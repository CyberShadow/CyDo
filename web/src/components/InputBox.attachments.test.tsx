/** @vitest-environment jsdom */
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  createControlledImageStore,
  resetControlledImageStore,
  retireControlledImage,
} from "../controlledImageStore";
import { createOrdinaryDraftStore } from "../ordinaryDraftStore";
import * as imageSniff from "../imageSniff";
import type { HeicConversionStatus } from "../protocol";
import { InputBox } from "./InputBox";

vi.hoisted(() => vi.stubGlobal("CSS", { supports: () => false }));

let container: HTMLDivElement;
const png = () => new File(["image"], "photo.png", { type: "image/png" });
const heic = () => new File(["image"], "photo.heic", { type: "image/heic" });
const picker = () =>
  container.querySelector<HTMLInputElement>('input[type="file"]')!;
const attach = () =>
  container.querySelector<HTMLButtonElement>(
    'button[aria-label="Attach images"]',
  )!;
const previews = () => container.querySelectorAll(".image-preview img");
const chips = () => container.querySelectorAll(".image-preview-label");
const heicBytes = "\0\0\0\x10ftypheic\0\0\0\0";
const untypedHeic = (name = "IMG_0001.HEIC") => new File([heicBytes], name);
const available = { available: true };
const unavailable = { available: false, reason: "converter is offline" };
let currentConversion: HeicConversionStatus;
const status = () => container.querySelector('[role="status"]');

beforeEach(() => {
  container = document.createElement("div");
  document.body.appendChild(container);
});

afterEach(() => {
  void act(() => {
    render(null, container);
  });
  container.remove();
  vi.restoreAllMocks();
});

function mount(
  mode: "ordinary" | "controlled",
  options: {
    disabled?: boolean;
    stdinClosed?: boolean;
    composerResetToken?: number;
    imageKey?: string;
    sessionId?: string;
    heicConversion?: HeicConversionStatus;
    getHeicConversion?: () => HeicConversionStatus;
    imageStore?: ReturnType<typeof createControlledImageStore>;
  } = {},
) {
  currentConversion = options.heicConversion ?? unavailable;
  const common = {
    isProcessing: false,
    onInterrupt: () => {},
    disabled: false,
    ...options,
    heicConversion: currentConversion,
    getHeicConversion: options.getHeicConversion ?? (() => currentConversion),
  };
  void act(() => {
    render(
      mode === "ordinary" ? (
        <InputBox
          {...common}
          sessionId={options.sessionId ?? "session"}
          ordinaryDraftStore={createOrdinaryDraftStore()}
          onSend={() => {}}
        />
      ) : (
        <InputBox
          {...common}
          mode="controlled"
          composerResetToken={options.composerResetToken ?? 0}
          value=""
          onChange={() => {}}
          onSubmit={() => {}}
        />
      ),
      container,
    );
  });
}

function pick(...files: File[]) {
  Object.defineProperty(picker(), "files", {
    value: files,
    configurable: true,
  });
  void act(() => {
    picker().dispatchEvent(new Event("change", { bubbles: true }));
  });
}

function transfer(kind: "paste" | "drop", files: File[]) {
  const event = new Event(kind, { bubbles: true, cancelable: true });
  if (kind === "paste") {
    Object.defineProperty(event, "clipboardData", {
      value: {
        items: files.map((file) => ({
          kind: "file",
          type: file.type,
          getAsFile: () => file,
        })),
      },
    });
  } else {
    Object.defineProperty(event, "dataTransfer", { value: { files } });
  }
  void act(() => {
    container.querySelector("textarea")!.dispatchEvent(event);
  });
  return event;
}

function holdFullReads() {
  const pending = new Map<string, FileReader>();
  vi.spyOn(FileReader.prototype, "readAsDataURL").mockImplementation(function (
    this: FileReader,
    file,
  ) {
    pending.set((file as File).name, this);
  });
  return {
    pending,
    async finish(name: string) {
      const reader = pending.get(name)!;
      pending.delete(name);
      await act(async () => {
        reader.onload?.({
          target: { result: "data:application/octet-stream;base64,aW1hZ2U=" },
        } as ProgressEvent<FileReader>);
        await Promise.resolve();
      });
    },
  };
}

const modes = ["ordinary", "controlled"] as const;

it.each(modes)("opens the multiple-image picker in the %s composer", (mode) => {
  mount(mode);
  const openPicker = vi.spyOn(picker(), "click");
  expect(picker().accept).toBe("image/*");
  expect(picker().multiple).toBe(true);
  attach().click();
  expect(openPicker).toHaveBeenCalledOnce();
});

it.each(modes)("previews picked images in the %s composer", async (mode) => {
  mount(mode);
  pick(png(), new File(["image"], "animation.gif", { type: "image/gif" }));
  await vi.waitFor(() => {
    expect(
      Array.from(previews(), (image) => image.getAttribute("src")),
    ).toEqual(
      expect.arrayContaining([
        "data:image/png;base64,aW1hZ2U=",
        "data:image/gif;base64,aW1hZ2U=",
      ]),
    );
    expect(previews()).toHaveLength(2);
  });
});

it("names every refused file in a mixed selection after the valid image loads", async () => {
  mount("ordinary");
  pick(
    new File(
      [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])],
      "photo.heic",
      { type: "image/heic" },
    ),
    png(),
    new File(["image"], "unknown.heic"),
    new File(["text"], "notes.txt", { type: "text/plain" }),
  );

  await vi.waitFor(() => {
    expect(previews()).toHaveLength(1);
  });
  expect(previews()[0]?.getAttribute("src")).toMatch(/^data:image\/png;/);
  for (const name of ["photo.heic", "unknown.heic", "notes.txt"]) {
    expect(status()?.textContent).toContain(name);
  }
  expect(status()?.textContent).toContain("not a HEIC/HEIF still image");
  expect(status()?.textContent).not.toContain("photo.png");
});

it("clears a refusal when sending a text-only suggestion", async () => {
  const onSend = vi.fn();
  const suggestion = "Describe the project";
  void act(() => {
    render(
      <InputBox
        heicConversion={unavailable}
        getHeicConversion={() => unavailable}
        disabled={false}
        isProcessing={false}
        onInterrupt={() => {}}
        sessionId="session"
        ordinaryDraftStore={createOrdinaryDraftStore()}
        onSend={onSend}
        suggestions={[suggestion]}
      />,
      container,
    );
  });
  pick(heic(), png());
  await vi.waitFor(() => {
    expect(previews()).toHaveLength(1);
  });
  expect(status()?.textContent).toContain("photo.heic");

  void act(() => {
    container.querySelector<HTMLButtonElement>(".btn-suggestion")!.click();
  });

  expect(onSend.mock.calls).toEqual([[suggestion]]);
  expect(status()).toBeNull();
  expect(previews()).toHaveLength(1);
});

it.each(["paste", "drop"] as const)(
  "names refused files from %s",
  async (kind) => {
    mount("ordinary");
    const event = transfer(kind, [
      new File(["text"], "notes.txt", { type: "text/plain" }),
    ]);
    expect(event.defaultPrevented).toBe(true);
    await vi.waitFor(() => {
      expect(status()?.textContent).toContain("notes.txt");
    });
    expect(previews()).toHaveLength(0);
  },
);

it("lets plain-text paste use the browser default", () => {
  mount("ordinary");
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { items: [{ kind: "string", type: "text/plain" }] },
  });
  container.querySelector("textarea")!.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(false);
  expect(status()).toBeNull();
});

it.each(modes)(
  "blocks intake when the %s composer is disabled",
  async (mode) => {
    mount(mode, { disabled: true });
    expect(attach().disabled).toBe(true);
    expect(picker().disabled).toBe(true);

    const sniff = vi
      .spyOn(FileReader.prototype, "readAsArrayBuffer")
      .mockImplementation(function (this: FileReader) {
        this.dispatchEvent(new ProgressEvent("error"));
      });
    const read = vi.spyOn(FileReader.prototype, "readAsDataURL");
    pick(png(), heic());
    expect(transfer("paste", [png(), heic()]).defaultPrevented).toBe(true);
    expect(transfer("drop", [png(), heic()]).defaultPrevented).toBe(true);

    await act(async () => {
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    });
    expect(sniff).not.toHaveBeenCalled();
    expect(read).not.toHaveBeenCalled();
    expect(status()).toBeNull();
    expect(previews()).toHaveLength(0);
  },
);

it.each(modes)(
  "disables the picker when stdin is closed in the %s composer",
  (mode) => {
    mount(mode, { stdinClosed: true });
    expect(attach().disabled).toBe(true);
    expect(picker().disabled).toBe(true);
  },
);

it("clears a refusal when switching controlled editors", async () => {
  const imageStore = createControlledImageStore();
  mount("controlled", { imageStore, imageKey: "first" });
  pick(heic());
  await vi.waitFor(() => {
    expect(status()?.textContent).toContain("photo.heic");
  });

  mount("controlled", { imageStore, imageKey: "second" });
  expect(status()).toBeNull();
});

it("clears a refusal when resetting a controlled editor", async () => {
  mount("controlled", { composerResetToken: 1 });
  pick(heic());
  await vi.waitFor(() => {
    expect(status()?.textContent).toContain("photo.heic");
  });

  mount("controlled", { composerResetToken: 2 });
  expect(status()).toBeNull();
});

it.each(modes)(
  "shows a HEIC chip for a drop in the %s composer",
  async (mode) => {
    mount(mode, { heicConversion: available });
    transfer("drop", [untypedHeic()]);

    await vi.waitFor(() => {
      expect(chips()).toHaveLength(1);
      expect(chips()[0]?.textContent).toContain("HEIC");
      expect(chips()[0]?.textContent).toContain("IMG_0001.HEIC");
    });
    expect(previews()).toHaveLength(0);
    expect(container.querySelector(".attach-error")).toBeNull();
  },
);

it.each(
  modes.flatMap((mode) => ["", "image/heic"].map((type) => ({ mode, type }))),
)(
  "refuses HEIC with MIME '$type' when conversion is unavailable in the $mode composer",
  async ({ mode, type }) => {
    mount(mode, { heicConversion: unavailable });
    transfer("drop", [new File([heicBytes], "IMG_0001.HEIC", { type })]);

    await vi.waitFor(() => {
      const error = container.querySelector(".attach-error")?.textContent;
      expect(error).toContain("IMG_0001.HEIC");
      expect(error).toContain(unavailable.reason);
    });
    expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
  },
);

it.each(modes)("previews an untyped PNG in the %s composer", async (mode) => {
  mount(mode);
  pick(
    new File(
      [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])],
      "untyped.bin",
    ),
  );

  await vi.waitFor(() => {
    expect(previews()).toHaveLength(1);
    expect(previews()[0]?.getAttribute("src")).toMatch(
      /^data:image\/png;base64,/,
    );
  });
});

it.each(modes)(
  "refuses an unknown untyped file by name in the %s composer",
  async (mode) => {
    mount(mode, { heicConversion: available });
    pick(new File(["not an image"], "unknown.bin"));

    await vi.waitFor(() => {
      expect(status()?.textContent).toContain("unknown.bin");
    });
    expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
  },
);

it.each(modes)(
  "keeps accepted images in batch order in the %s composer",
  async (mode) => {
    const reads = holdFullReads();
    mount(mode, { heicConversion: available });
    pick(
      new File(["image"], "a.png", { type: "image/png" }),
      untypedHeic("b.heic"),
      new File(["BM"], "c.bmp", { type: "image/bmp" }),
    );

    await vi.waitFor(() => {
      expect(reads.pending.size).toBe(2);
    });
    await reads.finish("b.heic");
    expect(previews()).toHaveLength(0);
    expect(chips()).toHaveLength(0);
    expect(status()).toBeNull();
    await reads.finish("a.png");

    await vi.waitFor(() => {
      const batch = container.querySelectorAll(".image-preview");
      expect(batch).toHaveLength(2);
      expect(batch[0]?.querySelector("img")?.getAttribute("src")).toMatch(
        /^data:image\/png;/,
      );
      expect(
        batch[1]?.querySelector(".image-preview-label")?.textContent,
      ).toContain("b.heic");
      expect(status()?.textContent).toContain("c.bmp");
    });
    expect(status()?.textContent).not.toMatch(/a\.png|b\.heic/);
  },
);

it.each(modes)(
  "pastes an untyped HEIC as a chip in the %s composer",
  async (mode) => {
    mount(mode, { heicConversion: available });
    expect(transfer("paste", [untypedHeic()]).defaultPrevented).toBe(true);

    await vi.waitFor(() => {
      expect(chips()).toHaveLength(1);
      expect(chips()[0]?.textContent).toContain("HEIC");
    });
    expect(previews()).toHaveLength(0);
  },
);

it.each(modes)(
  "offers HEIC picker extensions only when available in the %s composer",
  (mode) => {
    mount(mode, { heicConversion: unavailable });
    expect(picker().accept.split(",")).toEqual(["image/*"]);

    mount(mode, { heicConversion: available });
    expect(picker().accept.split(",")).toEqual(["image/*", ".heic", ".heif"]);
  },
);

it.each(modes)(
  "discards a sniff result after the %s editor resets",
  async (mode) => {
    const oldFile = untypedHeic("old.heic");
    const sniff = imageSniff.sniffImageType;
    let release!: () => void;
    const pending = new Promise<void>((resolve) => {
      release = resolve;
    });
    const result = pending.then(() => sniff(oldFile));
    const delayedSniff = vi
      .spyOn(imageSniff, "sniffImageType")
      .mockReturnValueOnce(result);
    const imageStore = createControlledImageStore();
    const imageKey = "editor";
    const read = vi.spyOn(FileReader.prototype, "readAsDataURL");
    mount(mode, {
      composerResetToken: 1,
      heicConversion: available,
      imageStore,
      imageKey,
    });
    pick(oldFile);
    await vi.waitFor(() => {
      expect(delayedSniff).toHaveBeenCalledWith(oldFile);
    });

    mount(mode, {
      composerResetToken: 2,
      sessionId: "new-session",
      heicConversion: available,
      imageStore,
      imageKey,
    });
    await act(async () => {
      release();
      expect(await result).toBe("image/heic");
    });
    expect(read).not.toHaveBeenCalled();
    if (mode === "controlled")
      expect(imageStore.entries.get(imageKey)?.images).toEqual([]);
    pick(untypedHeic("new.heic"));
    await vi.waitFor(() => {
      expect(chips()).toHaveLength(1);
      expect(chips()[0]?.textContent).toContain("new.heic");
    });
    expect(read).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ name: "new.heic" }),
    );
    expect(status()).toBeNull();
  },
);

it.each(modes)(
  "uses the current converter status after sniffing in the %s composer",
  async (mode) => {
    let finish!: (type: "image/heic") => void;
    const pending = new Promise<"image/heic">((resolve) => {
      finish = resolve;
    });
    vi.spyOn(imageSniff, "sniffImageType").mockReturnValueOnce(pending);
    const photo = new File([heicBytes], "phone.heif", { type: "image/heif" });
    mount(mode, { heicConversion: available });
    pick(png(), photo);
    mount(mode, { heicConversion: unavailable });
    finish("image/heic");

    await vi.waitFor(() => {
      expect(previews()).toHaveLength(1);
      const error = container.querySelector(".attach-error")?.textContent;
      expect(error).toContain(photo.name);
      expect(error).toContain(unavailable.reason);
    });
    expect(chips()).toHaveLength(0);
  },
);

it.each(["header", "full"] as const)(
  "keeps readable siblings when the %s read fails",
  async (stage) => {
    const unreadable = new File(["image"], "unreadable.png", {
      type: stage === "full" ? "image/png" : "",
    });
    if (stage === "header") {
      vi.spyOn(
        FileReader.prototype,
        "readAsArrayBuffer",
      ).mockImplementationOnce(function (this: FileReader) {
        this.dispatchEvent(new ProgressEvent("error"));
      });
    } else {
      vi.spyOn(FileReader.prototype, "readAsDataURL").mockImplementationOnce(
        function (this: FileReader) {
          this.dispatchEvent(new ProgressEvent("error"));
        },
      );
    }

    mount("ordinary");
    pick(unreadable, png());
    await vi.waitFor(() => {
      expect(previews()).toHaveLength(1);
      expect(previews()[0]?.getAttribute("src")).toMatch(/^data:image\/png;/);
      expect(container.querySelector(".attach-error")?.textContent).toContain(
        "Could not read unreadable.png",
      );
    });
  },
);

it("reports a non-I/O exception instead of refusing the file", async () => {
  const failure = new TypeError("Unexpected reader invocation");
  vi.spyOn(FileReader.prototype, "readAsArrayBuffer").mockImplementationOnce(
    () => {
      throw failure;
    },
  );
  const report = vi
    .spyOn(globalThis, "queueMicrotask")
    .mockImplementationOnce(() => {});
  mount("ordinary", { heicConversion: available });
  pick(untypedHeic());

  await vi.waitFor(() => {
    expect(report).toHaveBeenCalledOnce();
  });
  expect(() => {
    report.mock.calls[0]![0]();
  }).toThrow(new Error("Attachment intake failed", { cause: failure }));
  expect(status()).toBeNull();
  expect(chips()).toHaveLength(0);
});

it.each(
  modes.flatMap((mode) =>
    [true, false].map((availableAtStart) => ({ mode, availableAtStart })),
  ),
)(
  "uses publish-time status in the $mode composer (initially available: $availableAtStart)",
  async ({ mode, availableAtStart }) => {
    const reads = holdFullReads();
    const photo = untypedHeic();
    mount(mode, { heicConversion: availableAtStart ? available : unavailable });
    pick(png(), photo);
    await vi.waitFor(() => {
      expect(reads.pending.has("photo.png")).toBe(true);
    });
    if (reads.pending.has(photo.name)) await reads.finish(photo.name);

    mount(mode, { heicConversion: availableAtStart ? unavailable : available });
    await reads.finish("photo.png");

    await vi.waitFor(() => {
      expect(previews()).toHaveLength(1);
      if (availableAtStart) {
        expect(chips()).toHaveLength(0);
        expect(status()?.textContent).toContain(photo.name);
        expect(status()?.textContent).toContain(unavailable.reason);
      } else {
        expect(chips()).toHaveLength(1);
        expect(status()).toBeNull();
      }
    });
  },
);

it.each(["before", "after"] as const)(
  "shows a controlled entry's refusal when the composer remounts %s the batch completes",
  async (remount) => {
    const reads = holdFullReads();
    const imageStore = createControlledImageStore();
    const imageKey = "draft-a";
    const photo = untypedHeic();
    let conversion: HeicConversionStatus = available;
    const mountEditor = () => {
      mount("controlled", {
        imageStore,
        imageKey,
        heicConversion: conversion,
        getHeicConversion: () => conversion,
      });
    };
    mountEditor();
    pick(png(), photo);
    await vi.waitFor(() => {
      expect(reads.pending.size).toBe(2);
    });

    void act(() => {
      render(null, container);
    });
    conversion = unavailable;
    if (remount === "before") mountEditor();
    await reads.finish(photo.name);
    await reads.finish("photo.png");
    if (remount === "after") mountEditor();

    expect(previews()).toHaveLength(1);
    expect(chips()).toHaveLength(0);
    expect(status()?.textContent).toContain(photo.name);
    expect(status()?.textContent).toContain(unavailable.reason);
    const entry = imageStore.entries.get(imageKey)!;
    expect(entry.images.map(({ name }) => name)).toEqual(["photo.png"]);
    expect(entry.refusals.join(" ")).toContain(photo.name);
  },
);

it.each(modes)(
  "preserves the newest batch refusal in the %s composer",
  async (mode) => {
    const reads = holdFullReads();
    mount(mode);
    pick(png());
    pick(new File(["text"], "last.txt", { type: "text/plain" }));
    await vi.waitFor(() => {
      expect(status()?.textContent).toContain("last.txt");
    });

    await reads.finish("photo.png");

    expect(previews()).toHaveLength(1);
    expect(status()?.textContent).toContain("last.txt");
  },
);

it.each(modes)(
  "keeps an older batch's refusal when a newer batch finishes first in the %s composer",
  async (mode) => {
    const reads = holdFullReads();
    mount(mode);
    pick(
      new File(["a"], "a.png", { type: "image/png" }),
      new File(["notes"], "notes.txt", { type: "text/plain" }),
    );
    pick(new File(["b"], "b.png", { type: "image/png" }));
    await vi.waitFor(() => {
      expect(reads.pending.size).toBe(2);
    });
    await reads.finish("b.png");
    await reads.finish("a.png");
    expect(previews()).toHaveLength(2);
    expect(status()?.textContent).toContain("notes.txt");
  },
);

it.each(modes)(
  "clears the previous refusal when a new batch starts in the %s composer",
  async (mode) => {
    const reads = holdFullReads();
    mount(mode);
    pick(new File(["notes"], "notes.txt", { type: "text/plain" }));
    await vi.waitFor(() => {
      expect(status()?.textContent).toContain("notes.txt");
    });
    pick(png());
    expect(status()).toBeNull();
    await vi.waitFor(() => {
      expect(reads.pending.has("photo.png")).toBe(true);
    });
    await reads.finish("photo.png");
    expect(previews()).toHaveLength(1);
  },
);

it.each(["store reset", "editor reset", "retirement"] as const)(
  "discards old intake and accepts fresh files after %s",
  async (operation) => {
    const imageStore = createControlledImageStore();
    const imageKey = "editor";
    const options = { imageStore, imageKey, composerResetToken: 1 };
    const reads = holdFullReads();
    mount("controlled", { ...options, composerResetToken: 0 });
    mount("controlled", options);
    const detached = imageStore.entries.get(imageKey)!;
    pick(
      new File(["image"], "stale.png", { type: "image/png" }),
      new File(["text"], "stale.txt", { type: "text/plain" }),
    );
    await vi.waitFor(() => {
      expect(reads.pending.has("stale.png")).toBe(true);
    });
    pick(heic());
    await vi.waitFor(() => {
      expect(status()?.textContent).toContain("photo.heic");
    });

    if (operation === "store reset") {
      void act(() => {
        resetControlledImageStore(imageStore);
      });
    } else if (operation === "editor reset") {
      mount("controlled", { ...options, composerResetToken: 2 });
    } else {
      retireControlledImage(imageStore, imageKey);
      mount("controlled", options);
    }
    expect(status()).toBeNull();

    await reads.finish("stale.png");
    expect(detached.images).toEqual([]);
    expect(detached.refusals).toEqual([]);
    expect(previews()).toHaveLength(0);
    expect(status()).toBeNull();

    pick(png(), new File(["text"], "notes.txt", { type: "text/plain" }));
    await vi.waitFor(() => {
      expect(reads.pending.has("photo.png")).toBe(true);
    });
    await reads.finish("photo.png");
    expect(previews()).toHaveLength(1);
    expect(status()?.textContent).toContain("notes.txt");
    expect(
      imageStore.entries.get(imageKey)?.images.map(({ name }) => name),
    ).toEqual(["photo.png"]);
  },
);

it("keeps a switched-to owner's pending intake and refusals across different reset tokens", async () => {
  const imageStore = createControlledImageStore();
  const a = { imageStore, imageKey: "a", composerResetToken: 3 };
  const b = { imageStore, imageKey: "b", composerResetToken: 8 };
  const reads = holdFullReads();
  mount("controlled", a);
  pick(png(), new File(["text"], "bad-a.txt", { type: "text/plain" }));
  await vi.waitFor(() => {
    expect(reads.pending.has("photo.png")).toBe(true);
  });
  mount("controlled", b);
  mount("controlled", a);
  await reads.finish("photo.png");
  expect(status()?.textContent).toContain("bad-a.txt");
  expect(previews()).toHaveLength(1);
});

it("keeps a published refusal when returning to its editor with a different reset token", async () => {
  const imageStore = createControlledImageStore();
  const a = { imageStore, imageKey: "a", composerResetToken: 3 };
  const b = { imageStore, imageKey: "b", composerResetToken: 8 };
  mount("controlled", a);
  pick(heic());
  await vi.waitFor(() => {
    expect(status()?.textContent).toContain("photo.heic");
  });
  mount("controlled", b);
  expect(status()).toBeNull();
  mount("controlled", a);
  expect(status()?.textContent).toContain("photo.heic");
});
