# Execute

You have a plan. Decide how it should be executed.

## Decision

Choose one:

- **implement** — The plan is small enough for a single implementation task.
  Use this when changes touch a few files and can be completed in one coherent
  commit.

- **decompose** — The plan should be split into smaller, focused sub-tasks.
  Use this when the plan covers multiple distinct concerns that are better
  handled as separate, self-contained work units. Decomposition produces
  clarity, not parallelism — sub-tasks run serially.

## Constraints

- You have read-only access — editing tools are not available to you (enforced
  by the sandbox).
- This is a routing decision only. Do not revise the plan.
- Prefer `implement` when in doubt — decomposition adds overhead.
- Choose `decompose` only when the plan has clearly separable concerns.

## Action

- **implement**: Call the `mcp__cydo__SwitchMode` tool with `continuation: "implement"`.
- **decompose**: Call the `mcp__cydo__SwitchMode` tool with `continuation: "decompose"`.

The task description follows, provided by the parent task.

--------------------------------------------------------------------------------

Read the plan from the file path below before making your decision.

{{task_description}}
