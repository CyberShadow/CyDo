import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";
import { useDevMode } from "../devMode";

interface Props {
  message: DisplayMessage;
}

export function UserMessage({ message }: Props) {
  const devMode = useDevMode();
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

  const isMultipart = textParts.length > 1;
  const usesMarkdown =
    message.isSynthetic || message.parentToolUseId || message.isCompactSummary;

  const ackClass =
    message.ackState !== undefined ? ` ack-${message.ackState}` : "";
  const pendingClass =
    (message.ackState !== undefined && message.ackState >= 2) ||
    (!message.ackState && message.pending)
      ? " pending"
      : "";

  return (
    <div
      class={`message user-message${ackClass}${pendingClass}${
        isMultipart ? " multipart-user-message" : ""
      }${
        message.isMeta ? " meta-message" : ""
      }${message.isSteering ? " steering-message" : ""}${
        message.isCompactSummary ? " compact-summary-message" : ""
      }${message.isSynthetic ? " synthetic-message" : ""}${
        message.removed ? " removed-message" : ""
      }`}
    >
      {message.isCompactSummary && (
        <div class="message-meta">
          <span class="meta-badge compact-summary">compact summary</span>
        </div>
      )}
      {message.isMeta && (
        <div class="message-meta">
          {message.metaKinds?.length ? (
            message.metaKinds.map((kind) => (
              <span class="meta-badge meta meta-kind" key={kind}>
                {kind}
              </span>
            ))
          ) : (
            <span class="meta-badge meta">meta</span>
          )}
        </div>
      )}
      {message.isSteering && !message.isMeta && (
        <div class="message-meta">
          <span class="meta-badge steering">steering</span>
        </div>
      )}
      {message.removed && (
        <div class="message-meta">
          <span class="meta-badge removed">not delivered</span>
        </div>
      )}
      {message.isSynthetic &&
        !message.isMeta &&
        !message.isSteering &&
        !message.isCompactSummary && (
          <div class="message-meta">
            <span class="meta-badge synthetic">synthetic</span>
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
      {isMultipart ? (
        <div class="user-content-items">
          {textParts.map((text, i) => (
            <div class="user-content-item" key={i}>
              {usesMarkdown ? (
                <Markdown text={text} />
              ) : (
                <div class="user-text">{text}</div>
              )}
            </div>
          ))}
        </div>
      ) : (
        textParts[0] &&
        (usesMarkdown ? (
          <Markdown text={textParts[0]} />
        ) : (
          <div class="user-text">{textParts[0]}</div>
        ))
      )}
      {devMode &&
        message.extraFields &&
        Object.keys(message.extraFields).length > 0 && (
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
