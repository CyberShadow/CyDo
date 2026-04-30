import { useState, useEffect } from "preact/hooks";
import {
  tokenizeWithScopes,
  type TokenWithScopes,
  langFromPath,
} from "../highlight";
import type { ShikiTheme } from "../highlight";
import type {
  OutputPlan,
  OutputBlockPlan,
  SpanValidatorId,
} from "./shellOutputPlan";
import {
  parseCommandSourceTree,
  type SourceNode,
  type SourceSegment,
} from "./sourceTree";
import { useCurrentTheme } from "../useTheme";

// ---------------------------------------------------------------------------
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
  range:
    | { type: "all" }
    | { type: "lines"; start: number; end: number }
    | { type: "head"; count: number }
    | { type: "tail"; startLine: number }
    | { type: "tail-count"; count: number };
  presentation: {
    lineNumbers: false | { style: "nl"; width?: number; separator?: string };
  };
}

export interface ShellSourceSpan {
  start: number;
  end: number;
  rawText: string;
}

export type ShellEscapingScheme =
  | { kind: "shell-single-quote" }
  | { kind: "shell-double-quote"; conservative: true }
  | {
      kind: "shell-heredoc";
      delimiter: string;
      quoted: boolean;
      supportsExitReentry: false;
    };

export interface ShellEmbeddedContent {
  id: string;
  language: string;
  source: ShellSourceSpan;
  decodedText?: string;
  segments: ShellEmbeddedContentSegment[];
}

export type ShellEmbeddedContentSegment =
  | { kind: "text"; text: string; source: ShellSourceSpan }
  | {
      kind: "embed";
      role: "shell-wrapper-payload" | "inline-script" | "heredoc-body";
      escaping: ShellEscapingScheme;
      content: ShellEmbeddedContent;
      source: ShellSourceSpan;
    };

export type ShellInputSegment =
  | {
      kind:
        | "wrapper-prefix"
        | "command-header"
        | "heredoc-terminator"
        | "command-trailing"
        | "wrapper-suffix"
        | "shell-text";
      text: string;
      source: ShellSourceSpan;
      language?: "bash" | "shell-output" | "text";
    }
  | {
      kind: "embedded-content";
      role: "write-content" | "script-content" | "heredoc-body";
      text: string;
      source: ShellSourceSpan;
      language: string;
      filePath?: string;
      contentNodeId: string;
    };

export type ShellSemanticEffect =
  | {
      kind: "write-file";
      order: number;
      targetPath: string;
      contentNodeId: string;
    }
  | {
      kind: "execute-script";
      order: number;
      commandName: string;
      language: string;
      contentNodeId: string;
    }
  | {
      kind: "search";
      order: number;
      commandName: "rg";
      pattern: string;
      filePath: string;
    }
  | {
      kind: "read-file";
      order: number;
      commandName: "sed" | "cat" | "head" | "tail";
      filePath: string;
      range?: ShellReadSemantic["range"];
    }
  | { kind: "plain-output"; order: number; commandName: string };

export type ShellSemanticBase = {
  command: string;
  source?: ShellSourceSpan;
  sourceTree?: SourceNode;
  inputSegments?: ShellInputSegment[];
  embeddedContent?: ShellEmbeddedContent[];
  effects?: ShellSemanticEffect[];
  outputPlan?: OutputPlan;
};

export interface ShellHeredocWriteSemantic {
  kind: "write";
  commandName: "cat";
  command: string;
  filePath: string;
  writeMode: "overwrite";
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
// Layer 1: Shiki scope → ShellToken mapping
// ---------------------------------------------------------------------------

type ShellTokenRole =
  | "command"
  | "flag"
  | "argument"
  | "string"
  | "pipe"
  | "and"
  | "or"
  | "semicolon"
  | "redirect"
  | "heredoc-op"
  | "heredoc-delim"
  | "escape"
  | "whitespace"
  | "unknown";

interface ShellToken {
  /** Extracted text: quotes stripped from strings, raw otherwise */
  text: string;
  /** Original Shiki token content */
  raw: string;
  role: ShellTokenRole;
  /** Whether the heredoc delimiter was quoted (<<'EOF') */
  quoted?: boolean;
}

function allScopesOf(tok: TokenWithScopes): string[] {
  return tok.explanation.flatMap((e) => e.scopes.map((s) => s.scopeName));
}

/**
 * Map Shiki scope-annotated tokens to ShellToken[].
 *
 * Verified scope names (Shiki 4.x TextMate bash grammar):
 *   entity.name.command.shell                             — external commands: cat, sed, …
 *   support.function.builtin.shell                        — builtins: echo, cd, …
 *   constant.other.option / constant.other.option.dash.shell — flags: -n, -ba, --
 *   string.unquoted.argument.shell                        — bare arguments: file.txt, +40, …
 *   constant.numeric.integer.shell                        — numeric args: 50, 30, …
 *   string.quoted.single.shell                            — 'hello world' (anywhere in all scopes)
 *   string.quoted.double.shell                            — "hello world" (anywhere in all scopes)
 *   keyword.operator.pipe.shell                           — | and ||
 *   punctuation.separator.statement.and.shell             — && (anywhere in all scopes)
 *   punctuation.terminator.statement.semicolon.shell      — ; (anywhere in all scopes)
 *   keyword.operator.redirect.shell                       — >, >>
 *   keyword.operator.heredoc.shell                        — <<
 *   punctuation.definition.string.heredoc.delimiter.shell — EOF (unquoted delimiter)
 *   punctuation.definition.string.heredoc.quote.shell     — 'EOF' (quoted delimiter)
 *   constant.character.escape.shell                       — backslash-escape sequences
 */
export function mapShikiTokens(shikiLines: TokenWithScopes[][]): ShellToken[] {
  const out: ShellToken[] = [];
  for (const line of shikiLines) {
    for (const tok of line) {
      const raw = tok.content;
      const all = allScopesOf(tok);

      // Operators that appear as compound tokens (e.g. " && ", "; ")
      if (all.includes("punctuation.separator.statement.and.shell")) {
        out.push({ text: "&&", raw, role: "and" });
        continue;
      }
      if (all.includes("punctuation.terminator.statement.semicolon.shell")) {
        out.push({ text: ";", raw, role: "semicolon" });
        continue;
      }

      if (all.includes("keyword.operator.pipe.shell")) {
        const trimmed = raw.trim();
        out.push({
          text: trimmed,
          raw,
          role: trimmed === "||" ? "or" : "pipe",
        });
        continue;
      }

      if (all.includes("keyword.operator.heredoc.shell")) {
        out.push({ text: "<<", raw, role: "heredoc-op" });
        continue;
      }

      // Quoted heredoc delimiter: 'EOF'
      if (all.includes("punctuation.definition.string.heredoc.quote.shell")) {
        // Strip surrounding single quotes from 'EOF'
        const inner = raw.slice(1, -1);
        out.push({ text: inner, raw, role: "heredoc-delim", quoted: true });
        continue;
      }
      // Unquoted heredoc delimiter: EOF
      if (
        all.includes("punctuation.definition.string.heredoc.delimiter.shell")
      ) {
        out.push({ text: raw, raw, role: "heredoc-delim", quoted: false });
        continue;
      }

      if (all.includes("keyword.operator.redirect.shell")) {
        out.push({ text: raw.trim(), raw, role: "redirect" });
        continue;
      }

      if (
        all.includes("constant.other.option") ||
        all.includes("constant.other.option.dash.shell")
      ) {
        out.push({ text: raw, raw, role: "flag" });
        continue;
      }

      if (
        all.includes("entity.name.command.shell") ||
        all.includes("support.function.builtin.shell")
      ) {
        out.push({ text: raw, raw, role: "command" });
        continue;
      }

      if (all.includes("constant.character.escape.shell")) {
        out.push({ text: raw, raw, role: "escape" });
        continue;
      }

      if (
        all.includes("string.unquoted.argument.shell") ||
        all.includes("constant.numeric.integer.shell")
      ) {
        out.push({ text: raw, raw, role: "argument" });
        continue;
      }

      // Single-quoted strings: strip surrounding quotes
      if (all.includes("string.quoted.single.shell")) {
        out.push({ text: raw.slice(1, -1), raw, role: "string" });
        continue;
      }

      // Double-quoted strings: strip surrounding quotes
      if (all.includes("string.quoted.double.shell")) {
        out.push({ text: raw.slice(1, -1), raw, role: "string" });
        continue;
      }

      // Whitespace or meta-only scopes
      if (!raw.trim()) {
        out.push({ text: raw, raw, role: "whitespace" });
      } else {
        out.push({ text: raw, raw, role: "unknown" });
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Layer 2: AST builder
// ---------------------------------------------------------------------------

interface SimpleCommand {
  name: string | null;
  args: CommandArg[];
  redirects: Redirect[];
}

type CommandArg =
  | { kind: "flag"; text: string }
  | { kind: "value"; text: string };

interface Redirect {
  op: ">" | ">>" | "<" | "<<";
  target: string;
}

interface HeredocInfo {
  delimiter: string;
  quoted: boolean;
  content: string;
  terminator: string;
}

type ShellAST =
  | { type: "simple"; command: SimpleCommand }
  | { type: "pipeline"; stages: SimpleCommand[] }
  | { type: "list"; op: "&&" | ";"; left: ShellAST; right: ShellAST }
  | { type: "heredoc"; command: SimpleCommand; heredoc: HeredocInfo }
  | { type: "unsupported"; reason: string };

function reject(code: RejectCode, reason: string): ShellSemanticResult {
  return { ok: false, code, reason };
}

/**
 * Find the next non-whitespace token at or after position i.
 */
function nextNonWs(tokens: ShellToken[], i: number): number {
  while (i < tokens.length && tokens[i]!.role === "whitespace") i++;
  return i;
}

/**
 * Build a SimpleCommand from a token array.
 * Whitespace tokens act as word separators. Consecutive non-whitespace
 * argument/string/escape tokens (e.g. from backslash escaping: file\ name.txt)
 * are merged into a single value.
 */
export function buildSimpleCommand(tokens: ShellToken[]): SimpleCommand | null {
  const cmd: SimpleCommand = { name: null, args: [], redirects: [] };
  let i = 0;

  while (i < tokens.length) {
    const tok = tokens[i]!;

    if (tok.role === "whitespace") {
      i++;
      continue;
    }

    if (tok.role === "unknown") return null;

    if (tok.role === "command") {
      if (cmd.name === null) {
        cmd.name = tok.text;
      } else {
        return null; // multiple commands without separator
      }
      i++;
      continue;
    }

    if (tok.role === "redirect") {
      i++;
      i = nextNonWs(tokens, i);
      const target = tokens[i];
      if (!target || (target.role !== "argument" && target.role !== "string"))
        return null;
      cmd.redirects.push({
        op: tok.text as Redirect["op"],
        target: target.text,
      });
      i++;
      continue;
    }

    if (tok.role === "heredoc-op") {
      i++;
      i = nextNonWs(tokens, i);
      const delim = tokens[i];
      if (!delim || delim.role !== "heredoc-delim") return null;
      cmd.redirects.push({ op: "<<", target: delim.text });
      i++;
      continue;
    }

    if (tok.role === "flag") {
      cmd.args.push({ kind: "flag", text: tok.text });
      i++;
      continue;
    }

    if (
      tok.role === "argument" ||
      tok.role === "string" ||
      tok.role === "escape"
    ) {
      // Accumulate tokens until we hit whitespace or an operator.
      // This merges adjacent parts like: file\ name.txt → "file name.txt"
      let value = tok.role === "escape" ? tok.text.slice(1) : tok.text;
      i++;
      while (i < tokens.length) {
        const peek = tokens[i]!;
        if (peek.role === "whitespace") break; // word boundary
        if (peek.role === "argument" || peek.role === "string") {
          value += peek.text;
          i++;
        } else if (peek.role === "escape") {
          value += peek.text.slice(1);
          i++;
        } else {
          break;
        }
      }
      cmd.args.push({ kind: "value", text: value });
      continue;
    }

    // Unexpected token (pipe, and, or, heredoc-delim outside heredoc context, etc.)
    return null;
  }

  return cmd;
}

/**
 * Split a token array at a specific operator role.
 */
function splitAt(
  tokens: ShellToken[],
  roles: ShellTokenRole[],
): { segments: ShellToken[][]; operators: ShellToken[] } {
  const segments: ShellToken[][] = [];
  const operators: ShellToken[] = [];
  let current: ShellToken[] = [];
  for (const tok of tokens) {
    if (roles.includes(tok.role)) {
      segments.push(current);
      operators.push(tok);
      current = [];
    } else {
      current.push(tok);
    }
  }
  segments.push(current);
  return { segments, operators };
}

function buildPipelineOrSimple(tokens: ShellToken[]): ShellAST {
  const { segments: pipeSegs } = splitAt(tokens, ["pipe"]);

  if (pipeSegs.length === 1) {
    const cmd = buildSimpleCommand(pipeSegs[0]!);
    if (!cmd) return { type: "unsupported", reason: "invalid command" };
    return { type: "simple", command: cmd };
  }

  const stages: SimpleCommand[] = [];
  for (const seg of pipeSegs) {
    const cmd = buildSimpleCommand(seg);
    if (!cmd) return { type: "unsupported", reason: "invalid pipeline stage" };
    stages.push(cmd);
  }
  return { type: "pipeline", stages };
}

/**
 * Build a ShellAST from a flat ShellToken array.
 * rawCommand is used for heredoc body extraction.
 */
export function buildAST(tokens: ShellToken[], rawCommand: string): ShellAST {
  // Unknown tokens → unsupported
  if (tokens.some((t) => t.role === "unknown")) {
    return { type: "unsupported", reason: "unrecognized token" };
  }

  // Detect heredoc: any token has role heredoc-op
  if (tokens.some((t) => t.role === "heredoc-op")) {
    return buildHeredocAST(tokens, rawCommand);
  }

  // Split at && and ; for command lists
  const { segments: andSegments, operators: andOps } = splitAt(tokens, [
    "and",
    "semicolon",
  ]);

  if (andOps.length > 0) {
    const firstPart = buildPipelineOrSimple(andSegments[0]!);
    if (firstPart.type === "unsupported") return firstPart;

    let result: ShellAST = firstPart;
    for (let i = 0; i < andOps.length; i++) {
      const op = andOps[i]!.role === "and" ? "&&" : (";" as "&&" | ";");
      const rightTokens = andSegments[i + 1]!;
      const right = buildPipelineOrSimple(rightTokens);
      if (right.type === "unsupported") return right;
      result = { type: "list", op, left: result, right };
    }
    return result;
  }

  return buildPipelineOrSimple(tokens);
}

function buildHeredocAST(tokens: ShellToken[], rawCommand: string): ShellAST {
  const lines = rawCommand.replace(/\r\n/g, "\n").split("\n");

  // Find heredoc-op in the original token array (with whitespace intact)
  const heredocOpIdx = tokens.findIndex((t) => t.role === "heredoc-op");
  if (heredocOpIdx < 0)
    return { type: "unsupported", reason: "no heredoc-op found" };

  // Find the delimiter token (first non-whitespace after heredoc-op)
  const delimIdx = nextNonWs(tokens, heredocOpIdx + 1);
  const heredocDelimToken = tokens[delimIdx];
  if (!heredocDelimToken || heredocDelimToken.role !== "heredoc-delim")
    return { type: "unsupported", reason: "invalid heredoc syntax" };

  const delimiter = heredocDelimToken.text;
  const quoted = heredocDelimToken.quoted ?? false;

  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(delimiter))
    return {
      type: "unsupported",
      reason: "delimiter must be a simple literal word",
    };

  const terminatorIndex = lines.findIndex((l, i) => i > 0 && l === delimiter);
  if (terminatorIndex < 0)
    return { type: "unsupported", reason: "terminator line was not found" };
  if (
    terminatorIndex !== lines.length - 1 &&
    !(terminatorIndex === lines.length - 2 && lines.at(-1) === "")
  )
    return { type: "unsupported", reason: "content after heredoc terminator" };

  // Build command from tokens before the heredoc-op (whitespace preserved)
  const preHeredocTokens = tokens.slice(0, heredocOpIdx);
  const syntheticCmd = buildSimpleCommand(preHeredocTokens);
  if (!syntheticCmd)
    return { type: "unsupported", reason: "invalid heredoc command" };

  // Process tokens after the delimiter for any redirect (e.g. <<EOF > file)
  // Note: tokens may include body/terminator tokens from multi-line Shiki output;
  // we stop at any unrecognized token (body gets "unknown" scope from Shiki,
  // so if tokens include multi-line, they'll be caught here).
  // For safety, only process tokens that appear on the same line as the command
  // (i.e., until we see any heredoc body token with "unknown" role, which we stop at).
  const postTokens = tokens.slice(delimIdx + 1);
  for (let i = 0; i < postTokens.length; i++) {
    const t = postTokens[i]!;
    if (t.role === "whitespace") continue;
    if (t.role === "redirect") {
      i = nextNonWs(postTokens, i + 1);
      const next = postTokens[i];
      if (!next || (next.role !== "argument" && next.role !== "string"))
        return { type: "unsupported", reason: "invalid redirect in heredoc" };
      syntheticCmd.redirects.push({
        op: t.text as Redirect["op"],
        target: next.text,
      });
      continue;
    }
    // Stop at heredoc body/terminator tokens (from multi-line Shiki output)
    // These are "unknown" (body) or "heredoc-delim" (terminator) — not relevant
    // to command parsing, which uses raw line content for extraction.
    break;
  }

  return {
    type: "heredoc",
    command: syntheticCmd,
    heredoc: {
      delimiter,
      quoted,
      content: lines.slice(1, terminatorIndex).join("\n"),
      terminator: lines[terminatorIndex]!,
    },
  };
}

// ---------------------------------------------------------------------------
// Layer 3: Classifier
// ---------------------------------------------------------------------------

const READ_COMMANDS = new Set<string>(["cat", "nl", "sed", "head", "tail"]);

const INTERPRETER_LANG: Record<string, string> = {
  python: "python",
  python3: "python",
  node: "javascript",
  nodejs: "javascript",
  ruby: "ruby",
  perl: "perl",
  lua: "lua",
  php: "php",
  Rscript: "r",
  R: "r",
};

// Commands that are always formatting (never a primary read with file operand)
const ALWAYS_FORMATTING = new Set<string>([
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

/**
 * Return true if the command can appear as a non-primary pipeline stage.
 */
function isSmallFormatting(cmd: SimpleCommand): boolean {
  const name = cmd.name;
  if (!name) return false;
  if (ALWAYS_FORMATTING.has(name)) return true;

  const values = cmd.args.filter((a) => a.kind === "value");

  if (name === "head" || name === "tail") {
    return values.length === 0;
  }
  if (name === "sed") {
    const nFlagIdx = cmd.args.findIndex(
      (a) => a.kind === "flag" && a.text === "-n",
    );
    if (nFlagIdx < 0) return true;
    const exprArg = cmd.args[nFlagIdx + 1];
    if (!exprArg || exprArg.kind !== "value") return true;
    const m = exprArg.text.match(/^([1-9]\d*),([1-9]\d*)p$/);
    if (!m) return true;
    const fileArg = cmd.args[nFlagIdx + 2];
    return !fileArg || fileArg.kind !== "value";
  }
  if (name === "nl") {
    return values.length === 0;
  }
  if (name === "awk") {
    const nonFlagValues = cmd.args.filter(
      (a) => a.kind === "value" && !a.text.startsWith("{"),
    );
    return nonFlagValues.length === 0;
  }

  return false;
}

/**
 * Classify a single read-command SimpleCommand into a ShellReadSemantic.
 */
function classifyReadCommand(
  cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
  const name = cmd.name as ReadCommandName;

  if (cmd.redirects.some((r) => r.op !== "<<")) {
    return reject(
      "redirection_on_read",
      "read commands with redirection are not display-only reads",
    );
  }

  let range: ShellReadSemantic["range"] = { type: "all" };
  let presentation: ShellReadSemantic["presentation"] = { lineNumbers: false };
  let filePath: string | null = null;
  let doubleDash = false;

  const args = cmd.args;

  if (name === "sed") {
    const nFlagIdx = args.findIndex(
      (a) => a.kind === "flag" && a.text === "-n",
    );
    if (nFlagIdx < 0)
      return reject(
        "unsupported_option",
        "only sed -n 'N,Mp' path is supported",
      );
    const exprArg = args[nFlagIdx + 1];
    const pathArg = args[nFlagIdx + 2];
    if (
      !exprArg ||
      exprArg.kind !== "value" ||
      !pathArg ||
      pathArg.kind !== "value"
    )
      return reject("missing_path", "sed requires expression and path");
    const m = exprArg.text.match(/^([1-9]\d*),([1-9]\d*)p$/);
    if (!m) return reject("invalid_range", "sed expression must be N,Mp");
    const start = Number(m[1]);
    const end = Number(m[2]);
    if (end < start)
      return reject("invalid_range", "sed end line must be >= start line");
    range = { type: "lines", start, end };
    filePath = pathArg.text;
    if (args.length > nFlagIdx + 3)
      return reject("multiple_paths", "sed supports exactly one file operand");
  } else {
    for (let i = 0; i < args.length; i++) {
      const arg = args[i]!;

      if (arg.kind === "flag" && arg.text === "--") {
        doubleDash = true;
        continue;
      }

      if (arg.kind === "value") {
        if (filePath !== null)
          return reject(
            "multiple_paths",
            "multiple file operands are not supported",
          );
        filePath = arg.text;
        continue;
      }

      // Flag handling by command
      const flag = arg.text;

      if (name === "cat") {
        return reject("unsupported_option", `unsupported cat option ${flag}`);
      }

      if (name === "nl") {
        if (flag === "-ba") {
          const prev =
            presentation.lineNumbers !== false
              ? presentation.lineNumbers
              : { style: "nl" as const };
          presentation = { lineNumbers: { ...prev } };
          continue;
        }
        if (flag === "-w") {
          const next = args[++i];
          const width = next && next.kind === "value" ? Number(next.text) : NaN;
          if (!Number.isInteger(width) || width < 1)
            return reject(
              "unsupported_option",
              "nl -w requires a positive integer",
            );
          const prev =
            presentation.lineNumbers !== false
              ? presentation.lineNumbers
              : { style: "nl" as const };
          presentation = { lineNumbers: { ...prev, width } };
          continue;
        }
        if (flag === "-s") {
          const next = args[++i];
          if (!next || next.kind !== "value")
            return reject("unsupported_option", "nl -s requires a separator");
          const prev =
            presentation.lineNumbers !== false
              ? presentation.lineNumbers
              : { style: "nl" as const };
          presentation = { lineNumbers: { ...prev, separator: next.text } };
          continue;
        }
        return reject("unsupported_option", `unsupported nl option ${flag}`);
      }

      if (name === "head") {
        if (flag === "-n") {
          const next = args[++i];
          const count = next && next.kind === "value" ? Number(next.text) : NaN;
          if (!Number.isInteger(count) || count < 1)
            return reject(
              "unsupported_option",
              "head -n requires a positive integer",
            );
          range = { type: "head", count };
          continue;
        }
        const headN = flag.match(/^-n(\d+)$/);
        if (headN) {
          const count = Number(headN[1]);
          if (!Number.isInteger(count) || count < 1)
            return reject(
              "unsupported_option",
              "head -n requires a positive integer",
            );
          range = { type: "head", count };
          continue;
        }
        return reject("unsupported_option", `unsupported head option ${flag}`);
      }

      // name === "tail" (only remaining case)
      if (flag === "-n") {
        const next = args[++i];
        if (!next || next.kind !== "value")
          return reject("unsupported_option", "tail -n requires an argument");
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
      const tailPlusN = flag.match(/^-n\+([1-9]\d*)$/);
      if (tailPlusN) {
        range = { type: "tail", startLine: Number(tailPlusN[1]) };
        continue;
      }
      const tailN = flag.match(/^-n(\d+)$/);
      if (tailN) {
        range = { type: "tail-count", count: Number(tailN[1]) };
        continue;
      }
      return reject("unsupported_option", `unsupported tail option ${flag}`);
    }
  }

  if (filePath === null)
    return reject("missing_path", "expected one file path");

  void doubleDash;

  const effects: ShellSemanticEffect[] = [];
  if (name === "sed" || name === "cat" || name === "head" || name === "tail") {
    effects.push({
      kind: "read-file",
      order: 0,
      commandName: name,
      filePath,
      range: name === "sed" ? range : undefined,
    });
  }
  const language = langFromPath(filePath) || "text";
  const outputPlan =
    name === "sed"
      ? buildWholeOutputContentPlan(
          "sed-output",
          language,
          { commandIndex: 0, commandName: "sed", filePath },
          "non-empty",
        )
      : undefined;

  return {
    ok: true,
    value: {
      kind: "read",
      command: originalCommand,
      commandName: name,
      filePath,
      range,
      presentation,
      effects: effects.length > 0 ? effects : undefined,
      outputPlan,
    },
  };
}

/**
 * Classify a pipeline as a read or diff, applying the small-formatting-allowlist logic.
 */
function classifyPipeline(
  stages: SimpleCommand[],
  originalCommand: string,
): ShellSemanticResult {
  let primaryIdx = -1;
  let primaryResult: ShellSemanticResult | null = null;

  // Try read primary stage first
  for (let i = 0; i < stages.length; i++) {
    const stage = stages[i]!;
    if (!stage.name || !READ_COMMANDS.has(stage.name)) continue;

    const r = classifyReadCommand(stage, originalCommand);
    if (r.ok) {
      if (primaryIdx >= 0)
        return reject(
          "unsafe_shell_syntax",
          "pipeline has multiple read stages",
        );
      primaryIdx = i;
      primaryResult = r;
    }
  }

  // If no read primary found, try git/diff primary stage
  if (primaryIdx < 0) {
    for (let i = 0; i < stages.length; i++) {
      const stage = stages[i]!;
      if (!stage.name) continue;
      if (stage.name !== "git" && stage.name !== "diff") continue;

      const r =
        stage.name === "git"
          ? classifyGitCommand(stage, originalCommand)
          : classifyDiffCommand(stage, originalCommand);

      if (r.ok && r.value.kind === "diff") {
        if (primaryIdx >= 0)
          return reject(
            "unsafe_shell_syntax",
            "pipeline has multiple diff stages",
          );
        primaryIdx = i;
        primaryResult = r;
      }
    }
  }

  if (primaryIdx < 0 || !primaryResult)
    return reject(
      "unsafe_shell_syntax",
      "pipeline has no recognized file-reading or diff stage",
    );

  for (let i = 0; i < stages.length; i++) {
    if (i === primaryIdx) continue;
    if (!isSmallFormatting(stages[i]!))
      return reject(
        "unsafe_shell_syntax",
        `pipeline stage "${stages[i]!.name}" is not a recognized formatting command`,
      );
  }

  return primaryResult;
}

/**
 * Classify an && list for the cd-path-resolution pattern.
 * Only cd + read sequences are accepted.
 */
function classifyCdList(
  ast: ShellAST,
  originalCommand: string,
): ShellSemanticResult {
  const commands: SimpleCommand[] = [];
  const ops: ("&&" | ";")[] = [];

  function flatten(node: ShellAST): boolean {
    if (node.type === "simple") {
      commands.push(node.command);
      return true;
    }
    if (node.type === "list") {
      ops.push(node.op);
      return flatten(node.left) && flatten(node.right);
    }
    return false;
  }

  if (!flatten(ast))
    return reject("unsafe_shell_syntax", "unsupported list structure");

  if (ops.some((op) => op !== "&&"))
    return reject(
      "unsafe_shell_syntax",
      "only && chains are supported for cd patterns",
    );

  let cdPath = "";
  let readIdx = -1;

  for (let i = 0; i < commands.length; i++) {
    const cmd = commands[i]!;
    if (cmd.name === "cd") {
      const values = cmd.args.filter((a) => a.kind === "value");
      // Use last value (Codex behaviour: cd dir1 dir2 uses dir2)
      const target = values.at(-1)?.text ?? "";
      cdPath = cdPath ? cdPath + "/" + target : target;
    } else if (READ_COMMANDS.has(cmd.name ?? "")) {
      readIdx = i;
      break;
    } else {
      return reject(
        "unsafe_shell_syntax",
        "only cd + read commands are supported in && chains",
      );
    }
  }

  if (readIdx < 0)
    return reject("unsupported_command", "no read command found after cd");

  if (readIdx !== commands.length - 1)
    return reject(
      "unsafe_shell_syntax",
      "trailing commands after read are not supported",
    );

  const r = classifyReadCommand(commands[readIdx]!, originalCommand);
  if (!r.ok) return r;

  const readValue = r.value as ShellReadSemantic;
  const resolved = cdPath
    ? cdPath + "/" + readValue.filePath
    : readValue.filePath;

  return {
    ok: true,
    value: { ...readValue, filePath: resolved },
  };
}

/**
 * Classify a heredoc AST node — dispatches to cat-write or script-exec.
 */
function classifyHeredoc(
  cmd: SimpleCommand,
  heredoc: HeredocInfo,
  originalCommand: string,
): ShellSemanticResult {
  if (cmd.name === "cat")
    return classifyCatHeredoc(cmd, heredoc, originalCommand);
  const lang = cmd.name ? INTERPRETER_LANG[cmd.name] : undefined;
  if (lang) return classifyScriptHeredoc(cmd, heredoc, originalCommand, lang);
  return reject(
    "unsupported_command",
    "only cat heredoc writes and interpreter script heredocs are recognized",
  );
}

/**
 * Classify a `cat <<EOF > file` heredoc write.
 */
function classifyCatHeredoc(
  cmd: SimpleCommand,
  heredoc: HeredocInfo,
  originalCommand: string,
): ShellSemanticResult {
  if (cmd.args.length > 0)
    return reject("invalid_heredoc", "unexpected arguments in heredoc command");

  const redirectOp = cmd.redirects.find((r) => r.op === ">" || r.op === ">>");
  if (!redirectOp)
    return reject(
      "missing_path",
      "heredoc write requires a > redirect for the file path",
    );

  const lines = originalCommand.replace(/\r\n/g, "\n").split("\n");
  const commandLine = lines[0] ?? "";

  return {
    ok: true,
    value: {
      kind: "write",
      command: originalCommand,
      commandName: "cat",
      filePath: redirectOp.target,
      writeMode: "overwrite",
      heredoc: {
        delimiter: heredoc.delimiter,
        quoted: heredoc.quoted,
        commandLine,
        content: heredoc.content,
        terminator: heredoc.terminator,
      },
      segments: [
        { kind: "command-header", text: `${commandLine}\n` },
        {
          kind: "write-content",
          text: heredoc.content,
          filePath: redirectOp.target,
        },
        { kind: "command-footer", text: `\n${heredoc.terminator}` },
      ],
    },
  };
}

/**
 * Classify an interpreter heredoc script: `python3 - <<'PY' ... PY`
 */
function classifyScriptHeredoc(
  cmd: SimpleCommand,
  heredoc: HeredocInfo,
  originalCommand: string,
  language: string,
): ShellSemanticResult {
  // Must not have a > redirect (that would be writing to a file, not executing)
  if (cmd.redirects.some((r) => r.op === ">" || r.op === ">>"))
    return reject(
      "invalid_heredoc",
      "interpreter heredoc must not redirect output to a file",
    );

  const lines = originalCommand.replace(/\r\n/g, "\n").split("\n");
  const commandLine = lines[0] ?? "";

  return {
    ok: true,
    value: {
      kind: "script-exec",
      command: originalCommand,
      commandName: cmd.name!,
      language,
      scriptSource: {
        type: "heredoc",
        delimiter: heredoc.delimiter,
        quoted: heredoc.quoted,
        content: heredoc.content,
        terminator: heredoc.terminator,
        commandLine,
      },
      segments: [
        { kind: "command-header", text: `${commandLine}\n` },
        { kind: "script-content", text: heredoc.content, language },
        { kind: "command-footer", text: `\n${heredoc.terminator}` },
      ],
    },
  };
}

/**
 * Classify an interpreter command with inline -c/-e script.
 * e.g. `python3 -c 'import sys; print(sys.version)'`
 */
function classifyInterpreterCommand(
  cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
  const name = cmd.name!;
  const language = INTERPRETER_LANG[name]!;

  // Look for -c or -e flag
  for (let i = 0; i < cmd.args.length; i++) {
    const arg = cmd.args[i]!;
    if (arg.kind === "flag" && (arg.text === "-c" || arg.text === "-e")) {
      const next = cmd.args[i + 1];
      if (!next || next.kind !== "value")
        return reject(
          "unsupported_option",
          `${arg.text} requires a script argument`,
        );
      return {
        ok: true,
        value: {
          kind: "script-exec",
          command: originalCommand,
          commandName: name,
          language,
          scriptSource: {
            type: "inline",
            flag: arg.text,
            content: next.text,
          },
          segments: [
            { kind: "command-header", text: originalCommand },
            { kind: "script-content", text: next.text, language },
          ],
        },
      };
    }
  }

  // No -c/-e flag: running a file (e.g. python script.py) — not embedded code
  return reject(
    "unsupported_command",
    `${name} without -c/-e flag is running a file, not an embedded script`,
  );
}

/**
 * Classify a `git` command: diff, show, log -p, or show HEAD:file (→ read).
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

/**
 * Classify a `diff` binary invocation (not git diff).
 */
function classifyDiffCommand(
  _cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
  return {
    ok: true,
    value: { kind: "diff", commandName: "diff", command: originalCommand },
  };
}

function isDynamicShellValue(value: string): boolean {
  return (
    value.includes("$") ||
    value.includes("`") ||
    value.includes("$(") ||
    value.includes("${")
  );
}

function buildWholeOutputContentPlan(
  blockId: string,
  language: string,
  source?: OutputBlockPlan["source"],
  validator?: SpanValidatorId,
): OutputPlan {
  return {
    version: 1,
    blocks: [
      {
        id: blockId,
        source,
        format: { kind: "content", language },
        location: { kind: "whole-output", validator },
      },
    ],
  };
}

function classifyRgCommand(
  cmd: SimpleCommand,
  originalCommand: string,
): ShellSemanticResult {
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
  if (values.length !== 2) {
    return reject(
      values.length < 2 ? "missing_path" : "multiple_paths",
      `${toolName} -n requires exactly one pattern and one file operand`,
    );
  }
  const [pattern, filePath] = values;
  if (
    !pattern ||
    !filePath ||
    isDynamicShellValue(pattern) ||
    isDynamicShellValue(filePath)
  ) {
    return reject("variable_path", `${toolName} pattern/path must be literal`);
  }
  if (filePath === "." || filePath === ".." || filePath.endsWith("/")) {
    return reject(
      "unsupported_command",
      `${toolName} target must be a file path`,
    );
  }
  const language = langFromPath(filePath) || "text";
  return {
    ok: true,
    value: {
      kind: "search",
      commandName: "rg",
      command: originalCommand,
      pattern,
      filePath,
      effects: [
        {
          kind: "search",
          order: 0,
          commandName: "rg",
          pattern,
          filePath,
        },
      ],
      outputPlan: {
        version: 1,
        blocks: [
          {
            id: "rg-results",
            source: { commandIndex: 0, commandName: "rg", filePath },
            format: {
              kind: "individual-lines",
              format: {
                kind: "line-number-prefixed",
                format: { kind: "content", language },
              },
            },
            location: {
              kind: "whole-output",
              validator: "rg-line-number-prefixed",
            },
          },
        ],
      },
    },
  };
}

export function classifyAST(
  ast: ShellAST,
  originalCommand: string,
): ShellSemanticResult {
  if (ast.type === "unsupported")
    return reject("unsafe_shell_syntax", ast.reason);

  if (ast.type === "heredoc")
    return classifyHeredoc(ast.command, ast.heredoc, originalCommand);

  if (ast.type === "simple") {
    const name = ast.command.name;
    if (!name) return reject("empty", "empty command");
    if (name === "rg" || name === "grep")
      return classifyRgCommand(ast.command, originalCommand);
    if (name === "git") return classifyGitCommand(ast.command, originalCommand);
    if (name === "diff")
      return classifyDiffCommand(ast.command, originalCommand);
    if (INTERPRETER_LANG[name])
      return classifyInterpreterCommand(ast.command, originalCommand);
    if (!READ_COMMANDS.has(name))
      return reject(
        "unsupported_command",
        "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
      );
    return classifyReadCommand(ast.command, originalCommand);
  }

  if (ast.type === "pipeline")
    return classifyPipeline(ast.stages, originalCommand);

  // ast.type === "list"
  return classifyCdList(ast, originalCommand);
}

// ---------------------------------------------------------------------------
// Shell wrapper + Batch 1 structured parsing helpers
// ---------------------------------------------------------------------------

interface WrapperParse {
  decodedPayload: string;
  rawPayload: string;
  escaping: ShellEscapingScheme;
  prefix: ShellSourceSpan;
  payload: ShellSourceSpan;
  suffix: ShellSourceSpan;
}

function sourceSpan(
  source: string,
  start: number,
  end: number,
): ShellSourceSpan {
  return { start, end, rawText: source.slice(start, end) };
}

type SourceEmbedSegment = Extract<SourceSegment, { kind: "embed" }>;

interface LocatedEmbed {
  id: string;
  segment: SourceEmbedSegment;
  absoluteStart: number;
  absoluteEnd: number;
}

function findWrapperEmbed(root: SourceNode): LocatedEmbed | null {
  const idx = root.segments.findIndex(
    (segment) =>
      segment.kind === "embed" &&
      (segment.escaping.kind === "shell-single-quote" ||
        segment.escaping.kind === "shell-double-quote"),
  );
  if (idx < 0) return null;
  const segment = root.segments[idx] as SourceEmbedSegment;
  return {
    id: `embed-${idx}`,
    segment,
    absoluteStart: segment.span.start,
    absoluteEnd: segment.span.end,
  };
}

function findFirstHeredocEmbed(
  root: SourceNode,
  baseOffset = 0,
  path: number[] = [],
): LocatedEmbed | null {
  for (let i = 0; i < root.segments.length; i++) {
    const segment = root.segments[i]!;
    if (segment.kind !== "embed") continue;
    const absoluteStart = baseOffset + segment.span.start;
    const absoluteEnd = baseOffset + segment.span.end;
    const nextPath = path.concat(i);
    if (segment.escaping.kind === "shell-heredoc") {
      return {
        id: `embed-${nextPath.join(".")}`,
        segment,
        absoluteStart,
        absoluteEnd,
      };
    }
    const nested = findFirstHeredocEmbed(
      segment.content,
      absoluteStart,
      nextPath,
    );
    if (nested) return nested;
  }
  return null;
}

function mapDecodedOffsetToRawOffset(
  rawPayload: string,
  decodedOffset: number,
  escaping: Extract<
    ShellEscapingScheme,
    { kind: "shell-single-quote" } | { kind: "shell-double-quote" }
  >,
): number | null {
  if (decodedOffset < 0) return null;
  let raw = 0;
  let decoded = 0;
  while (decoded < decodedOffset && raw < rawPayload.length) {
    if (
      escaping.kind === "shell-single-quote" &&
      rawPayload.slice(raw, raw + 4) === "'\\''"
    ) {
      raw += 4;
      decoded += 1;
      continue;
    }
    if (
      escaping.kind === "shell-double-quote" &&
      rawPayload[raw] === "\\" &&
      raw + 1 < rawPayload.length
    ) {
      raw += 2;
      decoded += 1;
      continue;
    }
    raw += 1;
    decoded += 1;
  }
  if (decoded !== decodedOffset) return null;
  return raw;
}

function resolveHeredocEmbedForProjection(
  root: SourceNode,
): LocatedEmbed | null {
  const wrapperEmbed = findWrapperEmbed(root);
  if (
    wrapperEmbed &&
    (wrapperEmbed.segment.escaping.kind === "shell-single-quote" ||
      wrapperEmbed.segment.escaping.kind === "shell-double-quote")
  ) {
    const childHeredoc = findFirstHeredocEmbed(wrapperEmbed.segment.content);
    if (childHeredoc) {
      const rawPayload = root.text.slice(
        wrapperEmbed.absoluteStart,
        wrapperEmbed.absoluteEnd,
      );
      const rawStart = mapDecodedOffsetToRawOffset(
        rawPayload,
        childHeredoc.segment.span.start,
        wrapperEmbed.segment.escaping,
      );
      const rawEnd = mapDecodedOffsetToRawOffset(
        rawPayload,
        childHeredoc.segment.span.end,
        wrapperEmbed.segment.escaping,
      );
      if (rawStart != null && rawEnd != null) {
        return {
          ...childHeredoc,
          absoluteStart: wrapperEmbed.absoluteStart + rawStart,
          absoluteEnd: wrapperEmbed.absoluteStart + rawEnd,
        };
      }
    }
  }
  return findFirstHeredocEmbed(root);
}

function wrapperParseFromSourceTree(root: SourceNode): WrapperParse | null {
  const wrapperEmbed = findWrapperEmbed(root);
  if (!wrapperEmbed) return null;
  if (root.language !== "bash") return null;
  if (wrapperEmbed.segment.content.language !== "bash") return null;
  if (
    wrapperEmbed.segment.escaping.kind !== "shell-single-quote" &&
    wrapperEmbed.segment.escaping.kind !== "shell-double-quote"
  ) {
    return null;
  }
  return {
    decodedPayload: wrapperEmbed.segment.content.text,
    rawPayload: root.text.slice(
      wrapperEmbed.absoluteStart,
      wrapperEmbed.absoluteEnd,
    ),
    escaping: wrapperEmbed.segment.escaping,
    prefix: sourceSpan(root.text, 0, wrapperEmbed.absoluteStart),
    payload: sourceSpan(
      root.text,
      wrapperEmbed.absoluteStart,
      wrapperEmbed.absoluteEnd,
    ),
    suffix: sourceSpan(root.text, wrapperEmbed.absoluteEnd, root.text.length),
  };
}

function makeEmbeddedContent(
  root: SourceNode,
  embed: LocatedEmbed,
  id = embed.id,
): ShellEmbeddedContent {
  const source = sourceSpan(root.text, embed.absoluteStart, embed.absoluteEnd);
  return {
    id,
    language: embed.segment.content.language,
    source,
    decodedText: embed.segment.content.text,
    segments: [
      {
        kind: "text",
        text: embed.segment.content.text,
        source,
      },
    ],
  };
}

function heredocRoleFromSemantic(
  semantic?: ShellSemantic,
): "write-content" | "script-content" | "heredoc-body" {
  if (semantic?.kind === "write") return "write-content";
  if (
    semantic?.kind === "script-exec" &&
    semantic.scriptSource.type === "heredoc"
  ) {
    return "script-content";
  }
  return "heredoc-body";
}

function splitTerminatorAndTrailing(shellSuffix: string): {
  terminator: string;
  trailing: string;
} {
  if (!shellSuffix) return { terminator: "", trailing: "" };
  if (!shellSuffix.startsWith("\n")) {
    return { terminator: shellSuffix, trailing: "" };
  }
  const secondNewline = shellSuffix.indexOf("\n", 1);
  if (secondNewline < 0) return { terminator: shellSuffix, trailing: "" };
  return {
    terminator: shellSuffix.slice(0, secondNewline),
    trailing: shellSuffix.slice(secondNewline),
  };
}

export function sourceTreeToShellInputSegments(
  root: SourceNode,
  semantic?: ShellSemantic,
): ShellInputSegment[] {
  const wrapper = wrapperParseFromSourceTree(root);
  const heredoc = resolveHeredocEmbedForProjection(root);
  const role = heredocRoleFromSemantic(semantic);
  const hasSemanticHeredocRole =
    semantic?.kind === "write" ||
    (semantic?.kind === "script-exec" &&
      semantic.scriptSource.type === "heredoc");

  if (heredoc && hasSemanticHeredocRole) {
    const segments: ShellInputSegment[] = [];
    const shellStart = wrapper ? wrapper.payload.start : 0;
    const shellEnd = wrapper ? wrapper.payload.end : root.text.length;
    if (wrapper) {
      segments.push({
        kind: "wrapper-prefix",
        text: wrapper.prefix.rawText,
        source: wrapper.prefix,
        language: "bash",
      });
    }
    if (heredoc.absoluteStart > shellStart) {
      segments.push({
        kind: "command-header",
        text: root.text.slice(shellStart, heredoc.absoluteStart),
        source: sourceSpan(root.text, shellStart, heredoc.absoluteStart),
        language: "bash",
      });
    }
    segments.push({
      kind: "embedded-content",
      role,
      text: root.text.slice(heredoc.absoluteStart, heredoc.absoluteEnd),
      source: sourceSpan(root.text, heredoc.absoluteStart, heredoc.absoluteEnd),
      language: heredoc.segment.content.language,
      filePath: semantic.kind === "write" ? semantic.filePath : undefined,
      contentNodeId: "heredoc-body",
    });
    const suffix = root.text.slice(heredoc.absoluteEnd, shellEnd);
    const { terminator, trailing } = splitTerminatorAndTrailing(suffix);
    if (terminator.length > 0) {
      segments.push({
        kind: "heredoc-terminator",
        text: terminator,
        source: sourceSpan(
          root.text,
          heredoc.absoluteEnd,
          heredoc.absoluteEnd + terminator.length,
        ),
        language: "bash",
      });
    }
    if (trailing.length > 0) {
      const trailingStart = heredoc.absoluteEnd + terminator.length;
      segments.push({
        kind: "command-trailing",
        text: trailing,
        source: sourceSpan(
          root.text,
          trailingStart,
          trailingStart + trailing.length,
        ),
        language: "bash",
      });
    }
    if (wrapper) {
      segments.push({
        kind: "wrapper-suffix",
        text: wrapper.suffix.rawText,
        source: wrapper.suffix,
        language: "bash",
      });
    }
    return segments;
  }

  if (wrapper) {
    return [
      {
        kind: "wrapper-prefix",
        text: wrapper.prefix.rawText,
        source: wrapper.prefix,
        language: "bash",
      },
      {
        kind: "shell-text",
        text: wrapper.payload.rawText,
        source: wrapper.payload,
        language: "bash",
      },
      {
        kind: "wrapper-suffix",
        text: wrapper.suffix.rawText,
        source: wrapper.suffix,
        language: "bash",
      },
    ];
  }

  return [
    {
      kind: "shell-text",
      text: root.text,
      source: sourceSpan(root.text, 0, root.text.length),
      language: "bash",
    },
  ];
}

export function sourceTreeToShellEmbeddedContent(
  root: SourceNode,
  semantic?: ShellSemantic,
): ShellEmbeddedContent[] {
  const wrapperEmbed = findWrapperEmbed(root);
  const heredocEmbed = resolveHeredocEmbedForProjection(root);
  const hasSemanticHeredocRole =
    semantic?.kind === "write" ||
    (semantic?.kind === "script-exec" &&
      semantic.scriptSource.type === "heredoc");

  if (heredocEmbed && hasSemanticHeredocRole) {
    return [makeEmbeddedContent(root, heredocEmbed, "heredoc-body")];
  }
  if (wrapperEmbed) {
    return [makeEmbeddedContent(root, wrapperEmbed, "wrapper-payload")];
  }
  if (heredocEmbed) {
    return [makeEmbeddedContent(root, heredocEmbed)];
  }
  return [];
}

function withSourceTreeCompatibility(
  value: ShellSemantic,
  command: string,
  sourceTree: SourceNode,
): ShellSemantic {
  const baseSource = sourceSpan(command, 0, command.length);
  return {
    ...value,
    source: value.source ?? baseSource,
    sourceTree,
    inputSegments:
      value.inputSegments ?? sourceTreeToShellInputSegments(sourceTree, value),
    embeddedContent:
      value.embeddedContent ??
      sourceTreeToShellEmbeddedContent(sourceTree, value),
  };
}

function parseSedReadSpec(
  command: string,
): { start: number; end: number; filePath: string } | null {
  const m = command.match(
    /^\s*sed\s+-n\s+'([1-9]\d*),([1-9]\d*)p'\s+(\S+)\s*$/,
  );
  if (!m) return null;
  const start = Number(m[1]);
  const end = Number(m[2]);
  const filePath = m[3]!;
  if (end < start || isDynamicShellValue(filePath)) return null;
  return { start, end, filePath };
}

function parsePrintfLiteralSpec(
  command: string,
): { raw: string; decoded: string } | null {
  const m = command.match(/^\s*printf\s+'([^']*)'\s*$/);
  if (!m) return null;
  const raw = m[1]!;
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
  return { raw, decoded };
}

function parseLsReadbackSpec(
  command: string,
): { filePath: string; sedStart: number; sedEnd: number } | null {
  const m = command.match(
    /^\s*ls\s+-l\s+(\S+)\s*&&\s*sed\s+-n\s+'([1-9]\d*),([1-9]\d*)p'\s+(\S+)\s*$/,
  );
  if (!m) return null;
  const filePath = m[1]!;
  const sedPath = m[4]!;
  if (filePath !== sedPath) return null;
  if (isDynamicShellValue(filePath)) return null;
  const sedStart = Number(m[2]);
  const sedEnd = Number(m[3]);
  if (sedEnd < sedStart) return null;
  return { filePath, sedStart, sedEnd };
}

function parseLsDirectoryListing(command: string): { dirPath: string } | null {
  const m = command.match(/^\s*ls\s+-1\s+(\S+)\s*$/);
  if (!m) return null;
  return { dirPath: m[1]! };
}

function classifyTrailingStructuredOutput(
  trailing: string,
): { effects?: ShellSemanticEffect[]; outputPlan?: OutputPlan } | null {
  const readback = parseLsReadbackSpec(trailing);
  if (readback) {
    const language = langFromPath(readback.filePath) || "text";
    return {
      effects: [
        { kind: "plain-output", order: 0, commandName: "ls" },
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
        },
      ],
      outputPlan: {
        version: 1,
        blocks: [
          {
            id: "listing",
            source: {
              commandIndex: 0,
              commandName: "ls",
              filePath: readback.filePath,
            },
            format: { kind: "content", language: "shell-output" },
            location: {
              kind: "from-cursor",
              end: { kind: "line-count", count: 1 },
              validator: "non-empty",
            },
          },
          {
            id: "sed-output",
            source: {
              commandIndex: 1,
              commandName: "sed",
              filePath: readback.filePath,
            },
            format: { kind: "content", language },
            location: {
              kind: "from-cursor",
              end: { kind: "end-of-output", requiresComplete: true },
              validator: "non-empty",
            },
          },
        ],
      },
    };
  }

  const lsDir = parseLsDirectoryListing(trailing);
  if (lsDir) {
    return {
      effects: [{ kind: "plain-output", order: 0, commandName: "ls" }],
    };
  }
  return null;
}

function findHeredocOperatorIndex(line: string): number {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i + 1 < line.length; i++) {
    const ch = line[i]!;
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === "\\" && i + 1 < line.length) {
        i++;
        continue;
      }
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === "#") {
      const prev = line[i - 1] ?? "";
      if (prev !== "\\" && (i === 0 || /[\s;&|()<>]/.test(prev))) {
        break;
      }
    }
    if (
      ch === "<" &&
      line[i + 1] === "<" &&
      line[i + 2] !== "<" &&
      line[i - 1] !== "<"
    ) {
      return i;
    }
  }
  return -1;
}

function classifyHeredocDocument(
  innerCommand: string,
  originalCommand: string,
): ShellSemanticResult | null {
  const normalized = innerCommand.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  let heredocLineIndex = -1;
  let opIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    const idx = findHeredocOperatorIndex(lines[i] ?? "");
    if (idx >= 0) {
      heredocLineIndex = i;
      opIndex = idx;
      break;
    }
  }
  if (heredocLineIndex < 0 || opIndex < 0) return null;
  const leading = lines.slice(0, heredocLineIndex);
  if (
    leading.some(
      (line) => line.trim().length > 0 && !/^mkdir\s+-p\s+\S+\s*$/.test(line),
    )
  ) {
    return reject(
      "invalid_heredoc",
      "only leading mkdir -p setup is supported before heredoc",
    );
  }

  const commandLine = lines[heredocLineIndex] ?? "";
  if (commandLine.startsWith("<<-", opIndex)) {
    return reject("invalid_heredoc", "<<- heredoc is not supported");
  }
  let cursor = opIndex + 2;
  while (cursor < commandLine.length && /\s/.test(commandLine[cursor]!))
    cursor++;
  let quoted = false;
  let delimiter = "";
  let delimiterEnd: number;
  if (commandLine[cursor] === "'") {
    quoted = true;
    cursor++;
    const close = commandLine.indexOf("'", cursor);
    if (close < 0)
      return reject(
        "unterminated_quote",
        "unterminated quoted heredoc delimiter",
      );
    delimiter = commandLine.slice(cursor, close);
    delimiterEnd = close + 1;
  } else {
    const m = commandLine.slice(cursor).match(/^([A-Za-z_][A-Za-z0-9_]*)/);
    if (!m) return reject("invalid_heredoc", "invalid heredoc delimiter");
    delimiter = m[1]!;
    delimiterEnd = cursor + delimiter.length;
  }
  if (!delimiter) return reject("invalid_heredoc", "empty heredoc delimiter");
  if (findHeredocOperatorIndex(commandLine.slice(delimiterEnd)) >= 0) {
    return reject(
      "invalid_heredoc",
      "multiple heredocs are not supported in this batch",
    );
  }
  const terminatorIndex = lines.findIndex(
    (line, idx) => idx > heredocLineIndex && line === delimiter,
  );
  if (terminatorIndex < 0) {
    return reject("invalid_heredoc", "heredoc terminator line was not found");
  }
  const hasTrailingHeredoc = lines
    .slice(terminatorIndex + 1)
    .some((line) => findHeredocOperatorIndex(line) >= 0);
  if (hasTrailingHeredoc) {
    return reject(
      "invalid_heredoc",
      "multiple heredocs are not supported in this batch",
    );
  }

  const body = lines.slice(heredocLineIndex + 1, terminatorIndex).join("\n");
  const trailing = lines
    .slice(terminatorIndex + 1)
    .join("\n")
    .trim();
  const commandName = commandLine.trim().split(/\s+/)[0];
  if (!commandName)
    return reject("unsupported_command", "missing heredoc command name");

  if (commandName === "cat") {
    const redirect = commandLine.match(/(?:^|\s)>\s*(\S+)/);
    if (!redirect) {
      return reject("missing_path", "cat heredoc write requires > path");
    }
    const filePath = redirect[1]!;
    if (isDynamicShellValue(filePath)) {
      return reject("variable_path", "heredoc target path must be literal");
    }
    const writeValue: ShellSemantic = {
      kind: "write",
      command: originalCommand,
      commandName: "cat",
      filePath,
      writeMode: "overwrite",
      heredoc: {
        delimiter,
        quoted,
        commandLine,
        content: body,
        terminator: delimiter,
      },
      segments: [
        { kind: "command-header", text: `${commandLine}\n` },
        { kind: "write-content", text: body, filePath },
        { kind: "command-footer", text: `\n${delimiter}` },
      ],
      effects: [
        {
          kind: "write-file",
          order: 0,
          targetPath: filePath,
          contentNodeId: "heredoc-body",
        },
      ],
    };
    const trailingStructured = trailing
      ? classifyTrailingStructuredOutput(trailing)
      : null;
    if (trailing && !trailingStructured) {
      return { ok: true, value: writeValue };
    }
    return {
      ok: true,
      value: {
        ...writeValue,
        effects: [
          ...(writeValue.effects ?? []),
          ...(trailingStructured?.effects ?? []).map((e, idx) => ({
            ...e,
            order: idx + 1,
          })),
        ],
        outputPlan: trailingStructured?.outputPlan,
      },
    };
  }

  const language = INTERPRETER_LANG[commandName];
  if (!language) {
    return reject("unsupported_command", "unsupported heredoc command");
  }
  const scriptValue: ShellSemantic = {
    kind: "script-exec",
    command: originalCommand,
    commandName,
    language,
    scriptSource: {
      type: "heredoc",
      delimiter,
      quoted,
      content: body,
      terminator: delimiter,
      commandLine,
    },
    segments: [
      { kind: "command-header", text: `${commandLine}\n` },
      { kind: "script-content", text: body, language },
      { kind: "command-footer", text: `\n${delimiter}` },
    ],
    effects: [
      {
        kind: "execute-script",
        order: 0,
        commandName,
        language,
        contentNodeId: "heredoc-body",
      },
    ],
  };
  return {
    ok: true,
    value: scriptValue,
  };
}

function classifyStructuredCommandList(
  innerCommand: string,
  originalCommand: string,
): ShellSemanticResult | null {
  const normalized = innerCommand.replace(/\r\n/g, "\n");
  const readback = parseLsReadbackSpec(normalized);
  if (readback) {
    const language = langFromPath(readback.filePath) || "text";
    return {
      ok: true,
      value: {
        kind: "structured-output",
        commandName: "ls",
        command: originalCommand,
        effects: [
          { kind: "plain-output", order: 0, commandName: "ls" },
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
          },
        ],
        outputPlan: {
          version: 1,
          blocks: [
            {
              id: "listing",
              source: {
                commandIndex: 0,
                commandName: "ls",
                filePath: readback.filePath,
              },
              format: { kind: "content", language: "shell-output" },
              location: {
                kind: "from-cursor",
                end: { kind: "line-count", count: 1 },
                validator: "non-empty",
              },
            },
            {
              id: "sed-output",
              source: {
                commandIndex: 1,
                commandName: "sed",
                filePath: readback.filePath,
              },
              format: { kind: "content", language },
              location: {
                kind: "from-cursor",
                end: { kind: "end-of-output", requiresComplete: true },
                validator: "non-empty",
              },
            },
          ],
        },
      },
    };
  }

  const lines = normalized
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  if (lines.length < 2) return null;

  const blocks: OutputBlockPlan[] = [];
  const effects: ShellSemanticEffect[] = [];
  const separatorTexts: string[] = [];
  let hasUnsupported = false;
  let hasSed = false;
  const sedFileSet = new Set<string>();
  let hasAdjacentSedWithoutSeparator = false;
  const entries: Array<
    | {
        kind: "sed";
        lineIndex: number;
        blockId: string;
        filePath: string;
        language: string;
      }
    | {
        kind: "printf";
        lineIndex: number;
        blockId: string;
        decoded: string;
      }
  > = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const sed = parseSedReadSpec(line);
    if (sed) {
      hasSed = true;
      sedFileSet.add(sed.filePath);
      effects.push({
        kind: "read-file",
        order: effects.length,
        commandName: "sed",
        filePath: sed.filePath,
        range: { type: "lines", start: sed.start, end: sed.end },
      });
      if (entries[entries.length - 1]?.kind === "sed") {
        hasAdjacentSedWithoutSeparator = true;
      }
      entries.push({
        lineIndex: i,
        kind: "sed",
        blockId: `sed-${i}`,
        filePath: sed.filePath,
        language: langFromPath(sed.filePath) || "text",
      });
      continue;
    }
    const printf = parsePrintfLiteralSpec(line);
    if (printf) {
      effects.push({
        kind: "plain-output",
        order: effects.length,
        commandName: "printf",
      });
      separatorTexts.push(printf.decoded);
      entries.push({
        lineIndex: i,
        kind: "printf",
        blockId: `printf-${i}`,
        decoded: printf.decoded,
      });
      continue;
    }
    hasUnsupported = true;
    break;
  }
  if (hasUnsupported || !hasSed) return null;

  const duplicateSeparator =
    new Set(separatorTexts).size !== separatorTexts.length;
  const allowPlan =
    !duplicateSeparator &&
    !hasAdjacentSedWithoutSeparator &&
    (sedFileSet.size <= 1 || separatorTexts.length > 0);
  if (allowPlan) {
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i]!;
      if (entry.kind === "printf") {
        blocks.push({
          id: entry.blockId,
          source: { commandIndex: entry.lineIndex, commandName: "printf" },
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "unique-literal",
            text: entry.decoded,
            include: "self",
          },
        });
        continue;
      }
      const nextPrintf = entries
        .slice(i + 1)
        .find((item) => item.kind === "printf");
      blocks.push({
        id: entry.blockId,
        source: {
          commandIndex: entry.lineIndex,
          commandName: "sed",
          filePath: entry.filePath,
        },
        format: { kind: "content", language: entry.language },
        location: nextPrintf
          ? {
              kind: "from-cursor",
              end: { kind: "before-block", blockId: nextPrintf.blockId },
              validator: "non-empty",
            }
          : {
              kind: "from-cursor",
              end: { kind: "end-of-output", requiresComplete: true },
              validator: "non-empty",
            },
      });
    }
  }
  return {
    ok: true,
    value: {
      kind: "structured-output",
      commandName: "shell",
      command: originalCommand,
      effects,
      outputPlan: allowPlan ? { version: 1, blocks } : undefined,
    },
  };
}

// ---------------------------------------------------------------------------
// Public async API
// ---------------------------------------------------------------------------

export async function parseShellSemantic(
  command: string,
  theme: ShikiTheme = "github-dark",
): Promise<ShellSemanticResult> {
  if (!command.trim()) return reject("empty", "empty command");

  const sourceTreeResult = parseCommandSourceTree(command);
  if (!sourceTreeResult.ok) {
    return reject(sourceTreeResult.code, sourceTreeResult.reason);
  }
  const sourceTree = sourceTreeResult.value;
  const wrapperEmbed = findWrapperEmbed(sourceTree);
  const wrapper = wrapperParseFromSourceTree(sourceTree);
  const innerNode = wrapperEmbed ? wrapperEmbed.segment.content : sourceTree;
  const inner = wrapper ? wrapper.decodedPayload : sourceTree.text;

  if (findFirstHeredocEmbed(innerNode)) {
    const heredocResult = classifyHeredocDocument(inner, command);
    if (heredocResult) {
      return heredocResult.ok
        ? {
            ok: true,
            value: withSourceTreeCompatibility(
              heredocResult.value,
              command,
              sourceTree,
            ),
          }
        : heredocResult;
    }
  }

  const structuredList = classifyStructuredCommandList(inner, command);
  if (structuredList) {
    return structuredList.ok
      ? {
          ok: true,
          value: withSourceTreeCompatibility(
            structuredList.value,
            command,
            sourceTree,
          ),
        }
      : structuredList;
  }
  if (inner.includes("\n")) {
    return reject(
      "unsupported_command",
      "unsupported multiline shell command list",
    );
  }

  // For heredoc commands, only tokenize the first line (the command line).
  // Shiki tokenizes heredoc bodies with special heredoc scopes which we don't
  // need — body content is extracted via line splitting from the raw command.
  const tokenizeLine = inner.includes("\n") ? inner.split("\n")[0]! : inner;

  const shikiLines = await tokenizeWithScopes(tokenizeLine, theme);
  if (!shikiLines)
    return reject("unsafe_shell_syntax", "tokenizer unavailable");

  const shellTokens = mapShikiTokens(shikiLines);
  const ast = buildAST(shellTokens, inner);
  const classified = classifyAST(ast, command);
  if (!classified.ok) return classified;
  return {
    ok: true,
    value: withSourceTreeCompatibility(classified.value, command, sourceTree),
  };
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export function useShellSemantic(
  command: string | null,
): ShellSemanticResult | null {
  const appTheme = useCurrentTheme();
  const shikiTheme: ShikiTheme =
    appTheme === "light" ? "github-light" : "github-dark";
  const [result, setResult] = useState<ShellSemanticResult | null>(null);

  useEffect(() => {
    if (!command) {
      setResult(null);
      return;
    }
    let cancelled = false;
    void parseShellSemantic(command, shikiTheme).then((r) => {
      if (!cancelled) setResult(r);
    });
    return () => {
      cancelled = true;
    };
  }, [command, shikiTheme]);

  return result;
}
