# Task Type System

Task types define agent behavior, capabilities, and flow control. Each task
type is a template that determines how an agent approaches work, what tools it
has, and what happens when it finishes.

Concrete definitions are in [task-types.yaml](../defs/task-types.yaml).

## Schema

```yaml
name: string                          # unique key (the YAML map key)
description: string                   # human-readable comment
agent_description: string             # LLM-visible; explains when to use this type
prompt_template: string | path        # template used to wrap the task description in the rendered task prompt
system_prompt_template: string | path # optional startup system/developer prompt for agents that support it
model_class: small | medium | large   # maps to haiku / sonnet / opus
read_only: bool                   # sandbox mounts project dir as ro (default false)
output_type: [commit | worktree | report]  # what the task produces (empty = no output)
allow_native_subagents: bool  # use Claude's built-in Task tool instead of CyDo's (default false)

# Flow control
creatable_tasks: string[]             # task types this agent can spawn (modal)
continuations:                        # successors on completion (exec-style)
  <name>:                             # agent picks one on completion
    task_type: string
    requires_approval: bool           # all stewards must approve first

# Execution
serial: bool                          # one at a time, queued (steward pattern)
max_turns: int?                       # resource limit

# Visibility
user_visible: bool                    # can users create this type directly

# Steward
steward: bool                         # registers as an approver
steward_domain: string                # what this steward cares about
knowledge_base: path?                 # persistent state directory
```

## Output Types

- **commit** — A reviewable commit in an isolated worktree. Goes through CI
  and steward review before landing. Enforced: worktree must contain at least
  one commit ahead of its base.
- **worktree** — Working tree changes that the parent may adopt. Used when a
  task produces code changes alongside a report (e.g., spike, reproduce).
  Enforced: worktree must have changes (committed or uncommitted).
- **report** — A text artifact at `<taskDir>/output.md`. Plans, analyses,
  verdicts, investigation reports. Enforced: file must exist and be non-empty.
- **Empty `[]`** — No structured output. Used by interactive types and types
  that modify an inherited worktree (e.g., test).

## Read-Only Mode

When `read_only: true`, the sandbox mounts the project directory as read-only
(`ro` instead of `rw`). The agent keeps all tools — Bash, Write, Edit, etc. —
but filesystem writes to the project tree are denied by the kernel. A writable
`/tmp` is available for scratch work (test programs, temporary files).

This enforces role discipline (plan agents don't accidentally implement, review
agents don't make fixes) while still allowing agents to run commands, compile
code, or write throwaway test programs to verify theories.

A task type is **tree-read-only** if `read_only: true` and every non-forking
descendant type is also read-only. CyDo uses this to enforce worktree safety:
spawning a non-tree-read-only sub-task on a worktree that already has an alive
writer is rejected with an error. Fork edges are always safe (they create an
isolated worktree).

## Flow Control

Two mechanisms for chaining tasks:

**Continuation (exec-style):** The agent completes and declares which successor
should take over. Defined in the task type's `continuations` field. The current
session ends — failures propagate to the parent. Approval gates can block the
successor until stewards approve.

**Modal sub-task (fork+exec-style):** The agent creates sub-tasks via a tool
during execution. The agent's session is suspended and resumed when sub-tasks
complete. The agent sees results and can retry on failure, create more
sub-tasks, or eventually complete (possibly picking a continuation).

The two compose: an agent can do modal work during its lifetime, then use a
continuation when it's truly done.

## Approval

When a continuation has `requires_approval: true`, the system finds all task
types with `steward: true` and creates one approval task per steward. Steward
agents use `approve()` / `reject(reason)` tools to deliver verdicts. All
stewards must approve before the successor spawns.

Adding a steward to a project requires no changes to core workflow definitions —
just add the steward type definition and it's automatically included in all
approval gates.

On rejection: feedback propagates to the caller (the task that completed and
triggered the continuation). The caller's session is resumed with the rejection
context. It can revise and retry, or propagate the failure to its parent.

## Stewards

Stewards are not a special construct — they're task types with `steward: true`.
They have two invocation contexts:

**Approval:** Input is an artifact (plan or patch). Output is a verdict
(approve/reject). Runs in parallel across stewards. Blocks the continuation.

**Upkeep:** Input is a landed diff. The steward updates its knowledge base if
the change is relevant to its domain. Async, no gate.

Both use the same task type and knowledge base. The difference is in the task
description (structured by the system) and available tools (approval has
`approve()`/`reject()`, upkeep doesn't).

The steward's "statefulness" is files in its `knowledge_base` directory. Its
"serial queue" is the `serial: true` flag. Steward knowledge base updates
produce commits that go through steward review themselves.

## Task Lifecycle

```
pending → active → awaiting_approval → completed → (successor spawned)
                 → failed             → rejected  → (caller resumed)
```

## Example Workflows

### Bug fix (small)

```
user creates bug "Login fails with special characters"
  → bug agent investigates, reproduces, identifies fix
  → continuation: small_fix → implement
    → implement agent writes the fix in a worktree
    → continuation: done (requires approval)
      → steward_quality reviews → approve
      → steward_security reviews → approve
      → review agent verifies
      → commit lands via merge train
```

### Feature (needs decomposition)

```
user creates conversation "Add OAuth2 support"
  → conversation agent discusses with user, creates plan sub-task (modal)
    → plan agent produces implementation plan
    → continuation: decompose (requires approval)
      → steward_quality reviews plan → approve
      → steward_security reviews plan → approve
      → decompose agent splits into 3 implement tasks (modal)
        → implement "OAuth2 provider config" (parallel)
        → implement "Token exchange flow" (parallel)
        → implement "Session middleware" (parallel)
        → all complete, each through steward approval
      → decompose reports to conversation
```

### Steward rejection

```
plan agent produces plan
  → continuation: implement (requires approval)
    → steward_quality reviews → reject("Missing error handling")
    → plan agent resumed with rejection feedback
    → plan agent revises
    → continuation: implement (requires approval)
      → all stewards approve
      → implement agent proceeds
```
