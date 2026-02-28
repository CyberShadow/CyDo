import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { Connection } from "./connection";
import type {
  ClaudeMessage,
  AssistantMessage,
  AssistantContentBlock,
  StreamEvent,
} from "./protocol";
import { SystemBanner } from "./components/SystemBanner";
import { MessageList } from "./components/MessageList";
import { InputBox } from "./components/InputBox";

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

export function App() {
  const [connected, setConnected] = useState(false);
  const [messages, setMessages] = useState<DisplayMessage[]>([]);
  const [streamingBlocks, setStreamingBlocks] = useState<StreamingBlock[]>([]);
  const [sessionInfo, setSessionInfo] = useState<SessionInfo | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);
  const [totalCost, setTotalCost] = useState(0);
  const connRef = useRef<Connection | null>(null);
  const msgIdCounter = useRef(0);

  const handleMessage = useCallback((msg: ClaudeMessage) => {
    switch (msg.type) {
      case "system":
        if ("subtype" in msg && msg.subtype === "init") {
          setSessionInfo({
            model: msg.model,
            version: msg.claude_code_version,
            sessionId: msg.session_id,
          });
          setIsProcessing(true);
          setStreamingBlocks([]);
        }
        break;

      case "assistant":
        handleAssistantMessage(msg as AssistantMessage);
        break;

      case "user":
        if ("isReplay" in msg && (msg as any).isReplay) {
          // Echoed user input — remove pending and reinsert as confirmed at end
          const content = (msg as any).message?.content;
          const text = typeof content === "string" ? content : "";
          setMessages((prev) => {
            const filtered = prev.filter((m) => !(m.pending && m.type === "user"));
            const id = `user-${++msgIdCounter.current}`;
            return [...filtered, { id, type: "user" as const, content: [{ type: "text" as const, text }] }];
          });
        } else if ("message" in msg && msg.message) {
          // Tool results from --verbose
          handleUserEcho(msg);
        }
        break;

      case "stream_event":
        if ("event" in msg) {
          handleStreamEvent(msg.event);
        }
        break;

      case "result":
        if ("total_cost_usd" in msg) {
          setTotalCost(msg.total_cost_usd);
        }
        setIsProcessing(false);
        setStreamingBlocks([]);
        break;

      case "exit":
        setIsProcessing(false);
        setStreamingBlocks([]);
        break;

      case "stderr": {
        const id = `stderr-${++msgIdCounter.current}`;
        setMessages((prev) => [
          ...prev,
          { id, type: "system" as const, content: [{ type: "text" as const, text: msg.text }] },
        ]);
        break;
      }

    }
  }, []);

  const handleAssistantMessage = useCallback((msg: AssistantMessage) => {
    const msgId = msg.message.id;
    setMessages((prev) => {
      const existing = prev.findIndex((m) => m.id === msgId);
      if (existing >= 0) {
        // Merge content blocks into existing message
        const updated = [...prev];
        const existingMsg = { ...updated[existing] };
        existingMsg.content = [...existingMsg.content, ...msg.message.content];
        updated[existing] = existingMsg;
        return updated;
      }
      // New assistant message
      return [
        ...prev,
        {
          id: msgId,
          type: "assistant" as const,
          content: [...msg.message.content],
          toolResults: new Map(),
          model: msg.message.model,
        },
      ];
    });
    // Clear streaming block that corresponds to completed content
    setStreamingBlocks([]);
  }, []);

  const handleUserEcho = useCallback((msg: any) => {
    const content = msg.message?.content;
    if (!content) return;

    for (const block of content) {
      if (block.type === "tool_result") {
        // Attach tool result to the most recent assistant message
        setMessages((prev) => {
          const updated = [...prev];
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
                return updated;
              }
            }
          }
          return prev;
        });
      }
    }
  }, []);

  const handleStreamEvent = useCallback((event: StreamEvent) => {
    switch (event.type) {
      case "content_block_start":
        setStreamingBlocks((prev) => [
          ...prev,
          { index: event.index, type: event.content_block.type, text: "" },
        ]);
        break;
      case "content_block_delta":
        setStreamingBlocks((prev) =>
          prev.map((b) => {
            if (b.index !== event.index) return b;
            const delta = event.delta;
            let append = "";
            if (delta.type === "text_delta") append = delta.text;
            else if (delta.type === "thinking_delta") append = delta.thinking;
            else if (delta.type === "input_json_delta") append = delta.partial_json;
            return { ...b, text: b.text + append };
          })
        );
        break;
      case "content_block_stop":
        setStreamingBlocks((prev) => prev.filter((b) => b.index !== event.index));
        break;
    }
  }, []);

  useEffect(() => {
    const conn = new Connection();
    connRef.current = conn;
    conn.onStatusChange = setConnected;
    conn.onMessage = handleMessage;
    conn.connect();
    return () => conn.disconnect();
  }, [handleMessage]);

  const handleSend = useCallback(
    (text: string) => {
      const id = `pending-${++msgIdCounter.current}`;
      setMessages((prev) => [
        ...prev,
        { id, type: "user" as const, content: [{ type: "text" as const, text }], pending: true },
      ]);
      connRef.current?.sendMessage(text);
    },
    []
  );

  const handleInterrupt = useCallback(() => {
    connRef.current?.sendInterrupt();
  }, []);

  return (
    <div class="app">
      <SystemBanner
        sessionInfo={sessionInfo}
        connected={connected}
        totalCost={totalCost}
        isProcessing={isProcessing}
      />
      <MessageList
        messages={messages}
        streamingBlocks={streamingBlocks}
        isProcessing={isProcessing}
      />
      <InputBox
        onSend={handleSend}
        onInterrupt={handleInterrupt}
        isProcessing={isProcessing}
        disabled={!connected}
      />
    </div>
  );
}
