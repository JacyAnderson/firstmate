#!/usr/bin/env bash
# fm-mission-control-seed.sh - build Mission Control initiative stubs from the
# open backlog of the active FM_HOME.
#
# Usage:
#   fm-mission-control-seed.sh [--dry-run]
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
# pending decision; every other open item seeds status active.
#
# Refuses (exit 1) when the backlog backend is manual, tasks-axi is missing,
# incompatible, or its listing fails, or python3 (the parser) is absent.
# --dry-run prints what would be created without writing anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

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
if ! LISTING=$( (cd "$FM_HOME" && tasks-axi list --fields held,hold_kind,hold_reason) 2>"$LIST_ERR" ); then
  echo "error: tasks-axi list failed: $(tr '\n' ' ' < "$LIST_ERR")" >&2
  rm -f "$LIST_ERR"
  exit 1
fi
rm -f "$LIST_ERR"

# Parse the tasks-axi listing (CSV rows indented under the tasks[...] header)
# into tab-separated records: id, state, title, held, hold_kind, hold_reason.
# Tabs inside free text are flattened to spaces so the record stays parseable.
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
            if len(rec) < 8:
                continue
            tid, state, _kind, _repo, title, held, hold_kind, hold_reason = rec[:8]
            clean = lambda s: s.replace("\t", " ").replace("\r", " ")
            print("\t".join(clean(f) for f in (tid, state, title, held, hold_kind, hold_reason)))
    elif rows and not line.startswith("  "):
        rows = False
'
}

slug_of() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-64
}

created=0
skipped=0
registry_added=0

ensure_registry_header() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -f "$REGISTRY" ] || printf '# Mission Control registry\n' > "$REGISTRY"
}

while IFS=$(printf '\t') read -r id state title held hold_kind hold_reason; do
  [ -n "$id" ] || continue
  slug=$(slug_of "$id")
  if ! printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
    echo "skipping $id: cannot derive a valid slug" >&2
    continue
  fi
  [ -n "$title" ] || title=$id
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
  card="$INITIATIVES/$slug.md"
  if [ -e "$card" ]; then
    skipped=$((skipped + 1))
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
      printf 'work-items: %s\n' "$id"
      [ -z "$decision" ] || printf 'decision: %s\n' "$decision"
      printf -- '---\n'
      printf '%s\n\n' "$latest"
      printf '## History\n- %s: card seeded from the open backlog\n' "$NOW"
    } > "$card" || exit 1
    echo "created: $card ($status)"
    created=$((created + 1))
  fi
  if [ -f "$REGISTRY" ] && grep -Fq -- "- $slug:" "$REGISTRY"; then
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
echo "seed: $verb $created card(s), $skipped already present, $registry_added registry entr(y/ies) added"
