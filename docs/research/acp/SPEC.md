# Agent Client Protocol (ACP) Specification

Reference for the ACP protocol as specified at [agentclientprotocol.com](https://agentclientprotocol.com)
and as implemented by GitHub Copilot CLI (`copilot --acp`).

**Protocol version:** `1` (integer, negotiated during `initialize`)
**Schema version:** `0.11.3` (2026-03-18)
**Transport:** JSON-RPC 2.0 over NDJSON on stdio (default) or TCP
**License:** Apache 2.0

ACP is a bidirectional JSON-RPC 2.0 protocol between **Agents** (AI-powered code
assistants) and **Clients** (editors, IDEs, orchestrators). Unlike Claude Code's
stream-json protocol which uses typed NDJSON messages, ACP uses standard JSON-RPC
2.0 with `method`, `params`, `id` fields. Requests have `id` and expect a response;
notifications omit `id`.

```
Client ──stdin──▶ Agent    (client requests/notifications)
Client ◀──stdout── Agent   (agent responses/requests/notifications)
```

How to invoke with Copilot:
```sh
copilot --acp                   # stdio mode (default)
copilot --acp --port 3000       # TCP mode
```

---

## CLI Flags (Copilot-specific)

### Core Flags

| Flag | Description |
|:-----|:------------|
| `--acp` | Start as ACP server (stdio mode by default) |
| `--port PORT` | TCP mode instead of stdio |
| `-p PROMPT`, `--prompt PROMPT` | Non-interactive single-prompt mode (exits after) |
| `-i PROMPT`, `--interactive PROMPT` | Interactive mode with auto-executed initial prompt |
| `--output-format json` | JSONL output in non-ACP mode |

### Permission Flags

| Flag | Description |
|:-----|:------------|
| `--yolo` | Auto-approve all tool permissions (alias: `--allow-all`) |
| `--allow-tool TOOL` | Pre-approve specific tool |
| `--deny-tool TOOL` | Block specific tool |
| `--allow-all-paths` | Disable file path restrictions |
| `--allow-url URL` | Allow specific URL access |
| `--deny-url URL` | Block specific URL access |
| `--no-ask-user` | Disable the ask_user tool (autonomous operation) |
| `--available-tools T1,T2,...` | Restrict model to these tools only (glob patterns supported) |
| `--excluded-tools T1,T2,...` | Exclude these tools |

### Session Flags

| Flag | Description |
|:-----|:------------|
| `--continue` | Resume most recent session |
| `--resume [ID]` | Resume specific session (or open picker if no ID) |
| `--config-dir PATH` | Override config directory (default: `~/.copilot`) |

### Model Flags

| Flag | Description |
|:-----|:------------|
| `--model MODEL` | Set AI model (default: `claude-sonnet-4.5`) |
| `--autopilot` | Autonomous multi-turn continuation |
| `--max-autopilot-continues N` | Limit autopilot continuation loops |

### MCP Flags

| Flag | Description |
|:-----|:------------|
| `--additional-mcp-config JSON` | Add MCP server for this session only. Accepts inline JSON or `@/path/to/file.json`. Highest MCP config priority. |
| `--disable-builtin-mcps` | Disable all built-in MCP servers |
| `--disable-mcp-server NAME` | Disable specific MCP server |
| `--enable-all-github-mcp-tools` | Enable full GitHub MCP toolset (including writes) |
| `--add-github-mcp-tool TOOL` | Enable specific GitHub MCP tools |

### System Prompt

System prompt injection is done via the SDK `SessionConfig.systemMessage` object,
not via CLI flags. Three modes are supported:

| Mode | Description |
|:-----|:------------|
| `append` | Appends to Copilot's built-in system prompt |
| `replace` | Replaces all built-in prompts (removes guardrails) |
| `customize` | Section-level overrides (v1.0.7+) |

**On the wire**, system message config is passed as part of `session/new` parameters
via Copilot-specific extensions. The exact field names are not publicly documented
in the ACP spec — they are Copilot SDK abstractions. ⚠️ *Inferred, not confirmed
from raw wire traces.*

### Other Flags

| Flag | Description |
|:-----|:------------|
| `--experimental` | Enable experimental features (Autopilot, alt-screen, dynamic MCP instructions) |
| `--agent AGENT` | Invoke a custom agent |
| `--plugin-dir PATH` | Load plugin from directory |
| `--add-dir PATH` | Add directory to allowed file access list |
| `--screen-reader` | Accessibility optimizations |
| `--no-custom-instructions` | Skip loading custom instructions |
| `--disable-parallel-tools-execution` | Sequential tool execution |

### Environment Variables

| Variable | Description |
|:---------|:------------|
| `COPILOT_GITHUB_TOKEN` | Auth token (highest priority) |
| `GH_TOKEN` | Auth token (secondary) |
| `GITHUB_TOKEN` | Auth token (tertiary) |
| `COPILOT_MODEL` | Default model |
| `COPILOT_HOME` | Override config directory (lower priority than `--config-dir`) |
| `COPILOT_ALLOW_ALL` | Auto-approve all permissions |

**Config directory precedence:** `--config-dir` > `COPILOT_HOME` > `~/.copilot`

---

## Protocol Lifecycle

### Phase 1: Initialization

Client sends `initialize` as the first message. The agent responds with its
capabilities. Both sides negotiate the protocol version.

```
Client ──▶ initialize(protocolVersion, clientCapabilities, clientInfo)
Client ◀── {protocolVersion, agentCapabilities, agentInfo, authMethods}
```

### Phase 2: Authentication (optional)

If the agent returns `authMethods` in the initialize response, the client may
need to authenticate before creating sessions.

```
Client ──▶ authenticate(methodId)
Client ◀── {}
```

Copilot uses environment tokens (`COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`)
or OAuth device flow. The `authenticate` method is typically not needed when tokens
are in the environment.

### Phase 3: Session Setup

Create a new session or resume an existing one.

```
Client ──▶ session/new(cwd, mcpServers)
Client ◀── {sessionId, configOptions?, modes?}
```

### Phase 4: Prompt/Response Cycle

Send a prompt. The agent streams `session/update` notifications while processing,
then returns the final response.

```
Client ──▶ session/prompt(sessionId, prompt)
Agent  ──▶ session/update(sessionId, update)    ← notifications (no id)
Agent  ──▶ session/update(sessionId, update)    ← ...repeated...
Agent  ──▶ session/request_permission(...)       ← if tool needs approval (has id)
Client ──▶ {id, result: {outcome: ...}}          ← permission response
Agent  ──▶ session/update(sessionId, update)    ← more updates...
Client ◀── {stopReason}                          ← final response to session/prompt
```

### Phase 5: Shutdown

No explicit shutdown method in the stable spec. The client simply closes the
transport (stdin EOF or TCP close). Schema v0.11.0 added unstable `session/stop`
(renamed to `session/close` in v0.11.2).

---

## Client → Agent Methods

### `initialize`

**Type:** Request (has `id`)
**Required:** Yes — must be the first message.

```typescript
// Request params
type InitializeRequest = {
  protocolVersion: number;        // Currently 1
  clientCapabilities: {
    fs?: {
      readTextFile?: boolean;
      writeTextFile?: boolean;
    };
    terminal?: boolean;
  };
  clientInfo?: {
    name: string;
    version: string;
    title?: string;
  };
};

// Response
type InitializeResponse = {
  protocolVersion: number;
  agentCapabilities: {
    loadSession?: boolean;
    mcpCapabilities?: {
      http?: boolean;
      sse?: boolean;
    };
    promptCapabilities?: {
      image?: boolean;
      audio?: boolean;
      embeddedContext?: boolean;
    };
    sessionCapabilities?: {
      list?: {};              // presence = supported
      fork?: {};              // unstable, v0.10.0+
    };
  };
  agentInfo?: {
    name: string;
    version: string;
  };
  authMethods: AuthMethod[];    // empty if no auth needed
};

type AuthMethod = {
  id: string;
  name: string;
  description?: string;
};
```

**Example:**
```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true},"clientInfo":{"name":"cydo","version":"0.1.0"}}}
```

**Response:**
```json
{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"list":{}}},"agentInfo":{"name":"copilot","version":"1.0.9"},"authMethods":[]}}
```

**Copilot:** ✅ Implemented. Returns `loadSession: true` as of v0.0.410.

---

### `authenticate`

**Type:** Request
**Required:** Only if `authMethods` is non-empty.

```typescript
type AuthenticateRequest = {
  methodId: string;     // One of the ids from authMethods
};

type AuthenticateResponse = {};
```

**Copilot:** Typically unnecessary when `COPILOT_GITHUB_TOKEN` is set.

---

### `session/new`

**Type:** Request
**Required:** Yes — creates a conversation session.

```typescript
type NewSessionRequest = {
  cwd: string;                    // Absolute path to working directory
  mcpServers: McpServer[];        // MCP servers to configure
};

type McpServer =
  | { type: "stdio"; name: string; command: string; args: string[]; env: EnvVariable[] }
  | { type: "http";  name: string; url: string; headers: HttpHeader[] }
  | { type: "sse";   name: string; url: string; headers: HttpHeader[] };

type EnvVariable = { name: string; value: string };
type HttpHeader  = { name: string; value: string };

type NewSessionResponse = {
  sessionId: string;
  configOptions?: SessionConfigOption[];
  modes?: SessionModeState;
};
```

**Example:**
```json
{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/home/user/project","mcpServers":[]}}
```

**Response:**
```json
{"jsonrpc":"2.0","id":1,"result":{"sessionId":"a1b2c3d4","configOptions":[{"type":"select","currentValue":"claude-sonnet-4.5","options":[{"name":"Claude Sonnet 4.5","value":"claude-sonnet-4.5"},{"name":"GPT-5","value":"gpt-5"}]}],"modes":{"availableModes":[{"id":"agent","name":"Agent"},{"id":"plan","name":"Plan"}],"currentModeId":"agent"}}}
```

**Copilot:** ✅ Implemented. ⚠️ `mcpServers` parameter is accepted but **not
loaded** — known issue [#1040](https://github.com/github/copilot-cli/issues/1040).
Use `--additional-mcp-config` CLI flag instead.

---

### `session/load`

**Type:** Request
**Required:** Only if resuming a previous session.

```typescript
type LoadSessionRequest = {
  sessionId: string;              // Previously obtained session ID
  cwd: string;
  mcpServers: McpServer[];
};

type LoadSessionResponse = {
  configOptions?: SessionConfigOption[];
  modes?: SessionModeState;
};
```

**Copilot:** ✅ Implemented as of v0.0.410. Requires `loadSession: true` in
agent capabilities. Session state stored at `~/.copilot/session-state/{sessionId}/`.

---

### `session/list`

**Type:** Request
**Required:** No — requires `sessionCapabilities.list` in agent capabilities.

```typescript
type ListSessionsRequest = {
  cwd?: string;                   // Filter by working directory
  cursor?: string;                // Pagination cursor
};

type ListSessionsResponse = {
  sessions: SessionInfo[];
  nextCursor?: string;
};

type SessionInfo = {
  sessionId: string;
  cwd: string;
  title?: string;
  updatedAt?: string;             // ISO 8601 timestamp
};
```

**Copilot:** ✅ Stabilized in schema v0.11.1.

---

### `session/prompt`

**Type:** Request
**Required:** Yes — sends a user message.

```typescript
type PromptRequest = {
  sessionId: string;
  prompt: ContentBlock[];
};

type ContentBlock =
  | { type: "text"; text: string; annotations?: Annotations }
  | { type: "image"; data: string; mimeType: string; uri?: string; annotations?: Annotations }
  | { type: "audio"; data: string; mimeType: string; annotations?: Annotations }
  | { type: "resource_link"; uri: string; name: string; description?: string;
      mimeType?: string; size?: number; title?: string; annotations?: Annotations }
  | { type: "resource"; resource: EmbeddedResource; annotations?: Annotations };

type Annotations = {
  audience?: ("user" | "assistant")[];
  lastModified?: string;
  priority?: number;
};

type PromptResponse = {
  stopReason: StopReason;
};

type StopReason = "end_turn" | "cancelled";
```

The response is returned **after the turn completes**. During processing, the
agent streams `session/update` notifications.

**Example:**
```json
{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"a1b2c3d4","prompt":[{"type":"text","text":"What files are in the project?"}]}}
```

**Response (after streaming completes):**
```json
{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}
```

**Copilot:** ✅ Implemented.

---

### `session/cancel`

**Type:** Notification (no `id`, no response)
**Required:** No — cancels the current turn.

```typescript
type CancelNotification = {
  sessionId: string;
};
```

**Example:**
```json
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"a1b2c3d4"}}
```

After cancellation, the in-flight `session/prompt` returns `stopReason: "cancelled"`.

**Copilot:** ✅ Implemented. Cooperative cancellation — in-flight tool executions
may complete before the cancel takes effect.

---

### `session/fork` (unstable)

**Type:** Request
**Required:** No — requires `sessionCapabilities.fork` in agent capabilities.
**Schema version:** Added in v0.10.0 as unstable.

```typescript
type ForkSessionRequest = {
  sessionId: string;              // Session to fork from
  cwd?: string;                   // Working directory (agent may reject changes)
  mcpServers?: McpServer[];       // Tool configuration
};

type ForkSessionResponse = {
  sessionId: string;              // New forked session ID
  configOptions?: SessionConfigOption[];
  modes?: SessionModeState;
};
```

Creates a new independent session derived from an existing one, preserving
conversation context. Useful for summarization, PR description generation, or
subagent delegation without polluting the original session.

**Copilot:** ❌ Not implemented. Issue [#2058](https://github.com/github/copilot-cli/issues/2058)
is open but unimplemented.

---

### `session/set_mode`

**Type:** Request
**Required:** No

```typescript
type SetSessionModeRequest = {
  sessionId: string;
  modeId: string;                 // e.g. "agent", "plan", "ask"
};

type SetSessionModeResponse = {};
```

**Copilot:** ✅ Implemented. Available modes returned in `session/new` response.

---

### `session/set_model` (Copilot extension)

Not in the ACP spec. Copilot uses `session/set_config_option` instead.

---

### `session/set_config_option`

**Type:** Request
**Required:** No

```typescript
type SetSessionConfigOptionRequest = {
  sessionId: string;
  configId: string;               // e.g. "model", "reasoningEffort"
  value: string;                  // e.g. "claude-sonnet-4.6", "high"
};

type SetSessionConfigOptionResponse = {
  configOptions: SessionConfigOption[];   // Updated config options
};
```

The `configOptions` returned in `session/new` describe available config IDs and
their possible values. For example, to change the model:

```json
{"jsonrpc":"2.0","id":5,"method":"session/set_config_option","params":{"sessionId":"a1b2c3d4","configId":"model","value":"claude-sonnet-4.6"}}
```

**Copilot:** ✅ Implemented. Reasoning effort configurable via `reasoningEffort`
config option (`"low"`, `"medium"`, `"high"`, `"xhigh"`).

---

## Agent → Client Methods

### `session/update`

**Type:** Notification (no `id`)
**Required:** Yes — the primary streaming mechanism.

The agent sends `session/update` notifications during `session/prompt` processing.
Each notification contains a `sessionId` and an `update` object whose
`sessionUpdate` discriminator field determines the variant.

```typescript
type SessionNotification = {
  sessionId: string;
  update: SessionUpdate;
};
```

See [session/update Variants](#sessionupdate-variants) below for all variant types.

**Copilot:** ✅ Implemented.

---

### `session/request_permission`

**Type:** Request (has `id`, expects response)
**Required:** Yes — the permission gate for tool execution.

```typescript
type RequestPermissionRequest = {
  sessionId: string;
  toolCall: ToolCallUpdate;       // The tool call being requested
  options: PermissionOption[];    // Choices presented to the user
};

type PermissionOption = {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
};

type RequestPermissionResponse = {
  outcome: RequestPermissionOutcome;
};

type RequestPermissionOutcome =
  | { outcome: "selected"; optionId: string }
  | { outcome: "cancelled" };
```

**Example (agent → client):**
```json
{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{"sessionId":"a1b2c3d4","toolCall":{"toolCallId":"call_1","title":"Run shell command","kind":"execute","status":"pending","rawInput":{"command":"npm test"}},"options":[{"optionId":"allow","name":"Allow this command","kind":"allow_once"},{"optionId":"always","name":"Always allow shell commands","kind":"allow_always"},{"optionId":"reject","name":"Deny","kind":"reject_once"}]}}
```

**Response (client → agent):**
```json
{"jsonrpc":"2.0","id":3,"result":{"outcome":{"outcome":"selected","optionId":"allow"}}}
```

**Auto-approve all (headless):** respond with `"selected"` + the `allow_once`
or `allow_always` option ID for every request. The `--yolo` / `--allow-all-tools`
flag does this internally.

**Copilot:** ✅ Implemented. Known historical bug: permission requests used
friendly names instead of `toolCallId` values (issue #989, resolved).

---

### `fs/read_text_file`

**Type:** Request (agent → client)
**Required:** Only if client declared `fs.readTextFile: true`.

```typescript
type ReadTextFileRequest = {
  sessionId: string;
  path: string;                   // Absolute path
  line?: number;                  // 1-based start line
  limit?: number;                 // Max lines to read
};

type ReadTextFileResponse = {
  content: string;
};
```

**Copilot:** ✅ Implemented. The agent delegates file reads to the client when
the client advertises this capability.

---

### `fs/write_text_file`

**Type:** Request (agent → client)
**Required:** Only if client declared `fs.writeTextFile: true`.

```typescript
type WriteTextFileRequest = {
  sessionId: string;
  path: string;                   // Absolute path
  content: string;                // Full file content
};

type WriteTextFileResponse = {};
```

**Copilot:** ✅ Implemented.

---

### `terminal/create`

**Type:** Request (agent → client)
**Required:** Only if client declared `terminal: true`.

```typescript
type CreateTerminalRequest = {
  sessionId: string;
  command: string;
  args?: string[];
  cwd?: string;
  env?: EnvVariable[];
  outputByteLimit?: number;
};

type CreateTerminalResponse = {
  terminalId: string;
};
```

---

### `terminal/output`

**Type:** Request (agent → client)

```typescript
type TerminalOutputRequest = {
  sessionId: string;
  terminalId: string;
};

type TerminalOutputResponse = {
  output: string;
  truncated: boolean;
  exitStatus?: TerminalExitStatus;
};
```

---

### `terminal/wait_for_exit`

**Type:** Request (agent → client)

```typescript
type WaitForTerminalExitRequest = {
  sessionId: string;
  terminalId: string;
};

type WaitForTerminalExitResponse = {
  exitCode?: number;
  signal?: string;
};
```

---

### `terminal/kill`

**Type:** Request (agent → client)

```typescript
type KillTerminalRequest = {
  sessionId: string;
  terminalId: string;
};

type KillTerminalResponse = {};
```

---

### `terminal/release`

**Type:** Request (agent → client)

```typescript
type ReleaseTerminalRequest = {
  sessionId: string;
  terminalId: string;
};

type ReleaseTerminalResponse = {};
```

---

## session/update Variants

All `session/update` notifications share this envelope:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "...",
    "update": {
      "sessionUpdate": "<variant_name>",
      ...variant-specific fields...
    }
  }
}
```

The discriminator field is **`sessionUpdate`** (Python SDK alias: `session_update`).

### `agent_message_chunk`

Streamed text content from the agent's response. Emitted incrementally as the
model generates tokens.

```typescript
type AgentMessageChunk = {
  sessionUpdate: "agent_message_chunk";
  content: ContentBlock;          // Usually { type: "text", text: "..." }
};
```

**Example:**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I'll help you with that. Let me "}}}}
```

---

### `agent_thought_chunk`

Internal reasoning from the model (extended thinking). Only emitted if the model
supports it and the client has opted in.

```typescript
type AgentThoughtChunk = {
  sessionUpdate: "agent_thought_chunk";
  content: ContentBlock;          // Usually { type: "text", text: "..." }
};
```

**Example:**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user wants to see project files. I should use the terminal to run ls."}}}}
```

---

### `user_message_chunk`

Echo of the user's input message. Emitted during session load/resume to replay
conversation history.

```typescript
type UserMessageChunk = {
  sessionUpdate: "user_message_chunk";
  content: ContentBlock;
};
```

---

### `tool_call`

Announces that a new tool invocation has started. This is the initial notification
with the tool's parameters.

```typescript
type ToolCall = {
  sessionUpdate: "tool_call";
  toolCallId: string;             // Unique ID within the session
  title: string;                  // Human-readable description
  kind: ToolKind;
  status: ToolStatus;
  locations?: ToolLocation[];     // Affected file paths
  rawInput?: Record<string, unknown>;   // Raw tool parameters
};

type ToolKind =
  | "read"      // File/data retrieval
  | "edit"      // Content modification
  | "delete"    // File/data removal
  | "move"      // File relocation/renaming
  | "search"    // Information lookup
  | "execute"   // Command/code execution
  | "think"     // Internal reasoning
  | "fetch"     // External data retrieval
  | "other";    // Miscellaneous

type ToolStatus =
  | "pending"       // Awaiting approval or input still streaming
  | "in_progress"   // Currently executing
  | "completed"     // Finished successfully
  | "failed";       // Execution error

type ToolLocation = {
  path: string;
  line?: number;                  // 1-based
};
```

**Example:**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"Reading project files","kind":"read","status":"pending","locations":[{"path":"/home/user/project/README.md"}],"rawInput":{"path":"/home/user/project/README.md"}}}}
```

---

### `tool_call_update`

Progress or completion of a tool call. Uses the same `toolCallId` to correlate
with the initial `tool_call`.

```typescript
type ToolCallUpdate = {
  sessionUpdate: "tool_call_update";
  toolCallId: string;
  status?: ToolStatus;
  content?: ToolContent[];
  rawOutput?: Record<string, unknown>;
};

type ToolContent =
  | { type: "content"; content: ContentBlock }
  | { type: "diff"; diff: Diff }
  | { type: "terminal"; terminalId: string };

type Diff = {
  path: string;
  oldText?: string;
  newText: string;
};
```

**Example (completion):**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"# My Project\n\nA sample project..."}}],"rawOutput":{"content":"# My Project\n\nA sample project..."}}}}
```

**Example (file edit with diff):**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_2","status":"completed","content":[{"type":"diff","diff":{"path":"/home/user/project/main.ts","oldText":"const x = 1;","newText":"const x = 2;"}}]}}}
```

**Example (terminal output):**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_3","status":"completed","content":[{"type":"terminal","terminalId":"term_1"}]}}}
```

---

### `plan`

Execution plan updates. Maps to the agent's todo list / task tracking.

```typescript
type PlanUpdate = {
  sessionUpdate: "plan";
  entries: PlanEntry[];
};

type PlanEntry = {
  content: string;
  status: "pending" | "in_progress" | "completed";
  priority: "high" | "medium" | "low";
};
```

**Example:**
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"a1b2c3d4","update":{"sessionUpdate":"plan","entries":[{"content":"Read project structure","status":"completed","priority":"high"},{"content":"Implement feature","status":"in_progress","priority":"high"},{"content":"Write tests","status":"pending","priority":"medium"}]}}}
```

---

### `available_commands_update`

Updated list of available slash commands.

```typescript
type AvailableCommandsUpdate = {
  sessionUpdate: "available_commands_update";
  availableCommands: AvailableCommand[];
};

type AvailableCommand = {
  name: string;
  description: string;
  input?: { hint: string };
};
```

---

### `config_option_update`

Session configuration options changed (e.g., available models updated).

```typescript
type ConfigOptionUpdate = {
  sessionUpdate: "config_option_update";
  configOptions: SessionConfigOption[];
};

type SessionConfigOption = {
  type: "select";
  currentValue: string;
  options: SessionConfigSelectOption[] | SessionConfigSelectGroup[];
};

type SessionConfigSelectOption = {
  name: string;
  value: string;
  description?: string;
};

type SessionConfigSelectGroup = {
  group: string;
  name: string;
  options: SessionConfigSelectOption[];
};
```

---

### `current_mode_update`

Agent's operating mode changed.

```typescript
type CurrentModeUpdate = {
  sessionUpdate: "current_mode_update";
  currentModeId: string;
};
```

---

### `session_info_update`

Session metadata changed (title, timestamp).

```typescript
type SessionInfoUpdate = {
  sessionUpdate: "session_info_update";
  title?: string | null;          // null clears the title
  updatedAt?: string | null;      // ISO 8601; null clears
};
```

---

### `usage_update` (unstable)

Token usage and cost tracking. Added in schema v0.10.8.

```typescript
type UsageUpdate = {
  sessionUpdate: "usage_update";
  size: number;                   // Total context window size (tokens)
  used: number;                   // Tokens currently in context
  cost?: {                        // Cumulative session cost
    // Fields TBD — not yet stable
  };
};
```

---

## Message Flow Examples

### Simple Q&A (no tools)

```
→ {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true},"clientInfo":{"name":"cydo","version":"0.1.0"}}}
← {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"copilot","version":"1.0.9"},"authMethods":[]}}

→ {"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/home/user/project","mcpServers":[]}}
← {"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess_001"}}

→ {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"What is 2+2?"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"2 + 2 = 4"}}}}
← {"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}
```

### With Tool Use

```
→ {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"List files in the project"}]}}

← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"I should list the files in the project directory."}}}}

← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"List project files","kind":"execute","status":"pending","rawInput":{"command":"ls -la"}}}}

← {"jsonrpc":"2.0","id":10,"method":"session/request_permission","params":{"sessionId":"sess_001","toolCall":{"toolCallId":"call_1","title":"List project files","kind":"execute","status":"pending","rawInput":{"command":"ls -la"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Deny","kind":"reject_once"}]}}

→ {"jsonrpc":"2.0","id":10,"result":{"outcome":{"outcome":"selected","optionId":"allow"}}}

← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","content":[{"type":"terminal","terminalId":"term_1"}]}}}

← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Here are the files in your project:\n- README.md\n- src/\n- package.json"}}}}

← {"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}
```

### Multi-Turn Conversation

```
→ {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"My name is Alice"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello Alice! How can I help you today?"}}}}
← {"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}

→ {"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"What's my name?"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Your name is Alice."}}}}
← {"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
```

### Cancellation

```
→ {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"Write a very long essay"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Let me write an essay about..."}}}}

→ {"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess_001"}}

← {"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}
```

### Session Resume

```
→ {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true},"clientInfo":{"name":"cydo","version":"0.1.0"}}}
← {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"authMethods":[]}}

→ {"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"sess_001","cwd":"/home/user/project","mcpServers":[]}}

← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"My name is Alice"}}}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello Alice!"}}}}

← {"jsonrpc":"2.0","id":1,"result":{"configOptions":[],"modes":{"availableModes":[{"id":"agent","name":"Agent"}],"currentModeId":"agent"}}}

→ {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_001","prompt":[{"type":"text","text":"What's my name?"}]}}
← {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Your name is Alice."}}}}
← {"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}
```

---

## Session Management

### Session Storage (Copilot)

Sessions are stored at:
```
~/.copilot/session-state/{sessionId}/
├── checkpoints/         # Incremental JSON snapshots
├── plan.md              # Current plan state
└── files/               # Modified file copies
```

The `--config-dir` flag or `COPILOT_HOME` env var can redirect this.

### Resume Semantics

`session/load` restores a session from the agent's persistent storage. During
loading, the agent replays conversation history as `session/update` notifications
(`user_message_chunk` and `agent_message_chunk` variants) before returning the
response. The client can render these to reconstruct the UI state.

### Fork Semantics (unstable)

`session/fork` (schema v0.10.0+) creates a new session derived from an existing
one. The forked session shares conversation context but diverges from the fork
point. Parameters mirror `session/load` — the agent may reject incompatible
working directory changes.

**Copilot:** ❌ Not implemented.

### Session Listing

`session/list` returns available sessions, optionally filtered by `cwd`. Supports
cursor-based pagination. Requires `sessionCapabilities.list` capability.

---

## Permission Handling

### Flow

1. Agent encounters a tool call that requires authorization
2. Agent sends `session/request_permission` (request with `id`)
3. Client presents options to the user (or auto-approves)
4. Client responds with `{outcome: "selected", optionId: "..."}` or `{outcome: "cancelled"}`
5. Agent proceeds or skips the tool call accordingly

### Option Kinds

| Kind | Meaning |
|:-----|:--------|
| `allow_once` | Approve this specific invocation |
| `allow_always` | Approve all future invocations of this tool |
| `reject_once` | Deny this specific invocation |
| `reject_always` | Deny all future invocations of this tool |

### Auto-Approve Strategies

| Strategy | How |
|:---------|:----|
| `--yolo` / `--allow-all` | CLI flag: auto-approves everything internally |
| `--allow-tool TOOL` | Pre-approve specific tools |
| Programmatic | Respond `{outcome: "selected", optionId: "<allow_id>"}` to every `session/request_permission` |

### Comparison with Claude Code

| Aspect | Claude Code | ACP / Copilot |
|:-------|:------------|:--------------|
| Mechanism | `--permission-prompt-tool` MCP delegation or `--dangerously-skip-permissions` | `session/request_permission` JSON-RPC request |
| Auto-approve | `--dangerously-skip-permissions` | `--yolo` / `--allow-all-tools` |
| Pre-approve | `--allowedTools` list | `--allow-tool` per tool |
| Mode | `--permission-mode` (5 modes) | Options in each request |
| Denied tools | Listed in `result.permission_denials` | Agent skips the call, no explicit tracking |

---

## MCP Configuration

### `--additional-mcp-config` (recommended)

Inject per-session MCP servers without modifying global config:

```sh
# From file:
copilot --acp --additional-mcp-config @/path/to/mcp-config.json

# Inline JSON:
copilot --acp --additional-mcp-config '{"mcpServers":{"my-tool":{"command":"...","args":["..."]}}}'
```

Highest priority in MCP config merge order.

### `--config-dir` / `COPILOT_HOME` (full isolation)

Redirect all config including MCP to an isolated directory:

```sh
COPILOT_GITHUB_TOKEN=$TOKEN copilot --acp --config-dir /tmp/isolated-copilot
```

Auth tokens from `~/.copilot/` are NOT inherited — must pass via env var.

### Workspace-level `.vscode/mcp.json`

Loaded automatically from the working directory passed to `session/new`:

```json
{
  "servers": {
    "my-tool": {
      "command": "/path/to/mcp-server",
      "args": ["--stdio"]
    }
  }
}
```

### `mcpServers` in `session/new`

⚠️ **Broken in Copilot.** MCP servers passed in the ACP `session/new` params
are accepted by Zod validation but **not loaded**. Known issue
[#1040](https://github.com/github/copilot-cli/issues/1040) (open as of March 2026).

Root cause: `copilot --acp` does not declare `mcpCapabilities` in its
`agentCapabilities` response, so the ACP layer doesn't trigger MCP loading from
session parameters.

### MCP Config Precedence (Copilot)

1. `--additional-mcp-config` (CLI flag, highest)
2. `.vscode/mcp.json` (workspace-level)
3. `~/.copilot/mcp-config.json` (global user config)
4. Built-in GitHub MCP server (lowest)

---

## Copilot-Specific Extensions

These features are Copilot-specific and not part of the ACP standard.

### Model Selection

Available via `--model` CLI flag, `COPILOT_MODEL` env var, or
`session/set_config_option` with `configId: "model"` at runtime.

Available models (as of March 2026):
- `claude-sonnet-4.5` (default)
- `claude-sonnet-4.6`
- `claude-haiku-4.5`
- `claude-opus-4.6` (may require staff flag)
- `gpt-5`
- `gpt-5.4-mini`

### Reasoning Effort

Via `session/set_config_option` with `configId: "reasoningEffort"`:
- `"low"`, `"medium"`, `"high"`, `"xhigh"`

### Autopilot Mode

`--autopilot` flag enables multi-turn autonomous continuation without user
interaction. `--max-autopilot-continues N` limits the number of consecutive
autonomous turns.

### Custom Agents

`--agent AGENT_NAME` invokes a custom agent defined in the user agents directory.
Agents can also be selected via `/agent` slash command interactively.

### Slash Commands

Copilot supports many slash commands in interactive mode (see CLI reference).
The `available_commands_update` session update reports available commands to
ACP clients.

### System Prompt Injection

Via SDK `SessionConfig.systemMessage` (not raw ACP):

```typescript
// Append to built-in prompt
{ mode: "append", content: "Additional instructions..." }

// Replace entire prompt
{ mode: "replace", content: "Full custom system message" }

// Section-level overrides (v1.0.7+)
{ mode: "customize", content: "..." }
```

⚠️ The raw ACP wire format for system prompt in `session/new` is not publicly
documented. The SDK abstracts this.

---

## Comparison with Claude Code stream-json

| Feature | Claude Code stream-json | ACP (Copilot) |
|:--------|:------------------------|:--------------|
| **Wire protocol** | Custom NDJSON with `type` discriminator | JSON-RPC 2.0 with `method`/`id` |
| **Transport** | stdin/stdout only | stdin/stdout or TCP |
| **Invocation** | `claude -p --input-format stream-json --output-format stream-json` | `copilot --acp` |
| **Turn boundary** | `system.init` at start, `result` at end | `session/prompt` request/response pair |
| **Streaming text** | `assistant` messages + `stream_event` deltas | `session/update` with `agent_message_chunk` |
| **Tool calls** | `assistant` with `tool_use` content block | `session/update` with `tool_call` |
| **Tool results** | `user` echo messages (requires `--verbose`) | `session/update` with `tool_call_update` |
| **Thinking** | `assistant` with `thinking` content block | `session/update` with `agent_thought_chunk` |
| **Token-level streaming** | `stream_event` (requires `--include-partial-messages`) | Chunked `agent_message_chunk` (always on) |
| **Session create** | Implicit (process = session) | Explicit `session/new` request |
| **Session resume** | `--resume ID` flag on new process | `session/load` in same process |
| **Session fork** | `--fork-session` flag | `session/fork` (unstable, ❌ Copilot) |
| **Multi-session** | One session per process | Multiple sessions per process |
| **Cancellation** | `control_request` with `subtype: "interrupt"` | `session/cancel` notification |
| **Permission gate** | `--permission-prompt-tool` MCP delegation | `session/request_permission` JSON-RPC |
| **Auto-approve all** | `--dangerously-skip-permissions` | `--yolo` / `--allow-all-tools` |
| **Model change** | `control_request` with `subtype: "set_model"` | `session/set_config_option` |
| **System prompt** | `--system-prompt` / `--append-system-prompt` flags | SDK `systemMessage` config |
| **MCP config** | `--mcp-config PATH` flag | `--additional-mcp-config` flag |
| **Cost tracking** | `result.total_cost_usd` + `result.usage` | `usage_update` notification (unstable) |
| **Plan/todos** | Not in protocol (agent-internal) | `plan` session update |
| **Mode switching** | `--permission-mode` (static) | `session/set_mode` (dynamic) |
| **Capability negotiation** | None (fixed feature set) | `initialize` handshake |
| **Session storage** | JSONL at `~/.claude/projects/<path>/<id>.jsonl` | JSON at `~/.copilot/session-state/<id>/` |

### Key Architectural Differences

1. **Process model:** Claude Code is one-process-per-session. ACP supports multiple
   sessions per process via explicit session IDs.

2. **Turn tracking:** Claude Code emits `system.init` + `result` as turn
   boundaries. ACP uses the `session/prompt` request/response pair — the response
   itself marks turn completion.

3. **Streaming:** Claude Code has two tiers: `assistant` messages (accumulated
   content blocks) and `stream_event` (token deltas). ACP has one tier:
   `agent_message_chunk` delivers incremental text.

4. **Tool visibility:** Claude Code requires `--verbose` to see tool results.
   ACP always emits `tool_call` and `tool_call_update` — no opt-in needed.

5. **Control plane:** Claude Code uses `control_request`/`control_response` for
   settings changes. ACP uses dedicated RPC methods (`session/set_mode`,
   `session/set_config_option`).

---

## Known Issues

### MCP in ACP mode (Copilot #1040)

MCP servers passed in `session/new` `mcpServers` parameter are not loaded in ACP
mode. Root cause: `copilot --acp` doesn't declare `mcpCapabilities` in its
`agentCapabilities` response. **Status: Open** (March 2026). Workaround: use
`--additional-mcp-config` CLI flag.

### Session fork not implemented (Copilot #2058)

`session/fork` is defined in ACP schema v0.10.0+ as unstable but Copilot does
not implement it. **Status: Open.**

### Live steering limitations

No dedicated `session/steer` method in ACP. The SDK provides `session.send()` with
`mode: "enqueue"` to queue a message for the next turn, but raw ACP clients must
implement their own queuing: buffer the message and send it as the next
`session/prompt` after the current one completes. A non-blocking session-level
queue is an open feature request (Copilot #2025).

### Permission request ID mismatch (Copilot #989, resolved)

Historical bug where permission requests used friendly names instead of actual
`toolCallId` values. Fixed.

### Custom tool injection (Copilot #1574)

Even when MCP tools are passed to `session/new`, the agent cannot see or use them.
Custom JSON-RPC tool methods are ignored in ACP mode. **Status: Open.**

### Auth required for `session/new`

Copilot requires a GitHub token with Copilot-specific permissions. A standard
`gh auth token` PAT does NOT work. Must use a fine-grained PAT with "Copilot
Requests" permission, or `COPILOT_GITHUB_TOKEN` from OAuth device flow.

---

## Session Config Types

### `SessionConfigOption`

Returned in `session/new` and `session/load` responses. Used with
`session/set_config_option` to change settings dynamically.

```typescript
type SessionConfigOption = {
  type: "select";
  currentValue: string;           // Currently selected value ID
  options:
    | SessionConfigSelectOption[]                    // Flat list
    | SessionConfigSelectGroup[];                    // Grouped options
};

type SessionConfigSelectOption = {
  name: string;                   // Display name
  value: string;                  // Value ID (used in set_config_option)
  description?: string;
};

type SessionConfigSelectGroup = {
  group: string;                  // Group ID
  name: string;                   // Group display name
  options: SessionConfigSelectOption[];
};
```

Schema v0.11.1 added boolean toggle config options alongside the existing
select options.

### `SessionModeState`

```typescript
type SessionModeState = {
  availableModes: SessionMode[];
  currentModeId: string;
};

type SessionMode = {
  id: string;
  name: string;
  description?: string;
};
```

---

## Error Handling

Standard JSON-RPC 2.0 error format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Authentication required",
    "data": {}
  }
}
```

### Error Codes

| Code | Name | Meaning |
|:-----|:-----|:--------|
| `-32700` | Parse error | Invalid JSON |
| `-32600` | Invalid request | Not a valid JSON-RPC request |
| `-32601` | Method not found | Unknown method |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Agent internal error |
| `-32000` | Authentication required | ACP-specific: auth needed |
| `-32002` | Resource not found | ACP-specific: e.g., session not found |

---

## Extensibility

### `_meta` Field

All ACP objects support an optional `_meta` field (key-value string object) for
implementation-specific metadata:

```json
{
  "sessionUpdate": "agent_message_chunk",
  "content": {"type": "text", "text": "Hello"},
  "_meta": {"copilot_internal_id": "abc123"}
}
```

### Vendor Extensions

Custom methods use underscore-prefixed names:
- Kiro: `_kiro.dev/commands/execute`, `_kiro.dev/mcp/oauth_request`
- Other agents may add their own `_vendor/method` extensions

Extension requests/responses/notifications are typed as `ExtRequest`,
`ExtResponse`, `ExtNotification` in the schema.

### `$/cancel_request` Notification

Added in schema v0.10.1. Allows cancelling any pending JSON-RPC request by its
`id`, not just session prompts:

```json
{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":42}}
```

---

## Protocol Version History

| Schema | Date | Key Changes |
|:-------|:-----|:------------|
| 0.11.3 | 2026-03-18 | Elicitation types, logout method (unstable) |
| 0.11.2 | 2026-03-11 | `session/stop` → `session/close` rename |
| 0.11.1 | 2026-03-09 | Stabilize `session/list` and `session_info_update`; boolean toggle configs |
| 0.11.0 | 2026-03-04 | `session/stop` (unstable), message IDs, auth methods |
| 0.10.8 | 2026-02-04 | Stabilize session config options; `usage_update` (unstable) |
| 0.10.7 | 2026-01-15 | Fix enum variant schema titles |
| 0.10.6 | 2026-01-09 | Session config categories (unstable); request cancelled error |
| 0.10.5 | 2025-12-17 | Session config options (unstable) |
| 0.10.4 | 2025-12-16 | Config option categories/toggles |
| 0.10.1 | 2025-12-09 | `$/cancel_request` notification |
| 0.10.0 | 2025-12-06 | `session/fork` (unstable) |
| 0.9.0 | 2025-12-01 | `_meta` clarification |
| 0.8.0 | 2025-11-28 | Schema flattening, Rust breaking changes |
| 0.7.0 | 2025-11-25 | Stable/unstable schema split |

**Protocol version** remains `1` (integer) throughout. The schema semver tracks
implementation maturity, not protocol-level breaking changes.

---

## References

- [ACP Protocol Overview](https://agentclientprotocol.com/protocol/overview)
- [ACP Schema](https://agentclientprotocol.com/protocol/schema)
- [ACP Tool Calls](https://agentclientprotocol.com/protocol/tool-calls)
- [ACP Session Fork RFD](https://agentclientprotocol.com/rfds/session-fork)
- [ACP GitHub Repository](https://github.com/agentclientprotocol/agent-client-protocol)
- [ACP CHANGELOG](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/CHANGELOG.md)
- [TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk) (`@agentclientprotocol/sdk` v0.16.1)
- [Python SDK](https://github.com/agentclientprotocol/python-sdk) (`agent-client-protocol`)
- [Rust Crate](https://docs.rs/agent-client-protocol)
- [GitHub Docs: Copilot CLI ACP Server](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server)
- [GitHub Docs: Copilot CLI Reference](https://docs.github.com/en/copilot/reference/cli-command-reference)
- [Copilot CLI DeepWiki: Command-Line Flags](https://deepwiki.com/github/copilot-cli/5.6-command-line-flags-reference)
- [Copilot CLI Releases](https://github.com/github/copilot-cli/releases)
- [ACPex (Elixir) Protocol Overview](https://hexdocs.pm/acpex/protocol_overview.html)
