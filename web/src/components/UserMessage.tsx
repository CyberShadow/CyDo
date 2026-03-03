import { h } from "preact";
import type { DisplayMessage } from "../types";
import { ExtraFields } from "./ExtraFields";

interface Props {
  message: DisplayMessage;
}

export function UserMessage({ message }: Props) {
  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  return (
    <div class={`message user-message${message.pending ? " pending" : ""}`}>
      <div class="user-text">{text}</div>
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}
