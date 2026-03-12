# Execute

You have a plan. Decide how it should be executed.

## Decision

Choose one:

- **implement** — The plan is small enough for a single implementation task.
  Use this when changes touch a few files, have no parallelizable sub-parts,
  and can be completed in one coherent commit.

- **decompose** — The plan should be split into multiple parallel sub-tasks.
  Use this when the plan involves independent changes across different areas
  of the codebase, or when splitting would allow meaningful parallel work.

## Constraints

- You have read-only access — editing tools are not available to you (enforced
  by the sandbox).
- This is a routing decision only. Do not revise the plan.
- Prefer `implement` when in doubt — decomposition adds overhead.
- Choose `decompose` only when there are clearly independent work streams.

## Action

- **implement**: Call the `Handoff` tool with `continuation: "implement"` and a
  `prompt` containing the full plan context the implementer needs.
- **decompose**: Call the `SwitchMode` tool with `continuation: "decompose"`.

## Plan

{{task_description}}
