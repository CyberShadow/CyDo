import { describe, expect, it, vi } from "vitest";
import { makeTaskState } from "./types";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});
import {
  projectDraftTask,
  taskObservationFromEntry,
  taskStateFromEntry,
  type TaskSnapshotEntry,
} from "./useSessionManager";

describe("taskStateFromEntry draft merge", () => {
  const entry = (draft?: string) => ({
    tid: 11,
    child_count: 0,
    alive: false,
    resumable: false,
    isProcessing: false,
    ...(draft === undefined ? {} : { draft }),
  });

  it("applies an explicitly present newer draft, including a clear", () => {
    const existing = { ...makeTaskState(11, false), serverDraft: "old draft" };

    expect(
      taskStateFromEntry(entry("new draft"), existing, existing.uuid)
        .serverDraft,
    ).toBe("new draft");
    expect(
      taskStateFromEntry(entry(""), existing, existing.uuid).serverDraft,
    ).toBeUndefined();
  });

  it("preserves a prior draft when a snapshot omits the field", () => {
    const existing = { ...makeTaskState(11, false), serverDraft: "old draft" };

    expect(
      taskStateFromEntry(entry(), existing, existing.uuid).serverDraft,
    ).toBe("old draft");
  });
});

describe("taskStateFromEntry usage profile", () => {
  const entry = {
    tid: 11,
    child_count: 0,
    alive: false,
    resumable: false,
    isProcessing: false,
  };

  it("maps the usage profile when seeding a new task from a snapshot", () => {
    expect(
      taskStateFromEntry(
        { ...entry, usage_profile: "/profiles/work" },
        undefined,
        undefined,
      ).usageProfile,
    ).toBe("/profiles/work");
  });

  it("maps the snapshot's usage profile to the task", () => {
    const existing = makeTaskState(11, false);
    const profile = "/profiles/work";

    expect(
      taskStateFromEntry(
        { ...entry, usage_profile: profile },
        existing,
        existing.uuid,
      ).usageProfile,
    ).toBe(profile);
  });

  it.each([null, undefined, ""])(
    "clears a previous usage profile when the snapshot profile is %j",
    (usage_profile) => {
      const existing = {
        ...makeTaskState(11, false),
        usageProfile: "/profiles/work",
      };

      expect(
        taskStateFromEntry({ ...entry, usage_profile }, existing, existing.uuid)
          .usageProfile,
      ).toBeUndefined();
    },
  );
});

describe("task observation adapter", () => {
  const entry = (fields: Record<string, unknown> = {}) =>
    ({
      tid: 11,
      child_count: 0,
      alive: false,
      resumable: false,
      isProcessing: false,
      ...fields,
    }) as TaskSnapshotEntry;

  const idleFacts = {
    tid: 11,
    alive: false,
    isProcessing: false,
    hasMessages: false,
  };

  it("drops own-present null and undefined form facts", () => {
    expect(
      taskObservationFromEntry(
        entry({
          draft: null,
          entry_point: undefined,
          agent_name: null,
          status: undefined,
        }),
        false,
      ),
    ).toEqual(idleFacts);
  });

  it("omits absent form facts", () => {
    expect(taskObservationFromEntry(entry(), false)).toEqual(idleFacts);
  });

  it("preserves explicitly empty form strings", () => {
    expect(
      taskObservationFromEntry(
        entry({
          draft: "",
          entry_point: "",
          agent_name: "",
          status: "pending",
        }),
        false,
      ),
    ).toEqual({
      ...idleFacts,
      text: "",
      entryPoint: "",
      agent: "",
      status: "pending",
    });
  });
});

describe("task observation activity facts", () => {
  it("preserves an alive failed task with messages and no processing", () => {
    expect(
      taskObservationFromEntry(
        {
          tid: 11,
          child_count: 0,
          alive: true,
          resumable: false,
          isProcessing: false,
          status: "failed",
        },
        true,
      ),
    ).toEqual({
      tid: 11,
      alive: true,
      isProcessing: false,
      status: "failed",
      hasMessages: true,
    });
  });
});

describe("draft projection validation", () => {
  const form = { text: "new text", entryPoint: "entry", agent: "agent" };
  const task = {
    ...makeTaskState(71, false),
    projectPath: "/project",
    taskType: "snapshot-type",
    entryPoint: "entry",
  };

  const projected = { ...task, title: form.text, agentName: form.agent };
  const catalog = new Map([
    [
      task.projectPath,
      [
        {
          name: form.entryPoint,
          task_type: task.taskType,
          description: "",
          model_class: "",
          read_only: false,
        },
      ],
    ],
  ]);

  it("reuses the task when the draft projection is already applied", () => {
    expect(projectDraftTask(projected, 71, form, catalog)).toBe(projected);
  });

  it.each(["title", "entryPoint", "agentName", "taskType"] as const)(
    "replaces the task when the projected %s changes",
    (field) => {
      const previous = Object.freeze({ ...projected, [field]: "old value" });
      const next = projectDraftTask(previous, 71, form, catalog);
      expect(next).not.toBe(previous);
      expect(next).toEqual(projected);
    },
  );

  it("projects an unresolved agent without changing the underlying task agent", () => {
    expect(
      projectDraftTask(
        {
          ...task,
          agentName: "snapshot-agent",
          serverDraft: "server observation",
        },
        71,
        { ...form, agent: null },
        new Map(),
      ),
    ).toMatchObject({
      agentName: "snapshot-agent",
      title: form.text,
      serverDraft: "server observation",
    });
  });

  it("requires the underlying task and its canonical project", () => {
    expect(() => projectDraftTask(undefined, 71, form, new Map())).toThrow(
      "Draft projection requires task 71",
    );
    expect(() =>
      projectDraftTask({ ...task, projectPath: "" }, 71, form, new Map()),
    ).toThrow("Draft projection requires project 71");
  });

  it.each([new Map(), new Map([["/project", []]])])(
    "keeps the task type when its unlisted entry point matches the task",
    (catalog) => {
      expect(projectDraftTask(task, 71, form, catalog)).toMatchObject({
        taskType: "snapshot-type",
        entryPoint: "entry",
      });
    },
  );

  it("rejects an unlisted projected name that differs from the task's entry point", () => {
    expect(() =>
      projectDraftTask(
        task,
        71,
        { ...form, entryPoint: "different" },
        new Map([["/project", []]]),
      ),
    ).toThrow("Draft projection entry point does not match task 71");
  });
});

describe("taskStateFromEntry creator", () => {
  const entry: TaskSnapshotEntry = {
    tid: 11,
    alive: false,
    resumable: false,
    isProcessing: false,
    child_count: 0,
  };

  it("maps the creator on new snapshots and later updates", () => {
    const uncreated = taskStateFromEntry(entry, undefined, undefined);
    expect(uncreated.creatorTid).toBeUndefined();
    const snapshot = { ...entry, creator_tid: 7 };
    expect(taskStateFromEntry(snapshot, undefined, undefined).creatorTid).toBe(
      7,
    );
    const updated = taskStateFromEntry(snapshot, uncreated, uncreated.uuid);
    expect(updated.creatorTid).toBe(7);
    expect(taskStateFromEntry(entry, updated, updated.uuid).creatorTid).toBe(7);
  });
});
