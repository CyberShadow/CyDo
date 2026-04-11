module cydo.jsonl;

import std.stdio : File;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.sys.inotify : INotify;

import cydo.agent.agent : Agent;
import cydo.inotify : RefCountedINotify;
import cydo.task : ForkableUuidsMessage, TaskData;

struct JsonlTracker
{
	Agent delegate(int tid) getAgent;
	TaskData* delegate(int tid) getTask;
	void delegate(string msg) broadcast;

	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private int[int] jsonlLineCount;

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
			return;

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
		auto uuids = getAgent(tid).extractForkableIds(newContent, lineOffset);

		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; newContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		if (uuids.length > 0)
			broadcastForkableUuids(tid, uuids);
	}

	/// Stop all JSONL watches (used during shutdown).
	void stopAllWatches()
	{
		foreach (tid; jsonlWatches.keys)
			stopJsonlWatch(tid);
	}

	/// Stop watching the JSONL file for a task.
	void stopJsonlWatch(int tid)
	{
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
		import std.file : exists, readText;
		import ae.utils.json : toJson;

		auto jsonlPath = getAgent(tid).historyPath(agentSessionId, projectPath);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;

		auto content = readText(jsonlPath);
		auto uuids = getAgent(tid).extractForkableIds(content);
		if (uuids.length > 0)
			ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)).representation));
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

		auto uuids = ta.extractForkableIds(readText(jsonlPath));
		if (uuids.length > 0)
			broadcastForkableUuids(tid, uuids);
	}

	/// Broadcast forkable UUIDs to all clients.
	void broadcastForkableUuids(int tid, string[] uuids)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));
	}
}
