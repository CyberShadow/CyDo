import { h } from "preact";
import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";

interface Props {
  message: DisplayMessage;
}

export function UserMessage({ message }: Props) {
  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  return (
    <div
      class={`message user-message${message.pending ? " pending" : ""}${message.isMeta ? " meta-message" : ""}${message.isSteering ? " steering-message" : ""}${message.isCompactSummary ? " compact-summary-message" : ""}`}
    >
      {message.isCompactSummary && (
        <div class="message-meta">
          <span class="meta-badge compact-summary">compact summary</span>
        </div>
      )}
      {message.isMeta && (
        <div class="message-meta">
          <span class="meta-badge meta">meta</span>
        </div>
      )}
      {message.isSteering && !message.isMeta && (
        <div class="message-meta">
          <span class="meta-badge steering">steering</span>
        </div>
      )}
      {message.isSynthetic || message.parentToolUseId || message.isCompactSummary ? (
        <Markdown text={text} />
      ) : (
        <div class="user-text">{text}</div>
      )}
      {message.extraFields && Object.keys(message.extraFields).length > 0 && (
        <div class="unknown-extra-fields">
          {Object.entries(message.extraFields).map(([k, v]) => (
            <div key={k} class="tool-input-field">
              <span class="field-label">{k}:</span>
              <span class="field-value"> {typeof v === 'string' ? v : JSON.stringify(v)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
