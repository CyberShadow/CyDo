<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-banner-dark.webp">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-banner-light.webp">
    <img alt="CyDo — UI and orchestration for AI coding agents" src="docs/logo-banner-dark.webp" width="520">
  </picture>
</p>

<p align="center">
  <em>UI and orchestration for AI coding agents</em>
</p>

---

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/main-page.png" alt="Welcome page with project overview and active sessions" width="800">
</p>

## What is this?

CyDo provides a browser-based control plane for running multiple AI coding agents in parallel. Instead of interacting with one agent at a time in a terminal, you get:

- **An enhanced experience with your existing subscription** — CyDo wraps the official agent CLIs (Claude Code, Codex, Copilot) rather than replacing them. This means:

  - **No API key required** — use your existing Claude Code, Codex, or Copilot subscription as-is.
  - **No account risk** — CyDo runs the real, unmodified agent binaries. It doesn't impersonate official software or make direct API calls on your behalf, so there's no risk of violating terms of service.
  - **Always up to date** — when the underlying CLI updates, you get new features and fixes automatically. CyDo talks to the agent over its documented streaming protocol, not internal APIs.

- **Multi-session management** — Run multiple agent sessions concurrently from a single interface. A sidebar lets you easily switch between sessions, see their status, and steer any of them in real time.

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/conversation.png" alt="Conversation view with live streaming, suggestions, and task sidebar" width="800">
</p>

- **Simple model** — One issue = one task = one session = one Git worktree. No learning curve - you will be productive right away.

- **Agentic workflows** — CyDo comes pre-configured with a set of single-purpose tasks. The agentic flow diagnoses bugs, creates reproducers, carefully plans out large changes, runs spikes to confirm experiments, decomposes large plans, reviews and verifies implementation outputs automatically. Everything is fully observable, and sub-tasks are directly steerable.

  - **Not interested?** No problem: the blank, direct, and isolated task types provide a more classic experience.
  - **Not satisfied?** Everything is defined using a YAML-driven task type system; customize or replace at your leisure.

- **Sandbox isolation** — Agent sessions run inside [bubblewrap](https://github.com/containers/bubblewrap) sandboxes with configurable read-only and read-write filesystem paths. Agents can't escape their workspace.

- **Git worktree isolation** — Tasks that produce code changes run in their own git worktrees. Changes stay isolated until explicitly pulled into the main tree, so parallel agents never conflict.

- **Rich rendering** — Syntax-highlighted code blocks (via Shiki), ANSI color rendering for terminal output, Markdown with Mermaid diagrams, and structured tool call display.

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/tool-calls.png" alt="Tool calls: file edits, bash commands, and search results" width="800">
</p>

- **Inline file viewer** — View file contents and diffs directly in the conversation without leaving the UI.

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/file-viewer.png" alt="Inline file viewer with syntax-highlighted diff" width="800">
</p>

- **Cross-session search** — Find tasks across all workspaces and sessions.

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/search.png" alt="Search popup with results across workspaces" width="800">
</p>

- **No lock-in** — CyDo sessions are regular terminal sessions, and are stored in the agent's native format. Sessions you create in CyDo show up in the official CLI, and CLI sessions can be imported into CyDo. Use both interchangeably.

- **Resilient** — Backend restarts preserve all sessions. In-progress working agents are resumed automatically. Message and task drafts are persisted server-side, and synced across all clients. The UI reconnects automatically, and picks up where you left off.

- **Multi-agent support** — Not locked to a single AI provider. Supports Claude Code, OpenAI Codex, and GitHub Copilot CLI as agent backends, selectable per workspace or task.

- **Mobile-friendly** — Responsive layout with a slide-out sidebar for use on phones and tablets.

<p align="center">
  <img src="https://files.cy.md/CyDo/docs/screenshots/mobile-conversation.png" alt="Mobile conversation view" height="400">
  &nbsp;&nbsp;
  <img src="https://files.cy.md/CyDo/docs/screenshots/mobile-sidebar.png" alt="Mobile sidebar with task tree" height="400">
</p>

- **Thoroughly tested** — CyDo's integration test suite runs against the real software (the official, unmodified Claude Code / Codex / Copilot binaries), mocking only the AI inference API servers.

## Task Type System

CyDo uses a declarative YAML-based task type system (`defs/task-types.yaml`) that defines agent roles, their capabilities, and how work flows between them:

| Role | Purpose |
|------|---------|
| **conversation** | Interactive session — plans, delegates, reviews via sub-agents |
| **plan** | Designs implementation plans by reading the codebase |
| **implement** | Executes a plan in an isolated worktree, produces a commit |
| **triage** | Decides whether to implement directly or decompose into sub-tasks |
| **verify** | Adversarial testing — tries to break the implementation |
| **review** | Code review against the original plan |
| **spike** | Prototype in a disposable worktree to test feasibility |
| **bug** | Investigate and diagnose a bug report |
| **reproduce** | Create a minimal bug reproducer for fail-first development |

Task types control which sub-tasks an agent can create, what model class to use, whether the session is read-only, and what output it produces. Continuations define state machine transitions between types.

Task type definitions are customizable and extensible with per-project or global personal overrides.

## Support Matrix

### Agent support

| Agent                                                         | Status          |
|---------------------------------------------------------------|-----------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Fully supported |
| [OpenAI Codex CLI](https://github.com/openai/codex)           | Fully supported |
| [GitHub Copilot CLI](https://github.com/github/copilot-cli)   | Experimental    |
| [OpenCode](https://github.com/sst/opencode)                   | Planned         |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli)     | Planned         |

### OS support

| Platform    | Status          |
|-------------|-----------------|
| Linux / WSL | Fully supported |
| Windows     | Planned         |
| macOS       | Planned         |

## Running

### Via Nix (recommended)

1. Install Nix, e.g. using the [Determinate Nix Installer](https://determinate.systems/nix-installer/).
2. Run: `nix run github:CyberShadow/CyDo`.

### From source

1. Install prerequisites:

   - A [D compiler](https://dlang.org/download.html)
   - The [Dub Package Manager](https://dub.pm/), if it was not included with your D compiler
   - Node.js and npm

2. Clone this repository:

   ```bash
   git clone https://github.com/CyberShadow/CyDo.git
   cd CyDo
   ```

3. Build the back-end:

   ```bash
   dub build
   ```

4. Build the front-end:

   ```bash
   cd web
   npm ci
   npm run build
   ```

5. Run the back-end:

   ```bash
   cd ..
   build/cydo
   ```

### Development setup

```bash
# Enter the dev shell (provides D compiler, Node.js 22, npm, etc.)
nix develop

# One-time: enable pre-commit hooks
git config core.hooksPath .githooks

# Build and run the backend (serves on http://localhost:3940)
dub run

# In another terminal — install frontend deps and build
cd web
npm ci
npm run build

# Or for frontend development with hot reload:
npm run dev

# Run all tests
nix flake check
```

## Configuration

CyDo reads its configuration from `~/.config/cydo/config.yaml`:

```yaml
# Which agent backend to use by default
default_agent_type: claude

# Workspace definitions — CyDo discovers projects under these roots
workspaces:
  my-projects:
    root: ~/projects

# Sandbox configuration (optional)
sandbox:
  paths:
    /nix: ro           # Read-only system paths
    ~/projects: rw     # Read-write workspace
  env:
    PATH: "..."        # Environment for sandboxed agents
```

## Project Status

CyDo is under active development. The current implementation covers phases 1-9 of the [roadmap](docs/VISION.md):

- [x] Web UI with real-time streaming
- [x] Multi-session management
- [x] SQLite persistence
- [x] Workspace discovery and bubblewrap sandboxing
- [x] Custom MCP tools for sub-task creation
- [x] YAML-driven task type system
- [x] Git worktree isolation
- [x] Continuations (automatic successor task spawning)
- [x] Inter-task communication (child-parent clarification)
- [ ] Steward review agents
- [ ] Merge train (CI queue with conflict handling)

## License

TBD.
