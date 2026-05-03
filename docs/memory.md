# Project Memory

Project memory is a persistent scratchpad shared across all agents working on a
project. Agents can read it to pick up context from previous sessions and write
to it when they discover something worth preserving for the future.

## What it is

The memory store lives at `<repoPath>/.cydo/memory/`. `MEMORY.md` is the index:
a short file of one-line pointers to topic files under the same directory. The
full contents of `MEMORY.md` are injected into the first user message of every
task. Memory is read once at task start; mid-session writes by the running task
are visible to *future* tasks but not to the writer's own current session.

## File layout

```
.cydo/memory/
  MEMORY.md              ← index; injected into every task
  build_commands.md      ← example topic file
  known_flaky_tests.md   ← example topic file
```

`MEMORY.md` entries look like:

```
- [Build commands](build_commands.md) — nix develop -ic … patterns
- [Flaky tests](known_flaky_tests.md) — tests that fail non-deterministically
```

No frontmatter is required. Topic files can use any format that's useful.

## Update workflow

The preamble (injected into every task's first message) explains when and how
to update memory. In brief: if you discover something durable about how this
project is built, tested, or fails — a non-obvious command, a sandbox quirk, a
stable architectural fact — write it down. Use the absolute path from
`{{memory_dir}}` (shown in the preamble) so the file lands in the canonical
store, not in a per-task worktree directory that gets cleaned up.

## Override the preamble

Projects can override the preamble by placing a file at
`<projectPath>/.cydo/defs/system_prompts/memory_preamble.md`. The override is
picked up by the same search-path overlay that applies to all other CyDo prompt
templates.

## Per-task-type injection control

Memory injection is gated by the `memory: bool` field on each task type
(default `true`). A type with `memory: false` does not receive the memory
preamble; the `.cydo/memory/` directory remains sandbox-writable regardless.
When injection is enabled and `MEMORY.md` is absent, CyDo creates it as an
empty file on the first task that runs. An empty or whitespace-only file
renders the placeholder `(Memory is currently empty.)` instead of a blank block.

## Tracking under git

Projects choose whether to commit `.cydo/memory/` or to `.gitignore` it. CyDo
does not enforce either. Committing it makes memory visible in code review and
preserves it across fresh checkouts; ignoring it keeps it local.
