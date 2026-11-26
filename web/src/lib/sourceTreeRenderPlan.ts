import {
  prepareEmbedProjection,
  type ProjectOffset,
  type SourceNode,
  type SourceSpan,
  type SourceSegment,
} from "./sourceTree";

type SourceEmbedRenderMode = "inline" | "rich-markdown" | "rich-code";

type EmbedSegment = Extract<SourceSegment, { kind: "embed" }>;

export type SourceRenderPiece =
  | {
      kind: "inline";
      id: string;
      text: string;
      highlightSource: SourceNode;
      language: string;
      projectedInline: boolean;
      sourceSpan: SourceSpan;
      highlightSpan: SourceSpan;
      projection?: () => ProjectOffset;
    }
  | {
      kind: "rich";
      id: string;
      text: string;
      sourceText: string;
      language: string;
      mode: Exclude<SourceEmbedRenderMode, "inline">;
      document?: EmbedSegment["document"];
      sourceSpan: SourceSpan;
    };

function getRichRenderModeForLanguage(
  language: string,
): Exclude<SourceEmbedRenderMode, "inline"> | null {
  if (language === "markdown") return "rich-markdown";
  if (language === "") return null;
  if (language === "text" || language === "plain") return null;
  if (language === "terminal-output" || language === "process-output")
    return null;
  return "rich-code";
}

function classifyEmbedRenderMode(segment: EmbedSegment): SourceEmbedRenderMode {
  if (segment.presentation?.kind !== "rich") return "inline";
  return getRichRenderModeForLanguage(segment.content.language) ?? "inline";
}

type ProjectionPath = {
  mapSpan(span: SourceSpan): SourceSpan | null;
  cursor(): ProjectOffset;
};

function projectionPath(cursor: () => ProjectOffset): ProjectionPath {
  const start = cursor();
  const end = cursor();
  return {
    cursor,
    mapSpan(span) {
      const from = start(span.start);
      const to = end(span.end);
      return from === null || to === null || to < from
        ? null
        : { start: from, end: to };
    },
  };
}

function walkSourceRenderPieces(
  root: SourceNode,
  node: SourceNode,
  path: string,
  projection: ProjectionPath,
  projectedInline: boolean,
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
          projection,
          segPath,
          projectedInline,
          segment,
          pieces,
        )
      )
        return false;
      continue;
    }

    const mode = classifyEmbedRenderMode(segment);
    if (mode === "inline") {
      const rawSubtreeSpan = projection.mapSpan(segment.span);
      if (!rawSubtreeSpan) return false;
      const childProjectedInline =
        projectedInline || segment.projection != null;
      if (
        !walkInlineSubtree(
          root,
          segment,
          segPath,
          projection,
          childProjectedInline,
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
          projectedInline: childProjectedInline,
          sourceSpan: rawSubtreeSpan,
          highlightSource: node,
          highlightSpan: segment.span,
        });
      }
      continue;
    }

    const sourceSpan = projection.mapSpan(segment.span);
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
      document: segment.document,
      sourceSpan,
    });
  }
  return true;
}

function walkInlineSubtree(
  root: SourceNode,
  segment: EmbedSegment,
  segPath: string,
  projection: ProjectionPath,
  projectedInline: boolean,
  pieces: SourceRenderPiece[],
): boolean {
  const nestedPieces: SourceRenderPiece[] = [];
  const edge = prepareEmbedProjection(segment);
  if (!edge) return false;
  const nestedPath = projectionPath(() => {
    const local = edge();
    const outer = projection.cursor();
    return (offset) => {
      const mapped = local(offset);
      return mapped === null ? null : outer(mapped);
    };
  });
  const ok = walkSourceRenderPieces(
    root,
    segment.content,
    `${segPath}.content`,
    nestedPath,
    projectedInline,
    nestedPieces,
  );
  if (!ok) return false;
  for (const piece of nestedPieces) pieces.push(piece);
  return true;
}

function pushInlineTextPiece(
  root: SourceNode,
  node: SourceNode,
  projection: ProjectionPath,
  id: string,
  projectedInline: boolean,
  segment: Extract<SourceSegment, { kind: "text" }>,
  pieces: SourceRenderPiece[],
): boolean {
  const highlightText = node.text.slice(segment.span.start, segment.span.end);
  if (!highlightText) return true;
  const sourceSpan = projection.mapSpan(segment.span);
  if (!sourceSpan) return false;
  const text = root.text.slice(sourceSpan.start, sourceSpan.end);
  if (!text) return true;

  if (text === highlightText) {
    pieces.push({
      kind: "inline",
      id,
      text,
      language: node.language,
      projectedInline,
      sourceSpan,
      highlightSource: node,
      highlightSpan: segment.span,
    });
    return true;
  }

  pieces.push({
    kind: "inline",
    id,
    text,
    language: node.language,
    projectedInline,
    sourceSpan,
    highlightSource: node,
    highlightSpan: segment.span,
    projection: () => {
      const project = projection.cursor();
      return (offset) => {
        const raw = project(segment.span.start + offset);
        return raw === null ? null : raw - sourceSpan.start;
      };
    },
  });
  return true;
}

export function buildSourceRenderPieces(root: SourceNode): SourceRenderPiece[] {
  const pieces: SourceRenderPiece[] = [];
  const ok = walkSourceRenderPieces(
    root,
    root,
    "root",
    projectionPath(
      () => (offset) =>
        Number.isInteger(offset) && offset >= 0 && offset <= root.text.length
          ? offset
          : null,
    ),
    false,
    pieces,
  );
  if (!ok) {
    return [
      {
        kind: "inline",
        id: "root.0",
        text: root.text,
        language: root.language,
        projectedInline: false,
        sourceSpan: { start: 0, end: root.text.length },
        highlightSource: root,
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
    projectedInline: false,
    sourceSpan: { start: 0, end: root.text.length },
    highlightSource: root,
    highlightSpan: { start: 0, end: root.text.length },
  });
  return pieces;
}
