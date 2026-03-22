/// MCP proxy server.
///
/// Runs as `cydo --mcp-server`. Handles the MCP JSON-RPC protocol
/// over stdio and proxies tool calls to the CyDo backend via a UNIX socket.
module cydo.mcp.server;

version (Posix):

import std.conv : to;
import std.process : environment;
import std.logger : infof, tracef, warningf;

import ae.net.asockets : socketManager;
import ae.net.http.client : HttpClient, UnixConnector;
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
	auto socketPath = environment.get("CYDO_SOCKET", "");

	infof("CyDo MCP proxy starting (tid=%s, socket=%s)", tid, socketPath);

	auto conn = stdioLDJsonRpcConnection();
	auto codec = new JsonRpcCodec(conn);

	codec.handleRequest = (JsonRpcRequest request) {
		return handleRequest(request, socketPath, tid);
	};

	socketManager.loop();
	infof("CyDo MCP proxy exiting");
}

private:

/// MCP protocol version
enum MCP_PROTOCOL_VERSION = "2024-11-05";

/// Build the final tools/list JSON by substituting placeholders.
string buildToolsListJson()
{
	import std.array : split;
	import cydo.mcp.binding : buildToolsListJson;

	auto includeStr = environment.get("CYDO_INCLUDE_TOOLS", "");
	string[] includeTools = includeStr.length > 0 ? includeStr.split(",") : null;

	return buildToolsListJson!CydoTools([
		"creatable_task_types": environment.get("CYDO_CREATABLE_TYPES", ""),
		"switchmodes": environment.get("CYDO_SWITCHMODES", ""),
		"handoffs": environment.get("CYDO_HANDOFFS", ""),
	], includeTools);
}

Promise!JsonRpcResponse handleRequest(JsonRpcRequest request, string socketPath, string tid)
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
			return handleToolsCall(request, socketPath, tid);

		case "resources/list":
			return resolve(JsonRpcResponse.success(request.id,
				JSONFragment(`{"resources":[]}`)));

		case "resources/templates/list":
			return resolve(JsonRpcResponse.success(request.id,
				JSONFragment(`{"resourceTemplates":[]}`)));

		case "prompts/list":
			return resolve(JsonRpcResponse.success(request.id,
				JSONFragment(`{"prompts":[]}`)));

		default:
			return resolve(JsonRpcResponse.failure(request.id,
				JsonRpcErrorCode.methodNotFound, "Method not found: " ~ request.method));
	}
}

/// Forward tools/call to the backend via UNIX socket HTTP POST.
Promise!JsonRpcResponse handleToolsCall(JsonRpcRequest request, string socketPath, string tid)
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

	tracef("MCP proxy: tools/call %s → backend", params.name);

	// Connect to backend via UNIX socket — no timeout (sub-tasks can run for minutes/hours)
	import ae.net.http.common : HttpRequest, HttpResponse;
	import core.time : Duration;

	auto httpReq = new HttpRequest;
	httpReq.resource = "/mcp/call";
	httpReq.method = "POST";
	httpReq.headers["Content-Type"] = "application/json";
	httpReq.headers["Host"] = "localhost";
	httpReq.headers["Accept-Encoding"] = "identity"; // prevent server from compressing; client doesn't decompress
	httpReq.data = DataVec(Data(bodyJson.asBytes));

	auto client = new HttpClient(Duration.zero, new UnixConnector(socketPath));
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
			if (response.status / 100 != 2)
			{
				warningf("MCP proxy: backend returned HTTP %d", response.status);
				promise.fulfill(JsonRpcResponse.failure(request.id,
					JsonRpcErrorCode.internalError, "Backend returned HTTP " ~ to!string(response.status)));
				return;
			}
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
