module cydo.web.snapshots;

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

TaskListEntry buildTaskEntry(ref TaskData td, bool alive, bool canStop, string driver)
{
	return TaskListEntry(td.tid, alive,
		td.agentSessionId.length > 0 && !alive && td.status != "importable",
		td.isProcessing, td.stdinClosed, canStop, td.needsAttention, td.hasPendingQuestion, td.notificationBody,
		td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, cast(string) td.status,
		td.taskType, td.entryPoint, td.agentName, driver, td.archived, td.archiving, td.draft, td.error,
		stdTimeToUnixMillis(td.createdAt), stdTimeToUnixMillis(td.lastActive));
}

string buildTasksList(TaskListEntry[] entries)
{
	return toJson(TasksListMessage("tasks_list", entries));
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
