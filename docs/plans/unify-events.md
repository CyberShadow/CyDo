# Plan: Unify `event` and `fileEvent` Envelope Fields

## Goal

Eliminate the `fileEvent` envelope field so both live agent output and JSONL
history replay emit `{"tid": N, "event": <AgnosticEvent>}`, unifying the
frontend into a single union type, a single reducer, and a single handler.

## Prerequisites

None. All necessary infrastructure exists.

## Approach

### Key design decisions

**1. No envelope-level history flag needed.**

The original concern was that unifying the envelope field removes the ability
to distinguish history events from live events. However, analysis shows this
discrimination is unnecessary:

- **`alive` flag**: Set by `tasks_list`/`task_updated` control messages from
  the server, not by the handler. The `makeTaskState` call in
  `handleTaskMessage` only fires if the task doesn't yet exist in
  `liveStates`, which it always does (created by `task_created` control
  message). So `alive` is correctly managed regardless of which handler
  processes the event.

- **Buffering**: The existing `handleTaskMessage` buffers events when
  `!historyLoaded && requestedHistory`. After unification, history events
  flowing through this handler will also be buffered, then drained when
  `task_history_end` arrives. This is functionally equivalent to the current
  immediate processing — all history events and `task_history_end` arrive in
  rapid succession from the single-threaded backend, so the delay is
  imperceptible.

- **`preReloadDrafts`**: Requires a reorder in `task_history_end` — drain the
  buffer *before* clearing `preReloadDrafts` (see Changes §2d below).

**2. `pending: true` resolved in the backend.**

During history loading, the steering queue replay state machine (app.d
delegate, lines ~800–890) currently emits synthetic `pending:true` user
messages for enqueued items. These represent steering messages submitted but
not yet processed. In a historical replay, an enqueued message either:
- Gets dequeued later → the dequeue+echo/compaction path already emits a
  confirmed (non-pending) version
- Never gets dequeued (session ended) → the message was abandoned

For the abandoned case, emitting `pending:true` in a historical replay is
misleading — the message isn't actually pending. The change: the enqueue
branch returns `[]` instead of emitting a pending synthetic. The
dequeue/compaction paths are unchanged and continue to emit confirmed messages.

This eliminates `reducePendingUserMessage` from the frontend entirely.
Live pending messages use the separate `unconfirmedUserEvent` envelope
(unaffected by this change).

**3. `system` subtypes handled in the unified reducer.**

The untranslated `"type":"system"` events (`api_error`, `turn_duration`,
`stop_hook_summary`) pass through `translateSystemEvent`'s `default: return
rawLine` catch-all (claude.d:763). Rather than adding backend translation for
these rarely-occurring types, the unified frontend reducer includes a
`"system"` case that preserves the current `reduceFileMessage` behavior:
`stop_hook_summary` → `reduceStopHookSummary`, others → `return s`.

**4. Unified `message/user` handling.**

The two reducers handle `message/user` differently. The unified approach:

```
1. Normalize content (add ?? [] null guard from file reducer)
2. If is_replay: filter out pending user messages from state, then fall
   through to reduceUserEcho (not reduceUserReplay)
3. Else: reduceUserEcho directly
4. After echo: check preReloadDrafts matching (from file reducer)
```

Step 2 combines the "dismiss pending placeholder" behavior of
`reduceUserReplay` with the full flag handling of `reduceUserEcho`. Currently,
`reduceUserReplay` creates a simplified echo missing `isSidechain`,
`isSteering`, etc. flags. By filtering pending messages and then calling
`reduceUserEcho`, both history and live `is_replay` messages get correct flag
handling.

**5. Atomic change — backend and frontend in one commit.**

No migration step needed. The `fileEvent` field disappears entirely.

## Changes

### 1. Backend

#### 1a. `source/cydo/persist.d` (~line 237)

Change the envelope construction from `"fileEvent":` to `"event":`:

```d
// Before:
string injected = format!`{"tid":%d,"fileEvent":`(tid) ~ t ~ `}`;

// After:
string injected = format!`{"tid":%d,"event":`(tid) ~ t ~ `}`;
```

This is the core change. `extractEventFromEnvelope` (task.d:322) searches for
`,"event":` with a comma prefix (to avoid matching `"unconfirmedUserEvent"`).
The history envelope `{"tid":N,"event":...}` matches correctly because `"event"`
follows `"tid":N,`.

#### 1b. `source/cydo/task.d`

- **Remove `extractFileEventFromEnvelope`** (lines ~344–361). No callers
  remain after the other changes.
- **Keep `extractEventFromEnvelope`** unchanged — it now handles both sources.

#### 1c. `source/cydo/app.d` — `buildAbbreviatedHistory` (~line 2631)

Remove the `extractFileEventFromEnvelope` fallback:

```d
// Before:
auto event = extractEventFromEnvelope(envelope);
if (event.length == 0)
    event = extractFileEventFromEnvelope(envelope);

// After:
auto event = extractEventFromEnvelope(envelope);
```

`extractLastAssistantText` (~line 2513) already only uses
`extractEventFromEnvelope` — now correct without changes.

#### 1d. `source/cydo/app.d` — history delegate enqueue branch (~line 800–810)

Stop emitting `pending:true` synthetic events for enqueued steering messages:

```d
// Before (line ~806):
auto synthetic = buildSyntheticUserEvent(op.content, false, true);
synthetic = synthetic[0 .. $ - 1]
    ~ `,"uuid":"enqueue-` ~ format!"%d"(lineNum) ~ `"}`;
return [synthetic];

// After:
return [];   // Dequeue+echo/compaction will emit the confirmed version
```

The `steeringStash` push and `steeringEnqueueLineNums` push on lines ~800–804
must be preserved — they're needed by the dequeue branch.

### 2. Frontend

#### 2a. `web/src/protocol.ts`

Merge `AgnosticFileEvent`-only types into `AgnosticEvent`:

- Add `SystemApiErrorMessage` (type: `"system"`, subtype: `"api_error"`) to
  the `AgnosticEvent` union
- Add `SystemTurnDurationMessage` (type: `"system"`, subtype:
  `"turn_duration"`) to the union
- Add `SystemStopHookSummaryMessage` (type: `"system"`, subtype:
  `"stop_hook_summary"`) — or if not already a named type, define it

Do NOT add `progress`, `queue-operation`, `file-history-snapshot` — these are
already filtered to `null` in the backend's `translateClaudeEvent` (claude.d:
738–741) and never reach the frontend.

- **Delete** the `AgnosticFileEvent` type
- **Delete** the `FileMessage` type
- Keep `TaskMessage` as `{ tid: number; event: AgnosticEvent }`

#### 2b. `web/src/connection.ts`

Remove `onFileMessage` callback and the `"fileEvent"` routing branch:

```typescript
// Before:
onTaskMessage: ((tid: number, msg: AgnosticEvent) => void) | null = null;
onFileMessage: ((tid: number, msg: AgnosticFileEvent) => void) | null = null;
// ... routing:
} else if ("event" in raw) {
  this.onTaskMessage?.(raw.tid, raw.event as AgnosticEvent);
} else if ("fileEvent" in raw) {
  this.onFileMessage?.(raw.tid, raw.fileEvent as AgnosticFileEvent);
}

// After:
onTaskMessage: ((tid: number, msg: AgnosticEvent) => void) | null = null;
// ... routing:
} else if ("event" in raw) {
  this.onTaskMessage?.(raw.tid, raw.event as AgnosticEvent);
}
```

The `"fileEvent"` branch becomes dead code once the backend stops emitting it.
The `console.warn("Unknown task envelope")` else branch catches any mismatches
during development.

#### 2c. `web/src/sessionReducer.ts`

**Merge `reduceFileMessage` into `reduceStdoutMessage`**, then rename the
result to `reduceMessage`. Delete `reduceFileMessage`.

Specific changes to the merged reducer:

**`message/user` case** — combine both branches:
```typescript
case "message/user": {
  const rawContent = (msg as any).content;
  const contentBlocks: any[] =
    typeof rawContent === "string"
      ? [{ type: "text", text: rawContent }]
      : (rawContent ?? []);   // ← add ?? [] null guard from file reducer

  // is_replay: dismiss any pending placeholder, then echo normally
  let state = s;
  if ("is_replay" in msg && (msg as any).is_replay) {
    state = {
      ...state,
      messages: state.messages.filter(
        (m) => !(m.pending && m.type === "user")
      ),
    };
  }

  state = reduceUserEcho(
    state, contentBlocks,
    (msg as any).is_sidechain,
    (msg as any).parent_tool_use_id,
    msg,
    (msg as any).is_synthetic,
    (msg as any).is_meta,
    (msg as any).is_steering,
  );

  // Draft recovery (from file reducer, safe for live — preReloadDrafts
  // is undefined outside history loading, making this a no-op)
  if (state.preReloadDrafts && state.preReloadDrafts.length > 0) {
    const text = contentBlocks
      .filter((b: any) => b.type === "text")
      .map((b: any) => b.text ?? "")
      .join("");
    if (text && state.preReloadDrafts.includes(text)) {
      state = {
        ...state,
        confirmedDuringReplay: [
          ...(state.confirmedDuringReplay ?? []),
          text,
        ],
      };
    }
  }
  return state;
}
```

**Add `"system"` case** (from `reduceFileMessage`):
```typescript
case "system": {
  const subtype = (msg as any).subtype;
  if (subtype === "stop_hook_summary")
    return reduceStopHookSummary(s, msg);
  if (subtype === "api_error" || subtype === "turn_duration")
    return s;
  return reduceParseError(s, msg, "event", "Unknown system subtype");
}
```

**Parse error source tagging**: Change `"stdout"` to `"event"` (or remove the
source parameter entirely). The `"stdout"` vs `"file"` distinction is a minor
debugging convenience that loses meaning after unification.

**Delete** `reduceFileMessage` function entirely.

**Delete** `reducePendingUserMessage` function — no longer called (backend
resolves pending in history, live uses `unconfirmedUserEvent`).

#### 2d. `web/src/useSessionManager.ts`

**Remove `handleFileMessage`** callback and its wiring to
`conn.onFileMessage`.

**Reorder `task_history_end` handler** — drain the buffer BEFORE clearing
`preReloadDrafts`:

```typescript
case "task_history_end": {
  const { tid } = msg;
  let t = liveStates.get(tid);
  if (!t) break;

  // 1. Drain buffered events (history + any interleaved live)
  //    while preReloadDrafts is still set for draft matching
  const buffered = pendingLiveRef.current.get(tid);
  if (buffered) {
    pendingLiveRef.current.delete(tid);
    for (const liveMsg of buffered) {
      const prev = liveStates.get(tid)!;
      const next = reduceMessage(prev, liveMsg);
      liveStates.set(tid, next);
    }
    t = liveStates.get(tid)!;
  }

  // 2. Compute inputDraft from confirmed drafts
  let inputDraft = t.inputDraft;
  if (t.preReloadDrafts && t.preReloadDrafts.length > 0) {
    // ... existing draft computation logic ...
  }

  // 3. Finalize: mark loaded, clear transient state
  t = {
    ...t,
    historyLoaded: true,
    preReloadDrafts: undefined,
    confirmedDuringReplay: undefined,
    inputDraft,
  };
  liveStates.set(tid, t);
  setTasks(...);
  break;
}
```

The key insight: currently history events are processed immediately (via
`handleFileMessage`) with `preReloadDrafts` set, then `task_history_end`
computes `inputDraft` and clears `preReloadDrafts`, then drains the live
buffer. After unification, all events are buffered, so we drain first (with
`preReloadDrafts` still set), then compute and clear. Functionally equivalent.

**Rename `reduceStdoutMessage` references** to `reduceMessage` throughout.

#### 2e. `web/src/schemas.ts` (if present)

Remove any Zod schemas specific to `AgnosticFileEvent` or `FileMessage`. Merge
validation into the unified `AgnosticEvent` schema if Zod validation is used
at the routing layer.

## Verification

1. **`nix flake check`** — all existing e2e tests must pass (the mock API
   server exercises both history loading and live streaming paths)

2. **Manual testing**:
   - Start a new session → live events stream correctly
   - Reload the page → history replays correctly, all messages visible
   - Resume a session with history → history loads, then live events continue
   - Steering messages (enqueue/dequeue) in history → confirmed messages
     appear, no pending placeholders
   - Sessions with `system` events (api_error, stop_hook_summary) in JSONL →
     no parse errors, stop_hook_summary renders correctly

3. **Grep verification**: After the change, confirm:
   - `fileEvent` does not appear in any backend `.d` source files
   - `fileEvent`, `AgnosticFileEvent`, `FileMessage`, `onFileMessage`,
     `handleFileMessage`, `reduceFileMessage`, `reducePendingUserMessage` do
     not appear in any frontend `.ts` source files
   - `extractFileEventFromEnvelope` does not appear anywhere
