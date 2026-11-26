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

type SourceEmbedPresentation = { kind: "inline" } | { kind: "rich" };

export type SourceSegment =
  | { kind: "text"; span: SourceSpan }
  | {
      kind: "embed";
      span: SourceSpan;
      content: SourceNode;
      origin?: SourceEmbedOrigin;
      presentation?: SourceEmbedPresentation;
      projection?: SourceProjection;
      document?: Readonly<{ filePath: string }>;
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

export type ProjectOffset = (offset: number) => number | null;

function projectionCursor(
  points: readonly SourceProjectionPoint[],
): ProjectOffset {
  let index = -1;
  let previous = -1;
  return (offset) => {
    if (
      !Number.isInteger(offset) ||
      offset < 0 ||
      offset > points.at(-1)!.child
    )
      return null;
    if (index < 0 || offset < previous) {
      let first = 0;
      let last = points.length - 1;
      while (first < last) {
        const middle = Math.ceil((first + last) / 2);
        if (points[middle]!.child <= offset) first = middle;
        else last = middle - 1;
      }
      index = first;
    } else {
      while (index + 1 < points.length && points[index + 1]!.child <= offset)
        index++;
    }
    previous = offset;
    const from = points[index]!;
    if (from.child === offset) return from.parent;
    const to = points[index + 1]!;
    return to.parent - from.parent === to.child - from.child
      ? from.parent + offset - from.child
      : null;
  };
}

export function prepareEmbedProjection(
  segment: Extract<SourceSegment, { kind: "embed" }>,
): (() => ProjectOffset) | null {
  const childLength = segment.content.text.length;
  const { start, end } = segment.span;
  const projection = segment.projection;
  if (!projection)
    return () => (offset) =>
      offset >= 0 && offset <= Math.min(end - start, childLength)
        ? start + offset
        : null;
  const validated = validateProjection(projection);
  if (!validated.ok || validated.maxChild < childLength) return null;
  const check = projectionCursor(projection.points);
  if (check(childLength) !== end - start) return null;
  return () => {
    const project = projectionCursor(projection.points);
    return (offset) => {
      if (offset > childLength) return null;
      const mapped = project(offset);
      return mapped === null ? null : start + mapped;
    };
  };
}

export function simplifyProjectionPoints(
  points: readonly SourceProjectionPoint[],
): readonly SourceProjectionPoint[] {
  if (points.length <= 2) return points;
  const keep = new Set<number>([0, points.length - 1]);
  for (let i = 1; i < points.length; i++) {
    const previous = points[i - 1]!;
    const current = points[i]!;
    if (current.parent - current.child !== previous.parent - previous.child) {
      keep.add(i - 1);
      keep.add(i);
    }
  }
  return points.filter((_point, index) => keep.has(index));
}
