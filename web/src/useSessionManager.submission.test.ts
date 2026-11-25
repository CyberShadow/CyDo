import { DRAFT_SAVE_DELAY_MS } from "./draftReconciler";
import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  createControlledImageStore,
  type ControlledImageStore,
} from "./controlledImageStore";
import type { OutboxEntry } from "./outbox";
import type { AgnosticEvent, ControlMessage } from "./protocol";
import { reduceMessage, replaceHistoryBoundary } from "./sessionReducer";
import { replayStream, type ReplayOperation } from "./testing/replayStreams";
import type { TaskState } from "./types";
import { WriteBatch } from "./writeBatch";
import { deepFreeze } from "./testing/deepFreeze";
import type {
  DraftViewSnapshot,
  TaskManager,
  TaskSnapshotEntry,
} from "./useSessionManager";

const testState = vi.hoisted(() => {
  const state = {
    uuid: "submission-uuid",
    issuedUuids: new Set<string>(),
    nextUuid: 0,
    hidden: true,
    animationFrames: new Map<number, (timestamp: number) => void>(),
    nextAnimationFrame: 0,
    outboxEntries: [] as OutboxEntry[],
    outbox: {
      all: vi.fn(),
      add: vi.fn(),
      remove: vi.fn(),
      acceptSend: vi.fn(),
      acknowledgeDraft: vi.fn(),
      removeForTask: vi.fn(),
      byTid: vi.fn(),
    },
    route: {
      workspace: "source",
      project: "project",
      tid: null as string | null,
    },
    navigate: vi.fn(),
    addToast: vi.fn(),
    connection: null as {
      onTaskMessage:
        | ((
            tid: number,
            event: AgnosticEvent,
            seq?: number,
            ts?: number,
          ) => void)
        | null;
      onHistoryBoundaryReplaced: ((...args: unknown[]) => void) | null;
      onUnconfirmedUserMessage:
        | ((tid: number, event: AgnosticEvent, correlationId?: string) => void)
        | null;
      onAgentAck: ((tid: number, nonce: string) => void) | null;
      onControlMessage: ((message: ControlMessage) => void) | null;
      onStatusChange: ((connected: boolean) => void) | null;
      createTask: ReturnType<typeof vi.fn>;
      deleteTask: ReturnType<typeof vi.fn>;
      saveDraft: ReturnType<typeof vi.fn>;
      sendMessage: ReturnType<typeof vi.fn>;
      requestTaskTypes: ReturnType<typeof vi.fn>;
      requestHistory: ReturnType<typeof vi.fn>;
      setEntryPoint: ReturnType<typeof vi.fn>;
      setAgentName: ReturnType<typeof vi.fn>;
    } | null,
  };
  // The browser location changes synchronously; the router's render may lag.
  const renderedRoute = state.route;
  let navigatedPath: string | null = null;
  state.route = new Proxy(renderedRoute, {
    set(target, key, value) {
      navigatedPath = null;
      return Reflect.set(target, key, value);
    },
  });
  const renderedPath = () => {
    const { workspace, project, tid } = renderedRoute;
    const scope = `/${workspace}/${project}`;
    return tid === null ? scope : `${scope}/task/${tid}`;
  };
  vi.stubGlobal("location", {
    get pathname() {
      return navigatedPath ?? renderedPath();
    },
  });
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("crypto", {
    randomUUID: () => {
      if (state.issuedUuids.has(state.uuid))
        return `generated-${++state.nextUuid}`;
      state.issuedUuids.add(state.uuid);
      return state.uuid;
    },
  });
  vi.stubGlobal("document", {
    get hidden() {
      return state.hidden;
    },
    querySelector: () => null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  });
  vi.stubGlobal(
    "requestAnimationFrame",
    (callback: (timestamp: number) => void) => {
      const id = ++state.nextAnimationFrame;
      state.animationFrames.set(id, callback);
      return id;
    },
  );
  vi.stubGlobal("cancelAnimationFrame", (id: number) => {
    state.animationFrames.delete(id);
  });

  state.outbox.all.mockImplementation(() => [...state.outboxEntries]);
  state.outbox.add.mockImplementation((entry: OutboxEntry) => {
    state.outboxEntries = state.outboxEntries.filter(
      (candidate) =>
        candidate.nonce !== entry.nonce &&
        !(
          candidate.tid === entry.tid &&
          candidate.recoveredDraft !== undefined &&
          entry.recoveredDraft !== undefined
        ),
    );
    state.outboxEntries.push(entry);
  });
  state.outbox.remove.mockImplementation((nonce: string) => {
    state.outboxEntries = state.outboxEntries.filter(
      (entry) => entry.nonce !== nonce,
    );
  });
  state.outbox.acceptSend.mockImplementation((tid: number, nonce: string) => {
    state.outboxEntries = state.outboxEntries.filter(
      (entry) =>
        entry.tid !== tid ||
        entry.nonce !== nonce ||
        entry.recoveredDraft !== undefined,
    );
  });
  state.outbox.acknowledgeDraft.mockImplementation(
    (tid: number, nonce: string) => {
      state.outboxEntries = state.outboxEntries.filter(
        (entry) =>
          entry.tid !== tid ||
          entry.nonce !== nonce ||
          entry.recoveredDraft === undefined,
      );
    },
  );
  state.outbox.removeForTask.mockImplementation(
    (tid: number, keepRecoveredDraft = false) => {
      state.outboxEntries = state.outboxEntries.filter(
        (entry) =>
          entry.tid !== tid ||
          (keepRecoveredDraft && entry.recoveredDraft !== undefined),
      );
    },
  );
  state.outbox.byTid.mockImplementation((tid: number) =>
    state.outboxEntries.filter((entry) => entry.tid === tid),
  );
  return Object.assign(state, {
    renderedPath,
    navigateBrowser: (path: string) => {
      navigatedPath = path;
    },
  });
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({
    route: testState.navigate,
    path: testState.renderedPath(),
  }),
}));

vi.mock("./connection", () => {
  class MockConnection {
    onTaskMessage:
      | ((tid: number, event: AgnosticEvent, seq?: number, ts?: number) => void)
      | null = null;
    onHistoryBoundaryReplaced: ((...args: unknown[]) => void) | null = null;
    onUnconfirmedUserMessage: ((...args: unknown[]) => void) | null = null;
    onAgentAck: ((tid: number, nonce: string) => void) | null = null;
    onControlMessage: ((message: ControlMessage) => void) | null = null;
    onStatusChange: ((connected: boolean) => void) | null = null;
    onClientError: ((message: string) => void) | null = null;

    readonly connect = vi.fn();
    readonly disconnect = vi.fn(() => {
      this.onStatusChange?.(false);
    });
    readonly createTask = vi.fn();
    readonly deleteTask = vi.fn();
    readonly setEntryPoint = vi.fn();
    readonly setAgentName = vi.fn();
    readonly saveDraft = vi.fn();
    readonly sendMessage = vi.fn();
    readonly requestTaskTypes = vi.fn();
    readonly requestHistory = vi.fn(() => true);

    constructor() {
      testState.connection = this;
    }
  }

  return { Connection: MockConnection };
});

vi.mock("./outbox", () => ({ outbox: testState.outbox }));

import {
  getLiveTaskForTest,
  projectDraftTask,
  taskStateFromEntry,
  useTaskManager,
} from "./useSessionManager";

let manager: TaskManager | null = null;
let root: Element;
let imageStore: ControlledImageStore;

function seedEditorImage(editorId: string) {
  const entry = {
    resetToken: 0,
    generation: 0,
    images: [
      {
        id: "image",
        dataURL: "data:image/png;base64,aQ==",
        base64: "aQ==",
        mediaType: "image/png",
      },
    ],
    listeners: new Set<() => void>(),
  };
  imageStore.entries.set(editorId, entry);
  return entry;
}

let observedTasks: Set<TaskManager["tasks"]> | undefined;

function ManagerProbe() {
  manager = useTaskManager(testState.addToast, imageStore);
  observedTasks?.add(manager.tasks);
  return null;
}

function createRoot(): Element {
  return {
    nodeType: 1,
    namespaceURI: "http://www.w3.org/1999/xhtml",
    firstChild: null,
    childNodes: [],
    insertBefore: vi.fn(),
    removeChild: vi.fn(),
  } as unknown as Element;
}

async function renderManager(): Promise<TaskManager> {
  await act(() => {
    render(h(ManagerProbe, {}), root);
  });
  return manager!;
}

function commitRouteWithoutPassiveEffects(): TaskManager {
  render(h(ManagerProbe, {}), root);
  return manager!;
}

async function flushAnimationFrames(): Promise<void> {
  const callbacks = [...testState.animationFrames.values()];
  testState.animationFrames.clear();
  await act(() => {
    for (const callback of callbacks) callback(0);
  });
}

async function bootstrapProject(): Promise<void> {
  await renderManager();
  await act(() => {
    testState.connection!.onControlMessage?.({
      type: "workspaces_list",
      workspaces: [
        {
          name: "source",
          projects: [{ name: "project", path: "/source-project" }],
          default_agent: "agent",
          default_task_type: "entry",
        },
        {
          name: "other",
          projects: [{ name: "other-project", path: "/other-project" }],
          default_agent: "agent",
          default_task_type: "entry",
        },
      ],
    } satisfies ControlMessage);
    testState.connection!.onControlMessage?.({
      type: "task_types_list",
      entry_points: [
        {
          name: "entry",
          task_type: "blank",
          description: "",
          model_class: "",
          read_only: false,
        },
      ],
      type_info: [],
      default_task_type: "entry",
    } satisfies ControlMessage);
    testState.connection!.onControlMessage?.({
      type: "project_task_types_list",
      project_path: "/source-project",
      entry_points: [
        {
          name: "entry",
          task_type: "blank",
          description: "",
          model_class: "",
          read_only: false,
        },
      ],
      type_info: [],
    } satisfies ControlMessage);
    testState.connection!.onControlMessage?.({
      type: "agents_list",
      agents: [{ name: "agent", driver: "claude" }],
      default_agent: "agent",
    } satisfies ControlMessage);
  });
}

function workspaceCatalog(): ControlMessage {
  return {
    type: "workspaces_list",
    workspaces: [
      {
        name: "source",
        projects: [{ name: "project", path: "/source-project" }],
      },
    ],
  };
}

function globalTaskTypes(entryPoint: string, taskType: string): ControlMessage {
  return {
    type: "task_types_list",
    entry_points: [
      {
        name: `global-${entryPoint}`,
        task_type: taskType,
        description: "",
        model_class: "",
        read_only: false,
      },
    ],
    type_info: [],
    default_task_type: taskType,
  };
}

function projectTaskTypes(
  entryPoint: string,
  taskType: string,
): ControlMessage {
  return {
    type: "project_task_types_list",
    project_path: "/source-project",
    entry_points: [
      {
        name: entryPoint,
        task_type: taskType,
        description: "",
        model_class: "",
        read_only: false,
      },
    ],
    type_info: [],
  };
}

function agents(agent: string): ControlMessage {
  return {
    type: "agents_list",
    agents: [{ name: agent, driver: "claude" }],
    default_agent: agent,
  };
}

function emitGlobalDefaultProjectBootstrap(
  entryPoint: string,
  taskType: string,
  agent: string,
): void {
  const connection = testState.connection!;
  connection.onControlMessage?.(workspaceCatalog());
  connection.onControlMessage?.(globalTaskTypes(entryPoint, taskType));
  connection.onControlMessage?.(projectTaskTypes(entryPoint, taskType));
  connection.onControlMessage?.(agents(agent));
}

async function bootstrapGlobalDefaultProject(
  entryPoint: string,
  taskType: string,
  agent: string,
): Promise<void> {
  await renderManager();
  await act(() => {
    emitGlobalDefaultProjectBootstrap(entryPoint, taskType, agent);
  });
}

async function prepareSubmittingDraft(withImage = false) {
  await bootstrapProject();

  const draftManager = await renderManager();
  const draftView = draftManager.draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Project root draft view did not resolve");
  }
  const image = withImage ? seedEditorImage(draftView.editorId) : undefined;
  await act(() => {
    draftView.onTextChange("submit before acknowledgement");
    draftView.onSubmit("submit before acknowledgement", image?.images ?? []);
  });
  expect(testState.connection!.createTask).toHaveBeenCalledWith(
    "source",
    "/source-project",
    "entry",
    [
      { type: "text", text: "submit before acknowledgement" },
      ...(image
        ? [{ type: "image", data: "aQ==", media_type: "image/png" }]
        : []),
    ],
    "agent",
    "submission-uuid",
  );
  return image;
}

async function prepareEditableDraft(): Promise<DraftViewSnapshot> {
  await bootstrapProject();
  const draftView = (await renderManager()).draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Project root draft view did not resolve");
  }
  await act(() => {
    draftView.onTextChange("draft to delete");
  });
  await vi.waitFor(() => {
    expect(testState.connection!.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      "submission-uuid",
    );
  });
  await act(() => {
    testState.connection!.onControlMessage?.({
      type: "task_created",
      tid: 71,
      workspace: "source",
      project_path: "/source-project",
      correlation_id: "submission-uuid",
    } satisfies ControlMessage);
  });
  testState.route.tid = "71";
  const attached = (await renderManager()).draftView;
  if (!attached || attached.kind !== "resolved") {
    throw new Error("Created draft view did not attach to its task route");
  }
  return attached;
}

async function prepareCreatingDraft(): Promise<string> {
  await bootstrapProject();
  const draftView = (await renderManager()).draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Project root draft view did not resolve");
  }
  const correlationId = draftView.editorId.slice("composition:".length);
  await act(() => {
    draftView.onTextChange("editing create before acknowledgement");
  });
  await vi.waitFor(() => {
    expect(testState.connection!.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      correlationId,
    );
  });
  return correlationId;
}

function activeSnapshot(tid: number): TaskSnapshotEntry {
  return {
    tid,
    child_count: 0,
    alive: true,
    resumable: false,
    isProcessing: true,
    status: "active",
    workspace: "source",
    project_path: "/source-project",
  };
}

function persistedSnapshot(
  tid: number,
  draft = "persisted draft B",
): TaskSnapshotEntry {
  return {
    tid,
    child_count: 0,
    alive: false,
    resumable: false,
    isProcessing: false,
    status: "pending",
    workspace: "source",
    project_path: "/source-project",
    draft,
    task_type: "blank",
    entry_point: "entry",
    agent_name: "agent",
  };
}

function tasksList(
  tasks: TaskSnapshotEntry[],
  complete = true,
): ControlMessage {
  return { type: "tasks_list", complete, tasks };
}

async function seedOrdinaryTask(
  tid = 42,
  draft = "A",
): Promise<{
  connection: NonNullable<typeof testState.connection>;
  task: NonNullable<ReturnType<TaskManager["getByTid"]>>;
}> {
  await renderManager();
  const connection = testState.connection!;
  await act(() => {
    connection.onControlMessage?.(
      tasksList([
        {
          ...activeSnapshot(tid),
          isProcessing: false,
          draft,
        },
      ]),
    );
  });
  const task = manager!.getByTid(tid);
  if (!task) throw new Error("Expected seeded ordinary task");
  return { connection, task };
}

async function seedPreCatalogPersistedDraft(
  snapshot: TaskSnapshotEntry,
): Promise<DraftViewSnapshot> {
  testState.route.tid = String(snapshot.tid);
  await renderManager();
  const connection = testState.connection!;
  await act(() => {
    connection.onControlMessage?.(workspaceCatalog());
    connection.onControlMessage?.(globalTaskTypes("entry", "global-type"));
    connection.onControlMessage?.(agents("agent"));
    testState.uuid = `pre-catalog-${snapshot.tid}-uuid`;
    connection.onControlMessage?.({
      type: "tasks_list",
      complete: true,
      tasks: [snapshot],
    } satisfies ControlMessage);
    testState.uuid = "submission-uuid";
  });
  const view = (await renderManager()).draftView;
  if (!view || view.kind !== "resolved")
    throw new Error("Expected persisted editor before the catalog arrives");
  return view;
}

function acknowledgeSubmission(tid: number, correlationId = "submission-uuid") {
  testState.connection!.onControlMessage?.({
    type: "task_created",
    tid,
    workspace: "source",
    project_path: "/source-project",
    correlation_id: correlationId,
  } satisfies ControlMessage);
}

function acceptSubmission(tid: number) {
  testState.connection!.onControlMessage?.({
    type: "task_updated",
    task: { ...activeSnapshot(tid), draft: "" },
  });
}

function rejectSubmission(correlationId: string, tid?: number) {
  testState.connection!.onControlMessage?.({
    type: "cydo/submission_rejected",
    correlation_id: correlationId,
    ...(tid === undefined ? {} : { tid }),
    kind: "delivery_failed",
    reason: "Agent rejected the submission",
  });
}

describe("submission acknowledgement routing", () => {
  beforeEach(() => {
    testState.route.workspace = "source";
    testState.route.project = "project";
    testState.route.tid = null;
    testState.uuid = "submission-uuid";
    testState.issuedUuids.clear();
    testState.nextUuid = 0;
    testState.hidden = true;
    testState.animationFrames.clear();
    testState.nextAnimationFrame = 0;
    testState.connection = null;
    testState.navigate
      .mockReset()
      .mockImplementation(testState.navigateBrowser);
    testState.addToast.mockReset();
    testState.outboxEntries = [];
    for (const method of Object.values(testState.outbox)) method.mockClear();
    manager = null;
    root = createRoot();
    imageStore = createControlledImageStore();
  });

  afterEach(async () => {
    await act(() => {
      render(null, root);
    });
    vi.useRealTimers();
    testState.hidden = true;
    testState.animationFrames.clear();
  });

  it("allocates one composition UUID on New Task before typing", async () => {
    const allocateUuid = vi.spyOn(crypto, "randomUUID");
    try {
      await bootstrapProject();
      const initial = (await renderManager()).draftView;
      expect(initial).toMatchObject({
        editorId: "composition:submission-uuid",
        viewKey: "composition:submission-uuid",
        disabled: false,
        text: "",
      });
      expect((await renderManager()).draftView?.viewKey).toBe(initial?.viewKey);
      expect(allocateUuid).toHaveBeenCalledTimes(1);
      expect(testState.connection!.createTask).not.toHaveBeenCalled();
    } finally {
      allocateUuid.mockRestore();
    }
  });

  it("retires a composition cleared before its creation timer", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView;
    if (initial?.kind !== "resolved") throw new Error("Missing editor");

    await act(() => {
      initial.onTextChange("discard before the create timer");
      initial.onTextChange("");
    });
    const successor = (await renderManager()).draftView;
    expect(successor).toMatchObject({ text: "", remoteTid: null });
    expect(successor?.viewKey).not.toBe(initial.viewKey);
    expect(testState.connection!.createTask).not.toHaveBeenCalled();
    expect(testState.connection!.saveDraft).not.toHaveBeenCalled();
  });

  it("keeps project catalog lookups bounded while typing a new-task draft", async () => {
    const projects = [
      { name: "project", path: "/source-project" },
      ...Array.from({ length: 63 }, (_, index) => ({
        name: `project-${index}`,
        path: `/source-project-${index}`,
      })),
    ];
    const projectFind = vi.spyOn(projects, "find");
    let seedId = 0;
    const taskUuid = vi
      .spyOn(crypto, "randomUUID")
      .mockImplementation(() => `seed-${++seedId}-0000-0000-000000000000`);
    await renderManager();
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [
          {
            name: "source",
            projects,
            default_agent: "agent",
            default_task_type: "entry",
          },
        ],
      } satisfies ControlMessage);
      testState.connection!.onControlMessage?.(
        globalTaskTypes("entry", "blank"),
      );
      testState.connection!.onControlMessage?.(
        projectTaskTypes("entry", "blank"),
      );
      testState.connection!.onControlMessage?.(agents("agent"));
      testState.connection!.onControlMessage?.(
        tasksList(
          Array.from({ length: 160 }, (_, index) => ({
            ...activeSnapshot(index + 1),
            project_path: projects[index % projects.length]!.path,
          })),
        ),
      );
    });
    taskUuid.mockRestore();

    expect((await renderManager()).tasks.size).toBeGreaterThanOrEqual(160);
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Project draft did not resolve");
    }
    await act(() => {
      initial.onTextChange("a");
    });
    await vi.waitFor(() => {
      expect(testState.connection!.createTask).toHaveBeenCalled();
    });
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_created",
        tid: 10000,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "submission-uuid",
      } satisfies ControlMessage);
    });

    expect(projectFind).toHaveBeenCalled();
    // Each draft edit updates the task map and recomputes the sidebar projection.
    // Project lookup must not scale with the 160 tasks on every keystroke.
    projectFind.mockClear();
    for (const text of ["ab", "abc", "abcd"]) {
      const draft = (await renderManager()).draftView;
      if (!draft || draft.kind !== "resolved") {
        throw new Error("Project draft disappeared while typing");
      }
      await act(() => {
        draft.onTextChange(text);
      });
    }

    expect((await renderManager()).draftView).toMatchObject({ text: "abcd" });
    expect(projectFind.mock.calls.length).toBeLessThan(30);
  });

  it("merges arbitrary task-list packets and completes after the terminal merge", async () => {
    testState.route.tid = "2";
    await bootstrapProject();
    const connection = testState.connection!;
    const root = { ...activeSnapshot(1), child_count: 2 };
    const child = {
      ...activeSnapshot(2),
      child_count: 0,
      parent_tid: 1,
    };

    await act(() => {
      connection.onControlMessage?.(tasksList([root], false));
    });
    let partial = await renderManager();
    expect(partial.tasksLoaded).toBe(false);
    expect(partial.getByTid(1)).toMatchObject({ childCount: 2 });
    expect(partial.getByTid(2)).toBeUndefined();
    expect(partial.sidebarTasks).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ tid: 1, childCount: 2 }),
      ]),
    );
    expect(connection.requestHistory).not.toHaveBeenCalled();

    await act(() => {
      connection.onControlMessage?.(tasksList([], false));
      connection.onControlMessage?.(tasksList([child], true));
    });
    partial = await renderManager();
    expect(partial.tasksLoaded).toBe(true);
    expect(partial.getByTid(1)).toBeDefined();
    expect(partial.getByTid(2)).toMatchObject({ childCount: 0, parentTid: 1 });
    expect(connection.requestHistory).toHaveBeenCalledWith(2, "");
  });

  it("accepts one-packet empty completion and clears a partial snapshot on reconnect", async () => {
    await bootstrapProject();
    const connection = testState.connection!;

    await act(() => {
      connection.onControlMessage?.(tasksList([activeSnapshot(1)], false));
    });
    expect((await renderManager()).getByTid(1)).toBeDefined();
    expect(manager!.tasksLoaded).toBe(false);

    await act(() => {
      connection.onStatusChange?.(false);
    });
    let fresh = await renderManager();
    expect(fresh.tasks).toEqual(new Map());
    expect(fresh.tasksLoaded).toBe(false);

    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(tasksList([], true));
    });
    fresh = await renderManager();
    expect(fresh.tasks).toEqual(new Map());
    expect(fresh.tasksLoaded).toBe(true);
  });

  it("rejects malformed, duplicate, and post-terminal task-list packets before mutation", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    const first = activeSnapshot(1);

    await act(() => {
      connection.onControlMessage?.(tasksList([first], false));
    });
    expect(() =>
      connection.onControlMessage?.(tasksList([first], false)),
    ).toThrow("duplicate tid");
    expect(manager!.getByTid(1)).toBeDefined();

    const malformed = {
      type: "tasks_list",
      complete: false,
      tasks: {},
    } as unknown as ControlMessage;
    expect(() => connection.onControlMessage?.(malformed)).toThrow(
      "Invalid tasks list packet",
    );

    const invalid = {
      type: "tasks_list",
      complete: false,
      tasks: [{ ...activeSnapshot(2), child_count: -1 }],
    } as unknown as ControlMessage;
    expect(() => connection.onControlMessage?.(invalid)).toThrow(
      "Invalid tasks list entry",
    );
    expect(manager!.getByTid(2)).toBeUndefined();

    const invalidTid = {
      type: "tasks_list",
      complete: false,
      tasks: [{ ...activeSnapshot(3), tid: 0 }],
    } as unknown as ControlMessage;
    expect(() => connection.onControlMessage?.(invalidTid)).toThrow(
      "Invalid tasks list entry",
    );
    expect(manager!.getByTid(3)).toBeUndefined();

    expect(() =>
      connection.onControlMessage?.(
        tasksList([activeSnapshot(4), activeSnapshot(4)], false),
      ),
    ).toThrow("duplicate tid");
    expect(manager!.getByTid(4)).toBeUndefined();

    await act(() => {
      connection.onControlMessage?.(tasksList([activeSnapshot(5)], true));
    });
    expect(() =>
      connection.onControlMessage?.(tasksList([activeSnapshot(6)], false)),
    ).toThrow("after completion");
    expect(manager!.getByTid(6)).toBeUndefined();
  });

  it.each([
    [
      "a missing alive flag",
      (entry: TaskSnapshotEntry): Record<string, unknown> => {
        const { alive: _alive, ...withoutAlive } = entry;
        return withoutAlive;
      },
    ],
    [
      "a non-boolean resumable flag",
      (entry: TaskSnapshotEntry): Record<string, unknown> => ({
        ...entry,
        resumable: "false",
      }),
    ],
    [
      "a non-boolean isProcessing flag",
      (entry: TaskSnapshotEntry): Record<string, unknown> => ({
        ...entry,
        isProcessing: 1,
      }),
    ],
  ])(
    "rejects a task-list packet with %s without accepting any of its IDs",
    async (_description, invalidate) => {
      await bootstrapProject();
      const connection = testState.connection!;
      const first = activeSnapshot(21);
      const second = activeSnapshot(22);
      const malformed = {
        type: "tasks_list",
        complete: false,
        tasks: [first, invalidate(second)],
      } as unknown as ControlMessage;

      expect(() => connection.onControlMessage?.(malformed)).toThrow(
        "Invalid tasks list entry",
      );
      expect((await renderManager()).getByTid(first.tid)).toBeUndefined();
      expect(manager!.getByTid(second.tid)).toBeUndefined();

      await act(() => {
        connection.onControlMessage?.(tasksList([first, second]));
      });

      const accepted = await renderManager();
      expect(accepted.getByTid(first.tid)).toBeDefined();
      expect(accepted.getByTid(second.tid)).toBeDefined();
    },
  );

  it.each([
    ["a fractional tid", { tid: 23.5 }],
    ["a fractional child count", { child_count: 0.5 }],
  ])("rejects a task-list entry with %s", async (_description, overrides) => {
    await bootstrapProject();
    const connection = testState.connection!;
    const invalid = {
      type: "tasks_list",
      complete: false,
      tasks: [{ ...activeSnapshot(23), ...overrides }],
    } as unknown as ControlMessage;

    expect(() => connection.onControlMessage?.(invalid)).toThrow(
      "Invalid tasks list entry",
    );
    expect((await renderManager()).tasks).toEqual(new Map());
  });

  it("drops a task-list packet after its open epoch closes", async () => {
    await bootstrapProject();
    const connection = testState.connection!;

    await act(() => {
      connection.onStatusChange?.(false);
    });

    connection.onControlMessage?.(tasksList([activeSnapshot(24)]));
    await act(() => {});

    const closed = await renderManager();
    expect(closed.getByTid(24)).toBeUndefined();
    expect(closed.tasksLoaded).toBe(false);
  });

  it("reuses a task ID after reconnect discards its partial epoch", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    const task = activeSnapshot(25);

    await act(() => {
      connection.onControlMessage?.(tasksList([task], false));
    });
    expect((await renderManager()).getByTid(task.tid)).toBeDefined();

    await act(() => {
      connection.onStatusChange?.(false);
    });
    expect((await renderManager()).getByTid(task.tid)).toBeUndefined();

    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(tasksList([task]));
    });

    const reconnected = await renderManager();
    expect(reconnected.getByTid(task.tid)).toBeDefined();
    expect(reconnected.tasksLoaded).toBe(true);
  });

  it("defers outbox reconciliation until a terminal packet proves the task set", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
    });
    testState.outboxEntries = [
      {
        tid: 91,
        nonce: "later-packet-outbox",
        content: [{ type: "text", text: "arrives later" }],
        createdAt: 0,
      },
    ];

    await act(() => {
      connection.onControlMessage?.(tasksList([], false));
    });
    await renderManager();
    expect(testState.outbox.remove).not.toHaveBeenCalled();
    expect(connection.sendMessage).not.toHaveBeenCalled();

    await act(() => {
      connection.onControlMessage?.(tasksList([activeSnapshot(91)], true));
    });
    await renderManager();
    expect(connection.sendMessage).toHaveBeenCalledWith(
      91,
      [{ type: "text", text: "arrives later" }],
      "later-packet-outbox",
    );
    expect(testState.outbox.remove).not.toHaveBeenCalled();
  });

  it("does not surface an unmatched submission rejection to the user", async () => {
    await renderManager();

    expect(testState.connection!.onControlMessage).not.toBeNull();
    await act(() => {
      testState.connection!.onControlMessage!({
        type: "cydo/submission_rejected",
        correlation_id: "submission-uuid",
        tid: 17,
        kind: "delivery_failed",
        reason: "Agent session closed before accepting message submission",
      } satisfies ControlMessage);
    });

    expect(manager!.serverError).toBeNull();
  });

  it("routes an attached project-root submission acknowledgement", async () => {
    await prepareSubmittingDraft();

    await act(() => {
      acknowledgeSubmission(61);
    });

    expect(testState.navigate).toHaveBeenCalledWith(
      "/source/project/task/61",
      true,
    );
    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(61, "");

    testState.route.tid = "61";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "composition:submission-uuid",
      text: "submit before acknowledgement",
      lifecycle: "submitting",
      disabled: true,
    });
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: 61,
      });
      connection.onControlMessage?.({
        type: "task_updated",
        task: { ...activeSnapshot(61), isProcessing: false, draft: "" },
      });
      connection.onUnconfirmedUserMessage?.(
        61,
        {
          type: "item/started",
          item_id: "atomic-user",
          item_type: "user_message",
          content: [{ type: "text", text: "submit before acknowledgement" }],
        },
        "submission-uuid",
      );
      connection.onAgentAck?.(61, "submission-uuid");
    });
    expect((await renderManager()).draftView?.lifecycle).toBe("submitting");
    expect(connection.createTask).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).not.toHaveBeenCalled();
    expect(connection.saveDraft).not.toHaveBeenCalled();

    await act(() => {
      acceptSubmission(61);
    });
    expect(manager!.draftView).toBeNull();
    expect(manager!.getByTid(61)?.serverDraft ?? "").toBe("");
    await act(() => {
      acceptSubmission(61);
    });
    expect(manager!.draftView).toBeNull();
    expect(testState.navigate).toHaveBeenCalledTimes(1);
  });

  it("publishes optimistic sends and new backend placeholders without mutating returned tasks", async () => {
    const tid = 42;
    const { connection, task } = await seedOrdinaryTask(tid);
    deepFreeze(manager!.tasks);

    const sentContent = [{ type: "text", text: "optimistic send" }];
    await act(() => {
      manager!.send(task.uuid, "optimistic send");
    });
    expect(connection.sendMessage).toHaveBeenCalledExactlyOnceWith(
      tid,
      sentContent,
      expect.any(String),
    );
    const sent = manager!.getByTid(tid)!;
    expect(sent.messages).toMatchObject([
      { type: "user", content: sentContent, pending: true },
    ]);
    deepFreeze(manager!.tasks);

    const peerContent = [{ type: "text" as const, text: "sent by a peer" }];
    await act(() => {
      connection.onUnconfirmedUserMessage?.(
        tid,
        {
          type: "item/started",
          item_id: "peer-user",
          item_type: "user_message",
          content: peerContent,
        },
        "peer-nonce",
      );
    });
    const updated = manager!.getByTid(tid)!;
    expect(updated.messages).toMatchObject([
      { type: "user", content: sentContent, pending: true },
      { type: "user", content: peerContent, pending: true },
    ]);
    expect(updated.messages[1]!.id).not.toBe(updated.messages[0]!.id);
    deepFreeze(manager!.tasks);
  });

  it("does not route a submission acknowledgement after attachment changes", async () => {
    await prepareSubmittingDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    await renderManager();
    testState.navigate.mockClear();

    await act(() => {
      acknowledgeSubmission(62);
    });

    expect(testState.navigate).not.toHaveBeenCalled();
    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(62, "");
  });

  it("does not route a held submission acknowledgement across a pre-effect route switch", async () => {
    await prepareSubmittingDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    expect(commitRouteWithoutPassiveEffects().activeWorkspace).toBe("other");
    testState.navigate.mockClear();

    // The route render has committed, but its route attachment effect is
    // deliberately still pending when the held acknowledgement arrives.
    acknowledgeSubmission(63);

    expect(testState.navigate).not.toHaveBeenCalled();
    await act(() => {});
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("does not route a held editing create acknowledgement across a pre-effect route switch", async () => {
    await prepareCreatingDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    expect(commitRouteWithoutPassiveEffects().activeWorkspace).toBe("other");
    testState.navigate.mockClear();

    // This acknowledgement promotes the editor synchronously, before the route
    // attachment effect for the other project has had a chance to run.
    testState.connection!.onControlMessage?.({
      type: "task_created",
      tid: 64,
      workspace: "source",
      project_path: "/source-project",
      correlation_id: "submission-uuid",
    } satisfies ControlMessage);

    expect(testState.navigate).not.toHaveBeenCalled();
    await act(() => {});
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("keeps an owned draft view through numeric acknowledgement before its route attachment effect", async () => {
    await prepareCreatingDraft();
    const rootDraft = (await renderManager()).draftView;
    if (!rootDraft || rootDraft.kind !== "resolved") {
      throw new Error("Project root draft view did not resolve");
    }
    const composerResetToken = rootDraft.composerResetToken;

    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_created",
        tid: 65,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "submission-uuid",
      } satisfies ControlMessage);
    });
    expect(testState.navigate).toHaveBeenCalledWith(
      "/source/project/task/65",
      true,
    );

    testState.route.tid = "65";
    const promoted = commitRouteWithoutPassiveEffects().draftView;
    if (!promoted || promoted.kind !== "resolved") {
      throw new Error("Owned numeric draft view did not resolve synchronously");
    }
    expect(promoted).toMatchObject({
      viewKey: "composition:submission-uuid",
      remoteTid: 65,
      lifecycle: "present",
      composerResetToken,
    });
    testState.route.tid = null;
    const successor = (await renderManager()).draftView;
    expect(successor).toMatchObject({
      text: "",
      remoteTid: null,
      disabled: false,
    });
    expect(successor?.viewKey).not.toBe(promoted.viewKey);
  });

  it("returns an attached deleted draft to its project root", async () => {
    const draftView = await prepareEditableDraft();
    testState.navigate.mockClear();

    await act(() => {
      draftView.onTextChange("");
    });
    expect(testState.connection!.deleteTask).toHaveBeenCalledTimes(1);
    expect(testState.connection!.deleteTask).toHaveBeenCalledWith(71);
    expect(testState.navigate).toHaveBeenCalledTimes(1);
    expect(testState.navigate).toHaveBeenCalledWith("/source/project", true);
    const afterLocalClear = await renderManager();
    expect(
      [...afterLocalClear.tasks.values()].filter((task) => task.tid === 71),
    ).toHaveLength(0);
    expect(afterLocalClear.getByTid(71)).toBeUndefined();
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 71,
      } satisfies ControlMessage);
    });

    expect(testState.navigate).toHaveBeenCalledTimes(1);
    expect(testState.navigate).toHaveBeenCalledWith("/source/project", true);
  });

  it("selects a blank successor immediately when a promoted draft is cleared", async () => {
    const attached = await prepareEditableDraft();
    await act(() => {
      attached.onTextChange("");
    });
    testState.route.tid = null;
    const successor = (await renderManager()).draftView;
    if (successor?.kind !== "resolved") throw new Error("Missing successor");
    expect(successor.viewKey).not.toBe(attached.viewKey);
    expect(successor).toMatchObject({
      remoteTid: null,
      text: "",
      disabled: false,
    });
    await act(() => {
      successor.onTextChange("replacement B");
    });
    await vi.waitFor(() => {
      expect(testState.connection!.createTask).toHaveBeenCalledTimes(2);
    });
    expect(testState.connection!.deleteTask.mock.calls).toEqual([[71]]);
    await act(() =>
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 71,
      }),
    );
    expect((await renderManager()).draftView).toMatchObject({
      viewKey: successor.viewKey,
      remoteTid: null,
      text: "replacement B",
    });
  });

  it("does not route a deleted draft after attachment changes", async () => {
    const draftView = await prepareEditableDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    await renderManager();
    testState.navigate.mockClear();

    await act(() => {
      draftView.onTextChange("");
    });
    expect(testState.connection!.deleteTask).toHaveBeenCalledWith(71);
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 71,
      } satisfies ControlMessage);
    });

    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("does not return for a held deletion acknowledgement across a pre-effect route switch", async () => {
    const draftView = await prepareEditableDraft();
    await act(() => {
      draftView.onTextChange("");
    });
    expect(testState.connection!.deleteTask).toHaveBeenCalledWith(71);

    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    expect(commitRouteWithoutPassiveEffects().activeWorkspace).toBe("other");
    testState.navigate.mockClear();

    // As above, the route render is committed but the old attachment has not
    // yet been replaced by the passive route effect.
    testState.connection!.onControlMessage?.({
      type: "task_deleted",
      tid: 71,
    } satisfies ControlMessage);

    expect(testState.navigate).not.toHaveBeenCalled();
    await act(() => {});
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("does not project a nonempty ordinary save as a server draft", async () => {
    await renderManager();
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_created",
        tid: 73,
        workspace: "source",
        project_path: "/source-project",
      } satisfies ControlMessage);
      manager!.saveDraft(73, "ordinary local draft");
    });

    const task = (await renderManager()).getByTid(73);
    expect(testState.connection!.saveDraft).toHaveBeenCalledWith(
      73,
      "ordinary local draft",
    );
    expect(task?.serverDraft).toBeUndefined();
    expect(task?.title).toBe("ordinary local draft");
  });

  it("consumes a tombstoned expected focus hint before later generic routing", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Project root draft view did not resolve");
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });

    await act(() => {
      initial.onTextChange("draft A before acknowledgement");
      vi.advanceTimersByTime(16);
    });
    expect(testState.connection!.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      "submission-uuid",
    );

    const creating = (await renderManager()).draftView;
    if (!creating || creating.kind !== "resolved") {
      throw new Error("Creating A draft view did not resolve");
    }
    testState.uuid = "replacement-uuid";
    await act(() => {
      creating.onTextChange("");
    });
    const replacement = (await renderManager()).draftView;
    if (!replacement || replacement.kind !== "resolved") {
      throw new Error("Replacement B draft view did not resolve");
    }
    await act(() => {
      replacement.onTextChange("replacement draft B");
      vi.advanceTimersByTime(16);
    });
    const composerResetToken = replacement.composerResetToken;
    expect((await renderManager()).draftView).toMatchObject({
      lifecycle: "creating",
      text: "replacement draft B",
    });

    const tidA = 74;
    const connection = testState.connection!;
    testState.navigate.mockClear();
    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid: tidA,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "submission-uuid",
      } satisfies ControlMessage);
    });

    expect(connection.deleteTask).toHaveBeenCalledWith(tidA);
    expect(connection.deleteTask).toHaveBeenCalledTimes(1);
    expect(manager!.getByTid(tidA)).toBeUndefined();
    expect(
      [...manager!.tasks.values()].filter((task) => task.tid === tidA),
    ).toHaveLength(0);
    expect((await renderManager()).draftView).toMatchObject({
      lifecycle: "creating",
      remoteTid: null,
      text: "replacement draft B",
      composerResetToken,
    });

    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: tidA,
      } satisfies ControlMessage);
    });
    expect(testState.navigate).not.toHaveBeenCalled();

    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(tidA),
      } satisfies ControlMessage);
    });

    const afterHandoff = (await renderManager()).draftView;
    if (!afterHandoff || afterHandoff.kind !== "resolved") {
      throw new Error("Replacement B did not survive the active A handoff");
    }
    expect(afterHandoff).toMatchObject({
      text: "replacement draft B",
      composerResetToken,
      disabled: false,
    });
    expect(manager!.getByTid(tidA)).toMatchObject({
      tid: tidA,
      alive: true,
      isProcessing: true,
      status: "active",
    });

    testState.navigate.mockClear();
    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: tidA,
      } satisfies ControlMessage);
    });

    expect(testState.navigate).toHaveBeenCalledTimes(1);
    expect(testState.navigate).toHaveBeenCalledWith("/source/project/task/74");
  });

  it("keeps an initialized editor editable while workspace metadata is temporarily absent", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Project root draft view did not resolve");
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      initial.onTextChange("retain this draft through metadata loss");
    });
    const editing = (await renderManager()).draftView;
    if (!editing || editing.kind !== "resolved") {
      throw new Error("Editing draft view did not resolve");
    }
    const composerResetToken = editing.composerResetToken;
    const connection = testState.connection!;
    connection.createTask.mockClear();

    await act(() => {
      connection.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [
          {
            name: "source",
            projects: [],
            default_agent: "replacement-agent",
            default_task_type: "replacement-entry",
          },
        ],
      } satisfies ControlMessage);
    });

    const unavailable = (await renderManager()).draftView;
    if (!unavailable || unavailable.kind !== "resolved") {
      throw new Error("Cached project editor did not remain resolved");
    }
    expect(unavailable).toMatchObject({
      viewKey: "composition:submission-uuid",
      text: "retain this draft through metadata loss",
      entryPoint: "entry",
      agent: "agent",
      disabled: false,
      metadataReady: false,
      composerResetToken,
    });
    await act(() => {
      unavailable.onTextChange("must not create while metadata is unavailable");
      unavailable.onSubmit("", [
        {
          id: "unavailable-image",
          dataURL: "data:image/png;base64,dW5hdmFpbGFibGU=",
          base64: "dW5hdmFpbGFibGU=",
          mediaType: "image/png",
        },
      ]);
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect((await renderManager()).draftView).toMatchObject({
      text: "must not create while metadata is unavailable",
      disabled: false,
      metadataReady: false,
    });

    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });

    const restored = (await renderManager()).draftView;
    if (!restored || restored.kind !== "resolved") {
      throw new Error("Cached project editor did not restore");
    }
    expect(restored).toMatchObject({
      viewKey: "composition:submission-uuid",
      text: "must not create while metadata is unavailable",
      entryPoint: "entry",
      agent: "agent",
      disabled: false,
      metadataReady: true,
      composerResetToken,
    });
  });

  it("applies the first catalog to a pending editor whose workspace temporarily omits its project", async () => {
    const view = await seedPreCatalogPersistedDraft(
      persistedSnapshot(95, "snapshot"),
    );
    const connection = testState.connection!;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("pending local text");
      connection.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [{ name: "source", projects: [] }],
      });
    });
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "pending local text",
      metadataReady: false,
    });
    await act(() => {
      connection.onControlMessage?.(catalogWithoutEntry);
    });
    const controlled = await renderManager();
    expect(controlled.draftView).toMatchObject({
      editorId: "task:95",
      text: "pending local text",
      metadataReady: false,
      submitReady: false,
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();
    const next = controlled.draftView as DraftViewSnapshot;
    await act(() => {
      next.onTextChange("next local edit");
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      95,
      "next local edit",
    );
  });

  async function omitCurrentProject() {
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [{ name: "source", projects: [] }],
      });
    });
    return (await renderManager()).draftView;
  }

  function publishRouteProjects(projects: { name: string; path: string }[]) {
    testState.connection!.onControlMessage?.({
      type: "workspaces_list",
      workspaces: [{ name: "source", projects }],
    });
  }

  function acknowledgeRouteProbe(correlation: string) {
    acknowledgeSubmission(95, correlation);
    testState.connection!.onControlMessage?.({
      type: "focus_hint",
      from_tid: 0,
      to_tid: 95,
    });
  }

  it.each([
    ["omission first", true],
    ["ack first", true],
    ["omission first", false],
    ["ack first", false],
  ] as const)(
    "navigates across %s (same drain: %s)",
    async (order, sameDrain) => {
      const correlation = await prepareCreatingDraft();
      testState.hidden = false;
      const omit = () => {
        publishRouteProjects([]);
      };
      const ack = () => {
        acknowledgeRouteProbe(correlation);
      };
      const [first, second] =
        order === "omission first" ? [omit, ack] : [ack, omit];
      first();
      if (!sameDrain) await flushAnimationFrames();
      second();
      await flushAnimationFrames();

      expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
        "/source/project/task/95",
        true,
      );
      testState.route.tid = "95";
      expect((await renderManager()).draftView).toMatchObject({
        editorId: `composition:${correlation}`,
        remoteTid: 95,
        text: "editing create before acknowledgement",
      });
    },
  );

  it("keeps the in-flight composition across omission and a new name for the canonical path", async () => {
    const correlation = await prepareCreatingDraft();
    await omitCurrentProject();
    await act(() => {
      publishRouteProjects([{ name: "renamed", path: "/source-project" }]);
    });
    testState.route.project = "renamed";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: `composition:${correlation}`,
    });
    await act(() => {
      acknowledgeRouteProbe(correlation);
    });
    expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
      "/source/renamed/task/95",
      true,
    );
  });

  it("does not focus an omitted project's ack after moving to another route", async () => {
    const correlation = await prepareCreatingDraft();
    await omitCurrentProject();
    testState.route.project = "other-project";
    await renderManager();
    await act(() => {
      acknowledgeRouteProbe(correlation);
    });
    expect(testState.navigate).not.toHaveBeenCalled();
    expect((await renderManager()).getByTid(95)?.projectPath).toBe(
      "/source-project",
    );
  });

  it("does not infer a canonical path on a cold route whose first workspace list omits it", async () => {
    testState.route.tid = "95";
    await renderManager();
    await act(() => {
      publishRouteProjects([]);
      testState.connection!.onControlMessage?.(
        tasksList([persistedSnapshot(95, "snapshot")]),
      );
    });
    expect((await renderManager()).draftView).toBeNull();
    expect(testState.navigate).not.toHaveBeenCalled();
    await act(() => {
      publishRouteProjects([{ name: "project", path: "/source-project" }]);
    });
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "snapshot",
    });
  });

  it.each([true, false])(
    "does not navigate an old-path ack after the slug is reassigned (same drain: %s)",
    async (sameDrain) => {
      const correlation = await prepareCreatingDraft();
      await omitCurrentProject();
      testState.hidden = false;
      publishRouteProjects([
        { name: "renamed", path: "/source-project" },
        { name: "project", path: "/different-project" },
      ]);
      if (!sameDrain) await flushAnimationFrames();
      acknowledgeRouteProbe(correlation);
      await flushAnimationFrames();
      expect((await renderManager()).getByTid(95)?.projectPath).toBe(
        "/source-project",
      );
      expect(testState.navigate).not.toHaveBeenCalled();
    },
  );

  it.each([true, false])(
    "routes peer deletion to the original project after slug reassignment (same drain: %s)",
    async (sameDrain) => {
      await seedPreCatalogPersistedDraft(persistedSnapshot(95, "snapshot"));
      await omitCurrentProject();
      testState.hidden = false;
      publishRouteProjects([
        { name: "renamed", path: "/source-project" },
        { name: "project", path: "/different-project" },
      ]);
      if (!sameDrain) {
        await flushAnimationFrames();
        // Separate ordinary numeric URL correction from routing by task_deleted.
        expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
          "/source/renamed/task/95",
          true,
        );
        testState.navigate.mockClear();
      }
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 95,
      });
      await flushAnimationFrames();
      expect((await renderManager()).getByTid(95)).toBeUndefined();
      expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
        "/source/renamed",
        true,
      );
      expect(testState.navigate).not.toHaveBeenCalledWith(
        "/source/project",
        true,
      );
    },
  );

  it("retains the reassigned slug when the next workspace frame omits it", async () => {
    const correlation = await prepareCreatingDraft();
    testState.hidden = false;
    publishRouteProjects([{ name: "project", path: "/different-project" }]);
    publishRouteProjects([]);
    acknowledgeRouteProbe(correlation);
    await flushAnimationFrames();

    const current = await renderManager();
    expect(current.getByTid(95)?.projectPath).toBe("/source-project");
    expect(current.draftView).toMatchObject({
      projectPath: "/different-project",
      remoteTid: null,
    });
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("keeps the navigated route when the previous route renders again before the router commits", async () => {
    const correlation = await prepareCreatingDraft();
    acknowledgeRouteProbe(correlation);
    expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
      "/source/project/task/95",
      true,
    );

    // Model a previous-route render while the router's update is pending.
    commitRouteWithoutPassiveEffects();
    testState.connection!.onControlMessage?.({
      type: "task_deleted",
      tid: 95,
    });
    expect(testState.navigate.mock.calls).toEqual([
      ["/source/project/task/95", true],
      ["/source/project", true],
    ]);
  });

  it.each([false, true])(
    "returns to New Task when promotion and deletion share a drain (omission: %s)",
    async (omitted) => {
      const correlation = await prepareCreatingDraft();
      if (omitted) await omitCurrentProject();
      testState.hidden = false;
      acknowledgeRouteProbe(correlation);
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 95,
      });
      await flushAnimationFrames();
      expect(testState.navigate.mock.calls).toEqual([
        ["/source/project/task/95", true],
        ["/source/project", true],
      ]);
      const current = await renderManager();
      expect(current.getByTid(95)).toBeUndefined();
      expect(current.draftView).toMatchObject({ text: "", remoteTid: null });
      expect(current.draftView?.viewKey).not.toBe(`composition:${correlation}`);
    },
  );

  it.each([false, true])(
    "verifier: returns to the canonical project after promotion, slug reassignment, and deletion (same drain: %s)",
    async (sameDrain) => {
      const correlation = await prepareCreatingDraft();
      testState.hidden = false;
      acknowledgeRouteProbe(correlation);
      publishRouteProjects([
        { name: "renamed", path: "/source-project" },
        { name: "project", path: "/different-project" },
      ]);
      if (!sameDrain) {
        await flushAnimationFrames();
        // Reflect the canonical route committed by the real router.
        testState.route.project = "renamed";
        testState.route.tid = "95";
        await renderManager();
      }
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 95,
      });
      await flushAnimationFrames();
      expect((await renderManager()).getByTid(95)).toBeUndefined();
      expect(testState.navigate.mock.calls.at(-1)).toEqual([
        "/source/renamed",
        true,
      ]);
    },
  );

  it.each(["root", "sidebar"] as const)(
    "verifier: uses the last UI navigation before draining promotion and focus controls (%s)",
    async (destination) => {
      const correlation = await prepareCreatingDraft();
      testState.connection!.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(71),
      });
      testState.hidden = false;
      acknowledgeRouteProbe(correlation);
      publishRouteProjects([{ name: "project", path: "/source-project" }]);
      const select = () => {
        manager!.setActiveTaskId("71");
      };
      const newTask = () => {
        manager!.navigateToProject("source", "project");
      };
      await act(async () => {
        if (destination === "root") {
          select();
          newTask();
        } else {
          newTask();
          select();
        }
        testState.navigate.mockClear();
        await flushAnimationFrames();
      });
      if (destination === "root") {
        expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
          "/source/project/task/95",
          true,
        );
      } else {
        expect(testState.navigate).not.toHaveBeenCalled();
      }
    },
  );

  it.each(["back", "forward"] as const)(
    "verifier: handles browser %s before queued acknowledgements and deletes",
    async (direction) => {
      const correlation = await prepareCreatingDraft();
      const connection = testState.connection!;
      await act(() => {
        connection.onControlMessage?.({
          type: "task_updated",
          task: activeSnapshot(71),
        });
      });
      testState.route.tid = direction === "back" ? "71" : null;
      await renderManager();
      testState.hidden = false;
      acknowledgeRouteProbe(correlation);
      publishRouteProjects([]);
      connection.onControlMessage?.({ type: "task_deleted", tid: 95 });
      testState.navigateBrowser(
        direction === "back" ? "/source/project" : "/source/project/task/71",
      );
      await flushAnimationFrames();
      expect(testState.navigate.mock.calls).toEqual(
        direction === "back"
          ? [
              ["/source/project/task/95", true],
              ["/source/project", true],
            ]
          : [],
      );
      expect(manager!.getByTid(95)).toBeUndefined();
    },
  );

  it("verifier: chained focus hints target the same-drain reload", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() => {
      for (const tid of [71, 72]) {
        connection.onControlMessage?.({
          type: "task_updated",
          task: activeSnapshot(tid),
        });
      }
    });
    testState.hidden = false;
    connection.onControlMessage?.({
      type: "focus_hint",
      from_tid: 0,
      to_tid: 71,
    });
    connection.onControlMessage?.({
      type: "focus_hint",
      from_tid: 71,
      to_tid: 72,
    });
    connection.onControlMessage?.({
      type: "task_reload",
      tid: 72,
      reason: "edit",
    });
    await flushAnimationFrames();
    expect(testState.navigate.mock.calls).toEqual([
      ["/source/project/task/71"],
      ["/source/project/task/72"],
    ]);
    expect(connection.requestHistory).toHaveBeenCalledExactlyOnceWith(72, "");
  });

  it("routes an attached promotion while the workspace omits its project", async () => {
    await prepareCreatingDraft();
    const attached = await omitCurrentProject();
    expect(attached).toMatchObject({ viewKey: "composition:submission-uuid" });

    await act(() => {
      const connection = testState.connection!;
      connection.onControlMessage?.({
        type: "task_created",
        tid: 95,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "submission-uuid",
      });
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: 95,
      });
    });
    expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
      "/source/project/task/95",
      true,
    );

    testState.route.tid = "95";
    expect((await renderManager()).draftView).toMatchObject({
      viewKey: attached?.viewKey,
      text: attached?.text,
      remoteTid: 95,
    });
  });

  it.each(["clear", "peer deletion"])(
    "returns to blank New Task on %s while the workspace omits its project",
    async (action) => {
      await seedPreCatalogPersistedDraft(persistedSnapshot(95, "snapshot"));
      const attached = await omitCurrentProject();
      expect(attached).toMatchObject({ editorId: "task:95", text: "snapshot" });
      const connection = testState.connection!;
      await act(() => {
        if (action === "clear") {
          (attached as DraftViewSnapshot).onTextChange("");
        } else {
          connection.onControlMessage?.({ type: "task_deleted", tid: 95 });
        }
      });
      if (action === "clear") {
        expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(95);
      } else {
        expect(connection.deleteTask).not.toHaveBeenCalled();
      }
      expect(testState.navigate).toHaveBeenCalledExactlyOnceWith(
        "/source/project",
        true,
      );
      testState.route.tid = null;
      expect((await renderManager()).draftView).toMatchObject({
        text: "",
        remoteTid: null,
      });
    },
  );

  it("keeps a cached composition separate from numeric routes during metadata loss", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Project root draft view did not resolve");
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      initial.onTextChange("retain A while visiting unrelated routes");
    });
    const editing = (await renderManager()).draftView;
    if (!editing || editing.kind !== "resolved") {
      throw new Error("Editing project root draft view did not resolve");
    }
    const composerResetToken = editing.composerResetToken;
    const connection = testState.connection!;

    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(72),
      } satisfies ControlMessage);
      connection.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [
          {
            name: "source",
            projects: [],
            default_agent: "agent",
            default_task_type: "entry",
          },
        ],
      } satisfies ControlMessage);
    });
    connection.createTask.mockClear();
    connection.deleteTask.mockClear();
    connection.setEntryPoint.mockClear();
    connection.setAgentName.mockClear();
    connection.saveDraft.mockClear();

    testState.route.tid = "72";
    const realTaskRoute = await renderManager();
    expect(realTaskRoute.draftView).toBeNull();
    expect(realTaskRoute.getByTid(72)).toMatchObject({
      status: "active",
      alive: true,
      isProcessing: true,
    });

    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(72, "unowned pending B"),
      } satisfies ControlMessage);
    });
    const pendingTaskRoute = await renderManager();
    expect(pendingTaskRoute.draftView).toMatchObject({
      editorId: "task:72",
      text: "unowned pending B",
      metadataReady: false,
    });
    expect(pendingTaskRoute.getByTid(72)).toMatchObject({
      status: "pending",
      serverDraft: "unowned pending B",
    });

    testState.route.tid = null;
    const restored = (await renderManager()).draftView;
    if (!restored || restored.kind !== "resolved") {
      throw new Error("Cached project root draft view did not restore");
    }
    expect(restored).toMatchObject({
      viewKey: "composition:submission-uuid",
      text: "retain A while visiting unrelated routes",
      entryPoint: "entry",
      agent: "agent",
      disabled: false,
      metadataReady: false,
      composerResetToken,
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();
    expect(connection.setEntryPoint).not.toHaveBeenCalled();
    expect(connection.setAgentName).not.toHaveBeenCalled();
    expect(connection.saveDraft).not.toHaveBeenCalled();
  });

  it("routes independently between persisted editors and saves each exact tid", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(
        tasksList([
          persistedSnapshot(91, "persisted A"),
          persistedSnapshot(92, "persisted B"),
        ]),
      );
    });
    testState.route.tid = "91";
    const a = (await renderManager()).draftView;
    if (a?.kind !== "resolved") throw new Error("A did not open");
    expect(a).toMatchObject({
      editorId: "task:91",
      viewKey: "task:91",
      text: "persisted A",
    });

    connection.saveDraft.mockClear();
    connection.setEntryPoint.mockClear();
    connection.setAgentName.mockClear();
    await act(() => {
      a.onTextChange("local A");
    });
    testState.route.tid = "92";
    const b = (await renderManager()).draftView;
    if (b?.kind !== "resolved") throw new Error("B did not open");
    expect(b).toMatchObject({
      editorId: "task:92",
      viewKey: "task:92",
      text: "persisted B",
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();

    await act(() => {
      b.onTextChange("local B");
    });
    testState.route.tid = "91";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:91",
      text: "local A",
    });
    await vi.waitFor(() => {
      expect(connection.saveDraft.mock.calls).toEqual([
        [91, "local A"],
        [92, "local B"],
      ]);
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();
    expect(connection.setEntryPoint).not.toHaveBeenCalled();
    expect(connection.setAgentName).not.toHaveBeenCalled();
  });

  it("opens the reset numeric draft from a fresh snapshot", async () => {
    await renderManager();
    const connection = testState.connection!;
    testState.route.tid = "91";

    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "type"));
      connection.onControlMessage?.(projectTaskTypes("entry", "type"));
      connection.onControlMessage?.(agents("agent"));
      testState.uuid = "persisted-reload-uuid";
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [persistedSnapshot(91, "reloaded persisted draft")],
      } satisfies ControlMessage);
      testState.uuid = "submission-uuid";
    });

    const opened = (await renderManager()).draftView;
    if (!opened || opened.kind !== "resolved") {
      throw new Error("Fresh snapshot did not open the numeric draft");
    }
    expect(opened).toMatchObject({
      remoteTid: 91,
      text: "reloaded persisted draft",
      entryPoint: "entry",
      agent: "agent",
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();
  });

  it("reduces a present owned task message before its controller handoff effect", async () => {
    const attached = await prepareEditableDraft();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      attached.onTextChange("A waits for its pending save");
    });
    const connection = testState.connection!;
    expect(connection.deleteTask).not.toHaveBeenCalled();
    const expected = {
      type: "user",
      content: [{ type: "text", text: "A became active" }],
    };
    const originalClearTimeout = globalThis.clearTimeout;
    let sawControllerHandoff = false;
    const clearTimeoutSpy = vi
      .spyOn(globalThis, "clearTimeout")
      .mockImplementation((handle) => {
        sawControllerHandoff = true;
        expect(getLiveTaskForTest!(71)?.messages).toContainEqual(
          expect.objectContaining(expected),
        );
        originalClearTimeout(handle);
      });

    try {
      await act(() => {
        connection.onTaskMessage?.(71, {
          type: "item/started",
          item_id: "active-a-message",
          item_type: "user_message",
          content: [{ type: "text", text: "A became active" }],
        });
      });
      expect(sawControllerHandoff).toBe(true);
      expect(manager!.getByTid(71)?.messages).toContainEqual(
        expect.objectContaining(expected),
      );
      expect((await renderManager()).draftView).toBeNull();
    } finally {
      clearTimeoutSpy.mockRestore();
    }
  });

  it("reduces a present owned agent acknowledgement before its controller handoff effect", async () => {
    const attached = await prepareEditableDraft();
    const task = manager!.getByTid(71);
    if (!task) throw new Error("A was not materialized");
    testState.uuid = "a-agent-ack";
    await act(() => {
      manager!.send(task.uuid, "acknowledge A before B");
    });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      attached.onTextChange("A waits for its acknowledgement save");
    });

    const connection = testState.connection!;
    expect(connection.deleteTask).not.toHaveBeenCalled();
    const expected = {
      type: "user",
      nonce: "a-agent-ack",
      ackState: 2,
    };
    const originalClearTimeout = globalThis.clearTimeout;
    let sawControllerHandoff = false;
    const clearTimeoutSpy = vi
      .spyOn(globalThis, "clearTimeout")
      .mockImplementation((handle) => {
        sawControllerHandoff = true;
        expect(getLiveTaskForTest!(71)?.messages).toContainEqual(
          expect.objectContaining(expected),
        );
        originalClearTimeout(handle);
      });

    try {
      await act(() => {
        connection.onAgentAck?.(71, "a-agent-ack");
      });
      expect(sawControllerHandoff).toBe(true);
      expect(manager!.getByTid(71)?.messages).toContainEqual(
        expect.objectContaining(expected),
      );
      expect((await renderManager()).draftView).toBeNull();
    } finally {
      clearTimeoutSpy.mockRestore();
    }
  });

  it("keeps the canonical project composer available until project metadata resolves", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "blank"));
      connection.onControlMessage?.(agents("agent"));
    });

    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenCalledWith("/source-project");

    const waitingForMetadata = (await renderManager()).draftView;
    if (!waitingForMetadata || waitingForMetadata.kind !== "resolved") {
      throw new Error("Canonical project draft did not initialize");
    }
    expect(waitingForMetadata).toMatchObject({
      text: "",
      entryPoint: "",
      agent: "",
      disabled: false,
      metadataReady: false,
    });

    await act(() => {
      waitingForMetadata.onTextChange("type before project metadata");
      waitingForMetadata.onEntryPointChange("must-not-be-used");
      waitingForMetadata.onAgentChange("must-not-be-used");
      waitingForMetadata.onSubmit("type before project metadata", []);
    });
    await new Promise((resolve) => setTimeout(resolve, 32));
    expect(connection.createTask).not.toHaveBeenCalled();
    expect((await renderManager()).draftView).toMatchObject({
      text: "type before project metadata",
      entryPoint: "",
      agent: "",
      disabled: false,
      metadataReady: false,
    });

    await act(() => {
      connection.onControlMessage?.(projectTaskTypes("project-entry", "blank"));
    });
    await vi.waitFor(() => {
      expect(connection.createTask).toHaveBeenCalledTimes(1);
    });

    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "project-entry",
      undefined,
      "agent",
      "submission-uuid",
    );
    expect((await renderManager()).draftView).toMatchObject({
      entryPoint: "project-entry",
      agent: "agent",
      metadataReady: true,
    });
  });

  it("resolves a typed canonical draft in the catalog handler", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "blank"));
      connection.onControlMessage?.(agents("agent"));
    });

    const waitingForMetadata = (await renderManager()).draftView;
    if (!waitingForMetadata || waitingForMetadata.kind !== "resolved") {
      throw new Error("Canonical project draft did not initialize");
    }
    expect(waitingForMetadata).toMatchObject({
      text: "",
      entryPoint: "",
      agent: "",
      disabled: false,
      metadataReady: false,
    });

    const text = "type before catalog metadata resolution";
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      waitingForMetadata.onTextChange(text);
    });

    connection.onControlMessage?.(projectTaskTypes("project-entry", "blank"));
    const resolved = commitRouteWithoutPassiveEffects().draftView;
    if (!resolved || resolved.kind !== "resolved") {
      throw new Error("Canonical project draft did not resolve metadata");
    }
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(resolved).toMatchObject({
      text,
      entryPoint: "project-entry",
      agent: "agent",
      disabled: false,
      metadataReady: true,
    });

    await act(() => {
      resolved.onSubmit(text, []);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(1);
    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "project-entry",
      [{ type: "text", text }],
      "agent",
      "submission-uuid",
    );
  });

  it("edits and saves a known numeric draft before its picker catalog arrives", async () => {
    const view = await seedPreCatalogPersistedDraft({
      ...persistedSnapshot(91, "persisted before catalog"),
      task_type: "snapshot-type",
    });
    expect(view).toMatchObject({
      editorId: "task:91",
      remoteTid: 91,
      text: "persisted before catalog",
      entryPoint: "entry",
      agent: "agent",
      metadataReady: false,
      disabled: false,
    });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("edited before catalog");
      view.onEntryPointChange("other-entry");
      view.onAgentChange("other-agent");
      view.onSubmit("edited before catalog", []);
    });
    const connection = testState.connection!;
    expect(connection.saveDraft).not.toHaveBeenCalled();
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledWith(
      91,
      "edited before catalog",
    );
    expect(connection.setEntryPoint).not.toHaveBeenCalled();
    expect(connection.setAgentName).not.toHaveBeenCalled();
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.sendMessage).not.toHaveBeenCalled();
    expect(manager!.getByTid(91)).toMatchObject({
      entryPoint: "entry",
      agentName: "agent",
      taskType: "snapshot-type",
      serverDraft: "persisted before catalog",
      title: "edited before catalog",
    });
  });

  it("validates a persisted task against an arrived catalog without rewriting it", async () => {
    await seedPreCatalogPersistedDraft({
      ...persistedSnapshot(94),
      task_type: "snapshot-type",
    });
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/source-project",
        entry_points: [
          {
            name: "catalog-entry",
            task_type: "catalog-type",
            description: "",
            model_class: "",
            read_only: false,
          },
          {
            name: "entry",
            task_type: "persisted-catalog-type",
            description: "",
            model_class: "",
            read_only: false,
          },
          {
            name: "entry-b",
            task_type: "type-b",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
    });
    await renderManager();

    const resolvedDraftView = (await renderManager()).draftView;
    expect(resolvedDraftView).toMatchObject({
      entryPoint: "entry",
      agent: "agent",
      metadataReady: true,
    });
    if (!resolvedDraftView || resolvedDraftView.kind !== "resolved") {
      throw new Error(
        "Catalog resolution did not keep the persisted draft attached",
      );
    }
    await act(() => {
      resolvedDraftView.onTextChange("edited with catalog");
    });
    expect(manager!.getByTid(94)).toMatchObject({
      entryPoint: "entry",
      taskType: "persisted-catalog-type",
    });

    await act(() => {
      testState.uuid = "pre-catalog-switch-b-uuid";
      connection.onControlMessage?.({
        type: "task_updated",
        task: {
          ...persistedSnapshot(95, "persisted B"),
          task_type: "type-b",
          entry_point: "entry-b",
          agent_name: "agent-b",
        },
      } satisfies ControlMessage);
      testState.uuid = "submission-uuid";
    });
    testState.route.tid = "95";
    const switchedDraftView = (await renderManager()).draftView;
    expect(switchedDraftView).toMatchObject({
      editorId: "task:95",
      remoteTid: 95,
      entryPoint: "entry-b",
      agent: "agent-b",
      metadataReady: true,
    });
  });

  it.each([
    ["active", { status: "active" }],
    ["alive", { alive: true }],
    ["processing", { isProcessing: true }],
    ["blank", { draft: "  " }],
    ["missing entry point", { entry_point: "" }],
    ["wrong project", { project_path: "/other-project" }],
    ["wrong workspace", { workspace: "other" }],
  ] satisfies [string, Partial<TaskSnapshotEntry>][])(
    "does not open a direct editor for a snapshot that is %s",
    async (_condition, change) => {
      await bootstrapProject();
      testState.route.tid = "95";
      expect((await renderManager()).draftView).toBeNull();
      await act(() => {
        testState.connection!.onControlMessage?.({
          type: "task_updated",
          task: { ...persistedSnapshot(95), ...change },
        });
      });
      expect((await renderManager()).draftView).toBeNull();
      expect(testState.connection!.createTask).not.toHaveBeenCalled();
    },
  );

  it("keeps a pending task with messages on the ordinary path", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(95),
      });
      connection.onTaskMessage?.(
        95,
        {
          type: "item/started",
          item_type: "user_message",
          item_id: "existing-user",
          text: "existing message",
        },
        1,
      );
    });
    testState.route.tid = "95";
    const manager = await renderManager();
    expect(manager.getByTid(95)?.messages).toHaveLength(1);
    expect(manager.draftView).toBeNull();
  });

  const catalogWithoutEntry = {
    type: "project_task_types_list",
    project_path: "/source-project",
    entry_points: [],
    type_info: [],
  } satisfies ControlMessage;

  it("an unlisted-entry editor clears with one delete and cannot submit", async () => {
    await seedPreCatalogPersistedDraft(persistedSnapshot(95));
    const connection = testState.connection!;
    await act(() => connection.onControlMessage?.(catalogWithoutEntry));
    const view = (await renderManager()).draftView as DraftViewSnapshot;
    expect(view.submitReady).toBe(false);
    await act(() => {
      view.onSubmit(view.text, []);
      view.onTextChange("");
    });
    expect(connection.sendMessage).not.toHaveBeenCalled();
    expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(95);
  });

  it("publishes roster changes with the same default agent", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => connection.onControlMessage?.(agents("agent")));
    const previous = (await renderManager()).agents;
    const roster = [...previous, { name: "second", driver: "codex" }];
    await act(() => {
      connection.onControlMessage?.({
        type: "agents_list",
        agents: roster,
        default_agent: "agent",
      });
    });
    expect(manager!.agents).toEqual(roster);
    await act(() => {
      connection.onControlMessage?.({
        type: "agents_list",
        agents: roster.map((agent) => ({ ...agent })),
        default_agent: "agent",
      });
    });
    expect(manager!.agents).toBe(roster);
  });

  it("admits the persisted draft when a rejecting catalog arrives first", async () => {
    testState.route.tid = "95";
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(catalogWithoutEntry);
      connection.onControlMessage?.(
        tasksList([persistedSnapshot(95, "server draft")]),
      );
    });
    const view = await renderManager();
    expect(view.draftView).toMatchObject({
      editorId: "task:95",
      text: "server draft",
      submitReady: false,
    });
    expect(view.getByTid(95)?.serverDraft).toBe("server draft");
    expect(connection.saveDraft).not.toHaveBeenCalled();
  });

  it.each(["unedited", "pending edit", "already saved"] as const)(
    "keeps a persisted draft controlled when a rejecting catalog arrives after a %s snapshot",
    async (variant) => {
      const view = await seedPreCatalogPersistedDraft(
        persistedSnapshot(95, "server draft"),
      );
      const connection = testState.connection!;
      const image = seedEditorImage(view.editorId);
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      if (variant !== "unedited") {
        await act(() => {
          view.onTextChange("local edit");
          if (variant === "already saved")
            vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
        });
      }
      expect(connection.saveDraft).toHaveBeenCalledTimes(
        variant === "already saved" ? 1 : 0,
      );
      await act(() => {
        connection.onControlMessage?.(catalogWithoutEntry);
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS - 1);
      });
      const controlled = (await renderManager()).draftView as DraftViewSnapshot;
      expect(controlled).toMatchObject({
        editorId: "task:95",
        text: variant === "unedited" ? "server draft" : "local edit",
        submitReady: false,
      });
      expect(connection.saveDraft).toHaveBeenCalledTimes(
        variant === "already saved" ? 1 : 0,
      );
      await act(() => {
        vi.advanceTimersByTime(1);
      });
      if (variant === "unedited")
        expect(connection.saveDraft).not.toHaveBeenCalled();
      else
        expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
          95,
          "local edit",
        );
      expect(imageStore.entries.get(view.editorId)).toBe(image);
      expect(image.images).toHaveLength(1);
      await act(() => {
        controlled.onTextChange("next edit");
      });
      expect((await renderManager()).draftView).toMatchObject({
        editorId: view.editorId,
        text: "next edit",
      });
      expect(connection.deleteTask).not.toHaveBeenCalled();
    },
  );

  it.each(["task_updated", "tasks_list"] as const)(
    "keeps a pending edit controlled when %s names an unavailable entry point",
    async (frame) => {
      await bootstrapProject();
      testState.route.tid = "96";
      const connection = testState.connection!;
      await act(() => {
        connection.onControlMessage?.({
          type: "task_updated",
          task: persistedSnapshot(96),
        });
      });
      const view = (await renderManager()).draftView as DraftViewSnapshot;
      expect(view.editorId).toBe("task:96");
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      const edit = "pending local edit";
      await act(() => {
        view.onTextChange(edit);
      });
      expect(connection.saveDraft).not.toHaveBeenCalled();
      const snapshot = { ...persistedSnapshot(96), entry_point: "unavailable" };
      await act(() => {
        // Open via task_updated so this can be the epoch's first list entry.
        connection.onControlMessage?.(
          frame === "tasks_list"
            ? tasksList([snapshot])
            : { type: frame, task: snapshot },
        );
      });
      const manager = await renderManager();
      expect(manager.draftView).toMatchObject({
        editorId: "task:96",
        text: edit,
        entryPoint: "unavailable",
        submitReady: false,
      });
      const task = manager.getByTid(96)!;
      expect(task.entryPoint).toBe("unavailable");
      expect(task.serverDraft).toBe(snapshot.draft);
      expect(manager.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
      expect(connection.saveDraft).not.toHaveBeenCalled();
      await act(() => {
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(96, edit);
    },
  );

  it("merges an unavailable-entry snapshot and keeps a pending save", async () => {
    await bootstrapProject();
    testState.route.tid = "96";
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(96, "baseline"),
      });
    });
    const view = (await renderManager()).draftView as DraftViewSnapshot;
    expect(view.metadataReady).toBe(true);
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const idleTimers = vi.getTimerCount();
    await act(() => {
      view.onTextChange("transient edit");
      view.onTextChange("baseline");
    });
    expect(vi.getTimerCount()).toBe(idleTimers + 1);
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: {
          ...persistedSnapshot(96, "merged server text"),
          entry_point: "unavailable",
        },
      });
    });
    expect(vi.getTimerCount()).toBe(idleTimers + 1);
    const controlled = await renderManager();
    expect(controlled.draftView).toMatchObject({
      editorId: "task:96",
      text: "merged server text",
      entryPoint: "unavailable",
      submitReady: false,
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      96,
      "merged server text",
    );
  });

  it("fails fast when a pre-catalog persisted task lacks its snapshot task type", async () => {
    const view = await seedPreCatalogPersistedDraft({
      ...persistedSnapshot(92),
      task_type: undefined,
    });
    expect(() => {
      view.onTextChange("pending edit");
    }).toThrow("Draft projection requires task type 92");
    expect(testState.connection!.saveDraft).not.toHaveBeenCalled();
  });

  it("fails fast when a pre-catalog persisted task entry point diverges from its form", () => {
    const task = taskStateFromEntry(
      { ...persistedSnapshot(93), entry_point: "different-entry" },
      undefined,
      undefined,
    );
    expect(() =>
      projectDraftTask(
        task,
        93,
        { entryPoint: "entry", text: "pending edit", agent: "agent" },
        new Map(),
      ),
    ).toThrow("Draft projection entry point does not match task 93");
  });

  it("waits for project types and the global default on a direct route", async () => {
    await renderManager();
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [
          {
            name: "source",
            projects: [{ name: "project", path: "/source-project" }],
            default_agent: "agent",
          },
        ],
      } satisfies ControlMessage);
      testState.connection!.onControlMessage?.({
        type: "agents_list",
        agents: [{ name: "agent", driver: "claude" }],
        default_agent: "agent",
      } satisfies ControlMessage);
    });

    expect((await renderManager()).draftView).toMatchObject({
      kind: "resolved",
      disabled: false,
      metadataReady: false,
    });
    await vi.waitFor(() => {
      expect(testState.connection!.requestTaskTypes).toHaveBeenCalledWith(
        "/source-project",
      );
    });

    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/source-project",
        entry_points: [
          {
            name: "other-project-entry",
            task_type: "other-project-task",
            description: "",
            model_class: "",
            read_only: false,
          },
          {
            name: "project-entry",
            task_type: "project-task",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
    });

    expect((await renderManager()).draftView).toMatchObject({
      kind: "resolved",
      disabled: false,
      metadataReady: false,
    });
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_types_list",
        entry_points: [
          {
            name: "global-entry",
            task_type: "project-task",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
        default_task_type: "project-task",
      } satisfies ControlMessage);
    });

    const draftView = (await renderManager()).draftView;
    if (!draftView || draftView.kind !== "resolved") {
      throw new Error("Project entry-point response did not resolve the route");
    }
    expect(draftView.entryPoint).toBe("project-entry");
    await act(() => {
      draftView.onTextChange("project-only bootstrap");
    });
    await vi.waitFor(() => {
      expect(testState.connection!.createTask).toHaveBeenCalledWith(
        "source",
        "/source-project",
        "project-entry",
        undefined,
        "agent",
        "submission-uuid",
      );
    });
  });

  it("records a void project type request for the current epoch", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });
    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenCalledTimes(1);

    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });
    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenCalledTimes(1);
  });

  it("advances composer image tokens across reset without coupling projects", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    const initialA = (await renderManager()).draftView;
    if (!initialA || initialA.kind !== "resolved") {
      throw new Error("Initial project draft did not resolve");
    }
    expect(initialA.composerResetToken).toBe(0);

    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
    });
    await bootstrapProject();

    const afterZeroReset = (await renderManager()).draftView;
    if (!afterZeroReset || afterZeroReset.kind !== "resolved") {
      throw new Error("Fresh project draft did not resolve after reset");
    }
    expect(afterZeroReset.composerResetToken).toBeGreaterThan(
      initialA.composerResetToken,
    );

    await act(() => {
      afterZeroReset.onTextChange("draft A before local clear");
      afterZeroReset.onTextChange("");
    });
    const afterLocalClear = (await renderManager()).draftView;
    if (!afterLocalClear || afterLocalClear.kind !== "resolved") {
      throw new Error(
        "Project draft did not remain resolved after local clear",
      );
    }
    expect(afterLocalClear.viewKey).not.toBe(afterZeroReset.viewKey);

    testState.route.workspace = "other";
    testState.route.project = "other-project";
    await renderManager();
    await act(() => {
      connection.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/other-project",
        entry_points: [
          {
            name: "entry",
            task_type: "blank",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
    });

    const beforeResetB = (await renderManager()).draftView;
    if (!beforeResetB || beforeResetB.kind !== "resolved") {
      throw new Error("Second project draft did not resolve before reset");
    }
    expect(beforeResetB.composerResetToken).toBe(
      afterZeroReset.composerResetToken,
    );

    testState.route.workspace = "source";
    testState.route.project = "project";
    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
    });
    await bootstrapProject();

    const afterIncrementedReset = (await renderManager()).draftView;
    if (!afterIncrementedReset || afterIncrementedReset.kind !== "resolved") {
      throw new Error("Project draft did not resolve after incremented reset");
    }
    expect(afterIncrementedReset.viewKey).not.toBe(afterLocalClear.viewKey);

    testState.route.workspace = "other";
    testState.route.project = "other-project";
    await renderManager();
    await act(() => {
      connection.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/other-project",
        entry_points: [
          {
            name: "entry",
            task_type: "blank",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
    });

    const projectB = (await renderManager()).draftView;
    if (!projectB || projectB.kind !== "resolved") {
      throw new Error("Second project draft did not resolve after reset");
    }
    expect(projectB.composerResetToken).toBe(
      afterIncrementedReset.composerResetToken,
    );
  });

  it("drops a prior connection epoch before bootstrapping fresh project defaults", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await bootstrapGlobalDefaultProject("entry-a", "type-a", "agent-a");
    const connection = testState.connection!;
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Initial project defaults did not resolve");
    }
    expect(initial.entryPoint).toBe("entry-a");
    expect(initial.agent).toBe("agent-a");

    connection.requestTaskTypes.mockClear();
    testState.hidden = false;
    emitGlobalDefaultProjectBootstrap("entry-a", "type-a", "agent-a");
    expect(testState.animationFrames.size).toBe(1);

    await act(() => {
      connection.onStatusChange?.(false);
    });
    await flushAnimationFrames();

    const afterStaleBootstrap = await renderManager();
    expect(afterStaleBootstrap.connected).toBe(false);
    expect(afterStaleBootstrap.draftView).toMatchObject({
      kind: "unresolved",
      disabled: true,
    });
    expect(connection.requestTaskTypes).not.toHaveBeenCalled();

    testState.hidden = true;
    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
    });
    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenCalledTimes(1);
    expect(connection.requestTaskTypes).toHaveBeenCalledWith("/source-project");

    await act(() => {
      connection.onControlMessage?.(globalTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(projectTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(agents("agent-b"));
    });

    const fresh = (await renderManager()).draftView;
    if (!fresh || fresh.kind !== "resolved") {
      throw new Error("Fresh project defaults did not resolve");
    }
    expect(fresh.entryPoint).toBe("entry-b");
    expect(fresh.agent).toBe("agent-b");

    await act(() => {
      fresh.onTextChange("create with fresh defaults");
      fresh.onSubmit("create with fresh defaults", []);
    });
    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry-b",
      [{ type: "text", text: "create with fresh defaults" }],
      "agent-b",
      fresh.editorId.slice("composition:".length),
    );
  });

  it("drops closed-interval catalogs before bootstrapping fresh project defaults", async () => {
    await bootstrapGlobalDefaultProject("entry-a", "type-a", "agent-a");
    const connection = testState.connection!;
    connection.requestTaskTypes.mockClear();
    testState.hidden = false;

    await act(() => {
      connection.onStatusChange?.(false);
    });
    emitGlobalDefaultProjectBootstrap("entry-a", "type-a", "agent-a");
    expect(testState.animationFrames.size).toBe(0);

    await act(() => {
      connection.onStatusChange?.(true);
    });
    await flushAnimationFrames();

    const whileClosed = await renderManager();
    expect(whileClosed.connected).toBe(false);
    expect(whileClosed.draftView).toMatchObject({
      kind: "unresolved",
      disabled: true,
    });
    expect(connection.requestTaskTypes).not.toHaveBeenCalled();

    testState.hidden = true;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });
    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenCalledTimes(1);
    expect(connection.requestTaskTypes).toHaveBeenCalledWith("/source-project");

    await act(() => {
      connection.onControlMessage?.(globalTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(projectTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(agents("agent-b"));
    });

    const fresh = (await renderManager()).draftView;
    if (!fresh || fresh.kind !== "resolved") {
      throw new Error("Fresh project defaults did not resolve");
    }
    expect(fresh.entryPoint).toBe("entry-b");
    expect(fresh.agent).toBe("agent-b");

    await act(() => {
      fresh.onTextChange("create with closed-interval defaults");
      fresh.onSubmit("create with closed-interval defaults", []);
    });
    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry-b",
      [{ type: "text", text: "create with closed-interval defaults" }],
      "agent-b",
      fresh.editorId.slice("composition:".length),
    );
  });

  it("does not initialize a reset editor from a pending old-epoch effect", async () => {
    await renderManager();
    const connection = testState.connection!;

    emitGlobalDefaultProjectBootstrap("entry-a", "type-a", "agent-a");
    expect(commitRouteWithoutPassiveEffects().activeWorkspace).toBe("source");

    connection.onStatusChange?.(false);
    await act(() => {});

    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
    });
    await renderManager();
    expect(connection.requestTaskTypes).toHaveBeenLastCalledWith(
      "/source-project",
    );

    await act(() => {
      connection.onControlMessage?.(globalTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(projectTaskTypes("entry-b", "type-b"));
      connection.onControlMessage?.(agents("agent-b"));
    });

    const fresh = (await renderManager()).draftView;
    if (!fresh || fresh.kind !== "resolved") {
      throw new Error("Fresh project defaults did not resolve");
    }
    expect(fresh.entryPoint).toBe("entry-b");
    expect(fresh.agent).toBe("agent-b");

    await act(() => {
      fresh.onTextChange("create with fresh passive defaults");
      fresh.onSubmit("create with fresh passive defaults", []);
    });
    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry-b",
      [{ type: "text", text: "create with fresh passive defaults" }],
      "agent-b",
      fresh.editorId.slice("composition:".length),
    );
  });

  it("uses an explicit empty server default agent as the current default", async () => {
    await renderManager();
    await act(() => {
      testState.connection!.onControlMessage?.(workspaceCatalog());
      testState.connection!.onControlMessage?.(
        globalTaskTypes("entry", "type"),
      );
      testState.connection!.onControlMessage?.(
        projectTaskTypes("entry", "type"),
      );
      testState.connection!.onControlMessage?.({
        type: "agents_list",
        agents: [],
        default_agent: "",
      } satisfies ControlMessage);
    });

    const draftView = (await renderManager()).draftView;
    if (!draftView || draftView.kind !== "resolved") {
      throw new Error("Empty server default did not resolve the route");
    }
    expect(draftView.agent).toBe("");

    await act(() => {
      draftView.onTextChange("create without an agent default");
      draftView.onSubmit("create without an agent default", []);
    });
    expect(testState.connection!.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry",
      [{ type: "text", text: "create without an agent default" }],
      "",
      "submission-uuid",
    );
  });

  it("keeps a present numeric draft controlled until its own processing update", async () => {
    const draftView = await prepareEditableDraft();
    testState.connection!.requestHistory.mockClear();
    testState.connection!.sendMessage.mockClear();
    testState.navigate.mockClear();
    const connection = testState.connection!;
    connection.saveDraft.mockClear();
    connection.setEntryPoint.mockClear();
    connection.setAgentName.mockClear();
    const image = seedEditorImage(draftView.editorId);
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(71, draftView.text),
      });
    });

    await act(() => {
      testState.uuid = "present-send-nonce";
      draftView.onSubmit("draft to delete", []);
    });

    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(71, "");
    expect(testState.connection!.sendMessage).toHaveBeenCalledWith(
      71,
      [{ type: "text", text: "draft to delete" }],
      "present-send-nonce",
    );
    expect(
      testState.connection!.requestHistory.mock.invocationCallOrder[0],
    ).toBeLessThan(
      testState.connection!.sendMessage.mock.invocationCallOrder[0]!,
    );
    expect(testState.navigate).not.toHaveBeenCalled();

    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    expect(connection.saveDraft).not.toHaveBeenCalled();
    expect(connection.setEntryPoint).not.toHaveBeenCalled();
    expect(connection.setAgentName).not.toHaveBeenCalled();
    expect(manager!.getByTid(71)?.isProcessing).toBe(false);
    expect(manager!.getByTid(71)?.messages).toEqual([]);
    expect(manager!.getByTid(71)?.serverDraft).toBe(draftView.text);
    const frozen = {
      editorId: draftView.editorId,
      text: "draft to delete",
      lifecycle: "submitting",
      disabled: true,
    };
    expect((await renderManager()).draftView).toMatchObject(frozen);
    expect(imageStore.entries.get(draftView.editorId)).toBe(image);

    await act(() => {
      connection.onControlMessage?.({
        type: "draft_updated",
        tid: 71,
        old_draft: "draft to delete",
        new_draft: "",
      });
      connection.onControlMessage?.({
        type: "task_updated",
        task: { ...activeSnapshot(71), isProcessing: false, draft: "" },
      });
      connection.onUnconfirmedUserMessage?.(
        71,
        {
          type: "item/started",
          item_id: "present-user",
          item_type: "user_message",
          content: [{ type: "text", text: "draft to delete" }],
        },
        "present-send-nonce",
      );
      connection.onAgentAck?.(71, "present-send-nonce");
      acceptSubmission(72);
    });
    expect((await renderManager()).draftView).toMatchObject(frozen);
    await act(() => {
      acceptSubmission(71);
    });
    expect(manager!.draftView).toBeNull();
    expect(manager!.getByTid(71)?.serverDraft ?? "").toBe("");
    expect(imageStore.entries.get(draftView.editorId)?.images ?? []).toEqual(
      [],
    );
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it.each(["creating", "present"] as const)(
    "writes only the changed picker before sending a %s draft",
    async (state) => {
      const correlationId =
        state === "creating" ? await prepareCreatingDraft() : undefined;
      const view =
        state === "present"
          ? await prepareEditableDraft()
          : ((await renderManager()).draftView as DraftViewSnapshot);
      const connection = testState.connection!;
      connection.setEntryPoint.mockClear();
      connection.setAgentName.mockClear();
      await act(() => {
        connection.onControlMessage?.({
          type: "agents_list",
          agents: [
            { name: "agent", driver: "claude" },
            { name: "alternate", driver: "claude" },
          ],
          default_agent: "agent",
        });
        view.onAgentChange("alternate");
      });
      if (state === "present") {
        expect(connection.setAgentName).toHaveBeenCalledExactlyOnceWith(
          71,
          "alternate",
        );
      } else {
        expect(connection.setAgentName).not.toHaveBeenCalled();
      }
      const selected = (await renderManager()).draftView as DraftViewSnapshot;
      await act(() => {
        selected.onSubmit(selected.text, []);
      });
      if (state === "creating") {
        expect(connection.sendMessage).not.toHaveBeenCalled();
        await act(() => {
          acknowledgeSubmission(71, correlationId);
        });
      }
      expect(connection.setAgentName).toHaveBeenCalledExactlyOnceWith(
        71,
        "alternate",
      );
      expect(connection.setEntryPoint).not.toHaveBeenCalled();
      expect(connection.sendMessage).toHaveBeenCalledExactlyOnceWith(
        71,
        [{ type: "text", text: selected.text }],
        expect.any(String),
      );
      expect(connection.setAgentName.mock.invocationCallOrder[0]).toBeLessThan(
        connection.sendMessage.mock.invocationCallOrder[0]!,
      );
      expect(
        connection.saveDraft.mock.calls.filter(([, text]) => text === ""),
      ).toEqual([]);
    },
  );

  it("recovers only the rejected normal-message attempt and permits a new nonce", async () => {
    const view = await prepareEditableDraft();
    const connection = testState.connection!;
    const image = seedEditorImage(view.editorId);
    testState.navigate.mockClear();
    testState.outbox.add({
      tid: 94,
      nonce: "another-attempt",
      content: [{ type: "text", text: "other task" }],
      createdAt: Date.now(),
    });
    testState.uuid = "rejected-nonce";
    await act(() => {
      view.onSubmit(view.text, image.images);
    });
    await act(() => {
      rejectSubmission("unmatched-nonce", 71);
    });
    expect(manager!.draftView?.lifecycle).toBe("submitting");
    expect(manager!.serverError).toBeNull();

    await act(() => {
      rejectSubmission("rejected-nonce", 71);
    });
    const recovered = manager!.draftView as DraftViewSnapshot;
    expect(recovered).toMatchObject({
      editorId: view.editorId,
      remoteTid: 71,
      lifecycle: "present",
      disabled: false,
      text: view.text,
      entryPoint: view.entryPoint,
      agent: view.agent,
    });
    expect(imageStore.entries.get(view.editorId)).toBe(image);
    expect(image.images).toHaveLength(1);
    expect(testState.outboxEntries.map((entry) => entry.nonce)).toEqual([
      "another-attempt",
    ]);
    expect(testState.outbox.remove).toHaveBeenCalledExactlyOnceWith(
      "rejected-nonce",
    );
    expect(manager!.serverError?.message).toBe("Agent rejected the submission");
    expect(testState.navigate).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();

    await act(() => {
      manager!.dismissServerError();
    });
    testState.uuid = "retry-nonce";
    await act(() => {
      recovered.onSubmit(recovered.text, image.images);
    });
    await act(() => {
      rejectSubmission("rejected-nonce", 71);
    });
    expect(connection.sendMessage).toHaveBeenCalledTimes(2);
    expect(connection.sendMessage).toHaveBeenLastCalledWith(
      71,
      expect.any(Array),
      "retry-nonce",
    );
    expect(manager!.draftView?.lifecycle).toBe("submitting");
    expect(manager!.serverError).toBeNull();
  });

  it.each([
    ["validation", "error first"],
    ["validation", "receipt first"],
    ["native_undo_refused", "error first"],
    ["native_undo_refused", "receipt first"],
  ] as const)(
    "displays paired %s exactly once with %s",
    async (kind, order) => {
      const validation = kind === "validation";
      if (validation) await prepareSubmittingDraft();
      else await prepareEditableDraft();
      const view = manager!.draftView as DraftViewSnapshot;
      const connection = testState.connection!;
      const image = seedEditorImage(view.editorId);
      testState.navigate.mockClear();
      const tid = validation ? undefined : 71;
      const correlation = validation ? "submission-uuid" : "native-undo-nonce";
      if (!validation) {
        testState.uuid = correlation;
        await act(() => {
          view.onSubmit(view.text, image.images);
        });
      }
      const reason = validation
        ? "Invalid draft configuration"
        : "Native undo in progress";
      const error = { type: "error", tid, message: reason } as const;
      const receipt = {
        type: "cydo/submission_rejected",
        correlation_id: correlation,
        tid,
        kind,
        reason,
      } as const;
      const errorFirst = order === "error first";
      await act(() =>
        connection.onControlMessage?.(errorFirst ? error : receipt),
      );
      expect(manager!.serverError).toEqual(
        errorFirst ? { message: reason, tid } : null,
      );
      expect(manager!.draftView?.disabled).toBe(errorFirst);
      if (errorFirst)
        await act(() => {
          manager!.dismissServerError();
        });
      await act(() =>
        connection.onControlMessage?.(errorFirst ? receipt : error),
      );
      expect(manager!.serverError).toEqual(
        errorFirst ? null : { message: reason, tid },
      );
      if (!errorFirst)
        await act(() => {
          manager!.dismissServerError();
        });
      await act(() => connection.onControlMessage?.(receipt));
      expect(manager!.serverError).toBeNull();
      expect(manager!.draftView).toMatchObject({
        editorId: view.editorId,
        text: view.text,
        entryPoint: view.entryPoint,
        agent: view.agent,
        disabled: false,
        remoteTid: view.remoteTid,
      });
      expect(imageStore.entries.get(view.editorId)).toBe(image);
      expect(image.images).toHaveLength(1);
      if (validation) expect(connection.createTask).toHaveBeenCalledTimes(1);
      else
        expect(testState.outbox.remove).toHaveBeenCalledExactlyOnceWith(
          correlation,
        );
      expect(connection.deleteTask).not.toHaveBeenCalled();
      expect(testState.navigate).not.toHaveBeenCalled();
    },
  );

  it.each([
    "task_unavailable",
    "task_archiving",
    "history_cancelled",
    "delivery_failed",
  ] as const)("displays unpaired %s exactly once", async (kind) => {
    const view = await prepareEditableDraft();
    testState.uuid = "unpaired-nonce";
    await act(() => {
      view.onSubmit(view.text, []);
    });
    const connection = testState.connection!;
    const receipt = {
      type: "cydo/submission_rejected",
      correlation_id: "unpaired-nonce",
      tid: 71,
      kind,
      reason: "Submission failed",
    } as const;
    await act(() => connection.onControlMessage?.(receipt));
    expect(manager!.serverError).toEqual({ message: receipt.reason, tid: 71 });
    expect(manager!.draftView).toMatchObject({
      editorId: view.editorId,
      disabled: false,
    });
    await act(() => {
      manager!.dismissServerError();
    });
    await act(() => connection.onControlMessage?.(receipt));
    expect(manager!.serverError).toBeNull();
    expect(testState.outbox.remove).toHaveBeenCalledExactlyOnceWith(
      "unpaired-nonce",
    );
  });

  it.each(["acceptance", "correlated rejection"] as const)(
    "keeps submitting after an unrelated same-tid error until %s",
    async (outcome) => {
      const view = await prepareEditableDraft();
      testState.uuid = "pending-nonce";
      await act(() => {
        view.onSubmit(view.text, []);
      });
      const connection = testState.connection!;
      await act(() =>
        connection.onControlMessage?.({
          type: "error",
          tid: 71,
          message: "Cannot archive a running task",
        }),
      );
      expect(manager!.serverError?.message).toBe(
        "Cannot archive a running task",
      );
      expect(manager!.draftView).toMatchObject({
        editorId: view.editorId,
        lifecycle: "submitting",
        disabled: true,
      });
      expect(testState.outboxEntries.map(({ nonce }) => nonce)).toEqual([
        "pending-nonce",
      ]);
      expect(testState.outbox.remove).not.toHaveBeenCalled();
      await act(() => {
        if (outcome === "acceptance") acceptSubmission(71);
        else rejectSubmission("pending-nonce", 71);
      });
      if (outcome === "acceptance") expect(manager!.draftView).toBeNull();
      else {
        expect(manager!.draftView).toMatchObject({
          editorId: view.editorId,
          disabled: false,
        });
        expect(testState.outbox.remove).toHaveBeenCalledExactlyOnceWith(
          "pending-nonce",
        );
      }
    },
  );

  it.each(["atomic", "waiting-for-tid"] as const)(
    "retries a rejected pre-tid %s submission only on explicit Submit",
    async (delivery) => {
      if (delivery === "atomic") await prepareSubmittingDraft();
      else {
        await prepareCreatingDraft();
        const view = manager!.draftView as DraftViewSnapshot;
        await act(() => {
          view.onSubmit(view.text, []);
        });
      }
      const pending = manager!.draftView as DraftViewSnapshot;
      const connection = testState.connection!;
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await act(() => {
        rejectSubmission("submission-uuid");
        vi.runOnlyPendingTimers();
      });
      const recovered = manager!.draftView as DraftViewSnapshot;
      expect(recovered).toMatchObject({
        editorId: pending.editorId,
        text: pending.text,
        disabled: false,
      });
      expect(connection.createTask).toHaveBeenCalledTimes(1);
      expect(connection.sendMessage).not.toHaveBeenCalled();
      expect(testState.navigate).not.toHaveBeenCalled();
      await act(() => {
        recovered.onSubmit(recovered.text, []);
      });
      expect(connection.createTask).toHaveBeenCalledTimes(2);
      expect(connection.createTask).toHaveBeenLastCalledWith(
        "source",
        "/source-project",
        "entry",
        [{ type: "text", text: pending.text }],
        "agent",
        "submission-uuid",
      );
    },
  );

  it.each(["receipt", "initial delivery failure", "launch failure"] as const)(
    "persists a rejected atomic draft through %s and retries it as a message",
    async (outcome) => {
      const image = (await prepareSubmittingDraft(true))!;
      await act(() => {
        acknowledgeSubmission(61);
      });
      testState.route.tid = "61";
      const pending = (await renderManager()).draftView as DraftViewSnapshot;
      expect(pending).toMatchObject({ lifecycle: "submitting", remoteTid: 61 });
      const connection = testState.connection!;
      testState.navigate.mockClear();
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      if (outcome === "receipt") {
        await act(() => {
          rejectSubmission("submission-uuid", 61);
        });
      } else {
        const launchFailure = outcome === "launch failure";
        const reason = launchFailure
          ? "Agent executable missing"
          : "Agent rejected delivery";
        await act(() =>
          connection.onControlMessage?.({
            type: "task_updated",
            task: {
              ...persistedSnapshot(61, ""),
              status: "failed",
              error: reason,
            },
          }),
        );
        expect(manager!.serverError?.message).toBe(reason);
        await act(() => {
          manager!.dismissServerError();
        });
        await act(() => {
          connection.onTaskMessage?.(
            61,
            {
              type: "cydo/task_diagnostic",
              severity: "error",
              subject: launchFailure
                ? "Failed to resume session"
                : "Failed to submit initial message",
              body: reason,
            },
            1,
          );
          rejectSubmission("submission-uuid", 61);
          connection.onControlMessage?.({
            type: "task_updated",
            task: {
              ...persistedSnapshot(61, ""),
              status: undefined,
              alive: true,
            },
          });
        });
        expect(manager!.serverError).toBeNull();
      }
      const recovered = (await renderManager()).draftView as DraftViewSnapshot;
      expect(recovered).toMatchObject({
        editorId: pending.editorId,
        text: pending.text,
        remoteTid: 61,
        disabled: false,
      });
      expect(imageStore.entries.get(pending.editorId)).toBe(image);
      expect(image.images).toHaveLength(1);
      await act(() => {
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
        61,
        pending.text,
      );
      await act(() => {
        rejectSubmission("submission-uuid", 61);
      });
      expect(connection.saveDraft).toHaveBeenCalledTimes(1);
      expect(connection.deleteTask).not.toHaveBeenCalled();
      expect(testState.navigate).not.toHaveBeenCalled();

      testState.uuid = "atomic-retry";
      await act(() => {
        recovered.onSubmit(recovered.text, image.images);
      });
      expect(connection.createTask).toHaveBeenCalledTimes(1);
      expect(connection.sendMessage).toHaveBeenCalledExactlyOnceWith(
        61,
        [
          { type: "text", text: pending.text },
          { type: "image", data: "aQ==", media_type: "image/png" },
        ],
        "atomic-retry",
      );
      await act(() => {
        acceptSubmission(61);
      });
      expect(manager!.draftView).toBeNull();
    },
  );

  it.each(["normal", "atomic"] as const)(
    "clearing a recovered failed %s editor leaves the durable task reachable",
    async (delivery) => {
      const tid = delivery === "normal" ? 71 : 61;
      if (delivery === "normal") {
        const view = await prepareEditableDraft();
        testState.uuid = "normal-failure";
        await act(() => {
          view.onSubmit(view.text, []);
        });
      } else {
        await prepareSubmittingDraft();
        await act(() => {
          acknowledgeSubmission(tid);
        });
        testState.route.tid = String(tid);
        await renderManager();
      }

      const connection = testState.connection!;
      const submitting = manager!.draftView as DraftViewSnapshot;
      const image = seedEditorImage(submitting.editorId);
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await act(() => {
        connection.onControlMessage?.({
          type: "task_updated",
          task: {
            ...persistedSnapshot(
              tid,
              delivery === "normal" ? submitting.text : "",
            ),
            status: "failed",
            error: "Agent executable missing",
          },
        });
        connection.onTaskMessage?.(
          tid,
          {
            type: "cydo/task_diagnostic",
            severity: "error",
            subject: "Failed to resume session",
            body: "Agent executable missing",
          },
          1,
        );
        rejectSubmission(
          delivery === "normal" ? "normal-failure" : "submission-uuid",
          tid,
        );
      });

      const recovered = (await renderManager()).draftView as DraftViewSnapshot;
      expect(recovered).toMatchObject({
        editorId: submitting.editorId,
        text: submitting.text,
        disabled: false,
      });
      expect(imageStore.entries.get(recovered.editorId)).toBe(image);
      connection.saveDraft.mockClear();
      testState.navigate.mockClear();
      await act(() => {
        manager!.dismissServerError();
        recovered.onTextChange("");
      });

      await act(() => {
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(tid, "");
      expect(testState.navigate).not.toHaveBeenCalled();
      expect(testState.route.tid).toBe(String(tid));
      const closed = await renderManager();
      expect({
        taskStatus: closed.getByTid(tid)?.status,
        serverDraft: closed.getByTid(tid)?.serverDraft,
        sidebarContainsTask: closed.sidebarTasks.some(
          (task) => task.tid === tid,
        ),
        deleteCalls: connection.deleteTask.mock.calls,
        controlledEditorOpen: closed.draftView !== null,
        imagesRetained: imageStore.entries.has(recovered.editorId),
      }).toEqual({
        taskStatus: "failed",
        serverDraft: undefined,
        sidebarContainsTask: true,
        deleteCalls: [],
        controlledEditorOpen: false,
        imagesRetained: false,
      });
    },
  );

  it.each(["atomic", "normal"] as const)(
    "forgets a submitting editor and its %s correlation on reset",
    async (delivery) => {
      if (delivery === "atomic") {
        await prepareSubmittingDraft();
      } else {
        const view = await prepareEditableDraft();
        testState.uuid = "prior-message-nonce";
        await act(() => {
          view.onSubmit(view.text, []);
        });
      }
      const previous = manager!.draftView as DraftViewSnapshot;
      expect(previous.lifecycle).toBe("submitting");
      seedEditorImage(previous.editorId);
      const connection = testState.connection!;
      testState.route.tid = null;
      await act(() => {
        connection.onStatusChange?.(false);
        connection.onStatusChange?.(true);
        emitGlobalDefaultProjectBootstrap("entry", "blank", "agent");
      });
      const fresh = (await renderManager()).draftView as DraftViewSnapshot;
      expect(fresh.editorId).not.toBe(previous.editorId);
      expect(imageStore.entries.get(previous.editorId)?.images ?? []).toEqual(
        [],
      );
      await act(() => {
        if (delivery === "atomic") rejectSubmission("submission-uuid");
        else rejectSubmission("prior-message-nonce", 71);
      });
      expect(manager!.draftView).toMatchObject({
        editorId: fresh.editorId,
        text: "",
        disabled: false,
      });
      expect(manager!.serverError).toBeNull();
    },
  );

  it("delivers a present draft after detachment without stealing navigation", async () => {
    const attached = await prepareEditableDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    await renderManager();
    testState.connection!.requestHistory.mockClear();
    testState.connection!.sendMessage.mockClear();
    testState.navigate.mockClear();

    await act(() => {
      testState.uuid = "detached-send-nonce";
      attached.onSubmit("draft to delete", []);
    });

    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(71, "");
    expect(testState.connection!.sendMessage).toHaveBeenCalledWith(
      71,
      [{ type: "text", text: "draft to delete" }],
      "detached-send-nonce",
    );
    expect(
      testState.connection!.requestHistory.mock.invocationCallOrder[0],
    ).toBeLessThan(
      testState.connection!.sendMessage.mock.invocationCallOrder[0]!,
    );
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("opens a persisted editor while an unrelated composition is being deleted", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView;
    if (!initial || initial.kind !== "resolved") {
      throw new Error("Project root draft view did not resolve");
    }
    await act(() => {
      initial.onTextChange("transient A");
    });
    await vi.waitFor(() => {
      expect(testState.connection!.createTask).toHaveBeenCalledWith(
        "source",
        "/source-project",
        "entry",
        undefined,
        "agent",
        "submission-uuid",
      );
    });
    await act(() => {
      initial.onTextChange("");
      testState.uuid = "persisted-b-uuid";
      testState.connection!.onControlMessage?.({
        type: "task_created",
        tid: 82,
        workspace: "source",
        project_path: "/source-project",
      } satisfies ControlMessage);
      testState.connection!.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [persistedSnapshot(82)],
      } satisfies ControlMessage);
    });

    testState.route.tid = "82";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:82",
      text: "persisted draft B",
    });

    await act(() => {
      acknowledgeSubmission(81);
    });
    expect(testState.connection!.deleteTask).toHaveBeenCalledWith(81);
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 81,
      } satisfies ControlMessage);
    });

    const opened = (await renderManager()).draftView;
    if (!opened || opened.kind !== "resolved") {
      throw new Error("Deferred persisted draft did not reattach");
    }
    expect(opened.remoteTid).toBe(82);
    expect(opened.text).toBe("persisted draft B");
  });

  it.each([
    "delivery_failed",
    "history_cancelled",
    "native_undo_refused",
    "task_archiving",
    "task_unavailable",
  ] as const)("handles ordinary %s with no composer mounted", async (kind) => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: { ...activeSnapshot(901), draft: "stored draft" },
      } satisfies ControlMessage);
      const task = manager!.getByTid(901)!;
      manager!.send(task.uuid, "retry this message");
      manager!.send(task.uuid, "outcome still unknown");
    });
    const [rejected, pending] = testState.outboxEntries;
    const rejection = {
      type: "cydo/submission_rejected",
      correlation_id: rejected!.nonce,
      tid: 901,
      kind,
      reason: "submission rejected",
    } satisfies ControlMessage;

    await act(() => {
      connection.onControlMessage?.(rejection);
      connection.onControlMessage?.(rejection);
    });

    expect(testState.outboxEntries).toContainEqual(pending);
    const task = manager!.getByTid(901)!;
    expect(task.messages.map((message) => message.nonce)).toEqual([
      pending!.nonce,
    ]);
    expect(manager!.serverError).toEqual({
      message: rejection.reason,
      tid: 901,
    });
    if (kind === "task_unavailable") {
      expect(connection.saveDraft).not.toHaveBeenCalled();
      expect(testState.outboxEntries).toEqual([pending]);
      expect(manager!.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
    } else {
      const draft = "stored draft\n\nretry this message";
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
        901,
        draft,
        rejected!.nonce,
      );
      expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe(draft);
      expect(testState.outboxEntries).toEqual([
        pending,
        { ...rejected, content: [], recoveredDraft: draft },
      ]);
      await act(() => {
        connection.onControlMessage?.({
          type: "draft_updated",
          tid: 901,
          old_draft: "stored draft",
          new_draft: draft,
          correlation_id: rejected!.nonce,
        });
      });
      expect(testState.outboxEntries).toEqual([pending]);
    }
  });

  it("merges with the current ordinary draft and keeps an existing rejection diagnostic", async () => {
    await renderManager();
    const connection = testState.connection!;
    const draftListener = vi.fn();
    const reason = "no active turn to steer";
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: { ...activeSnapshot(901), draft: "old server draft" },
      } satisfies ControlMessage);
      const task = manager!.getByTid(901)!;
      manager!.ordinaryDraftStore.ensure(task.uuid, "current ordinary draft");
      manager!.ordinaryDraftStore.register(task.uuid, draftListener);
      manager!.send(task.uuid, "retry this message");
      connection.onTaskMessage?.(901, {
        type: "cydo/task_diagnostic",
        severity: "error",
        subject: "Failed to submit message",
        body: reason,
      });
      connection.onControlMessage?.({
        type: "cydo/submission_rejected",
        correlation_id: testState.outboxEntries[0]!.nonce,
        tid: 901,
        kind: "delivery_failed",
        reason,
      } satisfies ControlMessage);
    });

    const draft = "current ordinary draft\n\nretry this message";
    expect(draftListener.mock.calls).toEqual([
      ["current ordinary draft"],
      [draft],
    ]);
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      901,
      draft,
      expect.any(String),
    );
    expect(manager!.getByTid(901)!.messages).toMatchObject([
      {
        type: "diagnostic",
        diagnostic: { subject: "Failed to submit message" },
      },
    ]);
    expect(manager!.serverError).toBeNull();
  });

  it.each(["accepted", "rejected"] as const)(
    "settles a message %s just before disconnect without replaying it",
    async (outcome) => {
      await renderManager();
      const connection = testState.connection!;
      const snapshot = () => {
        connection.onControlMessage?.(workspaceCatalog());
        connection.onControlMessage?.({
          type: "tasks_list",
          complete: true,
          tasks: [activeSnapshot(901)],
        });
      };
      await act(snapshot);
      const text = "follow-up at disconnect";
      await act(() => {
        manager!.send(manager!.getByTid(901)!.uuid, text);
      });
      const nonce = testState.outboxEntries[0]!.nonce;
      connection.sendMessage.mockClear();

      // The first save is lost. No draft receipt or server draft arrives.
      connection.saveDraft.mockImplementationOnce(() => false);
      testState.hidden = false;
      await act(() => {
        if (outcome === "rejected") {
          rejectSubmission(nonce, 901);
        } else {
          connection.onUnconfirmedUserMessage?.(
            901,
            {
              type: "item/started",
              item_type: "user_message",
              item_id: "accepted-message",
            },
            nonce,
          );
          expect(testState.outboxEntries).toEqual([]);
          expect(testState.animationFrames.size).toBe(1);
        }
        connection.onStatusChange?.(false);
      });

      expect(testState.outboxEntries).toMatchObject(
        outcome === "rejected" ? [{ nonce, recoveredDraft: text }] : [],
      );
      testState.hidden = true;
      await act(() => {
        connection.onStatusChange?.(true);
        snapshot();
      });

      expect(connection.sendMessage).not.toHaveBeenCalled();
      if (outcome === "accepted") return;

      const task = manager!.getByTid(901)!;
      expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe(text);
      expect(connection.saveDraft.mock.calls).toEqual([
        [901, text, nonce],
        [901, text, nonce],
      ]);

      const edited = text + " edited";
      await act(() => {
        manager!.saveDraft(901, edited);
      });
      const replacement = testState.outboxEntries[0]!;
      expect(replacement.nonce).not.toBe(nonce);
      expect(replacement.recoveredDraft).toBe(edited);

      await act(() => {
        connection.onControlMessage?.({
          type: "draft_updated",
          tid: 901,
          old_draft: "",
          new_draft: text,
          correlation_id: nonce,
        });
      });
      expect(testState.outboxEntries).toEqual([replacement]);

      await act(() => {
        connection.onControlMessage?.({
          type: "draft_updated",
          tid: 901,
          old_draft: text,
          new_draft: edited,
          correlation_id: replacement.nonce,
        });
      });
      expect(testState.outboxEntries).toEqual([]);
    },
  );

  it("removes outbox entries when deleting an ordinary task", async () => {
    await renderManager();
    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_created",
        tid: 901,
        workspace: "source",
        project_path: "/source-project",
      } satisfies ControlMessage);
      manager!.send(manager!.getByTid(901)!.uuid, "must not survive deletion");
    });
    expect(testState.outbox.byTid(901)).toHaveLength(1);

    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 901,
      } satisfies ControlMessage);
    });

    expect(testState.outbox.removeForTask).toHaveBeenCalledWith(901);
    expect(testState.outbox.byTid(901)).toEqual([]);
  });

  it("removes outbox entries when deleting an unmaterialized task", async () => {
    await renderManager();
    testState.outboxEntries = [
      {
        tid: 902,
        nonce: "orphaned-message",
        content: [],
        createdAt: 0,
      },
    ];

    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 902,
      } satisfies ControlMessage);
    });

    expect(testState.outbox.removeForTask).toHaveBeenCalledWith(902);
    expect(testState.outbox.byTid(902)).toEqual([]);
  });

  it("does not replay an ordinary in-epoch send during its first passive outbox flush", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "task_created",
        tid: 903,
        workspace: "source",
        project_path: "/source-project",
      } satisfies ControlMessage);
    });

    const task = manager!.getByTid(903);
    if (!task) throw new Error("Ordinary task did not materialize");
    testState.outbox.all.mockClear();
    connection.onControlMessage?.({
      type: "tasks_list",
      complete: true,
      tasks: [activeSnapshot(903)],
    } satisfies ControlMessage);
    expect(commitRouteWithoutPassiveEffects().getByTid(903)).toBeDefined();

    testState.uuid = "ordinary-open-epoch-nonce";
    manager!.send(task.uuid, "send before the first replay");
    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledWith(
      903,
      [{ type: "text", text: "send before the first replay" }],
      "ordinary-open-epoch-nonce",
    );
    expect(testState.outboxEntries).toEqual([
      expect.objectContaining({
        tid: 903,
        nonce: "ordinary-open-epoch-nonce",
        content: [{ type: "text", text: "send before the first replay" }],
      }),
    ]);

    await renderManager();

    expect(testState.outbox.all).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    expect(testState.outbox.remove).not.toHaveBeenCalled();
    expect(testState.outboxEntries).toEqual([
      expect.objectContaining({
        tid: 903,
        nonce: "ordinary-open-epoch-nonce",
        content: [{ type: "text", text: "send before the first replay" }],
      }),
    ]);
  });

  it("replays an unacknowledged ordinary send once in a fresh epoch", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "task_created",
        tid: 904,
        workspace: "source",
        project_path: "/source-project",
      } satisfies ControlMessage);
    });

    const task = manager!.getByTid(904);
    if (!task) throw new Error("Ordinary task did not materialize");
    testState.uuid = "retry-after-reset-nonce";
    await act(() => {
      manager!.send(task.uuid, "retry in the next epoch");
    });
    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    connection.sendMessage.mockClear();
    testState.outbox.all.mockClear();

    await act(() => {
      connection.onStatusChange?.(false);
    });
    expect(testState.outboxEntries).toEqual([
      expect.objectContaining({
        tid: 904,
        nonce: "retry-after-reset-nonce",
        content: [{ type: "text", text: "retry in the next epoch" }],
      }),
    ]);

    connection.onStatusChange?.(true);
    connection.onControlMessage?.(workspaceCatalog());
    connection.onControlMessage?.({
      type: "tasks_list",
      complete: true,
      tasks: [activeSnapshot(904)],
    } satisfies ControlMessage);
    expect(commitRouteWithoutPassiveEffects().getByTid(904)).toBeDefined();

    await renderManager();

    expect(testState.outbox.all).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledWith(
      904,
      [{ type: "text", text: "retry in the next epoch" }],
      "retry-after-reset-nonce",
    );
    expect(testState.outboxEntries).toEqual([
      expect.objectContaining({
        tid: 904,
        nonce: "retry-after-reset-nonce",
        content: [{ type: "text", text: "retry in the next epoch" }],
      }),
    ]);

    connection.onControlMessage?.({
      type: "task_updated",
      task: activeSnapshot(904),
    } satisfies ControlMessage);
    expect(commitRouteWithoutPassiveEffects().getByTid(904)).toBeDefined();
    await renderManager();

    expect(testState.outbox.all).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
  });

  it("replays an outbox entry only after a fresh epoch tasks list", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });

    testState.outboxEntries = [
      {
        tid: 903,
        nonce: "survive-reconnect",
        content: [{ type: "text", text: "replay after reset" }],
        createdAt: 0,
      },
    ];
    connection.onControlMessage?.({
      type: "tasks_list",
      complete: true,
      tasks: [activeSnapshot(903)],
    } satisfies ControlMessage);
    expect(commitRouteWithoutPassiveEffects().getByTid(903)).toBeDefined();

    connection.onStatusChange?.(false);
    await act(() => {});

    expect(testState.outbox.remove).not.toHaveBeenCalled();
    expect(testState.outboxEntries).toEqual([
      {
        tid: 903,
        nonce: "survive-reconnect",
        content: [{ type: "text", text: "replay after reset" }],
        createdAt: 0,
      },
    ]);
    expect(connection.sendMessage).not.toHaveBeenCalled();

    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [activeSnapshot(903)],
      } satisfies ControlMessage);
    });
    await renderManager();

    expect(connection.sendMessage).toHaveBeenCalledTimes(1);
    expect(connection.sendMessage).toHaveBeenCalledWith(
      903,
      [{ type: "text", text: "replay after reset" }],
      "survive-reconnect",
    );

    const beforeRejection = manager!.tasks;
    await act(() => {
      connection.onControlMessage?.({
        type: "cydo/submission_rejected",
        tid: 903,
        correlation_id: "survive-reconnect",
        kind: "delivery_failed",
        reason: "rejected on new connection",
      } satisfies ControlMessage);
    });
    expect(manager!.tasks).toBe(beforeRejection);
    expect(testState.outboxEntries).toMatchObject([
      { nonce: "survive-reconnect", recoveredDraft: "replay after reset" },
    ]);
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      903,
      "replay after reset",
      "survive-reconnect",
    );
    const task = manager!.getByTid(903)!;
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe(
      "replay after reset",
    );
  });

  it("reconciles an orphaned outbox entry from an empty fresh snapshot once", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });
    testState.outboxEntries = [
      {
        tid: 904,
        nonce: "empty-snapshot-orphan",
        content: [{ type: "text", text: "must be removed" }],
        createdAt: 0,
      },
    ];

    await act(() => {
      connection.onStatusChange?.(false);
    });
    testState.outbox.all.mockClear();
    testState.outbox.remove.mockClear();

    await act(() => {
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [],
      } satisfies ControlMessage);
    });
    await renderManager();

    expect(testState.outbox.remove).toHaveBeenCalledTimes(1);
    expect(testState.outbox.remove).toHaveBeenCalledWith(
      "empty-snapshot-orphan",
    );
    expect(testState.outboxEntries).toEqual([]);
    expect(testState.outbox.all).toHaveBeenCalledTimes(1);

    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(905),
      } satisfies ControlMessage);
    });
    await renderManager();

    expect(testState.outbox.remove).toHaveBeenCalledTimes(1);
    expect(testState.outbox.all).toHaveBeenCalledTimes(1);
  });

  it("reconciles a detached current acknowledgement with its latest form before generic focus resumes", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/source-project",
        entry_points: [
          {
            name: "entry",
            task_type: "blank",
            description: "",
            model_class: "",
            read_only: false,
          },
          {
            name: "latest-entry",
            task_type: "latest-blank",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
    });

    const sourceDraft = (await renderManager()).draftView;
    if (!sourceDraft || sourceDraft.kind !== "resolved") {
      throw new Error("Source draft did not resolve");
    }

    await act(() => {
      sourceDraft.onTextChange("initial text");
      vi.advanceTimersByTime(16);
    });
    expect(connection.createTask).toHaveBeenCalledWith(
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      sourceDraft.editorId.slice("composition:".length),
    );

    await act(() => {
      sourceDraft.onTextChange("latest detached text");
      sourceDraft.onEntryPointChange("latest-entry");
      sourceDraft.onAgentChange("latest-agent");
    });

    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    await renderManager();
    connection.setEntryPoint.mockClear();
    connection.setAgentName.mockClear();
    connection.saveDraft.mockClear();
    connection.requestHistory.mockClear();
    testState.navigate.mockClear();

    const tid = 951;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: sourceDraft.editorId.slice("composition:".length),
      } satisfies ControlMessage);
    });

    expect(testState.navigate).not.toHaveBeenCalled();
    expect(connection.requestHistory).not.toHaveBeenCalled();
    expect(connection.setEntryPoint).toHaveBeenCalledTimes(1);
    expect(connection.setEntryPoint).toHaveBeenCalledWith(tid, "latest-entry");
    expect(connection.setAgentName).toHaveBeenCalledTimes(1);
    expect(connection.setAgentName).toHaveBeenCalledWith(tid, "latest-agent");
    expect(connection.saveDraft).toHaveBeenCalledTimes(1);
    expect(connection.saveDraft).toHaveBeenCalledWith(
      tid,
      "latest detached text",
    );
    expect(connection.setEntryPoint.mock.invocationCallOrder[0]).toBeLessThan(
      connection.setAgentName.mock.invocationCallOrder[0]!,
    );
    expect(connection.setAgentName.mock.invocationCallOrder[0]).toBeLessThan(
      connection.saveDraft.mock.invocationCallOrder[0]!,
    );

    const acknowledged = await renderManager();
    expect(acknowledged.getByTid(tid)).toMatchObject({
      tid,
      status: "pending",
      title: "latest detached text",
      entryPoint: "latest-entry",
      agentName: "latest-agent",
      taskType: "latest-blank",
    });
    expect(acknowledged.getByTid(tid)?.serverDraft).toBeUndefined();
    expect(
      [...acknowledged.tasks.values()].filter((task) => task.tid === tid),
    ).toHaveLength(1);

    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: tid,
      } satisfies ControlMessage);
    });
    expect(testState.navigate).not.toHaveBeenCalled();

    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(tid),
      } satisfies ControlMessage);
    });
    expect((await renderManager()).getByTid(tid)).toMatchObject({
      tid,
      status: "active",
      alive: true,
      isProcessing: true,
    });

    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: tid,
      } satisfies ControlMessage);
    });
    expect(testState.navigate).toHaveBeenCalledTimes(1);
    expect(testState.navigate).toHaveBeenCalledWith("/source/project/task/951");
  });

  it("abandons expected focus on reset before an ordinary reused task ID arrives", async () => {
    await prepareCreatingDraft();
    const connection = testState.connection!;
    const tid = 952;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "submission-uuid",
      } satisfies ControlMessage);
    });

    testState.navigateBrowser("/source/project");
    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [activeSnapshot(tid)],
      } satisfies ControlMessage);
    });

    const fresh = await renderManager();
    expect(fresh.getByTid(tid)).toMatchObject({
      tid,
      status: "active",
      alive: true,
      isProcessing: true,
    });
    testState.navigate.mockClear();

    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: tid,
      } satisfies ControlMessage);
    });

    expect(testState.navigate).toHaveBeenCalledTimes(1);
    expect(testState.navigate).toHaveBeenCalledWith("/source/project/task/952");
  });

  it("materializes an unknown create correlation exactly once as an ordinary task", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    const tid = 953;

    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "unknown-correlation",
      } satisfies ControlMessage);
    });

    const snapshot = await renderManager();
    expect(snapshot.getByTid(tid)).toMatchObject({
      tid,
      status: "pending",
      workspace: "source",
      projectPath: "/source-project",
    });
    expect(
      [...snapshot.tasks.values()].filter((task) => task.tid === tid),
    ).toHaveLength(1);
    expect(connection.deleteTask).not.toHaveBeenCalled();
  });

  it("CAS-reduces same-rAF ordinary A to B to C updates", async () => {
    const { connection, task } = await seedOrdinaryTask();
    manager!.ordinaryDraftStore.ensure(task.uuid, "A");
    const received: string[] = [];
    const unregister = manager!.ordinaryDraftStore.register(
      task.uuid,
      (text) => {
        received.push(text);
      },
    );
    received.length = 0;

    testState.hidden = false;
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "A",
      new_draft: "B",
    } satisfies ControlMessage);
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "B",
      new_draft: "C",
    } satisfies ControlMessage);
    await flushAnimationFrames();

    expect(received).toEqual(["B", "C"]);
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("C");
    expect(manager!.getByTid(42)?.serverDraft).toBe("C");
    unregister();
  });

  it("CAS-reduces a same-rAF ordinary A to B to clear sequence", async () => {
    const { connection, task } = await seedOrdinaryTask();
    manager!.ordinaryDraftStore.ensure(task.uuid, "A");

    testState.hidden = false;
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "A",
      new_draft: "B",
    } satisfies ControlMessage);
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "B",
      new_draft: "",
    } satisfies ControlMessage);
    await flushAnimationFrames();

    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("");
    expect(manager!.getByTid(42)?.serverDraft).toBeUndefined();
  });

  it("keeps absent ordinary blank, equal, and divergent local scalars distinct", async () => {
    const { connection, task } = await seedOrdinaryTask();
    manager!.ordinaryDraftStore.ensure(task.uuid, "");

    testState.hidden = false;
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "A",
      new_draft: "B",
    } satisfies ControlMessage);
    await flushAnimationFrames();
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("B");

    manager!.ordinaryDraftStore.retire(task.uuid);
    manager!.ordinaryDraftStore.ensure(task.uuid, "B");
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "B",
      new_draft: "C",
    } satisfies ControlMessage);
    await flushAnimationFrames();
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("C");

    manager!.ordinaryDraftStore.retire(task.uuid);
    manager!.ordinaryDraftStore.ensure(task.uuid, "local");
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 42,
      old_draft: "C",
      new_draft: "D",
    } satisfies ControlMessage);
    await flushAnimationFrames();
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("local");
  });

  it("retires ordinary scalars on UUID replacement, definitive deletion, and disconnect", async () => {
    const { connection, task } = await seedOrdinaryTask();
    manager!.ordinaryDraftStore.ensure(task.uuid, "local A");

    testState.uuid = "replacement-uuid";
    connection.onControlMessage?.({
      type: "task_created",
      tid: 42,
      workspace: "source",
      project_path: "/source-project",
      correlation_id: "unowned-replacement",
    } satisfies ControlMessage);
    const replacement = manager!.getByTid(42);
    if (!replacement) throw new Error("Expected replacement task");
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBeUndefined();

    manager!.ordinaryDraftStore.ensure(replacement.uuid, "local B");
    connection.onControlMessage?.({
      type: "task_deleted",
      tid: 42,
    } satisfies ControlMessage);
    expect(manager!.ordinaryDraftStore.read(replacement.uuid)).toBeUndefined();

    connection.onControlMessage?.({
      type: "task_updated",
      task: { ...activeSnapshot(43), isProcessing: false },
    } satisfies ControlMessage);
    const fresh = manager!.getByTid(43);
    if (!fresh) throw new Error("Expected fresh ordinary task");
    manager!.ordinaryDraftStore.ensure(fresh.uuid, "local C");
    connection.onStatusChange?.(false);
    expect(manager!.ordinaryDraftStore.read(fresh.uuid)).toBeUndefined();
  });

  it("retires an ordinary scalar when controlled ownership takes its task", async () => {
    const { task } = await seedOrdinaryTask(71, "ordinary A");
    manager!.ordinaryDraftStore.ensure(task.uuid, "ordinary local");

    const correlationId = await prepareCreatingDraft();
    await act(() => {
      acknowledgeSubmission(71, correlationId);
    });

    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
  });

  it("does not resurrect an accepted controlled peer draft after submit and remount", async () => {
    await prepareEditableDraft();
    const connection = testState.connection!;

    testState.hidden = false;
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 71,
      old_draft: "draft to delete",
      new_draft: "peer B",
    } satisfies ControlMessage);
    await flushAnimationFrames();

    const accepted = (await renderManager()).draftView;
    if (!accepted || accepted.kind !== "resolved")
      throw new Error("Expected controlled draft after accepted update");
    expect(accepted.text).toBe("peer B");

    await act(() => {
      accepted.onSubmit("peer B", []);
    });
    await act(() => {
      acceptSubmission(71);
    });
    await flushAnimationFrames();
    expect(manager!.draftView).toBeNull();
    const released = (await renderManager()).getByTid(71);
    if (!released) throw new Error("Expected released ordinary task");
    expect(manager!.ordinaryDraftStore.read(released.uuid)).toBeUndefined();
    expect(
      manager!.ordinaryDraftStore.ensure(
        released.uuid,
        released.serverDraft ?? "",
      ),
    ).toBe("");
    expect(manager!.ordinaryDraftStore.read(released.uuid)).toBe("");
  });

  it("discards peer draft deltas while a numeric clear waits for its deletion acknowledgement", async () => {
    const view = await prepareEditableDraft();
    const task = manager!.getByTid(71)!;
    const connection = testState.connection!;
    const peerUpdate = {
      type: "draft_updated",
      tid: 71,
      old_draft: "draft to delete",
      new_draft: "peer edit during deletion",
    } satisfies ControlMessage;

    testState.hidden = false;
    connection.onControlMessage?.(peerUpdate);
    await act(() => {
      view.onTextChange("");
    });
    expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(71);

    manager!.ordinaryDraftStore.ensure(task.uuid, "draft to delete");
    connection.onControlMessage?.(peerUpdate);
    await flushAnimationFrames();
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBe("draft to delete");
    expect(manager!.getByTid(71)).toBeUndefined();

    connection.onControlMessage?.({ type: "task_deleted", tid: 71 });
    await flushAnimationFrames();
    expect(manager!.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
  });

  it("retires images when clearing an unsent or in-flight composition", async () => {
    await bootstrapProject();
    const initial = (await renderManager()).draftView as DraftViewSnapshot;
    const first = seedEditorImage(initial.editorId);
    await act(() => {
      initial.onTextChange("discard before timer");
      initial.onTextChange("");
    });
    expect(imageStore.entries.has(initial.editorId)).toBe(false);
    expect(first.images).toEqual([]);

    const successor = (await renderManager()).draftView as DraftViewSnapshot;
    await act(() => {
      successor.onTextChange("discard while creating");
    });
    await vi.waitFor(() => {
      expect(testState.connection!.createTask).toHaveBeenCalledTimes(1);
    });
    const second = seedEditorImage(successor.editorId);
    await act(() => {
      successor.onTextChange("");
    });
    expect(imageStore.entries.has(successor.editorId)).toBe(false);
    expect(second.images).toEqual([]);
  });

  it.each([
    "clear",
    "submit",
    "external delete",
    "activity",
    "disconnect",
  ] as const)(
    "retires attachments on numeric editor %s and preserves them while detached",
    async (retirement) => {
      const view = await prepareEditableDraft();
      const entry = seedEditorImage(view.editorId);
      testState.route.tid = null;
      const rootView = (await renderManager()).draftView as DraftViewSnapshot;
      const rootEntry = seedEditorImage(rootView.editorId);
      expect(imageStore.entries.get(view.editorId)).toBe(entry);
      testState.route.tid = "71";
      const attached = (await renderManager()).draftView as DraftViewSnapshot;
      expect(attached.editorId).toBe(view.editorId);
      const connection = testState.connection!;
      await act(() => {
        switch (retirement) {
          case "clear":
            attached.onTextChange("");
            break;
          case "submit":
            attached.onSubmit(attached.text, entry.images);
            acceptSubmission(71);
            break;
          case "external delete":
            connection.onControlMessage?.({ type: "task_deleted", tid: 71 });
            break;
          case "activity":
            connection.onControlMessage?.({
              type: "task_updated",
              task: activeSnapshot(71),
            });
            break;
          case "disconnect":
            connection.onStatusChange?.(false);
            break;
        }
      });
      expect(entry.images).toEqual([]);
      expect(imageStore.entries.has(view.editorId)).toBe(false);
      if (retirement === "disconnect") {
        expect(imageStore.entries.size).toBe(0);
      } else {
        expect(imageStore.entries.get(rootView.editorId)).toBe(rootEntry);
      }
    },
  );

  it("discards a controlled receipt drained after its owner lifetime ends", async () => {
    const attached = await prepareEditableDraft();
    const connection = testState.connection!;

    await act(() => {
      attached.onSubmit("draft to delete", []);
    });
    testState.hidden = false;
    acceptSubmission(71);
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 71,
      old_draft: "draft to delete",
      new_draft: "peer B",
    } satisfies ControlMessage);
    await flushAnimationFrames();

    const released = manager!.getByTid(71);
    if (!released) throw new Error("Expected submitted task");
    expect(manager!.draftView).toBeNull();
    expect(manager!.ordinaryDraftStore.read(released.uuid)).toBeUndefined();
    expect(manager!.getByTid(71)?.serverDraft).toBeUndefined();
    expect(
      manager!.ordinaryDraftStore.ensure(
        released.uuid,
        manager!.getByTid(71)?.serverDraft ?? "",
      ),
    ).toBe("");
  });

  it("routes an ordinary receipt to controlled ownership created earlier in the same rAF", async () => {
    await prepareCreatingDraft();
    const connection = testState.connection!;

    testState.uuid = "ordinary-71-uuid";
    connection.onControlMessage?.(
      tasksList([persistedSnapshot(71, "ordinary A")]),
    );
    testState.uuid = "submission-uuid";
    const ordinary = manager!.getByTid(71);
    if (!ordinary) throw new Error("Expected ordinary task");
    manager!.ordinaryDraftStore.ensure(ordinary.uuid, "ordinary A");
    const received: string[] = [];
    manager!.ordinaryDraftStore.register(ordinary.uuid, (text) => {
      received.push(text);
    });
    received.length = 0;

    testState.hidden = false;
    connection.onControlMessage?.({
      type: "task_created",
      tid: 71,
      workspace: "source",
      project_path: "/source-project",
      correlation_id: "submission-uuid",
    } satisfies ControlMessage);
    connection.onControlMessage?.({
      type: "draft_updated",
      tid: 71,
      old_draft: "editing create before acknowledgement",
      new_draft: "controlled B",
    } satisfies ControlMessage);
    await flushAnimationFrames();

    testState.route.tid = "71";
    const controlled = (await renderManager()).draftView;
    if (!controlled || controlled.kind !== "resolved")
      throw new Error("Expected task_created to own the draft");
    expect(received).toEqual([]);
    expect(controlled.text).toBe("controlled B");
  });
  it("settles a pending numeric save on pagehide while detached", async () => {
    const pageEvents = new EventTarget();
    const previousWindow = Object.getOwnPropertyDescriptor(
      globalThis,
      "window",
    );
    Object.defineProperty(globalThis, "window", {
      value: pageEvents,
      configurable: true,
    });
    try {
      const view = await prepareEditableDraft();
      const connection = testState.connection!;
      connection.saveDraft.mockClear();
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await act(() => {
        view.onTextChange("detached pagehide edit");
      });
      testState.route.tid = null;
      await renderManager();
      expect(connection.saveDraft).not.toHaveBeenCalled();
      await act(() => {
        pageEvents.dispatchEvent(new Event("pagehide"));
        pageEvents.dispatchEvent(new Event("pagehide"));
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
        71,
        "detached pagehide edit",
      );
    } finally {
      await act(() => {
        render(null, root);
      });
      if (previousWindow)
        Object.defineProperty(globalThis, "window", previousWindow);
      else Reflect.deleteProperty(globalThis, "window");
    }
  });

  it("drops a detached pending save when the transport epoch closes", async () => {
    const view = await prepareEditableDraft();
    const connection = testState.connection!;
    connection.saveDraft.mockClear();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("unsaved offline edit");
    });
    testState.route.tid = null;
    await renderManager();
    expect(connection.saveDraft).not.toHaveBeenCalled();
    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "blank"));
      connection.onControlMessage?.(agents("agent"));
      connection.onControlMessage?.(projectTaskTypes("entry", "blank"));
      connection.onControlMessage?.(
        tasksList([persistedSnapshot(71, "server text in new epoch")]),
      );
    });
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();
    testState.route.tid = "71";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:71",
      text: "server text in new epoch",
    });
  });

  it("typing before metadata still files the draft if the user navigates away first", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "global-type"));
      connection.onControlMessage?.(agents("agent"));
      connection.onControlMessage?.(tasksList([activeSnapshot(72)]));
    });
    const view = (await renderManager()).draftView as DraftViewSnapshot;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("before metadata while attached");
    });
    testState.route.tid = "72";
    await renderManager();
    await act(() => {
      connection.onControlMessage?.(projectTaskTypes("entry", "global-type"));
    });
    await act(() => {
      vi.advanceTimersByTime(10000);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(1);
  });

  it("a rejecting catalog keeps a detached editor and saves once", async () => {
    const attached = await seedPreCatalogPersistedDraft(
      persistedSnapshot(95, "start"),
    );
    const connection = testState.connection!;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      attached.onTextChange("one local edit");
      attached.onEntryPointChange("ignored before catalog");
      attached.onAgentChange("ignored before catalog");
    });
    testState.route.tid = null;
    await renderManager();
    await act(() => {
      connection.onControlMessage?.(catalogWithoutEntry);
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      95,
      "one local edit",
    );
    expect(connection.setEntryPoint).not.toHaveBeenCalled();
    expect(connection.setAgentName).not.toHaveBeenCalled();
    testState.route.tid = "95";
    const controlled = await renderManager();
    expect(controlled.draftView).toMatchObject({
      editorId: attached.editorId,
      text: "one local edit",
      submitReady: false,
    });
    expect(
      controlled.ordinaryDraftStore.read(controlled.getByTid(95)!.uuid),
    ).toBeUndefined();
  });

  it.each(["snapshot-first", "catalog-first"] as const)(
    "%s legacy snapshots inherit the same agent default",
    async (order) => {
      testState.route.tid = "95";
      await renderManager();
      const connection = testState.connection!;
      const snapshot = tasksList([
        { ...persistedSnapshot(95, "start"), agent_name: "" },
      ]);
      await act(() => {
        connection.onControlMessage?.(workspaceCatalog());
        if (order === "snapshot-first") connection.onControlMessage?.(snapshot);
      });
      if (order === "snapshot-first") {
        const preCatalog = (await renderManager())
          .draftView as DraftViewSnapshot;
        expect(preCatalog.metadataReady).toBe(false);
        await act(() => {
          preCatalog.onTextChange("changed before metadata");
        });
      }
      await act(() => {
        connection.onControlMessage?.(globalTaskTypes("entry", "global-type"));
        connection.onControlMessage?.(projectTaskTypes("entry", "global-type"));
        connection.onControlMessage?.(agents("agent"));
        if (order === "catalog-first") connection.onControlMessage?.(snapshot);
      });
      const view = (await renderManager()).draftView as DraftViewSnapshot;
      expect(view).toMatchObject({ agent: "agent", metadataReady: true });
    },
  );

  it("scheduled save survives routing to an ordinary task and another project", async () => {
    const view = await prepareEditableDraft();
    const connection = testState.connection!;
    await act(() =>
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(72),
      }),
    );
    connection.saveDraft.mockClear();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("two route changes");
    });
    testState.route.tid = "72";
    expect((await renderManager()).draftView).toBeNull();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    await renderManager();
    expect(connection.saveDraft).not.toHaveBeenCalled();
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      71,
      "two route changes",
    );
  });

  it("immediate submit uses the still-debounced text and clear cancels its sibling write", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() =>
      connection.onControlMessage?.(
        tasksList([
          persistedSnapshot(95, "clear this"),
          persistedSnapshot(96, "submit this"),
        ]),
      ),
    );
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    testState.route.tid = "95";
    const first = (await renderManager()).draftView as DraftViewSnapshot;
    await act(() => {
      first.onTextChange("cancel pending write");
    });
    await act(() => {
      first.onTextChange("");
    });
    testState.route.tid = "96";
    const second = (await renderManager()).draftView as DraftViewSnapshot;
    await act(() => {
      second.onTextChange("latest submitted text");
      second.onSubmit("latest submitted text", []);
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(95);
    expect(connection.sendMessage).toHaveBeenCalledExactlyOnceWith(
      96,
      [{ type: "text", text: "latest submitted text" }],
      expect.any(String),
    );
    expect(connection.saveDraft).not.toHaveBeenCalled();
  });
  it("a pre-save snapshot queued behind a rejecting catalog keeps the controlled text", async () => {
    const snapshot = persistedSnapshot(95, "server draft");
    const view = await seedPreCatalogPersistedDraft(snapshot);
    const connection = testState.connection!;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("latest local edit");
    });
    testState.hidden = false;
    connection.onControlMessage?.(catalogWithoutEntry);
    connection.onControlMessage?.({ type: "task_updated", task: snapshot });
    await flushAnimationFrames();
    expect((await renderManager()).draftView).toMatchObject({
      editorId: view.editorId,
      text: "latest local edit",
      submitReady: false,
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      95,
      "latest local edit",
    );
  });

  it("keeps settled text controlled after bootstrap and repeated catalog changes", async () => {
    const snapshot = persistedSnapshot(95, "old server text");
    const view = await seedPreCatalogPersistedDraft(snapshot);
    const connection = testState.connection!;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("settled local text");
    });
    testState.hidden = false;
    connection.onControlMessage?.(catalogWithoutEntry);
    connection.onControlMessage?.({ type: "task_updated", task: snapshot });
    await flushAnimationFrames();
    expect(connection.saveDraft).not.toHaveBeenCalled();
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "settled local text",
      submitReady: false,
    });

    connection.onControlMessage?.(projectTaskTypes("entry", "blank"));
    await flushAnimationFrames();
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "settled local text",
      submitReady: true,
    });
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
      95,
      "settled local text",
    );
  });

  it("never creates an ordinary scalar for a controlled pending task across catalog changes", async () => {
    const snapshot = persistedSnapshot(95, "old server text");
    testState.route.tid = "95";
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.(globalTaskTypes("entry", "blank"));
      connection.onControlMessage?.(agents("agent"));
      connection.onControlMessage?.({ type: "task_updated", task: snapshot });
    });
    const first = (await renderManager()).draftView as DraftViewSnapshot;
    const task = manager!.getByTid(95)!;
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const frames = [
      catalogWithoutEntry,
      { type: "task_updated", task: snapshot },
      projectTaskTypes("entry", "blank"),
      tasksList([snapshot]),
      catalogWithoutEntry,
    ] satisfies ControlMessage[];
    let submitReady = false;
    for (const [index, frame] of frames.entries()) {
      const text = `edit ${index}`;
      const current = (await renderManager()).draftView as DraftViewSnapshot;
      await act(() => {
        current.onTextChange(text);
        connection.onControlMessage?.(frame);
      });
      if (frame.type === "project_task_types_list")
        submitReady = frame.entry_points.some(({ name }) => name === "entry");
      const controlled = await renderManager();
      expect(controlled.draftView).toMatchObject({
        editorId: first.editorId,
        text,
        submitReady,
      });
      expect(controlled.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
      expect(connection.saveDraft).not.toHaveBeenCalled();
    }
    await act(() => {
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(95, "edit 4");
  });

  it.each([false, true])(
    "keeps settled text across two catalog round trips (batched stale frame: %s)",
    async (batched) => {
      const snapshot = persistedSnapshot(95, "old server text");
      const opened = await seedPreCatalogPersistedDraft(snapshot);
      const connection = testState.connection!;
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      for (const text of ["first settled edit", "second settled edit"]) {
        testState.hidden = true;
        const active = (await renderManager()).draftView as DraftViewSnapshot;
        await act(() => {
          active.onTextChange(text);
          vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
          connection.onControlMessage?.(catalogWithoutEntry);
        });
        expect((await renderManager()).draftView).toMatchObject({
          editorId: opened.editorId,
          text,
          submitReady: false,
        });
        testState.hidden = !batched;
        await act(() => {
          connection.onControlMessage?.(projectTaskTypes("entry", "blank"));
          connection.onControlMessage?.({
            type: "task_updated",
            task: snapshot,
          });
        });
        if (batched) await flushAnimationFrames();
        expect((await renderManager()).draftView).toMatchObject({
          editorId: opened.editorId,
          text,
          submitReady: true,
        });
      }
      expect(connection.saveDraft.mock.calls).toEqual([
        [95, "first settled edit"],
        [95, "second settled edit"],
      ]);
    },
  );

  it("keeps peer CAS on the same editor through several catalog changes", async () => {
    const opened = await seedPreCatalogPersistedDraft(
      persistedSnapshot(95, "baseline"),
    );
    const connection = testState.connection!;
    const peer = (old_draft: string, new_draft: string) =>
      connection.onControlMessage?.({
        type: "draft_updated",
        tid: 95,
        old_draft,
        new_draft,
      });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    let current = opened;
    for (const turn of [1, 2]) {
      const local = `local ${turn}`;
      const accepted = `accepted peer ${turn}`;
      await act(() => {
        current.onTextChange(local);
        connection.onControlMessage?.(catalogWithoutEntry);
        peer("different text", "rejected peer");
      });
      expect((await renderManager()).draftView).toMatchObject({
        editorId: opened.editorId,
        text: local,
        submitReady: false,
      });
      await act(() => {
        connection.onControlMessage?.(projectTaskTypes("entry", "blank"));
        peer(local, accepted);
      });
      current = (await renderManager()).draftView as DraftViewSnapshot;
      expect(current).toMatchObject({
        editorId: opened.editorId,
        text: accepted,
        submitReady: true,
      });
    }
    await act(() => {
      current.onTextChange("");
    });
    expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(95);
  });

  it("retains a catalog received before a project first appears in the workspace list", async () => {
    testState.route.tid = "95";
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "workspaces_list",
        workspaces: [{ name: "source", projects: [] }],
      });
      connection.onControlMessage?.(catalogWithoutEntry);
      connection.onControlMessage?.(globalTaskTypes("entry", "blank"));
      connection.onControlMessage?.(agents("agent"));
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(95, "server text"),
      });
    });
    expect((await renderManager()).draftView).toBeNull();
    await act(() => {
      connection.onControlMessage?.(workspaceCatalog());
    });
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "server text",
      metadataReady: false,
      submitReady: false,
    });
    await act(() => {
      connection.onControlMessage?.(projectTaskTypes("entry", "blank"));
    });
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "server text",
      agent: "agent",
      metadataReady: true,
      submitReady: true,
    });
  });

  it("reopens from the last server observation when a same-epoch snapshot omits its draft", async () => {
    const view = await seedPreCatalogPersistedDraft(
      persistedSnapshot(95, "server baseline"),
    );
    const connection = testState.connection!;
    const { draft: _pendingDraft, ...pending } = persistedSnapshot(95);
    const { draft: _activeDraft, ...active } = activeSnapshot(95);
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      view.onTextChange("unsaved sidebar projection");
    });
    expect(manager!.getByTid(95)?.title).toBe("unsaved sidebar projection");
    expect(manager!.getByTid(95)?.serverDraft).toBe("server baseline");
    await act(() => {
      connection.onControlMessage?.({ type: "task_updated", task: active });
    });
    expect((await renderManager()).draftView).toBeNull();
    await act(() => {
      connection.onControlMessage?.({ type: "task_updated", task: pending });
      vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
    });
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:95",
      text: "server baseline",
    });
    expect(connection.saveDraft).not.toHaveBeenCalled();
  });

  const permutations = (items: readonly number[]): number[][] =>
    items.length === 0
      ? [[]]
      : items.flatMap((item) =>
          permutations(items.filter((other) => other !== item)).map((rest) => [
            item,
            ...rest,
          ]),
        );

  const orderingCases = permutations([0, 1, 2, 3]).flatMap((order) =>
    [false, true].flatMap((detached) =>
      [false, true].flatMap((batched) =>
        [false, true].map((rejecting) => ({
          order: order.join(""),
          detached,
          batched,
          rejecting,
        })),
      ),
    ),
  );

  it.each(orderingCases)(
    "verification ordering $order detached=$detached batched=$batched rejecting=$rejecting",
    async ({ order, detached, batched, rejecting }) => {
      const snapshot = {
        ...persistedSnapshot(95, "old server text"),
        agent_name: undefined,
      };
      testState.route.tid = "95";
      await renderManager();
      const connection = testState.connection!;
      const emit = (msg: ControlMessage) => connection.onControlMessage?.(msg);
      await act(() => {
        emit(workspaceCatalog());
        emit(globalTaskTypes("entry", "blank"));
        emit({ type: "task_updated", task: snapshot });
      });
      const view = (await renderManager()).draftView as DraftViewSnapshot;
      expect(view.editorId).toBe("task:95");
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await act(() => {
        view.onTextChange("settled local text");
      });
      if (detached) {
        testState.route.tid = null;
        await renderManager();
      }
      const frames = [
        projectTaskTypes(rejecting ? "replacement" : "entry", "blank"),
        agents("agent"),
        { type: "task_updated", task: snapshot } as const,
        tasksList([snapshot]),
      ];
      testState.hidden = false;
      for (const n of order) {
        emit(frames[Number(n)]!);
        if (!batched) await flushAnimationFrames();
      }
      if (batched) await flushAnimationFrames();
      await act(() => {
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(connection.saveDraft).toHaveBeenCalledExactlyOnceWith(
        95,
        "settled local text",
      );
      testState.route.tid = "95";
      const controlled = await renderManager();
      const task = controlled.getByTid(95)!;
      expect(controlled.draftView).toMatchObject({
        editorId: "task:95",
        text: "settled local text",
        agent: "agent",
        submitReady: !rejecting,
      });
      expect(controlled.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
      if (rejecting) {
        emit(projectTaskTypes("entry", "blank"));
        await flushAnimationFrames();
        expect((await renderManager()).draftView).toMatchObject({
          editorId: "task:95",
          text: "settled local text",
          agent: "agent",
          submitReady: true,
        });
        expect(controlled.ordinaryDraftStore.read(task.uuid)).toBeUndefined();
      }
    },
  );

  it("drops pending snapshots and history controls queued on both sides of a numeric clear", async () => {
    const view = await prepareEditableDraft();
    const connection = testState.connection!;
    testState.hidden = false;
    const emitPeerTraffic = () => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(71, "stale snapshot"),
      });
      connection.onControlMessage?.({
        type: "task_history_start",
        tid: 71,
        total: 1,
      });
      const event = {
        type: "item/started",
        item_id: "stale",
        item_type: "user_message",
        content: [{ type: "text", text: "stale history" }],
        history_boundary: { anchor: "stale", kind: "user" },
      } satisfies AgnosticEvent;
      connection.onHistoryBoundaryReplaced?.(71, event, 1);
      connection.onTaskMessage?.(71, event, 1);
    };
    emitPeerTraffic();
    await act(() => {
      view.onTextChange("");
    });
    emitPeerTraffic();
    await flushAnimationFrames();
    expect(connection.deleteTask).toHaveBeenCalledExactlyOnceWith(71);
    const settled = await renderManager();
    expect(settled.getByTid(71)).toBeUndefined();
    expect(
      Array.from(settled.tasks.values()).some((task) => task.tid === 71),
    ).toBe(false);
  });

  const retirementCases = (
    ["task_updated", "tasks_list", "task_deleted"] as const
  ).flatMap((retirement) =>
    [false, true].flatMap((detached) =>
      [false, true].map((batched) => ({ retirement, detached, batched })),
    ),
  );

  it.each(retirementCases)(
    "verification $retirement retires pending edits detached=$detached batched=$batched",
    async ({ retirement, detached, batched }) => {
      const tid = 95;
      testState.route.tid = String(tid);
      await renderManager();
      const conn = testState.connection!;
      const pending = persistedSnapshot(tid);
      const active = { ...activeSnapshot(tid), draft: "" };
      await act(() => {
        emitGlobalDefaultProjectBootstrap("entry", "blank", "agent");
        conn.onControlMessage?.({ type: "task_updated", task: pending });
      });
      const view = (await renderManager()).draftView as DraftViewSnapshot;
      expect(view.editorId).toBe(`task:${tid}`);
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await act(() => {
        view.onTextChange("pending local edit");
      });
      if (detached) {
        testState.route.tid = null;
        await renderManager();
      }
      testState.hidden = false;
      conn.onControlMessage?.({ type: "task_updated", task: pending });
      if (!batched) await flushAnimationFrames();
      switch (retirement) {
        case "task_updated":
          conn.onControlMessage?.({ type: retirement, task: active });
          break;
        case "tasks_list":
          conn.onControlMessage?.(tasksList([active]));
          break;
        case "task_deleted":
          conn.onControlMessage?.({ type: retirement, tid });
          break;
      }
      await flushAnimationFrames();
      await act(() => {
        vi.advanceTimersByTime(DRAFT_SAVE_DELAY_MS);
      });
      expect(conn.saveDraft).not.toHaveBeenCalled();
      expect(conn.deleteTask).not.toHaveBeenCalled();
      testState.route.tid = String(tid);
      const settled = await renderManager();
      expect(settled.draftView).toBeNull();
      if (retirement === "task_deleted") {
        expect(settled.getByTid(tid)).toBeUndefined();
      } else {
        expect(settled.getByTid(tid)?.serverDraft).toBeUndefined();
      }
    },
  );

  it("ignores a duplicate late acknowledgement while deletion is outstanding", async () => {
    const correlationId = await prepareCreatingDraft();
    const connection = testState.connection!;
    const a = manager!.draftView;
    if (a?.kind !== "resolved") throw new Error("A did not open");
    await act(() => {
      a.onTextChange("");
    });
    const b = (await renderManager()).draftView;
    if (b?.kind !== "resolved") throw new Error("B did not open");
    expect(b.editorId).not.toBe(a.editorId);
    await act(() => {
      b.onTextChange("B survives");
    });
    await vi.waitFor(() => {
      expect(connection.createTask).toHaveBeenCalledTimes(2);
    });

    connection.saveDraft.mockClear();
    testState.navigate.mockClear();
    const ack = {
      type: "task_created",
      tid: 71,
      workspace: "source",
      project_path: "/source-project",
      correlation_id: correlationId,
    } satisfies ControlMessage;
    await act(() => {
      connection.onControlMessage?.(ack);
      connection.onControlMessage?.(ack);
    });
    expect(connection.deleteTask.mock.calls).toEqual([[71]]);
    expect(connection.saveDraft).not.toHaveBeenCalled();
    expect(testState.navigate).not.toHaveBeenCalled();
    expect(manager!.getByTid(71)).toBeUndefined();
    expect(manager!.draftView).toMatchObject({
      editorId: b.editorId,
      remoteTid: null,
      text: "B survives",
    });

    await act(() => {
      connection.onControlMessage?.({ type: "task_deleted", tid: 71 });
      connection.onControlMessage?.({
        ...ack,
        tid: 72,
        correlation_id: connection.createTask.mock.calls[1]![5] as string,
      });
    });
    testState.route.tid = "72";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: b.editorId,
      remoteTid: 72,
      text: "B survives",
    });
  });

  it("isolates A/B/A through a single numeric clear", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() => {
      for (const task of [
        persistedSnapshot(91, "A"),
        persistedSnapshot(92, "B"),
      ])
        connection.onControlMessage?.({ type: "task_updated", task });
    });
    for (const [tid, text] of [
      [91, "A"],
      [92, "B"],
      [91, "A"],
    ] as const) {
      testState.route.tid = String(tid);
      expect((await renderManager()).draftView).toMatchObject({
        editorId: `task:${tid}`,
        text,
      });
    }
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();
    const a = manager!.draftView;
    if (a?.kind !== "resolved") throw new Error("A did not open");
    await act(() => {
      a.onTextChange(" \t");
      connection.onControlMessage?.({ type: "task_deleted", tid: 91 });
    });
    expect(connection.deleteTask.mock.calls).toEqual([[91]]);
    expect(connection.saveDraft).not.toHaveBeenCalled();
    expect(manager!.getByTid(91)).toBeUndefined();
    testState.route.tid = null;
    expect((await renderManager()).draftView).toMatchObject({
      text: "",
      remoteTid: null,
    });
    testState.route.tid = "92";
    expect((await renderManager()).draftView).toMatchObject({
      text: "B",
      remoteTid: 92,
    });
  });

  it("drops a queued CAS receipt after release and checks CAS on the reopened key", async () => {
    await bootstrapProject();
    const connection = testState.connection!;
    await act(() =>
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(91, "same"),
      }),
    );
    testState.route.tid = "91";
    const old = (await renderManager()).draftView;
    if (old?.kind !== "resolved") throw new Error("A did not open");
    testState.hidden = false;
    const receipt = {
      type: "draft_updated",
      tid: 91,
      old_draft: "same",
      new_draft: "stale lifetime",
    } satisfies ControlMessage;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_updated",
        task: activeSnapshot(91),
      });
      connection.onControlMessage?.(receipt);
    });
    await flushAnimationFrames();
    expect(manager!.getByTid(91)?.serverDraft).toBe("same");
    await act(() =>
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(91, "same"),
      }),
    );
    await flushAnimationFrames();
    expect((await renderManager()).draftView).toMatchObject({
      editorId: old.editorId,
      text: "same",
    });

    await act(() =>
      connection.onControlMessage?.({
        ...receipt,
        old_draft: "wrong",
        new_draft: "bad CAS",
      }),
    );
    await flushAnimationFrames();
    expect(manager!.draftView).toMatchObject({ text: "same" });
    await act(() =>
      connection.onControlMessage?.({
        ...receipt,
        new_draft: "fresh lifetime",
      }),
    );
    await flushAnimationFrames();
    expect(manager!.draftView).toMatchObject({ text: "fresh lifetime" });
  });
  it("drops create aliases, pending frames, and delete tombstones at reset", async () => {
    const correlationId = await prepareCreatingDraft();
    const connection = testState.connection!;
    for (const task of [
      persistedSnapshot(91, "deleting"),
      persistedSnapshot(92, "discarded in epoch"),
    ]) {
      await act(() =>
        connection.onControlMessage?.({ type: "task_updated", task }),
      );
    }
    testState.route.tid = "91";
    const old = (await renderManager()).draftView;
    if (old?.kind !== "resolved") throw new Error("91 did not open");
    await act(() => {
      old.onTextChange("");
    });
    expect(connection.deleteTask.mock.calls).toEqual([[91]]);

    testState.hidden = false;
    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid: 93,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: correlationId,
      });
      connection.onStatusChange?.(false);
    });
    await flushAnimationFrames();
    expect(manager!.getByTid(93)).toBeUndefined();
    expect(manager!.getByTid(92)).toBeUndefined();
    expect(manager!.draftView).toBeNull();
    expect(connection.saveDraft).not.toHaveBeenCalled();

    testState.hidden = true;
    testState.route.tid = null;
    await act(() => connection.onStatusChange?.(true));
    await bootstrapProject();
    expect((await renderManager()).draftView).toMatchObject({
      text: "",
      remoteTid: null,
    });
    await act(() =>
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(91, "new epoch"),
      }),
    );
    testState.route.tid = "91";
    expect((await renderManager()).draftView).toMatchObject({
      editorId: "task:91",
      text: "new epoch",
    });
    expect(connection.deleteTask.mock.calls).toEqual([[91]]);
  });
  it("flushes two detached deferred saves to their exact tids on pagehide", async () => {
    const window = new EventTarget();
    const restoreWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: window,
    });
    try {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      await bootstrapProject();
      const connection = testState.connection!;
      await act(() => {
        for (const task of [
          persistedSnapshot(91, "A"),
          persistedSnapshot(92, "B"),
        ]) {
          connection.onControlMessage?.({ type: "task_updated", task });
        }
      });
      for (const tid of [91, 92]) {
        testState.route.tid = String(tid);
        const draft = (await renderManager()).draftView;
        if (draft?.kind !== "resolved")
          throw new Error("Numeric draft did not open");
        await act(() => {
          draft.onTextChange(`edit ${tid}`);
        });
      }
      testState.route.tid = null;
      await renderManager();
      expect(connection.saveDraft).not.toHaveBeenCalled();
      await act(() => {
        window.dispatchEvent(new Event("pagehide"));
      });
      expect(connection.saveDraft.mock.calls).toEqual([
        [91, "edit 91"],
        [92, "edit 92"],
      ]);
      await act(() => {
        vi.runOnlyPendingTimers();
      });
      expect(connection.saveDraft).toHaveBeenCalledTimes(2);
    } finally {
      await act(() => {
        render(null, root);
      });
      if (restoreWindow)
        Object.defineProperty(globalThis, "window", restoreWindow);
      else Reflect.deleteProperty(globalThis, "window");
    }
  });

  type ReplayEvent = Extract<ReplayOperation, { kind: "event" }>;

  function generatedEvents(count: number, agent: string): ReplayEvent[] {
    const events: ReplayEvent[] = [];
    for (const operation of replayStream("claude", 7)) {
      if (operation.kind !== "event") continue;
      const { event } = operation;
      events.push(
        event.type === "session/init"
          ? { ...operation, event: { ...event, agent } }
          : operation,
      );
      if (events.length === count) break;
    }
    expect(events).toHaveLength(count);
    return events;
  }

  function reduceEvent(task: TaskState, { event, seq, ts }: ReplayEvent) {
    const next = reduceMessage(task, event, seq, ts);
    return (event.type === "item/started" || event.type === "turn/stop") &&
      event.history_boundary
      ? replaceHistoryBoundary(next, event, seq)
      : next;
  }

  async function recoverEditableDraft() {
    const view = await prepareEditableDraft();
    const nonce = "recovered-nonce";
    testState.uuid = nonce;
    await act(() => {
      view.onSubmit(view.text, []);
    });
    await act(() => {
      rejectSubmission(nonce, 71);
    });
    expect(manager!.draftView).toMatchObject({
      editorId: view.editorId,
      text: view.text,
      disabled: false,
    });
    const projection = {
      title: view.text,
      entryPoint: "entry",
      agentName: "agent",
      taskType: "blank",
    };
    expect(manager!.getByTid(71)).toMatchObject(projection);
    return projection;
  }

  describe("recovered draft editor", () => {
    it("seals and publishes once per loaded-task flush", async () => {
      const projection = await recoverEditableDraft();
      const connection = testState.connection!;
      await act(() => {
        connection.onControlMessage?.({ type: "task_history_end", tid: 71 });
      });
      const start = manager!.getByTid(71)!;
      expect(start.historyLoaded).toBe(true);
      deepFreeze(manager!.tasks);
      const events = generatedEvents(90, projection.agentName);
      testState.hidden = false;

      const close = vi.spyOn(WriteBatch.prototype, "close");
      try {
        for (let offset = 0; offset < events.length; offset += 30) {
          const before = manager!.tasks;
          close.mockClear();
          observedTasks = new Set();
          for (const { event, seq, ts } of events.slice(offset, offset + 30)) {
            connection.onTaskMessage?.(71, event, seq, ts);
          }
          expect(manager!.tasks).toBe(before);
          await flushAnimationFrames();
          expect(close).toHaveBeenCalledOnce();
          expect(manager!.tasks).not.toBe(before);
          expect(observedTasks).toEqual(new Set([manager!.tasks]));
          deepFreeze(manager!.tasks);
        }
        expect(manager!.getByTid(71)).toEqual(
          events.reduce(reduceEvent, start),
        );
        expect(manager!.getByTid(71)).toMatchObject(projection);
      } finally {
        observedTasks = undefined;
        close.mockRestore();
      }
    });
  });
});
