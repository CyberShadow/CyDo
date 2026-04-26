import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("triage -> decompose keep_context uses strengthened resumed handoff", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "Codex-focused regression for decompose continuation anchoring");

  const taskCreatedEvents: Array<{ tid: number; parent_tid: number; relation_type?: string }> = [];
  const taskReloadEvents: Array<{ tid: number; reason?: string }> = [];
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
        } else if (data.type === "task_reload") {
          taskReloadEvents.push({
            tid: data.tid,
            reason: data.reason,
          });
        }
      } catch { /* ignore non-JSON frames */ }
    });
  });

  await enterSession(page);

  await sendMessage(page, "call task triage call switchmode decompose");

  await expect(async () => {
    const triageChild = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(triageChild).toBeTruthy();
  }).toPass({ timeout: responseTimeout(agentType) });
  const triageTid = taskCreatedEvents.find((e) => e.relation_type === "subtask")!.tid;

  await expect(async () => {
    const continuationReload = taskReloadEvents.find(
      (e) => e.tid === triageTid && e.reason === "continuation",
    );
    expect(continuationReload).toBeTruthy();
  }).toPass({ timeout: responseTimeout(agentType) });

  await expect(async () => {
    const createdAfterSwitch = taskCreatedEvents
      .find((e) => e.relation_type === "subtask" && e.parent_tid === triageTid);
    expect(createdAfterSwitch).toBeTruthy();
  }).toPass({ timeout: responseTimeout(agentType) });
});
