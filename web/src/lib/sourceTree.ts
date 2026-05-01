import { langFromPath } from "../highlight";

export interface SourceNode {
  language: string;
  text: string;
  segments: SourceSegment[];
}

export type SourceEmbedRole = "inline-projected-payload";

export type SourceSegment =
  | { kind: "text"; span: SourceSpan }
  | {
      kind: "embed";
      span: SourceSpan;
      content: SourceNode;
      escaping: EscapingScheme;
      projection?: SourceProjection;
      role?: SourceEmbedRole;
    };

export interface SourceSpan {
  start: number;
  end: number;
}

export interface SourceProjection {
  points: SourceProjectionPoint[];
}

export interface SourceProjectionPoint {
  child: number;
  parent: number;
}

export type EscapingScheme =
  | { kind: "shell-single-quote" }
  | { kind: "shell-double-quote"; conservative: true }
  | { kind: "projected" }
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
  projection: SourceProjection;
}

type WrapperParseResult =
  | { kind: "wrapper"; value: WrapperParse }
  | { kind: "none" }
  | { kind: "reject"; code: SourceTreeRejectCode; reason: string };

const INTERPRETER_LANG: Record<string, string> = {
  sh: "bash",
  bash: "bash",
  zsh: "bash",
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

function isValidSourceSpan(span: SourceSpan): boolean {
  return (
    Number.isInteger(span.start) &&
    Number.isInteger(span.end) &&
    span.start >= 0 &&
    span.end >= span.start
  );
}

function validateProjection(
  projection: SourceProjection,
): { ok: true; maxChild: number } | { ok: false } {
  const points = projection.points;
  if (points.length < 1) return { ok: false };
  for (const point of points) {
    if (
      !Number.isInteger(point.child) ||
      !Number.isInteger(point.parent) ||
      point.child < 0 ||
      point.parent < 0
    ) {
      return { ok: false };
    }
  }
  if (points[0]!.child !== 0 || points[0]!.parent !== 0) {
    return { ok: false };
  }
  if (points.length === 1) return { ok: true, maxChild: 0 };
  for (let i = 1; i < points.length; i++) {
    const prev = points[i - 1]!;
    const curr = points[i]!;
    if (curr.child <= prev.child) return { ok: false };
    if (curr.parent <= prev.parent) return { ok: false };
  }
  return { ok: true, maxChild: points[points.length - 1]!.child };
}

export function projectOffset(
  projection: SourceProjection,
  offset: number,
): number | null {
  if (!Number.isInteger(offset) || offset < 0) return null;
  const validated = validateProjection(projection);
  if (!validated.ok) return null;
  if (offset > validated.maxChild) return null;
  const points = projection.points;
  for (const point of points) {
    if (offset === point.child) return point.parent;
  }
  for (let i = 0; i + 1 < points.length; i++) {
    const from = points[i]!;
    const to = points[i + 1]!;
    if (offset < from.child || offset > to.child) continue;
    const childDelta = to.child - from.child;
    const parentDelta = to.parent - from.parent;
    if (childDelta <= 0 || parentDelta < 0) return null;
    if (parentDelta !== childDelta) return null;
    return from.parent + (offset - from.child);
  }
  return null;
}

export function projectSpan(
  projection: SourceProjection,
  inputSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(inputSpan)) return null;
  const start = projectOffset(projection, inputSpan.start);
  const end = projectOffset(projection, inputSpan.end);
  if (start == null || end == null || end < start) return null;
  return { start, end };
}

export function projectEmbedSpan(
  segment: Extract<SourceSegment, { kind: "embed" }>,
  childSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(childSpan)) return null;
  const childLen = segment.content.text.length;
  const parentLen = segment.span.end - segment.span.start;
  if (childSpan.end > childLen) return null;
  const local = (() => {
    if (segment.projection == null) {
      return { start: childSpan.start, end: childSpan.end };
    }
    const projectedStart = projectOffset(segment.projection, 0);
    const projectedEnd = projectOffset(segment.projection, childLen);
    if (
      projectedStart !== 0 ||
      projectedEnd == null ||
      projectedEnd !== parentLen
    ) {
      return null;
    }
    return projectSpan(segment.projection, childSpan);
  })();
  if (!local) return null;
  if (local.start < 0 || local.end < local.start || local.end > parentLen) {
    return null;
  }
  return {
    start: segment.span.start + local.start,
    end: segment.span.start + local.end,
  };
}

export function projectDescendantSpan(
  ancestor: SourceNode,
  embedPath: number[],
  descendantSpan: SourceSpan,
): SourceSpan | null {
  if (!isValidSourceSpan(descendantSpan)) return null;
  const embeds: Array<Extract<SourceSegment, { kind: "embed" }>> = [];
  let node: SourceNode = ancestor;
  for (const index of embedPath) {
    if (
      !Number.isInteger(index) ||
      index < 0 ||
      index >= node.segments.length
    ) {
      return null;
    }
    const segment = node.segments[index];
    if (!segment || segment.kind !== "embed") return null;
    embeds.push(segment);
    node = segment.content;
  }
  if (descendantSpan.end > node.text.length) return null;
  let current: SourceSpan = { ...descendantSpan };
  for (let i = embeds.length - 1; i >= 0; i--) {
    const projected = projectEmbedSpan(embeds[i]!, current);
    if (!projected) return null;
    current = projected;
  }
  return current;
}

function shellBasename(name: string): string {
  const parts = name.split("/");
  return parts[parts.length - 1] ?? name;
}

interface WrapperWordParse {
  decodedPayload: string;
  payload: SourceSpan;
  escaping: EscapingScheme;
  projection: SourceProjection;
  wordEnd: number;
}

interface ShellWordFragmentTemp {
  quote: "single" | "double" | "unquoted";
  rawSpanAbs: SourceSpan;
  contentSpanAbs: SourceSpan;
  decodedSpan: SourceSpan;
}

function isSafeWrapperUnquotedChar(ch: string): boolean {
  return /[A-Za-z0-9_./:@%+=,-]/.test(ch);
}

function parseShellWrapperPayloadWord(
  command: string,
  start: number,
): WrapperWordParse | { reject: string; code: SourceTreeRejectCode } {
  if (start >= command.length) {
    return {
      reject: "shell wrapper requires exactly one payload word",
      code: "unsafe_shell_syntax",
    };
  }
  if (/\s/.test(command[start]!)) {
    return {
      reject: "shell wrapper payload cannot start with whitespace",
      code: "unsafe_shell_syntax",
    };
  }

  const fragments: ShellWordFragmentTemp[] = [];
  const pointsAbs: SourceProjectionPoint[] = [];
  let decoded = "";
  let child = 0;
  let i = start;

  const startsQuoted = command[start] === "'" || command[start] === '"';
  const embedStartAbs = startsQuoted ? start + 1 : start;
  pointsAbs.push({ child: 0, parent: embedStartAbs });

  const appendDecodedChar = (ch: string, parentAbs: number) => {
    decoded += ch;
    child += 1;
    pointsAbs.push({ child, parent: parentAbs });
  };

  while (i < command.length) {
    const ch = command[i]!;
    if (/\s/.test(ch)) break;

    if (ch === "'") {
      const rawStartAbs = i + 1;
      const decodedStart = child;
      let cursor = i + 1;
      for (;;) {
        const close = command.indexOf("'", cursor);
        if (close < 0) {
          return {
            reject: "unterminated single-quoted wrapper payload",
            code: "unterminated_quote",
          };
        }
        for (let j = cursor; j < close; j++) {
          appendDecodedChar(command[j]!, j + 1);
        }
        if (command.slice(close, close + 4) === "'\\''") {
          appendDecodedChar("'", close + 4);
          cursor = close + 4;
          continue;
        }
        fragments.push({
          quote: "single",
          rawSpanAbs: span(rawStartAbs, close),
          contentSpanAbs: span(rawStartAbs, close),
          decodedSpan: span(decodedStart, child),
        });
        i = close + 1;
        break;
      }
      continue;
    }

    if (ch === '"') {
      const rawStartAbs = i + 1;
      const decodedStart = child;
      let cursor = i + 1;
      for (;;) {
        if (cursor >= command.length) {
          return {
            reject: "unterminated double-quoted payload",
            code: "unterminated_quote",
          };
        }
        const inner = command[cursor]!;
        if (inner === '"') {
          fragments.push({
            quote: "double",
            rawSpanAbs: span(rawStartAbs, cursor),
            contentSpanAbs: span(rawStartAbs, cursor),
            decodedSpan: span(decodedStart, child),
          });
          i = cursor + 1;
          break;
        }
        if (inner === "$") {
          return {
            reject:
              "dynamic expansion in double-quoted wrapper payload is not supported",
            code: "unsafe_shell_syntax",
          };
        }
        if (inner === "`") {
          return {
            reject:
              "backticks in double-quoted wrapper payload are not supported",
            code: "unsafe_shell_syntax",
          };
        }
        if (inner === "\\") {
          const next = command[cursor + 1];
          if (!next) {
            return {
              reject: "unterminated double-quoted payload",
              code: "unterminated_quote",
            };
          }
          if (next === "\n") {
            cursor += 2;
            continue;
          }
          if (next === '"' || next === "\\" || next === "$" || next === "`") {
            appendDecodedChar(next, cursor + 2);
            cursor += 2;
            continue;
          }
          appendDecodedChar("\\", cursor + 1);
          appendDecodedChar(next, cursor + 2);
          cursor += 2;
          continue;
        }
        appendDecodedChar(inner, cursor + 1);
        cursor += 1;
      }
      continue;
    }

    if (!isSafeWrapperUnquotedChar(ch)) {
      return {
        reject: `unsupported unquoted shell syntax in wrapper payload: ${ch}`,
        code: "unsafe_shell_syntax",
      };
    }
    const rawStartAbs = i;
    const decodedStart = child;
    while (i < command.length) {
      const current = command[i]!;
      if (/\s/.test(current) || current === "'" || current === '"') break;
      if (!isSafeWrapperUnquotedChar(current)) {
        return {
          reject: `unsupported unquoted shell syntax in wrapper payload: ${current}`,
          code: "unsafe_shell_syntax",
        };
      }
      appendDecodedChar(current, i + 1);
      i += 1;
    }
    fragments.push({
      quote: "unquoted",
      rawSpanAbs: span(rawStartAbs, i),
      contentSpanAbs: span(rawStartAbs, i),
      decodedSpan: span(decodedStart, child),
    });
  }

  if (fragments.length === 0) {
    return {
      reject: "shell wrapper requires exactly one payload word",
      code: "unsafe_shell_syntax",
    };
  }

  const wordEnd = i;
  const endsQuoted = (() => {
    const last = fragments[fragments.length - 1];
    return last != null && last.quote !== "unquoted";
  })();
  const embedEndAbs = endsQuoted ? wordEnd - 1 : wordEnd;
  if (embedEndAbs < embedStartAbs) {
    return {
      reject: "invalid wrapper payload span",
      code: "unsafe_shell_syntax",
    };
  }
  if (decoded.length === 0 && embedEndAbs !== embedStartAbs) {
    return {
      reject: "wrapper payload decoding produced ambiguous zero-length span",
      code: "unsafe_shell_syntax",
    };
  }

  if (decoded.length > 0) {
    const lastPoint = pointsAbs[pointsAbs.length - 1];
    if (!lastPoint) {
      return {
        reject: "wrapper payload projection construction failed",
        code: "unsafe_shell_syntax",
      };
    }
    if (embedEndAbs < lastPoint.parent) {
      return {
        reject: "wrapper payload projection is not monotonic",
        code: "unsafe_shell_syntax",
      };
    }
    lastPoint.parent = embedEndAbs;
  }

  const points: SourceProjectionPoint[] = pointsAbs.map((point) => ({
    child: point.child,
    parent: point.parent - embedStartAbs,
  }));
  const projection: SourceProjection = { points };

  const escaping: EscapingScheme = (() => {
    if (fragments.length === 1 && fragments[0]?.quote === "single") {
      return { kind: "shell-single-quote" };
    }
    if (fragments.length === 1 && fragments[0]?.quote === "double") {
      return { kind: "shell-double-quote", conservative: true };
    }
    return { kind: "projected" };
  })();

  return {
    decodedPayload: decoded,
    payload: span(embedStartAbs, embedEndAbs),
    escaping,
    projection,
    wordEnd,
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
      "shell wrapper requires exactly one payload word",
    );
  }
  const payloadWord = parseShellWrapperPayloadWord(command, i);
  if ("reject" in payloadWord) {
    return rejectWrapper(payloadWord.code, payloadWord.reject);
  }
  const trailer = command.slice(payloadWord.wordEnd);
  if (trailer.trim().length > 0) {
    return rejectWrapper(
      "unsafe_shell_syntax",
      "extra positional args after wrapper payload are not supported",
    );
  }
  return {
    kind: "wrapper",
    value: {
      decodedPayload: payloadWord.decodedPayload,
      payload: payloadWord.payload,
      escaping: payloadWord.escaping,
      projection: payloadWord.projection,
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
  const wrapper = parseShellWrapper(text);
  if (wrapper.kind === "reject") {
    return reject(wrapper.code, wrapper.reason);
  }
  if (wrapper.kind === "wrapper") {
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
      projection: wrapper.value.projection,
      role: "inline-projected-payload",
    });
    const suffix = textSegment(wrapper.value.payload.end, text.length);
    if (suffix) segments.push(suffix);
    return {
      ok: true,
      value: {
        language: "bash",
        text,
        segments,
      },
    };
  }

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
  let child: SourceNode;
  if (
    heredoc.value.language === "bash" ||
    heredoc.value.language === "shell" ||
    heredoc.value.language === "shellscript"
  ) {
    const nested = parseShellNode(bodyText);
    if (!nested.ok) return nested;
    child = nested.value;
  } else {
    child = {
      language: heredoc.value.language,
      text: bodyText,
      segments: [{ kind: "text", span: span(0, bodyText.length) }],
    };
  }
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
  return parseShellNode(command);
}
