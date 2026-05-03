`mcp__cydo__SwitchMode` to `decompose` succeeded. You are already in decompose mode.
Do not re-run triage and do not re-evaluate whether decomposition is needed.

Before dispatching anything, do an intake:

1. **Restate the plan** — In 1-3 sentences: the overall goal, the major
   phases the plan describes, and what direction was already decided.
2. **Sketch the seams** — Identify where the natural unit boundaries are and
   what ordering constraints exist. This is a working sketch you will revise
   as units complete — not a fixed schedule and not a list of sub-tasks to
   spawn all at once.
3. **Name the first unit** — Pick the next concrete unit to dispatch (the
   smallest forward step that is on the critical path or that reduces
   uncertainty for everything that follows). Only scope and dispatch *that*
   unit. Re-enter the orchestration loop after it returns.
4. **Escalate if the restatement is hollow** — If the plan does not give you
   enough direction to find seams (rather than invent them), stop and use
   `mcp__cydo__Ask` instead of producing decomposition that papers over a
   vague plan. Pushing ambiguity downstream into `implement` is the failure
   mode this step exists to prevent.

Treat the prior triage result below as fixed input, then orchestrate it into
implementation-ready sub-tasks one step at a time.

Prior triage result:
{{result_text}}
