#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits at most one wake line per run and stays silent otherwise, including
# on every error, so a failed lookup can never be read as a merge, a
# degradation, or new review activity:
#   merged            the PR, MR, or change is merged
#   closed            the PR or MR was closed without merging
#   degraded ...      a ready change degraded after its ready report (a failing
#                     check on GitHub, a failing head pipeline on GitLab)
#   pr-comments +N    N new review comments landed since the last poll
# A degraded line names the head or pipeline that degraded, the failed jobs
# with the forge's failure reasons, and the pipeline or check URL, so the wake
# says which test broke without a job-log dig; the watcher dedupes one wake per
# transition on that head/pipeline (bin/fm-watch.sh). A merge always wins the
# run; otherwise new review comments do, and the degraded or merge-train read
# is reported by the next poll.
# The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Forgejo, so an upstream checkout
# needs no extra tooling to follow GitHub or GitLab. The Gerrit and Forgejo
# branches additionally need jq, and so does the GitLab degraded read (its
# rendered view carries no head pipeline state); without jq a GitLab poll
# still wakes on a merge from the plain state field. A GitLab poll also emits
# "ontrain" while the merge request has a merge-train car, and a degraded
# train=dropped line once the car is gone from a still-open merge request; the
# watcher wakes on a drop only after it saw the car on the train.
#
# Comment detection covers GitHub and GitLab only; a Gerrit change or Forgejo
# pull request is polled for its merge alone. It is strictly additive to merge
# detection and degrades silently to merge-only polling whenever the forge, its
# CLI, or its auth cannot answer. Its last-seen watermark lives in a private mutable
# state/<id>.pr-comments file whose path the watcher passes as the optional
# seventh --validated argument (derived from $0 in sidecar mode); the
# --baseline read never passes one, so arming never touches the watermark. The
# file holds a version line, the PR URL it belongs to, and one provider-tagged
# record:
#   github <token-login-or--> <issue-comment-watermark> <review-comment-watermark>
#   gitlab <user-note-count>
# GitHub watermarks are created_at timestamps over the issue-comment and
# review-comment sources, and comments authored by the recorded token identity
# (the supervisor's and workers' own replies) never wake. GitLab uses the
# user-note count from the same glab read the merge check already made;
# note authors are not cheaply distinguishable there, so any increase wakes
# and the supervisor triages. A missing or unreadable watermark record is
# re-initialized silently, so first arm and re-arm never produce a false wake.
# So is a record for another PR, which a poll of the old PR still running
# across a re-arm can write after bin/fm-pr-check.sh removed the file. A v1
# record predates the URL line and is still read.
# Watermark values are validated on read and write and are only ever compared
# as strings or integers; no forge-provided content is ever executed.
set -u
LC_ALL=C
export LC_ALL

# Status of a failed or unreadable forge read: silent success for the watcher,
# a distinct status for the arming baseline read (--baseline, passed only by
# bin/fm-pr-check.sh) so registration can tell "unknown" from "not degraded".
unknown=0
degraded_enabled=0
comments_file=
poll_home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
[ -e "${FM_CONFIG_OVERRIDE:-$poll_home/config}/pr-degraded-watch" ] && degraded_enabled=1
if { [ "$#" -eq 6 ] && [ "$1" = --baseline ]; } \
  || { [ "$#" -ge 6 ] && [ "$#" -le 7 ] && [ "$1" = --validated ]; }; then
  [ "$1" != --baseline ] || unknown=3
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
  [ "$1" = - ] && return 0
  case "$1" in
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
  local version owner record rest
  WM_F1=
  WM_F2=
  WM_F3=
  [ -f "$comments_file" ] && [ ! -L "$comments_file" ] || return 1
  { exec 4< "$comments_file"; } 2>/dev/null || return 1
  IFS= read -r version <&4 || { exec 4<&-; return 1; }
  case "$version" in
    fm-pr-comments-v1) owner=$url ;;
    fm-pr-comments-v2) IFS= read -r owner <&4 || { exec 4<&-; return 1; } ;;
    *) exec 4<&-; return 1 ;;
  esac
  IFS= read -r record <&4 || { exec 4<&-; return 1; }
  if IFS= read -r _extra <&4; then
    exec 4<&-
    return 1
  fi
  exec 4<&-
  [ "$owner" = "$url" ] || return 1
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
  if ! printf '%s\n%s\n%s\n' fm-pr-comments-v2 "$url" "$record" > "$tmp" 2>/dev/null \
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
# wake, never repeat one. Both comment helpers succeed only when they printed
# a wake line, so the caller can end the run there.
github_comments() {
  local me issue_wm review_wm anchor issue_out review_out new_issue_wm new_review_wm
  comments_file_usable || return 1
  if wm_read && wm_login_valid "$WM_F1" && wm_ts_valid "$WM_F2" && wm_ts_valid "$WM_F3"; then
    me=$WM_F1
    issue_wm=$WM_F2
    review_wm=$WM_F3
  else
    me=$(GH_HOST=$host gh api user --jq .login 2>/dev/null) || me=
    wm_login_valid "$me" || me=-
    anchor=$(GH_HOST=$host gh api "repos/$path/pulls/$number" --jq .updated_at 2>/dev/null) || return 1
    wm_ts_valid "$anchor" || return 1
    wm_write "github $me $anchor $anchor" || true
    return 1
  fi
  DELTA=0
  new_issue_wm=$issue_wm
  new_review_wm=$review_wm
  if issue_out=$(GH_HOST=$host gh api "repos/$path/issues/$number/comments?since=$issue_wm&per_page=100" \
    --jq '.[] | "\(.created_at)\t\(.user.login // "")"' 2>/dev/null); then
    count_newer "$issue_wm" "$me" "$issue_out"
    new_issue_wm=$NEW_WM
  fi
  if review_out=$(GH_HOST=$host gh api "repos/$path/pulls/$number/comments?since=$review_wm&per_page=100" \
    --jq '.[] | "\(.created_at)\t\(.user.login // "")"' 2>/dev/null); then
    count_newer "$review_wm" "$me" "$review_out"
    new_review_wm=$NEW_WM
  fi
  if [ "$new_issue_wm" != "$issue_wm" ] || [ "$new_review_wm" != "$review_wm" ]; then
    wm_write "github $me $new_issue_wm $new_review_wm" || return 1
  fi
  [ "$DELTA" -gt 0 ] || return 1
  printf 'pr-comments +%s\n' "$DELTA"
}

# GitLab comment delta: the user-note count from the same glab read the merge
# check already made (the rendered view's comments field, or user_notes_count
# in its JSON), so this adds no request. Any change is stored; only an
# increase wakes.
gitlab_comments() {  # <user-note-count>
  local count=$1 stored
  comments_file_usable || return 1
  wm_count_valid "$count" || return 1
  if wm_read && wm_count_valid "$WM_F1" && [ -z "$WM_F2" ]; then
    stored=$WM_F1
  else
    wm_write "gitlab $count" || true
    return 1
  fi
  [ "$count" != "$stored" ] || return 1
  wm_write "gitlab $count" || return 1
  [ "$count" -gt "$stored" ] || return 1
  printf 'pr-comments +%s\n' $((count - stored))
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot silently address a different project or a differently
# spelled URL. The host is one of those components: a GitHub Enterprise host is
# recorded only by bin/fm-pr-lib.sh after this home named it in
# config/github-hosts, and it is re-checked for shape here like every other
# provider's, because this static body sources nothing and cannot read config.
case "$provider" in
  github)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
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
    [ "$url" = "https://$host/$owner/$repo/pull/$number" ] || exit 0
    if [ "$degraded_enabled" != 1 ]; then
      result=$(GH_HOST=$host gh pr view "$url" --json state --jq '.state' 2>/dev/null) || exit $unknown
      if [ "$result" = MERGED ]; then
        printf '%s\n' merged
        exit 0
      fi
      if [ "$result" = CLOSED ]; then
        printf '%s\n' closed
        exit 0
      fi
      github_comments
      exit 0
    fi
    # One read answers both questions this poll owns: the merged wake it has
    # always owned, and the degraded state firstmate now watches for. The
    # parse runs through gh's own --jq, so no JSON processor is needed here.
    # Any failing check on the rollup counts as degraded because gh's rollup
    # cannot say which checks are required: at the ready report the required
    # checks were green, so a failing one here is a change worth waking for.
    # The degraded line names every failing check with its conclusion and the
    # first one's URL, so the wake says which test broke without a job-log
    # dig. Every error, a non-open state, a pending or green rollup, and an
    # unreadable head all stay silent; only the exact line shape below leaves
    # this branch, and the head is validated here so the watcher's dedupe
    # marker never sees another byte.
    # shellcheck disable=SC2016  # The filter's $f and $r are jq variables, expanded by jq, not the shell.
    result=$(GH_HOST=$host gh pr view "$url" --json state,headRefOid,statusCheckRollup --jq '
      if .state == "MERGED" then
        "merged"
      elif .state == "CLOSED" then
        "closed"
      elif .state == "OPEN"
        and ([.statusCheckRollup[]?
                | select((.conclusion // .state // "") as $r
                         | $r == "FAILURE" or $r == "TIMED_OUT"
                           or $r == "STARTUP_FAILURE" or $r == "ERROR")]
             | length) > 0
      then
        ([.statusCheckRollup[]?
            | select((.conclusion // .state // "") as $r
                     | $r == "FAILURE" or $r == "TIMED_OUT"
                       or $r == "STARTUP_FAILURE" or $r == "ERROR")]) as $f
        | ([$f[] | .detailsUrl // .targetUrl // ""] | .[0] // "") as $u
        | "degraded head=" + (.headRefOid // "")
          + " jobs=" + ([($f[]
              | ((.name // .context // "check") | gsub("[\\n\\r\\t]"; " "))
                + ":" + (((.conclusion // .state // "FAILURE"))
                          | gsub("[\\n\\r\\t]"; " ")))]
            | join(",") | .[:300])
          + (if $u == "" then "" else " url=" + ($u | gsub("[\\n\\r\\t]"; " ")) end)
      else
        ""
      end' 2>/dev/null) || exit $unknown
    if [ "$result" != merged ] && [ "$result" != closed ] && github_comments; then
      exit 0
    fi
    case $result in
      merged)
        printf '%s\n' merged
        ;;
      closed)
        printf '%s\n' closed
        ;;
      'degraded head='*)
        case $result in
          *$'\n'*) exit $unknown ;;
        esac
        head=${result#'degraded head='}
        head=${head%% *}
        case $head in
          ''|*[!0-9a-f]*) exit $unknown ;;
        esac
        [ "${#head}" -eq 40 ] || exit $unknown
        [ "${#result}" -le 2000 ] || exit 0
        printf '%s\n' "$result"
        ;;
    esac
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
    if [ "$degraded_enabled" != 1 ]; then
      raw=$(GITLAB_HOST=$host glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit $unknown
      state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit $unknown
      if [ "$state" = merged ]; then
        printf '%s\n' merged
        exit 0
      fi
      if [ "$state" = closed ]; then
        printf '%s\n' closed
        exit 0
      fi
      gitlab_comments "$(printf '%s\n' "$raw" | sed -n 's/^comments:[[:space:]]*//p' | head -1)"
      exit 0
    fi
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default,
    # and GITLAB_HOST pins it the same way the merge path pins it. It cannot
    # take a merge request URL the way gh does: that form shells out to git
    # for the current repository, and the watcher runs in no repository.
    # The record is read as JSON through glab's own -F json, the same read the
    # merge path makes, because the rendered view carries no head pipeline
    # state. Only an exact "merged" wakes as a merge. A failing head pipeline
    # on a still-open merge request emits the degraded pipeline line, because
    # a merge train drops a merge request when its pipeline does not succeed.
    # Any other open merge request has its merge-train car read: a present car
    # emits "ontrain"; after a car HTTP 404, a readable train list without the
    # merge request triggers one bounded MR-state re-read. An opened or locked
    # re-read emits a degraded train-drop line; a closed re-read emits "closed",
    # and a merged re-read emits "merged". If the re-read fails, the line
    # includes mr_state=unconfirmed so the confirmed drop is not hidden. The
    # watcher wakes only when it last saw the
    # car on the train. Other car or train-list read failures stay silent, as do
    # a pending or green head pipeline and an unreadable initial MR record.
    # Without jq the poll falls back to the plain state field,
    # which keeps the merged wake for a watch armed before jq was required.
    enc=${path//\//%2F}
    gitlab_detail_read() {  # <api path>
        # Each detail read gets its own hard limit of five seconds, so a hung
        # read is cut rather than holding the poll until the watcher's check
        # timeout kills it before it prints. This body sources nothing, so the
        # limit is the same perl fork-and-kill bound the watcher falls back to
        # for its own checks: the read runs in its own process group, which
        # gets TERM then KILL at the deadline. A bare alarm is not enough,
        # because glab's Go runtime ignores SIGALRM. A TERM, INT, or HUP that
        # stops the poll mid-read, such as the watcher's own check timeout,
        # is passed to that group the same way and the read is reaped before
        # perl exits, so a hung glab never outlives the watcher. Without perl
        # no read can be bounded, so gitlab_failure_detail makes none.
        # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
        GITLAB_HOST=$host perl -e 'my $t = shift; my $pid = fork; exit 1 unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } sub stop { kill "TERM", -$pid; select undef, undef, undef, 0.1; kill "KILL", -$pid; waitpid $pid, 0; exit $_[0] } local $SIG{ALRM} = sub { stop(124) }; local $SIG{TERM} = sub { stop(143) }; local $SIG{INT} = sub { stop(130) }; local $SIG{HUP} = sub { stop(129) }; alarm $t; waitpid $pid, 0; exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' 5 glab api "$1"
    }
    gitlab_failure_detail() {  # <pipeline>; sets detail
        # The degraded line names the failed jobs with their forge failure
        # reasons, following a failed bridge into its child pipeline so the
        # wake says which test broke without a job-log dig. Bounded depth and
        # seen-list keep one misbehaving pipeline graph from looping the
        # read, and every read failure simply shortens the detail: a fetch
        # failure can never be read as a change of state. A read budget -
        # at most four pipelines of two time-limited reads each, and none
        # started once this poll has run ten seconds - keeps a large or slow
        # pipeline graph inside the watcher's check timeout, so the known
        # failure is still emitted with whatever detail the budget allowed
        # rather than killed before it prints. Without perl to bound a read,
        # the failure is emitted with no detail rather than risk one.
        detail=
        command -v perl >/dev/null 2>&1 || return 0
        seen=
        frontier="$1:0"
        depth=0
        detail_pipelines=0
        while [ -n "$frontier" ] && [ "$depth" -lt 3 ]; do
          next=
          for entry in $frontier; do
            current=${entry%%:*}
            proj=${entry#*:}
            case $current$proj in *[!0-9]*) continue ;; esac
            case " $seen " in *" $current "*) continue ;; esac
            # A downstream pipeline may live in another project, so it is read
            # through its own project id when the bridge names one.
            base="projects/$enc"
            [ "$proj" = 0 ] || base="projects/$proj"
            [ "$detail_pipelines" -lt 4 ] && [ "$SECONDS" -lt 10 ] || return 0
            detail_pipelines=$((detail_pipelines + 1))
            seen="$seen $current "
            names=$(gitlab_detail_read "$base/pipelines/$current/jobs?per_page=100" 2>/dev/null \
              | jq -r 'if type == "array" then
                  [.[]
                    | select((.status // "") == "failed")
                    | ((.name // "job") | gsub("[\\n\\r\\t]"; " "))
                      + (if (.failure_reason // "") != ""
                         then ":" + ((.failure_reason // "") | gsub("[\\n\\r\\t]"; " "))
                         else ""
                         end)]
                  | join(",")
                else
                  ""
                end' 2>/dev/null) || names=
            [ -n "$names" ] && detail="$detail${detail:+,}$names"
            children=$(gitlab_detail_read "$base/pipelines/$current/bridges?per_page=100" 2>/dev/null \
              | jq -r 'if type == "array" then
                  [.[]
                    | select((.status // "") == "failed")
                    | select((.downstream_pipeline.id // 0) > 0)
                    | "\(.downstream_pipeline.id):\(if (.downstream_pipeline.project_id | type) == "number" then .downstream_pipeline.project_id else 0 end)"]
                  | join(" ")
                else
                  ""
                end' 2>/dev/null) || children=
            [ -n "$children" ] && next="$next${next:+ }$children"
          done
          frontier=$next
          depth=$((depth + 1))
        done
    }
    if ! command -v jq >/dev/null 2>&1; then
      raw=$(GITLAB_HOST=$host glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit $unknown
      state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit $unknown
      if [ "$state" = merged ]; then
        printf '%s\n' merged
        exit 0
      fi
      if [ "$state" = closed ]; then
        printf '%s\n' closed
        exit 0
      fi
      gitlab_comments "$(printf '%s\n' "$raw" | sed -n 's/^comments:[[:space:]]*//p' | head -1)"
      exit 0
    fi
    raw=$(GITLAB_HOST=$host glab mr view "$number" -R "https://$host/$path" -F json 2>/dev/null) || exit $unknown
    [ -n "$raw" ] || exit $unknown
    result=$(printf '%s' "$raw" | jq -r '
      if type == "object"
         and (.state | type) == "string"
         and ((.head_pipeline | type) == "object" or .head_pipeline == null)
      then
        if .state == "merged" then
          "merged"
        elif .state == "closed" then
          "closed"
        elif (.state == "opened" or .state == "locked")
             and (.head_pipeline | type) == "object"
             and (.head_pipeline.status | type) == "string"
             and .head_pipeline.status == "failed"
             and (.head_pipeline.id | type) == "number"
             and .head_pipeline.id > 0
        then
          "degraded pipeline=\(.head_pipeline.id)"
        elif .state == "opened" or .state == "locked" then
          "open \(if (.head_pipeline | type) == "object" and (.head_pipeline.id | type) == "number" then .head_pipeline.id else 0 end) \(.detailed_merge_status // "" | if type == "string" then . else "" end)"
        else
          ""
        end
      else
        error("invalid merge request record")
      end' 2>/dev/null) || exit $unknown
    if [ "$result" != merged ] && [ "$result" != closed ] \
      && gitlab_comments "$(printf '%s' "$raw" | jq -r '.user_notes_count // empty' 2>/dev/null)"; then
      exit 0
    fi
    case $result in
      open\ *)
        reason=${result#open }
        pipeline=${reason%% *}
        reason=${reason#* }
        case $reason in
          *[!a-z_]*) reason= ;;
        esac
        case $pipeline in
          ''|0*|*[!0-9]*) pipeline= ;;
        esac
        [ "${#pipeline}" -le 18 ] || pipeline=
        # stdout is the car record and stderr the CLI's diagnostics: a notice on
        # a good read must not spoil the record, nor noise on a 404 hide it.
        errfile=$(mktemp "${TMPDIR:-/tmp}/fm-pr-poll.XXXXXX") || exit $unknown
        car=$(GITLAB_HOST=$host glab api "projects/$enc/merge_trains/merge_requests/$number" 2>"$errfile")
        car_rc=$?
        car_err=$(cat "$errfile" 2>/dev/null)
        rm -f "$errfile"
        if [ "$car_rc" -eq 0 ]; then
          if printf '%s' "$car" | jq -e 'type == "object" and (.id | type) == "number"' >/dev/null 2>&1; then
            printf '%s\n' ontrain
          elif [ "$unknown" -eq 3 ]; then
            printf '%s\n' train=unknown
          fi
        elif [ "$car_rc" -ne 0 ]; then
          case $car_err in
            *'(HTTP 404)'*) ;;
            *) [ "$unknown" -eq 3 ] && printf '%s\n' train=unknown; exit 0 ;;
          esac
          trains=$(gitlab_detail_read "projects/$enc/merge_trains" 2>/dev/null) || { [ "$unknown" -eq 3 ] && printf '%s\n' train=unknown; exit 0; }
          present=$(printf '%s' "$trains" | jq -er --argjson iid "$number" '
            if type == "array" then
              [ .[].cars[]? | select(.merge_request.iid == $iid) ] | length == 0
            else
              error("invalid merge train list")
            end' 2>/dev/null) || { [ "$unknown" -eq 3 ] && printf '%s\n' train=unknown; exit 0; }
          [ "$present" = true ] || { [ "$unknown" -eq 3 ] && printf '%s\n' train=unknown; exit 0; }
          # A merge can remove the car between the initial MR read and the
          # train-list read. Recheck once, with the same hard read bound, so
          # stale open state cannot turn a merge into a drop wake.
          current=$(gitlab_detail_read "projects/$enc/merge_requests/$number" 2>/dev/null) || current=
          current_state=$(printf '%s' "$current" | jq -er '
            if type == "object" and (.state | type) == "string" then .state
            else error("invalid merge request record")
            end' 2>/dev/null) || current_state=unknown
          case $current_state in
            merged) printf '%s\n' merged; exit 0 ;;
            opened|locked) ;;
            closed) printf '%s\n' closed; exit 0 ;;
            *) current_state=unknown ;;
          esac
          line="degraded train=dropped url=$url"
          [ -z "$reason" ] || line="$line reason=$reason"
          [ -z "$pipeline" ] || line="$line pipeline_url=https://$host/$path/-/pipelines/$pipeline"
          [ "$current_state" != unknown ] || line="$line mr_state=unconfirmed"
          [ "${#line}" -le 2000 ] || exit 0
          printf '%s\n' "$line"
        fi
        exit 0
        ;;
    esac
    case $result in
      merged)
        printf '%s\n' merged
        ;;
      closed)
        printf '%s\n' closed
        ;;
      'degraded pipeline='*)
        case $result in
          *$'\n'*) exit 0 ;;
        esac
        pipeline=${result#'degraded pipeline='}
        case $pipeline in
          [1-9]*) ;;
          *) exit 0 ;;
        esac
        case $pipeline in
          *[!0-9]*) exit 0 ;;
        esac
        [ "${#pipeline}" -le 18 ] || exit 0
        gitlab_failure_detail "$pipeline"
        detail=$(printf '%s' "$detail" | head -c 300)
        case $detail in
          *$'\n'*) detail= ;;
        esac
        line="degraded pipeline=$pipeline url=https://$host/$path/-/pipelines/$pipeline"
        [ -z "$detail" ] || line="$line jobs=$detail"
        [ "${#line}" -le 2000 ] || exit 0
        printf '%s\n' "$line"
        if [ "$unknown" -eq 3 ]; then
          baseline_car=$(GITLAB_HOST=$host glab api "projects/$enc/merge_trains/merge_requests/$number" 2>/dev/null) || baseline_car=
          if [ -n "$baseline_car" ] && printf '%s' "$baseline_car" | jq -e 'type == "object" and (.id | type) == "number"' >/dev/null 2>&1; then
            printf '%s\n' ontrain
          else
            baseline_trains=$(gitlab_detail_read "projects/$enc/merge_trains" 2>/dev/null) || baseline_trains=
            baseline_absent=$(printf '%s' "$baseline_trains" | jq -er --argjson iid "$number" '
              if type == "array" then
                [ .[].cars[]? | select(.merge_request.iid == $iid) ] | length == 0
              else
                error("invalid merge train list")
              end' 2>/dev/null) || baseline_absent=false
            if [ "$baseline_absent" = true ]; then
              :
            else
              printf '%s\n' train=unknown
            fi
          fi
        fi
        ;;
    esac
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
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
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit $unknown
    [ -n "$json" ] || exit $unknown
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit $unknown
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  forgejo)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    [ "$owner" != "$path" ] || exit 0
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v tea >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    # tea addresses a repo by slug only; the host comes from a named login
    # rather than a URL the way gh and glab take one, so the login registered
    # for this exact host is resolved fresh on every poll rather than trusted
    # from anywhere durable. Refuse to guess when zero or more than one
    # registered login matches, rather than picking one arbitrarily.
    # The list is parsed as JSON, never split on quotes per line, so a login
    # printed as one compact object still matches; this is the same filter
    # bin/fm-pr-lib.sh's fm_pr_forgejo_login applies.
    login=$(
      tea login list --output json 2>/dev/null | jq -er --arg h "$host" '
        if type == "array" then
          [ .[]
            | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
                     and (.url | type) == "string")
            | select((.url
                      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                      | sub("[/?#].*$"; "")
                      | sub("^.*@"; "")
                      | sub(":[0-9]+$"; "")) == $h)
            | .name ]
          | if length == 1 then .[0] else error("not exactly one matching login") end
        else
          error("login list is not an array")
        end' 2>/dev/null
    ) || exit $unknown
    [ -n "$login" ] || exit $unknown
    # tea's single-PR view ignores field selection, so the one pull request
    # is read by number from the REST record through "tea api", which keeps
    # the credential inside tea. "tea api" exits 0 on an HTTP error with the
    # error body as output, so only a boolean merged field of true wakes this
    # poll and every other reading stays silent.
    merged=$(tea api --login "$login" --repo "$owner/$repo" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null | jq -r '
        if type == "object" and (.merged | type) == "boolean"
        then .merged | tostring
        else error("invalid pull request record")
        end' 2>/dev/null) || exit $unknown
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
