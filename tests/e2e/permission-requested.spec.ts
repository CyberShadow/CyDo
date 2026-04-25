import { writeFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("copilot built-in tool with permission auto-approval", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "copilot", "copilot-only test");

  // Create a file for the view tool to read.
  writeFileSync(
    "/tmp/cydo-test-workspace/perm-test.txt",
    "permission-test-content\n",
  );

  await enterSession(page);
  await sendMessage(
    page,
    "use builtin view /tmp/cydo-test-workspace/perm-test.txt",
  );

  // The built-in view tool should execute after permission auto-approval.
  // Verify the tool appears in the UI (tool.execution_start/complete events).
  await expect(page.locator(".tool-name", { hasText: "view" })).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Verify the session completes (assistant responds after tool result).
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});
