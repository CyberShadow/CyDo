import { h, render } from "preact";
import { act } from "preact/test-utils";
import { expect, vi } from "vitest";
import * as treeSitter from "web-tree-sitter";
import { tokenize } from "../highlight";
import * as parser from "../lib/shellParser";
import * as semanticApi from "../lib/shellSemantic";
import { configureTreeSitterAssets } from "../lib/treeSitterRuntime";
import {
  installedTreeSitterBytes,
  installedTreeSitterUrls,
} from "../test-support/treeSitterAssets";
import {
  actStep,
  type JoinedRow,
  type PollStage,
} from "../test-support/preactAct";
import { ThemeContext } from "../useTheme";
import { ToolCall } from "./ToolCall";

type ProcessLike = {
  on(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
  off(
    event: "unhandledRejection",
    listener: (reason: unknown, promise: Promise<unknown>) => void,
  ): void;
};

type AssetMode = "urls" | "bytes";

export const processLike = (
  globalThis as typeof globalThis & { process: ProcessLike }
).process;

export function deferred<T>(signal: AbortSignal): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: unknown): void;
} {
  signal.throwIfAborted();
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  // Some asset gates are never reached in the selected parser mode.
  void promise.catch(() => undefined);
  signal.addEventListener(
    "abort",
    () => {
      rejectPromise(signal.reason);
    },
    { once: true },
  );
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

async function readInstalledParserWasm() {
  const [runtime, bashLanguage] = await Promise.all([
    installedTreeSitterBytes.loadRuntime(),
    installedTreeSitterBytes.loadLanguage("bash"),
  ]);
  return { runtime, bashLanguage };
}

export function toolInput(command: string, theme: "dark" | "light") {
  return h(
    ThemeContext.Provider,
    { value: theme },
    h(ToolCall, {
      name: "Bash",
      driver: "claude",
      toolUseId: "tool-shell-source-tree",
      input: { command },
    }),
  );
}

export function directPreColors(root: HTMLElement, selector: string): string[] {
  const pre = root.querySelector<HTMLPreElement>(selector);
  if (!pre) return [];
  return Array.from(pre.children)
    .filter((child): child is HTMLSpanElement => child.tagName === "SPAN")
    .map((span) => span.style.color)
    .filter((color) => color.length > 0);
}

export function coloredPre(root: HTMLElement, selector: string): PollStage {
  return {
    description: `Shiki colors in ${selector}`,
    ready: () => directPreColors(root, selector).length > 1,
  };
}

export function changedColors(
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

export function expectHighlightedPre(
  root: HTMLElement,
  selector: string,
): string[] {
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

export function warmHighlighter(...langs: ("bash" | "python")[]) {
  return async () => {
    for (const lang of langs) {
      expect(
        await tokenize(lang === "bash" ? "true" : "print(1)", lang),
      ).not.toBeNull();
    }
  };
}

export function configureInstalledBytesParser() {
  configureTreeSitterAssets(installedTreeSitterBytes);
}

export async function lifecycle(
  { root, poll, signal }: JoinedRow,
  mode: AssetMode,
) {
  const command = 'printf -- "lifecycle"';
  const installed = await readInstalledParserWasm();
  signal.throwIfAborted();
  const load = vi.spyOn(parser, "loadParsedShellDocument");
  const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
  const languageLoad = vi.spyOn(treeSitter.Language, "load");
  const {
    runtime: runtimeUrl,
    languages: { bash: bashLanguageUrl },
  } = installedTreeSitterUrls;

  const initGate = deferred<undefined>(signal);
  const runtimeGate = deferred<Uint8Array>(signal);
  const bashLanguageGate = deferred<Uint8Array>(signal);
  const loadRuntime = vi.fn(() => runtimeGate.promise);
  const loadLanguage = vi.fn(() => bashLanguageGate.promise);
  let init: ReturnType<typeof vi.spyOn> | undefined;

  if (mode === "urls") {
    const actualInit = treeSitter.Parser.init.bind(treeSitter.Parser);
    init = vi
      .spyOn(treeSitter.Parser, "init")
      .mockImplementation(async (options) => {
        await initGate.promise;
        return actualInit(options);
      });
    configureTreeSitterAssets(installedTreeSitterUrls);
  } else {
    configureTreeSitterAssets({
      kind: "bytes",
      loadRuntime,
      loadLanguage,
    });
  }

  void act(() => {
    render(toolInput(command, "dark"), root);
  });
  expect(load).toHaveBeenCalledTimes(1);
  expect(parse).not.toHaveBeenCalled();
  expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(null);

  await poll(coloredPre(root, "pre.write-content"));
  const pendingColors = directPreColors(root, "pre.write-content");
  expectHighlightedPre(root, "pre.write-content");
  expect(new Set(pendingColors).size).toBeGreaterThan(1);

  const firstLoad = load.mock.results[0]?.value as Promise<unknown> | undefined;
  expect(firstLoad).toBeDefined();
  if (!firstLoad) return;
  await act(async () => {
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
      expect(loadLanguage).toHaveBeenCalledTimes(1);
      runtimeGate.resolve(installed.runtime);
      bashLanguageGate.resolve(installed.bashLanguage);
    }
    await firstLoad;
  });

  expect(parse).toHaveBeenCalledTimes(1);
  expect(parse).toHaveBeenCalledWith(command);
  expect(load).toHaveBeenCalledTimes(1);
  expect(load).toHaveBeenCalledWith(command);
  expect(root.querySelector('[data-testid="source-tree-input"]')).not.toBe(
    null,
  );
  if (mode === "urls") {
    expect(init).toHaveBeenCalledTimes(1);
    expect(languageLoad).toHaveBeenCalledTimes(1);
    expect(languageLoad).toHaveBeenCalledWith(bashLanguageUrl);
  }

  void act(() => {
    render(null, root);
    render(toolInput(command, "dark"), root);
    expect(root.querySelector('[data-testid="source-tree-input"]')).not.toBe(
      null,
    );
    expect(parse).toHaveBeenCalledTimes(1);
    expect(load).toHaveBeenCalledTimes(1);
  });

  await poll(
    coloredPre(root, '[data-testid="source-tree-input"] pre.write-content'),
  );
  const darkColors = directPreColors(
    root,
    '[data-testid="source-tree-input"] pre.write-content',
  );
  expectHighlightedPre(
    root,
    '[data-testid="source-tree-input"] pre.write-content',
  );

  void act(() => {
    render(toolInput(command, "light"), root);
  });
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
  expect(parse).toHaveBeenCalledTimes(1);
  expect(load).toHaveBeenCalledTimes(1);
}

export async function initFailure(
  { root, poll, signal }: JoinedRow,
  mode: AssetMode,
) {
  const command = 'printf -- "failure"';
  const installed = await readInstalledParserWasm();
  signal.throwIfAborted();
  const load = vi.spyOn(parser, "loadParsedShellDocument");
  const parse = vi.spyOn(treeSitter.Parser.prototype, "parse");
  const failure = new Error(`${mode} parser initialization failed`);
  const unhandled: unknown[] = [];
  const listener = (reason: unknown): void => {
    unhandled.push(reason);
  };
  const initGate = deferred<undefined>(signal);
  const runtimeGate = deferred<Uint8Array>(signal);
  const bashLanguageGate = deferred<Uint8Array>(signal);
  const loadRuntime = vi.fn(() => runtimeGate.promise);
  const loadLanguage = vi.fn(() => bashLanguageGate.promise);
  let init: ReturnType<typeof vi.spyOn> | undefined;

  processLike.on("unhandledRejection", listener);
  try {
    if (mode === "urls") {
      const actualInit = treeSitter.Parser.init.bind(treeSitter.Parser);
      init = vi
        .spyOn(treeSitter.Parser, "init")
        .mockImplementation(async (options) => {
          await initGate.promise;
          return actualInit(options);
        });
      configureTreeSitterAssets(installedTreeSitterUrls);
    } else {
      configureTreeSitterAssets({
        kind: "bytes",
        loadRuntime,
        loadLanguage,
      });
    }

    void act(() => {
      render(toolInput(command, "dark"), root);
    });
    expect(load).toHaveBeenCalledTimes(1);
    expect(parse).not.toHaveBeenCalled();

    const firstLoad = load.mock.results[0]?.value as
      | Promise<unknown>
      | undefined;
    expect(firstLoad).toBeDefined();
    if (!firstLoad) return;

    await act(async () => {
      if (mode === "urls") {
        expect(init).toBeDefined();
        if (!init) return;
        expect(init).toHaveBeenCalledTimes(1);
        initGate.reject(failure);
      } else {
        expect(loadRuntime).toHaveBeenCalledTimes(1);
        expect(loadLanguage).toHaveBeenCalledTimes(1);
        runtimeGate.reject(failure);
        bashLanguageGate.resolve(installed.bashLanguage);
      }

      await expect(firstLoad).resolves.toEqual({
        ok: false,
        reason: "parser_initialization_failed",
      });
    });
    await poll(coloredPre(root, "pre.write-content"));

    expectHighlightedPre(root, "pre.write-content");
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(null);
    expect(parse).not.toHaveBeenCalled();

    await actStep();
    expect(unhandled).toEqual([]);
  } finally {
    processLike.off("unhandledRejection", listener);
  }
}

export async function semanticInitFailure({ root, poll, signal }: JoinedRow) {
  const command = "python3 - <<'PY'\nprint(1)\nPY";
  const installed = await readInstalledParserWasm();
  signal.throwIfAborted();
  const failure = new Error("semantic parser initialization failed");
  const loadRuntime = vi.fn(() => Promise.reject(failure));
  const loadLanguage = vi.fn(() => Promise.resolve(installed.bashLanguage));
  const unhandled: unknown[] = [];
  const listener = (reason: unknown): void => {
    unhandled.push(reason);
  };

  configureTreeSitterAssets({
    kind: "bytes",
    loadRuntime,
    loadLanguage,
  });

  processLike.on("unhandledRejection", listener);
  try {
    const semantic = await semanticApi.parseShellSemantic(command);
    expect(semantic).toEqual({
      ok: false,
      code: "unsafe_shell_syntax",
      reason: "shell parser initialization failed",
    });

    void act(() => {
      render(toolInput(command, "dark"), root);
    });
    await poll(coloredPre(root, "pre.write-content"));
    expect(root.querySelector("pre.write-content")?.textContent).toBe(command);
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBe(null);
    expect(root.querySelector('[data-testid^="semantic-shell-"]')).toBe(null);
    expect(loadRuntime).toHaveBeenCalled();
    await actStep();
    expect(unhandled).toEqual([]);
  } finally {
    processLike.off("unhandledRejection", listener);
  }
}
