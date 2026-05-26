// Static task manager for exported HTML files — no WebSocket, no live updates.

import {
  useState,
  useEffect,
  useRef,
  useCallback,
  useMemo,
} from "preact/hooks";
import type { TaskManager, TypeInfo } from "./useSessionManager";
import type { AgnosticEvent } from "./protocol";
import { makeTaskState } from "./types";
import type { TaskState } from "./types";
import { reduceMessage } from "./sessionReducer";

interface ExportTaskEntry {
  tid: number;
  alive?: boolean;
  resumable?: boolean;
  title?: string;
  workspace?: string;
  project_path?: string;
  parent_tid?: number;
  relation_type?: string;
  status?: string;
  stdinClosed?: boolean;
  canStop?: boolean;
  task_type?: string;
  archived?: boolean;
  archiving?: boolean;
  created_at?: number;
  last_active?: number;
  agent_name?: string;
  entry_point?: string;
}

// Events in the export JSON are wrapped in TaskEventSeqEnvelope: {tid, seq, ts, event}.
interface ExportEventEnvelope {
  tid: number;
  seq: number;
  ts: number;
  event: AgnosticEvent;
}

interface ExportData {
  tasks: ExportTaskEntry[];
  events?: Record<string, ExportEventEnvelope[]>;
  typeInfo?: TypeInfo[];
}

interface ParsedExportData {
  data: ExportData | null;
  error: string | null;
}

export function parseExportDataText(text: string | null): ParsedExportData {
  if (!text || text.trim().length === 0) {
    return { data: null, error: "Missing embedded export data." };
  }
  try {
    const parsed = JSON.parse(text) as unknown;
    if (
      !parsed ||
      typeof parsed !== "object" ||
      !Array.isArray((parsed as ExportData).tasks)
    ) {
      return { data: null, error: "Invalid embedded export data format." };
    }
    return { data: parsed as ExportData, error: null };
  } catch {
    return { data: null, error: "Failed to parse embedded export data." };
  }
}

function buildTasksFromExportData(data: ExportData): Map<string, TaskState> {
  const taskMap = new Map<string, TaskState>();
  for (const entry of data.tasks) {
    let state = makeTaskState(
      entry.tid,
      entry.alive ?? false,
      entry.resumable ?? false,
      entry.title,
      true, // historyLoaded
      entry.workspace,
      entry.project_path,
      entry.parent_tid,
      entry.relation_type,
      entry.status ?? "completed",
      false, // isProcessing
      entry.stdinClosed ?? false,
      false, // needsAttention
      false, // hasPendingQuestion
      entry.task_type,
      entry.archived ?? false,
      entry.created_at,
      entry.last_active,
      entry.agent_name,
      entry.entry_point,
      entry.archiving ?? false,
      entry.canStop ?? entry.alive ?? false,
    );
    const events = data.events?.[String(entry.tid)] ?? [];
    for (let i = 0; i < events.length; i++) {
      state = reduceMessage(state, events[i]!.event, i, undefined);
    }
    taskMap.set(state.uuid, state);
  }
  return taskMap;
}

const noop = () => {
  // no-op for read-only export
};

export function useExportedTaskManager(): TaskManager {
  const [tasks, setTasks] = useState<Map<string, TaskState>>(new Map());
  const [activeTaskId, setActiveTaskIdState] = useState<string | null>(null);
  const activeTaskIdRef = useRef<string | null>(null);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);
  const [exportLoadError, setExportLoadError] = useState<string | null>(null);

  useEffect(() => {
    const el = document.getElementById("cydo-export-data");
    const parsed = parseExportDataText(el?.textContent ?? null);
    if (!parsed.data) {
      setExportLoadError(parsed.error);
      return;
    }
    const data = parsed.data;
    try {
      const taskMap = buildTasksFromExportData(data);
      setTasks(taskMap);
      setExportLoadError(null);
      if (data.typeInfo) setTypeInfo(data.typeInfo);

      const hash = window.location.hash;
      const match = hash.match(/^#task\/(\d+)$/);
      if (match) {
        activeTaskIdRef.current = match[1]!;
        setActiveTaskIdState(match[1]!);
      } else if (taskMap.size > 0) {
        const firstState = Array.from(taskMap.values()).sort(
          (a, b) => (a.tid ?? 0) - (b.tid ?? 0),
        )[0];
        const firstTid =
          firstState?.tid != null ? String(firstState.tid) : null;
        if (firstTid) {
          activeTaskIdRef.current = firstTid;
          setActiveTaskIdState(firstTid);
        }
      }
    } catch {
      setExportLoadError("Failed to load embedded export data.");
      setTasks(new Map());
    }
  }, []);

  useEffect(() => {
    const onHashChange = () => {
      const hash = window.location.hash;
      const match = hash.match(/^#task\/(\d+)$/);
      const id = match ? match[1]! : null;
      activeTaskIdRef.current = id;
      setActiveTaskIdState(id);
    };
    window.addEventListener("hashchange", onHashChange);
    return () => {
      window.removeEventListener("hashchange", onHashChange);
    };
  }, []);

  const setActiveTaskId = useCallback((id: string) => {
    activeTaskIdRef.current = id;
    setActiveTaskIdState(id);
    window.location.hash = `task/${id}`;
  }, []);

  const getTaskHref = useCallback((id: string) => `#task/${id}`, []);

  const getByTid = useCallback(
    (tid: number) => {
      for (const t of tasks.values()) {
        if (t.tid === tid) return t;
      }
      return undefined;
    },
    [tasks],
  );

  const sidebarTasks = useMemo(
    () =>
      Array.from(tasks.values())
        .filter((t): t is TaskState & { tid: number } => t.tid !== null)
        .sort((a, b) => a.tid - b.tid)
        .map((t) => ({
          tid: t.tid,
          alive: t.alive,
          canStop: t.canStop,
          resumable: t.resumable,
          isProcessing: t.isProcessing,
          stdinClosed: t.stdinClosed,
          title: t.title,
          parentTid: t.parentTid,
          relationType: t.relationType,
          status: t.status,
          archived: t.archived,
          archiving: t.archiving,
          taskType: t.taskType,
          hasPendingQuestion: t.hasPendingQuestion,
          hasMessages: t.messages.length > 0,
        })),
    [tasks],
  );

  return {
    tasks,
    activeTaskId,
    activeTaskIdRef,
    setActiveTaskId,
    connected: false,
    send: noop,
    interrupt: noop,
    stop: noop,
    closeStdin: noop,
    resume: noop,
    promote: noop,
    fork: noop,
    undoPreview: noop,
    undoConfirm: noop,
    undoDismiss: noop,
    dismissAttention: noop,
    clearInputDraft: noop,
    setArchived: noop,
    saveDraft: noop,
    setEntryPoint: noop,
    setAgentName: noop,
    sendAskUserResponse: noop,
    sendPermissionPromptResponse: noop,
    editMessage: noop,
    editRawEvent: noop,
    createDraftTask: noop,
    deleteDraftTask: noop,
    draftRenderKey: null,
    sidebarTasks,
    workspaces: [],
    entryPoints: [],
    typeInfo,
    agents: [],
    defaultAgent: "claude",
    defaultTaskType: "",
    activeWorkspace: null,
    activeProject: null,
    notices: {},
    localNotices: {},
    agentUsage: {},
    devMode: false,
    exportLoadError,
    navigateHome: noop,
    navigateToProject: noop,
    getProjectHref: () => "#",
    getTaskHref,
    getByTid,
    refreshWorkspaces: noop,
    scanState: "idle",
  };
}
