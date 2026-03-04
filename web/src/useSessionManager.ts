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
    title?: string;
  }>;
}

function parseSidFromPath(path: string): number | null {
  const m = path.match(/^\/session\/(\d+)$/);
  return m ? Number(m[1]) : null;
}

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

  const updateSession = useCallback(
    (sid: number, updater: (s: SessionState) => SessionState) => {
      setSessions((prev) => {
        const s = prev.get(sid);
        if (!s) return prev;
        const next = new Map(prev);
        next.set(sid, updater(s));
        return next;
      });
    },
    [],
  );

  // -- Live stdout message handler --
  // Ensures session exists, then delegates to the pure reducer.
  const handleSessionMessage = useCallback(
    (sid: number, msg: ClaudeMessage) => {
      setSessions((prev) => {
        const s = prev.get(sid) ?? makeSessionState(sid, true);
        const next = new Map(prev);
        next.set(sid, reduceStdoutMessage(s, msg));
        return next;
      });
    },
    [],
  );

  // -- JSONL file message handler --
  const handleFileMessage = useCallback(
    (sid: number, msg: ClaudeFileMessage) => {
      setSessions((prev) => {
        const s = prev.get(sid) ?? makeSessionState(sid);
        const next = new Map(prev);
        next.set(sid, reduceFileMessage(s, msg));
        return next;
      });
    },
    [],
  );

  const handleControlMessage = useCallback((msg: ControlMessage) => {
    switch (msg.type) {
      case "session_created": {
        const sid = msg.sid;
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sid, makeSessionState(sid, false));
          return next;
        });
        routeRef.current(`/session/${sid}`);

        // If we have a pending first message, send it now
        const text = pendingFirstMessage.current;
        if (text !== null) {
          pendingFirstMessage.current = null;
          updateSession(sid, (s) => reducePendingUserMessage(s, text));
          connRef.current?.sendMessage(sid, text);
        }
        break;
      }
      case "sessions_list": {
        setSessions((prev) => {
          const next = new Map(prev);
          for (const entry of msg.sessions) {
            if (!next.has(entry.sid)) {
              next.set(
                entry.sid,
                makeSessionState(
                  entry.sid,
                  entry.alive,
                  entry.resumable,
                  entry.title,
                ),
              );
            } else {
              const s = next.get(entry.sid)!;
              next.set(entry.sid, {
                ...s,
                alive: entry.alive,
                resumable: entry.resumable,
                title: entry.title || s.title,
              });
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
      case "title_update": {
        const { sid, title } = msg;
        setSessions((prev) => {
          const s = prev.get(sid);
          if (!s) return prev;
          const next = new Map(prev);
          next.set(sid, { ...s, title });
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
    let rafId: number | null = null;

    const flush = () => {
      rafId = null;
      const batch = buffer;
      buffer = [];
      for (const item of batch) {
        if (item.kind === "control") handleControlMessage(item.msg);
        else if (item.kind === "file") handleFileMessage(item.sid, item.msg);
        else handleSessionMessage(item.sid, item.msg);
      }
    };

    conn.onStatusChange = (connected) => {
      setConnected(connected);
      if (!connected) {
        setSessions(new Map());
      }
    };
    conn.onSessionMessage = (sid, msg) => {
      buffer.push({ kind: "session", sid, msg });
      if (rafId === null) rafId = requestAnimationFrame(flush);
    };
    conn.onFileMessage = (sid, msg) => {
      buffer.push({ kind: "file", sid, msg });
      if (rafId === null) rafId = requestAnimationFrame(flush);
    };
    conn.onControlMessage = (msg) => {
      buffer.push({ kind: "control", msg });
      if (rafId === null) rafId = requestAnimationFrame(flush);
    };
    conn.connect();
    return () => {
      if (rafId !== null) cancelAnimationFrame(rafId);
      conn.disconnect();
    };
  }, [handleSessionMessage, handleFileMessage, handleControlMessage]);

  const send = useCallback(
    (text: string) => {
      if (activeSessionId === null) {
        // No sessions — create one and queue the message
        pendingFirstMessage.current = text;
        connRef.current?.createSession();
        return;
      }
      updateSession(activeSessionId, (s) => reducePendingUserMessage(s, text));
      connRef.current?.sendMessage(activeSessionId, text);
    },
    [activeSessionId, updateSession],
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
      updateSession(activeSessionId, (s) => ({
        ...s,
        alive: true,
        resumable: false,
      }));
    }
  }, [activeSessionId, updateSession]);

  // Build sidebar session list sorted by sid
  const sidebarSessions = Array.from(sessions.values())
    .sort((a, b) => b.sid - a.sid)
    .map((s) => ({
      sid: s.sid,
      alive: s.alive,
      resumable: s.resumable,
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
