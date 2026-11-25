import { Buffer } from "node:buffer";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type TaskListEntry = {
  tid: number;
  parent_tid: number;
  child_count: number;
  archived: boolean;
};

type TaskListFrame = {
  type: "tasks_list";
  complete: boolean;
  tasks: readonly TaskListEntry[];
};

type ControlFrame = {
  type?: string;
  complete?: boolean;
  tid?: number;
  parent_tid?: number;
  relation_type?: string;
  correlation_id?: string;
  content?: unknown;
  entry_point?: string;
  agent_name?: string;
  tasks?: readonly TaskListEntry[];
};

type TaskCreated = {
  tid: number;
  parentTid?: number;
  relationType?: string;
};

interface PassiveRecorder {
  controls(type: string, tid?: number): readonly ControlFrame[];
  createdTasks(): readonly TaskCreated[];
}

type SnapshotReleaseState = "waiting" | "holding" | "released";

interface InitialSnapshotHold {
  createRequests: number[];
  deleteRequests: number[];
  targetSnapshotHeld(): boolean;
  targetSnapshotDelivered(): boolean;
  earlyTaskEntry(tid: number): TaskListEntry | null;
  heldTargetTaskEntry(): TaskListEntry | null;
  heldTargetPacketComplete(): boolean | null;
  terminalPacketDelivered(): boolean;
  targetFrameOrder(): number | null;
  heldFrameOrder(): readonly number[];
  releasedFrameOrder(): readonly number[];
  releaseState(): SnapshotReleaseState;
  connectionCount(): number;
  release(): void;
}

function parseControlFrame(message: SocketMessage): ControlFrame | null {
  try {
    return JSON.parse(
      typeof message === "string" ? message : message.toString(),
    ) as ControlFrame;
  } catch {
    return null;
  }
}

function tasksListFrame(frame: ControlFrame | null): TaskListFrame | null {
  if (
    frame?.type !== "tasks_list" ||
    typeof frame.complete !== "boolean" ||
    !Array.isArray(frame.tasks)
  )
    return null;
  return {
    type: "tasks_list",
    complete: frame.complete,
    tasks: frame.tasks,
  };
}

function taskEntry(
  frame: ControlFrame | null,
  tid: number,
): TaskListEntry | null {
  return tasksListFrame(frame)?.tasks.find((task) => task.tid === tid) ?? null;
}

function installPassiveRecorder(page: Page): PassiveRecorder {
  const outbound: ControlFrame[] = [];
  const createdTasks: TaskCreated[] = [];

  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;
    socket.on("framesent", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) outbound.push(frame);
    });
    socket.on("framereceived", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type !== "task_created" || typeof frame.tid !== "number")
        return;
      createdTasks.push({
        tid: frame.tid,
        parentTid: frame.parent_tid,
        relationType: frame.relation_type,
      });
    });
  });

  return {
    controls: (type, tid) =>
      outbound.filter(
        (frame) =>
          frame.type === type && (tid === undefined || frame.tid === tid),
      ),
    createdTasks: () => createdTasks,
  };
}

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<number> {
  let tid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    tid = tids.find((candidate) => !before.has(candidate));
    expect(tid).toBeTruthy();
  }).toPass();
  return Number(tid);
}

async function taskURLFromSidebar(page: Page, tid: number): Promise<string> {
  const taskLink = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(taskLink).toHaveCount(1);
  const href = await taskLink.getAttribute("href");
  if (!href) throw new Error(`Task ${tid} sidebar row did not have a URL`);
  return new URL(href, page.url()).toString();
}

async function waitForPersistedForm(
  recorder: PassiveRecorder,
  tid: number,
  text: string,
  entryPoint: string,
  agent: string,
) {
  await expect
    .poll(() => {
      const drafts = recorder.controls("set_draft", tid);
      return (
        recorder
          .controls("set_entry_point", tid)
          .some((frame) => frame.entry_point === entryPoint) &&
        recorder
          .controls("set_agent_name", tid)
          .some((frame) => frame.agent_name === agent) &&
        drafts.at(-1)?.content === text
      );
    })
    .toBe(true);
}

async function installInitialSnapshotHold(
  page: Page,
  targetTid: number,
): Promise<InitialSnapshotHold> {
  const createRequests: number[] = [];
  const deleteRequests: number[] = [];
  const earlyTaskEntries = new Map<number, TaskListEntry>();
  const heldServerFrames: {
    message: SocketMessage;
    frame: ControlFrame | null;
    order: number;
  }[] = [];
  const deferredServerFrames: typeof heldServerFrames = [];
  const heldFrameOrder: number[] = [];
  const releasedFrameOrder: number[] = [];
  let state: SnapshotReleaseState = "waiting";
  let deliveredTargetSnapshot = false;
  let deliveredTerminalPacket = false;
  let heldTargetEntry: TaskListEntry | null = null;
  let heldTargetPacketComplete: boolean | null = null;
  let heldTargetFrameOrder: number | null = null;
  let replaying = false;
  let nextServerFrameOrder = 0;
  let socketConnections = 0;
  let release = () => {
    throw new Error("WebSocket route was not installed");
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    socketConnections++;
    const serverSocket = browserSocket.connectToServer();

    const deliverServerFrame = (
      serverFrame: (typeof heldServerFrames)[number],
    ) => {
      const list = tasksListFrame(serverFrame.frame);
      if (list?.complete) deliveredTerminalPacket = true;
      if (taskEntry(serverFrame.frame, targetTid))
        deliveredTargetSnapshot = true;
      if (state === "waiting" && list) {
        for (const entry of list.tasks) earlyTaskEntries.set(entry.tid, entry);
      }
      if (replaying) releasedFrameOrder.push(serverFrame.order);
      browserSocket.send(serverFrame.message);
    };

    const relayServerFrame = (message: SocketMessage) => {
      const serverFrame = {
        message,
        frame: parseControlFrame(message),
        order: ++nextServerFrameOrder,
      };
      if (replaying) {
        deferredServerFrames.push(serverFrame);
        return;
      }
      if (state === "holding") {
        heldServerFrames.push(serverFrame);
        heldFrameOrder.push(serverFrame.order);
        return;
      }
      const targetEntry = taskEntry(serverFrame.frame, targetTid);
      if (targetEntry) {
        state = "holding";
        heldTargetEntry = targetEntry;
        heldTargetPacketComplete = tasksListFrame(serverFrame.frame)!.complete;
        heldTargetFrameOrder = serverFrame.order;
        heldServerFrames.push(serverFrame);
        heldFrameOrder.push(serverFrame.order);
        return;
      }
      deliverServerFrame(serverFrame);
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      if (frame?.type === "create_task") createRequests.push(1);
      if (frame?.type === "delete_task") deleteRequests.push(frame.tid ?? -1);
      serverSocket.send(message);
    });
    serverSocket.onMessage(relayServerFrame);

    release = () => {
      if (state !== "holding")
        throw new Error("Target tasks_list was not held");
      state = "released";
      replaying = true;
      try {
        while (heldServerFrames.length > 0)
          deliverServerFrame(heldServerFrames.shift()!);
        while (deferredServerFrames.length > 0)
          deliverServerFrame(deferredServerFrames.shift()!);
      } finally {
        replaying = false;
      }
    };
  });

  return {
    createRequests,
    deleteRequests,
    targetSnapshotHeld: () => state === "holding",
    targetSnapshotDelivered: () => deliveredTargetSnapshot,
    earlyTaskEntry: (tid) => earlyTaskEntries.get(tid) ?? null,
    heldTargetTaskEntry: () => heldTargetEntry,
    heldTargetPacketComplete: () => heldTargetPacketComplete,
    terminalPacketDelivered: () => deliveredTerminalPacket,
    targetFrameOrder: () => heldTargetFrameOrder,
    heldFrameOrder: () => [...heldFrameOrder],
    releasedFrameOrder: () => [...releasedFrameOrder],
    releaseState: () => state,
    connectionCount: () => socketConnections,
    release: () => release(),
  };
}

test("direct task route opens its own editor after the initial snapshot", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const seedContext = await browser.newContext({ baseURL });
  const seedPage = await seedContext.newPage();
  const seedRecorder = installPassiveRecorder(seedPage);
  const persistedText =
    "direct editor from tasks list\nwith complete persisted body";
  const persistedAgent = agentType === "codex" ? "claude" : "codex";

  await seedPage.goto(baseURL!);
  await enterSession(seedPage);
  await expect(
    seedPage.locator(`.agent-picker option[value="${persistedAgent}"]`),
  ).toHaveCount(1);
  await seedPage.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    seedPage.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await seedPage.locator(".agent-picker:visible").selectOption(persistedAgent);
  await expect(seedPage.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );

  const before = await snapshotTids(seedPage);
  await seedPage.locator(".input-textarea:visible").fill(persistedText);
  const tid = await waitForNewTid(seedPage, before);
  await waitForPersistedForm(
    seedRecorder,
    tid,
    persistedText,
    "blank",
    persistedAgent,
  );
  const targetURL = await taskURLFromSidebar(seedPage, tid);
  const projectPath = new URL(targetURL).pathname.replace(/\/task\/\d+$/, "");

  await seedContext.close();

  const proxy = await installInitialSnapshotHold(page, tid);
  await page.goto(targetURL);
  await expect.poll(() => proxy.targetSnapshotHeld()).toBe(true);
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);

  proxy.release();
  await expect.poll(() => proxy.targetSnapshotDelivered()).toBe(true);
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(persistedText);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );
  await expect(
    page.locator(".session-empty:visible", { hasText: "Loading task" }),
  ).toHaveCount(0);
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(1);
  expect(proxy.createRequests).toEqual([]);
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));

  await page.locator(".sidebar-back-btn:visible").click();
  await expect(page).toHaveURL(/\/$/);
  await page.goBack();
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(input).toHaveCount(1);
  await expect(input).toHaveValue(persistedText);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);

  await input.fill("");
  await expect(page).toHaveURL(new RegExp(`${projectPath}$`));
  await expect.poll(() => proxy.deleteRequests).toEqual([tid]);
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue("");
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([tid]);
});

test("held incremental bootstrap keeps an archived child route truthful", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const seedContext = await browser.newContext({ baseURL });
  const seedPage = await seedContext.newPage();
  const seedRecorder = installPassiveRecorder(seedPage);
  const marker = Date.now();
  const parentMarker = `held-bootstrap-parent-${marker}`;
  const childMarker = `held-bootstrap-child-history-${marker}`;

  await seedPage.goto(baseURL!);
  await enterSession(seedPage);
  await sendMessage(seedPage, `reply with "${parentMarker}"`);
  await expect(assistantText(seedPage, parentMarker).last()).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const activeParent = seedPage
    .locator(".sidebar-item.active[data-tid]")
    .first();
  await expect(activeParent).toBeVisible();
  const parentTidText = await activeParent.getAttribute("data-tid");
  if (!parentTidText)
    throw new Error("Top-level task did not have a numeric tid");
  const parentTid = Number(parentTidText);

  await sendMessage(seedPage, `call task research reply with "${childMarker}"`);
  const seedMessages = seedPage.locator(
    '[style*="display: contents"] .message-list',
  );
  await expect(
    seedMessages.getByText(childMarker, { exact: true }).last(),
  ).toBeVisible();
  await expect(
    seedMessages.getByText("Done.", { exact: true }).last(),
  ).toBeVisible();

  const directChild = () =>
    seedRecorder
      .createdTasks()
      .find(
        (task) =>
          task.parentTid === parentTid && task.relationType === "subtask",
      );
  await expect.poll(() => directChild()?.tid ?? null).not.toBeNull();
  const childTid = directChild()?.tid;
  if (childTid === undefined)
    throw new Error("Task workflow did not create the direct child");

  await expect(
    seedPage.locator(`.sidebar-item[data-tid="${parentTid}"].active`),
  ).toBeVisible();
  await seedPage.locator(".btn-banner-stop:visible").click();
  await expect(seedPage.locator(".btn-banner-archive:visible")).toHaveText(
    "Archive",
  );

  const childLink = seedPage.locator(`.sidebar-item[data-tid="${childTid}"]`);
  await expect(childLink).toBeVisible();
  await childLink.click();
  await expect(
    seedPage.locator(`.sidebar-item[data-tid="${childTid}"].active`),
  ).toBeVisible();
  const archiveButton = seedPage.locator(".btn-banner-archive:visible");
  await expect(archiveButton).toHaveText("Archive");
  await archiveButton.click();
  await expect(archiveButton).toHaveText("Unarchive");

  const parentURL = await taskURLFromSidebar(seedPage, parentTid);
  const childURL = await taskURLFromSidebar(seedPage, childTid);
  await seedPage.locator(`.sidebar-item[data-tid="${parentTid}"]`).click();
  await expect(
    seedPage.locator(`.sidebar-item[data-tid="${parentTid}"].active`),
  ).toBeVisible();
  await expect(seedPage.locator(".btn-banner-archive:visible")).toHaveText(
    "Archive",
  );
  await seedContext.close();

  await page.addInitScript((notFoundText) => {
    type HeldBootstrapObserverState = {
      sawNotFound: boolean;
      sawConnectedWithPlaceholder: boolean;
      loadingItems: number;
      connectedStatuses: number;
      observer: MutationObserver | null;
    };
    const beginObservation = () => {
      const observerWindow = window as Window & {
        __cydoHeldBootstrapObserver?: HeldBootstrapObserverState;
      };
      observerWindow.__cydoHeldBootstrapObserver?.observer?.disconnect();
      const count = (node: Element, selector: string) =>
        Number(node.matches(selector)) + node.querySelectorAll(selector).length;
      const connectedBar = '.task-bar[data-connection="connected"]';
      const state: HeldBootstrapObserverState = {
        sawNotFound: false,
        sawConnectedWithPlaceholder: false,
        loadingItems: document.querySelectorAll(".sidebar-loading-item").length,
        connectedStatuses: document.querySelectorAll(connectedBar).length,
        observer: null,
      };
      const inspect = () => {
        if (document.body.textContent?.includes(notFoundText))
          state.sawNotFound = true;
        if (state.loadingItems > 0 && state.connectedStatuses > 0)
          state.sawConnectedWithPlaceholder = true;
      };
      const inspectNode = (node: Node, direction: 1 | -1) => {
        if (node.textContent?.includes(notFoundText)) state.sawNotFound = true;
        if (!(node instanceof Element)) return;
        state.loadingItems += direction * count(node, ".sidebar-loading-item");
        state.connectedStatuses +=
          direction * count(node, connectedBar);
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === "childList") {
            for (const node of record.removedNodes) inspectNode(node, -1);
            for (const node of record.addedNodes) inspectNode(node, 1);
          } else if (
            record.type === "attributes" &&
            record.target instanceof Element
          ) {
            const wasConnected = record.oldValue === "connected";
            const isConnected = record.target.matches(connectedBar);
            state.connectedStatuses +=
              Number(isConnected) - Number(wasConnected);
          } else if (record.target.textContent?.includes(notFoundText)) {
            state.sawNotFound = true;
          }
          inspect();
        }
      });
      state.observer = observer;
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["data-connection"],
        attributeOldValue: true,
      });
      observerWindow.__cydoHeldBootstrapObserver = state;
      inspect();
    };
    if (document.readyState === "loading")
      document.addEventListener("DOMContentLoaded", beginObservation, {
        once: true,
      });
    else beginObservation();
  }, `Task ${childTid} not found`);

  const proxy = await installInitialSnapshotHold(page, childTid);
  await page.goto(childURL);
  await expect.poll(() => proxy.targetSnapshotHeld()).toBe(true);
  await expect.poll(() => proxy.heldFrameOrder().length > 1).toBe(true);

  expect(proxy.releaseState()).toBe("holding");
  expect(proxy.earlyTaskEntry(parentTid)).toMatchObject({
    tid: parentTid,
    child_count: 1,
    archived: false,
  });
  expect(proxy.heldTargetTaskEntry()).toMatchObject({
    tid: childTid,
    parent_tid: parentTid,
    archived: true,
  });
  expect(proxy.heldTargetPacketComplete()).toBe(true);
  expect(proxy.terminalPacketDelivered()).toBe(false);

  const parentRow = page.locator(`.sidebar-item[data-tid="${parentTid}"]`);
  const parentPlaceholder = page.locator(
    `.sidebar-loading-item:has(+ .sidebar-item[data-tid="${parentTid}"])`,
  );
  await expect(parentRow).toBeVisible();
  await expect(page).toHaveURL(childURL);
  await expect(parentPlaceholder).toHaveCount(1);
  await expect(parentPlaceholder).toHaveText("(loading…)");
  await expect(parentPlaceholder.locator("a")).toHaveCount(0);
  await expect(parentPlaceholder).not.toHaveClass(/sidebar-item/);
  expect(await parentPlaceholder.getAttribute("data-tid")).toBeNull();

  const taskLoading = page.locator(".session-empty:visible", {
    hasText: "Loading task…",
  });
  await expect(taskLoading).toHaveCount(1);
  await expect(
    page.getByText(`Task ${childTid} not found`, { exact: true }),
  ).toHaveCount(0);
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);

  const initialSocketCount = proxy.connectionCount();
  await parentRow.click();
  await expect(page).toHaveURL(parentURL);
  expect(proxy.connectionCount()).toBe(initialSocketCount);
  const loadingBanner = page.locator('.task-bar[data-connection="loading"]:visible');
  await expect(loadingBanner).toHaveCount(1);
  await expect(loadingBanner.locator(".task-bar-agent")).toHaveAttribute(
    "title",
    "Loading…",
  );
  await expect(
    page.locator(".sidebar").getByText("Loading…", { exact: true }),
  ).toHaveCount(0);
  await expect(parentPlaceholder).toHaveCount(1);

  await page.goBack();
  await expect(page).toHaveURL(childURL);
  expect(proxy.connectionCount()).toBe(initialSocketCount);
  await expect(taskLoading).toHaveCount(1);
  await expect(
    page.getByText(`Task ${childTid} not found`, { exact: true }),
  ).toHaveCount(0);

  const heldOrder = proxy.heldFrameOrder();
  expect(proxy.targetFrameOrder()).toBe(heldOrder[0]);
  proxy.release();
  await expect.poll(() => proxy.targetSnapshotDelivered()).toBe(true);
  await expect.poll(() => proxy.terminalPacketDelivered()).toBe(true);
  expect(proxy.releaseState()).toBe("released");
  const replayOrder = proxy.releasedFrameOrder();
  expect(replayOrder.slice(0, heldOrder.length)).toEqual(heldOrder);
  expect(replayOrder).toEqual([...replayOrder].sort((a, b) => a - b));
  expect(new Set(replayOrder).size).toBe(replayOrder.length);
  await expect(page).toHaveURL(childURL);

  const parentArchiveGroup = page.locator(
    `.sidebar-item.sidebar-archive-node[data-tid="archive:${parentTid}"]`,
  );
  const childRow = page.locator(`.sidebar-item[data-tid="${childTid}"]`);
  await expect(parentArchiveGroup).toBeVisible();
  await expect(childRow).toBeVisible();
  await expect(
    childRow.locator(
      `xpath=following-sibling::a[@data-tid="archive:${parentTid}"][1]`,
    ),
  ).toHaveCount(1);
  await expect(assistantText(page, childMarker).last()).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(parentPlaceholder).toHaveCount(0);
  await expect(page.locator(".sidebar-loading-item")).toHaveCount(0);
  const connectedBanner = page.locator('.task-bar[data-connection="connected"]:visible');
  await expect(connectedBanner).toHaveCount(1);
  await expect(taskLoading).toHaveCount(0);
  await expect(
    page.getByText(`Task ${childTid} not found`, { exact: true }),
  ).toHaveCount(0);

  const prohibitedTransient = await page.evaluate(() => {
    const observerWindow = window as Window & {
      __cydoHeldBootstrapObserver?: {
        sawNotFound: boolean;
        sawConnectedWithPlaceholder: boolean;
      };
    };
    return observerWindow.__cydoHeldBootstrapObserver;
  });
  expect(prohibitedTransient?.sawNotFound).toBe(false);
  expect(prohibitedTransient?.sawConnectedWithPlaceholder).toBe(false);
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);
  expect(() => proxy.release()).toThrow("Target tasks_list was not held");

  await page.evaluate(() => {
    const observerWindow = window as Window & {
      __cydoHeldBootstrapObserver?: { observer: MutationObserver | null };
    };
    observerWindow.__cydoHeldBootstrapObserver?.observer?.disconnect();
  });
});
