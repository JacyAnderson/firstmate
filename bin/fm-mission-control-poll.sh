#!/usr/bin/env bash
# One cheap poll of the mission-control inbox for the watcher.
#
# Contract: output => wake firstmate, silence => keep sleeping. The watcher
# runs this through the registered state/mission-control.check.sh shim
# (installed by fm-mission-control.sh; AGENTS.md section 7's custom-check
# contract), so the wake arrives as a check: event handled under the
# mission-control skill.
#
# This script lists inbox file NAMES only - it never reads, parses, or
# executes captain-provided message content. Slugs are recovered from the
# <epoch-ms>-<seq>-<slug>.msg naming contract (docs/mission-control.md);
# files that do not match it are counted and reported rather than silently
# ignored, so a malformed drop can never rot invisibly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INBOX="$STATE/mission-control/inbox"

[ -d "$INBOX" ] || exit 0

count=0
unrecognized=0
slugs=

for f in "$INBOX"/*.msg; do
  [ -e "$f" ] || continue
  count=$((count + 1))
  name=$(basename "$f" .msg)
  slug=""
  case "$name" in
    [0-9]*-*)
      slug=$(printf '%s' "$name" | sed -E 's/^[0-9]+-[0-9]+-//')
      ;;
  esac
  case "$slug" in
    [a-z0-9]*)
      if printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
        case " $slugs " in
          *" $slug "*) ;;
          *) slugs="$slugs $slug" ;;
        esac
      else
        unrecognized=$((unrecognized + 1))
      fi
      ;;
    *) unrecognized=$((unrecognized + 1)) ;;
  esac
done

[ "$count" -gt 0 ] || exit 0

line="mission-control inbox: $count pending for:${slugs:- (none)}"
if [ "$unrecognized" -gt 0 ]; then
  line="$line ($unrecognized unrecognized file names)"
fi
printf '%s\n' "$line"
