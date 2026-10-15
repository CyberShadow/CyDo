module cydo.web.snapshots;

import std.algorithm : sort;
import std.exception : enforce;
import std.file : exists, readText;
import std.logger : warningf;
import std.regex : matchFirst, regex;

import ae.utils.json : toJson;

import cydo.domain.tasks.model : AgentInfoEntry, AgentsListMessage, EntryPointEntry,
	NoticesListMessage, Notice, ProjectTaskTypesListMessage,
	ServerStatusMessage, TaskListEntry, TaskTypesListMessage,
	TasksListMessage, TaskData, TypeInfoEntry, WorkspaceInfo,
	WorkspacesListMessage, stdTimeToUnixMillis;
import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, byName,
	resolveModelClass;

TaskListEntry buildTaskEntry(ref TaskData td, size_t childCount, bool alive,
	bool canStop, string driver)
{
	return TaskListEntry(td.tid, alive,
		td.agentSessionId.length > 0 && !alive && td.status != "importable",
		td.isProcessing, td.stdinClosed, canStop, td.needsAttention, td.hasPendingQuestion, td.notificationBody,
		td.title, td.workspace, td.projectPath, td.parentTid, childCount, td.relationType, cast(string) td.status,
		td.taskType, td.entryPoint, td.agentName, driver, td.archived, td.archiving, td.draft, td.error,
		stdTimeToUnixMillis(td.createdAt), stdTimeToUnixMillis(td.lastActive));
}

string buildTasksList(TaskListEntry[] entries, bool complete)
{
	return toJson(TasksListMessage("tasks_list", complete, entries));
}

alias TaskListBuckets = TaskListEntry[][4];

TaskListBuckets partitionTaskListEntries(TaskListEntry[] entries)
{
	size_t[int] indexByTid;
	int[][int] childrenByParent;
	int[] roots;
	int[] tids;

	foreach (index, ref entry; entries)
	{
		enforce(entry.tid > 0, "Task list entry tid must be positive");
		enforce((entry.tid in indexByTid) is null,
			"Task list entries must not contain duplicate tids");
		indexByTid[entry.tid] = index;
		tids ~= entry.tid;
	}

	foreach (ref entry; entries)
	{
		if (entry.parent_tid <= 0)
		{
			roots ~= entry.tid;
			continue;
		}
		enforce(entry.parent_tid != entry.tid,
			"Task list entries must not parent themselves");
		if (entry.parent_tid in indexByTid)
			childrenByParent[entry.parent_tid] ~= entry.tid;
		else
			roots ~= entry.tid;
	}

	sort(roots);
	sort(tids);
	foreach (tid; tids)
		if (auto children = tid in childrenByParent)
			sort(*children);

	enum VisitState { unvisited, visiting, visited }
	VisitState[int] visitStates;
	void validateAcyclic(int tid)
	{
		auto state = visitStates.get(tid, VisitState.unvisited);
		if (state == VisitState.visiting)
		{
			enforce(false, "Task list entries must not contain parent cycles");
			return;
		}
		if (state == VisitState.visited)
			return;

		visitStates[tid] = VisitState.visiting;
		if (auto children = tid in childrenByParent)
			foreach (childTid; *children)
				validateAcyclic(childTid);
		visitStates[tid] = VisitState.visited;
	}
	foreach (tid; tids)
		validateAcyclic(tid);

	TaskListBuckets buckets;
	bool[int] emitted;
	void emit(int tid, bool ancestorArchived, bool aliveStageOneRoot,
		bool traversalRoot)
	{
		auto entry = entries[indexByTid[tid]];
		auto effectivelyArchived = ancestorArchived || entry.archived;
		auto stageOne = traversalRoot && entry.parent_tid <= 0
			&& !effectivelyArchived && entry.status != "importable";
		size_t bucketIndex;
		if (effectivelyArchived)
			bucketIndex = 3;
		else if (stageOne)
			bucketIndex = 0;
		else if (aliveStageOneRoot)
			bucketIndex = 1;
		else
			bucketIndex = 2;

		enforce((tid in emitted) is null,
			"Task list planner emitted a task more than once");
		emitted[tid] = true;
		buckets[bucketIndex] ~= entry;

		auto descendantAliveStageOneRoot = traversalRoot
			? stageOne && entry.alive
			: aliveStageOneRoot;
		if (auto children = tid in childrenByParent)
			foreach (childTid; *children)
				emit(childTid, effectivelyArchived, descendantAliveStageOneRoot, false);
	}
	foreach (rootTid; roots)
		emit(rootTid, false, false, true);

	enforce(emitted.length == entries.length,
		"Task list planner did not emit every task exactly once");
	return buckets;
}

string[4] buildTasksListPackets(TaskListEntry[] entries)
{
	auto buckets = partitionTaskListEntries(entries);
	string[4] packets;
	foreach (index, bucket; buckets)
		packets[index] = buildTasksList(bucket, index + 1 == packets.length);
	return packets;
}

string buildWorkspacesList(WorkspaceInfo[] workspacesInfo)
{
	return toJson(WorkspacesListMessage("workspaces_list", workspacesInfo));
}

string buildTaskTypesList(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string defaultTaskType,
	string workspace = "",
	string defaultAgent = "",
	string[] agents = null,
)
{
	TypeInfoEntry[] typeInfo;
	return toJson(TaskTypesListMessage(
		"task_types_list",
		buildEntryPointEntries(types, entryPoints, workspace, defaultAgent, agents, typeInfo),
		typeInfo,
		defaultTaskType,
	));
}

string buildTaskTypesListForProject(
	string projectPath,
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string workspace = "",
	string defaultAgent = "",
	string[] agents = null,
)
{
	TypeInfoEntry[] typeInfo;
	return toJson(ProjectTaskTypesListMessage(
		"project_task_types_list",
		projectPath,
		buildEntryPointEntries(types, entryPoints, workspace, defaultAgent, agents, typeInfo),
		typeInfo,
	));
}

string buildAgentsList(AgentInfoEntry[] entries, string defaultAgent)
{
	return toJson(AgentsListMessage("agents_list", entries, defaultAgent));
}

string readBuildId(string webDistDir)
{
	auto indexHtml = webDistDir ~ "index.html";
	if (!exists(indexHtml))
		return "";
	auto content = readText(indexHtml);
	auto m = matchFirst(content, regex(`/assets/index-([A-Za-z0-9_-]+)\.js`));
	if (m.empty)
	{
		warningf("Could not extract build id from %s", indexHtml);
		return "";
	}
	return m[1].idup;
}

string buildServerStatus(bool authEnabled, bool devMode, string webDistDir,
	int historyWindowDesktop = 0, int historyWindowMobile = 0)
{
	return toJson(ServerStatusMessage(
		"server_status",
		authEnabled,
		devMode,
		readBuildId(webDistDir),
		historyWindowDesktop,
		historyWindowMobile,
	));
}

string buildNoticesList(Notice[string] activeNotices)
{
	return toJson(NoticesListMessage("notices_list", activeNotices));
}

private EntryPointEntry[] buildEntryPointEntries(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string workspace,
	string defaultAgent,
	string[] agents,
	out TypeInfoEntry[] typeInfo,
)
{
	EntryPointEntry[] entries;
	foreach (ref ep; entryPoints)
	{
		auto typeDef = types.byName(ep.resolvedType);
		EntryPointEntry entry;
		entry.name = ep.name;
		entry.task_type = ep.resolvedType;
		entry.description = ep.description;
		if (typeDef !is null)
		{
			entry.model_class = resolveModelClass(typeDef.model_class, workspace, defaultAgent);
			foreach (agent; agents)
				entry.model_classes[agent] = resolveModelClass(typeDef.model_class,
					workspace, agent);
			entry.read_only = typeDef.read_only;
			entry.icon = typeDef.icon;
		}
		entries ~= entry;
	}
	foreach (ref def; types)
		typeInfo ~= TypeInfoEntry(def.name, def.icon);
	return entries;
}

unittest
{
	import std.algorithm : canFind;

	TaskTypeDef type;
	type.name = "conversation";
	type.model_class = "{{ 'best' if agent == 'claude-personal' else 'large' }}";
	UserEntryPointDef entryPoint;
	entryPoint.name = "agentic";
	entryPoint.task_type = type.name;
	entryPoint.description = "Agentic";

	auto personal = buildTaskTypesList([type], [entryPoint], "agentic", "home",
		"claude-personal", ["claude-personal", "codex"]);
	assert(personal.canFind(`"model_class":"best"`), personal);
	assert(personal.canFind(`"model_classes":{"claude-personal":"best","codex":"large"}`)
		|| personal.canFind(`"model_classes":{"codex":"large","claude-personal":"best"}`),
		personal);
	auto codex = buildTaskTypesList([type], [entryPoint], "agentic", "work", "codex");
	assert(codex.canFind(`"model_class":"large"`), codex);
}

unittest
{
	import std.algorithm : canFind;
	import std.exception : assertThrown;

	TaskListEntry entry(int tid, int parentTid = 0, bool alive = false,
		bool archived = false, string status = "completed", size_t childCount = 0)
	{
		TaskListEntry result;
		result.tid = tid;
		result.parent_tid = parentTid;
		result.alive = alive;
		result.archived = archived;
		result.status = status;
		result.childCount = childCount;
		return result;
	}

	int[] bucketTids(TaskListEntry[] bucket)
	{
		int[] result;
		foreach (task; bucket)
			result ~= task.tid;
		return result;
	}

	auto exact = buildTasksList([entry(1, 0, false, false, "completed", 2)], true);
	assert(exact == `{"type":"tasks_list","complete":true,"tasks":[{"tid":1,"alive":false,"resumable":false,"isProcessing":false,"stdinClosed":false,"canStop":false,"needsAttention":false,"hasPendingQuestion":false,"notificationBody":null,"title":null,"workspace":null,"project_path":null,"parent_tid":0,"child_count":2,"relation_type":null,"status":"completed","task_type":null,"entry_point":null,"agent_name":null,"driver":null,"archived":false,"archiving":false,"draft":null,"error":null,"created_at":0,"last_active":0}]}`,
		exact);
	assert(!exact.canFind(`"stage"`), exact);
	assert(buildTasksList([], false).canFind(`"complete":false`));

	auto entries = [
		entry(21, 20, false, false, "completed", 0),
		entry(4, 1, false, true, "completed", 0),
		entry(13, 999, false, false, "completed", 0),
		entry(3, 2, false, false, "completed", 0),
		entry(20, 0, false, true, "completed", 1),
		entry(12, 0, false, false, "importable", 0),
		entry(11, 10, false, false, "completed", 0),
		entry(10, 0, false, false, "completed", 1),
		entry(2, 1, false, false, "completed", 1),
		entry(1, 0, true, false, "completed", 2),
	];
	auto buckets = partitionTaskListEntries(entries);
	assert(bucketTids(buckets[0]) == [1, 10]);
	assert(bucketTids(buckets[1]) == [2, 3]);
	assert(bucketTids(buckets[2]) == [11, 12, 13]);
	assert(bucketTids(buckets[3]) == [4, 20, 21]);
	assert(buckets[0][0].childCount == 2);
	assert(buckets[3][0].archived);
	assert(!buckets[3][2].archived,
		"Effective archive state must not replace the raw archived field");

	auto reordered = [
		entries[9], entries[8], entries[7], entries[6], entries[5],
		entries[4], entries[3], entries[2], entries[1], entries[0],
	];
	auto reorderedBuckets = partitionTaskListEntries(reordered);
	foreach (index; 0 .. buckets.length)
		assert(bucketTids(reorderedBuckets[index]) == bucketTids(buckets[index]));

	auto packets = buildTasksListPackets([]);
	assert(packets.length == 4);
	assert(packets[0].canFind(`"complete":false`));
	assert(packets[1].canFind(`"complete":false`));
	assert(packets[2].canFind(`"complete":false`));
	assert(packets[3].canFind(`"complete":true`));

	assertThrown!Exception(partitionTaskListEntries([entry(0)]));
	assertThrown!Exception(partitionTaskListEntries([entry(1), entry(1)]));
	assertThrown!Exception(partitionTaskListEntries([entry(1, 1)]));
	assertThrown!Exception(partitionTaskListEntries([entry(1, 2), entry(2, 1)]));
}
