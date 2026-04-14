import type { PatchHunk } from "../components/ToolCall";

/** A single operation in a diff's operation stream. */
type Op =
  | { type: "gap"; count: number } // Unchanged lines between hunks (content unknown)
  | { type: "ctx"; content: string } // Context line within a hunk (content known)
  | { type: "del"; content: string } // Line deleted from old file
  | { type: "ins"; content: string }; // Line inserted into new file

/** Convert a PatchHunk[] to a sparse operation stream. */
function hunksToOps(hunks: PatchHunk[]): Op[] {
  const ops: Op[] = [];
  let oldLine = 1; // current position in old file (1-indexed)

  for (const hunk of hunks) {
    // Gap before this hunk
    const gap = hunk.oldStart - oldLine;
    if (gap > 0) ops.push({ type: "gap", count: gap });

    // Hunk content
    for (const line of hunk.lines) {
      const prefix = line[0];
      const content = line.slice(1);
      if (prefix === " ") ops.push({ type: "ctx", content });
      else if (prefix === "-") ops.push({ type: "del", content });
      else if (prefix === "+") ops.push({ type: "ins", content });
    }

    oldLine = hunk.oldStart + hunk.oldLines;
  }

  // No trailing gap needed — implicit "retain to end of file"
  return ops;
}

/**
 * Walk two operation streams aligned on the intermediate file and compose
 * them into a single stream representing the net effect (old → new).
 */
function composeOps(ops1: Op[], ops2: Op[]): Op[] {
  const result: Op[] = [];
  let i1 = 0,
    i2 = 0;
  let buf1: Op | null = null; // put-back buffer for ops1 (partial gap)
  let buf2: Op | null = null; // put-back buffer for ops2 (partial gap)

  function emit(op: Op) {
    // Merge adjacent gaps
    const last = result.length > 0 ? result[result.length - 1] : null;
    if (op.type === "gap" && last?.type === "gap") {
      last.count += op.count;
    } else {
      result.push(op);
    }
  }

  // Take next intermediate-PRODUCING op from ops1.
  // Del ops don't produce intermediate — emit them as side-effects and skip.
  function takeProducer(): Op | null {
    for (;;) {
      let op: Op;
      if (buf1) {
        op = buf1;
        buf1 = null;
      } else if (i1 < ops1.length) {
        op = ops1[i1++]!;
      } else {
        return null;
      }

      if (op.type === "del") {
        emit(op); // pass through to composed output
        continue; // get the next op
      }
      return op; // gap, ctx, or ins — produces intermediate
    }
  }

  // Take next intermediate-CONSUMING op from ops2.
  // Ins ops don't consume intermediate — emit them as side-effects and skip.
  function takeConsumer(): Op | null {
    for (;;) {
      let op: Op;
      if (buf2) {
        op = buf2;
        buf2 = null;
      } else if (i2 < ops2.length) {
        op = ops2[i2++]!;
      } else {
        return null;
      }

      if (op.type === "ins") {
        emit(op); // pass through to composed output
        continue;
      }
      return op; // gap, ctx, or del — consumes intermediate
    }
  }

  for (;;) {
    const p = takeProducer();
    const c = takeConsumer();

    if (p === null && c === null) break;

    // --- One side exhausted (implicit trailing retain) ---

    if (p === null) {
      // ops1 exhausted → implicit retain. ops2 continues.
      if (c!.type === "gap") emit({ type: "gap", count: c!.count });
      else if (c!.type === "ctx") emit({ type: "ctx", content: c!.content });
      else emit({ type: "del", content: c!.content }); // del
      continue;
    }

    if (c === null) {
      // ops2 exhausted → implicit retain. ops1 continues.
      if (p.type === "ins") {
        emit({ type: "ins", content: p.content });
        continue;
      }
      // gap or ctx from ops1 with implicit retain from ops2 = trailing retain.
      // Put back this op and drain any remaining del/ins from ops1.
      buf1 = p;
      for (;;) {
        const pp = takeProducer();
        if (pp === null) break;
        if (pp.type === "ins") emit({ type: "ins", content: pp.content });
        // gap/ctx are trailing retains — discard (implicit in output)
        // Note: takeProducer already emits del ops as side effects
      }
      break;
    }

    // --- Both sides have ops: pair them ---

    const pSize = p.type === "gap" ? p.count : 1;
    const cSize = c.type === "gap" ? c.count : 1;
    const n = Math.min(pSize, cSize);

    // Put back remainders for gap ops
    if (p.type === "gap" && pSize > n) buf1 = { type: "gap", count: pSize - n };
    if (c.type === "gap" && cSize > n) buf2 = { type: "gap", count: cSize - n };

    // Apply composition table
    const pKind = p.type; // 'gap' | 'ctx' | 'ins'
    const cKind = c.type; // 'gap' | 'ctx' | 'del'

    if (pKind === "gap" && cKind === "gap") {
      emit({ type: "gap", count: n });
    } else if (pKind === "gap" && cKind === "ctx") {
      emit({ type: "ctx", content: c.content });
    } else if (pKind === "gap" && cKind === "del") {
      emit({ type: "del", content: c.content });
    } else if (pKind === "ctx" && cKind === "gap") {
      emit({ type: "ctx", content: p.content });
    } else if (pKind === "ctx" && cKind === "ctx") {
      emit({ type: "ctx", content: p.content }); // prefer original side
    } else if (pKind === "ctx" && cKind === "del") {
      emit({ type: "del", content: p.content }); // original content
    } else if (pKind === "ins" && cKind === "gap") {
      emit({ type: "ins", content: p.content });
    } else if (pKind === "ins" && cKind === "ctx") {
      emit({ type: "ins", content: p.content });
    } else if (pKind === "ins" && cKind === "del") {
      // Cancel out: inserted then deleted = no net effect
    }
  }

  return result;
}

interface AnnotatedOp {
  op: Op;
  oldLine: number;
  newLine: number;
}

/** Convert a composed operation stream back to PatchHunk[]. */
function opsToHunks(ops: Op[], contextSize = 3): PatchHunk[] {
  // Step 1: Annotate with positions
  const annotated: AnnotatedOp[] = [];
  let oldLine = 1,
    newLine = 1;

  for (const op of ops) {
    annotated.push({ op, oldLine, newLine });
    if (op.type === "gap") {
      oldLine += op.count;
      newLine += op.count;
    } else if (op.type === "ctx") {
      oldLine++;
      newLine++;
    } else if (op.type === "del") {
      oldLine++;
    } else {
      // op.type === "ins"
      newLine++;
    }
  }

  // Step 2: Find indices of all change ops (del/ins)
  const changeIndices: number[] = [];
  for (let i = 0; i < annotated.length; i++) {
    const t = annotated[i]!.op.type;
    if (t === "del" || t === "ins") changeIndices.push(i);
  }

  if (changeIndices.length === 0) return [];

  // Step 3: Build hunk ranges
  type Range = { start: number; end: number };
  const ranges: Range[] = [];

  for (const ci of changeIndices) {
    // Expand backward for context (only over ctx ops, stop at gap)
    let start = ci;
    let ctxBefore = 0;
    for (let j = ci - 1; j >= 0 && ctxBefore < contextSize; j--) {
      if (annotated[j]!.op.type === "ctx") {
        start = j;
        ctxBefore++;
      } else break; // gap or another change — stop
    }

    // Expand forward for context (only ctx ops)
    let end = ci;
    let ctxAfter = 0;
    for (let j = ci + 1; j < annotated.length && ctxAfter < contextSize; j++) {
      if (annotated[j]!.op.type === "ctx") {
        end = j;
        ctxAfter++;
      } else break; // gap or change — stop
    }

    // Merge with previous range if overlapping or adjacent
    if (ranges.length > 0 && start <= ranges[ranges.length - 1]!.end + 1) {
      ranges[ranges.length - 1]!.end = Math.max(
        ranges[ranges.length - 1]!.end,
        end,
      );
    } else {
      ranges.push({ start, end });
    }
  }

  // Step 4: Emit hunks
  const hunks: PatchHunk[] = [];

  for (const range of ranges) {
    const lines: string[] = [];
    let oldLines = 0,
      newLines = 0;
    const oldStart = annotated[range.start]!.oldLine;
    const newStart = annotated[range.start]!.newLine;

    for (let i = range.start; i <= range.end; i++) {
      const { op } = annotated[i]!;
      if (op.type === "ctx") {
        lines.push(" " + op.content);
        oldLines++;
        newLines++;
      } else if (op.type === "del") {
        lines.push("-" + op.content);
        oldLines++;
      } else if (op.type === "ins") {
        lines.push("+" + op.content);
        newLines++;
      }
      // gap ops should not appear within a hunk range
    }

    hunks.push({ oldStart, oldLines, newStart, newLines, lines });
  }

  return hunks;
}

/**
 * Compose two sequential PatchHunk[] arrays (S0→S1 and S1→S2) into a single
 * cumulative diff (S0→S2), handling overlaps and cancellations.
 *
 * Composable: `edits.reduce(composeHunks, [])` for N sequential edits.
 */
export function composeHunks(
  hunks1: PatchHunk[],
  hunks2: PatchHunk[],
  contextSize = 3,
): PatchHunk[] {
  if (hunks1.length === 0) return hunks2;
  if (hunks2.length === 0) return hunks1;

  const ops1 = hunksToOps(hunks1);
  const ops2 = hunksToOps(hunks2);
  const composed = composeOps(ops1, ops2);
  return opsToHunks(composed, contextSize);
}

// Export internals for unit testing
export { hunksToOps, composeOps, opsToHunks };
export type { Op };
