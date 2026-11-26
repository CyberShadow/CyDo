import { beforeAll, expect, it, vi } from "vitest";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { analyzeEmbedded, getCachedEmbeddedAnalysis } from "./embeddedFlow";
import * as shellParser from "./shellParser";
import { configureTreeSitterAssets } from "./treeSitterRuntime";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

it("peeks at the Bash analysis after it has loaded", async () => {
  const source = "printf hello";

  expect(getCachedEmbeddedAnalysis("bash", source)).toBeUndefined();
  const analysis = await analyzeEmbedded("bash", source);
  expect(analysis).toMatchObject({ language: "bash", text: source });
  expect(getCachedEmbeddedAnalysis("bash", source)).toEqual(analysis);
});

it("returns null for a Bash parse failure", async () => {
  const source = "if";

  await expect(analyzeEmbedded("bash", source)).resolves.toBeNull();
  expect(getCachedEmbeddedAnalysis("bash", source)).toBeNull();
  await expect(
    shellParser.loadParsedShellDocument(source),
  ).resolves.toMatchObject({
    ok: false,
    reason: "unsafe_shell_syntax",
  });
});

it("returns null when loading the Bash parse rejects", async () => {
  const source = "printf unavailable";
  const load = vi
    .spyOn(shellParser, "loadParsedShellDocument")
    .mockRejectedValueOnce(new Error("Bash parser unavailable"));
  try {
    await expect(analyzeEmbedded("bash", source)).resolves.toBeNull();
    expect(load).toHaveBeenCalledExactlyOnceWith(source);
  } finally {
    load.mockRestore();
  }
});

it("returns null when Bash parses with a rejected diagnostic", async () => {
  const source = "bash -c 'cat <<EOF'";

  await expect(analyzeEmbedded("bash", source)).resolves.toBeNull();
  expect(getCachedEmbeddedAnalysis("bash", source)).toBeNull();
  await expect(
    shellParser.loadParsedShellDocument(source),
  ).resolves.toMatchObject({
    ok: true,
    document: {
      diagnostics: [{ kind: "child_parse_failed", reason: "invalid_heredoc" }],
    },
  });
});

it("starts loading the Bash parse before returning", async () => {
  const source = "printf synchronous";
  const load = vi.spyOn(shellParser, "loadParsedShellDocument");
  try {
    const analysis = analyzeEmbedded("bash", source);
    expect(load).toHaveBeenCalledExactlyOnceWith(source);
    await analysis;
  } finally {
    load.mockRestore();
  }
});
