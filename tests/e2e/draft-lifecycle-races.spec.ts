import { Buffer } from "node:buffer";
import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type ControlFrame = {
  type?: string;
  complete?: boolean;
  tid?: number;
  from_tid?: number;
  to_tid?: number;
  correlation_id?: string;
  content?: unknown;
  new_draft?: string;
  entry_point?: string;
  agent_name?: string;
  entry_points?: unknown;
  task?: {
    tid?: number;
    draft?: string;
    isProcessing?: boolean;
  };
};

type CreateRequest = {
  correlationId: string | null;
  content: unknown;
  order: number;
};

type CreatedTask = {
  tid: number;
  correlationId: string | null;
};

type RawMessage = {
  tid: number | null;
  nonce: string | null;
  content: unknown;
  order: number;
};

type BrowserNavigation = {
  kind: "pushState" | "replaceState" | "popstate";
  pathname: string;
};

type ControlDirection =
  | "browser-to-server"
  | "server-received"
  | "server-delivered";

type ObservedControl = {
  order: number;
  direction: ControlDirection;
  frame: ControlFrame;
  deliveredDuringRelease: boolean;
};

type HeldServerFrames =
  | {
      kind: "create";
      correlationId: string;
      tid: number;
      frames: SocketMessage[];
    }
  | {
      kind: "delete";
      tid: number;
      frames: SocketMessage[];
    }
  | {
      kind: "project-types";
      frame: ControlFrame;
      frames: SocketMessage[];
    }
  | {
      kind: "acceptance";
      tid: number;
      frames: SocketMessage[];
    };

interface DraftRaceProxy {
  createRequests: CreateRequest[];
  deleteRequests: number[];
  taskCreated: CreatedTask[];
  taskDeleted: number[];
  bootstrapComplete(): boolean;
  createdTid(correlationId: string): number | null;
  controls(
    type: string,
    query?: { tid?: number; direction?: ControlDirection },
  ): readonly ObservedControl[];
  rawMessages(): readonly RawMessage[];
  isCreateAckHeld(correlationId: string): boolean;
  isDeleteAckHeld(tid: number): boolean;
  isProjectTypesResponseHeld(): boolean;
  isAcceptanceHeld(tid: number): boolean;
  heldProjectTypesResponse(): ControlFrame | null;
  wasServerControlDelivered(type: string, tid?: number): boolean;
  armProjectTypesResponseHold(): void;
  armAcceptanceHold(tid: number): void;
  armDeleteAckHold(tid: number): void;
  releaseProjectTypesResponse(): void;
  releaseCreateAck(): void;
  releaseAcceptanceHold(tid: number): void;
  releaseDeleteAck(tid: number): void;
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

function controlTargetsTid(frame: ControlFrame, tid: number): boolean {
  return frame.tid === tid || frame.to_tid === tid || frame.task?.tid === tid;
}

function isEmptyCreateContent(content: unknown): boolean {
  return Array.isArray(content) && content.length === 0;
}

async function installDraftRaceProxy(page: Page): Promise<DraftRaceProxy> {
  const createRequests: CreateRequest[] = [];
  const deleteRequests: number[] = [];
  const taskCreated: CreatedTask[] = [];
  const taskDeleted: number[] = [];
  const rawMessages: RawMessage[] = [];
  const observations: ObservedControl[] = [];
  const bootstrapFrames = new Set<string>();
  let tasksListComplete = false;
  const deferredServerFrames: SocketMessage[] = [];

  let createCorrelation: string | null = null;
  let heldServerFrames: HeldServerFrames | null = null;
  let armedDeleteTid: number | null = null;
  let armedAcceptanceTid: number | null = null;
  let projectTypesResponseHoldArmed = false;
  let replayingServerFrames = false;
  let nextObservationOrder = 0;
  let armDeletionAck: (tid: number) => void = () => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseProjectTypesResponse = () => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseCreationAck = () => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseAcceptanceHold = (_tid: number) => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseDeletionAck: (tid: number) => void = () => {
    throw new Error("WebSocket route was not installed");
  };

  const recordControl = (
    direction: ControlDirection,
    frame: ControlFrame | null,
    deliveredDuringRelease = false,
  ): ObservedControl | null => {
    if (!frame?.type) return null;
    const observed = {
      order: ++nextObservationOrder,
      direction,
      frame,
      deliveredDuringRelease,
    };
    observations.push(observed);
    return observed;
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    const serverSocket = browserSocket.connectToServer();

    const deliverServerFrame = (message: SocketMessage) => {
      recordControl(
        "server-delivered",
        parseControlFrame(message),
        replayingServerFrames,
      );
      browserSocket.send(message);
    };

    const consumeServerFrame = (message: SocketMessage) => {
      const frame = parseControlFrame(message);
      if (frame?.type) bootstrapFrames.add(frame.type);
      if (frame?.type === "tasks_list" && frame.complete === true)
        tasksListComplete = true;
      recordControl("server-received", frame);

      if (frame?.type === "task_created" && typeof frame.tid === "number") {
        taskCreated.push({
          tid: frame.tid,
          correlationId:
            typeof frame.correlation_id === "string"
              ? frame.correlation_id
              : null,
        });
      }
      if (frame?.type === "task_deleted" && typeof frame.tid === "number")
        taskDeleted.push(frame.tid);

      if (heldServerFrames) {
        heldServerFrames.frames.push(message);
        return;
      }

      if (
        projectTypesResponseHoldArmed &&
        frame?.type === "project_task_types_list"
      ) {
        heldServerFrames = {
          kind: "project-types",
          frame,
          frames: [message],
        };
        projectTypesResponseHoldArmed = false;
        return;
      }

      if (
        armedAcceptanceTid !== null &&
        frame?.type === "task_updated" &&
        frame.task?.tid === armedAcceptanceTid &&
        frame.task.isProcessing === true
      ) {
        const tid = armedAcceptanceTid;
        armedAcceptanceTid = null;
        heldServerFrames = {
          kind: "acceptance",
          tid,
          frames: [message],
        };
        return;
      }

      if (
        createCorrelation !== null &&
        frame?.type === "task_created" &&
        frame.correlation_id === createCorrelation &&
        typeof frame.tid === "number"
      ) {
        heldServerFrames = {
          kind: "create",
          correlationId: createCorrelation,
          tid: frame.tid,
          frames: [message],
        };
        return;
      }

      if (
        armedDeleteTid !== null &&
        frame?.type === "task_deleted" &&
        frame.tid === armedDeleteTid
      ) {
        heldServerFrames = {
          kind: "delete",
          tid: armedDeleteTid,
          frames: [message],
        };
        armedDeleteTid = null;
        return;
      }

      deliverServerFrame(message);
    };

    const relayServerFrame = (message: SocketMessage) => {
      if (replayingServerFrames) {
        deferredServerFrames.push(message);
        return;
      }
      consumeServerFrame(message);
    };

    const replayHeldFrames = (frames: SocketMessage[]) => {
      replayingServerFrames = true;
      try {
        for (const frame of frames) deliverServerFrame(frame);
        while (deferredServerFrames.length > 0) {
          consumeServerFrame(deferredServerFrames.shift()!);
        }
      } finally {
        replayingServerFrames = false;
      }
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      const observed = recordControl("browser-to-server", frame);
      if (frame?.type === "create_task") {
        const correlationId =
          typeof frame.correlation_id === "string"
            ? frame.correlation_id
            : null;
        createRequests.push({
          correlationId,
          content: frame.content,
          order: observed?.order ?? 0,
        });
        if (
          createCorrelation === null &&
          correlationId !== null &&
          isEmptyCreateContent(frame.content)
        )
          createCorrelation = correlationId;
      }
      if (frame?.type === "delete_task" && typeof frame.tid === "number")
        deleteRequests.push(frame.tid);
      if (frame?.type === "message") {
        rawMessages.push({
          tid: typeof frame.tid === "number" ? frame.tid : null,
          nonce:
            typeof frame.correlation_id === "string"
              ? frame.correlation_id
              : null,
          content: frame.content,
          order: observed?.order ?? 0,
        });
      }
      serverSocket.send(message);
    });
    serverSocket.onMessage(relayServerFrame);

    releaseCreationAck = () => {
      if (heldServerFrames?.kind !== "create")
        throw new Error("task_created was not being held before release");
      const { frames } = heldServerFrames;
      heldServerFrames = null;
      replayHeldFrames(frames);
    };
    releaseProjectTypesResponse = () => {
      if (heldServerFrames?.kind !== "project-types")
        throw new Error(
          "project_task_types_list was not being held before release",
        );
      const { frames } = heldServerFrames;
      heldServerFrames = null;
      replayHeldFrames(frames);
    };
    releaseAcceptanceHold = (tid: number) => {
      if (
        heldServerFrames?.kind !== "acceptance" ||
        heldServerFrames.tid !== tid
      )
        throw new Error("Accepting task_updated was not being held");
      const { frames } = heldServerFrames;
      heldServerFrames = null;
      replayHeldFrames(frames);
    };
    armDeletionAck = (tid: number) => {
      if (armedDeleteTid !== null || heldServerFrames?.kind === "delete")
        throw new Error(
          "task_deleted acknowledgement is already armed or held",
        );
      armedDeleteTid = tid;
    };
    releaseDeletionAck = (tid: number) => {
      if (heldServerFrames?.kind !== "delete" || heldServerFrames.tid !== tid)
        throw new Error("task_deleted was not being held before release");
      const { frames } = heldServerFrames;
      heldServerFrames = null;
      replayHeldFrames(frames);
    };
  });

  const proxy: DraftRaceProxy = {
    createRequests,
    deleteRequests,
    taskCreated,
    taskDeleted,
    bootstrapComplete: () =>
      [
        "workspaces_list",
        "task_types_list",
        "agents_list",
        "server_status",
        "notices_list",
      ].every((type) => bootstrapFrames.has(type)) && tasksListComplete,
    createdTid: (correlationId) =>
      taskCreated.find((task) => task.correlationId === correlationId)?.tid ??
      null,
    controls: (type, query) =>
      observations.filter(
        (observation) =>
          observation.frame.type === type &&
          (query?.direction === undefined ||
            observation.direction === query.direction) &&
          (query?.tid === undefined ||
            controlTargetsTid(observation.frame, query.tid)),
      ),
    rawMessages: () => rawMessages,
    isCreateAckHeld: (correlationId) =>
      heldServerFrames?.kind === "create" &&
      heldServerFrames.correlationId === correlationId,
    isDeleteAckHeld: (tid) =>
      heldServerFrames?.kind === "delete" && heldServerFrames.tid === tid,
    isProjectTypesResponseHeld: () =>
      heldServerFrames?.kind === "project-types",
    isAcceptanceHeld: (tid) =>
      heldServerFrames?.kind === "acceptance" && heldServerFrames.tid === tid,
    heldProjectTypesResponse: () =>
      heldServerFrames?.kind === "project-types"
        ? heldServerFrames.frame
        : null,
    wasServerControlDelivered: (type, tid) =>
      observations.some(
        (observation) =>
          observation.direction === "server-delivered" &&
          observation.frame.type === type &&
          (tid === undefined || controlTargetsTid(observation.frame, tid)),
      ),
    armProjectTypesResponseHold: () => {
      if (
        projectTypesResponseHoldArmed ||
        heldServerFrames?.kind === "project-types"
      )
        throw new Error(
          "project_task_types_list response is already armed or held",
        );
      projectTypesResponseHoldArmed = true;
    },
    armAcceptanceHold: (tid) => {
      if (armedAcceptanceTid !== null || heldServerFrames !== null)
        throw new Error("Server frame hold is already armed or active");
      armedAcceptanceTid = tid;
    },
    armDeleteAckHold: (tid) => armDeletionAck(tid),
    releaseProjectTypesResponse: () => releaseProjectTypesResponse(),
    releaseCreateAck: () => releaseCreationAck(),
    releaseAcceptanceHold: (tid) => releaseAcceptanceHold(tid),
    releaseDeleteAck: (tid) => releaseDeletionAck(tid),
  };

  return proxy;
}

function requireCorrelation(request: CreateRequest, label: string): string {
  if (!request.correlationId)
    throw new Error(`${label} create_task did not carry a correlation_id`);
  return request.correlationId;
}

async function waitForCreatedTid(
  proxy: DraftRaceProxy,
  correlationId: string,
): Promise<number> {
  await expect.poll(() => proxy.createdTid(correlationId)).not.toBeNull();
  const tid = proxy.createdTid(correlationId);
  if (tid === null)
    throw new Error(`task_created missing for ${correlationId}`);
  return tid;
}

async function expectControlledTextarea(page: Page, value: string) {
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(value);
}

async function expectNoTaskLoading(page: Page) {
  await expect(
    page.locator(".session-empty:visible", { hasText: "Loading task" }),
  ).toHaveCount(0);
}

async function observeLoadingFallback(page: Page) {
  await page.evaluate(() => {
    const testWindow = window as Window & {
      __cydoDraftLifecycleLoadingFallback?: {
        state: { sawLoading: boolean; mutations: number };
        observer: MutationObserver;
      };
    };
    testWindow.__cydoDraftLifecycleLoadingFallback?.observer.disconnect();
    const state = { sawLoading: false, mutations: 0 };

    const isVisibleThroughAncestors = (element: Element) => {
      for (
        let current: Element | null = element;
        current !== null;
        current = current.parentElement
      ) {
        const style = getComputedStyle(current);
        if (
          (current instanceof HTMLElement && current.hidden) ||
          style.display === "none" ||
          style.visibility !== "visible"
        )
          return false;
      }
      return true;
    };

    const hasVisibleGeometry = (element: Element) =>
      Array.from(element.getClientRects()).some(
        ({ width, height }) => width > 0 && height > 0,
      );

    const isMeasurementNode = (node: Node) =>
      (node instanceof Element ? node : node.parentElement)?.closest(
        "[data-cydo-loading-measurement]",
      ) !== null;

    const isLoadingFallback = (element: Element) =>
      element.matches(".session-empty") &&
      element.textContent?.includes("Loading task") === true;

    const isVisibleLoadingFallback = (element: Element) =>
      isLoadingFallback(element) &&
      element.isConnected &&
      isVisibleThroughAncestors(element) &&
      hasVisibleGeometry(element);

    const inspectElement = (element: Element) => {
      if (!isMeasurementNode(element) && isVisibleLoadingFallback(element))
        state.sawLoading = true;
    };
    const inspectNode = (node: Node) => {
      if (isMeasurementNode(node)) return;
      if (node instanceof Element) {
        inspectElement(node);
        for (const element of node.querySelectorAll(".session-empty"))
          inspectElement(element);
        const parent = node.closest(".session-empty");
        if (parent) inspectElement(parent);
        return;
      }
      const parent = node.parentElement?.closest(".session-empty");
      if (parent) inspectElement(parent);
    };

    const pathFromRoot = (root: Node, descendant: Node) => {
      const path: number[] = [];
      for (let current = descendant; current !== root; ) {
        const parent = current.parentNode;
        if (!parent) return null;
        const index = Array.from(parent.childNodes).indexOf(current);
        if (index === -1) return null;
        path.unshift(index);
        current = parent;
      }
      return path;
    };

    const nodeAtPath = (root: Node, path: number[]) => {
      let current: Node | null = root;
      for (const index of path) current = current?.childNodes[index] ?? null;
      return current;
    };

    const inspectAddedSubtree = (node: Node, insertionTarget: Node) => {
      if (!(node instanceof Element) || isMeasurementNode(node)) return;
      const candidates = [
        ...(isLoadingFallback(node) ? [node] : []),
        ...Array.from(node.querySelectorAll(".session-empty")).filter(
          isLoadingFallback,
        ),
      ];
      if (candidates.length === 0) return;

      if (node.isConnected) {
        for (const candidate of candidates) inspectElement(candidate);
        return;
      }
      if (!(insertionTarget instanceof Element) || !insertionTarget.isConnected)
        return;

      const paths = candidates.map((candidate) =>
        pathFromRoot(node, candidate),
      );
      const measurement = node.cloneNode(true) as Element;
      measurement.setAttribute("data-cydo-loading-measurement", "");
      measurement.setAttribute("aria-hidden", "true");
      measurement.setAttribute("inert", "");
      insertionTarget.append(measurement);
      try {
        for (const path of paths) {
          const candidate = path && nodeAtPath(measurement, path);
          if (
            candidate instanceof Element &&
            isVisibleLoadingFallback(candidate)
          )
            state.sawLoading = true;
        }
      } finally {
        measurement.remove();
      }
    };
    const inspect = () => {
      for (const element of document.querySelectorAll(".session-empty"))
        inspectElement(element);
    };
    const observer = new MutationObserver((records) => {
      state.mutations += records.length;
      for (const record of records) {
        if (record.type === "childList") {
          for (const node of record.addedNodes)
            inspectAddedSubtree(node, record.target);
        }
        inspectNode(record.target);
      }
      inspect();
    });
    observer.observe(document.documentElement, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
    });
    inspect();
    testWindow.__cydoDraftLifecycleLoadingFallback = { state, observer };
  });
}

async function loadingFallbackWasObserved(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const state = (
      window as Window & {
        __cydoDraftLifecycleLoadingFallback?: {
          state: { sawLoading: boolean };
        };
      }
    ).__cydoDraftLifecycleLoadingFallback;
    if (!state) throw new Error("loading-fallback observer is unavailable");
    return state.state.sawLoading;
  });
}

async function loadingFallbackMutationCount(page: Page): Promise<number> {
  return page.evaluate(() => {
    const state = (
      window as Window & {
        __cydoDraftLifecycleLoadingFallback?: {
          state: { mutations: number };
        };
      }
    ).__cydoDraftLifecycleLoadingFallback;
    if (!state) throw new Error("loading-fallback observer is unavailable");
    return state.state.mutations;
  });
}

async function verifyTransientLoadingFallbackObservation(page: Page) {
  await observeLoadingFallback(page);
  await page.evaluate(() => {
    const fallback = document.createElement("div");
    fallback.className = "session-empty";
    fallback.textContent = "Loading task";
    fallback.style.display = "block";
    fallback.style.visibility = "visible";
    fallback.style.position = "fixed";
    fallback.style.width = "16px";
    fallback.style.height = "16px";
    document.body.append(fallback);
    fallback.remove();
  });
  await expect.poll(() => loadingFallbackWasObserved(page)).toBe(true);
  await observeLoadingFallback(page);
  await page.evaluate(() => {
    const fallback = document.createElement("div");
    fallback.className = "session-empty";
    fallback.textContent = "Loading task";
    fallback.style.display = "block";
    fallback.style.visibility = "visible";
    fallback.style.position = "fixed";
    fallback.style.width = "0";
    fallback.style.height = "0";
    fallback.style.overflow = "hidden";
    document.body.append(fallback);
    fallback.remove();
  });
  await expect
    .poll(() => loadingFallbackMutationCount(page))
    .toBeGreaterThan(0);
  await expectNoObservedLoadingFallback(page);
  await observeLoadingFallback(page);
  await page.evaluate(() => {
    const fallback = document.createElement("div");
    fallback.className = "session-empty";
    fallback.textContent = "Loading task";
    fallback.style.display = "block";
    fallback.style.visibility = "hidden";
    fallback.style.position = "fixed";
    fallback.style.width = "16px";
    fallback.style.height = "16px";
    document.body.append(fallback);
    fallback.remove();
  });
  await expect
    .poll(() => loadingFallbackMutationCount(page))
    .toBeGreaterThan(0);
  await expectNoObservedLoadingFallback(page);
  await observeLoadingFallback(page);
  await page.evaluate(() => {
    const fallback = document.createElement("div");
    fallback.className = "session-empty";
    fallback.textContent = "Loading task";
    fallback.style.display = "block";
    fallback.style.visibility = "collapse";
    fallback.style.position = "fixed";
    fallback.style.width = "16px";
    fallback.style.height = "16px";
    document.body.append(fallback);
    fallback.remove();
  });
  await expect
    .poll(() => loadingFallbackMutationCount(page))
    .toBeGreaterThan(0);
  await expectNoObservedLoadingFallback(page);
  await page.evaluate(() => {
    const stylesheet = document.createElement("style");
    stylesheet.id = "cydo-loading-probe-stylesheet";
    stylesheet.textContent = ".cydo-loading-probe-hidden { display: none; }";
    document.head.append(stylesheet);
  });
  await observeLoadingFallback(page);
  await page.evaluate(() => {
    const ancestor = document.createElement("div");
    ancestor.className = "cydo-loading-probe-hidden";
    const fallback = document.createElement("div");
    fallback.className = "session-empty";
    fallback.textContent = "Loading task";
    fallback.style.position = "fixed";
    fallback.style.width = "16px";
    fallback.style.height = "16px";
    ancestor.append(fallback);
    document.body.append(ancestor);
    ancestor.remove();
  });
  await expect
    .poll(() => loadingFallbackMutationCount(page))
    .toBeGreaterThan(0);
  await expectNoObservedLoadingFallback(page);
  await page.evaluate(() => {
    document.getElementById("cydo-loading-probe-stylesheet")?.remove();
  });
  await observeLoadingFallback(page);
}

async function expectNoObservedLoadingFallback(page: Page) {
  const sawLoading = await loadingFallbackWasObserved(page);
  expect(sawLoading).toBe(false);
}

async function observeBrowserNavigation(page: Page) {
  await page.evaluate(() => {
    const testWindow = window as Window & {
      __cydoDraftLifecycleNavigation?: {
        state: { events: BrowserNavigation[] };
        restore: () => void;
      };
    };
    testWindow.__cydoDraftLifecycleNavigation?.restore();
    const state = { events: [] as BrowserNavigation[] };
    const record = (kind: BrowserNavigation["kind"]) => {
      state.events.push({ kind, pathname: location.pathname });
    };
    const pushState = history.pushState;
    const replaceState = history.replaceState;
    const popstate = () => record("popstate");
    history.pushState = (...args) => {
      pushState.apply(history, args);
      record("pushState");
    };
    history.replaceState = (...args) => {
      replaceState.apply(history, args);
      record("replaceState");
    };
    addEventListener("popstate", popstate);
    testWindow.__cydoDraftLifecycleNavigation = {
      state,
      restore: () => {
        history.pushState = pushState;
        history.replaceState = replaceState;
        removeEventListener("popstate", popstate);
      },
    };
  });
}

async function browserNavigations(page: Page): Promise<BrowserNavigation[]> {
  return page.evaluate(() => {
    const state = (
      window as Window & {
        __cydoDraftLifecycleNavigation?: {
          state: { events: BrowserNavigation[] };
        };
      }
    ).__cydoDraftLifecycleNavigation;
    if (!state) throw new Error("navigation observer is unavailable");
    return state.state.events;
  });
}

async function expectNoNavigationToTid(page: Page, tid: number) {
  const tidRoute = new RegExp(`/task/${tid}(?:/|$)`);
  expect(
    (await browserNavigations(page)).filter(({ pathname }) =>
      tidRoute.test(pathname),
    ),
  ).toEqual([]);
}

async function waitForServerDelivery(
  proxy: DraftRaceProxy,
  type: string,
  tid?: number,
) {
  await expect
    .poll(() => proxy.wasServerControlDelivered(type, tid))
    .toBe(true);
}

async function settleDeliveredServerFrame(page: Page) {
  await page.evaluate(
    () =>
      new Promise<void>((resolve) => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => resolve());
        });
      }),
  );
}

function contentContainsText(content: unknown, text: string): boolean {
  return (
    Array.isArray(content) &&
    content.some(
      (block) =>
        typeof block === "object" &&
        block !== null &&
        (block as { type?: unknown; text?: unknown }).type === "text" &&
        (block as { text?: unknown }).text === text,
    )
  );
}

async function observeDeleteAcknowledgementProcessing(page: Page) {
  await page.evaluate(() => {
    const storage = Storage.prototype as Storage & {
      __cydoDraftDeleteSetItemWrapped?: boolean;
      __cydoDraftDeleteOriginalSetItem?: Storage["setItem"];
    };
    const testWindow = window as Window & {
      __cydoDraftDeleteOutboxWrites?: number;
    };
    testWindow.__cydoDraftDeleteOutboxWrites = 0;
    if (storage.__cydoDraftDeleteSetItemWrapped) return;

    storage.__cydoDraftDeleteOriginalSetItem = storage.setItem;
    storage.setItem = function (key: string, value: string) {
      if (key === "cydo.outbox.v1") {
        testWindow.__cydoDraftDeleteOutboxWrites =
          (testWindow.__cydoDraftDeleteOutboxWrites ?? 0) + 1;
      }
      storage.__cydoDraftDeleteOriginalSetItem!.call(this, key, value);
    };
    storage.__cydoDraftDeleteSetItemWrapped = true;
  });
}

async function waitForDeleteAcknowledgementProcessing(page: Page) {
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as Window & {
              __cydoDraftDeleteOutboxWrites?: number;
            }
          ).__cydoDraftDeleteOutboxWrites ?? 0,
      ),
    )
    .toBeGreaterThan(0);
  await page.evaluate(
    () =>
      new Promise<void>((resolve) => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => resolve());
        });
      }),
  );
}

async function observeStaleProjection(
  page: Page,
  tid: number,
  watchImmediately = true,
) {
  await page.evaluate(
    ({ staleTid, watch }) => {
      const selector = `.sidebar-item[data-tid="${staleTid}"]`;
      const state = { sawRoute: false, sawSidebar: false, watch };
      const inspect = () => {
        const routeProjected = new RegExp(`/task/${staleTid}(?:/|$)`).test(
          location.pathname,
        );
        const sidebarProjected = document.querySelector(selector) !== null;
        if (state.watch && routeProjected) state.sawRoute = true;
        if (state.watch && sidebarProjected) state.sawSidebar = true;
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          for (const node of record.addedNodes) {
            if (
              state.watch &&
              node instanceof Element &&
              (node.matches(selector) || node.querySelector(selector))
            ) {
              state.sawSidebar = true;
            }
          }
        }
        inspect();
      });
      observer.observe(document.documentElement, {
        subtree: true,
        childList: true,
        attributes: true,
      });
      inspect();
      (
        window as Window & {
          __cydoDraftLifecycleStaleProjection?: {
            state: typeof state;
            observer: MutationObserver;
          };
        }
      ).__cydoDraftLifecycleStaleProjection = { state, observer };
    },
    { staleTid: tid, watch: watchImmediately },
  );
}

async function expectStaleProjectionAbsentAndWatch(page: Page, tid: number) {
  const staleRoute = new RegExp(`/task/${tid}(?:/|$)`);
  const staleSidebar = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(page).not.toHaveURL(staleRoute);
  await expect(staleSidebar).toHaveCount(0);
  await page.evaluate(
    ({ staleTid }) => {
      const state = (
        window as Window & {
          __cydoDraftLifecycleStaleProjection?: {
            state: {
              sawRoute: boolean;
              sawSidebar: boolean;
              watch: boolean;
            };
          };
        }
      ).__cydoDraftLifecycleStaleProjection;
      if (!state) throw new Error("stale-projection observer is unavailable");
      const selector = `.sidebar-item[data-tid="${staleTid}"]`;
      if (
        new RegExp(`/task/${staleTid}(?:/|$)`).test(location.pathname) ||
        document.querySelector(selector) !== null
      )
        throw new Error(
          "stale task remained projected while deletion was held",
        );
      state.state.watch = true;
    },
    { staleTid: tid },
  );
}

async function expectNoStaleProjection(page: Page, tid: number) {
  await expect(page).not.toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(() => {
        const state = (
          window as Window & {
            __cydoDraftLifecycleStaleProjection?: {
              state: {
                sawRoute: boolean;
                sawSidebar: boolean;
              };
            };
          }
        ).__cydoDraftLifecycleStaleProjection;
        if (!state) throw new Error("stale-projection observer is unavailable");
        return {
          sawRoute: state.state.sawRoute,
          sawSidebar: state.state.sawSidebar,
        };
      }),
    )
    .toEqual({ sawRoute: false, sawSidebar: false });
}

test("typing before held project metadata creates once after resolution", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  proxy.armProjectTypesResponseHold();
  await enterSession(page);

  await expect.poll(() => proxy.isProjectTypesResponseHeld()).toBe(true);
  const metadata = proxy.heldProjectTypesResponse();
  if (!metadata || !Array.isArray(metadata.entry_points)) {
    throw new Error("Held project metadata did not contain entry points");
  }
  const validEntryPoints = metadata.entry_points.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) return [];
    const name = (entry as { name?: unknown }).name;
    return typeof name === "string" ? [name] : [];
  });
  if (validEntryPoints.length === 0) {
    throw new Error(
      "Held project metadata did not expose a usable entry point",
    );
  }

  const input = page.locator(".input-textarea:visible");
  await expect(input).toBeEnabled();
  await expect(page.locator(".task-type-row:visible").first()).toBeDisabled();
  await expect(page.locator(".agent-picker:visible")).toBeDisabled();
  const prompt = "typed while project metadata is held";
  await input.fill(prompt);
  await expect(input).toHaveValue(prompt);
  await expect(page.locator(".btn-send:visible")).toBeDisabled();
  await page.waitForTimeout(50);
  expect(
    proxy.controls("create_task", { direction: "browser-to-server" }),
  ).toHaveLength(0);

  proxy.releaseProjectTypesResponse();

  await expect
    .poll(
      () =>
        proxy.controls("create_task", { direction: "browser-to-server" })
          .length,
    )
    .toBe(1);
  const createControl = proxy.controls("create_task", {
    direction: "browser-to-server",
  })[0]!;
  const entryPoint = createControl.frame.entry_point;
  if (typeof entryPoint !== "string") {
    throw new Error("Resolved create_task did not carry an entry point");
  }
  expect(validEntryPoints).toContain(entryPoint);
  const correlationId =
    typeof createControl.frame.correlation_id === "string"
      ? createControl.frame.correlation_id
      : null;
  if (!correlationId) {
    throw new Error("Resolved create_task did not carry a correlation_id");
  }
  const tid = await waitForCreatedTid(proxy, correlationId);
  expect(proxy.isCreateAckHeld(correlationId)).toBe(true);

  proxy.releaseCreateAck();
  await waitForServerDelivery(proxy, "task_created", tid);
  await waitForServerDelivery(proxy, "focus_hint", tid);
  await expect
    .poll(
      () =>
        proxy.controls("set_draft", {
          tid,
          direction: "browser-to-server",
        }).length,
    )
    .toBe(1);
  expect(
    proxy.controls("set_draft", {
      tid,
      direction: "browser-to-server",
    })[0]!.frame.content,
  ).toBe(prompt);
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expectControlledTextarea(page, prompt);
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(1);
  expect(
    proxy.controls("create_task", { direction: "browser-to-server" }),
  ).toHaveLength(1);
});

test("clear and retype creates a successor while the original create is held", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("draft A that must never be projected");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);
  await verifyTransientLoadingFallbackObservation(page);
  await observeStaleProjection(page, tidA);

  await input.fill("");
  await input.fill("replacement B stays controlled");
  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);

  proxy.armDeleteAckHold(tidA);
  await expect.poll(() => proxy.createRequests.length).toBe(2);
  const createB = proxy.createRequests[1]!;
  expect(createB.content).toEqual([]);
  const correlationB = requireCorrelation(createB, "B");
  expect(correlationB).not.toBe(correlationA);
  const tidB = await waitForCreatedTid(proxy, correlationB);
  expect(tidB).not.toBe(tidA);

  proxy.releaseCreateAck();

  await expect.poll(() => proxy.deleteRequests).toEqual([tidA]);
  await expect.poll(() => proxy.isDeleteAckHeld(tidA)).toBe(true);
  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectNoStaleProjection(page, tidA);

  proxy.releaseDeleteAck(tidA);
  await waitForServerDelivery(proxy, "task_deleted", tidA);

  await expect(page).toHaveURL(new RegExp(`/task/${tidB}(?:/|$)`));

  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectNoStaleProjection(page, tidA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  expect(proxy.deleteRequests).toEqual([tidA]);
  expect(proxy.taskDeleted.filter((tid) => tid === tidA)).toHaveLength(1);
});

test("clear replaces an unacknowledged draft with a usable blank form", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("draft A that will be cleared");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);
  await observeLoadingFallback(page);
  await observeStaleProjection(page, tidA);

  const previousInput = await input.elementHandle();
  await input.fill("");
  await expectControlledTextarea(page, "");
  expect(await previousInput!.evaluate((element) => element.isConnected)).toBe(
    false,
  );
  await previousInput!.dispose();
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  expect(proxy.createRequests).toHaveLength(1);

  proxy.armDeleteAckHold(tidA);
  proxy.releaseCreateAck();

  await expect.poll(() => proxy.deleteRequests).toEqual([tidA]);
  await expect.poll(() => proxy.isDeleteAckHeld(tidA)).toBe(true);
  expect(proxy.createRequests).toHaveLength(1);
  await expectControlledTextarea(page, "");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectNoStaleProjection(page, tidA);

  await observeDeleteAcknowledgementProcessing(page);
  proxy.releaseDeleteAck(tidA);

  await waitForDeleteAcknowledgementProcessing(page);
  await expectControlledTextarea(page, "");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectNoStaleProjection(page, tidA);
  const blankInput = page.locator(".input-textarea:visible");
  await blankInput.click();
  await expect(blankInput).toBeFocused();
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([tidA]);
  expect(proxy.taskDeleted.filter((tid) => tid === tidA)).toHaveLength(1);
});

test("post-tid clear and retype creates a successor while deletion is held", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("post-tid draft A");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);

  proxy.releaseCreateAck();
  await waitForServerDelivery(proxy, "task_created", tidA);
  await waitForServerDelivery(proxy, "focus_hint", tidA);
  await settleDeliveredServerFrame(page);
  await expectControlledTextarea(page, "post-tid draft A");
  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );

  await observeLoadingFallback(page);
  await observeBrowserNavigation(page);
  await observeStaleProjection(page, tidA, false);
  proxy.armDeleteAckHold(tidA);
  await input.fill("");
  await input.fill("post-tid replacement B");

  await expect.poll(() => proxy.deleteRequests).toEqual([tidA]);
  await expect.poll(() => proxy.isDeleteAckHeld(tidA)).toBe(true);
  await expectControlledTextarea(page, "post-tid replacement B");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectStaleProjectionAbsentAndWatch(page, tidA);
  await expectNoNavigationToTid(page, tidA);

  await expect.poll(() => proxy.createRequests.length).toBe(2);
  const createB = proxy.createRequests[1]!;
  expect(createB.content).toEqual([]);
  const correlationB = requireCorrelation(createB, "B");
  expect(correlationB).not.toBe(correlationA);
  const tidB = await waitForCreatedTid(proxy, correlationB);
  expect(tidB).not.toBe(tidA);

  proxy.releaseDeleteAck(tidA);
  await waitForServerDelivery(proxy, "task_deleted", tidA);

  await expect(page).toHaveURL(new RegExp(`/task/${tidB}(?:/|$)`));

  await expectControlledTextarea(page, "post-tid replacement B");
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await expectNoStaleProjection(page, tidA);
  await expectNoNavigationToTid(page, tidA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  expect(proxy.deleteRequests).toEqual([tidA]);
  expect(proxy.taskDeleted.filter((tid) => tid === tidA)).toHaveLength(1);
});

async function expectSubmittingComposer(page: Page, prompt: string) {
  await expect(page.locator(".task-type-picker:visible")).toBeVisible();
  const textarea = page.locator(".input-textarea:visible");
  await expect(textarea).toHaveValue(prompt);
  await expect(textarea).toBeDisabled();
  const submit = page.locator(".btn-send:visible");
  await expect(submit).toHaveText("Submitting…");
  await expect(submit).toBeDisabled();
}

test("submitting during a held empty create delivers one raw message after acknowledgement", async ({
  page,
  agentType,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("held empty create A");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);

  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  const prompt = 'Please reply with "held-create-submit-once"';
  await input.fill(prompt);
  await expectControlledTextarea(page, prompt);
  await page.locator(".btn-send:visible").click();

  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.createRequests[0]!.content).toEqual([]);
  expect(proxy.rawMessages()).toHaveLength(0);
  expect(
    proxy
      .controls("set_draft", { direction: "browser-to-server" })
      .filter((control) => control.frame.content === prompt),
  ).toHaveLength(0);

  await expectSubmittingComposer(page, prompt);
  proxy.releaseCreateAck();
  proxy.armAcceptanceHold(tidA);

  const messagesForTid = () =>
    proxy.rawMessages().filter(({ tid }) => tid === tidA);
  await expect.poll(() => messagesForTid().length).toBe(1);
  const rawMessages = messagesForTid();
  const outbound = { tid: tidA, direction: "browser-to-server" } as const;
  const historyRequests = proxy.controls("request_history", outbound);
  const entryPointUpdates = proxy.controls("set_entry_point", outbound);
  expect(historyRequests).toHaveLength(1);
  expect(entryPointUpdates).toHaveLength(1);
  expect(entryPointUpdates[0]!.frame.entry_point).toBe("blank");
  expect(historyRequests[0]!.order).toBeLessThan(rawMessages[0]!.order);
  expect(entryPointUpdates[0]!.order).toBeLessThan(rawMessages[0]!.order);
  expect(proxy.controls("set_agent_name", outbound)).toHaveLength(0);
  expect(proxy.controls("set_draft", outbound)).toHaveLength(0);
  expect(rawMessages).toHaveLength(1);
  expect(rawMessages[0]!.nonce).toBeTruthy();
  expect(rawMessages[0]!.nonce).not.toBe(correlationA);
  expect(contentContainsText(rawMessages[0]!.content, prompt)).toBe(true);
  expect(proxy.createRequests).toHaveLength(1);
  await expect.poll(() => proxy.isAcceptanceHeld(tidA)).toBe(true);
  await expect(page).toHaveURL(new RegExp(`/task/${tidA}$`));
  await expectSubmittingComposer(page, prompt);
  proxy.releaseAcceptanceHold(tidA);
  await expect(page.locator(".task-type-picker:visible")).toHaveCount(0);
  await expect(
    page.locator(".message.user-message", { hasText: prompt }),
  ).toHaveCount(1);
  await expect(assistantText(page, "held-create-submit-once")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  expect(proxy.createRequests).toHaveLength(1);
  expect(messagesForTid()).toEqual(rawMessages);
  expect(proxy.controls("set_draft", outbound)).toHaveLength(0);
});

test("submitted present draft never overlaps its user message in the ordinary composer", async ({
  page,
}) => {
  test.setTimeout(90_000);
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const prompt = 'Please reply with "no-submission-draft-overlap"';
  const input = page.locator(".input-textarea:visible");
  await input.fill(prompt);

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const create = proxy.createRequests[0]!;
  expect(create.content).toEqual([]);
  const correlationId = requireCorrelation(create, "persisted draft");
  const tid = await waitForCreatedTid(proxy, correlationId);
  expect(proxy.isCreateAckHeld(correlationId)).toBe(true);

  proxy.releaseCreateAck();
  await waitForServerDelivery(proxy, "task_created", tid);
  await waitForServerDelivery(proxy, "focus_hint", tid);
  await expectControlledTextarea(page, prompt);
  await expect
    .poll(() =>
      proxy
        .controls("set_draft", {
          tid,
          direction: "browser-to-server",
        })
        .some((control) => control.frame.content === prompt),
    )
    .toBe(true);

  proxy.armAcceptanceHold(tid);
  await page.locator(".btn-send:visible").click();

  await expect.poll(() => proxy.isAcceptanceHeld(tid)).toBe(true);
  await settleDeliveredServerFrame(page);
  await expectSubmittingComposer(page, prompt);
  expect(
    proxy.rawMessages().filter((message) => message.tid === tid),
  ).toHaveLength(1);
  const emptyDraftWrites = () =>
    proxy
      .controls("set_draft", { tid, direction: "browser-to-server" })
      .filter(({ frame }) => frame.content === "");
  expect(emptyDraftWrites()).toHaveLength(0);
  expect(
    proxy
      .controls("draft_updated", { tid, direction: "server-delivered" })
      .some(({ frame }) => frame.new_draft === ""),
  ).toBe(true);

  await page.evaluate(() => {
    const capture = () => {
      if (document.querySelector(".task-type-picker")) return;
      const textarea = [
        ...document.querySelectorAll<HTMLTextAreaElement>(".input-textarea"),
      ].find((input) => input.getClientRects().length > 0);
      if (!textarea) return;
      textarea.dataset.firstOrdinaryValue = textarea.value;
      observer.disconnect();
    };
    const observer = new MutationObserver(capture);
    observer.observe(document.body, { childList: true, subtree: true });
  });
  proxy.releaseAcceptanceHold(tid);
  await expect(page.locator(".task-type-picker:visible")).toHaveCount(0);
  await expect(input).toHaveAttribute("data-first-ordinary-value", "");
  await expect(
    page.locator(".message.user-message:visible", { hasText: prompt }),
  ).toHaveCount(1);
  await expect(input).toHaveValue("");
  expect(emptyDraftWrites()).toHaveLength(0);
});

test("detached acknowledgement persists the latest controlled form without routing", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("initial detached acknowledgement text");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);

  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  const selectedAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const latestText = "latest detached acknowledgement text\nsecond line";
  await input.fill(latestText);
  await expectControlledTextarea(page, latestText);

  await observeLoadingFallback(page);
  const projectUrl = page.url();
  await page.locator(".sidebar-back-btn:visible").click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator(".input-textarea:visible")).toHaveCount(0);
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([]);

  proxy.releaseCreateAck();

  await expect
    .poll(
      () =>
        proxy.controls("set_entry_point", {
          tid: tidA,
          direction: "browser-to-server",
        }).length,
    )
    .toBe(1);
  await expect
    .poll(
      () =>
        proxy.controls("set_agent_name", {
          tid: tidA,
          direction: "browser-to-server",
        }).length,
    )
    .toBe(1);
  await expect
    .poll(
      () =>
        proxy.controls("set_draft", {
          tid: tidA,
          direction: "browser-to-server",
        }).length,
    )
    .toBe(1);
  expect(
    proxy.controls("set_entry_point", {
      tid: tidA,
      direction: "browser-to-server",
    })[0]!.frame.entry_point,
  ).toBe("blank");
  expect(
    proxy.controls("set_agent_name", {
      tid: tidA,
      direction: "browser-to-server",
    })[0]!.frame.agent_name,
  ).toBe(selectedAgent);
  expect(
    proxy.controls("set_draft", {
      tid: tidA,
      direction: "browser-to-server",
    })[0]!.frame.content,
  ).toBe(latestText);
  expect(
    proxy.controls("focus_hint", {
      tid: tidA,
      direction: "server-received",
    }),
  ).toHaveLength(1);
  await waitForServerDelivery(proxy, "focus_hint", tidA);
  await settleDeliveredServerFrame(page);

  await expect(page).toHaveURL(/\/$/);
  const homeTask = page.locator(`a[href$="/task/${tidA}"]`);
  await expect(homeTask).toHaveCount(1);
  await expect(homeTask.locator(".sidebar-label")).toHaveText(
    "latest detached acknowledgement text",
  );
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([]);

  await page.goBack();
  await expect(page).toHaveURL(projectUrl);
  await expectControlledTextarea(page, "");
  await page.locator(`.sidebar-item[data-tid="${tidA}"]`).click();
  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  await expectControlledTextarea(page, latestText);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    selectedAgent,
  );
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.createdTid(correlationA)).toBe(tidA);
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
});

test("returning before acknowledgement promotes the same attached composition", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  const text = "return before acknowledgement text";
  await input.fill(text);
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateAckHeld(correlationA)).toBe(true);
  await observeLoadingFallback(page);

  await page.locator(".sidebar-back-btn:visible").click();
  await expect(page).toHaveURL(/\/$/);
  await page.goBack();
  await expectControlledTextarea(page, text);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([]);
  expect(requireCorrelation(proxy.createRequests[0]!, "returned A")).toBe(
    correlationA,
  );

  await observeBrowserNavigation(page);
  expect(await browserNavigations(page)).toEqual([]);

  proxy.releaseCreateAck();
  await waitForServerDelivery(proxy, "task_created", tidA);
  await waitForServerDelivery(proxy, "focus_hint", tidA);
  await settleDeliveredServerFrame(page);

  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  await expectControlledTextarea(page, text);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  expect(
    proxy.controls("focus_hint", {
      tid: tidA,
      direction: "server-delivered",
    }),
  ).toHaveLength(1);
  const promotedNavigations = (await browserNavigations(page)).filter(
    ({ pathname }) => new RegExp(`/task/${tidA}(?:/|$)`).test(pathname),
  );
  expect(promotedNavigations).toHaveLength(1);
  expect(promotedNavigations[0]!.kind).toBe("replaceState");
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([]);
  await expectNoTaskLoading(page);
  await expectNoObservedLoadingFallback(page);
  await page.locator(".sidebar-new-task").click();
  await expectControlledTextarea(page, "");
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  expect(proxy.deleteRequests).toEqual([]);
});
