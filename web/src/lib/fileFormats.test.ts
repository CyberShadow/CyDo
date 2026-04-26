import { describe, expect, it } from "vitest";
import {
  detectRenderableFormat,
  isMarkdownPath,
  isSvgPath,
  looksLikeSvg,
  stripCatLineNumbers,
} from "./fileFormats";

describe("fileFormats", () => {
  it("detects markdown paths", () => {
    expect(isMarkdownPath("README.md")).toBe(true);
    expect(isMarkdownPath("docs/page.mdx")).toBe(true);
    expect(isMarkdownPath("docs/page.txt")).toBe(false);
  });

  it("detects svg paths", () => {
    expect(isSvgPath("icons/logo.svg")).toBe(true);
    expect(isSvgPath("icons/logo.SVG")).toBe(true);
    expect(isSvgPath("icons/logo.png")).toBe(false);
  });

  it("strips cat-style line number prefixes", () => {
    const input = "   1\t<svg>\n   2\t</svg>\n";
    expect(stripCatLineNumbers(input)).toBe("<svg>\n</svg>\n");
  });

  it("sniffs svg content", () => {
    expect(looksLikeSvg("<svg><rect /></svg>")).toBe(true);
    expect(looksLikeSvg('<?xml version="1.0"?><svg></svg>')).toBe(true);
    expect(looksLikeSvg("<div></div>")).toBe(false);
  });

  it("detects renderable format from path or content", () => {
    expect(detectRenderableFormat("README.md")).toBe("markdown");
    expect(detectRenderableFormat("icons/logo.svg")).toBe("svg");
    expect(detectRenderableFormat(undefined, "  <svg></svg>")).toBe("svg");
    expect(detectRenderableFormat("notes.txt", "plain text")).toBeNull();
  });
});
