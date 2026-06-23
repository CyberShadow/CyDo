module cydo.workflow.tasks.derived_text;

import std.datetime : Clock;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.logger : tracef, warningf;
import std.path : buildPath;

import ae.sys.paths : getDataDir;
import ae.utils.json : jsonParse, toJson;

import cydo.agent.contract : Agent;
import cydo.domain.tasks.model : TaskData;
import cydo.workflow.history.abbrev : buildAbbreviatedHistoryFromStrings;

struct DerivedTextJobsHost
{
	TaskData* delegate(int tid) getTask;
	int[] delegate() snapshotTaskIds;
	Agent delegate(int tid) agentForTask;
	bool delegate(int tid) hasSubscribers;
	void delegate(int tid) ensureHistoryLoaded;
	string delegate(int tid, string relativePath, string[string] vars) readPromptFile;
	void delegate(int tid, string title) persistTitle;
	void delegate(int tid, string title) broadcastTitleUpdate;
	void delegate(int tid, string[] suggestions) broadcastSuggestionsUpdate;
	void delegate(int tid, string text) emitTitleGenerationFailure;
	bool delegate() devMode;
}

class DerivedTextJobs
{
private:
	DerivedTextJobsHost host_;

public:
	this(DerivedTextJobsHost host)
	{
		host_ = host;
	}

	void cancelAll()
	{
		foreach (tid; host_.snapshotTaskIds())
			cancelBackgroundWork(tid);
	}

	void cancelBackgroundWork(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (td.titleGenKill !is null)
		{
			td.titleGenKill();
			td.titleGenKill = null;
		}
		if (td.suggestGenKill !is null)
		{
			td.suggestGenKill();
			td.suggestGenKill = null;
		}
	}

	void clearSuggestions(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		td.lastSuggestions = null;
	}

	void discardInFlightSuggestions(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		td.suggestGenHandle = null;
		td.suggestGeneration++;
	}

	void invalidateSuggestions(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		td.lastSuggestions = null;
		td.suggestGeneration++;
		if (td.suggestGenKill !is null)
			td.suggestGenKill();
		td.suggestGenHandle = null;
		td.suggestGenKill = null;
	}

	void onHistorySubscribed(int tid)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, format!"History subscribe callback for missing task %d"(tid));
		if (td.suggestGenHandle is null && td.lastSuggestions.length == 0 && td.status == "alive")
			generateSuggestions(tid);
	}

	void generateTitle(int tid, string userMessage)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (td.titleGenDone || td.titleGenHandle !is null)
			return;

		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;
		auto prompt = host_.readPromptFile(tid, "prompts/generate-title.md",
			["user_message": msg]);
		if (prompt.length == 0)
			return;

		auto titleHandle = host_.agentForTask(tid).completeOneShot(prompt, "small", td.launch);
		td.titleGenHandle = titleHandle.promise;
		td.titleGenKill = titleHandle.cancel;
		td.titleGenHandle.then((string title) {
			auto task = host_.getTask(tid);
			if (task is null)
				return;
			task.titleGenHandle = null;
			task.titleGenKill = null;
			task.titleGenDone = true;
			if (title.length > 0 && title.length < 200)
			{
				task.title = title;
				host_.persistTitle(tid, title);
				host_.broadcastTitleUpdate(tid, title);
			}
		}).except((Exception e) {
			auto task = host_.getTask(tid);
			if (task is null)
				return;
			task.titleGenHandle = null;
			task.titleGenKill = null;
			host_.emitTitleGenerationFailure(tid,
				"failed to generate title: " ~ e.msg);
		}).ignoreResult();
	}

	void generateSuggestions(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;

		if (td.parentTid != 0)
			return;
		if (td.wasKilledByUser)
			return;
		if (td.suggestGenHandle !is null)
			return;
		if (!host_.hasSubscribers(tid))
		{
			tracef("generateSuggestions[%d]: no subscribers, skipping", tid);
			return;
		}

		host_.ensureHistoryLoaded(tid);
		td = host_.getTask(tid);
		assert(td !is null, format!"Suggestion generation requested for missing task %d"(tid));
		string[] envelopes;
		foreach (ref d; td.history)
			envelopes ~= cast(string) d.toGC();
		auto history = buildAbbreviatedHistoryFromStrings(envelopes);
		if (history.length == 0)
		{
			tracef("generateSuggestions[%d]: empty history, skipping", tid);
			return;
		}

		auto prompt = host_.readPromptFile(tid, "prompts/generate-suggestions.md",
			["conversation": history]);
		if (prompt.length == 0)
		{
			warningf("generateSuggestions[%d]: prompt file not found or empty", tid);
			return;
		}
		tracef("generateSuggestions[%d]: spawning one-shot (history.length=%d)", tid, history.length);

		string debugDir;
		if (host_.devMode())
		{
			auto now = Clock.currTime;
			debugDir = buildPath(getDataDir("cydo"),
				format("suggestion-debug/%04d-%02d-%02dT%02d:%02d:%02d-%d",
					now.year, cast(int) now.month, now.day,
					now.hour, now.minute, now.second, tid));
			mkdirRecurse(debugDir);

			string jsonlContent;
			foreach (ref d; td.history)
				jsonlContent ~= cast(string) d.toGC() ~ "\n";
			write(debugDir ~ "/context.jsonl", jsonlContent);

			static struct DebugMeta
			{
				int tid;
				string agentType;
				string taskType;
				string timestamp;
			}

			auto timestamp = format("%04d-%02d-%02dT%02d:%02d:%02d",
				now.year, cast(int) now.month, now.day,
				now.hour, now.minute, now.second);
			write(debugDir ~ "/meta.json",
				toJson(DebugMeta(tid, td.agentType, td.taskType, timestamp)));
		}

		td.suggestGeneration++;
		auto capturedGen = td.suggestGeneration;

		auto suggestHandle = host_.agentForTask(tid).completeOneShot(prompt, "small", td.launch);
		td.suggestGenHandle = suggestHandle.promise;
		td.suggestGenKill = suggestHandle.cancel;
		td.suggestGenHandle.then((string result) {
			auto task = host_.getTask(tid);
			if (task is null)
				return;
			if (task.suggestGeneration != capturedGen)
				return;
			task.suggestGenHandle = null;
			task.suggestGenKill = null;

			if (debugDir.length)
			{
				write(debugDir ~ "/input.txt", prompt);
				write(debugDir ~ "/output.txt", result);
			}

			string[] suggestionList;
			try
				suggestionList = jsonParse!(string[])(result);
			catch (Exception e)
			{
				warningf("generateSuggestions: failed to parse result: %s\n---\n%s\n---",
					e.msg, result);
				host_.broadcastSuggestionsUpdate(tid, []);
				return;
			}

			task.lastSuggestions = suggestionList;
			host_.broadcastSuggestionsUpdate(tid, suggestionList);
		}).except((Exception e) {
			warningf("generateSuggestions[%d]: one-shot failed: %s", tid, e.msg);
			auto task = host_.getTask(tid);
			if (task is null)
				return;
			task.suggestGenHandle = null;
			task.suggestGenKill = null;
			if (debugDir.length)
			{
				write(debugDir ~ "/input.txt", prompt);
				write(debugDir ~ "/error.txt", e.msg);
			}
		}).ignoreResult();
	}
}
