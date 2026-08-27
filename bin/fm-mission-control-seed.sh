#!/usr/bin/env bash
# fm-mission-control-seed.sh - build Mission Control initiative stubs from the
# open backlog of the active FM_HOME.
#
# Usage:
#   fm-mission-control-seed.sh [--dry-run] [--fix-titles]
#   fm-mission-control-seed.sh -h | --help
#
# For every open backlog item (queued, in flight, or held) reported by a
# compatible tasks-axi backend, this creates a stub initiative card at
# data/mission-control/initiatives/<slug>.md and a registry entry in
# data/mission-control/registry.md, both only when absent - existing cards and
# entries are never rewritten, so re-running is safe. docs/mission-control.md
# owns the file schemas.
#
# Mapping: the slug is the backlog id normalized to the slug charset; a
# captain-kind hold seeds status waiting-on-you with the hold reason as the
# pending decision; every other open item seeds status active. The backlog
# repo field seeds the card's area, the backlog priority (0-4) seeds the
# card's priority, and an id of the form <parent>-decision-<rest> seeds
# umbrella: <parent>, so decision cards spawned by one initiative group under
# it on the board.
#
# The listing is used only to enumerate ids and states; titles, hold reasons,
# and the other free-text fields come from `tasks-axi show <id> --full`, whose
# values are complete and machine-quoted, never the listing's display-oriented
# cells (which truncate and escape long text). The detail fetch runs only for
# items that still need a card or registry entry, so re-runs stay cheap.
#
# --fix-titles additionally repairs existing cards and registry entries whose
# title still carries the listing's literal truncation marker from earlier
# seed versions, replacing only the title text; nothing else in the card is
# touched.
#
# Refuses (exit 1) when the backlog backend is manual, tasks-axi is missing,
# incompatible, or its listing fails, or python3 (the parser) is absent.
# --dry-run prints what would be created or fixed without writing anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

DRY_RUN=0
FIX_TITLES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --fix-titles) FIX_TITLES=1 ;;
    -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$(fm_backlog_backend_value "$CONFIG_DIR")" != manual ] \
  || { echo "error: backlog backend is manual; nothing to seed from" >&2; exit 1; }
fm_tasks_axi_compatible \
  || { echo "error: compatible tasks-axi not found (npm install -g tasks-axi)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required to parse the backlog listing" >&2; exit 1; }

INITIATIVES="$FM_HOME/data/mission-control/initiatives"
REGISTRY="$FM_HOME/data/mission-control/registry.md"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Capture the listing up front so a tasks-axi failure stops the seed with its
# error instead of reading an empty stream and reporting a zero-card success.
LIST_ERR=$(mktemp)
if ! LISTING=$( (cd "$FM_HOME" && tasks-axi list) 2>"$LIST_ERR" ); then
  echo "error: tasks-axi list failed: $(tr '\n' ' ' < "$LIST_ERR")" >&2
  rm -f "$LIST_ERR"
  exit 1
fi
rm -f "$LIST_ERR"

# Parse the tasks-axi listing (CSV rows indented under the tasks[...] header)
# into tab-separated id/state pairs. Only these two leading columns are read:
# they precede every free-text column, so a title that confuses the CSV
# quoting cannot shift them.
list_open_items() {
  printf '%s\n' "$LISTING" \
    | python3 -c '
import csv, io, sys

rows = False
for line in sys.stdin:
    if line.startswith("tasks["):
        rows = True
        continue
    if rows and line.startswith("  ") and line.strip():
        for rec in csv.reader(io.StringIO(line.strip())):
            if len(rec) < 2:
                continue
            clean = lambda s: s.replace("\t", " ").replace("\r", " ")
            print("\t".join(clean(f) for f in rec[:2]))
    elif rows and not line.startswith("  "):
        rows = False
'
}

# Full, unmangled fields for one item, as one tab-separated line:
# title, repo, priority, held, hold_kind, hold_reason. `tasks-axi show`
# machine-quotes free text (JSON string syntax), so long titles and titles
# with quotes arrive intact; "-" placeholders normalize to empty fields.
item_details() {
  (cd "$FM_HOME" && tasks-axi show "$1" --full 2>/dev/null) \
    | python3 -c '
import json, sys

wanted = ("title", "repo", "priority", "held", "hold_kind", "hold_reason")
fields = {}
for line in sys.stdin:
    if not line.startswith("  "):
        continue
    key, sep, value = line.rstrip("\n")[2:].partition(": ")
    if not sep or key not in wanted or key in fields:
        continue
    if value.startswith("\""):
        try:
            value = json.loads(value)
        except ValueError:
            pass
    fields[key] = value

# Empty fields ship as the "-" placeholder: bash read collapses consecutive
# tab separators, so a genuinely empty field would shift every later column.
clean = lambda s: s.replace("\t", " ").replace("\r", " ").replace("\n", " ")
print("\t".join(clean(fields.get(k) or "-") for k in wanted))
'
}

slug_of() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-64
}

# The literal truncation marker an earlier seed version copied from the
# listing into card and registry titles.
MANGLED_RE='truncated, [0-9]+ chars total - use show .* --full to see complete text\)'

title_mangled() {
  sed -n 's/^title: //p' "$1" | grep -Eq "$MANGLED_RE"
}

# Replace only the title text: the card's "title: ..." frontmatter line, or
# the registry's "- <slug>: ..." entry line (second argument selects a slug).
rewrite_title_line() {
  python3 - "$@" <<'PY'
import sys

path, title = sys.argv[1], sys.argv[2]
slug = sys.argv[3] if len(sys.argv) > 3 else ""
prefix = f"- {slug}: " if slug else "title: "
lines = open(path, encoding="utf-8").read().split("\n")
for i, line in enumerate(lines):
    if line.startswith(prefix):
        lines[i] = prefix + title
        break
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

created=0
skipped=0
registry_added=0
fixed=0

ensure_registry_header() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -f "$REGISTRY" ] || printf '# Mission Control registry\n' > "$REGISTRY"
}

while IFS=$(printf '\t') read -r id state; do
  [ -n "$id" ] || continue
  slug=$(slug_of "$id")
  if ! printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
    echo "skipping $id: cannot derive a valid slug" >&2
    continue
  fi
  card="$INITIATIVES/$slug.md"
  card_present=0
  [ -e "$card" ] && card_present=1
  registry_present=0
  [ -f "$REGISTRY" ] && grep -Fq -- "- $slug:" "$REGISTRY" && registry_present=1
  needs_fix=0
  if [ "$FIX_TITLES" -eq 1 ] && [ "$card_present" -eq 1 ] && title_mangled "$card"; then
    needs_fix=1
  fi
  if [ "$card_present" -eq 1 ] && [ "$registry_present" -eq 1 ] && [ "$needs_fix" -eq 0 ]; then
    skipped=$((skipped + 1))
    continue
  fi

  IFS=$(printf '\t') read -r title repo priority held hold_kind hold_reason \
    <<< "$(item_details "$id")"
  [ "$repo" = - ] && repo=
  [ "$priority" = - ] && priority=
  [ "$hold_reason" = - ] && hold_reason=
  [ -n "$title" ] && [ "$title" != - ] || title=$id
  case "$priority" in [0-4]) ;; *) priority= ;; esac
  umbrella=
  case "$id" in
    *-decision-?*)
      umbrella=$(slug_of "${id%-decision-*}")
      printf '%s' "$umbrella" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$' || umbrella=
      ;;
  esac
  status=active
  decision=
  latest="Work is under way; no board update recorded yet."
  case "$state" in
    queued) latest="Queued; work has not started yet." ;;
  esac
  if [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    status=waiting-on-you
    decision=$hold_reason
    latest="A decision is waiting on you: $hold_reason"
  fi

  if [ "$needs_fix" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would fix title: $card"
    else
      rewrite_title_line "$card" "$title" || exit 1
      echo "fixed title: $card"
    fi
    fixed=$((fixed + 1))
    if [ "$registry_present" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] \
      && grep -F -- "- $slug: " "$REGISTRY" 2>/dev/null | grep -Eq "$MANGLED_RE"; then
      rewrite_title_line "$REGISTRY" "$title" "$slug" || exit 1
    fi
  fi

  if [ "$card_present" -eq 1 ]; then
    [ "$needs_fix" -eq 1 ] || skipped=$((skipped + 1))
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "would create: $card ($status)"
    created=$((created + 1))
  else
    mkdir -p "$INITIATIVES" || exit 1
    {
      printf -- '---\n'
      printf 'title: %s\n' "$title"
      printf 'status: %s\n' "$status"
      printf 'updated: %s\n' "$NOW"
      [ -z "$repo" ] || printf 'area: %s\n' "$repo"
      [ -z "$umbrella" ] || printf 'umbrella: %s\n' "$umbrella"
      [ -z "$priority" ] || printf 'priority: %s\n' "$priority"
      printf 'work-items: %s\n' "$id"
      [ -z "$decision" ] || printf 'decision: %s\n' "$decision"
      printf -- '---\n'
      printf '%s\n\n' "$latest"
      printf '## History\n- %s: card seeded from the open backlog\n' "$NOW"
    } > "$card" || exit 1
    echo "created: $card ($status)"
    created=$((created + 1))
  fi

  if [ "$registry_present" -eq 1 ]; then
    :
  elif [ "$DRY_RUN" -eq 1 ]; then
    registry_added=$((registry_added + 1))
  else
    ensure_registry_header
    {
      printf -- '- %s: %s\n' "$slug" "$title"
      printf '  - work-items: %s\n' "$id"
      printf '  - decisions: %s\n' "${decision:--}"
      printf '  - sessions: -\n'
    } >> "$REGISTRY" || exit 1
    registry_added=$((registry_added + 1))
  fi
done < <(list_open_items)

verb=created
[ "$DRY_RUN" -eq 1 ] && verb="would create"
summary="seed: $verb $created card(s), $skipped already present, $registry_added registry entr(y/ies) added"
[ "$FIX_TITLES" -eq 0 ] || summary="$summary, $fixed title(s) fixed"
echo "$summary"
