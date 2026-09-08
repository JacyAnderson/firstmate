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

// The flight-ops skin: palette, grids, lamps, meters, and typography follow
// the owner-approved contract this rendering reproduces
// (docs/mission-control.md "Ordering and zones").
const PAGE_CSS = `
  :root{
    --space:#090C11; --panel:#11151D; --panel2:#161B25; --bezel:#242C39; --etch:#2E3745;
    --white:#EDEFF2; --ghost:#8C97A6; --stencil:#5F6A79;
    --caution:#F2A93B; --warn:#E0592A; --go:#69B98C; --lamp-off:#1B212B;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--space);color:var(--white);
    font:400 15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    background-image:
      linear-gradient(rgba(140,151,166,.045) 1px, transparent 1px),
      linear-gradient(90deg, rgba(140,151,166,.045) 1px, transparent 1px),
      radial-gradient(ellipse at 25% -10%, rgba(224,89,42,.06), transparent 45%);
    background-size:32px 32px, 32px 32px, auto;}
  .mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-variant-numeric:tabular-nums;}
  .stencil{font-family:"Avenir Next Condensed","Arial Narrow",Impact,sans-serif;
    font-weight:600;letter-spacing:.22em;text-transform:uppercase;}
  .wrap{max-width:1100px;margin:0 auto;padding:0 28px 56px;}

  /* corner brackets */
  .frame{position:relative;}
  .frame::before,.frame::after,
  .frame>.fb::before,.frame>.fb::after{content:"";position:absolute;width:14px;height:14px;border:1.5px solid var(--ghost);}
  .frame::before{left:-1px;top:-1px;border-right:none;border-bottom:none;}
  .frame::after{right:-1px;top:-1px;border-left:none;border-bottom:none;}
  .frame>.fb::before{left:-1px;bottom:-1px;border-right:none;border-top:none;}
  .frame>.fb::after{right:-1px;bottom:-1px;border-left:none;border-top:none;}

  /* ===== header: caution & warning panel ===== */
  header{display:flex;align-items:center;justify-content:space-between;gap:20px;flex-wrap:wrap;
    border:1px solid var(--bezel);background:var(--panel);
    padding:18px 22px;margin:26px 0 8px;}
  .ident h1{margin:0;font-size:1.2rem;line-height:1.2;}
  .ident h1 .stencil{font-size:1.35rem;letter-spacing:.34em;}
  .met{color:var(--caution);font-size:1.05rem;letter-spacing:.24em;margin-top:6px;
    text-shadow:0 0 12px rgba(242,169,59,.45);}
  .met small{color:var(--stencil);font-size:.68rem;letter-spacing:.2em;display:block;text-shadow:none;margin-bottom:2px;}
  .cw{display:grid;grid-template-columns:repeat(4,116px);gap:7px;}
  .lamp{border:1px solid var(--etch);background:var(--lamp-off);
    padding:7px 8px 6px;text-align:center;font-size:.62rem;letter-spacing:.14em;color:var(--stencil);
    font-family:"Avenir Next Condensed","Arial Narrow",sans-serif;font-weight:600;text-transform:uppercase;
    box-shadow:inset 0 1px 0 rgba(255,255,255,.04);}
  .lamp b{display:block;font:700 1.2rem/1.15 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:0;}
  .lamp.caution{background:rgba(242,169,59,.14);border-color:#57431f;color:#C99843;}
  .lamp.caution b{color:var(--caution);text-shadow:0 0 12px rgba(242,169,59,.55);}
  .lamp.warn{background:repeating-linear-gradient(45deg, rgba(224,89,42,.2) 0 8px, rgba(224,89,42,.08) 8px 16px);
    border-color:#5c2c1a;color:#C06443;}
  .lamp.warn b{color:var(--warn);text-shadow:0 0 12px rgba(224,89,42,.6);}
  .lamp.go{background:rgba(105,185,140,.10);border-color:#28513c;color:#63A181;}
  .lamp.go b{color:var(--go);text-shadow:0 0 10px rgba(105,185,140,.5);}

  .subplate{display:flex;justify-content:space-between;color:var(--stencil);font-size:.66rem;
    letter-spacing:.22em;text-transform:uppercase;margin:6px 2px 24px;
    font-family:"Avenir Next Condensed","Arial Narrow",sans-serif;}

  h2{display:flex;align-items:center;gap:12px;margin:30px 0 10px;font-size:.8rem;color:var(--stencil);}
  h2 .tag{border:1px solid var(--etch);padding:4px 12px;background:var(--panel);}
  h2 small{color:var(--stencil);font-size:.7rem;letter-spacing:.12em;}
  h2::after{content:"";flex:1;height:1px;background:repeating-linear-gradient(90deg,var(--etch) 0 6px,transparent 6px 12px);}

  ul{list-style:none;margin:0;padding:0;}

  li.ask{display:grid;grid-template-columns:38px 168px 1fr 190px 96px 34px;gap:13px;align-items:center;
    background:var(--panel);border:1px solid var(--bezel);
    padding:12px 14px 12px 0;margin-bottom:6px;animation:powerup .3s ease both;position:relative;}
  li.ask:nth-child(2){animation-delay:.05s} li.ask:nth-child(3){animation-delay:.1s}
  li.ask:nth-child(4){animation-delay:.15s} li.ask:nth-child(5){animation-delay:.2s}
  li.ask:nth-child(6){animation-delay:.25s} li.ask:nth-child(7){animation-delay:.3s}
  li.ask:nth-child(8){animation-delay:.35s}
  @keyframes powerup{from{opacity:0;filter:brightness(2.2)}to{opacity:1;filter:none}}
  @media (prefers-reduced-motion: reduce){li.ask{animation:none}}

  /* status block: lamp + stencil word */
  .stat{display:flex;flex-direction:column;align-items:center;gap:3px;align-self:stretch;justify-content:center;
    border-right:1px solid var(--bezel);background:var(--panel2);padding:0 6px;}
  .stat .ind{width:11px;height:11px;border-radius:2px;background:var(--caution);box-shadow:0 0 9px rgba(242,169,59,.55);}
  .stat span{font-size:.5rem;letter-spacing:.12em;color:var(--stencil);text-transform:uppercase;
    font-family:"Avenir Next Condensed","Arial Narrow",sans-serif;font-weight:600;}
  li.ask.hot .stat{background:repeating-linear-gradient(45deg, rgba(224,89,42,.14) 0 7px, transparent 7px 14px), var(--panel2);}
  li.ask.hot .stat .ind{background:var(--warn);box-shadow:0 0 9px rgba(224,89,42,.65);animation:blink 2.4s step-end infinite;}
  li.ask.hot .stat span{color:#C06443;}
  @keyframes blink{0%,92%{opacity:1}96%{opacity:.3}100%{opacity:1}}
  @media (prefers-reduced-motion: reduce){li.ask.hot .stat .ind{animation:none}}

  /* grid cells default to min-width:auto, which lets a long label or word
     force the row past the viewport; cap them so content truncates or wraps
     inside the row instead. */
  li.ask>span,.quiet li>span,.shelf li>span{min-width:0;}
  li.ask .init{font-weight:650;font-size:.95rem;overflow-wrap:break-word;}
  li.ask .what{color:var(--white);overflow-wrap:break-word;}
  li.ask .what small{display:block;color:var(--ghost);font-size:.85rem;}

  /* labeled days-waiting meter */
  .meter{display:flex;flex-direction:column;gap:3px;}
  .meter .row1{display:flex;justify-content:space-between;align-items:baseline;}
  .meter .label{font-size:.56rem;letter-spacing:.16em;color:var(--stencil);text-transform:uppercase;
    font-family:"Avenir Next Condensed","Arial Narrow",sans-serif;font-weight:600;}
  .meter .val{font-size:.85rem;color:var(--white);font-weight:700;}
  li.ask.hot .meter .val{color:var(--warn);}
  .meter .track{position:relative;height:8px;background:var(--lamp-off);border:1px solid var(--etch);}
  .meter .track i{position:absolute;left:0;top:0;bottom:0;background:var(--caution);}
  li.ask.hot .track i{background:var(--warn);}
  .meter .track em{position:absolute;top:-2px;bottom:-2px;width:1.5px;background:var(--ghost);left:50%;}
  .meter .scale{display:flex;justify-content:space-between;font-size:.54rem;color:var(--stencil);letter-spacing:.06em;}

  .btn{border:1px solid #6b4a22;background:linear-gradient(180deg,#241d11,#191408);color:var(--caution);
    padding:7px 13px;font:700 .76rem/1.2 "Avenir Next Condensed","Arial Narrow",sans-serif;
    letter-spacing:.16em;text-transform:uppercase;cursor:pointer;white-space:nowrap;
    text-decoration:none;display:inline-block;max-width:100%;overflow:hidden;text-overflow:ellipsis;
    box-shadow:inset 0 1px 0 rgba(255,255,255,.06), 0 1px 0 rgba(0,0,0,.5);}
  .btn::before{content:"▸ ";}
  .btn:hover{background:#2b2312;}
  .btn:focus-visible{outline:2px solid var(--caution);outline-offset:2px;}
  .btn.subtle{border-color:var(--etch);color:var(--ghost);background:var(--panel2);}
  .more{border:none;background:none;color:var(--stencil);font:700 1.05rem/1 inherit;cursor:pointer;padding:6px;}
  .more:hover{background:var(--panel2);color:var(--white);}
  .more:focus-visible{outline:2px solid var(--caution);outline-offset:1px;}

  /* the lifecycle menu */
  .menu{position:absolute;right:10px;top:44px;z-index:9;background:var(--panel2);border:1px solid var(--etch);
    box-shadow:0 8px 24px rgba(0,0,0,.5);min-width:230px;padding:6px;display:none;}
  .menu.open{display:block;}
  li:has(> .menu.open){z-index:10;}
  .menu button{display:block;width:100%;text-align:left;background:none;border:none;color:var(--white);
    font:500 .9rem/1.4 inherit;padding:8px 10px;cursor:pointer;}
  .menu button small{display:block;color:var(--stencil);font-size:.78rem;}
  .menu button:hover{background:var(--bezel);}
  .menu button.retire{color:#C06443;}
  .menu hr{border:none;border-top:1px solid var(--etch);margin:6px 4px;}
  .quiet .menu,.shelf .menu{top:34px;}

  .quiet li{display:grid;grid-template-columns:38px 168px 1fr 34px;gap:13px;align-items:center;
    padding:8px 14px 8px 0;border-bottom:1px solid var(--bezel);color:var(--ghost);position:relative;}
  .quiet .stat{border-right:none;background:none;}
  .quiet .stat .ind{background:var(--go);box-shadow:0 0 8px rgba(105,185,140,.5);}
  .quiet .stat span{color:#4c7a63;}
  .quiet li .init{color:var(--white);font-weight:550;}

  .shelf{margin-top:30px;border:1px dashed var(--etch);padding:2px 16px 10px;}
  .shelf h2{margin-top:12px;}
  .shelf li{display:grid;grid-template-columns:168px 1fr 110px 34px;gap:13px;align-items:center;
    padding:8px 0;color:var(--stencil);border-bottom:1px solid #151b24;position:relative;}
  .shelf li:last-child{border-bottom:none;}
  .shelf li .init{color:var(--ghost);font-weight:550;}
  .shelf .btn{border-color:var(--etch);color:var(--ghost);background:var(--panel2);}
  .shelf .btn::before{content:"↺ ";}

  /* umbrella children fold indented under their parent row */
  li.child .init{padding-left:18px;position:relative;}
  li.child .init::before{content:'\\21B3';position:absolute;left:0;color:var(--stencil);font-weight:400;}

  /* per-row note editor */
  .note{display:flex;gap:8px;align-items:flex-start;margin-top:6px;}
  li.ask .note{grid-column:2/-1;padding-right:14px;}
  .quiet .note{grid-column:2/-1;margin:2px 0 8px;padding-right:14px;}
  .shelf .note{grid-column:1/-1;margin:2px 0 8px;}
  .note textarea{flex:1;min-height:34px;max-height:120px;resize:vertical;border:1px solid var(--etch);
    background:var(--lamp-off);color:var(--white);padding:6px 10px;font:inherit;font-size:.9rem;}

  /* queued-for-pickup send feedback */
  .sent{grid-column:3/-1;font-size:.78rem;color:var(--go);padding-top:2px;letter-spacing:.06em;
    text-transform:uppercase;font-family:ui-monospace,"SF Mono",Menlo,monospace;}
  .sent::before{content:"● ";}
  .quiet .sent,.shelf .sent{grid-column:2/-1;}

  footer.plate{margin-top:36px;display:flex;justify-content:space-between;align-items:center;
    color:var(--stencil);font-size:.66rem;letter-spacing:.22em;text-transform:uppercase;
    font-family:"Avenir Next Condensed","Arial Narrow",sans-serif;border-top:1px solid var(--bezel);padding-top:12px;}
  footer.plate .go{color:var(--go);}

  .empty{color:var(--ghost);margin:32px 0;}
  .toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:var(--panel2);border:1px solid var(--etch);
    color:var(--white);padding:8px 16px;font-size:.85rem;opacity:0;transition:opacity .2s;pointer-events:none;}
  .toast.show{opacity:.95;}

  /* doc pages */
  .doc-wrap{max-width:860px;margin:0 auto;padding:10px 32px 40px;}
  .doc-body{background:var(--panel);border:1px solid var(--bezel);padding:20px 24px;}
  .doc-body pre{overflow-x:auto;background:var(--lamp-off);padding:10px;}
  .doc-body code{background:var(--lamp-off);padding:1px 4px;}
  .doc-body a{color:var(--caution);}
  a.back{display:inline-block;margin:16px 0 12px;color:var(--caution);text-decoration:none;font-size:.85rem;}

  @media (max-width:800px){
    li.ask{grid-template-columns:38px 1fr 96px;}
    li.ask .init{grid-column:2/-1;}
    .cw{grid-template-columns:repeat(2,116px);}
  }
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

  // Days an ask has waited on the captain; hot from the 7-day limit up.
  function age(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return { days: null, hot: false };
    const days = Math.max(0, Math.floor((Date.now() - t) / 86400000));
    return { days, hot: days >= 7 };
  }

  function shortDate(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return '';
    return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
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
    const box = el('span', 'sent', mine ? mine.text : 'Queued \\u2014 picked up on the next pass');
    box.title = 'Queued for pickup \\u2014 picked up on the next pass, not instant.';
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
      // A long label truncates with an ellipsis inside its column; the full
      // label stays readable on hover.
      a.title = link.label;
      a.href = link.href;
      if (link.kind === 'external') {
        a.target = '_blank';
        a.rel = 'noopener';
      }
      cell.appendChild(a);
    }
    return cell;
  }

  // Status block: indicator lamp plus stencil word (warn/caut on asks, go on
  // quiet rows), per the flight-ops contract.
  function statCell(word) {
    const s = el('span', 'stat');
    s.appendChild(el('span', 'ind'));
    s.appendChild(el('span', null, word));
    return s;
  }

  // Labeled days-waiting meter: value, 0-14 track filling with the wait, and
  // the tick at the 7-day limit.
  function meterCell(card, a) {
    const m = el('span', 'meter');
    m.title = 'How long this has waited on you; the tick marks the 7-day limit';
    const row1 = el('span', 'row1');
    row1.appendChild(el('span', 'label', 'Days waiting'));
    const val = el('span', 'val mono', a.days === null ? '\\u2014' : String(a.days));
    val.title = card.updated;
    row1.appendChild(val);
    m.appendChild(row1);
    const track = el('span', 'track');
    const fill = el('i');
    const pct = a.days === null ? 0 : Math.max(3, Math.min(100, Math.round((a.days / 14) * 100)));
    fill.style.width = pct + '%';
    track.appendChild(fill);
    track.appendChild(el('em'));
    m.appendChild(track);
    const scale = el('span', 'scale mono');
    for (const s of ['0', '7', '14']) scale.appendChild(el('span', null, s));
    m.appendChild(scale);
    return m;
  }

  function askRow(card, child) {
    const a = age(card.updated);
    const li = el('li', 'ask' + (a.hot ? ' hot' : '') + (child ? ' child' : ''));
    li.appendChild(statCell(a.hot ? 'warn' : 'caut'));
    li.appendChild(el('span', 'init', card.title));
    const ask = askOf(card);
    const what = el('span', 'what', ask.main);
    if (ask.sub) what.appendChild(el('small', null, ask.sub));
    li.appendChild(what);
    li.appendChild(meterCell(card, a));
    li.appendChild(actionCell(card));
    rowMenu(card, li);
    if (openNotes.has(card.slug)) li.appendChild(noteEditor(card));
    const fb = feedbackLine(card);
    if (fb) li.appendChild(fb);
    return li;
  }

  function quietRow(card, child) {
    const li = el('li', child ? 'child' : null);
    li.appendChild(statCell('go'));
    li.appendChild(el('span', 'init', card.title));
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

  function zoneHeading(title, subtitle) {
    const h = el('h2');
    h.appendChild(el('span', 'tag stencil', title));
    h.appendChild(el('small', 'mono', subtitle));
    return h;
  }

  function lamp(cls, label, count, title) {
    const d = el('div', 'lamp' + (cls ? ' ' + cls : ''));
    d.title = title;
    d.appendChild(document.createTextNode(label));
    d.appendChild(el('b', null, String(count)));
    return d;
  }

  // The caution-and-warning header panel: overdue (past the 7-day limit),
  // needs-you, nominal, and stowed counts; a lamp lights only when its count
  // is live, and the stowed lamp stays unlit per the contract.
  function renderLamps(asks, quiet, shelf) {
    const cw = document.getElementById('lamps');
    cw.textContent = '';
    const overdue = asks.filter((c) => age(c.updated).hot).length;
    cw.appendChild(lamp(overdue ? 'warn' : '', 'Overdue', overdue, 'Waiting on you longer than the 7-day limit'));
    cw.appendChild(lamp(asks.length ? 'caution' : '', 'Needs you', asks.length, 'Decisions and merges only you can do'));
    cw.appendChild(lamp(quiet.length ? 'go' : '', 'Nominal', quiet.length, 'Crews working, nothing for you'));
    cw.appendChild(lamp('', 'Stowed', shelf.length, 'Shelved until you re-engage'));
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
    renderLamps(asks, quiet, shelf);

    root.appendChild(zoneHeading('Needs you',
      asks.length ? 'OLDEST FIRST \\u00b7 LIMIT 7 DAYS' : 'NOTHING WAITING ON YOU'));
    if (asks.length) {
      const ul = el('ul');
      for (const r of foldGroups(asks)) ul.appendChild(askRow(r.card, r.child));
      root.appendChild(ul);
    }

    if (quiet.length) {
      root.appendChild(zoneHeading('Nominal', 'CREWS WORKING \\u00b7 NOTHING FOR YOU'));
      const wrap = el('div', 'quiet');
      const ul = el('ul');
      for (const r of foldGroups(quiet)) ul.appendChild(quietRow(r.card, r.child));
      wrap.appendChild(ul);
      root.appendChild(wrap);
    }

    if (shelf.length) {
      const wrap = el('div', 'shelf');
      wrap.appendChild(zoneHeading('Stowed', 'ONE CLICK BACK'));
      const ul = el('ul');
      for (const r of foldGroups(shelf)) ul.appendChild(shelfRow(r.card, r.child));
      wrap.appendChild(ul);
      root.appendChild(wrap);
    }

    if (!cards.length) root.appendChild(el('div', 'empty', 'No initiatives yet.'));
    restoreFocus(focused);
  }

  const shortToday = new Date()
    .toLocaleDateString('en-US', { month: 'short', day: 'numeric' }).toUpperCase();
  const flightDate = document.getElementById('flightdate');
  if (flightDate) flightDate.textContent = shortToday;
  const revPlate = document.getElementById('revplate');
  if (revPlate) revPlate.textContent = 'PANEL REV C \\u00b7 ' + shortToday;

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
<title>MISSION CONTROL — flight ops</title>
<style>${PAGE_CSS}</style>
</head>
<body>
<div class="wrap">
<header class="frame"><span class="fb"></span>
  <div class="ident">
    <h1><span class="stencil">Mission Control</span></h1>
    <div class="met mono" id="flightdate"></div>
  </div>
  <div class="cw" id="lamps" role="status" aria-label="fleet status summary"></div>
</header>
<div class="subplate"><span>UNIT 01</span><span>ALL SYSTEMS REPORTING</span></div>
<div id="board"></div>
<footer class="plate"><span>FIRSTMATE</span><span class="go">GO FLIGHT</span><span id="revplate">PANEL REV C</span></footer>
</div>
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
