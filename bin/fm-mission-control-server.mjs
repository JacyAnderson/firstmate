#!/usr/bin/env node
// Mission Control board server.
//
// Serves the captain's status board from initiative files and queues captain
// input as inbox event files. docs/mission-control.md owns the file schemas
// and this server's wire contract; bin/fm-mission-control.sh owns lifecycle
// mechanics (start/stop/status/check installation) and is the normal way to
// run this process.
//
// Hard boundaries:
//   - binds 127.0.0.1 only;
//   - reads only data/mission-control/ and local doc-link targets under data/;
//   - writes only under state/mission-control/ (the inbox);
//   - never executes anything it reads; inbox files are data for firstmate.
//
// Env: FM_HOME (operational home; defaults to the repo root above bin/),
//      FM_MC_PORT (default 7460).

import { createServer } from 'node:http';
import { readFileSync, readdirSync, writeFileSync, mkdirSync, realpathSync, statSync } from 'node:fs';
import { dirname, resolve, join, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const HOME = process.env.FM_HOME ? resolve(process.env.FM_HOME) : ROOT;
const PORT = Number(process.env.FM_MC_PORT || 7460);
const HOST = '127.0.0.1';

const DATA_DIR = join(HOME, 'data');
const INITIATIVES_DIR = join(DATA_DIR, 'mission-control', 'initiatives');
const INBOX_DIR = join(HOME, 'state', 'mission-control', 'inbox');

const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const ACTIONS = new Set(['park', 're-engage', 'drop']);
const STATUSES = new Set(['active', 'waiting-on-you', 'parked']);
const MAX_BODY_BYTES = 64 * 1024;
const MAX_MESSAGE_CHARS = 10000;

let inboxSeq = 0;

// --- initiative parsing ------------------------------------------------------

function parseInitiative(slug, raw) {
  const card = {
    slug,
    title: slug,
    status: 'active',
    updated: '',
    workItems: [],
    decisions: [],
    links: [],
    latest: '',
  };
  let body = raw;
  if (raw.startsWith('---\n')) {
    const end = raw.indexOf('\n---', 4);
    if (end !== -1) {
      const front = raw.slice(4, end);
      body = raw.slice(raw.indexOf('\n', end + 1) + 1);
      for (const line of front.split('\n')) {
        const m = line.match(/^([a-z-]+):\s*(.*)$/);
        if (!m) continue;
        const [, key, value] = m;
        if (!value) continue;
        if (key === 'title') card.title = value;
        else if (key === 'status') card.status = STATUSES.has(value) ? value : 'active';
        else if (key === 'updated') card.updated = value;
        else if (key === 'work-items') card.workItems = value.split(',').map((s) => s.trim()).filter(Boolean);
        else if (key === 'decision') card.decisions.push(value);
        else if (key === 'link') {
          const target = value.replace(/\s+$/, '').split(/\s+/).pop();
          const label = value.slice(0, value.lastIndexOf(target)).trim() || target;
          card.links.push({ label, target });
        }
      }
    }
  }
  const historyAt = body.indexOf('\n## History');
  card.latest = (historyAt === -1 ? body : body.slice(0, historyAt)).trim();
  return card;
}

function loadCard(slug) {
  const raw = readFileSync(join(INITIATIVES_DIR, `${slug}.md`), 'utf8');
  return parseInitiative(slug, raw);
}

function listCards() {
  let names = [];
  try {
    names = readdirSync(INITIATIVES_DIR);
  } catch {
    return [];
  }
  const cards = [];
  for (const name of names) {
    if (!name.endsWith('.md')) continue;
    const slug = name.slice(0, -3);
    if (!SLUG_RE.test(slug)) continue;
    try {
      cards.push(loadCard(slug));
    } catch {
      // An unreadable card is skipped rather than taking the board down.
    }
  }
  return cards;
}

// A local doc target is served only when the initiative file itself declared
// it, and only when it resolves (symlinks included) under the home's data/
// directory. Clients address links by index; no client-supplied path is ever
// resolved.
function resolveDocTarget(target) {
  if (!target || isAbsolute(target) || target.startsWith('https://') || target.startsWith('http://')) return null;
  const candidate = resolve(HOME, target);
  let real;
  let realData;
  try {
    real = realpathSync(candidate);
    realData = realpathSync(DATA_DIR);
  } catch {
    return null;
  }
  if (real !== realData && !real.startsWith(realData + sep)) return null;
  try {
    if (!statSync(real).isFile()) return null;
  } catch {
    return null;
  }
  return real;
}

function cardLinks(card) {
  return card.links.map((l, i) => {
    if (/^https?:\/\//.test(l.target)) return { label: l.label, href: l.target, kind: 'external' };
    return { label: l.label, href: `/doc/${card.slug}/${i}`, kind: 'doc' };
  });
}

// --- inbox writes ------------------------------------------------------------

function writeInboxEvent(kind, slug, text) {
  mkdirSync(INBOX_DIR, { recursive: true });
  inboxSeq = (inboxSeq + 1) % 10000;
  const name = `${Date.now()}-${inboxSeq}-${slug}.msg`;
  const body = kind === 'message' ? `\n${text.trim()}\n` : '\n';
  const content = `kind: ${kind}\nslug: ${slug}\nts: ${new Date().toISOString()}\n${body}`;
  writeFileSync(join(INBOX_DIR, name), content, { flag: 'wx', mode: 0o600 });
}

// --- markdown rendering ------------------------------------------------------

function escapeHtml(s) {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function renderInline(escaped) {
  return escaped
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
}

// Minimal, conservative markdown-to-HTML: headings, fenced code, lists,
// blockquotes, paragraphs, and inline code/bold/links. Everything is
// HTML-escaped before any markup is introduced.
function renderMarkdown(md) {
  const out = [];
  let inCode = false;
  let listTag = null;
  let para = [];
  const closeList = () => {
    if (listTag) {
      out.push(`</${listTag}>`);
      listTag = null;
    }
  };
  const flushPara = () => {
    if (para.length) {
      out.push(`<p>${para.join('<br>')}</p>`);
      para = [];
    }
  };
  for (const rawLine of md.split('\n')) {
    const line = escapeHtml(rawLine);
    if (rawLine.startsWith('```')) {
      flushPara();
      closeList();
      out.push(inCode ? '</code></pre>' : '<pre><code>');
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      out.push(line);
      continue;
    }
    const heading = rawLine.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      flushPara();
      closeList();
      const level = heading[1].length;
      out.push(`<h${level}>${renderInline(escapeHtml(heading[2]))}</h${level}>`);
      continue;
    }
    const bullet = rawLine.match(/^\s*[-*]\s+(.*)$/);
    const ordered = rawLine.match(/^\s*\d+\.\s+(.*)$/);
    if (bullet || ordered) {
      flushPara();
      const tag = bullet ? 'ul' : 'ol';
      if (listTag !== tag) {
        closeList();
        out.push(`<${tag}>`);
        listTag = tag;
      }
      out.push(`<li>${renderInline(escapeHtml((bullet || ordered)[1]))}</li>`);
      continue;
    }
    if (rawLine.startsWith('>')) {
      flushPara();
      closeList();
      out.push(`<blockquote>${renderInline(escapeHtml(rawLine.replace(/^>\s?/, '')))}</blockquote>`);
      continue;
    }
    if (rawLine.trim() === '') {
      flushPara();
      closeList();
      continue;
    }
    para.push(renderInline(line));
  }
  if (inCode) out.push('</code></pre>');
  flushPara();
  closeList();
  return out.join('\n');
}

// --- pages ---------------------------------------------------------------------

const PAGE_CSS = `
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 24px;
         background: #f4f5f7; color: #1c1e21; max-width: 860px; margin-inline: auto; }
  @media (prefers-color-scheme: dark) { body { background: #16181c; color: #e6e8eb; } }
  h1 { font-size: 20px; margin: 0 0 16px; }
  h2.section { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; opacity: .6; margin: 24px 0 8px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,.1); border-radius: 10px; padding: 14px 16px; margin-bottom: 12px; }
  @media (prefers-color-scheme: dark) { .card { background: #1f2228; border-color: rgba(255,255,255,.12); } }
  .card.waiting { border-left: 4px solid #d97706; }
  .card-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .card-title { font-size: 15px; font-weight: 600; margin: 0; flex: 1; }
  .chip { font-size: 11px; padding: 2px 8px; border-radius: 999px; white-space: nowrap; }
  .chip.active { background: #dcfce7; color: #14532d; }
  .chip.waiting-on-you { background: #fef3c7; color: #92400e; }
  .chip.parked { background: #e5e7eb; color: #374151; }
  .time { font-size: 12px; opacity: .55; white-space: nowrap; }
  .badges { margin: 8px 0 0; display: flex; flex-wrap: wrap; gap: 6px; }
  .badge { font-size: 12px; background: #fee2e2; color: #991b1b; border-radius: 6px; padding: 2px 8px; }
  .latest { margin: 8px 0 0; font-size: 14px; line-height: 1.45; white-space: pre-wrap; }
  .links { margin: 8px 0 0; display: flex; flex-wrap: wrap; gap: 12px; font-size: 13px; }
  .links a { color: #2563eb; text-decoration: none; }
  .links a:hover { text-decoration: underline; }
  .controls { margin-top: 10px; display: flex; gap: 8px; align-items: flex-start; }
  .controls textarea { flex: 1; min-height: 34px; max-height: 120px; resize: vertical; border-radius: 8px;
                       border: 1px solid rgba(0,0,0,.15); padding: 6px 10px; font: inherit; font-size: 13px;
                       background: inherit; color: inherit; }
  button { font: inherit; font-size: 13px; border-radius: 8px; border: 1px solid rgba(0,0,0,.15);
           background: transparent; color: inherit; padding: 6px 12px; cursor: pointer; }
  button:hover { background: rgba(0,0,0,.06); }
  @media (prefers-color-scheme: dark) { button:hover { background: rgba(255,255,255,.08); } }
  button.primary { background: #2563eb; border-color: #2563eb; color: #fff; }
  button.danger { color: #b91c1c; }
  details.parked-section summary { cursor: pointer; font-size: 13px; opacity: .7; margin: 24px 0 8px; }
  .empty { opacity: .6; font-size: 14px; margin: 32px 0; }
  .toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: #1c1e21; color: #fff;
           border-radius: 8px; padding: 8px 16px; font-size: 13px; opacity: 0; transition: opacity .2s; pointer-events: none; }
  .toast.show { opacity: .92; }
  .doc-body { background: #fff; border: 1px solid rgba(0,0,0,.1); border-radius: 10px; padding: 20px 24px; }
  @media (prefers-color-scheme: dark) { .doc-body { background: #1f2228; border-color: rgba(255,255,255,.12); } }
  .doc-body pre { overflow-x: auto; background: rgba(0,0,0,.05); padding: 10px; border-radius: 8px; }
  a.back { display: inline-block; margin-bottom: 12px; color: #2563eb; text-decoration: none; font-size: 13px; }
`;

const BOARD_JS = `
  const POLL_MS = 5000;
  let lastPayload = '';

  function relTime(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return iso || '';
    const s = Math.floor((Date.now() - t) / 1000);
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + 'm ago';
    if (s < 86400) return Math.floor(s / 3600) + 'h ago';
    return Math.floor(s / 86400) + 'd ago';
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function toast(msg) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.classList.add('show');
    setTimeout(() => t.classList.remove('show'), 2000);
  }

  async function post(path, payload) {
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) throw new Error('request failed');
  }

  function renderCard(card) {
    const div = el('div', 'card' + (card.status === 'waiting-on-you' ? ' waiting' : ''));
    div.dataset.slug = card.slug;
    const head = el('div', 'card-head');
    head.appendChild(el('h3', 'card-title', card.title));
    head.appendChild(el('span', 'chip ' + card.status, card.status === 'waiting-on-you' ? 'waiting on you' : card.status));
    const time = el('span', 'time', relTime(card.updated));
    time.title = card.updated;
    head.appendChild(time);
    div.appendChild(head);
    if (card.decisions.length) {
      const badges = el('div', 'badges');
      for (const d of card.decisions) badges.appendChild(el('span', 'badge', 'decision: ' + d));
      div.appendChild(badges);
    }
    if (card.latest) div.appendChild(el('div', 'latest', card.latest));
    if (card.links.length) {
      const links = el('div', 'links');
      for (const l of card.links) {
        const a = el('a', null, (l.kind === 'doc' ? '\\u{1F4C4} ' : '\\u{1F517} ') + l.label);
        a.href = l.href;
        if (l.kind === 'external') { a.target = '_blank'; a.rel = 'noopener'; }
        links.appendChild(a);
      }
      div.appendChild(links);
    }
    const controls = el('div', 'controls');
    const box = el('textarea');
    box.placeholder = 'Send direction for this initiative\\u2026';
    box.dataset.draftFor = card.slug;
    const send = el('button', 'primary', 'Send');
    send.onclick = async () => {
      const text = box.value.trim();
      if (!text) return;
      try {
        await post('/api/message', { slug: card.slug, text });
        box.value = '';
        toast('Sent.');
      } catch { toast('Could not send \\u2014 try again.'); }
    };
    controls.appendChild(box);
    controls.appendChild(send);
    if (card.status === 'parked') {
      const re = el('button', null, 'Re-engage');
      re.onclick = () => act(card.slug, 're-engage', 'Re-engaging.');
      controls.appendChild(re);
    } else {
      const park = el('button', null, 'Park');
      park.onclick = () => act(card.slug, 'park', 'Parked.');
      controls.appendChild(park);
    }
    const drop = el('button', 'danger', 'Drop');
    drop.onclick = () => {
      if (confirm('Drop "' + card.title + '"? This asks for it to be closed out.')) {
        act(card.slug, 'drop', 'Drop requested.');
      }
    };
    controls.appendChild(drop);
    div.appendChild(controls);
    return div;
  }

  async function act(slug, action, doneMsg) {
    try {
      await post('/api/action', { slug, action });
      toast(doneMsg);
      refresh(true);
    } catch { toast('Could not send \\u2014 try again.'); }
  }

  function saveDrafts() {
    const drafts = {};
    let focused = null;
    for (const t of document.querySelectorAll('textarea[data-draft-for]')) {
      if (t.value) drafts[t.dataset.draftFor] = t.value;
      if (t === document.activeElement) focused = t.dataset.draftFor;
    }
    return { drafts, focused };
  }

  function restoreDrafts({ drafts, focused }) {
    for (const t of document.querySelectorAll('textarea[data-draft-for]')) {
      const slug = t.dataset.draftFor;
      if (drafts[slug]) t.value = drafts[slug];
      if (slug === focused) t.focus();
    }
  }

  function render(cards) {
    const state = saveDrafts();
    const root = document.getElementById('board');
    root.textContent = '';
    const waiting = cards.filter((c) => c.status === 'waiting-on-you');
    const active = cards.filter((c) => c.status === 'active');
    const parked = cards.filter((c) => c.status === 'parked');
    const byRecency = (a, b) => (Date.parse(b.updated) || 0) - (Date.parse(a.updated) || 0);
    waiting.sort(byRecency);
    active.sort(byRecency);
    parked.sort(byRecency);
    if (!cards.length) {
      root.appendChild(el('div', 'empty', 'No initiatives yet.'));
    }
    if (waiting.length) {
      root.appendChild(el('h2', 'section', 'Waiting on you'));
      for (const c of waiting) root.appendChild(renderCard(c));
    }
    if (active.length) {
      root.appendChild(el('h2', 'section', 'Active'));
      for (const c of active) root.appendChild(renderCard(c));
    }
    if (parked.length) {
      const details = el('details', 'parked-section');
      details.appendChild(el('summary', null, 'Parked (' + parked.length + ')'));
      for (const c of parked) details.appendChild(renderCard(c));
      root.appendChild(details);
    }
    restoreDrafts(state);
  }

  async function refresh(force) {
    try {
      const res = await fetch('/api/cards');
      const body = await res.text();
      if (!force && body === lastPayload) return;
      lastPayload = body;
      render(JSON.parse(body).cards);
    } catch { /* transient; next poll retries */ }
  }

  refresh(true);
  setInterval(refresh, POLL_MS);
`;

function boardPage() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mission Control</title>
<style>${PAGE_CSS}</style>
</head>
<body>
<h1>Mission Control</h1>
<div id="board"></div>
<div id="toast" class="toast"></div>
<script>${BOARD_JS}</script>
</body>
</html>`;
}

function docPage(title, bodyHtml) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)} - Mission Control</title>
<style>${PAGE_CSS}</style>
</head>
<body>
<a class="back" href="/">← Back to the board</a>
<div class="doc-body">${bodyHtml}</div>
</body>
</html>`;
}

// --- http ----------------------------------------------------------------------

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
  res.end(body);
}

function sendHtml(res, code, html) {
  res.writeHead(code, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}

function readJsonBody(req) {
  return new Promise((resolveBody, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolveBody(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('invalid json'));
      }
    });
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${HOST}:${PORT}`);
  try {
    if (!ALLOWED_HOSTS.has((req.headers.host || '').toLowerCase())) {
      sendJson(res, 403, { error: 'forbidden host' });
      return;
    }
    if (req.method === 'GET' && url.pathname === '/') {
      sendHtml(res, 200, boardPage());
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/cards') {
      const cards = listCards().map((c) => ({ ...c, links: cardLinks(c) }));
      sendJson(res, 200, { cards });
      return;
    }
    if (req.method === 'POST' && (url.pathname === '/api/message' || url.pathname === '/api/action')) {
      const mediaType = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
      if (mediaType !== 'application/json') {
        sendJson(res, 415, { error: 'content-type must be application/json' });
        return;
      }
      let payload;
      try {
        payload = await readJsonBody(req);
      } catch {
        sendJson(res, 400, { error: 'invalid request body' });
        return;
      }
      const slug = typeof payload.slug === 'string' ? payload.slug : '';
      if (!SLUG_RE.test(slug)) {
        sendJson(res, 400, { error: 'invalid slug' });
        return;
      }
      if (url.pathname === '/api/message') {
        const text = typeof payload.text === 'string' ? payload.text.trim() : '';
        if (!text || text.length > MAX_MESSAGE_CHARS) {
          sendJson(res, 400, { error: 'invalid text' });
          return;
        }
        writeInboxEvent('message', slug, text);
      } else {
        const action = typeof payload.action === 'string' ? payload.action : '';
        if (!ACTIONS.has(action)) {
          sendJson(res, 400, { error: 'invalid action' });
          return;
        }
        writeInboxEvent(action, slug, '');
      }
      sendJson(res, 200, { ok: true });
      return;
    }
    const docMatch = req.method === 'GET' && url.pathname.match(/^\/doc\/([a-z0-9-]+)\/(\d{1,3})$/);
    if (docMatch) {
      const [, slug, indexRaw] = docMatch;
      if (!SLUG_RE.test(slug)) {
        sendHtml(res, 404, docPage('Not found', '<p>Not found.</p>'));
        return;
      }
      let card;
      try {
        card = loadCard(slug);
      } catch {
        sendHtml(res, 404, docPage('Not found', '<p>Not found.</p>'));
        return;
      }
      const link = card.links[Number(indexRaw)];
      const real = link ? resolveDocTarget(link.target) : null;
      if (!real) {
        sendHtml(res, 404, docPage('Not found', '<p>Not found.</p>'));
        return;
      }
      const md = readFileSync(real, 'utf8');
      sendHtml(res, 200, docPage(link.label, renderMarkdown(md)));
      return;
    }
    sendJson(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(`mission-control: ${err.message}`);
    sendJson(res, 500, { error: 'internal error' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`mission-control: listening on http://${HOST}:${PORT} (home: ${HOME})`);
});
