#!/usr/bin/env bash
# Report on, and start, a merge of upstream firstmate into this fork.
#
# Mechanical half of /updatefirstmate's upstream sync; the skill owns when each
# mode runs and how the merged branch reaches the fork. The fork layout is
# origin = the fork, the only remote any delivery path pushes to, and
# upstream = the template repository, used for fetching only. This script
# fetches and merges locally. It never pushes, forces, rebases, squashes, or
# resets.
#
# status (the default) fetches both remotes and prints, without touching HEAD,
# the index, the working tree, or any local branch:
#   upstream: <remote>/<branch> <sha>
#   fork: <remote>/<branch> <sha>
#   merge-base: <sha>
#   behind: <n>       upstream commits the fork does not have yet
#   ahead: <n>        fork commits upstream does not have
#   upstream-push: disabled <url> | ENABLED <url>
#   conflict: <path>[ (hotspot: <note>)]
#   review: <path>[ (hotspot: <note>)]
#   fm-prefix: <path> +<n>
#   summary: current | clean | conflicts=<n>
# conflict lines come from a dry-run merge (git merge-tree) of the fork tip and
# the upstream tip. review lines name files both sides changed since the merge
# base that still merge textually; those are where a fork change can be
# superseded or silently undone. fm-prefix lines count upstream-added lines
# naming an fm/ branch, because upstream defaults ship branches to fm/<id>
# while the fork's default is the bare <id> (FM_DEFAULT_BRANCH_PREFIX in
# bin/fm-branch-prefix-lib.sh). upstream-push reads disabled only when none
# of the upstream remote's effective push URLs (after pushInsteadOf) can name a
# remote: no scheme://, no scp-style [user@]host:path, and no existing local
# path, like the DISABLED placeholder. Anything else reads ENABLED, naming the
# first usable URL with any scheme://user:secret@ userinfo removed. A dry run
# that conflicts without naming a file prints `conflict: (unlisted)`. Each
# branch is fetched by name, so one deleted on its remote is an error rather
# than a stale tracking ref.
#
# merge [--branch <name>] fetches, then merges the upstream tip into the
# current branch with a real merge commit whose second parent is that tip, so
# upstream's history stays in the fork and the next sync starts from it.
# --branch first creates <name> at the fork tip, and deletes it again if git
# merge fails without leaving a merge to resolve. It refuses on the fork's
# default branch, on a detached HEAD without --branch, with tracked changes,
# during an unfinished merge, and when HEAD does not contain the fork tip.
# Exit 0: already current, or merged without conflicts and committed.
# Exit 1: conflicts left in the index, listed in the status format; resolve
# them and finish with `git commit --no-edit`.
# Exit 2: refused or failed, with nothing merged.
#
# hotspot_note below is the fork's list of recurring conflict sites; add an
# entry when a sync hits a new one that will recur.
#
# Remotes and branches default to upstream/main and origin/main; override with
# FM_UPSTREAM_REMOTE, FM_UPSTREAM_BRANCH, FM_FORK_REMOTE, and FM_FORK_BRANCH.
#
# Usage: fm-upstream-sync.sh [status | merge [--branch <name>]] [--help]
set -eu
# A hook or wrapper can export these, which would point every git call below at
# another repository. Config variables stay, so pushInsteadOf still applies.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UP_REMOTE="${FM_UPSTREAM_REMOTE:-upstream}"
UP_BRANCH="${FM_UPSTREAM_BRANCH:-main}"
FORK_REMOTE="${FM_FORK_REMOTE:-origin}"
FORK_BRANCH="${FM_FORK_BRANCH:-main}"
UP_REF="refs/remotes/$UP_REMOTE/$UP_BRANCH"
FORK_REF="refs/remotes/$FORK_REMOTE/$FORK_BRANCH"

usage() { echo "usage: fm-upstream-sync.sh [status | merge [--branch <name>]] [--help]" >&2; }
die() { echo "fm-upstream-sync: $*" >&2; exit 2; }
g() { git -C "$REPO" "$@"; }

# Hides the userinfo of a scheme://user:secret@host URL.
redact_url() {  # <url>
  printf '%s' "$1" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#'
}

push_url_usable() {  # <url>
  case "$1" in *://*) return 0 ;; esac
  case "${1%%/*}" in *:*) return 0 ;; esac
  case "$1" in
    /*) [ -e "$1" ] ;;
    *) [ -e "$REPO/$1" ] ;;
  esac
}

hotspot_note() {
  local notes=""
  case "$1" in
    bin/fm-project-mode.sh|bin/fm-brief.sh|bin/fm-spawn.sh|bin/fm-promote.sh|bin/fm-dod-lib.sh|\
    AGENTS.md|README.md|docs/architecture.md|\
    tests/fm-brief.test.sh|tests/fm-task-delivery.test.sh|tests/fm-control-relaunch.test.sh|tests/fm-fleet-ledger.test.sh)
      notes="$notes; branch-prefix default: keep the bare <id> default from FM_DEFAULT_BRANCH_PREFIX in bin/fm-branch-prefix-lib.sh" ;;
  esac
  case "$1" in
    bin/fm-brief.sh) notes="$notes; repo-text rule 8 renders after upstream's rule 7" ;;
    bin/fm-dod-lib.sh) notes="$notes; rule 8 PR-description steps sit in fm_dod_block's direct-PR and no-mistakes cases" ;;
    bin/fm-spawn.sh) notes="$notes; FM_SPAWN_WORKTREE_TIMEOUT and the branchless-record relaunch fallback" ;;
    bin/fm-merge-local.sh|bin/fm-review-diff.sh|bin/fm-bearings-snapshot.sh)
      notes="$notes; a record without branch= uses the bare <id> branch when it exists, else fm/<id>" ;;
    bin/fm-pr-check.sh|bin/fm-pr-poll.sh) notes="$notes; pr-comments review-comment wakes (GitHub and GitLab only)" ;;
    bin/fm-captain-hold.sh|docs/captain-hold-lifecycle.md) notes="$notes; Done-archive lookup for answered captain calls" ;;
    bin/fm-test-run.sh) notes="$notes; test family lists: keep both sides' entries" ;;
    .github/workflows/ci.yml) notes="$notes; Bearings test count is upstream's plus the fork's" ;;
    .github/workflows/no-mistakes-required.yml) notes="$notes; fork owner exemption" ;;
    docs/scripts.md) notes="$notes; keep the fork's rows (fm-text-check.sh, fm-upstream-sync.sh, review-comment poll)" ;;
    .agents/skills/updatefirstmate/SKILL.md) notes="$notes; fork's upstream sync section" ;;
    .agents/skills/operational-home-layout/*|.agents/skills/ship-landing/*|.agents/skills/agent-skill-trigger-index/*)
      notes="$notes; fork entries for Mission Control and pr-comments" ;;
  esac
  case "$1" in
    AGENTS.md) notes="$notes; port fork lines from sections upstream moved into skills into the owning skill" ;;
  esac
  printf '%s' "${notes#; }"
}

print_paths() {  # <label> ; paths on stdin
  local path note
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    note=$(hotspot_note "$path")
    if [ -n "$note" ]; then
      printf '%s: %s (hotspot: %s)\n' "$1" "$path" "$note"
    else
      printf '%s: %s\n' "$1" "$path"
    fi
  done
}

fetch_remotes() {
  g remote get-url "$UP_REMOTE" >/dev/null 2>&1 || die "no '$UP_REMOTE' remote; add upstream firstmate as a fetch-only remote"
  g remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || die "no '$FORK_REMOTE' remote"
  # Naming each branch in the refspec makes a branch deleted on its remote fail
  # the fetch, rather than leaving a stale tracking ref to be read as current.
  g fetch --quiet "$FORK_REMOTE" "+refs/heads/$FORK_BRANCH:$FORK_REF" \
    || die "fetching $FORK_BRANCH from '$FORK_REMOTE' failed; does the branch exist there?"
  g fetch --quiet "$UP_REMOTE" "+refs/heads/$UP_BRANCH:$UP_REF" \
    || die "fetching $UP_BRANCH from '$UP_REMOTE' failed; does the branch exist there?"
}

# Both-sides and fm/ scans for the sync from <base> to the upstream tip, with
# conflicting paths (one per line) excluded from the review list.
report_details() {  # <base> <fork-side-ref> <conflicts>
  local base=$1 side=$2 conflicts=$3 both
  both=$(comm -12 \
    <(g diff --no-renames --name-only "$base" "$side" | LC_ALL=C sort) \
    <(g diff --no-renames --name-only "$base" "$UP_REF" | LC_ALL=C sort))
  if [ -n "$conflicts" ]; then
    both=$(printf '%s\n' "$both" | LC_ALL=C grep -vxF -f <(printf '%s\n' "$conflicts") || true)
  fi
  printf '%s\n' "$conflicts" | print_paths conflict
  printf '%s\n' "$both" | print_paths review
  g diff --no-renames -U0 "$base" "$UP_REF" | awk '
    /^\+\+\+ / { path = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
    /^\+/ && path != "" && substr($0, 2) ~ /(^|[^A-Za-z0-9_.-])fm\// { count[path]++ }
    END { for (p in count) printf "fm-prefix: %s +%d\n", p, count[p] }
  ' | LC_ALL=C sort
}

cmd_status() {
  local up fork base behind ahead url push_url="" push_state=disabled tree_out rc conflicts n
  fetch_remotes
  up=$(g rev-parse "$UP_REF")
  fork=$(g rev-parse "$FORK_REF")
  base=$(g merge-base "$FORK_REF" "$UP_REF") || die "the fork and upstream share no history"
  behind=$(g rev-list --count "$FORK_REF..$UP_REF")
  ahead=$(g rev-list --count "$UP_REF..$FORK_REF")
  # A push goes to every configured push URL, so any usable one enables it.
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    if push_url_usable "$url"; then
      push_state=ENABLED
      push_url=$url
      break
    fi
    [ -n "$push_url" ] || push_url=$url
  done < <(g remote get-url --push --all "$UP_REMOTE")
  printf 'upstream: %s/%s %s\n' "$UP_REMOTE" "$UP_BRANCH" "$up"
  printf 'fork: %s/%s %s\n' "$FORK_REMOTE" "$FORK_BRANCH" "$fork"
  printf 'merge-base: %s\n' "$base"
  printf 'behind: %s\n' "$behind"
  printf 'ahead: %s\n' "$ahead"
  printf 'upstream-push: %s %s\n' "$push_state" "$(redact_url "$push_url")"
  if [ "$behind" -eq 0 ]; then
    echo "summary: current"
    return 0
  fi
  rc=0
  tree_out=$(g merge-tree --write-tree --name-only --no-messages "$FORK_REF" "$UP_REF") || rc=$?
  case "$rc" in
    0) conflicts="" ;;
    1)
      conflicts=$(printf '%s\n' "$tree_out" | sed 1d)
      # git merge-tree can report a conflict without naming a file.
      [ -n "$conflicts" ] || conflicts="(unlisted)"
      ;;
    *) die "dry-run merge failed (git merge-tree --write-tree needs git 2.38 or newer)" ;;
  esac
  report_details "$base" "$FORK_REF" "$conflicts"
  if [ -z "$conflicts" ]; then
    echo "summary: clean"
  else
    n=$(printf '%s\n' "$conflicts" | grep -c .)
    echo "summary: conflicts=$n"
  fi
}

cmd_merge() {
  local branch="" current start target up base conflicts n
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)
        [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
        branch=$2
        shift 2
        ;;
      *) usage; exit 2 ;;
    esac
  done
  g rev-parse --verify --quiet MERGE_HEAD >/dev/null && die "a merge is already in progress; finish or abort it first"
  [ -z "$(g status --porcelain --untracked-files=no)" ] || die "tracked changes present; commit or move them aside first"
  fetch_remotes
  current=$(g symbolic-ref --quiet --short HEAD || true)
  if [ -n "$branch" ]; then
    [ "$branch" != "$FORK_BRANCH" ] || die "refusing to merge on the fork's default branch '$FORK_BRANCH'"
    g check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name '$branch'"
    g rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && die "branch '$branch' already exists"
  else
    [ -n "$current" ] || die "HEAD is detached; pass --branch <name> or check out a sync branch"
    [ "$current" != "$FORK_BRANCH" ] || die "refusing to merge on the fork's default branch '$FORK_BRANCH'"
    g merge-base --is-ancestor "$FORK_REF" HEAD || die "HEAD does not contain $FORK_REMOTE/$FORK_BRANCH; start the sync branch from the fork tip"
  fi
  up=$(g rev-parse "$UP_REF")
  target=HEAD
  [ -z "$branch" ] || target=$FORK_REF
  if g merge-base --is-ancestor "$UP_REF" "$target"; then
    echo "summary: current"
    return 0
  fi
  if [ -n "$branch" ]; then
    start=${current:-$(g rev-parse HEAD)}
    g checkout --quiet -b "$branch" "$FORK_REF" -- || die "could not create branch '$branch'"
    current=$branch
  fi
  base=$(g merge-base HEAD "$UP_REF") || die "the branch and upstream share no history"
  printf 'branch: %s\n' "$current"
  printf 'upstream: %s/%s %s\n' "$UP_REMOTE" "$UP_BRANCH" "$up"
  printf 'merge-base: %s\n' "$base"
  if g merge --no-ff --no-edit --quiet -m "Merge upstream firstmate ${up:0:8} into the fork" "$UP_REF" >/dev/null; then
    report_details "$base" "HEAD^1" ""
    echo "summary: clean"
    return 0
  fi
  if ! g rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
    if [ -n "$branch" ]; then
      { g checkout --quiet "$start" -- && g branch --quiet -D "$branch"; } || true
    fi
    die "git merge failed without leaving a merge to resolve"
  fi
  conflicts=$(g diff --name-only --diff-filter=U)
  report_details "$base" "HEAD" "$conflicts"
  n=$(printf '%s\n' "$conflicts" | grep -c . || true)
  echo "summary: conflicts=$n"
  exit 1
}

case "${1:-status}" in
  -h|--help) usage; exit 0 ;;
  status) [ $# -le 1 ] || { usage; exit 2; }; cmd_status ;;
  merge) shift; cmd_merge "$@" ;;
  *) usage; exit 2 ;;
esac
