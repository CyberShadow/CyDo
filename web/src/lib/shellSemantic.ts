import { useState, useEffect } from "preact/hooks";
import {
  rowsLanguage,
  rowsLanguageMismatch,
  shellOutputView,
  type FileOrigin,
  type OutputSegment,
  type ReadRange,
  type RowsSegment,
} from "./shellOutput";
import {
  assertValidParsedShellDocument,
  foldParsedShellUnit,
  loadParsedShellDocument,
  type ParsedShellCommand,
  type ParsedShellDocument,
  type ParsedShellEmbeddedInvocation,
  type ParsedShellRedirect,
  type ParsedShellUnit,
} from "./shellParser";
import { ownsWholeCommand } from "./shellInvocationOwnership";
import {
  redirectEffect,
  shellArgumentWords,
  shellFdTable,
} from "./shellFdTable";

// Public types
// ---------------------------------------------------------------------------

export type RejectCode =
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

export interface ShellSourceSpan {
  start: number;
  end: number;
  rawText: string;
}

export interface ShellHeredocWriteSemantic {
  kind: "write";
  output?: OutputSegment[];
  commandName: "cat";
  command: string;
  filePath: string;
  heredoc: {
    delimiter: string;
    quoted: boolean;
    commandLine: string;
    content: string;
    terminator: string;
  };
  segments: Array<
    | { kind: "command-header"; text: string }
    | { kind: "write-content"; text: string; filePath: string }
    | { kind: "command-footer"; text: string }
  >;
}

export interface ShellScriptExecSemantic {
  kind: "script-exec";
  commandName: string;
  command: string;
  language: string;
  scriptSource:
    | {
        type: "heredoc";
        delimiter: string;
        quoted: boolean;
        content: string;
        terminator: string;
        commandLine: string;
      }
    | {
        type: "inline";
        flag: string;
        content: string;
      };
  segments: Array<
    | { kind: "command-header"; text: string }
    | { kind: "script-content"; text: string; language: string }
    | { kind: "command-footer"; text: string }
  >;
}

export interface ShellOutputSemantic {
  kind: "output";
  command: string;
  output: OutputSegment[];
}

export type ShellSemantic =
  | ShellOutputSemantic
  | ShellHeredocWriteSemantic
  | ShellScriptExecSemantic;

export type ShellSemanticResult =
  | { ok: true; value: ShellSemantic }
  | { ok: false; code: RejectCode; reason: string };

// ---------------------------------------------------------------------------
type SimpleCommand = {
  id: number;
  name: string | null;
  args: CommandArg[];
  redirects: ParsedShellRedirect[];
};

type CommandArg =
  | { kind: "flag"; text: string }
  | { kind: "value"; text: string };

type ShellAST =
  | { type: "simple"; command: SimpleCommand }
  | { type: "pipeline"; stages: SimpleCommand[] }
  | { type: "list"; op: "&&" | ";"; left: ShellAST; right: ShellAST }
  | { type: "unsupported"; reason: string };

function reject(
  code: RejectCode,
  reason: string,
): {
  ok: false;
  code: RejectCode;
  reason: string;
} {
  return { ok: false, code, reason };
}

function basename(value: string): string {
  const parts = value.split("/");
  return parts[parts.length - 1] ?? value;
}

// Layer 3: Classifier
// ---------------------------------------------------------------------------

const STREAM_COMMANDS = new Set<string>([
  "cat",
  "nl",
  "sed",
  "head",
  "tail",
  "grep",
  "rg",
  "git",
  "diff",
]);

const OPAQUE_TRANSFORM_COMMANDS = new Set<string>([
  "wc",
  "tr",
  "cut",
  "sort",
  "uniq",
  "tee",
  "column",
  "yes",
  "printf",
  "xargs",
]);

type NlOptions = {
  width?: number;
  separator?: string;
};
type SliceRange = Exclude<ReadRange, { type: "all" }>;
type ShellStream = RowsSegment | { kind: "diff" };

type StageOp =
  | { kind: "identity" }
  | { kind: "slice"; range: SliceRange }
  | {
      kind: "number-lines";
      options: NlOptions;
      lastRowMayBeUnterminated: boolean;
    }
  | { kind: "search"; lineNumbers: boolean; context: boolean }
  | { kind: "opaque"; commandName: string };

type ParsedStage =
  | { kind: "source"; stream: ShellStream }
  | {
      kind: "filter";
      operands: string[];
      op: StageOp;
    };

type ParseResult<T> =
  | { ok: true; value: T }
  | { ok: false; code: RejectCode; reason: string };

function isFileOperand(text: string): boolean {
  return text.length > 0 && text !== "-";
}

function parsePositiveDecimal(text: string): number | undefined {
  if (!/^\d+$/.test(text)) return undefined;
  const number = Number(text);
  return Number.isSafeInteger(number) && number > 0 ? number : undefined;
}

function parseCatArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ operands: string[]; numberLines: boolean }> {
  const operands: string[] = [];
  let options = true;
  let numberLines = false;
  for (const { text, kind } of cmd.args) {
    if (options && text === "--") {
      options = false;
      continue;
    }
    if (options && kind === "flag") {
      if (text === "-n" || text === "--number") {
        numberLines = true;
        continue;
      }
      return reject("unsupported_option", `unsupported cat option ${text}`);
    }
    if (!isFileOperand(text)) {
      return reject(
        "missing_path",
        `invalid cat file operand ${JSON.stringify(text)}`,
      );
    }
    operands.push(text);
  }
  if (requireFile && operands.length === 0) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { operands, numberLines } };
}

function parseLineCountArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
  tool: "head" | "tail",
): ParseResult<{
  count: number | undefined;
  fromStart: boolean;
  filePath?: string;
}> {
  let count: number | undefined;
  let fromStart = false;
  let filePath: string | undefined;
  let options = true;

  for (let i = 0; i < cmd.args.length; i++) {
    const { text, kind } = cmd.args[i]!;
    if (options && text === "--") {
      options = false;
      continue;
    }
    if (!options || kind === "value") {
      if (!isFileOperand(text)) {
        return reject(
          "missing_path",
          `invalid ${tool} file operand ${JSON.stringify(text)}`,
        );
      }
      if (filePath !== undefined) {
        return reject(
          "multiple_paths",
          `unexpected ${tool} file operand ${text}`,
        );
      }
      filePath = text;
      continue;
    }

    const legacy = i === 0 ? /^-(\d+)$/.exec(text) : null;
    let numberText: string | undefined;
    if (legacy) {
      numberText = legacy[1]!;
    } else if (text === "-n") {
      numberText = cmd.args[++i]?.text;
      if (numberText === undefined) {
        return reject("unsupported_option", `${tool} -n requires a line count`);
      }
    } else if (text.startsWith("-n")) {
      numberText = text.slice(2);
    }
    if (numberText === undefined) {
      return reject("unsupported_option", `unsupported ${tool} option ${text}`);
    }
    if (count !== undefined) {
      return reject(
        "unsupported_option",
        `unexpected ${tool} line count option ${text}`,
      );
    }
    const plus = numberText.startsWith("+");
    count = parsePositiveDecimal(plus ? numberText.slice(1) : numberText);
    if (count === undefined) {
      return reject(
        "unsupported_option",
        `${tool} line count must be a positive safe decimal integer: ${JSON.stringify(text === "-n" ? numberText : text)}`,
      );
    }
    fromStart = tool === "tail" && plus;
  }

  if (requireFile && filePath === undefined) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { count, fromStart, filePath } };
}

function parseHeadArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ count: number | undefined; filePath?: string }> {
  return parseLineCountArgs(cmd, requireFile, "head");
}

function parseTailArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ range: ReadRange; filePath?: string }> {
  const parsed = parseLineCountArgs(cmd, requireFile, "tail");
  if (!parsed.ok) return parsed;
  const { count, fromStart, filePath } = parsed.value;
  const range: ReadRange =
    count === undefined
      ? { type: "all" }
      : fromStart
        ? { type: "tail", startLine: count }
        : { type: "tail-count", count };
  return { ok: true, value: { range, filePath } };
}

function parseSedArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ start: number; end: number; filePath?: string }> {
  const [first] = cmd.args;
  if (first?.text !== "-n") {
    return reject(
      "unsupported_option",
      first
        ? `unsupported sed argument ${first.text} before -n`
        : "sed requires -n",
    );
  }
  const marked = cmd.args[1]?.text === "--";
  const exprIndex = marked ? 2 : 1;
  const exprArg = cmd.args[exprIndex];
  if (!exprArg) return reject("missing_path", "sed requires an expression");
  if (!marked && exprArg.kind === "flag") {
    return reject(
      "unsupported_option",
      `unsupported sed option ${exprArg.text}`,
    );
  }
  const match = /^(\d+),(\d+)p$/.exec(exprArg.text);
  if (!match)
    return reject(
      "invalid_range",
      `unsupported sed expression ${exprArg.text}`,
    );
  const start = parsePositiveDecimal(match[1]!);
  const end = parsePositiveDecimal(match[2]!);
  if (start === undefined || end === undefined) {
    return reject(
      "invalid_range",
      `sed line numbers must be positive safe decimal integers: ${exprArg.text}`,
    );
  }
  if (end < start) {
    return reject(
      "invalid_range",
      `sed end line must be >= start line: ${exprArg.text}`,
    );
  }

  const pathMarked = !marked && cmd.args[exprIndex + 1]?.text === "--";
  const pathIndex = exprIndex + (pathMarked ? 2 : 1);
  const path = cmd.args[pathIndex];
  if (path && !marked && !pathMarked && path.kind === "flag") {
    return reject("unsupported_option", `unsupported sed option ${path.text}`);
  }
  const extra = cmd.args[pathIndex + 1];
  if (extra) {
    if (!marked && !pathMarked && extra.kind === "flag") {
      return reject(
        "unsupported_option",
        `unsupported sed option ${extra.text}`,
      );
    }
    return reject(
      "multiple_paths",
      `unexpected sed file operand ${extra.text}`,
    );
  }
  if (path && !isFileOperand(path.text)) {
    return reject(
      "missing_path",
      `invalid sed file operand ${JSON.stringify(path.text)}`,
    );
  }
  if (requireFile && !path) {
    return reject("missing_path", "sed requires a file path");
  }
  return { ok: true, value: { start, end, filePath: path?.text } };
}

// GNU nl parses the field width as a positive C int.
const MAX_NL_WIDTH = 2_147_483_647;

function parseNlArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ options: NlOptions; operands: string[] }> {
  const operands: string[] = [];
  const options: NlOptions = {};
  let parseOptions = true;

  for (let i = 0; i < cmd.args.length; i++) {
    const arg = cmd.args[i]!;
    if (parseOptions && arg.text === "--") {
      parseOptions = false;
      continue;
    }
    if (!parseOptions || arg.kind === "value") {
      if (!isFileOperand(arg.text)) {
        return reject(
          "missing_path",
          `invalid nl file operand ${JSON.stringify(arg.text)}`,
        );
      }
      operands.push(arg.text);
      continue;
    }

    const flag = arg.text;
    if (flag === "-ba") continue;
    if (flag === "-w") {
      const next = cmd.args[++i];
      if (!next) return reject("unsupported_option", "nl -w requires a width");
      const width = parsePositiveDecimal(next.text);
      if (width === undefined || width > MAX_NL_WIDTH) {
        return reject(
          "unsupported_option",
          `nl -w width must be a decimal integer from 1 to ${MAX_NL_WIDTH}: ${JSON.stringify(next.text)}`,
        );
      }
      options.width = width;
      continue;
    }
    if (flag === "-s") {
      const next = cmd.args[++i];
      if (!next) {
        return reject("unsupported_option", "nl -s requires a separator");
      }
      if (/[\r\n]/.test(next.text)) {
        return reject(
          "unsupported_option",
          "nl -s separator must not contain a line terminator",
        );
      }
      if (next.text === "") {
        return reject(
          "unsupported_option",
          "nl -s separator must not be empty",
        );
      }
      if (/^\d/.test(next.text)) {
        return reject(
          "unsupported_option",
          "nl -s separator must not start with a digit",
        );
      }
      options.separator = next.text;
      continue;
    }
    return reject("unsupported_option", `unsupported nl option ${flag}`);
  }

  if (requireFile && operands.length === 0) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { options, operands } };
}

function parseRgArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ filePath?: string; lineNumbers: boolean; context: boolean }> {
  const toolName = cmd.name === "grep" ? "grep" : "rg";
  let lineNumberFlag: "-n" | "--line-number" | undefined;
  let context = false;
  const values: string[] = [];
  for (let i = 0; i < cmd.args.length; i++) {
    const { kind, text } = cmd.args[i]!;
    if (kind === "value") {
      values.push(text);
      continue;
    }
    if (text === "-n" || text === "--line-number") {
      lineNumberFlag = text;
      continue;
    }
    const contextOption =
      /^(?:-[ABC](\d*)|--(?:after-context|before-context|context)(?:=(\d+))?)$/.exec(
        text,
      );
    if (contextOption) {
      const count = contextOption[1] || contextOption[2] || cmd.args[++i]?.text;
      if (
        count !== undefined &&
        /^\d+$/.test(count) &&
        Number.isSafeInteger(Number(count))
      ) {
        context = true;
        continue;
      }
    }
    return reject(
      "unsupported_option",
      `unsupported ${toolName} option ${text}`,
    );
  }
  const hasLineNumbers = lineNumberFlag !== undefined;
  const expectedCount = requireFile ? 2 : 1;
  if (values.length > expectedCount) {
    return reject(
      "multiple_paths",
      `unexpected ${toolName} operand ${values[expectedCount]!}`,
    );
  }
  if (values.length < expectedCount) {
    const invocation = lineNumberFlag
      ? `${toolName} ${lineNumberFlag}`
      : toolName;
    return reject(
      "missing_path",
      requireFile
        ? `${invocation} requires exactly one pattern and one file operand`
        : `${invocation} requires exactly one pattern`,
    );
  }

  const pattern = values[0]!;
  const filePath = values[1];
  if (!pattern)
    return reject("variable_path", `${toolName} pattern must be non-empty`);
  if (requireFile) {
    if (filePath === undefined || !isFileOperand(filePath))
      return reject(
        "variable_path",
        `${toolName} file operand must name a file`,
      );
    if (filePath === "." || filePath === ".." || filePath.endsWith("/")) {
      return reject(
        "unsupported_command",
        `${toolName} target must be a file path`,
      );
    }
  }

  if (!hasLineNumbers && toolName === "rg") {
    return reject(
      "unsupported_option",
      requireFile
        ? "rg without -n/--line-number is not planned: its output depends on whether the operand is a directory"
        : "rg without -n/--line-number is not planned",
    );
  }
  if (!hasLineNumbers && context) {
    return reject(
      "unsupported_option",
      `${toolName} context lines require -n/--line-number`,
    );
  }

  return {
    ok: true,
    value: { filePath, lineNumbers: hasLineNumbers, context },
  };
}

function openFile(origin: FileOrigin): RowsSegment {
  return {
    kind: "rows",
    source: { kind: "file", origin, range: { type: "all" } },
    numbering: null,
  };
}

function rejectRedirectEffect(
  cmd: Pick<SimpleCommand, "name" | "redirects">,
): ReturnType<typeof reject> | null {
  for (const redirect of cmd.redirects) {
    switch (redirectEffect(redirect)) {
      case "stdin":
        return reject(
          "redirection_on_read",
          `${cmd.name} input redirection replaces the pipeline input`,
        );
      case "stdout":
        return reject(
          "redirection_on_read",
          `${cmd.name} output redirection diverts the command output`,
        );
      case "stderr-into-stdout":
        return reject(
          "redirection_on_read",
          `${cmd.name} stderr redirection mixes diagnostics into the output`,
        );
    }
  }
  return null;
}

function parseStage(
  cmd: SimpleCommand,
  position: "first" | "later",
  cdPath: string,
): ParseResult<ParsedStage> {
  const name = cmd.name;
  if (!name) return reject("empty", "empty command");

  const first = position === "first";
  const redirectRejection = rejectRedirectEffect(cmd);
  if (redirectRejection) return redirectRejection;

  function filter(op: StageOp, operands: string[]): ParseResult<ParsedStage> {
    if (first && operands.length === 0) {
      return reject("missing_path", "expected one file path");
    }
    if (!first && operands.length !== 0) {
      return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
    }
    return { ok: true, value: { kind: "filter", operands, op } };
  }

  switch (name) {
    case "cat": {
      const parsed = parseCatArgs(cmd, first);
      if (!parsed.ok) return parsed;
      const { operands, numberLines } = parsed.value;
      return filter(
        numberLines
          ? {
              kind: "number-lines",
              options: {},
              lastRowMayBeUnterminated: true,
            }
          : { kind: "identity" },
        operands,
      );
    }
    case "head": {
      const parsed = parseHeadArgs(cmd, first);
      if (!parsed.ok) return parsed;
      const { count = 10, filePath } = parsed.value;
      return filter(
        { kind: "slice", range: { type: "head", count } },
        filePath === undefined ? [] : [filePath],
      );
    }
    case "tail": {
      const parsed = parseTailArgs(cmd, first);
      if (!parsed.ok) return parsed;
      const { range, filePath } = parsed.value;
      const sliceRange: SliceRange =
        range.type === "all" ? { type: "tail-count", count: 10 } : range;
      return filter(
        { kind: "slice", range: sliceRange },
        filePath === undefined ? [] : [filePath],
      );
    }
    case "sed": {
      const parsed = parseSedArgs(cmd, first);
      if (!parsed.ok) return parsed;
      const { start, end, filePath } = parsed.value;
      return filter(
        {
          kind: "slice",
          range: { type: "lines", start, end },
        },
        filePath === undefined ? [] : [filePath],
      );
    }
    case "nl": {
      const parsed = parseNlArgs(cmd, first);
      if (!parsed.ok) return parsed;
      return filter(
        {
          kind: "number-lines",
          options: parsed.value.options,
          lastRowMayBeUnterminated: false,
        },
        parsed.value.operands,
      );
    }
    case "grep":
    case "rg": {
      const parsed = parseRgArgs(cmd, first);
      if (!parsed.ok) return parsed;
      return filter(
        {
          kind: "search",
          lineNumbers: parsed.value.lineNumbers,
          context: parsed.value.context,
        },
        parsed.value.filePath === undefined ? [] : [parsed.value.filePath],
      );
    }
    case "git":
    case "diff": {
      if (!first)
        return reject(
          "unsafe_shell_syntax",
          "pipeline has multiple diff stages",
        );
      const source =
        name === "diff"
          ? ({ ok: true, value: { kind: "diff" } } as const)
          : classifyGitCommand(cmd, cdPath);
      return source.ok
        ? { ok: true, value: { kind: "source", stream: source.value } }
        : source;
    }
  }

  if (
    OPAQUE_TRANSFORM_COMMANDS.has(name) ||
    (name === "awk" &&
      cmd.args.every((a) => a.kind === "flag" || a.text.startsWith("{")))
  ) {
    if (first) {
      return reject(
        "unsafe_shell_syntax",
        "pipeline has no recognized file-reading, search, or diff stage",
      );
    }
    return {
      ok: true,
      value: {
        kind: "filter",
        operands: [],
        op: { kind: "opaque", commandName: name },
      },
    };
  }

  return first
    ? reject(
        "unsupported_command",
        "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
      )
    : reject(
        "unsafe_shell_syntax",
        `pipeline stage "${name}" is not a recognized formatting command`,
      );
}

type IntervalRange = Exclude<SliceRange, { type: "tail-count" }>;
type LineInterval = { start: number; end: number | null };

function toInterval(range: IntervalRange): LineInterval {
  switch (range.type) {
    case "head":
      return { start: 1, end: range.count };
    case "tail":
      return { start: range.startLine, end: null };
    case "lines":
      return { start: range.start, end: range.end };
  }
}

function fromInterval({ start, end }: LineInterval): IntervalRange {
  if (end === null) return { type: "tail", startLine: start };
  if (start === 1) return { type: "head", count: end };
  return { type: "lines", start, end };
}

function applySlice(
  input: ReadRange,
  applied: SliceRange,
): ParseResult<ReadRange | "unchanged" | "unpositioned"> {
  if (
    input.type === "all" ||
    (input.type === "tail" && input.startLine === 1)
  ) {
    return { ok: true, value: applied };
  }

  const base = input.type === "tail-count" ? null : toInterval(input);
  const rowBound =
    input.type === "tail-count"
      ? input.count
      : base!.end === null
        ? Infinity
        : base!.end - base!.start + 1;
  const slice = applied.type === "tail-count" ? null : toInterval(applied);
  if (
    slice === null
      ? applied.type === "tail-count" && applied.count >= rowBound
      : slice.start === 1 && (slice.end === null || slice.end >= rowBound)
  ) {
    return { ok: true, value: "unchanged" };
  }

  if (input.type === "tail-count") {
    if (applied.type === "tail-count") {
      return {
        ok: true,
        value: {
          type: "tail-count",
          count: Math.min(input.count, applied.count),
        },
      };
    }
    return { ok: true, value: "unpositioned" };
  }
  if (applied.type === "tail-count") {
    return { ok: true, value: "unpositioned" };
  }

  const { start: baseStart, end: baseEnd } = toInterval(input);
  const { start: sliceStart, end: sliceEnd } = toInterval(applied);
  const offset = baseStart - 1;
  const start = offset + sliceStart;
  const end =
    sliceEnd === null
      ? baseEnd
      : Math.min(baseEnd ?? Infinity, offset + sliceEnd);
  if (
    !Number.isSafeInteger(start) ||
    (end !== null && !Number.isSafeInteger(end))
  ) {
    return reject(
      "unsafe_shell_syntax",
      "line range exceeds integer precision",
    );
  }
  if (end !== null && start > end) {
    return reject("unsafe_shell_syntax", "slice selects no lines of its input");
  }
  return { ok: true, value: fromInterval({ start, end }) };
}

function applyStage(
  stream: ShellStream,
  op: StageOp,
  rowBound: number,
): ParseResult<ShellStream> {
  const unchanged = { ok: true, value: stream } as const;
  switch (op.kind) {
    case "identity":
      return unchanged;
    case "slice": {
      if (stream.kind === "diff" || stream.numbering?.kind === "grep")
        return unchanged;

      const keepsFirstRow =
        op.range.type === "tail-count"
          ? op.range.count >= rowBound
          : toInterval(op.range).start === 1;
      const numbering =
        stream.numbering?.startsAtOne && !keepsFirstRow
          ? { ...stream.numbering, startsAtOne: false }
          : stream.numbering;
      const source = stream.source;
      if (source.kind === "unpositioned") {
        return { ok: true, value: { ...stream, numbering } };
      }
      const range = applySlice(source.range, op.range);
      if (!range.ok) return range;
      if (range.value === "unchanged") {
        return { ok: true, value: { ...stream, numbering } };
      }
      return {
        ok: true,
        value: {
          ...stream,
          numbering,
          source:
            range.value === "unpositioned"
              ? { kind: "unpositioned", language: rowsLanguage(source) }
              : { ...source, range: range.value },
        },
      };
    }
    case "number-lines": {
      if (stream.kind === "diff") return unchanged;
      if (stream.numbering?.kind === "grep") {
        return reject(
          "unsafe_shell_syntax",
          "nl numbering of search output is not supported",
        );
      }
      if (stream.numbering) {
        return reject(
          "unsafe_shell_syntax",
          "nested nl numbering is not supported",
        );
      }
      return {
        ok: true,
        value: {
          ...stream,
          numbering: {
            kind: "nl",
            startsAtOne: true,
            lastRowMayBeUnterminated: op.lastRowMayBeUnterminated,
            width: op.options.width ?? 6,
            separator: op.options.separator ?? "\t",
          },
        },
      };
    }
    case "search":
      if (stream.kind === "diff") {
        return reject(
          "unsafe_shell_syntax",
          "search over diff output is not supported",
        );
      }
      if (stream.numbering?.kind === "grep") {
        return reject(
          "unsafe_shell_syntax",
          "search over search output is not supported",
        );
      }
      if (stream.numbering) {
        return reject(
          "unsafe_shell_syntax",
          "search over nl-numbered output is not supported",
        );
      }
      if (!op.lineNumbers) {
        if (stream.source.kind === "unpositioned") return unchanged;
        return {
          ok: true,
          value: {
            ...stream,
            source: {
              kind: "unpositioned",
              language: rowsLanguage(stream.source),
            },
          },
        };
      }
      return {
        ok: true,
        value: {
          ...stream,
          numbering: {
            kind: "grep",
            context: op.context,
          },
        },
      };
    case "opaque":
      return stream.kind === "diff"
        ? unchanged
        : reject(
            "unsafe_shell_syntax",
            `${op.commandName} output is not planned`,
          );
  }
}

function buildPipelineStream(
  stages: SimpleCommand[],
  cdPath: string,
): ParseResult<ShellStream> {
  if (stages.length === 0) return reject("empty", "empty pipeline");
  let rowBound = Infinity;
  function applyPipelineStage(stream: ShellStream, op: StageOp) {
    const inputRowBound = rowBound;
    if (
      op.kind === "slice" &&
      stream.kind === "rows" &&
      stream.numbering?.kind !== "grep"
    ) {
      if (op.range.type === "tail-count") {
        rowBound = Math.min(rowBound, op.range.count);
      } else {
        const { start, end } = toInterval(op.range);
        if (start > rowBound) {
          return reject(
            "unsafe_shell_syntax",
            "slice selects no lines of its input",
          );
        }
        rowBound = Math.min(rowBound, end ?? Infinity) - (start - 1);
      }
    }
    return applyStage(stream, op, inputRowBound);
  }
  const first = parseStage(stages[0]!, "first", cdPath);
  if (!first.ok) return first;
  const source = first.value;
  let stream: ShellStream;
  if (source.kind === "source") {
    stream = source.stream;
  } else {
    const rows = openFile({
      kind: "worktree",
      filePath: resolveAgainstCd(cdPath, source.operands[0]!),
    });
    let input = rows;
    if (source.operands.length > 1) {
      const language = rowsLanguage(rows.source);
      for (let index = 1; index < source.operands.length; index++) {
        const next = openFile({
          kind: "worktree",
          filePath: resolveAgainstCd(cdPath, source.operands[index]!),
        });
        const mismatch = rowsLanguageMismatch(
          language,
          rowsLanguage(next.source),
        );
        if (mismatch) return reject("unsupported_command", mismatch.reason);
      }
      input = { ...rows, source: { kind: "unpositioned", language } };
    }
    const opened = applyPipelineStage(input, source.op);
    if (!opened.ok) return opened;
    stream = opened.value;
  }
  for (let index = 1; index < stages.length; index++) {
    const parsed = parseStage(stages[index]!, "later", cdPath);
    if (!parsed.ok) return parsed;
    if (parsed.value.kind !== "filter")
      throw new Error("Expected a pipeline filter");
    const next = applyPipelineStage(stream, parsed.value.op);
    if (!next.ok) return next;
    stream = next.value;
  }
  return { ok: true, value: stream };
}

function classifyPipeline(
  stages: SimpleCommand[],
  command: string,
  cdPath: string,
): ParseResult<ShellOutputSemantic> {
  const stream = buildPipelineStream(stages, cdPath);
  return stream.ok
    ? { ok: true, value: { kind: "output", command, output: [stream.value] } }
    : stream;
}

function resolveAgainstCd(cdPath: string, path: string): string {
  return path.startsWith("/") || !cdPath ? path : cdPath + "/" + path;
}

function isGitObjectRead(segment: OutputSegment): boolean {
  return (
    segment.kind === "rows" &&
    segment.source.kind === "file" &&
    segment.source.origin.kind === "git-object" &&
    segment.numbering?.kind !== "grep"
  );
}

function classifyGenericList(
  ast: ShellAST,
  originalCommand: string,
): ShellSemanticResult {
  const members: SimpleCommand[][] = [];
  const pending = [ast];
  while (pending.length > 0) {
    const node = pending.pop()!;
    if (node.type === "list") {
      pending.push(node.right, node.left);
    } else if (node.type === "simple") {
      members.push([node.command]);
    } else if (node.type === "pipeline") {
      members.push(node.stages);
    } else {
      return reject("unsafe_shell_syntax", "unsupported list structure");
    }
  }

  const isCd = (member: SimpleCommand[]) =>
    member.length === 1 && member[0]!.name === "cd";
  const singleMember = members.filter((member) => !isCd(member)).length === 1;
  let cdPath = "";
  let singleResult: ShellSemanticResult | undefined;
  const output: OutputSegment[] = [];

  for (const member of members) {
    const cmd = member[0]!;
    if (isCd(member)) {
      const parsed = parseCdArgs(cmd);
      if (!parsed.ok) return parsed;
      cdPath = resolveAgainstCd(cdPath, parsed.value);
      continue;
    }

    if (singleMember) {
      const result = classifyPipeline(member, originalCommand, cdPath);
      if (!result.ok) return result;
      const value = result.value;
      if (isGitObjectRead(value.output[0]!)) {
        return reject(
          "unsafe_shell_syntax",
          "git object paths are not relative to cd",
        );
      }
      singleResult = result;
      continue;
    }

    let memberOutput: OutputSegment[];
    if (member.length === 1 && !STREAM_COMMANDS.has(cmd.name ?? "")) {
      if (cmd.name === "echo" || cmd.name === "printf" || cmd.name === "wc") {
        const redirectRejection = rejectRedirectEffect(cmd);
        if (redirectRejection) return redirectRejection;
      }
      const result = classifyStepListMember(cmd);
      if (!result) {
        return reject(
          "unsupported_command",
          `unsupported command in list: ${cmd.name ?? "(unnamed)"}`,
        );
      }
      memberOutput = result;
    } else {
      const result = classifyPipeline(member, originalCommand, cdPath);
      if (!result.ok) return result;
      if (result.value.output[0]!.kind === "diff") {
        return reject(
          "unsupported_command",
          "diff output cannot be combined with other list output",
        );
      }
      memberOutput = result.value.output;
    }

    output.push(...memberOutput);
  }

  if (singleResult) return singleResult;

  if (!output.some((s) => s.kind === "rows")) {
    return reject(
      "unsupported_command",
      "list must contain at least one file-content or search command",
    );
  }

  return {
    ok: true,
    value: {
      kind: "output",
      command: originalCommand,
      output,
    },
  };
}

function isPlainGitRevision(revision: string): boolean {
  const ref = revision.split(/[~^]/, 1)[0]!;
  const ancestry = revision.slice(ref.length);
  return (
    ref !== "@" &&
    !ref.includes("@{") &&
    !ref.endsWith(".") &&
    !/[^!-~\u0080-\u{10ffff}]|[:?*[\\]/u.test(ref) &&
    ref
      .split("/")
      .every(
        (part) =>
          part.length > 0 && !part.startsWith(".") && !part.endsWith(".lock"),
      ) &&
    /^(?:[~^]\d+)*$/u.test(ancestry)
  );
}

function classifyGitCommand(
  cmd: SimpleCommand,
  cdPath: string,
): ParseResult<ShellStream> {
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  const subcommand = valueArgs[0]?.text;

  if (!subcommand)
    return reject("unsupported_command", "bare git without subcommand");

  if (subcommand === "diff") {
    return {
      ok: true,
      value: { kind: "diff" },
    };
  }

  if (subcommand === "show") {
    const showArgs = valueArgs.slice(1);
    const colonArg = showArgs.find((a) => a.text.includes(":"));
    if (colonArg && showArgs.length > 1) {
      return reject(
        "multiple_paths",
        "git show object reads require exactly one object operand",
      );
    }
    const marker = cmd.args.findIndex(
      (arg) => arg.text === "--" || arg.text === "--end-of-options",
    );
    if (
      (colonArg && (cmd.args.length !== 2 || cmd.args[0]?.text !== "show")) ||
      (marker !== -1 &&
        cmd.args.slice(marker + 1).some((arg) => arg.text.includes(":")))
    ) {
      return reject(
        "unsupported_option",
        "git show object reads do not support options or operand separators",
      );
    }
    if (colonArg) {
      const colonIdx = colonArg.text.indexOf(":");
      const revision = colonArg.text.slice(0, colonIdx);
      const filePath = colonArg.text.slice(colonIdx + 1);
      if (cdPath && (filePath.startsWith("./") || filePath.startsWith("../"))) {
        return reject(
          "unsafe_shell_syntax",
          "cwd-relative git object paths under cd are not supported",
        );
      }
      const validPath =
        filePath === ""
          ? revision === "HEAD"
          : !/^[!(]|[\^*?[]/.test(filePath) &&
            filePath.split("/").every((part) => part !== "" && part !== ".");
      if (
        colonArg.text.includes("..") ||
        (revision !== "" && !isPlainGitRevision(revision)) ||
        (revision === "" && /^[0-3]:/.test(filePath)) ||
        !validPath
      ) {
        return reject(
          "unsupported_command",
          "unsupported git show object specification",
        );
      }
      return {
        ok: true,
        value: openFile({ kind: "git-object", filePath }),
      };
    }
    return {
      ok: true,
      value: { kind: "diff" },
    };
  }

  if (subcommand === "log") {
    const flags = cmd.args.filter((a) => a.kind === "flag").map((a) => a.text);
    if (flags.includes("-p") || flags.includes("--patch")) {
      return {
        ok: true,
        value: { kind: "diff" },
      };
    }
    return reject(
      "unsupported_command",
      "git log without -p/--patch is not diff-producing",
    );
  }

  return reject(
    "unsupported_command",
    `unsupported git subcommand: ${subcommand}`,
  );
}

function commandForId(
  document: ParsedShellDocument,
  commandId: number,
): ParsedShellCommand {
  return document.commands[commandId]!;
}

function redirectForId(
  document: ParsedShellDocument,
  redirectId: number,
): ParsedShellRedirect {
  return document.redirects[redirectId]!;
}

function adaptCommand(
  document: ParsedShellDocument,
  commandId: number,
): SimpleCommand | null {
  const command = commandForId(document, commandId);
  if (command.assignments.length > 0 || command.name.kind !== "literal")
    return null;
  const redirects = command.redirectIds.map((id) =>
    redirectForId(document, id),
  );
  const args: CommandArg[] = [];
  for (const word of shellArgumentWords(command.arguments, redirects)) {
    if (word.kind !== "literal") return null;
    args.push({
      kind: word.value.startsWith("-") ? "flag" : "value",
      text: word.value,
    });
  }
  return {
    id: command.id,
    name: basename(command.name.value),
    args,
    redirects,
  };
}

function directCommandId(unit: ParsedShellUnit): number | null {
  if (unit.kind === "command") return unit.commandId;
  if (unit.kind === "redirected_statement" && unit.body.kind === "command")
    return unit.body.commandId;
  return null;
}

function directCommand(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
): SimpleCommand | null {
  const commandId = directCommandId(unit);
  return commandId === null ? null : adaptCommand(document, commandId);
}

function listAST(children: readonly ShellAST[], op: "&&" | ";"): ShellAST {
  if (children.length === 0)
    return { type: "unsupported", reason: "empty command list" };
  let result = children[0]!;
  for (let i = 1; i < children.length; i++)
    result = {
      type: "list",
      op,
      left: result,
      right: children[i]!,
    };
  return result;
}

function flattenAndUnits(unit: ParsedShellUnit): ParsedShellUnit[] | null {
  const pending = [unit];
  const flattened: ParsedShellUnit[] = [];
  while (pending.length > 0) {
    const current = pending.pop()!;
    if (directCommandId(current) !== null) {
      flattened.push(current);
      continue;
    }
    if (
      current.kind !== "list" ||
      current.operators.length !== current.children.length - 1 ||
      current.operators.some((operator) => operator.kind !== "and")
    )
      return null;
    for (let index = current.children.length - 1; index >= 0; index--)
      pending.push(current.children[index]!);
  }
  return flattened;
}

function adaptUnit(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
): ShellAST {
  return foldParsedShellUnit<ShellAST>(unit, (current, children) =>
    adaptUnitFromChildren(document, current, children),
  );
}

function adaptUnitFromChildren(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
  children: readonly ShellAST[],
): ShellAST {
  if (unit.kind === "command") {
    const command = adaptCommand(document, unit.commandId);
    return command === null
      ? { type: "unsupported", reason: "nonliteral command" }
      : { type: "simple", command };
  }

  if (unit.kind === "redirected_statement") {
    return children[0]!;
  }

  if (unit.kind === "pipeline") {
    if (
      unit.operators.length !== unit.children.length - 1 ||
      unit.operators.some((operator) => operator.kind !== "pipe")
    )
      return { type: "unsupported", reason: "unsupported pipeline operator" };
    const stages: SimpleCommand[] = [];
    for (const [index, child] of children.entries()) {
      if (
        child.type !== "simple" ||
        directCommandId(unit.children[index]!) === null
      )
        return { type: "unsupported", reason: "unsupported pipeline stage" };
      stages.push(child.command);
    }
    return { type: "pipeline", stages };
  }

  if (unit.kind === "list") {
    if (
      unit.operators.length !== unit.children.length - 1 ||
      unit.operators.some((operator) => operator.kind !== "and")
    )
      return { type: "unsupported", reason: "unsupported list structure" };
    return listAST(children, "&&");
  }

  if (unit.kind === "program") {
    if (unit.children.length === 0)
      return { type: "unsupported", reason: "empty command list" };
    if (unit.boundaries.length !== unit.children.length - 1)
      return { type: "unsupported", reason: "malformed program boundaries" };
    if (
      unit.boundaries.some(
        (boundary) =>
          boundary.kind !== "newline" && boundary.kind !== "semicolon",
      )
    )
      return { type: "unsupported", reason: "unsupported program boundary" };
    return unit.children.length === 1 ? children[0]! : listAST(children, ";");
  }

  return { type: "unsupported", reason: "opaque shell unit" };
}

function parseCdArgs(command: SimpleCommand): ParseResult<string> {
  for (const { kind, text } of command.args) {
    if (kind === "flag") {
      return reject("unsupported_option", `unsupported cd option ${text}`);
    }
  }
  const [target, extra] = command.args;
  if (!target?.text) {
    return reject("unsafe_shell_syntax", "cd target must be a literal path");
  }
  if (extra) {
    return reject("multiple_paths", `unexpected cd operand ${extra.text}`);
  }
  if (command.redirects.length > 0) {
    return reject(
      "unsafe_shell_syntax",
      `unsupported cd redirection ${command.redirects[0]!.operator}`,
    );
  }
  return { ok: true, value: target.text };
}

function isLiteralCd(command: SimpleCommand | null): command is SimpleCommand {
  return command !== null && command.name === "cd" && parseCdArgs(command).ok;
}

function invocationContextCommand(
  document: ParsedShellDocument,
): number | null {
  let unit: ParsedShellUnit = document.program;
  for (;;) {
    if (unit.kind === "command") return unit.commandId;
    if (unit.kind === "redirected_statement") {
      unit = unit.body;
      continue;
    }
    if (unit.kind === "program") {
      if (
        unit.children.length === 0 ||
        unit.boundaries.length !== unit.children.length - 1 ||
        unit.boundaries.some(
          (boundary) =>
            boundary.kind !== "newline" && boundary.kind !== "semicolon",
        )
      )
        return null;
      unit = unit.children[0]!;
      continue;
    }
    break;
  }

  if (unit.kind !== "list") return null;
  const children = flattenAndUnits(unit);
  if (children === null) return null;
  let prefixLength = 0;
  for (const child of children) {
    if (!isLiteralCd(directCommand(document, child)))
      return prefixLength > 0 ? directCommandId(child) : null;
    prefixLength++;
  }
  return null;
}

function oneEligibleInvocation(
  document: ParsedShellDocument,
): ParsedShellEmbeddedInvocation | null {
  if (document.embeddedInvocations.length === 0) return null;
  const contextCommand = invocationContextCommand(document);
  const soleCommand =
    document.program.children.length === 1
      ? directCommandId(document.program.children[0]!)
      : null;
  let eligible: ParsedShellEmbeddedInvocation | null = null;
  for (const invocation of document.embeddedInvocations) {
    const candidate =
      invocation.kind === "inline" && invocation.interpreter.language === "bash"
        ? soleCommand
        : contextCommand;
    if (
      invocation.commandId !== candidate ||
      commandForId(document, invocation.commandId).assignments.length > 0
    )
      continue;
    if (eligible !== null) return null;
    eligible = invocation;
  }
  return eligible;
}

function heredocForInvocation(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "heredoc" }>,
): Extract<ParsedShellRedirect, { kind: "heredoc" }> {
  return document.redirects[invocation.heredocRedirectId]! as Extract<
    ParsedShellRedirect,
    { kind: "heredoc" }
  >;
}

function heredocSegments(
  document: ParsedShellDocument,
  redirect: Extract<ParsedShellRedirect, { kind: "heredoc" }>,
  content: string,
  language: string,
): ShellScriptExecSemantic["segments"] {
  const headerEnd = redirect.headerLineBreakSpan.end;
  const contentEnd = redirect.contentSpan.end;
  return [
    {
      kind: "command-header",
      text: document.source.slice(redirect.headerSpan.start, headerEnd),
    },
    { kind: "script-content", text: content, language },
    {
      kind: "command-footer",
      text: document.source.slice(contentEnd, redirect.terminatorSpan.end),
    },
  ];
}

function catHeredocSegments(
  document: ParsedShellDocument,
  redirect: Extract<ParsedShellRedirect, { kind: "heredoc" }>,
  content: string,
  filePath: string,
): ShellHeredocWriteSemantic["segments"] {
  const headerEnd = redirect.headerLineBreakSpan.end;
  const contentEnd = redirect.contentSpan.end;
  return [
    {
      kind: "command-header",
      text: document.source.slice(redirect.headerSpan.start, headerEnd),
    },
    { kind: "write-content", text: content, filePath },
    {
      kind: "command-footer",
      text: document.source.slice(contentEnd, redirect.terminatorSpan.end),
    },
  ];
}

type CatHeredocContext = {
  leading: readonly ParsedShellUnit[];
  owner: ParsedShellUnit;
  trailing: readonly ParsedShellUnit[];
};

function unitContainsCommand(
  unit: ParsedShellUnit,
  commandId: number,
): boolean {
  const pending = [unit];
  while (pending.length > 0) {
    const current = pending.pop()!;
    if (current.kind === "command" && current.commandId === commandId)
      return true;
    if (current.kind === "redirected_statement") {
      pending.push(current.body);
    } else if (
      current.kind === "program" ||
      current.kind === "list" ||
      current.kind === "pipeline"
    ) {
      for (const child of current.children) pending.push(child);
    }
  }
  return false;
}

function withoutBareTerminalColonNoop(
  document: ParsedShellDocument,
): Pick<
  Extract<ParsedShellUnit, { kind: "program" }>,
  "children" | "boundaries"
> | null {
  const { children, boundaries } = document.program;
  if (children.length < 2 || boundaries.length !== children.length) return null;
  const colonUnit = children.at(-1);
  const beforeColon = boundaries.at(-2);
  const terminal = boundaries.at(-1);
  if (
    colonUnit === undefined ||
    beforeColon === undefined ||
    terminal === undefined ||
    colonUnit.kind !== "command" ||
    (beforeColon.kind !== "newline" && beforeColon.kind !== "semicolon") ||
    beforeColon.span.end !== colonUnit.span.start ||
    terminal.kind !== "semicolon" ||
    terminal.text !== ";" ||
    terminal.span.start !== colonUnit.span.end
  )
    return null;
  const command = document.commands[colonUnit.commandId]!;
  if (
    command.name.kind !== "literal" ||
    command.name.value !== ":" ||
    command.assignments.length !== 0 ||
    command.arguments.length !== 0 ||
    command.redirectIds.length !== 0
  )
    return null;
  return {
    children: children.slice(0, -1),
    boundaries: boundaries.slice(0, -2),
  };
}

function catHeredocContext(
  document: ParsedShellDocument,
  ownerId: number,
): CatHeredocContext | null {
  const suffixless = withoutBareTerminalColonNoop(document);
  const { children, boundaries } = suffixless ?? document.program;
  if (boundaries.length !== children.length - 1) return null;
  if (
    boundaries.some(
      (boundary) =>
        boundary.kind !== "newline" && boundary.kind !== "semicolon",
    )
  )
    return null;
  const ownerIndices = children
    .map((child, index) => (unitContainsCommand(child, ownerId) ? index : -1))
    .filter((index) => index >= 0);
  if (ownerIndices.length !== 1) return null;
  const ownerIndex = ownerIndices[0]!;
  return {
    leading: children.slice(0, ownerIndex),
    owner: children[ownerIndex]!,
    trailing: children.slice(ownerIndex + 1),
  };
}

function directUnitCommand(
  document: ParsedShellDocument,
  unit: ParsedShellUnit,
): SimpleCommand | null {
  if (unit.kind === "command") return directCommand(document, unit);
  if (unit.kind === "redirected_statement" && unit.body.kind === "command")
    return directCommand(document, unit);
  return null;
}

function trailingCatHeredocOutput(
  document: ParsedShellDocument,
  units: readonly ParsedShellUnit[],
): OutputSegment[] {
  if (units.length !== 1) return [];
  const unit = units[0]!;
  if (unit.kind === "list") {
    if (
      unit.children.length !== 2 ||
      unit.operators.length !== 1 ||
      unit.operators[0]!.kind !== "and"
    )
      return [];
    const commands = unit.children.map((child) =>
      directUnitCommand(document, child),
    );
    if (commands.some((command) => command === null)) return [];
    const readback = parseLsReadbackCommands(commands as SimpleCommand[]);
    return readback?.ok ? structuredReadbackOutput(readback.value) : [];
  }
  return [];
}

function isMkdirSetup(command: SimpleCommand): boolean {
  return (
    command.name === "mkdir" &&
    command.args.length === 2 &&
    command.args[0]!.kind === "flag" &&
    command.args[0]!.text === "-p" &&
    command.args[1]!.kind === "value" &&
    command.redirects.length === 0
  );
}

function parseLsReadbackCommands(
  commands: readonly SimpleCommand[],
): ParseResult<{ filePath: string; sedStart: number; sedEnd: number }> | null {
  if (commands.length !== 2) return null;
  const ls = commands[0]!;
  const sed = commands[1]!;
  if (
    ls.name !== "ls" ||
    ls.args.length !== 2 ||
    ls.args[0]!.kind !== "flag" ||
    ls.args[0]!.text !== "-l" ||
    ls.args[1]!.kind !== "value" ||
    ls.redirects.length > 0 ||
    sed.name !== "sed" ||
    sed.redirects.length > 0
  )
    return null;
  const parsed = parseSedArgs(sed, true);
  const filePath = ls.args[1]!.text;
  if (!parsed.ok) return parsed;
  if (filePath !== parsed.value.filePath) return null;
  return {
    ok: true,
    value: { filePath, sedStart: parsed.value.start, sedEnd: parsed.value.end },
  };
}

function structuredReadbackOutput(readback: {
  filePath: string;
  sedStart: number;
  sedEnd: number;
}): OutputSegment[] {
  return [
    { kind: "summary-line" },
    {
      kind: "rows",
      source: {
        kind: "file",
        origin: { kind: "worktree", filePath: readback.filePath },
        range: {
          type: "lines",
          start: readback.sedStart,
          end: readback.sedEnd,
        },
      },
      numbering: null,
    },
  ];
}

function classifyLsReadbackAST(
  ast: ShellAST,
  originalCommand: string,
): ShellSemanticResult | null {
  if (
    ast.type !== "list" ||
    ast.op !== "&&" ||
    ast.left.type !== "simple" ||
    ast.right.type !== "simple"
  )
    return null;
  const readback = parseLsReadbackCommands([
    ast.left.command,
    ast.right.command,
  ]);
  if (readback === null || !readback.ok) return readback;
  return {
    ok: true,
    value: {
      kind: "output",
      command: originalCommand,
      output: structuredReadbackOutput(readback.value),
    },
  };
}

function classifyCatHeredoc(
  document: ParsedShellDocument,
  redirect: Extract<ParsedShellRedirect, { kind: "heredoc" }>,
  originalCommand: string,
): ShellSemanticResult {
  const command = adaptCommand(document, redirect.ownerId);
  if (command === null || command.name !== "cat")
    return reject("unsupported_command", "unsupported heredoc command");
  if (command.args.length > 0)
    return reject("invalid_heredoc", "unexpected arguments in heredoc command");
  if (redirect.header.arguments.length > 0 || redirect.header.continuation)
    return reject("invalid_heredoc", "unsupported heredoc header");
  const fds = shellFdTable(document, redirect.ownerId);
  const stdin = fds.get(0);
  const stdout = fds.get(1);
  if (stdin?.kind !== "source" || stdin.redirectId !== redirect.id)
    return reject("invalid_heredoc", "heredoc is not effective stdin");
  if (stdout?.kind !== "file")
    return reject(
      "missing_path",
      "heredoc write requires a literal stdout path",
    );
  const content = document.source.slice(
    redirect.contentSpan.start,
    redirect.contentSpan.end,
  );
  const context = catHeredocContext(document, redirect.ownerId);
  if (context === null)
    return reject("unsafe_shell_syntax", "unsupported heredoc structure");
  const ownerUnitCommand = directUnitCommand(document, context.owner);
  if (ownerUnitCommand === null || ownerUnitCommand.id !== command.id)
    return reject("unsafe_shell_syntax", "unsupported heredoc structure");
  for (const unit of context.leading) {
    if (unit.kind !== "command")
      return reject(
        "invalid_heredoc",
        "only leading mkdir -p setup is supported before heredoc",
      );
    const leading = directUnitCommand(document, unit);
    if (leading === null || !isMkdirSetup(leading))
      return reject(
        "invalid_heredoc",
        "only leading mkdir -p setup is supported before heredoc",
      );
  }
  const output = trailingCatHeredocOutput(document, context.trailing);
  return {
    ok: true,
    value: {
      kind: "write",
      command: originalCommand,
      commandName: "cat",
      filePath: stdout.path,
      heredoc: {
        delimiter: redirect.delimiter.value,
        quoted: redirect.delimiter.quoted,
        commandLine: document.source.slice(
          redirect.headerSpan.start,
          redirect.headerSpan.end,
        ),
        content,
        terminator: document.source.slice(
          redirect.terminatorSpan.start,
          redirect.terminatorSpan.end,
        ),
      },
      segments: catHeredocSegments(document, redirect, content, stdout.path),
      output: output.length > 0 ? output : undefined,
    },
  };
}

function classifyScriptHeredoc(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "heredoc" }>,
  originalCommand: string,
): ShellSemanticResult {
  const redirect = heredocForInvocation(document, invocation);
  const command = adaptCommand(document, invocation.commandId);
  if (command === null)
    return reject("unsupported_command", "unsupported heredoc command");
  if (
    redirect.header.arguments.length > 0 ||
    redirect.header.continuation ||
    command.redirects.some(
      (redirect) =>
        redirect.operator === ">" ||
        redirect.operator === ">>" ||
        redirect.operator === ">|" ||
        redirect.operator === "&>" ||
        redirect.operator === "&>>",
    )
  )
    return reject("invalid_heredoc", "unsupported interpreter heredoc header");
  const content = document.source.slice(
    redirect.contentSpan.start,
    redirect.contentSpan.end,
  );
  const language = invocation.interpreter.language;
  return {
    ok: true,
    value: {
      kind: "script-exec",
      command: originalCommand,
      commandName: invocation.interpreter.basename,
      language,
      scriptSource: {
        type: "heredoc",
        delimiter: redirect.delimiter.value,
        quoted: redirect.delimiter.quoted,
        content,
        terminator: document.source.slice(
          redirect.terminatorSpan.start,
          redirect.terminatorSpan.end,
        ),
        commandLine: document.source.slice(
          redirect.headerSpan.start,
          redirect.headerSpan.end,
        ),
      },
      segments: heredocSegments(document, redirect, content, language),
    },
  };
}

function invocationFlagAndPayload(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "inline" }>,
): { flag: string; content: string } | null {
  const command = commandForId(document, invocation.commandId);
  const flag = command.arguments[invocation.flagArgumentIndex]!.word as Extract<
    ParsedShellCommand["name"],
    { kind: "literal" }
  >;
  if (flag.value !== "-c" && flag.value !== "-e") return null;
  return {
    flag: flag.value,
    content: invocation.payload.text,
  };
}

function classifyInlineInvocation(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "inline" }>,
  originalCommand: string,
): ShellSemanticResult {
  if (invocation.interpreter.language === "bash") {
    const command = commandForId(document, invocation.commandId);
    const wrapperRejection = rejectRedirectEffect({
      name:
        invocation.prefix.kind === "env"
          ? "env"
          : invocation.interpreter.basename,
      redirects: command.redirectIds.map((id) => redirectForId(document, id)),
    });
    return classifyNormalizedDocument(
      invocation.child!,
      originalCommand,
      false,
      wrapperRejection,
    );
  }
  const metadata = invocationFlagAndPayload(document, invocation);
  if (metadata === null)
    return reject("unsafe_shell_syntax", "invalid normalized invocation");
  const commandName = invocation.interpreter.basename;
  return {
    ok: true,
    value: {
      kind: "script-exec",
      command: originalCommand,
      commandName,
      language: invocation.interpreter.language,
      scriptSource: {
        type: "inline",
        flag: metadata.flag,
        content: metadata.content,
      },
      segments: [
        { kind: "command-header", text: originalCommand },
        {
          kind: "script-content",
          text: metadata.content,
          language: invocation.interpreter.language,
        },
      ],
    },
  };
}

function classifyNormalizedAST(
  ast: ShellAST,
  originalCommand: string,
  wrapperRejection: ReturnType<typeof rejectRedirectEffect>,
): ShellSemanticResult {
  if (ast.type === "unsupported")
    return reject("unsupported_command", ast.reason);
  if (ast.type === "simple") {
    const name = ast.command.name;
    if (!name) return reject("empty", "empty command");
    if (STREAM_COMMANDS.has(name)) {
      return (
        wrapperRejection ?? classifyPipeline([ast.command], originalCommand, "")
      );
    }
    return reject(
      "unsupported_command",
      "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
    );
  }
  if (ast.type === "pipeline")
    return (
      wrapperRejection ?? classifyPipeline(ast.stages, originalCommand, "")
    );
  return (
    classifyLsReadbackAST(ast, originalCommand) ??
    wrapperRejection ??
    classifyGenericList(ast, originalCommand)
  );
}

function classifyNormalizedDocument(
  document: ParsedShellDocument,
  originalCommand: string,
  allowWholeCommand: boolean,
  wrapperRejection: ReturnType<typeof rejectRedirectEffect> = null,
): ShellSemanticResult {
  assertValidParsedShellDocument(document);
  const invocation = oneEligibleInvocation(document);
  if (
    invocation !== null &&
    (allowWholeCommand || invocation.interpreter.language !== "bash")
  ) {
    if (
      invocation.kind === "inline" &&
      invocation.interpreter.language === "bash" &&
      !ownsWholeCommand(document, invocation)
    )
      return reject(
        "unsupported_command",
        "unsupported shell wrapper structure",
      );
    return invocation.kind === "inline"
      ? classifyInlineInvocation(document, invocation, originalCommand)
      : classifyScriptHeredoc(document, invocation, originalCommand);
  }
  const heredocs = document.redirects.filter(
    (redirect): redirect is Extract<ParsedShellRedirect, { kind: "heredoc" }> =>
      redirect.kind === "heredoc",
  );
  if (heredocs.length > 0) {
    const owner = commandForId(document, heredocs[0]!.ownerId);
    if (owner.name.kind === "literal" && basename(owner.name.value) === "cat")
      return classifyCatHeredoc(document, heredocs[0]!, originalCommand);
    return reject("unsupported_command", "unsupported heredoc command");
  }
  return classifyNormalizedAST(
    adaptUnit(document, document.program),
    originalCommand,
    wrapperRejection,
  );
}

function decodePrintfEscapes(raw: string): string | null {
  if (raw.includes("%")) return null;
  let decoded = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch !== "\\") {
      decoded += ch;
      continue;
    }
    const next = raw[i + 1];
    if (!next) return null;
    if (next === "n") decoded += "\n";
    else if (next === "t") decoded += "\t";
    else if (next === "r") decoded += "\r";
    else if (next === "\\") decoded += "\\";
    else return null;
    i++;
  }
  return decoded;
}

function classifyPrintfListMember(cmd: SimpleCommand): OutputSegment[] | null {
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  if (valueArgs.length !== 1) return null;
  const raw = valueArgs[0]!.text;
  const decoded = decodePrintfEscapes(raw);
  if (decoded === null) return null;
  return [{ kind: "literal", text: decoded }];
}

function classifyWcSummary(cmd: SimpleCommand): OutputSegment[] | null {
  const flags = cmd.args.filter((a) => a.kind === "flag");
  const values = cmd.args.filter((a) => a.kind === "value");
  if (flags.length !== 1 || flags[0]!.text !== "-l") return null;
  if (values.length !== 1) return null;
  return [{ kind: "summary-line" }];
}

function classifyEchoListMember(cmd: SimpleCommand): OutputSegment[] | null {
  // Reject flags: -n (no trailing newline) and -e (interpret escapes) change output.
  if (cmd.args.some((a) => a.kind === "flag")) return null;
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  // POSIX: echo joins args with single spaces and appends a newline.
  const text = valueArgs.map((v) => v.text).join(" ") + "\n";
  return [{ kind: "literal", text }];
}

function classifyStepListMember(cmd: SimpleCommand): OutputSegment[] | null {
  switch (cmd.name) {
    case "printf":
      return classifyPrintfListMember(cmd);
    case "wc":
      return classifyWcSummary(cmd);
    case "echo":
      return classifyEchoListMember(cmd);
    default:
      return null;
  }
}

export async function parseShellSemantic(
  command: string,
): Promise<ShellSemanticResult> {
  if (!command.trim()) return reject("empty", "empty command");
  const parsed = await loadParsedShellDocument(command);
  if (!parsed.ok) {
    if (parsed.reason === "invalid_heredoc")
      return reject(
        "invalid_heredoc",
        "shell parser rejected heredoc: " + parsed.issue,
      );
    if (parsed.reason === "unsafe_shell_syntax")
      return reject(
        "unsafe_shell_syntax",
        "shell parser rejected syntax: " + parsed.issue,
      );
    return reject("unsafe_shell_syntax", "shell parser initialization failed");
  }
  const result = classifyNormalizedDocument(parsed.document, command, true);
  if (result.ok && result.value.kind !== "script-exec" && result.value.output) {
    const view = shellOutputView(result.value.output);
    if (!view.ok) return reject("unsupported_command", view.reason);
  }
  return result;
}

export function useShellSemantic(
  command: string | null,
): ShellSemanticResult | null {
  const [state, setState] = useState<{
    command: string | null;
    result: ShellSemanticResult | null;
  }>({ command: null, result: null });

  useEffect(() => {
    if (command === null) {
      setState({ command: null, result: null });
      return;
    }
    const requestedCommand = command;
    let active = true;
    setState({ command: requestedCommand, result: null });
    void parseShellSemantic(requestedCommand).then(
      (result) => {
        if (active) setState({ command: requestedCommand, result });
      },
      () => {
        if (active) setState({ command: requestedCommand, result: null });
      },
    );
    return () => {
      active = false;
    };
  }, [command]);

  return state.command === command ? state.result : null;
}
