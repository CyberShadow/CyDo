import {
  buildFlowSourceTree,
  type FlowDocument,
  type FlowSink,
  type FlowSource,
} from "./contentFlow";
import {
  assertValidParsedShellDocument,
  type ParsedShellDocument,
  type ParsedShellEmbeddedInvocation,
  type ParsedShellHeredocRedirect,
} from "./shellParser";
import { fileSink, shellArgumentWords, shellFdTable } from "./shellFdTable";
import { ownsWholeCommand } from "./shellInvocationOwnership";
import type {
  SourceSegment,
  SourceTreeParseResult,
  SourceTreeRejectCode,
} from "./sourceTree";

type SourceEmbedSegment = Extract<SourceSegment, { kind: "embed" }>;
type SourceTreeRejection = Extract<SourceTreeParseResult, { ok: false }>;

const unknownSink = { kind: "unknown" } as const;

function heredocSinks(
  document: ParsedShellDocument,
  redirect: ParsedShellHeredocRedirect,
): readonly FlowSink[] {
  const owner = document.commands[redirect.ownerId]!;
  if (owner.name.kind !== "literal" || redirect.header.continuation)
    return [unknownSink];
  const executable = owner.name.value.split("/").at(-1);
  if (executable !== "cat" && executable !== "tee") return [unknownSink];

  const fds = shellFdTable(document, redirect.ownerId);
  const stdin = fds.get(0)!;
  if (stdin.kind !== "source" || stdin.redirectId !== redirect.id)
    return [unknownSink];
  const output = fds.get(1)!;
  const stdout =
    output.kind === "source" || output.kind === "inherited-stdin"
      ? unknownSink
      : output;
  const args = shellArgumentWords(
    [...owner.arguments, ...redirect.header.arguments],
    owner.redirectIds.map((id) => document.redirects[id]!),
  );
  if (executable === "cat") {
    return args.every((word) => word.kind === "literal" && word.value === "-")
      ? [stdout]
      : [unknownSink];
  }

  let mode: "overwrite" | "append" = "overwrite";
  let options = true;
  const paths: (string | null)[] = [];
  for (const word of args) {
    if (word.kind !== "literal") {
      paths.push(null);
    } else if (options && word.value === "--") {
      options = false;
    } else if (options && (word.value === "-a" || word.value === "--append")) {
      mode = "append";
    } else if (options && word.value.startsWith("-") && word.value !== "-") {
      return [unknownSink];
    } else {
      paths.push(word.value);
    }
  }
  return [
    ...paths.map((path) =>
      path === null ? unknownSink : fileSink(path, mode),
    ),
    stdout,
  ];
}

function heredocOrigin(
  redirect: ParsedShellHeredocRedirect,
): FlowSource["origin"] {
  return {
    language: "bash",
    construct: "heredoc-body",
    attributes: {
      delimiter: redirect.delimiter.value,
      quoted: redirect.delimiter.quoted,
      supportsExitReentry: false,
    },
  };
}

function invocationSource(
  document: ParsedShellDocument,
  invocation: ParsedShellEmbeddedInvocation,
): FlowSource {
  const { payload, interpreter, child } = invocation;
  const inline = invocation.kind === "inline";
  const redirect = inline
    ? null
    : (document.redirects[
        invocation.heredocRedirectId
      ] as ParsedShellHeredocRedirect);
  const attributes: Record<string, string | number | boolean> = {
    quote: payload.quoteKind ?? "projected",
  };
  if (inline && interpreter.language === "bash")
    attributes.ownsWholeCommand = ownsWholeCommand(document, invocation);
  return {
    span: redirect?.contentSpan ?? payload.projection.span,
    layout: inline ? "inline" : "block",
    origin:
      redirect === null
        ? { language: "bash", construct: "command-wrapper-payload", attributes }
        : heredocOrigin(redirect),
    value: {
      text: payload.text,
      projection: { points: payload.projection.points },
    },
    sinks: [
      {
        kind: "program",
        language: interpreter.language,
        channel: inline ? "argv" : "stdin",
      },
    ],
    child: child === null ? null : analyzeShellDocument(child),
  };
}

export function analyzeShellDocument(
  document: ParsedShellDocument,
): FlowDocument {
  const sources: FlowSource[] = [];
  const heredocInvocationIds = new Set<number>();
  for (const invocation of document.embeddedInvocations) {
    sources.push(invocationSource(document, invocation));
    if (invocation.kind === "heredoc")
      heredocInvocationIds.add(invocation.heredocRedirectId);
  }
  for (const redirect of document.redirects) {
    if (redirect.kind !== "heredoc" || heredocInvocationIds.has(redirect.id))
      continue;
    const span = redirect.contentSpan;
    const text = document.source.slice(span.start, span.end);
    const points = [{ child: 0, parent: 0 }];
    if (text.length > 0)
      points.push({ child: text.length, parent: text.length });
    sources.push({
      span,
      layout: "block",
      origin: heredocOrigin(redirect),
      value: { text, projection: { points } },
      sinks: heredocSinks(document, redirect),
      child: null,
    });
  }
  return { language: "bash", text: document.source, sources };
}

function sourceTreeRejection(
  document: ParsedShellDocument,
): SourceTreeRejection | null {
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
  for (const { child } of document.embeddedInvocations) {
    if (child === null) continue;
    const rejection = sourceTreeRejection(child);
    if (rejection !== null) return rejection;
  }
  return null;
}

export function buildShellSourceTree(
  document: ParsedShellDocument,
): SourceTreeParseResult {
  assertValidParsedShellDocument(document);
  return (
    sourceTreeRejection(document) ?? {
      ok: true,
      value: buildFlowSourceTree(analyzeShellDocument(document)),
    }
  );
}

function reject(
  code: SourceTreeRejectCode,
  reason: string,
): SourceTreeRejection {
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
