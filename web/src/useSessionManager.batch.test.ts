import { h, render } from "preact";
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

const tid = 42;
const path = "/source/project";
const frames = new Map<number, FrameRequestCallback>();
const addToast = vi.fn();
let frameId = 0;
let root: Element;
let manager: TaskManager;
let connection: InstanceType<typeof MockConnection>;

const browserDocument = vi.hoisted(() => {
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
});
