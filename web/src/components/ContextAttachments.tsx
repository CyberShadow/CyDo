import { createContext } from "preact";
import { useContext, useState } from "preact/hooks";
import type { ContextAttachment, DisplayMessage } from "../types";

/** attachment categories the config hides (ui.context.hidden_categories);
 *  applied at render time, so a config reload takes effect without replaying
 *  any history */
export const HiddenContextCategoriesContext = createContext<readonly string[]>(
  [],
);

function firstLine(text: string): string {
  const line = text.trimStart().split("\n", 1)[0] ?? "";
  return line.length > 120 ? `${line.slice(0, 120)}…` : line;
}

/** a body that is one pretty-printed JSON object or array: its opening and
 *  closing lines, and the lines between them */
function bracketed(
  text: string,
): { open: string; close: string; inner: string } | null {
  const lines = text.trim().split("\n");
  if (lines.length < 2) return null;
  const first = lines[0]!;
  const last = lines[lines.length - 1]!;
  if (!((first === "{" && last === "}") || (first === "[" && last === "]")))
    return null;
  return { open: first, close: last, inner: lines.slice(1, -1).join("\n") };
}

/** one record, collapsed to its category and first line; the body renders
 *  only while open, since some (CLAUDE.md loads, the system prompt snapshot)
 *  run to hundreds of kilobytes */
function ContextAttachmentItem({
  attachment,
}: {
  attachment: ContextAttachment;
}) {
  const [open, setOpen] = useState(false);
  const preview = firstLine(attachment.text);
  // a JSON body shows as `{ … }` while closed, and opens to its opening
  // bracket, the lines inside it, then its closing bracket on its own line
  const block = bracketed(attachment.text);
  return (
    <details
      class="context-attachment"
      data-category={attachment.category}
      data-uuid={attachment.uuid}
      onToggle={(e) => {
        setOpen(e.currentTarget.open);
      }}
    >
      {/* out of the tab order, like the thinking blocks: a message's undo
          and fork buttons sit on either side of it and stay adjacent */}
      <summary class="context-attachment-summary" tabIndex={-1}>
        <span class="context-attachment-category">{attachment.category}</span>
        {block ? (
          <span class="context-attachment-preview context-attachment-bracket">
            {block.open}
            {!open && (
              <>
                <span class="context-attachment-ellipsis">…</span>
                {block.close}
              </>
            )}
          </span>
        ) : (
          preview && <span class="context-attachment-preview">{preview}</span>
        )}
      </summary>
      {open && (
        <div class="context-attachment-body">
          {block ? (
            <pre class="context-attachment-text">{block.inner}</pre>
          ) : (
            attachment.text && (
              <pre class="context-attachment-text">{attachment.text}</pre>
            )
          )}
          {attachment.extras && Object.keys(attachment.extras).length > 0 && (
            <pre class="context-attachment-extras">
              {JSON.stringify(attachment.extras, null, 2)}
            </pre>
          )}
        </div>
      )}
      {open && block && (
        <div class="context-attachment-close">{block.close}</div>
      )}
    </details>
  );
}

/** the attachments on a message, in arrival order, minus hidden categories */
export function ContextAttachments({
  attachments,
}: {
  attachments: readonly ContextAttachment[] | undefined;
}) {
  const hidden = useContext(HiddenContextCategoriesContext);
  const shown = (attachments ?? []).filter((a) => !hidden.includes(a.category));
  if (shown.length === 0) return null;
  return (
    <div class="context-attachments">
      {shown.map((a) => (
        <ContextAttachmentItem key={a.uuid} attachment={a} />
      ))}
    </div>
  );
}

/** a run of context that arrived mid-turn, as a synthetic block */
export function ContextMessage({ message }: { message: DisplayMessage }) {
  const hidden = useContext(HiddenContextCategoriesContext);
  if (
    !(message.contextAttachments ?? []).some(
      (a) => !hidden.includes(a.category),
    )
  )
    return null;
  return (
    <div class="message context-message synthetic-message">
      <div class="message-meta">
        <span class="meta-badge synthetic">synthetic</span>
      </div>
      <ContextAttachments attachments={message.contextAttachments} />
    </div>
  );
}
