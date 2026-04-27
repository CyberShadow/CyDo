import type { CydoMeta, DisplayMessage } from "./types";

type UserTextBlock = { type: string; text?: string };

function getBodyVarValue(cydoMeta?: CydoMeta): string | undefined {
  const bodyVar = cydoMeta?.bodyVar;
  if (!bodyVar) return undefined;
  const bodyValue = cydoMeta.vars?.[bodyVar];
  if (typeof bodyValue === "string" && bodyValue.length > 0) return bodyValue;
  return undefined;
}

export function canonicalUserTextFromContentAndMeta(
  content: UserTextBlock[] | undefined,
  cydoMeta?: CydoMeta,
): string {
  const bodyVarValue = getBodyVarValue(cydoMeta);
  if (bodyVarValue !== undefined) return bodyVarValue;
  if (!content || content.length === 0) return "";
  return content
    .filter(
      (block): block is { type: string; text: string } =>
        block.type === "text" && typeof block.text === "string",
    )
    .map((block) => block.text)
    .join("");
}

export function canonicalUserTextFromDisplayMessage(
  message: DisplayMessage,
): string {
  return canonicalUserTextFromContentAndMeta(message.content, message.cydoMeta);
}
