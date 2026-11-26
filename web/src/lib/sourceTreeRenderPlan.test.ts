import { beforeAll, describe, it, expect } from "vitest";
import type { SourceNode } from "./sourceTree";
import { loadParsedShellDocument } from "./shellParser";
import { configureTreeSitterAssets } from "./treeSitterRuntime";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { buildShellSourceTree } from "./shellSourceTree";
import {
  buildSourceRenderPieces,
  type SourceRenderPiece,
} from "./sourceTreeRenderPlan";

function sourceTextOfPiece(piece: SourceRenderPiece): string {
  return piece.kind === "rich" ? piece.sourceText : piece.text;
}

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

async function buildLoadedShellSourceTree(source: string) {
  const parsed = await loadParsedShellDocument(source);
  expect(parsed.ok, source).toBe(true);
  if (!parsed.ok) throw new Error(`shell parser rejected: ${parsed.reason}`);
  return buildShellSourceTree(parsed.document);
}

describe("source tree render plan", () => {
  it("carries the document into a rich render piece for a mid-line embed", () => {
    const text = "<svg></svg>";
    const prefix = "const svg = `";
    const suffix = "`;";
    const end = prefix.length + text.length;
    const root: SourceNode = {
      language: "javascript",
      text: prefix + text + suffix,
      segments: [
        { kind: "text", span: { start: 0, end: prefix.length } },
        {
          kind: "embed",
          span: { start: prefix.length, end },
          presentation: { kind: "rich" },
          document: { filePath: "x.svg" },
          content: {
            language: "xml",
            text,
            segments: [{ kind: "text", span: { start: 0, end: text.length } }],
          },
        },
        { kind: "text", span: { start: end, end: end + suffix.length } },
      ],
    };

    expect(buildSourceRenderPieces(root)).toMatchObject([
      { kind: "inline", text: prefix },
      {
        kind: "rich",
        mode: "rich-code",
        text,
        document: { filePath: "x.svg" },
      },
      { kind: "inline", text: suffix },
    ]);
  });

  it("classifies heredoc body as rich markdown in safe heredoc context", async () => {
    const command = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const heredoc = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;

    expect(buildSourceRenderPieces(parsed.value)).toContainEqual(
      expect.objectContaining({
        kind: "rich",
        mode: "rich-markdown",
        text: "# Title",
      }),
    );
  });

  it("keeps a quoted shell wrapper inline", async () => {
    const command = "/run/current-system/sw/bin/zsh -lc 'cat README.md'";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;

    expect(buildSourceRenderPieces(parsed.value)).toContainEqual(
      expect.objectContaining({
        kind: "inline",
        language: "bash",
        text: wrapper.content.text,
      }),
    );
  });

  it("renders deeply nested wrappers as recursive inline pieces", async () => {
    const command = 'zsh -lc "bash -lc \'sh -c \\"cat README.md\\"\'"';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inlinePieces = pieces.filter((piece) => piece.kind === "inline");

    expect(inlinePieces.length).toBeGreaterThan(1);
    expect(inlinePieces.some((piece) => piece.text === command)).toBe(false);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
    expect(parsed.value.text).toBe(command);
  });

  it("keeps escaped wrapper source while exposing decoded highlight text", async () => {
    const command = 'zsh -lc "echo \\"CYDO_SKIP_LOAD_TASKS\\""';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inline = pieces.filter((piece) => piece.kind === "inline");
    const escaped = inline.find((piece) =>
      piece.text.includes('\\"CYDO_SKIP_LOAD_TASKS\\"'),
    );
    expect(escaped).toBeTruthy();
    if (!escaped) return;
    expect(
      escaped.highlightSource.text.slice(
        escaped.highlightSpan.start,
        escaped.highlightSpan.end,
      ),
    ).toContain('"CYDO_SKIP_LOAD_TASKS"');
    expect(escaped.projection).toBeTruthy();
  });

  it("keeps single-quote close/reopen raw text with decoded apostrophe highlight", async () => {
    const command = "zsh -lc 'printf '\\''hi'\\'''";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const inline = pieces.filter((piece) => piece.kind === "inline");
    const escaped = inline.find((piece) => piece.text.includes("'\\''"));
    expect(escaped).toBeTruthy();
    if (!escaped) return;
    expect(
      escaped.highlightSource.text.slice(
        escaped.highlightSpan.start,
        escaped.highlightSpan.end,
      ),
    ).toContain("'");
    expect(escaped.projection).toBeTruthy();
  });

  it("renders markdown heredoc body as rich markdown and keeps shell suffix inline", async () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\necho done\"";
    const parsed = await buildLoadedShellSourceTree(command);
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

  it("renders svg heredoc body as rich code and keeps wrapper/footer shell inline", async () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF\necho done\"";
    const parsed = await buildLoadedShellSourceTree(command);
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

  it("keeps escaped rich heredoc source text while rendering decoded body text", async () => {
    const command =
      'zsh -lc "cat > /tmp/a/output.svg <<\'EOF\'\n<svg a=\\"b\\"></svg>\nEOF"';
    const parsed = await buildLoadedShellSourceTree(command);
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

  it("renders mixed-quoted wrapper heredoc with decoded rich text and projected raw source", async () => {
    const command =
      "zsh -lc \"cat > /tmp/a/output.md <<'EOF'\nheredoc body with \\\"quotes\\\" and \"'$literal\nEOF'";
    const parsed = await buildLoadedShellSourceTree(command);
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

  it("renders mixed-quoted svg wrapper heredoc with a dense projection", async () => {
    const command = [
      `/run/current-system/sw/bin/zsh -lc "cat > /tmp/cydo-heredoc-render.svg <<'EOF'`,
      '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><text y="20">"\'$literal</text></svg>',
      "EOF'",
    ].join("\n");
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapperIndex = parsed.value.segments.findIndex(
      (segment) => segment.kind === "embed",
    );
    expect(wrapperIndex).toBeGreaterThanOrEqual(0);
    if (wrapperIndex < 0) return;
    const wrapper = parsed.value.segments[wrapperIndex];
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper || wrapper.kind !== "embed") return;

    const heredocIndex = wrapper.content.segments.findIndex(
      (segment) => segment.kind === "embed",
    );
    expect(heredocIndex).toBeGreaterThanOrEqual(0);
    if (heredocIndex < 0) return;
    const heredoc = wrapper.content.segments[heredocIndex];
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc || heredoc.kind !== "embed") return;

    const pieces = buildSourceRenderPieces(parsed.value);
    const rich = pieces.find(
      (piece) =>
        piece.kind === "rich" &&
        piece.mode === "rich-code" &&
        piece.language === "xml",
    );
    expect(rich?.kind).toBe("rich");
    if (!rich || rich.kind !== "rich") return;
    expect(rich.sourceSpan).toEqual({
      start: command.indexOf("<svg"),
      end: command.indexOf("\nEOF'"),
    });
    expect(rich.text).toBe(
      "<svg xmlns=http://www.w3.org/2000/svg width=32 height=32><text y=20>$literal</text></svg>",
    );
    expect(rich.sourceText).toBe(
      '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><text y="20">"\'$literal</text></svg>',
    );
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
  });

  it("renders python -c wrapper as projected inline pieces with python language", async () => {
    const command = 'python -c "import json,sys"';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);

    const pythonPiece = pieces.find(
      (p) => p.kind === "inline" && p.language === "python",
    );
    expect(pythonPiece).toBeTruthy();
    if (!pythonPiece || pythonPiece.kind !== "inline") return;
    expect(pythonPiece.text).toBe("import json,sys");
    expect(pythonPiece.projectedInline).toBe(true);

    expect(pieces.some((p) => p.kind === "rich")).toBe(false);
  });

  it("keeps compound heredoc source order around the trailing pipeline", async () => {
    const command =
      "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const pieces = buildSourceRenderPieces(parsed.value);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);

    const rich = pieces.find(
      (piece) =>
        piece.kind === "rich" &&
        piece.language === "python" &&
        piece.text === "print(1)",
    );
    expect(rich?.kind).toBe("rich");
    if (!rich || rich.kind !== "rich") return;
    expect(rich.mode).toBe("rich-code");
    expect(rich.text).toBe("print(1)");

    expect(pieces.map((piece) => piece.sourceSpan)).toEqual([
      { start: 0, end: 29 },
      { start: 29, end: 37 },
      { start: 37, end: 56 },
    ]);
  });

  it("renders a CRLF heredoc body as rich code", async () => {
    const command = "python3 - <<EOF\r\nprint(1)\r\nEOF";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const documentResult = await loadParsedShellDocument(command);
    expect(documentResult.ok).toBe(true);
    if (!documentResult.ok) return;
    const redirect = documentResult.document.redirects.find(
      (candidate) => candidate.kind === "heredoc",
    );
    expect(redirect?.kind).toBe("heredoc");
    if (!redirect) return;
    expect(redirect.headerLineBreakSpan).toEqual({ start: 15, end: 17 });
    expect(redirect.rawBodySpan).toEqual({ start: 17, end: 27 });
    expect(redirect.contentSpan).toEqual({ start: 17, end: 25 });
    expect(redirect.terminatorSpan).toEqual({ start: 27, end: 30 });

    const embed = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(embed?.kind).toBe("embed");
    if (!embed) return;
    expect(embed.span).toEqual({ start: 17, end: 25 });
    expect(embed.content.language).toBe("python");
    expect(embed.content.text).toBe("print(1)");

    const pieces = buildSourceRenderPieces(parsed.value);
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(command);
    const rich = pieces.find((piece) => piece.kind === "rich");
    expect(rich?.kind).toBe("rich");
    if (!rich) return;
    expect(rich.mode).toBe("rich-code");
    expect(rich.text).toBe("print(1)");
    expect(rich.sourceText).toBe("print(1)");
    expect(pieces.map((piece) => piece.sourceSpan)).toEqual([
      { start: 0, end: 17 },
      { start: 17, end: 25 },
      { start: 25, end: 30 },
    ]);
    expect(command.slice(25)).toBe("\r\nEOF");
  });

  it("treats projected inline embeds generically and preserves parent-owned source text", () => {
    const root: SourceNode = {
      language: "json",
      text: "a\\u0022b",
      segments: [
        {
          kind: "embed",
          span: { start: 0, end: 8 },
          origin: {
            language: "json",
            construct: "string-escape",
            attributes: { escape: "unicode" },
          },
          projection: {
            points: [
              { child: 0, parent: 0 },
              { child: 1, parent: 1 },
              { child: 2, parent: 7 },
              { child: 3, parent: 8 },
            ],
          },
          content: {
            language: "json",
            text: 'a"b',
            segments: [{ kind: "text", span: { start: 0, end: 3 } }],
          },
        },
      ],
    };

    const pieces = buildSourceRenderPieces(root);
    expect(pieces).toHaveLength(1);
    const piece = pieces[0];
    expect(piece?.kind).toBe("inline");
    if (!piece || piece.kind !== "inline") return;
    expect(piece.text).toBe("a\\u0022b");
    expect(
      piece.highlightSource.text.slice(
        piece.highlightSpan.start,
        piece.highlightSpan.end,
      ),
    ).toBe('a"b');
    expect(piece.projection).toBeTruthy();
    expect(pieces.map(sourceTextOfPiece).join("")).toBe(root.text);
  });
});

it("reads a dense projection linearly across ordered render boundaries", () => {
  const length = 16_000;
  let reads = 0;
  const points = new Proxy(
    Array.from({ length: length + 1 }, (_, offset) => ({
      child: offset,
      parent: offset * 4,
    })),
    {
      get(target, property, receiver): unknown {
        reads++;
        return Reflect.get(target, property, receiver);
      },
    },
  );
  const text = "a".repeat(length);
  const raw = "\\x61".repeat(length);
  const root: SourceNode = {
    language: "javascript",
    text: raw,
    segments: [
      {
        kind: "embed",
        span: { start: 0, end: raw.length },
        projection: { points },
        content: {
          language: "bash",
          text,
          segments: [{ kind: "text", span: { start: 0, end: text.length } }],
        },
      },
    ],
  };
  const [piece] = buildSourceRenderPieces(root);
  expect(piece?.kind).toBe("inline");
  if (piece?.kind !== "inline") throw new Error("Expected an inline piece");
  expect(piece.text).toBe(raw);
  const project = piece.projection!();
  for (let offset = 0; offset <= length; offset++) {
    if (project(offset) !== offset * 4) throw new Error("Wrong mapped offset");
  }
  expect(reads).toBeLessThan(30 * length);
});
