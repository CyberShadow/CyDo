import { describe, expect, it } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import type { OutputPlan } from "../lib/outputPlan";
import { OutputPlanView, hasStructuredOutput } from "./OutputPlanView";

function renderOutputPlanView(stdout: string, outputPlan: OutputPlan): string {
  return renderToString(
    h(OutputPlanView, {
      stdout,
      outputPlan,
      className: "test-output-plan",
      testId: "test-output-plan",
      blockTestIdPrefix: "test-block-",
    }),
  );
}

describe("OutputPlanView", () => {
  it("returns null rendering when all output falls back to raw", () => {
    const stdout = "no blocks\n";
    const outputPlan: OutputPlan = { version: 1, blocks: [] };
    expect(hasStructuredOutput(stdout, outputPlan)).toBe(false);
    const html = renderOutputPlanView(stdout, outputPlan);
    expect(html).toBe("");
  });

  it("renders markdown content in rendered mode", () => {
    const stdout = "# Header\n\nBody\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "md",
          format: { kind: "content", language: "markdown" },
          location: { kind: "whole-output", validator: "non-empty" },
        },
      ],
    };

    const html = renderOutputPlanView(stdout, outputPlan);
    expect(html).toContain('data-testid="test-output-plan"');
    expect(html).toContain('data-testid="test-block-md"');
    expect(html).toContain("<h1");
    expect(html).toContain("Header");
  });

  it("renders colon-prefixed lines with line prefix marker", () => {
    const stdout = "12:const x = 1;\n34:const y = 2;\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "rg-results",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "typescript" },
            },
          },
          location: {
            kind: "whole-output",
            validator: "colon-line-number-prefixed",
          },
        },
      ],
    };

    const html = renderOutputPlanView(stdout, outputPlan);
    expect(html).toContain('data-testid="output-line-prefix"');
    expect(html).toContain("12:");
    expect(html).toContain("34:");
  });

  it("uses preview callback when provided", () => {
    const stdout = '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n';
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "svg",
          source: {
            stepIndex: 0,
            producerName: "test",
            filePath: "/tmp/cydo-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: { kind: "whole-output", validator: "non-empty" },
        },
      ],
    };

    const html = renderToString(
      h(OutputPlanView, {
        stdout,
        outputPlan,
        canRenderFilePreview: () => true,
      }),
    );

    expect(html).toContain('alt="SVG preview"');
  });
});
