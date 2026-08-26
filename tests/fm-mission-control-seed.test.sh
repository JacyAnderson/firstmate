#!/usr/bin/env bash
# Behavior tests for bin/fm-mission-control-seed.sh: initiative stubs and
# registry entries built from a compatible tasks-axi backlog listing, hold
# mapping to waiting-on-you, idempotence, dry-run, and the manual-backend
# refusal (docs/mission-control.md owns the schemas).
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

# --- manual backend refusal ---------------------------------------------------------

mkdir -p "$HOME_DIR/config"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
if out=$("$SEED" 2>&1); then
  fail "seed ran with a manual backlog backend"
fi
assert_contains "$out" "manual" "manual-backend refusal names the reason"
pass "manual backlog backend is refused"

echo "ok - fm-mission-control-seed"
