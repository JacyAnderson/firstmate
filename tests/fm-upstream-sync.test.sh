#!/usr/bin/env bash
# Tests for bin/fm-upstream-sync.sh: the fork's upstream sync report and merge.
#
# Each world has a bare "upstream" repository, a bare "fork" repository cloned
# from it, and a working clone of the fork with origin = fork and
# upstream = upstream. The guarantees under test:
#   - status reports behind/ahead counts, dry-run conflicts (including one git
#     merge-tree does not name), files both sides changed, hotspot notes,
#     upstream-added fm/ lines, and any usable upstream push URL with its
#     credentials removed, and changes no local branch, HEAD, index, or working
#     tree. It reads the fork checkout despite an inherited GIT_DIR and refuses a
#     branch deleted on its remote.
#   - merge refuses the default branch, a detached HEAD without --branch, a
#     dirty tree, and a HEAD missing the fork tip.
#   - merge makes a real two-parent merge commit with upstream's tip as the
#     second parent, leaves conflicts in the index with exit 1, and never
#     pushes to either remote.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)

commit_file() {  # <repo> <path> <content> <message>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -qm "$4"
}

# new_world <name>: echoes the world dir. The work clone is on main at the fork
# tip, which has one fork-only commit touching bin/fm-brief.sh and notes.md.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w"
  git init -q -b main "$w/up-src"
  commit_file "$w/up-src" bin/fm-brief.sh "base line" "base brief"
  commit_file "$w/up-src" notes.md "notes base" "base notes"
  commit_file "$w/up-src" other.md "other base" "base other"
  git clone -q --bare "$w/up-src" "$w/upstream.git"
  git clone -q --bare "$w/upstream.git" "$w/fork.git"
  git clone -q "$w/fork.git" "$w/work"
  git -C "$w/work" remote add upstream "$w/upstream.git"
  git -C "$w/work" remote set-url --push upstream DISABLED
  git -C "$w/up-src" remote add origin "$w/upstream.git"
  commit_file "$w/work" notes.md "notes fork" "fork notes"
  git -C "$w/work" push -q origin main
  printf '%s\n' "$w"
}

upstream_commit() {  # <world> <path> <content> <message>
  commit_file "$1/up-src" "$2" "$3" "$4"
  git -C "$1/up-src" push -q origin main
}

run_sync() {  # <world> <args...>; sets OUT and RC
  local w=$1
  shift
  RC=0
  OUT=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC" "$@" 2>&1) || RC=$?
}

refs_of() { git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads; }

test_status_current() {
  local w
  w=$(new_world current)
  run_sync "$w" status
  expect_code 0 "$RC" "status when current"
  assert_contains "$OUT" "behind: 0" "a fork with every upstream commit is not behind"
  assert_contains "$OUT" "ahead: 1" "the fork-only commit is counted"
  assert_contains "$OUT" "upstream-push: disabled DISABLED" "a disabled push URL is reported"
  assert_contains "$OUT" "summary: current" "status summary when current"
  run_sync "$w" merge --branch upstream-sync
  expect_code 0 "$RC" "merge --branch when current"
  assert_contains "$OUT" "summary: current" "merge finds nothing to do"
  assert_equals "" "$(git -C "$w/work" branch --list upstream-sync)" "no sync branch is created when current"
  pass "status and merge report a current fork"
}

test_status_reports_without_touching_the_checkout() {
  local w before_refs before_head out2
  w=$(new_world report)
  upstream_commit "$w" bin/fm-brief.sh "base line
upstream adds git checkout -b fm/\$ID" "upstream brief"
  upstream_commit "$w" notes.md "notes upstream" "upstream notes"
  upstream_commit "$w" other.md "other upstream" "upstream other"
  git -C "$w/work" checkout -q -b local-work
  before_refs=$(refs_of "$w/work")
  before_head=$(git -C "$w/work" rev-parse HEAD)
  run_sync "$w"
  expect_code 0 "$RC" "status with upstream ahead"
  assert_contains "$OUT" "behind: 3" "three upstream commits are pending"
  assert_contains "$OUT" "conflict: notes.md" "both sides rewrote notes.md, so the dry run conflicts"
  assert_contains "$OUT" "fm-prefix: bin/fm-brief.sh +1" "an upstream-added fm/ branch line is counted"
  assert_not_contains "$OUT" "review: other.md" "an upstream-only change is not a both-sides review item"
  assert_contains "$OUT" "summary: conflicts=1" "one conflicting file"
  assert_equals "$before_refs" "$(refs_of "$w/work")" "status must not move any local branch"
  assert_equals "$before_head" "$(git -C "$w/work" rev-parse HEAD)" "status must not move HEAD"
  assert_equals "local-work" "$(git -C "$w/work" symbolic-ref --short HEAD)" "status must not switch branches"
  out2=$(git -C "$w/work" status --porcelain)
  assert_equals "" "$out2" "status must leave the tree and index clean"
  pass "status reports conflicts and fm/ lines without touching the checkout"
}

test_status_fm_prefix_ignores_diff_noprefix() {
  local w
  w=$(new_world noprefix)
  git -C "$w/work" config diff.noprefix true
  upstream_commit "$w" f "git checkout -b fm/\$ID" "upstream short path"
  upstream_commit "$w" bin/fm-brief.sh "base line
upstream adds git checkout -b fm/\$ID" "upstream brief"
  run_sync "$w" status
  expect_code 0 "$RC" "status with diff.noprefix set"
  assert_contains "$OUT" "fm-prefix: f +1" "a short path is still scanned under diff.noprefix"
  assert_contains "$OUT" "fm-prefix: bin/fm-brief.sh +1" "the full path is reported under diff.noprefix"
  pass "the fm/ scan does not depend on the user's diff config"
}

test_status_hotspot_and_review() {
  local w
  w=$(new_world hotspot)
  commit_file "$w/work" bin/fm-brief.sh "fork line
base line" "fork brief"
  git -C "$w/work" push -q origin main
  upstream_commit "$w" bin/fm-brief.sh "base line
upstream tail" "upstream brief"
  run_sync "$w" status
  expect_code 0 "$RC" "status with a both-sides change"
  assert_contains "$OUT" "review: bin/fm-brief.sh (hotspot: branch-prefix default" "a both-sides hotspot file carries its note"
  assert_contains "$OUT" "summary: clean" "non-overlapping hunks merge cleanly"
  pass "status lists both-sides changes with hotspot notes"
}

test_status_flags_enabled_upstream_push() {
  local w
  w=$(new_world pushurl)
  git -C "$w/work" config --unset remote.upstream.pushurl
  run_sync "$w" status
  expect_code 0 "$RC" "status with a live upstream push URL"
  assert_contains "$OUT" "upstream-push: ENABLED" "a push URL equal to the fetch URL is flagged"
  pass "status flags an upstream remote that can be pushed to"
}

test_status_flags_alternate_upstream_push_url() {
  local w
  w=$(new_world altpush)
  git -C "$w/work" remote set-url --push upstream git@github.com:example/firstmate.git
  run_sync "$w" status
  expect_code 0 "$RC" "status with an alternate upstream push URL"
  assert_contains "$OUT" "upstream-push: ENABLED git@github.com:example/firstmate.git" "an explicit alternate push URL is flagged"
  git -C "$w/work" config --unset remote.upstream.pushurl
  git -C "$w/work" config "url.file://$w/.insteadOf" "$w/"
  git -C "$w/work" config "url.file://$w/.pushInsteadOf" "$w/"
  run_sync "$w" status
  assert_contains "$OUT" "upstream-push: ENABLED file://$w/upstream.git" "a pushInsteadOf rewrite is flagged"
  pass "status flags an upstream push URL that differs from the fetch URL"
}

test_status_checks_every_push_url_and_redacts() {
  local w
  w=$(new_world pushall)
  git -C "$w/work" remote set-url --add --push upstream "https://user:s3cret@example.invalid/firstmate.git"
  run_sync "$w" status
  expect_code 0 "$RC" "status with a second, usable push URL"
  assert_contains "$OUT" "upstream-push: ENABLED https://example.invalid/firstmate.git" "a usable push URL after DISABLED is flagged"
  assert_not_contains "$OUT" "s3cret" "credentials in a remote URL are not printed"
  pass "status checks every upstream push URL and redacts credentials"
}

test_status_refuses_a_branch_deleted_upstream() {
  local w
  w=$(new_world deleted)
  run_sync "$w" status
  expect_code 0 "$RC" "status before the upstream branch is deleted"
  git -C "$w/upstream.git" branch -q -m main trunk
  run_sync "$w" status
  expect_code 2 "$RC" "status after the upstream branch is deleted"
  assert_contains "$OUT" "fetching main from 'upstream' failed" "the missing branch is named instead of using the stale tracking ref"
  pass "status refuses a branch deleted on its remote"
}

test_status_ignores_inherited_git_dir() {
  local w fork
  w=$(new_world gitdir)
  fork=$(git -C "$w/fork.git" rev-parse main)
  RC=0
  OUT=$(GIT_DIR="$w/up-src/.git" GIT_WORK_TREE="$w/up-src" FM_ROOT_OVERRIDE="$w/work" "$SYNC" status 2>&1) || RC=$?
  expect_code 0 "$RC" "status with an inherited GIT_DIR"
  assert_contains "$OUT" "fork: origin/main $fork" "status reads the fork checkout, not the inherited repository"
  pass "status ignores an inherited GIT_DIR"
}

test_status_treats_unlisted_conflict_as_conflict() {
  local w real_git
  w=$(new_world unlisted)
  upstream_commit "$w" other.md "other upstream" "upstream other"
  real_git=$(command -v git)
  mkdir -p "$w/fakebin"
  cat > "$w/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = merge-tree ]; then
  printf '%s\n' 4b825dc642cb6eb9a060e54bf8d69288fbee4904
  exit 1
fi
exec "$real_git" "\$@"
SH
  chmod +x "$w/fakebin/git"
  RC=0
  OUT=$(PATH="$w/fakebin:$PATH" FM_ROOT_OVERRIDE="$w/work" "$SYNC" status 2>&1) || RC=$?
  expect_code 0 "$RC" "status when merge-tree reports a conflict without a path"
  assert_contains "$OUT" "conflict: (unlisted)" "an unnamed conflict is reported"
  assert_contains "$OUT" "summary: conflicts=1" "an unnamed conflict is not summarized as clean"
  pass "status treats a merge-tree conflict without a path as a conflict"
}

test_status_fails_without_upstream_remote() {
  local w
  w=$(new_world noremote)
  git -C "$w/work" remote remove upstream
  run_sync "$w" status
  expect_code 2 "$RC" "status without the upstream remote"
  assert_contains "$OUT" "no 'upstream' remote" "the missing remote is named"
  pass "status refuses without an upstream remote"
}

test_merge_refusals() {
  local w
  w=$(new_world refuse)
  upstream_commit "$w" other.md "other upstream" "upstream other"
  run_sync "$w" merge
  expect_code 2 "$RC" "merge on the default branch"
  assert_contains "$OUT" "default branch" "the default-branch refusal is explained"
  run_sync "$w" merge --branch main
  expect_code 2 "$RC" "merge --branch main"
  git -C "$w/work" checkout -q --detach
  run_sync "$w" merge
  expect_code 2 "$RC" "merge on a detached HEAD"
  assert_contains "$OUT" "detached" "the detached-HEAD refusal is explained"
  git -C "$w/work" checkout -q -b sync main
  printf 'dirty\n' >> "$w/work/other.md"
  run_sync "$w" merge
  expect_code 2 "$RC" "merge with tracked changes"
  assert_contains "$OUT" "tracked changes" "the dirty-tree refusal is explained"
  git -C "$w/work" checkout -q -- other.md
  git -C "$w/work" checkout -q -b stale HEAD~1
  run_sync "$w" merge
  expect_code 2 "$RC" "merge from a branch missing the fork tip"
  assert_contains "$OUT" "does not contain origin/main" "the stale-base refusal is explained"
  assert_absent "$w/work/.git/MERGE_HEAD" "a refusal leaves no merge in progress"
  pass "merge refuses unsafe starting points"
}

test_merge_clean_creates_real_merge_and_never_pushes() {
  local w up fork_before up_before
  w=$(new_world clean)
  upstream_commit "$w" other.md "other upstream" "upstream other"
  up=$(git -C "$w/upstream.git" rev-parse main)
  fork_before=$(refs_of "$w/fork.git")
  up_before=$(refs_of "$w/upstream.git")
  run_sync "$w" merge --branch upstream-sync
  expect_code 0 "$RC" "clean merge"
  assert_contains "$OUT" "summary: clean" "clean merge summary"
  assert_equals "upstream-sync" "$(git -C "$w/work" symbolic-ref --short HEAD)" "--branch creates and checks out the sync branch"
  assert_equals "$up" "$(git -C "$w/work" rev-parse HEAD^2)" "upstream's tip is the merge commit's second parent"
  assert_equals "$(git -C "$w/fork.git" rev-parse main)" "$(git -C "$w/work" rev-parse HEAD^1)" "the fork tip is the first parent"
  assert_equals "$fork_before" "$(refs_of "$w/fork.git")" "merge must not push to the fork"
  assert_equals "$up_before" "$(refs_of "$w/upstream.git")" "merge must not push to upstream"
  run_sync "$w" merge
  expect_code 0 "$RC" "merge when already current"
  assert_contains "$OUT" "summary: current" "a second merge finds nothing to do"
  pass "merge makes a real merge commit on a sync branch and pushes nothing"
}

test_merge_failure_removes_created_branch() {
  local w
  w=$(new_world blocked)
  upstream_commit "$w" added.md "upstream added" "upstream adds a file"
  printf 'local\n' > "$w/work/added.md"
  run_sync "$w" merge --branch upstream-sync
  expect_code 2 "$RC" "merge blocked by an untracked file"
  assert_contains "$OUT" "without leaving a merge" "the failed merge is explained"
  assert_equals "main" "$(git -C "$w/work" symbolic-ref --short HEAD)" "a failed merge returns to the starting branch"
  assert_equals "" "$(git -C "$w/work" branch --list upstream-sync)" "a failed merge deletes the branch it created"
  rm "$w/work/added.md"
  run_sync "$w" merge --branch upstream-sync
  expect_code 0 "$RC" "retrying with the same --branch"
  assert_contains "$OUT" "summary: clean" "the retry merges"
  pass "merge --branch cleans up the branch when git merge fails outright"
}

test_merge_conflict_left_for_resolution() {
  local w
  w=$(new_world conflict)
  upstream_commit "$w" notes.md "notes upstream" "upstream notes"
  git -C "$w/work" checkout -q -b sync
  run_sync "$w" merge
  expect_code 1 "$RC" "conflicting merge"
  assert_contains "$OUT" "conflict: notes.md" "the conflicting file is listed"
  assert_contains "$OUT" "summary: conflicts=1" "conflict summary"
  assert_present "$w/work/.git/MERGE_HEAD" "the merge stays in progress for resolution"
  run_sync "$w" merge
  expect_code 2 "$RC" "merge while a merge is in progress"
  assert_contains "$OUT" "already in progress" "an unfinished merge is refused"
  pass "merge leaves conflicts in the index and exits 1"
}

test_status_current
test_status_reports_without_touching_the_checkout
test_status_hotspot_and_review
test_status_fm_prefix_ignores_diff_noprefix
test_status_flags_enabled_upstream_push
test_status_flags_alternate_upstream_push_url
test_status_fails_without_upstream_remote
test_status_checks_every_push_url_and_redacts
test_status_refuses_a_branch_deleted_upstream
test_status_ignores_inherited_git_dir
test_status_treats_unlisted_conflict_as_conflict
test_merge_refusals
test_merge_clean_creates_real_merge_and_never_pushes
test_merge_failure_removes_created_branch
test_merge_conflict_left_for_resolution

echo "# all fm-upstream-sync tests passed"
