import { test, expect } from "./fixtures";

test.use({
  backendEnv: {
    CYDO_AUTH_USER: "user",
    CYDO_AUTH_PASS: "test-pass",
  },
  httpCredentials: {
    username: "user",
    password: "test-pass",
  },
});

test("auth-enabled startup handles empty notices list", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  await page.goto("/");
  await expect(page.locator('button[title="New task"]').first()).toBeVisible({
    timeout: 15_000,
  });
});
