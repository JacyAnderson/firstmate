#!/usr/bin/env bash
# Behavior tests for bin/fm-mission-control-seed.sh: initiative stubs and
# registry entries built from a compatible tasks-axi backlog listing, hold
# mapping to waiting-on-you, idempotence, dry-run, full titles taken from
# `show --full` instead of the truncating listing, repo/priority/umbrella
# mapping, the --fix-titles repair of earlier mangled seeds, the
# manual-backend refusal, and loud per-item and listing failure handling
# (docs/mission-control.md owns the schemas).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/fm-mission-control-seed.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
fm_tasks_axi_compatible || { echo "skip: compatible tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

HOME_DIR=$(fm_test_tmproot fm-mc-seed)
export FM_HOME="$HOME_DIR"
mkdir -p "$HOME_DIR"
cp "$ROOT/.tasks.toml" "$HOME_DIR/"
(
  cd "$HOME_DIR" || exit 1
  tasks-axi add fix-login-flakes "Fix the flaky login tests" > /dev/null
  tasks-axi add deploy-pipeline "Speed up the deploy pipeline, safely" --start > /dev/null
  tasks-axi hold fix-login-flakes --reason "captain decision pending on Safari 16" --kind captain > /dev/null
) || fail "fixture backlog setup failed"

INITIATIVES="$HOME_DIR/data/mission-control/initiatives"
REGISTRY="$HOME_DIR/data/mission-control/registry.md"

# --- dry run writes nothing ---------------------------------------------------

out=$("$SEED" --dry-run)
assert_contains "$out" "would create" "dry run previews creations"
assert_absent "$INITIATIVES" "dry run created initiative files"
assert_absent "$REGISTRY" "dry run created the registry"
pass "dry run previews without writing"

# --- real run -------------------------------------------------------------------

out=$("$SEED")
assert_contains "$out" "created 2 card(s)" "seed creates one card per open item"
assert_present "$INITIATIVES/fix-login-flakes.md" "held item card created"
assert_present "$INITIATIVES/deploy-pipeline.md" "in-flight item card created"

assert_grep "title: Fix the flaky login tests" "$INITIATIVES/fix-login-flakes.md" "card carries the item title"
assert_grep "status: waiting-on-you" "$INITIATIVES/fix-login-flakes.md" "captain hold seeds waiting-on-you"
assert_grep "decision: captain decision pending on Safari 16" "$INITIATIVES/fix-login-flakes.md" "hold reason becomes the pending decision"
assert_grep "work-items: fix-login-flakes" "$INITIATIVES/fix-login-flakes.md" "card links its backlog item"
assert_grep "## History" "$INITIATIVES/fix-login-flakes.md" "card carries a history section"

assert_grep "title: Speed up the deploy pipeline, safely" "$INITIATIVES/deploy-pipeline.md" "comma-containing title parsed intact"
assert_grep "status: active" "$INITIATIVES/deploy-pipeline.md" "in-flight item seeds active"

assert_grep "- fix-login-flakes: Fix the flaky login tests" "$REGISTRY" "registry entry for held item"
assert_grep "- deploy-pipeline: Speed up the deploy pipeline, safely" "$REGISTRY" "registry entry for in-flight item"
pass "seed builds cards and registry from the open backlog"

# --- idempotence ------------------------------------------------------------------

before=$(cat "$INITIATIVES/fix-login-flakes.md")
out=$("$SEED")
assert_contains "$out" "created 0 card(s)" "second run creates nothing"
assert_contains "$out" "2 already present" "second run reports existing cards"
[ "$before" = "$(cat "$INITIATIVES/fix-login-flakes.md")" ] || fail "re-run rewrote an existing card"
[ "$(grep -c -- '- fix-login-flakes:' "$REGISTRY")" = 1 ] || fail "re-run duplicated a registry entry"
pass "re-running the seed is safe"

# --- full titles, area, priority, umbrella --------------------------------------

# A title long enough that the tasks-axi listing truncates it with a literal
# "... (truncated, N chars total ...)" marker; the seed must take the full
# title from `tasks-axi show --full` instead (regression: seeded cards used to
# carry the mangled listing cell).
LONG_TITLE="Speed up the product search endpoint by moving the synonym expansion out of the request path and precomputing it at index time behind a feature flag"
(
  cd "$HOME_DIR" || exit 1
  tasks-axi add web-slow-search "$LONG_TITLE" --repo acme-web > /dev/null
  tasks-axi update web-slow-search --priority 1 > /dev/null
  tasks-axi add codegen-study "Comparative codegen study" --repo tools > /dev/null
  tasks-axi add codegen-study-decision-3 "Pick the winning codegen approach" --repo tools > /dev/null
) || fail "grouping fixture backlog setup failed"

out=$("$SEED")
assert_contains "$out" "created 3 card(s)" "seed creates the new grouping fixtures"
assert_grep "title: $LONG_TITLE" "$INITIATIVES/web-slow-search.md" "long title seeded complete"
assert_no_grep "truncated," "$INITIATIVES/web-slow-search.md" "no listing truncation marker in the card"
assert_grep "area: acme-web" "$INITIATIVES/web-slow-search.md" "backlog repo seeds the card area"
assert_grep "priority: 1" "$INITIATIVES/web-slow-search.md" "backlog priority seeds the card priority"
assert_grep "- web-slow-search: $LONG_TITLE" "$REGISTRY" "registry entry carries the full title"
assert_grep "umbrella: codegen-study" "$INITIATIVES/codegen-study-decision-3.md" "decision-suffixed id seeds its umbrella"
assert_no_grep "umbrella:" "$INITIATIVES/codegen-study.md" "the parent itself gets no umbrella"
assert_no_grep "area:" "$INITIATIVES/fix-login-flakes.md" "an item without a repo gets no area line"
pass "seed maps full titles, repo, priority, and decision umbrellas"

# --- --fix-titles repairs earlier mangled seeds ----------------------------------

(cd "$HOME_DIR" && tasks-axi add mangled-item "$LONG_TITLE" > /dev/null) \
  || fail "mangled fixture backlog setup failed"
MARKER='\n... (truncated, 160 chars total - use show mangled-item --full to see complete text)'
cat > "$INITIATIVES/mangled-item.md" <<EOF
---
title: Speed up the product search endpoint by moving the synonym expansion out$MARKER
status: active
updated: 2026-08-26T12:00:00Z
work-items: mangled-item
---
Queued; work has not started yet.

## History
- 2026-08-26T12:00:00Z: card seeded from the open backlog
EOF
printf -- '- mangled-item: Speed up the product search endpoint by moving the synonym expansion out%s\n' "$MARKER" >> "$REGISTRY"

out=$("$SEED")
assert_grep "truncated," "$INITIATIVES/mangled-item.md" "a plain re-seed leaves existing mangled cards alone"

out=$("$SEED" --dry-run --fix-titles)
assert_contains "$out" "would fix title: $INITIATIVES/mangled-item.md" "dry run previews the title fix"
assert_grep "truncated," "$INITIATIVES/mangled-item.md" "dry run does not rewrite the card"

out=$("$SEED" --fix-titles)
assert_contains "$out" "1 title(s) fixed" "fix run reports the repair"
assert_grep "title: $LONG_TITLE" "$INITIATIVES/mangled-item.md" "mangled card title repaired to the full title"
assert_no_grep "truncated," "$INITIATIVES/mangled-item.md" "truncation marker removed from the card"
assert_grep "- mangled-item: $LONG_TITLE" "$REGISTRY" "mangled registry entry repaired"
assert_grep "status: active" "$INITIATIVES/mangled-item.md" "repair touches only the title line"
assert_grep "updated: 2026-08-26T12:00:00Z" "$INITIATIVES/mangled-item.md" "repair does not bump the update timestamp"
[ "$(grep -c -- '- mangled-item:' "$REGISTRY")" = 1 ] || fail "title fix duplicated a registry entry"

out=$("$SEED" --fix-titles)
assert_contains "$out" "0 title(s) fixed" "repair is idempotent"
pass "--fix-titles repairs mangled seeded titles once"

# --- manual backend refusal ---------------------------------------------------------

mkdir -p "$HOME_DIR/config"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
if out=$("$SEED" 2>&1); then
  fail "seed ran with a manual backlog backend"
fi
assert_contains "$out" "manual" "manual-backend refusal names the reason"
pass "manual backlog backend is refused"

# --- listing failure propagates ------------------------------------------------

# A fake tasks-axi that passes the compatibility probe but fails on list: the
# seed must stop with the error, not report a zero-card success.
FAIL_HOME=$(fm_test_tmproot fm-mc-seed-fail)
mkdir -p "$FAIL_HOME"
fakebin=$(fm_fakebin "$FAIL_HOME")
cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v|-V) echo "tasks-axi 0.9.9"; exit 0 ;;
  update) echo "usage: tasks-axi update ... --archive-body"; exit 0 ;;
  mv) echo "usage: tasks-axi mv [<id>...]"; exit 0 ;;
  list) echo "error: backlog corrupted" >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$fakebin/tasks-axi"
rc=0
out=$(FM_HOME="$FAIL_HOME" PATH="$fakebin:$PATH" "$SEED" 2>&1) || rc=$?
expect_code 1 "$rc" "seed with a failing tasks-axi list"
assert_contains "$out" "tasks-axi list failed" "listing failure is reported"
assert_contains "$out" "backlog corrupted" "listing failure carries the tool's error"
assert_not_contains "$out" "seed:" "no zero-card success summary after a listing failure"
assert_absent "$FAIL_HOME/data/mission-control" "no cards or registry written after a listing failure"
pass "a tasks-axi list failure stops the seed with its error"

# --- per-item show failure skips loudly ----------------------------------------

# A fake tasks-axi whose listing is fine but whose `show broken-item --full`
# fails: the seed must skip that item with the tool's error on stderr - never
# create a card or registry entry titled by the bare id from empty details -
# while still seeding the healthy item (regression: a failed show used to
# yield all-"-" fields silently).
SHOWFAIL_HOME=$(fm_test_tmproot fm-mc-seed-showfail)
mkdir -p "$SHOWFAIL_HOME"
fakebin=$(fm_fakebin "$SHOWFAIL_HOME")
cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v|-V) echo "tasks-axi 0.9.9"; exit 0 ;;
  update) echo "usage: tasks-axi update ... --archive-body"; exit 0 ;;
  mv) echo "usage: tasks-axi mv [<id>...]"; exit 0 ;;
  list)
    cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,title}:
  broken-item,queued,task,demo,Broken item
  healthy-item,queued,task,demo,Healthy item
OUT
    exit 0 ;;
  show)
    if [ "${2:-}" = healthy-item ]; then
      cat <<'OUT'
task:
  id: healthy-item
  title: Healthy item full title
  state: queued
  held: no
  hold_reason: "-"
  hold_kind: "-"
  repo: demo
  priority: "-"
OUT
      exit 0
    fi
    echo "error: task store locked" >&2
    exit 1 ;;
esac
exit 0
SH
chmod +x "$fakebin/tasks-axi"
rc=0
out=$(FM_HOME="$SHOWFAIL_HOME" PATH="$fakebin:$PATH" "$SEED" 2>&1) || rc=$?
expect_code 0 "$rc" "seed with one failing tasks-axi show"
assert_contains "$out" "skipping broken-item: tasks-axi show broken-item --full failed" "show failure is reported per item"
assert_contains "$out" "task store locked" "show failure carries the tool's error"
assert_contains "$out" "created 1 card(s)" "only the healthy item is counted as created"
SHOWFAIL_CARDS="$SHOWFAIL_HOME/data/mission-control/initiatives"
assert_absent "$SHOWFAIL_CARDS/broken-item.md" "no card seeded from a failed show"
assert_present "$SHOWFAIL_CARDS/healthy-item.md" "healthy item still seeded"
assert_grep "title: Healthy item full title" "$SHOWFAIL_CARDS/healthy-item.md" "healthy card carries its show title"
assert_no_grep "- broken-item:" "$SHOWFAIL_HOME/data/mission-control/registry.md" "no registry entry from a failed show"

# Under --fix-titles a failed show must leave an existing mangled card
# untouched instead of overwriting its title with the bare id.
cat > "$SHOWFAIL_CARDS/broken-item.md" <<EOF
---
title: Broken item mangled title$MARKER
status: active
updated: 2026-08-26T12:00:00Z
work-items: broken-item
---
Queued; work has not started yet.
EOF
out=$(FM_HOME="$SHOWFAIL_HOME" PATH="$fakebin:$PATH" "$SEED" --fix-titles 2>&1) || rc=$?
assert_contains "$out" "skipping broken-item" "fix run skips the failed show"
assert_contains "$out" "0 title(s) fixed" "failed show is never counted as fixed"
assert_grep "truncated," "$SHOWFAIL_CARDS/broken-item.md" "failed show leaves the mangled title untouched"
pass "a tasks-axi show failure skips the item loudly"

# --- help prints only the header comment -----------------------------------------

out=$("$SEED" --help)
assert_contains "$out" "Usage:" "help carries the usage block"
assert_not_contains "$out" "set -u" "help stops at the header comment"
pass "--help prints the header comment only"

echo "ok - fm-mission-control-seed"
