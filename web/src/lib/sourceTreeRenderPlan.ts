import {
  isShellWrapperEscaping,
  projectDescendantSpan,
  type SourceNode,
  type SourceProjection,
  type SourceSpan,
  type SourceSegment,
} from "./sourceTree";

export type SourceEmbedRenderMode = "inline" | "rich-markdown" | "rich-code";

type EmbedSegment = Extract<SourceSegment, { kind: "embed" }>;

export type SourceRenderPiece =
  | {
      kind: "inline";
      id: string;
      text: string;
      highlightText?: string;
      language: string;
      wrapperPayload: boolean;
      sourceSpan: SourceSpan;
      highlightSpan: SourceSpan;
      projection?: SourceProjection;
    }
  | {
      kind: "rich";
      id: string;
      text: string;
      sourceText: string;
      language: string;
      mode: Exclude<SourceEmbedRenderMode, "inline">;
      sourceSpan: SourceSpan;
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
  root: SourceNode,
  node: SourceNode,
  path: string,
  embedPath: number[],
  wrapperPayload: boolean,
  pieces: SourceRenderPiece[],
): boolean {
  for (let i = 0; i < node.segments.length; i++) {
    const segment = node.segments[i]!;
    const segPath = `${path}.${i}`;
    if (segment.kind === "text") {
      if (
        !pushInlineTextPiece(
          root,
          node,
          embedPath,
          segPath,
          wrapperPayload,
          segment,
          pieces,
        )
      )
        return false;
      continue;
    }

    const mode = classifyEmbedRenderMode(node, segment);
    if (mode === "inline") {
      const rawSubtreeSpan = projectDescendantSpan(
        root,
        embedPath,
        segment.span,
      );
      if (!rawSubtreeSpan) return false;
      const childWrapperPayload =
        wrapperPayload || isShellWrapperEscaping(segment.escaping);
      if (
        !walkInlineSubtree(
          root,
          segment,
          segPath,
          embedPath,
          i,
          childWrapperPayload,
          pieces,
        )
      ) {
        const rawText = root.text.slice(
          rawSubtreeSpan.start,
          rawSubtreeSpan.end,
        );
        if (!rawText) continue;
        pieces.push({
          kind: "inline",
          id: segPath,
          text: rawText,
          language: node.language,
          wrapperPayload: childWrapperPayload,
          sourceSpan: rawSubtreeSpan,
          highlightSpan: segment.span,
        });
      }
      continue;
    }

    const sourceSpan = projectDescendantSpan(root, embedPath, segment.span);
    if (!sourceSpan) return false;
    const rawText = root.text.slice(sourceSpan.start, sourceSpan.end);
    if (!rawText) continue;
    pieces.push({
      kind: "rich",
      id: segPath,
      text: segment.content.text,
      sourceText: rawText,
      language: segment.content.language,
      mode,
      sourceSpan,
    });
  }
  return true;
}

function walkInlineSubtree(
  root: SourceNode,
  segment: EmbedSegment,
  segPath: string,
  embedPath: number[],
  segmentIndex: number,
  wrapperPayload: boolean,
  pieces: SourceRenderPiece[],
): boolean {
  const nestedPieces: SourceRenderPiece[] = [];
  const nestedPath = [...embedPath, segmentIndex];
  const ok = walkSourceRenderPieces(
    root,
    segment.content,
    `${segPath}.content`,
    nestedPath,
    wrapperPayload,
    nestedPieces,
  );
  if (!ok) return false;
  pieces.push(...nestedPieces);
  return true;
}

function pushInlineTextPiece(
  root: SourceNode,
  node: SourceNode,
  embedPath: number[],
  id: string,
  wrapperPayload: boolean,
  segment: Extract<SourceSegment, { kind: "text" }>,
  pieces: SourceRenderPiece[],
): boolean {
  const highlightText = node.text.slice(segment.span.start, segment.span.end);
  if (!highlightText) return true;
  const sourceSpan = projectDescendantSpan(root, embedPath, segment.span);
  if (!sourceSpan) return false;
  const text = root.text.slice(sourceSpan.start, sourceSpan.end);
  if (!text) return true;

  if (text === highlightText) {
    pieces.push({
      kind: "inline",
      id,
      text,
      language: node.language,
      wrapperPayload,
      sourceSpan,
      highlightSpan: segment.span,
    });
    return true;
  }

  const projection = buildInlineProjection(
    root,
    embedPath,
    segment.span,
    sourceSpan,
    highlightText.length,
  );
  if (!projection) return false;

  pieces.push({
    kind: "inline",
    id,
    text,
    highlightText,
    language: node.language,
    wrapperPayload,
    sourceSpan,
    highlightSpan: segment.span,
    projection,
  });
  return true;
}

function buildInlineProjection(
  root: SourceNode,
  embedPath: number[],
  highlightSpan: SourceSpan,
  sourceSpan: SourceSpan,
  highlightLength: number,
): SourceProjection | null {
  const points: SourceProjection["points"] = [{ child: 0, parent: 0 }];
  let lastParent = 0;
  for (let i = 1; i <= highlightLength; i++) {
    const mapped = projectDescendantSpan(root, embedPath, {
      start: highlightSpan.start + i,
      end: highlightSpan.start + i,
    });
    if (!mapped || mapped.start !== mapped.end) return null;
    const parent = mapped.start - sourceSpan.start;
    if (parent <= lastParent) return null;
    points.push({ child: i, parent });
    lastParent = parent;
  }
  if (points[points.length - 1]?.parent !== sourceSpan.end - sourceSpan.start) {
    return null;
  }
  return { points };
}

export function buildSourceRenderPieces(root: SourceNode): SourceRenderPiece[] {
  const pieces: SourceRenderPiece[] = [];
  const ok = walkSourceRenderPieces(root, root, "root", [], false, pieces);
  if (!ok) {
    return [
      {
        kind: "inline",
        id: "root.0",
        text: root.text,
        language: root.language,
        wrapperPayload: false,
        sourceSpan: { start: 0, end: root.text.length },
        highlightSpan: { start: 0, end: root.text.length },
      },
    ];
  }
  if (pieces.length > 0) return pieces;
  if (!root.text) return pieces;
  pieces.push({
    kind: "inline",
    id: "root.0",
    text: root.text,
    language: root.language,
    wrapperPayload: false,
    sourceSpan: { start: 0, end: root.text.length },
    highlightSpan: { start: 0, end: root.text.length },
  });
  return pieces;
}
