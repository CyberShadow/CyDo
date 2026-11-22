# Task Type System

Task types define agent behavior, capabilities, and flow control. Each task
type is a template that determines how an agent approaches work, what tools it
has, and what happens when it finishes.

Concrete definitions are in [task-types.yaml](../defs/task-types.yaml).

Use the [commented task-type template](../source/cydo/cli/init_templates/task-types.yaml)
for the full option reference and a walkthrough for defining a type. The
packaged definitions are the starting point for project and user overrides.

## Prompt Templates

Every prompt CyDo sends is a [Jinja](https://jinja.palletsprojects.com/)
template under `prompts/` or `system_prompts/`. CyDo looks for a template in
three places and takes the first that has it:

1. `<project>/.cydo/defs/`
2. `~/.config/cydo/defs/`
3. the definitions shipped with CyDo

A file higher up replaces the one below it. To add to a prompt instead of
replacing it, write `{{ default }}` where the prompt from further down should
go:

```markdown
{{ default }}

In this project, run `make check` before every commit.
```

`{{ read_file("path") }}` is the text of a file outside these directories,
taken as it is. The path is absolute or starts with `~`:

```markdown
{{ default }}

{{ read_file("~/notes/landing-workflow.md") }}
```

## Singletons

The top-level `singletons:` map in `task-types.yaml` defines named tasks that
CyDo starts on demand. The shipped `integrator` singleton lands finished work
on the main branch.

```yaml
singletons:
  integrator:
    task_type: integrator
    prompt_template: prompts/integrator.md
    title: Integrator
    offered_to: interactive
    description: Lands finished work on the main branch.
```

The name is the address passed to `Request(to, message)`. The prompt template
wraps the singleton's first message and the title labels its task in the
sidebar. The description tells callers what to send and what its answer means.
A project overlay can disable a singleton by setting its `task_type` to `""`.

By default, `offered_to: interactive` gives interactive sessions access.
`offered_to: all` includes sub-tasks as well. A session can request other
singletons, and its own type is excluded. Singleton types are interactive and
keep their sessions open. CyDo starts them through system entry points that
are hidden on the new-task page.

CyDo routes each request to the newest unarchived singleton task in the
caller's project and workspace, starting one if needed. The caller waits
for the singleton's `Answer`. A singleton has no parent: its type's `agent:`
expression sees the workspace's default agent as `parent_agent_type`, so
which task happened to send the first request does not decide its agent.
To replace a singleton, stop and archive its
task. The next request starts a fresh one.

See the [generated task-type template](../source/cydo/cli/init_templates/task-types.yaml)
for the complete example and singleton field reference.

A singleton can receive questions while blocked in a CyDo tool call. Long
work should run in sub-tasks or background commands so it can keep receiving
requests. The integrator follows the project's instructions for checking and
landing work.

## Read-Only Mode

When `read_only: true`, the sandbox mounts the project directory as read-only
(`ro` instead of `rw`). The agent keeps all tools — Bash, Write, Edit, etc. —
but filesystem writes to the project tree are denied by the kernel. A writable
`/tmp` is available for scratch work (test programs, temporary files).

This enforces role discipline (plan agents don't accidentally implement, review
agents don't make fixes) while still allowing agents to run commands, compile
code, or write throwaway test programs to verify theories.

At the sandbox-path level, task read-only is a transform that runs after
declarations and before agent requirements. It changes declared/effective
ordinary `rw` to `ro`, while leaving `always_rw` and masks (`tmpfs`,
`empty_dir`, and `empty_file`) unchanged. Later exact agent, task, Git, MCP,
or memory requirements can restore a task-reduced compatible write or create a
child mount beneath an ancestor mask. Exact hard caps for the base and active
worktrees remain read-only. An exact explicit user `ro` or mask at a mandatory
write key fails with both origins instead of being silently overwritten.

A task type is **tree-read-only** if `read_only: true` and every non-forking
descendant type is also read-only. CyDo uses this to enforce worktree safety:
spawning a non-tree-read-only sub-task on a worktree that already has an alive
writer is rejected with an error. Fork edges are always safe (they create an
isolated worktree).

## Project Memory

Every task type with `memory: true` has the contents of `MEMORY.md`
prepended to its first user message, wrapped by the preamble at
`defs/system_prompts/memory_preamble.md`. The default is `false` — a
task type must explicitly opt in. Memory is read once at task start; a
mid-session write is visible to future tasks, not to the writer's own
current session.

In the production config, only `verify` opts into memory injection.

When injection is enabled and `MEMORY.md` does not yet exist, CyDo
creates it as an empty file on demand. An empty or whitespace-only
`MEMORY.md` renders as the placeholder `(Memory is currently empty.)`
rather than an empty block.

The directory `<repoPath>/.cydo/memory/` is sandbox-writable for all
task types — including those with `memory: false` and read-only ones —
via an `always_rw` carve-out. Worktree-bound tasks reach the canonical
store via the absolute path that the preamble exposes as `{{memory_dir}}`.

See `docs/memory.md` for content conventions.

## Flow Control

A user entry point starts an interactive session. Interactive sessions can
change roles through keep-context continuations while retaining the current
conversation. They can delegate work and remain available to the user.

A child tool starts a separate task with its own prompt. The caller receives
its result and decides whether to retry, delegate more work, or proceed. A
handoff ends the current task and starts a successor. Tasks reachable from a
user entry point through keep-context transitions must remain interactive.

The shipped workflow lets a conversation delegate planning and execution.
Execution can decompose a large request or pass a focused change to an
overseer. The overseer delegates implementation, review, and verification
and feeds objections back to the implementer. See the shipped definitions
for the actual edges and the instructions each task receives.

Steward approval and upkeep are schema concepts. The server does not
schedule stewards or enforce the serial and max_turns settings.
