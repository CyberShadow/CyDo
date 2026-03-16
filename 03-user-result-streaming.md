# Sub-task 3: Normalize User Messages, Turn Results, and Streaming (Plan Steps 6-7)

## Overview

Continue normalizing event payloads: user messages, turn results, streaming
events, and task lifecycle events. Both backend and frontend updated together.
Each step has a CI gate.

## Prior research

- `/home/vladimir/work/cydo/.cydo/tasks/721/output.md` — Backend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/722/output.md` — Frontend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/724/output.md` — Detailed current state
- `/home/vladimir/work/cydo/.cydo/tasks/726/output.md` — Full plan with field mappings

## Master plan

The complete plan is at `/home/vladimir/work/cydo/.cydo/tasks/720/plan.md`.
This sub-task covers Steps 6 and 7.

## Dependencies

Depends on sub-task 2 (session + assistant normalization) being complete.

---

## Part A: Normalize user messages and turn results (Plan Step 6)

**Goal:** `message/user` and `turn/result` are fully agnostic.

### Backend

In `source/cydo/agent/protocol.d`, add normalizers:

**`normalizeUserMessage`:**
- Flatten: `message.content` → `content`
- Rename camelCase flags: `isSidechain` → `is_sidechain`, `isReplay` → `is_replay`, `isSynthetic` → `is_synthetic`, `isMeta` → `is_meta`, `isSteering` → `is_steering`
- Unify: `toolUseResult` / `tool_use_result` → `tool_result`
- Drop: `session_id`, `slug`, `sourceToolAssistantUUID`, `role`
- Keep: `uuid` (fork support)

**`normalizeTurnResult`:**
- Keep: `subtype`, `is_error`, `result`, `num_turns`, `duration_ms`, `duration_api_ms`, `total_cost_usd`, `stop_reason`, `errors`
- Normalize usage: keep `input_tokens`, `output_tokens` only
- Keep `model_usage` and `permission_denials` as opaque JSON
- Drop: `uuid`, `session_id`

Update `source/cydo/agent/codex.d` user message and turn result construction.

Update `source/cydo/task.d` `buildSyntheticUserEvent`:
- Flatten (no `message` wrapper)
- `isSteering` → `is_steering`

Update `source/cydo/app.d` `broadcastUnconfirmedUserMessage`:
- Construct flat user event matching agnostic format

### Frontend

Update `web/src/schemas.ts` interfaces for `UserMessage` and `TurnResult`.

Update `web/src/sessionReducer.ts`:
- `reduceUserEcho`: `msg.message.content` → `msg.content`, flag renames
- `reduceUserReplay`: same flattening
- `reduceResultMessage`: `msg.modelUsage` → `msg.model_usage`
- Tool result: `raw?.toolUseResult ?? raw?.tool_use_result` → `raw?.tool_result`

Update `web/src/types.ts` `ToolResult.toolUseResult` → `ToolResult.toolResult`.

Update `web/src/components/ToolCall.tsx` `result?.toolUseResult` → `result?.toolResult`.

**Note:** `DisplayMessage` internal type keeps camelCase (`isSidechain`, etc.).
The reducer maps from wire snake_case to internal camelCase.

### Field mapping (message/user)

| Claude field | Agnostic field | Action |
|---|---|---|
| `message.content` | `content` | promote |
| `isSidechain` | `is_sidechain` | rename |
| `isReplay` | `is_replay` | rename |
| `isSynthetic` | `is_synthetic` | rename |
| `isMeta` | `is_meta` | rename |
| `isSteering` | `is_steering` | rename |
| `toolUseResult`/`tool_use_result` | `tool_result` | unify + rename |
| `uuid` | `uuid` | keep (fork support) |
| `session_id`, `slug`, `sourceToolAssistantUUID` | — | drop |

### Field mapping (turn/result)

| Claude field | Agnostic field | Action |
|---|---|---|
| `modelUsage` | `model_usage` | rename |
| `usage.cache_*`, `usage.service_tier`, etc. | — | drop |
| `uuid`, `session_id` | — | drop |

**CI gate: `nix flake check`**

---

## Part B: Normalize streaming and task lifecycle events (Plan Step 7)

**Goal:** `stream/*`, `task/*`, `control/response` use agnostic structs.

### Backend

In `source/cydo/agent/protocol.d`, update `translateStreamEvent`:
- Parse inner event and serialize as agnostic struct instead of just renaming type
- For `stream/block_delta` thinking delta: `thinking` field → `text`
- Drop `signature_delta` events entirely
- For `task/started` and `task/notification`: parse and serialize as agnostic structs, dropping `uuid` and `session_id`
- For `control/response`: pass through `response` as opaque JSON

Update `source/cydo/agent/codex.d` synthetic stream events:
- `thinking_delta` uses `"text"` as the delta field key

### Frontend

Update `web/src/schemas.ts`:
- `ThinkingDelta`: `{type: "thinking_delta", text: string}` (was `{thinking: string}`)
- Remove `SignatureDelta` interface

Update `web/src/sessionReducer.ts` `reduceStreamBlockDelta`:
- `thinking_delta` handler: `delta.text` instead of `delta.thinking`

### Field mapping (stream/block_delta)

| Claude field | Agnostic field | Action |
|---|---|---|
| `delta.thinking` | `delta.text` | rename |
| `signature_delta` | — | drop entirely |

**CI gate: `nix flake check`**
