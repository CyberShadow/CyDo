import { Language, Parser, type Node, type Tree } from "web-tree-sitter";
import type {
  SourceProjection,
  SourceProjectionPoint,
  SourceSpan,
} from "./sourceTree";

type ParsedShellSpan = SourceSpan;
type ParsedShellProjectionPoint = SourceProjectionPoint;

type ParsedShellProjection = SourceProjection & Readonly<{ span: SourceSpan }>;

type ParsedShellWordSyntax =
  | "word"
  | "raw_string"
  | "string"
  | "concatenation"
  | "synthetic";

type ParsedShellNonLiteralReason =
  | "unsafe_unquoted"
  | "dynamic_child"
  | "unsupported_node"
  | "invalid_quoting";

type ParsedShellWord =
  | Readonly<{
      kind: "literal";
      syntax: ParsedShellWordSyntax;
      rawSpan: ParsedShellSpan;
      value: string;
      projection: ParsedShellProjection;
    }>
  | Readonly<{
      kind: "nonliteral";
      syntax: string;
      rawSpan: ParsedShellSpan;
      reason: ParsedShellNonLiteralReason;
      nodeTypes: readonly string[];
    }>;

type ParsedShellRedirectDescriptor = Readonly<{
  kind: "number";
  value: string;
  rawSpan: ParsedShellSpan;
}>;

type ParsedShellArgument = Readonly<{
  word: ParsedShellWord;
  synthetic: boolean;
}>;

type ParsedShellAssignment = Readonly<{
  span: ParsedShellSpan;
  name: string;
  nameSpan: ParsedShellSpan;
  value: ParsedShellWord | null;
}>;

export type ParsedShellCommandId = number;
type ParsedShellRedirectId = number;
type ParsedShellInvocationId = number;

type ParsedShellOperator = Readonly<{
  kind: "and" | "or" | "pipe" | "pipe_stderr";
  text: "&&" | "||" | "|" | "|&";
  span: ParsedShellSpan;
}>;

type ParsedShellBoundary = Readonly<{
  kind: "newline" | "semicolon" | "background" | "case";
  text: "\n" | "\r\n" | ";" | "&" | ";;";
  span: ParsedShellSpan;
}>;

type ParsedShellFileRedirectOperator =
  | "<"
  | ">"
  | ">>"
  | "&>"
  | "&>>"
  | "<&"
  | ">&"
  | ">|";

type ParsedShellFileRedirect = Readonly<{
  kind: "file";
  id: ParsedShellRedirectId;
  ownerId: ParsedShellCommandId;
  span: ParsedShellSpan;
  operator: ParsedShellFileRedirectOperator;
  operatorSpan: ParsedShellSpan;
  descriptor: ParsedShellRedirectDescriptor | null;
  destination: ParsedShellWord | null;
}>;

type ParsedShellHereStringRedirect = Readonly<{
  kind: "herestring";
  id: ParsedShellRedirectId;
  ownerId: ParsedShellCommandId;
  span: ParsedShellSpan;
  operator: "<<<";
  operatorSpan: ParsedShellSpan;
  descriptor: ParsedShellRedirectDescriptor | null;
  value: ParsedShellWord;
}>;

type ParsedShellHeaderUnit =
  | Readonly<{
      kind: "command";
      span: ParsedShellSpan;
      name: ParsedShellWord;
      arguments: readonly ParsedShellArgument[];
    }>
  | Readonly<{
      kind: "list" | "pipeline";
      span: ParsedShellSpan;
      children: readonly ParsedShellHeaderUnit[];
      operators: readonly ParsedShellOperator[];
    }>
  | Readonly<{
      kind: "opaque";
      span: ParsedShellSpan;
      nodeType: string;
    }>;

type ParsedShellHeredocContinuation =
  | Readonly<{
      kind: "right";
      operator: ParsedShellOperator;
      unit: ParsedShellHeaderUnit;
    }>
  | Readonly<{
      kind: "pipeline";
      unit: ParsedShellHeaderUnit;
    }>;

export type ParsedShellHeredocRedirect = Readonly<{
  kind: "heredoc";
  id: ParsedShellRedirectId;
  ownerId: ParsedShellCommandId;
  span: ParsedShellSpan;
  descriptor: ParsedShellRedirectDescriptor | null;
  operator: "<<";
  operatorSpan: ParsedShellSpan;
  headerSpan: ParsedShellSpan;
  headerLineBreakSpan: ParsedShellSpan;
  delimiter: Readonly<{
    value: string;
    rawSpan: ParsedShellSpan;
    quoted: boolean;
  }>;
  rawBodySpan: ParsedShellSpan;
  contentSpan: ParsedShellSpan;
  terminatorSpan: ParsedShellSpan;
  header: Readonly<{
    arguments: readonly ParsedShellArgument[];
    continuation: ParsedShellHeredocContinuation | null;
  }>;
  nestedRedirectIds: readonly ParsedShellRedirectId[];
}>;

export type ParsedShellRedirect =
  | ParsedShellFileRedirect
  | ParsedShellHereStringRedirect
  | ParsedShellHeredocRedirect;

export type ParsedShellCommand = Readonly<{
  id: ParsedShellCommandId;
  span: ParsedShellSpan;
  name: ParsedShellWord;
  assignments: readonly ParsedShellAssignment[];
  arguments: readonly ParsedShellArgument[];
  redirectIds: readonly ParsedShellRedirectId[];
}>;

export type ParsedShellUnit =
  | Readonly<{
      kind: "program";
      span: ParsedShellSpan;
      children: readonly ParsedShellUnit[];
      boundaries: readonly ParsedShellBoundary[];
    }>
  | Readonly<{
      kind: "list" | "pipeline";
      span: ParsedShellSpan;
      children: readonly ParsedShellUnit[];
      operators: readonly ParsedShellOperator[];
    }>
  | Readonly<{
      kind: "redirected_statement";
      span: ParsedShellSpan;
      body: ParsedShellUnit;
      redirectIds: readonly ParsedShellRedirectId[];
    }>
  | Readonly<{
      kind: "command";
      span: ParsedShellSpan;
      commandId: ParsedShellCommandId;
    }>
  | Readonly<{
      kind: "opaque";
      span: ParsedShellSpan;
      nodeType: string;
      reason: "unsupported_construct" | "control_body";
    }>;

type ParsedShellEnvironmentAssignment = Readonly<{
  argumentIndex: number;
  name: string;
  value: string;
}>;

type ParsedShellInvocationPrefix =
  | Readonly<{ kind: "direct" }>
  | Readonly<{
      kind: "env";
      assignments: readonly ParsedShellEnvironmentAssignment[];
    }>;

type ParsedShellInterpreter = Readonly<{
  location:
    | Readonly<{ kind: "command_name" }>
    | Readonly<{ kind: "argument"; index: number }>;
  basename: string;
  language: string;
}>;

type ParsedShellPayloadQuoteKind = "single" | "double" | "projected";

type ParsedShellPayload = Readonly<{
  text: string;
  rawSpan: ParsedShellSpan;
  contentSpan: ParsedShellSpan;
  projection: ParsedShellProjection;
  quoteKind: ParsedShellPayloadQuoteKind | null;
}>;

type ParsedShellInvocationBase = Readonly<{
  id: ParsedShellInvocationId;
  commandId: ParsedShellCommandId;
  prefix: ParsedShellInvocationPrefix;
  interpreter: ParsedShellInterpreter;
  optionArgumentIndices: readonly number[];
  payload: ParsedShellPayload;
  child: ParsedShellDocument | null;
}>;

export type ParsedShellEmbeddedInvocation =
  | (ParsedShellInvocationBase &
      Readonly<{
        kind: "inline";
        flagArgumentIndex: number;
        payloadArgumentIndex: number;
      }>)
  | (ParsedShellInvocationBase &
      Readonly<{
        kind: "heredoc";
        heredocRedirectId: ParsedShellRedirectId;
        stdinArgumentIndex: number | null;
      }>);

type ParsedShellDiagnostic =
  | Readonly<{
      kind: "unsupported_control";
      span: ParsedShellSpan;
      operator: "||" | "|&" | "&" | ";;";
    }>
  | Readonly<{
      kind: "unsupported_construct";
      span: ParsedShellSpan;
      nodeType: string;
    }>
  | Readonly<{
      kind: "unsupported_env";
      span: ParsedShellSpan;
      issue:
        | "option"
        | "dynamic_assignment"
        | "missing_interpreter"
        | "unknown_interpreter";
    }>
  | Readonly<{
      kind: "unsupported_wrapper";
      span: ParsedShellSpan;
      issue:
        | "wrong_flag"
        | "missing_payload"
        | "dynamic_payload"
        | "extra_argument"
        | "unsupported_stdin_arguments";
    }>
  | Readonly<{
      kind: "unsupported_heredoc_header";
      span: ParsedShellSpan;
      issue: "arguments" | "right" | "pipe_stderr";
    }>
  | Readonly<{
      kind: "child_parse_failed";
      span: ParsedShellSpan;
      reason: "unsafe_shell_syntax" | "invalid_heredoc";
    }>;

export type ParsedShellDocument = Readonly<{
  source: string;
  program: Extract<ParsedShellUnit, { kind: "program" }>;
  commands: readonly ParsedShellCommand[];
  redirects: readonly ParsedShellRedirect[];
  embeddedInvocations: readonly ParsedShellEmbeddedInvocation[];
  diagnostics: readonly ParsedShellDiagnostic[];
}>;

export type ShellParserAssets =
  | Readonly<{ kind: "urls"; runtime: string; bashLanguage: string }>
  | Readonly<{
      kind: "bytes";
      loadRuntime(): Promise<Uint8Array>;
      loadBashLanguage(): Promise<Uint8Array>;
    }>;

export type ParseResult =
  | Readonly<{ ok: true; document: ParsedShellDocument }>
  | Readonly<{ ok: false; reason: "parser_initialization_failed" }>
  | Readonly<{
      ok: false;
      reason: "unsafe_shell_syntax";
      issue: "error_node" | "missing_node" | "no_tree" | "word_boundary";
      span: ParsedShellSpan;
    }>
  | Readonly<{
      ok: false;
      reason: "invalid_heredoc";
      issue:
        | "incomplete"
        | "multiple"
        | "indented"
        | "unsupported_delimiter"
        | "missing_owner";
      span: ParsedShellSpan;
    }>;

export function configureShellParserAssets(assets: ShellParserAssets): void {
  if (configuredAssets !== undefined)
    throw new Error("shell parser assets are already configured");
  configuredAssets = assets;
}

export function preloadShellParser(): void {
  ensureConfigured();
  const initialization = getInitialization();
  if (preloadReported) return;
  preloadReported = true;
  void initialization.catch((error: unknown) => {
    console.error("Failed to preload shell parser", error);
  });
}

export function loadParsedShellDocument(source: string): Promise<ParseResult> {
  ensureConfigured();
  const cached = parsedDocumentCache.get(source);
  if (cached !== undefined) {
    if (cached.kind === "settled") {
      parsedDocumentCache.delete(source);
      parsedDocumentCache.set(source, cached);
      return Promise.resolve(cached.result);
    }
    parsedDocumentCache.delete(source);
    parsedDocumentCache.set(source, cached);
    return cached.promise;
  }

  const promise = parseSource(source).then(
    (result) => {
      const entry = parsedDocumentCache.get(source);
      if (entry?.kind === "pending" && entry.promise === promise) {
        parsedDocumentCache.set(source, {
          kind: "settled",
          result,
        });
        evictSettledEntries();
      }
      return result;
    },
    (error: unknown) => {
      const entry = parsedDocumentCache.get(source);
      if (entry?.kind === "pending" && entry.promise === promise)
        parsedDocumentCache.delete(source);
      throw error;
    },
  );
  parsedDocumentCache.set(source, { kind: "pending", promise });
  return promise;
}

export function getCachedParsedShellDocument(
  source: string,
): ParseResult | undefined {
  ensureConfigured();
  const cached = parsedDocumentCache.get(source);
  if (cached === undefined) return undefined;
  if (cached.kind === "pending") return undefined;
  parsedDocumentCache.delete(source);
  parsedDocumentCache.set(source, cached);
  return cached.result;
}

const PARSED_DOCUMENT_CACHE_CAPACITY = 8;
const WASM_MAGIC = [0, 0x61, 0x73, 0x6d];

const INTERPRETERS: Readonly<
  Record<string, Readonly<{ flags: readonly string[]; language: string }>>
> = {
  sh: { flags: ["-c", "-lc", "-cl"], language: "bash" },
  bash: { flags: ["-c", "-lc", "-cl"], language: "bash" },
  zsh: { flags: ["-c", "-lc", "-cl"], language: "bash" },
  python: { flags: ["-c"], language: "python" },
  python3: { flags: ["-c"], language: "python" },
  node: { flags: ["-e"], language: "javascript" },
  nodejs: { flags: ["-e"], language: "javascript" },
  ruby: { flags: ["-e"], language: "ruby" },
  perl: { flags: ["-e"], language: "perl" },
  lua: { flags: ["-e"], language: "lua" },
  php: { flags: ["-r"], language: "php" },
  Rscript: { flags: ["-e"], language: "r" },
  R: { flags: ["-e"], language: "r" },
};

type CacheEntry =
  | Readonly<{
      kind: "pending";
      promise: Promise<ParseResult>;
    }>
  | Readonly<{
      kind: "settled";
      result: ParseResult;
    }>;

const parsedDocumentCache = new Map<string, CacheEntry>();
let configuredAssets: ShellParserAssets | undefined;
let initializationPromise: Promise<void> | undefined;
let initializedParser: Parser | undefined;
let preloadReported = false;

function ensureConfigured(): ShellParserAssets {
  if (configuredAssets === undefined)
    throw new Error("shell parser assets are not configured");
  return configuredAssets;
}

function getInitialization(): Promise<void> {
  ensureConfigured();
  if (initializationPromise !== undefined) return initializationPromise;
  let resolveInitialization!: () => void;
  let rejectInitialization!: (error: unknown) => void;
  initializationPromise = new Promise<void>((resolve, reject) => {
    resolveInitialization = resolve;
    rejectInitialization = reject;
  });
  const assets = ensureConfigured();
  void initializeAssets(assets).then(
    resolveInitialization,
    rejectInitialization,
  );
  return initializationPromise;
}

async function initializeAssets(assets: ShellParserAssets): Promise<void> {
  let language: Language;
  if (assets.kind === "urls") {
    await Parser.init({
      locateFile(fileName: string): string {
        if (fileName !== "web-tree-sitter.wasm")
          throw new Error(`unexpected Tree-sitter runtime file: ${fileName}`);
        return assets.runtime;
      },
    });
    language = await Language.load(assets.bashLanguage);
  } else {
    const [runtimeBytes, bashBytes] = await Promise.all([
      assets.loadRuntime(),
      assets.loadBashLanguage(),
    ]);
    assertWasmMagic(runtimeBytes);
    assertWasmMagic(bashBytes);
    await Parser.init({ wasmBinary: runtimeBytes });
    language = await Language.load(bashBytes);
  }
  const parser = new Parser();
  parser.setLanguage(language);
  initializedParser = parser;
}

function assertWasmMagic(bytes: Uint8Array): void {
  for (let i = 0; i < WASM_MAGIC.length; i++) {
    if (bytes[i] !== WASM_MAGIC[i])
      throw new Error("invalid Tree-sitter WASM magic");
  }
}

function evictSettledEntries(): void {
  let settledCount = 0;
  for (const entry of parsedDocumentCache.values())
    if (entry.kind === "settled") settledCount++;
  while (settledCount > PARSED_DOCUMENT_CACHE_CAPACITY) {
    let removed = false;
    for (const [source, entry] of parsedDocumentCache) {
      if (entry.kind !== "settled") continue;
      parsedDocumentCache.delete(source);
      settledCount--;
      removed = true;
      break;
    }
    if (!removed) throw new Error("settled parser cache eviction invariant");
  }
}

function nodeSpan(node: Node): ParsedShellSpan {
  return { start: node.startIndex, end: node.endIndex };
}

function sourceSpan(
  source: string,
  start: number,
  end: number,
): ParsedShellSpan {
  if (start < 0 || end < start || end > source.length)
    throw new Error("invalid shell source span");
  return { start, end };
}

function projection(
  span: ParsedShellSpan,
  points: readonly ParsedShellProjectionPoint[],
  childLength: number,
): ParsedShellProjection {
  const result: ParsedShellProjection = { span, points: [...points] };
  assertProjection(result, childLength);
  return result;
}

function assertProjection(
  value: ParsedShellProjection,
  childLength: number,
): void {
  if (value.points.length === 0) throw new Error("empty shell projection");
  if (value.points[0]!.child !== 0 || value.points[0]!.parent !== 0)
    throw new Error("invalid shell projection origin");
  for (let i = 1; i < value.points.length; i++) {
    const previous = value.points[i - 1]!;
    const current = value.points[i]!;
    if (current.child <= previous.child || current.parent <= previous.parent)
      throw new Error("non-increasing shell projection");
  }
  const last = value.points[value.points.length - 1]!;
  if (
    last.child !== childLength ||
    last.parent !== value.span.end - value.span.start
  )
    throw new Error("shell projection exceeds source span");
}

function simplifyProjectionPoints(
  points: readonly ParsedShellProjectionPoint[],
): readonly ParsedShellProjectionPoint[] {
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

type LiteralWord = Extract<ParsedShellWord, { kind: "literal" }> & {
  quoteKind: ParsedShellPayloadQuoteKind | null;
};

type WordDecode =
  | LiteralWord
  | Extract<ParsedShellWord, { kind: "nonliteral" }>;

function literalWord(
  syntax: ParsedShellWordSyntax,
  rawSpan: ParsedShellSpan,
  value: string,
  projectionSpan: ParsedShellSpan,
  points: readonly ParsedShellProjectionPoint[],
  quoteKind: ParsedShellPayloadQuoteKind | null = null,
): LiteralWord {
  const simplified = simplifyProjectionPoints(points);
  return {
    kind: "literal",
    syntax,
    rawSpan,
    value,
    projection: projection(projectionSpan, simplified, value.length),
    quoteKind,
  };
}

function nonliteralWord(
  syntax: string,
  rawSpan: ParsedShellSpan,
  reason: ParsedShellNonLiteralReason,
  nodeTypes: readonly string[],
): Extract<ParsedShellWord, { kind: "nonliteral" }> {
  return { kind: "nonliteral", syntax, rawSpan, reason, nodeTypes };
}

function composeLiteralWords(
  words: readonly LiteralWord[],
  source: string,
  rawSpan: ParsedShellSpan,
  quoteKind: ParsedShellPayloadQuoteKind = "projected",
): WordDecode {
  const contributing = words.filter((word) => word.value.length > 0);
  if (contributing.length === 0)
    return nonliteralWord("concatenation", rawSpan, "invalid_quoting", [
      "concatenation",
    ]);
  const first = contributing[0]!;
  const last = contributing[contributing.length - 1]!;
  const projectionStart = first.projection.span.start;
  const projectionEnd = last.projection.span.end;
  const points: SourceProjectionPoint[] = [{ child: 0, parent: 0 }];
  let childOffset = 0;
  for (let partIndex = 0; partIndex < contributing.length; partIndex++) {
    const part = contributing[partIndex]!;
    for (const point of part.projection.points) {
      const child = childOffset + point.child;
      const parent =
        part.projection.span.start - projectionStart + point.parent;
      if (child > points[points.length - 1]!.child)
        points.push({ child, parent });
    }
    if (partIndex + 1 < contributing.length) {
      const next = contributing[partIndex + 1]!;
      points[points.length - 1]!.parent =
        next.syntax === "word" && next.quoteKind === "single"
          ? next.projection.span.start - projectionStart
          : part.syntax === "string" && next.syntax === "raw_string"
            ? next.projection.span.start - projectionStart
            : part.syntax === "word" && part.quoteKind === "single"
              ? part.projection.span.end - projectionStart
              : part.projection.span.end - projectionStart;
    }
    childOffset += part.value.length;
  }
  const endpoint = projectionEnd - projectionStart;
  points[points.length - 1]!.parent = endpoint;
  return literalWord(
    "concatenation",
    rawSpan,
    contributing.map((word) => word.value).join(""),
    sourceSpan(source, projectionStart, projectionEnd),
    points,
    quoteKind,
  );
}

function decodeEscapedContent(
  value: string,
  parentStart: number,
  doubleQuoted: boolean,
): { value: string; points: ParsedShellProjectionPoint[] } | null {
  let decoded = "";
  const points: SourceProjectionPoint[] = [{ child: 0, parent: 0 }];
  for (let i = 0; i < value.length; i++) {
    const character = value[i]!;
    if (character !== "\\") {
      decoded += character;
      points.push({
        child: decoded.length,
        parent: parentStart + i + 1,
      });
      continue;
    }
    const next = value[i + 1];
    if (next === undefined) return null;
    if (next === "\n") {
      i++;
      continue;
    }
    if (next === "\r" && value[i + 2] === "\n") {
      i += 2;
      continue;
    }
    if (
      !doubleQuoted ||
      next === '"' ||
      next === "\\" ||
      next === "$" ||
      next === "`"
    ) {
      decoded += next;
      i++;
      points.push({
        child: decoded.length,
        parent: parentStart + i + 1,
      });
      continue;
    }
    decoded += "\\";
    points.push({
      child: decoded.length,
      parent: parentStart + i + 1,
    });
  }
  const last = points[points.length - 1]!;
  if (last.child === decoded.length) last.parent = parentStart + value.length;
  else
    points.push({
      child: decoded.length,
      parent: parentStart + value.length,
    });
  return { value: decoded, points };
}

function isEscapedBareWord(value: string): boolean {
  let decodedLength = 0;
  for (let i = 0; i < value.length; i++) {
    const character = value[i]!;
    if (character === "\\") {
      const next = value[i + 1];
      if (next === undefined) return false;
      if (next === "\n") {
        i++;
        continue;
      }
      if (next === "\r" && value[i + 2] === "\n") {
        i += 2;
        continue;
      }
      decodedLength++;
      i++;
      continue;
    }
    const allowed =
      decodedLength === 0
        ? /^[A-Za-z0-9_./:@%+=,\u0080-\uFFFF-]$/.test(character)
        : /^[A-Za-z0-9_./:@%+=,\u0080-\uFFFF~-]$/.test(character);
    if (!allowed) return false;
    decodedLength++;
  }
  return decodedLength > 0;
}

function decodeWordNode(
  node: Node,
  source: string,
  allowApostropheBridge = false,
  bridgeProjectionSpan: ParsedShellSpan | null = null,
  allowStaticNumber = false,
): WordDecode {
  const rawSpan = nodeSpan(node);
  const raw = source.slice(rawSpan.start, rawSpan.end);
  if (node.type === "word") {
    if (allowApostropheBridge && raw === "\\'") {
      if (bridgeProjectionSpan === null)
        throw new Error("apostrophe bridge span invariant");
      return literalWord(
        "word",
        rawSpan,
        "'",
        bridgeProjectionSpan,
        [
          { child: 0, parent: 0 },
          {
            child: 1,
            parent: bridgeProjectionSpan.end - bridgeProjectionSpan.start,
          },
        ],
        "single",
      );
    }
    if (
      !/^[A-Za-z0-9_./:@%+=,\u0080-\uFFFF-][A-Za-z0-9_./:@%+=,\u0080-\uFFFF~-]*$/.test(
        raw,
      )
    ) {
      if (!raw.includes("\\"))
        return nonliteralWord("word", rawSpan, "unsafe_unquoted", []);
      if (!isEscapedBareWord(raw))
        return nonliteralWord("word", rawSpan, "unsafe_unquoted", []);
      const decoded = decodeEscapedContent(raw, 0, false);
      if (decoded !== null)
        return literalWord(
          "word",
          rawSpan,
          decoded.value,
          rawSpan,
          decoded.points,
          "projected",
        );
      return nonliteralWord("word", rawSpan, "unsafe_unquoted", []);
    }
    return literalWord(
      "word",
      rawSpan,
      raw,
      rawSpan,
      [
        { child: 0, parent: 0 },
        { child: raw.length, parent: raw.length },
      ],
      "projected",
    );
  }

  if (node.type === "raw_string") {
    if (!(raw.startsWith("'") && raw.endsWith("'")))
      return nonliteralWord("raw_string", rawSpan, "invalid_quoting", [
        node.type,
      ]);
    const contentSpan = sourceSpan(source, rawSpan.start + 1, rawSpan.end - 1);
    const points: SourceProjectionPoint[] = [{ child: 0, parent: 0 }];
    for (let i = 0; i < raw.length - 2; i++)
      points.push({ child: i + 1, parent: i + 1 });
    return literalWord(
      "raw_string",
      rawSpan,
      raw.slice(1, -1),
      contentSpan,
      points,
      "single",
    );
  }

  if (node.type === "string") {
    if (!(raw.startsWith('"') && raw.endsWith('"')))
      return nonliteralWord("string", rawSpan, "invalid_quoting", [node.type]);
    const contentSpan = sourceSpan(source, rawSpan.start + 1, rawSpan.end - 1);
    for (const child of node.children) {
      if (!child.isNamed) continue;
      if (child.type !== "string_content")
        return nonliteralWord("string", rawSpan, "dynamic_child", [child.type]);
    }
    const decoded = decodeEscapedContent(
      source.slice(contentSpan.start, contentSpan.end),
      0,
      true,
    );
    if (decoded === null)
      return nonliteralWord("string", rawSpan, "invalid_quoting", [node.type]);
    if (decoded.value.length === 0 && contentSpan.start !== contentSpan.end)
      return nonliteralWord("string", rawSpan, "invalid_quoting", [node.type]);
    return literalWord(
      "string",
      rawSpan,
      decoded.value,
      contentSpan,
      decoded.points,
      "double",
    );
  }

  if (allowStaticNumber && node.type === "number") {
    return literalWord(
      "word",
      rawSpan,
      raw,
      rawSpan,
      [
        { child: 0, parent: 0 },
        { child: raw.length, parent: raw.length },
      ],
      "projected",
    );
  }

  if (node.type === "concatenation") {
    const children = node.namedChildren;
    const parts = children.map((child, index) => {
      const canBridge =
        child.type === "word" &&
        index > 0 &&
        index + 1 < children.length &&
        children[index - 1]!.type === "raw_string" &&
        children[index + 1]!.type === "raw_string" &&
        child.startIndex === children[index - 1]!.endIndex &&
        child.endIndex === children[index + 1]!.startIndex;
      const bridgeProjectionSpan = canBridge
        ? sourceSpan(
            source,
            children[index - 1]!.endIndex - 1,
            children[index + 1]!.startIndex + 1,
          )
        : null;
      return decodeWordNode(
        child,
        source,
        canBridge,
        bridgeProjectionSpan,
        true,
      );
    });
    const dynamic = parts.filter((part) => part.kind !== "literal");
    if (dynamic.length > 0) {
      return nonliteralWord("concatenation", rawSpan, "dynamic_child", [
        ...new Set(dynamic.flatMap((part) => part.nodeTypes)),
      ]);
    }
    const literalParts = parts as LiteralWord[];
    const hasApostropheBridge = children.some(
      (child, index) =>
        child.type === "word" &&
        index > 0 &&
        index + 1 < children.length &&
        children[index - 1]!.type === "raw_string" &&
        children[index + 1]!.type === "raw_string" &&
        child.startIndex === children[index - 1]!.endIndex &&
        child.endIndex === children[index + 1]!.startIndex,
    );
    const quoteKind =
      hasApostropheBridge &&
      literalParts.every((part) => part.quoteKind === "single")
        ? "single"
        : "projected";
    return composeLiteralWords(literalParts, source, rawSpan, quoteKind);
  }

  const dynamicNode =
    node.type === "expansion" ||
    node.type === "simple_expansion" ||
    node.type === "command_substitution" ||
    node.type === "arithmetic_expansion" ||
    node.type === "process_substitution";
  return nonliteralWord(
    node.type,
    rawSpan,
    dynamicNode ? "dynamic_child" : "unsupported_node",
    [node.type],
  );
}

function decodeRedirectWordNode(node: Node, source: string): WordDecode {
  return decodeWordNode(node, source, false, null, true);
}

function operatorFromNode(node: Node): ParsedShellOperator | null {
  const text = node.type;
  if (text !== "&&" && text !== "||" && text !== "|" && text !== "|&")
    return null;
  return {
    kind:
      text === "&&"
        ? "and"
        : text === "||"
          ? "or"
          : text === "|"
            ? "pipe"
            : "pipe_stderr",
    text,
    span: nodeSpan(node),
  };
}

function boundaryFromNode(node: Node): ParsedShellBoundary | null {
  const text = node.type;
  if (text !== ";" && text !== "&" && text !== ";;") return null;
  return {
    kind: text === ";" ? "semicolon" : text === "&" ? "background" : "case",
    text,
    span: nodeSpan(node),
  };
}

function isControlNode(type: string): boolean {
  return (
    type === "function_definition" ||
    type === "if_statement" ||
    type === "for_statement" ||
    type === "c_style_for_statement" ||
    type === "while_statement" ||
    type === "case_statement" ||
    type === "compound_statement" ||
    type === "subshell"
  );
}

function* walkNodes(
  root: Node,
  childrenOf: (node: Node) => readonly Node[],
): Generator<Node> {
  const pending = [root];
  while (pending.length > 0) {
    const node = pending.pop()!;
    yield node;
    const children = childrenOf(node);
    for (let index = children.length - 1; index >= 0; index--)
      pending.push(children[index]!);
  }
}

function reduceTree<T, R>(
  root: T,
  childrenOf: (node: T) => readonly T[],
  reduce: (node: T, children: R[]) => R,
): R {
  const frameFor = (node: T) => ({
    node,
    children: childrenOf(node),
    results: [] as R[],
  });
  const stack = [frameFor(root)];
  for (;;) {
    const frame = stack.at(-1)!;
    if (frame.results.length < frame.children.length) {
      stack.push(frameFor(frame.children[frame.results.length]!));
      continue;
    }
    const result = reduce(frame.node, frame.results);
    stack.pop();
    const parent = stack.at(-1);
    if (parent === undefined) return result;
    parent.results.push(result);
  }
}

function commandUnitChildren(node: Node): readonly Node[] {
  if (node.type === "redirected_statement") {
    const body = node.childForFieldName("body");
    return body === null ? [] : [body];
  }
  if (
    node.type === "program" ||
    node.type === "list" ||
    node.type === "pipeline"
  )
    return node.namedChildren.filter((child) => !child.isExtra);
  return [];
}

function collectCommandNodes(node: Node, result: Node[]): void {
  for (const child of walkNodes(node, (unit) =>
    unit.type === "ERROR" ? unit.namedChildren : commandUnitChildren(unit),
  )) {
    if (child.type === "command") result.push(child);
  }
}

function rightEdge(node: Node): Node | null {
  let current: Node | undefined = node;
  while (current !== undefined) {
    if (current.type === "command") return current;
    current = commandUnitChildren(current).at(-1);
  }
  return null;
}

function redirectedStatementAncestor(node: Node): Node | null {
  let current = node.parent;
  while (current !== null) {
    if (current.type === "redirected_statement") return current;
    current = current.parent;
  }
  return null;
}

function heredocOwnerNode(node: Node): Node | null {
  if (node.parent?.type === "command") return node.parent;
  const wrapper = redirectedStatementAncestor(node);
  if (wrapper === null) return null;
  const body = wrapper.childForFieldName("body");
  if (body === null) return null;
  return rightEdge(body);
}

function shellSyntaxChildren(node: Node): readonly Node[] {
  return node.type === "heredoc_body" ? [] : node.children;
}

function collectHeredocNodes(root: Node, result: Node[]): void {
  for (const node of walkNodes(root, shellSyntaxChildren)) {
    if (node.type === "heredoc_redirect") result.push(node);
  }
}

type NativeRedirect = {
  node: Node;
  owner: Node | null;
  inHeredoc: boolean;
};

function collectRedirectNodes(root: Node): NativeRedirect[] {
  const redirects: NativeRedirect[] = [];
  const wrapperOwners = new Map<number, Node | null>();
  const pending: {
    node: Node;
    parent: Node;
    wrapper: Node | null;
    inHeredoc: boolean;
  }[] = [{ node: root, parent: root, wrapper: null, inHeredoc: false }];
  while (pending.length > 0) {
    const entry = pending.pop()!;
    const { node, wrapper, inHeredoc } = entry;
    if (
      node.type === "file_redirect" ||
      node.type === "heredoc_redirect" ||
      node.type === "herestring_redirect"
    )
      redirects.push({
        node,
        owner: redirectOwner(entry.parent, wrapper, wrapperOwners),
        inHeredoc,
      });
    const children = shellSyntaxChildren(node);
    for (let index = children.length - 1; index >= 0; index--)
      pending.push({
        node: children[index]!,
        parent: node,
        wrapper: node.type === "redirected_statement" ? node : wrapper,
        inHeredoc: inHeredoc || node.type === "heredoc_redirect",
      });
  }
  return redirects;
}

function isVariableDescriptor(node: Node): boolean {
  if (node.type !== "concatenation") return false;
  const words = node.namedChildren;
  if (words.length !== 3) return false;
  const open = words[0]!;
  const name = words[1]!;
  const close = words[2]!;
  if (
    open.type !== "word" ||
    name.type !== "word" ||
    close.type !== "word" ||
    open.text !== "{" ||
    close.text !== "}" ||
    !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name.text) ||
    open.endIndex !== name.startIndex ||
    name.endIndex !== close.startIndex
  )
    return false;
  return true;
}

function findAdjacentVariableDescriptor(
  root: Node,
  redirects: ReadonlySet<number>,
  source: string,
): Node | null {
  if (redirects.size === 0) return null;
  for (const node of walkNodes(root, shellSyntaxChildren)) {
    if (!isVariableDescriptor(node)) continue;
    const end = node.endIndex;
    if (hasAdjacentRedirect(redirects, source, end)) return node;
    const lineBreak = source.startsWith("\r\n", end)
      ? 2
      : source[end] === "\n"
        ? 1
        : 0;
    if (lineBreak > 0 && redirects.has(end + lineBreak)) return node;
  }
  return null;
}

function hasAdjacentRedirect(
  redirects: ReadonlySet<number>,
  source: string,
  start: number,
): boolean {
  if (redirects.has(start)) return true;
  let index = start;
  while (source[index] === "\\") {
    if (source[index + 1] === "\n") index += 2;
    else if (source.startsWith("\r\n", index + 1)) index += 3;
    else return false;
    if (redirects.has(index)) return true;
  }
  return false;
}

function isWordContinuationGap(
  source: string,
  start: number,
  end: number,
): boolean {
  let index = start;
  let pairs = 0;
  while (index < end) {
    if (source.charCodeAt(index) !== 92) return false;
    index++;
    if (source.charCodeAt(index) === 10) {
      index++;
      pairs++;
      continue;
    }
    if (
      source.charCodeAt(index) === 13 &&
      source.charCodeAt(index + 1) === 10
    ) {
      index += 2;
      pairs++;
      continue;
    }
    return false;
  }
  return pairs > 0 && index === end;
}

function nativeRedirectDescriptor(node: Node): Node | null {
  const descriptor = node.childForFieldName("descriptor");
  return descriptor === null || descriptor.isMissing ? null : descriptor;
}

function redirectOwner(
  parent: Node,
  wrapper: Node | null,
  wrapperOwners: Map<number, Node | null>,
): Node | null {
  if (parent.type === "command") return parent;
  if (wrapper === null) return null;
  const cached = wrapperOwners.get(wrapper.id);
  if (cached !== undefined) return cached;
  const body = wrapper.childForFieldName("body");
  const owner = body === null ? null : rightEdge(body);
  wrapperOwners.set(wrapper.id, owner);
  return owner;
}

type NativeFileRedirectLayout = Readonly<{
  destinationNodes: readonly Node[];
  suffixNodes: readonly Node[];
  logicalEnd: number;
}>;

function isDecimalNode(node: Node): boolean {
  if (node.type !== "number" && node.type !== "word") return false;
  if (node.startIndex === node.endIndex) return false;
  for (let index = node.startIndex; index < node.endIndex; index++) {
    const code = node.text.charCodeAt(index - node.startIndex);
    if (code < 48 || code > 57) return false;
  }
  return true;
}

function nativeFileRedirectLayout(
  node: Node,
  source: string,
): NativeFileRedirectLayout {
  const candidates = node.childrenForFieldName("destination");
  const destinationNodes: Node[] = [];
  for (const candidate of candidates) {
    const previous = destinationNodes.at(-1);
    if (
      previous === undefined ||
      candidate.startIndex === previous.endIndex ||
      isWordContinuationGap(source, previous.endIndex, candidate.startIndex)
    ) {
      destinationNodes.push(candidate);
      continue;
    }
    return {
      destinationNodes,
      suffixNodes: candidates.slice(destinationNodes.length),
      logicalEnd:
        destinationNodes.at(-1)?.endIndex ?? redirectOperator(node).endIndex,
    };
  }
  return {
    destinationNodes,
    suffixNodes: [],
    logicalEnd:
      destinationNodes.at(-1)?.endIndex ?? redirectOperator(node).endIndex,
  };
}

// Bash resolves a >& or <& operand after expansion: digits duplicate a
// descriptor, "-" closes it, a trailing "-" moves it, and any other word
// names a file only for >& on stdout (>&word, 1>&word); everywhere else
// it is an ambiguous-redirect error. Only duplication and that stdout file
// target are modeled, so only literal operands of those two shapes pass.
function isModeledDescriptorOperand(
  redirect: Node,
  operator: ">&" | "<&",
  source: string,
): boolean {
  const { destinationNodes } = nativeFileRedirectLayout(redirect, source);
  if (destinationNodes.length === 0) return false;
  let value = "";
  for (const node of destinationNodes) {
    const word = decodeRedirectWordNode(node, source);
    if (word.kind !== "literal") return false;
    value += word.value;
  }
  if (/^[0-9]+$/.test(value)) return true;
  if (operator === "<&" || value.endsWith("-")) return false;
  const descriptor = nativeRedirectDescriptor(redirect)?.text ?? null;
  return descriptor === null || descriptor === "1";
}

function unsupportedRedirectFailure(
  source: string,
  root: Node,
  redirects: readonly NativeRedirect[],
): Extract<ParseResult, { ok: false }> | null {
  const unnumberedStarts = new Set<number>();
  const variableDescriptorStarts = new Set<number>();
  const ownerWords = new Map<
    number,
    { name: Node; lastArgument: Node | undefined }
  >();
  for (const { node: redirect, owner } of redirects) {
    const operatorNode = redirectOperator(redirect);
    const operator = operatorNode.type;
    if (operator === ">&-" || operator === "<&-")
      return {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
        span: nodeSpan(operatorNode),
      };
    if (
      (operator === ">&" || operator === "<&") &&
      !isModeledDescriptorOperand(redirect, operator, source)
    )
      return {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
        span: nodeSpan(redirect),
      };
    if (operator !== "&>" && operator !== "&>>")
      variableDescriptorStarts.add(redirect.startIndex);
    if (nativeRedirectDescriptor(redirect) !== null) continue;
    unnumberedStarts.add(redirect.startIndex);
    if (owner === null) continue;
    let words = ownerWords.get(owner.id);
    if (words === undefined) {
      words = {
        name: commandNameNode(owner),
        lastArgument: owner.childrenForFieldName("argument").at(-1),
      };
      ownerWords.set(owner.id, words);
    }
    const { name, lastArgument: argument } = words;
    const isAdjacent = (candidate: Node): boolean =>
      candidate.endIndex === redirect.startIndex ||
      isWordContinuationGap(source, candidate.endIndex, redirect.startIndex);
    const adjacent =
      isAdjacent(name) && isDecimalNode(name)
        ? name
        : argument !== undefined &&
            isAdjacent(argument) &&
            isDecimalNode(argument)
          ? argument
          : null;
    if (adjacent !== null) {
      return {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
        span: nodeSpan(adjacent),
      };
    }
  }
  const preceding = redirects
    .map(({ node }) => node)
    .filter((redirect) => redirect.type === "file_redirect")
    .flatMap((redirect) => {
      const layout = nativeFileRedirectLayout(redirect, source);
      return [...layout.destinationNodes, ...layout.suffixNodes];
    })
    .find(
      (candidate) =>
        isDecimalNode(candidate) &&
        hasAdjacentRedirect(unnumberedStarts, source, candidate.endIndex),
    );
  if (preceding !== undefined)
    return {
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
      span: nodeSpan(preceding),
    };
  const descriptor = findAdjacentVariableDescriptor(
    root,
    variableDescriptorStarts,
    source,
  );
  if (descriptor !== null)
    return {
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
      span: nodeSpan(descriptor),
    };
  return null;
}

type RedirectTemp =
  | {
      nativeId: number;
      ownerNativeId: number | null;
      kind: "file";
      span: ParsedShellSpan;
      operator: ParsedShellFileRedirectOperator;
      operatorSpan: ParsedShellSpan;
      descriptor: ParsedShellRedirectDescriptor | null;
      destination: ParsedShellWord | null;
    }
  | {
      nativeId: number;
      ownerNativeId: number | null;
      kind: "herestring";
      span: ParsedShellSpan;
      operatorSpan: ParsedShellSpan;
      descriptor: ParsedShellRedirectDescriptor | null;
      value: ParsedShellWord;
    }
  | {
      nativeId: number;
      ownerNativeId: number | null;
      kind: "heredoc";
      span: ParsedShellSpan;
      operatorSpan: ParsedShellSpan;
      descriptor: ParsedShellRedirectDescriptor | null;
      headerSpan: ParsedShellSpan;
      headerLineBreakSpan: ParsedShellSpan;
      delimiter: Readonly<{
        value: string;
        rawSpan: ParsedShellSpan;
        quoted: boolean;
      }>;
      rawBodySpan: ParsedShellSpan;
      contentSpan: ParsedShellSpan;
      terminatorSpan: ParsedShellSpan;
      header: Readonly<{
        arguments: readonly ParsedShellArgument[];
        continuation: ParsedShellHeredocContinuation | null;
      }>;
      nestedNativeIds: readonly number[];
    };

type CommandTemp = {
  node: Node;
  id: number;
  name: ParsedShellWord;
  assignments: readonly ParsedShellAssignment[];
  arguments: ParsedShellArgument[];
  directNativeRedirectIds: number[];
  span: ParsedShellSpan;
};

type NormalizationState = {
  source: string;
  commandIds: Map<number, number>;
  commands: CommandTemp[];
  commandByNativeId: Map<number, CommandTemp>;
  redirects: RedirectTemp[];
  redirectByNativeId: Map<number, RedirectTemp>;
  diagnostics: ParsedShellDiagnostic[];
  suppressedSpans: ParsedShellSpan[];
};

function normalizedCommandSpan(
  command: CommandTemp,
  state: NormalizationState,
): ParsedShellSpan {
  const spans = [
    command.name.rawSpan,
    ...command.assignments.map((assignment) => assignment.span),
    ...command.arguments.map((argument) => argument.word.rawSpan),
    ...command.directNativeRedirectIds.map((nativeId) => {
      const redirect = state.redirectByNativeId.get(nativeId);
      if (redirect === undefined)
        throw new Error("command redirect span invariant");
      return redirect.span;
    }),
  ].filter((span) => span.end > span.start);
  if (spans.length === 0) return command.name.rawSpan;
  return sourceSpan(
    state.source,
    Math.min(...spans.map((span) => span.start)),
    Math.max(...spans.map((span) => span.end)),
  );
}

class TypedNormalizationFailure extends Error {
  readonly result: ParseResult;

  constructor(result: ParseResult) {
    super("typed shell normalization failure");
    this.result = result;
  }
}

function throwInvalid(
  issue:
    | "incomplete"
    | "multiple"
    | "indented"
    | "unsupported_delimiter"
    | "missing_owner",
  span: ParsedShellSpan,
): never {
  throw new TypedNormalizationFailure({
    ok: false,
    reason: "invalid_heredoc",
    issue,
    span,
  });
}

function compoundParts(node: Node): {
  children: Node[];
  operators: ParsedShellOperator[];
} {
  const children: Node[] = [];
  const operators: ParsedShellOperator[] = [];
  let current = node;
  // Bash gives && and || equal precedence and groups them left to right.
  // Keep their lexical order without retaining the grammar's left spine.
  for (;;) {
    const operands = commandUnitChildren(current);
    const left = operands[0];
    const descend = current.type === "list" && left?.type === "list";
    for (let index = operands.length - 1; index >= (descend ? 1 : 0); index--)
      children.push(operands[index]!);
    const tokens = current.children;
    for (let index = tokens.length - 1; index >= 0; index--) {
      const operator = operatorFromNode(tokens[index]!);
      if (operator !== null) operators.push(operator);
    }
    if (!descend) break;
    current = left;
  }
  return { children: children.reverse(), operators: operators.reverse() };
}

function headerUnit(
  node: Node,
  state: NormalizationState,
): ParsedShellHeaderUnit {
  const span = nodeSpan(node);
  if (node.type === "command") {
    const command = state.commandByNativeId.get(node.id);
    if (command !== undefined) {
      return {
        kind: "command",
        span: command.span,
        name: command.name,
        arguments: command.arguments,
      };
    }
    const commandNameNode = node.childForFieldName("name");
    if (commandNameNode === null) throw new Error("command header has no name");
    const wordNode = commandNameNode.namedChildren[0] ?? commandNameNode;
    const args = node.childrenForFieldName("argument").map((child) => ({
      word: decodeWordNode(child, state.source),
      synthetic: false,
    }));
    return {
      kind: "command",
      span,
      name: decodeWordNode(wordNode, state.source),
      arguments: args,
    };
  }
  if (node.type === "list" || node.type === "pipeline") {
    const { children, operators } = compoundParts(node);
    return {
      kind: node.type,
      span,
      children: children.map((child) => headerUnit(child, state)),
      operators,
    };
  }
  return { kind: "opaque", span, nodeType: node.type };
}

function redirectOperator(node: Node): Node {
  const operator = node.children.find((child) => !child.isNamed);
  if (operator === undefined) throw new Error("redirect has no operator");
  return operator;
}

function addHeaderPipeStderrDiagnostics(
  node: Node,
  state: NormalizationState,
  publish: boolean,
): void {
  if (!publish) return;
  for (const child of walkNodes(node, (unit) =>
    unit.type === "list" ||
    unit.type === "pipeline" ||
    unit.type === "redirected_statement"
      ? unit.children
      : [],
  )) {
    const operator = operatorFromNode(child);
    if (operator?.kind === "pipe_stderr")
      state.diagnostics.push({
        kind: "unsupported_heredoc_header",
        span: operator.span,
        issue: "pipe_stderr",
      });
  }
}

function adjacentLiteralWords(
  words: readonly LiteralWord[],
  source: string,
  rawSpan: ParsedShellSpan,
): LiteralWord {
  const composed = composeLiteralWords(words, source, rawSpan);
  if (composed.kind !== "literal")
    throw new Error("redirect destination composition invariant");
  return composed;
}

function canonicalDecimal(value: string): string {
  if (!/^\d+$/.test(value)) throw new Error("decimal descriptor invariant");
  return value.replace(/^0+(?=\d)/, "");
}

function redirectDescriptor(
  node: Node,
  state: NormalizationState,
): { descriptor: ParsedShellRedirectDescriptor | null; start: number } {
  const native = nativeRedirectDescriptor(node);
  if (native === null) return { descriptor: null, start: node.startIndex };
  const rawSpan = nodeSpan(native);
  return {
    descriptor: {
      kind: "number",
      value: canonicalDecimal(state.source.slice(rawSpan.start, rawSpan.end)),
      rawSpan,
    },
    start: node.startIndex,
  };
}

function ensureRedirect(
  node: Node,
  ownerNativeId: number | null,
  headerStart: number,
  state: NormalizationState,
  publish = true,
): number {
  const existing = state.redirectByNativeId.get(node.id);
  if (existing !== undefined) return existing.nativeId;
  if (node.type === "file_redirect") {
    const operatorNode = redirectOperator(node);
    const operator = operatorNode.type;
    const supported: readonly ParsedShellFileRedirectOperator[] = [
      "<",
      ">",
      ">>",
      "&>",
      "&>>",
      "<&",
      ">&",
      ">|",
    ];
    if (!(supported as readonly string[]).includes(operator))
      throw new Error(`unsupported file redirect operator: ${operator}`);
    const layout = nativeFileRedirectLayout(node, state.source);
    const destinations = layout.destinationNodes;
    let destination: ParsedShellWord;
    if (destinations.length > 0) {
      const decoded = destinations.map((child) =>
        decodeRedirectWordNode(child, state.source),
      );
      const firstDestinationSpan = nodeSpan(destinations[0]!);
      const lastDestinationSpan = nodeSpan(
        destinations[destinations.length - 1]!,
      );
      if (decoded.length === 1) destination = decoded[0]!;
      else if (
        destinations.every(
          (child, index) =>
            index === 0 ||
            child.startIndex === destinations[index - 1]!.endIndex ||
            isWordContinuationGap(
              state.source,
              destinations[index - 1]!.endIndex,
              child.startIndex,
            ),
        )
      ) {
        if (decoded.some((word) => word.kind !== "literal")) {
          destination = nonliteralWord(
            "concatenation",
            sourceSpan(
              state.source,
              firstDestinationSpan.start,
              lastDestinationSpan.end,
            ),
            "unsupported_node",
            ["destination"],
          );
        } else {
          destination = adjacentLiteralWords(
            decoded as LiteralWord[],
            state.source,
            sourceSpan(
              state.source,
              firstDestinationSpan.start,
              lastDestinationSpan.end,
            ),
          );
        }
      } else {
        destination = nonliteralWord(
          "concatenation",
          sourceSpan(
            state.source,
            firstDestinationSpan.start,
            lastDestinationSpan.end,
          ),
          "unsupported_node",
          ["destination"],
        );
      }
    } else {
      throw new Error("file redirect has no destination");
    }
    const descriptor = redirectDescriptor(node, state);
    const logicalEnd = layout.logicalEnd;
    const temp: RedirectTemp = {
      nativeId: node.id,
      ownerNativeId,
      kind: "file",
      span: sourceSpan(state.source, descriptor.start, logicalEnd),
      operator: operator as ParsedShellFileRedirectOperator,
      operatorSpan: nodeSpan(operatorNode),
      descriptor: descriptor.descriptor,
      destination,
    };
    if (publish) {
      state.redirectByNativeId.set(node.id, temp);
      state.redirects.push(temp);
    }
    return node.id;
  }

  if (node.type === "herestring_redirect") {
    const operatorNode = redirectOperator(node);
    if (operatorNode.type !== "<<<")
      throw new Error("herestring has no <<< operator");
    const descriptor = redirectDescriptor(node, state);
    const valueNode = node.namedChildren.find(
      (child) => child.type !== "file_descriptor",
    );
    if (valueNode === undefined) throw new Error("herestring has no value");
    const temp: RedirectTemp = {
      nativeId: node.id,
      ownerNativeId,
      kind: "herestring",
      span: sourceSpan(state.source, descriptor.start, node.endIndex),
      operatorSpan: nodeSpan(operatorNode),
      descriptor: descriptor.descriptor,
      value: decodeWordNode(valueNode, state.source),
    };
    if (publish) {
      state.redirectByNativeId.set(node.id, temp);
      state.redirects.push(temp);
    }
    return node.id;
  }

  if (node.type !== "heredoc_redirect")
    throw new Error(`unexpected redirect: ${node.type}`);
  const operatorNode = redirectOperator(node);
  const descriptor = redirectDescriptor(node, state);
  const redirectSpan = sourceSpan(
    state.source,
    descriptor.start,
    node.endIndex,
  );
  if (operatorNode.type === "<<-")
    throwInvalid("indented", nodeSpan(operatorNode));
  if (operatorNode.type !== "<<") throw new Error("heredoc has no << operator");
  const startNode = node.namedChildren.find(
    (child) => child.type === "heredoc_start",
  );
  const bodyNode = node.namedChildren.find(
    (child) => child.type === "heredoc_body",
  );
  const endNode = node.namedChildren.find(
    (child) => child.type === "heredoc_end",
  );
  if (
    startNode === undefined ||
    bodyNode === undefined ||
    endNode === undefined
  )
    throwInvalid("incomplete", redirectSpan);
  const startSpan = nodeSpan(startNode);
  const delimiterRaw = state.source.slice(startSpan.start, startSpan.end);
  const unquoted = /^[A-Za-z_][A-Za-z0-9_]*$/.test(delimiterRaw);
  const singleQuoted = /^'[A-Za-z_][A-Za-z0-9_]*'$/.test(delimiterRaw);
  const doubleQuoted = /^"[A-Za-z_][A-Za-z0-9_]*"$/.test(delimiterRaw);
  if (!unquoted && !singleQuoted && !doubleQuoted)
    throwInvalid("unsupported_delimiter", nodeSpan(startNode));
  const quoted = singleQuoted || doubleQuoted;
  const delimiterValue = delimiterRaw.slice(
    quoted ? 1 : 0,
    quoted ? -1 : undefined,
  );
  const terminatorSpan = nodeSpan(endNode);
  if (
    state.source.slice(terminatorSpan.start, terminatorSpan.end) !==
      delimiterValue ||
    state.source[terminatorSpan.start - 1] !== "\n" ||
    (terminatorSpan.end !== state.source.length &&
      state.source[terminatorSpan.end] !== "\n" &&
      !state.source.startsWith("\r\n", terminatorSpan.end))
  )
    throwInvalid("incomplete", redirectSpan);
  const rawBodySpan = nodeSpan(bodyNode);
  const bodyText = state.source.slice(rawBodySpan.start, rawBodySpan.end);
  const contentEnd = bodyText.endsWith("\r\n")
    ? rawBodySpan.end - 2
    : bodyText.endsWith("\n")
      ? rawBodySpan.end - 1
      : rawBodySpan.end;
  const lineBreakStart =
    rawBodySpan.start - (state.source[rawBodySpan.start - 2] === "\r" ? 2 : 1);
  const lineBreakText = state.source.slice(lineBreakStart, rawBodySpan.start);
  if (lineBreakText !== "\n" && lineBreakText !== "\r\n")
    throwInvalid("incomplete", redirectSpan);
  const args = node.childrenForFieldName("argument").map((child) => ({
    word: decodeWordNode(child, state.source),
    synthetic: false,
  }));
  const pipelineNode = node.children.find(
    (child) =>
      child.type === "pipeline" && child.startIndex >= startNode.endIndex,
  );
  const rightNode = node.childForFieldName("right");
  const operatorField = node.childForFieldName("operator");
  let continuation: ParsedShellHeredocContinuation | null = null;
  if (pipelineNode !== undefined) {
    continuation = { kind: "pipeline", unit: headerUnit(pipelineNode, state) };
    addHeaderPipeStderrDiagnostics(pipelineNode, state, publish);
  } else if (rightNode !== null && operatorField !== null) {
    const operator = operatorFromNode(operatorField);
    if (operator === null) throw new Error("heredoc right has no operator");
    continuation = {
      kind: "right",
      operator,
      unit: headerUnit(rightNode, state),
    };
    if (publish)
      state.diagnostics.push({
        kind: "unsupported_heredoc_header",
        span: nodeSpan(rightNode),
        issue: "right",
      });
    addHeaderPipeStderrDiagnostics(rightNode, state, publish);
  }
  const nestedRedirectNodes = node.childrenForFieldName("redirect");
  const nestedTrailing = nestedRedirectNodes.flatMap((child) =>
    nativeFileRedirectLayout(child, state.source).suffixNodes.map(
      (trailing) => ({
        word: decodeWordNode(trailing, state.source),
        synthetic: false,
      }),
    ),
  );
  const headerArguments = [...args, ...nestedTrailing].sort(
    (a, b) => a.word.rawSpan.start - b.word.rawSpan.start,
  );
  if (publish && headerArguments.length > 0) {
    state.diagnostics.push({
      kind: "unsupported_heredoc_header",
      span: sourceSpan(
        state.source,
        headerArguments[0]!.word.rawSpan.start,
        headerArguments[headerArguments.length - 1]!.word.rawSpan.end,
      ),
      issue: "arguments",
    });
  }
  const nestedNativeIds = nestedRedirectNodes.map((child) =>
    ensureRedirect(child, ownerNativeId, headerStart, state, publish),
  );
  const temp: RedirectTemp = {
    nativeId: node.id,
    ownerNativeId,
    kind: "heredoc",
    span: redirectSpan,
    operatorSpan: nodeSpan(operatorNode),
    descriptor: descriptor.descriptor,
    headerSpan: sourceSpan(state.source, headerStart, lineBreakStart),
    headerLineBreakSpan: sourceSpan(
      state.source,
      lineBreakStart,
      rawBodySpan.start,
    ),
    delimiter: {
      value: delimiterValue,
      rawSpan: startSpan,
      quoted,
    },
    rawBodySpan,
    contentSpan: sourceSpan(state.source, rawBodySpan.start, contentEnd),
    terminatorSpan,
    header: { arguments: headerArguments, continuation },
    nestedNativeIds,
  };
  if (publish) {
    state.redirectByNativeId.set(node.id, temp);
    state.redirects.push(temp);
  }
  return node.id;
}

function normalizeAssignment(
  node: Node,
  state: NormalizationState,
): ParsedShellAssignment {
  const nameNode = node.childForFieldName("name");
  if (nameNode === null) throw new Error("assignment has no name");
  const nameSpan = nodeSpan(nameNode);
  const valueNode = node.childForFieldName("value");
  return {
    span: nodeSpan(node),
    name: state.source.slice(nameSpan.start, nameSpan.end),
    nameSpan,
    value: valueNode === null ? null : decodeWordNode(valueNode, state.source),
  };
}

function normalizeCommand(
  node: Node,
  state: NormalizationState,
): ParsedShellUnit {
  const command = state.commandByNativeId.get(node.id);
  if (command === undefined) throw new Error("command was not collected");
  const commandSpan = nodeSpan(node);
  const directRedirects = node
    .childrenForFieldName("redirect")
    .map((child) => ensureRedirect(child, node.id, commandSpan.start, state));
  command.directNativeRedirectIds.push(...directRedirects);
  command.span = normalizedCommandSpan(command, state);
  return { kind: "command", span: commandSpan, commandId: command.id };
}

function normalizeUnit(root: Node, state: NormalizationState): ParsedShellUnit {
  const unitFor = (node: Node) => ({
    node,
    compound:
      node.type === "list" || node.type === "pipeline"
        ? compoundParts(node)
        : undefined,
  });
  return reduceTree<ReturnType<typeof unitFor>, ParsedShellUnit>(
    unitFor(root),
    ({ node, compound }) =>
      (compound?.children ?? commandUnitChildren(node)).map(unitFor),
    ({ node, compound }, children) =>
      normalizeUnitFromChildren(node, children, compound, state),
  );
}

function normalizeUnitFromChildren(
  node: Node,
  children: ParsedShellUnit[],
  compound: ReturnType<typeof compoundParts> | undefined,
  state: NormalizationState,
): ParsedShellUnit {
  if (node.type === "program") {
    const boundaries: ParsedShellBoundary[] = node.children
      .map((child) => boundaryFromNode(child))
      .filter((boundary): boundary is ParsedShellBoundary => boundary !== null);
    let precedingIndex = -1;
    for (const boundary of boundaries) {
      if (boundary.kind === "background" || boundary.kind === "case") {
        state.diagnostics.push({
          kind: "unsupported_control",
          span: boundary.span,
          operator: boundary.kind === "background" ? "&" : ";;",
        });
        while (
          precedingIndex + 1 < children.length &&
          children[precedingIndex + 1]!.span.end <= boundary.span.start
        )
          precedingIndex++;
        const affected = children[precedingIndex];
        if (affected !== undefined) state.suppressedSpans.push(affected.span);
      }
    }
    for (let i = 0; i + 1 < children.length; i++) {
      const previous = children[i]!.span.end;
      const next = children[i + 1]!.span.start;
      const gap = state.source.slice(previous, next);
      const newline = gap.match(/\r?\n/);
      if (newline !== null) {
        const start = previous + newline.index!;
        boundaries.push({
          kind: "newline",
          text: newline[0] as "\n" | "\r\n",
          span: sourceSpan(state.source, start, start + newline[0].length),
        });
      }
    }
    boundaries.sort(
      (a, b) => a.span.start - b.span.start || a.span.end - b.span.end,
    );
    return {
      kind: "program",
      span: nodeSpan(node),
      children,
      boundaries,
    };
  }
  if (node.type === "list" || node.type === "pipeline") {
    if (compound === undefined) throw new Error("compound parts invariant");
    const { operators } = compound;
    let suppressThrough = -1;
    for (const [index, operator] of operators.entries()) {
      if (operator.kind === "or" || operator.kind === "pipe_stderr") {
        state.diagnostics.push({
          kind: "unsupported_control",
          span: operator.span,
          operator: operator.text as "||" | "|&",
        });
        suppressThrough =
          node.type === "list" ? index + 1 : children.length - 1;
      }
    }
    if (suppressThrough >= 0)
      state.suppressedSpans.push({
        start: node.startIndex,
        end: children[suppressThrough]!.span.end,
      });
    return { kind: node.type, span: nodeSpan(node), children, operators };
  }
  if (node.type === "redirected_statement") {
    const redirectedSpan = nodeSpan(node);
    const bodyUnit = children[0];
    if (bodyUnit === undefined) {
      state.diagnostics.push({
        kind: "unsupported_construct",
        span: redirectedSpan,
        nodeType: node.type,
      });
      return {
        kind: "opaque",
        span: redirectedSpan,
        nodeType: node.type,
        reason: "unsupported_construct",
      };
    }
    const ownerId = parsedRightEdgeCommandId(bodyUnit);
    if (ownerId === null)
      return {
        kind: "redirected_statement",
        span: redirectedSpan,
        body: bodyUnit,
        redirectIds: [],
      };
    const redirectIds = node
      .childrenForFieldName("redirect")
      .map((child) =>
        ensureRedirect(
          child,
          state.commands[ownerId]!.node.id,
          redirectedSpan.start,
          state,
        ),
      );
    return {
      kind: "redirected_statement",
      span: redirectedSpan,
      body: bodyUnit,
      redirectIds,
    };
  }
  if (node.type === "command") return normalizeCommand(node, state);
  const reason = isControlNode(node.type)
    ? "control_body"
    : "unsupported_construct";
  state.diagnostics.push({
    kind: "unsupported_construct",
    span: nodeSpan(node),
    nodeType: node.type,
  });
  return { kind: "opaque", span: nodeSpan(node), nodeType: node.type, reason };
}

function commandNameNode(node: Node): Node {
  const commandName = node.childForFieldName("name");
  if (commandName === null) throw new Error("command has no name");
  return commandName.namedChildren[0] ?? commandName;
}

function basename(value: string): string {
  const parts = value.split("/");
  return parts[parts.length - 1] ?? value;
}

type ResolvedInterpreter = Readonly<{
  prefix: ParsedShellInvocationPrefix;
  interpreter: ParsedShellInterpreter;
  interpreterIndex: number | null;
  effectiveArguments: readonly ParsedShellArgument[];
}>;

function unsupportedEnv(
  state: NormalizationState,
  issue:
    | "option"
    | "dynamic_assignment"
    | "missing_interpreter"
    | "unknown_interpreter",
  span: ParsedShellSpan,
): null {
  state.diagnostics.push({ kind: "unsupported_env", span, issue });
  return null;
}

function resolveInterpreter(
  command: CommandTemp,
  state: NormalizationState,
): ResolvedInterpreter | null {
  if (command.name.kind !== "literal") return null;
  const commandBasename = basename(command.name.value);
  if (commandBasename !== "env") {
    const info = INTERPRETERS[commandBasename];
    if (info === undefined) return null;
    return {
      prefix: { kind: "direct" },
      interpreter: {
        location: { kind: "command_name" },
        basename: commandBasename,
        language: info.language,
      },
      interpreterIndex: null,
      effectiveArguments: command.arguments,
    };
  }

  const assignments: ParsedShellEnvironmentAssignment[] = [];
  let index = 0;
  while (index < command.arguments.length) {
    const argument = command.arguments[index]!;
    if (argument.word.kind !== "literal") {
      const raw = state.source.slice(
        argument.word.rawSpan.start,
        argument.word.rawSpan.end,
      );
      if (/^(?:['"])?[A-Za-z_][A-Za-z0-9_]*=.*$/.test(raw))
        return unsupportedEnv(
          state,
          "dynamic_assignment",
          argument.word.rawSpan,
        );
      break;
    }
    const assignmentName = argument.word.value.match(
      /^([A-Za-z_][A-Za-z0-9_]*)=.*$/,
    )?.[1];
    if (assignmentName === undefined) break;
    assignments.push({
      argumentIndex: index,
      name: assignmentName,
      value: argument.word.value.slice(assignmentName.length + 1),
    });
    index++;
  }
  if (index === 0) {
    const first = command.arguments[0];
    if (
      first !== undefined &&
      first.word.kind === "literal" &&
      first.word.value.startsWith("-")
    ) {
      return unsupportedEnv(state, "option", first.word.rawSpan);
    }
    return unsupportedEnv(state, "missing_interpreter", nodeSpan(command.node));
  }
  const interpreterArgument = command.arguments[index];
  if (interpreterArgument === undefined)
    return unsupportedEnv(state, "missing_interpreter", nodeSpan(command.node));
  if (interpreterArgument.word.kind !== "literal")
    return unsupportedEnv(
      state,
      "dynamic_assignment",
      interpreterArgument.word.rawSpan,
    );
  if (interpreterArgument.word.value.startsWith("-"))
    return unsupportedEnv(state, "option", interpreterArgument.word.rawSpan);
  const interpreterBasename = basename(interpreterArgument.word.value);
  const info = INTERPRETERS[interpreterBasename];
  if (info === undefined)
    return unsupportedEnv(
      state,
      "unknown_interpreter",
      interpreterArgument.word.rawSpan,
    );
  return {
    prefix: { kind: "env", assignments },
    interpreter: {
      location: { kind: "argument", index },
      basename: interpreterBasename,
      language: info.language,
    },
    interpreterIndex: index,
    effectiveArguments: command.arguments.slice(index + 1),
  };
}

function addSyntheticDash(
  command: CommandTemp,
  resolved: ResolvedInterpreter,
  heredoc: RedirectTemp,
  state: NormalizationState,
): void {
  if (heredoc.kind !== "heredoc") return;
  if (resolved.prefix.kind === "env" && resolved.interpreterIndex === null)
    throw new Error("env interpreter has no argument index");
  const effective = resolved.effectiveArguments;
  const parsedEnd =
    effective.length > 0
      ? effective[effective.length - 1]!.word.rawSpan.end
      : resolved.interpreterIndex === null
        ? command.name.rawSpan.end
        : command.arguments[resolved.interpreterIndex]!.word.rawSpan.end;
  const gap = state.source.slice(parsedEnd, heredoc.span.start);
  if (!/^\s+-\s*$/.test(gap)) return;
  const dashOffset = gap.indexOf("-");
  if (dashOffset < 0) throw new Error("dash recovery invariant");
  const start = parsedEnd + dashOffset;
  command.arguments.push({
    word: literalWord(
      "synthetic",
      sourceSpan(state.source, start, start + 1),
      "-",
      sourceSpan(state.source, start, start + 1),
      [
        { child: 0, parent: 0 },
        { child: 1, parent: 1 },
      ],
    ),
    synthetic: true,
  });
}

function redirectRecords(state: NormalizationState): {
  redirects: readonly ParsedShellRedirect[];
  idByNativeId: Map<number, number>;
} {
  const sorted = [...state.redirects].sort(
    (a, b) => a.span.start - b.span.start || a.span.end - b.span.end,
  );
  const idByNativeId = new Map<number, number>();
  sorted.forEach((redirect, id) => idByNativeId.set(redirect.nativeId, id));
  const redirects = sorted.map((redirect) => {
    const id = idByNativeId.get(redirect.nativeId);
    if (id === undefined) throw new Error("redirect id invariant");
    const ownerId =
      redirect.ownerNativeId === null
        ? null
        : state.commandIds.get(redirect.ownerNativeId);
    if (ownerId === undefined || ownerId === null) {
      if (redirect.kind === "heredoc")
        throwInvalid("missing_owner", redirect.span);
      throw new Error("non-heredoc redirect owner invariant");
    }
    if (redirect.kind === "file")
      return {
        kind: "file" as const,
        id,
        ownerId,
        span: redirect.span,
        operator: redirect.operator,
        operatorSpan: redirect.operatorSpan,
        descriptor: redirect.descriptor,
        destination: redirect.destination,
      };
    if (redirect.kind === "herestring")
      return {
        kind: "herestring" as const,
        id,
        ownerId,
        span: redirect.span,
        operator: "<<<" as const,
        operatorSpan: redirect.operatorSpan,
        descriptor: redirect.descriptor,
        value: redirect.value,
      };
    return {
      kind: "heredoc" as const,
      id,
      ownerId,
      span: redirect.span,
      descriptor: redirect.descriptor,
      operator: "<<" as const,
      operatorSpan: redirect.operatorSpan,
      headerSpan: redirect.headerSpan,
      headerLineBreakSpan: redirect.headerLineBreakSpan,
      delimiter: redirect.delimiter,
      rawBodySpan: redirect.rawBodySpan,
      contentSpan: redirect.contentSpan,
      terminatorSpan: redirect.terminatorSpan,
      header: redirect.header,
      nestedRedirectIds: redirect.nestedNativeIds.map((nativeId) => {
        const nestedId = idByNativeId.get(nativeId);
        if (nestedId === undefined)
          throw new Error("nested redirect id invariant");
        return nestedId;
      }),
    };
  });
  return { redirects, idByNativeId };
}

function redirectAffectsStdin(redirect: ParsedShellRedirect): boolean {
  const descriptor = redirect.descriptor;
  if (descriptor?.kind === "number") return descriptor.value === "0";
  if (redirect.kind === "heredoc" || redirect.kind === "herestring")
    return true;
  return redirect.operator === "<" || redirect.operator === "<&";
}

function invocationPayload(word: LiteralWord): ParsedShellPayload {
  return {
    text: word.value,
    rawSpan: word.rawSpan,
    contentSpan: word.projection.span,
    projection: word.projection,
    quoteKind: word.quoteKind,
  };
}

function plainBodyPayload(
  redirect: ParsedShellHeredocRedirect,
  source: string,
): ParsedShellPayload {
  const text = source.slice(
    redirect.contentSpan.start,
    redirect.contentSpan.end,
  );
  const points: SourceProjectionPoint[] = [{ child: 0, parent: 0 }];
  for (let i = 0; i < text.length; i++)
    points.push({ child: i + 1, parent: i + 1 });
  return {
    text,
    rawSpan: redirect.rawBodySpan,
    contentSpan: redirect.contentSpan,
    projection: projection(
      redirect.contentSpan,
      simplifyProjectionPoints(points),
      text.length,
    ),
    quoteKind: null,
  };
}

const PARSED_SHELL_DOCUMENT_INVARIANT = "parsed shell document invariant:";

type ParsedUnitProvenance = {
  commandUnitIds: number[];
  commandUnits: Map<number, Extract<ParsedShellUnit, { kind: "command" }>>;
  opaqueUnits: Array<Extract<ParsedShellUnit, { kind: "opaque" }>>;
  nestedRedirectIds: Set<number>;
  redirectedUnits: Map<
    number,
    Extract<ParsedShellUnit, { kind: "redirected_statement" }>
  >;
  wrapperRedirectIds: Set<number>;
};

type ParsedUnitStarts = {
  command: Map<number, number>;
  redirected: Map<number, number>;
};

export function assertValidParsedShellDocument(
  document: ParsedShellDocument,
): void {
  assertParsedShellDocument(document, new Set());
}

function parsedShellDocumentInvariant(field: string): never {
  throw new Error(PARSED_SHELL_DOCUMENT_INVARIANT + " " + field);
}

function isParsedArray(value: unknown): boolean {
  return Array.isArray(value);
}

function assertParsedShellDocument(
  document: ParsedShellDocument,
  ancestors: ReadonlySet<ParsedShellDocument>,
): void {
  if (ancestors.has(document))
    parsedShellDocumentInvariant("shell document child cycle");
  if (typeof document.source !== "string")
    parsedShellDocumentInvariant("shell document source");
  if ((document.program as ParsedShellUnit).kind !== "program")
    parsedShellDocumentInvariant("program root");
  const nextAncestors = new Set(ancestors);
  nextAncestors.add(document);

  assertParsedSpan(document.source, document.program.span, "program span");
  assertParsedCommands(document);
  assertParsedRedirects(document);
  assertParsedRedirectMembership(document);
  const unitProvenance: ParsedUnitProvenance = {
    commandUnitIds: [],
    commandUnits: new Map(),
    opaqueUnits: [],
    nestedRedirectIds: new Set(
      document.redirects.flatMap((redirect) =>
        redirect.kind === "heredoc" ? redirect.nestedRedirectIds : [],
      ),
    ),
    redirectedUnits: new Map(),
    wrapperRedirectIds: new Set(),
  };
  assertParsedUnit(document, document.program, "program", unitProvenance);
  assertParsedCommandUnitReferences(document, unitProvenance.commandUnitIds);
  const unitStarts: ParsedUnitStarts = {
    command: new Map(),
    redirected: new Map(),
  };
  assertParsedUnitStarts(
    document,
    document.program,
    unitProvenance,
    unitStarts,
  );
  assertParsedHeredocHeaderAnchors(
    document,
    parsedRedirectUnitEnvelopes(document, unitStarts),
  );
  assertParsedInvocations(document);
  assertParsedDiagnostics(document);
  assertParsedOpaqueDiagnosticProvenance(document, unitProvenance.opaqueUnits);
  assertParsedChildRelationships(document, nextAncestors);
}

function assertParsedSpan(
  source: string,
  span: ParsedShellSpan,
  field: string,
): void {
  if (
    !Number.isInteger(span.start) ||
    !Number.isInteger(span.end) ||
    span.start < 0 ||
    span.end < span.start ||
    span.end > source.length
  )
    parsedShellDocumentInvariant(field);
}

function assertParsedContains(
  outer: ParsedShellSpan,
  inner: ParsedShellSpan,
  field: string,
): void {
  if (inner.start < outer.start || inner.end > outer.end)
    parsedShellDocumentInvariant(field);
}

function sameParsedSpan(
  left: ParsedShellSpan,
  right: ParsedShellSpan,
): boolean {
  return left.start === right.start && left.end === right.end;
}

function assertParsedSourceText(
  source: string,
  span: ParsedShellSpan,
  text: string,
  field: string,
): void {
  assertParsedSpan(source, span, field);
  if (source.slice(span.start, span.end) !== text)
    parsedShellDocumentInvariant(field);
}

function assertParsedProjection(
  source: string,
  value: ParsedShellProjection,
  childLength: number,
  field: string,
): void {
  assertParsedSpan(source, value.span, field + " span");
  if (!Number.isInteger(childLength) || childLength < 0)
    parsedShellDocumentInvariant(field + " child length");
  if (!isParsedArray(value.points) || value.points.length === 0)
    parsedShellDocumentInvariant(field + " points");
  const first = value.points[0]!;
  if (
    !Number.isInteger(first.child) ||
    !Number.isInteger(first.parent) ||
    first.child !== 0 ||
    first.parent !== 0
  )
    parsedShellDocumentInvariant(field + " origin");
  for (let index = 1; index < value.points.length; index++) {
    const previous = value.points[index - 1]!;
    const point = value.points[index]!;
    if (
      !Number.isInteger(point.child) ||
      !Number.isInteger(point.parent) ||
      point.child < 0 ||
      point.parent < 0 ||
      point.child <= previous.child ||
      point.parent <= previous.parent
    )
      parsedShellDocumentInvariant(field + " points");
  }
  const last = value.points[value.points.length - 1]!;
  if (
    last.child !== childLength ||
    last.parent !== value.span.end - value.span.start
  )
    parsedShellDocumentInvariant(field + " terminal");
  assertProjection(value, childLength);
}

function sameParsedProjection(
  left: ParsedShellProjection,
  right: ParsedShellProjection,
): boolean {
  return (
    sameParsedSpan(left.span, right.span) &&
    left.points.length === right.points.length &&
    left.points.every(
      (point, index) =>
        point.child === right.points[index]!.child &&
        point.parent === right.points[index]!.parent,
    )
  );
}

function literalParsedWord(word: ParsedShellWord, field: string): LiteralWord {
  if (word.kind !== "literal") parsedShellDocumentInvariant(field + " literal");
  if (!Object.prototype.hasOwnProperty.call(word, "quoteKind"))
    parsedShellDocumentInvariant(field + " quote kind");
  return word as LiteralWord;
}

function assertParsedQuoteKind(word: LiteralWord, field: string): void {
  const quoteKind: unknown = word.quoteKind;
  if (
    quoteKind !== null &&
    quoteKind !== "single" &&
    quoteKind !== "double" &&
    quoteKind !== "projected"
  )
    parsedShellDocumentInvariant(field + " quote kind");
}

function assertParsedWord(
  source: string,
  word: ParsedShellWord,
  field: string,
): void {
  assertParsedSpan(source, word.rawSpan, field + " raw span");
  if (word.kind === "literal") {
    const literal = literalParsedWord(word, field);
    const syntax: unknown = literal.syntax;
    if (
      syntax !== "word" &&
      syntax !== "raw_string" &&
      syntax !== "string" &&
      syntax !== "concatenation" &&
      syntax !== "synthetic"
    )
      parsedShellDocumentInvariant(field + " syntax");
    if (typeof literal.value !== "string")
      parsedShellDocumentInvariant(field + " value");
    assertParsedQuoteKind(literal, field);
    assertParsedProjection(
      source,
      literal.projection,
      literal.value.length,
      field + " projection",
    );
    assertParsedContains(
      literal.rawSpan,
      literal.projection.span,
      field + " projection span",
    );
    return;
  }
  if ((word as { kind: unknown }).kind !== "nonliteral")
    parsedShellDocumentInvariant(field + " kind");
  const reason: unknown = word.reason;
  if (
    reason !== "unsafe_unquoted" &&
    reason !== "dynamic_child" &&
    reason !== "unsupported_node" &&
    reason !== "invalid_quoting"
  )
    parsedShellDocumentInvariant(field + " reason");
  if (typeof word.syntax !== "string" || !isParsedArray(word.nodeTypes))
    parsedShellDocumentInvariant(field + " nonliteral");
  if (word.nodeTypes.some((nodeType) => typeof nodeType !== "string"))
    parsedShellDocumentInvariant(field + " node types");
}

function assertParsedArgument(
  source: string,
  argument: ParsedShellArgument,
  field: string,
): void {
  if (typeof argument.synthetic !== "boolean")
    parsedShellDocumentInvariant(field + " synthetic");
  assertParsedWord(source, argument.word, field + " word");
  if (argument.synthetic) {
    assertParsedSyntheticStdinArgument(source, argument);
  } else if (argument.word.syntax === "synthetic") {
    parsedShellDocumentInvariant(field + " synthetic");
  }
}

function assertParsedDescriptor(
  source: string,
  descriptor: ParsedShellRedirectDescriptor | null,
  redirectSpan: ParsedShellSpan,
): void {
  if (descriptor === null) return;
  assertParsedSpan(source, descriptor.rawSpan, "redirect descriptor span");
  assertParsedContains(
    redirectSpan,
    descriptor.rawSpan,
    "redirect descriptor span",
  );
  const raw = source.slice(descriptor.rawSpan.start, descriptor.rawSpan.end);
  if (
    !/^\d+$/.test(descriptor.value) ||
    descriptor.value !== descriptor.value.replace(/^0+(?=\d)/, "") ||
    !/^\d+$/.test(raw) ||
    descriptor.value !== canonicalDecimal(raw)
  )
    parsedShellDocumentInvariant("redirect descriptor value");
}

function assertParsedRedirectPrefix(redirect: ParsedShellRedirect): void {
  const descriptor = redirect.descriptor;
  const expectedStart =
    descriptor?.rawSpan.start ?? redirect.operatorSpan.start;
  if (redirect.span.start !== expectedStart)
    parsedShellDocumentInvariant("redirect span start");
  if (
    descriptor !== null &&
    descriptor.rawSpan.end !== redirect.operatorSpan.start
  )
    parsedShellDocumentInvariant("redirect descriptor position");
}

function assertParsedRedirectValuePosition(
  operatorSpan: ParsedShellSpan,
  valueSpan: ParsedShellSpan,
  field: string,
): void {
  if (valueSpan.start < operatorSpan.end) parsedShellDocumentInvariant(field);
}

function isParsedRedirectPayloadGap(
  source: string,
  start: number,
  end: number,
): boolean {
  let index = start;
  while (index < end) {
    const character = source.charCodeAt(index);
    if (character === 32 || character === 9) {
      index++;
      continue;
    }
    if (character !== 92) return false;
    if (source.charCodeAt(index + 1) === 10) {
      index += 2;
      continue;
    }
    if (
      source.charCodeAt(index + 1) === 13 &&
      source.charCodeAt(index + 2) === 10
    ) {
      index += 3;
      continue;
    }
    return false;
  }
  return true;
}

function assertParsedRedirectPayload(
  source: string,
  redirect: ParsedShellFileRedirect | ParsedShellHereStringRedirect,
  payloadSpan: ParsedShellSpan,
  field: string,
): void {
  assertParsedRedirectValuePosition(redirect.operatorSpan, payloadSpan, field);
  if (
    !isParsedRedirectPayloadGap(
      source,
      redirect.operatorSpan.end,
      payloadSpan.start,
    )
  )
    parsedShellDocumentInvariant(field + " gap");
  if (redirect.span.end !== payloadSpan.end)
    parsedShellDocumentInvariant(field + " end");
}

function assertParsedOperator(
  source: string,
  operator: ParsedShellOperator,
  field: string,
): void {
  let text: ParsedShellOperator["text"];
  switch (operator.kind) {
    case "and":
      text = "&&";
      break;
    case "or":
      text = "||";
      break;
    case "pipe":
      text = "|";
      break;
    case "pipe_stderr":
      text = "|&";
      break;
    default:
      return parsedShellDocumentInvariant(field + " kind");
  }
  if (operator.text !== text) parsedShellDocumentInvariant(field + " kind");
  assertParsedSourceText(source, operator.span, operator.text, field + " text");
}

function assertParsedBoundary(
  source: string,
  boundary: ParsedShellBoundary,
  field: string,
): void {
  switch (boundary.kind) {
    case "newline":
      if (boundary.text !== "\n" && boundary.text !== "\r\n")
        parsedShellDocumentInvariant(field + " kind");
      break;
    case "semicolon":
      if (boundary.text !== ";") parsedShellDocumentInvariant(field + " kind");
      break;
    case "background":
      if (boundary.text !== "&") parsedShellDocumentInvariant(field + " kind");
      break;
    case "case":
      if (boundary.text !== ";;") parsedShellDocumentInvariant(field + " kind");
      break;
    default:
      return parsedShellDocumentInvariant(field + " kind");
  }
  assertParsedSourceText(source, boundary.span, boundary.text, field + " text");
}

function parsedCommandForId(
  document: ParsedShellDocument,
  commandId: number,
): ParsedShellCommand {
  if (!Number.isInteger(commandId) || commandId < 0)
    parsedShellDocumentInvariant("command id");
  const command = document.commands[commandId];
  if (command === undefined || command.id !== commandId)
    parsedShellDocumentInvariant("command id");
  return command;
}

function parsedRedirectForId(
  document: ParsedShellDocument,
  redirectId: number,
): ParsedShellRedirect {
  if (!Number.isInteger(redirectId) || redirectId < 0)
    parsedShellDocumentInvariant("redirect id");
  const redirect = document.redirects[redirectId];
  if (redirect === undefined || redirect.id !== redirectId)
    parsedShellDocumentInvariant(
      redirect?.kind === "heredoc" ? "heredoc redirect id" : "redirect id",
    );
  return redirect;
}

function assertParsedCommands(document: ParsedShellDocument): void {
  if (!isParsedArray(document.commands))
    parsedShellDocumentInvariant("commands");
  let previousStart = -1;
  for (let index = 0; index < document.commands.length; index++) {
    const command = document.commands[index];
    if (command === undefined || command.id !== index)
      parsedShellDocumentInvariant("command id");
    assertParsedSpan(document.source, command.span, "command span");
    if (command.span.start < previousStart)
      parsedShellDocumentInvariant("command order");
    previousStart = command.span.start;
    assertParsedWord(document.source, command.name, "command name");
    if (
      !isParsedArray(command.assignments) ||
      !isParsedArray(command.arguments) ||
      !isParsedArray(command.redirectIds)
    )
      parsedShellDocumentInvariant("command records");
    assertParsedContains(
      command.span,
      command.name.rawSpan,
      "command name span",
    );
    const memberSpans: ParsedShellSpan[] = [];
    for (const assignment of command.assignments) {
      assertParsedSpan(document.source, assignment.span, "assignment span");
      assertParsedContains(
        command.span,
        assignment.span,
        "command assignment span",
      );
      assertParsedSpan(
        document.source,
        assignment.nameSpan,
        "assignment name span",
      );
      assertParsedContains(
        assignment.span,
        assignment.nameSpan,
        "assignment name span",
      );
      if (
        typeof assignment.name !== "string" ||
        assignment.name.length === 0 ||
        document.source.slice(
          assignment.nameSpan.start,
          assignment.nameSpan.end,
        ) !== assignment.name
      )
        parsedShellDocumentInvariant("assignment name");
      if (assignment.value !== null) {
        assertParsedWord(document.source, assignment.value, "assignment value");
        assertParsedContains(
          assignment.span,
          assignment.value.rawSpan,
          "assignment value span",
        );
      }
      memberSpans.push(assignment.span);
    }
    memberSpans.push(command.name.rawSpan);
    for (const argument of command.arguments) {
      assertParsedArgument(document.source, argument, "command argument");
      if (argument.synthetic) continue;
      assertParsedContains(
        command.span,
        argument.word.rawSpan,
        "command argument span",
      );
      memberSpans.push(argument.word.rawSpan);
    }
    let previousMemberEnd = -1;
    for (const span of memberSpans) {
      if (span.start < previousMemberEnd)
        parsedShellDocumentInvariant("command member order");
      previousMemberEnd = span.end;
    }
  }
}

function assertParsedRedirects(document: ParsedShellDocument): void {
  if (!isParsedArray(document.redirects))
    parsedShellDocumentInvariant("redirects");
  let heredocCount = 0;
  let previousStart = -1;
  let previousEnd = -1;
  for (let index = 0; index < document.redirects.length; index++) {
    const redirect = document.redirects[index];
    if (redirect === undefined || redirect.id !== index)
      parsedShellDocumentInvariant(
        redirect?.kind === "heredoc" ? "heredoc redirect id" : "redirect id",
      );
    assertParsedSpan(document.source, redirect.span, "redirect span");
    if (
      redirect.span.start < previousStart ||
      (redirect.span.start === previousStart && redirect.span.end < previousEnd)
    )
      parsedShellDocumentInvariant("redirect order");
    previousStart = redirect.span.start;
    previousEnd = redirect.span.end;
    parsedCommandForId(document, redirect.ownerId);
    assertParsedDescriptor(document.source, redirect.descriptor, redirect.span);

    if (redirect.kind === "file") {
      const operator: unknown = redirect.operator;
      if (
        operator !== "<" &&
        operator !== ">" &&
        operator !== ">>" &&
        operator !== "&>" &&
        operator !== "&>>" &&
        operator !== "<&" &&
        operator !== ">&" &&
        operator !== ">|"
      )
        parsedShellDocumentInvariant("redirect operator");
      assertParsedSourceText(
        document.source,
        redirect.operatorSpan,
        redirect.operator,
        "redirect operator",
      );
      assertParsedContains(
        redirect.span,
        redirect.operatorSpan,
        "redirect operator span",
      );
      assertParsedRedirectPrefix(redirect);
      if (redirect.destination !== null) {
        assertParsedWord(
          document.source,
          redirect.destination,
          "redirect destination",
        );
        assertParsedContains(
          redirect.span,
          redirect.destination.rawSpan,
          "redirect destination span",
        );
        assertParsedRedirectPayload(
          document.source,
          redirect,
          redirect.destination.rawSpan,
          "redirect destination position",
        );
      } else parsedShellDocumentInvariant("redirect destination");
      if (
        (redirect.operator === "&>" || redirect.operator === "&>>") &&
        redirect.descriptor !== null
      )
        parsedShellDocumentInvariant("stdout redirect descriptor");
      continue;
    }

    if (redirect.kind === "herestring") {
      if ((redirect.operator as unknown) !== "<<<")
        parsedShellDocumentInvariant("herestring operator");
      assertParsedSourceText(
        document.source,
        redirect.operatorSpan,
        "<<<",
        "herestring operator",
      );
      assertParsedContains(
        redirect.span,
        redirect.operatorSpan,
        "herestring operator span",
      );
      assertParsedRedirectPrefix(redirect);
      assertParsedWord(document.source, redirect.value, "herestring value");
      assertParsedContains(
        redirect.span,
        redirect.value.rawSpan,
        "herestring value span",
      );
      assertParsedRedirectPayload(
        document.source,
        redirect,
        redirect.value.rawSpan,
        "herestring value position",
      );
      continue;
    }

    if ((redirect.kind as unknown) !== "heredoc")
      parsedShellDocumentInvariant("redirect kind");
    heredocCount++;
    assertParsedHeredocRedirect(document, redirect);
  }
  if (heredocCount > 1) parsedShellDocumentInvariant("heredoc count");
  assertParsedRedirectExclusivity(document);
}

function spansOverlap(left: ParsedShellSpan, right: ParsedShellSpan): boolean {
  return left.start < right.end && right.start < left.end;
}

function assertParsedRedirectExclusivity(document: ParsedShellDocument): void {
  const heredoc = document.redirects.find(
    (redirect) => redirect.kind === "heredoc",
  );
  const nested = new Set(heredoc?.nestedRedirectIds);
  let previous: ParsedShellRedirect | undefined;
  for (const redirect of document.redirects) {
    if (redirect === heredoc) continue;
    if (
      heredoc !== undefined &&
      spansOverlap(heredoc.span, redirect.span) &&
      (!nested.has(redirect.id) ||
        redirect.span.start < heredoc.headerSpan.start ||
        redirect.span.end > heredoc.headerSpan.end)
    )
      parsedShellDocumentInvariant("redirect overlap");
    if (previous !== undefined && spansOverlap(previous.span, redirect.span))
      parsedShellDocumentInvariant("redirect overlap");
    previous = redirect;
  }
}

function assertParsedHeredocRedirect(
  document: ParsedShellDocument,
  redirect: ParsedShellHeredocRedirect,
): void {
  const source = document.source;
  if ((redirect.operator as unknown) !== "<<")
    parsedShellDocumentInvariant("heredoc operator");
  assertParsedSourceText(
    source,
    redirect.operatorSpan,
    "<<",
    "heredoc operator",
  );
  assertParsedContains(
    redirect.span,
    redirect.operatorSpan,
    "heredoc operator span",
  );
  assertParsedRedirectPrefix(redirect);
  assertParsedSpan(source, redirect.headerSpan, "heredoc header span");
  assertParsedSpan(
    source,
    redirect.headerLineBreakSpan,
    "heredoc line break span",
  );
  assertParsedSpan(
    source,
    redirect.delimiter.rawSpan,
    "heredoc delimiter span",
  );
  assertParsedSpan(source, redirect.rawBodySpan, "heredoc raw body span");
  assertParsedSpan(source, redirect.contentSpan, "heredoc content span");
  assertParsedSpan(source, redirect.terminatorSpan, "heredoc terminator span");
  assertParsedContains(
    redirect.headerSpan,
    redirect.delimiter.rawSpan,
    "heredoc delimiter span",
  );
  assertParsedContains(
    redirect.span,
    redirect.delimiter.rawSpan,
    "heredoc delimiter redirect span",
  );
  assertParsedContains(
    redirect.headerSpan,
    redirect.operatorSpan,
    "heredoc operator header span",
  );
  assertParsedRedirectValuePosition(
    redirect.operatorSpan,
    redirect.delimiter.rawSpan,
    "heredoc delimiter position",
  );
  assertParsedContains(
    redirect.span,
    redirect.rawBodySpan,
    "heredoc raw body span",
  );
  assertParsedContains(
    redirect.span,
    redirect.terminatorSpan,
    "heredoc terminator span",
  );
  if (
    redirect.headerSpan.end !== redirect.headerLineBreakSpan.start ||
    redirect.headerLineBreakSpan.end !== redirect.rawBodySpan.start ||
    redirect.rawBodySpan.start !== redirect.contentSpan.start ||
    redirect.rawBodySpan.end !== redirect.terminatorSpan.start ||
    redirect.span.end !== redirect.terminatorSpan.end
  )
    parsedShellDocumentInvariant("heredoc span order");
  const rawBody = source.slice(
    redirect.rawBodySpan.start,
    redirect.rawBodySpan.end,
  );
  const expectedContentEnd = rawBody.endsWith("\r\n")
    ? redirect.rawBodySpan.end - 2
    : rawBody.endsWith("\n")
      ? redirect.rawBodySpan.end - 1
      : redirect.rawBodySpan.end;
  if (redirect.contentSpan.end !== expectedContentEnd)
    parsedShellDocumentInvariant("heredoc content span");
  const lineBreak = source.slice(
    redirect.headerLineBreakSpan.start,
    redirect.headerLineBreakSpan.end,
  );
  if (lineBreak !== "\n" && lineBreak !== "\r\n")
    parsedShellDocumentInvariant("heredoc line break");
  if (
    typeof redirect.delimiter.value !== "string" ||
    redirect.delimiter.value.length === 0 ||
    typeof redirect.delimiter.quoted !== "boolean"
  )
    parsedShellDocumentInvariant("heredoc delimiter");
  const delimiter = source.slice(
    redirect.delimiter.rawSpan.start,
    redirect.delimiter.rawSpan.end,
  );
  if (
    redirect.delimiter.quoted
      ? delimiter !== "'" + redirect.delimiter.value + "'" &&
        delimiter !== '"' + redirect.delimiter.value + '"'
      : delimiter !== redirect.delimiter.value
  )
    parsedShellDocumentInvariant("heredoc delimiter");
  if (
    source.slice(redirect.terminatorSpan.start, redirect.terminatorSpan.end) !==
    redirect.delimiter.value
  )
    parsedShellDocumentInvariant("heredoc terminator");
  if (!isParsedArray(redirect.header.arguments))
    parsedShellDocumentInvariant("heredoc header arguments");
  for (const argument of redirect.header.arguments) {
    assertParsedArgument(source, argument, "heredoc header argument");
    assertParsedContains(
      redirect.headerSpan,
      argument.word.rawSpan,
      "heredoc header argument span",
    );
  }
  const continuation = redirect.header.continuation;
  if (continuation !== null) {
    if (continuation.kind === "right") {
      assertParsedOperator(
        source,
        continuation.operator,
        "heredoc continuation",
      );
      assertParsedContains(
        redirect.headerSpan,
        continuation.operator.span,
        "heredoc continuation span",
      );
      if (continuation.operator.span.end > continuation.unit.span.start)
        parsedShellDocumentInvariant("heredoc continuation position");
      assertParsedHeaderUnit(
        source,
        continuation.unit,
        redirect.headerSpan,
        "heredoc continuation",
      );
    } else {
      if ((continuation.kind as unknown) !== "pipeline")
        parsedShellDocumentInvariant("heredoc continuation");
      if ((continuation.unit.kind as unknown) !== "pipeline")
        parsedShellDocumentInvariant("heredoc continuation");
      assertParsedHeaderUnit(
        source,
        continuation.unit,
        redirect.headerSpan,
        "heredoc continuation",
      );
    }
  }
  if (!isParsedArray(redirect.nestedRedirectIds))
    parsedShellDocumentInvariant("nested redirect ids");
  const nested = new Set<number>();
  for (const nestedId of redirect.nestedRedirectIds) {
    if (nested.has(nestedId))
      parsedShellDocumentInvariant("nested redirect id");
    nested.add(nestedId);
    const nestedRedirect = parsedRedirectForId(document, nestedId);
    if (
      nestedRedirect.id === redirect.id ||
      nestedRedirect.ownerId !== redirect.ownerId
    )
      parsedShellDocumentInvariant("nested redirect owner");
    assertParsedContains(
      redirect.headerSpan,
      nestedRedirect.span,
      "nested redirect span",
    );
    if (!document.commands[redirect.ownerId]!.redirectIds.includes(nestedId))
      parsedShellDocumentInvariant("nested redirect membership");
  }
}

function assertParsedRedirectMembership(document: ParsedShellDocument): void {
  const counts = new Array<number>(document.redirects.length).fill(0);
  for (const command of document.commands) {
    const ids = new Set<number>();
    for (const redirectId of command.redirectIds) {
      if (ids.has(redirectId))
        parsedShellDocumentInvariant("redirect owner membership");
      ids.add(redirectId);
      const redirect = parsedRedirectForId(document, redirectId);
      if (redirect.ownerId !== command.id)
        parsedShellDocumentInvariant("redirect owner");
      counts[redirectId] = (counts[redirectId] ?? 0) + 1;
    }
  }
  for (let index = 0; index < counts.length; index++)
    if (counts[index] !== 1)
      parsedShellDocumentInvariant("redirect owner membership");
}

function assertParsedUnit(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
  field: string,
  provenance: ParsedUnitProvenance,
): void {
  const pending = [unit];
  while (pending.length > 0) {
    const current = pending.pop()!;
    assertParsedUnitNode(
      document,
      current,
      current === unit ? field : current.kind,
      provenance,
    );
    const children = parsedUnitChildren(current);
    for (let index = children.length - 1; index >= 0; index--)
      pending.push(children[index]!);
  }
}

function assertParsedUnitNode(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
  field: string,
  provenance: ParsedUnitProvenance,
): void {
  const source = document.source;
  assertParsedSpan(source, unit.span, field + " span");
  if (unit.kind === "command") {
    const command = parsedCommandForId(document, unit.commandId);
    if (provenance.commandUnits.has(command.id))
      parsedShellDocumentInvariant("command unit references");
    provenance.commandUnitIds.push(command.id);
    provenance.commandUnits.set(command.id, unit);
    return;
  }
  if (unit.kind === "opaque") {
    const reason: unknown = unit.reason;
    if (
      (reason !== "unsupported_construct" && reason !== "control_body") ||
      typeof unit.nodeType !== "string" ||
      unit.nodeType.length === 0
    )
      parsedShellDocumentInvariant(field + " opaque");
    provenance.opaqueUnits.push(unit);
    return;
  }
  if (unit.kind === "redirected_statement") {
    assertParsedSpan(source, unit.body.span, field + " body span");
    assertParsedContains(unit.span, unit.body.span, field + " body span");
    if (!isParsedArray(unit.redirectIds))
      parsedShellDocumentInvariant(field + " redirect ids");
    const ownerId = parsedRightEdgeCommandId(unit.body);
    const ids = new Set<number>();
    for (const redirectId of unit.redirectIds) {
      if (ids.has(redirectId))
        parsedShellDocumentInvariant(field + " redirect id");
      ids.add(redirectId);
      const redirect = parsedRedirectForId(document, redirectId);
      if (ownerId === null || redirect.ownerId !== ownerId)
        parsedShellDocumentInvariant(field + " redirect owner");
      assertParsedContains(unit.span, redirect.span, field + " redirect span");
      if (provenance.redirectedUnits.has(redirect.id))
        parsedShellDocumentInvariant("redirect unit envelope");
      provenance.redirectedUnits.set(redirect.id, unit);
      provenance.wrapperRedirectIds.add(redirect.id);
    }
    return;
  }
  const kind: unknown = unit.kind;
  if (kind !== "program" && kind !== "list" && kind !== "pipeline")
    parsedShellDocumentInvariant(field + " kind");
  if (!isParsedArray(unit.children))
    parsedShellDocumentInvariant(field + " children");
  for (let index = 0; index < unit.children.length; index++) {
    const child = unit.children[index]!;
    assertParsedSpan(source, child.span, field + " child span");
    assertParsedContains(unit.span, child.span, field + " child span");
    if (index > 0 && child.span.start < unit.children[index - 1]!.span.end)
      parsedShellDocumentInvariant(field + " child order");
  }
  if (unit.kind === "program") {
    if (!isParsedArray(unit.boundaries))
      parsedShellDocumentInvariant(field + " boundaries");
    let previousEnd = -1;
    let precedingIndex = -1;
    for (const boundary of unit.boundaries) {
      assertParsedBoundary(source, boundary, field + " boundary");
      assertParsedContains(unit.span, boundary.span, field + " boundary span");
      if (boundary.span.start < previousEnd)
        parsedShellDocumentInvariant(field + " boundary order");
      previousEnd = boundary.span.end;
      while (
        precedingIndex + 1 < unit.children.length &&
        unit.children[precedingIndex + 1]!.span.end <= boundary.span.start
      )
        precedingIndex++;
      const next = unit.children[precedingIndex + 1];
      if (
        precedingIndex < 0 ||
        (next !== undefined && boundary.span.end > next.span.start)
      )
        parsedShellDocumentInvariant(field + " boundary position");
    }
    return;
  }
  if (
    unit.children.length < 2 ||
    !isParsedArray(unit.operators) ||
    unit.operators.length !== unit.children.length - 1
  )
    parsedShellDocumentInvariant(field + " operator count");
  for (let index = 0; index < unit.operators.length; index++) {
    const operator = unit.operators[index]!;
    const before = unit.children[index]!;
    const after = unit.children[index + 1]!;
    assertParsedOperator(source, operator, field + " operator");
    assertParsedContains(unit.span, operator.span, field + " operator span");
    if (
      operator.span.start < before.span.end ||
      operator.span.end > after.span.start
    )
      parsedShellDocumentInvariant(field + " operator position");
  }
}

function assertParsedCommandUnitReferences(
  document: ParsedShellDocument,
  commandUnitIds: readonly number[],
): void {
  if (
    commandUnitIds.length !== document.commands.length ||
    commandUnitIds.some((commandId, index) => commandId !== index)
  )
    parsedShellDocumentInvariant("command unit references");
}

function assertParsedUnitStarts(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
  provenance: ParsedUnitProvenance,
  starts: ParsedUnitStarts,
): number | null {
  return foldParsedShellUnit<number | null>(unit, (current, childStarts) =>
    assertParsedUnitStart(document, current, childStarts, provenance, starts),
  );
}

function assertParsedUnitStart(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
  childStarts: readonly (number | null)[],
  provenance: ParsedUnitProvenance,
  starts: ParsedUnitStarts,
): number | null {
  if (unit.kind === "command") {
    const command = parsedCommandForId(document, unit.commandId);
    if (provenance.commandUnits.get(command.id) !== unit)
      parsedShellDocumentInvariant("command unit references");
    const directRedirectIds = command.redirectIds.filter(
      (redirectId) =>
        !provenance.wrapperRedirectIds.has(redirectId) &&
        !provenance.nestedRedirectIds.has(redirectId),
    );
    const memberStarts = [
      command.name.rawSpan.start,
      ...command.assignments.map((assignment) => assignment.span.start),
      ...command.arguments
        .filter((argument) => !argument.synthetic)
        .map((argument) => argument.word.rawSpan.start),
      ...directRedirectIds.map(
        (redirectId) => parsedRedirectForId(document, redirectId).span.start,
      ),
    ];
    const start = Math.min(...memberStarts);
    if (unit.span.start !== start)
      parsedShellDocumentInvariant("command unit start");
    const commandMembers = [
      command.name.rawSpan,
      ...command.assignments.map((assignment) => assignment.span),
    ];
    for (const member of commandMembers) {
      if (member.start < unit.span.end && member.end > unit.span.end)
        parsedShellDocumentInvariant("command unit end");
      if (member.start >= unit.span.end)
        parsedShellDocumentInvariant("command unit end");
    }
    for (const redirectId of directRedirectIds)
      assertParsedContains(
        unit.span,
        parsedRedirectForId(document, redirectId).span,
        "command unit redirect span",
      );
    const wrapperRedirects = command.redirectIds
      .filter((redirectId) => provenance.wrapperRedirectIds.has(redirectId))
      .map((redirectId) => parsedRedirectForId(document, redirectId));
    for (const argument of command.arguments) {
      if (argument.synthetic) continue;
      const span = argument.word.rawSpan;
      if (span.start < unit.span.end) {
        if (span.end > unit.span.end)
          parsedShellDocumentInvariant("command unit end");
        continue;
      }
      const detachedSuffix = wrapperRedirects.some(
        (redirect) =>
          (redirect.span.start < unit.span.end &&
            redirect.span.end > unit.span.end) ||
          (redirect.span.start >= unit.span.end &&
            redirect.span.end <= span.start),
      );
      if (!detachedSuffix) parsedShellDocumentInvariant("command unit end");
    }
    starts.command.set(command.id, start);
    return start;
  }

  if (unit.kind === "opaque") return unit.span.start;

  if (unit.kind === "redirected_statement") {
    const bodyStart = childStarts[0] as number | null;
    const redirectStarts = unit.redirectIds.map((redirectId) => {
      if (provenance.redirectedUnits.get(redirectId) !== unit)
        parsedShellDocumentInvariant("redirect unit envelope");
      return parsedRedirectForId(document, redirectId).span.start;
    });
    const memberStarts = [
      ...(bodyStart === null ? [] : [bodyStart]),
      ...redirectStarts,
    ];
    if (memberStarts.length === 0) return null;
    const start = Math.min(...memberStarts);
    if (unit.span.start !== start)
      parsedShellDocumentInvariant("redirected statement unit start");
    for (const redirectId of unit.redirectIds)
      starts.redirected.set(redirectId, start);
    return start;
  }

  if (unit.kind === "program") return null;

  const start = childStarts[0];
  if (start === null || start === undefined) return null;
  if (unit.span.start !== start)
    parsedShellDocumentInvariant(unit.kind + " unit start");
  return start;
}

function parsedRedirectUnitEnvelopes(
  document: ParsedShellDocument,
  starts: ParsedUnitStarts,
): ReadonlyMap<number, number> {
  const envelopes = new Map<number, number>();
  for (const redirect of document.redirects) {
    const envelope =
      starts.redirected.get(redirect.id) ??
      starts.command.get(redirect.ownerId);
    if (envelope === undefined)
      parsedShellDocumentInvariant("redirect unit envelope");
    envelopes.set(redirect.id, envelope);
  }
  return envelopes;
}

function assertParsedHeredocHeaderAnchors(
  document: ParsedShellDocument,
  redirectUnitEnvelopes: ReadonlyMap<number, number>,
): void {
  for (const redirect of document.redirects) {
    if (redirect.kind !== "heredoc") continue;
    const envelope = redirectUnitEnvelopes.get(redirect.id);
    if (envelope === undefined || redirect.headerSpan.start !== envelope)
      parsedShellDocumentInvariant("heredoc header start");
  }
}

function parsedUnitChildren(unit: ParsedShellUnit): readonly ParsedShellUnit[] {
  switch (unit.kind) {
    case "program":
    case "list":
    case "pipeline":
      return unit.children;
    case "redirected_statement":
      return [unit.body];
    default:
      return [];
  }
}

export function foldParsedShellUnit<R>(
  root: ParsedShellUnit,
  combine: (unit: ParsedShellUnit, children: R[]) => R,
): R {
  return reduceTree(root, parsedUnitChildren, combine);
}

function parsedRightEdgeCommandId(unit: ParsedShellUnit): number | null {
  let current: ParsedShellUnit | undefined = unit;
  while (current !== undefined) {
    if (current.kind === "command") return current.commandId;
    current = parsedUnitChildren(current).at(-1);
  }
  return null;
}

function assertParsedHeaderUnit(
  source: string,
  unit: ParsedShellHeaderUnit,
  outerSpan: ParsedShellSpan,
  field: string,
): void {
  assertParsedSpan(source, unit.span, field + " span");
  assertParsedContains(outerSpan, unit.span, field + " span");
  if (unit.kind === "command") {
    assertParsedWord(source, unit.name, field + " name");
    assertParsedContains(unit.span, unit.name.rawSpan, field + " name span");
    for (const argument of unit.arguments) {
      assertParsedArgument(source, argument, field + " argument");
      assertParsedContains(
        unit.span,
        argument.word.rawSpan,
        field + " argument span",
      );
    }
    return;
  }
  if (unit.kind === "opaque") {
    if (typeof unit.nodeType !== "string" || unit.nodeType.length === 0)
      parsedShellDocumentInvariant(field + " opaque");
    return;
  }
  const kind: unknown = unit.kind;
  if (
    (kind !== "list" && kind !== "pipeline") ||
    unit.children.length < 1 ||
    (unit.operators.length !== unit.children.length - 1 &&
      unit.operators.length !== unit.children.length)
  )
    parsedShellDocumentInvariant(field + " operator count");
  for (let index = 0; index < unit.children.length; index++) {
    const child = unit.children[index]!;
    assertParsedHeaderUnit(source, child, unit.span, field + " child");
    if (index > 0 && child.span.start < unit.children[index - 1]!.span.end)
      parsedShellDocumentInvariant(field + " child order");
  }
  for (let index = 0; index < unit.operators.length; index++) {
    const operator = unit.operators[index]!;
    assertParsedOperator(source, operator, field + " operator");
    assertParsedContains(unit.span, operator.span, field + " operator span");
    const leading = unit.operators.length === unit.children.length;
    const before = unit.children[leading ? index - 1 : index];
    const after = unit.children[leading ? index : index + 1];
    if (
      (before !== undefined && operator.span.start < before.span.end) ||
      (after !== undefined && operator.span.end > after.span.start)
    )
      parsedShellDocumentInvariant(field + " operator position");
  }
}

function assertParsedPayload(
  source: string,
  payload: ParsedShellPayload,
  field: string,
): void {
  if (typeof payload.text !== "string")
    parsedShellDocumentInvariant(field + " text");
  assertParsedSpan(source, payload.rawSpan, field + " raw span");
  assertParsedSpan(source, payload.contentSpan, field + " content span");
  assertParsedProjection(
    source,
    payload.projection,
    payload.text.length,
    field + " projection",
  );
  const quoteKind: unknown = payload.quoteKind;
  if (
    quoteKind !== null &&
    quoteKind !== "single" &&
    quoteKind !== "double" &&
    quoteKind !== "projected"
  )
    parsedShellDocumentInvariant(field + " quote kind");
}

function sameParsedPayload(
  left: ParsedShellPayload,
  right: ParsedShellPayload,
): boolean {
  return (
    left.text === right.text &&
    sameParsedSpan(left.rawSpan, right.rawSpan) &&
    sameParsedSpan(left.contentSpan, right.contentSpan) &&
    sameParsedProjection(left.projection, right.projection) &&
    left.quoteKind === right.quoteKind
  );
}

function assertParsedIndexArray(
  indices: readonly number[],
  command: ParsedShellCommand,
  field: string,
): void {
  if (!isParsedArray(indices)) parsedShellDocumentInvariant(field);
  let previous = -1;
  for (const index of indices) {
    if (
      !Number.isInteger(index) ||
      index < 0 ||
      index >= command.arguments.length ||
      index <= previous
    )
      parsedShellDocumentInvariant(field);
    previous = index;
  }
}

type ParsedInterpreterValidation = Readonly<{
  effectiveStart: number;
  flags: readonly string[];
}>;

function assertParsedInterpreter(
  invocation: ParsedShellEmbeddedInvocation,
  command: ParsedShellCommand,
): ParsedInterpreterValidation {
  const spec = INTERPRETERS[invocation.interpreter.basename];
  if (spec === undefined || spec.language !== invocation.interpreter.language)
    parsedShellDocumentInvariant("interpreter specification");
  const location = invocation.interpreter.location;
  if (invocation.prefix.kind === "direct") {
    if (location.kind !== "command_name")
      parsedShellDocumentInvariant("direct interpreter location");
    const name = literalParsedWord(command.name, "direct interpreter name");
    if (name.syntax === "synthetic")
      parsedShellDocumentInvariant("direct interpreter name");
    if (basename(name.value) !== invocation.interpreter.basename)
      parsedShellDocumentInvariant("direct interpreter basename");
    return { effectiveStart: 0, flags: spec.flags };
  }
  if ((invocation.prefix.kind as unknown) !== "env")
    parsedShellDocumentInvariant("invocation prefix");
  if (!isParsedArray(invocation.prefix.assignments))
    parsedShellDocumentInvariant("env assignments");
  if (
    location.kind !== "argument" ||
    !Number.isInteger(location.index) ||
    location.index < 1 ||
    location.index >= command.arguments.length ||
    invocation.prefix.assignments.length !== location.index
  )
    parsedShellDocumentInvariant("env interpreter index");
  const commandName = literalParsedWord(
    command.name,
    "env interpreter command",
  );
  if (basename(commandName.value) !== "env")
    parsedShellDocumentInvariant("env interpreter command");
  for (let index = 0; index < invocation.prefix.assignments.length; index++) {
    const assignment = invocation.prefix.assignments[index]!;
    const argument = command.arguments[index];
    if (
      assignment.argumentIndex !== index ||
      typeof assignment.name !== "string" ||
      typeof assignment.value !== "string" ||
      !/^[A-Za-z_][A-Za-z0-9_]*$/.test(assignment.name) ||
      argument === undefined ||
      argument.synthetic
    )
      parsedShellDocumentInvariant("env assignment");
    const word = literalParsedWord(argument.word, "env assignment argument");
    if (
      word.syntax === "synthetic" ||
      word.value !== assignment.name + "=" + assignment.value
    )
      parsedShellDocumentInvariant("env assignment");
  }
  const interpreterArgument = command.arguments[location.index];
  if (interpreterArgument === undefined || interpreterArgument.synthetic)
    parsedShellDocumentInvariant("env interpreter argument");
  const interpreter = literalParsedWord(
    interpreterArgument.word,
    "env interpreter argument",
  );
  if (
    interpreter.syntax === "synthetic" ||
    interpreter.value.startsWith("-") ||
    basename(interpreter.value) !== invocation.interpreter.basename
  )
    parsedShellDocumentInvariant("env interpreter basename");
  return { effectiveStart: location.index + 1, flags: spec.flags };
}

function assertParsedInvocations(document: ParsedShellDocument): void {
  if (!isParsedArray(document.embeddedInvocations))
    parsedShellDocumentInvariant("embedded invocations");
  const owners = new Set<number>();
  for (let index = 0; index < document.embeddedInvocations.length; index++) {
    const invocation = document.embeddedInvocations[index];
    if (invocation === undefined || invocation.id !== index)
      parsedShellDocumentInvariant("invocation id");
    const command = parsedCommandForId(document, invocation.commandId);
    if (owners.has(command.id))
      parsedShellDocumentInvariant("duplicate invocation owner");
    owners.add(command.id);
    const interpreter = assertParsedInterpreter(invocation, command);
    assertParsedIndexArray(
      invocation.optionArgumentIndices,
      command,
      "invocation option indices",
    );
    assertParsedPayload(
      document.source,
      invocation.payload,
      "invocation payload",
    );
    if (invocation.kind === "inline")
      assertParsedInlineInvocation(document, invocation, command, interpreter);
    else {
      if ((invocation.kind as unknown) !== "heredoc")
        parsedShellDocumentInvariant("invocation kind");
      assertParsedHeredocInvocation(document, invocation, command, interpreter);
    }
    if (invocation.interpreter.language !== "bash" && invocation.child !== null)
      parsedShellDocumentInvariant("non-bash invocation child");
  }
}

function assertParsedInlineInvocation(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "inline" }>,
  command: ParsedShellCommand,
  interpreter: ParsedInterpreterValidation,
): void {
  if (
    invocation.optionArgumentIndices.length !== 0 ||
    !Number.isInteger(invocation.flagArgumentIndex) ||
    !Number.isInteger(invocation.payloadArgumentIndex) ||
    invocation.flagArgumentIndex !== interpreter.effectiveStart ||
    invocation.payloadArgumentIndex !== interpreter.effectiveStart + 1 ||
    command.arguments.length !== interpreter.effectiveStart + 2
  )
    parsedShellDocumentInvariant("inline argument indices");
  const flagArgument = command.arguments[invocation.flagArgumentIndex];
  const payloadArgument = command.arguments[invocation.payloadArgumentIndex];
  if (
    flagArgument === undefined ||
    payloadArgument === undefined ||
    flagArgument.synthetic ||
    payloadArgument.synthetic
  )
    parsedShellDocumentInvariant("inline argument");
  const flag = literalParsedWord(flagArgument.word, "inline flag");
  const payload = literalParsedWord(payloadArgument.word, "inline payload");
  if (flag.syntax === "synthetic" || payload.syntax === "synthetic")
    parsedShellDocumentInvariant("inline argument");
  if (!interpreter.flags.includes(flag.value))
    parsedShellDocumentInvariant("inline flag");
  if (
    command.redirectIds.some(
      (redirectId) => parsedRedirectForId(document, redirectId).kind !== "file",
    )
  )
    parsedShellDocumentInvariant("inline redirect");
  const expectedPayload = invocationPayload(payload);
  if (!sameParsedPayload(invocation.payload, expectedPayload))
    parsedShellDocumentInvariant("inline payload");
}

function assertParsedSyntheticStdinArgument(
  source: string,
  argument: ParsedShellArgument,
): void {
  if (!argument.synthetic)
    parsedShellDocumentInvariant("heredoc stdin argument");
  const word = literalParsedWord(argument.word, "heredoc stdin argument");
  if (
    word.syntax !== "synthetic" ||
    word.value !== "-" ||
    word.quoteKind !== null ||
    source.slice(word.rawSpan.start, word.rawSpan.end) !== "-" ||
    !sameParsedSpan(word.rawSpan, word.projection.span) ||
    word.projection.points.length !== 2 ||
    word.projection.points[0]!.child !== 0 ||
    word.projection.points[0]!.parent !== 0 ||
    word.projection.points[1]!.child !== 1 ||
    word.projection.points[1]!.parent !== 1
  )
    parsedShellDocumentInvariant("heredoc stdin argument");
}

function assertParsedHeredocInvocation(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "heredoc" }>,
  command: ParsedShellCommand,
  interpreter: ParsedInterpreterValidation,
): void {
  const redirect = parsedRedirectForId(document, invocation.heredocRedirectId);
  if (
    redirect.kind !== "heredoc" ||
    redirect.ownerId !== command.id ||
    !command.redirectIds.includes(redirect.id)
  )
    parsedShellDocumentInvariant("heredoc invocation ownership");
  if (redirect.header.arguments.length !== 0)
    parsedShellDocumentInvariant("heredoc invocation header");
  const effectiveStdin = command.redirectIds
    .map((redirectId) => parsedRedirectForId(document, redirectId))
    .filter((candidate) => redirectAffectsStdin(candidate))
    .sort(
      (left, right) =>
        left.span.start - right.span.start || left.span.end - right.span.end,
    )
    .at(-1);
  if (effectiveStdin !== redirect)
    parsedShellDocumentInvariant("heredoc effective stdin");

  const expectedOptions: number[] = [];
  let expectedStdin: number | null = null;
  for (
    let index = interpreter.effectiveStart;
    index < command.arguments.length;
    index++
  ) {
    const argument = command.arguments[index]!;
    const word = literalParsedWord(argument.word, "heredoc argument");
    if (
      (invocation.interpreter.basename === "python" ||
        invocation.interpreter.basename === "python3") &&
      !argument.synthetic &&
      word.syntax !== "synthetic" &&
      word.value === "-u" &&
      expectedOptions.length === 0
    ) {
      expectedOptions.push(index);
      continue;
    }
    if (word.value === "-") {
      if (expectedStdin !== null || index !== command.arguments.length - 1)
        parsedShellDocumentInvariant("heredoc stdin index");
      assertParsedSyntheticStdinArgument(document.source, argument);
      expectedStdin = index;
      continue;
    }
    parsedShellDocumentInvariant("heredoc argument");
  }
  if (
    invocation.optionArgumentIndices.length !== expectedOptions.length ||
    invocation.optionArgumentIndices.some(
      (option, index) => option !== expectedOptions[index],
    ) ||
    invocation.stdinArgumentIndex !== expectedStdin
  )
    parsedShellDocumentInvariant("heredoc argument indices");
  if (
    invocation.stdinArgumentIndex !== null &&
    (!Number.isInteger(invocation.stdinArgumentIndex) ||
      invocation.stdinArgumentIndex < interpreter.effectiveStart ||
      invocation.stdinArgumentIndex >= command.arguments.length)
  )
    parsedShellDocumentInvariant("heredoc stdin index");
  const expectedPayload = plainBodyPayload(redirect, document.source);
  if (!sameParsedPayload(invocation.payload, expectedPayload))
    parsedShellDocumentInvariant("heredoc payload");
}

function assertParsedDiagnostics(document: ParsedShellDocument): void {
  if (!isParsedArray(document.diagnostics))
    parsedShellDocumentInvariant("diagnostics");
  const sorted = sortDiagnostics(document.diagnostics);
  if (
    sorted.some(
      (diagnostic, index) => diagnostic !== document.diagnostics[index],
    )
  )
    parsedShellDocumentInvariant("diagnostic order");
  for (const diagnostic of document.diagnostics) {
    assertParsedSpan(document.source, diagnostic.span, "diagnostic span");
    switch (diagnostic.kind) {
      case "unsupported_control": {
        const operator: unknown = diagnostic.operator;
        if (
          operator !== "||" &&
          operator !== "|&" &&
          operator !== "&" &&
          operator !== ";;"
        )
          parsedShellDocumentInvariant("diagnostic operator");
        assertParsedSourceText(
          document.source,
          diagnostic.span,
          diagnostic.operator,
          "diagnostic operator",
        );
        break;
      }
      case "unsupported_construct":
        if (
          typeof diagnostic.nodeType !== "string" ||
          diagnostic.nodeType.length === 0
        )
          parsedShellDocumentInvariant("diagnostic construct");
        break;
      case "unsupported_env": {
        const issue: unknown = diagnostic.issue;
        if (
          issue !== "option" &&
          issue !== "dynamic_assignment" &&
          issue !== "missing_interpreter" &&
          issue !== "unknown_interpreter"
        )
          parsedShellDocumentInvariant("diagnostic env");
        break;
      }
      case "unsupported_wrapper": {
        const issue: unknown = diagnostic.issue;
        if (
          issue !== "wrong_flag" &&
          issue !== "missing_payload" &&
          issue !== "dynamic_payload" &&
          issue !== "extra_argument" &&
          issue !== "unsupported_stdin_arguments"
        )
          parsedShellDocumentInvariant("diagnostic wrapper");
        break;
      }
      case "unsupported_heredoc_header": {
        const issue: unknown = diagnostic.issue;
        if (
          issue !== "arguments" &&
          issue !== "right" &&
          issue !== "pipe_stderr"
        )
          parsedShellDocumentInvariant("diagnostic heredoc header");
        break;
      }
      case "child_parse_failed": {
        const reason: unknown = diagnostic.reason;
        if (reason !== "unsafe_shell_syntax" && reason !== "invalid_heredoc")
          parsedShellDocumentInvariant("child parse diagnostic");
        break;
      }
      default:
        parsedShellDocumentInvariant("diagnostic kind");
    }
  }
}

function assertParsedOpaqueDiagnosticProvenance(
  document: ParsedShellDocument,
  opaqueUnits: readonly Extract<ParsedShellUnit, { kind: "opaque" }>[],
): void {
  const key = (nodeType: string, span: ParsedShellSpan) =>
    `${span.start}:${span.end}:${nodeType}`;
  const unmatched = new Map<string, number>();
  for (const diagnostic of document.diagnostics) {
    if (diagnostic.kind !== "unsupported_construct") continue;
    const id = key(diagnostic.nodeType, diagnostic.span);
    unmatched.set(id, (unmatched.get(id) ?? 0) + 1);
  }
  for (const unit of opaqueUnits) {
    const id = key(unit.nodeType, unit.span);
    const count = unmatched.get(id);
    if (count === undefined)
      parsedShellDocumentInvariant("opaque diagnostic provenance");
    if (count === 1) unmatched.delete(id);
    else unmatched.set(id, count - 1);
  }
  if (unmatched.size !== 0)
    parsedShellDocumentInvariant("opaque diagnostic provenance");
}

function assertParsedChildRelationships(
  document: ParsedShellDocument,
  ancestors: ReadonlySet<ParsedShellDocument>,
): void {
  const key = (span: ParsedShellSpan) => `${span.start}:${span.end}`;
  const diagnostics = new Map<string, number>();
  for (const diagnostic of document.diagnostics) {
    if (diagnostic.kind !== "child_parse_failed") continue;
    const id = key(diagnostic.span);
    diagnostics.set(id, (diagnostics.get(id) ?? 0) + 1);
  }
  const failedChildren = new Set<string>();
  for (const invocation of document.embeddedInvocations) {
    const id = key(invocation.payload.rawSpan);
    const matches = diagnostics.get(id) ?? 0;
    if (invocation.interpreter.language !== "bash") {
      if (invocation.child !== null || matches !== 0)
        parsedShellDocumentInvariant("non-bash invocation child");
      continue;
    }
    if (invocation.child === null) {
      if (matches !== 1) parsedShellDocumentInvariant("bash invocation child");
      if (failedChildren.has(id))
        parsedShellDocumentInvariant("child parse diagnostic");
      failedChildren.add(id);
      continue;
    }
    if (ancestors.has(invocation.child))
      parsedShellDocumentInvariant("shell document child cycle");
    if (matches !== 0)
      parsedShellDocumentInvariant("bash invocation child diagnostic");
    if (invocation.child.source !== invocation.payload.text)
      parsedShellDocumentInvariant("bash invocation child source");
    assertParsedShellDocument(invocation.child, ancestors);
  }
  if (failedChildren.size !== diagnostics.size)
    parsedShellDocumentInvariant("child parse diagnostic");
}

function addWrapperDiagnostic(
  state: NormalizationState,
  span: ParsedShellSpan,
  issue:
    | "wrong_flag"
    | "missing_payload"
    | "dynamic_payload"
    | "extra_argument"
    | "unsupported_stdin_arguments",
): void {
  state.diagnostics.push({ kind: "unsupported_wrapper", span, issue });
}

function sortDiagnostics(
  diagnostics: readonly ParsedShellDiagnostic[],
): ParsedShellDiagnostic[] {
  return [...diagnostics].sort((a, b) => {
    const sourceOrder = a.span.start - b.span.start || a.span.end - b.span.end;
    if (sourceOrder !== 0) return sourceOrder;
    const aKey = JSON.stringify(a);
    const bKey = JSON.stringify(b);
    return aKey < bKey ? -1 : aKey > bKey ? 1 : 0;
  });
}

function discoverInvocations(
  state: NormalizationState,
  redirectsByOwner: ReadonlyMap<number, readonly ParsedShellRedirect[]>,
): {
  invocations: ParsedShellEmbeddedInvocation[];
  childSources: Array<{ invocationIndex: number; source: string }>;
} {
  const drafts: ParsedShellEmbeddedInvocation[] = [];
  const childSources: Array<{ invocationIndex: number; source: string }> = [];
  state.suppressedSpans.sort((a, b) => a.start - b.start);
  let suppressedIndex = 0;
  let suppressedEnd = -1;
  for (const command of state.commands) {
    while (
      suppressedIndex < state.suppressedSpans.length &&
      state.suppressedSpans[suppressedIndex]!.start <= command.node.startIndex
    ) {
      suppressedEnd = Math.max(
        suppressedEnd,
        state.suppressedSpans[suppressedIndex]!.end,
      );
      suppressedIndex++;
    }
    if (command.node.startIndex < suppressedEnd) continue;
    const resolved = resolveInterpreter(command, state);
    if (resolved === null) continue;
    const commandRedirectRecords = redirectsByOwner.get(command.id) ?? [];
    const heredoc = commandRedirectRecords.find(
      (redirect) => redirect.kind === "heredoc",
    );
    const effectiveStdin = commandRedirectRecords
      .filter((redirect) => redirectAffectsStdin(redirect))
      .at(-1);
    if (heredoc !== undefined && effectiveStdin === heredoc) {
      const tempHeredoc = state.redirects.find(
        (redirect) =>
          redirect.kind === "heredoc" &&
          redirect.span.start === heredoc.span.start,
      );
      if (tempHeredoc === undefined || tempHeredoc.kind !== "heredoc")
        throw new Error("heredoc lookup invariant");
      if (heredoc.header.arguments.length > 0) continue;
      addSyntheticDash(command, resolved, tempHeredoc, state);
      const optionArgumentIndices: number[] = [];
      let stdinArgumentIndex: number | null = null;
      let unsupported = false;
      const effectiveAfterRecovery = command.arguments.slice(
        resolved.interpreterIndex === null ? 0 : resolved.interpreterIndex + 1,
      );
      for (const argument of effectiveAfterRecovery) {
        const index = command.arguments.indexOf(argument);
        if (argument.word.kind === "literal" && argument.word.value === "-") {
          if (
            stdinArgumentIndex !== null ||
            index !== command.arguments.length - 1
          ) {
            addWrapperDiagnostic(
              state,
              argument.word.rawSpan,
              "unsupported_stdin_arguments",
            );
            stdinArgumentIndex = null;
            unsupported = true;
            break;
          }
          stdinArgumentIndex = index;
        } else if (
          resolved.interpreter.basename === "python" ||
          resolved.interpreter.basename === "python3"
        ) {
          if (
            argument.word.kind === "literal" &&
            argument.word.value === "-u" &&
            optionArgumentIndices.length === 0
          )
            optionArgumentIndices.push(index);
          else {
            addWrapperDiagnostic(
              state,
              argument.word.rawSpan,
              "unsupported_stdin_arguments",
            );
            stdinArgumentIndex = null;
            unsupported = true;
            break;
          }
        } else {
          addWrapperDiagnostic(
            state,
            argument.word.rawSpan,
            "unsupported_stdin_arguments",
          );
          stdinArgumentIndex = null;
          unsupported = true;
          break;
        }
      }
      if (unsupported) continue;
      const payload = plainBodyPayload(heredoc, state.source);
      const invocation: ParsedShellEmbeddedInvocation = {
        kind: "heredoc",
        id: drafts.length,
        commandId: command.id,
        prefix: resolved.prefix,
        interpreter: resolved.interpreter,
        optionArgumentIndices,
        payload,
        child: null,
        heredocRedirectId: heredoc.id,
        stdinArgumentIndex,
      };
      drafts.push(invocation);
      if (resolved.interpreter.language === "bash")
        childSources.push({
          invocationIndex: drafts.length - 1,
          source: payload.text,
        });
      continue;
    }

    const args = resolved.effectiveArguments;
    if (args.length === 0) {
      addWrapperDiagnostic(state, nodeSpan(command.node), "missing_payload");
      continue;
    }
    const flag = args[0]!;
    if (
      flag.word.kind !== "literal" ||
      !INTERPRETERS[resolved.interpreter.basename]!.flags.includes(
        flag.word.value,
      )
    ) {
      addWrapperDiagnostic(state, flag.word.rawSpan, "wrong_flag");
      continue;
    }
    if (args.length < 2) {
      addWrapperDiagnostic(state, nodeSpan(command.node), "missing_payload");
      continue;
    }
    const payloadArgument = args[1]!;
    if (payloadArgument.word.kind !== "literal") {
      addWrapperDiagnostic(
        state,
        payloadArgument.word.rawSpan,
        "dynamic_payload",
      );
      continue;
    }
    const payloadWord = payloadArgument.word as LiteralWord;
    if (args.length > 2) {
      addWrapperDiagnostic(state, args[2]!.word.rawSpan, "extra_argument");
      continue;
    }
    if (commandRedirectRecords.some((redirect) => redirect.kind !== "file")) {
      addWrapperDiagnostic(state, nodeSpan(command.node), "extra_argument");
      continue;
    }
    const payload = invocationPayload(payloadWord);
    const flagIndex = command.arguments.indexOf(flag);
    const payloadIndex = command.arguments.indexOf(payloadArgument);
    const invocation: ParsedShellEmbeddedInvocation = {
      kind: "inline",
      id: drafts.length,
      commandId: command.id,
      prefix: resolved.prefix,
      interpreter: resolved.interpreter,
      optionArgumentIndices: [],
      payload,
      child: null,
      flagArgumentIndex: flagIndex,
      payloadArgumentIndex: payloadIndex,
    };
    drafts.push(invocation);
    if (resolved.interpreter.language === "bash")
      childSources.push({
        invocationIndex: drafts.length - 1,
        source: payload.text,
      });
  }
  return { invocations: drafts, childSources };
}

function finalizeDocument(
  source: string,
  root: Node,
  nativeRedirects: readonly NativeRedirect[],
): {
  result: ParseResult;
  childSources: Array<{ invocationIndex: number; source: string }>;
} {
  if (root.type !== "program")
    return {
      result: {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
        span: nodeSpan(root),
      },
      childSources: [],
    };
  const commandNodes: Node[] = [];
  collectCommandNodes(root, commandNodes);
  commandNodes.sort(
    (a, b) => a.startIndex - b.startIndex || a.endIndex - b.endIndex,
  );
  const trailingArgumentsByCommandId = new Map<number, Node[]>();
  for (const entry of nativeRedirects) {
    const redirectNode = entry.node;
    if (redirectNode.type !== "file_redirect" || entry.inHeredoc) continue;
    const trailing = nativeFileRedirectLayout(redirectNode, source).suffixNodes;
    if (trailing.length === 0) continue;
    const { owner } = entry;
    if (owner === null) continue;
    const existing = trailingArgumentsByCommandId.get(owner.id) ?? [];
    existing.push(...trailing);
    trailingArgumentsByCommandId.set(owner.id, existing);
  }
  const state: NormalizationState = {
    source,
    commandIds: new Map(commandNodes.map((node, index) => [node.id, index])),
    commands: [],
    commandByNativeId: new Map(),
    redirects: [],
    redirectByNativeId: new Map(),
    diagnostics: [],
    suppressedSpans: [],
  };
  commandNodes.forEach((node, id) => {
    const nameNode = commandNameNode(node);
    const argumentNodes = [
      ...node.childrenForFieldName("argument"),
      ...(trailingArgumentsByCommandId.get(node.id) ?? []),
    ].sort((a, b) => a.startIndex - b.startIndex);
    const assignments = node.children
      .filter((child) => child.type === "variable_assignment")
      .map((child) => normalizeAssignment(child, state));
    const command: CommandTemp = {
      node,
      id,
      name: decodeWordNode(nameNode, source),
      assignments,
      arguments: argumentNodes.map((child) => ({
        word: decodeWordNode(child, source, false, null, true),
        synthetic: false,
      })),
      directNativeRedirectIds: [],
      span: nodeSpan(node),
    };
    command.span = normalizedCommandSpan(command, state);
    state.commands.push(command);
    state.commandByNativeId.set(node.id, command);
  });
  let program: ParsedShellUnit;
  try {
    const heredocNodes: Node[] = [];
    collectHeredocNodes(root, heredocNodes);
    heredocNodes.sort((a, b) => {
      const aSpan = nodeSpan(a);
      const bSpan = nodeSpan(b);
      return aSpan.start - bSpan.start || aSpan.end - bSpan.end;
    });
    if (heredocNodes.length > 1)
      throwInvalid("multiple", nodeSpan(heredocNodes[1]!));
    for (const heredocNode of heredocNodes) {
      const ownerNode = heredocOwnerNode(heredocNode);
      const ownerNativeId = ownerNode?.id ?? null;
      const wrapper = redirectedStatementAncestor(heredocNode);
      let headerStart =
        wrapper === null
          ? nodeSpan(heredocNode).start
          : nodeSpan(wrapper).start;
      let ancestor = heredocNode.parent;
      while (ancestor !== null) {
        if (ancestor.type === "ERROR") {
          headerStart = ancestor.startIndex;
          break;
        }
        ancestor = ancestor.parent;
      }
      const publish = ownerNode !== null && state.commandIds.has(ownerNode.id);
      ensureRedirect(heredocNode, ownerNativeId, headerStart, state, publish);
      if (ownerNode === null)
        throwInvalid("missing_owner", nodeSpan(heredocNode));
    }
    program = normalizeUnit(root, state);
    if (program.kind !== "program")
      throw new Error("program normalization invariant");
    const heredocs = state.redirects
      .filter((redirect) => redirect.kind === "heredoc")
      .sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
    if (heredocs.length > 1) throwInvalid("multiple", heredocs[1]!.span);
    const redirectResult = redirectRecords(state);
    const redirectIdByNativeId = redirectResult.idByNativeId;
    const redirectsByOwner = new Map<number, ParsedShellRedirect[]>();
    for (const redirect of redirectResult.redirects) {
      const owned = redirectsByOwner.get(redirect.ownerId) ?? [];
      owned.push(redirect);
      redirectsByOwner.set(redirect.ownerId, owned);
    }
    const invocations = discoverInvocations(state, redirectsByOwner);
    const commands = state.commands.map((command) => {
      const redirectIds = (redirectsByOwner.get(command.id) ?? []).map(
        (redirect) => redirect.id,
      );
      const wrapperArgs = command.arguments;
      return {
        id: command.id,
        span: command.span,
        name: command.name,
        assignments: command.assignments,
        arguments: wrapperArgs,
        redirectIds,
      } satisfies ParsedShellCommand;
    });
    const mappedProgram = mapRedirectedUnitIds(program, redirectIdByNativeId);
    const result: ParseResult = {
      ok: true,
      document: {
        source,
        program: mappedProgram,
        commands,
        redirects: redirectResult.redirects,
        embeddedInvocations: invocations.invocations,
        diagnostics: sortDiagnostics(state.diagnostics),
      },
    };
    return { result, childSources: invocations.childSources };
  } catch (error: unknown) {
    if (error instanceof TypedNormalizationFailure)
      return { result: error.result, childSources: [] };
    throw error;
  }
}

function mapRedirectedUnitIds(
  unit: ParsedShellUnit,
  redirectIds: Map<number, number>,
): Extract<ParsedShellUnit, { kind: "program" }> {
  const repaired = foldParsedShellUnit<ParsedShellUnit>(
    unit,
    (value, children) => {
      if (value.kind === "redirected_statement")
        return {
          ...value,
          body: children[0]!,
          redirectIds: value.redirectIds.map((nativeId) => {
            const id = redirectIds.get(nativeId);
            if (id === undefined)
              throw new Error("redirected unit id invariant");
            return id;
          }),
        };
      if (
        value.kind === "program" ||
        value.kind === "list" ||
        value.kind === "pipeline"
      )
        return { ...value, children };
      return value;
    },
  );
  if (repaired.kind !== "program") throw new Error("program repair invariant");
  return repaired;
}

function precedingHeredocOwner(
  children: readonly Node[],
  before: number,
): Node | null {
  for (let index = before - 1; index >= 0; index--) {
    const child = children[index]!;
    if (child.type === "command" || child.type === "redirected_statement")
      return child;
  }
  return null;
}

function incompleteNativeHeredoc(
  node: Node,
  errorsWithPrecedingOwner: ReadonlySet<number>,
): Node | null {
  if (node.type === "heredoc_body") return null;
  if (node.type === "heredoc_start") {
    const parent = node.parent;
    if (parent?.type === "heredoc_redirect")
      return incompleteNativeHeredoc(parent, errorsWithPrecedingOwner);
  }
  if (node.type === "heredoc_redirect") {
    const operator = redirectOperator(node);
    let start: Node | null = null;
    let body: Node | null = null;
    let end: Node | null = null;
    for (const child of node.namedChildren) {
      if (child.type === "heredoc_start") start = child;
      else if (child.type === "heredoc_body") body = child;
      else if (child.type === "heredoc_end") end = child;
    }
    if (body !== null && end !== null) return null;
    if (
      start !== null &&
      (operator.type === "<<" || operator.type === "<<-") &&
      operator.endIndex <= start.startIndex &&
      heredocOwnerNode(node) !== null
    )
      return node;
    return null;
  }
  if (!node.isError) return null;
  const children = node.children;
  let startIndex = -1;
  let hasEnd = false;
  for (let index = 0; index < children.length; index++) {
    const child = children[index]!;
    if (child.type === "heredoc_start") startIndex = index;
    else if (child.type === "heredoc_end") hasEnd = true;
  }
  if (startIndex <= 0 || hasEnd) return null;
  for (const child of walkNodes(node, (current) =>
    current.id === node.id ? children : shellSyntaxChildren(current),
  )) {
    if (
      child.id !== node.id &&
      child.type !== "heredoc_body" &&
      (child.isError || child.isMissing)
    )
      return null;
  }
  const operator = children[startIndex - 1]!;
  if (operator.type !== "<<" && operator.type !== "<<-") return null;
  if (operator.startIndex === operator.endIndex) return null;
  return precedingHeredocOwner(children, startIndex - 1) !== null ||
    errorsWithPrecedingOwner.has(node.id)
    ? node
    : null;
}

function isWordBoundaryToken(node: Node): boolean {
  switch (node.type) {
    case "command_name":
    case "variable_assignment":
    case "heredoc_start":
    case "word":
    case "number":
    case "string":
    case "raw_string":
    case "ansi_c_string":
    case "translated_string":
    case "concatenation":
    case "expansion":
    case "simple_expansion":
    case "command_substitution":
    case "process_substitution":
    case "arithmetic_expansion":
      return true;
    default:
      return false;
  }
}

function findWordBoundaryDisagreement(
  root: Node,
  source: string,
): ParsedShellSpan | null {
  // Bash blanks are space, tab and newline. CyDo also treats CRLF as newline.
  // The grammar's extras and scanner's iswspace can drop other whitespace.
  const droppedSpace = /\\[ \t]|[\v\f]|\r(?!\n)|[^\x00-\x7f\P{White_Space}]/u;
  const gapHasDroppedSpace = (start: number, end: number): boolean => {
    if (start >= end) return false;
    const gap = source.slice(start, source[end] === "\n" ? end + 1 : end);
    return droppedSpace.test(gap);
  };
  let end = 0;
  for (const node of walkNodes(root, shellSyntaxChildren)) {
    if (node.type !== "heredoc_body" && node.childCount !== 0) continue;
    if (gapHasDroppedSpace(end, node.startIndex))
      return sourceSpan(source, end, node.startIndex);
    end = node.endIndex;
  }
  if (gapHasDroppedSpace(end, source.length))
    return sourceSpan(source, end, source.length);

  type LexicalNode = { node: Node; shellWords: boolean };
  type Edges = { first: Node; last: Node };
  const isSubstitution = (node: Node): boolean =>
    node.type === "command_substitution" ||
    node.type === "process_substitution";
  let disagreement: ParsedShellSpan | null = null;
  reduceTree<LexicalNode, Edges>(
    { node: root, shellWords: true },
    ({ node, shellWords }) => {
      // Quoting and expression syntax compose a word. A substitution starts
      // its own shell word context inside that word.
      const children = shellSyntaxChildren(node);
      const childShellWords =
        isSubstitution(node) || (shellWords && !isWordBoundaryToken(node));
      // Arithmetic compounds and subscripts contain expressions. A C-style
      // for loop switches back to shell syntax only in its body.
      const expression =
        node.type === "subscript" ||
        (node.type === "compound_statement" && children[0]?.type === "((");
      const loopBody =
        node.type === "c_style_for_statement"
          ? node.childForFieldName("body")
          : null;
      return children.map((child) => ({
        node: child,
        shellWords:
          childShellWords &&
          !expression &&
          (loopBody === null || child.id === loopBody.id),
      }));
    },
    ({ node, shellWords }, children) => {
      if (children.length === 0) return { first: node, last: node };
      const word = isWordBoundaryToken(node);
      const substitution = isSubstitution(node);

      if (disagreement === null && (substitution || (shellWords && !word))) {
        const destinationEnd =
          node.type === "file_redirect"
            ? nativeFileRedirectLayout(node, source).logicalEnd
            : -1;
        // The opening and closing tokens delimit the substitution body.
        const firstJoin = substitution ? 2 : 1;
        const end = children.length - (substitution ? 1 : 0);
        for (let index = firstJoin; index < end; index++) {
          const left = children[index - 1]!.last;
          const right = children[index]!.first;
          if (
            right.startIndex >= destinationEnd &&
            isWordBoundaryToken(left) &&
            (left.endIndex === right.startIndex ||
              isWordContinuationGap(source, left.endIndex, right.startIndex)) &&
            (isWordBoundaryToken(right) ||
              (!/[ \t\n|&;()<>]/.test(source[right.startIndex]!) &&
                !source.startsWith("\r\n", right.startIndex)))
          ) {
            disagreement = nodeSpan(right);
            break;
          }
        }
      }
      return word
        ? { first: node, last: node }
        : { first: children[0]!.first, last: children.at(-1)!.last };
    },
  );
  return disagreement;
}

function scanSyntax(
  root: Node,
  source: string,
  redirects: readonly NativeRedirect[],
): ParseResult | null {
  const unsupported = unsupportedRedirectFailure(source, root, redirects);
  if (unsupported !== null) return unsupported;
  const errors: Node[] = [];
  const errorsWithPrecedingOwner = new Set<number>();
  for (const node of walkNodes(root, (parent) => {
    const children = shellSyntaxChildren(parent);
    if (!parent.hasError) return children;

    let hasPrecedingOwner = false;
    for (const child of children) {
      if (hasPrecedingOwner && child.isError)
        errorsWithPrecedingOwner.add(child.id);
      if (child.type === "command" || child.type === "redirected_statement")
        hasPrecedingOwner = true;
    }
    return children;
  })) {
    if (node.isError || node.isMissing) errors.push(node);
  }
  if (errors.length > 0) {
    let heredoc: Node | null = null;
    for (const error of errors) {
      heredoc = incompleteNativeHeredoc(error, errorsWithPrecedingOwner);
      if (heredoc !== null) break;
    }
    if (heredoc !== null)
      return {
        ok: false,
        reason: "invalid_heredoc",
        issue: "incomplete",
        span:
          heredoc.type === "heredoc_start"
            ? nodeSpan(
                errors.find(
                  (error) =>
                    error.startIndex <= heredoc.startIndex &&
                    error.endIndex >= heredoc.endIndex,
                ) ?? heredoc,
              )
            : nodeSpan(heredoc),
      };
  }
  if (errors.length > 0) {
    errors.sort(
      (a, b) => a.startIndex - b.startIndex || a.endIndex - b.endIndex,
    );
    const first = errors[0]!;
    return {
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: first.isMissing ? "missing_node" : "error_node",
      span: nodeSpan(first),
    };
  }
  const boundary = findWordBoundaryDisagreement(root, source);
  return boundary === null
    ? null
    : {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "word_boundary",
        span: boundary,
      };
}

async function parseSource(source: string): Promise<ParseResult> {
  try {
    await getInitialization();
  } catch {
    return { ok: false, reason: "parser_initialization_failed" };
  }
  const parser = initializedParser;
  if (parser === undefined) throw new Error("initialized parser invariant");
  let tree: Tree | null = null;
  let normalized: {
    result: ParseResult;
    childSources: Array<{ invocationIndex: number; source: string }>;
  };
  try {
    tree = parser.parse(source);
    if (tree === null)
      return {
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "no_tree",
        span: sourceSpan(source, 0, 0),
      };
    const root = tree.rootNode;
    const redirects = collectRedirectNodes(root);
    const syntaxFailure = scanSyntax(root, source, redirects);
    if (syntaxFailure !== null) return syntaxFailure;
    normalized = finalizeDocument(source, root, redirects);
  } finally {
    if (tree !== null) tree.delete();
  }
  if (!normalized.result.ok) return normalized.result;
  if (normalized.childSources.length === 0) return normalized.result;
  const children = await Promise.all(
    normalized.childSources.map(
      async ({ invocationIndex, source: childSource }) => ({
        invocationIndex,
        result: await loadParsedShellDocument(childSource),
      }),
    ),
  );
  const invocations = [...normalized.result.document.embeddedInvocations];
  const diagnostics = [...normalized.result.document.diagnostics];
  for (const child of children) {
    const invocation = invocations[child.invocationIndex];
    if (invocation === undefined)
      throw new Error("child invocation index invariant");
    if (child.result.ok) {
      invocations[child.invocationIndex] = {
        ...invocation,
        child: child.result.document,
      };
    } else if (
      child.result.reason === "unsafe_shell_syntax" ||
      child.result.reason === "invalid_heredoc"
    ) {
      diagnostics.push({
        kind: "child_parse_failed",
        span: invocation.payload.rawSpan,
        reason: child.result.reason,
      });
    }
  }
  const sortedDiagnostics = sortDiagnostics(diagnostics);
  return {
    ok: true,
    document: {
      ...normalized.result.document,
      embeddedInvocations: invocations,
      diagnostics: sortedDiagnostics,
    },
  };
}
