import { h } from "preact";
import type { OutputPlan } from "../lib/outputPlan";
import { OutputPlanView, hasStructuredOutput } from "./OutputPlanView";

export function hasSemanticShellOutput(
  stdout: string,
  outputPlan: OutputPlan,
): boolean {
  return hasStructuredOutput(stdout, outputPlan);
}

export function SemanticShellOutput({
  stdout,
  outputPlan,
  search,
}: {
  stdout: string;
  outputPlan: OutputPlan;
  search: boolean;
}): h.JSX.Element | null {
  return (
    <OutputPlanView
      stdout={stdout}
      outputPlan={outputPlan}
      className="semantic-shell-output"
      testId={search ? "semantic-shell-output-search" : "semantic-shell-output"}
      blockTestIdPrefix="semantic-shell-block-"
      toolbarClassName="semantic-shell-output-toolbar"
      rawClassName="tool-result semantic-shell-raw"
      structuredPieceClassName="semantic-shell-structured-piece"
      linePrefixTestId="semantic-shell-line-prefix"
    />
  );
}
