# Repo text rule

This file is the single owner of the rule for text that a worker writes into a repository: code comments, commit messages, and pull or merge request text.
`bin/fm-brief.sh` inlines the block between the `rule-start` and `rule-end` markers as rule 8 of every ship and scout brief, then appends the path-specific instruction to run `bin/fm-text-check.sh --staged` before each commit.
Edit the rule here and nowhere else; the brief, the checker's banned-phrase list (held to this block by `tests/fm-text-check.test.sh`), and any project-level exception all point back to this file.

The rule follows the study recorded in the firstmate owner's investigation of agent-written comments: workers follow the brief exactly, so the brief has to be specific about length and shape, not only vocabulary.
Two decisions in the block below are repository policy rather than style and are the easiest lines to change:

- Disclosure: no `Co-Authored-By` or other agent trailers on commits; AI assistance is disclosed once per PR/MR, as the line that ends the description prose.
  A signature section the repo's checks require may sit below that line.
- Commit bodies: one to three sentences of why, only when the subject does not already carry it.
  This is the default pending a final ruling on body policy.

`bin/fm-text-check.sh` is the advisory checker for this rule.
It lists the mechanical tells (banned phrases, dashes, arrows, long comment blocks, comment-heavy files, long commit messages) and never decides whether a comment is a genuine why; that judgment stays with the writer.

<!-- rule-start -->
Everything you write into the repo (code comments, commit messages, PR/MR titles and descriptions, review comments, issue text) is read by that repo's engineers, who will not know an agent wrote it and should not be able to tell.
- Comments say what the code cannot: a non-obvious why, a constraint, a gotcha, the source of a workaround.
  Never what the code plainly does, never the change history ("previously X, now Y" goes in the commit), never a copy of an explanation that already exists in another file (name the function that owns it).
  One or two sentences.
  Dates, upstream ticket numbers, and "drop this after" notes go in the commit message or a TODO.
- Commit subject: imperative, under 60 characters.
  Body only when the subject does not carry the why, then one to three sentences: what was wrong, why this fix.
  No per-file changelog, no list of tests, no verification log; those belong in the PR description.
  No `Co-Authored-By` or other agent trailers.
- PR/MR description: the problem, the approach, how you verified it.
  Plain sentences or short bullets without a bold-label formula, ending with one line that discloses AI assistance; that line is the only disclosure and it ends your prose.
  Any signature section the repo's checks require sits below that line, untouched.
  When a pipeline or tool opened the PR/MR, rewrite its generated description to this shape before reporting done, keeping only that signature section.
- No em dashes, no spaced hyphens as dashes, no arrow chains.
  No "Note that", "This ensures", "In order to", no change-history words ("previously", "no longer"), no "by definition".
  No editorial adjectives about the code ("honestly", "truthfully", "cleanly").
  No agent-workflow vocabulary (captain, crewmate, firstmate, scout, secondmate, "brief" as a workflow term, your worktree or pipeline, nautical phrasing).
Before each commit, reread the staged diff's comments and the commit message against this rule and cut what fails it.
If a file's added lines are more comment than code, that is the signal to reread, not a number to hit.
<!-- rule-end -->
