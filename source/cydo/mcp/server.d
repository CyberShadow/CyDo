/// MCP proxy server.
///
/// Runs as `cydo --mcp-server`. Handles the MCP JSON-RPC protocol
/// over stdio and proxies tool calls to the CyDo backend via HTTP.
module cydo.mcp.server;

version (Posix):

import std.process : environment;
import std.stdio : stderr;

import ae.net.asockets : socketManager;
import ae.net.http.client : HttpClient;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.stdio : stdioLDJsonRpcConnection;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.array : asBytes;
import ae.utils.json : JSONFragment, jsonParse, toJson, JSONPartial;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

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

/// Build the final tools/list JSON by substituting placeholders.
string buildToolsListJson()
{
	import std.array : replace;
	import cydo.mcp.binding : jsonEscapeRuntime, mcpToolListJson;

	// Cache the template — generated once via toJson on ToolsList structs.
	// Contains {{creatable_task_types}} placeholder, substituted below.
	static string toolsTemplate;
	if (toolsTemplate is null)
		toolsTemplate = mcpToolListJson!CydoTools();

	auto creatableTypes = environment.get("CYDO_CREATABLE_TYPES", "(none available)");
	// Value is substituted inside a JSON string, so it must be JSON-escaped
	return toolsTemplate.replace("{{creatable_task_types}}", jsonEscapeRuntime(creatableTypes));
}

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
			return resolve(JsonRpcResponse.success(request.id, JSONFragment(buildToolsListJson())));

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

	// Use HttpClient with no timeout — sub-tasks can run for minutes/hours
	import ae.net.http.common : HttpRequest, HttpResponse;
	import core.time : Duration;

	auto httpReq = new HttpRequest;
	httpReq.resource = backendUrl;
	httpReq.method = "POST";
	httpReq.headers["Content-Type"] = "application/json";
	httpReq.data = DataVec(Data(bodyJson.asBytes));

	auto client = new HttpClient(Duration.zero);
	client.handleResponse = (HttpResponse response, string disconnectReason) {
		if (response is null)
		{
			promise.fulfill(JsonRpcResponse.failure(request.id,
				JsonRpcErrorCode.internalError, "Backend connection failed: " ~ disconnectReason));
			return;
		}
		try
		{
			import ae.sys.dataset : joinData;
			auto responseText = cast(string) response.data[].joinData().toGC();
			promise.fulfill(JsonRpcResponse.success(request.id, JSONFragment(responseText)));
		}
		catch (Exception e)
			promise.fulfill(JsonRpcResponse.failure(request.id,
				JsonRpcErrorCode.internalError, "Failed to parse backend response: " ~ e.msg));
	};
	client.request(httpReq);

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
