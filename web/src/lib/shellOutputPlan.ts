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
