import { afterEach, beforeAll, expect, it, vi } from "vitest";
import { Tree } from "web-tree-sitter";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { withJavaScriptTree } from "./javascriptParser";
import { configureTreeSitterAssets } from "./treeSitterRuntime";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});
afterEach(() => vi.restoreAllMocks());

it("parses a code-mode cell with top-level await", async () => {
  const source = 'const result = await tools.exec_command({ cmd: "pwd" });';
  await expect(
    withJavaScriptTree(source, (root) => ({
      hasError: root.hasError,
      type: root.type,
      expressionType:
        root.firstNamedChild?.firstNamedChild?.childForFieldName("value")?.type,
    })),
  ).resolves.toEqual({
    hasError: false,
    type: "program",
    expressionType: "await_expression",
  });
});

it("deletes the tree after analysis returns", async () => {
  const deleteTree = vi.spyOn(Tree.prototype, "delete");
  const analyze = vi.fn(() => {
    expect(deleteTree).not.toHaveBeenCalled();
    return "analysis result";
  });

  await expect(withJavaScriptTree("run();", analyze)).resolves.toBe(
    "analysis result",
  );
  expect(deleteTree).toHaveBeenCalledTimes(1);
});

it("deletes the tree when analysis throws", async () => {
  const deleteTree = vi.spyOn(Tree.prototype, "delete");
  const error = new Error("analysis failed");
  const analyze = vi.fn(() => {
    expect(deleteTree).not.toHaveBeenCalled();
    throw error;
  });

  await expect(withJavaScriptTree("run();", analyze)).rejects.toBe(error);
  expect(deleteTree).toHaveBeenCalledTimes(1);
});
