// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { beforeAll, expect, it, vi } from "vitest";
import * as treeSitter from "web-tree-sitter";
import * as parser from "../lib/shellParser";
import * as semanticApi from "../lib/shellSemantic";
import { actStep, joinedRows } from "../test-support/preactAct";
import {
  changedColors,
  coloredPre,
  configureInstalledBytesParser,
  directPreColors,
  expectHighlightedPre,
  processLike,
  toolInput,
  warmHighlighter,
} from "./ToolCall.shellSourceTree.fixture";

beforeAll(configureInstalledBytesParser);
beforeAll(warmHighlighter("bash", "python"));
const run = joinedRows();

it("keeps recognized semantic and source-tree selectors through a theme rerender", (context) =>
  run(context, async ({ root, poll }) => {
    const command = "python3 - <<'PY'\nprint(1)\nPY";
    const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      void act(() => {
        render(toolInput(command, "dark"), root);
      });
      await poll(
        {
          description: "semantic shell script selector",
          ready: () =>
            !!root.querySelector('[data-testid="semantic-shell-script"]'),
        },
        {
          description: "source-tree input selector",
          ready: () =>
            !!root.querySelector('[data-testid="source-tree-input"]'),
        },
        coloredPre(root, '[data-testid="source-tree-input"] pre.write-content'),
      );
      const darkColors = directPreColors(
        root,
        '[data-testid="source-tree-input"] pre.write-content',
      );
      expect(
        root.querySelector('[data-testid="semantic-shell-script"]'),
      ).not.toBeNull();
      expect(
        root.querySelector('[data-testid="source-tree-input"]'),
      ).not.toBeNull();
      expectHighlightedPre(
        root,
        '[data-testid="source-tree-input"] pre.write-content',
      );
      expect(parse).toHaveBeenCalledTimes(1);

      void act(() => {
        render(toolInput(command, "light"), root);
      });
      expect(
        root.querySelector('[data-testid="semantic-shell-script"]'),
      ).not.toBeNull();
      expect(
        root.querySelector('[data-testid="source-tree-input"]'),
      ).not.toBeNull();
      await poll(
        changedColors(
          root,
          '[data-testid="source-tree-input"] pre.write-content',
          darkColors,
        ),
      );
      const lightColors = directPreColors(
        root,
        '[data-testid="source-tree-input"] pre.write-content',
      );
      expect(lightColors).not.toEqual(darkColors);
      expect(
        root.querySelector('[data-testid="semantic-shell-script"]'),
      ).not.toBeNull();
      expect(
        root.querySelector('[data-testid="source-tree-input"]'),
      ).not.toBeNull();
      expect(parse).toHaveBeenCalledTimes(1);

      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps ambiguous variable redirect input raw and highlighted", (context) =>
  run(context, async ({ root, poll }) => {
    const command = "cat >{fd}>b";
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      void act(() => {
        render(toolInput(command, "dark"), root);
      });

      const firstLoad = load.mock.results[0]?.value as
        | Promise<unknown>
        | undefined;
      expect(firstLoad).toBeDefined();
      if (!firstLoad) return;

      await act(async () => {
        await firstLoad.catch(() => undefined);
      });
      await poll(coloredPre(root, "pre.write-content"));

      const raw = root.querySelector<HTMLPreElement>("pre.write-content");
      expect(raw).not.toBeNull();
      expect(raw?.textContent).toBe(command);
      expectHighlightedPre(root, "pre.write-content");
      expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
        null,
      );
      expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(null);

      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps atomic-close suffix commands exact and highlighted", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      'cat >&-""',
      'cat <&-""',
      "cat >&- x",
      "cat <&- x",
      "bash -c 'echo x' >&- x",
    ] as const;
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });
        const result = load.mock.results.at(-1)?.value as
          | Promise<unknown>
          | undefined;
        expect(result, source).toBeDefined();
        if (!result) continue;
        await act(async () => {
          await result;
        });
        await poll(coloredPre(root, "pre.write-content"));
        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw?.textContent, source).toBe(source);
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid^="semantic-shell-"]'),
          source,
        ).toBeNull();
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps adjacent fd-zero commands raw and highlighted", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      "cat 0\\\n>out",
      "cat 0\\\r\n>out",
      "cat 01\\\n>out",
      "cat 01\\\r\n>out",
      "cat >a 0\\\n>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0\\\r\n>/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
      "cat <<EOF 0\\\n>/tmp/output.py\nprint(1)\nEOF",
      "cat <<EOF 0\\\r\n>/tmp/output.py\r\nprint(1)\r\nEOF",
      "cat >a 0>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a 0>&1",
      "cat >a 0<&1",
      "cat >a 01>/tmp/output.py",
      "cat >a 0>/tmp/output.py 1>&2",
      "bash -c 'cat >a 0>/tmp/output.py'",
    ] as const;
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });
        const result = load.mock.results.at(-1)?.value as
          | Promise<unknown>
          | undefined;
        expect(result, source).toBeDefined();
        if (!result) continue;
        await act(async () => {
          await result;
        });
        await poll(coloredPre(root, "pre.write-content"));
        expect(root.querySelector("pre.write-content")?.textContent).toBe(
          source,
        );
        expectHighlightedPre(root, "pre.write-content");
        expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
          null,
        );
        expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(
          null,
        );
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps spaced continuation arguments structured", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      "cat >a 0 \\\n>out",
      "cat >a 0 \\\r\n>out",
      "cat {fd} \\\n>out",
      "cat {fd} \\\r\n>out",
    ] as const;
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });
        const result = load.mock.results.at(-1)?.value as
          | Promise<unknown>
          | undefined;
        expect(result, source).toBeDefined();
        if (!result) continue;
        await act(async () => {
          await result;
        });
        await poll(coloredPre(root, "pre.write-content"));
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
        ).not.toBe(null);
        expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(
          null,
        );
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("renders continued variable descriptors as typed raw fallbacks", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      "cat {fd}\\\n>out",
      "cat {fd}\\\r\n>out",
      "cat >a {fd}\\\n>/tmp/output.py <<EOF\nprint(1)\nEOF",
      "cat >a {fd}\\\r\n>/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
      "{fd}\\\n>out echo hi",
      "{fd}\\\r\n>out echo hi",
      "{fd}\\\n>out bash -c 'echo hi'",
      "{fd}\\\r\n>out bash -c 'echo hi'",
      "{a}\\\n>one {b}\\\n>two echo hi",
    ] as const;
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });
        const result = load.mock.results.at(-1)?.value as
          | Promise<{ ok: boolean; document?: { source: string } }>
          | undefined;
        expect(result, source).toBeDefined();
        expect(load.mock.calls.at(-1)?.[0], source).toBe(source);
        if (!result) continue;
        let loaded:
          | { ok: boolean; reason?: string; issue?: string }
          | undefined;
        await act(async () => {
          loaded = await result;
        });
        expect(loaded, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
          issue: "error_node",
        });
        await poll(coloredPre(root, "pre.write-content"));
        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw?.textContent, source).toBe(source);
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid^="semantic-shell-"]'),
          source,
        ).toBeNull();
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("renders recovered-prefix and merged-word inputs as typed raw fallbacks", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      "{fd}\\\n>one echo >two bash -c 'echo hi'",
      "{fd}\\\r\n>one echo >two bash -c 'echo hi'",
      "{fd}\\\n>&- echo hi",
      "{fd}\\\r\n>&- echo hi",
      "{fd}\\\n<&- echo hi",
      "{fd}\\\r\n<&- echo hi",
      "{a}\\\n>one {b} \\\n>two cat >/tmp/output.py <<EOF\nprint(1)\nEOF",
      "{a}\\\r\n>one {b} \\\r\n>two cat >/tmp/output.py <<EOF\r\nprint(1)\r\nEOF",
    ] as const;
    const load = vi.spyOn(parser, "loadParsedShellDocument");
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });
        const result = load.mock.results.at(-1)?.value as
          | Promise<{ ok: boolean }>
          | undefined;
        expect(result, source).toBeDefined();
        if (!result) continue;
        let loaded:
          | { ok: boolean; reason?: string; issue?: string }
          | undefined;
        await act(async () => {
          loaded = await result;
        });
        expect(loaded, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
          issue: "error_node",
        });
        await poll(coloredPre(root, "pre.write-content"));
        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw?.textContent, source).toBe(source);
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid^="semantic-shell-"]'),
          source,
        ).toBeNull();
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps malformed recovered-prefix errors typed and raw in the real hook", (context) =>
  run(context, async ({ root, poll }) => {
    const sources = [
      "{fd}\\\n>one bash -c 'echo hi' )",
      "{fd}\\\r\n>one bash -c 'echo hi' )",
      "{fd}\\\n>one echo >two )",
      "{fd}\\\r\n>one echo >two )",
      "{fd}\\\n>one echo >two $(",
      "{fd}\\\r\n>one echo >two $(",
    ] as const;
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });

        let parsed!: Awaited<ReturnType<typeof parser.loadParsedShellDocument>>;
        let sourceTree!: Awaited<
          ReturnType<typeof parser.loadParsedShellDocument>
        >;
        let semantic!: Awaited<
          ReturnType<typeof semanticApi.parseShellSemantic>
        >;
        await act(async () => {
          [parsed, sourceTree, semantic] = await Promise.all([
            parser.loadParsedShellDocument(source),
            parser.loadParsedShellDocument(source),
            semanticApi.parseShellSemantic(source),
          ]);
        });

        expect(parsed, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
          issue: "error_node",
        });
        expect(sourceTree, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
        });
        expect(semantic, source).toMatchObject({
          ok: false,
          code: "unsafe_shell_syntax",
        });

        await poll(coloredPre(root, "pre.write-content"));
        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw?.textContent, source).toBe(source);
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid="source-projected-inline"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid^="semantic-shell-"]'),
          source,
        ).toBeNull();
        expect(root.querySelector(".source-tree-rich-block"), source).toBe(
          null,
        );
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

it("keeps malformed atomic-close error fragments typed and raw in the real hook", (context) =>
  run(context, async ({ root, poll }) => {
    const descriptors = ["", "2", "{fd}"] as const;
    const operators = [">&-", "<&-"] as const;
    const fragments = ['""( extra', '"" ) extra', '""` extra'] as const;
    const sources = descriptors.flatMap((descriptor) =>
      operators.flatMap((operator) =>
        fragments.map((fragment) => `cat ${descriptor}${operator}${fragment}`),
      ),
    );
    sources.push(
      'cat >/tmp/output.py 2>&-""( extra <<EOF\nprint(1)\nEOF',
      'cat >/tmp/output.py 2>&-""( extra <<EOF\r\nprint(1)\r\nEOF',
    );
    const unhandled: unknown[] = [];
    const listener = (reason: unknown): void => {
      unhandled.push(reason);
    };

    processLike.on("unhandledRejection", listener);
    try {
      for (const source of sources) {
        void act(() => {
          render(toolInput(source, "dark"), root);
        });

        let parsed!: Awaited<ReturnType<typeof parser.loadParsedShellDocument>>;
        let sourceTree!: Awaited<
          ReturnType<typeof parser.loadParsedShellDocument>
        >;
        let semantic!: Awaited<
          ReturnType<typeof semanticApi.parseShellSemantic>
        >;
        await act(async () => {
          [parsed, sourceTree, semantic] = await Promise.all([
            parser.loadParsedShellDocument(source),
            parser.loadParsedShellDocument(source),
            semanticApi.parseShellSemantic(source),
          ]);
        });

        expect(parsed, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
          issue: "error_node",
        });
        expect(sourceTree, source).toMatchObject({
          ok: false,
          reason: "unsafe_shell_syntax",
        });
        expect(semantic, source).toMatchObject({
          ok: false,
          code: "unsafe_shell_syntax",
        });

        await poll(coloredPre(root, "pre.write-content"));
        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw?.textContent, source).toBe(source);
        expectHighlightedPre(root, "pre.write-content");
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid="source-projected-inline"]'),
          source,
        ).toBeNull();
        expect(
          root.querySelector('[data-testid^="semantic-shell-"]'),
          source,
        ).toBeNull();
        expect(root.querySelector(".source-tree-rich-block"), source).toBe(
          null,
        );
        await act(() => {
          render(null, root);
        });
      }
      await actStep();
      expect(unhandled).toEqual([]);
    } finally {
      processLike.off("unhandledRejection", listener);
    }
  }));

const orphanedRows = (["", "2", "{fd}"] as const).flatMap((descriptor) =>
  ([">&-", "<&-"] as const).map((operator) => ({
    descriptor,
    operator,
    redirect: descriptor + operator,
  })),
);

it.for(orphanedRows)(
  "keeps orphaned nonempty atomic-close continuations raw in the real hook ($redirect)",
  ({ descriptor, operator }, context) =>
    run(context, async ({ root, poll }) => {
      const lineEndings = ["\n", "\r\n"] as const;
      const fragments = ["x", '"x"', "$(printf x)"] as const;
      const malformedFragments = ['""(', '"" )', '""`'] as const;
      const sources: string[] = [];

      for (const lineEnding of lineEndings) {
        for (const fragment of fragments) {
          sources.push(
            `: ${descriptor}${operator}\\${lineEnding}${fragment}`,
            `bash -c 'echo hi' ${descriptor}${operator}\\${lineEnding}${fragment}`,
            `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${fragment} <<EOF${lineEnding}print(1)${lineEnding}EOF`,
          );
          for (const malformed of malformedFragments) {
            sources.push(
              `cat >/tmp/output.py ${descriptor}${operator}\\${lineEnding}${malformed} extra <<EOF${lineEnding}print(1)${lineEnding}EOF`,
            );
          }
        }
      }

      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void act(() => {
            render(toolInput(source, "dark"), root);
          });

          let parsed!: Awaited<
            ReturnType<typeof parser.loadParsedShellDocument>
          >;
          let sourceTree!: Awaited<
            ReturnType<typeof parser.loadParsedShellDocument>
          >;
          let semantic!: Awaited<
            ReturnType<typeof semanticApi.parseShellSemantic>
          >;
          await act(async () => {
            [parsed, sourceTree, semantic] = await Promise.all([
              parser.loadParsedShellDocument(source),
              parser.loadParsedShellDocument(source),
              semanticApi.parseShellSemantic(source),
            ]);
          });

          expect(parsed, source).toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
            issue: "error_node",
          });
          expect(sourceTree, source).toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
          });
          expect(semantic, source).toMatchObject({
            ok: false,
            code: "unsafe_shell_syntax",
          });

          await poll(coloredPre(root, "pre.write-content"));
          const raw = root.querySelector<HTMLPreElement>("pre.write-content");
          expect(raw?.textContent, source).toBe(source);
          expectHighlightedPre(root, "pre.write-content");
          expect(
            root.querySelector('[data-testid="source-tree-input"]'),
            source,
          ).toBeNull();
          expect(
            root.querySelector('[data-testid="source-projected-inline"]'),
            source,
          ).toBeNull();
          expect(
            root.querySelector('[data-testid^="semantic-shell-"]'),
            source,
          ).toBeNull();
          expect(root.querySelector(".source-tree-rich-block"), source).toBe(
            null,
          );
          await act(() => {
            render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    }),
);

const markdownBody = "# Title\n\nSome *markdown* with a list:\n- a\n- b";
const markdownTee = "tee 21420/doc.md >/dev/null";
const markdownCat = "cat >21420/doc.md";

function wrappedHeredoc(joiner: string, writer: string, content: string) {
  return `/run/current-system/sw/bin/zsh -lc "mkdir -p 21420${joiner}${writer} <<'EOF'\n${content}\nEOF"`;
}

it.for([
  ["tee after &&", " && ", markdownTee],
  ["cat after &&", " && ", markdownCat],
  ["tee after a newline", "\n", markdownTee],
  ["cat after a newline", "\n", markdownCat],
] as const)(
  "renders wrapped Markdown heredoc and shows highlighted source for %s",
  ([, joiner, writer], context) =>
    run(context, async ({ root, poll }) => {
      void act(() => {
        render(
          toolInput(wrappedHeredoc(joiner, writer, markdownBody), "dark"),
          root,
        );
      });
      const preview = ".source-tree-rich-block .text-content";
      await poll({
        description: "rendered Markdown list",
        ready: () => root.querySelectorAll(`${preview} li`).length === 2,
      });
      expect(root.querySelector(`${preview} h1`)?.textContent).toBe("Title");
      expect(root.querySelector(`${preview} em`)?.textContent).toBe("markdown");
      expect(root.querySelectorAll(`${preview} li`)).toHaveLength(2);

      const toggle = root.querySelector<HTMLButtonElement>(
        '.source-tree-rich-block button[title="Show source"]',
      );
      expect(toggle).not.toBeNull();
      await actStep(() => {
        toggle!.click();
      });

      const source = ".source-tree-rich-block pre";
      await poll(coloredPre(root, source));
      expectHighlightedPre(root, source);
      expect(root.querySelector(source)?.textContent).toBe(markdownBody);
      expect(root.querySelector(preview)).toBeNull();
    }),
);

it.for([
  ["a variable", "$X"],
  ["a backtick substitution", "`printf inline`"],
] as const)(
  "renders the raw wrapped command when the wrapper expands %s",
  ([, expansion], context) =>
    run(context, async ({ root, poll }) => {
      const command = wrappedHeredoc(
        " && ",
        markdownTee,
        `${markdownBody}\n${expansion}`,
      );
      void act(() => {
        render(toolInput(command, "dark"), root);
      });
      await poll(coloredPre(root, "pre.write-content"));
      expect(root.querySelector(".source-tree-rich-block")).toBeNull();
      expect(root.querySelector("pre.write-content")?.textContent).toBe(
        command,
      );
    }),
);

it.for(["cat >x.svg", "tee x.svg >/dev/null"])(
  "renders an SVG image preview for %s",
  (writer, context) =>
    run(context, async ({ root, poll }) => {
      const command = [
        `${writer} <<'EOF'`,
        '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32"/></svg>',
        "EOF",
      ].join("\n");
      void act(() => {
        render(toolInput(command, "dark"), root);
      });
      const preview = '.source-tree-rich-block img[alt="SVG preview"]';
      await poll({
        description: "rendered SVG image preview",
        ready: () => root.querySelector(preview) !== null,
      });
    }),
);
