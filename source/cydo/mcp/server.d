/// MCP proxy server.
///
/// Runs as `cydo --mcp-server`. Handles the MCP JSON-RPC protocol
/// over stdio and proxies tool calls to the CyDo backend via HTTP.
module cydo.mcp.server;

version (Posix):

import std.process : environment;
import std.stdio : stderr;

import ae.net.asockets : socketManager;
import ae.net.http.client : httpPost;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.stdio : stdioLDJsonRpcConnection;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.array : asBytes;
import ae.utils.json : JSONFragment, jsonParse, toJson, JSONPartial;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.mcp.binding : mcpToolListJson;
import cydo.mcp.tools : CydoTools;

/// Entry point for MCP server mode.
void runMcpServer()
{
	auto tid = environment.get("CYDO_TID", "0");
	auto port = environment.get("CYDO_PORT", "3456");
	auto backendUrl = "http://127.0.0.1:" ~ port ~ "/mcp/call";

	stderr.writefln("CyDo MCP proxy starting (tid=%s, backend=:%s)", tid, port);

	auto conn = stdioLDJsonRpcConnection();
	auto codec = new JsonRpcCodec(conn);

	codec.handleRequest = (JsonRpcRequest request) {
		return handleRequest(request, backendUrl, tid);
	};

	socketManager.loop();
	stderr.writefln("CyDo MCP proxy exiting");
}

private:

/// MCP protocol version
enum MCP_PROTOCOL_VERSION = "2024-11-05";

/// tools/list result JSON (generated at compile time from the CydoTools interface)
enum TOOLS_LIST_JSON = mcpToolListJson!CydoTools;

Promise!JsonRpcResponse handleRequest(JsonRpcRequest request, string backendUrl, string tid)
{
	switch (request.method)
	{
		case "initialize":
			return resolve(JsonRpcResponse.success(request.id,
				InitializeResult(MCP_PROTOCOL_VERSION, ServerInfo("cydo", "0.1.0"))));

		case "notifications/initialized":
			// Notification — codec will filter the response (no id)
			return resolve(JsonRpcResponse.success(request.id));

		case "tools/list":
			return resolve(JsonRpcResponse.success(request.id, JSONFragment(TOOLS_LIST_JSON)));

		case "tools/call":
			return handleToolsCall(request, backendUrl, tid);

		default:
			return resolve(JsonRpcResponse.failure(request.id,
				JsonRpcErrorCode.methodNotFound, "Method not found: " ~ request.method));
	}
}

/// Forward tools/call to the backend via HTTP POST.
Promise!JsonRpcResponse handleToolsCall(JsonRpcRequest request, string backendUrl, string tid)
{
	auto promise = new Promise!JsonRpcResponse;

	// Parse the MCP tools/call params: {name: string, arguments: object}
	ToolsCallParams params;
	try
		params = request.params.json.jsonParse!ToolsCallParams;
	catch (Exception e)
	{
		promise.fulfill(JsonRpcResponse.failure(request.id,
			JsonRpcErrorCode.invalidParams, "Invalid tools/call params: " ~ e.msg));
		return promise;
	}

	// Build backend request
	auto backendRequest = BackendToolCall(tid, params.name, params.arguments);
	auto bodyJson = toJson(backendRequest);

	stderr.writefln("MCP proxy: tools/call %s → backend", params.name);

	httpPost(backendUrl, DataVec(Data(bodyJson.asBytes)), "application/json",
		(Data response) {
			try
			{
				// Backend returns {content: [{type, text}], isError: bool}
				// Pass through as the tools/call result
				auto responseText = cast(string) response.toGC();
				promise.fulfill(JsonRpcResponse.success(request.id, JSONFragment(responseText)));
			}
			catch (Exception e)
				promise.fulfill(JsonRpcResponse.failure(request.id,
					JsonRpcErrorCode.internalError, "Failed to parse backend response: " ~ e.msg));
		},
		(string error) {
			promise.fulfill(JsonRpcResponse.failure(request.id,
				JsonRpcErrorCode.internalError, "Backend connection failed: " ~ error));
		}
	);

	return promise;
}

// ---- JSON structures ----

@JSONPartial
struct ToolsCallParams
{
	string name;
	JSONFragment arguments;
}

struct BackendToolCall
{
	string tid;
	string tool;
	JSONFragment args;
}

struct ServerInfo
{
	import ae.utils.json : JSONName;
	string name;
	@JSONName("version") string version_;
}

struct InitializeResult
{
	string protocolVersion;
	ServerInfo serverInfo;
	ServerCapabilities capabilities;
}

struct ServerCapabilities
{
	ToolsCapability tools;
}

struct ToolsCapability {}
