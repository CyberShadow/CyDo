import { describe, it, expect } from "vitest";
import { derivePlan } from "./commandStep";
import type { CommandStep } from "./commandStep";

const FMT_MD = { kind: "content" as const, language: "markdown" };
const FMT_SHELL = { kind: "content" as const, language: "shell-output" };

function contentStep(order: number): CommandStep {
  return {
    kind: "read-file",
    order,
    commandName: "sed",
    filePath: `/tmp/file${order}.md`,
    outputShape: {
      kind: "content",
      format: FMT_MD,
      validator: "non-empty",
    },
  };
}

function literalStep(order: number, text: string): CommandStep {
  return {
    kind: "plain-output",
    order,
    commandName: "printf",
    outputShape: { kind: "literal", text, format: FMT_SHELL },
  };
}

function fixedLinesStep(order: number, count: number): CommandStep {
  return {
    kind: "plain-output",
    order,
    commandName: "ls",
    filePath: "/tmp/file.md",
    outputShape: {
      kind: "fixed-lines",
      count,
      format: FMT_SHELL,
      validator: "non-empty",
    },
    blockId: "listing",
  };
}

function noneStep(order: number): CommandStep {
  return {
    kind: "write-file",
    order,
    targetPath: "/tmp/out.md",
    contentNodeId: "heredoc-body",
    outputShape: { kind: "none" },
  };
}

function unknownStep(order: number): CommandStep {
  return {
    kind: "execute-script",
    order,
    commandName: "python",
    language: "python",
    contentNodeId: "heredoc-body",
    outputShape: { kind: "unknown" },
  };
}

describe("derivePlan", () => {
  it("empty input returns undefined", () => {
    expect(derivePlan([])).toBeUndefined();
  });

  it("single content step produces 1 block with from-cursor + end-of-output", () => {
    const plan = derivePlan([contentStep(0)]);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(1);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("single literal step produces 1 block with unique-literal location", () => {
    const plan = derivePlan([literalStep(0, "\n--- sep ---\n")]);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(1);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "unique-literal",
      text: "\n--- sep ---\n",
      include: "self",
    });
  });

  it("single fixed-lines step produces 1 block with from-cursor + line-count", () => {
    const plan = derivePlan([fixedLinesStep(0, 3)]);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(1);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "line-count", count: 3 },
      validator: "non-empty",
    });
  });

  it("[content, literal] produces 2 blocks; content uses before-block", () => {
    const steps = [contentStep(0), literalStep(1, "\n--- sep ---\n")];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(2);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "before-block", blockId: "printf-1" },
      validator: "non-empty",
    });
    expect(plan!.blocks[1]!.location).toEqual({
      kind: "unique-literal",
      text: "\n--- sep ---\n",
      include: "self",
    });
  });

  it("[literal, content] produces 2 blocks; content uses end-of-output", () => {
    const steps = [literalStep(0, "\n--- sep ---\n"), contentStep(1)];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(2);
    expect(plan!.blocks[0]!.location.kind).toBe("unique-literal");
    expect(plan!.blocks[1]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("[content, content] returns undefined (adjacent unbounded)", () => {
    expect(derivePlan([contentStep(0), contentStep(1)])).toBeUndefined();
  });

  it("[content, literal, content] produces 3 blocks (mid-list anchor pattern)", () => {
    const steps = [
      contentStep(0),
      literalStep(1, "\n--- sep ---\n"),
      contentStep(2),
    ];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(3);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "before-block", blockId: "printf-1" },
      validator: "non-empty",
    });
    expect(plan!.blocks[1]!.location.kind).toBe("unique-literal");
    expect(plan!.blocks[2]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("[fixed-lines, content] produces 2 blocks (ls + sed pattern)", () => {
    const steps = [fixedLinesStep(0, 1), contentStep(1)];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(2);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "line-count", count: 1 },
      validator: "non-empty",
    });
    expect(plan!.blocks[1]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("[content, fixed-lines] returns undefined (fixed-lines is not a literal anchor)", () => {
    expect(derivePlan([contentStep(0), fixedLinesStep(1, 1)])).toBeUndefined();
  });

  it("duplicate literal text across two steps returns undefined", () => {
    const steps = [
      contentStep(0),
      literalStep(1, "\n--- sep ---\n"),
      contentStep(2),
      literalStep(3, "\n--- sep ---\n"),
      contentStep(4),
    ];
    expect(derivePlan(steps)).toBeUndefined();
  });

  it("any unknown step returns undefined", () => {
    expect(derivePlan([unknownStep(0)])).toBeUndefined();
    expect(derivePlan([contentStep(0), unknownStep(1)])).toBeUndefined();
  });

  it("[none, content] produces 1 block (write-file ignored, content gets end-of-output)", () => {
    const steps = [noneStep(0), contentStep(1)];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(1);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("[none, fixed-lines, content] produces 2 blocks (heredoc-write + ls-readback)", () => {
    const steps = [noneStep(0), fixedLinesStep(1, 1), contentStep(2)];
    const plan = derivePlan(steps);
    expect(plan).toBeDefined();
    expect(plan!.blocks).toHaveLength(2);
    expect(plan!.blocks[0]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "line-count", count: 1 },
      validator: "non-empty",
    });
    expect(plan!.blocks[1]!.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("block source attribution: stepIndex, producerName, filePath present when available", () => {
    const step: CommandStep = {
      kind: "read-file",
      order: 3,
      commandName: "sed",
      filePath: "/tmp/x.md",
      outputShape: { kind: "content", format: FMT_MD },
    };
    const plan = derivePlan([step]);
    expect(plan!.blocks[0]!.source).toEqual({
      stepIndex: 3,
      producerName: "sed",
      filePath: "/tmp/x.md",
    });
  });

  it("block source attribution: filePath absent for printf-style step", () => {
    const step = literalStep(2, "\n--- sep ---\n");
    // plain-output with no filePath
    const plan = derivePlan([step]);
    expect(plan!.blocks[0]!.source).toEqual({
      stepIndex: 2,
      producerName: "printf",
    });
    expect(plan!.blocks[0]!.source).not.toHaveProperty("filePath");
  });

  it("explicit blockId is honored; absent uses commandName-order default", () => {
    const withId: CommandStep = {
      kind: "read-file",
      order: 0,
      commandName: "sed",
      filePath: "/tmp/x.md",
      outputShape: { kind: "content", format: FMT_MD },
      blockId: "sed-output",
    };
    const withoutId: CommandStep = {
      kind: "read-file",
      order: 1,
      commandName: "cat",
      filePath: "/tmp/y.md",
      outputShape: { kind: "content", format: FMT_MD },
    };
    const plan = derivePlan([withId, literalStep(1, "\n---\n"), withoutId]);
    // withId uses explicit "sed-output"
    expect(plan!.blocks[0]!.id).toBe("sed-output");
    // withoutId uses default "cat-1"
    expect(plan!.blocks[2]!.id).toBe("cat-1");
  });
});
