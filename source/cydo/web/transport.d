module cydo.web.transport;

import std.conv : ConvException, to;
import std.file : exists, isFile, remove;
import std.logger : fatalf, infof, warningf;
import std.path : buildPath;

import ae.net.asockets : DisconnectType, onNextTick, socketManager;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection, HttpsServer;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;
import ae.sys.dataset : joinData;
import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.mcp : McpResult;
import cydo.mcp.payloads : McpContentItem, McpContentResult;
import cydo.runtime.launch.sandbox : runtimeDir;

version (unittest) import core.exception : AssertError;
version (unittest) import core.time : msecs, seconds;
version (unittest) import std.file : exists, remove, tempDir;
version (unittest) import std.format : format;
version (unittest) import std.process : thisProcessID;
version (unittest) import std.socket : AddressFamily, AddressInfo, ProtocolType,
	SocketType, UnixAddress;
version (unittest) import ae.net.http.client : HttpClient, UnixConnector;
version (unittest) import ae.net.http.common : HttpResponse;
version (unittest) import ae.sys.timing : setTimeout;
version (unittest) import ae.sys.dataset : DataVec;
version (unittest) import ae.utils.array : asBytes;

package(cydo):

enum RawSourceLookupStatus
{
	ok,
	taskNotFound,
	seqOutOfRange,
}

struct RawSourceLookupResult
{
	RawSourceLookupStatus status = RawSourceLookupStatus.ok;
	string raw;
}

struct WebSocketCallbacks
{
	void delegate(WebSocketAdapter ws) onAccepted;
	void delegate(WebSocketAdapter ws, string text) onMessage;
	void delegate(WebSocketAdapter ws, string reason, DisconnectType type) onDisconnected;
}

struct McpCallbacks
{
	Promise!McpResult delegate(string tool, string tid, JSONFragment args) dispatchTool;
	bool delegate(string tid) interruptForPendingContinuation;
	void delegate(string tid) onDeliveryFailed;
	void delegate(string tid) onDelivered;
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
	// session cookie token, regenerated whenever auth credentials are set; old
	// iOS Safari never sends the Authorization header on WebSocket upgrades, so
	// /ws authenticates via this cookie instead
	private string authCookieToken_;
	private WebSocketCallbacks websocketCallbacks_;
	private RawSourceLookupResult delegate(int tid, size_t seq) rawSourceLookup_;
	private McpCallbacks mcpCallbacks_;

	this(
		string webDistDir,
		WebSocketCallbacks websocketCallbacks,
		RawSourceLookupResult delegate(int tid, size_t seq) rawSourceLookup,
		McpCallbacks mcpCallbacks,
	)
	{
		webDistDir_ = webDistDir;
		websocketCallbacks_ = websocketCallbacks;
		rawSourceLookup_ = rawSourceLookup;
		mcpCallbacks_ = mcpCallbacks;
	}

	void setAuthCredentials(string user, string pass)
	{
		authUser_ = user;
		authPass_ = pass;
		if (authEnabled)
		{
			import std.file : read;
			import std.format : format;

			auto entropy = cast(ubyte[]) read("/dev/urandom", 32);
			if (entropy.length != 32)
				fatalf("Short read from /dev/urandom (%d bytes)", entropy.length);
			authCookieToken_ = format("%(%02x%)", entropy);
		}
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

		mcpServer_ = new HttpServer();
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

		if (request.resource == "/ws")
		{
			handleWebSocket(request, conn);
			return;
		}

		if (request.path == "/api/raw-source")
		{
			handleRawSourceRequest(request, conn);
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
		// hand a session cookie to clients that authenticated via basic auth; it
		// rides along on WebSocket upgrades where old Safari omits the
		// Authorization header
		if (authCookieToken_.length > 0 && !hasValidAuthCookie(request))
			response.headers["Set-Cookie"] =
				"cydo_auth=" ~ authCookieToken_ ~ "; Path=/; HttpOnly; SameSite=Strict";
		conn.sendResponse(response);
	}

	private bool hasValidAuthCookie(HttpRequest request)
	{
		return authCookieToken_.length > 0
			&& request.getCookies().get("cydo_auth", null) == authCookieToken_;
	}

	private bool checkAuth(HttpRequest request, HttpServerConnection conn)
	{
		if (!authEnabled)
			return true;
		if (hasValidAuthCookie(request))
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

		auto result = rawSourceLookup_(tid, seq);
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
			case RawSourceLookupStatus.ok:
				break;
		}

		response.headers["Content-Type"] = "application/json";
		conn.sendResponse(response.serveData(result.raw !is null ? result.raw : "null"));
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

		void finishDelivery(bool delivered)
		{
			assert(!deliveryFinalized);
			deliveryFinalized = true;
			onNextTick(socketManager, () {
				if (delivered)
					mcpCallbacks_.onDelivered(call.tid);
				else
					mcpCallbacks_.onDeliveryFailed(call.tid);
			});
		}

		void sendResult(McpResult result)
		{
			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
				result.structuredContent,
			));
			conn.sendResponse(response.serveData(resultJson));
			finishDelivery(true);
		}

		mcpCallbacks_.dispatchTool(call.tool, call.tid, call.args).then((McpResult result) {
			if (!conn.connected)
			{
				finishDelivery(false);
				return;
			}
			if (mcpCallbacks_.interruptForPendingContinuation(call.tid))
				return;

			sendResult(result);
		}).except((Exception e) {
			warningf("dispatchTool: unhandled error: %s", e.msg);
			if (!conn.connected)
			{
				finishDelivery(false);
				return;
			}
			sendResult(McpResult("Internal MCP transport error", true));
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
	auto body = `{"tid":"17","tool":"Ask","args":{}}`;
	request.data = DataVec(Data(body.asBytes));
	return request;
}

version (unittest) private HttpServer startMcpTransportTestServer(
	TransportAdapter adapter, string socketPath,
	void delegate(HttpRequest, HttpServerConnection) afterRequest = null)
{
	auto server = new HttpServer();
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
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, JSONFragment args) {
				auto promise = new Promise!McpResult;
				if (throwInFulfillment)
					promise.fulfill(McpResult("unused", false));
				else
					promise.reject(new Exception("simulated dispatch rejection"));
				return promise;
			},
			interruptForPendingContinuation: (string) {
				if (throwInFulfillment)
					throw new Exception("simulated fulfillment callback failure");
				return false;
			},
			onDeliveryFailed: (string) {
				deliveryFailedCalls++;
			},
			onDelivered: (string) {
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
}

version (unittest) private void assertMcpDisconnectedClientFailsDelivery()
{
	auto socketPath = mcpTransportTestSocketPath("disconnected");
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int deliveryFailedCalls;
	int deliveredCalls;
	int responseCalls;
	auto dispatchPromise = new Promise!McpResult;
	HttpServer server;
	auto client = new HttpClient(2.seconds, new UnixConnector(socketPath));
	client.handleResponse = (HttpResponse response, string reason) {
		if (response)
			responseCalls++;
	};
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, JSONFragment args) => dispatchPromise,
			interruptForPendingContinuation: (string) => false,
			onDeliveryFailed: (string) {
				deliveryFailedCalls++;
				server.close();
			},
			onDelivered: (string) {
				deliveredCalls++;
			},
		),
	);
	server = startMcpTransportTestServer(adapter, socketPath,
		(HttpRequest request, HttpServerConnection conn) {
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
	client.request(mcpTransportTestRequest());

	socketManager.loop();

	assert(deliveryFailedCalls == 1);
	assert(deliveredCalls == 0);
	assert(responseCalls == 0);
}

version (unittest) private void assertMcpContinuationInterruptionDoesNotRespond()
{
	auto socketPath = mcpTransportTestSocketPath("continuation");
	if (exists(socketPath))
		remove(socketPath);
	scope (exit)
		if (exists(socketPath))
			remove(socketPath);

	int deliveryFailedCalls;
	int deliveredCalls;
	auto adapter = new TransportAdapter(
		"",
		WebSocketCallbacks.init,
		null,
		McpCallbacks(
			dispatchTool: (string tool, string tid, JSONFragment args) {
				auto promise = new Promise!McpResult;
				promise.fulfill(McpResult("unused", false));
				return promise;
			},
			interruptForPendingContinuation: (string) => true,
			onDeliveryFailed: (string) {
				deliveryFailedCalls++;
			},
			onDelivered: (string) {
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

	assert(observedResponse is null);
	assert(disconnectReason == "Time-out");
	assert(deliveryFailedCalls == 0);
	assert(deliveredCalls == 0);
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
		McpCallbacks(
			dispatchTool: (string tool, string tid, JSONFragment args) => dispatchPromise,
			interruptForPendingContinuation: (string) => false,
			onDeliveryFailed: (string) {
				deliveryFailedCalls++;
				throwFromCleanup();
			},
			onDelivered: (string) {
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

unittest
{
	assertMcpDispatchFailureIsTerminal(false);
	assertMcpDispatchFailureIsTerminal(true);
	assertMcpDisconnectedClientFailsDelivery();
	assertMcpContinuationInterruptionDoesNotRespond();
	assertMcpCleanupFailureEscapes(true, false);
	assertMcpCleanupFailureEscapes(true, true);
	assertMcpCleanupFailureEscapes(false, false);
	assertMcpCleanupFailureEscapes(false, true);
}
