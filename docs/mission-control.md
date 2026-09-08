# Mission Control

Mission Control is a small always-listening local status board for the captain: one row per initiative, sorted into what needs the captain, what runs quietly, and what sits shelved, each row carrying the latest plain-language update, a direct link to its actionable thing, and a lifecycle menu.
This document is the single owner of Mission Control's file schemas, the registry format, the inbox event format, and the board's wire contract.
Launch, stop, and check-installation mechanics live in `bin/fm-mission-control.sh --help`; seeding mechanics live in `bin/fm-mission-control-seed.sh --help`; the agent-facing write contract lives in the `mission-control` skill.

## Design

State lives in files, never in the server.

- `data/mission-control/initiatives/<slug>.md` - one durable card per initiative, written by firstmate, rendered by the server.
- `data/mission-control/registry.md` - firstmate's durable map from each initiative to the work items, decisions, and sessions under it.
- `state/mission-control/inbox/` - file-queued captain input written by the server, drained by firstmate on watcher check wakes.
- `state/mission-control/` also holds the server's own runtime records (pid file, log).

The server renders and queues; it never mutates initiatives, the registry, the backlog, or any work state.
Captain actions (messages, park, re-engage, drop) land as inbox event files, so firstmate executes them through its normal safety rails on the next wake.
If the server dies, durable state is intact and pending messages stay queued in files; a restart shows everything.

## Slugs

An initiative slug must match `^[a-z0-9][a-z0-9-]{0,63}$`.
Every component (server, poll script, seed helper) validates slugs against this pattern and refuses anything else, so a slug is always safe as a file name component.

## Initiative file schema

`data/mission-control/initiatives/<slug>.md`:

```
---
title: Fix the flaky login tests
status: waiting-on-you
updated: 2026-08-26T17:40:00Z
area: acme-web
priority: 1
work-items: login-flake-f3, login-flake-audit-a1
decision: Should Safari 16 stay supported?
link: fix PR https://github.com/acme/web/pull/412
link: investigation report data/login-flake-audit-a1/report.md
---
The fix is in review with checks passing.
One decision is waiting on you: whether Safari 16 stays supported.

## History
- 2026-08-26T17:40:00Z: fix PR opened, checks green
- 2026-08-26T15:02:00Z: investigation confirmed the race in session refresh
```

Frontmatter is a block of `key: value` lines between two `---` lines, parsed line by line (no YAML nesting).

- `title` (required) - the initiative in the captain's own words.
- `status` (required) - `active`, `waiting-on-you`, or `parked`; an unknown value renders as `active`.
- `updated` (required) - ISO 8601 UTC timestamp of the last update write; drives card sorting.
- `area` (optional) - the repo or focus area the initiative belongs to; card data only, not a rendered grouping.
  The seed fills it from the backlog item's repo field.
- `umbrella` (optional) - the slug of a parent initiative; a child row folds indented under its parent's row when both sit in the same board zone.
  A card whose own slug equals the umbrella value is the group's head card.
  The seed derives it from backlog ids of the form `<parent>-decision-<rest>`; firstmate sets it directly for other parent-child shapes.
- `priority` (optional) - the backlog priority 0-4 (0 most urgent), copied from the backlog item when present; card data only, no longer part of the ordering rule below.
- `work-items` (optional) - comma-separated backlog item ids linked to this initiative.
- `decision` (optional, repeatable) - one pending captain decision per line; the first leads the row's ask text on the board, and any decision line places the card in the needs-you zone.
- `link` (optional, repeatable) - `<label> <target>`, where the target is the last whitespace-separated token and the label is everything before it.
  A target starting with `https://` or `http://` renders as an external link (a PR, an MR, a dashboard).
  Any other target is a path relative to the home that must resolve under `data/`; the board renders that markdown file as HTML itself, so acting on a card never requires the terminal.

The body above the first `## History` heading is the latest update: two to three sentences in plain outcome language (AGENTS.md section 9), no internal vocabulary.
The `## History` section is the running history, newest entry first; phase 1 keeps it in the file without rendering it on the card.

## Registry format

`data/mission-control/registry.md` maps each initiative to the work under it:

```
# Mission Control registry

- fix-login-flakes: Fix the flaky login tests
  - work-items: login-flake-f3, login-flake-audit-a1
  - decisions: safari-16-support
  - sessions: -
```

One top-level `- <slug>: <title>` entry per initiative, with indented `work-items`, `decisions` (durable decision keys or short summaries, `-` when none), and `sessions` (session or task references, `-` when none) lines.
The registry is firstmate's navigation record; the board renders cards from initiative files only and never reads or writes the registry.

## Inbox event format

Each captain action on a card becomes one file, `state/mission-control/inbox/<epoch-ms>-<seq>-<slug>.msg`, where `<epoch-ms>` is the server's millisecond timestamp and `<seq>` is a per-process sequence number that keeps same-millisecond names unique:

```
kind: message
slug: fix-login-flakes
ts: 2026-08-26T17:41:03.214Z

Ship it without Safari 16 support.
```

`kind` is one of `message`, `park`, `re-engage`, or `drop`; the body after the blank line is present only for `message`.
Member events of one group action are all stamped with a single timestamp captured before the batch, so their `<epoch-ms>` name component and `ts` values match and a same-kind same-timestamp burst reliably reads as one captain action.
Inbox files are data and are never executed by anything.
Firstmate reads each file, acts on it under the `mission-control` skill, and deletes it; unprocessed files stay queued and are never lost, even across a server or firstmate crash.

## Server wire contract

The server binds `127.0.0.1` only and serves nothing beyond its own page, the card data, and the renderings described here.
Every request must carry a `Host` header of `127.0.0.1:<port>` or `localhost:<port>`; anything else is 403, which shuts out DNS-rebinding access.
The POST endpoints additionally require a `Content-Type` of `application/json` (415 otherwise), so a cross-origin page cannot queue inbox events with a no-preflight simple request.
A request target that fails URL parsing is refused with 400 rather than taking the server down.
A POST body that does not parse as a JSON object (malformed JSON, `null`, a string, an array) is refused with 400 before any field is read.

- `GET /` - the board page; it polls for card updates itself, so the captain refreshes nothing manually.
- `GET /api/cards` - JSON `{"cards": [...]}` with one object per initiative file: `slug`, `title`, `status`, `updated`, `area`, `umbrella`, `priority` (0-4 or null), `workItems`, `decisions`, `links` (each `{label, href, kind}` with `kind` `external` or `doc`), and `latest` (the latest-update text).
  The array is sorted by the ordering rule below; consumers may rely on that order.
- `POST /api/message` - JSON `{"slug", "text"}`; appends a `message` inbox event; 400 on an invalid slug or empty text.
- `POST /api/action` - JSON `{"slug", "action"}` with action `park`, `re-engage`, or `drop`; appends the matching inbox event; 400 otherwise.
- `POST /api/group-action` - JSON `{"slugs": [...], "action"}` with the same three actions; appends one ordinary per-slug inbox event for each listed slug, so group actions need no new inbox kind and membership is fixed by the explicit list the caller sent - a card that joins the group later is never swept in.
  The whole batch is validated first (every slug valid, 1-200 entries); any bad entry is 400 with nothing written, and duplicate slugs collapse to one event.
- `GET /doc/<slug>/<n>` - renders the initiative's n-th local `link:` target as HTML.
  The path comes from the server's own parse of the initiative file, never from the client, and must resolve (symlinks included) under the home's `data/` directory; anything else is 404.

Every board action, including drop, acts immediately as an inbox event on one click: the click is intent, and firstmate applies its normal safety rails when acting on the event.
Each action button is disabled while its request is in flight, so a rapid double click cannot queue duplicate events.
The board itself no longer surfaces group-level controls; `POST /api/group-action` remains part of the wire contract for other consumers.

## Ordering and zones

A card has an ask when its status is `waiting-on-you` or it carries any `decision:` line; a parked card never counts as an ask.
`GET /api/cards` returns cards sorted by need, most captain-attention first:

1. Zone rank: cards with an ask, then quiet `active` cards, then `parked`.
2. Within the ask zone: `updated` oldest first, so the longest-waiting ask tops the board.
3. Within the other zones: `updated` newest first.
4. The slug as a stable tie-break.

The board (the owner-approved Command Deck rendering) cuts three zones straight from that order, one row per initiative:

- **Needs you** - one row per initiative with an ask: title, the ask in plain language (the first `decision:` line, else the latest update), the age since `updated:` (red from 7 days), the first `link:` as an action button, and the lifecycle menu.
- **Running quietly** - one-liner rows for active initiatives with no ask: title, status dot, latest-update snippet, and the menu.
- **Shelf** - a dashed box of dimmed one-liners for parked initiatives, each with a Re-engage button and its shelved date from `updated:`.

Every row's menu offers Send a note (opens the per-initiative message box, a `message` event), Shelve (a `park` event), and Retire (a `drop` event, one click).
Umbrella children fold indented under their parent's row within a zone; a child whose parent sits in another zone renders as its own row, so an ask is never hidden inside a quiet group.
Work items stay card data and never render as their own rows, which keeps the board calm at ten initiatives.

## Watcher integration

The inbox check follows the standard custom-check contract from AGENTS.md section 7: a mode-0700 shim at `state/mission-control.check.sh` whose bytes are bound by `bin/fm-check-register.sh mission-control`, so the watcher runs it from a hash-validated private snapshot.
The shim only dispatches the trusted repository script `bin/fm-mission-control-poll.sh`, which lists inbox file names (it never reads or executes captain-provided content) and prints one line naming the initiatives with pending input; silence means no wake.
`bin/fm-mission-control.sh start` installs and registers the shim; the resulting wake arrives as a `check:` event and is handled under the `mission-control` skill.

## Notifications

Notifications are board-only by captain decision (2026-08-26): no operating-system alerts; waiting-on-you sorting is the attention mechanism.

## Future work (phase 2, out of scope)

- Decision asks deep-linking to their decision records.
- A per-card history view rendering the `## History` section.
- Unread markers for updates the captain has not seen.
