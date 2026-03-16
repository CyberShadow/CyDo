# Sub-task 4: JSONL History Unification + Cleanup (Plan Steps 8 + 10)

## Overview

Unify JSONL history event format with live events, then clean up dead code
and consolidate the codebase. Each step has a CI gate.

## Prior research

- `/home/vladimir/work/cydo/.cydo/tasks/721/output.md` — Backend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/722/output.md` — Frontend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/724/output.md` — Detailed current state
- `/home/vladimir/work/cydo/.cydo/tasks/726/output.md` — Full plan with field mappings

## Master plan

The complete plan is at `/home/vladimir/work/cydo/.cydo/tasks/720/plan.md`.
This sub-task covers Steps 8 and 10.

## Dependencies

Depends on sub-task 3 (user/result/streaming normalization) being complete.
All event types must be normalized before unifying history with live events.

---

## Part A: Normalize JSONL history (Plan Step 8)

**Goal:** History events from JSONL go through the same normalization,
producing identical agnostic format as live events.

### Backend

Verify `source/cydo/agent/claude.d` `translateHistoryLine` produces correct
output (it delegates to `translateClaudeEvent` which now normalizes).

Verify `source/cydo/agent/codex.d` `translateHistoryLine` matches.

### Frontend

Unify live and file event types in `web/src/schemas.ts`:
- Remove `AssistantFileMessage` (now identical to `AssistantMessage`)
- Remove `UserFileMessage`
- Remove `FileEnvelopeFields`
- Remove JSONL-only no-op schemas: `ProgressSchema`, `QueueOperationSchema`, `FileHistorySnapshotSchema`
- Simplify `AgnosticFileEvent` type

Simplify `web/src/sessionReducer.ts` `reduceFileMessage`:
- JSONL events now have same shape as live events
- Remove duplicate parsing paths
- Keep JSONL-only type handlers: `system` subtype dispatch (`stop_hook_summary`, `api_error`, `turn_duration`), `progress`/`queue-operation`/`file-history-snapshot` (all no-ops)

**CI gate: `nix flake check`**

---

## Part B: Cleanup and consolidation (Plan Step 10)

**Goal:** Remove dead code, consolidate names.

### Backend

**`source/cydo/agent/protocol.d`:**
- Remove old string-level helpers if fully replaced: `renameType`, `findTopLevelType`, `replaceTypeRemoveSubtype`, `findMatchingBrace`
- Keep `translateClaudeEvent` as the public entry point

**`source/cydo/task.d`:**
- Replace `ExitMessage` / `StderrMessage` with `ProcessExitEvent` / `ProcessStderrEvent` from protocol.d (or just ensure they match)

### Frontend

Rename `web/src/schemas.ts` → `web/src/protocol.ts` (if not done earlier).
Remove `ClaudeMessage` type alias. Sweep for stale field name references.

Verify `AssistantMessage.tsx` synthetic detection (`message.model === "<synthetic>"`) still works.

### General sweep

Search for any remaining references to old field names:
- `claude_code_version`, `permissionMode`, `apiKeySource`
- `toolUseResult`, `isSidechain`, `isSteering`, `isMeta`, `isSynthetic`
- `isReplay`, `isApiErrorMessage`
- `block.thinking` (should be `block.text`)
- `delta.thinking` (should be `delta.text`)

**CI gate: `nix flake check`**
