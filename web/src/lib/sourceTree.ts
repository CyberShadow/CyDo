export interface SourceNode {
  language: string;
  text: string;
  segments: SourceSegment[];
}

export interface SourceEmbedOrigin {
  language: string;
  construct: string;
  attributes?: Record<string, string | number | boolean>;
}

export type SourceEmbedPresentation = { kind: "inline" } | { kind: "rich" };

export type SourceSegment =
  | { kind: "text"; span: SourceSpan }
  | {
      kind: "embed";
      span: SourceSpan;
      content: SourceNode;
      origin?: SourceEmbedOrigin;
      presentation?: SourceEmbedPresentation;
      projection?: SourceProjection;
    };

export interface SourceSpan {
  start: number;
  end: number;
}

export interface SourceProjection {
  points: SourceProjectionPoint[];
}

export interface SourceProjectionPoint {
  child: number;
  parent: number;
}

export type SourceTreeRejectCode =
  | "empty"
  | "unterminated_quote"
  | "unsafe_shell_syntax"
  | "unsupported_command"
  | "unsupported_option"
  | "missing_path"
  | "multiple_paths"
  | "redirection_on_read"
  | "variable_path"
  | "invalid_range"
  | "invalid_heredoc";

export type SourceTreeParseResult =
  | { ok: true; value: SourceNode }
  | { ok: false; code: SourceTreeRejectCode; reason: string };

function isValidSourceSpan(span: SourceSpan): boolean {
  return (
    Number.isInteger(span.start) &&
    Number.isInteger(span.end) &&
    span.start >= 0 &&
    span.end >= span.start
  );
}

function validateProjection(
  projection: SourceProjection,
): { ok: true; maxChild: number } | { ok: false } {
  const points = projection.points;
  if (points.length < 1) return { ok: false };
  for (const point of points) {
    if (
      !Number.isInteger(point.child) ||
      !Number.isInteger(point.parent) ||
      point.child < 0 ||
      point.parent < 0
    ) {
      return { ok: false };
    }
  }
  if (points[0]!.child !== 0 || points[0]!.parent !== 0) {
    return { ok: false };
  }
  if (points.length === 1) return { ok: true, maxChild: 0 };
  for (let i = 1; i < points.length; i++) {
    const prev = points[i - 1]!;
    const curr = points[i]!;
    if (curr.child <= prev.child) return { ok: false };
    if (curr.parent <= prev.parent) return { ok: false };
  }
  return { ok: true, maxChild: points[points.length - 1]!.child };
}

export function projectOffset(
  projection: SourceProjection,
  offset: number,
): number | null {
  if (!Number.isInteger(offset) || offset < 0) return null;
  const validated = validateProjection(projection);
  if (!validated.ok) return null;
  if (offset > validated.maxChild) return null;
  const points = projection.points;
  for (const point of points) {
    if (offset === point.child) return point.parent;
  }
  for (let i = 0; i + 1 < points.length; i++) {
    const from = points[i]!;
    const to = points[i + 1]!;
    if (offset < from.child || offset > to.child) continue;
    const childDelta = to.child - from.child;
    const parentDelta = to.parent - from.parent;
    if (childDelta <= 0 || parentDelta < 0) return null;
    if (parentDelta !== childDelta) return null;
    return from.parent + (offset - from.child);
  }
  return null;
}

export function projectSpan(
  projection: SourceProjection,
  inputSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(inputSpan)) return null;
  const start = projectOffset(projection, inputSpan.start);
  const end = projectOffset(projection, inputSpan.end);
  if (start == null || end == null || end < start) return null;
  return { start, end };
}

export function projectEmbedSpan(
  segment: Extract<SourceSegment, { kind: "embed" }>,
  childSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(childSpan)) return null;
  const childLen = segment.content.text.length;
  const parentLen = segment.span.end - segment.span.start;
  if (childSpan.end > childLen) return null;
  const local = (() => {
    if (segment.projection == null) {
      return { start: childSpan.start, end: childSpan.end };
    }
    const projectedStart = projectOffset(segment.projection, 0);
    const projectedEnd = projectOffset(segment.projection, childLen);
    if (
      projectedStart !== 0 ||
      projectedEnd == null ||
      projectedEnd !== parentLen
    ) {
      return null;
    }
    return projectSpan(segment.projection, childSpan);
  })();
  if (!local) return null;
  if (local.start < 0 || local.end < local.start || local.end > parentLen) {
    return null;
  }
  return {
    start: segment.span.start + local.start,
    end: segment.span.start + local.end,
  };
}

export function projectDescendantSpan(
  ancestor: SourceNode,
  embedPath: number[],
  descendantSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(descendantSpan)) return null;
  const embeds: Array<Extract<SourceSegment, { kind: "embed" }>> = [];
  let node: SourceNode = ancestor;
  for (const index of embedPath) {
    if (
      !Number.isInteger(index) ||
      index < 0 ||
      index >= node.segments.length
    ) {
      return null;
    }
    const segment = node.segments[index];
    if (!segment || segment.kind !== "embed") return null;
    embeds.push(segment);
    node = segment.content;
  }
  if (descendantSpan.end > node.text.length) return null;
  let current: SourceSpan = { ...descendantSpan };
  for (let i = embeds.length - 1; i >= 0; i--) {
    const projected = projectEmbedSpan(embeds[i]!, current);
    if (!projected) return null;
    current = projected;
  }
  return current;
}
