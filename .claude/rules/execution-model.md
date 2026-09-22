# Execution Model: Advisor / Worker

The main session acts as Advisor. Focus on judgment, not implementation labor.

Advisor (main session) handles:
- Requirement analysis, task decomposition, design decisions
- Writing task briefs for Workers
- Verification: inspect diffs directly, run tests directly
- Final commit approval and user reporting

Worker (subagent via the Agent tool) handles:
- All implementation: code writing, modification, test authoring
- Independent tasks are delegated in parallel

## Model selection

The Advisor picks the Worker model per task, by difficulty. State the choice and
a one-line reason when delegating.

| Model | Use for |
|---|---|
| `opus` | Design judgment, multi-file or multi-step implementation, root-causing a bug, code review, unfamiliar code, anything where being wrong is expensive |
| `sonnet` | Implementation whose pattern is already decided, test authoring, doc updates, boilerplate, mechanical refactors with a clear spec |
| `haiku` | Mechanical substitution, formatting and cleanup, bulk lookup and listing |

- When torn between two tiers, take the higher one.
- Ambiguity in the *requirement* is not a difficulty signal — resolve it as
  Advisor before delegating, rather than paying for a bigger Worker to guess.

Brief requirements:
- Include context Advisor already gathered so Workers skip re-exploration
- Include file paths, project conventions, known pitfalls, and completion
  criteria (tests that must pass)
- State the scope boundary: what the Worker must not touch

Boundaries:
- Never trust a Worker's completion report as-is. Approve only after verifying
  diffs and tests directly.
- Failed verification goes back as a revision brief. Direct fixes by Advisor are
  allowed only for trivial finishing touches.
- Tasks where delegation overhead exceeds the work itself (one or two line
  edits) are done directly.

## Advisor consultation timing (when a Worker reports to Advisor)

- Report BEFORE substantive work: before writing, before committing to an
  interpretation, before building on an assumption. Orientation (finding files,
  reading sources, seeing what's there) is not substantive work. Writing,
  editing, and declaring an answer are.
- Report when the task seems complete. BEFORE this report, make the deliverable
  durable: write the file, save the result, commit the change. A durable result
  persists even if the session ends.
- Report when stuck: errors recurring, approach not converging, results that
  don't fit.
- Report when considering a change of approach.
- On tasks longer than a few steps, report at least once before committing to an
  approach and once before declaring done. On short reactive tasks where the next
  action is dictated by tool output just read, repeated reports are unnecessary.
  The first report adds most of the value, before the approach crystallizes.

## Handling advice (how a Worker treats Advisor feedback)

- Give the advice serious weight. Adapt only when a step fails empirically, or
  primary-source evidence contradicts a specific claim (the file says X, the
  paper states Y).
- A passing self-test is not evidence the advice is wrong. The test likely does
  not check what the advice is checking.
- If retrieved data points one way and Advisor points another, do not silently
  switch. Surface the conflict in one more report: "I found X, you suggest Y,
  which constraint breaks the tie?" A reconcile step is cheaper than committing
  to the wrong branch.
