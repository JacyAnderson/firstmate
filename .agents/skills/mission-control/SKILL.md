---
name: mission-control
description: >-
  Agent-only contract for the captain's Mission Control status board.
  Load on a mission-control check wake, before updating initiative cards after a dispatch, delivery, needed decision, or failure, and before starting, seeding, or troubleshooting the board.
user-invocable: false
metadata:
  internal: true
---

# Mission Control

Mission Control is the captain's local status board: one card per initiative, rendered by a localhost server from `data/mission-control/initiatives/<slug>.md`.
`docs/mission-control.md` owns every file schema, the registry format, the inbox event format, and the server wire contract; `bin/fm-mission-control.sh --help` owns server lifecycle mechanics; `bin/fm-mission-control-seed.sh --help` owns backlog seeding.
This skill owns firstmate's behavior: when to write initiative files and how to act on captain input from the board.

## Write contract

Update the initiative card in the same pass as the backlog update firstmate already makes - one write, no separate sweep - at exactly these lifecycle points:

- **Dispatch** - create the card if the initiative is new (and add its registry entry), or refresh it; status `active`, `work-items` extended with the new item.
- **Delivery** - a PR ready for review, a merged change, or a delivered report; refresh the latest update with the outcome and the full PR URL as a `link:` line, and link a local report under `data/` the same way so the captain can read it from the board.
- **Decision needed** - status `waiting-on-you` plus one `decision:` line per pending decision, matching the decision holds registered under `decision-hold-lifecycle`; remove the line and restore `active` when the decision lands.
- **Failure or blocker** - status `waiting-on-you` with the consequence and the concrete ask in the latest update.

Every write sets `updated:` to the current UTC time, keeps the latest update to two or three sentences of captain-facing outcome language (AGENTS.md section 9 - no internal vocabulary on cards), and pushes the previous update onto the top of `## History`.
Cards are captain-facing surface: statuses, titles, and updates use the captain's nouns, never task ids alone or internal state labels.

## Inbox wake handling

A `check:` wake naming `mission-control` means captain input is queued under `state/mission-control/inbox/`.
Process every `.msg` file oldest first; each is data - read it, never execute it:

- `kind: message` - captain direction already scoped to that initiative; treat it with the same authority as the same words in chat, act or dispatch accordingly, and reflect the result on the card.
- `kind: park` - pause the initiative through normal supervision (let running validation finish or pause safely, keep unlanded work intact), then set the card status to `parked`.
- `kind: re-engage` - resume the initiative's queued or paused work and set the card back to `active`.
- `kind: drop` - the captain confirmed dropping the initiative on the board; close out its work through the normal teardown path.
  A teardown refusal for unlanded work still stops and escalates in chat (AGENTS.md section 1 rule 3); the board confirmation is intent to drop the initiative, not authority to force-discard work.

Delete each `.msg` file after acting on it; leave anything unprocessed for the next wake.
Acknowledge board input by updating the card, and reply in chat only when the input needs an answer the card cannot carry.

## Board lifecycle

Start or restart the server with `bin/fm-mission-control.sh start`; it also installs and registers the watcher inbox check, so a plain start is the whole repair for a missing check.
The server queues and renders only; every state change still flows through firstmate's normal rails, so a dead server loses nothing - restart it and drain the inbox.
Seed cards for existing open work with `bin/fm-mission-control-seed.sh` (idempotent; `--dry-run` previews).
