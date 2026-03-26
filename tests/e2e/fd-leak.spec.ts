import { readdirSync, readlinkSync } from "fs";
import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

function getFdCount(pid: number): number {
  return readdirSync(`/proc/${pid}/fd`).length;
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
  test.skip(agentType !== "claude", "codex has a separate FD leak to investigate");

  // Warm up: load the page so HTTP/WebSocket connections are established
  // before we take the baseline FD measurement.
  await page.goto("/");
  await page.waitForLoadState("load");
  await new Promise((r) => setTimeout(r, 2000));

  const fdBefore = getFdCount(backend.pid);
  const fdDetailsBefore = getFdDetails(backend.pid);

  // Spawn a session, send a message, wait for response, then kill the session
  await enterSession(page);
  await sendMessage(page, 'Please reply with "fd-leak-test"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fd-leak-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);

  // Give the backend time to finish async cleanup
  await new Promise((r) => setTimeout(r, 2000));

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
  test.skip(agentType !== "claude", "codex has a separate FD leak to investigate");
  test.setTimeout(120_000);

  // Warm up
  await page.goto("/");
  await page.waitForLoadState("load");
  await new Promise((r) => setTimeout(r, 2000));

  const fdBaseline = getFdCount(backend.pid);
  const cycles = 3;
  const fdCounts: number[] = [fdBaseline];

  for (let i = 0; i < cycles; i++) {
    await enterSession(page);
    await sendMessage(page, `Please reply with "cycle-${i}"`);
    await expect(
      page.locator(".message.assistant-message .text-content", { hasText: `cycle-${i}` }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
    await killSession(page, agentType);
    await new Promise((r) => setTimeout(r, 2000));

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
