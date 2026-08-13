# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

`complete` and `verify` look a durably-resolved decision up in the active backlog first and in the configured Done archive second.
The backlog's own retention rotates closed items out of the active file, and `tasks-axi show` reads only that active file, so without the archive lookup a session that resolves more decisions than `done_keep` locks its own investigations open.
Only a resolved record is accepted from the archive, and it must carry the same `Resolution recorded by fm-decision-hold.` and `Routed work:` body an active record must carry.
An active hold is never satisfiable from the archive, because the separate active-hold check that guards `resolve` reads the live backlog alone.
`bin/fm-decision-hold.sh`'s header and `--help` own the exact archive-path resolution, snapshot mechanics, and refusal conditions.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Incident: retention hid resolved decisions from the completion gate

Observed 2026-08-13 in the main home, with `.tasks.toml` setting `done_keep = 10` and `archive = "data/done-archive.md"`.
Seventeen `resolve` calls landed successfully, then the completion gate refused.

```text
$ bin/fm-decision-hold.sh complete emotion-scope-division <keys...>
fm-decision-hold: captain decision emotion-scope-division-decision-boundary-position is absent from .../data/backlog.md
```

The decision was not absent.
It had been resolved correctly, with its full resolution body, digest, and routed identities intact, and retention had rotated it out of `data/backlog.md` into `data/done-archive.md`.
Confirmed by hand: `tasks-axi show emotion-scope-division-decision-boundary-position --full` exited 1, while the same id was present in `data/done-archive.md` with its complete resolution content.

Because `verify` reads the same inventory, `bin/fm-teardown.sh` could not clean the investigation up either.
The failure was silent until the gate refused, and the natural workaround - forcing past the refusal - is exactly what the gate exists to prevent.
Any session resolving more than `done_keep` decisions at once reproduces it.

The defect and the fix were reproduced at the reported scale in a synthetic home using the same `.tasks.toml`: seventeen holds registered, routed, and resolved, leaving 10 resolved decisions in the active backlog and 7 in the archive.

```text
$ tasks-axi show incident-scope-review-decision-choice-1 --full
error: "Task \"incident-scope-review-decision-choice-1\" not found in this backlog"
code: NOT_FOUND

$ bin/fm-decision-hold.sh complete incident-scope-review choice-1 ... choice-17    # before
fm-decision-hold: captain decision incident-scope-review-decision-choice-1 is absent from /tmp/inc/data/backlog.md

$ bin/fm-decision-hold.sh complete incident-scope-review choice-1 ... choice-17    # after
complete: incident-scope-review decision inventory reviewed (choice-1,choice-10,...,choice-9)

$ bin/fm-decision-hold.sh verify incident-scope-review                             # after
verified: incident-scope-review unresolved-decision inventory
```

`tasks-axi` 0.2.5 exposes no archive query: `show` and `list` read one backlog file, and `--file` pointed at the configured archive is refused with `Archive path must not be the active backlog path`.
The fallback therefore queries a private throwaway snapshot of the archive whose `## Archived <date>` headings are normalized to `## Done`, which keeps tasks-axi's own parser as the only record parser instead of hand-parsing markdown.
Verified against 0.2.5: a normalized snapshot returns the identical `show --full` field set for an archived resolved record, including the full `body`, and an archived still-open hold stays unparseable there, so it cannot masquerade as resolved.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Done-archive lookup regression verification date: 2026-08-13, with ShellCheck 0.11.0 and tasks-axi 0.2.5.
Two backend scripts, `tests/fm-backend-orca.test.sh` and `tests/fm-backend.test.sh`, failed on that date both on the change branch and on the unmodified base, so they are pre-existing and unrelated to the archive lookup.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The Done-archive regression drives the incident above through the backlog's own `tasks-axi prune` retention rather than hand-moving records, and asserts all four boundaries: a resolved archived decision passes, an archived record stripped of its resolution markers still refuses, an open hold present only in the archive satisfies neither the active-hold check nor completion, and an absent, missing, or corrupt archive refuses exactly as before instead of passing.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a resolved decision in the Done archive satisfies the gate while open and unresolved records still refuse
ok - an absent, missing, or corrupt archive refuses exactly as before rather than passing

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ bash tests/fm-backend-orca.test.sh    # fails identically on the unmodified base
not ok - Orca spawn should fail when metadata cannot be written

$ bash tests/fm-backend.test.sh         # fails identically on the unmodified base
not ok - fm-send --key: old vs new exit code: expected exit 1, got 0

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
