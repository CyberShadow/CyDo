import { test, expect, enterSession, sendMessage } from "./fixtures";
import type { Locator, Page } from "@playwright/test";

// All ask/answer tests require launching sub-tasks which takes more time.
const TALK_TIMEOUT = 120_000;

type TaskResultItem = Record<string, unknown>;
type ItemResultEventLike = {
  type?: string;
  tool_result?: unknown;
  content?: unknown;
};

function currentMessageList(page: Page): Locator {
  return page.locator('[style*="display: contents"] .message-list');
}

function lastTaskTool(page: Page): Locator {
  return currentMessageList(page)
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".tool-call", {
        has: page.locator(".tool-name", { hasText: "Task" }),
      }),
    })
    .last();
}

function parseTaskResultItemsPayload(payload: unknown): TaskResultItem[] | null {
  if (Array.isArray(payload)) return payload as TaskResultItem[];
  if (payload && typeof payload === "object") {
    const obj = payload as Record<string, unknown>;
    if (obj.structuredContent !== undefined) {
      const structured = parseTaskResultItemsPayload(obj.structuredContent);
      if (structured) return structured;
    }
    if (Array.isArray(obj.tasks)) return obj.tasks as TaskResultItem[];
    return [obj];
  }
  return null;
}

function parseTaskResultItems(event: ItemResultEventLike): TaskResultItem[] | null {
  const structured = parseTaskResultItemsPayload(event.tool_result);
  if (structured) return structured;

  const content = event.content;
  const text =
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content
            .filter(
              (block): block is { type: string; text: string } =>
                typeof block === "object" &&
                block !== null &&
                (block as { type?: unknown }).type === "text" &&
                typeof (block as { text?: unknown }).text === "string",
            )
            .map((block) => block.text)
            .join("")
        : null;
  if (!text) return null;

  try {
    return parseTaskResultItemsPayload(JSON.parse(text) as unknown);
  } catch {
    // Ignore non-JSON tool result text.
  }
  return null;
}

function observeTaskResultEvents(page: Page, tid = 1): ItemResultEventLike[] {
  const taskEvents: ItemResultEventLike[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const data = JSON.parse(frame.payload.toString()) as {
          tid?: number;
          event?: ItemResultEventLike;
        };
        if (data.tid === tid && data.event?.type === "item/result") {
          taskEvents.push(data.event);
        }
      } catch {
        // Ignore non-JSON frames and unrelated events.
      }
    });
  });
  return taskEvents;
}

function observeTaskResultItems(page: Page, tid = 1): TaskResultItem[][] {
  const taskResults: TaskResultItem[][] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const data = JSON.parse(frame.payload.toString()) as {
          tid?: number;
          event?: ItemResultEventLike;
        };
        if (data.tid === tid && data.event?.type === "item/result") {
          const items = parseTaskResultItems(data.event);
          if (items) taskResults.push(items);
        }
      } catch {
        // Ignore non-JSON frames and unrelated events.
      }
    });
  });
  return taskResults;
}

async function waitForLatestTaskResultItems(
  observed: TaskResultItem[][],
): Promise<TaskResultItem[]> {
  await expect.poll(() => observed.length).toBeGreaterThan(0);
  return observed[observed.length - 1]!;
}

async function waitForLatestTaskResultEvent(
  observed: ItemResultEventLike[],
): Promise<ItemResultEventLike> {
  await expect.poll(() => observed.length).toBeGreaterThan(0);
  return observed[observed.length - 1]!;
}

test("Ask/Answer: follow-up to completed sub-task", async ({
  page,
  agentType,
}) => {
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

  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(page.locator('.sidebar-item[data-tid="2"].active')).toBeVisible({
    timeout: 10_000,
  });
  const followUpMessage = page.locator(
    '[style*="display: contents"] .message-list .message.user-message.system-user-message',
    { hasText: "Follow-up from parent" },
  ).last();
  await expect(followUpMessage).toBeVisible({ timeout: 30_000 });
  await expect(followUpMessage.locator(".system-user-body").first()).toContainText(
    "any follow-up?",
  );
  const followUpDetails = followUpMessage.locator("details.system-user-full-text").first();
  await expect(followUpDetails).toBeAttached();
  await expect(followUpDetails).not.toHaveAttribute("open");

  await page.reload();
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(page.locator('.sidebar-item[data-tid="2"].active')).toBeVisible({
    timeout: 10_000,
  });
  const followUpMessageAfterReload = page.locator(
    '[style*="display: contents"] .message-list .message.user-message.system-user-message',
    { hasText: "Follow-up from parent" },
  ).last();
  await expect(followUpMessageAfterReload).toBeVisible({ timeout: 30_000 });
  await expect(
    followUpMessageAfterReload.locator(".system-user-body").first(),
  ).toContainText("any follow-up?");
  const followUpDetailsAfterReload = followUpMessageAfterReload
    .locator("details.system-user-full-text")
    .first();
  await expect(followUpDetailsAfterReload).toBeAttached();
  await expect(followUpDetailsAfterReload).not.toHaveAttribute("open");
});

test("Ask/Answer: child asks parent, parent answers", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  const observedTaskResults = observeTaskResultItems(page);

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

  const questionResult = (await waitForLatestTaskResultItems(observedTaskResults))[0]!;
  expect(questionResult).toMatchObject({
    status: "question",
    tid: 2,
    message: "what approach should I use?",
  });
  const capturedQid = questionResult["qid"] as number;

  // Wait for parent's Turn 2 to complete (mock responds "Done." after seeing the
  // Task result with the question). This prevents a race where the Answer
  // arrives before Turn 2 finishes processing the Task result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Parent answers the pending question using the observed qid.
  await sendMessage(page, `call answer ${capturedQid} use approach A`);

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

test("Ask/Answer: completed task result exposes success status and preserved fields", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  const observedTaskResults = observeTaskResultItems(page);
  const observedTaskEvents = observeTaskResultEvents(page);

  await enterSession(page);
  await sendMessage(page, 'call task research reply with "structured-success"');

  const taskTool = lastTaskTool(page);
  await expect(taskTool).toContainText("structured-success", {
    timeout: 90_000,
  });

  expect((await waitForLatestTaskResultItems(observedTaskResults))[0]).toMatchObject(
    {
      status: "success",
      tid: 2,
      summary: "structured-success",
      note: "Read the output file for findings.",
    },
  );
  if (agentType === "codex") {
    expect(
      parseTaskResultItems(await waitForLatestTaskResultEvent(observedTaskEvents)),
    ).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          status: "success",
          tid: 2,
          summary: "structured-success",
        }),
      ]),
    );
  }
});

test("Ask/Answer: task validation errors expose error status and error field", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  const observedTaskResults = observeTaskResultItems(page);

  await enterSession(page);
  await sendMessage(page, "call task invalid_type reproduce the bug");

  const taskTool = lastTaskTool(page);
  await expect(taskTool).toContainText(/not in creatable_tasks/i, {
    timeout: 90_000,
  });

  expect((await waitForLatestTaskResultItems(observedTaskResults))[0]).toMatchObject(
    {
      status: "error",
      error: expect.stringContaining("invalid_type"),
    },
  );
});

test("Ask/Answer: task summaries preserve literal JSON-looking child final text", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  const observedTaskResults = observeTaskResultItems(page);

  await enterSession(page);
  await sendMessage(page, "call task research reply with json-summary-fixture");

  const taskTool = lastTaskTool(page);
  await expect(taskTool).toContainText("qid", { timeout: 90_000 });
  expect((await waitForLatestTaskResultItems(observedTaskResults))[0]).toMatchObject(
    {
      status: "success",
      tid: 2,
      summary: '{"qid":3,"message":"**Summary**\\n\\nHello"}',
    },
  );
});

test("Ask/Answer: batch with one completing child and one asking child", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  const observedTaskResults = observeTaskResultItems(page);

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

  // Wait for the parent's turn to complete after returning the question.
  // Sending Answer while this turn is still finalizing can race and skip
  // the expected batch-result shape.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Capture the qid from child B's observed question result.
  const questionResult = (await waitForLatestTaskResultItems(observedTaskResults)).find(
    (item) => item["status"] === "question",
  )!;
  const capturedQid = questionResult["qid"] as number;

  // Parent answers child B using the observed qid.
  await sendMessage(page, `call answer ${capturedQid} use approach A`);

  // After child B completes, Answer returns with the full batch results
  // in original request order (Normal child, then Questioning child).
  const finalSpecs = page
    .locator(
      '[style*="display: contents"] .message-list .tool-result-container',
    )
    .last()
    .locator(".cydo-task-spec");
  await expect(finalSpecs).toHaveCount(2, { timeout: 90_000 });
  await expect(finalSpecs.nth(0)).toContainText("tid: 2");
  await expect(finalSpecs.nth(0)).toContainText("normal-child-done");
  await expect(finalSpecs.nth(1)).toContainText("tid: 3");
});

test("Ask/Answer: invalid Ask target returns error", async ({
  page,
  agentType,
}) => {
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

test("Ask/Answer: tid field present in Task results", async ({
  page,
  agentType,
}) => {
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

  const observedTaskResults = observeTaskResultItems(page);

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

  // Capture qid of the first question from the observed task result.
  const firstQuestion = (await waitForLatestTaskResultItems(observedTaskResults)).find(
    (item) => item["status"] === "question",
  )!;
  const firstQid = firstQuestion["qid"] as number;

  // Answer the first child using the observed qid.
  await sendMessage(page, `call answer ${firstQid} answer one`);

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

  // Capture qid of the second question (latest item/result after answering the first).
  await expect.poll(() => observedTaskResults.length).toBeGreaterThanOrEqual(2);
  const secondQuestion = observedTaskResults[observedTaskResults.length - 1]!.find(
    (item) => item["status"] === "question",
  )!;
  const secondQid = secondQuestion["qid"] as number;

  // Answer the second child using the observed qid.
  await sendMessage(page, `call answer ${secondQid} answer two`);

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

test("Ask/Answer: Ask to busy (waiting) sub-task is enqueued", async ({
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

  // Parent asks the busy (waiting) child tid=2.
  await sendMessage(page, "call ask 2 hey are you done?");

  // Ask is enqueued — parent enters "waiting" state (no error returned).
  await expect(
    page.locator('.sidebar-item[data-tid="1"] .task-type-icon.waiting'),
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

  await page.reload();
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(/sub-task waiting for answer/i)
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: answer delivery is deferred until child becomes idle", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  await enterSession(page);

  // Create a child that completes normally.
  await sendMessage(page, 'call task research reply with "initial-result"');
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("initial-result", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Ask follow-up with "deferred-test" trigger — child will Answer + do extra Bash work.
  await sendMessage(page, "call ask 2 deferred-test");

  // Parent should receive the answer after the child's full turn completes.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("deferred-answer-result", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: Answer with invalid qid returns error", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);
  await enterSession(page);
  await sendMessage(page, "call answer 999 hello");
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(/unknown question/i)
      .last(),
  ).toBeVisible({ timeout: 60_000 });
});

test("Ask/Answer: SwitchMode preserves unanswered child question", async ({
  page,
  agentType,
}) => {
  // Claude-specific: only the Anthropic mock can reliably return SwitchMode
  // after a Task tool result in a deterministic sequence.
  test.skip(agentType !== "claude", "Claude-only: Anthropic-specific tool-result sequencing");
  test.setTimeout(TALK_TIMEOUT * 2);

  await enterSession(page);

  // "switchmode after child asks" creates a research child that calls Ask.
  // When the parent receives the Task result (child question), the mock returns SwitchMode(plan).
  // The backend must allow the mode switch and send a Sub-task waiting for answer reminder
  // in the new mode. The new mode then answers with Answer(qid, switch-mode-answer).
  await sendMessage(page, "switchmode after child asks");

  // Wait for the SwitchMode tool call to appear in parent's message list.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list .tool-name', {
        hasText: "SwitchMode",
      })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for the mode-switch system message divider.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list .system-user-message', {
        hasText: /Mode switch: plan/i,
      })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // The resumed plan_mode receives the Sub-task waiting reminder and calls Answer.
  // Wait for the Answer tool call to appear — confirms the fix is working.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list .tool-name', {
        hasText: "Answer",
      })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for the child task (tid=2) to show as completed in the sidebar.
  // Research sub-tasks are resumable after completion, so accept either status class.
  await expect(
    page.locator(
      '.sidebar-item[data-tid="2"] .task-type-icon.completed, .sidebar-item[data-tid="2"] .task-type-icon.resumable',
    ),
  ).toBeVisible({ timeout: 60_000 });

  // Wait for the final Task tool result (batch completed) to appear in the parent.
  await expect(
    page
      .locator(
        '[style*="display: contents"] .message-list .cydo-task-spec',
      )
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});

test("Ask/Answer: Handoff rejected while child question is pending", async ({
  page,
  agentType,
}) => {
  // Claude-specific: only the Anthropic mock can reliably return Handoff then Answer
  // after a Task tool result in a deterministic multi-step sequence.
  test.skip(agentType !== "claude", "Claude-only: Anthropic-specific tool-result sequencing");
  test.setTimeout(TALK_TIMEOUT * 2);

  await enterSession(page);

  // Create a test_handoff_with_children sub-task whose prompt is "handoff while child asks".
  // The sub-task (tid=2) creates a research grandchild (tid=3) that calls Ask.
  // When tid=2 receives the Task result with the pending question, the mock calls Handoff.
  // The backend must reject Handoff with a recoverable error and NOT create a continuation.
  // The mock then answers the pending question, which lets the grandchild complete.
  await sendMessage(
    page,
    "call task test_handoff_with_children handoff while child asks",
  );

  // Wait for the grandchild (tid=3) to appear in the sidebar.
  await page.locator('.sidebar-item[data-tid="3"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });

  // No continuation (tid=4) should be created — Handoff must be rejected.
  // Check immediately: if the backend incorrectly accepted Handoff, tid=4 would
  // appear quickly. Use not.toBeVisible() with a short timeout so the test
  // doesn't wait 90 seconds for something that should never appear.
  await expect(
    page.locator('.sidebar-item[data-tid="4"]'),
  ).not.toBeVisible();

  // After the Handoff rejection, the mock calls Answer which fulfills the
  // grandchild's Ask. Wait for tid=3 to complete: this proves the recovery
  // path worked (Handoff rejected → child answered the pending question).
  // Research sub-tasks are resumable after completion, so accept either status class.
  await expect(
    page.locator(
      '.sidebar-item[data-tid="3"] .task-type-icon.completed, .sidebar-item[data-tid="3"] .task-type-icon.resumable',
    ),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for the child task (tid=2) to complete — confirms it recovered fully.
  await expect(
    page.locator(
      '.sidebar-item[data-tid="2"] .task-type-icon.completed, .sidebar-item[data-tid="2"] .task-type-icon.resumable',
    ),
  ).toBeVisible({ timeout: 60_000 });
});
