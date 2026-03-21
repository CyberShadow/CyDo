import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  retries: 3,
  fullyParallel: true,
  use: {
    headless: true,
    screenshot: "on",
    launchOptions: {
      executablePath:
        process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined,
    },
  },
  projects: [
    {
      name: "claude",
      testIgnore: /process-failure/,
      use: { agentType: "claude" } as any,
    },
    {
      name: "codex",
      testIgnore: /process-failure/,
      use: { agentType: "codex" } as any,
    },
    {
      name: "failure",
      testMatch: /process-failure/,
      use: { agentType: "claude" } as any,
    },
  ],
});
