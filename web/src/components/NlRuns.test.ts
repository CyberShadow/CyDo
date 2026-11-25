// @vitest-environment jsdom
import { h } from "preact";
import { assert, beforeAll, expect, it } from "vitest";
import fixtures from "../lib/nlRuns.test-fixtures.json";
import { segmentOutput } from "../lib/outputPlan";
import { shellOutputView } from "../lib/shellOutput";
import { configureTreeSitterAssets } from "../lib/treeSitterRuntime";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { parseShellSemantic } from "../lib/shellSemantic";
import { actPoll, ownedRoots } from "../test-support/preactAct";
import {
  hasSemanticShellOutput,
  SemanticShellOutput,
} from "./SemanticShellOutput";

const roots = ownedRoots();

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

async function mixedNumberedView(command = "nl -ba a.d && nl -ba b.py") {
  const result = await parseShellSemantic(command);
  assert(result.ok && result.value.kind === "output");
  const view = shellOutputView(result.value.output);
  assert(view.ok && view.value.kind === "plan");
  return view.value;
}

it("highlights each GNU nl run with its own grammar in one block", async () => {
  const { plan: outputPlan, search } = await mixedNumberedView();
  const root = roots.create();
  roots.render(
    h(SemanticShellOutput, { stdout: fixtures.all, outputPlan, search }),
    root,
  );

  expect(
    root.querySelectorAll(".semantic-shell-structured-piece"),
  ).toHaveLength(1);
  const pre = root.querySelector("pre");
  assert(pre);
  const prefixes = pre.querySelectorAll(
    '[data-testid="semantic-shell-line-prefix"]',
  );
  expect(prefixes).toHaveLength(4);
  const secondRun = prefixes[2]!;
  expect(secondRun.textContent).toBe("     1\t");

  await actPoll({
    description: "D and Python keywords highlighted in their respective runs",
    ready: () => {
      const d = new Map<string, string>();
      const python = new Map<string, string>();
      for (const token of pre.querySelectorAll<HTMLElement>(
        "span[style*='color']",
      )) {
        const followsReset =
          secondRun.compareDocumentPosition(token) &
          Node.DOCUMENT_POSITION_FOLLOWING;
        const run = followsReset ? python : d;
        run.set(token.textContent, token.style.color);
      }
      // Under the D grammar, `def` receives an identifier color.
      const keywordColor = python.get("return");
      return (
        Boolean(keywordColor) &&
        d.get("module") === keywordColor &&
        d.get("int") === keywordColor &&
        python.get("def") === keywordColor
      );
    },
  });
  expect(pre.textContent).toBe(fixtures.all);
});

it("falls back to raw when the two-run plan receives one GNU nl run", async () => {
  const { plan, search } = await mixedNumberedView();
  const stdout = fixtures["nl-alone"];
  expect(segmentOutput(stdout, plan, { kind: "complete" }).pieces).toEqual([
    expect.objectContaining({ kind: "raw", start: 0, end: stdout.length }),
  ]);
  expect(hasSemanticShellOutput(stdout, plan)).toBe(false);

  const root = roots.create();
  roots.render(
    h(SemanticShellOutput, { stdout, outputPlan: plan, search }),
    root,
  );
  expect(root.innerHTML).toBe("");
});

it("falls back when an overlapping literal could hide a GNU section delimiter", async () => {
  const { plan, search } = await mixedNumberedView(
    "nl -ba a.d && nl -ba b.py && printf '\\n\\n\\n'",
  );
  // GNU nl emits an empty row for the final section delimiter in b.py.
  const stdout =
    "     1\tmodule a;\n     2\tint x;\n     1\tdef f(): pass\n\n\n\n\n";
  expect(segmentOutput(stdout, plan, { kind: "complete" }).pieces).toEqual([
    expect.objectContaining({ kind: "raw", start: 0, end: stdout.length }),
  ]);

  const root = roots.create();
  roots.render(
    h(SemanticShellOutput, { stdout, outputPlan: plan, search }),
    root,
  );
  expect(root.innerHTML).toBe("");
});
