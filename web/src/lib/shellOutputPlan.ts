export type OutputFormat =
  | { kind: "content"; language: string }
  | { kind: "line-number-prefixed"; format: OutputFormat }
  | { kind: "individual-lines"; format: OutputFormat };

export type OutputPlan = {
  version: 1;
  blocks: OutputBlockPlan[];
};

export type OutputBlockPlan = {
  id: string;
  source?: {
    commandIndex?: number;
    commandName?: string;
    filePath?: string;
  };
  format: OutputFormat;
  location: BlockLocationSpec;
};

export type BlockLocationSpec =
  | { kind: "whole-output"; validator?: SpanValidatorId }
  | { kind: "from-cursor"; end: BlockEndSpec; validator?: SpanValidatorId }
  | { kind: "unique-literal"; text: string; include: "self" };

export type BlockEndSpec =
  | { kind: "line-count"; count: number }
  | { kind: "end-of-output"; requiresComplete: true }
  | { kind: "before-block"; blockId: string };

export type SpanValidatorId = "non-empty" | "rg-line-number-prefixed";

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
  const second = stdout.indexOf(text, first + text.length);
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
    case "rg-line-number-prefixed": {
      const lines = text.split("\n");
      for (const rawLine of lines) {
        const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
        if (line.trim().length === 0) continue;
        if (!/^(\d+):(.*)$/.test(line)) return false;
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
  if (block.location.kind === "whole-output") {
    return { start: 0, end: stdout.length };
  }
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

    if (block.location.kind === "whole-output") {
      resolved = staticSpan;
      validator = block.location.validator;
    } else if (block.location.kind === "unique-literal") {
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
      block.location.kind !== "from-cursor" &&
      resolved.start > cursor
    ) {
      pushRaw(cursor, resolved.start, "gap-before-structured");
      cursor = resolved.start;
    }

    const overlapConflict = resolved ? resolved.start < cursor : false;
    const validatorOk =
      resolved && !overlapConflict
        ? validateSpan(stdout, resolved, validator)
        : false;

    if (resolved && !overlapConflict && validatorOk) {
      if (resolved.start > cursor) {
        pushRaw(cursor, resolved.start, "uncovered-gap");
      }
      pieces.push({
        kind: "structured",
        blockId: block.id,
        start: resolved.start,
        end: resolved.end,
        format: block.format,
      });
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
