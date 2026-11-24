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

import ae.net.asockets : ConnectionAdapter, DisconnectType, IConnection, socketManager;
import ae.net.http.client : HttpClient, UnixConnector;
import ae.net.jsonrpc.binding : jsonRpcDispatcher, RPCFlatten, RPCName, RPCNotification;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.stdio : stdioLDJsonRpcConnection;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.timing : setInterval, TimerTask;
import ae.utils.array : asBytes;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, toJson, jsonParse, JSONPartial;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcException, JsonRpcRequest, JsonRpcResponse;
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
	auto codec = new JsonRpcCodec(new McpStdioConnection(conn));

	auto impl = new McpServerImpl(socketPath, tid, (JsonRpcRequest request) {
		codec.sendNotification(request);
	});
	codec.handleRequest = &impl.handleRequest;

	socketManager.loop();
	infof("CyDo MCP proxy exiting");
}

private:

/// MCP protocol version
enum MCP_PROTOCOL_VERSION = "2024-11-05";

/// MCP 2024-11-05 predates batch support.
final class McpStdioConnection : ConnectionAdapter
{
	this(IConnection connection) { super(connection); }

	override void onReadData(Data data)
	{
		import std.algorithm.searching : canFind;

		size_t start;
		while (start < data.length && " \t\r\n".canFind(cast(char) data[start]))
			start++;
		if (start < data.length && data[start] == '[')
		{
			auto error = JsonRpcResponse.failure(SO(null), JsonRpcErrorCode.invalidRequest,
				"JSON-RPC batches are not supported");
			send(Data(error.toJson().asBytes));
			return;
		}
		super.onReadData(data);
	}
}

/// Build the final tools/list JSON by substituting placeholders.
string buildToolsListJson()
{
	import std.array : split;
	import cydo.mcp.binding : buildToolsListJson;

	auto includeStr = environment.get("CYDO_INCLUDE_TOOLS", "");
	string[] includeTools = includeStr.length > 0 ? includeStr.split(",") : null;

	auto placeholders = jsonParse!(string[string])(environment["CYDO_TOOL_PLACEHOLDERS"]);
	return buildToolsListJson!CydoTools(placeholders, includeTools);
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

	@RPCNotification
	@RPCName("notifications/cancelled")
	Promise!void notificationsCancelled(CancelledParams params);

	@RPCName("resources/list")
	Promise!SO resourcesList();

	@RPCName("resources/templates/list")
	Promise!SO resourcesTemplatesList();

	@RPCName("prompts/list")
	Promise!SO promptsList();
}

final class InFlightCall
{
	UnixConnector connector;
	HttpClient client;
	ProgressKeepalive keepalive;
}

class McpServerImpl : McpProtocol
{
	private string socketPath;
	private string tid;
	private InFlightCall[string] inFlight;
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

	Promise!JsonRpcResponse handleRequest(JsonRpcRequest request)
	{
		if (request.method != "tools/call")
			return jsonRpcDispatcher!McpProtocol(this).dispatch(request);

		ToolsCallParams params;
		try
			params = request.params.deserializeTo!ToolsCallParams;
		catch (Exception e)
			return resolve(JsonRpcResponse.failure(request.id, JsonRpcErrorCode.invalidParams, e.msg));

		try
			return toolsCall(request.id, params)
				.then((SO result) => JsonRpcResponse.success(request.id, result))
				.except((Exception e) {
					if (auto rpcError = cast(JsonRpcException) e)
						return JsonRpcResponse.failure(request.id, rpcError.error);
					return JsonRpcResponse.failure(request.id, JsonRpcErrorCode.internalError, e.msg);
				});
		catch (Exception e)
			return resolve(JsonRpcResponse.failure(request.id, JsonRpcErrorCode.internalError, e.msg));
	}

	Promise!void notificationsCancelled(CancelledParams params)
	{
		auto id = params.requestId.toJson();
		if (auto entry = id in inFlight)
		{
			auto call = *entry;
			finishCall(id, call);
			// An ordinary disconnect makes HttpClient reconnect for a queued request.
			call.connector.getConnection().disconnect("MCP call cancelled", DisconnectType.error);
		}
		return resolve();
	}

	private void finishCall(string id, InFlightCall call)
	{
		if (!inFlight.remove(id))
			return;
		call.client.handleResponse = null;
		if (call.keepalive)
			call.keepalive.cancel();
	}

	Promise!SO toolsCall(SO requestId, ToolsCallParams params)
	{
		auto promise = new Promise!SO;

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

		auto id = requestId.toJson();
		auto call = new InFlightCall;
		call.connector = new UnixConnector(socketPath);
		call.client = new HttpClient(Duration.zero, call.connector);
		inFlight[id] = call;
		scope (failure) finishCall(id, call);
		if (params.meta.progressToken)
			call.keepalive = startProgressKeepalive(params.meta.progressToken);
		call.client.handleResponse = (HttpResponse response, string disconnectReason) {
			finishCall(id, call);

			if (response is null)
			{
				promise.reject(new Exception("Harness connection failed: " ~ disconnectReason));
				return;
			}
			try
			{
				import ae.sys.dataset : joinData;
				auto responseText = cast(string) response.data[].joinData().toGC();
				if (response.status / 100 != 2)
				{
					warningf("MCP proxy: backend returned HTTP %d", response.status);
					promise.reject(new Exception("Harness returned HTTP " ~ to!string(response.status)));
					return;
				}
				promise.fulfill(responseText.jsonParse!SO);
			}
			catch (Exception e)
				promise.reject(new Exception("Failed to parse harness response: " ~ e.msg));
		};
		call.client.request(httpReq);

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
struct CancelledParams
{
	SO requestId;
}

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
	import ae.net.asockets : ConnectionState;
	import ae.sys.dataset : joinData;

	static class TestConnection : IConnection
	{
		ReadDataHandler receive;
		string[] sent;

		@property ConnectionState state() { return ConnectionState.connected; }

		void send(scope Data[] data, int priority)
		{
			sent ~= cast(string) data.joinData().toGC();
		}
		alias send = IConnection.send;

		void disconnect(string reason = defaultDisconnectReason,
			DisconnectType type = DisconnectType.requested)
		{
			assert(false, reason);
		}
		@property void handleConnect(ConnectHandler value) {}
		@property void handleReadData(ReadDataHandler value) { receive = value; }
		@property void handleDisconnect(DisconnectHandler value) {}
		@property void handleBufferFlushed(BufferFlushedHandler value) {}
	}

	auto connection = new TestConnection;
	auto codec = new JsonRpcCodec(new McpStdioConnection(connection));
	string[] dispatched;
	codec.handleRequest = (JsonRpcRequest request) {
		dispatched ~= request.method;
		return resolve(JsonRpcResponse.success(request.id, "pong"));
	};

	connection.receive(Data((" \t" ~
		`[{"jsonrpc":"2.0","method":"ping","id":1},{"jsonrpc":"2.0","method":"notify"}]`).asBytes));
	assert(dispatched.length == 0, "batch requests reached the dispatcher");
	assert(connection.sent.length == 1, "expected a single response to the batch");
	auto error = connection.sent[0].jsonParse!JsonRpcResponse;
	assert(error.isError && error.error.get.code == JsonRpcErrorCode.invalidRequest);
	assert(error.id.toJson() == "null");

	connection.receive(Data(`{"jsonrpc":"2.0","method":"ping","id":2}`.asBytes));
	socketManager.loop();
	assert(dispatched == ["ping"]);
	assert(connection.sent.length == 2);
	auto response = connection.sent[1].jsonParse!JsonRpcResponse;
	assert(!response.isError && response.id.toJson() == "2");
	assert(response.result.toJson() == `"pong"`);
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

unittest
{
	import std.array : array, replicate;
	import ae.sys.timing : mainTimer;

	auto proxy = new McpServerImpl("/" ~ "x".replicate(256), "17", (JsonRpcRequest) {
		assert(false, "unexpected progress notification");
	});
	auto request = `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"Ask","arguments":{},"_meta":{"progressToken":42}}}`
		.jsonParse!JsonRpcRequest;

	auto pendingTimers = mainTimer.pendingTasks().array;
	auto result = proxy.handleRequest(request);
	assert(proxy.inFlight.length == 0, "synchronous failure left a call in flight");
	assert(mainTimer.pendingTasks().array == pendingTimers, "synchronous failure leaked a timer");

	JsonRpcResponse response;
	result.then((JsonRpcResponse value) { response = value; }).ignoreResult();
	socketManager.loop();

	assert(response.id.toJson() == "7");
	assert(response.isError && response.error.get.code == JsonRpcErrorCode.internalError);
}

unittest
{
	import core.time : msecs;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.socket : AddressFamily, AddressInfo, ProtocolType, SocketType, UnixAddress;
	import ae.net.http.common : HttpRequest;
	import ae.net.http.responseex : HttpResponseEx;
	import ae.net.http.server : HttpServer, HttpServerConnection;
	import ae.sys.timing : setTimeout;

	auto socketPath = buildPath(tempDir(), "cydo-mcp-proxy-" ~ thisProcessID.to!string ~ ".sock");
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);
	auto backend = new HttpServer;
	backend.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
		cast(ProtocolType) 0, new UnixAddress(socketPath), socketPath)]);
	auto proxy = new McpServerImpl(socketPath, "17", (JsonRpcRequest) {
		assert(false, "unexpected progress notification");
	});

	void cancel(int id)
	{
		JsonRpcRequest notification;
		notification.method = "notifications/cancelled";
		notification.params = toJson(CancelledParams(SO(id))).jsonParse!SO;
		proxy.handleRequest(notification).ignoreResult();
	}

	enum result = `{"content":[{"type":"text","text":"tool output"}]}`;
	JsonRpcRequest call(int id)
	{
		JsonRpcRequest request;
		request.method = "tools/call";
		request.id = SO(id);
		request.params = (id == 6
			? `{"name":"Read","arguments":{},"_meta":{"progressToken":42}}`
			: `{"name":"Ask","arguments":{},"_meta":{"progressToken":42}}`).jsonParse!SO;
		return request;
	}

	bool timedOut;
	HttpClient outstandingClient;
	auto deadline = setTimeout({
		timedOut = true;
		backend.close();
		outstandingClient.disconnect("MCP proxy test timed out");
	}, 2.seconds);
	JsonRpcResponse[] responses;
	void recordResponse(JsonRpcResponse response)
	{
		if (timedOut)
			return;
		responses ~= response;
		assert(responses.length == 1);
		assert(response.id.toJson() == "8");
		assert(!response.isError);
		assert(response.result.toJson() == result);
		deadline.cancel();
		backend.close();
	}

	bool backendSawDisconnect;
	int backendRequests;
	backend.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		import ae.sys.dataset : joinData;
		assert(request.resource == "/mcp/call");
		auto body = cast(string) request.data[].joinData().toGC();
		assert(body.jsonParse!BackendToolCall.tool == "Ask");
		backendRequests++;
		if (backendRequests == 2)
		{
			conn.sendResponse((new HttpResponseEx).serveData(result));
			return;
		}
		assert(backendRequests == 1);

		auto keepalive = proxy.inFlight["7"].keepalive;
		assert(keepalive.timer.isWaiting());
		cancel(999);
		assert(keepalive.timer.isWaiting());

		void awaitDisconnect()
		{
			if (timedOut)
				return;
			if (conn.connected)
			{
				setTimeout(&awaitDisconnect, 1.msecs);
				return;
			}
			backendSawDisconnect = true;
			assert(!keepalive.timer.isWaiting());
			proxy.handleRequest(call(8)).then(&recordResponse).ignoreResult();
			outstandingClient = proxy.inFlight["8"].client;
		}

		// Check that the backend stays connected after the unknown cancellation.
		setTimeout({
			assert(conn.connected);
			cancel(7);
			awaitDisconnect();
		}, 1.msecs);
	};

	proxy.handleRequest(call(6)).then((JsonRpcResponse) {
		assert(false, "call cancelled before sending produced a JSON-RPC response");
	}).ignoreResult();
	auto unsent = proxy.inFlight["6"];
	cancel(6);
	assert("6" !in proxy.inFlight);
	assert(!unsent.keepalive.timer.isWaiting());
	assert(unsent.client.handleResponse is null);

	proxy.handleRequest(call(7)).then((JsonRpcResponse) {
		assert(false, "cancelled call produced a JSON-RPC response");
	}).ignoreResult();
	outstandingClient = proxy.inFlight["7"].client;
	socketManager.loop();
	assert(!timedOut, "MCP proxy test timed out");
	assert(backendSawDisconnect);
	assert(backendRequests == 2);
	assert(responses.length == 1);
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
