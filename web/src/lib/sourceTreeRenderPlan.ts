import type { SourceNode, SourceSpan, SourceSegment } from "./sourceTree";

export type SourceEmbedRenderMode = "inline" | "rich-markdown" | "rich-code";

type EmbedSegment = Extract<SourceSegment, { kind: "embed" }>;

export type SourceRenderPiece =
  | {
      kind: "inline";
      id: string;
      text: string;
      language: string;
      wrapperPayload: boolean;
    }
  | {
      kind: "rich";
      id: string;
      text: string;
      language: string;
      mode: Exclude<SourceEmbedRenderMode, "inline">;
    };

function isSupportedRichLanguage(language: string): boolean {
  if (language === "markdown") return true;
  if (language === "text") return false;
  if (language === "shell-output") return false;
  if (language === "bash") return false;
  return language.length > 0;
}

export function isLineBoundaryEmbed(text: string, span: SourceSpan): boolean {
  if (span.start < 0 || span.end < span.start || span.end > text.length) {
    return false;
  }
  const startsOnLineBoundary =
    span.start === 0 || text[span.start - 1] === "\n";
  const endsOnLineBoundary =
    span.end === text.length || text[span.end] === "\n";
  return startsOnLineBoundary && endsOnLineBoundary;
}

export function classifyEmbedRenderMode(
  parent: SourceNode,
  segment: EmbedSegment,
): SourceEmbedRenderMode {
  if (!isLineBoundaryEmbed(parent.text, segment.span)) return "inline";
  if (segment.escaping.kind !== "shell-heredoc") return "inline";
  if (!isSupportedRichLanguage(segment.content.language)) return "inline";
  return segment.content.language === "markdown"
    ? "rich-markdown"
    : "rich-code";
}

function walkSourceRenderPieces(
  node: SourceNode,
  path: string,
  pieces: SourceRenderPiece[],
  wrapperPayload: boolean,
): void {
  for (let i = 0; i < node.segments.length; i++) {
    const segment = node.segments[i]!;
    const segPath = `${path}.${i}`;
    if (segment.kind === "text") {
      const text = node.text.slice(segment.span.start, segment.span.end);
      if (!text) continue;
      pieces.push({
        kind: "inline",
        id: segPath,
        text,
        language: node.language,
        wrapperPayload,
      });
      continue;
    }

    const mode = classifyEmbedRenderMode(node, segment);
    if (mode === "inline") {
      const isShellWrapperPayload =
        segment.escaping.kind === "shell-single-quote" ||
        segment.escaping.kind === "shell-double-quote";
      if (isShellWrapperPayload) {
        const text = node.text.slice(segment.span.start, segment.span.end);
        if (!text) continue;
        pieces.push({
          kind: "inline",
          id: segPath,
          text,
          language: node.language,
          wrapperPayload: true,
        });
        continue;
      }
      walkSourceRenderPieces(
        segment.content,
        `${segPath}.content`,
        pieces,
        wrapperPayload,
      );
      continue;
    }

    pieces.push({
      kind: "rich",
      id: segPath,
      text: segment.content.text,
      language: segment.content.language,
      mode,
    });
  }
}

export function buildSourceRenderPieces(root: SourceNode): SourceRenderPiece[] {
  const pieces: SourceRenderPiece[] = [];
  walkSourceRenderPieces(root, "root", pieces, false);
  return pieces;
}
