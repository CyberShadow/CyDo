import { describe, expect, it } from "vitest";
import {
  assertResolvedDraftForm,
  editorMetadataReady,
  editorSubmittable,
  projectDraftDefaults,
  createDraftState,
  createProjectKey,
  getEditor,
  reduceDraft,
  tombstonedTids,
  type DraftEffect,
  type DraftEvent,
  type DraftState,
  type ProjectIdentity,
  type TaskSnapshot,
} from "./draftReconciler";

const project = { workspace: "workspace", projectPath: "/project" };
const projectKey = createProjectKey(project.workspace, project.projectPath);
const defaults = { entryPoint: "entry", agent: "agent" };
const metadata = {
  type: "fixture-project-metadata",
  project,
  metadata: { catalog: null, defaults },
} as const;
const uuidA = "11111111-1111-4111-8111-111111111111";
const uuidB = "22222222-2222-4222-8222-222222222222";
const a = `composition:${uuidA}` as const;
const b = `composition:${uuidB}` as const;
const c = "composition:33333333-3333-4333-8333-333333333333";

function assertDraftInvariants(state: DraftState) {
  const tids: number[] = [];
  const correlations: string[] = [];
  const tombstones: number[] = [];
  for (const [key, id] of Object.entries(state.newTaskByProject)) {
    const editor = getEditor(state, id);
    expect(id).toMatch(/^composition:/);
    expect(
      createProjectKey(editor.project.workspace, editor.project.projectPath),
    ).toBe(key);
    expect(editor.desired.kind).not.toBe("none");
    expect(["absent", "creating"]).toContain(editor.remote.kind);
    if (editor.desired.kind === "submitting")
      expect(editor.remote.kind).toBe("creating");
  }
  for (const [id, editor] of Object.entries(state.editors)) {
    const { project: owner, remote, desired } = editor;
    if (remote.kind === "present" || remote.kind === "deleting")
      tids.push(remote.tid);
    if (remote.kind === "deleting") {
      tombstones.push(remote.tid);
      expect(desired.kind).toBe("none");
    }
    if (remote.kind === "creating") {
      correlations.push(remote.correlationId);
      expect(id).toBe(`composition:${remote.correlationId}`);
    }
    if (id.startsWith("task:")) {
      expect(remote.kind === "present" || remote.kind === "deleting").toBe(
        true,
      );
      if (remote.kind === "present" || remote.kind === "deleting")
        expect(id).toBe(`task:${remote.tid}`);
    }
    if (desired.kind === "editing") {
      if (projectDraftDefaults(state, owner)) {
        expect(editor.defaults.entryPoint).not.toBeNull();
        expect(editor.defaults.agent).not.toBeNull();
      }
    }
  }
  expect(new Set(tids).size).toBe(tids.length);
  expect(new Set(correlations).size).toBe(correlations.length);
  expect(tombstonedTids(state)).toEqual(tombstones.sort((a, b) => a - b));
}

type ProjectMetadataFixture = {
  type: "fixture-project-metadata";
  project: ProjectIdentity;
  metadata: {
    catalog: readonly string[] | null;
    defaults: typeof defaults | null;
  };
};

function editorTrace(initial = createDraftState()) {
  let state = initial;
  const dispatch = (event: DraftEvent): readonly DraftEffect[] => {
    const before = state;
    const result = reduceDraft(before, event);
    if (
      event.type === "project-catalog" ||
      event.type === "workspace-draft-defaults" ||
      event.type === "global-draft-defaults" ||
      event.type === "agents-list"
    ) {
      expect(Object.keys(result.state.editors)).toEqual(
        Object.keys(before.editors),
      );
      for (const effect of result.effects) {
        expect(effect.type).toBe("schedule-create");
        expect(getEditor(before, effect.editorId).remote.kind).toBe("absent");
      }
    }
    state = result.state;
    assertDraftInvariants(state);
    return result.effects;
  };
  return {
    get state() {
      return state;
    },
    dispatch(event: DraftEvent | ProjectMetadataFixture) {
      if (event.type !== "fixture-project-metadata") return dispatch(event);
      const { project, metadata } = event;
      const projects = new Map(state.metadata.projects).set(
        createProjectKey(project.workspace, project.projectPath),
        {
          project,
          entryPoint: metadata.defaults?.entryPoint ?? null,
          agent: metadata.defaults?.agent ?? null,
        },
      );
      const effects = dispatch({
        type: "workspace-draft-defaults",
        projects: [...projects.values()],
      });
      const catalog =
        metadata.catalog ??
        (metadata.defaults ? [metadata.defaults.entryPoint] : null);
      if (!catalog) return effects;
      return [
        ...effects,
        ...dispatch({
          type: "project-catalog",
          projectPath: project.projectPath,
          catalog: catalog.map((name) => ({
            name,
            task_type: name,
            description: "",
            model_class: "",
            read_only: false,
          })),
        }),
      ];
    },
  };
}

function snapshot(tid: number, text: string): TaskSnapshot {
  return {
    tid,
    text,
    ...defaults,
    active: false,
    processing: false,
    hasMessages: false,
  };
}

describe("identity-keyed draft editors", () => {
  it("allocates a blank editor before typing and creates with its UUID after metadata resolves", () => {
    const trace = editorTrace();
    expect(
      trace.dispatch({
        type: "attach-new-task",
        editorId: a,
        project,
      }),
    ).toEqual([]);
    expect(trace.state.newTaskByProject[projectKey]).toBe(a);
    expect(getEditor(trace.state, a).desired).toMatchObject({ text: "" });
    expect(
      trace.dispatch({
        type: "edit-text",
        editorId: a,
        text: "before metadata",
      }),
    ).toEqual([]);
    expect(trace.dispatch(metadata)).toEqual([
      expect.objectContaining({
        type: "schedule-create",
        editorId: a,
        correlationId: uuidA,
      }),
    ]);
    const due = {
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    } as const;
    expect(trace.dispatch(due)).toEqual([
      {
        type: "create-task",
        editorId: a,
        correlationId: uuidA,
        ...defaults,
        content: null,
      },
    ]);
    expect(trace.dispatch(due)).toEqual([]);
    trace.dispatch({
      type: "task-created",
      editorId: a,
      correlationId: uuidA,
      tid: 71,
      successor: b,
    });
    expect(getEditor(trace.state, a)).toMatchObject({
      remote: { kind: "present", tid: 71, status: "pending" },
      desired: { text: "before metadata", ...defaults },
    });
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
    expect(getEditor(trace.state, b).desired).toMatchObject({
      text: "",
      ...defaults,
    });
  });

  it("creates B before A settles and deletes only A when its acknowledgement arrives", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({ type: "edit-text", editorId: a, text: "discard A" });
    trace.dispatch({
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    });
    expect(
      trace.dispatch({ type: "clear", editorId: a, successor: b }),
    ).toEqual([]);
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
    trace.dispatch({ type: "edit-text", editorId: b, text: "keep B" });
    expect(
      trace.dispatch({
        type: "create-timer-due",
        editorId: b,
        correlationId: uuidB,
      }),
    ).toEqual([
      expect.objectContaining({
        type: "create-task",
        editorId: b,
        correlationId: uuidB,
      }),
    ]);
    const lateAck = {
      type: "task-created",
      editorId: a,
      correlationId: uuidA,
      tid: 71,
    } as const;
    expect(trace.dispatch(lateAck)).toEqual([
      { type: "delete-task", editorId: a, tid: 71 },
    ]);
    expect(tombstonedTids(trace.state)).toEqual([71]);
    expect(() => trace.dispatch(lateAck)).toThrow();
    trace.dispatch({
      type: "task-created",
      editorId: b,
      correlationId: uuidB,
      tid: 72,
      successor: c,
    });
    expect(
      trace.dispatch({ type: "task-deleted", editorId: a, tid: 71 }),
    ).toEqual([]);
    expect(trace.state.editors[a]).toBeUndefined();
    expect(tombstonedTids(trace.state)).toEqual([]);
    expect(getEditor(trace.state, b)).toMatchObject({
      remote: { kind: "present", tid: 72, status: "pending" },
      desired: { text: "keep B" },
    });
    expect(trace.state.newTaskByProject[projectKey]).toBe(c);
  });

  it("keeps independent persisted forms and scopes delayed saves and deletion to each tid", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    expect(
      trace.dispatch({
        type: "open-persisted",
        editorId: "task:71",
        project,
        snapshot: snapshot(71, "A"),
      }),
    ).toEqual([]);
    expect(
      trace.dispatch({
        type: "open-persisted",
        editorId: "task:72",
        project,
        snapshot: snapshot(72, "B"),
      }),
    ).toEqual([]);
    expect(trace.dispatch({ type: "clear", editorId: a })).toEqual([]);
    for (const [tid, text] of [
      [71, "local A"],
      [72, "local B"],
    ] as const) {
      const editorId = `task:${tid}` as const;
      expect(trace.dispatch({ type: "edit-text", editorId, text })).toEqual([
        expect.objectContaining({ type: "project-draft", editorId, tid }),
        expect.objectContaining({ type: "ensure-draft-save", editorId, tid }),
      ]);
    }
    const { formVersion } = getEditor(trace.state, "task:71");
    expect(
      trace.dispatch({
        type: "save-timer-due",
        editorId: "task:71",
        tid: 71,
        formVersion,
      }),
    ).toEqual([
      expect.objectContaining({ type: "set-draft", tid: 71, text: "local A" }),
    ]);
    expect(trace.dispatch({ type: "clear", editorId: "task:71" })).toEqual([
      { type: "delete-task", editorId: "task:71", tid: 71 },
    ]);
    expect(() =>
      trace.dispatch({ type: "task-deleted", editorId: "task:71", tid: 72 }),
    ).toThrow();
    trace.dispatch({ type: "task-deleted", editorId: "task:71", tid: 71 });
    expect(trace.state.editors["task:71"]).toBeUndefined();
    expect(getEditor(trace.state, "task:72").desired).toMatchObject({
      text: "local B",
    });
    expect(getEditor(trace.state, a).desired).toMatchObject({ text: "" });
  });

  it.each([
    ["active", { active: true }],
    ["processing", { processing: true }],
    ["has messages", { hasMessages: true }],
    ["blank", { text: " " }],
  ] as const)(
    "rejects a %s snapshot before opening an editor",
    (_name, overrides) => {
      const trace = editorTrace();
      expect(() =>
        trace.dispatch({
          type: "open-persisted",
          editorId: "task:71",
          project,
          snapshot: { ...snapshot(71, "A"), ...overrides },
        }),
      ).toThrow();
      expect(trace.state).toEqual(createDraftState());
    },
  );

  it("cancels a scheduled create when the composition is cleared", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({
      type: "edit-text",
      editorId: a,
      text: "discard before create",
    });
    expect(
      trace.dispatch({ type: "clear", editorId: a, successor: b }),
    ).toEqual([
      { type: "cancel-create-schedule", editorId: a, correlationId: uuidA },
    ]);
    expect(trace.state.editors[a]).toBeUndefined();
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
    expect(getEditor(trace.state, b).desired).toMatchObject({
      text: "",
      ...defaults,
    });
    expect(trace.dispatch({ type: "clear", editorId: b })).toEqual([]);
  });

  it("includes image attachments in an atomic create with the composition correlation", () => {
    const trace = editorTrace();
    const image = {
      id: "image-one",
      dataURL: "data:image/png;base64,aW1hZ2U=",
      base64: "aW1hZ2U=",
      mediaType: "image/png",
    };
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    expect(
      trace.dispatch({ type: "submit", editorId: a, images: [image] }),
    ).toEqual([
      {
        type: "create-task",
        editorId: a,
        correlationId: uuidA,
        ...defaults,
        content: { text: "", images: [image] },
      },
    ]);
    expect(
      trace.dispatch({
        type: "task-created",
        editorId: a,
        correlationId: uuidA,
        tid: 71,
        successor: b,
      }),
    ).toEqual([]);
    expect(getEditor(trace.state, a)).toMatchObject({
      remote: { kind: "present", tid: 71, status: "pending" },
      desired: {
        kind: "submitting",
        text: "",
        ...defaults,
        images: [image],
        attempt: {
          delivery: "atomic-create",
          correlationId: uuidA,
          phase: "awaiting-acceptance",
        },
      },
    });
    trace.dispatch({ type: "submission-accepted", editorId: a, tid: 71 });
    expect(trace.state.editors[a]).toBeUndefined();
  });

  it("flushes only the pending save of the same editor after a catalog drop", () => {
    const trace = editorTrace();
    const editorId = "task:71";
    trace.dispatch({
      type: "open-persisted",
      editorId,
      project,
      snapshot: snapshot(71, "server"),
    });
    const idle = trace.state;
    expect(trace.dispatch({ type: "flush", editorId })).toEqual([]);
    expect(trace.state).toBe(idle);
    trace.dispatch({ type: "edit-text", editorId, text: "local edit" });
    const edited = getEditor(trace.state, editorId);
    expect(
      trace.dispatch({
        ...metadata,
        metadata: { catalog: [], defaults: null },
      }),
    ).toEqual([]);
    expect(getEditor(trace.state, editorId)).toBe(edited);
    expect(editorSubmittable(trace.state, editorId)).toBe(false);
    expect(trace.dispatch({ type: "flush", editorId })).toEqual([
      {
        type: "cancel-draft-save",
        editorId,
        tid: 71,
        formVersion: edited.formVersion,
      },
      {
        type: "set-draft",
        editorId,
        tid: 71,
        text: "local edit",
        formVersion: edited.formVersion,
      },
    ]);
    expect(tombstonedTids(trace.state)).toEqual([]);
  });

  it("keeps a promoted composition when a snapshot names an unlisted entry point", () => {
    const trace = editorTrace();
    trace.dispatch({ ...metadata, metadata: { catalog: ["entry"], defaults } });
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({ type: "edit-text", editorId: a, text: "original" });
    trace.dispatch({
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    });
    trace.dispatch({
      type: "task-created",
      editorId: a,
      correlationId: uuidA,
      tid: 71,
      successor: b,
    });
    trace.dispatch({ type: "edit-text", editorId: a, text: "new edit" });
    const { formVersion } = getEditor(trace.state, a);
    expect(
      trace.dispatch({
        type: "task-observed",
        editorId: a,
        observation: { tid: 71, entryPoint: "unavailable", text: "original" },
      }),
    ).toEqual([
      expect.objectContaining({ type: "project-draft", editorId: a, tid: 71 }),
      expect.objectContaining({
        type: "ensure-draft-save",
        editorId: a,
        tid: 71,
        formVersion: formVersion + 1,
      }),
    ]);
    expect(getEditor(trace.state, a).desired).toMatchObject({
      text: "new edit",
      entryPoint: "unavailable",
    });
    expect(editorSubmittable(trace.state, a)).toBe(false);
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
  });

  it("retains an absent editor and ignores repeated project metadata", () => {
    const trace = editorTrace();
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    const rejecting = {
      ...metadata,
      metadata: { catalog: [], defaults: null },
    };
    expect(trace.dispatch(rejecting)).toEqual([]);
    expect(trace.state.editors[a]).toBeDefined();
    const before = trace.state;
    expect(trace.dispatch(rejecting)).toEqual([]);
    expect(trace.state).toBe(before);
  });

  it("cancels the exact pending save when the persisted editor is cleared", () => {
    const trace = editorTrace();
    const editorId = "task:71";
    trace.dispatch({
      type: "open-persisted",
      editorId,
      project,
      snapshot: snapshot(71, "A"),
    });
    trace.dispatch({ type: "edit-text", editorId, text: "unsaved A" });
    const { formVersion } = getEditor(trace.state, editorId);
    expect(trace.dispatch({ type: "clear", editorId })).toEqual([
      { type: "cancel-draft-save", editorId, tid: 71, formVersion },
      { type: "delete-task", editorId, tid: 71 },
    ]);
    expect(
      trace.dispatch({
        type: "save-timer-due",
        editorId,
        tid: 71,
        formVersion,
      }),
    ).toEqual([]);
  });

  it("merges pristine peer fields and uses the old text for compare-and-swap", () => {
    const trace = editorTrace();
    const editorId = "task:71";
    trace.dispatch({
      type: "open-persisted",
      editorId,
      project,
      snapshot: snapshot(71, "A"),
    });
    trace.dispatch({ type: "edit-text", editorId, text: "local A" });
    trace.dispatch({
      type: "task-observed",
      editorId,
      observation: {
        tid: 71,
        oldText: "A",
        text: "peer B",
        entryPoint: "peer entry",
        agent: "peer agent",
      },
    });
    expect(getEditor(trace.state, editorId).desired).toMatchObject({
      text: "local A",
      entryPoint: "peer entry",
      agent: "peer agent",
    });
    trace.dispatch({
      type: "task-observed",
      editorId,
      observation: {
        tid: 71,
        oldText: "local A",
        text: "peer C",
      },
    });
    expect(getEditor(trace.state, editorId).desired).toMatchObject({
      text: "peer C",
      entryPoint: "peer entry",
      agent: "peer agent",
    });
  });

  it("tracks tombstones independently across projects and removes only the matching deletion", () => {
    const trace = editorTrace();
    const otherProject = { ...project, workspace: "other workspace" };
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({ ...metadata, project: otherProject });
    trace.dispatch({
      type: "attach-new-task",
      editorId: b,
      project: otherProject,
    });
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:71",
      project,
      snapshot: snapshot(71, "A"),
    });
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:72",
      project: otherProject,
      snapshot: snapshot(72, "B"),
    });
    trace.dispatch({ type: "clear", editorId: "task:71" });
    trace.dispatch({ type: "clear", editorId: "task:72" });
    expect(tombstonedTids(trace.state)).toEqual([71, 72]);

    trace.dispatch({ type: "task-deleted", editorId: "task:71", tid: 71 });
    expect(tombstonedTids(trace.state)).toEqual([72]);
    expect(trace.state.newTaskByProject).toEqual({
      [projectKey]: a,
      [createProjectKey(otherProject.workspace, otherProject.projectPath)]: b,
    });
    expect(
      trace.dispatch({
        type: "task-observed",
        editorId: "task:72",
        observation: { tid: 72, isProcessing: true },
      }),
    ).toEqual([]);
    expect(tombstonedTids(trace.state)).toEqual([]);
    expect(trace.state.editors["task:72"]).toBeUndefined();
  });

  it("drops an externally deleted editor and leaves its sibling's save intact", () => {
    const trace = editorTrace();
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:71",
      project,
      snapshot: snapshot(71, "A"),
    });
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:72",
      project,
      snapshot: snapshot(72, "B"),
    });
    trace.dispatch({
      type: "edit-text",
      editorId: "task:71",
      text: "unsaved A",
    });
    trace.dispatch({
      type: "edit-text",
      editorId: "task:72",
      text: "unsaved B",
    });
    const { formVersion } = getEditor(trace.state, "task:71");
    expect(
      trace.dispatch({ type: "task-deleted", editorId: "task:71", tid: 71 }),
    ).toEqual([
      { type: "cancel-draft-save", editorId: "task:71", tid: 71, formVersion },
    ]);
    expect(trace.state.editors["task:71"]).toBeUndefined();
    const bVersion = getEditor(trace.state, "task:72").formVersion;
    expect(
      trace.dispatch({
        type: "save-timer-due",
        editorId: "task:72",
        tid: 72,
        formVersion: bVersion,
      }),
    ).toEqual([
      {
        type: "set-draft",
        editorId: "task:72",
        tid: 72,
        formVersion: bVersion,
        text: "unsaved B",
      },
    ]);
  });

  it("rejects duplicate identities and acknowledgements for another editor", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({ type: "edit-text", editorId: a, text: "A" });
    trace.dispatch({
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    });
    const inFlight = trace.state;
    expect(() =>
      trace.dispatch({
        type: "attach-new-task",
        editorId: a,
        project: { ...project, workspace: "other" },
      }),
    ).toThrow("Duplicate draft editor");
    expect(() =>
      trace.dispatch({
        type: "open-persisted",
        editorId: "task:72",
        project,
        snapshot: snapshot(71, "A"),
      }),
    ).toThrow("must match the task ID");
    expect(() =>
      trace.dispatch({
        type: "task-created",
        editorId: a,
        correlationId: uuidB,
        tid: 71,
        successor: b,
      }),
    ).toThrow("does not match the editor");
    expect(trace.state).toBe(inFlight);
    trace.dispatch({
      type: "task-created",
      editorId: a,
      correlationId: uuidA,
      tid: 71,
      successor: b,
    });
    expect(() =>
      trace.dispatch({
        type: "open-persisted",
        editorId: "task:71",
        project,
        snapshot: snapshot(71, "A"),
      }),
    ).toThrow();
  });

  it("delivers an in-flight create submission once on the matching acknowledgement", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({
      type: "edit-text",
      editorId: a,
      text: "send after create",
    });
    trace.dispatch({
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    });
    expect(trace.dispatch({ type: "submit", editorId: a, images: [] })).toEqual(
      [],
    );
    expect(getEditor(trace.state, a).desired).toMatchObject({
      kind: "submitting",
      text: "send after create",
      ...defaults,
      attempt: {
        delivery: "send-when-present",
        phase: "waiting-for-tid",
        createCorrelationId: uuidA,
      },
    });
    const effects = trace.dispatch({
      type: "task-created",
      editorId: a,
      correlationId: uuidA,
      messageCorrelationId: "first-message",
      tid: 71,
      successor: b,
    });
    expect(effects).toEqual([
      expect.objectContaining({
        type: "send-first-message",
        editorId: a,
        tid: 71,
        content: { text: "send after create", images: [] },
      }),
    ]);
    const frozen = getEditor(trace.state, a).desired;
    expect(frozen).toMatchObject({
      kind: "submitting",
      text: "send after create",
      attempt: {
        delivery: "send-when-present",
        phase: "awaiting-acceptance",
        messageCorrelationId: "first-message",
      },
    });
    for (const observation of [
      { status: "active" },
      { hasMessages: true },
      { isProcessing: true, text: "" },
    ] as const) {
      expect(
        trace.dispatch({
          type: "task-observed",
          editorId: a,
          observation: { tid: 71, ...observation },
        }),
      ).toEqual([]);
      expect(getEditor(trace.state, a).desired).toEqual(frozen);
    }
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
    trace.dispatch({ type: "submission-accepted", editorId: a, tid: 71 });
    expect(trace.state.editors[a]).toBeUndefined();
  });

  it.each(["atomic", "waiting-for-tid"] as const)(
    "returns a rejected %s submission to the same root without issuing a create",
    (delivery) => {
      const trace = editorTrace();
      trace.dispatch(metadata);
      trace.dispatch({ type: "attach-new-task", editorId: a, project });
      trace.dispatch({ type: "edit-text", editorId: a, text: "retry this" });
      if (delivery === "waiting-for-tid") {
        trace.dispatch({
          type: "create-timer-due",
          editorId: a,
          correlationId: uuidA,
        });
      }
      const submit = { type: "submit", editorId: a, images: [] } as const;
      trace.dispatch(submit);

      expect(
        trace.dispatch({ type: "submission-rejected", editorId: a }),
      ).toEqual([]);
      expect(trace.state.newTaskByProject[projectKey]).toBe(a);
      expect(getEditor(trace.state, a)).toMatchObject({
        remote: { kind: "absent" },
        desired: { kind: "editing", text: "retry this", ...defaults },
      });
      expect(trace.dispatch(submit)).toEqual([
        expect.objectContaining({
          type: "create-task",
          correlationId: uuidA,
          content: { text: "retry this", images: [] },
        }),
      ]);
    },
  );

  it("does not clear or release a present submission and preserves its form for a new nonce after rejection", () => {
    const trace = editorTrace();
    const editorId = "task:71";
    trace.dispatch(metadata);
    trace.dispatch({
      type: "open-persisted",
      editorId,
      project,
      snapshot: snapshot(71, "send this"),
    });
    const submit = { type: "submit", editorId, images: [] } as const;
    expect(
      trace.dispatch({ ...submit, messageCorrelationId: "first" }),
    ).toEqual([
      expect.objectContaining({
        type: "send-first-message",
        editorId,
        tid: 71,
      }),
    ]);
    trace.dispatch({ type: "submission-rejected", editorId, tid: 71 });
    expect(getEditor(trace.state, editorId)).toMatchObject({
      remote: { kind: "present", tid: 71, status: "pending" },
      desired: { kind: "editing", text: "send this", ...defaults },
    });
    trace.dispatch({ ...submit, messageCorrelationId: "retry" });
    expect(getEditor(trace.state, editorId).desired).toMatchObject({
      attempt: {
        delivery: "send-when-present",
        phase: "awaiting-acceptance",
        messageCorrelationId: "retry",
      },
    });
  });

  it("drops open, creating, and tombstoned editors and the project pointer on reset", () => {
    const trace = editorTrace();
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:71",
      project,
      snapshot: snapshot(71, "A"),
    });
    trace.dispatch({ type: "clear", editorId: "task:71" });
    trace.dispatch({
      type: "open-persisted",
      editorId: "task:72",
      project,
      snapshot: snapshot(72, "B"),
    });
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: a, project });
    trace.dispatch({ type: "edit-text", editorId: a, text: "in flight" });
    trace.dispatch({
      type: "create-timer-due",
      editorId: a,
      correlationId: uuidA,
    });
    expect(trace.dispatch({ type: "connection-reset" })).toEqual([]);
    expect(trace.state).toEqual(createDraftState());
    expect(tombstonedTids(trace.state)).toEqual([]);
    trace.dispatch(metadata);
    trace.dispatch({ type: "attach-new-task", editorId: b, project });
    expect(trace.state.newTaskByProject[projectKey]).toBe(b);
    expect(getEditor(trace.state, b).desired).toMatchObject({ text: "" });
  });
});

describe("draft reducer validation and full observations", () => {
  const id = "task:71";
  const open = {
    type: "open-persisted",
    editorId: id,
    project,
    snapshot: snapshot(71, "original"),
  } as const;
  const attach = {
    type: "attach-new-task",
    editorId: a,
    project,
  } as const;

  function reject(
    trace: ReturnType<typeof editorTrace>,
    event: DraftEvent | ProjectMetadataFixture,
    message: string,
  ) {
    const before = trace.state;
    expect(() => trace.dispatch(event)).toThrow(message);
    expect(trace.state).toBe(before);
  }

  it("advances the baseline across consecutive full snapshots even while a field diverges", () => {
    const trace = editorTrace();
    trace.dispatch(open);
    trace.dispatch({ type: "edit-text", editorId: id, text: "local" });
    trace.dispatch({
      type: "task-observed",
      editorId: id,
      observation: {
        tid: 71,
        text: "peer-1",
        entryPoint: "peer-entry-1",
        agent: "peer-agent-1",
      },
    });
    expect(getEditor(trace.state, id)).toMatchObject({
      observed: {
        text: "peer-1",
        entryPoint: "peer-entry-1",
        agent: "peer-agent-1",
      },
      desired: {
        text: "local",
        entryPoint: "peer-entry-1",
        agent: "peer-agent-1",
      },
    });
    trace.dispatch({ type: "edit-text", editorId: id, text: "peer-1" });
    trace.dispatch({
      type: "task-observed",
      editorId: id,
      observation: {
        tid: 71,
        text: "peer-2",
        entryPoint: "peer-entry-2",
        agent: "peer-agent-2",
      },
    });
    const expected = {
      text: "peer-2",
      entryPoint: "peer-entry-2",
      agent: "peer-agent-2",
    };
    expect(getEditor(trace.state, id)).toMatchObject({
      desired: expected,
      observed: expected,
    });
  });

  it("distinguishes omitted and explicitly empty form fields", () => {
    const trace = editorTrace();
    trace.dispatch(open);
    trace.dispatch({
      type: "task-observed",
      editorId: id,
      observation: Object.assign(
        Object.create({ text: "inherited", agent: "inherited" }) as object,
        { tid: 71, entryPoint: "" },
      ),
    });
    expect(getEditor(trace.state, id)).toMatchObject({
      desired: { text: "original", agent: "agent", entryPoint: "" },
      observed: { text: "original", agent: "agent", entryPoint: "" },
    });
    trace.dispatch({
      type: "task-observed",
      editorId: id,
      observation: { tid: 71, text: "", agent: "" },
    });
    expect(getEditor(trace.state, id)).toMatchObject({
      desired: { text: "", agent: "", entryPoint: "" },
      observed: { text: "", agent: "", entryPoint: "" },
    });
  });

  it.each([0, -1, 1.5, 2147483648, NaN, "71"])(
    "rejects malformed tid %s",
    (tid) => {
      const trace = editorTrace();
      reject(
        trace,
        { ...open, snapshot: { ...open.snapshot, tid } as TaskSnapshot },
        "positive signed 32-bit integer",
      );
      trace.dispatch(metadata);
      trace.dispatch(attach);
      trace.dispatch({ type: "edit-text", editorId: a, text: "prompt" });
      trace.dispatch({
        type: "create-timer-due",
        editorId: a,
        correlationId: uuidA,
      });
      reject(
        trace,
        {
          type: "task-created",
          editorId: a,
          correlationId: uuidA,
          tid: tid as number,
          successor: b,
        },
        "positive signed 32-bit integer",
      );
    },
  );

  it.each(["task:70", "composition:", "composition:  "])(
    "rejects malformed composition identity %s",
    (editorId) => {
      reject(
        editorTrace(),
        { ...attach, editorId: editorId as typeof a },
        "requires a browser UUID",
      );
    },
  );

  it.each(Object.keys(open.snapshot) as (keyof TaskSnapshot)[])(
    "rejects inherited persisted field %s",
    (field) => {
      const { [field]: inherited, ...own } = open.snapshot;
      const incomplete = Object.assign(
        Object.create({ [field]: inherited }) as Partial<TaskSnapshot>,
        own,
      );
      reject(
        editorTrace(),
        { ...open, snapshot: incomplete as TaskSnapshot },
        "snapshot must be complete",
      );
    },
  );

  it.each([
    "text",
    "entryPoint",
    "agent",
    "active",
    "processing",
    "hasMessages",
  ] as const)("rejects malformed persisted field %s", (field) => {
    reject(
      editorTrace(),
      { ...open, snapshot: { ...open.snapshot, [field]: undefined } },
      "snapshot must be complete",
    );
  });

  it.each([undefined, null, "snapshot"])(
    "rejects non-record persisted snapshot %s",
    (value) => {
      reject(
        editorTrace(),
        { ...open, snapshot: value as unknown as TaskSnapshot },
        "snapshot must be complete",
      );
    },
  );

  it.each(["active", "processing", "hasMessages"] as const)(
    "rejects a persisted snapshot with %s",
    (field) => {
      reject(
        editorTrace(),
        { ...open, snapshot: { ...open.snapshot, [field]: true } },
        "Only a pending task",
      );
    },
  );

  it("rejects an all-whitespace persisted draft", () => {
    reject(
      editorTrace(),
      { ...open, snapshot: snapshot(71, "  ") },
      "must have non-empty text",
    );
  });

  it.each([
    "text",
    "oldText",
    "entryPoint",
    "agent",
    "status",
    "isProcessing",
    "hasMessages",
  ] as const)(
    "rejects malformed observation field %s before applying an active fact",
    (field) => {
      const trace = editorTrace();
      trace.dispatch(open);
      reject(
        trace,
        {
          type: "task-observed",
          editorId: id,
          observation: { tid: 71, status: "active", [field]: null },
        },
        `Observed ${["status", "isProcessing", "hasMessages"].includes(field) ? "activity" : "form"} field ${field}`,
      );
    },
  );

  it.each(["status", "isProcessing", "hasMessages"] as const)(
    "ignores inherited activity flag %s",
    (field) => {
      const trace = editorTrace();
      trace.dispatch(open);
      const before = trace.state;
      trace.dispatch({
        type: "task-observed",
        editorId: id,
        observation: Object.assign(
          Object.create({
            [field]: field === "status" ? "active" : true,
          }) as object,
          {
            tid: 71,
          },
        ),
      });
      expect(trace.state).toBe(before);
    },
  );

  it("rejects invalid delete and observation routing while retaining the owner and tombstone", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch(attach);
    trace.dispatch(open);
    for (const editorId of [a, id] as const) {
      reject(
        trace,
        { type: "task-deleted", editorId, tid: 72 },
        "Deletion acknowledgement does not match",
      );
      reject(
        trace,
        { type: "task-observed", editorId, observation: { tid: 72 } },
        "Observation does not match",
      );
    }
    trace.dispatch({ type: "clear", editorId: id });
    reject(
      trace,
      { type: "task-deleted", editorId: id, tid: 72 },
      "Deletion acknowledgement does not match",
    );
    reject(
      trace,
      { type: "task-observed", editorId: id, observation: { tid: 71 } },
      "Only a present task",
    );
    expect(tombstonedTids(trace.state)).toEqual([71]);
  });

  it("rejects an unknown editor, duplicate root, bad project, and missing successor", () => {
    const trace = editorTrace();
    reject(trace, { type: "flush", editorId: a }, "Unknown draft editor");
    expect(() => createProjectKey("bad\0workspace", "/ok")).toThrow(
      "cannot contain NUL",
    );
    expect(() => createProjectKey("good", "/bad\0path")).toThrow(
      "cannot contain NUL",
    );
    trace.dispatch(metadata);
    trace.dispatch(attach);
    reject(trace, { ...attach, editorId: b }, "already has a New Task editor");
    trace.dispatch({ type: "edit-text", editorId: a, text: "prompt" });
    reject(
      trace,
      { type: "clear", editorId: a },
      "requires the current editor and a successor",
    );
    const invalidPointer: DraftState = { ...trace.state, newTaskByProject: {} };
    reject(
      editorTrace(invalidPointer),
      { type: "clear", editorId: a, successor: b },
      "requires the current editor and a successor",
    );
  });

  it("rejects empty, unresolved, and repeated submission, and form edits during submission", () => {
    const trace = editorTrace();
    trace.dispatch({
      ...metadata,
      metadata: { catalog: ["entry", "other"], defaults },
    });
    trace.dispatch(attach);
    const submit = { type: "submit", editorId: a, images: [] } as const;
    reject(trace, submit, "Cannot submit an empty draft");
    expect(() => {
      assertResolvedDraftForm({
        text: "prompt",
        entryPoint: null,
        agent: "agent",
      });
    }).toThrow("resolved entry point");
    expect(() => {
      assertResolvedDraftForm({
        text: "prompt",
        entryPoint: "entry",
        agent: null,
      });
    }).toThrow("resolved agent");
    trace.dispatch({ type: "edit-text", editorId: a, text: "prompt" });
    trace.dispatch(submit);
    reject(trace, submit, "Only an editing draft can be submitted");
    reject(
      trace,
      { type: "edit-text", editorId: a, text: "other" },
      "Only an editing draft can change text",
    );
    reject(
      trace,
      { type: "clear", editorId: a },
      "A submitting draft cannot be cleared",
    );
    reject(
      trace,
      { type: "change-entry-point", editorId: a, entryPoint: "other" },
      "cannot change entry point",
    );
    reject(
      trace,
      { type: "change-agent", editorId: a, agent: "other" },
      "cannot change agent",
    );
  });

  it("ignores stale create and save callbacks with different identities", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch(attach);
    trace.dispatch({ type: "edit-text", editorId: a, text: "waiting" });
    const scheduled = trace.state;
    expect(
      trace.dispatch({
        type: "create-timer-due",
        editorId: a,
        correlationId: uuidB,
      }),
    ).toEqual([]);
    expect(trace.state).toBe(scheduled);

    trace.dispatch(open);
    const idle = trace.state;
    expect(
      trace.dispatch({
        type: "save-timer-due",
        editorId: id,
        tid: 71,
        formVersion: 0,
      }),
    ).toEqual([]);
    expect(trace.state).toBe(idle);
    trace.dispatch({ type: "edit-text", editorId: id, text: "unsaved" });
    const pending = trace.state;
    const { formVersion } = getEditor(pending, id);
    for (const invalid of [
      { tid: 72, formVersion },
      { tid: 71, formVersion: formVersion - 1 },
    ]) {
      expect(
        trace.dispatch({ type: "save-timer-due", editorId: id, ...invalid }),
      ).toEqual([]);
      expect(trace.state).toBe(pending);
    }
  });

  it("rejects an unexpected event type before touching state", () => {
    reject(
      editorTrace(),
      { type: "bogus" } as unknown as DraftEvent,
      "Unexpected value",
    );
  });

  it("fails fast for inconsistent internal submission and observation states", () => {
    const trace = editorTrace();
    trace.dispatch(metadata);
    trace.dispatch(attach);
    trace.dispatch({ type: "edit-text", editorId: a, text: "prompt" });
    trace.dispatch({ type: "submit", editorId: a, images: [] });
    const current = getEditor(trace.state, a);
    if (current.desired.kind !== "submitting")
      throw new Error("Expected submitting editor");
    const corrupt = (editor: typeof current) =>
      editorTrace({
        ...trace.state,
        metadata: { ...trace.state.metadata, projects: new Map() },
        editors: { [a]: { ...editor, defaults: { ...defaults, agent: null } } },
      });
    const restoreDefaults = {
      type: "workspace-draft-defaults",
      projects: [{ project, ...defaults }],
    } as const;
    reject(
      corrupt({
        ...current,
        remote: { kind: "absent" },
        desired: {
          ...current.desired,
          attempt: {
            delivery: "send-when-present",
            phase: "waiting-for-tid",
            createCorrelationId: uuidA,
          },
        },
      }),
      restoreDefaults,
      "Submitting editor must have an in-flight or bound task",
    );
    reject(
      trace,
      { type: "submission-accepted", editorId: a, tid: 71 },
      "Acceptance does not match a bound submission",
    );
    reject(
      corrupt({
        ...current,
        remote: { kind: "present", tid: 71, status: "pending" },
      }),
      { type: "task-observed", editorId: a, observation: { tid: 72 } },
      "does not match",
    );
  });
});

describe("project metadata and ownership handoff", () => {
  const id = "task:71";
  const attach = { type: "attach-new-task", project, editorId: a } as const;
  const known = {
    ...metadata,
    metadata: { catalog: ["entry"], defaults },
  } as const;
  const rejected = {
    ...metadata,
    metadata: {
      catalog: ["other"],
      defaults: { ...defaults, entryPoint: "other" },
    },
  } as const;
  const open = {
    type: "open-persisted",
    project,
    editorId: id,
    snapshot: { ...snapshot(71, "server"), agent: null },
  } as const;
  const edit = { type: "edit-text", editorId: id, text: "local edit" } as const;

  it.each([
    ["open", "catalog", "edit"],
    ["open", "edit", "catalog"],
    ["catalog", "open", "edit"],
    ["catalog", "edit", "open"],
    ["edit", "open", "catalog"],
    ["edit", "catalog", "open"],
  ] as const)("converges on a legacy agent after %s, %s, %s", (...order) => {
    const trace = editorTrace();
    const events = { open, catalog: known, edit };
    const effects: DraftEffect[] = [];
    let editBeforeOpen = false;
    for (const name of order) {
      if (name === "edit" && !trace.state.editors[id]) {
        expect(() => trace.dispatch(edit)).toThrow("Unknown draft editor");
        editBeforeOpen = true;
        continue;
      }
      effects.push(...trace.dispatch(events[name]));
      if (name === "open" && editBeforeOpen)
        effects.push(...trace.dispatch(edit));
    }
    expect(getEditor(trace.state, id)).toMatchObject({
      desired: { text: "local edit", ...defaults },
      observed: { text: "server", ...defaults },
      defaults,
    });
    expect(editorMetadataReady(trace.state, id)).toBe(true);
    // A pre-catalog projection may carry a null agent, but it must schedule
    // the same write and emit no picker or create RPC in any order.
    expect(effects.filter(({ type }) => type !== "project-draft")).toEqual([
      expect.objectContaining({
        type: "ensure-draft-save",
        editorId: id,
        tid: 71,
      }),
    ]);
  });

  it.each(["untouched", "pending", "saved"] as const)(
    "keeps the %s editor across a catalog drop on either side of a stale snapshot",
    (variant) => {
      for (const observeFirst of [true, false]) {
        const trace = editorTrace();
        trace.dispatch(known);
        trace.dispatch(open);
        if (variant !== "untouched") trace.dispatch(edit);
        if (variant === "saved") {
          const { formVersion } = getEditor(trace.state, id);
          trace.dispatch({
            type: "save-timer-due",
            editorId: id,
            tid: 71,
            formVersion,
          });
        }
        const initial = getEditor(trace.state, id);
        const stale = {
          type: "task-observed",
          editorId: id,
          observation: { tid: 71, text: "server" },
        } as const;
        if (observeFirst) trace.dispatch(stale);
        expect(trace.dispatch(rejected)).toEqual([]);
        if (!observeFirst) trace.dispatch(stale);
        expect(getEditor(trace.state, id)).toEqual(initial);
        expect(editorSubmittable(trace.state, id)).toBe(false);
      }
    },
  );

  const orders = (items: readonly string[]): string[][] =>
    items.length === 0
      ? [[]]
      : items.flatMap((first) =>
          orders(items.filter((other) => other !== first)).map((rest) => [
            first,
            ...rest,
          ]),
        );

  it.each(
    orders(["open", "drop", "restore", "snapshot"]).map((order) => ({
      order: order.join(","),
    })),
  )(
    "keeps ownership, baseline and the pending save across $order",
    ({ order }) => {
      const trace = editorTrace();
      const catalog = (name: string): DraftEvent => ({
        type: "project-catalog",
        projectPath: project.projectPath,
        catalog: [
          {
            name,
            task_type: name,
            description: "",
            model_class: "",
            read_only: false,
          },
        ],
      });
      trace.dispatch({
        type: "workspace-draft-defaults",
        projects: [{ project, ...defaults }],
      });
      let listsEntry = false;
      for (const step of order.split(",")) {
        switch (step) {
          case "open":
            trace.dispatch(open);
            trace.dispatch(edit);
            break;
          case "drop":
          case "restore":
            listsEntry = step === "restore";
            expect(
              trace.dispatch(catalog(listsEntry ? "entry" : "other")),
            ).toEqual([]);
            break;
          case "snapshot":
            if (trace.state.editors[id])
              trace.dispatch({
                type: "task-observed",
                editorId: id,
                observation: { tid: 71, text: "server" },
              });
            break;
        }
        if (trace.state.editors[id]) {
          expect(getEditor(trace.state, id)).toMatchObject({
            desired: { text: "local edit", entryPoint: "entry" },
            observed: { text: "server", entryPoint: "entry" },
            saveSchedule: { tid: 71, formVersion: 1 },
          });
          expect(editorSubmittable(trace.state, id)).toBe(listsEntry);
        }
      }
    },
  );

  it("resolves a detached composition independently of the current project's editor", () => {
    const trace = editorTrace();
    trace.dispatch(attach);
    trace.dispatch({ ...edit, editorId: a });
    trace.dispatch({
      ...attach,
      editorId: b,
      project: { ...project, projectPath: "/other" },
    });
    trace.dispatch({ ...edit, editorId: b });
    expect(trace.dispatch(known)).toEqual([
      expect.objectContaining({
        type: "schedule-create",
        editorId: a,
        correlationId: uuidA,
      }),
    ]);
    expect(getEditor(trace.state, a).desired).toMatchObject({
      text: "local edit",
      ...defaults,
    });
    expect(getEditor(trace.state, b).defaults).toEqual({
      entryPoint: null,
      agent: null,
    });
  });

  it("resolves a successor minted before metadata and keeps predecessor defaults thereafter", () => {
    const trace = editorTrace();
    trace.dispatch(attach);
    trace.dispatch({ ...edit, editorId: a });
    trace.dispatch({ type: "clear", editorId: a, successor: b });
    expect(getEditor(trace.state, b).defaults).toEqual({
      entryPoint: null,
      agent: null,
    });
    expect(trace.dispatch(known)).toEqual([]);
    expect(getEditor(trace.state, b).defaults).toEqual(defaults);
    trace.dispatch({ type: "change-agent", editorId: b, agent: "selected" });
    trace.dispatch({ ...edit, editorId: b });
    trace.dispatch({ type: "clear", editorId: b, successor: c });
    expect(getEditor(trace.state, c).desired).toMatchObject({
      text: "",
      entryPoint: "entry",
      agent: "selected",
    });
  });

  it("updates the existing save when an observation merges an unlisted entry point and text", () => {
    const trace = editorTrace();
    trace.dispatch(known);
    trace.dispatch(open);
    trace.dispatch(edit);
    trace.dispatch({ ...edit, text: "server" });
    const { formVersion } = getEditor(trace.state, id);
    expect(
      trace.dispatch({
        type: "task-observed",
        editorId: id,
        observation: {
          tid: 71,
          entryPoint: "unavailable",
          text: "merged server",
        },
      }),
    ).toEqual([
      expect.objectContaining({ type: "project-draft", editorId: id, tid: 71 }),
      expect.objectContaining({
        type: "ensure-draft-save",
        editorId: id,
        tid: 71,
        formVersion: formVersion + 1,
      }),
    ]);
    expect(getEditor(trace.state, id).desired).toMatchObject({
      text: "merged server",
      entryPoint: "unavailable",
    });
    expect(editorSubmittable(trace.state, id)).toBe(false);
  });

  it("rejects picker and submit intents with an unknown or unlisting catalog", () => {
    const trace = editorTrace();
    trace.dispatch(open);
    for (const catalog of [null, rejected]) {
      if (catalog) trace.dispatch(catalog);
      const state = trace.state;
      expect(() =>
        trace.dispatch({
          type: "change-entry-point",
          editorId: id,
          entryPoint: "entry",
        }),
      ).toThrow("Unknown entry point: entry");
      expect(() =>
        trace.dispatch({ type: "submit", editorId: id, images: [] }),
      ).toThrow("Draft metadata does not allow submission");
      expect(trace.state).toBe(state);
    }
    trace.dispatch({
      type: "change-entry-point",
      editorId: id,
      entryPoint: "other",
    });
    expect(editorSubmittable(trace.state, id)).toBe(true);
  });

  it("updates the roster and default together, preserves equal input, and clears both on reset", () => {
    const trace = editorTrace();
    trace.dispatch(known);
    trace.dispatch({
      type: "workspace-draft-defaults",
      projects: [{ project, entryPoint: defaults.entryPoint, agent: null }],
    });
    trace.dispatch(open);
    expect(getEditor(trace.state, id).defaults.agent).toBeNull();
    const first = {
      type: "agents-list",
      agents: [{ name: "agent", driver: "claude" }],
      defaultAgent: "agent",
    } as const;
    expect(trace.dispatch(first)).toEqual([]);
    expect(getEditor(trace.state, id).defaults.agent).toBe("agent");
    expect(trace.state.metadata.agents).toEqual(first.agents);
    const before = trace.state;
    expect(
      trace.dispatch({
        ...first,
        agents: first.agents.map((agent) => ({ ...agent })),
      }),
    ).toEqual([]);
    expect(trace.state).toBe(before);
    expect(
      trace.dispatch({
        ...first,
        agents: [...first.agents, { name: "other", driver: "codex" }],
      }),
    ).toEqual([]);
    expect(trace.state).not.toBe(before);
    expect(trace.state.editors).toBe(before.editors);
    expect(trace.dispatch({ type: "connection-reset" })).toEqual([]);
    expect(trace.state.metadata.agents).toBeNull();
    expect(trace.state.metadata.agent).toBeNull();
  });

  it("leaves server text authoritative when another client activates a pending-edit task", () => {
    const trace = editorTrace();
    trace.dispatch(open);
    trace.dispatch(edit);
    const { formVersion } = getEditor(trace.state, id);
    expect(
      trace.dispatch({
        type: "task-observed",
        editorId: id,
        observation: { tid: 71, isProcessing: true },
      }),
    ).toEqual([
      { type: "cancel-draft-save", editorId: id, tid: 71, formVersion },
    ]);
    expect(trace.state.editors[id]).toBeUndefined();
  });

  it("rejects malformed metadata identities and non-null, non-string persisted agents", () => {
    const trace = editorTrace();
    const before = trace.state;
    expect(() =>
      trace.dispatch({
        type: "workspace-draft-defaults",
        projects: [
          { project: { ...project, workspace: "bad\0workspace" }, ...defaults },
        ],
      }),
    ).toThrow("cannot contain NUL");
    expect(() =>
      trace.dispatch({
        ...open,
        snapshot: { ...open.snapshot, agent: 1 as unknown as string },
      }),
    ).toThrow("snapshot must be complete");
    expect(trace.state).toBe(before);
  });
});
