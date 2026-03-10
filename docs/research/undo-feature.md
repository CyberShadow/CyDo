# Undo Feature: Protocol Support and Implementation Research

Research into Claude Code protocol capabilities for implementing undo in CyDo.
Undo has two axes: **conversation history rollback** (truncating messages) and
**file change revert** (restoring filesystem state).

## Executive Summary

Claude Code provides all the building blocks needed:

- **File revert (running session):** `rewind_files` control_request sent over
  stdin reverts file changes without killing the process.
- **File revert (cold session):** `--rewind-files <uuid>` hidden CLI flag, or
  manual restore from `~/.claude/file-history/` backups.
- **Conversation rollback (cold):** JSONL truncation at a target UUID (already
  implemented as `forkTask()` in `persist.d`).
- **Conversation rollback (running):** No protocol support — must stop the
  process, truncate JSONL, and resume.

---

## 1. File Change Tracking: `file-history-snapshot`

Claude Code maintains per-session file backups via a checkpointing system.

### Backup storage

Location: `~/.claude/file-history/<session-uuid>/<hash>@v<N>`

- `<hash>` = first 16 hex digits of SHA256(absolute file path, UTF-8)
- Each backup is a **full copy** of the file at that version
- Verification: `hashlib.sha256('/path/to/file'.encode()).hexdigest()[:16]`

### JSONL representation

Snapshots appear as standalone `file-history-snapshot` records in the session
JSONL (no `uuid` field — not part of the linked list):

```json
{
  "type": "file-history-snapshot",
  "messageId": "<uuid-of-associated-record>",
  "snapshot": {
    "messageId": "<uuid-of-last-checkpoint>",
    "trackedFileBackups": {
      "/absolute/path/to/file.d": {
        "backupFileName": "4379aec066020ff5@v2",
        "version": 2,
        "backupTime": "2026-03-07T14:00:05.746Z"
      },
      "relative/path/new-file.ts": {
        "backupFileName": null,
        "version": 1,
        "backupTime": "2026-03-07T14:21:42.905Z"
      }
    },
    "timestamp": "2026-03-07T14:00:05.744Z"
  },
  "isSnapshotUpdate": false
}
```

### Two snapshot modes

| `isSnapshotUpdate` | Meaning | Outer `messageId` | Inner `snapshot.messageId` |
|---|---|---|---|
| `false` | **Turn boundary checkpoint.** Full snapshot of all tracked files. | UUID of the next user message (turn start) | Same as outer (this IS the checkpoint) |
| `true` | **Incremental update.** A file was first touched or modified. | UUID of the assistant record that triggered the edit | UUID of the last turn-boundary checkpoint |

### File version semantics

| State | `version` | `backupFileName` | Meaning |
|---|---|---|---|
| New file | 1 | `null` | Created by the agent; no pre-existing content to back up |
| First edit of existing file | 1 | `<hash>@v1` | v1 backup contains the original pre-session content |
| Nth edit | N | `<hash>@vN` | Backup contains file content just before the Nth edit |

### Availability caveat

`file-history-snapshot` records are **not guaranteed** in all sessions. Observed
in ~50% of CyDo sessions with Edit/Write tools. Presence correlates with:
- File checkpointing being enabled (default: `true` in settings)
- Not disabled via `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING` env var

The feature guard in Claude Code:
```javascript
function AM() {
  return W$().fileCheckpointingEnabled !== false
    && !CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING;
}
```

### Not forwarded to WebSocket

`file-history-snapshot` records exist **only in JSONL files** — the CyDo backend
never sends them over the WebSocket live stream. The frontend reducer at
`sessionReducer.ts:875-882` intentionally filters them out. To use snapshots for
undo, the backend must read JSONL or `~/.claude/file-history/` directly.

---

## 2. `rewind_files` Control Request (Running Session)

The stream-json input protocol supports rewinding file changes on a running
process without killing it.

### Request

```json
{
  "type": "control_request",
  "request_id": "<uuid>",
  "request": {
    "subtype": "rewind_files",
    "user_message_id": "<user-turn-uuid>",
    "dry_run": false
  }
}
```

- `user_message_id`: UUID of the user message to rewind to. Files are restored
  to their state at the start of that user turn.
- `dry_run`: When `true`, reports what would change without modifying files.

### Response

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "<uuid>",
    "response": {
      "canRewind": true,
      "filesChanged": ["path/to/file.ts", "path/to/other.d"],
      "insertions": 42,
      "deletions": 10
    }
  }
}
```

When `canRewind` is `false`:
```json
{
  "response": {
    "canRewind": false,
    "error": "No file history snapshot found for this message"
  }
}
```

### Requirements

- File checkpointing must be enabled (default)
- The target `user_message_id` must correspond to a `file-history-snapshot`
  with `isSnapshotUpdate: false`
- Backup files must exist in `~/.claude/file-history/<session-uuid>/`

### CyDo integration

Currently not implemented. `source/cydo/agent/claude.d` only sends `interrupt`
control_requests. Adding `rewind_files` requires:
1. New method on `AgentSession` interface
2. Backend handler for a new WebSocket command
3. Request/response plumbing through the control_request protocol

---

## 3. Hidden CLI Flags

Found via binary string analysis of Claude Code v2.1.56. These flags have
`.hideHelp()` and do not appear in `claude --help`.

### `--rewind-files <user-message-id>`

Restores files to state at the specified user message UUID and exits.
**Requires `--resume`.**

```bash
claude --resume <session-id> --rewind-files <user-message-uuid>
```

Useful for cold sessions (no running process). Equivalent to sending the
`rewind_files` control_request but as a one-shot CLI invocation.

### `--resume-session-at <message-id>`

When resuming, only include messages up to and including the specified assistant
message ID. Works with `--resume` in print mode. Controls which messages are
sent to the model (API-level truncation) rather than modifying the JSONL file.

Potentially useful for the "interrogation" feature (fork + replay to a specific
point). May be more reliable than JSONL truncation for controlling what the
model sees without modifying files.

---

## 4. JSONL Message Structure for Conversation Rollback

### Linked list ordering

Every JSONL record (except `file-history-snapshot`) has:

| Field | Purpose |
|---|---|
| `uuid` | Unique identifier for this record (UUID v4) |
| `parentUuid` | UUID of the preceding record (`null` for first message) |
| `timestamp` | ISO 8601 UTC |

Records form a singly-linked list via `parentUuid` → `uuid`, matching line
order in the append-only file.

### Envelope fields

All JSONL records carry additional metadata beyond what appears in the live
stream:

```json
{
  "type": "assistant",
  "uuid": "46bbef80-...",
  "parentUuid": "bc9945ca-...",
  "isSidechain": false,
  "userType": "external",
  "cwd": "/home/vladimir/work/cydo",
  "sessionId": "2f5969c9-...",
  "version": "2.1.56",
  "gitBranch": "master",
  "slug": "elegant-tinkering-zephyr",
  "requestId": "req_011CYosdd8ifbvqwWkv6TbSS",
  "timestamp": "2026-03-07T14:25:35.486Z",
  "message": { ... }
}
```

Additional fields seen across sessions: `logicalParentUuid`, `toolUseID`,
`toolUseResult`, `sourceToolAssistantUUID`, `parentToolUseID`,
`permissionMode`, `planContent`, `isMeta`, `isCompactSummary`,
`compactMetadata`, `durationMs`, `level`, `subtype`,
`isVisibleInTranscriptOnly`, `stopReason`, `hookCount`, `hookErrors`,
`hasOutput`, `preventedContinuation`.

### Message types in JSONL

| Type | Purpose | Has `uuid`? |
|---|---|---|
| `user` | Human messages and tool results | Yes |
| `assistant` | Model responses and tool calls | Yes |
| `progress` | Hook execution, streaming trace | No (has `parentToolUseID`) |
| `system` | Metadata (`turn_duration`, `compact_boundary`, `api_error`) | Varies |
| `file-history-snapshot` | File backup snapshots | No (has `messageId`) |
| `queue-operation` | Task queue bookkeeping | No |

### Turn boundary identification

A new conversation turn starts with a `user` message where `message.content` is
a string (not a list of `tool_result` blocks). `file-history-snapshot` with
`isSnapshotUpdate: false` records appear at turn boundaries.

### Tool call structure in JSONL

**Edit** (inside `assistant.message.content[]`):
```json
{
  "type": "tool_use",
  "id": "toolu_01FqGk2cS3sCHxJpYKDF7QVm",
  "name": "Edit",
  "input": {
    "file_path": "/home/vladimir/work/cydo/source/cydo/app.d",
    "old_string": "void main()\n{\n\tauto app = new App();\n\t...",
    "new_string": "void main(string[] args)\n{\n\timport std.algorithm : canFind;\n\t...",
    "replace_all": false
  },
  "caller": {"type": "direct"}
}
```

**Write** (inside `assistant.message.content[]`):
```json
{
  "type": "tool_use",
  "id": "toolu_011shj7zZq14JJNQGUXSkhtF",
  "name": "Write",
  "input": {
    "file_path": "/home/vladimir/work/cydo/.cydo/tasks/219/output.md",
    "content": "# Full file content here..."
  }
}
```

**Tool results** (inside `user.message.content[]`):
```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01FqGk2cS3sCHxJpYKDF7QVm",
  "content": "The file /home/vladimir/work/cydo/source/cydo/app.d has been updated successfully."
}
```

Tool results contain **only a success/error string** — no before/after diff.
All revert capability relies on the backup system or the `old_string` in Edit
tool inputs.

**Large tool outputs** (>~32KB) are stored externally at
`~/.claude/projects/<proj>/<session-uuid>/tool-results/<shortid>.txt` with a
`<persisted-output>` placeholder in the JSONL.

---

## 5. Undo-Relevant Data in Live Stream vs JSONL

### What's in the live stream (useful for undo)

| Data | Source | Undo relevance |
|---|---|---|
| Edit `old_string`/`new_string` | `assistant.message.content[].input` | Can invert Edit operations directly |
| Write `content` | `assistant.message.content[].input` | New content only; need prior state for revert |
| Bash `command` | `assistant.message.content[].input` | Opaque; no structural before/after |
| `tool_use.id` | `assistant.message.content[].id` | Stable ID linking call to result |
| `uuid` / `parentUuid` | Envelope | Message chain ordering |
| `message.id` | `assistant.message.id` | Groups content blocks of same API response |

### What's JSONL-only (not in live stream)

| Data | Purpose |
|---|---|
| `file-history-snapshot` | File backup references and version history |
| `toolUseResult` (with `stdout`/`stderr`) | Enriched tool result envelope |
| `sourceToolAssistantUUID` | Links tool result back to the assistant that called it |
| `progress` records | Hook execution trace |
| `queue-operation` records | Task queue bookkeeping |

### IDs available for undo anchoring

| ID | Where | Best for |
|---|---|---|
| `tool_use.id` (`toolu_...`) | Both | Targeting a specific tool invocation |
| `uuid` (outer) | Both | Targeting a specific message in the chain |
| `message.id` (`msg_...`) | Both | Grouping content blocks of one API response |
| `parentUuid` | Both | Walking the message chain |
| `requestId` (`req_...`) | Both | Grouping all messages of one API call |

---

## 6. Existing CyDo Infrastructure

### Fork mechanism (`persist.d:190-233`)

`forkTask()` already implements JSONL truncation:
1. Read source JSONL
2. Copy lines up to and including `after_uuid`, rewriting `sessionId`
3. Write new JSONL with a fresh UUID
4. Create a new DB row with `relation_type="fork"`, `status="completed"`
5. Return `ForkResult{tid, claudeSessionId}`

This is **non-destructive** — the original session is untouched. The fork must
be explicitly resumed via `claude --resume <new-uuid>`.

### Forkable UUIDs (`persist.d:237-256`)

`extractForkableUuids()` scans JSONL for `user` and `assistant` message UUIDs.
These are sent to the frontend as `forkable_uuids` for the fork UI.

### WebSocket protocol (`app.d`)

Current client→server commands relevant to undo:

| Command | Fields | Purpose |
|---|---|---|
| `fork_task` | `tid`, `after_uuid` | Fork session at a message UUID |
| `interrupt` | `tid` | Graceful protocol interrupt |
| `stop` | `tid` | SIGTERM |
| `resume` | `tid` | Resume stopped session |

No `undo` or `rewind` command exists yet.

### Agent session interface (`session.d`)

`AgentSession` defines: `sendMessage`, `interrupt`, `sigint`, `stop`,
`closeStdin`, and callbacks. No `rewind` or `undo` method exists.

---

## 7. Implementation Approaches

### Approach A: Full undo (files + conversation) on a running session

1. Send `rewind_files` with `dry_run: true` → preview affected files
2. Send `rewind_files` with `dry_run: false` → revert files
3. Stop the process (`stop()`)
4. Truncate JSONL at the target UUID (adapt `forkTask` logic for in-place
   truncation, or fork and swap the task's `claudeSessionId`)
5. Resume with `claude --resume <session-id>`

**Pros:** Clean undo of both axes. Uses Claude's own backup system.
**Cons:** Process restart required for conversation rollback. Brief interruption.

### Approach B: Full undo on a cold session

1. Truncate JSONL at target UUID
2. Resume with `claude --resume <session-id> --rewind-files <target-uuid>`

**Pros:** Single CLI invocation handles both axes.
**Cons:** Only works when no process is running.

### Approach C: File-only undo on a running session

Send `rewind_files` control_request without stopping the process. Conversation
history remains intact — the agent sees the revert as an external filesystem
change on its next tool call.

**Pros:** No process restart. Instant.
**Cons:** Conversation history still contains the undone messages. Agent may
be confused by the discrepancy.

### Approach D: CyDo-native file tracking (no Claude dependency)

Track `(tool_use_id → {file_path, old_content})` in CyDo's memory as the live
stream is processed:
- For Edit: `old_string` is in the tool_use input
- For Write: read file before tool executes (via pre-tool hook or inotify)
- For Bash: rely on git

**Pros:** Independent of Claude's backup system. Works even when
`file-history-snapshot` is absent.
**Cons:** Edit `old_string` is a substring, not the full file — applying the
inverse requires finding it in the current file (fragile if file was modified
since). Write requires pre-read. Bash is opaque.

### Approach E: Git-based file undo

Auto-commit (or stash) at turn boundaries. Undo = `git checkout` to the
commit at the target turn.

**Pros:** Handles all tool types uniformly. Robust.
**Cons:** Requires worktree integration (Phase 7). Git operations add overhead.
Doesn't work for non-git-tracked files.

### Recommended approach

**Approach A for MVP** — it uses existing Claude infrastructure (`rewind_files`)
and extends the existing fork mechanism. The process restart is acceptable since
undo is an infrequent user-initiated action.

For sessions where `file-history-snapshot` is absent, fall back to Approach E
(git-based) when worktrees are available, or Approach D (CyDo-native tracking)
as a last resort.

---

## 8. Gaps and Open Questions

1. **In-place vs fork:** Current `forkTask()` creates a parallel task. True
   undo should rewind the *same* task. Options:
   - Truncate original JSONL directly (destructive but simpler UX)
   - Fork + swap: fork the task, then update the original task's
     `claudeSessionId` to point to the fork

2. **`rewind_files` + conversation truncation atomicity:** If `rewind_files`
   succeeds but JSONL truncation fails (or vice versa), the session is in an
   inconsistent state. Need error handling for partial failures.

3. **Frontend UX:** How does undo appear? Options:
   - "Undo last turn" button (rewinds to the previous user message)
   - Per-message undo (click on any message to rewind to that point)
   - The existing fork button could gain an "undo" variant

4. **`rewind_files` on sessions without snapshots:** The control_request will
   return `canRewind: false`. Need a fallback strategy.

5. **Bash side effects:** File changes made via Bash (e.g., `git commit`,
   `npm install`, `mkdir`) are not captured by `file-history-snapshot` and
   cannot be reverted by `rewind_files`. Git-based undo is the only option.

6. **Multiple undos:** Can the user undo multiple turns in sequence? The
   `rewind_files` mechanism supports rewinding to any turn boundary, not just
   the most recent one. JSONL truncation also supports arbitrary cut points.

7. **`--resume-session-at`:** Could this replace JSONL truncation for
   conversation rollback? It controls the API view without modifying files,
   but its behavior with `--input-format stream-json` needs testing.

---

## References

- [Stream-JSON protocol spec](claude-code-harness/SPEC.md) — full protocol
  documentation including `rewind_files`
- [Session forking research](session-forking.md) — JSONL truncation mechanism
- [JSONL vs stream-json comparison](jsonl-vs-stream-json.md) — format differences
- `source/cydo/persist.d` — existing fork implementation
- `source/cydo/agent/claude.d` — agent process management
- `source/cydo/agent/session.d` — session interface
- `web/src/schemas.ts:498-504` — `FileHistorySnapshotSchema`
- `web/src/sessionReducer.ts:875-882` — snapshot filtering in frontend
