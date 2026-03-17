import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  retries: 1,
  fullyParallel: true,
  workers: 4,
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
      use: { agentType: "claude" } as any,
    },
    {
      name: "codex",
      use: { agentType: "codex" } as any,
    },
  ],
});
