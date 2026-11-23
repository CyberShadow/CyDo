module cydo.workflow.history.jsonl_tracker;

import std.stdio : File;
import std.string : representation;
import std.typecons : Nullable;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.sys.inotify : INotify;
import ae.sys.timing : setTimeout, TimerTask;

import cydo.agent.contract : Agent, PersistedHistoryBoundary,
	PersistedHistoryBoundaryKind;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;
import cydo.foundation.platform.inotify : RefCountedINotify;
import cydo.domain.tasks.model : TaskData, Watermark,
	extractEventFromEnvelope;
import cydo.workflow.history.jsonl_store : completeJsonlPrefix;
import cydo.workflow.history.native_history : LiveHistoryContext,
	LiveHistoryWatchResolution, LiveHistoryWatchResolutionKind, LiveHistoryWatchTarget,
	TaskHistoryResolution,
	TaskHistoryResolutionKind;

struct JsonlTracker
{
	private static bool boundaryHasCheckpoint(AgentDriver driver,
		PersistedHistoryBoundaryKind kind)
	{
		return driver == AgentDriver.claude && kind == PersistedHistoryBoundaryKind.user;
	}
	struct LiveBoundaryCandidate {
		size_t seq;
		PersistedHistoryBoundaryKind kind;
		string identity;
		ulong generation;
		bool requiresExactIdentity;
		int apiBlockCount;
	}
	struct PersistedBoundaryCandidate {
		PersistedHistoryBoundary boundary;
		size_t sourceLine;
		bool requiresExactIdentity;
		ulong generation;
		int lastBlockIndex = -1;
		bool joined;
		bool unindexed;
	}
	struct BoundaryReconcileState {
		size_t readPos;
		size_t lineCount;
		LiveBoundaryCandidate[][PersistedHistoryBoundaryKind] liveByKind;
		PersistedBoundaryCandidate[][PersistedHistoryBoundaryKind] persistedByKind;
		bool[string] queueCanonicalIdentities;
		bool[string] absorbedLocalIdentities;
		string lastAgentTurnAnchor;
		bool[string] seenAgentTurnAnchors;
		ubyte[] partialLine;
	}
	TaskData* delegate(int tid) getTask;
	ulong delegate(int tid) historyGeneration;
	TaskHistoryResolution delegate(int tid) resolveTaskHistory;
	LiveHistoryWatchResolution delegate(int tid) resolveLiveHistoryWatch;
	void delegate(int tid, string msg) sendToSubscribed;
	void delegate(int tid, size_t seq, HistoryBoundary boundary, bool publish, ulong generation) onBoundaryResolved;
	void delegate(int tid) onLineageInvalidated;
	/// Called for every complete line the tail reads, with its absolute
	/// (1-based) line number. Claude ≥2.1.2xx records queue operations only in
	/// the session file, so this feed is where the live queue lifecycle of
	/// user messages is observed.
	void delegate(int tid, string line, int lineNum) onJsonlLine;

	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private string[int] jsonlPaths;
	private LiveHistoryContext[int] liveContexts;
	private int[int] jsonlLineCount;
	private BoundaryReconcileState[int] boundaryState;
	private ulong[int] lineageGeneration;
	private TimerTask[int] jsonlRetryTimers;
	// Snapshot of JSONL content taken just before broadcast, used for undo
	// when the agent compacts the file.
	private string[int] undoJsonl;

	private LiveHistoryContext requireLiveContext(int tid)
	{
		auto context = tid in liveContexts;
		assert(context !is null,
			"JSONL history operation requires an attached live history context");
		return *context;
	}

	private void attachLiveContext(int tid, LiveHistoryContext context)
	{
		liveContexts[tid] = context;
	}

	private void scheduleWatchRetry(int tid)
	{
		import core.time : seconds;

		if (tid in jsonlRetryTimers)
			return;
		auto generation = lineageGeneration.get(tid, 0);
		jsonlRetryTimers[tid] = setTimeout({
			jsonlRetryTimers.remove(tid);
			if (lineageGeneration.get(tid, 0) == generation)
				startJsonlWatch(tid);
		}, 2.seconds);
	}

	void noteLiveBoundaryCandidate(int tid, size_t seq, string event,
		string raw = null, int sourceLine = 0,
		bool registeredLocal = false)
	{
		import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
		@JSONPartial static struct Probe { string type; @JSONOptional string item_type;
			@JSONOptional string uuid; @JSONOptional string item_id;
			@JSONOptional bool is_meta; @JSONOptional bool is_synthetic; @JSONOptional bool pending; @JSONOptional bool is_sidechain;
			@JSONOptional string parent_tool_use_id;
			@JSONOptional int api_block_count = -1; }
		auto p = jsonParse!Probe(event);
		PersistedHistoryBoundaryKind kind;
		if (p.type == "item/started" && p.item_type == "user_message"
			&& !p.is_synthetic && !p.pending && !p.is_sidechain
			&& p.parent_tool_use_id.length == 0)
			kind = PersistedHistoryBoundaryKind.user;
		else if (p.type == "turn/stop" && !p.is_sidechain && p.parent_tool_use_id.length == 0)
			kind = PersistedHistoryBoundaryKind.agent_turn;
		else return;
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		if (kind == PersistedHistoryBoundaryKind.user && p.is_meta
			&& requireLiveContext(tid).agent.driver == AgentDriver.claude)
			return;
		auto identity = p.uuid.length > 0 ? p.uuid : p.item_id;
		if (kind == PersistedHistoryBoundaryKind.agent_turn
			&& requireLiveContext(tid).agent.driver == AgentDriver.claude)
		{
			assert(identity.length > 0, "Claude live turn/stop requires the API message id");
			assert(p.api_block_count >= 0, "Claude live turn/stop requires the API block count");
			if (p.api_block_count == 0)
				return;
		}
		if (kind == PersistedHistoryBoundaryKind.user
			&& identity in boundaryState[tid].absorbedLocalIdentities)
			return;
		boundaryState[tid].liveByKind[kind] ~= LiveBoundaryCandidate(seq, kind,
			identity, historyGeneration(tid), registeredLocal, p.api_block_count);
		drainLiveBoundaries(tid, kind);
	}

	void noteAbsorbedLocalUser(int tid, string uuid, ulong generation)
	{
		assert(uuid.length > 0, "absorbed Claude user requires a native identity");
		assert(historyGeneration(tid) == generation,
			"absorbed Claude user belongs to a stale history lineage");
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		auto state = &boundaryState[tid];
		assert(uuid !in state.queueCanonicalIdentities,
			"Claude user cannot be both canonical and absorbed");
		state.absorbedLocalIdentities[uuid] = true;
		if (auto lives = PersistedHistoryBoundaryKind.user in state.liveByKind)
		{
			LiveBoundaryCandidate[] remaining;
			foreach (live; *lives)
				if (live.identity != uuid)
					remaining ~= live;
			*lives = remaining;
		}
	}

	void noteQueueCanonicalIdentity(int tid, string canonicalIdentity,
		ulong generation)
	{
		assert(canonicalIdentity.length > 0,
			"canonical Claude queue echo requires a native identity");
		assert(historyGeneration(tid) == generation,
			"canonical Claude user belongs to a stale history lineage");
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		auto state = &boundaryState[tid];
		assert(canonicalIdentity !in state.absorbedLocalIdentities,
			"Claude user cannot be both canonical and absorbed");
		state.queueCanonicalIdentities[canonicalIdentity] = true;
		if (auto persisted = PersistedHistoryBoundaryKind.user in state.persistedByKind)
			foreach (ref candidate; *persisted)
				if (candidate.boundary.anchor == canonicalIdentity)
					candidate.requiresExactIdentity = true;
		drainLiveBoundaries(tid, PersistedHistoryBoundaryKind.user);
	}

	/// Rule C (task 42281): only the final indexed member can publish a live
	/// Claude stop. The stream and file order then make earlier candidates
	/// impossible to match, so retire them together with the published pair.
	private void drainClaudeMessageBoundaries(int tid)
	{
		auto state = tid in boundaryState;
		if (state is null)
			return;
		enum kind = PersistedHistoryBoundaryKind.agent_turn;
		auto lives = kind in state.liveByKind;
		auto persisted = kind in state.persistedByKind;
		auto current = historyGeneration(tid);

		void dropStale(Candidate)(ref Candidate[] candidates)
		{
			foreach (candidate; candidates)
				assert(candidate.generation <= current,
					"history boundary candidate belongs to a future generation");
			while (candidates.length > 0 && candidates[0].generation < current)
				candidates = candidates[1 .. $];
		}

		if (lives !is null)
			dropStale(*lives);
		if (persisted !is null)
			dropStale(*persisted);
		if (lives is null || persisted is null)
			return;

		while ((*lives).length > 0 && (*persisted).length > 0)
		{
			bool published;
			foreach (j, live; *lives)
			{
				foreach (i, candidate; *persisted)
				{
					if (candidate.boundary.anchor != live.identity)
						continue;
					assert(!candidate.unindexed, "Claude assistant record requires apiBlockIndex");
					// The 2.1.330 joined-text path strips apiBlockIndex.
					// The joined-mixed probe has an indexed tool in the same ID.
					if (candidate.joined)
						break;
					assert(candidate.lastBlockIndex < live.apiBlockCount,
						"Claude persisted block index exceeds the live message");
					if (candidate.lastBlockIndex != live.apiBlockCount - 1)
						break;
					*lives = (*lives)[j + 1 .. $];
					*persisted = (*persisted)[i + 1 .. $];
					resolveBoundary(tid, live.seq, candidate.boundary, true, current);
					published = true;
					break;
				}
				if (published)
					break;
			}
			if (!published)
				return;
		}
	}

	private static void absorbClaudeMember(ref PersistedBoundaryCandidate candidate,
		int apiBlockIndex, bool joined)
	{
		if (joined)
			candidate.joined = true;
		else if (apiBlockIndex < 0)
			candidate.unindexed = true;
		else
		{
			assert(apiBlockIndex > candidate.lastBlockIndex,
				"Claude persisted block indexes must strictly increase");
			candidate.lastBlockIndex = apiBlockIndex;
		}
	}

	private void drainLiveBoundaries(int tid, PersistedHistoryBoundaryKind kind)
	{
		import std.algorithm : startsWith;

		if (kind == PersistedHistoryBoundaryKind.agent_turn
			&& requireLiveContext(tid).agent.driver == AgentDriver.claude)
		{
			drainClaudeMessageBoundaries(tid);
			return;
		}
		while (true)
		{
			auto state = tid in boundaryState;
			if (state is null) return;
			auto lives = kind in (*state).liveByKind;
			auto persistedCandidates = kind in (*state).persistedByKind;
			if (lives is null || persistedCandidates is null || lives.length == 0
				|| persistedCandidates.length == 0) return;
			auto liveCandidates = (*lives).dup;
			auto candidates = (*persistedCandidates).dup;
			auto current = historyGeneration(tid);
			foreach (live; liveCandidates)
				assert(live.generation <= current,
					"history boundary candidate belongs to a future generation");
			ptrdiff_t liveIndex = -1;
			ptrdiff_t persistedIndex = -1;
			foreach (i, persisted; candidates)
			{
				assert(persisted.generation <= current,
					"history boundary candidate belongs to a future generation");
				if (persisted.generation < current)
					continue;
				foreach (j, live; liveCandidates)
				{
					if (live.generation == current && live.identity.length > 0
						&& persisted.boundary.anchor == live.identity)
					{
						liveIndex = cast(ptrdiff_t) j;
						persistedIndex = cast(ptrdiff_t) i;
						break;
					}
				}
				if (persistedIndex >= 0)
					break;
			}
			if (persistedIndex < 0)
			{
				if (liveCandidates[0].generation < current)
				{
					(*state).liveByKind[kind] = liveCandidates[1 .. $];
					continue;
				}
				foreach (j, live; liveCandidates)
				{
					if (live.generation != current || live.requiresExactIdentity)
						continue;
					foreach (i, persisted; candidates)
					{
						if (persisted.generation < current || persisted.requiresExactIdentity)
							continue;
						auto nativeRecord = !persisted.boundary.anchor.startsWith("enqueue-");
						if ((nativeRecord && persisted.boundary.anchor.startsWith("line:"))
							|| (nativeRecord && requireLiveContext(tid).agent.driver == AgentDriver.claude
								&& kind == PersistedHistoryBoundaryKind.user))
						{
							liveIndex = cast(ptrdiff_t) j;
							persistedIndex = cast(ptrdiff_t) i;
							break;
						}
					}
					if (persistedIndex >= 0)
						break;
				}
			}
			if (persistedIndex < 0) return;
			auto live = liveCandidates[cast(size_t) liveIndex];
			auto persisted = (*persistedCandidates)[cast(size_t) persistedIndex];
			LiveBoundaryCandidate[] remainingLives;
			foreach (i, candidate; liveCandidates)
				if (i != liveIndex)
					remainingLives ~= candidate;
			(*state).liveByKind[kind] = remainingLives;
			PersistedBoundaryCandidate[] remaining;
			foreach (i, candidate; candidates)
				if (i != persistedIndex)
					remaining ~= candidate;
			(*state).persistedByKind[kind] = remaining;
			resolveBoundary(tid, live.seq, persisted.boundary, true, live.generation);
		}
	}

	void invalidateLineage(int tid)
	{
		lineageGeneration[tid]++;
		stopJsonlWatch(tid);
	}

	/// `knownResolution`, when present, is the resolution ensureHistoryLoadedForExit
	/// already resolved immediately before this call while loading the task's
	/// history for the first time; it is reused here instead of re-resolving.
	/// This is exclusively an exit-path call (task_runner.d's onExit is its
	/// only production caller): the post-exit config-only reset that follows
	/// it is the sole owner of the unavailable-history diagnostic, so neither
	/// this branch nor the fresh self-resolve branch below ever reports.
	void finalReconcileJsonlIfPresent(int tid,
		Nullable!TaskHistoryResolution knownResolution = Nullable!TaskHistoryResolution.init)
	{
		auto td = getTask(tid);
		assert(td !is null && td.history.isLoaded,
			"final JSONL reconciliation requires a loaded current task history");
		TaskHistoryResolution resolution;
		if (knownResolution.isNull)
		{
			resolution = resolveTaskHistory(tid);
			final switch (resolution.kind)
			{
			case TaskHistoryResolutionKind.noSession:
			case TaskHistoryResolutionKind.orphanAgent:
			case TaskHistoryResolutionKind.unavailable:
				return;
			case TaskHistoryResolutionKind.access:
				break;
			}
		}
		else
		{
			resolution = knownResolution.get;
			if (resolution.kind != TaskHistoryResolutionKind.access)
				return;
		}
		auto access = resolution.requireAccess();
		auto path = tid in jsonlPaths;
		if (path is null)
		{
			attachAndCatchUp(tid, access.path, false);
			return;
		}
		assert(*path == access.path,
			"Final JSONL reconciliation path does not match resolved history access");
		attachAndCatchUp(tid, *path, false);
	}

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	void startJsonlWatch(int tid)
	{
		import std.file : exists;
		import std.path : baseName, dirName;
		import std.logger : tracef;

		if (tid in jsonlWatches)
			return;
		auto resolution = resolveLiveHistoryWatch(tid);
		final switch (resolution.kind)
		{
		case LiveHistoryWatchResolutionKind.noLiveBinding:
			return;
		case LiveHistoryWatchResolutionKind.awaitingPath:
			attachLiveContext(tid, resolution.requireContext());
			scheduleWatchRetry(tid);
			return;
		case LiveHistoryWatchResolutionKind.target:
			break;
		}
		auto target = resolution.requireTarget();
		attachLiveContext(tid, target.context);
		auto jsonlPath = target.path;
		tracef("[jsonl] startJsonlWatch tid=%d sessionId=%s jsonlPath=%s exists=%s",
			tid, target.context.sessionId, jsonlPath, exists(jsonlPath));

		if (auto t = tid in jsonlRetryTimers)
		{
			(*t).cancel();
			jsonlRetryTimers.remove(tid);
		}

		if (exists(jsonlPath))
		{
			watchJsonlFile(tid, target);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation.
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			if (!exists(dirPath))
			{
				scheduleWatchRetry(tid);
				return;
			}
			auto generation = lineageGeneration.get(tid, 0);
			jsonlWatches[tid] = rcINotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (lineageGeneration.get(tid, 0) == generation && name == fileName)
					{
						// File appeared — switch to file watch
						if (auto h = tid in jsonlWatches)
						{
							rcINotify.remove(*h);
							jsonlWatches.remove(tid);
						}
						watchJsonlFile(tid, target);
					}
				}
			);
		}
	}

	/// Establish the lineage cursor, register the watch, then consume every
	/// complete line visible after registration.  Watching is an optimization
	/// for later growth; this catch-up is the correctness boundary.
	private void attachAndCatchUp(int tid, string jsonlPath, bool installWatch = true)
	{
		jsonlPaths[tid] = jsonlPath;
		if (tid !in jsonlReadPos)
		{
			import std.file : getSize, read;
			import std.string : lineSplitter;

			auto context = tid in liveContexts;
			auto watermark = getTask(tid).history.watermark;
			// The history store loads complete lines within a snapshot's byte
			// limit. Leave an unfinished record for the tail to read in full.
			auto pos = watermark.maxBytes;
			if (context is null || (context.resuming && !watermark.isDeferred))
				pos = getSize(jsonlPath);
			string prefix;
			if (pos > 0)
				prefix = completeJsonlPrefix(cast(string) read(jsonlPath, cast(size_t) pos));
			int lines = 0;
			foreach (_; prefix.lineSplitter)
				lines++;
			jsonlReadPos[tid] = prefix.length;
			jsonlLineCount[tid] = lines;
		}
		if (installWatch && tid !in jsonlWatches)
		{
			auto generation = lineageGeneration.get(tid, 0);
			jsonlWatches[tid] = rcINotify.add(jsonlPath, INotify.Mask.modify,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (lineageGeneration.get(tid, 0) == generation)
						processNewJsonlContent(tid, jsonlPath);
				}
			);
		}
		processNewJsonlContent(tid, jsonlPath);
	}

	void watchJsonlFile(int tid, LiveHistoryWatchTarget watchedTarget)
	{
		attachAndCatchUp(tid, watchedTarget.path);
	}

	/// Read new content from the JSONL file and reconcile persisted boundaries.
	void processNewJsonlContent(int tid, string jsonlPath)
	{
		import std.file : exists, getSize;
		import std.logger : tracef;

		if (jsonlPath.length == 0 || !exists(jsonlPath))
		{
			tracef("[jsonl] processNewJsonlContent tid=%d: path missing/nonexistent: %s", tid, jsonlPath);
			return;
		}
		auto fileSize = getSize(jsonlPath);
		auto lastPos = jsonlReadPos.get(tid, 0);
		if (fileSize < lastPos)
		{
			tracef("[jsonl] processNewJsonlContent tid=%d: file shrank (was %d, now %d)", tid, lastPos, fileSize);
			onLineageInvalidated(tid);
			return;
		}
		if (fileSize <= lastPos)
			return;

		auto f = File(jsonlPath, "r");
		f.seek(lastPos);
		char[] buf;
		buf.length = cast(size_t)(fileSize - lastPos);
		auto got = f.rawRead(buf);
		auto newContent = cast(string) got;
		auto completeContent = completeJsonlPrefix(newContent);
		auto completeBytes = completeContent.length;
		if (completeBytes == 0)
			return;
		jsonlReadPos[tid] = lastPos + completeContent.length;
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		boundaryState[tid].partialLine = cast(ubyte[]) newContent[completeBytes .. $].dup;

		auto lineOffset = jsonlLineCount.get(tid, 0);
		auto context = requireLiveContext(tid);
		import cydo.agent.drivers.claude : ClaudeCodeAgent;
		auto claude = cast(ClaudeCodeAgent) context.agent;

		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; completeContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		if (onJsonlLine !is null)
		{
			int n = lineOffset;
			foreach (line; completeContent.lineSplitter)
			{
				n++;
				if (line.length > 0)
					onJsonlLine(tid, line, n);
			}
		}
		void processBoundary(PersistedHistoryBoundary boundary, int apiBlockIndex = -1, bool joinedApiReply = false)
		{
			if (claude !is null && boundary.kind == PersistedHistoryBoundaryKind.provisional_user)
				return;
			if (tid !in boundaryState)
				boundaryState[tid] = BoundaryReconcileState.init;
			auto state = &boundaryState[tid];
			if (claude !is null && boundary.kind == PersistedHistoryBoundaryKind.agent_turn)
			{
				if (boundary.anchor == state.lastAgentTurnAnchor)
				{
					foreach (ref candidate; state.persistedByKind[boundary.kind])
					{
						if (candidate.boundary.anchor != boundary.anchor
							|| candidate.generation != historyGeneration(tid))
							continue;
						absorbClaudeMember(candidate, apiBlockIndex, joinedApiReply);
						drainLiveBoundaries(tid, boundary.kind);
						return;
					}
					assert(false, "Claude assistant record arrived after boundary publication");
					return;
				}
				assert(boundary.anchor !in state.seenAgentTurnAnchors,
					"Claude API message records must be contiguous among boundaries");
				state.seenAgentTurnAnchors[boundary.anchor] = true;
				state.lastAgentTurnAnchor = boundary.anchor;
			}
			auto candidate = PersistedBoundaryCandidate(boundary, cast(size_t) boundary.sourceLine,
				(boundary.anchor in state.queueCanonicalIdentities) !is null,
				historyGeneration(tid));
			if (claude !is null && boundary.kind == PersistedHistoryBoundaryKind.agent_turn)
				absorbClaudeMember(candidate, apiBlockIndex, joinedApiReply);
			state.persistedByKind[boundary.kind] ~= candidate;
			drainLiveBoundaries(tid, boundary.kind);
		}

		if (claude !is null)
		{
			claude.visitPersistedHistoryRows(completeContent, lineOffset, &processBoundary, () {
				// A turn.step rewrite can drop a block. Leave an incomplete
				// message unpublished when its persisted span closes.
				boundaryState[tid].lastAgentTurnAnchor = null;
			});
		}
		else
			foreach (boundary; context.agent.extractPersistedHistoryBoundaries(completeContent, lineOffset))
				processBoundary(boundary);
	}

	/// Stop all JSONL watches and clear all snapshots (used during shutdown).
	void stopAllWatches()
	{
		foreach (tid; jsonlWatches.keys)
			stopJsonlWatch(tid);
		foreach (tid; jsonlRetryTimers.keys)
			stopJsonlWatch(tid);
		undoJsonl = null;
	}

	/// Stop watching the JSONL file for a task.
	void stopJsonlWatch(int tid)
	{
		if (auto t = tid in jsonlRetryTimers)
		{
			(*t).cancel();
			jsonlRetryTimers.remove(tid);
		}
		if (auto h = tid in jsonlWatches)
		{
			rcINotify.remove(*h);
			jsonlWatches.remove(tid);
		}
		jsonlReadPos.remove(tid);
		jsonlPaths.remove(tid);
		liveContexts.remove(tid);
		jsonlLineCount.remove(tid);
		boundaryState.remove(tid);
		// The snapshot must survive an agent restart.
	}

	/// Return the pre-compaction JSONL snapshot for undo, or "" if none.
	string getUndoJsonl(int tid) { return undoJsonl.get(tid, ""); }

	/// Clear the undo snapshot for a task (call after the snapshot has been used).
	void clearUndoJsonl(int tid) { undoJsonl.remove(tid); }

	/// Save the current JSONL content as the undo snapshot for this task.
	/// Call this just before sending a new message to the agent, so the
	/// snapshot captures the state before any agent-side compaction.
	void captureUndoSnapshot(int tid)
	{
		import std.file : exists, readText;
		import std.logger : tracef;

		auto resolution = resolveTaskHistory(tid);
		final switch (resolution.kind)
		{
		case TaskHistoryResolutionKind.noSession:
		case TaskHistoryResolutionKind.orphanAgent:
		case TaskHistoryResolutionKind.unavailable:
			return;
		case TaskHistoryResolutionKind.access:
			break;
		}
		auto access = resolution.requireAccess();
		if (access.isDriverServed)
			return; // no file that an agent could rewrite under an undo
		undoJsonl[tid] = readText(access.path);
		tracef("[jsonl] captureUndoSnapshot tid=%d path=%s bytes=%d", tid,
			access.path, undoJsonl[tid].length);
	}


	private void resolveBoundary(int tid, size_t seq, PersistedHistoryBoundary boundary,
		bool publish, ulong generation)
	{
		if (onBoundaryResolved is null)
			return;
		if (boundaryHasCheckpoint(requireLiveContext(tid).agent.driver, boundary.kind))
			boundary.checkpointUuid = getTask(tid).checkpointUuidForAnchor(boundary.anchor);
		onBoundaryResolved(tid, seq, HistoryBoundary(boundary.anchor,
			boundary.kind == PersistedHistoryBoundaryKind.user
				? HistoryBoundaryKind.user
				: boundary.kind == PersistedHistoryBoundaryKind.provisional_user
					? HistoryBoundaryKind.provisional_user : HistoryBoundaryKind.agent_turn,
			boundary.checkpointUuid), publish, generation);
	}
}

version (unittest)
private void setTestLiveContext(ref JsonlTracker tracker, int tid,
	Agent agent, bool resuming = false)
{
	import cydo.runtime.launch.types : NativeHistoryProfile;

	tracker.liveContexts[tid] = LiveHistoryContext(agent,
		NativeHistoryProfile(agent.driver, "/tmp"), "session", resuming);
}

unittest
{
	assert(JsonlTracker.boundaryHasCheckpoint(AgentDriver.claude,
		PersistedHistoryBoundaryKind.user));
	assert(!JsonlTracker.boundaryHasCheckpoint(AgentDriver.claude,
		PersistedHistoryBoundaryKind.agent_turn));
	assert(!JsonlTracker.boundaryHasCheckpoint(AgentDriver.codex,
		PersistedHistoryBoundaryKind.user));
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.conv : to;
	auto tasks = [1: TaskData(1, "", "")];
	JsonlTracker tracker;
	tracker.getTask = (int tid) => &tasks[tid];
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] = [
		JsonlTracker.LiveBoundaryCandidate(3, PersistedHistoryBoundaryKind.user, "bootstrap", 0),
		JsonlTracker.LiveBoundaryCandidate(10, PersistedHistoryBoundaryKind.user, "second", 0),
		JsonlTracker.LiveBoundaryCandidate(17, PersistedHistoryBoundaryKind.user, "third", 0),
	];
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] = [
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("second", PersistedHistoryBoundaryKind.user, null), 2, false, 0),
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("third", PersistedHistoryBoundaryKind.user, null), 3, false, 0),
	];
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["second:10", "third:17"]);
	auto pending = tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user];
	assert(pending.length == 1 && pending[0].identity == "bootstrap");
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.conv : to;
	TaskData task = TaskData(1, "", "");
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:4",
			PersistedHistoryBoundaryKind.user, null, 4), 4, false, 0);
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","uuid":"live-user","meta":{"label":"Session start: agentic"}}`);
	assert(resolved == ["line:4:4"]);
}

@("Claude persisted prompt waits for its own stdout after a meta user")
unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.conv : to;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;

	auto path = buildPath(tempDir(), "cydo-jsonl-tracker-meta-user.jsonl");
	write(path, `{"type":"user","uuid":"M","isMeta":true,"message":{"role":"user","content":"Meta user"}}` ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};

	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","uuid":"M","is_meta":true}`);
	tracker.processNewJsonlContent(1, path);
	assert(resolved.length == 0, "Tailing M must leave the boundary unresolved");

	File(path, "a").write(`{"type":"user","uuid":"P","message":{"role":"user","content":"Canonical prompt"}}` ~ "\n");
	tracker.processNewJsonlContent(1, path);
	auto beforePromptStdout = resolved.dup;
	tracker.noteLiveBoundaryCandidate(1, 9,
		`{"type":"item/started","item_type":"user_message","uuid":"P"}`);

	assert(beforePromptStdout.length == 0,
		"Resolution before P stdout: " ~ beforePromptStdout.to!string
		~ "; resolutions after P stdout: " ~ resolved.to!string);
	assert(resolved == ["P:9"], "P must resolve exactly once at its own stdout sequence");
}

unittest
{
	import std.file : getSize, remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	auto path = "/tmp/cydo-jsonl-tracker-attach.jsonl";
	write(path, `{"type":"system","subtype":"init"}` ~ "\n"
		~ `{"type":"user","uuid":"df9fe96a-5ba5-4188-8ad9-ef654a518202","message":{"role":"user","content":"saved"}}` ~ "\n");
	scope(exit) remove(path);
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary b, bool, ulong) { resolved ~= b.anchor; };
	int[] lines;
	tracker.onJsonlLine = (int, string, int lineNum) { lines ~= lineNum; };
	tracker.noteLiveBoundaryCandidate(1, 0,
		`{"type":"item/started","item_type":"user_message","uuid":"df9fe96a-5ba5-4188-8ad9-ef654a518202"}`);
	tracker.attachAndCatchUp(1, path, false);
	assert(resolved == ["df9fe96a-5ba5-4188-8ad9-ef654a518202"]);
	tracker.stopJsonlWatch(1);
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent(), true);
	tracker.attachAndCatchUp(1, path, false);
	assert(tracker.jsonlReadPos[1] == getSize(path));
	assert(lines == [1, 2]);
	assert(resolved == ["df9fe96a-5ba5-4188-8ad9-ef654a518202"]);
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : remove, write;

	auto path = "/tmp/cydo-jsonl-tracker-fresh-claude.jsonl";
	write(path, `{"type":"queue-operation","operation":"enqueue"}` ~ "\n"
		~ `{"type":"user","uuid":"first-user","message":{"role":"user","content":"hello"}}` ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	string[] published;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool publish, ulong) {
		assert(seq == 4);
		assert(boundary.kind == HistoryBoundaryKind.user);
		assert(publish);
		published ~= boundary.anchor;
	};

	tracker.attachAndCatchUp(1, path, false);
	assert(published.length == 0);
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","uuid":"first-user"}`);
	assert(published == ["first-user"]);
}

@("Claude publishes the user checkpoint UUID in either arrival order")
unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : remove, write;

	enum uuid = "2f9b69a2-fb3d-4d54-b5ce-169ea80ebfd9";
	enum path = "/tmp/cydo-jsonl-tracker-claude-checkpoint.jsonl";
	foreach (transcriptFirst; [false, true])
	{
		write(path, `{"type":"user","uuid":"` ~ uuid
			~ `","message":{"role":"user","content":"hello"}}` ~ "\n");
		scope(exit) remove(path);

		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		string[] publishedCheckpoints;
		tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool publish, ulong) {
			assert(seq == 4);
			assert(boundary.kind == HistoryBoundaryKind.user);
			assert(boundary.anchor == uuid);
			assert(publish);
			publishedCheckpoints ~= boundary.checkpoint_uuid;
		};

		if (transcriptFirst)
			tracker.attachAndCatchUp(1, path, false);
		assert(publishedCheckpoints.length == 0);

		task.registerVisibleTurnAnchor(4, true, false, uuid, uuid, false);
		tracker.noteLiveBoundaryCandidate(1, 4,
			`{"type":"item/started","item_type":"user_message","uuid":"` ~ uuid ~ `"}`);
		if (!transcriptFirst)
		{
			assert(publishedCheckpoints.length == 0);
			tracker.attachAndCatchUp(1, path, false);
		}

		assert(publishedCheckpoints.length == 1);
		assert(publishedCheckpoints[0] == uuid, transcriptFirst
			? "Transcript-first boundary must publish the Claude checkpoint UUID"
			: "Stdout-first boundary must publish the Claude checkpoint UUID");
	}
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : remove, write;

	auto path = "/tmp/cydo-jsonl-tracker-resumed.jsonl";
	auto preexisting = `{"type":"system","subtype":"init"}` ~ "\n"
		~ `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}` ~ "\n";
	write(path, preexisting);
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent(), true);
	tracker.onJsonlLine = (int, string, int) {
		assert(false, "resumed attachment must not publish pre-existing lines");
	};
	tracker.onBoundaryResolved = (int, size_t, HistoryBoundary, bool, ulong) {
		assert(false, "resumed attachment must not resolve a pre-existing boundary");
	};
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","uuid":"live-user"}`);

	tracker.attachAndCatchUp(1, path, false);
	assert(tracker.jsonlReadPos[1] == preexisting.length);
	assert(tracker.jsonlLineCount[1] == 2);
}

@("Resumed reload loads the deferred prefix and tails the rest")
unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.workflow.history.jsonl_store : loadTaskHistory;
	import std.file : remove, write;

	auto path = "/tmp/cydo-jsonl-tracker-reload-watermark.jsonl";
	auto persisted = `{"type":"system","subtype":"init"}` ~ "\n\n";
	auto user = `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}`;
	write(path, persisted ~ user ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.atBytes(persisted.length));
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent(), true);
	int[] publishedLines;
	tracker.onJsonlLine = (int, string line, int lineNum) {
		assert(line == user);
		publishedLines ~= lineNum;
	};

	tracker.attachAndCatchUp(1, path, false);
	assert(publishedLines == [3]);
	assert(tracker.jsonlReadPos[1] == persisted.length + user.length + 1);
	assert(tracker.jsonlLineCount[1] == 3);
	task.history.load((ulong maxBytes) {
		auto loaded = loadTaskHistory(1, path, null, maxBytes);
		assert(loaded.rawSource == [persisted[0 .. $ - 2]]);
		return loaded;
	});
}

@("Resumed attachment tails the whole file when it appears after an unreadable snapshot")
unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : exists, remove, write;

	auto path = "/tmp/cydo-jsonl-tracker-unreadable-watermark.jsonl";
	assert(!exists(path));
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.unreadable());

	auto first = `{"type":"system","subtype":"init"}`;
	auto second = `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}`;
	write(path, first ~ "\n" ~ second ~ "\n");
	scope(exit) remove(path);

	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent(), true);
	string[] lines;
	int[] lineNumbers;
	tracker.onJsonlLine = (int, string line, int lineNum) {
		lines ~= line;
		lineNumbers ~= lineNum;
	};

	tracker.attachAndCatchUp(1, path, false);
	assert(lines == [first, second]);
	assert(lineNumbers == [1, 2]);
}

version (unittest)
private void checkSplitRecordAttachment(string path, Watermark watermark,
	string firstPrefix, string remainingRecords, string[] expectedLines)
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : remove, write;

	write(path, firstPrefix);
	scope(exit) remove(path);
	TaskData task = TaskData(1, "", "");
	task.history.reset(watermark);
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent(), true);
	string[] lines;
	int[] lineNumbers;
	tracker.onJsonlLine = (int, string line, int lineNum) {
		lines ~= line;
		lineNumbers ~= lineNum;
	};

	tracker.attachAndCatchUp(1, path, false);
	assert(lines.length == 0);
	File(path, "a").write(remainingRecords);
	tracker.processNewJsonlContent(1, path);
	assert(lines == expectedLines);
	assert(lineNumbers == [1, 2]);
}

@("Resumed attachment reconstructs a record split at attach-time EOF")
unittest
{
	auto prefix = `{"type":"system","subtype":`;
	auto suffix = `"init"}`;
	auto second = `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}`;
	checkSplitRecordAttachment("/tmp/cydo-jsonl-tracker-split-eof.jsonl",
		Watermark.none(), prefix, suffix ~ "\n" ~ second ~ "\n", [prefix ~ suffix, second]);
}

@("Resumed attachment reconstructs a record split by a deferred watermark")
unittest
{
	auto prefix = `{"type":"system",`;
	auto atAttach = prefix ~ `"subtype":`;
	auto suffix = `"init"}`;
	auto second = `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}`;
	checkSplitRecordAttachment("/tmp/cydo-jsonl-tracker-split-watermark.jsonl",
		Watermark.atBytes(prefix.length), atAttach, suffix ~ "\n" ~ second ~ "\n",
		[atAttach ~ suffix, second]);
}

@("Deferred load excludes a record whose newline falls beyond the watermark")
unittest
{
	import cydo.workflow.history.jsonl_store : loadTaskHistory;
	import std.file : remove, write;

	auto path = "/tmp/cydo-jsonl-tracker-deferred-partial.jsonl";
	auto first = `{"type":"system","subtype":"init"}`;
	auto second = `{"type":"user","uuid":"old-user","message":{"role":"user","content":"hi"}}`;
	auto prefix = first ~ "\n" ~ second;
	write(path, prefix ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.atBytes(prefix.length));
	task.history.load((ulong maxBytes) {
		auto loaded = loadTaskHistory(1, path, null, maxBytes);
		assert(loaded.rawSource == [first]);
		return loaded;
	});
}

unittest
{
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	tracker.resolveTaskHistory = (int) => TaskHistoryResolution.noSession();
	tracker.finalReconcileJsonlIfPresent(1);
	assert(1 !in tracker.jsonlPaths);
}

unittest
{
	import std.file : getSize, readText, remove, write;
	import std.conv : to;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : NativeHistoryProfile;
	import cydo.workflow.history.native_history : HistoryAccess;
	import ae.utils.json : JSONFragment, toJson;
	import cydo.protocol : TaskEventEnvelope;
	auto path = "/tmp/cydo-jsonl-tracker-final-flush.jsonl";
	write(path, `{"type":"system","subtype":"init"}` ~ "\n");
	TaskData task = TaskData(1, "", "");
	task.agentSessionId = "session";
	task.history.reset(Watermark.none());
	task.history.appendLive(Data(toJson(TaskEventEnvelope(1, 1,
		JSONFragment(`{"type":"item/started","item_type":"user_message"}`))).representation), null);
	auto agent = new ClaudeCodeAgent();
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	setTestLiveContext(tracker, 1, agent);
	tracker.historyGeneration = (int) => task.history.generation;
	tracker.resolveTaskHistory = (int) => TaskHistoryResolution.access(
		HistoryAccess(agent, NativeHistoryProfile(agent.driver, "/tmp"), "session",
			path));
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.jsonlReadPos[1] = getSize(path);
	tracker.jsonlPaths[1] = path;
	tracker.jsonlLineCount[1] = 1;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(0, PersistedHistoryBoundaryKind.user, "", task.history.generation);
	write(path, readText(path) ~ `{"type":"user","message":{"content":"saved"}}` ~ "\n");
	tracker.finalReconcileJsonlIfPresent(1);
	assert(resolved == ["line:2:0"]);
	tracker.finalReconcileJsonlIfPresent(1);
	assert(resolved == ["line:2:0"]);
	remove(path);
}

// Regression for the onExit sequence in task_runner.d: ensureHistoryLoadedForExit
// followed immediately by finalReconcileJsonlIfPresent(tid, itsReturnValue),
// for a task whose history was never loaded during its live session and
// whose native JSONL is unavailable at exit, must never report — that is the
// exclusive job of the post-exit config-only reset that runs after this pair
// (App.resetHistoryWatermark), which is the sole owner of the diagnostic for
// the exit sequence.
unittest
{
	import cydo.domain.storage.persistence : LoadedHistory;
	import cydo.workflow.history.native_history : UnavailableHistory, UnavailableHistoryKind;
	import cydo.workflow.history.pipeline : HistoryEventPipeline, HistoryEventPipelineHost;

	TaskData task = TaskData(1, "", "");

	auto unavailable = TaskHistoryResolution.unavailable(UnavailableHistory(
		UnavailableHistoryKind.context, "claude", "session-1",
		"The derived history file does not exist"));

	int reportCount;
	void reportUnavailableHistory(int tid, const ref TaskHistoryResolution resolution)
	{
		reportCount++;
		task.history.reset(Watermark.unreadable());
		task.history.load((ulong) => LoadedHistory.init);
	}

	auto pipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
		getTask: (int) => &task,
		resolveTaskHistory: (int) => unavailable,
		reportUnavailableHistory: &reportUnavailableHistory,
	));

	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.resolveTaskHistory = (int) => unavailable;

	assert(!task.history.isLoaded);
	auto historyResolution = pipeline.ensureHistoryLoadedForExit(1);
	assert(task.history.isLoaded);
	assert(reportCount == 0, "ensureHistoryLoadedForExit must not report; the "
		~ "post-exit reset owns the diagnostic");

	// Mirrors task_runner.d's onExit: finalReconcileJsonlIfPresent receives
	// the resolution ensureHistoryLoadedForExit just resolved, and must not
	// report it either.
	tracker.finalReconcileJsonlIfPresent(1, historyResolution);
	assert(reportCount == 0, "finalReconcileJsonlIfPresent must not report a "
		~ "resolution reused from ensureHistoryLoadedForExit");
}

// Positive-contract counterpart to the exit-path regression above:
// ensureHistoryLoaded (the reporting variant, used outside the exit sequence
// by handleRequestHistory and the edit-message flows) must still report an
// unavailable resolution exactly once, since it is the sole reporter for
// those callers.
unittest
{
	import cydo.workflow.history.native_history : UnavailableHistory, UnavailableHistoryKind;
	import cydo.workflow.history.pipeline : HistoryEventPipeline, HistoryEventPipelineHost;

	TaskData task = TaskData(1, "", "");

	auto unavailable = TaskHistoryResolution.unavailable(UnavailableHistory(
		UnavailableHistoryKind.context, "claude", "session-1",
		"The derived history file does not exist"));

	int reportCount;
	void reportUnavailableHistory(int tid, const ref TaskHistoryResolution resolution)
	{
		reportCount++;
	}

	auto pipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
		getTask: (int) => &task,
		resolveTaskHistory: (int) => unavailable,
		reportUnavailableHistory: &reportUnavailableHistory,
	));

	assert(!task.history.isLoaded);
	auto historyResolution = pipeline.ensureHistoryLoaded(1);
	assert(task.history.isLoaded);
	assert(reportCount == 1, "ensureHistoryLoaded should report exactly once");
	assert(!historyResolution.isNull);
	assert(historyResolution.get.kind == TaskHistoryResolutionKind.unavailable);
}

// A task whose history was already loaded before onExit runs (ensureHistoryLoadedForExit
// short-circuits, returning no resolution) must still have finalReconcileJsonlIfPresent
// resolve fresh, but — being exit-path exclusive — must not report it either;
// JsonlTracker has no reportUnavailableHistory delegate at all, so a report
// here would be a null-delegate crash rather than a silently swallowed call.
unittest
{
	import cydo.domain.storage.persistence : LoadedHistory;
	import cydo.workflow.history.native_history : UnavailableHistory, UnavailableHistoryKind;

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.unreadable());
	task.history.load((ulong) => LoadedHistory.init);
	assert(task.history.isLoaded);

	auto unavailable = TaskHistoryResolution.unavailable(UnavailableHistory(
		UnavailableHistoryKind.context, "claude", "session-1",
		"The derived history file does not exist"));

	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.resolveTaskHistory = (int) => unavailable;

	auto generationBefore = task.history.generation;
	tracker.finalReconcileJsonlIfPresent(1);
	assert(task.history.isLoaded);
	assert(task.history.generation == generationBefore,
		"the unavailable arm must leave history untouched");
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.exception : assertThrown;
	import core.exception : AssertError;
	import std.conv : to;
	auto tasks = [1: TaskData(1, "", ""), 2: TaskData(2, "", ""), 3: TaskData(3, "", "")];
	JsonlTracker tracker;
	tracker.getTask = (int tid) => &tasks[tid];
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	setTestLiveContext(tracker, 2, new ClaudeCodeAgent());
	setTestLiveContext(tracker, 3, new ClaudeCodeAgent());
	ulong current = 2;
	tracker.historyGeneration = (int) => current;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	auto staleLive = JsonlTracker.LiveBoundaryCandidate(1, PersistedHistoryBoundaryKind.user, "old", 1);
	auto currentLive = JsonlTracker.LiveBoundaryCandidate(2, PersistedHistoryBoundaryKind.user, "new", 2);
	auto stalePersisted = JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("old", PersistedHistoryBoundaryKind.user, null), 1, false, 1);
	auto currentPersisted = JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("new", PersistedHistoryBoundaryKind.user, null), 2, false, 2);
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~= [staleLive, currentLive];
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~= [stalePersisted, currentPersisted];
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["new:2"]);
	tracker.boundaryState[2] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[2].liveByKind[PersistedHistoryBoundaryKind.user] ~= currentLive;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.user] ~= stalePersisted;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.user] ~= currentPersisted;
	tracker.drainLiveBoundaries(2, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["new:2", "new:2"]);
	tracker.boundaryState[3] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[3].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(3, PersistedHistoryBoundaryKind.user, "future", 3);
	tracker.boundaryState[3].persistedByKind[PersistedHistoryBoundaryKind.user] ~= currentPersisted;
	assertThrown!AssertError(tracker.drainLiveBoundaries(3, PersistedHistoryBoundaryKind.user));
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.conv : to;
	// A boundary pair can be captured before a reset but resolved only after it.
	// Publication must reject that old lineage and accept a replacement pair.
	TaskData task = TaskData(1, "", "");
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	task.history.reset(Watermark.none());
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int tid, size_t seq, HistoryBoundary boundary, bool,
		ulong generation) {
		if (tracker.historyGeneration(tid) == generation)
			resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	auto stale = task.history.generation;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(12, PersistedHistoryBoundaryKind.user, "stale", stale);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("stale",
			PersistedHistoryBoundaryKind.user, null), 1, false, stale);
	task.history.reset(Watermark.none());
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved.length == 0);

	auto current = task.history.generation;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(1, PersistedHistoryBoundaryKind.user, "current", current);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("current",
			PersistedHistoryBoundaryKind.user, null), 2, false, current);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["current:1"]);
}

unittest
{
	import std.conv : to;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	string[] resolved;
	auto tasks = [1: TaskData(1, "", ""), 3: TaskData(3, "", ""), 5: TaskData(5, "", "")];
	JsonlTracker tracker;
	tracker.getTask = (int tid) => &tasks[tid];
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	// Live callback first: the canonical persisted identity resolves the queued live event.
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u"}`);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 1);
	tracker.invalidateLineage(1);
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u","meta":null}`);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 1);
	tracker.invalidateLineage(1);
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;

	// Live callback first: the canonical persisted identity resolves the queued live event.
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u"}`);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("u", PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["u:7"]);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user].length == 0);

	// Persisted callback first: noteLiveBoundaryCandidate drains the matching canonical queue.
	setTestLiveContext(tracker, 2, new ClaudeCodeAgent());
	tracker.boundaryState[2] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("turn", PersistedHistoryBoundaryKind.agent_turn, null), 1, false, 0, 0);
	tracker.noteLiveBoundaryCandidate(2, 8, `{"type":"turn/stop","uuid":"turn","api_block_count":1}`);
	assert(resolved == ["u:7", "turn:8"]);
	assert(tracker.boundaryState[2].liveByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);
	assert(tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);

	// Line anchors have no shared identity and drain FIFO in either callback order.
	setTestLiveContext(tracker, 3, new ClaudeCodeAgent());
	tracker.boundaryState[3] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[3].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:10", PersistedHistoryBoundaryKind.user, null), 10, false, 0);
	tracker.noteLiveBoundaryCandidate(3, 9,
		`{"type":"item/started","item_type":"user_message"}`);
	assert(resolved == ["u:7", "turn:8", "line:10:9"]);

	// Claude turn stops require a message id and cannot pair with another id.
	setTestLiveContext(tracker, 4, new ClaudeCodeAgent());
	tracker.boundaryState[4] = JsonlTracker.BoundaryReconcileState.init;
	import core.exception : AssertError;
	bool rejectedEmptyIdentity;
	try tracker.noteLiveBoundaryCandidate(4, 10, `{"type":"turn/stop"}`);
	catch (AssertError) rejectedEmptyIdentity = true;
	assert(rejectedEmptyIdentity);
	tracker.boundaryState[4].liveByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.LiveBoundaryCandidate(10, PersistedHistoryBoundaryKind.agent_turn, "X", 0);
	tracker.boundaryState[4].persistedByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("Y", PersistedHistoryBoundaryKind.agent_turn, null), 1, false, 0);
	tracker.drainLiveBoundaries(4, PersistedHistoryBoundaryKind.agent_turn);
	assert(tracker.boundaryState[4].liveByKind[PersistedHistoryBoundaryKind.agent_turn].length == 1);
	assert(tracker.boundaryState[4].persistedByKind[PersistedHistoryBoundaryKind.agent_turn].length == 1);

	setTestLiveContext(tracker, 5, new ClaudeCodeAgent());
	tracker.boundaryState[5] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[5].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(11, PersistedHistoryBoundaryKind.user, "user-a", 0);
	tracker.boundaryState[5].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("user-b", PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.drainLiveBoundaries(5, PersistedHistoryBoundaryKind.user);
	assert(resolved[$ - 1] == "user-b:11");
}

unittest
{
	import core.exception : AssertError;
	import std.conv : to;
	import std.exception : assertThrown;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto tasks = [1: TaskData(1, "", ""), 2: TaskData(2, "", ""),
		4: TaskData(4, "", ""), 6: TaskData(6, "", "")];
	JsonlTracker tracker;
	tracker.getTask = (int tid) => &tasks[tid];
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};

	// A registered local candidate cannot consume an unrelated ordinary user;
	// that ordinary pair remains eligible for Claude's existing FIFO path.
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"echo-native"}`,
		null, 0, true);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("ordinary",
			PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.noteLiveBoundaryCandidate(1, 8,
		`{"type":"item/started","item_type":"user_message","uuid":"other"}`);
	assert(resolved == ["ordinary:8"]);

	// Live-first and tail-first association require the canonical UUID and
	// each candidate resolves exactly once.
	tracker.noteQueueCanonicalIdentity(1, "echo-native", 0);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("echo-native",
			PersistedHistoryBoundaryKind.user, null), 2, true, 0);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["ordinary:8", "echo-native:7"]);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["ordinary:8", "echo-native:7"]);

	setTestLiveContext(tracker, 2, new ClaudeCodeAgent());
	tracker.noteQueueCanonicalIdentity(2, "echo-native-2", 0);
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("echo-native-2",
			PersistedHistoryBoundaryKind.user, null), 1, true, 0);
	tracker.noteLiveBoundaryCandidate(2, 9,
		`{"type":"item/started","item_type":"user_message","uuid":"echo-native-2"}`,
		null, 0, true);
	assert(resolved == ["ordinary:8", "echo-native:7", "echo-native-2:9"]);

	// A protected queue-derived persisted identity cannot fall back to FIFO.
	setTestLiveContext(tracker, 3, new ClaudeCodeAgent());
	tracker.noteQueueCanonicalIdentity(3, "echo-empty", 0);
	tracker.boundaryState[3].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("echo-empty",
			PersistedHistoryBoundaryKind.user, null), 1, true, 0);
	tracker.noteLiveBoundaryCandidate(3, 10,
		`{"type":"item/started","item_type":"user_message","uuid":"display-empty"}`,
		null, 0, true);
	assert(resolved.length == 3);

	// Steering is presentation metadata: an ordinary event retains FIFO.
	setTestLiveContext(tracker, 4, new ClaudeCodeAgent());
	tracker.boundaryState[4] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[4].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("ordinary-steering",
			PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.noteLiveBoundaryCandidate(4, 11,
		`{"type":"item/started","item_type":"user_message","is_steering":true}`);
	assert(resolved[$ - 1] == "ordinary-steering:11");

	tracker.noteAbsorbedLocalUser(1, "different-native", 0);
	assertThrown!AssertError(tracker.noteQueueCanonicalIdentity(1,
		"different-native", 0));

	// Absorption is exact: it removes an already-live local candidate and its
	// tombstone suppresses a late echo without disturbing ordinary FIFO users.
	setTestLiveContext(tracker, 6, new ClaudeCodeAgent());
	tracker.noteLiveBoundaryCandidate(6, 12,
		`{"type":"item/started","item_type":"user_message","uuid":"absorbed-live"}`,
		null, 0, true);
	tracker.noteAbsorbedLocalUser(6, "absorbed-live", 0);
	assert(tracker.boundaryState[6].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	tracker.noteAbsorbedLocalUser(6, "absorbed-live", 0);
	tracker.noteLiveBoundaryCandidate(6, 13,
		`{"type":"item/started","item_type":"user_message","uuid":"absorbed-live"}`,
		null, 0, true);
	assert(tracker.boundaryState[6].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	tracker.boundaryState[6].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("ordinary-peer",
			PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.noteLiveBoundaryCandidate(6, 14,
		`{"type":"item/started","item_type":"user_message","uuid":"ordinary-peer"}`);
	assert(resolved[$ - 1] == "ordinary-peer:14");
}

unittest
{
	JsonlTracker tracker;
	tracker.historyGeneration = (int) => 0;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(4, PersistedHistoryBoundaryKind.user, "user", 0);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("user",
			PersistedHistoryBoundaryKind.user, null), 1, false, 0);
	tracker.jsonlReadPos[1] = 42;
	tracker.jsonlLineCount[1] = 3;

	tracker.stopJsonlWatch(1);

	assert(1 !in tracker.boundaryState);
	assert(1 !in tracker.jsonlReadPos);
	assert(1 !in tracker.jsonlLineCount);

	// Invalidation advances the watch generation, so a callback captured by the
	// old watch cannot process the replacement lineage.
	tracker.lineageGeneration[2] = 4;
	auto staleGeneration = tracker.lineageGeneration[2];
	tracker.invalidateLineage(2);
	assert(tracker.lineageGeneration[2] != staleGeneration);
}

unittest
{
	import std.string : lineSplitter;

	auto firstNotification = `{"type":"user.message","id":"u"}`;
	assert(completeJsonlPrefix(firstNotification).length == 0);
	int incompleteLines;
	foreach (_; firstNotification.lineSplitter)
		incompleteLines++;
	assert(incompleteLines == 1);

	auto completedNotification = firstNotification ~ "\n";
	auto completeBytes = completeJsonlPrefix(completedNotification).length;
	assert(completeBytes == completedNotification.length);
	auto completeContent = completedNotification[0 .. completeBytes];
	int completeLines;
	foreach (_; completeContent.lineSplitter)
		completeLines++;
	assert(completeLines == 1);
}

unittest
{
	import std.conv : to;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.file : remove, write;

	// A notification may arrive after stdout supplied the live candidate but
	// before the writer has finished its JSONL line.  The completed line must
	// be consumed once, rather than losing or replaying its boundary.
	auto path = "/tmp/cydo-jsonl-tracker-split-tail.jsonl";
	auto preamble = `{"type":"system","subtype":"init"}` ~ "\n";
	auto line = `{"type":"user","uuid":"df9fe96a-5ba5-4188-8ad9-ef654a518202","message":{"role":"user","content":"saved"}}`;
	write(path, preamble ~ line[0 .. 20]);

	scope(exit) remove(path);
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	int[] lines;
	tracker.onJsonlLine = (int, string, int lineNum) { lines ~= lineNum; };
	tracker.noteLiveBoundaryCandidate(1, 12,
		`{"type":"item/started","item_type":"user_message","uuid":"df9fe96a-5ba5-4188-8ad9-ef654a518202"}`);

	tracker.processNewJsonlContent(1, path);
	assert(resolved.length == 0);
	assert(lines == [1]);
	File(path, "a").write(line[20 .. $] ~ "\n");
	tracker.processNewJsonlContent(1, path);
	tracker.processNewJsonlContent(1, path);
	assert(lines == [1, 2]);
	assert(resolved.length == 1);
	assert(resolved[0] == "df9fe96a-5ba5-4188-8ad9-ef654a518202:12");
}

unittest
{
	import std.conv : to;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	// When both queues already contain consecutive compatible boundaries, one
	// reconciliation pass preserves their full FIFO order.
	auto tasks = [1: TaskData(1, "", "")];
	JsonlTracker tracker;
	tracker.getTask = (int tid) => &tasks[tid];
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	foreach (i; 0 .. 2)
	{
		tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
			JsonlTracker.LiveBoundaryCandidate(10 + i, PersistedHistoryBoundaryKind.user, "", 0);
		tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
			JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:" ~ to!string(i + 1),
				PersistedHistoryBoundaryKind.user, null), i + 1, false, 0);
	}

	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["line:1:10", "line:2:11"]);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user].length == 0);
}

unittest
{
	import cydo.agent.drivers.codex : computeRollbackSkipLines;
	auto jsonl =
		`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	auto skipped = computeRollbackSkipLines(jsonl);
	assert(4 in skipped && 5 in skipped);
}

unittest
{
	import core.exception : AssertError;
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum assistant1 = `{"type":"assistant","uuid":"a1","apiBlockIndex":0,"message":{"id":"X"}}`;
	enum assistant2 = `{"type":"assistant","uuid":"a2","apiBlockIndex":1,"message":{"id":"X"}}`;
	enum toolResult = `{"type":"user","uuid":"tool-result","message":{"content":[{"type":"tool_result","content":"ok"}]}}`;
	foreach (liveFirst; [true, false])
	{
		auto path = liveFirst ? "/tmp/cydo-message-anchor-live-first.jsonl"
			: "/tmp/cydo-message-anchor-file-first.jsonl";
		write(path, assistant1 ~ "\n" ~ toolResult ~ "\n" ~ assistant2 ~ "\n");
		scope(exit) remove(path);
		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		string[] resolved;
		tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
			resolved ~= boundary.anchor;
		};
		if (liveFirst) tracker.noteLiveBoundaryCandidate(1, 1, `{"type":"turn/stop","uuid":"X","api_block_count":2}`);
		tracker.processNewJsonlContent(1, path);
		if (!liveFirst) tracker.noteLiveBoundaryCandidate(1, 1, `{"type":"turn/stop","uuid":"X","api_block_count":2}`);
		assert(resolved == ["X"]);
		assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);
		assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);
	}

	auto path = "/tmp/cydo-message-anchor-reused.jsonl";
	write(path, assistant1 ~ "\n" ~
		`{"type":"user","uuid":"prompt","message":{"content":"hello"}}` ~ "\n" ~
		assistant2 ~ "\n");
	scope(exit) remove(path);
	TaskData task = TaskData(2, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	setTestLiveContext(tracker, 2, new ClaudeCodeAgent());
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	bool rejected;
	try tracker.processNewJsonlContent(2, path);
	catch (AssertError) rejected = true;
	assert(rejected);
}

unittest
{
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.agent.drivers.copilot : CopilotAgent;
	foreach (driver; ["codex", "copilot"])
	{
		JsonlTracker tracker;
		if (driver == "codex") setTestLiveContext(tracker, 1, new CodexAgent());
		else setTestLiveContext(tracker, 1, new CopilotAgent());
		tracker.historyGeneration = (int) => 0;
		string[] resolved;
			tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
				resolved ~= boundary.anchor;
			};
			auto anchor = driver == "codex" ? "line:2" : "copilot-id";
			tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
		tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
			JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary(anchor,
				PersistedHistoryBoundaryKind.agent_turn, null), 2, false, 0);
		tracker.noteLiveBoundaryCandidate(1, 1, driver == "codex"
			? `{"type":"turn/stop"}` : `{"type":"turn/stop","uuid":"copilot-id"}`);
		assert(resolved == [anchor]);
	}
}

@("Claude live reconciliation absorbs history rows belonging to one root message")
unittest
{
	import std.array : join;
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent, claudeHistoryAgreementFixture;

	enum path = "/tmp/cydo-tracker-shared-claude-history-rows.jsonl";
	foreach (toolInputType; ["ordinary", "user", "queue-operation"])
	{
		auto rows = claudeHistoryAgreementFixture(toolInputType);
		write(path, rows[0 .. 9].join("\n") ~ "\n");
		scope(exit) remove(path);

		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		string[] resolved;
		tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
			resolved ~= boundary.anchor;
		};
		tracker.noteLiveBoundaryCandidate(1, 1, `{"type":"turn/stop","uuid":"X","api_block_count":2}`);
		tracker.processNewJsonlContent(1, path);
		assert(resolved.length == 0, "first member must not publish the boundary");
		File(path, "a").write(rows[9 .. $].join("\n") ~ "\n");
		tracker.processNewJsonlContent(1, path);
		assert(resolved == ["X"]);
		assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);
		assert(PersistedHistoryBoundaryKind.user !in tracker.boundaryState[1].persistedByKind);

		// A terminal row with no public boundary must still close X across
		// chunks, so its reappearance is rejected just as it is in replay.
		import core.exception : AssertError;
		import std.exception : assertThrown;
		tracker.invalidateLineage(1);
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		write(path, rows[3] ~ "\n" ~ rows[13] ~ "\n");
		tracker.processNewJsonlContent(1, path);
		File(path, "a").write(rows[10] ~ "\n");
		assertThrown!AssertError(tracker.processNewJsonlContent(1, path));
	}
}

@("Claude boundaries wait for the final complete persisted block")
unittest
{
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-final-claude-block.jsonl";
	enum member0 = `{"type":"assistant","apiBlockIndex":0,"message":{"id":"X","content":[{"type":"tool_use"}]}}`;
	enum member1 = `{"type":"assistant","apiBlockIndex":1,"message":{"id":"X","content":[{"type":"text","text":""}]}}`;
	enum toolResult = `{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}`;
	enum stop = `{"type":"turn/stop","uuid":"X","api_block_count":2}`;
	string[] earlyPublication;
	foreach (scenario; ["split writes", "torn final line", "file first", "closed short"])
	{
		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		size_t[] resolved;
		tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
			assert(boundary.anchor == "X");
			resolved ~= seq;
		};

		auto prefix = member0 ~ "\n" ~ toolResult ~ "\n";
		if (scenario == "closed short")
			prefix ~= `{"type":"summary","summary":"end"}` ~ "\n";
		if (scenario == "file first")
			prefix ~= member1 ~ "\n";
		else if (scenario == "torn final line")
			prefix ~= member1;
		write(path, prefix);
		scope(exit) remove(path);
		if (scenario != "file first")
			tracker.noteLiveBoundaryCandidate(1, 7, stop);
		tracker.processNewJsonlContent(1, path);
		if (resolved.length > 0)
			earlyPublication ~= scenario;
		if (scenario == "closed short")
			continue;
		if (scenario == "file first")
			tracker.noteLiveBoundaryCandidate(1, 7, stop);
		else
		{
			File(path, "a").write(scenario == "torn final line" ? "\n" : member1 ~ "\n");
			tracker.processNewJsonlContent(1, path);
		}
		assert(resolved == [7]);
	}
	import std.array : join;
	assert(earlyPublication.length == 0,
		"Claude published prematurely for " ~ earlyPublication.join(", "));
}

@("An empty Claude block resolves and a message without rows does not block its successor")
unittest
{
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.format : format;

	enum path = "/tmp/cydo-tracker-empty-claude-block.jsonl";
	foreach (absentCount; [0, 1])
	{
		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		string[] resolved;
		tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
			resolved ~= boundary.anchor;
		};
		write(path, "");
		scope(exit) remove(path);
		tracker.noteLiveBoundaryCandidate(1, 1,
			format!`{"type":"turn/stop","uuid":"X","api_block_count":%d}`(absentCount));
		if (absentCount == 0)
		{
			enum kind = PersistedHistoryBoundaryKind.agent_turn;
			auto state = 1 in tracker.boundaryState;
			assert(state is null || kind !in state.liveByKind || state.liveByKind[kind].length == 0,
				"a zero-block Claude stop must register no live candidate");
		}
		tracker.processNewJsonlContent(1, path);
		assert(resolved.length == 0);
		tracker.noteLiveBoundaryCandidate(1, 2, `{"type":"turn/stop","uuid":"Y","api_block_count":1}`);
		write(path, `{"type":"assistant","apiBlockIndex":0,"message":{"id":"Y","content":[{"type":"text","text":""}]}}` ~ "\n");
		tracker.processNewJsonlContent(1, path);
		assert(resolved == ["Y"]);
	}
}

@("Claude boundary reconciliation rejects inconsistent persisted indexes")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-invalid-claude-index.jsonl";
	enum member0 = `{"type":"assistant","apiBlockIndex":0,"message":{"id":"X"}}` ~ "\n";
	enum member1 = `{"type":"assistant","apiBlockIndex":1,"message":{"id":"X"}}` ~ "\n";
	enum member2 = `{"type":"assistant","apiBlockIndex":2,"message":{"id":"X"}}` ~ "\n";
	enum stop1 = `{"type":"turn/stop","uuid":"X","api_block_count":1}`;
	enum stop2 = `{"type":"turn/stop","uuid":"X","api_block_count":2}`;
	foreach (testCase; [
		[stop2, "", member2],
		[stop2, member0, member0],
		[stop1, member0, member1],
		[stop2, "", `{"type":"assistant","message":{"id":"X"}}` ~ "\n"],
	])
	{
		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		tracker.noteLiveBoundaryCandidate(1, 1, testCase[0]);
		write(path, testCase[1]);
		scope(exit) remove(path);
		tracker.processNewJsonlContent(1, path);
		File(path, "a").write(testCase[2]);
		assertThrown!AssertError(tracker.processNewJsonlContent(1, path));
	}
}

@("Claude joined text replies stay unpublished without blocking the next message")
unittest
{
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-joined-claude-reply.jsonl";
	// Pinned CLI with CLAUDE_CODE_WEBSEARCH_CITATIONS=1, simplified to
	// the fields relevant to reconciliation. The second probe mixes in a tool.
	enum joined = `{"type":"assistant","uuid":"404c6bdd-8831-451b-9278-28d2e9239942","message":{"id":"msg_mock_00001","content":[{"type":"text","text":"steering-probe-first-blocksteering-probe-second-block","citations":null}]},"joinedApiReply":true}`;
	enum tool = `{"type":"assistant","apiBlockIndex":2,"message":{"id":"msg_mock_00001","content":[{"type":"tool_use","name":"Bash"}]}}`;
	enum next = `{"type":"assistant","uuid":"329e3779-df0b-45d0-80b4-c267c0089ad8","apiBlockIndex":0,"message":{"id":"msg_mock_00002","content":[{"type":"text","text":"steering-probe-second"}]}}`;
	string[] retained;
	foreach (mixed; [false, true])
	{
		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		string[] resolved;
		tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
			resolved ~= boundary.anchor;
		};
		write(path, joined ~ "\n");
		scope(exit) remove(path);
		tracker.noteLiveBoundaryCandidate(1, 1, mixed
			? `{"type":"turn/stop","uuid":"msg_mock_00001","api_block_count":3}`
			: `{"type":"turn/stop","uuid":"msg_mock_00001","api_block_count":2}`);
		tracker.processNewJsonlContent(1, path);
		if (mixed)
		{
			File(path, "a").write(tool ~ "\n");
			tracker.processNewJsonlContent(1, path);
		}
		assert(resolved.length == 0);
		tracker.noteLiveBoundaryCandidate(1, 2,
			`{"type":"turn/stop","uuid":"msg_mock_00002","api_block_count":1}`);
		File(path, "a").write(next ~ "\n");
		tracker.processNewJsonlContent(1, path);
		assert(resolved == ["msg_mock_00002"]);
		enum kind = PersistedHistoryBoundaryKind.agent_turn;
		auto state = &tracker.boundaryState[1];
		auto live = kind in state.liveByKind;
		auto persisted = kind in state.persistedByKind;
		if ((live !is null && (*live).length != 0) || (persisted !is null && (*persisted).length != 0))
			retained ~= mixed ? "joined reply with tool retained candidates" : "joined reply retained candidates";
	}
	import std.array : join;
	assert(retained.length == 0, retained.join("\n"));
}

@("Claude tracker rejects a message that reappears after a parent-linked queue operation")
unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent, claudeParentLinkedQueueFixture;

	enum path = "/tmp/cydo-tracker-claude-queue-contiguity.jsonl";
	write(path, `{"type":"assistant","apiBlockIndex":0,"message":{"id":"X"}}` ~ "\n" ~
		claudeParentLinkedQueueFixture("queue-operation") ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	tracker.processNewJsonlContent(1, path);
	File(path, "a").write(`{"type":"assistant","apiBlockIndex":1,"message":{"id":"X"}}` ~ "\n");
	assertThrown!AssertError(tracker.processNewJsonlContent(1, path));
}

@("Claude tracker rejects a missing block index in both arrival orders")
unittest
{
	import core.exception : AssertError;
	import std.array : join;
	import std.file : remove, write;
	import std.format : format;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-claude-missing-index.jsonl";
	enum stop = `{"type":"turn/stop","uuid":"X","api_block_count":2}`;
	string[] mismatches;
	foreach (liveFirst; [true, false])
	{
		write(path, `{"type":"assistant","message":{"id":"X"}}` ~ "\n" ~
			`{"type":"assistant","apiBlockIndex":1,"message":{"id":"X"}}` ~ "\n");
		scope(exit) remove(path);

		TaskData task = TaskData(1, "", "");
		task.history.reset(Watermark.none());
		JsonlTracker tracker;
		setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
		tracker.getTask = (int) => &task;
		tracker.historyGeneration = (int) => task.history.generation;
		string[] resolved;
		tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
			resolved ~= boundary.anchor;
		};

		bool rejected;
		if (liveFirst)
		{
			tracker.noteLiveBoundaryCandidate(1, 1, stop);
			try tracker.processNewJsonlContent(1, path);
			catch (AssertError) rejected = true;
		}
		else
		{
			tracker.processNewJsonlContent(1, path);
			try tracker.noteLiveBoundaryCandidate(1, 1, stop);
			catch (AssertError) rejected = true;
		}
		if (!rejected || resolved.length != 0)
			mismatches ~= format!"%s first: rejection=%s, published=%s"(
				liveFirst ? "stop" : "file", rejected, resolved);
	}
	assert(mismatches.length == 0, mismatches.join("\n"));
}

@("Claude publication retires older unmatched message candidates")
unittest
{
	import std.array : join;
	import std.file : remove, write;
	import std.format : format;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-claude-retirement.jsonl";
	enum kind = PersistedHistoryBoundaryKind.agent_turn;
	enum successor = `{"type":"assistant","apiBlockIndex":0,"message":{"id":"Z"}}` ~ "\n";
	enum successorStop = `{"type":"turn/stop","uuid":"Z","api_block_count":1}`;
	struct Scenario
	{
		string name;
		string[] stops;
		string rows;
	}
	auto scenarios = [
		Scenario("refusal", [
			`{"type":"turn/stop","uuid":"R1","api_block_count":1}`,
			`{"type":"turn/stop","uuid":"R2","api_block_count":1}`,
		], ""),
		Scenario("interrupted stream", [`{"type":"turn/stop","uuid":"X","api_block_count":2}`],
			`{"type":"assistant","apiBlockIndex":0,"message":{"id":"X"}}` ~ "\n"),
		Scenario("synthetic reply", [],
			`{"type":"assistant","message":{"id":"535a0cf3-a555-4b47-a2db-e41463b473df","model":"<synthetic>"}}` ~ "\n"),
	];
	string[] mismatches;
	foreach (scenario; scenarios)
		foreach (liveFirst; [true, false])
		{
			write(path, scenario.rows ~ successor);
			scope(exit) remove(path);

			TaskData task = TaskData(1, "", "");
			task.history.reset(Watermark.none());
			JsonlTracker tracker;
			setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
			tracker.getTask = (int) => &task;
			tracker.historyGeneration = (int) => task.history.generation;
			string[] resolved;
			tracker.onBoundaryResolved = (int, size_t, HistoryBoundary boundary, bool, ulong) {
				resolved ~= boundary.anchor;
			};

			void sendStops()
			{
				foreach (i, stop; scenario.stops)
					tracker.noteLiveBoundaryCandidate(1, i + 1, stop);
				tracker.noteLiveBoundaryCandidate(1, scenario.stops.length + 1, successorStop);
			}
			if (liveFirst) sendStops();
			tracker.processNewJsonlContent(1, path);
			if (!liveFirst) sendStops();

			auto state = &tracker.boundaryState[1];
			auto live = kind in state.liveByKind;
			auto persisted = kind in state.persistedByKind;
			auto liveCount = live is null ? 0 : (*live).length;
			auto persistedCount = persisted is null ? 0 : (*persisted).length;
			if (resolved != ["Z"] || liveCount != 0 || persistedCount != 0)
				mismatches ~= format!"%s, %s first: published=%s, retained live=%s persisted=%s"(
					scenario.name, liveFirst ? "stop" : "file", resolved, liveCount, persistedCount);
		}
	assert(mismatches.length == 0, mismatches.join("\n"));
}

@("Claude transcript payloads never invalidate the lineage")
unittest
{
	import std.file : remove, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	enum path = "/tmp/cydo-tracker-claude-rollback-payload.jsonl";
	write(path, `{"type":"assistant","apiBlockIndex":0,"message":{"id":"X","content":[{"type":"tool_use","input":{"type":"thread_rolled_back"}}]}}` ~ "\n");
	scope(exit) remove(path);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	setTestLiveContext(tracker, 1, new ClaudeCodeAgent());
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	tracker.onLineageInvalidated = (int) { assert(false, "a quoted rollback event is not a lineage change"); };
	tracker.processNewJsonlContent(1, path);
}
