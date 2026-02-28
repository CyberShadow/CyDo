import { h } from "preact";
import type { DisplayMessage } from "../app";

interface Props {
  message: DisplayMessage;
}

export function UserMessage({ message }: Props) {
  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  return (
    <div class="message user-message">
      <div class="user-text">{text}</div>
    </div>
  );
}
