module cydo.export_;

import ae.utils.json : JSONFragment, toJson;

import cydo.agent.agent : Agent;
import cydo.agent.protocol : TaskEventSeqEnvelope, TranslatedEvent;
import cydo.persist : Persistence, loadTaskHistory;
import cydo.task : TypeInfoEntry;

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
string exportTaskData(ref Persistence persistence, Persistence.TaskRow[] taskRows,
	TypeInfoEntry[] typeInfo = null)
{
	import std.format : format;

	import cydo.agent.registry : agentRegistry;
	import cydo.task : extractEventFromEnvelope, extractTsFromEnvelope;

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
		string agent_type;
		long created_at;
		long last_active;
	}

	TaskExport[] taskExports;
	foreach (ref t; taskRows)
		taskExports ~= TaskExport(t.tid, t.title, t.status, t.parentTid,
			t.relationType, t.workspace, t.projectPath, t.taskType,
			t.agentType, t.createdAt, t.lastActive);

	// Cache agent instances by type
	Agent[string] agentCache;
	Agent getAgent(string agentType)
	{
		if (auto p = agentType in agentCache)
			return *p;
		foreach (ref entry; agentRegistry)
			if (entry.name == agentType)
			{
				auto a = entry.create();
				agentCache[agentType] = a;
				return a;
			}
		return null;
	}

	// Load history events for each task
	string[][string] eventsMap;
	foreach (ref t; taskRows)
	{
		if (t.agentSessionId.length == 0)
			continue;

		auto agent = getAgent(t.agentType);
		if (agent is null)
			continue;

		auto jsonlPath = agent.historyPath(t.agentSessionId, t.projectPath);
		if (jsonlPath.length == 0)
			continue;

		// Pre-compute rollback skip lines for Codex
		bool[int] rollbackSkipLines;
		if (t.agentType == "codex")
		{
			import std.file : exists, readText;
			if (exists(jsonlPath))
			{
				import cydo.agent.codex : computeRollbackSkipLines;
				rollbackSkipLines = computeRollbackSkipLines(readText(jsonlPath));
			}
		}

		agent.resetHistoryReplay();
		auto loaded = loadTaskHistory(t.tid, jsonlPath,
			delegate TranslatedEvent[](string line, int lineNum) {
				if (lineNum in rollbackSkipLines)
					return [];
				return agent.translateHistoryLine(line, lineNum);
			});

		string[] evList;
		foreach (i, ref msg; loaded.history)
		{
			auto envelope = cast(string) msg.unsafeContents;
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0)
				continue;
			auto ts = extractTsFromEnvelope(envelope);
			evList ~= toJson(TaskEventSeqEnvelope(t.tid, cast(int) i, ts,
				JSONFragment(event)));
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
