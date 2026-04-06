// Mock API server for CyDo integration tests.
// Implements:
//   POST /v1/messages      — Anthropic Messages API (Claude Code)
//   POST /v1/responses      — OpenAI Responses API  (Codex CLI)

import { createServer } from "node:http";
import { matchPattern } from "./patterns.mjs";

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

function streamToolUseResponse(
  res,
  toolName,
  input,
  model = "claude-sonnet-4-20250514",
) {
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
    content_block: {
      type: "tool_use",
      id: toolId,
      name: toolName,
      input: {},
      caller: { type: "direct" },
    },
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

function streamMultiToolUseResponse(
  res,
  toolNames,
  inputs,
  model = "claude-sonnet-4-20250514",
) {
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
  for (let i = 0; i < toolNames.length; i++) {
    const toolId = nextToolId();
    sseEvent(res, "content_block_start", {
      type: "content_block_start",
      index: i,
      content_block: {
        type: "tool_use",
        id: toolId,
        name: toolNames[i],
        input: {},
        caller: { type: "direct" },
      },
    });
    sseEvent(res, "content_block_delta", {
      type: "content_block_delta",
      index: i,
      delta: {
        type: "input_json_delta",
        partial_json: JSON.stringify(inputs[i]),
      },
    });
    sseEvent(res, "content_block_stop", {
      type: "content_block_stop",
      index: i,
    });
  }
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

function oaiStreamTextResponse(res, text, totalTokensOverride) {
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
      usage: {
        input_tokens: 10,
        input_tokens_details: null,
        output_tokens: text.length,
        output_tokens_details: null,
        total_tokens: totalTokensOverride ?? 10 + text.length,
      },
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
      usage: {
        input_tokens: 10,
        input_tokens_details: null,
        output_tokens: 20,
        output_tokens_details: null,
        total_tokens: 30,
      },
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
        usage: {
          input_tokens: 10,
          input_tokens_details: null,
          output_tokens: 20,
          output_tokens_details: null,
          total_tokens: 30,
        },
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
      usage: {
        input_tokens: 10,
        input_tokens_details: null,
        output_tokens: 20,
        output_tokens_details: null,
        total_tokens: 30,
      },
    },
  });
  res.end();
}

function oaiStreamCustomToolCallResponse(res, name, input) {
  const respId = nextRespId();
  const callId = nextCallId();
  // Extract raw patch string from the pattern's input object
  const rawInput =
    typeof input === "object" &&
    input !== null &&
    typeof input.input === "string"
      ? input.input
      : typeof input === "string"
        ? input
        : JSON.stringify(input);

  const itemId = `ctc_mock_${callId}`;

  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  // 1. output_item.added — item in progress with empty input
  oaiSseEvent(res, "response.output_item.added", {
    type: "response.output_item.added",
    output_index: 0,
    item: {
      id: itemId,
      type: "custom_tool_call",
      status: "in_progress",
      call_id: callId,
      name,
      input: "",
    },
  });
  // 2. Single delta with full input (real API streams token by token)
  oaiSseEvent(res, "response.custom_tool_call_input.delta", {
    type: "response.custom_tool_call_input.delta",
    delta: rawInput,
    item_id: itemId,
    output_index: 0,
  });
  // 3. input.done with final assembled input
  oaiSseEvent(res, "response.custom_tool_call_input.done", {
    type: "response.custom_tool_call_input.done",
    input: rawInput,
    item_id: itemId,
    output_index: 0,
  });
  // 4. output_item.done — completed item with full input
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    output_index: 0,
    item: {
      id: itemId,
      type: "custom_tool_call",
      status: "completed",
      call_id: callId,
      name,
      input: rawInput,
    },
  });
  oaiSseEvent(res, "response.completed", {
    type: "response.completed",
    response: {
      id: respId,
      usage: {
        input_tokens: 10,
        input_tokens_details: null,
        output_tokens: 20,
        output_tokens_details: null,
        total_tokens: 30,
      },
    },
  });
  res.end();
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

// Check if the input array contains tool output AFTER the last user message.
// Multi-turn inputs include tool outputs from previous turns, so we must only
// check for tool outputs that belong to the current (most recent) turn.
function hasToolOutput(input) {
  let lastUserIdx = -1;
  for (let i = input.length - 1; i >= 0; i--) {
    if (input[i].type === "message" && input[i].role === "user") {
      lastUserIdx = i;
      break;
    }
  }
  return input
    .slice(lastUserIdx + 1)
    .some(
      (item) =>
        item.type === "local_shell_call_output" ||
        item.type === "function_call_output" ||
        item.type === "custom_tool_call_output" ||
        item.type === "mcp_tool_call_output",
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
    const intent = userText === null ? null : matchPattern(userText);
    console.log(
      `[mock-api] [responses] model=${requestedModel} userText=${JSON.stringify(userText)} isToolOutput=${isToolOutput} inputLen=${input.length}`,
    );

    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });

    // If input contains tool output, check for multi-command flow before
    // defaulting to "Done."
    if (isToolOutput) {
      // Multi-background-command: if original message was "run two background
      // commands" and we've only sent one exec_command so far, send the second.
      const origText = extractLastUserTextFromInput(input);
      if (origText && /run two background commands/i.test(origText)) {
        const fcOutputCount = input.filter(
          (i) => i.type === "function_call_output",
        ).length;
        if (fcOutputCount < 2) {
          oaiStreamFunctionCallResponse(res, "exec_command", {
            cmd: "sleep 10",
            yield_time_ms: 500,
          });
          return;
        }
      }
      oaiStreamTextResponse(res, "Done.");
      return;
    }

    if (userText === null) {
      oaiStreamTextResponse(res, "Done.");
      return;
    }

    // Detect compaction/summarization requests — Codex sends a summarization
    // prompt containing "CONTEXT CHECKPOINT COMPACTION" when compacting.
    if (userText.includes("CONTEXT CHECKPOINT COMPACTION")) {
      console.log(
        "[mock-api] [responses] detected compaction summarization request",
      );
      oaiStreamTextResponse(
        res,
        "Conversation summary: previous context compacted.",
      );
      return;
    }

    if (intent.type === "check_context") {
      const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
      const haystack = JSON.stringify(parsed);
      const found = haystack.includes(needle);
      oaiStreamTextResponse(res, found ? "context-check-passed" : "context-check-failed");
      return;
    } else if (intent.type === "text") {
      oaiStreamTextResponse(res, intent.text, intent.totalTokens);
    } else if (intent.type === "quick_yield_shell") {
      oaiStreamFunctionCallResponse(res, "exec_command", {
        cmd: intent.command,
        yield_time_ms: 1,
      });
    } else if (intent.type === "background_shell") {
      // exec_command with short yield_time_ms — command keeps running after yield
      oaiStreamFunctionCallResponse(res, "exec_command", {
        cmd: intent.command,
        yield_time_ms: 500,
      });
    } else if (intent.type === "shell") {
      if (intent.command.match(/sleep\s+\d+/)) {
        // Simulate blocking execution: send output_item.done immediately but
        // delay response.completed by 5s so turnInProgress stays true while
        // the test sends a second message.
        oaiStreamShellCallResponseDelayed(res, intent.command, 5000);
      } else {
        oaiStreamShellCallResponse(res, intent.command);
      }
    } else if (intent.name === "apply_patch") {
      oaiStreamCustomToolCallResponse(res, intent.name, intent.input);
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
        if (
          block.type === "text" &&
          !block.text.trimStart().startsWith("<system-reminder>")
        )
          return block.text;
      }
      // No user text found; signal tool_result if present
      if (msg.content.some((b) => b.type === "tool_result")) return null;
    }
  }
  return null;
}

function hasImageContent(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "user") continue;
    if (Array.isArray(msg.content)) {
      if (msg.content.some((b) => b.type === "image")) return true;
    }
    break;
  }
  return false;
}

function hasToolResult(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "user") continue;
    if (Array.isArray(msg.content)) {
      // Don't signal tool_result if there's also user text (e.g. a steering message)
      const hasUserText = msg.content.some(
        (b) =>
          b.type === "text" &&
          !b.text.trimStart().startsWith("<system-reminder>"),
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
    const hasImages = hasImageContent(messages);
    if (hasImages) {
      console.log(`[mock-api] image content detected`);
    }
    console.log(
      `[mock-api] model=${requestedModel} userText=${JSON.stringify(userText)} isToolResult=${isToolResult} msgCount=${messages.length}`,
    );
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
    if (hasImages && intent.type === "text") {
      intent.text = "image received";
    }

    if (intent.type === "check_context") {
      const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
      const haystack = JSON.stringify(parsed);
      const found = haystack.includes(needle);
      streamTextResponse(res, found ? "context-check-passed" : "context-check-failed", model);
      return;
    } else if (intent.type === "stall") {
      // Send message_start to begin the stream, then stall indefinitely.
      // The session stays alive (waiting for LLM) so tests can Kill it.
      sseEvent(res, "message_start", {
        type: "message_start",
        message: {
          id: nextMsgId(),
          type: "message",
          role: "assistant",
          content: [],
          model,
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 10, output_tokens: 0 },
        },
      });
      // Do NOT call res.end() — connection stays open until the process is killed.
    } else if (intent.type === "text") {
      streamTextResponse(res, intent.text, model);
    } else if (intent.type === "parallel_shell") {
      const toolNames = intent.commands.map(() => "Bash");
      const inputs = intent.commands.map((cmd) => ({
        command: cmd,
        description: "Running command",
      }));
      streamMultiToolUseResponse(res, toolNames, inputs, model);
    } else if (intent.type === "timed_shell") {
      streamToolUseResponse(
        res,
        "Bash",
        { command: intent.command, timeout: intent.timeout, description: "Running command" },
        model,
      );
    } else if (intent.type === "shell" || intent.type === "background_shell") {
      streamToolUseResponse(
        res,
        "Bash",
        { command: intent.command, description: "Running command" },
        model,
      );
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

  // Remote compact endpoint — Codex calls POST /v1/responses/compact when the
  // context window is exceeded. Return a minimal compacted history so Codex proceeds.
  if (url.pathname === "/v1/responses/compact" && req.method === "POST") {
    console.log("[mock-api] [responses/compact] remote compaction request");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ output: [] }));
    return;
  }

  // Models list — Codex calls GET /v1/models on startup
  if (url.pathname === "/v1/models" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        object: "list",
        data: [
          { id: "codex-mini-latest", object: "model", owned_by: "system" },
          { id: "o3", object: "model", owned_by: "system" },
          { id: "o4-mini", object: "model", owned_by: "system" },
        ],
      }),
    );
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
  const actualPort = server.address().port;
  console.log(
    `Mock API server (Anthropic + OpenAI) listening on http://127.0.0.1:${actualPort}`,
  );
});
