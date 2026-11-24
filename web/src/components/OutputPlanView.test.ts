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

  it.each([true, false])(
    "renders Markdown controls when a document is present: %s",
    (hasDocument) => {
      const stdout = "# Header\n\nBody\n";
      const outputPlan: OutputPlan = {
        version: 1,
        blocks: [
          {
            id: "0",
            ...(hasDocument
              ? { document: { filePath: "a.md", preview: false } }
              : {}),
            format: { kind: "content", language: "markdown" },
            location: {
              kind: "from-cursor",
              end: { kind: "end-of-output", requiresComplete: true },
              validator: "non-empty",
            },
          },
        ],
      };

      const html = renderOutputPlanView(stdout, outputPlan);
      expect(html).toContain('data-testid="test-output-plan"');
      expect(html).toContain('data-testid="test-block-0"');
      expect(html).toContain("Header");
      if (hasDocument) {
        expect(html).toContain("<h1");
        expect(html).toContain("text-content");
        expect(html).toContain('title="Show source"');
      } else {
        expect(html).not.toContain("text-content");
        expect(html).not.toContain('title="Show source"');
        expect(html).not.toContain('title="Show rendered"');
      }
    },
  );

  it("renders colon-prefixed lines with line prefix marker", () => {
    const stdout = "12:const x = 1;\n34:const y = 2;\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "typescript" },
            },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
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

  it.each([
    ["/repo/README.md", "markdown", "     1\t# Title\n     2\t\n"],
    ["/repo/x.svg", "xml", "     1\t<svg></svg>\n"],
  ])(
    "keeps numbered %s on the code rendering path",
    (_filePath, language, stdout) => {
      const outputPlan: OutputPlan = {
        version: 1,
        blocks: [
          {
            id: "0",
            format: {
              kind: "nl-line-number-prefixed",
              width: 6,
              separator: "\t",
              format: { kind: "content", language },
            },
            location: {
              kind: "from-cursor",
              end: { kind: "end-of-output", requiresComplete: true },
            },
          },
        ],
      };
      const html = renderToString(
        h(OutputPlanView, {
          stdout,
          outputPlan,
        }),
      );
      expect(html).toContain(
        'data-testid="output-line-prefix" class="line-number">     1\t</span>',
      );
      expect(html).not.toContain('alt="SVG preview"');
      expect(html).not.toContain("text-content");
      expect(html).not.toContain("<h1");
      if (language === "markdown") {
        expect(html).toContain(
          'data-testid="output-line-prefix" class="line-number">     2\t</span>',
        );
        expect(html).toContain("# Title");
      }
    },
  );

  it("renders match and context prefixes and a search group separator", () => {
    const stdout =
      "60-left\rright\u2028above\u2029below\r\n61:b: c\n--\n70-d\r";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "text" },
            },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "line-number-prefixed-with-context",
          },
        },
      ],
    };

    const html = renderOutputPlanView(stdout, outputPlan);
    for (const prefix of ["60-", "61:", "70-"]) {
      expect(html).toContain(
        `data-testid="output-line-prefix" class="line-number">${prefix}</span>`,
      );
    }
    expect(hasStructuredOutput(stdout, outputPlan)).toBe(true);
    expect(html).toContain("</span>left\rright\u2028above\u2029below\r\n");
    expect(html).toContain("</span>b: c\n");
    expect(html).toContain("</span>d\r");
    expect(
      html.match(/<span class="search-group-separator">--<\/span>/g),
    ).toHaveLength(1);
  });

  it.each([true, false])(
    "uses SVG preview when the document enables it: %s",
    (preview) => {
      const stdout = '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n';
      const outputPlan: OutputPlan = {
        version: 1,
        blocks: [
          {
            id: "0",
            document: { filePath: "/tmp/cydo-render.svg", preview },
            format: { kind: "content", language: "xml" },
            location: {
              kind: "from-cursor",
              end: { kind: "end-of-output", requiresComplete: true },
              validator: "non-empty",
            },
          },
        ],
      };

      const html = renderOutputPlanView(stdout, outputPlan);
      expect(html).toContain('data-testid="test-block-0"');
      if (preview) expect(html).toContain('alt="SVG preview"');
      else expect(html).not.toContain('alt="SVG preview"');
    },
  );
});
