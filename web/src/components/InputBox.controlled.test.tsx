/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import {
  createControlledImageStore,
  InputBox,
  resetControlledImageStore,
} from "./InputBox";
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
    take() {
      const pending = [...callbacks.values()];
      callbacks.clear();
      return pending;
    },
  };
});

const flush = async (update?: () => void) => {
  await act(async () => {
    update?.();
    await Promise.resolve();
    await Promise.resolve();

    let idlePasses = 0;
    for (let pass = 0; pass < 10; pass++) {
      await new Promise((resolve) => setTimeout(resolve));
      const callbacks = animationFrames.take();
      if (callbacks.length === 0) {
        if (++idlePasses === 2) return;
        continue;
      }

      idlePasses = 0;
      for (const callback of callbacks) {
        callback(performance.now());
      }
    }
  });
};

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

  return {
    complete() {
      for (const reader of readers.splice(0)) complete(reader);
    },
    completeNext() {
      const reader = readers.shift();
      if (reader) complete(reader);
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
          mode="controlled"
          value={value}
          onChange={(next) => {
            changes.push(next);
          }}
          onBlur={() => {}}
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
    await act(async () => {
      render(null, container);
      await flush();
    });
    container.remove();
  });

  it("renders the supplied value and emits the exact controlled edit", async () => {
    mount("first value");
    expect(textarea().value).toBe("first value");

    await flush(() => {
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
    await flush(() => {
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
          mediaType: "image/png",
        },
      ],
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
          mediaType: "image/png",
        },
      ],
      listeners: new Set([receiveB]),
    };
    store.entries.set("project-a", entryA);
    store.entries.set("project-b", entryB);

    resetControlledImageStore(store);

    expect(store.entries.size).toBe(0);
    expect(entryA.images).toEqual([]);
    expect(entryB.images).toEqual([]);
    expect(entryA.generation).toBe(5);
    expect(entryB.generation).toBe(9);
    expect(receiveA).toHaveBeenCalledWith([], 5);
    expect(receiveB).toHaveBeenCalledWith([], 9);
    expect(entryA.listeners.size).toBe(0);
    expect(entryB.listeners.size).toBe(0);

    resetControlledImageStore(store);

    expect(store.entries.size).toBe(0);
    expect(entryA.generation).toBe(5);
    expect(entryB.generation).toBe(9);
  });

  it("submits trimmed text and exact images without clearing controlled text", async () => {
    class Reader {
      onload: ((event: ProgressEvent<FileReader>) => void) | null = null;
      readAsDataURL() {
        setTimeout(() => {
          this.onload?.({
            target: { result: "data:image/png;base64,aW1hZ2U=" },
          } as ProgressEvent<FileReader>);
        });
      }
    }
    vi.stubGlobal("FileReader", Reader);
    vi.stubGlobal("crypto", { randomUUID: () => "image-id" });
    try {
      mount("  send this  ");
      await flush(() => {
        pasteImage(textarea());
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);

      await flush(() => {
        send().click();
      });

      expect(changes).toEqual([]);
      expect(submits).toEqual([
        {
          text: "send this",
          images: [
            {
              id: "image-id",
              dataURL: "data:image/png;base64,aW1hZ2U=",
              base64: "aW1hZ2U=",
              mediaType: "image/png",
            },
          ],
        },
      ]);
    } finally {
      vi.unstubAllGlobals();
      vi.stubGlobal("CSS", { supports: () => false });
    }
  });

  it("submits an image-only controlled draft", async () => {
    class Reader {
      onload: ((event: ProgressEvent<FileReader>) => void) | null = null;
      readAsDataURL() {
        setTimeout(() => {
          this.onload?.({
            target: { result: "data:image/png;base64,aW1hZ2U=" },
          } as ProgressEvent<FileReader>);
        });
      }
    }
    vi.stubGlobal("FileReader", Reader);
    try {
      mount("");
      await flush(() => {
        pasteImage(textarea());
      });
      await flush(() => {
        send().click();
      });

      expect(submits).toHaveLength(1);
      expect(submits[0]?.text).toBe("");
      expect(submits[0]?.images).toHaveLength(1);
    } finally {
      vi.unstubAllGlobals();
      vi.stubGlobal("CSS", { supports: () => false });
    }
  });

  it("rejects disabled image ingestion without carrying it into an enabled draft", async () => {
    const imageReader = mockImageReader();
    try {
      mount("", 0, { disabled: true });
      await flush(() => {
        pasteImage(textarea());
        dropImage(container.querySelector<HTMLElement>(".input-box")!);
        imageReader.complete();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      mount("");
      await flush();

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);

      await flush(() => {
        dropImage(container.querySelector<HTMLElement>(".input-box")!);
        imageReader.complete();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      expect(send().disabled).toBe(false);
    } finally {
      imageReader.restore();
    }
  });

  it("does not carry an in-flight image across a controlled composer reset", async () => {
    const imageReader = mockImageReader();
    try {
      mount("draft A", 7);
      void act(() => {
        pasteImage(textarea());
      });
      mount("", 8);
      await flush(() => {
        imageReader.completeNext();
      });

      expect(textarea().value).toBe("");
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);
      await flush(() => {
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
      void act(() => {
        pasteImage(textarea());
      });
      mount("", 0, { disabled: true });
      await flush(() => {
        imageReader.completeNext();
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);

      mount("", 0);
      void act(() => {
        pasteImage(textarea());
      });
      mount("", 0, { disabled: true });
      mount("", 0);
      await flush(() => {
        imageReader.completeNext();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
      expect(send().disabled).toBe(true);
      await flush(() => {
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
      await flush(() => {
        pasteImage(textarea());
        imageReader.completeNext();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      await flush(() => {
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
      await flush(() => {
        pasteImage(textarea());
        imageReader.completeNext();
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      void act(() => {
        pasteImage(textarea());
      });

      mount("replacement B", 7);
      await flush();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(1);
      await flush(() => {
        imageReader.completeNext();
      });
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);

      mount("replacement B", 8);
      await flush();
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      imageReader.restore();
    }
  });
});
