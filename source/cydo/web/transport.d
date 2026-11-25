module cydo.web.transport;

import std.conv : ConvException, to;
import std.file : exists, isFile, remove;
import std.logger : infof, warningf;
import std.path : buildPath;

import ae.net.asockets : ConnectionAdapter, DisconnectType, IConnection, onNextTick, socketManager;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection, HttpsServer;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;
import ae.sys.dataset : joinData;
import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.mcp : McpResult, ToolCallCancellation;
import cydo.mcp.payloads : McpContentItem, McpContentResult;
import cydo.runtime.launch.sandbox : runtimeDir;
import cydo.web.request_policy : checkRequestPolicy;

version (unittest) import core.exception : AssertError;
version (unittest) import core.time : msecs, seconds;
version (unittest) import std.file : exists, remove, tempDir;
version (unittest) import std.format : format;
version (unittest) import std.process : thisProcessID;
version (unittest) import std.socket : AddressFamily, AddressInfo, ProtocolType,
	SocketType, UnixAddress;
version (unittest) import ae.net.asockets : SocketConnection;
version (unittest) import ae.net.http.client : HttpClient, UnixConnector;
version (unittest) import ae.net.http.common : HttpResponse;
version (unittest) import ae.sys.timing : setTimeout;
version (unittest) import ae.sys.dataset : DataVec;
version (unittest) import ae.utils.array : asBytes;

package(cydo):

private enum webSocketResource = "/ws";

enum RawSourceLookupStatus
{
	ok,
	taskNotFound,
	seqOutOfRange,
	historyNotLoaded,
}

struct RawSourceLookupResult
{
	RawSourceLookupStatus status = RawSourceLookupStatus.ok;
	string raw;
}

enum LiveFileLookupStatus
{
	ok,
	taskNotFound,
	unavailable,
}

struct LiveFileLookupResult
{
	LiveFileLookupStatus status;
	string mediaType;
	immutable(ubyte)[] bytes;
	string reason;
}

struct WebSocketCallbacks
{
	void delegate(WebSocketAdapter ws) onAccepted;
	void delegate(WebSocketAdapter ws, string text) onMessage;
	void delegate(WebSocketAdapter ws, string reason, DisconnectType type) onDisconnected;
}

struct McpCallbacks
{
	Promise!McpResult delegate(string tool, string tid, string itemId, JSONFragment args, ToolCallCancellation cancellation) dispatchTool;
	bool delegate(string tid) interruptForPendingContinuation;
	void delegate(string tid, McpResult result) onDeliveryFailed;
	void delegate(string tid, McpResult result) onDelivered;
}

alias RawSourceReady = void delegate(RawSourceLookupResult);
alias LiveFileReady = void delegate(LiveFileLookupResult);

private final class McpConnection : ConnectionAdapter
{
	void delegate() onPendingCallDisconnect;

	this(IConnection transport) { super(transport); }

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		if (onPendingCallDisconnect)
			onPendingCallDisconnect();
	}
}

private final class McpHttpServer : HttpServer
{
	override IConnection adaptConnection(IConnection transport)
	{
		return new McpConnection(transport);
	}
}

class TransportAdapter
{
	private static immutable pwaPublicFiles = [
		"manifest.json",
		"icon-192.png",
		"icon-512.png",
		"apple-touch-icon.png",
		"favicon.svg",
	];

	private HttpServer server_;
	private HttpServer mcpServer_;
	private string mcpSocketPath_;
	private string webDistDir_;
	private string authUser_;
	private string authPass_;
	private WebSocketCallbacks websocketCallbacks_;
	private void delegate(int tid, size_t seq, RawSourceReady ready) rawSourceLookup_;
	private void delegate(int tid, string path, LiveFileReady ready) liveFileLookup_;
	private McpCallbacks mcpCallbacks_;

	this(
		string webDistDir,
		WebSocketCallbacks websocketCallbacks,
		void delegate(int tid, size_t seq, RawSourceReady ready) rawSourceLookup,
		void delegate(int tid, string path, LiveFileReady ready) liveFileLookup,
		McpCallbacks mcpCallbacks,
	)
	{
		webDistDir_ = webDistDir;
		websocketCallbacks_ = websocketCallbacks;
		rawSourceLookup_ = rawSourceLookup;
		liveFileLookup_ = liveFileLookup;
		mcpCallbacks_ = mcpCallbacks;
	}

	void setAuthCredentials(string user, string pass)
	{
		authUser_ = user;
		authPass_ = pass;
	}

	void startHttpServer(string sslCert, string sslKey)
	{
		if (sslCert || sslKey)
		{
			auto https = new HttpsServer();
			https.ctx.setCertificate(sslCert);
			https.ctx.setPrivateKey(sslKey);
			server_ = https;
		}
		else
			server_ = new HttpServer();

		server_.handleRequest = &handleRequest;
	}

	void startMcpSocket()
	{
		mcpSocketPath_ = buildPath(runtimeDir(), "mcp.sock");

		if (exists(mcpSocketPath_))
			remove(mcpSocketPath_);

		mcpServer_ = new McpHttpServer();
		mcpServer_.handleRequest = (HttpRequest request, HttpServerConnection conn) {
			if (request.resource == "/mcp/call" && request.method == "POST")
				handleMcpCall(request, conn);
			else
			{
				auto response = new HttpResponseEx();
				response.setStatus(HttpStatusCode.NotFound);
				conn.sendResponse(response);
			}
		};

		import std.socket : AddressFamily, AddressInfo, ProtocolType, SocketType, UnixAddress;

		auto addr = new UnixAddress(mcpSocketPath_);
		mcpServer_.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType) 0, addr, mcpSocketPath_)]);
		infof("MCP socket listening on %s", mcpSocketPath_);
	}

	@property HttpServer server()
	{
		return server_;
	}

	@property HttpServer mcpServer()
	{
		return mcpServer_;
	}

	@property string mcpSocketPath() const
	{
		return mcpSocketPath_;
	}

	@property bool authEnabled() const
	{
		return authUser_.length > 0 || authPass_.length > 0;
	}

	private void handleRequest(HttpRequest request, HttpServerConnection conn)
	{
		auto rejection = checkRequestPolicy(request.headers.getAll("Host"),
			request.headers.getAll("Origin"), request.resource == webSocketResource,
			authEnabled, request.resource);
		if (!rejection.isNull)
		{
			warningf("%s", rejection.get.logMessage);
			auto response = new HttpResponseEx();
			response.setStatus(rejection.get.status);
			conn.sendResponse(response.serveText(rejection.get.responseText));
			return;
		}

		auto resource = request.resource.length > 1 ? request.resource[1 .. $] : "";
		foreach (pub; pwaPublicFiles)
		{
			if (resource == pub)
			{
				auto response = new HttpResponseEx();
				response.serveFile(pub, webDistDir_);
				if (pub == "manifest.json")
					response.headers["Content-Type"] = "application/manifest+json";
				conn.sendResponse(response);
				return;
			}
		}

		if (!checkAuth(request, conn))
			return;

		if (request.resource == webSocketResource)
		{
			handleWebSocket(request, conn);
			return;
		}

		if (request.path == "/api/raw-source")
		{
			handleRawSourceRequest(request, conn);
			return;
		}

		if (request.path == "/api/live-file")
		{
			handleLiveFileRequest(request, conn);
			return;
		}

		auto response = new HttpResponseEx();
		auto path = request.resource[1 .. $];
		if (path == "" || !exists(webDistDir_ ~ path) || !isFile(webDistDir_ ~ path))
			path = "index.html";
		response.serveFile(path, webDistDir_);
		response.headers["Content-Security-Policy"] =
			"default-src 'self'; " ~
			"script-src 'self' 'wasm-unsafe-eval'; " ~
			"style-src 'self' 'unsafe-inline'; " ~
			"worker-src blob:; " ~
			"connect-src 'self' ws: wss:; " ~
			"img-src 'self' data:; " ~
			"object-src 'none'; " ~
			"base-uri 'self'; " ~
			"frame-ancestors 'none'";
		conn.sendResponse(response);
	}

	private bool checkAuth(HttpRequest request, HttpServerConnection conn)
	{
		if (!authEnabled)
			return true;
		auto response = new HttpResponseEx();
		if (!response.authorize(request, (reqUser, reqPass) => reqUser == authUser_ && reqPass == authPass_))
		{
			conn.sendResponse(response);
			return false;
		}
		return true;
	}

	private void handleWebSocket(HttpRequest request, HttpServerConnection conn)
	{
		WebSocketAdapter ws;
		try
			ws = accept(request, conn);
		catch (Exception e)
		{
			auto response = new HttpResponseEx();
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Bad WebSocket request: " ~ e.msg));
			return;
		}

		ws.sendBinary = true;
		websocketCallbacks_.onAccepted(ws);
		ws.handleReadData = (Data data) {
			auto text = cast(string) data.toGC();
			websocketCallbacks_.onMessage(ws, text);
		};
		ws.handleDisconnect = (string reason, DisconnectType type) {
			websocketCallbacks_.onDisconnected(ws, reason, type);
		};
	}

	private void handleRawSourceRequest(HttpRequest request, HttpServerConnection conn)
	{
		auto response = new HttpResponseEx();
		auto params = request.urlParameters;
		auto tidStr = params.get("tid", "");
		auto seqStr = params.get("seq", "");
		if (tidStr.length == 0 || seqStr.length == 0)
		{
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Missing tid or seq"));
			return;
		}

		int tid;
		size_t seq;
		try
		{
			tid = tidStr.to!int;
			seq = seqStr.to!size_t;
		}
		catch (ConvException)
		{
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Invalid tid or seq"));
			return;
		}

		// The reply may come later, and ae keeps reading requests off a
		// keep-alive connection while a bodyless one is unanswered. Hold the
		// next one back; sending the response resumes reading.
		conn.conn.handleReadData = null;
		rawSourceLookup_(tid, seq, (RawSourceLookupResult result) {
			if (!conn.connected)
				return;
			final switch (result.status)
			{
				case RawSourceLookupStatus.taskNotFound:
					response.setStatus(HttpStatusCode.NotFound);
					conn.sendResponse(response.serveData("Task not found"));
					return;
				case RawSourceLookupStatus.seqOutOfRange:
					response.setStatus(HttpStatusCode.NotFound);
					conn.sendResponse(response.serveData("Seq out of range"));
					return;
				case RawSourceLookupStatus.historyNotLoaded:
					response.setStatus(HttpStatusCode.Conflict);
					conn.sendResponse(response.serveData("History is not loaded. Preview the session first."));
					return;
				case RawSourceLookupStatus.ok:
					break;
			}

			response.headers["Content-Type"] = "application/json";
			conn.sendResponse(response.serveData(result.raw !is null ? result.raw : "null"));
		});
	}

	private void handleLiveFileRequest(HttpRequest request, HttpServerConnection conn)
	{
		import std.algorithm.searching : canFind;
		import std.exception : enforce;
		import std.path : isAbsolute;

		auto response = new HttpResponseEx();
		int tid;
		string path;
		try
		{
			auto params = request.urlParameters;
			auto tidStr = params.get("tid", "");
			path = params.get("path", "");
			enforce!ConvException(tidStr.length && path.length, "Missing tid or path");
			tid = tidStr.to!int;
			enforce!ConvException(isAbsolute(path), "The file path must be absolute");
			enforce!ConvException(!path.canFind('\0'), "The file path contains a NUL character");
		}
		catch (ConvException e)
		{
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveText(e.msg));
			return;
		}

		conn.conn.handleReadData = null;
		liveFileLookup_(tid, path, (LiveFileLookupResult result) {
			if (!conn.connected)
				return;
			final switch (result.status)
			{
			case LiveFileLookupStatus.ok:
				response.headers["X-Content-Type-Options"] = "nosniff";
				response.headers["Content-Security-Policy"] = "sandbox; default-src 'none'";
				response.headers["Cache-Control"] = "no-store";
				conn.sendResponse(response.serveData(Data(result.bytes), result.mediaType));
				return;
			case LiveFileLookupStatus.taskNotFound:
				response.setStatus(HttpStatusCode.NotFound);
				conn.sendResponse(response.serveText("Task not found"));
				return;
			case LiveFileLookupStatus.unavailable:
				response.setStatus(HttpStatusCode.UnprocessableContent);
				break;
			}
			conn.sendResponse(response.serveText(result.reason));
		});
	}

	private void handleMcpCall(HttpRequest request, HttpServerConnection conn)
	{
		auto response = new HttpResponseEx();
		response.headers["Content-Type"] = "application/json";
		bool deliveryFinalized;

		@JSONPartial
		static struct McpCallRequest
		{
			string tid;
			string tool;
			string item_id;
			JSONFragment args;
		}

		McpCallRequest call;
		try
		{
			auto bodyText = cast(string) request.data[].joinData().toGC();
			call = jsonParse!McpCallRequest(bodyText);
		}
		catch (Exception)
		{
			conn.sendResponse(response.serveData(
				`{"content":[{"type":"text","text":"Invalid request"}],"isError":true}`));
			return;
		}

		auto observed = cast(McpConnection) conn.timer.next;
		auto cancellation = new ToolCallCancellation;
		observed.onPendingCallDisconnect = () {
			observed.onPendingCallDisconnect = null;
			cancellation.cancel();
		};

		void finishDelivery(McpResult result, bool delivered)
		{
			assert(!deliveryFinalized);
			deliveryFinalized = true;
			onNextTick(socketManager, () {
				if (delivered)
					mcpCallbacks_.onDelivered(call.tid, result);
				else
					mcpCallbacks_.onDeliveryFailed(call.tid, result);
			});
		}

		void sendResult(McpResult result)
		{
			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
				result.structuredContent,
			));
			observed.onPendingCallDisconnect = null;
			conn.sendResponse(response.serveData(resultJson));
		}

		void discardResult(McpResult result)
		{
			if (result.settleDelivery !is null)
				onNextTick(socketManager, () { result.settleDelivery(false); });
		}

		void sendTransportError(Exception e)
		{
			warningf("dispatchTool: unhandled error: %s", e.msg);
			auto reply = McpResult("Internal MCP transport error", true);
			bool connected = conn.connected;
			if (connected)
				sendResult(reply);
			finishDelivery(reply, connected);
		}

		mcpCallbacks_.dispatchTool(call.tool, call.tid, call.item_id, call.args, cancellation).then((McpResult result) {
			if (!conn.connected)
			{
				finishDelivery(result, false);
				return;
			}
			observed.onPendingCallDisconnect = null;
			try
			{
				if (mcpCallbacks_.interruptForPendingContinuation(call.tid))
				{
					discardResult(result);
					return;
				}
				sendResult(result);
			}
			catch (Exception e)
			{
				discardResult(result);
				sendTransportError(e);
				return;
			}
			finishDelivery(result, true);
		}, &sendTransportError).except((Exception e) {
			onNextTick(socketManager, () { throw e; });
		}).ignoreResult();
	}
}

version (unittest) private string mcpTransportTestSocketPath(string scenario)
{
	return buildPath(tempDir(), format!"cydo-transport-%s-%s.sock"(
		thisProcessID, scenario));
}

version (unittest) private HttpRequest mcpTransportTestRequest()
{
	auto request = new HttpRequest();
	request.resource = "/mcp/call";
	request.method = "POST";
	request.headers["Host"] = "localhost";
	auto body = `{"tid":"17","tool":"Ask","item_id":"call_transport","args":{}}`;
	request.data = DataVec(Data(body.asBytes));
	return request;
}

version (unittest) private HttpServer startMcpTransportTestServer(
	TransportAdapter adapter, string socketPath,
	void delegate(HttpRequest, HttpServerConnection) afterRequest = null)
{
	auto server = new McpHttpServer();
	server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		assert(request.resource == "/mcp/call");
		adapter.handleMcpCall(request, conn);
		if (afterRequest)
			afterRequest(request, conn);
	};
	auto address = new UnixAddress(socketPath);
	server.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
		cast(ProtocolType) 0, address, socketPath)]);
	return server;
}

version (unittest) private void assertMcpDispatchFailureIsTerminal(bool throwInFulfillment)
{
	auto scenario = throwInFulfillment ? "callback" : "rejection";
	auto socketPath = mcpTransportTestSocketPath(scenario);
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int deliveryFailedCalls;
	int deliveredCalls;
	bool[] settlements;
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, string itemId, JSONFragment args, ToolCallCancellation cancellation) {
				auto promise = new Promise!McpResult;
				if (throwInFulfillment)
					promise.fulfill(McpResult("unused", false, JSONFragment.init,
						(bool delivered) { settlements ~= delivered; }));
				else
					promise.reject(new Exception("simulated dispatch rejection"));
				return promise;
			},
			interruptForPendingContinuation: (string) {
				if (throwInFulfillment)
					throw new Exception("simulated fulfillment callback failure");
				return false;
			},
			onDeliveryFailed: (string, McpResult result) {
				if (result.settleDelivery !is null)
					result.settleDelivery(false);
				deliveryFailedCalls++;
			},
			onDelivered: (string, McpResult result) {
				if (result.settleDelivery !is null)
					result.settleDelivery(true);
				deliveredCalls++;
			},
		),
	);

	auto server = startMcpTransportTestServer(adapter, socketPath);
	HttpResponse observedResponse;
	string disconnectReason;
	auto client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		observedResponse = response;
		disconnectReason = reason;
		server.close();
	};
	client.request(mcpTransportTestRequest());

	socketManager.loop();

	auto description = throwInFulfillment
		? "fulfillment callback exception"
		: "dispatch rejection";
	assert(observedResponse !is null,
		format!"%s produced no terminal HTTP response: %s"(description, disconnectReason));
	assert(observedResponse.status == HttpStatusCode.OK);
	auto responseText = cast(string) observedResponse.data[].joinData().toGC();
	auto result = responseText.jsonParse!McpContentResult;
	assert(result.isError);
	assert(result.content.length == 1);
	assert(result.content[0].type == "text");
	assert(result.content[0].text == "Internal MCP transport error");
	assert(deliveredCalls == 1);
	assert(deliveryFailedCalls == 0);
	if (throwInFulfillment)
		assert(settlements == [false], "The original result must settle once as undelivered");
}

version (unittest) private void assertMcpDisconnectedClientFailsDelivery(bool settleBeforeDisconnect)
{
	auto socketPath = mcpTransportTestSocketPath(
		settleBeforeDisconnect ? "settled-disconnect" : "pending-disconnect");
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int deliveryFailedCalls;
	int deliveredCalls;
	int responseCalls;
	bool cancelledBeforeSettlement;
	bool deliveryCalledBeforeSettlement;
	auto dispatchPromise = new Promise!McpResult;
	ToolCallCancellation dispatchCancellation;
	HttpServer server;
	auto client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		if (response)
			responseCalls++;
	};
	auto deliveryTimeout = setTimeout({
		assert(false, "disconnected MCP call did not finish delivery");
	}, 2.seconds);
	scope (exit) if (deliveryTimeout.isWaiting()) deliveryTimeout.cancel();
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, string itemId, JSONFragment args, ToolCallCancellation cancellation) {
				dispatchCancellation = cancellation;
				assert(!cancellation.cancelled);
				return dispatchPromise;
			},
			interruptForPendingContinuation: (string) => false,
			onDeliveryFailed: (string, McpResult result) {
				deliveryFailedCalls++;
				deliveryTimeout.cancel();
				server.close();
			},
			onDelivered: (string, McpResult result) {
				deliveredCalls++;
			},
		),
	);
	server = startMcpTransportTestServer(adapter, socketPath,
		(HttpRequest request, HttpServerConnection conn) {
			if (settleBeforeDisconnect)
			{
				// Close the server connection before the queued fulfillment handler runs.
				assert(conn.connected);
				dispatchPromise.fulfill(McpResult("unused", false));
				conn.transport.disconnect("simulated server-side disconnect", DisconnectType.error);
				assert(!conn.connected);
				return;
			}

			auto disconnectTimeout = setTimeout({
				assert(false, "server did not observe client disconnect");
			}, 2.seconds);
			void fulfillAfterClientDisconnect()
			{
				if (conn.connected)
				{
					setTimeout(&fulfillAfterClientDisconnect, 1.msecs);
					return;
				}
				disconnectTimeout.cancel();
				cancelledBeforeSettlement = dispatchCancellation.cancelled;
				deliveryCalledBeforeSettlement = deliveryFailedCalls != 0 || deliveredCalls != 0;
				dispatchPromise.fulfill(McpResult("unused", false));
			}
			client.disconnect("simulated client disconnect");
			setTimeout(&fulfillAfterClientDisconnect, 1.msecs);
		});
	client.request(mcpTransportTestRequest());

	socketManager.loop();

	if (!settleBeforeDisconnect)
	{
		assert(cancelledBeforeSettlement, "disconnect did not cancel pending dispatch");
		assert(!deliveryCalledBeforeSettlement);
	}
	assert(deliveryFailedCalls == 1);
	assert(deliveredCalls == 0);
	assert(responseCalls == 0);
}

version (unittest) private void assertMcpSettledDispatchIsNotCancelled(bool withholdResponse)
{
	auto socketPath = mcpTransportTestSocketPath(withholdResponse ? "continuation" : "delivered");
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int failedSettlements;
	int deliveryFailedCalls;
	int deliveredCalls;
	string dispatchedItemId;
	ToolCallCancellation dispatchCancellation;
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, string itemId, JSONFragment args, ToolCallCancellation cancellation) {
				dispatchedItemId = itemId;
				dispatchCancellation = cancellation;
				auto promise = new Promise!McpResult;
				promise.fulfill(McpResult("tool output", false, JSONFragment.init, (bool delivered) {
					assert(!delivered);
					failedSettlements++;
				}));
				return promise;
			},
			interruptForPendingContinuation: (string) => withholdResponse,
			onDeliveryFailed: (string, McpResult result) {
				deliveryFailedCalls++;
				result.settleDelivery(false);
			},
			onDelivered: (string, McpResult result) {
				deliveredCalls++;
			},
		),
	);

	auto server = startMcpTransportTestServer(adapter, socketPath);
	HttpResponse observedResponse;
	string disconnectReason;
	auto client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		observedResponse = response;
		disconnectReason = reason;
		server.close();
	};
	client.request(mcpTransportTestRequest());

	socketManager.loop();

	assert(dispatchedItemId == "call_transport", dispatchedItemId);
	assert(dispatchCancellation !is null && !dispatchCancellation.cancelled);
	if (withholdResponse)
	{
		assert(observedResponse is null);
		assert(disconnectReason == "Time-out");
	}
	else
	{
		assert(observedResponse !is null);
		assert(observedResponse.status == HttpStatusCode.OK);
		auto body = cast(string) observedResponse.data[].joinData().toGC();
		auto result = body.jsonParse!McpContentResult;
		assert(!result.isError);
		assert(result.content.length == 1 && result.content[0].text == "tool output");
	}
	assert(failedSettlements == (withholdResponse ? 1 : 0));
	assert(deliveryFailedCalls == 0);
	assert(deliveredCalls == (withholdResponse ? 0 : 1));
}

version (unittest) private void assertMcpCleanupFailureEscapes(
	bool delivered, bool assertionFailure)
{
	auto scenario = format!"cleanup-%s-%s"(
		delivered ? "delivered" : "failed",
		assertionFailure ? "assert" : "exception");
	auto socketPath = mcpTransportTestSocketPath(scenario);
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int deliveryFailedCalls;
	int deliveredCalls;
	int responseCalls;
	bool drainObserverRan;
	HttpServer server;
	HttpClient client;
	HttpResponse observedResponse;
	auto dispatchPromise = new Promise!McpResult;

	void throwFromCleanup()
	{
		onNextTick(socketManager, () { drainObserverRan = true; });
		if (assertionFailure)
			assert(false, "simulated MCP cleanup assertion failure");
		throw new Exception("simulated MCP cleanup exception");
	}

	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, string itemId, JSONFragment args, ToolCallCancellation cancellation) => dispatchPromise,
			interruptForPendingContinuation: (string) => false,
			onDeliveryFailed: (string, McpResult result) {
				deliveryFailedCalls++;
				throwFromCleanup();
			},
			onDelivered: (string, McpResult result) {
				deliveredCalls++;
				throwFromCleanup();
			},
		),
	);
	server = startMcpTransportTestServer(adapter, socketPath,
		(HttpRequest request, HttpServerConnection conn) {
			if (delivered)
				return;

			auto disconnectTimeout = setTimeout({
				assert(false, "server did not observe client disconnect");
			}, 2.seconds);
			void fulfillAfterClientDisconnect()
			{
				if (conn.connected)
				{
					setTimeout(&fulfillAfterClientDisconnect, 1.msecs);
					return;
				}
				disconnectTimeout.cancel();
				dispatchPromise.fulfill(McpResult("unused", false));
			}
			client.disconnect("simulated client disconnect");
			setTimeout(&fulfillAfterClientDisconnect, 1.msecs);
		});
	client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		if (response)
		{
			responseCalls++;
			observedResponse = response;
		}
		if (delivered)
			server.close();
	};
	client.request(mcpTransportTestRequest());
	if (delivered)
		dispatchPromise.fulfill(McpResult("cleanup response", false));

	Exception cleanupError;
	AssertError cleanupAssertion;
	try
		socketManager.loop();
	catch (AssertError error)
		cleanupAssertion = error;
	catch (Exception e)
		cleanupError = e;

	if (assertionFailure)
	{
		assert(cleanupAssertion !is null);
		assert(cleanupError is null);
	}
	else
	{
		assert(cleanupError !is null);
		assert(cleanupError.msg == "simulated MCP cleanup exception");
		assert(cleanupAssertion is null);
	}
	assert(!drainObserverRan);
	assert(deliveredCalls == (delivered ? 1 : 0));
	assert(deliveryFailedCalls == (delivered ? 0 : 1));

	if (!delivered)
		server.close();

	socketManager.loop();

	assert(drainObserverRan);
	assert(responseCalls == (delivered ? 1 : 0));
	if (delivered)
	{
		assert(observedResponse !is null);
		assert(observedResponse.status == HttpStatusCode.OK);
	}
	assert(deliveredCalls == (delivered ? 1 : 0));
	assert(deliveryFailedCalls == (delivered ? 0 : 1));
}

/// A second request reaching a keep-alive connection while a raw-source
/// reply is pending must wait: ae would otherwise answer it first and send
/// the pending reply with the second request's method and headers.
version (unittest) private void assertDeferredRawSourceReplyOwnsItsRequest()
{
	import std.algorithm.searching : endsWith;
	import std.string : indexOf;

	auto socketPath = mcpTransportTestSocketPath("raw-source");
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int[] lookups;
	auto client = new SocketConnection();
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		(int tid, size_t seq, RawSourceReady ready) {
			lookups ~= tid;
			if (tid == 2)
			{
				ready(RawSourceLookupResult(RawSourceLookupStatus.taskNotFound, null));
				return;
			}
			client.send(Data(("HEAD /api/raw-source?tid=2&seq=0 HTTP/1.1\r\n"
				~ "Host: localhost\r\nConnection: close\r\n\r\n").asBytes));
			setTimeout({
				assert(lookups == [1], "second request handled while the first was unanswered");
				ready(RawSourceLookupResult(RawSourceLookupStatus.ok, `{"first":true}`));
			}, 100.msecs);
		},
		null,
		McpCallbacks.init,
	);

	auto server = new HttpServer();
	server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		adapter.handleRawSourceRequest(request, conn);
	};
	server.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
		cast(ProtocolType) 0, new UnixAddress(socketPath), socketPath)]);

	string received;
	client.handleConnect = {
		client.send(Data(("GET /api/raw-source?tid=1&seq=0 HTTP/1.1\r\n"
			~ "Host: localhost\r\n\r\n").asBytes));
	};
	client.handleReadData = (Data data) { received ~= cast(string) data.toGC(); };
	client.handleDisconnect = (string reason, DisconnectType type) { server.close(); };
	client.connect([AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
		cast(ProtocolType) 0, new UnixAddress(socketPath), socketPath)]);

	socketManager.loop();

	assert(lookups == [1, 2]);
	auto second = received.indexOf("HTTP/1.1 404");
	assert(received.indexOf("HTTP/1.1 200") == 0 && second > 0, received);
	assert(received[0 .. second].endsWith(`{"first":true}`), received);
	assert(received[second .. $].endsWith("\r\n\r\n"), received);
}

unittest
{
	assertMcpDispatchFailureIsTerminal(false);
	assertMcpDispatchFailureIsTerminal(true);
	assertMcpDisconnectedClientFailsDelivery(false);
	assertMcpDisconnectedClientFailsDelivery(true);
	assertMcpSettledDispatchIsNotCancelled(false);
	assertMcpSettledDispatchIsNotCancelled(true);
	assertMcpCleanupFailureEscapes(true, false);
	assertMcpCleanupFailureEscapes(true, true);
	assertMcpCleanupFailureEscapes(false, false);
	assertMcpCleanupFailureEscapes(false, true);
	assertDeferredRawSourceReplyOwnsItsRequest();
}

version (unittest) private HttpResponse requestOverUnixSocket(
	string user, string pass, string resource, string host, string origin = null)
{
	import std.file : mkdir, rmdirRecurse, write;
	import std.uuid : randomUUID;

	auto webDistDir = buildPath(tempDir(), "cydo-http-" ~ randomUUID().toString());
	mkdir(webDistDir);
	scope (exit) rmdirRecurse(webDistDir);
	write(buildPath(webDistDir, "index.html"), "<html>CyDo</html>");
	write(buildPath(webDistDir, "manifest.json"), `{"name":"CyDo"}`);

	auto adapter = new TransportAdapter(webDistDir ~ "/", WebSocketCallbacks.init, null, null, McpCallbacks.init);
	adapter.setAuthCredentials(user, pass);
	adapter.startHttpServer(null, null);

	auto socketPath = buildPath(webDistDir, "http.sock");
	auto server = adapter.server;
	server.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
		cast(ProtocolType) 0, new UnixAddress(socketPath), socketPath)]);

	auto request = new HttpRequest();
	request.resource = resource;
	request.method = "GET";
	if (host !is null)
		request.headers["Host"] = host;
	if (origin !is null)
		request.headers["Origin"] = origin;

	HttpResponse observedResponse;
	string disconnectReason;
	auto client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		observedResponse = response;
		disconnectReason = reason;
		server.close();
	};
	client.request(request);
	socketManager.loop();

	assert(observedResponse !is null,
		format!"GET %s produced no HTTP response: %s"(resource, disconnectReason));
	return observedResponse;
}

// A cross-origin WebSocket request is rejected before Basic authentication.
unittest
{
	import cydo.web.request_policy : originMismatchText;

	auto response = requestOverUnixSocket("user", "pass", webSocketResource, "cydo.example", "https://evil.example");
	assert(response.status == HttpStatusCode.Forbidden, response.status.to!string);
	assert(response.headers.get("Content-Type", null) == "text/plain; charset=utf-8");
	assert(cast(string) response.data[].joinData().toGC() == originMismatchText);
}

// An arbitrary Host can reach the authentication challenge on a regular route.
unittest
{
	auto response = requestOverUnixSocket("user", "pass", "/", "cydo.example");
	assert(response.status == HttpStatusCode.Unauthorized, response.status.to!string);
}

// The no-auth Host check runs before serving the public manifest.
unittest
{
	import cydo.web.request_policy : noAuthHostText;

	auto allowed = requestOverUnixSocket("", "", "/manifest.json", "localhost:3940");
	assert(allowed.status == HttpStatusCode.OK, allowed.status.to!string);
	assert(allowed.headers.get("Content-Type", null) == "application/manifest+json");
	assert(cast(string) allowed.data[].joinData().toGC() == `{"name":"CyDo"}`);

	auto rejected = requestOverUnixSocket("", "", "/manifest.json", "evil.example:3940");
	assert(rejected.status == HttpStatusCode.Forbidden, rejected.status.to!string);
	assert(cast(string) rejected.data[].joinData().toGC() == noAuthHostText);
}

// A request without a Host header is forbidden when auth is disabled.
unittest
{
	import cydo.web.request_policy : noAuthHostText;

	auto response = requestOverUnixSocket("", "", "/", null);
	assert(response.status == HttpStatusCode.Forbidden, response.status.to!string);
	assert(cast(string) response.data[].joinData().toGC() == noAuthHostText);
}

// An allowed Host reaches the application index without credentials.
unittest
{
	auto response = requestOverUnixSocket("", "", "/", "localhost:3940");
	assert(response.status == HttpStatusCode.OK, response.status.to!string);
	assert(cast(string) response.data[].joinData().toGC() == "<html>CyDo</html>");
}

unittest // The live-file route serves status, headers and bytes over HTTP.
{
	import std.algorithm.searching : canFind, endsWith, startsWith;
	import std.string : indexOf;
	import std.uni : toLower;

	auto socketPath = mcpTransportTestSocketPath("live-file");
	if (exists(socketPath))
		remove(socketPath);

	immutable(ubyte)[] bytes = [0x89, 0x50, 0, 0xFF];
	enum reason = "The task is archived";
	string[] lookups;
	SocketConnection client;

	void request(string query, string method, bool close)
	{
		auto headers = "Host: localhost\r\n" ~ (close ? "Connection: close\r\n" : "");
		client.send(Data((method ~ " /api/live-file?" ~ query ~ " HTTP/1.1\r\n"
			~ headers ~ "\r\n").asBytes));
	}

	auto adapter = new TransportAdapter("", WebSocketCallbacks.init, null,
		(int tid, string path, LiveFileReady ready) {
			assert(tid == 17);
			lookups ~= path;
			switch (path)
			{
			case "/file":
				request("tid=17&path=/unknown", "HEAD", true);
				setTimeout({
					assert(lookups == ["/file"], "The pending reply must keep its request");
					ready(LiveFileLookupResult(LiveFileLookupStatus.ok, "image/png", bytes));
				}, 100.msecs);
				break;
			case "/unknown":
				ready(LiveFileLookupResult(LiveFileLookupStatus.taskNotFound));
				break;
			case "/archived":
				ready(LiveFileLookupResult(status: LiveFileLookupStatus.unavailable, reason: reason));
				break;
			default:
				assert(0, path);
			}
		}, McpCallbacks.init);

	string exchange(string query, bool close)
	{
		adapter.startHttpServer(null, null);
		auto server = adapter.server;
		auto address = AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
			cast(ProtocolType) 0, new UnixAddress(socketPath), socketPath);
		server.listen([address]);
		scope (exit)
			if (exists(socketPath))
				remove(socketPath);

		string received;
		client = new SocketConnection();
		client.handleConnect = { request(query, "GET", close); };
		client.handleReadData = (Data data) { received ~= cast(string) data.toGC(); };
		client.handleDisconnect = (string reason, DisconnectType type) { server.close(); };
		client.connect([address]);
		socketManager.loop();
		return received;
	}

	foreach (query; ["tid=17", "tid=17&path=relative", "tid=17&path=/with%00nul",
		"path=/file", "tid=invalid&path=/file"])
	{
		auto badRequest = exchange(query, true);
		assert(badRequest.startsWith("HTTP/1.1 400 "), query ~ ": " ~ badRequest);
		assert(lookups.length == 0, query);
	}

	auto success = exchange("tid=17&path=/file", false);
	assert(lookups == ["/file", "/unknown"]);
	assert(success.startsWith("HTTP/1.1 200 "), success);
	auto headerEnd = success.indexOf("\r\n\r\n");
	assert(headerEnd >= 0, success);
	auto headers = success[0 .. headerEnd + 2].toLower;
	assert(headers.canFind("\r\ncontent-type: image/png\r\n"), headers);
	assert(headers.canFind("\r\nx-content-type-options: nosniff\r\n"), headers);
	assert(headers.canFind("\r\ncontent-security-policy: sandbox; default-src 'none'\r\n"), headers);
	assert(headers.canFind("\r\ncache-control: no-store\r\n"), headers);

	auto bodyStart = headerEnd + 4;
	auto nextResponse = bodyStart + bytes.length;
	assert(success.length >= nextResponse, success);
	assert(success[bodyStart .. nextResponse].asBytes == bytes);
	auto notFound = success[nextResponse .. $];
	assert(notFound.startsWith("HTTP/1.1 404 ") && notFound.endsWith("\r\n\r\n"), notFound);

	auto unavailable = exchange("tid=17&path=/archived", true);
	assert(lookups == ["/file", "/unknown", "/archived"]);
	assert(unavailable.startsWith("HTTP/1.1 422 ") && unavailable.endsWith("\r\n\r\n" ~ reason),
		unavailable);
}
