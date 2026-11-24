export type ContentFormat = { kind: "content"; language: string };

export type NlFormat = {
  kind: "nl-line-number-prefixed";
  width: number;
  separator: string;
  format: ContentFormat;
};

export type OutputFormat =
  | ContentFormat
  | { kind: "line-number-prefixed"; format: OutputFormat }
  | { kind: "individual-lines"; format: OutputFormat }
  | NlFormat;

export type OutputPlan = {
  version: 1;
  blocks: OutputBlockPlan[];
};

export type OutputBlockPlan = {
  id: string;
  document?: { filePath: string; preview: boolean };
  format: OutputFormat;
  location: BlockLocationSpec;
};

export type BlockLocationSpec =
  | { kind: "from-cursor"; end: BlockEndSpec; validator?: SpanValidatorId }
  | { kind: "unique-literal"; text: string; include: "self" };

export type BlockEndSpec =
  | { kind: "line-count"; count: number }
  | { kind: "end-of-output"; requiresComplete: true }
  | { kind: "before-block"; blockId: string };

export type SpanValidatorId =
  | "non-empty"
  | "colon-line-number-prefixed"
  | "line-number-prefixed-with-context";

export type NumberedOutputRow =
  | {
      kind: "numbered";
      lineNumber: number;
      delimiter: ":" | "-";
      prefix: string;
      text: string;
    }
  | { kind: "group-separator" };

export function parseNumberedOutputRow(line: string): NumberedOutputRow | null {
  if (line === "--") return { kind: "group-separator" };
  const match = /^(\d+)([:-])([^\n]*)$/.exec(line);
  if (!match) return null;
  const lineNumber = match[1]!;
  const delimiter = match[2] as ":" | "-";
  return {
    kind: "numbered",
    lineNumber: Number(lineNumber),
    delimiter,
    prefix: lineNumber + delimiter,
    text: match[3]!,
  };
}

export function* splitOutputRows(
  text: string,
): Generator<{ text: string; terminator: string }> {
  for (let start = 0; start < text.length; ) {
    const newline = text.indexOf("\n", start);
    const lineEnd = newline === -1 ? text.length : newline;
    const rowEnd = newline === -1 ? lineEnd : newline + 1;
    const contentEnd =
      newline !== -1 && text[lineEnd - 1] === "\r" ? lineEnd - 1 : lineEnd;
    yield {
      text: text.slice(start, contentEnd),
      terminator: text.slice(contentEnd, rowEnd),
    };
    start = rowEnd;
  }
}

type NlRowOptions = { width: number; separator: string };
type NlOutputRow = { prefix: string; text: string };

export function parseNlOutputRow(
  line: string,
  { width, separator }: NlRowOptions,
  paddedWidth = width + new TextEncoder().encode(separator).length,
): NlOutputRow | null {
  if (line.length === 0) return { prefix: "", text: "" };

  const padding = line.slice(0, paddedWidth);
  if (padding.length === paddedWidth && /^ +$/.test(padding)) {
    return { prefix: padding, text: line.slice(paddedWidth) };
  }

  const match = /^( *)(\d+)/.exec(line);
  if (!match) return null;
  const [field, , digits] = match;
  if (
    field.length !== Math.max(width, digits!.length) ||
    !line.startsWith(separator, field.length)
  ) {
    return null;
  }
  const prefixEnd = field.length + separator.length;
  return { prefix: line.slice(0, prefixEnd), text: line.slice(prefixEnd) };
}

export function* parseNlOutputRows(
  text: string,
  options: NlRowOptions,
): Generator<{ row: NlOutputRow | null; terminator: string }> {
  // GNU nl pads unnumbered rows by the separator's byte length.
  const paddedWidth =
    options.width + new TextEncoder().encode(options.separator).length;
  for (const line of splitOutputRows(text)) {
    yield {
      row: parseNlOutputRow(line.text, options, paddedWidth),
      terminator: line.terminator,
    };
  }
}

function formatAccepts(text: string, format: OutputFormat): boolean {
  if (format.kind !== "nl-line-number-prefixed") return true;
  if (!text) return false;
  for (const { row } of parseNlOutputRows(text, format)) {
    if (!row) return false;
  }
  return true;
}

export type OutputApplicationMode =
  | { kind: "complete" }
  | { kind: "streaming"; strategy: "none" | "stable-prefix" };

export type SegmentedOutputPiece =
  | {
      kind: "structured";
      blockId: string;
      start: number;
      end: number;
      format: OutputFormat;
    }
  | {
      kind: "raw";
      start: number;
      end: number;
      reason: string;
    };

export type SegmentedOutput = {
  pieces: SegmentedOutputPiece[];
  copyText: string;
};

type Span = { start: number; end: number };

function clampSpan(span: Span, total: number): Span | null {
  if (span.start < 0 || span.end < 0) return null;
  if (span.start > span.end) return null;
  if (span.end > total) return null;
  return span;
}

function resolveUniqueLiteral(stdout: string, text: string): Span | null {
  const first = stdout.indexOf(text);
  if (first < 0) return null;
  const second = stdout.indexOf(text, first + 1);
  if (second >= 0) return null;
  return { start: first, end: first + text.length };
}

function consumeLineCount(
  stdout: string,
  start: number,
  count: number,
): number | null {
  if (count <= 0) return null;
  let pos = start;
  for (let i = 0; i < count; i++) {
    if (pos >= stdout.length) return null;
    const nl = stdout.indexOf("\n", pos);
    if (nl < 0) {
      if (i < count - 1) return null;
      pos = stdout.length;
    } else {
      pos = nl + 1;
    }
  }
  return pos;
}

function validateSpan(
  stdout: string,
  span: Span,
  validator: SpanValidatorId | undefined,
): boolean {
  const text = stdout.slice(span.start, span.end);
  switch (validator) {
    case undefined:
      return true;
    case "non-empty":
      return /\S/.test(text);
    case "colon-line-number-prefixed":
    case "line-number-prefixed-with-context": {
      for (const { text: line } of splitOutputRows(text)) {
        if (line.trim().length === 0) continue;
        const row = parseNumberedOutputRow(line);
        if (
          !row ||
          (validator === "colon-line-number-prefixed" &&
            (row.kind !== "numbered" || row.delimiter !== ":"))
        ) {
          return false;
        }
      }
      return true;
    }
  }
}

function findNextAnchorStart(
  cursor: number,
  candidates: Array<Span | null>,
): number | null {
  let best: number | null = null;
  for (const span of candidates) {
    if (!span) continue;
    if (span.start <= cursor) continue;
    if (best == null || span.start < best) best = span.start;
  }
  return best;
}

function resolveStaticSpan(
  stdout: string,
  block: OutputBlockPlan,
): Span | null {
  if (block.location.kind === "unique-literal") {
    return resolveUniqueLiteral(stdout, block.location.text);
  }
  return null;
}

export function segmentOutput(
  stdout: string,
  outputPlan: OutputPlan,
  mode: OutputApplicationMode,
): SegmentedOutput {
  const total = stdout.length;

  if (mode.kind !== "complete") {
    return {
      pieces: [
        {
          kind: "raw",
          start: 0,
          end: total,
          reason: `mode:${mode.kind}:${mode.strategy}`,
        },
      ],
      copyText: stdout,
    };
  }

  if (!outputPlan.blocks.length) {
    return {
      pieces: [{ kind: "raw", start: 0, end: total, reason: "no-blocks" }],
      copyText: stdout,
    };
  }

  const pieces: SegmentedOutputPiece[] = [];
  let cursor = 0;
  const acceptedStarts = new Map<string, number>();
  const staticSpans = outputPlan.blocks.map((block) =>
    resolveStaticSpan(stdout, block),
  );

  const pushRaw = (start: number, end: number, reason: string) => {
    const span = clampSpan({ start, end }, total);
    if (!span || span.end <= span.start) return;
    const last = pieces[pieces.length - 1];
    if (last && last.kind === "raw" && last.end === span.start) {
      last.end = span.end;
      return;
    }
    pieces.push({ kind: "raw", start: span.start, end: span.end, reason });
  };

  for (let i = 0; i < outputPlan.blocks.length; i++) {
    const block = outputPlan.blocks[i]!;
    let resolved: Span | null;
    let validator: SpanValidatorId | undefined;
    const staticSpan = staticSpans[i] ?? null;

    if (block.location.kind === "unique-literal") {
      resolved = staticSpan;
    } else {
      const endSpec = block.location.end;
      const start = cursor;
      let end: number | null = null;
      if (endSpec.kind === "line-count") {
        end = consumeLineCount(stdout, start, endSpec.count);
      } else if (endSpec.kind === "end-of-output") {
        end = total;
      } else {
        const target = outputPlan.blocks.find((b) => b.id === endSpec.blockId);
        if (target) {
          const acceptedStart = acceptedStarts.get(target.id);
          if (acceptedStart != null) {
            end = acceptedStart;
          } else {
            const targetIdx = outputPlan.blocks.indexOf(target);
            const targetStatic = targetIdx >= 0 ? staticSpans[targetIdx] : null;
            end = targetStatic?.start ?? null;
          }
        }
      }
      resolved = end == null ? null : clampSpan({ start, end }, total);
      validator = block.location.validator;
    }

    if (
      resolved &&
      block.location.kind === "unique-literal" &&
      resolved.start > cursor
    ) {
      pushRaw(cursor, resolved.start, "gap-before-structured");
      cursor = resolved.start;
    }

    const overlapConflict = resolved ? resolved.start < cursor : false;
    const validatorOk =
      resolved && !overlapConflict
        ? validateSpan(stdout, resolved, validator) &&
          formatAccepts(
            stdout.slice(resolved.start, resolved.end),
            block.format,
          )
        : false;

    if (resolved && !overlapConflict && validatorOk) {
      if (resolved.start > cursor) {
        pushRaw(cursor, resolved.start, "uncovered-gap");
      }
      const structuredPiece: SegmentedOutputPiece = {
        kind: "structured",
        blockId: block.id,
        start: resolved.start,
        end: resolved.end,
        format: block.format,
      };
      pieces.push(structuredPiece);
      acceptedStarts.set(block.id, resolved.start);
      cursor = resolved.end;
      continue;
    }

    if (block.location.kind === "from-cursor") {
      let fallbackEnd: number;
      if (resolved && resolved.end > cursor) {
        fallbackEnd = resolved.end;
      } else {
        const nextAnchor = findNextAnchorStart(cursor, staticSpans);
        fallbackEnd = nextAnchor ?? total;
      }
      if (fallbackEnd <= cursor) fallbackEnd = total;
      pushRaw(cursor, fallbackEnd, "fallback:from-cursor");
      cursor = fallbackEnd;
      continue;
    }

    if (resolved && resolved.end > cursor && resolved.start <= cursor) {
      pushRaw(cursor, resolved.end, "fallback:anchor");
      cursor = resolved.end;
    }
  }

  if (cursor < total) {
    pushRaw(cursor, total, "trailing-raw");
  }

  if (pieces.length === 0) {
    pieces.push({ kind: "raw", start: 0, end: total, reason: "empty-plan" });
  }

  return { pieces, copyText: stdout };
}
