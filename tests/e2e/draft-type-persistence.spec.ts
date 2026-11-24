import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass();
  return newTid!;
}

type ControlFrame = {
  type?: string;
  tid?: number;
  correlation_id?: string;
  content?: unknown;
  entry_point?: string;
  agent_name?: string;
};

type CreatedTask = {
  tid: number;
  correlationId: string | null;
};

interface OutboundRecorder {
  mark(): number;
  controls(
    type: string,
    query?: { tid?: number; since?: number },
  ): readonly ControlFrame[];
  createdTid(correlationId: string): number | null;
}

function parseControlFrame(payload: string): ControlFrame {
  return JSON.parse(payload) as ControlFrame;
}

function installOutboundRecorder(page: Page): OutboundRecorder {
  const outbound: ControlFrame[] = [];
  const createdTasks: CreatedTask[] = [];

  // This only observes the application's existing WebSocket; it never proxies
  // or otherwise changes the traffic being exercised by the test.
  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;

    socket.on("framesent", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame.type) outbound.push(frame);
    });
    socket.on("framereceived", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame.type === "task_created" && typeof frame.tid === "number") {
        createdTasks.push({
          tid: frame.tid,
          correlationId:
            typeof frame.correlation_id === "string"
              ? frame.correlation_id
              : null,
        });
      }
    });
  });

  return {
    mark: () => outbound.length,
    controls: (type, query) =>
      outbound
        .slice(query?.since ?? 0)
        .filter(
          (frame) =>
            frame.type === type &&
            (query?.tid === undefined || frame.tid === query.tid),
        ),
    createdTid: (correlationId) =>
      createdTasks.find((task) => task.correlationId === correlationId)?.tid ??
      null,
  };
}

function requireCorrelation(frame: ControlFrame, label: string): string {
  if (!frame.correlation_id)
    throw new Error(`${label} create_task did not carry a correlation_id`);
  return frame.correlation_id;
}

async function waitForCreatedTid(
  recorder: OutboundRecorder,
  correlationId: string,
): Promise<number> {
  await expect.poll(() => recorder.createdTid(correlationId)).not.toBeNull();
  const tid = recorder.createdTid(correlationId);
  if (tid === null)
    throw new Error(
      `task_created acknowledgement missing for ${correlationId}`,
    );
  return tid;
}

async function waitForPersistedDraft(
  recorder: OutboundRecorder,
  since: number,
  tid: number,
  text: string,
  metadata: { entryPoint?: string; agentName?: string },
) {
  await expect
    .poll(() => {
      const latestDraft = recorder.controls("set_draft", { tid, since }).at(-1);
      const entryPointPersisted =
        metadata.entryPoint === undefined ||
        recorder
          .controls("set_entry_point", { tid, since })
          .some((frame) => frame.entry_point === metadata.entryPoint);
      const agentPersisted =
        metadata.agentName === undefined ||
        recorder
          .controls("set_agent_name", { tid, since })
          .some((frame) => frame.agent_name === metadata.agentName);
      return (
        latestDraft?.content === text && entryPointPersisted && agentPersisted
      );
    })
    .toBe(true);
}

test("sidebar icon updates when entry point changed on draft", async ({
  page,
}) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task (default type is "conversation" in test env)
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("sidebar icon test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible();

  // Default icon should be "conversation" (agentic is the first entry point in test env)
  await expect(
    page.locator(
      `.sidebar-item[data-tid="${draftTid}"] .task-type-icon-conversation`,
    ),
  ).toBeVisible();

  // Change entry point to "blank" via the picker
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .task-type-icon-blank`),
  ).toBeVisible();
});

test("entry point persists across page reload on draft", async ({ page }) => {
  const recorder = installOutboundRecorder(page);
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("entry point reload test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible();

  // Change entry point to "blank"
  const persistenceStart = recorder.mark();
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await waitForPersistedDraft(
    recorder,
    persistenceStart,
    Number(draftTid),
    "entry point reload test",
    { entryPoint: "blank" },
  );

  // Reload the page
  await page.reload();

  // Navigate to the draft task
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached();
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();

  // Wait for the entry-point picker to be visible
  await expect(page.locator(".task-type-picker")).toBeVisible();

  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
});

test("sending from isolated draft applies the isolated entry-point prompt", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("isolated");

  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("isolated draft echo test");
  await page.locator(".btn-send:visible").first().click();

  await expect(assistantText(page, "The user's request follows")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(assistantText(page, "isolated draft echo test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("agent type persists across page reload on draft", async ({
  page,
  agentType,
}) => {
  const targetAgent = agentType === "codex" ? "claude" : "codex";
  const recorder = installOutboundRecorder(page);

  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("agent type reload test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible();

  // Change the agent type
  const persistenceStart = recorder.mark();
  await page.locator(".agent-picker").selectOption(targetAgent);
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);
  await waitForPersistedDraft(
    recorder,
    persistenceStart,
    Number(draftTid),
    "agent type reload test",
    { agentName: targetAgent },
  );

  // Reload the page
  await page.reload();

  // Navigate to the draft task
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached();
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();

  // Wait for the agent picker to be visible
  await expect(page.locator(".agent-picker")).toBeVisible();

  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);
});

test("New Task defaults stay independent of promoted draft selectors", async ({
  page,
  agentType,
}) => {
  const recorder = installOutboundRecorder(page);
  const targetAgent = agentType === "codex" ? "claude" : "codex";

  await enterSession(page);

  const input = page.locator(".input-textarea:visible");
  const agentPicker = page.locator(".agent-picker:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toHaveValue("");
  await expect(
    agentPicker.locator(`option[value="${targetAgent}"]`),
  ).toHaveCount(1);

  // Select both defaults on the blank New Task composition.
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await agentPicker.selectOption(targetAgent);
  await expect(agentPicker).toHaveValue(targetAgent);
  expect(recorder.controls("create_task")).toHaveLength(0);

  const textA = "selector defaults draft A";
  const createAStart = recorder.mark();
  await input.fill(textA);

  await expect
    .poll(
      () => recorder.controls("create_task", { since: createAStart }).length,
    )
    .toBe(1);
  const createA = recorder.controls("create_task", { since: createAStart })[0]!;
  expect(createA.content).toEqual([]);
  expect(createA.entry_point).toBe("blank");
  expect(createA.agent_name).toBe(targetAgent);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(recorder, correlationA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  await waitForPersistedDraft(recorder, createAStart, tidA, textA, {
    entryPoint: "blank",
    agentName: targetAgent,
  });

  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  const changedA = recorder.mark();
  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await agentPicker.selectOption(agentType);
  await expect
    .poll(
      () =>
        recorder
          .controls("set_entry_point", { tid: tidA, since: changedA })
          .at(-1)?.entry_point,
    )
    .toBe("isolated");
  await expect
    .poll(
      () =>
        recorder
          .controls("set_agent_name", { tid: tidA, since: changedA })
          .at(-1)?.agent_name,
    )
    .toBe(agentType);
  await page.locator(".sidebar-new-task").click();
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue("");
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(agentPicker).toHaveValue(targetAgent);

  const textB = "selector defaults draft B";
  const createBStart = recorder.mark();
  await input.fill(textB);

  await expect
    .poll(
      () => recorder.controls("create_task", { since: createBStart }).length,
    )
    .toBe(1);
  const createB = recorder.controls("create_task", { since: createBStart })[0]!;
  expect(createB.content).toEqual([]);
  expect(createB.entry_point).toBe("blank");
  expect(createB.agent_name).toBe(targetAgent);
  const correlationB = requireCorrelation(createB, "B");
  expect(correlationB).not.toBe(correlationA);
  const tidB = await waitForCreatedTid(recorder, correlationB);
  expect(tidB).not.toBe(tidA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  await waitForPersistedDraft(recorder, createBStart, tidB, textB, {
    entryPoint: "blank",
    agentName: targetAgent,
  });
  await expect(input).toHaveValue(textB);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(agentPicker).toHaveValue(targetAgent);
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidB}"] .task-type-icon-blank`),
  ).toBeVisible();

  const createsBeforeReattach = recorder.controls("create_task").length;
  const deletesBeforeReattach = recorder.controls("delete_task").length;
  expect(createsBeforeReattach).toBe(2);
  expect(deletesBeforeReattach).toBe(0);

  await page.locator(".sidebar-back-btn:visible").click();
  await expect(page).toHaveURL(/\/$/);
  await page.goBack();
  await expect(page).toHaveURL(new RegExp(`/task/${tidB}(?:/|$)`));
  await expect(input).toHaveCount(1);
  await expect(input).toHaveValue(textB);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(agentPicker).toHaveValue(targetAgent);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidB}"] .task-type-icon-blank`),
  ).toBeVisible();
  expect(recorder.controls("create_task")).toHaveLength(createsBeforeReattach);
  expect(recorder.controls("delete_task")).toHaveLength(deletesBeforeReattach);
  expect(recorder.createdTid(correlationB)).toBe(tidB);

  const clearBStart = recorder.mark();
  await input.fill("");
  await expect
    .poll(
      () =>
        recorder.controls("delete_task", { tid: tidB, since: clearBStart })
          .length,
    )
    .toBe(1);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    0,
  );
  expect(recorder.controls("delete_task").map((frame) => frame.tid)).toEqual([
    tidB,
  ]);
  await page.locator(`.sidebar-item[data-tid="${tidA}"]`).click();
  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  await expect(input).toHaveValue(textA);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("isolated");
  await expect(agentPicker).toHaveValue(agentType);
});
