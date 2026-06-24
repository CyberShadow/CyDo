module cydo.agent.drivers.codex.rpc;

import std.typecons : Nullable;

import ae.net.jsonrpc.binding : RPCFlatten;
import ae.utils.json : JSONExtras, JSONFragment, JSONOptional, JSONPartial;
import ae.utils.serialization.json : JSONName;
import ae.utils.serialization.store : SerializedObject;

package alias SO = SerializedObject!(immutable char);

// ---------------------------------------------------------------------------
// JSON-RPC param/result structs for the Codex app-server protocol.
// ---------------------------------------------------------------------------

// ---- Outgoing request params (CyDo → Codex) ----

@RPCFlatten @JSONPartial
struct InitializeParams
{
	static struct ClientInfo
	{
		string name;
		@JSONName("version") string version_;
	}
	ClientInfo clientInfo;
	JSONFragment capabilities;
}

@RPCFlatten @JSONPartial
struct LoginStartParams
{
	string type;
	string apiKey;
}

@RPCFlatten @JSONPartial
struct ThreadStartParams
{
	string cwd;
	string model;
	string approvalPolicy;
	string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

@RPCFlatten @JSONPartial
struct ThreadResumeParams
{
	string threadId;
	@JSONOptional string model;
	@JSONOptional string cwd;
	@JSONOptional string approvalPolicy;
	@JSONOptional string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

@RPCFlatten @JSONPartial
struct ThreadForkParams
{
	string threadId;
	@JSONOptional string path;
	@JSONOptional string model;
	@JSONOptional string cwd;
	@JSONOptional string approvalPolicy;
	@JSONOptional string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

struct ThreadForkOutcome
{
	bool ok;
	string threadId;
	string rawResultJson;
	string error;
}

@RPCFlatten @JSONPartial
struct ThreadRollbackParams
{
	string threadId;
	uint numTurns;
}

struct ThreadRollbackOutcome
{
	bool ok;
	string error;
}

@RPCFlatten @JSONPartial
struct TurnStartInput
{
	string type;
	string text;
}

@RPCFlatten @JSONPartial
struct SandboxPolicy
{
	string type;
	string networkAccess;
}

@RPCFlatten @JSONPartial
struct TurnStartParams
{
	string threadId;
	TurnStartInput[] input;
	SandboxPolicy sandboxPolicy;
}

@RPCFlatten @JSONPartial
struct TurnSteerParams
{
	string threadId;
	TurnStartInput[] input;
	string expectedTurnId;
}

@RPCFlatten @JSONPartial
struct TurnInterruptParams
{
	string threadId;
	string turnId;
}

// ---- Incoming notification params (Codex → CyDo) ----

@RPCFlatten @JSONPartial
struct ItemStartedParams
{
	string threadId;
	@JSONOptional string turnId;
	static struct Item
	{
		string type;
		@JSONOptional string id;
		@JSONOptional string name;
		@JSONOptional string text;
		@JSONOptional string command;
		@JSONOptional SO action;
		@JSONOptional SO content; // userMessage items: Array<UserInput>
		@JSONOptional string tool;          // mcpToolCall: tool name (e.g. "AskUserQuestion")
		@JSONOptional string server;        // mcpToolCall: server name (e.g. "cydo")
		// commandExecution fields (explicit to prevent appearance in _extras):
		@JSONOptional string cwd;
		@JSONOptional string status;
		@JSONOptional string processId;
		@JSONOptional Nullable!int exitCode;  // null while command is running
		@JSONOptional Nullable!int durationMs; // null while command is running
		@JSONOptional SO commandActions;
		@JSONOptional string aggregatedOutput; // commandExecution: stdout+stderr (null while running)
		// fileChange fields:
		@JSONOptional SO changes;
		// mcpToolCall fields:
		@JSONName("arguments") @JSONOptional SO arguments_;
		// webSearch fields:
		@JSONOptional SO query;
		// agentMessage fields:
		@JSONOptional string phase;
		// mcpToolCall pending-result fields (null until item/completed):
		@JSONOptional SO result;
		@JSONOptional SO error;
		// reasoning fields (declared to prevent leaking into _extras):
		@JSONOptional SO summary;
		// agentMessage fields:
		@JSONOptional typeof(null) memoryCitation;
		// internal Codex metadata:
		@JSONName("_creationOrder") @JSONOptional int _creationOrder;
		JSONExtras extras;
	}
	Item item;
}

@RPCFlatten @JSONPartial
struct DeltaParams
{
	string threadId;
	@JSONOptional string itemId;
	@JSONOptional string turnId;
	string delta;
}

@RPCFlatten @JSONPartial
struct TerminalInteractionParams
{
	string threadId;
	string itemId;
	string processId;
	string stdin;
	string turnId;
}

@RPCFlatten @JSONPartial
struct ThreadIdParams
{
	string threadId;
}

@JSONPartial
struct TurnRef
{
	string id;
}

@RPCFlatten @JSONPartial
struct TurnStartedParams
{
	string threadId;
	TurnRef turn;
}

@RPCFlatten @JSONPartial
struct TurnDiffUpdatedParams
{
	string threadId;
	string turnId;
	SO diff;
}

/// Catch-all params struct for no-op handlers that receive notifications
/// we don't process (may or may not have a threadId).
@RPCFlatten @JSONPartial
struct IgnoredParams
{
	@JSONOptional string threadId;
}

@RPCFlatten @JSONPartial
struct ErrorParams
{
	@JSONOptional string threadId;
	@JSONOptional string turnId;
	@JSONOptional bool willRetry;
	@JSONOptional SO error;
}

@RPCFlatten @JSONPartial
struct WarningParams
{
	@JSONOptional string threadId;
	@JSONOptional string turnId;
	@JSONOptional string message;
}

@RPCFlatten @JSONPartial
struct TokenUsageUpdatedParams
{
	string threadId;
	@JSONOptional string turnId;
	@JSONOptional TokenUsagePayload tokenUsage;
}

@JSONPartial
struct TokenUsagePayload
{
	@JSONOptional TokenUsageBreakdown last;
}

@JSONPartial
struct TokenUsageBreakdown
{
	@JSONOptional int inputTokens;
	@JSONOptional int outputTokens;
}

@RPCFlatten @JSONPartial
struct ItemCompletedParams
{
	string threadId;
	static struct Item
	{
		@JSONOptional string id;
		@JSONOptional bool is_error;
		@JSONOptional string aggregatedOutput; // commandExecution: stdout+stderr
		@JSONOptional string status;           // "inProgress", "failed", "completed"
		@JSONOptional int exitCode;            // process exit code
		@JSONOptional int durationMs;          // execution duration in ms
		@JSONOptional string command;          // original command string
		@JSONOptional string cwd;              // working directory
		@JSONOptional string type;             // item type (e.g. "commandExecution")
		@JSONOptional SO query;            // webSearch: search query
		@JSONOptional SO action;           // webSearch: {type, query, queries}
		@JSONOptional string processId;        // process ID for commandExecution
		@JSONOptional SO commandActions;   // commandExecution actions log
		@JSONOptional SO result;           // mcpToolCall/webSearch result payload
		@JSONOptional SO changes;          // fileChange: array of file changes
		// agentMessage fields:
		@JSONOptional string text;
		@JSONOptional string phase;
		// mcpToolCall fields (repeated from item/started for completed items):
		@JSONOptional string server;
		@JSONOptional string tool;
		@JSONName("arguments") @JSONOptional SO arguments_;
		@JSONOptional SO error;
		// reasoning fields (declared to prevent leaking into _extras):
		@JSONOptional SO summary;
		@JSONOptional SO content;
		// agentMessage fields:
		@JSONOptional typeof(null) memoryCitation;
		// internal Codex metadata:
		@JSONName("_creationOrder") @JSONOptional int _creationOrder;
		JSONExtras extras;                     // remaining unknown fields
	}
	@JSONOptional Item item;
}

// ---- Response result types ----

@JSONPartial
struct ThreadStartResult
{
	@JSONPartial
	static struct Thread
	{
		string id;
		@JSONOptional string path;
	}
	Thread thread;
}

@JSONPartial
struct TurnStartResult
{
	TurnRef turn;
}

@JSONPartial
struct ApprovalDecision
{
	string decision;
}

// ---- Config struct for MCP override ----

struct McpServerConfig
{
	string command;
	string[] args;
	string[string] env;
	uint tool_timeout_sec;
}
