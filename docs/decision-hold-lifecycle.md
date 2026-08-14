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

The lookup reads only the archive path pinned under `.tasks.toml`'s `[markdown] archive` key.
When that key is absent the fallback is unavailable and the gate refuses exactly as it did before, which is deliberate; the accepted limitation that follows from it is recorded below.

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

The real-world failure shape is confirmed live rather than only synthetic.
On 2026-08-13 two scout closeouts were refused by this exact defect.
The first printed `fm-decision-hold: captain decision ds5-build-vs-buy-decision-codegen-experiment-funding is absent from data/backlog.md`, followed by `REFUSED: scout task ds5-build-vs-buy has not passed the unresolved-decision completion gate.`, and `emotion-scope-division` was refused the same way.
Both holds were durably resolved and sat in `data/done-archive.md` marked `[x]` with `(done 2026-08-13)`, carrying full resolution bodies, digests, and routed identities.
The regression drives that same shape - a hold resolved, rotated into the archive by the backlog's own retention, and its origin scout torn down afterward - so it covers the real failure rather than a fabricated archive fixture.

`tasks-axi` 0.2.5 exposes no archive query: `show` and `list` read one backlog file, and `--file` pointed at the configured archive is refused with `Archive path must not be the active backlog path`.
The fallback therefore stages one private throwaway single-record snapshot per archived record carrying the id, each under a `## Done` heading, and queries them through `tasks-axi show --file`.
That keeps tasks-axi's own parser as the only parser of a record instead of hand-parsing markdown: the split decides only where records start, using the fact that tasks-axi always indents body lines, so an unindented `- [` line is a boundary and never body prose.
Per-record staging is what makes the answer independent of archive ordering, because `show` reports only the first record carrying an id while retention can archive one identity more than once; the id counts as durably resolved when any archived record for it clears the shared bar.
Verified against 0.2.5: a normalized snapshot returns the identical `show --full` field set for an archived resolved record, including the full `body`, and an archived still-open hold stays unparseable there, so it cannot masquerade as resolved.

The archive is consulted when the live backlog has no record for the identity at all, and when it has a SETTLED - closed - captain record that carries no durable resolution.
Without the second case, a stale closed live copy of an identity whose resolution had already rotated into the archive made the gate refuse `neither actively held nor durably resolved` for a decision that was in fact durably resolved, and the identical facts passed once retention rotated the stale copy out too.
Retention position must not decide the answer for a settled decision.

The fall-through stops at settled records.
A live record that is open but is not an active captain hold - in flight, unheld, or held for something other than the captain - is an unanswered captain decision in its own right, so it refuses on its own observed state and no archived resolution can satisfy it.
The refusal names all four fields the active-hold check tests, `state`, `held`, `kind`, and `hold_kind`, so it can say which one failed.

Re-holding an archived decision key through this script's own `hold` is a different path with a different answer, and this check is not what governs it.
That record presents as an active captain hold - `state=queued held=yes kind=captain hold_kind=captain` - which the active-hold branch accepts before the settled check is reached, so completion, verification, and teardown all succeed.
That is base-parity behavior, verified identical on base `4bf9c08`, and not a gap in protection: an active captain hold is a legitimate durable state, and such a decision is gated by that live hold rather than by this check.
What lets the key be re-held at all is `command_hold`'s live-only resolved-key guard, recorded below as a known related gap.

Observed 2026-08-14 in a synthetic home: before the fall-through was narrowed to settled records, an archived answer settled a live record that was open and not an active captain hold.
The reproduction resolves a decision, lets the backlog's own retention archive it, re-holds the same key, and then drops that live copy out of an active captain hold.

```text
$ bin/fm-decision-hold.sh hold sample-reopened-review pick --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample
$ bin/fm-decision-hold.sh resolve sample-reopened-review pick --decision-file pick-decision.txt --routed-to sample-pick-work
$ tasks-axi prune --keep 0 --state done
$ bin/fm-decision-hold.sh hold sample-reopened-review pick --title "Choose the sample pick" --reason "captain pick choice pending" --repo sample
$ tasks-axi unhold sample-reopened-review-decision-pick

$ tasks-axi show sample-reopened-review-decision-pick --full
  state: queued
  held: no
  hold_kind: "-"
  kind: captain
  body: "Origin: sample-reopened-review\nDecision key: pick\nState: awaiting captain decision."

$ bin/fm-decision-hold.sh complete sample-reopened-review pick    # before narrowing
complete: sample-reopened-review decision inventory reviewed (pick)
                                                                        # rc=0

$ bin/fm-decision-hold.sh complete sample-reopened-review pick    # after narrowing
fm-decision-hold: captain decision sample-reopened-review-decision-pick has an open unresolved record in .../data/backlog.md (state=queued held=no kind=captain hold_kind="-")
                                                                        # rc=1
```

`tasks-axi start` in place of `unhold` reproduces it through a distinct live shape, one that keeps its captain hold but leaves `state=in_flight`.

```text
$ tasks-axi start sample-reopened-review-decision-pick
$ tasks-axi show sample-reopened-review-decision-pick --full
  state: in_flight
  held: yes
  hold_kind: captain
  kind: captain

$ bin/fm-decision-hold.sh complete sample-reopened-review pick    # before narrowing
complete: sample-reopened-review decision inventory reviewed (pick)
                                                                        # rc=0

$ bin/fm-decision-hold.sh complete sample-reopened-review pick    # after narrowing
fm-decision-hold: captain decision sample-reopened-review-decision-pick has an open unresolved record in .../data/backlog.md (state=in_flight held=yes kind=captain hold_kind=captain)
                                                                        # rc=1
```

Both refusals match what base `4bf9c08` did before any archive lookup existed, so teardown can no longer erase the source of one of these decisions.
Settling either copy without a resolution restores the stale-record case, and the archive answers it again, so the narrowing does not revert the fix.

```text
$ tasks-axi done sample-reopened-review-decision-pick
$ tasks-axi show sample-reopened-review-decision-pick --full
  state: done
  held: no

$ bin/fm-decision-hold.sh complete sample-reopened-review pick    # after narrowing
complete: sample-reopened-review decision inventory reviewed (pick)
                                                                        # rc=0
```

Re-holding the same archived key through `bin/fm-decision-hold.sh hold` alone, with no `unhold` or `start` after it, is the base-parity case above rather than a refusal.
Verified 2026-08-14 against both this revision and base `4bf9c08` in the same home: the record is an active captain hold, and both revisions pass it.

```text
$ bin/fm-decision-hold.sh hold sample-reheld-review pick --title "Pick" --reason "captain pick pending" --repo sample
sample-reheld-review-decision-pick

$ tasks-axi show sample-reheld-review-decision-pick --full
  state: queued
  held: yes
  hold_kind: captain
  kind: captain

$ bin/fm-decision-hold.sh complete sample-reheld-review pick    # this revision
complete: sample-reheld-review decision inventory reviewed (pick)
                                                                        # rc=0

$ bin/fm-decision-hold.sh verify sample-reheld-review              # this revision
verified: sample-reheld-review unresolved-decision inventory
                                                                        # rc=0

$ bin/fm-decision-hold.sh complete sample-reheld-review pick    # base 4bf9c08
complete: sample-reheld-review decision inventory reviewed (pick)
                                                                        # rc=0
```

The refusal names `hold_kind` because that field alone can be what failed.
Verified 2026-08-14: a record held for something other than the captain satisfies `state`, `held`, and `kind`, so without `hold_kind` the message printed only fields that look like a valid active captain hold and could not explain its own refusal.

```text
$ tasks-axi hold sample-hk-review-decision-pick --reason "external pending" --kind external
$ tasks-axi show sample-hk-review-decision-pick --full
  state: queued
  held: yes
  hold_kind: external
  kind: captain

$ bin/fm-decision-hold.sh complete sample-hk-review pick
fm-decision-hold: captain decision sample-hk-review-decision-pick has an open unresolved record in .../data/backlog.md (state=queued held=yes kind=captain hold_kind=external)
                                                                        # rc=1
```

An accepted limitation, verified 2026-08-14 on tasks-axi 0.2.5: the lookup reads only the archive path pinned under `[markdown] archive`, while tasks-axi archives to a default `<backlog-dir>/done-archive.md` even when that key - or the whole `.tasks.toml` - is absent.
A home that does not pin the key therefore still reproduces the original defect.

```text
$ cat .tasks.toml
backend = "markdown"

[markdown]
path = "data/backlog.md"
done_keep = 10

$ tasks-axi prune --keep 0 --state done
ok: prune done -> archived 1 (kept 0)

$ ls data/
backlog.md
done-archive.md
sample-noarchivekey-review

$ grep -c "Resolution recorded by fm-decision-hold." data/done-archive.md
1

$ bin/fm-decision-hold.sh complete sample-noarchivekey-review pick
fm-decision-hold: captain decision sample-noarchivekey-review-decision-pick is absent from .../data/backlog.md
```

That is accepted rather than fixed: honoring tasks-axi's own default archive location is out of this change's scope, and the absent-key path must keep refusing exactly as it did before.
This repo's tracked `.tasks.toml` pins the key, and the regression suite copies it into every synthetic home, so the shipped path is covered.

Two further consequences are intentional and stated here rather than left for a reader to discover.
First, the fallback removes an implicit fail-closed on an unreadable live backlog: tasks-axi cannot distinguish a corrupt backlog from an empty one, so a corrupt `data/backlog.md` now lets `verify` succeed from the archived record alone.
That is the right answer, because an archived resolution record is genuine evidence that the decision was resolved, and the fail-closed requirement was scoped to the archive rather than to the live backlog.
Second, `command_hold`'s "already durably resolved; use a new decision key" guard still reads only the live backlog, so a resolved key can be re-held once its record has been archived.
Closing that would change when a decision key may be reopened, which is semantic policy owned by `.agents/skills/decision-hold-lifecycle/SKILL.md`, so it is a known related gap outside this change's scope.
It is also what lets the ordering and stale-record regressions build their fixtures through the real script instead of hand-writing archive files.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Done-archive lookup regression verification date: 2026-08-13, with ShellCheck 0.11.0 and tasks-axi 0.2.5.
Reopened-decision narrowing verification date: 2026-08-14, with the same ShellCheck 0.11.0 and tasks-axi 0.2.5.
Two backend scripts fail for reasons that have nothing to do with the archive lookup, and they fail on unmodified base code with no part of this change present.
That was re-verified by cloning main at `4bf9c08` into a throwaway checkout and running the two suites there: `tests/fm-backend.test.sh` fails `not ok - fm-send --key: old vs new exit code: expected exit 1, got 0`, and `tests/fm-backend-orca.test.sh` fails `not ok - Orca spawn should fail when metadata cannot be written`.
Both are therefore pre-existing and not caused by this change.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
Five Done-archive regressions drive the incident above through the backlog's own `tasks-axi prune` retention rather than hand-moving records, and together assert eight boundaries.
`test_resolved_decision_in_done_archive_satisfies_the_gate` covers three: a resolved archived decision passes, an archived record stripped of its resolution markers still refuses with the archive-specific refusal, and an open hold present only in the archive satisfies neither the active-hold check nor completion.
Each of those three refusals is pinned to the identity under test, and the open-hold case resets the inventory to that key alone so which key refuses cannot depend on inventory sort order.
`test_duplicate_archived_identity_is_order_independent` covers the ordering boundary, building both archive orderings of one duplicated identity through the real hold, resolve, and prune lifecycle and requiring the same answer from each.
`test_stale_live_record_still_consults_the_archive` covers the stale-live-record boundary, pairing an archived resolution with a closed unresolved live copy of the same identity and requiring that the answer not change when retention later rotates that live copy out.
`test_reopened_decision_is_not_settled_by_the_archive` covers two: the open-without-an-active-captain-hold boundary in all three live shapes that reach it, `unhold`, `start`, and a non-captain `hold`, and the base-parity boundary for the one shape that does not.
In each of the three, completion, verification, and teardown refuse on the live record's own open state, the refusal is required to quote the fields actually observed so it can explain which one failed, no false attestation is written, and settling that same copy without a resolution then passes from the archive so the narrowing is proved not to revert the stale-record fix.
The base-parity case re-holds an archived key through this script's own `hold` and nothing further, leaving an active captain hold, and requires completion and verification to keep succeeding, pinning the behavior recorded above as unchanged from base rather than leaving it implicit.
`test_absent_archive_config_behaves_as_before` covers the last: an absent, missing, empty, or corrupt archive refuses exactly as before instead of passing, with the corrupt case asserted on its own `is not a text backlog file` refusal so it cannot be satisfied by an ordinary absence.

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
ok - a duplicated archived identity resolves the same way in either ordering
ok - a stale unresolved live record does not hide a durable resolution in the archive
ok - an open live record without an active captain hold is not settled by the archive
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

$ ls tests/*.test.sh | wc -l
      95
```

No all-suites aggregate is claimed here.
Re-counted 2026-08-14: the repository holds 95 test scripts, not the 71 an earlier revision of this record asserted, and two of them - the backend scripts quoted above - fail on unmodified base code.
An "all scripts passed" line therefore cannot be true as written, so it is dropped rather than restated; the whole-repository run is owned by the dedicated test step, and this record keeps only the suites it verified directly.
