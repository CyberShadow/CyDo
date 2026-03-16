# Sub-task 1: Foundation (Steps 1-3 from plan + cherry-pick)

## Overview

Prepare the codebase for protocol normalization. Four sequential changes, each
with a CI gate (`nix flake check`). No wire protocol changes — these are purely
structural refactors and additions.

## Prior research

- `/home/vladimir/work/cydo/.cydo/tasks/721/output.md` — Backend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/722/output.md` — Frontend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/724/output.md` — Detailed current state
- `/home/vladimir/work/cydo/.cydo/tasks/726/output.md` — Full plan with field mappings

## Master plan

The complete plan is at `/home/vladimir/work/cydo/.cydo/tasks/720/plan.md`.
This sub-task covers the original plan's Steps 1-3 plus the cherry-pick.

## Ordering

This is the first sub-task. No dependencies on other sub-tasks.

---

## Part A: Cherry-pick ae bump

Cherry-pick commit `be4c1ac` from `/home/vladimir/work/cydo/.cydo/tasks/786/worktree`.

This bumps ae to v0.0.3796 which provides the `@JSONExtras` attribute needed
for later steps. If the cherry-pick fails (e.g. due to merge conflicts), resolve
manually — the change should be small (likely just `dub.selections.json` or
similar).

**CI gate: `nix flake check`**

---

## Part B: Route live events through Agent interface (Plan Step 2)

**Goal:** Eliminate direct `translateClaudeEvent` import in `app.d`. All
agent-specific parsing goes through the `Agent` interface.

### `source/cydo/agent/agent.d`

Add four methods to the `Agent` interface:

```d
/// Translate a raw output line to agnostic protocol JSON.
/// Returns null for events that should be consumed.
string translateLiveEvent(string rawLine);

/// Whether a raw output line represents a completed turn.
bool isTurnResult(string rawLine);

/// Whether a raw JSONL line is a user message (for compaction detection).
bool isUserMessageLine(string rawLine);

/// Whether a raw JSONL line is an assistant message (for compaction detection).
bool isAssistantMessageLine(string rawLine);
```

### `source/cydo/agent/claude.d`

Implement the four new methods:
- `translateLiveEvent` → delegates to existing `translateClaudeEvent` (from `protocol.d`)
- `isTurnResult` → `rawLine.canFind("\"type\":\"result\"")`
- `isUserMessageLine` → `rawLine.canFind("\"type\":\"user\"")`
- `isAssistantMessageLine` → `rawLine.canFind("\"type\":\"assistant\"")`

### `source/cydo/agent/codex.d`

Implement the four new methods. Codex already emits agnostic format for live
events, so `translateLiveEvent` returns `rawLine` unchanged. The other three
check for the agnostic type names (`"type":"turn/result"`, etc.) or for
Codex-specific JSONL patterns.

### `source/cydo/app.d`

- In `broadcastTask` (~line 1511): remove `import cydo.agent.protocol : translateClaudeEvent;`.
  Replace `translateClaudeEvent(rawLine)` with `agentForTask(tid).translateLiveEvent(rawLine)`.
- In `onOutput` handler (~line 1215): replace
  `line.canFind("type":"result") || line.canFind("type":"turn/result")`
  with `agentForTask(tid).isTurnResult(line)`.
- In `handleRequestHistory` closure: replace `isUserMessageLine(line)` /
  `isAssistantMessageLine(line)` calls with `ta.isUserMessageLine(line)` /
  `ta.isAssistantMessageLine(line)` (where `ta` is the agent for the task).

### `source/cydo/task.d`

Remove the standalone `isUserMessageLine` and `isAssistantMessageLine`
functions (~lines 100-111). Keep `isQueueOperation` (agent-agnostic).

**CI gate: `nix flake check`**

---

## Part C: Drop Zod validation from frontend (Plan Step 9, moved early)

**Goal:** Remove all Zod schemas and runtime validation. Replace with plain
TypeScript interfaces. Trust the backend. This is done early (before payload
normalization) to avoid updating Zod schemas that will be immediately deleted.

### Files to delete
- `web/src/validate.ts`
- `web/src/extractExtras.ts`

### Files to update

**`web/src/schemas.ts`:**
- Remove all `z.object(...)` / Zod schema definitions
- Replace with plain TypeScript interfaces
- Remove `zod` import
- Keep all exported type names (`AgnosticEvent`, etc.)
- Add `[key: string]: unknown` index signature to replace `.passthrough()`

**`web/src/sessionReducer.ts`:**
- Remove `validateWith` import and calls
- Remove `extras` parameter from all sub-reducers
- Cast incoming events directly: `const msg = rawMsg as SessionInit`
- Remove `extraFields: extras` from DisplayMessage construction in all reducers

**`web/src/types.ts`:**
- Remove `extraFields?: ExtraField[]` from `DisplayMessage`
- Remove `rawSource?: unknown` from `DisplayMessage`

**`web/src/components/ExtraFields.tsx`** — Delete if standalone file.

**`web/src/components/MessageList.tsx`** — Remove all `<ExtraFields>` renders.

**`web/src/components/AssistantMessage.tsx`** — Remove `<ExtraFields>` render.

**`web/src/components/UserMessage.tsx`** — Remove `<ExtraFields>` render.

**`web/package.json`** — Remove `zod` from dependencies.

**`tests/e2e/fixtures.ts`** — Remove `.extra-fields` assertion if present.

**CI gate: `nix flake check`**

---

## Part D: Define agnostic D structs in protocol.d (Plan Step 3)

**Goal:** Establish source-of-truth protocol type definitions. No behavior
change — these structs are defined alongside the existing translation code.

### `source/cydo/agent/protocol.d`

Add the struct definitions from the plan (see `/home/vladimir/work/cydo/.cydo/tasks/720/plan.md`
Step 3 for the complete struct listing). Key structs:

- `ContentBlock` — with unified `text` field for both text and thinking blocks
- `UsageInfo` — `input_tokens`, `output_tokens` only
- `SessionInitEvent`, `SessionStatusEvent`, `SessionCompactedEvent`
- `AssistantMessageEvent` — flat (no `message` wrapper)
- `UserMessageEvent` — flat (no `message` wrapper)
- `TurnResultEvent`
- `SessionSummaryEvent`, `SessionRateLimitEvent`
- `TaskStartedEvent`, `TaskNotificationEvent`
- `StreamBlockStartEvent`, `StreamBlockDeltaEvent`, `StreamBlockStopEvent`, `StreamTurnStopEvent`
- `ControlResponseEvent`
- `ProcessStderrEvent`, `ProcessExitEvent`

All structs use `@JSONOptional` for optional fields. No `@JSONExtras` needed
at this stage (extras handling comes later if needed).

**CI gate: `nix flake check`** (struct definitions only, no behavior change)
