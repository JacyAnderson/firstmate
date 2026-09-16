#!/usr/bin/env bash
# Advisory checker for the repo-text rule (docs/repo-text-rule.md): lists the
# mechanical tells of machine-written comments and commit messages in a diff so
# the writer can reread them before committing. It never judges whether a
# comment is a genuine why; that stays with the writer.
# Usage: fm-text-check.sh [--staged] [--message-file <file>] [--strict]
#        fm-text-check.sh <range> [--strict]
#   Default (or --staged): reads `git diff --cached`. The commit message is
#   checked only when --message-file names it (git's comment lines and scissors
#   block are stripped, so a commit-msg hook can pass its argument); without
#   the flag no message checks run, because .git/COMMIT_EDITMSG holds the
#   previous commit's message, not the one being prepared.
#   <range>: any `git diff` range such as main..HEAD or A...B; a single revision
#   R means R^! (that one commit). The message checked is the range's end
#   revision (HEAD when the range ends in ..).
# What it lists, one finding per line, nothing when clean:
#   - added comment-only lines containing an em dash, a spaced hyphen between
#     words, an arrow (->, =>, or the Unicode arrows), or a banned phrase
#     (BANNED_PHRASES below; the list mirrors docs/repo-text-rule.md);
#   - added comment blocks longer than MAX_COMMENT_BLOCK lines, with file:line;
#   - files whose added comment lines outnumber their added code lines;
#   - a commit subject over MAX_SUBJECT_CHARS characters or a body over
#     MAX_BODY_WORDS words, the same tells inside the message, and an agent
#     co-author trailer.
# Comment detection is by file extension (hash, slash, dash, and HTML comment
# leaders) on comment-only lines; trailing comments after code count as code,
# and Markdown, plain text, and data files have no comment lines.
# Exit status: 0 always, so it can run in every brief without blocking a
# legitimate module header. --strict exits 1 when anything was listed, for
# repos that want it as a hook. Usage and git errors exit 2.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BANNED_PHRASES='note that|this ensures|in order to|previously|no longer|honestly|truthful|by definition'
MAX_COMMENT_BLOCK=4
MAX_SUBJECT_CHARS=60
MAX_BODY_WORDS=80

MODE=staged
RANGE=
MESSAGE_FILE=
STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --staged) MODE=staged ;;
    --strict) STRICT=1 ;;
    --message-file)
      [ "$#" -ge 2 ] || { echo "error: --message-file needs a path" >&2; exit 2; }
      MESSAGE_FILE=$2; shift ;;
    --message-file=*) MESSAGE_FILE=${1#--message-file=} ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$RANGE" ] || { echo "error: only one range is accepted" >&2; exit 2; }
      MODE=range; RANGE=$1 ;;
  esac
  shift
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not inside a git repository" >&2; exit 2; }

diff_text() {
  case "$MODE" in
    staged) git diff --cached --no-color --no-ext-diff --no-prefix -U0 --diff-filter=ACMR ;;
    range)
      case "$RANGE" in
        *..*) git diff --no-color --no-ext-diff --no-prefix -U0 --diff-filter=ACMR "$RANGE" ;;
        *) git diff --no-color --no-ext-diff --no-prefix -U0 --diff-filter=ACMR "$RANGE^!" ;;
      esac ;;
  esac
}

# Prints the commit message to check, or nothing when none is available.
message_text() {
  local end
  case "$MODE" in
    range)
      end=${RANGE##*..}
      [ -n "$end" ] || end=HEAD
      git log -1 --format=%B "$end" ;;
    staged)
      [ -n "$MESSAGE_FILE" ] || return 0
      awk '/^# -+ >8 -+$/ { exit } !/^#/' "$MESSAGE_FILE" ;;
  esac
}

EM_DASH=$(printf '\342\200\224')
ARROW_RIGHT=$(printf '\342\206\222')
ARROW_DOUBLE=$(printf '\342\207\222')

# The awk programs live in temp files so each can read its data on stdin and
# share one tell-detection library, keeping the diff and message checks in step.
AWK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-text-check.XXXXXX") || exit 2
trap 'rm -rf -- "$AWK_DIR"' EXIT HUP INT TERM

cat > "$AWK_DIR/tells.awk" <<'AWK'
function tells(text, where,    lower, i, re) {
  lower = tolower(text)
  if (index(text, emdash)) print where ": em dash: " text
  if (text ~ /[^[:space:]] - [^[:space:]]/) print where ": spaced hyphen as a dash: " text
  if (index(text, arrow) || index(text, darrow) || text ~ / (->|=>) /) print where ": arrow: " text
  for (i = 1; i <= nphrases; i++) {
    re = "(^|[^[:alnum:]])" phrases[i] "([^[:alnum:]]|$)"
    if (lower ~ re) print where ": \"" phrases[i] "\": " text
  }
}
BEGIN { nphrases = split(banned, phrases, "|") }
AWK

cat > "$AWK_DIR/diff.awk" <<'AWK'
# Comment leader family for a path; "none" means the file has no comment lines.
function style(path,    base, ext) {
  base = path; sub(/.*\//, "", base)
  ext = base
  if (index(base, ".")) sub(/.*\./, "", ext); else ext = ""
  ext = tolower(ext); base = tolower(base)
  if (base == "dockerfile" || base == "makefile" || base ~ /^\.(gitignore|gitattributes|env)/) return "hash"
  if (ext ~ /^(sh|bash|zsh|ksh|py|rb|pl|pm|yaml|yml|toml|ini|cfg|conf|tf|r|jl|nix|ps1|awk|sed|cmake|mk)$/) return "hash"
  if (ext ~ /^(js|jsx|ts|tsx|mjs|cjs|go|rs|java|kt|kts|swift|c|h|cc|cpp|cxx|hpp|hh|cs|php|scala|dart|m|mm|groovy|gradle|proto|sol|css|scss|less)$/) return "slash"
  if (ext ~ /^(sql|lua|hs|elm)$/) return "dash"
  if (ext ~ /^(html|htm|xml|vue|svelte|svg)$/) return "html"
  if (ext ~ /^(md|markdown|txt|rst|json|lock|csv|tsv)$/) return "none"
  return "generic"
}
# Returns the comment text with its leader removed, or "\001" when the line is
# not a comment-only line. Tracks /* */ and <!-- --> blocks across lines.
function comment_text(line,    t) {
  t = line; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
  if (inblock) {
    if (index(t, blockend)) inblock = 0
    sub(/^\*+\/?/, "", t); sub(/^-->/, "", t); sub(/^[[:space:]]+/, "", t)
    return t
  }
  if (fstyle == "none") return "\001"
  if ((fstyle == "hash" || fstyle == "generic") && t ~ /^#/ && t !~ /^#!/) { sub(/^#+/, "", t); sub(/^[[:space:]]+/, "", t); return t }
  if (fstyle == "slash" || fstyle == "generic") {
    if (t ~ /^\/\//) { sub(/^\/+/, "", t); sub(/^[[:space:]]+/, "", t); return t }
    if (t ~ /^\/\*/) {
      if (!index(substr(t, 3), "*/")) { inblock = 1; blockend = "*/" }
      sub(/^\/\*+/, "", t); sub(/^[[:space:]]+/, "", t); return t
    }
    if (t ~ /^\*(\/|$|[[:space:]])/) { sub(/^\*+\/?/, "", t); sub(/^[[:space:]]+/, "", t); return t }
  }
  if (fstyle == "dash" && t ~ /^--/) { sub(/^-+/, "", t); sub(/^[[:space:]]+/, "", t); return t }
  if (fstyle == "html" && t ~ /^<!--/) {
    if (!index(substr(t, 5), "-->")) { inblock = 1; blockend = "-->" }
    sub(/^<!--/, "", t); sub(/^[[:space:]]+/, "", t); return t
  }
  return "\001"
}
function end_block() {
  if (blocklen > maxblock) print blockfile ":" blockstart ": comment block of " blocklen " lines (limit " maxblock ")"
  blocklen = 0
}
function end_file() {
  end_block()
  if (file != "" && comments[file] > code[file]) print file ": " comments[file] " comment lines added vs " code[file] " code lines"
}
/^diff --git / { inheader = 1; next }
inheader && /^\+\+\+ / { end_file(); file = substr($0, 5); fstyle = style(file); inblock = 0; comments[file] += 0; code[file] += 0; next }
/^@@ / {
  inheader = 0; end_block(); inblock = 0
  split($3, pos, ","); lineno = substr(pos[1], 2) + 0
  next
}
/^\+/ {
  if (file == "") next
  line = substr($0, 2)
  if (line ~ /^[[:space:]]*$/) { end_block(); lineno++; next }
  text = comment_text(line)
  if (text == "\001") { end_block(); code[file]++ }
  else {
    comments[file]++
    if (blocklen == 0) { blockfile = file; blockstart = lineno }
    blocklen++
    if (text != "") tells(text, file ":" lineno)
  }
  lineno++
  next
}
/^-/ { next }
END { end_file() }
AWK

cat > "$AWK_DIR/message.awk" <<'AWK'
{
  if (subject == "" && $0 ~ /^[[:space:]]*$/) next
  if (subject == "") subject = $0
  else body = body " " $0
  if (tolower($0) ~ /^co-authored-by:.*(claude|codex|copilot|gpt|gemini|anthropic|openai)/) print "message: agent co-author trailer: " $0
  tells($0, "message line " NR)
}
END {
  if (subject == "") exit
  if (length(subject) > maxsubject) print "message: subject is " length(subject) " characters (limit " maxsubject "): " subject
  words = split(body, w, /[[:space:]]+/)
  n = 0; for (i = 1; i <= words; i++) if (w[i] != "") n++
  if (n > maxbody) print "message: body is " n " words (limit " maxbody ")"
}
AWK

if [ -n "$MESSAGE_FILE" ] && [ ! -r "$MESSAGE_FILE" ]; then
  echo "error: cannot read message file $MESSAGE_FILE" >&2
  exit 2
fi

DIFF=$(diff_text) || { echo "error: git diff failed for ${RANGE:-the index}" >&2; exit 2; }
MESSAGE=$(message_text) || { echo "error: git log failed for the end of $RANGE" >&2; exit 2; }

run_checks() {
  printf '%s\n' "$DIFF" | awk -f "$AWK_DIR/tells.awk" -f "$AWK_DIR/diff.awk" \
    -v emdash="$EM_DASH" -v arrow="$ARROW_RIGHT" -v darrow="$ARROW_DOUBLE" \
    -v banned="$BANNED_PHRASES" -v maxblock="$MAX_COMMENT_BLOCK"
  printf '%s\n' "$MESSAGE" | awk -f "$AWK_DIR/tells.awk" -f "$AWK_DIR/message.awk" \
    -v emdash="$EM_DASH" -v arrow="$ARROW_RIGHT" -v darrow="$ARROW_DOUBLE" \
    -v banned="$BANNED_PHRASES" -v maxsubject="$MAX_SUBJECT_CHARS" -v maxbody="$MAX_BODY_WORDS"
}

FINDINGS=$(run_checks)
[ -z "$FINDINGS" ] || printf '%s\n' "$FINDINGS"
if [ "$STRICT" -eq 1 ] && [ -n "$FINDINGS" ]; then
  exit 1
fi
exit 0
