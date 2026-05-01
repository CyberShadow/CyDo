import { describe, it, expect } from "vitest";
import { parseCommandSourceTree } from "./sourceTree";
import {
  buildSourceRenderPieces,
  classifyEmbedRenderMode,
  isLineBoundaryEmbed,
  type SourceRenderPiece,
} from "./sourceTreeRenderPlan";

function sourceTextOfPiece(piece: SourceRenderPiece): string {
  return piece.kind === "rich" ? piece.sourceText : piece.text;
}

describe("source tree render plan", () => {
  it("isLineBoundaryEmbed returns false for quoted wrapper payload", () => {
    const command =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;

    expect(isLineBoundaryEmbed(parsed.value.text, wrapper.span)).toBe(false);
    expect(classifyEmbedRenderMode(parsed.value, wrapper)).toBe("inline");
  });

  it("isLineBoundaryEmbed returns true for heredoc body spans", () => {
    const command = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const heredoc = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;

    expect(isLineBoundaryEmbed(parsed.value.text, heredoc.span)).toBe(true);
  });

  it("classifies heredoc body as rich markdown in safe heredoc context", () => {
    const command = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const heredoc = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;

    expect(classifyEmbedRenderMode(parsed.value, heredoc)).toBe(
      "rich-markdown",
    );
  });

  it("does not promote non-heredoc embeds to rich", () => {
    const command = "/run/current-system/sw/bin/zsh -lc 'cat README.md'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;

    expect(classifyEmbedRenderMode(parsed.value, wrapper)).toBe("inline");
  });

  it("renders deeply nested wrappers as recursive inline pieces", () => {
    const command = 'zsh -lc "bash -lc \'sh -c \\"cat README.md\\"\'"';
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inlinePieces = pieces.filter((piece) => piece.kind === "inline");

    expect(inlinePieces.length).toBeGreaterThan(1);
    expect(inlinePieces.some((piece) => piece.text === command)).toBe(false);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
    expect(parsed.value.text).toBe(command);
  });

  it("keeps escaped wrapper source while exposing decoded highlight text", () => {
    const command = 'zsh -lc "echo \\"CYDO_SKIP_LOAD_TASKS\\""';
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inline = pieces.filter((piece) => piece.kind === "inline");
    const escaped = inline.find((piece) =>
      piece.text.includes('\\"CYDO_SKIP_LOAD_TASKS\\"'),
    );
    expect(escaped).toBeTruthy();
    if (!escaped) return;
    expect(escaped.highlightText).toContain('"CYDO_SKIP_LOAD_TASKS"');
    expect(escaped.projection).toBeTruthy();
  });

  it("keeps single-quote close/reopen raw text with decoded apostrophe highlight", () => {
    const command = "zsh -lc 'printf '\\''hi'\\'''";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inline = pieces.filter((piece) => piece.kind === "inline");
    const escaped = inline.find((piece) => piece.text.includes("'\\''"));
    expect(escaped).toBeTruthy();
    if (!escaped) return;
    expect(escaped.highlightText).toContain("'");
    expect(escaped.projection).toBeTruthy();
  });

  it("renders markdown heredoc body as rich markdown and keeps shell suffix inline", () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\necho done\"";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const richIndex = pieces.findIndex(
      (piece) => piece.kind === "rich" && piece.mode === "rich-markdown",
    );
    expect(richIndex).toBeGreaterThanOrEqual(0);
    const rich = richIndex >= 0 ? pieces[richIndex] : undefined;
    expect(rich?.text).toBe("# Title");
    const trailingInline = pieces
      .slice(richIndex + 1)
      .map((piece) => (piece.kind === "inline" ? piece.text : ""))
      .join("");
    expect(trailingInline.includes("EOF")).toBe(true);
    expect(trailingInline.includes('echo done"')).toBe(true);
    const joined = pieces.map(sourceTextOfPiece).join("");
    expect(joined).toBe(command);
  });

  it("renders svg heredoc body as rich code and keeps wrapper/footer shell inline", () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF\necho done\"";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const richIndex = pieces.findIndex(
      (piece) =>
        piece.kind === "rich" &&
        piece.mode === "rich-code" &&
        piece.language === "xml",
    );
    expect(richIndex).toBeGreaterThanOrEqual(0);
    const rich = richIndex >= 0 ? pieces[richIndex] : undefined;
    expect(rich?.text).toBe("<svg></svg>");
    const trailingInline = pieces
      .slice(richIndex + 1)
      .map((piece) => (piece.kind === "inline" ? piece.text : ""))
      .join("");
    expect(trailingInline.includes("EOF")).toBe(true);
    expect(trailingInline.includes('echo done"')).toBe(true);
    const joined = pieces.map(sourceTextOfPiece).join("");
    expect(joined).toBe(command);
  });

  it("keeps escaped rich heredoc source text while rendering decoded body text", () => {
    const command =
      'zsh -lc "cat > /tmp/a/output.svg <<\'EOF\'\n<svg a=\\"b\\"></svg>\nEOF"';
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const rich = pieces.find(
      (piece) =>
        piece.kind === "rich" &&
        piece.mode === "rich-code" &&
        piece.language === "xml",
    );
    expect(rich?.kind).toBe("rich");
    if (!rich || rich.kind !== "rich") return;
    expect(rich.text).toBe('<svg a="b"></svg>');
    expect(rich.sourceText).toBe('<svg a=\\"b\\"></svg>');
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
  });

  it("renders mixed-quoted wrapper heredoc with decoded rich text and projected raw source", () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.md <<'EOF'\nheredoc body with \\\"quotes\\\" and \"'$literal\nEOF'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const rich = pieces.find(
      (piece) =>
        piece.kind === "rich" &&
        piece.mode === "rich-markdown" &&
        piece.language === "markdown",
    );
    expect(rich?.kind).toBe("rich");
    if (!rich || rich.kind !== "rich") return;

    expect(rich.text).toBe('heredoc body with "quotes" and $literal');
    expect(rich.sourceText).toContain('\\"quotes\\" and "\'$literal');
    expect(rich.sourceSpan.end).toBeGreaterThan(rich.sourceSpan.start);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
  });
});
