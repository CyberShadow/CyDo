# Task Type System

Task types define agent behavior, capabilities, and flow control. Each task
type is a template that determines how an agent approaches work, what tools it
has, and what happens when it finishes.

Concrete definitions are in [task-types.yaml](../defs/task-types.yaml).

Use the [commented task-type template](../source/cydo/cli/init_templates/task-types.yaml)
for the full option reference and a walkthrough for defining a type. The
packaged definitions are the starting point for project and user overrides.

## Configuration packs

A pack groups a task-type overlay with its prompt files. Put each pack in
its own directory under `~/.config/cydo/packs/` for all projects or under
`<project>/.cydo/packs/` for one project. Each pack can contain any of
these paths:

```text
<pack>/
  task-types.yaml
  prompts/
  system_prompts/
```

Prompt-only and YAML-only packs are both valid. Each directory in
`packs/` is active. Move it out of `packs/` or remove it to deactivate
it. To activate a pack shipped under `defs/packs/`, copy or symlink its
directory into `~/.config/cydo/packs/`.

CyDo merges YAML from lowest to highest precedence in this order:

1. Shipped `defs/task-types.yaml`
2. User packs, in lexical directory-name order
3. `~/.config/cydo/task-types.yaml`
4. Project packs, in lexical directory-name order
5. `<project>/.cydo/task-types.yaml`

Mappings merge by key. Later values override earlier scalars and
sequences. Prefix pack names with numbers such as `10-` and `20-` to
control their relative order. CyDo logs the YAML layer order and prompt
search path on a successful load. If a layer prevents loading, CyDo logs
a warning and keeps the last successfully loaded configuration for that
project.

`cydo dot`, `cydo dump-context`, `cydo simulate`, and `cydo export-html`
read the same layers as the server and print the load order to stderr.
They use the Git root of the current directory as the project by default.
Pass `--project <path>` to select an existing directory explicitly. Outside
a Git checkout, the commands load only shipped and user layers unless
`--project` is supplied.

### Automatic reload

CyDo watches the user `config.yaml`, `task-types.yaml`, and `packs/`.
For each known project it watches `.cydo/task-types.yaml`, `.cydo/packs/`,
and the `.cydo/defs` entry. It also watches each pack's `task-types.yaml`.
User task-type changes reload every project. Project changes reload the
affected project.

The user configuration files and `packs/`, a project's `.cydo` and its
`task-types.yaml` and `packs/` entries, each pack directory, and its
`task-types.yaml` may be symlinks or chains of up to 40 symlinks.
CyDo detects creating, removing, renaming, or retargeting a link in the
chain. It also detects creation, removal, renaming, or replacement at the
final target path, and writes to a watched target file.

Changes to an ancestor or intermediate component of a link's target path
are picked up on the next re-scan triggered by a watched event, or on
restart. In particular, replacing a directory reached through a symlink
target ending in `/..` requires another watched event or a restart.
The same applies to moving or deleting a project root or
`~/.config/cydo`, and to retargeting `~/.config/cydo` itself if it is a
symlink.

CyDo logs a warning when it cannot watch a directory. Changes inside it
are missed until its permissions or its entry in a watched parent change.
CyDo watches the `.cydo/defs` entry for presence. It reads prompt files
when they are used.

### Disabling definitions

Task types, `creatable_tasks` entries, `creatable_entry_points` entries,
`continuations` entries,
`on_yield`, and `user_entry_points` entries support a boolean `enabled`
field that defaults to `true`. Set it to `false` in an overlay to remove
the entry. A higher layer can set it back to `true` to restore the
merged definition.

CyDo checks that `enabled` is a boolean and rejects unknown keys at the
top level of a disabled definition. Its other fields use their defaults
without validation. CyDo checks enabled entries in full, including routes
whose target type is disabled.

Disabling a task type also removes every creatable task, continuation,
`on_yield`, and entry point that targets it. An edge to a name that was
never defined still produces an unknown-type warning. The `blank` type
and entry point must stay enabled. If you disable the integrator's
target type, also set `singletons.integrator.task_type` to `""` to turn
off the singleton, or point it at an available type. A singleton
targeting a disabled type causes a load error.

Generated guidance follows the remaining edges. Override any handwritten
prompts that name a type your pack disables. Existing tasks keep their
stored type and session history and can still send messages or resume
their sessions. Subsequent lookups skip type-specific behavior when the
definition is missing, including prompt wrapping, the model override on
session launch, and automatic continuation on yield.

In task-type YAML, only `agent` and `model_class` are templates. The
choice of prompt file, `enabled`, and the workflow edges are fixed for
the merged configuration. Use separate packs for setups that need
different wording for different model families.

## Prompt Templates

Every prompt CyDo sends is a [Jinja](https://jinja.palletsprojects.com/)
template under `prompts/` or `system_prompts/`. CyDo takes the first
matching file in this search order:

1. `<project>/.cydo/defs/`
2. Project pack directories, in reverse lexical order
3. `~/.config/cydo/defs/`
4. User pack directories, in reverse lexical order
5. Shipped `defs/`

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
are hidden on the new-task page. CyDo does not flag a singleton for attention
when its turn ends.
After a restart, an idle singleton with no work to recover stays stopped
until its next request resumes the same session.

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

## Creating user tasks

A task type can list named user entry points under
`creatable_entry_points`. Each edge can override the entry point's
description in the CreateTask tool. Disabling an entry point also
removes edges that target it. At most one enabled edge per task type can
set `default: true`. A pack overlay that moves the default between
enabled edges must set `default: false` on the old edge and
`default: true` on the new edge. CyDo ships with `agentic` as the
default edge for `conversation`.

CreateTask creates an independent top-level task. It defaults to a
draft in the caller's project. If the call omits `entry_point`,
CreateTask uses the caller's edge marked `(default)` in the tool
description. If the caller has no default edge, `entry_point` is
required. The selected entry point must exist in the target project.
The target workspace supplies the default agent. The tool can start
a task immediately only in the caller's workspace.

CyDo records the creator in `creator_tid` and links to that task from
the created task's header.

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

## Unsandboxed Commands

Set `unsandboxed_command_execution` to control the `UnsandboxedCommand` tool,
which runs a command in the user's shell on the host, outside the sandbox:

- `no` omits the tool, and calls are rejected.
- `ask` offers it, and the user must approve each call.
- `yes` offers it, and calls run without approval.

The field accepts a Djinja expression with `task_type` and `interactive`. It
defaults to `ask` for interactive task types and `no` for sub-agents. Operator
config can override it in the shared, agent, and workspace sandbox settings, in
that order; there the expression also sees `default`, the task type's verdict.

The sandbox and this verdict guard against accidental host damage, such as an
agent deleting the wrong directory. They do not form a trust boundary against
a malicious agent. `yes` therefore makes sense on a trusted local setup, for
task types that routinely need host tooling the sandbox blocks (nix builds,
system package queries, talking to local services), where per-call prompts
would only cause approval fatigue. Keep `ask` or `no` when working on untrusted
repositories or prompts, or on a shared machine.

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
