module cydo.workflow.exporter.html;

import std.conv : to;

import ae.utils.json : JSONFragment, toJson;

import cydo.agent.contract : Agent, DriverHistory, DriverHistoryLaunch,
	DriverServedHistoryAgent, SessionConfig;
import cydo.agent.resolver : tryCreateConfiguredAgent;
import cydo.runtime.config : AgentDriver, CydoConfig;
import cydo.protocol : TaskEventSeqEnvelope, TranslatedEvent;
import cydo.domain.storage.persistence : Persistence;
import cydo.domain.tasks.model : TaskData, TypeInfoEntry, stdTimeToUnixMillis;
import cydo.workflow.history.jsonl_store : loadTaskHistory;
import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
	HistoryAccess, ResolvedNativeHistoryContext, resolveNativeHistoryContext;
import cydo.workflow.workspace.task_path_resolver : TaskPathResolver;

/// The events of a task whose agent serves its history itself. The export
/// has no sessions: the driver starts a process of its own for the read, and
/// the event loop runs until that read has settled and the process is gone.
private string[] driverServedEvents(DriverServedHistoryAgent driver,
	ref Persistence.TaskRow t, ResolvedNativeHistoryContext resolved)
{
	import ae.net.asockets : socketManager;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch;
	import cydo.runtime.launch.types : ProcessLaunch;

	ProcessLaunch launch;
	bool launched;
	DriverHistory history;
	Exception failure;
	driver.loadHistory(t.agentSessionId, resolved.profile, () => null, () {
		launch = prepareProcessLaunch(resolved.sandbox, resolved.rule, resolved.profile,
			"", driver.executableName(resolved.sandbox.env));
		launched = true;
		SessionConfig config;
		config.workspace = t.workspace;
		return DriverHistoryLaunch(launch, config);
	}).then((DriverHistory loaded) { history = loaded; },
		(Exception e) { failure = e; }).ignoreResult();
	socketManager.loop();
	if (launched)
		cleanup(launch.sandbox);
	if (failure !is null)
		throw new Exception("Cannot export task " ~ t.tid.to!string
			~ ": session history is unavailable: " ~ failure.msg);

	string[] events;
	foreach (i, ref event; history.events)
		events ~= toJson(TaskEventSeqEnvelope(t.tid, cast(int) i, event.ts.stdTime,
			JSONFragment(event.translated)));
	return events;
}

/// Recursively collect all tasks reachable from rootTids via parent_tid.
/// Returns the deduplicated set (roots + all descendants).
Persistence.TaskRow[] collectTaskTree(ref Persistence persistence, int[] rootTids)
{
	auto allTasks = persistence.loadTasks();

	// Build tid → TaskRow index
	Persistence.TaskRow[int] byTid;
	foreach (ref t; allTasks)
		byTid[t.tid] = t;

	// Build parent → children map (using parent_tid column)
	int[][int] children;
	foreach (ref t; allTasks)
		if (t.parentTid != 0)
			children.require(t.parentTid) ~= t.tid;

	// BFS from rootTids collecting all descendants
	bool[int] visited;
	int[] queue;
	foreach (tid; rootTids)
		if (tid in byTid && tid !in visited)
		{
			visited[tid] = true;
			queue ~= tid;
		}

	Persistence.TaskRow[] result;
	while (queue.length > 0)
	{
		auto tid = queue[0];
		queue = queue[1 .. $];
		result ~= byTid[tid];
		if (auto ch = tid in children)
			foreach (childTid; *ch)
				if (childTid !in visited)
				{
					visited[childTid] = true;
					queue ~= childTid;
				}
	}
	return result;
}

/// Serialize task metadata and event history as the export JSON blob.
/// Format: {"tasks": [...], "events": {"<tid>": [TaskEventSeqEnvelope, ...]}, "typeInfo": [...]}
string exportTaskData(Persistence.TaskRow[] taskRows, ref CydoConfig config,
	TaskData[int]* allTasks, TaskPathResolver taskPathResolver,
	TypeInfoEntry[] typeInfo = null)
{
	import std.format : format;

	import cydo.domain.tasks.model : extractEventFromEnvelope, extractTsFromEnvelope;

	// Serialize task metadata
	static struct TaskExport
	{
		int tid;
		string title;
		string status;
		int parent_tid;
		string relation_type;
		string workspace;
		string project_path;
		string task_type;
		string agent_name;
		string driver;  // resolved runtime driver; empty for orphaned agents
		long created_at;
		long last_active;
	}

	// Cache agent instances by configured name
	Agent[string] agentCache;
	Agent getAgent(string agentName)
	{
		if (auto p = agentName in agentCache)
			return *p;
		auto a = tryCreateConfiguredAgent(config, agentName);
		if (a !is null)
		{
			agentCache[agentName] = a;
			return a;
		}
		return null;
	}

	TaskExport[] taskExports;
	foreach (ref t; taskRows)
	{
		import std.conv : to;

		auto agent = getAgent(t.agentName);
		taskExports ~= TaskExport(t.tid, t.title, t.status, t.parentTid,
			t.relationType, t.workspace, t.projectPath, t.taskType,
			t.agentName, agent is null ? "" : to!string(agent.driver),
			stdTimeToUnixMillis(t.createdAt), stdTimeToUnixMillis(t.lastActive));
	}

	// Load history events for each task
	string[][string] eventsMap;
	foreach (ref t; taskRows)
	{
		if (t.agentSessionId.length == 0)
			continue;

		auto agent = getAgent(t.agentName);
		if (agent is null)
			throw new Exception("Cannot export task " ~ t.tid.to!string
				~ ": configured agent '" ~ t.agentName ~ "' is unavailable");
		auto td = t.tid in *allTasks;
		if (td is null)
			throw new Exception("Cannot export task " ~ t.tid.to!string
				~ ": task context is unavailable");
		auto context = ConfiguredNativeHistoryContext(t.agentName, t.workspace,
			(*td).repoPath, false);
		auto resolved = resolveNativeHistoryContext(config, agent, context);
		if (auto driver = HistoryAccess.driverServingHistory(agent))
		{
			eventsMap[format!"%d"(t.tid)] = driverServedEvents(driver, t, resolved);
			continue;
		}
		auto jsonlPath = agent.historyPath(t.agentSessionId, resolved.profile);
		import std.file : exists, isFile;
		import std.path : isAbsolute;
		import std.stdio : File;
		if (jsonlPath.length == 0 || !isAbsolute(jsonlPath) || !exists(jsonlPath)
			|| !isFile(jsonlPath))
			throw new Exception("Cannot export task " ~ t.tid.to!string
				~ ": session history is unavailable");
		try
		{
			auto file = File(jsonlPath, "r");
		}
		catch (Exception)
			throw new Exception("Cannot export task " ~ t.tid.to!string
				~ ": session history is unreadable");

		import std.file : readText;
		auto inactiveLines = agent.inactiveHistoryLines(readText(jsonlPath));

		auto replay = agent.createHistoryReplay();
		auto loaded = loadTaskHistory(t.tid, jsonlPath,
			delegate TranslatedEvent[](string line, int lineNum) {
				if (lineNum in inactiveLines)
					return [];
				return replay.translateHistoryLine(line, lineNum);
			}, ulong.max, replay.finishHistoryReplay);

		string[] evList;
		foreach (i, ref msg; loaded.history)
		{
			import ae.utils.array : as;
			msg.enter((scope ubyte[] bytes) {
				// `as!(char[])` is a no-copy view; `as!string` would hard-cast to immutable.
				auto envelope = bytes.as!(char[]);
				auto event = extractEventFromEnvelope(envelope);
				if (event.length == 0)
					return;
				auto ts = extractTsFromEnvelope(envelope);
				// idup so the JSONFragment slice doesn't reference scope-bound bytes.
				evList ~= toJson(TaskEventSeqEnvelope(t.tid, cast(int) i, ts,
					JSONFragment(event.idup)));
			});
		}
		eventsMap[format!"%d"(t.tid)] = evList;
	}

	// Build events JSON object manually
	import std.array : join;
	string eventsJson = "{";
	bool firstEntry = true;
	foreach (tidStr, evList; eventsMap)
	{
		if (!firstEntry)
			eventsJson ~= ",";
		firstEntry = false;
		eventsJson ~= toJson(tidStr) ~ ":[" ~ evList.join(",") ~ "]";
	}
	eventsJson ~= "}";

	return `{"tasks":` ~ toJson(taskExports) ~ `,"events":` ~ eventsJson
		~ `,"typeInfo":` ~ toJson(typeInfo) ~ `}`;
}

unittest
{
	import std.datetime : SysTime, UTC;
	import std.json : parseJSON;

	Persistence.TaskRow row;
	row.tid = 1;
	row.createdAt = SysTime.fromUnixTime(1_700_000_000, UTC()).stdTime + 1_230_000;
	row.lastActive = SysTime.fromUnixTime(1_700_000_001, UTC()).stdTime + 4_560_000;

	CydoConfig config;
	auto task = parseJSON(exportTaskData([row], config, null, null))["tasks"].array[0];
	assert(task["created_at"].integer == 1_700_000_000_123);
	assert(task["last_active"].integer == 1_700_000_001_456);

	row.lastActive = 0;
	task = parseJSON(exportTaskData([row], config, null, null))["tasks"].array[0];
	assert(task["last_active"].integer == 0);
}

/// Read the export HTML template and inject jsonData by replacing
/// the __CYDO_EXPORT_DATA__ placeholder. Escapes </script> sequences
/// in the data to prevent breaking the script block.
string buildExportHtml(string templatePath, string jsonData)
{
	import std.file : readText;
	import std.string : replace;

	auto html = readText(templatePath);
	auto escaped = jsonData.replace("</script>", `<\/script>`);
	return html.replace("__CYDO_EXPORT_DATA__", escaped);
}
