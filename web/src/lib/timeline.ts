import type { DisplayMessage } from "../types";

export function partitionTimeline(messages: DisplayMessage[]) {
  const topLevelMessages: DisplayMessage[] = [];
  const childrenByParent = new Map<string, DisplayMessage[]>();
  for (const message of messages) {
    if (!message.parentToolUseId) {
      topLevelMessages.push(message);
      continue;
    }
    const children = childrenByParent.get(message.parentToolUseId);
    if (children) children.push(message);
    else childrenByParent.set(message.parentToolUseId, [message]);
  }
  return { topLevelMessages, childrenByParent };
}
