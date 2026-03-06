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

export interface SessionManager {
  sessions: Map<number, SessionState>;
  activeSessionId: number | null;
  setActiveSessionId: (sid: number) => void;
  connected: boolean;
  send: (text: string) => void;
  interrupt: () => void;
  newSession: () => void;
  resume: () => void;
  sidebarSessions: Array<{
    sid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    title?: string;
  }>;
}

function parseSidFromPath(path: string): number | null {
  const m = path.match(/^\/session\/(\d+)$/);
  return m ? Number(m[1]) : null;
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
  const { path, route } = useLocation();
  const routeRef = useRef(route);
  routeRef.current = route;
  const activeSessionId = useMemo(() => parseSidFromPath(path), [path]);
  const setActiveSessionId = useCallback(
    (sid: number) => routeRef.current(`/session/${sid}`),
    [],
  );

  const connRef = useRef<Connection | null>(null);
  // When we create a session and want to send a message once it's confirmed
  const pendingFirstMessage = useRef<string | null>(null);
  // Track which sessions have had history requested (avoid duplicate requests)
  const requestedHistoryRef = useRef(new Set<number>());

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
      case "session_created": {
        const sid = msg.sid;
        const s = makeSessionState(sid, false, false, undefined, true);
        liveStates.set(sid, s);
        initSnapshot(sid, s);
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sid, s);
          return next;
        });
        routeRef.current(`/session/${sid}`);

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
            if (!next.has(entry.sid)) {
              const s = makeSessionState(
                entry.sid,
                entry.alive,
                entry.resumable,
                entry.title,
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
              };
              liveStates.set(entry.sid, updated);
              initSnapshot(entry.sid, updated);
              next.set(entry.sid, updated);
            }
          }
          return next;
        });
        // Navigate to most recently active session if no session is selected
        if (
          msg.sessions.length > 0 &&
          parseSidFromPath(location.pathname) === null
        ) {
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
          ...makeSessionState(sid, false, s.resumable, s.title, false),
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
        // No sessions — create one and queue the message
        pendingFirstMessage.current = text;
        connRef.current?.createSession();
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

  const newSession = useCallback(() => {
    connRef.current?.createSession();
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

  // Build sidebar session list sorted by sid
  const sidebarSessions = Array.from(sessions.values())
    .sort((a, b) => b.sid - a.sid)
    .map((s) => ({
      sid: s.sid,
      alive: s.alive,
      resumable: s.resumable,
      isProcessing: s.isProcessing,
      title: s.title,
    }));

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
  };
}
