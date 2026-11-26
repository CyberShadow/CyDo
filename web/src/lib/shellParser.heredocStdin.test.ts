import { beforeAll, expect, it } from "vitest";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { loadParsedShellDocument } from "./shellParser";
import { buildShellSourceTree } from "./shellSourceTree";
import { configureTreeSitterAssets } from "./treeSitterRuntime";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

it.each([
  { label: "a single-quoted dash", dash: "'-'", syntax: "raw_string" },
  { label: "a double-quoted dash", dash: '"-"', syntax: "string" },
  { label: "a bare dash", dash: "-", syntax: "synthetic" },
])("builds a rich Python heredoc with $label", async ({ dash, syntax }) => {
  const parsed = await loadParsedShellDocument(
    `python3 ${dash} <<'PY'\npass\nPY`,
  );
  expect(parsed.ok).toBe(true);
  if (!parsed.ok) return;

  const { document } = parsed;
  const args = document.commands[0]!.arguments;
  expect(args).toMatchObject([
    {
      synthetic: syntax === "synthetic",
      word: { kind: "literal", syntax, value: "-" },
    },
  ]);
  expect(document.embeddedInvocations).toMatchObject([
    { kind: "heredoc", stdinArgumentIndex: args.length - 1 },
  ]);

  const tree = buildShellSourceTree(document);
  expect(tree.ok).toBe(true);
  if (!tree.ok) return;

  const body = tree.value.segments.find(
    (segment) =>
      segment.kind === "embed" && segment.origin?.construct === "heredoc-body",
  );
  expect(body).toMatchObject({
    presentation: { kind: "rich" },
    content: { language: "python", text: "pass" },
  });
});
