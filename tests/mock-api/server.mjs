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
  oaiSseEvent(res, "response.output_item.added", {
    type: "response.output_item.added",
    output_index: 0,
    item: {
      type: "message",
      role: "assistant",
      id: msgId,
      content: [],
    },
  });
  oaiSseEvent(res, "response.output_text.delta", {
    type: "response.output_text.delta",
    delta: text,
  });
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    output_index: 0,
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

function oaiStreamLegacyMalformedTextResponse(res, text, totalTokensOverride) {
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

function oaiStreamFunctionCallResponse(res, name, args, totalTokensOverride) {
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
        total_tokens: totalTokensOverride ?? 30,
      },
    },
  });
  res.end();
}

function oaiStreamMultiFunctionCallResponse(res, names, argsList) {
  const respId = nextRespId();
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  for (let i = 0; i < names.length; i++) {
    const callId = nextCallId();
    oaiSseEvent(res, "response.output_item.done", {
      type: "response.output_item.done",
      output_index: i,
      item: {
        type: "function_call",
        call_id: callId,
        name: names[i],
        arguments: JSON.stringify(argsList[i]),
      },
    });
  }
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

function oaiStreamWebSearchCallResponse(res, query, queries) {
  const respId = nextRespId();
  const wsId = `ws_mock_${nextCallId()}`;
  oaiSseEvent(res, "response.created", {
    type: "response.created",
    response: { id: respId },
  });
  // 1. Item added (in_progress, no action yet)
  oaiSseEvent(res, "response.output_item.added", {
    type: "response.output_item.added",
    output_index: 0,
    item: {
      id: wsId,
      type: "web_search_call",
      status: "in_progress",
    },
  });
  // 2. State: in_progress
  oaiSseEvent(res, "response.web_search_call.in_progress", {
    type: "response.web_search_call.in_progress",
    output_index: 0,
    item_id: wsId,
  });
  // 3. State: searching
  oaiSseEvent(res, "response.web_search_call.searching", {
    type: "response.web_search_call.searching",
    output_index: 0,
    item_id: wsId,
  });
  // 4. State: completed
  oaiSseEvent(res, "response.web_search_call.completed", {
    type: "response.web_search_call.completed",
    output_index: 0,
    item_id: wsId,
  });
  // 5. Final item with action containing query/queries
  oaiSseEvent(res, "response.output_item.done", {
    type: "response.output_item.done",
    output_index: 0,
    item: {
      id: wsId,
      type: "web_search_call",
      status: "completed",
      action: {
        type: "search",
        query: query,
        queries: queries || [query],
      },
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
function isCydoTaskReminderText(text) {
  return (
    typeof text === "string" &&
    text.trimStart().startsWith("[SYSTEM: Post-compaction task mode reminder]")
  );
}

function isModeAReminderText(text) {
  return (
    isCydoTaskReminderText(text) &&
    text.includes("CYDO_SYSTEM_PROMPT_MODE_A_MARKER")
  );
}

function isModeBReminderText(text) {
  return (
    isCydoTaskReminderText(text) &&
    text.includes("CYDO_SYSTEM_PROMPT_MODE_B_MARKER")
  );
}

function extractUserTextSpan(item) {
  if (!item || item.type !== "message" || item.role !== "user") return null;
  if (Array.isArray(item.content)) {
    for (const span of item.content) {
      if (span.type === "input_text") return span.text;
    }
  }
  if (typeof item.content === "string") return item.content;
  return null;
}

function extractLastUserTextFromInput(input) {
  for (let i = input.length - 1; i >= 0; i--) {
    const text = extractUserTextSpan(input[i]);
    if (text !== null) return text;
  }
  return null;
}

function extractLastNonReminderUserTextFromInput(input) {
  for (let i = input.length - 1; i >= 0; i--) {
    const text = extractUserTextSpan(input[i]);
    if (text === null) continue;
    if (!isCydoTaskReminderText(text)) return text;
  }
  return null;
}

// Check if the input array contains tool output AFTER the last user message.
// Multi-turn inputs include tool outputs from previous turns, so we must only
// check for tool outputs that belong to the current (most recent) turn.
function hasToolOutput(input) {
  let lastUserIdx = -1;
  for (let i = input.length - 1; i >= 0; i--) {
    const text = extractUserTextSpan(input[i]);
    if (text === null) continue;
    if (isCydoTaskReminderText(text)) continue;
    lastUserIdx = i;
    break;
  }
  if (lastUserIdx === -1) {
    for (let i = input.length - 1; i >= 0; i--) {
      const text = extractUserTextSpan(input[i]);
      if (text === null) continue;
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
    const intentText =
      isCydoTaskReminderText(userText)
        ? (extractLastNonReminderUserTextFromInput(input) ?? userText)
        : userText;
    const isToolOutput = hasToolOutput(input);
    const intent = intentText === null ? null : matchPattern(intentText);
    console.log(
      `[mock-api] [responses] model=${requestedModel} userText=${JSON.stringify(userText)} intentText=${JSON.stringify(intentText)} isToolOutput=${isToolOutput} inputLen=${input.length}`,
    );

    // Codex compaction reminder fixture:
    // `call switchmode check_old_user_absent` should only proceed when the
    // in-flight reminder already reached the model request.
    if (
      intent?.type === "tool_call" &&
      intent.name === "mcp__cydo__SwitchMode" &&
      intent.input?.continuation === "check_old_user_absent" &&
      !isModeAReminderText(userText)
    ) {
      oaiStreamTextResponse(res, "switchmode-reminder-missing");
      return;
    }

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
      const origText =
        extractLastNonReminderUserTextFromInput(input) ??
        extractLastUserTextFromInput(input);
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
      if (origText && /codex filechange update fixture/i.test(origText)) {
        // Keep this path malformed on purpose: stderr-handling.spec.ts relies on
        // Codex surfacing a process/stderr payload for this fixture.
        oaiStreamLegacyMalformedTextResponse(res, "Done.");
        return;
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
      const isAutonomousContinuationProbe =
        typeof intentText === "string" &&
        intentText.includes("AUTONOMOUS_REMINDER_PROBE");
      if (isAutonomousContinuationProbe) {
        oaiStreamTextResponse(
          res,
          isModeBReminderText(userText)
            ? "autonomous-reminder-observed"
            : "autonomous-reminder-missing",
        );
        return;
      }
      const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
      const haystack = JSON.stringify(parsed);
      const found = haystack.includes(needle);
      oaiStreamTextResponse(res, found ? "context-check-passed" : "context-check-failed");
      return;
    } else if (intent.type === "check_user_text") {
      const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
      const found = typeof userText === "string" && userText.includes(needle);
      oaiStreamTextResponse(res, found ? "context-check-passed" : "context-check-failed");
      return;
    } else if (intent.type === "stall") {
      // Send response.created to begin the stream, then stall indefinitely.
      // The session stays alive (waiting for LLM) so tests can kill it.
      oaiSseEvent(res, "response.created", {
        type: "response.created",
        response: { id: nextRespId() },
      });
      // Do NOT call res.end() — connection stays open until the process is killed.
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
    } else if (intent.type === "multi_tool_call") {
      // For the OpenAI/Codex protocol, only send the first tool call.
      // Codex doesn't support MCP + shell calls in parallel, and the
      // deferral mechanism is exercised even with a single Answer call.
      const first = intent.tool_calls[0];
      oaiStreamFunctionCallResponse(res, first.name, first.input);
    } else if (intent.type === "autonomous_compaction_switchmode") {
      oaiStreamFunctionCallResponse(
        res,
        "mcp__cydo__SwitchMode",
        { continuation: "check_new_autonomous" },
        500000,
      );
    } else if (intent.name === "apply_patch") {
      oaiStreamCustomToolCallResponse(res, intent.name, intent.input);
    } else if (intent.type === "web_search") {
      oaiStreamWebSearchCallResponse(res, intent.query, [intent.query]);
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

// Find the original (first) user text in the conversation — used to detect
// multi-step sequences when the last user message is a tool_result.
function findOriginalUserText(messages) {
  for (const msg of messages) {
    if (msg.role !== "user") continue;
    if (typeof msg.content === "string") return msg.content;
    if (Array.isArray(msg.content)) {
      for (const block of msg.content) {
        if (
          block.type === "text" &&
          !block.text.trimStart().startsWith("<system-reminder>")
        )
          return block.text;
      }
    }
  }
  return null;
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

    // If last message contains tool_result, check for multi-step sequences
    // before defaulting to "Done."
    if (isToolResult) {
      const origText = findOriginalUserText(messages);
      if (origText && /run orphan then switchmode/i.test(origText)) {
        // Step 2: after the timed Bash command completes, call SwitchMode.
        // Only do this on the first tool_result (3 messages: user, assistant/bash, user/result).
        // Subsequent tool_results (from SwitchMode rejection etc.) get "Done."
        // so Claude can yield its turn and attempt to exit.
        if (messages.length <= 3) {
          streamToolUseResponse(res, "mcp__cydo__SwitchMode", { continuation: "plan" }, model);
          return;
        }
      }
      if (origText && /switchmode after child asks/i.test(origText) && messages.length <= 3) {
        // Step 2: parent receives Task tool result containing the child's question.
        // Only fire on the first tool result (messages.length == 3: initial user,
        // assistant Task call, user Task result with question). Subsequent tool results
        // in the same session (e.g. the SwitchMode result itself at messages.length==5)
        // must fall through to "Done." so the session can exit and the mode switch fires.
        // The guard also prevents the plan_mode continuation (which carries over the full
        // history) from looping back and calling SwitchMode('plan') again.
        streamToolUseResponse(res, "mcp__cydo__SwitchMode", { continuation: "plan" }, model);
        return;
      }
      if (origText &&
          /handoff while child asks/i.test(origText) &&
          /Task prompt:.*test_handoff_with_children/.test(origText)) {
        // This is the test_handoff_with_children child task (not the parent conversation).
        // Step 2: child receives Task result with grandchild question → try Handoff (rejected).
        // Step 3: child receives Handoff error → answer the pending question (qid=1).
        // Steps distinguished by message count.
        if (messages.length <= 3) {
          // First tool result: question arrived, try Handoff.
          streamToolUseResponse(
            res,
            "mcp__cydo__Handoff",
            { continuation: "done", prompt: "handoff-while-child-asks-prompt" },
            model,
          );
          return;
        } else if (messages.length <= 5) {
          // Second tool result: Handoff was rejected, answer the grandchild's question.
          // Extract the real qid from the prior Task tool result that delivered the question.
          const askedQid = (() => {
            for (const m of messages) {
              if (m.role !== "user" || !Array.isArray(m.content)) continue;
              for (const part of m.content) {
                if (part.type !== "tool_result") continue;
                const text =
                  typeof part.content === "string"
                    ? part.content
                    : Array.isArray(part.content)
                      ? part.content.map((c) => c.text ?? "").join("")
                      : "";
                const match = text.match(
                  /"status"\s*:\s*"question"[^}]*"qid"\s*:\s*(\d+)/,
                );
                if (match) return parseInt(match[1], 10);
              }
            }
            return null;
          })();
          if (askedQid === null) {
            streamTextResponse(res, "Done.", model);
            return;
          }
          streamToolUseResponse(
            res,
            "mcp__cydo__Answer",
            { qid: askedQid, message: "handoff-test-answered" },
            model,
          );
          return;
        }
      }
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
    } else if (intent.type === "check_user_text") {
      const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
      const found = typeof userText === "string" && userText.includes(needle);
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
    } else if (intent.type === "multi_tool_call") {
      const toolNames = intent.tool_calls.map((tc) => tc.name);
      const inputs = intent.tool_calls.map((tc) => tc.input);
      streamMultiToolUseResponse(res, toolNames, inputs, model);
    } else if (intent.type === "orphan_then_switchmode") {
      // Step 1: run sleep 999 with a short timeout — the timeout causes Claude
      // to background the sleep, then the tool_result triggers step 2 (SwitchMode).
      streamToolUseResponse(
        res,
        "Bash",
        { command: "sleep 999", timeout: 2000, description: "Running command" },
        model,
      );
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
