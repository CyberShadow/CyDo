// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { actPoll, actStep, type PollStage } from "../test-support/preactAct";
import { describe, expect, it, vi } from "vitest";

type FsPromisesLike = {
  readFile(path: string): Promise<Uint8Array>;
};

type ProcessLike = {
  getBuiltinModule(name: string): unknown;
  cwd(): string;
  on(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
  off(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
};

type ShellParserModule = typeof import("../lib/shellParser");
type TreeSitterModule = typeof import("web-tree-sitter");

type FreshGraph = {
  preact: typeof import("preact");
  testUtils: typeof import("preact/test-utils");
  theme: typeof import("../useTheme");
  parser: ShellParserModule;
  treeSitter: TreeSitterModule;
  toolCall: typeof import("./ToolCall");
};

type RealHookGraph = FreshGraph & {
  sourceTree: typeof import("../lib/shellSourceTree");
  semantic: typeof import("../lib/shellSemantic");
};

type AssetMode = "urls" | "bytes";

const processLike = (globalThis as typeof globalThis & { process: ProcessLike })
  .process;

function installedWasmPath(packageName: string, fileName: string): string {
  return `${processLike.cwd()}/node_modules/${packageName}/${fileName}`;
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: unknown): void;
} {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

async function readInstalledParserWasm(): Promise<{
  runtime: Uint8Array;
  bashLanguage: Uint8Array;
}> {
  const fs = processLike.getBuiltinModule("node:fs/promises") as FsPromisesLike;
  const [runtime, bashLanguage] = await Promise.all([
    fs.readFile(installedWasmPath("web-tree-sitter", "web-tree-sitter.wasm")),
    fs.readFile(installedWasmPath("tree-sitter-bash", "tree-sitter-bash.wasm")),
  ]);
  return {
    runtime: new Uint8Array(runtime),
    bashLanguage: new Uint8Array(bashLanguage),
  };
}

async function importFreshGraph(): Promise<FreshGraph> {
  const [preact, testUtils, theme, parser, treeSitter, toolCall] =
    await Promise.all([
      import("preact"),
      import("preact/test-utils"),
      import("../useTheme"),
      import("../lib/shellParser"),
      import("web-tree-sitter"),
      import("./ToolCall"),
    ]);
  expect(testUtils.act).toBe(act);
  return { preact, testUtils, theme, parser, treeSitter, toolCall };
}

async function importFreshRealHookGraph(): Promise<RealHookGraph> {
  const graph = await importFreshGraph();
  const [sourceTree, semantic] = await Promise.all([
    import("../lib/shellSourceTree"),
    import("../lib/shellSemantic"),
  ]);
  return { ...graph, sourceTree, semantic };
}

async function runFreshRow<T>(
  body: (graph: FreshGraph, root: HTMLDivElement) => Promise<T>,
): Promise<T> {
  vi.resetModules();
  vi.doMock("../lib/shellSemantic", async () => {
    const actual = await vi.importActual<typeof import("../lib/shellSemantic")>(
      "../lib/shellSemantic",
    );
    return { ...actual, useShellSemantic: () => null };
  });

  const root = document.createElement("div");
  let graph: FreshGraph | undefined;
  try {
    graph = await importFreshGraph();
    return await body(graph, root);
  } finally {
    if (graph) {
      const { preact, testUtils } = graph;
      await testUtils.act(() => {
        preact.render(null, root);
      });
    }
    vi.restoreAllMocks();
    vi.doUnmock("../lib/shellSemantic");
    vi.resetModules();
  }
}

async function runFreshRealHookRow<T>(
  body: (graph: RealHookGraph, root: HTMLDivElement) => Promise<T>,
): Promise<T> {
  vi.resetModules();
  const root = document.createElement("div");
  let graph: RealHookGraph | undefined;
  try {
    graph = await importFreshRealHookGraph();
    return await body(graph, root);
  } finally {
    if (graph) {
      const { preact, testUtils } = graph;
      await testUtils.act(() => {
        preact.render(null, root);
      });
    }
    vi.restoreAllMocks();
    vi.resetModules();
  }
}

function toolInput(
  graph: FreshGraph,
  command: string,
  theme: "dark" | "light",
) {
  return graph.preact.h(
    graph.theme.ThemeContext.Provider,
    { value: theme },
    graph.preact.h(graph.toolCall.ToolCall, {
      name: "Bash",
      driver: "claude",
      toolUseId: "tool-shell-source-tree",
      input: { command },
    }),
  );
}

function directPreColors(root: HTMLElement, selector: string): string[] {
  const pre = root.querySelector<HTMLPreElement>(selector);
  if (!pre) return [];
  return Array.from(pre.children)
    .filter((child): child is HTMLSpanElement => child.tagName === "SPAN")
    .map((span) => span.style.color)
    .filter((color) => color.length > 0);
}

function coloredPre(root: HTMLElement, selector: string): PollStage {
  return {
    description: `Shiki colors in ${selector}`,
    ready: () => directPreColors(root, selector).length > 1,
  };
}

function changedColors(
  root: HTMLElement,
  selector: string,
  previous: readonly string[],
): PollStage {
  return {
    description: `changed Shiki colors in ${selector}`,
    ready: () => {
      const colors = directPreColors(root, selector);
      return colors.length > 1 && !sameColors(colors, previous);
    },
  };
}

function sameColors(
  first: readonly string[],
  second: readonly string[],
): boolean {
  return (
    first.length === second.length &&
    first.every((color, index) => color === second[index])
  );
}

function expectHighlightedPre(root: HTMLElement, selector: string): string[] {
  const pre = root.querySelector<HTMLPreElement>(selector);
  expect(pre).not.toBeNull();
  if (!pre) return [];

  const tokenSpans = Array.from(pre.children).filter(
    (child): child is HTMLSpanElement => child.tagName === "SPAN",
  );
  expect(tokenSpans.length).toBeGreaterThan(1);
  const colors = tokenSpans
    .map((span) => span.style.color)
    .filter((color) => color.length > 0);
  expect(colors.length).toBeGreaterThan(1);
  return colors;
}

const lifecycleRows: readonly AssetMode[] = ["urls", "bytes"];

describe.sequential("ToolCall shell source tree lifecycle", () => {
  it.each(lifecycleRows)(
    "holds, settles, remounts, and rerenders with $0 parser assets",
    async (mode) => {
      await runFreshRow(async (graph, root) => {
        const command = 'printf -- "lifecycle"';
        const installed = await readInstalledParserWasm();
        const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
        const parse = vi.spyOn(graph.treeSitter.Parser.prototype, "parse");
        const languageLoad = vi.spyOn(graph.treeSitter.Language, "load");
        const runtimeUrl = installedWasmPath(
          "web-tree-sitter",
          "web-tree-sitter.wasm",
        );
        const bashLanguageUrl = installedWasmPath(
          "tree-sitter-bash",
          "tree-sitter-bash.wasm",
        );

        const initGate = deferred<undefined>();
        const runtimeGate = deferred<Uint8Array>();
        const bashLanguageGate = deferred<Uint8Array>();
        const loadRuntime = vi.fn(() => runtimeGate.promise);
        const loadBashLanguage = vi.fn(() => bashLanguageGate.promise);
        let init: ReturnType<typeof vi.spyOn> | undefined;

        if (mode === "urls") {
          const actualInit = graph.treeSitter.Parser.init.bind(
            graph.treeSitter.Parser,
          );
          init = vi
            .spyOn(graph.treeSitter.Parser, "init")
            .mockImplementation(async (options) => {
              await initGate.promise;
              return actualInit(options);
            });
          graph.parser.configureShellParserAssets({
            kind: "urls",
            runtime: runtimeUrl,
            bashLanguage: bashLanguageUrl,
          });
        } else {
          graph.parser.configureShellParserAssets({
            kind: "bytes",
            loadRuntime,
            loadBashLanguage,
          });
        }

        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "dark"), root);
        });
        expect(load).toHaveBeenCalledTimes(1);
        expect(parse).not.toHaveBeenCalled();
        expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
          null,
        );

        await actPoll(coloredPre(root, "pre.write-content"));
        const pendingColors = directPreColors(root, "pre.write-content");
        expectHighlightedPre(root, "pre.write-content");
        expect(new Set(pendingColors).size).toBeGreaterThan(1);

        const firstLoad = load.mock.results[0]?.value as
          | Promise<unknown>
          | undefined;
        expect(firstLoad).toBeDefined();
        if (!firstLoad) return;
        await graph.testUtils.act(async () => {
          if (mode === "urls") {
            expect(init).toBeDefined();
            if (!init) return;
            expect(init).toHaveBeenCalledTimes(1);
            const options = init.mock.calls[0]?.[0] as
              | { locateFile(fileName: string): string }
              | undefined;
            expect(options).toBeDefined();
            if (!options) return;
            expect(options.locateFile("web-tree-sitter.wasm")).toBe(runtimeUrl);
            expect(() => options.locateFile("unexpected.wasm")).toThrow();
            initGate.resolve(undefined);
          } else {
            expect(loadRuntime).toHaveBeenCalledTimes(1);
            expect(loadBashLanguage).toHaveBeenCalledTimes(1);
            runtimeGate.resolve(installed.runtime);
            bashLanguageGate.resolve(installed.bashLanguage);
          }
          await firstLoad;
        });

        expect(parse).toHaveBeenCalledTimes(1);
        expect(parse).toHaveBeenCalledWith(command);
        expect(load).toHaveBeenCalledTimes(1);
        expect(load).toHaveBeenCalledWith(command);
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
        ).not.toBe(null);
        if (mode === "urls") {
          expect(init).toHaveBeenCalledTimes(1);
          expect(languageLoad).toHaveBeenCalledTimes(1);
          expect(languageLoad).toHaveBeenCalledWith(bashLanguageUrl);
        }

        void graph.testUtils.act(() => {
          graph.preact.render(null, root);
          graph.preact.render(toolInput(graph, command, "dark"), root);
          expect(
            root.querySelector('[data-testid="source-tree-input"]'),
          ).not.toBe(null);
          expect(parse).toHaveBeenCalledTimes(1);
          expect(load).toHaveBeenCalledTimes(1);
        });

        await actPoll(
          coloredPre(
            root,
            '[data-testid="source-tree-input"] pre.write-content',
          ),
        );
        const darkColors = directPreColors(
          root,
          '[data-testid="source-tree-input"] pre.write-content',
        );
        expectHighlightedPre(
          root,
          '[data-testid="source-tree-input"] pre.write-content',
        );

        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "light"), root);
        });
        await actPoll(
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
        expect(parse).toHaveBeenCalledTimes(1);
        expect(load).toHaveBeenCalledTimes(1);
      });
    },
  );

  it("keeps recognized semantic and source-tree selectors through a theme rerender", async () => {
    await runFreshRealHookRow(async (graph, root) => {
      const command = "python3 - <<'PY'\nprint(1)\nPY";
      const installed = await readInstalledParserWasm();
      const parse = vi.spyOn(graph.treeSitter.Parser.prototype, "parse");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "dark"), root);
        });
        await actPoll(
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
          coloredPre(
            root,
            '[data-testid="source-tree-input"] pre.write-content',
          ),
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

        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "light"), root);
        });
        expect(
          root.querySelector('[data-testid="semantic-shell-script"]'),
        ).not.toBeNull();
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
        ).not.toBeNull();
        await actPoll(
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
    });
  });

  it.each(lifecycleRows)(
    "keeps highlighted raw input after $0 parser initialization failure",
    async (mode) => {
      await runFreshRow(async (graph, root) => {
        const command = 'printf -- "failure"';
        const installed = await readInstalledParserWasm();
        const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
        const parse = vi.spyOn(graph.treeSitter.Parser.prototype, "parse");
        const failure = new Error(`${mode} parser initialization failed`);
        const unhandled: unknown[] = [];
        const listener = (reason: unknown): void => {
          unhandled.push(reason);
        };
        const initGate = deferred<undefined>();
        const runtimeGate = deferred<Uint8Array>();
        const bashLanguageGate = deferred<Uint8Array>();
        const loadRuntime = vi.fn(() => runtimeGate.promise);
        const loadBashLanguage = vi.fn(() => bashLanguageGate.promise);
        let init: ReturnType<typeof vi.spyOn> | undefined;

        processLike.on("unhandledRejection", listener);
        try {
          if (mode === "urls") {
            const actualInit = graph.treeSitter.Parser.init.bind(
              graph.treeSitter.Parser,
            );
            init = vi
              .spyOn(graph.treeSitter.Parser, "init")
              .mockImplementation(async (options) => {
                await initGate.promise;
                return actualInit(options);
              });
            graph.parser.configureShellParserAssets({
              kind: "urls",
              runtime: installedWasmPath(
                "web-tree-sitter",
                "web-tree-sitter.wasm",
              ),
              bashLanguage: installedWasmPath(
                "tree-sitter-bash",
                "tree-sitter-bash.wasm",
              ),
            });
          } else {
            graph.parser.configureShellParserAssets({
              kind: "bytes",
              loadRuntime,
              loadBashLanguage,
            });
          }

          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, command, "dark"), root);
          });
          expect(load).toHaveBeenCalledTimes(1);
          expect(parse).not.toHaveBeenCalled();

          const firstLoad = load.mock.results[0]?.value as
            | Promise<unknown>
            | undefined;
          expect(firstLoad).toBeDefined();
          if (!firstLoad) return;

          await graph.testUtils.act(async () => {
            if (mode === "urls") {
              expect(init).toBeDefined();
              if (!init) return;
              expect(init).toHaveBeenCalledTimes(1);
              initGate.reject(failure);
            } else {
              expect(loadRuntime).toHaveBeenCalledTimes(1);
              expect(loadBashLanguage).toHaveBeenCalledTimes(1);
              runtimeGate.reject(failure);
              bashLanguageGate.resolve(installed.bashLanguage);
            }

            await expect(firstLoad).resolves.toEqual({
              ok: false,
              reason: "parser_initialization_failed",
            });
          });
          await actPoll(coloredPre(root, "pre.write-content"));

          expectHighlightedPre(root, "pre.write-content");
          expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
            null,
          );
          expect(parse).not.toHaveBeenCalled();

          await actStep();
          expect(unhandled).toEqual([]);
        } finally {
          processLike.off("unhandledRejection", listener);
        }
      });
    },
  );

  it("maps semantic parser initialization failure to a typed result without rejection", async () => {
    await runFreshRealHookRow(async (graph, root) => {
      const command = "python3 - <<'PY'\nprint(1)\nPY";
      const installed = await readInstalledParserWasm();
      const failure = new Error("semantic parser initialization failed");
      const loadRuntime = vi.fn(() => Promise.reject(failure));
      const loadBashLanguage = vi.fn(() =>
        Promise.resolve(installed.bashLanguage),
      );
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime,
        loadBashLanguage,
      });

      processLike.on("unhandledRejection", listener);
      try {
        const semantic = await graph.semantic.parseShellSemantic(command);
        expect(semantic).toEqual({
          ok: false,
          code: "unsafe_shell_syntax",
          reason: "shell parser initialization failed",
        });

        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "dark"), root);
        });
        await actPoll(coloredPre(root, "pre.write-content"));
        expect(root.querySelector("pre.write-content")?.textContent).toBe(
          command,
        );
        expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
          null,
        );
        expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(
          null,
        );
        expect(loadRuntime).toHaveBeenCalled();
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps ambiguous variable redirect input raw and highlighted", async () => {
    await runFreshRow(async (graph, root) => {
      const command = "cat >{fd}>b";
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        void graph.testUtils.act(() => {
          graph.preact.render(toolInput(graph, command, "dark"), root);
        });

        const firstLoad = load.mock.results[0]?.value as
          | Promise<unknown>
          | undefined;
        expect(firstLoad).toBeDefined();
        if (!firstLoad) return;

        await graph.testUtils.act(async () => {
          await firstLoad.catch(() => undefined);
        });
        await actPoll(coloredPre(root, "pre.write-content"));

        const raw = root.querySelector<HTMLPreElement>("pre.write-content");
        expect(raw).not.toBeNull();
        expect(raw?.textContent).toBe(command);
        expectHighlightedPre(root, "pre.write-content");
        expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(
          null,
        );
        expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(
          null,
        );

        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps atomic-close suffix commands exact and highlighted", async () => {
    await runFreshRow(async (graph, root) => {
      const sources = [
        'cat >&-""',
        'cat <&-""',
        "cat >&- x",
        "cat <&- x",
        "bash -c 'echo x' >&- x",
      ] as const;
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });
          const result = load.mock.results.at(-1)?.value as
            | Promise<unknown>
            | undefined;
          expect(result, source).toBeDefined();
          if (!result) continue;
          await graph.testUtils.act(async () => {
            await result;
          });
          await actPoll(coloredPre(root, "pre.write-content"));
          const raw = root.querySelector<HTMLPreElement>("pre.write-content");
          expect(raw?.textContent, source).toBe(source);
          expectHighlightedPre(root, "pre.write-content");
          expect(
            root.querySelector('[data-testid^="semantic-shell-"]'),
            source,
          ).toBeNull();
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps adjacent fd-zero commands raw and highlighted", async () => {
    await runFreshRow(async (graph, root) => {
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
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });
          const result = load.mock.results.at(-1)?.value as
            | Promise<unknown>
            | undefined;
          expect(result, source).toBeDefined();
          if (!result) continue;
          await graph.testUtils.act(async () => {
            await result;
          });
          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps spaced continuation arguments structured", async () => {
    await runFreshRow(async (graph, root) => {
      const sources = [
        "cat >a 0 \\\n>out",
        "cat >a 0 \\\r\n>out",
        "cat {fd} \\\n>out",
        "cat {fd} \\\r\n>out",
      ] as const;
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });
          const result = load.mock.results.at(-1)?.value as
            | Promise<unknown>
            | undefined;
          expect(result, source).toBeDefined();
          if (!result) continue;
          await graph.testUtils.act(async () => {
            await result;
          });
          await actPoll(coloredPre(root, "pre.write-content"));
          expectHighlightedPre(root, "pre.write-content");
          expect(
            root.querySelector('[data-testid="source-tree-input"]'),
          ).not.toBe(null);
          expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(
            null,
          );
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("renders continued variable descriptors as typed raw fallbacks", async () => {
    await runFreshRealHookRow(async (graph, root) => {
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
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
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
          await graph.testUtils.act(async () => {
            loaded = await result;
          });
          expect(loaded, source).toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
            issue: "error_node",
          });
          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("renders recovered-prefix and merged-word inputs as typed raw fallbacks", async () => {
    await runFreshRow(async (graph, root) => {
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
      const installed = await readInstalledParserWasm();
      const load = vi.spyOn(graph.parser, "loadParsedShellDocument");
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });
          const result = load.mock.results.at(-1)?.value as
            | Promise<{ ok: boolean }>
            | undefined;
          expect(result, source).toBeDefined();
          if (!result) continue;
          let loaded:
            | { ok: boolean; reason?: string; issue?: string }
            | undefined;
          await graph.testUtils.act(async () => {
            loaded = await result;
          });
          expect(loaded, source).toMatchObject({
            ok: false,
            reason: "unsafe_shell_syntax",
            issue: "error_node",
          });
          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps malformed recovered-prefix errors typed and raw in the real hook", async () => {
    await runFreshRealHookRow(async (graph, root) => {
      const sources = [
        "{fd}\\\n>one bash -c 'echo hi' )",
        "{fd}\\\r\n>one bash -c 'echo hi' )",
        "{fd}\\\n>one echo >two )",
        "{fd}\\\r\n>one echo >two )",
        "{fd}\\\n>one echo >two $(",
        "{fd}\\\r\n>one echo >two $(",
      ] as const;
      const installed = await readInstalledParserWasm();
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });

          let parsed!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let sourceTree!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let semantic!: Awaited<
            ReturnType<typeof graph.semantic.parseShellSemantic>
          >;
          await graph.testUtils.act(async () => {
            [parsed, sourceTree, semantic] = await Promise.all([
              graph.parser.loadParsedShellDocument(source),
              graph.parser.loadParsedShellDocument(source),
              graph.semantic.parseShellSemantic(source),
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

          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps malformed atomic-close error fragments typed and raw in the real hook", async () => {
    await runFreshRealHookRow(async (graph, root) => {
      const descriptors = ["", "2", "{fd}"] as const;
      const operators = [">&-", "<&-"] as const;
      const fragments = ['""( extra', '"" ) extra', '""` extra'] as const;
      const sources = descriptors.flatMap((descriptor) =>
        operators.flatMap((operator) =>
          fragments.map(
            (fragment) => `cat ${descriptor}${operator}${fragment}`,
          ),
        ),
      );
      sources.push(
        'cat >/tmp/output.py 2>&-""( extra <<EOF\nprint(1)\nEOF',
        'cat >/tmp/output.py 2>&-""( extra <<EOF\r\nprint(1)\r\nEOF',
      );
      const installed = await readInstalledParserWasm();
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });

          let parsed!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let sourceTree!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let semantic!: Awaited<
            ReturnType<typeof graph.semantic.parseShellSemantic>
          >;
          await graph.testUtils.act(async () => {
            [parsed, sourceTree, semantic] = await Promise.all([
              graph.parser.loadParsedShellDocument(source),
              graph.parser.loadParsedShellDocument(source),
              graph.semantic.parseShellSemantic(source),
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

          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });

  it("keeps orphaned nonempty atomic-close continuations raw in the real hook", async () => {
    await runFreshRealHookRow(async (graph, root) => {
      const descriptors = ["", "2", "{fd}"] as const;
      const operators = [">&-", "<&-"] as const;
      const lineEndings = ["\n", "\r\n"] as const;
      const fragments = ["x", '"x"', "$(printf x)"] as const;
      const malformedFragments = ['""(', '"" )', '""`'] as const;
      const sources: string[] = [];

      for (const descriptor of descriptors) {
        for (const operator of operators) {
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
        }
      }

      const installed = await readInstalledParserWasm();
      const unhandled: unknown[] = [];
      const listener = (reason: unknown): void => {
        unhandled.push(reason);
      };

      graph.parser.configureShellParserAssets({
        kind: "bytes",
        loadRuntime: () => Promise.resolve(installed.runtime),
        loadBashLanguage: () => Promise.resolve(installed.bashLanguage),
      });

      processLike.on("unhandledRejection", listener);
      try {
        for (const source of sources) {
          void graph.testUtils.act(() => {
            graph.preact.render(toolInput(graph, source, "dark"), root);
          });

          let parsed!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let sourceTree!: Awaited<
            ReturnType<typeof graph.parser.loadParsedShellDocument>
          >;
          let semantic!: Awaited<
            ReturnType<typeof graph.semantic.parseShellSemantic>
          >;
          await graph.testUtils.act(async () => {
            [parsed, sourceTree, semantic] = await Promise.all([
              graph.parser.loadParsedShellDocument(source),
              graph.parser.loadParsedShellDocument(source),
              graph.semantic.parseShellSemantic(source),
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

          await actPoll(coloredPre(root, "pre.write-content"));
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
          await graph.testUtils.act(() => {
            graph.preact.render(null, root);
          });
        }
        await actStep();
        expect(unhandled).toEqual([]);
      } finally {
        processLike.off("unhandledRejection", listener);
      }
    });
  });
});
