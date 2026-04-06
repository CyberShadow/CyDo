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
import type { AgnosticEvent, ControlMessage, ContentBlock } from "./protocol";
import type { CydoMeta, TaskState } from "./types";
import { makeTaskState } from "./types";
import { reduceMessage } from "./sessionReducer";
import { drafts as inputDrafts } from "./components/InputBox";

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

type DraftPhase =
  | { phase: "none" }
  | { phase: "virtual"; renderKey: string }
  | {
      phase: "timer_pending";
      renderKey: string;
      timerId: ReturnType<typeof setTimeout>;
      entryPoint?: string;
      agentType?: string;
    }
  | { phase: "create_pending"; renderKey: string; correlationId: string }
  | { phase: "create_cancelled"; renderKey: string; correlationId: string }
  | {
      phase: "send_pending";
      renderKey: string;
      correlationId: string;
      firstMessage: {
        text: string;
        entryPointName?: string;
        images?: ImageAttachment[];
      };
    }
  | { phase: "promoted"; renderKey: string; tid: number };

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
}

export interface WorkspaceInfo {
  name: string;
  projects: ProjectInfo[];
  default_agent_type?: string;
}

export interface AgentTypeInfo {
  name: string;
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
  tasks: Map<number, TaskState>;
  activeTaskId: string | null;
  activeTaskIdRef: { current: string | null };
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  send: (
    text: string,
    images?: ImageAttachment[],
    entryPointName?: string,
    agentType?: string,
  ) => void;
  interrupt: () => void;
  stop: () => void;
  closeStdin: () => void;
  resume: () => void;
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
  setAgentType: (tid: number, agentType: string) => void;
  sendAskUserResponse: (tid: number, content: string) => void;
  editMessage: (tid: number, uuid: string, content: string) => void;
  createDraftTask: (entryPointName?: string, agentType?: string) => void;
  deleteDraftTask: () => void;
  draftRenderKey: string | null;
  sidebarTasks: Array<{
    tid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    title?: string;
    parentTid?: number;
    relationType?: string;
    status?: string;
    archived?: boolean;
    hasPendingQuestion?: boolean;
    lastActive?: number;
    hasMessages?: boolean;
  }>;
  workspaces: WorkspaceInfo[];
  entryPoints: EntryPointInfo[];
  typeInfo: TypeInfo[];
  agentTypes: AgentTypeInfo[];
  defaultAgentType: string;
  activeWorkspace: string | null;
  activeProject: string | null;
  authEnabled: boolean;
  devMode: boolean;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  refreshWorkspaces: () => void;
}

/// Extract text content from a user message event (for unconfirmed display).
function extractTextContent(msg: AgnosticEvent): string {
  if (msg.type !== "item/started" || msg.item_type !== "user_message")
    return "";
  return msg.text ?? "";
}

// Mutable mirror of task states, updated synchronously outside Preact's
// render cycle.  Used so that reducers and notification checks run immediately
// when WebSocket messages arrive, even when Preact defers state updates in
// background tabs.
const liveStates = new Map<number, TaskState>();

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

export function useTaskManager(): TaskManager {
  const [connected, setConnected] = useState(false);
  const [tasks, setTasks] = useState<Map<number, TaskState>>(new Map());
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [entryPoints, setEntryPoints] = useState<EntryPointInfo[]>([]);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);
  const [agentTypes, setAgentTypes] = useState<AgentTypeInfo[]>([]);
  const [defaultAgentType, setDefaultAgentType] = useState("claude");
  const [authEnabled, setAuthEnabled] = useState(true);
  const [devMode, setDevMode] = useState(false);
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
      const t = liveStates.get(tid);
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
  // Correlation ID of the most recent createTask call; set to null once consumed.
  // The client only auto-focuses a new task when the task_created response echoes this ID.
  const pendingFocusId = useRef<string | null>(null);
  // Track which tasks have had history requested (avoid duplicate requests)
  const requestedHistoryRef = useRef(new Set<number>());

  // Draft task management state
  const draftRef = useRef<DraftPhase>({ phase: "none" });
  const [draftRenderKey, setDraftRenderKey] = useState<string | null>(null);
  // Set when a promoted draft is deleted; cleared on task_deleted.
  // Guards handleTaskMessage against stale history events.
  const deletedDraftTid = useRef<number | null>(null);

  const setDraft = useCallback((next: DraftPhase) => {
    draftRef.current = next;
    const rk = next.phase !== "none" ? next.renderKey : null;
    setDraftRenderKey((prev) => (prev === rk ? prev : rk));
  }, []);

  const createVirtualDraft = useCallback(() => {
    const renderKey = crypto.randomUUID();
    const ws = activeWorkspaceRef.current ?? "";
    const proj = activeProjectRef.current;
    const projPath = proj
      ? (findProjectPath(workspacesRef.current, ws, proj) ?? "")
      : "";
    const t: TaskState = {
      ...makeTaskState(0, false, false, undefined, true, ws, projPath),
      renderKey,
    };
    liveStates.set(0, t);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(0, t);
      return next;
    });
    setDraft({ phase: "virtual", renderKey });
    return renderKey;
  }, [setDraft]);

  const createDraftTask = useCallback(
    (entryPointName?: string, agentType?: string) => {
      const cur = draftRef.current;
      if (cur.phase !== "virtual") return;
      const ws = activeWorkspaceRef.current;
      const proj = activeProjectRef.current;
      if (!ws || !proj) return;
      const { renderKey } = cur;
      // Debounce: delay sending create_task so that rapid fill()+click()
      // sequences (common in Playwright tests) don't create zombie tasks.
      const timerId = setTimeout(() => {
        const projPath = findProjectPath(workspacesRef.current, ws, proj);
        const correlationId = crypto.randomUUID();
        setDraft({ phase: "create_pending", renderKey, correlationId });
        connRef.current?.createTask(
          ws,
          projPath || "",
          entryPointName,
          undefined,
          agentType,
          correlationId,
        );
      }, 16);
      setDraft({
        phase: "timer_pending",
        renderKey,
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
        setDraft({ phase: "virtual", renderKey: cur.renderKey });
        return;

      case "promoted": {
        const tid = cur.tid;
        const existing = liveStates.get(tid);
        // Real backend task — delete it
        deletedDraftTid.current = tid;
        connRef.current?.deleteTask(tid);
        inputDrafts.delete(tid);
        liveStates.delete(tid);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.delete(tid);
          return next;
        });
        // Reset virtual draft to tid=0 (reuse same renderKey — no remount)
        const ws = activeWorkspaceRef.current ?? "";
        const proj = activeProjectRef.current;
        const projPath = proj
          ? (findProjectPath(workspacesRef.current, ws, proj) ?? "")
          : "";
        const t: TaskState = {
          ...makeTaskState(0, false, false, undefined, true, ws, projPath),
          renderKey: cur.renderKey,
          entryPoint: existing?.entryPoint,
          taskType: existing?.taskType,
          agentType: existing?.agentType,
        };
        // Clear stale in-memory draft from the virtual slot so the InputBox
        // starts fresh on the next cycle (avoids wasEmpty=false blocking onContentStart).
        inputDrafts.delete(0);
        liveStates.set(0, t);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(0, t);
          return next;
        });
        setDraft({ phase: "virtual", renderKey: cur.renderKey });
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
          renderKey: cur.renderKey,
          correlationId: cur.correlationId,
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
    (tid: number, msg: AgnosticEvent, meta: CydoMeta | undefined) => {
      const t = liveStates.get(tid);
      const prev = t ?? makeTaskState(tid, true);
      const content = ((msg as Record<string, unknown>).content as
        | ContentBlock[]
        | undefined) ?? [
        { type: "text" as const, text: extractTextContent(msg) },
      ];
      const id = `pending-${++prev.msgIdCounter}`;
      const updated = {
        ...prev,
        messages: [
          ...prev.messages,
          {
            id,
            type: "user" as const,
            content,
            pending: true,
            cydoMeta: meta,
          },
        ],
      };
      liveStates.set(tid, updated);
      setTasks((map) => {
        const next = new Map(map);
        next.set(tid, updated);
        return next;
      });
    },
    [],
  );

  const handleTaskMessage = useCallback((tid: number, msg: AgnosticEvent) => {
    // Skip stale events for recently deleted draft tasks (e.g. from
    // requestHistory responses arriving after deleteDraftTask).
    if (deletedDraftTid.current === tid) return;
    const t = liveStates.get(tid);
    const prev = t ?? makeTaskState(tid, true);
    const updated = reduceMessage(prev, msg);
    liveStates.set(tid, updated);

    // When an agent sub-task exits and it's currently focused, switch to the
    // first alive ancestor. For continuations (Handoff), the direct parent is
    // already completed; the actual result receiver is further up the chain.
    // User-created children (forks) stay focused — user navigates manually.
    if (
      msg.type === "process/exit" &&
      !msg.is_continuation &&
      prev.parentTid &&
      prev.relationType !== "fork" &&
      activeTaskIdRef.current === String(tid)
    ) {
      let targetTid = prev.parentTid;
      while (targetTid) {
        const t = liveStates.get(targetTid);
        if (!t || !t.parentTid || t.alive) break;
        targetTid = t.parentTid;
      }
      const target = liveStates.get(targetTid);
      if (target) {
        setActiveTaskId(String(targetTid));
      }
    }

    setTasks((map) => {
      const next = new Map(map);
      next.set(tid, updated);
      return next;
    });
  }, []);

  const handleControlMessage = useCallback((msg: ControlMessage) => {
    switch (msg.type) {
      case "workspaces_list": {
        setWorkspaces(msg.workspaces);
        setConnected(true);
        break;
      }
      case "task_types_list": {
        setEntryPoints(msg.entry_points);
        setTypeInfo(msg.type_info);
        break;
      }
      case "agent_types_list": {
        setAgentTypes(msg.agent_types);
        if (msg.default_agent_type) setDefaultAgentType(msg.default_agent_type);
        break;
      }
      case "task_created": {
        const tid = msg.tid;
        const workspace = msg.workspace || "";
        const projectPath = msg.project_path || "";
        const parentTid = msg.parent_tid || undefined;
        const relationType = msg.relation_type || undefined;
        const t = makeTaskState(
          tid,
          false,
          false,
          undefined,
          false, // always request history; backend responds immediately for new tasks
          workspace,
          projectPath,
          parentTid,
          relationType,
          "pending",
        );
        liveStates.set(tid, t);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(tid, t);
          return next;
        });

        // Check if this is a draft task creation (no navigation)
        const draft = draftRef.current;
        const isDraftCreation =
          (draft.phase === "create_pending" ||
            draft.phase === "create_cancelled" ||
            draft.phase === "send_pending") &&
          draft.correlationId === msg.correlation_id;
        if (isDraftCreation) {
          if (draft.phase === "create_cancelled") {
            // User navigated away before task_created arrived — delete zombie.
            // Also clean up tid=0 if still present (it was already deleted in
            // the welcome-page path but may still exist for other nav paths).
            connRef.current?.deleteTask(tid);
            liveStates.delete(tid);
            liveStates.delete(0);
            inputDrafts.delete(0);
            setTasks((prev) => {
              const hasRealTid = prev.has(tid);
              const hasVirtual = prev.has(0);
              if (!hasRealTid && !hasVirtual) return prev;
              const next = new Map(prev);
              if (hasRealTid) next.delete(tid);
              if (hasVirtual) next.delete(0);
              return next;
            });
            setDraft({ phase: "none" });
            break;
          }
          const { renderKey } = draft;
          const firstMsg =
            draft.phase === "send_pending" ? draft.firstMessage : null;
          // Copy in-memory draft from slot 0 to the real tid (only if not piggybacking)
          if (firstMsg === null) {
            const currentText = inputDrafts.get(0);
            if (currentText !== undefined) {
              inputDrafts.set(tid, currentText);
            }
          }
          inputDrafts.delete(0);
          // Transfer renderKey from virtual task (tid=0) to real task
          liveStates.delete(0);
          const realTask: TaskState = {
            ...t,
            historyLoaded: true,
            renderKey,
          };
          liveStates.set(tid, realTask);
          setTasks((prev) => {
            const next = new Map(prev);
            next.delete(0);
            next.set(tid, realTask);
            return next;
          });
          // Subscribe to live events for the new task. The backend uses
          // request_history as the subscription mechanism — without it,
          // sendToSubscribed won't deliver agent messages to this client.
          connRef.current?.requestHistory(tid);
          requestedHistoryRef.current.add(tid);
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
              const taskState = prev.get(tid);
              if (!taskState) return prev;
              const next = new Map(prev);
              next.set(tid, {
                ...taskState,
                isProcessing: true,
                suggestions: undefined,
              });
              return next;
            });
          } else {
            // User is still typing — navigate URL to reflect the real tid
            // (replaceState so back button returns to "new task" view).
            setDraft({ phase: "promoted", renderKey, tid });
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
          break; // Skip normal navigation logic
        }

        // Navigate to the new task only if:
        // - this client created it (top-level, correlation ID matches), or
        // - its parent is currently focused (sub-task visible in context)
        // Never auto-focus undo-backup tasks (they're invisible backups).
        const correlationMatches =
          pendingFocusId.current !== null &&
          msg.correlation_id === pendingFocusId.current;
        const shouldFocus =
          relationType === "undo-backup"
            ? false
            : parentTid
              ? activeTaskIdRef.current === String(parentTid)
              : correlationMatches;
        // Only consume the pending focus ID when the correlation actually
        // matched.  Broadcast task_created messages (sub-tasks, forks,
        // continuations) must not clear it — otherwise the unicast response
        // to our own createTask would fail to navigate.
        if (correlationMatches) pendingFocusId.current = null;
        if (shouldFocus) {
          activeTaskIdRef.current = String(tid);
          if (workspace && projectPath) {
            const projName = findProjectName(
              workspacesRef.current,
              workspace,
              projectPath,
            );
            if (projName) {
              const encodedProject = projName.replace(/\//g, ":");
              routeRef.current(`/${workspace}/${encodedProject}/task/${tid}`);
            } else {
              routeRef.current("/");
            }
          } else {
            routeRef.current("/");
          }
        }

        break;
      }
      case "tasks_list": {
        const updates = new Map<number, TaskState>();
        for (const entry of msg.tasks) {
          // Skip recently deleted draft tasks
          if (deletedDraftTid.current === entry.tid) continue;
          const workspace = entry.workspace || "";
          const projectPath = entry.project_path || "";
          const existing = liveStates.get(entry.tid);
          if (!existing) {
            const t = {
              ...makeTaskState(
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
                entry.needsAttention || false,
                entry.hasPendingQuestion || false,
                entry.task_type || undefined,
                entry.archived || false,
                entry.created_at || undefined,
                entry.last_active || undefined,
                entry.agent_type || undefined,
                entry.entry_point || undefined,
                entry.archiving || false,
              ),
              serverDraft: entry.draft || undefined,
              error: entry.error || undefined,
            };
            liveStates.set(entry.tid, t);
            updates.set(entry.tid, t);
          } else {
            // If a task becomes resumable but has no messages loaded,
            // reset historyLoaded so JSONL history gets requested
            // (e.g. forked tasks with pre-existing JSONL).
            const needsHistory =
              entry.resumable &&
              existing.messages.length === 0 &&
              existing.historyLoaded;
            const updated = {
              ...existing,
              alive: entry.alive,
              resumable: entry.resumable,
              isProcessing: entry.isProcessing || false,
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
              agentType: entry.agent_type || existing.agentType,
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
            liveStates.set(entry.tid, updated);
            updates.set(entry.tid, updated);
          }
        }
        setTasks((prev) => {
          const next = new Map(prev);
          for (const [tid, state] of updates) {
            next.set(tid, state);
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
        const existing = liveStates.get(entry.tid);
        let taskUpdated: TaskState;
        if (!existing) {
          taskUpdated = {
            ...makeTaskState(
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
              entry.needsAttention || false,
              entry.hasPendingQuestion || false,
              entry.task_type || undefined,
              entry.archived || false,
              entry.created_at || undefined,
              entry.last_active || undefined,
              entry.agent_type || undefined,
              entry.entry_point || undefined,
              entry.archiving || false,
            ),
            serverDraft: entry.draft || undefined,
            error: entry.error || undefined,
          };
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
            agentType: entry.agent_type || existing.agentType,
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
        }
        liveStates.set(entry.tid, taskUpdated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(entry.tid, taskUpdated);
          return next;
        });
        break;
      }
      case "task_reload": {
        const { tid } = msg;
        requestedHistoryRef.current.delete(tid);
        const t = liveStates.get(tid);
        if (!t) break;
        // Collect user message texts to detect unsaved prompts after replay.
        // Skip for edit-triggered reloads: the message was intentionally
        // replaced, not removed, so old text should not become inputDraft.
        const isEdit = msg.reason === "edit";
        const userTexts = isEdit
          ? []
          : t.messages
              .filter((m) => m.type === "user")
              .map((m) =>
                m.content
                  .filter((b) => b.type === "text")
                  .map((b) => ("text" in b ? b.text : ""))
                  .join(""),
              )
              .filter((t) => t.length > 0);
        // When a session has already started (sessionInfo set), the first user
        // message was rendered into the prompt template before being sent to
        // the agent, so it is stored in JSONL as the full template text — not
        // the raw user input.  Exact-match confirmation during replay therefore
        // never fires for it, which would incorrectly keep it in inputDraft.
        // Since the first message always starts the session (it was definitely
        // delivered), exclude it from recovery tracking entirely.
        const textsToRecover = t.sessionInfo ? userTexts.slice(1) : userTexts;
        const reset = {
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
          resumable: t.resumable,
          preReloadDrafts:
            textsToRecover.length > 0 ? textsToRecover : undefined,
          undoResult: t.undoResult,
        };
        liveStates.set(tid, reset);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, reset);
          return next;
        });
        // Re-request history if this is the active task — the useEffect
        // won't re-fire because activeTaskId hasn't changed.
        if (String(tid) === activeTaskIdRef.current) {
          if (connRef.current?.requestHistory(tid)) {
            requestedHistoryRef.current.add(tid);
          }
        }
        break;
      }
      case "task_history_end": {
        const { tid } = msg;
        let t = liveStates.get(tid);
        if (!t) break;

        // Compute inputDraft from confirmed drafts
        let inputDraft: string | undefined;
        if (t.preReloadDrafts && t.preReloadDrafts.length > 0) {
          // Multiset subtraction: remove one confirmed occurrence per match
          const confirmedCounts = new Map<string, number>();
          for (const text of t.confirmedDuringReplay ?? []) {
            confirmedCounts.set(text, (confirmedCounts.get(text) ?? 0) + 1);
          }
          const remaining: string[] = [];
          for (const text of t.preReloadDrafts) {
            const count = confirmedCounts.get(text) ?? 0;
            if (count > 0) {
              confirmedCounts.set(text, count - 1);
            } else {
              remaining.push(text);
            }
          }
          inputDraft =
            remaining.length > 0 ? remaining.join("\n\n") : undefined;
        }

        // Finalize: mark loaded, clear transient state
        t = {
          ...t,
          historyLoaded: true,
          preReloadDrafts: undefined,
          confirmedDuringReplay: undefined,
          inputDraft,
        };
        liveStates.set(tid, t);

        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, t);
          return next;
        });
        break;
      }
      case "title_update": {
        const { tid, title } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        const updated = { ...t, title };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "suggestions_update": {
        const { tid, suggestions } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        const updated = { ...t, suggestions };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "draft_updated": {
        const { tid, new_draft } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        const updated = { ...t, serverDraft: new_draft };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "task_deleted": {
        const { tid } = msg;
        if (deletedDraftTid.current === tid) deletedDraftTid.current = null;
        liveStates.delete(tid);
        requestedHistoryRef.current.delete(tid);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.delete(tid);
          return next;
        });
        break;
      }
      case "forkable_uuids": {
        const { tid, uuids } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        const merged = new Set(t.forkableUuids);
        for (const u of uuids) merged.add(u);
        const updated = { ...t, forkableUuids: merged };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "undo_preview": {
        const { tid, messages_removed } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        // Find the afterUuid from pending state — it was set optimistically
        // when undoPreview was called.
        const updated = {
          ...t,
          undoPending: {
            afterUuid: t.undoPending?.afterUuid ?? "",
            messagesRemoved: messages_removed,
          },
        };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "undo_result": {
        const { tid, output } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        if (output) {
          const updated = { ...t, undoResult: output };
          liveStates.set(tid, updated);
          setTasks((prev) => {
            const next = new Map(prev);
            next.set(tid, updated);
            return next;
          });
          setTimeout(() => {
            const cur = liveStates.get(tid);
            if (!cur) return;
            const cleared = { ...cur, undoResult: null };
            liveStates.set(tid, cleared);
            setTasks((prev) => {
              const next = new Map(prev);
              next.set(tid, cleared);
              return next;
            });
          }, 8000);
        }
        break;
      }
      case "ask_user_question": {
        const { tid, tool_use_id, questions } = msg;
        const t = liveStates.get(tid);
        if (!t) break;
        // Empty tool_use_id signals that the question was answered (clear the form)
        const pendingAskUser = tool_use_id
          ? { toolUseId: tool_use_id, questions }
          : null;
        const updated = { ...t, pendingAskUser };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
        break;
      }
      case "server_status": {
        setAuthEnabled(msg.auth_enabled);
        setDevMode(msg.dev_mode ?? false);
        break;
      }
      case "error": {
        const errMsg = msg.message;
        const errTid = msg.tid;
        console.error("Server error:", errMsg, "tid:", errTid);
        // Clear undoPending if this error is for a task with an active undo dialog
        if (errTid !== undefined) {
          const t = liveStates.get(errTid);
          if (t?.undoPending) {
            const updated = { ...t, undoPending: null };
            liveStates.set(errTid, updated);
            setTasks((prev) => {
              const next = new Map(prev);
              next.set(errTid, updated);
              return next;
            });
          }
        }
        alert(errMsg);
        break;
      }
    }
  }, []);

  useEffect(() => {
    const conn = new Connection();
    connRef.current = conn;

    // Buffer incoming messages and flush on rAF so that hundreds of replay
    // messages are processed in a single render pass instead of one-per-message.
    type BufferedMsg =
      | { kind: "task"; tid: number; msg: AgnosticEvent }
      | {
          kind: "unconfirmed";
          tid: number;
          msg: AgnosticEvent;
          meta: CydoMeta | undefined;
        }
      | { kind: "control"; msg: ControlMessage };
    let buffer: BufferedMsg[] = [];
    let flushId: number | null = null;
    let flushTimerId: ReturnType<typeof setTimeout> | null = null;

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
          handleUnconfirmedUserMessage(item.tid, item.msg, item.meta);
        else handleTaskMessage(item.tid, item.msg);
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
        requestedHistoryRef.current.clear();
        const cur = draftRef.current;
        if (cur.phase === "timer_pending") clearTimeout(cur.timerId);
        setDraft({ phase: "none" });
        deletedDraftTid.current = null;
        setTasks(new Map());
      }
    };

    conn.onTaskMessage = (tid, msg) => {
      buffer.push({ kind: "task", tid, msg });
      scheduleFlush();
    };
    conn.onUnconfirmedUserMessage = (tid, msg, meta) => {
      buffer.push({ kind: "unconfirmed", tid, msg, meta });
      scheduleFlush();
    };
    conn.onControlMessage = (msg) => {
      buffer.push({ kind: "control", msg });
      scheduleFlush();
    };
    conn.connect();
    return () => {
      cancelPendingFlush();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      conn.disconnect();
    };
  }, [handleTaskMessage, handleControlMessage]);

  // Request history when the active task changes and hasn't been loaded yet
  useEffect(() => {
    if (!connected || activeTaskId === null) return;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return;
    if (requestedHistoryRef.current.has(tid)) return;
    const t = liveStates.get(tid);
    if (t?.historyLoaded) return;
    if (connRef.current?.requestHistory(tid)) {
      requestedHistoryRef.current.add(tid);
    }
  }, [connected, activeTaskId, tasks]);

  // True when the active task is a draft loaded from the backend (no renderKey
  // yet).  Used as a dep below so re-adopt runs when the task first appears
  // after page reload (activeTaskId is already set from the URL but liveStates
  // is empty until tasks_list arrives).
  const activeTaskNeedsAdoption = useMemo(() => {
    if (activeTaskId === null) return false;
    const tid = parseTaskId(activeTaskId);
    if (tid === null) return false;
    const task = tasks.get(tid);
    return (
      !!task &&
      task.status === "pending" &&
      task.messages.length === 0 &&
      !task.isProcessing &&
      !task.renderKey
    );
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
        const task = liveStates.get(tid);
        if (
          task &&
          task.status === "pending" &&
          task.messages.length === 0 &&
          !task.isProcessing
        ) {
          // Tasks loaded from backend (page reload, second client) don't have
          // renderKey.  Assign one so app.tsx wiring (isDraft, taskTypes,
          // onContentEnd) works correctly.
          const renderKey = task.renderKey || crypto.randomUUID();
          if (!task.renderKey) {
            const updated = { ...task, renderKey };
            liveStates.set(tid, updated);
            setTasks((prev) => {
              const next = new Map(prev);
              next.set(tid, updated);
              return next;
            });
          }
          setDraft({ phase: "promoted", renderKey, tid });
        } else {
          // Navigated to a non-draft task — clear stale draft tracking so
          // send() doesn't accidentally target the previous draft.
          // Fix Race 1: if timer_pending, cancel the timer before clearing.
          // Fix Race 2: if create_pending, transition to create_cancelled so
          // task_created can clean up the zombie.
          const cur = draftRef.current;
          if (cur.phase !== "none") {
            if (cur.phase === "timer_pending") {
              clearTimeout(cur.timerId);
              setDraft({ phase: "none" });
            } else if (cur.phase === "create_pending") {
              setDraft({
                phase: "create_cancelled",
                renderKey: cur.renderKey,
                correlationId: cur.correlationId,
              });
            } else if (cur.phase === "promoted" || cur.phase === "virtual") {
              setDraft({ phase: "none" });
            }
          }
        }
      }
      return;
    }
    if (activeWorkspace === null) {
      // navigated to welcome page; tear down any virtual draft so tid=0
      // doesn't leak into the welcome page task list as "Task 0"
      const cur = draftRef.current;
      if (cur.phase !== "none") {
        if (cur.phase === "timer_pending") {
          clearTimeout(cur.timerId);
        } else if (cur.phase === "create_pending") {
          // Keep correlationId so task_created can clean up the zombie.
          // Still delete tid=0 immediately so it doesn't appear as "Task 0".
          liveStates.delete(0);
          setTasks((prev) => {
            if (!prev.has(0)) return prev;
            const next = new Map(prev);
            next.delete(0);
            return next;
          });
          inputDrafts.delete(0);
          setDraft({
            phase: "create_cancelled",
            renderKey: cur.renderKey,
            correlationId: cur.correlationId,
          });
          return;
        }
        liveStates.delete(0);
        setTasks((prev) => {
          if (!prev.has(0)) return prev;
          const next = new Map(prev);
          next.delete(0);
          return next;
        });
        inputDrafts.delete(0);
        setDraft({ phase: "none" });
      }
      return;
    }
    // Clear existing draft tracking when a real promoted draft task exists
    if (draftRef.current.phase === "promoted") {
      setDraft({ phase: "none" });
    }
    // Create fresh virtual draft if none exists
    if (draftRef.current.phase === "none") {
      inputDrafts.delete(0); // clear stale text re-saved by InputBox cleanup
      createVirtualDraft();
    }
  }, [
    activeTaskId,
    activeWorkspace,
    createVirtualDraft,
    setDraft,
    activeTaskNeedsAdoption,
  ]);

  const send = useCallback(
    (
      text: string,
      images?: ImageAttachment[],
      entryPointName?: string,
      agentType?: string,
    ) => {
      const content = buildContentBlocks(text, images);
      const draft = draftRef.current;

      // Path (a): promoted draft — send to real tid
      if (draft.phase === "promoted") {
        const draftTid = draft.tid;
        if (entryPointName) {
          connRef.current?.setEntryPoint(draftTid, entryPointName);
        }
        if (agentType) {
          connRef.current?.setAgentType(draftTid, agentType);
        }
        connRef.current?.sendMessage(draftTid, content);
        // Navigate URL to the real task
        const draftState = liveStates.get(draftTid);
        if (draftState && draftState.workspace && draftState.projectPath) {
          const projName = findProjectName(
            workspacesRef.current,
            draftState.workspace,
            draftState.projectPath,
          );
          if (projName) {
            const encodedProject = projName.replace(/\//g, ":");
            routeRef.current(
              `/${draftState.workspace}/${encodedProject}/task/${draftTid}`,
              false,
            );
          }
        }
        // Clear draft state (task transitions from draft to active)
        setDraft({ phase: "none" });
        // Optimistically mark as processing
        setTasks((prev) => {
          const t = prev.get(draftTid);
          if (!t) return prev;
          const next = new Map(prev);
          next.set(draftTid, {
            ...t,
            isProcessing: true,
            suggestions: undefined,
          });
          return next;
        });
        return;
      }

      if (activeTaskId === null) {
        // Path (c): timer already fired (create_task in flight) but task_created
        // hasn't arrived yet. Store the message for task_created to deliver —
        // no zombie task is created.
        if (draft.phase === "create_pending") {
          setDraft({
            phase: "send_pending",
            renderKey: draft.renderKey,
            correlationId: draft.correlationId,
            firstMessage: { text, entryPointName, images },
          });
          return;
        }

        // Path (b): timer hasn't fired yet — cancel it and use atomic create+send.
        if (draft.phase === "timer_pending") {
          clearTimeout(draft.timerId);
        }
        // Remove virtual draft (tid=0).
        liveStates.delete(0);
        setTasks((prev) => {
          if (!prev.has(0)) return prev;
          const next = new Map(prev);
          next.delete(0);
          return next;
        });
        setDraft({ phase: "none" });

        // Atomic create+send
        const correlationId = crypto.randomUUID();
        pendingFocusId.current = correlationId;
        const ws = activeWorkspaceRef.current;
        const proj = activeProjectRef.current;
        if (ws && proj) {
          const projPath = findProjectPath(workspacesRef.current, ws, proj);
          connRef.current?.createTask(
            ws,
            projPath || "",
            entryPointName,
            content,
            agentType,
            correlationId,
          );
        } else {
          connRef.current?.createTask(
            undefined,
            undefined,
            entryPointName,
            content,
            agentType,
            correlationId,
          );
        }
        return;
      }
      const tid = parseTaskId(activeTaskId);
      if (tid === null) return;
      connRef.current?.sendMessage(tid, content);
      // Optimistically mark as processing so suggestions disappear immediately.
      const t = liveStates.get(tid);
      if (t) {
        const updated = { ...t, isProcessing: true, suggestions: undefined };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          if (!prev.has(tid)) return prev;
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
      }
    },
    [activeTaskId, setTasks, entryPoints],
  );

  const interrupt = useCallback(() => {
    if (activeTaskId !== null) {
      const tid = parseTaskId(activeTaskId);
      if (tid !== null) connRef.current?.sendInterrupt(tid);
    }
  }, [activeTaskId]);

  const stop = useCallback(() => {
    if (activeTaskId !== null) {
      const tid = parseTaskId(activeTaskId);
      if (tid !== null) connRef.current?.sendStop(tid);
    }
  }, [activeTaskId]);

  const closeStdin = useCallback(() => {
    if (activeTaskId !== null) {
      const tid = parseTaskId(activeTaskId);
      if (tid !== null) connRef.current?.sendCloseStdin(tid);
    }
  }, [activeTaskId]);

  const fork = useCallback((tid: number, afterUuid: string) => {
    connRef.current?.forkTask(tid, afterUuid);
  }, []);

  const undoPreview = useCallback((tid: number, afterUuid: string) => {
    // Optimistically set afterUuid so confirmation bar can reference it
    const t = liveStates.get(tid);
    if (t) {
      const updated = {
        ...t,
        undoPending: { afterUuid, messagesRemoved: -1 },
      };
      liveStates.set(tid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(tid, updated);
        return next;
      });
    }
    connRef.current?.undoTask(tid, afterUuid, true);
  }, []);

  const undoConfirm = useCallback(
    (tid: number, revertConversation: boolean, revertFiles: boolean) => {
      const t = liveStates.get(tid);
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
      liveStates.set(tid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(tid, updated);
        return next;
      });
    },
    [],
  );

  const undoDismiss = useCallback((tid: number) => {
    const t = liveStates.get(tid);
    if (!t) return;
    const updated = { ...t, undoPending: null };
    liveStates.set(tid, updated);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(tid, updated);
      return next;
    });
  }, []);

  const dismissAttention = useCallback((tid: number) => {
    connRef.current?.dismissAttention(tid);
  }, []);

  const clearInputDraft = useCallback((tid: number) => {
    const t = liveStates.get(tid);
    if (!t?.inputDraft) return;
    const updated = { ...t, inputDraft: undefined };
    liveStates.set(tid, updated);
    setTasks((prev) => {
      if (!prev.has(tid)) return prev;
      const next = new Map(prev);
      next.set(tid, updated);
      return next;
    });
  }, []);

  const resume = useCallback(() => {
    if (activeTaskId !== null) {
      const tid = parseTaskId(activeTaskId);
      if (tid === null) return;
      const t = liveStates.get(tid);
      if (t?.archived) return;
      connRef.current?.resumeTask(tid);
      if (t) {
        const updated = {
          ...t,
          alive: true,
          resumable: false,
          status: "active",
        };
        liveStates.set(tid, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
      }
    }
  }, [activeTaskId]);

  const promote = useCallback((tid: number) => {
    const t = liveStates.get(tid);
    if (!t || t.status !== "importable") return;
    connRef.current?.promoteTask(tid);
    // Optimistic update
    const updated = { ...t, status: "completed", resumable: true };
    liveStates.set(tid, updated);
    setTasks((prev) => {
      const next = new Map(prev);
      next.set(tid, updated);
      return next;
    });
  }, []);

  const setArchived = useCallback((tid: number, archived: boolean) => {
    connRef.current?.setArchived(tid, archived);
  }, []);

  const setEntryPoint = useCallback((tid: number, entryPoint: string) => {
    connRef.current?.setEntryPoint(tid, entryPoint);
  }, []);

  const setAgentType = useCallback((tid: number, agentType: string) => {
    connRef.current?.setAgentType(tid, agentType);
  }, []);

  const saveDraft = useCallback((tid: number, draft: string) => {
    connRef.current?.saveDraft(tid, draft);
    const t = liveStates.get(tid);
    if (t) {
      let updated: typeof t | null = null;
      // When draft is cleared (message sent), clear serverDraft so InputBox doesn't
      // restore a stale value on remount (e.g. after the welcome→active view transition).
      // We only clear on empty — non-empty updates are intentionally skipped to avoid
      // triggering the serverDraft effect in InputBox, which would corrupt lastServerDraftRef
      // and break the "don't overwrite local typing from broadcast" protection.
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
        liveStates.set(tid, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(tid, updated);
          return next;
        });
      }
    }
  }, []);

  const sendAskUserResponse = useCallback((tid: number, content: string) => {
    connRef.current?.sendAskUserResponse(tid, content);
    // Optimistically clear the pending question
    const t = liveStates.get(tid);
    if (t) {
      const updated = { ...t, pendingAskUser: null, isProcessing: true };
      liveStates.set(tid, updated);
      setTasks((prev) => {
        const next = new Map(prev);
        next.set(tid, updated);
        return next;
      });
    }
  }, []);

  const editMessage = useCallback(
    (tid: number, uuid: string, content: string) => {
      connRef.current?.editMessage(tid, uuid, content);
    },
    [],
  );

  // Build sidebar task list filtered by active workspace/project and sorted by tid
  const prevSidebarTasksRef = useRef<
    import("./components/Sidebar").SidebarTask[]
  >([]);
  const sidebarTasks = useMemo(() => {
    let filtered = Array.from(tasks.values()).filter((t) => t.tid > 0); // Exclude virtual drafts
    if (activeWorkspace !== null && activeProject !== null) {
      filtered = filtered.filter((t) => {
        if (!t.workspace || !t.projectPath) return false;
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
        resumable: t.resumable,
        isProcessing: t.isProcessing,
        title:
          t.title ||
          (t.status === "pending" && t.messages.length === 0 && t.serverDraft
            ? t.serverDraft.trim().split("\n")[0]?.slice(0, 100)
            : undefined),
        parentTid: t.parentTid,
        relationType: t.relationType,
        status: t.status,
        archived: t.archived,
        archiving: t.archiving,
        taskType: t.taskType,
        hasPendingQuestion: t.hasPendingQuestion,
        lastActive: t.lastActive,
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
          t.resumable === p.resumable &&
          t.isProcessing === p.isProcessing &&
          t.title === p.title &&
          t.parentTid === p.parentTid &&
          t.relationType === p.relationType &&
          t.status === p.status &&
          t.archived === p.archived &&
          t.archiving === p.archiving &&
          t.taskType === p.taskType &&
          t.hasPendingQuestion === p.hasPendingQuestion &&
          t.lastActive === p.lastActive &&
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
    setAgentType,
    sendAskUserResponse,
    editMessage,
    createDraftTask,
    deleteDraftTask,
    draftRenderKey,
    sidebarTasks,
    workspaces,
    entryPoints,
    typeInfo,
    agentTypes,
    defaultAgentType,
    activeWorkspace,
    activeProject,
    authEnabled,
    devMode,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    refreshWorkspaces: () => connRef.current?.refreshWorkspaces(),
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
