import { h, render } from "preact";
import renderToString from "preact-render-to-string";
import { SessionView } from "./components/SessionView";
import { permissionAwaitingAgent } from "./permissionHandoff";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Connection } from "./connection";
import {
  reduceAgentAck,
  reduceMessage,
  replaceHistoryBoundary,
} from "./sessionReducer";
import { deepFreeze } from "./testing/deepFreeze";
import { replayStream, type ReplayOperation } from "./testing/replayStreams";
import type { TaskState } from "./types";
import { useTaskManager, type TaskManager } from "./useSessionManager";
import { WriteBatch } from "./writeBatch";

const tid = 42;
const path = "/source/project";
const frames = new Map<number, FrameRequestCallback>();
const addToast = vi.fn();
let frameId = 0;
let root: Element;
let manager: TaskManager;
let connection: InstanceType<typeof MockConnection>;

const browserDocument = vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  const document = {
    hidden: false,
    querySelector: () => null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  };
  vi.stubGlobal("document", document);
  return document;
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({ route: vi.fn(), path }),
}));

vi.mock("./connection", () => ({
  Connection: function () {
    connection = new MockConnection();
    return connection;
  },
}));

vi.mock("./outbox", () => ({
  outbox: {
    all: () => [],
    byTid: () => [],
    acceptSend: vi.fn(),
    add: vi.fn(),
    removeForTask: vi.fn(),
  },
}));

// The hook assigns the callbacks when it connects.
const MockConnection = vi.hoisted(
  () =>
    class MockConnection {
      onTaskMessage!: NonNullable<Connection["onTaskMessage"]>;
      onHistoryBoundaryReplaced!: NonNullable<
        Connection["onHistoryBoundaryReplaced"]
      >;
      onUnconfirmedUserMessage!: NonNullable<
        Connection["onUnconfirmedUserMessage"]
      >;
      onAgentAck!: NonNullable<Connection["onAgentAck"]>;
      onControlMessage!: NonNullable<Connection["onControlMessage"]>;
      onStatusChange!: NonNullable<Connection["onStatusChange"]>;

      readonly sendMessage = vi.fn<Connection["sendMessage"]>();
      readonly sendPermissionPromptResponse =
        vi.fn<Connection["sendPermissionPromptResponse"]>();
      readonly unsendMessage = vi.fn<Connection["unsendMessage"]>();

      connect() {
        this.onStatusChange(true);
      }

      disconnect() {
        this.onStatusChange(false);
      }
    },
);

function Probe() {
  manager = useTaskManager(addToast);
  return null;
}

type ReplayEvent = Extract<ReplayOperation, { kind: "event" }>;

function deliver({ event, seq, ts }: ReplayEvent) {
  connection.onTaskMessage(tid, event, seq, ts);
}

function reduceEvent(task: TaskState, { event, seq, ts }: ReplayEvent) {
  const next = reduceMessage(task, event, seq, ts);
  if (
    (event.type === "item/started" || event.type === "turn/stop") &&
    event.history_boundary
  ) {
    return replaceHistoryBoundary(next, event, seq);
  }
  return next;
}

function currentTask() {
  return manager.getByTid(tid)!;
}

async function flush(deliverMessages: () => void) {
  await act(() => {
    deliverMessages();
    expect(frames.size).toBe(1);
    const [id, callback] = frames.entries().next().value!;
    frames.delete(id);
    callback(0);
  });
  deepFreeze(manager.tasks);
}

describe("task event batches", () => {
  beforeEach(async () => {
    vi.stubGlobal("location", { pathname: path });
    vi.stubGlobal("CSS", { supports: () => false });
    vi.stubGlobal("document", browserDocument);
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      frames.set(++frameId, callback);
      return frameId;
    });
    vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
    root = {
      nodeType: 1,
      namespaceURI: "http://www.w3.org/1999/xhtml",
      firstChild: null,
      childNodes: [],
      insertBefore: vi.fn(),
      removeChild: vi.fn(),
    } as unknown as Element;

    await act(() => {
      render(h(Probe, {}), root);
    });
    await flush(() => {
      connection.onControlMessage({
        type: "tasks_list",
        complete: true,
        tasks: [
          {
            tid,
            child_count: 0,
            alive: true,
            resumable: false,
            isProcessing: true,
            status: "active",
          },
        ],
      });
    });
    expect(currentTask()).toBeDefined();
  });

  afterEach(async () => {
    await act(() => {
      render(null, root);
    });
    frames.clear();
    vi.unstubAllGlobals();
  });

  it("publishes one tasks map for 200 events and matches sequential reduction", async () => {
    const events: ReplayEvent[] = [];
    for (const operation of replayStream("claude", 42)) {
      if (operation.kind === "event") events.push(operation);
      if (events.length === 200) break;
    }
    const expected = events.reduce(reduceEvent, currentTask());
    const before = manager.tasks;
    const copies = new Set<unknown>([before]);

    // Preact can coalesce renders even if the updater copies the map for
    // every event. Follow copies of the publication map during the flush.
    const NativeMap = Map;
    vi.stubGlobal(
      "Map",
      new Proxy(NativeMap, {
        construct(target, args: unknown[], newTarget) {
          const map = Reflect.construct(target, args, newTarget) as Map<
            string,
            TaskState
          >;
          const source = args[0];
          if (copies.has(source)) copies.add(map);
          return map;
        },
      }),
    );
    try {
      await flush(() => {
        events.forEach(deliver);
      });
    } finally {
      globalThis.Map = NativeMap;
    }

    expect(currentTask()).toEqual(expected);
    expect(manager.tasks).not.toBe(before);
    expect(copies.has(manager.tasks)).toBe(true);
    expect(copies.size - 1).toBe(1);
  });

  it("applies later events, boundary replacements and acks after freezing each publication", async () => {
    const user = {
      kind: "event",
      event: {
        type: "item/started",
        item_type: "user_message",
        item_id: "history-user",
        content: [{ type: "text", text: "History prompt" }],
        history_boundary: { kind: "user", anchor: "original-anchor" },
      },
      seq: 1,
      ts: 1_700_000_000_001,
    } satisfies ReplayEvent;
    const nextUser = {
      ...user,
      event: { ...user.event, item_id: "next-user" },
      seq: 2,
      ts: user.ts + 1,
    } satisfies ReplayEvent;
    const nonce = "pending-user";
    await flush(() => {
      deliver(user);
      connection.onUnconfirmedUserMessage(
        tid,
        {
          type: "item/started",
          item_type: "user_message",
          item_id: nonce,
          content: [{ type: "text", text: "Pending prompt" }],
        },
        nonce,
      );
    });
    const before = currentTask();
    expect(before.messages).toContainEqual(
      expect.objectContaining({ nonce, ackState: 3 }),
    );

    const replacement = {
      ...user.event,
      history_boundary: { kind: "user", anchor: "new-anchor" },
    } as const;
    const deferred = {
      ...nextUser.event,
      history_boundary: { kind: "user", anchor: "next-anchor" },
    } as const;
    await flush(() => {
      connection.onHistoryBoundaryReplaced(tid, replacement, user.seq);
      connection.onAgentAck(tid, nonce);
      connection.onHistoryBoundaryReplaced(tid, deferred, nextUser.seq);
      deliver(nextUser);
    });

    const updated = reduceAgentAck(
      replaceHistoryBoundary(before, replacement, user.seq),
      nonce,
    );
    expect(currentTask()).toEqual(
      replaceHistoryBoundary(
        reduceEvent(updated, nextUser),
        deferred,
        nextUser.seq,
      ),
    );
    expect(currentTask().messages).toContainEqual(
      expect.objectContaining({ nonce, ackState: 2 }),
    );
  });

  it("keeps a task deleted after an event in the same flush", async () => {
    const { uuid } = currentTask();
    await flush(() => {
      connection.onTaskMessage(tid, {
        type: "item/started",
        item_type: "user_message",
        item_id: "before-control",
        content: [{ type: "text", text: "Before control message" }],
      });
      connection.onControlMessage({ type: "task_deleted", tid });
    });

    expect(manager.getByTid(tid)).toBeUndefined();
    expect(manager.tasks.has(uuid)).toBe(false);
  });

  it("keeps events on both sides of a title update in the same flush", async () => {
    await flush(() => {
      connection.onTaskMessage(tid, {
        type: "item/started",
        item_type: "user_message",
        item_id: "before-control",
        content: [{ type: "text", text: "Before control message" }],
      });
      connection.onControlMessage({
        type: "title_update",
        tid,
        title: "Renamed",
      });
      connection.onTaskMessage(tid, {
        type: "item/started",
        item_type: "user_message",
        item_id: "after-title",
        content: [{ type: "text", text: "After rename" }],
      });
    });

    expect(currentTask()).toMatchObject({
      title: "Renamed",
      messages: [
        {
          type: "user",
          content: [{ type: "text", text: "Before control message" }],
        },
        { type: "user", content: [{ type: "text", text: "After rename" }] },
      ],
    });
  });

  const replayEvents: ReplayEvent[] = [];
  for (const operation of replayStream("claude", 42)) {
    if (operation.kind === "event") replayEvents.push(operation);
    if (replayEvents.length === 100) break;
  }

  function startHistory() {
    connection.onControlMessage({
      type: "task_history_start",
      tid,
      total: replayEvents.length,
    });
  }

  function endHistory() {
    connection.onControlMessage({ type: "task_history_end", tid });
  }

  function completedHistory(task: TaskState): TaskState {
    return {
      ...task,
      historyLoaded: true,
      everLoaded: true,
      historyTotal: undefined,
      historyReceived: undefined,
      preReloadDrafts: undefined,
      pendingHistoryReplies: 0,
      inputDraft: undefined,
      sessionStatus: task.isProcessing ? task.sessionStatus : null,
    };
  }

  it("publishes only history progress across five frames, then the full replay", async () => {
    await flush(startHistory);
    const start = currentTask();
    expect(start).toMatchObject({
      historyLoaded: false,
      historyTotal: replayEvents.length,
      historyReceived: 0,
    });
    const expected = completedHistory(replayEvents.reduce(reduceEvent, start));

    for (let offset = 0; offset < replayEvents.length; offset += 20) {
      const chunk = replayEvents.slice(offset, offset + 20);
      await flush(() => {
        chunk.forEach(deliver);
      });

      const progress = currentTask();
      expect(progress.historyReceived).toBe(offset + chunk.length);
      expect(progress.messages).toBe(start.messages);
      expect(progress.blocks).toBe(start.blocks);
      expect(progress.itemIdMap).toBe(start.itemIdMap);
    }

    await flush(endHistory);
    expect(currentTask()).toEqual(expected);
  });

  it("publishes a mid-replay title update immediately and resumes replay", async () => {
    await flush(startHistory);
    const start = currentTask();
    const first = replayEvents.slice(0, 50);
    const rest = replayEvents.slice(first.length);
    const title = "Renamed during replay";

    await flush(() => {
      first.forEach(deliver);
    });
    expect(currentTask().messages).toBe(start.messages);
    await flush(() => {
      connection.onControlMessage({ type: "title_update", tid, title });
    });
    const renamed = currentTask();
    expect(renamed).toMatchObject({
      title,
      historyLoaded: false,
      historyReceived: first.length,
    });
    const expectedAtRename = { ...first.reduce(reduceEvent, start), title };
    expect(renamed.messages).toEqual(expectedAtRename.messages);

    await flush(() => {
      rest.forEach(deliver);
    });
    expect(currentTask().messages).toBe(renamed.messages);
    await flush(endHistory);
    expect(currentTask()).toEqual(
      completedHistory(rest.reduce(reduceEvent, expectedAtRename)),
    );
  });

  it("publishes history progress and the same final replay while hidden", async () => {
    async function flushHidden(deliverMessage: () => void) {
      await act(deliverMessage);
      expect(frames.size).toBe(0);
      deepFreeze(manager.tasks);
    }

    browserDocument.hidden = true;
    try {
      await flushHidden(startHistory);
      const start = currentTask();
      for (const [index, event] of replayEvents.entries()) {
        await flushHidden(() => {
          deliver(event);
        });
        expect(currentTask().historyReceived).toBe(index + 1);
        expect(currentTask().messages).toBe(start.messages);
      }
      await flushHidden(endHistory);
      expect(currentTask()).toEqual(
        completedHistory(replayEvents.reduce(reduceEvent, start)),
      );
    } finally {
      browserDocument.hidden = false;
    }
  });

  const permissionToolId = "awaiting-permission";

  async function submitPermission() {
    await flush(() => {
      connection.onControlMessage({
        type: "permission_prompt",
        tid,
        tool_use_id: permissionToolId,
        tool_name: "Bash",
        input: { command: "echo test" },
      });
    });
    await act(() => {
      manager.sendPermissionPromptResponse(tid, permissionToolId, "allow");
    });
    const submitted = currentTask().submittedPermission;
    expect(submitted?.toolUseId).toBe(permissionToolId);
    return submitted;
  }

  const permissionTool: ReplayEvent = {
    kind: "event",
    event: {
      type: "item/started",
      item_type: "tool_use",
      item_id: permissionToolId,
      name: "Bash",
    },
    seq: 101,
    ts: 101,
  };

  function permissionStage(stage: "answered" | "accepted"): ReplayEvent {
    return {
      kind: "event",
      event: { type: "item/permission", item_id: permissionToolId, stage },
      seq: 102,
      ts: 102,
    };
  }

  function renderSession() {
    const noop = () => {};
    return renderToString(
      h(SessionView, {
        heicConversion: { available: false },
        getHeicConversion: () => ({ available: false }),
        task: currentTask(),
        connected: true,
        tasksLoading: false,
        isActive: true,
        onSend: noop,
        onInterrupt: noop,
        onStop: noop,
        onCloseStdin: noop,
        onResume: noop,
        onFork: noop,
        onUndo: noop,
        onUndoConfirm: noop,
        onUndoDismiss: noop,
        onClearInputDraft: noop,
        ordinaryDraftStore: manager.ordinaryDraftStore,
        onAskUserResponse: noop,
        onPermissionPromptResponse: noop,
        theme: "dark",
        onToggleTheme: noop,
        onToggleSidebar: noop,
      }),
    );
  }

  it("shows the submitted permission as soon as its block replays", async () => {
    const submitted = await submitPermission();
    await flush(startHistory);
    await flush(() => {
      deliver(permissionTool);
      deliver(permissionStage("answered"));
    });

    expect(currentTask().historyLoaded).toBe(false);
    expect(permissionAwaitingAgent(currentTask())).toBe(submitted);
    expect(renderSession()).toContain("permission-prompt-sending");
    await flush(endHistory);
    expect(renderSession()).toContain("permission-prompt-sending");
  });

  it("clears the submitted permission as soon as acceptance replays", async () => {
    await flush(startHistory);
    const start = currentTask();
    const earlyEvents = replayEvents.slice(0, 5);
    await flush(() => {
      earlyEvents.forEach(deliver);
    });
    await flush(() => {
      deliver(permissionTool);
    });
    const submitted = await submitPermission();
    expect(permissionAwaitingAgent(currentTask())).toBe(submitted);
    expect(renderSession()).toContain("permission-prompt-sending");

    const accepted = permissionStage("accepted");
    await flush(() => {
      deliver(accepted);
    });
    expect(currentTask().historyLoaded).toBe(false);
    expect(permissionAwaitingAgent(currentTask())).toBeUndefined();
    expect(renderSession()).not.toContain("permission-prompt-sending");

    await flush(endHistory);
    const reduced = [...earlyEvents, permissionTool, accepted].reduce(
      reduceEvent,
      start,
    );
    expect(currentTask()).toEqual(
      completedHistory({
        ...reduced,
        pendingPermission: null,
        submittedPermission: submitted,
        isProcessing: true,
      }),
    );
  });

  it("keeps the same write batch open until the replay is published", async () => {
    const submitted = await submitPermission();
    await flush(startHistory);
    const object = vi.spyOn(WriteBatch.prototype, "object");
    const close = vi.spyOn(WriteBatch.prototype, "close");
    try {
      await flush(() => {
        replayEvents.slice(0, 50).forEach(deliver);
      });
      expect(object).toHaveBeenCalled();
      const [batch] = object.mock.contexts;
      expect(currentTask().submittedPermission).toBe(submitted);
      expect(permissionAwaitingAgent(currentTask())).toBeUndefined();
      expect(close).not.toHaveBeenCalled();

      object.mockClear();
      await flush(() => {
        replayEvents.slice(50).forEach(deliver);
      });
      expect(object).toHaveBeenCalled();
      expect(new Set(object.mock.contexts)).toEqual(new Set([batch]));
      expect(close).not.toHaveBeenCalled();

      await flush(endHistory);
      expect(close).toHaveBeenCalledTimes(1);
      expect(close.mock.contexts[0]).toBe(batch);
    } finally {
      object.mockRestore();
      close.mockRestore();
    }
  });

  it("closes the replay batch and clears the task store on unmount before the connection closes", async () => {
    await flush(startHistory);
    await flush(() => {
      deliver(replayEvents[0]!);
    });
    expect(currentTask()).toMatchObject({
      historyLoaded: false,
      historyReceived: 1,
    });

    const close = vi.spyOn(WriteBatch.prototype, "close");
    const disconnect = vi
      .spyOn(connection, "disconnect")
      .mockImplementation(() => {
        expect(close).toHaveBeenCalledOnce();
        expect(manager.getByTid(tid)).toBeUndefined();
      });
    try {
      await act(() => {
        render(null, root);
        expect(disconnect).toHaveBeenCalledOnce();
      });
    } finally {
      disconnect.mockRestore();
      close.mockRestore();
      // Deliver the delayed close after checking synchronous teardown.
      connection.onStatusChange(false);
    }
  });

  it("restores a locally withdrawn prompt when the confirmation is replayed", async () => {
    const text = "Restore my queued prompt";
    await act(() => {
      manager.send(currentTask().uuid, text);
    });
    const nonce = connection.sendMessage.mock.lastCall![2]!;
    await act(() => {
      manager.unsendMessage(tid, nonce);
    });
    expect(connection.unsendMessage).toHaveBeenCalledWith(tid, nonce);

    await flush(() => {
      connection.onControlMessage({ type: "task_reload", tid, reason: "edit" });
    });
    await flush(() => {
      connection.onControlMessage({
        type: "task_history_start",
        tid,
        total: 3,
      });
    });
    await flush(() => {
      deliver(replayEvents[0]!);
    });
    await flush(() => {
      deliver(replayEvents[1]!);
      connection.onTaskMessage(
        tid,
        {
          type: "user_message/consumed",
          uuid: "queued-prompt",
          consumed_as: "cancelled",
          correlation_id: nonce,
        },
        0,
        1,
      );
    });

    expect(currentTask()).toMatchObject({
      historyLoaded: false,
      historyReceived: 3,
      inputDraft: text,
    });

    const historyOperations = { fork: {}, undo: {} };
    await flush(() => {
      connection.onControlMessage({
        type: "history_operations",
        tid,
        history_operations: historyOperations,
      });
      endHistory();
    });
    expect(currentTask()).toMatchObject({
      historyLoaded: true,
      historyReceived: undefined,
      historyOperations,
      inputDraft: undefined,
    });
  });
});
