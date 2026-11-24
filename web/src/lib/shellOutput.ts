import { langFromPath } from "../highlight";
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

export type FileOrigin = { kind: "worktree" | "git-object"; filePath: string };
export type RowSource = { kind: "file"; origin: FileOrigin; range: ReadRange };
export type NumberingLayer =
  | { kind: "nl"; width: number; separator: string }
  | { kind: "grep"; context: boolean };
export type RowsSegment = {
  kind: "rows";
  source: RowSource;
  numbering: NumberingLayer | null;
};
export type OutputSegment =
  | RowsSegment
  | { kind: "diff" }
  | { kind: "literal"; text: string }
  | { kind: "summary-line" };
export type ShellOutputView =
  | { kind: "plan"; plan: OutputPlan; search: boolean }
  | { kind: "git-object"; filePath: string }
  | { kind: "diff" };

type ViewResult<T> = { ok: true; value: T } | { ok: false; reason: string };

function rowsLanguage(source: RowSource): string {
  return langFromPath(source.origin.filePath) || "text";
}

export function shellOutputView(
  output: readonly OutputSegment[],
): ViewResult<ShellOutputView> {
  const first = output[0];
  if (output.length === 1) {
    if (first?.kind === "diff") return { ok: true, value: { kind: "diff" } };
    if (
      first?.kind === "rows" &&
      first.source.origin.kind === "git-object" &&
      first.numbering === null
    ) {
      return {
        ok: true,
        value: { kind: "git-object", filePath: first.source.origin.filePath },
      };
    }
  }
  const plan = derivePlan(output);
  return plan.ok
    ? {
        ok: true,
        value: {
          kind: "plan",
          plan: plan.value,
          search: output.some(
            (s) => s.kind === "rows" && s.numbering?.kind === "grep",
          ),
        },
      }
    : plan;
}

export function derivePlan(
  output: readonly OutputSegment[],
): ViewResult<OutputPlan> {
  if (!output.every((segment) => segment.kind !== "diff"))
    throw new Error("Diff output requires its own view");

  const ambiguous = {
    ok: false,
    reason: "shell output steps do not define an unambiguous output plan",
  } as const;
  const blocks: OutputBlockPlan[] = [];
  const literalTexts = new Set<string>();
  const shellFormat = { kind: "content", language: "shell-output" } as const;
  for (const [index, segment] of output.entries()) {
    const id = String(index);
    switch (segment.kind) {
      case "literal":
        if (literalTexts.has(segment.text)) return ambiguous;
        literalTexts.add(segment.text);
        blocks.push({
          id,
          format: shellFormat,
          location: {
            kind: "unique-literal",
            text: segment.text,
            include: "self",
          },
        });
        break;
      case "summary-line":
        blocks.push({
          id,
          format: shellFormat,
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "non-empty",
          },
        });
        break;
      case "rows": {
        const next = output[index + 1];
        if (next && next.kind !== "literal") return ambiguous;
        const { filePath } = segment.source.origin;
        const content: OutputFormat = {
          kind: "content",
          language: rowsLanguage(segment.source),
        };
        const location: Extract<
          OutputBlockPlan["location"],
          { kind: "from-cursor" }
        > = {
          kind: "from-cursor",
          end: next
            ? { kind: "before-block", blockId: String(index + 1) }
            : { kind: "end-of-output", requiresComplete: true },
        };
        const numbering = segment.numbering;
        let format: OutputFormat = content;
        let validator: SpanValidatorId | undefined;
        if (numbering?.kind === "nl") {
          const { width, separator } = numbering;
          format = {
            kind: "nl-line-number-prefixed",
            width,
            separator,
            format: content,
          };
        } else if (numbering?.kind === "grep") {
          format = {
            kind: "individual-lines",
            format: { kind: "line-number-prefixed", format: content },
          };
          validator = numbering.context
            ? "line-number-prefixed-with-context"
            : "colon-line-number-prefixed";
        } else {
          validator = "non-empty";
        }
        if (validator) location.validator = validator;
        const block: OutputBlockPlan = { id, format, location };
        if (!numbering) block.document = { filePath, preview: !next };
        blocks.push(block);
        break;
      }
    }
  }
  return blocks.length
    ? { ok: true, value: { version: 1, blocks } }
    : ambiguous;
}
