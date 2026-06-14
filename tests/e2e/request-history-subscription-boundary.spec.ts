import { test as base, expect } from "@playwright/test";
import { spawn } from "child_process";
import { mkdirSync, rmSync, symlinkSync } from "fs";

import { assistantText, enterSession, sendMessage } from "./fixtures";

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

function waitForClose(ws: WebSocket, timeoutMs = 5_000): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`Timed out waiting for WebSocket close after ${timeoutMs}ms`));
    }, timeoutMs);
    ws.addEventListener(
      "close",
      () => {
        clearTimeout(timeout);
        resolve();
      },
      { once: true },
    );
    ws.addEventListener(
      "error",
      () => reject(new Error("WebSocket failed while closing")),
      { once: true },
    );
  });
}

async function decodeWebSocketData(data: unknown): Promise<string> {
  if (typeof data === "string") {
    return data;
  }
  if (data instanceof Blob) {
    return await data.text();
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8");
  }
  return String(data);
}

function containsLiveTurnText(
  msg: any,
  livePrompt: string,
  liveReply: string,
): boolean {
  const text = JSON.stringify(msg);
  return text.includes(livePrompt) || text.includes(liveReply);
}

const test = base.extend<WorkerFixtures>({
  backend: [
    async (
      {},
      use: (value: WorkerFixtures["backend"]) => Promise<void>,
    ) => {
      const workDir = "/tmp/cydo-request-history-subscription-boundary";

      rmSync(workDir, { recursive: true, force: true });
      mkdirSync(`${workDir}/data`, { recursive: true });
      symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

      const proc = spawn(process.env.CYDO_BIN!, [], {
        detached: true,
        cwd: workDir,
        env: {
          ...process.env,
          XDG_DATA_HOME: `${workDir}/data`,
        },
        stdio: ["ignore", "inherit", "inherit"],
      });

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

test("request_history replays before later live task updates on the same socket", async ({
  page,
  backend,
}) => {
  const timeoutMs = test.info().project.name === "codex" ? 90_000 : 60_000;

  let tid: number | null = null;
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const data = JSON.parse(frame.payload.toString()) as {
          type?: string;
          tid?: number;
        };
        if (data.type === "task_created" && typeof data.tid === "number") {
          tid = data.tid;
        }
      } catch {
        // Ignore non-JSON frames.
      }
    });
  });

  await enterSession(page);

  const seedReply = `history-boundary-seed-${Date.now()}`;
  await sendMessage(page, `reply with "${seedReply}"`);
  await expect(assistantText(page, seedReply)).toBeVisible({
    timeout: timeoutMs,
  });
  await expect.poll(() => tid ?? -1, { timeout: 15_000 }).toBeGreaterThan(0);
  const taskId = tid!;

  const observer = new WebSocket(`${backend.baseURL.replace(/^http/, "ws")}/ws`);
  await waitForOpen(observer);

  const frames: any[] = [];
  let frameDrain: Promise<void> = Promise.resolve();
  observer.addEventListener("message", (event) => {
    frameDrain = frameDrain
      .then(async () => {
        try {
          frames.push(JSON.parse(await decodeWebSocketData(event.data)));
        } catch {
          // Ignore non-JSON frames.
        }
      })
      .catch(() => {});
  });

  const requestStartIndex = frames.length;
  observer.send(JSON.stringify({ type: "request_history", tid: taskId }));

  const liveReply = `history-boundary-live-${Date.now()}`;
  const livePrompt = `reply with "${liveReply}"`;
  await sendMessage(page, livePrompt);

  await expect
    .poll(
      () =>
        frames.findIndex(
          (msg, idx) =>
            idx >= requestStartIndex &&
            msg?.type === "task_history_end" &&
            msg?.tid === taskId,
        ),
      { timeout: 15_000 },
    )
    .not.toBe(-1);

  await frameDrain;
  const historyEndAbsoluteIndex = frames.findIndex(
    (msg, idx) =>
      idx >= requestStartIndex &&
      msg?.type === "task_history_end" &&
      msg?.tid === taskId,
  );

  await expect
    .poll(
      () =>
        frames.findIndex(
          (msg, idx) =>
            idx >= requestStartIndex &&
            msg?.tid === taskId &&
            (msg?.unconfirmedUserEvent !== undefined ||
              msg?.event !== undefined) &&
            containsLiveTurnText(msg, livePrompt, liveReply),
        ),
      { timeout: 15_000 },
    )
    .not.toBe(-1);

  const requestFrames = frames.slice(requestStartIndex);
  const historyStartIndex = requestFrames.findIndex(
    (msg) => msg?.type === "task_history_start" && msg?.tid === taskId,
  );
  const historyEndIndex = requestFrames.findIndex(
    (msg) => msg?.type === "task_history_end" && msg?.tid === taskId,
  );
  const replayEventIndices = requestFrames.flatMap((msg, idx) =>
    msg?.tid === taskId &&
    typeof msg?.seq === "number" &&
    msg?.event !== undefined
      ? [idx]
      : [],
  );

  expect(historyStartIndex).toBeGreaterThanOrEqual(0);
  expect(historyEndIndex).toBeGreaterThan(historyStartIndex);
  expect(replayEventIndices.length).toBeGreaterThan(0);
  for (const idx of replayEventIndices) {
    expect(idx).toBeGreaterThan(historyStartIndex);
    expect(idx).toBeLessThan(historyEndIndex);
  }

  await frameDrain;
  const liveUpdateIndex = frames.findIndex(
    (msg, idx) =>
      idx >= requestStartIndex &&
      msg?.tid === taskId &&
      (msg?.unconfirmedUserEvent !== undefined ||
        msg?.event !== undefined) &&
      containsLiveTurnText(msg, livePrompt, liveReply),
  );

  expect(liveUpdateIndex).toBeGreaterThan(historyEndAbsoluteIndex);
  expect(
    frames
      .slice(requestStartIndex, historyEndAbsoluteIndex + 1)
      .some((msg) => containsLiveTurnText(msg, livePrompt, liveReply)),
  ).toBe(false);

  await expect(assistantText(page, liveReply)).toBeVisible({
    timeout: timeoutMs,
  });

  const closePromise = waitForClose(observer);
  observer.close();
  await closePromise;
  await page.waitForTimeout(250);
});
