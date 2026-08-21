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
import { useLocation, useRoute } from "preact-iso";
import { Connection } from "./connection";
import type {
  AgentUsageMessage,
  AgnosticEvent,
  ControlMessage,
  ContentBlock,
  HistoryBoundary,
  Notice,
  TasksListMessage,
} from "./protocol";
import type { CydoMeta, TaskState, UndoPending } from "./types";
import { makeTaskState } from "./types";
import {
  reduceAgentAck,
  reduceMessage,
  replaceHistoryBoundary,
} from "./sessionReducer";
import { outbox } from "./outbox";
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
  getSlot,
  reduceDraft,
  type DraftEffect,
  type DraftEvent,
  type DraftSlotState,
  type DraftState,
  type ProjectKey,
  type ResolvedDraftForm,
  type TaskObservation,
  type TaskSnapshot,
} from "./draftReconciler";
import {
  buildProjectHref,
  buildScopedHref,
  canonicalTaskRedirect,
  parseRoute,
  taskPath,
} from "./routing";

// Only the class travels: the server holds the window sizes, because the first
// history request goes out before server_status has taught this side what they
// are, and guessing zero there means replaying the whole task.
//
// Three signals rather than one, since a pointer query alone is not enough:
// some mobile browsers report a fine pointer despite being a phone. A
// touchscreen laptop reads as mobile here, which only costs it a smaller
// starting window.
function deviceClass(): "mobile" | "desktop" {
  if (typeof window === "undefined") return "desktop";
  const media = (query: string) =>
    typeof window.matchMedia === "function" && window.matchMedia(query).matches;
  const touch = window.navigator.maxTouchPoints > 0;
  const mobileAgent = /Mobi|Android|iPhone|iPad|iPod/i.test(
    window.navigator.userAgent,
  );
  return touch ||
    mobileAgent ||
    media("(pointer: coarse)") ||
    media("(hover: none)")
    ? "mobile"
    : "desktop";
}

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

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

export interface AgentInfo {
  name: string;
  driver: string;
  display_name?: string;
  is_available?: boolean;
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
  composerResetToken: number;
}

export interface UnresolvedDraftView extends DraftViewBase {
  kind: "unresolved";
}

export interface DraftViewSnapshot extends DraftViewBase {
  kind: "resolved";
  projectKey: ProjectKey;
  onTextChange: (text: string) => void;
  onEntryPointChange: (entryPoint: string) => void;
  onAgentChange: (agent: string) => void;
  onBlur: () => void;
  onSubmit: (text: string, images: ImageAttachment[]) => void;
}

export type DraftView = UnresolvedDraftView | DraftViewSnapshot;

export interface TaskManager {
  tasks: Map<string, TaskState>;
  activeTaskId: string | null;
  activeTaskIdRef: { current: string | null };
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  tasksLoaded: boolean;
  send: (uuid: string, text: string, images?: ImageAttachment[]) => void;
  interrupt: (uuid: string) => void;
  stop: (uuid: string) => void;
  closeStdin: (uuid: string) => void;
  resume: (uuid: string) => void;
  promote: (tid: number) => void;
  fork: (tid: number, afterUuid: string) => void;
  undo: (
    tid: number,
    afterUuid: string,
    dryRun: boolean,
    revertConversation: boolean,
    revertFiles: boolean,
  ) => void;
  undoPreview: (tid: number, afterUuid: string) => void;
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
  sendPermissionPromptResponse: (tid: number, content: string) => void;
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
  agents: AgentInfo[];
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
  /** configured history window in messages for this device class; 0 = off */
  historyWindowStep: number;
  /** load `step` more messages of older history (0 = all) */
  loadMoreHistory: (tid: number, step: number) => void;
  exportLoadError?: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  getByTid: (tid: number) => TaskState | undefined;
  refreshWorkspaces: () => void;
  scanState: "idle" | "requested" | "scanning";
}

function makeDraftViewSnapshot(
  slot: DraftSlotState,
  projectKey: ProjectKey,
  projectName: string,
  composerDisabled: boolean,
  metadataReady: boolean,
  composerResetToken: number,
  editText: (projectKey: ProjectKey, text: string) => void,
  dispatch: (event: DraftEvent) => void,
  submit: (projectKey: ProjectKey, images: ImageAttachment[]) => void,
): DraftViewSnapshot {
  const form =
    slot.desired.kind === "none"
      ? { text: "", ...slot.defaults }
      : {
          text: slot.desired.text,
          entryPoint: slot.desired.entryPoint,
          agent: slot.desired.agent,
        };
  const resolvedMetadata =
    metadataReady && form.entryPoint !== null && form.agent !== null;
  const lifecycle: DraftLifecycle =
    slot.desired.kind === "submitting"
      ? "submitting"
      : slot.remote.kind === "creating"
        ? "creating"
        : slot.remote.kind === "present"
          ? "present"
          : slot.remote.kind === "deleting"
            ? "deleting"
            : "idle";
  const disabled = composerDisabled || slot.desired.kind === "submitting";
  return {
    kind: "resolved",
    projectKey,
    viewKey: projectKey,
    workspace: slot.project.workspace,
    projectName,
    projectPath: slot.project.projectPath,
    remoteTid:
      slot.remote.kind === "present" || slot.remote.kind === "deleting"
        ? slot.remote.tid
        : null,
    text: form.text,
    entryPoint: form.entryPoint ?? "",
    agent: form.agent ?? "",
    lifecycle,
    disabled,
    metadataReady: resolvedMetadata,
    composerResetToken,
    onTextChange: (text) => {
      if (disabled) return;
      editText(projectKey, text);
    },
    onEntryPointChange: (entryPoint) => {
      if (disabled || !resolvedMetadata) return;
      dispatch({ type: "change-entry-point", projectKey, entryPoint });
    },
    onAgentChange: (agent) => {
      if (disabled || !resolvedMetadata) return;
      dispatch({ type: "change-agent", projectKey, agent });
    },
    onBlur: () => {
      if (disabled) return;
      dispatch({ type: "flush", projectKey });
    },
    onSubmit: (_text, images) => {
      if (disabled || !resolvedMetadata) return;
      submit(projectKey, images);
    },
  };
}

export function receiveServerError(
  tasks: Map<string, TaskState>,
  message: string,
  tid?: number,
): {
  serverError: { message: string; tid?: number };
  tasks: Map<string, TaskState>;
} {
  const serverError = { message, tid };
  if (tid === undefined) return { serverError, tasks };

  for (const [uuid, task] of tasks) {
    if (task.tid !== tid || !task.undoPending) continue;
    const nextTasks = new Map(tasks);
    nextTasks.set(uuid, { ...task, undoPending: null });
    return { serverError, tasks: nextTasks };
  }
  return { serverError, tasks };
}

/** Snapshot entry shape shared by tasks_list and task_updated messages. */
export type TaskSnapshotEntry = TasksListMessage["tasks"][number];

/** Build (or merge) the TaskState a tasks_list/task_updated snapshot entry seeds. */
export function taskStateFromEntry(
  entry: TaskSnapshotEntry,
  existing: TaskState | undefined,
  existingUuid: string | undefined,
): TaskState {
  const workspace = entry.workspace || "";
  const projectPath = entry.project_path || "";
  const hasDraft = Object.prototype.hasOwnProperty.call(entry, "draft");
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
      uuid: existingUuid ?? base.uuid,
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
    relationType: entry.relation_type || existing.relationType,
    status: entry.status || existing.status,
    taskType: entry.task_type || existing.taskType,
    entryPoint: entry.entry_point || existing.entryPoint,
    agentName: entry.agent_name || existing.agentName,
    driver: entry.driver || existing.driver,
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
  if (
    Object.prototype.hasOwnProperty.call(entry, "status") &&
    typeof entry.status === "string"
  )
    observation.active = entry.status !== "pending";
  if (entry.alive) observation.active = true;
  if (entry.isProcessing) observation.processing = true;
  if (hasKnownMessages) observation.hasMessages = true;
  return observation;
}

function isAuthoritativeActivity(observation: TaskObservation): boolean {
  return (
    observation.active === true ||
    observation.processing === true ||
    observation.hasMessages === true
  );
}

function activityOnlyObservation(
  observation: TaskObservation,
): TaskObservation {
  return {
    tid: observation.tid,
    ...(observation.active ? { active: true } : {}),
    ...(observation.processing ? { processing: true } : {}),
    ...(observation.hasMessages ? { hasMessages: true } : {}),
  };
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

// Index: backend tid → frontend uuid. Maintained in lockstep with liveStates.
const tidToUuid = new Map<number, string>();

function findByTid(tid: number): TaskState | undefined {
  const uuid = tidToUuid.get(tid);
  return uuid ? liveStates.get(uuid) : undefined;
}

/** Convert a string task id to a numeric tid; returns null for non-numeric strings. */
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
): TaskManager {
  const [connected, setConnected] = useState(false);
  const [tasks, setTasks] = useState<Map<string, TaskState>>(new Map());
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [scanState, setScanState] = useState<"idle" | "requested" | "scanning">(
    "idle",
  );
  const [entryPoints, setEntryPoints] = useState<EntryPointInfo[]>([]);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);
  const [projectEntryPoints, setProjectEntryPoints] = useState<
    Map<string, EntryPointInfo[]>
  >(new Map());
  const [projectTypeInfo, setProjectTypeInfo] = useState<
    Map<string, TypeInfo[]>
  >(new Map());
  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [defaultAgent, setDefaultAgent] = useState("");
  const [defaultTaskType, setDefaultTaskType] = useState("");
  const [globalTaskTypesLoaded, setGlobalTaskTypesLoaded] = useState(false);
  const [agentsLoaded, setAgentsLoaded] = useState(false);
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
  // the configured window for this device class, used to label the load-more
  // buttons; the server still decides what a request actually returns
  const [historyWindowStep, setHistoryWindowStep] = useState(0);
  const addToastRef = useRef(addToast);
  addToastRef.current = addToast;
  const prevNoticeIdsRef = useRef<Set<string>>(new Set());
  const initialNoticeLoadRef = useRef(true);
  const { route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;
  const projectEntryPointsRef = useRef(projectEntryPoints);
  projectEntryPointsRef.current = projectEntryPoints;
  const defaultAgentRef = useRef(defaultAgent);
  defaultAgentRef.current = defaultAgent;

  const { params, path } = useRoute();
  const parsed = useMemo(
    () => parseRoute(path, params),
    [
      path,
      params.workspace,
      params.project,
      params.tid,
      params.sid,
      params.parentTid,
    ],
  );
  const activeTaskIdRef = useRef<string | null>(parsed.tid);
  activeTaskIdRef.current = parsed.tid;
  const activeTaskId = parsed.tid;
  const activeWorkspace = parsed.workspace;
  const activeProject = parsed.project;
  const activeWorkspaceRef = useRef(activeWorkspace);
  activeWorkspaceRef.current = activeWorkspace;
  const activeProjectRef = useRef(activeProject);
  activeProjectRef.current = activeProject;

  const taskContext = useCallback(
    (tid: number): [string | null, string | null] => {
      const t = findByTid(tid);
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

  const currentRouteProjectName = useCallback(
    (
      project: { workspace: string; projectPath: string },
      tid: number | null,
    ): string | null => {
      if (
        activeWorkspaceRef.current !== project.workspace ||
        activeTaskIdRef.current !== (tid === null ? null : String(tid))
      )
        return null;
      const projectName = findProjectName(
        workspacesRef.current,
        project.workspace,
        project.projectPath,
      );
      return projectName === activeProjectRef.current ? projectName : null;
    },
    [],
  );

  const getTaskHref = useCallback(
    (id: string) => {
      if (id === "archive") {
        return buildScopedHref(
          activeWorkspaceRef.current,
          activeProjectRef.current,
          "/archive",
        );
      }
      const archiveMatch = id.match(/^archive:(\d+)$/);
      if (archiveMatch) {
        const parentTid = parseInt(archiveMatch[1]!, 10);
        const [ws, proj] = taskContext(parentTid);
        return buildScopedHref(ws, proj, `/archive/${parentTid}`);
      }
      if (id === "import") {
        return buildScopedHref(
          activeWorkspaceRef.current,
          activeProjectRef.current,
          "/import",
        );
      }

      const tid = parseInt(id, 10);
      if (!isNaN(tid)) {
        const [ws, proj] = taskContext(tid);
        return buildScopedHref(ws, proj, `/task/${id}`);
      }

      return "/";
    },
    [taskContext],
  );

  const setActiveTaskId = useCallback(
    (id: string) => {
      const tid = parseInt(id, 10);
      if (!isNaN(tid)) {
        activeTaskIdRef.current = id;
      }
      routeRef.current(getTaskHref(id));
    },
    [getTaskHref],
  );

  const navigateHome = useCallback(() => {
    routeRef.current("/");
  }, []);

  const navigateToProject = useCallback(
    (workspace: string, projectName: string) => {
      routeRef.current(buildProjectHref(workspace, projectName));
    },
    [],
  );

  const connRef = useRef<Connection | null>(null);
  // Track which tasks have had history requested (avoid duplicate requests), keyed by uuid
  const requestedHistoryRef = useRef(new Set<string>());
  // an in-flight prepend: older messages are reduced into a state of their own
  // and merged at the end, so nothing already on screen is rebuilt
  const prependRef = useRef(
    new Map<string, { beforeSeq: number; state: TaskState }>(),
  );
  // message ids come from a per-state counter, so a staged state would hand out
  // ids the live one already used; starting well past any real count keeps
  // preact's keys unique without rewriting anything afterwards
  const prependIdBaseRef = useRef(1_000_000);
  const outboxReplayedEpochRef = useRef<number | null>(null);
  const outboxAttemptedNoncesRef = useRef(new Set<string>());
  const tasksListEpochRef = useRef<number | null>(null);
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

  const draftStateRef = useRef<DraftState>(createDraftState());
  const [draftRevision, setDraftRevision] = useState(0);
  const requestedProjectTypesRef = useRef(new Map<string, number>());
  const readyDraftMetadataProjectsRef = useRef(new Set<ProjectKey>());
  const createRuntimeRef = useRef(
    new Map<
      ProjectKey,
      {
        generation: string;
        token: number;
        handle: ReturnType<typeof setTimeout>;
      }
    >(),
  );
  const saveRuntimeRef = useRef(
    new Map<
      number,
      {
        projectKey: ProjectKey;
        formVersion: number;
        handle: ReturnType<typeof setTimeout>;
      }
    >(),
  );
  const createTokenRef = useRef(0);
  const correlationToProjectRef = useRef(new Map<string, ProjectKey>());
  const ownedTidToProjectRef = useRef(new Map<number, ProjectKey>());
  const tombstoneTidToProjectRef = useRef(new Map<number, ProjectKey>());
  const expectedFocusRef = useRef(new Set<string>());
  const draftAttachmentRef = useRef<{
    projectKey: ProjectKey;
    routeTid: number | null;
  } | null>(null);
  const routeProjectCacheRef = useRef<{
    epoch: number;
    workspace: string;
    projectName: string;
    projectPath: string;
  } | null>(null);
  const composerResetSequenceRef = useRef(0);
  const composerResetEpochRef = useRef(0);
  const composerResetRef = useRef(new Map<ProjectKey, number>());
  const executeDraftEffectsRef = useRef<
    (effects: readonly DraftEffect[]) => void
  >(() => {
    throw new Error("Draft effect executor is not installed");
  });

  const refreshDraftView = useCallback(() => {
    setDraftRevision((revision) => revision + 1);
  }, []);

  const rebuildDraftIndexes = useCallback((state: DraftState) => {
    correlationToProjectRef.current.clear();
    ownedTidToProjectRef.current.clear();
    tombstoneTidToProjectRef.current.clear();
    for (const [projectKey, slot] of Object.entries(state.slots)) {
      if (slot.remote.kind === "creating") {
        correlationToProjectRef.current.set(
          slot.remote.correlationId,
          projectKey,
        );
      }
      if (slot.remote.kind === "present" || slot.remote.kind === "deleting") {
        ownedTidToProjectRef.current.set(slot.remote.tid, projectKey);
      }
      if (slot.remote.kind === "deleting") {
        tombstoneTidToProjectRef.current.set(slot.remote.tid, projectKey);
      }
    }
  }, []);

  const applyDraftEvent = useCallback(
    (event: DraftEvent) => {
      const result = reduceDraft(draftStateRef.current, event);
      draftStateRef.current = result.state;
      rebuildDraftIndexes(result.state);
      refreshDraftView();
      return result;
    },
    [rebuildDraftIndexes, refreshDraftView],
  );

  const entryPointFor = useCallback(
    (projectPath: string, entryPointName: string) => {
      const candidates = projectEntryPointsRef.current.get(projectPath);
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

  const projectDraft = useCallback((tid: number, form: ResolvedDraftForm) => {
    const task = findByTid(tid);
    if (!task) throw new Error(`Draft projection requires task ${tid}`);
    const projectPath = task.projectPath;
    if (!projectPath)
      throw new Error(`Draft projection requires project ${tid}`);
    const candidates = projectEntryPointsRef.current.get(projectPath);
    let taskType: string;
    if (candidates !== undefined) {
      const entryPoint = candidates.find(
        (candidate) => candidate.name === form.entryPoint,
      );
      if (!entryPoint) {
        throw new Error(`Unknown entry point: ${form.entryPoint}`);
      }
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
    const title = form.text.trim().split("\n")[0]?.slice(0, 100) || undefined;
    const updated: TaskState = {
      ...task,
      serverDraft: form.text || undefined,
      title,
      entryPoint: form.entryPoint,
      agentName: form.agent,
      taskType,
    };
    liveStates.set(task.uuid, updated);
    setTasks((previous) => new Map(previous).set(task.uuid, updated));
  }, []);

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
      outbox.add({ tid: task.tid, nonce, content, createdAt: Date.now() });
      if (outboxReplayedEpochRef.current !== openConnectionEpochRef.current) {
        outboxAttemptedNoncesRef.current.add(nonce);
      }
      connRef.current?.sendMessage(task.tid, content, nonce);
      const messageId = `opt-${++task.msgIdCounter}`;
      const updated: TaskState = {
        ...task,
        messages: [
          ...task.messages,
          {
            id: messageId,
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
      liveStates.set(uuid, updated);
      setTasks((previous) => new Map(previous).set(uuid, updated));
    },
    [],
  );

  const clearComposerImages = useCallback(
    (projectKey: ProjectKey) => {
      composerResetSequenceRef.current++;
      composerResetRef.current.set(
        projectKey,
        composerResetSequenceRef.current,
      );
      refreshDraftView();
    },
    [refreshDraftView],
  );

  const composerResetTokenFor = useCallback((projectKey: ProjectKey) => {
    return (
      composerResetRef.current.get(projectKey) ?? composerResetEpochRef.current
    );
  }, []);

  const executeDraftEffects = useCallback(
    (effects: readonly DraftEffect[]) => {
      for (const effect of effects) {
        switch (effect.type) {
          case "schedule-create": {
            const existing = createRuntimeRef.current.get(effect.projectKey);
            if (existing) {
              if (existing.generation !== effect.generation) {
                throw new Error(
                  "Different draft creation is already scheduled",
                );
              }
              break;
            }
            const token = ++createTokenRef.current;
            const handle = setTimeout(() => {
              const current = createRuntimeRef.current.get(effect.projectKey);
              if (
                !current ||
                current.generation !== effect.generation ||
                current.token !== token
              )
                return;
              createRuntimeRef.current.delete(effect.projectKey);
              const result = applyDraftEvent({
                type: "create-timer-due",
                projectKey: effect.projectKey,
                generation: effect.generation,
              });
              executeDraftEffectsRef.current(result.effects);
            }, effect.delayMs);
            createRuntimeRef.current.set(effect.projectKey, {
              generation: effect.generation,
              token,
              handle,
            });
            break;
          }

          case "cancel-create-schedule": {
            const existing = createRuntimeRef.current.get(effect.projectKey);
            if (existing?.generation === effect.generation) {
              clearTimeout(existing.handle);
              createRuntimeRef.current.delete(effect.projectKey);
            }
            break;
          }

          case "create-task": {
            const slot = getSlot(draftStateRef.current, effect.projectKey);
            connRef.current?.createTask(
              slot.project.workspace,
              slot.project.projectPath,
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
              existing.projectKey === effect.projectKey &&
              existing.formVersion === effect.formVersion
            )
              break;
            if (existing) clearTimeout(existing.handle);
            const handle = setTimeout(() => {
              const current = saveRuntimeRef.current.get(effect.tid);
              if (
                !current ||
                current.projectKey !== effect.projectKey ||
                current.formVersion !== effect.formVersion
              )
                return;
              saveRuntimeRef.current.delete(effect.tid);
              const result = applyDraftEvent({
                type: "save-timer-due",
                projectKey: effect.projectKey,
                tid: effect.tid,
                formVersion: effect.formVersion,
              });
              executeDraftEffectsRef.current(result.effects);
            }, effect.delayMs);
            saveRuntimeRef.current.set(effect.tid, {
              projectKey: effect.projectKey,
              formVersion: effect.formVersion,
              handle,
            });
            break;
          }

          case "cancel-draft-save": {
            const existing = saveRuntimeRef.current.get(effect.tid);
            if (
              existing &&
              existing.projectKey === effect.projectKey &&
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

          case "project-draft":
            projectDraft(effect.tid, effect.form);
            break;

          case "delete-task": {
            const uuid = tidToUuid.get(effect.tid);
            setTasks((previous) => {
              if (!uuid || !previous.has(uuid)) return previous;
              const next = new Map(previous);
              next.delete(uuid);
              return next;
            });
            const slot = getSlot(draftStateRef.current, effect.projectKey);
            const projectName = currentRouteProjectName(
              slot.project,
              effect.tid,
            );
            if (projectName) {
              activeTaskIdRef.current = null;
              routeRef.current(
                buildProjectHref(slot.project.workspace, projectName),
                true,
              );
            }
            connRef.current?.deleteTask(effect.tid);
            break;
          }

          case "draft-ready": {
            const slot = getSlot(draftStateRef.current, effect.projectKey);
            const projectName = currentRouteProjectName(slot.project, null);
            if (!projectName) break;
            routeRef.current(
              taskPath(slot.project.workspace, projectName, effect.tid),
              true,
            );
            break;
          }

          case "send-first-message": {
            const uuid = tidToUuid.get(effect.tid);
            if (!uuid) {
              throw new Error(`First message requires task ${effect.tid}`);
            }
            sendRealTask(uuid, effect.content.text, effect.content.images);
            break;
          }

          case "release-task":
            if (effect.resetComposer) clearComposerImages(effect.projectKey);
            break;

          default:
            assertNeverDraftEffect(effect);
        }
      }
    },
    [
      applyDraftEvent,
      clearComposerImages,
      currentRouteProjectName,
      projectDraft,
      sendRealTask,
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
      desired: Exclude<ReturnType<typeof getSlot>["desired"], { kind: "none" }>,
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
        submitting,
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
        uuid: desired.uuid,
        serverDraft: submitting ? undefined : desired.text || undefined,
        everLoaded: submitting,
      };
      liveStates.set(task.uuid, task);
      tidToUuid.set(tid, task.uuid);
      setTasks((previous) => new Map(previous).set(task.uuid, task));
    },
    [entryPointFor],
  );

  // ask for the slice older than what is held and prepend it; growing the
  // window instead would replay everything already on screen
  const loadMoreHistory = useCallback((tid: number, step: number) => {
    const task = findByTid(tid);
    if (!task) throw new Error(`Loading more history requires task ${tid}`);
    const beforeSeq = task.historyWindowStart ?? 0;
    if (beforeSeq <= 0) return; // nothing older is being held back
    if (prependRef.current.has(task.uuid)) return; // one batch at a time

    prependIdBaseRef.current += 1_000_000;
    const staged: TaskState = {
      ...makeTaskState(tid, true),
      uuid: task.uuid,
      msgIdCounter: prependIdBaseRef.current,
    };
    prependRef.current.set(task.uuid, { beforeSeq, state: staged });

    // step 0 is "load all", i.e. everything before the current start
    const sent = connRef.current?.requestHistoryBefore(
      tid,
      beforeSeq,
      step === 0 ? -1 : step,
      deviceClass(),
    );
    if (!sent) {
      prependRef.current.delete(task.uuid);
      throw new Error(`History request failed for ${tid}`);
    }
  }, []);

  const requestTaskHistory = useCallback((tid: number) => {
    const task = findByTid(tid);
    if (!task) throw new Error(`History request requires task ${tid}`);
    if (requestedHistoryRef.current.has(task.uuid)) return;
    if (!connRef.current?.requestHistory(tid, 0, deviceClass())) {
      throw new Error(`History request failed for ${tid}`);
    }
    requestedHistoryRef.current.add(task.uuid);
  }, []);

  const releaseTombstonedActivity = useCallback(
    (
      projectKey: ProjectKey,
      observation: TaskObservation,
    ): readonly DraftEffect[] | null => {
      if (!isAuthoritativeActivity(observation)) return null;
      const result = applyDraftEvent({
        type: "task-observed",
        projectKey,
        observation: activityOnlyObservation(observation),
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
      if (tombstoneTidToProjectRef.current.has(tid)) return;
      const projectKey = ownedTidToProjectRef.current.get(tid);
      const effects = projectKey
        ? applyDraftEvent({
            type: "task-observed",
            projectKey,
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
        outbox.remove(correlationId);
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
          liveStates.set(uuid, updated);
          setTasks((map) => {
            const next = new Map(map);
            next.set(uuid, updated);
            return next;
          });
          executeDraftEffectsRef.current(effects);
          return;
        }
      }

      const id = `pending-${++prev.msgIdCounter}`;
      const updated = {
        ...prev,
        messages: [
          ...messages,
          {
            id,
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
      liveStates.set(uuid, updated);
      setTasks((map) => {
        const next = new Map(map);
        next.set(uuid, updated);
        return next;
      });
      executeDraftEffectsRef.current(effects);
    },
    [applyDraftEvent],
  );

  const handleTaskMessage = useCallback(
    (tid: number, msg: AgnosticEvent, seq?: number, ts?: number) => {
      if (tombstoneTidToProjectRef.current.has(tid)) return;
      const projectKey = ownedTidToProjectRef.current.get(tid);
      const effects = projectKey
        ? applyDraftEvent({
            type: "task-observed",
            projectKey,
            observation: { tid, hasMessages: true },
          }).effects
        : [];
      const uuid = tidToUuid.get(tid);
      if (!uuid) {
        executeDraftEffectsRef.current(effects);
        return;
      }
      const prepend = prependRef.current.get(uuid);
      if (
        prepend !== undefined &&
        seq !== undefined &&
        seq < prepend.beforeSeq
      ) {
        // belongs to the older batch being staged, not to what is on screen
        let staged = reduceMessage(prepend.state, msg, seq, ts);
        if (hasHistoryBoundary(msg))
          staged = replaceHistoryBoundary(staged, msg, seq);
        prependRef.current.set(uuid, { ...prepend, state: staged });
        return;
      }

      const prev = liveStates.get(uuid) ?? {
        ...makeTaskState(tid, true),
        uuid,
      };
      let updated = reduceMessage(prev, msg, seq, ts);
      if (hasHistoryBoundary(msg) && seq !== undefined)
        updated = replaceHistoryBoundary(updated, msg, seq);
      if (!updated.historyLoaded && updated.historyTotal !== undefined) {
        updated = {
          ...updated,
          historyReceived: (updated.historyReceived ?? 0) + 1,
        };
      }
      liveStates.set(uuid, updated);

      setTasks((map) => {
        const next = new Map(map);
        next.set(uuid, updated);
        return next;
      });
      executeDraftEffectsRef.current(effects);
    },
    [applyDraftEvent],
  );

  const handleControlMessage = useCallback(
    (msg: ControlMessage) => {
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
        tombstoneTidToProjectRef.current.has(controlledTid)
      )
        return;
      switch (msg.type) {
        case "workspaces_list": {
          workspacesRef.current = msg.workspaces;
          setWorkspaces(msg.workspaces);
          setConnected(true);
          break;
        }
        case "scan_status": {
          setScanState(msg.scanning ? "scanning" : "idle");
          break;
        }
        case "task_types_list": {
          setEntryPoints(msg.entry_points);
          setTypeInfo(msg.type_info);
          setDefaultTaskType(msg.default_task_type ?? "");
          setGlobalTaskTypesLoaded(true);
          break;
        }
        case "project_task_types_list": {
          const { project_path, entry_points, type_info } = msg;
          setProjectEntryPoints((prev) => {
            const next = new Map(prev);
            next.set(project_path, entry_points);
            projectEntryPointsRef.current = next;
            return next;
          });
          setProjectTypeInfo((prev) => {
            const next = new Map(prev);
            next.set(project_path, type_info);
            return next;
          });
          break;
        }
        case "agents_list": {
          setAgents(msg.agents);
          const nextDefaultAgent = msg.default_agent ?? "";
          defaultAgentRef.current = nextDefaultAgent;
          setDefaultAgent(nextDefaultAgent);
          setAgentsLoaded(true);
          break;
        }
        case "task_created": {
          const tid = msg.tid;
          const workspace = msg.workspace || "";
          const projectPath = msg.project_path || "";
          const parentTid = msg.parent_tid || undefined;
          const relationType = msg.relation_type || undefined;

          const correlationId = msg.correlation_id;
          const projectKey = correlationId
            ? correlationToProjectRef.current.get(correlationId)
            : undefined;
          if (projectKey && correlationId) {
            const before = getSlot(draftStateRef.current, projectKey);
            if (
              before.remote.kind !== "creating" ||
              before.remote.correlationId !== correlationId
            ) {
              throw new Error(
                "Draft create index does not match reducer state",
              );
            }
            if (
              before.project.workspace !== workspace ||
              before.project.projectPath !== projectPath
            ) {
              throw new Error(
                "Draft creation acknowledgement has wrong project",
              );
            }
            const currentDesired =
              before.desired.kind !== "none" &&
              before.desired.uuid === correlationId
                ? before.desired
                : null;
            const result = applyDraftEvent({
              type: "task-created",
              correlationId,
              tid,
            });
            expectedFocusRef.current.add(`0:${tid}`);
            if (currentDesired) {
              materializeDraftTask(
                tid,
                workspace,
                projectPath,
                parentTid,
                relationType,
                currentDesired,
              );
            }
            if (currentDesired?.kind === "submitting") {
              requestTaskHistory(tid);
            }
            executeDraftEffects(result.effects);
            if (currentDesired?.kind === "submitting") {
              const projectName = currentRouteProjectName(before.project, null);
              if (projectName) {
                routeRef.current(
                  taskPath(before.project.workspace, projectName, tid),
                  true,
                );
              }
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
          liveStates.set(t.uuid, t);
          tidToUuid.set(tid, t.uuid);
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(t.uuid, t);
            return next;
          });
          break;
        }
        case "tasks_list": {
          const updates = new Map<string, TaskState>();
          const effects: DraftEffect[] = [];
          for (const entry of msg.tasks) {
            const observation = taskObservationFromEntry(
              entry,
              (findByTid(entry.tid)?.messages.length ?? 0) > 0,
            );
            const tombstoneProjectKey = tombstoneTidToProjectRef.current.get(
              entry.tid,
            );
            if (tombstoneProjectKey) {
              const released = releaseTombstonedActivity(
                tombstoneProjectKey,
                observation,
              );
              if (!released) continue;
              effects.push(...released);
            }
            const projectKey = ownedTidToProjectRef.current.get(entry.tid);
            const result = projectKey
              ? applyDraftEvent({
                  type: "task-observed",
                  projectKey,
                  observation,
                })
              : null;
            const existingUuid = tidToUuid.get(entry.tid);
            const existing = existingUuid
              ? liveStates.get(existingUuid)
              : undefined;
            const state = taskStateFromEntry(entry, existing, existingUuid);
            liveStates.set(state.uuid, state);
            tidToUuid.set(entry.tid, state.uuid);
            updates.set(state.uuid, state);
            if (result) effects.push(...result.effects);
          }
          setTasks((prev) => {
            const next = new Map(prev);
            for (const [uuid, state] of updates) {
              next.set(uuid, state);
            }
            return next;
          });
          const epoch = openConnectionEpochRef.current;
          if (!isCurrentOpenEpoch(epoch))
            throw new Error("Tasks list arrived outside an open connection");
          tasksListEpochRef.current = epoch;
          setTasksListEpoch(epoch);
          executeDraftEffects(effects);
          break;
        }
        case "task_updated": {
          const entry = msg.task;
          const observation = taskObservationFromEntry(
            entry,
            (findByTid(entry.tid)?.messages.length ?? 0) > 0,
          );
          const tombstoneProjectKey = tombstoneTidToProjectRef.current.get(
            entry.tid,
          );
          const effects: DraftEffect[] = [];
          if (tombstoneProjectKey) {
            const released = releaseTombstonedActivity(
              tombstoneProjectKey,
              observation,
            );
            if (!released) break;
            effects.push(...released);
          }
          const projectKey = ownedTidToProjectRef.current.get(entry.tid);
          const result = projectKey
            ? applyDraftEvent({
                type: "task-observed",
                projectKey,
                observation,
              })
            : null;
          const existingUuid = tidToUuid.get(entry.tid);
          const existing = existingUuid
            ? liveStates.get(existingUuid)
            : undefined;
          const taskUpdated = taskStateFromEntry(entry, existing, existingUuid);
          liveStates.set(taskUpdated.uuid, taskUpdated);
          tidToUuid.set(entry.tid, taskUpdated.uuid);
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(taskUpdated.uuid, taskUpdated);
            return next;
          });
          if (result) effects.push(...result.effects);
          executeDraftEffects(effects);
          break;
        }
        case "focus_hint": {
          const fromTid = msg.from_tid;
          const toTid = msg.to_tid;
          const expectedKey = `${fromTid}:${toTid}`;
          if (expectedFocusRef.current.delete(expectedKey)) break;
          if (tombstoneTidToProjectRef.current.has(toTid)) break;
          const currentId = activeTaskIdRef.current;
          const currentTid = currentId !== null ? parseInt(currentId, 10) : NaN;
          const matches =
            fromTid === 0
              ? currentId === null || isNaN(currentTid)
              : currentId === String(fromTid);
          if (matches && tidToUuid.has(toTid)) {
            setActiveTaskId(String(toTid));
          }
          break;
        }
        case "task_reload": {
          const { tid } = msg;
          const t = findByTid(tid);
          if (!t) break;
          outbox.removeForTask(tid);
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
          if (String(tid) === activeTaskIdRef.current) {
            if (connRef.current?.requestHistory(tid, 0, deviceClass())) {
              requestedHistoryRef.current.add(t.uuid);
              final = {
                ...reset,
                pendingHistoryReplies: reset.pendingHistoryReplies + 1,
              };
            }
          }

          liveStates.set(t.uuid, final);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, final);
            return next;
          });
          break;
        }
        case "task_history_start": {
          const { tid, total } = msg;
          const t0 = findByTid(tid);
          if (!t0) break;
          const windowStart = msg.window_start ?? 0;
          // historyTotal drives the progress bar, so count only what will
          // actually be sent
          const t = {
            ...beginTaskHistoryReplay(t0, total - windowStart),
            historyWindowed: (msg.window_limit ?? 0) > 0,
            historyWindowStart: windowStart,
          };
          liveStates.set(t0.uuid, t);
          setTasks((prev) => {
            if (!prev.has(t0.uuid)) return prev;
            const next = new Map(prev);
            next.set(t0.uuid, t);
            return next;
          });
          break;
        }
        case "task_history_prepend_start": {
          // the staging state was created when the request went out; nothing to
          // do but let the batch flow into it
          break;
        }
        case "task_history_prepend_end": {
          const { tid, window_start: windowStart } = msg;
          const t0 = findByTid(tid);
          if (!t0) break;
          const staged = prependRef.current.get(t0.uuid);
          prependRef.current.delete(t0.uuid);
          if (!staged) break;

          const older = staged.state;
          const t: TaskState = {
            ...t0,
            // older messages sort before everything held, by construction:
            // every staged seq is below the batch's stopping point
            messages: [...older.messages, ...t0.messages],
            blocks: new Map([...older.blocks, ...t0.blocks]),
            replacementEvents: new Map([
              ...older.replacementEvents,
              ...t0.replacementEvents,
            ]),
            spawnedTidsByItemId: new Map([
              ...older.spawnedTidsByItemId,
              ...t0.spawnedTidsByItemId,
            ]),
            historyWindowStart: windowStart,
          };
          liveStates.set(t0.uuid, t);
          setTasks((prev) => {
            if (!prev.has(t0.uuid)) return prev;
            const next = new Map(prev);
            next.set(t0.uuid, t);
            return next;
          });
          break;
        }
        case "task_history_end": {
          const { tid } = msg;
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
            liveStates.set(t0.uuid, t);
            setTasks((prev) => {
              if (!prev.has(t0.uuid)) return prev;
              const next = new Map(prev);
              next.set(t0.uuid, t);
              return next;
            });
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
          liveStates.set(t0.uuid, t);

          setTasks((prev) => {
            if (!prev.has(t0.uuid)) return prev;
            const next = new Map(prev);
            next.set(t0.uuid, t);
            return next;
          });
          break;
        }
        case "title_update": {
          const { tid, title } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, title };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "suggestions_update": {
          const { tid, suggestions } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, suggestions };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "draft_updated": {
          const { tid, new_draft } = msg;
          const projectKey = ownedTidToProjectRef.current.get(tid);
          const result = projectKey
            ? applyDraftEvent({
                type: "task-observed",
                projectKey,
                observation: { tid, text: new_draft },
              })
            : null;
          const t = findByTid(tid);
          if (t) {
            const updated = { ...t, serverDraft: new_draft || undefined };
            liveStates.set(t.uuid, updated);
            setTasks((prev) => {
              if (!prev.has(t.uuid)) return prev;
              const next = new Map(prev);
              next.set(t.uuid, updated);
              return next;
            });
          }
          if (result) executeDraftEffects(result.effects);
          break;
        }
        case "task_deleted": {
          const { tid } = msg;
          const projectKey = ownedTidToProjectRef.current.get(tid);
          const deletedSlot = projectKey
            ? getSlot(draftStateRef.current, projectKey)
            : null;
          const deletedProject = deletedSlot?.project ?? null;
          const wasDeleting = deletedSlot?.remote.kind === "deleting";
          const result = projectKey
            ? applyDraftEvent({ type: "task-deleted", tid })
            : null;
          const uuid = tidToUuid.get(tid);
          outbox.removeForTask(tid);
          if (uuid) {
            liveStates.delete(uuid);
            tidToUuid.delete(tid);
            requestedHistoryRef.current.delete(uuid);
          }
          setTasks((prev) => {
            if (!uuid || !prev.has(uuid)) return prev;
            const next = new Map(prev);
            next.delete(uuid);
            return next;
          });
          if (result) executeDraftEffects(result.effects);
          if (deletedProject && !wasDeleting) {
            const projectName = currentRouteProjectName(deletedProject, tid);
            if (projectName) {
              routeRef.current(
                buildProjectHref(deletedProject.workspace, projectName),
                true,
              );
            }
          }
          break;
        }
        case "history_operations": {
          const { tid, history_operations } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, historyOperations: history_operations };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "undo_preview": {
          const { tid, messages_removed, count_unit } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const undoPending: UndoPending = {
            afterUuid: t.undoPending?.afterUuid ?? "",
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
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "undo_result": {
          const { tid, output } = msg;
          const t = findByTid(tid);
          if (!t) break;
          if (output) {
            const updated = { ...t, undoResult: output };
            liveStates.set(t.uuid, updated);
            setTasks((prev) => {
              const next = new Map(prev);
              next.set(t.uuid, updated);
              return next;
            });
            const { uuid } = t;
            setTimeout(() => {
              const cur = liveStates.get(uuid);
              if (!cur) return;
              const cleared = { ...cur, undoResult: null };
              liveStates.set(uuid, cleared);
              setTasks((prev) => {
                const next = new Map(prev);
                next.set(uuid, cleared);
                return next;
              });
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
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "permission_prompt": {
          const { tid, tool_use_id, tool_name, input } = msg;
          const t = findByTid(tid);
          if (!t) break;
          // Empty tool_use_id signals clear (prompt resolved)
          const pendingPermission = tool_use_id
            ? { toolUseId: tool_use_id, toolName: tool_name, input }
            : null;
          const updated = { ...t, pendingPermission };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "server_status": {
          setDevMode(msg.dev_mode ?? false);
          setHistoryWindowStep(
            deviceClass() === "mobile"
              ? (msg.history_window_mobile ?? 0)
              : (msg.history_window_desktop ?? 0),
          );
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
            [msg.agent]: msg,
          }));
          break;
        }
        case "error": {
          const errMsg = msg.message;
          const errTid = msg.tid;
          console.error("Server error:", errMsg, "tid:", errTid);
          const transition = receiveServerError(liveStates, errMsg, errTid);
          if (transition.tasks !== liveStates) {
            const task = findByTid(errTid!);
            liveStates.set(task!.uuid, transition.tasks.get(task!.uuid)!);
            setTasks((prev) => receiveServerError(prev, errMsg, errTid).tasks);
          }
          setServerError(transition.serverError);
          break;
        }
      }
    },
    [
      applyDraftEvent,
      currentRouteProjectName,
      executeDraftEffects,
      materializeDraftTask,
      releaseTombstonedActivity,
      requestTaskHistory,
      isCurrentOpenEpoch,
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
      | { kind: "control"; msg: ControlMessage };
    type BufferedMsg = BufferedPayload & { epoch: number };
    let buffer: BufferedMsg[] = [];
    const pendingHistoryBoundaries = new Map<
      number,
      { msg: HistoryBoundaryEvent; seq: number }[]
    >();
    let flushId: number | null = null;
    let flushTimerId: ReturnType<typeof setTimeout> | null = null;

    const handleAgentAck = (tid: number, nonce: string) => {
      if (tombstoneTidToProjectRef.current.has(tid)) return;
      const projectKey = ownedTidToProjectRef.current.get(tid);
      const effects = projectKey
        ? applyDraftEvent({
            type: "task-observed",
            projectKey,
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
      const updated = reduceAgentAck(t, nonce);
      if (updated !== t) {
        liveStates.set(uuid, updated);
        setTasks((map) => {
          const next = new Map(map);
          next.set(uuid, updated);
          return next;
        });
      }
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
      for (const item of batch) {
        if (!isCurrentOpenEpoch(item.epoch)) continue;
        if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "unconfirmed")
          handleUnconfirmedUserMessage(item.tid, item.msg, item.correlationId);
        else if (item.kind === "agentAck") handleAgentAck(item.tid, item.nonce);
        else if (item.kind === "historyBoundary") {
          if (tombstoneTidToProjectRef.current.has(item.tid)) continue;
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
          const updated = replaceHistoryBoundary(task, item.msg, item.seq);
          liveStates.set(uuid, updated);
          setTasks((prev) => new Map(prev).set(uuid, updated));
        } else {
          handleTaskMessage(item.tid, item.msg, item.seq, item.ts);
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
              let updated = initialTask;
              for (const replacement of matching)
                updated = replaceHistoryBoundary(
                  updated,
                  replacement.msg,
                  replacement.seq,
                );
              liveStates.set(uuid, updated);
              setTasks((prev) => new Map(prev).set(uuid, updated));
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

    conn.onStatusChange = (connected) => {
      if (!connected) {
        connectionEpochRef.current++;
        openConnectionEpochRef.current = null;
        cancelPendingFlush();
        buffer = [];
        pendingHistoryBoundaries.clear();
        setConnected(false);
        liveStates.clear();
        tidToUuid.clear();
        requestedHistoryRef.current.clear();
        outboxReplayedEpochRef.current = null;
        outboxAttemptedNoncesRef.current.clear();
        tasksListEpochRef.current = null;
        for (const runtime of createRuntimeRef.current.values())
          clearTimeout(runtime.handle);
        for (const runtime of saveRuntimeRef.current.values())
          clearTimeout(runtime.handle);
        createRuntimeRef.current.clear();
        saveRuntimeRef.current.clear();
        composerResetSequenceRef.current++;
        composerResetEpochRef.current = composerResetSequenceRef.current;
        composerResetRef.current.clear();
        applyDraftEvent({ type: "connection-reset" });
        expectedFocusRef.current.clear();
        draftAttachmentRef.current = null;
        routeProjectCacheRef.current = null;
        requestedProjectTypesRef.current.clear();
        readyDraftMetadataProjectsRef.current.clear();
        workspacesRef.current = [];
        projectEntryPointsRef.current = new Map();
        defaultAgentRef.current = "";
        setWorkspaces([]);
        setEntryPoints([]);
        setTypeInfo([]);
        setProjectEntryPoints(new Map());
        setProjectTypeInfo(new Map());
        setAgents([]);
        setDefaultAgent("");
        setDefaultTaskType("");
        setGlobalTaskTypesLoaded(false);
        setAgentsLoaded(false);
        setTasksListEpoch(null);
        setTasks(new Map());
        setAgentUsage({});
      } else {
        openConnectionEpochRef.current = connectionEpochRef.current;
        initialNoticeLoadRef.current = true;
      }
    };

    const enqueue = (item: BufferedPayload) => {
      const epoch = openConnectionEpochRef.current;
      if (!isCurrentOpenEpoch(epoch)) return;
      buffer.push({ ...item, epoch });
      scheduleFlush();
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
      enqueue({ kind: "unconfirmed", tid, msg, correlationId });
    };
    conn.onAgentAck = (tid, nonce) => {
      enqueue({ kind: "agentAck", tid, nonce });
    };
    conn.onControlMessage = (msg) => {
      enqueue({ kind: "control", msg });
    };
    conn.onClientError = (message) => {
      addToastRef.current("error", message);
    };
    conn.connect();
    return () => {
      cancelPendingFlush();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      conn.disconnect();
    };
  }, [
    handleTaskMessage,
    handleControlMessage,
    handleUnconfirmedUserMessage,
    isCurrentOpenEpoch,
  ]);

  // The workspace/project segments of a task URL are derived from the task; enforce
  // that. The URL is the source of truth for which task is open, so correct the URL
  // rather than teaching its consumers to tolerate a mismatch.
  //
  // `tasks` and `workspaces` are load-bearing dependencies and must not be removed
  // by a later cleanup. `taskContext` is a `useCallback([])` that reads a
  // module-level map and a ref, so neither the task list nor the workspace list
  // arriving would re-run this effect on its own — `tasks` and `workspaces` are
  // what make it fire.
  useEffect(() => {
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    const [ws, proj] = taskContext(tid);
    const target = canonicalTaskRedirect({
      tid,
      taskWorkspace: ws,
      taskProject: proj,
      urlWorkspace: activeWorkspace,
      urlProject: activeProject,
    });
    if (target !== null) routeRef.current(target, true);
  }, [
    activeTaskId,
    activeWorkspace,
    activeProject,
    tasks,
    workspaces,
    taskContext,
  ]);

  // Request history when the active task changes and hasn't been loaded yet
  useEffect(() => {
    if (!connected || activeTaskId === null) return;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    if (tombstoneTidToProjectRef.current.has(tid)) return;
    if (ownedTidToProjectRef.current.has(tid)) return;
    const t = findByTid(tid);
    if (!t) return;
    if (requestedHistoryRef.current.has(t.uuid)) return;
    if (t.historyLoaded) return;
    if (connRef.current?.requestHistory(tid, 0, deviceClass())) {
      requestedHistoryRef.current.add(t.uuid);
    }
  }, [connected, activeTaskId, tasks]);

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
  ]);

  const cachedRouteProject = (() => {
    const cached = routeProjectCacheRef.current;
    if (
      !cached ||
      !activeWorkspace ||
      !activeProject ||
      cached.workspace !== activeWorkspace ||
      cached.projectName !== activeProject ||
      !isCurrentOpenEpoch(cached.epoch)
    ) {
      routeProjectCacheRef.current = null;
      return null;
    }
    return cached;
  })();

  const routeProject = useMemo(() => {
    if (!connected || !activeWorkspace || !activeProject) return null;
    const workspace = workspaces.find(
      (candidate) => candidate.name === activeWorkspace,
    );
    const project = workspace?.projects.find(
      (candidate) => candidate.name === activeProject,
    );
    if (!workspace || !project) return null;
    return { workspace, projectName: activeProject, projectPath: project.path };
  }, [activeWorkspace, activeProject, workspaces]);

  if (
    routeProject &&
    isCurrentOpenEpoch(renderedConnectionEpoch) &&
    draftStateRef.current.slots[
      createProjectKey(routeProject.workspace.name, routeProject.projectPath)
    ]
  ) {
    routeProjectCacheRef.current = {
      epoch: renderedConnectionEpoch,
      workspace: routeProject.workspace.name,
      projectName: routeProject.projectName,
      projectPath: routeProject.projectPath,
    };
  }

  // Project task types are keyed by the canonical workspace metadata path,
  // which only exists after the workspace bootstrap has arrived.
  useEffect(() => {
    if (!connected || !routeProject) return;
    if (projectEntryPoints.has(routeProject.projectPath)) return;
    const epoch = renderedConnectionEpoch;
    if (!isCurrentOpenEpoch(epoch)) return;
    if (
      requestedProjectTypesRef.current.get(routeProject.projectPath) === epoch
    )
      return;
    const connection = connRef.current;
    if (!connection) return;
    connection.requestTaskTypes(routeProject.projectPath);
    if (isCurrentOpenEpoch(epoch))
      requestedProjectTypesRef.current.set(routeProject.projectPath, epoch);
  }, [
    connected,
    routeProject,
    projectEntryPoints,
    renderedConnectionEpoch,
    isCurrentOpenEpoch,
  ]);

  const routeDraftMetadata = useMemo(() => {
    if (!activeWorkspace || !activeProject) return null;
    if (!routeProject && cachedRouteProject) {
      return {
        workspace: cachedRouteProject.workspace,
        projectName: cachedRouteProject.projectName,
        projectPath: cachedRouteProject.projectPath,
        entryPoint: undefined,
        agent: "",
        metadataReady: false,
      };
    }
    if (!routeProject) {
      return {
        workspace: activeWorkspace,
        projectName: activeProject,
        projectPath: "",
        entryPoint: undefined,
        agent: "",
        metadataReady: false,
      };
    }
    const candidates = projectEntryPoints.get(routeProject.projectPath);
    const preferred =
      routeProject.workspace.default_task_type || defaultTaskType;
    const agentReady = !!routeProject.workspace.default_agent || agentsLoaded;
    const entryPoint =
      candidates &&
      agentReady &&
      (routeProject.workspace.default_task_type || globalTaskTypesLoaded)
        ? (candidates.find(
            (candidate) =>
              candidate.name === preferred || candidate.task_type === preferred,
          ) ?? candidates[0])
        : undefined;
    return {
      workspace: activeWorkspace,
      projectName: routeProject.projectName,
      projectPath: routeProject.projectPath,
      entryPoint,
      agent: agentReady
        ? routeProject.workspace.default_agent || defaultAgent
        : "",
      metadataReady: entryPoint !== undefined,
    };
  }, [
    activeWorkspace,
    activeProject,
    cachedRouteProject,
    routeProject,
    projectEntryPoints,
    defaultTaskType,
    globalTaskTypesLoaded,
    agentsLoaded,
    defaultAgent,
  ]);

  const setDraftAttachment = useCallback(
    (next: { projectKey: ProjectKey; routeTid: number | null } | null) => {
      const previous = draftAttachmentRef.current;
      if (
        previous?.projectKey === next?.projectKey &&
        previous?.routeTid === next?.routeTid
      )
        return;
      draftAttachmentRef.current = next;
      refreshDraftView();
    },
    [refreshDraftView],
  );

  const dispatchDraftIntent = useCallback(
    (event: DraftEvent) => {
      const result = applyDraftEvent(event);
      executeDraftEffects(result.effects);
    },
    [applyDraftEvent, executeDraftEffects],
  );

  const persistedSnapshot = useCallback(
    (task: TaskState, fallbackAgent: string): TaskSnapshot | null => {
      if (
        task.status !== "pending" ||
        task.messages.length !== 0 ||
        task.isProcessing ||
        !task.serverDraft?.trim() ||
        !task.entryPoint ||
        task.tid === null
      )
        return null;
      return {
        tid: task.tid,
        text: task.serverDraft,
        entryPoint: task.entryPoint,
        agent: task.agentName ?? fallbackAgent,
        active: task.alive,
        processing: task.isProcessing,
        hasMessages: false,
      };
    },
    [],
  );

  const switchStablePersistedRoute = useCallback(
    (projectKey: ProjectKey, task: TaskState, snapshot: TaskSnapshot) => {
      const slot = getSlot(draftStateRef.current, projectKey);
      if (
        slot.desired.kind !== "editing" ||
        slot.remote.kind !== "present" ||
        slot.remote.tid === snapshot.tid ||
        (slot.remote.generation !== null &&
          slot.remote.generation !== slot.desired.uuid)
      )
        return false;
      const switched = applyDraftEvent({
        type: "switch-persisted",
        projectKey,
        uuid: task.uuid,
        snapshot,
      });
      executeDraftEffects(switched.effects);
      return true;
    },
    [applyDraftEvent, executeDraftEffects],
  );

  useLayoutEffect(() => {
    if (
      !isCurrentOpenEpoch(renderedConnectionEpoch) ||
      !connected ||
      !routeDraftMetadata?.metadataReady ||
      !routeDraftMetadata.projectPath ||
      !routeDraftMetadata.entryPoint ||
      activeTaskId === null
    )
      return;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    const task = findByTid(tid);
    if (
      !task ||
      task.workspace !== routeDraftMetadata.workspace ||
      task.projectPath !== routeDraftMetadata.projectPath
    )
      return;
    const snapshot = persistedSnapshot(task, routeDraftMetadata.agent);
    if (!snapshot) return;
    const projectKey = createProjectKey(
      routeDraftMetadata.workspace,
      routeDraftMetadata.projectPath,
    );
    if (!draftStateRef.current.slots[projectKey]) return;
    switchStablePersistedRoute(projectKey, task, snapshot);
  }, [
    activeTaskId,
    connected,
    draftRevision,
    isCurrentOpenEpoch,
    persistedSnapshot,
    renderedConnectionEpoch,
    routeDraftMetadata,
    switchStablePersistedRoute,
    tasks,
  ]);

  useEffect(() => {
    if (!isCurrentOpenEpoch(renderedConnectionEpoch)) return;
    if (!connected || !routeDraftMetadata?.projectPath) {
      setDraftAttachment(null);
      return;
    }
    const projectKey = createProjectKey(
      routeDraftMetadata.workspace,
      routeDraftMetadata.projectPath,
    );
    const existingSlot = draftStateRef.current.slots[projectKey];
    if (routeDraftMetadata.metadataReady) {
      const entryPoint = routeDraftMetadata.entryPoint;
      if (!entryPoint) {
        throw new Error("Resolved draft metadata lacks an entry point");
      }
      const metadataWasReady =
        readyDraftMetadataProjectsRef.current.has(projectKey);
      readyDraftMetadataProjectsRef.current.add(projectKey);
      if (!existingSlot) {
        const initialized = applyDraftEvent({
          type: "initialize-slot",
          project: {
            workspace: routeDraftMetadata.workspace,
            projectPath: routeDraftMetadata.projectPath,
          },
          defaults: {
            entryPoint: entryPoint.name,
            agent: routeDraftMetadata.agent,
          },
        });
        executeDraftEffects(initialized.effects);
      } else if (!metadataWasReady) {
        const resolved = applyDraftEvent({
          type: "resolve-metadata",
          projectKey,
          entryPoint: entryPoint.name,
          agent: routeDraftMetadata.agent,
        });
        executeDraftEffects(resolved.effects);
      }
    } else {
      readyDraftMetadataProjectsRef.current.delete(projectKey);
      if (!existingSlot) {
        const initialized = applyDraftEvent({
          type: "initialize-slot",
          project: {
            workspace: routeDraftMetadata.workspace,
            projectPath: routeDraftMetadata.projectPath,
          },
          defaults: {
            entryPoint: null,
            agent: null,
          },
        });
        executeDraftEffects(initialized.effects);
      }
    }
    routeProjectCacheRef.current = {
      epoch: renderedConnectionEpoch,
      workspace: routeDraftMetadata.workspace,
      projectName: routeDraftMetadata.projectName,
      projectPath: routeDraftMetadata.projectPath,
    };

    if (activeTaskId === null) {
      setDraftAttachment({ projectKey, routeTid: null });
      return;
    }

    const tid = parseTaskId(activeTaskId);
    if (tid === null) {
      setDraftAttachment(null);
      return;
    }
    const task = findByTid(tid);
    if (
      !task ||
      task.workspace !== routeDraftMetadata.workspace ||
      task.projectPath !== routeDraftMetadata.projectPath
    ) {
      setDraftAttachment(null);
      return;
    }
    const slot = getSlot(draftStateRef.current, projectKey);
    if (
      (slot.remote.kind === "present" || slot.remote.kind === "deleting") &&
      slot.remote.tid === tid
    ) {
      setDraftAttachment({ projectKey, routeTid: tid });
      return;
    }
    const snapshot = persistedSnapshot(task, routeDraftMetadata.agent);
    if (!snapshot) {
      setDraftAttachment(null);
      return;
    }
    if (
      slot.remote.kind === "creating" ||
      slot.remote.kind === "deleting" ||
      slot.desired.kind === "submitting"
    ) {
      setDraftAttachment(null);
      return;
    }
    if (slot.desired.kind === "none" && slot.remote.kind === "absent") {
      const adopted = applyDraftEvent({
        type: "adopt-persisted",
        projectKey,
        uuid: task.uuid,
        snapshot,
      });
      executeDraftEffects(adopted.effects);
      setDraftAttachment({ projectKey, routeTid: tid });
      return;
    }
    if (switchStablePersistedRoute(projectKey, task, snapshot)) {
      setDraftAttachment({ projectKey, routeTid: tid });
      return;
    }
    setDraftAttachment(null);
  }, [
    activeTaskId,
    applyDraftEvent,
    connected,
    draftRevision,
    executeDraftEffects,
    persistedSnapshot,
    routeDraftMetadata,
    renderedConnectionEpoch,
    isCurrentOpenEpoch,
    setDraftAttachment,
    switchStablePersistedRoute,
    tasks,
  ]);

  const editDraftText = useCallback(
    (projectKey: ProjectKey, text: string) => {
      const slot = getSlot(draftStateRef.current, projectKey);
      if (slot.desired.kind !== "none" && text.trim().length === 0) {
        clearComposerImages(projectKey);
      }
      dispatchDraftIntent({
        type: "edit-text",
        projectKey,
        text,
        ...(slot.desired.kind === "none" && text.trim().length > 0
          ? { uuid: crypto.randomUUID() }
          : {}),
      });
    },
    [clearComposerImages, dispatchDraftIntent],
  );

  const submitDraft = useCallback(
    (projectKey: ProjectKey, images: ImageAttachment[]) => {
      const slot = getSlot(draftStateRef.current, projectKey);
      const presentSubmission =
        slot.remote.kind === "present" ? { tid: slot.remote.tid } : null;
      const result = applyDraftEvent({
        type: "submit",
        projectKey,
        images,
        ...(slot.desired.kind === "none" ? { uuid: crypto.randomUUID() } : {}),
      });
      if (presentSubmission) requestTaskHistory(presentSubmission.tid);
      executeDraftEffects(result.effects);
      if (presentSubmission) {
        const projectName = currentRouteProjectName(slot.project, null);
        if (!projectName) return;
        routeRef.current(
          taskPath(slot.project.workspace, projectName, presentSubmission.tid),
          true,
        );
      }
    },
    [
      applyDraftEvent,
      currentRouteProjectName,
      executeDraftEffects,
      requestTaskHistory,
    ],
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

  const fork = useCallback((tid: number, afterUuid: string) => {
    connRef.current?.forkTask(tid, afterUuid);
  }, []);

  const undo = useCallback(
    (
      tid: number,
      afterUuid: string,
      dryRun: boolean,
      revertConversation: boolean,
      revertFiles: boolean,
    ) => {
      connRef.current?.undoTask(
        tid,
        afterUuid,
        dryRun,
        revertConversation,
        revertFiles,
      );
    },
    [],
  );

  const undoPreview = useCallback((tid: number, afterUuid: string) => {
    // Optimistically set afterUuid so confirmation bar can reference it
    const t = findByTid(tid);
    if (t) {
      const boundary = [...t.replacementEvents.values()].find(
        (event) =>
          (event as { history_boundary?: { anchor: string } }).history_boundary
            ?.anchor === afterUuid,
      ) as
        | {
            history_boundary?: {
              checkpoint_uuid?: string;
              kind: "user" | "agent_turn";
            };
          }
        | undefined;
      const canRevertFiles = !!boundary?.history_boundary?.checkpoint_uuid;
      const undoPending: UndoPending = {
        afterUuid,
        kind: "requesting",
        canRevertFiles,
        retainsPrompt: boundary?.history_boundary?.kind === "agent_turn",
        supportsFileRevert: t.sessionInfo?.supports_file_revert !== false,
      };
      const updated = {
        ...t,
        undoPending,
      };
      liveStates.set(t.uuid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(t.uuid, updated);
        return next;
      });
    }
    connRef.current?.undoTask(tid, afterUuid, true, false, false);
  }, []);

  const undoConfirm = useCallback(
    (tid: number, revertConversation: boolean, revertFiles: boolean) => {
      const t = findByTid(tid);
      if (!t?.undoPending) return;
      const pending = t.undoPending;
      connRef.current?.undoTask(
        tid,
        pending.afterUuid,
        false,
        revertConversation,
        revertFilesForUndo(pending.canRevertFiles, revertFiles),
        pending.kind === "codex_turns" ? pending.messagesRemoved : undefined,
      );
      // Clear undoPending
      const updated = { ...t, undoPending: null };
      liveStates.set(t.uuid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(t.uuid, updated);
        return next;
      });
    },
    [],
  );

  const undoDismiss = useCallback((tid: number) => {
    const t = findByTid(tid);
    if (!t) return;
    const updated = { ...t, undoPending: null };
    liveStates.set(t.uuid, updated);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(t.uuid, updated);
      return next;
    });
  }, []);

  const dismissAttention = useCallback((tid: number) => {
    connRef.current?.dismissAttention(tid);
  }, []);

  const clearInputDraft = useCallback((tid: number) => {
    const t = findByTid(tid);
    if (!t?.inputDraft) return;
    const updated = { ...t, inputDraft: undefined };
    liveStates.set(t.uuid, updated);
    setTasks((prev) => {
      if (!prev.has(t.uuid)) return prev;
      const next = new Map(prev);
      next.set(t.uuid, updated);
      return next;
    });
  }, []);

  const resume = useCallback((uuid: string) => {
    const t = liveStates.get(uuid);
    if (!t || t.tid === null || t.archived) return;
    connRef.current?.resumeTask(t.tid);
    const updated: TaskState = {
      ...t,
      alive: true,
      resumable: false,
      status: "active",
    };
    liveStates.set(uuid, updated);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(uuid, updated);
      return next;
    });
  }, []);

  const promote = useCallback((tid: number) => {
    const t = findByTid(tid);
    if (!t || t.status !== "importable") return;
    connRef.current?.promoteTask(tid, activeWorkspaceRef.current ?? "");
  }, []);

  const setArchived = useCallback((tid: number, archived: boolean) => {
    connRef.current?.setArchived(tid, archived);
  }, []);

  const saveDraft = useCallback((tid: number, draft: string) => {
    connRef.current?.saveDraft(tid, draft);
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
    liveStates.set(task.uuid, updated);
    setTasks((previous) => {
      const next = new Map(previous);
      next.set(task.uuid, updated);
      return next;
    });
  }, []);

  const sendAskUserResponse = useCallback((tid: number, content: string) => {
    connRef.current?.sendAskUserResponse(tid, content);
    // Optimistically clear the pending question
    const t = findByTid(tid);
    if (t) {
      const updated = { ...t, pendingAskUser: null, isProcessing: true };
      liveStates.set(t.uuid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(t.uuid, updated);
        return next;
      });
    }
  }, []);

  const sendPermissionPromptResponse = useCallback(
    (tid: number, content: string) => {
      connRef.current?.sendPermissionPromptResponse(tid, content);
      // Optimistically clear the pending permission prompt
      const t = findByTid(tid);
      if (t) {
        const updated = { ...t, pendingPermission: null, isProcessing: true };
        liveStates.set(t.uuid, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(t.uuid, updated);
          return next;
        });
      }
    },
    [],
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
    const projectPath = routeDraftMetadata?.projectPath;
    if (projectPath) {
      const projectEps = projectEntryPoints.get(projectPath);
      if (projectEps) return projectEps;
    }
    return entryPoints;
  }, [entryPoints, projectEntryPoints, routeDraftMetadata]);

  const resolvedTypeInfo = useMemo(() => {
    const projectPath = routeDraftMetadata?.projectPath;
    if (projectPath) {
      const projectTi = projectTypeInfo.get(projectPath);
      if (projectTi) return projectTi;
    }
    return typeInfo;
  }, [projectTypeInfo, routeDraftMetadata, typeInfo]);

  const draftView = useMemo<DraftView | null>(() => {
    if (!routeDraftMetadata) return null;
    const routeViewKey = `route:${routeDraftMetadata.workspace}\0${routeDraftMetadata.projectName}`;
    if (!routeDraftMetadata.projectPath) {
      if (activeTaskId !== null) return null;
      return {
        kind: "unresolved",
        viewKey: routeViewKey,
        workspace: routeDraftMetadata.workspace,
        projectName: routeDraftMetadata.projectName,
        projectPath: routeDraftMetadata.projectPath,
        remoteTid: null,
        text: "",
        entryPoint: "",
        agent: "",
        lifecycle: "idle",
        disabled: true,
        metadataReady: false,
        composerResetToken: 0,
      };
    }
    const projectKey = createProjectKey(
      routeDraftMetadata.workspace,
      routeDraftMetadata.projectPath,
    );
    const slot = draftStateRef.current.slots[projectKey];
    const composerDisabled = !connected;
    if (activeTaskId === null) {
      if (!slot) {
        return {
          kind: "unresolved",
          viewKey: routeViewKey,
          workspace: routeDraftMetadata.workspace,
          projectName: routeDraftMetadata.projectName,
          projectPath: routeDraftMetadata.projectPath,
          remoteTid: null,
          text: "",
          entryPoint: "",
          agent: "",
          lifecycle: "idle",
          disabled: true,
          metadataReady: false,
          composerResetToken: 0,
        };
      }
      return makeDraftViewSnapshot(
        slot,
        projectKey,
        routeDraftMetadata.projectName,
        composerDisabled,
        routeDraftMetadata.metadataReady,
        composerResetTokenFor(projectKey),
        editDraftText,
        dispatchDraftIntent,
        submitDraft,
      );
    }

    const tid = parseTaskId(activeTaskId);
    if (tid === null || !slot) return null;
    if (
      (slot.remote.kind === "present" || slot.remote.kind === "deleting") &&
      slot.remote.tid === tid
    ) {
      return makeDraftViewSnapshot(
        slot,
        projectKey,
        routeDraftMetadata.projectName,
        composerDisabled,
        routeDraftMetadata.metadataReady,
        composerResetTokenFor(projectKey),
        editDraftText,
        dispatchDraftIntent,
        submitDraft,
      );
    }
    if (!routeDraftMetadata.metadataReady) return null;
    const task = findByTid(tid);
    const snapshot =
      task &&
      task.workspace === routeDraftMetadata.workspace &&
      task.projectPath === routeDraftMetadata.projectPath
        ? persistedSnapshot(task, routeDraftMetadata.agent)
        : null;
    if (
      !snapshot ||
      slot.desired.kind !== "editing" ||
      slot.remote.kind !== "present" ||
      (slot.remote.generation !== null &&
        slot.remote.generation !== slot.desired.uuid)
    )
      return null;
    return makeDraftViewSnapshot(
      slot,
      projectKey,
      routeDraftMetadata.projectName,
      true,
      true,
      composerResetTokenFor(projectKey),
      editDraftText,
      dispatchDraftIntent,
      submitDraft,
    );
  }, [
    activeTaskId,
    connected,
    composerResetTokenFor,
    dispatchDraftIntent,
    draftRevision,
    editDraftText,
    persistedSnapshot,
    routeDraftMetadata,
    submitDraft,
    tasks,
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
        // Importable tasks have workspace="" — match by projectPath instead
        if (!t.workspace) {
          return t.projectPath === activeProjectPath;
        }
        const projName = findProjectName(
          workspaces,
          t.workspace,
          t.projectPath,
        );
        return t.workspace === activeWorkspace && projName === activeProject;
      });
    }
    const result = filtered
      .sort((a, b) => a.tid - b.tid)
      .map((t) => ({
        tid: t.tid,
        alive: t.alive,
        canStop: t.canStop,
        resumable: t.resumable,
        isProcessing: t.isProcessing,
        stdinClosed: t.stdinClosed,
        title:
          t.title ||
          (t.status === "pending" && t.messages.length === 0 && t.serverDraft
            ? t.serverDraft.replace(/\s+/g, " ").trim().slice(0, 100)
            : undefined),
        parentTid: t.parentTid,
        relationType: t.relationType,
        status: t.status,
        archived: t.archived,
        archiving: t.archiving,
        taskType: t.taskType,
        hasPendingQuestion: t.hasPendingQuestion,
        hasMessages: t.messages.length > 0,
      }));

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
  }, [tasks, activeWorkspace, activeProject, workspaces]);

  const getProjectedByTid = useCallback((tid: number) => {
    if (tombstoneTidToProjectRef.current.has(tid)) return undefined;
    return findByTid(tid);
  }, []);

  const tasksLoaded =
    tasksListEpoch !== null &&
    tasksListEpoch === renderedConnectionEpoch &&
    tasksListEpochRef.current === renderedConnectionEpoch &&
    isCurrentOpenEpoch(renderedConnectionEpoch);

  return {
    tasks,
    activeTaskId,
    activeTaskIdRef,
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
    agents,
    defaultAgent,
    defaultTaskType,
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
    historyWindowStep,
    loadMoreHistory,
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
