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
import ae.net.jsonrpc.binding : jsonRpcDispatcher, RPCFlatten, RPCName, RPCNotification;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.stdio : stdioLDJsonRpcConnection;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.array : asBytes;
import ae.utils.json : JSONFragment, jsonParse, toJson, JSONPartial;
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

	auto impl = new McpServerImpl(socketPath, tid);
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
	Promise!JSONFragment toolsList();

	@RPCName("tools/call")
	Promise!JSONFragment toolsCall(ToolsCallParams params);

	@RPCName("resources/list")
	Promise!JSONFragment resourcesList();

	@RPCName("resources/templates/list")
	Promise!JSONFragment resourcesTemplatesList();

	@RPCName("prompts/list")
	Promise!JSONFragment promptsList();
}

class McpServerImpl : McpProtocol
{
	private string socketPath;
	private string tid;

	this(string socketPath, string tid)
	{
		this.socketPath = socketPath;
		this.tid = tid;
	}

	Promise!InitializeResult initialize()
	{
		return resolve(InitializeResult(MCP_PROTOCOL_VERSION, ServerInfo("cydo", "0.1.0")));
	}

	Promise!void notificationsInitialized()
	{
		return resolve();
	}

	Promise!JSONFragment toolsList()
	{
		return resolve(JSONFragment(buildToolsListJson()));
	}

	Promise!JSONFragment toolsCall(ToolsCallParams params)
	{
		auto promise = new Promise!JSONFragment;

		auto backendRequest = BackendToolCall(tid, params.name, params.arguments);
		auto bodyJson = toJson(backendRequest);

		tracef("MCP proxy: tools/call %s → backend", params.name);

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
				promise.reject(new Exception("Backend connection failed: " ~ disconnectReason));
				return;
			}
			try
			{
				import ae.sys.dataset : joinData;
				auto responseText = cast(string) response.data[].joinData().toGC();
				if (response.status / 100 != 2)
				{
					warningf("MCP proxy: backend returned HTTP %d", response.status);
					promise.reject(new Exception("Backend returned HTTP " ~ to!string(response.status)));
					return;
				}
				promise.fulfill(JSONFragment(responseText));
			}
			catch (Exception e)
				promise.reject(new Exception("Failed to parse backend response: " ~ e.msg));
		};
		client.request(httpReq);

		return promise;
	}

	Promise!JSONFragment resourcesList()
	{
		return resolve(JSONFragment(`{"resources":[]}`));
	}

	Promise!JSONFragment resourcesTemplatesList()
	{
		return resolve(JSONFragment(`{"resourceTemplates":[]}`));
	}

	Promise!JSONFragment promptsList()
	{
		return resolve(JSONFragment(`{"prompts":[]}`));
	}
}

// ---- JSON structures ----

@RPCFlatten @JSONPartial
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
