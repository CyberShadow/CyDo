/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 *
 * Image intake through the composer: every file handed over must either
 * become a visible attachment or a visible refusal. A photo that vanishes
 * with no trace is indistinguishable from a broken composer.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import { InputBox, drafts } from "./InputBox";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

const SESSION = "attach-session";

/** FileReader.readAsDataURL and the type sniffer resolve on tasks; let them land. */
const flushAsync = () => new Promise((resolve) => setTimeout(resolve, 60));

async function mountComposer(container: HTMLElement) {
  await act(() => {
    render(
      <InputBox
        onSend={() => {}}
        onInterrupt={() => {}}
        isProcessing={false}
        stdinClosed={false}
        disabled={false}
        sessionId={SESSION}
      />,
      container,
    );
  });
}

/** A File with the leading bytes of the named format, typed as the browser
 *  would type it (an empty type is what Gecko assigns to .heic). */
function imageFile(name: string, type: string, magic?: number[]) {
  const bytes = magic ??
    {
      "image/jpeg": [0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46],
      "image/png": [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    }[type] ?? [1, 2, 3, 4];
  return new File([new Uint8Array(bytes)], name, { type });
}

/** bytes 4..12 of an iPhone camera HEIC: "ftypheic" */
const HEIC_MAGIC = [
  0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63,
];

/** Deliver files the way a drag-and-drop does. */
async function dropFiles(container: HTMLElement, files: File[]) {
  const box = container.querySelector<HTMLElement>(".input-box");
  expect(box).not.toBeNull();
  // a FileList stand-in: indexed access, length, item(), and iteration
  const list: Record<string | number | symbol, unknown> = {
    item: (index: number) => files[index] ?? null,
    [Symbol.iterator]: files[Symbol.iterator].bind(files),
  };
  files.forEach((file, index) => {
    list[index] = file;
  });
  list.length = files.length;
  const event = new Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", {
    value: { files: list, types: ["Files"] },
  });
  await act(() => {
    box!.dispatchEvent(event);
  });
}

describe("composer image attachment", () => {
  let container: HTMLElement;

  beforeEach(() => {
    drafts.clear();
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  it("attaches dropped images as previews", async () => {
    await mountComposer(container);
    await dropFiles(container, [
      imageFile("one.jpg", "image/jpeg"),
      imageFile("two.png", "image/png"),
    ]);
    await act(async () => {
      await flushAsync();
    });

    expect(container.querySelectorAll(".image-preview img").length).toBe(2);
  });

  it("refuses image types nothing downstream can use, and says so", async () => {
    await mountComposer(container);
    await dropFiles(container, [imageFile("scan.bmp", "image/bmp")]);
    await act(async () => {
      await flushAsync();
    });

    expect(container.querySelectorAll(".image-preview").length).toBe(0);
    const error = container.querySelector(".attach-error");
    expect(error).not.toBeNull();
    expect(error!.textContent).toContain("image/bmp");
  });

  it("recognizes a HEIC photo by its bytes even with no browser-assigned type", async () => {
    await mountComposer(container);
    // gecko has no mime entry for .heic, so the File arrives with type ""
    await dropFiles(container, [imageFile("IMG_0001.HEIC", "", HEIC_MAGIC)]);
    await act(async () => {
      await flushAsync();
    });

    // nothing silently dropped: a chip stands in for the undecodable preview
    expect(container.querySelector(".attach-error")).toBeNull();
    const label = container.querySelector(".image-preview-label");
    expect(label).not.toBeNull();
    expect(label!.textContent).toContain("HEIC");
    expect(container.querySelectorAll(".image-preview img").length).toBe(0);
  });

  it("names an unrecognized file instead of dropping it silently", async () => {
    await mountComposer(container);
    await dropFiles(container, [imageFile("mystery.bin", "", [0, 1, 2, 3])]);
    await act(async () => {
      await flushAsync();
    });

    const error = container.querySelector(".attach-error");
    expect(error).not.toBeNull();
    expect(error!.textContent).toContain("mystery.bin");
  });
});
