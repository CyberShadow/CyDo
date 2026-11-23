import { describe, it, expect, beforeAll, vi } from "vitest";
import { parseShellSemantic } from "./shellSemantic";
import * as shellParser from "./shellParser";
import {
  configureShellParserAssets,
  loadParsedShellDocument,
  type ParsedShellDocument,
} from "./shellParser";
import { derivePlan } from "./commandStep";
import { buildShellSourceTree } from "./shellSourceTree";
import type {
  ShellReadSemantic,
  ShellHeredocWriteSemantic,
  ShellDiffSemantic,
  ShellScriptExecSemantic,
} from "./shellSemantic";

const plan = (v: { steps?: Parameters<typeof derivePlan>[0] }) =>
  v.steps ? derivePlan(v.steps) : undefined;

type FsPromisesLike = {
  readFile(path: URL): Promise<Uint8Array>;
};

const processLike = (
  globalThis as typeof globalThis & {
    process: {
      getBuiltinModule(name: string): unknown;
    };
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

async function buildLoadedShellSourceTree(source: string) {
  const parsed = await loadParsedShellDocument(source);
  expect(parsed.ok, source).toBe(true);
  if (!parsed.ok) throw new Error(`shell parser rejected: ${parsed.reason}`);
  return buildShellSourceTree(parsed.document);
}

function normalizeSemanticForComparison(value: unknown): unknown {
  const normalized: unknown = JSON.parse(JSON.stringify(value));
  if (normalized && typeof normalized === "object") {
    delete (normalized as { command?: string }).command;
  }
  return normalized;
}

it("returns an unsupported command result for a 4,000-command && chain", async () => {
  const source = Array(4_000).fill("true").join(" && ");
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: false,
    code: "unsupported_command",
  });
});

it("returns an unsupported command result for a long && chain with redirects", async () => {
  const source = Array(4_000).fill("true >out").join(" && ");
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: false,
    code: "unsupported_command",
  });
}, 30_000);

it("classifies a 4,000-stage read pipeline", async () => {
  const source = ["cat file", ...Array<string>(3_999).fill("head -n 1")].join(
    " | ",
  );
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: true,
    value: { kind: "read", range: { type: "head", count: 1 } },
  });
}, 30_000);

it("classifies a diff source in a 4,000-stage formatting pipeline", async () => {
  const source = ["git diff", ...Array<string>(3_999).fill("head -n 1")].join(
    " | ",
  );
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: true,
    value: { kind: "diff", command: source },
  });
}, 30_000);

it("returns an unsupported command result for a 4,000-command Python wrapper chain", async () => {
  const source = Array(4_000).fill("python -c 'pass'").join(" && ");
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: false,
    code: "unsupported_command",
  });
}, 30_000);

it("classifies a Python wrapper after 3,999 literal cd commands", async () => {
  const source = [
    ...Array<string>(3_999).fill("cd /tmp"),
    "python -c 'pass'",
  ].join(" && ");
  await expect(parseShellSemantic(source)).resolves.toMatchObject({
    ok: true,
    value: { kind: "script-exec", language: "python", command: source },
  });
}, 30_000);

// ---------------------------------------------------------------------------
// Accepted read forms
// ---------------------------------------------------------------------------

describe("cat reads", () => {
  it.each(["café.md", "漢字.md", "🧪.md"])(
    "classifies a read from the bare Unicode path %s",
    async (path) => {
      await expect(parseShellSemantic(`cat ${path}`)).resolves.toMatchObject({
        ok: true,
        value: { kind: "read", filePath: path },
      });
    },
  );

  it("cat README.md → read with filePath", async () => {
    const r = await parseShellSemantic("cat README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "all" });
    expect(v.presentation.lineNumbers).toBe(false);
  });

  it("cat -- README.md → read", async () => {
    const r = await parseShellSemantic("cat -- README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("keeps a terminal semicolon structurally visible and conservative", async () => {
    await expect(parseShellSemantic("cat README.md;")).resolves.toEqual({
      ok: false,
      code: "unsupported_command",
      reason: "malformed program boundaries",
    });
  });
});

describe("nl reads", () => {
  it("nl -ba -w 4 -s ': ' source/app.d → read with lineNumbers presentation", async () => {
    const r = await parseShellSemantic("nl -ba -w 4 -s ': ' source/app.d");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("source/app.d");
    expect(v.presentation.lineNumbers).toMatchObject({
      style: "nl",
      width: 4,
      separator: ": ",
    });
  });
});

describe("strict shell argv", () => {
  it.each([
    ["cat f | sed -z -n 1,1p | head -2", "-z"],
    ["sed junk -n 1,2p f", "junk"],
    ["sed -n 1,2p f -z", "-z"],
    ["sed -n 1,2p f extra", "extra"],
    ["sed -n 1,9007199254740993p f", "9007199254740993"],
    [
      "head -n 9007199254740993 f | head -n 9007199254740994",
      "9007199254740993",
    ],
    ["head -n9007199254740993 f", "-n9007199254740993"],
    ["head -9007199254740993 f", "-9007199254740993"],
    ["head -n 0x10 f", "0x10"],
    ["head -n 2e0 f", "2e0"],
    ["head f -2", "-2"],
    ["tail -n +9007199254740993 f", "+9007199254740993"],
    ["tail -n9007199254740993 f", "-n9007199254740993"],
    ["tail -9007199254740993 f", "-9007199254740993"],
    ["tail -2 -n 1 f", "-n"],
    ["tail -n +2 -n 1 f", "-n"],
    ["head -n 2 -n1 f", "-n1"],
    ["tail f -2", "-2"],
    ["nl -w 2147483648 f", "2147483648"],
    ["nl -w 9007199254740991 f", "9007199254740991"],
    ["nl -w 9007199254740993 f", "9007199254740993"],
    ["nl -w 2e0 f", "2e0"],
    ["nl f -z", "-z"],
    ["cat f -n", "-n"],
    ["cat f extra", "extra"],
    ["cat -- -", "-"],
    ['cat ""', '""'],
    ["cat f && cd -Z /tmp", "-Z"],
    ["cd -Z y && cat f", "-Z"],
    ["cd a b && cat f", "b"],
    ["cd a >out && cat f", ">"],
    ["grep -n p f -z", "-z"],
    ["rg -n p f --json", "--json"],
    ["rg -n p f extra", "extra"],
    ["cat f | grep -n p extra", "extra"],
  ])("rejects %s and names %s", async (command, token) => {
    const result = await parseShellSemantic(command);
    expect(result.ok, command).toBe(false);
    if (!result.ok) expect(result.reason).toContain(token);
  });

  it.each([
    ["cat -- -n", "-n"],
    ["head -n 2 -- -n", "-n"],
    ["tail -n +2 -- -n", "-n"],
    ["sed -n -- 1,2p -n", "-n"],
    ["sed -n 1,2p -- -n", "-n"],
    ["nl -ba -- -n", "-n"],
  ])("uses the literal file operand in %s", async (command, filePath) => {
    await expect(parseShellSemantic(command)).resolves.toMatchObject({
      ok: true,
      value: { kind: "read", filePath },
    });
  });

  it("accepts GNU nl's maximum field width", async () => {
    await expect(
      parseShellSemantic("nl -w 2147483647 f"),
    ).resolves.toMatchObject({
      ok: true,
      value: {
        kind: "read",
        presentation: { lineNumbers: { width: 2147483647 } },
      },
    });
  });

  it("rejects unsafe sed addresses on the ls readback path", async () => {
    await expect(
      parseShellSemantic("ls -l f && sed -n 1,9007199254740993p f"),
    ).resolves.toEqual({
      ok: false,
      code: "invalid_range",
      reason:
        "sed line numbers must be positive safe decimal integers: 1,9007199254740993p",
    });
  });
});

describe("sed reads", () => {
  it("sed -n '10,20p' web/src/main.tsx → read with lines range", async () => {
    const r = await parseShellSemantic("sed -n '10,20p' web/src/main.tsx");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("web/src/main.tsx");
    expect(v.range).toEqual({ type: "lines", start: 10, end: 20 });
  });
});

describe("head reads", () => {
  it("head -n 25 README.md → read with head range", async () => {
    const r = await parseShellSemantic("head -n 25 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "head", count: 25 });
  });

  it("head README.md → read with the first 10 lines", async () => {
    const r = await parseShellSemantic("head README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "head", count: 10 });
  });

  it("head -n50 Cargo.toml → read with no space (Codex parity)", async () => {
    const r = await parseShellSemantic("head -n50 Cargo.toml");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "head", count: 50 });
  });

  it("head -20 README.md → read with compact count", async () => {
    const r = await parseShellSemantic("head -20 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "head", count: 20 });
  });
});

describe("tail reads", () => {
  it("tail -n +40 README.md → read with tail range", async () => {
    const r = await parseShellSemantic("tail -n +40 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 40 });
  });

  it("tail -n+10 README.md → read with no space (Codex parity)", async () => {
    const r = await parseShellSemantic("tail -n+10 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail", startLine: 10 });
  });

  it("tail -n 30 README.md → read with tail-count range (v2 parity)", async () => {
    const r = await parseShellSemantic("tail -n 30 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail-count", count: 30 });
  });

  it("tail README.md → read with the last 10 lines", async () => {
    const r = await parseShellSemantic("tail README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail-count", count: 10 });
  });

  it("tail -20 README.md → read with compact count", async () => {
    const r = await parseShellSemantic("tail -20 README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.range).toEqual({ type: "tail-count", count: 20 });
  });
});

// ---------------------------------------------------------------------------
// Pipeline reads
// ---------------------------------------------------------------------------

describe("pipe reads (should succeed as Read)", () => {
  it("cat file.txt | head -5 → read with filePath file.txt", async () => {
    const r = await parseShellSemantic("cat file.txt | head -5");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.kind).toBe("read");
    expect(v.filePath).toBe("file.txt");
  });

  it("cat tui/Cargo.toml | sed -n '1,200p' → read with filePath tui/Cargo.toml", async () => {
    const r = await parseShellSemantic("cat tui/Cargo.toml | sed -n '1,200p'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("tui/Cargo.toml");
  });

  it.each([
    ["nl -w 3 -s ': ' f.d | sed -n 2,4p", 3, ": ", "d"],
    ["git show HEAD:x.svg | nl -ba | sed -n 1,20p", 6, "\t", "xml"],
  ])(
    "preserves the gutter format for %s",
    async (command, width, separator, language) => {
      const result = await parseShellSemantic(command);
      expect(result.ok).toBe(true);
      if (!result.ok) return;
      expect(plan(result.value)?.blocks[0]?.format).toEqual({
        kind: "nl-line-number-prefixed",
        width,
        separator,
        format: { kind: "content", language },
      });
    },
  );

  it.each([
    ["nl -s '' f.d", "nl -s separator must not be empty"],
    ["nl -s 5 f.d", "nl -s separator must not start with a digit"],
    [
      "nl -ba -s 1x f.d | sed -n 1,2p",
      "nl -s separator must not start with a digit",
    ],
  ])(
    "rejects a separator that cannot delimit the gutter in %s",
    async (command, reason) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: false,
        code: "unsupported_option",
        reason,
      });
    },
  );

  it.each([
    ["LF", "\n"],
    ["CR", "\r"],
  ])("rejects an nl separator containing %s", async (_label, separator) => {
    await expect(
      parseShellSemantic(`nl -ba -s '${separator}' f.d | sed -n 1,2p`),
    ).resolves.toEqual({
      ok: false,
      code: "unsupported_option",
      reason: "nl -s separator must not contain a line terminator",
    });
  });

  it("nl -ba src/main.rs | sed -n '1200,1720p' → read with line numbers and selected range", async () => {
    const r = await parseShellSemantic(
      "nl -ba src/main.rs | sed -n '1200,1720p'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.rs");
    expect(v.range).toEqual({ type: "lines", start: 1200, end: 1720 });
    expect(v.presentation).toEqual({ lineNumbers: { style: "nl" } });
    expect(v.commandName).toBe("nl");
    expect(plan(r.value)?.blocks[0]?.source?.producerName).toBe("nl");
    expect(plan(r.value)?.blocks[0]?.format).toEqual({
      kind: "nl-line-number-prefixed",
      width: 6,
      separator: "\t",
      format: { kind: "content", language: "rust" },
    });
  });

  it("sed -n '260,640p' src/main.rs | nl -ba → reject (numbering after range is ambiguous)", async () => {
    const r = await parseShellSemantic(
      "sed -n '260,640p' src/main.rs | nl -ba",
    );
    expect(r).toMatchObject({
      ok: false,
      reason:
        "nl numbering of a sliced range would not match file line numbers",
    });
  });

  it("cat file.txt | wc -l → reject (opaque transform over file-read)", async () => {
    const r = await parseShellSemantic("cat file.txt | wc -l");
    expect(r).toMatchObject({ ok: false, reason: "wc output is not planned" });
  });

  it("cat file.txt | sort | head -5 → reject at the opaque stage", async () => {
    const r = await parseShellSemantic("cat file.txt | sort | head -5");
    expect(r).toMatchObject({
      ok: false,
      reason: "sort output is not planned",
    });
  });
});

describe("pipe reads (should reject)", () => {
  it("cat file.txt | rm -rf / → reject (rm is not formatting)", async () => {
    const r = await parseShellSemantic("cat file.txt | rm -rf /");
    expect(r.ok).toBe(false);
  });

  it("echo hello | cat → reject (no primary file operand)", async () => {
    const r = await parseShellSemantic("echo hello | cat");
    expect(r.ok).toBe(false);
  });

  it("cat file.txt | head -5 | tail -2 rejects a file-length-dependent range", async () => {
    await expect(
      parseShellSemantic("cat file.txt | head -5 | tail -2"),
    ).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason:
        "a last-lines slice of an already sliced range depends on the file length",
    });
  });
});

describe("stream composition", () => {
  it.each([
    ["tail -n +1 f.d | sed -n 1,5p", { type: "lines", start: 1, end: 5 }],
    ["sed -n 2,6p f.d | tail -n +1", { type: "lines", start: 2, end: 6 }],
  ])("preserves the sed range and producer for %s", async (command, range) => {
    const result = await parseShellSemantic(command);
    expect(result).toMatchObject({
      ok: true,
      value: { kind: "read", commandName: "sed", range },
    });
    if (!result.ok) return;
    expect(plan(result.value)?.blocks[0]).toMatchObject({
      id: "sed-output",
      source: { producerName: "sed" },
    });
  });

  it("sed followed by head selects the first three file lines", async () => {
    await expect(
      parseShellSemantic("cat file.txt | sed -n '1,20p' | head -3"),
    ).resolves.toMatchObject({
      ok: true,
      value: {
        kind: "read",
        commandName: "head",
        range: { type: "head", count: 3 },
      },
    });
  });

  it("rg followed by head preserves the search semantic", async () => {
    const direct = await parseShellSemantic("rg -n needle README.md");
    const sliced = await parseShellSemantic(
      "rg -n needle README.md | head -n 5",
    );
    expect(direct.ok).toBe(true);
    expect(sliced.ok).toBe(true);
    if (!direct.ok || !sliced.ok) return;
    expect(normalizeSemanticForComparison(sliced.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
  });

  it("searches a sliced file with rg", async () => {
    await expect(
      parseShellSemantic("sed -n '10,20p' file.txt | rg -n needle"),
    ).resolves.toMatchObject({
      ok: true,
      value: { kind: "search", filePath: "file.txt", pattern: "needle" },
    });
  });

  it.each([
    ["cat f.d | cat", "cat", { type: "all" }],
    ["cat f.d | head", "head", { type: "head", count: 10 }],
    [
      "cat f.d | head | sed -n 5,20p",
      "sed",
      { type: "lines", start: 5, end: 10 },
    ],
    ["head -n 5 f.d | tail", "head", { type: "head", count: 5 }],
    ["sed -n 2,6p f.d | head", "sed", { type: "lines", start: 2, end: 6 }],
    [
      "sed -n 10,20p f.d | head -5",
      "head",
      { type: "lines", start: 10, end: 14 },
    ],
    [
      "head -n 20 f.d | sed -n 5,8p",
      "sed",
      { type: "lines", start: 5, end: 8 },
    ],
    [
      "tail -n +10 f.d | head -n 3",
      "head",
      { type: "lines", start: 10, end: 12 },
    ],
    ["tail -n +10 f.d | tail -n +3", "tail", { type: "tail", startLine: 12 }],
    ["head -n 5 f.d | head -n 9", "head", { type: "head", count: 5 }],
    ["sed -n 2,6p f.d | head -n 9", "sed", { type: "lines", start: 2, end: 6 }],
    ["tail -n 3 f.d | head -n 5", "tail", { type: "tail-count", count: 3 }],
    ["tail -n 9 f.d | tail -n 3", "tail", { type: "tail-count", count: 3 }],
  ] as const)(
    "%s composes the read range and producer",
    async (command, commandName, range) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: true,
        value: {
          kind: "read",
          command,
          commandName,
          filePath: "f.d",
          range,
          presentation: { lineNumbers: false },
          steps: [
            {
              kind: "read-file",
              order: 0,
              commandName,
              filePath: "f.d",
              range,
              outputShape: {
                kind: "content",
                format: { kind: "content", language: "d" },
                validator: "non-empty",
              },
              blockId: commandName === "sed" ? "sed-output" : undefined,
            },
          ],
        },
      });
    },
  );

  it.each([
    ["nl f.d | head -5", { type: "head", count: 5 }],
    ["head -5 f.d | nl", { type: "head", count: 5 }],
    ["nl f.d | cat", { type: "all" }],
  ] as const)(
    "%s preserves nl as the numbered read producer",
    async (command, range) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: true,
        value: {
          kind: "read",
          command,
          commandName: "nl",
          filePath: "f.d",
          range,
          presentation: { lineNumbers: { style: "nl" } },
          steps: [
            {
              kind: "read-file",
              order: 0,
              commandName: "nl",
              filePath: "f.d",
              range,
              outputShape: {
                kind: "content",
                format: {
                  kind: "nl-line-number-prefixed",
                  width: 6,
                  separator: "\t",
                  format: { kind: "content", language: "d" },
                },
              },
            },
          ],
        },
      });
    },
  );

  it.each([
    [
      "tail -n +9007199254740991 f.d | tail -n +3",
      "line range exceeds integer precision",
    ],
    ["head -n 5 f.d | sed -n 7,9p", "slice selects no lines of its input"],
    [
      "tail f.d | head -5",
      "slicing the output of a last-lines slice depends on the file length",
    ],
    [
      "cat f.d | head | tail -n 2",
      "a last-lines slice of an already sliced range depends on the file length",
    ],
    [
      "sed -n 10,20p f.d | tail -n 3",
      "a last-lines slice of an already sliced range depends on the file length",
    ],
    [
      "tail -n 9 f.d | head -n 2",
      "slicing the output of a last-lines slice depends on the file length",
    ],
    [
      "sed -n 10,20p f.d | nl",
      "nl numbering of a sliced range would not match file line numbers",
    ],
    ["nl f.d | nl", "nested nl numbering is not supported"],
    ["nl f.d | grep -n x", "search over nl-numbered output is not supported"],
    ["nl f.d | wc -l", "wc output is not planned"],
    ["grep -n p f.d | nl", "nl numbering of search output is not supported"],
    ["grep -n p f.d | grep -n q", "search over search output is not supported"],
    ["grep -n p f.d | wc -l", "wc output is not planned"],
    ["git diff | grep -n x", "search over diff output is not supported"],
    ["cat f.d | head -n 2 g.d", "pipeline has multiple read stages"],
  ])("%s rejects with the failing stage's reason", async (command, reason) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason,
    });
  });

  it.each([
    "head -5 | tail -2",
    "sed -n 1,150p",
    "head -15",
    "tail -n 5",
    "tail -n +3",
    "head",
    "cat",
  ])("grep -n p f.d | %s preserves the search semantic", async (filters) => {
    const direct = await parseShellSemantic("grep -n p f.d");
    const filtered = await parseShellSemantic(`grep -n p f.d | ${filters}`);
    expect(direct.ok).toBe(true);
    expect(filtered.ok).toBe(true);
    if (!direct.ok || !filtered.ok) return;
    expect(normalizeSemanticForComparison(filtered.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
  });

  it.each([
    "sed -n 10,20p f.d | grep -n x",
    "tail -n 30 f.d | grep -n x",
    "git show HEAD:f.d | grep -n x | head -3",
  ])("%s preserves the search pattern and D output plan", async (command) => {
    const direct = await parseShellSemantic("grep -n x f.d");
    const composed = await parseShellSemantic(command);
    expect(composed).toMatchObject({
      ok: true,
      value: { kind: "search", pattern: "x", filePath: "f.d" },
    });
    expect(composed.ok).toBe(true);
    if (!direct.ok || !composed.ok) return;
    expect(normalizeSemanticForComparison(composed.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
    expect(plan(composed.value)?.blocks[0]?.format).toEqual({
      kind: "individual-lines",
      format: {
        kind: "line-number-prefixed",
        format: { kind: "content", language: "d" },
      },
    });
  });

  it.each([
    "git diff | nl | sed -n 1,5p",
    "git diff | sed -n 1,5p | nl",
    "git diff | cat",
  ])("%s preserves the diff semantic", async (command) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: true,
      value: { kind: "diff", commandName: "git", command, subcommand: "diff" },
    });
  });

  it("composes a read range over a git object without a worktree output plan", async () => {
    const command = "git show HEAD:f.d | sed -n 2,4p | head -2";
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: true,
      value: {
        kind: "read",
        command,
        commandName: "git",
        filePath: "f.d",
        range: { type: "lines", start: 2, end: 3 },
        presentation: { lineNumbers: false },
      },
    });
  });

  it("reports an opaque stage at the end of a 4,000-stage read pipeline", async () => {
    const command = [
      "cat file",
      ...Array<string>(3_998).fill("head -n 1"),
      "wc -l",
    ].join(" | ");
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "wc output is not planned",
    });
  }, 30_000);
});

describe("argv vs pipeline equivalence", () => {
  it("nl/read forms normalize to the same semantic", async () => {
    const direct = await parseShellSemantic("nl f.d");
    const viaPipe = await parseShellSemantic("cat f.d | nl");
    expect(direct.ok).toBe(true);
    expect(viaPipe.ok).toBe(true);
    if (!direct.ok || !viaPipe.ok) return;
    expect(normalizeSemanticForComparison(viaPipe.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
  });

  it("head/read forms normalize to the same semantic", async () => {
    const direct = await parseShellSemantic("head -n 20 README.md");
    const viaPipe = await parseShellSemantic("cat README.md | head -n 20");
    const viaCompact = await parseShellSemantic("cat README.md | head -20");
    expect(direct.ok).toBe(true);
    expect(viaPipe.ok).toBe(true);
    expect(viaCompact.ok).toBe(true);
    if (!direct.ok || !viaPipe.ok || !viaCompact.ok) return;
    expect(direct.value.kind).toBe("read");
    expect(viaPipe.value.kind).toBe("read");
    expect(viaCompact.value.kind).toBe("read");
    const d = direct.value as ShellReadSemantic;
    const p = viaPipe.value as ShellReadSemantic;
    const c = viaCompact.value as ShellReadSemantic;
    expect(p.filePath).toBe(d.filePath);
    expect(c.filePath).toBe(d.filePath);
    expect(p.range).toEqual(d.range);
    expect(c.range).toEqual(d.range);
    expect(p.presentation).toEqual(d.presentation);
    expect(c.presentation).toEqual(d.presentation);
  });

  it("sed/read forms normalize to the same semantic", async () => {
    const direct = await parseShellSemantic("sed -n '1,20p' README.md");
    const viaPipe = await parseShellSemantic("cat README.md | sed -n '1,20p'");
    expect(direct.ok).toBe(true);
    expect(viaPipe.ok).toBe(true);
    if (!direct.ok || !viaPipe.ok) return;
    expect(direct.value.kind).toBe("read");
    expect(viaPipe.value.kind).toBe("read");
    const d = direct.value as ShellReadSemantic;
    const p = viaPipe.value as ShellReadSemantic;
    expect(p.filePath).toBe(d.filePath);
    expect(p.range).toEqual(d.range);
    expect(p.presentation).toEqual(d.presentation);
  });

  it("rg/search forms normalize to the same semantic", async () => {
    const direct = await parseShellSemantic("rg -n needle README.md");
    const viaPipe = await parseShellSemantic("cat README.md | rg -n needle");
    expect(direct.ok).toBe(true);
    expect(viaPipe.ok).toBe(true);
    if (!direct.ok || !viaPipe.ok) return;
    expect(normalizeSemanticForComparison(viaPipe.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
  });

  it("grep/search forms normalize to the same semantic", async () => {
    const direct = await parseShellSemantic("grep -n needle README.md");
    const viaPipe = await parseShellSemantic("cat README.md | grep -n needle");
    expect(direct.ok).toBe(true);
    expect(viaPipe.ok).toBe(true);
    if (!direct.ok || !viaPipe.ok) return;
    expect(normalizeSemanticForComparison(viaPipe.value)).toEqual(
      normalizeSemanticForComparison(direct.value),
    );
  });
});

// ---------------------------------------------------------------------------
// cd + read patterns
// ---------------------------------------------------------------------------

describe("cd && read (should succeed)", () => {
  it("cd foo && cat file.txt → read with path foo/file.txt", async () => {
    const r = await parseShellSemantic("cd foo && cat file.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("foo/file.txt");
  });

  it("cd dir1 && cd dir2 && cat file.txt → read with path dir1/dir2/file.txt", async () => {
    const r = await parseShellSemantic("cd dir1 && cd dir2 && cat file.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("dir1/dir2/file.txt");
  });

  it("cd foo && cat f.d | sed -n 1,150p → read with a D output plan", async () => {
    const r = await parseShellSemantic("cd foo && cat f.d | sed -n 1,150p");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value).toMatchObject({
      kind: "read",
      filePath: "foo/f.d",
      range: { type: "lines", start: 1, end: 150 },
    });
    expect(plan(r.value)?.blocks[0]?.format).toEqual({
      kind: "content",
      language: "d",
    });
  });

  it("cd foo && grep -n pat f.d → search with a cd-resolved output plan", async () => {
    const r = await parseShellSemantic("cd foo && grep -n pat f.d");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value).toMatchObject({ kind: "search", filePath: "foo/f.d" });
    expect(plan(r.value)?.blocks[0]?.source?.filePath).toBe("foo/f.d");
  });

  it("resolves a pipeline against the cd directory at the pipeline", async () => {
    const result = await parseShellSemantic("cd x && cat f | head -5 && cd y");
    expect(result).toMatchObject({
      ok: true,
      value: { kind: "read", filePath: "x/f" },
    });
    if (!result.ok) return;
    expect(plan(result.value)?.blocks[0]?.source?.filePath).toBe("x/f");
  });

  it.each([
    "cat f && cd",
    "cd x && cat f && cd",
    "cd x && cat f | head -5 && cd",
    "grep -n pat f && cd",
    "git diff && cd",
  ])("rejects the missing cd target in %s", async (command) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "cd target must be a literal path",
    });
  });

  it("cd foo && cat f | sed -n 1,5p && echo done → structured output", async () => {
    await expect(
      parseShellSemantic("cd foo && cat f | sed -n 1,5p && echo done"),
    ).resolves.toMatchObject({
      ok: true,
      value: {
        kind: "structured-output",
        steps: [
          {
            kind: "read-file",
            filePath: "foo/f",
            range: { type: "lines", start: 1, end: 5 },
          },
          {
            kind: "plain-output",
            commandName: "echo",
            outputShape: { kind: "literal", text: "done\n" },
          },
        ],
      },
    });
  });

  it.each([
    ["cd /a && cd /b && cat f", "/b/f"],
    ["cd x && cat /abs/f", "/abs/f"],
  ])("%s → read with absolute path %s", async (command, filePath) => {
    await expect(parseShellSemantic(command)).resolves.toMatchObject({
      ok: true,
      value: { kind: "read", filePath },
    });
  });
});

describe("cd && read (should reject)", () => {
  it.each([
    "git show HEAD:f && cat f",
    "cat f && git show HEAD:f",
    "git show HEAD:f | sed -n 1,2p && echo done",
  ])("rejects the git-object read in %s", async (command) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsupported_command",
      reason: "git object reads cannot be combined with other list output",
    });
  });

  it.each(["git diff && cat f", "cat f && git diff", "diff a b && cat f"])(
    "rejects the diff output in %s",
    async (command) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: false,
        code: "unsupported_command",
        reason: "diff output cannot be combined with other list output",
      });
    },
  );

  it("rejects a numbered git-object read combined with other list output", async () => {
    await expect(
      parseShellSemantic("git show HEAD:f | nl && echo done"),
    ).resolves.toMatchObject({
      ok: false,
      reason: "git object reads cannot be combined with other list output",
    });
  });

  it("rejects a numbered git-object read under cd", async () => {
    await expect(
      parseShellSemantic("cd x && git show HEAD:x.svg | nl -ba | sed -n 1,20p"),
    ).resolves.toMatchObject({
      ok: false,
      reason: "git object paths are not relative to cd",
    });
  });

  it("cd foo && echo hello → reject (echo is not a read command)", async () => {
    const r = await parseShellSemantic("cd foo && echo hello");
    expect(r.ok).toBe(false);
  });

  it.each([
    ["cd x && git show HEAD:f", "git object paths are not relative to cd"],
    ["cd x && cat f | wc -l", "wc output is not planned"],
    [
      "cd x && git diff | cat && echo y",
      "diff output cannot be combined with other list output",
    ],
  ])("%s → reject with reason %s", async (command, reason) => {
    await expect(parseShellSemantic(command)).resolves.toMatchObject({
      ok: false,
      reason,
    });
  });

  it("cd foo && cat file.txt && echo done → structured-output (echo is recognized)", async () => {
    const r = await parseShellSemantic("cd foo && cat file.txt && echo done");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
  });
});

// ---------------------------------------------------------------------------
// cd newline-separated (bare \n treated same as &&)
// ---------------------------------------------------------------------------

describe("cd newline-separated read (should succeed)", () => {
  it("cd dir\\ncat file.md → same as cd dir && cat file.md", async () => {
    const r = await parseShellSemantic("cd dir\ncat file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.kind).toBe("read");
    expect(v.filePath).toBe("dir/file.md");
  });

  it("cd a\\ncd b\\ncat x.md → resolves to a/b/x.md", async () => {
    const r = await parseShellSemantic("cd a\ncd b\ncat x.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("a/b/x.md");
  });
});

describe("cd newline-separated read (should reject)", () => {
  it("cd dir\\necho x → reject (echo not a read command)", async () => {
    const r = await parseShellSemantic("cd dir\necho x");
    expect(r.ok).toBe(false);
  });

  it("unknown_cmd arg\\nunknown2 arg → reject (unsupported multiline)", async () => {
    const r = await parseShellSemantic("unknown_cmd arg\nunknown2 arg");
    expect(r.ok).toBe(false);
  });
});

describe("structured list output boundaries", () => {
  it.each([
    "cat a.md\ncat b.md",
    "cat a.md && cat b.md",
    "cd . && nl -ba f.svg | sed -n 1,20p && cat empty",
    "echo same && cat a && echo same",
  ])("rejects an ambiguous output plan for %s", async (command) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsupported_command",
      reason: "shell output steps do not define an unambiguous output plan",
    });
  });
});

// ---------------------------------------------------------------------------
// echo as a literal anchor in lists (R6)
// ---------------------------------------------------------------------------

describe("echo in lists (R6: unified classifier)", () => {
  it("echo x && cat file.md → structured-output with literal + content blocks", async () => {
    const r = await parseShellSemantic('echo "hello" && cat file.md');
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const p = plan(r.value);
    expect(p?.blocks).toHaveLength(2);
    expect(p?.blocks[0]?.location.kind).toBe("unique-literal");
    expect(p?.blocks[1]?.location.kind).toBe("from-cursor");
  });

  it("echo x\\ncat file.md → structured-output (newline-separated)", async () => {
    const r = await parseShellSemantic("echo x\ncat file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const p = plan(r.value);
    expect(p?.blocks).toHaveLength(2);
    expect(p?.blocks[0]?.location.kind).toBe("unique-literal");
  });

  it("echo a b c\\ncat file.md → args joined with spaces in literal text", async () => {
    const r = await parseShellSemantic("echo a b c\ncat file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const echoStep = r.value.steps?.find(
      (s) => s.kind !== "write-file" && s.commandName === "echo",
    );
    expect(
      echoStep?.outputShape.kind === "literal"
        ? echoStep.outputShape.text
        : null,
    ).toBe("a b c\n");
  });

  it("echo -n x\\ncat file.md → reject (flag echo)", async () => {
    const r = await parseShellSemantic("echo -n x\ncat file.md");
    expect(r.ok).toBe(false);
  });

  it("echo $VAR\\ncat file.md → reject (dynamic value)", async () => {
    const r = await parseShellSemantic("echo $VAR\ncat file.md");
    expect(r.ok).toBe(false);
  });

  it("cd dir && echo x && cat file.md → cd-resolved structured-output", async () => {
    const r = await parseShellSemantic("cd dir && echo x && cat file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const catStep = r.value.steps?.find(
      (s) => s.kind !== "write-file" && s.commandName === "cat",
    );
    expect(catStep?.kind === "read-file" ? catStep.filePath : null).toBe(
      "dir/file.md",
    );
    expect(r.value.steps).toHaveLength(2);
  });

  it("cd dir\\necho x\\ncat file.md → same via newline path", async () => {
    const r = await parseShellSemantic("cd dir\necho x\ncat file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const catStep = r.value.steps?.find(
      (s) => s.kind !== "write-file" && s.commandName === "cat",
    );
    expect(catStep?.kind === "read-file" ? catStep.filePath : null).toBe(
      "dir/file.md",
    );
  });

  it("cd dir && echo x → reject (no read-file step)", async () => {
    const r = await parseShellSemantic("cd dir && echo x");
    expect(r.ok).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Accepted heredoc write forms
// ---------------------------------------------------------------------------

describe("heredoc writes", () => {
  it.each(["café.md", "漢字.md", "🧪.md"])(
    "classifies a heredoc write to the bare Unicode path %s",
    async (path) => {
      const source = `cat >${path} <<EOF\nbody\nEOF`;
      await expect(parseShellSemantic(source)).resolves.toMatchObject({
        ok: true,
        value: { kind: "write", filePath: path, heredoc: { content: "body" } },
      });
    },
  );

  it("cat > README.md <<EOF\\n# Title\\nEOF → write", async () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.content).toBe("# Title");
    expect(v.heredoc.quoted).toBe(false);
  });

  it("cat <<'EOF' > README.md\\n# Title\\nEOF → write with quoted heredoc", async () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    const v = r.value as ShellHeredocWriteSemantic;
    expect(v.filePath).toBe("README.md");
    expect(v.heredoc.quoted).toBe(true);
  });

  it("heredoc segments concatenate back to the original command", async () => {
    const cmd = "cat > README.md <<EOF\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });

  it("quoted heredoc segments concatenate back to the original command", async () => {
    const cmd = "cat <<'EOF' > README.md\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellHeredocWriteSemantic;
    const reconstructed = v.segments.map((s) => s.text).join("");
    expect(reconstructed).toBe(cmd);
  });

  it.each([
    ["sed", "sed -n '1,2p' README.md <<EOF\nignored\nEOF"],
    ["git diff", "git diff --no-index - README.md <<EOF\nold contents\nEOF"],
  ] as const)(
    "rejects a heredoc on %s before read or diff lowering",
    async (_commandName, command) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: false,
        code: "unsupported_command",
        reason: "unsupported heredoc command",
      });
    },
  );
});

// ---------------------------------------------------------------------------
// sh -c/-lc wrapper unwrapping (Codex commandExecution wraps commands this way)
// ---------------------------------------------------------------------------

describe("shell -c/-lc wrapper unwrapping", () => {
  it("sh -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("sh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("sh -c 'head -n 10 src/main.ts' → read with head range", async () => {
    const r = await parseShellSemantic("sh -c 'head -n 10 src/main.ts'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.ts");
    expect(v.range).toEqual({ type: "head", count: 10 });
  });

  it("bash -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("keeps a terminal Bash-wrapper semicolon as unsupported wrapper structure", async () => {
    await expect(
      parseShellSemantic("bash -c 'cat README.md';"),
    ).resolves.toEqual({
      ok: false,
      code: "unsupported_command",
      reason: "unsupported shell wrapper structure",
    });
  });

  it("zsh -c 'cat README.md' → read", async () => {
    const r = await parseShellSemantic("zsh -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("zsh -lc 'cat README.md' → read (login shell flag)", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/bash -c 'cat README.md' → read (absolute path)", async () => {
    const r = await parseShellSemantic("/bin/bash -c 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/bin/zsh -lc 'sed -n '1,10p' Cargo.toml' → read", async () => {
    const r = await parseShellSemantic(
      `/bin/zsh -lc "sed -n '1,10p' Cargo.toml"`,
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("Cargo.toml");
    expect(v.range).toEqual({ type: "lines", start: 1, end: 10 });
  });

  it("/run/current-system/sw/bin/zsh -c 'cat README.md' → read (NixOS path)", async () => {
    const r = await parseShellSemantic(
      "/run/current-system/sw/bin/zsh -c 'cat README.md'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("/nix/store/abc-bash-5.2/bin/bash -lc 'head -n 5 file.ts' → read (Nix store path)", async () => {
    const r = await parseShellSemantic(
      "/nix/store/abc-bash-5.2/bin/bash -lc 'head -n 5 file.ts'",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.ts");
    expect(v.range).toEqual({ type: "head", count: 5 });
  });
});

describe("wrapped inline script execution", () => {
  it.each([
    [`bash -lc 'python3 -c "print(1)"'`, "python3", "python", "-c", "print(1)"],
    [
      `zsh -lc 'node -e "console.log(1)"'`,
      "node",
      "javascript",
      "-e",
      "console.log(1)",
    ],
    [
      `bash -lc 'python3 -c "print(1)"' >/tmp/outer.log`,
      "python3",
      "python",
      "-c",
      "print(1)",
    ],
    [
      `zsh -lc 'node -e "console.log(1)"' >/tmp/outer.log`,
      "node",
      "javascript",
      "-e",
      "console.log(1)",
    ],
  ] as const)(
    "preserves exact outer command metadata for one shell wrapper: %s",
    async (command, commandName, language, flag, content) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("script-exec");
      if (result.value.kind !== "script-exec") return;

      expect(result.value).toMatchObject({
        command,
        commandName,
        language,
        scriptSource: {
          type: "inline",
          flag,
          content,
        },
      });
      expect(result.value).not.toHaveProperty("source");
      expect(result.value).not.toHaveProperty("sourceTree");
    },
  );
});

// ---------------------------------------------------------------------------
// Rejected forms
// ---------------------------------------------------------------------------

describe("rejected forms", () => {
  it("substitution: cat $(pwd)/README.md → reject", async () => {
    const r = await parseShellSemantic("cat $(pwd)/README.md");
    expect(r.ok).toBe(false);
  });

  it("variable: cat $FILE → reject", async () => {
    const r = await parseShellSemantic("cat $FILE");
    expect(r.ok).toBe(false);
  });

  it('variable: cat "$FILE" → reject', async () => {
    const r = await parseShellSemantic('cat "$FILE"');
    expect(r.ok).toBe(false);
  });

  it('variable: head -n 5 "$FILE" → reject', async () => {
    const r = await parseShellSemantic('head -n 5 "$FILE"');
    expect(r.ok).toBe(false);
  });

  it("multiple paths: cat README.md package.json → reject (multiple_paths)", async () => {
    const r = await parseShellSemantic("cat README.md package.json");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("multiple_paths");
  });

  it("redirection on read: cat README.md > out.txt → reject (redirection_on_read)", async () => {
    const r = await parseShellSemantic("cat README.md > out.txt");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("redirection_on_read");
  });

  it("invalid range: sed -n '20,10p' README.md → reject (invalid_range)", async () => {
    const r = await parseShellSemantic("sed -n '20,10p' README.md");
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("invalid_range");
  });

  it("wc file.txt → reject (no precise read semantic)", async () => {
    const r = await parseShellSemantic("wc file.txt");
    expect(r.ok).toBe(false);
  });

  it("head -0 README.md → reject (zero count is invalid)", async () => {
    const r = await parseShellSemantic("head -0 README.md");
    expect(r.ok).toBe(false);
  });

  it("head -n0 README.md → reject (zero count is invalid)", async () => {
    const r = await parseShellSemantic("head -n0 README.md");
    expect(r.ok).toBe(false);
  });

  it("tail -0 README.md → reject (zero count is invalid)", async () => {
    const r = await parseShellSemantic("tail -0 README.md");
    expect(r.ok).toBe(false);
  });

  it("tail -n0 README.md → reject (zero count is invalid)", async () => {
    const r = await parseShellSemantic("tail -n0 README.md");
    expect(r.ok).toBe(false);
  });

  it("variable in heredoc: cat <<EOF > $FILE\\nhello\\nEOF → reject", async () => {
    const r = await parseShellSemantic("cat <<EOF > $FILE\nhello\nEOF");
    expect(r.ok).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// git diff / git show / git log -p / diff binary (ShellDiffSemantic)
// ---------------------------------------------------------------------------

describe("git diff commands (should succeed as diff)", () => {
  it("git diff → diff, subcommand: diff", async () => {
    const r = await parseShellSemantic("git diff");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.commandName).toBe("git");
    expect(v.subcommand).toBe("diff");
  });

  it("git diff HEAD~1 → diff", async () => {
    const r = await parseShellSemantic("git diff HEAD~1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff --cached → diff", async () => {
    const r = await parseShellSemantic("git diff --cached");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff --staged → diff", async () => {
    const r = await parseShellSemantic("git diff --staged");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff branch1..branch2 → diff", async () => {
    const r = await parseShellSemantic("git diff branch1..branch2");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git show abc123 → diff, subcommand: show", async () => {
    const r = await parseShellSemantic("git show abc123");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.subcommand).toBe("show");
  });

  it("git log -p -1 → diff, subcommand: log", async () => {
    const r = await parseShellSemantic("git log -p -1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.subcommand).toBe("log");
  });

  it("git log --patch -1 → diff", async () => {
    const r = await parseShellSemantic("git log --patch -1");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("diff binary (should succeed as diff)", () => {
  it("diff -u old.txt new.txt → diff, commandName: diff", async () => {
    const r = await parseShellSemantic("diff -u old.txt new.txt");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
    const v = r.value as ShellDiffSemantic;
    expect(v.commandName).toBe("diff");
  });

  it("diff file1 file2 → diff", async () => {
    const r = await parseShellSemantic("diff file1 file2");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("git show HEAD:file (should succeed as read)", () => {
  it("git show HEAD:src/main.ts → read, filePath: src/main.ts", async () => {
    const r = await parseShellSemantic("git show HEAD:src/main.ts");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("src/main.ts");
  });

  it("git show abc123:README.md → read, filePath: README.md", async () => {
    const r = await parseShellSemantic("git show abc123:README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("README.md");
  });
});

describe("git diff pipelines (should succeed as diff)", () => {
  it("git diff | head -100 → diff (pipeline with formatting)", async () => {
    const r = await parseShellSemantic("git diff | head -100");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff | sed -n '1,260p' → diff (pipeline with formatting)", async () => {
    const r = await parseShellSemantic("git diff | sed -n '1,260p'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff | sort | uniq → diff (opaque transforms over diff at any depth)", async () => {
    const r = await parseShellSemantic("git diff | sort | uniq");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("git diff | head -n 5 | sort → diff (mixed transforms over diff)", async () => {
    const r = await parseShellSemantic("git diff | head -n 5 | sort");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });
});

describe("unsupported git commands (should reject)", () => {
  it("git push origin main → reject", async () => {
    const r = await parseShellSemantic("git push origin main");
    expect(r.ok).toBe(false);
  });

  it("git commit -m 'msg' → reject", async () => {
    const r = await parseShellSemantic("git commit -m 'msg'");
    expect(r.ok).toBe(false);
  });

  it("git log (without -p) → reject", async () => {
    const r = await parseShellSemantic("git log");
    expect(r.ok).toBe(false);
  });
});

describe("shell wrapper with git/diff commands", () => {
  it("sh -c 'git diff' → diff", async () => {
    const r = await parseShellSemantic("sh -c 'git diff'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("diff");
  });

  it("bash -lc 'git show HEAD:file.ts' → read", async () => {
    const r = await parseShellSemantic("bash -lc 'git show HEAD:file.ts'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    const v = r.value as ShellReadSemantic;
    expect(v.filePath).toBe("file.ts");
  });
});

// ---------------------------------------------------------------------------
// Script execution — heredoc
// ---------------------------------------------------------------------------

describe("script-exec: heredoc", () => {
  it("python - <<'PY' → script-exec, language python", async () => {
    const cmd = "python - <<'PY'\nimport json\nprint(\"hi\")\nPY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.commandName).toBe("python");
    expect(v.scriptSource.type).toBe("heredoc");
    if (v.scriptSource.type === "heredoc") {
      expect(v.scriptSource.content).toBe('import json\nprint("hi")');
      expect(v.scriptSource.quoted).toBe(true);
      expect(v.scriptSource.delimiter).toBe("PY");
    }
  });

  it("python3 - <<'PYTHON' → script-exec, language python", async () => {
    const cmd = "python3 - <<'PYTHON'\nprint(\"hello\")\nPYTHON";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.commandName).toBe("python3");
  });

  it("node - <<'JS' → script-exec, language javascript", async () => {
    const cmd = "node - <<'JS'\nconsole.log(42)\nJS";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("javascript");
    expect(v.commandName).toBe("node");
  });

  it("ruby - <<'RUBY' → script-exec, language ruby", async () => {
    const cmd = "ruby - <<'RUBY'\nputs \"hello\"\nRUBY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("ruby");
  });

  it("ruby - <<RUBY (unquoted delimiter) → script-exec", async () => {
    const cmd = 'ruby - <<RUBY\nputs "hello"\nRUBY';
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    if (v.scriptSource.type === "heredoc") {
      expect(v.scriptSource.quoted).toBe(false);
    }
  });

  it("segments concatenate back to original command", async () => {
    const cmd = "python3 - <<'PY'\nprint(42)\nPY";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const v = r.value as ShellScriptExecSemantic;
    const joined = v.segments.map((s) => s.text).join("");
    // header ends with \n, content is the body, footer starts with \n
    expect(joined).toBe("python3 - <<'PY'\nprint(42)\nPY");
  });
});

// ---------------------------------------------------------------------------
// Script execution — inline -c/-e
// ---------------------------------------------------------------------------

describe("script-exec: inline", () => {
  it("python3 -c '...' → script-exec, language python", async () => {
    const cmd = "python3 -c 'import sys; print(sys.version)'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("python");
    expect(v.scriptSource.type).toBe("inline");
    if (v.scriptSource.type === "inline") {
      expect(v.scriptSource.flag).toBe("-c");
      expect(v.scriptSource.content).toBe("import sys; print(sys.version)");
    }
  });

  it("node -e 'console.log(42)' → script-exec, language javascript", async () => {
    const cmd = "node -e 'console.log(42)'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("javascript");
    if (v.scriptSource.type === "inline") {
      expect(v.scriptSource.flag).toBe("-e");
    }
  });

  it("perl -e 'print \"hello\\n\"' → script-exec, language perl", async () => {
    const cmd = "perl -e 'print \"hello\\n\"'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    const v = r.value as ShellScriptExecSemantic;
    expect(v.language).toBe("perl");
  });
});

// ---------------------------------------------------------------------------
// Script execution — rejections
// ---------------------------------------------------------------------------

describe("script-exec: rejections", () => {
  it("python script.py → reject (running a file, not embedding code)", async () => {
    const r = await parseShellSemantic("python script.py");
    expect(r.ok).toBe(false);
  });

  it("unknown_interpreter - <<'EOF' → reject (not in INTERPRETER_LANG)", async () => {
    const cmd = "unknown_interpreter - <<'EOF'\ncode\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
  });
});

describe("source tree parsing and invariants", () => {
  it("does not classify wrappers with bare atomic-close suffix arguments", async () => {
    for (const source of ["cat >&- x", "cat <&- x", "bash -c 'echo x' >&- x"]) {
      const result = await parseShellSemantic(source);
      expect(result.ok, source).toBe(false);
    }
  });

  it("keeps adjacent fd-zero redirects on the typed raw semantic path", async () => {
    for (const source of [
      "cat >a 0>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0>&1",
      "cat >a 0<&1",
      "cat >a 01>/tmp/output.py",
      "bash -c 'cat >a 0>/tmp/output.py'",
      "cat >a 0>/tmp/output.py 1>&2",
    ]) {
      const result = await parseShellSemantic(source);
      expect(result.ok, source).toBe(false);
    }
  });

  it("rejects adjacent numeric descriptors across line continuations", async () => {
    for (const source of [
      "cat 0\\\n>out",
      "cat 0\\\r\n>out",
      "cat 01\\\n>out",
      "cat 01\\\r\n>out",
      "cat >a 0\\\n>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0\\\r\n>/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
      "cat <<EOF 0\\\n>/tmp/output.py\nprint(1)\nEOF",
      "cat <<EOF 0\\\r\n>/tmp/output.py\r\nprint(1)\r\nEOF",
    ]) {
      const result = await parseShellSemantic(source);
      expect(result, source).toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    }
  });

  it("keeps a whitespace boundary before a continuation numeric argument", async () => {
    for (const source of ["cat >a 0 \\\n>out", "cat >a 0 \\\r\n>out"]) {
      const result = await parseShellSemantic(source);
      expect(result, source).not.toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    }
  });

  it("maps continued variable descriptors to unsafe shell syntax", async () => {
    for (const source of ["cat {fd}\\\n>out", "cat {fd}\\\r\n>out"]) {
      await expect(parseShellSemantic(source)).resolves.toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    }
  });

  it("does not classify words from later prefix channels as a wrapper", async () => {
    for (const source of [
      "{fd}\\\n>one echo >two bash -c 'echo hi'",
      "{fd}\\\r\n>one echo >two bash -c 'echo hi'",
      "{fd}\\\n>&- echo hi",
      "{fd}\\\r\n>&- echo hi",
      "{fd}\\\n<&- echo hi",
      "{fd}\\\r\n<&- echo hi",
    ]) {
      const result = await parseShellSemantic(source);
      expect(result, source).not.toMatchObject({
        ok: true,
        value: { kind: "read" },
      });
    }
    for (const source of [
      "{a}\\\n>one {b} \\\n>two cat >/tmp/output.py <<EOF\nprint(1)\nEOF",
      "{a}\\\r\n>one {b} \\\r\n>two cat >/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
    ]) {
      expect(await parseShellSemantic(source), source).not.toMatchObject({
        ok: true,
        value: { kind: "read" },
      });
    }
  });

  it("rejects unaccounted anonymous recovered-prefix children", async () => {
    for (const source of [
      "{fd}\\\n>one bash -c 'echo hi' )",
      "{fd}\\\r\n>one bash -c 'echo hi' )",
      "{fd}\\\n>one echo >two )",
      "{fd}\\\r\n>one echo >two )",
      "{fd}\\\n>one echo >two $(",
      "{fd}\\\r\n>one echo >two $(",
    ]) {
      await expect(parseShellSemantic(source)).resolves.toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    }
  });

  it("rejects malformed atomic-close error fragments", async () => {
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const fragments = ['""(', '"" )', '""`'] as const;
    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const fragment of fragments) {
          const source = `cat ${descriptor}${operator}${fragment} extra`;
          await expect(parseShellSemantic(source)).resolves.toMatchObject({
            ok: false,
            code: "unsafe_shell_syntax",
          });
        }
      }
    }
    for (const source of [
      'cat >/tmp/output.py 2>&-""( extra <<EOF\nprint(1)\nEOF',
      'cat >/tmp/output.py 2>&-""( extra <<EOF\r\nprint(1)\r\nEOF',
    ]) {
      await expect(parseShellSemantic(source)).resolves.toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    }
  });

  it("rejects orphaned nonempty atomic-close continuation fragments", async () => {
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const lineEndings = ["\n", "\r\n"] as const;
    const fragments = ["x", '"x"', "$(printf x)"] as const;

    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const lineEnding of lineEndings) {
          for (const fragment of fragments) {
            for (const source of [
              `: ${descriptor}${operator}\\${lineEnding}${fragment}`,
              `bash -c 'echo hi' ${descriptor}${operator}\\${lineEnding}${fragment}`,
              `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${fragment} <<EOF${lineEnding}print(1)${lineEnding}EOF`,
            ]) {
              await expect(parseShellSemantic(source)).resolves.toMatchObject({
                ok: false,
                code: "unsafe_shell_syntax",
              });
            }
          }
        }
      }
    }
  });

  it("rejects malformed atomic-close errors after continued empty fragments", async () => {
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const lineEndings = ["\n", "\r\n"] as const;
    const fragments = ['""(', '"" )', '""`'] as const;

    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const lineEnding of lineEndings) {
          for (const fragment of fragments) {
            for (const source of [
              `: ${descriptor}${operator}\\${lineEnding}${fragment} extra`,
              `bash -c 'echo hi' ${descriptor}${operator}\\${lineEnding}${fragment} extra`,
              `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${fragment} extra <<EOF${lineEnding}print(1)${lineEnding}EOF`,
            ]) {
              await expect(parseShellSemantic(source)).resolves.toMatchObject({
                ok: false,
                code: "unsafe_shell_syntax",
              });
            }
          }
        }
      }
    }
  });

  it("maps continued atomic closes to unsafe shell syntax", async () => {
    await expect(parseShellSemantic(': >&-\\\n\\"\\"')).resolves.toMatchObject({
      ok: false,
      code: "unsafe_shell_syntax",
    });
  });

  it("maps ambiguous redirect ownership to a typed semantic rejection", async () => {
    const parsed = await loadParsedShellDocument("cat >{fd}>b");
    expect(parsed).toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
    const semantic = await parseShellSemantic("cat >{fd}>b");
    expect(semantic).toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "shell parser rejected syntax: error_node",
    });
  });

  it("quoted wrapper command parses to a root shell node with payload embed", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.value.language).toBe("bash");
    expect(parsed.value.text).toBe(cmd);
    const payload = parsed.value.segments.find((s) => s.kind === "embed");
    expect(payload?.kind).toBe("embed");
    if (!payload) return;
    expect(parsed.value.text.slice(payload.span.start, payload.span.end)).toBe(
      'program --some-flag -y "hello world"',
    );
    expect(payload.content.language).toBe("bash");
    expect(payload.content.text).toBe('program --some-flag -y "hello world"');
  });

  it("double-quoted wrapper command keeps raw escaped source span", async () => {
    const cmd =
      '/run/current-system/sw/bin/zsh -lc "nl -ba source/cydo/app.d | sed -n \'720,790p\' && rg -n \\"CYDO_SKIP_LOAD_TASKS\\" -n source tests"';
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.value.text).toBe(cmd);
    const payload = parsed.value.segments.find((s) => s.kind === "embed");
    expect(payload?.kind).toBe("embed");
    if (!payload) return;

    expect(parsed.value.text.slice(payload.span.start, payload.span.end)).toBe(
      "nl -ba source/cydo/app.d | sed -n '720,790p' && rg -n \\\"CYDO_SKIP_LOAD_TASKS\\\" -n source tests",
    );
    expect(payload.content.text).toBe(
      "nl -ba source/cydo/app.d | sed -n '720,790p' && rg -n \"CYDO_SKIP_LOAD_TASKS\" -n source tests",
    );
  });

  it("wrapper payload command remains semantic unsupported_command", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe("unsupported_command");
  });

  it("wrapped python heredoc creates nested wrapper + heredoc embeds", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint('x')\nPY\"";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find((s) => s.kind === "embed");
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;
    const heredoc = wrapper.content.segments.find((s) => s.kind === "embed");
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;
    expect(heredoc.origin).toEqual({
      language: "bash",
      construct: "heredoc-body",
      attributes: {
        delimiter: "PY",
        quoted: true,
        supportsExitReentry: false,
      },
    });
    expect(heredoc.presentation).toEqual({ kind: "rich" });
    expect(heredoc.content.language).toBe("python");
    expect(heredoc.content.text).toBe("print('x')");
    expect(parsed.value.text).toBe(cmd);
  });

  it("segment spans are offsets into each containing node text", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    for (const segment of parsed.value.segments) {
      const parentSlice = parsed.value.text.slice(
        segment.span.start,
        segment.span.end,
      );
      expect(parentSlice.length).toBe(segment.span.end - segment.span.start);
      if (segment.kind === "embed") {
        expect(segment.content.text).toBe("# Title");
      }
    }
  });

  it("dynamic double-quoted wrapper payload rejects source-tree parsing", async () => {
    const parsed = await loadParsedShellDocument(
      '/run/current-system/sw/bin/zsh -lc "cat $HOME/README.md"',
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(buildShellSourceTree(parsed.document)).toMatchObject({ ok: false });
  });

  it("multiple heredocs and <<- remain rejected safely", async () => {
    const multiple = await loadParsedShellDocument(
      "cat <<'A'\na\nA\ncat <<'B'\nb\nB",
    );
    expect(multiple.ok).toBe(false);
    const tabs = await loadParsedShellDocument("cat <<-EOF\nx\nEOF");
    expect(tabs.ok).toBe(false);
    const missing = await loadParsedShellDocument("cat <<'EOF'\nhello");
    expect(missing.ok).toBe(false);
  });

  it("quoted << literal remains parseable and keeps search semantic behavior", async () => {
    const cmd = "rg -n '<<' web/src/lib/sourceTree.ts";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const semantic = await parseShellSemantic(cmd);
    expect(semantic.ok).toBe(true);
    if (!semantic.ok) return;
    expect(semantic.value.kind).toBe("search");
  });
});

describe("whole-command shell wrapper semantic unwrapping", () => {
  it.each([
    "zsh -lc 'cat README.md'",
    "env FOO=1 zsh -lc 'cat README.md'",
    "zsh -lc 'cat README.md' 2>/dev/null",
  ])("unwraps %s", async (command) => {
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.kind).toBe("read");
    expect((result.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it.each([
    "cd /tmp && zsh -lc 'cat README.md'",
    "echo before && zsh -lc 'cat README.md'",
    "zsh -lc 'cat README.md' && echo after",
    "echo before | zsh -lc 'cat README.md'",
    "zsh -lc 'cat README.md' | cat",
    "zsh -lc 'cat README.md'; echo after",
    "zsh -lc 'cat README.md'\necho after",
    ">prefix zsh -lc 'cat README.md'",
  ])("does not unwrap compound source %s", async (command) => {
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(false);
    if (!result.ok && !command.startsWith(">prefix"))
      expect(result.code).toBe("unsupported_command");
  });

  it("keeps recursive direct wrappers in the existing unsupported semantic path", async () => {
    const result = await parseShellSemantic(
      "zsh -lc \"bash -lc 'cat README.md'\"",
    );
    expect(result).toEqual({
      ok: false,
      code: "unsupported_command",
      reason:
        "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
    });
  });
});

describe("batch 1 wrapper quoting and heredoc source preservation", () => {
  it("zsh -cl wrapper is supported", async () => {
    const r = await parseShellSemantic("zsh -cl 'cat README.md'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("single-quoted wrapper payload supports close/escape/reopen syntax", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat '\\''README.md'\\'''");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.md");
  });

  it("adjacent wrapper payload fragments are parsed as one argv word", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat README.md''x'");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect((r.value as ShellReadSemantic).filePath).toBe("README.mdx");
  });

  it("wrapper payload split by whitespace is rejected as extra argv", async () => {
    const r = await parseShellSemantic("zsh -lc 'cat README.md' 'x'");
    expect(r.ok).toBe(false);
  });

  it("conservative double-quoted wrapper rejects dynamic expansions", async () => {
    const bad = [
      '/run/current-system/sw/bin/zsh -lc "cat $HOME/README.md"',
      '/run/current-system/sw/bin/zsh -lc "cat $(pwd)/README.md"',
      '/run/current-system/sw/bin/zsh -lc "cat ${x}"',
      '/run/current-system/sw/bin/zsh -lc "cat `pwd`/README.md"',
    ];
    for (const cmd of bad) {
      const r = await parseShellSemantic(cmd);
      expect(r.ok).toBe(false);
    }
  });

  it("wrapped python heredoc preserves exact command and wrapper segments", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint('x')\nPY\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("script-exec");
    expect(r.value.command).toBe(cmd);
  });

  it("wrapped markdown heredoc with trailing ls -l && sed gets output plan", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\nls -l /tmp/a/output.md && sed -n '1,80p' /tmp/a/output.md\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    expect(plan(r.value)?.blocks.map((b: { id: string }) => b.id)).toEqual([
      "listing",
      "sed-output",
    ]);
    expect(plan(r.value)?.blocks[1]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("wrapped markdown heredoc with ls -1 dir has no markdown output plan", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\nls -1 /tmp/a\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
    expect(plan(r.value)).toBeUndefined();
  });

  it("escaped wrapper payload keeps heredoc body projection aligned", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"cat > /tmp/a\\\\b.md <<'EOF'\n# T\nEOF\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("mixed-quoted wrapper heredoc emits wrapper segments and clean embedded content", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"cat > /tmp/cydo-heredoc-render.md <<'EOF'\nheredoc body with \\\"quotes\\\" and \"'$literal\nEOF'";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("heredoc body containing << does not trigger false multi-heredoc rejection", async () => {
    const cmd =
      "/run/current-system/sw/bin/zsh -lc \"mkdir -p /tmp/a\ncat > /tmp/a/output.md <<'EOF'\nline with << inside body\nEOF\nls -1 /tmp/a\"";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing quoted << literal after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\necho '<<'";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing comment with << after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\n# << comment";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("trailing ;# comment with << after heredoc does not trigger false multi-heredoc rejection", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\n:;# << comment";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("treats the normalized bare :; suffix like the comment-equivalent write", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\n:;";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok || r.value.kind !== "write") return;
    expect(r.value).toMatchObject({
      filePath: "/tmp/a/output.md",
      heredoc: { content: "# Title" },
    });
    expect(r.value.steps).toBeUndefined();
  });

  it("trailing here-string <<< after heredoc is not treated as second heredoc", async () => {
    const cmd =
      "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF\ngrep foo <<< 'bar'";
    const parsed = await buildLoadedShellSourceTree(cmd);
    expect(parsed.ok).toBe(true);
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });

  it("unwrapped heredoc embedded-content source span points to body text", async () => {
    const cmd = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("write");
  });
});

describe("batch 1 rg/sed/structured output plans", () => {
  it("classifies the exact reported command as a D context search", async () => {
    const result = await parseShellSemantic(
      'cd /mnt/local/moved/home/vladimir/work/.cydo/tasks/39201/worktree && grep -n "backfillHistoryBoundary" -B3 -A60 source/cydo/workflow/history/pipeline.d | sed -n 1,150p',
    );
    const filePath =
      "/mnt/local/moved/home/vladimir/work/.cydo/tasks/39201/worktree/source/cydo/workflow/history/pipeline.d";

    expect(result).toMatchObject({
      ok: true,
      value: {
        kind: "search",
        commandName: "rg",
        pattern: "backfillHistoryBoundary",
        filePath,
      },
    });
    if (!result.ok) return;
    expect(plan(result.value)).toEqual({
      version: 1,
      blocks: [
        {
          id: "rg-results",
          source: { stepIndex: 0, producerName: "rg", filePath },
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "d" },
            },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "line-number-prefixed-with-context",
          },
        },
      ],
    });
  });

  it.each([
    ["grep -n pat -B3 -A60 f.d", "d"],
    ["grep -n -A 3 pat f.d", "d"],
    ["grep -n --context=2 pat f.d", "d"],
    ["grep -n --after-context 2 pat f.d", "d"],
    ["rg -n -A3 foo README.md", "markdown"],
    ["rg -n --context=3 foo README.md", "markdown"],
    ["cat f.d | grep -n -C1 pat", "d"],
    ["grep -n p -A2 f.d | head -5 | tail -2", "d"],
  ])("plans numbered context rows for %s", async (command, language) => {
    const result = await parseShellSemantic(command);
    expect(result).toMatchObject({ ok: true, value: { kind: "search" } });
    if (!result.ok) return;
    const block = plan(result.value)?.blocks[0];
    expect(block?.location).toMatchObject({
      validator: "line-number-prefixed-with-context",
    });
    expect(block?.format).toEqual({
      kind: "individual-lines",
      format: {
        kind: "line-number-prefixed",
        format: { kind: "content", language },
      },
    });
  });

  it.each([
    ["grep -n pat f.d -A", "-A"],
    ["grep -n -A x pat f.d", "-A"],
    ["grep -n -A -1 pat f.d", "-A"],
    ["grep -n -A9007199254740993 pat f.d", "-A9007199254740993"],
    [
      "grep -n --context=9007199254740993 pat f.d",
      "--context=9007199254740993",
    ],

    ["grep -n pat f.d --context", "--context"],
    ["grep -n --group-separator=x pat f.d", "--group-separator=x"],
    ["grep -nA3 pat f.d", "-nA3"],
    ["grep -n -H pat f.d", "-H"],
  ])("rejects %s and names the unsupported flag", async (command, flag) => {
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsupported_option",
      reason: `unsupported grep option ${flag}`,
    });
  });

  it("supported rg -n emits search semantic and line-number plan", async () => {
    const r = await parseShellSemantic(
      'rg -n "formatGenericInput" web/src/components/ToolCall.tsx',
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("search");
    const v = r.value;
    expect(plan(v)?.blocks[0]?.id).toBe("rg-results");
    expect(plan(v)?.blocks[0]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "colon-line-number-prefixed",
    });
  });

  it("supported grep -n emits search semantic and line-number plan", async () => {
    const r = await parseShellSemantic(
      'grep -n "formatGenericInput" web/src/components/ToolCall.tsx',
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("search");
    const v = r.value;
    expect(plan(v)?.blocks[0]?.id).toBe("rg-results");
    expect(plan(v)?.blocks[0]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "colon-line-number-prefixed",
    });
  });

  it.each([
    ['rg -n "" README.md', "rg"],
    ['grep -n "" README.md', "grep"],
  ] as const)(
    "rejects a direct empty quoted %s pattern",
    async (command, tool) => {
      const r = await parseShellSemantic(command);
      expect(r, `${tool}: ${command}`).toMatchObject({
        ok: false,
        code: "variable_path",
      });
    },
  );

  it.each(['cat README.md | rg -n ""', 'cat README.md | grep -n ""'])(
    "rejects an empty quoted pattern in a search pipeline: %s",
    async (command) => {
      const r = await parseShellSemantic(command);
      expect(r).toMatchObject({ ok: false, code: "variable_path" });
    },
  );

  it("unsupported rg forms reject", async () => {
    const bad = [
      "rg --json foo README.md",
      "rg -n foo .",
      "rg -n foo README.md package.json",
      "rg -n --column foo README.md",
      "rg -n --with-filename foo README.md",
      "rg -n --color=always foo README.md",
      "rg -n --replace=bar foo README.md",
    ];
    for (const cmd of bad) {
      const r = await parseShellSemantic(cmd);
      expect(r.ok).toBe(false);
    }
  });

  it("grep -n ... osthread.d | head keeps D highlighting", async () => {
    const r = await parseShellSemantic(
      'grep -n "cbDllUnload\\|ll_removeThread" /nix/store/ab1n7scnjf98w13jwz12r5lm43d30cj9-dmd-2.112.0/include/dmd/core/thread/osthread.d | head -15',
    );
    expect(r).toMatchObject({ ok: true, value: { kind: "search" } });
    if (!r.ok) return;
    expect(plan(r.value)?.blocks[0]?.format).toEqual({
      kind: "individual-lines",
      format: {
        kind: "line-number-prefixed",
        format: { kind: "content", language: "d" },
      },
    });
  });

  it("rg -n ... app.d | head remains a search", async () => {
    const r = await parseShellSemantic(
      'rg -n "sessionBroadcast" source/cydo/app.d | head -15',
    );
    expect(r).toMatchObject({ ok: true, value: { kind: "search" } });
  });

  it("unsupported search pipeline stage rejects", async () => {
    const r = await parseShellSemantic(
      "grep -n pattern source/cydo/app.d | unsupported",
    );
    expect(r.ok).toBe(false);
  });

  it("single sed read includes whole-output plan", async () => {
    const r = await parseShellSemantic("sed -n '1,20p' README.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect(plan(r.value)?.blocks[0]?.id).toBe("sed-output");
  });

  it("single sed svg read carries source file identity in output plan", async () => {
    const r = await parseShellSemantic(
      "sed -n '1,20p' /tmp/cydo-heredoc-render.svg",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("read");
    expect(plan(r.value)?.blocks[0]?.source?.filePath).toBe(
      "/tmp/cydo-heredoc-render.svg",
    );
  });

  it("ls -l same-file && sed emits structured-output with listing + sed blocks", async () => {
    const r = await parseShellSemantic(
      "ls -l README.md && sed -n '1,20p' README.md",
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const v = r.value;
    expect(plan(v)?.blocks.map((b: { id: string }) => b.id)).toEqual([
      "listing",
      "sed-output",
    ]);
    expect(plan(v)?.blocks[1]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
    expect(plan(v)?.blocks[1]?.source?.filePath).toBe("README.md");
  });

  it.each([
    "ls -l README.md; sed -n '1,20p' README.md",
    "ls -l README.md\nsed -n '1,20p' README.md",
  ])(
    "does not treat direct %j ls/sed boundaries as the exact readback",
    async (command) => {
      const r = await parseShellSemantic(command);
      expect(r.ok, command).toBe(false);
      if (!r.ok) expect(r.code, command).toBe("unsupported_command");
    },
  );

  it("sed/printf multiline list emits unique-literal separator anchors", async () => {
    const cmd = [
      "sed -n '1,20p' /tmp/a.md",
      "printf '\\n--- spike ---\\n'",
      "sed -n '1,20p' /tmp/b.md",
    ].join("\n");
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    const sedBlock = plan(r.value)?.blocks.find((b) => b.id === "sed-0");
    expect(sedBlock?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "before-block", blockId: "printf-1" },
      validator: "non-empty",
    });
    expect(
      plan(r.value)?.blocks.some(
        (b: { location: { kind: string } }) =>
          b.location.kind === "unique-literal",
      ),
    ).toBe(true);
  });

  it("sed/printf && list emits structured blocks for mixed readbacks", async () => {
    const cmd =
      "sed -n '1,40p' /tmp/cydo-heredoc-render.md && printf '\\n--- svg ---\\n' && sed -n '1,20p' /tmp/cydo-heredoc-render.svg";
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    expect(plan(r.value)?.blocks.map((b: { id: string }) => b.id)).toEqual([
      "sed-0",
      "printf-1",
      "sed-2",
    ]);
    expect(plan(r.value)?.blocks[0]?.format).toEqual({
      kind: "content",
      language: "markdown",
    });
    expect(plan(r.value)?.blocks[0]?.source?.filePath).toBe(
      "/tmp/cydo-heredoc-render.md",
    );
    expect(plan(r.value)?.blocks[1]?.location).toEqual({
      kind: "unique-literal",
      text: "\n--- svg ---\n",
      include: "self",
    });
    expect(plan(r.value)?.blocks[2]?.format).toEqual({
      kind: "content",
      language: "xml",
    });
    expect(plan(r.value)?.blocks[2]?.source?.filePath).toBe(
      "/tmp/cydo-heredoc-render.svg",
    );
    expect(plan(r.value)?.blocks[2]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
  });

  it("printf conversion forms are not accepted in structured sed/printf lists", async () => {
    const cmd = [
      "sed -n '1,20p' /tmp/a.md",
      "printf '%s\\n'",
      "sed -n '1,20p' /tmp/b.md",
    ].join("\n");
    const r = await parseShellSemantic(cmd);
    expect(r.ok).toBe(false);
  });

  it("wc -l && head -100 of same file emits 2-block plan", async () => {
    const r = await parseShellSemantic("wc -l file.md && head -100 file.md");
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.kind).toBe("structured-output");
    expect(plan(r.value)?.blocks).toHaveLength(2);
    expect(plan(r.value)?.blocks.map((b: { id: string }) => b.id)).toEqual([
      "wc-0",
      "head-1",
    ]);
    expect(plan(r.value)?.blocks[0]?.format).toEqual({
      kind: "content",
      language: "shell-output",
    });
    expect(plan(r.value)?.blocks[0]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "line-count", count: 1 },
      validator: "non-empty",
    });
    expect(plan(r.value)?.blocks[0]?.source?.filePath).toBe("file.md");
    expect(plan(r.value)?.blocks[1]?.format).toEqual({
      kind: "content",
      language: "markdown",
    });
    expect(plan(r.value)?.blocks[1]?.location).toEqual({
      kind: "from-cursor",
      end: { kind: "end-of-output", requiresComplete: true },
      validator: "non-empty",
    });
    expect(plan(r.value)?.blocks[1]?.source?.filePath).toBe("file.md");
  });
});

describe("Unit 2 public shell semantic contracts", () => {
  it("keeps the canonical mixed program exact and exposes its trailing pipeline", async () => {
    const command =
      "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
    expect(command.length).toBe(56);

    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const value = result.value;
    if (value.kind !== "script-exec") return;
    expect(value.command).toBe(command);
    expect(value.commandName).toBe("python3");
    expect(value.language).toBe("python");
    expect(value.scriptSource).toMatchObject({
      type: "heredoc",
      delimiter: "EOF",
      quoted: true,
      content: "print(1)",
      commandLine: "cd /tmp && python3 - <<'EOF'",
      terminator: "EOF",
    });
    expect(value.steps).toBeUndefined();
    expect(plan(value)).toBeUndefined();
  });

  it.each([
    "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF",
    "cd /tmp && python3 -c 'print(1)'",
    "env FOO=bar python3 -c 'print(1)'",
    "cd /tmp && env FOO=bar python3 -c 'print(1)'",
  ])(
    "recognizes cd-prefix and environment Python forms: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("script-exec");
      expect(result.value.command, command).toBe(command);
      expect((result.value as ShellScriptExecSemantic).language, command).toBe(
        "python",
      );
    },
  );

  it.each([
    "env FOO=bar python3 - <<'PY'\nprint(1)\nPY",
    "cd /tmp && env FOO=bar python3 - <<'PY'\nprint(1)\nPY",
  ])(
    "publishes exact Python heredoc metadata for environment-prefixed commands: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("script-exec");
      if (result.value.kind !== "script-exec") return;
      expect(result.value).toMatchObject({
        command,
        commandName: "python3",
        language: "python",
        scriptSource: {
          type: "heredoc",
          delimiter: "PY",
          quoted: true,
          content: "print(1)",
          commandLine: command.split("\n", 1)[0],
          terminator: "PY",
        },
      });
      expect(result.value.steps).toBeUndefined();
    },
  );

  it.each(["cat foo\\ bar*", "cat foo\\ bar?", "cat ~/foo\\ bar"])(
    "rejects mixed escaped and dynamic path operands: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(false);
    },
  );

  it.each([
    "cat operand >output.md <<EOF\nbody\nEOF",
    "cat -n >output.md <<EOF\nbody\nEOF",
  ])(
    "does not classify a cat heredoc with operands or options as a write: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok ? result.value.kind : undefined, command).not.toBe(
        "write",
      );
    },
  );

  it("keeps an unsupported trailing ls pipeline out of cat heredoc steps", async () => {
    const command =
      "cat >output.md <<EOF\nbody\nEOF\nls -l output.md | sed -n '1,2p' output.md";
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok || result.value.kind !== "write") return;
    expect(result.value.steps).toBeUndefined();
  });

  it("classifies the exact trailing ls readback after a cat heredoc", async () => {
    const command =
      "cat >output.md <<EOF\nbody\nEOF\nls -l output.md && sed -n '1,2p' output.md";
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok || result.value.kind !== "write") return;
    expect(result.value.steps).toEqual([
      {
        kind: "write-file",
        order: 0,
        targetPath: "output.md",
        contentNodeId: "heredoc-body",
        outputShape: { kind: "none" },
      },
      {
        kind: "plain-output",
        order: 1,
        commandName: "ls",
        filePath: "output.md",
        outputShape: {
          kind: "fixed-lines",
          count: 1,
          format: { kind: "content", language: "shell-output" },
          validator: "non-empty",
        },
        blockId: "listing",
      },
      {
        kind: "read-file",
        order: 2,
        commandName: "sed",
        filePath: "output.md",
        range: { type: "lines", start: 1, end: 2 },
        outputShape: {
          kind: "content",
          format: { kind: "content", language: "markdown" },
          validator: "non-empty",
        },
        blockId: "sed-output",
      },
    ]);
  });

  it("classifies the exact trailing ls directory listing after a cat heredoc", async () => {
    const command = "cat >output.md <<EOF\nbody\nEOF\nls -1 src";
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok || result.value.kind !== "write") return;
    expect(result.value.steps).toBeUndefined();
  });

  it("classifies direct ls -1 src without an output plan", async () => {
    const result = await parseShellSemantic("ls -1 src");
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.kind).toBe("structured-output");
    expect(result.value.steps).toBeUndefined();
  });

  it.each([
    "env -i python3 -c 'print(1)'",
    "env FOO=$BAR python3 -c 'print(1)'",
    "FOO=one python3 -c 'print(1)'",
    "FOO=$BAR python3 -c 'print(1)'",
    "env FOO=bar",
    "env FOO=bar unknown-interpreter -c 'print(1)'",
    "env FOO=bar python3 -c 'print(1)' extra",
    "python3 -c 'print(1)' && python3 -c 'print(2)'",
    "cd /tmp && python3 -c 'print(1)' | cat",
  ])(
    "does not false-positive unsupported environment or compound form: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok ? result.value.kind : undefined, command).not.toBe(
        "script-exec",
      );
    },
  );

  it.each([
    ["/usr/bin/cat README.md", "README.md"],
    ["cat 'README'\".md\"", "README.md"],
    ["cat 'a>b'", "a>b"],
    ["cat 'a|b'", "a|b"],
    ["cat 'cost$USD'", "cost$USD"],
    ["cat /tmp/project/README.md", "/tmp/project/README.md"],
  ] as const)(
    "normalizes literal command and path forms: %s",
    async (command, filePath) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("read");
      expect((result.value as ShellReadSemantic).filePath, command).toBe(
        filePath,
      );
    },
  );

  it.each([
    'cat "$(pwd)/README.md"',
    'cat "README$SUFFIX"',
    "cat README$(suffix)",
    "cat >out.txt README.md",
  ])("rejects dynamic or post-redirect read operands: %s", async (command) => {
    const result = await parseShellSemantic(command);
    expect(result.ok, command).toBe(false);
  });

  it.each(["echo done; cat b", "echo done && cat b", "echo done\ncat b"])(
    "accepts normalized list boundaries: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("structured-output");
      expect(result.value.steps, command).toHaveLength(2);
    },
  );

  it("keeps pipe lowering separate from conservative control operators", async () => {
    const pipe = await parseShellSemantic("cat a | head -1");
    expect(pipe).toMatchObject({
      ok: true,
      value: { kind: "read", filePath: "a", range: { type: "head", count: 1 } },
    });

    for (const command of [
      "cat a || cat b",
      "cat a |& cat b",
      "cat a & cat b",
      "cat a ;; cat b",
      "case x in x) cat a ;; esac",
      "if true; then cat a; fi",
      "cat '",
    ]) {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(false);
    }
  });

  it("retains normalized parser diagnostics for unsupported control", async () => {
    const command = "cat a || cat b";
    const parsed = await loadParsedShellDocument(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.document.diagnostics).toEqual([
      {
        kind: "unsupported_control",
        span: { start: 6, end: 8 },
        operator: "||",
      },
    ]);
  });

  it.each([
    ["if list", "if true; then echo x; fi && cat <<EOF\nbody\nEOF"],
    ["for list", "for x in x; do echo x; done && cat <<EOF\nbody\nEOF"],
    ["while list", "while true; do echo x; done && cat <<EOF\nbody\nEOF"],
    ["subshell list", "(echo x) && cat <<EOF\nbody\nEOF"],
    ["if pipeline", "if true; then echo x; fi | cat <<EOF\nbody\nEOF"],
    ["for pipeline", "for x in x; do echo x; done | cat <<EOF\nbody\nEOF"],
    ["while pipeline", "while true; do echo x; done | cat <<EOF\nbody\nEOF"],
    ["subshell pipeline", "(echo x) | cat <<EOF\nbody\nEOF"],
  ] as const)(
    "returns the unsupported-construct fallback after a leading opaque %s",
    async (_label, command) => {
      expect((await parseShellSemantic(command)).ok, command).toBe(false);
    },
  );

  it.each(["bash -c 'if'", "bash -c 'cat <<EOF'"] as const)(
    "keeps the failed Bash child fallback typed for %s",
    async (command) => {
      await expect(parseShellSemantic(command)).resolves.toEqual({
        ok: false,
        code: "unsupported_command",
        reason: "unsupported shell wrapper structure",
      });
    },
  );

  it.each([
    ["python3 -c 'print(1)'", "python3", "python", "-c", "print(1)"],
    ["node -e 'console.log(1)'", "node", "javascript", "-e", "console.log(1)"],
    ["ruby -e 'puts 1'", "ruby", "ruby", "-e", "puts 1"],
    ["perl -e 'print 1'", "perl", "perl", "-e", "print 1"],
  ] as const)(
    "publishes inline %s invocation metadata",
    async (command, commandName, language, flag, content) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      const value = result.value;
      if (value.kind !== "script-exec") return;
      expect(value).toMatchObject({
        kind: "script-exec",
        command,
        commandName,
        language,
        scriptSource: { type: "inline", flag, content },
      });
      expect(plan(value)).toBeUndefined();
    },
  );

  it("unwraps one shell wrapper with trailing redirects", async () => {
    const command = "bash -lc \"python3 - <<'PY'\nprint(1)\nPY\" 2>/dev/null";
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value).toMatchObject({
      kind: "script-exec",
      command,
      commandName: "python3",
      language: "python",
      scriptSource: {
        type: "heredoc",
        delimiter: "PY",
        content: "print(1)",
      },
    });
  });

  it("keeps direct multi-level wrappers unsupported while preserving nested source nodes", async () => {
    const command = `zsh -lc "bash -lc 'cat README.md'"`;
    const semantic = await parseShellSemantic(command);
    expect(semantic).toEqual({
      ok: false,
      code: "unsupported_command",
      reason:
        "only cat, nl, sed, head, tail, git, diff, and interpreters are recognized",
    });

    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.value.text).toBe(command);
    const outer = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(outer?.kind).toBe("embed");
    if (!outer) return;
    expect(outer.content.text).toBe("bash -lc 'cat README.md'");
    const inner = outer.content.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(inner?.kind).toBe("embed");
    if (!inner) return;
    expect(inner.content.text).toBe("cat README.md");
  });

  it.each(["\n", "\r\n"] as const)(
    "preserves interpreter and cat heredoc segments with %j line endings",
    async (lineEnding) => {
      const body = 'print("$HOME | && <<")';
      const interpreterCommand = `python3 - <<'PY'${lineEnding}${body}${lineEnding}PY`;
      const interpreter = await parseShellSemantic(interpreterCommand);
      expect(interpreter.ok, interpreterCommand).toBe(true);
      if (!interpreter.ok) return;
      const script = interpreter.value;
      if (script.kind !== "script-exec") return;
      expect(script.scriptSource).toMatchObject({
        type: "heredoc",
        content: body,
        terminator: "PY",
      });
      expect(
        script.segments.map((segment) => segment.text).join(""),
        interpreterCommand,
      ).toBe(interpreterCommand);

      const catCommand = `cat >output.py <<'EOF'${lineEnding}${body}${lineEnding}EOF`;
      const cat = await parseShellSemantic(catCommand);
      expect(cat.ok, catCommand).toBe(true);
      if (!cat.ok) return;
      const write = cat.value;
      if (write.kind !== "write") return;
      expect(write.heredoc.content).toBe(body);
      expect(
        write.segments.map((segment) => segment.text).join(""),
        catCommand,
      ).toBe(catCommand);
    },
  );

  it.each([
    ["cat 2>error.log >output.py <<EOF\nbody\nEOF", "output.py"],
    ["cat &>all.log <<EOF\nbody\nEOF", "all.log"],
    ["cat 2>$ERR >output.py <<EOF\nbody\nEOF", "output.py"],
    ["cat >> out.md <<'EOF'\nx\nEOF", "out.md"],
    ["cat >&all.log <<EOF\nbody\nEOF", "all.log"],
    ["cat 2>&1 >out.md <<EOF\nbody\nEOF", "out.md"],
  ] as const)(
    "uses the literal stdout redirect for cat heredoc: %s",
    async (command, filePath) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("write");
      expect(
        (result.value as ShellHeredocWriteSemantic).filePath,
        command,
      ).toBe(filePath);
    },
  );

  it.each([
    "cat >&1- <<EOF\nx\nEOF",
    "cat >out.md 2>&$((1))- <<EOF\nx\nEOF",
    "cat >out.md 3>&$fd- <<EOF\nx\nEOF",
    "cat >out.md 2>&$fd- <<EOF\nx\nEOF",
    "cat >out.md <&$fd- <<EOF\nx\nEOF",
    "cat <&file >out.md <<EOF\nx\nEOF",
    "cat >out.md >&+1- <<EOF\nx\nEOF",
    "cat >out.md 2>&file <<EOF\nx\nEOF",
  ])(
    "rejects unmodeled descriptor operands in a cat heredoc: %j",
    async (source) => {
      await expect(parseShellSemantic(source)).resolves.toMatchObject({
        ok: false,
        code: "unsafe_shell_syntax",
      });
    },
  );

  it.each([
    "cat 2>error.log <<EOF\nbody\nEOF",
    "cat >$OUT <<EOF\nbody\nEOF",
    "cat >output.py 1>&- <<EOF\nbody\nEOF",
  ])(
    "rejects cat heredoc without a known open stdout file: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(false);
    },
  );

  it.each([
    "cat >output.py 2<<EOF\nbody\nEOF",
    "cat >output.py {fd}<<EOF\nbody\nEOF",
    "cat >output.py 1<&0 <<EOF\nbody\nEOF",
    "cat >output.py <<EOF <in\nbody\nEOF",
    "cat >output.py <<EOF <&-\nbody\nEOF",
  ])(
    "does not classify a non-effective cat heredoc as a write: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok ? result.value.kind : undefined, command).not.toBe(
        "write",
      );
    },
  );

  it.each(["cat >output.py <in <<EOF\nbody\nEOF"])(
    "classifies a cat write when its heredoc remains effective stdin: %s",
    async (command) => {
      const result = await parseShellSemantic(command);
      expect(result.ok, command).toBe(true);
      if (!result.ok) return;
      expect(result.value.kind, command).toBe("write");
    },
  );

  it.each([
    "cat >output.py 0<&1 <<EOF\nbody\nEOF",
    "cat >output.py 0<&- <<EOF\nbody\nEOF",
  ])(
    "keeps adjacent fd-zero cat redirect limitations typed: %s",
    async (command) => {
      await expect(parseShellSemantic(command), command).resolves.toMatchObject(
        {
          ok: false,
          code: "unsafe_shell_syntax",
        },
      );
    },
  );

  it("does not invent output steps for an unsupported trailing unit", async () => {
    const command = 'cat >output.py <<EOF\nbody\nEOF\nprintf "$OUT"';
    const result = await parseShellSemantic(command);
    expect(result.ok).toBe(true);
    if (!result.ok || result.value.kind !== "write") return;
    expect(result.value.steps).toBeUndefined();
  });

  it("fails fast on a corrupted direct Python invocation command ID", async () => {
    const command = "python3 -c 'print(1)'";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const invocation = loaded.document.embeddedInvocations[0];
    expect(invocation?.kind).toBe("inline");
    if (!invocation || invocation.kind !== "inline") return;

    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockResolvedValue({
        ok: true,
        document: {
          ...loaded.document,
          embeddedInvocations: [{ ...invocation, commandId: 99 }],
        },
      });
    try {
      await expect(parseShellSemantic(command)).rejects.toThrow(
        "parsed shell document invariant: command id",
      );
    } finally {
      load.mockRestore();
    }
  });

  it("fails fast when a loader shortens the sole command unit", async () => {
    const command = "cat README.md";
    expect(command).toHaveLength(13);
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok, command).toBe(true);
    if (!loaded.ok) return;
    const [unit] = loaded.document.program.children;
    if (
      loaded.document.program.children.length !== 1 ||
      unit?.kind !== "command" ||
      unit.span.end !== 13
    )
      throw new Error("test sole command unit is incomplete");

    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockResolvedValue({
        ok: true,
        document: {
          ...loaded.document,
          program: {
            ...loaded.document.program,
            children: [{ ...unit, span: { ...unit.span, end: 12 } }],
          },
        },
      });
    try {
      await expect(parseShellSemantic(command)).rejects.toThrow(
        "parsed shell document invariant:",
      );
    } finally {
      load.mockRestore();
    }
  });

  it("fails fast before an ordinary read when a loader marks its argument synthetic", async () => {
    const command = "cat REVIEW-SYNTHETIC.md";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok, command).toBe(true);
    if (!loaded.ok) return;
    const record = loaded.document.commands[0];
    const argument = record?.arguments[0];
    const unit = loaded.document.program.children[0];
    if (
      loaded.document.commands.length !== 1 ||
      record === undefined ||
      record.arguments.length !== 1 ||
      argument === undefined ||
      argument.synthetic ||
      argument.word.kind !== "literal" ||
      argument.word.syntax === "synthetic" ||
      unit?.kind !== "command" ||
      unit.span.start !== 0 ||
      unit.span.end !== command.length
    )
      throw new Error("test ordinary argument record is incomplete");

    const corruptions: readonly Readonly<{
      label: string;
      document: ParsedShellDocument;
    }>[] = [
      {
        label: "ordinary argument marked synthetic",
        document: {
          ...loaded.document,
          commands: [
            {
              ...record,
              arguments: [{ ...argument, synthetic: true }],
            },
          ],
        },
      },
      {
        label: "synthetic marker with shortened sole command unit",
        document: {
          ...loaded.document,
          commands: [
            {
              ...record,
              arguments: [{ ...argument, synthetic: true }],
            },
          ],
          program: {
            ...loaded.document.program,
            children: [{ ...unit, span: { start: 0, end: 3 } }],
          },
        },
      },
    ];
    for (const corruption of corruptions) {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document: corruption.document });
      try {
        await expect(
          parseShellSemantic(command),
          corruption.label,
        ).rejects.toThrow("parsed shell document invariant:");
      } finally {
        load.mockRestore();
      }
    }
  });

  it("fails fast when a loader returns an opaque unit that no longer matches its construct diagnostic", async () => {
    const command = "if true; then echo x; fi";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok, command).toBe(true);
    if (!loaded.ok) return;
    const opaque = loaded.document.program.children[0];
    if (
      loaded.document.program.children.length !== 1 ||
      loaded.document.diagnostics.length !== 1 ||
      opaque?.kind !== "opaque" ||
      opaque.nodeType !== "if_statement"
    )
      throw new Error("test opaque if document is incomplete");

    for (const [label, unit] of [
      ["node type", { ...opaque, nodeType: "for_statement" }],
      [
        "span start",
        {
          ...opaque,
          span: { ...opaque.span, start: opaque.span.start + 1 },
        },
      ],
    ] as const) {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({
          ok: true,
          document: {
            ...loaded.document,
            program: {
              ...loaded.document.program,
              children: [unit],
            },
          },
        });
      try {
        await expect(parseShellSemantic(command), label).rejects.toThrow(
          "parsed shell document invariant:",
        );
      } finally {
        load.mockRestore();
      }
    }
  });

  it("fails fast before classifying an ordinary read with unlisted redirect ownership", async () => {
    const command = "cat README.md >/tmp/out4";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const redirect = loaded.document.redirects[0];
    if (redirect === undefined) throw new Error("test redirect missing");
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockResolvedValue({
        ok: true,
        document: {
          ...loaded.document,
          commands: loaded.document.commands.map((owner) =>
            owner.id === redirect.ownerId
              ? { ...owner, redirectIds: [] }
              : owner,
          ),
        },
      });
    try {
      await expect(parseShellSemantic(command)).rejects.toThrow(
        "parsed shell document invariant: redirect owner membership",
      );
    } finally {
      load.mockRestore();
    }
  });

  it("fails fast before inline semantic fallback on invalid invocation metadata", async () => {
    const command = "python3 -c 'print(3)' >/tmp/out3";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const invocation = loaded.document.embeddedInvocations[0];
    expect(invocation?.kind).toBe("inline");
    if (invocation?.kind !== "inline") return;
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockResolvedValue({
        ok: true,
        document: {
          ...loaded.document,
          embeddedInvocations: [{ ...invocation, flagArgumentIndex: 99 }],
        },
      });
    try {
      await expect(parseShellSemantic(command)).rejects.toThrow(
        "parsed shell document invariant: inline argument indices",
      );
    } finally {
      load.mockRestore();
    }
  });

  it("validates parser provenance before semantic policy selects an invocation", async () => {
    const expectInvariant = async (
      command: string,
      document: ParsedShellDocument,
    ): Promise<void> => {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document });
      try {
        await expect(parseShellSemantic(command)).rejects.toThrow(
          "parsed shell document invariant:",
        );
      } finally {
        load.mockRestore();
      }
    };

    const inlineCommand = "python3 -c 'print(3)' >/tmp/out3";
    const inline = await loadParsedShellDocument(inlineCommand);
    expect(inline.ok).toBe(true);
    if (!inline.ok) return;
    const inlineInvocation = inline.document.embeddedInvocations[0];
    const inlineRedirect = inline.document.redirects[0];
    expect(inlineInvocation?.kind).toBe("inline");
    if (inlineInvocation?.kind !== "inline" || inlineRedirect === undefined)
      return;
    await expectInvariant(inlineCommand, {
      ...inline.document,
      redirects: [{ ...inlineRedirect, id: 99 }],
    });
    await expectInvariant(inlineCommand, {
      ...inline.document,
      embeddedInvocations: [
        {
          ...inlineInvocation,
          payload: {
            ...inlineInvocation.payload,
            projection: {
              ...inlineInvocation.payload.projection,
              span: {
                ...inlineInvocation.payload.projection.span,
                end: inlineInvocation.payload.projection.span.end - 1,
              },
            },
          },
        },
      ],
    });
    await expectInvariant(inlineCommand, {
      ...inline.document,
      embeddedInvocations: [{ ...inlineInvocation, child: inline.document }],
    });

    const envCommand = "env FOO=bar python3 -c 'print(3)'";
    const env = await loadParsedShellDocument(envCommand);
    expect(env.ok).toBe(true);
    if (!env.ok) return;
    const envInvocation = env.document.embeddedInvocations[0];
    expect(envInvocation?.prefix.kind).toBe("env");
    if (envInvocation?.prefix.kind !== "env") return;
    const assignment = envInvocation.prefix.assignments[0];
    if (assignment === undefined) return;
    await expectInvariant(envCommand, {
      ...env.document,
      embeddedInvocations: [
        {
          ...envInvocation,
          prefix: {
            ...envInvocation.prefix,
            assignments: [{ ...assignment, value: "different" }],
          },
        },
      ],
    });

    const heredocCommand = "python3 -u - <<EOF\nprint(3)\nEOF";
    const heredoc = await loadParsedShellDocument(heredocCommand);
    expect(heredoc.ok).toBe(true);
    if (!heredoc.ok) return;
    const heredocInvocation = heredoc.document.embeddedInvocations[0];
    const heredocRedirect = heredoc.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    expect(heredocInvocation?.kind).toBe("heredoc");
    if (heredocInvocation?.kind !== "heredoc" || heredocRedirect === undefined)
      return;
    await expectInvariant(heredocCommand, {
      ...heredoc.document,
      embeddedInvocations: [{ ...heredocInvocation, stdinArgumentIndex: 0 }],
    });
    await expectInvariant(heredocCommand, {
      ...heredoc.document,
      redirects: heredoc.document.redirects.map((redirect) =>
        redirect.id === heredocRedirect.id
          ? {
              ...heredocRedirect,
              rawBodySpan: {
                ...heredocRedirect.rawBodySpan,
                end: heredocRedirect.rawBodySpan.end - 1,
              },
            }
          : redirect,
      ),
    });

    const bashCommand = "bash -c 'cat README.md'";
    const bash = await loadParsedShellDocument(bashCommand);
    expect(bash.ok).toBe(true);
    if (!bash.ok) return;
    const bashInvocation = bash.document.embeddedInvocations[0];
    if (bashInvocation?.kind !== "inline" || bashInvocation.child === null)
      return;
    await expectInvariant(bashCommand, {
      ...bash.document,
      embeddedInvocations: [{ ...bashInvocation, child: inline.document }],
    });
  });

  it("fails fast for command, member, and descriptor provenance before semantic policy", async () => {
    const expectInvariant = async (
      command: string,
      document: ParsedShellDocument,
      message: string,
    ): Promise<void> => {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document });
      try {
        await expect(parseShellSemantic(command)).rejects.toThrow(message);
      } finally {
        load.mockRestore();
      }
    };

    const multiCommand = "echo hi; cat README.md";
    const multi = await loadParsedShellDocument(multiCommand);
    expect(multi.ok).toBe(true);
    if (!multi.ok) return;
    const [firstUnit, secondUnit] = multi.document.program.children;
    const [echoCommand, catCommand] = multi.document.commands;
    if (
      firstUnit?.kind !== "command" ||
      secondUnit?.kind !== "command" ||
      echoCommand === undefined ||
      catCommand === undefined
    )
      throw new Error("test multi-command document is incomplete");
    await expectInvariant(
      multiCommand,
      {
        ...multi.document,
        program: {
          ...multi.document.program,
          children: [
            { ...firstUnit, commandId: secondUnit.commandId },
            secondUnit,
          ],
        },
      },
      "parsed shell document invariant: command unit references",
    );
    await expectInvariant(
      multiCommand,
      {
        ...multi.document,
        commands: [{ ...echoCommand, name: catCommand.name }, catCommand],
      },
      "parsed shell document invariant: command name span",
    );
    await expectInvariant(
      multiCommand,
      {
        ...multi.document,
        commands: [
          { ...echoCommand, arguments: [catCommand.arguments[0]!] },
          catCommand,
        ],
      },
      "parsed shell document invariant: command argument span",
    );

    const narrowedCommand = "cat README.md >out";
    const narrowed = await loadParsedShellDocument(narrowedCommand);
    expect(narrowed.ok).toBe(true);
    if (!narrowed.ok) return;
    const narrowedRecord = narrowed.document.commands[0];
    if (narrowedRecord === undefined)
      throw new Error("test narrowed command is incomplete");
    await expectInvariant(
      narrowedCommand,
      {
        ...narrowed.document,
        commands: [
          {
            ...narrowedRecord,
            span: {
              start: narrowedRecord.span.start,
              end: narrowedRecord.name.rawSpan.end,
            },
          },
        ],
      },
      "parsed shell document invariant: command argument span",
    );

    const numericCommand = "cat 2>out";
    const numeric = await loadParsedShellDocument(numericCommand);
    expect(numeric.ok).toBe(true);
    if (!numeric.ok) return;
    const numericRedirect = numeric.document.redirects[0];
    const numericDescriptor =
      numericRedirect?.kind === "file" ? numericRedirect.descriptor : null;
    if (
      numericRedirect?.kind !== "file" ||
      numericDescriptor?.kind !== "number"
    )
      throw new Error("test numeric descriptor is incomplete");
    await expectInvariant(
      numericCommand,
      {
        ...numeric.document,
        redirects: [
          {
            ...numericRedirect,
            descriptor: { ...numericDescriptor, value: "1" },
          },
        ],
      },
      "parsed shell document invariant: redirect descriptor value",
    );
  });

  it("fails fast for redirect components and heredoc header anchors before semantic policy", async () => {
    const expectInvariant = async (
      command: string,
      document: ParsedShellDocument,
    ): Promise<void> => {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document });
      try {
        await expect(parseShellSemantic(command)).rejects.toThrow(
          "parsed shell document invariant:",
        );
      } finally {
        load.mockRestore();
      }
    };

    const quotedCommand = 'cat <"in>out" <<EOF\nbody\nEOF';
    const quotedDestination = await loadParsedShellDocument(quotedCommand);
    expect(quotedDestination.ok).toBe(true);
    if (!quotedDestination.ok) return;
    const quotedRedirect = quotedDestination.document.redirects[0];
    if (
      quotedRedirect?.kind !== "file" ||
      quotedRedirect.destination?.kind !== "literal"
    )
      throw new Error("test quoted redirect is incomplete");
    const quotedOperatorStart = quotedCommand.indexOf(
      ">",
      quotedRedirect.destination.rawSpan.start,
    );
    if (quotedOperatorStart < quotedRedirect.destination.rawSpan.start)
      throw new Error("test quoted destination operator is missing");
    await expectInvariant(quotedCommand, {
      ...quotedDestination.document,
      redirects: quotedDestination.document.redirects.map((redirect) =>
        redirect.id === quotedRedirect.id
          ? {
              ...quotedRedirect,
              operator: ">",
              operatorSpan: {
                start: quotedOperatorStart,
                end: quotedOperatorStart + 1,
              },
            }
          : redirect,
      ),
    });

    const descriptorCommand = "cat 1>2 <<EOF\nbody\nEOF";
    const descriptorDestination =
      await loadParsedShellDocument(descriptorCommand);
    expect(descriptorDestination.ok).toBe(true);
    if (!descriptorDestination.ok) return;
    const descriptorRedirect = descriptorDestination.document.redirects[0];
    if (descriptorRedirect?.kind !== "file")
      throw new Error("test descriptor redirect is incomplete");
    const { descriptor, destination } = descriptorRedirect;
    if (descriptor?.kind !== "number" || destination?.kind !== "literal")
      throw new Error("test descriptor redirect is incomplete");
    expect(destination.value).toBe("2");
    expect(descriptor.value).toBe("1");
    await expectInvariant(descriptorCommand, {
      ...descriptorDestination.document,
      redirects: descriptorDestination.document.redirects.map((redirect) =>
        redirect.id === descriptorRedirect.id
          ? {
              ...descriptorRedirect,
              destination: {
                ...destination,
                rawSpan: descriptor.rawSpan,
                value: descriptor.value,
                projection: {
                  ...destination.projection,
                  span: descriptor.rawSpan,
                },
              },
            }
          : redirect,
      ),
    });

    const headerCases = [
      {
        command: "cd /tmp && python3 - <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("python3"),
      },
      {
        command: "mkdir output\ncat <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("mkdir"),
      },
      {
        command: "cat <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("<<"),
      },
    ] as const;
    for (const testCase of headerCases) {
      const loaded = await loadParsedShellDocument(testCase.command);
      expect(loaded.ok, testCase.command).toBe(true);
      if (!loaded.ok) return;
      const heredoc = loaded.document.redirects.find(
        (redirect) => redirect.kind === "heredoc",
      );
      if (heredoc === undefined)
        throw new Error("test heredoc redirect is missing");
      const headerStart = testCase.headerStart(testCase.command);
      if (headerStart < 0 || heredoc.headerSpan.start === headerStart)
        throw new Error("test heredoc anchor is incomplete");
      await expectInvariant(testCase.command, {
        ...loaded.document,
        redirects: loaded.document.redirects.map((redirect) =>
          redirect.id === heredoc.id
            ? {
                ...heredoc,
                headerSpan: { ...heredoc.headerSpan, start: headerStart },
              }
            : redirect,
        ),
      });
    }
  });

  it("fails fast for a file redirect payload transplanted from its later sibling before public semantic output", async () => {
    const expectInvariant = async (
      command: string,
      document: ParsedShellDocument,
    ): Promise<void> => {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document });
      try {
        await expect(parseShellSemantic(command)).rejects.toThrow(
          "parsed shell document invariant:",
        );
      } finally {
        load.mockRestore();
      }
    };

    const redirectCommand = "cat >out.py 2>err.log <<EOF\nprint(1)\nEOF";
    const redirectDocument = await loadParsedShellDocument(redirectCommand);
    expect(redirectDocument.ok, redirectCommand).toBe(true);
    if (!redirectDocument.ok) return;
    const [firstRedirect, secondRedirect] = redirectDocument.document.redirects;
    if (
      firstRedirect?.kind !== "file" ||
      secondRedirect?.kind !== "file" ||
      firstRedirect.destination === null ||
      secondRedirect.destination === null
    )
      throw new Error("test paired file redirects are incomplete");
    const secondDestination = secondRedirect.destination;
    await expectInvariant(redirectCommand, {
      ...redirectDocument.document,
      redirects: redirectDocument.document.redirects.map((redirect) =>
        redirect.id === firstRedirect.id
          ? {
              ...firstRedirect,
              destination: secondDestination,
              span: {
                ...firstRedirect.span,
                end: secondDestination.rawSpan.end,
              },
            }
          : redirect,
      ),
    });
  });

  it("fails fast for co-mutated redirected-statement and heredoc header starts before public semantic output", async () => {
    const expectInvariant = async (
      command: string,
      document: ParsedShellDocument,
    ): Promise<void> => {
      const load = vi
        .spyOn(shellParser, "loadParsedShellDocument")
        .mockResolvedValue({ ok: true, document });
      try {
        await expect(parseShellSemantic(command)).rejects.toThrow(
          "parsed shell document invariant:",
        );
      } finally {
        load.mockRestore();
      }
    };

    const headerCommand =
      "mkdir -p output\n# neighboring trivia\ncat >out.py <<EOF\nprint(1)\nEOF";
    const headerDocument = await loadParsedShellDocument(headerCommand);
    expect(headerDocument.ok, headerCommand).toBe(true);
    if (!headerDocument.ok) return;
    const [firstUnit, secondUnit] = headerDocument.document.program.children;
    const heredoc = headerDocument.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    const commentStart = headerCommand.indexOf("# neighboring trivia");
    if (
      headerDocument.document.program.children.length !== 2 ||
      firstUnit?.kind !== "command" ||
      secondUnit?.kind !== "redirected_statement" ||
      heredoc === undefined ||
      commentStart < 0 ||
      secondUnit.span.start <= commentStart ||
      heredoc.headerSpan.start <= commentStart
    )
      throw new Error("test redirected statement header is incomplete");
    await expectInvariant(headerCommand, {
      ...headerDocument.document,
      program: {
        ...headerDocument.document.program,
        children: [
          firstUnit,
          {
            ...secondUnit,
            span: { ...secondUnit.span, start: commentStart },
          },
        ],
      },
      redirects: headerDocument.document.redirects.map((redirect) =>
        redirect.id === heredoc.id
          ? {
              ...heredoc,
              headerSpan: {
                ...heredoc.headerSpan,
                start: commentStart,
              },
            }
          : redirect,
      ),
    });
  });

  it("preserves a genuine nested Bash child parse diagnostic", async () => {
    await expect(parseShellSemantic('bash -c "cat \'"')).resolves.toEqual({
      ok: false,
      code: "unsupported_command",
      reason: "unsupported shell wrapper structure",
    });
  });

  it("uses a typed fallback for a source-consistent terminal cat boundary", async () => {
    const command = "cat >output.md <<EOF\nbody\nEOF;";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    expect(loaded.document.program.boundaries).toEqual([
      {
        kind: "semicolon",
        text: ";",
        span: { start: command.length - 1, end: command.length },
      },
    ]);
    await expect(parseShellSemantic(command)).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "unsupported heredoc structure",
    });
  });

  it("fails fast for a source-inconsistent cat program boundary", async () => {
    const command = "cat >output.md <<EOF\nbody\nEOF";
    const loaded = await loadParsedShellDocument(command);
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockResolvedValue({
        ok: true,
        document: {
          ...loaded.document,
          program: {
            ...loaded.document.program,
            boundaries: [
              {
                kind: "newline",
                text: "\n",
                span: { start: command.length, end: command.length },
              },
            ],
          },
        },
      });
    try {
      await expect(parseShellSemantic(command)).rejects.toThrow(
        "parsed shell document invariant: program boundary text",
      );
    } finally {
      load.mockRestore();
    }
  });

  it("maps malformed ordinary syntax and incomplete heredocs to typed results", async () => {
    await expect(parseShellSemantic("cat '")).resolves.toMatchObject({
      ok: false,
      code: "unsafe_shell_syntax",
    });
    await expect(
      parseShellSemantic("python3 - <<'EOF'\nprint(1)"),
    ).resolves.toMatchObject({
      ok: false,
      code: "invalid_heredoc",
    });
    for (const command of ["cat <<-EOF\nbody\nEOF", "cat <<$EOF\nbody\n$EOF"]) {
      await expect(parseShellSemantic(command)).resolves.toMatchObject({
        ok: false,
        code: "invalid_heredoc",
      });
    }
  });
});
