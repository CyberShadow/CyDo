import { h } from "preact";
import { useEffect, useRef } from "preact/hooks";
import type { DisplayMessage, StreamingBlock } from "../app";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { Markdown } from "./Markdown";

interface Props {
  messages: DisplayMessage[];
  streamingBlocks: StreamingBlock[];
  isProcessing: boolean;
}

export function MessageList({ messages, streamingBlocks, isProcessing }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const shouldAutoScroll = useRef(true);

  // Track if user has scrolled up
  const handleScroll = () => {
    const el = containerRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
    shouldAutoScroll.current = atBottom;
  };

  // Auto-scroll on new content
  useEffect(() => {
    if (shouldAutoScroll.current && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [messages, streamingBlocks]);

  return (
    <div class="message-list" ref={containerRef} onScroll={handleScroll}>
      {messages.map((msg) => {
        if (msg.type === "user") {
          return <UserMessage key={msg.id} message={msg} />;
        }
        if (msg.type === "system") {
          const text = msg.content
            .filter((b): b is { type: "text"; text: string } => b.type === "text")
            .map((b) => b.text)
            .join("\n");
          return (
            <div key={msg.id} class="message system-message">
              <pre>{text}</pre>
            </div>
          );
        }
        return <AssistantMessage key={msg.id} message={msg} />;
      })}
      {streamingBlocks.length > 0 && (
        <div class="message assistant-message streaming">
          {streamingBlocks.map((block) => (
            <div key={block.index} class={`content-block ${block.type}`}>
              {block.type === "thinking" && (
                <details open>
                  <summary>Thinking...</summary>
                  <Markdown text={block.text} class="thinking-text" />
                </details>
              )}
              {block.type === "text" && (
                <div class="text-content streaming-text">
                  <Markdown text={block.text} />
                  <span class="cursor" />
                </div>
              )}
              {block.type === "tool_use" && (
                <div class="tool-streaming">
                  <span class="tool-label">Tool call building...</span>
                  <pre>{block.text}</pre>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
