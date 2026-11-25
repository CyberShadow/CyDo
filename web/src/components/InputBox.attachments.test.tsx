/** @vitest-environment jsdom */
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createControlledImageStore } from "../controlledImageStore";
import { createOrdinaryDraftStore } from "../ordinaryDraftStore";
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
    imageStore?: ReturnType<typeof createControlledImageStore>;
  } = {},
) {
  const common = {
    isProcessing: false,
    onInterrupt: () => {},
    disabled: false,
    ...options,
  };
  void act(() => {
    render(
      mode === "ordinary" ? (
        <InputBox
          {...common}
          sessionId="session"
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
    heic(),
    png(),
    new File(["image"], "unknown.heic"),
    new File(["text"], "notes.txt", { type: "text/plain" }),
  );

  await vi.waitFor(() => {
    expect(previews()).toHaveLength(1);
  });
  expect(previews()[0]?.getAttribute("src")).toMatch(/^data:image\/png;/);
  expect(status()?.textContent).toContain(
    "photo.heic (image/heic), unknown.heic, notes.txt (text/plain)",
  );
  expect(status()?.textContent).not.toContain("photo.png");
});

it("clears a refusal when sending a text-only suggestion", async () => {
  const onSend = vi.fn();
  const suggestion = "Describe the project";
  void act(() => {
    render(
      <InputBox
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

it.each(["paste", "drop"] as const)("names refused files from %s", (kind) => {
  mount("ordinary");
  const event = transfer(kind, [
    new File(["text"], "notes.txt", { type: "text/plain" }),
  ]);
  expect(event.defaultPrevented).toBe(true);
  expect(status()?.textContent).toContain("notes.txt (text/plain)");
  expect(previews()).toHaveLength(0);
});

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

it.each(modes)("blocks intake when the %s composer is disabled", (mode) => {
  mount(mode, { disabled: true });
  expect(attach().disabled).toBe(true);
  expect(picker().disabled).toBe(true);

  const read = vi.spyOn(FileReader.prototype, "readAsDataURL");
  pick(png(), heic());
  expect(transfer("paste", [png(), heic()]).defaultPrevented).toBe(true);
  expect(transfer("drop", [png(), heic()]).defaultPrevented).toBe(true);

  expect(read).not.toHaveBeenCalled();
  expect(status()).toBeNull();
  expect(previews()).toHaveLength(0);
});

it.each(modes)(
  "disables the picker when stdin is closed in the %s composer",
  (mode) => {
    mount(mode, { stdinClosed: true });
    expect(attach().disabled).toBe(true);
    expect(picker().disabled).toBe(true);
  },
);

it("clears a refusal when switching controlled editors", () => {
  const imageStore = createControlledImageStore();
  mount("controlled", { imageStore, imageKey: "first" });
  pick(heic());
  expect(status()?.textContent).toContain("photo.heic");

  mount("controlled", { imageStore, imageKey: "second" });
  expect(status()).toBeNull();
});

it("clears a refusal when resetting a controlled editor", () => {
  mount("controlled", { composerResetToken: 1 });
  pick(heic());
  expect(status()?.textContent).toContain("photo.heic");

  mount("controlled", { composerResetToken: 2 });
  expect(status()).toBeNull();
});
