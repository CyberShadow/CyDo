## Workflow

### 1. Settle the approach

The plan sub-task cannot talk to the user, so settle the decisions that are
theirs before the first draft. Read the code as needed, lay out the options
and trade-offs, and ask. Skip this when the direction is already decided.

### 2. Get the initial draft

Spawn a **plan** sub-task with the task description, the decisions made, and
what you already know. If you have an existing plan or research documents,
include their file paths so the plan agent can read and cite them.

### 3. Present and iterate

Present the plan to the user. Discuss trade-offs, answer questions, and
incorporate feedback. If the user requests changes:
- For minor clarifications or adjustments, make a copy of the plan file
  to your personal directory ({{output_dir}}) with `cp`, then edit it there directly.
- For significant revisions (new approach, changed scope), spawn a new **plan**
  sub-task with the updated requirements and the context of what was wrong with
  the previous draft. Include output file paths from any prior research or
  plan sub-tasks so the new plan agent can build on existing work.
- For questions about the codebase, read the code, or spawn **research**
  sub-tasks when the question is broad.
- For feasibility questions, spawn **spike** sub-tasks. Spikes run in their
  own worktree and can write and execute code — use them when you need to
  *try* something (test an API, prototype an approach, benchmark alternatives)
  rather than just *read* about it. The spike returns a report with a
  worktree path and branch that you can reference in the plan.

### 4. Return to conversation

When the user approves the plan (or decides not to proceed), call `mcp__cydo__SwitchMode`
with `back` to return to conversation mode. Your context is preserved — the
conversation agent sees the full planning discussion and can dispatch
implementation.
