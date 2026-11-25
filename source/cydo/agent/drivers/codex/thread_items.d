/// Translation of Codex thread items into CyDo's agnostic events.
///
/// A live session receives a thread's items through item/started and
/// item/completed notifications; a history read receives the same objects
/// through thread/items/list pages. Both translate them here, so a task shows
/// the same events whether it is watched or reloaded.
module cydo.agent.drivers.codex.thread_items;

import std.conv : to;
import std.exception : enforce;

import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.time.types : AbsTime;

import cydo.agent.drivers.codex.app_server : extractCodexErrorMessage;
import cydo.agent.drivers.codex.rollout : extractCommandInput;
import cydo.agent.drivers.codex.user_message : isCodexContextualFragment, isCodexPermissionsInstructionsText;
import cydo.agent.drivers.codex.rpc : SO, ThreadItem, ThreadItemEntry, ThreadMetadata, Turn;
import cydo.foundation.system.framing : isSystemFramed;
import cydo.protocol : ContentBlock, HistoryBoundary, HistoryBoundaryKind,
	ItemCompletedEvent, ItemResultEvent, ItemStartedEvent, SessionCompactedEvent,
	SessionInitEvent, TranslatedEvent, TurnEndReason, TurnResultEvent,
	TurnStopEvent, UsageInfo, extrasToFragment;

void attachUserBoundary(ref ItemStartedEvent event, string turnId, bool isContext,
	ref bool seenUserMessage)
{
	if (seenUserMessage)
		return;
	seenUserMessage = true;
	if (!isContext && turnId.length > 0)
		event.history_boundary = HistoryBoundary("before:" ~ turnId, HistoryBoundaryKind.user);
}

/// The item_type CyDo displays a Codex item as. Item types CyDo does not
/// know are displayed as text.
string threadItemEventType(string type)
{
	switch (type)
	{
		case "reasoning":
			return "thinking";
		case "commandExecution", "fileChange", "mcpToolCall", "webSearch":
			return "tool_use";
		default:
			return "text";
	}
}

/// The item/started event of any item except a user message or a context
/// compaction, which are not content items (see `userMessageEvent` and
/// `compactionEvents`).
ItemStartedEvent itemStartedEvent(ThreadItem item)
{
	assert(item.type != "userMessage" && item.type != "contextCompaction",
		"Codex " ~ item.type ~ " item is not a content item");

	ItemStartedEvent ev;
	ev.item_id = item.id;
	ev.item_type = threadItemEventType(item.type);

	switch (item.type)
	{
		case "commandExecution":
			ev.name = "commandExecution";
			string cmdInput = extractCommandExecutionInput(
				item.commandActions ? JSONFragment(toJson(item.commandActions)) : JSONFragment.init,
				item.action ? JSONFragment(toJson(item.action)) : JSONFragment.init,
				item.command);
			if (cmdInput.length > 0 && cmdInput != `{}`)
				ev.input = JSONFragment(cmdInput);
			break;
		case "fileChange":
			ev.name = "fileChange";
			// Include changes directly so the frontend can show the File Viewer button
			// without relying on _raw (which is stripped before broadcast).
			if (item.changes)
				ev.input = JSONFragment(`{"changes":` ~ toJson(item.changes) ~ `}`);
			break;
		case "mcpToolCall":
			if (item.tool.length > 0)
			{
				ev.name = item.tool;
				if (item.server.length > 0)
				{
					ev.tool_server = item.server;
					ev.tool_source = "mcp";
				}
			}
			else
				ev.name = item.name.length > 0 ? item.name : "unknown";
			if (item.arguments_)
				ev.input = JSONFragment(toJson(item.arguments_));
			break;
		case "webSearch":
			ev.name = "webSearch";
			if (item.query)
				ev.input = JSONFragment(`{"query":` ~ toJson(item.query) ~ `}`);
			break;
		default:
			break;
	}

	// An item that is already complete (or an agent message that arrives
	// fully formed) carries its text. A reasoning item's text is reported
	// when it completes.
	if (item.text.length > 0)
		ev.text = item.text;

	// Forward Codex extras (fields this driver does not declare) to extras.
	ev.extras = extrasToFragment(item.extras);
	return ev;
}

/// The text of a completed reasoning item: its raw content when Codex has it,
/// else its summary. Each summary entry is a separate Markdown paragraph.
private string reasoningText(ThreadItem item)
{
	static string joined(SO parts, string separator)
	{
		if (parts.type != SO.Type.array)
			return null; // the schema allows either array to be absent
		import std.array : join;
		return jsonParse!(string[])(toJson(parts)).join(separator);
	}

	auto content = joined(item.content, "");
	return content.length > 0 ? content : joined(item.summary, "\n\n");
}

/// The events of a completed content item: item/completed and, for a tool
/// item, the item/result that follows it.
string[] itemCompletedEvents(ThreadItem item)
{
	assert(item.type != "userMessage" && item.type != "contextCompaction",
		"Codex " ~ item.type ~ " item is not a content item");

	bool isTool = threadItemEventType(item.type) == "tool_use";

	ItemCompletedEvent ev;
	ev.item_id = item.id;
	// Codex reports failure through the item's status.
	ev.is_error = item.status == "failed";

	if (isTool && item.aggregatedOutput.length > 0)
		ev.output = item.aggregatedOutput;

	// The final text of a reasoning item replaces whatever deltas built up.
	// A started item may already hold part or all of it, and deltas may or
	// may not follow, so only the completed item says what the text is.
	if (item.type == "reasoning")
	{
		auto text = reasoningText(item);
		if (text.length > 0)
			ev.text = text;
	}

	// Forward Codex extras (fields this driver does not declare) to extras.
	ev.extras = extrasToFragment(item.extras);

	// For webSearch items, propagate the completed query into the input field
	// so the frontend subtitle updates from the empty started-query to the real query.
	if (item.type == "webSearch" && item.query)
		ev.input = JSONFragment(`{"query":` ~ toJson(item.query) ~ `}`);

	auto events = [toJson(ev)];
	if (!isTool)
		return events;

	// item/result must come AFTER item/completed so the tool_use block is
	// already in content[] when reduceItemResult searches for it.
	ItemResultEvent resEv;
	resEv.item_id = item.id;
	resEv.is_error = ev.is_error;

	// mcpToolCall: McpToolCallError {message}; null unless the call failed.
	string toolErrorMessage;
	if (resEv.is_error)
	{
		@JSONPartial
		static struct ItemErrorPayload
		{
			@JSONOptional string message;
		}

		if (item.error.type == SO.Type.object)
			toolErrorMessage = jsonParse!ItemErrorPayload(toJson(item.error)).message;
		else if (item.error.type == SO.Type.string_)
			toolErrorMessage = jsonParse!string(toJson(item.error));
	}

	if (item.aggregatedOutput.length > 0)
		resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(item.aggregatedOutput) ~ `}]`);
	else
	{
		@JSONPartial
		static struct ResultPayload
		{
			@JSONOptional JSONFragment content;
			@JSONName("structuredContent") @JSONOptional JSONFragment structuredContent;
		}

		// mcpToolCall: McpToolCallResult; null when the call failed.
		bool hasResultContent = false;
		if (item.result.type == SO.Type.object)
		{
			auto payload = jsonParse!ResultPayload(toJson(item.result));
			if (payload.content.json !is null)
			{
				resEv.content = payload.content;
				hasResultContent = true;
			}
			if (payload.structuredContent.json !is null)
				resEv.tool_result = payload.structuredContent;
		}

		if (!hasResultContent)
		{
			if (item.type == "webSearch")
			{
				// Pass Codex web search data as structured tool_result for the frontend
				// to interpret. Set content to empty text (required field).
				if (toolErrorMessage.length > 0)
					resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
				else
					resEv.content = JSONFragment(`[{"type":"text","text":""}]`);

				import std.array : appender;
				auto tr = appender!string;
				tr ~= `{`;

				// Include the main query
				if (item.query)
					tr ~= `"query":` ~ toJson(item.query);

				// Include the queries array from action; action is null for
				// a search Codex did not classify.
				if (item.action.type == SO.Type.object)
				{
					@JSONPartial
					static struct WebSearchAction
					{
						@JSONOptional JSONFragment queries;  // preserve raw JSON
					}
					auto act = jsonParse!WebSearchAction(toJson(item.action));
					if (act.queries.json !is null)
					{
						if (item.query)
							tr ~= `,`;
						tr ~= `"queries":` ~ act.queries.json;
					}
				}

				tr ~= `}`;
				resEv.tool_result = JSONFragment(tr.data);
			}
			else if (toolErrorMessage.length > 0)
				resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
			else
				resEv.content = JSONFragment(`[{"type":"text","text":""}]`);
		}
	}

	// Build structured tool_result for commandExecution items.
	// Surfaces exitCode, status, durationMs, command, cwd for frontend rendering.
	if (item.type == "commandExecution")
	{
		string[] fields;
		if (item.status.length > 0)
			fields ~= `"status":` ~ toJson(item.status);
		// Null for a command that never ran to an exit.
		if (!item.exitCode.isNull)
			fields ~= `"exitCode":` ~ to!string(item.exitCode.get);
		if (!item.durationMs.isNull && item.durationMs.get > 0)
			fields ~= `"durationMs":` ~ to!string(item.durationMs.get);
		if (item.command.length > 0)
			fields ~= `"command":` ~ toJson(item.command);
		if (item.cwd.length > 0)
			fields ~= `"cwd":` ~ toJson(item.cwd);
		if (item.processId.length > 0)
			fields ~= `"processId":` ~ toJson(item.processId);
		if (item.commandActions)
			fields ~= `"commandActions":` ~ toJson(item.commandActions);
		if (fields.length > 0)
		{
			import std.array : join;
			resEv.tool_result = JSONFragment(`{` ~ fields.join(",") ~ `}`);
		}
	}

	return events ~ toJson(resEv);
}

/// The inputs of a user message (UserInput in the app-server schema).
@JSONPartial
private struct UserInput
{
	string type;
	@JSONOptional string text;   // text
	@JSONOptional string url;    // image, audio
	@JSONOptional string fileId; // image, audio
	@JSONOptional string path;   // localImage, localAudio, skill, mention
	@JSONOptional string name;   // skill, mention
}

private UserInput[] userInputs(ThreadItem item)
{
	assert(item.type == "userMessage", "Codex " ~ item.type ~ " item is not a user message");
	return jsonParse!(UserInput[])(toJson(item.content));
}

/// The item/started event of a user message. A text input is a text block
/// and an image given inline is an image block. An input CyDo cannot show
/// (an image, audio, skill or mention given by reference) is a text block
/// naming it. An input of a kind this driver does not know is left out of the
/// message and reported in `unrecognized`, as events to emit with it.
ItemStartedEvent userMessageEvent(ThreadItem item, out string[] unrecognized)
{
	import std.algorithm.searching : findSplit, startsWith;
	import cydo.protocol : makeUnrecognizedEvent;

	static ContentBlock textBlock(string text)
	{
		ContentBlock block;
		block.type = "text";
		block.text = text;
		return block;
	}

	ItemStartedEvent ev;
	ev.item_id = item.id;
	ev.item_type = "user_message";
	foreach (input; userInputs(item))
		switch (input.type)
		{
			case "text":
				ev.content ~= textBlock(input.text);
				break;
			case "image":
				if (!input.url.startsWith("data:"))
					ev.content ~= textBlock("[image: "
						~ (input.url.length > 0 ? input.url : input.fileId) ~ "]");
				else
				{
					auto parts = input.url["data:".length .. $].findSplit(";base64,");
					if (parts[1].length == 0)
						ev.content ~= textBlock("[image]"); // inline, in another encoding
					else
					{
						ContentBlock block;
						block.type = "image";
						block.media_type = parts[0];
						block.data = parts[2];
						ev.content ~= block;
					}
				}
				break;
			case "localImage":
				ev.content ~= textBlock("[image: " ~ input.path ~ "]");
				break;
			case "audio":
				ev.content ~= textBlock(input.url.startsWith("data:") ? "[audio]"
					: "[audio: " ~ (input.url.length > 0 ? input.url : input.fileId) ~ "]");
				break;
			case "localAudio":
				ev.content ~= textBlock("[audio: " ~ input.path ~ "]");
				break;
			case "skill":
				ev.content ~= textBlock("[skill: " ~ input.name ~ "]");
				break;
			case "mention":
				ev.content ~= textBlock("[mention: " ~ input.name ~ "]");
				break;
			default:
				unrecognized ~= makeUnrecognizedEvent(
					"unknown Codex user input type: " ~ input.type);
				break;
		}
	if (ev.content.length == 0)
		ev.content = [textBlock(null)];
	return ev;
}

/// The text of a user message: what its text inputs say.
string userMessageText(ThreadItem item)
{
	string text;
	foreach (input; userInputs(item))
		if (input.type == "text")
			text ~= input.text;
	return text;
}

/// The durable event of a completed context compaction.
string[] compactionEvents(ThreadItem item)
{
	assert(item.type == "contextCompaction",
		"Codex " ~ item.type ~ " item is not a context compaction");
	return [toJson(SessionCompactedEvent())];
}

/// The turn/result event of a finished turn. `lastAgentText` is the text of
/// the turn's last agent message.
TurnResultEvent turnResultEvent(Turn turn, string lastAgentText)
{
	TurnResultEvent tre;
	tre.num_turns = 1;
	tre.usage = UsageInfo(0, 0);
	tre.result = lastAgentText;
	if (turn.status == "failed")
	{
		auto message = extractCodexErrorMessage(turn.error);
		if (message.length == 0)
			message = "Unknown error";
		tre.subtype = "error";
		tre.is_error = true;
		tre.errors = [message];
		tre.result = lastAgentText.length > 0
			? lastAgentText ~ "\n\n" ~ message : message;
	}
	else
		tre.subtype = "success";
	if (turn.status == "interrupted")
		tre.end_reason = TurnEndReason.interrupted;
	return tre;
}

/// Translate a thread read from Codex (thread/read metadata, the turns of
/// thread/turns/list and the entries of thread/items/list, both in ascending
/// order) into the events of its history.
///
/// `liveTurnIds` are the turns a live session of this thread started itself.
/// It emits their events as they happen, so they are left out here; every
/// other turn was complete before that session attached. A turn that follows
/// a live turn without being one belongs to neither side and is an error.
TranslatedEvent[] translateThreadHistory(ThreadMetadata thread, Turn[] turns,
	ThreadItemEntry[] items, string systemKeyword, const bool[string] liveTurnIds = null)
{
	ThreadItem[][string] itemsByTurn;
	bool seenLiveTurn;
	foreach (ref turn; turns)
	{
		if (turn.id in liveTurnIds)
		{
			seenLiveTurn = true;
			continue;
		}
		enforce(!seenLiveTurn, "Codex turn " ~ turn.id
			~ " follows a turn of the live session, which did not start it");
		enforce(turn.status == "completed" || turn.status == "interrupted"
			|| turn.status == "failed",
			"Codex turn " ~ turn.id ~ " is " ~ turn.status ~ " but no live session runs it");
		itemsByTurn[turn.id] = null;
	}
	foreach (ref entry; items)
	{
		if (entry.turnId in liveTurnIds)
			continue;
		auto turnItems = entry.turnId in itemsByTurn;
		enforce(turnItems !is null, "Codex item " ~ entry.item.id
			~ " belongs to turn " ~ entry.turnId ~ ", which the thread does not list");
		*turnItems ~= entry.item;
	}

	SessionInitEvent init;
	init.session_id = thread.id;
	init.model = thread.model;
	init.cwd = thread.cwd;
	init.tools = [];
	init.agent_version = thread.cliVersion;
	init.permission_mode = "dangerously-skip-permissions";
	init.agent = "codex";
	auto events = [TranslatedEvent(toJson(init), toJson(thread))];

	foreach (ref turn; turns)
	{
		auto turnItems = turn.id in itemsByTurn;
		if (turnItems is null)
			continue; // a live turn

		auto rawTurn = toJson(turn);
		auto ts = turn.startedAt.isNull ? AbsTime.init : unixTime(turn.startedAt.get * 1000);
		bool seenUserMessage;
		bool itemsSinceStop;
		string lastAgentText;
		TurnStopEvent lastStop;
		size_t lastStopIndex;
		bool stopped;

		void stop()
		{
			lastStop = TurnStopEvent.init;
			lastStop.model = thread.model;
			lastStop.usage = UsageInfo(0, 0);
			lastStopIndex = events.length;
			stopped = true;
			itemsSinceStop = false;
			events ~= TranslatedEvent(toJson(lastStop), rawTurn, ts);
		}

		foreach (ref item; *turnItems)
		{
			auto rawItem = toJson(item);
			if (!item.completedAtMs.isNull)
				ts = unixTime(item.completedAtMs.get);
			else if (!item.startedAtMs.isNull)
				ts = unixTime(item.startedAtMs.get);

			switch (item.type)
			{
				case "userMessage":
					// A message sent into a running turn ends what the agent
					// had produced until then.
					if (itemsSinceStop)
						stop();
					string[] unrecognized;
					auto ev = userMessageEvent(item, unrecognized);
					auto text = userMessageText(item);
					import std.algorithm : any;

					ev.is_meta = isCodexPermissionsInstructionsText(text) || ev.content.any!(
						block => block.type == "text" && isCodexContextualFragment(block.text));
					attachUserBoundary(ev, turn.id, ev.is_meta || isSystemFramed(systemKeyword, text),
						seenUserMessage);
					events ~= TranslatedEvent(toJson(ev), rawItem, ts);
					foreach (event; unrecognized)
						events ~= TranslatedEvent(event, rawItem, ts);
					break;
				case "contextCompaction":
					foreach (event; compactionEvents(item))
						events ~= TranslatedEvent(event, rawItem, ts);
					break;
				default:
					events ~= TranslatedEvent(toJson(itemStartedEvent(item)), rawItem, ts);
					foreach (event; itemCompletedEvents(item))
						events ~= TranslatedEvent(event, rawItem, ts);
					itemsSinceStop = true;
					if (item.type == "agentMessage")
					{
						lastAgentText = item.text;
						stop();
					}
					break;
			}
		}
		if (itemsSinceStop)
			stop();
		if (stopped)
		{
			lastStop.history_boundary = HistoryBoundary("through:" ~ turn.id,
				HistoryBoundaryKind.agent_turn);
			events[lastStopIndex].translated = toJson(lastStop);
		}

		// Codex times a turn in whole seconds: its end can read as earlier
		// than its last item, which the result must not precede.
		if (!turn.completedAt.isNull
			&& unixTime(turn.completedAt.get * 1000).stdTime > ts.stdTime)
			ts = unixTime(turn.completedAt.get * 1000);
		events ~= TranslatedEvent(toJson(turnResultEvent(turn, lastAgentText)), rawTurn, ts);
	}
	return events;
}

private AbsTime unixTime(long msecs)
{
	import std.datetime.systime : unixTimeToStdTime;

	return AbsTime(unixTimeToStdTime(0) + msecs * 10_000);
}

/// Extract display-level command input from a live Codex commandExecution item.
string extractCommandExecutionInput(JSONFragment commandActions, JSONFragment action, string command)
{
	import cydo.protocol : CommandInput;

	string actionType;
	auto actionCommand = extractCommandActionsCommand(commandActions, actionType);
	if (command.length > 0)
	{
		if (actionType == "unknown" && actionCommand.length > 0)
			return toJson(CommandInput(actionCommand, ""));
		return toJson(CommandInput(command, ""));
	}

	if (actionCommand.length > 0)
		return toJson(CommandInput(actionCommand, ""));

	auto fromAction = extractCommandInput(action);
	if (fromAction.length > 0 && fromAction != `{}`)
		return fromAction;

	return `{}`;
}

/// Extract a fallback command from Codex commandActions when no executed command
/// field is available.
string extractCommandActionsInput(JSONFragment commandActions)
{
	auto command = extractCommandActionsCommand(commandActions);
	if (command.length == 0)
		return `{}`;

	import cydo.protocol : CommandInput;
	return toJson(CommandInput(command, ""));
}

/// Extract a single user-level command from Codex commandActions.
string extractCommandActionsCommand(JSONFragment commandActions)
{
	string actionType;
	return extractCommandActionsCommand(commandActions, actionType);
}

/// Extract a single user-level command and its action type from Codex commandActions.
string extractCommandActionsCommand(JSONFragment commandActions, out string actionType)
{
	if (commandActions.json is null || commandActions.json.length == 0)
		return "";

	// Every kind of command action Codex reports has these two.
	@JSONPartial
	static struct CommandAction
	{
		string type;
		string command;
	}

	auto actions = jsonParse!(CommandAction[])(commandActions.json);
	if (actions.length != 1 || actions[0].command.length == 0)
		return "";
	actionType = actions[0].type;
	return actions[0].command;
}

version (unittest)
{
	import cydo.agent.drivers.codex.rpc : ThreadItemsListResult, ThreadMetadataResult,
		ThreadTurnsListResult;
	import cydo.agent.drivers.codex.thread_items_fixtures;

	/// The turns of a captured thread/turns/list page, oldest first. The
	/// captures asked for no order and got Codex's default, newest first.
	package Turn[] ascendingTurns(string turnsPage)
	{
		import std.algorithm.mutation : reverse;

		auto page = jsonParse!ThreadTurnsListResult(turnsPage);
		assert(page.nextCursor is null);
		return page.data.reverse;
	}

	package ThreadItemEntry[] pageItems(string itemsPage)
	{
		auto page = jsonParse!ThreadItemsListResult(itemsPage);
		assert(page.nextCursor is null);
		return page.data;
	}

	package ThreadMetadata fixtureThread()
	{
		return jsonParse!ThreadMetadataResult(nineTurnThreadRead).thread;
	}

	/// One line per event, naming what the tests assert on. Turn ids in
	/// anchors are replaced by the turn's position: T1 is the oldest of `turns`.
	package string[] outline(TranslatedEvent[] events, Turn[] turns)
	{
		import std.array : replace;

		static struct Boundary
		{
			string anchor;
			string kind;
		}

		@JSONPartial
		static struct Probe
		{
			string type;
			@JSONOptional string item_id;
			@JSONOptional string item_type;
			@JSONOptional string name;
			@JSONOptional string text;
			@JSONOptional ContentBlock[] content;
			@JSONOptional bool is_meta;
			@JSONOptional bool is_error;
			@JSONOptional Boundary history_boundary;
			@JSONOptional string subtype;
			@JSONOptional string end_reason;
		}

		string[] lines;
		foreach (ref event; events)
		{
			auto probe = jsonParse!Probe(event.translated);
			string line;
			if (probe.type == "item/started" && probe.item_type == "user_message")
			{
				line = "user";
				foreach (ref block; probe.content)
					line ~= " " ~ (block.type == "text" ? "[" ~ block.text ~ "]" : block.type);
				if (probe.is_meta)
					line ~= " meta";
			}
			else if (probe.type == "item/started")
			{
				line = "start " ~ probe.item_type ~ " " ~ probe.item_id;
				if (probe.name.length > 0)
					line ~= " " ~ probe.name;
				if (probe.text.length > 0)
					line ~= " [" ~ probe.text ~ "]";
			}
			else if (probe.type == "item/completed")
				line = "done " ~ probe.item_id ~ (probe.is_error ? " error" : "")
					~ (probe.text.length > 0 ? " [" ~ probe.text ~ "]" : "");
			else if (probe.type == "item/result")
				line = "result " ~ probe.item_id ~ (probe.is_error ? " error" : "");
			else if (probe.type == "turn/result")
				line = "turn " ~ probe.subtype
					~ (probe.end_reason.length > 0 ? " " ~ probe.end_reason : "");
			else
				line = probe.type;
			if (probe.history_boundary.anchor.length > 0)
				line ~= " " ~ probe.history_boundary.kind ~ "=" ~ probe.history_boundary.anchor;
			foreach (i, ref turn; turns)
				line = line.replace(turn.id, "T" ~ to!string(i + 1));
			lines ~= line;
		}
		return lines;
	}

	private void assertOutline(string[] actual, string[] expected)
	{
		import std.array : join;

		assert(actual == expected, "\n" ~ actual.join("\n"));
	}
}

// The nine-turn thread: every kind of turn and the boundaries of each.
unittest
{
	auto turns = ascendingTurns(nineTurnTurnsPage);
	auto events = translateThreadHistory(fixtureThread(), turns, pageItems(nineTurnItemsPage), "SYSTEM");
	assertOutline(outline(events, turns), [
		"session/init",
		// reasoning
		`user [reply with "reasoning-fixture"] user=before:T1`,
		"start thinking rs_history_fixture",
		"done rs_history_fixture [fixture reasoning]",
		`start text msg_mock_00001 [reasoning-fixture]`,
		"done msg_mock_00001",
		"turn/stop agent_turn=through:T1",
		"turn success",
		// a command
		`user [run command printf success-marker] user=before:T2`,
		"start tool_use call_mock_00001 commandExecution",
		"done call_mock_00001",
		"result call_mock_00001",
		`start text msg_mock_00002 [Done.]`,
		"done msg_mock_00002",
		"turn/stop agent_turn=through:T2",
		"turn success",
		// a command that fails
		`user [run command printf failure-marker && exit 7] user=before:T3`,
		"start tool_use call_mock_00002 commandExecution",
		"done call_mock_00002 error",
		"result call_mock_00002 error",
		`start text msg_mock_00003 [Done.]`,
		"done msg_mock_00003",
		"turn/stop agent_turn=through:T3",
		"turn success",
		// a file change
		`user [codex filechange create fixture] user=before:T4`,
		"start tool_use call_mock_00003 fileChange",
		"done call_mock_00003",
		"result call_mock_00003",
		`start text msg_mock_00004 [Done.]`,
		"done msg_mock_00004",
		"turn/stop agent_turn=through:T4",
		"turn success",
		// an MCP call
		`user [call history MCP fixture] user=before:T5`,
		"start tool_use call_mock_00004 Task",
		"done call_mock_00004",
		"result call_mock_00004",
		`start text msg_mock_00005 [MCP done]`,
		"done msg_mock_00005",
		"turn/stop agent_turn=through:T5",
		"turn success",
		// a turn that fails before the agent produces anything: no
		// turn/stop, so no agent-turn boundary
		`user [fail with usage limit] user=before:T6`,
		"turn error",
		// a steered turn: the second user message ends the agent's output
		// so far and is not a boundary
		`user [run command printf steer-marker && sleep 2] user=before:T7`,
		"start tool_use call_mock_00005 commandExecution",
		"done call_mock_00005",
		"result call_mock_00005",
		"turn/stop",
		`user [reply with "steer accepted"]`,
		`start text msg_mock_00006 [steer accepted]`,
		"done msg_mock_00006",
		"turn/stop agent_turn=through:T7",
		"turn success",
		// an interrupted turn
		`user [run command sleep 9] user=before:T8`,
		"turn success interrupted",
		// a manual compaction: a turn of its own, without a user message
		"session/compacted",
		"turn success",
	]);

	@JSONPartial static struct Init
	{
		string session_id, model, cwd, agent_version, agent;
	}
	auto init = jsonParse!Init(events[0].translated);
	assert(init.session_id == "01a1feae-9e4c-7d83-a43c-dbd595e0221d" && init.model == "gpt-5.4"
		&& init.cwd == "/mnt/local/moved/home/vladimir/work/.cydo/tasks/39225/trace-fidelity-final"
		&& init.agent_version == "0.171.0" && init.agent == "codex");

	@JSONPartial static struct TurnResult
	{
		string result;
		bool is_error;
		@JSONOptional string[] errors;
	}
	// The failed turn reports Codex's error; a successful turn its last agent message.
	auto failed = jsonParse!TurnResult(events[41].translated);
	assert(failed.is_error && failed.errors == ["You’ve hit your usage limit. Try again later."]
		&& failed.result == failed.errors[0]);
	assert(jsonParse!TurnResult(events[39].translated).result == "MCP done");

	// Each event carries the item's time (the turn's, where the item has
	// none) and the object it was translated from. The turn completed at
	// second 219, by Codex's whole-second count: its result is not dated
	// before its last item.
	import std.algorithm.searching : canFind, startsWith;
	assert(events[1].ts == unixTime(1_795_274_219_154) && events[4].ts == unixTime(1_795_274_219_214)
		&& events[6].ts == events[4].ts && events[7].ts == events[4].ts);
	assert(events[4].raw.canFind(`"type":"agentMessage"`) && events[4].raw.canFind(`"id":"msg_mock_00001"`));
	assert(events[7].raw.startsWith(`{"id":"01a1feae-9e5b-7430-b501-883bafb074dd","status":"completed"`));
}

// Tool items carry the same input and result as the live events do.
unittest
{
	@JSONPartial static struct Event
	{
		string type;
		@JSONOptional JSONFragment input;
		@JSONOptional string output;
		@JSONOptional JSONFragment content;
		@JSONOptional JSONFragment tool_result;
		@JSONOptional string tool_server;
		@JSONOptional string tool_source;
	}

	Event[] itemEvents(string id)
	{
		foreach (ref entry; pageItems(nineTurnItemsPage))
			if (entry.item.id == id)
			{
				auto events = [jsonParse!Event(toJson(itemStartedEvent(entry.item)))];
				foreach (event; itemCompletedEvents(entry.item))
					events ~= jsonParse!Event(event);
				return events;
			}
		assert(false, id);
	}

	auto command = itemEvents("call_mock_00002");
	assert(command.length == 3);
	assert(command[0].input.json
		== `{"command":"printf failure-marker \u0026\u0026 exit 7","description":""}`,
		command[0].input.json);
	assert(command[1].output == "failure-marker");
	assert(command[2].type == "item/result"
		&& command[2].content.json == `[{"type":"text","text":"failure-marker"}]`);
	assert(command[2].tool_result.json == `{"status":"failed","exitCode":7,`
		~ `"command":"/run/current-system/sw/bin/zsh -lc 'printf failure-marker \u0026\u0026 exit 7'",`
		~ `"cwd":"/mnt/local/moved/home/vladimir/work/.cydo/tasks/39225/trace-fidelity-final",`
		~ `"processId":"69064","commandActions":[{"type":"unknown",`
		~ `"command":"printf failure-marker \u0026\u0026 exit 7"}]}`,
		command[2].tool_result.json);

	auto fileChange = itemEvents("call_mock_00003");
	assert(fileChange[0].input.json == `{"changes":[{"path":"/mnt/local/moved/home/vladimir/work/`
		~ `.cydo/tasks/39225/trace-fidelity-final/tmp/codex-fileviewer-create.txt",`
		~ `"kind":{"type":"add"},"diff":"hello from create fixture\n"}]}`, fileChange[0].input.json);
	assert(fileChange[2].content.json == `[{"type":"text","text":""}]`);

	auto mcp = itemEvents("call_mock_00004");
	assert(mcp[0].tool_server == "cydo" && mcp[0].tool_source == "mcp"
		&& mcp[0].input.json == `{"marker":"history-mcp-input"}`);
	assert(mcp[2].content.json == `[{"type":"text","text":"fixture success"}]`);

	// A command that never ran to an exit has no exit code to report.
	auto unfinished = jsonParse!ThreadItem(`{"type":"commandExecution","id":"call-declined",`
		~ `"command":"true","cwd":"/tmp","status":"declined","commandActions":[],`
		~ `"aggregatedOutput":null,"exitCode":null,"durationMs":null}`);
	assert(jsonParse!Event(itemCompletedEvents(unfinished)[1]).tool_result.json
		== `{"status":"declined","command":"true","cwd":"/tmp","commandActions":[]}`);

	// A failed MCP call reports its error.
	auto failedCall = jsonParse!ThreadItem(`{"type":"mcpToolCall","id":"call-failed","server":"cydo",`
		~ `"tool":"Task","status":"failed","arguments":{},"result":null,`
		~ `"error":{"message":"Transport closed"}}`);
	assert(jsonParse!Event(itemCompletedEvents(failedCall)[1]).content.json
		== `[{"type":"text","text":"Transport closed"}]`);
}

// A web search, from a captured item/completed.
unittest
{
	@JSONPartial static struct Event
	{
		string type;
		@JSONOptional string name;
		@JSONOptional JSONFragment input;
		@JSONOptional JSONFragment content;
		@JSONOptional JSONFragment tool_result;
	}

	auto search = jsonParse!ThreadItem(`{"type":"webSearch","id":"ws_mock_call_mock_00001",`
		~ `"query":"dagster incremental pipelines","action":{"type":"search",`
		~ `"query":"dagster incremental pipelines","queries":["dagster incremental pipelines"]},`
		~ `"results":null,"startedAtMs":1795287089896,"completedAtMs":1795287089897}`);
	assert(search.extras.length == 0);
	auto started = jsonParse!Event(toJson(itemStartedEvent(search)));
	assert(started.name == "webSearch"
		&& started.input.json == `{"query":"dagster incremental pipelines"}`);
	auto completed = itemCompletedEvents(search);
	assert(completed.length == 2);
	assert(jsonParse!Event(completed[0]).input.json == `{"query":"dagster incremental pipelines"}`);
	auto result = jsonParse!Event(completed[1]);
	assert(result.type == "item/result" && result.content.json == `[{"type":"text","text":""}]`
		&& result.tool_result.json == `{"query":"dagster incremental pipelines",`
			~ `"queries":["dagster incremental pipelines"]}`);
}

// An item type this driver does not know is displayed as text, with the
// fields it does not declare forwarded.
unittest
{
	// Schema-derived (0.171.0 ThreadItem `plan`): no capture has one.
	auto plan = jsonParse!ThreadItem(`{"type":"plan","id":"plan-1","text":"1. look","savedPath":"/tmp/p"}`);
	auto started = itemStartedEvent(plan);
	assert(started.item_type == "text" && started.item_id == "plan-1" && started.text == "1. look"
		&& started.extras.json == `{"savedPath":"/tmp/p"}`);
	assert(itemCompletedEvents(plan) == [`{"type":"item/completed","item_id":"plan-1",`
		~ `"extras":{"savedPath":"/tmp/p"}}`]);
}

// User messages with several inputs.
unittest
{
	// Schema-derived (0.171.0 UserInput): no capture has a user message with
	// anything but one text input.
	auto item = jsonParse!ThreadItem(`{"type":"userMessage","id":"user-1","clientId":null,`
		~ `"content":[{"type":"text","text":"first","text_elements":[]},`
		~ `{"type":"image","url":"data:image/png;base64,iVBORw0KGgo=","detail":null},`
		~ `{"type":"image","url":"data:image/svg+xml,%3Csvg/%3E","detail":null},`
		~ `{"type":"image","url":"https://example.com/remote.png","detail":null},`
		~ `{"type":"image","fileId":"file-1","detail":null},`
		~ `{"type":"localImage","path":"/tmp/local.png","detail":null},`
		~ `{"type":"audio","url":"https://example.com/remote.wav"},`
		~ `{"type":"audio","url":"data:audio/wav;base64,UklGRg=="},`
		~ `{"type":"audio","fileId":"file-2"},`
		~ `{"type":"localAudio","path":"/tmp/local.wav"},`
		~ `{"type":"skill","name":"review","path":"/skills/review/SKILL.md"},`
		~ `{"type":"mention","name":"notes","path":"app://notes"},`
		~ `{"type":"text","text":" last ","text_elements":[]}]}`);
	string[] unrecognized;
	auto message = userMessageEvent(item, unrecognized);
	assert(message.item_id == "user-1" && message.item_type == "user_message");
	assert(unrecognized.length == 0);
	assert(message.content.length == 13);
	assert(message.content[1].type == "image" && message.content[1].media_type == "image/png"
		&& message.content[1].data == "iVBORw0KGgo=");
	string[] texts;
	foreach (i, ref block; message.content)
		if (i != 1)
		{
			assert(block.type == "text");
			texts ~= block.text;
		}
	assert(texts == ["first", "[image]", "[image: https://example.com/remote.png]",
		"[image: file-1]", "[image: /tmp/local.png]", "[audio: https://example.com/remote.wav]",
		"[audio]", "[audio: file-2]", "[audio: /tmp/local.wav]", "[skill: review]",
		"[mention: notes]", " last "]);
	// Only what the user typed is the message's text.
	assert(userMessageText(item) == "first last ");
	assert(!message.is_meta && message.history_boundary == HistoryBoundary.init);

	// An input of a kind the schema does not have is reported, and the rest
	// of the message is kept.
	auto unknown = jsonParse!ThreadItem(`{"type":"userMessage","id":"user-2",`
		~ `"content":[{"type":"hologram","url":"https://example.com/h"},`
		~ `{"type":"text","text":"look","text_elements":[]}]}`);
	message = userMessageEvent(unknown, unrecognized);
	assert(message.content.length == 1 && message.content[0].text == "look");
	assert(unrecognized == [`{"type":"agent/unrecognized","reason":"unknown Codex user input type: hologram"}`],
		unrecognized[0]);

	// So it is in a history: the event follows the message.
	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 1];
	auto items = pageItems(nineTurnItemsPage)[0 .. 1];
	items[0].item.content = unknown.content;
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, items, "SYSTEM"), turns), [
		"session/init",
		"user [look] user=before:T1",
		"agent/unrecognized",
		"turn success",
	]);

	// A message with no inputs is still a message.
	auto empty = userMessageEvent(jsonParse!ThreadItem(
		`{"type":"userMessage","id":"user-3","content":[]}`), unrecognized);
	assert(unrecognized.length == 0 && empty.content.length == 1
		&& empty.content[0].type == "text" && empty.content[0].text.length == 0);
}

unittest
{
	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 1];
	auto items = pageItems(nineTurnItemsPage)[0 .. 1];
	items[0].item.content = jsonParse!ThreadItem(`{"type":"userMessage","id":"user-1",`
		~ `"content":[{"type":"text","text":"Ordinary text","text_elements":[]},`
		~ `{"type":"text","text":"<environment_context>cwd</environment_context>","text_elements":[]}]}`).content;
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, items, "SYSTEM"), turns), [
		"session/init",
		"user [Ordinary text] [<environment_context>cwd</environment_context>] meta",
		"turn success",
	]);
}

unittest
{
	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 2];
	auto page = pageItems(nineTurnItemsPage);
	auto openers = [page[0], page[3]];
	enum modeSwitch = "[CYDO: Mode switch: a -> b]\n\nx\n\n[/CYDO]";
	enum ordinary = "[SYSTEM: not ours]";
	openers[0].item.content = jsonParse!SO(`[{"type":"text","text":` ~ toJson(modeSwitch) ~ `}]`);
	openers[1].item.content = jsonParse!SO(`[{"type":"text","text":` ~ toJson(ordinary) ~ `}]`);
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, openers, "CYDO"), turns), [
		"session/init",
		"user [" ~ modeSwitch ~ "]",
		"turn success",
		"user [" ~ ordinary ~ "] user=before:T2",
		"turn success",
	]);
}

unittest
{
	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 1];
	auto items = pageItems(nineTurnItemsPage)[0 .. 1];
	enum taskPrompt = "[SYSTEM: Task prompt: x]\n\nbody\n\n[/SYSTEM]";
	items[0].item.content = jsonParse!SO(`[{"type":"text","text":` ~ toJson(taskPrompt) ~ `}]`);
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, items, "SYSTEM"), turns), [
		"session/init",
		"user [" ~ taskPrompt ~ "]",
		"turn success",
	]);
}

// A reasoning item's text is its content when it has any, else its summary,
// and is reported when the item completes.
unittest
{
	@JSONPartial static struct Completed
	{
		string type;
		@JSONOptional string text;
	}

	string completedText(string summary, string content)
	{
		auto item = jsonParse!ThreadItem(`{"type":"reasoning","id":"rs-1","summary":` ~ summary
			~ `,"content":` ~ content ~ `}`);
		assert(itemStartedEvent(item).text is null);
		auto events = itemCompletedEvents(item);
		assert(events.length == 1);
		return jsonParse!Completed(events[0]).text;
	}

	// Schema-derived variations of the captured items.
	assert(completedText(`["first part","second part"]`, `[]`) == "first part\n\nsecond part");
	assert(completedText(`["summary"]`, `["raw ","reasoning"]`) == "raw reasoning");
	assert(completedText(`[]`, `[]`) is null);

	auto captured = jsonParse!ThreadItemEntry(reasoningItemEntry).item;
	assert(itemStartedEvent(captured).text is null);
	assert(jsonParse!Completed(itemCompletedEvents(captured)[0]).text == "reason before shell");
}

// Variations on the captured thread.
unittest
{
	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 2];
	auto items = pageItems(nineTurnItemsPage)[0 .. 6];

	// A turn whose agent ran a tool and said nothing still ends in a turn/stop.
	assert(items[5].item.type == "agentMessage");
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, items[0 .. 5], "SYSTEM"), turns)[8 .. $], [
		`user [run command printf success-marker] user=before:T2`,
		"start tool_use call_mock_00001 commandExecution",
		"done call_mock_00001",
		"result call_mock_00001",
		"turn/stop agent_turn=through:T2",
		"turn success",
	]);

	// Bootstrap context occupies the opener position. A later steer cannot anchor it.
	auto context = items.dup;
	context[3].item.content = jsonParse!SO(
		`[{"type":"text","text":"[SYSTEM: Session start]\n\nrun it","text_elements":[]}]`);
	context[5].item = context[0].item;
	assertOutline(outline(translateThreadHistory(fixtureThread(), turns, context, "SYSTEM"), turns)[8 .. $], [
		"user [[SYSTEM: Session start]\n\nrun it]",
		"start tool_use call_mock_00001 commandExecution",
		"done call_mock_00001",
		"result call_mock_00001",
		"turn/stop agent_turn=through:T2",
		`user [reply with "reasoning-fixture"]`,
		"turn success",
	]);

	context[3].item.content = jsonParse!SO(
		`[{"type":"text","text":"<environment_context>context</environment_context>"}]`);
	auto replayed = outline(translateThreadHistory(fixtureThread(), turns, context, "SYSTEM"), turns);
	assert(replayed[8] == "user [<environment_context>context</environment_context>] meta");
}

// An automatic compaction is an item of the turn that triggered it.
unittest
{
	auto turns = ascendingTurns(autoCompactionTurnsPage);
	auto events = translateThreadHistory(fixtureThread(), turns, pageItems(autoCompactionItemsPage), "SYSTEM");
	assertOutline(outline(events, turns)[11 .. $], [
		"session/compacted",
		`user [reply with "after compaction"] user=before:T3`,
		`start text msg_mock_00004 [after compaction]`,
		"done msg_mock_00004",
		"turn/stop agent_turn=through:T3",
		"turn success",
	]);
}

// Codex resolves lineage: a fork child and a reverted thread list the turns
// and items they consist of, under the ids of the thread they came from.
unittest
{
	import std.algorithm.iteration : map;
	import std.array : array, replace;

	// The boundary anchors of a thread, by the positions its turns have in
	// the nine-turn thread.
	string[] anchors(string turnsPage, string itemsPage)
	{
		static struct Boundary
		{
			string anchor;
			string kind;
		}

		@JSONPartial static struct Probe
		{
			@JSONOptional Boundary history_boundary;
		}

		string[] result;
		foreach (ref event; translateThreadHistory(fixtureThread(), ascendingTurns(turnsPage),
			pageItems(itemsPage), "SYSTEM"))
		{
			auto anchor = jsonParse!Probe(event.translated).history_boundary.anchor;
			if (anchor.length == 0)
				continue;
			foreach (i, ref turn; ascendingTurns(nineTurnTurnsPage))
				anchor = anchor.replace(turn.id, "T" ~ to!string(i + 1));
			result ~= anchor;
		}
		return result;
	}

	// Forked at the fourth turn of the nine.
	assert(anchors(forkChildTurnsPage, forkChildItemsPage) == [
		"before:T1", "through:T1", "before:T2", "through:T2",
		"before:T3", "through:T3", "before:T4", "through:T4"]);
	assert(pageItems(forkChildItemsPage).map!(entry => entry.item.id).array
		== pageItems(nineTurnItemsPage)[0 .. 12].map!(entry => entry.item.id).array);

	// Reverted to before the eighth turn: the eighth and ninth are gone.
	assert(anchors(revertedTurnsPage, revertedItemsPage) == [
		"before:T1", "through:T1", "before:T2", "through:T2",
		"before:T3", "through:T3", "before:T4", "through:T4",
		"before:T5", "through:T5", "before:T6", "before:T7", "through:T7"]);
	assert(pageItems(revertedItemsPage).map!(entry => entry.item.id).array
		== pageItems(nineTurnItemsPage)[0 .. 20].map!(entry => entry.item.id).array);
}

// The turns a live session started are its own to report.
unittest
{
	import std.exception : collectExceptionMsg;

	auto turns = ascendingTurns(nineTurnTurnsPage)[0 .. 3];
	auto items = pageItems(nineTurnItemsPage)[0 .. 9];
	auto thread = fixtureThread();

	auto durable = outline(translateThreadHistory(thread, turns[0 .. 2], items[0 .. 6], "SYSTEM"), turns);
	assert(durable.length == 16 && durable[$ - 2] == "turn/stop agent_turn=through:T2");
	assert(outline(translateThreadHistory(thread, turns, items, "SYSTEM", [turns[2].id: true]), turns) == durable);

	// A turn after a live one that the session did not start.
	assert(collectExceptionMsg(translateThreadHistory(thread, turns, items, "SYSTEM", [turns[1].id: true]))
		== "Codex turn " ~ turns[2].id ~ " follows a turn of the live session, which did not start it");
	// A turn still running without a live session to run it.
	auto running = turns.dup;
	running[2].status = "inProgress";
	assert(collectExceptionMsg(translateThreadHistory(thread, running, items, "SYSTEM"))
		== "Codex turn " ~ turns[2].id ~ " is inProgress but no live session runs it");
	// An item of a turn the thread does not list.
	assert(collectExceptionMsg(translateThreadHistory(thread, turns[0 .. 2], items, "SYSTEM"))
		== "Codex item " ~ items[6].item.id ~ " belongs to turn " ~ turns[2].id
			~ ", which the thread does not list");
}
