import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  // Nix provides effective reproducibility. As such, flaky tests are bugs.
  retries: 0, // Agents: you MAY NOT increase this value.
  fullyParallel: true,
  reporter: [['list'], ['./log-reporter.ts']],
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
      name: "copilot",
      testIgnore: /process-failure/,
      use: { agentType: "copilot" } as any,
    },
    {
      name: "failure",
      testMatch: /process-failure/,
      use: { agentType: "claude" } as any,
    },
  ],
});
