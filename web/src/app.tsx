import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { Connection } from "./connection";
import type {
  ClaudeMessage,
  AssistantMessage,
  AssistantContentBlock,
  StreamEvent,
  ControlMessage,
} from "./protocol";
import { SystemBanner } from "./components/SystemBanner";
import { MessageList } from "./components/MessageList";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";

// Display types for the UI
export interface DisplayMessage {
  id: string;
  type: "user" | "assistant" | "tool_result" | "system";
  content: AssistantContentBlock[];
  toolResults?: Map<string, ToolResult>;
  model?: string;
  pending?: boolean;
}

export interface ToolResult {
  toolUseId: string;
  content: string;
  isError?: boolean;
}

export interface StreamingBlock {
  index: number;
  type: string;
  text: string;
}

export interface SessionInfo {
  model: string;
  version: string;
  sessionId: string;
}

interface SessionState {
  sid: number;
  messages: DisplayMessage[];
  streamingBlocks: StreamingBlock[];
  sessionInfo: SessionInfo | null;
  isProcessing: boolean;
  totalCost: number;
  alive: boolean;
  msgIdCounter: number;
}

function makeSessionState(sid: number, alive: boolean = false): SessionState {
  return {
    sid,
    messages: [],
    streamingBlocks: [],
    sessionInfo: null,
    isProcessing: false,
    totalCost: 0,
    alive,
    msgIdCounter: 0,
  };
}

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

  const handleSessionMessage = useCallback((sid: number, msg: ClaudeMessage) => {
    // Ensure session exists in our map (might arrive before sessions_list on replay)
    setSessions((prev) => {
      if (!prev.has(sid)) {
        const next = new Map(prev);
        next.set(sid, makeSessionState(sid, true));
        return next;
      }
      return prev;
    });

    switch (msg.type) {
      case "system":
        if ("subtype" in msg && msg.subtype === "init") {
          updateSession(sid, (s) => ({
            ...s,
            sessionInfo: {
              model: msg.model,
              version: msg.claude_code_version,
              sessionId: msg.session_id,
            },
            isProcessing: true,
            streamingBlocks: [],
          }));
        }
        break;

      case "assistant":
        handleAssistantMessage(sid, msg as AssistantMessage);
        break;

      case "user":
        if ("isReplay" in msg && (msg as any).isReplay) {
          const content = (msg as any).message?.content;
          const text = typeof content === "string" ? content : "";
          updateSession(sid, (s) => {
            const filtered = s.messages.filter((m) => !(m.pending && m.type === "user"));
            const id = `user-${++s.msgIdCounter}`;
            return {
              ...s,
              messages: [...filtered, { id, type: "user" as const, content: [{ type: "text" as const, text }] }],
            };
          });
        } else if ("message" in msg && msg.message) {
          handleUserEcho(sid, msg);
        }
        break;

      case "stream_event":
        if ("event" in msg) {
          handleStreamEvent(sid, msg.event);
        }
        break;

      case "result":
        if ("total_cost_usd" in msg) {
          updateSession(sid, (s) => ({
            ...s,
            totalCost: msg.total_cost_usd,
            isProcessing: false,
            streamingBlocks: [],
          }));
        } else {
          updateSession(sid, (s) => ({ ...s, isProcessing: false, streamingBlocks: [] }));
        }
        break;

      case "exit":
        updateSession(sid, (s) => ({ ...s, isProcessing: false, streamingBlocks: [], alive: false }));
        break;

      case "stderr": {
        updateSession(sid, (s) => {
          const id = `stderr-${++s.msgIdCounter}`;
          return {
            ...s,
            messages: [
              ...s.messages,
              { id, type: "system" as const, content: [{ type: "text" as const, text: msg.text }] },
            ],
          };
        });
        break;
      }
    }
  }, [updateSession]);

  const handleAssistantMessage = useCallback((sid: number, msg: AssistantMessage) => {
    const msgId = msg.message.id;
    updateSession(sid, (s) => {
      const existing = s.messages.findIndex((m) => m.id === msgId);
      if (existing >= 0) {
        const updated = [...s.messages];
        const existingMsg = { ...updated[existing] };
        existingMsg.content = [...existingMsg.content, ...msg.message.content];
        updated[existing] = existingMsg;
        return { ...s, messages: updated, streamingBlocks: [] };
      }
      return {
        ...s,
        messages: [
          ...s.messages,
          {
            id: msgId,
            type: "assistant" as const,
            content: [...msg.message.content],
            toolResults: new Map(),
            model: msg.message.model,
          },
        ],
        streamingBlocks: [],
      };
    });
  }, [updateSession]);

  const handleUserEcho = useCallback((sid: number, msg: any) => {
    const content = msg.message?.content;
    if (!content) return;

    for (const block of content) {
      if (block.type === "tool_result") {
        updateSession(sid, (s) => {
          const updated = [...s.messages];
          for (let i = updated.length - 1; i >= 0; i--) {
            const m = updated[i];
            if (m.type === "assistant") {
              const hasToolUse = m.content.some(
                (c) => c.type === "tool_use" && (c as any).id === block.tool_use_id
              );
              if (hasToolUse) {
                const newMsg = { ...m, toolResults: new Map(m.toolResults) };
                newMsg.toolResults!.set(block.tool_use_id, {
                  toolUseId: block.tool_use_id,
                  content: block.content,
                  isError: block.is_error,
                });
                updated[i] = newMsg;
                return { ...s, messages: updated };
              }
            }
          }
          return s;
        });
      }
    }
  }, [updateSession]);

  const handleStreamEvent = useCallback((sid: number, event: StreamEvent) => {
    switch (event.type) {
      case "content_block_start":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: [
            ...s.streamingBlocks,
            { index: event.index, type: event.content_block.type, text: "" },
          ],
        }));
        break;
      case "content_block_delta":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: s.streamingBlocks.map((b) => {
            if (b.index !== event.index) return b;
            const delta = event.delta;
            let append = "";
            if (delta.type === "text_delta") append = delta.text;
            else if (delta.type === "thinking_delta") append = delta.thinking;
            else if (delta.type === "input_json_delta") append = delta.partial_json;
            return { ...b, text: b.text + append };
          }),
        }));
        break;
      case "content_block_stop":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: s.streamingBlocks.filter((b) => b.index !== event.index),
        }));
        break;
    }
  }, [updateSession]);

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
          // Add pending user message to session state
          setSessions((prev) => {
            const next = new Map(prev);
            const s = next.get(sid);
            if (s) {
              const id = `pending-${++s.msgIdCounter}`;
              next.set(sid, {
                ...s,
                messages: [...s.messages, { id, type: "user" as const, content: [{ type: "text" as const, text }], pending: true }],
              });
            }
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
              next.set(entry.sid, makeSessionState(entry.sid, entry.alive));
            } else {
              const s = next.get(entry.sid)!;
              next.set(entry.sid, { ...s, alive: entry.alive });
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
    conn.onStatusChange = (connected) => {
      setConnected(connected);
      if (!connected) {
        // Clear state on disconnect — will be replayed on reconnect
        setSessions(new Map());
        setActiveSessionId(null);
      }
    };
    conn.onSessionMessage = handleSessionMessage;
    conn.onControlMessage = handleControlMessage;
    conn.connect();
    return () => conn.disconnect();
  }, [handleSessionMessage, handleControlMessage]);

  const handleSend = useCallback(
    (text: string) => {
      if (activeSessionId === null) {
        // No sessions — create one and queue the message
        pendingFirstMessage.current = text;
        connRef.current?.createSession();
        return;
      }
      updateSession(activeSessionId, (s) => {
        const id = `pending-${++s.msgIdCounter}`;
        return {
          ...s,
          messages: [...s.messages, { id, type: "user" as const, content: [{ type: "text" as const, text }], pending: true }],
        };
      });
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

  const active = activeSessionId !== null ? sessions.get(activeSessionId) ?? null : null;
  const hasSessions = sessions.size > 0;

  // Build sidebar session list sorted by sid
  const sidebarSessions = Array.from(sessions.values())
    .sort((a, b) => a.sid - b.sid)
    .map((s) => ({ sid: s.sid, alive: s.alive, totalCost: s.totalCost }));

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
      <InputBox
        onSend={handleSend}
        onInterrupt={handleInterrupt}
        isProcessing={active?.isProcessing ?? false}
        disabled={!connected}
      />
    </div>
  );
}
