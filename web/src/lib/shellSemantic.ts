import { useState, useEffect } from "preact/hooks";
import { langFromPath } from "../highlight";
import { derivePlan, type CommandStep, type ReadRange } from "./commandStep";
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
import type { ShellRedirectStateResult } from "./shellRedirectState";
import { reduceShellRedirectState } from "./shellRedirectState";

// Public types (API contract — do not change)
// ---------------------------------------------------------------------------

type ReadCommandName = "cat" | "nl" | "sed" | "head" | "tail" | "git";

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

export interface ShellReadSemantic {
  kind: "read";
  commandName: ReadCommandName;
  command: string;
  filePath: string;
  range: ReadRange;
  presentation: {
    lineNumbers: false | { style: "nl"; width?: number; separator?: string };
  };
}

export interface ShellSourceSpan {
  start: number;
  end: number;
  rawText: string;
}

export type ShellSemanticBase = {
  command: string;
  steps?: CommandStep[];
};

export interface ShellHeredocWriteSemantic {
  kind: "write";
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

export interface ShellDiffSemantic {
  kind: "diff";
  commandName: "git" | "diff";
  command: string;
  subcommand?: string; // "diff", "show", "log" (for git commands)
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

export interface ShellSearchSemantic {
  kind: "search";
  commandName: "rg";
  command: string;
  pattern: string;
  filePath: string;
}

export interface ShellStructuredOutputSemantic {
  kind: "structured-output";
  commandName: string;
  command: string;
}

export type ShellSemantic =
  | (ShellReadSemantic & ShellSemanticBase)
  | (ShellHeredocWriteSemantic & ShellSemanticBase)
  | (ShellDiffSemantic & ShellSemanticBase)
  | (ShellScriptExecSemantic & ShellSemanticBase)
  | (ShellSearchSemantic & ShellSemanticBase)
  | (ShellStructuredOutputSemantic & ShellSemanticBase);

export type ShellSemanticResult =
  | { ok: true; value: ShellSemantic }
  | { ok: false; code: RejectCode; reason: string };

// ---------------------------------------------------------------------------
type SimpleCommand = {
  id: number;
  name: string | null;
  args: CommandArg[];
  redirects: Redirect[];
};

type CommandArg =
  | { kind: "flag"; text: string }
  | { kind: "value"; text: string };

type Redirect = {
  op: ParsedShellRedirect["operator"];
};

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

const READ_COMMANDS = new Set<string>(["cat", "nl", "sed", "head", "tail"]);

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

type NlOptions = { width?: number; separator?: string };

type ShellOutputExpr =
  | {
      kind: "file-read";
      filePath: string;
      stageIndex: number;
      commandName: ReadCommandName;
    }
  | {
      kind: "diff-source";
      subcommand: string | undefined;
      commandName: "git" | "diff";
      stageIndex: number;
    }
  | {
      kind: "take-first-lines";
      count?: number;
      input: ShellOutputExpr;
      stageIndex: number;
    }
  | {
      kind: "take-last-lines";
      count: number;
      input: ShellOutputExpr;
      stageIndex: number;
    }
  | {
      kind: "take-lines-from";
      startLine: number;
      input: ShellOutputExpr;
      stageIndex: number;
    }
  | {
      kind: "select-lines";
      start: number;
      end: number;
      input: ShellOutputExpr;
      stageIndex: number;
    }
  | {
      kind: "line-number-prefix";
      input: ShellOutputExpr;
      stageIndex: number;
      options: NlOptions;
    }
  | {
      kind: "sparse-match-lines";
      input: ShellOutputExpr;
      pattern: string;
      stageIndex: number;
    }
  | {
      kind: "opaque-transform";
      input: ShellOutputExpr;
      commandName: string;
      stageIndex: number;
    };

type ParseResult<T> =
  | { ok: true; value: T }
  | { ok: false; code: RejectCode; reason: string };

function parseHeadArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ count?: number; filePath?: string }> {
  let count: number | undefined;
  let filePath: string | undefined;

  for (let i = 0; i < cmd.args.length; i++) {
    const arg = cmd.args[i]!;
    const text = arg.text;

    if (text === "--") continue;

    if (text === "-n") {
      const next = cmd.args[++i];
      const nextText = next?.kind === "value" ? next.text : "";
      const parsed = Number(nextText);
      if (!Number.isInteger(parsed) || parsed < 1) {
        return reject(
          "unsupported_option",
          "head -n requires a positive integer",
        );
      }
      count = parsed;
      continue;
    }

    const joined = text.match(/^-n([1-9]\d*)$/);
    if (joined) {
      count = Number(joined[1]);
      continue;
    }

    const legacy = text.match(/^-([1-9]\d*)$/);
    if (legacy) {
      count = Number(legacy[1]);
      continue;
    }

    if (arg.kind === "flag") {
      return reject("unsupported_option", `unsupported head option ${text}`);
    }

    if (filePath !== undefined) {
      return reject(
        "multiple_paths",
        "multiple file operands are not supported",
      );
    }
    filePath = text;
  }

  if (requireFile && filePath === undefined) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { count, filePath } };
}

function parseTailArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ range: ReadRange; filePath?: string }> {
  let range: ReadRange = { type: "all" };
  let filePath: string | undefined;

  for (let i = 0; i < cmd.args.length; i++) {
    const arg = cmd.args[i]!;
    const text = arg.text;

    if (text === "--") continue;

    if (text === "-n") {
      const next = cmd.args[++i];
      if (!next || next.kind !== "value") {
        return reject("unsupported_option", "tail -n requires an argument");
      }
      const plusMatch = next.text.match(/^\+([1-9]\d*)$/);
      if (plusMatch) {
        range = { type: "tail", startLine: Number(plusMatch[1]) };
        continue;
      }
      const countMatch = next.text.match(/^([1-9]\d*)$/);
      if (countMatch) {
        range = { type: "tail-count", count: Number(countMatch[1]) };
        continue;
      }
      return reject("unsupported_option", "tail -n requires +N or N");
    }

    const plus = text.match(/^-n\+([1-9]\d*)$/);
    if (plus) {
      range = { type: "tail", startLine: Number(plus[1]) };
      continue;
    }

    const joined = text.match(/^-n([1-9]\d*)$/);
    if (joined) {
      range = { type: "tail-count", count: Number(joined[1]) };
      continue;
    }

    const legacy = text.match(/^-([1-9]\d*)$/);
    if (legacy) {
      range = { type: "tail-count", count: Number(legacy[1]) };
      continue;
    }

    if (arg.kind === "flag") {
      return reject("unsupported_option", `unsupported tail option ${text}`);
    }

    if (filePath !== undefined) {
      return reject(
        "multiple_paths",
        "multiple file operands are not supported",
      );
    }
    filePath = text;
  }

  if (requireFile && filePath === undefined) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { range, filePath } };
}

function parseSedArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ start: number; end: number; filePath?: string }> {
  const nFlagIdx = cmd.args.findIndex(
    (a) => a.kind === "flag" && a.text === "-n",
  );
  if (nFlagIdx < 0) {
    return reject("unsupported_option", "only sed -n 'N,Mp' path is supported");
  }
  const exprArg = cmd.args[nFlagIdx + 1];
  if (!exprArg || exprArg.kind !== "value") {
    return reject("missing_path", "sed requires expression and path");
  }
  const m = exprArg.text.match(/^([1-9]\d*),([1-9]\d*)p$/);
  if (!m) return reject("invalid_range", "sed expression must be N,Mp");
  const start = Number(m[1]);
  const end = Number(m[2]);
  if (end < start) {
    return reject("invalid_range", "sed end line must be >= start line");
  }
  const pathArg = cmd.args[nFlagIdx + 2];
  if (requireFile && (!pathArg || pathArg.kind !== "value")) {
    return reject("missing_path", "sed requires expression and path");
  }
  if (
    cmd.args.length >
    nFlagIdx + (requireFile ? 3 : pathArg?.kind === "value" ? 3 : 2)
  ) {
    return reject("multiple_paths", "sed supports exactly one file operand");
  }
  return {
    ok: true,
    value: {
      start,
      end,
      filePath: pathArg?.kind === "value" ? pathArg.text : undefined,
    },
  };
}

function parseNlArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ options: NlOptions; filePath?: string }> {
  let filePath: string | undefined;
  const options: NlOptions = {};

  for (let i = 0; i < cmd.args.length; i++) {
    const arg = cmd.args[i]!;
    if (arg.kind === "value") {
      if (filePath !== undefined) {
        return reject(
          "multiple_paths",
          "multiple file operands are not supported",
        );
      }
      filePath = arg.text;
      continue;
    }

    const flag = arg.text;
    if (flag === "--" || flag === "-ba") continue;
    if (flag === "-w") {
      const next = cmd.args[++i];
      const width = next && next.kind === "value" ? Number(next.text) : NaN;
      if (!Number.isInteger(width) || width < 1) {
        return reject(
          "unsupported_option",
          "nl -w requires a positive integer",
        );
      }
      options.width = width;
      continue;
    }
    if (flag === "-s") {
      const next = cmd.args[++i];
      if (!next || next.kind !== "value") {
        return reject("unsupported_option", "nl -s requires a separator");
      }
      options.separator = next.text;
      continue;
    }
    return reject("unsupported_option", `unsupported nl option ${flag}`);
  }

  if (requireFile && filePath === undefined) {
    return reject("missing_path", "expected one file path");
  }
  return { ok: true, value: { options, filePath } };
}

function parseRgArgs(
  cmd: SimpleCommand,
  requireFile: boolean,
): ParseResult<{ pattern: string; filePath?: string }> {
  const toolName = cmd.name === "grep" ? "grep" : "rg";
  if (cmd.redirects.length > 0) {
    return reject(
      "unsafe_shell_syntax",
      `${toolName} redirections are not supported`,
    );
  }
  const hasOtherFlags = cmd.args.some(
    (a) => a.kind === "flag" && a.text !== "-n" && a.text !== "--line-number",
  );
  if (hasOtherFlags) {
    return reject("unsupported_option", `unsupported ${toolName} option`);
  }
  const hasLineNumbers = cmd.args.some(
    (a) => a.kind === "flag" && (a.text === "-n" || a.text === "--line-number"),
  );
  if (!hasLineNumbers) {
    return reject(
      "unsupported_option",
      `${toolName} must include -n/--line-number`,
    );
  }

  const values = cmd.args
    .filter((a): a is { kind: "value"; text: string } => a.kind === "value")
    .map((a) => a.text);
  const expectedCount = requireFile ? 2 : 1;
  if (values.length !== expectedCount) {
    return reject(
      values.length < expectedCount ? "missing_path" : "multiple_paths",
      requireFile
        ? `${toolName} -n requires exactly one pattern and one file operand`
        : `${toolName} -n requires exactly one pattern`,
    );
  }

  const pattern = values[0]!;
  const filePath = values[1];
  if (!pattern)
    return reject("variable_path", `${toolName} pattern/path must be literal`);
  if (requireFile) {
    if (!filePath)
      return reject(
        "variable_path",
        `${toolName} pattern/path must be literal`,
      );
    if (filePath === "." || filePath === ".." || filePath.endsWith("/")) {
      return reject(
        "unsupported_command",
        `${toolName} target must be a file path`,
      );
    }
  }

  return { ok: true, value: { pattern, filePath } };
}

function parseStageAsSource(
  cmd: SimpleCommand,
  stageIndex: number,
): ParseResult<ShellOutputExpr> {
  const name = cmd.name;
  if (!name) return reject("empty", "empty command");

  if (cmd.redirects.some((r) => r.op !== "<<")) {
    return reject(
      "redirection_on_read",
      "read commands with redirection are not display-only reads",
    );
  }

  if (name === "cat") {
    const flags = cmd.args.filter((a) => a.kind === "flag" && a.text !== "--");
    if (flags.length > 0) {
      return reject(
        "unsupported_option",
        `unsupported cat option ${flags[0]!.text}`,
      );
    }
    const values = cmd.args
      .filter((a) => a.kind === "value")
      .map((a) => a.text);
    if (values.length === 0)
      return reject("missing_path", "expected one file path");
    if (values.length > 1)
      return reject(
        "multiple_paths",
        "multiple file operands are not supported",
      );
    return {
      ok: true,
      value: {
        kind: "file-read",
        filePath: values[0]!,
        stageIndex,
        commandName: "cat",
      },
    };
  }

  if (name === "head") {
    const parsed = parseHeadArgs(cmd, true);
    if (!parsed.ok) return parsed;
    const base: ShellOutputExpr = {
      kind: "file-read",
      filePath: parsed.value.filePath!,
      stageIndex,
      commandName: "head",
    };
    return {
      ok: true,
      value: {
        kind: "take-first-lines",
        count: parsed.value.count,
        input: base,
        stageIndex,
      },
    };
  }

  if (name === "tail") {
    const parsed = parseTailArgs(cmd, true);
    if (!parsed.ok) return parsed;
    const base: ShellOutputExpr = {
      kind: "file-read",
      filePath: parsed.value.filePath!,
      stageIndex,
      commandName: "tail",
    };
    if (parsed.value.range.type === "tail") {
      return {
        ok: true,
        value: {
          kind: "take-lines-from",
          startLine: parsed.value.range.startLine,
          input: base,
          stageIndex,
        },
      };
    }
    if (parsed.value.range.type === "tail-count") {
      return {
        ok: true,
        value: {
          kind: "take-last-lines",
          count: parsed.value.range.count,
          input: base,
          stageIndex,
        },
      };
    }
    return { ok: true, value: base };
  }

  if (name === "sed") {
    const parsed = parseSedArgs(cmd, true);
    if (!parsed.ok) return parsed;
    const base: ShellOutputExpr = {
      kind: "file-read",
      filePath: parsed.value.filePath!,
      stageIndex,
      commandName: "sed",
    };
    return {
      ok: true,
      value: {
        kind: "select-lines",
        start: parsed.value.start,
        end: parsed.value.end,
        input: base,
        stageIndex,
      },
    };
  }

  if (name === "nl") {
    const parsed = parseNlArgs(cmd, true);
    if (!parsed.ok) return parsed;
    const base: ShellOutputExpr = {
      kind: "file-read",
      filePath: parsed.value.filePath!,
      stageIndex,
      commandName: "nl",
    };
    return {
      ok: true,
      value: {
        kind: "line-number-prefix",
        input: base,
        stageIndex,
        options: parsed.value.options,
      },
    };
  }

  if (name === "rg" || name === "grep") {
    const parsed = parseRgArgs(cmd, true);
    if (!parsed.ok) return parsed;
    return {
      ok: true,
      value: {
        kind: "sparse-match-lines",
        input: {
          kind: "file-read",
          filePath: parsed.value.filePath!,
          stageIndex,
          commandName: "cat",
        },
        pattern: parsed.value.pattern,
        stageIndex,
      },
    };
  }

  if (name === "git") {
    const git = classifyGitCommand(cmd, "");
    if (!git.ok) return git;
    if (git.value.kind === "read") {
      return {
        ok: true,
        value: {
          kind: "file-read",
          filePath: git.value.filePath,
          stageIndex,
          commandName: "git",
        },
      };
    }
    if (git.value.kind === "diff") {
      return {
        ok: true,
        value: {
          kind: "diff-source",
          subcommand: git.value.subcommand,
          commandName: "git",
          stageIndex,
        },
      };
    }
    return reject("unsupported_command", "unsupported git stage in pipeline");
  }

  if (name === "diff") {
    return {
      ok: true,
      value: {
        kind: "diff-source",
        subcommand: undefined,
        commandName: "diff",
        stageIndex,
      },
    };
  }

  if (
    OPAQUE_TRANSFORM_COMMANDS.has(name) ||
    (name === "awk" &&
      cmd.args.every((a) => a.kind === "flag" || a.text.startsWith("{")))
  ) {
    return reject(
      "unsafe_shell_syntax",
      "pipeline has no recognized file-reading, search, or diff stage",
    );
  }

  return reject(
    "unsupported_command",
    "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
  );
}

function parseStageAsTransform(
  cmd: SimpleCommand,
  stageIndex: number,
): ParseResult<(input: ShellOutputExpr) => ShellOutputExpr> {
  const name = cmd.name;
  if (!name) return reject("empty", "empty command");

  if (name === "cat") {
    const flags = cmd.args.filter((a) => a.kind === "flag" && a.text !== "--");
    if (flags.length > 0) {
      return reject(
        "unsupported_option",
        `unsupported cat option ${flags[0]!.text}`,
      );
    }
    const values = cmd.args.filter((a) => a.kind === "value");
    if (values.length === 0) return { ok: true, value: (input) => input };
    return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
  }

  if (name === "head") {
    const parsed = parseHeadArgs(cmd, false);
    if (!parsed.ok) return parsed;
    if (parsed.value.filePath) {
      return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
    }
    if (parsed.value.count === undefined) {
      return { ok: true, value: (input) => input };
    }
    return {
      ok: true,
      value: (input) => ({
        kind: "take-first-lines",
        count: parsed.value.count,
        input,
        stageIndex,
      }),
    };
  }

  if (name === "tail") {
    const parsed = parseTailArgs(cmd, false);
    if (!parsed.ok) return parsed;
    if (parsed.value.filePath) {
      return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
    }
    if (parsed.value.range.type === "all") {
      return { ok: true, value: (input) => input };
    }
    return {
      ok: true,
      value: (input) => {
        if (parsed.value.range.type === "tail") {
          return {
            kind: "take-lines-from",
            startLine: parsed.value.range.startLine,
            input,
            stageIndex,
          };
        }
        if (parsed.value.range.type === "tail-count") {
          return {
            kind: "take-last-lines",
            count: parsed.value.range.count,
            input,
            stageIndex,
          };
        }
        return input;
      },
    };
  }

  if (name === "sed") {
    const parsed = parseSedArgs(cmd, false);
    if (!parsed.ok) return parsed;
    if (parsed.value.filePath) {
      return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
    }
    return {
      ok: true,
      value: (input) => ({
        kind: "select-lines",
        start: parsed.value.start,
        end: parsed.value.end,
        input,
        stageIndex,
      }),
    };
  }

  if (name === "nl") {
    const parsed = parseNlArgs(cmd, false);
    if (!parsed.ok) return parsed;
    if (parsed.value.filePath) {
      return reject("unsafe_shell_syntax", "pipeline has multiple read stages");
    }
    return {
      ok: true,
      value: (input) => ({
        kind: "line-number-prefix",
        input,
        stageIndex,
        options: parsed.value.options,
      }),
    };
  }

  if (name === "rg" || name === "grep") {
    const parsed = parseRgArgs(cmd, false);
    if (!parsed.ok) return parsed;
    return {
      ok: true,
      value: (input) => ({
        kind: "sparse-match-lines",
        input,
        pattern: parsed.value.pattern,
        stageIndex,
      }),
    };
  }

  if (name === "git" || name === "diff") {
    return reject("unsafe_shell_syntax", "pipeline has multiple diff stages");
  }

  if (
    OPAQUE_TRANSFORM_COMMANDS.has(name) ||
    (name === "awk" &&
      cmd.args.every((a) => a.kind === "flag" || a.text.startsWith("{")))
  ) {
    return {
      ok: true,
      value: (input) => ({
        kind: "opaque-transform",
        input,
        commandName: name,
        stageIndex,
      }),
    };
  }

  return reject(
    "unsafe_shell_syntax",
    `pipeline stage "${name}" is not a recognized formatting command`,
  );
}

function buildShellOutputExpr(
  stages: SimpleCommand[],
): ParseResult<ShellOutputExpr> {
  if (stages.length === 0) return reject("empty", "empty pipeline");
  const first = parseStageAsSource(stages[0]!, 0);
  if (!first.ok) return first;

  let expr = first.value;
  for (let i = 1; i < stages.length; i++) {
    const transform = parseStageAsTransform(stages[i]!, i);
    if (!transform.ok) return transform;
    expr = transform.value(expr);
  }
  return { ok: true, value: expr };
}

function lowerReadFromFileExpr(
  expr: Extract<ShellOutputExpr, { kind: "file-read" }>,
  originalCommand: string,
  range: ReadRange,
  presentation: ShellReadSemantic["presentation"] = { lineNumbers: false },
  commandNameOverride?: "cat" | "nl" | "sed" | "head" | "tail",
): ShellSemanticResult {
  if (expr.commandName === "git") {
    return {
      ok: true,
      value: {
        kind: "read",
        command: originalCommand,
        commandName: "git",
        filePath: expr.filePath,
        range,
        presentation,
      },
    };
  }

  const language = langFromPath(expr.filePath) || "text";
  const commandName = commandNameOverride ?? expr.commandName;
  const steps: CommandStep[] = [
    {
      kind: "read-file",
      order: 0,
      commandName,
      filePath: expr.filePath,
      range,
      outputShape: {
        kind: "content",
        format: { kind: "content", language },
        validator: "non-empty",
      },
      blockId: commandName === "sed" ? "sed-output" : undefined,
    },
  ];
  return {
    ok: true,
    value: {
      kind: "read",
      command: originalCommand,
      commandName,
      filePath: expr.filePath,
      range,
      presentation,
      steps,
    },
  };
}

function lowerDiffSource(
  expr: Extract<ShellOutputExpr, { kind: "diff-source" }>,
  originalCommand: string,
): ShellSemanticResult {
  return {
    ok: true,
    value: {
      kind: "diff",
      commandName: expr.commandName,
      command: originalCommand,
      subcommand: expr.subcommand,
    },
  };
}

function conservativeLower(
  expr: ShellOutputExpr,
  originalCommand: string,
): ShellSemanticResult {
  const rejectUnsupportedPipeline = () =>
    reject("unsafe_shell_syntax", "pipeline has multiple read stages");
  const lowerAsDiffOnly = (input: ShellOutputExpr): ShellSemanticResult => {
    let current = input;
    while (current.kind !== "diff-source") {
      if (
        current.kind === "file-read" ||
        current.kind === "sparse-match-lines" ||
        (current.kind === "select-lines" &&
          current.input.kind === "line-number-prefix") ||
        (current.kind === "line-number-prefix" &&
          current.input.kind === "select-lines")
      )
        return rejectUnsupportedPipeline();
      current = current.input;
    }
    return lowerDiffSource(current, originalCommand);
  };

  if (expr.kind === "file-read") {
    return lowerReadFromFileExpr(expr, originalCommand, { type: "all" });
  }
  if (expr.kind === "diff-source")
    return lowerDiffSource(expr, originalCommand);
  if (expr.kind === "take-first-lines") {
    if (expr.input.kind === "file-read") {
      const range = expr.count
        ? ({ type: "head", count: expr.count } as const)
        : ({ type: "all" } as const);
      return lowerReadFromFileExpr(
        expr.input,
        originalCommand,
        range,
        undefined,
        "head",
      );
    }
    return lowerAsDiffOnly(expr.input);
  }
  if (expr.kind === "take-last-lines") {
    if (expr.input.kind === "file-read") {
      return lowerReadFromFileExpr(
        expr.input,
        originalCommand,
        {
          type: "tail-count",
          count: expr.count,
        },
        undefined,
        "tail",
      );
    }
    return lowerAsDiffOnly(expr.input);
  }
  if (expr.kind === "take-lines-from") {
    if (expr.input.kind === "file-read") {
      return lowerReadFromFileExpr(
        expr.input,
        originalCommand,
        {
          type: "tail",
          startLine: expr.startLine,
        },
        undefined,
        "tail",
      );
    }
    return lowerAsDiffOnly(expr.input);
  }
  if (expr.kind === "select-lines") {
    if (expr.input.kind === "file-read") {
      return lowerReadFromFileExpr(
        expr.input,
        originalCommand,
        {
          type: "lines",
          start: expr.start,
          end: expr.end,
        },
        undefined,
        "sed",
      );
    }
    if (expr.input.kind === "line-number-prefix") {
      if (expr.input.input.kind !== "file-read")
        return rejectUnsupportedPipeline();
      const lineNumbers = {
        style: "nl" as const,
        ...(expr.input.options.width !== undefined
          ? { width: expr.input.options.width }
          : {}),
        ...(expr.input.options.separator !== undefined
          ? { separator: expr.input.options.separator }
          : {}),
      };
      return lowerReadFromFileExpr(
        expr.input.input,
        originalCommand,
        {
          type: "lines",
          start: expr.start,
          end: expr.end,
        },
        { lineNumbers },
        "sed",
      );
    }
    return lowerAsDiffOnly(expr.input);
  }
  if (expr.kind === "line-number-prefix") {
    if (expr.input.kind === "select-lines") {
      return rejectUnsupportedPipeline();
    }
    if (expr.input.kind === "file-read") {
      const lineNumbers = {
        style: "nl" as const,
        ...(expr.options.width !== undefined
          ? { width: expr.options.width }
          : {}),
        ...(expr.options.separator !== undefined
          ? { separator: expr.options.separator }
          : {}),
      };
      return lowerReadFromFileExpr(
        expr.input,
        originalCommand,
        { type: "all" },
        { lineNumbers },
        "nl",
      );
    }
    return lowerAsDiffOnly(expr.input);
  }
  if (expr.kind === "sparse-match-lines") {
    if (expr.input.kind !== "file-read") {
      return rejectUnsupportedPipeline();
    }
    const language = langFromPath(expr.input.filePath) || "text";
    const steps: CommandStep[] = [
      {
        kind: "search",
        order: 0,
        commandName: "rg",
        pattern: expr.pattern,
        filePath: expr.input.filePath,
        outputShape: {
          kind: "content",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language },
            },
          },
          validator: "colon-line-number-prefixed",
        },
        blockId: "rg-results",
      },
    ];
    return {
      ok: true,
      value: {
        kind: "search",
        commandName: "rg",
        command: originalCommand,
        pattern: expr.pattern,
        filePath: expr.input.filePath,
        steps,
      },
    };
  }
  return lowerAsDiffOnly(expr.input);
}

function classifyReadCommand(
  cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
  const expr = buildShellOutputExpr([cmd]);
  if (!expr.ok) return expr;
  return conservativeLower(expr.value, originalCommand);
}

function classifyPipeline(
  stages: SimpleCommand[],
  originalCommand: string,
): ShellSemanticResult {
  const expr = buildShellOutputExpr(stages);
  if (!expr.ok) return expr;
  return conservativeLower(expr.value, originalCommand);
}

function resolveAgainstCd(cdPath: string, path: string): string {
  return path.startsWith("/") || !cdPath ? path : cdPath + "/" + path;
}

function resolveStepAgainstCd(cdPath: string, step: CommandStep): CommandStep {
  if (
    (step.kind === "read-file" ||
      step.kind === "search" ||
      step.kind === "plain-output") &&
    step.filePath !== undefined
  ) {
    return { ...step, filePath: resolveAgainstCd(cdPath, step.filePath) };
  }
  return step;
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
  const steps: CommandStep[] = [];

  for (const member of members) {
    const cmd = member[0]!;
    if (isCd(member)) {
      const values = cmd.args.filter((a) => a.kind === "value");
      // Use last value (Codex behaviour: cd dir1 dir2 uses dir2)
      const target = values.at(-1)?.text ?? "";
      if (!target) {
        return reject(
          "unsafe_shell_syntax",
          "cd target must be a literal path",
        );
      }
      cdPath = resolveAgainstCd(cdPath, target);
      continue;
    }

    if (singleMember) {
      const result = classifyPipeline(member, originalCommand);
      if (!result.ok) return result;
      const value = result.value;
      if (value.kind !== "read" && value.kind !== "search") {
        singleResult = result;
        continue;
      }
      if (value.kind === "read" && value.commandName === "git") {
        return reject(
          "unsafe_shell_syntax",
          "git object paths are not relative to cd",
        );
      }
      singleResult = {
        ok: true,
        value: {
          ...value,
          filePath: resolveAgainstCd(cdPath, value.filePath),
          steps: value.steps?.map((step) => resolveStepAgainstCd(cdPath, step)),
        },
      };
      continue;
    }

    let memberSteps: CommandStep[];
    if (member.length === 1 && cmd.name !== "git" && cmd.name !== "diff") {
      const result = classifySimpleCommandAsListMember(cmd, originalCommand);
      if (!result) {
        return reject(
          "unsupported_command",
          `unsupported command in list: ${cmd.name ?? "(unnamed)"}`,
        );
      }
      memberSteps = result.steps;
    } else {
      const result = classifyPipeline(member, originalCommand);
      if (!result.ok) return result;
      if (result.value.kind === "read" && result.value.commandName === "git") {
        return reject(
          "unsupported_command",
          "git object reads cannot be combined with other list output",
        );
      }
      if (!result.value.steps) {
        return reject(
          "unsupported_command",
          "diff output cannot be combined with other list output",
        );
      }
      memberSteps = result.value.steps;
    }

    for (const step of memberSteps) {
      steps.push({
        ...resolveStepAgainstCd(cdPath, step),
        order: steps.length,
        blockId: undefined,
      });
    }
  }

  if (singleResult) return singleResult;

  if (!steps.some((s) => s.kind === "read-file")) {
    return reject(
      "unsupported_command",
      "list must contain at least one read command",
    );
  }

  return {
    ok: true,
    value: {
      kind: "structured-output",
      commandName: "shell",
      command: originalCommand,
      steps,
    },
  };
}

/**
 * Classify a heredoc AST node — dispatches to cat-write or script-exec.
 */
function classifyGitCommand(
  cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  const subcommand = valueArgs[0]?.text;

  if (!subcommand)
    return reject("unsupported_command", "bare git without subcommand");

  if (subcommand === "diff") {
    return {
      ok: true,
      value: {
        kind: "diff",
        commandName: "git",
        command: originalCommand,
        subcommand: "diff",
      },
    };
  }

  if (subcommand === "show") {
    // Check if any value arg (after the subcommand) contains ':' → file content read
    const showArgs = valueArgs.slice(1);
    const colonArg = showArgs.find((a) => a.text.includes(":"));
    if (colonArg) {
      const colonIdx = colonArg.text.indexOf(":");
      const filePath = colonArg.text.slice(colonIdx + 1);
      return {
        ok: true,
        value: {
          kind: "read",
          commandName: "git",
          command: originalCommand,
          filePath,
          range: { type: "all" },
          presentation: { lineNumbers: false },
        },
      };
    }
    return {
      ok: true,
      value: {
        kind: "diff",
        commandName: "git",
        command: originalCommand,
        subcommand: "show",
      },
    };
  }

  if (subcommand === "log") {
    const flags = cmd.args.filter((a) => a.kind === "flag").map((a) => a.text);
    if (flags.includes("-p") || flags.includes("--patch")) {
      return {
        ok: true,
        value: {
          kind: "diff",
          commandName: "git",
          command: originalCommand,
          subcommand: "log",
        },
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
  const args: CommandArg[] = [];
  for (const argument of command.arguments) {
    if (argument.word.kind !== "literal") return null;
    args.push({
      kind: argument.word.value.startsWith("-") ? "flag" : "value",
      text: argument.word.value,
    });
  }
  const redirects = command.redirectIds.map((redirectId) => {
    const redirect = redirectForId(document, redirectId);
    return { op: redirect.operator };
  });
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

function isLiteralCd(command: SimpleCommand | null): command is SimpleCommand {
  return (
    command !== null &&
    command.name === "cd" &&
    command.args.length === 1 &&
    command.args[0]!.kind === "value" &&
    command.redirects.length === 0
  );
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

function trailingCatHeredocSteps(
  document: ParsedShellDocument,
  units: readonly ParsedShellUnit[],
): CommandStep[] {
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
    return readback === null ? [] : structuredReadbackSteps(readback);
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
): { filePath: string; sedStart: number; sedEnd: number } | null {
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
    sed.args.length !== 3 ||
    sed.args[0]!.kind !== "flag" ||
    sed.args[0]!.text !== "-n" ||
    sed.args[1]!.kind !== "value" ||
    sed.args[2]!.kind !== "value" ||
    sed.redirects.length > 0
  )
    return null;
  const range = sed.args[1]!.text.match(/^([1-9]\d*),([1-9]\d*)p$/);
  if (!range) return null;
  const filePath = ls.args[1]!.text;
  const sedPath = sed.args[2]!.text;
  const sedStart = Number(range[1]);
  const sedEnd = Number(range[2]);
  if (filePath !== sedPath || sedEnd < sedStart) return null;
  return { filePath, sedStart, sedEnd };
}

function parseLsDirectoryCommand(command: SimpleCommand): string | null {
  if (
    command.name !== "ls" ||
    command.args.length !== 2 ||
    command.args[0]!.kind !== "flag" ||
    command.args[0]!.text !== "-1" ||
    command.args[1]!.kind !== "value" ||
    command.redirects.length > 0
  )
    return null;
  return command.args[1]!.text;
}

function structuredReadbackSteps(readback: {
  filePath: string;
  sedStart: number;
  sedEnd: number;
}): CommandStep[] {
  const language = langFromPath(readback.filePath) || "text";
  return [
    {
      kind: "plain-output",
      order: 0,
      commandName: "ls",
      filePath: readback.filePath,
      outputShape: {
        kind: "fixed-lines",
        count: 1,
        format: { kind: "content", language: "shell-output" },
        validator: "non-empty",
      },
      blockId: "listing",
    },
    {
      kind: "read-file",
      order: 1,
      commandName: "sed",
      filePath: readback.filePath,
      range: {
        type: "lines",
        start: readback.sedStart,
        end: readback.sedEnd,
      },
      outputShape: {
        kind: "content",
        format: { kind: "content", language },
        validator: "non-empty",
      },
      blockId: "sed-output",
    },
  ];
}

function classifyLsCommands(
  commands: readonly SimpleCommand[],
  originalCommand: string,
): ShellSemanticResult | null {
  if (commands.length === 1 && parseLsDirectoryCommand(commands[0]!) !== null)
    return {
      ok: true,
      value: {
        kind: "structured-output",
        commandName: "ls",
        command: originalCommand,
      },
    };
  return null;
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
  if (readback === null) return null;
  return {
    ok: true,
    value: {
      kind: "structured-output",
      commandName: "ls",
      command: originalCommand,
      steps: structuredReadbackSteps(readback),
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
  const state: ShellRedirectStateResult = reduceShellRedirectState(
    document,
    redirect.ownerId,
  );
  if (state.effectiveStdinRedirectId !== redirect.id)
    return reject("invalid_heredoc", "heredoc is not effective stdin");
  if (state.literalStdoutPath === null)
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
  const trailingSteps = trailingCatHeredocSteps(document, context.trailing);
  const steps: CommandStep[] = [
    {
      kind: "write-file",
      order: 0,
      targetPath: state.literalStdoutPath,
      contentNodeId: "heredoc-body",
      outputShape: { kind: "none" },
    },
    ...trailingSteps.map((step, index) => ({
      ...step,
      order: index + 1,
    })),
  ];
  return {
    ok: true,
    value: {
      kind: "write",
      command: originalCommand,
      commandName: "cat",
      filePath: state.literalStdoutPath,
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
      segments: catHeredocSegments(
        document,
        redirect,
        content,
        state.literalStdoutPath,
      ),
      steps: trailingSteps.length > 0 ? steps : undefined,
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
        redirect.op === ">" ||
        redirect.op === ">>" ||
        redirect.op === ">|" ||
        redirect.op === "&>" ||
        redirect.op === "&>>",
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
    return classifyNormalizedDocument(
      invocation.child!,
      originalCommand,
      false,
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
): ShellSemanticResult {
  if (ast.type === "unsupported")
    return reject("unsupported_command", ast.reason);
  if (ast.type === "simple") {
    if (ast.command.name === "ls") {
      const classified = classifyLsCommands([ast.command], originalCommand);
      if (classified !== null) return classified;
    }
    const name = ast.command.name;
    if (!name) return reject("empty", "empty command");
    if (
      READ_COMMANDS.has(name) ||
      name === "rg" ||
      name === "grep" ||
      name === "git" ||
      name === "diff"
    ) {
      const expr = buildShellOutputExpr([ast.command]);
      if (!expr.ok) return expr;
      return conservativeLower(expr.value, originalCommand);
    }
    return reject(
      "unsupported_command",
      "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
    );
  }
  if (ast.type === "pipeline")
    return classifyPipeline(ast.stages, originalCommand);
  return (
    classifyLsReadbackAST(ast, originalCommand) ??
    classifyGenericList(ast, originalCommand)
  );
}

function classifyNormalizedDocument(
  document: ParsedShellDocument,
  originalCommand: string,
  allowWholeCommand: boolean,
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

function classifyPrintfListMember(
  cmd: SimpleCommand,
): { steps: CommandStep[] } | null {
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  if (valueArgs.length !== 1) return null;
  const raw = valueArgs[0]!.text;
  const decoded = decodePrintfEscapes(raw);
  if (decoded === null) return null;
  return {
    steps: [
      {
        kind: "plain-output",
        order: 0,
        commandName: "printf",
        outputShape: {
          kind: "literal",
          text: decoded,
          format: { kind: "content", language: "shell-output" },
        },
      },
    ],
  };
}

function classifyWcSummary(
  cmd: SimpleCommand,
): { steps: CommandStep[] } | null {
  const flags = cmd.args.filter((a) => a.kind === "flag");
  const values = cmd.args.filter((a) => a.kind === "value");
  if (flags.length !== 1 || flags[0]!.text !== "-l") return null;
  if (values.length !== 1) return null;
  if (cmd.redirects.length > 0) return null;
  const filePath = values[0]!.text;
  return {
    steps: [
      {
        kind: "plain-output",
        order: 0,
        commandName: "wc",
        filePath,
        outputShape: {
          kind: "fixed-lines",
          count: 1,
          format: { kind: "content", language: "shell-output" },
          validator: "non-empty",
        },
      },
    ],
  };
}

function classifyEchoListMember(
  cmd: SimpleCommand,
): { steps: CommandStep[] } | null {
  // Reject flags: -n (no trailing newline) and -e (interpret escapes) change output.
  if (cmd.args.some((a) => a.kind === "flag")) return null;
  if (cmd.redirects.length > 0) return null;
  const valueArgs = cmd.args.filter((a) => a.kind === "value");
  // POSIX: echo joins args with single spaces and appends a newline.
  const text = valueArgs.map((v) => v.text).join(" ") + "\n";
  return {
    steps: [
      {
        kind: "plain-output",
        order: 0,
        commandName: "echo",
        outputShape: {
          kind: "literal",
          text,
          format: { kind: "content", language: "shell-output" },
        },
      },
    ],
  };
}

function classifySimpleCommandAsListMember(
  cmd: SimpleCommand,
  originalCommand: string,
): { steps: CommandStep[] } | null {
  switch (cmd.name) {
    case "sed":
    case "cat":
    case "head":
    case "tail":
    case "nl": {
      const r = classifyReadCommand(cmd, originalCommand);
      return r.ok ? { steps: r.value.steps ?? [] } : null;
    }
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
  if (result.ok && result.value.steps && !derivePlan(result.value.steps)) {
    return reject(
      "unsupported_command",
      "shell output steps do not define an unambiguous output plan",
    );
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
