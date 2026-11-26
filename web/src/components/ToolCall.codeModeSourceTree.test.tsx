// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { beforeAll, expect, it, vi } from "vitest";
import { tokenize } from "../highlight";
import { configureTreeSitterAssets } from "../lib/treeSitterRuntime";
import { actStep, joinedRows } from "../test-support/preactAct";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { ThemeContext } from "../useTheme";
import { ToolCall } from "./ToolCall";
import {
  coloredPre,
  deferred,
  directPreColors,
  expectHighlightedPre,
} from "./ToolCall.shellSourceTree.fixture";

const run = joinedRows();
const body = "# Title\n\nSome *markdown* with a list:\n- a\n- b";
const prefix = "mkdir -p d && tee d/doc.md >/dev/null <<'EOF'";
const command = `${prefix}\n${body}\nEOF`;
const makeCell = (operand: string) =>
  `// @exec: {"yield_time_ms": 1000}\nconst r = await tools.exec_command({cmd: ${operand}});\ntext(r.output);`;
const templateCell = makeCell("`" + command + "`");
const escapedCell = makeCell(JSON.stringify(command));
const tree = '[data-testid="source-tree-input"]';
const rich = ".source-tree-rich-block";
const pre = "pre.write-content";
const addPatch =
  "*** Begin Patch\n*** Add File: docs/a.md\n+# Added\n*** End Patch";
const twoFilePatch = addPatch.replace(
  "*** End Patch",
  "*** Update File: src/x.py\n@@\n-print(1)\n+print(2)\n*** End Patch",
);
const rawPatchCell = `const patch = String.raw\`${twoFilePatch}\`; await tools.apply_patch(patch);`;
const sectionlessPatch = "*** Begin Patch\n@@\n-old\n+new\n*** End Patch";
const patchCell = (patch: string) =>
  `await tools.apply_patch(${JSON.stringify(patch)});`;

function toolInput(cell: string, Component = ToolCall, Theme = ThemeContext) {
  return (
    <Theme.Provider value="dark">
      <Component
        name="exec"
        driver="codex"
        toolUseId="tool-code-mode-source-tree"
        input={{ input: cell }}
      />
    </Theme.Provider>
  );
}

beforeAll(async () => {
  configureTreeSitterAssets(installedTreeSitterBytes);
  await Promise.all([
    tokenize("const x = 1;", "javascript"),
    tokenize(prefix, "bash"),
    tokenize(body, "markdown"),
  ]);
});

it.for([
  ["template", templateCell, body],
  ["double-quoted string", escapedCell, JSON.stringify(body).slice(1, -1)],
] as const)(
  "renders Markdown from a %s operand",
  ([, cell, rawBody], context) =>
    run(context, async ({ root, poll }) => {
      await actStep(() => {
        render(toolInput(cell), root);
      });
      const preview = `${rich} .text-content`;
      const before = `${tree} > ${pre}.source-tree-block-start`;
      const after = `${tree} > ${pre}.source-tree-block-end`;
      const bash = `${before} [data-language="bash"]`;
      await poll(
        {
          description: "rendered Markdown list",
          ready: () => root.querySelectorAll(`${preview} li`).length === 2,
        },
        {
          description: "distinct Bash colors in the command prefix",
          ready: () =>
            new Set(
              Array.from(
                root.querySelectorAll<HTMLSpanElement>(
                  `${bash} span[style*="color"]`,
                ),
                (span) => span.style.color,
              ),
            ).size > 1,
        },
      );
      expect(root.querySelector(`${preview} h1`)?.textContent).toBe("Title");
      expect(root.querySelector(`${preview} em`)?.textContent).toBe("markdown");
      expect(
        Array.from(
          root.querySelectorAll(`${preview} li`),
          (item) => item.textContent,
        ),
      ).toEqual(["a", "b"]);
      expect(root.querySelector(bash)?.textContent).toContain(prefix);
      expect(root.querySelector(before)?.textContent).toContain(
        "const r = await",
      );
      expect(root.querySelector(after)?.textContent).toContain(
        "text(r.output);",
      );

      await actStep(() => {
        root
          .querySelector<HTMLButtonElement>(
            `${rich} button[title="Show source"]`,
          )!
          .click();
      });
      const source = `${rich} pre`;
      await poll(coloredPre(root, source));
      expectHighlightedPre(root, source);
      expect(root.querySelector(source)?.textContent).toBe(rawBody);

      const writeText = vi
        .fn<(text: string) => Promise<void>>()
        .mockResolvedValue(undefined);
      const originalClipboard = Object.getOwnPropertyDescriptor(
        navigator,
        "clipboard",
      );
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText },
      });
      try {
        await actStep(() => {
          root
            .querySelector<HTMLButtonElement>(
              `${tree} > button[title="Copy to clipboard"]`,
            )!
            .click();
        });
        expect(writeText.mock.calls).toEqual([[cell]]);
      } finally {
        if (originalClipboard)
          Object.defineProperty(navigator, "clipboard", originalClipboard);
        else Reflect.deleteProperty(navigator, "clipboard");
      }
    }),
);

it.for([
  ["template", templateCell],
  ["double-quoted string", escapedCell],
] as const)(
  "highlights JavaScript on both sides of a %s operand",
  ([, cell], context) =>
    run(context, async ({ root, poll }) => {
      await actStep(() => {
        render(toolInput(cell), root);
      });
      const before = `${tree} > ${pre}.source-tree-block-start`;
      const after = `${tree} > ${pre}.source-tree-block-end`;
      await poll(coloredPre(root, before), coloredPre(root, after));
      expect(
        new Set(directPreColors(root, before)).size,
        "JavaScript before the operand",
      ).toBeGreaterThan(1);
      expect(
        new Set(directPreColors(root, after)).size,
        "JavaScript after the operand",
      ).toBeGreaterThan(1);
    }),
);

function expectWholeCell(root: HTMLElement, cell: string) {
  expect(root.querySelector(rich)).toBeNull();
  expect(root.querySelectorAll(pre)).toHaveLength(1);
  expect(root.querySelector(pre)?.textContent).toBe(cell);
  expect(new Set(expectHighlightedPre(root, pre)).size).toBeGreaterThan(1);
}

it("renders the same two-file patch list in a cell and a direct tool call", (context) =>
  run(context, async ({ root, poll }) => {
    await actStep(() => {
      render(
        <>
          <div id="cell">{toolInput(rawPatchCell)}</div>
          <div id="direct">
            <ThemeContext.Provider value="dark">
              <ToolCall
                name="apply_patch"
                driver="codex"
                toolUseId="tool-direct-apply-patch"
                input={{ input: twoFilePatch }}
              />
            </ThemeContext.Provider>
          </div>
        </>,
        root,
      );
    });
    const cellList = `#cell ${rich} .filechange-list`;
    const directList = "#direct .filechange-list";
    await poll(
      coloredPre(root, `${cellList} pre`),
      coloredPre(root, `${directList} pre`),
      {
        description: "Markdown preview in both patch lists",
        ready: () =>
          root.querySelector(`${cellList} h1`)?.textContent === "Added" &&
          root.querySelector(`${directList} h1`)?.textContent === "Added",
      },
    );
    expect(
      root.querySelectorAll(`${cellList} .filechange-change`),
    ).toHaveLength(2);
    expect(root.querySelector(cellList)!.outerHTML).toBe(
      root.querySelector(directList)!.outerHTML,
    );
  }));

it("shows the action and path for a single-file patch in a cell", (context) =>
  run(context, async ({ root, poll }) => {
    await actStep(() => {
      render(toolInput(patchCell(addPatch)), root);
    });
    const list = `${rich} .filechange-list`;
    await poll({
      description: "single-file patch in the rich block",
      ready: () =>
        root.querySelectorAll(`${list} .filechange-change`).length === 1,
    });
    const meta = root.querySelector(`${list} .filechange-meta`);
    expect(meta?.querySelector(".tool-subtitle-tag")?.textContent).toBe("Add");
    expect(meta?.textContent).toContain("docs/a.md");
  }));

it("shows a diff-highlighted fallback for a patch with no file sections", (context) =>
  run(context, async ({ root, poll }) => {
    const tokens = await tokenize(sectionlessPatch, "diff");
    expect(tokens).not.toBeNull();
    const style = document.createElement("span").style;
    const diffColors = tokens!.flat().map(({ color }) => {
      style.color = color ?? "";
      return style.color;
    });
    await actStep(() => {
      render(toolInput(patchCell(sectionlessPatch)), root);
    });
    const fallback = `${rich} ${pre}`;
    await poll(coloredPre(root, fallback));
    expect(root.querySelector(`${rich} .filechange-list`)).toBeNull();
    expect(root.querySelector(fallback)?.textContent).toBe(sectionlessPatch);
    expect(expectHighlightedPre(root, fallback)).toEqual(diffColors);
  }));

it("shows a single highlighted JavaScript pre for a malformed cell", (context) =>
  run(context, async ({ root, poll }) => {
    const cell = 'await tools.exec_command({cmd: "echo hi"';
    // Wait for the real analysis to settle before checking the steady-state view.
    const { analyzeEmbedded } = await import("../lib/embeddedFlow");
    await act(async () => {
      render(toolInput(cell), root);
      await analyzeEmbedded("codex-code-mode", cell);
    });
    await poll(coloredPre(root, pre));
    expectWholeCell(root, cell);
  }));

it.for(["loads", "fails"] as const)(
  "keeps the whole cell highlighted while the JavaScript grammar %s",
  (outcome, context) =>
    run(context, async ({ root, poll, signal }) => {
      // Grammar initialization is cached for the life of the module.
      vi.resetModules();
      const [
        { configureTreeSitterAssets },
        { ToolCall },
        { analyzeEmbedded },
        { ThemeContext: FreshTheme },
      ] = await Promise.all([
        import("../lib/treeSitterRuntime"),
        import("./ToolCall"),
        import("../lib/embeddedFlow"),
        import("../useTheme"),
      ]);
      const gate = deferred<Uint8Array>(signal);
      const loadLanguage = vi.fn((grammar: "javascript" | "bash") =>
        grammar === "javascript"
          ? gate.promise
          : installedTreeSitterBytes.loadLanguage(grammar),
      );
      configureTreeSitterAssets({ ...installedTreeSitterBytes, loadLanguage });

      await actStep(() => {
        render(toolInput(templateCell, ToolCall, FreshTheme), root);
      });
      await poll(coloredPre(root, pre));
      expect(loadLanguage.mock.calls).toEqual([["javascript"]]);
      expect(root.querySelector(tree)).toBeNull();
      expectWholeCell(root, templateCell);

      const pending = analyzeEmbedded("codex-code-mode", templateCell);
      if (outcome === "loads") {
        await act(async () => {
          gate.resolve(
            await installedTreeSitterBytes.loadLanguage("javascript"),
          );
          await pending;
        });
        await poll({
          description: "Markdown after the JavaScript grammar loads",
          ready: () =>
            root.querySelector(`${tree} ${rich} h1`)?.textContent === "Title",
        });
      } else {
        const failure = new Error("JavaScript grammar load failed");
        await act(async () => {
          gate.reject(failure);
          await expect(pending).rejects.toBe(failure);
        });
        await actStep();
        expect(root.querySelector(tree)).toBeNull();
        expectWholeCell(root, templateCell);
      }
    }),
);
