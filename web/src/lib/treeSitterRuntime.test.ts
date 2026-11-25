import { afterEach, expect, it, vi } from "vitest";
import { Parser } from "web-tree-sitter";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import {
  configureTreeSitterAssets,
  loadTreeSitterLanguage,
} from "./treeSitterRuntime";

afterEach(() => vi.restoreAllMocks());

it("shares one runtime initialization across concurrent grammar loads", async () => {
  const init = vi.spyOn(Parser, "init");
  const loadRuntime = vi.fn(installedTreeSitterBytes.loadRuntime);
  const loadLanguage = vi.fn(installedTreeSitterBytes.loadLanguage);
  configureTreeSitterAssets({ kind: "bytes", loadRuntime, loadLanguage });

  const [bash, javascript, bashAgain, javascriptAgain] = await Promise.all([
    loadTreeSitterLanguage("bash"),
    loadTreeSitterLanguage("javascript"),
    loadTreeSitterLanguage("bash"),
    loadTreeSitterLanguage("javascript"),
  ]);

  expect(bash).not.toBe(javascript);
  expect(bashAgain).toBe(bash);
  expect(javascriptAgain).toBe(javascript);
  expect(loadLanguage.mock.calls).toEqual([["bash"], ["javascript"]]);
  expect(loadRuntime).toHaveBeenCalledTimes(1);
  expect(init).toHaveBeenCalledTimes(1);
});
