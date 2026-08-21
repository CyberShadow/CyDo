module cydo.workflow.history.pipeline;

import std.algorithm : canFind, startsWith;
import std.file : append, exists, mkdirRecurse, read;
import std.format : format;
import std.logger : infof, tracef;
import std.path : dirName;
import std.string : representation;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.array : as;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent, PersistedHistoryBoundaryKind;
import cydo.protocol : ContentBlock, ItemStartedEvent, TaskEventEnvelope,
	TaskHistoryBoundaryReplacedEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, UserMessageConsumedEvent, HistoryBoundary,
	HistoryBoundaryKind, extractContentText;
import cydo.runtime.config : AgentDriver;
import cydo.domain.storage.persistence : LoadedHistory;
import cydo.domain.tasks.model : QueueOperationProbe, TaskData, TaskHistoryEndMessage,
	TaskHistoryPrependEndMessage, TaskHistoryPrependStartMessage,
	TaskHistoryStartMessage, Watermark, buildSyntheticUserEvent, extractEventFromEnvelope,
	extractTsFromEnvelope, watermarkFromPath;
import cydo.workflow.history.native_history : HistoryAccess,
	TaskHistoryResolution, TaskHistoryResolutionKind;
import cydo.workflow.history.jsonl_store : loadTaskHistory;

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
	TaskHistoryResolution delegate(int tid) resolveTaskHistory;
	void delegate(int tid, const ref TaskHistoryResolution resolution)
		reportUnavailableHistory;
	string delegate(string translated, string agentName) injectAgentNameIntoSessionInit;
	string delegate(string translated, int tid) normalizeKnownSystemMessageMeta;
	string[] delegate() configuredAgentNames;
	string delegate(string subject, string body) makeTaskDiagnosticEventJson;
	void delegate(int tid, Data data) sendToSubscribed;
	void delegate(WebSocketAdapter ws, int tid) subscribe;
	void delegate(WebSocketAdapter ws, int tid) sendHistoryOperations;
	void delegate(int tid) broadcastHistoryOperations;
	void delegate(int tid, size_t seq, string event, string raw, int sourceLine,
		bool isContextBootstrap) noteLiveBoundaryCandidate;
	void delegate(WebSocketAdapter ws, int tid) sendReplaySupplementalState;
	void delegate(int tid) onHistorySubscribed;
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

	/// Returns the resolution used to load history, or null when history was
	/// already loaded and no resolution was performed.
	Nullable!TaskHistoryResolution ensureHistoryLoaded(int tid)
	{
		return ensureHistoryLoadedImpl(tid, true);
	}

	/// Exit-path variant of `ensureHistoryLoaded`. On exit, the live binding
	/// is about to be torn down and re-resolved against config alone by the
	/// post-exit reset (App.resetHistoryWatermark); that later resolution is
	/// the sole owner of the unavailable-history diagnostic for the exit
	/// sequence, so this variant loads history the same way but never reports.
	Nullable!TaskHistoryResolution ensureHistoryLoadedForExit(int tid)
	{
		return ensureHistoryLoadedImpl(tid, false);
	}

	private Nullable!TaskHistoryResolution ensureHistoryLoadedImpl(int tid,
		bool reportUnavailable)
	{
		auto td = host_.getTask(tid);
		if (td is null || td.history.isLoaded)
			return Nullable!TaskHistoryResolution.init;

		auto resolution = host_.resolveTaskHistory(tid);
		bool orphan = resolution.kind == TaskHistoryResolutionKind.orphanAgent;
		string jsonlPath;
		Agent ta;
		if (resolution.kind == TaskHistoryResolutionKind.access)
		{
			auto access = resolution.requireAccess();
			ta = access.agent;
			jsonlPath = access.path;
		}
		else if (resolution.kind == TaskHistoryResolutionKind.unavailable)
		{
			// Loading is a pipeline-owned invariant that must hold regardless
			// of who reports: callers such as finalReconcileJsonlIfPresent
			// require td.history.isLoaded once this returns. Reporting (the
			// diagnostic append + reload broadcast) is a separate, optional
			// concern gated by reportUnavailable. On the reporting path
			// reportUnavailableHistory resets and loads again; the repeat is
			// idempotent (empty store both times) and the extra generation
			// bump is inert, so it is left unconditional rather than
			// coupling this branch to the reporter's internals.
			td.history.reset(Watermark.unreadable());
			td.history.load((ulong) => LoadedHistory.init);
			if (reportUnavailable)
				host_.reportUnavailableHistory(tid, resolution);
			return Nullable!TaskHistoryResolution(resolution);
		}

		bool hasQueueOps = false;
		int userMsgFromJsonl = 0;
		// Queue reconstruction: the enqueue record is the authoritative "user
		// sent this" fact and emits the message immediately (pending
		// presentation, identity enqueue-N). Dequeue moves the front entry to
		// the awaiting-echo stage; the following echo user line is swallowed
		// and replaced by a user_message/consumed confirmation carrying the
		// CLI's own steering classification. Entries still queued at EOF stay
		// pending — a killed session's unconsumed steer remains visible.
		string[] queuedUuids;
		string[] awaitingEchoUuids;
		auto stripTransientStatus = (TranslatedEvent[] events) {
			foreach (ref e; events)
				e.translated = host_.injectAgentNameIntoSessionInit(e.translated, td.agentName);
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
						auto enqueueUuid = format!"enqueue-%d"(lineNum);
						queuedUuids ~= enqueueUuid;
						auto synEv = buildSyntheticUserEvent(op.content, false, true);
						synEv.uuid = enqueueUuid;
						return stripTransientStatus([TranslatedEvent(
							toJsonWithSyntheticUserMeta(op.content, synEv, tid),
							line, AbsTime.init, lineNum)]);
					}
					else if (op.operation == "dequeue")
					{
						if (queuedUuids.length > 0)
						{
							awaitingEchoUuids ~= queuedUuids[0];
							queuedUuids = queuedUuids[1 .. $];
						}
						return [];
					}
					else if (op.operation == "remove")
					{
						TranslatedEvent[] result;
						if (queuedUuids.length > 0)
						{
							result ~= TranslatedEvent(toJson(UserMessageConsumedEvent(
								uuid: queuedUuids[0], consumed_as: "removed")),
								null, AbsTime.init, lineNum);
							queuedUuids = queuedUuids[1 .. $];
						}
						return stripTransientStatus(result);
					}
					return [];
				}
				if (awaitingEchoUuids.length > 0)
				{
					if (ta.isUserMessageLine(line))
					{
						auto ts = ta.translateHistoryLine(line, lineNum);
						// a type:"user" JSONL line translates to either an
						// item/started user_message (the consumption echo we're
						// waiting for) or an item/result (a tool_result that landed
						// while the turn was mid-tool-use). only the former is the
						// echo; parsing an item/result as ItemStartedEvent throws on
						// its tool_result field, so peek at the type first
						bool firstIsItemStarted = false;
						if (ts.length > 0)
						{
							@JSONPartial static struct TypeProbe { string type; }
							firstIsItemStarted =
								jsonParse!TypeProbe(ts[0].translated).type == "item/started";
						}
						if (firstIsItemStarted)
						{
							// The consumption echo is the canonical message record:
							// emit it exactly as the pre-queue-primary pipeline did
							// (anchors, checkpoints and truncation semantics attach
							// to it), preceded by the confirmation that tells the
							// UI to drop the provisional enqueue-emitted bubble.
							auto enqueueUuid = awaitingEchoUuids[0];
							awaitingEchoUuids = awaitingEchoUuids[1 .. $];
							auto ev = jsonParse!ItemStartedEvent(ts[0].translated);
							// Persisted echo lines carry no steering flag (it is a
							// live-stdout-only field); mid-turn consumption is
							// classified via the assistant-fallback branch below.
							auto consumed = UserMessageConsumedEvent(
								uuid: enqueueUuid,
								consumed_as: "turn_start",
								native_uuid: ev.uuid.length > 0 ? ev.uuid : enqueueUuid);
							return stripTransientStatus([
								TranslatedEvent(toJson(consumed), null, AbsTime.init, lineNum),
								TranslatedEvent(toJson(ev), ts[0].raw)] ~ ts[1 .. $]);
						}
						// not the echo (tool_result, or empty translation): pass
						// through unchanged and stay awaiting the real echo
						return stripTransientStatus(ts);
					}
					if (ta.isAssistantMessageLine(line))
					{
						// No echo before assistant output. The output proves the
						// dequeued message was consumed; turn openers always echo
						// before assistant output, so classify as steering.
						auto consumed = UserMessageConsumedEvent(
							uuid: awaitingEchoUuids[0], consumed_as: "steering");
						awaitingEchoUuids = awaitingEchoUuids[1 .. $];
						auto ts = ta.translateHistoryLine(line, lineNum);
						return stripTransientStatus([TranslatedEvent(toJson(consumed),
							null, AbsTime.init, lineNum)] ~ ts);
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
			appendTaskDiagnostic(tid, "Failed to load session history",
				buildOrphanAgentBody(td.agentName,
					host_.configuredAgentNames is null ? null : host_.configuredAgentNames()));

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
		}
		rebuildVisibleTurnAnchors(tid);
		foreach (i, ref entry; td.history)
		{
			import ae.utils.array : as;
			import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
			auto raw = td.history.rawAt(i);
			auto line = td.history.sourceLineAt(i);
			if (raw.length == 0 || line == 0)
				continue;
			auto boundaries = ta.extractPersistedHistoryBoundaries(raw, line - 1);
			if (boundaries.length != 1)
				continue;
			@JSONPartial static struct Probe {
				string type; @JSONOptional string item_type; @JSONOptional string uuid;
				@JSONOptional string item_id; @JSONOptional bool is_meta;
				@JSONOptional bool is_synthetic; @JSONOptional bool pending;
				@JSONOptional bool is_sidechain; @JSONOptional string parent_tool_use_id;
			}
			Probe probe;
			entry.enter((scope const(ubyte)[] bytes) {
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				probe = jsonParse!Probe(event);
			});
			// pending user messages are queue-emitted records anchored at
			// their enqueue line — boundary-worthy so removed/unconsumed
			// messages stay undoable; consumed ones are dropped by the UI in
			// favor of the canonical echo (which anchors at the echo line).
			auto isUser = probe.type == "item/started" && probe.item_type == "user_message"
				&& !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0;
			auto isTurn = probe.type == "turn/stop" && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0;
			if ((boundaries[0].kind == PersistedHistoryBoundaryKind.user && !isUser)
				|| (boundaries[0].kind == PersistedHistoryBoundaryKind.agent_turn && !isTurn))
				continue;
			assertReplayNativeIdentity(ta.driver,
				probe.uuid.length > 0 ? probe.uuid : probe.item_id, boundaries[0].anchor);
			if (ta.driver == AgentDriver.claude
				&& boundaries[0].kind == PersistedHistoryBoundaryKind.user)
				boundaries[0].checkpointUuid = td.checkpointUuidForAnchor(boundaries[0].anchor);
			backfillHistoryBoundary(tid, i, HistoryBoundary(boundaries[0].anchor,
				boundaries[0].kind == PersistedHistoryBoundaryKind.user
					? HistoryBoundaryKind.user : HistoryBoundaryKind.agent_turn,
				boundaries[0].checkpointUuid), false);
		}
		if (ta !is null)
			host_.broadcastHistoryOperations(tid);
		return Nullable!TaskHistoryResolution(resolution);
	}

	bool resolveFreshPersistedBoundary(int tid, const ref HistoryAccess access,
		string requestedAnchor, out HistoryBoundary boundary)
	{
		if (requestedAnchor.length == 0)
			return false;
		auto source = host_.getTask(tid);
		if (source is null)
			return false;
		auto agent = access.agent;
		auto path = access.path;

		auto snapshot = TaskData(tid, source.workspace, source.projectPath);
		snapshot.agentSessionId = access.sessionId;
		snapshot.agentName = source.agentName;
		snapshot.worktreeTid = source.worktreeTid;
		snapshot.history.reset(watermarkFromPath(path));

		auto snapshotHost = host_;
		snapshotHost.getTask = (int candidateTid) => candidateTid == tid ? &snapshot : null;
		snapshotHost.sendToSubscribed = (int, Data) {};
		snapshotHost.broadcastHistoryOperations = (int) {};
		auto pipeline = new HistoryEventPipeline(snapshotHost);
		pipeline.ensureHistoryLoaded(tid);

		bool found;
		foreach (ref entry; snapshot.history)
		{
			HistoryBoundary candidate;
			entry.enter((scope const(ubyte)[] bytes) {
				@JSONPartial static struct Probe { @JSONOptional HistoryBoundary history_boundary; }
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				candidate = jsonParse!Probe(event).history_boundary;
			});
			if (candidate.anchor != requestedAnchor)
				continue;
			assert(!found, "persisted history boundary anchor must be unique");
			boundary = candidate;
			found = true;
		}
		return found;
	}

	private static void assertReplayNativeIdentity(AgentDriver driver, string identity,
		string anchor)
	{
		import std.algorithm : startsWith;
		if (identity.length == 0 || anchor.startsWith("line:") || anchor.startsWith("enqueue-"))
			return;
		if (driver == AgentDriver.claude || driver == AgentDriver.copilot)
			assert(identity == anchor,
				"replayed native history identity does not match its persisted boundary");
	}

	/// how many raw events a single requested message may drag along
	///
	/// page weight tracks events rather than bubbles: one turn can carry dozens
	/// of tool calls and their output, so a task with chatty tool use turns a
	/// 100-message window into thousands of events and a DOM to match. the
	/// budget scales with the request, so asking for more history still gets
	/// more of it
	enum eventsPerMessageBudget = 4;

	/// First seq of a replay window covering at least messageLimit rendered
	/// message bubbles (user messages and assistant text), snapped back to a
	/// genuine user-message boundary so the client's reducers never see a split
	/// turn. Whichever budget runs out first, messages or events, ends the
	/// window. Returns 0 when the history is smaller than the window.
	size_t historyWindowStart(TaskData* td, int messageLimit, size_t end = size_t.max)
	{
		assert(messageLimit > 0, "history window scan requires a positive limit");
		if (end > td.history.length)
			end = td.history.length;
		const size_t eventBudget = cast(size_t) messageLimit * eventsPerMessageBudget;
		size_t scanned = 0;
		@JSONPartial static struct WindowProbe
		{
			string type; @JSONOptional string item_type; @JSONOptional bool is_meta;
			@JSONOptional bool is_synthetic; @JSONOptional bool pending;
			@JSONOptional bool is_sidechain; @JSONOptional string parent_tool_use_id;
		}
		size_t bubbles = 0;
		// newest clean cut seen so far, used when the event budget runs out
		// between boundaries; without it the scan sails past a perfectly good
		// boundary and keeps going to a much older one
		size_t newestBoundary = size_t.max;
		foreach_reverse (i; 0 .. end)
		{
			scanned++;
			WindowProbe probe;
			td.history[i].enter((scope const(ubyte)[] bytes) {
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				if (event.length > 0)
					probe = jsonParse!WindowProbe(event);
			});
			if (probe.type != "item/started" || probe.is_meta || probe.is_synthetic
				|| probe.is_sidechain || probe.parent_tool_use_id.length > 0)
				continue;
			auto isUser = probe.item_type == "user_message";
			if (isUser || probe.item_type == "text")
				bubbles++;
			// a non-pending user message opens a turn, so it is the only place a
			// window may start without handing the client a split turn
			if (isUser && !probe.pending)
			{
				if (bubbles >= cast(size_t) messageLimit)
					return i;
				newestBoundary = i;
			}
			// event budget spent: stop at the newest clean cut rather than
			// walking further back. with no boundary seen yet there is nothing
			// safe to cut at, so the scan continues until one appears
			if (scanned >= eventBudget && newestBoundary != size_t.max)
				return newestBoundary;
		}
		return 0;
	}

	void handleRequestHistory(WebSocketAdapter ws, int tid, int messageLimit = 0)
	{
		if (tid < 0)
			return;
		ensureHistoryLoaded(tid);
		auto td = host_.getTask(tid);
		if (td is null)
			return;

		auto windowStart = messageLimit > 0 ? historyWindowStart(td, messageLimit) : 0;
		ws.send(Data(toJson(TaskHistoryStartMessage("task_history_start", tid,
			cast(int) td.history.length, cast(int) windowStart, messageLimit)).representation));

		sendHistoryRange(ws, tid, td, windowStart, td.history.length);
		if (host_.resolveTaskHistory(tid).kind == TaskHistoryResolutionKind.access)
			host_.sendHistoryOperations(ws, tid);

		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));
		host_.sendReplaySupplementalState(ws, tid);
	}

	/// Replay the messages immediately older than a window the client already
	/// holds, so it can prepend them instead of rebuilding its list; growing
	/// the window instead would replay everything the client already has.
	void handleRequestHistoryBefore(WebSocketAdapter ws, int tid, int beforeSeq, int messageLimit)
	{
		if (tid < 0)
			return;
		ensureHistoryLoaded(tid);
		auto td = host_.getTask(tid);
		if (td is null)
			return;

		size_t end = beforeSeq < 0 ? 0 : beforeSeq;
		if (end > td.history.length)
			end = td.history.length;
		auto start = messageLimit > 0 ? historyWindowStart(td, messageLimit, end) : 0;

		ws.send(Data(toJson(TaskHistoryPrependStartMessage("task_history_prepend_start",
			tid, cast(int) start, cast(int) end)).representation));
		sendHistoryRange(ws, tid, td, start, end);
		ws.send(Data(toJson(TaskHistoryPrependEndMessage("task_history_prepend_end",
			tid, cast(int) start)).representation));
	}

	private void sendHistoryRange(WebSocketAdapter ws, int tid, TaskData* td,
		size_t start, size_t end)
	{
		// iterate by ref: indexing yields a const copy, which Data.enter and
		// WebSocketAdapter.send both reject
		foreach (i, ref msg; td.history)
		{
			if (i < start || i >= end)
				continue;
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
		host_.subscribe(ws, tid);
		host_.onHistorySubscribed(tid);
	}

	void appendUnconfirmedUserMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		string nonce = null)
	{
		import cydo.protocol : ItemStartedEvent;

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
		td.pendingSteeringTexts ~= extractContentText(uiContent);
	}

	string appendTaskDiagnostic(int tid, string subject, string body)
	{
		import std.datetime : Clock;

		auto td = host_.getTask(tid);
		if (td is null)
			return null;

		auto translated = host_.makeTaskDiagnosticEventJson(subject, body);
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
		{
			registerVisibleTurnAnchorFromEvent(tid, seq, ev.translated, ev.raw);
		}
		host_.sendToSubscribed(tid, Data(
			toJson(TaskEventSeqEnvelope(tid, cast(int) seq, ev.ts.stdTime,
				JSONFragment(ev.translated))).representation));
		if (!merged && host_.noteLiveBoundaryCandidate !is null)
			host_.noteLiveBoundaryCandidate(tid, seq, ev.translated, ev.raw, ev.sourceLine,
				ev.isContextBootstrap);
		return seq;
	}

	void broadcastTask(int tid, TranslatedEvent ev)
	{
		import std.datetime : Clock;

		if (ev.ts == AbsTime.init)
			ev.ts = AbsTime(Clock.currStdTime);

		ev.translated = host_.normalizeKnownSystemMessageMeta(ev.translated, tid);
		host_.updateClaudeUsageFromEvent(tid, ev.translated);

		auto plan = host_.planBroadcast(tid, ev);
		foreach (synthetic; plan.prependedEvents)
			appendAndBroadcastTaskEvent(tid, synthetic);
		if (plan.consumeCurrent)
			return;

		appendAndBroadcastTaskEvent(tid, plan.currentEvent);
	}

	void backfillHistoryBoundary(int tid, size_t seq, HistoryBoundary boundary,
		bool publish = true)
	{
		import cydo.protocol : ItemStartedEvent, TurnStopEvent;

		auto td = host_.getTask(tid);
		assert(td !is null, "history boundary resolved for missing task");
		assert(boundary.anchor.length > 0, "history boundary anchor must be non-empty");
		assert(seq < td.history.length, "history boundary sequence is out of range");

		Data replacement;
		bool alreadyResolved;
		td.history[seq].enter((scope const(ubyte)[] bytes) {
			auto envelope = bytes.as!(char[]);
			auto event = extractEventFromEnvelope(envelope);
			assert(event.length > 0, "history boundary target has no event");
			auto timestamp = extractTsFromEnvelope(envelope);
			@JSONPartial static struct Probe {
				string type; @JSONOptional string item_type; @JSONOptional bool is_meta;
				@JSONOptional bool is_synthetic; @JSONOptional bool pending;
				@JSONOptional bool is_sidechain; @JSONOptional string parent_tool_use_id;
				@JSONOptional HistoryBoundary history_boundary;
			}
			auto probe = jsonParse!Probe(event);
			assert((boundary.kind == HistoryBoundaryKind.user
				&& probe.type == "item/started" && probe.item_type == "user_message"
				&& !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0)
				|| (boundary.kind == HistoryBoundaryKind.agent_turn && probe.type == "turn/stop"
				&& !probe.is_sidechain && probe.parent_tool_use_id.length == 0),
				"history boundary target is ineligible");
			if (probe.history_boundary.anchor.length > 0)
			{
				assert(toJson(probe.history_boundary) == toJson(boundary),
					"history boundary resolution conflicts with canonical event");
				alreadyResolved = true;
				return;
			}
			auto enriched = event[0 .. $ - 1] ~ `,"history_boundary":` ~ toJson(boundary) ~ `}`;
			replacement = Data(toJson(TaskEventEnvelope(tid, timestamp,
				JSONFragment(enriched.idup))).representation);
		});
		if (alreadyResolved)
			return;
		assert(replacement.length > 0, "history boundary replacement was not produced");
		td.history.replaceAt(seq, replacement);
		if (!publish)
			return;
		td.history[seq].enter((scope const(ubyte)[] bytes) {
			auto envelope = bytes.as!(char[]);
			host_.sendToSubscribed(tid, Data(toJson(TaskHistoryBoundaryReplacedEnvelope(
				"task_history_boundary_replaced", tid, cast(int) seq, extractTsFromEnvelope(envelope),
			JSONFragment(extractEventFromEnvelope(envelope).idup))).representation));
		});
		host_.broadcastHistoryOperations(tid);
	}

private:
	static string buildOrphanAgentBody(string agentName, string[] configuredAgentNames)
	{
		import std.algorithm : map;
		import std.array : join;
		auto knownNames = configuredAgentNames.map!(name => "`" ~ name ~ "`").join(", ");
		return "This task uses agent `" ~ agentName ~ "`, which is not configured.\n\n"
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

unittest
{
	auto body = HistoryEventPipeline.buildOrphanAgentBody("missing-agent",
		["work-claude", "codex", "copilot"]);
	assert(body.canFind("`missing-agent`"));
	assert(body.canFind("`work-claude`"));
	assert(body.canFind("`codex`"));
	assert(body.canFind("`copilot`"));
	assert(!body.canFind("`claude`"),
		"orphan message must list configured names, not implicit driver names");
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
	import std.exception : assertThrown;
	import core.exception : AssertError;
	import ae.utils.json : JSONFragment, toJson;
	import cydo.domain.tasks.model : Watermark;
	import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
	// pending is absent here: queue-emitted user messages are pending until
	// confirmed and remain boundary-eligible (removed/unconsumed messages
	// must stay undoable).
	foreach (suffix; [
		`"is_meta":true`, `"is_synthetic":true`,
		`"is_sidechain":true`, `"parent_tool_use_id":"tool"`])
	{
		TaskData td = TaskData(1, "", "");
		td.history.reset(Watermark.none());
		td.history.appendLive(Data(toJson(TaskEventEnvelope(1, 1,
			JSONFragment(`{"type":"item/started","item_id":"u","item_type":"user_message",` ~ suffix ~ `}`))).representation), null);
		HistoryEventPipelineHost host;
		host.getTask = (int tid) => tid == 1 ? &td : null;
		host.sendToSubscribed = (int, Data) {};
		host.broadcastHistoryOperations = (int) {};
		auto pipeline = new HistoryEventPipeline(host);
		assertThrown!AssertError(pipeline.backfillHistoryBoundary(1, 0,
			HistoryBoundary("a", HistoryBoundaryKind.user, null)));
	}
}

unittest
{
	import ae.utils.json : JSONFragment, toJson;
	import cydo.domain.tasks.model : Watermark;
	import cydo.protocol : HistoryBoundary, HistoryBoundaryKind, TurnStopEvent;
	import std.exception : assertThrown;
	import core.exception : AssertError;

	TaskData td = TaskData(1, "", "");
	td.history.reset(Watermark.none());
	TurnStopEvent turn;
	turn.uuid = "turn";
	td.history.appendLive(Data(toJson(TaskEventEnvelope(1, 7,
		JSONFragment(toJson(turn)))).representation), null);
	HistoryEventPipelineHost host;
	host.getTask = (int tid) => tid == 1 ? &td : null;
	host.sendToSubscribed = (int, Data) {};
	host.broadcastHistoryOperations = (int) {};
	auto pipeline = new HistoryEventPipeline(host);
	pipeline.backfillHistoryBoundary(1, 0,
		HistoryBoundary("agent-anchor", HistoryBoundaryKind.agent_turn, null));
	assert((cast(string) td.history[0].toGC()).canFind(`"history_boundary":{"anchor":"agent-anchor","kind":"agent_turn"}`));

	td.history.reset(Watermark.none());
	TurnStopEvent nested;
	nested.parent_tool_use_id = "tool";
	nested.uuid = "nested";
	td.history.appendLive(Data(toJson(TaskEventEnvelope(1, 8,
		JSONFragment(toJson(nested)))).representation), null);
	assertThrown!AssertError(pipeline.backfillHistoryBoundary(1, 0,
		HistoryBoundary("nested-anchor", HistoryBoundaryKind.agent_turn, null)));
}

unittest
{
	import ae.utils.json : JSONFragment, toJson;
	import cydo.domain.tasks.model : Watermark;
	import cydo.protocol : HistoryBoundary, HistoryBoundaryKind, ItemStartedEvent;

	TaskData td = TaskData(1, "", "");
	td.history.reset(Watermark.none());
	auto original = toJson(TaskEventEnvelope(1, 123,
		JSONFragment(`{"type":"item/started","item_id":"u","item_type":"user_message","meta":{"codex":true}}`)));
	td.history.appendLive(Data(original.representation), null);
	string[] published;
	string[] publicationOrder;
	HistoryEventPipelineHost host;
	host.getTask = (int tid) => tid == 1 ? &td : null;
	host.sendToSubscribed = (int, Data data) {
		published ~= cast(string) data.toGC();
		publicationOrder ~= "replacement";
	};
	host.broadcastHistoryOperations = (int tid) {
		assert(tid == 1);
		publicationOrder ~= "operations";
	};
	auto pipeline = new HistoryEventPipeline(host);
	auto boundary = HistoryBoundary("anchor", HistoryBoundaryKind.user, null);
	pipeline.backfillHistoryBoundary(1, 0, boundary);
	assert(published.length == 1);
	assert(publicationOrder == ["replacement", "operations"]);
	assert(published[0].canFind(`"type":"task_history_boundary_replaced","tid":1,"seq":0,"ts":123`));
	auto stored = cast(string) td.history[0].toGC();
	assert(stored.canFind(`"meta":{"codex":true}`));
	assert(stored.canFind(`"history_boundary":{"anchor":"anchor","kind":"user"}`));
	pipeline.backfillHistoryBoundary(1, 0, boundary);
	assert(published.length == 1);
	import std.exception : assertThrown;
	import core.exception : AssertError;
	assertThrown!AssertError(pipeline.backfillHistoryBoundary(1, 0,
		HistoryBoundary("other", HistoryBoundaryKind.user, null)));
}

// Replay reconciliation enriches the canonical event before serialization, but
// does not emit a live replacement frame for a client that has just reset.
unittest
{
	import ae.utils.json : JSONFragment, toJson;
	import cydo.domain.tasks.model : Watermark;
	import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;

	TaskData td = TaskData(1, "", "");
	td.history.reset(Watermark.none());
	td.history.appendLive(Data(toJson(TaskEventEnvelope(1, 123,
		JSONFragment(`{"type":"item/started","item_id":"u","item_type":"user_message"}`))).representation), null);
	string[] published;
	HistoryEventPipelineHost host;
	host.getTask = (int tid) => tid == 1 ? &td : null;
	host.sendToSubscribed = (int, Data data) { published ~= cast(string) data.toGC(); };
	host.broadcastHistoryOperations = (int) {};
	auto pipeline = new HistoryEventPipeline(host);
	pipeline.backfillHistoryBoundary(1, 0,
		HistoryBoundary("replay-anchor", HistoryBoundaryKind.user, null), false);
	assert(published.length == 0);
	auto stored = cast(string) td.history[0].toGC();
	assert(stored.canFind(`"ts":123`));
	assert(stored.canFind(`"history_boundary":{"anchor":"replay-anchor","kind":"user"}`));
}

unittest
{
	import std.algorithm : canFind;
	import std.array : join;
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath, dirName;
	import std.process : environment;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.domain.tasks.model : Watermark;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto dir = buildPath("/tmp", "cydo-history-tool-result-after-dequeue");
	if (exists(dir))
		rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto projectPath = buildPath(dir, "project");
	mkdirRecurse(projectPath);

	// Keep any Claude profile resolution inside the temp location.
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
	td.agentName = "claude";
	td.agentSessionId = "S";
	td.worktreeTid = 0;

	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, buildPath(dir, "claude"));

	// enqueue, dequeue, then a type:"user" line carrying a tool_result. The
	// toolUseResult sidecar makes the translated item/result include a
	// tool_result field — exactly the field the old strict parse choked on.
	auto jsonlPath = buildPath(profile.root, "projects", "project",
		td.agentSessionId ~ ".jsonl");
	mkdirRecurse(dirName(jsonlPath));
	auto jsonl = [
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-11T06:00:00Z","sessionId":"S","content":"are you under control?"}`,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-06-11T06:00:01Z","sessionId":"S"}`,
		`{"parentUuid":"p","isSidechain":false,"type":"user","toolUseResult":{"stdout":"ok"},"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}`,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl);

	td.history.reset(Watermark.atBytes(getSize(jsonlPath)));

	// Minimal host: ensureHistoryLoaded receives its explicit history access.
	// remaining delegates are stubbed no-ops so a stray call can't null-deref.
	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.resolveTaskHistory = (int t) => TaskHistoryResolution.access(
		HistoryAccess(agent, profile, td.agentSessionId, jsonlPath));
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.makeTaskDiagnosticEventJson = (string subject, string body) => "";
	host.sendToSubscribed = (int t, Data d) {};
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendHistoryOperations = (WebSocketAdapter ws, int t) {};
	host.broadcastHistoryOperations = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);

	// Before the fix this throws object.Exception "Unknown field tool_result".
	pipeline.ensureHistoryLoaded(tid);

	assert(td.history.isLoaded, "history must load without throwing");

	// The tool_result must survive translation as an item/result event rather
	// than being dropped by the (mis)parse as a steering echo.
	bool sawToolResult = false;
	foreach (i, ref ev; td.history)
	{
		auto s = cast(string) ev.toGC();
		if (s.canFind(`"item/result"`) && s.canFind("tool_result"))
			sawToolResult = true;
	}
	assert(sawToolResult, "tool_result event missing from loaded history");
}

unittest
{
	import std.algorithm : canFind;
	import std.array : join;
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath, dirName;
	import std.process : environment;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.domain.tasks.model : Watermark;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto dir = buildPath("/tmp", "cydo-history-steering-source-line");
	if (exists(dir))
		rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto projectPath = buildPath(dir, "project");
	mkdirRecurse(projectPath);

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
	td.agentName = "claude";
	td.agentSessionId = "S";
	td.worktreeTid = 0;

	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, buildPath(dir, "claude"));
	auto jsonlPath = buildPath(profile.root, "projects", "project",
		td.agentSessionId ~ ".jsonl");
	mkdirRecurse(dirName(jsonlPath));

	auto enqueueLine = `{"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-11T06:00:00Z","sessionId":"S","content":"queued steering"}`;
	auto assistantLine =
		`{"type":"assistant","uuid":"msg-1","message":{"id":"msg-1","content":[{"type":"text","text":"assistant after steering"},{"type":"text","text":"second content"}],"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":1,"output_tokens":1}}}`;
	auto jsonl = [
		enqueueLine,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-06-11T06:00:01Z","sessionId":"S"}`,
		assistantLine,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl);

	td.history.reset(Watermark.atBytes(getSize(jsonlPath)));

	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.resolveTaskHistory = (int t) => TaskHistoryResolution.access(
		HistoryAccess(agent, profile, td.agentSessionId, jsonlPath));
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.makeTaskDiagnosticEventJson = (string subject, string body) => "";
	host.sendToSubscribed = (int t, Data d) {};
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendHistoryOperations = (WebSocketAdapter ws, int t) {};
	host.broadcastHistoryOperations = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);
	pipeline.ensureHistoryLoaded(tid);

	bool sawQueuedSteering = false;
	foreach (i, ref ev; td.history)
	{
		auto s = cast(string) ev.toGC();
		if (!s.canFind(`"user_message"`) || !s.canFind("queued steering"))
			continue;
		sawQueuedSteering = true;
		assert(td.history.rawAt(i) == enqueueLine,
			"queued steering event must keep the enqueue raw line");
		assert(td.history.sourceLineAt(i) == 1,
			"queued steering event must keep the enqueue physical line");
	}
	assert(sawQueuedSteering, "queued steering replay event missing from loaded history");
	int assistantBoundaries;
	foreach (i, ref ev; td.history)
	{
		auto s = cast(string) ev.toGC();
		if (td.history.rawAt(i) == assistantLine && s.canFind(`"history_boundary"`))
		{
			assistantBoundaries++;
			assert(s.canFind(`"type":"turn/stop"`));
		}
	}
	assert(assistantBoundaries == 1,
		"multi-content assistant replay enriches only its final top-level turn");
}

unittest
{
	import ae.net.asockets : ConnectionState, DisconnectType, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;
	import ae.utils.json : JSONFragment, jsonParse, toJson;
	import cydo.domain.tasks.model : Watermark;
	import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;

	// A synthesized diagnostic is an in-memory history event, rather than a
	// transient broadcast. Keep its typed payload intact so request_history can
	// replay the same event kind the client received live.
	enum tid = 73;
	enum subject = "Failed to load session history";
	enum body = "The Codex session is unavailable.";
	auto td = TaskData(tid, "local", "/tmp");
	td.history.reset(Watermark.none());
	Data[] sent;
	class StubWebSocketAdapter : WebSocketAdapter
	{
		string[] sent;

		this()
		{
			super(new class IConnection
			{
				ConnectionState state_ = ConnectionState.connected;
				void delegate(string, DisconnectType) disconnectHandler;

				@property ConnectionState state() { return state_; }
				void send(scope Data[] data, int priority) {}
				void disconnect(string reason, DisconnectType type)
				{
					state_ = ConnectionState.disconnected;
					disconnectHandler(reason, type);
				}
				@property void handleConnect(void delegate() value) {}
				@property void handleReadData(void delegate(Data) value) {}
				@property void handleDisconnect(void delegate(string, DisconnectType) value)
				{
					disconnectHandler = value;
				}
				@property void handleBufferFlushed(void delegate() value) {}
			});
		}

		override void send(scope Data[] data, int priority)
		{
			sent ~= cast(string) data.joinData().toGC().as!string;
		}
	}
	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.resolveTaskHistory = (int t) => TaskHistoryResolution.noSession();
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.makeTaskDiagnosticEventJson = (string actualSubject, string actualBody) {
		assert(actualSubject == subject);
		assert(actualBody == body);
		TaskDiagnosticEvent diagnostic;
		diagnostic.severity = TaskDiagnosticSeverity.error;
		diagnostic.subject = actualSubject;
		diagnostic.body = actualBody;
		return toJson(diagnostic);
	};
	host.sendToSubscribed = (int t, Data data) { sent ~= data; };
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendHistoryOperations = (WebSocketAdapter ws, int t) {};
	host.broadcastHistoryOperations = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);
	pipeline.appendTaskDiagnostic(tid, subject, body);
	pipeline.appendAndBroadcastTaskEvent(tid,
		TranslatedEvent(`{"type":"process/stderr","text":"after diagnostic"}`,
			null, AbsTime(4242)));

	assert(td.history.length == 2, "diagnostic must precede later task output");
	assert(td.history.rawAt(0) is null, "synthesized diagnostic must have no raw agent line");
	assert(td.history.sourceLineAt(0) == 0, "synthesized diagnostic must not claim a JSONL line");

	auto persisted = cast(string) td.history[0].toGC();
	assert(extractTsFromEnvelope(persisted) > 0,
		"synthesized diagnostic must receive an append timestamp");
	auto persistedEvent = extractEventFromEnvelope(persisted);

	@JSONPartial static struct DiagnosticProbe
	{
		string type;
		string subject;
		string body;
		string severity;
	}
	@JSONPartial static struct EnvelopeProbe
	{
		int tid;
		long ts;
		JSONFragment event;
	}
	auto envelope = jsonParse!EnvelopeProbe(persisted);
	auto replayed = jsonParse!DiagnosticProbe(envelope.event.json);
	assert(envelope.tid == tid && envelope.ts > 0);
	assert(replayed.type == "cydo/task_diagnostic");
	assert(replayed.subject == subject && replayed.body == body);
	assert(replayed.severity == "error");

	auto later = cast(string) td.history[1].toGC();
	assert(extractTsFromEnvelope(later) == 4242,
		"later task event must retain its producer timestamp");
	assert(sent.length == 1, "only the ordinary task event is broadcast here");
	assert(cast(string) sent[0].toGC() == toJson(TaskEventSeqEnvelope(tid, 1,
		4242, JSONFragment(`{"type":"process/stderr","text":"after diagnostic"}`))));

	// Request history through the same generic replay path used by the browser.
	// The replay must retain the typed event rather than construct an item shape.
	auto ws = new StubWebSocketAdapter();
	scope(exit) ws.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistory(ws, tid);
	assert(ws.sent.length == 4, "replay must send start, both events, and end");
	@JSONPartial static struct ReplayProbe
	{
		int tid;
		int seq;
		long ts;
		JSONFragment event;
	}
	auto replayEnvelope = jsonParse!ReplayProbe(ws.sent[1]);
	auto replayedDiagnostic = jsonParse!DiagnosticProbe(replayEnvelope.event.json);
	assert(replayEnvelope.tid == tid && replayEnvelope.seq == 0,
		"diagnostic must replay before later task output");
	assert(replayEnvelope.ts == envelope.ts,
		"replay must preserve the diagnostic timestamp");
	assert(replayEnvelope.event.json == persistedEvent,
		"generic replay must preserve the exact inner event");
	assert(replayedDiagnostic.type == "cydo/task_diagnostic");
	assert(replayedDiagnostic.subject == subject && replayedDiagnostic.body == body);
	assert(replayedDiagnostic.severity == "error");
}

// Windowed replay: a message limit replays only the newest window, cut at a
// genuine (non-pending) user-message boundary so the client never reduces a
// split turn, with seqs left as true history indices.
unittest
{
	import ae.net.asockets : ConnectionState, DisconnectType, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;
	import ae.utils.json : jsonParse;
	import cydo.domain.tasks.model : Watermark;

	enum tid = 74;
	auto td = TaskData(tid, "local", "/tmp");
	td.history.reset(Watermark.none());
	class StubWebSocketAdapter : WebSocketAdapter
	{
		string[] sent;

		this()
		{
			super(new class IConnection
			{
				ConnectionState state_ = ConnectionState.connected;
				void delegate(string, DisconnectType) disconnectHandler;

				@property ConnectionState state() { return state_; }
				void send(scope Data[] data, int priority) {}
				void disconnect(string reason, DisconnectType type)
				{
					state_ = ConnectionState.disconnected;
					disconnectHandler(reason, type);
				}
				@property void handleConnect(void delegate() value) {}
				@property void handleReadData(void delegate(Data) value) {}
				@property void handleDisconnect(void delegate(string, DisconnectType) value)
				{
					disconnectHandler = value;
				}
				@property void handleBufferFlushed(void delegate() value) {}
			});
		}

		override void send(scope Data[] data, int priority)
		{
			sent ~= cast(string) data.joinData().toGC().as!string;
		}
	}
	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.resolveTaskHistory = (int t) => TaskHistoryResolution.noSession();
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.sendToSubscribed = (int t, Data data) {};
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendHistoryOperations = (WebSocketAdapter ws, int t) {};
	host.broadcastHistoryOperations = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);
	// two full turns, then a pending queue record and a trailing assistant
	// message: the pending user at seq 5 must not serve as a boundary
	foreach (event; [
		`{"type":"item/started","item_type":"user_message","uuid":"u1"}`,       // seq 0
		`{"type":"item/started","item_type":"text","item_id":"a1"}`,            // seq 1
		`{"type":"item/started","item_type":"tool_use","item_id":"t1"}`,        // seq 2
		`{"type":"item/started","item_type":"user_message","uuid":"u2"}`,       // seq 3
		`{"type":"item/started","item_type":"text","item_id":"a2"}`,            // seq 4
		`{"type":"item/started","item_type":"user_message","uuid":"q","pending":true}`, // seq 5
		`{"type":"item/started","item_type":"text","item_id":"a3"}`,            // seq 6
	])
		pipeline.appendAndBroadcastTaskEvent(tid, TranslatedEvent(event, null, AbsTime(1000)));
	assert(td.history.length == 7);

	@JSONPartial static struct StartProbe
	{
		string type; int tid; int total; int window_start; int window_limit;
	}
	@JSONPartial static struct SeqProbe
	{
		int seq = -1;
	}

	// no limit: the whole history replays, and says so
	auto wsFull = new StubWebSocketAdapter();
	scope(exit) wsFull.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistory(wsFull, tid);
	auto fullStart = jsonParse!StartProbe(wsFull.sent[0]);
	assert(fullStart.total == 7 && fullStart.window_start == 0);
	assert(fullStart.window_limit == 0, "a full replay reports no window");
	assert(wsFull.sent.length == 9, "full replay sends start, 7 events, and end");

	// limit 2: seq 6 and the pending seq 5 reach the count, but the cut skips
	// back to the non-pending user at seq 3
	auto wsWindow = new StubWebSocketAdapter();
	scope(exit) wsWindow.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistory(wsWindow, tid, 2);
	auto windowStart = jsonParse!StartProbe(wsWindow.sent[0]);
	assert(windowStart.total == 7 && windowStart.window_start == 3);
	assert(windowStart.window_limit == 2, "a windowed replay reports its limit");
	assert(wsWindow.sent.length == 6, "windowed replay sends start, 4 events, and end");
	assert(jsonParse!SeqProbe(wsWindow.sent[1]).seq == 3,
		"windowed replay keeps true history indices");

	// a limit beyond the history replays everything
	auto wsBig = new StubWebSocketAdapter();
	scope(exit) wsBig.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistory(wsBig, tid, 100);
	assert(jsonParse!StartProbe(wsBig.sent[0]).window_start == 0);
	assert(wsBig.sent.length == 9);

	// loading older history replays only the slice before what the client holds,
	// framed so it can prepend rather than rebuild
	@JSONPartial static struct PrependProbe
	{
		string type; int tid; int window_start; int before_seq;
	}
	auto wsBefore = new StubWebSocketAdapter();
	scope(exit) wsBefore.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistoryBefore(wsBefore, tid, 3, 2);
	auto prependStart = jsonParse!PrependProbe(wsBefore.sent[0]);
	assert(prependStart.type == "task_history_prepend_start");
	assert(prependStart.before_seq == 3, "the batch stops where the client's window began");
	assert(prependStart.window_start == 0, "two messages back from seq 3 reaches the start");
	assert(jsonParse!PrependProbe(wsBefore.sent[$ - 1]).type == "task_history_prepend_end");
	assert(wsBefore.sent.length == 5, "only the older slice replays");
	assert(jsonParse!SeqProbe(wsBefore.sent[1]).seq == 0);
	assert(jsonParse!SeqProbe(wsBefore.sent[3]).seq == 2);

	// asking for older history when nothing is held back replays nothing
	auto wsNone = new StubWebSocketAdapter();
	scope(exit) wsNone.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistoryBefore(wsNone, tid, 0, 2);
	assert(wsNone.sent.length == 2, "just the frames, no events");

	// the event budget ends the window even when the message budget is nowhere
	// near spent: a tool-heavy turn is what makes a page unusable, and a message
	// count cannot see it coming
	foreach (n; 0 .. 40)
		pipeline.appendAndBroadcastTaskEvent(tid, TranslatedEvent(
			`{"type":"item/started","item_type":"tool_use","item_id":"noise"}`, null, AbsTime(1000)));
	pipeline.appendAndBroadcastTaskEvent(tid, TranslatedEvent(
		`{"type":"item/started","item_type":"user_message","uuid":"u3"}`, null, AbsTime(1000)));
	pipeline.appendAndBroadcastTaskEvent(tid, TranslatedEvent(
		`{"type":"item/started","item_type":"text","item_id":"a4"}`, null, AbsTime(1000)));

	// limit 3 allows 12 events; the turn at seq 47 is the newest boundary past
	// that budget, so the window starts there rather than walking back to u2
	auto wsBudget = new StubWebSocketAdapter();
	scope(exit) wsBudget.disconnect("test complete", DisconnectType.requested);
	pipeline.handleRequestHistory(wsBudget, tid, 3);
	assert(jsonParse!StartProbe(wsBudget.sent[0]).window_start == 47,
		"the event budget cuts the window at the newest boundary past it");
}

unittest
{
	import cydo.agent.contract : PersistedHistoryBoundaryKind;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto agent = new ClaudeCodeAgent();
	auto boundaries = agent.extractPersistedHistoryBoundaries(
		`{"type":"queue-operation","operation":"enqueue"}` ~ "\n" ~
		`{"type":"user","uuid":"user-checkpoint"}` ~ "\n" ~
		`{"type":"assistant","uuid":"agent-checkpoint"}`);

	assert(boundaries.length == 3);
	assert(boundaries[0].anchor == "enqueue-1");
	assert(boundaries[0].kind == PersistedHistoryBoundaryKind.user);
	assert(boundaries[0].checkpointUuid.length == 0);
	assert(boundaries[1].anchor == "user-checkpoint");
	assert(boundaries[1].kind == PersistedHistoryBoundaryKind.user);
	assert(boundaries[1].checkpointUuid.length == 0);
	assert(boundaries[2].anchor == "agent-checkpoint");
	assert(boundaries[2].kind == PersistedHistoryBoundaryKind.agent_turn);
	assert(boundaries[2].checkpointUuid.length == 0);
}

unittest
{
	import std.exception : assertThrown;
	import core.exception : AssertError;
	import cydo.runtime.config : AgentDriver;

	assertThrown!AssertError(HistoryEventPipeline.assertReplayNativeIdentity(
		AgentDriver.claude, "canonical-uuid", "persisted-uuid"));
	HistoryEventPipeline.assertReplayNativeIdentity(
		AgentDriver.claude, "same-uuid", "same-uuid");
	HistoryEventPipeline.assertReplayNativeIdentity(
		AgentDriver.claude, "", "line:2");
}

// The enqueue record is the authoritative user-message fact: it emits the
// message immediately with the pending presentation; the dequeue + echo pair
// swallows the echo and yields a user_message/consumed confirmation carrying
// the CLI's steering classification; a remove yields "removed"; an enqueue
// with no confirmation at EOF (session killed with the message still queued)
// leaves the pending message visible.
unittest
{
	import std.algorithm : canFind;
	import std.array : join;
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath, dirName;
	import std.process : environment;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.domain.tasks.model : Watermark;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto dir = buildPath("/tmp", "cydo-history-enqueue-primary");
	if (exists(dir))
		rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto projectPath = buildPath(dir, "project");
	mkdirRecurse(projectPath);

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
	td.agentName = "claude";
	td.agentSessionId = "S";
	td.worktreeTid = 0;

	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, buildPath(dir, "claude"));
	auto jsonlPath = buildPath(profile.root, "projects", "project",
		td.agentSessionId ~ ".jsonl");
	mkdirRecurse(dirName(jsonlPath));

	auto jsonl = [
		// consumed as a turn opener: enqueue(1), dequeue(2), echo(3)
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:00Z","sessionId":"S","content":"turn opener"}`,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-08-02T06:00:01Z","sessionId":"S"}`,
		`{"type":"user","uuid":"echo-1","message":{"role":"user","content":"turn opener"}}`,
		// consumed mid-turn with no echo before assistant output: enqueue(4),
		// dequeue(5), assistant(6) — classified as steering
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:02Z","sessionId":"S","content":"steer text"}`,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-08-02T06:00:03Z","sessionId":"S"}`,
		`{"type":"assistant","uuid":"asst-1","message":{"id":"asst-1","content":[{"type":"text","text":"after steer"}],"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}`,
		// removed without consumption: enqueue(7), remove(8)
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:04Z","sessionId":"S","content":"withdrawn text"}`,
		`{"type":"queue-operation","operation":"remove","timestamp":"2026-08-02T06:00:05Z","sessionId":"S"}`,
		// killed with the message still queued: enqueue(9), nothing after
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:06Z","sessionId":"S","content":"still queued"}`,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl);

	td.history.reset(Watermark.atBytes(getSize(jsonlPath)));

	HistoryEventPipelineHost host;
	host.getTask = (int t) => t == tid ? &td : null;
	host.resolveTaskHistory = (int t) => TaskHistoryResolution.access(
		HistoryAccess(agent, profile, td.agentSessionId, jsonlPath));
	host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
	host.normalizeKnownSystemMessageMeta = (string translated, int t) => translated;
	host.makeTaskDiagnosticEventJson = (string subject, string body) => "";
	host.sendToSubscribed = (int t, Data d) {};
	host.subscribe = (WebSocketAdapter ws, int t) {};
	host.sendHistoryOperations = (WebSocketAdapter ws, int t) {};
	host.broadcastHistoryOperations = (int t) {};
	host.sendReplaySupplementalState = (WebSocketAdapter ws, int t) {};
	host.onHistorySubscribed = (int t) {};
	host.updateClaudeUsageFromEvent = (int t, string translated) => false;
	host.planBroadcast = (int t, TranslatedEvent ev) => HistoryBroadcastPlan.init;

	auto pipeline = new HistoryEventPipeline(host);
	pipeline.ensureHistoryLoaded(tid);
	assert(td.history.isLoaded);

	string[] events;
	foreach (i, ref ev; td.history)
		events ~= cast(string) ev.toGC();

	// All four messages are present, each emitted from its enqueue record
	// with the pending presentation and the enqueue anchor as identity.
	foreach (needle; ["turn opener", "steer text", "withdrawn text", "still queued"])
	{
		bool found;
		foreach (s; events)
			if (s.canFind(`"user_message"`) && s.canFind(needle)
				&& s.canFind(`"pending":true`) && s.canFind(`"uuid":"enqueue-`))
				found = true;
		assert(found, "missing pending user message: " ~ needle);
	}

	// The canonical echo message is re-emitted after its confirmation, under
	// its native identity, and the confirmation carries that identity so the
	// UI can drop the provisional bubble and anchors resolve either name.
	bool sawCanonicalEcho, sawNative;
	foreach (s; events)
	{
		if (s.canFind(`"user_message"`) && s.canFind(`"uuid":"echo-1"`))
			sawCanonicalEcho = true;
		if (s.canFind(`"user_message/consumed"`) && s.canFind(`"native_uuid":"echo-1"`))
			sawNative = true;
	}
	assert(sawCanonicalEcho, "canonical echo message missing");
	assert(sawNative, "confirmation must carry the echo native uuid");

	// Confirmations: turn_start for the opener, steering for the steer,
	// removed for the withdrawn message, and none for the still-queued one.
	bool sawTurnStart, sawSteering, sawRemoved;
	foreach (s; events)
	{
		if (!s.canFind(`"user_message/consumed"`))
			continue;
		if (s.canFind(`"enqueue-1"`) && s.canFind(`"turn_start"`))
			sawTurnStart = true;
		if (s.canFind(`"enqueue-4"`) && s.canFind(`"steering"`))
			sawSteering = true;
		if (s.canFind(`"enqueue-7"`) && s.canFind(`"removed"`))
			sawRemoved = true;
		assert(!s.canFind(`"enqueue-9"`), "still-queued enqueue must have no confirmation");
	}
	assert(sawTurnStart, "turn_start confirmation missing");
	assert(sawSteering, "steering confirmation missing");
	assert(sawRemoved, "removed confirmation missing");
}
