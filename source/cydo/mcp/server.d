/// MCP proxy server.
///
/// Runs as `cydo --mcp-server`. Handles the MCP JSON-RPC protocol
/// over stdio and proxies tool calls to the CyDo backend via a UNIX socket.
module cydo.mcp.server;

version (Posix):

import std.conv : to;
import std.process : environment;
import std.logger : infof, tracef, warningf;

import core.time : Duration, seconds;

import ae.net.asockets : socketManager;
import ae.net.http.client : HttpClient, UnixConnector;
import ae.net.jsonrpc.binding : jsonRpcDispatcher, RPCFlatten, RPCName, RPCNotification;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.stdio : stdioLDJsonRpcConnection;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.timing : setInterval, TimerTask;
import ae.utils.array : asBytes;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, toJson, jsonParse, JSONPartial;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);

import cydo.mcp.tools : CydoTools;

/// Entry point for MCP server mode.
void runMcpServer()
{
	auto tid = environment.get("CYDO_TID", "0");
	auto socketPath = environment.get("CYDO_SOCKET", "");

	infof("CyDo MCP proxy starting (tid=%s, socket=%s)", tid, socketPath);

	auto conn = stdioLDJsonRpcConnection();
	auto codec = new JsonRpcCodec(conn);

	auto impl = new McpServerImpl(socketPath, tid, (JsonRpcRequest request) {
		codec.sendNotification(request);
	});
	auto dispatcher = jsonRpcDispatcher!McpProtocol(impl);
	codec.handleRequest = &dispatcher.dispatch;

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

interface McpProtocol
{
	@RPCName("initialize")
	Promise!InitializeResult initialize();

	@RPCNotification
	@RPCName("notifications/initialized")
	Promise!void notificationsInitialized();

	@RPCName("tools/list")
	Promise!SO toolsList();

	@RPCName("tools/call")
	Promise!SO toolsCall(ToolsCallParams params);

	@RPCName("resources/list")
	Promise!SO resourcesList();

	@RPCName("resources/templates/list")
	Promise!SO resourcesTemplatesList();

	@RPCName("prompts/list")
	Promise!SO promptsList();
}

class McpServerImpl : McpProtocol
{
	private string socketPath;
	private string tid;
	private void delegate(JsonRpcRequest request) sendNotification;

	this(string socketPath, string tid, void delegate(JsonRpcRequest request) sendNotification)
	{
		this.socketPath = socketPath;
		this.tid = tid;
		this.sendNotification = sendNotification;
	}

	Promise!InitializeResult initialize()
	{
		return resolve(InitializeResult(MCP_PROTOCOL_VERSION, ServerInfo("cydo", "0.1.0")));
	}

	Promise!void notificationsInitialized()
	{
		return resolve();
	}

	Promise!SO toolsList()
	{
		return resolve(buildToolsListJson().jsonParse!SO);
	}

	Promise!SO toolsCall(ToolsCallParams params)
	{
		auto promise = new Promise!SO;
		ProgressKeepalive keepalive;
		if (params.meta.progressToken)
			keepalive = startProgressKeepalive(params.meta.progressToken);
		void cleanup()
		{
			if (keepalive !is null)
				keepalive.cancel();
		}
		void finishSuccess(SO result)
		{
			cleanup();
			promise.fulfill(result);
		}
		void finishError(Exception error)
		{
			cleanup();
			promise.reject(error);
		}

		auto backendRequest = BackendToolCall(tid, params.name, JSONFragment(params.arguments.toJson()));
		auto bodyJson = toJson(backendRequest);

		tracef("MCP proxy: tools/call %s → backend", params.name);

		import ae.net.http.common : HttpRequest, HttpResponse;
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
				finishError(new Exception("Harness connection failed: " ~ disconnectReason));
				return;
			}
			try
			{
				import ae.sys.dataset : joinData;
				auto responseText = cast(string) response.data[].joinData().toGC();
				if (response.status / 100 != 2)
				{
					warningf("MCP proxy: backend returned HTTP %d", response.status);
					finishError(new Exception("Harness returned HTTP " ~ to!string(response.status)));
					return;
				}
				finishSuccess(responseText.jsonParse!SO);
			}
			catch (Exception e)
				finishError(new Exception("Failed to parse harness response: " ~ e.msg));
		};
		client.request(httpReq);

		return promise;
	}

	private ProgressKeepalive startProgressKeepalive(SO progressToken)
	{
		auto keepalive = new ProgressKeepalive(progressToken, sendNotification);
		keepalive.start(60.seconds);
		return keepalive;
	}

	Promise!SO resourcesList()
	{
		return resolve(`{"resources":[]}`.jsonParse!SO);
	}

	Promise!SO resourcesTemplatesList()
	{
		return resolve(`{"resourceTemplates":[]}`.jsonParse!SO);
	}

	Promise!SO promptsList()
	{
		return resolve(`{"prompts":[]}`.jsonParse!SO);
	}
}

// ---- JSON structures ----

@RPCFlatten @JSONPartial
struct ToolsCallParams
{
	string name;
	SO arguments;
	@JSONName("_meta") @JSONOptional ToolsCallMeta meta;
}

@JSONPartial
struct ToolsCallMeta
{
	@JSONOptional SO progressToken;
}

private JsonRpcRequest buildProgressNotification(SO progressToken, int progress)
{
	JsonRpcRequest request;
	request.method = "notifications/progress";
	request.params = toJson(ProgressNotificationParams(progressToken, progress)).jsonParse!SO;
	return request;
}

private struct ProgressNotificationParams
{
	SO progressToken;
	int progress;
}

private final class ProgressKeepalive
{
	private SO progressToken;
	private void delegate(JsonRpcRequest request) sendNotification;
	private int progress;
	TimerTask timer;

	this(SO progressToken, void delegate(JsonRpcRequest request) sendNotification)
	{
		this.progressToken = progressToken;
		this.sendNotification = sendNotification;
	}

	void start(Duration interval)
	{
		timer = setInterval({ tick(); }, interval);
	}

	void tick()
	{
		if (timer is null || !timer.isWaiting())
			return;
		sendNotification(buildProgressNotification(progressToken, ++progress));
	}

	void cancel()
	{
		if (timer !is null && timer.isWaiting())
			timer.cancel();
	}
}

unittest
{
	auto params = `{"name":"Task","arguments":{},"_meta":{"progressToken":42,"x-codex-turn-metadata":{}}}`
		.jsonParse!ToolsCallParams;
	auto noTokenParams = `{"name":"Task","arguments":{}}`.jsonParse!ToolsCallParams;
	assert(toJson(params.meta.progressToken) == "42");
	assert(!noTokenParams.meta.progressToken);

	auto stringToken = buildProgressNotification(`"token"`.jsonParse!SO, 1);
	auto integerToken = buildProgressNotification(`42`.jsonParse!SO, 2);

	assert(toJson(stringToken) ==
		`{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"token","progress":1}}`);
	assert(toJson(integerToken) ==
		`{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":42,"progress":2}}`);

	JsonRpcRequest[] notifications;
	auto first = new ProgressKeepalive(`"first"`.jsonParse!SO, (JsonRpcRequest request) {
		notifications ~= request;
	});
	auto second = new ProgressKeepalive(`2`.jsonParse!SO, (JsonRpcRequest request) {
		notifications ~= request;
	});
	first.start(60.seconds);
	second.start(60.seconds);
	assert(first.timer.isWaiting());
	assert(second.timer.isWaiting());
	first.tick();
	second.tick();
	first.tick();
	first.cancel();
	assert(!first.timer.isWaiting());
	assert(second.timer.isWaiting());
	first.tick();
	second.cancel();
	assert(!second.timer.isWaiting());
	second.tick();
	assert(toJson(notifications) ==
		`[{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"first","progress":1}},{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":2,"progress":1}},{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"first","progress":2}}]`);
}

struct BackendToolCall
{
	string tid;
	string tool;
	JSONFragment args;
}

struct ServerInfo
{
	import ae.utils.serialization.json : JSONName;
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
