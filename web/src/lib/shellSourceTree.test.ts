import { beforeAll, describe, expect, it } from "vitest";
import {
  projectDescendantSpan,
  projectEmbedSpan,
  projectSpan,
  type SourceSegment,
} from "./sourceTree";
import {
  configureShellParserAssets,
  loadParsedShellDocument,
} from "./shellParser";
import { ownsWholeCommand } from "./shellInvocationOwnership";
import {
  analyzeShellDocument,
  buildShellSourceTree,
  isShellCommandWrapperEmbed,
} from "./shellSourceTree";

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

function findFirstEmbed(
  segments: SourceSegment[],
): Extract<SourceSegment, { kind: "embed" }> | null {
  return (
    segments.find(
      (segment): segment is Extract<SourceSegment, { kind: "embed" }> =>
        segment.kind === "embed",
    ) ?? null
  );
}

async function buildLoadedShellSourceTree(source: string) {
  const parsed = await loadParsedShellDocument(source);
  expect(parsed.ok, source).toBe(true);
  if (!parsed.ok) throw new Error(`shell parser rejected: ${parsed.reason}`);
  return buildShellSourceTree(parsed.document);
}

function reconstructSource(node: {
  text: string;
  segments: SourceSegment[];
}): string {
  return node.segments
    .map((segment) => node.text.slice(segment.span.start, segment.span.end))
    .join("");
}

describe("sourceTree projection parser", () => {
  it.each([
    ["delimiter text inside an expansion", ":<<E\n$xE "],
    ["trailing space on the delimiter line", ":<<E\n$x\nE "],
  ])("rejects an incomplete heredoc with %s", async (_label, source) => {
    const parsed = await loadParsedShellDocument(source);
    if (parsed.ok) buildShellSourceTree(parsed.document);
    expect(parsed).toMatchObject({
      ok: false,
      reason: "invalid_heredoc",
      issue: "incomplete",
    });
  });

  it.each([
    ["at EOF without a final newline", ":<<E\n$x\nE"],
    ["after a quoted opener", ":<<'E'\n$x\nE\n"],
    ["before CRLF", ":<<E\n$x\nE\r\n"],
  ])("accepts a heredoc terminator %s", async (_label, source) => {
    const tree = await buildLoadedShellSourceTree(source);
    expect(tree.ok).toBe(true);
    if (tree.ok) expect(reconstructSource(tree.value)).toBe(source);
  });

  it("rejects multiple heredocs on the same command line", async () => {
    const parsed = await loadParsedShellDocument(":<<A <<B\na\nA\nb\nB\n");
    expect(parsed).toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });

  it("preserves the full source of a 4,000-command && chain", async () => {
    const source = Array(4_000).fill("true").join(" && ");
    const tree = await buildLoadedShellSourceTree(source);

    expect(tree.ok).toBe(true);
    if (!tree.ok) return;
    expect(tree.value.text).toBe(source);
    expect(reconstructSource(tree.value)).toBe(source);
  });

  it("reconstructs the full source of a long && chain with redirects", async () => {
    const source = Array.from(
      { length: 4_000 },
      (_, index) => `true >out-${index}`,
    ).join(" && ");
    const tree = await buildLoadedShellSourceTree(source);

    expect(tree.ok).toBe(true);
    if (!tree.ok) return;
    expect(reconstructSource(tree.value)).toBe(source);
  }, 30_000);

  it("preserves every Python embed and reconstructs a 4,000-command wrapper chain", async () => {
    const payloads = Array.from(
      { length: 4_000 },
      (_, index) => `print(${index})`,
    );
    const source = payloads
      .map((payload) => `python -c '${payload}'`)
      .join(" && ");
    const tree = await buildLoadedShellSourceTree(source);

    expect(tree.ok).toBe(true);
    if (!tree.ok) return;
    const embeds = tree.value.segments.filter(
      (segment) => segment.kind === "embed",
    );
    expect(
      embeds.map(({ content }) => [content.language, content.text]),
    ).toEqual(payloads.map((payload) => ["python", payload]));
    expect(reconstructSource(tree.value)).toBe(source);
  }, 30_000);

  it("returns a typed child rejection for a 4,000-command broken Bash wrapper chain", async () => {
    const source = Array(4_000).fill("bash -c 'if'").join(" && ");
    await expect(buildLoadedShellSourceTree(source)).resolves.toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "shell parser rejected child: unsafe_shell_syntax",
    });
  }, 30_000);

  it("parses at least three nested shell wrapper levels", async () => {
    const command = 'zsh -lc "bash -lc \'sh -c \\"cat README.md\\"\'"';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const level1 = findFirstEmbed(parsed.value.segments);
    expect(level1).not.toBeNull();
    if (!level1) return;
    const level2 = findFirstEmbed(level1.content.segments);
    expect(level2).not.toBeNull();
    if (!level2) return;
    const level3 = findFirstEmbed(level2.content.segments);
    expect(level3).not.toBeNull();
    if (!level3) return;

    expect(parsed.value.language).toBe("bash");
    expect(level1.content.language).toBe("bash");
    expect(level2.content.language).toBe("bash");
    expect(level3.content.language).toBe("bash");
    expect(level1.origin?.attributes?.ownsWholeCommand === true).toBe(true);
    expect(level2.origin?.attributes?.ownsWholeCommand === true).toBe(true);
    expect(level3.origin?.attributes?.ownsWholeCommand === true).toBe(true);
    expect(level3.content.text).toBe("cat README.md");
    expect(parsed.value.text).toBe(command);
  });

  it("preserves raw escaped double-quote payload text and projects decoded quote spans", async () => {
    const command = 'zsh -lc "echo \\"CYDO_SKIP_LOAD_TASKS\\""';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper || !wrapper.projection) return;

    expect(parsed.value.text).toBe(command);
    expect(parsed.value.text).toContain('\\"CYDO_SKIP_LOAD_TASKS\\"');
    expect(wrapper.content.text).toBe('echo "CYDO_SKIP_LOAD_TASKS"');
    expect(Object.keys(wrapper.projection)).toEqual(["points"]);
    expect(wrapper.projection).not.toHaveProperty("span");

    const quote = wrapper.content.text.indexOf('"CYDO_SKIP_LOAD_TASKS"');
    expect(quote).toBeGreaterThanOrEqual(0);
    if (quote < 0) return;

    const local = projectSpan(wrapper.projection, {
      start: quote,
      end: quote + 1,
    });
    expect(local).not.toBeNull();
    if (!local) return;

    const parentStart = wrapper.span.start + local.start;
    const parentEnd = wrapper.span.start + local.end;
    expect(parsed.value.text.slice(parentStart, parentEnd)).toBe('\\"');
  });

  it("preserves raw single-quote close/escape/reopen text and projects apostrophe spans", async () => {
    const command = "zsh -lc 'printf '\\''hi'\\'''";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;

    expect(parsed.value.text).toContain("'\\''");
    expect(wrapper.content.text).toBe("printf 'hi'");
    expect(wrapper.content.text.includes("'")).toBe(true);

    const apostrophe = wrapper.content.text.indexOf("'");
    expect(apostrophe).toBeGreaterThanOrEqual(0);
    if (apostrophe < 0) return;

    const mapped = projectEmbedSpan(wrapper, {
      start: apostrophe,
      end: apostrophe + 1,
    });
    expect(mapped).not.toBeNull();
    if (!mapped) return;

    expect(parsed.value.text.slice(mapped.start, mapped.end)).toBe("'\\''");
  });

  it("parses mixed quoted wrapper payload words and preserves raw source with decoded heredoc body", async () => {
    const command =
      "zsh -lc \"cat <<'EOF'\nheredoc body with \\\"quotes\\\" and \"'$literal\nEOF'";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapperIdx = parsed.value.segments.findIndex(
      (s) => s.kind === "embed",
    );
    expect(wrapperIdx).toBeGreaterThanOrEqual(0);
    if (wrapperIdx < 0) return;
    const wrapper = parsed.value.segments[wrapperIdx];
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper || wrapper.kind !== "embed") return;

    expect(wrapper.origin?.attributes?.quote).toBe("projected");
    expect(wrapper.content.text).toBe(
      "cat <<'EOF'\nheredoc body with \"quotes\" and $literal\nEOF",
    );
    expect(parsed.value.text).toContain('\\"quotes\\" and "\'$literal');

    const heredocIdx = wrapper.content.segments.findIndex(
      (segment) => segment.kind === "embed",
    );
    expect(heredocIdx).toBeGreaterThanOrEqual(0);
    if (heredocIdx < 0) return;
    const heredoc = wrapper.content.segments[heredocIdx];
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc || heredoc.kind !== "embed") return;
    expect(heredoc.content.text).toBe(
      'heredoc body with "quotes" and $literal',
    );
    expect(heredoc.projection).toEqual({
      points: heredoc.projection?.points,
    });
    expect(heredoc.projection).not.toHaveProperty("span");

    const projected = projectDescendantSpan(
      parsed.value,
      [wrapperIdx, heredocIdx],
      { start: 0, end: heredoc.content.text.length },
    );
    expect(projected).not.toBeNull();
    if (!projected) return;
    expect(parsed.value.text.slice(projected.start, projected.end)).toContain(
      '\\"quotes\\" and "\'$literal',
    );
  });

  it("accepts adjacent quoted wrapper fragments as one payload word", async () => {
    const parsed = await buildLoadedShellSourceTree(
      "zsh -lc 'cat README.md''x'",
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;
    expect(wrapper.content.text).toBe("cat README.mdx");
  });

  it("rejects wrapper payload fragments split by whitespace as extra argv", async () => {
    const parsed = await buildLoadedShellSourceTree(
      "zsh -lc 'cat README.md' 'x'",
    );
    expect(parsed.ok).toBe(false);
  });

  it("rejects unsafe wrapper payload syntax", async () => {
    const bad = [
      'zsh -lc "cat $HOME/README.md"',
      'zsh -lc "cat `pwd`/README.md"',
      "zsh -lc cat*README.md",
      'bash -lc "echo ok" x',
    ];
    for (const command of bad) {
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(false);
    }
  });

  it("keeps supported outer suffixes outside normalized wrapper embeds", async () => {
    for (const suffix of [";README.md", "|README.md", ">README.md"]) {
      const command = `zsh -lc cat${suffix}`;
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const wrapper = findFirstEmbed(parsed.value.segments);
      expect(wrapper?.span).toEqual({ start: 8, end: 11 });
      expect(wrapper?.content.text).toBe("cat");
      expect(parsed.value.text.slice(11)).toBe(suffix);
      expect(parsed.value.text).toBe(command);
    }
  });

  it("parses shell/bash heredoc bodies recursively and keeps markdown/xml heredocs as text nodes", async () => {
    const directBashCommand = "bash <<'EOF'\ncat README.md\nEOF";
    const directBashParsed =
      await buildLoadedShellSourceTree(directBashCommand);
    expect(directBashParsed.ok).toBe(true);
    if (!directBashParsed.ok) return;
    const directBashHeredoc = findFirstEmbed(directBashParsed.value.segments);
    expect(directBashHeredoc?.content.language).toBe("bash");

    const shellCommand =
      "cat > /tmp/a/script.sh <<'EOF'\nzsh -lc 'cat README.md'\nEOF";
    const shellParsed = await buildLoadedShellSourceTree(shellCommand);
    expect(shellParsed.ok).toBe(true);
    if (!shellParsed.ok) return;
    const shellHeredoc = findFirstEmbed(shellParsed.value.segments);
    expect(shellHeredoc?.kind).toBe("embed");
    if (!shellHeredoc) return;
    expect(shellHeredoc.content.language).toBe("bash");
    expect(shellHeredoc.content.text).toBe("zsh -lc 'cat README.md'");
    expect(shellHeredoc.content.segments).toHaveLength(1);
    expect(shellHeredoc.content.segments[0]?.kind).toBe("text");
    expect(shellParsed.value.text).toBe(shellCommand);

    const shellDocument = await loadParsedShellDocument(shellCommand);
    expect(shellDocument.ok).toBe(true);
    if (shellDocument.ok)
      expect(shellDocument.document.embeddedInvocations).toHaveLength(0);

    const markdownCommand = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const markdownParsed = await buildLoadedShellSourceTree(markdownCommand);
    expect(markdownParsed.ok).toBe(true);
    if (!markdownParsed.ok) return;
    const markdownHeredoc = findFirstEmbed(markdownParsed.value.segments);
    expect(markdownHeredoc?.content.language).toBe("markdown");
    expect(markdownHeredoc?.content.segments).toHaveLength(1);
    expect(markdownHeredoc?.content.segments[0]?.kind).toBe("text");

    const svgCommand = "cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF";
    const svgParsed = await buildLoadedShellSourceTree(svgCommand);
    expect(svgParsed.ok).toBe(true);
    if (!svgParsed.ok) return;
    const svgHeredoc = findFirstEmbed(svgParsed.value.segments);
    expect(svgHeredoc?.content.language).toBe("xml");
    expect(svgHeredoc?.content.segments).toHaveLength(1);
    expect(svgHeredoc?.content.segments[0]?.kind).toBe("text");
  });

  it("returns null for malformed wrapper projections", async () => {
    const parsed = await buildLoadedShellSourceTree("zsh -lc 'cat README.md'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;

    expect(
      projectEmbedSpan(wrapper, {
        start: 0,
        end: wrapper.content.text.length + 1,
      }),
    ).toBeNull();
    expect(
      projectDescendantSpan(parsed.value, [999], { start: 0, end: 1 }),
    ).toBeNull();
    expect(
      projectDescendantSpan(parsed.value, [0], { start: 3, end: 2 }),
    ).toBeNull();

    const malformedProjectionWrapper: Extract<
      SourceSegment,
      { kind: "embed" }
    > = {
      ...wrapper,
      projection: {
        points: [
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
        ],
      },
    };
    expect(
      projectEmbedSpan(malformedProjectionWrapper, { start: 0, end: 1 }),
    ).toBeNull();
  });

  it("supports zero-length wrapper payload projections", async () => {
    const parsed = await buildLoadedShellSourceTree('zsh -lc ""');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;
    expect(wrapper.content.text).toBe("");

    const mapped = projectEmbedSpan(wrapper, { start: 0, end: 0 });
    expect(mapped).not.toBeNull();
    if (!mapped) return;
    expect(mapped.start).toBe(wrapper.span.start);
    expect(mapped.end).toBe(wrapper.span.start);
  });

  it("recognizes python -c double-quoted payload as python embed", async () => {
    const parsed = await buildLoadedShellSourceTree('python -c "import json"');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("python");
    expect(embed.content.text).toBe("import json");
    expect(parsed.value.language).toBe("bash");
  });

  it("recognizes python -c single-quoted payload as python embed", async () => {
    const parsed = await buildLoadedShellSourceTree("python -c 'print(1)'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("python");
    expect(embed.content.text).toBe("print(1)");
  });

  it("recognizes node -e double-quoted payload as javascript embed", async () => {
    const parsed = await buildLoadedShellSourceTree('node -e "console.log(1)"');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("javascript");
    expect(embed.content.text).toBe("console.log(1)");
  });

  it("recognizes ruby -e single-quoted payload as ruby embed", async () => {
    const parsed = await buildLoadedShellSourceTree("ruby -e 'puts 42'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("ruby");
    expect(embed.content.text).toBe("puts 42");
  });

  it("recognizes python3 -c as python embed (basename alias)", async () => {
    const parsed = await buildLoadedShellSourceTree('python3 -c "import sys"');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("python");
    expect(embed.content.text).toBe("import sys");
  });

  it("does not recognize python script.py as a wrapper (no flag)", async () => {
    const parsed = await buildLoadedShellSourceTree("python script.py");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(findFirstEmbed(parsed.value.segments)).toBeNull();
    expect(parsed.value.language).toBe("bash");
  });

  it("does not recognize python -e as a wrapper (wrong flag for python)", async () => {
    const parsed = await buildLoadedShellSourceTree("python -e 'whatever'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(findFirstEmbed(parsed.value.segments)).toBeNull();
  });

  it("does not recognize node -c as a wrapper (wrong flag for node)", async () => {
    const parsed = await buildLoadedShellSourceTree("node -c something");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(findFirstEmbed(parsed.value.segments)).toBeNull();
  });

  it("does not recognize unsupported interpreter as a wrapper", async () => {
    const parsed = await buildLoadedShellSourceTree('go run -e "..."');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(findFirstEmbed(parsed.value.segments)).toBeNull();
  });

  it("accepts trailing I/O redirections after wrapper payload", async () => {
    const cases: [string, string, string][] = [
      ['python -c "import json" 2>&1', "python", "import json"],
      ["python3 -c 'print(1)' >/dev/null 2>&1", "python", "print(1)"],
      ['node -e "console.log(1)" 2>/dev/null', "javascript", "console.log(1)"],
      ['python -c "\nimport json\n" 2>&1', "python", "\nimport json\n"],
    ];
    for (const [command, language, payload] of cases) {
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const embed = findFirstEmbed(parsed.value.segments);
      expect(embed).not.toBeNull();
      if (!embed) continue;
      expect(embed.content.language).toBe(language);
      expect(embed.content.text).toBe(payload);
    }
  });

  it("does not recurse into non-shell interpreter wrapper payloads", async () => {
    // python payload looks like a shell wrapper but must not be recursed into
    const parsed = await buildLoadedShellSourceTree(
      "python -c 'bash -c \"echo hi\"'",
    );
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.language).toBe("python");
    // The child is a leaf — its segments should be a single text segment, not another embed
    expect(embed.content.segments).toHaveLength(1);
    expect(embed.content.segments[0]?.kind).toBe("text");
  });

  it("keeps the compound heredoc header and trailing pipeline parent-owned", async () => {
    const command =
      "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    expect(parsed.value.text).toBe(command);
    expect(parsed.value.text.length).toBe(56);
    expect(parsed.value.segments.map((segment) => segment.span)).toEqual([
      { start: 0, end: 29 },
      { start: 29, end: 37 },
      { start: 37, end: 56 },
    ]);
    const heredoc = findFirstEmbed(parsed.value.segments);
    expect(heredoc?.origin?.construct).toBe("heredoc-body");
    expect(heredoc?.content.language).toBe("python");
    expect(heredoc?.content.text).toBe("print(1)");
    expect(parsed.value.text.slice(0, 29)).toContain("cd /tmp &&");
    expect(parsed.value.text.slice(37)).toBe("\nEOF\ngit diff | cat");
  });

  it("recognizes an env-prefixed heredoc by its effective interpreter", async () => {
    const command = "env FOO=1 python3 - <<EOF\nprint(1)\nEOF";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed?.content.language).toBe("python");
    expect(embed?.content.text).toBe("print(1)");
    expect(parsed.value.text).toBe(command);
    expect(parsed.value.text.slice(0, embed?.span.start ?? 0)).toBe(
      "env FOO=1 python3 - <<EOF\n",
    );
  });

  it("keeps shell prefixes and suffix redirects outside inline payload embeds", async () => {
    const cases = [
      [
        "cd /tmp && python3 -c 'print(1)'",
        "python",
        "print(1)",
        "cd /tmp && python3 -c '",
        "'",
      ],
      [
        "env FOO=1 node -e 'console.log(1)' 2>/dev/null",
        "javascript",
        "console.log(1)",
        "env FOO=1 node -e '",
        "' 2>/dev/null",
      ],
    ] as const;

    for (const [command, language, payload, prefix, suffix] of cases) {
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const embed = findFirstEmbed(parsed.value.segments);
      expect(embed?.content.language).toBe(language);
      expect(embed?.content.text).toBe(payload);
      expect(parsed.value.text).toBe(command);
      expect(parsed.value.text.slice(0, embed?.span.start ?? 0)).toBe(prefix);
      expect(parsed.value.text.slice(embed?.span.end ?? command.length)).toBe(
        suffix,
      );
    }
  });

  it("rejects variable descriptors across line continuations", async () => {
    for (const source of [
      "cat {fd}\\\n>out",
      "cat {fd}\\\r\n>out",
      "cat >a {fd}\\\n>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a {fd}\\\r\n>/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
      "{fd}\\\n>out echo hi",
      "{fd}\\\r\n>out echo hi",
      "{fd}\\\n>out bash -c 'echo hi'",
      "{fd}\\\r\n>out bash -c 'echo hi'",
      "{a}\\\n>one {b}\\\n>two echo hi",
    ])
      await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });

    for (const source of ["cat {fd} \\\n>out", "cat {fd} \\\r\n>out"]) {
      const parsed = await buildLoadedShellSourceTree(source);
      expect(parsed.ok, source).toBe(true);
      if (!parsed.ok) continue;
      expect(reconstructSource(parsed.value)).toBe(source);
      expect(findFirstEmbed(parsed.value.segments)).toBeNull();
    }
  });

  it("rejects recovered prefix words from every redirect channel", async () => {
    for (const [source] of [
      [
        "{fd}\\\n>one echo >two bash -c 'echo hi'",
        "echo",
        ["bash", "-c", "echo hi"],
      ],
      ["{fd}\\\n>&- echo hi", "echo", ["hi"]],
      ["{fd}\\\n<&- echo hi", "echo", ["hi"]],
      [
        "{fd}\\\r\n>one echo >two bash -c 'echo hi'",
        "echo",
        ["bash", "-c", "echo hi"],
      ],
      ["{fd}\\\r\n>&- echo hi", "echo", ["hi"]],
      ["{fd}\\\r\n<&- echo hi", "echo", ["hi"]],
    ] as const)
      await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });

    for (const source of [
      "{a}\\\n>one {b} \\\n>two cat >/tmp/output.py <<EOF\nprint(1)\nEOF",
      "{a}\\\r\n>one {b} \\\r\n>two cat >/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
    ])
      await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
      });
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
      await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
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
          await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
            issue: "error_node",
          });
        }
      }
    }
    for (const source of [
      'cat >/tmp/output.py 2>&-""( extra <<EOF\nprint(1)\nEOF',
      'cat >/tmp/output.py 2>&-""( extra <<EOF\r\nprint(1)\r\nEOF',
    ]) {
      await expect(loadParsedShellDocument(source)).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
        issue: "error_node",
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
              await expect(
                loadParsedShellDocument(source),
              ).resolves.toMatchObject({
                ok: false,
                reason: "unsafe_shell_syntax",
                issue: "error_node",
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
              await expect(
                loadParsedShellDocument(source),
              ).resolves.toMatchObject({
                ok: false,
                reason: "unsafe_shell_syntax",
                issue: "error_node",
              });
            }
          }
        }
      }
    }
  });

  it("preserves valid empty atomic-close continuations and separated argv", async () => {
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const lineEndings = ["\n", "\r\n"] as const;

    for (const descriptor of descriptors) {
      for (const operator of operators) {
        for (const lineEnding of lineEndings) {
          for (const suffix of ["", " argv"] as const) {
            const source = `: ${descriptor}${operator}\\${lineEnding}""${suffix}`;
            const parsed = await loadParsedShellDocument(source);
            expect(parsed, source).toMatchObject({ ok: false });
          }
        }
      }
    }
  });

  it("selects sibling wrapper embeds and leaves their separators raw", async () => {
    const command = "python3 -c 'print(1)' && node -e 'console.log(2)'";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const embeds = parsed.value.segments.filter(
      (segment): segment is Extract<SourceSegment, { kind: "embed" }> =>
        segment.kind === "embed",
    );
    expect(embeds).toHaveLength(2);
    expect(embeds.map((embed) => embed.content.text)).toEqual([
      "print(1)",
      "console.log(2)",
    ]);
    expect(
      parsed.value.text.slice(embeds[0]!.span.end, embeds[1]!.span.start),
    ).toBe("' && node -e '");
    expect(parsed.value.text).toBe(command);
  });

  it("adapts recursive documents without flattening their local invocation IDs", async () => {
    const command = "bash -lc \"python3 -c 'print(1)'\"";
    const result = await loadParsedShellDocument(command);
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const rootInvocation = result.document.embeddedInvocations[0];
    expect(rootInvocation).toBeDefined();
    if (!rootInvocation || !rootInvocation.child) return;
    const childInvocation = rootInvocation.child.embeddedInvocations[0];
    expect(childInvocation).toBeDefined();
    if (!childInvocation) return;
    expect(rootInvocation.id).toBe(0);
    expect(childInvocation.id).toBe(0);

    const tree = buildShellSourceTree(result.document);
    expect(tree.ok).toBe(true);
    if (!tree.ok) return;
    expect(tree.value.text).toBe(command);
    const outer = findFirstEmbed(tree.value.segments);
    expect(outer?.content.text).toBe("python3 -c 'print(1)'");
    expect(outer).not.toBeNull();
    if (!outer) return;
    expect(outer.origin?.attributes?.ownsWholeCommand === true).toBe(true);
    expect(
      outer.content.segments.some(
        (segment) =>
          segment.kind === "embed" && segment.content.language === "python",
      ),
    ).toBe(true);
  });

  it("preserves BMP and astral characters through wrapper projections", async () => {
    const command = 'python3 -c "print(中, \\"😀\\")"';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.text).toBe('print(中, "😀")');
    expect(parsed.value.text).toBe(command);
    const emoji = embed.content.text.indexOf("😀");
    const projected = projectEmbedSpan(embed, {
      start: emoji,
      end: emoji + "😀".length,
    });
    expect(projected).not.toBeNull();
    if (!projected) return;
    expect(parsed.value.text.slice(projected.start, projected.end)).toBe("😀");
  });

  it("preserves CRLF offsets through wrapper projections", async () => {
    const command = 'python3 -c "print(1)\r\n"';
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed).not.toBeNull();
    if (!embed) return;
    expect(embed.content.text).toBe("print(1)\r\n");
    expect(parsed.value.text).toBe(command);

    const projected = projectEmbedSpan(embed, {
      start: 0,
      end: embed.content.text.length,
    });
    expect(projected).not.toBeNull();
    if (!projected) return;
    expect(parsed.value.text.slice(projected.start, projected.end)).toBe(
      "print(1)\r\n",
    );
  });

  it("marks only whole-command Bash wrappers for semantic unwrapping", async () => {
    const positive = [
      "zsh -lc 'cat README.md'",
      "env FOO=1 zsh -lc 'cat README.md'",
      "zsh -lc 'cat README.md' 2>/dev/null",
      "zsh -lc \"bash -lc 'cat README.md'\"",
    ];
    for (const command of positive) {
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const wrapper = findFirstEmbed(parsed.value.segments);
      expect(wrapper).not.toBeNull();
      if (!wrapper) continue;
      expect(isShellCommandWrapperEmbed(wrapper)).toBe(true);
      expect(wrapper.origin?.attributes?.ownsWholeCommand === true).toBe(true);
      expect(wrapper.origin?.attributes?.ownsWholeCommand).toBe(true);
    }

    const negative = [
      "cd /tmp && zsh -lc 'cat README.md'",
      "echo before && zsh -lc 'cat README.md'",
      "zsh -lc 'cat README.md' && echo after",
      "echo before | zsh -lc 'cat README.md'",
      "zsh -lc 'cat README.md' | cat",
      "zsh -lc 'cat README.md';",
      "zsh -lc 'cat README.md'; echo after",
      "zsh -lc 'cat README.md'\necho after",
      ">prefix zsh -lc 'cat README.md'",
    ];
    for (const command of negative) {
      const parsed = await buildLoadedShellSourceTree(command);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const wrapper = parsed.value.segments.find(
        (segment): segment is Extract<SourceSegment, { kind: "embed" }> =>
          segment.kind === "embed" && isShellCommandWrapperEmbed(segment),
      );
      expect(wrapper).not.toBeNull();
      if (!wrapper) continue;
      expect(wrapper.origin?.attributes?.ownsWholeCommand === true).toBe(false);
      expect(wrapper.origin?.attributes?.ownsWholeCommand).toBe(false);
      expect(parsed.value.text).toBe(command);
    }
  });

  it.each([
    ["bash -c 'if'", "unsafe_shell_syntax"],
    ["bash -c 'cat <<EOF'", "invalid_heredoc"],
  ] as const)(
    "does not mark a failed Bash child as owning its command: %s",
    async (source, code) => {
      const loaded = await loadParsedShellDocument(source);
      expect(loaded.ok, source).toBe(true);
      if (!loaded.ok) return;
      const invocation = loaded.document.embeddedInvocations[0];
      if (invocation?.kind !== "inline")
        throw new Error("test Bash invocation is incomplete");

      expect(invocation.child).toBeNull();
      expect(loaded.document.diagnostics).toContainEqual({
        kind: "child_parse_failed",
        span: invocation.payload.rawSpan,
        reason: code,
      });
      expect(ownsWholeCommand(loaded.document, invocation)).toBe(false);

      const expected = {
        ok: false,
        code,
        reason: `shell parser rejected child: ${code}`,
      };
      expect(buildShellSourceTree(loaded.document), source).toEqual(expected);
      await expect(buildLoadedShellSourceTree(source), source).resolves.toEqual(
        expected,
      );
    },
  );

  it("propagates a failed recursive Bash adapter without sibling leakage", async () => {
    const command = "bash -c 'zsh -lc \"cat $HOME/README.md\"'";
    const siblingCommand = `${command} && python3 -c 'print(1)'`;
    for (const source of [command, siblingCommand]) {
      const loaded = await loadParsedShellDocument(source);
      expect(loaded.ok).toBe(true);
      if (!loaded.ok) continue;
      const invocation = loaded.document.embeddedInvocations[0];
      expect(invocation?.child).not.toBeNull();
      if (!invocation?.child) continue;
      expect(
        invocation.child.diagnostics.some(
          (diagnostic) =>
            diagnostic.kind === "unsupported_wrapper" &&
            diagnostic.issue === "dynamic_payload",
        ),
      ).toBe(true);

      const adapted = buildShellSourceTree(loaded.document);
      const parsed = await buildLoadedShellSourceTree(source);
      expect(adapted).toEqual(parsed);
      expect(adapted).toEqual({
        ok: false,
        code: "unsafe_shell_syntax",
        reason: "shell parser rejected unsupported_wrapper",
      });
      expect(adapted).not.toHaveProperty("value");
    }
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
    async (_label, source) => {
      const loaded = await loadParsedShellDocument(source);
      expect(loaded.ok, source).toBe(true);
      if (!loaded.ok) return;
      const expected = {
        ok: false,
        code: "unsafe_shell_syntax",
        reason: "shell parser rejected unsupported_construct",
      };

      expect(buildShellSourceTree(loaded.document), source).toEqual(expected);
      await expect(buildLoadedShellSourceTree(source), source).resolves.toEqual(
        expected,
      );
    },
  );

  it("throws when an opaque unit no longer matches its construct diagnostic", async () => {
    const source = "if true; then echo x; fi";
    const loaded = await loadParsedShellDocument(source);
    expect(loaded.ok, source).toBe(true);
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
    ] as const)
      expect(
        () =>
          buildShellSourceTree({
            ...loaded.document,
            program: { ...loaded.document.program, children: [unit] },
          }),
        label,
      ).toThrow("parsed shell document invariant:");
  });

  it("throws when a normalized Bash invocation is missing its child", async () => {
    const loaded = await loadParsedShellDocument("bash -c 'printf ok'");
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const invocation = loaded.document.embeddedInvocations[0];
    expect(invocation?.kind).toBe("inline");
    if (!invocation || invocation.kind !== "inline") return;
    const missingChild = {
      ...loaded.document,
      embeddedInvocations: [{ ...invocation, child: null }],
    };
    expect(() => buildShellSourceTree(missingChild)).toThrow(
      "parsed shell document invariant: bash invocation child",
    );
  });

  it("throws when a non-Bash invocation has a mismatched stored ID", async () => {
    const loaded = await loadParsedShellDocument("python3 -c 'print(1)'");
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const invocation = loaded.document.embeddedInvocations[0];
    expect(invocation?.kind).toBe("inline");
    if (!invocation || invocation.kind !== "inline") return;

    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        embeddedInvocations: [{ ...invocation, id: 99 }],
      }),
    ).toThrow("parsed shell document invariant: invocation id");
  });

  it("throws when a trailing wrapper redirect is missing from owner forward IDs", async () => {
    const loaded = await loadParsedShellDocument(
      "zsh -lc 'cat README.md' >/tmp/output.log",
    );
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    const redirect = loaded.document.redirects.find(
      (candidate) => candidate.kind === "file",
    );
    expect(redirect?.kind).toBe("file");
    if (!redirect) return;

    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        commands: loaded.document.commands.map((command) =>
          command.id === redirect.ownerId
            ? { ...command, redirectIds: [] }
            : command,
        ),
      }),
    ).toThrow("parsed shell document invariant: redirect owner membership");
  });

  it("throws on impossible normalized invocation and redirect identities", async () => {
    const wrapperLoaded = await loadParsedShellDocument(
      "zsh -lc 'cat README.md' 2>/dev/null",
    );
    expect(wrapperLoaded.ok).toBe(true);
    if (!wrapperLoaded.ok) return;
    const wrapperInvocation = wrapperLoaded.document.embeddedInvocations[0];
    expect(wrapperInvocation?.kind).toBe("inline");
    if (!wrapperInvocation || wrapperInvocation.kind !== "inline") return;

    expect(() =>
      buildShellSourceTree({
        ...wrapperLoaded.document,
        embeddedInvocations: [{ ...wrapperInvocation, commandId: 99 }],
      }),
    ).toThrow("parsed shell document invariant: command id");

    const wrapperRedirect = wrapperLoaded.document.redirects.find(
      (redirect) => redirect.kind === "file",
    );
    expect(wrapperRedirect?.kind).toBe("file");
    if (!wrapperRedirect) return;

    expect(() =>
      buildShellSourceTree({
        ...wrapperLoaded.document,
        redirects: [{ ...wrapperRedirect, ownerId: 99 }],
      }),
    ).toThrow("parsed shell document invariant: command id");
    expect(() =>
      buildShellSourceTree({
        ...wrapperLoaded.document,
        redirects: [{ ...wrapperRedirect, id: 99 }],
      }),
    ).toThrow("parsed shell document invariant: redirect id");

    const heredocLoaded = await loadParsedShellDocument(
      "python3 - <<EOF\nx\nEOF",
    );
    expect(heredocLoaded.ok).toBe(true);
    if (!heredocLoaded.ok) return;
    const heredocInvocation = heredocLoaded.document.embeddedInvocations[0];
    expect(heredocInvocation?.kind).toBe("heredoc");
    if (!heredocInvocation || heredocInvocation.kind !== "heredoc") return;
    const heredocRedirect = heredocLoaded.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    expect(heredocRedirect?.kind).toBe("heredoc");
    if (!heredocRedirect) return;

    expect(() =>
      buildShellSourceTree({
        ...heredocLoaded.document,
        embeddedInvocations: [{ ...heredocInvocation, heredocRedirectId: 99 }],
      }),
    ).toThrow("parsed shell document invariant: redirect id");
    expect(() =>
      buildShellSourceTree({
        ...heredocLoaded.document,
        redirects: [{ ...heredocRedirect, ownerId: 99 }],
      }),
    ).toThrow("parsed shell document invariant: command id");
    expect(() =>
      buildShellSourceTree({
        ...heredocLoaded.document,
        redirects: [{ ...heredocRedirect, id: 99 }],
      }),
    ).toThrow("parsed shell document invariant: heredoc redirect id");

    const catLoaded = await loadParsedShellDocument(
      "cat >output.md <<EOF\nbody\nEOF",
    );
    expect(catLoaded.ok).toBe(true);
    if (!catLoaded.ok) return;
    const catRedirect = catLoaded.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    expect(catRedirect?.kind).toBe("heredoc");
    if (!catRedirect) return;
    expect(() =>
      buildShellSourceTree({
        ...catLoaded.document,
        redirects: catLoaded.document.redirects.map((redirect) =>
          redirect.id === catRedirect.id
            ? { ...catRedirect, ownerId: 99 }
            : redirect,
        ),
      }),
    ).toThrow("parsed shell document invariant: command id");
    expect(() =>
      buildShellSourceTree({
        ...catLoaded.document,
        redirects: catLoaded.document.redirects.map((redirect) =>
          redirect.id === catRedirect.id
            ? { ...catRedirect, id: 99 }
            : redirect,
        ),
      }),
    ).toThrow("parsed shell document invariant: heredoc redirect id");
  });

  it("validates corrupted diagnostics before SourceTree fallback selection", async () => {
    const loaded = await loadParsedShellDocument(
      "env -i cat README.md >/tmp/output.log",
    );
    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    expect(buildShellSourceTree(loaded.document)).toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "shell parser rejected unsupported_env",
    });
    const redirect = loaded.document.redirects[0];
    if (redirect === undefined) throw new Error("test redirect missing");
    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        commands: loaded.document.commands.map((command) =>
          command.id === redirect.ownerId
            ? { ...command, redirectIds: [] }
            : command,
        ),
      }),
    ).toThrow("parsed shell document invariant: redirect owner membership");
  });

  it("validates invocation provenance before SourceTree candidate selection", async () => {
    const ordinaryLoaded = await loadParsedShellDocument(
      "cat README.md >/tmp/out4",
    );
    expect(ordinaryLoaded.ok).toBe(true);
    if (!ordinaryLoaded.ok) return;
    const ordinaryRedirect = ordinaryLoaded.document.redirects[0];
    if (ordinaryRedirect === undefined)
      throw new Error("test ordinary redirect missing");
    expect(() =>
      buildShellSourceTree({
        ...ordinaryLoaded.document,
        commands: ordinaryLoaded.document.commands.map((command) =>
          command.id === ordinaryRedirect.ownerId
            ? { ...command, redirectIds: [] }
            : command,
        ),
      }),
    ).toThrow("parsed shell document invariant: redirect owner membership");

    const inlineLoaded = await loadParsedShellDocument(
      "python3 -c 'print(1)' >/tmp/out3",
    );
    expect(inlineLoaded.ok).toBe(true);
    if (!inlineLoaded.ok) return;
    const inlineInvocation = inlineLoaded.document.embeddedInvocations[0];
    const inlineRedirect = inlineLoaded.document.redirects[0];
    expect(inlineInvocation?.kind).toBe("inline");
    if (inlineInvocation?.kind !== "inline" || inlineRedirect === undefined)
      return;

    expect(() =>
      buildShellSourceTree({
        ...inlineLoaded.document,
        redirects: [{ ...inlineRedirect, id: 99 }],
      }),
    ).toThrow("parsed shell document invariant: redirect id");
    expect(() =>
      buildShellSourceTree({
        ...inlineLoaded.document,
        embeddedInvocations: [{ ...inlineInvocation, flagArgumentIndex: 99 }],
      }),
    ).toThrow("parsed shell document invariant: inline argument indices");
    expect(() =>
      buildShellSourceTree({
        ...inlineLoaded.document,
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
      }),
    ).toThrow("parsed shell document invariant:");
    expect(() =>
      buildShellSourceTree({
        ...inlineLoaded.document,
        embeddedInvocations: [
          { ...inlineInvocation, child: inlineLoaded.document },
        ],
      }),
    ).toThrow("parsed shell document invariant: non-bash invocation child");

    const envLoaded = await loadParsedShellDocument(
      "env FOO=bar python3 -c 'print(1)'",
    );
    expect(envLoaded.ok).toBe(true);
    if (!envLoaded.ok) return;
    const envInvocation = envLoaded.document.embeddedInvocations[0];
    expect(envInvocation?.prefix.kind).toBe("env");
    if (envInvocation?.prefix.kind !== "env") return;
    expect(() =>
      buildShellSourceTree({
        ...envLoaded.document,
        embeddedInvocations: [
          {
            ...envInvocation,
            interpreter: {
              ...envInvocation.interpreter,
              location: { kind: "command_name" },
            },
          },
        ],
      }),
    ).toThrow("parsed shell document invariant: env interpreter index");

    const heredocLoaded = await loadParsedShellDocument(
      "python3 - <<EOF\nprint(1)\nEOF",
    );
    expect(heredocLoaded.ok).toBe(true);
    if (!heredocLoaded.ok) return;
    const heredocInvocation = heredocLoaded.document.embeddedInvocations[0];
    expect(heredocInvocation?.kind).toBe("heredoc");
    if (heredocInvocation?.kind !== "heredoc") return;
    expect(() =>
      buildShellSourceTree({
        ...heredocLoaded.document,
        embeddedInvocations: [{ ...heredocInvocation, heredocRedirectId: 99 }],
      }),
    ).toThrow("parsed shell document invariant: redirect id");
  });

  it("uses the effective stdout file redirect for non-interpreter heredocs", async () => {
    const body = "print(1)";
    const cases = [
      ["cat", ">/tmp/output.py", "python"],
      ["cat", ">>/tmp/output.py", "python"],
      ["cat", ">|/tmp/output.py", "python"],
      ["cat", "1>/tmp/output.py", "python"],
      ["cat", "1>>/tmp/output.py", "python"],
      ["cat", "1>|/tmp/output.py", "python"],
      ["cat", "2>/tmp/output.py", "text"],
      ["cat", ">/tmp/output.py 2>/tmp/error", "python"],
      ["cat", "2>/tmp/error >/tmp/output.py", "python"],
      ["cat", "&>/tmp/output.py", "python"],
      ["cat", "&>>/tmp/output.py", "python"],
      ["cat", "&>/tmp/output.py 2>/tmp/error", "python"],
      ["cat", "2>/tmp/error &>/tmp/output.py", "python"],
      ["cat", ">/tmp/output.txt >/tmp/output.py", "python"],
      ["cat", ">/tmp/output.py 1>&2", "text"],
      ["cat", ">$OUTPUT.py", "text"],
      ["cat", ">$OUTPUT >/tmp/output.py", "python"],
      ["cat", '2>/tmp/output.py 1>&"02"', "python"],
      ["cat", "2>/tmp/output.py 1>&'0'2", "python"],
      ["cat", '2>/tmp/output.py >&"02"', "python"],
      ["cat", '3>/tmp/output.py 4<&"03" 1>&4', "python"],
      ["cat", '>"2"', "text"],
      ["cat", ">>'03'", "text"],
      ["cat", '>|"000"', "text"],
      ["cat", '&>"2"', "text"],
      ["cat", "&>>'03'", "text"],
      ["tee", ">/tmp/output.py", "python"],
      ["/usr/bin/cat", ">/tmp/output.py", "python"],
      ["cat", ">&/tmp/output.py", "python"],
      ["cat", "2>/tmp/output.py 1>&2", "python"],
      ["cat", "&>/tmp/output.py 1>&2", "python"],
      ["cat", "1>&2 2>/tmp/output.py", "text"],
      ["cat", "2>/tmp/output.py >&2", "python"],
      ["cat", "3>/tmp/output.py 1>&3", "python"],
      ["cat", ">/tmp/output.py 2>&1 1>&2", "python"],
      ["cat", ">&/tmp/output.py 1>/tmp/final.md", "markdown"],
      ["cat", "1>&/tmp/output.py", "python"],
      ["cat", "3>/tmp/output.py 3</tmp/input 1>&3", "text"],
      ["cat", "3>/tmp/output.py 4<&3 1>&4", "python"],
      ["cat", "2>$OUTPUT 1>&2", "text"],
    ] as const;
    for (const [owner, redirects, language] of cases) {
      const source = `${owner} ${redirects} <<EOF\n${body}\nEOF`;
      const parsed = await buildLoadedShellSourceTree(source);
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) continue;
      const embed = findFirstEmbed(parsed.value.segments);
      expect(embed?.content.language, `${owner} ${redirects}`).toBe(language);
      expect(embed?.content.text).toBe(body);
      expect(parsed.value.text).toBe(source);
      expect(reconstructSource(parsed.value)).toBe(source);
    }
    const dynamicOwner = `"$CAT" >/tmp/output.py <<EOF\n${body}\nEOF`;
    const dynamicParsed = await buildLoadedShellSourceTree(dynamicOwner);
    expect(dynamicParsed.ok).toBe(true);
    if (!dynamicParsed.ok) return;
    expect(findFirstEmbed(dynamicParsed.value.segments)?.content.language).toBe(
      "text",
    );
  });

  it("requires a cat heredoc to remain the effective stdin for output language", async () => {
    const body = "print(1)";
    const cases = [
      ["cat >output.py <<EOF\nprint(1)\nEOF", "python"],
      ["cat >output.py 2<<EOF\nprint(1)\nEOF", "text"],
      ["cat >output.py 1<&0 <<EOF\nprint(1)\nEOF", "text"],
      ["cat >output.py <<EOF <in\nprint(1)\nEOF", "text"],
      ["cat >output.py <in <<EOF\nprint(1)\nEOF", "python"],
    ] as const;

    for (const [source, language] of cases) {
      const parsed = await buildLoadedShellSourceTree(source);
      expect(parsed.ok, source).toBe(true);
      if (!parsed.ok) continue;
      const embed = findFirstEmbed(parsed.value.segments);
      expect(embed?.content.language, source).toBe(language);
      expect(embed?.content.text, source).toBe(body);
      expect(reconstructSource(parsed.value), source).toBe(source);
    }

    await expect(
      loadParsedShellDocument("cat >output.py {fd}<<EOF\nprint(1)\nEOF"),
    ).resolves.toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });

    for (const source of [
      "cat >output.py 0<&1 <<EOF\nprint(1)\nEOF",
      "cat >output.py 0<&- <<EOF\nprint(1)\nEOF",
    ])
      await expect(
        loadParsedShellDocument(source),
        source,
      ).resolves.toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
      });
  });

  it("validates command and descriptor provenance before building a SourceTree", async () => {
    const multiCommand = await loadParsedShellDocument(
      "echo hi; cat README.md",
    );
    expect(multiCommand.ok).toBe(true);
    if (!multiCommand.ok) return;
    const [firstUnit, secondUnit] = multiCommand.document.program.children;
    const [echoCommand, catCommand] = multiCommand.document.commands;
    if (
      firstUnit?.kind !== "command" ||
      secondUnit?.kind !== "command" ||
      echoCommand === undefined ||
      catCommand === undefined
    )
      throw new Error("test command units are incomplete");
    expect(() =>
      buildShellSourceTree({
        ...multiCommand.document,
        program: {
          ...multiCommand.document.program,
          children: [
            { ...firstUnit, commandId: secondUnit.commandId },
            secondUnit,
          ],
        },
      }),
    ).toThrow("parsed shell document invariant: command unit references");
    expect(() =>
      buildShellSourceTree({
        ...multiCommand.document,
        commands: [{ ...echoCommand, name: catCommand.name }, catCommand],
      }),
    ).toThrow("parsed shell document invariant: command name span");
    expect(() =>
      buildShellSourceTree({
        ...multiCommand.document,
        commands: [
          { ...echoCommand, arguments: [catCommand.arguments[0]!] },
          catCommand,
        ],
      }),
    ).toThrow("parsed shell document invariant: command argument span");

    const narrowed = await loadParsedShellDocument("cat README.md >out");
    expect(narrowed.ok).toBe(true);
    if (!narrowed.ok) return;
    const narrowedCommand = narrowed.document.commands[0];
    if (narrowedCommand === undefined)
      throw new Error("test narrowed command is incomplete");
    expect(() =>
      buildShellSourceTree({
        ...narrowed.document,
        commands: [
          {
            ...narrowedCommand,
            span: {
              start: narrowedCommand.span.start,
              end: narrowedCommand.name.rawSpan.end,
            },
          },
        ],
      }),
    ).toThrow("parsed shell document invariant: command argument span");

    const numeric = await loadParsedShellDocument("cat 12>out");
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
    expect(() =>
      buildShellSourceTree({
        ...numeric.document,
        redirects: [
          {
            ...numericRedirect,
            descriptor: { ...numericDescriptor, value: "1" },
          },
        ],
      }),
    ).toThrow("parsed shell document invariant: redirect descriptor value");
  });

  it("fails fast when a sole command unit stops before its argument", async () => {
    const source = "cat README.md";
    expect(source).toHaveLength(13);
    const loaded = await loadParsedShellDocument(source);
    expect(loaded.ok, source).toBe(true);
    if (!loaded.ok) return;
    const [unit] = loaded.document.program.children;
    if (
      loaded.document.program.children.length !== 1 ||
      unit?.kind !== "command" ||
      unit.span.end !== 13
    )
      throw new Error("test sole command unit is incomplete");

    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        program: {
          ...loaded.document.program,
          children: [{ ...unit, span: { ...unit.span, end: 12 } }],
        },
      }),
    ).toThrow("parsed shell document invariant:");
  });

  it("throws when a synthetic marker hides an ordinary command argument", async () => {
    const source = "cat REVIEW-SYNTHETIC.md";
    const loaded = await loadParsedShellDocument(source);
    expect(loaded.ok, source).toBe(true);
    if (!loaded.ok) return;
    const command = loaded.document.commands[0];
    const argument = command?.arguments[0];
    const unit = loaded.document.program.children[0];
    if (
      loaded.document.commands.length !== 1 ||
      command === undefined ||
      command.arguments.length !== 1 ||
      argument === undefined ||
      argument.synthetic ||
      argument.word.kind !== "literal" ||
      argument.word.syntax === "synthetic" ||
      unit?.kind !== "command" ||
      unit.span.start !== 0 ||
      unit.span.end !== source.length
    )
      throw new Error("test ordinary argument record is incomplete");

    const corruptions = [
      {
        label: "ordinary argument marked synthetic",
        document: {
          ...loaded.document,
          commands: [
            {
              ...command,
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
              ...command,
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
    for (const corruption of corruptions)
      expect(
        () => buildShellSourceTree(corruption.document),
        corruption.label,
      ).toThrow("parsed shell document invariant:");
  });

  it("validates redirect components and heredoc header anchors before building a SourceTree", async () => {
    const loadDocument = async (source: string) => {
      const loaded = await loadParsedShellDocument(source);
      expect(loaded.ok, source).toBe(true);
      if (!loaded.ok)
        throw new Error(
          `expected normalized document: ${source}: ${loaded.reason}`,
        );
      return loaded.document;
    };
    const expectInvariant = (
      document: Awaited<ReturnType<typeof loadDocument>>,
    ) => {
      expect(() => buildShellSourceTree(document)).toThrow(
        "parsed shell document invariant:",
      );
    };

    const quotedDestination = await loadDocument(
      'cat <"in>out" <<EOF\nbody\nEOF',
    );
    const quotedRedirect = quotedDestination.redirects[0];
    if (
      quotedRedirect?.kind !== "file" ||
      quotedRedirect.destination?.kind !== "literal"
    )
      throw new Error("test quoted redirect is incomplete");
    const quotedOperatorStart = quotedDestination.source.indexOf(
      ">",
      quotedRedirect.destination.rawSpan.start,
    );
    if (quotedOperatorStart < quotedRedirect.destination.rawSpan.start)
      throw new Error("test quoted destination operator is missing");
    expectInvariant({
      ...quotedDestination,
      redirects: quotedDestination.redirects.map((redirect) =>
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

    const descriptorDestination = await loadDocument(
      "cat 1>2 <<EOF\nbody\nEOF",
    );
    const descriptorRedirect = descriptorDestination.redirects[0];
    if (descriptorRedirect?.kind !== "file")
      throw new Error("test descriptor redirect is incomplete");
    const { descriptor, destination } = descriptorRedirect;
    if (descriptor?.kind !== "number" || destination?.kind !== "literal")
      throw new Error("test descriptor redirect is incomplete");
    expect(destination.value).toBe("2");
    expect(descriptor.value).toBe("1");
    expectInvariant({
      ...descriptorDestination,
      redirects: descriptorDestination.redirects.map((redirect) =>
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
        source: "cd /tmp && python3 - <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("python3"),
      },
      {
        source: "mkdir output\ncat <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("mkdir"),
      },
      {
        source: "cat <<EOF\nbody\nEOF",
        headerStart: (source: string) => source.indexOf("<<"),
      },
    ] as const;
    for (const testCase of headerCases) {
      const document = await loadDocument(testCase.source);
      const heredoc = document.redirects.find(
        (redirect) => redirect.kind === "heredoc",
      );
      if (heredoc === undefined)
        throw new Error("test heredoc redirect is missing");
      const headerStart = testCase.headerStart(testCase.source);
      if (headerStart < 0 || heredoc.headerSpan.start === headerStart)
        throw new Error("test heredoc anchor is incomplete");
      expectInvariant({
        ...document,
        redirects: document.redirects.map((redirect) =>
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

  it("throws for a file redirect payload transplanted from its later sibling", async () => {
    const source = "cat >out.py 2>err.log <<EOF\nprint(1)\nEOF";
    const loaded = await loadParsedShellDocument(source);
    expect(loaded.ok, source).toBe(true);
    if (!loaded.ok) return;
    const [firstRedirect, secondRedirect] = loaded.document.redirects;
    if (
      firstRedirect?.kind !== "file" ||
      secondRedirect?.kind !== "file" ||
      firstRedirect.destination === null ||
      secondRedirect.destination === null
    )
      throw new Error("test paired file redirects are incomplete");
    const secondDestination = secondRedirect.destination;

    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        redirects: loaded.document.redirects.map((redirect) =>
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
      }),
    ).toThrow("parsed shell document invariant:");
  });

  it("throws for co-mutated redirected-statement and heredoc header starts", async () => {
    const source =
      "mkdir -p output\n# neighboring trivia\ncat >out.py <<EOF\nprint(1)\nEOF";
    const loaded = await loadParsedShellDocument(source);
    expect(loaded.ok, source).toBe(true);
    if (!loaded.ok) return;
    const [firstUnit, secondUnit] = loaded.document.program.children;
    const heredoc = loaded.document.redirects.find(
      (redirect) => redirect.kind === "heredoc",
    );
    const commentStart = source.indexOf("# neighboring trivia");
    if (
      loaded.document.program.children.length !== 2 ||
      firstUnit?.kind !== "command" ||
      secondUnit?.kind !== "redirected_statement" ||
      heredoc === undefined ||
      commentStart < 0 ||
      secondUnit.span.start <= commentStart ||
      heredoc.headerSpan.start <= commentStart
    )
      throw new Error("test redirected statement header is incomplete");

    expect(() =>
      buildShellSourceTree({
        ...loaded.document,
        program: {
          ...loaded.document.program,
          children: [
            firstUnit,
            {
              ...secondUnit,
              span: { ...secondUnit.span, start: commentStart },
            },
          ],
        },
        redirects: loaded.document.redirects.map((redirect) =>
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
      }),
    ).toThrow("parsed shell document invariant:");
  });

  it("keeps sibling redirects out of a heredoc owner's language policy", async () => {
    const command = "echo before >/tmp/other.py; cat <<EOF\nprint(1)\nEOF";
    const parsed = await buildLoadedShellSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const embed = findFirstEmbed(parsed.value.segments);
    expect(embed?.content.language).toBe("text");
    expect(parsed.value.text).toBe(command);
  });

  it("keeps adjacent fd-zero output redirects on the typed raw path", async () => {
    for (const source of [
      "cat 0>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat 01>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat 0<<EOF\nprint(1)\nEOF",
      "cat >a 0>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0>&1",
      "cat >a 0<&1",
      "cat >a 01>/tmp/output.py",
      "cat >a 0>/tmp/output.py 1>&2",
    ]) {
      const parsed = await loadParsedShellDocument(source);
      expect(parsed, source).toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
      });
    }

    const wrapped = await loadParsedShellDocument(
      "bash -c 'cat >a 0>/tmp/output.py'",
    );
    expect(wrapped.ok).toBe(true);
    if (!wrapped.ok) return;
    expect(wrapped.document.diagnostics).toMatchObject([
      { kind: "child_parse_failed", reason: "unsafe_shell_syntax" },
    ]);
    expect(buildShellSourceTree(wrapped.document)).toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "shell parser rejected child: unsafe_shell_syntax",
    });
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
      const parsed = await loadParsedShellDocument(source);
      expect(parsed, source).toMatchObject({
        ok: false,
        reason: "unsafe_shell_syntax",
      });
    }
  });

  it("keeps a whitespace boundary before a continuation numeric argument", async () => {
    for (const source of ["cat >a 0 \\\n>out", "cat >a 0 \\\r\n>out"]) {
      const parsed = await buildLoadedShellSourceTree(source);
      expect(parsed.ok, source).toBe(true);
      if (!parsed.ok) continue;
      expect(parsed.value.text).toBe(source);
      expect(reconstructSource(parsed.value)).toBe(source);
      expect(findFirstEmbed(parsed.value.segments)).toBeNull();
    }
  });

  it("keeps bare atomic close suffix arguments out of redirect destinations", async () => {
    for (const source of ["cat >&- x", "cat <&- x"] as const) {
      const parsed = await loadParsedShellDocument(source);
      expect(parsed.ok, source).toBe(false);
    }

    const wrapperSource = "bash -c 'echo x' >&- x";
    const wrapper = await loadParsedShellDocument(wrapperSource);
    expect(wrapper).toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });
});

describe("heredoc routing", () => {
  const body = "\n# Title\n- a\nEOF";

  it.each([
    ["cat", "cat >note.md <<'EOF'", "markdown"],
    ["assigned-cat", "X=1 cat >note.md <<'EOF'", "markdown"],
    ["cat-stdin-operand", "cat - >note.md <<'EOF'", "markdown"],
    ["cat-file-operand", "cat a >note.md <<'EOF'", "text"],
    ["cat-overflow-operand", "cat 2147483648>out.md <<'EOF'", "text"],
    ["cat-null", "cat >/dev/null <<'EOF'", "text"],
    ["cat-stderr", "cat <<'EOF' >&2", "text"],
    ["cat-stderr-file", "cat 2>note.md 1>&2 <<'EOF'", "markdown"],
    ["cat-stderr-late-file", "cat 1>&2 2>note.md <<'EOF'", "text"],
    ["tee", "tee note.md >/dev/null <<'EOF'", "markdown"],
    ["tee-assigned", "X=1 tee note.md >/dev/null <<'EOF'", "markdown"],
    ["tee-append", "tee -a note.md 1>/dev/null <<'EOF'", "markdown"],
    ["tee-clobber-null", "tee note.md >|/dev/null <<'EOF'", "markdown"],
    ["tee-conflict", "tee note.md other.py >/dev/null <<'EOF'", "text"],
    ["tee-consensus", "tee note.md other.md >/dev/null <<'EOF'", "markdown"],
    ["tee-stdout-conflict", "tee note.md >other.py <<'EOF'", "text"],
    [
      "tee-untyped-other",
      "tee note.md other.txt >/dev/null <<'EOF'",
      "markdown",
    ],
    [
      "tee-dynamic-other",
      "tee note.md \"$TARGET\" >/dev/null <<'EOF'",
      "markdown",
    ],
    ["tee-json", "tee out.json >/dev/null <<'EOF'", "json"],
    ["tee-python", "tee out.py >/dev/null <<'EOF'", "python"],
    ["tee-bash", "tee out.sh >/dev/null <<'EOF'", "bash"],
    ["tee-yaml", "tee out.yaml >/dev/null <<'EOF'", "yaml"],
    ["python-program", "python <<'EOF'", "python"],
    ["tee-append-f", "tee -a f.md 1>/dev/null <<'EOF'", "markdown"],
    ["tee-no-operand", "tee >f.py <<'EOF'", "python"],
    ["tee-conflict-f", "tee a.md b.py >/dev/null <<'EOF'", "text"],
    ["tee-untyped-f", "tee a.md log.txt >/dev/null <<'EOF'", "markdown"],
    ["cat-file-f", "cat a >f.md <<'EOF'", "text"],
    ["cat-stdin-f", "cat - >f.md <<'EOF'", "markdown"],
    ["cat-option-f", "cat -n >f.md <<'EOF'", "text"],
    ["cat-dup-python", "cat 2>f.py 1>&2 <<'EOF'", "python"],
    ["cat-dup-python-late", "cat 1>&2 2>f.py <<'EOF'", "text"],
    ["tee-assigned-f", "X=1 tee f.md >/dev/null <<'EOF'", "markdown"],
    ["cd-cat", "cd d && cat >f.md <<'EOF'", "markdown"],
    ["cat-svg", "cat >x.svg <<'EOF'", "xml"],
    ["tee-svg", "tee x.svg >/dev/null <<'EOF'", "xml"],
    ["cat-stdin-operands", "cat - - >note.md <<'EOF'", "markdown"],
    ["cat-dynamic-operand", "cat \"$INPUT\" >note.md <<'EOF'", "text"],
    ["tee-long-append", "tee --append note.md >/dev/null <<'EOF'", "markdown"],
    ["tee-end-options", "tee -- -note.md >/dev/null <<'EOF'", "markdown"],
    ["tee-unknown-option", "tee --unknown note.md >out.py <<'EOF'", "text"],
    ["tee-heredoc-on-stderr", "tee note.md <in >/dev/null 2<<'EOF'", "text"],
  ])("routes %s using its sinks", async (_label, header, language) => {
    const tree = await buildLoadedShellSourceTree(header + body);
    expect(tree).toMatchObject({ ok: true });
    if (!tree.ok) throw new Error(tree.reason);
    const embed = findFirstEmbed(tree.value.segments);
    expect(embed?.content.language).toBe(language);
    expect(embed?.presentation?.kind).toBe(
      language === "text" || language === "bash" ? undefined : "rich",
    );
  });

  it("keeps Markdown when tee has an additional numeric file sink", async () => {
    const parsed = await loadParsedShellDocument(
      "tee out.md 2147483648>/dev/null <<'EOF'" + body,
    );
    if (!parsed.ok) throw new Error(parsed.reason);
    const { sources } = analyzeShellDocument(parsed.document);
    expect(sources).toMatchObject([
      {
        sinks: [
          { kind: "file", path: "out.md", mode: "overwrite" },
          { kind: "file", path: "2147483648", mode: "overwrite" },
          { kind: "discard" },
        ],
      },
    ]);
    const tree = buildShellSourceTree(parsed.document);
    if (!tree.ok) throw new Error(tree.reason);
    expect(findFirstEmbed(tree.value.segments)).toMatchObject({
      content: { language: "markdown" },
      presentation: { kind: "rich" },
    });
  });

  it("keeps Python program input when stdout is redirected to JSON", async () => {
    const tree = await buildLoadedShellSourceTree(
      "python3 - <<PY > out.json\nprint(1)\nPY",
    );
    expect(tree).toMatchObject({ ok: true });
    if (!tree.ok) throw new Error(tree.reason);
    expect(findFirstEmbed(tree.value.segments)).toMatchObject({
      content: { language: "python", text: "print(1)" },
      presentation: { kind: "rich" },
    });
  });

  it.each([
    ["cat-late-file-operand", "cat >note.md <<'EOF' a"],
    ["tee-late-operand", "tee >/dev/null <<'EOF' note.md"],
  ])("rejects the unsupported header in %s", async (_label, header) => {
    expect(await buildLoadedShellSourceTree(header + body)).toMatchObject({
      ok: false,
      code: "invalid_heredoc",
      reason: "shell parser rejected heredoc header",
    });
  });

  it.each([
    ["cat-fd0-replaced", "cat >note.md <<'EOF' 0>out"],
    ["cat-dup-stdin", "cat 3<<'EOF' 0<&3 >note.md"],
  ])("keeps the parser rejection for %s", async (_label, header) => {
    expect(await loadParsedShellDocument(header + body)).toMatchObject({
      ok: false,
      reason: "unsafe_shell_syntax",
      issue: "error_node",
    });
  });

  const markdownBody =
    "\n# Title\n\nSome *markdown* with a list:\n- a\n- b\nEOF";

  it.each([
    ["trigger", " && ", "tee 21420/doc.md >/dev/null", body],
    ["tee-and", " && ", "tee 21420/doc.md >/dev/null", markdownBody],
    ["tee-newline", "\n", "tee 21420/doc.md >/dev/null", markdownBody],
    ["cat-and", " && ", "cat >21420/doc.md", markdownBody],
    ["cat-newline", "\n", "cat >21420/doc.md", markdownBody],
  ])(
    "routes the nested [0, 0] heredoc in %s",
    async (_label, joiner, writer, heredoc) => {
      const command = `/run/current-system/sw/bin/zsh -lc "mkdir -p 21420${joiner}${writer} <<'EOF'${heredoc}"`;
      const tree = await buildLoadedShellSourceTree(command);
      expect(tree).toMatchObject({ ok: true });
      if (!tree.ok) throw new Error(tree.reason);
      const wrapper = findFirstEmbed(tree.value.segments);
      expect(wrapper?.content.language).toBe("bash");
      expect(findFirstEmbed(wrapper!.content.segments)).toMatchObject({
        content: {
          language: "markdown",
          text: heredoc.slice(1, -"\nEOF".length),
        },
        presentation: { kind: "rich" },
      });
    },
  );
});
