import { beforeAll, expect, it } from "vitest";
import type { Node } from "web-tree-sitter";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { decodeJavaScriptLiteral } from "./javascriptLiteral";
import { withJavaScriptTree } from "./javascriptParser";
import { prepareEmbedProjection } from "./sourceTree";
import { configureTreeSitterAssets } from "./treeSitterRuntime";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

function literalCursor(
  value: NonNullable<ReturnType<typeof decodeJavaScriptLiteral>>,
  rawLength: number,
) {
  return prepareEmbedProjection({
    kind: "embed",
    span: { start: 0, end: rawLength },
    content: { language: "javascript", text: value.text, segments: [] },
    projection: value.projection,
    origin: { language: "javascript", construct: "literal", attributes: {} },
  })!();
}

const forms = [
  { name: "single quotes", prefix: "'", suffix: "'", mode: "cooked" },
  { name: "double quotes", prefix: '"', suffix: '"', mode: "cooked" },
  { name: "template", prefix: "`", suffix: "`", mode: "cooked" },
  { name: "String.raw", prefix: "String.raw`", suffix: "`", mode: "raw" },
] as const;

type LiteralForm = (typeof forms)[number];

function literalSource(form: LiteralForm, content: string): string {
  return form.prefix + content + form.suffix;
}

function evaluate(source: string): string {
  // eslint-disable-next-line @typescript-eslint/no-implied-eval -- Use the JS engine as the oracle for fixed literal fixtures.
  const run = Function('"use strict"; return ' + source) as () => unknown;
  const value = run();
  if (typeof value !== "string") throw new Error("Expected a string");
  return value;
}

function withLiteral<T>(
  form: LiteralForm,
  content: string,
  check: (node: Node) => T,
): Promise<T> {
  return withJavaScriptTree(literalSource(form, content), (root) => {
    expect(root.hasError).toBe(false);
    const expression = root.firstNamedChild!.firstNamedChild!;
    const literal =
      form.mode === "raw"
        ? expression.childForFieldName("arguments")!
        : expression;
    expect(literal.type).toBe(
      form.suffix === "`" ? "template_string" : "string",
    );
    return check(literal);
  });
}

const cookedEscapes = [
  ...[
    "n",
    "t",
    "r",
    "b",
    "f",
    "v",
    "0",
    "xAf",
    "u0041",
    "uD800",
    "uDC00",
    "u{0}",
    "u{000041}",
    "u{1F600}",
    "u{10FFFF}",
    "'",
    '"',
    "\\",
    "`",
    "$",
    "{",
    "q",
    "\n",
    "\r",
    "\r\n",
    "\u2028",
    "\u2029",
  ].map((escape) => "\\" + escape),
  "\\${name}",
];

const invalidCookedEscapes = [
  "\\01",
  "\\08",
  "\\09",
  ..."123456789".split("").map((digit) => "\\" + digit),
  "\\u{110000}",
];

const grammarRejectedEscapes = [
  "\\x",
  "\\xZ",
  "\\u",
  "\\u12",
  "\\uZZZZ",
  "\\u{}",
  "\\u{Z}",
];

it.each(
  forms.flatMap((form) =>
    (form.mode === "raw"
      ? [...cookedEscapes, ...invalidCookedEscapes]
      : cookedEscapes
    ).map((escape) => ({
      form,
      spelling: JSON.stringify(escape),
      content: "a" + escape + "z",
    })),
  ),
)("$form.name decodes $spelling like JavaScript", async ({ form, content }) => {
  const expected = evaluate(literalSource(form, content));
  await expect(
    withLiteral(
      form,
      content,
      (node) => decodeJavaScriptLiteral(node, form.mode)?.text,
    ),
  ).resolves.toBe(expected);
});

it.each(
  forms
    .filter((form) => form.mode === "cooked")
    .flatMap((form) =>
      invalidCookedEscapes.map((escape) => ({ form, escape })),
    ),
)(
  "$form.name rejects $escape like strict JavaScript",
  async ({ form, escape }) => {
    const content = "a" + escape + "z";
    expect(() => evaluate(literalSource(form, content))).toThrow(SyntaxError);
    await expect(
      withLiteral(form, content, (node) =>
        decodeJavaScriptLiteral(node, "cooked"),
      ),
    ).resolves.toBeNull();
  },
);

it.each(
  forms.flatMap((form) =>
    grammarRejectedEscapes.map((escape) => ({ form, escape })),
  ),
)(
  "$form.name has a site grammar error for $escape",
  async ({ form, escape }) => {
    const content = "a" + escape + "z";
    const source = literalSource(form, content);
    if (form.mode === "raw") {
      expect(evaluate(source)).toBe(content);
    } else {
      expect(() => evaluate(source)).toThrow(SyntaxError);
    }
    await withJavaScriptTree(
      `tools.exec_command({ cmd: ${source} })`,
      (root) => {
        const site = root.firstNamedChild!.firstNamedChild!;
        expect(site.type).toBe("call_expression");
        // An errored site never reaches literal decoding.
        expect(site.hasError).toBe(true);
      },
    );
  },
);

it.each(forms)("decodes an empty literal in $name", async (form) => {
  await expect(
    withLiteral(form, "", (node) => decodeJavaScriptLiteral(node, form.mode)),
  ).resolves.toEqual({
    text: "",
    projection: { points: [{ child: 0, parent: 0 }] },
  });
});

const projectionCases = [
  {
    name: "mixed-width escapes and continuation absorption",
    form: forms[1],
    content: "a\\n\\x42\\\r\nc\\u0044",
    offsets: [0, 1, 3, 7, 11, 17],
  },
  {
    name: "leading and trailing continuations",
    form: forms[2],
    content: "\\\u2028ab\\\u2029",
    offsets: [0, 3, 6],
  },
  {
    name: "an astral code-point escape",
    form: forms[2],
    content: "a\\u{1F600}z",
    offsets: [0, 1, null, 10, 11],
  },
  {
    name: "separate escaped surrogate halves",
    form: forms[1],
    content: "a\\uD83D\\uDE00z",
    offsets: [0, 1, 7, 13, 14],
  },
  {
    name: "cooked template CRLF and CR",
    form: forms[2],
    content: "a\r\nb\rc",
    offsets: [0, 1, 3, 4, 5, 6],
  },
  {
    name: "raw template CRLF, CR and escaped CRLF",
    form: forms[3],
    content: "a\r\nb\rc\\\r\nz",
    offsets: [0, 1, 3, 4, 5, 6, 7, 9, 10],
  },
  {
    name: "raw escape characters",
    form: forms[3],
    content: "a\\x42z",
    offsets: [0, 1, 2, 3, 4, 5, 6],
  },
];

it.each(projectionCases)(
  "projects every boundary for $name",
  async ({ form, content, offsets }) => {
    await withLiteral(form, content, (node) => {
      const value = decodeJavaScriptLiteral(node, form.mode)!;
      expect(value.text).toBe(evaluate(literalSource(form, content)));
      const project = literalCursor(value, content.length);
      expect(
        Array.from({ length: value.text.length + 1 }, (_, offset) =>
          project(offset),
        ),
      ).toEqual(offsets);
      expect(value.projection.points.at(-1)?.parent).toBe(content.length);
    });
  },
);

it("rejects template substitutions at the literal boundary", async () => {
  await withLiteral(forms[2], "a${value}z", (node) => {
    expect(decodeJavaScriptLiteral(node, "cooked")).toBeNull();
  });
});

it.each(["\n", "\r"] as const)(
  "rejects raw line terminator %j even when the grammar reports no error",
  async (lineEnd) => {
    for (const form of [forms[0], forms[1]]) {
      const content = "bad" + lineEnd;
      expect(() => evaluate(literalSource(form, content))).toThrow(SyntaxError);
      await expect(
        withLiteral(form, content, (node) =>
          decodeJavaScriptLiteral(node, "cooked"),
        ),
      ).resolves.toBeNull();
    }
  },
);

it.each([
  ["\r", "\n"],
  ["\r", "\u2028"],
  ["\r", "\u2029"],
  ["?", "\n"],
  ["?", "\u2028"],
  ["?", "\u2029"],
] as const)(
  "lexes a grouped escape followed by %j %j",
  async (first, second) => {
    const content = "a\\" + first + second + "b";
    for (const form of forms) {
      const literal = literalSource(form, content);
      if (first === "?" && second === "\n" && form.suffix !== "`") {
        expect(() => evaluate(literal)).toThrow(SyntaxError);
        await expect(
          withLiteral(form, content, (node) =>
            decodeJavaScriptLiteral(node, form.mode),
          ),
        ).resolves.toBeNull();
        continue;
      }
      await withLiteral(form, content, (node) => {
        const decoded = decodeJavaScriptLiteral(node, form.mode)!;
        expect(decoded.text).toBe(evaluate(literal));
        if (form.mode === "raw") return;
        const project = literalCursor(decoded, content.length);
        if (first === "?") {
          expect(project(2)).toBe(3);
          expect(project(3)).toBe(4);
        } else if (second !== "\n") {
          expect(project(2)).toBe(4);
        } else {
          expect(decoded.text).toBe("ab");
          expect(project(2)).toBe(5);
        }
      });
    }
  },
);
