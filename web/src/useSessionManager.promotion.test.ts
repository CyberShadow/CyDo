import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ControlMessage } from "./protocol";
import type { TaskManager } from "./useSessionManager";

const testState = vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("crypto", { randomUUID: () => "task-uuid" });
  vi.stubGlobal("document", {
    hidden: true,
    querySelector: () => null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  });

  return {
    route: {
      workspace: "source",
      project: "project",
      tid: "42",
    },
    navigate: vi.fn(),
    addToast: vi.fn(),
    connection: null as {
      onControlMessage: ((message: unknown) => void) | null;
      promoteTask: ReturnType<typeof vi.fn>;
      undoTask: ReturnType<typeof vi.fn>;
    } | null,
  };
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({ route: testState.navigate }),
  useRoute: () => ({
    params: {
      workspace: testState.route.workspace,
      project: testState.route.project,
      tid: testState.route.tid,
    },
    path: `/${testState.route.workspace}/${testState.route.project}/task/${testState.route.tid}`,
  }),
}));

vi.mock("./connection", () => {
  class MockConnection {
    onTaskMessage: ((...args: unknown[]) => void) | null = null;
    onHistoryBoundaryReplaced: ((...args: unknown[]) => void) | null = null;
    onUnconfirmedUserMessage: ((...args: unknown[]) => void) | null = null;
    onAgentAck: ((...args: unknown[]) => void) | null = null;
    onControlMessage: ((message: unknown) => void) | null = null;
    onStatusChange: ((connected: boolean) => void) | null = null;
    onClientError: ((message: string) => void) | null = null;

    readonly connect = vi.fn();
    readonly disconnect = vi.fn();
    readonly promoteTask = vi.fn();
    readonly undoTask = vi.fn();
    readonly requestTaskTypes = vi.fn();
    readonly requestHistory = vi.fn(() => false);

    constructor() {
      testState.connection = this;
    }
  }

  return { Connection: MockConnection };
});

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

describe("task promotion", () => {
  beforeEach(() => {
    testState.route.workspace = "source";
    testState.route.project = "project";
    testState.route.tid = "42";
    testState.connection = null;
    testState.navigate.mockReset();
    testState.addToast.mockReset();
    manager = null;
    root = createRoot();
  });

  afterEach(async () => {
    await act(() => {
      render(null, root);
    });
  });

  it("uses the current workspace without optimistically promoting the task", async () => {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [
          {
            tid: 42,
            child_count: 0,
            alive: false,
            resumable: true,
            isProcessing: false,
            status: "importable",
          },
        ],
      } satisfies ControlMessage);
    });

    expect((await renderManager()).getByTid(42)?.status).toBe("importable");

    testState.route.workspace = "destination";
    const currentManager = await renderManager();
    currentManager.promote(42);

    expect(connection.promoteTask).toHaveBeenCalledWith(42, "destination");
    expect(currentManager.getByTid(42)?.status).toBe("importable");
  });

  async function seedUndoTask() {
    await renderManager();
    const connection = testState.connection!;
    await act(() => {
      connection.onControlMessage?.({
        type: "tasks_list",
        complete: true,
        tasks: [
          {
            tid: 42,
            child_count: 0,
            alive: false,
            resumable: true,
            isProcessing: false,
            status: "importable",
          },
        ],
      } satisfies ControlMessage);
    });
    return connection;
  }

  it("echoes a native preview count when confirming undo", async () => {
    const connection = await seedUndoTask();
    const currentManager = await renderManager();

    currentManager.undoPreview(42, "boundary-42");
    expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
      anchor: "boundary-42",
      kind: "requesting",
      canRevertFiles: false,
      retainsPrompt: false,
      supportsFileRevert: true,
    });
    expect(connection.undoTask).toHaveBeenLastCalledWith(
      42,
      "boundary-42",
      true,
      false,
      false,
    );
    await act(() => {
      connection.onControlMessage?.({
        type: "undo_preview",
        tid: 42,
        messages_removed: 3,
        count_unit: "codex_turns",
      } satisfies ControlMessage);
    });

    expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
      anchor: "boundary-42",
      kind: "codex_turns",
      messagesRemoved: 3,
      canRevertFiles: false,
      retainsPrompt: false,
      supportsFileRevert: true,
    });

    manager!.undoConfirm(42, true, false);

    expect(connection.undoTask).toHaveBeenLastCalledWith(
      42,
      "boundary-42",
      false,
      true,
      false,
      3,
    );
  });

  it("omits an expected count for history-entry undo", async () => {
    const connection = await seedUndoTask();
    const currentManager = await renderManager();

    currentManager.undoPreview(42, "boundary-42");
    await act(() => {
      connection.onControlMessage?.({
        type: "undo_preview",
        tid: 42,
        messages_removed: 4,
        count_unit: "history_entries",
      } satisfies ControlMessage);
    });

    expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
      anchor: "boundary-42",
      kind: "history_entries",
      messagesRemoved: 4,
      canRevertFiles: false,
      retainsPrompt: false,
      supportsFileRevert: true,
    });

    manager!.undoConfirm(42, true, false);

    expect(connection.undoTask).toHaveBeenLastCalledWith(
      42,
      "boundary-42",
      false,
      true,
      false,
      undefined,
    );
  });
});
