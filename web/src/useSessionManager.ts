// Custom hook: WebSocket connection, rAF message buffering, session state, and user actions.

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
  ClaudeMessage,
  ClaudeFileMessage,
  ControlMessage,
} from "./schemas";
import type { SessionState } from "./types";
import { makeSessionState } from "./types";
import {
  reduceStdoutMessage,
  reduceFileMessage,
  reducePendingUserMessage,
} from "./sessionReducer";
import {
  notifyTransition,
  initSnapshot,
  resetReplay,
  markReplayDone,
} from "./useNotifications";

export interface ProjectInfo {
  name: string;
  path: string;
}

export interface WorkspaceInfo {
  name: string;
  projects: ProjectInfo[];
}

export interface SessionManager {
  sessions: Map<number, SessionState>;
  activeSessionId: number | null;
  setActiveSessionId: (sid: number) => void;
  connected: boolean;
  send: (text: string) => void;
  interrupt: () => void;
  newSession: (workspace?: string, projectPath?: string) => void;
  resume: () => void;
  sidebarSessions: Array<{
    sid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    title?: string;
  }>;
  workspaces: WorkspaceInfo[];
  activeWorkspace: string | null;
  activeProject: string | null;
  navigateHome: () => void;
  navigateToProject: (workspace: string, projectName: string) => void;
}

interface ParsedPath {
  workspace: string | null;
  project: string | null;
  sid: number | null;
}

function parseFromPath(path: string): ParsedPath {
  // Legacy: /session/:sid
  const legacyMatch = path.match(/^\/session\/(\d+)$/);
  if (legacyMatch) {
    return { workspace: null, project: null, sid: Number(legacyMatch[1]) };
  }

  // /:workspace/:project/session/:sid
  const sessionMatch = path.match(/^\/([^/]+)\/([^/]+)\/session\/(\d+)$/);
  if (sessionMatch) {
    return {
      workspace: sessionMatch[1],
      project: sessionMatch[2].replace(/:/g, "/"),
      sid: Number(sessionMatch[3]),
    };
  }

  // /:workspace/:project
  const projectMatch = path.match(/^\/([^/]+)\/([^/]+)$/);
  if (projectMatch) {
    return {
      workspace: projectMatch[1],
      project: projectMatch[2].replace(/:/g, "/"),
      sid: null,
    };
  }

  // / (welcome page) or anything else
  return { workspace: null, project: null, sid: null };
}

// Mutable mirror of session states, updated synchronously outside Preact's
// render cycle.  Used so that reducers and notification checks run immediately
// when WebSocket messages arrive, even when Preact defers state updates in
// background tabs.
const liveStates = new Map<number, SessionState>();

export function useSessionManager(): SessionManager {
  const [connected, setConnected] = useState(false);
  const [sessions, setSessions] = useState<Map<number, SessionState>>(
    new Map(),
  );
  const [workspaces, setWorkspaces] = useState<WorkspaceInfo[]>([]);
  const { path, route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const workspacesRef = useRef(workspaces);
  workspacesRef.current = workspaces;

  const parsed = useMemo(() => parseFromPath(path), [path]);
  const activeSessionId = parsed.sid;
  const activeWorkspace = parsed.workspace;
  const activeProject = parsed.project;

  const setActiveSessionId = useCallback((sid: number) => {
    // Look up the session to build the full URL
    const s = liveStates.get(sid);
    if (s?.workspace && s?.projectPath) {
      // Find the project name from workspaces
      const projName = findProjectName(
        workspacesRef.current,
        s.workspace,
        s.projectPath,
      );
      if (projName) {
        const encodedProject = projName.replace(/\//g, ":");
        routeRef.current(`/${s.workspace}/${encodedProject}/session/${sid}`);
        return;
      }
    }
    routeRef.current(`/session/${sid}`);
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
  // When we create a session and want to send a message once it's confirmed
  const pendingFirstMessage = useRef<string | null>(null);
  // Track which sessions have had history requested (avoid duplicate requests)
  const requestedHistoryRef = useRef(new Set<number>());
  // Track workspace/projectPath for pending session creation
  const pendingSessionContext = useRef<{
    workspace?: string;
    projectPath?: string;
  } | null>(null);

  // Buffer for live messages that arrive before history is loaded.
  // Keyed by sid; drained on session_history_end.
  const pendingLiveRef = useRef(new Map<number, ClaudeMessage[]>());

  // -- Live stdout message handler --
  // Reduces against the mutable liveStates map (synchronous), fires
  // notifications, then enqueues a Preact state update for rendering.
  const handleSessionMessage = useCallback(
    (sid: number, msg: ClaudeMessage) => {
      // If history has been requested but not yet loaded, buffer live
      // messages so they are processed after history.
      const s = liveStates.get(sid);
      if (s && !s.historyLoaded && requestedHistoryRef.current.has(sid)) {
        let buf = pendingLiveRef.current.get(sid);
        if (!buf) {
          buf = [];
          pendingLiveRef.current.set(sid, buf);
        }
        buf.push(msg);
        return;
      }

      const prev = s ?? makeSessionState(sid, true);
      const updated = reduceStdoutMessage(prev, msg);
      liveStates.set(sid, updated);
      notifyTransition(sid, prev, updated);

      setSessions((map) => {
        const next = new Map(map);
        next.set(sid, updated);
        return next;
      });
    },
    [],
  );

  // -- JSONL file message handler --
  const handleFileMessage = useCallback(
    (sid: number, msg: ClaudeFileMessage) => {
      const prev = liveStates.get(sid) ?? makeSessionState(sid);
      const updated = reduceFileMessage(prev, msg);
      liveStates.set(sid, updated);
      // File replay: seed snapshot without notifying (historical data)
      initSnapshot(sid, updated);

      setSessions((map) => {
        const next = new Map(map);
        next.set(sid, updated);
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
      case "session_created": {
        const sid = msg.sid;
        const workspace = msg.workspace || "";
        const projectPath = msg.project_path || "";
        const s = makeSessionState(
          sid,
          false,
          false,
          undefined,
          true,
          workspace,
          projectPath,
        );
        liveStates.set(sid, s);
        initSnapshot(sid, s);
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sid, s);
          return next;
        });

        // Navigate to the new session
        if (workspace && projectPath) {
          const projName = findProjectName(
            workspacesRef.current,
            workspace,
            projectPath,
          );
          if (projName) {
            const encodedProject = projName.replace(/\//g, ":");
            routeRef.current(`/${workspace}/${encodedProject}/session/${sid}`);
          } else {
            routeRef.current(`/session/${sid}`);
          }
        } else {
          routeRef.current(`/session/${sid}`);
        }

        // If we have a pending first message, send it now
        const text = pendingFirstMessage.current;
        if (text !== null) {
          pendingFirstMessage.current = null;
          const withMsg = reducePendingUserMessage(s, text);
          liveStates.set(sid, withMsg);
          setSessions((prev) => {
            const next = new Map(prev);
            next.set(sid, withMsg);
            return next;
          });
          connRef.current?.sendMessage(sid, text);
        }
        break;
      }
      case "sessions_list": {
        setSessions((prev) => {
          const next = new Map(prev);
          for (const entry of msg.sessions) {
            const workspace = entry.workspace || "";
            const projectPath = entry.project_path || "";
            if (!next.has(entry.sid)) {
              const s = makeSessionState(
                entry.sid,
                entry.alive,
                entry.resumable,
                entry.title,
                false,
                workspace,
                projectPath,
              );
              liveStates.set(entry.sid, s);
              initSnapshot(entry.sid, s);
              next.set(entry.sid, s);
            } else {
              const s = next.get(entry.sid)!;
              const updated = {
                ...s,
                alive: entry.alive,
                resumable: entry.resumable,
                title: entry.title || s.title,
                workspace: workspace || s.workspace,
                projectPath: projectPath || s.projectPath,
              };
              liveStates.set(entry.sid, updated);
              initSnapshot(entry.sid, updated);
              next.set(entry.sid, updated);
            }
          }
          return next;
        });
        // Navigate to most recently active session if on a project page without a session
        // Do NOT auto-navigate when on welcome page (/)
        const currentParsed = parseFromPath(location.pathname);
        if (
          msg.sessions.length > 0 &&
          currentParsed.sid === null &&
          currentParsed.workspace !== null
        ) {
          // On a project page — auto-select latest session for this project
        } else if (
          msg.sessions.length > 0 &&
          currentParsed.workspace === null &&
          currentParsed.sid === null &&
          location.pathname !== "/"
        ) {
          // Legacy: no path structure, not welcome page
          const latest = msg.sessions.reduce((a, b) =>
            (b.lastActivity || "") > (a.lastActivity || "") ? b : a,
          );
          routeRef.current(`/session/${latest.sid}`, true);
        }
        break;
      }
      case "session_reload": {
        const { sid } = msg;
        requestedHistoryRef.current.delete(sid);
        const s = liveStates.get(sid);
        if (!s) break;
        // Collect user message texts to detect unsaved prompts after replay
        const userTexts = s.messages
          .filter((m) => m.type === "user")
          .map((m) =>
            m.content
              .filter((b) => b.type === "text")
              .map((b) => ("text" in b ? b.text : ""))
              .join(""),
          )
          .filter((t) => t.length > 0);
        const reset = {
          ...makeSessionState(
            sid,
            false,
            s.resumable,
            s.title,
            false,
            s.workspace,
            s.projectPath,
          ),
          resumable: s.resumable,
          preReloadDrafts: userTexts.length > 0 ? userTexts : undefined,
        };
        liveStates.set(sid, reset);
        initSnapshot(sid, reset);
        setSessions((prev) => {
          if (!prev.has(sid)) return prev;
          const next = new Map(prev);
          next.set(sid, reset);
          return next;
        });
        break;
      }
      case "session_history_end": {
        const { sid } = msg;
        let s = liveStates.get(sid);
        if (!s) break;
        s = { ...s, historyLoaded: true };
        liveStates.set(sid, s);

        // Drain any live messages that were buffered while history was loading.
        // The backend uses a unified history model (JSONL + live events are
        // disjoint), so no deduplication is needed here.
        const buffered = pendingLiveRef.current.get(sid);
        if (buffered) {
          pendingLiveRef.current.delete(sid);
          for (const liveMsg of buffered) {
            const prev = liveStates.get(sid)!;
            const next = reduceStdoutMessage(prev, liveMsg);
            liveStates.set(sid, next);
            notifyTransition(sid, prev, next);
          }
          s = liveStates.get(sid)!;
        }

        setSessions((prev) => {
          if (!prev.has(sid)) return prev;
          const next = new Map(prev);
          next.set(sid, s);
          return next;
        });
        break;
      }
      case "title_update": {
        const { sid, title } = msg;
        const s = liveStates.get(sid);
        if (!s) break;
        const updated = { ...s, title };
        liveStates.set(sid, updated);
        setSessions((prev) => {
          if (!prev.has(sid)) return prev;
          const next = new Map(prev);
          next.set(sid, updated);
          return next;
        });
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
      | { kind: "session"; sid: number; msg: ClaudeMessage }
      | { kind: "file"; sid: number; msg: ClaudeFileMessage }
      | { kind: "control"; msg: ControlMessage };
    let buffer: BufferedMsg[] = [];
    let flushId: number | null = null;

    const flush = () => {
      flushId = null;
      const batch = buffer;
      buffer = [];
      for (const item of batch) {
        if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "file") handleFileMessage(item.sid, item.msg);
        else handleSessionMessage(item.sid, item.msg);
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

    let replayTimerId: ReturnType<typeof setTimeout> | null = null;

    conn.onStatusChange = (connected) => {
      setConnected(connected);
      if (connected) {
        // Suppress notifications during initial replay; mark done after
        // messages settle (debounced in onSessionMessage/onFileMessage).
        resetReplay();
      } else {
        resetReplay();
        if (replayTimerId) {
          clearTimeout(replayTimerId);
          replayTimerId = null;
        }
        liveStates.clear();
        requestedHistoryRef.current.clear();
        setSessions(new Map());
      }
    };
    const debounceReplay = () => {
      if (replayTimerId) clearTimeout(replayTimerId);
      replayTimerId = setTimeout(() => {
        markReplayDone();
        replayTimerId = null;
      }, 1000);
    };

    conn.onSessionMessage = (sid, msg) => {
      buffer.push({ kind: "session", sid, msg });
      scheduleFlush();
      debounceReplay();
    };
    conn.onFileMessage = (sid, msg) => {
      buffer.push({ kind: "file", sid, msg });
      scheduleFlush();
      debounceReplay();
    };
    conn.onControlMessage = (msg) => {
      buffer.push({ kind: "control", msg });
      scheduleFlush();
      debounceReplay();
    };
    conn.connect();
    return () => {
      cancelPendingFlush();
      if (replayTimerId) clearTimeout(replayTimerId);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      conn.disconnect();
    };
  }, [handleSessionMessage, handleFileMessage, handleControlMessage]);

  // Request history when the active session changes and hasn't been loaded yet
  useEffect(() => {
    if (!connected || activeSessionId === null) return;
    if (requestedHistoryRef.current.has(activeSessionId)) return;
    const s = liveStates.get(activeSessionId);
    if (s?.historyLoaded) return;
    requestedHistoryRef.current.add(activeSessionId);
    connRef.current?.requestHistory(activeSessionId);
  }, [connected, activeSessionId]);

  const send = useCallback(
    (text: string) => {
      if (activeSessionId === null) {
        // No active session — create one in the current project context and queue the message
        pendingFirstMessage.current = text;
        const parsed = parseFromPath(location.pathname);
        if (parsed.workspace && parsed.project) {
          // Find the absolute project path from workspaces
          const projPath = findProjectPath(
            workspacesRef.current,
            parsed.workspace,
            parsed.project,
          );
          connRef.current?.createSession(parsed.workspace, projPath || "");
        } else {
          connRef.current?.createSession();
        }
        return;
      }
      const s = liveStates.get(activeSessionId);
      if (s) {
        const updated = reducePendingUserMessage(s, text);
        liveStates.set(activeSessionId, updated);
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(activeSessionId, updated);
          return next;
        });
      }
      connRef.current?.sendMessage(activeSessionId, text);
    },
    [activeSessionId],
  );

  const interrupt = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.sendInterrupt(activeSessionId);
    }
  }, [activeSessionId]);

  const newSession = useCallback((workspace?: string, projectPath?: string) => {
    connRef.current?.createSession(workspace, projectPath);
  }, []);

  const resume = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.resumeSession(activeSessionId);
      const s = liveStates.get(activeSessionId);
      if (s) {
        const updated = { ...s, alive: true, resumable: false };
        liveStates.set(activeSessionId, updated);
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(activeSessionId, updated);
          return next;
        });
      }
    }
  }, [activeSessionId]);

  // Build sidebar session list filtered by active workspace/project and sorted by sid
  const sidebarSessions = useMemo(() => {
    let filtered = Array.from(sessions.values());
    if (activeWorkspace !== null && activeProject !== null) {
      filtered = filtered.filter((s) => {
        if (!s.workspace || !s.projectPath) return false;
        const projName = findProjectName(
          workspaces,
          s.workspace,
          s.projectPath,
        );
        return s.workspace === activeWorkspace && projName === activeProject;
      });
    }
    return filtered
      .sort((a, b) => b.sid - a.sid)
      .map((s) => ({
        sid: s.sid,
        alive: s.alive,
        resumable: s.resumable,
        isProcessing: s.isProcessing,
        title: s.title,
      }));
  }, [sessions, activeWorkspace, activeProject, workspaces]);

  return {
    sessions,
    activeSessionId,
    setActiveSessionId,
    connected,
    send,
    interrupt,
    newSession,
    resume,
    sidebarSessions,
    workspaces,
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
