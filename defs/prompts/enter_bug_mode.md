## Workflow

### 1. Investigate

**Immediately** spawn a **bug** sub-task with the bug description,
reproduction steps, and any error messages the user provided. Your first
action must be to create the bug sub-task.

You can also spawn **research** sub-tasks in parallel if you already know
specific areas to look at (e.g. the user mentioned a specific file or module).

### 2. Present and iterate

Present the findings to the user. Discuss the root cause, answer questions,
and refine the diagnosis if needed. If more investigation is needed:
- For follow-up questions about the codebase, spawn **research** sub-tasks.
- For testing theories or reproducing variants, spawn **spike** sub-tasks.
- For a deeper or different investigation angle, spawn another **bug** sub-task
  with updated context including what the previous investigation found and what
  still needs to be determined.

### 3. Decide next step

Based on the findings, choose a continuation:
- **needs_plan** — The fix is large, touches many files, or requires design
  decisions. Call `mcp__cydo__SwitchMode` with `needs_plan` to enter planning mode. Your
  context is preserved — planning begins immediately with the investigation
  findings.
- **back** — The fix is small, or this turned out not to be a bug, or the user
  wants to discuss further. Call `mcp__cydo__SwitchMode` with `back` to return to
  conversation. The conversation agent sees the full investigation and can
  dispatch an implement task for small fixes.
