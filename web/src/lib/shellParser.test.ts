import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import type { TreeSitterAssets } from "./treeSitterRuntime";
import { afterEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "../test-support/waitFor";
import { shellParserCorpus } from "./fixtures/shellParserCorpus";
import type * as ShellParserTypes from "./shellParser";
import type * as TreeSitterTypes from "web-tree-sitter";
import type {
  ParseResult,
  ParsedShellDocument,
  ParsedShellEmbeddedInvocation,
} from "./shellParser";

type ParsedShellWord = ParsedShellDocument["commands"][number]["name"];
type ParsedShellProjection = Extract<
  ParsedShellWord,
  { kind: "literal" }
>["projection"];
type ParsedShellHeaderUnit = NonNullable<
  Extract<
    ParsedShellDocument["redirects"][number],
    { kind: "heredoc" }
  >["header"]["continuation"]
>["unit"];
type ParsedShellUnit =
  | ParsedShellDocument["program"]
  | ParsedShellDocument["program"]["children"][number];
import type {
  ShellParserCorpusArgument,
  ShellParserCorpusCase,
  ShellParserCorpusCommand,
  ShellParserCorpusDiagnostic,
  ShellParserCorpusDocument,
  ShellParserCorpusInvocation,
  ShellParserCorpusProjection,
  ShellParserCorpusRedirect,
  ShellParserCorpusSpan,
  ShellParserCorpusUnit,
  ShellParserCorpusWord,
} from "./fixtures/shellParserCorpus";

type ShellParserModule = typeof ShellParserTypes;
type TreeSitterModule = typeof TreeSitterTypes;

type ProcessLike = {
  getBuiltinModule(name: string): unknown;
  on(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
  off(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
};

const processLike = (globalThis as typeof globalThis & { process: ProcessLike })
  .process;

let realLanguage: unknown;

async function freshShellParser(): Promise<{
  service: ShellParserModule;
  treeSitter: TreeSitterModule;
  assetRuntime: typeof import("./treeSitterRuntime");
}> {
  vi.doUnmock("web-tree-sitter");
  vi.resetModules();
  const [service, treeSitter, assetRuntime] = await Promise.all([
    import("./shellParser"),
    import("web-tree-sitter"),
    import("./treeSitterRuntime"),
  ]);
  return { service, treeSitter, assetRuntime };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: unknown): void;
} {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

function expectSpan(
  source: string,
  actual: Readonly<{ start: number; end: number }>,
  expected: ShellParserCorpusSpan,
): void {
  expect(actual).toEqual({ start: expected.start, end: expected.end });
  expect(source.slice(expected.start, expected.end)).toBe(expected.text);
}

function expectProjection(
  source: string,
  actual: ParsedShellProjection,
  expected: ShellParserCorpusProjection,
): void {
  expectSpan(source, actual.span, expected.span);
  expect(actual.points).toEqual(expected.points);
}

function expectWord(
  source: string,
  actual: ParsedShellWord,
  expected: ShellParserCorpusWord,
): void {
  expect(actual.kind).toBe(expected.kind);
  expect(actual.syntax).toBe(expected.syntax);
  expectSpan(source, actual.rawSpan, expected.rawSpan);

  if (expected.kind === "literal") {
    if (actual.kind !== "literal") throw new Error("expected a literal word");
    expect(actual.value).toBe(expected.value);
    if (expected.projection === undefined) {
      throw new Error("literal fixture word is missing its projection");
    }
    expectProjection(source, actual.projection, expected.projection);
    return;
  }

  if (actual.kind !== "nonliteral")
    throw new Error("expected a nonliteral word");
  expect(actual.reason).toBe(expected.reason);
  expect(actual.nodeTypes).toEqual(expected.nodeTypes);
}

function expectArgument(
  source: string,
  actual: { word: ParsedShellWord; synthetic: boolean },
  expected: ShellParserCorpusArgument,
): void {
  expect(actual.synthetic).toBe(expected.synthetic);
  expectWord(source, actual.word, expected.word);
}

function expectOperator(
  source: string,
  actual: Readonly<{
    kind: string;
    text: string;
    span: Readonly<{ start: number; end: number }>;
  }>,
  expected: { kind: string; text: string; span: ShellParserCorpusSpan },
): void {
  expect(actual.kind).toBe(expected.kind);
  expect(actual.text).toBe(expected.text);
  expectSpan(source, actual.span, expected.span);
}

function expectBoundary(
  source: string,
  actual: Readonly<{
    kind: string;
    text: string;
    span: Readonly<{ start: number; end: number }>;
  }>,
  expected: { kind: string; text: string; span: ShellParserCorpusSpan },
): void {
  expect(actual.kind).toBe(expected.kind);
  expect(actual.text).toBe(expected.text);
  expectSpan(source, actual.span, expected.span);
}

function expectHeaderUnit(
  source: string,
  actual: ParsedShellHeaderUnit,
  expected: ShellParserCorpusUnit,
): void {
  expect(actual.kind).toBe(expected.kind);
  expectSpan(source, actual.span, expected.span);

  if (expected.kind === "command") {
    if (actual.kind !== "command") throw new Error("expected a header command");
    if (expected.name === undefined || expected.arguments === undefined) {
      throw new Error("header command fixture is incomplete");
    }
    expectWord(source, actual.name, expected.name);
    expect(actual.arguments).toHaveLength(expected.arguments.length);
    for (let i = 0; i < expected.arguments.length; i++) {
      expectArgument(source, actual.arguments[i]!, expected.arguments[i]!);
    }
    return;
  }

  if (expected.kind === "list" || expected.kind === "pipeline") {
    if (actual.kind !== expected.kind)
      throw new Error("expected a header compound unit");
    if (expected.children === undefined || expected.operators === undefined) {
      throw new Error("header compound fixture is incomplete");
    }
    expect(actual.children).toHaveLength(expected.children.length);
    for (let i = 0; i < expected.children.length; i++) {
      expectHeaderUnit(source, actual.children[i]!, expected.children[i]!);
    }
    expect(actual.operators).toHaveLength(expected.operators.length);
    for (let i = 0; i < expected.operators.length; i++) {
      expectOperator(source, actual.operators[i]!, expected.operators[i]!);
    }
    return;
  }

  throw new Error("header fixture contains an unsupported unit kind");
}

function expectUnit(
  source: string,
  actual: ParsedShellUnit,
  expected: ShellParserCorpusUnit,
): void {
  expect(actual.kind).toBe(expected.kind);
  expectSpan(source, actual.span, expected.span);

  if (expected.kind === "program") {
    if (actual.kind !== "program") throw new Error("expected a program unit");
    if (expected.children === undefined || expected.boundaries === undefined) {
      throw new Error("program fixture is incomplete");
    }
    expect(actual.children).toHaveLength(expected.children.length);
    for (let i = 0; i < expected.children.length; i++) {
      expectUnit(source, actual.children[i]!, expected.children[i]!);
    }
    expect(actual.boundaries).toHaveLength(expected.boundaries.length);
    for (let i = 0; i < expected.boundaries.length; i++) {
      expectBoundary(source, actual.boundaries[i]!, expected.boundaries[i]!);
    }
    return;
  }

  if (expected.kind === "command") {
    if (actual.kind !== "command") throw new Error("expected a command unit");
    expect(actual.commandId).toBe(expected.commandId);
    return;
  }

  if (expected.kind === "redirected_statement") {
    if (actual.kind !== "redirected_statement") {
      throw new Error("expected a redirected statement unit");
    }
    if (expected.body === undefined || expected.redirectIds === undefined) {
      throw new Error("redirected statement fixture is incomplete");
    }
    expectUnit(source, actual.body, expected.body);
    expect(actual.redirectIds).toEqual(expected.redirectIds);
    return;
  }

  if (expected.kind === "list" || expected.kind === "pipeline") {
    if (actual.kind !== expected.kind)
      throw new Error("expected a compound unit");
    if (expected.children === undefined || expected.operators === undefined) {
      throw new Error("compound fixture is incomplete");
    }
    expect(actual.children).toHaveLength(expected.children.length);
    for (let i = 0; i < expected.children.length; i++) {
      expectUnit(source, actual.children[i]!, expected.children[i]!);
    }
    expect(actual.operators).toHaveLength(expected.operators.length);
    for (let i = 0; i < expected.operators.length; i++) {
      expectOperator(source, actual.operators[i]!, expected.operators[i]!);
    }
    return;
  }

  if (actual.kind !== "opaque") throw new Error("expected an opaque unit");
  expect(actual.nodeType).toBe(expected.nodeType);
  expect(actual.reason).toBe(expected.reason);
}

function expectCommand(
  source: string,
  actual: ParsedShellDocument["commands"][number],
  expected: ShellParserCorpusCommand,
): void {
  expect(actual.id).toBe(expected.id);
  expectSpan(source, actual.span, expected.span);
  expectWord(source, actual.name, expected.name);
  expect(actual.assignments).toHaveLength(expected.assignments.length);
  for (let i = 0; i < expected.assignments.length; i++) {
    const actualAssignment = actual.assignments[i]!;
    const expectedAssignment = expected.assignments[i]!;
    expectSpan(source, actualAssignment.span, expectedAssignment.span);
    expect(actualAssignment.name).toBe(expectedAssignment.name);
    expectSpan(source, actualAssignment.nameSpan, expectedAssignment.nameSpan);
    if (expectedAssignment.value === null) {
      expect(actualAssignment.value).toBeNull();
    } else {
      expect(actualAssignment.value).not.toBeNull();
      expectWord(source, actualAssignment.value!, expectedAssignment.value);
    }
  }
  expect(actual.arguments).toHaveLength(expected.arguments.length);
  for (let i = 0; i < expected.arguments.length; i++) {
    expectArgument(source, actual.arguments[i]!, expected.arguments[i]!);
  }
  expect(actual.redirectIds).toEqual(expected.redirectIds);
}

function expectRedirect(
  source: string,
  actual: ParsedShellDocument["redirects"][number],
  expected: ShellParserCorpusRedirect,
): void {
  expect(actual.kind).toBe(expected.kind);
  expect(actual.id).toBe(expected.id);
  expect(actual.ownerId).toBe(expected.ownerId);
  expectSpan(source, actual.span, expected.span);

  if (actual.kind === "file") {
    expect(expected.operator).toBeDefined();
    expect(actual.operator).toBe(expected.operator);
    expectSpan(source, actual.operatorSpan, expected.operatorSpan);
    const expectedDescriptor = expected.descriptor ?? null;
    expect(actual.descriptor).not.toBeUndefined();
    if (expectedDescriptor === null) {
      expect(actual.descriptor).toBeNull();
    } else {
      expect(actual.descriptor).not.toBeNull();
      const actualDescriptor = actual.descriptor!;
      expect(actualDescriptor.kind).toBe(expectedDescriptor.kind);
      expect(actualDescriptor.value).toBe(expectedDescriptor.value);
      expectSpan(source, actualDescriptor.rawSpan, expectedDescriptor.rawSpan);
    }
    if (expected.destination === undefined)
      throw new Error("file fixture is incomplete");
    if (expected.destination === null) {
      expect(actual.destination).toBeNull();
    } else {
      expect(actual.destination).not.toBeNull();
      expectWord(source, actual.destination!, expected.destination);
    }
    return;
  }

  expect(actual.operator).toBe(expected.operator);
  expectSpan(source, actual.operatorSpan, expected.operatorSpan);
  expect(actual.descriptor).toEqual(expected.descriptor ?? null);

  if (actual.kind === "herestring") {
    if (expected.value === undefined)
      throw new Error("herestring fixture is incomplete");
    expectWord(source, actual.value, expected.value);
    return;
  }

  if (
    expected.headerSpan === undefined ||
    expected.headerLineBreakSpan === undefined ||
    expected.delimiter === undefined ||
    expected.rawBodySpan === undefined ||
    expected.contentSpan === undefined ||
    expected.terminatorSpan === undefined ||
    expected.nestedRedirectIds === undefined ||
    expected.header === undefined
  ) {
    throw new Error("heredoc fixture is incomplete");
  }
  expectSpan(source, actual.headerSpan, expected.headerSpan);
  expectSpan(source, actual.headerLineBreakSpan, expected.headerLineBreakSpan);
  expect(actual.delimiter.value).toBe(expected.delimiter.value);
  expect(actual.delimiter.quoted).toBe(expected.delimiter.quoted);
  expectSpan(source, actual.delimiter.rawSpan, expected.delimiter.rawSpan);
  expectSpan(source, actual.rawBodySpan, expected.rawBodySpan);
  expectSpan(source, actual.contentSpan, expected.contentSpan);
  expectSpan(source, actual.terminatorSpan, expected.terminatorSpan);
  expect(actual.nestedRedirectIds).toEqual(expected.nestedRedirectIds);
  expect(actual.header.arguments).toHaveLength(
    expected.header.arguments.length,
  );
  for (let i = 0; i < expected.header.arguments.length; i++) {
    expectArgument(
      source,
      actual.header.arguments[i]!,
      expected.header.arguments[i]!,
    );
  }

  if (expected.header.continuation === null) {
    expect(actual.header.continuation).toBeNull();
  } else if (expected.header.continuationOperator !== undefined) {
    expect(actual.header.continuation?.kind).toBe("right");
    if (actual.header.continuation?.kind !== "right") return;
    expectOperator(
      source,
      actual.header.continuation.operator,
      expected.header.continuationOperator,
    );
    expectHeaderUnit(
      source,
      actual.header.continuation.unit,
      expected.header.continuation,
    );
  } else {
    expect(actual.header.continuation?.kind).toBe("pipeline");
    if (actual.header.continuation?.kind !== "pipeline") return;
    expectHeaderUnit(
      source,
      actual.header.continuation.unit,
      expected.header.continuation,
    );
  }
}

function expectInvocation(
  source: string,
  actual: ParsedShellDocument["embeddedInvocations"][number],
  expected: ShellParserCorpusInvocation,
): void {
  expect(actual.kind).toBe(expected.kind);
  expect(actual.id).toBe(expected.id);
  expect(actual.commandId).toBe(expected.commandId);
  expect(actual.prefix).toEqual(expected.prefix);
  expect(actual.interpreter).toEqual(expected.interpreter);
  expect(actual.optionArgumentIndices).toEqual(expected.optionArgumentIndices);
  expect(actual.payload.text).toBe(expected.payload.text);
  expectSpan(source, actual.payload.rawSpan, expected.payload.rawSpan);
  expectSpan(source, actual.payload.contentSpan, expected.payload.contentSpan);
  expectProjection(
    source,
    actual.payload.projection,
    expected.payload.projection,
  );

  if (expected.flagArgumentIndex !== undefined) {
    expect(actual.kind).toBe("inline");
    if (actual.kind !== "inline") return;
    expect(actual.flagArgumentIndex).toBe(expected.flagArgumentIndex);
  }
  if (expected.payloadArgumentIndex !== undefined) {
    expect(actual.kind).toBe("inline");
    if (actual.kind !== "inline") return;
    expect(actual.payloadArgumentIndex).toBe(expected.payloadArgumentIndex);
  }
  if (expected.heredocRedirectId !== undefined) {
    expect(actual.kind).toBe("heredoc");
    if (actual.kind !== "heredoc") return;
    expect(actual.heredocRedirectId).toBe(expected.heredocRedirectId);
    expect(actual.stdinArgumentIndex).toBe(expected.stdinArgumentIndex);
  }
  if (expected.child !== undefined) {
    if (expected.child === null) {
      expect(actual.child).toBeNull();
    } else {
      expect(actual.child).not.toBeNull();
      expectDocument(actual.child!, expected.child);
    }
  }
}

function expectDiagnostic(
  source: string,
  actual: ParsedShellDocument["diagnostics"][number],
  expected: ShellParserCorpusDiagnostic,
): void {
  expect(actual.kind).toBe(expected.kind);
  expectSpan(source, actual.span, expected.span);
  if (expected.operator !== undefined) {
    expect(actual.kind).toBe("unsupported_control");
    if (actual.kind === "unsupported_control")
      expect(actual.operator).toBe(expected.operator);
  }
  if (expected.nodeType !== undefined) {
    expect(actual.kind).toBe("unsupported_construct");
    if (actual.kind === "unsupported_construct")
      expect(actual.nodeType).toBe(expected.nodeType);
  }
  if (expected.issue !== undefined) {
    if (!("issue" in actual))
      throw new Error("diagnostic fixture expects an issue");
    expect(actual.issue).toBe(expected.issue);
  }
}

function expectDocument(
  actual: ParsedShellDocument,
  expected: ShellParserCorpusDocument,
): void {
  expect(actual.source).toBe(expected.source);
  expectUnit(actual.source, actual.program, expected.program);
  expect(actual.commands).toHaveLength(expected.commands.length);
  for (let i = 0; i < expected.commands.length; i++) {
    expectCommand(actual.source, actual.commands[i]!, expected.commands[i]!);
  }
  expect(actual.redirects).toHaveLength(expected.redirects.length);
  for (let i = 0; i < expected.redirects.length; i++) {
    expectRedirect(actual.source, actual.redirects[i]!, expected.redirects[i]!);
  }
  expect(actual.embeddedInvocations).toHaveLength(
    expected.embeddedInvocations.length,
  );
  for (let i = 0; i < expected.embeddedInvocations.length; i++) {
    expectInvocation(
      actual.source,
      actual.embeddedInvocations[i]!,
      expected.embeddedInvocations[i]!,
    );
  }
  expect(actual.diagnostics).toHaveLength(expected.diagnostics.length);
  for (let i = 0; i < expected.diagnostics.length; i++) {
    expectDiagnostic(
      actual.source,
      actual.diagnostics[i]!,
      expected.diagnostics[i]!,
    );
  }
}

function expectCorpusCase(
  result: ParseResult,
  fixture: ShellParserCorpusCase,
): void {
  if (!fixture.expected.ok) {
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe(fixture.expected.reason);
    if (result.reason === "parser_initialization_failed") {
      throw new Error("corpus fixture cannot expect initialization failure");
    }
    expect(result.issue).toBe(fixture.expected.issue);
    expectSpan(fixture.source, result.span, fixture.expected.span);
    return;
  }

  expect(result.ok).toBe(true);
  if (!result.ok) return;
  expectDocument(result.document, fixture.expected.document);
}

function expectPlainRepositoryData(
  value: unknown,
  seen = new Set<unknown>(),
): void {
  if (value === null || typeof value !== "object") return;
  if (seen.has(value)) return;
  seen.add(value);
  if (Array.isArray(value)) {
    for (const item of value) expectPlainRepositoryData(item, seen);
    return;
  }
  expect(Object.getPrototypeOf(value)).toBe(Object.prototype);
  for (const child of Object.values(value))
    expectPlainRepositoryData(child, seen);
}

function configureUrlService({
  assetRuntime,
  treeSitter,
}: Awaited<ReturnType<typeof freshShellParser>>) {
  const init = vi.spyOn(treeSitter.Parser, "init").mockResolvedValue(undefined);
  const languageLoad = vi
    .spyOn(treeSitter.Language, "load")
    .mockResolvedValue(realLanguage as never);
  const assets: TreeSitterAssets = {
    kind: "urls",
    runtime: "/assets/web-tree-sitter.wasm",
    languages: {
      bash: "/assets/tree-sitter-bash.wasm",
      javascript: "/assets/tree-sitter-javascript.wasm",
    },
  };
  assetRuntime.configureTreeSitterAssets(assets);
  return { init, languageLoad };
}

async function freshRealByteService(): Promise<ShellParserModule> {
  const { service, assetRuntime } = await freshShellParser();
  assetRuntime.configureTreeSitterAssets(installedTreeSitterBytes);
  return service;
}

const parsedShellDocumentInvariant = "parsed shell document invariant:";

async function loadRealDocument(
  service: ShellParserModule,
  source: string,
): Promise<ParsedShellDocument> {
  const result = await service.loadParsedShellDocument(source);
  expect(result.ok, source).toBe(true);
  if (!result.ok)
    throw new Error(
      `expected normalized document: ${source}: ${result.reason}`,
    );
  return result.document;
}

function expectParsedShellDocumentInvariant(
  service: ShellParserModule,
  document: ParsedShellDocument,
  label: string,
): void {
  expect(() => {
    service.assertValidParsedShellDocument(document);
  }, label).toThrow(parsedShellDocumentInvariant);
}

function opaqueUnits(
  unit: ParsedShellUnit,
): Extract<ParsedShellUnit, { kind: "opaque" }>[] {
  if (unit.kind === "opaque") return [unit];
  if (unit.kind === "redirected_statement") return opaqueUnits(unit.body);
  if (unit.kind === "command") return [];
  return unit.children.flatMap(opaqueUnits);
}

describe.sequential("shell parser service", () => {
  it("normalizes all 4,000 commands in a long && chain", async () => {
    const service = await freshRealByteService();
    const source = Array(4_000).fill("true").join(" && ");
    const document = await loadRealDocument(service, source);

    expect(
      document.commands.map(({ name }) => ({
        value: name.kind === "literal" ? name.value : null,
        start: name.rawSpan.start,
        end: name.rawSpan.end,
      })),
    ).toEqual(
      Array.from({ length: 4_000 }, (_, index) => ({
        value: "true",
        start: index * 8,
        end: index * 8 + 4,
      })),
    );
  });

  it("keeps each redirect with its command in a long && chain", async () => {
    const service = await freshRealByteService();
    const destinations = Array.from(
      { length: 4_000 },
      (_, index) => `out-${index}`,
    );
    const source = destinations
      .map((destination) => `true >${destination}`)
      .join(" && ");
    const { commands, redirects } = await loadRealDocument(service, source);

    expect(commands).toHaveLength(destinations.length);
    expect(redirects).toHaveLength(destinations.length);
    for (const [index, command] of commands.entries()) {
      expect(command.name).toMatchObject({ kind: "literal", value: "true" });
      expect(command.redirectIds).toHaveLength(1);
      expect(
        redirects[command.redirectIds[0]!],
        `command ${index}`,
      ).toMatchObject({
        kind: "file",
        ownerId: command.id,
        operator: ">",
        destination: { kind: "literal", value: destinations[index] },
      });
    }
  });

  describe.each([
    ["LF", "\n"],
    ["CRLF", "\r\n"],
  ])("%s word continuations", (_lineEnding, newline) => {
    it.each([
      ["ASCII", "y"],
      ["Unicode", "漢字"],
      ["U+200B", "\u200by"],
      ["U+FEFF", "\ufeffy"],
    ])(
      "rejects a split quoted argument before %s",
      async (_wordKind, suffix) => {
        const service = await freshRealByteService();
        const prefix = 'cat "x"\\' + newline;
        // The continuation is elided, leaving the single argument x + suffix.
        await expect(
          service.loadParsedShellDocument(prefix + suffix),
        ).resolves.toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
          issue: "word_boundary",
          span: { start: prefix.length, end: prefix.length + suffix.length },
        });
      },
    );
  });

  it.each([
    "cat foo\\\n#bar",
    'cat "x"\\\n#bar',
    "cat a\\\n#",
    "cat a\\\n#bar file",
    "cat a\\\n#bar\n",
    'cat "x"\\\r\n#bar',
    'cat >"x"\\\n#bar',
    'cat <<<"x"\\\n#bar',
    'X="x"\\\n#bar\necho c',
    'cat $(echo "a"\\\n#b\n)',
    "echo $(cat a\\\n#bar\n)",
    "echo `cat a\\\n#bar\n`",
    'echo "$(cat a\\\n#bar\n)"',
    'echo "`cat a\\\n#bar\n`"',
  ])(
    "rejects a comment marker joined to a shell word in %j",
    async (source) => {
      const service = await freshRealByteService();
      // Bash treats the marker as part of the word when the continuation
      // is elided. The parser must reject a syntax tree that drops it.
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "word_boundary",
      });
    },
  );

  it.each(["((1+2))", "for ((i=1+2; i<3; i++)); do cat a; done"])(
    "preserves arithmetic expressions in %j",
    async (source) => {
      const service = await freshRealByteService();
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: true,
      });
    },
  );

  it("accepts a separated comment after a line continuation", async () => {
    const service = await freshRealByteService();
    const document = await loadRealDocument(service, "cat a \\\n# comment\n");
    expect(document.commands).toHaveLength(1);
    expect(document.commands[0]?.arguments).toMatchObject([
      { word: { kind: "literal", value: "a" } },
    ]);
  });

  it("accepts operators adjacent to words across continuations", async () => {
    const service = await freshRealByteService();
    const document = await loadRealDocument(
      service,
      "cat a\\\n|head -n 1\\\n&&cat b",
    );
    expect(document.program.children).toMatchObject([
      {
        kind: "list",
        operators: [{ text: "&&" }],
        children: [
          {
            kind: "pipeline",
            operators: [{ text: "|" }],
            children: [{ kind: "command" }, { kind: "command" }],
          },
          { kind: "command" },
        ],
      },
    ]);
  });

  it.each([
    ["assignment and command name", 'X="x"\\\n漢字 arg'],
    ["redirected argument", 'cat >out "x"\\\n漢字'],
    ["here-string", 'cat <<<"x"\\\n漢字'],
    ["heredoc delimiter", "cat <<'EOF'\\\n漢字\nbody\nEOF\n"],
    ["assignment with an ideographic space", 'X="x"　cat foo'],
    ["redirect suffix with an ideographic space", 'cat >out "x"　y'],
    ["here-string with an ideographic space", 'cat <<<"x"　y'],
    [
      "heredoc delimiter with an ideographic space",
      "cat >out <<EOF　suffix\nbody\nEOF\n",
    ],
    ["quoted argument with NEL", 'cat "x"\u0085y'],
    ["trailing lone CR", "cat a\r"],
    ["leading VT", "cat \vb.md"],
  ])("rejects a mismatched %s in %j", async (_context, source) => {
    const service = await freshRealByteService();
    await expect(
      service.loadParsedShellDocument(source),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "word_boundary",
    });
  });

  it.each([
    ["VT", "\v"],
    ["FF", "\f"],
    ["lone CR", "\r"],
  ])(
    "rejects %s treated as whitespace between words",
    async (_separator, character) => {
      const service = await freshRealByteService();
      // Bash keeps the character as part of the single argument.
      await expect(
        service.loadParsedShellDocument(`cat a${character}b`),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "word_boundary",
        span: { start: 5, end: 6 },
      });
    },
  );

  it("keeps bare and concatenated Unicode arguments with CRLF", async () => {
    const service = await freshRealByteService();
    const document = await loadRealDocument(
      service,
      'cat café "x"漢字 \\\r\n\u200by\ufeff\r\n',
    );
    expect(document.commands[0]?.arguments).toMatchObject(
      ["café", "x漢字", "\u200by\ufeff"].map((value) => ({
        word: { kind: "literal", value },
      })),
    );
  });

  it("joins a quoted redirect destination across a CRLF continuation", async () => {
    const service = await freshRealByteService();
    const document = await loadRealDocument(service, 'cat >"x"\\\r\n漢字');
    expect(document.redirects).toMatchObject([
      { kind: "file", destination: { kind: "literal", value: "x漢字" } },
    ]);
    expect(document.commands[0]?.arguments).toEqual([]);
  });

  it("keeps Unicode in a quoted here-string", async () => {
    const service = await freshRealByteService();
    const document = await loadRealDocument(service, 'cat <<<"x\u3000漢字"');
    expect(document.redirects).toMatchObject([
      { kind: "herestring", value: { kind: "literal", value: "x\u3000漢字" } },
    ]);
  });

  it("keeps a Unicode heredoc body with CRLF", async () => {
    const service = await freshRealByteService();
    const source = "cat <<'EOF'\r\nx\u3000漢字\r\nEOF";
    const document = await loadRealDocument(service, source);
    expect(document.redirects).toHaveLength(1);
    const redirect = document.redirects[0];
    expect(redirect?.kind).toBe("heredoc");
    if (redirect?.kind !== "heredoc") throw new Error("expected a heredoc");
    expect(redirect.delimiter).toMatchObject({ value: "EOF", quoted: true });
    expect(
      source.slice(redirect.rawBodySpan.start, redirect.rawBodySpan.end),
    ).toBe("x\u3000漢字\r\n");
  });

  it.each(["café.md", "漢字.md", "🧪.md"])(
    "normalizes the bare argument %s as a literal",
    async (path) => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(service, `cat ${path}`);

      expect(document.commands[0]?.arguments).toMatchObject([
        {
          word: {
            kind: "literal",
            value: path,
            rawSpan: { start: 4, end: 4 + path.length },
          },
        },
      ]);
    },
  );

  it.each(["café.md", "漢字.md", "🧪.md"])(
    "normalizes the bare redirect destination %s as a literal",
    async (path) => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(service, `cat >${path}`);

      expect(document.redirects).toMatchObject([
        {
          kind: "file",
          destination: {
            kind: "literal",
            value: path,
            rawSpan: { start: 5, end: 5 + path.length },
          },
        },
      ]);
    },
  );

  it.each([
    ["U+00A0", "\u00a0"],
    ["U+3000", "\u3000"],
  ])("matches Bash word boundaries around %s", async (_label, space) => {
    const service = await freshRealByteService();
    const source = `set -- left${space}right ${space} tail`;
    const { execFileSync } = processLike.getBuiltinModule(
      "node:child_process",
    ) as {
      execFileSync: (
        file: string,
        args: string[],
        options: { encoding: "utf8" },
      ) => string;
    };
    const bashOutput = execFileSync(
      "bash",
      ["--noprofile", "--norc", "-c", source + "\nprintf '%s\\0' \"$@\""],
      { encoding: "utf8" },
    );
    const bashArguments = bashOutput.split("\0").slice(0, -1);

    const document = await loadRealDocument(service, source);
    expect(document.commands[0]?.arguments).toMatchObject(
      ["--", ...bashArguments].map((value) => ({
        word: { kind: "literal", value },
      })),
    );
  });

  it("rejects a Unicode whitespace boundary that Bash keeps inside a word", async () => {
    const service = await freshRealByteService();
    const source = 'cat "x"\u3000y';

    await expect(
      service.loadParsedShellDocument(source),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "word_boundary",
      span: { start: 7, end: 9 },
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.doUnmock("web-tree-sitter");
  });

  it("initializes in real byte mode and deletes the parsed tree", async () => {
    const { service, treeSitter, assetRuntime } = await freshShellParser();
    const [runtime, bashLanguage] = await Promise.all([
      installedTreeSitterBytes.loadRuntime(),
      installedTreeSitterBytes.loadLanguage("bash"),
    ]);
    const loadRuntime = vi.fn(() => Promise.resolve(runtime));
    const loadLanguage = vi.fn(() => Promise.resolve(bashLanguage));
    const init = vi.spyOn(treeSitter.Parser, "init");
    const languageLoad = vi.spyOn(treeSitter.Language, "load");
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    const deleteTree = vi.spyOn(treeSitter.Tree.prototype, "delete");

    assetRuntime.configureTreeSitterAssets({
      kind: "bytes",
      loadRuntime,
      loadLanguage,
    });
    const result = await service.loadParsedShellDocument("echo 😀");

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.program.span).toEqual({ start: 0, end: 7 });
    expect(loadRuntime).toHaveBeenCalledTimes(1);
    expect(loadLanguage).toHaveBeenCalledTimes(1);
    expect(runtime.slice(0, 4)).toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d]));
    expect(bashLanguage.slice(0, 4)).toEqual(
      new Uint8Array([0, 0x61, 0x73, 0x6d]),
    );
    expect(init).toHaveBeenCalledTimes(1);
    const initOptions = init.mock.calls[0]?.[0] as
      | { wasmBinary?: Uint8Array }
      | undefined;
    expect(initOptions?.wasmBinary).toBe(runtime);
    expect(languageLoad).toHaveBeenCalledTimes(1);
    expect(languageLoad.mock.calls[0]?.[0]).toBe(bashLanguage);
    expect(parse).toHaveBeenCalledWith("echo 😀");
    expect(deleteTree).toHaveBeenCalledTimes(1);

    realLanguage = await (languageLoad.mock.results[0]!
      .value as Promise<unknown>);
  });

  it("guards configuration synchronously and retains one-time configuration", async () => {
    const first = await freshShellParser();
    expect(() => {
      first.service.preloadShellParser();
    }).toThrow("Tree-sitter assets are not configured");
    expect(() => {
      void first.service.loadParsedShellDocument("echo hi");
    }).toThrow("Tree-sitter assets are not configured");
    expect(() => {
      first.service.getCachedParsedShellDocument("echo hi");
    }).toThrow("Tree-sitter assets are not configured");

    const firstAssets: TreeSitterAssets = {
      kind: "urls",
      runtime: "runtime-one.wasm",
      languages: { bash: "bash-one.wasm", javascript: "javascript-one.wasm" },
    };
    first.assetRuntime.configureTreeSitterAssets(firstAssets);
    expect(() => {
      first.assetRuntime.configureTreeSitterAssets(firstAssets);
    }).toThrow("Tree-sitter assets are already configured");
    expect(() => {
      first.assetRuntime.configureTreeSitterAssets({
        kind: "urls",
        runtime: "runtime-two.wasm",
        languages: { bash: "bash-two.wasm", javascript: "javascript-two.wasm" },
      });
    }).toThrow("Tree-sitter assets are already configured");

    const second = await freshShellParser();
    const loadRuntime = vi.fn(() =>
      Promise.resolve(new Uint8Array([0, 0x61, 0x73, 0x6d])),
    );
    const loadLanguage = vi.fn(() =>
      Promise.resolve(new Uint8Array([0, 0x61, 0x73, 0x6d])),
    );
    const byteAssets: TreeSitterAssets = {
      kind: "bytes",
      loadRuntime,
      loadLanguage,
    };
    expect(second.service).not.toBe(first.service);
    second.assetRuntime.configureTreeSitterAssets(byteAssets);
    expect(loadRuntime).not.toHaveBeenCalled();
    expect(loadLanguage).not.toHaveBeenCalled();
    expect(() => {
      second.assetRuntime.configureTreeSitterAssets(byteAssets);
    }).toThrow("Tree-sitter assets are already configured");
    expect(() => {
      second.assetRuntime.configureTreeSitterAssets({
        kind: "bytes",
        loadRuntime: () =>
          Promise.resolve(new Uint8Array([0, 0x61, 0x73, 0x6d])),
        loadLanguage: () =>
          Promise.resolve(new Uint8Array([0, 0x61, 0x73, 0x6d])),
      });
    }).toThrow("Tree-sitter assets are already configured");
  });

  it("uses one URL initialization flight and validates locateFile", async () => {
    const { service, treeSitter, assetRuntime } = await freshShellParser();
    const initGate = deferred<undefined>();
    const init = vi
      .spyOn(treeSitter.Parser, "init")
      .mockImplementation(() => initGate.promise);
    const languageLoad = vi
      .spyOn(treeSitter.Language, "load")
      .mockResolvedValue(realLanguage as never);
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    const deleteTree = vi.spyOn(treeSitter.Tree.prototype, "delete");
    assetRuntime.configureTreeSitterAssets({
      kind: "urls",
      runtime: "runtime-url.wasm",
      languages: {
        bash: "bash-language-url.wasm",
        javascript: "javascript-language-url.wasm",
      },
    });

    const first = service.loadParsedShellDocument("echo hi");
    const second = service.loadParsedShellDocument("echo hi");
    expect(first).toBe(second);
    expect(init).toHaveBeenCalledTimes(1);
    const options = init.mock.calls[0]![0] as {
      locateFile(fileName: string): string;
    };
    expect(options.locateFile("web-tree-sitter.wasm")).toBe("runtime-url.wasm");
    expect(() => {
      options.locateFile("other.wasm");
    }).toThrow();

    initGate.resolve(undefined);
    const [firstResult, secondResult] = await Promise.all([first, second]);
    expect(firstResult).toBe(secondResult);
    expect(languageLoad).toHaveBeenCalledTimes(1);
    expect(languageLoad).toHaveBeenCalledWith("bash-language-url.wasm");
    expect(parse).toHaveBeenCalledTimes(1);
    expect(deleteTree).toHaveBeenCalledTimes(1);
  });

  it.each([
    {
      label: "runtime",
      runtime: new Uint8Array([0, 0x61, 0x73]),
      bash: new Uint8Array([0, 0x61, 0x73, 0x6d]),
    },
    {
      label: "grammar",
      runtime: new Uint8Array([0, 0x61, 0x73, 0x6d]),
      bash: new Uint8Array([1, 2, 3, 4]),
    },
  ])(
    "rejects an invalid $label WASM prefix before native initialization",
    async ({ runtime, bash }) => {
      const { service, treeSitter, assetRuntime } = await freshShellParser();
      const runtimeGate = deferred<Uint8Array>();
      const grammarGate = deferred<Uint8Array>();
      const loadRuntime = vi.fn(() => runtimeGate.promise);
      const loadLanguage = vi.fn(() => grammarGate.promise);
      const init = vi.spyOn(treeSitter.Parser, "init");
      const languageLoad = vi.spyOn(treeSitter.Language, "load");
      const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
      const deleteTree = vi.spyOn(treeSitter.Tree.prototype, "delete");
      assetRuntime.configureTreeSitterAssets({
        kind: "bytes",
        loadRuntime,
        loadLanguage,
      });

      const pending = service.loadParsedShellDocument("echo hi");
      runtimeGate.resolve(runtime);
      await runtimeGate.promise;
      expect(init).not.toHaveBeenCalled();
      expect(languageLoad).not.toHaveBeenCalled();
      grammarGate.resolve(bash);
      await expect(pending).resolves.toEqual({
        ok: false,
        reason: "parser_initialization_failed",
      });
      expect(init).not.toHaveBeenCalled();
      expect(languageLoad).not.toHaveBeenCalled();
      expect(parse).not.toHaveBeenCalled();
      expect(deleteTree).not.toHaveBeenCalled();
    },
  );

  it.each([
    {
      label: "runtime loader",
      phase: "runtime" as const,
      error: new Error("all CDN candidates failed"),
    },
    {
      label: "Parser.init",
      phase: "init" as const,
      error: new Error("init exploded"),
    },
    {
      label: "Language.load",
      phase: "language" as const,
      error: new Error("grammar load exploded"),
    },
  ])(
    "retains a typed initialization failure from the $label",
    async ({ phase, error }) => {
      const { service, treeSitter, assetRuntime } = await freshShellParser();
      const init = vi.spyOn(treeSitter.Parser, "init");
      const languageLoad = vi.spyOn(treeSitter.Language, "load");
      const loadRuntime = vi.fn(() => Promise.reject(error));
      const loadLanguage = vi.fn(() =>
        Promise.resolve(new Uint8Array([0, 0x61, 0x73, 0x6d])),
      );

      if (phase === "runtime") {
        assetRuntime.configureTreeSitterAssets({
          kind: "bytes",
          loadRuntime,
          loadLanguage,
        });
      } else {
        assetRuntime.configureTreeSitterAssets({
          kind: "urls",
          runtime: "runtime-url.wasm",
          languages: {
            bash: "bash-language-url.wasm",
            javascript: "javascript-language-url.wasm",
          },
        });
        init.mockImplementation(
          phase === "init"
            ? () => Promise.reject(error)
            : () => Promise.resolve(),
        );
        languageLoad.mockImplementation(
          phase === "language"
            ? () => Promise.reject(error)
            : () => Promise.resolve(realLanguage as never),
        );
      }

      for (const source of Array.from({ length: 10 }, (_, i) => `echo ${i}`)) {
        await expect(service.loadParsedShellDocument(source)).resolves.toEqual({
          ok: false,
          reason: "parser_initialization_failed",
        });
      }
      if (phase === "runtime") {
        expect(loadRuntime).toHaveBeenCalledTimes(1);
        expect(loadLanguage).toHaveBeenCalledTimes(1);
        expect(init).not.toHaveBeenCalled();
      } else {
        expect(init).toHaveBeenCalledTimes(1);
        if (phase === "language") expect(languageLoad).toHaveBeenCalledTimes(1);
      }
    },
  );

  it("loads only the Bash grammar when preloading the shell parser", async () => {
    const { service, assetRuntime } = await freshShellParser();
    const loadLanguage = vi.fn(installedTreeSitterBytes.loadLanguage);
    assetRuntime.configureTreeSitterAssets({
      ...installedTreeSitterBytes,
      loadLanguage,
    });
    expect(loadLanguage).not.toHaveBeenCalled();

    service.preloadShellParser();
    expect(loadLanguage).toHaveBeenCalledExactlyOnceWith("bash");
    await assetRuntime.loadTreeSitterLanguage("bash");
    expect(loadLanguage).toHaveBeenCalledExactlyOnceWith("bash");
  });

  it("reports a preload rejection once without an unhandled rejection", async () => {
    const { service, treeSitter, assetRuntime } = await freshShellParser();
    const error = new Error("preload failed");
    const init = vi.spyOn(treeSitter.Parser, "init").mockRejectedValue(error);
    vi.spyOn(treeSitter.Language, "load").mockResolvedValue(
      realLanguage as never,
    );
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };
    processLike.on("unhandledRejection", listener);
    try {
      assetRuntime.configureTreeSitterAssets({
        kind: "urls",
        runtime: "runtime-url.wasm",
        languages: {
          bash: "bash-language-url.wasm",
          javascript: "javascript-language-url.wasm",
        },
      });
      expect(() => {
        service.preloadShellParser();
      }).not.toThrow();
      expect(() => {
        service.preloadShellParser();
      }).not.toThrow();
      await waitFor(() => {
        expect(consoleError).toHaveBeenCalledWith(
          "Failed to preload shell parser",
          error,
        );
      });
      // Node emits unhandledRejection after the promise jobs for that turn.
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      expect(consoleError).toHaveBeenCalledTimes(1);
      expect(unhandled).toEqual([]);
      await expect(
        service.loadParsedShellDocument("echo later"),
      ).resolves.toEqual({
        ok: false,
        reason: "parser_initialization_failed",
      });
      expect(init).toHaveBeenCalledTimes(1);
      expect(consoleError).toHaveBeenCalledTimes(1);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  });

  it("caches exact source strings and shares pending work", async () => {
    const { service, treeSitter, assetRuntime } = await freshShellParser();
    const initGate = deferred<undefined>();
    const init = vi
      .spyOn(treeSitter.Parser, "init")
      .mockImplementation(() => initGate.promise);
    vi.spyOn(treeSitter.Language, "load").mockResolvedValue(
      realLanguage as never,
    );
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    assetRuntime.configureTreeSitterAssets({
      kind: "urls",
      runtime: "runtime-url.wasm",
      languages: {
        bash: "bash-language-url.wasm",
        javascript: "javascript-language-url.wasm",
      },
    });

    const pendingA = service.loadParsedShellDocument("echo hi");
    const pendingB = service.loadParsedShellDocument("echo hi");
    expect(pendingA).toBe(pendingB);
    initGate.resolve(undefined);
    const first = await pendingA;
    expect(service.getCachedParsedShellDocument("echo hi")).toBe(first);
    await service.loadParsedShellDocument("echo hi ");
    await service.loadParsedShellDocument("echo hi\n");
    expect(service.getCachedParsedShellDocument("echo hi ")).toBeDefined();
    expect(service.getCachedParsedShellDocument("echo hi\n")).toBeDefined();
    expect(parse).toHaveBeenCalledTimes(3);
    expect(await service.loadParsedShellDocument("echo hi")).toBe(first);
    expect(parse).toHaveBeenCalledTimes(3);
    expect(init).toHaveBeenCalledTimes(1);
  });

  it("evicts settled entries by true LRU order and never evicts pending entries", async () => {
    const firstService = await freshShellParser();
    const firstSetup = configureUrlService(firstService);
    const firstParse = vi.spyOn(
      firstService.treeSitter.Parser.prototype,
      "parse",
    );
    for (let i = 0; i < 8; i++)
      await firstService.service.loadParsedShellDocument(`echo ${i}`);
    const touched = firstService.service.getCachedParsedShellDocument("echo 0");
    expect(touched).toBeDefined();
    await firstService.service.loadParsedShellDocument("echo 8");
    expect(firstService.service.getCachedParsedShellDocument("echo 0")).toBe(
      touched,
    );
    expect(
      firstService.service.getCachedParsedShellDocument("echo 1"),
    ).toBeUndefined();
    expect(firstParse).toHaveBeenCalledTimes(9);
    expect(firstSetup.init).toHaveBeenCalledTimes(1);

    const secondService = await freshShellParser();
    const initGate = deferred<undefined>();
    const init = vi
      .spyOn(secondService.treeSitter.Parser, "init")
      .mockImplementation(() => initGate.promise);
    vi.spyOn(secondService.treeSitter.Language, "load").mockResolvedValue(
      realLanguage as never,
    );
    const parse = vi.spyOn(secondService.treeSitter.Parser.prototype, "parse");
    secondService.assetRuntime.configureTreeSitterAssets({
      kind: "urls",
      runtime: "runtime-url.wasm",
      languages: {
        bash: "bash-language-url.wasm",
        javascript: "javascript-language-url.wasm",
      },
    });
    const pending = Array.from({ length: 9 }, (_, i) =>
      secondService.service.loadParsedShellDocument(`echo pending-${i}`),
    );
    const duplicate =
      secondService.service.loadParsedShellDocument("echo pending-0");
    expect(duplicate).toBe(pending[0]);
    initGate.resolve(undefined);
    await Promise.all(pending);
    expect(parse).toHaveBeenCalledTimes(9);
    expect(
      secondService.service.getCachedParsedShellDocument("echo pending-0"),
    ).toBeDefined();
    expect(init).toHaveBeenCalledTimes(1);
  });

  it("deletes every tree, including fatal trees, before recursive child parsing", async () => {
    const fresh = await freshShellParser();
    const { service, treeSitter } = fresh;
    configureUrlService(fresh);
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    const deleteTree = vi.spyOn(treeSitter.Tree.prototype, "delete");

    await service.loadParsedShellDocument("echo ok");
    await service.loadParsedShellDocument("echo a &&");
    await service.loadParsedShellDocument("cat <<EOF\nbody");
    const nested = await service.loadParsedShellDocument(
      "bash -c 'bash -c \"echo hi\"'",
    );

    expect(parse).toHaveBeenCalledTimes(6);
    expect(deleteTree).toHaveBeenCalledTimes(6);
    expect(parse.mock.calls.slice(-3).map(([source]) => source)).toEqual([
      "bash -c 'bash -c \"echo hi\"'",
      'bash -c "echo hi"',
      "echo hi",
    ]);
    const parseOrder = parse.mock.invocationCallOrder;
    const deleteOrder = deleteTree.mock.invocationCallOrder;
    expect(deleteOrder[3]).toBeLessThan(parseOrder[4]!);
    expect(deleteOrder[4]).toBeLessThan(parseOrder[5]!);
    expect(nested.ok).toBe(true);
    if (nested.ok) expectPlainRepositoryData(nested.document);
  });

  it("decodes only strict literal words and preserves projections", async () => {
    const service = await freshRealByteService();

    const escaped = await service.loadParsedShellDocument('echo "a\\"b"');
    expect(escaped.ok).toBe(true);
    if (escaped.ok) {
      const word = escaped.document.commands[0]!.arguments[0]!.word;
      expect(word).toMatchObject({
        kind: "literal",
        value: 'a"b',
        syntax: "string",
      });
      if (word.kind === "literal") {
        expectSpan(escaped.document.source, word.projection.span, {
          start: 6,
          end: 10,
          text: 'a\\"b',
        });
        expect(word.projection.points).toEqual([
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
          { child: 2, parent: 3 },
          { child: 3, parent: 4 },
        ]);
      }
    }

    const bridge = await service.loadParsedShellDocument(
      String.raw`echo 'a'\''b'`,
    );
    expect(bridge.ok).toBe(true);
    if (bridge.ok) {
      const word = bridge.document.commands[0]!.arguments[0]!.word;
      expect(word).toMatchObject({
        kind: "literal",
        value: "a'b",
        syntax: "concatenation",
      });
      if (word.kind === "literal")
        expect(word.projection.points).toEqual([
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
          { child: 2, parent: 5 },
          { child: 3, parent: 6 },
        ]);
    }

    const multiline =
      await service.loadParsedShellDocument('echo "line\ntext"');
    expect(multiline.ok).toBe(true);
    if (multiline.ok)
      expect(multiline.document.commands[0]!.arguments[0]!.word).toMatchObject({
        kind: "literal",
        value: "line\ntext",
      });

    const continued = await service.loadParsedShellDocument(
      'echo "a\\' + "\n" + 'b"',
    );
    expect(continued.ok).toBe(true);
    if (continued.ok)
      expect(continued.document.commands[0]!.arguments[0]!.word).toMatchObject({
        kind: "literal",
        value: "ab",
      });

    const glob = await service.loadParsedShellDocument("echo *");
    expect(glob.ok).toBe(true);
    if (glob.ok)
      expect(glob.document.commands[0]!.arguments[0]!.word).toMatchObject({
        kind: "nonliteral",
        reason: "unsafe_unquoted",
      });

    const dynamic = await service.loadParsedShellDocument(
      'echo "$(printf hi)" $((1+2))',
    );
    expect(dynamic.ok).toBe(true);
    if (dynamic.ok) {
      expect(dynamic.document.commands[0]!.arguments).toHaveLength(2);
      expect(dynamic.document.commands[0]!.arguments[0]!.word).toMatchObject({
        kind: "nonliteral",
        reason: "dynamic_child",
      });
      expect(dynamic.document.commands[0]!.arguments[1]!.word).toMatchObject({
        kind: "nonliteral",
        reason: "dynamic_child",
      });
    }

    const empty = await service.loadParsedShellDocument('zsh -lc ""');
    expect(empty.ok).toBe(true);
    if (empty.ok) {
      const payload = empty.document.embeddedInvocations[0]!.payload;
      expect(payload.text).toBe("");
      expectSpan(empty.document.source, payload.contentSpan, {
        start: 9,
        end: 9,
        text: "",
      });
      expect(payload.projection.points).toEqual([{ child: 0, parent: 0 }]);
    }

    const crlf = await service.loadParsedShellDocument("cat <<EOF\r\nx\r\nEOF");
    expect(crlf.ok).toBe(true);
    if (crlf.ok) {
      expect(crlf.document.source.length).toBe(17);
      const heredoc = crlf.document.redirects[0];
      expect(heredoc?.kind).toBe("heredoc");
      if (heredoc?.kind === "heredoc") {
        expectSpan(crlf.document.source, heredoc.headerLineBreakSpan, {
          start: 9,
          end: 11,
          text: "\r\n",
        });
        expectSpan(crlf.document.source, heredoc.rawBodySpan, {
          start: 11,
          end: 14,
          text: "x\r\n",
        });
        expectSpan(crlf.document.source, heredoc.contentSpan, {
          start: 11,
          end: 12,
          text: "x",
        });
        expectSpan(crlf.document.source, heredoc.terminatorSpan, {
          start: 14,
          end: 17,
          text: "EOF",
        });
      }
    }

    const quotedDelimiter = await service.loadParsedShellDocument(
      'cat <<"EOF"\nx\nEOF',
    );
    expect(quotedDelimiter.ok).toBe(true);
    if (quotedDelimiter.ok) {
      const heredoc = quotedDelimiter.document.redirects[0];
      expect(heredoc?.kind).toBe("heredoc");
      if (heredoc?.kind === "heredoc")
        expect(heredoc.delimiter).toMatchObject({
          value: "EOF",
          quoted: true,
        });
    }

    const descriptor = await service.loadParsedShellDocument(
      "echo hi <in 2>err >out",
    );
    expect(descriptor.ok).toBe(true);
    if (descriptor.ok) {
      expect(descriptor.document.redirects).toHaveLength(3);
      expect(
        descriptor.document.redirects.map((redirect) => redirect.kind),
      ).toEqual(["file", "file", "file"]);
      const [input, errorOutput, output] = descriptor.document.redirects;
      if (input?.kind === "file") {
        expectSpan(descriptor.document.source, input.span, {
          start: 8,
          end: 11,
          text: "<in",
        });
        expect(input.operator).toBe("<");
        expect(input.destination?.kind).toBe("literal");
        if (input.destination?.kind === "literal")
          expect(input.destination.value).toBe("in");
      }
      if (errorOutput?.kind === "file") {
        expectSpan(
          descriptor.document.source,
          errorOutput.descriptor!.rawSpan,
          {
            start: 12,
            end: 13,
            text: "2",
          },
        );
        expect(errorOutput.operator).toBe(">");
        expect(errorOutput.destination?.kind).toBe("literal");
        if (errorOutput.destination?.kind === "literal")
          expect(errorOutput.destination.value).toBe("err");
      }
      if (output?.kind === "file")
        expect(output.destination?.kind).toBe("literal");
    }
  });

  it("records normalized payload quote ownership", async () => {
    const service = await freshRealByteService();
    const cases = [
      ["python -c 'print(1)'", "single"],
      ['python -c "print(1)"', "double"],
      ["zsh -lc cat", "projected"],
      ["zsh -lc 'cat README.md''x'", "projected"],
      ["zsh -lc 'printf '\\''hi'\\'''", "single"],
      ["zsh -lc \"cat\"'suffix'", "projected"],
    ] as const;

    for (const [source, quoteKind] of cases) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok).toBe(true);
      if (!result.ok) continue;
      expect(result.document.embeddedInvocations[0]?.payload.quoteKind).toBe(
        quoteKind,
      );
    }
  });

  it("normalizes literal command arguments and escaped wrapper paths", async () => {
    const service = await freshRealByteService();
    const cases = [
      {
        source: "head -25",
        arguments: [{ value: "-25", start: 5, end: 8 }],
      },
      {
        source: "nl -w 4",
        arguments: [
          { value: "-w", start: 3, end: 5 },
          { value: "4", start: 6, end: 7 },
        ],
      },
      {
        source: "git diff HEAD~1",
        arguments: [
          { value: "diff", start: 4, end: 8 },
          { value: "HEAD~1", start: 9, end: 15 },
        ],
      },
      {
        source: "git log -p -1",
        arguments: [
          { value: "log", start: 4, end: 7 },
          { value: "-p", start: 8, end: 10 },
          { value: "-1", start: 11, end: 13 },
        ],
      },
    ] as const;
    for (const { source, arguments: expectedArguments } of cases) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (!result.ok) continue;
      const command = result.document.commands[0]!;
      expect(command.arguments).toHaveLength(expectedArguments.length);
      expect(
        command.arguments.map((argument) =>
          argument.word.kind === "literal" ? argument.word.value : null,
        ),
        source,
      ).toEqual(expectedArguments.map(({ value }) => value));

      for (const expected of expectedArguments) {
        const argument = command.arguments.find(
          (candidate) => candidate.word.rawSpan.start === expected.start,
        );
        expect(argument, source).toBeDefined();
        if (argument === undefined) continue;
        const word = argument.word;
        expect(word, source).toMatchObject({
          kind: "literal",
          value: expected.value,
          rawSpan: { start: expected.start, end: expected.end },
        });
        if (word.kind !== "literal") continue;
        expectSpan(result.document.source, word.rawSpan, {
          start: expected.start,
          end: expected.end,
          text: expected.value,
        });
        expectProjection(result.document.source, word.projection, {
          span: {
            start: expected.start,
            end: expected.end,
            text: expected.value,
          },
          points: [
            { child: 0, parent: 0 },
            {
              child: expected.value.length,
              parent: expected.value.length,
            },
          ],
        });
      }
    }

    for (const source of ["cat ~", "cat ~/README.md", "cat ~user/README.md"]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (result.ok)
        expect(result.document.commands[0]!.arguments[0]!.word).toMatchObject({
          kind: "nonliteral",
          reason: "unsafe_unquoted",
        });
    }

    const escapedWrapper =
      "/run/current-system/sw/bin/zsh -lc \"cat > /tmp/a\\\\b.md <<'EOF'\\n# T\\nEOF\"";
    const escapedResult = await service.loadParsedShellDocument(escapedWrapper);
    expect(escapedResult.ok).toBe(true);
    if (escapedResult.ok) {
      const invocation = escapedResult.document.embeddedInvocations[0];
      expect(invocation?.kind).toBe("inline");
      if (invocation?.kind !== "inline" || invocation.child === null) return;
      const redirect = invocation.child.redirects.find(
        (candidate) => candidate.kind === "file",
      );
      expect(redirect?.kind).toBe("file");
      if (redirect?.kind !== "file" || redirect.destination === null) return;
      const destination = redirect.destination;
      expect(destination).toMatchObject({
        kind: "literal",
        value: "/tmp/ab.md",
      });
      if (destination.kind === "literal") {
        const childSource = invocation.child.source;
        expect(childSource).toBe("cat > /tmp/a\\b.md <<'EOF'\n# T\nEOF");
        expectSpan(childSource, destination.rawSpan, {
          start: 6,
          end: 17,
          text: "/tmp/a\\b.md",
        });
        expectProjection(childSource, destination.projection, {
          span: {
            start: 6,
            end: 17,
            text: "/tmp/a\\b.md",
          },
          points: [
            { child: 0, parent: 0 },
            { child: 6, parent: 6 },
            { child: 7, parent: 8 },
            { child: 10, parent: 11 },
          ],
        });
      }
    }

    for (const source of [
      "cat foo\\ bar*",
      "cat foo\\ bar?",
      "cat ~/foo\\ bar",
    ]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (result.ok)
        expect(result.document.commands[0]!.arguments[0]!.word).toMatchObject({
          kind: "nonliteral",
          reason: "unsafe_unquoted",
        });
    }

    const glob = await service.loadParsedShellDocument("cat *");
    expect(glob.ok).toBe(true);
    if (glob.ok)
      expect(glob.document.commands[0]!.arguments[0]!.word).toMatchObject({
        kind: "nonliteral",
        reason: "unsafe_unquoted",
      });
    await expect(
      service.loadParsedShellDocument("cat trailing\\"),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
    });
  });

  it("normalizes file redirect destinations as literal words", async () => {
    const service = await freshRealByteService();
    const cases = [
      {
        source: "cat 2>&1",
        operator: ">&",
        descriptor: "2",
        destination: { syntax: "word", value: "1" },
      },
      {
        source: "cat 1>/tmp/output.py",
        operator: ">",
        descriptor: "1",
        destination: { syntax: "word", value: "/tmp/output.py" },
      },
      {
        source: "cat 3>/tmp/output.py",
        operator: ">",
        descriptor: "3",
        destination: { syntax: "word", value: "/tmp/output.py" },
      },
      {
        source: "cat 4<&3",
        operator: "<&",
        descriptor: "4",
        destination: { syntax: "word", value: "3" },
      },
      {
        source: 'cat 2>&"1"',
        operator: ">&",
        descriptor: "2",
        destination: { syntax: "string", value: "1" },
      },
      {
        source: "cat 2>&'0'2",
        operator: ">&",
        descriptor: "2",
        destination: { syntax: "concatenation", value: "02" },
      },
      {
        source: 'cat 10>/tmp/output.py 4<&"03"',
        operator: ">",
        descriptor: "10",
        destination: { syntax: "word", value: "/tmp/output.py" },
      },
      {
        source: 'cat 10>/tmp/output.py 4<&"03"',
        operator: "<&",
        descriptor: "4",
        destination: { syntax: "string", value: "03" },
      },
      {
        source: 'cat >"2"',
        operator: ">",
        descriptor: null,
        destination: { syntax: "string", value: "2" },
      },
      {
        source: "cat >>'03'",
        operator: ">>",
        descriptor: null,
        destination: { syntax: "raw_string", value: "03" },
      },
      {
        source: 'cat >|"000"',
        operator: ">|",
        descriptor: null,
        destination: { syntax: "string", value: "000" },
      },
      {
        source: 'cat &>"2"',
        operator: "&>",
        descriptor: null,
        destination: { syntax: "string", value: "2" },
      },
      {
        source: "cat &>>'03'",
        operator: "&>>",
        descriptor: null,
        destination: { syntax: "raw_string", value: "03" },
      },
    ] as const;

    for (const testCase of cases) {
      const result = await service.loadParsedShellDocument(testCase.source);
      expect(result.ok, testCase.source).toBe(true);
      if (!result.ok) continue;

      const redirects = result.document.redirects.filter(
        (redirect) => redirect.kind === "file",
      );
      const redirect = redirects.find(
        (candidate) => candidate.operator === testCase.operator,
      );
      expect(redirect, testCase.source).toBeDefined();
      if (redirect === undefined) continue;

      const descriptor =
        redirect.descriptor === null
          ? null
          : testCase.source.slice(
              redirect.descriptor.rawSpan.start,
              redirect.descriptor.rawSpan.end,
            );
      const destination =
        redirect.destination === null
          ? null
          : {
              kind: redirect.destination.kind,
              syntax: redirect.destination.syntax,
              value:
                redirect.destination.kind === "literal"
                  ? redirect.destination.value
                  : null,
            };
      expect({ descriptor, destination }).toEqual({
        descriptor: testCase.descriptor,
        destination: {
          kind: "literal",
          ...testCase.destination,
        },
      });
    }
  });

  it("rejects variable descriptors as unsafe shell syntax", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat {fd}>out",
      "{fd}<in",
      "{fd}>&1",
      "{fd}<&0",
      "cat >a {fd}>b",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects variable descriptor heredocs as unsafe shell syntax", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat {fd}<<EOF\nprint(1)\nEOF",
      "{fd}<<EOF\nprint(1)\nEOF",
      "{fd}<<<x",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects atomic variable closes as unsafe shell syntax", async () => {
    const service = await freshRealByteService();
    await expect(
      service.loadParsedShellDocument('cat {fd}>&-"" extra'),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });

  it("rejects atomic closes as unsafe shell syntax", async () => {
    const service = await freshRealByteService();
    for (const source of ["cat >&- x", "cat <&- x", "bash -c 'echo x' >&- x"]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it.each([
    "cat >&1-",
    "cat 2>&1-",
    "cat <&0-",
    "cat 3<&4-",
    "cat >& 1-",
    "cat >&1\\\n-",
    "cat >& -",
    'cat >&"-"',
    'cat 4<&"-"',
    'cat >&"1-"',
    'cat >&1-""',
    "cat >&+1-",
    "cat 2>&$((1))-",
    "cat 3>&$fd-",
    "cat 2>&${v}-",
    "cat <&$fd-",
    "cat 2>&$'1'-",
    "cat 2>&[1]-",
    "cat >&$target",
    'cat 1>&"$FD"',
    "cat 2>&file",
    "cat 3>&file",
    "cat <&file",
  ])(
    "rejects unmodeled descriptor operands as unsafe shell syntax: %j",
    async (source) => {
      const service = await freshRealByteService();
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
      });
    },
  );

  it.each([
    "cat 2>&1",
    "cat >&2",
    'cat >&"1"',
    "cat <&0",
    "cat 1<&3",
    "cat >&file",
    "cat 1>&file",
  ])("accepts descriptor duplication and file targets: %s", async (source) => {
    const service = await freshRealByteService();
    await expect(
      service.loadParsedShellDocument(source),
    ).resolves.toMatchObject({
      ok: true,
    });
  });

  it("keeps malformed atomic-close error fragments typed raw", async () => {
    const service = await freshRealByteService();
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const fragments = ['""(', '"" )', '""`'] as const;
    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const fragment of fragments) {
          const source = `cat ${descriptor}${operator}${fragment} extra`;
          await expect(
            service.loadParsedShellDocument(source),
          ).resolves.toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
            issue: "error_node",
          });
        }
      }
    }
    for (const source of [
      'cat >/tmp/output.py 2>&-""( extra <<EOF\nprint(1)\nEOF',
      'cat >/tmp/output.py 2>&-""( extra <<EOF\r\nprint(1)\r\nEOF',
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects orphaned nonempty atomic-close continuation fragments", async () => {
    const service = await freshRealByteService();
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const lineEndings = ["\n", "\r\n"] as const;
    const fragments = ["x", '"x"', "$(printf x)"] as const;
    const sources: string[] = [];

    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const lineEnding of lineEndings) {
          for (const fragment of fragments) {
            sources.push(
              `: ${descriptor}${operator}\\${lineEnding}${fragment}`,
              `bash -c 'echo hi' ${descriptor}${operator}\\${lineEnding}${fragment}`,
              `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${fragment} <<EOF${lineEnding}print(1)${lineEnding}EOF`,
            );
          }
        }
      }
    }

    for (const source of sources) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects malformed atomic-close errors after continued empty fragments", async () => {
    const service = await freshRealByteService();
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const lineEndings = ["\n", "\r\n"] as const;
    const fragments = ['""(', '"" )', '""`'] as const;

    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const lineEnding of lineEndings) {
          for (const fragment of fragments) {
            for (const source of [
              `: ${descriptor}${operator}\\${lineEnding}${fragment} extra`,
              `bash -c 'echo hi' ${descriptor}${operator}\\${lineEnding}${fragment} extra`,
              `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${fragment} extra <<EOF${lineEnding}print(1)${lineEnding}EOF`,
            ]) {
              await expect(
                service.loadParsedShellDocument(source),
              ).resolves.toMatchObject({
                ok: false,
                reason: "unsafe_shell_syntax",
                issue: "error_node",
              });
            }
          }
        }
      }
    }
  });

  it("rejects continued atomic closes as unsafe shell syntax", async () => {
    const service = await freshRealByteService();
    for (const source of [': >&-\\\n\\"\\"', ': <&-\\\r\n\\"\\"']) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("keeps nonexact brace forms out of descriptor repair", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat {fd} >out",
      'cat "{fd}">out',
      "cat x{fd}>out",
      "cat \\{fd}>out",
      "cat {a,b}>out",
      "cat {fd}&>out",
    ]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (!result.ok) continue;
      expect(result.document.commands[0]?.arguments).toHaveLength(1);
      expect(result.document.redirects[0]?.descriptor).toBeNull();
    }
  });

  it("bounds descriptor rejection to native syntax nodes", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "echo '{fd}>out'",
      "printf '%s' '{fd}>out'",
      "echo ok # {fd}>out",
      "cat <<EOF\n{fd}>out\nEOF",
      "echo >out {fd}",
      "echo >out; echo {fd}",
      "echo >out\necho {fd}",
    ])
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: true,
      });

    for (const source of [
      "cat {fd}\n>one cat <<EOF\nbody\nEOF",
      "cat {fd}\r\n>one cat <<EOF\r\nbody\r\nEOF",
      "if ); then cat <<EOF\nbody\nEOF\nfi",
    ])
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });

    const wrapper = await service.loadParsedShellDocument(
      "bash -c 'echo {fd}>out'",
    );
    expect(wrapper).toMatchObject({ ok: true });
    if (!wrapper.ok) return;
    expect(wrapper.document.diagnostics).toContainEqual(
      expect.objectContaining({ kind: "child_parse_failed" }),
    );
  });

  it("keeps static numeric concatenation fragments in mixed wrapper payloads", async () => {
    const service = await freshRealByteService();
    const source = [
      `/run/current-system/sw/bin/zsh -lc "cat > /tmp/cydo-heredoc-render.svg <<'EOF'`,
      '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><text y="20">"\'$literal</text></svg>',
      `EOF'`,
    ].join("\n");
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.diagnostics).toEqual([]);
    expect(result.document.embeddedInvocations).toHaveLength(1);
    const invocation = result.document.embeddedInvocations[0]!;
    expect(invocation.payload.text).toBe(
      [
        "cat > /tmp/cydo-heredoc-render.svg <<'EOF'",
        "<svg xmlns=http://www.w3.org/2000/svg width=32 height=32><text y=20>$literal</text></svg>",
        "EOF",
      ].join("\n"),
    );
    expect(
      source.slice(
        invocation.payload.projection.span.start,
        invocation.payload.projection.span.end,
      ),
    ).toContain('width="32"');
    expect(invocation.child).not.toBeNull();
    if (!invocation.child) return;
    const heredoc = invocation.child.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    expect(heredoc?.kind).toBe("heredoc");
    if (heredoc?.kind === "heredoc")
      expect(
        invocation.child.source.slice(
          heredoc.contentSpan.start,
          heredoc.contentSpan.end,
        ),
      ).toContain("<svg");
  });

  it.each([
    {
      boundary: "&" as const,
      source: 'bash -c "echo left" & bash -c "echo right"',
    },
    {
      boundary: ";;" as const,
      source: 'bash -c "echo left" ;; bash -c "echo right"',
    },
  ])(
    "suppresses only the wrapper before an unsupported $boundary boundary",
    async ({ boundary, source }) => {
      const service = await freshRealByteService();
      const result = await service.loadParsedShellDocument(source);

      expect(result.ok).toBe(true);
      if (!result.ok) return;
      expect(result.document.commands).toHaveLength(2);
      expect(result.document.embeddedInvocations).toHaveLength(1);
      expect(result.document.embeddedInvocations[0]).toMatchObject({
        commandId: 1,
        payload: { text: "echo right" },
      });
      expect(result.document.diagnostics).toEqual([
        {
          kind: "unsupported_control",
          span: {
            start: source.indexOf(boundary),
            end: source.indexOf(boundary) + boundary.length,
          },
          operator: boundary,
        },
      ]);
    },
  );

  it("does not discover a wrapper when its heredoc header has arguments", async () => {
    const service = await freshRealByteService();
    const source = "python3 <<EOF echo a b\nbody\nEOF";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const heredoc = result.document.redirects[0];
    expect(heredoc?.kind).toBe("heredoc");
    if (heredoc?.kind !== "heredoc") return;
    expect(
      heredoc.header.arguments.map((argument) => argument.word),
    ).toMatchObject([
      { kind: "literal", value: "echo" },
      { kind: "literal", value: "a" },
      { kind: "literal", value: "b" },
    ]);
    expect(result.document.embeddedInvocations).toEqual([]);
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_heredoc_header",
        span: {
          start: source.indexOf("echo"),
          end: source.indexOf("\n"),
        },
        issue: "arguments",
      },
    ]);
  });

  it("keeps zero-length concatenation endpoints out of projections", async () => {
    const service = await freshRealByteService();
    const source = 'echo ""a""';
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const word = result.document.commands[0]!.arguments[0]!.word;
    expect(word).toMatchObject({
      kind: "literal",
      syntax: "concatenation",
      rawSpan: { start: 5, end: 10 },
      value: "a",
    });
    if (word.kind !== "literal") return;
    expectSpan(source, word.projection.span, {
      start: 7,
      end: 8,
      text: "a",
    });
    expect(word.projection.points).toEqual([
      { child: 0, parent: 0 },
      { child: 1, parent: 1 },
    ]);
  });

  it("closes projections over trailing line continuations", async () => {
    const service = await freshRealByteService();
    const source = 'echo "a\\\n"';
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const word = result.document.commands[0]!.arguments[0]!.word;
    expect(word).toMatchObject({
      kind: "literal",
      value: "a",
      syntax: "string",
    });
    if (word.kind !== "literal") return;
    expectSpan(source, word.projection.span, {
      start: 6,
      end: 9,
      text: "a\\\n",
    });
    expect(word.projection.points).toEqual([
      { child: 0, parent: 0 },
      { child: 1, parent: 3 },
    ]);
  });

  it("rejects a quote-only line continuation as invalid quoting", async () => {
    const service = await freshRealByteService();
    const source = 'echo "\\\n"';
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.commands[0]!.arguments[0]!.word).toMatchObject({
      kind: "nonliteral",
      syntax: "string",
      rawSpan: { start: 5, end: 9 },
      reason: "invalid_quoting",
      nodeTypes: ["string"],
    });
  });

  it("diagnoses pipe-stderr in nested heredoc header pipelines", async () => {
    const service = await freshRealByteService();
    const source = "cat <<EOF | sed x |& cat\nbody\nEOF";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_heredoc_header",
        span: {
          start: source.indexOf("|&"),
          end: source.indexOf("|&") + 2,
        },
        issue: "pipe_stderr",
      },
    ]);
  });

  it("diagnoses the exact pipe-stderr heredoc header span", async () => {
    const service = await freshRealByteService();
    const source = "cat <<EOF | a |& b >out\nx\nEOF";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_heredoc_header",
        span: {
          start: source.indexOf("|&"),
          end: source.indexOf("|&") + 2,
        },
        issue: "pipe_stderr",
      },
    ]);
  });

  it("inventories multiple and invalid heredocs inside opaque controls", async () => {
    const service = await freshRealByteService();
    const multipleSource = "if true; then cat <<A\na\nA\ncat <<B\nb\nB\nfi";
    const multiple = await service.loadParsedShellDocument(multipleSource);
    expect(multiple).toEqual({
      ok: false,
      reason: "invalid_heredoc",
      issue: "multiple",
      span: {
        start: multipleSource.indexOf("<<B"),
        end: multipleSource.indexOf("\nfi"),
      },
    });

    const invalidSource = "if true; then cat <<-A\na\nA\nfi";
    const invalid = await service.loadParsedShellDocument(invalidSource);
    expect(invalid).toEqual({
      ok: false,
      reason: "invalid_heredoc",
      issue: "indented",
      span: {
        start: invalidSource.indexOf("<<-"),
        end: invalidSource.indexOf("<<-") + 3,
      },
    });

    const unsupportedSource = "if true; then cat <<$A\nbody\n$A\nfi";
    const unsupported =
      await service.loadParsedShellDocument(unsupportedSource);
    expect(unsupported).toMatchObject({
      ok: false,
      reason: "invalid_heredoc",
      issue: "unsupported_delimiter",
    });
    if (!unsupported.ok && unsupported.reason === "invalid_heredoc")
      expectSpan(unsupportedSource, unsupported.span, {
        start: unsupportedSource.indexOf("$A"),
        end: unsupportedSource.indexOf("$A") + 2,
        text: "$A",
      });

    const incompleteSource = "if true; then cat <<A\nbody";
    const incomplete = await service.loadParsedShellDocument(incompleteSource);
    expect(incomplete).toMatchObject({
      ok: false,
      reason: "invalid_heredoc",
      issue: "incomplete",
    });

    const malformedIncompleteSource = "if ); then cat <<EOF\nbody";
    await expect(
      service.loadParsedShellDocument(malformedIncompleteSource),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });

  it.each([
    {
      position: "at the start",
      index: 0,
      command: "cat <<'EOF'",
      separator: ";",
    },
    {
      position: "in the middle",
      index: 2_000,
      command: "cat <<'EOF'",
      separator: ";",
    },
    {
      position: "before a background separator",
      index: 0,
      command: "cat >顔.md <<'EOF'",
      separator: "&",
    },
  ])(
    "reports an incomplete heredoc $position of a long list",
    async ({ index, command, separator }) => {
      const service = await freshRealByteService();
      const parts = Array.from({ length: 4_000 }, () => "true");
      parts[index] = command;
      const source = parts.join(`${separator} `) + "\nx\nEOF\n";
      const heredocStart = source.indexOf("<<");
      const expected = {
        ok: false,
        reason: "invalid_heredoc",
        issue: "incomplete",
        span: { start: heredocStart, end: heredocStart + "<<'EOF'".length },
      } satisfies ParseResult;

      expect(await service.loadParsedShellDocument(source)).toEqual(expected);
    },
  );

  it("decodes quoted env assignments before resolving the interpreter", async () => {
    const service = await freshRealByteService();
    const source = 'env "FOO=bar baz" BAR=two python3 -u - <<EOF\nx\nEOF';
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.embeddedInvocations).toHaveLength(1);
    expect(result.document.embeddedInvocations[0]).toMatchObject({
      prefix: {
        kind: "env",
        assignments: [
          { argumentIndex: 0, name: "FOO", value: "bar baz" },
          { argumentIndex: 1, name: "BAR", value: "two" },
        ],
      },
      interpreter: {
        location: { kind: "argument", index: 2 },
        basename: "python3",
      },
      optionArgumentIndices: [3],
      stdinArgumentIndex: 4,
    });
  });

  it("reports -- after env assignments as an unsupported option", async () => {
    const service = await freshRealByteService();
    const source = "env FOO=bar -- python3 - <<EOF\nx\nEOF";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.embeddedInvocations).toEqual([]);
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_env",
        span: {
          start: source.indexOf("--"),
          end: source.indexOf("--") + 2,
        },
        issue: "option",
      },
    ]);
  });

  it("orders diagnostics by their source spans", async () => {
    const service = await freshRealByteService();
    const source = "env -i python3 - <<EOF\nx\nEOF\necho a || echo b";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const optionStart = source.indexOf("-i");
    const controlStart = source.indexOf("||");
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_env",
        span: { start: optionStart, end: optionStart + 2 },
        issue: "option",
      },
      {
        kind: "unsupported_control",
        span: { start: controlStart, end: controlStart + 2 },
        operator: "||",
      },
    ]);
  });

  it("represents a redirection-only statement as an opaque unit", async () => {
    const service = await freshRealByteService();
    for (const source of [">out", ">out & 2>&1"]) {
      const result = await service.loadParsedShellDocument(source);

      expect(result.ok).toBe(true);
      if (!result.ok) continue;
      expect(result.document.program.children).toEqual(
        source === ">out"
          ? [
              {
                kind: "opaque",
                span: { start: 0, end: source.length },
                nodeType: "redirected_statement",
                reason: "unsupported_construct",
              },
            ]
          : [
              {
                kind: "opaque",
                span: { start: 0, end: 4 },
                nodeType: "redirected_statement",
                reason: "unsupported_construct",
              },
              {
                kind: "opaque",
                span: { start: 7, end: source.length },
                nodeType: "redirected_statement",
                reason: "unsupported_construct",
              },
            ],
      );
      expect(result.document.commands).toEqual([]);
      expect(result.document.redirects).toEqual([]);
      expect(result.document.embeddedInvocations).toEqual([]);
      expect(result.document.diagnostics).toEqual(
        source === ">out"
          ? [
              {
                kind: "unsupported_construct",
                span: { start: 0, end: source.length },
                nodeType: "redirected_statement",
              },
            ]
          : [
              {
                kind: "unsupported_construct",
                span: { start: 0, end: 4 },
                nodeType: "redirected_statement",
              },
              {
                kind: "unsupported_control",
                span: { start: 5, end: 6 },
                operator: "&",
              },
              {
                kind: "unsupported_construct",
                span: { start: 7, end: source.length },
                nodeType: "redirected_statement",
              },
            ],
      );
    }
  });

  it("rejects an ownerless complete heredoc", async () => {
    const service = await freshRealByteService();
    await expect(
      service.loadParsedShellDocument("<<EOF\nbody\nEOF"),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });

  it("keeps nested heredoc and invalid-looking text opaque in a heredoc body", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat <<OUT\n$(cat <<IN\nx\nIN\n)\nOUT",
      "cat <<EOF\n$(echo &&)\nEOF",
    ]) {
      const result = await service.loadParsedShellDocument(source);

      expect(result.ok).toBe(true);
      if (!result.ok) continue;
      expect(result.document.commands).toHaveLength(1);
      expect(result.document.redirects).toHaveLength(1);
      expect(result.document.embeddedInvocations).toEqual([]);
      expect(result.document.diagnostics).toEqual([]);

      const redirect = result.document.redirects[0];
      expect(redirect?.kind).toBe("heredoc");
    }
  });

  it.each([
    {
      label: "if body",
      source: ["if true; then cat <<EOF", "body", "EOF", "fi"].join("\n"),
      nodeType: "if_statement",
    },
    {
      label: "function body",
      source: ["run() { cat <<EOF", "body", "EOF", "}"].join("\n"),
      nodeType: "function_definition",
    },
    {
      label: "command-substitution body",
      source: ["echo $(cat <<EOF", "body", "EOF", ")"].join("\n"),
      nodeType: "command",
    },
  ])(
    "validates a single heredoc in an opaque $label without publishing its inner data",
    async ({ source, nodeType }) => {
      const service = await freshRealByteService();
      const result = await service.loadParsedShellDocument(source);

      expect(result.ok).toBe(true);
      if (!result.ok) return;
      expect(result.document.redirects).toEqual([]);
      expect(result.document.embeddedInvocations).toEqual([]);

      if (nodeType === "command") {
        expect(result.document.commands).toHaveLength(1);
        expect(result.document.commands[0]?.name).toMatchObject({
          kind: "literal",
          value: "echo",
        });
        expect(result.document.program.children).toHaveLength(1);
        expect(result.document.program.children[0]?.kind).toBe("command");
        expect(result.document.diagnostics).toEqual([]);
        return;
      }

      expect(result.document.commands).toEqual([]);
      expect(result.document.program.children).toEqual([
        {
          kind: "opaque",
          span: { start: 0, end: source.length },
          nodeType,
          reason: "control_body",
        },
      ]);
      expect(result.document.diagnostics).toEqual([
        {
          kind: "unsupported_construct",
          span: { start: 0, end: source.length },
          nodeType,
        },
      ]);
    },
  );

  it.each(["<<EOF\nbody\nEOF", "2<<EOF\nbody\nEOF", "<<EOF >out\nbody\nEOF"])(
    "rejects complete ownerless heredoc %s",
    async (source) => {
      const service = await freshRealByteService();
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    },
  );

  it("keeps adjacent literal-zero descriptors typed raw with tree-sitter-bash 0.25.1", async () => {
    const service = await freshRealByteService();
    const source = "cat 0<in";
    const result = await service.loadParsedShellDocument(source);

    expect(result).toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
      span: { start: 4, end: 5 },
    });
  });

  it("pins adjacent fd-zero and leading-zero grammar limits to typed raw", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat 0>out",
      "cat 0>&1",
      "cat 0<&1",
      "cat 0<<EOF\nbody\nEOF",
      "cat 01>out",
      "cat 02>out",
      "cat 01<<EOF\nbody\nEOF",
      "cat 02<<EOF\nbody\nEOF",
      "cat >a 0>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0>&1",
      "cat >a 0<&1",
      "cat >a 01>/tmp/output.py",
      "cat >a 0>/tmp/output.py 1>&2",
    ]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result, source).toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
    const nested = await service.loadParsedShellDocument(
      "bash -c 'cat >a 0>/tmp/output.py'",
    );
    expect(nested.ok).toBe(true);
    if (!nested.ok) return;
    expect(nested.document.diagnostics).toContainEqual({
      kind: "child_parse_failed",
      span: { start: 8, end: 33 },
      reason: "unsafe_shell_syntax",
    });
  });

  it("rejects adjacent numeric descriptors across line continuations", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat 0\\\n>out",
      "cat 0\\\r\n>out",
      "cat 01\\\n>out",
      "cat 01\\\r\n>out",
      "cat >a 0\\\n>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0\\\r\n>/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
      "cat <<EOF 0\\\n>/tmp/output.py\nprint(1)\nEOF",
      "cat <<EOF 0\\\r\n>/tmp/output.py\r\nprint(1)\r\nEOF",
    ]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result, source).toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("keeps a whitespace boundary before a continuation numeric argument", async () => {
    const service = await freshRealByteService();
    for (const source of ["cat >a 0 \\\n>out", "cat >a 0 \\\r\n>out"]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (!result.ok) continue;
      expect(result.document.source).toBe(source);
      expect(result.document.commands[0]?.arguments).toHaveLength(1);
      expect(
        result.document.commands[0]?.arguments[0]?.word.rawSpan.start,
      ).toBe(source.indexOf("0"));
      expect(result.document.redirects).toHaveLength(2);
      expect(result.document.redirects[1]?.descriptor).toBeNull();
    }
  });

  it("keeps whitespace-separated numeric controls as ordinary argv", async () => {
    const service = await freshRealByteService();
    for (const source of ["cat 0 >out", "cat 01 >out", "echo 0 01 02"]) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok, source).toBe(true);
      if (!result.ok) continue;
      expect(result.document.commands[0]?.arguments.length, source).toBe(
        source.startsWith("echo") ? 3 : 1,
      );
      if (!source.startsWith("echo"))
        expect(result.document.redirects[0]?.descriptor, source).toBeNull();
    }
  });

  it("assigns swallowed redirect words to their AST owners", async () => {
    const service = await freshRealByteService();
    const wrapper = await service.loadParsedShellDocument(
      "bash -c 'cat README.md' >out unexpected",
    );
    expect(wrapper.ok).toBe(true);
    if (!wrapper.ok) return;
    expect(
      wrapper.document.commands[0]?.arguments.map((argument) =>
        argument.word.kind === "literal" ? argument.word.value : null,
      ),
    ).toEqual(["-c", "cat README.md", "unexpected"]);
    expect(wrapper.document.redirects[0]).toMatchObject({
      span: { start: 24, end: 28 },
      destination: { kind: "literal", value: "out" },
    });
    expect(wrapper.document.embeddedInvocations).toEqual([]);
    expect(wrapper.document.diagnostics).toContainEqual({
      kind: "unsupported_wrapper",
      span: { start: 29, end: 39 },
      issue: "extra_argument",
    });

    const destination = await service.loadParsedShellDocument('cat >out"put"');
    expect(destination.ok).toBe(true);
    if (!destination.ok) return;
    expect(destination.document.redirects[0]).toMatchObject({
      span: { start: 4, end: 13 },
      destination: {
        kind: "literal",
        value: "output",
        rawSpan: { start: 5, end: 13 },
      },
    });

    const separated = await service.loadParsedShellDocument(
      "cat >out unexpected",
    );
    expect(separated.ok).toBe(true);
    if (!separated.ok) return;
    expect(separated.document.commands[0]?.arguments).toHaveLength(1);
    expect(separated.document.commands[0]?.arguments[0]?.word).toMatchObject({
      kind: "literal",
      value: "unexpected",
      rawSpan: { start: 9, end: 19 },
    });
    expect(separated.document.redirects[0]?.span).toEqual({
      start: 4,
      end: 8,
    });
  });

  it("joins only backslash line continuations in redirect destinations", async () => {
    const service = await freshRealByteService();
    for (const [source, value, rawEnd] of [
      ["cat >out\\\nput", "output", 13],
      ["cat >out\\\r\nput", "output", 14],
    ] as const) {
      const result = await service.loadParsedShellDocument(source);
      expect(result.ok).toBe(true);
      if (!result.ok) continue;
      expect(result.document.redirects[0]).toMatchObject({
        span: { start: 4, end: rawEnd },
        destination: {
          kind: "literal",
          value,
          rawSpan: { start: 5, end: rawEnd },
        },
      });
      expect(result.document.commands[0]?.arguments).toEqual([]);
    }
    const separated = await service.loadParsedShellDocument("cat >out\\\n put");
    expect(separated.ok).toBe(true);
    if (!separated.ok) return;
    expect(separated.document.commands[0]?.arguments[0]?.word).toMatchObject({
      kind: "literal",
      value: "put",
      rawSpan: { start: 11, end: 14 },
    });
    expect(separated.document.redirects[0]?.span).toEqual({
      start: 4,
      end: 8,
    });
  });

  it("keeps exclusive sibling redirect spans and ordered suffix argv", async () => {
    const service = await freshRealByteService();
    const source = "cat x >a y >b z";
    const result = await service.loadParsedShellDocument(source);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(
      result.document.commands[0]?.arguments.map(
        (argument) => argument.word.rawSpan,
      ),
    ).toEqual([
      { start: 4, end: 5 },
      { start: 9, end: 10 },
      { start: 14, end: 15 },
    ]);
    expect(result.document.redirects.map((redirect) => redirect.span)).toEqual([
      { start: 6, end: 8 },
      { start: 11, end: 13 },
    ]);
  });

  it("rejects variable descriptor ownership repairs", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "{fd}>out echo hi",
      "{a}>out {b}>out2 echo hi",
      "cat >a {fd}>b",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects continued variable descriptors", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "cat {fd}\\\n>out",
      "cat {fd}\\\r\n>out",
      "{fd}\\\n>out echo hi",
      "{fd}\\\r\n>out echo hi",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("rejects recovered prefix syntax", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "{fd}\\\n>one echo >two bash -c 'echo hi'",
      "{fd}\\\r\n>&- echo hi",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("keeps unaccounted anonymous recovered-prefix children typed raw", async () => {
    const service = await freshRealByteService();
    for (const source of [
      "{fd}\\\n>one bash -c 'echo hi' )",
      "{fd}\\\r\n>one bash -c 'echo hi' )",
      "{fd}\\\n>one echo >two )",
      "{fd}\\\r\n>one echo >two )",
      "{fd}\\\n>one echo >two $(",
      "{fd}\\\r\n>one echo >two $(",
    ]) {
      await expect(
        service.loadParsedShellDocument(source),
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
    }
  });

  it("retains nested redirect suffix words in heredoc headers", async () => {
    const service = await freshRealByteService();
    const source = "cat <<EOF >out echo hi\nbody\nEOF";
    const result = await service.loadParsedShellDocument(source);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const heredoc = result.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    expect(heredoc?.kind).toBe("heredoc");
    if (heredoc?.kind !== "heredoc") return;
    expect(
      heredoc.header.arguments.map((argument) =>
        argument.word.kind === "literal" ? argument.word.value : null,
      ),
    ).toEqual(["echo", "hi"]);
    expect(heredoc.headerSpan).toEqual({ start: 0, end: 22 });
    expect(heredoc.headerLineBreakSpan).toEqual({ start: 22, end: 23 });
  });

  it("represents a standalone variable assignment as an opaque unit", async () => {
    const service = await freshRealByteService();
    const source = "FOO=bar";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.document.program.children).toEqual([
      {
        kind: "opaque",
        span: { start: 0, end: source.length },
        nodeType: "variable_assignment",
        reason: "unsupported_construct",
      },
    ]);
    expect(result.document.commands).toEqual([]);
    expect(result.document.redirects).toEqual([]);
    expect(result.document.embeddedInvocations).toEqual([]);
    expect(result.document.diagnostics).toEqual([
      {
        kind: "unsupported_construct",
        span: { start: 0, end: source.length },
        nodeType: "variable_assignment",
      },
    ]);
  });

  it("preserves the canonical list node span separately from its heredoc header", async () => {
    const service = await freshRealByteService();
    const source =
      "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
    const result = await service.loadParsedShellDocument(source);

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const statement = result.document.program.children[0];
    expect(statement?.kind).toBe("redirected_statement");
    if (statement?.kind !== "redirected_statement") return;
    expect(statement.body.kind).toBe("list");
    if (statement.body.kind !== "list") return;
    expectSpan(source, statement.body.span, {
      start: 0,
      end: 18,
      text: "cd /tmp && python3",
    });

    const redirect = result.document.redirects[0];
    expect(redirect?.kind).toBe("heredoc");
    if (redirect?.kind !== "heredoc") return;
    expectSpan(source, redirect.headerSpan, {
      start: 0,
      end: 28,
      text: "cd /tmp && python3 - <<'EOF'",
    });
  });

  describe("parsed shell document validation", () => {
    it.each([
      ["if list", "if true; then echo x; fi && cat <<EOF\nbody\nEOF"],
      ["for list", "for x in x; do echo x; done && cat <<EOF\nbody\nEOF"],
      ["while list", "while true; do echo x; done && cat <<EOF\nbody\nEOF"],
      ["subshell list", "(echo x) && cat <<EOF\nbody\nEOF"],
      ["if pipeline", "if true; then echo x; fi | cat <<EOF\nbody\nEOF"],
      ["for pipeline", "for x in x; do echo x; done | cat <<EOF\nbody\nEOF"],
      ["while pipeline", "while true; do echo x; done | cat <<EOF\nbody\nEOF"],
      ["subshell pipeline", "(echo x) | cat <<EOF\nbody\nEOF"],
    ] as const)(
      "accepts a leading opaque %s before a heredoc-bearing command",
      async (_label, source) => {
        const service = await freshRealByteService();
        const document = await loadRealDocument(service, source);
        const opaque = opaqueUnits(document.program);
        const constructDiagnostics = document.diagnostics.filter(
          (
            diagnostic,
          ): diagnostic is Extract<
            ParsedShellDocument["diagnostics"][number],
            { kind: "unsupported_construct" }
          > => diagnostic.kind === "unsupported_construct",
        );

        expect(opaque).toHaveLength(1);
        expect(
          opaque.map(({ span, nodeType }) => ({ span, nodeType })),
        ).toEqual(
          constructDiagnostics.map(({ span, nodeType }) => ({
            span,
            nodeType,
          })),
        );
        expect(() => {
          service.assertValidParsedShellDocument(document);
        }, source).not.toThrow();
      },
    );

    it("requires opaque units and unsupported-construct diagnostics to match exactly", async () => {
      const service = await freshRealByteService();
      const source = "if true; then echo x; fi";
      const document = await loadRealDocument(service, source);
      const opaque = document.program.children[0];
      const diagnostic = document.diagnostics[0];
      if (
        document.program.children.length !== 1 ||
        document.diagnostics.length !== 1 ||
        opaque?.kind !== "opaque" ||
        opaque.nodeType !== "if_statement" ||
        diagnostic?.kind !== "unsupported_construct"
      )
        throw new Error("test opaque if document is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "opaque node type",
          document: {
            ...document,
            program: {
              ...document.program,
              children: [{ ...opaque, nodeType: "for_statement" }],
            },
          },
        },
        {
          label: "opaque span start",
          document: {
            ...document,
            program: {
              ...document.program,
              children: [
                {
                  ...opaque,
                  span: { ...opaque.span, start: opaque.span.start + 1 },
                },
              ],
            },
          },
        },
        {
          label: "missing construct diagnostic",
          document: { ...document, diagnostics: [] },
        },
        {
          label: "duplicate construct diagnostic",
          document: {
            ...document,
            diagnostics: [diagnostic, diagnostic],
          },
        },
        {
          label: "extra construct diagnostic",
          document: {
            ...document,
            diagnostics: [
              diagnostic,
              {
                kind: "unsupported_construct",
                span: {
                  start: source.indexOf("true"),
                  end: source.indexOf("true") + "true".length,
                },
                nodeType: "for_statement",
              },
            ],
          },
        },
        {
          label: "construct diagnostic node type",
          document: {
            ...document,
            diagnostics: [{ ...diagnostic, nodeType: "for_statement" }],
          },
        },
        {
          label: "construct diagnostic span",
          document: {
            ...document,
            diagnostics: [
              {
                ...diagnostic,
                span: {
                  ...diagnostic.span,
                  start: diagnostic.span.start + 1,
                },
              },
            ],
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it.each([
      ["direct cat", "cat README.md;"],
      ["Bash wrapper", "bash -c 'cat README.md';"],
    ] as const)(
      "retains the exact terminal semicolon for %s",
      async (_label, source) => {
        const service = await freshRealByteService();
        const document = await loadRealDocument(service, source);
        const terminalStart = source.length - 1;

        expect(document.program.children).toEqual([
          {
            kind: "command",
            span: { start: 0, end: terminalStart },
            commandId: 0,
          },
        ]);
        expect(document.program.boundaries).toEqual([
          {
            kind: "semicolon",
            text: ";",
            span: { start: terminalStart, end: source.length },
          },
        ]);
        expect(() => {
          service.assertValidParsedShellDocument(document);
        }).not.toThrow();
      },
    );

    it("retains the terminal semicolon after the cat-heredoc comment suffix", async () => {
      const service = await freshRealByteService();
      const source = "cat > README.md <<'EOF'\nhello\nEOF\n:;# << comment";
      const document = await loadRealDocument(service, source);
      const terminalStart = source.indexOf(";", source.lastIndexOf("\n") + 1);
      const newlineStart = source.lastIndexOf("\n", terminalStart);

      expect(
        document.program.children.map(({ kind, span }) => ({ kind, span })),
      ).toEqual([
        {
          kind: "redirected_statement",
          span: { start: 0, end: newlineStart },
        },
        {
          kind: "command",
          span: { start: newlineStart + 1, end: terminalStart },
        },
      ]);
      expect(document.program.boundaries).toEqual([
        {
          kind: "newline",
          text: "\n",
          span: { start: newlineStart, end: newlineStart + 1 },
        },
        {
          kind: "semicolon",
          text: ";",
          span: { start: terminalStart, end: terminalStart + 1 },
        },
      ]);
      expect(() => {
        service.assertValidParsedShellDocument(document);
      }).not.toThrow();
    });

    it("accepts real normalized controls from every producer family", async () => {
      const service = await freshRealByteService();
      const controls = new Set([
        "sh -c 'cat README.md'",
        "sh -lc 'cat README.md'",
        "sh -cl 'cat README.md'",
        "bash -c 'cat README.md'",
        "bash -lc 'cat README.md'",
        "bash -cl 'cat README.md'",
        "zsh -c 'cat README.md'",
        "zsh -lc 'cat README.md'",
        "zsh -cl 'cat README.md'",
        "python -c 'print(1)'",
        'python3 -c "print(1)"',
        "node -e 'console.log(1)'",
        "nodejs -e 'console.log(1)'",
        "ruby -e 'puts 1'",
        "perl -e 'print 1'",
        "lua -e 'print(1)'",
        "php -r 'echo 1;'",
        "Rscript -e 'print(1)'",
        "R -e 'print(1)'",
        "env FOO=one /usr/bin/python3 -c 'print(1)'",
        "FOO=one python3 -c 'print(1)'",
        "zsh -lc cat",
        "python3 - <<'EOF'\nprint(1)\nEOF",
        "env FOO=one python3 - <<'EOF'\nprint(1)\nEOF",
        "python3 -u - <<'EOF'\nprint(1)\nEOF",
        "bash -c 'bash -c \"echo hi\"'",
        `bash -c "cat '"`,
        ...shellParserCorpus
          .filter((fixture) => fixture.expected.ok)
          .map((fixture) => fixture.source),
      ]);

      for (const source of controls) {
        const document = await loadRealDocument(service, source);
        expect(() => {
          service.assertValidParsedShellDocument(document);
        }, source).not.toThrow();
      }
    });

    it("accepts synthetic dash records without requiring an invocation", async () => {
      const service = await freshRealByteService();
      const recorded = await loadRealDocument(
        service,
        "python3 - <<EOF\nprint(1)\nEOF",
      );
      const recordedCommand = recorded.commands[0];
      const recordedDash = recordedCommand?.arguments[0];
      const recordedInvocation = recorded.embeddedInvocations[0];
      if (
        recordedCommand === undefined ||
        recordedDash === undefined ||
        !recordedDash.synthetic ||
        recordedDash.word.kind !== "literal" ||
        recordedDash.word.syntax !== "synthetic" ||
        recordedDash.word.value !== "-" ||
        recordedInvocation?.kind !== "heredoc"
      )
        throw new Error("test recorded synthetic dash is incomplete");
      expect(() => {
        service.assertValidParsedShellDocument(recorded);
      }).not.toThrow();

      const diagnosticProducer = await loadRealDocument(
        service,
        "python3 foo - <<EOF\nprint(1)\nEOF",
      );
      const diagnosticCommand = diagnosticProducer.commands[0];
      const diagnosticDash = diagnosticCommand?.arguments.find(
        (argument) =>
          argument.synthetic &&
          argument.word.kind === "literal" &&
          argument.word.syntax === "synthetic" &&
          argument.word.value === "-",
      );
      if (
        diagnosticProducer.diagnostics.length === 0 ||
        diagnosticProducer.embeddedInvocations.length !== 0 ||
        diagnosticDash === undefined
      )
        throw new Error("test diagnostic synthetic dash record is incomplete");
      expect(() => {
        service.assertValidParsedShellDocument(diagnosticProducer);
      }).not.toThrow();
    });

    it("rejects ordinary arguments marked synthetic", async () => {
      const service = await freshRealByteService();
      const source = "cat REVIEW-SYNTHETIC.md";
      const document = await loadRealDocument(service, source);
      const command = document.commands[0];
      const argument = command?.arguments[0];
      const unit = document.program.children[0];
      if (
        document.commands.length !== 1 ||
        command === undefined ||
        command.arguments.length !== 1 ||
        argument === undefined ||
        argument.synthetic ||
        argument.word.kind !== "literal" ||
        argument.word.syntax === "synthetic" ||
        unit?.kind !== "command" ||
        unit.span.start !== 0 ||
        unit.span.end !== source.length
      )
        throw new Error("test ordinary argument record is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "ordinary argument marked synthetic",
          document: {
            ...document,
            commands: [
              {
                ...command,
                arguments: [{ ...argument, synthetic: true }],
              },
            ],
          },
        },
        {
          label: "synthetic marker with shortened sole command unit",
          document: {
            ...document,
            commands: [
              {
                ...command,
                arguments: [{ ...argument, synthetic: true }],
              },
            ],
            program: {
              ...document.program,
              children: [{ ...unit, span: { start: 0, end: 3 } }],
            },
          },
        },
      ];
      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("rejects synthetic dash words marked ordinary without an invocation", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "python3 foo - <<EOF\nprint(1)\nEOF",
      );
      const command = document.commands[0];
      const dash = command?.arguments.find(
        (argument) =>
          argument.synthetic &&
          argument.word.kind === "literal" &&
          argument.word.syntax === "synthetic" &&
          argument.word.value === "-",
      );
      if (
        document.diagnostics.length === 0 ||
        document.embeddedInvocations.length !== 0 ||
        command === undefined ||
        dash === undefined ||
        !dash.synthetic ||
        dash.word.kind !== "literal" ||
        dash.word.syntax !== "synthetic" ||
        dash.word.value !== "-"
      )
        throw new Error("test synthetic dash record is incomplete");

      expect(() => {
        service.assertValidParsedShellDocument({
          ...document,
          commands: [
            {
              ...command,
              arguments: command.arguments.map((argument) =>
                argument === dash
                  ? { ...argument, synthetic: false }
                  : argument,
              ),
            },
          ],
        });
      }).toThrow("parsed shell document invariant: command argument synthetic");
    });

    it("rejects one-field indexed identity and redirect-membership corruptions", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "python3 -c 'print(1)' >/tmp/out3",
      );
      const command = document.commands[0];
      const redirect = document.redirects[0];
      if (command === undefined || redirect === undefined)
        throw new Error("test inline redirect document is incomplete");

      const twoInvocations = await loadRealDocument(
        service,
        "python3 -c 'print(1)'; node -e 'console.log(1)'",
      );
      const firstInvocation = twoInvocations.embeddedInvocations[0];
      const secondInvocation = twoInvocations.embeddedInvocations[1];
      if (firstInvocation === undefined || secondInvocation === undefined)
        throw new Error("test multiple invocation document is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "stored command ID",
          document: {
            ...document,
            commands: [{ ...command, id: command.id + 1 }],
          },
        },
        {
          label: "unlisted owned redirect",
          document: {
            ...document,
            commands: [{ ...command, redirectIds: [] }],
          },
        },
        {
          label: "duplicate owned redirect ID",
          document: {
            ...document,
            commands: [
              {
                ...command,
                redirectIds: [redirect.id, redirect.id],
              },
            ],
          },
        },
        {
          label: "unknown owned redirect ID",
          document: {
            ...document,
            commands: [{ ...command, redirectIds: [999] }],
          },
        },
        {
          label: "stored redirect ID",
          document: {
            ...document,
            redirects: [{ ...redirect, id: redirect.id + 1 }],
          },
        },
        {
          label: "redirect owner",
          document: {
            ...document,
            redirects: [{ ...redirect, ownerId: command.id + 1 }],
          },
        },
        {
          label: "stored invocation ID",
          document: {
            ...twoInvocations,
            embeddedInvocations: [
              { ...firstInvocation, id: firstInvocation.id + 2 },
              secondInvocation,
            ],
          },
        },
        {
          label: "duplicate invocation owner",
          document: {
            ...twoInvocations,
            embeddedInvocations: [
              firstInvocation,
              {
                ...secondInvocation,
                commandId: firstInvocation.commandId,
              },
            ],
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("rejects one-field direct and env interpreter provenance corruptions", async () => {
      const service = await freshRealByteService();
      const directDocument = await loadRealDocument(
        service,
        "python3 -c 'print(1)'",
      );
      const directInvocation = directDocument.embeddedInvocations[0];
      if (directInvocation?.kind !== "inline")
        throw new Error("test direct invocation is incomplete");

      const envDocument = await loadRealDocument(
        service,
        "env FOO=one BAR=two python3 -c 'print(1)'",
      );
      const envInvocation = envDocument.embeddedInvocations[0];
      if (
        envInvocation?.kind !== "inline" ||
        envInvocation.prefix.kind !== "env"
      )
        throw new Error("test env invocation is incomplete");
      const [firstAssignment, secondAssignment] =
        envInvocation.prefix.assignments;
      if (firstAssignment === undefined || secondAssignment === undefined)
        throw new Error("test env assignments are incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "direct prefix",
          document: {
            ...directDocument,
            embeddedInvocations: [
              {
                ...directInvocation,
                prefix: { kind: "env", assignments: [] },
              },
            ],
          },
        },
        {
          label: "direct interpreter location",
          document: {
            ...directDocument,
            embeddedInvocations: [
              {
                ...directInvocation,
                interpreter: {
                  ...directInvocation.interpreter,
                  location: { kind: "argument", index: 0 },
                },
              },
            ],
          },
        },
        {
          label: "direct interpreter basename",
          document: {
            ...directDocument,
            embeddedInvocations: [
              {
                ...directInvocation,
                interpreter: {
                  ...directInvocation.interpreter,
                  basename: "node",
                },
              },
            ],
          },
        },
        {
          label: "direct interpreter language",
          document: {
            ...directDocument,
            embeddedInvocations: [
              {
                ...directInvocation,
                interpreter: {
                  ...directInvocation.interpreter,
                  language: "javascript",
                },
              },
            ],
          },
        },
        {
          label: "env prefix",
          document: {
            ...envDocument,
            embeddedInvocations: [
              { ...envInvocation, prefix: { kind: "direct" } },
            ],
          },
        },
        {
          label: "env interpreter location",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                interpreter: {
                  ...envInvocation.interpreter,
                  location: { kind: "argument", index: 0 },
                },
              },
            ],
          },
        },
        {
          label: "env interpreter basename",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                interpreter: { ...envInvocation.interpreter, basename: "node" },
              },
            ],
          },
        },
        {
          label: "env interpreter language",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                interpreter: {
                  ...envInvocation.interpreter,
                  language: "javascript",
                },
              },
            ],
          },
        },
        {
          label: "env assignment index",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                prefix: {
                  ...envInvocation.prefix,
                  assignments: [
                    {
                      ...firstAssignment,
                      argumentIndex: firstAssignment.argumentIndex + 1,
                    },
                    secondAssignment,
                  ],
                },
              },
            ],
          },
        },
        {
          label: "env assignment name",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                prefix: {
                  ...envInvocation.prefix,
                  assignments: [
                    { ...firstAssignment, name: "OTHER" },
                    secondAssignment,
                  ],
                },
              },
            ],
          },
        },
        {
          label: "env assignment value",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                prefix: {
                  ...envInvocation.prefix,
                  assignments: [
                    { ...firstAssignment, value: "different" },
                    secondAssignment,
                  ],
                },
              },
            ],
          },
        },
        {
          label: "env assignment order",
          document: {
            ...envDocument,
            embeddedInvocations: [
              {
                ...envInvocation,
                prefix: {
                  ...envInvocation.prefix,
                  assignments: [secondAssignment, firstAssignment],
                },
              },
            ],
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("rejects one-field inline argument and payload corruptions", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "python3 -c 'print(1)' >/tmp/out3",
      );
      const invocation = document.embeddedInvocations[0];
      const redirect = document.redirects[0];
      if (invocation?.kind !== "inline" || redirect?.kind !== "file")
        throw new Error("test inline payload document is incomplete");
      const lastProjectionPoint = invocation.payload.projection.points.at(-1);
      if (lastProjectionPoint === undefined)
        throw new Error("test inline payload projection is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "inline option index",
          document: {
            ...document,
            embeddedInvocations: [
              { ...invocation, optionArgumentIndices: [0] },
            ],
          },
        },
        {
          label: "inline flag index",
          document: {
            ...document,
            embeddedInvocations: [{ ...invocation, flagArgumentIndex: 99 }],
          },
        },
        {
          label: "inline payload index",
          document: {
            ...document,
            embeddedInvocations: [{ ...invocation, payloadArgumentIndex: 99 }],
          },
        },
        {
          label: "inline payload text",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: { ...invocation.payload, text: "print(2)" },
              },
            ],
          },
        },
        {
          label: "inline payload raw span",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: {
                  ...invocation.payload,
                  rawSpan: {
                    ...invocation.payload.rawSpan,
                    end: invocation.payload.rawSpan.end - 1,
                  },
                },
              },
            ],
          },
        },
        {
          label: "inline payload content span",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: {
                  ...invocation.payload,
                  contentSpan: {
                    ...invocation.payload.contentSpan,
                    end: invocation.payload.contentSpan.end - 1,
                  },
                },
              },
            ],
          },
        },
        {
          label: "inline payload projection span",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: {
                  ...invocation.payload,
                  projection: {
                    ...invocation.payload.projection,
                    span: {
                      ...invocation.payload.projection.span,
                      end: invocation.payload.projection.span.end - 1,
                    },
                  },
                },
              },
            ],
          },
        },
        {
          label: "inline payload projection points",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: {
                  ...invocation.payload,
                  projection: {
                    ...invocation.payload.projection,
                    points: [
                      ...invocation.payload.projection.points.slice(0, -1),
                      {
                        ...lastProjectionPoint,
                        parent: lastProjectionPoint.parent + 1,
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
        {
          label: "inline payload quote kind",
          document: {
            ...document,
            embeddedInvocations: [
              {
                ...invocation,
                payload: { ...invocation.payload, quoteKind: "double" },
              },
            ],
          },
        },
        {
          label: "inline non-file redirect",
          document: {
            ...document,
            redirects: [{ ...redirect, kind: "herestring" }],
          } as unknown as ParsedShellDocument,
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("rejects one-field heredoc invocation and redirect corruptions", async () => {
      const service = await freshRealByteService();
      const stdinDocument = await loadRealDocument(
        service,
        "python3 -u - <<'EOF'\nx\nEOF",
      );
      const stdinInvocation = stdinDocument.embeddedInvocations[0];
      const stdinHeredoc = stdinDocument.redirects.find(
        (redirect) => redirect.kind === "heredoc",
      );
      if (
        stdinInvocation?.kind !== "heredoc" ||
        stdinHeredoc === undefined ||
        stdinInvocation.stdinArgumentIndex === null
      )
        throw new Error("test stdin heredoc invocation is incomplete");

      const nestedDocument = await loadRealDocument(
        service,
        "python3 - <<EOF >out\nx\nEOF",
      );
      const nestedInvocation = nestedDocument.embeddedInvocations[0];
      const nestedHeredoc = nestedDocument.redirects.find(
        (redirect) => redirect.kind === "heredoc",
      );
      if (nestedInvocation?.kind !== "heredoc" || nestedHeredoc === undefined)
        throw new Error("test nested heredoc invocation is incomplete");
      const nestedRedirectId = nestedHeredoc.nestedRedirectIds[0];
      const nestedRedirect =
        nestedRedirectId === undefined
          ? undefined
          : nestedDocument.redirects[nestedRedirectId];
      if (nestedRedirect?.kind !== "file")
        throw new Error("test nested heredoc redirect is incomplete");
      const wrongStdinArgumentIndex =
        stdinInvocation.stdinArgumentIndex === 0 ? 1 : 0;

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "heredoc option index",
          document: {
            ...stdinDocument,
            embeddedInvocations: [
              { ...stdinInvocation, optionArgumentIndices: [1] },
            ],
          },
        },
        {
          label: "heredoc stdin index",
          document: {
            ...stdinDocument,
            embeddedInvocations: [
              {
                ...stdinInvocation,
                stdinArgumentIndex: wrongStdinArgumentIndex,
              },
            ],
          },
        },
        {
          label: "heredoc payload quote kind",
          document: {
            ...stdinDocument,
            embeddedInvocations: [
              {
                ...stdinInvocation,
                payload: { ...stdinInvocation.payload, quoteKind: "single" },
              },
            ],
          },
        },
        {
          label: "missing heredoc payload quote kind",
          document: {
            ...stdinDocument,
            embeddedInvocations: [
              {
                ...stdinInvocation,
                payload: { ...stdinInvocation.payload, quoteKind: undefined },
              },
            ],
          } as unknown as ParsedShellDocument,
        },
        {
          label: "unknown heredoc redirect ID",
          document: {
            ...stdinDocument,
            embeddedInvocations: [
              { ...stdinInvocation, heredocRedirectId: 999 },
            ],
          },
        },
        {
          label: "non-heredoc effective stdin redirect",
          document: {
            ...nestedDocument,
            embeddedInvocations: [
              {
                ...nestedInvocation,
                heredocRedirectId: nestedRedirect.id,
              },
            ],
          },
        },
        {
          label: "heredoc no longer effective stdin",
          document: {
            ...nestedDocument,
            redirects: nestedDocument.redirects.map((redirect) =>
              redirect.id === nestedRedirect.id
                ? { ...nestedRedirect, operator: "<" }
                : redirect,
            ),
          },
        },
        {
          label: "heredoc owner",
          document: {
            ...nestedDocument,
            redirects: nestedDocument.redirects.map((redirect) =>
              redirect.id === nestedHeredoc.id
                ? { ...redirect, ownerId: redirect.ownerId + 1 }
                : redirect,
            ),
          },
        },
        {
          label: "heredoc header line break",
          document: {
            ...nestedDocument,
            redirects: nestedDocument.redirects.map((redirect) =>
              redirect.id === nestedHeredoc.id
                ? {
                    ...redirect,
                    headerLineBreakSpan: {
                      ...nestedHeredoc.headerLineBreakSpan,
                      start: nestedHeredoc.headerLineBreakSpan.start + 1,
                    },
                  }
                : redirect,
            ),
          },
        },
        {
          label: "heredoc raw body",
          document: {
            ...nestedDocument,
            redirects: nestedDocument.redirects.map((redirect) =>
              redirect.id === nestedHeredoc.id
                ? {
                    ...redirect,
                    rawBodySpan: {
                      ...nestedHeredoc.rawBodySpan,
                      end: nestedHeredoc.rawBodySpan.end - 1,
                    },
                  }
                : redirect,
            ),
          },
        },
        {
          label: "heredoc nested redirect ID",
          document: {
            ...nestedDocument,
            redirects: nestedDocument.redirects.map((redirect) =>
              redirect.id === nestedHeredoc.id
                ? { ...redirect, nestedRedirectIds: [999] }
                : redirect,
            ),
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("rejects one-field child-document and child-failure corruptions", async () => {
      const service = await freshRealByteService();
      const unrelatedChild = await loadRealDocument(service, "cat LICENSE");
      const pythonDocument = await loadRealDocument(
        service,
        "python3 -c 'print(1)'",
      );
      const pythonInvocation = pythonDocument.embeddedInvocations[0];
      if (pythonInvocation?.kind !== "inline")
        throw new Error("test non-Bash invocation is incomplete");

      const bashDocument = await loadRealDocument(
        service,
        "bash -c 'cat README.md'",
      );
      const bashInvocation = bashDocument.embeddedInvocations[0];
      if (bashInvocation?.kind !== "inline" || bashInvocation.child === null)
        throw new Error("test Bash child invocation is incomplete");

      const failedChildSource = `bash -c "cat '"`;
      const failedChildDocument = await loadRealDocument(
        service,
        failedChildSource,
      );
      const failedChildInvocation = failedChildDocument.embeddedInvocations[0];
      const childFailureDiagnostic = failedChildDocument.diagnostics.find(
        (diagnostic) => diagnostic.kind === "child_parse_failed",
      );
      if (
        failedChildInvocation?.kind !== "inline" ||
        failedChildInvocation.child !== null ||
        childFailureDiagnostic === undefined
      )
        throw new Error("test child parse failure document is incomplete");

      const cyclicDocument: {
        source: string;
        program: ParsedShellDocument["program"];
        commands: ParsedShellDocument["commands"];
        redirects: ParsedShellDocument["redirects"];
        embeddedInvocations: ParsedShellEmbeddedInvocation[];
        diagnostics: ParsedShellDocument["diagnostics"];
      } = {
        ...bashDocument,
        embeddedInvocations: [...bashDocument.embeddedInvocations],
      };
      cyclicDocument.embeddedInvocations[0] = {
        ...bashInvocation,
        child: cyclicDocument,
      };

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "non-Bash child",
          document: {
            ...pythonDocument,
            embeddedInvocations: [
              { ...pythonInvocation, child: unrelatedChild },
            ],
          },
        },
        {
          label: "Bash child source",
          document: {
            ...bashDocument,
            embeddedInvocations: [{ ...bashInvocation, child: unrelatedChild }],
          },
        },
        {
          label: "child parse failure span",
          document: {
            ...failedChildDocument,
            diagnostics: failedChildDocument.diagnostics.map((diagnostic) =>
              diagnostic === childFailureDiagnostic
                ? {
                    ...diagnostic,
                    span: {
                      ...diagnostic.span,
                      end: diagnostic.span.end - 1,
                    },
                  }
                : diagnostic,
            ),
          },
        },
        {
          label: "child parse failure paired with a child",
          document: {
            ...bashDocument,
            diagnostics: [
              ...bashDocument.diagnostics,
              {
                kind: "child_parse_failed",
                span: bashInvocation.payload.rawSpan,
                reason: "unsafe_shell_syntax",
              },
            ],
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );

      expect(() => {
        service.assertValidParsedShellDocument(cyclicDocument);
      }, "Bash child cycle").toThrow(/parsed shell document invariant:.*cycle/);
    });

    it("rejects one-field malformed program boundary records", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "echo one; echo two; echo three",
      );
      const [firstBoundary, secondBoundary] = document.program.boundaries;
      if (firstBoundary === undefined || secondBoundary === undefined)
        throw new Error("test program boundaries are incomplete");

      const placementDocument = await loadRealDocument(
        service,
        "printf ';'; cat README.md",
      );
      const placementBoundary = placementDocument.program.boundaries[0];
      const quotedSemicolon = placementDocument.source.indexOf(";");
      if (placementBoundary === undefined || quotedSemicolon < 0)
        throw new Error("test boundary placement document is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "non-integer boundary span",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [
                {
                  ...firstBoundary,
                  span: { ...firstBoundary.span, start: 0.5 },
                },
                secondBoundary,
              ],
            },
          },
        },
        {
          label: "out-of-bounds boundary span",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [
                {
                  ...firstBoundary,
                  span: {
                    ...firstBoundary.span,
                    end: document.source.length + 1,
                  },
                },
                secondBoundary,
              ],
            },
          },
        },
        {
          label: "boundary kind",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [
                { ...firstBoundary, kind: "background" },
                secondBoundary,
              ],
            },
          } as unknown as ParsedShellDocument,
        },
        {
          label: "boundary text",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [{ ...firstBoundary, text: "&" }, secondBoundary],
            },
          } as unknown as ParsedShellDocument,
        },
        {
          label: "boundary source slice",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [
                {
                  ...firstBoundary,
                  span: { start: 0, end: 1 },
                },
                secondBoundary,
              ],
            },
          },
        },
        {
          label: "overlapping boundaries",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [
                firstBoundary,
                { ...secondBoundary, span: firstBoundary.span },
              ],
            },
          },
        },
        {
          label: "boundary order",
          document: {
            ...document,
            program: {
              ...document.program,
              boundaries: [secondBoundary, firstBoundary],
            },
          },
        },
        {
          label: "boundary inside a child",
          document: {
            ...placementDocument,
            program: {
              ...placementDocument.program,
              boundaries: [
                {
                  ...placementBoundary,
                  span: { start: quotedSemicolon, end: quotedSemicolon + 1 },
                },
              ],
            },
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("requires command units to reference every command once in source order", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "echo hi; cat README.md",
      );
      const [first, second] = document.program.children;
      if (
        first?.kind !== "command" ||
        second?.kind !== "command" ||
        first.commandId !== 0 ||
        second.commandId !== 1
      )
        throw new Error("test command unit records are incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "substituted first command unit",
          document: {
            ...document,
            program: {
              ...document.program,
              children: [{ ...first, commandId: second.commandId }, second],
            },
          },
        },
        {
          label: "swapped command units",
          document: {
            ...document,
            program: {
              ...document.program,
              children: [
                { ...first, commandId: second.commandId },
                { ...second, commandId: first.commandId },
              ],
            },
          },
        },
        {
          label: "omitted command unit",
          document: {
            ...document,
            program: {
              ...document.program,
              children: [first],
            },
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("requires a sole command unit to contain its full command", async () => {
      const service = await freshRealByteService();
      for (const [label, source, end] of [
        ["short sole command unit", "cat README.md", 12],
        ["detached sole command argument", "cat README.md", 3],
        ["short direct here-string unit", "cat <<<value", 11],
      ] as const) {
        const document = await loadRealDocument(service, source);
        const [unit] = document.program.children;
        if (
          document.program.children.length !== 1 ||
          unit?.kind !== "command" ||
          unit.span.end <= end
        )
          throw new Error("test sole command unit is incomplete");

        expectParsedShellDocumentInvariant(
          service,
          {
            ...document,
            program: {
              ...document.program,
              children: [{ ...unit, span: { ...unit.span, end } }],
            },
          },
          label,
        );
      }
    });

    it("ties normalized command members to their owning command span", async () => {
      const service = await freshRealByteService();
      const multiCommand = await loadRealDocument(
        service,
        "echo hi; cat README.md",
      );
      const [echoCommand, catCommand] = multiCommand.commands;
      const echoArgument = echoCommand?.arguments[0];
      if (
        echoCommand === undefined ||
        catCommand === undefined ||
        echoArgument === undefined
      )
        throw new Error("test command records are incomplete");

      const narrowed = await loadRealDocument(service, "cat README.md >out");
      const narrowedCommand = narrowed.commands[0];
      if (narrowedCommand === undefined)
        throw new Error("test narrowed command is incomplete");

      const corruptions: readonly Readonly<{
        label: string;
        document: ParsedShellDocument;
      }>[] = [
        {
          label: "cross-command name",
          document: {
            ...multiCommand,
            commands: [{ ...echoCommand, name: catCommand.name }, catCommand],
          },
        },
        {
          label: "cross-command argument",
          document: {
            ...multiCommand,
            commands: [
              { ...echoCommand, arguments: [catCommand.arguments[0]!] },
              catCommand,
            ],
          },
        },
        {
          label: "narrowed command span",
          document: {
            ...narrowed,
            commands: [
              {
                ...narrowedCommand,
                span: {
                  start: narrowedCommand.span.start,
                  end: narrowedCommand.name.rawSpan.end,
                },
              },
            ],
          },
        },
      ];

      for (const corruption of corruptions)
        expectParsedShellDocumentInvariant(
          service,
          corruption.document,
          corruption.label,
        );
    });

    it("validates numeric descriptor tokens against their declared source spans", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(service, "cat 12>out");
      const redirect = document.redirects[0];
      if (redirect?.kind !== "file" || redirect.descriptor?.kind !== "number")
        throw new Error("test numeric descriptor is incomplete");
      expect(() => {
        service.assertValidParsedShellDocument(document);
      }).not.toThrow();
      for (const descriptor of [
        { ...redirect.descriptor, value: "13" },
        { ...redirect.descriptor, rawSpan: { start: 5, end: 7 } },
      ]) {
        expectParsedShellDocumentInvariant(
          service,
          {
            ...document,
            redirects: [{ ...redirect, descriptor }],
          },
          "numeric descriptor corruption",
        );
      }
    });

    it("rejects header operators placed inside either adjacent quoted child", async () => {
      const service = await freshRealByteService();
      const document = await loadRealDocument(
        service,
        "cat <<EOF | sed '|' | printf '|'\nbody\nEOF",
      );
      const heredoc = document.redirects[0];
      if (
        heredoc?.kind !== "heredoc" ||
        heredoc.header.continuation?.kind !== "pipeline" ||
        heredoc.header.continuation.unit.kind !== "pipeline"
      )
        throw new Error("test header continuation is incomplete");
      const outer = heredoc.header.continuation.unit;
      const nested = outer.children[0];
      if (
        nested?.kind !== "pipeline" ||
        nested.operators.length !== 1 ||
        nested.children.length !== 2
      )
        throw new Error("test nested header pipeline is incomplete");
      const [previous, following] = nested.children;
      const previousArgument =
        previous?.kind === "command" ? previous.arguments[0] : undefined;
      const followingArgument =
        following?.kind === "command" ? following.arguments[0] : undefined;
      const operator = nested.operators[0];
      if (
        previousArgument === undefined ||
        followingArgument === undefined ||
        operator === undefined
      )
        throw new Error("test quoted header children are incomplete");

      const documentForOperatorSpan = (
        span: Readonly<{ start: number; end: number }>,
      ): ParsedShellDocument => ({
        ...document,
        redirects: [
          {
            ...heredoc,
            header: {
              ...heredoc.header,
              continuation: {
                kind: "pipeline",
                unit: {
                  ...outer,
                  children: [
                    {
                      ...nested,
                      operators: [{ ...operator, span }],
                    },
                  ],
                },
              },
            },
          },
        ],
      });

      for (const [label, word] of [
        ["preceding child", previousArgument.word],
        ["following child", followingArgument.word],
      ] as const)
        expectParsedShellDocumentInvariant(
          service,
          documentForOperatorSpan({
            start: word.rawSpan.start + 1,
            end: word.rawSpan.start + 2,
          }),
          label,
        );

      for (const source of [
        "cat <<EOF | sed x | cat\nbody\nEOF",
        "cat <<EOF && echo done\nbody\nEOF",
      ]) {
        const valid = await loadRealDocument(service, source);
        expect(() => {
          service.assertValidParsedShellDocument(valid);
        }, source).not.toThrow();
      }
    });

    it("accepts direct, prefixed, continued, CRLF, and mixed provenance controls", async () => {
      const service = await freshRealByteService();
      const controls = [
        ["direct", 'cat <"in>out" <<EOF\nbody\nEOF'],
        ["prefixed", 'env FOO=bar cat <"in>out" <<EOF\nbody\nEOF'],
        ["compound", "cd /tmp && python3 - <<EOF\nbody\nEOF"],
        ["continued", 'cat <"in>out" \\\n<<EOF\nbody\nEOF'],
        ["CRLF", 'cat <"in>out" <<EOF\r\nbody\r\nEOF'],
        ["mixed", 'cat <"in>out" 1>2 <<EOF\r\nbody\nEOF'],
        ["leading trivia", "# leading trivia\ncat <<EOF >out.py\nbody\nEOF"],
        ["file/file", "cat >out.py 2>err.log"],
        ["file/here-string", "cat <<EOF >out.py <<<input\nbody\nEOF"],
        [
          "multiple nested header redirects",
          "cat <<EOF >out.py 2>err.log\nbody\nEOF",
        ],
        ["prefix redirect", ">out.py cat <<EOF\nbody\nEOF"],
        [
          "horizontal whitespace",
          "cat > \tout.py 2> \terr.log << EOF\nbody\nEOF",
        ],
        ["LF operator payload continuation", "cat >\\\nout.py"],
        ["CRLF operator payload continuation", "cat >\\\r\nout.py"],
        ["heredoc followed by output redirect", "cat <<EOF >out.py\nbody\nEOF"],
      ] as const;

      for (const [label, source] of controls) {
        const document = await loadRealDocument(service, source);
        expect(() => {
          service.assertValidParsedShellDocument(document);
        }, label).not.toThrow();
      }
    });

    it("rejects a file redirect payload transplanted from a later redirect", async () => {
      const service = await freshRealByteService();
      const source = "cat >out.py 2>err.log <<EOF\nprint(1)\nEOF";
      const document = await loadRealDocument(service, source);
      const [firstRedirect, secondRedirect] = document.redirects;
      if (
        firstRedirect?.kind !== "file" ||
        secondRedirect?.kind !== "file" ||
        firstRedirect.destination === null ||
        secondRedirect.destination === null
      )
        throw new Error("test paired file redirects are incomplete");
      const secondDestination = secondRedirect.destination;

      expectParsedShellDocumentInvariant(
        service,
        {
          ...document,
          redirects: document.redirects.map((redirect) =>
            redirect.id === firstRedirect.id
              ? {
                  ...firstRedirect,
                  destination: secondDestination,
                  span: {
                    ...firstRedirect.span,
                    end: secondDestination.rawSpan.end,
                  },
                }
              : redirect,
          ),
        },
        "file redirect payload from its later sibling",
      );
    });

    it("rejects co-mutated redirected-statement and heredoc header starts", async () => {
      const service = await freshRealByteService();
      const source =
        "mkdir -p output\n# neighboring trivia\ncat >out.py <<EOF\nprint(1)\nEOF";
      const document = await loadRealDocument(service, source);
      const [firstUnit, secondUnit] = document.program.children;
      const heredoc = document.redirects.find(
        (redirect) => redirect.kind === "heredoc",
      );
      const commentStart = source.indexOf("# neighboring trivia");
      if (
        document.program.children.length !== 2 ||
        firstUnit?.kind !== "command" ||
        secondUnit?.kind !== "redirected_statement" ||
        heredoc === undefined ||
        commentStart < 0 ||
        secondUnit.span.start <= commentStart ||
        heredoc.headerSpan.start <= commentStart
      )
        throw new Error("test redirected statement header is incomplete");

      expectParsedShellDocumentInvariant(
        service,
        {
          ...document,
          program: {
            ...document.program,
            children: [
              firstUnit,
              {
                ...secondUnit,
                span: { ...secondUnit.span, start: commentStart },
              },
            ],
          },
          redirects: document.redirects.map((redirect) =>
            redirect.id === heredoc.id
              ? {
                  ...heredoc,
                  headerSpan: {
                    ...heredoc.headerSpan,
                    start: commentStart,
                  },
                }
              : redirect,
          ),
        },
        "co-mutated redirected statement and heredoc header starts",
      );
    });

    it("rejects redirect component transplants and heredoc header anchor changes", async () => {
      const service = await freshRealByteService();
      const quotedDestination = await loadRealDocument(
        service,
        'cat <"in>out" <<EOF\nbody\nEOF',
      );
      const quotedRedirect = quotedDestination.redirects[0];
      if (
        quotedRedirect?.kind !== "file" ||
        quotedRedirect.destination?.kind !== "literal"
      )
        throw new Error("test quoted redirect is incomplete");
      const quotedOperatorStart = quotedDestination.source.indexOf(
        ">",
        quotedRedirect.destination.rawSpan.start,
      );
      if (quotedOperatorStart < quotedRedirect.destination.rawSpan.start)
        throw new Error("test quoted destination operator is missing");
      expectParsedShellDocumentInvariant(
        service,
        {
          ...quotedDestination,
          redirects: quotedDestination.redirects.map((redirect) =>
            redirect.id === quotedRedirect.id
              ? {
                  ...quotedRedirect,
                  operator: ">",
                  operatorSpan: {
                    start: quotedOperatorStart,
                    end: quotedOperatorStart + 1,
                  },
                }
              : redirect,
          ),
        },
        "operator transplanted inside quoted destination",
      );

      const descriptorDestination = await loadRealDocument(
        service,
        "cat 1>2 <<EOF\nbody\nEOF",
      );
      const descriptorRedirect = descriptorDestination.redirects[0];
      if (descriptorRedirect?.kind !== "file")
        throw new Error("test descriptor redirect is incomplete");
      const { descriptor, destination } = descriptorRedirect;
      if (descriptor?.kind !== "number" || destination?.kind !== "literal")
        throw new Error("test descriptor redirect is incomplete");
      expect(destination.value).toBe("2");
      expect(descriptor.value).toBe("1");
      expectParsedShellDocumentInvariant(
        service,
        {
          ...descriptorDestination,
          redirects: descriptorDestination.redirects.map((redirect) =>
            redirect.id === descriptorRedirect.id
              ? {
                  ...descriptorRedirect,
                  destination: {
                    ...destination,
                    rawSpan: descriptor.rawSpan,
                    value: descriptor.value,
                    projection: {
                      ...destination.projection,
                      span: descriptor.rawSpan,
                    },
                  },
                }
              : redirect,
          ),
        },
        "destination transplanted from descriptor word",
      );

      const headerCases = [
        {
          label: "compound header shrunk to python3",
          source: "cd /tmp && python3 - <<EOF\nbody\nEOF",
          headerStart: (source: string) => source.indexOf("python3"),
        },
        {
          label: "second-command cat header widened to mkdir",
          source: "mkdir output\ncat <<EOF\nbody\nEOF",
          headerStart: (source: string) => source.indexOf("mkdir"),
        },
        {
          label: "direct cat header shrunk to the heredoc operator",
          source: "cat <<EOF\nbody\nEOF",
          headerStart: (source: string) => source.indexOf("<<"),
        },
      ] as const;
      for (const testCase of headerCases) {
        const document = await loadRealDocument(service, testCase.source);
        const heredoc = document.redirects.find(
          (redirect) => redirect.kind === "heredoc",
        );
        if (heredoc === undefined)
          throw new Error("test heredoc redirect is missing");
        const headerStart = testCase.headerStart(testCase.source);
        if (headerStart < 0 || heredoc.headerSpan.start === headerStart)
          throw new Error("test heredoc anchor is incomplete");
        expectParsedShellDocumentInvariant(
          service,
          {
            ...document,
            redirects: document.redirects.map((redirect) =>
              redirect.id === heredoc.id
                ? {
                    ...heredoc,
                    headerSpan: { ...heredoc.headerSpan, start: headerStart },
                  }
                : redirect,
            ),
          },
          testCase.label,
        );
      }
    });
  });

  it("matches every independently authored corpus row and its exact-source cache result", async () => {
    expect(shellParserCorpus).toHaveLength(25);
    const { service, treeSitter, assetRuntime } = await freshShellParser();
    const loadRuntime = vi.fn(installedTreeSitterBytes.loadRuntime);
    const loadLanguage = vi.fn(installedTreeSitterBytes.loadLanguage);
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    assetRuntime.configureTreeSitterAssets({
      kind: "bytes",
      loadRuntime,
      loadLanguage,
    });

    for (const fixture of shellParserCorpus) {
      const result = await service.loadParsedShellDocument(fixture.source);
      expectCorpusCase(result, fixture);
      expect(service.getCachedParsedShellDocument(fixture.source)).toBe(result);
      const parseCount = parse.mock.calls.length;
      expect(await service.loadParsedShellDocument(fixture.source)).toBe(
        result,
      );
      expect(parse.mock.calls.length).toBe(parseCount);

      if (fixture.name === "nested-bash-wrapper") {
        if (!fixture.expected.ok || !result.ok)
          throw new Error("nested fixture did not parse");
        const childSource =
          fixture.expected.document.embeddedInvocations[0]!.child!.source;
        const child = result.document.embeddedInvocations[0]!.child;
        expect(child?.source).toBe(childSource);
        const childParseCount = parse.mock.calls.length;
        const cachedChild = await service.loadParsedShellDocument(childSource);
        expect(cachedChild.ok).toBe(true);
        if (cachedChild.ok) expect(cachedChild.document).toBe(child);
        expect(parse.mock.calls.length).toBe(childParseCount);
      }
    }
  });
});
