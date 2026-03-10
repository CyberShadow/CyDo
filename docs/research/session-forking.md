# Session Forking via JSONL Truncation

See also: [Undo feature research](undo-feature.md) for how forking combines
with `rewind_files` to implement full undo (files + conversation).

## Findings

Claude Code stores sessions as JSONL files at:
```
~/.claude/projects/<mangled-cwd>/<session-id>.jsonl
```

Where mangled cwd has `/` replaced with `-` (e.g. `-home-vladimir-work-cydo`).

### JSONL Format

Messages form a linked list via `uuid`/`parentUuid`:

```
{"type":"queue-operation","operation":"enqueue","sessionId":"...","content":"..."}
{"type":"queue-operation","operation":"dequeue","sessionId":"..."}
{"type":"user","parentUuid":null,"uuid":"aaa","sessionId":"...","message":{"role":"user","content":"..."}}
{"type":"assistant","parentUuid":"aaa","uuid":"bbb","sessionId":"...","message":{"role":"assistant","content":[{"type":"thinking",...}]}}
{"type":"assistant","parentUuid":"bbb","uuid":"ccc","sessionId":"...","message":{"role":"assistant","content":[{"type":"text",...}]}}
{"type":"queue-operation","operation":"enqueue",...}
{"type":"queue-operation","operation":"dequeue",...}
{"type":"user","parentUuid":"ccc","uuid":"ddd",...}
...
```

Each turn consists of:
1. `queue-operation` (enqueue/dequeue) — bookkeeping
2. `user` message — `parentUuid` points to the last assistant message
3. One or more `assistant` messages — chained via `parentUuid`/`uuid` (thinking block, then text/tool_use block)
4. Optionally `user` with `tool_result` content blocks (tool responses)
5. More `assistant` messages continuing the turn

Every line contains `sessionId` matching the filename.

### CLI Flags

- `--resume <session-id>`: Resume a session by ID. Loads the JSONL and continues.
- `--continue` / `-c`: Resume the most recent session in the current cwd.
- `--fork-session`: When used with `--resume`, creates a new branched session. The original is preserved. Only forks from the **end** of the session — there is no built-in way to fork from a mid-point.

### `isReplay` is Output-Only

Investigated whether we could create a new session and send old messages with `isReplay` set to populate history without triggering inference. Result: **no**. `isReplay` is purely output-side:

- The input protocol only has `{"type":"user",...}` — every message triggers inference
- In the binary, `isReplay` is set when replaying history from a resumed session or echoing stdin via `--replay-user-messages`
- There is no input-side handling that accepts `isReplay`

### Forking from an Arbitrary Point

Since there's no built-in mid-point fork, the approach is JSONL file manipulation:

1. Read the session JSONL file
2. Truncate after the desired message (identified by `uuid`)
3. Generate a new session UUID
4. Write truncated lines to a new file, rewriting `sessionId` in each line
5. `--resume <new-uuid>` to spawn a new process that loads the truncated history

This is non-destructive — the original session file is untouched.

### Implementation Sketch

**Backend:**
- Track `currentSessionId` from `system.init` output
- Handle `{"type":"fork","after_uuid":"<uuid>"}` WebSocket command
- Read + truncate + rewrite JSONL, spawn new session with `--resume`

**Frontend:**
- Track `uuid` on each `DisplayMessage` (from protocol `msg.uuid`)
- Fork button on messages, sends `sendFork(uuid)` via WebSocket
- Handle `{"type":"fork",...}` response: clear UI state, let resumed session replay history

**`ClaudeCodeSession`:**
- Accept optional `resumeSessionId` constructor parameter
- When set, add `"--resume", resumeSessionId` to spawn args
