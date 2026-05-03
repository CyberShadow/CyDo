import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";
import type { Page } from "./fixtures";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "fs";

const MEMORY_DIR = "/tmp/cydo-test-workspace/.cydo/memory";
const MEMORY_FILE = `${MEMORY_DIR}/MEMORY.md`;

function setupMemory(contents: string) {
  mkdirSync(MEMORY_DIR, { recursive: true });
  writeFileSync(MEMORY_FILE, contents);
}

function cleanupMemory() {
  if (existsSync(MEMORY_DIR)) {
    rmSync(MEMORY_DIR, { recursive: true, force: true });
  }
}

// Helper: expect a sub-task result containing the given text to be visible.
async function expectSubtaskResult(page: Page, text: string, timeout: number) {
  await expect(
    page
      .locator(".tool-result-container .text-content:visible", { hasText: text })
      .first(),
  ).toBeVisible({ timeout });
}

test("project memory is injected into first user message", async ({
  page,
  agentType,
}) => {
  const marker = "CYDO_TEST_PROJECT_MEMORY_MARKER_INJECT";
  setupMemory(`- [Test entry](test.md) — ${marker}\n`);

  try {
    await enterSession(page);

    const encoded = Buffer.from(marker).toString("base64");
    await sendMessage(
      page,
      `call task test_memory_check check context contains ${encoded}`,
    );

    await expectSubtaskResult(page, "context-check-passed", responseTimeout(agentType));
  } finally {
    cleanupMemory();
  }
});

test("project memory marker appears in user message text (not only system prompt)", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "copilot",
    "copilot-proxy does not implement check_user_text; check context contains covers this",
  );

  const marker = "CYDO_TEST_PROJECT_MEMORY_IN_USER_TEXT";
  setupMemory(`- [User text test](user_text.md) — ${marker}\n`);

  try {
    await enterSession(page);

    // check user text contains confirms the marker is in the user message body
    // specifically, not just somewhere in the API request (e.g. system field).
    const encoded = Buffer.from(marker).toString("base64");
    await sendMessage(
      page,
      `call task test_memory_check check user text contains ${encoded}`,
    );

    await expectSubtaskResult(page, "context-check-passed", responseTimeout(agentType));
  } finally {
    cleanupMemory();
  }
});

test("no memory block injected when MEMORY.md absent", async ({
  page,
  agentType,
}) => {
  cleanupMemory();

  await enterSession(page);

  const framingMarker = Buffer.from("[CYDO PROJECT MEMORY]").toString("base64");
  await sendMessage(
    page,
    `call task test_memory_check check context contains ${framingMarker}`,
  );

  await expectSubtaskResult(page, "context-check-failed", responseTimeout(agentType));
});

test("read-only task can write to memory carve-out", async ({
  page,
  agentType,
}) => {
  const markerFile = `${MEMORY_DIR}/test_rw_carveout.md`;
  setupMemory("- [Test](test.md)\n");
  if (existsSync(markerFile)) rmSync(markerFile);

  try {
    await enterSession(page);

    // The sub-task is read_only: true, so writes to the project tree are
    // blocked — but the always_rw carve-out must allow writes to the memory dir.
    await sendMessage(
      page,
      `call task test_memory_check_ro run command touch ${markerFile}`,
    );

    await expectSubtaskResult(page, "Done.", responseTimeout(agentType));
    expect(existsSync(markerFile)).toBe(true);
  } finally {
    if (existsSync(markerFile)) rmSync(markerFile);
    cleanupMemory();
  }
});

test("worktree-bound task writes via absolute path land in canonical store", async ({
  page,
  agentType,
}) => {
  const markerFile = `${MEMORY_DIR}/test_wt_write.md`;
  setupMemory("- [Test](test.md)\n");
  if (existsSync(markerFile)) rmSync(markerFile);

  try {
    await enterSession(page);

    // The worktree task has its main project dir downgraded to ro; only the
    // worktree itself is rw.  The always_rw carve-out must let the absolute
    // path to the canonical memory dir through.
    await sendMessage(
      page,
      `call task test_memory_write_wt run command touch ${markerFile}`,
    );

    await expectSubtaskResult(page, "Done.", responseTimeout(agentType));
    // File must exist in the canonical store, not just in a now-destroyed worktree.
    expect(existsSync(markerFile)).toBe(true);
  } finally {
    if (existsSync(markerFile)) rmSync(markerFile);
    cleanupMemory();
  }
});

test("memory written by one task is visible to the next task", async ({
  page,
  agentType,
}) => {
  const marker = "CYDO_TEST_PROJECT_MEMORY_CROSSTASK";
  setupMemory(`- [Cross-task test](cross.md) — ${marker}\n`);

  try {
    await enterSession(page);

    // Task 1: confirm memory is present
    const encoded = Buffer.from(marker).toString("base64");
    await sendMessage(
      page,
      `call task test_memory_check check context contains ${encoded}`,
    );
    await expectSubtaskResult(page, "context-check-passed", responseTimeout(agentType));

    // Task 2: a second independent sub-task also sees the same memory
    await sendMessage(
      page,
      `call task test_memory_check check context contains ${encoded}`,
    );
    await expect(
      page
        .locator(".tool-result-container .text-content:visible", { hasText: "context-check-passed" })
        .nth(1),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
  } finally {
    cleanupMemory();
  }
});
