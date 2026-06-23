module cydo.history.pipeline;

import std.algorithm : canFind, startsWith;
import std.file : append, exists, mkdirRecurse, read;
import std.format : format;
import std.logger : infof, tracef;
import std.path : dirName;
import std.string : representation;
import std.uuid : randomUUID;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.array : as;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent;
import cydo.agent.protocol : ContentBlock, ItemStartedEvent, TaskEventEnvelope,
	TaskEventSeqEnvelope, TranslatedEvent, UnconfirmedUserEventEnvelope,
	extractContentText;
import cydo.runtime.config : AgentDriver;
import cydo.domain.storage.persistence : LoadedHistory, loadTaskHistory;
import cydo.domain.tasks.model : QueueOperationProbe, TaskData, TaskHistoryEndMessage,
	TaskHistoryStartMessage, buildSyntheticUserEvent, extractEventFromEnvelope,
	extractTsFromEnvelope;

package(cydo):

struct HistoryBroadcastPlan
{
	TranslatedEvent[] prependedEvents;
	TranslatedEvent currentEvent;
	bool consumeCurrent;
}

struct HistoryEventPipelineHost
{
	TaskData* delegate(int tid) getTask;
	Agent delegate(int tid) tryAgentForTask;
	string delegate(int tid) effectiveCwd;
	string delegate(string translated, string agentName) injectAgentNameIntoSessionInit;
	string delegate(string translated, int tid) normalizeKnownSystemMessageMeta;
	string delegate(string subject, string body) synthesizeHistoryErrorEventJson;
	void delegate(int tid, Data data) sendToSubscribed;
	void delegate(WebSocketAdapter ws, int tid) subscribe;
	void delegate(WebSocketAdapter ws, int tid) sendForkableUuids;
	void delegate(int tid) broadcastForkableUuids;
	void delegate(WebSocketAdapter ws, int tid) sendReplaySupplementalState;
	void delegate(int tid) onHistorySubscribed;
	void delegate(int tid, string line) ensureAgentSessionIdFromEvent;
	bool delegate(int tid, string translated) updateClaudeUsageFromEvent;
	HistoryBroadcastPlan delegate(int tid, TranslatedEvent ev) planBroadcast;
}

class HistoryEventPipeline
{
	private HistoryEventPipelineHost host_;

	this(HistoryEventPipelineHost host)
	{
		host_ = host;
	}

	void ensureHistoryLoaded(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null || td.history.isLoaded)
			return;

		bool orphan = false;
		string jsonlPath;
		Agent ta;

		if (td.agentSessionId.length > 0)
		{
			ta = host_.tryAgentForTask(tid);
			if (!ta)
				orphan = true;
			else
				jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(tid));
		}

		bool hasQueueOps = false;
		int userMsgFromJsonl = 0;
		string[] steeringStash;
		int[] steeringEnqueueLineNums;
		string[] steeringEnqueueRawLines;
		string lastDequeuedText;
		int lastDequeuedEnqueueLineNum;
		string lastDequeuedRawLine;
		auto stripTransientStatus = (TranslatedEvent[] events) {
			foreach (ref e; events)
				e.translated = host_.injectAgentNameIntoSessionInit(e.translated, td.agentType);
			return filterTransientSessionStatusEvents(events);
		};

		import std.datetime.stopwatch : StopWatch;
		StopWatch sw;
		sw.start();
		td.history.load((ulong maxBytes) {
			if (orphan || ta is null)
				return LoadedHistory.init;

			bool[int] rollbackSkipLines;
			if (ta.driver == AgentDriver.codex && jsonlPath.length > 0 && maxBytes > 0)
			{
				if (exists(jsonlPath))
				{
					import cydo.agent.drivers.codex : computeRollbackSkipLines;
					rollbackSkipLines = computeRollbackSkipLines(
						cast(string) read(jsonlPath, cast(size_t) maxBytes));
				}
			}

			ta.resetHistoryReplay();
			return loadTaskHistory(tid, jsonlPath, delegate TranslatedEvent[](string line, int lineNum) {
				if (lineNum in rollbackSkipLines)
					return [];
				if (isQueueOperation(line))
				{
					auto op = jsonParse!QueueOperationProbe(line);
					if (op.operation == "enqueue")
					{
						hasQueueOps = true;
						steeringStash ~= op.content;
						steeringEnqueueLineNums ~= lineNum;
						steeringEnqueueRawLines ~= line;
						return [];
					}
					else if (op.operation == "dequeue" || op.operation == "remove")
					{
						TranslatedEvent[] result;
						if (lastDequeuedText.length > 0)
						{
							auto synEv = buildSyntheticUserEvent(lastDequeuedText);
							result ~= TranslatedEvent(toJsonWithSyntheticUserMeta(lastDequeuedText, synEv, tid),
								lastDequeuedRawLine.length > 0 ? lastDequeuedRawLine : null);
							lastDequeuedText = null;
							lastDequeuedRawLine = null;
						}
						if (steeringStash.length > 0)
						{
							auto text = steeringStash[0];
							auto enqLineNum = steeringEnqueueLineNums[0];
							auto enqRaw = steeringEnqueueRawLines[0];
							steeringStash = steeringStash[1 .. $];
							steeringEnqueueLineNums = steeringEnqueueLineNums[1 .. $];
							steeringEnqueueRawLines = steeringEnqueueRawLines[1 .. $];
							if (op.operation == "remove")
							{
								auto enqueueUuid = format!"enqueue-%d"(enqLineNum);
								auto synEv = buildSyntheticUserEvent(text, true);
								synEv.uuid = enqueueUuid;
								result ~= TranslatedEvent(toJsonWithSyntheticUserMeta(text, synEv, tid),
									enqRaw.length > 0 ? enqRaw : null);
							}
							else
							{
								lastDequeuedText = text;
								lastDequeuedEnqueueLineNum = enqLineNum;
								lastDequeuedRawLine = enqRaw;
							}
						}
						return stripTransientStatus(result);
					}
					return [];
				}
				if (lastDequeuedText.length > 0)
				{
					if (ta.isUserMessageLine(line))
					{
						auto ts = ta.translateHistoryLine(line, lineNum);
						// a type:"user" JSONL line translates to either an
						// item/started user_message (the steering echo we're waiting
						// for) or an item/result (a tool_result that landed while the
						// turn was mid-tool-use). only the former is the dequeued echo;
						// parsing an item/result as ItemStartedEvent throws on its
						// tool_result field, so peek at the type first
						bool firstIsItemStarted = false;
						if (ts.length > 0)
						{
							@JSONPartial static struct TypeProbe { string type; }
							firstIsItemStarted =
								jsonParse!TypeProbe(ts[0].translated).type == "item/started";
						}
						if (firstIsItemStarted)
						{
							auto savedEnqueueLineNum = lastDequeuedEnqueueLineNum;
							lastDequeuedText = null;
							lastDequeuedEnqueueLineNum = 0;
							auto enqueueUuid = format!"enqueue-%d"(savedEnqueueLineNum);
							auto ev = jsonParse!ItemStartedEvent(ts[0].translated);
							if (ev.is_steering)
								ev.uuid = enqueueUuid;
							return stripTransientStatus([TranslatedEvent(toJson(ev), ts[0].raw)] ~ ts[1 .. $]);
						}
						// not the echo (tool_result, or empty translation): pass
						// through unchanged and stay deferred for the real echo
						return stripTransientStatus(ts);
					}
					if (ta.isAssistantMessageLine(line))
					{
						auto enqueueUuid = format!"enqueue-%d"(lastDequeuedEnqueueLineNum);
						auto synEv = buildSyntheticUserEvent(lastDequeuedText, true);
						synEv.uuid = enqueueUuid;
						auto synthetic = toJsonWithSyntheticUserMeta(lastDequeuedText, synEv, tid);
						auto syntheticRaw = lastDequeuedRawLine.length > 0 ? lastDequeuedRawLine : null;
						lastDequeuedText = null;
						lastDequeuedEnqueueLineNum = 0;
						lastDequeuedRawLine = null;
						auto ts = ta.translateHistoryLine(line, lineNum);
						return stripTransientStatus([TranslatedEvent(synthetic, syntheticRaw)] ~ ts);
					}
					return stripTransientStatus(ta.translateHistoryLine(line, lineNum));
				}
				if (ta.isUserMessageLine(line))
					userMsgFromJsonl++;
				return stripTransientStatus(ta.translateHistoryLine(line, lineNum));
			}, maxBytes);
		});
		sw.stop();
		if (td.history.isLoaded)
			infof("Loaded history for task %d (%d events, %d ms)",
				tid, td.history.length, sw.peek.total!"msecs");

		if (orphan)
			appendSynthesizedHistoryError(tid, "Failed to load session history",
				buildOrphanAgentBody(td.agentType));

		td.clearPendingDequeuedSteering();
		if (!hasQueueOps && td.pendingSteeringTexts.length > userMsgFromJsonl)
		{
			import std.datetime : Clock;
			foreach (text; td.pendingSteeringTexts[cast(size_t) userMsgFromJsonl .. $])
			{
				auto uuid = randomUUID().toString();
				if (jsonlPath.length > 0)
				{
					mkdirRecurse(dirName(jsonlPath));
					append(jsonlPath,
						`{"type":"user.message","id":"` ~ uuid
						~ `","data":{"content":` ~ toJson(text) ~ `}}` ~ "\n");
				}
				auto synEv = buildSyntheticUserEvent(text);
				synEv.uuid = uuid;
				td.history.appendLive(Data(
					toJson(TaskEventEnvelope(tid, Clock.currStdTime,
						JSONFragment(toJsonWithSyntheticUserMeta(text, synEv, tid)))).representation), null);
			}
			host_.broadcastForkableUuids(tid);
		}
		rebuildVisibleTurnAnchors(tid);
	}

	void handleRequestHistory(WebSocketAdapter ws, int tid)
	{
		if (tid < 0)
			return;
		ensureHistoryLoaded(tid);
		auto td = host_.getTask(tid);
		if (td is null)
			return;

		ws.send(Data(toJson(TaskHistoryStartMessage("task_history_start", tid,
			cast(int) td.history.length)).representation));

		foreach (i, ref msg; td.history)
		{
			Data outgoing;
			msg.enter((scope ubyte[] bytes) {
				auto envelope = bytes.as!(char[]);
				auto event = extractEventFromEnvelope(envelope);
				if (event.length == 0)
					return;
				auto normalized = host_.normalizeKnownSystemMessageMeta(event.idup, tid);
				auto clientEnvelope = toJson(TaskEventSeqEnvelope(
					tid,
					cast(int) i,
					extractTsFromEnvelope(envelope),
					JSONFragment(normalized)));
				outgoing = Data(clientEnvelope.representation);
			});
			if (outgoing.length > 0)
				ws.send(outgoing);
			else
				ws.send(msg);
		}

		if (td.agentSessionId.length > 0 && host_.tryAgentForTask(tid))
			host_.sendForkableUuids(ws, tid);

		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));
		host_.sendReplaySupplementalState(ws, tid);
		host_.subscribe(ws, tid);
		host_.onHistorySubscribed(tid);
	}

	void appendUnconfirmedUserMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		string nonce = null)
	{
		import cydo.agent.protocol : ItemStartedEvent;

		auto td = host_.getTask(tid);
		if (td is null)
			return;

		auto uiContent = broadcastContent !is null ? broadcastContent : content;
		ItemStartedEvent ev;
		ev.item_id = "cc-user-msg";
		ev.item_type = "user_message";
		ev.text = extractContentText(uiContent);
		ev.content = uiContent.dup;
		ev.pending = true;
		auto userEvent = toJson(ev);
		if (cydoMeta.length > 0)
			userEvent = userEvent[0 .. $ - 1] ~ `,"meta":` ~ cydoMeta ~ `}`;
		auto envelope = UnconfirmedUserEventEnvelope(tid, JSONFragment(userEvent), nonce);
		auto data = Data(toJson(envelope).representation);
		ensureHistoryLoaded(tid);
		td = host_.getTask(tid);
		if (td is null)
			return;
		td.history.appendLive(data, null);
		host_.sendToSubscribed(tid, data);
		if (nonce.length > 0)
			td.pendingUserNonce = nonce;
		td.pendingSteeringTexts ~= extractContentText(uiContent);
	}

	string appendSynthesizedHistoryError(int tid, string subject, string body)
	{
		import std.datetime : Clock;

		auto td = host_.getTask(tid);
		if (td is null)
			return null;

		auto translated = host_.synthesizeHistoryErrorEventJson(subject, body);
		auto envelope = toJson(TaskEventEnvelope(tid, Clock.currStdTime,
			JSONFragment(translated)));
		td.history.appendLive(Data(envelope.representation), null);
		return translated;
	}

	size_t appendAndBroadcastTaskEvent(int tid, TranslatedEvent ev)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return 0;

		if (isTurnResultEvent(ev.translated) || isProcessExitEvent(ev.translated))
			td.clearLastSessionStatus();

		if (isSessionStatusEvent(ev.translated))
		{
			cacheSessionStatusEvent(tid, ev.translated, ev.ts.stdTime);
			host_.sendToSubscribed(tid, Data(
				toJson(TaskEventEnvelope(tid, ev.ts.stdTime,
					JSONFragment(ev.translated))).representation));
			return cast(size_t) -1;
		}

		auto historyData = Data(toJson(TaskEventEnvelope(tid, ev.ts.stdTime,
			JSONFragment(ev.translated))).representation);
		auto merged = mergeStreamingDelta(tid, ev.translated);
		size_t seq;
		td = host_.getTask(tid);
		if (td is null)
			return 0;
		if (merged)
			seq = td.history.isLoaded ? td.history.length - 1 : cast(size_t) -1;
		else
			seq = td.history.appendLive(historyData, ev.raw);

		if (seq == cast(size_t) -1)
			return seq;

		if (!merged)
			registerVisibleTurnAnchorFromEvent(tid, seq, ev.translated, ev.raw);
		host_.sendToSubscribed(tid, Data(
			toJson(TaskEventSeqEnvelope(tid, cast(int) seq, ev.ts.stdTime,
				JSONFragment(ev.translated))).representation));
		return seq;
	}

	void broadcastTask(int tid, TranslatedEvent ev)
	{
		import std.datetime : Clock;

		if (ev.ts == AbsTime.init)
			ev.ts = AbsTime(Clock.currStdTime);

		host_.ensureAgentSessionIdFromEvent(tid, ev.translated);
		ev.translated = host_.normalizeKnownSystemMessageMeta(ev.translated, tid);
		host_.updateClaudeUsageFromEvent(tid, ev.translated);

		auto plan = host_.planBroadcast(tid, ev);
		foreach (synthetic; plan.prependedEvents)
			appendAndBroadcastTaskEvent(tid, synthetic);
		if (plan.consumeCurrent)
			return;

		appendAndBroadcastTaskEvent(tid, plan.currentEvent);
	}

	void backfillHistoryAnchor(int tid, size_t seq, string anchor)
	{
		import cydo.agent.protocol : ItemStartedEvent;

		auto td = host_.getTask(tid);
		if (td is null || anchor.length == 0 || seq >= td.history.length)
			return;

		Data replacement;
		td.history[seq].enter((scope const(ubyte)[] bytes) {
			auto envelope = bytes.as!(char[]);
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0
				|| !event.canFind(`"type":"item/started"`)
				|| !event.canFind(`"item_type":"user_message"`))
				return;

			ItemStartedEvent userEv;
			try
				userEv = jsonParse!ItemStartedEvent(event);
			catch (Exception)
				return;
			if (userEv.uuid == anchor)
				return;
			userEv.uuid = anchor;
			replacement = Data(toJson(TaskEventEnvelope(tid,
				extractTsFromEnvelope(envelope),
				JSONFragment(toJson(userEv)))).representation);
		});
		if (replacement.length > 0)
			td.history.replaceAt(seq, replacement);
	}

private:
	static string buildOrphanAgentBody(string agentType)
	{
		import std.algorithm : map;
		import std.array : join;
		import cydo.agent.drivers.registry : agentRegistry;
		auto knownNames = agentRegistry[].map!(r => "`" ~ r.name ~ "`").join(", ");
		return "This task uses agent `" ~ agentType ~ "`, which is not configured.\n\n"
			~ "The currently available agents are: " ~ knownNames ~ ".";
	}

	void registerVisibleTurnAnchorFromEvent(int tid, size_t seq,
		const(char)[] translated, const(char)[] rawLine = null)
	{
		auto td = host_.getTask(tid);
		if (td is null || translated.length == 0)
			return;

		if (translated.canFind(`"type":"item/started"`) && translated.canFind(`"item_type":"user_message"`))
		{
			@JSONPartial
			static struct UserAnchorProbe
			{
				string type;
				string item_type;
				@JSONOptional bool is_meta;
				@JSONOptional bool is_steering;
				@JSONOptional bool pending;
				@JSONOptional string uuid;
			}

			UserAnchorProbe probe;
			try
				probe = jsonParse!UserAnchorProbe(translated);
			catch (Exception)
				return;

			if (probe.type != "item/started" || probe.item_type != "user_message")
				return;
			if (probe.is_meta || probe.pending)
				return;

			auto uuid = probe.uuid;
			auto isEnqueue = uuid.length > "enqueue-".length && uuid.startsWith("enqueue-");
			string checkpointUuid;
			if (!isEnqueue && uuid.length > 0)
				checkpointUuid = uuid;
			else if (rawLine.length > 0)
			{
				@JSONPartial static struct RawUserUuidProbe
				{
					string type;
					@JSONOptional string uuid;
				}
				try
				{
					auto rawProbe = jsonParse!RawUserUuidProbe(rawLine);
					if (rawProbe.type == "user" && rawProbe.uuid.length > 0)
						checkpointUuid = rawProbe.uuid;
				}
				catch (Exception)
				{
				}
			}
			auto shouldPend = probe.is_steering && uuid.length == 0;
			auto anchor = shouldPend ? null : uuid;
			if (!shouldPend && anchor.length == 0)
				return;

			td.registerVisibleTurnAnchor(seq, true, probe.is_steering,
				anchor.idup, checkpointUuid.idup, shouldPend);
			return;
		}

		if (translated.canFind(`"type":"turn/stop"`))
		{
			@JSONPartial static struct TurnStopAnchorProbe
			{
				string type;
				@JSONOptional string uuid;
			}
			try
			{
				auto probe = jsonParse!TurnStopAnchorProbe(translated);
				if (probe.type == "turn/stop" && probe.uuid.length > 0)
				{
					auto uuid = probe.uuid.idup;
					td.registerVisibleTurnAnchor(seq, false, false, uuid, uuid, false);
				}
			}
			catch (Exception)
			{
			}
			return;
		}

		if (translated.canFind(`"type":"turn/delta"`))
		{
			@JSONPartial static struct TurnDeltaAnchorProbe
			{
				string type;
				@JSONOptional string uuid;
			}
			try
			{
				auto probe = jsonParse!TurnDeltaAnchorProbe(translated);
				if (probe.type == "turn/delta" && probe.uuid.length > 0)
				{
					auto uuid = probe.uuid.idup;
					td.registerVisibleTurnAnchor(seq, false, false, uuid, uuid, false);
				}
			}
			catch (Exception)
			{
			}
		}
	}

	void rebuildVisibleTurnAnchors(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		td.visibleTurnAnchors = null;
		foreach (i, ref entry; td.history)
		{
			entry.enter((scope ubyte[] bytes) {
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				if (event.length == 0)
					return;
				registerVisibleTurnAnchorFromEvent(tid, i, event, td.history.rawAt(i));
			});
		}
	}

	static bool isSessionStatusEvent(string translated)
	{
		return translated.canFind(`"type":"session/status"`)
			|| translated.canFind(`"type":"session\/status"`);
	}

	static bool isTurnResultEvent(string translated)
	{
		return translated.canFind(`"type":"turn/result"`)
			|| translated.canFind(`"type":"turn\/result"`);
	}

	static bool isProcessExitEvent(string translated)
	{
		return translated.canFind(`"type":"process/exit"`)
			|| translated.canFind(`"type":"process\/exit"`);
	}

	void cacheSessionStatusEvent(int tid, string translated, long ts)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;

		@JSONPartial static struct StatusProbe
		{
			string type;
			@JSONOptional string status;
		}

		try
		{
			auto probe = jsonParse!StatusProbe(translated);
			if (probe.type != "session/status")
				return;
			import std.string : strip;
			if (probe.status.strip.length == 0)
			{
				td.clearLastSessionStatus();
				return;
			}
			td.setLastSessionStatus(translated, ts);
		}
		catch (Exception)
		{
			td.clearLastSessionStatus();
		}
	}

	static TranslatedEvent[] filterTransientSessionStatusEvents(TranslatedEvent[] events)
	{
		if (events.length == 0)
			return events;

		TranslatedEvent[] filtered;
		foreach (ev; events)
			if (!isSessionStatusEvent(ev.translated))
				filtered ~= ev;
		return filtered;
	}

	bool mergeStreamingDelta(int tid, string translated)
	{
		if (!translated.canFind(`"type":"item/delta"`))
			return false;

		auto td = host_.getTask(tid);
		if (td is null || td.history.lastEventContents().length == 0)
			return false;

		auto lastEntry = td.history.lastEventContents();
		if (lastEntry.length > 64 * 1024)
			return false;
		if (!lastEntry.canFind(`"type":"item/delta"`)
			&& !lastEntry.canFind(`"type":"item\/delta"`))
			return false;

		auto lastId = extractItemId(lastEntry);
		auto newId = extractItemId(translated);
		if (lastId is null || newId is null || lastId != newId)
			return false;

		auto merged = mergeItemDeltas(lastEntry, translated);
		if (merged is null)
			return false;

		import std.json : parseJSON;
		auto prevTs = td.history.lastEventTs();
		auto mergedObj = parseJSON(merged);
		auto canonical = toJson(TaskEventEnvelope(tid, prevTs,
			JSONFragment(mergedObj["event"].toString())));
		td.history.replaceLastEvent(Data(canonical.representation));
		return true;
	}

	static string extractItemId(const(char)[] s)
	{
		import std.string : indexOf;
		enum key = `"item_id":"`;
		auto idx = s.indexOf(key);
		if (idx < 0)
			return null;
		auto start = idx + key.length;
		auto end = s.indexOf('"', start);
		if (end < 0 || end <= start)
			return null;
		return cast(string) s[start .. end];
	}

	string mergeItemDeltas(const(char)[] lastEnvelope, string newTranslated)
	{
		import std.json : JSONValue, parseJSON;

		JSONValue lastJson, newEventJson;
		try
		{
			lastJson = parseJSON(lastEnvelope);
			newEventJson = parseJSON(newTranslated);
		}
		catch (Exception e)
		{
			tracef("mergeItemDeltas: JSON parse error: %s", e.msg);
			return null;
		}

		auto lastEvent = lastJson["event"];
		if (auto lastContent = "content" in lastEvent.objectNoRef)
		{
			if (auto newContent = "content" in newEventJson.objectNoRef)
			{
				(*lastContent).str = (*lastContent).str ~ (*newContent).str;
				return lastJson.toString();
			}
		}

		return null;
	}

	string toJsonWithSyntheticUserMeta(string text, ItemStartedEvent ev, int tid = -1)
	{
		auto translated = toJson(ev);
		return host_.normalizeKnownSystemMessageMeta(translated, tid);
	}

	static bool isQueueOperation(string translated)
	{
		return translated.canFind(`"type":"queue-operation"`)
			|| translated.canFind(`"type":"queue\/operation"`);
	}
}

// Regression test: a task history where a queue dequeue is immediately followed
// by a tool_result line (the turn was interrupted mid-tool-use, so the next
// type:"user" line is NOT the steering echo) must not crash history loading.
// The deferred-dequeue branch used to parse that line strictly as an
// ItemStartedEvent; the translated item/result carries a tool_result field that
// ItemStartedEvent doesn't declare, so the strict parse threw an uncaught
// "Unknown field tool_result" and the task could never open.
unittest
{
	import std.algorithm : canFind;
	import std.array : join;
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath, dirName;
	import std.process : environment;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.domain.tasks.model : Watermark;

	auto dir = buildPath("/tmp", "cydo-history-tool-result-after-dequeue");
	if (exists(dir))
		rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto projectPath = buildPath(dir, "project");
	mkdirRecurse(projectPath);

	// Point ClaudeCodeAgent.historyPath at a writable temp location.
	auto oldConfigDir = environment.get("CLAUDE_CONFIG_DIR");
	environment["CLAUDE_CONFIG_DIR"] = buildPath(dir, "claude");
	scope(exit)
	{
		if (oldConfigDir is null)
			environment.remove("CLAUDE_CONFIG_DIR");
		else
			environment["CLAUDE_CONFIG_DIR"] = oldConfigDir;
	}

	enum tid = 1;
	auto td = TaskData(tid, "local", projectPath);
	td.agentType = "claude";
	td.agentSessionId = "S";
	td.worktreeTid = 0;

	Agent agent = new ClaudeCodeAgent();

	// enqueue, dequeue, then a type:"user" line carrying a tool_result. The
	// toolUseResult sidecar makes the translated item/result include a
	// tool_result field — exactly the field the old strict parse choked on.
	auto jsonlPath = agent.historyPath(td.agentSessionId, projectPath);
	mkdirRecurse(dirName(jsonlPath));
	auto jsonl = [
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-11T06:00:00Z","sessionId":"S","content":"are you under control?"}`,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-06-11T06:00:01Z","sessionId":"S"}`,
		`{"parentUuid":"p","isSidechain":false,"type":"user","toolUseResult":{"stdout":"ok"},"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}`,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl);

	td.history.reset(Watermark.atBytes(getSize(jsonlPath)));

	// Minimal host: ensureHistoryLoaded on a queue-op history only touches
	// getTask/tryAgentForTask/effectiveCwd/injectAgentNameIntoSessionInit. The
	// remaining delegates are stubbed no-ops so a stray call can't null-deref.
	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.tryAgentForTask = (int t) => agent;
	host.effectiveCwd = (int t) => projectPath;
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.synthesizeHistoryErrorEventJson = (string subject, string body) => "";
	host.sendToSubscribed = (int t, Data d) {};
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendForkableUuids = (WebSocketAdapter ws, int t) {};
	host.broadcastForkableUuids = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.ensureAgentSessionIdFromEvent = (int t, string line) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);

	// Before the fix this throws object.Exception "Unknown field tool_result".
	pipeline.ensureHistoryLoaded(tid);

	assert(td.history.isLoaded, "history must load without throwing");

	// The tool_result must survive translation as an item/result event rather
	// than being dropped by the (mis)parse as a steering echo.
	bool sawToolResult = false;
	foreach (ref ev; td.history)
	{
		auto s = cast(string) ev.toGC();
		if (s.canFind(`"item/result"`) && s.canFind("tool_result"))
			sawToolResult = true;
	}
	assert(sawToolResult, "tool_result event missing from loaded history");
}
