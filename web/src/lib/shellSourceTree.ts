import { langFromPath } from "../highlight";
import {
  assertValidParsedShellDocument,
  type ParsedShellDocument,
  type ParsedShellEmbeddedInvocation,
  type ParsedShellHeredocRedirect,
} from "./shellParser";
import { reduceShellRedirectState } from "./shellRedirectState";
import { ownsWholeCommand } from "./shellInvocationOwnership";
import type {
  SourceNode,
  SourceProjection,
  SourceSegment,
  SourceTreeParseResult,
  SourceTreeRejectCode,
} from "./sourceTree";

type SourceEmbedSegment = Extract<SourceSegment, { kind: "embed" }>;

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

function shouldUseRichHeredocPresentation(language: string): boolean {
  if (
    language === "bash" ||
    language === "shell" ||
    language === "shellscript"
  ) {
    return false;
  }
  return language !== "" && language !== "text" && language !== "shell-output";
}

function childForInvocation(
  invocation: ParsedShellEmbeddedInvocation,
): SourceTreeParseResult {
  const language = invocation.interpreter.language;
  if (language === "bash") return buildShellSourceTree(invocation.child!);
  return { ok: true, value: plainNode(language, invocation.payload.text) };
}

type EmbedCandidate = {
  span: { start: number; end: number };
  segment: SourceEmbedSegment;
};

type EmbedCandidateResult =
  | { ok: true; value: EmbedCandidate }
  | Extract<SourceTreeParseResult, { ok: false }>;

function invocationCandidate(
  document: ParsedShellDocument,
  invocation: ParsedShellEmbeddedInvocation,
): EmbedCandidateResult {
  const child = childForInvocation(invocation);
  if (!child.ok) return child;
  const content = child.value;
  const payload = invocation.payload;
  const segmentSpan = payload.projection.span;
  const attributes: Record<string, string | number | boolean> = {
    quote: payload.quoteKind ?? "projected",
  };
  if (
    invocation.kind === "inline" &&
    invocation.interpreter.language === "bash"
  )
    attributes.ownsWholeCommand = ownsWholeCommand(document, invocation);
  return {
    ok: true,
    value: {
      span: segmentSpan,
      segment: {
        kind: "embed",
        span: segmentSpan,
        content,
        origin: {
          language: "bash",
          construct:
            invocation.kind === "inline"
              ? "command-wrapper-payload"
              : "heredoc-body",
          attributes:
            invocation.kind === "inline"
              ? attributes
              : {
                  delimiter: heredocForInvocation(document, invocation)
                    .delimiter.value,
                  quoted: heredocForInvocation(document, invocation).delimiter
                    .quoted,
                  supportsExitReentry: false,
                },
        },
        projection: { points: payload.projection.points },
        presentation:
          invocation.kind === "heredoc" &&
          shouldUseRichHeredocPresentation(content.language)
            ? { kind: "rich" }
            : undefined,
      },
    },
  };
}

function heredocForInvocation(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "heredoc" }>,
): ParsedShellHeredocRedirect {
  return document.redirects[
    invocation.heredocRedirectId
  ]! as ParsedShellHeredocRedirect;
}

function outputLanguage(
  document: ParsedShellDocument,
  redirect: ParsedShellHeredocRedirect,
): string | null {
  const owner = document.commands[redirect.ownerId]!;
  if (owner.name.kind !== "literal") return null;
  if (owner.name.value.split("/").pop() !== "cat") return null;
  if (redirect.header.arguments.length > 0 || redirect.header.continuation)
    return null;
  const { effectiveStdinRedirectId, literalStdoutPath } =
    reduceShellRedirectState(document, redirect.ownerId);
  if (effectiveStdinRedirectId !== redirect.id) return null;
  if (literalStdoutPath === null) return null;
  return langFromPath(literalStdoutPath) || "text";
}

function heredocCandidate(
  document: ParsedShellDocument,
  redirect: ParsedShellHeredocRedirect,
  invocation: Extract<
    ParsedShellEmbeddedInvocation,
    { kind: "heredoc" }
  > | null,
): EmbedCandidateResult {
  let language: string;
  let content: SourceNode;
  let projection: SourceProjection;
  if (invocation !== null) {
    const child = childForInvocation(invocation);
    if (!child.ok) return child;
    content = child.value;
    language = content.language;
    projection = { points: invocation.payload.projection.points };
  } else {
    language = outputLanguage(document, redirect) ?? "text";
    const text = document.source.slice(
      redirect.contentSpan.start,
      redirect.contentSpan.end,
    );
    content = plainNode(language, text);
    projection = {
      points:
        text.length === 0
          ? [{ child: 0, parent: 0 }]
          : [
              { child: 0, parent: 0 },
              { child: text.length, parent: text.length },
            ],
    };
  }
  const span = redirect.contentSpan;
  return {
    ok: true,
    value: {
      span,
      segment: {
        kind: "embed",
        span,
        content,
        origin: {
          language: "bash",
          construct: "heredoc-body",
          attributes: {
            delimiter: redirect.delimiter.value,
            quoted: redirect.delimiter.quoted,
            supportsExitReentry: false,
          },
        },
        projection,
        presentation: shouldUseRichHeredocPresentation(language)
          ? { kind: "rich" }
          : undefined,
      },
    },
  };
}

function selectCandidates(
  candidates: readonly EmbedCandidate[],
): EmbedCandidate[] {
  const sorted = [...candidates].sort(
    (a, b) =>
      a.span.start - b.span.start ||
      b.span.end - b.span.start - (a.span.end - a.span.start),
  );
  const selected: EmbedCandidate[] = [];
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
  candidates: readonly EmbedCandidate[],
): SourceSegment[] {
  const segments: SourceSegment[] = [];
  let cursor = 0;
  for (const candidate of candidates) {
    if (candidate.span.start < cursor || candidate.span.end > source.length)
      throw new Error("source-tree candidate span invariant");
    const before = textSegment(cursor, candidate.span.start);
    if (before) segments.push(before);
    segments.push(candidate.segment);
    cursor = candidate.span.end;
  }
  const after = textSegment(cursor, source.length);
  if (after) segments.push(after);
  return segments;
}

export function buildShellSourceTree(
  document: ParsedShellDocument,
): SourceTreeParseResult {
  assertValidParsedShellDocument(document);
  const diagnostic = document.diagnostics.find(
    (candidate) =>
      !(
        candidate.kind === "unsupported_wrapper" &&
        candidate.issue === "wrong_flag"
      ),
  );
  if (diagnostic !== undefined) {
    if (diagnostic.kind === "child_parse_failed")
      return reject(
        diagnostic.reason === "invalid_heredoc"
          ? "invalid_heredoc"
          : "unsafe_shell_syntax",
        `shell parser rejected child: ${diagnostic.reason}`,
      );
    if (diagnostic.kind === "unsupported_heredoc_header")
      return reject("invalid_heredoc", "shell parser rejected heredoc header");
    return reject(
      "unsafe_shell_syntax",
      `shell parser rejected ${diagnostic.kind}`,
    );
  }
  const candidates: EmbedCandidate[] = [];
  const heredocInvocationIds = new Set<number>();
  for (let index = 0; index < document.embeddedInvocations.length; index++) {
    const invocation = document.embeddedInvocations[index]!;
    if (invocation.kind === "heredoc")
      heredocInvocationIds.add(invocation.heredocRedirectId);
    const candidate =
      invocation.kind === "heredoc"
        ? heredocCandidate(
            document,
            heredocForInvocation(document, invocation),
            invocation,
          )
        : invocationCandidate(document, invocation);
    if (!candidate.ok) return candidate;
    candidates.push(candidate.value);
  }
  for (const redirect of document.redirects) {
    if (redirect.kind !== "heredoc") continue;
    if (heredocInvocationIds.has(redirect.id)) continue;
    const candidate = heredocCandidate(document, redirect, null);
    if (!candidate.ok) return candidate;
    candidates.push(candidate.value);
  }
  const selected = selectCandidates(candidates);
  return {
    ok: true,
    value: {
      language: "bash",
      text: document.source,
      segments: buildSegments(document.source, selected),
    },
  };
}

function reject(
  code: SourceTreeRejectCode,
  reason: string,
): SourceTreeParseResult {
  return { ok: false, code, reason };
}

export function isShellCommandWrapperEmbed(
  segment: SourceEmbedSegment,
): boolean {
  return (
    segment.origin?.language === "bash" &&
    segment.origin.construct === "command-wrapper-payload" &&
    segment.projection != null &&
    segment.content.language === "bash"
  );
}
