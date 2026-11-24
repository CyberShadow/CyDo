/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { actStep, ownedRoots } from "../test-support/preactAct";
import { act } from "preact/test-utils";
import type {
  DraftView,
  DraftViewSnapshot,
  UnresolvedDraftView,
} from "../useSessionManager";

vi.hoisted(() => {
  vi.stubGlobal("CSS", {
    supports: () => false,
    escape: (value: string) => value,
  });
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener: () => {},
    removeEventListener: () => {},
  }));
});

import {
  createControlledImageStore,
  retireControlledImage,
} from "../controlledImageStore";
import { DraftSessionView } from "./SessionView";

const entryPoints = [
  {
    name: "implement",
    task_type: "implement",
    description: "Implement a change",
    model_class: "general",
    read_only: false,
  },
  {
    name: "test",
    task_type: "test",
    description: "Test a change",
    model_class: "general",
    read_only: false,
  },
];

const agents = [
  { name: "codex", driver: "codex" },
  { name: "claude", driver: "claude" },
];

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

  return {
    complete() {
      for (const reader of readers.splice(0)) {
        reader.onload?.({
          target: { result: "data:image/png;base64,aW1hZ2U=" },
        } as ProgressEvent<FileReader>);
      }
    },
    restore() {
      readAsDataURL.mockRestore();
    },
  };
}

describe("DraftSessionView draft availability", () => {
  const roots = ownedRoots();
  let container: HTMLDivElement;

  const mount = (
    draftView: DraftView,
    imageStore?: ReturnType<typeof createControlledImageStore>,
  ) => {
    roots.render(
      <DraftSessionView
        key={draftView.viewKey}
        draftView={draftView}
        imageStore={imageStore}
        connected={true}
        tasksLoading={false}
        entryPoints={entryPoints}
        agents={agents}
        defaultAgent="codex"
        theme="dark"
        onToggleTheme={() => {}}
        onToggleSidebar={() => {}}
      />,
      container,
    );
  };

  const controls = () => ({
    taskTypePicker:
      container.querySelector<HTMLDivElement>(".task-type-picker")!,
    taskTypeButtons: Array.from(
      container.querySelectorAll<HTMLButtonElement>(".task-type-row"),
    ),
    agentPicker: container.querySelector<HTMLSelectElement>(".agent-picker")!,
    textarea: container.querySelector<HTMLTextAreaElement>("textarea")!,
    send: container.querySelector<HTMLButtonElement>(".btn-send")!,
  });

  const expectFullyDisabledControls = () => {
    const { taskTypePicker, taskTypeButtons, agentPicker, textarea, send } =
      controls();

    expect(taskTypePicker.tabIndex).toBe(-1);
    expect(taskTypeButtons).toHaveLength(2);
    for (const button of taskTypeButtons) expect(button.disabled).toBe(true);
    expect(agentPicker.disabled).toBe(true);
    expect(textarea.disabled).toBe(true);
    expect(send.disabled).toBe(true);
  };

  beforeEach(() => {
    container = roots.create();
  });

  it("discards a pending image read from the retired editor after clear", async () => {
    const reader = mockImageReader();
    const store = createControlledImageStore();
    const editorId = "composition:discarded";
    const successor: DraftViewSnapshot = {
      kind: "resolved",
      editorId: "composition:successor",
      viewKey: "composition:successor",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: null,
      text: "",
      entryPoint: "implement",
      agent: "codex",
      lifecycle: "idle",
      disabled: false,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange: vi.fn(),
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    };
    try {
      mount(
        { ...successor, editorId, viewKey: editorId, text: "discard" },
        store,
      );
      await actStep(() => {
        pasteImage(controls().textarea);
        reader.complete();
        pasteImage(controls().textarea);
      });
      const entry = store.entries.get(editorId)!;
      expect(entry.images).toHaveLength(1);
      mount(successor, store);
      await actStep(() => {
        reader.complete();
      });
      expect(entry.images).toHaveLength(2);
      mount(
        { ...successor, editorId, viewKey: editorId, text: "discard" },
        store,
      );
      expect(container.querySelectorAll(".image-preview")).toHaveLength(2);
      await actStep(() => pasteImage(controls().textarea));
      await act(() => {
        retireControlledImage(store, editorId);
      });
      mount(successor, store);
      await actStep(() => {
        reader.complete();
      });
      expect(store.entries.has(editorId)).toBe(false);
      expect(entry.images).toEqual([]);
      expect(store.entries.get(successor.editorId)?.images).toEqual([]);
      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      reader.restore();
    }
  });

  it("rejects pasted attachments while route metadata is unresolved", async () => {
    const imageReader = mockImageReader();
    const draftView: UnresolvedDraftView = {
      kind: "unresolved",
      viewKey: "route:workspace\\0project",
      workspace: "workspace",
      projectName: "project",
      projectPath: "",
      remoteTid: null,
      text: "",
      entryPoint: "",
      agent: "",
      lifecycle: "idle",
      disabled: true,
      metadataReady: false,
      submitReady: false,
      composerResetToken: 0,
    };

    try {
      mount(draftView);

      expectFullyDisabledControls();
      await actStep(() => {
        pasteImage(controls().textarea);
        imageReader.complete();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      imageReader.restore();
    }
  });

  it("keeps the composer enabled while metadata blocks configuration and send", async () => {
    const onTextChange = vi.fn();
    const onEntryPointChange = vi.fn();
    const onAgentChange = vi.fn();
    const onSubmit = vi.fn();
    const draftView = {
      kind: "resolved",
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: null,
      text: "typing before metadata",
      entryPoint: "",
      agent: "",
      lifecycle: "idle",
      disabled: false,
      metadataReady: false,
      submitReady: false,
      composerResetToken: 0,
      onTextChange,
      onEntryPointChange,
      onAgentChange,
      onSubmit,
    } satisfies DraftViewSnapshot;

    mount(draftView);

    const { taskTypePicker, taskTypeButtons, agentPicker, textarea, send } =
      controls();
    expect(taskTypePicker.tabIndex).toBe(-1);
    for (const button of taskTypeButtons) expect(button.disabled).toBe(true);
    expect(agentPicker.disabled).toBe(true);
    expect(textarea.disabled).toBe(false);
    expect(send.disabled).toBe(true);

    await actStep(() => {
      textarea.value = "updated before metadata";
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(onTextChange).toHaveBeenCalledWith("updated before metadata");

    await act(() => {
      taskTypeButtons[1]!.click();
      agentPicker.value = "claude";
      agentPicker.dispatchEvent(new Event("change", { bubbles: true }));
      send.click();
    });
    expect(onEntryPointChange).not.toHaveBeenCalled();
    expect(onAgentChange).not.toHaveBeenCalled();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("keeps the picker enabled and Submit disabled for an unlisted entry point", async () => {
    const onEntryPointChange = vi.fn();
    const onTextChange = vi.fn();
    const onSubmit = vi.fn();
    mount({
      kind: "resolved",
      editorId: "task:95",
      viewKey: "task:95",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: 95,
      text: "still editable",
      entryPoint: "unlisted",
      agent: "codex",
      lifecycle: "present",
      disabled: false,
      metadataReady: true,
      submitReady: false,
      composerResetToken: 0,
      onTextChange,
      onEntryPointChange,
      onAgentChange: vi.fn(),
      onSubmit,
    });
    const { taskTypeButtons, agentPicker, textarea, send } = controls();
    expect(container.querySelector(".task-type-row.selected")).toBeNull();
    expect(taskTypeButtons.every((button) => !button.disabled)).toBe(true);
    expect(agentPicker.disabled).toBe(false);
    expect(textarea.disabled).toBe(false);
    expect(send.disabled).toBe(true);
    await actStep(() => {
      textarea.value = "next edit";
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
      textarea.blur();
      send.click();
      taskTypeButtons[0]!.click();
    });
    expect(onTextChange).toHaveBeenCalledExactlyOnceWith("next edit");
    expect(onEntryPointChange).toHaveBeenCalledExactlyOnceWith("implement");
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("rejects dropped attachments while a resolved draft is submitting", async () => {
    const imageReader = mockImageReader();
    const onEntryPointChange = vi.fn();
    const draftView = {
      kind: "resolved",
      editorId: "composition:test" as const,
      viewKey: "composition:test",
      workspace: "workspace",
      projectName: "project",
      projectPath: "/project",
      remoteTid: 71,
      text: "submit this",
      entryPoint: "implement",
      agent: "codex",
      lifecycle: "submitting",
      disabled: true,
      metadataReady: true,
      submitReady: true,
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange,
      onAgentChange: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    try {
      mount(draftView);
      expectFullyDisabledControls();
      expect(container.querySelector("textarea")?.value).toBe("submit this");
      expect(container.querySelector(".btn-send")?.textContent).toBe(
        "Submitting…",
      );

      const { taskTypePicker, taskTypeButtons } = controls();
      await act(() => {
        taskTypePicker.dispatchEvent(
          new KeyboardEvent("keydown", { bubbles: true, key: "ArrowDown" }),
        );
        taskTypeButtons[1]!.dispatchEvent(
          new MouseEvent("click", { bubbles: true }),
        );
      });
      expect(onEntryPointChange).not.toHaveBeenCalled();

      await actStep(() => {
        dropImage(container.querySelector<HTMLElement>(".input-box")!);
        imageReader.complete();
      });

      expect(container.querySelectorAll(".image-preview")).toHaveLength(0);
    } finally {
      imageReader.restore();
    }
  });
});
