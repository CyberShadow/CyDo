import { existsSync, readFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

type AnthropicCaptureTool = {
  name: string | null;
  description: string | null;
};

type AnthropicCaptureRecord = {
  path: string;
  model: string;
  userText: string | null;
  isToolResult: boolean;
  tools: AnthropicCaptureTool[];
};

test("Claude forwards compact CyDo MCP descriptions to the Anthropic boundary", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  const probeText = "anthropic tool definitions boundary check";
  const capturePath = process.env.MOCK_ANTHROPIC_CAPTURE;
  if (!capturePath) {
    throw new Error("MOCK_ANTHROPIC_CAPTURE is unset");
  }

  const readCaptureRecords = (startLine = 0): AnthropicCaptureRecord[] => {
    if (!existsSync(capturePath)) {
      return [];
    }
    return readFileSync(capturePath, "utf8")
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .slice(startLine)
      .map((line) => JSON.parse(line) as AnthropicCaptureRecord);
  };
  const initialCaptureLineCount = readCaptureRecords().length;

  await enterSession(page);
  await sendMessage(page, probeText);
  await expect(
    assistantText(page, probeText),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect
    .poll(() => {
      return readCaptureRecords(initialCaptureLineCount).find((record) =>
        !record.isToolResult &&
        record.tools.some(
          (tool) =>
            typeof tool.name === "string" &&
            tool.name.startsWith("mcp__cydo__"),
        ),
      )
        ? "found"
        : "missing";
    }, { timeout: responseTimeout(agentType) })
    .toBe("found");

  const cydoRecord = readCaptureRecords(initialCaptureLineCount)
    .filter((record) =>
      !record.isToolResult &&
      record.tools.some(
        (tool) =>
          typeof tool.name === "string" && tool.name.startsWith("mcp__cydo__"),
      ),
    )
    .at(-1);

  expect(cydoRecord, `No CyDo MCP tools captured in ${capturePath}`).toBeDefined();

  const cydoTools = cydoRecord!.tools.filter(
    (tool): tool is { name: string; description: string | null } =>
      typeof tool.name === "string" && tool.name.startsWith("mcp__cydo__"),
  );
  expect(cydoTools.length).toBeGreaterThan(0);

  for (const tool of cydoTools) {
    expect(tool.description, `${tool.name} description should be present`).not.toBeNull();
    expect(tool.description!.trim(), `${tool.name} description should not be empty`).not.toBe("");
    expect(tool.description!).not.toContain("[truncated]");
    expect(tool.description!).not.toContain("...[truncated]");
    expect(tool.description!.length).toBeLessThanOrEqual(2000);
  }

  const taskTool = cydoTools.find((tool) => tool.name === "mcp__cydo__Task");
  expect(taskTool, "Expected mcp__cydo__Task in captured CyDo tool list").toBeDefined();
  expect(taskTool!.description).toMatch(/follow-up|ask|qid|answer/i);
});
