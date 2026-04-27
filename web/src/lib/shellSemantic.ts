type ReadCommandName = "cat" | "nl" | "sed" | "head" | "tail";

type RejectCode =
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

interface Token {
  text: string;
  quote: "none" | "single" | "double";
}

export interface ShellReadSemantic {
  kind: "read";
  commandName: ReadCommandName;
  command: string;
  filePath: string;
  range:
    | { type: "all" }
    | { type: "lines"; start: number; end: number }
    | { type: "head"; count: number }
    | { type: "tail"; startLine: number };
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

const READ_COMMANDS = new Set(["cat", "nl", "sed", "head", "tail"]);
const UNSAFE_CHARS = /[|&;(){}]/;
const VARIABLE_OR_SUBST = /[$`]/;
const SIMPLE_PATH = /^(?:\.{1,2}\/|\/|[A-Za-z0-9_.@+-])[-A-Za-z0-9_./@:+,=]*$/;

function reject(code: RejectCode, reason: string): ShellSemanticResult {
  return { ok: false, code, reason };
}

function tokenize(line: string): Token[] | ShellSemanticResult {
  const tokens: Token[] = [];
  let current = "";
  let quote: Token["quote"] = "none";
  let tokenQuote: Token["quote"] = "none";

  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!;
    if (quote === "single") {
      if (ch === "'") quote = "none";
      else current += ch;
      continue;
    }
    if (quote === "double") {
      if (ch === '"') quote = "none";
      else current += ch;
      continue;
    }
    if (ch === "'") {
      quote = "single";
      tokenQuote = "single";
      continue;
    }
    if (ch === '"') {
      quote = "double";
      tokenQuote = "double";
      continue;
    }
    if (/\s/.test(ch)) {
      if (current) {
        tokens.push({ text: current, quote: tokenQuote });
        current = "";
        tokenQuote = "none";
      }
      continue;
    }
    if (ch === "\\")
      return reject(
        "unsafe_shell_syntax",
        "backslash escaping is not in the supported subset",
      );
    current += ch;
  }
  if (quote !== "none")
    return reject("unterminated_quote", "quoted token is not closed");
  if (current) tokens.push({ text: current, quote: tokenQuote });
  return tokens;
}

function validatePathToken(
  token: Token | undefined,
): string | ShellSemanticResult {
  if (!token) return reject("missing_path", "expected one file path");
  if (VARIABLE_OR_SUBST.test(token.text))
    return reject(
      "variable_path",
      "paths using variables or command substitution are not display-safe",
    );
  if (!SIMPLE_PATH.test(token.text))
    return reject(
      "variable_path",
      "path contains characters outside the supported literal subset",
    );
  return token.text;
}

function parseReadLine(line: string): ShellSemanticResult {
  if (!line.trim()) return reject("empty", "empty command");
  if (UNSAFE_CHARS.test(line) || VARIABLE_OR_SUBST.test(line))
    return reject(
      "unsafe_shell_syntax",
      "command contains shell operators, variables, or substitution",
    );
  const tokens = tokenize(line);
  if (!Array.isArray(tokens)) return tokens;
  if (tokens.length === 0) return reject("empty", "empty command");
  const [cmdTok, ...rest] = tokens;
  const commandName = cmdTok!.text;
  if (!READ_COMMANDS.has(commandName))
    return reject(
      "unsupported_command",
      "only cat, nl, sed, head, and tail are recognized",
    );

  let pathToken: Token | undefined;
  let range: ShellReadSemantic["range"] = { type: "all" };
  let presentation: ShellReadSemantic["presentation"] = {
    lineNumbers: false,
  };

  const consumeOnlyPath = (tok: Token): ShellSemanticResult | null => {
    if (pathToken)
      return reject(
        "multiple_paths",
        "multiple file operands are not supported",
      );
    pathToken = tok;
    return null;
  };

  for (let i = 0; i < rest.length; i++) {
    const tok = rest[i]!;
    if (tok.text === "--") continue;
    if (tok.text === ">" || tok.text === ">>" || tok.text.startsWith(">"))
      return reject(
        "redirection_on_read",
        "read commands with redirection are not display-only reads",
      );
    if (tok.text.startsWith("<"))
      return reject(
        "redirection_on_read",
        "input redirection is outside the supported read subset",
      );

    if (commandName === "nl") {
      if (tok.text === "-ba") continue;
      if (tok.text === "-w") {
        const next = rest[++i];
        const width = next ? Number(next.text) : NaN;
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
      if (tok.text === "-s") {
        const next = rest[++i];
        if (!next)
          return reject("unsupported_option", "nl -s requires a separator");
        const prev =
          presentation.lineNumbers !== false
            ? presentation.lineNumbers
            : { style: "nl" as const };
        presentation = { lineNumbers: { ...prev, separator: next.text } };
        continue;
      }
      if (tok.text.startsWith("-"))
        return reject(
          "unsupported_option",
          `unsupported nl option ${tok.text}`,
        );
      const err = consumeOnlyPath(tok);
      if (err) return err;
      continue;
    }

    if (commandName === "sed") {
      if (tok.text !== "-n")
        return reject(
          "unsupported_option",
          "only sed -n 'N,Mp' path is supported",
        );
      const expr = rest[++i];
      const path = rest[++i];
      if (!expr || !path)
        return reject("missing_path", "sed requires expression and path");
      const m = expr.text.match(/^([1-9]\d*),([1-9]\d*)p$/);
      if (!m) return reject("invalid_range", "sed expression must be N,Mp");
      const start = Number(m[1]);
      const end = Number(m[2]);
      if (end < start)
        return reject("invalid_range", "sed end line must be >= start line");
      range = { type: "lines", start, end };
      pathToken = path;
      if (i !== rest.length - 1)
        return reject(
          "multiple_paths",
          "sed supports exactly one file operand",
        );
      break;
    }

    if (commandName === "head") {
      if (tok.text === "-n") {
        const next = rest[++i];
        const count = next ? Number(next.text) : NaN;
        if (!Number.isInteger(count) || count < 1)
          return reject(
            "unsupported_option",
            "head -n requires a positive integer",
          );
        range = { type: "head", count };
        continue;
      }
      // Support combined -nN (no space), e.g. head -n50 file
      const headNMatch = tok.text.match(/^-n(\d+)$/);
      if (headNMatch) {
        const count = Number(headNMatch[1]);
        if (!Number.isInteger(count) || count < 1)
          return reject(
            "unsupported_option",
            "head -n requires a positive integer",
          );
        range = { type: "head", count };
        continue;
      }
      if (tok.text.startsWith("-"))
        return reject(
          "unsupported_option",
          `unsupported head option ${tok.text}`,
        );
      const err = consumeOnlyPath(tok);
      if (err) return err;
      continue;
    }

    if (commandName === "tail") {
      if (tok.text === "-n") {
        const next = rest[++i];
        const m = next?.text.match(/^\+([1-9]\d*)$/);
        if (!m) return reject("unsupported_option", "tail supports only -n +N");
        range = { type: "tail", startLine: Number(m[1]) };
        continue;
      }
      // Support combined -n+N (no space), e.g. tail -n+10 file
      const tailNMatch = tok.text.match(/^-n\+([1-9]\d*)$/);
      if (tailNMatch) {
        range = { type: "tail", startLine: Number(tailNMatch[1]) };
        continue;
      }
      if (tok.text.startsWith("-"))
        return reject(
          "unsupported_option",
          `unsupported tail option ${tok.text}`,
        );
      const err = consumeOnlyPath(tok);
      if (err) return err;
      continue;
    }

    if (commandName === "cat") {
      if (tok.text.startsWith("-") && tok.text !== "--")
        return reject(
          "unsupported_option",
          `unsupported cat option ${tok.text}`,
        );
      const err = consumeOnlyPath(tok);
      if (err) return err;
    }
  }

  const path = validatePathToken(pathToken);
  if (typeof path !== "string") return path;
  return {
    ok: true,
    value: {
      kind: "read",
      command: line,
      commandName: commandName as ReadCommandName,
      filePath: path,
      range,
      presentation,
    },
  };
}

function parseHeredoc(command: string): ShellSemanticResult {
  const lines = command.replace(/\r\n/g, "\n").split("\n");
  const commandLine = lines[0] ?? "";
  if (UNSAFE_CHARS.test(commandLine) || VARIABLE_OR_SUBST.test(commandLine))
    return reject(
      "unsafe_shell_syntax",
      "heredoc command line contains unsupported shell syntax",
    );
  const tokens = tokenize(commandLine);
  if (!Array.isArray(tokens)) return tokens;
  if (tokens[0]?.text !== "cat")
    return reject(
      "unsupported_command",
      "only cat heredoc writes are recognized",
    );

  let delimiter: Token | undefined;
  let pathToken: Token | undefined;
  for (let i = 1; i < tokens.length; i++) {
    const tok = tokens[i]!;
    if (tok.text.startsWith("<<")) {
      const raw = tok.text.slice(2);
      delimiter = raw ? { text: raw, quote: tok.quote } : tokens[++i];
      continue;
    }
    if (tok.text === ">") {
      pathToken = tokens[++i];
      continue;
    }
    if (tok.text.startsWith(">") && tok.text.length > 1) {
      pathToken = { text: tok.text.slice(1), quote: tok.quote };
      continue;
    }
    return reject("invalid_heredoc", `unexpected heredoc token ${tok.text}`);
  }
  if (!delimiter || !delimiter.text)
    return reject("invalid_heredoc", "missing heredoc delimiter");
  const path = validatePathToken(pathToken);
  if (typeof path !== "string") return path;
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(delimiter.text))
    return reject("invalid_heredoc", "delimiter must be a simple literal word");

  const terminatorIndex = lines.findIndex(
    (line, i) => i > 0 && line === delimiter.text,
  );
  if (terminatorIndex < 0)
    return reject("invalid_heredoc", "terminator line was not found");
  if (
    terminatorIndex !== lines.length - 1 &&
    !(terminatorIndex === lines.length - 2 && lines.at(-1) === "")
  )
    return reject(
      "invalid_heredoc",
      "content after heredoc terminator is unsupported",
    );

  const content = lines.slice(1, terminatorIndex).join("\n");
  const terminator = lines[terminatorIndex]!;
  return {
    ok: true,
    value: {
      kind: "write",
      command: command,
      commandName: "cat",
      filePath: path,
      writeMode: "overwrite",
      heredoc: {
        delimiter: delimiter.text,
        quoted: delimiter.quote !== "none",
        commandLine,
        content,
        terminator,
      },
      segments: [
        { kind: "command-header", text: `${commandLine}\n` },
        { kind: "write-content", text: content, filePath: path },
        { kind: "command-footer", text: `\n${terminator}` },
      ],
    },
  };
}

export function parseShellSemantic(command: string): ShellSemanticResult {
  // Strip shell -c/-lc wrappers that Codex emits for commandExecution items.
  // Codex uses sh, bash, or zsh (bare name or any absolute path) with -c or
  // -lc depending on platform/config. Match the basename like Codex's own
  // detect_shell_type (shell_detect.rs) does via file_stem().
  const shCMatch = command.match(
    /^(?:.*\/)?(?:sh|bash|zsh)\s+-l?c\s+'([\s\S]*)'\s*$/,
  );
  if (shCMatch) command = shCMatch[1]!;
  if (command.includes("\n") || command.includes("<<"))
    return parseHeredoc(command);
  return parseReadLine(command);
}
