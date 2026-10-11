import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  lastAssistantText,
  responseTimeout,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

const CLAUDE_SETTINGS = "/tmp/claude-test-home/settings.json";
const HOOK_MARKER = "context-hook-marker";

/** the attachment categories in a transcript, in file order */
function transcriptCategories(path: string): string[] {
  // the CLI creates the file with its first write; until then there is
  // nothing to compare against
  if (!existsSync(path)) return [];
  return readHistoryFile(path)
    .split("\n")
    .filter((line) => line.includes('"type":"attachment"'))
    .map((line) => JSON.parse(line) as { attachment?: { type?: string } })
    .map((record) => record.attachment?.type ?? "")
    .filter((category) => category && category !== "queued_command");
}

// the context claude code writes into its transcript around a turn (date,
// environment, tool listings, ...) shows up as labeled context blocks: live
// through the transcript tail, and the same records again after a reload,
// replayed from the transcript

/** a prompt hook, like one that stamps the time on the user's own prompts,
 *  guarantees at least one hook_success record per prompt */
function installPromptHook() {
  const settings = existsSync(CLAUDE_SETTINGS)
    ? (JSON.parse(readFileSync(CLAUDE_SETTINGS, "utf8")) as Record<
        string,
        unknown
      >)
    : {};
  settings.hooks = {
    ...((settings.hooks as Record<string, unknown>) ?? {}),
    UserPromptSubmit: [
      { hooks: [{ type: "command", command: `echo ${HOOK_MARKER}` }] },
    ],
  };
  writeFileSync(CLAUDE_SETTINGS, JSON.stringify(settings));
}

async function contextRecords(page: import("@playwright/test").Page) {
  return page.locator(".context-attachment").evaluateAll((els) =>
    els.map((el) => ({
      category: el.getAttribute("data-category"),
      inUserMessage: !!el.closest(".user-message"),
      inAssistantMessage: !!el.closest(".assistant-message"),
    })),
  );
}

test(
  "context attachments render live and again after a reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    installPromptHook();

    await enterSession(page);
    await sendMessage(page, 'Please reply with "OK"');
    await expect(lastAssistantText(page, "OK")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const historyPath = historyPathForTask(currentTaskTid(page));
    await expect
      .poll(() => transcriptCategories(historyPath))
      .toContain("hook_success");
    const written = transcriptCategories(historyPath);
    console.log(`transcript context categories: ${written.join(", ")}`);

    // the tail delivers them shortly after the transcript is written
    await expect
      .poll(async () => (await contextRecords(page)).map((r) => r.category), {
        timeout: responseTimeout(agentType),
      })
      .toEqual(written);
    const live = await contextRecords(page);
    const hook = page.locator(
      '.context-attachment[data-category="hook_success"]',
    );
    await expect(hook.locator(".context-attachment-preview")).toHaveText(
      HOOK_MARKER,
    );
    expect(live.find((r) => r.category === "hook_success")!.inUserMessage).toBe(
      true,
    );
    for (const record of live) {
      expect(record.category).toBeTruthy();
      expect(record.inAssistantMessage).toBe(false);
    }
    const summary = page.locator(".context-attachment-summary").first();
    await expect(summary.locator(".context-attachment-category")).toHaveText(
      live[0]!.category!,
    );

    // the body renders on demand
    await summary.click();
    await expect(
      page
        .locator(".context-attachment[open] .context-attachment-body")
        .first(),
    ).toBeVisible();

    await page.reload();
    await expect(lastAssistantText(page, "OK")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(page.locator(".context-attachment").first()).toBeVisible();
    const replayed = await contextRecords(page);
    // the same records, each in the same place: a prompt's context on the
    // prompt, mid-turn context in synthetic blocks
    expect(replayed).toEqual(live);

    // a plain prompt sent from the page: its context arrives through the
    // tail around the agent's echo of it, and still lands on it
    await sendMessage(page, 'Please reply with "TWO"');
    await expect(lastAssistantText(page, "TWO")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    // both sides re-read on every attempt: the transcript gains the second
    // prompt's records around the same time the page does
    await expect
      .poll(
        async () => {
          const written = transcriptCategories(historyPath);
          const rendered = (await contextRecords(page)).map((r) => r.category);
          return {
            grew: written.length > live.length,
            matches: JSON.stringify(rendered) === JSON.stringify(written),
          };
        },
        { timeout: responseTimeout(agentType) },
      )
      .toEqual({ grew: true, matches: true });
    const liveAfterSecond = await contextRecords(page);
    expect(
      liveAfterSecond.slice(live.length).every((r) => r.inUserMessage),
    ).toBe(true);
    await page.reload();
    await expect(lastAssistantText(page, "TWO")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect
      .poll(async () => contextRecords(page))
      .toEqual(liveAfterSecond);
  },
);

test(
  "the ui config hides context categories, live",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    installPromptHook();
    const configPath = "/tmp/playwright-home/.config/cydo/config.yaml";
    const config = `workspaces:
  local:
    root: /tmp/cydo-test-workspace
`;

    await enterSession(page);
    await sendMessage(page, 'Please reply with "OK"');
    await expect(lastAssistantText(page, "OK")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const hook = page.locator(
      '.context-attachment[data-category="hook_success"]',
    );
    await expect(hook).toHaveCount(1, { timeout: responseTimeout(agentType) });

    // a config reload re-sends server_status, and the page re-renders
    // without replaying anything
    writeTestConfig(
      configPath,
      config + "ui:\n  context:\n    hidden_categories: [hook_success]\n",
    );
    await expect(hook).toHaveCount(0, { timeout: responseTimeout(agentType) });

    writeTestConfig(configPath, config);
    await expect(hook).toHaveCount(1, { timeout: responseTimeout(agentType) });
  },
);
