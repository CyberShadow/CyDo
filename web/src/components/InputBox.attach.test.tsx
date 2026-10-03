/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 *
 * The composer's attach button. Paste and drag-and-drop were the only ways to
 * attach an image, which left phones with no way at all: iOS has no file drag
 * source, and gecko-for-iOS does not put pasted photos on the DOM clipboard.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import { InputBox } from "./InputBox";
import {
  createOrdinaryDraftStore,
  type OrdinaryDraftStore,
} from "../ordinaryDraftStore";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

const SESSION = "attach-session";

/** FileReader.readAsDataURL resolves on a task, so let it land. */
const flushReader = () => new Promise((resolve) => setTimeout(resolve, 20));

async function mountComposer(
  container: HTMLElement,
  store: OrdinaryDraftStore,
) {
  await act(() => {
    render(
      <InputBox
        onSend={() => {}}
        onInterrupt={() => {}}
        isProcessing={false}
        stdinClosed={false}
        disabled={false}
        sessionId={SESSION}
        ordinaryDraftStore={store}
      />,
      container,
    );
  });
}

/** A real File whose bytes decode as the given data URL payload. */
function imageFile(name: string, type: string) {
  return new File([new Uint8Array([1, 2, 3, 4])], name, { type });
}

/** Drive the hidden input the way a picker selection does. */
async function selectFiles(container: HTMLElement, files: File[]) {
  const input = container.querySelector<HTMLInputElement>("input.input-file");
  expect(input).not.toBeNull();
  // a FileList stand-in: indexed access, length, item(), and iteration
  const list: Record<string | number | symbol, unknown> = {
    item: (index: number) => files[index] ?? null,
    [Symbol.iterator]: files[Symbol.iterator].bind(files),
  };
  files.forEach((file, index) => {
    list[index] = file;
  });
  list.length = files.length;
  Object.defineProperty(input!, "files", { configurable: true, value: list });
  await act(() => {
    input!.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

describe("composer image attachment", () => {
  let container: HTMLElement;
  let store: OrdinaryDraftStore;

  beforeEach(() => {
    store = createOrdinaryDraftStore();
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  it("offers an attach control that reaches the system picker", async () => {
    await mountComposer(container, store);

    const button = container.querySelector<HTMLButtonElement>(".btn-attach");
    const input = container.querySelector<HTMLInputElement>("input.input-file");
    expect(button).not.toBeNull();
    expect(input).not.toBeNull();
    // accept drives which picker iOS opens; multiple lets a batch through
    expect(input!.getAttribute("accept")).toBe("image/*");
    expect(input!.hasAttribute("multiple")).toBe(true);

    let clicked = false;
    input!.click = () => {
      clicked = true;
    };
    await act(() => {
      button!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(clicked).toBe(true);
  });

  it("attaches picked images as previews", async () => {
    await mountComposer(container, store);
    await selectFiles(container, [
      imageFile("one.jpg", "image/jpeg"),
      imageFile("two.png", "image/png"),
    ]);
    await act(async () => {
      await flushReader();
    });

    expect(container.querySelectorAll(".image-preview img").length).toBe(2);
  });

  it("refuses image types the agent APIs reject, and says so", async () => {
    await mountComposer(container, store);
    await selectFiles(container, [imageFile("photo.heic", "image/heic")]);
    await act(async () => {
      await flushReader();
    });

    expect(container.querySelectorAll(".image-preview img").length).toBe(0);
    const error = container.querySelector(".attach-error");
    expect(error).not.toBeNull();
    expect(error!.textContent).toContain("image/heic");
  });

  it("clears the input so the same photo can be picked twice", async () => {
    await mountComposer(container, store);
    const input = container.querySelector<HTMLInputElement>("input.input-file");
    await selectFiles(container, [imageFile("one.jpg", "image/jpeg")]);
    await act(async () => {
      await flushReader();
    });
    expect(input!.value).toBe("");
  });
});
