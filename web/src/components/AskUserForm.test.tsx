// @vitest-environment jsdom
import { createRef } from "preact";
import { act } from "preact/test-utils";
import { expect, it, vi } from "vitest";
import { ownedRoots } from "../test-support/preactAct";
import { AskUserForm } from "./AskUserForm";
import { LocalFileContext } from "./LocalFileContext";

const roots = ownedRoots();

it("selects an option when its inert local file label is clicked", async () => {
  const root = roots.create();
  const onSubmit = vi.fn();
  const onAbort = vi.fn();
  const openInFileViewer = vi.fn();
  const access = { tid: 7, baseDir: "/w", ancestorPaths: [], openInFileViewer };
  await act(() => {
    roots.render(
      <LocalFileContext.Provider value={access}>
        <AskUserForm
          questions={[
            {
              question: "Pick a report",
              header: "Report",
              options: [
                { label: "First", description: "![Report](report.md)" },
              ],
            },
          ]}
          onSubmit={onSubmit}
          onAbort={onAbort}
        />
      </LocalFileContext.Provider>,
      root,
    );
  });

  const option = root.querySelector(".ask-option-btn")!;
  const label = option.querySelector<HTMLElement>(".local-file-link-inert")!;
  expect(label.textContent).toBe("Report");
  expect(option.querySelector("a, button, figure")).toBeNull();

  await act(() => {
    label.click();
  });

  expect(option.classList.contains("selected")).toBe(true);
  expect(option.querySelector("a, button, figure")).toBeNull();
  expect(openInFileViewer).not.toHaveBeenCalled();
  expect(onSubmit).not.toHaveBeenCalled();
  expect(onAbort).not.toHaveBeenCalled();
});

function renderQuoteForm() {
  const root = roots.create();
  const insertTextRef = createRef<(text: string) => void>();
  const onSubmit = vi.fn();
  roots.render(
    <AskUserForm
      questions={["First", "Second"].map((header) => ({
        question: `${header} question`,
        header,
        options: [{ label: "Standard", description: "" }],
        multiSelect: true,
      }))}
      onSubmit={onSubmit}
      onAbort={() => {}}
      insertTextRef={insertTextRef}
    />,
    root,
  );
  const others = root.querySelectorAll<HTMLButtonElement>("button.other");
  const inputs = () => root.querySelectorAll<HTMLTextAreaElement>("textarea");
  return { root, insertTextRef, onSubmit, others, inputs };
}

it("exposes an inserter only while an Other answer is open", async () => {
  const { insertTextRef, others } = renderQuoteForm();
  expect(insertTextRef.current).toBeNull();

  await act(() => {
    others[0]!.click();
  });
  expect(insertTextRef.current).toBeTypeOf("function");

  await act(() => {
    others[0]!.click();
  });
  expect(insertTextRef.current).toBeNull();
});

it("appends the exact quote to the only open Other answer", async () => {
  const { root, insertTextRef, onSubmit, others, inputs } = renderQuoteForm();
  await act(() => {
    others[1]!.click();
  });
  const input = inputs()[0]!;
  await act(() => {
    input.value = "Existing text  ";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.setSelectionRange(0, 8);
  });

  await act(() => {
    insertTextRef.current!("> quote\n\n");
  });
  expect(input.value).toBe("Existing text\n\n> quote\n\n");

  await act(() => {
    root.querySelector<HTMLButtonElement>(".ask-submit-btn")!.click();
  });
  expect(onSubmit).toHaveBeenCalledWith({
    "First question": "",
    "Second question": "Existing text\n\n> quote\n\n",
  });
});

it("quotes into the most recently focused Other answer", async () => {
  const { insertTextRef, others, inputs } = renderQuoteForm();
  await act(() => {
    others[0]!.click();
  });
  await act(() => {
    others[1]!.click();
  });
  const [first, second] = inputs();
  expect(document.activeElement).toBe(second);

  await act(() => {
    insertTextRef.current!("> Autofocused\n\n");
  });
  expect(first!.value).toBe("");
  expect(second!.value).toBe("> Autofocused\n\n");

  await act(() => {
    first!.focus();
  });
  await act(() => {
    insertTextRef.current!("> Refocused\n\n");
  });
  expect(first!.value).toBe("> Refocused\n\n");
  expect(second!.value).toBe("> Autofocused\n\n");
});

it("falls back to the remaining Other answer when the focused one closes", async () => {
  const { insertTextRef, others, inputs } = renderQuoteForm();
  await act(() => {
    others[0]!.click();
  });
  await act(() => {
    others[1]!.click();
  });
  const [first, second] = inputs();
  await act(() => {
    first!.focus();
  });
  await act(() => {
    others[0]!.click();
  });

  await act(() => {
    insertTextRef.current!("> Fallback\n\n");
  });
  expect(second!.value).toBe("> Fallback\n\n");
});
