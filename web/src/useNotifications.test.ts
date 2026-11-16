import { describe, expect, it } from "vitest";
import type { TaskListEntry } from "./protocol";
import { makeWorkerCode } from "./useNotifications";

type WorkerScope = {
  onconnect?: (event: { ports: unknown[] }) => void;
};

type WorkerNotificationOptions = {
  body?: string;
  tag?: string;
  icon?: string;
};

type ScheduledTimer = {
  callback: () => void;
  delay: number;
};

function task(
  tid: number,
  needsAttention: boolean,
  child_count: number,
  title = `Task ${tid}`,
  notificationBody = `Body ${tid}`,
): TaskListEntry {
  return {
    tid,
    alive: false,
    resumable: true,
    isProcessing: false,
    child_count,
    needsAttention,
    title,
    notificationBody,
  };
}

function startWorker() {
  const sockets: MockWebSocket[] = [];
  const notifications: MockNotification[] = [];
  const timers: ScheduledTimer[] = [];
  const scope: WorkerScope = {};

  class MockWebSocket {
    binaryType = "";
    onopen: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onmessage: ((event: { data: unknown }) => void) | null = null;
    closeCalls = 0;

    constructor(readonly url: string) {
      sockets.push(this);
    }

    open() {
      if (!this.onopen) throw new Error("WebSocket did not install onopen");
      this.onopen();
    }

    close() {
      this.closeCalls += 1;
    }

    emitClose() {
      if (!this.onclose) throw new Error("WebSocket did not install onclose");
      this.onclose();
    }

    emitJson(raw: unknown) {
      this.emitMessage(JSON.stringify(raw));
    }

    emitBinaryJson(raw: unknown) {
      this.emitMessage(new TextEncoder().encode(JSON.stringify(raw)));
    }

    private emitMessage(data: unknown) {
      if (!this.onmessage)
        throw new Error("WebSocket did not install onmessage");
      this.onmessage({ data });
    }
  }

  class MockNotification {
    closeCalls = 0;

    constructor(
      readonly title: string,
      readonly options: WorkerNotificationOptions,
    ) {
      notifications.push(this);
    }

    close() {
      this.closeCalls += 1;
    }
  }

  class MockPort {
    onmessage: ((event: { data: unknown }) => void) | null = null;
    starts = 0;

    start() {
      this.starts += 1;
    }

    emit(data: unknown) {
      if (!this.onmessage) throw new Error("Port did not install onmessage");
      this.onmessage({ data });
    }
  }

  const schedule = (callback: () => void, delay: number) => {
    timers.push({ callback, delay });
    return timers.length;
  };
  const workerUrl = "ws://notifications.test/ws";
  // eslint-disable-next-line @typescript-eslint/no-implied-eval -- execute the generated worker source with injected test doubles
  const evaluate = new Function(
    "self",
    "WebSocket",
    "Notification",
    "TextDecoder",
    "setTimeout",
    makeWorkerCode(workerUrl, "http://notifications.test/icon-192.png"),
  ) as (
    self: WorkerScope,
    WebSocket: typeof MockWebSocket,
    Notification: typeof MockNotification,
    TextDecoder: typeof globalThis.TextDecoder,
    setTimeout: (callback: () => void, delay: number) => number,
  ) => void;

  evaluate(scope, MockWebSocket, MockNotification, TextDecoder, schedule);

  return {
    notifications,
    sockets,
    timers,
    port() {
      const port = new MockPort();
      if (!scope.onconnect) throw new Error("Worker did not install onconnect");
      scope.onconnect({ ports: [port] });
      return port;
    },
    socket(index: number) {
      const socket = sockets[index];
      if (!socket) throw new Error(`No WebSocket at index ${index}`);
      return socket;
    },
    runNextTimer() {
      const timer = timers.shift();
      if (!timer) throw new Error("No reconnect timer is pending");
      timer.callback();
    },
  };
}

describe("notification SharedWorker baseline", () => {
  it("suppresses every staged packet through its terminal merge before handling live transitions", () => {
    const worker = startWorker();
    const socket = worker.socket(0);

    expect(socket.url).toBe("ws://notifications.test/ws");
    expect(socket.binaryType).toBe("arraybuffer");
    socket.open();

    socket.emitBinaryJson({
      type: "tasks_list",
      complete: false,
      tasks: [task(101, true, 2, "Stage one", "Stage one body")],
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "task_updated",
      complete: true,
      task: task(105, true, 0, "Early update", "Early update body"),
    });
    socket.emitJson({
      type: "tasks_list",
      complete: false,
      tasks: [
        task(102, true, 0, "Stage two", "Stage two body"),
        task(105, true, 0, "Early update", "Early update body"),
      ],
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "tasks_list",
      complete: true,
      tasks: [
        task(103, false, 1, "Terminal parent", "Terminal parent body"),
        task(104, true, 0, "Terminal child", "Terminal child body"),
      ],
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "task_updated",
      task: task(104, true, 0, "Terminal child", "Terminal child body"),
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "task_updated",
      task: task(101, true, 2, "Stage one", "Stage one body"),
    });
    socket.emitJson({
      type: "task_updated",
      task: task(105, true, 0, "Early update", "Early update body"),
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "task_updated",
      task: task(101, false, 2, "Needs response", "Please reply"),
    });
    socket.emitJson({
      type: "task_updated",
      task: task(101, true, 2, "Needs response", "Please reply"),
    });
    expect(worker.notifications).toHaveLength(1);
    expect(worker.notifications[0]).toMatchObject({
      title: "Needs response",
      options: {
        body: "Please reply",
        tag: "cydo-101",
        icon: "http://notifications.test/icon-192.png",
      },
    });

    socket.emitJson({
      type: "task_updated",
      task: task(101, true, 2, "Needs response", "Please reply"),
    });
    expect(worker.notifications).toHaveLength(1);

    socket.emitJson({
      type: "task_updated",
      task: task(101, false, 2, "Needs response", "Please reply"),
    });
    expect(worker.notifications[0]!.closeCalls).toBe(1);

    socket.emitJson({
      type: "task_updated",
      task: task(101, false, 2, "Needs response", "Please reply"),
    });
    expect(worker.notifications[0]!.closeCalls).toBe(1);
  });

  it("treats an attention-needed one-packet terminal list as baseline data", () => {
    const worker = startWorker();
    const socket = worker.socket(0);
    socket.open();

    socket.emitJson({
      type: "tasks_list",
      complete: true,
      tasks: [task(201, true, 0, "One packet", "One packet body")],
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({
      type: "task_updated",
      task: task(201, false, 0, "One packet", "One packet body"),
    });
    socket.emitJson({
      type: "task_updated",
      task: task(201, true, 0, "One packet", "One packet body"),
    });
    expect(worker.notifications).toHaveLength(1);
  });

  it("requires literal true to finish an empty baseline", () => {
    const worker = startWorker();
    const socket = worker.socket(0);
    socket.open();

    socket.emitJson({ type: "tasks_list", tasks: [] });
    socket.emitJson({
      type: "task_updated",
      task: task(202, true, 0, "Missing complete", "Missing body"),
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({ type: "tasks_list", complete: false, tasks: [] });
    socket.emitJson({
      type: "task_updated",
      task: task(203, true, 0, "False complete", "False body"),
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({ type: "tasks_list", complete: 1, tasks: [] });
    socket.emitJson({
      type: "task_updated",
      task: task(204, true, 0, "Malformed complete", "Malformed body"),
    });
    expect(worker.notifications).toHaveLength(0);

    socket.emitJson({ type: "tasks_list", complete: true, tasks: [] });
    socket.emitJson({
      type: "task_updated",
      task: task(202, false, 0, "Missing complete", "Missing body"),
    });
    socket.emitJson({
      type: "task_updated",
      task: task(202, true, 0, "Missing complete", "Missing body"),
    });
    expect(worker.notifications).toHaveLength(1);
  });

  it("closes old notifications and establishes a fresh suppressed baseline after reconnect", () => {
    const worker = startWorker();
    const firstSocket = worker.socket(0);
    firstSocket.open();

    firstSocket.emitJson({
      type: "tasks_list",
      complete: true,
      tasks: [task(301, false, 0, "Old task", "Old task body")],
    });
    firstSocket.emitJson({
      type: "task_updated",
      task: task(301, true, 0, "Old task", "Old task body"),
    });
    expect(worker.notifications).toHaveLength(1);
    const oldNotification = worker.notifications[0]!;

    firstSocket.emitClose();
    expect(worker.timers).toHaveLength(1);
    expect(worker.timers[0]!.delay).toBe(3000);
    worker.runNextTimer();

    expect(worker.sockets).toHaveLength(2);
    const secondSocket = worker.socket(1);
    secondSocket.open();
    expect(oldNotification.closeCalls).toBe(1);

    secondSocket.emitJson({
      type: "tasks_list",
      complete: false,
      tasks: [task(302, true, 0, "Fresh early", "Fresh early body")],
    });
    secondSocket.emitJson({ type: "tasks_list", complete: true, tasks: [] });
    expect(worker.notifications).toHaveLength(1);

    secondSocket.emitJson({
      type: "task_updated",
      task: task(301, true, 0, "New task", "New task body"),
    });
    expect(worker.notifications).toHaveLength(2);

    secondSocket.emitJson({
      type: "task_updated",
      task: task(302, false, 0, "Fresh early", "Fresh early body"),
    });
    secondSocket.emitJson({
      type: "task_updated",
      task: task(302, true, 0, "Fresh early", "Fresh early body"),
    });
    expect(worker.notifications).toHaveLength(3);
  });

  it("suppresses live attention while a connected tab is focused", () => {
    const worker = startWorker();
    const port = worker.port();
    const socket = worker.socket(0);
    expect(port.starts).toBe(1);
    socket.open();

    socket.emitJson({
      type: "tasks_list",
      complete: true,
      tasks: [task(401, false, 0, "Focused task", "Focused task body")],
    });
    port.emit({ type: "tab-state", hasFocus: true });
    socket.emitJson({
      type: "task_updated",
      task: task(401, true, 0, "Focused task", "Focused task body"),
    });
    expect(worker.notifications).toHaveLength(0);

    port.emit({ type: "tab-state", hasFocus: false });
    socket.emitJson({
      type: "task_updated",
      task: task(401, false, 0, "Focused task", "Focused task body"),
    });
    socket.emitJson({
      type: "task_updated",
      task: task(401, true, 0, "Focused task", "Focused task body"),
    });
    expect(worker.notifications).toHaveLength(1);
  });
});
