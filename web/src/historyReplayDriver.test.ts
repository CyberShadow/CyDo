// Driver identity for tasks whose transcript comes from a history replay.
//
// On a page reload the frontend learns about a task from `tasks_list` /
// `task_updated`, which carry the resolved runtime driver alongside the
// configured agent name, and then replays the stored transcript. A replayed
// Claude transcript contains no `session/init` event (Claude's own JSONL
// session files have no `{"type":"system","subtype":"init"}` line), so the
// driver must already be known from the task listing for tool blocks to get
// Claude-specific rendering.

import { describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});

import { reduceMessage } from "./sessionReducer";
import { qualifiedToolKey } from "./toolIdentity";
import { type TaskState } from "./types";
import bashEditDiff from "./testFixtures/claude-bash-edit-diff.json";
import {
  taskStateFromEntry,
  type TaskSnapshotEntry,
} from "./useSessionManager";

function asEvent(event: object): Parameters<typeof reduceMessage>[1] {
  return event as Parameters<typeof reduceMessage>[1];
}

const BASE_ENTRY: TaskSnapshotEntry = {
  tid: 42,
  child_count: 0,
  alive: false,
  resumable: true,
  isProcessing: false,
  canStop: false,
  needsAttention: false,
  hasPendingQuestion: false,
  title: "Reloaded task",
  workspace: "local",
  project_path: "/tmp/project",
  status: "waiting",
  task_type: "implement",
  entry_point: "agentic",
  agent_name: "claude",
  driver: "claude",
  archived: false,
  archiving: false,
  created_at: 1000,
  last_active: 2000,
};

/** Build the TaskState the way useSessionManager's `tasks_list` /
 *  `task_updated` handlers do when this client has not watched the task
 *  live: feed a snapshot entry (as the backend sends it) through the same
 *  seeding function those handlers call, so the driver comes from the task
 *  listing rather than being hand-set on the TaskState. */
function makeReloadedTask(agentName: string, driver: string): TaskState {
  const entry: TaskSnapshotEntry = {
    ...BASE_ENTRY,
    agent_name: agentName,
    driver,
  };
  return taskStateFromEntry(entry, undefined, undefined);
}

const BASH_STARTED = asEvent({
  type: "item/started",
  item_type: "tool_use",
  item_id: "bash-1",
  name: "Bash",
  input: { command: "ls -la", description: "List files" },
});

const EDIT_STARTED = asEvent({
  type: "item/started",
  item_type: "tool_use",
  item_id: "edit-1",
  name: "Edit",
  input: {
    file_path: "/tmp/project/notes.md",
    old_string: "old",
    new_string: "new",
  },
});

const EDIT_RESULT = asEvent({
  type: "item/result",
  item_id: "edit-1",
  content: [{ type: "text", text: "ok" }],
  is_error: false,
});

const BASH_EDIT_DIFF_RESULT = asEvent({
  type: "item/result",
  item_id: "bash-1",
  content: [{ type: "text", text: "done" }],
  is_error: false,
  tool_result: { bashEditDiff },
});

const SESSION_INIT = asEvent({
  type: "session/init",
  model: "claude-sonnet",
  agent_version: "1.0.0",
  session_id: "sid-42",
  cwd: "/tmp/project",
  tools: [],
  permission_mode: "default",
  agent: "claude",
  agent_name: "claude",
  supports_file_revert: false,
});

describe.each([
  ["claude", "built-in agent name"],
  ["work-claude", "custom configured agent name"],
])("replayed Claude history (no session/init) — %s (%s)", (agentName) => {
  it("qualifies Bash as a Claude built-in", () => {
    const next = reduceMessage(
      makeReloadedTask(agentName, "claude"),
      BASH_STARTED,
    );

    const blockKey = next.itemIdMap.get("bash-1");
    const block = next.blocks.get(blockKey!);
    expect(block).toBeTruthy();
    expect(block?.driver).toBe("claude");
    expect(
      qualifiedToolKey(block!.name!, block!.toolServer, block!.driver),
    ).toBe("claude/Bash");
  });

  it("tracks a Claude Edit as a file edit", () => {
    const started = reduceMessage(
      makeReloadedTask(agentName, "claude"),
      EDIT_STARTED,
    );
    const next = reduceMessage(started, EDIT_RESULT);

    const tracked = next.trackedFiles.get("/tmp/project/notes.md");
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.type).toBe("edit");
    expect(tracked?.edits[0]?.source).toBe("claude-tool");
  });

  it("replays complete Bash edit records identically to a live session", () => {
    const initialized = reduceMessage(
      makeReloadedTask(agentName, "claude"),
      SESSION_INIT,
    );
    const replay = reduceMessage(
      reduceMessage(
        {
          ...makeReloadedTask(agentName, "claude"),
          msgIdCounter: initialized.msgIdCounter,
        },
        BASH_STARTED,
      ),
      BASH_EDIT_DIFF_RESULT,
    );
    const live = reduceMessage(
      reduceMessage(initialized, BASH_STARTED),
      BASH_EDIT_DIFF_RESULT,
    );
    const paths = bashEditDiff.files.map((file) => file.filePath);
    const replayRecords = paths.map(
      (path) => replay.trackedFiles.get(path)?.edits,
    );
    const liveRecords = paths.map((path) => live.trackedFiles.get(path)?.edits);

    expect(replayRecords).toEqual(liveRecords);
    expect(replayRecords).toEqual([
      [
        {
          toolUseId: "bash-1",
          messageId: "streaming-2",
          filePath: bashEditDiff.files[0]!.filePath,
          type: "edit",
          op: "update",
          status: "applied",
          source: "claude-bashEditDiff",
          changeIndex: 0,
          turnId: undefined,
          payload: { mode: "hunks", hunks: bashEditDiff.files[0]!.hunks },
        },
      ],
      [
        {
          toolUseId: "bash-1",
          messageId: "streaming-2",
          filePath: bashEditDiff.files[1]!.filePath,
          type: "edit",
          op: "update",
          status: "applied",
          source: "claude-bashEditDiff",
          changeIndex: 1,
          turnId: undefined,
          payload: { mode: "hunks", hunks: bashEditDiff.files[1]!.hunks },
        },
      ],
    ]);
  });
});

describe("task_updated merge path", () => {
  it("adopts the driver from a later snapshot entry (task_created, then task_updated)", () => {
    // task_created never sets a driver; it only arrives on a later task_updated.
    const created = taskStateFromEntry(
      { ...BASE_ENTRY, driver: undefined },
      undefined,
      undefined,
    );
    expect(created.driver).toBeUndefined();

    const merged = taskStateFromEntry(
      { ...BASE_ENTRY, driver: "claude" },
      created,
      created.uuid,
    );

    expect(merged.driver).toBe("claude");
  });
});

describe("live Claude session (session/init present) — control", () => {
  it("qualifies Bash as a Claude built-in", () => {
    const initialized = reduceMessage(
      makeReloadedTask("claude", "claude"),
      SESSION_INIT,
    );
    const next = reduceMessage(initialized, BASH_STARTED);

    const blockKey = next.itemIdMap.get("bash-1");
    const block = next.blocks.get(blockKey!);
    expect(block).toBeTruthy();
    expect(block?.driver).toBe("claude");
    expect(
      qualifiedToolKey(block!.name!, block!.toolServer, block!.driver),
    ).toBe("claude/Bash");
  });

  it("tracks a Claude Edit as a file edit", () => {
    const initialized = reduceMessage(
      makeReloadedTask("claude", "claude"),
      SESSION_INIT,
    );
    const started = reduceMessage(initialized, EDIT_STARTED);
    const next = reduceMessage(started, EDIT_RESULT);

    const tracked = next.trackedFiles.get("/tmp/project/notes.md");
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.type).toBe("edit");
    expect(tracked?.edits[0]?.source).toBe("claude-tool");
  });
});
