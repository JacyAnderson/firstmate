#!/usr/bin/env bash
# Tests for bin/fm-promote.sh: scout-to-ship promotion flips kind= in the task
# meta, and the suggested ship instructions name the bare-slug task branch
# (task branches carry no fm/ namespace).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote-tests)

make_case() {
  local name=$1 id=$2 kind=${3:-scout} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$kind"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_promote() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROMOTE" "$@"
}

test_promote_flips_kind_and_names_bare_slug_branch() {
  local case_dir out
  case_dir=$(make_case promote scout-p1)
  out=$(run_promote "$case_dir" scout-p1)
  grep -qx 'kind=ship' "$case_dir/state/scout-p1.meta" \
    || fail "promotion did not flip kind= to ship"
  assert_contains "$out" 'create branch scout-p1;' \
    "ship instructions must name the bare-slug task branch"
  assert_not_contains "$out" 'fm/scout-p1' \
    "ship instructions must not namespace the branch under fm/"
  pass "fm-promote flips kind to ship and instructs the bare-slug branch"
}

test_promote_refuses_non_scout() {
  local case_dir err rc=0
  case_dir=$(make_case non-scout ship-p2 ship)
  err=$(run_promote "$case_dir" ship-p2 2>&1) || rc=$?
  expect_code 1 "$rc" "promoting a non-scout task must fail"
  assert_contains "$err" 'not a scout task' "refusal must explain the kind mismatch"
  pass "fm-promote refuses a non-scout task"
}

test_promote_flips_kind_and_names_bare_slug_branch
test_promote_refuses_non_scout
