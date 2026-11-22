# AGENTS.md

This file provides guidance to agents when working with code in this repository.

For a general overview of the project and high-level direction, please see @docs/VISION.md.

## Development Environment

All dependencies (D compiler, Node.js 22, npm, etc.) are provided by Nix.
Use `nix develop -ic` to prefix commands, or enter `nix develop` interactively.

**One-time setup:**
```bash
git config core.hooksPath .githooks   # Gate updates of master on nix flake check
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
nix eval .#checks.x86_64-linux --apply builtins.attrNames   # List individual checks
nix build -L .#checks.x86_64-linux.{unittests,typecheck}    # Run selected checks
nix develop -ic env -C tests playwright ...        # Invoke Playwright directly
```

Besides the e2e tests, the checks are `unittests`, `frontend-unit-tests`,
`typecheck`, `lint`, `lint-css`, `format`, `protocol-types-fresh`,
`tool-descriptions` and `sandbox-init`. Each e2e test is its own check, named
`e2e-<project>-<spec>-L<line>` (`<project>` is `claude`, `codex`, `copilot`
or `failure`), so a spec or a single test can be run on its own. Checks build
from the git-tracked tree: `git add` new files before running them.

**Testing policy:**

- **The tip of master must always pass `nix flake check`.** Only the integrator
  lands work on master, and it runs the full `nix flake check` on the exact
  tree it lands. It sends work back when the checks fail. The
  `reference-transaction` hook in `.githooks` rejects any update of master
  to a commit whose checks have not all been built.
- **Everyone else runs the checks relevant to their change**, not the full
  suite: the unit tests, typecheck and linters for the code they touched, and
  the e2e specs that exercise the affected area. Use judgment — a protocol or
  driver change can affect e2e tests in every agent project, so run those
  too. Do not submit work you know to be broken.
- **Every commit on master should be green**, so that history stays
  bisectable. When a test failure is traced to a commit in your branch, fold
  the fix into that commit (`git commit --fixup=<commit>` then
  `git rebase --autosquash`) instead of adding a separate "fix tests" commit
  on top. The same applies to work sent back by the integrator.
- If a test fails and the failure looks flaky (non-deterministic, unrelated to
  the change), retry it. If it fails consistently, treat it as a real
  regression. For the full suite, retry with
  `nix --option keep-going true flake check`.

**Formatting:**
```bash
cd web && npm run fmt   # Run prettier on frontend sources
```

## Commit Messages

- Prefer `type(scope): imperative summary` in lowercase when a conventional
  type fits, for example `fix(codex): align mock text streaming with current
  protocol`.
- Choose a conventional type that best matches the change instead of inventing
  alternate subject formats.
- Keep the subject concise, imperative, and without a trailing period.
- Leave a blank line before the body. Use the body to explain what changed and
  why, and wrap it at roughly 72 columns.
- Split unrelated changes into separate commits instead of combining them under
  one message.

Tests are Playwright e2e specs (`tests/e2e/`) that run against a mock LLM API server (`tests/mock-api/server.mjs`).

## Architecture

CyDo wraps Claude Code CLI (`claude --input-format stream-json --output-format stream-json`) and other agentic coding software (Codex, Copilot) in a web UI with WebSocket-based real-time streaming, multi-session management, and SQLite persistence.

### Backend (D + ae library)

Single-threaded async event loop (`ae.net.asockets.socketManager`). Serves HTTP on port 3940.

- `source/cydo/app.d` — Entry point: HTTP server, WebSocket handler, session routing, message broadcasting
- `source/cydo/agent/claude.d` — Spawns `claude` CLI process, formats NDJSON input, handles output stream
- `source/cydo/agent/process.d` — Wraps posix pipes/signals, async I/O via `FileConnection`/`Duplex`/`LineBufferedAdapter`
- `source/cydo/agent/session.d` — `AgentSession` interface (sendMessage, interrupt, stop, callbacks)
- `source/cydo/storage/persistence.d` — SQLite persistence (sessions table, session history loading from Claude's JSONL files)

Key ae modules used: `ae.net.http.*`, `ae.net.asockets`, `ae.sys.process`, `ae.sys.database`, `ae.utils.json`.

### Frontend (TypeScript + Preact + Vite)

All source in `web/src/`. Pure functional components with hooks.

- `useSessionManager.ts` — Central custom hook: WebSocket connection, session state map, message dispatch
- `sessionReducer.ts` — Pure reducers for processing Claude output into display state
- Protocol DTOs are authored in `source/cydo/protocol/package.d`, generated into `web/src/generated/protocol.ts`, and assembled into the frontend event union in `protocol.ts`
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
