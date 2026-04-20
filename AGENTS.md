# AGENTS.md

This file provides guidance to agents when working with code in this repository.

For a general overview of the project and high-level direction, please see @docs/VISION.md.

## Development Environment

All dependencies (D compiler, Node.js 22, npm, etc.) are provided by Nix.
Use `nix develop -ic` to prefix commands, or enter `nix develop` interactively.

**One-time setup:**
```bash
git config core.hooksPath .githooks   # Enable pre-commit checks
```

**Build & run:**
```bash
nix develop -ic dub build                          # Build backend → build/cydo
nix develop -ic env -C web npm ci                  # Install frontend deps
nix develop -ic env -C web npm run build           # Build frontend → web/dist/
nix develop -ic dub run                            # Build + run backend (serves on :3940)
```

**Production build (sandboxed, no incremental):**
```bash
nix build         # Build the full application
```

**Testing:**
```bash
nix flake check   # Run all tests — the single "all tests pass" command
nix develop -ic env -C tests playwright ...        # Invoke Playwright directly
```

**`nix flake check` is the mandatory gate before handing any work to the user.**
This applies after every unit of work — not just `git commit`, but also
`git commit --amend`, `git rebase`, or any other operation that changes the
tree. No work is considered complete until the full suite passes.

- If a test fails and the failure looks flaky (non-deterministic, unrelated to
  your changes), retry `nix flake check`. If it fails consistently, treat it as
  a real regression and fix it before proceeding.
- **`--no-verify` is BANNED.** Never use it to bypass the pre-commit hook or
  any other check. The `nix flake check` gate is non-negotiable.
- Do not skip or substitute with partial checks.

**Formatting:**
```bash
cd web && npm run fmt   # Run prettier on frontend sources
```

Tests are Playwright e2e specs (`tests/e2e/`) that run against a mock LLM API server (`tests/mock-api/server.mjs`).

## Architecture

CyDo wraps Claude Code CLI (`claude --input-format stream-json --output-format stream-json`) and other agentic coding software (Codex, Copilot) in a web UI with WebSocket-based real-time streaming, multi-session management, and SQLite persistence.

### Backend (D + ae library)

Single-threaded async event loop (`ae.net.asockets.socketManager`). Serves HTTP on port 3940.

- `source/cydo/app.d` — Entry point: HTTP server, WebSocket handler, session routing, message broadcasting
- `source/cydo/agent/claude.d` — Spawns `claude` CLI process, formats NDJSON input, handles output stream
- `source/cydo/agent/process.d` — Wraps posix pipes/signals, async I/O via `FileConnection`/`Duplex`/`LineBufferedAdapter`
- `source/cydo/agent/session.d` — `AgentSession` interface (sendMessage, interrupt, stop, callbacks)
- `source/cydo/persist.d` — SQLite persistence (sessions table, session history loading from Claude's JSONL files)

Key ae modules used: `ae.net.http.*`, `ae.net.asockets`, `ae.sys.process`, `ae.sys.database`, `ae.utils.json`.

### Frontend (TypeScript + Preact + Vite)

All source in `web/src/`. Pure functional components with hooks.

- `useSessionManager.ts` — Central custom hook: WebSocket connection, session state map, message dispatch
- `sessionReducer.ts` — Pure reducers for processing Claude output into display state
- `schemas.ts` — Zod schemas validating Claude Code's stream-json wire protocol
- `connection.ts` — WebSocket client class
- `ansi.ts` — ANSI escape sequence parser for colored Bash output
- `highlight.ts` — Shiki-based syntax highlighting for code blocks
- Components: `SessionView`, `Sidebar`, `MessageList`, `InputBox`, `AssistantMessage`, `UserMessage`, `ToolCall`, `Markdown`, `SystemBanner`

### Message Flow

1. Browser sends WebSocket JSON `{type: "message", sid, content}` to backend
2. Backend writes NDJSON to claude's stdin
3. Claude outputs NDJSON on stdout
4. Backend wraps each line with `{sid, timestamp, event}` envelope and broadcasts to all WebSocket clients
5. Frontend reducers process events into renderable state

### Session Lifecycle

- Sessions tracked in SQLite (`sessions` table: sid, claude_session_id)
- Session history loaded from Claude's own JSONL files at `~/.claude/projects/<path>/<uuid>.jsonl`
- Resume via `claude --resume <uuid>`

### Testing Principles

**Test against real software, not mocks.** Integration tests must exercise the
actual agent binaries (Claude CLI, Codex CLI, Copilot CLI) via the HTTPS proxy
infrastructure in `tests/mock-api/`. Mocks of the agent binary itself are not
acceptable — they mask real integration issues. The proxy intercepts API traffic
(LLM completions, auth, models) while letting the real binary handle protocol
framing, startup, and session management.

**Test real user interactions, not low-level details.** E2e tests should exercise
the full stack (frontend, backend, agent binary, LLM API), rather than narrow
scoped slices. Do not use WebSocket packet injection or agent software mocking.
