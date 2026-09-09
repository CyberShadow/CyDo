import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("sidebar status dot reflects session state", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "dot-test"');

  const sidebarItem = page.locator(".sidebar-item", {
    hasText: "dot-test",
  });
  await expect(sidebarItem).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await expect(assistantText(page, "dot-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await expect(sidebarItem.locator(".task-type-icon.alive")).toBeVisible();

  await killSession(page, agentType);

  await expect(sidebarItem.locator(".task-type-icon.failed")).toBeVisible();
});

test("multi-client navigation isolation", { tag: "@no-codex" }, async ({
  page,
  agentType,
  context,
}) => {
  const pageA = page;
  const pageB = await context.newPage();

  await enterSession(pageA);
  await enterSession(pageB);

  await sendMessage(pageA, 'Please reply with "isolation-a"');

  await expect(
    pageA.locator(".message.user-message", { hasText: "isolation-a" }),
  ).toBeVisible();

  await expect(
    pageB.locator(".message.user-message", { hasText: "isolation-a" }),
  ).not.toBeVisible();

  await expect(
    pageB.locator(".sidebar-item .sidebar-label", { hasText: "isolation-a" }),
  ).toBeVisible();

  await pageB.close();
});

test("auto-scroll stays at bottom for new messages", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  await sendMessage(page, 'Please reply with "scroll-test"');
  await expect(assistantText(page, "scroll-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const scrollTop = await page
    .locator(".message-list")
    .evaluate((el) => el.scrollTop);
  expect(scrollTop).toBeGreaterThanOrEqual(-1);
});

test("tool result with Bash output renders correctly", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "Please run command echo tool-result-test");

  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  await expect(page.locator(".tool-name", { hasText: toolName })).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await expect(
    page.locator(".tool-result", { hasText: "tool-result-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType)});

  // Tool subtitle only present for Claude (description field)
  if (agentType === "claude") {
    await expect(
      page.locator(".tool-subtitle", { hasText: "Running command" }),
    ).toBeVisible();
  }
});

test("fork stays focused on forked session", async ({ page, agentType }) => {
  const frames: any[] = [];
  let postReloadFrameStart = 0;
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        frames.push(JSON.parse(event.payload.toString()));
      } catch {}
    });
  });
  await enterSession(page);
  await sendMessage(page, 'Please reply with "fork-bootstrap"');

  await expect(assistantText(page, "fork-bootstrap")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const targetPrompt = 'Please reply with "fork-source"';
  await sendMessage(page, targetPrompt);

  await expect(assistantText(page, "fork-source")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  if (agentType === "codex" || agentType === "copilot") {
    // Codex/Copilot: kill and reload so JSONL is finalized and fork buttons appear
    await killSession(page, agentType);
    postReloadFrameStart = frames.length;
    await page.reload();
    await expect(assistantText(page, "fork-source")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
  }

  const metaUserMsg = page.locator(".message-wrapper").filter({
    has: page.locator(".message.user-message.meta-message", {
      hasText: "fork-source",
    }),
  });
  await expect(metaUserMsg).toHaveCount(0);

  const userMsg = page.locator(".message-wrapper").filter({
    has: page.locator(
      ".message.user-message:not(.meta-message):not(.system-user-message):not(.pending)",
      { hasText: "fork-source" },
    ),
  });
  await expect(userMsg).toHaveCount(1);
  await expect(async () => {
    const targetUsers = frames.filter(
      (frame) =>
        frame?.type !== "task_history_boundary_replaced" &&
        frame?.event?.type === "item/started" &&
        frame?.event?.item_type === "user_message" &&
        !frame?.event?.is_meta &&
        !frame?.event?.is_synthetic &&
        !frame?.event?.pending &&
        !frame?.event?.history_boundary &&
        frame?.event?.content?.[0]?.text === targetPrompt,
    );
    expect(targetUsers).toHaveLength(1);
    const target = targetUsers[0];
    const targetReplacements = frames.filter(
      (frame) =>
        frame?.type === "task_history_boundary_replaced" &&
        frame?.seq === target.seq &&
        frame?.event?.history_boundary?.kind === "user",
    );
    expect(targetReplacements).toHaveLength(1);
    expect(
      frames
        .slice(postReloadFrameStart)
        .some(
          (frame) =>
            frame?.type === "history_operations" &&
            frame?.history_operations?.fork?.user ===
              (agentType === "codex" ? undefined : "jsonl"),
        ),
    ).toBe(true);
  }).toPass();
  await userMsg.hover();
  const forkBtn = userMsg.locator(".fork-btn");
  if (agentType === "codex") {
    await expect(forkBtn).toHaveCount(0);
    return;
  }
  await expect(forkBtn).toBeVisible();

  await forkBtn.click();

  const forkEntry = page.locator(".sidebar-item .sidebar-label", {
    hasText: "(fork)",
  });
  await expect(forkEntry).toBeVisible();

  const forkSidebarItem = page.locator(".sidebar-item.active", {
    hasText: "(fork)",
  });
  await expect(forkSidebarItem).toBeVisible();

  // Use :visible to avoid strict mode violation from multiple resume buttons (codex sessions)
  await expect(
    page.locator(".btn-banner-resume:visible").first(),
  ).toBeVisible();
});

test("assistant messages do not render literal undefined", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');
  await expect(assistantText(page, "hello")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  // Ensure no text block renders literal "undefined"
  const undefinedBlocks = page.locator(".text-content", {
    hasText: /^undefined$/,
  });
  await expect(undefinedBlocks).toHaveCount(0);
});
