import {
  expect,
  installCydoE2eBridge,
  parseShellThroughBridge,
  test,
} from "./fixtures";
import { readExportCdnFixtures } from "./export-cdn-fixtures";

test(
  "normal packaged app loads and parses its local shell parser assets",
  {
    tag: "@claude-only",
  },
  async ({ page }) => {
    const fixtures = readExportCdnFixtures();
    const requests: string[] = [];
    const pageErrors: string[] = [];
    const wasmResponses: Array<{
      url: string;
      contentType: string | undefined;
      body: () => Promise<Buffer>;
    }> = [];

    await installCydoE2eBridge(page);
    page.on("request", (request) => requests.push(request.url()));
    page.on("pageerror", (error) =>
      pageErrors.push(`${error.name}: ${error.message}`),
    );
    page.on("response", (response) => {
      if (!/\.wasm(?:$|[?#])/.test(response.url())) return;
      wasmResponses.push({
        url: response.url(),
        contentType: response.headers()["content-type"],
        body: () => response.body(),
      });
    });

    await page.goto("/");

  expect(await parseShellThroughBridge(page, "echo normal")).toEqual({
      ok: true,
      source: "echo normal",
      commands: [
        {
          name: "echo",
          argv: ["echo", "normal"],
          span: { start: 0, end: 11 },
        },
      ],
    });

    expect(pageErrors).toEqual([]);
    expect(wasmResponses).toHaveLength(2);

    const expectedFiles = new Map([
      ["web-tree-sitter", "files/web-tree-sitter/web-tree-sitter.wasm"],
      ["tree-sitter-bash", "files/tree-sitter-bash/tree-sitter-bash.wasm"],
    ]);
    const seenArtifacts = new Set<string>();

    for (const observed of wasmResponses) {
      const parsedUrl = new URL(observed.url);
      expect(parsedUrl.origin).toBe(new URL(page.url()).origin);
      expect(parsedUrl.pathname).toMatch(
        /^\/assets\/(?:web-tree-sitter|tree-sitter-bash)-[A-Za-z0-9_-]+\.wasm$/,
      );

      const artifact = [...expectedFiles].find(([name]) =>
        parsedUrl.pathname.includes(`/${name}-`),
      );
      expect(artifact).toBeDefined();
      const [artifactName, fixtureFile] = artifact!;
      expect(seenArtifacts.has(artifactName)).toBe(false);
      seenArtifacts.add(artifactName);

      expect(observed.contentType).toBe("application/wasm");
      const bytes = await observed.body();
      expect([...bytes.subarray(0, 4)]).toEqual([0, 0x61, 0x73, 0x6d]);
      const fixture = fixtures.records.find(
        (record) => record.file === fixtureFile,
      );
      expect(fixture).toBeDefined();
      expect(bytes).toEqual(fixture!.bytes);
    }

    expect(seenArtifacts).toEqual(new Set(expectedFiles.keys()));
    const wasmRequestUrls = requests.filter((url) =>
      new URL(url).pathname.endsWith(".wasm"),
    );
    expect(wasmRequestUrls).toHaveLength(2);
    expect(new Set(wasmRequestUrls).size).toBe(2);
    expect([...new Set(wasmRequestUrls)].sort()).toEqual(
      wasmResponses.map(({ url }) => url).sort(),
    );
    expect(
      requests.filter((url) => {
        const parsedUrl = new URL(url);
        return (
          /\.wasm(?:$|[?#])/.test(parsedUrl.pathname) &&
          ["cdn.jsdelivr.net", "unpkg.com", "esm.sh"].includes(
            parsedUrl.hostname,
          )
        );
      }),
    ).toEqual([]);
  },
);
