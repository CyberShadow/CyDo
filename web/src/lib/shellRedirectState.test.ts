import { beforeAll, describe, expect, it } from "vitest";
import {
  configureShellParserAssets,
  loadParsedShellDocument,
  type ParsedShellDocument,
} from "./shellParser";
import { reduceShellRedirectState } from "./shellRedirectState";

type FsPromisesLike = { readFile(path: URL): Promise<Uint8Array> };

const processLike = (
  globalThis as typeof globalThis & {
    process: { getBuiltinModule(name: string): unknown };
  }
).process;

beforeAll(async () => {
  const fs = processLike.getBuiltinModule("node:fs/promises") as FsPromisesLike;
  const [runtime, bashLanguage] = await Promise.all([
    fs.readFile(
      new URL(
        "../../node_modules/web-tree-sitter/web-tree-sitter.wasm",
        import.meta.url,
      ),
    ),
    fs.readFile(
      new URL(
        "../../node_modules/tree-sitter-bash/tree-sitter-bash.wasm",
        import.meta.url,
      ),
    ),
  ]);
  configureShellParserAssets({
    kind: "bytes",
    loadRuntime: () => Promise.resolve(new Uint8Array(runtime)),
    loadBashLanguage: () => Promise.resolve(new Uint8Array(bashLanguage)),
  });
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

async function expectFacts(
  source: string,
  facts: Readonly<{
    literalStdoutPath: string | null;
    effectiveStdinRedirectIndex: number | null;
  }>,
  searchStart = 0,
): Promise<void> {
  const document = await loadDocument(source);
  const result = reduceShellRedirectState(
    document,
    ownerIdAt(document, source, searchStart),
  );
  const effectiveStdinRedirectId =
    facts.effectiveStdinRedirectIndex === null
      ? null
      : document.redirects[facts.effectiveStdinRedirectIndex]?.id;
  if (effectiveStdinRedirectId === undefined)
    throw new Error("test effective stdin redirect missing");
  expect(result, source).toEqual({
    literalStdoutPath: facts.literalStdoutPath,
    effectiveStdinRedirectId,
  });
}

function heredoc(redirect = ""): string {
  return redirect === ""
    ? "cat <<EOF\nbody\nEOF"
    : `cat ${redirect}<<EOF\nbody\nEOF`;
}

describe("shell redirect state", () => {
  it.each([
    ["cat >out.md", "out.md"],
    ["cat >>out.md", "out.md"],
    ["cat >|out.md", "out.md"],
    ["cat &>all.log", "all.log"],
    ["cat &>>all.log", "all.log"],
    ["cat >&output.log", "output.log"],
    ["cat 1>out.md", "out.md"],
    ["cat >$OUT", null],
    ["cat >first.md >later.py", "later.py"],
    ["cat >first.py >&2", null],
    ["cat >out.md 1<&0", null],
    ["cat 2>error.log", null],
  ] as const)(
    "reports the literal stdout path for %s",
    async (source, literalStdoutPath) => {
      await expectFacts(source, {
        literalStdoutPath,
        effectiveStdinRedirectIndex: null,
      });
    },
  );

  it("uses redirects from only the selected command", async () => {
    const source = "cat >first.md; cat >second.py";
    await expectFacts(
      source,
      { literalStdoutPath: "second.py", effectiveStdinRedirectIndex: null },
      source.indexOf("cat") + 1,
    );
  });

  it.each([
    ["cat <in", 0],
    [heredoc(), 0],
    ["cat <<<value", 0],
    ["cat <<EOF <in\nbody\nEOF", 1],
    ["cat <in <<EOF\nbody\nEOF", 1],
    ["cat <<EOF <&1\nbody\nEOF", null],
    ["cat <<EOF 2<&0\nbody\nEOF", 0],
    [heredoc("2"), null],
  ] as const)(
    "reports stdin provenance for %s",
    async (source, effectiveStdinRedirectIndex) => {
      await expectFacts(source, {
        literalStdoutPath: null,
        effectiveStdinRedirectIndex,
      });
    },
  );
});

describe("shell redirect state parser boundaries", () => {
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

describe("shell redirect state invariants", () => {
  it("fails fast for an unknown command ID", async () => {
    const document = await loadDocument("cat >out.py");
    expect(() => reduceShellRedirectState(document, 999)).toThrow(
      "command id invariant",
    );
  });

  it("validates command and redirect ownership before reducing", async () => {
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
      expect(() => reduceShellRedirectState(malformed, ownerId)).toThrow(
        parsedShellDocumentInvariant,
      );
  });

  it("validates native numeric descriptor provenance before reducing", async () => {
    const document = await loadDocument("cat 2>out");
    const redirect = document.redirects[0];
    const descriptor = redirect?.descriptor;
    if (redirect?.kind !== "file" || descriptor?.kind !== "number")
      throw new Error("test numeric descriptor is incomplete");
    expect(() =>
      reduceShellRedirectState(
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
