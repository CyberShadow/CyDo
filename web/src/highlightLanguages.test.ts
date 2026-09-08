import { describe, expect, it } from "vitest";
import {
  EXT_TO_LANG,
  FILENAME_TO_LANG,
  langFromPath,
  supportedHighlightLanguages,
} from "./highlightLanguages.mjs";
import { langFromPath as exportedLangFromPath } from "./highlight";

describe("highlight language mappings", () => {
  it("maps exact special filenames, extensions, case variants, and unknown paths", () => {
    expect(langFromPath("src/Dockerfile")).toBe("dockerfile");
    expect(langFromPath("src/Makefile")).toBe("makefile");
    expect(langFromPath("src/CMakeLists.txt")).toBe("cmake");
    expect(langFromPath("src/dockerfile")).toBeNull();
    expect(langFromPath("src/makefile")).toBeNull();
    expect(langFromPath("src/example.ts")).toBe("typescript");
    expect(langFromPath("src/COMPONENT.TSX")).toBe("tsx");
    expect(langFromPath("src/script.R")).toBe("r");
    expect(langFromPath("src/script.r")).toBe("r");
    expect(langFromPath("src/README")).toBeNull();
    expect(langFromPath("src/unknown.extension")).toBeNull();
  });

  it("derives the canonical sorted supported set from every mapping-table result", () => {
    const mappedLanguages = [
      ...Object.values(EXT_TO_LANG),
      ...Object.values(FILENAME_TO_LANG),
    ];
    const expected = [...new Set(mappedLanguages)].sort();

    expect(supportedHighlightLanguages).toEqual(expected);
    expect(supportedHighlightLanguages).toContain("bash");
    expect(supportedHighlightLanguages).toContain("rust");
    expect(supportedHighlightLanguages).toContain("nix");
  });

  it("re-exports the mapping function used by highlighting", () => {
    expect(exportedLangFromPath).toBe(langFromPath);
  });
});
