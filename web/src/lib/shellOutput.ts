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
export type RowSource =
  | { kind: "file"; origin: FileOrigin; range: ReadRange }
  | { kind: "unpositioned"; language: string };
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

export function rowsLanguage(source: RowSource): string {
  return source.kind === "file"
    ? langFromPath(source.origin.filePath) || "text"
    : source.language;
}

export function rowsLanguageMismatch(
  first: string,
  next: string,
): { ok: false; reason: string } | null {
  return first === next
    ? null
    : {
        ok: false,
        reason: `concatenated rows have different languages: ${first}, ${next}`,
      };
}

const rowLabels = {
  file: "file rows",
  nl: "nl-numbered rows",
  grep: "search rows",
} as const;

export function shellOutputView(
  output: readonly OutputSegment[],
): ViewResult<ShellOutputView> {
  const first = output[0];
  if (output.length === 1) {
    if (first?.kind === "diff") return { ok: true, value: { kind: "diff" } };
    if (
      first?.kind === "rows" &&
      first.source.kind === "file" &&
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
  let index = 0;
  while (index < output.length) {
    const segment = output[index++]!;
    const id = String(blocks.length);
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
        const language = rowsLanguage(segment.source);
        const numbering = segment.numbering;
        const rowKind = numbering?.kind ?? "file";
        let next = output[index];
        const single = next?.kind !== "rows";
        while (next?.kind === "rows") {
          const nextKind = next.numbering?.kind ?? "file";
          if (rowKind !== nextKind) {
            return {
              ok: false,
              reason: `${rowLabels[rowKind]} cannot be concatenated with ${rowLabels[nextKind]}`,
            };
          }
          if (rowKind === "nl") {
            return {
              ok: false,
              reason:
                "nl-numbered output cannot be concatenated with other nl-numbered output",
            };
          }
          if (rowKind === "grep") {
            return {
              ok: false,
              reason:
                "search output cannot be concatenated with other search output",
            };
          }
          const mismatch = rowsLanguageMismatch(
            language,
            rowsLanguage(next.source),
          );
          if (mismatch) return mismatch;
          next = output[++index];
        }
        if (next && next.kind !== "literal") return ambiguous;
        const content: OutputFormat = {
          kind: "content",
          language,
        };
        const location: Extract<
          OutputBlockPlan["location"],
          { kind: "from-cursor" }
        > = {
          kind: "from-cursor",
          end: next
            ? { kind: "before-block", blockId: String(blocks.length + 1) }
            : { kind: "end-of-output", requiresComplete: true },
        };
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
        if (single && !numbering && segment.source.kind === "file") {
          block.document = {
            filePath: segment.source.origin.filePath,
            preview: !next,
          };
        }
        blocks.push(block);
        break;
      }
    }
  }
  return blocks.length
    ? { ok: true, value: { version: 1, blocks } }
    : ambiguous;
}
