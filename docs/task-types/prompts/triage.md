# Triage

You have just produced a plan. Now decide how it should be executed.

## Decision

Choose one:

- **implement** — The plan is small enough for a single implementation task.
  Use this when changes touch a few files, have no parallelizable sub-parts,
  and can be completed in one coherent commit.

- **decompose** — The plan should be split into multiple parallel sub-tasks.
  Use this when the plan involves independent changes across different areas
  of the codebase, or when splitting would allow meaningful parallel work.

## Constraints

- This is a routing decision only. Do not revise the plan.
- Prefer `implement` when in doubt — decomposition adds overhead.
- Choose `decompose` only when there are clearly independent work streams.
