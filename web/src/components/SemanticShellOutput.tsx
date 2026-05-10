import { h } from "preact";
import type {
  OutputPlan,
  OutputBlockPlan,
  SegmentedOutputPiece,
} from "../lib/outputPlan";
import { OutputPlanView, hasStructuredOutput } from "./OutputPlanView";

// nl is excluded: its output carries line-number prefixes ("1\t…") that are
// not part of the source file, so rendering as a file preview would be wrong.
const FILE_PREVIEW_PRODUCERS = new Set(["sed", "cat", "head", "tail"]);

function canRenderStructuredFilePreview(
  piece: Extract<SegmentedOutputPiece, { kind: "structured" }>,
  block: OutputBlockPlan | undefined,
  stdoutLength: number,
): boolean {
  if (!piece.source?.filePath) return false;
  if (!block) return false;

  if (block.location.kind === "whole-output") {
    return piece.start === 0 && piece.end === stdoutLength;
  }

  if (
    piece.source.producerName !== undefined &&
    FILE_PREVIEW_PRODUCERS.has(piece.source.producerName) &&
    block.location.kind === "from-cursor" &&
    block.location.end.kind === "end-of-output"
  ) {
    return piece.end === stdoutLength;
  }

  return false;
}

export function hasSemanticShellOutput(
  stdout: string,
  outputPlan: OutputPlan,
): boolean {
  return hasStructuredOutput(stdout, outputPlan);
}

export function SemanticShellOutput({
  stdout,
  outputPlan,
}: {
  stdout: string;
  outputPlan: OutputPlan;
}): h.JSX.Element | null {
  const hasSearchBlock = outputPlan.blocks.some(
    (block) => block.source?.producerName === "rg",
  );
  return (
    <OutputPlanView
      stdout={stdout}
      outputPlan={outputPlan}
      className="semantic-shell-output"
      testId={
        hasSearchBlock
          ? "semantic-shell-output-search"
          : "semantic-shell-output"
      }
      blockTestIdPrefix="semantic-shell-block-"
      toolbarClassName="semantic-shell-output-toolbar"
      rawClassName="tool-result semantic-shell-raw"
      structuredPieceClassName="semantic-shell-structured-piece"
      linePrefixTestId="semantic-shell-line-prefix"
      canRenderFilePreview={({ piece, block, stdoutLength }) =>
        canRenderStructuredFilePreview(piece, block, stdoutLength)
      }
    />
  );
}
