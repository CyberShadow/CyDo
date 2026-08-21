import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { OutboxEntry } from "./outbox";
import type { AgnosticEvent, ControlMessage } from "./protocol";
import type {
  DraftViewSnapshot,
  TaskManager,
  TaskSnapshotEntry,
} from "./useSessionManager";

const testState = vi.hoisted(() => {
  const state = {
    uuid: "submission-uuid",
    hidden: true,
    animationFrames: new Map<number, (timestamp: number) => void>(),
    nextAnimationFrame: 0,
    outboxEntries: [] as OutboxEntry[],
    outbox: {
      all: vi.fn(),
      add: vi.fn(),
      remove: vi.fn(),
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
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("crypto", { randomUUID: () => state.uuid });
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
      (candidate) => candidate.nonce !== entry.nonce,
    );
    state.outboxEntries.push(entry);
  });
  state.outbox.remove.mockImplementation((nonce: string) => {
    state.outboxEntries = state.outboxEntries.filter(
      (entry) => entry.nonce !== nonce,
    );
  });
  state.outbox.removeForTask.mockImplementation((tid: number) => {
    state.outboxEntries = state.outboxEntries.filter(
      (entry) => entry.tid !== tid,
    );
  });
  state.outbox.byTid.mockImplementation((tid: number) =>
    state.outboxEntries.filter((entry) => entry.tid === tid),
  );
  return state;
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({ route: testState.navigate }),
  useRoute: () => ({
    params: {
      workspace: testState.route.workspace,
      project: testState.route.project,
      ...(testState.route.tid === null ? {} : { tid: testState.route.tid }),
    },
    path:
      testState.route.tid === null
        ? `/${testState.route.workspace}/${testState.route.project}`
        : `/${testState.route.workspace}/${testState.route.project}/task/${testState.route.tid}`,
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
    readonly disconnect = vi.fn();
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

import { useTaskManager } from "./useSessionManager";

let manager: TaskManager | null = null;
let root: Element;

function ManagerProbe() {
  manager = useTaskManager(testState.addToast);
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

async function prepareSubmittingDraft(): Promise<void> {
  await bootstrapProject();

  const draftManager = await renderManager();
  const draftView = draftManager.draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Project root draft view did not resolve");
  }
  await act(() => {
    draftView.onTextChange("submit before acknowledgement");
    draftView.onSubmit("submit before acknowledgement", []);
  });
  expect(testState.connection!.createTask).toHaveBeenCalledWith(
    "source",
    "/source-project",
    "entry",
    [{ type: "text", text: "submit before acknowledgement" }],
    "agent",
    "submission-uuid",
  );
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

async function prepareCreatingDraft(): Promise<void> {
  await bootstrapProject();
  const draftView = (await renderManager()).draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Project root draft view did not resolve");
  }
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
      "submission-uuid",
    );
  });
}

async function prepareRetainedReplacementDraft(): Promise<DraftViewSnapshot> {
  const attached = await prepareEditableDraft();
  testState.uuid = "replacement-uuid";
  await act(() => {
    attached.onTextChange("");
    attached.onTextChange("replacement draft B");
  });
  expect(testState.connection!.deleteTask).toHaveBeenCalledWith(71);
  return attached;
}

async function submitAtomicReplacement(
  attached: DraftViewSnapshot,
): Promise<void> {
  testState.uuid = "atomic-b-uuid";
  await act(() => {
    attached.onTextChange("");
    attached.onTextChange("atomic submission B");
    attached.onSubmit("atomic submission B", []);
  });
  expect(testState.connection!.deleteTask).toHaveBeenCalledWith(71);
  expect(testState.connection!.createTask).toHaveBeenCalledTimes(1);
}

function activeSnapshot(tid: number): TaskSnapshotEntry {
  return {
    tid,
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

async function preparePreCatalogPersistedDraft(
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
      tasks: [snapshot],
    } satisfies ControlMessage);
    testState.uuid = "submission-uuid";
  });
  const draftView = (await renderManager()).draftView;
  if (!draftView || draftView.kind !== "resolved") {
    throw new Error("Pre-catalog persisted draft did not attach");
  }
  return draftView;
}

function acknowledgeSubmission(tid: number) {
  testState.connection!.onControlMessage?.({
    type: "task_created",
    tid,
    workspace: "source",
    project_path: "/source-project",
    correlation_id: "submission-uuid",
  } satisfies ControlMessage);
}

describe("submission acknowledgement routing", () => {
  beforeEach(() => {
    testState.route.workspace = "source";
    testState.route.project = "project";
    testState.route.tid = null;
    testState.uuid = "submission-uuid";
    testState.hidden = true;
    testState.animationFrames.clear();
    testState.nextAnimationFrame = 0;
    testState.connection = null;
    testState.navigate.mockReset();
    testState.addToast.mockReset();
    testState.outboxEntries = [];
    for (const method of Object.values(testState.outbox)) method.mockClear();
    manager = null;
    root = createRoot();
  });

  afterEach(async () => {
    await act(() => {
      render(null, root);
    });
    vi.useRealTimers();
    testState.hidden = true;
    testState.animationFrames.clear();
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
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(
      61,
      0,
      "desktop",
    );
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
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(
      62,
      0,
      "desktop",
    );
  });

  it("does not route a held submission acknowledgement across a pre-effect route switch", async () => {
    await prepareSubmittingDraft();
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    expect(commitRouteWithoutPassiveEffects().activeWorkspace).toBe("other");
    testState.navigate.mockClear();

    // The route render has committed, but its passive attachment effect is
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

    // This acknowledgement emits draft-ready synchronously, before the route
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

  it("keeps an owned draft view through numeric acknowledgement before its passive attachment effect", async () => {
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
      projectKey: "source\0/source-project",
      viewKey: "source\0/source-project",
      remoteTid: 65,
      lifecycle: "present",
      composerResetToken,
    });
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

  it("resets composer ownership immediately for a local clear only once", async () => {
    const attached = await prepareEditableDraft();
    const initialToken = attached.composerResetToken;

    await act(() => {
      attached.onTextChange("");
    });
    const clearing = (await renderManager()).draftView;
    if (!clearing || clearing.kind !== "resolved") {
      throw new Error("Clearing draft view did not remain resolved");
    }
    expect(clearing).toMatchObject({
      lifecycle: "deleting",
      text: "",
      composerResetToken: initialToken + 1,
    });

    testState.uuid = "replacement-before-ack-uuid";
    await act(() => {
      clearing.onTextChange("");
      clearing.onTextChange("replacement B before acknowledgement");
    });
    const replacement = (await renderManager()).draftView;
    if (!replacement || replacement.kind !== "resolved") {
      throw new Error("Replacement draft view did not remain resolved");
    }
    expect(replacement).toMatchObject({
      text: "replacement B before acknowledgement",
      composerResetToken: initialToken + 1,
    });

    await act(() => {
      testState.connection!.onControlMessage?.({
        type: "task_deleted",
        tid: 71,
      } satisfies ControlMessage);
    });
    testState.route.tid = null;
    const afterDeletion = (await renderManager()).draftView;
    if (!afterDeletion || afterDeletion.kind !== "resolved") {
      throw new Error("Replacement draft did not return to the project root");
    }
    const postReleaseToken = afterDeletion.composerResetToken;
    expect(postReleaseToken).toBe(initialToken + 1);

    await act(() => {
      afterDeletion.onTextChange("replacement B after acknowledgement");
    });
    expect((await renderManager()).draftView).toMatchObject({
      text: "replacement B after acknowledgement",
      composerResetToken: postReleaseToken,
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

  it.each(["task_updated", "tasks_list"] as const)(
    "retains replacement B ownership through authoritative %s activity",
    async (source) => {
      await prepareRetainedReplacementDraft();
      const deleting = await renderManager();
      expect(deleting.getByTid(71)).toBeUndefined();
      expect(
        [...deleting.tasks.values()].filter((task) => task.tid === 71),
      ).toHaveLength(0);
      testState.route.tid = null;
      const replacement = (await renderManager()).draftView;
      if (!replacement || replacement.kind !== "resolved") {
        throw new Error("Replacement draft did not attach to the project root");
      }
      const composerResetToken = replacement.composerResetToken;
      const connection = testState.connection!;
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      connection.createTask.mockImplementationOnce(() => {
        expect(manager!.getByTid(71)).toMatchObject({
          tid: 71,
          alive: true,
          isProcessing: true,
          status: "active",
        });
      });

      await act(() => {
        if (source === "task_updated") {
          connection.onControlMessage?.({
            type: "task_updated",
            task: activeSnapshot(71),
          } satisfies ControlMessage);
        } else {
          connection.onControlMessage?.({
            type: "tasks_list",
            tasks: [activeSnapshot(71)],
          } satisfies ControlMessage);
        }
      });

      const afterHandoffManager = await renderManager();
      const afterHandoff = afterHandoffManager.draftView;
      if (!afterHandoff || afterHandoff.kind !== "resolved") {
        throw new Error("Replacement draft did not survive tombstone handoff");
      }
      expect(afterHandoffManager.getByTid(71)).toMatchObject({
        tid: 71,
        alive: true,
        isProcessing: true,
        status: "active",
      });
      expect(afterHandoff).toMatchObject({
        projectKey: "source\0/source-project",
        text: "replacement draft B",
        composerResetToken,
        disabled: false,
      });
      await act(() => {
        afterHandoff.onSubmit("replacement draft B", [
          {
            id: "replacement-image",
            dataURL: "data:image/png;base64,cmVwbGFjZW1lbnQ=",
            base64: "cmVwbGFjZW1lbnQ=",
            mediaType: "image/png",
          },
        ]);
      });
      expect(connection.createTask).toHaveBeenLastCalledWith(
        "source",
        "/source-project",
        "entry",
        [
          { type: "text", text: "replacement draft B" },
          {
            type: "image",
            data: "cmVwbGFjZW1lbnQ=",
            media_type: "image/png",
          },
        ],
        "agent",
        "replacement-uuid",
      );
    },
  );

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
      creating.onTextChange("replacement draft B");
    });
    const replacement = (await renderManager()).draftView;
    if (!replacement || replacement.kind !== "resolved") {
      throw new Error("Replacement B draft view did not resolve");
    }
    const composerResetToken = replacement.composerResetToken;
    expect(replacement).toMatchObject({
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
      lifecycle: "deleting",
      remoteTid: tidA,
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

  it("keeps an initialized slot editable while workspace metadata is temporarily absent", async () => {
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
      throw new Error("Cached project slot did not remain resolved");
    }
    expect(unavailable).toMatchObject({
      projectKey: "source\0/source-project",
      viewKey: "source\0/source-project",
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
      throw new Error("Cached project slot did not restore");
    }
    expect(restored).toMatchObject({
      projectKey: "source\0/source-project",
      viewKey: "source\0/source-project",
      text: "must not create while metadata is unavailable",
      entryPoint: "entry",
      agent: "agent",
      disabled: false,
      metadataReady: true,
      composerResetToken,
    });
  });

  it("detaches a cached slot from unrelated numeric routes during metadata loss", async () => {
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
    expect(pendingTaskRoute.draftView).toBeNull();
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
      projectKey: "source\0/source-project",
      viewKey: "source\0/source-project",
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

  it("settles a stable persisted switch before passive route attachment", async () => {
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
            name: "entry-b",
            task_type: "blank-b",
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
        type_info: [],
      } satisfies ControlMessage);
      testState.uuid = "persisted-a-uuid";
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(91, "persisted A"),
      } satisfies ControlMessage);
      testState.uuid = "persisted-b-uuid";
      connection.onControlMessage?.({
        type: "task_updated",
        task: {
          ...persistedSnapshot(92, "persisted B"),
          task_type: "blank-b",
          entry_point: "entry-b",
          agent_name: "agent-b",
        },
      } satisfies ControlMessage);
      testState.uuid = "submission-uuid";
    });

    testState.route.tid = "91";
    const attachedA = (await renderManager()).draftView;
    if (!attachedA || attachedA.kind !== "resolved") {
      throw new Error("Persisted A did not attach to its numeric route");
    }
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      attachedA.onTextChange("persisted A with local edits");
    });
    const editedA = (await renderManager()).draftView;
    if (!editedA || editedA.kind !== "resolved") {
      throw new Error("Edited persisted A did not remain resolved");
    }
    const composerResetToken = editedA.composerResetToken;
    connection.createTask.mockClear();
    connection.deleteTask.mockClear();
    connection.setEntryPoint.mockClear();
    connection.setAgentName.mockClear();
    connection.saveDraft.mockClear();

    testState.route.tid = "92";
    const beforePassive = commitRouteWithoutPassiveEffects().draftView;
    if (!beforePassive || beforePassive.kind !== "resolved") {
      throw new Error("Persisted B did not settle before passive attachment");
    }
    expect(beforePassive).toMatchObject({
      projectKey: "source\0/source-project",
      viewKey: "source\0/source-project",
      remoteTid: 91,
      text: "persisted A with local edits",
      entryPoint: "entry",
      agent: "agent",
      composerResetToken,
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();

    const afterPassive = (await renderManager()).draftView;
    expect(afterPassive).toMatchObject({
      kind: "resolved",
      projectKey: "source\0/source-project",
      remoteTid: 92,
      text: "persisted B",
      entryPoint: "entry-b",
      agent: "agent-b",
      composerResetToken: composerResetToken + 1,
    });
    expect(connection.setEntryPoint).toHaveBeenCalledWith(91, "entry");
    expect(connection.setAgentName).toHaveBeenCalledWith(91, "agent");
    expect(connection.saveDraft).toHaveBeenCalledWith(
      91,
      "persisted A with local edits",
    );
  });

  it("waits for passive slot initialization before adopting a reset numeric draft", async () => {
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
        tasks: [persistedSnapshot(91, "reloaded persisted draft")],
      } satisfies ControlMessage);
      testState.uuid = "submission-uuid";
    });

    const adopted = (await renderManager()).draftView;
    if (!adopted || adopted.kind !== "resolved") {
      throw new Error("Passive initialization did not adopt the numeric draft");
    }
    expect(adopted).toMatchObject({
      projectKey: "source\0/source-project",
      remoteTid: 91,
      text: "reloaded persisted draft",
      entryPoint: "entry",
      agent: "agent",
    });
    expect(connection.createTask).not.toHaveBeenCalled();
    expect(connection.deleteTask).not.toHaveBeenCalled();
  });

  it("projects active A before atomically creating submitting B after a tombstone handoff", async () => {
    const attached = await prepareEditableDraft();
    await submitAtomicReplacement(attached);
    const connection = testState.connection!;
    connection.createTask.mockImplementationOnce(() => {
      expect(manager!.getByTid(71)).toMatchObject({
        tid: 71,
        alive: true,
        isProcessing: true,
        status: "active",
      });
    });

    await act(() => {
      connection.onControlMessage?.({
        type: "tasks_list",
        tasks: [activeSnapshot(71)],
      } satisfies ControlMessage);
    });

    expect(connection.createTask).toHaveBeenLastCalledWith(
      "source",
      "/source-project",
      "entry",
      [{ type: "text", text: "atomic submission B" }],
      "agent",
      "atomic-b-uuid",
    );
  });

  it("reduces a present owned task message before its controller handoff effect", async () => {
    const attached = await prepareEditableDraft();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      attached.onTextChange("A waits for its pending save");
    });
    const connection = testState.connection!;
    expect(connection.deleteTask).not.toHaveBeenCalled();
    const originalClearTimeout = globalThis.clearTimeout;
    let sawControllerHandoff = false;
    const clearTimeoutSpy = vi
      .spyOn(globalThis, "clearTimeout")
      .mockImplementation((handle) => {
        sawControllerHandoff = true;
        expect(manager!.getByTid(71)?.messages).toContainEqual(
          expect.objectContaining({
            type: "user",
            content: [{ type: "text", text: "A became active" }],
          }),
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
    const originalClearTimeout = globalThis.clearTimeout;
    let sawControllerHandoff = false;
    const clearTimeoutSpy = vi
      .spyOn(globalThis, "clearTimeout")
      .mockImplementation((handle) => {
        sawControllerHandoff = true;
        expect(manager!.getByTid(71)?.messages).toContainEqual(
          expect.objectContaining({
            type: "user",
            nonce: "a-agent-ack",
            ackState: 2,
          }),
        );
        originalClearTimeout(handle);
      });

    try {
      await act(() => {
        connection.onAgentAck?.(71, "a-agent-ack");
      });
      expect(sawControllerHandoff).toBe(true);
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
      projectKey: "source\0/source-project",
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

  it("keeps a canonical draft's metadata gate closed until passive resolution", async () => {
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

    const text = "type before passive metadata resolution";
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await act(() => {
      waitingForMetadata.onTextChange(text);
    });

    connection.onControlMessage?.(projectTaskTypes("project-entry", "blank"));
    const beforePassive = commitRouteWithoutPassiveEffects().draftView;
    if (!beforePassive || beforePassive.kind !== "resolved") {
      throw new Error(
        "Canonical project draft did not commit before metadata resolution",
      );
    }
    expect(beforePassive).toMatchObject({
      text,
      entryPoint: "",
      agent: "",
      disabled: false,
      metadataReady: false,
    });

    beforePassive.onSubmit(text, []);
    expect(connection.createTask).not.toHaveBeenCalled();

    await act(() => {});
    const resolved = (await renderManager()).draftView;
    if (!resolved || resolved.kind !== "resolved") {
      throw new Error("Canonical project draft did not resolve metadata");
    }
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

  it("projects a pre-catalog persisted edit from its snapshot task type", async () => {
    const draftView = await preparePreCatalogPersistedDraft({
      ...persistedSnapshot(91, "persisted before catalog"),
      task_type: "snapshot-type",
    });
    const connection = testState.connection!;

    expect(draftView.metadataReady).toBe(false);
    await act(() => {
      draftView.onTextChange("edited before catalog");
      draftView.onBlur();
    });

    expect(connection.saveDraft).toHaveBeenCalledWith(
      91,
      "edited before catalog",
    );
    expect(manager!.getByTid(91)).toMatchObject({
      entryPoint: "entry",
      agentName: "agent",
      taskType: "snapshot-type",
      serverDraft: "edited before catalog",
    });
  });

  it("fails fast when a pre-catalog persisted task lacks its snapshot task type", async () => {
    const draftView = await preparePreCatalogPersistedDraft({
      ...persistedSnapshot(92),
      task_type: undefined,
    });

    expect(() => {
      draftView.onBlur();
    }).toThrow("Draft projection requires task type 92");
  });

  it("fails fast when a pre-catalog persisted task entry point diverges from its form", async () => {
    const draftView = await preparePreCatalogPersistedDraft(
      persistedSnapshot(93),
    );
    const task = manager!.getByTid(93);
    if (!task)
      throw new Error("Pre-catalog persisted task did not materialize");
    task.entryPoint = "different-entry";

    expect(() => {
      draftView.onBlur();
    }).toThrow("Draft projection entry point does not match task 93");
  });

  it("validates a persisted task against an arrived catalog without rewriting it", async () => {
    await preparePreCatalogPersistedDraft({
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
      remoteTid: 95,
      entryPoint: "entry-b",
      agent: "agent-b",
      metadataReady: true,
    });
  });

  it("keeps an empty arrived project catalog authoritative", async () => {
    const draftView = await preparePreCatalogPersistedDraft({
      ...persistedSnapshot(95),
      task_type: "snapshot-type",
    });
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "project_task_types_list",
        project_path: "/source-project",
        entry_points: [],
        type_info: [],
      } satisfies ControlMessage);
    });

    expect(() => {
      draftView.onBlur();
    }).toThrow("Unknown entry point: entry");
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
    expect(afterLocalClear.composerResetToken).toBeGreaterThan(
      afterZeroReset.composerResetToken,
    );

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
    expect(afterIncrementedReset.composerResetToken).toBeGreaterThan(
      afterLocalClear.composerResetToken,
    );

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

    testState.uuid = "fresh-b-uuid";
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
      "fresh-b-uuid",
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

    testState.uuid = "closed-interval-b-uuid";
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
      "closed-interval-b-uuid",
    );
  });

  it("does not initialize a reset slot from a pending old-epoch effect", async () => {
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

    testState.uuid = "stale-slot-b-uuid";
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
      "stale-slot-b-uuid",
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

  it("submits a present draft from the attached project root after history subscription", async () => {
    await prepareEditableDraft();
    testState.route.tid = null;
    const draftView = (await renderManager()).draftView;
    if (!draftView || draftView.kind !== "resolved") {
      throw new Error("Present draft did not reattach to the project root");
    }
    testState.connection!.requestHistory.mockClear();
    testState.connection!.sendMessage.mockClear();
    testState.navigate.mockClear();

    await act(() => {
      draftView.onSubmit("draft to delete", []);
    });

    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(
      71,
      0,
      "desktop",
    );
    expect(testState.connection!.sendMessage).toHaveBeenCalledWith(
      71,
      [{ type: "text", text: "draft to delete" }],
      "submission-uuid",
    );
    expect(
      testState.connection!.requestHistory.mock.invocationCallOrder[0],
    ).toBeLessThan(
      testState.connection!.sendMessage.mock.invocationCallOrder[0]!,
    );
    expect(testState.navigate).toHaveBeenCalledWith(
      "/source/project/task/71",
      true,
    );

    testState.route.tid = "71";
    expect((await renderManager()).draftView).toBeNull();
  });

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
      attached.onSubmit("draft to delete", []);
    });

    expect(testState.connection!.requestHistory).toHaveBeenCalledTimes(1);
    expect(testState.connection!.requestHistory).toHaveBeenCalledWith(
      71,
      0,
      "desktop",
    );
    expect(testState.connection!.sendMessage).toHaveBeenCalledWith(
      71,
      [{ type: "text", text: "draft to delete" }],
      "submission-uuid",
    );
    expect(
      testState.connection!.requestHistory.mock.invocationCallOrder[0],
    ).toBeLessThan(
      testState.connection!.sendMessage.mock.invocationCallOrder[0]!,
    );
    expect(testState.navigate).not.toHaveBeenCalled();
  });

  it("retries deferred persisted adoption after reducer-only deletion settles", async () => {
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
        tasks: [persistedSnapshot(82)],
      } satisfies ControlMessage);
    });

    testState.route.tid = "82";
    expect((await renderManager()).draftView).toBeNull();

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

    const adopted = (await renderManager()).draftView;
    if (!adopted || adopted.kind !== "resolved") {
      throw new Error("Deferred persisted draft did not reattach");
    }
    expect(adopted.remoteTid).toBe(82);
    expect(adopted.text).toBe("persisted draft B");
  });

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

    testState.uuid = "current-detached-ack";
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
      "current-detached-ack",
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
        correlation_id: "current-detached-ack",
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
      serverDraft: "latest detached text",
      entryPoint: "latest-entry",
      agentName: "latest-agent",
      taskType: "latest-blank",
    });
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

    await act(() => {
      connection.onStatusChange?.(false);
      connection.onStatusChange?.(true);
      connection.onControlMessage?.(workspaceCatalog());
      connection.onControlMessage?.({
        type: "tasks_list",
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

  it("keeps retained stale generations isolated across canonical project keys", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await bootstrapProject();
    const connection = testState.connection!;
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

    const sourceDraft = (await renderManager()).draftView;
    if (!sourceDraft || sourceDraft.kind !== "resolved") {
      throw new Error("Source draft did not resolve");
    }
    testState.uuid = "source-a-correlation";
    await act(() => {
      sourceDraft.onTextChange("source A");
      vi.advanceTimersByTime(16);
    });

    testState.route.workspace = "other";
    testState.route.project = "other-project";
    testState.route.tid = null;
    const otherDraft = (await renderManager()).draftView;
    if (!otherDraft || otherDraft.kind !== "resolved") {
      throw new Error("Other draft did not resolve");
    }
    expect(otherDraft).toMatchObject({
      projectKey: "other\0/other-project",
      entryPoint: "entry",
      agent: "agent",
    });
    testState.uuid = "other-c-correlation";
    await act(() => {
      otherDraft.onTextChange("other C");
      vi.advanceTimersByTime(16);
    });

    testState.uuid = "source-b-correlation";
    await act(() => {
      sourceDraft.onTextChange("");
      sourceDraft.onTextChange("source B");
    });
    testState.uuid = "other-d-correlation";
    await act(() => {
      otherDraft.onTextChange("");
      otherDraft.onTextChange("other D");
    });

    expect(connection.createTask).toHaveBeenCalledTimes(2);
    expect(connection.createTask).toHaveBeenNthCalledWith(
      1,
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      "source-a-correlation",
    );
    expect(connection.createTask).toHaveBeenNthCalledWith(
      2,
      "other",
      "/other-project",
      "entry",
      undefined,
      "agent",
      "other-c-correlation",
    );

    const sourceTid = 954;
    const otherTid = 955;
    connection.deleteTask.mockClear();
    connection.requestHistory.mockClear();
    testState.navigate.mockClear();
    await act(() => {
      connection.onControlMessage?.({
        type: "task_created",
        tid: otherTid,
        workspace: "other",
        project_path: "/other-project",
        correlation_id: "other-c-correlation",
      } satisfies ControlMessage);
      connection.onControlMessage?.({
        type: "task_created",
        tid: sourceTid,
        workspace: "source",
        project_path: "/source-project",
        correlation_id: "source-a-correlation",
      } satisfies ControlMessage);
    });

    expect(connection.deleteTask).toHaveBeenCalledTimes(2);
    expect(connection.deleteTask).toHaveBeenNthCalledWith(1, otherTid);
    expect(connection.deleteTask).toHaveBeenNthCalledWith(2, sourceTid);
    expect(connection.requestHistory).not.toHaveBeenCalled();
    expect(testState.navigate).not.toHaveBeenCalled();
    expect(manager!.getByTid(sourceTid)).toBeUndefined();
    expect(manager!.getByTid(otherTid)).toBeUndefined();
    expect(
      [...manager!.tasks.values()].filter(
        (task) => task.tid === sourceTid || task.tid === otherTid,
      ),
    ).toHaveLength(0);

    testState.route.workspace = "source";
    testState.route.project = "project";
    const sourceDeleting = commitRouteWithoutPassiveEffects().draftView;
    if (!sourceDeleting || sourceDeleting.kind !== "resolved") {
      throw new Error("Source retained generation did not remain resolved");
    }
    expect(sourceDeleting).toMatchObject({
      projectKey: "source\0/source-project",
      text: "source B",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "deleting",
      remoteTid: sourceTid,
    });
    testState.route.workspace = "other";
    testState.route.project = "other-project";
    const otherDeleting = commitRouteWithoutPassiveEffects().draftView;
    if (!otherDeleting || otherDeleting.kind !== "resolved") {
      throw new Error("Other retained generation did not remain resolved");
    }
    expect(otherDeleting).toMatchObject({
      projectKey: "other\0/other-project",
      text: "other D",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "deleting",
      remoteTid: otherTid,
    });

    await act(() => {
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: otherTid,
      } satisfies ControlMessage);
      connection.onControlMessage?.({
        type: "focus_hint",
        from_tid: 0,
        to_tid: sourceTid,
      } satisfies ControlMessage);
      connection.onTaskMessage?.(sourceTid, {
        type: "item/started",
        item_id: "source-tombstone-message",
        item_type: "user_message",
        content: [{ type: "text", text: "source pending traffic" }],
      });
      connection.onAgentAck?.(sourceTid, "source-tombstone-ack");
      connection.onControlMessage?.({
        type: "task_updated",
        task: persistedSnapshot(sourceTid, "source pending traffic"),
      } satisfies ControlMessage);
      connection.onTaskMessage?.(otherTid, {
        type: "item/started",
        item_id: "other-tombstone-message",
        item_type: "user_message",
        content: [{ type: "text", text: "other pending traffic" }],
      });
      connection.onAgentAck?.(otherTid, "other-tombstone-ack");
      connection.onControlMessage?.({
        type: "task_updated",
        task: {
          ...persistedSnapshot(otherTid, "other pending traffic"),
          workspace: "other",
          project_path: "/other-project",
        },
      } satisfies ControlMessage);
    });

    expect(testState.navigate).not.toHaveBeenCalled();
    expect(manager!.getByTid(sourceTid)).toBeUndefined();
    expect(manager!.getByTid(otherTid)).toBeUndefined();
    expect(connection.deleteTask).toHaveBeenCalledTimes(2);
    expect(connection.createTask).toHaveBeenCalledTimes(2);

    await act(() => {
      connection.onControlMessage?.({
        type: "task_deleted",
        tid: sourceTid,
      } satisfies ControlMessage);
      vi.advanceTimersByTime(15);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(2);
    await act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(3);
    expect(connection.createTask).toHaveBeenNthCalledWith(
      3,
      "source",
      "/source-project",
      "entry",
      undefined,
      "agent",
      "source-b-correlation",
    );

    const otherStillDeleting = commitRouteWithoutPassiveEffects().draftView;
    if (!otherStillDeleting || otherStillDeleting.kind !== "resolved") {
      throw new Error("Other deletion wait did not retain its generation");
    }
    expect(otherStillDeleting).toMatchObject({
      projectKey: "other\0/other-project",
      text: "other D",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "deleting",
      remoteTid: otherTid,
    });

    testState.route.workspace = "source";
    testState.route.project = "project";
    const sourceReplacement = commitRouteWithoutPassiveEffects().draftView;
    if (!sourceReplacement || sourceReplacement.kind !== "resolved") {
      throw new Error("Source replacement did not remain resolved");
    }
    expect(sourceReplacement).toMatchObject({
      projectKey: "source\0/source-project",
      text: "source B",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating",
    });

    testState.route.workspace = "other";
    testState.route.project = "other-project";

    await act(() => {
      connection.onControlMessage?.({
        type: "task_deleted",
        tid: otherTid,
      } satisfies ControlMessage);
      vi.advanceTimersByTime(15);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(3);
    await act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(connection.createTask).toHaveBeenCalledTimes(4);
    expect(connection.createTask).toHaveBeenNthCalledWith(
      4,
      "other",
      "/other-project",
      "entry",
      undefined,
      "agent",
      "other-d-correlation",
    );
    const otherReplacement = commitRouteWithoutPassiveEffects().draftView;
    if (!otherReplacement || otherReplacement.kind !== "resolved") {
      throw new Error("Other replacement did not remain resolved");
    }
    expect(otherReplacement).toMatchObject({
      projectKey: "other\0/other-project",
      text: "other D",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating",
    });

    testState.route.workspace = "source";
    testState.route.project = "project";
    expect(commitRouteWithoutPassiveEffects().draftView).toMatchObject({
      projectKey: "source\0/source-project",
      text: "source B",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating",
    });
    expect(
      connection.createTask.mock.calls.map((call) => String(call[5])),
    ).toEqual([
      "source-a-correlation",
      "other-c-correlation",
      "source-b-correlation",
      "other-d-correlation",
    ]);
  });
});
