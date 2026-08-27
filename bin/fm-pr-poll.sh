#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits at most one wake line per run and stays silent otherwise, including
# on every error, so a failed lookup can never be read as a merge or as new
# review activity:
#   merged            the PR or MR is merged
#   pr-comments +N    N new review comments landed since the last poll
# The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# Comment detection is strictly additive to merge detection and degrades
# silently to merge-only polling whenever the forge, its CLI, or its auth
# cannot answer. Its last-seen watermark lives in a private mutable
# state/<id>.pr-comments file whose path the watcher passes as the optional
# seventh --validated argument (derived from $0 in sidecar mode). The file
# holds a version line and one provider-tagged record:
#   github <token-login-or--> <issue-comment-watermark> <review-comment-watermark>
#   gitlab <user-note-count>
# GitHub watermarks are created_at timestamps over the issue-comment and
# review-comment sources, and comments authored by the recorded token identity
# (the supervisor's and workers' own replies) never wake. GitLab uses the
# user-note count from the same glab output the merge check already fetched;
# note authors are not cheaply distinguishable there, so any increase wakes
# and the supervisor triages. A missing or unreadable watermark record is
# re-initialized silently, so first arm and re-arm never produce a false wake.
# Watermark values are validated on read and write and are only ever compared
# as strings or integers; no forge-provided content is ever executed.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -ge 6 ] && [ "$#" -le 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  comments_file=${7-}
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh)
      data=${0%.check.sh}.pr-poll
      comments_file=${0%.check.sh}.pr-comments
      ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

TAB=$(printf '\t')

# --- comment watermark helpers ----------------------------------------------
# Values stored in or read from the watermark file are accepted only in these
# exact shapes, so a corrupted or hand-edited record is re-initialized rather
# than trusted, and nothing read back can ever be more than a compared string.

wm_ts_valid() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9TZ:.-]*) return 1 ;;
  esac
  return 0
}

wm_count_valid() {
  case "$1" in
    0) return 0 ;;
    [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

wm_login_valid() {
  local login=$1 base
  [ "$1" = - ] && return 0
  case "$login" in
    *\[bot\]) base=${login%\[bot\]} ;;
    *) base=$login ;;
  esac
  case "$base" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

comments_file_usable() {
  [ -n "$comments_file" ] || return 1
  [ ! -L "$comments_file" ] || return 1
  if [ -e "$comments_file" ]; then
    [ -f "$comments_file" ] || return 1
  fi
  return 0
}

WM_F1=
WM_F2=
WM_F3=
wm_read() {
  local version record rest
  WM_F1=
  WM_F2=
  WM_F3=
  [ -f "$comments_file" ] && [ ! -L "$comments_file" ] || return 1
  { exec 4< "$comments_file"; } 2>/dev/null || return 1
  IFS= read -r version <&4 || { exec 4<&-; return 1; }
  IFS= read -r record <&4 || { exec 4<&-; return 1; }
  if IFS= read -r _extra <&4; then
    exec 4<&-
    return 1
  fi
  exec 4<&-
  [ "$version" = fm-pr-comments-v1 ] || return 1
  rest=
  IFS=' ' read -r record WM_F1 WM_F2 WM_F3 rest <<EOF
$record
EOF
  [ "$record" = "$provider" ] || return 1
  [ -z "$rest" ] || return 1
  return 0
}

wm_write() {
  local record=$1 tmp
  tmp=$(mktemp "$comments_file.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n%s\n' fm-pr-comments-v1 "$record" > "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" 2>/dev/null \
    || ! mv -f -- "$tmp" "$comments_file" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

# Count one source's comments newer than the given watermark, excluding the
# recorded token identity, from created_at<TAB>login lines. Sets NEW_WM to the
# newest validated created_at seen (any author) and adds to DELTA.
NEW_WM=
DELTA=0
count_newer() {
  local wm=$1 me=$2 lines=$3 ts login
  NEW_WM=$wm
  while IFS="$TAB" read -r ts login; do
    [ -n "$ts" ] || continue
    wm_ts_valid "$ts" || continue
    if [[ "$ts" > "$NEW_WM" ]]; then
      NEW_WM=$ts
    fi
    [[ "$ts" > "$wm" ]] || continue
    if [ "$me" != - ] && [ "$login" = "$me" ]; then
      continue
    fi
    DELTA=$((DELTA + 1))
  done <<EOF
$lines
EOF
  return 0
}

# GitHub comment delta: issue comments and review comments, one newest page
# each, filtered by the token identity recorded at initialization. The
# watermark advances before anything prints, so a lost write can only delay a
# wake, never repeat one.
github_comments() {
  local me issue_wm review_wm anchor issue_out review_out new_issue_wm new_review_wm
  comments_file_usable || return 0
  if wm_read && wm_login_valid "$WM_F1" && wm_ts_valid "$WM_F2" && wm_ts_valid "$WM_F3"; then
    me=$WM_F1
    issue_wm=$WM_F2
    review_wm=$WM_F3
  else
    me=$(gh api user --jq .login 2>/dev/null) || me=
    wm_login_valid "$me" || me=-
    anchor=$(gh api "repos/$path/pulls/$number" --jq .updated_at 2>/dev/null) || return 0
    wm_ts_valid "$anchor" || return 0
    wm_write "github $me $anchor $anchor" || true
    return 0
  fi
  DELTA=0
  new_issue_wm=$issue_wm
  new_review_wm=$review_wm
  if issue_out=$(gh api "repos/$path/issues/$number/comments?since=$issue_wm&per_page=100" \
    --jq '.[] | "\(.created_at)\t\(.user.login // "")"' 2>/dev/null); then
    count_newer "$issue_wm" "$me" "$issue_out"
    new_issue_wm=$NEW_WM
  fi
  if review_out=$(gh api "repos/$path/pulls/$number/comments?since=$review_wm&per_page=100" \
    --jq '.[] | "\(.created_at)\t\(.user.login // "")"' 2>/dev/null); then
    count_newer "$review_wm" "$me" "$review_out"
    new_review_wm=$NEW_WM
  fi
  if [ "$new_issue_wm" != "$issue_wm" ] || [ "$new_review_wm" != "$review_wm" ]; then
    wm_write "github $me $new_issue_wm $new_review_wm" || return 0
  fi
  if [ "$DELTA" -gt 0 ]; then
    printf 'pr-comments +%s\n' "$DELTA"
  fi
  return 0
}

# GitLab comment delta: the user-note count parsed from the same glab field
# output the merge check already fetched, so this adds no request. Any change
# is stored; only an increase wakes.
gitlab_comments() {
  local raw=$1 count stored
  comments_file_usable || return 0
  count=$(printf '%s\n' "$raw" | sed -n 's/^comments:[[:space:]]*//p' | head -1) || return 0
  wm_count_valid "$count" || return 0
  if wm_read && wm_count_valid "$WM_F1" && [ -z "$WM_F2" ]; then
    stored=$WM_F1
  else
    wm_write "gitlab $count" || true
    return 0
  fi
  [ "$count" != "$stored" ] || return 0
  wm_write "gitlab $count" || return 0
  if [ "$count" -gt "$stored" ]; then
    printf 'pr-comments +%s\n' $((count - stored))
  fi
  return 0
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    github_comments
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    if [ "$state" = merged ]; then
      printf '%s\n' merged
      exit 0
    fi
    gitlab_comments "$raw"
    ;;
  *) exit 0 ;;
esac
exit 0
