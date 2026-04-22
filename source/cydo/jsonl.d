module cydo.jsonl;

import std.stdio : File;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.sys.inotify : INotify;
import ae.sys.timing : setTimeout, TimerTask;

import cydo.agent.agent : Agent, ForkableIdInfo;
import cydo.inotify : RefCountedINotify;
import cydo.task : AssignUuidsMessage, ForkableUuidsMessage, TaskData, UuidAssignment, extractEventFromEnvelope;

struct JsonlTracker
{
	Agent delegate(int tid) getAgent;
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, string msg) sendToSubscribed;
	void delegate(int tid, size_t seq, string anchor) onAnchorResolved;

	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private int[int] jsonlLineCount;
	private TimerTask[int] jsonlRetryTimers;
	// Snapshot of JSONL content taken just before broadcast, used for undo
	// when the agent compacts the file (e.g. Codex auto-compaction).
	private string[int] undoJsonl;

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	void startJsonlWatch(int tid)
	{
		import std.file : exists, mkdirRecurse;
		import std.path : baseName, dirName;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null)
			return;
		if (tid in jsonlWatches)
			return;
		if (td.agentSessionId.length == 0)
			return;

		auto jsonlPath = getAgent(tid).historyPath(td.agentSessionId, td.effectiveCwd);
		tracef("[jsonl] startJsonlWatch tid=%d sessionId=%s jsonlPath=%s exists=%s",
			tid, td.agentSessionId, jsonlPath, jsonlPath.length > 0 && exists(jsonlPath));
		if (jsonlPath.length == 0)
		{
			// File not discoverable yet (e.g. Codex — JSONL created asynchronously).
			// Schedule a retry so the watch gets established once the file appears.
			import core.time : seconds;
			if (tid !in jsonlRetryTimers)
				jsonlRetryTimers[tid] = setTimeout({
					jsonlRetryTimers.remove(tid);
					startJsonlWatch(tid);
				}, 2.seconds);
			return;
		}

		if (auto t = tid in jsonlRetryTimers)
		{
			(*t).cancel();
			jsonlRetryTimers.remove(tid);
		}

		if (exists(jsonlPath))
		{
			watchJsonlFile(tid, jsonlPath);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation.
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			mkdirRecurse(dirPath);
			jsonlWatches[tid] = rcINotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (name == fileName)
					{
						// File appeared — switch to file watch
						if (auto h = tid in jsonlWatches)
						{
							rcINotify.remove(*h);
							jsonlWatches.remove(tid);
						}
						watchJsonlFile(tid, jsonlPath);
					}
				}
			);
		}
	}

	/// Start watching a JSONL file for modifications.
	void watchJsonlFile(int tid, string jsonlPath)
	{
		processNewJsonlContent(tid, jsonlPath);

		jsonlWatches[tid] = rcINotify.add(jsonlPath, INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				processNewJsonlContent(tid, jsonlPath);
			}
		);
	}

	/// Read new content from the JSONL file and broadcast forkable UUIDs.
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
			// File shrank — agent compacted the JSONL (e.g. Codex auto-compaction).
			// The pre-compaction content was already saved to undoJsonl on the last
			// normal-growth event, so don't overwrite it.  Just reset read position
			// and skip broadcasting: the compacted forkIds (checkpoint only) are not
			// meaningful to the frontend and would overwrite valid prior assignments.
			tracef("[jsonl] processNewJsonlContent tid=%d: file shrank (was %d, now %d) — compaction detected, skipping broadcast", tid, lastPos, fileSize);
			jsonlReadPos[tid] = fileSize;
			jsonlLineCount[tid] = 0;
			return;
		}
		if (fileSize <= lastPos)
			return;

		auto f = File(jsonlPath, "r");
		f.seek(lastPos);
		char[] buf;
		buf.length = cast(size_t)(fileSize - lastPos);
		auto got = f.rawRead(buf);
		jsonlReadPos[tid] = cast(size_t) fileSize;

		auto newContent = cast(string) got;
		auto lineOffset = jsonlLineCount.get(tid, 0);
		auto forkIds = getAgent(tid).extractForkableIdsWithInfo(newContent, lineOffset);
		tracef("[jsonl] processNewJsonlContent tid=%d path=%s newBytes=%d forkIds=%d", tid, jsonlPath, got.length, forkIds.length);

		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; newContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		import std.algorithm : canFind;
		bool hasRollback = newContent.canFind(`"thread_rolled_back"`);
		if (forkIds.length > 0 || hasRollback)
			// Read the full JSONL so computeAssignments can correlate IDs by
			// global order (incremental forkIds start idx at 0 and would map
			// turn-2 IDs to turn-1 seqs).
			broadcastForkableUuidsFromFile(tid);
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
		jsonlLineCount.remove(tid);
		// Do NOT remove undoJsonl here: for agents that auto-restart (e.g. Codex
		// exits with SIGTERM and is restarted), the snapshot captured before the
		// stall message is still valid and must survive the restart cycle.
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

		auto td = getTask(tid);
		if (td is null || td.agentSessionId.length == 0)
			return;
		auto jsonlPath = getAgent(tid).historyPath(td.agentSessionId, td.effectiveCwd);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;
		undoJsonl[tid] = readText(jsonlPath);
		tracef("[jsonl] captureUndoSnapshot tid=%d path=%s bytes=%d", tid, jsonlPath, undoJsonl[tid].length);
	}

	/// Send forkable UUIDs from the full JSONL file to a single client.
	void sendForkableUuidsFromFile(WebSocketAdapter ws, int tid,
		string agentSessionId, string projectPath)
	{
		import std.algorithm : map;
		import std.array : array;
		import std.file : exists, readText;
		import ae.utils.json : toJson;

		auto jsonlPath = getAgent(tid).historyPath(agentSessionId, projectPath);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;

		auto content = readText(jsonlPath);
		auto forkIds = getAgent(tid).extractForkableIdsWithInfo(content);
		auto td = getTask(tid);
		auto isClaude = td !is null && td.agentType == "claude";
		UuidAssignment[] assignments;
		string[] uuids;
		if (isClaude)
		{
			bool[string] onDiskAnchors;
			foreach (ref fid; forkIds)
				onDiskAnchors[fid.id] = true;
			assignments = resolvePendingAssignments(tid, forkIds);
			foreach (anchor; td.resolvedVisibleAnchors())
				if (anchor in onDiskAnchors)
					uuids ~= anchor;
		}
		else
		{
			assignments = computeAssignments(tid, forkIds);
			uuids = forkIds.map!(f => f.id).array;
		}
		if (uuids.length > 0)
			ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)).representation));
		if (assignments.length > 0)
			ws.send(Data(toJson(AssignUuidsMessage("assign_uuids", tid, assignments)).representation));
	}

	/// Broadcast forkable UUIDs from the full JSONL file to subscribed clients.
	void broadcastForkableUuidsFromFile(int tid)
	{
		import std.file : exists, readText;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null)
			return;
		if (td.agentSessionId.length == 0)
			return;

		auto ta = getAgent(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
		{
			tracef("[jsonl] broadcastForkableUuidsFromFile tid=%d: path missing/nonexistent: %s", tid, jsonlPath);
			return;
		}

		auto forkIds = ta.extractForkableIdsWithInfo(readText(jsonlPath));
		tracef("[jsonl] broadcastForkableUuidsFromFile tid=%d forkIds=%d path=%s", tid, forkIds.length, jsonlPath);
		if (forkIds.length > 0)
			broadcastForkableUuidsWithAssignments(tid, forkIds);
	}

	/// Broadcast forkable UUIDs to subscribed clients.
	void broadcastForkableUuids(int tid, string[] uuids)
	{
		import ae.utils.json : toJson;
		sendToSubscribed(tid, toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));
	}

	/// Broadcast forkable UUIDs and their seq assignments to subscribed clients.
	void broadcastForkableUuidsWithAssignments(int tid, ForkableIdInfo[] forkIds)
	{
		import std.algorithm : map;
		import std.array : array;
		import ae.utils.json : toJson;

		auto td = getTask(tid);
		auto isClaude = td !is null && td.agentType == "claude";
		UuidAssignment[] assignments;
		string[] uuids;
		if (isClaude)
		{
			bool[string] onDiskAnchors;
			foreach (ref fid; forkIds)
				onDiskAnchors[fid.id] = true;
			assignments = resolvePendingAssignments(tid, forkIds);
			foreach (anchor; td.resolvedVisibleAnchors())
				if (anchor in onDiskAnchors)
					uuids ~= anchor;
		}
		else
		{
			assignments = computeAssignments(tid, forkIds);
			uuids = forkIds.map!(f => f.id).array;
		}
		sendToSubscribed(tid, toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));

		if (assignments.length > 0)
			sendToSubscribed(tid, toJson(AssignUuidsMessage("assign_uuids", tid, assignments)));
	}

	/// Compute seq→UUID assignments by correlating JSONL forkable IDs with history events.
	UuidAssignment[] computeAssignments(int tid, ForkableIdInfo[] forkIds)
	{
		import std.algorithm : canFind;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null) return null;

		// Count user and assistant events in history, recording their seqs
		size_t[] userSeqs, assistantSeqs;
		foreach (i, ref entry; td.history)
		{
			auto envelope = cast(string) entry.unsafeContents;
			// Only look inside regular events (skip unconfirmedUserEvent and other envelopes).
			auto content = extractEventFromEnvelope(envelope);
			if (content.length == 0)
				continue;
			// User message: item/started with user_message type
			if (content.canFind(`"item_type":"user_message"`) && content.canFind(`"type":"item/started"`)
				&& !content.canFind(`"is_meta":true`))
				userSeqs ~= i;
			// Assistant turn: turn/stop
			else if (content.canFind(`"type":"turn/stop"`))
				assistantSeqs ~= i;
		}

		tracef("[jsonl] computeAssignments tid=%d forkIds=%d userSeqs=%s assistantSeqs=%s histLen=%d",
			tid, forkIds.length, userSeqs, assistantSeqs, td.history.length);

		// Match forkable IDs to history seqs by order
		size_t userIdx, assistantIdx;
		UuidAssignment[] result;
		foreach (ref fid; forkIds)
		{
			if (fid.isUser)
			{
				if (userIdx < userSeqs.length)
					result ~= UuidAssignment(fid.id, userSeqs[userIdx]);
				userIdx++;
			}
			else
			{
				if (assistantIdx < assistantSeqs.length)
					result ~= UuidAssignment(fid.id, assistantSeqs[assistantIdx]);
				assistantIdx++;
			}
		}
		tracef("[jsonl] computeAssignments tid=%d result=%d assignments", tid, result.length);
		return result;
	}

	private bool isEnqueueAnchor(string id)
	{
		return id.length > "enqueue-".length
			&& id[0 .. "enqueue-".length] == "enqueue-";
	}

	/// Resolve pending visible-turn anchors against enqueue IDs seen in JSONL.
	private UuidAssignment[] resolvePendingAssignments(int tid, ForkableIdInfo[] forkIds)
	{
		import std.algorithm : sort;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null)
			return null;

		auto pendingSeqs = td.pendingVisibleTurnSeqs();
		if (pendingSeqs.length == 0)
			return null;
		pendingSeqs.sort();

		bool[string] usedEnqueueAnchors;
		foreach (anchor; td.resolvedEnqueueAnchors())
			usedEnqueueAnchors[anchor] = true;

		string[] availableEnqueueAnchors;
		bool[string] availableSeen;
		foreach (ref fid; forkIds)
		{
			if (!fid.isUser || !isEnqueueAnchor(fid.id))
				continue;
			if (fid.id in usedEnqueueAnchors)
				continue;
			if (fid.id in availableSeen)
				continue;
			availableSeen[fid.id] = true;
			availableEnqueueAnchors ~= fid.id;
		}

		tracef("[jsonl] resolvePendingAssignments tid=%d pending=%d availableEnqueue=%d",
			tid, pendingSeqs.length, availableEnqueueAnchors.length);
		UuidAssignment[] result;
		size_t enqueueIdx = 0;
		foreach (seq; pendingSeqs)
		{
			if (enqueueIdx >= availableEnqueueAnchors.length)
				break;
			auto anchor = availableEnqueueAnchors[enqueueIdx++];
			if (td.resolveVisibleTurnAnchor(seq, anchor))
			{
				if (onAnchorResolved !is null)
					onAnchorResolved(tid, seq, anchor);
				result ~= UuidAssignment(anchor, seq);
			}
		}
		tracef("[jsonl] resolvePendingAssignments tid=%d result=%d", tid, result.length);
		return result;
	}
}

unittest
{
	import std.algorithm : canFind;

	TaskData td = TaskData(1);
	td.registerVisibleTurnAnchor(4, true, false, "user-one", "user-one", false);
	td.registerVisibleTurnAnchor(13, true, true, null, "raw-steering", true);

	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) null;
	tracker.getTask = (int tid) => tid == 1 ? &td : null;
	tracker.sendToSubscribed = (int, string) {};

	ForkableIdInfo[] forkIds = [
		ForkableIdInfo("user-one", true),
		ForkableIdInfo("enqueue-22", true),
		ForkableIdInfo("raw-steering", true),
	];
	auto assignments = tracker.resolvePendingAssignments(1, forkIds);
	assert(assignments.length == 1);
	assert(assignments[0].seq == 13);
	assert(assignments[0].uuid == "enqueue-22");
	assert(td.resolvedVisibleAnchors().canFind("enqueue-22"));
}

unittest
{
	TaskData td = TaskData(1);
	td.registerVisibleTurnAnchor(13, true, true, null, "raw-steering", true);

	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) null;
	tracker.getTask = (int tid) => tid == 1 ? &td : null;
	tracker.sendToSubscribed = (int, string) {};
	int callbackCount;
	size_t callbackSeq;
	string callbackAnchor;
	tracker.onAnchorResolved = (int tid, size_t seq, string anchor)
	{
		assert(tid == 1);
		callbackCount++;
		callbackSeq = seq;
		callbackAnchor = anchor;
	};

	ForkableIdInfo[] forkIds = [
		ForkableIdInfo("enqueue-22", true),
	];
	auto assignments = tracker.resolvePendingAssignments(1, forkIds);
	assert(assignments.length == 1);
	assert(callbackCount == 1);
	assert(callbackSeq == 13);
	assert(callbackAnchor == "enqueue-22");
}

unittest
{
	import std.algorithm : sort;

	TaskData td = TaskData(1);
	td.registerVisibleTurnAnchor(2, true, false, "user-two", "user-two", false);
	td.registerVisibleTurnAnchor(10, true, true, "enqueue-3", null, false); // already resolved
	td.registerVisibleTurnAnchor(20, true, true, null, "raw-tool-only", true);
	td.registerVisibleTurnAnchor(30, true, true, null, "raw-meta", true);

	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) null;
	tracker.getTask = (int tid) => tid == 1 ? &td : null;
	tracker.sendToSubscribed = (int, string) {};

	// Extra raw user/assistant IDs (tool-result-only users, meta users, API-error
	// assistant lines) must not shift pending steering anchors.
	ForkableIdInfo[] forkIds = [
		ForkableIdInfo("tool-result-user-uuid", true),
		ForkableIdInfo("enqueue-3", true),   // already used, must be skipped
		ForkableIdInfo("assistant-api-error", false),
		ForkableIdInfo("enqueue-8", true),
		ForkableIdInfo("meta-user-uuid", true),
		ForkableIdInfo("enqueue-12", true),
	];

	auto assignments = tracker.resolvePendingAssignments(1, forkIds);
	assert(assignments.length == 2);
	assignments.sort!((a, b) => a.seq < b.seq);
	assert(assignments[0].seq == 20 && assignments[0].uuid == "enqueue-8");
	assert(assignments[1].seq == 30 && assignments[1].uuid == "enqueue-12");
}
