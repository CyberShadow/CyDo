module cydo.transport;

import std.conv : ConvException, to;
import std.file : exists, isFile, remove;
import std.logger : infof, warningf;
import std.path : buildPath;

import ae.net.asockets : DisconnectType;
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
import cydo.sandbox : runtimeDir;

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

		mcpCallbacks_.dispatchTool(call.tool, call.tid, call.args).then((McpResult result) {
			if (!conn.connected)
			{
				mcpCallbacks_.onDeliveryFailed(call.tid);
				return;
			}
			if (mcpCallbacks_.interruptForPendingContinuation(call.tid))
				return;

			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
				result.structuredContent,
			));
			conn.sendResponse(response.serveData(resultJson));
			mcpCallbacks_.onDelivered(call.tid);
		}).except((Exception e) {
			warningf("dispatchTool: unhandled error: %s", e.msg);
		}).ignoreResult();
	}
}
