import type { ParsedShellDocument } from "../shellParser";

type ParsedShellWord = ParsedShellDocument["commands"][number]["name"];
type ParsedShellNonLiteralReason = Extract<
  ParsedShellWord,
  { kind: "nonliteral" }
>["reason"];
type ParsedShellRedirectDescriptor = NonNullable<
  ParsedShellDocument["redirects"][number]["descriptor"]
>;
type ParsedShellUnit =
  | ParsedShellDocument["program"]
  | ParsedShellDocument["program"]["children"][number];
type ParsedShellDiagnostic = ParsedShellDocument["diagnostics"][number];
type ParsedShellWordSyntax = Extract<
  ParsedShellWord,
  { kind: "literal" }
>["syntax"];

export type ShellParserCorpusSpan = Readonly<{
  start: number;
  end: number;
  text: string;
}>;

export type ShellParserCorpusProjection = Readonly<{
  span: ShellParserCorpusSpan;
  points: readonly Readonly<{ child: number; parent: number }>[];
}>;

export type ShellParserCorpusWord = Readonly<{
  kind: ParsedShellWord["kind"];
  syntax: string;
  rawSpan: ShellParserCorpusSpan;
  value?: string;
  reason?: ParsedShellNonLiteralReason;
  nodeTypes?: readonly string[];
  projection?: ShellParserCorpusProjection;
}>;

export type ShellParserCorpusArgument = Readonly<{
  word: ShellParserCorpusWord;
  synthetic: boolean;
}>;

export type ShellParserCorpusAssignment = Readonly<{
  span: ShellParserCorpusSpan;
  name: string;
  nameSpan: ShellParserCorpusSpan;
  value: ShellParserCorpusWord | null;
}>;

export type ShellParserCorpusOperator = Readonly<{
  kind: "and" | "or" | "pipe" | "pipe_stderr";
  text: "&&" | "||" | "|" | "|&";
  span: ShellParserCorpusSpan;
}>;

export type ShellParserCorpusBoundary = Readonly<{
  kind: "newline" | "semicolon" | "background" | "case";
  text: "\n" | "\r\n" | ";" | "&" | ";;";
  span: ShellParserCorpusSpan;
}>;

export type ShellParserCorpusUnit = Readonly<{
  kind: ParsedShellUnit["kind"];
  span: ShellParserCorpusSpan;
  children?: readonly ShellParserCorpusUnit[];
  boundaries?: readonly ShellParserCorpusBoundary[];
  operators?: readonly ShellParserCorpusOperator[];
  body?: ShellParserCorpusUnit;
  redirectIds?: readonly number[];
  commandId?: number;
  nodeType?: string;
  reason?: "unsupported_construct" | "control_body";
  name?: ShellParserCorpusWord;
  arguments?: readonly ShellParserCorpusArgument[];
}>;

export type ShellParserCorpusCommand = Readonly<{
  id: number;
  span: ShellParserCorpusSpan;
  name: ShellParserCorpusWord;
  assignments: readonly ShellParserCorpusAssignment[];
  arguments: readonly ShellParserCorpusArgument[];
  redirectIds: readonly number[];
}>;

export type ShellParserCorpusRedirect = Readonly<{
  kind: "file" | "herestring" | "heredoc";
  id: number;
  ownerId: number;
  span: ShellParserCorpusSpan;
  operator?: string;
  operatorSpan: ShellParserCorpusSpan;
  descriptor?: ShellParserCorpusDescriptor | null;
  destination?: ShellParserCorpusWord | null;
  value?: ShellParserCorpusWord;
  headerSpan?: ShellParserCorpusSpan;
  headerLineBreakSpan?: ShellParserCorpusSpan;
  delimiter?: Readonly<{
    value: string;
    rawSpan: ShellParserCorpusSpan;
    quoted: boolean;
  }>;
  rawBodySpan?: ShellParserCorpusSpan;
  contentSpan?: ShellParserCorpusSpan;
  terminatorSpan?: ShellParserCorpusSpan;
  nestedRedirectIds?: readonly number[];
  header?: Readonly<{
    arguments: readonly ShellParserCorpusArgument[];
    continuation: ShellParserCorpusUnit | null;
    continuationOperator?: ShellParserCorpusOperator;
  }>;
}>;

export type ShellParserCorpusDescriptor = Readonly<{
  kind: ParsedShellRedirectDescriptor["kind"];
  value?: string;
  name?: string;
  rawSpan: ShellParserCorpusSpan;
  nameSpan?: ShellParserCorpusSpan;
}> | null;

export type ShellParserCorpusInvocation = Readonly<{
  kind: "inline" | "heredoc";
  id: number;
  commandId: number;
  prefix:
    | Readonly<{ kind: "direct" }>
    | Readonly<{
        kind: "env";
        assignments: readonly Readonly<{
          argumentIndex: number;
          name: string;
          value: string;
        }>[];
      }>;
  interpreter: Readonly<{
    location:
      | Readonly<{ kind: "command_name" }>
      | Readonly<{ kind: "argument"; index: number }>;
    basename: string;
    language: string;
  }>;
  optionArgumentIndices: readonly number[];
  payload: Readonly<{
    text: string;
    rawSpan: ShellParserCorpusSpan;
    contentSpan: ShellParserCorpusSpan;
    projection: ShellParserCorpusProjection;
  }>;
  flagArgumentIndex?: number;
  payloadArgumentIndex?: number;
  heredocRedirectId?: number;
  stdinArgumentIndex?: number | null;
  child?: ShellParserCorpusDocument | null;
}>;

export type ShellParserCorpusDiagnostic = Readonly<{
  kind: ParsedShellDiagnostic["kind"];
  span: ShellParserCorpusSpan;
  operator?: "||" | "|&" | "&" | ";;";
  nodeType?: string;
  issue?: string;
}>;

export type ShellParserCorpusDocument = Readonly<{
  source: string;
  program: ShellParserCorpusUnit;
  commands: readonly ShellParserCorpusCommand[];
  redirects: readonly ShellParserCorpusRedirect[];
  embeddedInvocations: readonly ShellParserCorpusInvocation[];
  diagnostics: readonly ShellParserCorpusDiagnostic[];
}>;

export type ShellParserCorpusCase = Readonly<{
  name: string;
  source: string;
  expected:
    | Readonly<{ ok: true; document: ShellParserCorpusDocument }>
    | Readonly<{
        ok: false;
        reason: "unsafe_shell_syntax" | "invalid_heredoc";
        issue: string;
        span: ShellParserCorpusSpan;
      }>;
}>;

const span = (
  start: number,
  end: number,
  text: string,
): ShellParserCorpusSpan => ({
  start,
  end,
  text,
});

const projection = (
  rawSpan: ShellParserCorpusSpan,
  points: readonly Readonly<{ child: number; parent: number }>[],
  projectionSpan = rawSpan,
): ShellParserCorpusProjection => ({
  span: projectionSpan,
  points,
});

const linearPoints = (
  length: number,
): readonly Readonly<{ child: number; parent: number }>[] => [
  { child: 0, parent: 0 },
  { child: length, parent: length },
];

const literal = (
  start: number,
  end: number,
  rawText: string,
  value: string,
  syntax: ParsedShellWordSyntax = "word",
  points = linearPoints(value.length),
  projectionSpan = span(start, end, rawText),
): ShellParserCorpusWord => ({
  kind: "literal",
  syntax,
  rawSpan: span(start, end, rawText),
  value,
  projection: projection(span(start, end, rawText), points, projectionSpan),
});

const nonliteral = (
  start: number,
  end: number,
  rawText: string,
  syntax: string,
  reason: ParsedShellNonLiteralReason,
  nodeTypes: readonly string[] = [],
): ShellParserCorpusWord => ({
  kind: "nonliteral",
  syntax,
  rawSpan: span(start, end, rawText),
  reason,
  nodeTypes,
});

const argument = (
  word: ShellParserCorpusWord,
  synthetic = false,
): ShellParserCorpusArgument => ({ word, synthetic });

const commandUnit = (
  start: number,
  end: number,
  text: string,
  commandId: number,
): ShellParserCorpusUnit => ({
  kind: "command",
  span: span(start, end, text),
  commandId,
});

const command = (
  id: number,
  start: number,
  end: number,
  text: string,
  name: ShellParserCorpusWord,
  args: readonly ShellParserCorpusArgument[] = [],
  redirectIds: readonly number[] = [],
  assignments: readonly ShellParserCorpusAssignment[] = [],
): ShellParserCorpusCommand => ({
  id,
  span: span(start, end, text),
  name,
  assignments,
  arguments: args,
  redirectIds,
});

const operator = (
  kind: ShellParserCorpusOperator["kind"],
  text: ShellParserCorpusOperator["text"],
  start: number,
  end: number,
): ShellParserCorpusOperator => ({
  kind,
  text,
  span: span(start, end, text),
});

const boundary = (
  kind: ShellParserCorpusBoundary["kind"],
  text: ShellParserCorpusBoundary["text"],
  start: number,
  end: number,
): ShellParserCorpusBoundary => ({
  kind,
  text,
  span: span(start, end, text),
});

const program = (
  sourceText: string,
  children: readonly ShellParserCorpusUnit[],
  boundaries: readonly ShellParserCorpusBoundary[] = [],
): ShellParserCorpusUnit => ({
  kind: "program",
  span: span(0, sourceText.length, sourceText),
  children,
  boundaries,
});

const list = (
  start: number,
  end: number,
  text: string,
  children: readonly ShellParserCorpusUnit[],
  operators: readonly ShellParserCorpusOperator[],
): ShellParserCorpusUnit => ({
  kind: "list",
  span: span(start, end, text),
  children,
  operators,
});

const pipeline = (
  start: number,
  end: number,
  text: string,
  children: readonly ShellParserCorpusUnit[],
  operators: readonly ShellParserCorpusOperator[],
): ShellParserCorpusUnit => ({
  kind: "pipeline",
  span: span(start, end, text),
  children,
  operators,
});

const redirected = (
  start: number,
  end: number,
  text: string,
  body: ShellParserCorpusUnit,
  redirectIds: readonly number[],
): ShellParserCorpusUnit => ({
  kind: "redirected_statement",
  span: span(start, end, text),
  body,
  redirectIds,
});

const headerCommand = (
  start: number,
  end: number,
  text: string,
  name: ShellParserCorpusWord,
  args: readonly ShellParserCorpusArgument[] = [],
): ShellParserCorpusUnit => ({
  kind: "command",
  span: span(start, end, text),
  name,
  arguments: args,
});

const fileRedirect = (
  id: number,
  ownerId: number,
  start: number,
  end: number,
  text: string,
  operatorText: string,
  operatorStart: number,
  operatorEnd: number,
  destination: ShellParserCorpusWord | null,
  descriptor: ShellParserCorpusDescriptor = null,
): ShellParserCorpusRedirect => ({
  kind: "file",
  id,
  ownerId,
  span: span(start, end, text),
  operator: operatorText,
  operatorSpan: span(operatorStart, operatorEnd, operatorText),
  descriptor,
  destination,
});

const heredoc = (
  id: number,
  ownerId: number,
  start: number,
  end: number,
  text: string,
  operatorStart: number,
  operatorText: "<<" | "<<-",
  headerStart: number,
  headerEnd: number,
  headerText: string,
  lineBreakStart: number,
  lineBreakEnd: number,
  lineBreakText: "\n" | "\r\n",
  rawBodyStart: number,
  rawBodyEnd: number,
  rawBodyText: string,
  contentEnd: number,
  contentText: string,
  terminatorStart: number,
  terminatorEnd: number,
  terminatorText: string,
  delimiterStart: number,
  delimiterEnd: number,
  delimiterText: string,
  delimiterValue: string,
  quoted: boolean,
  headerArguments: readonly ShellParserCorpusArgument[] = [],
  continuation: ShellParserCorpusUnit | null = null,
  continuationOperator?: ShellParserCorpusOperator,
  nestedRedirectIds: readonly number[] = [],
): ShellParserCorpusRedirect => ({
  kind: "heredoc",
  id,
  ownerId,
  span: span(start, end, text),
  operator: operatorText,
  operatorSpan: span(
    operatorStart,
    operatorStart + operatorText.length,
    operatorText,
  ),
  descriptor: null,
  headerSpan: span(headerStart, headerEnd, headerText),
  headerLineBreakSpan: span(lineBreakStart, lineBreakEnd, lineBreakText),
  delimiter: {
    value: delimiterValue,
    rawSpan: span(delimiterStart, delimiterEnd, delimiterText),
    quoted,
  },
  rawBodySpan: span(rawBodyStart, rawBodyEnd, rawBodyText),
  contentSpan: span(rawBodyStart, contentEnd, contentText),
  terminatorSpan: span(terminatorStart, terminatorEnd, terminatorText),
  header: {
    arguments: headerArguments,
    continuation,
    continuationOperator,
  },
  nestedRedirectIds,
});

const document = (
  source: string,
  programUnit: ShellParserCorpusUnit,
  commands: readonly ShellParserCorpusCommand[],
  redirects: readonly ShellParserCorpusRedirect[] = [],
  embeddedInvocations: readonly ShellParserCorpusInvocation[] = [],
  diagnostics: readonly ShellParserCorpusDiagnostic[] = [],
): ShellParserCorpusDocument => ({
  source,
  program: programUnit,
  commands,
  redirects,
  embeddedInvocations,
  diagnostics,
});

const direct = { kind: "direct" as const };

const inlinePayload = (
  text: string,
  rawSpan: ShellParserCorpusSpan,
  contentSpan: ShellParserCorpusSpan,
  points: readonly Readonly<{ child: number; parent: number }>[],
): ShellParserCorpusInvocation["payload"] => ({
  text,
  rawSpan,
  contentSpan,
  projection: projection(rawSpan, points, contentSpan),
});

const canonicalSource =
  "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
const canonicalProgram = program(
  canonicalSource,
  [
    redirected(
      0,
      41,
      "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF",
      list(
        0,
        18,
        "cd /tmp && python3",
        [commandUnit(0, 7, "cd /tmp", 0), commandUnit(11, 18, "python3", 1)],
        [operator("and", "&&", 8, 10)],
      ),
      [0],
    ),
    pipeline(
      42,
      56,
      "git diff | cat",
      [commandUnit(42, 50, "git diff", 2), commandUnit(53, 56, "cat", 3)],
      [operator("pipe", "|", 51, 52)],
    ),
  ],
  [boundary("newline", "\n", 41, 42)],
);

const canonicalDocument = document(
  canonicalSource,
  canonicalProgram,
  [
    command(0, 0, 7, "cd /tmp", literal(0, 2, "cd", "cd"), [
      argument(literal(3, 7, "/tmp", "/tmp")),
    ]),
    command(
      1,
      11,
      18,
      "python3",
      literal(11, 18, "python3", "python3"),
      [argument(literal(19, 20, "-", "-", "synthetic"), true)],
      [0],
    ),
    command(2, 42, 50, "git diff", literal(42, 45, "git", "git"), [
      argument(literal(46, 50, "diff", "diff")),
    ]),
    command(3, 53, 56, "cat", literal(53, 56, "cat", "cat")),
  ],
  [
    heredoc(
      0,
      1,
      21,
      41,
      "<<'EOF'\nprint(1)\nEOF",
      21,
      "<<",
      0,
      28,
      "cd /tmp && python3 - <<'EOF'",
      28,
      29,
      "\n",
      29,
      38,
      "print(1)\n",
      37,
      "print(1)",
      38,
      41,
      "EOF",
      23,
      28,
      "'EOF'",
      "EOF",
      true,
    ),
  ],
  [
    {
      kind: "heredoc",
      id: 0,
      commandId: 1,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload(
        "print(1)",
        span(29, 38, "print(1)\n"),
        span(29, 37, "print(1)"),
        [
          { child: 0, parent: 0 },
          { child: 8, parent: 8 },
        ],
      ),
      heredocRedirectId: 0,
      stdinArgumentIndex: 0,
      child: null,
    },
  ],
);

const redirectTopologySource = "cat >out <<EOF >copy\nbody\nEOF";
const redirectTopologyProgram = program(redirectTopologySource, [
  redirected(
    0,
    redirectTopologySource.length,
    redirectTopologySource,
    commandUnit(0, 3, "cat", 0),
    [0, 1],
  ),
]);

const redirectTopologyDocument = document(
  redirectTopologySource,
  redirectTopologyProgram,
  [command(0, 0, 3, "cat", literal(0, 3, "cat", "cat"), [], [0, 1, 2])],
  [
    fileRedirect(0, 0, 4, 8, ">out", ">", 4, 5, literal(5, 8, "out", "out")),
    heredoc(
      1,
      0,
      9,
      29,
      "<<EOF >copy\nbody\nEOF",
      9,
      "<<",
      0,
      20,
      "cat >out <<EOF >copy",
      20,
      21,
      "\n",
      21,
      26,
      "body\n",
      25,
      "body",
      26,
      29,
      "EOF",
      11,
      14,
      "EOF",
      "EOF",
      false,
      [],
      null,
      undefined,
      [2],
    ),
    fileRedirect(
      2,
      0,
      15,
      20,
      ">copy",
      ">",
      15,
      16,
      literal(16, 20, "copy", "copy"),
    ),
  ],
);

const herestringSource = 'cat <<<"$x"';
const herestringDocument = document(
  herestringSource,
  program(herestringSource, [commandUnit(0, 11, herestringSource, 0)]),
  [command(0, 0, 11, herestringSource, literal(0, 3, "cat", "cat"), [], [0])],
  [
    {
      kind: "herestring",
      id: 0,
      ownerId: 0,
      span: span(4, 11, '<<<"$x"'),
      operator: "<<<",
      operatorSpan: span(4, 7, "<<<"),
      descriptor: null,
      value: nonliteral(7, 11, '"$x"', "string", "dynamic_child", [
        "simple_expansion",
      ]),
    },
  ],
);

const newlinePipelineSource = "a\nb; c && d | e | f";
const newlinePipelineDocument = document(
  newlinePipelineSource,
  program(
    newlinePipelineSource,
    [
      commandUnit(0, 1, "a", 0),
      commandUnit(2, 3, "b", 1),
      list(
        5,
        19,
        "c && d | e | f",
        [
          commandUnit(5, 6, "c", 2),
          pipeline(
            10,
            19,
            "d | e | f",
            [
              commandUnit(10, 11, "d", 3),
              commandUnit(14, 15, "e", 4),
              commandUnit(18, 19, "f", 5),
            ],
            [operator("pipe", "|", 12, 13), operator("pipe", "|", 16, 17)],
          ),
        ],
        [operator("and", "&&", 7, 9)],
      ),
    ],
    [boundary("newline", "\n", 1, 2), boundary("semicolon", ";", 3, 4)],
  ),
  [
    command(0, 0, 1, "a", literal(0, 1, "a", "a")),
    command(1, 2, 3, "b", literal(2, 3, "b", "b")),
    command(2, 5, 6, "c", literal(5, 6, "c", "c")),
    command(3, 10, 11, "d", literal(10, 11, "d", "d")),
    command(4, 14, 15, "e", literal(14, 15, "e", "e")),
    command(5, 18, 19, "f", literal(18, 19, "f", "f")),
  ],
);

const heredocPipelineSource = "cat <<EOF | sed x | cat\nbody\nEOF";
const heredocPipelineDocument = document(
  heredocPipelineSource,
  program(heredocPipelineSource, [
    redirected(
      0,
      32,
      "cat <<EOF | sed x | cat\nbody\nEOF",
      commandUnit(0, 3, "cat", 0),
      [0],
    ),
  ]),
  [command(0, 0, 3, "cat", literal(0, 3, "cat", "cat"), [], [0])],
  [
    heredoc(
      0,
      0,
      4,
      32,
      "<<EOF | sed x | cat\nbody\nEOF",
      4,
      "<<",
      0,
      23,
      "cat <<EOF | sed x | cat",
      23,
      24,
      "\n",
      24,
      29,
      "body\n",
      28,
      "body",
      29,
      32,
      "EOF",
      6,
      9,
      "EOF",
      "EOF",
      false,
      [],
      pipeline(
        10,
        23,
        "| sed x | cat",
        [
          pipeline(
            12,
            23,
            "sed x | cat",
            [
              headerCommand(12, 17, "sed x", literal(12, 15, "sed", "sed"), [
                argument(literal(16, 17, "x", "x")),
              ]),
              headerCommand(20, 23, "cat", literal(20, 23, "cat", "cat")),
            ],
            [operator("pipe", "|", 18, 19)],
          ),
        ],
        [operator("pipe", "|", 10, 11)],
      ),
    ),
  ],
);

const heredocArgsSource = "cat <<EOF echo a b\nbody\nEOF";
const heredocArgsDocument = document(
  heredocArgsSource,
  program(heredocArgsSource, [
    redirected(0, 27, heredocArgsSource, commandUnit(0, 3, "cat", 0), [0]),
  ]),
  [command(0, 0, 3, "cat", literal(0, 3, "cat", "cat"), [], [0])],
  [
    heredoc(
      0,
      0,
      4,
      27,
      "<<EOF echo a b\nbody\nEOF",
      4,
      "<<",
      0,
      18,
      "cat <<EOF echo a b",
      18,
      19,
      "\n",
      19,
      24,
      "body\n",
      23,
      "body",
      24,
      27,
      "EOF",
      6,
      9,
      "EOF",
      "EOF",
      false,
      [
        argument(literal(10, 14, "echo", "echo")),
        argument(literal(15, 16, "a", "a")),
        argument(literal(17, 18, "b", "b")),
      ],
    ),
  ],
  [],
  [
    {
      kind: "unsupported_heredoc_header",
      span: span(10, 18, "echo a b"),
      issue: "arguments",
    },
  ],
);

const heredocRightSource = "cat <<EOF && echo done\nbody\nEOF";
const heredocRightDocument = document(
  heredocRightSource,
  program(heredocRightSource, [
    redirected(0, 31, heredocRightSource, commandUnit(0, 3, "cat", 0), [0]),
  ]),
  [command(0, 0, 3, "cat", literal(0, 3, "cat", "cat"), [], [0])],
  [
    heredoc(
      0,
      0,
      4,
      31,
      "<<EOF && echo done\nbody\nEOF",
      4,
      "<<",
      0,
      22,
      "cat <<EOF && echo done",
      22,
      23,
      "\n",
      23,
      28,
      "body\n",
      27,
      "body",
      28,
      31,
      "EOF",
      6,
      9,
      "EOF",
      "EOF",
      false,
      [],
      headerCommand(13, 22, "echo done", literal(13, 17, "echo", "echo"), [
        argument(literal(18, 22, "done", "done")),
      ]),
      operator("and", "&&", 10, 12),
    ),
  ],
  [],
  [
    {
      kind: "unsupported_heredoc_header",
      span: span(13, 22, "echo done"),
      issue: "right",
    },
  ],
);

const controlsSource = "echo a || echo b\na |& b";
const controlsDocument = document(
  controlsSource,
  program(
    controlsSource,
    [
      list(
        0,
        16,
        "echo a || echo b",
        [commandUnit(0, 6, "echo a", 0), commandUnit(10, 16, "echo b", 1)],
        [operator("or", "||", 7, 9)],
      ),
      pipeline(
        17,
        23,
        "a |& b",
        [commandUnit(17, 18, "a", 2), commandUnit(22, 23, "b", 3)],
        [operator("pipe_stderr", "|&", 19, 21)],
      ),
    ],
    [boundary("newline", "\n", 16, 17)],
  ),
  [
    command(0, 0, 6, "echo a", literal(0, 4, "echo", "echo"), [
      argument(literal(5, 6, "a", "a")),
    ]),
    command(1, 10, 16, "echo b", literal(10, 14, "echo", "echo"), [
      argument(literal(15, 16, "b", "b")),
    ]),
    command(2, 17, 18, "a", literal(17, 18, "a", "a")),
    command(3, 22, 23, "b", literal(22, 23, "b", "b")),
  ],
  [],
  [],
  [
    { kind: "unsupported_control", span: span(7, 9, "||"), operator: "||" },
    { kind: "unsupported_control", span: span(19, 21, "|&"), operator: "|&" },
  ],
);

const pythonInlineSource = "python3 -c 'print(☃)'";
const pythonInlineDocument = document(
  pythonInlineSource,
  program(pythonInlineSource, [commandUnit(0, 21, pythonInlineSource, 0)]),
  [
    command(0, 0, 21, pythonInlineSource, literal(0, 7, "python3", "python3"), [
      argument(literal(8, 10, "-c", "-c")),
      argument(
        literal(
          11,
          21,
          "'print(☃)'",
          "print(☃)",
          "raw_string",
          [
            { child: 0, parent: 0 },
            { child: 8, parent: 8 },
          ],
          span(12, 20, "print(☃)"),
        ),
      ),
    ]),
  ],
  [],
  [
    {
      kind: "inline",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload(
        "print(☃)",
        span(11, 21, "'print(☃)'"),
        span(12, 20, "print(☃)"),
        [
          { child: 0, parent: 0 },
          { child: 8, parent: 8 },
        ],
      ),
      flagArgumentIndex: 0,
      payloadArgumentIndex: 1,
      child: null,
    },
  ],
);

const nestedGrandchild: ShellParserCorpusDocument = document(
  "echo hi",
  program("echo hi", [commandUnit(0, 7, "echo hi", 0)]),
  [
    command(0, 0, 7, "echo hi", literal(0, 4, "echo", "echo"), [
      argument(literal(5, 7, "hi", "hi")),
    ]),
  ],
);

const nestedChild: ShellParserCorpusDocument = document(
  'bash -c "echo hi"',
  program('bash -c "echo hi"', [commandUnit(0, 17, 'bash -c "echo hi"', 0)]),
  [
    command(0, 0, 17, 'bash -c "echo hi"', literal(0, 4, "bash", "bash"), [
      argument(literal(5, 7, "-c", "-c")),
      argument(
        literal(
          8,
          17,
          '"echo hi"',
          "echo hi",
          "string",
          [
            { child: 0, parent: 0 },
            { child: 7, parent: 7 },
          ],
          span(9, 16, "echo hi"),
        ),
      ),
    ]),
  ],
  [],
  [
    {
      kind: "inline",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "bash",
        language: "bash",
      },
      optionArgumentIndices: [],
      payload: inlinePayload(
        "echo hi",
        span(8, 17, '"echo hi"'),
        span(9, 16, "echo hi"),
        [
          { child: 0, parent: 0 },
          { child: 7, parent: 7 },
        ],
      ),
      flagArgumentIndex: 0,
      payloadArgumentIndex: 1,
      child: nestedGrandchild,
    },
  ],
);

const nestedSource = "bash -c 'bash -c \"echo hi\"'";
const nestedDocument = document(
  nestedSource,
  program(nestedSource, [commandUnit(0, 27, nestedSource, 0)]),
  [
    command(0, 0, 27, nestedSource, literal(0, 4, "bash", "bash"), [
      argument(literal(5, 7, "-c", "-c")),
      argument(
        literal(
          8,
          27,
          "'bash -c \"echo hi\"'",
          'bash -c "echo hi"',
          "raw_string",
          [
            { child: 0, parent: 0 },
            { child: 17, parent: 17 },
          ],
          span(9, 26, 'bash -c "echo hi"'),
        ),
      ),
    ]),
  ],
  [],
  [
    {
      kind: "inline",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "bash",
        language: "bash",
      },
      optionArgumentIndices: [],
      payload: inlinePayload(
        'bash -c "echo hi"',
        span(8, 27, "'bash -c \"echo hi\"'"),
        span(9, 26, 'bash -c "echo hi"'),
        [
          { child: 0, parent: 0 },
          { child: 17, parent: 17 },
        ],
      ),
      flagArgumentIndex: 0,
      payloadArgumentIndex: 1,
      child: nestedChild,
    },
  ],
);

const emptyWrapperSource = 'zsh -lc ""';
const emptyWrapperDocument = document(
  emptyWrapperSource,
  program(emptyWrapperSource, [commandUnit(0, 10, emptyWrapperSource, 0)]),
  [
    command(0, 0, 10, emptyWrapperSource, literal(0, 3, "zsh", "zsh"), [
      argument(literal(4, 7, "-lc", "-lc")),
      argument(
        literal(
          8,
          10,
          '""',
          "",
          "string",
          [{ child: 0, parent: 0 }],
          span(9, 9, ""),
        ),
      ),
    ]),
  ],
  [],
  [
    {
      kind: "inline",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "zsh",
        language: "bash",
      },
      optionArgumentIndices: [],
      payload: inlinePayload("", span(8, 10, '""'), span(9, 9, ""), [
        { child: 0, parent: 0 },
      ]),
      flagArgumentIndex: 0,
      payloadArgumentIndex: 1,
      child: document("", program("", []), []),
    },
  ],
);

const concatenationSource = "echo a'b'\"c\"d";
const concatenationDocument = document(
  concatenationSource,
  program(concatenationSource, [commandUnit(0, 13, concatenationSource, 0)]),
  [
    command(0, 0, 13, concatenationSource, literal(0, 4, "echo", "echo"), [
      argument(
        literal(5, 13, "a'b'\"c\"d", "abcd", "concatenation", [
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
          { child: 2, parent: 3 },
          { child: 3, parent: 6 },
          { child: 4, parent: 8 },
        ]),
      ),
    ]),
  ],
);

const envLiteralSource = "env FOO=1 python3 - <<EOF\nx\nEOF";
const envLiteralDocument = document(
  envLiteralSource,
  program(envLiteralSource, [
    redirected(
      0,
      31,
      envLiteralSource,
      commandUnit(0, 17, "env FOO=1 python3", 0),
      [0],
    ),
  ]),
  [
    command(
      0,
      0,
      17,
      "env FOO=1 python3",
      literal(0, 3, "env", "env"),
      [
        argument(literal(4, 9, "FOO=1", "FOO=1")),
        argument(literal(10, 17, "python3", "python3")),
        argument(literal(18, 19, "-", "-", "synthetic"), true),
      ],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      20,
      31,
      "<<EOF\nx\nEOF",
      20,
      "<<",
      0,
      25,
      "env FOO=1 python3 - <<EOF",
      25,
      26,
      "\n",
      26,
      28,
      "x\n",
      27,
      "x",
      28,
      31,
      "EOF",
      22,
      25,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [
    {
      kind: "heredoc",
      id: 0,
      commandId: 0,
      prefix: {
        kind: "env",
        assignments: [{ argumentIndex: 0, name: "FOO", value: "1" }],
      },
      interpreter: {
        location: { kind: "argument", index: 1 },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload("x", span(26, 28, "x\n"), span(26, 27, "x"), [
        { child: 0, parent: 0 },
        { child: 1, parent: 1 },
      ]),
      heredocRedirectId: 0,
      stdinArgumentIndex: 2,
      child: null,
    },
  ],
);

const envOptionSource = "env -i python3 - <<EOF\nx\nEOF";
const envOptionDocument = document(
  envOptionSource,
  program(envOptionSource, [
    redirected(
      0,
      28,
      envOptionSource,
      commandUnit(0, 14, "env -i python3", 0),
      [0],
    ),
  ]),
  [
    command(
      0,
      0,
      14,
      "env -i python3",
      literal(0, 3, "env", "env"),
      [
        argument(literal(4, 6, "-i", "-i")),
        argument(literal(7, 14, "python3", "python3")),
      ],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      17,
      28,
      "<<EOF\nx\nEOF",
      17,
      "<<",
      0,
      22,
      "env -i python3 - <<EOF",
      22,
      23,
      "\n",
      23,
      25,
      "x\n",
      24,
      "x",
      25,
      28,
      "EOF",
      19,
      22,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [],
  [{ kind: "unsupported_env", span: span(4, 6, "-i"), issue: "option" }],
);

const envDynamicSource = 'env FOO="$x" python3 - <<EOF\nx\nEOF';
const envDynamicDocument = document(
  envDynamicSource,
  program(envDynamicSource, [
    redirected(
      0,
      34,
      envDynamicSource,
      commandUnit(0, 20, 'env FOO="$x" python3', 0),
      [0],
    ),
  ]),
  [
    command(
      0,
      0,
      20,
      'env FOO="$x" python3',
      literal(0, 3, "env", "env"),
      [
        argument(
          nonliteral(4, 12, 'FOO="$x"', "concatenation", "dynamic_child", [
            "simple_expansion",
          ]),
        ),
        argument(literal(13, 20, "python3", "python3")),
      ],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      23,
      34,
      "<<EOF\nx\nEOF",
      23,
      "<<",
      0,
      28,
      'env FOO="$x" python3 - <<EOF',
      28,
      29,
      "\n",
      29,
      31,
      "x\n",
      30,
      "x",
      31,
      34,
      "EOF",
      25,
      28,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [],
  [
    {
      kind: "unsupported_env",
      span: span(4, 12, 'FOO="$x"'),
      issue: "dynamic_assignment",
    },
  ],
);

const envMissingSource = "env FOO=1 <<EOF\nx\nEOF";
const envMissingDocument = document(
  envMissingSource,
  program(envMissingSource, [
    redirected(0, 21, envMissingSource, commandUnit(0, 9, "env FOO=1", 0), [0]),
  ]),
  [
    command(
      0,
      0,
      9,
      "env FOO=1",
      literal(0, 3, "env", "env"),
      [argument(literal(4, 9, "FOO=1", "FOO=1"))],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      10,
      21,
      "<<EOF\nx\nEOF",
      10,
      "<<",
      0,
      15,
      "env FOO=1 <<EOF",
      15,
      16,
      "\n",
      16,
      18,
      "x\n",
      17,
      "x",
      18,
      21,
      "EOF",
      12,
      15,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [],
  [
    {
      kind: "unsupported_env",
      span: span(0, 9, "env FOO=1"),
      issue: "missing_interpreter",
    },
  ],
);

const envUnknownSource = "env FOO=1 mystic - <<EOF\nx\nEOF";
const envUnknownDocument = document(
  envUnknownSource,
  program(envUnknownSource, [
    redirected(
      0,
      30,
      envUnknownSource,
      commandUnit(0, 16, "env FOO=1 mystic", 0),
      [0],
    ),
  ]),
  [
    command(
      0,
      0,
      16,
      "env FOO=1 mystic",
      literal(0, 3, "env", "env"),
      [
        argument(literal(4, 9, "FOO=1", "FOO=1")),
        argument(literal(10, 16, "mystic", "mystic")),
      ],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      19,
      30,
      "<<EOF\nx\nEOF",
      19,
      "<<",
      0,
      24,
      "env FOO=1 mystic - <<EOF",
      24,
      25,
      "\n",
      25,
      27,
      "x\n",
      26,
      "x",
      27,
      30,
      "EOF",
      21,
      24,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [],
  [
    {
      kind: "unsupported_env",
      span: span(10, 16, "mystic"),
      issue: "unknown_interpreter",
    },
  ],
);

const dashPositiveSource = "python3 \t- \t<<EOF\nx\nEOF";
const dashPositiveDocument = document(
  dashPositiveSource,
  program(dashPositiveSource, [
    redirected(0, 23, dashPositiveSource, commandUnit(0, 7, "python3", 0), [0]),
  ]),
  [
    command(
      0,
      0,
      7,
      "python3",
      literal(0, 7, "python3", "python3"),
      [argument(literal(9, 10, "-", "-", "synthetic"), true)],
      [0],
    ),
  ],
  [
    heredoc(
      0,
      0,
      12,
      23,
      "<<EOF\nx\nEOF",
      12,
      "<<",
      0,
      17,
      "python3 \t- \t<<EOF",
      17,
      18,
      "\n",
      18,
      20,
      "x\n",
      19,
      "x",
      20,
      23,
      "EOF",
      14,
      17,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [
    {
      kind: "heredoc",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload("x", span(18, 20, "x\n"), span(18, 19, "x"), [
        { child: 0, parent: 0 },
        { child: 1, parent: 1 },
      ]),
      heredocRedirectId: 0,
      stdinArgumentIndex: 0,
      child: null,
    },
  ],
);

const dashRedirectSource = "python3 > xyz <<EOF\nx\nEOF";
const dashRedirectDocument = document(
  dashRedirectSource,
  program(dashRedirectSource, [
    redirected(
      0,
      25,
      dashRedirectSource,
      commandUnit(0, 7, "python3", 0),
      [0, 1],
    ),
  ]),
  [
    command(
      0,
      0,
      7,
      "python3",
      literal(0, 7, "python3", "python3"),
      [],
      [0, 1],
    ),
  ],
  [
    fileRedirect(
      0,
      0,
      8,
      13,
      "> xyz",
      ">",
      8,
      9,
      literal(10, 13, "xyz", "xyz"),
    ),
    heredoc(
      1,
      0,
      14,
      25,
      "<<EOF\nx\nEOF",
      14,
      "<<",
      0,
      19,
      "python3 > xyz <<EOF",
      19,
      20,
      "\n",
      20,
      22,
      "x\n",
      21,
      "x",
      22,
      25,
      "EOF",
      16,
      19,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [
    {
      kind: "heredoc",
      id: 0,
      commandId: 0,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload("x", span(20, 22, "x\n"), span(20, 21, "x"), [
        { child: 0, parent: 0 },
        { child: 1, parent: 1 },
      ]),
      heredocRedirectId: 1,
      stdinArgumentIndex: null,
      child: null,
    },
  ],
);

const bodyOpacitySource =
  "cat <<EOF\nbody && ; |\nEOF\npython3 -c 'print(☃)' && echo 😀";
const bodyOpacityDocument = document(
  bodyOpacitySource,
  program(
    bodyOpacitySource,
    [
      redirected(
        0,
        25,
        "cat <<EOF\nbody && ; |\nEOF",
        commandUnit(0, 3, "cat", 0),
        [0],
      ),
      list(
        26,
        58,
        "python3 -c 'print(☃)' && echo 😀",
        [
          commandUnit(26, 47, "python3 -c 'print(☃)'", 1),
          commandUnit(51, 58, "echo 😀", 2),
        ],
        [operator("and", "&&", 48, 50)],
      ),
    ],
    [boundary("newline", "\n", 25, 26)],
  ),
  [
    command(0, 0, 3, "cat", literal(0, 3, "cat", "cat"), [], [0]),
    command(
      1,
      26,
      47,
      "python3 -c 'print(☃)'",
      literal(26, 33, "python3", "python3"),
      [
        argument(literal(34, 36, "-c", "-c")),
        argument(
          literal(
            37,
            47,
            "'print(☃)'",
            "print(☃)",
            "raw_string",
            [
              { child: 0, parent: 0 },
              { child: 8, parent: 8 },
            ],
            span(38, 46, "print(☃)"),
          ),
        ),
      ],
    ),
    command(2, 51, 58, "echo 😀", literal(51, 55, "echo", "echo"), [
      argument(literal(56, 58, "😀", "😀")),
    ]),
  ],
  [
    heredoc(
      0,
      0,
      4,
      25,
      "<<EOF\nbody && ; |\nEOF",
      4,
      "<<",
      0,
      9,
      "cat <<EOF",
      9,
      10,
      "\n",
      10,
      22,
      "body && ; |\n",
      21,
      "body && ; |",
      22,
      25,
      "EOF",
      6,
      9,
      "EOF",
      "EOF",
      false,
    ),
  ],
  [
    {
      kind: "inline",
      id: 0,
      commandId: 1,
      prefix: direct,
      interpreter: {
        location: { kind: "command_name" },
        basename: "python3",
        language: "python",
      },
      optionArgumentIndices: [],
      payload: inlinePayload(
        "print(☃)",
        span(37, 47, "'print(☃)'"),
        span(38, 46, "print(☃)"),
        [
          { child: 0, parent: 0 },
          { child: 8, parent: 8 },
        ],
      ),
      flagArgumentIndex: 0,
      payloadArgumentIndex: 1,
      child: null,
    },
  ],
);

const dynamicWrapperSource = 'bash -c "echo $HOME"';
const dynamicWrapperDocument = document(
  dynamicWrapperSource,
  program(dynamicWrapperSource, [commandUnit(0, 20, dynamicWrapperSource, 0)]),
  [
    command(0, 0, 20, dynamicWrapperSource, literal(0, 4, "bash", "bash"), [
      argument(literal(5, 7, "-c", "-c")),
      argument(
        nonliteral(8, 20, '"echo $HOME"', "string", "dynamic_child", [
          "simple_expansion",
        ]),
      ),
    ]),
  ],
  [],
  [],
  [
    {
      kind: "unsupported_wrapper",
      span: span(8, 20, '"echo $HOME"'),
      issue: "dynamic_payload",
    },
  ],
);

export const shellParserCorpus: readonly ShellParserCorpusCase[] = [
  {
    name: "canonical-mixed",
    source: canonicalSource,
    expected: { ok: true, document: canonicalDocument },
  },
  {
    name: "redirect-topology",
    source: redirectTopologySource,
    expected: { ok: true, document: redirectTopologyDocument },
  },
  {
    name: "herestring-not-heredoc",
    source: herestringSource,
    expected: { ok: true, document: herestringDocument },
  },
  {
    name: "newline-semicolon-and-pipeline",
    source: newlinePipelineSource,
    expected: { ok: true, document: newlinePipelineDocument },
  },
  {
    name: "heredoc-header-pipeline",
    source: heredocPipelineSource,
    expected: { ok: true, document: heredocPipelineDocument },
  },
  {
    name: "heredoc-header-args",
    source: heredocArgsSource,
    expected: { ok: true, document: heredocArgsDocument },
  },
  {
    name: "heredoc-header-right",
    source: heredocRightSource,
    expected: { ok: true, document: heredocRightDocument },
  },
  {
    name: "unsupported-controls",
    source: controlsSource,
    expected: { ok: true, document: controlsDocument },
  },
  {
    name: "inline-python-bmp",
    source: pythonInlineSource,
    expected: { ok: true, document: pythonInlineDocument },
  },
  {
    name: "nested-bash-wrapper",
    source: nestedSource,
    expected: { ok: true, document: nestedDocument },
  },
  {
    name: "empty-wrapper-payload",
    source: emptyWrapperSource,
    expected: { ok: true, document: emptyWrapperDocument },
  },
  {
    name: "literal-concatenation",
    source: concatenationSource,
    expected: { ok: true, document: concatenationDocument },
  },
  {
    name: "env-literal",
    source: envLiteralSource,
    expected: { ok: true, document: envLiteralDocument },
  },
  {
    name: "env-option",
    source: envOptionSource,
    expected: { ok: true, document: envOptionDocument },
  },
  {
    name: "env-dynamic",
    source: envDynamicSource,
    expected: { ok: true, document: envDynamicDocument },
  },
  {
    name: "env-missing-interpreter",
    source: envMissingSource,
    expected: { ok: true, document: envMissingDocument },
  },
  {
    name: "env-unknown-interpreter",
    source: envUnknownSource,
    expected: { ok: true, document: envUnknownDocument },
  },
  {
    name: "dash-gap-positive",
    source: dashPositiveSource,
    expected: { ok: true, document: dashPositiveDocument },
  },
  {
    name: "dash-gap-redirect-negative",
    source: dashRedirectSource,
    expected: { ok: true, document: dashRedirectDocument },
  },
  {
    name: "dash-heredoc-rejected",
    source: "cat <<-EOF\nbody\nEOF",
    expected: {
      ok: false,
      reason: "invalid_heredoc",
      issue: "indented",
      span: span(4, 7, "<<-"),
    },
  },
  {
    name: "multiple-heredocs-rejected",
    source: "cat <<A\na\nA\ncat <<B\nb\nB",
    expected: {
      ok: false,
      reason: "invalid_heredoc",
      issue: "multiple",
      span: span(16, 23, "<<B\nb\nB"),
    },
  },
  {
    name: "incomplete-heredoc",
    source: "cat <<EOF\nbody",
    expected: {
      ok: false,
      reason: "invalid_heredoc",
      issue: "incomplete",
      span: span(4, 14, "<<EOF\nbody"),
    },
  },
  {
    name: "body-opacity-unicode",
    source: bodyOpacitySource,
    expected: { ok: true, document: bodyOpacityDocument },
  },
  {
    name: "malformed-list",
    source: "echo a &&",
    expected: {
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "missing_node",
      span: span(9, 9, ""),
    },
  },
  {
    name: "dynamic-wrapper",
    source: dynamicWrapperSource,
    expected: { ok: true, document: dynamicWrapperDocument },
  },
];
