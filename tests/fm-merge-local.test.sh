#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded local-only fast-forward merge.
#
# Task branches are named with the bare task id; older briefs created fm/<id>.
# The merge must resolve the task branch under either name so in-flight legacy
# tasks keep landing, and must still refuse when neither branch exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name> <task-id> [branch]: a local-only project with one commit on
# <branch> ahead of the default branch, plus the task meta. Echoes the case dir.
# Pass an empty branch to skip creating a task branch at all.
make_case() {
  local name=$1 id=$2 branch=${3-} case_dir default
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_git_init_commit "$case_dir/project"
  default=$(git -C "$case_dir/project" symbolic-ref --short HEAD)
  if [ -n "$branch" ]; then
    git -C "$case_dir/project" checkout -q -b "$branch"
    printf 'feature\n' > "$case_dir/project/feature.txt"
    git -C "$case_dir/project" add feature.txt
    git -C "$case_dir/project" commit -qm "task work"
    git -C "$case_dir/project" checkout -q "$default"
  fi
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/project" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

test_bare_slug_branch_merges() {
  local case_dir out
  case_dir=$(make_case bare-slug task-b1 task-b1)
  out=$(run_merge_local "$case_dir" task-b1)
  assert_contains "$out" 'merged task-b1 into local' \
    "bare-slug: merge must land the bare-slug task branch"
  [ -f "$case_dir/project/feature.txt" ] || fail "bare-slug: default branch did not receive the task commit"
  pass "fm-merge-local merges a bare-slug task branch"
}

test_legacy_fm_branch_merges() {
  local case_dir out
  case_dir=$(make_case legacy task-l1 fm/task-l1)
  out=$(run_merge_local "$case_dir" task-l1)
  assert_contains "$out" 'merged fm/task-l1 into local' \
    "legacy: merge must land the legacy fm/-prefixed task branch"
  [ -f "$case_dir/project/feature.txt" ] || fail "legacy: default branch did not receive the task commit"
  pass "fm-merge-local merges a legacy fm/ task branch"
}

test_missing_branch_refuses_naming_both_forms() {
  local case_dir err rc=0
  case_dir=$(make_case missing task-m1 "")
  err=$(run_merge_local "$case_dir" task-m1 2>&1) || rc=$?
  expect_code 1 "$rc" "missing: merge must fail when no task branch exists"
  assert_contains "$err" "no task branch for task-m1" \
    "missing: error must say the task branch is absent"
  assert_contains "$err" "legacy 'fm/task-m1'" \
    "missing: error must show that the legacy form was also checked"
  pass "fm-merge-local refuses cleanly when neither branch form exists"
}

test_bare_slug_branch_merges
test_legacy_fm_branch_merges
test_missing_branch_refuses_naming_both_forms
