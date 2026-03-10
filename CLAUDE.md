# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Please see @docs/VISION.md

## Build & Run Commands

```bash
make all          # Build backend + frontend
make backend      # dub build → build/cydo
make frontend     # npm install + vite build in web/
make run          # Build all, then dub run (serves on :3456)
make clean        # Remove build/, web/dist/, web/node_modules/
```

**Development with hot reload:**
- Backend: `dub run` (recompiles and runs)
- Frontend: `cd web && npm run dev` (Vite dev server on :5173, proxies `/ws` to :3456)

**Testing:**
```bash
nix flake check   # Run all tests — the single "all tests pass" command
```
Run `nix flake check` after every unit of work and before committing.

## Architecture

CyDo wraps Claude Code CLI (`claude --input-format stream-json --output-format stream-json`) in a web UI with WebSocket-based real-time streaming, multi-session management, and SQLite persistence.

### Backend (D + ae library)

Single-threaded async event loop (`ae.net.asockets.socketManager`). Serves HTTP on port 3456.

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
