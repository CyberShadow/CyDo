# Claude Code JSONL vs Stream-JSON Format Comparison

Compared Claude Code's on-disk session JSONL files with the stream-json stdout output format.

## Location

Session JSONL files: `~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`
Where mangled cwd has `/` replaced with `-` (e.g. `-home-vladimir-work-cydo`).

## Core Finding

The `message` structure is identical between formats: same `id`, `role`, `model`, `content` (content blocks), `stop_reason`, `usage` fields. The differences are in the envelope (top-level fields) and which message types are present.

## Field Differences

### Common fields (same in both)

| Field | Notes |
|-------|-------|
| `type` | `"user"` or `"assistant"` |
| `uuid` | Message UUID |
| `isSidechain` | Boolean |
| `parent_tool_use_id` | Present in both (null when not applicable) |
| `message` | Identical structure |

### JSONL-only fields

| Field | Example |
|-------|---------|
| `sessionId` | `"16699f62-..."` (the actual session UUID) |
| `parentUuid` | `"2998a11e-..."` (linked-list chain) |
| `cwd` | `"/home/vladimir/work/cydo"` |
| `gitBranch` | `"master"` |
| `version` | `"2.1.56"` |
| `userType` | `"external"` |
| `requestId` | `"req_011CYb..."` |
| `timestamp` | `"2026-02-28T19:56:29.805Z"` |

### `session_id` field

- **JSONL**: field exists but is always `null`; actual value is in `sessionId` (camelCase)
- **Stream-JSON**: field contains the actual session UUID (e.g. `"abc-123"`)
- Both `session_id` and `sessionId` are present in JSONL; only `session_id` in stream-json

### `parent_tool_use_id` / `parentToolUseId`

Both naming variants are present in JSONL. Only `parent_tool_use_id` in stream-json.

## Message Types

### Stream-JSON only

| Type | Purpose |
|------|---------|
| `system` (subtype: `init`) | Turn start — model, tools, cwd, permissions |
| `result` | Turn end — cost, usage, stop_reason |
| `stream_event` | Token-by-token streaming deltas |

### JSONL only

| Type | Purpose |
|------|---------|
| `queue-operation` | Enqueue/dequeue bookkeeping |
| `progress` | Tool execution progress |
| `file-history-snapshot` | File state snapshots |
| `system` (subtype: `turn_duration`) | Turn timing metadata |

### Both formats

| Type | Notes |
|------|-------|
| `user` | User messages and tool results |
| `assistant` | Model responses (content blocks) |

## Practical Implications

To load JSONL for UI replay:
1. Filter to `user` and `assistant` types (skip `queue-operation`, `progress`, etc.)
2. Fix `session_id`: replace `"session_id":null` with actual value from `sessionId`
3. Extra fields (`cwd`, `gitBranch`, `timestamp`, etc.) are harmless — frontend ignores unknown fields

What's lost vs live stream-json:
- No `system.init` → no system banner (model name, tools list)
- No `result` → no cost/usage summary per turn
- No `stream_event` → messages appear fully formed (no token animation)
