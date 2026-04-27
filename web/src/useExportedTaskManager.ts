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
  task_type?: string;
  archived?: boolean;
  created_at?: number;
  last_active?: number;
  agent_type?: string;
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

function buildTasksFromExportData(data: ExportData): Map<number, TaskState> {
  const taskMap = new Map<number, TaskState>();
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
      entry.agent_type,
      entry.entry_point,
    );
    const events = data.events?.[String(entry.tid)] ?? [];
    for (let i = 0; i < events.length; i++) {
      state = reduceMessage(state, events[i]!.event, i, undefined);
    }
    taskMap.set(entry.tid, state);
  }
  return taskMap;
}

const noop = () => {
  // no-op for read-only export
};

export function useExportedTaskManager(): TaskManager {
  const [tasks, setTasks] = useState<Map<number, TaskState>>(new Map());
  const [activeTaskId, setActiveTaskIdState] = useState<string | null>(null);
  const activeTaskIdRef = useRef<string | null>(null);
  const [typeInfo, setTypeInfo] = useState<TypeInfo[]>([]);

  useEffect(() => {
    const el = document.getElementById("cydo-export-data");
    if (!el || !el.textContent) return;
    let data: ExportData;
    try {
      data = JSON.parse(el.textContent) as ExportData;
    } catch {
      return;
    }
    const taskMap = buildTasksFromExportData(data);
    setTasks(taskMap);
    if (data.typeInfo) setTypeInfo(data.typeInfo);

    const hash = window.location.hash;
    const match = hash.match(/^#task\/(\d+)$/);
    if (match) {
      activeTaskIdRef.current = match[1]!;
      setActiveTaskIdState(match[1]!);
    } else if (taskMap.size > 0) {
      const firstTid = String([...taskMap.keys()].sort((a, b) => a - b)[0]);
      activeTaskIdRef.current = firstTid;
      setActiveTaskIdState(firstTid);
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

  const sidebarTasks = useMemo(
    () =>
      Array.from(tasks.values())
        .sort((a, b) => a.tid - b.tid)
        .map((t) => ({
          tid: t.tid,
          alive: t.alive,
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
          lastActive: t.lastActive,
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
    setAgentType: noop,
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
    agentTypes: [],
    defaultAgentType: "claude",
    defaultTaskType: "",
    activeWorkspace: null,
    activeProject: null,
    notices: {},
    devMode: false,
    navigateHome: noop,
    navigateToProject: noop,
    getProjectHref: () => "#",
    getTaskHref,
    refreshWorkspaces: noop,
    refreshingWorkspaces: false,
  };
}
