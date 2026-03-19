// Mock API server for CyDo integration tests.
// Implements:
//   POST /v1/messages      — Anthropic Messages API (Claude Code)
//   POST /v1/responses      — OpenAI Responses API  (Codex CLI)

import { createServer } from "node:http";

const PORT = parseInt(process.env.MOCK_API_PORT || "9000", 10);
let msgCounter = 0;
let toolCounter = 0;
let respCounter = 0;
let callCounter = 0;

function nextMsgId() {
  return `msg_mock_${String(++msgCounter).padStart(5, "0")}`;
}

function nextToolId() {
  return `toolu_mock_${String(++toolCounter).padStart(5, "0")}`;
}

function nextRespId() {
  return `resp_mock_${String(++respCounter).padStart(5, "0")}`;
}

function nextCallId() {
  return `call_mock_${String(++callCounter).padStart(5, "0")}`;
}

// SSE helpers
function sseEvent(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function streamTextResponse(res, text, model = "claude-sonnet-4-20250514") {
  const msgId = nextMsgId();
  sseEvent(res, "message_start", {
    type: "message_start",
    message: {
      id: msgId,
      type: "message",
      role: "assistant",
      content: [],
      model,
      stop_reason: null,
      stop_sequence: null,
      usage: { input_tokens: 10, output_tokens: 1 },
    },
  });
  sseEvent(res, "content_block_start", {
    type: "content_block_start",
    index: 0,
    content_block: { type: "text", text: "" },
  });
  sseEvent(res, "content_block_delta", {
    type: "content_block_delta",
    index: 0,
    delta: { type: "text_delta", text },
  });
  sseEvent(res, "content_block_stop", {
    type: "content_block_stop",
    index: 0,
  });
  sseEvent(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: "end_turn", stop_sequence: null },
    usage: { output_tokens: text.length },
  });
  sseEvent(res, "message_stop", { type: "message_stop" });
  res.end();
}

function streamToolUseResponse(res, toolName, input, model = "claude-sonnet-4-20250514") {
  const msgId = nextMsgId();
  const toolId = nextToolId();
  sseEvent(res, "message_start", {
    type: "message_start",
    message: {
      id: msgId,
      type: "message",
      role: "assistant",
      content: [],
      model,
      stop_reason: null,
      stop_sequence: null,
      usage: { input_tokens: 10, output_tokens: 1 },
    },
  });
  sseEvent(res, "content_block_start", {
    type: "content_block_start",
    index: 0,
    content_block: { type: "tool_use", id: toolId, name: toolName, input: {}, caller: { type: "direct" } },
  });
  sseEvent(res, "content_block_delta", {
    type: "content_block_delta",
    index: 0,
    delta: { type: "input_json_delta", partial_json: JSON.stringify(input) },
  });
  sseEvent(res, "content_block_stop", {
    type: "content_block_stop",
    index: 0,
  });
  sseEvent(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: "tool_use", stop_sequence: null },
    usage: { output_tokens: 20 },
  });
  sseEvent(res, "message_stop", { type: "message_stop" });
  res.end();
}

// ---------------------------------------------------------------------------
// OpenAI Responses API helpers (Codex CLI)
// ---------------------------------------------------------------------------

function oaiSseEvent(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function oaiStreamTextResponse(res, text) {
  const respId = nextRespId();
  const msgId = nextMsgId();
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  oaiSseEvent(res, "response.output_text.delta", {
    type: "response.output_text.delta",
    delta: text,
  });
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    item: {
      type: "message",
      role: "assistant",
      id: msgId,
      content: [{ type: "output_text", text }],
    },
  });
  oaiSseEvent(res, "response.completed", {
    type: "response.completed",
    response: {
      id: respId,
      usage: { input_tokens: 10, input_tokens_details: null, output_tokens: text.length, output_tokens_details: null, total_tokens: 10 + text.length },
    },
  });
  res.end();
}

function oaiStreamShellCallResponse(res, command) {
  const respId = nextRespId();
  const callId = nextCallId();
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    item: {
      type: "local_shell_call",
      call_id: callId,
      status: "completed",
      action: { type: "exec", command: ["sh", "-c", command] },
    },
  });
  oaiSseEvent(res, "response.completed", {
    type: "response.completed",
    response: {
      id: respId,
      usage: { input_tokens: 10, input_tokens_details: null, output_tokens: 20, output_tokens_details: null, total_tokens: 30 },
    },
  });
  res.end();
}

function oaiStreamShellCallResponseDelayed(res, command, delayMs) {
  const respId = nextRespId();
  const callId = nextCallId();
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    item: {
      type: "local_shell_call",
      call_id: callId,
      status: "completed",
      action: { type: "exec", command: ["sh", "-c", command] },
    },
  });
  setTimeout(() => {
    oaiSseEvent(res, "response.completed", {
      type: "response.completed",
      response: {
        id: respId,
        usage: { input_tokens: 10, input_tokens_details: null, output_tokens: 20, output_tokens_details: null, total_tokens: 30 },
      },
    });
    res.end();
  }, delayMs);
}

function oaiStreamFunctionCallResponse(res, name, args) {
  const respId = nextRespId();
  const callId = nextCallId();
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    item: {
      type: "function_call",
      call_id: callId,
      name,
      arguments: JSON.stringify(args),
    },
  });
  oaiSseEvent(res, "response.completed", {
    type: "response.completed",
    response: {
      id: respId,
      usage: { input_tokens: 10, input_tokens_details: null, output_tokens: 20, output_tokens_details: null, total_tokens: 30 },
    },
  });
  res.end();
}

// ---------------------------------------------------------------------------
// Protocol-agnostic pattern matching
// ---------------------------------------------------------------------------

// Match a user text against known patterns and return a structured intent.
// Returns one of:
//   { type: "text", text: string }
//   { type: "shell", command: string }
//   { type: "tool_call", name: string, input: object }
function matchPattern(userText) {
  // Suggestion generation — must be checked before other patterns
  // because the prompt contains abbreviated history that may match them.
  if (userText.startsWith("[SUGGESTION MODE:")) {
    return { type: "text", text: '["run the tests", "commit this"]' };
  }

  // Title generation subprocess — extract a recognizable title from the prompt
  if (userText.startsWith("Generate a concise title")) {
    const innerMatch = userText.match(/reply with "([^"]*)"/i);
    return { type: "text", text: innerMatch ? innerMatch[1] : "Test Task" };
  }

  // Backend restart nudge — acknowledge and respond with Done.
  if (userText.startsWith("[SYSTEM:")) {
    return { type: "text", text: "Done." };
  }

  let match;

  // "reply with "<text>""
  match = userText.match(/reply with "([^"]*)"/i);
  if (match) return { type: "text", text: match[1] };

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

  // "call task <type> <prompt>" → MCP Task tool call (create sub-task)
  match = userText.match(/call task (\S+) (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__Task", input: { tasks: [{ task_type: match[1].trim(), prompt: match[2].trim(), description: "Test task" }] } };

  // "call handoff <continuation> <prompt>" → MCP Handoff tool call
  match = userText.match(/call handoff (\S+) (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__Handoff", input: { continuation: match[1].trim(), prompt: match[2].trim() } };

  // "call askuserquestion <question>" → MCP AskUserQuestion tool call
  match = userText.match(/call askuserquestion (.*)/is);
  if (match) return { type: "tool_call", name: "mcp__cydo__AskUserQuestion", input: { questions: [{ header: "Test", question: match[1].trim(), options: [{ label: "Yes", description: "Confirm" }, { label: "No", description: "Deny" }], multiSelect: false }] } };

  // Default: echo back
  return { type: "text", text: userText };
}

// Extract the last user text from the Responses API input array.
function extractLastUserTextFromInput(input) {
  for (let i = input.length - 1; i >= 0; i--) {
    const item = input[i];
    if (item.type === "message" && item.role === "user") {
      if (Array.isArray(item.content)) {
        for (const span of item.content) {
          if (span.type === "input_text") return span.text;
        }
      }
      if (typeof item.content === "string") return item.content;
    }
  }
  return null;
}

// Check if the input array contains tool output (local_shell_call_output or function_call_output).
function hasToolOutput(input) {
  return input.some(
    (item) => item.type === "local_shell_call_output" || item.type === "function_call_output",
  );
}

function handleResponses(req, res) {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Invalid JSON" }));
      return;
    }

    const input = parsed.input || [];
    const requestedModel = parsed.model || "unknown";
    const userText = extractLastUserTextFromInput(input);
    const isToolOutput = hasToolOutput(input);
    console.log(`[mock-api] [responses] model=${requestedModel} userText=${JSON.stringify(userText)} isToolOutput=${isToolOutput} inputLen=${input.length}`);

    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });

    // If input contains tool output, respond with "Done."
    if (isToolOutput) {
      oaiStreamTextResponse(res, "Done.");
      return;
    }

    if (userText === null) {
      oaiStreamTextResponse(res, "Done.");
      return;
    }

    const intent = matchPattern(userText);

    if (intent.type === "text") {
      oaiStreamTextResponse(res, intent.text);
    } else if (intent.type === "shell") {
      if (intent.command.match(/sleep\s+\d+/)) {
        // Simulate blocking execution: send output_item.done immediately but
        // delay response.completed by 5s so turnInProgress stays true while
        // the test sends a second message.
        oaiStreamShellCallResponseDelayed(res, intent.command, 5000);
      } else {
        oaiStreamShellCallResponse(res, intent.command);
      }
    } else {
      // tool_call — names are already correct for the OpenAI/Codex protocol
      oaiStreamFunctionCallResponse(res, intent.name, intent.input);
    }
  });
}

// ---------------------------------------------------------------------------
// Anthropic Messages API helpers (Claude Code)
// ---------------------------------------------------------------------------

// Extract the last user text from the messages array.
// Skips <system-reminder> blocks injected by Claude Code.
function extractLastUserText(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "user") continue;
    if (typeof msg.content === "string") return msg.content;
    if (Array.isArray(msg.content)) {
      // Find user text first — steering messages may appear alongside tool_results
      for (const block of msg.content) {
        if (block.type === "text" && !block.text.trimStart().startsWith("<system-reminder>"))
          return block.text;
      }
      // No user text found; signal tool_result if present
      if (msg.content.some((b) => b.type === "tool_result")) return null;
    }
  }
  return null;
}

function hasToolResult(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "user") continue;
    if (Array.isArray(msg.content)) {
      // Don't signal tool_result if there's also user text (e.g. a steering message)
      const hasUserText = msg.content.some(
        (b) => b.type === "text" && !b.text.trimStart().startsWith("<system-reminder>"),
      );
      if (hasUserText) return false;
      return msg.content.some((b) => b.type === "tool_result");
    }
    return false;
  }
  return false;
}

function handleMessages(req, res) {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Invalid JSON" }));
      return;
    }

    const messages = parsed.messages || [];
    const requestedModel = parsed.model || "unknown";
    const userText = extractLastUserText(messages);
    const isToolResult = hasToolResult(messages);
    console.log(`[mock-api] model=${requestedModel} userText=${JSON.stringify(userText)} isToolResult=${isToolResult} msgCount=${messages.length}`);
    const model = requestedModel;
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });

    // If last message contains tool_result, respond with "Done."
    if (isToolResult) {
      streamTextResponse(res, "Done.", model);
      return;
    }

    if (userText === null) {
      streamTextResponse(res, "Done.", model);
      return;
    }

    const intent = matchPattern(userText);

    if (intent.type === "text") {
      streamTextResponse(res, intent.text, model);
    } else if (intent.type === "shell") {
      streamToolUseResponse(res, "Bash", { command: intent.command, description: "Running command" }, model);
    } else {
      // tool_call — map generic names to Anthropic tool names
      let toolName = intent.name;
      let input = intent.input;
      if (intent.name === "write_file") {
        toolName = "Write";
        input = { file_path: intent.input.path, content: intent.input.content };
      } else if (intent.name === "read_file") {
        toolName = "Read";
        input = { file_path: intent.input.path };
      }
      streamToolUseResponse(res, toolName, input, model);
    }
  });
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  console.log(`[mock-api] ${req.method} ${url.pathname}`);

  // Health check
  if (url.pathname === "/api/hello" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  // Messages API (handles /v1/messages and /v1/messages?beta=true)
  if (url.pathname === "/v1/messages" && req.method === "POST") {
    handleMessages(req, res);
    return;
  }

  // Responses API (OpenAI / Codex CLI)
  if (url.pathname === "/v1/responses" && req.method === "POST") {
    handleResponses(req, res);
    return;
  }

  // Models list — Codex calls GET /v1/models on startup
  if (url.pathname === "/v1/models" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      object: "list",
      data: [
        { id: "codex-mini-latest", object: "model", owned_by: "system" },
        { id: "o3", object: "model", owned_by: "system" },
        { id: "o4-mini", object: "model", owned_by: "system" },
      ],
    }));
    return;
  }

  // Token counting — return a dummy count
  if (url.pathname === "/v1/messages/count_tokens" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ input_tokens: 100 }));
    });
    return;
  }

  // Catch-all: return 404
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Not found" }));
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Mock API server (Anthropic + OpenAI) listening on http://127.0.0.1:${PORT}`);
});
