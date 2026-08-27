#!/usr/bin/env bash
# Behavior tests for the Mission Control board (docs/mission-control.md):
# server lifecycle via fm-mission-control.sh, card rendering from initiative
# files, inbox event queueing, local doc rendering with the data/ containment
# boundary, the inbox poll script, and the registered watcher-check path
# (shim registration, hash-validated snapshot execution, tamper refusal).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

CLI="$ROOT/bin/fm-mission-control.sh"
POLL_SCRIPT="$ROOT/bin/fm-mission-control-poll.sh"

HOME_DIR=$(fm_test_tmproot fm-mc)
export FM_HOME="$HOME_DIR"
STATE="$HOME_DIR/state"
INITIATIVES="$HOME_DIR/data/mission-control/initiatives"
INBOX="$STATE/mission-control/inbox"
mkdir -p "$INITIATIVES" "$HOME_DIR/data/mc-scout" "$STATE"

stop_server() { "$CLI" stop >/dev/null 2>&1 || true; }
trap 'stop_server; fm_test_cleanup' EXIT

# --- fixtures ----------------------------------------------------------------

cat > "$INITIATIVES/fix-login-flakes.md" <<'EOF'
---
title: Fix the flaky login tests
status: waiting-on-you
updated: 2026-08-26T17:40:00Z
work-items: login-flake-f3
decision: Should Safari 16 stay supported?
link: fix PR https://github.com/acme/web/pull/412
link: investigation report data/mc-scout/report.md
link: sneaky /etc/hosts
link: traversal data/../outside.md
link: escape data/mc-scout/escape.md
---
The fix is in review with checks passing.

## History
- 2026-08-26T17:40:00Z: fix PR opened
EOF
cat > "$HOME_DIR/data/mc-scout/report.md" <<'EOF'
# Findings

The race is in **session refresh**.

```
code <tag>
```
EOF
printf 'outside data\n' > "$HOME_DIR/outside.md"
ln -s "$HOME_DIR/outside.md" "$HOME_DIR/data/mc-scout/escape.md"

cat > "$INITIATIVES/deploy-pipeline.md" <<'EOF'
---
title: Speed up the deploy pipeline
status: parked
updated: 2026-08-25T10:00:00Z
---
Parked while the release settles.
EOF

# Closing --- as the last bytes of the file, no trailing newline.
printf -- '---\ntitle: Stub card\nstatus: active\nupdated: 2026-08-26T12:00:00Z\n---' \
  > "$INITIATIVES/stub-card.md"

# --- start the server on a free port -----------------------------------------

started=0
for _ in 1 2 3 4 5; do
  PORT=$((20000 + RANDOM % 20000))
  if FM_MC_PORT=$PORT "$CLI" start > "$HOME_DIR/start.out" 2>&1; then
    started=1
    break
  fi
  stop_server
done
[ "$started" -eq 1 ] || fail "server did not start: $(cat "$HOME_DIR/start.out")"
BASE="http://127.0.0.1:$PORT"
pass "server started via CLI"

out=$(cat "$HOME_DIR/start.out")
assert_contains "$out" "registered: state/mission-control.check.sh" "start registers the inbox check"
assert_present "$STATE/mission-control.check.sh" "check shim installed"
assert_present "$STATE/mission-control.check-trust" "check trust binding written"
mode=$(stat -f %Lp "$STATE/mission-control.check.sh" 2>/dev/null || stat -c %a "$STATE/mission-control.check.sh")
[ "$mode" = 700 ] || fail "check shim mode is $mode, expected 700"
pass "check shim is mode 0700 and registered"

out=$(FM_MC_PORT=$PORT "$CLI" start)
assert_contains "$out" "already running" "second start is idempotent"
assert_contains "$out" "already registered" "second start does not re-register the check"
pass "start is idempotent"

# --- board and cards ----------------------------------------------------------

out=$(curl -sf "$BASE/")
assert_contains "$out" "Mission Control" "board page serves"
assert_contains "$out" "id=\"board\"" "board page carries the card container"
pass "board page renders"

cards=$(curl -sf "$BASE/api/cards")
assert_contains "$cards" '"title":"Fix the flaky login tests"' "card title rendered from initiative file"
assert_contains "$cards" '"status":"waiting-on-you"' "card status rendered"
assert_contains "$cards" '"decisions":["Should Safari 16 stay supported?"]' "decision badge data rendered"
assert_contains "$cards" '"href":"https://github.com/acme/web/pull/412","kind":"external"' "external PR link rendered"
assert_contains "$cards" '"href":"/doc/fix-login-flakes/1","kind":"doc"' "local report link rendered as board doc link"
assert_contains "$cards" '"latest":"The fix is in review with checks passing."' "latest update rendered without history"
assert_contains "$cards" '"status":"parked"' "parked card rendered"
assert_contains "$cards" '"title":"Stub card"' "frontmatter parsed when the closing --- has no trailing newline"
assert_not_contains "$cards" 'title: Stub card' "raw frontmatter never leaks into a card body"
pass "GET /api/cards renders initiative files"

# --- local doc rendering and containment ---------------------------------------

doc=$(curl -sf "$BASE/doc/fix-login-flakes/1")
assert_contains "$doc" "<strong>session refresh</strong>" "doc link renders markdown as HTML"
assert_contains "$doc" "code &lt;tag&gt;" "doc rendering escapes HTML"
pass "local evidence report renders in the board"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/doc/fix-login-flakes/0")
[ "$code" = 404 ] || fail "external link index served as doc (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/doc/fix-login-flakes/2")
[ "$code" = 404 ] || fail "absolute path target served (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/doc/fix-login-flakes/3")
[ "$code" = 404 ] || fail "traversal target outside data/ served (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/doc/fix-login-flakes/4")
[ "$code" = 404 ] || fail "symlink escaping data/ served (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/doc/no-such-card/0")
[ "$code" = 404 ] || fail "unknown initiative served (got $code)"
pass "doc rendering is contained to declared targets under data/"

# --- inbox events ---------------------------------------------------------------

curl -sf -X POST "$BASE/api/message" -H 'content-type: application/json' \
  -d '{"slug":"fix-login-flakes","text":"Ship without Safari 16."}' > /dev/null \
  || fail "message post failed"
curl -sf -X POST "$BASE/api/action" -H 'content-type: application/json' \
  -d '{"slug":"deploy-pipeline","action":"re-engage"}' > /dev/null \
  || fail "action post failed"

msg_file=$(find "$INBOX" -name '*-fix-login-flakes.msg' | head -1)
[ -n "$msg_file" ] || fail "message inbox file missing"
assert_grep "kind: message" "$msg_file" "message event carries kind"
assert_grep "slug: fix-login-flakes" "$msg_file" "message event carries slug"
assert_grep "Ship without Safari 16." "$msg_file" "message event carries body"
act_file=$(find "$INBOX" -name '*-deploy-pipeline.msg' | head -1)
[ -n "$act_file" ] || fail "action inbox file missing"
assert_grep "kind: re-engage" "$act_file" "action event carries kind"
pass "captain input lands as inbox event files"

before=$(find "$INBOX" -name '*.msg' | wc -l | tr -d ' ')
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/message" \
  -H 'content-type: application/json' -d '{"slug":"../evil","text":"x"}')
[ "$code" = 400 ] || fail "invalid slug accepted (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/action" \
  -H 'content-type: application/json' -d '{"slug":"fix-login-flakes","action":"delete-everything"}')
[ "$code" = 400 ] || fail "invalid action accepted (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/message" \
  -H 'content-type: application/json' -d '{"slug":"fix-login-flakes","text":"  "}')
[ "$code" = 400 ] || fail "empty message accepted (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/message" \
  -H 'content-type: text/plain' -d '{"slug":"fix-login-flakes","text":"cross-origin simple request"}')
[ "$code" = 415 ] || fail "non-JSON content type accepted (got $code)"
for body in 'null' '"a-string"' '[1,2]'; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/message" \
    -H 'content-type: application/json' -d "$body")
  [ "$code" = 400 ] || fail "non-object JSON body $body accepted (got $code)"
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$BASE/api/cards")
[ "$code" = 403 ] || fail "foreign Host header served (got $code)"
raw_status=$(exec 3<>"/dev/tcp/127.0.0.1/$PORT" \
  && printf 'GET http://a:99999999/ HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$PORT" >&3 \
  && head -1 <&3; exec 3>&- 3<&- 2>/dev/null || true)
case "$raw_status" in
  *" 400 "*) : ;;
  *) fail "malformed absolute-form request target not refused with 400 (got: $raw_status)" ;;
esac
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/api/cards" || true)
[ "$code" = 200 ] || fail "server died after malformed request target (got $code)"
after=$(find "$INBOX" -name '*.msg' | wc -l | tr -d ' ')
[ "$before" = "$after" ] || fail "rejected input still wrote inbox files"
pass "invalid slugs, actions, content types, hosts, request targets, and empty messages are refused without writes"

# --- the server never mutates initiative files ----------------------------------

assert_grep "status: waiting-on-you" "$INITIATIVES/fix-login-flakes.md" \
  "initiative file untouched by message and action posts"
assert_grep "status: parked" "$INITIATIVES/deploy-pipeline.md" \
  "parked initiative untouched by re-engage post (firstmate owns the write)"
pass "server queues events without mutating work state"

# --- poll script ------------------------------------------------------------------

out=$(FM_STATE_OVERRIDE="$STATE" "$POLL_SCRIPT")
assert_contains "$out" "mission-control inbox:" "poll reports pending inbox"
assert_contains "$out" "fix-login-flakes" "poll names the initiative"
assert_contains "$out" "deploy-pipeline" "poll names every initiative with input"
touch "$INBOX/garbage.msg"
out=$(FM_STATE_OVERRIDE="$STATE" "$POLL_SCRIPT")
assert_contains "$out" "unrecognized file names" "poll reports files outside the naming contract"
rm -f "$INBOX/garbage.msg"
pass "poll wakes on pending input and reports malformed names"

empty_home=$(fm_test_tmproot fm-mc-empty)
out=$(FM_HOME="$empty_home" "$POLL_SCRIPT")
[ -z "$out" ] || fail "poll printed output with no inbox: $out"
mkdir -p "$empty_home/state/mission-control/inbox"
out=$(FM_HOME="$empty_home" "$POLL_SCRIPT")
[ -z "$out" ] || fail "poll printed output for an empty inbox: $out"
pass "poll is silent when nothing is pending"

# --- watcher custom-check path -----------------------------------------------------

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

fm_custom_check_registered "$STATE" mission-control \
  || fail "check registration does not validate"
fm_custom_check_snapshot_prepare "$STATE" mission-control \
  || fail "watcher snapshot preparation failed"
out=$(bash "$FM_CUSTOM_CHECK_SNAPSHOT")
fm_custom_check_snapshot_cleanup
assert_contains "$out" "mission-control inbox:" "watcher-path snapshot execution reports the inbox"
pass "registered shim runs through the watcher's hash-validated snapshot path"

printf '\n# tampered\n' >> "$STATE/mission-control.check.sh"
if fm_custom_check_snapshot_prepare "$STATE" mission-control; then
  fm_custom_check_snapshot_cleanup
  fail "tampered shim still ran"
fi
pass "tampered shim is refused without execution"

out=$("$CLI" install-check)
assert_contains "$out" "registered: state/mission-control.check.sh" "install-check repairs a tampered shim"
fm_custom_check_registered "$STATE" mission-control || fail "repair did not re-register"
pass "install-check repair re-binds the shim"

# --- stop ---------------------------------------------------------------------------

out=$(FM_MC_PORT=$PORT "$CLI" stop)
assert_contains "$out" "stopped" "stop reports"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE/api/cards" || true)
[ "$code" != 200 ] || fail "server still answering after stop"
out=$(FM_MC_PORT=$PORT "$CLI" status)
assert_contains "$out" "server: stopped" "status reports stopped"
assert_contains "$out" "inbox check: registered" "check registration survives server stop"
pass "stop halts the server and keeps the inbox check armed"

# --- readiness-probe failure ---------------------------------------------------

# A fake node that never listens: start must report the failed probe, stop the
# process, and exit non-zero instead of printing started.
fakebin=$(fm_fakebin "$HOME_DIR")
cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$fakebin/node"
rc=0
out=$(FM_MC_READY_SECS=1 FM_MC_PORT=$PORT PATH="$fakebin:$PATH" "$CLI" start 2>&1) || rc=$?
expect_code 1 "$rc" "start with an unresponsive server"
assert_contains "$out" "did not answer" "readiness failure is reported"
assert_not_contains "$out" "started (pid" "an unresponsive server is never announced as started"
assert_absent "$STATE/mission-control/server.pid" "no stale pid file after a failed readiness probe"
pass "a failed readiness probe is reported instead of started"

echo "ok - fm-mission-control"
