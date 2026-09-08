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
const MAX_GROUP_SLUGS = 200;

let inboxSeq = 0;

// --- initiative parsing ------------------------------------------------------

function parseInitiative(slug, raw) {
  const card = {
    slug,
    title: slug,
    status: 'active',
    updated: '',
    area: '',
    umbrella: '',
    priority: null,
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
      // The closing --- may be the last line of the file with no trailing
      // newline; the card body is then empty rather than the raw frontmatter.
      const afterClose = raw.indexOf('\n', end + 1);
      body = afterClose === -1 ? '' : raw.slice(afterClose + 1);
      for (const line of front.split('\n')) {
        const m = line.match(/^([a-z-]+):\s*(.*)$/);
        if (!m) continue;
        const [, key, value] = m;
        if (!value) continue;
        if (key === 'title') card.title = value;
        else if (key === 'status') card.status = STATUSES.has(value) ? value : 'active';
        else if (key === 'updated') card.updated = value;
        else if (key === 'area') card.area = value;
        else if (key === 'umbrella') card.umbrella = SLUG_RE.test(value) ? value : '';
        else if (key === 'priority') card.priority = /^[0-4]$/.test(value) ? Number(value) : null;
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
  return cards.sort(compareNeed);
}

// Zone derivation (docs/mission-control.md "Ordering and zones"): a parked
// card sits on the shelf; a card with an ask (status waiting-on-you, or any
// decision line) needs the captain; everything else runs quietly.
function zoneOf(card) {
  if (card.status === 'parked') return 2;
  if (card.status === 'waiting-on-you' || card.decisions.length) return 0;
  return 1;
}

// The documented ordering rule (docs/mission-control.md "Ordering and
// zones"): asks first with the oldest ask on top, then quiet active cards and
// the shelf newest first, with the slug as a stable tie-break. /api/cards
// returns this order and the board renders its zones straight from it.
function compareNeed(a, b) {
  const zone = zoneOf(a) - zoneOf(b);
  if (zone) return zone;
  const ta = Date.parse(a.updated) || 0;
  const tb = Date.parse(b.updated) || 0;
  const recency = zoneOf(a) === 0 ? ta - tb : tb - ta;
  if (recency) return recency;
  return a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0;
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

// Queued, not-yet-consumed inbox events per slug, read from the inbox file
// names (`<epoch-ms>-<seq>-<slug>.msg`; docs/mission-control.md "Inbox event
// format"). The board shows queued-for-pickup feedback from this, and each
// submitting session tracks its own event id (the file name, returned by the
// POST) so a confirmation never outlives its own event or claims another
// session's; it disappears once firstmate consumes (deletes) the file.
function pendingEventsBySlug() {
  const events = new Map();
  let names = [];
  try {
    names = readdirSync(INBOX_DIR);
  } catch {
    return events;
  }
  for (const name of names.sort()) {
    if (!name.endsWith('.msg')) continue;
    const parts = name.slice(0, -4).split('-');
    if (parts.length < 3 || !/^\d+$/.test(parts[0]) || !/^\d+$/.test(parts[1])) continue;
    const slug = parts.slice(2).join('-');
    if (!SLUG_RE.test(slug)) continue;
    if (!events.has(slug)) events.set(slug, []);
    events.get(slug).push(name);
  }
  return events;
}

// --- inbox writes ------------------------------------------------------------

// Returns the event file name, which doubles as the event id in POST
// responses so a client can track its own submission's consumption.
function writeInboxEvent(kind, slug, text, epochMs = Date.now()) {
  mkdirSync(INBOX_DIR, { recursive: true });
  inboxSeq = (inboxSeq + 1) % 10000;
  const name = `${epochMs}-${inboxSeq}-${slug}.msg`;
  const body = kind === 'message' ? `\n${text.trim()}\n` : '\n';
  const content = `kind: ${kind}\nslug: ${slug}\nts: ${new Date(epochMs).toISOString()}\n${body}`;
  writeFileSync(join(INBOX_DIR, name), content, { flag: 'wx', mode: 0o600 });
  return name;
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

// The Command Deck theme: the palette, grids, and typography follow the
// owner-approved mock this rendering reproduces (docs/mission-control.md
// "Ordering and zones").
const PAGE_CSS = `
  :root{
    --bg:#0e1013; --panel:#15181d; --panel2:#1b1f26; --line:#262b33;
    --text:#e6e9ee; --dim:#8a93a1; --faint:#5c6572;
    --you:#f5b944; --ok:#4cc38a; --run:#5b9cf5; --park:#6b7482; --danger:#e5644e;
    font-size:15px;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);font:400 1rem/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  header.top{padding:22px 32px 14px;}
  header.top h1{font-size:1.25rem;margin:0;font-weight:650;}
  .deck{max-width:1220px;margin:0 auto;padding:10px 32px 40px;}
  .zone-title{font-size:.8rem;letter-spacing:.08em;text-transform:uppercase;color:var(--faint);margin:22px 0 10px;}
  ul{list-style:none;margin:0;padding:0;}

  /* needs-you rows */
  li.ask{display:grid;grid-template-columns:190px 1fr 96px 96px 40px;gap:14px;align-items:center;
    background:var(--panel2);border:1px solid #3a3414;border-left:3px solid var(--you);border-radius:8px;padding:12px 16px;margin-bottom:8px;position:relative;}
  li.ask .init{font-weight:650;}
  li.ask .what small{display:block;color:var(--dim);}
  li.ask .age{color:var(--dim);text-align:right;font-variant-numeric:tabular-nums;}
  li.ask .age.hot{color:var(--danger);font-weight:650;}
  .btn{display:inline-block;text-align:center;text-decoration:none;border:1px solid #3d4550;background:#20262e;color:var(--text);border-radius:6px;padding:5px 12px;font:600 .85rem/1.3 inherit;cursor:pointer;white-space:nowrap;}
  .btn:hover{border-color:#525c69;}

  /* the lifecycle menu */
  .more{border:none;background:none;color:var(--faint);font:700 1.1rem/1 inherit;cursor:pointer;padding:6px;border-radius:6px;text-align:center;}
  .more:hover{background:#242a33;color:var(--text);}
  .menu{position:absolute;right:10px;top:44px;z-index:9;background:#20252d;border:1px solid #39414d;border-radius:8px;
    box-shadow:0 8px 24px rgba(0,0,0,.5);min-width:230px;padding:6px;display:none;}
  .menu.open{display:block;}
  .menu button{display:block;width:100%;text-align:left;background:none;border:none;color:var(--text);
    font:500 .9rem/1.4 inherit;padding:8px 10px;border-radius:6px;cursor:pointer;}
  .menu button small{display:block;color:var(--faint);font-size:.78rem;}
  .menu button:hover{background:#2a313b;}
  .menu button.retire{color:#f0a196;}
  .menu hr{border:none;border-top:1px solid #2c333d;margin:6px 4px;}
  .quiet .menu,.shelf .menu{top:34px;}

  /* quiet strip */
  .quiet li{display:grid;grid-template-columns:190px 14px 1fr 40px;gap:14px;align-items:center;padding:7px 16px;border-bottom:1px solid var(--line);color:var(--dim);position:relative;}
  .quiet li .init{color:var(--text);font-weight:550;}
  .dot{width:8px;height:8px;border-radius:50%;display:inline-block;}
  .dot.ok{background:var(--ok);} .dot.run{background:var(--run);}

  /* shelf */
  .shelf{margin-top:26px;border:1px dashed #333b46;border-radius:10px;padding:4px 16px 10px;}
  .shelf .zone-title{margin-top:12px;color:var(--park);}
  .shelf li{display:grid;grid-template-columns:190px 1fr 110px 40px;gap:14px;align-items:center;padding:7px 0;border-bottom:1px solid #1d222a;color:var(--faint);position:relative;}
  .shelf li:last-child{border-bottom:none;}
  .shelf li .init{color:var(--dim);font-weight:550;text-decoration:none;}
  .shelf .btn{opacity:.85;}

  /* umbrella children fold indented under their parent row */
  li.child .init{padding-left:18px;position:relative;}
  li.child .init::before{content:'\\21B3';position:absolute;left:0;color:var(--faint);font-weight:400;}

  /* per-row note editor */
  .note{grid-column:1/-1;display:flex;gap:8px;align-items:flex-start;margin-top:6px;}
  .quiet .note,.shelf .note{margin:6px 0 8px;}
  .note textarea{flex:1;min-height:34px;max-height:120px;resize:vertical;border-radius:6px;border:1px solid #3d4550;
    background:#12151a;color:var(--text);padding:6px 10px;font:inherit;font-size:.9rem;}
  .btn.subtle{opacity:.7;}

  /* queued-for-pickup send feedback */
  .sent{grid-column:1/-1;display:flex;gap:8px;align-items:center;margin-top:6px;font-size:.85rem;color:var(--dim);}
  .quiet .sent,.shelf .sent{margin:2px 0 8px;}
  .chip-queued{border:1px solid #3d4550;background:#171b21;color:var(--dim);border-radius:999px;
    padding:1px 8px;font-size:.75rem;white-space:nowrap;}

  .empty{color:var(--dim);margin:32px 0;}
  .toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#20262e;border:1px solid #3d4550;color:var(--text);
    border-radius:8px;padding:8px 16px;font-size:.85rem;opacity:0;transition:opacity .2s;pointer-events:none;}
  .toast.show{opacity:.95;}

  /* doc pages */
  .doc-wrap{max-width:860px;margin:0 auto;padding:10px 32px 40px;}
  .doc-body{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:20px 24px;}
  .doc-body pre{overflow-x:auto;background:#12151a;padding:10px;border-radius:8px;}
  .doc-body code{background:#12151a;border-radius:4px;padding:1px 4px;}
  .doc-body a{color:var(--run);}
  a.back{display:inline-block;margin:16px 0 12px;color:var(--run);text-decoration:none;font-size:.85rem;}
`;

const BOARD_JS = `
  const POLL_MS = 5000;
  let lastPayload = '';
  let lastCards = [];
  // Open note editors, unsent drafts, the open menu, and this session's
  // send confirmations survive re-renders.
  const openNotes = new Set();
  const drafts = {};
  const confirmations = new Map();
  let openMenu = '';

  // Zone derivation mirrors the server's ordering rule: parked cards sit on
  // the shelf, cards with an ask need the captain, the rest run quietly.
  function zoneOf(card) {
    if (card.status === 'parked') return 2;
    if (card.status === 'waiting-on-you' || card.decisions.length) return 0;
    return 1;
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
    return res.json();
  }

  function firstLine(text) {
    return (text || '').split('\\n').map((l) => l.trim()).filter(Boolean)[0] || '';
  }

  function age(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return { label: '', hot: false };
    const days = Math.floor((Date.now() - t) / 86400000);
    if (days < 1) return { label: 'today', hot: false };
    return { label: days + (days === 1 ? ' day' : ' days'), hot: days >= 7 };
  }

  function shortDate(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return '';
    return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  function plural(n, word) {
    return n + ' ' + word + (n === 1 ? '' : 's');
  }

  // A successful send confirms on the row right away: the confirmation text
  // and the submitted event's id are remembered per slug, the local card's
  // pending state is bumped so the queued-for-pickup line shows before the
  // next poll, and the server's own pending events take over from the forced
  // refresh onward.
  function noteQueued(slug, text, event) {
    confirmations.set(slug, { text, event: event || '' });
    const card = lastCards.find((c) => c.slug === slug);
    if (card) {
      card.pendingEvents = (card.pendingEvents || []).concat(event || []);
      card.pending = (card.pending || 0) + 1;
    }
    render(lastCards);
    refresh(true);
  }

  // The button stays disabled while its request is in flight so a rapid
  // double click cannot queue a duplicate event; re-enabling matters only on
  // failure, since a success re-renders the row.
  async function act(slug, action, doneMsg, btn) {
    if (btn) btn.disabled = true;
    try {
      const r = await post('/api/action', { slug, action });
      toast(doneMsg);
      noteQueued(slug, doneMsg, r && r.event);
    } catch {
      toast('Could not send \\u2014 try again.');
      if (btn) btn.disabled = false;
    }
  }

  // The queued-for-pickup line stays on the row while the initiative has
  // unconsumed inbox events, and honestly says pickup happens on the next
  // pass, not instantly. A confirmation is tied to its own submitted event
  // id: once that event is consumed the confirmation goes with it, and other
  // sessions' queued events show neutral wording instead of claiming "Sent".
  function feedbackLine(card) {
    const entry = confirmations.get(card.slug);
    const queued = card.pendingEvents || [];
    if (entry && entry.event && !queued.includes(entry.event)) confirmations.delete(card.slug);
    if (!card.pending) {
      confirmations.delete(card.slug);
      return null;
    }
    const mine = confirmations.get(card.slug);
    const box = el('div', 'sent');
    const chip = el('span', 'chip-queued', 'queued for pickup');
    chip.title = 'Queued \\u2014 picked up on the next pass, not instant.';
    box.appendChild(chip);
    box.appendChild(el('span', null, mine ? mine.text : 'Queued \\u2014 picked up on the next pass'));
    return box;
  }

  function closeMenus() {
    openMenu = '';
    for (const m of document.querySelectorAll('.menu.open')) m.classList.remove('open');
  }

  function menuItem(label, small, cls, handler) {
    const b = el('button', cls);
    b.appendChild(document.createTextNode(label));
    if (small) b.appendChild(el('small', null, small));
    b.onclick = (e) => {
      e.stopPropagation();
      closeMenus();
      handler(b);
    };
    return b;
  }

  // Every row carries the same lifecycle menu: Send a note (message event),
  // Shelve (park event, absent on already-shelved rows), and Retire (drop
  // event; a single click is intent, per the existing drop handling).
  function rowMenu(card, row) {
    const more = el('button', 'more', '\\u22EF');
    const menu = el('div', 'menu');
    more.onclick = (e) => {
      e.stopPropagation();
      const wasOpen = menu.classList.contains('open');
      closeMenus();
      if (!wasOpen) {
        menu.classList.add('open');
        openMenu = card.slug;
      }
    };
    menu.appendChild(menuItem('Send a note', 'direction lands with the crew working this initiative', null, () => {
      openNotes.add(card.slug);
      render(lastCards);
    }));
    menu.appendChild(el('hr'));
    if (card.status !== 'parked') {
      menu.appendChild(menuItem('Shelve', 'pause everything safely; drops to the shelf below', null,
        (b) => act(card.slug, 'park', 'Shelve queued \\u2014 picked up on the next pass', b)));
    }
    menu.appendChild(menuItem('Retire', 'close it out for good; unfinished work is flagged first, never discarded', 'retire',
      (b) => act(card.slug, 'drop', 'Retire queued \\u2014 picked up on the next pass', b)));
    if (openMenu === card.slug) menu.classList.add('open');
    row.appendChild(more);
    row.appendChild(menu);
  }

  function noteEditor(card) {
    const box = el('div', 'note');
    const ta = el('textarea');
    ta.placeholder = 'Send direction for this initiative\\u2026';
    ta.dataset.draftFor = card.slug;
    if (drafts[card.slug]) ta.value = drafts[card.slug];
    const send = el('button', 'btn', 'Send');
    // The input clears the moment the note is submitted and the control stays
    // disabled while the write is in flight; a failure restores the text.
    send.onclick = async () => {
      const text = ta.value.trim();
      if (!text) return;
      ta.value = '';
      delete drafts[card.slug];
      send.disabled = true;
      try {
        const r = await post('/api/message', { slug: card.slug, text });
        openNotes.delete(card.slug);
        toast('Note sent \\u2014 queued for pickup.');
        noteQueued(card.slug, 'Note sent \\u2014 queued for pickup on the next pass', r && r.event);
      } catch {
        ta.value = text;
        drafts[card.slug] = text;
        toast('Could not send \\u2014 try again.');
        send.disabled = false;
      }
    };
    const cancel = el('button', 'btn subtle', 'Cancel');
    cancel.onclick = () => {
      delete drafts[card.slug];
      openNotes.delete(card.slug);
      render(lastCards);
    };
    box.appendChild(ta);
    box.appendChild(send);
    box.appendChild(cancel);
    return box;
  }

  // The ask in plain language: the first pending decision leads; extra
  // decisions or the latest update give the small second line.
  function askOf(card) {
    if (card.decisions.length) {
      const sub = card.decisions.length > 1 ? card.decisions.slice(1).join(' \\u00b7 ') : firstLine(card.latest);
      return { main: card.decisions[0], sub };
    }
    return { main: firstLine(card.latest) || 'Waiting on you', sub: '' };
  }

  function actionCell(card) {
    const cell = el('span');
    const link = card.links[0];
    if (link) {
      const a = el('a', 'btn', link.label);
      a.href = link.href;
      if (link.kind === 'external') {
        a.target = '_blank';
        a.rel = 'noopener';
      }
      cell.appendChild(a);
    }
    return cell;
  }

  function askRow(card, child) {
    const li = el('li', 'ask' + (child ? ' child' : ''));
    li.appendChild(el('span', 'init', card.title));
    const ask = askOf(card);
    const what = el('span', 'what', ask.main);
    if (ask.sub) what.appendChild(el('small', null, ask.sub));
    li.appendChild(what);
    const a = age(card.updated);
    const ageEl = el('span', 'age' + (a.hot ? ' hot' : ''), a.label);
    ageEl.title = card.updated;
    li.appendChild(ageEl);
    li.appendChild(actionCell(card));
    rowMenu(card, li);
    if (openNotes.has(card.slug)) li.appendChild(noteEditor(card));
    const fb = feedbackLine(card);
    if (fb) li.appendChild(fb);
    return li;
  }

  function quietRow(card, child) {
    const li = el('li', child ? 'child' : null);
    li.appendChild(el('span', 'init', card.title));
    li.appendChild(el('span', 'dot run'));
    li.appendChild(el('span', null, firstLine(card.latest)));
    rowMenu(card, li);
    if (openNotes.has(card.slug)) li.appendChild(noteEditor(card));
    const fb = feedbackLine(card);
    if (fb) li.appendChild(fb);
    return li;
  }

  function shelfRow(card, child) {
    const li = el('li', child ? 'child' : null);
    li.appendChild(el('span', 'init', card.title));
    const line = firstLine(card.latest);
    const when = shortDate(card.updated);
    li.appendChild(el('span', null, line + (when ? (line ? '; ' : '') + 'shelved ' + when : '')));
    const cell = el('span');
    const re = el('button', 'btn', 'Re-engage');
    re.onclick = () => act(card.slug, 're-engage', 'Re-engage queued \\u2014 picked up on the next pass', re);
    cell.appendChild(re);
    li.appendChild(cell);
    rowMenu(card, li);
    if (openNotes.has(card.slug)) li.appendChild(noteEditor(card));
    const fb = feedbackLine(card);
    if (fb) li.appendChild(fb);
    return li;
  }

  // Umbrella children fold indented under their parent when both share a
  // zone; a child whose parent sits in another zone stays its own row, so an
  // ask is never hidden inside a quiet group. Rows stay one per initiative.
  function foldGroups(list) {
    const heads = new Set();
    for (const c of list) if (c.umbrella) heads.add(c.umbrella);
    const bySlug = new Map(list.map((c) => [c.slug, c]));
    const done = new Set();
    const out = [];
    for (const c of list) {
      if (done.has(c.slug)) continue;
      const key = c.umbrella || (heads.has(c.slug) ? c.slug : '');
      if (!key) {
        done.add(c.slug);
        out.push({ card: c, child: false });
        continue;
      }
      const head = bySlug.get(key);
      if (!head) {
        done.add(c.slug);
        out.push({ card: c, child: false });
        continue;
      }
      if (!done.has(head.slug)) {
        done.add(head.slug);
        out.push({ card: head, child: false });
      }
      for (const m of list) {
        if (m.umbrella === key && !done.has(m.slug)) {
          done.add(m.slug);
          out.push({ card: m, child: true });
        }
      }
    }
    return out;
  }

  function saveDrafts() {
    let focused = null;
    for (const t of document.querySelectorAll('textarea[data-draft-for]')) {
      if (t.value) drafts[t.dataset.draftFor] = t.value;
      else delete drafts[t.dataset.draftFor];
      if (t === document.activeElement) focused = t.dataset.draftFor;
    }
    return focused;
  }

  function restoreFocus(focused) {
    if (!focused) return;
    for (const t of document.querySelectorAll('textarea[data-draft-for]')) {
      if (t.dataset.draftFor === focused) {
        t.focus();
        t.setSelectionRange(t.value.length, t.value.length);
      }
    }
  }

  // Cards arrive from /api/cards already in need order (asks first, oldest
  // ask first); the three zones are cut straight from that order.
  function render(cards) {
    lastCards = cards;
    const focused = saveDrafts();
    const root = document.getElementById('board');
    root.textContent = '';
    const asks = cards.filter((c) => zoneOf(c) === 0);
    const quiet = cards.filter((c) => zoneOf(c) === 1);
    const shelf = cards.filter((c) => zoneOf(c) === 2);

    const askCount = asks.reduce((n, c) => n + Math.max(1, c.decisions.length), 0);
    root.appendChild(el('p', 'zone-title', asks.length
      ? 'Needs you \\u2014 ' + plural(askCount, 'ask') + ' across ' + plural(asks.length, 'initiative')
      : 'Needs you \\u2014 nothing waiting on you'));
    if (asks.length) {
      const ul = el('ul');
      for (const r of foldGroups(asks)) ul.appendChild(askRow(r.card, r.child));
      root.appendChild(ul);
    }

    if (quiet.length) {
      const wrap = el('div', 'quiet');
      wrap.appendChild(el('p', 'zone-title', 'Running quietly \\u2014 nothing for you'));
      const ul = el('ul');
      for (const r of foldGroups(quiet)) ul.appendChild(quietRow(r.card, r.child));
      wrap.appendChild(ul);
      root.appendChild(wrap);
    }

    if (shelf.length) {
      const wrap = el('div', 'shelf');
      wrap.appendChild(el('p', 'zone-title', 'Shelf \\u2014 ' + shelf.length + ' shelved, out of the way until you bring '
        + (shelf.length === 1 ? 'it' : 'them') + ' back'));
      const ul = el('ul');
      for (const r of foldGroups(shelf)) ul.appendChild(shelfRow(r.card, r.child));
      wrap.appendChild(ul);
      root.appendChild(wrap);
    }

    if (!cards.length) root.appendChild(el('div', 'empty', 'No initiatives yet.'));
    restoreFocus(focused);
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

  document.addEventListener('click', () => closeMenus());
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
<header class="top"><h1>Mission Control</h1></header>
<div class="deck" id="board"></div>
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
<div class="doc-wrap">
<a class="back" href="/">← Back to the board</a>
<div class="doc-body">${bodyHtml}</div>
</div>
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
  try {
    if (!ALLOWED_HOSTS.has((req.headers.host || '').toLowerCase())) {
      sendJson(res, 403, { error: 'forbidden host' });
      return;
    }
    let url;
    try {
      url = new URL(req.url, `http://${HOST}:${PORT}`);
    } catch {
      sendJson(res, 400, { error: 'invalid request target' });
      return;
    }
    if (req.method === 'GET' && url.pathname === '/') {
      sendHtml(res, 200, boardPage());
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/cards') {
      const pending = pendingEventsBySlug();
      const cards = listCards().map((c) => {
        const events = pending.get(c.slug) || [];
        return { ...c, links: cardLinks(c), pending: events.length, pendingEvents: events };
      });
      sendJson(res, 200, { cards });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/group-action') {
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
      if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
        sendJson(res, 400, { error: 'invalid request body' });
        return;
      }
      const action = typeof payload.action === 'string' ? payload.action : '';
      if (!ACTIONS.has(action)) {
        sendJson(res, 400, { error: 'invalid action' });
        return;
      }
      // Membership is explicit at emission time: the client sends the exact
      // member list it displayed when the button was clicked, and every slug is
      // validated before any event is written, so a bad entry rejects the
      // whole batch instead of acting on part of it.
      const slugs = Array.isArray(payload.slugs) ? payload.slugs : null;
      if (!slugs || !slugs.length || slugs.length > MAX_GROUP_SLUGS
        || !slugs.every((s) => typeof s === 'string' && SLUG_RE.test(s))) {
        sendJson(res, 400, { error: 'invalid slugs' });
        return;
      }
      // One timestamp captured before the batch: member events of one group
      // action must share their epoch-ms and ts so the consumer can read a
      // same-kind same-timestamp burst as one captain action.
      const batchMs = Date.now();
      const events = [...new Set(slugs)].map((slug) => writeInboxEvent(action, slug, '', batchMs));
      sendJson(res, 200, { ok: true, events });
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
      if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
        sendJson(res, 400, { error: 'invalid request body' });
        return;
      }
      const slug = typeof payload.slug === 'string' ? payload.slug : '';
      if (!SLUG_RE.test(slug)) {
        sendJson(res, 400, { error: 'invalid slug' });
        return;
      }
      let event;
      if (url.pathname === '/api/message') {
        const text = typeof payload.text === 'string' ? payload.text.trim() : '';
        if (!text || text.length > MAX_MESSAGE_CHARS) {
          sendJson(res, 400, { error: 'invalid text' });
          return;
        }
        event = writeInboxEvent('message', slug, text);
      } else {
        const action = typeof payload.action === 'string' ? payload.action : '';
        if (!ACTIONS.has(action)) {
          sendJson(res, 400, { error: 'invalid action' });
          return;
        }
        event = writeInboxEvent(action, slug, '');
      }
      sendJson(res, 200, { ok: true, event });
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
