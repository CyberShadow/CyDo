import { createInterface } from "readline";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

for await (const line of rl) {
  if (!line.trim()) {
    process.stdout.write(line + "\n");
    continue;
  }

  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    process.stdout.write(line + "\n");
    continue;
  }

  // Inject top-level extra field on all events
  obj._test_extra = "top_level";

  // Inject extra field on each content block for assistant events
  if (obj.type === "assistant" && obj.message && Array.isArray(obj.message.content)) {
    for (const block of obj.message.content) {
      block._test_extra_block = "content_block";
    }
  }

  // Inject extra field inside toolUseResult for user events with tool results
  // Claude Code may use either camelCase or snake_case for the field name
  if (obj.type === "user") {
    if (obj.toolUseResult && typeof obj.toolUseResult === "object") {
      obj.toolUseResult._test_extra_result = "tool_result";
    } else if (obj.tool_use_result && typeof obj.tool_use_result === "object") {
      obj.tool_use_result._test_extra_result = "tool_result";
    }
  }

  process.stdout.write(JSON.stringify(obj) + "\n");
}
