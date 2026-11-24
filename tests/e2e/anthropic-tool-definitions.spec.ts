import { existsSync, readFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

type AnthropicCaptureSchema = {
  type?: string;
  description?: string;
  items?: AnthropicCaptureSchema;
  properties?: Record<string, AnthropicCaptureSchema>;
};

type AnthropicCaptureTool = {
  name: string | null;
  description: string | null;
  input_schema: AnthropicCaptureSchema | null;
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
    (tool): tool is AnthropicCaptureTool & { name: string } =>
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
  expect(taskTool!.description).toContain(
    "Each created child appears in the CyDo task tree; the returned `tid` opens that child session.",
  );
  expect(taskTool!.description).toContain(
    "After a restart, CyDo resumes in-flight children and keeps unfinished batches grouped. Unanswered questions and recovered results are queued again and delivered like any other event.",
  );
  expect(taskTool!.description).toContain(
    "Accepted multi-task batches launch every child before waiting, so the children run concurrently.",
  );
  expect(taskTool!.description).toContain(
    "Once every child settles, the batch result contains one item per requested task in request order, regardless of completion order.",
  );
  expect(taskTool!.input_schema?.properties?.tasks?.items?.properties?.prompt?.description).toBe(
    "The child task prompt; see the session's Create Sub-Tasks guidance for context requirements",
  );

  const askTool = cydoTools.find((tool) => tool.name === "mcp__cydo__Ask");
  const answerTool = cydoTools.find((tool) => tool.name === "mcp__cydo__Answer");
  expect(askTool?.description).toContain(
    "The answer to your question may arrive through a later call.",
  );
  expect(answerTool?.description).toContain(
    'After a successful Answer, the call returns `status: "delivered"` immediately unless you owe no other received question an answer and are still waiting for a Task batch result or for a reply or failure to your own question. In that case, it waits for the next event.',
  );
  for (const tool of [taskTool!, askTool!, answerTool!]) {
    expect(tool.description).toContain(
      "Any blocked Task, Ask, or Answer call returns the next event in arrival order.",
    );
    expect(tool.description).toContain("the child `tid`s in the `tasks` list for batch results.");
    expect(tool.description).not.toContain("returns early with a `qid`");
    expect(tool.description).not.toContain("pauses your task until the target responds");
  }
});
