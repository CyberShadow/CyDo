import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ControlMessage } from "./protocol";
import type { TaskManager } from "./useSessionManager";

const testState = vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  const randomUUID = vi.fn();
  vi.stubGlobal("crypto", { randomUUID });
  vi.stubGlobal("document", {
    hidden: true,
    querySelector: () => null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  });

  return {
    randomUUID,
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

function renderedPath() {
  const { workspace, project, tid } = testState.route;
  return `/${workspace}/${project}/task/${tid}`;
}

vi.stubGlobal("location", {
  get pathname() {
    return renderedPath();
  },
});

vi.mock("preact-iso", () => ({
  useLocation: () => ({ route: testState.navigate, path: renderedPath() }),
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

beforeEach(() => {
  let nextId = 0;
  testState.randomUUID.mockImplementation(() => `test-uuid-${++nextId}`);
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

describe("agent usage", () => {
  it("retains independent usage messages for two profiles", async () => {
    await renderManager();
    const connection = testState.connection!;
    const work = {
      type: "agent_usage",
      profile: "/profiles/work",
      updated_at: 1,
      limits: { five_hour: { utilization: 42 } },
    } satisfies ControlMessage;
    const personal = {
      type: "agent_usage",
      profile: "/profiles/personal",
      updated_at: 2,
      limits: { five_hour: { utilization: 71 } },
    } satisfies ControlMessage;

    await act(() => {
      connection.onControlMessage?.(work);
      connection.onControlMessage?.(personal);
    });

    expect((await renderManager()).agentUsage).toEqual({
      [work.profile]: work,
      [personal.profile]: personal,
    });
  });
});

describe("task promotion", () => {
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

  function latestUndoRequestId(
    connection: Awaited<ReturnType<typeof seedUndoTask>>,
  ) {
    const requestId: unknown = connection.undoTask.mock.lastCall?.[6];
    expect(requestId).toEqual(expect.any(String));
    return requestId as string;
  }

  it("echoes a native preview count when confirming undo", async () => {
    const connection = await seedUndoTask();
    const currentManager = await renderManager();

    currentManager.undoPreview(42, "boundary-42");
    const requestId = latestUndoRequestId(connection);
    expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
      anchor: "boundary-42",
      kind: "requesting",
      requestId,
      retainsPrompt: false,
    });
    expect(connection.undoTask).toHaveBeenLastCalledWith(
      42,
      "boundary-42",
      true,
      false,
      false,
      undefined,
      requestId,
    );
    await act(() => {
      connection.onControlMessage?.({
        type: "undo_preview",
        tid: 42,
        correlation_id: requestId,
        messages_removed: 3,
        count_unit: "codex_turns",
        can_revert_files: false,
      } satisfies ControlMessage);
    });

    expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
      anchor: "boundary-42",
      kind: "codex_turns",
      messagesRemoved: 3,
      canRevertFiles: false,
      retainsPrompt: false,
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

  it.each([true, false])(
    "forwards revert_files=%s for history-entry undo",
    async (revertFiles) => {
      const connection = await seedUndoTask();
      const currentManager = await renderManager();

      currentManager.undoPreview(42, "boundary-42");
      await act(() => {
        connection.onControlMessage?.({
          type: "undo_preview",
          tid: 42,
          correlation_id: latestUndoRequestId(connection),
          messages_removed: 4,
          count_unit: "history_entries",
          can_revert_files: !revertFiles,
          file_changes: {
            files_changed: ["/project/a.txt"],
            insertions: 5,
            deletions: 2,
          },
        } satisfies ControlMessage);
      });

      expect((await renderManager()).getByTid(42)?.undoPending).toEqual({
        anchor: "boundary-42",
        kind: "history_entries",
        messagesRemoved: 4,
        canRevertFiles: !revertFiles,
        fileChanges: { files: ["/project/a.txt"], insertions: 5, deletions: 2 },
        retainsPrompt: false,
      });

      manager!.undoConfirm(42, true, revertFiles);

      expect(connection.undoTask).toHaveBeenLastCalledWith(
        42,
        "boundary-42",
        false,
        true,
        revertFiles,
        undefined,
      );
    },
  );

  it.each(["different request ID", "dismissed request"] as const)(
    "ignores a preview for a %s",
    async (scenario) => {
      const connection = await seedUndoTask();
      const currentManager = await renderManager();
      await act(() => {
        currentManager.undoPreview(42, "boundary-42");
      });
      const requestId = latestUndoRequestId(connection);
      if (scenario === "dismissed request") {
        await act(() => {
          manager!.undoDismiss(42);
        });
      }

      const before = (await renderManager()).getByTid(42)!.undoPending;
      expect(before).toEqual(
        scenario === "dismissed request"
          ? null
          : {
              anchor: "boundary-42",
              kind: "requesting",
              requestId,
              retainsPrompt: false,
            },
      );

      await act(() => {
        connection.onControlMessage?.({
          type: "undo_preview",
          tid: 42,
          correlation_id:
            scenario === "different request ID" ? "older-request" : requestId,
          messages_removed: 4,
          count_unit: "history_entries",
          can_revert_files: false,
        } satisfies ControlMessage);
      });

      expect((await renderManager()).getByTid(42)!.undoPending).toEqual(before);
    },
  );

  it("waits for the new preview after dismissing and reopening the same boundary", async () => {
    const connection = await seedUndoTask();
    const currentManager = await renderManager();

    await act(() => {
      currentManager.undoPreview(42, "boundary-42");
    });
    const firstId = latestUndoRequestId(connection);
    await act(() => {
      manager!.undoDismiss(42);
    });
    await act(() => {
      manager!.undoPreview(42, "boundary-42");
    });
    const secondId = latestUndoRequestId(connection);

    const reply = (correlation_id: string, messages_removed: number) =>
      act(() => {
        connection.onControlMessage?.({
          type: "undo_preview",
          tid: 42,
          correlation_id,
          messages_removed,
          count_unit: "history_entries",
          can_revert_files: false,
        } satisfies ControlMessage);
      });

    await reply(firstId, 4);
    expect((await renderManager()).getByTid(42)?.undoPending).toMatchObject({
      kind: "requesting",
      requestId: secondId,
    });

    await reply(secondId, 2);
    expect((await renderManager()).getByTid(42)?.undoPending).toMatchObject({
      anchor: "boundary-42",
      kind: "history_entries",
      messagesRemoved: 2,
    });
  });
});
