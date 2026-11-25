import { langFromPath } from "../highlight";
import type {
  SourceEmbedOrigin,
  SourceNode,
  SourceProjection,
  SourceSegment,
  SourceSpan,
} from "./sourceTree";

export type FlowValue = Readonly<{
  text: string;
  projection: SourceProjection;
}>;

export type FlowSink =
  | Readonly<{ kind: "file"; path: string; mode: "overwrite" | "append" }>
  | Readonly<{ kind: "program"; language: string; channel: "stdin" | "argv" }>
  | Readonly<{ kind: "discard" }>
  | Readonly<{ kind: "tool-output" }>
  | Readonly<{ kind: "unknown" }>;

export type FlowSource = Readonly<{
  span: SourceSpan;
  layout: "block" | "inline";
  origin: SourceEmbedOrigin;
  value: FlowValue;
  sinks: readonly FlowSink[];
  child: FlowDocument | null;
}>;

export type FlowDocument = Readonly<{
  language: string;
  text: string;
  sources: readonly FlowSource[];
}>;

export function resolveFlowLanguage(sinks: readonly FlowSink[]): Readonly<{
  language: string;
  document: Readonly<{ filePath: string }> | null;
}> {
  const languages = new Set<string>();
  const paths = new Set<string>();
  let hasProgram = false;
  for (const sink of sinks) {
    if (sink.kind === "program") {
      languages.add(sink.language);
      hasProgram = true;
    } else if (sink.kind === "file") {
      const language = langFromPath(sink.path);
      if (language !== null) {
        languages.add(language);
        paths.add(sink.path);
      }
    }
  }
  return {
    language: languages.size === 1 ? [...languages][0]! : "text",
    document:
      !hasProgram && paths.size === 1 ? { filePath: [...paths][0]! } : null,
  };
}

function textSegment(start: number, end: number): SourceSegment | null {
  if (end <= start) return null;
  return { kind: "text", span: { start, end } };
}

function plainNode(language: string, text: string): SourceNode {
  return {
    language,
    text,
    segments: [{ kind: "text", span: { start: 0, end: text.length } }],
  };
}

function shouldUseRichPresentation(
  layout: FlowSource["layout"],
  language: string,
): boolean {
  if (
    layout !== "block" ||
    language === "bash" ||
    language === "shell" ||
    language === "shellscript"
  ) {
    return false;
  }
  return language !== "" && language !== "text" && language !== "shell-output";
}

function selectCandidates(candidates: readonly FlowSource[]): FlowSource[] {
  const sorted = [...candidates].sort(
    (a, b) =>
      a.span.start - b.span.start ||
      b.span.end - b.span.start - (a.span.end - a.span.start),
  );
  const selected: FlowSource[] = [];
  let coveredUntil = -1;
  for (const candidate of sorted) {
    if (candidate.span.start < coveredUntil) continue;
    const previous = selected.at(-1);
    if (
      previous?.span.start === candidate.span.start &&
      previous.span.end === candidate.span.end
    )
      continue;
    selected.push(candidate);
    coveredUntil = Math.max(coveredUntil, candidate.span.end);
  }
  return selected;
}

function buildSegments(
  source: string,
  candidates: readonly FlowSource[],
): SourceSegment[] {
  const segments: SourceSegment[] = [];
  let cursor = 0;
  for (const candidate of candidates) {
    if (candidate.span.start < cursor || candidate.span.end > source.length)
      throw new Error("source-tree candidate span invariant");
    const before = textSegment(cursor, candidate.span.start);
    if (before) segments.push(before);
    const { language, document } = resolveFlowLanguage(candidate.sinks);
    const content =
      candidate.child === null
        ? plainNode(language, candidate.value.text)
        : buildFlowSourceTree(candidate.child);
    segments.push({
      kind: "embed",
      span: candidate.span,
      content,
      origin: candidate.origin,
      projection: candidate.value.projection,
      document: document ?? undefined,
      presentation: shouldUseRichPresentation(
        candidate.layout,
        content.language,
      )
        ? { kind: "rich" }
        : undefined,
    });
    cursor = candidate.span.end;
  }
  const after = textSegment(cursor, source.length);
  if (after) segments.push(after);
  return segments;
}

export function buildFlowSourceTree(document: FlowDocument): SourceNode {
  return {
    language: document.language,
    text: document.text,
    segments: buildSegments(document.text, selectCandidates(document.sources)),
  };
}
