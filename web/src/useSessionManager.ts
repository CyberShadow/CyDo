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
import { useLocation } from "preact-iso";
import { Connection } from "./connection";
import type {
  AgnosticEvent,
  AgnosticFileEvent,
  ControlMessage,
} from "./schemas";
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
  description: string;
  model_class: string;
  read_only: boolean;
}

export interface TaskManager {
  tasks: Map<number, TaskState>;
  activeTaskId: number | null;
  setActiveTaskId: (tid: number) => void;
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
  sidebarTasks: Array<{
    tid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    title?: string;
    parentTid?: number;
    relationType?: string;
    status?: string;
  }>;
  workspaces: WorkspaceInfo[];
  taskTypes: TaskTypeInfo[];
  activeWorkspace: string | null;
  activeProject: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
}

interface ParsedPath {
  workspace: string | null;
  project: string | null;
  tid: number | null;
}

function parseFromPath(path: string): ParsedPath {
  // Legacy: /session/:sid (redirect handled elsewhere)
  const legacyMatch = path.match(/^\/session\/(\d+)$/);
  if (legacyMatch) {
    return { workspace: null, project: null, tid: Number(legacyMatch[1]) };
  }

  // /task/:tid (no workspace context)
  const taskMatch = path.match(/^\/task\/(\d+)$/);
  if (taskMatch) {
    return { workspace: null, project: null, tid: Number(taskMatch[1]) };
  }

  // /:workspace/:project/task/:tid
  const wpTaskMatch = path.match(/^\/([^/]+)\/([^/]+)\/task\/(\d+)$/);
  if (wpTaskMatch) {
    return {
      workspace: wpTaskMatch[1],
      project: wpTaskMatch[2].replace(/:/g, "/"),
      tid: Number(wpTaskMatch[3]),
    };
  }

  // Legacy: /:workspace/:project/session/:sid
  const wpSessionMatch = path.match(/^\/([^/]+)\/([^/]+)\/session\/(\d+)$/);
  if (wpSessionMatch) {
    return {
      workspace: wpSessionMatch[1],
      project: wpSessionMatch[2].replace(/:/g, "/"),
      tid: Number(wpSessionMatch[3]),
    };
  }

  // /:workspace/:project
  const projectMatch = path.match(/^\/([^/]+)\/([^/]+)$/);
  if (projectMatch) {
    return {
      workspace: projectMatch[1],
      project: projectMatch[2].replace(/:/g, "/"),
      tid: null,
    };
  }

  // / (welcome page) or anything else
  return { workspace: null, project: null, tid: null };
}

/// Extract text content from a user message event (for unconfirmed display).
function extractTextContent(msg: AgnosticEvent): string {
  const raw = msg as any;
  if (raw?.message?.content) {
    if (typeof raw.message.content === "string") return raw.message.content;
    if (Array.isArray(raw.message.content)) {
      return raw.message.content
        .filter((b: any) => b.type === "text")
        .map((b: any) => b.text)
        .join("");
    }
  }
  return "";
}

// Mutable mirror of task states, updated synchronously outside Preact's
// render cycle.  Used so that reducers and notification checks run immediately
// when WebSocket messages arrive, even when Preact defers state updates in
// background tabs.
const liveStates = new Map<number, TaskState>();

export function useTaskManager(): TaskManager {
  const [connected, setConnected] = useState(false);
  const [tasks, setTasks] = useState<Map<number, TaskState>>(new Map());
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [taskTypes, setTaskTypes] = useState<TaskTypeInfo[]>([]);
  const { path, route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;

  const parsed = useMemo(() => parseFromPath(path), [path]);
  const activeTaskIdRef = useRef(parsed.tid);
  activeTaskIdRef.current = parsed.tid;
  const activeTaskId = parsed.tid;
  const activeWorkspace = parsed.workspace;
  const activeProject = parsed.project;

  const setActiveTaskId = useCallback((tid: number) => {
    // Look up the task to build the full URL
    const t = liveStates.get(tid);
    if (t?.workspace && t?.projectPath) {
      // Find the project name from workspaces
      const projName = findProjectName(
        workspacesRef.current,
        t.workspace,
        t.projectPath,
      );
      if (projName) {
        const encodedProject = projName.replace(/\//g, ":");
        routeRef.current(`/${t.workspace}/${encodedProject}/task/${tid}`);
        return;
      }
    }
    routeRef.current(`/task/${tid}`);
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
  // True when this client initiated a task creation and should focus it
  const pendingFocus = useRef(false);
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

    // When an agent sub-task exits and it's currently focused, switch to parent.
    // User-created children (forks) stay focused — user navigates manually.
    if (
      msg.type === "process/exit" &&
      prev.parentTid &&
      prev.relationType !== "fork" &&
      activeTaskIdRef.current === tid
    ) {
      const parent = liveStates.get(prev.parentTid);
      if (parent) {
        setActiveTaskId(prev.parentTid);
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
          relationType !== "fork" && relationType !== "undo-backup", // Forks/backups have JSONL history that must be loaded
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
        // - this client created it (top-level), or
        // - its parent is currently focused (sub-task visible in context)
        // Never auto-focus undo-backup tasks (they're invisible backups).
        const shouldFocus =
          relationType === "undo-backup"
            ? false
            : parentTid
              ? activeTaskIdRef.current === parentTid
              : pendingFocus.current;
        pendingFocus.current = false;
        if (shouldFocus) {
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
              routeRef.current(`/task/${tid}`);
            }
          } else {
            routeRef.current(`/task/${tid}`);
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
              const t = makeTaskState(
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
                entry.task_type || undefined,
              );
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
                historyLoaded: needsHistory ? false : t.historyLoaded,
                title: entry.title || t.title,
                workspace: workspace || t.workspace,
                projectPath: projectPath || t.projectPath,
                parentTid: entry.parent_tid || t.parentTid,
                relationType: entry.relation_type || t.relationType,
                status: entry.status || t.status,
                taskType: entry.task_type || t.taskType,
              };
              liveStates.set(entry.tid, updated);
              next.set(entry.tid, updated);
            }
          }
          return next;
        });
        // Navigate to most recently active task if on a project page without a task
        // Do NOT auto-navigate when on welcome page (/)
        const currentParsed = parseFromPath(location.pathname);
        if (
          msg.tasks.length > 0 &&
          currentParsed.tid === null &&
          currentParsed.workspace === null &&
          location.pathname !== "/"
        ) {
          // Legacy: no path structure, not welcome page
          const latest = msg.tasks.reduce((a, b) =>
            (b.lastActivity || "") > (a.lastActivity || "") ? b : a,
          );
          routeRef.current(`/task/${latest.tid}`, true);
        }
        break;
      }
      case "task_reload": {
        const { tid } = msg;
        requestedHistoryRef.current.delete(tid);
        const t = liveStates.get(tid);
        if (!t) break;
        // Collect user message texts to detect unsaved prompts after replay
        const userTexts = t.messages
          .filter((m) => m.type === "user")
          .map((m) =>
            m.content
              .filter((b) => b.type === "text")
              .map((b) => ("text" in b ? b.text : ""))
              .join(""),
          )
          .filter((t) => t.length > 0);
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
          preReloadDrafts: userTexts.length > 0 ? userTexts : undefined,
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
        if (tid === activeTaskIdRef.current) {
          requestedHistoryRef.current.add(tid);
          connRef.current?.requestHistory(tid);
        }
        break;
      }
      case "task_history_end": {
        const { tid } = msg;
        let t = liveStates.get(tid);
        if (!t) break;
        t = { ...t, historyLoaded: true };
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
        const { tid, messages_removed } = msg as any;
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
      case "error": {
        const errMsg = (msg as any).message ?? "Unknown error";
        const errTid = (msg as any).tid as number | undefined;
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
    if (requestedHistoryRef.current.has(activeTaskId)) return;
    const t = liveStates.get(activeTaskId);
    if (t?.historyLoaded) return;
    requestedHistoryRef.current.add(activeTaskId);
    connRef.current?.requestHistory(activeTaskId);
  }, [connected, activeTaskId]);

  const send = useCallback(
    (text: string, taskType?: string) => {
      if (activeTaskId === null) {
        // No active task — create one with the message atomically
        pendingFocus.current = true;
        const parsed = parseFromPath(location.pathname);
        if (parsed.workspace && parsed.project) {
          const projPath = findProjectPath(
            workspacesRef.current,
            parsed.workspace,
            parsed.project,
          );
          connRef.current?.createTask(
            parsed.workspace,
            projPath || "",
            taskType,
            text,
          );
        } else {
          connRef.current?.createTask(undefined, undefined, taskType, text);
        }
        return;
      }
      connRef.current?.sendMessage(activeTaskId, text);
    },
    [activeTaskId],
  );

  const interrupt = useCallback(() => {
    if (activeTaskId !== null) {
      connRef.current?.sendInterrupt(activeTaskId);
    }
  }, [activeTaskId]);

  const stop = useCallback(() => {
    if (activeTaskId !== null) {
      connRef.current?.sendStop(activeTaskId);
    }
  }, [activeTaskId]);

  const closeStdin = useCallback(() => {
    if (activeTaskId !== null) {
      connRef.current?.sendCloseStdin(activeTaskId);
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

  const resume = useCallback(() => {
    if (activeTaskId !== null) {
      connRef.current?.resumeTask(activeTaskId);
      const t = liveStates.get(activeTaskId);
      if (t) {
        const updated = {
          ...t,
          alive: true,
          resumable: false,
          status: "active",
        };
        liveStates.set(activeTaskId, updated);
        setTasks((prev) => {
          const next = new Map(prev);
          next.set(activeTaskId, updated);
          return next;
        });
      }
    }
  }, [activeTaskId]);

  // Build sidebar task list filtered by active workspace/project and sorted by tid
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
    return filtered
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
      }));
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
