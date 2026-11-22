module cydo.agent.drivers.codex.rpc;

import std.conv : to;
import std.typecons : Nullable;

import ae.net.jsonrpc.binding : RPCFlatten;
import ae.utils.json : JSONExtras, JSONFragment, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.serialization.json : JSONName, jsonCustomDeserializer;
import ae.utils.serialization.serialization : isProtocolArray, isProtocolBoolean,
	isProtocolField, isProtocolMap, isProtocolNull, isProtocolNumeric,
	isProtocolString;
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
struct ThreadRollbackParams
{
	string threadId;
	uint numTurns;
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

@JSONPartial
struct ThreadStatus
{
	string type;
	@JSONOptional string[] activeFlags;
	JSONExtras extras;
}

@JSONPartial
struct UserInput
{
	string type;
	@JSONOptional string text;
	@JSONName("text_elements") @JSONOptional SO[] textElements;
	JSONExtras extras;
}

@JSONPartial
private struct LedgerThreadItemWire
{
	string type;
	@JSONOptional string id;
	@JSONOptional string clientId;
	@JSONOptional SO content;
	@JSONOptional string text;
	@JSONOptional string phase;
	@JSONOptional SO memoryCitation;
	JSONExtras extras;
}

/// A materialized thread item. Unknown item types remain represented by their
/// provider string; only user-message content is projected into UserInput.
@JSONPartial
struct LedgerThreadItem
{
	string type;
	@JSONOptional string id;
	@JSONOptional string clientId;
	@JSONOptional UserInput[] content;
	@JSONOptional string text;
	@JSONOptional string phase;
	@JSONOptional SO memoryCitation;
	JSONExtras extras;

	static LedgerThreadItem fromJSON(SO raw)
	{
		auto wire = raw.deserializeTo!LedgerThreadItemWire;
		LedgerThreadItem result;
		result.type = wire.type;
		result.id = wire.id;
		result.clientId = wire.clientId;
		result.text = wire.text;
		result.phase = wire.phase;
		result.memoryCitation = wire.memoryCitation;
		result.extras = wire.extras;
		if (wire.type == "userMessage" && wire.content.type != SO.Type.none)
			result.content = wire.content.deserializeTo!(UserInput[]);
		return result;
	}
}

@JSONPartial
struct LedgerTurn
{
	string id;
	LedgerThreadItem[] items;
	string itemsView;
	string status;
	SO error;
	Nullable!long startedAt;
	Nullable!long completedAt;
	Nullable!long durationMs;
	JSONExtras extras;
}

@JSONPartial
struct LedgerThread
{
	string id;
	ThreadStatus status;
	LedgerTurn[] turns;
	JSONExtras extras;
}

@JSONPartial
private struct ThreadResultWire
{
	LedgerThread thread;
}

private void decodeThreadResult(SO raw, ref LedgerThread thread, ref SO rawThread,
	ref SO[] rawTurns)
{
	if (raw.type != SO.Type.object || !("thread" in raw)
		|| raw["thread"].type != SO.Type.object || !("turns" in raw["thread"]))
		throw new Exception("Codex thread response is missing thread.turns");
	auto turns = raw["thread"]["turns"];
	if (turns.type != SO.Type.array)
		throw new Exception("Codex thread response turns must be an array");
	ThreadResultWire decoded;
	raw.read(jsonCustomDeserializer(&decoded));
	thread = decoded.thread;
	rawThread = raw["thread"];
	foreach (i; 0 .. turns.length)
		rawTurns ~= turns[i];
}

/// Result of thread/read, with a typed turn vector and its exact raw sidecar.
struct ThreadReadResult
{
	LedgerThread thread;
	SO rawThread;
	SO[] rawTurns;

	static ThreadReadResult fromJSON(SO raw)
	{
		try
		{
			ThreadReadResult result;
			decodeThreadResult(raw, result.thread, result.rawThread, result.rawTurns);
			return result;
		}
		catch (Exception e)
			throw new Exception("Invalid Codex thread/read result: " ~ e.msg);
	}
}

/// Result of thread/rollback, with the returned typed turn vector and its
/// exact raw sidecar.
struct ThreadRollbackResult
{
	LedgerThread thread;
	SO rawThread;
	SO[] rawTurns;

	static ThreadRollbackResult fromJSON(SO raw)
	{
		try
		{
			ThreadRollbackResult result;
			decodeThreadResult(raw, result.thread, result.rawThread, result.rawTurns);
			return result;
		}
		catch (Exception e)
			throw new Exception("Invalid Codex thread/rollback result: " ~ e.msg);
	}
}

private struct SOComparisonNode
{
	SO.Type type;
	bool boolean;
	string text;
	string[] keys;
	SOComparisonNode[] values;
}

private struct SOComparisonSink
{
	SOComparisonNode* node;

	void handle(V)(V value)
	{
		*node = makeSOComparisonNode(value);
	}
}

private struct SOComparisonArraySink
{
	SOComparisonNode[]* values;

	void handle(V)(V value)
	{
		*values ~= makeSOComparisonNode(value);
	}
}

private struct SOComparisonMapSink
{
	SOComparisonNode* node;

	void handle(V)(V field)
	{
		static if (isProtocolField!V)
		{
			SOComparisonNode key;
			field.nameReader(SOComparisonSink(&key));
			assert(key.type == SO.Type.string_, "Codex raw object key must be a string");
			SOComparisonNode value;
			field.valueReader(SOComparisonSink(&value));
			node.keys ~= key.text;
			node.values ~= value;
		}
		else
			static assert(false, "Codex raw object comparison expected a field");
	}
}

private SOComparisonNode makeSOComparisonNode(V)(V value)
{
	SOComparisonNode result;
	static if (isProtocolNull!V)
		result.type = SO.Type.null_;
	else static if (isProtocolBoolean!V)
	{
		result.type = SO.Type.boolean;
		result.boolean = value.value;
	}
	else static if (isProtocolNumeric!V)
	{
		result.type = SO.Type.numeric;
		result.text = value.text.to!string;
	}
	else static if (isProtocolString!V)
	{
		result.type = SO.Type.string_;
		result.text = value.text.to!string;
	}
	else static if (isProtocolArray!V)
	{
		result.type = SO.Type.array;
		value.reader(SOComparisonArraySink(&result.values));
	}
	else static if (isProtocolMap!V)
	{
		result.type = SO.Type.object;
		value.reader(SOComparisonMapSink(&result));
	}
	else
		static assert(false, "Unsupported Codex raw comparison value");
	return result;
}

private bool sameSOComparisonNode(const ref SOComparisonNode left,
	const ref SOComparisonNode right)
{
	if (left.type != right.type || left.boolean != right.boolean || left.text != right.text
		|| left.keys != right.keys || left.values.length != right.values.length)
		return false;
	foreach (i; 0 .. left.values.length)
		if (!sameSOComparisonNode(left.values[i], right.values[i]))
			return false;
	return true;
}

/// Compare raw provider values recursively, preserving array and object order.
package bool sameSO(SO left, SO right)
{
	SOComparisonNode leftNode;
	left.read(SOComparisonSink(&leftNode));
	SOComparisonNode rightNode;
	right.read(SOComparisonSink(&rightNode));
	return sameSOComparisonNode(leftNode, rightNode);
}

unittest
{
	ThreadReadParams readParams;
	readParams.threadId = "019fd753-5670-7901-ad88-0c938273cfe1";
	readParams.includeTurns = true;
	assert(toJson(readParams)
		== `{"threadId":"019fd753-5670-7901-ad88-0c938273cfe1","includeTurns":true}`);

	// Distilled from the pinned interrupted-turn thread/read capture. The
	// leading opaque turn and nested provider fields model retained prefix data
	// that this unit must preserve without admitting or interpreting it.
	enum readPayload = `{
		"thread":{
			"id":"019fd753-5670-7901-ad88-0c938273cfe1",
			"status":{"type":"idle","statusUnknown":{"source":"capture"}},
			"threadUnknown":{"must":"survive"},
			"turns":[
				{
					"id":"opaque-prefix-turn",
					"items":[{
						"type":"providerPrefixItem",
						"id":"opaque-prefix-item",
						"content":["uninterpreted prefix content"],
						"providerPrefixPayload":{"all":["fields",1]}
					}],
					"itemsView":"summary",
					"status":"completed",
					"error":null,
					"startedAt":1786023989,
					"completedAt":1786023990,
					"durationMs":1,
					"turnUnknown":"opaque prefix"
				},
				{
					"id":"019fd753-5694-7232-9661-ba3e8236127e",
					"items":[
						{
							"type":"userMessage",
							"id":"item-1",
							"clientId":"spike-interrupted-retained-client",
							"content":[{
								"type":"text",
								"text":"Reply with \"SPIKE_INTERRUPTED_RETAINED_SENTINEL\"",
								"text_elements":[],
								"inputUnknown":{"nested":true}
							}],
							"itemUnknown":["must","remain"]
						},
						{
							"type":"agentMessage",
							"id":"item-2",
							"text":"SPIKE_INTERRUPTED_RETAINED_SENTINEL",
							"phase":null,
							"memoryCitation":null
						}
					],
					"itemsView":"full",
					"status":"completed",
					"error":null,
					"startedAt":1786023990,
					"completedAt":1786023991,
					"durationMs":72,
					"turnUnknown":{"reason":"preserve"}
				},
				{
					"id":"019fd753-56e1-7c40-bf58-72b8d7902706",
					"items":[{
						"type":"userMessage",
						"id":"item-3",
						"clientId":"spike-interrupted-rollback-client",
						"content":[{
							"type":"text",
							"text":"stall session SPIKE_INTERRUPTED_ROLLBACK_PROMPT",
							"text_elements":[]
						}]
					}],
					"itemsView":"full",
					"status":"interrupted",
					"error":null,
					"startedAt":1786023991,
					"completedAt":1786023991,
					"durationMs":57
				}
			]
		}
	}`;

	auto read = jsonParse!ThreadReadResult(readPayload);
	auto rawRead = jsonParse!SO(readPayload);
	auto expectedReadTurns = rawRead["thread"]["turns"];
	assert(read.thread.id == "019fd753-5670-7901-ad88-0c938273cfe1");
	assert(read.thread.status.type == "idle");
	assert(sameSO(read.rawThread, rawRead["thread"]));
	assert(read.thread.status.extras["statusUnknown"].json == `{"source":"capture"}`);
	assert(read.thread.extras["threadUnknown"].json == `{"must":"survive"}`);
	assert(read.thread.turns.length == 3 && read.rawTurns.length == 3);
	foreach (i; 0 .. read.rawTurns.length)
		assert(sameSO(read.rawTurns[i], expectedReadTurns[i]));

	bool missingTurnsRefused;
	try
		jsonParse!ThreadReadResult(`{"thread":{"id":"missing-turns"}}`);
	catch (Exception e)
	{
		assert(e.msg == "Invalid Codex thread/read result: Codex thread response is missing thread.turns");
		missingTurnsRefused = true;
	}
	assert(missingTurnsRefused);

	auto prefix = read.thread.turns[0];
	assert(prefix.id == "opaque-prefix-turn" && prefix.itemsView == "summary"
		&& prefix.status == "completed" && prefix.error.type == SO.Type.null_
		&& prefix.startedAt.get == 1786023989 && prefix.completedAt.get == 1786023990
		&& prefix.durationMs.get == 1);
	assert(prefix.items.length == 1,
		"expected one opaque prefix item; actual=" ~ prefix.items.length.to!string);
	auto prefixItem = prefix.items[0];
	assert(prefixItem.type == "providerPrefixItem",
		"expected opaque prefix item type; actual=" ~ prefixItem.type);
	assert(prefixItem.id == "opaque-prefix-item",
		"expected opaque prefix item id; actual=" ~ prefixItem.id);
	assert(prefixItem.content.length == 0,
		"opaque prefix content must not be projected as UserInput; actual count="
			~ prefixItem.content.length.to!string);
	assert(prefixItem.extras["providerPrefixPayload"].json == `{"all":["fields",1]}`);
	assert(prefix.extras["turnUnknown"].json == `"opaque prefix"`);

	auto completed = read.thread.turns[1];
	assert(completed.id == "019fd753-5694-7232-9661-ba3e8236127e"
		&& completed.itemsView == "full" && completed.status == "completed"
		&& completed.error.type == SO.Type.null_ && completed.startedAt.get == 1786023990
		&& completed.completedAt.get == 1786023991 && completed.durationMs.get == 72);
	assert(completed.items.length == 2);
	auto user = completed.items[0];
	assert(user.type == "userMessage" && user.id == "item-1"
		&& user.clientId == "spike-interrupted-retained-client" && user.content.length == 1
		&& user.extras["itemUnknown"].json == `["must","remain"]`);
	assert(user.content[0].type == "text"
		&& user.content[0].text == `Reply with "SPIKE_INTERRUPTED_RETAINED_SENTINEL"`
		&& user.content[0].textElements.length == 0
		&& user.content[0].extras["inputUnknown"].json == `{"nested":true}`);
	auto agent = completed.items[1];
	assert(agent.type == "agentMessage" && agent.id == "item-2"
		&& agent.text == "SPIKE_INTERRUPTED_RETAINED_SENTINEL" && agent.phase is null
		&& agent.memoryCitation.type == SO.Type.null_);
	assert(completed.extras["turnUnknown"].json == `{"reason":"preserve"}`);

	auto interrupted = read.thread.turns[2];
	assert(interrupted.id == "019fd753-56e1-7c40-bf58-72b8d7902706"
		&& interrupted.itemsView == "full" && interrupted.status == "interrupted"
		&& interrupted.error.type == SO.Type.null_ && interrupted.startedAt.get == 1786023991
		&& interrupted.completedAt.get == 1786023991 && interrupted.durationMs.get == 57);
	assert(interrupted.items.length == 1 && interrupted.items[0].type == "userMessage"
		&& interrupted.items[0].id == "item-3"
		&& interrupted.items[0].clientId == "spike-interrupted-rollback-client"
		&& interrupted.items[0].content[0].text == "stall session SPIKE_INTERRUPTED_ROLLBACK_PROMPT"
		&& interrupted.items[0].content[0].textElements.length == 0);

	// The populated thread/rollback response has the same result shape and
	// preserves the captured retained-prefix vector unchanged.
	enum rollbackPayload = `{
		"thread":{
			"id":"019fd753-5670-7901-ad88-0c938273cfe1",
			"status":{"type":"idle","statusUnknown":{"source":"rollback-capture"}},
			"threadUnknown":{"must":"survive rollback"},
			"turns":[{
				"id":"019fd753-5694-7232-9661-ba3e8236127e",
				"items":[
					{"type":"userMessage","id":"item-1","clientId":"spike-interrupted-retained-client","content":[{"type":"text","text":"Reply with \"SPIKE_INTERRUPTED_RETAINED_SENTINEL\"","text_elements":[],"inputUnknown":{"nested":true}}],"itemUnknown":["must","remain"]},
					{"type":"agentMessage","id":"item-2","text":"SPIKE_INTERRUPTED_RETAINED_SENTINEL","phase":null,"memoryCitation":null}
				],
				"itemsView":"full",
				"status":"completed",
				"error":null,
				"startedAt":1786023990,
				"completedAt":1786023991,
				"durationMs":72,
				"turnUnknown":{"reason":"preserve rollback"}
			},{
				"id":"retained-trailing-turn",
				"items":[],
				"itemsView":"summary",
				"status":"completed",
				"error":null,
				"startedAt":1786023991,
				"completedAt":1786023992,
				"durationMs":1
			}]
		}
	}`;

	auto rollback = jsonParse!ThreadRollbackResult(rollbackPayload);
	auto rawRollback = jsonParse!SO(rollbackPayload);
	auto expectedRollbackTurns = rawRollback["thread"]["turns"];
	assert(rollback.thread.id == "019fd753-5670-7901-ad88-0c938273cfe1"
		&& rollback.thread.status.type == "idle" && rollback.thread.turns.length == 2
		&& rollback.rawTurns.length == 2);
	assert(rollback.thread.status.extras["statusUnknown"].json
		== `{"source":"rollback-capture"}`);
	assert(rollback.thread.extras["threadUnknown"].json == `{"must":"survive rollback"}`);
	auto retained = rollback.thread.turns[0];
	assert(retained.id == "019fd753-5694-7232-9661-ba3e8236127e"
		&& retained.itemsView == "full" && retained.status == "completed"
		&& retained.error.type == SO.Type.null_ && retained.startedAt.get == 1786023990
		&& retained.completedAt.get == 1786023991 && retained.durationMs.get == 72
		&& retained.items.length == 2);
	assert(retained.items[0].clientId == "spike-interrupted-retained-client"
		&& retained.items[0].content[0].text
			== `Reply with "SPIKE_INTERRUPTED_RETAINED_SENTINEL"`
		&& retained.items[0].extras["itemUnknown"].json == `["must","remain"]`
		&& retained.items[0].content[0].extras["inputUnknown"].json == `{"nested":true}`
		&& retained.items[1].text == "SPIKE_INTERRUPTED_RETAINED_SENTINEL"
		&& retained.extras["turnUnknown"].json == `{"reason":"preserve rollback"}`);
	assert(rollback.thread.turns[1].id == "retained-trailing-turn"
		&& rollback.thread.turns[1].itemsView == "summary");
	foreach (i; 0 .. rollback.rawTurns.length)
		assert(sameSO(rollback.rawTurns[i], expectedRollbackTurns[i]));
	assert(!sameSO(jsonParse!SO(`[1,2]`), jsonParse!SO(`[2,1]`)));
}

unittest
{
	// Distilled from the pinned duplicate-prompt thread/read and rollback
	// frames. Equal prompt text remains distinguishable only by client ID.
	enum duplicateReadPayload = `{
		"thread":{
			"id":"019fd6d2-f60f-7850-8924-e3566e56f9e6",
			"status":{"type":"idle"},
			"turns":[
				{
					"id":"019fd6d2-f63a-7e51-93b0-ae5a5e535b96",
					"items":[
						{"type":"userMessage","id":"item-1","clientId":"spike-duplicate-client-a","content":[{"type":"text","text":"Reply with \"SPIKE_DUPLICATE_REPLY\"","text_elements":[]}]},
						{"type":"agentMessage","id":"item-2","text":"SPIKE_DUPLICATE_REPLY","phase":null,"memoryCitation":null}
					],
					"itemsView":"full",
					"status":"completed",
					"error":null,
					"startedAt":1786015577,
					"completedAt":1786015577,
					"durationMs":66
				},
				{
					"id":"019fd6d2-f688-7dd2-8eff-c68c4c0ff614",
					"items":[
						{"type":"userMessage","id":"item-3","clientId":"spike-duplicate-client-b","content":[{"type":"text","text":"Reply with \"SPIKE_DUPLICATE_REPLY\"","text_elements":[]}]},
						{"type":"agentMessage","id":"item-4","text":"SPIKE_DUPLICATE_REPLY","phase":null,"memoryCitation":null}
					],
					"itemsView":"full",
					"status":"completed",
					"error":null,
					"startedAt":1786015577,
					"completedAt":1786015577,
					"durationMs":70
				}
			]
		}
	}`;

	auto duplicateRead = jsonParse!ThreadReadResult(duplicateReadPayload);
	auto rawDuplicateRead = jsonParse!SO(duplicateReadPayload);
	auto expectedDuplicateTurns = rawDuplicateRead["thread"]["turns"];
	assert(duplicateRead.thread.id == "019fd6d2-f60f-7850-8924-e3566e56f9e6"
		&& duplicateRead.thread.status.type == "idle"
		&& duplicateRead.thread.turns.length == 2 && duplicateRead.rawTurns.length == 2);
	assert(duplicateRead.thread.turns[0].id == "019fd6d2-f63a-7e51-93b0-ae5a5e535b96"
		&& duplicateRead.thread.turns[1].id == "019fd6d2-f688-7dd2-8eff-c68c4c0ff614");
	auto duplicateFirst = duplicateRead.thread.turns[0].items[0];
	auto duplicateSecond = duplicateRead.thread.turns[1].items[0];
	assert(duplicateFirst.clientId == "spike-duplicate-client-a"
		&& duplicateSecond.clientId == "spike-duplicate-client-b"
		&& duplicateFirst.clientId != duplicateSecond.clientId
		&& duplicateFirst.content[0].text == duplicateSecond.content[0].text
		&& duplicateFirst.content[0].textElements.length == 0
		&& duplicateSecond.content[0].textElements.length == 0);
	foreach (i; 0 .. duplicateRead.rawTurns.length)
		assert(sameSO(duplicateRead.rawTurns[i], expectedDuplicateTurns[i]));

	enum duplicateRollbackPayload = `{
		"thread":{
			"id":"019fd6d2-f60f-7850-8924-e3566e56f9e6",
			"status":{"type":"idle"},
			"turns":[{
				"id":"019fd6d2-f63a-7e51-93b0-ae5a5e535b96",
				"items":[
					{"type":"userMessage","id":"item-1","clientId":"spike-duplicate-client-a","content":[{"type":"text","text":"Reply with \"SPIKE_DUPLICATE_REPLY\"","text_elements":[]}]},
					{"type":"agentMessage","id":"item-2","text":"SPIKE_DUPLICATE_REPLY","phase":null,"memoryCitation":null}
				],
				"itemsView":"full",
				"status":"completed",
				"error":null,
				"startedAt":1786015577,
				"completedAt":1786015577,
				"durationMs":66
			}]
		}
	}`;

	auto duplicateRollback = jsonParse!ThreadRollbackResult(duplicateRollbackPayload);
	auto rawDuplicateRollback = jsonParse!SO(duplicateRollbackPayload);
	assert(duplicateRollback.thread.id == "019fd6d2-f60f-7850-8924-e3566e56f9e6"
		&& duplicateRollback.thread.turns.length == 1 && duplicateRollback.rawTurns.length == 1
		&& duplicateRollback.thread.turns[0].id == "019fd6d2-f63a-7e51-93b0-ae5a5e535b96"
		&& duplicateRollback.thread.turns[0].items[0].clientId
			== "spike-duplicate-client-a");
	assert(sameSO(duplicateRollback.rawTurns[0],
		rawDuplicateRollback["thread"]["turns"][0]));
}

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
