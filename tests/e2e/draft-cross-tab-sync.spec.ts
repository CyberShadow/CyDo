import { Buffer } from "node:buffer";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
  currentTaskTid,
} from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type TaskFrame = {
  tid?: number;
  draft?: string;
  entry_point?: string;
  agent_name?: string;
};

type ControlFrame = {
  type?: string;
  tid?: number;
  content?: unknown;
  entry_point?: string;
  agent_name?: string;
  old_draft?: string;
  new_draft?: string;
  task?: TaskFrame;
};

type ObservedControl = {
  sequence: number;
  frame: ControlFrame;
};

interface PageObserver {
  mark(): number;
  outbound(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
  inbound(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
}

interface OutboundHoldingObserver extends PageObserver {
  armOutgoingMutationHold(): number;
  heldOutgoing(): readonly ObservedControl[];
  forwarded(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
  releaseOutgoingHold(): void;
}

function parseControlFrame(message: SocketMessage): ControlFrame | null {
  try {
    return JSON.parse(
      typeof message === "string" ? message : message.toString(),
    ) as ControlFrame;
  } catch {
    return null;
  }
}

function frameTid(frame: ControlFrame): number | undefined {
  return frame.tid ?? frame.task?.tid;
}

function filterControls(
  controls: readonly ObservedControl[],
  type: string | undefined,
  query: { tid?: number; since?: number } | undefined,
): readonly ObservedControl[] {
  return controls.filter(
    (control) =>
      (type === undefined || control.frame.type === type) &&
      (query?.tid === undefined || frameTid(control.frame) === query.tid) &&
      (query?.since === undefined || control.sequence > query.since),
  );
}

function installPassiveObserver(page: Page): PageObserver {
  const outbound: ObservedControl[] = [];
  const inbound: ObservedControl[] = [];
  let sequence = 0;

  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;
    socket.on("framesent", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) outbound.push({ sequence: ++sequence, frame });
    });
    socket.on("framereceived", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) inbound.push({ sequence: ++sequence, frame });
    });
  });

  return {
    mark: () => sequence,
    outbound: (type, query) => filterControls(outbound, type, query),
    inbound: (type, query) => filterControls(inbound, type, query),
  };
}

function isDraftMutation(frame: ControlFrame | null): boolean {
  return (
    frame?.type === "set_entry_point" ||
    frame?.type === "set_agent_name" ||
    frame?.type === "set_draft"
  );
}

async function installOutboundHoldingObserver(
  page: Page,
): Promise<OutboundHoldingObserver> {
  const outbound: ObservedControl[] = [];
  const inbound: ObservedControl[] = [];
  const forwarded: ObservedControl[] = [];
  const held: ObservedControl[] = [];
  const heldFrames: { message: SocketMessage; observed?: ObservedControl }[] =
    [];
  const deferredFrames: {
    message: SocketMessage;
    observed?: ObservedControl;
  }[] = [];
  let sequence = 0;
  let armed = false;
  let holding = false;
  let replaying = false;
  let release = () => {
    throw new Error("WebSocket route was not installed");
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    const serverSocket = browserSocket.connectToServer();

    const forwardBrowserFrame = (entry: {
      message: SocketMessage;
      observed?: ObservedControl;
    }) => {
      if (entry.observed) forwarded.push(entry.observed);
      serverSocket.send(entry.message);
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      const observed = frame?.type
        ? { sequence: ++sequence, frame }
        : undefined;
      if (observed) outbound.push(observed);
      const entry = { message, observed };

      if (replaying) {
        deferredFrames.push(entry);
        return;
      }
      if (holding || (armed && isDraftMutation(frame))) {
        holding = true;
        heldFrames.push(entry);
        if (observed) held.push(observed);
        return;
      }
      forwardBrowserFrame(entry);
    });

    serverSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      if (frame?.type) inbound.push({ sequence: ++sequence, frame });
      browserSocket.send(message);
    });

    release = () => {
      if (!holding) throw new Error("No outgoing draft mutation is held");
      armed = false;
      holding = false;
      replaying = true;
      try {
        while (heldFrames.length > 0) forwardBrowserFrame(heldFrames.shift()!);
        while (deferredFrames.length > 0)
          forwardBrowserFrame(deferredFrames.shift()!);
      } finally {
        replaying = false;
      }
    };
  });

  return {
    mark: () => sequence,
    outbound: (type, query) => filterControls(outbound, type, query),
    inbound: (type, query) => filterControls(inbound, type, query),
    armOutgoingMutationHold: () => {
      if (armed || holding) throw new Error("Outgoing mutation hold is active");
      armed = true;
      return sequence;
    },
    heldOutgoing: () => held,
    forwarded: (type, query) => filterControls(forwarded, type, query),
    releaseOutgoingHold: () => release(),
  };
}

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<number> {
  let tid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    tid = tids.find((candidate) => !before.has(candidate));
    expect(tid).toBeTruthy();
  }).toPass();
  return Number(tid);
}

async function createPersistedDraft(
  page: Page,
  observer: PageObserver,
  text: string,
): Promise<number> {
  const before = await snapshotTids(page);
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await input.fill(text);
  const tid = await waitForNewTid(page, before);
  await expect
    .poll(() =>
      observer
        .outbound("set_draft", { tid })
        .some((control) => control.frame.content === text),
    )
    .toBe(true);
  return tid;
}

async function selectPersistedDraft(page: Page, tid: number): Promise<void> {
  const draft = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(draft).toHaveCount(1);
  await draft.click();
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(page.locator(".input-textarea:visible")).toHaveCount(1);
}

async function selectedEntryPoint(page: Page): Promise<string> {
  const entryPoint = await page
    .locator(".task-type-row.selected .task-type-name")
    .textContent();
  if (!entryPoint) throw new Error("Selected entry point was unavailable");
  return entryPoint.trim();
}

async function selectableAgentValues(page: Page): Promise<readonly string[]> {
  return page.locator(".agent-picker:visible option").evaluateAll((options) =>
    options
      .map((option) => option as HTMLOptionElement)
      .filter((option) => option.value.length > 0 && !option.disabled)
      .map((option) => option.value),
  );
}

async function expectControlledForm(
  page: Page,
  text: string,
  entryPoint: string,
  agent: string,
) {
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(text);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText(entryPoint);
  await expect(page.locator(".agent-picker:visible")).toHaveValue(agent);
}

async function expectDraftPropagation(
  sender: PageObserver,
  receiver: PageObserver,
  tid: number,
  oldText: string,
  text: string,
  senderSince: number,
  receiverSince: number,
): Promise<void> {
  await expect
    .poll(() => {
      const draftWasSent = sender
        .outbound("set_draft", { tid, since: senderSince })
        .some((control) => control.frame.content === text);
      const draftWasReceived = receiver
        .inbound("draft_updated", { tid, since: receiverSince })
        .some(
          (control) =>
            control.frame.old_draft === oldText &&
            control.frame.new_draft === text,
        );
      return draftWasSent && draftWasReceived;
    })
    .toBe(true);
}

async function observeLoadingTaskInsertion(page: Page): Promise<void> {
  await page.evaluate(() => {
    const testWindow = window as Window & {
      __cydoCrossTabLoading?: {
        state: { inserted: boolean };
        observer: MutationObserver;
      };
    };
    testWindow.__cydoCrossTabLoading?.observer.disconnect();
    const state = { inserted: false };
    const inspect = (node: Node) => {
      if (!(node instanceof Element)) return;
      if (
        node.matches(".session-empty") &&
        node.textContent?.includes("Loading task")
      )
        state.inserted = true;
      if (
        node
          .querySelector(".session-empty")
          ?.textContent?.includes("Loading task")
      )
        state.inserted = true;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records)
        for (const node of record.addedNodes) inspect(node);
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
    testWindow.__cydoCrossTabLoading = { state, observer };
  });
}

async function loadingTaskWasInserted(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const state = (
      window as Window & {
        __cydoCrossTabLoading?: { state: { inserted: boolean } };
      }
    ).__cydoCrossTabLoading;
    if (!state) throw new Error("Loading task observer was unavailable");
    return state.state.inserted;
  });
}

test("draft creation syncs title and body to another tab", async ({
  page,
  browser,
  baseURL,
}) => {
  const observer = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();

  await enterSession(page);
  await enterSession(page2);

  const draftText = "cross tab draft sync body";
  const draftTid = await createPersistedDraft(page, observer, draftText);

  const tab2Draft = page2.locator(`.sidebar-item[data-tid="${draftTid}"]`);
  await expect(tab2Draft).toHaveCount(1);
  await expect(tab2Draft.locator(".sidebar-label")).toHaveText(draftText);
  await tab2Draft.click();
  await expect(page2.locator(".input-textarea:visible")).toHaveValue(draftText);

  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toHaveCount(0);
});

test("a pending draft sender adopts a later peer update", async ({
  page,
  browser,
  baseURL,
}) => {
  const observerA = installPassiveObserver(page);
  const contextB = await browser.newContext({ baseURL });
  const pageB = await contextB.newPage();
  const observerB = installPassiveObserver(pageB);

  await enterSession(page);
  await enterSession(pageB);

  const textA = "pending sender draft";
  const initialSenderStart = observerA.mark();
  const initialReceiverStart = observerB.mark();
  const tid = await createPersistedDraft(page, observerA, textA);
  await expectDraftPropagation(
    observerA,
    observerB,
    tid,
    "",
    textA,
    initialSenderStart,
    initialReceiverStart,
  );

  await selectPersistedDraft(pageB, tid);
  const inputA = page.locator(".input-textarea:visible");
  const inputB = pageB.locator(".input-textarea:visible");
  await expect(inputA).toHaveValue(textA);
  await expect(inputB).toHaveValue(textA);

  const textB = "pending peer replacement";
  const peerSenderStart = observerB.mark();
  const peerReceiverStart = observerA.mark();
  await inputB.fill(textB);
  await expectDraftPropagation(
    observerB,
    observerA,
    tid,
    textA,
    textB,
    peerSenderStart,
    peerReceiverStart,
  );
  await expect(inputA).toHaveValue(textB);

  const finalSenderStart = observerA.mark();
  const finalReceiverStart = observerB.mark();
  await inputA.fill(textA);
  await expectDraftPropagation(
    observerA,
    observerB,
    tid,
    textB,
    textA,
    finalSenderStart,
    finalReceiverStart,
  );
  await expect(inputB).toHaveValue(textA);

  await contextB.close();
});

test("a pristine persisted editor accepts peer text and configuration", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = await installOutboundHoldingObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const peerAgent = agentType === "codex" ? "claude" : "codex";
  expect(await selectableAgentValues(page)).toContain(peerAgent);
  expect(peerAgent).not.toBe(baselineAgent);
  expect(baselineEntryPoint).not.toBe("blank");

  const baselineText = "pristine baseline text";
  const tid = await createPersistedDraft(page, observer1, baselineText);
  await selectPersistedDraft(page2, tid);
  await expectControlledForm(
    page2,
    baselineText,
    baselineEntryPoint,
    baselineAgent,
  );
  expect(observer2.outbound("create_task")).toHaveLength(0);

  const peerText = "pristine peer first line\nsecond peer line";
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await page.locator(".agent-picker:visible").selectOption(peerAgent);
  await page.locator(".input-textarea:visible").fill(peerText);

  await expect
    .poll(() => {
      const peerDraftArrived = observer2
        .inbound("draft_updated", { tid })
        .some((control) => control.frame.new_draft === peerText);
      const peerConfigurationArrived = observer2
        .inbound("task_updated", { tid })
        .some(
          (control) =>
            control.frame.task?.entry_point === "blank" &&
            control.frame.task.agent_name === peerAgent,
        );
      return peerDraftArrived && peerConfigurationArrived;
    })
    .toBe(true);
  await expectControlledForm(page2, peerText, "blank", peerAgent);
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .sidebar-label`),
  ).toHaveText("pristine peer first line");
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .task-type-icon-blank`),
  ).toBeVisible();
  await expect(page2.locator(".input-textarea:visible")).toHaveCount(1);
  expect(observer1.outbound("create_task")).toHaveLength(1);
  expect(observer2.outbound("create_task")).toHaveLength(0);

  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
});

test("a diverged persisted editor retains local fields until its held write wins", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = await installOutboundHoldingObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const receiverAgent = agentType === "codex" ? "claude" : "codex";
  expect(baselineAgent).toBe(agentType);
  expect(await selectableAgentValues(page)).toEqual(
    expect.arrayContaining([baselineAgent, receiverAgent]),
  );
  expect(receiverAgent).not.toBe(baselineAgent);
  expect(new Set([baselineEntryPoint, "isolated", "blank"]).size).toBe(3);
  await expect(
    page.locator(".task-type-row", { hasText: "isolated" }),
  ).toHaveCount(1);
  await expect(
    page.locator(".task-type-row", { hasText: "blank" }),
  ).toHaveCount(1);

  const baselineText = "diverged baseline text";
  const tid = await createPersistedDraft(page, observer1, baselineText);
  await selectPersistedDraft(page2, tid);
  await expectControlledForm(
    page2,
    baselineText,
    baselineEntryPoint,
    baselineAgent,
  );
  expect(observer2.outbound("create_task")).toHaveLength(0);

  const receiverText = "receiver keeps this first line\nreceiver second line";
  const holdStart = observer2.armOutgoingMutationHold();
  await page2.locator(".task-type-row", { hasText: "isolated" }).click();
  await page2.locator(".agent-picker:visible").selectOption(receiverAgent);
  await page2.locator(".input-textarea:visible").fill(receiverText);
  await expect
    .poll(() =>
      observer2
        .heldOutgoing()
        .filter(
          (control) =>
            control.frame.tid === tid &&
            (control.frame.type === "set_entry_point" ||
              control.frame.type === "set_agent_name" ||
              control.frame.type === "set_draft"),
        )
        .map((control) => ({
          type: control.frame.type,
          entryPoint: control.frame.entry_point,
          agent: control.frame.agent_name,
          content: control.frame.content,
        })),
    )
    .toEqual([
      {
        type: "set_entry_point",
        entryPoint: "isolated",
        agent: undefined,
        content: undefined,
      },
      {
        type: "set_agent_name",
        entryPoint: undefined,
        agent: receiverAgent,
        content: undefined,
      },
      {
        type: "set_draft",
        entryPoint: undefined,
        agent: undefined,
        content: receiverText,
      },
    ]);
  expect(
    observer2.forwarded("set_entry_point", { tid, since: holdStart }),
  ).toHaveLength(0);
  expect(
    observer2.forwarded("set_agent_name", { tid, since: holdStart }),
  ).toHaveLength(0);
  expect(
    observer2.forwarded("set_draft", { tid, since: holdStart }),
  ).toHaveLength(0);

  const peerStart = observer2.mark();
  const senderStart = observer1.mark();
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    baselineAgent,
  );
  const senderText = "sender peer first line\nsender second line";
  await page.locator(".input-textarea:visible").fill(senderText);
  await expect
    .poll(() => {
      const senderDraftSent = observer1
        .outbound("set_draft", { tid, since: senderStart })
        .some((control) => control.frame.content === senderText);
      const peerDraftArrived = observer2
        .inbound("draft_updated", { tid, since: peerStart })
        .some((control) => control.frame.new_draft === senderText);
      return senderDraftSent && peerDraftArrived;
    })
    .toBe(true);

  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect
    .poll(() => {
      const senderEntryPointSent = observer1
        .outbound("set_entry_point", { tid, since: senderStart })
        .some((control) => control.frame.entry_point === "blank");
      const peerFullSnapshotArrived = observer2
        .inbound("task_updated", { tid, since: peerStart })
        .some((control) => {
          const task = control.frame.task;
          return (
            task?.draft === senderText &&
            task.entry_point === "blank" &&
            task.agent_name === baselineAgent
          );
        });
      return senderEntryPointSent && peerFullSnapshotArrived;
    })
    .toBe(true);
  await expectControlledForm(page2, receiverText, "isolated", receiverAgent);
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .sidebar-label`),
  ).toHaveText("receiver keeps this first line");
  await expect(page2.locator(".input-textarea:visible")).toHaveCount(1);

  const releaseStart = observer1.mark();
  observer2.releaseOutgoingHold();
  await expect
    .poll(() =>
      observer2
        .forwarded(undefined, { since: holdStart })
        .filter(
          (control) =>
            control.frame.tid === tid &&
            (control.frame.type === "set_entry_point" ||
              control.frame.type === "set_agent_name" ||
              control.frame.type === "set_draft"),
        )
        .map((control) => ({
          type: control.frame.type,
          entryPoint: control.frame.entry_point,
          agent: control.frame.agent_name,
          content: control.frame.content,
        })),
    )
    .toEqual([
      {
        type: "set_entry_point",
        entryPoint: "isolated",
        agent: undefined,
        content: undefined,
      },
      {
        type: "set_agent_name",
        entryPoint: undefined,
        agent: receiverAgent,
        content: undefined,
      },
      {
        type: "set_draft",
        entryPoint: undefined,
        agent: undefined,
        content: receiverText,
      },
    ]);
  expect(observer2.forwarded("create_task", { since: holdStart })).toHaveLength(
    0,
  );
  expect(observer2.forwarded("delete_task", { since: holdStart })).toHaveLength(
    0,
  );
  await expect
    .poll(() => {
      const receiverConfigurationArrived = observer1
        .inbound("task_updated", { tid, since: releaseStart })
        .some(
          (control) =>
            control.frame.task?.entry_point === "isolated" &&
            control.frame.task.agent_name === receiverAgent,
        );
      const receiverDraftArrived = observer1
        .inbound("draft_updated", { tid, since: releaseStart })
        .some((control) => control.frame.new_draft === receiverText);
      return receiverConfigurationArrived && receiverDraftArrived;
    })
    .toBe(true);

  const targetHref = await page
    .locator(`.sidebar-item[data-tid="${tid}"]`)
    .getAttribute("href");
  if (!targetHref)
    throw new Error("Persisted sidebar draft did not have a URL");
  const context3 = await browser.newContext({ baseURL });
  const page3 = await context3.newPage();
  await page3.goto(new URL(targetHref, page.url()).toString());
  await expectControlledForm(page3, receiverText, "isolated", receiverAgent);

  await context3.close();
  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
});

test("persisted editors keep delayed writes scoped to their tids across A/B/A routing", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = await installOutboundHoldingObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = installPassiveObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const agentB = agentType === "codex" ? "claude" : "codex";
  const agentALatest = baselineAgent;
  expect(baselineAgent).toBe(agentType);
  expect(await selectableAgentValues(page)).toEqual(
    expect.arrayContaining([agentALatest, agentB]),
  );
  expect(agentB).not.toBe(agentALatest);
  expect(new Set([baselineEntryPoint, "blank", "isolated"]).size).toBe(3);

  const textA = "switch persisted A baseline";
  const seedPage = await browser.newPage({ baseURL });
  const seedObserver = installPassiveObserver(seedPage);
  await enterSession(seedPage);
  const tidA = await createPersistedDraft(seedPage, seedObserver, textA);
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidA}"] .sidebar-label`),
  ).toHaveText(textA);
  await seedPage.close();
  await page2.locator(".task-type-row", { hasText: "blank" }).click();
  await page2.locator(".agent-picker:visible").selectOption(agentB);
  const textB = "switch persisted B baseline";
  const tidB = await createPersistedDraft(page2, observer2, textB);
  expect(tidB).not.toBe(tidA);
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidA}"] .sidebar-label`),
  ).toHaveText(textA);
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidB}"] .sidebar-label`),
  ).toHaveText(textB);
  await expect
    .poll(() =>
      observer1
        .inbound("task_updated", { tid: tidB })
        .some(
          (control) =>
            control.frame.task?.entry_point === "blank" &&
            control.frame.task.agent_name === agentB,
        ),
    )
    .toBe(true);

  const latestA = "persisted A latest local text";
  const latestB = "persisted B latest local text";
  await selectPersistedDraft(page, tidA);
  await expectControlledForm(page, textA, baselineEntryPoint, agentALatest);
  const clockStart = new Date();
  await page.clock.install({ time: clockStart });
  await page.clock.pauseAt(new Date(clockStart.getTime() + 60_000));
  const since = observer1.armOutgoingMutationHold();
  await observeLoadingTaskInsertion(page);

  const navigateFromEditor = async (tid: number) => {
    const row = page.locator(`.sidebar-item[data-tid="${tid}"]`);
    // The browser focuses the link before a click. Exercise that blur while
    // the clock is paused, then follow the link without advancing the timer.
    await row.focus();
    await row.evaluate((element: HTMLElement) => {
      element.click();
    });
    await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  };
  const writes = () =>
    observer1
      .outbound("set_draft", { since })
      .map(({ frame }) => [frame.tid, frame.content]);

  await page.locator(".input-textarea:visible").fill(latestA);
  await navigateFromEditor(tidB);
  await expectControlledForm(page, textB, "blank", agentB);
  await page.clock.runFor(499);
  expect(writes()).toEqual([]);
  await page.clock.runFor(1);
  await expect.poll(writes).toEqual([[tidA, latestA]]);

  await page.locator(".input-textarea:visible").fill(latestB);
  await navigateFromEditor(tidA);
  await expectControlledForm(page, latestA, baselineEntryPoint, agentALatest);
  await page.clock.runFor(499);
  expect(writes()).toEqual([[tidA, latestA]]);
  await page.clock.runFor(1);
  await expect.poll(writes).toEqual([
    [tidA, latestA],
    [tidB, latestB],
  ]);
  expect(observer1.forwarded("set_draft", { since })).toEqual([]);
  expect(await loadingTaskWasInserted(page)).toBe(false);
  await page.clock.resume();

  observer1.releaseOutgoingHold();
  await expect
    .poll(() =>
      observer2
        .inbound("draft_updated", { tid: tidA })
        .some(({ frame }) => frame.new_draft === latestA),
    )
    .toBe(true);
  await expectControlledForm(page2, latestB, "blank", agentB);
  expect(writes()).toEqual([
    [tidA, latestA],
    [tidB, latestB],
  ]);
  for (const type of [
    "create_task",
    "delete_task",
    "set_entry_point",
    "set_agent_name",
  ]) {
    expect(observer1.outbound(type, { since })).toEqual([]);
  }

  await page2.locator(".input-textarea:visible").fill("");
  await expect(page2.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    0,
  );
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    0,
  );
  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    0,
  );
});

test("an active task sender adopts a later peer update", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observerA = installPassiveObserver(page);
  const contextB = await browser.newContext({ baseURL });
  const pageB = await contextB.newPage();
  const observerB = installPassiveObserver(pageB);

  await enterSession(page);
  await sendMessage(page, 'Please reply with "ordinary-draft-cross-tab"');
  await expect(assistantText(page, "ordinary-draft-cross-tab")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const tid = currentTaskTid(page);

  await pageB.goto(page.url());
  await selectPersistedDraft(pageB, tid);
  const inputA = page.locator(".input-textarea:visible");
  const inputB = pageB.locator(".input-textarea:visible");
  await expect(inputA).toHaveValue("");
  await expect(inputB).toHaveValue("");

  const textA = "ordinary sender draft";
  const initialSenderStart = observerA.mark();
  const initialReceiverStart = observerB.mark();
  await inputA.fill(textA);
  await expectDraftPropagation(
    observerA,
    observerB,
    tid,
    "",
    textA,
    initialSenderStart,
    initialReceiverStart,
  );
  await expect(inputB).toHaveValue(textA);

  const textB = "ordinary peer replacement";
  const peerSenderStart = observerB.mark();
  const peerReceiverStart = observerA.mark();
  await inputB.fill(textB);
  await expectDraftPropagation(
    observerB,
    observerA,
    tid,
    textA,
    textB,
    peerSenderStart,
    peerReceiverStart,
  );
  await expect(inputA).toHaveValue(textB);

  const finalSenderStart = observerA.mark();
  const finalReceiverStart = observerB.mark();
  await inputA.fill(textA);
  await expectDraftPropagation(
    observerA,
    observerB,
    tid,
    textB,
    textA,
    finalSenderStart,
    finalReceiverStart,
  );
  await expect(inputB).toHaveValue(textA);

  await contextB.close();
});
