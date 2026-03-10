# Implementation Plan: OpenAI Codex CLI Support

## Overview

Add OpenAI Codex CLI as a second agent backend alongside Claude Code CLI.
This requires: (1) a series of atomic refactoring commits to make the codebase
agent-agnostic, (2) an agent-agnostic event protocol with backend translation,
and (3) a Codex CLI integration via the `codex app-server` JSON-RPC 2.0 protocol.

The plan is organized into two phases:
- **Phase A**: Refactoring (atomic commits, no Codex code)
- **Phase B**: Codex implementation

---

## Phase A: Refactoring

Each step is an atomic commit. Steps within a stage are independent and can
land in any order. Steps in later stages depend on earlier stages completing.

**Migration numbering:** Multiple steps add DB migrations. The current schema
has migrations 0–6. Each step's migration takes the next available number
(7, 8, ...) in whichever order the commits land. The specific numbers shown
below assume the listed order.

### Stage 1: Pure renames (no behavioral changes)

#### A1. Rename `claude_session_id` → `agent_session_id` (DB + code)

Single atomic commit covering both the DB column and all D code references.

**Files:**
- `persist.d`: Add migration 7: `ALTER TABLE tasks RENAME COLUMN claude_session_id TO agent_session_id`. Update `setClaudeSessionId` → `setAgentSessionId`, `TaskRow.claudeSessionId` → `agentSessionId`, `ForkResult.claudeSessionId` → `agentSessionId`, all SQL strings.
- `app.d`: Rename `TaskData.claudeSessionId` → `agentSessionId` (~15 usages). Update error messages: "Task has no Claude session ID" → "Task has no agent session ID". Rename `tryExtractClaudeSessionId` → `tryExtractAgentSessionId`.

**Risk:** Safe rename + DB migration.

#### A2. Add `agent_type` column to tasks table

**Files:**
- `persist.d`: Add migration 8: `ALTER TABLE tasks ADD COLUMN agent_type TEXT NOT NULL DEFAULT 'claude'`. Add field to `TaskRow` struct. Add `setAgentType()` method.
- `app.d`: Set `agent_type` on task creation. Propagate in `tasks_list` control messages.

**Frontend:** Add `agent_type` field to `TasksListEntry` in `schemas.ts` / `types.ts`. Display in sidebar if desired (optional, can be deferred).

**Risk:** Safe DB migration.

### Stage 2: Interface extractions (no behavioral changes)

These are all independent of each other.

#### A3. Make `rewindFiles` optional on AgentSession

`session.rewindFiles()` is confirmed dead code — `app.d` never calls it
(the undo flow uses `spawnRewindFiles()` directly). Remove it from the
`AgentSession` interface entirely, keep the implementation in `claude.d`
as a standalone function if needed later.

**Files:** `session.d` (remove method), `claude.d` (remove implementation or make standalone).

**Risk:** Safe — dead code removal.

#### A4. Move `tryExtractAgentSessionId` to Agent interface

The function parses Claude's `system.init` to discover the session ID.
Different agents signal their session ID differently. Add
`Agent.parseSessionId(string line) → string` method.

**Files:**
- `agent.d`: Add `string parseSessionId(string line)` to `Agent` interface.
- `claude.d`: Implement — move the parsing logic from `app.d`.
- `app.d`: Replace inline parsing with `agent.parseSessionId(line)`.

**Risk:** Low — structural move.

#### A5. Move `extractResultText` and `extractAssistantText` to Agent

Both parse Claude-specific JSON. Add to `Agent` interface.

**Files:**
- `agent.d`: Add `string extractResultText(string line)` and `string extractAssistantText(string line)`.
- `claude.d`: Implement — move the `@JSONPartial` probe structs and logic from `app.d`.
- `app.d`: Replace inline parsing with `agent.extractResultText(line)` / `agent.extractAssistantText(line)`.

**Risk:** Low — structural move.

#### A6. Move model alias mapping to Agent

`tasktype.d:modelClassToAlias()` hardcodes "haiku"/"sonnet"/"opus". Move to Agent interface.

**Files:**
- `agent.d`: Add `string modelAlias(string modelClass)` to `Agent` interface.
- `claude.d`: Implement with current mapping.
- `tasktype.d`: Replace `modelClassToAlias()` with calls through the agent.
- `app.d`: Thread agent reference to call sites that need model aliases.

**Risk:** Low — routing change.

### Stage 3: JSONL path and MCP abstraction

#### A7. Move JSONL path computation to Agent

`claudeJsonlPath()` hardcodes `~/.claude/projects/<mangled>/<uuid>.jsonl`.
Make it a method on `Agent` so each backend can specify its own path.

The free function in `persist.d` becomes a `ClaudeCodeAgent` method.
The `persist.d` functions that use it (`loadTaskHistory`, `forkTask`,
`truncateJsonl`, etc.) now take a path parameter instead of computing it.

**Files:**
- `agent.d`: Add `string historyPath(string sessionId, string projectPath)` and `string translateHistoryLine(string line)` (returns agnostic event JSON; Claude returns the line unchanged since its JSONL is already in raw Claude format that will be translated by `translateClaudeEvent`; Codex translates from `{timestamp, type, payload}` to agnostic events).
- `claude.d`: Implement `historyPath` with current mangling logic, `translateHistoryLine` returns input unchanged.
- `persist.d`: Change `loadTaskHistory`, `forkTask`, `truncateJsonl`, `countMessagesAfterUuid`, `lastUuidInJsonl`, `extractForkableUuids` to accept a `string jsonlPath` parameter instead of `(sessionId, projectPath)`.
- `app.d`: Compute path via `agent.historyPath(...)` and pass to persist functions.

**Risk:** Medium — many call site updates, but mechanically straightforward.

#### A8. Move MCP config tracking to Agent interface

`app.d:892` does `cast(ClaudeCodeAgent)` to access `lastMcpConfigPath`.
Move temp file cleanup to the Agent interface so the cast is unnecessary.

**Files:**
- `agent.d`: Add `string lastMcpConfigPath()` property, or better: move cleanup into `Agent.cleanup()` method called on session exit.
- `claude.d`: Implement cleanup.
- `app.d`: Remove `cast(ClaudeCodeAgent)` at line 892. Call `agent.cleanup()` on session exit.

**Risk:** Low.

### Stage 4: Fork/undo and factory

#### A9. Move fork/undo JSONL operations to Agent

`forkTask` and `truncateJsonl` manipulate JSONL with Claude-specific
assumptions (session ID field rewriting with `"sessionId":"..."` and
`"session_id":"..."`). Make these agent-aware.

**Files:**
- `agent.d`: Add methods:
  - `string rewriteSessionId(string line, string oldId, string newId)` — per-agent JSONL session ID rewriting
  - `@property bool supportsFileRevert()` — whether file revert is supported (Claude: true, Codex: false)
  - `void rewindFiles(string sessionId, string afterUuid, string cwd)` — replaces `spawnRewindFiles` (only called when `supportsFileRevert`)
- `claude.d`: Implement all three.
- `persist.d`: `forkTask()` takes an Agent parameter for `rewriteSessionId`. Or simpler: pass a rewrite delegate.
- `app.d`: Update fork/undo code paths.

**Risk:** Medium — largest diff, but JSONL manipulation logic is self-contained.

#### A10. Extract agent factory

Replace `new ClaudeCodeAgent()` with config-driven factory.

**Files:**
- `agent.d` or new `factory.d`: `Agent createAgent(string agentType)` function. Returns `ClaudeCodeAgent` for "claude", will return `CodexAgent` for "codex" in Phase B.
- `app.d`: Replace `agent = new ClaudeCodeAgent()` (line 105) with `agent = createAgent(config.defaultAgentType)`. For per-task agent types, use `tasks[tid].agentType`.
- `config.d`: Add `defaultAgentType` setting (defaults to "claude").

**Depends on:** A2 (agent_type column), A8 (no cast to concrete type).

**Risk:** Medium — changes initialization flow.

#### A11. Move `generateTitle` to Agent

`generateTitle` (app.d:1448) directly spawns `claude -p "Generate a title..."
--model haiku`. Different agents need different title generation.

**Files:**
- `agent.d`: Add `void generateTitle(string message, void delegate(string) callback)`.
- `claude.d`: Implement — move the subprocess spawning.
- `app.d`: Replace direct subprocess call with agent method.

**Risk:** Low — structural move.

### Stage 5: Agent-agnostic protocol

#### A12. Implement backend translation layer for Claude events

Add `source/cydo/agent/protocol.d` containing the `translateClaudeEvent`
function. This parses Claude's stream-json events and emits the agent-agnostic
protocol.

**Architecture:**

```d
// protocol.d
import ae.utils.aa : OrderedMap;
import ae.utils.json : JSONFragment, jsonParse, toJson, JSONPartial;

string translateClaudeEvent(string rawLine)
{
    // Fast path: probe type field cheaply
    @JSONPartial
    static struct TypeProbe { string type; string subtype; }

    TypeProbe probe;
    try
        probe = jsonParse!TypeProbe(rawLine);
    catch (Exception)
        return rawLine; // unparseable → pass through

    switch (probe.type)
    {
        case "system":
            return translateSystemEvent(rawLine, probe.subtype);
        case "assistant":
            return renameType(rawLine, "message/assistant");
        case "user":
            return renameType(rawLine, "message/user");
        case "stream_event":
            return translateStreamEvent(rawLine);
        case "result":
            return renameType(rawLine, "turn/result");
        case "summary":
            return renameType(rawLine, "session/summary");
        case "rate_limit_event":
            return renameType(rawLine, "session/rate_limit");
        case "control_response":
            return renameType(rawLine, "control/response");
        case "stderr":
            return renameType(rawLine, "process/stderr");
        case "exit":
            return renameType(rawLine, "process/exit");
        default:
            return rawLine; // unknown → pass through
    }
}
```

**Translation rules:**

| Claude event | Agnostic event | Transformation |
|---|---|---|
| `system { subtype: "init" }` | `session/init` | Rename type, remove subtype, add `agent: "claude"` |
| `system { subtype: "status" }` | `session/status` | Rename type, remove subtype |
| `system { subtype: "compact_boundary" }` | `session/compacted` | Rename type, remove subtype |
| `system { subtype: "task_started" }` | `task/started` | Rename type, remove subtype |
| `system { subtype: "task_notification" }` | `task/notification` | Rename type, remove subtype |
| `system { subtype: "api_error" }` | Pass through (JSONL-only, frontend ignores) |
| `system { subtype: "turn_duration" }` | Pass through |
| `system { subtype: "stop_hook_summary" }` | Pass through |
| `assistant` | `message/assistant` | Rename type only; all fields preserved |
| `user` | `message/user` | Rename type only |
| `stream_event` | `stream/block_start`, `stream/block_delta`, `stream/block_stop`, `stream/turn_stop` | Unwrap inner `event`, map `content_block_start/delta/stop` → `stream/block_*`, `message_stop` → `stream/turn_stop` |
| `result` | `turn/result` | Rename type only |
| `summary` | `session/summary` | Rename type only |
| `rate_limit_event` | `session/rate_limit` | Rename type only |
| `control_response` | `control/response` | Rename type only |
| `stderr` | `process/stderr` | Rename type only |
| `exit` | `process/exit` | Rename type only |
| JSONL-only types | Pass through unchanged |

**Implementation approach:**

For simple renames (most events), use `OrderedMap!(string, JSONFragment)`:
parse all fields, replace the `"type"` value, re-serialize. All unknown
fields are preserved automatically.

For `stream_event`, deeper transformation is needed: unwrap the inner
`event` object, read its `type` field, and emit the appropriate
`stream/*` event with the inner event's fields promoted to top level.

For `system { subtype: ... }`, read `subtype`, compose the new type
string, remove `subtype` from the map, and re-serialize.

**Integration point:** `app.d:broadcastTask()` calls `translateClaudeEvent(rawLine)`
before embedding in the envelope. Also called during JSONL history replay
in `loadTaskHistory` (or at broadcast time when sending `fileEvent` to clients).

**Null handling:** `translateClaudeEvent` returns `null` for events that
are consumed and not forwarded (e.g., `message_start`, `message_delta`).
`broadcastTask` must check for null and skip both history storage and
WebSocket broadcast when the translation returns null.

**Files:**
- New: `source/cydo/agent/protocol.d`
- Modified: `app.d` — call `translateClaudeEvent` in `broadcastTask` and `processNewJsonlContent`

#### A13. Update frontend schemas for agent-agnostic protocol

Update `schemas.ts` to define the new event types. The new union replaces
`ClaudeMessage`:

```typescript
// New discriminated union (replaces ClaudeMessage)
export type AgnosticEvent =
  | z.infer<typeof SessionInitSchema>       // session/init
  | z.infer<typeof SessionStatusSchema>     // session/status
  | z.infer<typeof SessionCompactedSchema>  // session/compacted
  | z.infer<typeof SessionSummarySchema>    // session/summary
  | z.infer<typeof SessionRateLimitSchema>  // session/rate_limit
  | z.infer<typeof TurnResultSchema>        // turn/result
  | z.infer<typeof MessageAssistantSchema>  // message/assistant
  | z.infer<typeof MessageUserSchema>       // message/user
  | z.infer<typeof StreamBlockStartSchema>  // stream/block_start
  | z.infer<typeof StreamBlockDeltaSchema>  // stream/block_delta
  | z.infer<typeof StreamBlockStopSchema>   // stream/block_stop
  | z.infer<typeof StreamTurnStopSchema>    // stream/turn_stop
  | z.infer<typeof TaskStartedSchema>       // task/started
  | z.infer<typeof TaskNotificationSchema>  // task/notification
  | z.infer<typeof ControlResponseSchema>   // control/response
  | z.infer<typeof ProcessStderrSchema>     // process/stderr
  | z.infer<typeof ProcessExitSchema>;      // process/exit
```

All schemas use `.passthrough()` to preserve agent-specific extra fields.

**Content block schemas** (text, tool_use, thinking) are **unchanged** — they
are already effectively agent-agnostic. The assistant message `content` array
keeps the same discriminated block structure.

**Key schema changes:**
- `stream_event` (embedding full Anthropic SSE) → `stream/block_*` (flattened)
- `system { subtype }` → `session/*`, `task/*` (slash-namespaced)
- `assistant` → `message/assistant` (just renamed)
- Inner fields all preserved via `.passthrough()`

**Files:** `web/src/schemas.ts`

#### A14. Update frontend reducers for agent-agnostic protocol

Update `sessionReducer.ts` to dispatch on the new type strings.

**Key changes:**
- `reduceStdoutMessage` switch: `case "system":` → `case "session/init":`, `case "session/status":`, etc.
- `reduceStreamEvent` is absorbed: its inner switch on `event.type` (`content_block_start/delta/stop`) is replaced by top-level `case "stream/block_start":`, `case "stream/block_delta":`, `case "stream/block_stop":`, `case "stream/turn_stop":`.
- Individual reducer functions (`reduceSystemInit`, `reduceAssistantMessage`, etc.) are adapted to receive the new shapes but internal logic stays the same.
- `reduceFileMessage` for JSONL history: same changes (JSONL events also go through translation).

**Files:** `web/src/sessionReducer.ts`, `web/src/validate.ts` (schema dispatch map)

#### A15. Update `useSessionManager.ts` types

Change `TaskMessage.event` from `ClaudeMessage` to `AgnosticEvent`.

**Files:** `web/src/useSessionManager.ts`

---

## Phase B: Codex Implementation

### B1. Implement `CodexAgent` and `CodexSession`

New file: `source/cydo/agent/codex.d`

**Architecture:**

Unlike Claude Code CLI (one process per session), Codex uses a **single
`codex app-server` process** serving multiple threads via JSON-RPC 2.0.

**Sandbox constraint:** CyDo builds per-task bwrap from per-workspace
sandbox configs. The bwrap prefix is passed to `createSession`, which
for Claude prepends it to the spawned process. For Codex, the app-server
is long-lived and shared — it can't be re-bwrapped per task.

**Solution: one app-server per workspace**, each spawned inside that
workspace's bwrap on first use. Tasks in the same workspace share
one app-server. Tasks in different workspaces get separate processes.
Per-task `cwd` differences are handled via `turn/start.cwd`, not bwrap
`--chdir`. The per-task `taskDir` is within the project dir (already rw
in the workspace bwrap). Read-only task types use the same app-server
but set `sandbox: "read-only"` in `turn/start.sandboxPolicy` as an
additional defense-in-depth signal to the model.

`CodexAgent` is a singleton that manages a pool of `AppServerProcess`
instances keyed by workspace name. Each `AppServerProcess` wraps the
stdio connection, JSON-RPC client, and session routing for one
bwrap'd `codex app-server` process.

```
CodexAgent (singleton)
├── AppServerProcess (workspace-a, inside bwrap-a)
│   ├── JSON-RPC client (stdio)
│   ├── CodexSession (thread_001) ← tid 5
│   └── CodexSession (thread_003) ← tid 12
└── AppServerProcess (workspace-b, inside bwrap-b)
    ├── JSON-RPC client (stdio)
    └── CodexSession (thread_002) ← tid 8
```

Each `AppServerProcess` is started lazily on first Codex task creation
for that workspace. The bwrap args from the first task's
`resolveSandbox` are used to spawn the process. Subsequent tasks in
the same workspace reuse the running process — their bwrap args are
ignored (they should be equivalent since the workspace config is the
same; the only difference is `taskDir`, which is already inside the
project rw path).

`createSession` for Codex: look up or create the `AppServerProcess`
for this workspace (spawning inside `bwrapPrefix` if new), then send
`thread/start` with the task's `cwd` to that process.

**Interface change:** `SessionConfig` needs a `workspace` field so
CodexAgent knows which `AppServerProcess` to use. Add
`string workspace;` to `SessionConfig` (Phase A, as part of A10).
Claude ignores it; Codex uses it as the pool key.

**CodexAgent** (`Agent` interface):
- `configureSandbox(...)`: Add `~/.codex` as rw, set `OPENAI_API_KEY`.
- `createSession(tid, resumeId, bwrapPrefix, config)`: Look up `AppServerProcess` for this task's workspace. If none exists, spawn `codex app-server` inside `bwrapPrefix`, send `initialize` + `account/login/start`. Then send `thread/start` (or `thread/resume` if `resumeId` is set), create `CodexSession`, register threadId→tid mapping.
- `historyPath(...)`: Return `~/.codex/sessions/YYYY/MM/DD/rollout-*-<threadId>.jsonl`.
- `parseSessionId(...)`: Parse `session/init` for thread ID.
- `extractResultText(...)`, `extractAssistantText(...)`: Parse agnostic event format.
- `modelAlias(modelClass)`: Map "large"→"o3", "small"→"o4-mini", etc.
- `rewriteSessionId(...)`: Codex JSONL format session ID rewriting.
- `supportsFileRevert()`: Return `false`.

**CodexSession** (`AgentSession` interface):
- `sendMessage(content)`: Send `turn/start` with `[{ type: "text", text: content }]`. If a turn is already in progress, use `turn/steer` instead.
- `interrupt()`: Send `turn/interrupt`.
- `sigint()`: Send `turn/interrupt` (no separate signal concept).
- `stop()`: Close the thread. If last thread, terminate app-server process.
- `closeStdin()`: No-op (JSON-RPC has no stdin concept).
- `onOutput`: Emit translated agent-agnostic events.

**JSON-RPC 2.0 client:** Implement a simple NDJSON-over-stdio JSON-RPC client
using `AgentProcess` + `LineBufferedAdapter`. Track pending requests by `id`.
Route notifications by method name. Handle `ServerRequest` (approval gates)
with auto-approve responses.

**Translation (Codex → agnostic):**

The CodexSession's onOutput callback emits agent-agnostic events directly
(no second translation step). The mapping:

| Codex event | Agnostic event |
|---|---|
| `thread/started` | `session/init { agent: "codex", session_id: thread.id, ... }` |
| `item/started { type: agentMessage }` | `stream/block_start { index, block: { type: "text" } }` |
| `item/agentMessage/delta` | `stream/block_delta { index, delta: { type: "text_delta", text } }` |
| `item/started { type: reasoning }` | `stream/block_start { index, block: { type: "thinking" } }` |
| `item/reasoning/textDelta` | `stream/block_delta { index, delta: { type: "thinking_delta", thinking } }` |
| `item/started { type: commandExecution }` | `stream/block_start { index, block: { type: "tool_use", id, name: "Bash" } }` |
| `item/commandExecution/outputDelta` | `stream/block_delta { index, delta: { type: "tool_output_delta", text } }` |
| `item/started { type: fileChange }` | `stream/block_start { index, block: { type: "tool_use", id, name: "Write"/"Edit" } }` |
| `item/started { type: mcpToolCall }` | `stream/block_start { index, block: { type: "tool_use", id, name: tool } }` |
| `item/completed` | `stream/block_stop { index }` (+ synthesize `message/user` with tool_result for tool items) |
| `turn/completed` | `stream/turn_stop` + `message/assistant` (accumulated blocks) + `turn/result` |
| `thread/tokenUsage/updated` | Accumulated, emitted in `turn/result.usage` |
| `thread/compacted` | `session/compacted` |
| `error` | `process/stderr { text: error.message }` |
| approval requests | Auto-respond with `{ decision: "acceptForSession" }` |

**Block index tracking:** Maintain a per-turn counter. Each `item/started`
increments the index. This maps to the `stream/block_start.index` and
`stream/block_delta.index` fields.

**Turn completion synthesis:** On `turn/completed`, CodexSession builds a
`message/assistant` event by collecting all items from the turn:
- `agentMessage` items → `{ type: "text", text }` blocks
- `reasoning` items → `{ type: "thinking", thinking, signature: "" }` blocks
- `commandExecution` items → `{ type: "tool_use", id, name: "Bash", input: { command, description: "" } }` blocks
- `fileChange` items → `{ type: "tool_use", ... }` blocks
- `mcpToolCall` items → `{ type: "tool_use", ... }` blocks

Then emits synthetic `message/user` events with `tool_result` blocks for
each tool item's output.

### B2. Register Codex agent in factory

Update the factory from A10 to create `CodexAgent` for `agent_type == "codex"`.

**Files:** `agent.d` or `factory.d`

### B3. Codex session persistence

Implement Codex-specific methods on `CodexAgent`:

- `historyPath()`: Codex stores sessions at `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<threadId>.jsonl`. The threadId IS the UUID in the filename. However, the timestamp prefix means we can't construct the path from threadId alone — need to either (a) store the full rollout path from the `thread/started` response, or (b) glob for `*-<threadId>.jsonl`.

- `parseSessionId()`: Extract threadId from the first `session/init` event (translated from `thread/started`). Store in `agent_session_id` column.

- **History replay**: Two approaches:
  - **App-server API** (recommended): Use `thread/read { threadId, includeTurns: true }` to get `Thread.turns[].items[]`. Translate items to agnostic events. This is clean and doesn't require parsing JSONL.
  - **Direct JSONL**: Parse `response_item` and `event_msg` lines. More complex, but works without a running app-server.

- **Fork**: Use `thread/fork { threadId }` via app-server. Returns new thread with new UUID. No JSONL manipulation needed. **Limitation**: fork is whole-session only (no mid-message fork like Claude). CyDo's fork UI should show fork at turn boundaries only for Codex sessions.

- **Undo/rollback**: Use `thread/rollback { threadId, numTurns }` via app-server. Granularity is whole turns (not individual messages). **Does NOT revert filesystem changes** — CyDo must handle file revert separately (e.g., git checkout).

- **Initial scope**: Implement resume and history replay. Defer fork and undo to a later iteration — return "not supported for Codex" errors.

### B4. Codex-specific MCP tool delivery

Codex supports MCP servers configured in `~/.codex/config.toml`. For CyDo's
custom tools (Task, SwitchMode), two options:

**Option 1: MCP config** — write a `[mcp_servers.cydo]` section to
`~/.codex/config.toml` pointing to CyDo's MCP server binary. Codex starts
the MCP server automatically.

**Option 2: Dynamic tools** — use the `item/tool/call` server request
mechanism. Register CyDo tools via `skills/config/write`. When Codex needs
a CyDo tool, it sends `item/tool/call` as a ServerRequest; CyDo responds
with the tool result.

**Recommendation:** Start with Option 1 (MCP config) since CyDo already has
an MCP server (`source/cydo/mcp/server.d`). Codex's MCP support is mature
and this requires the least new code.

### B5. Codex `disallowedTools` equivalent

Claude Code uses `--disallowedTools` to restrict tool access. Codex has no
direct equivalent. The CyDo task type system's `disallowedTools()` in
`tasktype.d` returns Claude-specific tool names ("Task,EnterPlanMode,...").

For Codex, tool restriction happens differently:
- MCP tools can be selectively registered
- Built-in tools cannot be individually disabled
- Use `developerInstructions` in `thread/start` to instruct the agent to avoid certain tools

**Implementation:** `CodexAgent.createSession()` includes tool restriction
instructions in `developerInstructions` when the task type specifies
`disallowedTools`. This is a soft restriction (prompt-based) vs Claude's
hard restriction.

### B6. Frontend agent type indicator (optional)

Add a small visual indicator showing which agent backend a session uses.
Use the `agent` field from `session/init` events.

**Files:** `web/src/components/SessionView.tsx` or `SystemBanner.tsx`

---

## Protocol Reference

### Envelope

```json
{"tid": 42, "timestamp": "2026-03-10T12:00:00Z", "forkPoint": true, "event": <AgnosticEvent>}
```

The `forkPoint` boolean indicates whether this event is a valid fork/undo
point. The backend sets this based on agent type:

- **Claude**: `true` on every `message/assistant` and `message/user` event
  that carries a UUID (same granularity as existing undo points).
- **Codex**: `true` only on `turn/result` events (whole-turn boundaries),
  since Codex's `thread/fork` and `thread/rollback` operate at turn
  granularity.

The frontend uses `forkPoint` to control which messages show fork/undo
affordances. This replaces the current approach where the frontend
independently determines forkable points from UUIDs — the backend now makes
the decision since it knows the agent's capabilities.

### Event types

| Type | Description | Claude | Codex |
|------|-------------|--------|-------|
| `session/init` | Session metadata | ✓ | ✓ |
| `session/status` | Progress text | ✓ | ✓ |
| `session/compacted` | Context compaction | ✓ | ✓ |
| `session/summary` | Text summary | ✓ | — |
| `session/rate_limit` | Rate limiting | ✓ | — |
| `turn/result` | Turn completion | ✓ | ✓ |
| `message/assistant` | Full assistant message | ✓ | ✓ |
| `message/user` | User message / tool results | ✓ | ✓ |
| `stream/block_start` | Begin streaming block | ✓ | ✓ |
| `stream/block_delta` | Streaming content chunk | ✓ | ✓ |
| `stream/block_stop` | End streaming block | ✓ | ✓ |
| `stream/turn_stop` | All blocks done | ✓ | ✓ |
| `task/started` | Sub-task started | ✓ | — |
| `task/notification` | Sub-task update | ✓ | — |
| `control/response` | Control protocol response | ✓ | — |
| `tool/approval_request` | Tool approval gate | — | ✓ |
| `process/stderr` | Agent stderr | ✓ | ✓ |
| `process/exit` | Agent process exit | ✓ | ✓ |

### Content block types (in `message/assistant.content`)

| Block type | Fields | Source |
|---|---|---|
| `text` | `text` | Both |
| `tool_use` | `id`, `name`, `input` | Both |
| `thinking` | `thinking`, `signature` | Both |

### Streaming delta types (in `stream/block_delta.delta`)

| Delta type | Fields | Source |
|---|---|---|
| `text_delta` | `text` | Both |
| `thinking_delta` | `thinking` | Both |
| `input_json_delta` | `partial_json` | Claude only |
| `signature_delta` | `signature` | Claude only |
| `tool_output_delta` | `text` | Codex only |

### Codex tool → content block name mapping

| Codex item type | `tool_use.name` | Notes |
|---|---|---|
| `commandExecution` | `"Bash"` | Renders with BashInput |
| `fileChange` (create) | `"Write"` | Renders with WriteInput |
| `fileChange` (patch) | `"Edit"` | Renders with EditInput |
| `mcpToolCall` | actual tool name | Renders generically |
| `webSearch` | `"WebSearch"` | |

---

## Implementation Details

### D backend translation layer

Use `OrderedMap!(string, JSONFragment)` from `ae.utils.json` for
field-preserving JSON transformation:

```d
import ae.utils.aa : OrderedMap;
import ae.utils.json : JSONFragment, jsonParse, toJson;

string renameType(string rawLine, string newType)
{
    auto fields = rawLine.jsonParse!(OrderedMap!(string, JSONFragment));
    fields["type"] = JSONFragment(`"` ~ newType ~ `"`);
    return fields.toJson;
}
```

For `stream_event` translation (most complex case — unwrap inner `event`):

```d
string translateStreamEvent(string rawLine)
{
    auto fields = rawLine.jsonParse!(OrderedMap!(string, JSONFragment));
    auto innerEvent = fields["event"].json
        .jsonParse!(OrderedMap!(string, JSONFragment));

    string innerType = innerEvent["type"].json.jsonParse!string;

    // Build output: promote inner fields to top level
    OrderedMap!(string, JSONFragment) output;

    switch (innerType)
    {
        case "content_block_start":
            output["type"] = JSONFragment(`"stream/block_start"`);
            output["index"] = innerEvent["index"];
            output["block"] = innerEvent["content_block"];
            break;
        case "content_block_delta":
            output["type"] = JSONFragment(`"stream/block_delta"`);
            output["index"] = innerEvent["index"];
            output["delta"] = innerEvent["delta"];
            break;
        case "content_block_stop":
            output["type"] = JSONFragment(`"stream/block_stop"`);
            output["index"] = innerEvent["index"];
            break;
        case "message_stop":
            output["type"] = JSONFragment(`"stream/turn_stop"`);
            break;
        case "message_start", "message_delta":
            return null; // consumed, not forwarded
        default:
            return rawLine; // unknown → pass through
    }

    // Preserve envelope fields (uuid, session_id, parent_tool_use_id)
    foreach (key; ["uuid", "session_id", "parent_tool_use_id"])
        if (key in fields)
            output[key] = fields[key];

    return output.toJson;
}
```

**Performance:** Use `canFind` pre-filter to skip parsing for events that
need no transformation (e.g., JSONL-only types the frontend ignores).

### Codex JSON-RPC 2.0 client

Build on `AgentProcess` + `LineBufferedAdapter` (already proven for
Claude's stdio protocol). Add a thin JSON-RPC layer:

```d
class JsonRpcClient
{
    private AgentProcess process;
    private int nextId = 1;
    private Promise!JSONFragment[int] pending;

    void sendRequest(string method, string paramsJson,
        void delegate(JSONFragment result) onResult) { ... }

    void sendNotification(string method, string paramsJson) { ... }

    // Called by process.onStdoutLine
    private void handleLine(string line) {
        // Parse: is it a response (has "id" + "result"/"error")?
        // Or a notification (has "method" + "params")?
        // Or a server request (has "id" + "method")?
    }
}
```

### Codex app-server lifecycle

1. On CyDo startup (or first Codex task creation): spawn `codex app-server --listen stdio://`
2. Send `initialize { clientInfo: { name: "cydo", version: "<ver>" } }`
3. Send `account/login/start { type: "apiKey", apiKey: "<key>" }`
4. Wait for `account/login/completed { success: true }`
5. For each new Codex session: send `thread/start` with:
   - `cwd`: task working directory
   - `model`: from `CodexAgent.modelAlias(modelClass)`
   - `approvalPolicy: "never"`
   - `sandbox: "danger-full-access"` (or `externalSandbox` — see sandbox section)
   - `developerInstructions`: CyDo system prompt + tool restrictions
   Register threadId → tid mapping.
6. For each user message: send `turn/start` with:
   - `threadId`, `input: [{ type: "text", text: content }]`
   - `sandboxPolicy: { type: "externalSandbox", networkAccess: "enabled" }`
   If a turn is already in progress, use `turn/steer` instead.
7. Handle v2 notifications (ignore `codex/event/*` legacy duplicates):
   - `item/*` notifications: translate to agnostic events, emit via onOutput
   - `turn/completed`: synthesize `message/assistant` + `turn/result`
8. Handle ServerRequests (approval gates):
   - `item/commandExecution/requestApproval`: respond `{ decision: "acceptForSession" }`
   - `item/fileChange/requestApproval`: respond `{ decision: "acceptForSession" }`
   - `item/tool/call`: execute CyDo dynamic tool, respond with result
9. On session stop: no explicit cleanup (thread persists in app-server)
10. On CyDo shutdown: terminate app-server process

**Multi-thread routing:** All Codex notifications include `threadId`. The
`CodexAgent` maintains a `CodexSession[string]` map keyed by threadId.
When a notification arrives, look up the session and call its handler.

**Dual notification filtering:** Every event arrives twice (v1 `codex/event/*`
and v2 `turn/*`/`item/*`). Filter by method prefix — only process v2 methods.

### Auth flow

On `codex app-server` initialization, after `initialize` response:
1. Read API key from `CODEX_API_KEY` or `OPENAI_API_KEY` env var
2. Send `account/login/start { type: "apiKey", apiKey: "<key>" }`
3. Wait for `account/login/completed { success: true }`
4. If login fails: emit error event to all Codex sessions, disable Codex agent

For per-workspace isolation, set `CODEX_HOME` to a workspace-specific
directory before spawning the app-server process.

### Sandbox configuration (CRITICAL)

CyDo uses bwrap for filesystem sandboxing. Codex also uses bwrap internally.
Nested bwrap fails on kernels with restricted unprivileged user namespaces.

CyDo's sandbox is a layered merge: global config → per-workspace config →
agent's `configureSandbox()` additions. The bwrap whitelist (ro/rw paths)
enforces filesystem isolation. Network is always shared (`--share-net`
hardcoded). Read-only task types downgrade all paths to ro before the agent
layer runs, so agent-added paths (like `~/.codex`) stay rw even in
read-only mode.

**`CodexAgent.configureSandbox()`** adds:
- `~/.codex` as rw (Codex config/session data)
- Directory containing `codex` binary as ro

**For Codex sessions inside CyDo's bwrap (normal operation):**
- `thread/start`: `sandbox: "danger-full-access"` (disables Codex's own sandbox)
- `turn/start`: `sandboxPolicy: { type: "externalSandbox", networkAccess: "enabled" }`
  (CyDo's bwrap always shares network, so `"enabled"` is truthful)
- Both must be set explicitly (known bug: CLI bypass flag doesn't propagate)
- CyDo's bwrap path whitelist provides the actual filesystem isolation

**For Codex sessions without CyDo's bwrap** (e.g., development mode):
- `thread/start`: `sandbox: "workspace-write"` (Codex sandbox active)
- `turn/start`: `sandboxPolicy: { type: "workspaceWrite" }`

### Session resume on CyDo restart

Resume is **lazy** — the app-server is not started until the user actually
interacts with a Codex task (clicks it in the sidebar, sends a message, etc.).

When the user first interacts with a Codex task after restart:
1. If app-server not running: spawn, initialize, authenticate
2. Send `thread/resume { threadId }` for that task
3. Response includes full turn history in `thread.turns[]`
4. Translate history items to agnostic events for frontend replay
5. Thread is now live — ready for new `turn/start` calls

History display before resume: Codex JSONL uses `{timestamp, type,
payload}` format (not agnostic events). `loadTaskHistory` wraps each
line as a raw `fileEvent` — the frontend wouldn't understand Codex format
without translation. Two options:
- **Translate during replay** (preferred): `CodexAgent` provides a
  `translateHistoryLine(string line) → string` method that converts Codex
  JSONL lines to agnostic events. Called during `loadTaskHistory` before
  wrapping as `fileEvent`.
- **App-server only**: Skip offline JSONL replay entirely; require the
  app-server to be running for any history display. Simpler but degrades
  UX (no history until first interaction triggers lazy startup).

The app-server is only needed when the user wants to send a new message.

Note: threads must have had at least one turn to be resumable. Threads
created but never given a turn have no JSONL file and cannot be resumed.

---

## Commit sequence summary

```
A1.  Rename claude_session_id → agent_session_id
A2.  Add agent_type column to tasks table
A3.  Remove rewindFiles from AgentSession interface
A4.  Move session ID extraction to Agent interface
A5.  Move extractResultText/extractAssistantText to Agent
A6.  Move model alias mapping to Agent
A7.  Move JSONL path computation to Agent
A8.  Move MCP config tracking to Agent interface
A9.  Move fork/undo JSONL operations to Agent
A10. Extract agent factory
A11. Move generateTitle to Agent
A12. Implement Claude event translation layer (protocol.d)
A13. Update frontend schemas for agnostic protocol
A14. Update frontend reducers for agnostic protocol
A15. Update useSessionManager types
---
B1.  Implement CodexAgent and CodexSession
B2.  Register Codex in agent factory
B3.  Codex session persistence
B4.  Codex MCP tool delivery
B5.  Codex disallowedTools equivalent
B6.  Frontend agent type indicator (optional)
```

## Resolved Questions

### Codex JSONL format

Codex JSONL lines use `{timestamp, type, payload}` envelope. Types:
`session_meta` (header), `response_item` (messages/tools), `event_msg`
(lifecycle), `turn_context` (per-turn config). **No per-line UUID** — unlike
Claude. Fork/undo use app-server APIs (`thread/fork`, `thread/rollback`)
rather than direct JSONL manipulation. Rollback granularity is whole turns.

### Codex auth

API keys via `CODEX_API_KEY` (priority) or `OPENAI_API_KEY` env vars, or
`account/login/start { type: "apiKey" }` via app-server. Config at
`~/.codex/config.toml`. Per-project overrides in `.codex/config.toml`
traversed upward from cwd. `CODEX_HOME` env var isolates config/data.

### Session resume across restarts

Cross-process resume works: a new `codex app-server` instance can resume any
thread that had at least one `turn/start` (which creates the JSONL rollout
file). `thread/list` on a fresh server scans disk. No event replay on
reconnect — use `thread/read { includeTurns: true }` to reconstruct history.

### Sandbox / bwrap interaction (CRITICAL)

**Codex uses its own bwrap**. Running Codex inside CyDo's bwrap creates
nested user namespaces which fail on kernels with
`kernel.apparmor_restrict_unprivileged_userns=1` (Ubuntu 24.04+ default).

**Solution:** Use `sandboxPolicy: { type: "externalSandbox" }` in
`thread/start` and `turn/start`. This disables Codex's own bwrap while
signaling that external sandboxing is in place.

**Known bug (v0.101.0):** The `--dangerously-bypass-approvals-and-sandbox`
CLI flag does NOT fully propagate to app-server tool execution. Must
explicitly set sandbox in both `thread/start` AND `turn/start`.

### Read-only task types

For `read_only: true` tasks, CyDo's `resolveSandbox` downgrades all config
paths to ro before calling `agent.configureSandbox()` — so the bwrap
whitelist enforces read-only. The Codex `externalSandbox` params are the
same as for read-write tasks (`networkAccess: "enabled"`) since CyDo's
bwrap is what actually enforces the restriction.

### WebSocket vs stdio transport

**Recommendation:** Start with stdio (simpler, `AgentProcess`-based).
WebSocket enables: reconnection without losing thread state, multiple CyDo
instances sharing one app-server, and survival of in-progress turns across
CyDo restarts. Worth upgrading to later but not required initially.

### Model selection

Codex models specified as plain strings: `"o3"`, `"o4-mini"`, `"gpt-4.1"`.
Default determined by config. CyDo's `modelClassToAlias` on `CodexAgent`
should map `large` → `"o3"`, `small` → `"o4-mini"`.

### Concurrent turns

Not supported: `turn/start` on a thread with an active turn is accepted
but behavior is undefined. CyDo must wait for `turn/completed` before
sending the next `turn/start`. Use `turn/steer` for mid-turn injection.

### Fork granularity (`forkPoint` boolean)

Claude supports fork at any message UUID. Codex only supports whole-turn
granularity (`thread/fork`, `thread/rollback`). Rather than restricting
the UI globally, the backend emits a `forkPoint: true` field in the
envelope for events that are valid fork/undo points.

- **Claude**: every `message/assistant` / `message/user` with a UUID
- **Codex**: only `turn/result` (turn boundaries)

The frontend renders fork/undo affordances only on events where
`forkPoint` is true. This is analogous to the existing undo-point
filtering (`extractForkableUuids`), but pushed to the backend where the
agent type is known.

**Implementation:** In `broadcastTask()`, after calling the translation
layer, check the event type and agent to decide the `forkPoint` value.
Inject it into the envelope alongside `tid` and `timestamp`. For JSONL
history replay (`fileEvent` path), do the same when wrapping stored lines.

**Supersedes `forkable_uuids`:** The existing `forkable_uuids` control
message (`sendForkableUuidsFromFile` in app.d, `extractForkableUuids` in
persist.d) is no longer needed — the frontend builds its fork point list
from `forkPoint` flags on individual events. Remove the
`forkable_uuids` message and its supporting functions as part of A12
(protocol translation) or A14 (frontend reducer update).

### File revert capability

File revert on undo is an agent capability, not a universal feature.
Claude has `--rewind-files`; Codex has nothing equivalent. A FUSE-backed
mechanism for agent-agnostic file revert is planned as a future
enhancement.

For now, expose this as an `Agent` property:

- `agent.d`: Add `@property bool supportsFileRevert()` to `Agent` interface.
- `claude.d`: Return `true`.
- `codex.d`: Return `false`.

The undo UI's "revert file changes" checkbox is shown/enabled only when
`supportsFileRevert` is true for the task's agent. The backend sends this
in `session/init` (as `capabilities: { fileRevert: true }`) so the
frontend can adapt without knowing the agent type directly.

**Implementation in A9** (fork/undo refactoring): Replace the existing
`supportsRewind()` method with `supportsFileRevert()`. The undo handler
in `app.d` checks this before offering/executing file revert.

## Remaining open questions

None — all questions resolved.
