// @vitest-environment jsdom
import { h } from "preact";
import { expect, it } from "vitest";
import { actPoll, actStep, ownedRoots } from "../test-support/preactAct";
import { DiffView, HunkDiffView } from "./diff/DiffView";
import { FileContentPreview } from "./file-preview/FileContentPreview";
import { Markdown } from "./Markdown";
import { OutputPlanView } from "./OutputPlanView";

const roots = ownedRoots();
const endings = [
  { ending: "with a final newline", suffix: "\r\n" },
  { ending: "without a final newline", suffix: "" },
];

async function expectHighlightedText(root: HTMLElement, source: string) {
  await actPoll({
    description: "highlighted source",
    ready: () => root.querySelector("pre span[style*='color']") !== null,
  });
  expect(root.querySelector("pre")!.textContent).toBe(source);
}

it.each(endings)(
  "preserves highlighted typed output $ending",
  async ({ suffix }) => {
    const stdout = `const first = 1;\r\n\nconst second =\r 2;\nconst third = 3;${suffix}`;
    const root = roots.create();
    await actStep(() => {
      roots.render(
        h(OutputPlanView, {
          stdout,
          outputPlan: {
            version: 1,
            blocks: [
              {
                id: "code",
                format: { kind: "content", language: "typescript" },
                location: {
                  kind: "from-cursor",
                  end: { kind: "end-of-output", requiresComplete: true },
                  validator: "non-empty",
                },
              },
            ],
          },
        }),
        root,
      );
    });
    await expectHighlightedText(root, stdout);
  },
);

it.each(endings)(
  "preserves highlighted SVG source $ending",
  async ({ suffix }) => {
    const content = `<svg xmlns="http://www.w3.org/2000/svg">\r\n\n  <text>first\rsecond</text>\n</svg>${suffix}`;
    const root = roots.create();
    await actStep(() => {
      roots.render(h(FileContentPreview, { filePath: "x.svg", content }), root);
    });
    expect(root.querySelector('[alt="SVG preview"]')).not.toBeNull();
    await actStep(() => {
      root.querySelector<HTMLButtonElement>('[title="Show source"]')!.click();
    });
    await expectHighlightedText(root, content);
  },
);

it.each([
  { name: "empty", body: "", expected: "" },
  { name: "one blank line", body: "\n", expected: "" },
  { name: "one source line", body: "x\n", expected: "x\n" },
  { name: "a final blank line", body: "x\n\n", expected: "x\n\n" },
])(
  "renders a normalized Markdown fence body with $name",
  async ({ body, expected }) => {
    const root = roots.create();
    await actStep(() => {
      roots.render(
        h(Markdown, { text: "```typescript\n" + body + "```\n" }),
        root,
      );
    });
    if (expected) {
      await expectHighlightedText(root, expected);
    } else {
      expect(root.querySelector("pre")?.textContent).toBe("");
    }
  },
);

it("highlights an unclosed Markdown fence as its body streams in", async () => {
  const root = roots.create();
  const fence = "```typescript\n";
  await actStep(() => {
    roots.render(h(Markdown, { text: fence }), root);
  });
  await actStep(() => {
    roots.render(h(Markdown, { text: fence + "const x = 1;\n" }), root);
  });
  await expectHighlightedText(root, "const x = 1;\n");
});

const diffPayload = "const x =\r 1;\r";

it.each([
  {
    name: "file diff",
    view: () =>
      h(DiffView, {
        filePath: "x.ts",
        oldStr: "const y = 2;\r\n" + diffPayload,
        newStr: "const y = 2;\r\n" + diffPayload,
      }),
    rowTexts: ["  const y = 2;", "  " + diffPayload],
  },
  {
    name: "hunk diff",
    view: () =>
      h(HunkDiffView, {
        filePath: "x.ts",
        hunks: [
          {
            oldStart: 4,
            oldLines: 2,
            newStart: 7,
            newLines: 2,
            lines: [" " + diffPayload, " const y = 2;"],
          },
        ],
      }),
    rowTexts: ["47  " + diffPayload, "58  const y = 2;"],
  },
])(
  "preserves bare CRs in a highlighted $name context row",
  async ({ view, rowTexts }) => {
    const root = roots.create();
    await actStep(() => {
      roots.render(view(), root);
    });
    await actPoll({
      description: "highlighted diff context",
      ready: () =>
        root.querySelector(".diff-context span[style*='color']") !== null,
    });
    const rows = root.querySelectorAll(".diff-context");
    expect(Array.from(rows, (row) => row.textContent)).toEqual(rowTexts);
  },
);
