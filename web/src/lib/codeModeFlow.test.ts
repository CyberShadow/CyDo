import { beforeAll, expect, it, vi } from "vitest";
import { Node } from "web-tree-sitter";
import * as literalDecoder from "./javascriptLiteral";
import { analyzeCodeModeCell } from "./codeModeFlow";
import { withJavaScriptTree } from "./javascriptParser";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { buildFlowSourceTree } from "./contentFlow";
import { analyzeEmbedded } from "./embeddedFlow";
import * as shellParser from "./shellParser";
import type { SourceNode } from "./sourceTree";
import { buildSourceRenderPieces } from "./sourceTreeRenderPlan";
import { configureTreeSitterAssets } from "./treeSitterRuntime";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

const exec = (operand: string) =>
  `await tools.exec_command({cmd: ${operand}});`;
const echo = exec('"echo hi"');
const bound = 'const c = "echo hi"; ' + exec("c");
const applyPatch = (operand: string) => `await tools.apply_patch(${operand});`;
const patch =
  "*** Begin Patch\n*** Add File: a.txt\n+hello\\nworld\n*** End Patch";
const quotedPatch = JSON.stringify(patch);
const bindPatch = (operand: string) => `const patch = ${operand};\n`;
const patchReference = applyPatch("patch");
const patchSink = {
  kind: "program",
  language: "apply-patch",
  channel: "argv",
};

async function analyze(cell: string) {
  const flow = await analyzeEmbedded("codex-code-mode", cell);
  expect(flow).toMatchObject({ language: "javascript", text: cell });
  const tree = buildFlowSourceTree(flow!);
  const pieces = buildSourceRenderPieces(tree);
  expect(
    pieces
      .map((piece) => (piece.kind === "rich" ? piece.sourceText : piece.text))
      .join(""),
  ).toBe(cell);
  return { flow: flow!, tree, pieces };
}

it(
  "keeps a generated cell above the JavaScript spread argument limit renderable",
  { timeout: 120_000 },
  async () => {
    const commandCount = 65_000;
    const command = "python3 -c 'pass'\n".repeat(commandCount);
    const { flow, pieces } = await analyze(exec("`" + command + "`"));
    expect(flow.sources[0]?.child?.sources).toHaveLength(commandCount);
    expect(pieces).toHaveLength(2 * commandCount + 3);
    expect(pieces.filter((piece) => piece.language === "python")).toHaveLength(
      commandCount,
    );
  },
);

function embeds(node: SourceNode, prefix: number[] = []): unknown[] {
  return node.segments
    .filter((segment) => segment.kind === "embed")
    .flatMap((segment, index) => {
      const path = [...prefix, index];
      return [
        [
          path,
          segment.content.language,
          segment.presentation?.kind ?? "inline",
        ],
        ...embeds(segment.content, path),
      ];
    });
}

function expectSource(
  flow: Awaited<ReturnType<typeof analyze>>["flow"],
  raw: string,
  decoded: string,
  construct: string,
  binding: "inline" | "const",
  uses = 1,
) {
  const start = flow.text.indexOf(raw);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(flow.sources).toHaveLength(1);
  expect(flow.sources[0]).toMatchObject({
    span: { start, end: start + raw.length },
    value: { text: decoded },
    origin: { language: "javascript", construct, attributes: { binding } },
    layout: "inline",
    child: { language: "bash", text: decoded },
  });
  expect(flow.sources[0]!.sinks).toEqual(
    Array.from({ length: uses }, () => ({
      kind: "program",
      language: "bash",
      channel: "argv",
    })),
  );
}

it.each([
  ["quoted string", echo, "echo hi", "echo hi", "string-literal", "inline"],
  [
    "cooked template",
    exec("`echo\\x20hi`"),
    String.raw`echo\x20hi`,
    "echo hi",
    "template-literal",
    "inline",
  ],
  [
    "raw template",
    exec("String.raw`echo \\n`"),
    String.raw`echo \n`,
    String.raw`echo \n`,
    "string-raw",
    "inline",
  ],
  ["const reference", bound, "echo hi", "echo hi", "string-literal", "const"],
  [
    "const shorthand",
    'const cmd = "echo hi"; await tools.exec_command({cmd});',
    "echo hi",
    "echo hi",
    "string-literal",
    "const",
  ],
  [
    "pragma",
    '// @exec: {"yield_time_ms": 1000}\n' + echo,
    "echo hi",
    "echo hi",
    "string-literal",
    "inline",
  ],
  [
    "escaped identifier key",
    String.raw`await tools.exec_command({c\u006dd: "echo hi"});`,
    "echo hi",
    "echo hi",
    "string-literal",
    "inline",
  ],
  [
    "escaped string key",
    String.raw`await tools.exec_command({"c\x6dd": "echo hi"});`,
    "echo hi",
    "echo hi",
    "string-literal",
    "inline",
  ],
  [
    "escaped method property",
    String.raw`await tools.exec_\u0063ommand({cmd: "echo hi"});`,
    "echo hi",
    "echo hi",
    "string-literal",
    "inline",
  ],
  [
    "complete call before truncated tail",
    echo + "\nconst later =",
    "echo hi",
    "echo hi",
    "string-literal",
    "inline",
  ],
] as const)(
  "embeds Bash for %s",
  async (_label, cell, raw, decoded, construct, binding) => {
    const { flow, tree, pieces } = await analyze(cell);
    expectSource(flow, raw, decoded, construct, binding);
    expect(embeds(tree)).toEqual([[[0], "bash", "inline"]]);
    expect(pieces.map(({ kind, language }) => [kind, language])).toEqual([
      ["inline", "javascript"],
      ["inline", "bash"],
      ["inline", "javascript"],
    ]);
  },
);

it("analyzes one Bash child for a const used by two calls", async () => {
  const command = "printf fan-out";
  const cell = `const c = "${command}";\n${exec("c")}\n${exec("c")}`;
  const load = vi.spyOn(shellParser, "loadParsedShellDocument");
  try {
    const { flow, tree } = await analyze(cell);
    expectSource(flow, command, command, "string-literal", "const", 2);
    expect(embeds(tree)).toEqual([[[0], "bash", "inline"]]);
    expect(load.mock.calls).toEqual([[command]]);
  } finally {
    load.mockRestore();
  }
});

it("keeps a Bash leaf and analyzes its sibling when one parser load rejects", async () => {
  const unavailable = "printf unavailable";
  const sibling = "python3 - <<'PY'\nprint(2)\nPY";
  const cell = [unavailable, sibling]
    .map((command) => exec(JSON.stringify(command)))
    .join("\n");
  const originalLoad = shellParser.loadParsedShellDocument;
  const load = vi
    .spyOn(shellParser, "loadParsedShellDocument")
    .mockImplementation(async (source) => {
      if (source === unavailable) throw new Error("Bash parser unavailable");
      return originalLoad(source);
    });
  try {
    const { flow, tree, pieces } = await analyze(cell);
    expect(flow.sources).toMatchObject([
      { value: { text: unavailable }, child: null },
      {
        value: { text: sibling },
        child: { language: "bash", text: sibling },
      },
    ]);
    expect(tree.language).toBe("javascript");
    expect(embeds(tree)).toEqual([
      [[0], "bash", "inline"],
      [[1], "bash", "inline"],
      [[1, 0], "python", "rich"],
    ]);
    expect(pieces).toContainEqual(
      expect.objectContaining({
        kind: "inline",
        language: "bash",
        text: unavailable,
      }),
    );
  } finally {
    load.mockRestore();
  }
});

it.each([
  ["template substitution", exec("`echo ${name}`")],
  ["concatenation", exec("prefix + s")],
  ["member access", exec("item.cmd")],
  ["spread", 'await tools.exec_command({cmd: "echo hi", ...options});'],
  ["computed key", 'await tools.exec_command({cmd: "echo hi", [key]: 1});'],
  [
    "duplicate cmd",
    'await tools.exec_command({cmd: "echo hi", "cmd": "echo bye"});',
  ],
  ["block const", "{ " + bound + " }"],
  ["let", bound.replace("const", "let")],
  ["var", bound.replace("const", "var")],
  ["second binding as a function parameter", bound + " function f(c) {}"],
  ["second binding in destructuring", bound + " { const {c} = obj; }"],
  ["second binding as a catch parameter", bound + " try {} catch (c) {}"],
  ["second binding as a nested const", bound + ' { const c = "echo bye"; }'],
  ["use before declaration", exec("c") + ' const c = "echo hi";'],
  ["tools parameter", echo + " function f(tools) {}"],
  ["tools variable", echo + " let tools;"],
  ["tools function name", echo + " function tools() {}"],
  ["escaped tools binding", echo + String.raw` let t\u006fols;`],
  ["named generator expression", echo + " const f = function* tools() {};"],
  ["String binding", exec("String.raw`echo hi`") + " let String;"],
  ["strict-invalid escape", exec(String.raw`"echo \1"`)],
  [
    "raw template with a grammar-rejected hex escape",
    exec("String.raw`echo \\xGG`"),
  ],
  ["empty operand", exec('""')],
  ["continuation-only operand", exec('"\\\n"')],
  ["bracket method", 'await tools["exec_command"]({cmd: "echo hi"});'],
  ["nested receiver", "await x." + echo.slice("await ".length)],
  ["write_stdin", String.raw`await tools.write_stdin({chars: "y\n"});`],
  [
    "interpolated patch template",
    applyPatch("`*** Begin Patch\n${body}\n*** End Patch`"),
  ],
  ["missing closing parenthesis", 'await tools.exec_command({cmd: "echo hi"};'],
  ["unterminated initializer", "const c = `echo hi\n" + exec("c")],
  ["potential binding in an ERROR region", bound + "\nconst c +"],
])("keeps %s as JavaScript", async (_label, cell) => {
  const { flow, tree, pieces } = await analyze(cell);
  expect(flow.sources).toEqual([]);
  expect(embeds(tree)).toEqual([]);
  expect(pieces).toMatchObject([
    { kind: "inline", language: "javascript", text: cell },
  ]);
});

it.each([
  [
    "inline literal",
    applyPatch(quotedPatch),
    quotedPatch.slice(1, -1),
    "string-literal",
    "inline",
    1,
  ],
  [
    "const literal",
    bindPatch(quotedPatch) + patchReference,
    quotedPatch.slice(1, -1),
    "string-literal",
    "const",
    1,
  ],
  [
    "const String.raw",
    bindPatch("String.raw`" + patch + "`") + patchReference,
    patch,
    "string-raw",
    "const",
    1,
  ],
  [
    "const with two uses",
    bindPatch(quotedPatch) + patchReference + "\n" + patchReference,
    quotedPatch.slice(1, -1),
    "string-literal",
    "const",
    2,
  ],
] as const)(
  "renders a rich patch for %s",
  async (_label, cell, raw, construct, binding, uses) => {
    const { flow, tree, pieces } = await analyze(cell);
    const start = cell.indexOf(raw);
    const span = { start, end: start + raw.length };
    expect(flow.sources).toMatchObject([
      {
        span,
        value: { text: patch },
        origin: { language: "javascript", construct, attributes: { binding } },
        sinks: Array.from({ length: uses }, () => patchSink),
        layout: "block",
        child: null,
      },
    ]);
    expect(embeds(tree)).toEqual([[[0], "apply-patch", "rich"]]);
    expect(pieces.filter((piece) => piece.kind === "rich")).toMatchObject([
      {
        language: "apply-patch",
        mode: "rich-patch",
        text: patch,
        sourceText: raw,
        sourceSpan: span,
      },
    ]);
  },
);

it("keeps a const shared by Bash and apply_patch as inline text", async () => {
  const cell = bindPatch(quotedPatch) + exec("patch") + "\n" + patchReference;
  const { flow, tree, pieces } = await analyze(cell);
  expect(flow.sources).toMatchObject([
    {
      value: { text: patch },
      sinks: [
        { kind: "program", language: "bash", channel: "argv" },
        patchSink,
      ],
      layout: "inline",
      child: null,
    },
  ]);
  expect(embeds(tree)).toEqual([[[0], "text", "inline"]]);
  expect(pieces.map(({ kind, language }) => [kind, language])).toEqual([
    ["inline", "javascript"],
    ["inline", "text"],
    ["inline", "javascript"],
  ]);
});

it("projects a Markdown heredoc through a nested zsh command into escaped JavaScript", async () => {
  const body = "# Title\n\nSome *markdown*";
  const command = `zsh -lc "tee d/doc.md >/dev/null <<'EOF'\n${body}\nEOF"`;
  const raw = JSON.stringify(command).slice(1, -1);
  const cell = exec(JSON.stringify(command));
  const { flow, tree, pieces } = await analyze(cell);
  expectSource(flow, raw, command, "string-literal", "inline");
  expect(embeds(tree)).toEqual([
    [[0], "bash", "inline"],
    [[0, 0], "bash", "inline"],
    [[0, 0, 0], "markdown", "rich"],
  ]);
  const rawBody = String.raw`# Title\n\nSome *markdown*`;
  const start = cell.indexOf(rawBody);
  expect(pieces.filter((piece) => piece.kind === "rich")).toMatchObject([
    {
      language: "markdown",
      mode: "rich-markdown",
      text: body,
      sourceText: rawBody,
      sourceSpan: { start, end: start + rawBody.length },
    },
  ]);
});

it("renders Python stdin inside the Bash operand as rich code", async () => {
  const command = "python3 - <<'PY'\nprint(1)\nPY";
  const { flow, tree, pieces } = await analyze(exec("`" + command + "`"));
  expectSource(flow, command, command, "template-literal", "inline");
  expect(embeds(tree)).toEqual([
    [[0], "bash", "inline"],
    [[0, 0], "python", "rich"],
  ]);
  expect(pieces.filter((piece) => piece.kind === "rich")).toMatchObject([
    {
      language: "python",
      mode: "rich-code",
      text: "print(1)",
      sourceText: "print(1)",
    },
  ]);
});

it.each([
  'tools.exec_command(,{cmd:"echo hi"});',
  'tools.exec_command({cmd:"echo hi"},,);',
  'tools.exec_command({,cmd:"echo hi"});',
  'tools.exec_command({cmd:"echo hi",,});',
  'tools.exec_command({cmd:"echo hi", 01: 0});',
  'tools.exec_command({cmd:"echo hi", __proto__: null, "__proto__": null});',
  'tools.exec_command({cmd:"echo hi", get other(value) {}});',
  String.raw`tools.exec_command({cmd:"echo hi", "\1": 0});`,
  "tools.exec_command({cmd:String?.raw`echo hi`});",
  'tools?.exec_command({cmd:"echo hi"});',
  'tools.exec_command?.({cmd:"echo hi"});',
])("rejects unsupported local syntax in %s", async (cell) => {
  expect((await analyze(cell)).flow.sources).toHaveLength(0);
});

it.each(["undefined", String.raw`\u0075ndefined`])(
  "resolves the const reference %s with trailing commas and comments",
  async (reference) => {
    const cell =
      'const undefined = "echo hi"; ' +
      `tools.exec_command(/* argument */ {cmd: ${reference},},);`;
    expect((await analyze(cell)).flow.sources[0]?.value.text).toBe("echo hi");
  },
);

it("retains an independent call in a deeply nested valid cell", async () => {
  const cell = echo + "\n" + "0+".repeat(18000) + "0;";
  expect((await analyze(cell)).flow.sources).toHaveLength(1);
});

it("preserves nested Markdown after a non-BMP escape in the Bash prefix", async () => {
  const cell = exec(
    String.raw`"echo \u{1F600}; tee d/doc.md <<'EOF'\n# Title\nEOF"`,
  );
  const { pieces } = await analyze(cell);
  expect(pieces.map(({ kind, language }) => [kind, language])).toContainEqual([
    "rich",
    "markdown",
  ]);
  expect(pieces.map(({ kind, language }) => [kind, language])).toContainEqual([
    "inline",
    "bash",
  ]);
});

it.each([
  'tools.apply_patch(,"demo");',
  'tools.apply_patch("demo",,);',
  'tools?.apply_patch("demo");',
  'tools.apply_patch?.("demo");',
  "tools.apply_patch(String?.raw`demo`);",
])("rejects unsupported patch syntax in %s", async (cell) => {
  expect((await analyze(cell)).flow.sources).toHaveLength(0);
});

it.each(["undefined", String.raw`\u0075ndefined`])(
  "resolves patch const reference %s with a trailing comma",
  async (reference) => {
    const cell =
      bindPatch(quotedPatch).replace("const patch", "const undefined") +
      `tools.apply_patch(${reference},);`;
    expect((await analyze(cell)).flow.sources[0]?.value.text).toBe(patch);
  },
);

it("classifies a deep binding pattern without reading an ancestor per identifier", async () => {
  const depth = 1024;
  const pattern =
    Array.from({ length: depth }, (_, index) => `[v${index},`).join("") +
    "leaf" +
    "]".repeat(depth);
  const parent = vi.spyOn(Node.prototype, "parent", "get");
  try {
    const cell = `const ${pattern} = []; ${echo}`;
    expect((await analyze(cell)).flow.sources).toHaveLength(1);
    expect(parent).not.toHaveBeenCalled();
  } finally {
    parent.mockRestore();
  }
});

it.each([
  ["invalid escape", String.raw`\x61`.repeat(512) + String.raw`\8`],
  ["empty value", ("\\" + "\n").repeat(512)],
])("decodes a const with %s only once across all uses", async (_name, raw) => {
  const decode = vi.spyOn(literalDecoder, "decodeJavaScriptLiteral");
  try {
    const cell = `const c = "${raw}";` + exec("c").repeat(512);
    expect((await analyze(cell)).flow.sources).toHaveLength(0);
    expect(decode).toHaveBeenCalledTimes(1);
  } finally {
    decode.mockRestore();
  }
});

it.each([
  "m() {}",
  "get m() {}",
  "set m(value) {}",
  "async m() {}",
  "*m() {}",
  "async\n m() {}",
  "m(a, a) {}",
  String.raw`\u0069f`,
  String.raw`l\u0065t`,
  String.raw`\u0079ield`,
  String.raw`\u0061wait`,
  String.raw`\u0073tatic`,
  String.raw`\u0069mplements`,
])("rejects methods and strict-reserved shorthand in %s", async (option) => {
  expect(
    (await analyze(`tools.exec_command({cmd:"echo hi", ${option}});`)).flow
      .sources,
  ).toHaveLength(0);
});

it("allows explicit reserved-word keys and ordinary shorthand", async () => {
  const cell = String.raw`const other = 1; tools.exec_command({\u0069f: 1, "await": 2, 3: 4, other, cmd:"echo hi",});`;
  expect((await analyze(cell)).flow.sources[0]?.value.text).toBe("echo hi");
});

it.each([
  String.raw`\uD835\uDC9C`,
  String.raw`\u0030name`,
  String.raw`\u200Cname`,
])(
  "rejects invalid identifier escapes in shorthand and explicit key %s",
  async (name) => {
    for (const property of [name, name + ": 0"]) {
      const cell = `tools.exec_command({cmd: "echo hi", ${property}});`;
      expect((await analyze(cell)).flow.sources).toHaveLength(0);
    }
  },
);

it.each([
  "𝒜",
  String.raw`\u{1D49C}`,
  String.raw`name\u0030`,
  String.raw`name\u200C\u200D`,
])(
  "retains valid identifier spellings in shorthand and explicit key %s",
  async (name) => {
    for (const property of [name, name + ": 0"]) {
      const cell = `tools.exec_command({cmd: "echo hi", ${property}});`;
      expect((await analyze(cell)).flow.sources[0]?.value.text).toBe("echo hi");
    }
  },
);

it.each([
  [String.raw`\uD835\uDC9C`, "𝒜", false],
  ["𝒜", String.raw`\uD835\uDC9C`, false],
  ["𝒜", String.raw`\u{1D49C}`, true],
  [String.raw`\u{1D49C}`, "𝒜", true],
] as const)(
  "validates a const name %s and its reference %s independently",
  async (name, reference, resolved) => {
    const cell = `const ${name} = "echo hi"; ` + exec(reference);
    expect((await analyze(cell)).flow.sources).toHaveLength(resolved ? 1 : 0);
  },
);

it.each([
  ["direct operand", 'tools.exec_command({cmd:"bad\n"});'],
  ["const initializer", 'const bad = "bad\r"; tools.exec_command({cmd:bad});'],
  ["quoted options key", 'tools.exec_command({cmd:"echo bad","extra\n":0});'],
])(
  "keeps the valid sibling when a %s contains a raw line terminator",
  async (_label, invalid) => {
    const { flow } = await analyze(echo + "\n" + invalid);
    expect(flow.sources.map(({ value }) => value.text)).toEqual(["echo hi"]);
  },
);

it("handles every prefix and single-character mutation of a code-mode cell", async () => {
  const cell = [
    '// @exec: {"yield_time_ms":1000}',
    "const cmd = `tee d/doc.md <<'EOF'",
    "# Title",
    "EOF`;",
    'await tools.exec_command({cmd, "workdir": "/tmp"});',
    'await tools.exec_command({cmd:"printf %s\\n done"});',
  ].join("\n");
  const checks = Array.from({ length: cell.length + 1 }, (_, end) =>
    cell.slice(0, end),
  );
  for (let index = 0; index < cell.length; index++) {
    for (const replacement of [
      "'",
      '"',
      "`",
      "\\",
      "\n",
      "\r",
      "$",
      "{",
      "}",
      "\0",
    ]) {
      if (replacement !== cell[index])
        checks.push(cell.slice(0, index) + replacement + cell.slice(index + 1));
    }
  }
  for (const source of checks) {
    await withJavaScriptTree(source, (root) =>
      analyzeCodeModeCell(root, source),
    );
  }
});

it("keeps a valid exec sibling when an error-free patch literal contains a raw LF", async () => {
  const cell =
    'tools.exec_command({cmd:"echo ok"});\ntools.apply_patch("bad\n");';
  const { flow } = await analyze(cell);
  expect(flow.sources.map(({ value }) => value.text)).toEqual(["echo ok"]);
});
