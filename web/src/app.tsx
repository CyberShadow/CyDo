import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { Connection } from "./connection";
import type {
  ClaudeMessage,
  ClaudeFileMessage,
  ControlMessage,
} from "./schemas";
import { SystemBanner } from "./components/SystemBanner";
import { MessageList } from "./components/MessageList";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";
import type { SessionState } from "./types";
import { makeSessionState } from "./types";
import { reduceStdoutMessage, reduceFileMessage, reducePendingUserMessage } from "./sessionReducer";

export function App() {
  const [connected, setConnected] = useState(false);
  const [sessions, setSessions] = useState<Map<number, SessionState>>(new Map());
  const [activeSessionId, setActiveSessionId] = useState<number | null>(null);
  const connRef = useRef<Connection | null>(null);
  // When we create a session and want to send a message once it's confirmed
  const pendingFirstMessage = useRef<string | null>(null);

  const updateSession = useCallback((sid: number, updater: (s: SessionState) => SessionState) => {
    setSessions((prev) => {
      const s = prev.get(sid);
      if (!s) return prev;
      const next = new Map(prev);
      next.set(sid, updater(s));
      return next;
    });
  }, []);

  // -- Live stdout message handler --
  // Ensures session exists, then delegates to the pure reducer.
  const handleSessionMessage = useCallback((sid: number, msg: ClaudeMessage) => {
    setSessions((prev) => {
      const s = prev.get(sid) ?? makeSessionState(sid, true);
      const next = new Map(prev);
      next.set(sid, reduceStdoutMessage(s, msg));
      return next;
    });
  }, []);

  // -- JSONL file message handler --
  const handleFileMessage = useCallback((sid: number, msg: ClaudeFileMessage) => {
    setSessions((prev) => {
      const s = prev.get(sid) ?? makeSessionState(sid);
      const next = new Map(prev);
      next.set(sid, reduceFileMessage(s, msg));
      return next;
    });
  }, []);

  const handleControlMessage = useCallback((msg: ControlMessage) => {
    switch (msg.type) {
      case "session_created": {
        const sid = msg.sid;
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sid, makeSessionState(sid, false));
          return next;
        });
        setActiveSessionId(sid);

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
              next.set(entry.sid, makeSessionState(entry.sid, entry.alive, entry.resumable));
            } else {
              const s = next.get(entry.sid)!;
              next.set(entry.sid, { ...s, alive: entry.alive, resumable: entry.resumable });
            }
          }
          return next;
        });
        // Set active to first session if we don't have one
        if (msg.sessions.length > 0) {
          setActiveSessionId((prev) => prev ?? msg.sessions[0].sid);
        }
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
        setActiveSessionId(null);
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

  const handleSend = useCallback(
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
    [activeSessionId, updateSession]
  );

  const handleInterrupt = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.sendInterrupt(activeSessionId);
    }
  }, [activeSessionId]);

  const handleNewSession = useCallback(() => {
    connRef.current?.createSession();
  }, []);

  const handleResume = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.resumeSession(activeSessionId);
      updateSession(activeSessionId, (s) => ({ ...s, alive: true, resumable: false }));
    }
  }, [activeSessionId, updateSession]);

  const active = activeSessionId !== null ? sessions.get(activeSessionId) ?? null : null;
  const hasSessions = sessions.size > 0;

  // Build sidebar session list sorted by sid
  const sidebarSessions = Array.from(sessions.values())
    .sort((a, b) => a.sid - b.sid)
    .map((s) => ({ sid: s.sid, alive: s.alive, resumable: s.resumable, totalCost: s.totalCost }));

  if (!hasSessions) {
    // Welcome screen — no sessions yet
    return (
      <div class="app welcome">
        <div class="welcome-box">
          <h1 class="welcome-title">CyDo</h1>
          <p class="welcome-subtitle">Multi-agent orchestration system</p>
          <InputBox
            onSend={handleSend}
            onInterrupt={handleInterrupt}
            isProcessing={false}
            disabled={!connected}
          />
        </div>
      </div>
    );
  }

  return (
    <div class="app has-sidebar">
      <Sidebar
        sessions={sidebarSessions}
        activeSessionId={activeSessionId}
        onSelectSession={setActiveSessionId}
        onNewSession={handleNewSession}
      />
      <SystemBanner
        sessionInfo={active?.sessionInfo ?? null}
        connected={connected}
        totalCost={active?.totalCost ?? 0}
        isProcessing={active?.isProcessing ?? false}
      />
      <MessageList
        messages={active?.messages ?? []}
        streamingBlocks={active?.streamingBlocks ?? []}
        isProcessing={active?.isProcessing ?? false}
      />
      {active?.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={handleResume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={handleSend}
          onInterrupt={handleInterrupt}
          isProcessing={active?.isProcessing ?? false}
          disabled={!connected}
        />
      )}
    </div>
  );
}
