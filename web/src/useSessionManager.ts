// Custom hook: WebSocket connection, rAF message buffering, task state, and user actions.

// Stateful hook with one-time effects and closure-captured callbacks.
// HMR can't safely update a running instance — force full reload.
if (import.meta.hot) import.meta.hot.invalidate();

import {
  useState,
  useEffect,
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
  Notice,
} from "./protocol";
import type { CydoMeta, TaskState } from "./types";
import { makeTaskState } from "./types";
import { reduceMessage } from "./sessionReducer";
import { canonicalUserTextFromDisplayMessage } from "./userText";
import { drafts as inputDrafts } from "./components/InputBox";
import { outbox } from "./outbox";
import { resetTaskForHistoryReplay } from "./historyReplayReset";

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

type DraftPhase =
  | { phase: "none" }
  | { phase: "virtual"; uuid: string }
  | {
      phase: "timer_pending";
      uuid: string;
      timerId: ReturnType<typeof setTimeout>;
      entryPoint?: string;
      agentType?: string;
    }
  | { phase: "create_pending"; uuid: string }
  | { phase: "create_cancelled"; uuid: string }
  | {
      phase: "send_pending";
      uuid: string;
      firstMessage: {
        text: string;
        entryPointName?: string;
        images?: ImageAttachment[];
      };
    }
  | { phase: "promoted"; uuid: string };

function buildContentBlocks(
  text: string,
  images?: ImageAttachment[],
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
  read_only: boolean;
  icon?: string;
}

export interface TypeInfo {
  name: string;
  icon?: string;
}

export interface TaskManager {
  tasks: Map<string, TaskState>;
  activeTaskId: string | null;
  activeTaskIdRef: { current: string | null };
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  send: (
    uuid: string,
    text: string,
    images?: ImageAttachment[],
    entryPointName?: string,
    agentType?: string,
  ) => void;
  interrupt: (uuid: string) => void;
  stop: (uuid: string) => void;
  closeStdin: (uuid: string) => void;
  resume: (uuid: string) => void;
  promote: (tid: number) => void;
  fork: (tid: number, afterUuid: string) => void;
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
  setEntryPoint: (tid: number, entryPoint: string) => void;
  setAgentName: (tid: number, agentName: string) => void;
  sendAskUserResponse: (tid: number, content: string) => void;
  sendPermissionPromptResponse: (tid: number, content: string) => void;
  editMessage: (tid: number, uuid: string, content: string) => void;
  editRawEvent: (tid: number, seq: number, content: string) => void;
  createDraftTask: (entryPointName?: string, agentType?: string) => void;
  deleteDraftTask: () => void;
  draftRenderKey: string | null;
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
  devMode: boolean;
  exportLoadError?: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  getByTid: (tid: number) => TaskState | undefined;
  refreshWorkspaces: () => void;
  refreshingWorkspaces: boolean;
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
// Every task with a real tid has an entry here; virtual drafts (tid=null) do not.
const tidToUuid = new Map<number, string>();

function findByTid(tid: number): TaskState | undefined {
  const uuid = tidToUuid.get(tid);
  return uuid ? liveStates.get(uuid) : undefined;
}

/** Convert a string task id to a numeric tid; returns null for non-numeric strings. */
function parseTaskId(id: string | null): number | null {
  if (id === null) return null;
  const n = parseInt(id, 10);
  return String(n) === id ? n : null;
}

function encodeProjectName(projectName: string): string {
  return projectName.replace(/\//g, ":");
}

function buildProjectHref(workspace: string, projectName: string): string {
  return `/${workspace}/${encodeProjectName(projectName)}`;
}

function buildScopedHref(
  workspace: string | null,
  projectName: string | null,
  suffix: string,
): string {
  if (workspace && projectName) {
    return `${buildProjectHref(workspace, projectName)}${suffix}`;
  }
  return suffix;
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
  const [refreshingWorkspaces, setRefreshingWorkspaces] = useState(false);
  const [entryPoints, setEntryPoints] = useState<EntryPointInfo[]>([]);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);
  const [projectEntryPoints, setProjectEntryPoints] = useState<
    Map<string, EntryPointInfo[]>
  >(new Map());
  const [projectTypeInfo, setProjectTypeInfo] = useState<
    Map<string, TypeInfo[]>
  >(new Map());
  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [defaultAgent, setDefaultAgent] = useState("claude");
  const [defaultTaskType, setDefaultTaskType] = useState("");
  const [notices, setNotices] = useState<Record<string, Notice>>({});
  const [localNotices, setLocalNotices] = useState<Record<string, Notice>>({});
  const [agentUsage, setAgentUsage] = useState<
    Record<string, AgentUsageMessage>
  >({});
  const [devMode, setDevMode] = useState(false);
  const addToastRef = useRef(addToast);
  addToastRef.current = addToast;
  const prevNoticeIdsRef = useRef<Set<string>>(new Set());
  const initialNoticeLoadRef = useRef(true);
  const { route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;

  const { params, path } = useRoute();
  const parsed = useMemo(() => {
    // Archive routes set parentTid param; derive the virtual archive ID
    const isArchive = path.includes("/archive");
    const isImport = path.includes("/import");
    const tid = isArchive
      ? params.parentTid
        ? `archive:${params.parentTid}`
        : "archive"
      : isImport
        ? "import"
        : (params.tid ?? params.sid ?? null);
    return {
      workspace: params.workspace ?? null,
      project: params.project ? params.project.replace(/:/g, "/") : null,
      tid,
    };
  }, [
    path,
    params.workspace,
    params.project,
    params.tid,
    params.sid,
    params.parentTid,
  ]);
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
        return buildScopedHref(
          ws ?? activeWorkspaceRef.current,
          proj ?? activeProjectRef.current,
          `/task/${id}`,
        );
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

  // Draft task management state
  const draftRef = useRef<DraftPhase>({ phase: "none" });
  const [draftRenderKey, setDraftRenderKey] = useState<string | null>(null);
  // Set when a promoted draft is deleted; cleared on task_deleted.
  // Guards handleTaskMessage against stale history events.
  const deletedDraftTid = useRef<number | null>(null);

  const setDraft = useCallback((next: DraftPhase) => {
    draftRef.current = next;
    const rk = next.phase !== "none" ? next.uuid : null;
    setDraftRenderKey((prev) => (prev === rk ? prev : rk));
  }, []);

  /** Remove virtual draft from task map and input drafts. */
  const teardownVirtualDraft = useCallback(() => {
    const draft = draftRef.current;
    const uuid = draft.phase !== "none" ? draft.uuid : null;
    if (!uuid) return;
    liveStates.delete(uuid);
    setTasks((prev) => {
      if (!prev.has(uuid)) return prev;
      const next = new Map(prev);
      next.delete(uuid);
      return next;
    });
    inputDrafts.delete(uuid);
  }, []);

  /** Clear draft state when navigating away. Handles all phases correctly. */
  const clearDraftForNav = useCallback(
    (opts: { teardownVirtual: boolean }) => {
      const cur = draftRef.current;
      if (cur.phase === "none") return;
      if (cur.phase === "timer_pending") clearTimeout(cur.timerId);
      if (opts.teardownVirtual) teardownVirtualDraft();
      if (cur.phase === "create_pending") {
        setDraft({
          phase: "create_cancelled",
          uuid: cur.uuid,
        });
      } else if (
        !opts.teardownVirtual &&
        (cur.phase === "create_cancelled" || cur.phase === "send_pending")
      ) {
        // navigate-to-task: leave these phases active so task_created can
        // still clean up the zombie or deliver the pending message.
      } else {
        setDraft({ phase: "none" });
      }
    },
    [setDraft, teardownVirtualDraft],
  );

  const createVirtualDraft = useCallback(() => {
    const ws = activeWorkspaceRef.current ?? "";
    const proj = activeProjectRef.current;
    const projPath = proj
      ? (findProjectPath(workspacesRef.current, ws, proj) ?? "")
      : "";
    const t = makeTaskState(null, false, false, undefined, true, ws, projPath);
    liveStates.set(t.uuid, t);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(t.uuid, t);
      return next;
    });
    setDraft({ phase: "virtual", uuid: t.uuid });
    return t.uuid;
  }, [setDraft]);

  const createDraftTask = useCallback(
    (entryPointName?: string, agentType?: string) => {
      const cur = draftRef.current;
      if (cur.phase !== "virtual") return;
      const ws = activeWorkspaceRef.current;
      const proj = activeProjectRef.current;
      if (!ws || !proj) return;
      const { uuid } = cur;
      // Debounce: delay sending create_task so that rapid fill()+click()
      // sequences (common in Playwright tests) don't create zombie tasks.
      const timerId = setTimeout(() => {
        const projPath = findProjectPath(workspacesRef.current, ws, proj);
        setDraft({ phase: "create_pending", uuid });
        // The draft's uuid serves as the correlation_id for the handshake.
        connRef.current?.createTask(
          ws,
          projPath || "",
          entryPointName,
          undefined,
          agentType,
          uuid,
        );
      }, 16);
      setDraft({
        phase: "timer_pending",
        uuid,
        timerId,
        entryPoint: entryPointName,
        agentType,
      });
    },
    [setDraft],
  );

  const deleteDraftTask = useCallback(() => {
    const cur = draftRef.current;
    switch (cur.phase) {
      case "timer_pending":
        clearTimeout(cur.timerId);
        setDraft({ phase: "virtual", uuid: cur.uuid });
        return;

      case "promoted": {
        const { uuid } = cur;
        const existing = liveStates.get(uuid);
        const tid = existing?.tid ?? null;
        if (tid !== null) {
          // Real backend task — delete it
          deletedDraftTid.current = tid;
          connRef.current?.deleteTask(tid);
          tidToUuid.delete(tid);
        }
        inputDrafts.delete(uuid);
        liveStates.delete(uuid);
        setTasks((prev) => {
          if (!prev.has(uuid)) return prev;
          const next = new Map(prev);
          next.delete(uuid);
          return next;
        });
        // Reset virtual draft reusing the same uuid so InputBox key stays stable
        const ws = activeWorkspaceRef.current ?? "";
        const proj = activeProjectRef.current;
        const projPath = proj
          ? (findProjectPath(workspacesRef.current, ws, proj) ?? "")
          : "";
        const t: TaskState = {
          ...makeTaskState(null, false, false, undefined, true, ws, projPath),
          uuid,
          entryPoint: existing?.entryPoint,
          taskType: existing?.taskType,
          agentType: existing?.agentType,
        };
        // Clear stale in-memory draft so InputBox starts fresh on the next cycle
        inputDrafts.delete(uuid);
        liveStates.set(uuid, t);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(uuid, t);
          return next;
        });
        setDraft({ phase: "virtual", uuid });
        // Navigate back to project root so activeTaskId becomes null
        // and the virtual draft view renders.
        if (ws && proj) {
          const encodedProject = proj.replace(/\//g, ":");
          routeRef.current(`/${ws}/${encodedProject}`, true);
        }
        return;
      }

      case "create_pending":
        setDraft({
          phase: "create_cancelled",
          uuid: cur.uuid,
        });
        return;

      default:
        return; // none, virtual, send_pending, create_cancelled — no-op
    }
  }, [setDraft]);

  // -- Live stdout message handler --
  // Reduces against the mutable liveStates map (synchronous), fires
  // notifications, then enqueues a Preact state update for rendering.
  const handleUnconfirmedUserMessage = useCallback(
    (tid: number, msg: AgnosticEvent, correlationId?: string) => {
      const uuid = tidToUuid.get(tid);
      if (!uuid) return;
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
            i === idx ? { ...m, ackState: 3 as const, pending: true } : m,
          );
          const updated = { ...prev, messages };
          liveStates.set(uuid, updated);
          setTasks((map) => {
            const next = new Map(map);
            next.set(uuid, updated);
            return next;
          });
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
            rawSource: msg,
          },
        ],
      };
      liveStates.set(uuid, updated);
      setTasks((map) => {
        const next = new Map(map);
        next.set(uuid, updated);
        return next;
      });
    },
    [],
  );

  const handleTaskMessage = useCallback(
    (tid: number, msg: AgnosticEvent, seq?: number, ts?: number) => {
      // Skip stale events for recently deleted draft tasks (e.g. from
      // requestHistory responses arriving after deleteDraftTask).
      if (deletedDraftTid.current === tid) return;
      const uuid = tidToUuid.get(tid);
      if (!uuid) return;
      const prev = liveStates.get(uuid) ?? {
        ...makeTaskState(tid, true),
        uuid,
      };
      let updated = reduceMessage(prev, msg, seq, ts);
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
    },
    [],
  );

  const handleControlMessage = useCallback(
    (msg: ControlMessage) => {
      switch (msg.type) {
        case "workspaces_list": {
          setWorkspaces(msg.workspaces);
          setRefreshingWorkspaces(false);
          setConnected(true);
          break;
        }
        case "task_types_list": {
          setEntryPoints(msg.entry_points);
          setTypeInfo(msg.type_info);
          if (msg.default_task_type) setDefaultTaskType(msg.default_task_type);
          break;
        }
        case "project_task_types_list": {
          const { project_path, entry_points, type_info } = msg;
          setProjectEntryPoints((prev) => {
            const next = new Map(prev);
            next.set(project_path, entry_points);
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
          if (msg.default_agent) setDefaultAgent(msg.default_agent);
          break;
        }
        case "task_created": {
          const tid = msg.tid;
          const workspace = msg.workspace || "";
          const projectPath = msg.project_path || "";
          const parentTid = msg.parent_tid || undefined;
          const relationType = msg.relation_type || undefined;

          // Check if this is a draft task creation — the draft's uuid IS the correlation_id.
          const draft = draftRef.current;
          const isDraftCreation =
            (draft.phase === "create_pending" ||
              draft.phase === "create_cancelled" ||
              draft.phase === "send_pending") &&
            draft.uuid === msg.correlation_id;

          if (isDraftCreation) {
            const { uuid } = draft;

            if (draft.phase === "create_cancelled") {
              // User navigated away before task_created arrived — delete zombie.
              connRef.current?.deleteTask(tid);
              teardownVirtualDraft();
              setDraft({ phase: "none" });
              break;
            }

            const firstMsg =
              draft.phase === "send_pending" ? draft.firstMessage : null;

            // Clear the in-memory draft text when piggybacking a first message
            if (firstMsg !== null) {
              inputDrafts.set(uuid, "");
            }

            // The draft task state already exists in liveStates keyed by uuid.
            // Stamp the real tid onto it — no rekeying needed.
            const existing = liveStates.get(uuid);
            if (!existing) {
              console.warn("task_created with no matching draft", uuid);
              break;
            }
            const realTask: TaskState = {
              ...existing,
              tid,
              historyLoaded: true,
              everLoaded: true,
            };
            liveStates.set(uuid, realTask);
            tidToUuid.set(tid, uuid);
            setTasks((prev) => {
              const next = new Map(prev);
              next.set(uuid, realTask);
              return next;
            });

            // Subscribe to live events for the new task.
            connRef.current?.requestHistory(tid);
            requestedHistoryRef.current.add(uuid);

            if (firstMsg !== null) {
              // Path (c): user sent before task_created arrived — send now.
              // Navigate URL to reflect the real tid.
              if (workspace && projectPath) {
                const projName = findProjectName(
                  workspacesRef.current,
                  workspace,
                  projectPath,
                );
                if (projName) {
                  const encodedProject = projName.replace(/\//g, ":");
                  routeRef.current(
                    `/${workspace}/${encodedProject}/task/${tid}`,
                    true,
                  );
                }
              }
              connRef.current?.sendMessage(
                tid,
                buildContentBlocks(firstMsg.text, firstMsg.images),
              );
              setDraft({ phase: "none" });
              setTasks((prev) => {
                const taskState = prev.get(uuid);
                if (!taskState) return prev;
                const next = new Map(prev);
                next.set(uuid, {
                  ...taskState,
                  isProcessing: true,
                  suggestions: undefined,
                });
                return next;
              });
            } else {
              // User is still typing — navigate URL to reflect the real tid.
              setDraft({ phase: "promoted", uuid });
              if (workspace && projectPath) {
                const projName = findProjectName(
                  workspacesRef.current,
                  workspace,
                  projectPath,
                );
                if (projName) {
                  const encodedProject = projName.replace(/\//g, ":");
                  routeRef.current(
                    `/${workspace}/${encodedProject}/task/${tid}`,
                    true,
                  );
                }
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
          for (const entry of msg.tasks) {
            // Skip recently deleted draft tasks
            if (deletedDraftTid.current === entry.tid) continue;
            const workspace = entry.workspace || "";
            const projectPath = entry.project_path || "";
            const existingUuid = tidToUuid.get(entry.tid);
            const existing = existingUuid
              ? liveStates.get(existingUuid)
              : undefined;
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
              );
              const t: TaskState = {
                ...base,
                uuid: existingUuid ?? base.uuid,
                serverDraft: entry.draft || undefined,
                error: entry.error || undefined,
              };
              liveStates.set(t.uuid, t);
              tidToUuid.set(entry.tid, t.uuid);
              updates.set(t.uuid, t);
            } else {
              // If a task becomes resumable but has no messages loaded,
              // reset historyLoaded so JSONL history gets requested
              // (e.g. forked tasks with pre-existing JSONL).
              const needsHistory =
                entry.resumable &&
                existing.messages.length === 0 &&
                existing.historyLoaded;
              const updated: TaskState = {
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
                agentType: entry.agent_name || existing.agentType,
                suggestions:
                  entry.isProcessing && !existing.isProcessing
                    ? undefined
                    : existing.suggestions,
                archived: entry.archived || false,
                archiving: entry.archiving || false,
                error: entry.error || undefined,
                createdAt: entry.created_at || existing.createdAt,
                lastActive: entry.last_active || existing.lastActive,
              };
              liveStates.set(existingUuid, updated);
              updates.set(existingUuid, updated);
            }
          }
          setTasks((prev) => {
            const next = new Map(prev);
            for (const [uuid, state] of updates) {
              next.set(uuid, state);
            }
            return next;
          });
          break;
        }
        case "task_updated": {
          const entry = msg.task;
          // Skip updates for recently deleted draft tasks
          if (deletedDraftTid.current === entry.tid) break;
          const workspace = entry.workspace || "";
          const projectPath = entry.project_path || "";
          const existingUuid = tidToUuid.get(entry.tid);
          const existing = existingUuid
            ? liveStates.get(existingUuid)
            : undefined;
          let taskUpdated: TaskState;
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
            );
            taskUpdated = {
              ...base,
              uuid: existingUuid ?? base.uuid,
              serverDraft: entry.draft || undefined,
              error: entry.error || undefined,
            };
            liveStates.set(taskUpdated.uuid, taskUpdated);
            tidToUuid.set(entry.tid, taskUpdated.uuid);
          } else {
            const needsHistory =
              entry.resumable &&
              existing.messages.length === 0 &&
              existing.historyLoaded;
            taskUpdated = {
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
              agentType: entry.agent_name || existing.agentType,
              suggestions:
                entry.isProcessing && !existing.isProcessing
                  ? undefined
                  : existing.suggestions,
              archived: entry.archived || false,
              archiving: entry.archiving || false,
              error: entry.error || undefined,
              createdAt: entry.created_at || existing.createdAt,
              lastActive: entry.last_active || existing.lastActive,
            };
            liveStates.set(existingUuid, taskUpdated);
          }
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(taskUpdated.uuid, taskUpdated);
            return next;
          });
          break;
        }
        case "focus_hint": {
          const fromTid = msg.from_tid;
          const toTid = msg.to_tid;
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
          requestedHistoryRef.current.delete(t.uuid);

          const isEdit = msg.reason === "edit";
          // opensCycle: first reload of a new reconciliation cycle
          const opensCycle = t.pendingHistoryReplies === 0;

          let nextDrafts: string[] | undefined;
          if (opensCycle) {
            if (isEdit) {
              nextDrafts = undefined;
            } else {
              const snap = t.messages
                .filter((m) => m.type === "user")
                .map((m) => canonicalUserTextFromDisplayMessage(m))
                .filter((s) => s.length > 0);
              nextDrafts = snap.length > 0 ? snap : undefined;
            }
          } else {
            // Intermediate reload within an open cycle — preserve the snapshot
            // captured at cycle start so the final diff still has it.
            nextDrafts = t.preReloadDrafts;
          }

          const reset: TaskState = {
            ...makeTaskState(
              tid,
              false,
              t.resumable,
              t.title,
              false,
              t.workspace,
              t.projectPath,
              t.parentTid,
              t.relationType,
              t.status,
            ),
            uuid: t.uuid,
            resumable: t.resumable,
            everLoaded: t.everLoaded,
            preReloadDrafts: nextDrafts,
            pendingHistoryReplies: t.pendingHistoryReplies,
            undoResult: t.undoResult,
          };

          // Re-request history if this is the active task — the useEffect
          // won't re-fire because activeTaskId hasn't changed.
          let final = reset;
          if (String(tid) === activeTaskIdRef.current) {
            if (connRef.current?.requestHistory(tid)) {
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
          const t = resetTaskForHistoryReplay(t0, total);
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
          let inputDraft: string | undefined;
          if (t0.preReloadDrafts && t0.preReloadDrafts.length > 0) {
            const finalCounts = new Map<string, number>();
            for (const m of t0.messages) {
              if (m.type !== "user") continue;
              const s = canonicalUserTextFromDisplayMessage(m);
              if (s.length === 0) continue;
              finalCounts.set(s, (finalCounts.get(s) ?? 0) + 1);
            }
            const remaining: string[] = [];
            for (const text of t0.preReloadDrafts) {
              const c = finalCounts.get(text) ?? 0;
              if (c > 0) finalCounts.set(text, c - 1);
              else remaining.push(text);
            }
            inputDraft =
              remaining.length > 0 ? remaining.join("\n\n") : undefined;
          }

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
          const t = findByTid(tid);
          if (!t) break;
          const updated = { ...t, serverDraft: new_draft };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "task_deleted": {
          const { tid } = msg;
          const t = findByTid(tid);
          if (deletedDraftTid.current === tid) deletedDraftTid.current = null;
          if (t) {
            liveStates.delete(t.uuid);
            tidToUuid.delete(tid);
            requestedHistoryRef.current.delete(t.uuid);
          }
          setTasks((prev) => {
            if (!t || !prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.delete(t.uuid);
            return next;
          });
          break;
        }
        case "forkable_uuids": {
          const { tid, uuids } = msg;
          const t = findByTid(tid);
          if (!t) break;
          // Skip update if all UUIDs are already present — avoids
          // creating a new TaskState reference that would break memo
          // equality for MessageView components.
          if (uuids.every((u: string) => t.forkableUuids.has(u))) break;
          const merged = new Set(t.forkableUuids);
          for (const u of uuids) merged.add(u);
          const updated = { ...t, forkableUuids: merged };
          liveStates.set(t.uuid, updated);
          setTasks((prev) => {
            if (!prev.has(t.uuid)) return prev;
            const next = new Map(prev);
            next.set(t.uuid, updated);
            return next;
          });
          break;
        }
        case "assign_uuids": {
          const { tid, assignments } = msg;
          const t = findByTid(tid);
          if (!t) break;

          let changed = false;
          const messages = [...t.messages];
          const forkable = new Set(t.forkableUuids);

          for (const { uuid: msgUuid, seq } of assignments) {
            forkable.add(msgUuid);
            for (let i = messages.length - 1; i >= 0; i--) {
              const m = messages[i];
              if (!m) continue;
              if (m.type !== "user" && m.type !== "assistant") continue; // only patch forkable message types
              if (m.uuid) continue;
              const mSeq = m.seq;
              const seqMatch =
                typeof mSeq === "number"
                  ? mSeq === seq
                  : Array.isArray(mSeq) && mSeq.includes(seq);
              if (seqMatch) {
                messages[i] = { ...m, uuid: msgUuid } as typeof m;
                changed = true;
                break;
              }
            }
          }

          if (changed) {
            const updated = { ...t, messages, forkableUuids: forkable };
            liveStates.set(t.uuid, updated);
            setTasks((prev) => {
              if (!prev.has(t.uuid)) return prev;
              const next = new Map(prev);
              next.set(t.uuid, updated);
              return next;
            });
          }
          break;
        }
        case "undo_preview": {
          const { tid, messages_removed } = msg;
          const t = findByTid(tid);
          if (!t) break;
          const updated = {
            ...t,
            undoPending: {
              afterUuid: t.undoPending?.afterUuid ?? "",
              messagesRemoved: messages_removed,
            },
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
          // Clear undoPending if this error is for a task with an active undo dialog
          if (errTid !== undefined) {
            const t = findByTid(errTid);
            if (t?.undoPending) {
              const updated = { ...t, undoPending: null };
              liveStates.set(t.uuid, updated);
              setTasks((prev) => {
                const next = new Map(prev);
                next.set(t.uuid, updated);
                return next;
              });
            }
          }
          alert(errMsg);
          break;
        }
      }
    },
    [teardownVirtualDraft],
  );

  useEffect(() => {
    const conn = new Connection();
    connRef.current = conn;

    // Buffer incoming messages and flush on rAF so that hundreds of replay
    // messages are processed in a single render pass instead of one-per-message.
    type BufferedMsg =
      | {
          kind: "task";
          tid: number;
          msg: AgnosticEvent;
          seq?: number;
          ts?: number;
        }
      | {
          kind: "unconfirmed";
          tid: number;
          msg: AgnosticEvent;
          correlationId?: string;
        }
      | { kind: "agentAck"; tid: number; nonce: string }
      | { kind: "control"; msg: ControlMessage };
    let buffer: BufferedMsg[] = [];
    let flushId: number | null = null;
    let flushTimerId: ReturnType<typeof setTimeout> | null = null;

    const handleAgentAck = (tid: number, nonce: string) => {
      const uuid = tidToUuid.get(tid);
      if (!uuid) return;
      const t = liveStates.get(uuid);
      if (!t) return;
      const idx = t.messages.findIndex(
        (m) => m.type === "user" && m.nonce === nonce,
      );
      if (idx < 0) return;
      const updated = {
        ...t,
        messages: t.messages.map((m, i) =>
          i === idx ? { ...m, ackState: 2 as const } : m,
        ),
      };
      liveStates.set(uuid, updated);
      setTasks((map) => {
        const next = new Map(map);
        next.set(uuid, updated);
        return next;
      });
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
        if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "unconfirmed")
          handleUnconfirmedUserMessage(item.tid, item.msg, item.correlationId);
        else if (item.kind === "agentAck") handleAgentAck(item.tid, item.nonce);
        else handleTaskMessage(item.tid, item.msg, item.seq, item.ts);
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
        setConnected(false);
        liveStates.clear();
        tidToUuid.clear();
        requestedHistoryRef.current.clear();
        const cur = draftRef.current;
        if (cur.phase === "timer_pending") clearTimeout(cur.timerId);
        setDraft({ phase: "none" });
        deletedDraftTid.current = null;
        setTasks(new Map());
        setAgentUsage({});
      } else {
        initialNoticeLoadRef.current = true;
      }
    };

    conn.onTaskMessage = (tid, msg, seq, ts) => {
      buffer.push({ kind: "task", tid, msg, seq, ts });
      scheduleFlush();
    };
    conn.onUnconfirmedUserMessage = (tid, msg, correlationId) => {
      buffer.push({ kind: "unconfirmed", tid, msg, correlationId });
      scheduleFlush();
    };
    conn.onAgentAck = (tid, nonce) => {
      buffer.push({ kind: "agentAck", tid, nonce });
      scheduleFlush();
    };
    conn.onControlMessage = (msg) => {
      buffer.push({ kind: "control", msg });
      scheduleFlush();
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
  }, [handleTaskMessage, handleControlMessage, handleUnconfirmedUserMessage]);

  // Request history when the active task changes and hasn't been loaded yet
  useEffect(() => {
    if (!connected || activeTaskId === null) return;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    const t = findByTid(tid);
    if (!t) return;
    if (requestedHistoryRef.current.has(t.uuid)) return;
    if (t.historyLoaded) return;
    if (connRef.current?.requestHistory(tid)) {
      requestedHistoryRef.current.add(t.uuid);
    }
  }, [connected, activeTaskId, tasks]);

  // Replay outbox entries after tasks_list arrives and WS is connected.
  // The backend deduplicates by nonce, so replaying is safe.
  const outboxReplayedRef = useRef(false);
  useEffect(() => {
    if (!connected || tasks.size === 0) return;
    if (outboxReplayedRef.current) return;
    outboxReplayedRef.current = true;
    const entries = outbox.all();
    if (entries.length === 0) return;
    let dropped = 0;
    for (const entry of entries) {
      if (!tidToUuid.has(entry.tid)) {
        outbox.remove(entry.nonce);
        dropped++;
        continue;
      }
      connRef.current?.sendMessage(
        entry.tid,
        entry.content as import("./protocol").AssistantContentBlock[],
        entry.nonce,
      );
    }
    if (dropped > 0) {
      console.warn(
        `[outbox] dropped ${dropped} unsent message(s): task no longer exists`,
      );
    }
  }, [connected, tasks]);

  // Request project-specific task types when the active project changes
  useEffect(() => {
    if (!activeWorkspace || !activeProject) return;
    const projPath = findProjectPath(
      workspacesRef.current,
      activeWorkspace,
      activeProject,
    );
    if (projPath) {
      connRef.current?.requestTaskTypes(projPath);
    }
  }, [activeWorkspace, activeProject]);

  // True when the active task is a pending draft not yet tracked by the draft state machine.
  // Used as a dep below so re-adopt runs when the task first appears after page reload.
  const activeTaskNeedsAdoption = useMemo(() => {
    if (activeTaskId === null) return false;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return false;
    const task = findByTid(tid);
    return task
      ? task.status === "pending" &&
          task.messages.length === 0 &&
          !task.isProcessing
      : false;
  }, [activeTaskId, tasks]);

  // Manage draft tracking state in response to navigation.
  //
  // When activeTaskId is null (project root / "New Task"):
  //   - Clear stale draft tracking and create a fresh virtual draft.
  //   Both must happen atomically in one effect to avoid ordering issues.
  //
  // When activeTaskId points to a pending draft task:
  //   - Re-adopt it as the active draft so isDraft/taskTypes/onContentEnd
  //   are wired correctly (e.g. after navigating away and back, or after
  //   page reload where the task loads from tasks_list asynchronously).
  useEffect(() => {
    if (activeTaskId !== null) {
      // Re-adopt an existing draft task when navigating to it.
      const tid = parseTaskId(activeTaskId);
      if (tid !== null) {
        const task = findByTid(tid);
        if (
          task &&
          task.status === "pending" &&
          task.messages.length === 0 &&
          !task.isProcessing
        ) {
          // Every task has a uuid from creation — just set promoted state.
          setDraft({ phase: "promoted", uuid: task.uuid });
        } else {
          clearDraftForNav({ teardownVirtual: false });
        }
      }
      return;
    }
    if (activeWorkspace === null) {
      clearDraftForNav({ teardownVirtual: true });
      return;
    }
    // Clear existing draft tracking when a real promoted draft task exists
    if (draftRef.current.phase === "promoted") {
      setDraft({ phase: "none" });
    }
    // Create fresh virtual draft if none exists
    if (draftRef.current.phase === "none") {
      createVirtualDraft();
    }
  }, [
    activeTaskId,
    activeWorkspace,
    createVirtualDraft,
    setDraft,
    clearDraftForNav,
    activeTaskNeedsAdoption,
  ]);

  const send = useCallback(
    (
      uuid: string,
      text: string,
      images?: ImageAttachment[],
      entryPointName?: string,
      agentType?: string,
    ) => {
      const content = buildContentBlocks(text, images);
      const taskState = liveStates.get(uuid);
      const draft = draftRef.current;
      const draftTid = taskState?.tid ?? null;

      // Real backend task: covers regular send and the promoted-draft case.
      if (draftTid !== null) {
        const isPromotedDraft =
          draft.phase === "promoted" && draft.uuid === uuid;
        if (isPromotedDraft) {
          if (entryPointName)
            connRef.current?.setEntryPoint(draftTid, entryPointName);
          if (agentType) connRef.current?.setAgentName(draftTid, agentType);
        }
        const nonce = crypto.randomUUID();
        connRef.current?.sendMessage(draftTid, content, nonce);
        outbox.add({ tid: draftTid, nonce, content, createdAt: Date.now() });
        // Insert optimistic placeholder (ackState=4)
        if (taskState) {
          const msgId = `opt-${++taskState.msgIdCounter}`;
          const withPlaceholder = {
            ...taskState,
            msgIdCounter: taskState.msgIdCounter,
            messages: [
              ...taskState.messages,
              {
                id: msgId,
                type: "user" as const,
                content:
                  content as import("./protocol").AssistantContentBlock[],
                ackState: 4 as const,
                pending: true,
                nonce,
              },
            ],
          };
          liveStates.set(uuid, withPlaceholder);
        }

        if (
          isPromotedDraft &&
          taskState &&
          taskState.workspace &&
          taskState.projectPath
        ) {
          const projName = findProjectName(
            workspacesRef.current,
            taskState.workspace,
            taskState.projectPath,
          );
          if (projName) {
            const encodedProject = projName.replace(/\//g, ":");
            routeRef.current(
              `/${taskState.workspace}/${encodedProject}/task/${draftTid}`,
              false,
            );
          }
          setDraft({ phase: "none" });
        }

        setTasks((prev) => {
          const t = prev.get(uuid);
          if (!t) return prev;
          const next = new Map(prev);
          const cur = liveStates.get(uuid) ?? t;
          next.set(uuid, {
            ...cur,
            isProcessing: true,
            suggestions: undefined,
          });
          return next;
        });
        return;
      }

      // No real tid: virtual draft. Route through the create_task handshake.
      if (draft.phase === "create_pending") {
        // Timer fired but task_created hasn't arrived; stash the message.
        setDraft({
          phase: "send_pending",
          uuid: draft.uuid,
          firstMessage: { text, entryPointName, images },
        });
        return;
      }
      if (draft.phase === "timer_pending") {
        clearTimeout(draft.timerId);
      }
      teardownVirtualDraft();
      setDraft({ phase: "none" });

      const correlationId = crypto.randomUUID();
      const ws = activeWorkspaceRef.current;
      const proj = activeProjectRef.current;
      const projPath =
        ws && proj ? findProjectPath(workspacesRef.current, ws, proj) : null;
      connRef.current?.createTask(
        ws ?? undefined,
        projPath ?? (ws ? "" : undefined),
        entryPointName,
        content,
        agentType,
        correlationId,
      );
    },
    [setTasks, teardownVirtualDraft, setDraft],
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

  const undoPreview = useCallback((tid: number, afterUuid: string) => {
    // Optimistically set afterUuid so confirmation bar can reference it
    const t = findByTid(tid);
    if (t) {
      const updated = {
        ...t,
        undoPending: { afterUuid, messagesRemoved: -1 },
      };
      liveStates.set(t.uuid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(t.uuid, updated);
        return next;
      });
    }
    connRef.current?.undoTask(tid, afterUuid, true);
  }, []);

  const undoConfirm = useCallback(
    (tid: number, revertConversation: boolean, revertFiles: boolean) => {
      const t = findByTid(tid);
      if (!t?.undoPending) return;
      connRef.current?.undoTask(
        tid,
        t.undoPending.afterUuid,
        false,
        revertConversation,
        revertFiles,
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
    const updated = { ...t, alive: true, resumable: false, status: "active" };
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
    connRef.current?.promoteTask(tid);
    // Optimistic update
    const updated = { ...t, status: "completed", resumable: true };
    liveStates.set(t.uuid, updated);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(t.uuid, updated);
      return next;
    });
  }, []);

  const setArchived = useCallback((tid: number, archived: boolean) => {
    connRef.current?.setArchived(tid, archived);
  }, []);

  const setEntryPoint = useCallback((tid: number, entryPoint: string) => {
    connRef.current?.setEntryPoint(tid, entryPoint);
  }, []);

  const setAgentName = useCallback((tid: number, agentName: string) => {
    connRef.current?.setAgentName(tid, agentName);
  }, []);

  const saveDraft = useCallback((tid: number, draft: string) => {
    connRef.current?.saveDraft(tid, draft);
    const t = findByTid(tid);
    if (t) {
      let updated: typeof t | null = null;
      // When draft is cleared (message sent), clear serverDraft so InputBox doesn't
      // restore a stale value on remount (e.g. after the welcome→active view transition).
      if (!draft && t.serverDraft !== undefined) {
        updated = { ...t, serverDraft: undefined };
      }
      // Derive sidebar title from draft text for pending tasks with no messages
      if (t.status === "pending" && t.messages.length === 0) {
        const firstLine =
          draft.trim().split("\n")[0]?.slice(0, 100) || undefined;
        if (firstLine !== (updated ?? t).title) {
          updated = { ...(updated ?? t), title: firstLine };
        }
      }
      if (updated) {
        liveStates.set(t.uuid, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(t.uuid, updated);
          return next;
        });
      }
    }
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
    if (activeWorkspace && activeProject) {
      const projPath = findProjectPath(
        workspacesRef.current,
        activeWorkspace,
        activeProject,
      );
      if (projPath) {
        const projectEps = projectEntryPoints.get(projPath);
        if (projectEps) return projectEps;
      }
    }
    return entryPoints;
  }, [activeWorkspace, activeProject, entryPoints, projectEntryPoints]);

  const resolvedTypeInfo = useMemo(() => {
    if (activeWorkspace && activeProject) {
      const projPath = findProjectPath(
        workspacesRef.current,
        activeWorkspace,
        activeProject,
      );
      if (projPath) {
        const projectTi = projectTypeInfo.get(projPath);
        if (projectTi) return projectTi;
      }
    }
    return typeInfo;
  }, [activeWorkspace, activeProject, typeInfo, projectTypeInfo]);

  // Build sidebar task list filtered by active workspace/project and sorted by createdAt/tid
  const prevSidebarTasksRef = useRef<
    import("./components/Sidebar").SidebarTask[]
  >([]);
  const sidebarTasks = useMemo(() => {
    // Exclude virtual drafts (tid === null)
    let filtered = Array.from(tasks.values()).filter(
      (t): t is TaskState & { tid: number } => t.tid !== null,
    );
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

  return {
    tasks,
    activeTaskId,
    activeTaskIdRef,
    setActiveTaskId,
    connected,
    send,
    interrupt,
    stop,
    closeStdin,
    resume,
    promote,
    fork,
    undoPreview,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    setArchived,
    saveDraft,
    setEntryPoint,
    setAgentName,
    sendAskUserResponse,
    sendPermissionPromptResponse,
    editMessage,
    editRawEvent,
    createDraftTask,
    deleteDraftTask,
    draftRenderKey,
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
    devMode,
    exportLoadError: null,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    getByTid: findByTid,
    refreshWorkspaces: () => {
      setRefreshingWorkspaces(true);
      connRef.current?.refreshWorkspaces();
    },
    refreshingWorkspaces,
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
