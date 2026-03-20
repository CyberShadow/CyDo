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
  AgnosticEvent,
  AgnosticFileEvent,
  AskUserQuestionControlMessage,
  ControlMessage,
  DraftUpdatedMessage,
  SuggestionsUpdateMessage,
  TaskReloadMessage,
  TaskUpdatedMessage,
} from "./protocol";
import type { TaskState } from "./types";
import { makeTaskState } from "./types";
import {
  reduceStdoutMessage,
  reduceFileMessage,
  reducePendingUserMessage,
} from "./sessionReducer";

export interface ProjectInfo {
  name: string;
  path: string;
}

export interface WorkspaceInfo {
  name: string;
  projects: ProjectInfo[];
}

export interface TaskTypeInfo {
  name: string;
  display_name?: string;
  description: string;
  model_class: string;
  read_only: boolean;
  icon?: string;
  user_visible?: boolean;
}

export interface TaskManager {
  tasks: Map<number, TaskState>;
  activeTaskId: string | null;
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  send: (text: string, taskType?: string) => void;
  interrupt: () => void;
  stop: () => void;
  closeStdin: () => void;
  resume: () => void;
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
  sendAskUserResponse: (tid: number, content: string) => void;
  editMessage: (tid: number, uuid: string, content: string) => void;
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
  }>;
  workspaces: WorkspaceInfo[];
  taskTypes: TaskTypeInfo[];
  activeWorkspace: string | null;
  activeProject: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
}

/// Extract text content from a user message event (for unconfirmed display).
function extractTextContent(msg: AgnosticEvent): string {
  if (msg.type !== "message/user") return "";
  if (typeof msg.content === "string") return msg.content;
  if (Array.isArray(msg.content)) {
    return msg.content
      .filter((b) => b.type === "text")
      .map((b) => b.text ?? "")
      .join("");
  }
  return "";
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

export function useTaskManager(): TaskManager {
  const [connected, setConnected] = useState(false);
  const [tasks, setTasks] = useState<Map<number, TaskState>>(new Map());
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [taskTypes, setTaskTypes] = useState<TaskTypeInfo[]>([]);
  const { route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;

  const { params, path } = useRoute();
  const parsed = useMemo(() => {
    // Archive routes set parentTid param; derive the virtual archive ID
    const isArchive = path.includes("/archive");
    const tid = isArchive
      ? params.parentTid
        ? `archive:${params.parentTid}`
        : "archive"
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

  const setActiveTaskId = useCallback((id: string) => {
    // Helper: build a URL with optional workspace/project prefix
    const buildUrl = (
      ws: string | null,
      proj: string | null,
      suffix: string,
    ) => {
      if (ws && proj) {
        const enc = proj.replace(/\//g, ":");
        return `/${ws}/${enc}${suffix}`;
      }
      return suffix;
    };

    // Helper: find workspace/project for a numeric task ID
    const taskContext = (tid: number): [string | null, string | null] => {
      const t = liveStates.get(tid);
      if (!t?.workspace || !t?.projectPath) return [null, null];
      const projName = findProjectName(
        workspacesRef.current,
        t.workspace,
        t.projectPath,
      );
      return projName ? [t.workspace, projName] : [null, null];
    };

    // Archive nodes: route to /archive or /:ws/:proj/archive/:parentTid
    if (id === "archive") {
      routeRef.current(
        buildUrl(
          activeWorkspaceRef.current,
          activeProjectRef.current,
          "/archive",
        ),
      );
      return;
    }
    const archiveMatch = id.match(/^archive:(\d+)$/);
    if (archiveMatch) {
      const parentTid = parseInt(archiveMatch[1]!, 10);
      const [ws, proj] = taskContext(parentTid);
      routeRef.current(buildUrl(ws, proj, `/archive/${parentTid}`));
      return;
    }

    // Regular task: look up workspace/project from task state
    const tid = parseInt(id, 10);
    if (!isNaN(tid)) {
      activeTaskIdRef.current = id;
      const [ws, proj] = taskContext(tid);
      routeRef.current(buildUrl(ws, proj, `/task/${id}`));
      return;
    }

    routeRef.current("/");
  }, []);

  const navigateHome = useCallback(() => {
    routeRef.current("/");
  }, []);

  const navigateToProject = useCallback(
    (workspace: string, projectName: string) => {
      const encodedProject = projectName.replace(/\//g, ":");
      routeRef.current(`/${workspace}/${encodedProject}`);
    },
    [],
  );

  const connRef = useRef<Connection | null>(null);
  // Correlation ID of the most recent createTask call; set to null once consumed.
  // The client only auto-focuses a new task when the task_created response echoes this ID.
  const pendingFocusId = useRef<string | null>(null);
  // Track which tasks have had history requested (avoid duplicate requests)
  const requestedHistoryRef = useRef(new Set<number>());

  // Buffer for live messages that arrive before history is loaded.
  // Keyed by tid; drained on task_history_end.
  const pendingLiveRef = useRef(new Map<number, AgnosticEvent[]>());

  // -- Live stdout message handler --
  // Reduces against the mutable liveStates map (synchronous), fires
  // notifications, then enqueues a Preact state update for rendering.
  const handleUnconfirmedUserMessage = useCallback(
    (tid: number, msg: AgnosticEvent) => {
      const t = liveStates.get(tid);
      const prev = t ?? makeTaskState(tid, true);
      const updated = reducePendingUserMessage(prev, extractTextContent(msg));
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
    // If history has been requested but not yet loaded, buffer live
    // messages so they are processed after history.
    const t = liveStates.get(tid);
    if (t && !t.historyLoaded && !requestedHistoryRef.current.has(tid)) {
      console.warn(
        `[CyDo] Received event for task ${tid} before history was loaded — this shouldn't happen`,
        msg.type,
      );
    }
    if (t && !t.historyLoaded && requestedHistoryRef.current.has(tid)) {
      let buf = pendingLiveRef.current.get(tid);
      if (!buf) {
        buf = [];
        pendingLiveRef.current.set(tid, buf);
      }
      buf.push(msg);
      return;
    }

    const prev = t ?? makeTaskState(tid, true);
    const updated = reduceStdoutMessage(prev, msg);
    liveStates.set(tid, updated);

    // When an agent sub-task exits and it's currently focused, switch to the
    // first alive ancestor. For continuations (Handoff), the direct parent is
    // already completed; the actual result receiver is further up the chain.
    // User-created children (forks) stay focused — user navigates manually.
    if (
      msg.type === "process/exit" &&
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

  // -- JSONL file message handler --
  const handleFileMessage = useCallback(
    (tid: number, msg: AgnosticFileEvent) => {
      const prev = liveStates.get(tid) ?? makeTaskState(tid);
      const updated = reduceFileMessage(prev, msg);
      liveStates.set(tid, updated);

      setTasks((map) => {
        const next = new Map(map);
        next.set(tid, updated);
        return next;
      });
    },
    [],
  );

  const handleControlMessage = useCallback((msg: ControlMessage) => {
    switch (msg.type) {
      case "workspaces_list": {
        setWorkspaces(msg.workspaces);
        break;
      }
      case "task_types_list": {
        setTaskTypes(msg.task_types);
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

        // Navigate to the new task only if:
        // - this client created it (top-level, correlation ID matches), or
        // - its parent is currently focused (sub-task visible in context)
        // Never auto-focus undo-backup tasks (they're invisible backups).
        const shouldFocus =
          relationType === "undo-backup"
            ? false
            : parentTid
              ? activeTaskIdRef.current === String(parentTid)
              : pendingFocusId.current !== null &&
                msg.correlation_id === pendingFocusId.current;
        pendingFocusId.current = null;
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
        setTasks((prev) => {
          const next = new Map(prev);
          for (const entry of msg.tasks) {
            const workspace = entry.workspace || "";
            const projectPath = entry.project_path || "";
            if (!next.has(entry.tid)) {
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
                ),
                serverDraft: entry.draft || undefined,
                error: entry.error || undefined,
              };
              liveStates.set(entry.tid, t);
              next.set(entry.tid, t);
            } else {
              const t = next.get(entry.tid)!;
              // If a task becomes resumable but has no messages loaded,
              // reset historyLoaded so JSONL history gets requested
              // (e.g. forked tasks with pre-existing JSONL).
              const needsHistory =
                entry.resumable && t.messages.length === 0 && t.historyLoaded;
              const updated = {
                ...t,
                alive: entry.alive,
                resumable: entry.resumable,
                isProcessing: entry.isProcessing || false,
                needsAttention: entry.needsAttention || false,
                hasPendingQuestion: entry.hasPendingQuestion || false,
                historyLoaded: needsHistory ? false : t.historyLoaded,
                title: entry.title || t.title,
                workspace: workspace || t.workspace,
                projectPath: projectPath || t.projectPath,
                parentTid: entry.parent_tid || t.parentTid,
                relationType: entry.relation_type || t.relationType,
                status: entry.status || t.status,
                taskType: entry.task_type || t.taskType,
                suggestions:
                  entry.isProcessing && !t.isProcessing
                    ? undefined
                    : t.suggestions,
                archived: entry.archived || false,
                error: entry.error || undefined,
              };
              liveStates.set(entry.tid, updated);
              next.set(entry.tid, updated);
            }
          }
          return next;
        });
        break;
      }
      case "task_updated": {
        const entry = (msg as TaskUpdatedMessage).task;
        setTasks((prev) => {
          const next = new Map(prev);
          const workspace = entry.workspace || "";
          const projectPath = entry.project_path || "";
          if (!next.has(entry.tid)) {
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
              ),
              serverDraft: entry.draft || undefined,
              error: entry.error || undefined,
            };
            liveStates.set(entry.tid, t);
            next.set(entry.tid, t);
          } else {
            const t = next.get(entry.tid)!;
            const needsHistory =
              entry.resumable && t.messages.length === 0 && t.historyLoaded;
            const updated = {
              ...t,
              alive: entry.alive,
              resumable: entry.resumable,
              isProcessing: entry.isProcessing || false,
              needsAttention: entry.needsAttention || false,
              hasPendingQuestion: entry.hasPendingQuestion || false,
              historyLoaded: needsHistory ? false : t.historyLoaded,
              title: entry.title || t.title,
              workspace: workspace || t.workspace,
              projectPath: projectPath || t.projectPath,
              parentTid: entry.parent_tid || t.parentTid,
              relationType: entry.relation_type || t.relationType,
              status: entry.status || t.status,
              taskType: entry.task_type || t.taskType,
              suggestions:
                entry.isProcessing && !t.isProcessing
                  ? undefined
                  : t.suggestions,
              archived: entry.archived || false,
              error: entry.error || undefined,
            };
            liveStates.set(entry.tid, updated);
            next.set(entry.tid, updated);
          }
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
        const isEdit = (msg as TaskReloadMessage).reason === "edit";
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

        t = {
          ...t,
          historyLoaded: true,
          preReloadDrafts: undefined,
          confirmedDuringReplay: undefined,
          inputDraft,
        };
        liveStates.set(tid, t);

        // Drain any live messages that were buffered while history was loading.
        // The backend uses a unified history model (JSONL + live events are
        // disjoint), so no deduplication is needed here.
        const buffered = pendingLiveRef.current.get(tid);
        if (buffered) {
          pendingLiveRef.current.delete(tid);
          for (const liveMsg of buffered) {
            const prev = liveStates.get(tid)!;
            const next = reduceStdoutMessage(prev, liveMsg);
            liveStates.set(tid, next);
          }
          t = liveStates.get(tid)!;
        }

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
        const { tid, suggestions } = msg as SuggestionsUpdateMessage;
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
        const { tid, new_draft } = msg as DraftUpdatedMessage;
        setTasks((prev) => {
          const task = prev.get(tid);
          if (!task) return prev;
          const next = new Map(prev);
          next.set(tid, { ...task, serverDraft: new_draft });
          return next;
        });
        const t = liveStates.get(tid);
        if (t) liveStates.set(tid, { ...t, serverDraft: new_draft });
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
      case "ask_user_question": {
        const { tid, tool_use_id, questions } =
          msg as AskUserQuestionControlMessage;
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
      | { kind: "unconfirmed"; tid: number; msg: AgnosticEvent }
      | { kind: "file"; tid: number; msg: AgnosticFileEvent }
      | { kind: "control"; msg: ControlMessage };
    let buffer: BufferedMsg[] = [];
    let flushId: number | null = null;

    const flush = () => {
      flushId = null;
      const batch = buffer;
      buffer = [];
      for (const item of batch) {
        if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "file") handleFileMessage(item.tid, item.msg);
        else if (item.kind === "unconfirmed")
          handleUnconfirmedUserMessage(item.tid, item.msg);
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
    };

    const scheduleFlush = () => {
      if (document.hidden) {
        cancelPendingFlush();
        flush();
        return;
      }
      if (flushId !== null) return;
      flushId = requestAnimationFrame(flush);
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
      setConnected(connected);
      if (!connected) {
        liveStates.clear();
        requestedHistoryRef.current.clear();
        setTasks(new Map());
      }
    };

    conn.onTaskMessage = (tid, msg) => {
      buffer.push({ kind: "task", tid, msg });
      scheduleFlush();
    };
    conn.onUnconfirmedUserMessage = (tid, msg) => {
      buffer.push({ kind: "unconfirmed", tid, msg });
      scheduleFlush();
    };
    conn.onFileMessage = (tid, msg) => {
      buffer.push({ kind: "file", tid, msg });
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
  }, [handleTaskMessage, handleFileMessage, handleControlMessage]);

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
  }, [connected, activeTaskId]);

  const send = useCallback(
    (text: string, taskType?: string) => {
      if (activeTaskId === null) {
        // No active task — create one with the message atomically
        const correlationId = crypto.randomUUID();
        pendingFocusId.current = correlationId;
        const ws = activeWorkspaceRef.current;
        const proj = activeProjectRef.current;
        if (ws && proj) {
          const projPath = findProjectPath(workspacesRef.current, ws, proj);
          connRef.current?.createTask(
            ws,
            projPath || "",
            taskType,
            text,
            undefined,
            correlationId,
          );
        } else {
          connRef.current?.createTask(
            undefined,
            undefined,
            taskType,
            text,
            undefined,
            correlationId,
          );
        }
        return;
      }
      const tid = parseTaskId(activeTaskId);
      if (tid === null) return;
      connRef.current?.sendMessage(tid, text);
    },
    [activeTaskId],
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
    setTasks((prev) => {
      const t = prev.get(tid);
      if (!t?.inputDraft) return prev;
      const updated = { ...t, inputDraft: undefined };
      liveStates.set(tid, updated);
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

  const setArchived = useCallback((tid: number, archived: boolean) => {
    connRef.current?.setArchived(tid, archived);
  }, []);

  const saveDraft = useCallback((tid: number, draft: string) => {
    connRef.current?.saveDraft(tid, draft);
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
    let filtered = Array.from(tasks.values());
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
        title: t.title,
        parentTid: t.parentTid,
        relationType: t.relationType,
        status: t.status,
        archived: t.archived,
        taskType: t.taskType,
        hasPendingQuestion: t.hasPendingQuestion,
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
          t.taskType === p.taskType &&
          t.hasPendingQuestion === p.hasPendingQuestion
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
    setActiveTaskId,
    connected,
    send,
    interrupt,
    stop,
    closeStdin,
    resume,
    fork,
    undoPreview,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    setArchived,
    saveDraft,
    sendAskUserResponse,
    editMessage,
    sidebarTasks,
    workspaces,
    taskTypes,
    activeWorkspace,
    activeProject,
    navigateHome,
    navigateToProject,
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
