# Claude Code Stream-JSON Protocol Specification

Reference for the headless/programmatic interface:
```
claude -p --input-format stream-json --output-format stream-json [options]
```

The process accepts NDJSON on **stdin** and emits NDJSON on **stdout**, enabling
multi-turn conversations with full tool-use visibility.

`-p` is required for `--input-format stream-json`. The process stays alive across
multiple input messages (the session is preserved), but each turn produces a full
`init → assistant → result` cycle. The `system.init` message is re-emitted at the
start of each turn (not just once at startup). Consumers should treat repeated
init messages as turn boundaries rather than new sessions.

## CLI Flags

### Core Flags

| Flag | Description |
|:-----|:------------|
| `-p`, `--print` | Required for headless mode. |
| `--input-format stream-json` | Accept NDJSON on stdin |
| `--output-format stream-json` | Emit NDJSON on stdout |
| `--verbose` | **Required for tool visibility.** Without this, tool results (user echo messages) are not emitted — the consumer has no visibility into what tools returned. |
| `--include-partial-messages` | Emit `stream_event` messages with token-by-token deltas. Enables real-time streaming UX. |

### Permission Flags

| Flag | Description |
|:-----|:------------|
| `--permission-mode MODE` | `default`, `acceptEdits`, `bypassPermissions`, `plan`, `dontAsk` |
| `--allowedTools TOOLS` | Tools that execute without prompts |
| `--disallowedTools TOOLS` | Tools removed from context entirely |
| `--dangerously-skip-permissions` | Bypass all permission checks (requires `--allow-dangerously-skip-permissions`) |
| `--permission-prompt-tool NAME` | MCP tool to delegate permission decisions (see [Permission Handling](#permission-handling)) |

### Session Flags

| Flag | Description |
|:-----|:------------|
| `--continue`, `-c` | Continue most recent conversation (same cwd) |
| `--resume ID`, `-r ID` | Resume specific session by ID |
| `--session-id UUID` | Use specific UUID for a new session |
| `--fork-session` | When resuming, create a new session branched from the original |
| `--replay-user-messages` | Echo user messages from stdin back on stdout for acknowledgment (marked with `isReplay: true`). Requires stream-json I/O. |
| `--max-turns N` | Limit agentic turns (tool-use loops) per input message |
| `--max-budget-usd N` | Maximum spend before stopping |
| `--no-session-persistence` | Don't persist session to disk (cannot resume later) |

### System Prompt Flags

| Flag | Description |
|:-----|:------------|
| `--system-prompt TEXT` | Replace entire system prompt |
| `--append-system-prompt TEXT` | Append to default system prompt |
| `--system-prompt-file PATH` | Replace system prompt from file |
| `--append-system-prompt-file PATH` | Append system prompt from file |

### Other Flags

| Flag | Description |
|:-----|:------------|
| `--model MODEL` | `sonnet`, `opus`, `haiku`, or full model name |
| `--mcp-config PATH` | Load MCP servers from JSON file |
| `--json-schema SCHEMA` | Structured output matching a JSON schema |
| `--fallback-model MODEL` | Fallback when primary is overloaded |
| `--add-dir PATH` | Add additional working directories |

---

## Input Messages (stdin)

All input is NDJSON: one JSON object per line.

### User Message

The only input message type:

```typescript
type InputMessage = {
  type: "user";
  message: {
    role: "user";
    content: string | ContentBlock[];
  };
  session_id: string;            // "default" for all messages (session is managed by the process)
  parent_tool_use_id: string | null;
};

type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } };
```

### Examples

**Text message:**
```json
{"type":"user","message":{"role":"user","content":"Hello"},"session_id":"default","parent_tool_use_id":null}
```

**Message with image:**
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"What is this?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBOR..."}}]},"session_id":"default","parent_tool_use_id":null}
```

---

## Output Messages (stdout)

All output is NDJSON. Each line is one of the following message types.

### System Init

Emitted at the start of **every turn** (not just once). Acts as a turn boundary.
Contains session metadata.

```typescript
type SystemInitMessage = {
  type: "system";
  subtype: "init";
  session_id: string;
  uuid: string;
  model: string;
  cwd: string;
  tools: string[];
  mcp_servers: { name: string; status: string }[];
  permissionMode: string;
  apiKeySource: string;
  claude_code_version: string;
  agents?: string[];
  slash_commands?: string[];
  skills?: string[];
  plugins?: { name: string; path: string }[];
  fast_mode_state?: string;
};
```

### Assistant Message

Emitted **per content block**, not per API response. A single API response with
thinking + text produces two `assistant` messages with the same `message.id`:
one containing the `thinking` block, then one containing the `text` block.

Consumers should **merge by `message.id`** to reconstruct the full response.

```typescript
type AssistantMessage = {
  type: "assistant";
  uuid: string;
  session_id: string;
  parent_tool_use_id: string | null;
  message: {
    id: string;                  // Same id for all blocks of the same API response
    role: "assistant";
    content: AssistantContentBlock[];  // Usually contains a single block
    model: string;
    stop_reason: string | null;  // "end_turn", "tool_use", or null
    usage: {
      input_tokens: number;
      output_tokens: number;
      cache_creation_input_tokens?: number;
      cache_read_input_tokens?: number;
    };
  };
  error?: "authentication_failed" | "billing_error" | "rate_limit"
        | "invalid_request" | "server_error" | "unknown";
};

type AssistantContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> }
  | { type: "thinking"; thinking: string; signature: string };
```

### User Message (echo)

Emitted only with `--verbose`. Contains tool results and raw tool output.
**Without `--verbose`, these are not emitted and the consumer has no visibility
into tool execution results.**

```typescript
type UserEchoMessage = {
  type: "user";
  uuid?: string;
  session_id: string;
  message: {
    role: "user";
    content: UserContentBlock[];
  };
  parent_tool_use_id: string | null;
  isSynthetic?: boolean;
  tool_use_result?: unknown;    // Raw tool output (e.g. {stdout, stderr} for Bash)
};

type UserContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_result"; tool_use_id: string; content: string; is_error?: boolean };
```

### Result Message

Final message of a turn. Emitted after Claude finishes or hits a limit.

```typescript
type ResultMessage = {
  type: "result";
  subtype: "success"
    | "error_max_turns"
    | "error_during_execution"
    | "error_max_budget_usd";
  uuid: string;
  session_id: string;
  is_error: boolean;
  result: string;              // Final text output
  num_turns: number;
  duration_ms: number;
  duration_api_ms: number;
  total_cost_usd: number;
  stop_reason: string | null;
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_creation_input_tokens: number;
    cache_read_input_tokens: number;
  };
  modelUsage: Record<string, {
    inputTokens: number;
    outputTokens: number;
    cacheCreationInputTokens: number;
    cacheReadInputTokens: number;
  }>;
  permission_denials: {
    tool_name: string;
    tool_use_id: string;
    tool_input: Record<string, unknown>;
  }[];
  errors?: string[];             // Only on error subtypes
  structured_output?: unknown;   // Only with --json-schema
};
```

### Stream Events (partial messages)

Only emitted with `--include-partial-messages`. Provides token-by-token streaming
for real-time display.

```typescript
type StreamEventMessage = {
  type: "stream_event";
  uuid: string;
  session_id: string;
  parent_tool_use_id: string | null;
  event: StreamEvent;
};
```

#### Stream Event Types

**`message_start`** — Start of API response. Contains model, usage metadata.
```typescript
{ type: "message_start"; message: { model: string; id: string; role: "assistant"; usage: Usage } }
```

**`content_block_start`** — Start of a content block. The `index` identifies the block.
```typescript
{ type: "content_block_start"; index: number; content_block: { type: "thinking" | "text" } }
```

**`content_block_delta`** — Incremental content. Different delta types per block type.
```typescript
// For thinking blocks:
{ type: "content_block_delta"; index: number; delta: { type: "thinking_delta"; thinking: string } }

// For text blocks:
{ type: "content_block_delta"; index: number; delta: { type: "text_delta"; text: string } }

// For tool_use blocks:
{ type: "content_block_delta"; index: number; delta: { type: "input_json_delta"; partial_json: string } }
```

**`content_block_stop`** — End of a content block.
```typescript
{ type: "content_block_stop"; index: number }
```

**`message_delta`** — Message-level update (stop reason, final usage).
```typescript
{ type: "message_delta"; delta: { stop_reason: string }; usage: Usage }
```

**`message_stop`** — End of message.
```typescript
{ type: "message_stop" }
```

#### Ordering with Assistant Messages

When `--include-partial-messages` is used, the `assistant` message for each content
block is emitted **after the last delta but before `content_block_stop`**:

```
stream_event  content_block_start   index=0 (thinking)
stream_event  content_block_delta   index=0 (thinking chunks...)
assistant     [thinking block]               ← accumulated thinking content
stream_event  content_block_stop    index=0
stream_event  content_block_start   index=1 (text)
stream_event  content_block_delta   index=1 (text chunks...)
assistant     [text block]                   ← accumulated text content
stream_event  content_block_stop    index=1
stream_event  message_delta
stream_event  message_stop
result
```

### System Status

```typescript
type StatusMessage = {
  type: "system";
  subtype: "status";
  status: "compacting" | null;
  permissionMode?: string;
  uuid: string;
  session_id: string;
};
```

### Compact Boundary

Emitted when context is compressed (auto or manual).

```typescript
type CompactBoundaryMessage = {
  type: "system";
  subtype: "compact_boundary";
  uuid: string;
  session_id: string;
  compact_metadata: {
    trigger: "manual" | "auto";
    pre_tokens: number;
  };
};
```

### Rate Limit Event

Emitted after each API call with rate limit status.

```typescript
type RateLimitEvent = {
  type: "rate_limit_event";
  uuid: string;
  session_id: string;
  rate_limit_info: {
    status: "allowed" | "allowed_warning" | "rejected";
    resetsAt?: number;         // Unix timestamp
    rateLimitType?: string;    // e.g. "five_hour"
    utilization?: number;
  };
};
```

### Other System Messages

```typescript
// Hook lifecycle
type HookStartedMessage = {
  type: "system"; subtype: "hook_started";
  hook_id: string; hook_name: string; hook_event: string;
  uuid: string; session_id: string;
};

// Task/subagent lifecycle
type TaskStartedMessage = {
  type: "system"; subtype: "task_started";
  task_id: string; tool_use_id?: string;
  uuid: string; session_id: string;
};

type TaskNotificationMessage = {
  type: "system"; subtype: "task_notification";
  task_id: string; status: "completed" | "failed" | "stopped";
  output_file: string; summary: string;
  uuid: string; session_id: string;
};

// Misc
type ToolUseSummaryMessage = { type: "tool_use_summary"; summary: string; /* ... */ };
type PromptSuggestionMessage = { type: "prompt_suggestion"; suggestion: string; /* ... */ };
```

---

## Message Flow

### Simple Q&A (no tools)

```
stdin:  {"type":"user",...,"content":"What is 2+2?"}

stdout: {"type":"system","subtype":"init","session_id":"abc-123",...}
stdout: {"type":"assistant","message":{"id":"msg_1","content":[{"type":"thinking",...}],...}}
stdout: {"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"4"}],...}}
stdout: {"type":"result","subtype":"success","result":"4",...}
```

### With Tool Use (--verbose)

```
stdout: {"type":"system","subtype":"init",...}
stdout: {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],...}}
stdout: {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"...","content":"file1\nfile2"}]},...}
stdout: {"type":"assistant","message":{"content":[{"type":"text","text":"The files are..."}],...}}
stdout: {"type":"result","subtype":"success",...}
```

### Multi-Turn Conversation

Each turn starts with `system.init` and ends with `result`:

```
stdin:  {"type":"user",...,"content":"My name is Alice"}
stdout: {"type":"system","subtype":"init","session_id":"abc-123",...}     ← turn 1 start
stdout: {"type":"assistant",...}
stdout: {"type":"result","subtype":"success",...}                          ← turn 1 end

stdin:  {"type":"user",...,"content":"What's my name?"}
stdout: {"type":"system","subtype":"init","session_id":"abc-123",...}     ← turn 2 start (same session)
stdout: {"type":"assistant","message":{"content":[{"type":"text","text":"Your name is Alice."}],...}}
stdout: {"type":"result","subtype":"success",...}                          ← turn 2 end
```

### With Streaming Deltas (--include-partial-messages)

```
stdout: {"type":"system","subtype":"init",...}
stdout: {"type":"stream_event","event":{"type":"message_start",...}}
stdout: {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}
stdout: {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me"}}}
stdout: {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" think..."}}}
stdout: {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me think..."}],...}}
stdout: {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
stdout: {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text"}}}
stdout: {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}}
stdout: {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}}
stdout: {"type":"assistant","message":{"content":[{"type":"text","text":"Hello there"}],...}}
stdout: {"type":"stream_event","event":{"type":"content_block_stop","index":1}}
stdout: {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},...}}
stdout: {"type":"stream_event","event":{"type":"message_stop"}}
stdout: {"type":"result","subtype":"success",...}
```

---

## Session Management

### Session Storage

Sessions are persisted as JSONL files at:
```
~/.claude/projects/<mangled-project-path>/<session-id>.jsonl
```
Where the project path has `/` replaced with `-`, e.g.:
`~/.claude/projects/-home-vladimir-work-cydo/<uuid>.jsonl`

Use `--no-session-persistence` to disable (session cannot be resumed).

### Resuming Sessions

After a process exits, a new process can resume the session:

```bash
# Capture session_id from first run
session_id=$(jq -r 'select(.type == "system") | .session_id' < output.jsonl | head -1)

# Resume later (minutes, hours, or days later)
claude -p --resume "$session_id" --input-format stream-json --output-format stream-json ...
```

The resumed process loads the full conversation history from disk and continues
as if the session never ended. The output format is identical to a new session.

**`--continue` / `-c`** resumes the most recent session in the current working
directory without needing the session ID.

**`--fork-session`** creates a new session branched from the resume point. The
original session is preserved unchanged. Useful for exploring alternative
approaches or for interrogation (see VISION.md Phase 7).

**`--replay-user-messages`** echoes user messages sent on stdin back on stdout
for acknowledgment, similar to IRCv3 `echo-message`. The echoed messages are
marked with `isReplay: true` to distinguish them from tool-result user messages:

```typescript
type UserMessageReplay = {
  type: "user";
  uuid: string;
  session_id: string;
  message: MessageParam;
  parent_tool_use_id: string | null;
  isReplay: true;              // Distinguishes echoed input from tool results
  isSynthetic?: boolean;
  tool_use_result?: unknown;
};
```

This lets the consumer confirm message delivery and display user messages
from the single authoritative output stream rather than tracking them separately.

### Session Listing (SDK)

```typescript
import { listSessions } from "@anthropic-ai/claude-agent-sdk";
const sessions = await listSessions({ dir: "/path/to/project" });
// Returns: { sessionId, summary, lastModified, fileSize, customTitle, firstPrompt, gitBranch, cwd }
```

---

## Permission Handling

In headless mode, tools that require permission will be denied unless explicitly allowed.

### Strategies

1. **Bypass all** via `--dangerously-skip-permissions` (requires `--allow-dangerously-skip-permissions`).
   This is CyDo's approach — agents run sandboxed.

2. **Pre-approve tools** via `--allowedTools`:
   ```
   claude -p --allowedTools "Read,Grep,Glob" ...
   ```

3. **`--permission-mode dontAsk`**: Tools not pre-approved are silently denied.

4. **MCP permission tool** via `--permission-prompt-tool`: Delegates permission
   decisions to an MCP tool. See below.

### `--permission-prompt-tool` (for reference)

Not used by CyDo (we use `--dangerously-skip-permissions`), but documented for completeness.

The named MCP tool receives:
```json
{
  "tool_use_id": "toolu_xxx",
  "tool_name": "Bash",
  "input": { "command": "ls -la" }
}
```

And must return (JSON-stringified in MCP `content[0].text`):
```json
{"behavior": "allow", "updatedInput": {"command": "ls -la"}}
```
or:
```json
{"behavior": "deny", "message": "Policy denied"}
```

`AskUserQuestion` also routes through `--permission-prompt-tool`. The response
must include the original questions plus an `answers` map:
```json
{
  "behavior": "allow",
  "updatedInput": {
    "questions": [{"question": "Which approach?", ...}],
    "answers": {"Which approach?": "Option A"}
  }
}
```

### Permission Denials in Result

Denied tool calls appear in the `result` message:
```json
{
  "type": "result",
  "permission_denials": [
    {"tool_name": "Bash", "tool_use_id": "toolu_xxx", "tool_input": {"command": "rm -rf /"}}
  ]
}
```

### AskUserQuestion in Headless Mode

Without `--permission-prompt-tool`:
- In `dontAsk` mode: denied with an explanation message
- In `bypassPermissions` mode: executes but typically fails (no TTY for interactive input)

With `--permission-prompt-tool`: routes through the MCP tool like any other permission request.

---

## Known Issues

1. **Session file duplication** (GitHub #5034): Each input message may cause conversation history to be duplicated in session `.jsonl` files. Use `--no-session-persistence` if session files aren't needed.

2. **Missing result event** (GitHub #1920): The final `{"type":"result",...}` may occasionally not be emitted.

3. **Extended thinking + streaming**: When `maxThinkingTokens` is explicitly set, `stream_event` messages may not be emitted.

4. **Session index staleness** (GitHub #25032): `sessions-index.json` is sometimes not updated, making sessions invisible to `--resume` even though the JSONL files exist on disk.

---

## References

- [Official headless docs](https://code.claude.com/docs/en/headless)
- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Agent SDK (TypeScript)](https://platform.claude.com/docs/en/agent-sdk/typescript)
- [Streaming output](https://platform.claude.com/docs/en/agent-sdk/streaming-output)
- [Permissions](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [User input handling](https://platform.claude.com/docs/en/agent-sdk/user-input)
- [Session management](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [npm: @anthropic-ai/claude-agent-sdk](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)
- Existing output parser: `~/libexec/format-claude-session` (jq script)
