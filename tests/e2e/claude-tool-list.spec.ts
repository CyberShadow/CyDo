import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
} from "./fixtures";

// The tools a Claude Code session has, as its init event reports them. The
// list is exact on purpose: a Claude Code upgrade that adds, renames or drops
// a tool fails this test, so that each new tool is looked at (should CyDo
// leave it to the agent, or does it bypass something CyDo provides, as the
// native sub-agent and plan-mode tools do?) before the list is updated.
const expectedTools = [
  "Bash",
  "CronCreate",
  "CronDelete",
  "CronList",
  "Edit",
  "Monitor",
  "NotebookEdit",
  "Read",
  "ReportFindings",
  "ScheduleWakeup",
  "Skill",
  "TaskStop",
  "ToolSearch",
  "WebFetch",
  "WebSearch",
  "Write",
  "mcp__cydo__Answer",
  "mcp__cydo__Ask",
  "mcp__cydo__AskUserQuestion",
  "mcp__cydo__Request",
  "mcp__cydo__SwitchMode",
  "mcp__cydo__Task",
  "mcp__cydo__UnsandboxedCommand",
];

test(
  "a Claude session has exactly the reviewed set of tools",
  { tag: "@claude-only" },
  async ({ page }) => {
    const toolLists: string[][] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        let data: { event?: { type?: string; tools?: string[] } };
        try {
          data = JSON.parse(frame.payload.toString());
        } catch {
          return; // not a JSON frame
        }
        if (data.event?.type === "session/init" && data.event.tools)
          toolLists.push(data.event.tools);
      });
    });

    await enterSession(page);
    await sendMessage(page, 'reply with "tool list probe"');
    await expect(assistantText(page, "tool list probe")).toBeVisible();

    expect(toolLists.length).toBeGreaterThan(0);
    expect([...toolLists[0]!].sort()).toEqual([...expectedTools].sort());
  },
);
