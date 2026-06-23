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
import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, byName;

TaskListEntry buildTaskEntry(ref TaskData td)
{
	const supportsEndingStop = td.session !is null && td.session.canStopAfterCloseStdin;
	const canStop = td.alive && (!td.stdinClosed || supportsEndingStop);
	return TaskListEntry(td.tid, td.alive,
		td.agentSessionId.length > 0 && !td.alive && td.status != "importable",
		td.isProcessing, td.stdinClosed, canStop, td.needsAttention, td.hasPendingQuestion, td.notificationBody,
		td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, td.status,
		td.taskType, td.entryPoint, td.agentType, td.archived, td.archiving, td.draft, td.error,
		stdTimeToUnixMillis(td.createdAt), stdTimeToUnixMillis(td.lastActive));
}

string buildTasksList(ref TaskData[int] tasksById)
{
	TaskListEntry[] entries;
	foreach (ref td; tasksById)
		entries ~= buildTaskEntry(td);
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
)
{
	TypeInfoEntry[] typeInfo;
	return toJson(TaskTypesListMessage(
		"task_types_list",
		buildEntryPointEntries(types, entryPoints, typeInfo),
		typeInfo,
		defaultTaskType,
	));
}

string buildTaskTypesListForProject(
	string projectPath,
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
)
{
	TypeInfoEntry[] typeInfo;
	return toJson(ProjectTaskTypesListMessage(
		"project_task_types_list",
		projectPath,
		buildEntryPointEntries(types, entryPoints, typeInfo),
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

string buildServerStatus(bool authEnabled, bool devMode, string webDistDir)
{
	return toJson(ServerStatusMessage(
		"server_status",
		authEnabled,
		devMode,
		readBuildId(webDistDir),
	));
}

string buildNoticesList(Notice[string] activeNotices)
{
	return toJson(NoticesListMessage("notices_list", activeNotices));
}

private EntryPointEntry[] buildEntryPointEntries(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
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
			entry.model_class = typeDef.model_class;
			entry.read_only = typeDef.read_only;
			entry.icon = typeDef.icon;
		}
		entries ~= entry;
	}
	foreach (ref def; types)
		typeInfo ~= TypeInfoEntry(def.name, def.icon);
	return entries;
}
