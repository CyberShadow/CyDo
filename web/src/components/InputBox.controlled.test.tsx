/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import { actPoll, actStep } from "../test-support/preactAct";
import { waitFor } from "../test-support/waitFor";
import {
  createControlledImageStore,
  resetControlledImageStore,
} from "../controlledImageStore";
import { InputBox } from "./InputBox";
import type { ImageAttachment } from "../useSessionManager";
import { createOrdinaryDraftStore } from "../ordinaryDraftStore";

const animationFrames = vi.hoisted(() => {
  let nextId = 0;
  const callbacks = new Map<number, FrameRequestCallback>();

  vi.stubGlobal("CSS", { supports: () => false });

  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    const id = ++nextId;
    callbacks.set(id, callback);
    return id;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => {
    callbacks.delete(id);
  });

  return {
    get pending() {
      return callbacks.size > 0;
    },
    runFrame() {
      const pending = [...callbacks.keys()];
      const timestamp = performance.now();
      for (const id of pending) {
        const callback = callbacks.get(id);
        callbacks.delete(id);
        callback?.(timestamp);
      }
    },
  };
});

async function updateInput(update: () => void) {
  await act(update);
  await actPoll({
    description: "mocked animation frame queue to empty",
    ready: () => {
      if (!animationFrames.pending) return true;
      void act(() => {
        animationFrames.runFrame();
      });
      return !animationFrames.pending;
    },
  });
}

function pasteImage(textarea: HTMLTextAreaElement) {
  const file = new File(["image"], "image.png", { type: "image/png" });
  const event = new Event("paste", { bubbles: true }) as ClipboardEvent;
  Object.defineProperty(event, "clipboardData", {
    value: {
      items: [
        {
          kind: "file",
          type: "image/png",
          getAsFile: () => file,
        },
      ],
    },
    enumerable: true,
  });
  textarea.dispatchEvent(event);
  return event;
}

function dropImage(inputBox: HTMLElement) {
  const file = new File(["image"], "image.png", { type: "image/png" });
  const event = new Event("drop", { bubbles: true }) as DragEvent;
  Object.defineProperty(event, "dataTransfer", {
    value: { files: [file] },
    enumerable: true,
  });
  inputBox.dispatchEvent(event);
  return event;
}

function mockImageReader() {
  const readers: FileReader[] = [];
  const readAsDataURL = vi
    .spyOn(FileReader.prototype, "readAsDataURL")
    .mockImplementation(function (this: FileReader) {
      readers.push(this);
    });

  const complete = (reader: FileReader) => {
    reader.onload?.({
      target: { result: "data:image/png;base64,aW1hZ2U=" },
    } as ProgressEvent<FileReader>);
  };

  const waitForRead = () =>
    actPoll({
      description: "image FileReader to start",
      ready: () => readers.length > 0,
    });

  return {
    waitForRead,
    async completeNext() {
      await waitForRead();
      await act(() => {
        complete(readers.shift()!);
      });
    },
    get pendingReads() {
      return readers.length;
    },
    restore() {
      for (const reader of readers.splice(0)) reader.onload = null;
      readAsDataURL.mockRestore();
    },
  };
}

describe("controlled InputBox", () => {
  let container: HTMLDivElement;
  let changes: string[];
  let submits: Array<{ text: string; images: ImageAttachment[] }>;

  const mount = (
    value: string,
    composerResetToken = 0,
    extras: Record<string, unknown> = {},
  ) => {
    void act(() => {
      render(
        <InputBox
          heicConversion={{ available: false }}
          getHeicConversion={() => ({ available: false })}
          mode="controlled"
          value={value}
          onChange={(next) => {
            changes.push(next);
          }}
          onSubmit={(text, images) => {
            submits.push({ text, images });
          }}
          composerResetToken={composerResetToken}
          onInterrupt={() => {}}
          isProcessing={false}
          disabled={false}
          {...extras}
        />,
        container,
      );
    });
  };

  const textarea = () =>
    container.querySelector<HTMLTextAreaElement>("textarea")!;
  const send = () => container.querySelector<HTMLButtonElement>(".btn-send")!;

  beforeEach(() => {
    changes = [];
    submits = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(async () => {
    await updateInput(() => {
      render(null, container);
    });
    container.remove();
  });

  it("renders the supplied value and emits the exact controlled edit", async () => {
    mount("first value");
    expect(textarea().value).toBe("first value");

    await updateInput(() => {
      textarea().value = "typed value";
      textarea().dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(changes).toEqual(["typed value"]);

    mount("server snapshot");
    expect(textarea().value).toBe("server snapshot");
  });

  it("does not consult or mutate the ordinary draft cache", async () => {
    const ordinaryDraftStore = createOrdinaryDraftStore();
    ordinaryDraftStore.ensure("ordinary-session", "ordinary cached text");
    mount("controlled text", 0, {
      sessionId: "ordinary-session",
      serverDraft: "ordinary server text",
      inputDraft: "ordinary recovered text",
      ordinaryDraftStore,
    });

    expect(textarea().value).toBe("controlled text");
    await updateInput(() => {
      textarea().value = "new controlled text";
      textarea().dispatchEvent(new Event("input", { bubbles: true }));
    });

    expect(changes).toEqual(["new controlled text"]);
    expect(ordinaryDraftStore.read("ordinary-session")).toBe(
      "ordinary cached text",
    );
  });

  it("restores only the supplied snapshot after unmount and remount", () => {
    const ordinaryDraftStore = createOrdinaryDraftStore();
    ordinaryDraftStore.ensure("ordinary-session", "stale cache");
    mount("slot snapshot", 0, { ordinaryDraftStore });
    void act(() => {
      render(null, container);
    });
    mount("slot snapshot", 0, { ordinaryDraftStore });

    expect(textarea().value).toBe("slot snapshot");
  });

  it("eagerly invalidates every controlled image store entry", () => {
    const store = createControlledImageStore();
    const receiveA = vi.fn(() => {
      expect(store.entries.has("project-a")).toBe(false);
      expect(store.entries.has("project-b")).toBe(false);
    });
    const receiveB = vi.fn(() => {
      expect(store.entries.has("project-a")).toBe(false);
      expect(store.entries.has("project-b")).toBe(false);
    });
    const entryA = {
      resetToken: 3,
      generation: 4,
      images: [
        {
          id: "a",
          dataURL: "data:image/png;base64,YQ==",
          base64: "YQ==",
          name: "image.png",
          mediaType: "image/png",
        },
      ],
      refusals: ["x"],
      listeners: new Set([receiveA]),
    };
    const entryB = {
      resetToken: 7,
      generation: 8,
      images: [
        {
          id: "b",
          dataURL: "data:image/png;base64,Yg==",
          base64: "Yg==",
          name: "image.png",
          mediaType: "image/png",
        },
      ],
      refusals: ["x"],
      listeners: new Set([receiveB]),
    };
    store.entries.set("project-a", entryA);
    store.entries.set("project-b", entryB);

    resetControlledImageStore(store);

    expect(store.entries.size).toBe(0);
    expect(entryA.images).toEqual([]);
    expect(entryA.refusals).toEqual([]);
    expect(entryB.images).toEqual([]);
    expect(entryB.refusals).toEqual([]);
    expect(entryA.generation).toBe(5);
    expect(entryB.generation).toBe(9);
    expect(receiveA).toHaveBeenCalledWith([], [], 5);
    expect(receiveB).toHaveBeenCalledWith([], [], 9);
    expect(entryA.listeners.size).toBe(0);
    expect(entryB.listeners.size).toBe(0);

    resetControlledImageStore(store);

    expect(store.entries.size).toBe(0);
    expect(entryA.generation).toBe(5);
    expect(entryB.generation).toBe(9);
  });

  it("retains controlled text and submitted images until its reset token changes", async () => {
    const imageReader = mockImageReader();
    const randomUUID = vi
      .spyOn(crypto, "randomUUID")
      .mockReturnValue("00000000-0000-4000-8000-000000000000");
    try {
      mount("  send this  ");
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.completeNext();
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });

      await updateInput(() => {
        send().click();
      });

      expect(changes).toEqual([]);
      expect(submits).toEqual([
        {
          text: "send this",
          images: [
            {
              id: "00000000-0000-4000-8000-000000000000",
              dataURL: "data:image/png;base64,aW1hZ2U=",
              base64: "aW1hZ2U=",
              name: "image.png",
              mediaType: "image/png",
            },
          ],
        },
      ]);
      expect(textarea().value).toBe("  send this  ");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      mount("  send this  ", 0, { disabled: true, submitLabel: "Submitting…" });
      expect(send().textContent).toBe("Submitting…");
      expect(send().disabled).toBe(true);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      mount("  send this  ");
      expect(send().disabled).toBe(false);
      await updateInput(() => {
        send().click();
      });
      expect(submits).toEqual([submits[0], submits[0]]);

      mount("", 1);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      imageReader.restore();
      randomUUID.mockRestore();
    }
  });

  it("submits an image-only controlled draft", async () => {
    const imageReader = mockImageReader();
    try {
      mount("");
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.completeNext();
      await waitFor(() => {
        expect(send().disabled).toBe(false);
      });
      await updateInput(() => {
        send().click();
      });

      expect(submits).toHaveLength(1);
      expect(submits[0]?.text).toBe("");
      expect(submits[0]?.images).toHaveLength(1);
    } finally {
      imageReader.restore();
    }
  });

  it("rejects disabled image ingestion without carrying it into an enabled draft", async () => {
    const imageReader = mockImageReader();
    try {
      mount("", 0, { disabled: true });
      // This non-flaky negative check has no completion signal for disabled intake.
      await actStep(() => {
        pasteImage(textarea());
        dropImage(container.querySelector<HTMLElement>(".input-box")!);
      });

      expect(imageReader.pendingReads).toBe(0);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      mount("");

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);

      await updateInput(() => {
        dropImage(container.querySelector<HTMLElement>(".input-box")!);
      });
      await imageReader.completeNext();
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      expect(send().disabled).toBe(false);
    } finally {
      imageReader.restore();
    }
  });

  it("does not carry an in-flight image across a controlled composer reset", async () => {
    const imageReader = mockImageReader();
    try {
      mount("draft A", 7);
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.waitForRead();
      mount("", 8);
      // The stale local read has no completion signal. This checkpoint only checks for an unexpected update.
      await imageReader.completeNext();
      await actStep();

      expect(textarea().value).toBe("");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);
      await updateInput(() => {
        send().click();
      });
      expect(submits).toEqual([]);
    } finally {
      imageReader.restore();
    }
  });

  it("invalidates in-flight images across controlled disabled intervals", async () => {
    const imageReader = mockImageReader();
    try {
      mount("", 0);
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.waitForRead();
      mount("", 0, { disabled: true });
      await imageReader.completeNext();
      // This negative check has no completion signal for the discarded local read.
      await actStep();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      mount("", 0);
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.waitForRead();
      mount("", 0, { disabled: true });
      mount("", 0);
      await imageReader.completeNext();
      // This negative check has no completion signal for the discarded local read.
      await actStep();

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);
      await updateInput(() => {
        send().click();
      });
      expect(submits).toEqual([]);
    } finally {
      imageReader.restore();
    }
  });

  it("keeps ordinary image reads enabled", async () => {
    const imageReader = mockImageReader();
    const sent: Array<{ text: string; images?: ImageAttachment[] }> = [];
    try {
      void act(() => {
        render(
          <InputBox
            heicConversion={{ available: false }}
            getHeicConversion={() => ({ available: false })}
            onSend={(text, images) => {
              sent.push({ text, images });
            }}
            onInterrupt={() => {}}
            isProcessing={false}
            disabled={false}
            sessionId="ordinary-image-session"
            ordinaryDraftStore={createOrdinaryDraftStore()}
          />,
          container,
        );
      });
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.completeNext();
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      await updateInput(() => {
        send().click();
      });
      expect(sent).toHaveLength(1);
      expect(sent[0]?.text).toBe("");
      expect(sent[0]?.images).toHaveLength(1);
    } finally {
      imageReader.restore();
    }
  });

  it("keeps loaded and held images through controlled handoff rerenders", async () => {
    const imageReader = mockImageReader();
    try {
      mount("replacement B", 7);
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.completeNext();
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      });
      await updateInput(() => {
        pasteImage(textarea());
      });
      await imageReader.waitForRead();

      mount("replacement B", 7);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      await imageReader.completeNext();
      await waitFor(() => {
        expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      });

      mount("replacement B", 8);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      imageReader.restore();
    }
  });
});
