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

  const mount = (draftView: DraftView) => {
    roots.render(
      <DraftSessionView
        draftView={draftView}
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
      projectKey: "workspace\0/project",
      viewKey: "workspace\0/project",
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
      composerResetToken: 0,
      onTextChange,
      onEntryPointChange,
      onAgentChange,
      onBlur: vi.fn(),
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

  it("rejects dropped attachments while a resolved draft is submitting", async () => {
    const imageReader = mockImageReader();
    const onEntryPointChange = vi.fn();
    const draftView = {
      kind: "resolved",
      projectKey: "workspace\\0/project",
      viewKey: "workspace\\0/project",
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
      composerResetToken: 0,
      onTextChange: vi.fn(),
      onEntryPointChange,
      onAgentChange: vi.fn(),
      onBlur: vi.fn(),
      onSubmit: vi.fn(),
    } satisfies DraftViewSnapshot;

    try {
      mount(draftView);
      expectFullyDisabledControls();

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
