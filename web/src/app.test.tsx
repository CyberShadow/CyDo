/** @vitest-environment jsdom */

import {
  h,
  options,
  render,
  toChildArray,
  type ComponentChildren,
  type VNode,
} from "preact";
import renderToString from "preact-render-to-string";
import { act } from "preact/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { actPoll, actStep, ownedRoots } from "./test-support/preactAct";
import { waitFor } from "./test-support/waitFor";
import type { ControlledImageStore } from "./controlledImageStore";
import type { ControlMessage } from "./protocol";
import type { DraftViewSnapshot, TaskManager } from "./useSessionManager";
import { makeTaskState, type TaskState } from "./types";
import { createOrdinaryDraftStore } from "./ordinaryDraftStore";

const state = vi.hoisted(() => ({
  serverError: null as TaskManager["serverError"],
  dismissServerError: vi.fn(),
  toggleTheme: vi.fn(),
  agentUsage: {} as TaskManager["agentUsage"],
  sendPermissionPromptResponse: vi.fn(),
  draftView: null as TaskManager["draftView"],
  activeTaskId: null as string | null,
  activeWorkspace: null as string | null,
  activeProject: null as string | null,
  tasks: new Map<string, TaskState>(),
  entryPoints: [] as TaskManager["entryPoints"],
  agents: [] as TaskManager["agents"],
  ui: {} as TaskManager["ui"],
  sidebarTasks: [] as TaskManager["sidebarTasks"],
  attention: new Set<number>(),
  setActiveTaskId: vi.fn(),
  navigateToProject: vi.fn(),
  connected: true,
  tasksLoaded: true,
  getByTid: vi.fn(),
  ordinaryDraftStore: null as
    | import("./ordinaryDraftStore").OrdinaryDraftStore
    | null,
}));

const componentProps = vi.hoisted(() => ({
  sidebar: [] as Array<{
    tasksLoading: boolean;
    propNames: string[];
    claudeUsage?: TaskManager["agentUsage"][string];
  }>,
  sessionView: [] as Array<{ tasksLoading: boolean; tid: number | null }>,
  draftSessionView: [] as Array<{ tasksLoading: boolean }>,
  searchPopup: [] as Array<{ tasksLoaded: boolean }>,
  welcomePage: [] as Array<{ tasksLoaded: boolean }>,
}));

const controlledImageStore = vi.hoisted(() => ({
  current: null as ControlledImageStore | null,
}));

vi.hoisted(() => {
  Object.defineProperty(globalThis, "CSS", {
    value: { supports: () => false, escape: (value: string) => value },
    configurable: true,
  });
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener: () => {},
    removeEventListener: () => {},
  }));
});

const liveManager = vi.hoisted(() => ({
  enabled: false,
  manager: null as TaskManager | null,
  receive: null as ((message: ControlMessage) => void) | null,
  route: vi.fn(),
  undoTask: vi.fn(),
}));

vi.mock("./connection", () => ({
  Connection: class {
    onControlMessage?: (message: ControlMessage) => void;
    onStatusChange?: (connected: boolean) => void;

    connect() {
      this.onStatusChange?.(true);
      liveManager.receive = (message) => {
        this.onControlMessage?.(message);
      };
    }

    disconnect() {}
    undoTask = liveManager.undoTask;
    setTaskTitle() {}
  },
}));

vi.mock("./useSessionManager", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./useSessionManager")>();
  return {
    parseTaskId: (id: string | null) => {
      if (id === null) return null;
      const tid = parseInt(id, 10);
      return String(tid) === id ? tid : null;
    },
    useTaskManager: (...args: Parameters<typeof actual.useTaskManager>) => {
      if (liveManager.enabled) {
        liveManager.manager = actual.useTaskManager(...args);
        return liveManager.manager;
      }
      return {
        tasks: state.tasks,
        agentUsage: state.agentUsage,
        ordinaryDraftStore: (state.ordinaryDraftStore ??=
          createOrdinaryDraftStore()),
        activeTaskId: state.activeTaskId,
        getActiveTaskId: () => state.activeTaskId,
        setActiveTaskId: state.setActiveTaskId,
        connected: state.connected,
        tasksLoaded: state.tasksLoaded,
        send: vi.fn(),
        interrupt: vi.fn(),
        stop: vi.fn(),
        closeStdin: vi.fn(),
        resume: vi.fn(),
        promote: vi.fn(),
        fork: vi.fn(),
        undo: vi.fn(),
        undoPreview: vi.fn(),
        unsendMessage: vi.fn(),
        approveRetry: vi.fn(),
        undoConfirm: vi.fn(),
        undoDismiss: vi.fn(),
        dismissAttention: vi.fn(),
        clearInputDraft: vi.fn(),
        setArchived: vi.fn(),
        setTaskTitle: vi.fn(),
        saveDraft: vi.fn(),
        sendAskUserResponse: vi.fn(),
        sendPermissionPromptResponse: state.sendPermissionPromptResponse,
        editMessage: vi.fn(),
        editRawEvent: vi.fn(),
        draftView: state.draftView,
        sidebarTasks: state.sidebarTasks,
        workspaces: [],
        entryPoints: state.entryPoints,
        typeInfo: [],
        agents: state.agents,
        defaultAgent: "",
        defaultTaskType: "",
        activeWorkspace: state.activeWorkspace,
        activeProject: state.activeProject,
        notices: {},
        localNotices: {},
        serverError: state.serverError,
        dismissServerError: state.dismissServerError,
        devMode: false,
        ui: state.ui,
        heicConversion: { available: false, reason: "not configured" },
        getHeicConversion: () => ({
          available: false,
          reason: "not configured",
        }),
        navigateHome: vi.fn(),
        navigateToProject: state.navigateToProject,
        getProjectHref: vi.fn(),
        getTaskHref: vi.fn(),
        getByTid: state.getByTid,
        refreshWorkspaces: vi.fn(),
        scanState: "idle",
      } satisfies TaskManager;
    },
  };
});

vi.mock("./controlledImageStore", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./controlledImageStore")>();
  return {
    ...actual,
    createControlledImageStore: () => {
      const store = actual.createControlledImageStore();
      controlledImageStore.current = store;
      return store;
    },
  };
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({ route: liveManager.route, path: "/" }),
  Router: ({ children }: { children: ComponentChildren }) => {
    const firstRoute = toChildArray(children)[0] as VNode<{
      component: () => VNode;
    }>;
    return h(firstRoute.props.component, {});
  },
  Route: () => null,
}));

vi.mock("./components/Sidebar", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./components/Sidebar")>()),
  Sidebar: (
    props: Parameters<typeof import("./components/Sidebar").Sidebar>[0],
  ) => {
    componentProps.sidebar.push({
      tasksLoading: props.tasksLoading,
      propNames: Object.keys(props),
      claudeUsage: props.claudeUsage,
    });
    return null;
  },
}));

vi.mock("./components/SessionView", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./components/SessionView")>();
  return {
    ...actual,
    SessionView: (props: Parameters<typeof actual.SessionView>[0]) => {
      componentProps.sessionView.push({
        tasksLoading: props.tasksLoading,
        tid: props.task.tid,
      });
      return h(actual.SessionView, props);
    },
    DraftSessionView: (
      props: Parameters<typeof actual.DraftSessionView>[0],
    ) => {
      componentProps.draftSessionView.push({
        tasksLoading: props.tasksLoading,
      });
      return h(actual.DraftSessionView, props);
    },
  };
});

vi.mock("./components/SearchPopup", () => ({
  SearchPopup: (props: { tasksLoaded: boolean }) => {
    componentProps.searchPopup.push({ tasksLoaded: props.tasksLoaded });
    return null;
  },
}));

vi.mock("./components/WelcomePage", () => ({
  WelcomePage: (props: { tasksLoaded: boolean }) => {
    componentProps.welcomePage.push({ tasksLoaded: props.tasksLoaded });
    return null;
  },
}));

vi.mock("./useTheme", () => ({
  ThemeContext: {
    Provider: ({ children }: { children: ComponentChildren }) => children,
  },
  useTheme: () => ({ theme: "dark", toggleTheme: state.toggleTheme }),
}));

vi.mock("./useToast", () => ({
  useToast: () => ({
    toasts: [],
    addToast: vi.fn(),
    dismissToast: vi.fn(),
    clearToasts: vi.fn(),
  }),
}));

vi.mock("./useNotifications", () => ({
  useNotifications: () => state.attention,
  requestNotificationPermissionFromGesture: vi.fn(),
}));

vi.mock("./useErrorOverlay", () => ({
  useErrorCapture: () => {},
}));

import { App } from "./app";

beforeEach(() => {
  liveManager.enabled = false;
  liveManager.manager = null;
  liveManager.receive = null;
  liveManager.undoTask.mockClear();
  state.serverError = null;
  state.dismissServerError.mockReset();
  state.draftView = null;
  state.toggleTheme.mockClear();
  state.agentUsage = {};
  state.activeTaskId = null;
  state.activeWorkspace = null;
  state.activeProject = null;
  state.tasks = new Map();
  state.entryPoints = [];
  state.agents = [];
  state.connected = true;
  state.tasksLoaded = true;
  state.ui = {};
  state.sidebarTasks = [];
  state.attention = new Set();
  state.setActiveTaskId.mockClear();
  state.navigateToProject.mockClear();
  state.sendPermissionPromptResponse.mockClear();
  state.getByTid.mockReset();
  state.getByTid.mockImplementation((tid: number) =>
    Array.from(state.tasks.values()).find((task) => task.tid === tid),
  );
  controlledImageStore.current = null;
  componentProps.sidebar.length = 0;
  componentProps.sessionView.length = 0;
  componentProps.draftSessionView.length = 0;
  componentProps.searchPopup.length = 0;
  componentProps.welcomePage.length = 0;
  state.ordinaryDraftStore?.clear();
});

function latest<T>(calls: T[]): T {
  const call = calls.at(-1);
  if (call === undefined) throw new Error("Expected the component to render");
  return call;
}

function makeDraftView(): DraftViewSnapshot {
  return {
    kind: "resolved",
    editorId: "composition:test" as const,
    viewKey: "composition:test",
    workspace: "workspace",
    projectName: "project",
    projectPath: "/project",
    remoteTid: null,
    text: "",
    entryPoint: "",
    agent: "",
    lifecycle: "idle",
    disabled: false,
    metadataReady: true,
    submitReady: true,
    composerResetToken: 0,
    onTextChange: vi.fn(),
    onEntryPointChange: vi.fn(),
    onAgentChange: vi.fn(),
    onSubmit: vi.fn(),
  };
}

function expectPlaceholderFrame(
  html: string,
  connection: "connected" | "loading" | "disconnected" = "connected",
): void {
  const root = document.createElement("div");
  root.innerHTML = html;
  const bars = root.querySelectorAll(".task-bar");
  expect(bars).toHaveLength(1);
  expect(bars[0]?.getAttribute("data-connection")).toBe(connection);
  expect(bars[0]?.querySelector(".task-bar-agent")).toBeNull();
  expect(bars[0]?.querySelector(".task-bar-title")?.textContent ?? "").toBe(
    { connected: "", loading: "Loading…", disconnected: "Disconnected" }[
      connection
    ],
  );
  expect(bars[0]?.lastElementChild?.matches(".theme-toggle")).toBe(true);
  expect(root.querySelectorAll(".session-empty")).toHaveLength(
    connection === "disconnected" ? 0 : 1,
  );
}

describe("permission prompt responses", () => {
  const roots = ownedRoots();
  const tid = 42;
  const toolUseId = "toolu_visible";

  async function renderPrompt() {
    const task = {
      ...makeTaskState(tid, true, false, "Permission task", true),
      status: "active" as const,
      pendingPermission: {
        toolUseId,
        toolName: "Bash",
        input: { command: "echo example" },
      },
    };
    state.tasks.set(task.uuid, task);
    state.activeTaskId = String(tid);

    const container = roots.create();
    await act(() => {
      render(h(App, {}), container);
    });
    return container;
  }

  it.each([false, true])(
    "keeps a submitted permission prompt only when its tool block exists (%s)",
    (hasBlock) => {
      const task = {
        ...makeTaskState(tid, true, false, "Permission task", true),
        status: "active" as const,
        submittedPermission: {
          toolUseId,
          toolName: hasBlock ? "Bash" : "UnsandboxedCommand",
          input: { command: "echo example" },
        },
      };
      if (hasBlock) {
        task.blocks.set(toolUseId, {
          itemId: toolUseId,
          type: "tool_use",
          name: "Bash",
          text: "",
          completed: false,
          creationOrder: 0,
          permission: "answered",
        });
      }
      state.tasks.set(task.uuid, task);
      state.activeTaskId = String(tid);

      const html = renderToString(h(App, {}));
      expect(html.includes("permission-prompt-sending")).toBe(hasBlock);
      expect(html.includes("permission-prompt-form")).toBe(hasBlock);
    },
  );

  it("allows the tool call identified by the shown prompt", async () => {
    const container = await renderPrompt();
    await act(() => {
      container
        .querySelector<HTMLButtonElement>(".permission-allow-btn")!
        .click();
    });

    expect(state.sendPermissionPromptResponse).toHaveBeenCalledExactlyOnceWith(
      tid,
      toolUseId,
      JSON.stringify({ behavior: "allow" }),
    );
  });

  it("denies the tool call identified by the shown prompt", async () => {
    const container = await renderPrompt();
    const denyButton = () =>
      container.querySelector<HTMLButtonElement>(".permission-deny-btn")!;
    await act(() => {
      denyButton().click();
    });
    await act(() => {
      denyButton().click();
    });

    expect(state.sendPermissionPromptResponse).toHaveBeenCalledExactlyOnceWith(
      tid,
      toolUseId,
      JSON.stringify({ behavior: "deny" }),
    );
  });
});

describe("server command errors", () => {
  const roots = ownedRoots();

  it("renders the server error dialog and dismisses it", () => {
    state.serverError = { message: "Undo target is no longer valid", tid: 7 };

    let dismiss: (() => void) | undefined;
    const previousVNode = options.vnode?.bind(options);
    options.vnode = (vnode: VNode) => {
      previousVNode?.(vnode);
      if (vnode.type === "button" && vnode.props.children === "Dismiss") {
        dismiss = (vnode.props as unknown as { onClick: () => void }).onClick;
      }
    };
    try {
      const html = renderToString(h(App, {}));
      expect(html).toContain("Command failed");
      expect(html).toContain("Undo target is no longer valid");
      expect(dismiss).toBe(state.dismissServerError);

      dismiss?.();
      expect(state.dismissServerError).toHaveBeenCalledOnce();
    } finally {
      options.vnode = previousVNode;
    }
  });

  async function renderTaskWithCommandErrors() {
    liveManager.enabled = true;
    const root = roots.create();
    await act(() => {
      render(h(App, {}), root);
    });

    const tid = 7;
    const receive = liveManager.receive!;
    const currentTask = () => liveManager.manager!.getByTid(tid);
    await actStep(() => {
      receive({
        type: "tasks_list",
        complete: true,
        tasks: [
          {
            tid,
            alive: false,
            resumable: false,
            isProcessing: false,
            child_count: 0,
          },
        ],
      });
    });
    await actPoll({
      description: "task snapshot received",
      ready: () => currentTask() !== undefined,
    });
    return { root, tid, receive, currentTask };
  }

  function latestUndoRequestId(): string {
    const requestId: unknown = liveManager.undoTask.mock.lastCall?.[6];
    expect(requestId).toEqual(expect.any(String));
    return requestId as string;
  }

  it("shows a rejected title edit without clearing a pending undo preview", async () => {
    const { root, tid, receive, currentTask } =
      await renderTaskWithCommandErrors();
    await act(() => {
      liveManager.manager!.undoPreview(tid, "before:message");
      liveManager.manager!.setTaskTitle(tid, "");
    });
    expect(currentTask()!.undoPending).toMatchObject({
      kind: "requesting",
      anchor: "before:message",
    });

    const reason = "Title cannot be empty after a task has started";
    await actStep(() => {
      receive({ type: "error", message: reason, tid });
    });
    await actPoll({
      description: "title error dialog rendered",
      ready: () => root.querySelector(".command-error-dialog") !== null,
    });
    const dialog = root.querySelector(".command-error-dialog")!;
    expect(dialog.textContent).toContain(reason);
    expect(currentTask()!.undoPending).toMatchObject({
      kind: "requesting",
      anchor: "before:message",
    });
    await actStep(() => {
      receive({
        type: "undo_preview",
        tid,
        correlation_id: latestUndoRequestId(),
        messages_removed: 2,
        count_unit: "history_entries",
        can_revert_files: false,
      });
    });
    await actPoll({
      description: "undo preview arrived with its anchor",
      ready: () => currentTask()?.undoPending?.kind === "history_entries",
    });
    expect(currentTask()!.undoPending?.anchor).toBe("before:message");
  });

  it("clears a failed current preview and shows the command error", async () => {
    const { root, tid, receive, currentTask } =
      await renderTaskWithCommandErrors();
    await act(() => {
      liveManager.manager!.undoPreview(tid, "before:message");
    });
    expect(currentTask()?.undoPending?.kind).toBe("requesting");

    const reason = "Undo preview refused";
    await actStep(() => {
      receive({
        type: "error",
        message: reason,
        tid,
        operation: "undo_preview",
        correlation_id: latestUndoRequestId(),
      });
    });

    await actPoll({
      description: "undo preview error dialog rendered",
      ready: () => root.querySelector(".command-error-dialog") !== null,
    });
    expect(currentTask()?.undoPending).toBeNull();
    expect(root.querySelector(".command-error-dialog")?.textContent).toContain(
      reason,
    );
  });

  it.each(["replaced", "dismissed"] as const)(
    "ignores a late failure for a %s preview",
    async (scenario) => {
      const { root, tid, receive, currentTask } =
        await renderTaskWithCommandErrors();
      await act(() => {
        liveManager.manager!.undoPreview(tid, "before:first");
      });
      const firstId = latestUndoRequestId();

      await act(() => {
        if (scenario === "replaced") {
          liveManager.manager!.undoPreview(tid, "before:second");
        } else {
          liveManager.manager!.undoDismiss(tid);
        }
      });
      const pending = currentTask()?.undoPending;
      if (scenario === "replaced") {
        expect(pending).toMatchObject({
          kind: "requesting",
          anchor: "before:second",
          requestId: latestUndoRequestId(),
        });
      } else {
        expect(pending).toBeNull();
      }

      await actStep(() => {
        receive({
          type: "error",
          message: "The first preview failed",
          tid,
          operation: "undo_preview",
          correlation_id: firstId,
        });
        // Wait for a message behind the error in the same connection queue.
        receive({
          type: "agent_usage",
          profile: "/profiles/undo-test",
          updated_at: 1,
          limits: { five_hour: { utilization: 42 } },
        });
      });

      await actPoll({
        description:
          "the connection processed the batch containing the late error",
        ready: () =>
          liveManager.manager!.agentUsage["/profiles/undo-test"] !== undefined,
      });

      expect(currentTask()?.undoPending).toEqual(pending);
      expect(root.querySelector(".command-error-dialog")).toBeNull();
    },
  );

  it("hides the dialog after its error state is cleared", () => {
    state.serverError = { message: "Undo failed" };
    expect(renderToString(h(App, {}))).toContain("Command failed");

    state.serverError = null;
    expect(renderToString(h(App, {}))).not.toContain("Command failed");
  });

  it("renders an attached project draft view before its pending task pane", () => {
    const pending = {
      ...makeTaskState(
        71,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "pending-draft",
      status: "pending" as const,
      serverDraft: "controlled draft",
      entryPoint: "entry",
      agentName: "agent",
    };
    state.tasks = new Map([[pending.uuid, pending]]);
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    state.draftView = {
      kind: "resolved",
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: 71,
      text: "controlled draft",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "present",
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    const html = renderToString(h(App, {}));

    expect(html).toContain(">controlled draft</textarea>");
    expect(html).not.toContain("Loading task");
    expect(html.match(/input-textarea/g) ?? []).toHaveLength(1);
  });

  it("keeps the numeric-route draft editable with Submit disabled by the catalog", async () => {
    const pending = {
      ...makeTaskState(
        95,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "pending-draft",
      status: "pending" as const,
      serverDraft: "controlled draft",
      entryPoint: "entry",
      agentName: "agent",
    };
    state.tasks = new Map([[pending.uuid, pending]]);
    state.activeTaskId = "95";
    state.entryPoints = [
      {
        name: "listed",
        task_type: "blank",
        description: "",
        model_class: "",
        read_only: false,
      },
    ];
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    state.draftView = {
      kind: "resolved",
      editorId: "task:95" as const,
      viewKey: "task:95",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: 95,
      text: "controlled draft",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "present",
      disabled: false,
      metadataReady: true,
      submitReady: false,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    const container = roots.create();
    await act(() => {
      render(h(App, {}), container);
    });
    const inputs =
      container.querySelectorAll<HTMLTextAreaElement>(".input-textarea");
    expect(inputs).toHaveLength(1);
    expect(inputs[0]?.value).toBe("controlled draft");
    expect(inputs[0]?.disabled).toBe(false);
    expect(
      container.querySelector<HTMLButtonElement>(".btn-send")?.disabled,
    ).toBe(true);
    expect(container.querySelector(".task-type-row.selected")).toBeNull();
    expect(container.textContent).not.toContain("Loading task");
  });

  it("does not hydrate an ordinary composer from a submitted controlled peer update", async () => {
    const controlledSubmit = vi.fn();
    const controlledTask = {
      ...makeTaskState(
        71,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "controlled-task",
      status: "pending" as const,
      serverDraft: "peer B",
      entryPoint: "entry",
      agentName: "agent",
    };
    state.tasks = new Map([[controlledTask.uuid, controlledTask]]);
    state.activeTaskId = "71";
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    state.draftView = {
      kind: "resolved",
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: 71,
      text: "peer B",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "present",
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: controlledSubmit,
    } satisfies DraftViewSnapshot;
    const container = roots.create();

    await act(() => {
      render(h(App, {}), container);
    });
    expect(
      container.querySelector<HTMLTextAreaElement>("textarea")?.value,
    ).toBe("peer B");
    await act(() => {
      container.querySelector<HTMLButtonElement>(".btn-send")!.click();
    });
    expect(controlledSubmit).toHaveBeenCalledWith("peer B", []);

    const ordinaryTask = {
      ...makeTaskState(
        71,
        true,
        false,
        undefined,
        true,
        "workspace",
        "/project",
        undefined,
        undefined,
        "active",
      ),
      uuid: "ordinary-task",
    };
    state.tasks = new Map([[ordinaryTask.uuid, ordinaryTask]]);
    state.draftView = null;
    await act(() => {
      render(h(App, {}), container);
    });
    expect(
      container.querySelector<HTMLTextAreaElement>("textarea")?.value,
    ).toBe("");

    await act(() => {
      render(null, container);
      render(h(App, {}), container);
    });
    expect(
      container.querySelector<HTMLTextAreaElement>("textarea")?.value,
    ).toBe("");
  });

  it("shows numeric loading while a known pending task is not renderable", () => {
    const pending = {
      ...makeTaskState(
        72,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "deferred-pending-draft",
      status: "pending" as const,
      serverDraft: "persisted draft",
      entryPoint: "entry",
      agentName: "agent",
    };
    state.tasks = new Map([[pending.uuid, pending]]);
    state.activeTaskId = "72";
    state.activeWorkspace = "workspace";
    state.activeProject = "project";

    const html = renderToString(h(App, {}));

    expect(html).toContain("Loading task…");
    expect(html).not.toContain("input-textarea");
  });

  it("keeps the same controlled editor mounted through numeric promotion", async () => {
    const readers: FileReader[] = [];
    const readAsDataURL = vi
      .spyOn(FileReader.prototype, "readAsDataURL")
      .mockImplementation(function (this: FileReader) {
        readers.push(this);
      });
    const completeNextReader = () => {
      const reader = readers.shift();
      reader?.onload?.({
        target: { result: "data:image/png;base64,aW1hZ2U=" },
      } as ProgressEvent<FileReader>);
    };
    const pasteImage = (textarea: HTMLTextAreaElement) => {
      const file = new File(["image"], "image.png", { type: "image/png" });
      const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
      Object.defineProperty(event, "clipboardData", {
        value: {
          items: [
            {
              kind: "file",
              type: "image/png",
              getAsFile: () => file,
            },
          ],
        },
        enumerable: true,
      });
      textarea.dispatchEvent(event);
    };
    const rootDraft = {
      kind: "resolved",
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: null,
      text: "draft A",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating",
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 11,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.draftView = rootDraft;
      const container = roots.create();
      await act(() => {
        render(h(App, {}), container);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await act(() => {
        completeNextReader();
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      await act(() => {
        pasteImage(beforeTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });

      const pending = {
        ...makeTaskState(
          71,
          false,
          false,
          undefined,
          false,
          "workspace",
          "/project",
        ),
        uuid: "pending-draft",
        status: "pending" as const,
        serverDraft: "draft A",
        entryPoint: "entry",
        agentName: "agent",
      };
      state.tasks = new Map([[pending.uuid, pending]]);
      state.activeTaskId = "71";
      state.draftView = {
        ...rootDraft,
        remoteTid: 71,
        lifecycle: "present",
      };
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelector(".input-box")).toBe(beforeInputBox);
      expect(container.querySelector("textarea")).toBe(beforeTextarea);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(container.querySelector(".session-empty")).toBeNull();
      expect(container.textContent).not.toContain("Loading task…");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      await act(() => {
        completeNextReader();
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      });

      state.activeTaskId = null;
      state.draftView = {
        ...rootDraft,
        editorId: "composition:successor",
        viewKey: "composition:successor",
        lifecycle: "idle",
        text: "",
      };
      await act(() => {
        render(h(App, {}), container);
      });
      expect(container.querySelector("textarea")).not.toBe(beforeTextarea);
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.value,
      ).toBe("");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      readAsDataURL.mockRestore();
    }
  });

  it("keeps the project composer editable through temporary metadata loss", async () => {
    const readers: FileReader[] = [];
    const readAsDataURL = vi
      .spyOn(FileReader.prototype, "readAsDataURL")
      .mockImplementation(function (this: FileReader) {
        readers.push(this);
      });
    const completeNextReader = () => {
      const reader = readers.shift();
      reader?.onload?.({
        target: { result: "data:image/png;base64,aW1hZ2U=" },
      } as ProgressEvent<FileReader>);
    };
    const pasteImage = (textarea: HTMLTextAreaElement) => {
      const file = new File(["image"], "image.png", { type: "image/png" });
      const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
      Object.defineProperty(event, "clipboardData", {
        value: {
          items: [
            {
              kind: "file",
              type: "image/png",
              getAsFile: () => file,
            },
          ],
        },
        enumerable: true,
      });
      textarea.dispatchEvent(event);
    };
    const projectDraft = {
      kind: "resolved" as const,
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: null,
      text: "retain B",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating" as const,
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 15,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.entryPoints = [
        {
          name: "entry",
          task_type: "entry",
          description: "Project entry",
          model_class: "general",
          read_only: false,
        },
      ];
      state.agents = [{ name: "agent", driver: "claude" }];
      state.draftView = projectDraft;
      const container = roots.create();
      await act(() => {
        render(h(App, {}), container);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await act(() => {
        completeNextReader();
        pasteImage(beforeTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });

      state.draftView = {
        ...projectDraft,
        metadataReady: false,
        submitReady: false,
      };
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelector(".input-box")).toBe(beforeInputBox);
      expect(container.querySelector("textarea")).toBe(beforeTextarea);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(beforeTextarea.disabled).toBe(false);
      expect(
        container.querySelector<HTMLButtonElement>(".btn-send")?.disabled,
      ).toBe(true);
      expect(
        container.querySelector<HTMLSelectElement>(".agent-picker")?.disabled,
      ).toBe(true);
      expect(container.querySelector(".session-empty")).toBeNull();
      expect(container.textContent).not.toContain("Loading task…");
      expect(
        container.querySelector(".task-type-row.selected .task-type-name")
          ?.textContent,
      ).toBe("entry");
      expect(
        container.querySelector<HTMLSelectElement>(".agent-picker")?.value,
      ).toBe("agent");
      await act(() => {
        completeNextReader();
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      });

      state.draftView = projectDraft;
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelector(".input-box")).toBe(beforeInputBox);
      expect(container.querySelector("textarea")).toBe(beforeTextarea);
      expect(beforeTextarea.disabled).toBe(false);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
    } finally {
      readAsDataURL.mockRestore();
    }
  });

  it("detaches a cached draft for unrelated metadata-gap routes", async () => {
    const readers: FileReader[] = [];
    const readAsDataURL = vi
      .spyOn(FileReader.prototype, "readAsDataURL")
      .mockImplementation(function (this: FileReader) {
        readers.push(this);
      });
    const completeNextReader = () => {
      const reader = readers.shift();
      reader?.onload?.({
        target: { result: "data:image/png;base64,aW1hZ2U=" },
      } as ProgressEvent<FileReader>);
    };
    const pasteImage = (textarea: HTMLTextAreaElement) => {
      const file = new File(["image"], "image.png", { type: "image/png" });
      const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
      Object.defineProperty(event, "clipboardData", {
        value: {
          items: [
            {
              kind: "file",
              type: "image/png",
              getAsFile: () => file,
            },
          ],
        },
        enumerable: true,
      });
      textarea.dispatchEvent(event);
    };
    const cachedDraft = {
      kind: "resolved" as const,
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: null,
      text: "retain A across metadata-gap navigation",
      entryPoint: "entry A",
      agent: "agent A",
      lifecycle: "creating" as const,
      disabled: false,
      metadataReady: false,
      submitReady: false,
      composerResetToken: 19,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;
    const realTaskB = {
      ...makeTaskState(
        72,
        true,
        false,
        undefined,
        true,
        "workspace",
        "/project",
        undefined,
        undefined,
        "active",
      ),
      uuid: "real-task-b",
    };
    const pendingTaskB = {
      ...makeTaskState(
        72,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "pending-task-b",
      status: "pending" as const,
      serverDraft: "unowned pending B",
      entryPoint: "entry B",
      agentName: "agent B",
    };

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.entryPoints = [
        {
          name: "entry A",
          task_type: "entry-a",
          description: "A entry point",
          model_class: "general",
          read_only: false,
        },
      ];
      state.agents = [{ name: "agent A", driver: "claude" }];
      state.draftView = cachedDraft;
      const container = roots.create();
      await act(() => {
        render(h(App, {}), container);
      });

      const rootTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(rootTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await act(() => {
        completeNextReader();
        pasteImage(rootTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });

      state.activeTaskId = "72";
      state.tasks = new Map([[realTaskB.uuid, realTaskB]]);
      state.draftView = null;
      await act(() => {
        render(h(App, {}), container);
        completeNextReader();
      });

      expect(container.querySelectorAll(".input-box")).toHaveLength(1);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(container.textContent).not.toContain(
        "retain A across metadata-gap navigation",
      );
      expect(container.querySelector(".session-empty")).toBeNull();

      state.tasks = new Map([[pendingTaskB.uuid, pendingTaskB]]);
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelectorAll(".input-box")).toHaveLength(0);
      expect(container.querySelectorAll("textarea")).toHaveLength(0);
      expect(container.querySelector(".session-empty")?.textContent).toContain(
        "Loading task…",
      );

      state.activeTaskId = null;
      state.draftView = cachedDraft;
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.value,
      ).toBe("retain A across metadata-gap navigation");
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      });
      expect(
        container.querySelector(".task-type-row.selected .task-type-name")
          ?.textContent,
      ).toBe("entry A");
      expect(
        container.querySelector<HTMLSelectElement>(".agent-picker")?.value,
      ).toBe("agent A");
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.disabled,
      ).toBe(false);
      expect(
        container.querySelector<HTMLButtonElement>(".btn-send")?.disabled,
      ).toBe(true);

      state.draftView = {
        ...cachedDraft,
        disabled: false,
        metadataReady: true,
        submitReady: true,
      };
      await act(() => {
        render(h(App, {}), container);
      });

      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.disabled,
      ).toBe(false);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
    } finally {
      readAsDataURL.mockRestore();
    }
  });

  it("eagerly clears controlled images on connection reset", async () => {
    const readers: FileReader[] = [];
    const readAsDataURL = vi
      .spyOn(FileReader.prototype, "readAsDataURL")
      .mockImplementation(function (this: FileReader) {
        readers.push(this);
      });
    const complete = (reader: FileReader) => {
      reader.onload?.({
        target: { result: "data:image/png;base64,aW1hZ2U=" },
      } as ProgressEvent<FileReader>);
    };
    const pasteImage = (textarea: HTMLTextAreaElement) => {
      const file = new File(["image"], "image.png", { type: "image/png" });
      const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
      Object.defineProperty(event, "clipboardData", {
        value: {
          items: [
            {
              kind: "file",
              type: "image/png",
              getAsFile: () => file,
            },
          ],
        },
        enumerable: true,
      });
      textarea.dispatchEvent(event);
    };
    const submitA = vi.fn();
    const draftA = {
      kind: "resolved" as const,
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project-a",
      projectPath: "/project-a",
      remoteTid: null,
      text: "draft A",
      entryPoint: "entry",
      agent: "agent",
      lifecycle: "creating" as const,
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: submitA,
    } satisfies DraftViewSnapshot;
    const draftB = {
      ...draftA,
      editorId: "composition:test-b" as const,
      viewKey: "composition:test-b",
      projectName: "project-b",
      projectPath: "/project-b",
      text: "draft B",
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    const container = roots.create();
    const renderApp = async () => {
      await act(() => {
        render(h(App, {}), container);
      });
    };

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project-a";
      state.entryPoints = [
        {
          name: "entry",
          task_type: "entry",
          description: "Project entry",
          model_class: "general",
          read_only: false,
        },
      ];
      state.agents = [{ name: "agent", driver: "claude" }];
      state.draftView = draftA;
      await renderApp();

      const imageStore = controlledImageStore.current!;
      expect(imageStore.entries.size).toBe(1);
      const aEntry = imageStore.entries.get(draftA.editorId)!;

      const aTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(aTextarea);
      });
      await waitFor(() => {
        expect(readers).toHaveLength(1);
      });
      await act(() => {
        complete(readers[0]!);
        pasteImage(aTextarea);
      });
      await waitFor(() => {
        expect(readers).toHaveLength(2);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      const heldAcrossHome = readers[1]!;
      expect(aEntry.images).toHaveLength(1);

      state.activeProject = null;
      state.draftView = null;
      await renderApp();
      expect(imageStore.entries.get(draftA.editorId)).toBe(aEntry);
      expect(aEntry.images).toHaveLength(1);

      state.activeProject = "project-a";
      state.draftView = draftA;
      await act(() => {
        render(h(App, {}), container);
        complete(heldAcrossHome);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      });
      expect(aEntry.images).toHaveLength(2);

      await act(() => {
        const current =
          container.querySelector<HTMLTextAreaElement>("textarea")!;
        pasteImage(current);
      });
      await waitFor(() => {
        expect(readers).toHaveLength(3);
      });
      const heldAcrossReset = readers[2]!;

      state.activeProject = "project-b";
      state.draftView = draftB;
      await renderApp();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(imageStore.entries.get(draftA.editorId)).toBe(aEntry);
      expect(aEntry.images).toHaveLength(2);

      const bTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(bTextarea);
      });
      await waitFor(() => {
        expect(readers).toHaveLength(4);
      });
      await act(() => {
        complete(readers[3]!);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      const bEntry = imageStore.entries.get(draftB.editorId)!;
      expect(imageStore.entries.size).toBe(2);
      expect(bEntry.images).toHaveLength(1);

      state.draftView = {
        ...draftB,
        disabled: true,
        composerResetToken: 1,
      };
      state.connected = false;
      await renderApp();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(imageStore.entries.size).toBe(0);
      expect(aEntry.images).toEqual([]);
      expect(bEntry.images).toEqual([]);

      const aResetGeneration = aEntry.generation;
      const bResetGeneration = bEntry.generation;
      await renderApp();
      expect(imageStore.entries.size).toBe(0);
      expect(aEntry.generation).toBe(aResetGeneration);
      expect(bEntry.generation).toBe(bResetGeneration);

      // No completion signal is exposed for the reset editor's stale read.
      await actStep(() => {
        complete(heldAcrossReset);
      });
      expect(imageStore.entries.size).toBe(0);
      expect(aEntry.images).toEqual([]);

      const freshSubmit = vi.fn();
      const freshDraft = {
        ...draftA,
        editorId: "composition:after-reset",
        viewKey: "composition:after-reset",
        text: "fresh A",
        composerResetToken: 1,
        onSubmit: freshSubmit,
      } satisfies DraftViewSnapshot;
      state.connected = true;
      state.activeProject = "project-a";
      state.draftView = freshDraft;
      await renderApp();
      const freshEntry = imageStore.entries.get(freshDraft.editorId)!;
      expect(freshEntry).not.toBe(aEntry);
      expect(freshEntry.resetToken).toBe(1);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      await act(() => {
        container.querySelector<HTMLButtonElement>(".btn-send")!.click();
      });
      expect(freshSubmit).toHaveBeenCalledWith("fresh A", []);

      await act(() => {
        const current =
          container.querySelector<HTMLTextAreaElement>("textarea")!;
        pasteImage(current);
      });
      await waitFor(() => {
        expect(readers).toHaveLength(5);
      });
      await act(() => {
        complete(readers[4]!);
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });

      state.draftView = {
        ...state.draftView,
        disabled: true,
        composerResetToken: 2,
      };
      state.connected = false;
      await renderApp();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(imageStore.entries.size).toBe(0);

      const freshResetGeneration = freshEntry.generation;
      await renderApp();
      expect(imageStore.entries.size).toBe(0);
      expect(freshEntry.generation).toBe(freshResetGeneration);
    } finally {
      readAsDataURL.mockRestore();
    }
  });

  it("keeps attachments scoped to each persisted numeric editor", async () => {
    const readers: FileReader[] = [];
    const readAsDataURL = vi
      .spyOn(FileReader.prototype, "readAsDataURL")
      .mockImplementation(function (this: FileReader) {
        readers.push(this);
      });
    const completeNextReader = () => {
      const reader = readers.shift();
      reader?.onload?.({
        target: { result: "data:image/png;base64,aW1hZ2U=" },
      } as ProgressEvent<FileReader>);
    };
    const pasteImage = (textarea: HTMLTextAreaElement) => {
      const file = new File(["image"], "image.png", { type: "image/png" });
      const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
      Object.defineProperty(event, "clipboardData", {
        value: {
          items: [
            {
              kind: "file",
              type: "image/png",
              getAsFile: () => file,
            },
          ],
        },
        enumerable: true,
      });
      textarea.dispatchEvent(event);
    };
    const persistedA = {
      ...makeTaskState(
        71,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "persisted-a",
      status: "pending" as const,
      serverDraft: "persisted draft A",
      entryPoint: "entry A",
      agentName: "agent A",
    };
    const persistedB = {
      ...makeTaskState(
        72,
        false,
        false,
        undefined,
        false,
        "workspace",
        "/project",
      ),
      uuid: "persisted-b",
      status: "pending" as const,
      serverDraft: "persisted draft B",
      entryPoint: "entry B",
      agentName: "agent B",
    };
    const projectDraft = {
      kind: "resolved" as const,
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      lifecycle: "present" as const,
      disabled: false,
      metadataReady: true,
      submitReady: true,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    };
    const draftA = {
      ...projectDraft,
      editorId: "task:71",
      viewKey: "task:71",
      remoteTid: 71,
      text: "persisted draft A",
      entryPoint: "entry A",
      agent: "agent A",
      composerResetToken: 11,
    } satisfies DraftViewSnapshot;
    const draftB = {
      ...projectDraft,
      editorId: "task:72",
      viewKey: "task:72",
      remoteTid: 72,
      text: "persisted draft B",
      entryPoint: "entry B",
      agent: "agent B",
      composerResetToken: 12,
    } satisfies DraftViewSnapshot;

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.activeTaskId = "71";
      state.tasks = new Map([
        [persistedA.uuid, persistedA],
        [persistedB.uuid, persistedB],
      ]);
      state.entryPoints = [
        {
          name: "entry A",
          task_type: "entry-a",
          description: "A entry point",
          model_class: "general",
          read_only: false,
        },
        {
          name: "entry B",
          task_type: "entry-b",
          description: "B entry point",
          model_class: "general",
          read_only: false,
        },
      ];
      state.agents = [
        { name: "agent A", driver: "claude" },
        { name: "agent B", driver: "codex" },
      ];
      state.draftView = draftA;
      const container = roots.create();
      await act(() => {
        render(h(App, {}), container);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
      });
      await waitFor(() => {
        expect(readers.length).toBeGreaterThan(0);
      });
      await act(() => {
        completeNextReader();
      });
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });

      state.activeTaskId = "72";
      state.draftView = draftB;
      await act(() => {
        render(h(App, {}), container);
      });

      expect(container.querySelector(".input-box")).not.toBe(beforeInputBox);
      expect(container.querySelector("textarea")).not.toBe(beforeTextarea);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.value,
      ).toBe("persisted draft B");
      expect(
        container.querySelector(".task-type-row.selected .task-type-name")
          ?.textContent,
      ).toBe("entry B");
      expect(
        container.querySelector<HTMLSelectElement>(".agent-picker")?.value,
      ).toBe("agent B");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      state.activeTaskId = "71";
      state.draftView = draftA;
      await act(() => {
        render(h(App, {}), container);
      });
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.value,
      ).toBe("persisted draft A");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
    } finally {
      readAsDataURL.mockRestore();
    }
  });
});

describe("missing numeric tasks", () => {
  const tid = 123;

  it("renders the archive placeholder with the shared system banner", () => {
    state.activeTaskId = "archive-123";

    const html = renderToString(h(App, {}));

    expectPlaceholderFrame(html);
    expect(html).toContain("Archived tasks");
    expect(html).not.toContain("Loading task…");
  });

  it("shows a not-found message once the tasks list has loaded", () => {
    state.activeTaskId = String(tid);

    const html = renderToString(h(App, {}));

    expectPlaceholderFrame(html);
    expect(html).toContain(`Task ${tid} not found`);
    expect(html).not.toContain("Loading task…");
  });

  it("keeps loading while the tasks list has not loaded yet, even if connected", () => {
    state.activeTaskId = String(tid);
    state.connected = true;
    state.tasksLoaded = false;

    const html = renderToString(h(App, {}));

    expectPlaceholderFrame(html, "loading");
    expect(html).toContain("Loading task…");
    expect(html).not.toContain(`Task ${tid} not found`);
  });

  it.each([String(tid), "archive-123", "import", null])(
    "renders only the disconnected bar in the main area for route %s",
    (activeTaskId) => {
      state.activeTaskId = activeTaskId;
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.draftView = activeTaskId === null ? makeDraftView() : null;
      state.connected = false;
      state.tasksLoaded = false;

      const html = renderToString(h(App, {}));

      expectPlaceholderFrame(html, "disconnected");
      expect(html).not.toMatch(
        /Loading task…|Archived tasks|Importable sessions/,
      );
      expect(componentProps.draftSessionView).toHaveLength(0);
      expect(componentProps.sessionView).toHaveLength(0);
    },
  );

  it("shows a not-found message for a malformed task id", () => {
    const task = makeTaskState(tid, false, false, "Known task 123");
    state.tasks.set(task.uuid, task);
    state.activeTaskId = "123junk";

    const html = renderToString(h(App, {}));

    expect(html).toContain("Task 123junk not found");
    expect(html).not.toContain("Loading task…");
    expect(html).not.toContain("Known task 123");
    expect(state.getByTid).not.toHaveBeenCalled();
  });
});

it.each(["/profiles/work", undefined])(
  "passes only the selected task's profile usage to the sidebar (%s)",
  (usageProfile) => {
    const usage = (profile: string, utilization: number) => ({
      type: "agent_usage" as const,
      profile,
      updated_at: 1,
      limits: { five_hour: { utilization } },
    });
    const workUsage = usage("/profiles/work", 42);
    state.agentUsage = {
      claude: usage("claude", 71),
      "/profiles/work": workUsage,
    };
    const active = { ...makeTaskState(41), usageProfile };
    state.activeTaskId = "41";
    state.tasks = new Map([[active.uuid, active]]);

    renderToString(h(App, {}));

    expect(latest(componentProps.sidebar).claudeUsage).toEqual(
      usageProfile ? workUsage : undefined,
    );
  },
);

describe("sidebar keyboard navigation", () => {
  const roots = ownedRoots();

  it.each([
    ["oldest_first", "ArrowDown", "1"],
    ["oldest_first", "ArrowUp", "5"],
    ["newest_first", "ArrowDown", "5"],
    ["newest_first", "ArrowUp", "2"],
  ] as const)(
    "jumps from New Task to attention in %s order with %s",
    async (order, key, next) => {
      state.ui = { sidebar: { order } };
      state.activeTaskId = null;
      state.attention = new Set(order === "oldest_first" ? [1, 5] : [5, 2]);
      roots.render(h(App, {}), roots.create());

      await act(() => {
        document.dispatchEvent(
          new KeyboardEvent("keydown", { key, altKey: true, shiftKey: true }),
        );
      });

      expect(state.setActiveTaskId).toHaveBeenCalledExactlyOnceWith(next);
      expect(state.navigateToProject).not.toHaveBeenCalled();
    },
  );

  beforeEach(() => {
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    state.sidebarTasks = [1, 2, 3, 4, 5].map((tid) => ({
      tid,
      lastActive: [0, 5, 50, 10, 20, 40][tid],
      parentTid: tid === 2 || tid === 3 ? 1 : undefined,
      status: "completed",
      alive: false,
      canStop: false,
      resumable: false,
      isProcessing: false,
      childCount: tid === 1 ? 2 : 0,
    }));
  });

  it.each([
    ["creation", "oldest_first", [null, "1", "2", "3", "4", "5", null]],
    ["creation", "newest_first", [null, "5", "4", "1", "3", "2", null]],
    ["activity", "oldest_first", [null, "4", "5", "1", "3", "2", null]],
    ["activity", "newest_first", [null, "1", "2", "3", "5", "4", null]],
  ] as const)(
    "moves through New Task and hidden descendants without visiting the summary (%s, %s)",
    async (sort, order, cycle) => {
      state.ui = { sidebar: { sort, order } };
      const container = roots.create();
      for (const key of ["ArrowDown", "ArrowUp"]) {
        const route = key === "ArrowDown" ? cycle : [...cycle].reverse();
        for (const [index, next] of route.slice(1).entries()) {
          state.activeTaskId = route[index]!;
          state.setActiveTaskId.mockClear();
          state.navigateToProject.mockClear();
          roots.render(h(App, {}), container);
          await act(() => {
            document.dispatchEvent(
              new KeyboardEvent("keydown", { key, altKey: true }),
            );
          });

          if (next === null) {
            expect(state.navigateToProject).toHaveBeenCalledExactlyOnceWith(
              "workspace",
              "project",
            );
            expect(state.setActiveTaskId).not.toHaveBeenCalled();
          } else {
            expect(state.setActiveTaskId).toHaveBeenCalledExactlyOnceWith(next);
            expect(state.navigateToProject).not.toHaveBeenCalled();
          }
        }
      }
    },
  );

  it.each([
    ["creation", "oldest_first", "2", "3"],
    ["activity", "oldest_first", "3", "2"],
    ["creation", "newest_first", "3", "2"],
    ["activity", "newest_first", "2", "3"],
  ] as const)(
    "jumps to attention in both directions with %s and %s",
    async (sort, order, down, up) => {
      state.ui = { sidebar: { sort, order } };
      state.activeTaskId = "4";
      state.attention = new Set([2, 3]);
      const container = roots.create();
      roots.render(h(App, {}), container);

      for (const [key, next] of [
        ["ArrowDown", down],
        ["ArrowUp", up],
      ]) {
        state.setActiveTaskId.mockClear();
        await act(() => {
          document.dispatchEvent(
            new KeyboardEvent("keydown", { key, altKey: true, shiftKey: true }),
          );
        });
        expect(state.setActiveTaskId).toHaveBeenCalledExactlyOnceWith(next);
      }
      expect(state.navigateToProject).not.toHaveBeenCalled();
    },
  );
});

describe("completion-aware task loading", () => {
  const roots = ownedRoots();

  it("passes live partial loading to Sidebar and both session view paths", () => {
    const active = {
      ...makeTaskState(41, false, false, "Known task"),
      status: "completed" as const,
    };
    state.activeTaskId = "41";
    state.tasks = new Map([[active.uuid, active]]);
    state.connected = true;
    state.tasksLoaded = false;

    renderToString(h(App, {}));

    expect(latest(componentProps.sidebar)).toMatchObject({
      tasksLoading: true,
    });
    expect(latest(componentProps.sidebar).propNames).toContain("tasksLoading");
    expect(latest(componentProps.sidebar).propNames).not.toContain("loading");
    expect(latest(componentProps.sessionView)).toEqual({
      tasksLoading: true,
      tid: 41,
    });

    state.tasksLoaded = true;
    renderToString(h(App, {}));

    expect(latest(componentProps.sidebar).tasksLoading).toBe(false);
    expect(latest(componentProps.sessionView)).toEqual({
      tasksLoading: false,
      tid: 41,
    });

    state.activeTaskId = null;
    state.tasks = new Map();
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    state.draftView = makeDraftView();
    state.tasksLoaded = false;
    renderToString(h(App, {}));

    expect(latest(componentProps.sidebar).tasksLoading).toBe(true);
    expect(latest(componentProps.draftSessionView)).toEqual({
      tasksLoading: true,
    });

    state.tasksLoaded = true;
    renderToString(h(App, {}));

    expect(latest(componentProps.sidebar).tasksLoading).toBe(false);
    expect(latest(componentProps.draftSessionView)).toEqual({
      tasksLoading: false,
    });
  });

  it("shows the task layout without a connection overlay when disconnected", () => {
    const active = {
      ...makeTaskState(42, false, false, "Disconnected task"),
      status: "completed" as const,
    };
    state.activeTaskId = "42";
    state.tasks = new Map([[active.uuid, active]]);
    state.connected = false;
    state.tasksLoaded = false;

    const html = renderToString(h(App, {}));

    expect(latest(componentProps.sidebar).tasksLoading).toBe(false);
    expect(componentProps.sessionView).toHaveLength(0);
    expectPlaceholderFrame(html, "disconnected");
    expect(html).not.toContain("connection-overlay");
    expect(html).not.toContain("Connecting…");
  });

  it("closes search on disconnect and ignores its shortcut until reconnect", async () => {
    const container = roots.create();
    state.activeWorkspace = "workspace";
    state.activeProject = "project";
    const pressSearch = () => {
      document.dispatchEvent(
        new KeyboardEvent("keydown", {
          bubbles: true,
          ctrlKey: true,
          key: "k",
        }),
      );
    };

    roots.render(h(App, {}), container);
    await act(pressSearch);
    expect(componentProps.searchPopup).toHaveLength(1);

    state.serverError = { message: "Pending command error" };
    roots.render(h(App, {}), container);
    expect(container.querySelector(".command-error-dialog")).not.toBeNull();

    state.connected = false;
    state.tasksLoaded = false;
    componentProps.searchPopup.length = 0;
    roots.render(h(App, {}), container);
    expectPlaceholderFrame(container.innerHTML, "disconnected");
    expect(container.querySelector(".command-error-dialog")).toBeNull();
    await act(pressSearch);
    expect(componentProps.searchPopup).toHaveLength(0);

    state.connected = true;
    state.serverError = null;
    roots.render(h(App, {}), container);
    expect(componentProps.searchPopup).toHaveLength(0);
    await act(pressSearch);
    expect(componentProps.searchPopup).toHaveLength(1);
  });

  it("updates search and welcome components from partial to complete task lists", async () => {
    const container = roots.create();
    state.connected = true;
    state.tasksLoaded = false;

    await act(() => {
      render(h(App, {}), container);
    });
    expect(latest(componentProps.welcomePage)).toEqual({ tasksLoaded: false });

    await act(() => {
      document.dispatchEvent(
        new KeyboardEvent("keydown", {
          bubbles: true,
          ctrlKey: true,
          key: "k",
        }),
      );
    });
    expect(latest(componentProps.searchPopup)).toEqual({ tasksLoaded: false });

    state.tasksLoaded = true;
    await act(() => {
      render(h(App, {}), container);
    });

    expect(latest(componentProps.welcomePage)).toEqual({ tasksLoaded: true });
    expect(latest(componentProps.searchPopup)).toEqual({ tasksLoaded: true });
  });

  it("keeps a late deep-link loading until it appears or the list completes", () => {
    const tid = 43;
    state.activeTaskId = String(tid);
    state.connected = true;
    state.tasksLoaded = false;

    expect(renderToString(h(App, {}))).toContain("Loading task…");
    expect(componentProps.sessionView).toHaveLength(0);

    const appeared = {
      ...makeTaskState(tid, false, false, "Late task"),
      status: "completed" as const,
    };
    state.tasks = new Map([[appeared.uuid, appeared]]);
    const partialHtml = renderToString(h(App, {}));

    expect(latest(componentProps.sessionView)).toEqual({
      tasksLoading: true,
      tid,
    });
    expect(partialHtml).not.toContain("Loading task…");
    expect(partialHtml).not.toContain(`Task ${tid} not found`);

    state.tasks = new Map();
    expect(renderToString(h(App, {}))).toContain("Loading task…");
    expect(renderToString(h(App, {}))).not.toContain(`Task ${tid} not found`);

    state.tasksLoaded = true;
    const completeHtml = renderToString(h(App, {}));

    expect(completeHtml).toContain(`Task ${tid} not found`);
    expect(completeHtml).not.toContain("Loading task…");
  });
});

describe("welcome theme toggle", () => {
  const roots = ownedRoots();

  it.each([true, false])(
    "offers theme switching without an account strip when connected is %s",
    async (connected) => {
      state.connected = connected;
      state.agentUsage = {
        claude: {
          type: "agent_usage",
          profile: "claude",
          updated_at: 1_700_000_000,
          limits: { five_hour: { utilization: 42 } },
        },
      };
      const root = roots.create();
      roots.render(h(App, {}), root);

      const welcome = root.querySelector(".welcome-page-container")!;
      expect(welcome.querySelector(".sidebar-account")).toBeNull();
      const toggle = welcome.querySelector<HTMLButtonElement>(
        ".theme-toggle.theme-toggle-corner",
      )!;
      expect(toggle.title).toBe("Switch to light theme");
      await act(() => {
        toggle.click();
      });
      expect(state.toggleTheme).toHaveBeenCalledOnce();
    },
  );
});
