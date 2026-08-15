#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# The backlog's own retention rotates closed items into the configured archive, and
# `tasks-axi show` reads only the active backlog file. Before the archive fallback,
# a session that resolved more decisions than done_keep locked its own investigations
# open: `complete` and `verify` reported the resolved decision "absent from
# .../data/backlog.md", and teardown could not clean up either.
#
# The gate must find a durably-resolved decision in the archive while keeping every
# other guarantee: an archived record without the resolution markers still refuses,
# an OPEN hold present only in the archive never satisfies the active-hold check,
# and a home with no configured archive behaves exactly as before.
test_resolved_decision_in_done_archive_satisfies_the_gate() {
  local home origin hold archive keep_hold show
  home=$(make_home archived-resolution)
  origin=sample-archive-review
  mkdir -p "$home/data/$origin"
  archive="$home/data/done-archive.md"

  tasks_in "$home" add "$origin" "Investigate archived sample decisions" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-decision origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archive review\n\nOne captain choice was resolved and then archived.\n' \
    > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" rotation \
    --title "Choose the sample rotation" --reason "captain rotation choice pending" --repo sample) \
    || fail "could not register the rotation hold"
  run_decisions "$home" complete "$origin" rotation >/dev/null \
    || fail "completion failed while the hold was still live"

  tasks_in "$home" add sample-rotation-work "Apply the selected sample rotation" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent rotation work"
  printf 'Rotate the sample clockwise.\n' > "$home/rotation-decision.txt"
  run_decisions "$home" resolve "$origin" rotation \
    --decision-file "$home/rotation-decision.txt" --routed-to sample-rotation-work >/dev/null \
    || fail "could not resolve the rotation decision"

  # Force the exact retention rotation that hid the resolved decision, using the
  # backlog's own archiving path rather than hand-moving the record.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not archive the resolved decision through backlog retention"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "retention fixture did not remove the resolved decision from the active backlog"
  fi
  assert_grep "$hold" "$archive" "retention fixture did not archive the resolved decision"
  assert_grep "Resolution recorded by fm-decision-hold." "$archive" \
    "archived record lost its resolution body"

  run_decisions "$home" complete "$origin" rotation >/dev/null 2> "$home/archived-complete.err" \
    || fail "completion refused a decision durably resolved in the archive: $(cat "$home/archived-complete.err")"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/archived-verify.err" \
    || fail "verification refused a decision durably resolved in the archive: $(cat "$home/archived-verify.err")"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/archived-teardown.err" \
    || fail "teardown refused an investigation whose decisions are archived: $(cat "$home/archived-teardown.err")"

  # An archived record must clear the same resolution bar an active record clears:
  # mere presence of the identity in the archive is not durable resolution.
  #
  # Teardown deleted the origin metadata, so the completed inventory is restored
  # before this `verify`: without it verify refuses at "has no completed
  # unresolved-decision inventory" and never reaches the archive lookup at all.
  write_origin_meta "$home" "$origin"
  printf 'decisions_reviewed=1\ndecision_keys=rotation\n' >> "$home/state/$origin.meta"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  perl -0pi -e 's/^  Resolution recorded by fm-decision-hold\.\n//m' "$archive" \
    || fail "could not strip the archived resolution marker"
  assert_no_grep "Resolution recorded by fm-decision-hold." "$archive" \
    "stripped fixture still carries the resolution marker"
  if run_decisions "$home" verify "$origin" \
    > "$home/stripped-verify.out" 2> "$home/stripped-verify.err"; then
    fail "verification accepted an archived record with no resolution body"
  fi
  # The archive-specific refusal proves the archive lookup actually ran and judged
  # the record, rather than an earlier gate refusing for an unrelated reason.
  assert_grep "archived captain decision $hold has no durable resolution record" \
    "$home/stripped-verify.err" \
    "verification must refuse the archived record on its missing resolution body"
  if run_decisions "$home" complete "$origin" rotation \
    > "$home/stripped-complete.out" 2> "$home/stripped-complete.err"; then
    fail "completion accepted an archived record with no resolution body"
  fi
  assert_grep "archived captain decision $hold has no durable resolution record" \
    "$home/stripped-complete.err" \
    "completion must refuse the archived record on its missing resolution body"

  # An OPEN hold is a live-backlog fact. Finding one only in the archive must never
  # satisfy the active-hold check that guards `resolve`.
  keep_hold=$(run_decisions "$home" hold "$origin" retention \
    --title "Choose the sample retention" --reason "captain retention choice pending" --repo sample) \
    || fail "could not register the retention hold"
  tasks_in "$home" prune --keep 0 --state queued >/dev/null \
    || fail "could not archive the still-open retention hold"
  if tasks_in "$home" show "$keep_hold" --full >/dev/null 2>&1; then
    fail "queued-retention fixture did not remove the open hold from the active backlog"
  fi
  assert_grep "$keep_hold" "$archive" "queued-retention fixture did not archive the open hold"
  tasks_in "$home" add sample-retention-work "Apply the selected sample retention" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent retention work"
  printf 'Keep the sample for one cycle.\n' > "$home/retention-decision.txt"
  if run_decisions "$home" resolve "$origin" retention \
    --decision-file "$home/retention-decision.txt" --routed-to sample-retention-work \
    > "$home/archived-open.out" 2> "$home/archived-open.err"; then
    fail "resolve satisfied its active-hold check from the archive"
  fi
  assert_grep "captain hold $keep_hold is absent from" "$home/archived-open.err" \
    "an open hold found only in the archive must refuse as absent from the live backlog"
  # The inventory is reset to the retention key alone so this refusal cannot be
  # satisfied by the stripped rotation record examined above: which key refuses must
  # not depend on the order the inventory happens to be sorted in.
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  if run_decisions "$home" complete "$origin" retention \
    > "$home/archived-open-complete.out" 2> "$home/archived-open-complete.err"; then
    fail "completion accepted an open hold that exists only in the archive"
  fi
  assert_grep "captain decision $keep_hold is absent from" \
    "$home/archived-open-complete.err" \
    "completion must refuse the open archived hold on its own absence from the live backlog"
  assert_no_grep "$hold" "$home/archived-open-complete.err" \
    "the open-hold refusal must name the retention key, not the rotation key"

  pass "a resolved decision in the Done archive satisfies the gate while open and unresolved records still refuse"
}

# Archives one durably-resolved copy and one closed-unresolved copy of the SAME
# decision identity into <home>'s Done archive, in the requested order, driving the
# real lifecycle: retention rotates a resolved decision out, the same key can then
# be held again because the live backlog no longer carries it, and that second hold
# can be closed without a resolution and rotated out in turn.
archive_duplicate_identity() {  # <home> <origin> <key> <order: resolved-first|unresolved-first>
  local home=$1 origin=$2 key=$3 order=$4 hold work
  work="sample-$key-work"

  if [ "$order" = unresolved-first ]; then
    hold=$(run_decisions "$home" hold "$origin" "$key" \
      --title "Choose the sample $key" --reason "captain $key choice pending" --repo sample) \
      || fail "could not register the first $key hold"
    tasks_in "$home" "done" "$hold" >/dev/null \
      || fail "could not close the $key hold without a resolution"
    tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
      || fail "could not archive the unresolved $key copy"
  fi

  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the sample $key" --reason "captain $key choice pending" --repo sample) \
    || fail "could not register the resolvable $key hold"
  tasks_in "$home" add "$work" "Apply the selected sample $key" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent $key work"
  printf 'Take the %s branch.\n' "$key" > "$home/$key-decision.txt"
  run_decisions "$home" resolve "$origin" "$key" \
    --decision-file "$home/$key-decision.txt" --routed-to "$work" >/dev/null \
    || fail "could not resolve the $key decision"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not archive the resolved $key copy"

  if [ "$order" = resolved-first ]; then
    hold=$(run_decisions "$home" hold "$origin" "$key" \
      --title "Choose the sample $key" --reason "captain $key choice pending" --repo sample) \
      || fail "could not re-register the $key hold after its resolution was archived"
    tasks_in "$home" "done" "$hold" >/dev/null \
      || fail "could not close the second $key hold without a resolution"
    tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
      || fail "could not archive the unresolved $key copy"
  fi

  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "duplicate fixture left a $key copy in the active backlog"
  fi
  printf '%s\n' "$hold"
}

# `tasks-axi show` reports only the FIRST record carrying an id, so a single show
# call against the archive let record ordering decide the gate's answer: the same
# two archived copies of one identity passed when the resolved copy happened to
# come first and refused when it came second. The lookup must examine every
# archived record for the id, so both orderings answer identically.
test_duplicate_archived_identity_is_order_independent() {
  local home origin hold order rc
  for order in resolved-first unresolved-first; do
    home=$(make_home "duplicate-$order")
    origin="sample-dup-$order-review"
    mkdir -p "$home/data/$origin"
    tasks_in "$home" add "$origin" "Investigate duplicated sample decisions" \
      --kind scout --repo sample --start >/dev/null \
      || fail "could not create duplicate-identity origin ($order)"
    write_origin_meta "$home" "$origin"
    printf 'done: report complete\n' > "$home/state/$origin.status"
    printf '# Duplicate review\n\nOne captain choice was resolved and archived twice.\n' \
      > "$home/data/$origin/report.md"

    hold=$(archive_duplicate_identity "$home" "$origin" branch "$order")
    [ "$(grep -c -F -- "- [x] $hold - " "$home/data/done-archive.md")" = 2 ] \
      || fail "duplicate fixture did not archive two copies of $hold ($order)"

    set +e
    run_decisions "$home" complete "$origin" branch \
      > "$home/dup-complete.out" 2> "$home/dup-complete.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || fail "completion answered differently for $order ordering: $(cat "$home/dup-complete.err")"

    printf 'decisions_reviewed=1\ndecision_keys=branch\n' >> "$home/state/$origin.meta"
    set +e
    run_decisions "$home" verify "$origin" \
      > "$home/dup-verify.out" 2> "$home/dup-verify.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || fail "verification answered differently for $order ordering: $(cat "$home/dup-verify.err")"
  done

  pass "a duplicated archived identity resolves the same way in either ordering"
}

# The archive fallback originally ran only when the live backlog held NO record for
# the id, so a stale live record short-circuited it: with a durably-resolved copy in
# the archive and a closed-unresolved copy of the SAME identity still in the live
# backlog's Done section, the gate refused "neither actively held nor durably
# resolved" even though the decision WAS durably resolved, and the very same facts
# passed once retention rotated the stale live copy out too. Retention position must
# not decide the answer, so the archive is consulted whenever the live backlog does
# not settle the question.
test_stale_live_record_still_consults_the_archive() {
  local home origin hold work rc
  home=$(make_home stale-live-record)
  origin=sample-stale-live-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Investigate a stale live decision copy" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create stale-live-record origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Stale live review\n\nOne captain choice was resolved, archived, then re-held.\n' \
    > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" placement \
    --title "Choose the sample placement" --reason "captain placement choice pending" --repo sample) \
    || fail "could not register the placement hold"
  work=sample-placement-work
  tasks_in "$home" add "$work" "Apply the selected sample placement" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent placement work"
  printf 'Place the sample forward.\n' > "$home/placement-decision.txt"
  run_decisions "$home" resolve "$origin" placement \
    --decision-file "$home/placement-decision.txt" --routed-to "$work" >/dev/null \
    || fail "could not resolve the placement decision"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not archive the resolved placement copy"

  # The same key can be re-held once its resolution has left the live backlog, and
  # that second hold can be closed with no resolution. This leaves the exact state
  # the defect mishandled: a stale unresolved live record over an archived resolution.
  run_decisions "$home" hold "$origin" placement \
    --title "Choose the sample placement" --reason "captain placement choice pending" --repo sample \
    >/dev/null || fail "could not re-hold the placement key after its resolution was archived"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not close the second placement hold without a resolution"
  tasks_in "$home" show "$hold" --full >/dev/null 2>&1 \
    || fail "stale-live fixture must leave an unresolved copy in the live backlog"
  assert_grep "Resolution recorded by fm-decision-hold." "$home/data/done-archive.md" \
    "stale-live fixture must leave the resolved copy in the archive"

  set +e
  run_decisions "$home" complete "$origin" placement \
    > "$home/stale-complete.out" 2> "$home/stale-complete.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "completion refused a decision resolved in the archive because a stale live copy existed: $(cat "$home/stale-complete.err")"
  set +e
  run_decisions "$home" verify "$origin" \
    > "$home/stale-verify.out" 2> "$home/stale-verify.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "verification refused a decision resolved in the archive because a stale live copy existed: $(cat "$home/stale-verify.err")"

  # Rotating the stale live copy out changes nothing about the decisions, so it must
  # not change the answer either.
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not rotate the stale live copy out"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "retention fixture did not remove the stale live copy"
  fi
  set +e
  run_decisions "$home" complete "$origin" placement \
    > "$home/rotated-complete.out" 2> "$home/rotated-complete.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "completion answered differently once the stale live copy rotated out: $(cat "$home/rotated-complete.err")"
  set +e
  run_decisions "$home" verify "$origin" \
    > "$home/rotated-verify.out" 2> "$home/rotated-verify.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "verification answered differently once the stale live copy rotated out: $(cat "$home/rotated-verify.err")"

  pass "a stale unresolved live record does not hide a durable resolution in the archive"
}

# The archive fallback must not let an archived answer settle a live record that is
# OPEN and is not an active captain hold. Retention rotates a resolved decision out,
# the same key can then be re-held, and dropping that copy out of its captain hold -
# unheld, in flight, or held for something else - leaves a genuinely unanswered
# captain decision whatever the archive remembers. Before the fall-through was
# narrowed to settled live records, every one of those states passed completion, so
# teardown could erase the source of a pending decision. Each must refuse, naming all
# four fields the active-hold check tests so the refusal explains which one failed,
# and a SETTLED live copy carrying no resolution must still be satisfiable from the
# archive so the narrowing does not revert the fix this fallback exists to deliver.
#
# Re-holding through the script's own `hold` alone is deliberately NOT one of these
# states: it presents as an active captain hold, which is a legitimate durable state
# satisfied by the active-hold check before this one, so it passes here exactly as it
# does on base. That base parity is asserted at the end rather than left implicit.
test_reopened_decision_is_not_settled_by_the_archive() {
  local home origin hold work rc state show expected
  for state in unheld in-flight external-hold; do
    home=$(make_home "reopened-$state")
    origin="sample-reopened-$state-review"
    mkdir -p "$home/data/$origin"
    tasks_in "$home" add "$origin" "Investigate a reopened sample decision" \
      --kind scout --repo sample --start >/dev/null \
      || fail "could not create reopened-decision origin ($state)"
    write_origin_meta "$home" "$origin"
    printf 'done: report complete\n' > "$home/state/$origin.status"
    printf '# Reopened review\n\nOne captain choice was answered, archived, then reopened.\n' \
      > "$home/data/$origin/report.md"

    hold=$(run_decisions "$home" hold "$origin" pick \
      --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample) \
      || fail "could not register the pick hold ($state)"
    work=sample-pick-work
    tasks_in "$home" add "$work" "Apply the selected sample pick" \
      --kind ship --repo sample --blocked-by "$hold" >/dev/null \
      || fail "could not create dependent pick work ($state)"
    printf 'Pick the sample front.\n' > "$home/pick-decision.txt"
    run_decisions "$home" resolve "$origin" pick \
      --decision-file "$home/pick-decision.txt" --routed-to "$work" >/dev/null \
      || fail "could not resolve the pick decision ($state)"
    tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
      || fail "could not archive the resolved pick copy ($state)"
    assert_grep "Resolution recorded by fm-decision-hold." "$home/data/done-archive.md" \
      "reopened fixture must leave the resolved copy in the archive ($state)"

    # Reopening the key is possible once its resolution has left the live backlog.
    # Each reopened shape is a live record that is NOT settled.
    run_decisions "$home" hold "$origin" pick \
      --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample \
      >/dev/null || fail "could not re-hold the pick key after its resolution was archived ($state)"
    case "$state" in
      unheld)
        tasks_in "$home" unhold "$hold" >/dev/null \
          || fail "could not drop the hold from the reopened pick record"
        ;;
      in-flight)
        tasks_in "$home" start "$hold" >/dev/null \
          || fail "could not start the reopened pick record"
        ;;
      external-hold)
        tasks_in "$home" hold "$hold" --reason "external pick review pending" --kind external \
          >/dev/null || fail "could not re-hold the reopened pick record for a non-captain owner"
        ;;
    esac
    show=$(tasks_in "$home" show "$hold" --full) \
      || fail "reopened fixture must leave a live copy in the backlog ($state)"
    assert_not_contains "$show" "Resolution recorded by fm-decision-hold." \
      "reopened live copy must carry no resolution body ($state)"
    # Each shape must fail exactly one of the four active-hold fields, and the refusal
    # must name the failing value: otherwise a message listing only satisfying-looking
    # fields cannot explain its own refusal.
    case "$state" in
      unheld)
        assert_contains "$show" "state: queued" "unheld fixture must leave a queued record"
        assert_contains "$show" "held: no" "unheld fixture must leave an unheld record"
        expected="state=queued held=no kind=captain"
        ;;
      in-flight)
        assert_contains "$show" "state: in_flight" "in-flight fixture must leave an in_flight record"
        assert_contains "$show" "held: yes" "in-flight fixture must keep its captain hold"
        expected="state=in_flight held=yes kind=captain hold_kind=captain"
        ;;
      external-hold)
        assert_contains "$show" "state: queued" "external-hold fixture must leave a queued record"
        assert_contains "$show" "held: yes" "external-hold fixture must leave a held record"
        assert_contains "$show" "hold_kind: external" \
          "external-hold fixture must leave a non-captain hold_kind"
        expected="state=queued held=yes kind=captain hold_kind=external"
        ;;
    esac

    if run_decisions "$home" complete "$origin" pick \
      > "$home/reopened-complete.out" 2> "$home/reopened-complete.err"; then
      fail "completion accepted a reopened pending decision from the archive ($state)"
    fi
    assert_grep "captain decision $hold has an open unresolved record" \
      "$home/reopened-complete.err" \
      "completion must refuse a reopened decision on its own open live record ($state)"
    assert_grep "($expected" "$home/reopened-complete.err" \
      "the refusal must report the live fields actually observed ($state)"
    assert_no_grep "decisions_reviewed=1" "$home/state/$origin.meta" \
      "refused completion recorded a false attestation for a reopened decision ($state)"

    printf 'decisions_reviewed=1\ndecision_keys=pick\n' >> "$home/state/$origin.meta"
    if run_decisions "$home" verify "$origin" \
      > "$home/reopened-verify.out" 2> "$home/reopened-verify.err"; then
      fail "verification accepted a reopened pending decision from the archive ($state)"
    fi
    assert_grep "captain decision $hold has an open unresolved record" \
      "$home/reopened-verify.err" \
      "verification must refuse a reopened decision on its own open live record ($state)"
    if run_teardown "$home" "$origin" \
      > "$home/reopened-teardown.out" 2> "$home/reopened-teardown.err"; then
      fail "teardown erased the source of a reopened pending decision ($state)"
    fi
    assert_present "$home/state/$origin.meta" \
      "refused teardown removed the metadata of a reopened pending decision ($state)"

    # Settling the reopened copy - closed, still with no resolution body - restores
    # the stale-record case the fallback exists for, so the archive must answer again.
    tasks_in "$home" "done" "$hold" >/dev/null \
      || fail "could not settle the reopened pick record ($state)"
    show=$(tasks_in "$home" show "$hold" --full) \
      || fail "settled fixture must leave the live copy in the backlog ($state)"
    assert_contains "$show" "state: done" "settled fixture must leave a done record"
    assert_not_contains "$show" "Resolution recorded by fm-decision-hold." \
      "settled live copy must still carry no resolution body ($state)"
    set +e
    run_decisions "$home" complete "$origin" pick \
      > "$home/settled-complete.out" 2> "$home/settled-complete.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || fail "narrowing broke the settled stale-record fall-through ($state): $(cat "$home/settled-complete.err")"
    set +e
    run_decisions "$home" verify "$origin" \
      > "$home/settled-verify.out" 2> "$home/settled-verify.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || fail "narrowing broke the settled stale-record verification ($state): $(cat "$home/settled-verify.err")"
  done

  # Re-holding an archived key through the script's own `hold`, with nothing after it,
  # leaves an ACTIVE captain hold. That is a legitimate durable state the active-hold
  # check satisfies before the settled check is reached, so it must keep passing: the
  # narrowing above governs records that are open WITHOUT such a hold, not this one.
  home=$(make_home reheld-active-hold)
  origin=sample-reheld-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Investigate a re-held sample decision" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create re-held-decision origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Re-held review\n\nOne captain choice was answered, archived, then re-held.\n' \
    > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" pick \
    --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample) \
    || fail "could not register the re-held pick hold"
  work=sample-pick-work
  tasks_in "$home" add "$work" "Apply the selected sample pick" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create dependent re-held pick work"
  printf 'Pick the sample front.\n' > "$home/pick-decision.txt"
  run_decisions "$home" resolve "$origin" pick \
    --decision-file "$home/pick-decision.txt" --routed-to "$work" >/dev/null \
    || fail "could not resolve the re-held pick decision"
  tasks_in "$home" prune --keep 0 --state "done" >/dev/null \
    || fail "could not archive the resolved re-held pick copy"
  run_decisions "$home" hold "$origin" pick \
    --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample \
    >/dev/null || fail "could not re-hold the pick key after its resolution was archived"

  show=$(tasks_in "$home" show "$hold" --full) \
    || fail "re-held fixture must leave a live copy in the backlog"
  assert_contains "$show" "state: queued" "re-held fixture must leave a queued record"
  assert_contains "$show" "held: yes" "re-held fixture must leave an active hold"
  assert_contains "$show" "kind: captain" "re-held fixture must leave a captain record"
  assert_contains "$show" "hold_kind: captain" "re-held fixture must leave a captain hold"
  set +e
  run_decisions "$home" complete "$origin" pick \
    > "$home/reheld-complete.out" 2> "$home/reheld-complete.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an active captain hold stopped satisfying completion: $(cat "$home/reheld-complete.err")"
  set +e
  run_decisions "$home" verify "$origin" \
    > "$home/reheld-verify.out" 2> "$home/reheld-verify.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an active captain hold stopped satisfying verification: $(cat "$home/reheld-verify.err")"

  pass "an open live record without an active captain hold is not settled by the archive"
}

# An absent or unset archive key must behave exactly as before the fallback existed:
# refuse a genuinely missing decision, without crashing and without silently passing.
test_absent_archive_config_behaves_as_before() {
  local home origin
  # The home directory name is embedded in refusal messages, so it deliberately
  # avoids the substring "archive": otherwise an assertion on that word would match
  # any refusal that merely names a path under this home.
  home=$(make_home unconfigured-retention)
  origin=sample-retention-only-review
  mkdir -p "$home/data/$origin"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
done_keep = 10
EOF
  tasks_in "$home" add "$origin" "Investigate without an archive" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create no-archive origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# No-archive review\n\nOne captain choice is claimed but absent.\n' \
    > "$home/data/$origin/report.md"

  if run_decisions "$home" complete "$origin" ghost \
    > "$home/no-archive.out" 2> "$home/no-archive.err"; then
    fail "completion passed a genuinely absent decision when no archive is configured"
  fi
  assert_grep "absent from" "$home/no-archive.err" \
    "an absent archive key must refuse with the ordinary absence error"
  assert_no_grep "decisions_reviewed=1" "$home/state/$origin.meta" \
    "refused completion recorded a false attestation with no archive configured"

  # A configured-but-missing archive file is a legitimate absence too.
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  assert_absent "$home/data/done-archive.md" "fixture must start with no archive file"
  if run_decisions "$home" complete "$origin" ghost \
    > "$home/missing-archive.out" 2> "$home/missing-archive.err"; then
    fail "completion passed an absent decision when the archive file does not exist"
  fi
  assert_grep "absent from" "$home/missing-archive.err" \
    "a missing archive file must refuse with the ordinary absence error"

  # An empty archive unambiguously holds no records, so it is an absence too.
  : > "$home/data/done-archive.md"
  if run_decisions "$home" complete "$origin" ghost \
    > "$home/empty-archive.out" 2> "$home/empty-archive.err"; then
    fail "completion passed an absent decision when the archive file is empty"
  fi
  assert_grep "absent from" "$home/empty-archive.err" \
    "an empty archive file must refuse with the ordinary absence error"

  # A corrupt archive is not the same thing as an absence and must not read as one.
  printf 'not a backlog\000at all\n' > "$home/data/done-archive.md"
  if run_decisions "$home" complete "$origin" ghost \
    > "$home/corrupt-archive.out" 2> "$home/corrupt-archive.err"; then
    fail "completion passed while the configured archive was unreadable as a backlog"
  fi
  assert_grep "is not a text backlog file" "$home/corrupt-archive.err" \
    "a corrupt archive must refuse as unreadable rather than as an ordinary absence"
  assert_no_grep "absent from" "$home/corrupt-archive.err" \
    "a corrupt archive must not refuse as if the decision were merely absent"
  assert_no_grep "decisions_reviewed=1" "$home/state/$origin.meta" \
    "a corrupt archive recorded a false completion attestation"

  pass "an absent, missing, or corrupt archive refuses exactly as before rather than passing"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_resolved_decision_in_done_archive_satisfies_the_gate
test_duplicate_archived_identity_is_order_independent
test_stale_live_record_still_consults_the_archive
test_reopened_decision_is_not_settled_by_the_archive
test_absent_archive_config_behaves_as_before
