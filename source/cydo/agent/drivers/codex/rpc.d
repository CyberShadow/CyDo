module cydo.agent.drivers.codex.rpc;

import std.typecons : Nullable;

import ae.net.jsonrpc.binding : RPCFlatten;
import ae.utils.json : JSONExtras, JSONFragment, JSONOptional, JSONPartial,
	jsonParse, toJson;
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
	bool excludeTurns;
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
	@JSONOptional string lastTurnId;
	bool excludeTurns;
	@JSONOptional string model;
	@JSONOptional string cwd;
	@JSONOptional string approvalPolicy;
	@JSONOptional string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

/// thread/inject_items: append raw Responses items to what the model sees.
@RPCFlatten @JSONPartial
struct ThreadInjectItemsParams
{
	static struct Text
	{
		string type = "input_text";
		string text;
	}

	static struct Message
	{
		string type = "message";
		string role;
		Text[] content;
	}

	string threadId;
	Message[] items;
}

@RPCFlatten @JSONPartial
struct ThreadUnsubscribeParams
{
	string threadId;
}

@RPCFlatten @JSONPartial
struct ThreadRevertParams
{
	string threadId;
	string beforeTurnId;
}

@RPCFlatten @JSONPartial
struct ThreadReadParams
{
	string threadId;
	bool includeTurns;
}

@RPCFlatten @JSONPartial
struct ThreadTurnsListParams
{
	string threadId;
	string itemsView;
	string sortDirection;
	uint limit;
	@JSONOptional string cursor;
}

@RPCFlatten @JSONPartial
struct ThreadItemsListParams
{
	string threadId;
	string sortDirection;
	uint limit;
	@JSONOptional string cursor;
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
	@JSONOptional string clientUserMessageId;
	TurnStartInput[] input;
	SandboxPolicy sandboxPolicy;
}

@RPCFlatten @JSONPartial
struct TurnSteerParams
{
	string threadId;
	@JSONOptional string clientUserMessageId;
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

/// One item of a Codex thread. item/started, item/completed and the
/// thread/items/list pages all carry this object.
@JSONPartial
struct ThreadItem
{
	string type;
	string id;
	@JSONOptional string clientId;
	@JSONOptional Nullable!long startedAtMs;
	@JSONOptional Nullable!long completedAtMs;
	@JSONOptional string name;
	@JSONOptional string text;             // agentMessage, plan
	@JSONOptional SO content;              // userMessage inputs or reasoning text
	@JSONOptional string phase;            // agentMessage
	@JSONOptional SO memoryCitation;       // agentMessage
	@JSONOptional SO moderation;           // agentMessage
	@JSONOptional SO delivery;             // agentMessage
	@JSONOptional SO questions;            // agentMessage
	@JSONOptional SO summary;              // reasoning
	// commandExecution:
	@JSONOptional string command;
	@JSONOptional string cwd;
	@JSONOptional string status;           // also fileChange, mcpToolCall
	@JSONOptional string processId;
	@JSONOptional Nullable!int exitCode;   // null while the command is running
	@JSONOptional Nullable!int durationMs; // also mcpToolCall; null while running
	@JSONOptional SO commandActions;
	@JSONOptional string aggregatedOutput; // stdout+stderr; null while running
	@JSONOptional string scriptPath;
	@JSONOptional string source;           // agent, userShell, unifiedExec*
	// fileChange:
	@JSONOptional SO changes;
	// mcpToolCall:
	@JSONOptional string tool;
	@JSONOptional string server;
	@JSONName("arguments") @JSONOptional SO arguments_;
	@JSONOptional SO result;               // null until the call completes
	@JSONOptional SO error;                // null until the call completes
	@JSONOptional string environmentId;
	@JSONOptional SO mcpAppUi;
	@JSONOptional Nullable!bool readOnlyHint;
	@JSONOptional SO pluginId;             // also commandExecution
	@JSONOptional SO appContext;
	// webSearch:
	@JSONOptional SO query;
	@JSONOptional SO action;
	@JSONOptional SO results;
	// internal Codex metadata:
	@JSONName("_creationOrder") @JSONOptional int _creationOrder;
	JSONExtras extras;
}

@RPCFlatten @JSONPartial
struct ItemStartedParams
{
	string threadId;
	@JSONOptional string turnId;
	ThreadItem item;
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

/// A turn as carried by turn/completed and by the thread/turns/list pages.
@JSONPartial
struct Turn
{
	string id;
	string status;                    // "completed", "interrupted", "failed", "inProgress"
	@JSONOptional SO error;           // TurnError {message, codexErrorInfo, additionalDetails}; null unless failed
	@JSONOptional Nullable!long startedAt;   // Unix seconds
	@JSONOptional Nullable!long completedAt; // Unix seconds
	@JSONOptional Nullable!long durationMs;
}

@RPCFlatten @JSONPartial
struct TurnCompletedParams
{
	string threadId;
	Turn turn;
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

/// deprecationNotice / configWarning: app-server-wide notices for the user.
@RPCFlatten @JSONPartial
struct NoticeParams
{
	string summary;
	@JSONOptional string details;
	@JSONOptional string path;  // configWarning: the config file at fault
	@JSONOptional SO range;     // configWarning: where in that file
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
	ThreadItem item;
}

// ---- Response result types ----

@JSONPartial
struct ThreadStartResult
{
	@JSONPartial
	static struct Thread
	{
		string id;
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

// ---- Thread history pages ----

/// The thread object of a thread/read result with includeTurns false.
@JSONPartial
struct ThreadMetadata
{
	string id;
	string historyMode;              // "paginated" or "legacy"
	@JSONOptional string path;       // current rollout file
	string cwd;
	string cliVersion;
	@JSONOptional string model;
	string modelProvider;
	string preview;
	@JSONOptional string forkedFromId;
}

@JSONPartial
struct ThreadMetadataResult
{
	ThreadMetadata thread;
}

/// One page of thread/turns/list.
@JSONPartial
struct ThreadTurnsListResult
{
	Turn[] data;
	@JSONOptional string nextCursor; // null on the last page
}

@JSONPartial
struct ThreadItemEntry
{
	string turnId;
	ThreadItem item;
}

/// One page of thread/items/list.
@JSONPartial
struct ThreadItemsListResult
{
	ThreadItemEntry[] data;
	@JSONOptional string nextCursor; // null on the last page
}

// ---- Materialized thread ledger results ----

// ---- Config struct for MCP override ----

struct McpServerConfig
{
	string command;
	string[] args;
	string[string] env;
	uint tool_timeout_sec;
}

unittest
{
	// Completed items from the Codex 0.171.0 trace-fidelity-final wire capture.
	foreach (itemJson; [
		`{
			"type":"userMessage",
			"id":"01a1feae-9e92-7753-9e61-757f909bcc11",
			"clientId":null,
			"content":[{"type":"text","text":"reply with \"reasoning-fixture\"","text_elements":[]}],
			"startedAtMs":1795274219154,
			"completedAtMs":1795274219154
		}`,
		`{
			"type":"agentMessage",
			"moderation":null,
			"id":"msg_mock_00001",
			"text":"reasoning-fixture",
			"phase":null,
			"memoryCitation":null,
			"delivery":null,
			"questions":null,
			"startedAtMs":1795274219214,
			"completedAtMs":1795274219214
		}`,
		`{
			"type":"commandExecution",
			"id":"call_mock_00001",
			"pluginId":null,
			"scriptPath":null,
			"command":"/run/current-system/sw/bin/zsh -lc 'printf success-marker'",
			"cwd":"/mnt/local/moved/home/vladimir/work/.cydo/tasks/39225/trace-fidelity-final",
			"processId":"95145",
			"source":"unifiedExecStartup",
			"status":"completed",
			"commandActions":[{"type":"unknown","command":"printf success-marker"}],
			"aggregatedOutput":"success-marker",
			"exitCode":0,
			"durationMs":0,
			"startedAtMs":1795274219348,
			"completedAtMs":1795274219348
		}`,
		`{
			"type":"contextCompaction",
			"id":"01a1feae-aa46-7bf2-807f-facdd4b5453b",
			"startedAtMs":1795274222150,
			"completedAtMs":1795274222212
		}`,
		`{
			"type":"fileChange",
			"id":"call_mock_00003",
			"changes":[{"path":"/mnt/local/moved/home/vladimir/work/.cydo/tasks/39225/trace-fidelity-final/tmp/codex-fileviewer-create.txt","kind":{"type":"add"},"diff":"hello from create fixture\n"}],
			"status":"completed",
			"startedAtMs":1795274219664,
			"completedAtMs":1795274219665
		}`,
		`{
			"type":"mcpToolCall",
			"id":"call_mock_00004",
			"server":"cydo",
			"environmentId":null,
			"tool":"Task",
			"status":"completed",
			"arguments":{"marker":"history-mcp-input"},
			"appContext":null,
			"mcpAppUi":null,
			"pluginId":null,
			"readOnlyHint":null,
			"result":{"content":[{"type":"text","text":"fixture success"}],"structuredContent":null,"_meta":null},
			"error":null,
			"durationMs":1,
			"startedAtMs":1795274219803,
			"completedAtMs":1795274219805
		}`,
		`{
			"type":"reasoning",
			"id":"rs_history_fixture",
			"summary":["fixture summary"],
			"content":["fixture reasoning"],
			"startedAtMs":1795274219211,
			"completedAtMs":1795274219212
		}`,
		// From the web-search e2e capture.
		`{
			"type":"webSearch",
			"id":"ws_mock_call_mock_00001",
			"query":"dagster incremental pipelines",
			"action":{"type":"search","query":"dagster incremental pipelines","queries":["dagster incremental pipelines"]},
			"results":null,
			"startedAtMs":1795287089896,
			"completedAtMs":1795287089897
		}`,
		// Schema-derived (MemoryCitation): no capture has a memory citation.
		`{
			"type":"agentMessage",
			"id":"msg-cited",
			"text":"fixture reply",
			"phase":null,
			"memoryCitation":{"entries":[{"path":"MEMORY.md","lineStart":1,"lineEnd":2,"note":"fixture"}],"threadIds":["thread-1"]}
		}`,
		// Codex 0.144.1-style item without the newer fields.
		`{"type":"agentMessage","id":"msg-legacy","text":"fixture reply","phase":null,"memoryCitation":null}`,
	])
	{
		// item/started, item/completed and thread/items/list carry one object.
		static assert(is(typeof(ItemStartedParams.item) == ThreadItem)
			&& is(typeof(ItemCompletedParams.item) == ThreadItem)
			&& is(typeof(ThreadItemEntry.item) == ThreadItem));
		auto item = jsonParse!ThreadItem(itemJson);
		auto raw = jsonParse!SO(itemJson);
		assert(toJson(item.type) == raw["type"].toJson() && toJson(item.id) == raw["id"].toJson(),
			itemJson);
		assert(item.extras.length == 0,
			"extras for " ~ item.type ~ ": " ~ toJson(item.extras._data));
	}
}

unittest
{
	// The history requests, with the parameter names of the 0.171.0 captures
	// (rpc-examples.json, cold-large ids 2-10).
	assert(toJson(ThreadReadParams("thread-1", false))
		== `{"threadId":"thread-1","includeTurns":false}`);
	assert(toJson(ThreadTurnsListParams("thread-1", "summary", "asc", 100))
		== `{"threadId":"thread-1","itemsView":"summary","sortDirection":"asc","limit":100}`);
	assert(toJson(ThreadTurnsListParams("thread-1", "summary", "asc", 100, "cursor-1"))
		== `{"threadId":"thread-1","itemsView":"summary","sortDirection":"asc","limit":100,"cursor":"cursor-1"}`);
	assert(toJson(ThreadItemsListParams("thread-1", "asc", 100))
		== `{"threadId":"thread-1","sortDirection":"asc","limit":100}`);
	assert(toJson(ThreadItemsListParams("thread-1", "asc", 100, "cursor-1"))
		== `{"threadId":"thread-1","sortDirection":"asc","limit":100,"cursor":"cursor-1"}`);
}

unittest
{
	import cydo.agent.drivers.codex.thread_items_fixtures;

	// thread/read {includeTurns: false}
	auto thread = jsonParse!ThreadMetadataResult(nineTurnThreadRead).thread;
	assert(thread.id == "01a1feae-9e4c-7d83-a43c-dbd595e0221d" && thread.historyMode == "paginated"
		&& thread.path == "/mnt/local/moved/home/vladimir/work/.cydo/tasks/39247/rerun-e8"
			~ "/home/sessions/2026/11/21/rollout-2026-11-21T15-17-02-"
			~ "01a1feae-9e4c-7d83-a43c-dbd595e0221d_01a1feae-abdf-7350-a0a8-cb08309b191a.jsonl"
		&& thread.cwd == "/mnt/local/moved/home/vladimir/work/.cydo/tasks/39225/trace-fidelity-final"
		&& thread.cliVersion == "0.171.0" && thread.model == "gpt-5.4"
		&& thread.modelProvider == "cydo-mock" && thread.preview == `reply with "reasoning-fixture"`
		&& thread.forkedFromId is null);

	// thread/turns/list
	auto turns = jsonParse!ThreadTurnsListResult(nineTurnTurnsPage);
	assert(turns.data.length == 9 && turns.nextCursor is null);
	auto compaction = turns.data[0];
	assert(compaction.id == "01a1feae-aa3e-70c1-b080-0d550c0682cf" && compaction.status == "completed"
		&& compaction.error.type == SO.Type.null_ && compaction.startedAt.get == 1795274222
		&& compaction.completedAt.get == 1795274222 && compaction.durationMs.get == 73);
	assert(turns.data[1].status == "interrupted");
	auto failed = turns.data[3];
	assert(failed.status == "failed" && failed.error["codexErrorInfo"].toJson() == `"usageLimitExceeded"`);

	// thread/items/list
	auto items = jsonParse!ThreadItemsListResult(nineTurnItemsPage);
	assert(items.data.length == 22 && items.nextCursor is null);
	assert(items.data[0].turnId == "01a1feae-9e5b-7430-b501-883bafb074dd"
		&& items.data[0].item.type == "userMessage"
		&& items.data[0].item.id == "01a1feae-9e92-7753-9e61-757f909bcc11");
	assert(items.data[4].turnId == "01a1feae-9ed9-74d0-bb3f-8f0c3874ed42"
		&& items.data[4].item.type == "commandExecution" && items.data[4].item.exitCode.get == 0
		&& items.data[4].item.aggregatedOutput == "success-marker");
	foreach (ref entry; items.data)
		assert(entry.item.extras.length == 0, toJson(entry.item.extras._data));

	// A page that is not the last one names the next. Schema-derived: every
	// captured page of the nine-turn thread is its last.
	assert(jsonParse!ThreadItemsListResult(`{"data":[],"nextCursor":"cursor-2","backwardsCursor":null}`)
		.nextCursor == "cursor-2");
	assert(jsonParse!ThreadTurnsListResult(`{"data":[],"nextCursor":"cursor-2","backwardsCursor":null}`)
		.nextCursor == "cursor-2");
}
