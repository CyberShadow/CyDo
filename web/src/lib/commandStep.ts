import type {
  OutputPlan,
  OutputBlockPlan,
  OutputFormat,
  SpanValidatorId,
} from "./outputPlan";

export type ReadRange =
  | { type: "all" }
  | { type: "lines"; start: number; end: number }
  | { type: "head"; count: number }
  | { type: "tail"; startLine: number }
  | { type: "tail-count"; count: number };

export type OutputShape =
  // Variable-length content from one logical source.
  | { kind: "content"; format: OutputFormat; validator?: SpanValidatorId }
  // Predictable line count (e.g. `ls -l <one-file>`).
  | {
      kind: "fixed-lines";
      count: number;
      format: OutputFormat;
      validator?: SpanValidatorId;
    }
  // Literal text (printf '...'), used as a unique anchor.
  | { kind: "literal"; text: string; format: OutputFormat }
  // Step produces no stdout (write-file). Skipped by derivePlan.
  | { kind: "none" }
  // Unstructured stdout we cannot anchor. derivePlan returns undefined when present.
  | { kind: "unknown" };

export type CommandStep =
  | {
      kind: "write-file";
      order: number;
      targetPath: string;
      contentNodeId: string;
      outputShape: OutputShape;
      blockId?: string;
    }
  | {
      kind: "execute-script";
      order: number;
      commandName: string;
      language: string;
      contentNodeId: string;
      outputShape: OutputShape;
      blockId?: string;
    }
  | {
      kind: "search";
      order: number;
      commandName: "rg";
      pattern: string;
      filePath: string;
      outputShape: OutputShape;
      blockId?: string;
    }
  | {
      kind: "read-file";
      order: number;
      commandName: "sed" | "cat" | "head" | "tail" | "nl";
      filePath: string;
      range?: ReadRange;
      outputShape: OutputShape;
      blockId?: string;
    }
  | {
      kind: "plain-output";
      order: number;
      commandName: string;
      filePath?: string;
      outputShape: OutputShape;
      blockId?: string;
    };

function stepCommandName(step: CommandStep): string | undefined {
  return step.kind === "write-file" ? undefined : step.commandName;
}

function stepFilePath(step: CommandStep): string | undefined {
  if (step.kind === "search" || step.kind === "read-file") return step.filePath;
  if (step.kind === "plain-output") return step.filePath;
  return undefined;
}

function defaultBlockId(step: CommandStep): string {
  const name = stepCommandName(step) ?? step.kind;
  return `${name}-${step.order}`;
}

export function derivePlan(steps: CommandStep[]): OutputPlan | undefined {
  // Rule 1: reject if any step has unknown shape
  if (steps.some((s) => s.outputShape.kind === "unknown")) return undefined;

  // Rule 2: validate literal uniqueness
  const literalTexts: string[] = [];
  for (const s of steps) {
    if (s.outputShape.kind === "literal") literalTexts.push(s.outputShape.text);
  }
  if (new Set(literalTexts).size !== literalTexts.length) return undefined;

  // Rule 3: walk steps and emit blocks
  const blocks: OutputBlockPlan[] = [];

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i]!;
    const shape = step.outputShape;

    if (shape.kind === "none") continue;

    const blockId = step.blockId ?? defaultBlockId(step);
    const commandName = stepCommandName(step);
    const filePath = stepFilePath(step);

    const source: OutputBlockPlan["source"] = { stepIndex: step.order };
    if (commandName !== undefined) source.producerName = commandName;
    if (filePath !== undefined) source.filePath = filePath;

    if (shape.kind === "literal") {
      blocks.push({
        id: blockId,
        source,
        format: shape.format,
        location: { kind: "unique-literal", text: shape.text, include: "self" },
      });
      continue;
    }

    if (shape.kind === "fixed-lines") {
      const location: OutputBlockPlan["location"] = shape.validator
        ? {
            kind: "from-cursor",
            end: { kind: "line-count", count: shape.count },
            validator: shape.validator,
          }
        : {
            kind: "from-cursor",
            end: { kind: "line-count", count: shape.count },
          };
      blocks.push({ id: blockId, source, format: shape.format, location });
      continue;
    }

    // Only "content" remains; "unknown" was already rejected by rule 1
    if (shape.kind !== "content") return undefined;

    // shape.kind === "content": choose end anchor
    const subsequent = steps
      .slice(i + 1)
      .find((s) => s.outputShape.kind !== "none");

    let location: OutputBlockPlan["location"];
    if (!subsequent) {
      location = shape.validator
        ? {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: shape.validator,
          }
        : {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
          };
    } else if (subsequent.outputShape.kind === "literal") {
      const nextId = subsequent.blockId ?? defaultBlockId(subsequent);
      location = shape.validator
        ? {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: nextId },
            validator: shape.validator,
          }
        : {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: nextId },
          };
    } else {
      // content followed by content, fixed-lines, or whole-output — reject
      return undefined;
    }

    blocks.push({ id: blockId, source, format: shape.format, location });
  }

  return blocks.length === 0 ? undefined : { version: 1, blocks };
}
