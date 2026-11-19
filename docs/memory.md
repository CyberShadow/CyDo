# Project Memory

Project memory is a persistent scratchpad shared across all agents working on a
project. Agents can read it to pick up context from previous sessions and write
to it when they discover something worth preserving for the future.

## What it is

The memory store lives at `<repoPath>/.cydo/memory/`. `MEMORY.md` is the index:
a short file of one-line pointers to topic files under the same directory. The
full contents of `MEMORY.md` are injected into the first user message of each
task whose type opts in (see "Per-task-type injection control" below). Memory
is read once at task start; mid-session writes by the running task are visible
to *future* tasks but not to the writer's own current session.

## File layout

```
.cydo/memory/
  MEMORY.md              ← index; injected into tasks that opt in
  build_commands.md      ← example topic file
  known_flaky_tests.md   ← example topic file
```

`MEMORY.md` entries look like:

```
- [Build commands](build_commands.md) — nix develop -ic … patterns
- [Flaky tests](known_flaky_tests.md) — tests that fail non-deterministically
```

Each line is short and carries the fact itself where it fits: every task that
receives memory pays for the whole index, and most never open a topic file.
No frontmatter is required. A topic file covers one subject, in any format
that's useful.

## Update workflow

The preamble (injected along with the index) explains how to read and update
memory. In brief:

- **Read with suspicion.** A note is a claim from when it was written; check
  that a command or path still exists before relying on it, and correct or
  delete a note that proved wrong.
- **Write what changes a future task.** A non-obvious command, a sandbox
  quirk, a stable architectural fact, a correction the user gave. Not the
  state or verdict of the current task, not what the repository already says,
  not line numbers or commit hashes, not facts about another project.
- **Update before adding.** Edit the existing note on a subject rather than
  writing a second one beside it, and keep its index line in step.

Use the absolute path from `{{memory_dir}}` (shown in the preamble) so the
file lands in the canonical store, not in a per-task worktree directory that
gets cleaned up.

Nothing prunes the store automatically or limits the size of the index; the
guidance above is all that keeps it small.

## Override the preamble

Projects can override the preamble by placing a file at
`<projectPath>/.cydo/defs/system_prompts/memory_preamble.md`. The override is
picked up by the same search-path overlay that applies to all other CyDo prompt
templates.

## Per-task-type injection control

Memory injection is gated by the `memory: bool` field on each task type
(default `false`). Set `memory: true` on a task type to receive the memory
preamble in its first user message. The `.cydo/memory/` directory remains
sandbox-writable for all task types regardless of this flag, via the
`always_rw` carve-out. CyDo always creates and registers the exact canonical
base-repository path `<repoPath>/.cydo/memory/` for every task type, including
when it is beneath an ancestor mask. A mask parent does not suppress this
memory mount. An exact explicit user `ro`, `tmpfs`, `empty_dir`, or
`empty_file` declaration at that memory key conflicts with the mandatory write
requirement and fails launch; compatible exact host-backed declarations join
upward to the required access. When injection is enabled and `MEMORY.md` is
absent, CyDo creates it as an empty file on the first task that runs. An empty
or whitespace-only file renders the placeholder `(Memory is currently empty.)`
instead of a blank block.

In the production config, only the `verify` task type opts into memory
injection. Other types are kept lean by default; add `memory: true` to a
type's definition if it benefits from project context.

## Tracking under git

Projects choose whether to commit `.cydo/memory/` or to `.gitignore` it. CyDo
does not enforce either. Committing it makes memory visible in code review and
preserves it across fresh checkouts; ignoring it keeps it local.
