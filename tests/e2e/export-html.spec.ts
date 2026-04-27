import { spawnSync } from "child_process";
import { unlinkSync } from "fs";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  lastAssistantText,
} from "./fixtures";

test("export-html creates viewable HTML file", async ({ page, backend, agentType }, testInfo) => {
  test.skip(testInfo.project.name !== "claude", "agent-agnostic, runs in claude project only");

  const outputPath = "/tmp/cydo-export-test.html";

  try {
    await enterSession(page);
    await sendMessage(page, 'reply with "export-marker-ok"');
    await expect(lastAssistantText(page, "export-marker-ok")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await killSession(page, agentType);

    const tid = await page.locator(".sidebar-item.active").getAttribute("data-tid");
    expect(tid).toBeTruthy();

    const result = spawnSync(
      process.env.CYDO_BIN!,
      ["export-html", tid!, "--output", outputPath],
      {
        env: {
          ...process.env,
          XDG_DATA_HOME: "/tmp/cydo-backend/data",
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(`cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
    }

    await page.goto(`file://${outputPath}`);

    await expect(
      page.locator('[data-testid="assistant-text"]', { hasText: "export-marker-ok" }),
    ).toBeVisible({ timeout: 10_000 });

    await expect(page.locator(".sidebar-item")).toHaveCount(
      await page.locator(".sidebar-item").count(),
    );
    const sidebarItems = page.locator(".sidebar-item");
    expect(await sidebarItems.count()).toBeGreaterThan(0);

    await expect(page.locator(".input-textarea")).toHaveCount(0);
  } finally {
    try {
      unlinkSync(outputPath);
    } catch {
      // file may not exist if export failed
    }
  }
});
