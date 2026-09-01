# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard implementation and adapters are unchanged.
They remain the final backstop rather than the normal continuity mechanism.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## External arm kills

A CONFIRMED watcher's lifecycle belongs to the home singleton lock, not to the arm process that started it.
The arm forks the watcher into its own process group, so a group-targeted kill of the arm's task tree cannot reach it.
Once the arm has printed `watcher: started`, a TERM/HUP/INT to the arm exits the arm with the signal status, records the interrupted cycle with `successor=detached:<pid>`, and leaves the watcher supervising; the next arm invocation attaches to it through the ordinary healthy-watcher path, so no wake is lost between the kill and the re-arm.
Before confirmation the old teardown contract holds: a signaled arm still stops its unconfirmed child, which is what the Pi/OpenCode adapters' bounded unready-arm retirement relies on.
A detached watcher is bounded - it exits at its next actionable wake, which is durably queued either way - and `--restart` still stops exactly this home's watcher through the recorded lock pid.
The arm never relaunches anything from inside its own signal handler.

Every TERM/HUP/INT received by the arm, and by the away-mode daemon's shutdown handler, also appends one line to the size-capped `state/.signal-provenance.log` (`fm_signal_provenance_log` in `bin/fm-wake-lib.sh`).
Each line records the launch-time parent pid and command, the current parent pid, the process group ids, and the child's state at trap time, which together distinguish a single-pid TERM from a group- or tree-targeted kill.

While `state/.afk` exists with no live daemon holding `state/.supervise-daemon.lock`, away mode is flagged but unsupervised - the state an external kill of the daemon's host task leaves behind.
`bin/fm-turnend-guard.sh` blocks the next turn end for it (even with zero tasks in flight) and `bin/fm-guard.sh` warns on every guarded command, both pointing at the `/afk` restart owner.

### Evidence, 2026-08-31

Kills of harness-hosted supervision tasks were reproduced and attributed on Claude Code (Darwin 25.6.0).
A probe with the arm's process shape (parent traps TERM; child bash sleeps with its own TERM trap) was run as a tracked background Bash task and stopped through the harness:

```text
parent: pid=41493 pgid=41491 ppid=41491 pcmd=[/bin/zsh -c ...]
child:  pid=41499 pgid=41491
child: got TERM, exiting clean
parent trap: sig=TERM child_stat=[Z] ppid_now=1
```

The child received TERM directly and was already a zombie when the parent's trap ran, and the parent was orphaned to pid 1: the harness signals the whole process group, so no in-arm handler choice could previously save a same-group watcher.
Upstream, unexpected SIGTERM kills of long-lived `run_in_background` tasks are known Claude Code defects, not a documented or configurable lifetime cap: anthropics/claude-code#87496 (kills ~30-90s after the owning turn ends) and #87948 (kills seconds after the arming turn ends), with #90616 showing a killed background task can even be reported to the model as completed.

With the survival contract in place, a group TERM of the arm's own process tree left the watcher supervising with the lock intact, a fresh arm reported `watcher: attached`, and a subsequent status write still produced the queued wake and the attached arm's typed close.
Regression coverage: `test_confirmed_arm_signal_detaches_watcher_and_cleans_temp`, `test_group_term_of_arm_tree_spares_watcher`, and `test_unconfirmed_arm_signal_still_kills_child` in `tests/fm-watcher-lock.test.sh`.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
That quit observation predates the external-kill survival contract above: a confirmed watcher now outlives arm retirement, and `tests/fm-pi-primary-live-e2e.test.sh` asserts the surviving watcher stops through its recorded lock pid instead.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
