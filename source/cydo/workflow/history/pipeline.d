module cydo.workflow.history.pipeline;

import std.algorithm : canFind, startsWith;
import std.file : append, exists, mkdirRecurse, read;
import std.format : format;
import std.logger : infof, tracef;
import std.path : dirName;
import std.string : representation;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import ae.net.asockets : ConnectionState, onNextTick, socketManager;
import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.array : as;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;
import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent, DriverHistory, PersistedHistoryBoundaryKind;
import cydo.agent.drivers.claude_queue : ClaudeQueueOutcome, ClaudeQueueOutcomeKind,
	classifyClaudeQueueRecords;
import cydo.protocol : ContentBlock, ItemStartedEvent, TaskEventEnvelope,
	TaskHistoryBoundaryReplacedEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, UserMessageConsumedEvent, HistoryBoundary,
	HistoryBoundaryKind, extractContentText;
import cydo.runtime.config : AgentDriver;
import cydo.domain.storage.persistence : LoadedHistory;
import cydo.domain.tasks.model : QueueOperationProbe, TaskData, TaskHistoryEndMessage,
	TaskHistoryStartMessage, Watermark, buildSyntheticUserEvent, extractEventFromEnvelope,
	extractTsFromEnvelope, isQueueOperation, watermarkFromPath;
import cydo.workflow.history.native_history : HistoryAccess,
	TaskHistoryResolution, TaskHistoryResolutionKind, UnavailableHistory,
	UnavailableHistoryKind;
import cydo.workflow.history.jsonl_store : completeJsonlPrefix, loadTaskHistoryContent;

package(cydo):

struct HistoryBroadcastPlan
{
	TranslatedEvent[] prependedEvents;
	TranslatedEvent currentEvent;
	bool consumeCurrent;
	LocalUserProvenance localUserProvenance;
}

enum LocalUserProvenance { ordinary, registeredLocal }

alias HistoryLoaded = void delegate();

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
		bool isContextBootstrap, LocalUserProvenance localUserProvenance)
		noteLiveBoundaryCandidate;
	void delegate(WebSocketAdapter ws, int tid) sendReplaySupplementalState;
	void delegate(int tid) onHistorySubscribed;
	bool delegate(int tid, string translated) updateClaudeUsageFromEvent;
	HistoryBroadcastPlan delegate(int tid, TranslatedEvent ev) planBroadcast;
	Promise!DriverHistory delegate(int tid, HistoryAccess access) loadDriverHistory;
}

/// The user_message/consumed confirmations recorded at `lineNum`.
private TranslatedEvent[] queueConfirmations(const ClaudeQueueOutcome[int] outcomes,
	const string[][int] targets, int lineNum)
{
	auto here = lineNum in targets;
	if (here is null)
		return null;
	TranslatedEvent[] result;
	foreach (enqueueUuid; *here)
	{
		import std.conv : to;
		auto enqueueLine = enqueueUuid["enqueue-".length .. $].to!int;
		string consumedAs;
		final switch (outcomes[enqueueLine].kind)
		{
			case ClaudeQueueOutcomeKind.queued:
				assert(false, "a queued message records no outcome");
			case ClaudeQueueOutcomeKind.turnStart: consumedAs = "turn_start"; break;
			case ClaudeQueueOutcomeKind.steering: consumedAs = "steering"; break;
			case ClaudeQueueOutcomeKind.removed: consumedAs = "removed"; break;
			case ClaudeQueueOutcomeKind.cancelled: consumedAs = "cancelled"; break;
		}
		result ~= TranslatedEvent(toJson(UserMessageConsumedEvent(
			uuid: enqueueUuid, consumed_as: consumedAs)), null, AbsTime.init, lineNum);
	}
	return result;
}

class HistoryEventPipeline
{
	private HistoryEventPipelineHost host_;
	/// A driver read and the continuations waiting for it. They belong to the
	/// store generation the read was started for.
	private static final class DriverLoad
	{
		ulong generation;
		HistoryAccess access;
		HistoryLoaded[] waiters;

		this(ulong generation, HistoryAccess access, HistoryLoaded[] waiters)
		{
			this.generation = generation;
			this.access = access;
			this.waiters = waiters;
		}
	}

	/// The most recently started driver read of each task.
	private DriverLoad[int] driverLoads_;

	this(HistoryEventPipelineHost host)
	{
		host_ = host;
	}

	/// Returns the resolution used to load history, or null when history was
	/// already loaded and no resolution was performed.
	Nullable!TaskHistoryResolution ensureHistoryLoaded(int tid)
	{
		return whenHistoryLoadedImpl(tid, () {}, true, true);
	}

	/// Exit-path variant of `ensureHistoryLoaded`. On exit, the live binding
	/// is about to be torn down and re-resolved against config alone by the
	/// post-exit reset (App.resetHistoryWatermark); that later resolution is
	/// the sole owner of the unavailable-history diagnostic for the exit
	/// sequence, so this variant loads history the same way but never reports.
	Nullable!TaskHistoryResolution ensureHistoryLoadedForExit(int tid)
	{
		return whenHistoryLoadedImpl(tid, () {}, true, false);
	}

	void whenHistoryLoaded(int tid, HistoryLoaded dg)
	{
		whenHistoryLoadedImpl(tid, dg, false, true);
	}

	private Nullable!TaskHistoryResolution whenHistoryLoadedImpl(int tid,
		HistoryLoaded dg, bool fileOnly, bool reportUnavailable)
	{
		auto td = host_.getTask(tid);
		assert(!fileOnly || td is null || !td.history.isDriverServed,
			"Synchronous load requires file-backed history");
		if (td is null || td.history.isLoaded)
		{
			dg();
			return Nullable!TaskHistoryResolution.init;
		}
		if (td.history.isLoading)
		{
			auto load = driverLoads_[tid];
			assert(load.generation == td.history.generation,
				"A loading store belongs to the read of its own generation");
			load.waiters ~= dg;
			return Nullable!TaskHistoryResolution.init;
		}

		auto resolution = host_.resolveTaskHistory(tid);
		if (resolution.kind != TaskHistoryResolutionKind.access
			|| !resolution.requireAccess().isDriverServed)
		{
			loadFileHistory(tid, td, resolution, reportUnavailable);
			dg();
			return Nullable!TaskHistoryResolution(resolution);
		}
		assert(!fileOnly, "Synchronous load requires file-backed history");
		auto access = resolution.requireAccess();
		auto load = new DriverLoad(td.history.beginDriverLoad(), access, [dg]);
		// A read of an earlier generation keeps its own waiters until it settles.
		driverLoads_[tid] = load;

		// Settle on a tick of its own: the promise would turn an exception
		// escaping a continuation into a rejection nobody observes.
		host_.loadDriverHistory(tid, access).then(
			(DriverHistory value) {
				onNextTick(socketManager, () { finishDriverLoad(tid, load, value, null); });
			},
			(Exception failure) {
				onNextTick(socketManager, () {
					finishDriverLoad(tid, load, DriverHistory.init, failure);
				});
			}).ignoreResult();
		return Nullable!TaskHistoryResolution.init;
	}

	private void finishDriverLoad(int tid, DriverLoad load, DriverHistory value,
		Exception failure)
	{
		if (auto latest = tid in driverLoads_)
			if (*latest is load)
				driverLoads_.remove(tid);
		auto td = host_.getTask(tid);
		if (td !is null && td.history.generation == load.generation)
		{
			LoadedHistory loaded;
			foreach (event; filterTransientSessionStatusEvents(value.events))
			{
				auto translated = host_.injectAgentNameIntoSessionInit(event.translated,
					td.agentName);
				loaded.history ~= Data(toJson(TaskEventEnvelope(tid,
					event.ts.stdTime, JSONFragment(translated))).representation);
				loaded.rawSource ~= event.raw;
				loaded.sourceLine ~= event.sourceLine;
			}
			import std.algorithm.mutation : move;
			td.history.completeDriverLoad(load.generation, move(loaded), value.mode);
			if (failure !is null)
			{
				auto unavailable = TaskHistoryResolution.unavailable(UnavailableHistory(
					UnavailableHistoryKind.driverRead, td.agentName,
					load.access.sessionId, failure.msg, load.access.agent.nativeHistoryRule,
					load.access.profile));
				host_.reportUnavailableHistory(tid, unavailable);
			}
			rebuildVisibleTurnAnchors(tid);
			host_.broadcastHistoryOperations(tid);
		}
		deliver(tid, load.waiters);
	}

	/// Each continuation asks again, so one that follows a reset waits for
	/// the next load instead of running against an unloaded store. An
	/// exception leaves through the event loop once the rest have been served.
	private void deliver(int tid, HistoryLoaded[] waiters)
	{
		if (waiters.length == 0)
			return;
		scope (exit)
			deliver(tid, waiters[1 .. $]);
		whenHistoryLoaded(tid, waiters[0]);
	}

	private void loadFileHistory(int tid, TaskData* td,
		TaskHistoryResolution resolution, bool reportUnavailable)
	{
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
			return;
		}

		bool hasQueueOps = false;
		int userMsgFromJsonl = 0;
		// Queue rows close the open API message before queue events (Rule E).
		// The enqueue record is the authoritative "user
		// sent this" fact and emits the message immediately (pending
		// presentation, identity enqueue-N). Its outcome, classified up front
		// from the whole file (classifyClaudeQueueRecords), is reported where
		// it is recorded by a user_message/consumed confirmation: the echo of
		// a turn opener is swallowed and re-emitted after its confirmation;
		// steering, legacy removal and withdrawal confirm in place. Entries
		// still queued at EOF stay pending — a killed session's unconsumed
		// steer remains visible.
		ClaudeQueueOutcome[int] queueOutcomes;
		// Outcome line → the enqueue identities whose outcome it records.
		string[][int] queueOutcomeTargets;
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

			string content;
			if (jsonlPath.length > 0 && maxBytes > 0 && exists(jsonlPath))
				content = completeJsonlPrefix(cast(string) read(jsonlPath, cast(size_t) maxBytes));
			auto inactiveLines = ta.inactiveHistoryLines(content);
			queueOutcomes = null;
			queueOutcomeTargets = null;
			if (ta.driver == AgentDriver.claude && content.length > 0)
			{
				queueOutcomes = classifyClaudeQueueRecords(content, inactiveLines);
				foreach (enqueueLine, outcome; queueOutcomes)
					if (outcome.kind != ClaudeQueueOutcomeKind.queued)
						queueOutcomeTargets[outcome.line] ~= format!"enqueue-%d"(enqueueLine);
			}

			auto replay = ta.createHistoryReplay();
			return loadTaskHistoryContent(tid, content, delegate TranslatedEvent[](string line, int lineNum) {
				if (lineNum in inactiveLines)
					return [];
				auto confirmations = queueConfirmations(queueOutcomes,
					queueOutcomeTargets, lineNum);
				if (isQueueOperation(line))
				{
					auto closed = replay.translateHistoryLine(line, lineNum);
					auto op = jsonParse!QueueOperationProbe(line);
					if (op.operation == "enqueue")
					{
						hasQueueOps = true;
						auto enqueueUuid = format!"enqueue-%d"(lineNum);
						auto synEv = buildSyntheticUserEvent(op.content, false, true);
						synEv.uuid = enqueueUuid;
						return stripTransientStatus(closed ~ [TranslatedEvent(
							toJsonWithSyntheticUserMeta(op.content, synEv, tid),
							line, AbsTime.init, lineNum)]);
					}
					return stripTransientStatus(closed ~ confirmations);
				}
				if (confirmations.length > 0)
				{
					// The consumption echo is the canonical message record:
					// emit it exactly as the pre-queue-primary pipeline did
					// (anchors, checkpoints and truncation semantics attach to
					// it), preceded by the confirmation that tells the UI to
					// drop the provisional enqueue-emitted bubble.
					auto events = replay.translateHistoryLine(line, lineNum);
					assert(confirmations.length == 1,
						"one echo row confirms exactly one queued message");
					auto consumed = jsonParse!UserMessageConsumedEvent(
						confirmations[0].translated);
					@JSONPartial static struct EchoProbe
					{
						string type;
						@JSONOptional string item_type;
						@JSONOptional string uuid;
					}
					foreach (i, event; events)
					{
						auto echo = jsonParse!EchoProbe(event.translated);
						if (echo.type != "item/started" || echo.item_type != "user_message")
							continue;
						consumed.native_uuid = echo.uuid.length > 0 ? echo.uuid : consumed.uuid;
						auto confirmation = TranslatedEvent(toJson(consumed), null, AbsTime.init, lineNum);
						return stripTransientStatus(events[0 .. i] ~ confirmation ~ events[i .. $]);
					}
					assert(false, "Claude queue echo must translate to a user message");
				}
				if (ta.isHistoryPrompt(line))
					userMsgFromJsonl++;
				return stripTransientStatus(replay.translateHistoryLine(line, lineNum));
			}, replay.finishHistoryReplay);
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
				// The row is Copilot's events.jsonl format, so undo can cut a
				// Copilot history at it. Other agents' files neither use this
				// format nor are CyDo's to append to.
				if (jsonlPath.length > 0 && ta.driver == AgentDriver.copilot)
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
			// A turn opener's boundary belongs to its canonical echo; a
			// withdrawn message has left the conversation.
			if (boundaries[0].kind == PersistedHistoryBoundaryKind.provisional_user
				&& boundaries[0].sourceLine in queueOutcomes
				&& (queueOutcomes[boundaries[0].sourceLine].kind == ClaudeQueueOutcomeKind.turnStart
					|| queueOutcomes[boundaries[0].sourceLine].kind == ClaudeQueueOutcomeKind.cancelled))
			{
				tracef("queue replay: suppressing boundary %s", boundaries[0].anchor);
				continue;
			}
			auto isUser = probe.type == "item/started" && probe.item_type == "user_message"
				&& !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& !probe.pending && probe.parent_tool_use_id.length == 0;
			auto isProvisionalUser = probe.type == "item/started"
				&& probe.item_type == "user_message" && probe.pending
				&& !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0
				&& boundaries[0].anchor.startsWith("enqueue-");
			auto isTurn = probe.type == "turn/stop" && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0;
			if ((boundaries[0].kind == PersistedHistoryBoundaryKind.user && !isUser)
				|| (boundaries[0].kind == PersistedHistoryBoundaryKind.provisional_user
					&& !isProvisionalUser)
				|| (boundaries[0].kind == PersistedHistoryBoundaryKind.agent_turn && !isTurn))
				continue;
			assertReplayNativeIdentity(ta.driver,
				probe.uuid.length > 0 ? probe.uuid : probe.item_id, boundaries[0].anchor);
			if (ta.driver == AgentDriver.claude
				&& boundaries[0].kind == PersistedHistoryBoundaryKind.user)
				boundaries[0].checkpointUuid = td.checkpointUuidForAnchor(boundaries[0].anchor);
			backfillHistoryBoundary(tid, i, HistoryBoundary(boundaries[0].anchor,
				boundaries[0].kind == PersistedHistoryBoundaryKind.user
					? HistoryBoundaryKind.user
					: boundaries[0].kind == PersistedHistoryBoundaryKind.provisional_user
						? HistoryBoundaryKind.provisional_user : HistoryBoundaryKind.agent_turn,
				boundaries[0].checkpointUuid), false);
		}
		if (ta !is null)
			host_.broadcastHistoryOperations(tid);
	}

	/// Find the boundary `requestedAnchor` names in the task's session file
	/// as it is now. `opensConversation`: no other user boundary precedes it.
	bool resolveFreshPersistedBoundary(int tid, const ref HistoryAccess access,
		string requestedAnchor, out HistoryBoundary boundary, out bool opensConversation)
	{
		assert(!access.isDriverServed, "Fresh boundary resolution requires file-backed history");
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

		bool found, userBefore;
		foreach (ref entry; snapshot.history)
		{
			HistoryBoundary candidate;
			entry.enter((scope const(ubyte)[] bytes) {
				@JSONPartial static struct Probe { @JSONOptional HistoryBoundary history_boundary; }
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				candidate = jsonParse!Probe(event).history_boundary;
			});
			if (candidate.anchor != requestedAnchor)
			{
				if (!found && candidate.anchor.length > 0
					&& candidate.kind == HistoryBoundaryKind.user)
					userBefore = true;
				continue;
			}
			assert(!found, "persisted history boundary anchor must be unique");
			boundary = candidate;
			opensConversation = !userBefore;
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

	void handleRequestHistory(WebSocketAdapter ws, int tid)
	{
		if (tid < 0)
			return;
		whenHistoryLoaded(tid, () {
			if (ws.state == ConnectionState.connected)
				sendHistory(ws, tid);
		});
	}

	private void sendHistory(WebSocketAdapter ws, int tid)
	{
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
		if (host_.resolveTaskHistory(tid).kind == TaskHistoryResolutionKind.access)
			host_.sendHistoryOperations(ws, tid);

		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));
		host_.sendReplaySupplementalState(ws, tid);
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
		// File-backed history loads here. A driver read only starts: the
		// message takes its place among the live events buffered behind it,
		// which reach clients through the replay.
		whenHistoryLoaded(tid, () {});
		td = host_.getTask(tid);
		if (td is null)
			return;
		if (td.history.appendLive(data, null) != cast(size_t) -1)
			host_.sendToSubscribed(tid, data);
		td.pendingSteeringTexts ~= ev.text;
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

	size_t appendAndBroadcastTaskEvent(int tid, TranslatedEvent ev,
		LocalUserProvenance localUserProvenance = LocalUserProvenance.ordinary)
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
		{
			if (ev.turnBoundary.anchor.length > 0)
				attachTurnBoundary(tid, td, ev.turnBoundary);
			return seq;
		}

		if (!merged)
		{
			registerVisibleTurnAnchorFromEvent(tid, seq, ev.translated, ev.raw);
		}
		host_.sendToSubscribed(tid, Data(
			toJson(TaskEventSeqEnvelope(tid, cast(int) seq, ev.ts.stdTime,
				JSONFragment(ev.translated))).representation));
		if (!merged && host_.noteLiveBoundaryCandidate !is null)
			host_.noteLiveBoundaryCandidate(tid, seq, ev.translated, ev.raw, ev.sourceLine,
				ev.isContextBootstrap, localUserProvenance);
		if (ev.turnBoundary.anchor.length > 0)
			attachTurnBoundary(tid, td, ev.turnBoundary);
		return seq;
	}

	private enum TurnEvent { other, stop, result }

	private static TurnEvent turnEventOf(scope const(char)[] envelope)
	{
		@JSONPartial static struct Probe
		{
			string type;
			@JSONOptional bool is_sidechain;
			@JSONOptional string parent_tool_use_id;
		}
		auto probe = jsonParse!Probe(extractEventFromEnvelope(envelope));
		if (probe.is_sidechain || probe.parent_tool_use_id.length > 0)
			return TurnEvent.other;
		return probe.type == "turn/stop" ? TurnEvent.stop
			: probe.type == "turn/result" ? TurnEvent.result : TurnEvent.other;
	}

	/// An agent that knows where a turn ends says so with the turn/result,
	/// which has just been appended. The boundary belongs on the last
	/// turn/stop of that turn; a turn that produced none has no boundary.
	private void attachTurnBoundary(int tid, TaskData* td, HistoryBoundary boundary)
	{
		assert(boundary.kind == HistoryBoundaryKind.agent_turn);
		if (!td.history.isLoaded)
		{
			bool newest = true;
			td.history.amendPending((ref Data event) {
				if (newest)
				{
					// The turn/result that carried the boundary.
					newest = false;
					return false;
				}
				TurnEvent kind;
				event.enter((scope const(ubyte)[] bytes) { kind = turnEventOf(bytes.as!(char[])); });
				if (kind == TurnEvent.stop)
					event = withHistoryBoundary(tid, event, boundary);
				return kind != TurnEvent.other;
			});
			return;
		}
		foreach_reverse (seq; 0 .. td.history.length - 1)
		{
			TurnEvent kind;
			td.history[seq].enter((scope const(ubyte)[] bytes) {
				kind = turnEventOf(bytes.as!(char[]));
			});
			if (kind == TurnEvent.stop)
				backfillHistoryBoundary(tid, seq, boundary);
			if (kind != TurnEvent.other)
				return;
		}
	}

	private static Data withHistoryBoundary(int tid, ref const Data envelopeData,
		HistoryBoundary boundary)
	{
		Data replacement;
		envelopeData.enter((scope const(ubyte)[] bytes) {
			auto envelope = bytes.as!(char[]);
			auto event = extractEventFromEnvelope(envelope);
			auto enriched = event[0 .. $ - 1] ~ `,"history_boundary":` ~ toJson(boundary) ~ `}`;
			replacement = Data(toJson(TaskEventEnvelope(tid, extractTsFromEnvelope(envelope),
				JSONFragment(enriched.idup))).representation);
		});
		return replacement;
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

		appendAndBroadcastTaskEvent(tid, plan.currentEvent,
			plan.localUserProvenance);
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
			@JSONPartial static struct Probe {
				string type; @JSONOptional string item_type; @JSONOptional bool is_meta;
				@JSONOptional bool is_synthetic; @JSONOptional bool pending;
				@JSONOptional bool is_sidechain; @JSONOptional string parent_tool_use_id;
				@JSONOptional HistoryBoundary history_boundary;
			}
			auto probe = jsonParse!Probe(event);
			bool isUser = boundary.kind == HistoryBoundaryKind.user
				&& probe.type == "item/started" && probe.item_type == "user_message"
				&& !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& !probe.pending && probe.parent_tool_use_id.length == 0;
			bool isProvisionalUser = boundary.kind == HistoryBoundaryKind.provisional_user
				&& boundary.anchor.startsWith("enqueue-")
				&& probe.type == "item/started" && probe.item_type == "user_message"
				&& probe.pending && !probe.is_meta && !probe.is_synthetic && !probe.is_sidechain
				&& probe.parent_tool_use_id.length == 0;
			bool isTurn = boundary.kind == HistoryBoundaryKind.agent_turn && probe.type == "turn/stop"
				&& !probe.is_sidechain && probe.parent_tool_use_id.length == 0;
			assert(isUser || isProvisionalUser || isTurn,
				"history boundary target is ineligible");
			if (probe.history_boundary.anchor.length > 0)
			{
				assert(toJson(probe.history_boundary) == toJson(boundary),
					"history boundary resolution conflicts with canonical event");
				alreadyResolved = true;
				return;
			}
		});
		if (alreadyResolved)
			return;
		td.history.replaceAt(seq, withHistoryBoundary(tid, td.history[seq], boundary));
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
	bool completed;
	pipeline.whenHistoryLoaded(tid, () {
		assert(td.history.isLoaded, "history must load without throwing");
		completed = true;
	});
	assert(completed, "file-backed history must complete inline");

	// The tool_result must survive translation as an item/result event rather
	// than being dropped by the (mis)parse as a steering echo.
	bool sawToolResult = false;
	foreach (i, ref ev; td.history)
	{
		auto s = cast(string) ev.toGC();
		if (s.canFind(`"item/result"`) && s.canFind("tool_result"))
		{
			sawToolResult = true;
			assert(!s.canFind(`"history_boundary"`),
				"a tool-result-only outer user record must not open a user boundary");
		}
	}
	assert(sawToolResult, "tool_result event missing from loaded history");
}

@("Claude replay preserves source lines and stops before the next prompt")
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
		`{"type":"assistant","uuid":"record-1","message":{"id":"msg-1","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"true"}}],"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":1,"output_tokens":1}}}`;
	auto toolResultLine = `{"type":"user","uuid":"result-1","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}`;
	auto lastAssistantLine = `{"type":"assistant","uuid":"record-2","message":{"id":"msg-1","content":[{"type":"tool_use","id":"tool-2","name":"Write","input":{"type":"queue-operation","nested":{"type":"user"}}}],"model":"claude-3-5-sonnet-20241022","usage":{"input_tokens":1,"output_tokens":1}}}`;
	string[] replayMismatches;
	auto extracted = agent.extractPersistedHistoryBoundaries(lastAssistantLine, 4);
	if (extracted.length != 1 || extracted[0].kind != PersistedHistoryBoundaryKind.agent_turn
		|| extracted[0].sourceLine != 5)
		replayMismatches ~= "final grouped assistant member must extract as an agent turn at line 5";
	auto jsonl = [
		enqueueLine,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-06-11T06:00:01Z","sessionId":"S"}`,
		assistantLine,
		toolResultLine,
		lastAssistantLine,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl ~ `{"type":"assistant","message":`);

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
		assert(td.history.sourceLineAt(i) <= 5, "partial row reached replay");
		if (s.canFind(`"type":"turn/stop"`) && s.canFind(`"history_boundary"`))
		{
			assistantBoundaries++;
			assert(td.history.rawAt(i) == lastAssistantLine);
			assert(td.history.sourceLineAt(i) == 5);
			assert(s.canFind(`"uuid":"msg-1"`));
			assert(s.canFind(`"anchor":"msg-1"`));
		}
	}
	assert(assistantBoundaries == 1,
		"multi-content assistant replay enriches only its final top-level turn");
	// Both the ordinary prompt and the canonical queue echo close reply 1
	// at the same point, including when the snapshot ends with that prompt.
	enum firstPrompt = `{"type":"user","uuid":"prompt-1","message":{"content":"first prompt"}}`;
	enum secondPrompt = `{"type":"user","uuid":"prompt-2","message":{"content":"second prompt"}}`;
	enum secondReply = `{"type":"assistant","uuid":"record-3","message":{"id":"msg-2","content":[{"type":"text","text":"second reply"}]}}`;
	foreach (queued; [false, true])
	{
		auto rows = [firstPrompt, assistantLine, toolResultLine, lastAssistantLine];
		if (queued)
			rows ~= [
				`{"type":"queue-operation","operation":"enqueue","content":"second prompt"}`,
				`{"type":"queue-operation","operation":"dequeue"}`,
			];
		rows ~= secondPrompt;
		auto prefix = rows.join("\n") ~ "\n";
		write(jsonlPath, prefix ~ secondReply ~ "\n");
		foreach (bounded; [false, true])
		{
			td.history.reset(Watermark.atBytes(bounded ? prefix.length : getSize(jsonlPath)));
			pipeline.ensureHistoryLoaded(tid);

			@JSONPartial static struct ReplayEvent
			{
				string type;
				@JSONOptional string uuid;
				@JSONOptional string native_uuid;
				@JSONOptional HistoryBoundary history_boundary;
			}
			string[] order;
			foreach (i, ref entry; td.history)
			{
				auto envelope = cast(string) entry.toGC();
				auto event = jsonParse!ReplayEvent(extractEventFromEnvelope(envelope));
				switch (event.type)
				{
					case "turn/stop":
						assert(event.history_boundary.kind == HistoryBoundaryKind.agent_turn);
						assert(event.history_boundary.anchor == event.uuid);
						goto case "item/started";
					case "item/started", "item/completed", "item/result":
						order ~= event.type ~ ":" ~ event.uuid ~ ":" ~ format!"%d"(td.history.sourceLineAt(i));
						break;
					case "user_message/consumed":
						order ~= event.type ~ ":" ~ event.uuid ~ ":" ~ event.native_uuid;
						break;
					default: break;
				}
			}
			string[] expected = [
				"item/started:prompt-1:1",
				"item/started::2", "item/completed::2", "item/result::3",
				"item/started::4", "item/completed::4",
			];
			expected ~= "turn/stop:msg-1:4";
			if (queued)
				expected ~= "item/started:enqueue-5:5";
			if (queued)
				expected ~= "user_message/consumed:enqueue-5:prompt-2";
			expected ~= queued ? "item/started:prompt-2:7" : "item/started:prompt-2:5";
			if (!bounded)
				expected ~= queued
					? ["item/started::8", "item/completed::8", "turn/stop:msg-2:8"]
					: ["item/started::6", "item/completed::6", "turn/stop:msg-2:6"];
			if (order != expected)
				replayMismatches ~= format!"queued=%s bounded=%s: %s, expected %s"(queued, bounded, order, expected);
		}
	}
	// A prompt queued during the tool follows the completed API message.
	// A prompt queued during streaming precedes both persisted members.
	enum toolMember = `{"type":"assistant","uuid":"record-1","apiBlockIndex":0,"message":{"id":"msg-1","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{}}]}}`;
	enum text0 = `{"type":"assistant","uuid":"text-0","apiBlockIndex":0,"message":{"id":"msg-1","content":[{"type":"text","text":"first block"}]}}`;
	enum text1 = `{"type":"assistant","uuid":"text-1","apiBlockIndex":1,"message":{"id":"msg-1","content":[{"type":"text","text":"second block"}]}}`;
	enum queuedPrompt = `{"type":"queue-operation","operation":"enqueue","content":"queued"}`;
	foreach (duringTool; [false, true])
	{
		auto rows = duringTool
			? [toolMember, queuedPrompt, toolResultLine,
				`{"type":"queue-operation","operation":"remove"}`,
				`{"type":"attachment","attachment":{"type":"queued_command","prompt":"queued"}}`,
				secondReply, secondPrompt]
			: [queuedPrompt, text0, text1];
		write(jsonlPath, rows.join("\n") ~ "\n");
		td.history.reset(Watermark.atBytes(getSize(jsonlPath)));
		pipeline.ensureHistoryLoaded(tid);

		@JSONPartial static struct Event
		{
			string type;
			@JSONOptional string item_type;
			@JSONOptional string uuid;
		}
		string[] order;
		foreach (i, ref entry; td.history)
		{
			auto event = jsonParse!Event(extractEventFromEnvelope(cast(string) entry.toGC()));
			if (event.type == "turn/stop" && event.uuid == "msg-1")
				order ~= "stop";
			if (event.type == "item/started" && event.item_type == "user_message"
				&& event.uuid == (duringTool ? "enqueue-2" : "enqueue-1"))
				order ~= "queued";
			if (!duringTool && event.type == "item/started" && event.item_type == "text"
				&& td.history.sourceLineAt(i) == 2)
				order ~= "first block";
		}
		auto expected = duringTool ? ["stop", "queued"] : ["queued", "first block", "stop"];
		if (order != expected)
			replayMismatches ~= format!"queued during %s: got %s, expected %s"(
				duringTool ? "tool" : "stream", order, expected);
	}
	// A confirmed enqueue uses its canonical echo, while an unconsumed
	// enqueue still resolves by its provisional anchor.
	foreach (queueType; ["queue-operation", "queue/operation"])
	{
		auto rows = [
			format!`{"type":"%s","operation":"enqueue","content":"second prompt"}`(queueType),
			format!`{"type":"%s","operation":"dequeue"}`(queueType),
			secondPrompt,
			format!`{"type":"%s","operation":"enqueue","content":"still queued"}`(queueType),
		];
		write(jsonlPath, rows.join("\n") ~ "\n");
		td.history.reset(Watermark.atBytes(getSize(jsonlPath)));
		pipeline.ensureHistoryLoaded(tid);

		bool confirmed;
		foreach (ref entry; td.history)
		{
			auto event = extractEventFromEnvelope(cast(string) entry.toGC());
			confirmed |= event.canFind(`"type":"user_message/consumed"`)
				&& event.canFind(`"uuid":"enqueue-1"`)
				&& event.canFind(`"native_uuid":"prompt-2"`)
				&& event.canFind(`"turn_start"`);
		}
		if (!confirmed)
			replayMismatches ~= queueType ~ ": missing turn-start confirmation tied to the canonical echo";

		auto access = HistoryAccess(agent, profile, td.agentSessionId, jsonlPath);
		HistoryBoundary pending;
		bool opensConversation;
		if (!pipeline.resolveFreshPersistedBoundary(tid, access, "enqueue-4", pending, opensConversation)
			|| pending.kind != HistoryBoundaryKind.provisional_user || opensConversation)
			replayMismatches ~= queueType ~ ": pending enqueue must resolve after the canonical echo";
		if (!agent.forkIdMatchesLine(rows[3], 4, "enqueue-4"))
			replayMismatches ~= queueType ~ ": provisional anchor must match its physical enqueue row";
	}
	assert(replayMismatches.length == 0, replayMismatches.join("\n"));
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

unittest
{
	import cydo.agent.contract : PersistedHistoryBoundaryKind;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto agent = new ClaudeCodeAgent();
	auto boundaries = agent.extractPersistedHistoryBoundaries(
		`{"type":"queue-operation","operation":"enqueue"}` ~ "\n" ~
		`{"type":"user","uuid":"user-checkpoint","message":{"role":"user","content":"canonical prompt"}}` ~ "\n" ~
		`{"type":"assistant","uuid":"agent-checkpoint","message":{"id":"agent-msg"}}`);

	assert(boundaries.length == 3);
	assert(boundaries[0].anchor == "enqueue-1");
	assert(boundaries[0].kind == PersistedHistoryBoundaryKind.provisional_user);
	assert(boundaries[0].checkpointUuid.length == 0);
	assert(boundaries[1].anchor == "user-checkpoint");
	assert(boundaries[1].kind == PersistedHistoryBoundaryKind.user);
	assert(boundaries[1].checkpointUuid.length == 0);
	assert(boundaries[2].anchor == "agent-msg");
	assert(boundaries[2].kind == PersistedHistoryBoundaryKind.agent_turn);
	assert(boundaries[2].checkpointUuid.length == 0);
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto agent = new ClaudeCodeAgent();
	auto boundaries = agent.extractPersistedHistoryBoundaries(
		`{"type":"user","uuid":"string","message":{"role":"user","content":"prompt"}}` ~ "\n" ~
		`{"type":"user","uuid":"tool-only","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":"result"}]}}` ~ "\n" ~
		`{"type":"user","uuid":"text","message":{"role":"user","content":[{"type":"text","text":"prompt"}]}}` ~ "\n" ~
		`{"type":"user","uuid":"image","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}}` ~ "\n" ~
		`{"type":"user","uuid":"mixed","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":"result"},{"type":"text","text":"prompt"}]}}`);

	assert(boundaries.length == 4);
	assert(boundaries[0].anchor == "string");
	assert(boundaries[1].anchor == "text");
	assert(boundaries[2].anchor == "image");
	assert(boundaries[3].anchor == "mixed");
	foreach (boundary; boundaries)
		assert(boundary.kind == PersistedHistoryBoundaryKind.user);
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
		// Claude ≥2.1.250 shapes, after a row naming the CLI version (10):
		// absorbed mid-turn: enqueue(11), remove(14) with its reason; and
		// withdrawn by CyDo: enqueue(12), anonymous dequeue(13) with no echo
		`{"type":"assistant","version":"2.1.319","uuid":"asst-2","message":{"id":"asst-2","content":[{"type":"text","text":"later"}],"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}`,
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:07Z","sessionId":"S","content":"absorbed steer"}`,
		`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-02T06:00:08Z","sessionId":"S","content":"withdrawn steer"}`,
		`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-08-02T06:00:09Z","sessionId":"S"}`,
		`{"type":"queue-operation","operation":"remove","timestamp":"2026-08-02T06:00:10Z","sessionId":"S","content":"absorbed steer","reason":"absorbed_mid_turn","commandUuid":"c-absorbed"}`,
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

	// Echo-less queue messages retain their provisional enqueue boundaries.
	foreach (needle; ["steer text", "withdrawn text", "still queued", "absorbed steer"])
	{
		bool found;
		foreach (s; events)
			if (s.canFind(`"user_message"`) && s.canFind(needle)
				&& s.canFind(`"pending":true`) && s.canFind(`"uuid":"enqueue-`)
				&& s.canFind(`"history_boundary":{"anchor":"enqueue-`)
				&& s.canFind(`"kind":"provisional_user"`))
				found = true;
		assert(found, "missing provisional queue user boundary: " ~ needle);
	}

	// The canonical echo message is re-emitted after its confirmation, under
	// its native identity, and the confirmation carries that identity so the
	// UI can drop the provisional bubble and anchors resolve either name.
	bool sawCanonicalEcho, sawCanonicalBoundary, sawNative;
	foreach (s; events)
	{
		if (s.canFind(`"user_message"`) && s.canFind(`"uuid":"echo-1"`))
			sawCanonicalEcho = true;
		if (s.canFind(`"uuid":"echo-1"`)
			&& s.canFind(`"history_boundary":{"anchor":"echo-1","kind":"user"`))
			sawCanonicalBoundary = true;
		if (s.canFind(`"user_message/consumed"`) && s.canFind(`"native_uuid":"echo-1"`))
			sawNative = true;
	}
	assert(sawCanonicalEcho, "canonical echo message missing");
	assert(sawCanonicalBoundary, "canonical echo must replace the provisional boundary");
	assert(sawNative, "confirmation must carry the echo native uuid");

	// Confirmations: turn_start for the opener, steering for the steer,
	// removed for the withdrawn message, and none for the still-queued one.
	bool sawTurnStart, sawSteering, sawRemoved, sawAbsorbed, sawCancelled;
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
		if (s.canFind(`"enqueue-11"`) && s.canFind(`"steering"`))
			sawAbsorbed = true;
		if (s.canFind(`"enqueue-12"`) && s.canFind(`"cancelled"`))
			sawCancelled = true;
		assert(!s.canFind(`"enqueue-9"`), "still-queued enqueue must have no confirmation");
	}
	assert(sawTurnStart, "turn_start confirmation missing");
	assert(sawSteering, "steering confirmation missing");
	assert(sawRemoved, "removed confirmation missing");
	assert(sawAbsorbed, "absorbed steering must confirm as steering, not removed");
	assert(sawCancelled, "withdrawn message must confirm as cancelled");

	// A withdrawn message has left the conversation: no undo boundary.
	foreach (s; events)
		if (s.canFind(`"user_message"`) && s.canFind("withdrawn steer"))
			assert(!s.canFind(`"history_boundary"`),
				"withdrawn message must not keep a provisional boundary");
}

version (unittest) private final class DriverHistoryPipelineFixture
{
	enum tid = 1;
	enum sessionId = "driver-session";
	TaskData task;
	HistoryEventPipeline pipeline;
	TaskHistoryResolution resolution;
	Promise!DriverHistory[] reads;
	UnavailableHistory[] reports;
	string[] sent;

	this()
	{
		import cydo.runtime.launch.types : NativeHistoryProfile;
		import cydo.workflow.history.native_history : DriverHistoryTestAgent;

		auto agent = new DriverHistoryTestAgent();
		auto profile = NativeHistoryProfile(agent.driver, "/unused-profile");
		auto access = HistoryAccess.driverServed(agent, profile, sessionId);
		task = TaskData(tid, "local", "/tmp");
		task.agentName = "driver";
		task.agentSessionId = sessionId;
		task.history.reset(Watermark.driverServed());

		HistoryEventPipelineHost host;
		host.getTask = (int t) => t == tid ? &task : null;
		resolution = TaskHistoryResolution.access(access);
		host.resolveTaskHistory = (int t) => resolution;
		host.sendToSubscribed = (int t, Data data) { sent ~= cast(string) data.toGC(); };
		host.loadDriverHistory = (int t, HistoryAccess resolved) {
			assert(t == tid && resolved.sessionId == sessionId);
			auto pending = new Promise!DriverHistory;
			reads ~= pending;
			return pending;
		};
		host.injectAgentNameIntoSessionInit = (string translated, string agentName) => translated;
		host.broadcastHistoryOperations = (int t) {};
		host.reportUnavailableHistory = (int t, const ref TaskHistoryResolution resolution) {
			assert(t == tid);
			reports ~= resolution.requireUnavailable();
		};
		pipeline = new HistoryEventPipeline(host);
	}
}

version (unittest) private void drainHistoryNextTicks()
{
	// These fixtures create no sockets or timers. Dispatch the ae promise
	// callbacks without running other unit tests' scheduled I/O.
	for (;;)
	{
		auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
		if (handlers.length == 0)
			return;
		mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
		foreach (handler; handlers)
			handler();
	}
}

unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	size_t[] called;
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		assert(fixture.task.history.isLoaded);
		assert(fixture.task.history.rawAt(0) == "driver raw");
		called ~= 1;
	});
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		assert(fixture.task.history.isLoaded);
		called ~= 2;
	});
	assert(called.length == 0 && fixture.reads.length == 1);
	fixture.reads[0].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "driver raw")], 2));
	assert(called.length == 0, "driver callbacks run on the next event-loop tick");
	drainHistoryNextTicks();
	assert(called == [1, 2]);
	assert(fixture.reads.length == 1 && fixture.reports.length == 0);

	fixture.pipeline.whenHistoryLoaded(fixture.tid, () { called ~= 3; });
	assert(called == [1, 2, 3]);
	assert(fixture.reads.length == 1);
}

unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	enum detail = "driver read failed";
	size_t[] called;
	void observeFailure(size_t waiter)
	{
		assert(fixture.task.history.isLoaded);
		assert(fixture.reports.length == 1);
		auto unavailable = fixture.reports[0];
		assert(unavailable.detail == detail);
		assert(unavailable.sessionId == fixture.sessionId);
		called ~= waiter;
	}
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () => observeFailure(1));
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () => observeFailure(2));
	assert(called.length == 0 && fixture.reports.length == 0 && fixture.reads.length == 1);
	fixture.reads[0].reject(new Exception(detail));
	drainHistoryNextTicks();
	assert(called == [1, 2]);
	assert(fixture.reports.length == 1);
}

unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	size_t[] called;
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () { called ~= 1; });
	assert(fixture.reads.length == 1);
	fixture.task.history.reset(Watermark.driverServed());
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () { called ~= 2; });

	fixture.reads[0].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "stale")], 1));
	drainHistoryNextTicks();
	assert(fixture.reads.length == 2 && called.length == 0);
	assert(!fixture.task.history.isLoaded);
	fixture.reads[1].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "fresh")], 2));
	drainHistoryNextTicks();
	// The first continuation joined the second read when the stale one settled.
	assert(called == [2, 1]);
	assert(fixture.task.history.length == 1);
	assert(fixture.task.history.rawAt(0) == "fresh");
	assert(fixture.task.history.historyMode == 2);
}

// A continuation that resets the store leaves the next one waiting for the
// next load.
unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	size_t[] called;
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		called ~= 1;
		fixture.task.history.reset(Watermark.driverServed());
	});
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		assert(fixture.task.history.isLoaded);
		assert(fixture.task.history.rawAt(0) == "fresh");
		called ~= 2;
	});
	fixture.reads[0].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "first")], 1));
	drainHistoryNextTicks();
	assert(called == [1] && fixture.reads.length == 2);
	fixture.reads[1].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "fresh")], 1));
	drainHistoryNextTicks();
	assert(called == [1, 2] && fixture.reads.length == 2);
}

// A store reset to the file-backed shape during a driver read loads inline,
// for both forms; the stale read's continuation is served when it settles.
unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	size_t[] called;
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () { called ~= 1; });
	fixture.task.history.reset(Watermark.atBytes(0));
	fixture.resolution = TaskHistoryResolution.noSession();
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		assert(fixture.task.history.isLoaded);
		called ~= 2;
	});
	assert(called == [2]);

	fixture.task.history.reset(Watermark.atBytes(0));
	fixture.pipeline.ensureHistoryLoaded(fixture.tid);
	assert(fixture.task.history.isLoaded);

	fixture.reads[0].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "stale")], 1));
	drainHistoryNextTicks();
	assert(called == [2, 1]);
	assert(fixture.reads.length == 1 && fixture.task.history.length == 0);
}

// An exception escaping a continuation leaves through the event loop, after
// the other continuations have run.
unittest
{
	import std.exception : collectExceptionMsg;

	auto fixture = new DriverHistoryPipelineFixture;
	size_t[] called;
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () {
		throw new Exception("consumer error");
	});
	fixture.pipeline.whenHistoryLoaded(fixture.tid, () { called ~= 2; });
	fixture.reads[0].fulfill(DriverHistory.init);
	assert(collectExceptionMsg(drainHistoryNextTicks()) == "consumer error");
	assert(called == [2]);
}

// A message accepted while history is being read keeps its place among the
// live events, and goes with them when the store is reset.
unittest
{
	auto fixture = new DriverHistoryPipelineFixture;
	fixture.pipeline.appendUnconfirmedUserMessage(fixture.tid,
		[ContentBlock("text", "provisional")], null, null, "nonce");
	assert(fixture.reads.length == 1 && fixture.sent.length == 0);
	assert(fixture.task.pendingSteeringTexts == ["provisional"]);
	fixture.task.history.appendLive(Data("later agent event".representation), "agent raw");
	fixture.reads[0].fulfill(DriverHistory(
		[TranslatedEvent(`{"type":"turn/stop"}`, "driver raw")], 1));
	drainHistoryNextTicks();
	assert(fixture.task.history.length == 3);
	assert(fixture.task.history.rawAt(0) == "driver raw");
	assert((cast(string) fixture.task.history[1].toGC()).canFind("provisional"));
	assert(fixture.task.history.rawAt(2) == "agent raw");

	fixture = new DriverHistoryPipelineFixture;
	fixture.pipeline.appendUnconfirmedUserMessage(fixture.tid,
		[ContentBlock("text", "provisional")], null, null, "nonce");
	fixture.task.history.reset(Watermark.driverServed());
	fixture.reads[0].fulfill(DriverHistory.init);
	drainHistoryNextTicks();
	assert(fixture.reads.length == 2);
	fixture.reads[1].fulfill(DriverHistory.init);
	drainHistoryNextTicks();
	assert(fixture.task.history.length == 0 && fixture.sent.length == 0);
}

// The end of a turn, which an agent reports with the turn/result, goes on the
// turn's last turn/stop: at once in a loaded history, where clients are told,
// and in the events waiting for a load.
unittest
{
	import cydo.foundation.testing : drainNextTicks;

	enum stop = `{"type":"turn/stop"}`;
	TranslatedEvent result(string turnId)
	{
		auto event = TranslatedEvent(`{"type":"turn/result","subtype":"success"}`, null);
		event.turnBoundary = HistoryBoundary("through:" ~ turnId, HistoryBoundaryKind.agent_turn);
		return event;
	}
	string[] boundaries(ref TaskData task)
	{
		string[] found;
		foreach (ref entry; task.history)
			found ~= (cast(string) entry.toGC()).canFind("history_boundary")
				? (cast(string) entry.toGC()).canFind("through:t1") ? "t1" : "t2" : "-";
		return found;
	}

	auto fixture = new DriverHistoryPipelineFixture;
	fixture.pipeline.host_.normalizeKnownSystemMessageMeta = (string translated, int) => translated;
	fixture.pipeline.host_.updateClaudeUsageFromEvent = (int, string) => false;
	fixture.pipeline.host_.planBroadcast = (int, TranslatedEvent event) {
		HistoryBroadcastPlan plan;
		plan.currentEvent = event;
		return plan;
	};
	auto pipeline = fixture.pipeline;
	enum tid = DriverHistoryPipelineFixture.tid;

	// Before the load: the live events are buffered.
	foreach (event; [TranslatedEvent(stop, null), TranslatedEvent(stop, null), result("t1"),
		// a turn that stopped nowhere has no end to cut at
		result("t2")])
		pipeline.broadcastTask(tid, event);
	assert(fixture.sent.length == 0);
	pipeline.whenHistoryLoaded(tid, () {});
	fixture.reads[0].fulfill(DriverHistory.init);
	drainNextTicks();
	assert(boundaries(fixture.task) == ["-", "t1", "-", "-"]);

	// In a loaded history the boundary is published as a replacement.
	fixture.sent = null;
	pipeline.broadcastTask(tid, TranslatedEvent(stop, null));
	pipeline.broadcastTask(tid, TranslatedEvent(`{"type":"item/started","item_id":"i"}`, null));
	pipeline.broadcastTask(tid, result("t2"));
	assert(boundaries(fixture.task) == ["-", "t1", "-", "-", "t2", "-", "-"]);
	assert(fixture.sent.length == 4);
	assert(fixture.sent[3].canFind("task_history_boundary_replaced")
		&& fixture.sent[3].canFind("through:t2") && fixture.sent[3].canFind(`"seq":4`));
	pipeline.broadcastTask(tid, result("t2"));
	assert(boundaries(fixture.task) == ["-", "t1", "-", "-", "t2", "-", "-", "-"]);
}
