import type { TaskStatus } from "./types";

export type ProjectKey = string;
export type DraftId = string;
export type CompositionId = `composition:${string}`;
export type EditorId = CompositionId | `task:${number}`;

export const CREATE_DELAY_MS = 16 as const;
export const DRAFT_SAVE_DELAY_MS = 500 as const;
const MAX_TASK_ID = 2_147_483_647;
const PERSISTED_SNAPSHOT_FIELDS = [
  "tid",
  "text",
  "entryPoint",
  "agent",
  "active",
  "processing",
  "hasMessages",
] as const;

export interface ProjectIdentity {
  workspace: string;
  projectPath: string;
}

export interface FormDefaults {
  entryPoint: string | null;
  agent: string | null;
}

export interface DraftForm extends FormDefaults {
  text: string;
}

export interface ResolvedDraftForm extends DraftForm {
  entryPoint: string;
  agent: string;
}

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

export interface DraftContent {
  text: string;
  images: readonly ImageAttachment[];
}

type SubmissionAttempt =
  | {
      delivery: "atomic-create";
      phase: "awaiting-acceptance";
      correlationId: DraftId;
    }
  | {
      delivery: "send-when-present";
      phase: "waiting-for-tid";
      createCorrelationId: DraftId;
    }
  | {
      delivery: "send-when-present";
      phase: "awaiting-acceptance";
      messageCorrelationId: string;
    };

export type Desired =
  | { kind: "none" }
  | ({ kind: "editing"; recovered?: true } & DraftForm)
  | ({
      kind: "submitting";
      images: readonly ImageAttachment[];
      attempt: SubmissionAttempt;
    } & DraftForm);

export type Remote =
  | { kind: "absent" }
  | { kind: "creating"; correlationId: DraftId }
  | { kind: "present"; tid: number; status: TaskStatus }
  | { kind: "deleting"; tid: number };

export interface SaveSchedule {
  tid: number;
  formVersion: number;
}

export interface EditorState {
  project: ProjectIdentity;
  defaults: FormDefaults;
  observed: DraftForm;
  desired: Desired;
  remote: Remote;
  formVersion: number;
  createSchedule: DraftId | null;
  saveSchedule: SaveSchedule | null;
}

export interface EntryPointInfo {
  name: string;
  task_type: string;
  description: string;
  model_class: string;
  model_classes?: Record<string, string>;
  read_only: boolean;
  icon?: string;
}

export interface ProjectDraftDefaults {
  project: ProjectIdentity;
  entryPoint: string | null;
  agent: string | null;
}

export interface AgentInfo {
  name: string;
  driver: string;
  display_name?: string;
  is_available?: boolean;
}

interface DraftMetadata {
  agents: readonly AgentInfo[] | null;
  catalogs: ReadonlyMap<string, readonly EntryPointInfo[]>;
  projects: ReadonlyMap<ProjectKey, ProjectDraftDefaults>;
  entryPoint: string | null;
  agent: string | null;
}

export interface DraftState {
  metadata: DraftMetadata;
  editors: Readonly<Record<EditorId, EditorState>>;
  newTaskByProject: Readonly<Record<ProjectKey, CompositionId>>;
}

export interface TaskSnapshot extends ResolvedDraftForm {
  tid: number;
  active: boolean;
  processing: boolean;
  hasMessages: boolean;
}

export type PersistedSnapshot = Omit<TaskSnapshot, "agent"> & {
  agent: string | null;
};
export type ProjectedDraftForm = DraftForm & { entryPoint: string };

export interface TaskObservation {
  tid: number;
  status?: TaskStatus;
  alive?: boolean;
  isProcessing?: boolean;
  hasMessages?: boolean;
  text?: string;
  oldText?: string;
  entryPoint?: string;
  agent?: string;
}

export type DraftEffect =
  | {
      type: "schedule-create";
      editorId: EditorId;
      correlationId: DraftId;
      delayMs: typeof CREATE_DELAY_MS;
    }
  | {
      type: "cancel-create-schedule";
      editorId: EditorId;
      correlationId: DraftId;
    }
  | {
      type: "create-task";
      editorId: EditorId;
      correlationId: DraftId;
      entryPoint: string;
      agent: string;
      content: DraftContent | null;
    }
  | {
      type: "ensure-draft-save";
      editorId: EditorId;
      tid: number;
      formVersion: number;
      delayMs: typeof DRAFT_SAVE_DELAY_MS;
    }
  | {
      type: "cancel-draft-save";
      editorId: EditorId;
      tid: number;
      formVersion: number;
    }
  | {
      type: "set-entry-point";
      editorId: EditorId;
      tid: number;
      entryPoint: string;
    }
  | {
      type: "set-agent";
      editorId: EditorId;
      tid: number;
      agent: string;
    }
  | {
      type: "set-draft";
      editorId: EditorId;
      tid: number;
      text: string;
      formVersion: number;
    }
  | {
      type: "project-draft";
      editorId: EditorId;
      tid: number;
      form: ProjectedDraftForm;
      formVersion: number;
    }
  | { type: "clear-task-draft"; editorId: EditorId; tid: number }
  | { type: "delete-task"; editorId: EditorId; tid: number }
  | {
      type: "send-first-message";
      editorId: EditorId;
      tid: number;
      messageCorrelationId: string;
      content: DraftContent;
    };

export type DraftEvent =
  | {
      type: "attach-new-task";
      editorId: CompositionId;
      project: ProjectIdentity;
    }
  | {
      type: "project-catalog";
      projectPath: string;
      catalog: readonly EntryPointInfo[];
    }
  | {
      type: "workspace-draft-defaults";
      projects: readonly ProjectDraftDefaults[];
    }
  | { type: "global-draft-defaults"; entryPoint?: string }
  | { type: "agents-list"; agents: readonly AgentInfo[]; defaultAgent: string }
  | {
      type: "edit-text";
      editorId: EditorId;
      text: string;
      successor?: CompositionId;
    }
  | { type: "clear"; editorId: EditorId; successor?: CompositionId }
  | {
      type: "change-entry-point";
      editorId: EditorId;
      entryPoint: string;
    }
  | { type: "change-agent"; editorId: EditorId; agent: string }
  | {
      type: "submit";
      editorId: EditorId;
      messageCorrelationId?: string;
      images: readonly ImageAttachment[];
    }
  | { type: "flush"; editorId: EditorId }
  | {
      type: "create-timer-due";
      editorId: EditorId;
      correlationId: DraftId;
    }
  | {
      type: "save-timer-due";
      editorId: EditorId;
      tid: number;
      formVersion: number;
    }
  | {
      type: "task-created";
      editorId: EditorId;
      messageCorrelationId?: string;
      correlationId: DraftId;
      tid: number;
      successor?: CompositionId;
    }
  | { type: "submission-accepted"; editorId: EditorId; tid: number }
  | { type: "submission-rejected"; editorId: EditorId; tid?: number }
  | { type: "task-deleted"; editorId: EditorId; tid: number }
  | {
      type: "task-observed";
      editorId: EditorId;
      observation: TaskObservation;
    }
  | {
      type: "open-persisted";
      editorId: EditorId;
      project: ProjectIdentity;
      snapshot: PersistedSnapshot;
    }
  | { type: "connection-reset" };

export interface DraftResult {
  state: DraftState;
  effects: readonly DraftEffect[];
}

export function createProjectKey(
  workspace: string,
  projectPath: string,
): ProjectKey {
  if (workspace.includes("\0") || projectPath.includes("\0")) {
    throw new Error("Canonical project identity cannot contain NUL");
  }
  return workspace + "\0" + projectPath;
}

export function createDraftState(): DraftState {
  return {
    editors: {},
    newTaskByProject: {},
    metadata: {
      agents: null,
      catalogs: new Map(),
      projects: new Map(),
      entryPoint: null,
      agent: null,
    },
  };
}

function createEditor(
  project: ProjectIdentity,
  defaults: FormDefaults,
): EditorState {
  return {
    project: { ...project },
    defaults: { ...defaults },
    observed: { text: "", ...defaults },
    desired: { kind: "editing", text: "", ...defaults },
    remote: { kind: "absent" },
    formVersion: 0,
    createSchedule: null,
    saveSchedule: null,
  };
}

export function getEditor(state: DraftState, editorId: EditorId): EditorState {
  const editor = state.editors[editorId];
  if (!editor) throw new Error("Unknown draft editor: " + editorId);
  return editor;
}

export function tombstonedTids(state: DraftState): readonly number[] {
  return Object.values(state.editors)
    .flatMap((editor) =>
      editor.remote.kind === "deleting" ? [editor.remote.tid] : [],
    )
    .sort((left, right) => left - right);
}

export function isTombstoned(state: DraftState, tid: number): boolean {
  return tombstonedTids(state).includes(tid);
}

export function reduceDraft(state: DraftState, event: DraftEvent): DraftResult {
  switch (event.type) {
    case "attach-new-task":
      return attachNewTask(state, event);
    case "project-catalog": {
      const previous = state.metadata.catalogs.get(event.projectPath);
      if (JSON.stringify(previous) === JSON.stringify(event.catalog))
        return { state, effects: [] };
      const catalogs = new Map(state.metadata.catalogs).set(
        event.projectPath,
        event.catalog,
      );
      return updateDraftMetadata(state, { ...state.metadata, catalogs });
    }
    case "workspace-draft-defaults": {
      const projects = new Map(
        event.projects.map((defaults) => [
          projectKeyOf(defaults.project),
          defaults,
        ]),
      );
      if (
        JSON.stringify([...projects]) ===
        JSON.stringify([...state.metadata.projects])
      )
        return { state, effects: [] };
      return updateDraftMetadata(state, { ...state.metadata, projects });
    }
    case "global-draft-defaults": {
      const entryPoint = event.entryPoint ?? state.metadata.entryPoint;
      if (entryPoint === state.metadata.entryPoint)
        return { state, effects: [] };
      return updateDraftMetadata(state, { ...state.metadata, entryPoint });
    }
    case "agents-list": {
      const { agents, defaultAgent: agent } = event;
      if (
        agent === state.metadata.agent &&
        JSON.stringify(agents) === JSON.stringify(state.metadata.agents)
      )
        return { state, effects: [] };
      return updateDraftMetadata(state, { ...state.metadata, agents, agent });
    }
    case "edit-text":
      return editText(state, event);
    case "clear":
      return clearEditor(state, event.editorId, event.successor);
    case "change-entry-point":
      return changeEntryPoint(state, event.editorId, event.entryPoint);
    case "change-agent":
      return changeAgent(state, event.editorId, event.agent);
    case "submit":
      return submit(state, event);
    case "flush":
      return flush(state, event.editorId);
    case "create-timer-due":
      return createTimerDue(state, event);
    case "save-timer-due":
      return saveTimerDue(state, event);
    case "task-created":
      return taskCreated(state, event);
    case "task-deleted":
      return taskDeleted(state, event);
    case "submission-accepted": {
      const current = getEditor(state, event.editorId);
      if (
        current.desired.kind !== "submitting" ||
        current.desired.attempt.phase !== "awaiting-acceptance" ||
        current.remote.kind !== "present" ||
        current.remote.tid !== event.tid
      ) {
        throw new Error("Acceptance does not match a bound submission");
      }
      return { state: removeEditor(state, event.editorId), effects: [] };
    }

    case "submission-rejected":
      return rejectSubmission(state, event);

    case "task-observed":
      return taskObserved(state, event);
    case "open-persisted":
      return openPersisted(state, event);
    case "connection-reset":
      return { state: createDraftState(), effects: [] };
    default:
      return assertNever(event);
  }
}

export function assertNever(value: never): never {
  throw new Error("Unexpected value: " + JSON.stringify(value));
}

export function assertResolvedDraftForm<T extends DraftForm>(
  form: T,
): asserts form is T & ResolvedDraftForm {
  if (form.entryPoint === null) {
    throw new Error("Draft create/sync requires a resolved entry point");
  }
  if (form.agent === null) {
    throw new Error("Draft create/sync requires a resolved agent");
  }
}

function projectKeyOf(project: ProjectIdentity): ProjectKey {
  return createProjectKey(project.workspace, project.projectPath);
}

export function projectDraftDefaults(
  state: DraftState,
  project: ProjectIdentity,
): Omit<ResolvedDraftForm, "text"> | null {
  const policy = state.metadata.projects.get(projectKeyOf(project));
  const catalog = state.metadata.catalogs.get(project.projectPath);
  if (!policy || !catalog) return null;
  const preference = policy.entryPoint ?? state.metadata.entryPoint;
  const agent = policy.agent ?? state.metadata.agent;
  if (preference === null || agent === null) return null;
  const entryPoint =
    catalog.find(
      (candidate) =>
        candidate.name === preference || candidate.task_type === preference,
    ) ?? catalog[0];
  return entryPoint ? { entryPoint: entryPoint.name, agent } : null;
}

function catalogLists(
  state: DraftState,
  project: ProjectIdentity,
  entryPoint: string | null,
): boolean {
  const catalog = state.metadata.catalogs.get(project.projectPath);
  return catalog?.some((candidate) => candidate.name === entryPoint) ?? false;
}

export function editorMetadataReady(
  state: DraftState,
  editorId: EditorId,
): boolean {
  const editor = getEditor(state, editorId);
  return (
    projectDraftDefaults(state, editor.project) !== null &&
    editor.desired.kind !== "none" &&
    editor.desired.entryPoint !== null &&
    editor.desired.agent !== null
  );
}

export function editorSubmittable(
  state: DraftState,
  editorId: EditorId,
): boolean {
  const editor = getEditor(state, editorId);
  return (
    editor.desired.kind !== "none" &&
    editorMetadataReady(state, editorId) &&
    catalogLists(state, editor.project, editor.desired.entryPoint)
  );
}

function updateDraftMetadata(
  state: DraftState,
  metadata: DraftMetadata,
): DraftResult {
  let next = { ...state, metadata };
  const effects: DraftEffect[] = [];
  for (const id of (Object.keys(state.editors) as EditorId[]).sort()) {
    const project = getEditor(next, id).project;
    const resolved = resolveEditorDefaults(
      next,
      id,
      projectDraftDefaults(next, project),
    );
    next = resolved.state;
    effects.push(...resolved.effects);
  }
  return { state: next, effects };
}

function attachNewTask(
  state: DraftState,
  { project, editorId }: Extract<DraftEvent, { type: "attach-new-task" }>,
): DraftResult {
  const projectKey = createProjectKey(project.workspace, project.projectPath);
  if (state.newTaskByProject[projectKey] !== undefined) {
    throw new Error("Project already has a New Task editor");
  }
  compositionCorrelation(editorId);
  const defaults = projectDraftDefaults(state, project) ?? {
    entryPoint: null,
    agent: null,
  };
  return {
    state: {
      ...insertEditor(state, editorId, createEditor(project, defaults)),
      newTaskByProject: { ...state.newTaskByProject, [projectKey]: editorId },
    },
    effects: [],
  };
}

function replaceNewTask(
  state: DraftState,
  editorId: EditorId,
  successor: CompositionId | undefined,
): DraftState {
  const editor = getEditor(state, editorId);
  const projectKey = createProjectKey(
    editor.project.workspace,
    editor.project.projectPath,
  );
  if (
    state.newTaskByProject[projectKey] !== editorId ||
    successor === undefined
  ) {
    throw new Error(
      "Replacing New Task requires the current editor and a successor",
    );
  }
  compositionCorrelation(successor);
  const next = {
    ...insertEditor(
      state,
      successor,
      createEditor(editor.project, editor.defaults),
    ),
    newTaskByProject: { ...state.newTaskByProject, [projectKey]: successor },
  };
  return resolveEditorDefaults(
    next,
    successor,
    projectDraftDefaults(state, editor.project),
  ).state;
}

function resolveEditorDefaults(
  state: DraftState,
  editorId: EditorId,
  fallback: Omit<ResolvedDraftForm, "text"> | null,
): DraftResult {
  const current = getEditor(state, editorId);
  if (
    !fallback ||
    (current.defaults.entryPoint !== null && current.defaults.agent !== null)
  )
    return { state, effects: [] };
  const defaults: FormDefaults = {
    entryPoint:
      current.defaults.entryPoint === null
        ? fallback.entryPoint
        : current.defaults.entryPoint,
    agent:
      current.defaults.agent === null ? fallback.agent : current.defaults.agent,
  };
  const observed: DraftForm = {
    ...current.observed,
    entryPoint:
      current.defaults.entryPoint === null
        ? fallback.entryPoint
        : current.observed.entryPoint,
    agent:
      current.defaults.agent === null ? fallback.agent : current.observed.agent,
  };

  if (current.desired.kind === "none") {
    return {
      state: replaceEditor(state, editorId, {
        ...current,
        defaults,
        observed,
      }),
      effects: [],
    };
  }

  const next = replaceEditor(state, editorId, {
    ...current,
    defaults,
    observed,
    desired: {
      ...current.desired,
      entryPoint:
        current.defaults.entryPoint === null
          ? acceptsObservedValue(
              current.desired.entryPoint,
              current.observed.entryPoint,
              fallback.entryPoint,
            )
          : current.desired.entryPoint,
      agent:
        current.defaults.agent === null
          ? acceptsObservedValue(
              current.desired.agent,
              current.observed.agent,
              fallback.agent,
            )
          : current.desired.agent,
    },
  });
  return reconcileCore(next, editorId);
}

function editText(
  state: DraftState,
  event: Extract<DraftEvent, { type: "edit-text" }>,
): DraftResult {
  const current = getEditor(state, event.editorId);
  if (event.text.trim().length === 0) {
    return clearEditor(state, event.editorId, event.successor);
  }
  if (current.desired.kind !== "editing") {
    throw new Error("Only an editing draft can change text");
  }
  if (current.desired.text === event.text) return { state, effects: [] };
  const next = replaceEditor(state, event.editorId, {
    ...current,
    desired: { ...current.desired, text: event.text },
    formVersion: current.formVersion + 1,
  });
  return afterLocalFormChange(next, event.editorId, {
    entryPoint: false,
    agent: false,
  });
}

function clearEditor(
  state: DraftState,
  editorId: EditorId,
  successor: CompositionId | undefined,
): DraftResult {
  const current = getEditor(state, editorId);
  if (current.desired.kind === "none") return { state, effects: [] };
  if (current.desired.kind !== "editing") {
    throw new Error("A submitting draft cannot be cleared");
  }
  if (current.remote.kind === "absent" && current.desired.text === "") {
    return { state, effects: [] };
  }
  if (current.remote.kind === "present")
    return closePresentEditor(state, editorId, current, current.remote);
  const next = replaceNewTask(state, editorId, successor);
  return {
    state:
      current.remote.kind === "creating"
        ? replaceEditor(next, editorId, {
            ...current,
            desired: { kind: "none" },
          })
        : removeEditor(next, editorId),
    effects: cancelCreateEffect(current, editorId),
  };
}

function changeEntryPoint(
  state: DraftState,
  editorId: EditorId,
  entryPoint: string,
): DraftResult {
  const current = getEditor(state, editorId);

  if (!catalogLists(state, current.project, entryPoint)) {
    throw new Error(`Unknown entry point: ${entryPoint}`);
  }

  switch (current.desired.kind) {
    case "none":
      if (current.defaults.entryPoint === entryPoint) {
        return { state, effects: [] };
      }
      return {
        state: replaceEditor(state, editorId, {
          ...current,
          defaults: { ...current.defaults, entryPoint },
        }),
        effects: [],
      };

    case "editing": {
      if (current.desired.entryPoint === entryPoint) {
        return { state, effects: [] };
      }
      const next = replaceEditor(state, editorId, {
        ...current,
        defaults: { ...current.defaults, entryPoint },
        desired: { ...current.desired, entryPoint },
        formVersion: current.formVersion + 1,
      });
      return afterLocalFormChange(next, editorId, {
        entryPoint: true,
        agent: false,
      });
    }

    case "submitting":
      throw new Error("A submitting draft cannot change entry point");

    default:
      return assertNever(current.desired);
  }
}

function changeAgent(
  state: DraftState,
  editorId: EditorId,
  agent: string,
): DraftResult {
  const current = getEditor(state, editorId);

  switch (current.desired.kind) {
    case "none":
      if (current.defaults.agent === agent) return { state, effects: [] };
      return {
        state: replaceEditor(state, editorId, {
          ...current,
          defaults: { ...current.defaults, agent },
        }),
        effects: [],
      };

    case "editing": {
      if (current.desired.agent === agent) return { state, effects: [] };
      const next = replaceEditor(state, editorId, {
        ...current,
        defaults: { ...current.defaults, agent },
        desired: { ...current.desired, agent },
        formVersion: current.formVersion + 1,
      });
      return afterLocalFormChange(next, editorId, {
        entryPoint: false,
        agent: true,
      });
    }

    case "submitting":
      throw new Error("A submitting draft cannot change agent");

    default:
      return assertNever(current.desired);
  }
}

function submit(
  state: DraftState,
  event: Extract<DraftEvent, { type: "submit" }>,
): DraftResult {
  const current = getEditor(state, event.editorId);
  if (current.desired.kind !== "editing") {
    throw new Error("Only an editing draft can be submitted");
  }
  if (!editorSubmittable(state, event.editorId))
    throw new Error("Draft metadata does not allow submission");
  const images = [...event.images];
  if (current.desired.text.trim().length === 0 && images.length === 0) {
    throw new Error("Cannot submit an empty draft");
  }
  const editorId = event.editorId;
  const { remote } = current;
  if (remote.kind === "deleting")
    throw new Error("Cannot submit a deleting draft");
  const attempt: SubmissionAttempt =
    remote.kind === "absent"
      ? {
          delivery: "atomic-create",
          phase: "awaiting-acceptance",
          correlationId: compositionCorrelation(editorId),
        }
      : remote.kind === "creating"
        ? {
            delivery: "send-when-present",
            phase: "waiting-for-tid",
            createCorrelationId: remote.correlationId,
          }
        : messageAttempt(event.messageCorrelationId);
  const desired = {
    ...formOf(current.desired),
    kind: "submitting" as const,
    images,
    attempt,
  };
  const effects = [
    ...cancelCreateEffect(current, editorId),
    ...cancelSaveEffect(current, editorId),
  ];
  const nextEditor: EditorState = {
    ...current,
    defaults: defaultsOf(desired),
    desired,
    createSchedule: null,
    saveSchedule: null,
  };
  if (attempt.delivery === "atomic-create") {
    assertResolvedDraftForm(desired);
    nextEditor.observed = { ...defaultsOf(desired), text: "" };
    nextEditor.remote = {
      kind: "creating",
      correlationId: attempt.correlationId,
    };
    effects.push({
      type: "create-task",
      editorId,
      correlationId: attempt.correlationId,
      entryPoint: desired.entryPoint,
      agent: desired.agent,
      content: contentOf(desired),
    });
  } else if (
    remote.kind === "present" &&
    attempt.phase === "awaiting-acceptance"
  ) {
    effects.push({
      type: "send-first-message",
      editorId,
      tid: remote.tid,
      messageCorrelationId: attempt.messageCorrelationId,
      content: contentOf(desired),
    });
  }
  return { state: replaceEditor(state, editorId, nextEditor), effects };
}

function messageAttempt(messageCorrelationId: string | undefined) {
  if (!messageCorrelationId)
    throw new Error("First message requires a correlation");
  return {
    delivery: "send-when-present",
    phase: "awaiting-acceptance",
    messageCorrelationId,
  } as const;
}

function rejectSubmission(
  state: DraftState,
  { editorId, tid }: Extract<DraftEvent, { type: "submission-rejected" }>,
): DraftResult {
  const current = getEditor(state, editorId);
  const { desired, remote, observed } = current;
  if (desired.kind !== "submitting")
    throw new Error("Rejection requires a submitting editor");
  const editing = { kind: "editing" as const, ...formOf(desired) };
  if (remote.kind === "creating" && tid === undefined) {
    return {
      state: replaceEditor(state, editorId, {
        ...current,
        remote: { kind: "absent" },
        desired: editing,
      }),
      effects: [],
    };
  }
  if (remote.kind !== "present" || remote.tid !== tid)
    throw new Error("Rejection does not match a bound submission");
  const editable: EditorState = {
    ...current,
    desired: { ...editing, recovered: true },
  };
  const next = replaceEditor(state, editorId, editable);
  const changed = {
    entryPoint: editing.entryPoint !== observed.entryPoint,
    agent: editing.agent !== observed.agent,
  };
  if (changed.entryPoint || changed.agent)
    return afterLocalFormChange(
      next,
      editorId,
      changed,
      editing.text !== observed.text,
    );
  if (editing.text !== observed.text)
    return ensureDraftSave(next, editorId, editable, tid);
  return { state: next, effects: [] };
}

function flush(state: DraftState, editorId: EditorId): DraftResult {
  const current = getEditor(state, editorId);
  if (!isPresentEditing(current) || current.saveSchedule === null)
    return { state, effects: [] };

  const next = replaceEditor(state, editorId, {
    ...current,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      ...cancelSaveEffect(current, editorId),
      {
        type: "set-draft",
        editorId,
        tid: current.remote.tid,
        text: current.desired.text,
        formVersion: current.formVersion,
      },
    ],
  };
}

function createTimerDue(
  state: DraftState,
  event: Extract<DraftEvent, { type: "create-timer-due" }>,
): DraftResult {
  const current = getEditor(state, event.editorId);
  if (
    current.createSchedule !== event.correlationId ||
    current.remote.kind !== "absent" ||
    current.desired.kind !== "editing"
  ) {
    return { state, effects: [] };
  }
  assertResolvedDraftForm(current.desired);

  const next = replaceEditor(state, event.editorId, {
    ...current,
    observed: {
      text: "",
      entryPoint: current.desired.entryPoint,
      agent: current.desired.agent,
    },
    remote: { kind: "creating", correlationId: event.correlationId },
    createSchedule: null,
  });
  return {
    state: next,
    effects: [
      {
        type: "create-task",
        editorId: event.editorId,
        correlationId: event.correlationId,
        entryPoint: current.desired.entryPoint,
        agent: current.desired.agent,
        content: null,
      },
    ],
  };
}

function saveTimerDue(
  state: DraftState,
  event: Extract<DraftEvent, { type: "save-timer-due" }>,
): DraftResult {
  const current = getEditor(state, event.editorId);
  if (
    !isPresentEditing(current) ||
    current.saveSchedule === null ||
    current.saveSchedule.tid !== event.tid ||
    current.saveSchedule.formVersion !== event.formVersion
  ) {
    return { state, effects: [] };
  }

  const next = replaceEditor(state, event.editorId, {
    ...current,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      {
        type: "set-draft",
        editorId: event.editorId,
        tid: event.tid,
        text: current.desired.text,
        formVersion: event.formVersion,
      },
    ],
  };
}

function taskCreated(
  state: DraftState,
  event: Extract<DraftEvent, { type: "task-created" }>,
): DraftResult {
  const { editorId, correlationId, tid } = event;
  const current = getEditor(state, editorId);
  if (
    current.remote.kind !== "creating" ||
    current.remote.correlationId !== correlationId
  ) {
    throw new Error("Create acknowledgement does not match the editor");
  }
  assertTaskId(tid);
  assertTidUnowned(state, tid);
  const promoted =
    current.desired.kind === "none"
      ? state
      : replaceNewTask(state, editorId, event.successor);
  const next = replaceEditor(promoted, editorId, {
    ...current,
    remote: { kind: "present", tid, status: "pending" },
  });
  if (
    current.desired.kind === "submitting" &&
    current.desired.attempt.phase === "waiting-for-tid"
  ) {
    const desired = current.desired;
    assertResolvedDraftForm(desired);
    const attempt = messageAttempt(event.messageCorrelationId);
    const effects: DraftEffect[] = [];
    if (desired.entryPoint !== current.observed.entryPoint) {
      effects.push({
        type: "set-entry-point",
        editorId,
        tid,
        entryPoint: desired.entryPoint,
      });
    }
    if (desired.agent !== current.observed.agent) {
      effects.push({ type: "set-agent", editorId, tid, agent: desired.agent });
    }
    effects.push({
      type: "send-first-message",
      editorId,
      tid,
      messageCorrelationId: attempt.messageCorrelationId,
      content: contentOf(desired),
    });
    return {
      state: replaceEditor(next, editorId, {
        ...getEditor(next, editorId),
        desired: { ...desired, attempt },
      }),
      effects,
    };
  }
  const reconciled = reconcileCore(next, editorId);
  if (current.desired.kind !== "editing") return reconciled;

  assertResolvedDraftForm(current.desired);
  return {
    state: reconciled.state,
    effects: [
      ...reconciled.effects,
      {
        type: "set-entry-point",
        editorId,
        tid,
        entryPoint: current.desired.entryPoint,
      },
      { type: "set-agent", editorId, tid, agent: current.desired.agent },
      {
        type: "set-draft",
        editorId,
        tid,
        text: current.desired.text,
        formVersion: current.formVersion,
      },
      projectEffect(editorId, tid, {
        desired: current.desired,
        formVersion: current.formVersion,
      }),
    ],
  };
}

function taskDeleted(
  state: DraftState,
  { editorId, tid }: Extract<DraftEvent, { type: "task-deleted" }>,
): DraftResult {
  const current = getEditor(state, editorId);
  if (
    (current.remote.kind !== "present" && current.remote.kind !== "deleting") ||
    current.remote.tid !== tid
  ) {
    throw new Error("Deletion acknowledgement does not match the editor");
  }
  return {
    state: removeEditor(state, editorId),
    effects: cancelSaveEffect(current, editorId),
  };
}

function taskObserved(
  state: DraftState,
  event: Extract<DraftEvent, { type: "task-observed" }>,
): DraftResult {
  const { editorId, observation } = event;
  const current = getEditor(state, editorId);
  if (
    (current.remote.kind !== "present" && current.remote.kind !== "deleting") ||
    current.remote.tid !== observation.tid
  ) {
    throw new Error("Observation does not match an owned task");
  }
  assertObservedFormFieldTypes(observation);
  assertObservedActivityFactTypes(observation);

  const remote =
    current.remote.kind === "present" &&
    hasOwnProperty(observation, "status") &&
    observation.status !== undefined &&
    observation.status !== current.remote.status
      ? { ...current.remote, status: observation.status }
      : current.remote;

  if (current.desired.kind === "submitting") {
    const observed = mergeObservedBaseline(current.observed, observation);
    return {
      state:
        remote !== current.remote || hasObservedFormFields(observation)
          ? replaceEditor(state, editorId, { ...current, remote, observed })
          : state,
      effects: [],
    };
  }
  if (
    isActiveObservation(observation) &&
    !(current.desired.kind === "editing" && current.desired.recovered)
  ) {
    return {
      state: removeEditor(state, editorId),
      effects: [...cancelSaveEffect(current, editorId)],
    };
  }

  if (current.remote.kind !== "present") {
    throw new Error("Only a present task accepts a pending observation");
  }
  if (current.desired.kind !== "editing") {
    throw new Error("Only an editing draft accepts a task observation");
  }

  if (!hasObservedFormFields(observation)) {
    return {
      state:
        remote === current.remote
          ? state
          : replaceEditor(state, editorId, { ...current, remote }),
      effects: [
        projectEffect(editorId, observation.tid, {
          desired: current.desired,
          formVersion: current.formVersion,
        }),
      ],
    };
  }

  const form = mergeObservedForm(
    current.desired,
    current.observed,
    observation,
  );
  const changed =
    form.text !== current.desired.text ||
    form.entryPoint !== current.desired.entryPoint ||
    form.agent !== current.desired.agent;
  const formVersion = changed ? current.formVersion + 1 : current.formVersion;
  const saveSchedule =
    changed && current.saveSchedule !== null
      ? { tid: observation.tid, formVersion }
      : current.saveSchedule;
  const nextEditor = {
    ...current,
    remote,
    defaults: mergeObservedDefaults(current.defaults, form, observation),
    observed: mergeObservedBaseline(current.observed, observation),
    desired: changed ? { ...current.desired, ...form } : current.desired,
    formVersion,
    saveSchedule,
  };
  const next = replaceEditor(state, editorId, nextEditor);
  const effects: DraftEffect[] = [
    projectEffect(editorId, observation.tid, nextEditor),
  ];
  if (changed && saveSchedule !== null) {
    effects.push({
      type: "ensure-draft-save",
      editorId,
      tid: saveSchedule.tid,
      formVersion: saveSchedule.formVersion,
      delayMs: DRAFT_SAVE_DELAY_MS,
    });
  }
  return { state: next, effects };
}

function openPersisted(
  state: DraftState,
  {
    editorId,
    project,
    snapshot,
  }: Extract<DraftEvent, { type: "open-persisted" }>,
): DraftResult {
  assertPersistedSnapshot(snapshot);
  assertNonEmptyPersistedText(snapshot.text);
  if (editorId !== `task:${snapshot.tid}`) {
    throw new Error("Persisted draft editor must match the task ID");
  }
  assertTidUnowned(state, snapshot.tid);
  const form = formOf(snapshot);
  const next = insertEditor(state, editorId, {
    ...createEditor(project, defaultsOf(form)),
    observed: form,
    desired: { kind: "editing", ...form },
    remote: { kind: "present", tid: snapshot.tid, status: "pending" },
  });
  return resolveEditorDefaults(
    next,
    editorId,
    projectDraftDefaults(state, project),
  );
}

function afterLocalFormChange(
  state: DraftState,
  editorId: EditorId,
  changed: { entryPoint: boolean; agent: boolean },
  saveText = true,
): DraftResult {
  const reconciled = reconcileCore(state, editorId);
  const current = getEditor(reconciled.state, editorId);
  if (!isPresentEditing(current)) return reconciled;
  const effects: DraftEffect[] = [...reconciled.effects];
  if (changed.entryPoint || changed.agent) {
    assertResolvedDraftForm(current.desired);
    if (changed.entryPoint) {
      effects.push({
        type: "set-entry-point",
        editorId,
        tid: current.remote.tid,
        entryPoint: current.desired.entryPoint,
      });
    }
    if (changed.agent) {
      effects.push({
        type: "set-agent",
        editorId,
        tid: current.remote.tid,
        agent: current.desired.agent,
      });
    }
  }
  effects.push(projectEffect(editorId, current.remote.tid, current));
  if (!saveText) return { state: reconciled.state, effects };

  const scheduled = ensureDraftSave(
    reconciled.state,
    editorId,
    current,
    current.remote.tid,
  );
  return {
    state: scheduled.state,
    effects: [...effects, ...scheduled.effects],
  };
}

function reconcileCore(state: DraftState, editorId: EditorId): DraftResult {
  const current = getEditor(state, editorId);

  switch (current.remote.kind) {
    case "absent":
      switch (current.desired.kind) {
        case "none":
          return { state, effects: [] };

        case "submitting":
          throw new Error(
            "Submitting editor must have an in-flight or bound task",
          );

        case "editing": {
          if (
            current.desired.text.trim() === "" ||
            current.desired.entryPoint === null ||
            current.desired.agent === null ||
            current.createSchedule !== null
          ) {
            return { state, effects: [] };
          }
          const correlationId = compositionCorrelation(editorId);
          return {
            state: replaceEditor(state, editorId, {
              ...current,
              createSchedule: correlationId,
            }),
            effects: [
              {
                type: "schedule-create",
                editorId,
                correlationId,
                delayMs: CREATE_DELAY_MS,
              },
            ],
          };
        }

        default:
          return assertNever(current.desired);
      }

    case "creating":
    case "deleting":
      return { state, effects: [] };

    case "present":
      switch (current.desired.kind) {
        case "editing":
        case "submitting":
          return { state, effects: [] };

        case "none":
          return closePresentEditor(state, editorId, current, current.remote);

        default:
          return assertNever(current.desired);
      }

    default:
      return assertNever(current.remote);
  }
}

function closePresentEditor(
  state: DraftState,
  editorId: EditorId,
  current: EditorState,
  { tid, status }: Extract<Remote, { kind: "present" }>,
): DraftResult {
  if (status !== "pending") {
    return {
      state: removeEditor(state, editorId),
      effects: [
        ...cancelSaveEffect(current, editorId),
        { type: "clear-task-draft", editorId, tid },
      ],
    };
  }
  const next = replaceEditor(state, editorId, {
    ...current,
    remote: { kind: "deleting", tid },
    desired: { kind: "none" },
    createSchedule: null,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      ...cancelCreateEffect(current, editorId),
      ...cancelSaveEffect(current, editorId),
      { type: "delete-task", editorId, tid },
    ],
  };
}

function ensureDraftSave(
  state: DraftState,
  editorId: EditorId,
  current: EditorState,
  tid: number,
): DraftResult {
  const schedule: SaveSchedule = {
    tid,
    formVersion: current.formVersion,
  };
  if (
    current.saveSchedule !== null &&
    current.saveSchedule.tid === schedule.tid &&
    current.saveSchedule.formVersion === schedule.formVersion
  ) {
    return { state, effects: [] };
  }
  return {
    state: replaceEditor(state, editorId, {
      ...current,
      saveSchedule: schedule,
    }),
    effects: [
      {
        type: "ensure-draft-save",
        editorId,
        tid: schedule.tid,
        formVersion: schedule.formVersion,
        delayMs: DRAFT_SAVE_DELAY_MS,
      },
    ],
  };
}

function cancelCreateEffect(
  current: EditorState,
  editorId: EditorId,
): DraftEffect[] {
  if (current.createSchedule === null) return [];
  return [
    {
      type: "cancel-create-schedule",
      editorId,
      correlationId: current.createSchedule,
    },
  ];
}

function cancelSaveEffect(
  current: EditorState,
  editorId: EditorId,
): DraftEffect[] {
  if (current.saveSchedule === null) return [];
  return [
    {
      type: "cancel-draft-save",
      editorId,
      tid: current.saveSchedule.tid,
      formVersion: current.saveSchedule.formVersion,
    },
  ];
}

function projectEffect(
  editorId: EditorId,
  tid: number,
  current: { desired: DraftForm; formVersion: number },
): DraftEffect {
  const form = formOf(current.desired);
  if (form.entryPoint === null)
    throw new Error("Draft projection requires a resolved entry point");
  return {
    type: "project-draft",
    editorId,
    tid,
    form: { ...form, entryPoint: form.entryPoint },
    formVersion: current.formVersion,
  };
}

function isPresentEditing(editor: EditorState): editor is EditorState & {
  desired: Extract<Desired, { kind: "editing" }>;
  remote: Extract<Remote, { kind: "present" }>;
} {
  return editor.desired.kind === "editing" && editor.remote.kind === "present";
}

function mergeObservedForm(
  desired: Extract<Desired, { kind: "editing" }>,
  observed: DraftForm,
  observation: TaskObservation,
): DraftForm {
  return {
    text: hasOwnProperty(observation, "text")
      ? acceptsObservedValue(
          desired.text,
          hasOwnProperty(observation, "oldText")
            ? observation.oldText!
            : observed.text,
          observation.text!,
        )
      : desired.text,
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? acceptsObservedValue(
          desired.entryPoint,
          observed.entryPoint,
          observation.entryPoint!,
        )
      : desired.entryPoint,
    agent: hasOwnProperty(observation, "agent")
      ? acceptsObservedValue(desired.agent, observed.agent, observation.agent!)
      : desired.agent,
  };
}

function mergeObservedDefaults(
  defaults: FormDefaults,
  form: DraftForm,
  observation: TaskObservation,
): FormDefaults {
  return {
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? form.entryPoint
      : defaults.entryPoint,
    agent: hasOwnProperty(observation, "agent") ? form.agent : defaults.agent,
  };
}

function mergeObservedBaseline(
  observed: DraftForm,
  observation: TaskObservation,
): DraftForm {
  return {
    text: hasOwnProperty(observation, "text")
      ? observation.text!
      : observed.text,
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? observation.entryPoint!
      : observed.entryPoint,
    agent: hasOwnProperty(observation, "agent")
      ? observation.agent!
      : observed.agent,
  };
}

function hasObservedFormFields(observation: TaskObservation): boolean {
  return (
    hasOwnProperty(observation, "text") ||
    hasOwnProperty(observation, "entryPoint") ||
    hasOwnProperty(observation, "agent")
  );
}

function assertObservedFormFieldTypes(observation: TaskObservation): void {
  assertObservedFormFieldType(observation, "text");
  assertObservedFormFieldType(observation, "oldText");
  assertObservedFormFieldType(observation, "entryPoint");
  assertObservedFormFieldType(observation, "agent");
}

function assertObservedFormFieldType(
  observation: TaskObservation,
  field: keyof DraftForm | "oldText",
): void {
  if (
    hasOwnProperty(observation, field) &&
    typeof observation[field] !== "string"
  ) {
    throw new Error("Observed form field " + field + " must be a string");
  }
}

function assertObservedActivityFactTypes(observation: TaskObservation): void {
  if (
    hasOwnProperty(observation, "status") &&
    typeof observation.status !== "string"
  )
    throw new Error("Observed activity field status must be a string");
  assertObservedActivityFactType(observation, "alive");
  assertObservedActivityFactType(observation, "isProcessing");
  assertObservedActivityFactType(observation, "hasMessages");
}

function assertObservedActivityFactType(
  observation: TaskObservation,
  field: "alive" | "isProcessing" | "hasMessages",
): void {
  if (
    hasOwnProperty(observation, field) &&
    typeof observation[field] !== "boolean"
  ) {
    throw new Error("Observed activity field " + field + " must be a boolean");
  }
}

function hasOwnProperty(value: object, field: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(value, field);
}

function acceptsObservedValue<T extends string | null>(
  local: T,
  observed: T,
  incoming: string,
): T | string {
  return local === "" || local === observed ? incoming : local;
}

function isActiveSnapshot(snapshot: PersistedSnapshot): boolean {
  return snapshot.active || snapshot.processing || snapshot.hasMessages;
}

export function isActiveObservation(observation: TaskObservation): boolean {
  return (
    (hasOwnProperty(observation, "status") &&
      observation.status !== "pending") ||
    (hasOwnProperty(observation, "alive") && observation.alive === true) ||
    (hasOwnProperty(observation, "isProcessing") &&
      observation.isProcessing === true) ||
    (hasOwnProperty(observation, "hasMessages") &&
      observation.hasMessages === true)
  );
}

function assertPersistedSnapshot(
  snapshot: unknown,
): asserts snapshot is PersistedSnapshot {
  if (typeof snapshot !== "object" || snapshot === null) {
    throw new Error("Persisted task snapshot must be complete");
  }

  const candidate = snapshot as Partial<PersistedSnapshot>;
  assertPersistedSnapshotOwnProperties(candidate);
  assertTaskId(candidate.tid);
  if (
    typeof candidate.text !== "string" ||
    typeof candidate.entryPoint !== "string" ||
    (candidate.agent !== null && typeof candidate.agent !== "string") ||
    typeof candidate.active !== "boolean" ||
    typeof candidate.processing !== "boolean" ||
    typeof candidate.hasMessages !== "boolean"
  ) {
    throw new Error("Persisted task snapshot must be complete");
  }

  assertPendingSnapshot(candidate as PersistedSnapshot);
}

function assertPersistedSnapshotOwnProperties(snapshot: object): void {
  for (const field of PERSISTED_SNAPSHOT_FIELDS) {
    if (!hasOwnProperty(snapshot, field)) {
      throw new Error("Persisted task snapshot must be complete");
    }
  }
}

function assertTaskId(tid: unknown): asserts tid is number {
  if (
    typeof tid !== "number" ||
    !Number.isInteger(tid) ||
    tid <= 0 ||
    tid > MAX_TASK_ID
  ) {
    throw new Error("Task ID must be a positive signed 32-bit integer");
  }
}

function assertPendingSnapshot(snapshot: PersistedSnapshot): void {
  if (isActiveSnapshot(snapshot)) {
    throw new Error("Only a pending task can be opened as a draft");
  }
}

function assertNonEmptyPersistedText(text: string): void {
  if (text.trim().length === 0) {
    throw new Error("A persisted draft must have non-empty text");
  }
}

function compositionCorrelation(editorId: EditorId): DraftId {
  const prefix = "composition:";
  const correlationId = editorId.slice(prefix.length);
  if (!editorId.startsWith(prefix) || correlationId.trim() === "") {
    throw new Error("A composition editor requires a browser UUID");
  }
  return correlationId;
}

function assertTidUnowned(state: DraftState, tid: number): void {
  for (const editor of Object.values(state.editors)) {
    if (
      (editor.remote.kind === "present" || editor.remote.kind === "deleting") &&
      editor.remote.tid === tid
    ) {
      throw new Error(`Task ID is already owned by another editor: ${tid}`);
    }
  }
}

function insertEditor(
  state: DraftState,
  editorId: EditorId,
  value: EditorState,
): DraftState {
  if (state.editors[editorId])
    throw new Error("Duplicate draft editor: " + editorId);
  return { ...state, editors: { ...state.editors, [editorId]: value } };
}

function replaceEditor(
  state: DraftState,
  editorId: EditorId,
  value: EditorState,
): DraftState {
  return { ...state, editors: { ...state.editors, [editorId]: value } };
}

function removeEditor(state: DraftState, editorId: EditorId): DraftState {
  const { [editorId]: _removed, ...editors } = state.editors;
  return { ...state, editors };
}

function defaultsOf(form: FormDefaults): FormDefaults {
  return { entryPoint: form.entryPoint, agent: form.agent };
}

function formOf(form: DraftForm): DraftForm {
  return {
    text: form.text,
    entryPoint: form.entryPoint,
    agent: form.agent,
  };
}

function contentOf(
  desired: Extract<Desired, { kind: "submitting" }>,
): DraftContent {
  return { text: desired.text, images: desired.images };
}
