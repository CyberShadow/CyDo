import { test as base } from "@playwright/test";
import { spawn, spawnSync } from "child_process";
import type { ChildProcess } from "child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join, relative } from "path";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  endSession,
  killBackend,
  assistantText,
  responseTimeout,
  lastAssistantText,
  installCydoE2eBridge,
  parseShellThroughBridge,
} from "./fixtures";
import type { Locator, Page } from "@playwright/test";
import { writeTestConfig } from "./test-config";
import {
  installExportCdnRoutes,
  readExportCdnFixtures,
  type ExportCdnFixture,
  type ExportCdnFixtures,
  type ExportCdnRoutePolicy,
  type ExportCdnRouteState,
} from "./export-cdn-fixtures";

test.use({ serviceWorkers: "block" });

const JSDELIVR_HOST = "cdn.jsdelivr.net";
const UNPKG_HOST = "unpkg.com";
const ESM_HOST = "esm.sh";
const COMPOUND_COMMAND =
  "cd /tmp && python3 - <<'EOF'\nprint(1)\nEOF\ngit diff | cat";
const COMPOUND_HEADER = "cd /tmp && python3 - <<'EOF'\n";
const COMPOUND_BODY = "print(1)";
const COMPOUND_FOOTER = "\nEOF\ngit diff | cat";
const RICH_EXPORT_MARKER = "rich-export-marker";
const RUST_SOURCE = 'fn main() {\n    println!("rust-export-marker");\n}';
const MERMAID_SOURCE = "graph TD\n  Export[Export] --> Ready[Ready]";

type ExportDiagnostics = {
  console: Array<{ text: string; type: "error" | "warning" }>;
  failedRequests: Array<{ errorText: string | undefined; url: string }>;
  pageErrors: string[];
};

type ExportNavigation = {
  diagnostics: ExportDiagnostics;
  fixtures: ExportCdnFixtures;
  pageRequests: string[];
  routeState: ExportCdnRouteState;
};

type ExportAssets = {
  bash: readonly [ExportCdnFixture, ExportCdnFixture, ExportCdnFixture];
  core: ExportCdnFixture;
  mermaid: Readonly<{ jsdelivr: ExportCdnFixture; unpkg: ExportCdnFixture }>;
  runtime: readonly [ExportCdnFixture, ExportCdnFixture, ExportCdnFixture];
  shiki: Readonly<{ jsdelivr: ExportCdnFixture; unpkg: ExportCdnFixture }>;
};

function deleteExport(outputPath: string): void {
  try {
    unlinkSync(outputPath);
  } catch {
    // The exporter may have failed before creating its output.
  }
}

function exportHtml(tid: string, outputPath: string): void {
  const result = spawnSync(
    process.env.CYDO_BIN!,
    ["export-html", tid, "--output", outputPath],
    {
      env: {
        ...process.env,
        XDG_DATA_HOME: "/tmp/cydo-backend/data",
      },
      encoding: "utf8",
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
    );
  }
}

async function createRichExport(
  page: Page,
  agentType: "claude" | "codex" | "copilot",
  outputPath: string,
): Promise<string> {
  await enterSession(page);
  await sendMessage(page, "semantic shell compound heredoc");
  await expect(
    page
      .locator(".tool-call")
      .filter({ has: page.locator(".tool-name", { hasText: "Bash" }) })
      .last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  await expect(lastAssistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await sendMessage(page, "rich export rendering fixture");
  await expect(lastAssistantText(page, RICH_EXPORT_MARKER)).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await killSession(page, agentType);
  const tid = await page
    .locator(".sidebar-item.active")
    .getAttribute("data-tid");
  expect(tid).toBeTruthy();
  exportHtml(tid!, outputPath);
  return tid!;
}

function recordExportDiagnostics(page: Page): ExportDiagnostics {
  const diagnostics: ExportDiagnostics = {
    console: [],
    failedRequests: [],
    pageErrors: [],
  };
  page.on("console", (message) => {
    const type = message.type();
    if (type === "error" || type === "warning") {
      diagnostics.console.push({ text: message.text(), type });
    }
  });
  page.on("pageerror", (error) => {
    diagnostics.pageErrors.push(`${error.name}: ${error.message}`);
  });
  page.on("requestfailed", (request) => {
    const url = request.url();
    if (new URL(url).protocol !== "https:") return;
    diagnostics.failedRequests.push({
      errorText: request.failure()?.errorText,
      url,
    });
  });
  return diagnostics;
}

async function navigateExport(
  page: Page,
  outputPath: string,
  policy: ExportCdnRoutePolicy,
): Promise<ExportNavigation> {
  const diagnostics = recordExportDiagnostics(page);
  const pageRequests: string[] = [];
  page.on("request", (request) => pageRequests.push(request.url()));
  await installCydoE2eBridge(page);
  const fixtures = readExportCdnFixtures();
  const routeState = await installExportCdnRoutes(page, fixtures, policy);
  await page.goto(`file://${outputPath}`);
  return { diagnostics, fixtures, pageRequests, routeState };
}

function fixtureFile(
  fixtures: ExportCdnFixtures,
  predicate: (file: string) => boolean,
  description: string,
): string {
  const files = [
    ...new Set(fixtures.records.map((record) => record.file)),
  ].filter(predicate);
  expect(files, `fixture has one ${description} file`).toHaveLength(1);
  return files[0]!;
}

function fixtureForHost(
  fixtures: ExportCdnFixtures,
  file: string,
  host: string,
): ExportCdnFixture {
  const records = fixtures.records.filter(
    (record) => record.file === file && new URL(record.url).hostname === host,
  );
  expect(records, `${file} has one ${host} candidate`).toHaveLength(1);
  return records[0]!;
}

function exportAssets(fixtures: ExportCdnFixtures): ExportAssets {
  const shikiFile = fixtureFile(
    fixtures,
    (file) =>
      file.startsWith("files/shiki@") && file.endsWith("/dist/bundle-web.mjs"),
    "Shiki root",
  );
  const mermaidFile = fixtureFile(
    fixtures,
    (file) =>
      file.startsWith("files/mermaid@") &&
      file.endsWith("/dist/mermaid.esm.min.mjs"),
    "Mermaid root",
  );
  const coreFile = fixtureFile(
    fixtures,
    (file) =>
      file.startsWith("files/@shikijs/core@") &&
      file.endsWith("/dist/index.mjs"),
    "Shiki core module",
  );
  const runtimeFile = "files/web-tree-sitter/web-tree-sitter.wasm";
  const bashFile = "files/tree-sitter-bash/tree-sitter-bash.wasm";

  return {
    bash: [
      fixtureForHost(fixtures, bashFile, JSDELIVR_HOST),
      fixtureForHost(fixtures, bashFile, UNPKG_HOST),
      fixtureForHost(fixtures, bashFile, ESM_HOST),
    ],
    core: fixtureForHost(fixtures, coreFile, JSDELIVR_HOST),
    mermaid: {
      jsdelivr: fixtureForHost(fixtures, mermaidFile, JSDELIVR_HOST),
      unpkg: fixtureForHost(fixtures, mermaidFile, UNPKG_HOST),
    },
    runtime: [
      fixtureForHost(fixtures, runtimeFile, JSDELIVR_HOST),
      fixtureForHost(fixtures, runtimeFile, UNPKG_HOST),
      fixtureForHost(fixtures, runtimeFile, ESM_HOST),
    ],
    shiki: {
      jsdelivr: fixtureForHost(fixtures, shikiFile, JSDELIVR_HOST),
      unpkg: fixtureForHost(fixtures, shikiFile, UNPKG_HOST),
    },
  };
}

function actionFor(
  routeState: ExportCdnRouteState,
  url: string,
): ExportCdnRouteState["actions"][number] {
  const actions = routeState.actions.filter((action) => action.url === url);
  expect(actions, `one action for ${url}`).toHaveLength(1);
  return actions[0]!;
}

function tamperActionFor(
  routeState: ExportCdnRouteState,
  url: string,
): Extract<ExportCdnRouteState["actions"][number], { action: "tamper" }> {
  const action = actionFor(routeState, url);
  if (action.action !== "tamper") {
    throw new Error(`expected tamper action for ${url}; got ${action.action}`);
  }
  return action;
}

function assertActionCorrespondence(routeState: ExportCdnRouteState): void {
  expect(routeState.actions).toHaveLength(routeState.requests.length);
  expect(routeState.actions.map((action) => action.url)).toEqual(
    routeState.requests,
  );
}

function expectCandidateAttempts(
  routeState: ExportCdnRouteState,
  candidates: readonly ExportCdnFixture[],
): void {
  const urls = candidates.map((candidate) => candidate.url);
  expect(routeState.requests.filter((url) => urls.includes(url))).toEqual(urls);
}

function expectNoUnknownHttps(routeState: ExportCdnRouteState): void {
  expect(routeState.unexpectedHttps).toEqual([]);
  expect(
    routeState.requests.every((url) =>
      routeState.actions.some((action) => action.url === url),
    ),
  ).toBe(true);
}

function assertNoPageErrors(diagnostics: ExportDiagnostics): void {
  expect(diagnostics.pageErrors).toEqual([]);
}

function expectedIntegrityDiagnostic(
  url: string,
  integrity: string,
): (diagnostic: ExportDiagnostics["console"][number]) => boolean {
  const digest = integrity.replace(/^sha384-/, "");
  return (diagnostic) =>
    diagnostic.type === "error" &&
    diagnostic.text.includes(url) &&
    diagnostic.text.includes(digest) &&
    diagnostic.text.includes("computed SHA-384 integrity");
}

function expectedParserExhaustion(
  assetLabel: string,
): (diagnostic: ExportDiagnostics["console"][number]) => boolean {
  return (diagnostic) =>
    diagnostic.type === "error" &&
    diagnostic.text.startsWith(
      `Failed to preload shell parser AggregateError: failed to load ${assetLabel} from CDN candidates`,
    );
}

function expectedShikiExhaustion(
  diagnostic: ExportDiagnostics["console"][number],
): boolean {
  return (
    diagnostic.type === "warning" &&
    diagnostic.text.startsWith(
      "Shiki: failed to create highlighter AggregateError: failed to import shiki-root from CDN candidates",
    )
  );
}

function expectedBlockedResource(
  diagnostic: ExportDiagnostics["console"][number],
): boolean {
  return (
    diagnostic.type === "error" &&
    diagnostic.text ===
      "Failed to load resource: net::ERR_BLOCKED_BY_CLIENT.Inspector"
  );
}

function expectedFetchIntegrityFailure(
  url: string,
): (diagnostic: ExportDiagnostics["console"][number]) => boolean {
  return (diagnostic) =>
    diagnostic.type === "error" &&
    diagnostic.text === `Fetch API cannot load ${url}. SRI's integrity checks failed.`;
}

async function expectOnlyDiagnostics(
  diagnostics: ExportDiagnostics,
  expected: Array<
    (diagnostic: ExportDiagnostics["console"][number]) => boolean
  >,
): Promise<void> {
  if (expected.length > 0) {
    await expect
      .poll(() => diagnostics.console.length)
      .toBeGreaterThanOrEqual(expected.length);
  }
  const remaining = [...diagnostics.console];
  for (const matches of expected) {
    const index = remaining.findIndex(matches);
    expect(
      index,
      `expected console diagnostics: ${JSON.stringify(diagnostics.console)}`,
    ).toBeGreaterThanOrEqual(0);
    remaining.splice(index, 1);
  }
  expect(remaining).toEqual([]);
  assertNoPageErrors(diagnostics);
}

async function expectColored(locator: Locator): Promise<void> {
  await expect(locator).toBeVisible();
  await expect
    .poll(() => locator.locator('span[style*="color"]').count())
    .toBeGreaterThan(0);
}

async function expectStructuredShell(page: Page): Promise<void> {
  const semanticScript = page.locator('[data-testid="semantic-shell-script"]');
  const sourceTree = semanticScript.locator(
    '[data-testid="source-tree-input"]',
  );
  await expect(sourceTree).toBeVisible();
  await expect
    .poll(() =>
      sourceTree
        .locator(".source-tree-block")
        .evaluateAll((blocks) =>
          blocks.map((block) => block.textContent ?? ""),
        ),
    )
    .toEqual([COMPOUND_HEADER, COMPOUND_BODY, COMPOUND_FOOTER]);
  const middle = sourceTree.locator("pre.source-tree-block").nth(1);
  await expect(middle).toHaveText(COMPOUND_BODY);
  await expectColored(middle);
}

async function expectRawShell(page: Page): Promise<void> {
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: "Bash" }) })
    .last();
  const raw = toolCall.locator(".code-pre-wrap > pre.write-content");
  await expect(raw).toBeVisible();
  expect(await raw.textContent()).toBe(COMPOUND_COMMAND);
  await expect(
    toolCall.locator('[data-testid="source-tree-input"]'),
  ).toHaveCount(0);
}

async function expectRichRust(page: Page): Promise<void> {
  const rust = page.locator(
    '[data-testid="assistant-text"] pre.language-rust code',
  );
  await expect(rust).toContainText(RUST_SOURCE);
  await expectColored(rust);
}

async function expectRawRust(page: Page): Promise<void> {
  const rust = page.locator(
    '[data-testid="assistant-text"] pre.language-rust code',
  );
  await expect(rust).toContainText(RUST_SOURCE);
  expect(await rust.locator('span[style*="color"]').count()).toBe(0);
}

async function expectRichMermaid(page: Page): Promise<void> {
  await expect(
    page.locator('[data-testid="assistant-text"] .mermaid-diagram svg'),
  ).toBeVisible();
  await expect(page.locator(".mermaid-error")).toHaveCount(0);
}

async function expectRawMermaid(page: Page): Promise<void> {
  const error = page.locator(".mermaid-error");
  await expect(error).toBeVisible();
  await expect(error.locator("pre.language-mermaid > code")).toContainText(
    MERMAID_SOURCE,
  );
  await expect(page.locator(".mermaid-diagram svg")).toHaveCount(0);
}

test(
  "export HTML renders a rich transcript through primary routed assets",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-test.html";
    try {
      const tid = await createRichExport(page, agentType, outputPath);
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "abort",
        hostActions: { [JSDELIVR_HOST]: "fulfill" },
      });
      const assets = exportAssets(navigation.fixtures);

      expect(await parseShellThroughBridge(page, "echo export")).toEqual({
        ok: true,
        source: "echo export",
        commands: [
          {
            name: "echo",
            argv: ["echo", "export"],
            span: { start: 0, end: 11 },
          },
        ],
      });
      await expectStructuredShell(page);
      await expectRichRust(page);
      await expectRichMermaid(page);

      await expect(
        page.locator('[data-testid="assistant-text"]', {
          hasText: RICH_EXPORT_MARKER,
        }),
      ).toBeVisible();
      const sidebarItems = page.locator(".sidebar-item");
      expect(await sidebarItems.count()).toBeGreaterThan(0);
      await expect(page.locator(".input-textarea")).toHaveCount(0);

      const html = readFileSync(outputPath, "utf8");
      const match = html.match(
        /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
      );
      expect(match).toBeTruthy();
      const data = JSON.parse(match![1]);
      expect(
        data.tasks.find((task: { tid: number }) => task.tid === Number(tid))
          ?.driver,
      ).toBe("claude");

      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expect(navigation.routeState.requests).toContain(
        assets.shiki.jsdelivr.url,
      );
      expect(navigation.routeState.requests).toContain(
        assets.mermaid.jsdelivr.url,
      );
      expect(navigation.routeState.requests).toEqual(
        expect.arrayContaining([
          assets.runtime[0].url,
          assets.bash[0].url,
          assets.core.url,
        ]),
      );
      expect(
        navigation.routeState.actions.every(
          (action) =>
            action.action === "fulfill" &&
            new URL(action.url).hostname === JSDELIVR_HOST,
        ),
      ).toBe(true);
      expect(
        navigation.routeState.actions.some((action) =>
          action.file?.includes("/dist/chunks/"),
        ),
      ).toBe(true);
      expect(navigation.diagnostics.failedRequests).toEqual([]);
      await expectOnlyDiagnostics(navigation.diagnostics, []);
      expect(
        navigation.pageRequests.filter(
          (url) => url.startsWith("file:") && /\.wasm(?:$|[?#])/.test(url),
        ),
      ).toEqual([]);

      expect(html).not.toMatch(
        /\/assets\/(?:web-tree-sitter|tree-sitter-bash)-[^"']+\.wasm/,
      );
      expect(html).not.toContain("data:application/wasm");
      expect(html).not.toMatch(
        /new URL\(["']web-tree-sitter\.wasm["'],\s*import\.meta\.url\)/,
      );
      for (const record of navigation.fixtures.records) {
        expect(html).not.toContain(record.bytes.toString("base64"));
      }
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export HTML falls back from every primary asset host",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-all-primary-fallback.html";
    try {
      await createRichExport(page, agentType, outputPath);
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "abort",
        hostActions: { [UNPKG_HOST]: "fulfill" },
      });
      const assets = exportAssets(navigation.fixtures);

      await expectStructuredShell(page);
      await expectRichRust(page);
      await expectRichMermaid(page);
      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expectCandidateAttempts(navigation.routeState, [
        assets.shiki.jsdelivr,
        assets.shiki.unpkg,
      ]);
      expectCandidateAttempts(navigation.routeState, [
        assets.mermaid.jsdelivr,
        assets.mermaid.unpkg,
      ]);
      expectCandidateAttempts(
        navigation.routeState,
        assets.runtime.slice(0, 2),
      );
      expectCandidateAttempts(navigation.routeState, assets.bash.slice(0, 2));
      const primaryUrls = [
        assets.shiki.jsdelivr.url,
        assets.mermaid.jsdelivr.url,
        assets.runtime[0].url,
        assets.bash[0].url,
      ];
      const jsdelivrRequests = navigation.routeState.requests.filter(
        (url) => new URL(url).hostname === JSDELIVR_HOST,
      );
      expect(jsdelivrRequests.slice().sort()).toEqual(
        primaryUrls.slice().sort(),
      );
      expect(
        jsdelivrRequests
          .filter(
            (url) =>
              navigation.fixtures.byUrl.get(url)?.contentType ===
              "application/javascript",
          )
          .sort(),
      ).toEqual(
        [assets.shiki.jsdelivr.url, assets.mermaid.jsdelivr.url].sort(),
      );
      expect(
        navigation.routeState.requests.filter(
          (url) => new URL(url).hostname === ESM_HOST,
        ),
      ).toEqual([]);
      expect(
        actionFor(navigation.routeState, assets.runtime[1].url).action,
      ).toBe("fulfill");
      expect(actionFor(navigation.routeState, assets.bash[1].url).action).toBe(
        "fulfill",
      );
      await expectOnlyDiagnostics(
        navigation.diagnostics,
        primaryUrls.map(() => expectedBlockedResource),
      );
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export HTML uses tertiary parser-WASM candidates without transformed JavaScript",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-tertiary-wasm.html";
    try {
      await createRichExport(page, agentType, outputPath);
      const fixtures = readExportCdnFixtures();
      const assets = exportAssets(fixtures);
      const urlActions = Object.fromEntries(
        [...assets.runtime, ...assets.bash].map((candidate, index) => [
          candidate.url,
          index % 3 === 2 ? "fulfill" : "abort",
        ]),
      ) as Record<string, "abort" | "fulfill">;
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "abort",
        hostActions: { [JSDELIVR_HOST]: "fulfill" },
        urlActions,
      });

      await expectStructuredShell(page);
      await expectRichRust(page);
      await expectRichMermaid(page);
      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expectCandidateAttempts(navigation.routeState, assets.runtime);
      expectCandidateAttempts(navigation.routeState, assets.bash);
      const esmRequests = navigation.routeState.requests.filter(
        (url) => new URL(url).hostname === ESM_HOST,
      );
      expect(esmRequests.slice().sort()).toEqual(
        [assets.runtime[2].url, assets.bash[2].url].sort(),
      );
      expect(
        navigation.routeState.requests.filter(
          (url) => new URL(url).hostname === ESM_HOST && !url.endsWith(".wasm"),
        ),
      ).toEqual([]);
      expect(
        navigation.routeState.requests.some((url) => url.includes("+esm")),
      ).toBe(false);
      const abortedUrls = Object.entries(urlActions)
        .filter(([, action]) => action === "abort")
        .map(([url]) => url);
      await expectOnlyDiagnostics(
        navigation.diagnostics,
        abortedUrls.map(() => expectedBlockedResource),
      );
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export HTML rejects a tampered transitive Shiki module and restarts from unpkg",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-shiki-tamper.html";
    try {
      await createRichExport(page, agentType, outputPath);
      const fixtures = readExportCdnFixtures();
      const assets = exportAssets(fixtures);
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "fulfill",
        urlActions: { [assets.core.url]: "tamper" },
      });

      await expectStructuredShell(page);
      await expectRichRust(page);
      await expectRichMermaid(page);
      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expectCandidateAttempts(navigation.routeState, [
        assets.shiki.jsdelivr,
        assets.shiki.unpkg,
      ]);
      const tampered = tamperActionFor(navigation.routeState, assets.core.url);
      expect(tampered).toMatchObject({
        action: "tamper",
        expectedIntegrity: assets.core.integrity,
        file: assets.core.file,
        status: 200,
      });
      await expectOnlyDiagnostics(navigation.diagnostics, [
        expectedIntegrityDiagnostic(
          assets.core.url,
          tampered.computedIntegrity,
        ),
      ]);
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export HTML degrades parser structure after every tampered runtime WASM candidate",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-parser-tamper.html";
    try {
      await createRichExport(page, agentType, outputPath);
      const fixtures = readExportCdnFixtures();
      const assets = exportAssets(fixtures);
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "abort",
        hostActions: { [JSDELIVR_HOST]: "fulfill" },
        urlActions: Object.fromEntries(
          assets.runtime.map((candidate) => [candidate.url, "tamper"]),
        ) as Record<string, "tamper">,
      });

      await expectRawShell(page);
      await expectRichRust(page);
      await expectRichMermaid(page);
      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expectCandidateAttempts(navigation.routeState, assets.runtime);
      const tamperedActions = assets.runtime.map((candidate) =>
        tamperActionFor(navigation.routeState, candidate.url),
      );
      for (const [index, action] of tamperedActions.entries()) {
        expect(action).toMatchObject({
          action: "tamper",
          expectedIntegrity: assets.runtime[index]!.integrity,
          file: assets.runtime[index]!.file,
          status: 200,
        });
      }
      await expectOnlyDiagnostics(navigation.diagnostics, [
        ...tamperedActions.map((action) =>
          expectedIntegrityDiagnostic(action.url, action.computedIntegrity),
        ),
        ...tamperedActions.map((action) =>
          expectedFetchIntegrityFailure(action.url),
        ),
        expectedParserExhaustion("web-tree-sitter.wasm"),
      ]);
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export HTML remains readable when every generated CDN host is unavailable",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-raw-degradation.html";
    try {
      await createRichExport(page, agentType, outputPath);
      const navigation = await navigateExport(page, outputPath, {
        defaultAction: "abort",
      });
      const assets = exportAssets(navigation.fixtures);
      const expectedUrls = [
        assets.shiki.jsdelivr.url,
        assets.shiki.unpkg.url,
        assets.mermaid.jsdelivr.url,
        assets.mermaid.unpkg.url,
        ...assets.runtime.map((candidate) => candidate.url),
        ...assets.bash.map((candidate) => candidate.url),
      ];

      await expectRawShell(page);
      await expectRawRust(page);
      await expectRawMermaid(page);
      assertActionCorrespondence(navigation.routeState);
      expectNoUnknownHttps(navigation.routeState);
      expect(navigation.routeState.requests.slice().sort()).toEqual(
        expectedUrls.slice().sort(),
      );
      expectCandidateAttempts(navigation.routeState, [
        assets.shiki.jsdelivr,
        assets.shiki.unpkg,
      ]);
      expectCandidateAttempts(navigation.routeState, [
        assets.mermaid.jsdelivr,
        assets.mermaid.unpkg,
      ]);
      expectCandidateAttempts(navigation.routeState, assets.runtime);
      expectCandidateAttempts(navigation.routeState, assets.bash);
      expect(
        navigation.routeState.actions.every(
          (action) => action.action === "abort",
        ),
      ).toBe(true);
      await expectOnlyDiagnostics(navigation.diagnostics, [
        ...expectedUrls.map(() => expectedBlockedResource),
        expectedShikiExhaustion,
        expectedShikiExhaustion,
        (diagnostic) =>
          expectedParserExhaustion("web-tree-sitter.wasm")(diagnostic) ||
          expectedParserExhaustion("tree-sitter-bash.wasm")(diagnostic),
      ]);
    } finally {
      deleteExport(outputPath);
    }
  },
);

test(
  "export-html includes transcript for custom Claude-backed agent",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const outputPath = "/tmp/cydo-export-custom-agent.html";

    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `default_agent: claude
agents:
  claude:
    driver: claude
  work-claude:
    driver: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
    );
    await page.waitForTimeout(500);

    try {
      await enterSession(page);
      await page.selectOption(".agent-picker", "work-claude");
      await sendMessage(page, 'reply with "custom-export-marker-ok"');
      await expect(
        lastAssistantText(page, "custom-export-marker-ok"),
      ).toBeVisible({ timeout: responseTimeout(agentType) });

      await killSession(page, agentType);

      const tid = await page
        .locator(".sidebar-item.active")
        .getAttribute("data-tid");
      expect(tid).toBeTruthy();

      exportHtml(tid!, outputPath);
      const fixtures = readExportCdnFixtures();
      const routeState = await installExportCdnRoutes(page, fixtures, {
        defaultAction: "fulfill",
      });
      await page.goto(`file://${outputPath}`);
      await expect(
        page.locator('[data-testid="assistant-text"]', {
          hasText: "custom-export-marker-ok",
        }),
      ).toBeVisible();
      expect(routeState.unexpectedHttps).toEqual([]);
    } finally {
      deleteExport(outputPath);
    }
  },
);

// ---------------------------------------------------------------------------
// AC23 real-Claude export-html split-profile / missing-profile regression
// tests.
//
// Mirrors custom-claude-agent-lifecycle.spec.ts's AC21 profile-lifecycle
// tests: a separate backend-parent profile (A) from the configured
// work-claude agent's profile (B, later reconfigurable to C). `export-html`
// is a standalone CLI invocation with no live in-memory binding of its
// own — like AC21's own cold-read path, it always resolves the task's
// history against whatever profile is CURRENTLY configured at the moment it
// runs (there is no persisted native path/root to fall back on), so a task
// whose real content lives at B can only be exported successfully while B
// is still current; once reconfigured away, export-html must fail cleanly
// rather than silently substituting the new (or backend-parent) root's
// content.
// ---------------------------------------------------------------------------

type ProfiledClaudeBackend = {
  baseURL: string;
  workDir: string;
  workerHome: string;
  configPath: string;
  backendProfileA: string;
  profileB: string;
  profileC: string;
};

const EXPORT_PROFILE_WORK_DIR = "/tmp/cydo-export-html-profile-lifecycle";
const EXPORT_PROFILE_BASE_URL = "http://localhost:3940";

function initClaudeProfileDir(dir: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "settings.json"),
    JSON.stringify({
      hasCompletedOnboarding: true,
      theme: "dark",
      skipDangerousModePermissionPrompt: true,
      autoUpdates: false,
    }),
  );
}

/** Write a complete work-claude config pointed at the given profile root. */
function writeProfileConfig(
  configPath: string,
  profileRoot: string,
  displayName: string,
): void {
  writeTestConfig(
    configPath,
    `default_agent: work-claude
agents:
  work-claude:
    driver: claude
    display_name: ${displayName}
    sandbox:
      env:
        CLAUDE_CONFIG_DIR: ${profileRoot}
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
}

function spawnProfiledBackend(
  workDir: string,
  workerHome: string,
  backendProfileA: string,
): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CLAUDE_CONFIG_DIR: backendProfileA,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function waitForProfiledBackend(
  baseURL: string,
  proc: ChildProcess,
  timeoutMs = 30_000,
): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
    if (proc.exitCode !== null) {
      reject(
        new Error(`Backend process already exited with code ${proc.exitCode}`),
      );
      return;
    }
    proc.on("exit", (code, signal) => {
      reject(
        new Error(
          `Backend process exited with code ${code}` +
            `${signal ? ` (signal ${signal})` : ""} before becoming ready`,
        ),
      );
    });
  });

  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) return;
      } catch {
        // not ready yet
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${baseURL} did not start in time`);
  })();

  await Promise.race([polling, processExited]);
}

/**
 * Local backend fixture with a separate backend-parent profile (A) and
 * configured agent profile (B/C). Overrides baseURL so page.goto("/")
 * targets this backend instead of fixtures.ts's fixed /tmp/cydo-backend.
 * Uses its own work dir, distinct from custom-claude-agent-lifecycle.spec.ts's
 * PROFILE_WORK_DIR, so the two specs' fixtures never collide.
 */
const profiledTest = base.extend<{ profileBackend: ProfiledClaudeBackend }>({
  profileBackend: async ({}, use) => {
    const workDir = EXPORT_PROFILE_WORK_DIR;
    const workerHome = `${workDir}/home`;
    const backendProfileA = `${workDir}/profile-a`;
    const profileB = `${workDir}/profile-b`;
    const profileC = `${workDir}/profile-c`;
    const configPath = `${workerHome}/.config/cydo/config.yaml`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });

    initClaudeProfileDir(backendProfileA);
    initClaudeProfileDir(profileB);
    writeProfileConfig(configPath, profileB, "Profile B");

    const proc = spawnProfiledBackend(workDir, workerHome, backendProfileA);
    try {
      await waitForProfiledBackend(EXPORT_PROFILE_BASE_URL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {
        // already gone
      }
      throw e;
    }

    await use({
      baseURL: EXPORT_PROFILE_BASE_URL,
      workDir,
      workerHome,
      configPath,
      backendProfileA,
      profileB,
      profileC,
    });

    await killBackend(proc);
  },
  baseURL: async ({ profileBackend }, use) => {
    await use(profileBackend.baseURL);
  },
});

/** Poll root/projects for exactly one real CLI JSONL containing marker. */
async function findNativeJsonlContaining(
  root: string,
  marker: string,
): Promise<string> {
  const projectsDir = join(root, "projects");
  let found: string | undefined;
  await expect
    .poll(() => {
      if (!existsSync(projectsDir)) return 0;
      const matches: string[] = [];
      for (const entry of readdirSync(projectsDir, {
        recursive: true,
      }) as string[]) {
        if (!entry.endsWith(".jsonl")) continue;
        const full = join(projectsDir, entry);
        try {
          if (readFileSync(full, "utf8").includes(marker)) matches.push(full);
        } catch {
          // file may be mid-write; retry on next poll
        }
      }
      found = matches.length === 1 ? matches[0] : undefined;
      return matches.length;
    })
    .toBe(1);
  return found!;
}

function relativeNativePath(root: string, realFile: string): string {
  const rel = relative(root, realFile);
  expect(rel.startsWith("projects/")).toBe(true);
  return rel;
}

/** Create a valid two-line native Claude session at the given relative location. */
function writeSameIdPoison(
  root: string,
  relativePath: string,
  sessionId: string,
  cwd: string,
  marker: string,
): void {
  const fullPath = join(root, relativePath);
  mkdirSync(dirname(fullPath), { recursive: true });
  const content =
    [
      JSON.stringify({
        type: "user",
        cwd,
        sessionId,
        message: { role: "user", content: marker },
      }),
    ].join("\n") + "\n";
  writeFileSync(fullPath, content);
}

function readFileOrEmpty(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

async function activeTaskTid(page: Page): Promise<string> {
  const row = page.locator(".sidebar-item.active");
  await expect(row).toBeVisible();
  const tid = await row.getAttribute("data-tid");
  expect(tid).toBeTruthy();
  return tid!;
}

function exportHtmlCli(
  profileBackend: ProfiledClaudeBackend,
  tid: string,
  outputPath: string,
): ReturnType<typeof spawnSync> {
  return spawnSync(
    process.env.CYDO_BIN!,
    ["export-html", tid, "--output", outputPath],
    {
      env: {
        ...process.env,
        HOME: profileBackend.workerHome,
        XDG_DATA_HOME: `${profileBackend.workDir}/data`,
      },
      encoding: "utf8",
    },
  );
}

profiledTest(
  "cydo export-html resolves the configured profile B, never backend-parent A, and stops working once reconfigured to C",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const liveMarker = "export-split-b-live-marker";
    const poisonMarker = "export-split-a-poison-marker";
    const cwd = "/tmp/cydo-test-workspace";
    const outputPath = `${profileBackend.workDir}/export-b.html`;
    const outputPathAfterReconfigure = `${profileBackend.workDir}/export-b-after-c.html`;

    await enterSession(page);
    await sendMessage(page, `reply with "${liveMarker}"`);
    await expect(assistantText(page, liveMarker)).toBeVisible();

    const tid = await activeTaskTid(page);
    const realFile = await findNativeJsonlContaining(
      profileBackend.profileB,
      liveMarker,
    );
    const relPath = relativeNativePath(profileBackend.profileB, realFile);
    const sessionId = basename(realFile, ".jsonl");

    // Adversarial same-session-ID poison under the backend's own parent
    // profile (A): a fallback to A would surface this instead of B's own
    // content.
    writeSameIdPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      poisonMarker,
    );
    const poisonAContent = readFileSync(
      join(profileBackend.backendProfileA, relPath),
      "utf8",
    );

    await endSession(page);

    try {
      // While work-claude is still configured at B, export succeeds and
      // contains exactly B's content.
      const result = exportHtmlCli(profileBackend, tid, outputPath);
      expect(result.status).toBe(0);

      const html = readFileSync(outputPath, "utf8");
      const match = html.match(
        /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
      );
      expect(match).toBeTruthy();
      const data = JSON.parse(match![1]);
      expect(
        data.tasks.find((t: { tid: number }) => t.tid === Number(tid))?.driver,
      ).toBe("claude");
      const eventsText = JSON.stringify(data.events[tid]);
      expect(eventsText).toContain(liveMarker);
      expect(eventsText).not.toContain(poisonMarker);

      // Reconfigure work-claude live, from B to C, after the task is
      // already ended (cold). Cold resolution always re-derives the
      // CURRENTLY configured profile (see custom-claude-agent-lifecycle
      // .spec.ts's "real Claude retains live profile B but uses current
      // profile C after End" test for the equivalent live-server proof) —
      // there is no persisted native root to fall back on — so a *second*
      // export attempt for the same task must now fail instead of silently
      // substituting C's (or A's) content for B's.
      initClaudeProfileDir(profileBackend.profileC);
      writeProfileConfig(
        profileBackend.configPath,
        profileBackend.profileC,
        "Profile C",
      );
      await enterSession(page);
      await expect(
        page.locator('.agent-picker option[value="work-claude"]'),
      ).toHaveText("Profile C");

      const resultAfterReconfigure = exportHtmlCli(
        profileBackend,
        tid,
        outputPathAfterReconfigure,
      );
      expect(resultAfterReconfigure.status).toBe(1);
      expect(resultAfterReconfigure.stderr).toContain(
        `Cannot export task ${tid}: session history is unavailable`,
      );
      expect(existsSync(outputPathAfterReconfigure)).toBe(false);

      // Neither the real B file nor the A poison were ever touched.
      expect(readFileOrEmpty(realFile)).toContain(liveMarker);
      expect(
        readFileOrEmpty(join(profileBackend.backendProfileA, relPath)),
      ).toBe(poisonAContent);
    } finally {
      try {
        unlinkSync(outputPath);
      } catch {
        // file may not exist if export failed
      }
      try {
        unlinkSync(outputPathAfterReconfigure);
      } catch {
        // file is not expected to exist — the failed export must never
        // create it
      }
    }
  },
);

profiledTest(
  "cydo export-html fails gracefully instead of producing empty output when the configured profile root is missing",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const liveMarker = "export-missing-root-marker";
    const outputPath = `${profileBackend.workDir}/export-missing.html`;

    await enterSession(page);
    await sendMessage(page, `reply with "${liveMarker}"`);
    await expect(assistantText(page, liveMarker)).toBeVisible();

    const tid = await activeTaskTid(page);
    await findNativeJsonlContaining(profileBackend.profileB, liveMarker);

    await endSession(page);

    // Remove the entire configured profile root — work-claude's config
    // still points at it (no reconfigure), but the directory itself is gone.
    rmSync(profileBackend.profileB, { recursive: true, force: true });

    try {
      const result = exportHtmlCli(profileBackend, tid, outputPath);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain(
        `Cannot export task ${tid}: session history is unavailable`,
      );
      expect(existsSync(outputPath)).toBe(false);
    } finally {
      try {
        unlinkSync(outputPath);
      } catch {
        // file is not expected to exist — the failed export must never
        // create it
      }
    }
  },
);
