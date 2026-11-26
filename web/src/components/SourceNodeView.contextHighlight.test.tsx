// @vitest-environment jsdom
import { render } from "preact";
import { beforeAll, expect, it } from "vitest";
import { tokenize } from "../highlight";
import { loadParsedShellDocument } from "../lib/shellParser";
import { buildShellSourceTree } from "../lib/shellSourceTree";
import type { SourceNode } from "../lib/sourceTree";
import { configureTreeSitterAssets } from "../lib/treeSitterRuntime";
import { actStep, joinedRows, type JoinedRow } from "../test-support/preactAct";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { ThemeContext } from "../useTheme";
import { SourceNodeView } from "./SourceNodeView";

const run = joinedRows();
const payload = "printf x";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

async function shikiColors(text: string, language: string) {
  const tokens = await tokenize(text, language, "github-dark");
  if (!tokens) throw new Error(`No Shiki tokens for ${language}`);

  const style = document.createElement("span").style;
  const colors = new Array<string>(text.length).fill("");
  for (const token of tokens.flat()) {
    style.color = token.color ?? "";
    colors.fill(style.color, token.offset, token.offset + token.content.length);
  }
  return colors;
}

function renderedColors(pre: HTMLPreElement) {
  const colors: string[] = [];
  const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const span = node.parentElement?.closest<HTMLElement>("span[style]");
    const color = span?.style.color ?? "";
    for (let i = 0; i < node.textContent!.length; i++) colors.push(color);
  }
  return colors;
}

async function expectContextHighlight(
  { root, poll }: JoinedRow,
  source: SourceNode,
  embedStart: number,
) {
  const parentColors = await shikiColors(source.text, source.language);
  const payloadColors = await shikiColors(payload, "bash");
  const suffixStart = embedStart + payload.length;

  await actStep(() => {
    render(
      <ThemeContext.Provider value="dark">
        <SourceNodeView root={source} copyText={source.text} />
      </ThemeContext.Provider>,
      root,
    );
  });

  const pre = root.querySelector("pre")!;
  await poll({
    description: "source tree syntax highlighting",
    ready: () => pre.querySelector("span[style*='color']") !== null,
  });
  expect(pre.textContent).toBe(source.text);
  const colors = renderedColors(pre);
  expect(colors.slice(embedStart, suffixStart)).toEqual(payloadColors);
  expect(colors.slice(suffixStart)).toEqual(parentColors.slice(suffixStart));
}

it("preserves whole-command Bash colors after a quoted shell wrapper payload", (context) =>
  run(context, async (row) => {
    const command = 'zsh -lc "printf x" && echo done';
    const parsed = await loadParsedShellDocument(command);
    if (!parsed.ok) throw new Error(parsed.reason);
    const tree = buildShellSourceTree(parsed.document);
    if (!tree.ok) throw new Error(tree.reason);
    await expectContextHighlight(row, tree.value, command.indexOf(payload));
  }));

it("preserves the closing backtick and following JavaScript colors after an embedded Bash template body", (context) =>
  run(context, async (row) => {
    const prefix = "const cmd = `";
    const text = prefix + payload + "`; const exitCode = 0;";
    const start = prefix.length;
    const end = start + payload.length;
    const source: SourceNode = {
      language: "javascript",
      text,
      segments: [
        { kind: "text", span: { start: 0, end: start } },
        {
          kind: "embed",
          span: { start, end },
          content: {
            language: "bash",
            text: payload,
            segments: [
              { kind: "text", span: { start: 0, end: payload.length } },
            ],
          },
        },
        { kind: "text", span: { start: end, end: text.length } },
      ],
    };
    await expectContextHighlight(row, source, start);
  }));
