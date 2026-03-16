# Sub-task 2: Normalize Session and Assistant Events (Plan Steps 4-5)

## Overview

Use the agnostic D structs (defined in sub-task 1) to fully normalize session
events and assistant messages. Both backend and frontend are updated together
for each event type. Each step has a CI gate.

## Prior research

- `/home/vladimir/work/cydo/.cydo/tasks/721/output.md` — Backend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/722/output.md` — Frontend protocol audit
- `/home/vladimir/work/cydo/.cydo/tasks/724/output.md` — Detailed current state
- `/home/vladimir/work/cydo/.cydo/tasks/726/output.md` — Full plan with field mappings

## Master plan

The complete plan is at `/home/vladimir/work/cydo/.cydo/tasks/720/plan.md`.
This sub-task covers Steps 4 and 5.

## Dependencies

Depends on sub-task 1 (foundation) being complete. The agnostic structs must
exist in `protocol.d`, Zod must be removed, and live events must route through
the Agent interface.

---

## Part A: Normalize session events (Plan Step 4)

**Goal:** `session/init`, `session/status`, `session/compacted`,
`session/summary`, `session/rate_limit` produce fully normalized JSON
via the agnostic structs.

### Backend

In `source/cydo/agent/protocol.d`, update `translateClaudeEvent` cases for
`"system"` subtypes (`init`, `status`, `compact_boundary`) and for `"summary"`
and `"rate_limit_event"`:

- Parse raw Claude JSON into a Claude-specific intermediate `@JSONPartial`
  struct (to extract known fields from Claude's format).
- Map to the agnostic struct (rename fields, drop unused).
- Serialize via `toJson()`.

For `session/init`:
- Parse `{type:"system", subtype:"init", session_id, uuid, model, cwd, tools, claude_code_version, permissionMode, apiKeySource, ...}`
- Map: `claude_code_version` → `agent_version`, `permissionMode` → `permission_mode`, `apiKeySource` → `api_key_source`
- Drop: `uuid`, `subtype`, `slash_commands`, `output_style`

In `source/cydo/agent/codex.d`, update session init construction
(`onThreadStarted`, `translateRolloutSessionMeta`) to use
`toJson(SessionInitEvent(...))` with the agnostic struct. Same renames.

### Frontend

Update `web/src/schemas.ts` — change `SystemInit` interface fields:
- `claude_code_version` → `agent_version`
- `permissionMode` → `permission_mode`
- `apiKeySource` → `api_key_source`

Update `web/src/sessionReducer.ts` `reduceSystemInit`:
- `msg.claude_code_version` → `msg.agent_version`
- `msg.permissionMode` → `msg.permission_mode`
- `msg.apiKeySource` → `msg.api_key_source`

Update `web/src/types.ts` `SessionInfo` field names to match.

Update `web/src/components/SystemBanner.tsx` and `MessageList.tsx` if they
reference old field names.

### Field mapping (session/init)

| Claude field | Agnostic field | Action |
|---|---|---|
| `claude_code_version` | `agent_version` | rename |
| `permissionMode` | `permission_mode` | rename |
| `apiKeySource` | `api_key_source` | rename |
| `uuid` | — | drop |
| `slash_commands` | — | drop |
| `output_style` | — | drop |

**CI gate: `nix flake check`**

---

## Part B: Normalize assistant messages (Plan Step 5)

**Goal:** `message/assistant` events are flat `AssistantMessageEvent` with
normalized content blocks.

### Backend

In `source/cydo/agent/protocol.d`, replace the `"assistant"` case with a
normalizer that:
- Parses Claude's `{type:"assistant", uuid, session_id, parent_tool_use_id, isSidechain, isApiErrorMessage, message:{id, role, content, model, stop_reason, usage, ...}}`
- Flattens: promotes `message.id`, `message.content`, `message.model`, `message.stop_reason`, `message.usage` to top level
- For thinking content blocks: renames `thinking` field → `text`, drops `signature`
- Normalizes usage: keeps only `input_tokens`, `output_tokens`
- Renames: `isSidechain` → `is_sidechain`, `isApiErrorMessage` → `is_api_error`
- Drops: `uuid`, `session_id`, `role`, `stop_sequence`, `context_management`, `container`

Update `source/cydo/agent/codex.d` assistant message construction to produce
the flat agnostic format.

### Frontend

Update `web/src/schemas.ts` `AssistantMessage` interface to flat format:
- Remove `message` wrapper, fields at top level
- `ThinkingContentBlock`: `{type: "thinking", text: string}` (was `{thinking: string, signature: string}`)

Update `web/src/sessionReducer.ts` `reduceAssistantMessage`:
- `msg.message.id` → `msg.id`
- `msg.message.content` → `msg.content`
- `msg.message.model` → `msg.model`
- `msg.message.usage` → `msg.usage`
- `msg.isSidechain` → `msg.is_sidechain`
- `msg.isApiErrorMessage` → `msg.is_api_error`

Update `web/src/useSessionManager.ts` notification text extraction:
- `raw.message.content` → `raw.content`

Update `web/src/components/AssistantMessage.tsx` thinking block rendering:
- `block.thinking` → `block.text`

Update `web/src/sessionReducer.ts` `reduceResultMessage` thinking block mapping:
- `{ type: "thinking", thinking: b.text, signature: "" }` → `{ type: "thinking", text: b.text }`

### Field mapping (message/assistant)

| Claude field | Agnostic field | Action |
|---|---|---|
| `message.id` | `id` | promote |
| `message.content` | `content` | promote |
| `message.model` | `model` | promote |
| `message.stop_reason` | `stop_reason` | promote |
| `message.usage` | `usage` | promote (input_tokens + output_tokens only) |
| `isSidechain` | `is_sidechain` | rename |
| `isApiErrorMessage` | `is_api_error` | rename |
| thinking `thinking` field | `text` | rename |
| thinking `signature` field | — | drop |
| `uuid`, `session_id` | — | drop |
| `role`, `stop_sequence` | — | drop |
| `context_management`, `container` | — | drop |

**CI gate: `nix flake check`**
