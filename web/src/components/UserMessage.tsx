import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";

interface Props {
  message: DisplayMessage;
}

export function UserMessage({ message }: Props) {
  const textParts: string[] = [];
  const imageBlocks: Array<{ data: string; media_type: string }> = [];

  for (const block of message.content) {
    if (block.type === "text" && typeof block.text === "string") {
      textParts.push(block.text);
    } else if (
      block.type === "image" &&
      typeof (block as Record<string, unknown>).data === "string"
    ) {
      imageBlocks.push(
        block as unknown as { data: string; media_type: string },
      );
    }
  }

  const text = textParts.join("\n");

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
      {imageBlocks.length > 0 && (
        <div class="user-images">
          {imageBlocks.map((img, i) => (
            <img
              key={i}
              src={`data:${img.media_type};base64,${img.data}`}
              alt="User attached image"
              class="user-image"
            />
          ))}
        </div>
      )}
      {text &&
        (message.isSynthetic ||
        message.parentToolUseId ||
        message.isCompactSummary ? (
          <Markdown text={text} />
        ) : (
          <div class="user-text">{text}</div>
        ))}
      {message.extraFields && Object.keys(message.extraFields).length > 0 && (
        <div class="unknown-extra-fields">
          {Object.entries(message.extraFields).map(([k, v]) => (
            <div key={k} class="tool-input-field">
              <span class="field-label">{k}:</span>
              <span class="field-value">
                {" "}
                {typeof v === "string" ? v : JSON.stringify(v)}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
