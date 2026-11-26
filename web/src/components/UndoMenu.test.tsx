// @vitest-environment jsdom

import { createRef } from "preact";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ownedRoots } from "../test-support/preactAct";
import type { UndoPending } from "../types";
import { UndoMenu } from "./UndoMenu";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  Reflect.deleteProperty(Element.prototype, "scrollIntoView");
});
const roots = ownedRoots();
const userPreview = {
  anchor: "boundary-7",
  kind: "history_entries",
  messagesRemoved: 1,
  canRevertFiles: false,
  retainsPrompt: false,
} satisfies UndoPending;
const longPath = `/project/${"nested-directory/".repeat(12)}a.txt`;
const filePreview = {
  ...userPreview,
  canRevertFiles: true,
  fileChanges: {
    files: [longPath, "/project/b.txt"],
    insertions: 5,
    deletions: 2,
  },
} satisfies UndoPending;

function renderMenu(pending: UndoPending, needed = 60) {
  const geometry = { listBottom: 300, rowTop: 200, rowBottom: 222 };
  const scrollIntoView = vi.fn();
  Object.defineProperty(Element.prototype, "scrollIntoView", {
    configurable: true,
    value: scrollIntoView,
  });
  let nextHandle = 0;
  const frames = new Map<number, FrameRequestCallback>();
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    frames.set(++nextHandle, callback);
    return nextHandle;
  });
  const cancelFrame = vi.fn((handle: number) => frames.delete(handle));
  vi.stubGlobal("cancelAnimationFrame", cancelFrame);
  vi.spyOn(Element.prototype, "scrollHeight", "get").mockReturnValue(
    needed - 2,
  );
  vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(22);
  vi.spyOn(Element.prototype, "clientHeight", "get").mockReturnValue(20);

  const root = roots.create();
  const buttonRef = createRef<HTMLButtonElement>();
  const onSelect = vi.fn();
  const onDismiss = vi.fn();
  roots.render(
    <>
      <div
        class="message-list"
        ref={(list) => {
          if (!list) return;
          list.getBoundingClientRect = () =>
            new DOMRect(0, 0, 400, geometry.listBottom);
          Object.defineProperties(list, {
            clientTop: { value: 0 },
            clientHeight: { get: () => geometry.listBottom },
          });
        }}
      >
        <div
          class="message-actions"
          ref={(row) => {
            if (!row) return;
            row.getBoundingClientRect = () =>
              new DOMRect(
                370,
                geometry.rowTop,
                30,
                geometry.rowBottom - geometry.rowTop,
              );
          }}
        >
          <button class="undo-btn" ref={buttonRef}>
            Undo
          </button>
          <UndoMenu
            pending={pending}
            buttonRef={buttonRef}
            onSelect={onSelect}
            onDismiss={onDismiss}
          />
        </div>
      </div>
      <button data-outside>Outside</button>
    </>,
    root,
  );
  const menu = root.querySelector<HTMLElement>('[role="menu"]')!;
  return {
    root,
    geometry,
    scrollIntoView,
    frames,
    cancelFrame,
    frame: () => {
      for (const [handle, callback] of [...frames]) {
        frames.delete(handle);
        callback(0);
      }
    },
    menu,
    items: [...menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')],
    buttonRef,
    onSelect,
    onDismiss,
  };
}

describe("UndoMenu", () => {
  it("opens below when it fits even with more space above", () => {
    const { menu } = renderMenu(userPreview);
    expect(menu.classList.contains("undo-menu-up")).toBe(false);
    expect(menu.style.maxHeight).toBe("78px");
  });

  it("opens up and caps its height when it cannot fit below", () => {
    const { menu } = renderMenu(userPreview, 150);
    expect(menu.classList.contains("undo-menu-up")).toBe(true);
    expect(menu.style.maxHeight).toBe("200px");
  });

  it("repositions on successive frames as the scrollport and row move", () => {
    const { menu, geometry, frame } = renderMenu(userPreview);
    geometry.rowTop = 140;
    geometry.rowBottom = 162;
    frame();
    expect(menu.style.maxHeight).toBe("138px");

    geometry.listBottom = 240;
    frame();
    expect(menu.style.maxHeight).toBe("78px");
    expect(menu.classList.contains("undo-menu-up")).toBe(false);

    geometry.rowTop = 180;
    geometry.rowBottom = 202;
    frame();
    expect(menu.classList.contains("undo-menu-up")).toBe(true);
    expect(menu.style.maxHeight).toBe("180px");
  });

  it.each([
    ["top", -1, 21],
    ["bottom", 279, 301],
  ] as const)(
    "dismisses once when the row is partly clipped at the %s",
    (_, rowTop, rowBottom) => {
      const { geometry, frame, frames, menu, buttonRef, onDismiss } =
        renderMenu(userPreview);
      expect(document.activeElement).toBe(menu);
      const focus = vi.spyOn(buttonRef.current!, "focus");
      Object.assign(geometry, { rowTop, rowBottom });
      frame();
      expect(onDismiss).toHaveBeenCalledTimes(1);
      expect(document.activeElement).toBe(buttonRef.current);
      expect(focus).toHaveBeenCalledExactlyOnceWith({ preventScroll: true });

      frame();
      expect(onDismiss).toHaveBeenCalledTimes(1);
      expect(frames.size).toBe(0);
    },
  );

  it("preserves focus outside the menu when clipping dismisses it", () => {
    const { root, geometry, frame, onDismiss } = renderMenu(userPreview);
    const outside = root.querySelector<HTMLButtonElement>("[data-outside]")!;
    outside.focus();
    Object.assign(geometry, { rowTop: -1, rowBottom: 21 });
    frame();
    expect(onDismiss).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(outside);
  });

  it("scrolls the opener into view on open", () => {
    const { scrollIntoView, buttonRef } = renderMenu(userPreview);
    expect(scrollIntoView).toHaveBeenCalledExactlyOnceWith({
      block: "nearest",
    });
    expect(scrollIntoView.mock.contexts[0]).toBe(buttonRef.current);
  });

  it("cancels the pending frame on unmount", () => {
    const { root, frames, frame, cancelFrame } = renderMenu(userPreview);
    frame();
    expect(frames.size).toBe(1);
    const [pending] = frames.keys();
    roots.render(null, root);
    expect(cancelFrame).toHaveBeenCalledExactlyOnceWith(pending);
    expect(frames.size).toBe(0);
  });

  it("shows a loading state without choices while requesting a preview", () => {
    const { menu, items } = renderMenu({
      anchor: "boundary-7",
      kind: "requesting",
      requestId: "preview-1",
      retainsPrompt: false,
    });

    expect(menu.textContent).toContain(
      "Remove this message and later history?",
    );
    expect(menu.textContent).toContain("Loading…");
    expect(items).toHaveLength(0);
  });

  it("describes removing a user message and restoring its prompt", () => {
    const { menu } = renderMenu(userPreview);

    expect(menu.textContent).toContain(
      "Remove this message and later history?",
    );
    expect(menu.textContent).toContain(
      "Its prompt will return to the composer.",
    );
    expect(menu.textContent).toContain("1 message will be removed.");
  });

  it("describes Codex removal in whole turns and keeps the preceding prompt", () => {
    const { menu, items } = renderMenu({
      ...userPreview,
      kind: "codex_turns",
      messagesRemoved: 2,
      retainsPrompt: true,
    });

    expect(menu.textContent).toContain(
      "Remove this response and later history?",
    );
    expect(menu.textContent).toContain("The preceding prompt will remain.");
    expect(menu.textContent).toContain("2 whole turns will be removed.");
    expect(items).toHaveLength(1);
  });

  it("offers only conversation undo when files cannot be reverted", () => {
    const { items } = renderMenu(userPreview);

    expect(
      items.map((item) => item.getAttribute("aria-label") ?? item.textContent),
    ).toEqual(["Undo conversation"]);
  });

  it("offers three choices without a file preview when only availability is known", () => {
    const { menu, items } = renderMenu({
      ...userPreview,
      canRevertFiles: true,
    });

    expect(items).toHaveLength(3);
    expect(menu.querySelector(".undo-menu-files")).toBeNull();
  });

  it("previews the changed paths and line counts", () => {
    const { menu } = renderMenu(filePreview);

    expect(
      [...menu.querySelectorAll("li")].map((item) => item.textContent.trim()),
    ).toEqual([longPath, "/project/b.txt"]);
    expect(menu.textContent).toContain("+5");
    expect(menu.textContent).toContain("−2");
  });

  it("shows the line counts without a path list when paths are unavailable", () => {
    const { menu } = renderMenu({
      ...filePreview,
      fileChanges: { insertions: 5, deletions: 2 },
    });

    expect(menu.textContent).toContain("+5");
    expect(menu.textContent).toContain("−2");
    expect(menu.querySelector("ul")).toBeNull();
  });

  it.each([
    ["Undo conversation", true, false],
    ["Undo conversation + files", true, true],
    ["Undo files only", false, true],
  ] as const)(
    "%s forwards its selection",
    (label, revertConversation, revertFiles) => {
      const { items, onSelect } = renderMenu(filePreview);

      items
        .find(
          (item) =>
            (item.getAttribute("aria-label") ?? item.textContent) === label,
        )!
        .click();

      expect(onSelect).toHaveBeenCalledExactlyOnceWith(
        revertConversation,
        revertFiles,
      );
    },
  );

  it("dismisses on Escape and returns focus to the undo button", () => {
    const { menu, onDismiss, buttonRef } = renderMenu(userPreview);
    expect(document.activeElement).toBe(menu);

    menu.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );

    expect(onDismiss).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(buttonRef.current);
  });

  it("dismisses on an outside click", () => {
    const { root, onDismiss } = renderMenu(userPreview);

    root.querySelector<HTMLButtonElement>("[data-outside]")!.click();

    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it("keeps the menu open on an inside click", () => {
    const { menu, onDismiss } = renderMenu(filePreview);

    menu.querySelector("li")!.click();

    expect(onDismiss).not.toHaveBeenCalled();
  });
});
