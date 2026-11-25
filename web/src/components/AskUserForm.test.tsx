// @vitest-environment jsdom
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
