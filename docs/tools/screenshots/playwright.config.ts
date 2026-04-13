import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'capture.spec.ts',
  timeout: 120_000,
  retries: 0,
  use: {
    baseURL: `http://${process.env.CYDO_AUTH_USER || 'user'}:${process.env.CYDO_AUTH_PASS || 'screenshot'}@127.0.0.1:${process.env.CYDO_PORT || 3950}`,
    viewport: { width: 1440, height: 900 },
    headless: true,
  },
});
