import { beforeAll, describe, expect, it } from "vitest";
import {
  loadParsedShellDocument,
  type ParsedShellDocument,
} from "./shellParser";
import { configureTreeSitterAssets } from "./treeSitterRuntime";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import {
  shellArgumentWords,
  shellFdTable,
  type ShellFdBinding,
} from "./shellFdTable";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

const parsedShellDocumentInvariant = "parsed shell document invariant:";

function ownerIdAt(
  document: ParsedShellDocument,
  source: string,
  searchStart = 0,
): number {
  const commandStart = source.indexOf("cat", searchStart);
  if (commandStart < 0) throw new Error("test command marker missing");
  const owner = document.commands.find(
    (command) => command.name.rawSpan.start === commandStart,
  );
  if (owner === undefined) throw new Error("test command owner missing");
  return owner.id;
}

async function loadDocument(source: string): Promise<ParsedShellDocument> {
  const result = await loadParsedShellDocument(source);
  if (!result.ok)
    throw new Error(
      `expected normalized document: ${source}: ${result.reason}`,
    );
  return result.document;
}

const inheritedStdin = { kind: "inherited-stdin" } as const;
const toolOutput = { kind: "tool-output" } as const;
const discard = { kind: "discard" } as const;

function file(
  path: string,
  mode: "overwrite" | "append" = "overwrite",
): ShellFdBinding {
  return { kind: "file", path, mode };
}

// Numeric expectations identify source bindings by their redirect index.
type ExpectedBinding = readonly [fd: number, binding: ShellFdBinding | number];

async function expectBindings(
  source: string,
  bindings: readonly ExpectedBinding[],
  searchStart = 0,
): Promise<void> {
  const document = await loadDocument(source);
  const expected = new Map<number, ShellFdBinding>([
    [0, inheritedStdin],
    [1, toolOutput],
    [2, toolOutput],
  ]);
  for (const [fd, binding] of bindings) {
    if (typeof binding === "number") {
      const redirect = document.redirects[binding];
      if (redirect === undefined)
        throw new Error("test source redirect missing");
      expected.set(fd, { kind: "source", redirectId: redirect.id });
    } else {
      expected.set(fd, binding);
    }
  }
  expect(
    shellFdTable(document, ownerIdAt(document, source, searchStart)),
    source,
  ).toEqual(expected);
}

describe("shell fd table", () => {
  it("starts with inherited stdin and tool output for stdout and stderr", async () => {
    await expectBindings("cat", []);
  });

  it.each([
    ["cat >out.md", [[1, file("out.md")]]],
    ["cat >>out.md", [[1, file("out.md", "append")]]],
    ["cat >|out.md", [[1, file("out.md")]]],
    [
      "cat &>all.log",
      [
        [1, file("all.log")],
        [2, file("all.log")],
      ],
    ],
    [
      "cat &>>all.log",
      [
        [1, file("all.log", "append")],
        [2, file("all.log", "append")],
      ],
    ],
    [
      "cat >&output.log",
      [
        [1, file("output.log")],
        [2, file("output.log")],
      ],
    ],
    ["cat 1>out.md", [[1, file("out.md")]]],
    ["cat >$OUT", [[1, { kind: "unknown" }]]],
    ["cat >first.md >later.py", [[1, file("later.py")]]],
    ["cat >first.py >&2", []],
    ["cat >out.md 1<&0", [[1, inheritedStdin]]],
    ["cat 2>error.log", [[2, file("error.log")]]],
    ['cat >"2"', [[1, file("2")]]],
    [
      'cat &>"2"',
      [
        [1, file("2")],
        [2, file("2")],
      ],
    ],
  ] as const)("binds output redirects for %s", async (source, bindings) => {
    await expectBindings(source, bindings);
  });

  it("uses redirects from only the selected command", async () => {
    const source = "cat >first.md 3>extra; cat >second.py";
    await expectBindings(
      source,
      [[1, file("second.py")]],
      source.indexOf(";") + 1,
    );
  });

  it.each([
    ["cat <in", [[0, { kind: "unknown" }]]],
    ["cat <<EOF\nbody\nEOF", [[0, 0]]],
    ["cat <<<value", [[0, 0]]],
    ["cat <<EOF <in\nbody\nEOF", [[0, { kind: "unknown" }]]],
    ["cat <in <<EOF\nbody\nEOF", [[0, 1]]],
    ["cat <<EOF <&1\nbody\nEOF", [[0, toolOutput]]],
    [
      "cat <<EOF 2<&0\nbody\nEOF",
      [
        [0, 0],
        [2, 0],
      ],
    ],
    ["cat 2<<EOF\nbody\nEOF", [[2, 0]]],
  ] as const)("binds input redirects for %j", async (source, bindings) => {
    await expectBindings(source, bindings);
  });

  it.each([
    [
      "cat 2>f 1>&2",
      [
        [1, file("f")],
        [2, file("f")],
      ],
    ],
    ["cat 1>&2 2>f", [[2, file("f")]]],
    [
      'cat 2>f 1>&"02"',
      [
        [1, file("f")],
        [2, file("f")],
      ],
    ],
    [
      "cat 2>f 1>&'0'2",
      [
        [1, file("f")],
        [2, file("f")],
      ],
    ],
    [
      'cat 3>f 4<&"03" 1>&4',
      [
        [1, file("f")],
        [3, file("f")],
        [4, file("f")],
      ],
    ],
  ] as const)(
    "copies the descriptor binding in effect for %s",
    async (source, bindings) => {
      await expectBindings(source, bindings);
    },
  );

  it.each([
    ["cat 2147483647>out", [[2147483647, file("out")]]],
    ["cat 2147483648>out", [[1, file("out")]]],
    ["cat 2147483648<in", [[0, { kind: "unknown" }]]],
  ] as const)(
    "honors the descriptor limit for %s",
    async (source, bindings) => {
      await expectBindings(source, bindings);
    },
  );

  it.each([
    ["2147483647", []],
    [
      "2147483648",
      [
        {
          kind: "literal",
          value: "2147483648",
          rawSpan: { start: 10, end: 20 },
        },
      ],
    ],
  ] as const)(
    "returns argument words around %s>out in source order",
    async (fd, extraWords) => {
      const document = await loadDocument(`cat first ${fd}>out "$FILE" last`);
      const command = document.commands[0]!;
      const redirects = command.redirectIds.map(
        (id) => document.redirects[id]!,
      );
      expect(shellArgumentWords(command.arguments, redirects)).toMatchObject([
        { kind: "literal", value: "first", rawSpan: { start: 4, end: 9 } },
        ...extraWords,
        { kind: "nonliteral", rawSpan: { start: 25, end: 32 } },
        { kind: "literal", value: "last", rawSpan: { start: 33, end: 37 } },
      ]);
    },
  );

  it.each([
    ["cat >/dev/null", [[1, discard]]],
    ["cat 1>/dev/null", [[1, discard]]],
    ["cat >|/dev/null", [[1, discard]]],
    [
      "cat &>/dev/null",
      [
        [1, discard],
        [2, discard],
      ],
    ],
    [
      "cat &>>/dev/null",
      [
        [1, discard],
        [2, discard],
      ],
    ],
  ] as const)("discards output for %s", async (source, bindings) => {
    await expectBindings(source, bindings);
  });
});

describe("shell fd table parser boundaries", () => {
  it.each([
    "cat >&-",
    "cat <&-",
    "cat 0>out",
    "cat 0>&1",
    "cat 0<&1",
    "cat 0<<EOF\nbody\nEOF",
    "cat 01>out",
    "cat 02>out",
    "cat 01<<EOF\nbody\nEOF",
    "cat 02<<EOF\nbody\nEOF",
  ])("keeps unsupported native redirect source unsafe: %s", async (source) => {
    await expect(
      loadParsedShellDocument(source),
      source,
    ).resolves.toMatchObject({
      ok: false,
    });
  });
});

describe("shell fd table invariants", () => {
  it("fails fast for an unknown command ID", async () => {
    const document = await loadDocument("cat >out.py");
    expect(() => shellFdTable(document, 999)).toThrow("command id invariant");
  });

  it("validates command and redirect ownership before applying redirects", async () => {
    const document = await loadDocument("cat 2>out.py");
    const ownerId = ownerIdAt(document, document.source);
    const redirect = document.redirects[0];
    if (redirect === undefined) throw new Error("test redirect missing");

    for (const malformed of [
      {
        ...document,
        commands: document.commands.map((command) =>
          command.id === ownerId ? { ...command, redirectIds: [] } : command,
        ),
      },
      {
        ...document,
        redirects: document.redirects.map((candidate) => ({
          ...candidate,
          ownerId: ownerId + 1,
        })),
      },
    ] as const)
      expect(() => shellFdTable(malformed, ownerId)).toThrow(
        parsedShellDocumentInvariant,
      );
  });

  it("validates native numeric descriptor provenance before applying redirects", async () => {
    const document = await loadDocument("cat 2>out");
    const redirect = document.redirects[0];
    const descriptor = redirect?.descriptor;
    if (redirect?.kind !== "file" || descriptor?.kind !== "number")
      throw new Error("test numeric descriptor is incomplete");
    expect(() =>
      shellFdTable(
        {
          ...document,
          redirects: [
            {
              ...redirect,
              descriptor: {
                kind: "number",
                rawSpan: descriptor.rawSpan,
                value: "1",
              },
            },
          ],
        },
        redirect.ownerId,
      ),
    ).toThrow("parsed shell document invariant: redirect descriptor value");
  });
});
