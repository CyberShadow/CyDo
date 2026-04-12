module cydo.jsonl;

import std.stdio : File;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.sys.inotify : INotify;
import ae.sys.timing : setTimeout, TimerTask;

import cydo.agent.agent : Agent, ForkableIdInfo;
import cydo.inotify : RefCountedINotify;
import cydo.task : AssignUuidsMessage, ForkableUuidsMessage, TaskData, UuidAssignment;

struct JsonlTracker
{
	Agent delegate(int tid) getAgent;
	TaskData* delegate(int tid) getTask;
	void delegate(string msg) broadcast;

	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private int[int] jsonlLineCount;
	private TimerTask[int] jsonlRetryTimers;

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	void startJsonlWatch(int tid)
	{
		import std.file : exists, mkdirRecurse;
		import std.path : baseName, dirName;

		auto td = getTask(tid);
		if (td is null)
			return;
		if (tid in jsonlWatches)
			return;
		if (td.agentSessionId.length == 0)
			return;

		auto jsonlPath = getAgent(tid).historyPath(td.agentSessionId, td.effectiveCwd);
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

		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;
		auto fileSize = getSize(jsonlPath);
		auto lastPos = jsonlReadPos.get(tid, 0);
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

		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; newContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		if (forkIds.length > 0)
			broadcastForkableUuidsWithAssignments(tid, forkIds);
	}

	/// Stop all JSONL watches (used during shutdown).
	void stopAllWatches()
	{
		foreach (tid; jsonlWatches.keys)
			stopJsonlWatch(tid);
		foreach (tid; jsonlRetryTimers.keys)
			stopJsonlWatch(tid);
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
		if (forkIds.length == 0)
			return;

		string[] uuids = forkIds.map!(f => f.id).array;
		ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)).representation));

		auto assignments = computeAssignments(tid, forkIds);
		if (assignments.length > 0)
			ws.send(Data(toJson(AssignUuidsMessage("assign_uuids", tid, assignments)).representation));
	}

	/// Broadcast forkable UUIDs from the full JSONL file to all clients.
	void broadcastForkableUuidsFromFile(int tid)
	{
		import std.file : exists, readText;

		auto td = getTask(tid);
		if (td is null)
			return;
		if (td.agentSessionId.length == 0)
			return;

		auto ta = getAgent(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;

		auto forkIds = ta.extractForkableIdsWithInfo(readText(jsonlPath));
		if (forkIds.length > 0)
			broadcastForkableUuidsWithAssignments(tid, forkIds);
	}

	/// Broadcast forkable UUIDs to all clients.
	void broadcastForkableUuids(int tid, string[] uuids)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));
	}

	/// Broadcast forkable UUIDs and their seq assignments to all clients.
	void broadcastForkableUuidsWithAssignments(int tid, ForkableIdInfo[] forkIds)
	{
		import std.algorithm : map;
		import std.array : array;
		import ae.utils.json : toJson;

		string[] uuids = forkIds.map!(f => f.id).array;
		broadcast(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));

		auto assignments = computeAssignments(tid, forkIds);
		if (assignments.length > 0)
			broadcast(toJson(AssignUuidsMessage("assign_uuids", tid, assignments)));
	}

	/// Compute seq→UUID assignments by correlating JSONL forkable IDs with history events.
	UuidAssignment[] computeAssignments(int tid, ForkableIdInfo[] forkIds)
	{
		import std.algorithm : canFind;

		auto td = getTask(tid);
		if (td is null) return null;

		// Count user and assistant events in history, recording their seqs
		size_t[] userSeqs, assistantSeqs;
		foreach (i, ref entry; td.history)
		{
			auto content = cast(string) entry.unsafeContents;
			// User message: item/started with user_message type
			if (content.canFind(`"item_type":"user_message"`) && content.canFind(`"type":"item/started"`))
				userSeqs ~= i;
			// Assistant turn: turn/stop
			else if (content.canFind(`"type":"turn/stop"`))
				assistantSeqs ~= i;
		}

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
		return result;
	}
}
