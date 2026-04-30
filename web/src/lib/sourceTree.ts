import { langFromPath } from "../highlight";

export interface SourceNode {
  language: string;
  text: string;
  segments: SourceSegment[];
}

export type SourceSegment =
  | { kind: "text"; span: SourceSpan }
  | {
      kind: "embed";
      span: SourceSpan;
      content: SourceNode;
      escaping: EscapingScheme;
    };

export interface SourceSpan {
  start: number;
  end: number;
}

export type EscapingScheme =
  | { kind: "shell-single-quote" }
  | { kind: "shell-double-quote"; conservative: true }
  | {
      kind: "shell-heredoc";
      delimiter: string;
      quoted: boolean;
      supportsExitReentry: false;
    };

type SourceTreeRejectCode =
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

export type SourceTreeParseResult =
  | { ok: true; value: SourceNode }
  | { ok: false; code: SourceTreeRejectCode; reason: string };

interface WrapperParse {
  decodedPayload: string;
  payload: SourceSpan;
  escaping: EscapingScheme;
}

type WrapperParseResult =
  | { kind: "wrapper"; value: WrapperParse }
  | { kind: "none" }
  | { kind: "reject"; code: SourceTreeRejectCode; reason: string };

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

function span(start: number, end: number): SourceSpan {
  return { start, end };
}

function textSegment(start: number, end: number): SourceSegment | null {
  if (end <= start) return null;
  return { kind: "text", span: span(start, end) };
}

function reject(
  code: SourceTreeRejectCode,
  reason: string,
): SourceTreeParseResult {
  return { ok: false, code, reason };
}

function shellBasename(name: string): string {
  const parts = name.split("/");
  return parts[parts.length - 1] ?? name;
}

function decodeShellDoubleQuotedPayloadConservative(
  source: string,
  quoteStart: number,
):
  | { decoded: string; closingQuote: number }
  | { reject: string; code: SourceTreeRejectCode } {
  let i = quoteStart + 1;
  let decoded = "";
  while (i < source.length) {
    const ch = source[i]!;
    if (ch === '"') {
      return { decoded, closingQuote: i };
    }
    if (ch === "\\") {
      const next = source[i + 1];
      if (!next) {
        return {
          reject: "unterminated double-quoted payload",
          code: "unterminated_quote",
        };
      }
      if (next !== '"' && next !== "\\" && next !== "$" && next !== "`") {
        return {
          reject: `unsupported double-quote escape \\${next}`,
          code: "unsafe_shell_syntax",
        };
      }
      decoded += next;
      i += 2;
      continue;
    }
    if (ch === "$") {
      return {
        reject:
          "dynamic expansion in double-quoted wrapper payload is not supported",
        code: "unsafe_shell_syntax",
      };
    }
    if (ch === "`") {
      return {
        reject: "backticks in double-quoted wrapper payload are not supported",
        code: "unsafe_shell_syntax",
      };
    }
    decoded += ch;
    i++;
  }
  return {
    reject: "unterminated double-quoted payload",
    code: "unterminated_quote",
  };
}

function parseShellWrapper(command: string): WrapperParseResult {
  const trimmed = command.trim();
  if (!trimmed) return { kind: "none" };
  const leadWs = command.match(/^\s*/)?.[0].length ?? 0;
  if (leadWs !== 0) return { kind: "none" };
  const firstWs = command.search(/\s/);
  if (firstWs <= 0) return { kind: "none" };
  const shellToken = command.slice(0, firstWs);
  const base = shellBasename(shellToken);
  if (base !== "sh" && base !== "bash" && base !== "zsh") {
    return { kind: "none" };
  }

  let i = firstWs;
  while (i < command.length && /\s/.test(command[i]!)) i++;
  const flagStart = i;
  while (i < command.length && !/\s/.test(command[i]!)) i++;
  const flag = command.slice(flagStart, i);
  if (flag !== "-c" && flag !== "-lc" && flag !== "-cl") {
    return { kind: "none" };
  }

  while (i < command.length && /\s/.test(command[i]!)) i++;
  if (i >= command.length) {
    return rejectWrapper(
      "unsafe_shell_syntax",
      "shell wrapper requires exactly one quoted payload",
    );
  }
  const quoteChar = command[i]!;
  if (quoteChar !== "'" && quoteChar !== '"') {
    return rejectWrapper(
      "unsafe_shell_syntax",
      "shell wrapper payload must be single or double quoted",
    );
  }

  if (quoteChar === "'") {
    let cursor = i + 1;
    let decodedPayload = "";
    for (;;) {
      const close = command.indexOf("'", cursor);
      if (close < 0) {
        return rejectWrapper(
          "unterminated_quote",
          "unterminated single-quoted wrapper payload",
        );
      }
      decodedPayload += command.slice(cursor, close);
      if (command.slice(close, close + 4) === "'\\''") {
        decodedPayload += "'";
        cursor = close + 4;
        continue;
      }
      const trailer = command.slice(close + 1);
      if (trailer.trim().length > 0) {
        return rejectWrapper(
          "unsafe_shell_syntax",
          "extra positional args after wrapper payload are not supported",
        );
      }
      return {
        kind: "wrapper",
        value: {
          decodedPayload,
          payload: span(i + 1, close),
          escaping: { kind: "shell-single-quote" },
        },
      };
    }
  }

  const decoded = decodeShellDoubleQuotedPayloadConservative(command, i);
  if ("reject" in decoded) {
    return rejectWrapper(decoded.code, decoded.reject);
  }
  const trailer = command.slice(decoded.closingQuote + 1);
  if (trailer.trim().length > 0) {
    return rejectWrapper(
      "unsafe_shell_syntax",
      "extra positional args after wrapper payload are not supported",
    );
  }
  return {
    kind: "wrapper",
    value: {
      decodedPayload: decoded.decoded,
      payload: span(i + 1, decoded.closingQuote),
      escaping: { kind: "shell-double-quote", conservative: true },
    },
  };
}

function rejectWrapper(
  code: SourceTreeRejectCode,
  reason: string,
): WrapperParseResult {
  return { kind: "reject", code, reason };
}

interface HeredocParse {
  bodyStart: number;
  bodyEnd: number;
  delimiter: string;
  quoted: boolean;
  language: string;
}

type HeredocParseResult =
  | { kind: "none" }
  | { kind: "ok"; value: HeredocParse }
  | { kind: "reject"; code: SourceTreeRejectCode; reason: string };

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

function parseHeredoc(text: string): HeredocParseResult {
  const lines = text.split("\n");
  const starts: number[] = [];
  let pos = 0;
  for (const line of lines) {
    starts.push(pos);
    pos += line.length + 1;
  }

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
  if (heredocLineIndex < 0 || opIndex < 0) return { kind: "none" };
  const commandLine = lines[heredocLineIndex] ?? "";
  if (commandLine.slice(opIndex, opIndex + 3) === "<<-") {
    return {
      kind: "reject",
      code: "invalid_heredoc",
      reason: "<<- heredoc is not supported",
    };
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
    if (close < 0) {
      return {
        kind: "reject",
        code: "unterminated_quote",
        reason: "unterminated quoted heredoc delimiter",
      };
    }
    delimiter = commandLine.slice(cursor, close);
    delimiterEnd = close + 1;
  } else {
    const m = commandLine.slice(cursor).match(/^([A-Za-z_][A-Za-z0-9_]*)/);
    if (!m) {
      return {
        kind: "reject",
        code: "invalid_heredoc",
        reason: "invalid heredoc delimiter",
      };
    }
    delimiter = m[1]!;
    delimiterEnd = cursor + delimiter.length;
  }
  if (!delimiter) {
    return {
      kind: "reject",
      code: "invalid_heredoc",
      reason: "empty delimiter",
    };
  }
  if (findHeredocOperatorIndex(commandLine.slice(delimiterEnd)) >= 0) {
    return {
      kind: "reject",
      code: "invalid_heredoc",
      reason: "multiple heredocs are not supported in this batch",
    };
  }
  const terminatorIndex = lines.findIndex(
    (line, idx) => idx > heredocLineIndex && line === delimiter,
  );
  if (terminatorIndex < 0) {
    return {
      kind: "reject",
      code: "invalid_heredoc",
      reason: "heredoc terminator line was not found",
    };
  }
  const hasTrailingHeredoc = lines
    .slice(terminatorIndex + 1)
    .some((line) => findHeredocOperatorIndex(line) >= 0);
  if (hasTrailingHeredoc) {
    return {
      kind: "reject",
      code: "invalid_heredoc",
      reason: "multiple heredocs are not supported in this batch",
    };
  }

  const headerLen = (starts[heredocLineIndex] ?? 0) + commandLine.length + 1;
  const bodyStart = headerLen;
  let bodyEnd = starts[terminatorIndex] ?? text.length;
  if (bodyEnd > bodyStart && text[bodyEnd - 1] === "\n") {
    bodyEnd -= 1;
  }
  const commandName = commandLine.trim().split(/\s+/)[0] ?? "";
  const language = inferHeredocLanguage(commandName, commandLine);
  return {
    kind: "ok",
    value: {
      bodyStart,
      bodyEnd,
      delimiter,
      quoted,
      language,
    },
  };
}

function inferHeredocLanguage(
  commandName: string,
  commandLine: string,
): string {
  if (INTERPRETER_LANG[commandName]) return INTERPRETER_LANG[commandName];
  if (commandName !== "cat") return "text";
  const redirect = commandLine.match(/(?:^|\s)>\s*(\S+)/);
  if (!redirect) return "text";
  return langFromPath(redirect[1]!) || "text";
}

function parseShellNode(text: string): SourceTreeParseResult {
  const heredoc = parseHeredoc(text);
  if (heredoc.kind === "reject") {
    return reject(heredoc.code, heredoc.reason);
  }
  if (heredoc.kind === "none") {
    return {
      ok: true,
      value: {
        language: "bash",
        text,
        segments: [{ kind: "text", span: span(0, text.length) }],
      },
    };
  }

  const bodyText = text.slice(heredoc.value.bodyStart, heredoc.value.bodyEnd);
  const child: SourceNode = {
    language: heredoc.value.language,
    text: bodyText,
    segments: [{ kind: "text", span: span(0, bodyText.length) }],
  };
  const segments: SourceSegment[] = [];
  const before = textSegment(0, heredoc.value.bodyStart);
  if (before) segments.push(before);
  segments.push({
    kind: "embed",
    span: span(heredoc.value.bodyStart, heredoc.value.bodyEnd),
    content: child,
    escaping: {
      kind: "shell-heredoc",
      delimiter: heredoc.value.delimiter,
      quoted: heredoc.value.quoted,
      supportsExitReentry: false,
    },
  });
  const after = textSegment(heredoc.value.bodyEnd, text.length);
  if (after) segments.push(after);
  return {
    ok: true,
    value: {
      language: "bash",
      text,
      segments,
    },
  };
}

export function parseCommandSourceTree(command: string): SourceTreeParseResult {
  if (!command.trim()) return reject("empty", "empty command");

  const wrapper = parseShellWrapper(command);
  if (wrapper.kind === "reject") {
    return reject(wrapper.code, wrapper.reason);
  }
  if (wrapper.kind === "none") {
    return parseShellNode(command);
  }

  const payloadNode = parseShellNode(wrapper.value.decodedPayload);
  if (!payloadNode.ok) return payloadNode;
  const segments: SourceSegment[] = [];
  const prefix = textSegment(0, wrapper.value.payload.start);
  if (prefix) segments.push(prefix);
  segments.push({
    kind: "embed",
    span: wrapper.value.payload,
    content: payloadNode.value,
    escaping: wrapper.value.escaping,
  });
  const suffix = textSegment(wrapper.value.payload.end, command.length);
  if (suffix) segments.push(suffix);
  return {
    ok: true,
    value: {
      language: "bash",
      text: command,
      segments,
    },
  };
}
