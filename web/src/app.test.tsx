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
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ControlledImageStore } from "./components/InputBox";
import type { DraftViewSnapshot, TaskManager } from "./useSessionManager";
import { makeTaskState, type TaskState } from "./types";

const state = vi.hoisted(() => ({
  serverError: null as TaskManager["serverError"],
  dismissServerError: vi.fn(),
  draftView: null as TaskManager["draftView"],
  activeTaskId: null as string | null,
  activeWorkspace: null as string | null,
  activeProject: null as string | null,
  tasks: new Map<string, TaskState>(),
  entryPoints: [] as TaskManager["entryPoints"],
  agents: [] as TaskManager["agents"],
  connected: true,
  tasksLoaded: true,
  getByTid: vi.fn(),
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

vi.mock("./useSessionManager", () => ({
  parseTaskId: (id: string | null) => {
    if (id === null) return null;
    const tid = parseInt(id, 10);
    return String(tid) === id ? tid : null;
  },
  useTaskManager: () =>
    ({
      tasks: state.tasks,
      activeTaskId: state.activeTaskId,
      activeTaskIdRef: { current: state.activeTaskId },
      setActiveTaskId: vi.fn(),
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
      undoConfirm: vi.fn(),
      undoDismiss: vi.fn(),
      dismissAttention: vi.fn(),
      clearInputDraft: vi.fn(),
      setArchived: vi.fn(),
      saveDraft: vi.fn(),
      sendAskUserResponse: vi.fn(),
      sendPermissionPromptResponse: vi.fn(),
      editMessage: vi.fn(),
      editRawEvent: vi.fn(),
      draftView: state.draftView,
      sidebarTasks: [],
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
      agentUsage: {},
      serverError: state.serverError,
      dismissServerError: state.dismissServerError,
      devMode: false,
      navigateHome: vi.fn(),
      navigateToProject: vi.fn(),
      getProjectHref: vi.fn(),
      getTaskHref: vi.fn(),
      getByTid: state.getByTid,
      refreshWorkspaces: vi.fn(),
      historyWindowStep: 0,
      loadMoreHistory: vi.fn(),
      scanState: "idle",
    }) satisfies TaskManager,
}));

vi.mock("./components/InputBox", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./components/InputBox")>();
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
  Router: ({ children }: { children: ComponentChildren }) => {
    const firstRoute = toChildArray(children)[0] as VNode<{
      component: () => VNode;
    }>;
    return h(firstRoute.props.component, {});
  },
  Route: () => null,
}));

vi.mock("./components/Sidebar", () => ({
  Sidebar: () => null,
  flatTaskOrder: () => [],
}));

vi.mock("./useTheme", () => ({
  ThemeContext: {
    Provider: ({ children }: { children: ComponentChildren }) => children,
  },
  useTheme: () => ({ theme: "dark", toggleTheme: vi.fn() }),
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
  useNotifications: () => new Set(),
  requestNotificationPermissionFromGesture: vi.fn(),
}));

vi.mock("./useErrorOverlay", () => ({
  useErrorCapture: () => {},
}));

import { App } from "./app";

beforeEach(() => {
  state.serverError = null;
  state.dismissServerError.mockReset();
  state.draftView = null;
  state.activeTaskId = null;
  state.activeWorkspace = null;
  state.activeProject = null;
  state.tasks = new Map();
  state.entryPoints = [];
  state.agents = [];
  state.connected = true;
  state.tasksLoaded = true;
  state.getByTid.mockReset();
  state.getByTid.mockImplementation((tid: number) =>
    Array.from(state.tasks.values()).find((task) => task.tid === tid),
  );
  controlledImageStore.current = null;
});

describe("server command errors", () => {
  let container: HTMLDivElement | null = null;

  afterEach(() => {
    if (!container) return;
    render(null, container);
    container.remove();
    container = null;
  });

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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
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
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    const html = renderToString(h(App, {}));

    expect(html).toContain(">controlled draft</textarea>");
    expect(html).not.toContain("Loading task");
    expect(html.match(/input-textarea/g) ?? []).toHaveLength(1);
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

  it("keeps the project-keyed controlled composer mounted through owned numeric acknowledgement", async () => {
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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
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
      composerResetToken: 11,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    try {
      state.activeWorkspace = "workspace";
      state.activeProject = "project";
      state.draftView = rootDraft;
      container = document.createElement("div");
      document.body.appendChild(container);
      await act(() => {
        render(h(App, {}), container!);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
        completeNextReader();
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      await act(() => {
        pasteImage(beforeTextarea);
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
        render(h(App, {}), container!);
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
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
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
      composerResetToken: 15,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
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
      container = document.createElement("div");
      document.body.appendChild(container);
      await act(() => {
        render(h(App, {}), container!);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
        completeNextReader();
        pasteImage(beforeTextarea);
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      state.draftView = {
        ...projectDraft,
        metadataReady: false,
      };
      await act(() => {
        render(h(App, {}), container!);
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
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);

      state.draftView = projectDraft;
      await act(() => {
        render(h(App, {}), container!);
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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
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
      composerResetToken: 19,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
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
      container = document.createElement("div");
      document.body.appendChild(container);
      await act(() => {
        render(h(App, {}), container!);
      });

      const rootTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(rootTextarea);
        completeNextReader();
        pasteImage(rootTextarea);
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      state.activeTaskId = "72";
      state.tasks = new Map([[realTaskB.uuid, realTaskB]]);
      state.draftView = null;
      await act(() => {
        render(h(App, {}), container!);
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
        render(h(App, {}), container!);
      });

      expect(container.querySelectorAll(".input-box")).toHaveLength(0);
      expect(container.querySelectorAll("textarea")).toHaveLength(0);
      expect(container.querySelector(".session-empty")?.textContent).toContain(
        "Loading task…",
      );

      state.activeTaskId = null;
      state.draftView = cachedDraft;
      await act(() => {
        render(h(App, {}), container!);
      });

      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(
        container.querySelector<HTMLTextAreaElement>("textarea")?.value,
      ).toBe("retain A across metadata-gap navigation");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
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
      };
      await act(() => {
        render(h(App, {}), container!);
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
      projectKey: "workspace\0/project-a",
      viewKey: "workspace\0/project-a",
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
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
      onSubmit: submitA,
    } satisfies DraftViewSnapshot;
    const draftB = {
      ...draftA,
      projectKey: "workspace\0/project-b",
      viewKey: "workspace\0/project-b",
      projectName: "project-b",
      projectPath: "/project-b",
      text: "draft B",
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    const renderApp = async () => {
      await act(() => {
        render(h(App, {}), container!);
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
      container = document.createElement("div");
      document.body.appendChild(container);
      await renderApp();

      const imageStore = controlledImageStore.current!;
      expect(imageStore.entries.size).toBe(1);
      const aEntry = imageStore.entries.get(draftA.projectKey)!;

      const aTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(aTextarea);
        complete(readers[0]!);
        pasteImage(aTextarea);
      });
      const heldAcrossHome = readers[1]!;
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      expect(aEntry.images).toHaveLength(1);

      state.activeProject = null;
      state.draftView = null;
      await renderApp();
      expect(imageStore.entries.get(draftA.projectKey)).toBe(aEntry);
      expect(aEntry.images).toHaveLength(1);

      state.activeProject = "project-a";
      state.draftView = draftA;
      await act(() => {
        render(h(App, {}), container!);
        complete(heldAcrossHome);
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      expect(aEntry.images).toHaveLength(2);

      let heldAcrossReset: FileReader;
      await act(() => {
        const current =
          container!.querySelector<HTMLTextAreaElement>("textarea")!;
        pasteImage(current);
        heldAcrossReset = readers[2]!;
      });

      state.activeProject = "project-b";
      state.draftView = draftB;
      await renderApp();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(imageStore.entries.get(draftA.projectKey)).toBe(aEntry);
      expect(aEntry.images).toHaveLength(2);

      const bTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(bTextarea);
        complete(readers[3]!);
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      const bEntry = imageStore.entries.get(draftB.projectKey)!;
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

      await act(() => {
        complete(heldAcrossReset);
      });
      expect(imageStore.entries.size).toBe(0);
      expect(aEntry.images).toEqual([]);

      const freshSubmit = vi.fn();
      state.connected = true;
      state.activeProject = "project-a";
      state.draftView = {
        ...draftA,
        text: "fresh A",
        composerResetToken: 1,
        onSubmit: freshSubmit,
      };
      await renderApp();
      const freshEntry = imageStore.entries.get(draftA.projectKey)!;
      expect(freshEntry).not.toBe(aEntry);
      expect(freshEntry.resetToken).toBe(1);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      await act(() => {
        container!.querySelector<HTMLButtonElement>(".btn-send")!.click();
      });
      expect(freshSubmit).toHaveBeenCalledWith("fresh A", []);

      await act(() => {
        const current =
          container!.querySelector<HTMLTextAreaElement>("textarea")!;
        pasteImage(current);
        complete(readers[4]!);
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

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

  it("keeps the project composer stable while switching persisted numeric drafts", async () => {
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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      lifecycle: "present" as const,
      disabled: false,
      metadataReady: true,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
      onSubmit: vi.fn(),
    };
    const draftA = {
      ...projectDraft,
      remoteTid: 71,
      text: "persisted draft A",
      entryPoint: "entry A",
      agent: "agent A",
      composerResetToken: 11,
    } satisfies DraftViewSnapshot;
    const draftB = {
      ...projectDraft,
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
      container = document.createElement("div");
      document.body.appendChild(container);
      await act(() => {
        render(h(App, {}), container!);
      });

      const beforeInputBox =
        container.querySelector<HTMLElement>(".input-box")!;
      const beforeTextarea =
        container.querySelector<HTMLTextAreaElement>("textarea")!;
      await act(() => {
        pasteImage(beforeTextarea);
        completeNextReader();
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      // The B route has committed, but the draft reducer has not yet adopted
      // B. The A project slot must continue to own the controlled composer.
      state.activeTaskId = "72";
      await act(() => {
        render(h(App, {}), container!);
      });

      expect(container.querySelector(".input-box")).toBe(beforeInputBox);
      expect(container.querySelector("textarea")).toBe(beforeTextarea);
      expect(container.querySelectorAll(".input-box")).toHaveLength(1);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(container.querySelector(".session-empty")).toBeNull();
      expect(container.textContent).not.toContain("Loading task…");
      expect(beforeTextarea.value).toBe("persisted draft A");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      state.draftView = draftB;
      await act(() => {
        render(h(App, {}), container!);
      });

      expect(container.querySelector(".input-box")).toBe(beforeInputBox);
      expect(container.querySelector("textarea")).toBe(beforeTextarea);
      expect(container.querySelectorAll("textarea")).toHaveLength(1);
      expect(beforeTextarea.value).toBe("persisted draft B");
      expect(
        container.querySelector(".task-type-row.selected .task-type-name")
          ?.textContent,
      ).toBe("entry B");
      expect(
        container.querySelector<HTMLSelectElement>(".agent-picker")?.value,
      ).toBe("agent B");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      readAsDataURL.mockRestore();
    }
  });
});

describe("missing numeric tasks", () => {
  const tid = 123;

  it("shows a not-found message once the tasks list has loaded", () => {
    state.activeTaskId = String(tid);

    const html = renderToString(h(App, {}));

    expect(html).toContain(`Task ${tid} not found`);
    expect(html).not.toContain("Loading task…");
  });

  it("keeps loading while the tasks list has not loaded yet, even if connected", () => {
    state.activeTaskId = String(tid);
    state.connected = true;
    state.tasksLoaded = false;

    const html = renderToString(h(App, {}));

    expect(html).toContain("Loading task…");
    expect(html).not.toContain(`Task ${tid} not found`);
  });

  it("keeps loading while disconnected", () => {
    // A real disconnect resets tasksListEpoch, so tasksLoaded goes false too.
    state.activeTaskId = String(tid);
    state.connected = false;
    state.tasksLoaded = false;

    expect(renderToString(h(App, {}))).toContain("Loading task…");
  });

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
