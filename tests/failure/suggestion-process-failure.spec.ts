import { test as base, expect } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import { mkdirSync, cpSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";

type WorkerFixtures = {
  backend: { baseURL: string };
};

function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener(
      "error",
      () => reject(new Error("WebSocket failed to open")),
      { once: true },
    );
  });
}

function waitForMessage(
  ws: WebSocket,
  predicate: (data: any) => boolean,
  timeoutMs: number,
): Promise<any> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ws.removeEventListener("message", onMessage);
      reject(
        new Error(
          `Timed out waiting for matching WebSocket message after ${timeoutMs}ms`,
        ),
      );
    }, timeoutMs);

    const onMessage = async (event: MessageEvent) => {
      try {
        let rawText: string;
        if (typeof event.data === "string") {
          rawText = event.data;
        } else if (event.data instanceof Blob) {
          rawText = await event.data.text();
        } else if (event.data instanceof ArrayBuffer) {
          rawText = Buffer.from(event.data).toString("utf8");
        } else {
          rawText = String(event.data);
        }
        const data = JSON.parse(rawText);
        if (!predicate(data)) {
          return;
        }
        clearTimeout(timeout);
        ws.removeEventListener("message", onMessage);
        resolve(data);
      } catch {
        // Ignore non-JSON frames.
      }
    };

    ws.addEventListener("message", onMessage);
  });
}

const test = base.extend<WorkerFixtures>({
  backend: [
    async (
      {},
      use: (value: WorkerFixtures["backend"]) => Promise<void>,
    ) => {
      const workDir = "/tmp/cydo-suggestion-failure";
      const workerHome = `${workDir}/home`;

      mkdirSync(`${workDir}/data`, { recursive: true });
      symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

      mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
      cpSync(
        "/tmp/playwright-home/.config/cydo/config.yaml",
        `${workerHome}/.config/cydo/config.yaml`,
      );

      const codexHome = `${workDir}/codex-home`;
      mkdirSync(codexHome, { recursive: true });
      writeFileSync(
        `${codexHome}/config.toml`,
        'model = "codex-mini-latest"\napproval_mode = "full-auto"\n',
      );

      const wrapperPath = join(
        __dirname,
        "..",
        "suggestion-one-shot-fail-wrapper.sh",
      );
      const realClaudeBin = execFileSync("sh", ["-lc", "command -v claude"], {
        encoding: "utf8",
      }).trim();

      const proc = spawn(process.env.CYDO_BIN!, [], {
        detached: true,
        cwd: workDir,
        env: {
          ...process.env,
          HOME: workerHome,
          CYDO_CLAUDE_BIN: wrapperPath,
          CYDO_REAL_CLAUDE_BIN: realClaudeBin,
          CODEX_HOME: codexHome,
        },
        stdio: ["ignore", "inherit", "inherit"],
      });

      // Poll for readiness on fixed port
      const baseURL = "http://localhost:3940";
      for (let i = 0; i < 60; i++) {
        try {
          const res = await fetch(baseURL);
          if (res.ok || res.status < 500) break;
        } catch {}
        await new Promise((resolve) => setTimeout(resolve, 500));
      }

      await use({ baseURL });

      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {}
      await new Promise<void>((resolve) => proc.on("exit", resolve));
    },
    { scope: "worker" },
  ],

  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },
});

test("suggestion one-shot rejection keeps session responsive", async ({
  backend,
}) => {
  const ws = new WebSocket(`${backend.baseURL.replace("http", "ws")}/ws`);
  await waitForOpen(ws);

  const createdPromise = waitForMessage(
    ws,
    (data) => data.type === "task_created" && typeof data.tid === "number",
    10_000,
  );
  ws.send(
    JSON.stringify({
      type: "create_task",
      workspace: "local",
      project_path: "/tmp/cydo-test-workspace",
      correlation_id: "repro",
    }),
  );

  const created = await createdPromise;
  const tid = created.tid as number;

  const historyEndPromise = waitForMessage(
    ws,
    (data) => data.type === "task_history_end" && data.tid === tid,
    10_000,
  );
  ws.send(JSON.stringify({ type: "request_history", tid }));
  await historyEndPromise;

  for (let i = 0; i < 6; i++) {
    const resultPromise = waitForMessage(
      ws,
      (data) =>
        data.event?.type === "turn/result" && data.event?.subtype === "success",
      30_000,
    );
    ws.send(
      JSON.stringify({
        type: "message",
        tid,
        content: [{ type: "text", text: 'Please reply with "done"' }],
      }),
    );
    await resultPromise;
  }

  ws.close();
});
