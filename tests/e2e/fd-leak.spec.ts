import { readdirSync, readlinkSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

function getFdCount(pid: number): number {
  return readdirSync(`/proc/${pid}/fd`).length;
}

async function waitForFdStabilization(
  pid: number,
  timeoutMs: number = 10_000,
  pollMs: number = 200,
  stableSamples: number = 4,
): Promise<void> {
  let stableCount = 0;
  let lastCount = getFdCount(pid);
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, pollMs));
    const current = getFdCount(pid);
    if (current === lastCount) {
      stableCount += 1;
      if (stableCount >= stableSamples) {
        return;
      }
      continue;
    }
    lastCount = current;
    stableCount = 0;
  }

  throw new Error(
    `FD count for backend pid ${pid} did not stabilize within ${timeoutMs}ms (last count: ${lastCount})`,
  );
}

function getFdDetails(pid: number): string[] {
  const fdDir = `/proc/${pid}/fd`;
  const entries = readdirSync(fdDir);
  return entries.map((fd) => {
    try {
      return `${fd} -> ${readlinkSync(`${fdDir}/${fd}`)}`;
    } catch {
      return `${fd} -> (unreadable)`;
    }
  });
}

test("agent session teardown does not leak file descriptors", async ({
  page,
  backend,
  agentType,
}) => {
  test.setTimeout(120_000);

  // Warm up: load the page so HTTP/WebSocket connections are established
  // before we take the baseline FD measurement.
  await page.goto("/");
  await page.waitForLoadState("load");
  await waitForFdStabilization(backend.pid);

  const fdBefore = getFdCount(backend.pid);
  const fdDetailsBefore = getFdDetails(backend.pid);

  // Spawn a session, send a message, wait for response, then kill the session
  await enterSession(page);
  await sendMessage(page, 'Please reply with "fd-leak-test"');
  await expect(assistantText(page, "fd-leak-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(page.locator(".suggestions")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await killSession(page, agentType);
  await waitForFdStabilization(backend.pid);

  const fdAfter = getFdCount(backend.pid);
  const fdDetailsAfter = getFdDetails(backend.pid);

  // Compute which FDs are new (leaked)
  const beforeSet = new Set(fdDetailsBefore);
  const leakedFds = fdDetailsAfter.filter((fd) => !beforeSet.has(fd));

  // FD count should not grow — leaked ThreadAnchor socket pairs add 2 FDs each
  expect(
    fdAfter,
    `FD count grew from ${fdBefore} to ${fdAfter} after session teardown (leak of ${fdAfter - fdBefore} FDs).\n` +
      `Before (${fdBefore} FDs):\n${fdDetailsBefore.join("\n")}\n\n` +
      `After (${fdAfter} FDs):\n${fdDetailsAfter.join("\n")}\n\n` +
      `New FDs:\n${leakedFds.join("\n")}`,
  ).toBeLessThanOrEqual(fdBefore);
});

test("FD count stays stable across multiple session cycles", async ({
  page,
  backend,
  agentType,
}) => {
  test.setTimeout(300_000);

  // Warm up
  await page.goto("/");
  await page.waitForLoadState("load");
  await waitForFdStabilization(backend.pid);

  const fdBaseline = getFdCount(backend.pid);
  const cycles = 3;
  const fdCounts: number[] = [fdBaseline];

  for (let i = 0; i < cycles; i++) {
    await enterSession(page);
    await sendMessage(page, `Please reply with "cycle-${i}"`);
    await expect(assistantText(page, `cycle-${i}`)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(page.locator(".suggestions")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await killSession(page, agentType);
    await waitForFdStabilization(backend.pid);

    const fdNow = getFdCount(backend.pid);
    fdCounts.push(fdNow);
  }

  const fdFinal = fdCounts[fdCounts.length - 1];
  const fdDetailsAfter = getFdDetails(backend.pid);

  expect(
    fdFinal,
    `FD count drifted over ${cycles} cycles: ${fdCounts.join(" → ")}\n` +
      `Final FDs (${fdFinal}):\n${fdDetailsAfter.join("\n")}`,
  ).toBeLessThanOrEqual(fdBaseline + 1); // allow 1 FD of slack
});
