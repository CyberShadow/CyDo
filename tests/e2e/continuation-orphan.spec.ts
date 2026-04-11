import { test, expect, enterSession, sendMessage } from "./fixtures";

test("SwitchMode with orphaned process completes continuation", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only: Bash tool backgrounding behavior");
  test.setTimeout(30_000);

  // Listen for task_reload broadcast frames to detect continuation completion.
  const reloadEvents: Array<{ tid: number; reason?: string }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_reload") {
          reloadEvents.push({ tid: data.tid, reason: data.reason });
        }
      } catch { /* ignore non-JSON frames */ }
    });
  });

  await enterSession(page);

  // Create a sub-task of type blank. The sub-task's prompt triggers a two-step
  // sequence in the mock API:
  //   1. Bash tool: `sleep 999` with 2s timeout → Claude backgrounds the sleep
  //   2. SwitchMode tool call → backend should process continuation
  //
  // With the bug (commit a60667b), the claude process hangs after SwitchMode
  // because the orphaned `sleep 999` holds stdout open and killAfterTimeout
  // is not called for continuation exits.
  await sendMessage(page, "call task blank run orphan then switchmode");

  // Wait for task_reload with reason "continuation". If the process hangs
  // (the bug), this will time out at 30s.
  await expect(async () => {
    const continuationReload = reloadEvents.find((e) => e.reason === "continuation");
    expect(continuationReload).toBeTruthy();
  }).toPass({ timeout: 25_000 });
});
