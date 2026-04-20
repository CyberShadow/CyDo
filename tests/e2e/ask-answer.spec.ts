import { test, expect, enterSession, sendMessage } from "./fixtures";

// All ask/answer tests require launching sub-tasks which takes more time.
const TALK_TIMEOUT = 120_000;

test("Ask/Answer: follow-up to completed sub-task", async ({ page, agentType }) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Create a sub-task that completes normally.
  await sendMessage(page, 'call task research reply with "initial-result"');

  // Wait for the sub-task result to appear (marker text from sub-task).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("initial-result", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for the parent's turn to complete (mock responds "Done." after seeing
  // the Task tool result). This ensures the session is in "alive" state before
  // sending the follow-up, avoiding a race where suggestions render mid-turn
  // and destabilize the send button layout.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Parent calls Ask on the completed child (tid=2) with a follow-up question.
  await sendMessage(page, "call ask 2 any follow-up?");

  // The child is resumed, receives "[Follow-up question from parent task (qid=1)]",
  // and responds with Answer(1, "follow-up-answered"). That answer is returned as the Ask result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("follow-up-answered", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: child asks parent, parent answers", async ({ page, agentType }) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Create a sub-task that calls Ask(question) with no tid (asks parent).
  // The parent's Task call returns with the question.
  // The mock sees "[SYSTEM:" in parent's turn-complete and returns "Done."
  // Parent stays alive (interactive) and waits.
  await sendMessage(
    page,
    "call task research call ask what approach should I use?",
  );

  // Wait for the child (tid=2) to appear in the sidebar (confirms auto-focus happened),
  // then navigate back to the parent (tid=1) to see the Task result with the question.
  await page.locator('.sidebar-item[data-tid="2"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator('.sidebar-item[data-tid="1"]').click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible({
    timeout: 10_000,
  });

  // Wait for question to appear in parent's Task tool result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("what approach should I use?")
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for parent's Turn 2 to complete (mock responds "Done." after seeing the
  // Task result with the question). This prevents a race where the Answer
  // arrives before Turn 2 finishes processing the Task result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Parent answers via Answer(qid=1, answer). First qid is always 1 in fresh session.
  await sendMessage(page, "call answer 1 use approach A");

  // The child receives the answer, responds "Done." (isToolResult → mock), and exits.
  // Parent's Answer call returns with the batch completion result.
  await expect(
    page
      .locator(
        '[style*="display: contents"] .message-list .tool-result, [style*="display: contents"] .message-list .cydo-task-spec',
      )
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: batch with one completing child and one asking child", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // "call mixed batch research" spawns two children:
  //   - child A: replies with "normal-child-done" (completes normally)
  //   - child B: calls Ask("what approach should I use?") (asks parent)
  // createTasks returns early with child B's question.
  await sendMessage(page, "call mixed batch research");

  // Wait for child B's question to appear in parent's result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("what approach should I use?")
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Parent answers child B using qid=1 (first question allocated in fresh session).
  await sendMessage(page, "call answer 1 use approach A");

  // After child B completes, Answer returns with the full batch results
  // (both child A's "normal-child-done" and child B's final result).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("normal-child-done")
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: invalid Ask target returns error", async ({ page, agentType }) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Ask a nonexistent tid — should return an error.
  await sendMessage(page, "call ask 999 hello");

  // The error message should include "not found".
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(/not found/i)
      .last(),
  ).toBeVisible({ timeout: 60_000 });
});

test("Ask/Answer: tid field present in Task results", async ({ page, agentType }) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Create a sub-task that completes with a known result.
  await sendMessage(page, 'call task research reply with "check-tid"');

  // Wait for the result to appear.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("check-tid", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // The tid field should be visible in the tool result display.
  // The task result item renders remaining fields (after summary/error) as key: value.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list .cydo-task-spec')
      .getByText(/tid/)
      .last(),
  ).toBeVisible({ timeout: 10_000 });
});

test("Ask/Answer: two children asking simultaneously are queued", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Create two sub-tasks that both call Ask(question) with no tid (ask parent).
  // The parent's Task call returns early with the first child's question.
  // The second question is queued and delivered after the first is answered.
  await sendMessage(page, "call 2 tasks research call ask what approach?");

  // Wait for both children to appear in the sidebar (confirms auto-focus to tid=2
  // has settled), then navigate back to the parent (tid=1) to see the Task result.
  await page.locator('.sidebar-item[data-tid="3"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator('.sidebar-item[data-tid="1"]').click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible({
    timeout: 10_000,
  });

  // Wait for the first question to appear in parent's Task tool result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("what approach?")
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for parent's Turn 2 to complete (mock returns "Done." for the Task result).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Answer the first child (qid=1 — first question allocated in fresh session).
  await sendMessage(page, "call answer 1 answer one");

  // The second question (from the other child) should now be delivered as the Answer result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("what approach?")
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for Turn 3 to complete before answering the second question.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Answer the second child (qid=2 — second question allocated in fresh session).
  await sendMessage(page, "call answer 2 answer two");

  // Both children complete → Task returns with batch results (cydo-task-spec items).
  await expect(
    page
      .locator(
        '[style*="display: contents"] .message-list .tool-result, [style*="display: contents"] .message-list .cydo-task-spec',
      )
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: Ask to active sub-task delivers follow-up message", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // "call active-child-test" creates:
  //   - child tid=2: stalls (LLM connection kept open)
  //   - child tid=3: calls Ask("am I doing this right?") asking parent
  await sendMessage(page, "call active-child-test");

  // The UI auto-focuses to tid=2 (the stalling child, created first).
  // Since tid=2 never completes, the UI never auto-returns to the parent.
  // Wait for both children to appear in the sidebar (confirming they were
  // created and the auto-focus to tid=2 has settled), then navigate to tid=1.
  await page.locator('.sidebar-item[data-tid="3"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator('.sidebar-item[data-tid="1"]').click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible({
    timeout: 10_000,
  });

  // Wait for child 3's question to appear in the parent's Task tool result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("am I doing this right?")
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for the parent's Turn 2 to complete: after the Task result with the
  // question is delivered, the mock responds "Done." which the parent outputs
  // as assistant text. This ensures Turn 2 is complete before we send a new
  // user message (otherwise it would race with the task result delivery).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Parent asks the stalling (active) child tid=2 with a follow-up.
  // This should succeed now — asking an active child is allowed.
  // The old behavior would return "Cannot Ask active sub-task" error.
  await sendMessage(page, "call ask 2 hey are you done?");

  // Verify success: the parent enters "waiting" state (yellow dot in sidebar).
  // This means Ask was accepted and the parent is blocking on the batch loop.
  // The old behavior would have returned an error immediately without changing state.
  await expect(
    page.locator('.sidebar-item[data-tid="1"] .task-type-icon.waiting'),
  ).toBeVisible({ timeout: 60_000 });
});

test("Ask/Answer: Ask to busy (waiting) sub-task returns error", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // "call busy-child-test" creates two children:
  //   - child A (tid=2): creates grandchild (tid=4) that stalls → becomes "waiting"
  //   - child B (tid=3): asks parent → makes parent's Task return early with a question
  // Tids: 1=parent, 2=child A, 3=child B, 4=grandchild (created by child A).
  await sendMessage(page, "call busy-child-test");

  // Wait for grandchild (tid=4) to appear in sidebar — confirms child A (tid=2) has
  // created its sub-task and entered "waiting" status.
  await page.locator('.sidebar-item[data-tid="4"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });

  // Navigate to parent (tid=1) which should have the Task result.
  await page.locator('.sidebar-item[data-tid="1"]').click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible({
    timeout: 10_000,
  });

  // Wait for the parent's turn to finish (mock responds "Done." after task result).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Parent tries to Ask the busy (waiting) child tid=2.
  await sendMessage(page, "call ask 2 hey are you done?");

  // Backend should return an error because child 2 is busy (waiting on grandchild).
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(/busy sub-task/i)
      .last(),
  ).toBeVisible({ timeout: 60_000 });
});

test("Ask/Answer: yield enforcement steers parent with unanswered child question", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT * 2);

  await enterSession(page);

  // Grandparent (tid=1) creates parent (tid=2) which creates child (tid=3).
  // Child (tid=3) calls Ask with no tid → asks parent (tid=2).
  // Parent (tid=2) is non-interactive: mock sees "[SYSTEM:" → returns "Done." and
  // tries to yield (close stdin). Yield enforcement detects the unanswered question
  // and sends a steering message instead of closing stdin.
  await sendMessage(
    page,
    "call task research call task research call ask what approach?",
  );

  // Wait for tid=3 to appear in the sidebar, confirming that the auto-focus
  // chain (1→2→3) has settled. Without this wait the test would click tid=2
  // while tid=2 is still creating tid=3, causing auto-focus to jump to tid=3
  // immediately after and leaving `[style*="display: contents"]` matching
  // tid=3's container instead of tid=2's.
  await page.locator('.sidebar-item[data-tid="3"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });

  // Navigate to the parent task (tid=2) to see its message list.
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(page.locator('.sidebar-item[data-tid="2"].active')).toBeVisible({
    timeout: 10_000,
  });

  // Yield enforcement sends a system message with label "Sub-task waiting for answer"
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(/sub-task waiting for answer/i)
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: Answer with invalid qid returns error", async ({ page, agentType }) => {
  test.setTimeout(TALK_TIMEOUT);
  await enterSession(page);
  await sendMessage(page, "call answer 999 hello");
  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText(/unknown question/i).last(),
  ).toBeVisible({ timeout: 60_000 });
});
