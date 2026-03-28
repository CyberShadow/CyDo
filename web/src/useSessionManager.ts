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
import type { TaskState } from "./types";
import { makeTaskState } from "./types";
import { reduceMessage } from "./sessionReducer";
import { drafts as inputDrafts } from "./components/InputBox";

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

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
  activeTaskIdRef: { current: string | null };
  setActiveTaskId: (id: string) => void;
  connected: boolean;
  send: (
    text: string,
    images?: ImageAttachment[],
    taskType?: string,
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
  sendAskUserResponse: (tid: number, content: string) => void;
  editMessage: (tid: number, uuid: string, content: string) => void;
  createDraftTask: (taskType?: string) => void;
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
  taskTypes: TaskTypeInfo[];
  agentTypes: AgentTypeInfo[];
  defaultAgentType: string;
  activeWorkspace: string | null;
  activeProject: string | null;
  authEnabled: boolean;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
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

export function useTaskManager(): TaskManager {
  const [connected, setConnected] = useState(false);
  const [tasks, setTasks] = useState<Map<number, TaskState>>(new Map());
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const [taskTypes, setTaskTypes] = useState<TaskTypeInfo[]>([]);
  const [agentTypes, setAgentTypes] = useState<AgentTypeInfo[]>([]);
  const [defaultAgentType, setDefaultAgentType] = useState("claude");
  const [authEnabled, setAuthEnabled] = useState(true);
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
      if (!t || !t.workspace || !t.projectPath) return [null, null];
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

  // Draft task management state
  const draftTidRef = useRef<number | null>(null);
  const draftRenderKeyRef = useRef<string | null>(null);
  const [draftRenderKey, setDraftRenderKey] = useState<string | null>(null);
  const pendingDraftCorrelation = useRef<string | null>(null);
  const draftCancelled = useRef(false);
  // Track recently deleted draft tids so handleTaskMessage skips stale
  // events arriving after deleteDraftTask (e.g. from requestHistory).
  // Cleared when the backend confirms deletion via task_deleted.
  const deletedDraftTids = useRef(new Set<number>());
  const draftCreateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(
    null,
  );
  // Stored first message for path (c): timer fired before task_created arrived.
  // Sent to the real task when task_created arrives instead of creating a zombie.
  const pendingFirstMessage = useRef<{
    text: string;
    taskType?: string;
    images?: ImageAttachment[];
  } | null>(null);

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
    draftRenderKeyRef.current = renderKey;
    setDraftRenderKey(renderKey);
    return renderKey;
  }, []);

  const createDraftTask = useCallback((taskType?: string) => {
    if (
      draftTidRef.current !== null ||
      pendingDraftCorrelation.current !== null ||
      draftCreateTimerRef.current !== null
    )
      return;
    const ws = activeWorkspaceRef.current;
    const proj = activeProjectRef.current;
    if (!ws || !proj) return;
    // Debounce: delay sending create_task so that rapid fill()+click()
    // sequences (common in Playwright tests) don't create zombie tasks.
    draftCreateTimerRef.current = setTimeout(() => {
      draftCreateTimerRef.current = null;
      draftCancelled.current = false;
      const projPath = findProjectPath(workspacesRef.current, ws, proj);
      const correlationId = crypto.randomUUID();
      pendingDraftCorrelation.current = correlationId;
      connRef.current?.createTask(
        ws,
        projPath || "",
        taskType,
        undefined,
        undefined,
        correlationId,
      );
    }, 16);
  }, []);

  const deleteDraftTask = useCallback(() => {
    // Cancel pending debounced create — create_task was never sent
    if (draftCreateTimerRef.current !== null) {
      clearTimeout(draftCreateTimerRef.current);
      draftCreateTimerRef.current = null;
      return;
    }
    const tid = draftTidRef.current;
    if (tid !== null && tid > 0) {
      // Real backend task — delete it
      deletedDraftTids.current.add(tid);
      inputDrafts.delete(tid);
      connRef.current?.deleteTask(tid);
      // Remove from tasks Map
      liveStates.delete(tid);
      setTasks((prev) => {
        if (!prev.has(tid)) return prev;
        const next = new Map(prev);
        next.delete(tid);
        return next;
      });
      // Reset virtual draft to tid=0 (reuse same renderKey — no remount)
      const renderKey = draftRenderKeyRef.current;
      draftTidRef.current = null;
      if (renderKey) {
        const ws = activeWorkspaceRef.current ?? "";
        const proj = activeProjectRef.current;
        const projPath = proj
          ? (findProjectPath(workspacesRef.current, ws, proj) ?? "")
          : "";
        const t: TaskState = {
          ...makeTaskState(0, false, false, undefined, true, ws, projPath),
          renderKey,
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
        // Navigate back to project root so activeTaskId becomes null
        // and the virtual draft view renders.
        if (ws && proj) {
          const encodedProject = proj.replace(/\//g, ":");
          routeRef.current(`/${ws}/${encodedProject}`, true);
        }
      }
    } else if (pendingDraftCorrelation.current !== null) {
      // Creation is pending — mark for deletion when task_created arrives
      draftCancelled.current = true;
    }
  }, []);

  // -- Live stdout message handler --
  // Reduces against the mutable liveStates map (synchronous), fires
  // notifications, then enqueues a Preact state update for rendering.
  const handleUnconfirmedUserMessage = useCallback(
    (tid: number, msg: AgnosticEvent) => {
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
    if (deletedDraftTids.current.has(tid)) return;
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
        setTaskTypes(msg.task_types);
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
        const isDraftCreation =
          pendingDraftCorrelation.current !== null &&
          msg.correlation_id === pendingDraftCorrelation.current;
        if (isDraftCreation) {
          pendingDraftCorrelation.current = null;
          if (draftCancelled.current) {
            // User blanked before task_created arrived — delete zombie
            draftCancelled.current = false;
            pendingFirstMessage.current = null;
            connRef.current?.deleteTask(tid);
            liveStates.delete(tid);
            setTasks((prev) => {
              if (!prev.has(tid)) return prev;
              const next = new Map(prev);
              next.delete(tid);
              return next;
            });
            break;
          }
          // Check if user sent before task_created arrived (path c piggyback)
          const firstMsg = pendingFirstMessage.current;
          pendingFirstMessage.current = null;
          // Copy in-memory draft from slot 0 to the real tid (only if not piggybacking)
          if (firstMsg === null) {
            const currentText = inputDrafts.get(0);
            if (currentText !== undefined) {
              inputDrafts.set(tid, currentText);
            }
          }
          inputDrafts.delete(0);
          // Transfer renderKey from virtual task (tid=0) to real task
          const renderKey = draftRenderKeyRef.current;
          liveStates.delete(0);
          const realTask: TaskState = {
            ...t,
            historyLoaded: true,
            renderKey: renderKey ?? undefined,
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
            draftTidRef.current = null;
            draftRenderKeyRef.current = null;
            setDraftRenderKey(null);
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
            draftTidRef.current = tid;
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
          if (deletedDraftTids.current.has(entry.tid)) continue;
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
              suggestions:
                entry.isProcessing && !existing.isProcessing
                  ? undefined
                  : existing.suggestions,
              archived: entry.archived || false,
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
        if (deletedDraftTids.current.has(entry.tid)) break;
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
            suggestions:
              entry.isProcessing && !existing.isProcessing
                ? undefined
                : existing.suggestions,
            archived: entry.archived || false,
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
        // Clear draft refs if this was the current draft
        if (draftTidRef.current === tid) {
          draftTidRef.current = null;
          // Note: don't clear draftRenderKey — the virtual task with renderKey
          // is recreated by deleteDraftTask (same renderKey, tid=0)
        }
        deletedDraftTids.current.delete(tid);
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
        draftTidRef.current = null;
        draftRenderKeyRef.current = null;
        pendingDraftCorrelation.current = null;
        draftCancelled.current = false;
        deletedDraftTids.current.clear();
        pendingFirstMessage.current = null;
        if (draftCreateTimerRef.current !== null) {
          clearTimeout(draftCreateTimerRef.current);
          draftCreateTimerRef.current = null;
        }
        setDraftRenderKey(null);
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

  // Manage draft tracking state in response to navigation.
  //
  // When activeTaskId is null (project root / "New Task"):
  //   - Clear stale draft tracking and create a fresh virtual draft.
  //   Both must happen atomically in one effect to avoid ordering issues.
  //
  // When activeTaskId points to a pending draft task:
  //   - Re-adopt it as the active draft so isDraft/taskTypes/onContentEnd
  //   are wired correctly (e.g. after navigating away and back).
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
          !task.isProcessing &&
          task.renderKey
        ) {
          draftTidRef.current = tid;
          draftRenderKeyRef.current = task.renderKey;
          setDraftRenderKey(task.renderKey);
        }
      }
      return;
    }
    if (activeWorkspace === null) return; // on welcome page, no draft
    // Clear existing draft tracking when a real draft task exists
    if (draftTidRef.current !== null) {
      draftTidRef.current = null;
      draftRenderKeyRef.current = null;
      setDraftRenderKey(null);
    }
    // Create fresh virtual draft if none exists
    if (draftRenderKeyRef.current === null) {
      inputDrafts.delete(0); // clear stale text re-saved by InputBox cleanup
      createVirtualDraft();
    }
  }, [activeTaskId, activeWorkspace, createVirtualDraft]);

  const send = useCallback(
    (
      text: string,
      images?: ImageAttachment[],
      taskType?: string,
      agentType?: string,
    ) => {
      const content = buildContentBlocks(text, images);
      // Check for virtual draft with real tid
      const draftTid = draftTidRef.current;
      if (draftTid !== null && draftTid > 0) {
        // Draft task exists — send message to it
        connRef.current?.sendMessage(draftTid, content);
        // Clear draft state (task transitions from draft to active)
        draftTidRef.current = null;
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
        // Clear renderKey after navigation to avoid brief unmount
        draftRenderKeyRef.current = null;
        setDraftRenderKey(null);
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
        if (pendingDraftCorrelation.current !== null) {
          pendingFirstMessage.current = { text, taskType, images };
          return;
        }

        // Path (b): timer hasn't fired yet — cancel it and use atomic create+send.
        if (draftCreateTimerRef.current !== null) {
          clearTimeout(draftCreateTimerRef.current);
          draftCreateTimerRef.current = null;
        }
        // Remove virtual draft (tid=0).
        liveStates.delete(0);
        setTasks((prev) => {
          if (!prev.has(0)) return prev;
          const next = new Map(prev);
          next.delete(0);
          return next;
        });
        draftTidRef.current = null;
        draftRenderKeyRef.current = null;
        setDraftRenderKey(null);

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
            taskType,
            content,
            agentType,
            correlationId,
          );
        } else {
          connRef.current?.createTask(
            undefined,
            undefined,
            taskType,
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
    [activeTaskId, setTasks],
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

  const saveDraft = useCallback((tid: number, draft: string) => {
    connRef.current?.saveDraft(tid, draft);
    // Derive sidebar title from draft text for pending tasks with no messages
    const t = liveStates.get(tid);
    if (t && t.status === "pending" && t.messages.length === 0) {
      const firstLine = draft.trim().split("\n")[0]?.slice(0, 100) || undefined;
      if (firstLine !== t.title) {
        const updated = { ...t, title: firstLine };
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
        title: t.title,
        parentTid: t.parentTid,
        relationType: t.relationType,
        status: t.status,
        archived: t.archived,
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
    sendAskUserResponse,
    editMessage,
    createDraftTask,
    deleteDraftTask,
    draftRenderKey,
    sidebarTasks,
    workspaces,
    taskTypes,
    agentTypes,
    defaultAgentType,
    activeWorkspace,
    activeProject,
    authEnabled,
    navigateHome,
    navigateToProject,
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
