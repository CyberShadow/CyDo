// Custom hook: WebSocket connection, rAF message buffering, task state, and user actions.

// Stateful hook with one-time effects and closure-captured callbacks.
// HMR can't safely update a running instance — force full reload.
if (import.meta.hot) import.meta.hot.invalidate();

import {
  useState,
  useEffect,
  useLayoutEffect,
  useRef,
  useCallback,
  useMemo,
} from "preact/hooks";
import { useLocation } from "preact-iso";
import { Connection } from "./connection";
import type {
  AgentUsageMessage,
  AgnosticEvent,
  ControlMessage,
  ContentBlock,
  DraftUpdatedMessage,
  HistoryBoundary,
  Notice,
  TaskListEntry,
  UiConfig,
  HeicConversionStatus,
} from "./protocol";
import {
  resetControlledImageStore,
  retireControlledImage,
  type ControlledImageStore,
} from "./controlledImageStore";
import {
  createOrdinaryDraftStore,
  type OrdinaryDraftStore,
} from "./ordinaryDraftStore";
import type { CydoMeta, TaskState, UndoPending } from "./types";
import { makeTaskState } from "./types";
import {
  reduceAgentAckIn,
  reduceMessageIn,
  rejectOrdinarySubmission,
  replaceHistoryBoundaryIn,
} from "./sessionReducer";
import { deepFreeze } from "./testing/deepFreeze";
import { permissionAwaitingAgent } from "./permissionHandoff";
import { WriteBatch } from "./writeBatch";
import { outbox } from "./outbox";
import {
  canonicalUserTextFromContentAndMeta,
  canonicalUserTextFromDisplayMessage,
} from "./userText";
import {
  beginTaskHistoryReplay,
  excludeReloadDraftUuid,
  reconcileInputDraft,
  resetTaskForReload,
  snapshotUserDrafts,
} from "./historyReplayReset";
import {
  assertResolvedDraftForm,
  createDraftState,
  createProjectKey,
  editorMetadataReady,
  editorSubmittable,
  type AgentInfo,
  getEditor,
  isActiveObservation,
  reduceDraft,
  type DraftEffect,
  type DraftEvent,
  type EditorState,
  type DraftState,
  type CompositionId,
  type EditorId,
  type ImageAttachment,
  type EntryPointInfo,
  type ProjectedDraftForm,
  type TaskObservation,
  type PersistedSnapshot,
} from "./draftReconciler";
import {
  buildProjectHref,
  buildScopedHref,
  canonicalTaskRedirect,
  parseRoute,
} from "./routing";

export type { ImageAttachment } from "./draftReconciler";

type HistoryBoundaryEvent =
  | (Extract<AgnosticEvent, { type: "item/started" }> & {
      history_boundary: HistoryBoundary;
    })
  | (Extract<AgnosticEvent, { type: "turn/stop" }> & {
      history_boundary: HistoryBoundary;
    });

function hasHistoryBoundary(
  event: AgnosticEvent,
): event is HistoryBoundaryEvent {
  return (
    (event.type === "item/started" || event.type === "turn/stop") &&
    event.history_boundary !== undefined
  );
}

export function revertFilesForUndo(
  canRevertFiles: boolean,
  revertFiles: boolean,
) {
  return canRevertFiles && revertFiles;
}

function buildContentBlocks(
  text: string,
  images?: readonly ImageAttachment[],
): ContentBlock[] {
  const blocks: ContentBlock[] = [];
  if (text) blocks.push({ type: "text", text });
  if (images) {
    for (const img of images) {
      blocks.push({
        type: "image",
        data: img.base64,
        media_type: img.mediaType,
      });
    }
  }
  return blocks;
}

function assertNeverDraftEffect(effect: never): never {
  throw new Error(`Unexpected draft effect: ${JSON.stringify(effect)}`);
}

export interface ProjectInfo {
  name: string;
  path: string;
  virtual?: boolean;
  exists?: boolean;
}

export interface WorkspaceInfo {
  name: string;
  projects: ProjectInfo[];
  default_agent?: string;
  default_task_type?: string;
}

export type { AgentInfo, EntryPointInfo } from "./draftReconciler";

export interface TypeInfo {
  name: string;
  icon?: string;
}

export type DraftLifecycle =
  | "idle"
  | "creating"
  | "present"
  | "deleting"
  | "submitting";

interface DraftViewBase {
  viewKey: string;
  workspace: string;
  projectName: string;
  projectPath: string;
  remoteTid: number | null;
  text: string;
  entryPoint: string;
  agent: string;
  lifecycle: DraftLifecycle;
  disabled: boolean;
  metadataReady: boolean;
  submitReady: boolean;
  composerResetToken: number;
}

export interface UnresolvedDraftView extends DraftViewBase {
  kind: "unresolved";
}

export interface DraftViewSnapshot extends DraftViewBase {
  kind: "resolved";
  editorId: EditorId;
  onTextChange: (text: string) => void;
  onEntryPointChange: (entryPoint: string) => void;
  onAgentChange: (agent: string) => void;
  onSubmit: (text: string, images: ImageAttachment[]) => void;
}

export type DraftView = UnresolvedDraftView | DraftViewSnapshot;

export interface TaskManager {
  tasks: Map<string, TaskState>;
  ordinaryDraftStore: OrdinaryDraftStore;
  activeTaskId: string | null;
  getActiveTaskId: () => string | null;
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  tasksLoaded: boolean;
  send: (uuid: string, text: string, images?: ImageAttachment[]) => void;
  interrupt: (uuid: string) => void;
  stop: (uuid: string) => void;
  closeStdin: (uuid: string) => void;
  resume: (uuid: string) => void;
  promote: (tid: number) => void;
  fork: (tid: number, anchor: string) => void;
  undo: (
    tid: number,
    anchor: string,
    dryRun: boolean,
    revertConversation: boolean,
    revertFiles: boolean,
  ) => void;
  undoPreview: (tid: number, anchor: string) => void;
  unsendMessage: (tid: number, nonce: string) => void;
  /** Overrule the auto mode classifier's denial of a tool call and let the
   *  agent retry it. */
  approveRetry: (tid: number, toolName: string, input: unknown) => void;
  undoConfirm: (
    tid: number,
    revertConversation: boolean,
    revertFiles: boolean,
  ) => void;
  undoDismiss: (tid: number) => void;
  dismissAttention: (tid: number) => void;
  clearInputDraft: (tid: number) => void;
  setArchived: (tid: number, archived: boolean) => void;
  saveDraft: (tid: number, draft: string) => void;
  sendAskUserResponse: (tid: number, content: string) => void;
  sendPermissionPromptResponse: (
    tid: number,
    toolUseId: string,
    content: string,
  ) => void;
  editMessage: (tid: number, uuid: string, content: string) => void;
  editRawEvent: (tid: number, seq: number, content: string) => void;
  draftView: DraftView | null;
  sidebarTasks: Array<{
    tid: number;
    alive: boolean;
    canStop: boolean;
    resumable: boolean;
    isProcessing: boolean;
    stdinClosed?: boolean;
    title?: string;
    parentTid?: number;
    childCount: number;
    relationType?: string;
    status?: string;
    archived?: boolean;
    taskType?: string;
    hasPendingQuestion?: boolean;
    hasMessages?: boolean;
  }>;
  workspaces: WorkspaceInfo[];
  entryPoints: EntryPointInfo[];
  typeInfo: TypeInfo[];
  agents: readonly AgentInfo[];
  defaultAgent: string;
  defaultTaskType: string;
  activeWorkspace: string | null;
  activeProject: string | null;
  notices: Record<string, Notice>;
  localNotices: Record<string, Notice>;
  agentUsage: Record<string, AgentUsageMessage>;
  serverError: { message: string; tid?: number } | null;
  dismissServerError: () => void;
  devMode: boolean;
  ui: UiConfig;
  heicConversion: HeicConversionStatus;
  getHeicConversion: () => HeicConversionStatus;
  exportLoadError?: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  getByTid: (tid: number) => TaskState | undefined;
  refreshWorkspaces: () => void;
  scanState: "idle" | "requested" | "scanning";
}

interface ControlledDraftOwner {
  readonly editorId: EditorId;
  readonly lifetime: number;
}

type DraftUpdatedReceipt =
  | { readonly kind: "ordinary" }
  | { readonly kind: "controlled"; readonly owner: ControlledDraftOwner };

function sameControlledDraftOwner(
  left: ControlledDraftOwner,
  right: ControlledDraftOwner,
) {
  return left.editorId === right.editorId && left.lifetime === right.lifetime;
}

function mintCompositionId(): CompositionId {
  return `composition:${crypto.randomUUID()}`;
}

function makeDraftViewSnapshot(
  editor: EditorState,
  editorId: EditorId,
  projectName: string,
  composerDisabled: boolean,
  metadataReady: boolean,
  submitReady: boolean,
  composerResetToken: number,
  editText: (editorId: EditorId, text: string) => void,
  dispatch: (event: DraftEvent) => void,
  submit: (editorId: EditorId, images: ImageAttachment[]) => void,
): DraftViewSnapshot {
  const form =
    editor.desired.kind === "none"
      ? { text: "", ...editor.defaults }
      : {
          text: editor.desired.text,
          entryPoint: editor.desired.entryPoint,
          agent: editor.desired.agent,
        };
  const lifecycle: DraftLifecycle =
    editor.desired.kind === "submitting"
      ? "submitting"
      : editor.remote.kind === "creating"
        ? "creating"
        : editor.remote.kind === "present"
          ? "present"
          : editor.remote.kind === "deleting"
            ? "deleting"
            : "idle";
  const disabled = composerDisabled || editor.desired.kind !== "editing";
  return {
    kind: "resolved",
    editorId,
    viewKey: editorId,
    workspace: editor.project.workspace,
    projectName,
    projectPath: editor.project.projectPath,
    remoteTid:
      editor.remote.kind === "present" || editor.remote.kind === "deleting"
        ? editor.remote.tid
        : null,
    text: form.text,
    entryPoint: form.entryPoint ?? "",
    agent: form.agent ?? "",
    lifecycle,
    disabled,
    metadataReady,
    submitReady,
    composerResetToken,
    onTextChange: (text) => {
      if (disabled) return;
      editText(editorId, text);
    },
    onEntryPointChange: (entryPoint) => {
      if (disabled || !metadataReady) return;
      dispatch({ type: "change-entry-point", editorId, entryPoint });
    },
    onAgentChange: (agent) => {
      if (disabled || !metadataReady) return;
      dispatch({ type: "change-agent", editorId, agent });
    },
    onSubmit: (_text, images) => {
      if (disabled || !submitReady) return;
      submit(editorId, images);
    },
  };
}

/** Snapshot entry shape shared by tasks_list and task_updated messages. */
export type TaskSnapshotEntry = TaskListEntry;

/** Build (or merge) the TaskState a tasks_list/task_updated snapshot entry seeds. */
export function taskStateFromEntry(
  entry: TaskSnapshotEntry,
  existing: TaskState | undefined,
  existingUuid: string | undefined,
): TaskState {
  const workspace = entry.workspace || "";
  const projectPath = entry.project_path || "";
  const hasDraft = Object.prototype.hasOwnProperty.call(entry, "draft");
  const usageProfile = entry.usage_profile || undefined;
  if (!existing || !existingUuid) {
    const base = makeTaskState(
      entry.tid,
      entry.alive,
      entry.resumable,
      entry.title,
      false,
      workspace,
      projectPath,
      entry.parent_tid || undefined,
      entry.relation_type || undefined,
      entry.status || "pending",
      entry.isProcessing || false,
      entry.stdinClosed || false,
      entry.needsAttention || false,
      entry.hasPendingQuestion || false,
      entry.task_type || undefined,
      entry.archived || false,
      entry.created_at || undefined,
      entry.last_active || undefined,
      entry.agent_name || undefined,
      entry.entry_point || undefined,
      entry.archiving || false,
      entry.canStop ?? entry.alive,
      entry.driver || undefined,
    );
    return {
      ...base,
      usageProfile,
      uuid: existingUuid ?? base.uuid,
      childCount: entry.child_count,
      creatorTid: entry.creator_tid || undefined,
      serverDraft: hasDraft ? entry.draft || undefined : base.serverDraft,
      error: entry.error || undefined,
    };
  }
  // If a task becomes resumable but has no messages loaded,
  // reset historyLoaded so JSONL history gets requested
  // (e.g. forked tasks with pre-existing JSONL).
  const needsHistory =
    entry.resumable && existing.messages.length === 0 && existing.historyLoaded;
  return {
    ...existing,
    alive: entry.alive,
    resumable: entry.resumable,
    isProcessing: entry.isProcessing || false,
    stdinClosed: entry.stdinClosed || false,
    canStop: entry.canStop ?? entry.alive,
    needsAttention: entry.needsAttention || false,
    hasPendingQuestion: entry.hasPendingQuestion || false,
    historyLoaded: needsHistory ? false : existing.historyLoaded,
    title: entry.title || existing.title,
    workspace: workspace || existing.workspace,
    projectPath: projectPath || existing.projectPath,
    parentTid: entry.parent_tid || existing.parentTid,
    childCount: entry.child_count,
    relationType: entry.relation_type || existing.relationType,
    creatorTid: entry.creator_tid || existing.creatorTid,
    status: entry.status || existing.status,
    taskType: entry.task_type || existing.taskType,
    entryPoint: entry.entry_point || existing.entryPoint,
    agentName: entry.agent_name || existing.agentName,
    driver: entry.driver || existing.driver,
    usageProfile,
    suggestions:
      entry.isProcessing && !existing.isProcessing
        ? undefined
        : existing.suggestions,
    archived: entry.archived || false,
    archiving: entry.archiving || false,
    error: entry.error || undefined,
    createdAt: entry.created_at || existing.createdAt,
    lastActive: entry.last_active || existing.lastActive,
    serverDraft: hasDraft ? entry.draft || undefined : existing.serverDraft,
  };
}

export function taskObservationFromEntry(
  entry: TaskSnapshotEntry,
  hasKnownMessages: boolean,
): TaskObservation {
  const observation: TaskObservation = { tid: entry.tid };
  if (
    Object.prototype.hasOwnProperty.call(entry, "draft") &&
    typeof entry.draft === "string"
  )
    observation.text = entry.draft;
  if (
    Object.prototype.hasOwnProperty.call(entry, "entry_point") &&
    typeof entry.entry_point === "string"
  )
    observation.entryPoint = entry.entry_point;
  if (
    Object.prototype.hasOwnProperty.call(entry, "agent_name") &&
    typeof entry.agent_name === "string"
  )
    observation.agent = entry.agent_name;
  if (entry.status !== undefined) observation.status = entry.status;
  observation.alive = entry.alive;
  observation.isProcessing = entry.isProcessing;
  observation.hasMessages = hasKnownMessages;
  return observation;
}

export function projectDraftTask(
  task: TaskState | undefined,
  tid: number,
  form: ProjectedDraftForm,
  catalogs: ReadonlyMap<string, readonly EntryPointInfo[]>,
): TaskState {
  if (!task) throw new Error(`Draft projection requires task ${tid}`);
  const projectPath = task.projectPath;
  if (!projectPath) throw new Error(`Draft projection requires project ${tid}`);
  const entryPoint = catalogs
    .get(projectPath)
    ?.find((candidate) => candidate.name === form.entryPoint);
  let taskType: string;
  if (entryPoint) {
    taskType = entryPoint.task_type;
  } else {
    if (task.entryPoint !== form.entryPoint) {
      throw new Error(
        `Draft projection entry point does not match task ${tid}`,
      );
    }
    if (!task.taskType) {
      throw new Error(`Draft projection requires task type ${tid}`);
    }
    taskType = task.taskType;
  }
  const title = projectedTitle(form.text);
  const agentName = form.agent ?? task.agentName;
  if (
    title === task.title &&
    form.entryPoint === task.entryPoint &&
    agentName === task.agentName &&
    taskType === task.taskType
  )
    return task;
  return { ...task, title, entryPoint: form.entryPoint, agentName, taskType };
}

function projectedTitle(text: string): string | undefined {
  return text.trim().split("\n")[0]?.slice(0, 100) || undefined;
}

/// Extract text content from a user message event (for unconfirmed display).
function extractTextContent(msg: AgnosticEvent): string {
  if (msg.type !== "item/started" || msg.item_type !== "user_message")
    return "";
  return msg.text ?? "";
}

// Mutable mirror of task states, keyed by uuid. Updated synchronously outside
// Preact's render cycle so reducers and notification checks run immediately
// when WebSocket messages arrive, even when Preact defers state updates in
// background tabs.
const liveStates = new Map<string, TaskState>();

const taskBatches = new Map<string, WriteBatch>();

function batchFor(uuid: string): WriteBatch {
  let batch = taskBatches.get(uuid);
  if (!batch) {
    batch = new WriteBatch();
    taskBatches.set(uuid, batch);
  }
  return batch;
}

function sealTask(uuid: string): void {
  taskBatches.get(uuid)?.close();
  taskBatches.delete(uuid);
}

function markDirty(dirty: Set<string>, uuid: string, next: TaskState): void {
  liveStates.set(uuid, next);
  dirty.add(uuid);
}

// Index: backend tid → frontend uuid. Maintained in lockstep with liveStates.
const tidToUuid = new Map<number, string>();

function findByTid(tid: number): TaskState | undefined {
  const uuid = tidToUuid.get(tid);
  return uuid ? liveStates.get(uuid) : undefined;
}

export const getLiveTaskForTest =
  import.meta.env.MODE === "test" ? findByTid : undefined;

function isReplaying(task: TaskState): boolean {
  return !task.historyLoaded && task.historyTotal !== undefined;
}

function useTaskPublication() {
  const [tasks, setTasks] = useState(new Map<string, TaskState>());
  const publishedTasksRef = useRef(tasks);
  const operations = useMemo(() => {
    const publish = (
      update: (previous: Map<string, TaskState>) => Map<string, TaskState>,
    ) => {
      const previous = publishedTasksRef.current;
      const next = update(previous);
      if (next === previous) return;
      publishedTasksRef.current = next;
      setTasks(next);
    };

    const publishState = (state: TaskState) =>
      import.meta.env.DEV || import.meta.env.MODE === "test"
        ? deepFreeze(state)
        : state;

    const commitTask = (
      uuid: string,
      next: TaskState,
      publication: "always" | "if-present" = "always",
    ) => {
      if (next === liveStates.get(uuid))
        throw new Error(`Commit of unchanged task ${uuid}`);
      liveStates.set(uuid, next);
      sealTask(uuid);
      publish((previous) => {
        if (publication === "if-present" && !previous.has(uuid))
          return previous;
        return new Map(previous).set(uuid, publishState(next));
      });
    };

    const commitTasks = (entries: Map<string, TaskState>) => {
      for (const [uuid, state] of entries) {
        liveStates.set(uuid, state);
        sealTask(uuid);
      }
      publish((previous) => {
        const next = new Map(previous);
        for (const [uuid, state] of entries)
          next.set(uuid, publishState(state));
        return next;
      });
    };

    const publishDirtyTasks = (dirty: Set<string>) => {
      if (dirty.size === 0) return;
      publish((previous) => {
        let next = previous;
        for (const uuid of dirty) {
          const live = liveStates.get(uuid);
          if (!live || !taskBatches.has(uuid)) continue;

          let state: TaskState;
          if (isReplaying(live)) {
            const published = previous.get(uuid);
            if (!published)
              throw new Error(`Missing published replay task ${uuid}`);
            // Rule 4: the composer's permission handoff is derived from timeline and must be current while loading.
            if (
              permissionAwaitingAgent(live) ===
              permissionAwaitingAgent(published)
            ) {
              state = { ...published, historyReceived: live.historyReceived };
            } else {
              sealTask(uuid);
              state = live;
            }
          } else {
            sealTask(uuid);
            state = live;
          }

          if (next === previous) next = new Map(previous);
          next.set(uuid, publishState(state));
        }
        return next;
      });
    };

    const getPublishedTask = (tid: number) => {
      const uuid = tidToUuid.get(tid);
      return uuid === undefined
        ? undefined
        : publishedTasksRef.current.get(uuid);
    };

    /** Hide a task pending deletion while retaining its live state. */
    const unpublishTask = (uuid: string) => {
      sealTask(uuid);
      publish((previous) => {
        if (!previous.has(uuid)) return previous;
        const next = new Map(previous);
        next.delete(uuid);
        return next;
      });
    };

    const removeTask = (uuid: string) => {
      liveStates.delete(uuid);
      unpublishTask(uuid);
    };

    const clearTasks = () => {
      for (const uuid of taskBatches.keys()) sealTask(uuid);
      liveStates.clear();
      publish(() => new Map());
    };

    return {
      commitTask,
      commitTasks,
      unpublishTask,
      removeTask,
      clearTasks,
      publishDirtyTasks,
      getPublishedTask,
    };
  }, [setTasks]);
  return { tasks, ...operations };
}

/** Convert a string task id to a numeric tid; returns null for non-numeric strings. */
function readBrowserRoute(): ReturnType<typeof parseRoute> {
  return parseRoute(location.pathname);
}

function getActiveTaskId(): string | null {
  return readBrowserRoute().tid;
}

export function parseTaskId(id: string | null): number | null {
  if (id === null) return null;
  const n = parseInt(id, 10);
  return String(n) === id ? n : null;
}

function readLocalBuildId(): string {
  const script = document.querySelector<HTMLScriptElement>(
    'script[type="module"][src*="/assets/index-"]',
  );
  const match = script?.src.match(/\/assets\/index-([^.]+)\.js/);
  return match?.[1] ?? "";
}

const localBuildId = readLocalBuildId();

export function useTaskManager(
  addToast: (
    level: "info" | "warning" | "error" | "alert",
    message: string,
  ) => void,
  controlledImageStore?: ControlledImageStore,
): TaskManager {
  const [connected, setConnected] = useState(false);
  const {
    tasks,
    commitTask,
    commitTasks,
    unpublishTask,
    removeTask,
    clearTasks,
    publishDirtyTasks,
    getPublishedTask,
  } = useTaskPublication();
  const [ordinaryDraftStore] = useState(createOrdinaryDraftStore);
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [scanState, setScanState] = useState<"idle" | "requested" | "scanning">(
    "idle",
  );
  const [entryPoints, setEntryPoints] = useState<EntryPointInfo[]>([]);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);
  const [projectTypeInfo, setProjectTypeInfo] = useState<
    Map<string, TypeInfo[]>
  >(new Map());
  const [tasksListEpoch, setTasksListEpoch] = useState<number | null>(null);
  const [notices, setNotices] = useState<Record<string, Notice>>({});
  const [localNotices, setLocalNotices] = useState<Record<string, Notice>>({});
  const [agentUsage, setAgentUsage] = useState<
    Record<string, AgentUsageMessage>
  >({});
  const [serverError, setServerError] = useState<{
    message: string;
    tid?: number;
  } | null>(null);
  const [devMode, setDevMode] = useState(false);
  const [ui, setUi] = useState<UiConfig>({});
  const [heicConversion, setHeicConversion] = useState<HeicConversionStatus>({
    available: false,
    reason: "waiting for server status",
  });
  const heicConversionRef = useRef(heicConversion);
  const getHeicConversion = useCallback(() => heicConversionRef.current, []);
  const addToastRef = useRef(addToast);
  addToastRef.current = addToast;
  const prevNoticeIdsRef = useRef<Set<string>>(new Set());
  const initialNoticeLoadRef = useRef(true);
  const { route, path } = useLocation();
  const routerNavigateRef = useRef(route);
  useLayoutEffect(() => {
    routerNavigateRef.current = route;
  }, [route]);
  const workspacesRef = useRef(workspaces);

  const parsed = useMemo(() => parseRoute(path), [path]);
  const {
    tid: activeTaskId,
    workspace: activeWorkspace,
    project: activeProject,
  } = parsed;
  const connectionEpochRef = useRef(0);
  const openConnectionEpochRef = useRef<number | null>(0);

  const isCurrentOpenEpoch = useCallback(
    (epoch: number | null): epoch is number => {
      return (
        epoch !== null &&
        connectionEpochRef.current === epoch &&
        openConnectionEpochRef.current === epoch
      );
    },
    [],
  );
  const renderedConnectionEpoch = openConnectionEpochRef.current;

  const routeProjectCacheRef = useRef<{
    epoch: number;
    workspace: string;
    projectName: string;
    projectPath: string;
  } | null>(null);

  const resolveRouteProject = useCallback(
    ({ workspace, project }: ReturnType<typeof parseRoute>) => {
      if (!workspace || !project) return null;
      const listed = workspacesRef.current
        .find((candidate) => candidate.name === workspace)
        ?.projects.find((candidate) => candidate.name === project);
      const cached = routeProjectCacheRef.current;
      const epoch = openConnectionEpochRef.current;
      const cachedPath =
        cached &&
        cached.epoch === epoch &&
        cached.workspace === workspace &&
        cached.projectName === project
          ? cached.projectPath
          : "";
      return {
        workspace,
        projectName: project,
        projectPath: listed?.path ?? cachedPath,
      };
    },
    [],
  );

  const rememberRouteProject = useCallback(() => {
    const epoch = openConnectionEpochRef.current;
    const project = resolveRouteProject(readBrowserRoute());
    routeProjectCacheRef.current =
      epoch !== null && project?.projectPath ? { ...project, epoch } : null;
  }, [resolveRouteProject]);

  useLayoutEffect(() => {
    rememberRouteProject();
  }, [path, rememberRouteProject]);

  const taskContext = useCallback(
    (t: TaskState | undefined): [string | null, string | null] => {
      if (!t || !t.workspace || !t.projectPath) return [null, null];
      const projName = findProjectName(
        workspacesRef.current,
        t.workspace,
        t.projectPath,
      );
      return projName ? [t.workspace, projName] : [null, null];
    },
    [],
  );

  const getProjectHref = useCallback(
    (workspace: string, projectName: string) =>
      buildProjectHref(workspace, projectName),
    [],
  );

  const currentDraftRouteProjectName = useCallback(
    (
      project: { workspace: string; projectPath: string },
      tid: number | null,
    ): string | null => {
      const current = readBrowserRoute();
      if (current.tid !== (tid === null ? null : String(tid))) return null;
      const resolved = resolveRouteProject(current);
      return resolved?.workspace === project.workspace &&
        resolved.projectPath === project.projectPath
        ? resolved.projectName
        : null;
    },
    [resolveRouteProject],
  );

  const taskRoute = useCallback(
    (
      id: string,
      lookupTask: (tid: number) => TaskState | undefined,
    ): ReturnType<typeof parseRoute> => {
      if (id === "archive" || id === "import") {
        return { ...readBrowserRoute(), tid: id };
      }
      const archiveMatch = id.match(/^archive:(\d+)$/);
      const tid = parseInt(archiveMatch?.[1] ?? id, 10);
      if (isNaN(tid)) return { workspace: null, project: null, tid: null };
      const [workspace, project] = taskContext(lookupTask(tid));
      return { workspace, project, tid: id };
    },
    [taskContext],
  );

  const routeHref = useCallback(
    ({ workspace, project, tid }: ReturnType<typeof parseRoute>) => {
      if (tid === null)
        return workspace && project
          ? buildProjectHref(workspace, project)
          : "/";
      if (tid === "archive" || tid === "import")
        return buildScopedHref(workspace, project, `/${tid}`);
      if (tid.startsWith("archive:"))
        return buildScopedHref(
          workspace,
          project,
          `/archive/${tid.slice("archive:".length)}`,
        );
      return buildScopedHref(workspace, project, `/task/${tid}`);
    },
    [],
  );

  const getTaskHref = useCallback(
    (id: string) => routeHref(taskRoute(id, getPublishedTask)),
    [getPublishedTask, routeHref, taskRoute],
  );

  const navigate = useCallback(
    (destination: ReturnType<typeof parseRoute>, replace?: boolean) => {
      const href = routeHref(destination);
      if (replace) routerNavigateRef.current(href, true);
      else routerNavigateRef.current(href);
      rememberRouteProject();
    },
    [rememberRouteProject, routeHref],
  );

  const returnFromDeletedDraft = useCallback(
    (project: { workspace: string; projectPath: string }, tid: number) => {
      if (readBrowserRoute().tid !== String(tid)) return;
      const { workspace, projectPath } = project;
      const listed = findProjectName(
        workspacesRef.current,
        workspace,
        projectPath,
      );
      const cached = routeProjectCacheRef.current;
      const projectName =
        listed ??
        (cached &&
        cached.epoch === openConnectionEpochRef.current &&
        cached.workspace === workspace &&
        cached.projectPath === projectPath
          ? cached.projectName
          : null);
      if (projectName)
        navigate({ workspace, project: projectName, tid: null }, true);
    },
    [navigate],
  );

  const setActiveTaskId = useCallback(
    (id: string) => {
      navigate(taskRoute(id, getPublishedTask));
    },
    [getPublishedTask, navigate, taskRoute],
  );

  const navigateHome = useCallback(() => {
    navigate({ workspace: null, project: null, tid: null });
  }, [navigate]);

  const navigateToProject = useCallback(
    (workspace: string, project: string) => {
      navigate({ workspace, project, tid: null });
    },
    [navigate],
  );

  const connRef = useRef<Connection | null>(null);
  // Texts of the messages this client asked to un-send, by nonce: restored
  // to the composer once the agent confirms the withdrawal.
  const unsendRequestsRef = useRef(new Map<string, string>());
  // Track which tasks have had history requested (avoid duplicate requests), keyed by uuid
  const requestedHistoryRef = useRef(new Map<string, string>());
  const outboxReplayedEpochRef = useRef<number | null>(null);
  const outboxAttemptedNoncesRef = useRef(new Set<string>());
  const tasksListEpochRef = useRef<number | null>(null);
  const tasksListAcceptedTidsRef = useRef(new Set<number>());
  const tasksListPhaseRef = useRef<"awaiting" | "receiving" | "complete">(
    "awaiting",
  );
  const draftStateRef = useRef<DraftState>(createDraftState());
  const [draftRevision, setDraftRevision] = useState(0);
  const requestedProjectTypesRef = useRef(new Map<string, number>());
  const createRuntimeRef = useRef(
    new Map<
      EditorId,
      {
        correlationId: string;
        token: number;
        handle: ReturnType<typeof setTimeout>;
      }
    >(),
  );
  const saveRuntimeRef = useRef(
    new Map<
      number,
      {
        editorId: EditorId;
        formVersion: number;
        handle: ReturnType<typeof setTimeout>;
      }
    >(),
  );
  const createTokenRef = useRef(0);
  const correlationToEditorRef = useRef(new Map<string, EditorId>());
  const submissionCorrelationToEditorRef = useRef(new Map<string, EditorId>());
  const controlledOwnerByTidRef = useRef(
    new Map<number, ControlledDraftOwner>(),
  );
  const nextControlledOwnerLifetimeRef = useRef(0);
  const tombstoneTidToEditorRef = useRef(new Map<number, EditorId>());
  const expectedFocusRef = useRef(new Set<string>());
  const composerResetEpochRef = useRef(0);
  const executeDraftEffectsRef = useRef<
    (effects: readonly DraftEffect[]) => void
  >(() => {
    throw new Error("Draft effect executor is not installed");
  });

  const refreshDraftView = useCallback(() => {
    setDraftRevision((revision) => revision + 1);
  }, []);

  const rebuildDraftIndexes = useCallback(
    (state: DraftState) => {
      const previousOwners = controlledOwnerByTidRef.current;
      const nextOwners = new Map<number, ControlledDraftOwner>();
      correlationToEditorRef.current.clear();
      submissionCorrelationToEditorRef.current.clear();
      tombstoneTidToEditorRef.current.clear();
      for (const editorId of Object.keys(state.editors) as EditorId[]) {
        const { remote, desired } = getEditor(state, editorId);
        if (remote.kind === "creating") {
          correlationToEditorRef.current.set(remote.correlationId, editorId);
        }
        if (desired.kind === "submitting") {
          const { attempt } = desired;
          if (attempt.delivery === "atomic-create") {
            correlationToEditorRef.current.set(attempt.correlationId, editorId);
          } else if (attempt.phase === "awaiting-acceptance") {
            submissionCorrelationToEditorRef.current.set(
              attempt.messageCorrelationId,
              editorId,
            );
          }
        }
        if (remote.kind === "present") {
          const previous = previousOwners.get(remote.tid);
          nextOwners.set(
            remote.tid,
            previous?.editorId === editorId
              ? previous
              : {
                  editorId,
                  lifetime: ++nextControlledOwnerLifetimeRef.current,
                },
          );
          const uuid = tidToUuid.get(remote.tid);
          if (uuid) ordinaryDraftStore.retire(uuid);
        }
        if (remote.kind === "deleting") {
          tombstoneTidToEditorRef.current.set(remote.tid, editorId);
        }
      }
      controlledOwnerByTidRef.current = nextOwners;
    },
    [ordinaryDraftStore],
  );

  const bindTaskUuid = useCallback(
    (tid: number, uuid: string) => {
      const previousUuid = tidToUuid.get(tid);
      if (previousUuid !== undefined && previousUuid !== uuid)
        ordinaryDraftStore.retire(previousUuid);
      tidToUuid.set(tid, uuid);
      if (controlledOwnerByTidRef.current.has(tid))
        ordinaryDraftStore.retire(uuid);
    },
    [ordinaryDraftStore],
  );

  const removeTaskIdentity = useCallback(
    (tid: number) => {
      const uuid = tidToUuid.get(tid);
      if (uuid === undefined) return;
      ordinaryDraftStore.retire(uuid);
      removeTask(uuid);
      tidToUuid.delete(tid);
      requestedHistoryRef.current.delete(uuid);
    },
    [ordinaryDraftStore, removeTask],
  );

  const applyDraftEvent = useCallback(
    (event: DraftEvent) => {
      const previous = draftStateRef.current;
      const result = reduceDraft(previous, event);
      if (result.state === previous) return result;
      draftStateRef.current = result.state;
      if (controlledImageStore) {
        for (const key of Object.keys(previous.editors) as EditorId[]) {
          const editor = result.state.editors[key];
          if (!editor || editor.desired.kind === "none") {
            retireControlledImage(controlledImageStore, key);
          }
        }
      }
      rebuildDraftIndexes(result.state);
      refreshDraftView();
      return result;
    },
    [controlledImageStore, rebuildDraftIndexes, refreshDraftView],
  );

  const entryPointFor = useCallback(
    (projectPath: string, entryPointName: string) => {
      const candidates =
        draftStateRef.current.metadata.catalogs.get(projectPath);
      if (!candidates) {
        throw new Error(`Project entry points unavailable for ${projectPath}`);
      }
      const entryPoint = candidates.find(
        (candidate) => candidate.name === entryPointName,
      );
      if (!entryPoint) {
        throw new Error(`Unknown entry point: ${entryPointName}`);
      }
      return entryPoint;
    },
    [],
  );

  const projectDraft = useCallback(
    (tid: number, form: ProjectedDraftForm) => {
      const task = findByTid(tid);
      const updated = projectDraftTask(
        task,
        tid,
        form,
        draftStateRef.current.metadata.catalogs,
      );
      if (updated !== task) commitTask(updated.uuid, updated);
    },
    [commitTask],
  );

  const requestTaskHistory = useCallback((tid: number) => {
    const task = findByTid(tid);
    if (!task) throw new Error(`History request requires task ${tid}`);
    if (requestedHistoryRef.current.get(task.uuid) === "") return;
    if (!connRef.current?.requestHistory(tid, "")) {
      throw new Error(`History request failed for ${tid}`);
    }
    requestedHistoryRef.current.set(task.uuid, "");
  }, []);

  const sendMessageAttempt = useCallback(
    (
      tid: number,
      content: ContentBlock[],
      nonce: string,
      attachmentNames?: string[],
    ) => {
      outbox.add({
        tid,
        nonce,
        content,
        createdAt: Date.now(),
        attachmentNames,
      });
      if (outboxReplayedEpochRef.current !== openConnectionEpochRef.current) {
        outboxAttemptedNoncesRef.current.add(nonce);
      }
      connRef.current?.sendMessage(tid, content, nonce);
    },
    [],
  );

  const sendRealTask = useCallback(
    (uuid: string, text: string, images?: readonly ImageAttachment[]) => {
      const task = liveStates.get(uuid);
      if (!task || task.tid === null) {
        throw new Error(`Cannot send to missing real task ${uuid}`);
      }
      const content = buildContentBlocks(text, images);
      const displayContent =
        content as import("./protocol").AssistantContentBlock[];
      const nonce = crypto.randomUUID();
      sendMessageAttempt(
        task.tid,
        content,
        nonce,
        images?.map(({ name }) => name),
      );
      const msgIdCounter = task.msgIdCounter + 1;
      const updated: TaskState = {
        ...task,
        msgIdCounter,
        messages: [
          ...task.messages,
          {
            id: `opt-${msgIdCounter}`,
            type: "user",
            content: displayContent,
            ackState: 4,
            pending: true,
            nonce,
            isProvisional: true,
          },
        ],
        isProcessing: true,
        suggestions: undefined,
      };
      commitTask(uuid, updated);
    },
    [sendMessageAttempt, commitTask],
  );

  const saveDraft = useCallback(
    (tid: number, draft: string) => {
      const recovery = outbox
        .byTid(tid)
        .find((entry) => entry.recoveredDraft !== undefined);
      if (recovery) {
        const entry =
          recovery.recoveredDraft === draft
            ? recovery
            : {
                ...recovery,
                nonce: crypto.randomUUID(),
                recoveredDraft: draft,
              };
        if (entry !== recovery) outbox.add(entry);
        connRef.current?.saveDraft(tid, draft, entry.nonce);
      } else {
        connRef.current?.saveDraft(tid, draft);
      }
      const task = findByTid(tid);
      if (!task) return;
      let updated: TaskState | null = null;
      if (!draft && task.serverDraft !== undefined) {
        updated = { ...task, serverDraft: undefined };
      }
      if (task.status === "pending" && task.messages.length === 0) {
        const title = draft.trim().split("\n")[0]?.slice(0, 100) || undefined;
        if (title !== (updated ?? task).title) {
          updated = { ...(updated ?? task), title };
        }
      }
      if (!updated) return;
      commitTask(task.uuid, updated);
    },
    [commitTask],
  );

  const executeDraftEffects = useCallback(
    (effects: readonly DraftEffect[]) => {
      for (const effect of effects) {
        switch (effect.type) {
          case "schedule-create": {
            const existing = createRuntimeRef.current.get(effect.editorId);
            if (existing) {
              if (existing.correlationId !== effect.correlationId) {
                throw new Error(
                  "Different draft creation is already scheduled",
                );
              }
              break;
            }
            const token = ++createTokenRef.current;
            const handle = setTimeout(() => {
              const current = createRuntimeRef.current.get(effect.editorId);
              if (
                !current ||
                current.correlationId !== effect.correlationId ||
                current.token !== token
              )
                return;
              createRuntimeRef.current.delete(effect.editorId);
              const result = applyDraftEvent({
                type: "create-timer-due",
                editorId: effect.editorId,
                correlationId: effect.correlationId,
              });
              executeDraftEffectsRef.current(result.effects);
            }, effect.delayMs);
            createRuntimeRef.current.set(effect.editorId, {
              correlationId: effect.correlationId,
              token,
              handle,
            });
            break;
          }

          case "cancel-create-schedule": {
            const existing = createRuntimeRef.current.get(effect.editorId);
            if (existing?.correlationId === effect.correlationId) {
              clearTimeout(existing.handle);
              createRuntimeRef.current.delete(effect.editorId);
            }
            break;
          }

          case "create-task": {
            const editor = getEditor(draftStateRef.current, effect.editorId);
            connRef.current?.createTask(
              editor.project.workspace,
              editor.project.projectPath,
              effect.entryPoint,
              effect.content
                ? buildContentBlocks(effect.content.text, effect.content.images)
                : undefined,
              effect.agent,
              effect.correlationId,
            );
            break;
          }

          case "ensure-draft-save": {
            const existing = saveRuntimeRef.current.get(effect.tid);
            if (
              existing &&
              existing.editorId === effect.editorId &&
              existing.formVersion === effect.formVersion
            )
              break;
            if (existing) clearTimeout(existing.handle);
            const handle = setTimeout(() => {
              const current = saveRuntimeRef.current.get(effect.tid);
              if (
                !current ||
                current.editorId !== effect.editorId ||
                current.formVersion !== effect.formVersion ||
                current.handle !== handle
              )
                return;
              saveRuntimeRef.current.delete(effect.tid);
              const result = applyDraftEvent({
                type: "save-timer-due",
                editorId: effect.editorId,
                tid: effect.tid,
                formVersion: effect.formVersion,
              });
              executeDraftEffectsRef.current(result.effects);
            }, effect.delayMs);
            saveRuntimeRef.current.set(effect.tid, {
              editorId: effect.editorId,
              formVersion: effect.formVersion,
              handle,
            });
            break;
          }

          case "cancel-draft-save": {
            const existing = saveRuntimeRef.current.get(effect.tid);
            if (
              existing &&
              existing.editorId === effect.editorId &&
              existing.formVersion === effect.formVersion
            ) {
              clearTimeout(existing.handle);
              saveRuntimeRef.current.delete(effect.tid);
            }
            break;
          }

          case "set-entry-point":
            connRef.current?.setEntryPoint(effect.tid, effect.entryPoint);
            break;

          case "set-agent":
            connRef.current?.setAgentName(effect.tid, effect.agent);
            break;

          case "set-draft":
            connRef.current?.saveDraft(effect.tid, effect.text);
            break;

          case "clear-task-draft":
            saveDraft(effect.tid, "");
            break;

          case "project-draft":
            projectDraft(effect.tid, effect.form);
            break;

          case "delete-task": {
            const uuid = tidToUuid.get(effect.tid);
            if (uuid !== undefined) unpublishTask(uuid);
            const editor = getEditor(draftStateRef.current, effect.editorId);
            returnFromDeletedDraft(editor.project, effect.tid);
            connRef.current?.deleteTask(effect.tid);
            break;
          }

          case "send-first-message":
            requestTaskHistory(effect.tid);
            sendMessageAttempt(
              effect.tid,
              buildContentBlocks(effect.content.text, effect.content.images),
              effect.messageCorrelationId,
            );
            break;

          default:
            assertNeverDraftEffect(effect);
        }
      }
    },
    [
      applyDraftEvent,
      returnFromDeletedDraft,
      ordinaryDraftStore,
      projectDraft,
      requestTaskHistory,
      saveDraft,
      sendMessageAttempt,
      unpublishTask,
    ],
  );
  executeDraftEffectsRef.current = executeDraftEffects;

  const materializeDraftTask = useCallback(
    (
      tid: number,
      workspace: string,
      projectPath: string,
      parentTid: number | undefined,
      relationType: string | undefined,
      desired: Exclude<
        ReturnType<typeof getEditor>["desired"],
        { kind: "none" }
      >,
    ) => {
      assertResolvedDraftForm(desired);
      const entryPoint = entryPointFor(projectPath, desired.entryPoint);
      const submitting = desired.kind === "submitting";
      const title = submitting
        ? undefined
        : desired.text.trim().split("\n")[0]?.slice(0, 100) || undefined;
      const base = makeTaskState(
        tid,
        false,
        false,
        title,
        submitting,
        workspace,
        projectPath,
        parentTid,
        relationType,
        "pending",
        false,
        false,
        false,
        false,
        entryPoint.task_type,
        false,
        undefined,
        undefined,
        desired.agent,
        desired.entryPoint,
      );
      const task: TaskState = {
        ...base,
        everLoaded: submitting,
      };
      bindTaskUuid(tid, task.uuid);
      commitTask(task.uuid, task);
    },
    [bindTaskUuid, entryPointFor, commitTask],
  );

  const releaseTombstonedActivity = useCallback(
    (
      editorId: EditorId,
      observation: TaskObservation,
    ): readonly DraftEffect[] | null => {
      if (!isActiveObservation(observation)) return null;
      const result = applyDraftEvent({
        type: "task-observed",
        editorId,
        observation,
      });
      return result.effects;
    },
    [applyDraftEvent],
  );

  // -- Live stdout message handler --
  // Reduces against the mutable liveStates map (synchronous), fires
  // notifications, then enqueues a Preact state update for rendering.
  const handleUnconfirmedUserMessage = useCallback(
    (tid: number, msg: AgnosticEvent, correlationId?: string) => {
      if (tombstoneTidToEditorRef.current.has(tid)) return;
      const editorId = controlledOwnerByTidRef.current.get(tid)?.editorId;
      const effects = editorId
        ? applyDraftEvent({
            type: "task-observed",
            editorId,
            observation: { tid, hasMessages: true },
          }).effects
        : [];
      const uuid = tidToUuid.get(tid);
      if (!uuid) {
        executeDraftEffectsRef.current(effects);
        return;
      }
      const prev = liveStates.get(uuid) ?? {
        ...makeTaskState(tid, true),
        uuid,
      };
      const meta = (msg as Record<string, unknown>).meta as
        | CydoMeta
        | undefined;
      const content = ((msg as Record<string, unknown>).content as
        | import("./protocol").AssistantContentBlock[]
        | undefined) ?? [
        { type: "text" as const, text: extractTextContent(msg) },
      ];

      // If a local ackState=4 placeholder with this nonce exists, upgrade it
      // to ackState=3 (backend acked). Otherwise insert a fresh ackState=3 bubble.
      let messages = prev.messages;
      if (correlationId) {
        const idx = messages.findIndex(
          (m) => m.type === "user" && m.nonce === correlationId,
        );
        if (idx >= 0) {
          messages = messages.map((m, i) =>
            i === idx
              ? {
                  ...m,
                  ackState: 3 as const,
                  pending: true,
                  isProvisional: true,
                }
              : m,
          );
          const updated = { ...prev, messages };
          commitTask(uuid, updated);
          executeDraftEffectsRef.current(effects);
          return;
        }
      }

      const msgIdCounter = prev.msgIdCounter + 1;
      const updated = {
        ...prev,
        msgIdCounter,
        messages: [
          ...messages,
          {
            id: `pending-${msgIdCounter}`,
            type: "user" as const,
            content,
            ackState: 3 as const,
            pending: true,
            nonce: correlationId,
            cydoMeta: meta,
            isProvisional: true,
          },
        ],
      };
      commitTask(uuid, updated);
      executeDraftEffectsRef.current(effects);
    },
    [applyDraftEvent, commitTask],
  );

  const handleTaskMessage = useCallback(
    (
      dirty: Set<string>,
      tid: number,
      msg: AgnosticEvent,
      seq?: number,
      ts?: number,
    ) => {
      if (tombstoneTidToEditorRef.current.has(tid)) return;
      const editorId = controlledOwnerByTidRef.current.get(tid)?.editorId;
      const effects = editorId
        ? applyDraftEvent({
            type: "task-observed",
            editorId,
            observation: { tid, hasMessages: true },
          }).effects
        : [];
      const uuid = tidToUuid.get(tid);
      if (!uuid) {
        executeDraftEffectsRef.current(effects);
        return;
      }
      const prev = liveStates.get(uuid) ?? {
        ...makeTaskState(tid, true),
        uuid,
      };
      const batch = batchFor(uuid);
      let updated = reduceMessageIn(batch, prev, msg, seq, ts);
      if (hasHistoryBoundary(msg) && seq !== undefined)
        updated = replaceHistoryBoundaryIn(batch, updated, msg, seq);
      let recoveredDraft: string | undefined;
      if (
        msg.type === "user_message/consumed" &&
        msg.consumed_as === "cancelled" &&
        msg.correlation_id
      ) {
        recoveredDraft = unsendRequestsRef.current.get(msg.correlation_id);
        if (recoveredDraft !== undefined)
          unsendRequestsRef.current.delete(msg.correlation_id);
      }
      if (isReplaying(updated)) {
        updated = batch.object(updated);
        updated.historyReceived = (updated.historyReceived ?? 0) + 1;
      }
      if (recoveredDraft !== undefined)
        commitTask(uuid, { ...updated, inputDraft: recoveredDraft });
      else markDirty(dirty, uuid, updated);
      executeDraftEffectsRef.current(effects);
    },
    [applyDraftEvent, commitTask],
  );

  const handleDraftUpdatedMessage = useCallback(
    (msg: DraftUpdatedMessage, receipt: DraftUpdatedReceipt) => {
      const { tid, old_draft, new_draft } = msg;
      if (tombstoneTidToEditorRef.current.has(tid)) return;
      const ownerAtDrain = controlledOwnerByTidRef.current.get(tid);
      if (
        receipt.kind === "controlled" &&
        (!ownerAtDrain ||
          !sameControlledDraftOwner(ownerAtDrain, receipt.owner))
      )
        return;
      const result = ownerAtDrain
        ? applyDraftEvent({
            type: "task-observed",
            editorId: ownerAtDrain.editorId,
            observation: { tid, text: new_draft, oldText: old_draft },
          })
        : null;
      const task = findByTid(tid);
      if (task) {
        const updated = {
          ...task,
          serverDraft: new_draft || undefined,
        };
        commitTask(task.uuid, updated, "if-present");
        if (receipt.kind === "ordinary" && !ownerAtDrain)
          ordinaryDraftStore.applyRemote(task.uuid, {
            old_draft,
            new_draft,
          });
      }
      if (result) executeDraftEffects(result.effects);
    },
    [applyDraftEvent, executeDraftEffects, ordinaryDraftStore, commitTask],
  );

  const applyTaskSnapshotEntry = useCallback(
    (entry: TaskSnapshotEntry) => {
      const existing = findByTid(entry.tid);
      const observation = taskObservationFromEntry(
        entry,
        (existing?.messages.length ?? 0) > 0,
      );
      const tombstoneEditorId = tombstoneTidToEditorRef.current.get(entry.tid);
      const effects: DraftEffect[] = [];
      if (tombstoneEditorId) {
        const released = releaseTombstonedActivity(
          tombstoneEditorId,
          observation,
        );
        if (!released) return null;
        effects.push(...released);
      }
      const updated = taskStateFromEntry(
        entry,
        existing,
        tidToUuid.get(entry.tid),
      );
      bindTaskUuid(entry.tid, updated.uuid);
      const owner = controlledOwnerByTidRef.current.get(entry.tid);
      if (owner) {
        effects.push(
          ...applyDraftEvent({
            type: "task-observed",
            editorId: owner.editorId,
            observation,
          }).effects,
        );
      }
      return { updated, effects };
    },
    [applyDraftEvent, bindTaskUuid, releaseTombstonedActivity],
  );

  const showServerError = useCallback((message: string, tid?: number) => {
    console.error("Server error:", message, "tid:", tid);
    setServerError({ message, tid });
  }, []);

  const recoverSubmission = useCallback(
    (editorId: EditorId, tid?: number) => {
      const { desired, remote } = getEditor(draftStateRef.current, editorId);
      if (desired.kind !== "submitting") return false;
      const boundTid = remote.kind === "present" ? remote.tid : undefined;
      if (tid !== boundTid)
        throw new Error("Submission rejection has the wrong task ID");
      const { attempt } = desired;
      if (
        attempt.delivery === "send-when-present" &&
        attempt.phase === "awaiting-acceptance"
      ) {
        outbox.remove(attempt.messageCorrelationId);
      }
      executeDraftEffects(
        applyDraftEvent({
          type: "submission-rejected",
          editorId,
          tid,
        }).effects,
      );
      return desired;
    },
    [applyDraftEvent, executeDraftEffects],
  );

  const handleControlMessage = useCallback(
    (msg: Exclude<ControlMessage, DraftUpdatedMessage>) => {
      const controlledTid =
        msg.type === "task_updated"
          ? msg.task.tid
          : "tid" in msg && typeof msg.tid === "number"
            ? msg.tid
            : undefined;
      if (
        controlledTid !== undefined &&
        msg.type !== "task_deleted" &&
        msg.type !== "task_updated" &&
        tombstoneTidToEditorRef.current.has(controlledTid)
      )
        return;
      switch (msg.type) {
        case "workspaces_list": {
          rememberRouteProject();
          workspacesRef.current = msg.workspaces;
          rememberRouteProject();
          setWorkspaces(msg.workspaces);
          setConnected(true);
          executeDraftEffects(
            applyDraftEvent({
              type: "workspace-draft-defaults",
              projects: msg.workspaces.flatMap((workspace) =>
                workspace.projects.map(({ path }) => ({
                  project: { workspace: workspace.name, projectPath: path },
                  entryPoint: workspace.default_task_type || null,
                  agent: workspace.default_agent || null,
                })),
              ),
            }).effects,
          );
          break;
        }
        case "scan_status": {
          setScanState(msg.scanning ? "scanning" : "idle");
          break;
        }
        case "task_types_list": {
          setEntryPoints(msg.entry_points);
          setTypeInfo(msg.type_info);
          const entryPoint = msg.default_task_type ?? "";
          executeDraftEffects(
            applyDraftEvent({ type: "global-draft-defaults", entryPoint })
              .effects,
          );
          break;
        }
        case "project_task_types_list": {
          const { project_path, entry_points, type_info } = msg;
          executeDraftEffects(
            applyDraftEvent({
              type: "project-catalog",
              projectPath: project_path,
              catalog: entry_points,
            }).effects,
          );
          setProjectTypeInfo((prev) => {
            const next = new Map(prev);
            next.set(project_path, type_info);
            return next;
          });
          break;
        }
        case "agents_list": {
          executeDraftEffects(
            applyDraftEvent({
              type: "agents-list",
              agents: msg.agents,
              defaultAgent: msg.default_agent ?? "",
            }).effects,
          );
          break;
        }
        case "task_created": {
          const tid = msg.tid;
          const workspace = msg.workspace || "";
          const projectPath = msg.project_path || "";
          const parentTid = msg.parent_tid || undefined;
          const relationType = msg.relation_type || undefined;

          const correlationId = msg.correlation_id;
          const editorId = correlationId
            ? correlationToEditorRef.current.get(correlationId)
            : undefined;
          const before = editorId
            ? getEditor(draftStateRef.current, editorId)
            : undefined;
          if (editorId && correlationId && before?.remote.kind === "creating") {
            if (
              before.project.workspace !== workspace ||
              before.project.projectPath !== projectPath
            ) {
              throw new Error(
                "Draft creation acknowledgement has wrong project",
              );
            }
            const desired = before.desired;
            const attachedProjectName =
              draftStateRef.current.newTaskByProject[
                createProjectKey(workspace, projectPath)
              ] === editorId
                ? currentDraftRouteProjectName(before.project, null)
                : null;
            const result = applyDraftEvent({
              type: "task-created",
              editorId,
              correlationId,
              tid,
              messageCorrelationId:
                desired.kind === "submitting" &&
                desired.attempt.phase === "waiting-for-tid"
                  ? crypto.randomUUID()
                  : undefined,
              successor:
                desired.kind === "none" ? undefined : mintCompositionId(),
            });
            expectedFocusRef.current.add(`0:${tid}`);
            if (desired.kind !== "none") {
              materializeDraftTask(
                tid,
                workspace,
                projectPath,
                parentTid,
                relationType,
                desired,
              );
            }
            if (
              desired.kind === "submitting" &&
              desired.attempt.delivery === "atomic-create"
            )
              requestTaskHistory(tid);
            executeDraftEffects(result.effects);
            if (desired.kind !== "none" && attachedProjectName) {
              navigate(
                { workspace, project: attachedProjectName, tid: String(tid) },
                true,
              );
            }
            break;
          }

          // Non-draft task_created (unicast to this client for a task created
          // without a matching draft — e.g. from another code path).
          const t = makeTaskState(
            tid,
            false,
            false,
            undefined,
            false,
            workspace,
            projectPath,
            parentTid,
            relationType,
            "pending",
          );
          bindTaskUuid(tid, t.uuid);
          commitTask(t.uuid, t);
          break;
        }
        case "tasks_list": {
          const epoch = openConnectionEpochRef.current;
          if (!isCurrentOpenEpoch(epoch))
            throw new Error("Tasks list arrived outside an open connection");
          if (typeof msg.complete !== "boolean" || !Array.isArray(msg.tasks))
            throw new Error("Invalid tasks list packet");
          if (tasksListPhaseRef.current === "complete")
            throw new Error("Tasks list arrived after completion");

          const packetTids = new Set<number>();
          for (const rawEntry of msg.tasks as unknown[]) {
            if (typeof rawEntry !== "object" || rawEntry === null)
              throw new Error("Invalid tasks list entry");
            const entry = rawEntry as Record<string, unknown>;
            const tid = entry.tid;
            const childCount = entry.child_count;
            if (
              typeof tid !== "number" ||
              !Number.isSafeInteger(tid) ||
              tid <= 0 ||
              typeof childCount !== "number" ||
              !Number.isSafeInteger(childCount) ||
              childCount < 0 ||
              typeof entry.alive !== "boolean" ||
              typeof entry.resumable !== "boolean" ||
              typeof entry.isProcessing !== "boolean"
            )
              throw new Error("Invalid tasks list entry");
            if (
              packetTids.has(tid) ||
              tasksListAcceptedTidsRef.current.has(tid)
            )
              throw new Error("Tasks list contains a duplicate tid");
            packetTids.add(tid);
          }
          for (const tid of packetTids)
            tasksListAcceptedTidsRef.current.add(tid);

          const updates = new Map<string, TaskState>();
          const effects: DraftEffect[] = [];
          for (const entry of msg.tasks) {
            const result = applyTaskSnapshotEntry(entry);
            if (!result) continue;
            updates.set(result.updated.uuid, result.updated);
            effects.push(...result.effects);
          }
          commitTasks(updates);
          executeDraftEffects(effects);
          if (msg.complete) {
            tasksListPhaseRef.current = "complete";
            tasksListEpochRef.current = epoch;
            setTasksListEpoch(epoch);
          } else {
            tasksListPhaseRef.current = "receiving";
          }
          break;
        }
        case "task_updated": {
          const { tid, isProcessing, status, error } = msg.task;
          const previousStatus = findByTid(tid)?.status;
          const result = applyTaskSnapshotEntry(msg.task);
          if (!result) break;
          const { updated, effects } = result;
          commitTask(updated.uuid, updated);
          executeDraftEffects(effects);
          const owner = controlledOwnerByTidRef.current.get(tid);
          if (!owner) break;
          const { desired } = getEditor(draftStateRef.current, owner.editorId);
          if (desired.kind === "submitting") {
            if (isProcessing) {
              applyDraftEvent({
                type: "submission-accepted",
                editorId: owner.editorId,
                tid,
              });
            } else if (
              status === "failed" &&
              previousStatus !== "failed" &&
              recoverSubmission(owner.editorId, tid) &&
              error
            ) {
              showServerError(error, tid);
            }
          }
          break;
        }
        case "cydo/submission_rejected": {
          // Only the live submission receipt recovers a draft. History
          // diagnostics are display events and never settle the outbox.
          const { correlation_id, tid, kind, reason, attachment } = msg;
          const attachmentError = (name?: string) =>
            `Could not send ${name ?? `image ${(attachment ?? 0) + 1}`}: ${reason}`;
          const editorId =
            submissionCorrelationToEditorRef.current.get(correlation_id) ??
            correlationToEditorRef.current.get(correlation_id);
          if (editorId) {
            const recovered = recoverSubmission(editorId, tid);
            if (
              recovered &&
              kind !== "validation" &&
              kind !== "native_undo_refused"
            ) {
              showServerError(
                kind === "attachment_rejected"
                  ? attachmentError(
                      attachment === undefined
                        ? undefined
                        : recovered.images[attachment]?.name,
                    )
                  : reason,
                tid,
              );
            }
            break;
          }
          if (tid === undefined) break;
          const entry = outbox
            .byTid(tid)
            .find(
              ({ nonce, recoveredDraft }) =>
                nonce === correlation_id && recoveredDraft === undefined,
            );
          // A history reload may already have retired the entry and taken
          // ownership of restoring the displaced text.
          if (!entry) break;
          const task = findByTid(tid);
          let recovered = false;
          if (task) {
            const updated = rejectOrdinarySubmission(task, correlation_id);
            if (updated !== task) commitTask(task.uuid, updated);

            if (kind !== "task_unavailable") {
              const text = canonicalUserTextFromContentAndMeta(
                entry.content as ContentBlock[],
              );
              if (text) {
                const current = ordinaryDraftStore.ensure(
                  task.uuid,
                  task.serverDraft ?? "",
                );
                const draft = current ? `${current}\n\n${text}` : text;
                // Replace the replayable entry before attempting the network write.
                outbox.add({ ...entry, content: [], recoveredDraft: draft });
                ordinaryDraftStore.write(task.uuid, draft);
                saveDraft(tid, draft);
                recovered = true;
              }
            }
          }
          if (!recovered) outbox.remove(correlation_id);
          if (!task) break;
          if (kind === "attachment_rejected") {
            showServerError(
              attachmentError(
                attachment === undefined
                  ? undefined
                  : entry.attachmentNames?.[attachment],
              ),
              tid,
            );
            break;
          }
          const hasDiagnostic =
            task.messages.some(
              (message) =>
                message.diagnostic?.subject === "Failed to submit message" &&
                canonicalUserTextFromDisplayMessage(message) === reason,
            ) ||
            [...task.blocks.values()].some(
              (block) =>
                block.type === "diagnostic" &&
                block.subject === "Failed to submit message" &&
                block.text === reason,
            );
          if (!hasDiagnostic) showServerError(reason, tid);
          break;
        }
        case "focus_hint": {
          const fromTid = msg.from_tid;
          const toTid = msg.to_tid;
          const expectedKey = `${fromTid}:${toTid}`;
          if (expectedFocusRef.current.delete(expectedKey)) break;
          if (
            tombstoneTidToEditorRef.current.has(fromTid) ||
            tombstoneTidToEditorRef.current.has(toTid)
          )
            break;
          const currentId = getActiveTaskId();
          const currentTid = currentId !== null ? parseInt(currentId, 10) : NaN;
          const matches =
            fromTid === 0
              ? currentId === null || isNaN(currentTid)
              : currentId === String(fromTid);
          if (matches && tidToUuid.has(toTid)) {
            navigate(taskRoute(String(toTid), findByTid));
          }
          break;
        }
        case "task_reload": {
          const { tid } = msg;
          if (tombstoneTidToEditorRef.current.has(tid)) break;
          const t = findByTid(tid);
          if (!t) break;
          outbox.removeForTask(tid, true);
          requestedHistoryRef.current.delete(t.uuid);

          const isEdit = msg.reason === "edit";
          const excludedNativeUuid =
            msg.reason === "continuation" ? msg.excluded_user_uuid : undefined;
          // opensCycle: first reload of a new reconciliation cycle
          const opensCycle = t.pendingHistoryReplies === 0;

          let nextDrafts: TaskState["preReloadDrafts"];
          if (opensCycle) {
            if (isEdit) {
              nextDrafts = undefined;
            } else {
              nextDrafts = snapshotUserDrafts(t, excludedNativeUuid);
            }
          } else {
            // Intermediate reload within an open cycle — preserve the snapshot
            // captured at cycle start so the final diff still has it.
            nextDrafts = excludeReloadDraftUuid(
              t.preReloadDrafts,
              excludedNativeUuid,
            );
          }

          const reset = resetTaskForReload(t, nextDrafts);

          // Re-request history if this is the active task — the useEffect
          // won't re-fire because activeTaskId hasn't changed.
          let final = reset;
          if (String(tid) === getActiveTaskId()) {
            const workspace =
              t.status === "importable"
                ? (readBrowserRoute().workspace ?? "")
                : "";
            if (connRef.current?.requestHistory(tid, workspace)) {
              requestedHistoryRef.current.set(t.uuid, workspace);
              final = {
                ...reset,
                pendingHistoryReplies: reset.pendingHistoryReplies + 1,
              };
            }
          }

          commitTask(t.uuid, final, "if-present");
          break;
        }
        case "task_history_start": {
          const { tid, total } = msg;
          if (tombstoneTidToEditorRef.current.has(tid)) break;
          const t0 = findByTid(tid);
          if (!t0) break;
          const t = beginTaskHistoryReplay(t0, total);
          commitTask(t0.uuid, t, "if-present");
          break;
        }
        case "task_history_end": {
          const { tid } = msg;
          if (tombstoneTidToEditorRef.current.has(tid)) break;
          const t0 = findByTid(tid);
          if (!t0) break;

          const nextPending = Math.max(0, t0.pendingHistoryReplies - 1);

          if (nextPending > 0) {
            // Not yet the final reply of this cycle — just decrement and wait.
            const t = {
              ...t0,
              historyTotal: undefined,
              historyReceived: undefined,
              pendingHistoryReplies: nextPending,
            };
            commitTask(t0.uuid, t, "if-present");
            break;
          }

          // Cycle is closing — compute inputDraft by multiset-subtracting the
          // pre-reload snapshot against the canonical user texts in the final
          // replayed messages (both sides use canonicalUserTextFromDisplayMessage).
          const inputDraft = reconcileInputDraft(t0);

          const t = {
            ...t0,
            historyLoaded: true,
            everLoaded: true,
            historyTotal: undefined,
            historyReceived: undefined,
            preReloadDrafts: undefined,
            pendingHistoryReplies: 0,
            inputDraft,
            sessionStatus: t0.isProcessing ? t0.sessionStatus : null,
          };
          commitTask(t0.uuid, t, "if-present");
          break;
        }
        case "title_update": {
          const { tid, title } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, title };
          commitTask(t.uuid, updated, "if-present");
          break;
        }
        case "suggestions_update": {
          const { tid, suggestions } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, suggestions };
          commitTask(t.uuid, updated, "if-present");
          break;
        }
        case "task_deleted": {
          const { tid } = msg;
          const editorId =
            controlledOwnerByTidRef.current.get(tid)?.editorId ??
            tombstoneTidToEditorRef.current.get(tid);
          const deletedSlot = editorId
            ? getEditor(draftStateRef.current, editorId)
            : null;
          const deletedProject = deletedSlot?.project ?? null;
          const wasDeleting = deletedSlot?.remote.kind === "deleting";
          const result = editorId
            ? applyDraftEvent({ type: "task-deleted", editorId, tid })
            : null;
          outbox.removeForTask(tid);
          removeTaskIdentity(tid);
          if (result) executeDraftEffects(result.effects);
          if (deletedProject && !wasDeleting) {
            returnFromDeletedDraft(deletedProject, tid);
          }
          break;
        }
        case "history_operations": {
          const { tid, history_operations } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, historyOperations: history_operations };
          commitTask(t.uuid, updated, "if-present");
          break;
        }
        case "undo_preview": {
          const { tid, messages_removed, count_unit } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const undoPending: UndoPending = {
            anchor: t.undoPending?.anchor ?? "",
            kind: count_unit,
            messagesRemoved: messages_removed,
            canRevertFiles: t.undoPending?.canRevertFiles ?? false,
            retainsPrompt: t.undoPending?.retainsPrompt ?? false,
            supportsFileRevert: t.undoPending?.supportsFileRevert ?? true,
          };
          const updated = {
            ...t,
            undoPending,
          };
          commitTask(t.uuid, updated, "if-present");
          break;
        }
        case "undo_result": {
          const { tid, output } = msg;
          const t = findByTid(tid);
          if (!t) break;
          if (output) {
            const updated = { ...t, undoResult: output };
            commitTask(t.uuid, updated);
            const { uuid } = t;
            setTimeout(() => {
              const cur = liveStates.get(uuid);
              if (!cur) return;
              const cleared = { ...cur, undoResult: null };
              commitTask(uuid, cleared);
            }, 8000);
          }
          break;
        }
        case "ask_user_question": {
          const { tid, tool_use_id, questions } = msg;
          const t = findByTid(tid);
          if (!t) break;
          // Empty tool_use_id signals that the question was answered (clear the form)
          const pendingAskUser = tool_use_id
            ? { toolUseId: tool_use_id, questions }
            : null;
          const updated = { ...t, pendingAskUser };
          commitTask(t.uuid, updated);
          break;
        }
        case "permission_prompt": {
          const { tid, tool_use_id, tool_name, input, reason, expires_at } =
            msg;
          const t = findByTid(tid);
          if (!t) break;
          // Empty tool_use_id signals clear (prompt resolved)
          const pendingPermission = tool_use_id
            ? {
                toolUseId: tool_use_id,
                toolName: tool_name,
                input,
                reason,
                expiresAt: expires_at,
              }
            : null;
          const updated = { ...t, pendingPermission };
          commitTask(t.uuid, updated);
          break;
        }
        case "server_status": {
          setDevMode(msg.dev_mode ?? false);
          setUi(msg.ui);
          heicConversionRef.current = msg.heic_conversion;
          setHeicConversion(msg.heic_conversion);
          const serverBuildId = msg.build_id ?? "";
          if (
            serverBuildId.length > 0 &&
            localBuildId.length > 0 &&
            serverBuildId !== localBuildId
          ) {
            setLocalNotices((prev) => ({
              ...prev,
              frontend_update: {
                level: "info",
                description: "This page is running an outdated CyDo UI.",
                impact: "Reload to load the current frontend.",
                action: "Reload",
                action_kind: "reload",
              },
            }));
          } else {
            setLocalNotices((prev) => {
              if (!("frontend_update" in prev)) return prev;
              const { frontend_update: _, ...rest } = prev;
              return rest;
            });
          }
          break;
        }
        case "notices_list": {
          setNotices(msg.notices);
          if (!initialNoticeLoadRef.current) {
            const newIds = Object.keys(msg.notices).filter(
              (id) => !prevNoticeIdsRef.current.has(id),
            );
            for (const id of newIds) {
              const notice = msg.notices[id]!;
              addToastRef.current(
                notice.level === "alert" ? "error" : notice.level,
                notice.description,
              );
            }
          }
          prevNoticeIdsRef.current = new Set(Object.keys(msg.notices));
          initialNoticeLoadRef.current = false;
          break;
        }
        case "agent_usage": {
          setAgentUsage((prev) => ({
            ...prev,
            [msg.profile]: msg,
          }));
          break;
        }
        case "error": {
          const { message, tid, operation } = msg;
          if (operation === "undo_preview" && tid !== undefined) {
            const task = findByTid(tid);
            if (task?.undoPending?.kind === "requesting") {
              commitTask(
                task.uuid,
                { ...task, undoPending: null },
                "if-present",
              );
            }
          }
          showServerError(message, tid);
          break;
        }
      }
    },
    [
      applyDraftEvent,
      bindTaskUuid,
      currentDraftRouteProjectName,
      navigate,
      rememberRouteProject,
      returnFromDeletedDraft,
      taskRoute,
      executeDraftEffects,
      materializeDraftTask,
      removeTaskIdentity,
      applyTaskSnapshotEntry,
      requestTaskHistory,
      recoverSubmission,
      ordinaryDraftStore,
      saveDraft,
      showServerError,
      isCurrentOpenEpoch,
      commitTask,
      commitTasks,
    ],
  );

  useEffect(() => {
    const conn = new Connection();
    connRef.current = conn;

    // Buffer incoming messages and flush on rAF so that hundreds of replay
    // messages are processed in a single render pass instead of one-per-message.
    type BufferedPayload =
      | {
          kind: "task";
          tid: number;
          msg: AgnosticEvent;
          seq?: number;
          ts?: number;
        }
      | {
          kind: "historyBoundary";
          tid: number;
          msg: HistoryBoundaryEvent;
          seq: number;
        }
      | {
          kind: "unconfirmed";
          tid: number;
          msg: AgnosticEvent;
          correlationId?: string;
        }
      | { kind: "agentAck"; tid: number; nonce: string }
      | {
          kind: "draftUpdated";
          msg: DraftUpdatedMessage;
          receipt: DraftUpdatedReceipt;
        }
      | {
          kind: "control";
          msg: Exclude<ControlMessage, DraftUpdatedMessage>;
        };
    type BufferedMsg = BufferedPayload & { epoch: number };
    let buffer: BufferedMsg[] = [];
    const pendingHistoryBoundaries = new Map<
      number,
      { msg: HistoryBoundaryEvent; seq: number }[]
    >();
    let flushId: number | null = null;
    let flushTimerId: ReturnType<typeof setTimeout> | null = null;

    const handleAgentAck = (dirty: Set<string>, tid: number, nonce: string) => {
      if (tombstoneTidToEditorRef.current.has(tid)) return;
      const editorId = controlledOwnerByTidRef.current.get(tid)?.editorId;
      const effects = editorId
        ? applyDraftEvent({
            type: "task-observed",
            editorId,
            observation: { tid, hasMessages: true },
          }).effects
        : [];
      const uuid = tidToUuid.get(tid);
      if (!uuid) {
        executeDraftEffects(effects);
        return;
      }
      const t = liveStates.get(uuid);
      if (!t) {
        executeDraftEffects(effects);
        return;
      }
      // An unchanged identity can also mean the open batch edited in place.
      const existingBatch = taskBatches.get(uuid);
      const updated = reduceAgentAckIn(batchFor(uuid), t, nonce);
      if (updated !== t) markDirty(dirty, uuid, updated);
      else if (!existingBatch) sealTask(uuid);
      executeDraftEffects(effects);
    };

    const flush = () => {
      flushId = null;
      if (flushTimerId !== null) {
        clearTimeout(flushTimerId);
        flushTimerId = null;
      }
      const batch = buffer;
      buffer = [];
      const dirty = new Set<string>();
      for (const item of batch) {
        if (!isCurrentOpenEpoch(item.epoch)) continue;
        if (item.kind === "draftUpdated")
          handleDraftUpdatedMessage(item.msg, item.receipt);
        else if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "unconfirmed")
          handleUnconfirmedUserMessage(item.tid, item.msg, item.correlationId);
        else if (item.kind === "agentAck")
          handleAgentAck(dirty, item.tid, item.nonce);
        else if (item.kind === "historyBoundary") {
          if (tombstoneTidToEditorRef.current.has(item.tid)) continue;
          const uuid = tidToUuid.get(item.tid);
          if (uuid === undefined)
            throw new Error(`Replacement for unknown task ${item.tid}`);
          const task = liveStates.get(uuid);
          if (task === undefined)
            throw new Error(`Replacement for unknown task ${item.tid}`);
          const hasTarget = task.messages.some(
            (message) =>
              message.seq === item.seq ||
              (Array.isArray(message.seq) && message.seq.includes(item.seq)),
          );
          if (!hasTarget) {
            const pending = pendingHistoryBoundaries.get(item.tid) ?? [];
            pending.push({ msg: item.msg, seq: item.seq });
            pendingHistoryBoundaries.set(item.tid, pending);
            continue;
          }
          const updated = replaceHistoryBoundaryIn(
            batchFor(uuid),
            task,
            item.msg,
            item.seq,
          );
          markDirty(dirty, uuid, updated);
        } else {
          if (tombstoneTidToEditorRef.current.has(item.tid)) {
            pendingHistoryBoundaries.delete(item.tid);
            continue;
          }
          handleTaskMessage(dirty, item.tid, item.msg, item.seq, item.ts);
          const pending = pendingHistoryBoundaries.get(item.tid);
          if (pending && item.seq !== undefined) {
            const matching = pending.filter(
              (replacement) => replacement.seq === item.seq,
            );
            if (matching.length > 0) {
              const uuid = tidToUuid.get(item.tid);
              if (uuid === undefined)
                throw new Error(`Replacement for unknown task ${item.tid}`);
              const initialTask = liveStates.get(uuid);
              if (initialTask === undefined)
                throw new Error(`Replacement for unknown task ${item.tid}`);
              const taskBatch = batchFor(uuid);
              let updated = initialTask;
              for (const replacement of matching)
                updated = replaceHistoryBoundaryIn(
                  taskBatch,
                  updated,
                  replacement.msg,
                  replacement.seq,
                );
              markDirty(dirty, uuid, updated);
              const remaining = pending.filter(
                (replacement) => replacement.seq !== item.seq,
              );
              if (remaining.length > 0)
                pendingHistoryBoundaries.set(item.tid, remaining);
              else pendingHistoryBoundaries.delete(item.tid);
            }
          }
        }
      }
      publishDirtyTasks(dirty);
    };

    // Batch via rAF when visible for render-aligned updates. When hidden,
    // flush synchronously — there's no rendering benefit to batching, and
    // browsers throttle timers / pause rAF in background tabs.
    const cancelPendingFlush = () => {
      if (flushId !== null) {
        cancelAnimationFrame(flushId);
        flushId = null;
      }
      if (flushTimerId !== null) {
        clearTimeout(flushTimerId);
        flushTimerId = null;
      }
    };

    const scheduleFlush = () => {
      if (document.hidden) {
        cancelPendingFlush();
        flush();
        return;
      }
      if (flushId !== null) return;
      flushId = requestAnimationFrame(flush);
      // Fallback: if rAF is deprioritized (e.g. headless Chromium with no
      // interaction), flush after 50ms so tests don't time out.
      flushTimerId = setTimeout(() => {
        if (flushId !== null) {
          cancelAnimationFrame(flushId);
          flushId = null;
          flush();
        }
      }, 50);
    };

    // If the tab becomes hidden while a rAF is pending, it will never fire.
    // Flush immediately so notifications can still trigger.
    const onVisibilityChange = () => {
      if (document.hidden && buffer.length > 0) {
        cancelPendingFlush();
        flush();
      }
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    const flushPendingDraftSaves = () => {
      for (const runtime of saveRuntimeRef.current.values()) {
        const result = applyDraftEvent({
          type: "flush",
          editorId: runtime.editorId,
        });
        executeDraftEffects(result.effects);
      }
    };
    if (typeof window !== "undefined")
      window.addEventListener("pagehide", flushPendingDraftSaves);

    const cancelDraftTimers = () => {
      for (const runtime of createRuntimeRef.current.values())
        clearTimeout(runtime.handle);
      for (const runtime of saveRuntimeRef.current.values())
        clearTimeout(runtime.handle);
      createRuntimeRef.current.clear();
      saveRuntimeRef.current.clear();
    };

    conn.onStatusChange = (connected) => {
      if (!connected) {
        connectionEpochRef.current++;
        openConnectionEpochRef.current = null;
        cancelPendingFlush();
        buffer = [];
        pendingHistoryBoundaries.clear();
        setConnected(false);
        clearTasks();
        tidToUuid.clear();
        ordinaryDraftStore.clear();
        requestedHistoryRef.current.clear();
        outboxReplayedEpochRef.current = null;
        outboxAttemptedNoncesRef.current.clear();
        tasksListEpochRef.current = null;
        tasksListAcceptedTidsRef.current.clear();
        tasksListPhaseRef.current = "awaiting";
        cancelDraftTimers();
        composerResetEpochRef.current++;
        applyDraftEvent({ type: "connection-reset" });
        expectedFocusRef.current.clear();
        routeProjectCacheRef.current = null;
        requestedProjectTypesRef.current.clear();
        workspacesRef.current = [];
        setWorkspaces([]);
        setEntryPoints([]);
        setTypeInfo([]);
        setProjectTypeInfo(new Map());
        setTasksListEpoch(null);
        setAgentUsage({});
      } else {
        openConnectionEpochRef.current = connectionEpochRef.current;
        tasksListAcceptedTidsRef.current.clear();
        tasksListPhaseRef.current = "awaiting";
        initialNoticeLoadRef.current = true;
      }
    };

    const enqueue = (item: BufferedPayload, settleOutbox = false) => {
      const epoch = openConnectionEpochRef.current;
      if (!isCurrentOpenEpoch(epoch)) return;
      buffer.push({ ...item, epoch });
      if (settleOutbox) {
        // Preserve wire order, including task snapshots and diagnostics ahead
        // of the receipt, without leaving it in a batch a disconnect can drop.
        cancelPendingFlush();
        flush();
      } else scheduleFlush();
    };

    conn.onTaskMessage = (tid, msg, seq, ts) => {
      enqueue({ kind: "task", tid, msg, seq, ts });
    };
    conn.onHistoryBoundaryReplaced = (tid, msg, seq) => {
      if (!hasHistoryBoundary(msg))
        throw new Error("Replacement event has no history boundary");
      enqueue({ kind: "historyBoundary", tid, msg, seq });
    };
    conn.onUnconfirmedUserMessage = (tid, msg, correlationId) => {
      // Settle delivery immediately while keeping history replay batched.
      if (correlationId && isCurrentOpenEpoch(openConnectionEpochRef.current))
        outbox.acceptSend(tid, correlationId);
      enqueue({ kind: "unconfirmed", tid, msg, correlationId });
    };
    conn.onAgentAck = (tid, nonce) => {
      enqueue({ kind: "agentAck", tid, nonce });
    };
    conn.onControlMessage = (msg) => {
      if (msg.type === "draft_updated") {
        if (msg.correlation_id) {
          outbox.acknowledgeDraft(msg.tid, msg.correlation_id);
          return;
        }
        const owner = controlledOwnerByTidRef.current.get(msg.tid);
        enqueue({
          kind: "draftUpdated",
          msg,
          receipt: owner
            ? { kind: "controlled", owner: { ...owner } }
            : { kind: "ordinary" },
        });
        return;
      }
      enqueue(
        { kind: "control", msg },
        msg.type === "cydo/submission_rejected" ||
          ((msg.type === "task_deleted" || msg.type === "task_reload") &&
            outbox.byTid(msg.tid).length > 0),
      );
    };
    conn.onClientError = (message) => {
      addToastRef.current("error", message);
    };
    conn.connect();
    return () => {
      cancelPendingFlush();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      if (typeof window !== "undefined")
        window.removeEventListener("pagehide", flushPendingDraftSaves);
      flushPendingDraftSaves();
      cancelDraftTimers();
      if (controlledImageStore) resetControlledImageStore(controlledImageStore);
      ordinaryDraftStore.clear();
      clearTasks();
      tidToUuid.clear();
      conn.disconnect();
    };
  }, [
    clearTasks,
    controlledImageStore,
    handleTaskMessage,
    handleDraftUpdatedMessage,
    handleControlMessage,
    handleUnconfirmedUserMessage,
    isCurrentOpenEpoch,
    publishDirtyTasks,
    ordinaryDraftStore,
  ]);

  // The workspace/project segments of a task URL are derived from the task; enforce
  // that. The URL is the source of truth for which task is open, so correct the URL
  // rather than teaching its consumers to tolerate a mismatch.
  //
  // `tasks` and `workspaces` are load-bearing dependencies and must not be removed
  // by a later cleanup. The task and workspace lookups read refs, so
  // `tasks` and `workspaces` trigger this effect when either list changes.
  useEffect(() => {
    const current = readBrowserRoute();
    const tid = parseTaskId(current.tid);
    if (tid === null) return;
    const [ws, proj] = taskContext(getPublishedTask(tid));
    const target = canonicalTaskRedirect({
      tid,
      taskWorkspace: ws,
      taskProject: proj,
      urlWorkspace: current.workspace,
      urlProject: current.project,
    });
    if (target !== null)
      navigate({ workspace: ws, project: proj, tid: String(tid) }, true);
  }, [
    activeTaskId,
    activeWorkspace,
    activeProject,
    tasks,
    workspaces,
    taskContext,
    getPublishedTask,
    navigate,
  ]);

  // Request history when the active task changes and hasn't been loaded yet
  useEffect(() => {
    if (!connected || activeTaskId === null) return;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    if (tombstoneTidToEditorRef.current.has(tid)) return;
    if (controlledOwnerByTidRef.current.has(tid)) return;
    const t = findByTid(tid);
    if (!t) return;
    const workspace = t.status === "importable" ? (activeWorkspace ?? "") : "";
    if (requestedHistoryRef.current.get(t.uuid) === workspace) return;
    if (t.historyLoaded && t.status !== "importable") return;
    if (connRef.current?.requestHistory(tid, workspace)) {
      requestedHistoryRef.current.set(t.uuid, workspace);
    }
  }, [connected, activeTaskId, activeWorkspace, tasks]);

  // Replay outbox entries after tasks_list arrives and WS is connected.
  // The backend deduplicates by nonce, so replaying is safe.
  useEffect(() => {
    const epoch = renderedConnectionEpoch;
    if (
      !connected ||
      tasksListEpoch !== epoch ||
      tasksListEpochRef.current !== epoch ||
      !isCurrentOpenEpoch(epoch)
    )
      return;
    if (outboxReplayedEpochRef.current === epoch) return;
    outboxReplayedEpochRef.current = epoch;
    const entries = outbox.all();
    let dropped = 0;
    for (const entry of entries) {
      if (!tidToUuid.has(entry.tid)) {
        outbox.remove(entry.nonce);
        dropped++;
        continue;
      }
      if (entry.recoveredDraft !== undefined) {
        const task = findByTid(entry.tid)!;
        ordinaryDraftStore.ensure(task.uuid, task.serverDraft ?? "");
        ordinaryDraftStore.write(task.uuid, entry.recoveredDraft);
        saveDraft(entry.tid, entry.recoveredDraft);
        continue;
      }
      if (outboxAttemptedNoncesRef.current.has(entry.nonce)) continue;
      outboxAttemptedNoncesRef.current.add(entry.nonce);
      connRef.current?.sendMessage(
        entry.tid,
        entry.content as import("./protocol").AssistantContentBlock[],
        entry.nonce,
      );
    }
    outboxAttemptedNoncesRef.current.clear();
    if (dropped > 0) {
      console.warn(
        `[outbox] dropped ${dropped} unsent message(s): task no longer exists`,
      );
    }
  }, [
    connected,
    tasks,
    tasksListEpoch,
    renderedConnectionEpoch,
    isCurrentOpenEpoch,
    ordinaryDraftStore,
    saveDraft,
  ]);

  const routeDraftProject = useMemo(
    () => resolveRouteProject(parsed),
    [parsed, renderedConnectionEpoch, resolveRouteProject, workspaces],
  );

  const projectEntryPoints = draftStateRef.current.metadata.catalogs;

  // Project task types are keyed by the canonical workspace metadata path,
  // which only exists after the workspace bootstrap has arrived.
  useEffect(() => {
    if (!connected || !routeDraftProject?.projectPath) return;
    if (projectEntryPoints.has(routeDraftProject.projectPath)) return;
    const epoch = renderedConnectionEpoch;
    if (!isCurrentOpenEpoch(epoch)) return;
    if (
      requestedProjectTypesRef.current.get(routeDraftProject.projectPath) ===
      epoch
    )
      return;
    const connection = connRef.current;
    if (!connection) return;
    connection.requestTaskTypes(routeDraftProject.projectPath);
    if (isCurrentOpenEpoch(epoch))
      requestedProjectTypesRef.current.set(
        routeDraftProject.projectPath,
        epoch,
      );
  }, [
    connected,
    routeDraftProject,
    projectEntryPoints,
    renderedConnectionEpoch,
    isCurrentOpenEpoch,
  ]);

  const dispatchDraftIntent = useCallback(
    (event: DraftEvent) => {
      const result = applyDraftEvent(event);
      executeDraftEffects(result.effects);
    },
    [applyDraftEvent, executeDraftEffects],
  );

  const persistedSnapshot = useCallback(
    (task: TaskState, tid: number): PersistedSnapshot | null => {
      if (
        task.status !== "pending" ||
        task.messages.length !== 0 ||
        task.isProcessing ||
        task.alive ||
        !task.entryPoint ||
        !task.serverDraft?.trim()
      )
        return null;
      return {
        tid,
        text: task.serverDraft,
        entryPoint: task.entryPoint,
        agent: task.agentName ?? null,
        active: task.alive,
        processing: task.isProcessing,
        hasMessages: false,
      };
    },
    [],
  );

  const selectedTid = activeTaskId === null ? null : parseTaskId(activeTaskId);
  const selectedTask =
    selectedTid === null ? undefined : getPublishedTask(selectedTid);
  const openPersistedEvent = useMemo<Extract<
    DraftEvent,
    { type: "open-persisted" }
  > | null>(() => {
    if (
      !connected ||
      !routeDraftProject?.projectPath ||
      selectedTid === null ||
      !selectedTask ||
      selectedTask.workspace !== routeDraftProject.workspace ||
      selectedTask.projectPath !== routeDraftProject.projectPath
    )
      return null;
    const snapshot = persistedSnapshot(selectedTask, selectedTid);
    if (
      !snapshot ||
      controlledOwnerByTidRef.current.has(snapshot.tid) ||
      tombstoneTidToEditorRef.current.has(snapshot.tid)
    )
      return null;
    const project = {
      workspace: selectedTask.workspace,
      projectPath: selectedTask.projectPath,
    };
    return {
      type: "open-persisted",
      editorId: `task:${snapshot.tid}`,
      project,
      snapshot,
    };
  }, [
    connected,
    draftRevision,
    persistedSnapshot,
    routeDraftProject,
    selectedTask,
    selectedTid,
  ]);

  useLayoutEffect(() => {
    if (!isCurrentOpenEpoch(renderedConnectionEpoch)) return;
    if (!connected || !routeDraftProject?.projectPath) return;
    const current = readBrowserRoute();
    if (
      current.tid !== activeTaskId ||
      current.workspace !== routeDraftProject.workspace ||
      current.project !== routeDraftProject.projectName
    )
      return;
    if (activeTaskId === null) {
      const { workspace, projectPath } = routeDraftProject;
      const projectKey = createProjectKey(workspace, projectPath);
      if (!draftStateRef.current.newTaskByProject[projectKey]) {
        dispatchDraftIntent({
          type: "attach-new-task",
          project: { workspace, projectPath },
          editorId: mintCompositionId(),
        });
      }
    } else if (openPersistedEvent) {
      dispatchDraftIntent(openPersistedEvent);
    }
  }, [
    activeTaskId,
    connected,
    dispatchDraftIntent,
    draftRevision,
    isCurrentOpenEpoch,
    openPersistedEvent,
    renderedConnectionEpoch,
    routeDraftProject,
  ]);

  const editDraftText = useCallback(
    (editorId: EditorId, text: string) => {
      const editor = getEditor(draftStateRef.current, editorId);
      const blank = text.trim() === "";
      let successor: CompositionId | undefined;
      if (
        blank &&
        editor.desired.kind === "editing" &&
        editor.desired.text !== "" &&
        editor.remote.kind !== "present"
      ) {
        successor = mintCompositionId();
      }
      dispatchDraftIntent({ type: "edit-text", editorId, text, successor });
    },
    [dispatchDraftIntent],
  );

  const submitDraft = useCallback(
    (editorId: EditorId, images: ImageAttachment[]) => {
      const editor = getEditor(draftStateRef.current, editorId);
      dispatchDraftIntent({
        type: "submit",
        editorId,
        images,
        messageCorrelationId:
          editor.remote.kind === "present" ? crypto.randomUUID() : undefined,
      });
    },
    [dispatchDraftIntent],
  );

  const send = useCallback(
    (uuid: string, text: string, images?: ImageAttachment[]) => {
      sendRealTask(uuid, text, images);
    },
    [sendRealTask],
  );

  const interrupt = useCallback((uuid: string) => {
    const tid = liveStates.get(uuid)?.tid ?? null;
    if (tid !== null) connRef.current?.sendInterrupt(tid);
  }, []);

  const stop = useCallback((uuid: string) => {
    const tid = liveStates.get(uuid)?.tid ?? null;
    if (tid !== null) connRef.current?.sendStop(tid);
  }, []);

  const closeStdin = useCallback((uuid: string) => {
    const tid = liveStates.get(uuid)?.tid ?? null;
    if (tid !== null) connRef.current?.sendCloseStdin(tid);
  }, []);

  const fork = useCallback((tid: number, anchor: string) => {
    connRef.current?.forkTask(tid, anchor);
  }, []);

  const undo = useCallback(
    (
      tid: number,
      anchor: string,
      dryRun: boolean,
      revertConversation: boolean,
      revertFiles: boolean,
    ) => {
      connRef.current?.undoTask(
        tid,
        anchor,
        dryRun,
        revertConversation,
        revertFiles,
      );
    },
    [],
  );

  const undoPreview = useCallback(
    (tid: number, anchor: string) => {
      // Optimistically set anchor so confirmation bar can reference it
      const t = findByTid(tid);
      if (t) {
        const boundary = [...t.replacementEvents.values()].find(
          (event) =>
            (event as { history_boundary?: { anchor: string } })
              .history_boundary?.anchor === anchor,
        ) as
          | {
              history_boundary?: {
                checkpoint_uuid?: string;
                kind: "user" | "provisional_user" | "agent_turn";
              };
            }
          | undefined;
        const canRevertFiles =
          boundary?.history_boundary?.kind !== "provisional_user" &&
          !!boundary?.history_boundary?.checkpoint_uuid;
        const undoPending: UndoPending = {
          anchor,
          kind: "requesting",
          canRevertFiles,
          retainsPrompt: boundary?.history_boundary?.kind === "agent_turn",
          supportsFileRevert: t.sessionInfo?.supports_file_revert !== false,
        };
        const updated = {
          ...t,
          undoPending,
        };
        commitTask(t.uuid, updated);
      }
      connRef.current?.undoTask(tid, anchor, true, false, false);
    },
    [commitTask],
  );

  const undoConfirm = useCallback(
    (tid: number, revertConversation: boolean, revertFiles: boolean) => {
      const t = findByTid(tid);
      if (!t?.undoPending) return;
      const pending = t.undoPending;
      connRef.current?.undoTask(
        tid,
        pending.anchor,
        false,
        revertConversation,
        revertFilesForUndo(pending.canRevertFiles, revertFiles),
        pending.kind === "codex_turns" ? pending.messagesRemoved : undefined,
      );
      // Clear undoPending
      const updated = { ...t, undoPending: null };
      commitTask(t.uuid, updated);
    },
    [commitTask],
  );

  const undoDismiss = useCallback(
    (tid: number) => {
      const t = findByTid(tid);
      if (!t) return;
      const updated = { ...t, undoPending: null };
      commitTask(t.uuid, updated);
    },
    [commitTask],
  );

  const dismissAttention = useCallback((tid: number) => {
    connRef.current?.dismissAttention(tid);
  }, []);

  const unsendMessage = useCallback((tid: number, nonce: string) => {
    const message = findByTid(tid)?.messages.find(
      (m) => m.type === "user" && m.nonce === nonce,
    );
    if (!message) return;
    unsendRequestsRef.current.set(
      nonce,
      canonicalUserTextFromDisplayMessage(message),
    );
    connRef.current?.unsendMessage(tid, nonce);
  }, []);

  const approveRetry = useCallback(
    (tid: number, toolName: string, input: unknown) => {
      connRef.current?.approveRetry(tid, toolName, input);
    },
    [],
  );

  const clearInputDraft = useCallback(
    (tid: number) => {
      const t = findByTid(tid);
      if (!t?.inputDraft) return;
      const updated = { ...t, inputDraft: undefined };
      commitTask(t.uuid, updated, "if-present");
    },
    [commitTask],
  );

  const resume = useCallback(
    (uuid: string) => {
      const t = liveStates.get(uuid);
      if (!t || t.tid === null || t.archived) return;
      connRef.current?.resumeTask(t.tid);
      const updated: TaskState = {
        ...t,
        alive: true,
        resumable: false,
        status: "active",
      };
      commitTask(uuid, updated);
    },
    [commitTask],
  );

  const promote = useCallback((tid: number) => {
    const t = findByTid(tid);
    if (!t || t.status !== "importable") return;
    connRef.current?.promoteTask(tid, readBrowserRoute().workspace ?? "");
  }, []);

  const setArchived = useCallback((tid: number, archived: boolean) => {
    connRef.current?.setArchived(tid, archived);
  }, []);

  const sendAskUserResponse = useCallback(
    (tid: number, content: string) => {
      connRef.current?.sendAskUserResponse(tid, content);
      // Optimistically clear the pending question
      const t = findByTid(tid);
      if (t) {
        const updated = { ...t, pendingAskUser: null, isProcessing: true };
        commitTask(t.uuid, updated);
      }
    },
    [commitTask],
  );

  const sendPermissionPromptResponse = useCallback(
    (tid: number, toolUseId: string, content: string) => {
      connRef.current?.sendPermissionPromptResponse(tid, toolUseId, content);
      const t = findByTid(tid);
      if (t?.pendingPermission?.toolUseId === toolUseId) {
        const updated = {
          ...t,
          pendingPermission: null,
          submittedPermission: t.pendingPermission,
          isProcessing: true,
        };
        commitTask(t.uuid, updated);
      }
    },
    [commitTask],
  );

  const editMessage = useCallback(
    (tid: number, uuid: string, content: string) => {
      connRef.current?.editMessage(tid, uuid, content);
    },
    [],
  );

  const editRawEvent = useCallback(
    (tid: number, seq: number, content: string) => {
      connRef.current?.editRawEvent(tid, seq, content);
    },
    [],
  );

  const resolvedEntryPoints = useMemo(() => {
    const projectPath = routeDraftProject?.projectPath;
    if (projectPath) {
      const projectEps = projectEntryPoints.get(projectPath);
      if (projectEps) return [...projectEps];
    }
    return entryPoints;
  }, [entryPoints, projectEntryPoints, routeDraftProject]);

  const resolvedTypeInfo = useMemo(() => {
    const projectPath = routeDraftProject?.projectPath;
    if (projectPath) {
      const projectTi = projectTypeInfo.get(projectPath);
      if (projectTi) return projectTi;
    }
    return typeInfo;
  }, [projectTypeInfo, routeDraftProject, typeInfo]);

  const draftView = useMemo<DraftView | null>(() => {
    if (!routeDraftProject) return null;
    const projectKey = createProjectKey(
      routeDraftProject.workspace,
      routeDraftProject.projectPath,
    );
    const editorId =
      activeTaskId === null
        ? draftStateRef.current.newTaskByProject[projectKey]
        : selectedTid === null
          ? undefined
          : (controlledOwnerByTidRef.current.get(selectedTid)?.editorId ??
            openPersistedEvent?.editorId);
    if (!editorId) {
      if (activeTaskId !== null) return null;
      return {
        kind: "unresolved",
        viewKey: `route:${routeDraftProject.workspace}\0${routeDraftProject.projectName}`,
        workspace: routeDraftProject.workspace,
        projectName: routeDraftProject.projectName,
        projectPath: routeDraftProject.projectPath,
        remoteTid: null,
        text: "",
        entryPoint: "",
        agent: "",
        lifecycle: "idle",
        disabled: true,
        metadataReady: false,
        submitReady: false,
        composerResetToken: 0,
      };
    }
    // Render a qualifying numeric route in the same commit as its snapshot.
    // The layout effect commits this same transition before the view can edit.
    const state = openPersistedEvent
      ? reduceDraft(draftStateRef.current, openPersistedEvent).state
      : draftStateRef.current;
    const editor = getEditor(state, editorId);
    if (
      editor.project.workspace !== routeDraftProject.workspace ||
      editor.project.projectPath !== routeDraftProject.projectPath
    )
      return null;
    return makeDraftViewSnapshot(
      editor,
      editorId,
      routeDraftProject.projectName,
      !connected,
      editorMetadataReady(state, editorId),
      editorSubmittable(state, editorId),
      composerResetEpochRef.current,
      editDraftText,
      dispatchDraftIntent,
      submitDraft,
    );
  }, [
    activeTaskId,
    connected,
    dispatchDraftIntent,
    draftRevision,
    editDraftText,
    openPersistedEvent,
    routeDraftProject,
    selectedTid,
    submitDraft,
  ]);

  // Build sidebar task list filtered by active workspace/project and sorted by createdAt/tid
  const prevSidebarTasksRef = useRef<
    import("./components/Sidebar").SidebarTask[]
  >([]);
  const sidebarTasks = useMemo(() => {
    let filtered: Array<TaskState & { tid: number }> = [];
    for (const task of tasks.values()) {
      if (task.tid === null) {
        throw new Error("Sidebar task must have a numeric tid");
      }
      filtered.push(task as TaskState & { tid: number });
    }
    if (activeWorkspace !== null && activeProject !== null) {
      const activeProjectPath = findProjectPath(
        workspaces,
        activeWorkspace,
        activeProject,
      );
      filtered = filtered.filter((t) => {
        if (!t.projectPath) return false;
        // Importable tasks have workspace="" — match by projectPath alone
        if (!t.workspace) {
          return t.projectPath === activeProjectPath;
        }
        return (
          t.workspace === activeWorkspace && t.projectPath === activeProjectPath
        );
      });
    }
    const result = filtered
      .sort((a, b) => a.tid - b.tid)
      .map((t) => {
        const owner = controlledOwnerByTidRef.current.get(t.tid);
        const editor = owner && draftStateRef.current.editors[owner.editorId];
        const text =
          editor && editor.desired.kind !== "none"
            ? editor.desired.text
            : t.serverDraft;
        return {
          tid: t.tid,
          alive: t.alive,
          canStop: t.canStop,
          resumable: t.resumable,
          isProcessing: t.isProcessing,
          stdinClosed: t.stdinClosed,
          title:
            t.title ||
            (t.status === "pending" && t.messages.length === 0 && text
              ? text.replace(/\s+/g, " ").trim().slice(0, 100)
              : undefined),
          parentTid: t.parentTid,
          childCount: t.childCount,
          relationType: t.relationType,
          status: t.status,
          archived: t.archived,
          archiving: t.archiving,
          taskType: t.taskType,
          hasPendingQuestion: t.hasPendingQuestion,
          hasMessages: t.messages.length > 0,
        };
      });

    const prev = prevSidebarTasksRef.current;
    if (
      prev.length === result.length &&
      result.every((t, i) => {
        const p = prev[i]!;
        return (
          t.tid === p.tid &&
          t.alive === p.alive &&
          t.canStop === p.canStop &&
          t.resumable === p.resumable &&
          t.isProcessing === p.isProcessing &&
          t.stdinClosed === p.stdinClosed &&
          t.title === p.title &&
          t.parentTid === p.parentTid &&
          t.childCount === p.childCount &&
          t.relationType === p.relationType &&
          t.status === p.status &&
          t.archived === p.archived &&
          t.archiving === p.archiving &&
          t.taskType === p.taskType &&
          t.hasPendingQuestion === p.hasPendingQuestion &&
          t.hasMessages === p.hasMessages
        );
      })
    ) {
      return prev;
    }
    prevSidebarTasksRef.current = result;
    return result;
  }, [tasks, draftRevision, activeWorkspace, activeProject, workspaces]);

  const getProjectedByTid = useCallback(
    (tid: number) => {
      if (tombstoneTidToEditorRef.current.has(tid)) return undefined;
      return getPublishedTask(tid);
    },
    [getPublishedTask],
  );

  const tasksLoaded =
    tasksListEpoch !== null &&
    tasksListEpoch === renderedConnectionEpoch &&
    tasksListEpochRef.current === renderedConnectionEpoch &&
    isCurrentOpenEpoch(renderedConnectionEpoch);

  return {
    tasks,
    ordinaryDraftStore,
    activeTaskId,
    getActiveTaskId,
    setActiveTaskId,
    connected,
    tasksLoaded,
    send,
    interrupt,
    stop,
    closeStdin,
    resume,
    promote,
    fork,
    undo,
    undoPreview,
    unsendMessage,
    approveRetry,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    setArchived,
    saveDraft,
    sendAskUserResponse,
    sendPermissionPromptResponse,
    editMessage,
    editRawEvent,
    draftView,
    sidebarTasks,
    workspaces,
    entryPoints: resolvedEntryPoints,
    typeInfo: resolvedTypeInfo,
    agents: draftStateRef.current.metadata.agents ?? [],
    defaultAgent: draftStateRef.current.metadata.agent ?? "",
    defaultTaskType: draftStateRef.current.metadata.entryPoint ?? "",
    activeWorkspace,
    activeProject,
    notices,
    localNotices,
    agentUsage,
    serverError,
    dismissServerError: () => {
      setServerError(null);
    },
    devMode,
    ui,
    heicConversion,
    getHeicConversion,
    exportLoadError: null,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    getByTid: getProjectedByTid,
    refreshWorkspaces: () => {
      setScanState("requested");
      connRef.current?.refreshWorkspaces();
    },
    scanState,
  };
}

/** Find the relative project name given workspace name and absolute project path. */
function findProjectName(
  workspaces: WorkspaceInfo[],
  workspace: string,
  projectPath: string,
): string | null {
  const ws = workspaces.find((w) => w.name === workspace);
  if (!ws) return null;
  const proj = ws.projects.find((p) => p.path === projectPath);
  return proj?.name ?? null;
}

/** Find the absolute project path given workspace name and relative project name. */
function findProjectPath(
  workspaces: WorkspaceInfo[],
  workspace: string,
  projectName: string,
): string | null {
  const ws = workspaces.find((w) => w.name === workspace);
  if (!ws) return null;
  const proj = ws.projects.find((p) => p.name === projectName);
  return proj?.path ?? null;
}
