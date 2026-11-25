/// Reading a Codex thread's history: over the app-server for the threads it
/// keeps an index of, from the rollout file it names for the older ones.
module cydo.agent.drivers.codex.history;

import std.exception : enforce;

import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.json : jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.agent.contract : DriverHistory;
import cydo.agent.drivers.codex.rollout : computeRollbackSkipLines, scanRollout;
import cydo.agent.drivers.codex : CodexAgent;
import cydo.agent.drivers.codex.user_message : CodexUserItemKind;
import cydo.agent.drivers.codex.rpc : ThreadItemEntry, ThreadItemsListParams,
	ThreadItemsListResult, ThreadMetadata, ThreadMetadataResult, ThreadReadParams,
	ThreadTurnsListParams, ThreadTurnsListResult, Turn;
import cydo.agent.drivers.codex.thread_items : attachUserBoundary, translateThreadHistory;
import cydo.foundation.system.framing : isSystemFramed;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind, ItemStartedEvent,
	TranslatedEvent, TurnStopEvent;

package(cydo):

/// How Codex stores a thread, as `thread/read` reports it. Threads written
/// before Codex kept a history index can be forked but not reverted.
enum CodexHistoryMode : ubyte
{
	legacy = 1,
	paginated = 2,
}

alias CodexRequest = Promise!JsonRpcResponse delegate(string method, string params);

private T resultOf(T)(JsonRpcResponse response)
{
	if (response.isError)
		throw new Exception(response.error.get.message);
	return response.getResult!T();
}

/// Read the whole history of `threadId`. `liveTurnIds` is asked once all of
/// it has arrived, so a turn the live session started meanwhile is left to it.
Promise!DriverHistory readThreadHistory(CodexRequest request, string threadId, string systemKeyword,
	const(bool[string]) delegate() liveTurnIds, string delegate(string path) readRollout)
{
	auto result = new Promise!DriverHistory;
	ThreadMetadata thread;
	Turn[] turns;
	ThreadItemEntry[] items;

	void fail(Exception e)
	{
		result.reject(e);
	}

	// A handler that throws rejects the read.
	void step(T)(Promise!JsonRpcResponse response, void delegate(T) next)
	{
		response.then((JsonRpcResponse raw) {
			try
				next(resultOf!T(raw));
			catch (Exception e)
				fail(e);
		}, &fail).ignoreResult();
	}

	void readItems(string cursor)
	{
		ThreadItemsListParams params;
		params.threadId = threadId;
		params.sortDirection = "asc";
		params.limit = 100;
		params.cursor = cursor;
		step!ThreadItemsListResult(request("thread/items/list", toJson(params)),
			(ThreadItemsListResult page) {
				items ~= page.data;
				if (page.nextCursor.length > 0)
					return readItems(page.nextCursor);
				result.fulfill(DriverHistory(
					translateThreadHistory(thread, turns, items, systemKeyword, liveTurnIds()),
					CodexHistoryMode.paginated));
			});
	}

	void readTurns(string cursor)
	{
		ThreadTurnsListParams params;
		params.threadId = threadId;
		params.itemsView = "summary";
		params.sortDirection = "asc";
		params.limit = 100;
		params.cursor = cursor;
		step!ThreadTurnsListResult(request("thread/turns/list", toJson(params)),
			(ThreadTurnsListResult page) {
				turns ~= page.data;
				if (page.nextCursor.length > 0)
					return readTurns(page.nextCursor);
				readItems(null);
			});
	}

	step!ThreadMetadataResult(request("thread/read", toJson(ThreadReadParams(threadId, false))),
		(ThreadMetadataResult metadata) {
			thread = metadata.thread;
			enforce(thread.id == threadId, "thread/read returned a different thread");
			switch (thread.historyMode)
			{
				case "paginated":
					readTurns(null);
					break;
				case "legacy":
					enforce(thread.path.length > 0, "Codex named no rollout file for a legacy thread");
					result.fulfill(DriverHistory(
						decodeLegacyRollout(readRollout(thread.path), systemKeyword, liveTurnIds()),
						CodexHistoryMode.legacy));
					break;
				default:
					throw new Exception("Unknown Codex history mode: " ~ thread.historyMode);
			}
		});
	return result;
}

/// Translate a legacy rollout. Its turns are the stretches that follow a
/// `task_started` record; the ones that record carries an id for get the
/// boundaries Codex can cut at.
TranslatedEvent[] decodeLegacyRollout(string content, string systemKeyword,
	const bool[string] liveTurnIds)
{
	import std.conv : to;
	import std.string : lineSplitter;

	auto scan = scanRollout(content);
	auto rolledBack = computeRollbackSkipLines(scan);
	bool seenTaskStarted;
	TranslatedEvent[] events;
	string turnId;
	bool live;
	bool seenLiveTurn;
	bool seenUserMessage;
	ptrdiff_t lastStop = -1;

	void endTurn()
	{
		if (turnId.length > 0 && lastStop >= 0)
		{
			auto stop = jsonParse!TurnStopEvent(events[lastStop].translated);
			stop.history_boundary = HistoryBoundary("through:" ~ turnId,
				HistoryBoundaryKind.agent_turn);
			events[lastStop].translated = toJson(stop);
		}
		lastStop = -1;
		seenUserMessage = false;
	}

	ptrdiff_t pendingUser = -1;
	string pendingUserText;
	int lineNumber;
	foreach (line; content.lineSplitter)
	{
		lineNumber++;
		if (line.length == 0)
			continue;
		auto evidence = &scan[lineNumber - 1];
		enforce(evidence.parsed, "Cannot decode Codex rollout line " ~ lineNumber.to!string);
		if (lineNumber in rolledBack)
			continue;
		if (evidence.probe.isTaskStarted)
		{
			endTurn();
			turnId = evidence.eventTurnIdValid ? evidence.eventTurnId : null;
			live = (turnId in liveTurnIds) !is null;
			seenLiveTurn = seenLiveTurn || live;
			enforce(live || !seenLiveTurn, "Codex turn " ~ turnId
				~ " follows a turn of the live session, which did not start it");
		}
		if (live)
			continue;
		// A submitted legacy input is recorded as a user response followed by
		// its user_message event. Codex's own user-role context has no such event.
		if (pendingUser >= 0 && evidence.probe.isEventMsg
			&& evidence.payloadType == "user_message" && evidence.eventMessageValid
			&& evidence.eventMessage == pendingUserText)
		{
			auto user = jsonParse!ItemStartedEvent(events[pendingUser].translated);
			attachUserBoundary(user, turnId,
				user.is_meta || isSystemFramed(systemKeyword, pendingUserText), seenUserMessage);
			events[pendingUser].translated = toJson(user);
		}
		pendingUser = -1;
		foreach (event; CodexAgent.translateLegacyRolloutLine(line, *evidence, seenTaskStarted))
		{
			if (evidence.probe.isForkableMessage)
			{
				// The file replay named these events after their line.
				if (evidence.probe.isUserMessage && evidence.user.kind != CodexUserItemKind.unrecognized)
				{
					auto user = jsonParse!ItemStartedEvent(event.translated);
					user.uuid = null;
					user.item_id = "codex-user-hist-" ~ lineNumber.to!string;
					event.translated = toJson(user);
					pendingUser = events.length;
					pendingUserText = evidence.user.message();
				}
				else if (evidence.probe.isAssistantMessage && isTurnStop(event.translated))
				{
					auto stop = jsonParse!TurnStopEvent(event.translated);
					stop.uuid = null;
					event.translated = toJson(stop);
					lastStop = events.length;
				}
			}
			events ~= event;
		}
	}
	endTurn();
	return events;
}

private bool isTurnStop(string translated)
{
	import ae.utils.json : JSONPartial;

	@JSONPartial static struct Probe { string type; }
	return jsonParse!Probe(translated).type == "turn/stop";
}

version (unittest)
{
	import ae.utils.json : JSONOptional, JSONPartial;

	import cydo.agent.drivers.codex.history_fixtures;

	@JSONPartial private struct EventProbe
	{
		string type;
		@JSONOptional string item_type;
		@JSONOptional string item_id;
		@JSONOptional bool is_meta;
		@JSONOptional string uuid;
		@JSONOptional HistoryBoundary history_boundary;
	}

	private TranslatedEvent[] decodeLegacy(string content, const bool[string] liveTurnIds = null,
		string systemKeyword = "SYSTEM")
	{
		return decodeLegacyRollout(content, systemKeyword, liveTurnIds);
	}

	/// The boundaries of `events`, as "<event type> <anchor>".
	private string[] boundariesOf(TranslatedEvent[] events)
	{
		string[] result;
		foreach (event; events)
		{
			auto probe = jsonParse!EventProbe(event.translated);
			if (probe.history_boundary.anchor.length == 0)
				continue;
			assert(probe.history_boundary.kind == (probe.type == "turn/stop"
				? HistoryBoundaryKind.agent_turn : HistoryBoundaryKind.user));
			result ~= probe.type ~ " " ~ probe.history_boundary.anchor;
		}
		return result;
	}

	private string[] legacyLines()
	{
		import std.array : array;
		import std.string : lineSplitter;

		return legacyRollout.lineSplitter.array;
	}
}

// A rollout of Codex 0.144.1: its two turns are cut at the ids Codex gave
// them, and its shell command is there with its output.
unittest
{
	import std.algorithm : canFind, count, filter, map;
	import std.array : array, join;

	auto events = decodeLegacy(legacyRollout);
	assert(boundariesOf(events) == [
		"item/started before:" ~ legacyRolloutFirstTurn,
		"turn/stop through:" ~ legacyRolloutFirstTurn,
		"item/started before:" ~ legacyRolloutSecondTurn,
		"turn/stop through:" ~ legacyRolloutSecondTurn,
	]);
	auto all = events.map!(event => event.translated).join("\n");
	assert(!all.canFind("line:"), "a Codex history names no rollout lines");
	assert(all.canFind("printf legacy-marker"));
	assert(all.canFind(`Process exited with code 0`) && all.canFind(`legacy-marker"`));

	// What Codex put into the conversation is no message of the user's.
	auto users = events.map!(event => jsonParse!EventProbe(event.translated))
		.filter!(probe => probe.item_type == "user_message").array;
	assert(users.count!(probe => probe.is_meta) == 2);
	assert(users.count!(probe => !probe.is_meta) == 2);
	foreach (probe; users)
		assert(probe.uuid.length == 0
			&& (probe.is_meta || probe.item_id.length > "codex-user-hist-".length));
}

unittest
{
	import std.array : join;

	void checkOpener(string text, HistoryBoundary boundary)
	{
		auto response = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":`
			~ toJson(text) ~ "}]}}";
		auto event = `{"type":"event_msg","payload":{"type":"user_message","message":`
			~ toJson(text) ~ "}}";
		auto events = decodeLegacy([legacyLines()[1], response, event].join("\n"), null, "CYDO");
		assert(events.length == 1);
		auto user = jsonParse!ItemStartedEvent(events[0].translated);
		assert(user.item_type == "user_message" && user.content[0].text == text);
		assert(!user.is_meta);
		assert(user.history_boundary == boundary);
	}

	checkOpener("[CYDO: Task prompt: x]\n\nbody\n\n[/CYDO]", HistoryBoundary.init);
	checkOpener("[SYSTEM: not ours]",
		HistoryBoundary("before:" ~ legacyRolloutFirstTurn, HistoryBoundaryKind.user));
}

unittest
{
	import std.array : join;

	enum media = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image>"},{"type":"input_image","file_id":"file-image"},{"type":"input_text","text":"</image>"}`;
	foreach (text; ["Explain.", ""])
	{
		auto response = media ~ (text.length ? `,{"type":"input_text","text":"Explain."}` : "") ~ "]}}";
		auto event = `{"type":"event_msg","payload":{"type":"user_message","message":` ~ toJson(text) ~ "}}";
		assert(boundariesOf(decodeLegacy([legacyLines()[1], response, event].join("\n")))
			== ["item/started before:" ~ legacyRolloutFirstTurn]);
	}
}

unittest
{
	import std.array : join;

	foreach (part; [
		`{"type":"input_audio","audio_url":42}`,
		`{"type":"input_audio","file_id":42}`,
		`{"type":"input_image","file_id":"image","detail":42}`,
		`{"type":"input_image","image_url":"image","detail":"unknown"}`,
		`{"type":"output_text","text":"output","annotations":{}}`,
		`{"type":"output_text","text":"output","logprobs":42}`,
	])
	{
		auto malformed = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Listen."},` ~ part ~ "]}}";
		auto events = decodeLegacy([legacyLines()[1], malformed,
			`{"type":"event_msg","payload":{"type":"user_message","message":"Listen."}}`,
		].join("\n"));
		assert(events.length == 1 && events[0].raw == malformed);
		auto event = jsonParse!EventProbe(events[0].translated);
		assert(event.type == "agent/unrecognized");
		assert(event.history_boundary == HistoryBoundary.init);
	}
}

unittest
{
	import std.array : join;
	import cydo.agent.drivers.codex.history_fixtures : nativeUserSchemaCases, nativeUserSchemaLine;

	foreach (fixture; nativeUserSchemaCases)
	{
		auto response = nativeUserSchemaLine(fixture);
		auto event = `{"type":"event_msg","payload":{"type":"user_message","message":`
			~ toJson(fixture.message.length == 0 ? "" : fixture.message) ~ "}}";
		auto events = decodeLegacy([legacyLines()[1], response, event].join("\n"));
		assert(events.length == 1 && events[0].raw == response, response);
		if (fixture.title is null)
		{
			assert(jsonParse!EventProbe(events[0].translated).type == "agent/unrecognized", response);
			assert(boundariesOf(events).length == 0, response);
		}
		else
		{
			assert(boundariesOf(events) == ["item/started before:" ~ legacyRolloutFirstTurn], response);
			if (fixture.renderedMediaType !is null)
				assert(jsonParse!ItemStartedEvent(events[0].translated).content[0].type
					== fixture.renderedMediaType, response);
		}
	}
}

// Variations on that rollout.
unittest
{
	import std.algorithm : canFind, map;
	import std.array : join, replace;
	import std.exception : assertThrown;

	auto lines = legacyLines();
	assert(lines[14].canFind(`"task_started"`) && lines[14].canFind(legacyRolloutSecondTurn));

	// Without the second task_started, the second message is steered into
	// the first turn, whose first answer is no longer its last.
	auto steered = decodeLegacy((lines[0 .. 14] ~ lines[15 .. $]).join("\n"));
	assert(boundariesOf(steered) == [
		"item/started before:" ~ legacyRolloutFirstTurn,
		"turn/stop through:" ~ legacyRolloutFirstTurn,
	]);
	assert(steered[$ - 1].translated.canFind(`"turn/result"`));
	bool[] stopsWithBoundary;
	foreach (event; steered)
		if (jsonParse!EventProbe(event.translated).type == "turn/stop")
			stopsWithBoundary ~= event.translated.canFind("through:");
	assert(stopsWithBoundary.length > 1 && stopsWithBoundary[$ - 1]
		&& !stopsWithBoundary[0 .. $ - 1].canFind(true),
		"the boundary belongs to the turn's last answer");

	// A turn whose task_started carries no id cannot be named to Codex.
	auto anonymous = lines.dup;
	anonymous[14] = anonymous[14].replace(`"turn_id":"` ~ legacyRolloutSecondTurn ~ `",`, "");
	assert(boundariesOf(decodeLegacy(anonymous.join("\n"))) == [
		"item/started before:" ~ legacyRolloutFirstTurn,
		"turn/stop through:" ~ legacyRolloutFirstTurn,
	]);

	// A turn Codex rolled back is gone.
	auto rolledBack = decodeLegacy(legacyRollout ~ "\n"
		~ `{"timestamp":"2026-11-21T15:15:00.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`);
	assert(boundariesOf(rolledBack) == [
		"item/started before:" ~ legacyRolloutFirstTurn,
		"turn/stop through:" ~ legacyRolloutFirstTurn,
	]);
	assert(!rolledBack.map!(event => event.translated).join.canFind("legacy-marker"));

	// The turns of a live session are left to it; what precedes them was
	// complete before it attached.
	auto durable = decodeLegacy(legacyRollout, [legacyRolloutSecondTurn: true]);
	assert(boundariesOf(durable) == [
		"item/started before:" ~ legacyRolloutFirstTurn,
		"turn/stop through:" ~ legacyRolloutFirstTurn,
	]);
	assert(!durable.map!(event => event.translated).join.canFind("legacy-marker"));
	assertThrown!Exception(decodeLegacy(legacyRollout, [legacyRolloutFirstTurn: true]));
}

version (unittest) private final class FakeAppServer
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import ae.utils.serialization.store : SerializedObject;

	alias SO = SerializedObject!(immutable(char));

	static struct Call
	{
		string method;
		string params;
	}

	Call[] calls;
	/// What to answer each request with, in order: a result, or an error message.
	string[] results;
	string failWith;

	Promise!JsonRpcResponse request(string method, string params)
	{
		auto answer = new Promise!JsonRpcResponse;
		JsonRpcResponse response;
		if (calls.length == results.length)
			response.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest, failWith);
		else
			response.result = jsonParse!SO(results[calls.length]);
		calls ~= Call(method, params);
		answer.fulfill(response);
		return answer;
	}
}

version (unittest) private struct ReadOutcome
{
	DriverHistory history;
	string failure;
}

version (unittest) private ReadOutcome readWith(FakeAppServer server,
	const(bool[string]) delegate() liveTurnIds = null, string rollout = null,
	string* rolloutPath = null)
{
	import cydo.foundation.testing : drainNextTicks;

	ReadOutcome outcome;
	bool settled;
	readThreadHistory(&server.request, "01a1feae-9e4c-7d83-a43c-dbd595e0221d", "SYSTEM",
		liveTurnIds is null ? delegate const(bool[string])() => null : liveTurnIds,
		(string path) {
			assert(rolloutPath !is null, "a paginated thread is read over the app-server only");
			*rolloutPath = path;
			return rollout;
		})
	.then((DriverHistory history) { outcome.history = history; settled = true; },
		(Exception e) { outcome.failure = e.msg; settled = true; }).ignoreResult();
	drainNextTicks();
	assert(settled, "the read did not settle");
	return outcome;
}

// A paginated thread is read page by page, turns before items, both in
// ascending order and never with their items materialized by Codex.
unittest
{
	import std.algorithm : canFind, filter, map, reverse;
	import std.array : array;

	import cydo.agent.drivers.codex.thread_items_fixtures : nineTurnItemsPage,
		nineTurnThreadRead, nineTurnTurnsPage;

	auto thread = jsonParse!ThreadMetadataResult(nineTurnThreadRead).thread;
	auto turns = jsonParse!ThreadTurnsListResult(nineTurnTurnsPage).data;
	turns.reverse();
	auto items = jsonParse!ThreadItemsListResult(nineTurnItemsPage).data;
	assert(turns.length == 9 && items.length > 4);
	string turnsPage(Turn[] page, string next) =>
		toJson(ThreadTurnsListResult(page, next));
	string itemsPage(ThreadItemEntry[] page, string next) =>
		toJson(ThreadItemsListResult(page, next));

	auto server = new FakeAppServer;
	server.results = [nineTurnThreadRead, turnsPage(turns[0 .. 5], "turns-2"),
		turnsPage(turns[5 .. $], null), itemsPage(items[0 .. 3], "items-2"),
		itemsPage(items[3 .. $], null)];
	auto read = readWith(server);
	assert(read.failure is null, read.failure);
	assert(read.history.mode == CodexHistoryMode.paginated);
	assert(read.history.events.map!(event => event.translated).array
		== translateThreadHistory(thread, turns, items, "SYSTEM").map!(event => event.translated).array);

	assert(server.calls.map!(call => call.method).array == ["thread/read",
		"thread/turns/list", "thread/turns/list", "thread/items/list", "thread/items/list"]);
	assert(server.calls[0].params
		== `{"threadId":"01a1feae-9e4c-7d83-a43c-dbd595e0221d","includeTurns":false}`);
	assert(server.calls[1].params == `{"threadId":"01a1feae-9e4c-7d83-a43c-dbd595e0221d",`
		~ `"itemsView":"summary","sortDirection":"asc","limit":100}`);
	assert(server.calls[2].params == `{"threadId":"01a1feae-9e4c-7d83-a43c-dbd595e0221d",`
		~ `"itemsView":"summary","sortDirection":"asc","limit":100,"cursor":"turns-2"}`);
	assert(server.calls[3].params == `{"threadId":"01a1feae-9e4c-7d83-a43c-dbd595e0221d",`
		~ `"sortDirection":"asc","limit":100}`);
	assert(server.calls[4].params == `{"threadId":"01a1feae-9e4c-7d83-a43c-dbd595e0221d",`
		~ `"sortDirection":"asc","limit":100,"cursor":"items-2"}`);

	// The turns a live session started are its own to tell. Its set is asked
	// for when the pages are in: a turn it started after the turn list was
	// read is known to it by then, and that turn's items are left out too.
	auto lastTurn = turns[$ - 1].id;
	bool asked;
	server = new FakeAppServer;
	server.results = [nineTurnThreadRead, turnsPage(turns[0 .. $ - 1], null),
		itemsPage(items, null)];
	read = readWith(server, () {
		assert(server.calls.length == 3, "the live turns are asked for after the last page");
		asked = true;
		return cast(const(bool[string])) [lastTurn: true];
	});
	assert(asked && read.failure is null, read.failure);
	assert(read.history.events.map!(event => event.translated).array
		== translateThreadHistory(thread, turns[0 .. $ - 1],
			items.filter!(entry => entry.turnId != lastTurn).array, "SYSTEM")
			.map!(event => event.translated).array);

	// Without a session to account for it, such an item is an error, and so
	// is a turn after a live one that the session did not start.
	server = new FakeAppServer;
	server.results = [nineTurnThreadRead, turnsPage(turns[0 .. $ - 1], null),
		itemsPage(items, null)];
	assert(readWith(server).failure.canFind("which the thread does not list"));
	server = new FakeAppServer;
	server.results = [nineTurnThreadRead, turnsPage(turns, null), itemsPage(items, null)];
	assert(readWith(server, () => cast(const(bool[string])) [turns[$ - 2].id: true])
		.failure.canFind("follows a turn of the live session"));

	// Codex 0.171.0 preserves the original preview after revert-all. These
	// are the fields the reader uses from the review's cold thread/read and
	// empty page responses, with the fixture's thread ID.
	enum revertedThread = `{"thread":{"id":"01a1feae-9e4c-7d83-a43c-dbd595e0221d",`
		~ `"historyMode":"paginated","cwd":"/workspace","cliVersion":"0.171.0",`
		~ `"model":"codex-mini-latest","modelProvider":"cydo-mock",`
		~ `"preview":"reply with \"first\"","turns":[]}}`;
	enum emptyPage = `{"data":[],"nextCursor":null,"backwardsCursor":null}`;
	server = new FakeAppServer;
	server.results = [revertedThread, emptyPage, emptyPage];
	read = readWith(server);
	assert(read.failure is null, read.failure);
	assert(read.history.mode == CodexHistoryMode.paginated);
	assert(read.history.events.length == 1);
	assert(server.calls.length == 3);

	// A thread nothing was ever said in has no turns either.
	auto silent = thread;
	silent.preview = "";
	server = new FakeAppServer;
	server.results = [toJson(ThreadMetadataResult(silent)), turnsPage(null, null),
		itemsPage(null, null)];
	read = readWith(server);
	assert(read.failure is null && read.history.events.length == 1);

	// Codex's refusal is the reason the history is unavailable.
	server = new FakeAppServer;
	server.failWith = "thread not found";
	assert(readWith(server).failure.canFind("thread not found"));
	server = new FakeAppServer;
	server.results = [nineTurnThreadRead];
	server.failWith = "turns unavailable";
	assert(readWith(server).failure.canFind("turns unavailable"));
}

// A legacy thread is decoded from the rollout file Codex names.
unittest
{
	auto legacy = ThreadMetadata("01a1feae-9e4c-7d83-a43c-dbd595e0221d", "legacy",
		"/profile/sessions/rollout.jsonl", "/workspace", "0.144.1", "model", "openai",
		"reply");
	auto server = new FakeAppServer;
	server.results = [toJson(ThreadMetadataResult(legacy))];
	string path;
	auto read = readWith(server, null, legacyRollout, &path);
	assert(read.failure is null, read.failure);
	assert(path == "/profile/sessions/rollout.jsonl" && server.calls.length == 1);
	assert(read.history.mode == CodexHistoryMode.legacy);
	assert(boundariesOf(read.history.events).length == 4);
}

// A malformed line must reject the read even after valid turns were decoded.
unittest
{
	import std.algorithm : startsWith;

	auto legacy = ThreadMetadata("01a1feae-9e4c-7d83-a43c-dbd595e0221d", "legacy",
		"/profile/sessions/rollout.jsonl", "/workspace", "0.144.1", "model", "openai",
		"reply");
	auto server = new FakeAppServer;
	server.results = [toJson(ThreadMetadataResult(legacy))];
	string path;
	auto read = readWith(server, null, legacyRollout ~ "\nnot json\n", &path);
	assert(path == legacy.path && server.calls.length == 1);
	assert(read.failure.startsWith("Cannot decode Codex rollout line "),
		"Malformed legacy rollout must reject the history read");
}

// Record shapes of legacy rollouts, as the line translators render them.
unittest
{
	import std.algorithm : canFind, filter, map;
	import std.array : array, join;

	string record(string payload)
	{
		return `{"timestamp":"2026-03-27T07:32:23.000Z","type":"response_item","payload":`
			~ payload ~ `}`;
	}
	string[] translated(string[] records)
	{
		auto base = decodeLegacy(legacyRollout).length;
		return decodeLegacy(legacyRollout ~ "\n" ~ records.join("\n"))[base .. $]
			.map!(event => event.translated).array;
	}

	// A tool result that is a JSON document is shown as that document.
	enum taskError = "Task type 'execute' is not in creatable_tasks for 'plan_mode'";
	auto task = translated([
		record(`{"type":"function_call","call_id":"call_task","name":"mcp__cydo__Task",`
			~ `"arguments":"{\"tasks\":[{\"task_type\":\"execute\"}]}"}`),
		record(`{"type":"function_call_output","call_id":"call_task","output":`
			~ toJson(toJson(["tasks": [taskError]])) ~ `}`),
	]);
	assert(task.length == 4 && task[0].canFind(`"item/started"`)
		&& task[0].canFind(`"name":"Task"`) && task[0].canFind(`"tool_server":"cydo"`),
		task.join("\n"));
	assert(task[3].canFind(`"item/result"`) && task[3].canFind(taskError), task.join("\n"));

	auto search = translated([record(`{"type":"web_search_call","status":"completed","action":`
		~ `{"type":"search","query":"dagster incremental pipelines","queries":`
		~ `["dagster incremental pipelines","dagster asset partitions docs"]}}`)]);
	assert(search.filter!(event => event.canFind("webSearch")).array.length > 0);
	assert(search.join.canFind("dagster asset partitions docs"));

	// A payload type CyDo does not know is reported, not dropped.
	auto unknown = translated([record(`{"type":"future_codex_payload"}`)]);
	assert(unknown.length == 1 && unknown[0].canFind(
		"unknown Codex response_item payload type: future_codex_payload"));
}

version (unittest)
{
	private string taggedLegacyUser(string content, string kinds)
	{
		return legacyRollout ~ "\n"
			~ "{\"timestamp\":\"2026-03-27T07:32:23.000Z\",\"type\":\"response_item\","
			~ "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":" ~ content
			~ ",\"internal_chat_message_metadata_passthrough\":{\"content_item_kinds\":" ~ kinds ~ "}}}";
	}
}

// Replayed context retains its kinds through the user event round trip.
unittest
{
	enum content = "[{\"type\":\"input_text\",\"text\":\"<recommended_plugins>plugins</recommended_plugins>\"},"
		~ "{\"type\":\"input_text\",\"text\":\"# AGENTS.md instructions for /x\\n<INSTRUCTIONS>instructions</INSTRUCTIONS>\"},"
		~ "{\"type\":\"input_text\",\"text\":\"<environment_context>environment</environment_context>\"}]";
	string[] kinds = ["plugins.recommendations", "agents_md.instructions",
		"environments.environment_context"];
	auto base = decodeLegacy(legacyRollout);
	auto events = decodeLegacy(taggedLegacyUser(content, toJson(kinds)));
	assert(events.length == base.length + 1);
	auto appended = jsonParse!ItemStartedEvent(events[$ - 1].translated);
	assert(appended.type == "item/started" && appended.item_type == "user_message");
	assert(appended.is_meta && appended.meta_kinds == kinds);
	assert(boundariesOf(events) == boundariesOf(base));
}

// Kinds that contradict the content reject the history read even after valid turns were decoded.
unittest
{
	import std.algorithm : canFind;

	enum first = `{"type":"input_text","text":"first"}`;
	enum last = `{"type":"input_text","text":"last"}`;
	enum oneItem = "[" ~ first ~ "]";
	enum twoItems = "[" ~ first ~ "," ~ last ~ "]";
	auto legacy = ThreadMetadata("01a1feae-9e4c-7d83-a43c-dbd595e0221d", "legacy",
		"/profile/sessions/rollout.jsonl", "/workspace", "0.144.1", "model", "openai",
		"reply");

	void assertReadFailure(string content, string kinds, string expected)
	{
		auto server = new FakeAppServer;
		server.results = [toJson(ThreadMetadataResult(legacy))];
		string path;
		auto read = readWith(server, null, taggedLegacyUser(content, kinds), &path);
		assert(path == legacy.path && server.calls.length == 1);
		assert(read.failure !is null && read.failure.canFind(expected), read.failure);
	}

	assertReadFailure(twoItems, `["user.text","environments.environment_context"]`,
		"mixes user.text with other content kinds");
	assertReadFailure(twoItems, `["user.text"]`, "1 content kinds for 2 content items");
}

// A replayed mode-switch prompt still gets CyDo's own display metadata.
unittest
{
	import cydo.workflow.system_message_normalizer : SystemMessageNormalizer,
		SystemMessageNormalizerHost;

	@JSONPartial static struct Normalized
	{
		static struct Meta { string label; }
		Meta meta;
		@JSONOptional string[] meta_kinds;
	}

	enum prompt = "[SYSTEM: Mode switch: plan_mode -> execute]\n\nContinue the task.\n\n[/SYSTEM]";
	auto content = "[{\"type\":\"input_text\",\"text\":" ~ toJson(prompt) ~ "}]";
	auto normalizer = new SystemMessageNormalizer(SystemMessageNormalizerHost(
		systemKeyword: () => "SYSTEM"));
	foreach (kinds, expected; [
		"[\"user.text\"]": cast(string[]) null,
		"[\"agents_md.instructions\"]": ["agents_md.instructions"],
	])
	{
		auto events = decodeLegacy(taggedLegacyUser(content, kinds));
		auto translated = events[$ - 1].translated;
		auto user = jsonParse!ItemStartedEvent(translated);
		assert(user.is_meta == (expected.length > 0) && user.meta_kinds == expected);
		assert(user.content.length == 1 && user.content[0].text == prompt);

		auto normalized = jsonParse!Normalized(normalizer.normalizeKnownSystemMessageMeta(translated));
		assert(normalized.meta.label == "Mode switch: execute");
		assert(normalized.meta_kinds == expected);
	}
}
