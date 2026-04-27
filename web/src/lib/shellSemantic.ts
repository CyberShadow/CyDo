import { useState, useEffect } from "preact/hooks";
import { tokenizeWithScopes, type TokenWithScopes } from "../highlight";
import type { ShikiTheme } from "../highlight";
import { useCurrentTheme } from "../useTheme";

// ---------------------------------------------------------------------------
// Public types (API contract — do not change)
// ---------------------------------------------------------------------------

type ReadCommandName = "cat" | "nl" | "sed" | "head" | "tail";

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

export type ShellSemantic = ShellReadSemantic | ShellHeredocWriteSemantic;

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

  return {
    ok: true,
    value: {
      kind: "read",
      command: originalCommand,
      commandName: name,
      filePath,
      range,
      presentation,
    },
  };
}

/**
 * Classify a pipeline as a read, applying the small-formatting-allowlist logic.
 */
function classifyPipeline(
  stages: SimpleCommand[],
  originalCommand: string,
): ShellSemanticResult {
  let primaryIdx = -1;
  let primaryResult: ShellSemanticResult | null = null;

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

  if (primaryIdx < 0 || !primaryResult)
    return reject(
      "unsafe_shell_syntax",
      "pipeline has no recognized file-reading stage",
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

  const resolved = cdPath ? cdPath + "/" + r.value.filePath : r.value.filePath;

  return {
    ok: true,
    value: { ...(r.value as ShellReadSemantic), filePath: resolved },
  };
}

/**
 * Classify a heredoc AST node into a ShellHeredocWriteSemantic.
 */
function classifyHeredoc(
  cmd: SimpleCommand,
  heredoc: HeredocInfo,
  originalCommand: string,
): ShellSemanticResult {
  if (cmd.name !== "cat")
    return reject(
      "unsupported_command",
      "only cat heredoc writes are recognized",
    );

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
    if (!READ_COMMANDS.has(name))
      return reject(
        "unsupported_command",
        "only cat, nl, sed, head, and tail are recognized",
      );
    return classifyReadCommand(ast.command, originalCommand);
  }

  if (ast.type === "pipeline")
    return classifyPipeline(ast.stages, originalCommand);

  // ast.type === "list"
  return classifyCdList(ast, originalCommand);
}

// ---------------------------------------------------------------------------
// Shell wrapper stripping
// ---------------------------------------------------------------------------

function stripShellWrapper(command: string): string {
  const m = command.match(/^(?:.*\/)?(?:sh|bash|zsh)\s+-l?c\s+'([\s\S]*)'\s*$/);
  return m ? m[1]! : command;
}

// ---------------------------------------------------------------------------
// Public async API
// ---------------------------------------------------------------------------

export async function parseShellSemantic(
  command: string,
  theme: ShikiTheme = "github-dark",
): Promise<ShellSemanticResult> {
  if (!command.trim()) return reject("empty", "empty command");

  const inner = stripShellWrapper(command);

  // For heredoc commands, only tokenize the first line (the command line).
  // Shiki tokenizes heredoc bodies with special heredoc scopes which we don't
  // need — body content is extracted via line splitting from the raw command.
  const tokenizeLine =
    inner.includes("\n") || inner.includes("<<")
      ? inner.split("\n")[0]!
      : inner;

  const shikiLines = await tokenizeWithScopes(tokenizeLine, theme);
  if (!shikiLines)
    return reject("unsafe_shell_syntax", "tokenizer unavailable");

  const shellTokens = mapShikiTokens(shikiLines);
  const ast = buildAST(shellTokens, inner);
  return classifyAST(ast, command);
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
