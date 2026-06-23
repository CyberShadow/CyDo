module cydo.workflow.discovery.service;

import std.algorithm : filter, startsWith;
import std.array : array;
import std.conv : to;
import std.file : exists;
import std.json : parseJSON;
import std.logger : tracef, warningf;
import std.path : relativePath;
import std.process : execute;

import ae.utils.promise : Promise, resolve;
import ae.utils.promise.concurrency : threadAsync;

import cydo.agent.contract : Agent, DiscoveredSession;
import cydo.runtime.config : CydoConfig;
import cydo.domain.storage.persistence : Persistence;
import cydo.runtime.launch.sandbox : buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	resolveSandboxForDiscovery;
import cydo.domain.tasks.model : ProjectInfo, WorkspaceInfo;

package(cydo):

struct DiscoveryTaskSnapshot
{
	int tid;
	int parentTid;
	string status;
	string agentSessionId;
	string agentType;
	string projectPath;
}

struct ImportableTaskSpec
{
	string projectPath;
	string agentName;
	string sessionId;
	string title;
	long lastActive;
}

struct DiscoveryServiceHost
{
	DiscoveryTaskSnapshot[int] delegate() snapshotTasks;
	Persistence.CacheRow[] delegate() loadSessionMetaCache;
	void delegate(scope void delegate() work) withMutationTransaction;
	string delegate(int tid) importableHistoryPath;
	void delegate(int tid) deleteImportableTask;
	void delegate(ImportableTaskSpec spec) createImportableTask;
	void delegate(WorkspaceInfo[] workspaces) broadcastWorkspaces;
	void delegate(bool active) broadcastScanStatus;
	void delegate(string agentType, string sessionId) deleteSessionMetaCacheEntry;
	void delegate(string agentType, string sessionId, long mtime, string projectPath,
		string title, bool hasMessages) upsertSessionMetaCache;
}

struct DiscoveryAgentEntry
{
	Agent agent;
	string driverName;
	string importAgentName;
}

struct DiscoveryScanInput
{
	DiscoveryAgentEntry[] agents;
	bool[string] knownSessionIds;
	Persistence.CacheRow[string] cacheMap;
	string[] knownProjectPaths;
}

struct ScannedSessionRecord
{
	string agentType;
	string importAgentName;
	string sessionId;
	long mtime;
	string enumProjectPath;
	string title;
	string projectPath;
	bool fromCache;
	bool hasMessages = true;
}

class DiscoveryService
{
	private DiscoveryServiceHost host_;
	private WorkspaceInfo[] workspacesInfo_;
	private bool scanInProgress_;
	private Promise!(ScannedSessionRecord[]) delegate(DiscoveryScanInput) runScan_;

	this(DiscoveryServiceHost host,
		Promise!(ScannedSessionRecord[]) delegate(DiscoveryScanInput) runScan = null)
	{
		host_ = host;
		runScan_ = runScan !is null ? runScan : (DiscoveryScanInput input) => runScanAsync(input);
	}

	@property ref WorkspaceInfo[] workspacesInfo()
	{
		return workspacesInfo_;
	}

	@property bool scanInProgress() const
	{
		return scanInProgress_;
	}

	void beginScan()
	{
		setScanInProgress(true);
	}

	void endScan()
	{
		setScanInProgress(false);
	}

	void discoverAllWorkspaces(CydoConfig config)
	{
		workspacesInfo_ = null;
		foreach (ref ws; config.workspaces)
		{
			auto sandbox = resolveSandboxForDiscovery(
				config.sandbox, ws.sandbox, ws.root, cydoBinaryDir());
			auto cmdPrefix = buildCommandPrefix(sandbox, "/");
			auto isProjectExpr = ws.project_discovery.is_project;
			auto recurseWhenExpr = ws.project_discovery.recurse_when;
			auto cmd = (cmdPrefix !is null ? cmdPrefix : []) ~ cydoBinaryPath
				~ ["discover", ws.root, ws.name, isProjectExpr, recurseWhenExpr]
				~ ws.exclude;

			typeof(execute(cmd)) result;
			try
				result = execute(cmd);
			catch (Exception e)
			{
				cleanup(sandbox);
				warningf("Discovery subprocess failed for workspace '%s': %s", ws.name, e.msg);
				workspacesInfo_ ~= WorkspaceInfo(ws.name, null, ws.default_agent, ws.default_task_type);
				continue;
			}
			cleanup(sandbox);

			if (result.status != 0)
			{
				warningf("Discovery failed for workspace '%s': exit %d", ws.name, result.status);
				workspacesInfo_ ~= WorkspaceInfo(ws.name, null, ws.default_agent, ws.default_task_type);
				continue;
			}

			ProjectInfo[] projInfos;
			try
			{
				auto json = parseJSON(result.output);
				foreach (entry; json.array)
					projInfos ~= ProjectInfo(entry["name"].str, entry["path"].str, false, true);
			}
			catch (Exception e)
				warningf("Discovery JSON parse failed for workspace '%s': %s", ws.name, e.msg);

			workspacesInfo_ ~= WorkspaceInfo(ws.name, projInfos, ws.default_agent, ws.default_task_type);

			tracef("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projInfos.length);
			foreach (ref p; projInfos)
				tracef("  - %s (%s)", p.name, p.path);
		}
		injectVirtualProjects(config, host_.snapshotTasks());
	}

	void enumerateSessions(CydoConfig config, Agent[string] agentsByName)
	{
		beginScan();

		auto taskSnapshot = host_.snapshotTasks();

		bool[string] knownSessionIds;
		foreach (ref td; taskSnapshot)
			if (td.agentSessionId.length > 0)
				knownSessionIds[td.agentType ~ "\0" ~ td.agentSessionId] = true;

		Persistence.CacheRow[string] cacheMap;
		foreach (row; host_.loadSessionMetaCache())
			cacheMap[row.agentType ~ "\0" ~ row.sessionId] = row;

		auto discoveryAgents = snapshotDiscoveryAgents(agentsByName);

		{
			int[] toDelete;
			foreach (ref td; taskSnapshot)
			{
				if (td.status != "importable")
					continue;
				try
				{
					auto historyPath = host_.importableHistoryPath(td.tid);
					if (historyPath.length == 0 || !exists(historyPath))
						toDelete ~= td.tid;
				}
				catch (Exception)
					toDelete ~= td.tid;
			}
			foreach (delTid; toDelete)
				host_.deleteImportableTask(delTid);
		}

		string[] cacheKeys = cacheMap.keys;

		string[] knownProjectPaths;
		foreach (ref wi; workspacesInfo_)
			foreach (ref pi; wi.projects)
				knownProjectPaths ~= pi.path;

		auto scanInput = DiscoveryScanInput(
			discoveryAgents,
			knownSessionIds,
			cacheMap,
			knownProjectPaths,
		);

		runScan_(scanInput).then((ScannedSessionRecord[] results) {
			bool[string] discoveredKeys;
			foreach (ref r; results)
				discoveredKeys[r.agentType ~ "\0" ~ r.sessionId] = true;

			host_.withMutationTransaction({
				foreach (key; cacheKeys)
					if (key !in discoveredKeys)
					{
						import std.string : indexOf;
						auto sep = key.indexOf('\0');
						if (sep >= 0)
							host_.deleteSessionMetaCacheEntry(key[0 .. sep], key[sep + 1 .. $]);
					}

				foreach (ref r; results)
				{
					bool alreadyKnown = false;
					foreach (ref td; host_.snapshotTasks())
						if (td.agentSessionId == r.sessionId && td.agentType == r.agentType)
						{
							alreadyKnown = true;
							break;
						}
					if (alreadyKnown)
						continue;

					string finalProjectPath = r.projectPath.length > 0 ? r.projectPath : r.enumProjectPath;

					if (!r.hasMessages)
					{
						if (!r.fromCache)
							host_.upsertSessionMetaCache(r.agentType, r.sessionId, r.mtime,
								finalProjectPath, r.title, false);
						continue;
					}

					string finalTitle = r.title.length > 0 ? r.title : "(untitled)";

					if (!r.fromCache)
						host_.upsertSessionMetaCache(r.agentType, r.sessionId, r.mtime,
							finalProjectPath, finalTitle, true);

					host_.createImportableTask(ImportableTaskSpec(
						finalProjectPath,
						r.importAgentName,
						r.sessionId,
						finalTitle,
						r.mtime,
					));
				}
			});

			refreshVirtualProjects(config);
			host_.broadcastWorkspaces(workspacesInfo_);
			endScan();
		}).ignoreResult();
	}

private:
	void setScanInProgress(bool active)
	{
		if (scanInProgress_ == active)
			return;
		scanInProgress_ = active;
		host_.broadcastScanStatus(active);
	}

	void refreshVirtualProjects(CydoConfig config)
	{
		foreach (ref wi; workspacesInfo_)
			wi.projects = wi.projects.filter!(p => !p.virtual_).array;
		workspacesInfo_ = workspacesInfo_
			.filter!(wi => wi.name != "" || wi.projects.length > 0)
			.array;
		injectVirtualProjects(config, host_.snapshotTasks());
	}

	void injectVirtualProjects(CydoConfig config, DiscoveryTaskSnapshot[int] tasks)
	{
		bool[string] seen;
		string[] taskPaths;
		foreach (ref td; tasks)
			if (td.parentTid == 0 && td.projectPath.length > 0 && td.projectPath !in seen)
			{
				seen[td.projectPath] = true;
				taskPaths ~= td.projectPath;
			}

		bool[string] coveredPaths;
		foreach (ref wi; workspacesInfo_)
			foreach (ref pi; wi.projects)
				coveredPaths[pi.path] = true;

		string[] orphanedPaths;
		foreach (projectPath; taskPaths)
		{
			if (projectPath in coveredPaths)
				continue;

			bool matched = false;
			foreach (ref ws; config.workspaces)
			{
				auto wsRoot = ws.root;
				if (projectPath == wsRoot || projectPath.startsWith(wsRoot ~ "/"))
				{
					matched = true;
					auto relName = relativePath(projectPath, wsRoot);
					auto vp = ProjectInfo(relName, projectPath, true, exists(projectPath));
					bool found = false;
					foreach (ref wi; workspacesInfo_)
						if (wi.name == ws.name)
						{
							wi.projects ~= vp;
							found = true;
							break;
						}
					if (!found)
						workspacesInfo_ ~= WorkspaceInfo(ws.name, [vp], ws.default_agent, ws.default_task_type);
				}
			}
			if (!matched)
				orphanedPaths ~= projectPath;
		}

		if (orphanedPaths.length == 0)
			return;

		WorkspaceInfo* synthWs = null;
		foreach (ref wi; workspacesInfo_)
			if (wi.name == "")
			{
				synthWs = &wi;
				break;
			}

		if (synthWs is null)
		{
			workspacesInfo_ ~= WorkspaceInfo("", null, "", "");
			synthWs = &workspacesInfo_[$ - 1];
		}

		bool[string] synthCovered;
		foreach (ref pi; synthWs.projects)
			synthCovered[pi.path] = true;

		foreach (projectPath; orphanedPaths)
			if (projectPath !in synthCovered)
				synthWs.projects ~= ProjectInfo(projectPath, projectPath, true, exists(projectPath));
	}

	static DiscoveryAgentEntry[] snapshotDiscoveryAgents(Agent[string] agentsByName)
	{
		DiscoveryAgentEntry[] entries;
		bool[string] seenDriver;
		foreach (name, agent; agentsByName)
		{
			auto driverName = to!string(agent.driver);
			if (driverName in seenDriver)
				continue;
			seenDriver[driverName] = true;
			entries ~= DiscoveryAgentEntry(agent, driverName, name);
		}
		return entries;
	}

	static Promise!(ScannedSessionRecord[]) runScanAsync(DiscoveryScanInput input)
	{
		return threadAsync({
			ScannedSessionRecord[] results;
			foreach (entry; input.agents)
			{
				DiscoveredSession[] discovered;
				try
					discovered = entry.agent.enumerateAllSessions();
				catch (Exception e)
				{
					warningf("enumerateSessions: error enumerating %s sessions: %s",
						entry.driverName, e.msg);
					continue;
				}

				foreach (ref ds; discovered)
				{
					auto compositeKey = entry.driverName ~ "\0" ~ ds.sessionId;
					if (compositeKey in input.knownSessionIds)
						continue;

					auto cachedp = compositeKey in input.cacheMap;

					ScannedSessionRecord record;
					record.agentType = entry.driverName;
					record.importAgentName = entry.importAgentName;
					record.sessionId = ds.sessionId;
					record.mtime = ds.mtime;
					record.enumProjectPath = ds.projectPath.length > 0
						? ds.projectPath
						: entry.agent.matchProject(ds.sessionId, input.knownProjectPaths);

					if (cachedp !is null && cachedp.mtime == ds.mtime)
					{
						record.title = cachedp.title;
						record.projectPath = cachedp.projectPath;
						record.hasMessages = cachedp.hasMessages;
						record.fromCache = true;
					}
					else
					{
						try
						{
							auto meta = entry.agent.readSessionMeta(ds.sessionId);
							record.title = meta.title;
							record.projectPath = meta.projectPath;
							record.hasMessages = meta.hasMessages;
						}
						catch (Exception e)
							warningf("enumerateSessions: error reading meta for %s/%s: %s",
								entry.driverName, ds.sessionId, e.msg);
						record.fromCache = false;
					}
					results ~= record;
				}
			}
			return results;
		});
	}
}

unittest
{
	DiscoveryTaskSnapshot[int] tasks;
	auto service = new DiscoveryService(DiscoveryServiceHost(
		snapshotTasks: () => tasks,
		loadSessionMetaCache: () => Persistence.CacheRow[].init,
		withMutationTransaction: (scope void delegate() work) => work(),
		importableHistoryPath: (int tid) => "",
		deleteImportableTask: (int tid) {},
		createImportableTask: (ImportableTaskSpec spec) {},
		broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
		broadcastScanStatus: (bool active) {},
		deleteSessionMetaCacheEntry: (string agentType, string sessionId) {},
		upsertSessionMetaCache: (string agentType, string sessionId, long mtime,
			string projectPath, string title, bool hasMessages) {},
	));

	tasks[1] = DiscoveryTaskSnapshot(1, 0, "", "", "", "/tmp/other");
	tasks[2] = DiscoveryTaskSnapshot(2, 1, "", "", "", "/tmp/ws/.cydo/tasks/42/worktree");

	CydoConfig config;
	service.discoverAllWorkspaces(config);

	bool foundOther = false;
	bool foundWorktree = false;
	foreach (ref wi; service.workspacesInfo)
		foreach (ref pi; wi.projects)
		{
			if (pi.path == "/tmp/other")
				foundOther = true;
			if (pi.path == "/tmp/ws/.cydo/tasks/42/worktree")
				foundWorktree = true;
		}
	assert(foundOther, "virtual project for root task path must exist");
	assert(!foundWorktree, "virtual project for subtask worktree path must not exist");
}

unittest
{
	import std.exception : assertNotThrown;
	import ae.net.asockets : socketManager;

	int createCount;
	bool[] scanTransitions;
	int snapshotCount;

	DiscoveryTaskSnapshot[int] knownTasks;
	auto service = new DiscoveryService(
		DiscoveryServiceHost(
			snapshotTasks: () {
				snapshotCount++;
				if (snapshotCount == 1)
				{
					DiscoveryTaskSnapshot[int] emptyTasks;
					return emptyTasks;
				}
				return knownTasks;
			},
			loadSessionMetaCache: () => Persistence.CacheRow[].init,
			withMutationTransaction: (scope void delegate() work) => work(),
			importableHistoryPath: (int tid) => "",
			deleteImportableTask: (int tid) {},
			createImportableTask: (ImportableTaskSpec spec) {
				createCount++;
			},
			broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
			broadcastScanStatus: (bool active) {
				scanTransitions ~= active;
			},
			deleteSessionMetaCacheEntry: (string agentType, string sessionId) {},
			upsertSessionMetaCache: (string agentType, string sessionId, long mtime,
				string projectPath, string title, bool hasMessages) {},
		),
		(DiscoveryScanInput input) {
			ScannedSessionRecord[] results = [
				ScannedSessionRecord("claude", "claude", "session-1", 1, "", "Imported", "", false, true),
			];
			return resolve(results);
		},
	);

	knownTasks[1] = DiscoveryTaskSnapshot(1, 0, "completed", "session-1", "claude", "");

	Agent[string] agentsByName;
	service.enumerateSessions(CydoConfig.init, agentsByName);
	socketManager.loop().assertNotThrown;

	assert(createCount == 0, "enumerateSessions must re-check current tasks before import");
	assert(snapshotCount >= 2, "enumerateSessions must snapshot tasks again after scan");
	assert(scanTransitions == [true, false]);
}
