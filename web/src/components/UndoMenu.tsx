import type { RefObject } from "preact";
import { useLayoutEffect, useRef } from "preact/hooks";
import type { UndoPending } from "../types";
import { PathDisplay } from "./PathDisplay";

export type UndoSelection = (
  revertConversation: boolean,
  revertFiles: boolean,
) => void;

export function UndoMenu({
  pending,
  buttonRef,
  onSelect,
  onDismiss,
}: {
  pending: UndoPending;
  buttonRef: RefObject<HTMLButtonElement>;
  onSelect: UndoSelection;
  onDismiss: () => void;
}) {
  const menuRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const menu = menuRef.current!;
    const list = menu.closest(".message-list");
    if (!list)
      throw new Error("UndoMenu must be mounted inside a message list");
    const row = menu.parentElement!;
    const button = buttonRef.current!;
    let frame: number | undefined;

    const place = () => {
      frame = undefined;
      const listRect = list.getBoundingClientRect();
      const rowRect = row.getBoundingClientRect();
      const top = Math.max(0, listRect.top + list.clientTop);
      const bottom = Math.min(
        window.innerHeight,
        listRect.top + list.clientTop + list.clientHeight,
      );
      if (rowRect.top < top || rowRect.bottom > bottom) {
        if (menu.contains(document.activeElement))
          button.focus({ preventScroll: true });
        onDismiss();
        return false;
      }

      const up = rowRect.top - top;
      const down = bottom - rowRect.bottom;
      const needed = menu.scrollHeight + menu.offsetHeight - menu.clientHeight;
      const opensDown = needed <= down || down >= up;
      menu.classList.toggle("undo-menu-up", !opensDown);
      menu.style.maxHeight = `${opensDown ? down : up}px`;
      menu.style.setProperty(
        "--undo-menu-width",
        `${rowRect.right - Math.max(0, listRect.left + list.clientLeft)}px`,
      );
      frame = requestAnimationFrame(place);
      return true;
    };

    button.scrollIntoView({ block: "nearest" });
    if (place()) menu.focus({ preventScroll: true });
    return () => {
      if (frame !== undefined) cancelAnimationFrame(frame);
    };
  }, [buttonRef, onDismiss]);

  useLayoutEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        buttonRef.current?.focus({ preventScroll: true });
        onDismiss();
      }
    };
    const onClick = (event: MouseEvent) => {
      const target = event.target as Node;
      if (
        !menuRef.current?.contains(target) &&
        !buttonRef.current?.contains(target)
      ) {
        onDismiss();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("click", onClick, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("click", onClick, true);
    };
  }, [buttonRef, onDismiss]);

  return (
    <div
      class="undo-menu"
      role="menu"
      aria-label="Undo"
      tabIndex={-1}
      ref={menuRef}
    >
      <div class="undo-menu-content">
        <div class="undo-menu-header">
          {pending.retainsPrompt
            ? "Remove this response and later history?"
            : "Remove this message and later history?"}
        </div>
        {pending.kind === "requesting" ? (
          <div class="undo-menu-loading">Loading…</div>
        ) : (
          <>
            {pending.messagesRemoved > 0 && (
              <div class="undo-menu-count">
                {pending.messagesRemoved}{" "}
                {pending.kind === "codex_turns" ? "whole turn" : "message"}
                {pending.messagesRemoved !== 1 ? "s" : ""} will be removed.
              </div>
            )}
            <button
              type="button"
              role="menuitem"
              aria-label="Undo conversation"
              class="btn undo-menu-item"
              onClick={() => {
                onSelect(true, false);
              }}
            >
              <span>Undo conversation</span>
              <span class="undo-menu-item-detail">
                {pending.retainsPrompt
                  ? "The preceding prompt will remain."
                  : "Its prompt will return to the composer."}
              </span>
            </button>
            {pending.canRevertFiles && (
              <>
                <button
                  type="button"
                  role="menuitem"
                  class="btn undo-menu-item"
                  onClick={() => {
                    onSelect(true, true);
                  }}
                >
                  Undo conversation + files
                </button>
                <button
                  type="button"
                  role="menuitem"
                  class="btn undo-menu-item"
                  onClick={() => {
                    onSelect(false, true);
                  }}
                >
                  Undo files only
                </button>
              </>
            )}
            {pending.fileChanges && (
              <div class="undo-menu-files">
                <div>
                  {pending.fileChanges.files && (
                    <>
                      Restores {pending.fileChanges.files.length} file
                      {pending.fileChanges.files.length === 1 ? "" : "s"}{" "}
                    </>
                  )}
                  <span class="diffstat-added">
                    +{pending.fileChanges.insertions}
                  </span>{" "}
                  <span class="diffstat-removed">
                    −{pending.fileChanges.deletions}
                  </span>
                </div>
                {pending.fileChanges.files && (
                  <ul class="undo-menu-paths">
                    {pending.fileChanges.files.map((path) => (
                      <li key={path}>
                        <PathDisplay path={path} />
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
