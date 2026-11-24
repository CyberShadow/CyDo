import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  killSession,
  responseTimeout,
} from "./fixtures";

test(
  "Codex preserves the boundary between reasoning summary entries",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await enterSession(page);
    await sendMessage(page, "codex reasoning summary fixture");

    const done = assistantText(page, "reasoning-summary-fixture-done");
    const reasoning = page.locator(".thinking-block");
    const paragraphs = reasoning.locator(".thinking-text p");
    const summary = [
      "Planning detailed gate reporting",
      "Evaluating test execution via Nix flake",
    ];
    const timeout = responseTimeout(agentType);

    await test.step("streaming summary", async () => {
      await expect(paragraphs).toHaveText(summary, { timeout });
      await expect(done).toHaveCount(0);
    });

    await test.step("completed summary", async () => {
      await expect(done).toHaveCount(1, { timeout });
      await expect(reasoning).toHaveCount(1);
      await expect(paragraphs).toHaveText(summary);
    });

    await test.step("reloaded turn", async () => {
      await killSession(page, agentType);
      await page.reload();
      await expect(done).toHaveCount(1, { timeout });
      await expect(reasoning).toHaveCount(1);
      await expect(paragraphs).toHaveText(summary);
    });
  },
);
