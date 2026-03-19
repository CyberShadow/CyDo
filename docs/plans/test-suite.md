# Test Suite Plan for CyDo

## Goal

**`nix flake check`** is the single command that signals "all tests pass." It should be run after every unit of work and before committing. All test infrastructure — mock servers, service startup, Playwright execution — lives inside Nix check derivations so that `nix flake check` is self-contained and reproducible.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  nix flake check (stdenv.mkDerivation)                  │
│                                                         │
│  1. Start mock Anthropic API server  (Node.js, :9000)   │
│  2. Start CyDo backend              (dub binary, :3940) │
│  3. Run Playwright tests            (Chromium)          │
│  4. Kill services, check result                         │
└─────────────────────────────────────────────────────────┘
```

Three components run inside the Nix sandbox derivation:

1. **Mock Anthropic API server** — Node.js HTTP server implementing `POST /v1/messages` with SSE streaming. Simple pattern-matching on input to produce predictable responses.
2. **CyDo backend** — The real `build/cydo` binary, serving HTTP+WebSocket on `:3940`, spawning real Claude Code CLI processes configured to use the mock API.
3. **Playwright** — Browser automation tests via `pkgs.playwright-test`.

**Test isolation:** Each test creates a new task via the WebSocket `create_task` message. Tasks are independent — separate Claude Code subprocess, separate session state. The mock server is stateless (pattern-matches each request independently). All tests run against a single CyDo backend instance within one derivation.

## 1. Mock Anthropic API Server

**Location:** `tests/mock-api/server.mjs`

**What it implements:**
- `POST /v1/messages` — The only required endpoint. Accepts `X-Api-Key` header (any value). Returns SSE stream.
- `GET /api/hello` — Returns `200 OK` (prevents Claude Code connectivity error dialogs).

**Response conventions (pattern-matching on last user message text):**

| Pattern | Response |
|---------|----------|
| `reply with "<text>"` | Text response: `<text>` |
| `create file <path> with content <text>` | Tool call: `Write` tool with `file_path` and `content` |
| `run command <cmd>` | Tool call: `Bash` tool with `command: <cmd>` |
| `read file <path>` | Tool call: `Read` tool with `file_path` |
| After receiving a `tool_result` | Text response: `"Done."` (end_turn) |
| Anything else | Text response: echo the input back |

**SSE streaming format:**

Text-only response:
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_mock_001","type":"message","role":"assistant","content":[],"model":"claude-opus-4-6-20250514","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

event: message_stop
data: {"type":"message_stop"}
```

Tool use response (e.g., Bash tool):
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_mock_002","type":"message","role":"assistant","content":[],"model":"claude-opus-4-6-20250514","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_mock_001","name":"Bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"echo hello\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}
```

After tool_result, the mock always responds with text `"Done."` and `stop_reason: "end_turn"`.

**Implementation:** ~200 lines of Node.js using built-in `http` module (no dependencies). Listens on `$MOCK_API_PORT` (default 9000).

## 2. Claude Code Environment Configuration

Claude Code CLI processes (spawned by CyDo) are configured via environment variables set before launching the CyDo backend (inherited by child processes):

```bash
ANTHROPIC_BASE_URL=http://localhost:9000    # → mock server
ANTHROPIC_API_KEY=test-key-mock             # any non-empty value
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1  # suppress telemetry/statsig/updater
DISABLE_TELEMETRY=1                         # suppress telemetry
CLAUDE_CONFIG_DIR=/tmp/claude-test-home     # isolated from user's ~/.claude
```

Pre-created config at `$CLAUDE_CONFIG_DIR/settings.json`:
```json
{
  "hasCompletedOnboarding": true,
  "theme": "dark",
  "skipDangerousModePermissionPrompt": true,
  "autoUpdates": false
}
```

## 3. Claude Code CLI Packaging

Claude Code CLI is a Bun-compiled single-file binary. Packaged as a **fixed-output derivation** (FOD):

```nix
claude-code = pkgs.stdenv.mkDerivation {
  pname = "claude-code";
  version = "2.1.56";  # pin version

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.56.tgz";
    hash = "sha256-XXXX";  # to be filled
  };

  # npm pack produces a tarball with package/ prefix
  # The actual binary is the Bun-compiled JS bundle
  nativeBuildInputs = [ pkgs.nodejs_22 ];

  installPhase = ''
    mkdir -p $out/bin
    npm install --global --prefix=$out @anthropic-ai/claude-code@${version}
    # or extract and wrap the binary directly
  '';
};
```

Alternative: install via `pkgs.buildNpmPackage` if it's a standard npm package. The exact approach depends on Claude Code's packaging format — may need a spike to determine the cleanest method.

## 4. Nix Integration

**Pattern:** `pkgs.stdenv.mkDerivation` (same as k4system and DFeed).

**flake.nix additions:**

```nix
checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
  integration = pkgs.stdenv.mkDerivation {
    pname = "cydo-integration-test";
    src = ./tests;

    nativeBuildInputs = with pkgs; [
      playwright-test
      nodejs_22
      curl
      self.packages.${system}.default  # cydo binary
      claude-code                       # Claude Code CLI (FOD)
    ];

    FONTCONFIG_FILE = pkgs.makeFontsConf {
      fontDirectories = [ pkgs.liberation_ttf ];
    };
    HOME = "/tmp/playwright-home";

    # Claude Code env
    ANTHROPIC_BASE_URL = "http://localhost:9000";
    ANTHROPIC_API_KEY = "test-key-mock";
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_TELEMETRY = "1";
    CLAUDE_CONFIG_DIR = "/tmp/claude-test-home";

    buildPhase = ''
      # Pre-create Claude config
      mkdir -p $CLAUDE_CONFIG_DIR
      cat > $CLAUDE_CONFIG_DIR/settings.json <<'SETTINGS'
      {"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true,"autoUpdates":false}
      SETTINGS

      # Create workspace directory for CyDo
      mkdir -p /tmp/cydo-test-workspace
      cd /tmp/cydo-test-workspace

      # 1. Start mock API server
      ${pkgs.nodejs_22}/bin/node $src/mock-api/server.mjs &
      MOCK_PID=$!
      for i in $(seq 1 15); do
        if curl -sf http://localhost:9000/api/hello; then break; fi
        if ! kill -0 $MOCK_PID 2>/dev/null; then echo "Mock server died"; exit 1; fi
        sleep 1
      done

      # 2. Start CyDo backend
      cydo &
      CYDO_PID=$!
      for i in $(seq 1 30); do
        if curl -sf http://localhost:3940/; then break; fi
        if ! kill -0 $CYDO_PID 2>/dev/null; then echo "CyDo died"; exit 1; fi
        sleep 1
      done

      # 3. Run Playwright
      set +e
      cd $src
      playwright test --reporter=list
      TEST_RESULT=$?
      set -e

      # 4. Cleanup
      kill $CYDO_PID $MOCK_PID 2>/dev/null
      wait $CYDO_PID $MOCK_PID 2>/dev/null || true

      if [ $TEST_RESULT -ne 0 ]; then
        echo "Tests failed with exit code $TEST_RESULT"
        exit 1
      fi
    '';

    installPhase = ''
      mkdir -p $out
      echo "Tests passed" > $out/result
    '';
  };
};
```

## 5. Test File Structure

```
tests/
├── mock-api/
│   └── server.mjs              # Mock Anthropic API server
├── playwright.config.ts        # Playwright configuration
├── e2e/
│   ├── basic-flow.spec.ts      # Core message flow tests
│   ├── tool-execution.spec.ts  # Tool call rendering and execution
│   ├── session-management.spec.ts  # Create, switch, sidebar
│   ├── session-history.spec.ts # History loading, reconnect, ordering
│   └── task-tree.spec.ts       # Sub-tasks, fork, MCP tools
└── helpers/
    ├── setup.ts                # Global setup: wait for services
    └── ws-client.ts            # WebSocket client for backend-level tests
```

**Playwright config** (`tests/playwright.config.ts`):
```ts
export default defineConfig({
  testDir: './e2e',
  use: {
    baseURL: 'http://localhost:3940',
    headless: true,
    launchOptions: {
      executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined,
    },
  },
  projects: [
    { name: 'default', use: { ...devices['Desktop Chrome'] } },
  ],
});
```

## 6. Proposed Test Cases

### Tier 1: Core Flow (must-have, validates the whole stack works)

1. **Basic message → response** — Send "reply with OK" via the UI input box. Verify "OK" appears in the assistant message bubble.

2. **Tool call flow** — Send "run command echo hello". Verify: tool call block renders with command, tool result shows "hello", final "Done." response appears.

3. **Session creation** — Click "New Task" button. Verify sidebar shows new entry. Verify the session view is active and ready for input.

4. **Session switching** — Create two sessions. Send a message in each. Switch between them. Verify correct message content is shown for each.

5. **Build artifact sanity** — Verify `index.html` in the served page contains hashed asset references (not raw `/src/main.tsx`).

### Tier 2: Session Lifecycle (regression-heavy area from git history)

6. **History survives reconnect** — Send messages, disconnect WebSocket (close tab), reconnect. Verify all messages are present and in order. *(Regression: `8318c99`, `b5834586`)*

7. **No duplicate messages on reconnect** — Same as above but assert message count equals expected count. *(Regression: `a03a60e`, `b5834586`)*

8. **History ordering: file + live** — Start a session, send messages (creates live history), then reconnect while session is still running. Verify file history precedes live history in the message list. *(Regression: `359e4f6`)*

9. **Session stop → history reload** — Stop a session. Verify the conversation is still visible (reloaded from JSONL). *(Regression: `084c4da`)*

10. **Session resume** — Stop a session, then resume it. Send a new message. Verify the session continues with history preserved.

### Tier 3: UI Rendering (regressions from git history)

11. **Sidebar status dots** — Verify: yellow dot while processing, green while alive+idle, faded green when stopped (resumable), red when killed. *(Regression: `8ce973f`, `ad05ef2`)*

12. **Tool result content formats** — Verify tool results render correctly for both string content (`"content": "text"`) and array content (`"content": [{"type":"text","text":"..."}]`). *(Regression: `e9ad104`, `5ca37c0`)*

13. **Sub-agent message nesting** — Trigger a Task tool call (mock returns a tool_use for Task). Verify child messages appear nested under the parent tool call, not in the flat message list. *(Regression: `e9ad104`)*

14. **Auto-scroll on new messages** — When scrolled to bottom, new messages should keep viewport at bottom. When scrolled up, new messages should not disturb scroll position. *(Regression: `2b4670c`)*

### Tier 4: Multi-Session / Multi-Client

15. **Multi-client navigation isolation** — Open two browser tabs. Create a task from tab A. Verify only tab A navigates to the new task; tab B stays on its current view. *(Regression: `f11cf5a`)*

16. **Fork stays focused** — Fork a session from the UI. Verify the forked session stays focused (doesn't auto-navigate back to parent). *(Regression: `c3d93e6`)*

### Tier 5: Edge Cases

17. **rate_limit_event not rendered** — If a `rate_limit_event` arrives, it should not add any visible message to the session view. *(Regression: `9c89aff`)*

18. **Unknown message types** — Send an unrecognized message type via WebSocket. Verify no crash, and a console warning is produced. *(Regression: `8f099e6`)*

19. **Long session input performance** — With 50+ messages rendered, verify typing in the input box is responsive (no forced reflows). *(Regression: `417b365`)*

## 7. Implementation Phases

**Phase 1: Mock API server + basic Playwright test**
- Implement `tests/mock-api/server.mjs` with text-only responses
- Add Playwright config and `basic-flow.spec.ts` (test case #1)
- Package Claude Code CLI as FOD
- Wire into `flake.nix` as a check
- Validate the full stack works end-to-end in `nix flake check`

**Phase 2: Tool call support + session tests**
- Add tool_use SSE streaming to mock server
- Add test cases #2–5
- Add test cases #6–10 (session lifecycle)

**Phase 3: UI regression tests**
- Add test cases #11–14 (rendering)
- Add test cases #15–19 (edge cases)

## Appendix: Research Findings

### Claude Code CLI Startup Requirements

Minimal headless invocation (as spawned by CyDo):
```bash
CLAUDE_CONFIG_DIR=/tmp/claude-test \
ANTHROPIC_API_KEY=test-key \
ANTHROPIC_BASE_URL=http://localhost:9000 \
DISABLE_TELEMETRY=1 \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p \
    --input-format stream-json \
    --output-format stream-json \
    --verbose \
    --permission-mode dontAsk \
    --no-session-persistence \
    --settings '{"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true}'
```

Key env vars:
- `CLAUDE_CONFIG_DIR` — isolate from user's real `~/.claude`
- `ANTHROPIC_BASE_URL` — redirect API calls to mock (read by both Claude Code and embedded Anthropic SDK)
- `ANTHROPIC_API_KEY` — any non-empty string; mock doesn't validate
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — suppress auto-updater, statsig, telemetry
- `CLAUDECODE` must be **unset** when launching from within a Claude session (prevents "cannot launch inside another session" error)

The `-p` (print) mode skips workspace trust dialog and onboarding wizard automatically.

### Anthropic SSE Protocol: Tool Use

Tool_use content blocks are streamed as:
1. `content_block_start` with `type:"tool_use"`, `id:"toolu_..."`, `name`, `input:{}`
2. `content_block_delta` with `delta.type:"input_json_delta"`, `delta.partial_json` (concatenate all to form full input JSON)
3. `content_block_stop`
4. `message_delta` with `stop_reason:"tool_use"` (signals model expects tool result)

Tool results sent as user message with `content: [{type:"tool_result", tool_use_id:"toolu_...", content:"..."}]`.

### Nix Patterns (from btdu, DFeed, k4system)

All three reference projects use `checks.${system}` entries in `flake.nix`:
- `pkgs.stdenv.mkDerivation` for Playwright (DFeed, k4system) — start services in `buildPhase`, poll with `curl`, run playwright, kill, check result
- `pkgs.testers.nixosTest` for VM-level tests (btdu, k4system)
- `pkgs.playwright-test` wraps Playwright with correct Chromium paths
- `FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.liberation_ttf ]; }` required for Chromium
- `HOME = "/tmp/playwright-home"` required
- Mock strategy: application-level flags/config (not network mocking)

### Git History Analysis: Bug Patterns

**Most regression-prone areas** (from analysis of ~170 commits):

1. **Session history ordering/deduplication** — live vs. file history, reconnect duplicates, pending live event buffering (commits: `359e4f6`, `8318c99`, `b5834586`, `a03a60e`)
2. **Streaming message state** — placeholder adoption during batched replay, multi-part message handling (commits: `2cc5000`, `5032189`)
3. **JSONL path handling** — dot replacement, inotify on missing dirs, duplicate watches (commits: `e987536`, `2968d21`, `ce16666`)
4. **Sidebar status logic** — conditional ordering bugs, alive vs status field confusion (commits: `8ce973f`, `ad05ef2`)
5. **Multi-client focus** — broadcast navigation, fork vs sub-task distinction (commits: `f11cf5a`, `c3d93e6`, `79b1de2`)
6. **Tool result rendering** — string vs array content, structured content validation (commits: `e9ad104`, `5ca37c0`, `2585239`)
