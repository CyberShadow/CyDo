import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

it("skips later tests in a file after a test times out", async ({ signal }) => {
  const tempDir = mkdtempSync(join(tmpdir(), "cydo-vitest-timeout-"));
  try {
    const reportPath = join(tempDir, "report.json");
    const require = createRequire(import.meta.url);
    const vitest = join(
      dirname(require.resolve("vitest/package.json")),
      "vitest.mjs",
    );
    const child = spawn(
      process.execPath,
      [
        vitest,
        "run",
        "--config=src/test-support/fixtures/timeoutIsolation.config.ts",
        "--testTimeout=200",
        "--reporter=default",
        "--reporter=json",
        `--outputFile.json=${reportPath}`,
      ],
      {
        cwd: fileURLToPath(new URL("..", import.meta.url)),
        detached: true,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );

    let output = "";
    for (const stream of [child.stdout, child.stderr]) {
      stream.setEncoding("utf8").on("data", (chunk) => {
        output += chunk;
      });
    }
    try {
      const [status] = await once(child, "close", { signal });
      expect(status, output).toBe(1);
    } finally {
      if (child.pid !== undefined) {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch (error) {
          if (error.code !== "ESRCH") throw error;
        }
      }
    }
    const report = JSON.parse(readFileSync(reportPath, "utf8"));
    expect(report.testResults).toEqual([
      expect.objectContaining({
        assertionResults: [
          expect.objectContaining({
            title: "times out",
            status: "failed",
          }),
          expect.objectContaining({
            title: "stubs a global",
            status: "skipped",
          }),
          expect.objectContaining({
            title: "runs a plain test",
            status: "skipped",
          }),
        ],
      }),
    ]);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
