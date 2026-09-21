#!/usr/bin/env bash
# Behavior tests for bin/fm-text-check.sh, the advisory repo-text checker.
#
# Each detector is exercised against a fixture diff in a throwaway repo: voice
# tells on added comment-only lines (em dash, spaced hyphen, arrow, banned
# phrases), comment blocks over the limit, comment-heavy files, and commit
# message subject length, body word count, and agent co-author trailers. The
# exit contract is asserted both ways: 0 with findings by default, 1 only under
# --strict, silence plus 0 on a clean diff, and 2 when git rejects the range.
# The banned-phrase list is held to its owner, the marked block of
# docs/repo-text-rule.md, through --list-phrases.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-text-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-text-check)
fm_git_identity

# new_repo <dir>: empty repo with one root commit so HEAD ranges resolve.
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m "root"
}

test_script_parses_and_helps() {
  local out rc
  out=$(bash -n "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-text-check.sh must parse cleanly (got: $out)"
  out=$("$CHECK" --help)
  assert_contains "$out" "Usage and git errors exit 2." "fm-text-check.sh --help omitted its header terminator"
  assert_contains "$out" "docs/repo-text-rule.md" "help must name the rule owner file"
  pass "fm-text-check.sh: parses and renders its header as help"
}

test_comment_tells_are_listed_per_line() {
  local repo out
  repo="$TMP_ROOT/tells"
  new_repo "$repo"
  cat > "$repo/app.js" <<'JS'
// Fetch the widget — the server is slow.
// Note that this ensures the cache is warm.
function f() {
  return 1; // a trailing comment is code, not a comment line
}
JS
  cat > "$repo/tool.sh" <<'SH'
#!/usr/bin/env bash
# Retry -> then fail - previously this looped
echo hi
SH
  cat > "$repo/q.sql" <<'SQL'
-- honestly this is by definition fine → no
-- Truthfully it maps cleanly onto the schema
select 1;
select 2;
select 3;
SQL
  git -C "$repo" add -A
  out=$(cd "$repo" && "$CHECK" --staged)
  assert_contains "$out" "app.js:1: em dash:" "em dash in a comment must be listed with file:line"
  assert_contains "$out" 'app.js:2: "note that":' "banned phrase 'note that' must be listed"
  assert_contains "$out" 'app.js:2: "this ensures":' "banned phrase 'this ensures' must be listed"
  assert_contains "$out" "tool.sh:2: spaced hyphen as a dash:" "spaced hyphen between words must be listed"
  assert_contains "$out" "tool.sh:2: arrow:" "ASCII arrow in a comment must be listed"
  assert_contains "$out" 'tool.sh:2: "previously":' "banned phrase 'previously' must be listed"
  assert_contains "$out" "q.sql:1: arrow:" "Unicode arrow in a dash-comment file must be listed"
  assert_contains "$out" 'q.sql:1: "honestly":' "banned phrase 'honestly' must be listed"
  assert_contains "$out" 'q.sql:1: "by definition":' "banned phrase 'by definition' must be listed"
  assert_contains "$out" 'q.sql:2: "truthful":' "the stem 'truthful' must list 'Truthfully' regardless of case"
  assert_contains "$out" 'q.sql:2: "cleanly":' "banned phrase 'cleanly' must be listed"
  assert_not_contains "$out" "tool.sh:1" "a shebang is not a comment line"
  assert_not_contains "$out" "app.js:4" "a trailing comment after code is not scanned as a comment line"
  pass "fm-text-check.sh: lists each voice tell on added comment lines with file:line"
}

# Every phrase the checker flags must be named inside the rule block that
# docs/repo-text-rule.md owns, so a worker who follows the rule exactly is never
# flagged for a phrase the rule does not mention.
test_banned_phrases_are_named_by_the_owner_doc() {
  local phrases block phrase rc
  phrases=$("$CHECK" --list-phrases); rc=$?
  expect_code 0 "$rc" "--list-phrases must exit 0"
  [ "$(printf '%s\n' "$phrases" | wc -l | tr -d ' ')" -ge 3 ] || fail "--list-phrases printed too few phrases: $phrases"
  block=$(awk '/^<!-- rule-start -->$/ { on = 1; next } /^<!-- rule-end -->$/ { on = 0 } on' "$ROOT/docs/repo-text-rule.md" | tr '[:upper:]' '[:lower:]')
  [ -n "$block" ] || fail "docs/repo-text-rule.md has no marker-delimited rule block"
  while IFS= read -r phrase; do
    [ -n "$phrase" ] || fail "--list-phrases printed an empty line"
    case "$block" in
      *"$phrase"*) ;;
      *) fail "checker flags \"$phrase\" but the rule block in docs/repo-text-rule.md never names it" ;;
    esac
  done <<EOF
$phrases
EOF
  pass "fm-text-check.sh: every banned phrase is named inside the owner doc's rule block"
}

test_long_comment_block_and_density() {
  local repo out
  repo="$TMP_ROOT/blocks"
  new_repo "$repo"
  cat > "$repo/lib.py" <<'PY'
# line one of a block
# line two of a block
# line three of a block
# line four of a block
# line five of a block
x = 1
# a short block
# of two lines
y = 2
PY
  cat > "$repo/main.c" <<'C'
/* Open the socket.
 * Retries are bounded because the kernel already queues connects.
 */
int open_socket(void) {
  return 0;
}
int close_socket(void) {
  return 0;
}
C
  git -C "$repo" add -A
  out=$(cd "$repo" && "$CHECK" --staged)
  assert_contains "$out" "lib.py:1: comment block of 5 lines (limit 4)" "a five-line comment block must be listed at its first line"
  assert_not_contains "$out" "lib.py:7" "a two-line comment block is within the limit"
  assert_contains "$out" "lib.py: 7 comment lines added vs 2 code lines" "a comment-heavy file must be listed with both counts"
  assert_not_contains "$out" "main.c:" "a three-line block comment and a code-heavy file are not listed"
  assert_not_contains "$out" "main.c " "a code-heavy file must not be listed for density"
  pass "fm-text-check.sh: lists comment blocks over four lines and comment-heavy files"
}

test_markdown_and_data_files_have_no_comment_lines() {
  local repo out
  repo="$TMP_ROOT/nocomments"
  new_repo "$repo"
  printf '# Heading — em dash in prose\n\nNote that this is prose.\n' > "$repo/notes.md"
  printf '{"a": 1}\n' > "$repo/data.json"
  git -C "$repo" add -A
  out=$(cd "$repo" && "$CHECK" --staged)
  [ -z "$out" ] || fail "Markdown and data files must produce no findings (got: $out)"
  pass "fm-text-check.sh: Markdown and data files have no comment lines"
}

test_message_checks_only_from_message_file() {
  local repo out rc
  repo="$TMP_ROOT/message"
  new_repo "$repo"
  printf 'x=1\n' > "$repo/a.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "First commit — em dash here"
  printf 'y=2\n' >> "$repo/a.sh"
  git -C "$repo" add -A
  [ -f "$repo/.git/COMMIT_EDITMSG" ] || fail "fixture expected git to leave COMMIT_EDITMSG behind after a commit"
  out=$(cd "$repo" && "$CHECK" --staged)
  assert_not_contains "$out" "message" "staged mode without --message-file must not read the previous commit's COMMIT_EDITMSG"
  {
    printf 'A very long subject line that goes well past the sixty character limit\n\n'
    yes word | head -85 | tr '\n' ' '
    printf '\n\nCo-Authored-By: Claude Fable <noreply@anthropic.com>\n'
  } > "$repo/msg.txt"
  out=$(cd "$repo" && "$CHECK" --staged --message-file msg.txt); rc=$?
  expect_code 0 "$rc" "findings without --strict must still exit 0"
  assert_contains "$out" "message: subject is 70 characters (limit 60):" "an over-long subject must be listed with its length"
  assert_contains "$out" "message: body is 89 words (limit 80)" "an over-long body must be listed with its word count"
  assert_contains "$out" "message: agent co-author trailer: Co-Authored-By: Claude Fable" "an agent co-author trailer must be listed"

  # A commit-msg hook passes git's own editor file, whose comment lines and
  # scissors block are not part of the message.
  {
    printf 'Short subject — with an em dash\n\n# Please enter the commit message\n'
    printf '# ------------------------ >8 ------------------------\n'
    yes word | head -200 | tr '\n' ' '
    printf '\n'
  } > "$repo/editmsg.txt"
  out=$(cd "$repo" && "$CHECK" --staged --message-file=editmsg.txt)
  assert_contains "$out" "message line 1: em dash: Short subject" "the message itself is scanned for voice tells"
  assert_not_contains "$out" "message: body is" "text below the scissors line must not count toward the body"
  assert_not_contains "$out" "message: subject is" "a 31-character subject is within the limit"
  pass "fm-text-check.sh: checks the commit message only when --message-file names it"
}

test_plus_plus_code_line_is_not_a_file_header() {
  local repo out
  repo="$TMP_ROOT/plusplus"
  new_repo "$repo"
  cat > "$repo/loop.c" <<'C'
int i = 0;
while (i < 3)
++ i;
// Note that i is three here
C
  git -C "$repo" add -A
  out=$(cd "$repo" && "$CHECK" --staged)
  assert_contains "$out" 'loop.c:4: "note that":' "a comment after a ++ code line must stay attributed to the real file"
  assert_not_contains "$out" "i;:" "an added line starting with ++ must not be read as a +++ file header"
  pass "fm-text-check.sh: only a header +++ line switches the file being counted"
}

test_range_mode_reads_commits_and_their_message() {
  local repo out
  repo="$TMP_ROOT/range"
  new_repo "$repo"
  printf '# In order to be safe, retry\nx=1\n' > "$repo/a.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "Add retry — with a dash in the subject"
  printf 'y=2\n' >> "$repo/a.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "Append y"
  out=$(cd "$repo" && "$CHECK" HEAD~1)
  assert_contains "$out" 'a.sh:1: "in order to":' "a single revision must be checked as that one commit's diff"
  assert_contains "$out" "message line 1: em dash: Add retry" "a single revision's own message must be checked"
  out=$(cd "$repo" && "$CHECK" HEAD~2..HEAD)
  assert_contains "$out" 'a.sh:1: "in order to":' "a range must include every commit's added lines"
  assert_not_contains "$out" "em dash" "a range checks only the end revision's message"
  printf 'Note that the file wins\n' > "$repo/msg.txt"
  out=$(cd "$repo" && "$CHECK" --message-file msg.txt HEAD~2..HEAD)
  assert_contains "$out" 'message line 1: "note that": Note that the file wins' "--message-file must name the message checked in range mode"
  assert_not_contains "$out" "Append y" "--message-file must replace the end revision's message, not add to it"
  out=$(cd "$repo" && "$CHECK" HEAD~1 --message-file msg.txt)
  assert_contains "$out" 'message line 1: "note that":' "--message-file must override a single revision's message too"
  assert_not_contains "$out" "em dash" "a single revision's own message must not be checked when --message-file is given"
  pass "fm-text-check.sh: range mode diffs the commits and checks the end revision's message unless --message-file names one"
}

test_strict_and_clean_exit_codes() {
  local repo out rc
  repo="$TMP_ROOT/exitcodes"
  new_repo "$repo"
  printf '# Note that x\nx=1\n' > "$repo/a.sh"
  git -C "$repo" add -A
  (cd "$repo" && "$CHECK" --strict >/dev/null); rc=$?
  expect_code 1 "$rc" "--strict must exit 1 when anything was listed"
  (cd "$repo" && "$CHECK" >/dev/null); rc=$?
  expect_code 0 "$rc" "default mode must exit 0 with findings"

  printf 'x=1\n# Bounded because the kernel queues connects.\n' > "$repo/a.sh"
  git -C "$repo" add -A
  out=$(cd "$repo" && "$CHECK" --strict); rc=$?
  expect_code 0 "$rc" "--strict must exit 0 on a clean diff"
  [ -z "$out" ] || fail "a clean diff must print nothing (got: $out)"

  (cd "$TMP_ROOT" && "$CHECK" --bogus >/dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown option must exit 2"
  out=$(cd "$repo" && "$CHECK" nonexistent..HEAD 2>&1); rc=$?
  expect_code 2 "$rc" "a range git cannot resolve must exit 2"
  assert_contains "$out" "error: git diff failed" "a failed git diff must be reported"
  (cd "$repo" && "$CHECK" nonexistent --strict >/dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "a bogus single revision must exit 2 under --strict, not pass as clean"
  pass "fm-text-check.sh: exit 0 by default, 1 under --strict with findings, 2 on usage and git errors"
}

test_script_parses_and_helps
test_comment_tells_are_listed_per_line
test_banned_phrases_are_named_by_the_owner_doc
test_long_comment_block_and_density
test_markdown_and_data_files_have_no_comment_lines
test_message_checks_only_from_message_file
test_plus_plus_code_line_is_not_a_file_header
test_range_mode_reads_commits_and_their_message
test_strict_and_clean_exit_codes
