// Shared pattern matching module for mock API servers.
// Imported by server.mjs (Claude/Codex) and copilot-proxy.mjs (Copilot).

// Match a user text against known patterns and return a structured intent.
// Returns one of:
//   { type: "text", text: string }
//   { type: "shell", command: string }
//   { type: "background_shell", command: string }
//   { type: "tool_call", name: string, input: object }
//   { type: "stall" }  — keep the LLM connection open indefinitely (for kill tests)
export function matchPattern(userText) {
  // Suggestion generation — must be checked before other patterns
  // because the prompt contains abbreviated history that may match them.
  // Uses includes() because Copilot prepends <current_datetime>...</current_datetime>
  // before the actual content, so startsWith() would fail.
  if (userText.includes("[SUGGESTION MODE:")) {
    return { type: "text", text: '["run the tests", "commit this"]' };
  }

  // Title generation subprocess — extract a recognizable title from the prompt.
  // Uses includes() for the same reason as SUGGESTION MODE above.
  if (userText.includes("Generate a concise title")) {
    const innerMatch = userText.match(/reply with "([^"]*)"/i);
    return { type: "text", text: innerMatch ? innerMatch[1] : "Test Task" };
  }

  // Backend restart nudge — acknowledge and respond with Done.
  // Uses includes() for the same reason as SUGGESTION MODE above.
  if (userText.includes("[SYSTEM:")) {
    return { type: "text", text: "Done." };
  }

  let match;

  // "reply with "<text>""
  match = userText.match(/reply with "([^"]*)"/i);
  if (match) return { type: "text", text: match[1] };

  // Task-creation patterns must come before "run command" because a task prompt
  // like "call 2 tasks research run command sleep 10" contains "run command" as
  // a substring, which would otherwise match the shell pattern first.

  // "call N tasks <type> <prompt>" → MCP Task tool call (create multiple sub-tasks)
  match = userText.match(/call (\d+) tasks (\S+) (.*)/is);
  if (match) {
    const count = parseInt(match[1]);
    const type = match[2].trim();
    const prompt = match[3].trim();
    const tasks = [];
    for (let i = 0; i < count; i++) {
      tasks.push({ task_type: type, prompt, description: `Test task ${i + 1}` });
    }
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: { tasks },
    };
  }

  // "call task <type> <prompt>" → MCP Task tool call (create sub-task)
  match = userText.match(/call task (\S+) (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__Task", input: { tasks: [{ task_type: match[1].trim(), prompt: match[2].trim(), description: "Test task" }] } };

  // "stall session" → keep LLM connection open without completing
  if (/^stall session\s*$/i.test(userText)) return { type: "stall" };

  // "run parallel commands" — two parallel tool_use blocks in a single response
  match = userText.match(/run parallel commands/i);
  if (match) return { type: "parallel_shell", commands: ["echo one", "echo two"] };

  // "run two background commands" — two sequential exec_command with yield_time_ms
  // (must come before single "run background command" to avoid substring match)
  match = userText.match(/run two background commands/i);
  if (match) return { type: "background_shell", command: "sleep 2" };

  // "run background command <cmd>" — exec_command with short yield_time_ms
  match = userText.match(/run background command (.+)/i);
  if (match) return { type: "background_shell", command: match[1].trim() };

  // "run command <cmd>"
  match = userText.match(/run command (.+)/i);
  if (match) return { type: "shell", command: match[1].trim() };

  // "create file <path> with content <text>"
  match = userText.match(/create file (\S+) with content (.+)/is);
  if (match) return { type: "tool_call", name: "write_file", input: { path: match[1], content: match[2] } };

  // "read file <path>"
  match = userText.match(/read file (\S+)/i);
  if (match) return { type: "tool_call", name: "read_file", input: { path: match[1] } };

  // "call switchmode <continuation>" → MCP SwitchMode tool call
  match = userText.match(/call switchmode (\S+)/i);
  if (match) return { type: "tool_call", name: "mcp__cydo__SwitchMode", input: { continuation: match[1] } };

  // "call handoff <continuation> <prompt>" → MCP Handoff tool call
  match = userText.match(/call handoff (\S+) (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__Handoff", input: { continuation: match[1].trim(), prompt: match[2].trim() } };

  // "call askuserquestion <question>" → MCP AskUserQuestion tool call
  match = userText.match(/call askuserquestion (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__AskUserQuestion", input: { questions: [{ header: "Test", question: match[1].trim(), options: [{ label: "Yes", description: "Confirm" }, { label: "No", description: "Deny" }], multiSelect: false }] } };

  // Default: echo back
  return { type: "text", text: userText };
}
