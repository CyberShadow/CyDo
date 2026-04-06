// HTTPS CONNECT proxy for Copilot integration tests.
// Intercepts Copilot CLI's outbound HTTPS traffic via TLS termination.
//
// Usage: node copilot-proxy.mjs
// Then set HTTPS_PROXY=http://127.0.0.1:9001 and NODE_TLS_REJECT_UNAUTHORIZED=0
// in the process that runs the Copilot CLI.

import { createServer } from "node:http";
import { TLSSocket } from "node:tls";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { matchPattern } from "./patterns.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.COPILOT_PROXY_PORT || "9001", 10);

const tlsKey = readFileSync(join(__dirname, "certs/proxy.key"));
const tlsCert = readFileSync(join(__dirname, "certs/proxy.crt"));

let chatCallCounter = 0;
function nextChatId() {
  return `chatcmpl-mock-${String(++chatCallCounter).padStart(5, "0")}`;
}

let callIdCounter = 0;

function sendJson(socket, statusCode, statusText, body) {
  const bodyStr = JSON.stringify(body);
  const response =
    `HTTP/1.1 ${statusCode} ${statusText}\r\n` +
    `Content-Type: application/json\r\n` +
    `Content-Length: ${Buffer.byteLength(bodyStr)}\r\n` +
    `Connection: keep-alive\r\n` +
    `\r\n` +
    bodyStr;
  socket.write(response);
}

function sendSse(socket, chunks) {
  const body = chunks.map((c) => `data: ${typeof c === "string" ? c : JSON.stringify(c)}\n\n`).join("");
  const response =
    `HTTP/1.1 200 OK\r\n` +
    `Content-Type: text/event-stream\r\n` +
    `Cache-Control: no-cache\r\n` +
    `Transfer-Encoding: chunked\r\n` +
    `\r\n`;
  socket.write(response);
  // Write body as a single chunk then terminate chunked encoding
  const bodyBuf = Buffer.from(body);
  socket.write(`${bodyBuf.length.toString(16)}\r\n`);
  socket.write(bodyBuf);
  socket.write(`\r\n0\r\n\r\n`);
}

function handleTokenExchange(socket) {
  console.log("[copilot-proxy] token exchange");
  sendJson(socket, 200, "OK", {
    token: "mock_copilot_token",
    expires_at: 9999999999,
    refresh_in: 1500,
    sku: "free_limited_copilot",
    individual: true,
    telemetry: "disabled",
  });
}

const MODEL_CAPABILITIES = {
  limits: {
    max_prompt_tokens: 128000,
    max_output_tokens: 8192,
    max_context_window_tokens: 200000,
  },
  supports: { tool_calls: true, vision: false },
};

function handleModels(socket) {
  console.log("[copilot-proxy] models list");
  sendJson(socket, 200, "OK", {
    object: "list",
    data: [
      { id: "claude-sonnet-4.5", object: "model", name: "Claude Sonnet 4.5", model_picker_enabled: true, capabilities: MODEL_CAPABILITIES },
      { id: "claude-haiku-4.5", object: "model", name: "Claude Haiku 4.5", model_picker_enabled: true, capabilities: MODEL_CAPABILITIES },
      { id: "gpt-4.1", object: "model", name: "GPT-4.1", model_picker_enabled: true, capabilities: MODEL_CAPABILITIES },
    ],
  });
}

function handleChatCompletions(socket, body) {
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    sendJson(socket, 400, "Bad Request", { error: "Invalid JSON" });
    return;
  }

  const messages = parsed.messages || [];
  const tools = parsed.tools || [];

  // Log tool names on first call
  if (tools.length > 0) {
    const toolNames = tools.map(t => t.function?.name || t.name || "?").join(", ");
    console.log(`[copilot-proxy] chat completions tools: [${toolNames}]`);
  }

  // Log the message role sequence for diagnostics
  const msgRoles = messages.map(m => {
    const c = m.content;
    const cType = Array.isArray(c) ? c.map(b => b.type).join('+') : typeof c;
    return `${m.role}(${cType})`;
  }).join(', ');
  console.log(`[copilot-proxy] chat completions msgs: [${msgRoles}]`);

  // Detect tool-result follow-up: look for a role:"tool" message after the
  // last assistant message. Copilot may append another user message after the
  // tool result, so checking only the very last message is insufficient.
  let lastAssistantIdx = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === "assistant") { lastAssistantIdx = i; break; }
  }
  let toolResultMsg = null;
  if (lastAssistantIdx >= 0) {
    for (let i = lastAssistantIdx + 1; i < messages.length; i++) {
      if (messages[i].role === "tool") { toolResultMsg = messages[i]; break; }
    }
  }
  if (toolResultMsg) {
    console.log(`[copilot-proxy] tool-result follow-up: content=${JSON.stringify(toolResultMsg.content).slice(0, 200)}`);
    const chatId = nextChatId();
    sendSse(socket, [
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: "Done." }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      "[DONE]",
    ]);
    return;
  }

  let userText = null;
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role === "user") {
      if (typeof msg.content === "string") {
        userText = msg.content;
        break;
      }
      if (Array.isArray(msg.content)) {
        for (const part of msg.content) {
          if (part.type === "text") {
            userText = part.text;
            break;
          }
        }
        if (userText !== null) break;
      }
    }
  }

  console.log(`[copilot-proxy] chat completions userText=${JSON.stringify(userText)}`);

  const intent = userText !== null ? matchPattern(userText) : { type: "text", text: "Done." };
  const chatId = nextChatId();

  if (intent.type === "check_context") {
    const needle = Buffer.from(intent.needle, "base64").toString("utf-8");
    const haystack = JSON.stringify(parsed);
    const found = haystack.includes(needle);
    const resultText = found ? "context-check-passed" : "context-check-failed";
    sendSse(socket, [
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: resultText }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      "[DONE]",
    ]);
  } else if (intent.type === "text") {
    sendSse(socket, [
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: intent.text }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      "[DONE]",
    ]);
  } else if (intent.type === "stall") {
    // Send an initial SSE header and one empty assistant delta, then stall indefinitely.
    // The connection stays open so the copilot process keeps waiting for more data.
    const initialChunk = `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] })}\n\n`;
    const response =
      `HTTP/1.1 200 OK\r\n` +
      `Content-Type: text/event-stream\r\n` +
      `Cache-Control: no-cache\r\n` +
      `Transfer-Encoding: chunked\r\n` +
      `\r\n`;
    socket.write(response);
    const buf = Buffer.from(initialChunk);
    socket.write(`${buf.length.toString(16)}\r\n`);
    socket.write(buf);
    socket.write(`\r\n`);
    // Do NOT close the connection — leave it open so the process stalls.
  } else if (intent.type === "shell") {
    // Use the CyDo MCP Bash tool — copilot's native bash fails in the sandbox
    const callId = `call_mock_${String(++callIdCounter).padStart(3, "0")}`;
    sendSse(socket, [
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: null, tool_calls: [{ index: 0, id: callId, type: "function", function: { name: "cydo-Bash", arguments: "" } }] }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: JSON.stringify({ command: intent.command }) } }] }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      "[DONE]",
    ]);
  } else {
    // tool_call — translate mcp__cydo__Foo → cydo-Foo for copilot's MCP tool registry
    let toolName = intent.name;
    if (toolName.startsWith("mcp__cydo__")) {
      toolName = "cydo-" + toolName.slice("mcp__cydo__".length);
    }
    const callId = `call_mock_${String(++callIdCounter).padStart(3, "0")}`;
    sendSse(socket, [
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: null, tool_calls: [{ index: 0, id: callId, type: "function", function: { name: toolName, arguments: "" } }] }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: JSON.stringify(intent.input) } }] }, finish_reason: null }] },
      { id: chatId, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      "[DONE]",
    ]);
  }
}

function handleMcpReadonly(socket, body) {
  console.log(`[copilot-proxy] /mcp/readonly request: ${body.slice(0, 500)}`);
  let request;
  try {
    request = JSON.parse(body);
  } catch {
    sendJson(socket, 400, "Bad Request", { error: "Invalid JSON" });
    return;
  }

  // Notifications have no "id" field — send empty 200 to satisfy HTTP protocol
  if (!("id" in request)) {
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n");
    return;
  }

  const { id, method } = request;
  if (method === "initialize") {
    sendJson(socket, 200, "OK", {
      jsonrpc: "2.0", id,
      result: {
        protocolVersion: "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "github-mcp-readonly", version: "1.0.0" },
      },
    });
  } else if (method === "tools/list") {
    sendJson(socket, 200, "OK", { jsonrpc: "2.0", id, result: { tools: [] } });
  } else {
    sendJson(socket, 200, "OK", { jsonrpc: "2.0", id, result: {} });
  }
}

function handleDecryptedRequest(socket, host, method, path, body) {
  console.log(`[copilot-proxy] ${host} ${method} ${path}`);

  if (host === "api.github.com") {
    if (method === "GET" && path.startsWith("/copilot_internal/user")) {
      sendJson(socket, 200, "OK", {
        login: "test-user",
        id: 12345,
        copilot_plan: "business",
        chat_enabled: true,
        telemetry: "disabled",
        public_key_fingerprint: "mock",
        analytics_tracking_id: "mock-tracking-id",
        endpoints: {
          api: "https://api.githubcopilot.com",
          proxy: "https://copilot-proxy.githubusercontent.com",
        },
      });
      return;
    }
    if (method === "GET" && path.startsWith("/copilot_internal/v2/token")) {
      handleTokenExchange(socket);
      return;
    }
    if (method === "GET" && path.startsWith("/models")) {
      handleModels(socket);
      return;
    }
    // Suppress version check requests
    if (method === "GET" && path.includes("/releases/latest")) {
      sendJson(socket, 404, "Not Found", { message: "Not Found" });
      return;
    }
  } else if (host === "api.githubcopilot.com" || host === "copilot-proxy.githubusercontent.com") {
    if (method === "POST" && path.startsWith("/mcp/readonly")) {
      handleMcpReadonly(socket, body);
      return;
    }
    if (method === "POST" && (path.startsWith("/chat/completions") || path.startsWith("/v1/chat/completions"))) {
      handleChatCompletions(socket, body);
      return;
    }
    if (method === "GET" && path.startsWith("/models")) {
      handleModels(socket);
      return;
    }
  }

  console.log(`[copilot-proxy] 404 body: ${body.slice(0, 200)}`);
  sendJson(socket, 404, "Not Found", { error: "Not found" });
}

// Parse HTTP/1.x request from a buffer. Returns { method, path, headers, body } or null if incomplete.
function parseHttpRequest(buf) {
  const headerEnd = buf.indexOf("\r\n\r\n");
  if (headerEnd === -1) return null;

  const headerSection = buf.slice(0, headerEnd).toString();
  const lines = headerSection.split("\r\n");
  const [method, path] = lines[0].split(" ");
  const headers = {};
  for (let i = 1; i < lines.length; i++) {
    const colon = lines[i].indexOf(":");
    if (colon === -1) continue;
    headers[lines[i].slice(0, colon).toLowerCase().trim()] = lines[i].slice(colon + 1).trim();
  }

  const contentLength = parseInt(headers["content-length"] || "0", 10);
  const bodyStart = headerEnd + 4;
  const bodyEnd = bodyStart + contentLength;
  if (buf.length < bodyEnd) return null;

  return { method, path, headers, body: buf.slice(bodyStart, bodyEnd).toString(), end: bodyEnd };
}

const server = createServer();

server.on("connect", (req, clientSocket, head) => {
  const host = req.url.split(":")[0];
  console.log(`[copilot-proxy] CONNECT ${req.url}`);

  clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");

  const tlsSocket = new TLSSocket(clientSocket, {
    isServer: true,
    key: tlsKey,
    cert: tlsCert,
  });

  // If there's already buffered data from the client, put it back on the
  // underlying socket so the TLSSocket picks it up during the handshake.
  if (head && head.length > 0) {
    clientSocket.unshift(head);
  }

  let reqBuf = Buffer.alloc(0);

  tlsSocket.on("data", (chunk) => {
    reqBuf = Buffer.concat([reqBuf, chunk]);
    let parsed;
    while ((parsed = parseHttpRequest(reqBuf))) {
      reqBuf = reqBuf.slice(parsed.end);
      handleDecryptedRequest(tlsSocket, host, parsed.method, parsed.path, parsed.body);
    }
  });

  tlsSocket.on("error", (err) => {
    console.error(`[copilot-proxy] TLS error for ${host}:`, err.message);
  });
});

server.on("request", (req, res) => {
  // Plain HTTP requests — not expected for Copilot, but handle gracefully
  res.writeHead(400, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Use CONNECT for HTTPS" }));
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Copilot HTTPS proxy listening on http://127.0.0.1:${PORT}`);
});
