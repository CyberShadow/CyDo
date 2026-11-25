import { existsSync, readFileSync } from "node:fs";
import type { AgentType } from "./fixtures";
import {
  test,
  expect,
  enterSession,
  taskPane,
  sendMessage,
  assistantText,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
  responseTimeout,
} from "./fixtures";

type JsonRecord = Record<string, unknown>;
type ResponsesItem = {
  type: string;
  role?: string;
  name?: string;
  namespace?: string;
  call_id?: string;
  output?: unknown;
  content?: Array<{ text?: string }>;
};
type ResponsesRequest = {
  input: ResponsesItem[];
  threadId: string | null;
  userText: string | null;
};

function responsesCapture() {
  const path = process.env.MOCK_OPENAI_CAPTURE;
  if (!path) throw new Error("MOCK_OPENAI_CAPTURE is unset");
  const read = (): ResponsesRequest[] =>
    existsSync(path)
      ? readFileSync(path, "utf8")
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line))
      : [];
  const start = read().length;
  return () => read().slice(start);
}

type ContinuationTool = "SwitchMode" | "Handoff";
type ContinuationReload = {
  tid: number;
  hasExcludedUserUuid: boolean;
  excludedUserUuid: unknown;
};

const rejectedContinuationHistoryFragments = [
  "The user doesn't want to proceed with this tool use",
  "[Request interrupted by user",
  "aborted by user after",
  "<turn_aborted>",
  '"toolDenialKind"',
];

function isJsonRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireJsonRecord(value: unknown, label: string): JsonRecord {
  if (!isJsonRecord(value)) throw new Error(`${label} must be a JSON object`);
  return value;
}

function requireJsonString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`${label} must be a non-empty string`);
  return value;
}

function parseHistoryJsonl(rawHistory: string): JsonRecord[] {
  return rawHistory
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line, index) =>
      requireJsonRecord(JSON.parse(line) as unknown, `JSONL line ${index + 1}`),
    );
}

function exactlyOne<T>(items: T[], label: string): T {
  expect(items, label).toHaveLength(1);
  return items[0]!;
}

function continuationReloadFromFrame(
  frame: JsonRecord,
): ContinuationReload | undefined {
  if (
    frame.type !== "task_reload" ||
    frame.reason !== "continuation" ||
    typeof frame.tid !== "number"
  ) {
    return undefined;
  }
  return {
    tid: frame.tid,
    hasExcludedUserUuid: Object.hasOwn(frame, "excluded_user_uuid"),
    excludedUserUuid: frame.excluded_user_uuid,
  };
}

function assertAcceptedContinuationText(text: string, prefix: string) {
  expect(text.startsWith(prefix), `Expected ${prefix} success text`).toBe(true);
  expect(text).toContain("' accepted.");
}

function assertClaudeContinuationResult(
  rows: JsonRecord[],
  tool: ContinuationTool,
  successPrefix: string,
) {
  const toolUses: JsonRecord[] = [];
  for (const row of rows) {
    if (row.type !== "assistant" || !isJsonRecord(row.message)) continue;
    const content = row.message.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (
        isJsonRecord(block) &&
        block.type === "tool_use" &&
        block.name === `mcp__cydo__${tool}`
      ) {
        toolUses.push(block);
      }
    }
  }

  const toolUse = exactlyOne(toolUses, `Expected one Claude ${tool} tool_use`);
  const toolUseId = requireJsonString(toolUse.id, `Claude ${tool} tool_use id`);
  const toolResults: JsonRecord[] = [];
  for (const row of rows) {
    if (row.type !== "user" || !isJsonRecord(row.message)) continue;
    const content = row.message.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (
        isJsonRecord(block) &&
        block.type === "tool_result" &&
        block.tool_use_id === toolUseId
      ) {
        toolResults.push(block);
      }
    }
  }

  const toolResult = exactlyOne(
    toolResults,
    `Expected one Claude ${tool} tool_result for ${toolUseId}`,
  );
  assertAcceptedContinuationText(
    requireJsonString(toolResult.content, `Claude ${tool} tool result content`),
    successPrefix,
  );
}

function assertCopilotContinuationResult(
  rows: JsonRecord[],
  tool: ContinuationTool,
  successPrefix: string,
) {
  const starts = rows.filter(
    (row) =>
      row.type === "tool.execution_start" &&
      isJsonRecord(row.data) &&
      row.data.toolName === `cydo-${tool}`,
  );
  const start = exactlyOne(
    starts,
    `Expected one Copilot cydo-${tool} tool.execution_start`,
  );
  const startData = requireJsonRecord(start.data, `Copilot ${tool} start data`);
  const toolCallId = requireJsonString(
    startData.toolCallId,
    `Copilot ${tool} tool call id`,
  );
  const completions = rows.filter(
    (row) =>
      row.type === "tool.execution_complete" &&
      isJsonRecord(row.data) &&
      row.data.toolCallId === toolCallId,
  );
  const completion = exactlyOne(
    completions,
    `Expected one Copilot ${tool} tool.execution_complete for ${toolCallId}`,
  );
  const completionData = requireJsonRecord(
    completion.data,
    `Copilot ${tool} completion data`,
  );
  expect(completionData.success).toBe(true);
  const result = requireJsonRecord(
    completionData.result,
    `Copilot ${tool} completion result`,
  );
  const content = requireJsonString(
    result.content,
    `Copilot ${tool} completion result content`,
  );
  assertAcceptedContinuationText(content, successPrefix);
  expect(
    requireJsonString(
      result.detailedContent,
      `Copilot ${tool} completion result detailed content`,
    ),
  ).toBe(content);
}

/// The agents whose history is a file CyDo corrects. Codex keeps its own
/// history: it is told of the accepted call in its conversation instead.
function assertRepairedContinuationHistory(
  agentType: Exclude<AgentType, "codex">,
  rawHistory: string,
  tool: ContinuationTool,
) {
  const rows = parseHistoryJsonl(rawHistory);
  const successPrefix = tool === "SwitchMode" ? "Mode switch to '" : "Handoff to '";

  if (agentType === "claude") {
    assertClaudeContinuationResult(rows, tool, successPrefix);
  } else {
    assertCopilotContinuationResult(rows, tool, successPrefix);
    return;
  }

  for (const fragment of rejectedContinuationHistoryFragments) {
    expect(rawHistory, `Unexpected stale continuation history: ${fragment}`).not.toContain(
      fragment,
    );
  }
}

test("keep_context continuation injects prompt template", async ({
  page,
  agentType,
}) => {
  const captured = agentType === "codex" ? responsesCapture() : null;
  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  // Verify MCP tool call shows correct tool name (not "cydo__SwitchMode" or "unknown").
  // Codex does not keep a tool call its session's end cut short: the call
  // is on screen only until the continuation reloads the history.
  if (agentType !== "codex")
    await expect(
      page.locator(".tool-name", { hasText: "SwitchMode" }),
    ).toBeVisible();

  await expect(
    page.locator(".result-divider.system-user-message", {
      hasText: "Mode switch: plan",
    }),
  ).toBeVisible();

  await expect(
    assistantText(page, "SwitchMode to plan successful."),
  ).toBeVisible();

  if (agentType === "codex") {
    const wrapper = "[SYSTEM: Mode switch:";
    const preface = "`SwitchMode` to `plan` successful.";
    const promptTemplate = "Get the initial draft";
    const first = captured!().find((request) =>
      request.userText?.startsWith(wrapper),
    );
    expect(first, "Expected the first SwitchMode continuation request").toBeDefined();
    const { input } = first!;
    const call = exactlyOne(
      input.filter(
        (item) =>
          item.type === "function_call" &&
          item.namespace === "mcp__cydo" &&
          item.name === "SwitchMode",
      ),
      "Expected one SwitchMode function call",
    );
    expect(call.call_id).toBeTruthy();
    const abort = exactlyOne(
      input.filter(
        (item) =>
          item.type === "function_call_output" && item.call_id === call.call_id,
      ),
      "Expected one native output for the SwitchMode call",
    );
    expect(JSON.stringify(abort.output)).toMatch(/aborted by user/i);
    const correction = input.findIndex(
      (item) =>
        item.type === "message" &&
        item.role === "developer" &&
        item.content?.some(
          (span) =>
            span.text?.includes("Your `SwitchMode` call") &&
            span.text.includes("was accepted and took effect"),
        ),
    );
    const prompt = input.findIndex(
      (item) =>
        item.type === "message" &&
        item.role === "user" &&
        item.content?.some(
          (span) =>
            span.text?.startsWith(wrapper) &&
            span.text.includes(preface) &&
            span.text.includes(promptTemplate),
        ),
    );
    expect(correction, "Expected the developer correction after the native abort")
      .toBeGreaterThan(input.indexOf(abort));
    expect(prompt, "Expected the wrapped continuation prompt after the correction")
      .toBeGreaterThan(correction);
    return;
  }

  assertRepairedContinuationHistory(
    agentType,
    readHistoryFile(historyPathForTask(currentTaskTid(page))),
    "SwitchMode",
  );

  if (agentType !== "copilot") {
    const encodedNeedle = Buffer.from(
      "The user doesn't want to proceed",
    ).toString("base64");
    await sendMessage(page, `check context contains ${encodedNeedle}`);
    await expect(assistantText(page, "context-check-failed")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
  }
});

test("keep_context SwitchMode preface uses continuation key", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  await sendMessage(page, "call switchmode implement");

  await expect(
    page.locator(".result-divider.system-user-message", {
      hasText: "Mode switch: implement",
    }),
  ).toBeVisible();

  await expect(
    assistantText(page, "SwitchMode to implement successful."),
  ).toBeVisible();
});

test("mode switch replay rebuilds known system message metadata", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "call switchmode plan");
  await expect(
    assistantText(page, "SwitchMode to plan successful."),
  ).toBeVisible({ timeout });

  await page.reload();

  await expect(
    page.locator(".result-divider.system-user-message", {
      hasText: "Mode switch: plan",
    }),
  ).toBeVisible({ timeout });
});

test("unsent steer is either recovered into input box or shown in history after kill", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  await sendMessage(page, "run command sleep 20");

  await expect(
    page.locator(".tool-call", { hasText: "sleep 20" }),
  ).toBeVisible();

  await sendMessage(page, "this should be recovered");

  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-banner-resume")).toBeVisible();

  await page.locator(".btn-banner-resume").click();
  await expect(page.locator(".btn-banner-stop")).toBeVisible();

  const input = page.locator(".input-textarea:visible").first();
  const historyMessage = page.locator(".user-message", {
    hasText: "this should be recovered",
  });

  await expect(async () => {
    const inputValue = await input.inputValue();
    const messageVisible = await historyMessage.isVisible();
    expect(inputValue === "this should be recovered" || messageVisible).toBe(
      true,
    );
  }).toPass();
});

test("handoff continuation exit navigates to grandparent, not completed parent", async ({
  page,
  agentType,
}) => {
  const captured = agentType === "codex" ? responsesCapture() : null;
  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid: number;
    relation_type?: string;
  }> = [];
  const liveInterruptionMarkers: Array<{ tid: number; uuid: string }> = [];
  const continuationReloads: ContinuationReload[] = [];
  const taskStatusUpdates: Array<{ tid: number; status: string }> = [];
  const focusHints: Array<{ fromTid: number; toTid: number }> = [];
  const routeTids: Array<number | null> = [];
  page.on("framenavigated", (frame) => {
    if (frame !== page.mainFrame()) return;
    const match = new URL(frame.url()).pathname.match(/\/task\/(\d+)$/);
    const tid = match ? Number(match[1]) : null;
    if (routeTids.at(-1) !== tid) routeTids.push(tid);
  });
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const frame = JSON.parse(event.payload.toString()) as unknown;
        if (!isJsonRecord(frame)) return;
        if (
          frame.type === "task_created" &&
          typeof frame.tid === "number" &&
          typeof frame.parent_tid === "number"
        ) {
          taskCreatedEvents.push({
            tid: frame.tid,
            parent_tid: frame.parent_tid,
            relation_type:
              typeof frame.relation_type === "string"
                ? frame.relation_type
                : undefined,
          });
        } else if (
          frame.type === "task_updated" &&
          isJsonRecord(frame.task) &&
          typeof frame.task.tid === "number" &&
          typeof frame.task.status === "string"
        ) {
          taskStatusUpdates.push({
            tid: frame.task.tid,
            status: frame.task.status,
          });
        } else if (
          frame.type === "focus_hint" &&
          typeof frame.from_tid === "number" &&
          typeof frame.to_tid === "number"
        ) {
          focusHints.push({ fromTid: frame.from_tid, toTid: frame.to_tid });
        }
        const interruptionUuid = interruptedClaudeUserUuid(frame);
        if (interruptionUuid && typeof frame.tid === "number") {
          liveInterruptionMarkers.push({ tid: frame.tid, uuid: interruptionUuid });
        }
        const continuationReload = continuationReloadFromFrame(frame);
        if (continuationReload) continuationReloads.push(continuationReload);
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // Create root task G and enter its session.
  await enterSession(page);

  // G calls Task to create subtask A (type test_handoff).
  // A's prompt is "call handoff done test-prompt" which triggers Handoff immediately.
  // G's fiber blocks waiting for A's result, keeping G alive throughout.
  // The task is created atomically with this first message (activeTaskId === null).
  await sendMessage(
    page,
    "call task test_handoff call handoff done test-prompt",
  );

  const rootTaskTid = () => routeTids.find((tid) => tid !== null);
  await expect
    .poll(rootTaskTid, { message: "G's task route is visited" })
    .toBeDefined();
  const tidG = rootTaskTid()!;
  expect(tidG).toBeGreaterThan(0);

  // task_created is broadcast before A receives the initial prompt that calls
  // Handoff, so retain A's tid before navigation can move to its successor.
  const handingOffTasks = () =>
    taskCreatedEvents.filter(
      (event) =>
        event.relation_type === "subtask" && event.parent_tid === tidG,
    );
  await expect(async () => {
    expect(handingOffTasks()).toHaveLength(1);
  }).toPass();
  const handingOffTid = handingOffTasks()[0]!.tid;

  // Focus hints take the browser from G to A to C, then directly back to G.
  const successorTid = () =>
    taskCreatedEvents.find(
      (task) =>
        task.relation_type === "continuation" &&
        task.parent_tid === handingOffTid,
    )?.tid;
  await expect
    .poll(successorTid, { message: "A's continuation is created" })
    .toBeDefined();
  const tidC = successorTid()!;

  await expect
    .poll(
      () =>
        taskStatusUpdates.some(
          (update) =>
            update.tid === handingOffTid && update.status === "completed",
        ),
      { message: "A is completed" },
    )
    .toBe(true);

  const item = page.locator(`.sidebar-item[data-tid="${tidC}"]`);
  await expect(
    item.locator(".task-type-icon.completed, .task-type-icon.resumable"),
    "C reaches a terminal state",
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect
    .poll(
      () =>
        focusHints.some((hint) => hint.fromTid === tidC && hint.toTid === tidG),
      { message: "C's batch result returns focus to G" },
    )
    .toBe(true);

  await expect
    .poll(
      () => {
        const fromC = routeTids.indexOf(tidC);
        return fromC < 0 ? "C never visited" : routeTids.slice(fromC);
      },
      { message: "route from C" },
    )
    .toEqual([tidC, tidG]);
  await expect(page).toHaveURL(new RegExp(`/task/${tidG}$`));

  await expect
    .poll(
      () => continuationReloads.some((reload) => reload.tid === handingOffTid),
      { message: "A's continuation task_reload is received" },
    )
    .toBe(true);

  if (agentType === "codex") {
    const requests = captured!();
    const source = requests.find(
      (request) =>
        request.userText?.startsWith("[SYSTEM: Task prompt: conversation -> test_handoff]") &&
        request.userText.includes("\n\ncall handoff done test-prompt\n"),
    );
    const successor = requests.find(
      (request) =>
        request.userText?.startsWith("[SYSTEM: Handoff: test_handoff -> done]") &&
        request.userText.includes("\n\ntest-prompt\n"),
    );
    expect(source?.threadId).toBeTruthy();
    expect(successor?.threadId).toBeTruthy();
    expect(successor?.threadId).not.toBe(source?.threadId);
  } else {
    assertRepairedContinuationHistory(
      agentType,
      readHistoryFile(historyPathForTask(handingOffTid)),
      "Handoff",
    );
  }

  const sourceReload = exactlyOne(
    continuationReloads.filter((reload) => reload.tid === handingOffTid),
    "Expected one source-task continuation task_reload",
  );
  if (agentType === "claude") {
    const markerUuid = exactlyOne(
      [
        ...new Set(
          liveInterruptionMarkers
            .filter((marker) => marker.tid === handingOffTid)
            .map((marker) => marker.uuid),
        ),
      ],
      "Expected one live Claude Handoff interruption marker UUID",
    );
    expect(sourceReload.hasExcludedUserUuid).toBe(true);
    expect(sourceReload.excludedUserUuid).toBe(markerUuid);
  } else {
    expect(sourceReload.hasExcludedUserUuid).toBe(false);
    expect(sourceReload.excludedUserUuid).toBeUndefined();
  }
});

test("handoff replay rebuilds known system message metadata", async ({
  page,
  agentType,
}) => {
  const taskCreatedEvents: Array<{ tid: number; relation_type?: string }> = [];
  const returnFocusSources = new Set<number>();
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "focus_hint" && data.to_tid === 1) {
          returnFocusSources.add(data.from_tid);
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(
    page,
    "call task test_handoff call handoff done test-prompt",
  );

  await expect(async () => {
    const continuationTask = taskCreatedEvents.find(
      (e) => e.relation_type === "continuation",
    );
    expect(continuationTask).toBeTruthy();
  }).toPass({ timeout });

  const continuationTid = taskCreatedEvents.find(
    (e) => e.relation_type === "continuation",
  )!.tid;

  await expect(
    page.locator(
      `.sidebar-item[data-tid="${continuationTid}"] .task-type-icon.completed, ` +
        `.sidebar-item[data-tid="${continuationTid}"] .task-type-icon.resumable`,
    ),
  ).toBeVisible({ timeout });

  // Settlement returns focus to the batch owner after the terminal snapshot.
  await expect
    .poll(() => returnFocusSources.has(continuationTid), { timeout })
    .toBe(true);
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible({
    timeout,
  });

  await page.locator(`.sidebar-item[data-tid="${continuationTid}"]`).click();
  await expect(
    page.locator(`.sidebar-item[data-tid="${continuationTid}"].active`),
  ).toBeVisible({ timeout });
  await expect(
    page.locator(".system-user-message", { hasText: "Handoff: done" }).last(),
  ).toBeVisible({ timeout });

  await page.reload();
  await page.locator(`.sidebar-item[data-tid="${continuationTid}"]`).click();
  await expect(
    page.locator(`.sidebar-item[data-tid="${continuationTid}"].active`),
  ).toBeVisible({ timeout });
  await expect(
    page.locator(".system-user-message", { hasText: "Handoff: done" }).last(),
  ).toBeVisible({ timeout });
});

test("SwitchMode from sub-task sends is_continuation flag", async ({
  page,
  agentType,
}) => {
  // Listen for websocket broadcast frames sent to ALL clients regardless
  // of subscription. The process/exit event with is_continuation is only sent
  // to subscribers of the child's tid, which is racy (the child can exit
  // before any client subscribes). task_reload with reason "continuation" is
  // the reliable broadcast equivalent.
  const taskCreatedEvents: Array<{ tid: number; relation_type?: string }> = [];
  const reloadEvents: Array<{ tid: number; reason?: string }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_reload") {
          reloadEvents.push({
            tid: data.tid,
            reason: data.reason,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // Create root task G and enter its session.
  await enterSession(page);

  // G creates child C of type blank. C's initial prompt is
  // "call switchmode plan", triggering a keep_context continuation.
  await sendMessage(page, "call task blank call switchmode plan");

  const timeout = responseTimeout(agentType);

  // Wait for the child task to be created first; otherwise continuation reload
  // checks can race ahead before the sub-task exists on slower MCP paths.
  await expect(async () => {
    const subTaskCreated = taskCreatedEvents.find(
      (e) => e.relation_type === "subtask",
    );
    expect(subTaskCreated).toBeTruthy();
  }).toPass({ timeout });

  // Wait for a task_reload with reason "continuation" — this confirms the
  // backend processed the SwitchMode and transitioned the task in-place.
  await expect(async () => {
    const continuationReload = reloadEvents.find(
      (e) => e.reason === "continuation",
    );
    expect(continuationReload).toBeTruthy();
  }).toPass({ timeout });
});

test("on_yield continuation auto-fires on clean exit", async ({
  page,
  agentType,
}) => {
  // Listen for task_created broadcast frames — sent to ALL clients regardless of subscription.
  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid: number;
    relation_type: string;
  }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            parent_tid: data.parent_tid,
            relation_type: data.relation_type,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);

  // Create a sub-task of type test_on_yield. The mock agent produces a text
  // reply and exits cleanly (code 0) without calling SwitchMode/Handoff.
  // The on_yield continuation should auto-fire, creating a blank successor.
  await sendMessage(page, "call task test_on_yield hello");

  // A task_created with relation_type "continuation" must appear.
  await expect(async () => {
    const continuationCreated = taskCreatedEvents.find(
      (e) => e.relation_type === "continuation",
    );
    expect(continuationCreated).toBeTruthy();
  }).toPass();
});

test("on_yield does not fire on non-zero exit", { tag: "@no-codex" }, async ({ page, agentType }) => {
  // Keep Codex skipped for now: in this mocked stall path, Codex/mock behavior
  // is not yet deterministic enough to keep the child stalled until kill assertion.

  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid: number;
    relation_type: string;
  }> = [];
  const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            parent_tid: data.parent_tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated") {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            alive: data.task.alive,
          });
        }
      } catch {}
    });
  });

  await enterSession(page);

  // Create a sub-task of type test_on_yield with a stalling LLM response so
  // the sub-task stays alive long enough for us to kill it.
  await sendMessage(page, "call task test_on_yield stall session");

  // Wait for the sub-task to be created (task_created is broadcast to all clients).
  await expect(async () => {
    const subTask = taskCreatedEvents.find(
      (e) => e.relation_type === "subtask",
    );
    expect(subTask).toBeTruthy();
  }).toPass();
  const subTaskTid = taskCreatedEvents.find(
    (e) => e.relation_type === "subtask",
  )!.tid;

  await expect(
    page.locator(`.sidebar-item[data-tid="${subTaskTid}"]`),
  ).toHaveClass(/\bactive\b/);

  // Other task panes stay mounted while hidden, so scope Kill to the child.
  await taskPane(page, subTaskTid)
    .getByRole("button", { name: "Kill", exact: true })
    .click();

  // Wait for the sub-task to show as dead via broadcast task_updated.
  await expect(async () => {
    const deadUpdate = taskUpdatedEvents.find(
      (e) => e.tid === subTaskTid && !e.alive,
    );
    expect(deadUpdate).toBeTruthy();
  }).toPass();

  // No task_created with relation_type "continuation" should have appeared.
  const continuationCreated = taskCreatedEvents.find(
    (e) => e.relation_type === "continuation",
  );
  expect(continuationCreated).toBeFalsy();
});

test("input box stays empty after mode switch", async ({ page, agentType }) => {
  const liveInterruptionUuids: string[] = [];
  const continuationReloads: ContinuationReload[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const frame = JSON.parse(event.payload.toString()) as unknown;
        if (!isJsonRecord(frame)) return;
        const interruptionUuid = interruptedClaudeUserUuid(frame);
        if (interruptionUuid) liveInterruptionUuids.push(interruptionUuid);
        const continuationReload = continuationReloadFromFrame(frame);
        if (continuationReload) continuationReloads.push(continuationReload);
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".result-divider.system-user-message", {
      hasText: "Mode switch: plan",
    }),
  ).toBeVisible();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue("");

  const continuationReload = exactlyOne(
    continuationReloads,
    "Expected one continuation task_reload",
  );
  if (agentType === "claude") {
    const markerUuid = exactlyOne(
      [...new Set(liveInterruptionUuids)],
      "Expected one live Claude interruption marker UUID",
    );
    expect(continuationReload.hasExcludedUserUuid).toBe(true);
    expect(
      continuationReload.excludedUserUuid,
      "The persisted repair UUID must equal the UUID emitted for the live marker",
    ).toBe(markerUuid);
  } else {
    expect(continuationReload.hasExcludedUserUuid).toBe(false);
    expect(continuationReload.excludedUserUuid).toBeUndefined();
  }

  await page.reload();
  await expect(
    page.locator(".result-divider.system-user-message", {
      hasText: "Mode switch: plan",
    }),
  ).toBeVisible();
  const reloadedInput = page.locator(".input-textarea:visible").first();
  await expect(reloadedInput).toBeEnabled();
  await expect(reloadedInput).toHaveValue("");
});

function interruptedClaudeUserUuid(frame: JsonRecord): string | undefined {
  const event = frame.event;
  if (
    !isJsonRecord(event) ||
    event.type !== "item/started" ||
    event.item_type !== "user_message" ||
    typeof event.uuid !== "string" ||
    event.uuid.length === 0 ||
    !Array.isArray(event.content)
  ) {
    return undefined;
  }

  return event.content.some(
    (block) =>
      isJsonRecord(block) &&
      block.type === "text" &&
      (block.text === "[Request interrupted by user for tool use]" ||
        block.text === "[Request interrupted by user]"),
  )
    ? event.uuid
    : undefined;
}
