module cydo.workflow.discovery.service;

import std.algorithm : filter, startsWith;
import std.array : array;
import std.conv : to;
import std.file : exists, isFile;
import std.format : format;
import std.json : parseJSON;
import std.logger : tracef, warningf;
import std.path : isAbsolute, relativePath;
import std.process : execute;
import std.stdio : File;

import ae.utils.promise : Promise, resolve;
import ae.utils.promise.concurrency : threadAsync;

import cydo.agent.resolver : isConfiguredAgentName, resolveConfiguredAgent;
import cydo.agent.contract : Agent, DiscoveredSession;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig;
import cydo.domain.storage.persistence : Persistence;
import cydo.foundation.platform.path : bestEffortProjectPathIdentity, canonicalProjectPath;
import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
	ResolvedNativeHistoryContext;
import cydo.runtime.launch.types : NativeHistoryProfile;
import cydo.runtime.launch.sandbox : buildCommandPrefix, cleanup, cydoBinaryPath,
	resolveSandboxForDiscovery;
import cydo.domain.tasks.model : ProjectInfo, WorkspaceInfo;

package(cydo):

struct DiscoveryTaskSnapshot
{
	int tid;
	int parentTid;
	string status;
	string agentSessionId;
	string agentName;
	string workspace;
	string projectPath;
}

struct NativeSessionKey
{
	AgentDriver driver;
	string profileRoot;
	string sessionId;
}

struct ImportableScanRecord
{
	NativeSessionKey key;
	DiscoveredSession discovered;
	string agentName;
	ConfiguredNativeHistoryContext[] producingContexts;
	ulong scanGeneration;
}

struct ImportableTaskSpec
{
	string projectPath;
	string agentName;
	string title;
	long lastActive;
	ImportableScanRecord scanRecord;
}

alias ImportableReconciliationCommit = void delegate();

struct DiscoveryServiceHost
{
	DiscoveryTaskSnapshot[int] delegate() snapshotTasks;
	ConfiguredNativeHistoryContext[] delegate() snapshotNativeHistoryContexts;
	Agent delegate(string agentName) tryConfiguredAgent;
	ResolvedNativeHistoryContext delegate(Agent agent,
		const ref ConfiguredNativeHistoryContext context)
		resolveCurrentNativeHistoryContext;
	Persistence.CacheRow[] delegate() loadSessionMetaCache;
	void delegate(scope void delegate() work) withMutationTransaction;
	ImportableReconciliationCommit delegate(ulong scanGeneration,
		ImportableTaskSpec[] desired)
		reconcileImportableTasks;
	void delegate(WorkspaceInfo[] workspaces) broadcastWorkspaces;
	void delegate(bool active) broadcastScanStatus;
	void delegate(string driverName, string profileRoot, string sessionId)
		deleteSessionMetaCacheEntry;
	void delegate(string driverName, string profileRoot) deleteSessionMetaCacheGroup;
	void delegate(string driverName, string profileRoot, string sessionId,
		long mtime, string projectPath, string title, bool hasMessages)
		upsertSessionMetaCache;
}

private struct DiscoveryCandidate
{
	ConfiguredNativeHistoryContext context;
	Agent agent;
	ResolvedNativeHistoryContext resolved;
}

private struct DiscoveryGroup
{
	Agent agent;
	NativeHistoryProfile profile;
	string importAgentName;
	ConfiguredNativeHistoryContext[] producingContexts;
}

struct DiscoveryScanInput
{
	DiscoveryGroup[] groups;
	bool[string] knownSessionKeys;
	Persistence.CacheRow[string] cacheMap;
	ulong scanGeneration;
}

struct ScannedSessionRecord
{
	ImportableScanRecord scanRecord;
	long mtime;
	string title;
	string projectPath;
	bool fromCache;
	bool hasMessages = true;
}

struct DiscoveryScanOutput
{
	ScannedSessionRecord[] records;
	bool[string] failedGroupKeys;
}

class DiscoveryService
{
	private DiscoveryServiceHost host_;
	private WorkspaceInfo[] workspacesInfo_;
	private CydoConfig discoveryConfig_;
	private bool scanInProgress_;
	private ulong scanGeneration_;
	private Promise!DiscoveryScanOutput delegate(DiscoveryScanInput) runScan_;

	this(DiscoveryServiceHost host,
		Promise!DiscoveryScanOutput delegate(DiscoveryScanInput) runScan = null)
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
		discoveryConfig_ = config;
		workspacesInfo_ = null;
		foreach (ref ws; config.workspaces)
		{
			auto sandbox = resolveSandboxForDiscovery(
				config.sandbox, ws.sandbox, ws.root, ws.name);
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
				warningf("Discovery failed for workspace '%s': exit %d: %s", ws.name,
					result.status, result.output);
				workspacesInfo_ ~= WorkspaceInfo(ws.name, null, ws.default_agent, ws.default_task_type);
				continue;
			}

			ProjectInfo[] projInfos;
			try
			{
				auto json = parseJSON(result.output);
				foreach (entry; json.array)
					projInfos ~= ProjectInfo(entry["name"].str,
						canonicalProjectPath(entry["path"].str), false, true);
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

	void enumerateSessions()
	{
		++scanGeneration_;
		auto generation = scanGeneration_;
		beginScan();
		auto groups = buildDiscoveryGroups();
		auto knownSessionKeys = knownNativeSessionKeys(host_.snapshotTasks());

		Persistence.CacheRow[string] cacheMap;
		foreach (row; host_.loadSessionMetaCache())
			cacheMap[sessionKey(row.driverName, row.profileRoot, row.sessionId)] = row;

		bool[string] producedGroups;
		foreach (ref group; groups)
			producedGroups[groupKey(group.agent.driver, group.profile.root)] = true;

		auto scanInput = DiscoveryScanInput(
			groups,
			knownSessionKeys,
			cacheMap,
			generation,
		);

		runScan_(scanInput).then((DiscoveryScanOutput output) {
			if (generation != scanGeneration_)
				return;
			ScannedSessionRecord[] results;
			bool[string] currentByDiscoveredKey;
			foreach (ref result; output.records)
			{
				auto nativeKey = result.scanRecord.key;
				auto key = sessionKey(nativeKey);
				assert(key !in currentByDiscoveredKey,
					format("native session discovery returned duplicate session ID %s for %s/%s",
						nativeKey.sessionId, to!string(nativeKey.driver), nativeKey.profileRoot));
				auto current = scanRecordStillCurrent(result.scanRecord);
				currentByDiscoveredKey[key] = current;
				if (current)
					results ~= result;
			}

			ImportableReconciliationCommit commit;
			host_.withMutationTransaction({
				bool[string] deletedGroups;
				foreach (key, row; cacheMap)
				{
					auto cacheGroup = groupKey(row.driverName, row.profileRoot);
					if (cacheGroup !in producedGroups)
					{
						if (cacheGroup !in deletedGroups)
						{
							host_.deleteSessionMetaCacheGroup(row.driverName, row.profileRoot);
							deletedGroups[cacheGroup] = true;
						}
					}
					else if (cacheGroup !in output.failedGroupKeys
						&& !currentByDiscoveredKey.get(key, false))
						host_.deleteSessionMetaCacheEntry(row.driverName, row.profileRoot,
							row.sessionId);
				}

				auto currentKnownSessions = knownNativeSessionKeys(host_.snapshotTasks());
				ImportableTaskSpec[] desired;
				foreach (ref r; results)
				{
					auto key = sessionKey(r.scanRecord.key);
					if (key in currentKnownSessions)
						continue;

					string finalProjectPath = bestEffortProjectPathIdentity(r.projectPath);

					if (!r.hasMessages)
					{
						if (!r.fromCache)
							host_.upsertSessionMetaCache(to!string(r.scanRecord.key.driver),
								r.scanRecord.key.profileRoot, r.scanRecord.key.sessionId,
								r.mtime, finalProjectPath, r.title, false);
						continue;
					}

					string finalTitle = r.title.length > 0 ? r.title : "(untitled)";

					if (!r.fromCache)
						host_.upsertSessionMetaCache(to!string(r.scanRecord.key.driver),
							r.scanRecord.key.profileRoot, r.scanRecord.key.sessionId,
							r.mtime, finalProjectPath, finalTitle, true);

					desired ~= ImportableTaskSpec(
						finalProjectPath,
						r.scanRecord.agentName,
						finalTitle,
						r.mtime,
						r.scanRecord,
					);
					currentKnownSessions[key] = true;
				}
				commit = host_.reconcileImportableTasks(generation, desired);
			});
			if (commit !is null)
				commit();

			refreshVirtualProjects();
			host_.broadcastWorkspaces(workspacesInfo_);
			if (generation == scanGeneration_)
				endScan();
		}, (Exception e) {
			if (generation != scanGeneration_)
				return;
			warningf("native session discovery scan failed: %s", e.msg);
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

	void refreshVirtualProjects()
	{
		foreach (ref wi; workspacesInfo_)
			wi.projects = wi.projects.filter!(p => !p.virtual_).array;
		workspacesInfo_ = workspacesInfo_
			.filter!(wi => wi.name != "" || wi.projects.length > 0)
			.array;
		injectVirtualProjects(discoveryConfig_, host_.snapshotTasks());
	}

	void injectVirtualProjects(CydoConfig config, DiscoveryTaskSnapshot[int] tasks)
	{
		bool[string] seen;
		string[] taskPaths;
		foreach (ref td; tasks)
			if (td.parentTid == 0 && td.projectPath.length > 0)
			{
				auto projectPath = bestEffortProjectPathIdentity(td.projectPath);
				if (projectPath !in seen)
				{
					seen[projectPath] = true;
					taskPaths ~= projectPath;
				}
			}

		bool[string] coveredPaths;
		foreach (ref wi; workspacesInfo_)
			foreach (ref pi; wi.projects)
				coveredPaths[bestEffortProjectPathIdentity(pi.path)] = true;

		string[] orphanedPaths;
		foreach (projectPath; taskPaths)
		{
			if (projectPath in coveredPaths)
				continue;

			bool matched = false;
			foreach (ref ws; config.workspaces)
			{
				auto wsRoot = bestEffortProjectPathIdentity(ws.root);
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

	DiscoveryGroup[] buildDiscoveryGroups()
	{
		import std.algorithm : sort;

		auto contexts = host_.snapshotNativeHistoryContexts();
		contexts.sort!((a, b) {
			if (a.agentName != b.agentName)
				return a.agentName < b.agentName;
			if (a.workspaceName != b.workspaceName)
				return a.workspaceName < b.workspaceName;
			return a.projectDir < b.projectDir;
		});
		DiscoveryCandidate[] candidates;
		foreach (ref context; contexts)
		{
			auto agent = host_.tryConfiguredAgent(context.agentName);
			if (agent is null)
				continue;
			try
				candidates ~= DiscoveryCandidate(context, agent,
					host_.resolveCurrentNativeHistoryContext(agent, context));
			catch (Exception e)
				warningf("native session discovery skipped %s/%s: %s", context.agentName,
					context.workspaceName, e.msg);
		}
		candidates.sort!((a, b) {
			if (a.resolved.profile.driver != b.resolved.profile.driver)
				return a.resolved.profile.driver < b.resolved.profile.driver;
			if (a.resolved.profile.root != b.resolved.profile.root)
				return a.resolved.profile.root < b.resolved.profile.root;
			if (a.context.agentName != b.context.agentName)
				return a.context.agentName < b.context.agentName;
			return a.context.workspaceName < b.context.workspaceName;
		});
		DiscoveryGroup[] groups;
		foreach (ref candidate; candidates)
		{
			if (groups.length == 0
				|| groups[$ - 1].agent.driver != candidate.resolved.profile.driver
				|| groups[$ - 1].profile.root != candidate.resolved.profile.root)
			{
				groups ~= DiscoveryGroup(candidate.agent, candidate.resolved.profile,
					candidate.context.agentName, [candidate.context]);
			}
			else
				groups[$ - 1].producingContexts ~= candidate.context;
		}
		return groups;
	}

	bool scanRecordStillCurrent(const ref ImportableScanRecord record)
	{
		foreach (ref context; record.producingContexts)
		{
			auto agent = host_.tryConfiguredAgent(context.agentName);
			if (agent is null)
				continue;
			try
			{
				auto resolved = host_.resolveCurrentNativeHistoryContext(agent, context);
				if (resolved.profile.driver == record.key.driver
					&& resolved.profile.root == record.key.profileRoot
					&& isAbsolute(record.discovered.exactHistoryPath)
					&& exists(record.discovered.exactHistoryPath)
					&& isFile(record.discovered.exactHistoryPath))
				{
					auto file = File(record.discovered.exactHistoryPath, "r");
					return true;
				}
			}
			catch (Exception)
			{
			}
		}
		return false;
	}

	bool[string] knownNativeSessionKeys(DiscoveryTaskSnapshot[int] tasks)
	{
		bool[string] known;
		foreach (ref td; tasks)
		{
			if (td.status == "importable" || td.agentSessionId.length == 0)
				continue;
			auto agent = host_.tryConfiguredAgent(td.agentName);
			if (agent is null)
				continue;
			try
			{
				auto context = ConfiguredNativeHistoryContext(td.agentName, td.workspace,
					td.projectPath, false);
				auto resolved = host_.resolveCurrentNativeHistoryContext(agent, context);
				auto key = NativeSessionKey(resolved.profile.driver,
					resolved.profile.root, td.agentSessionId);
				known[sessionKey(key)] = true;
			}
			catch (Exception)
			{
			}
		}
		return known;
	}

	static Promise!DiscoveryScanOutput runScanAsync(DiscoveryScanInput input)
	{
		return threadAsync({
			DiscoveryScanOutput output;
			foreach (ref group; input.groups)
			{
				DiscoveredSession[] discovered;
				try
					discovered = group.agent.enumerateAllSessions(group.profile);
				catch (Exception e)
				{
					warningf("enumerateSessions: error enumerating %s/%s: %s",
						to!string(group.agent.driver), group.profile.root, e.msg);
					output.failedGroupKeys[groupKey(group.agent.driver, group.profile.root)] = true;
					continue;
				}

				ScannedSessionRecord[] groupResults;
				bool groupFailed;
				foreach (ref discoveredSession; discovered)
				{
					auto nativeKey = NativeSessionKey(group.agent.driver, group.profile.root,
						discoveredSession.sessionId);
					auto compositeKey = sessionKey(nativeKey);
					if (compositeKey in input.knownSessionKeys)
						continue;
					try
					{
						auto cachedp = compositeKey in input.cacheMap;
						ScannedSessionRecord record;
						record.scanRecord = ImportableScanRecord(nativeKey, discoveredSession,
							group.importAgentName, group.producingContexts, input.scanGeneration);
						record.mtime = discoveredSession.mtime;
						if (cachedp !is null && cachedp.mtime == discoveredSession.mtime)
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
								auto meta = group.agent.readSessionMeta(discoveredSession);
								record.title = meta.title;
								record.projectPath = meta.projectPath;
								record.hasMessages = meta.hasMessages;
							}
							catch (Exception e)
								warningf("enumerateSessions: error reading meta for %s/%s: %s",
									to!string(group.agent.driver), discoveredSession.sessionId, e.msg);
						}
						record.projectPath = bestEffortProjectPathIdentity(record.projectPath);
						groupResults ~= record;
					}
					catch (Exception e)
					{
						warningf("native session discovery skipped %s/%s: %s",
							to!string(group.agent.driver), group.profile.root, e.msg);
						groupFailed = true;
						break;
					}
				}
				if (groupFailed)
				{
					output.failedGroupKeys[groupKey(group.agent.driver, group.profile.root)] = true;
					continue;
				}
				output.records ~= groupResults;
			}
			return output;
		});
	}

	static string groupKey(AgentDriver driver, string profileRoot)
	{
		return to!string(driver) ~ "\0" ~ profileRoot;
	}

	static string groupKey(string driverName, string profileRoot)
	{
		return driverName ~ "\0" ~ profileRoot;
	}

	static string sessionKey(const ref NativeSessionKey key)
	{
		return groupKey(key.driver, key.profileRoot) ~ "\0" ~ key.sessionId;
	}

	static string sessionKey(string driverName, string profileRoot, string sessionId)
	{
		return groupKey(driverName, profileRoot) ~ "\0" ~ sessionId;
	}
}

version (unittest)
private ResolvedNativeHistoryContext testResolvedNativeHistoryContext(
	Agent agent, const ref ConfiguredNativeHistoryContext context)
{
	import cydo.runtime.launch.types : ResolvedSandbox;

	return ResolvedNativeHistoryContext(agent, ResolvedSandbox.init,
		agent.nativeHistoryRule, NativeHistoryProfile(agent.driver,
			"/tmp/cydo-discovery-test-profile-" ~ context.agentName));
}

version (unittest)
private ScannedSessionRecord testScannedSession(Agent agent, string agentName,
	string sessionId, long mtime, string title,
	string projectPath, bool hasMessages = true)
{
	import std.file : thisExePath;

	auto context = ConfiguredNativeHistoryContext(agentName, "", "", false);
	auto resolved = testResolvedNativeHistoryContext(agent, context);
	auto discovered = DiscoveredSession(sessionId, mtime, thisExePath());
	auto record = ImportableScanRecord(NativeSessionKey(agent.driver,
		resolved.profile.root, sessionId), discovered, agentName, [context], 1);
	return ScannedSessionRecord(record, mtime, title, projectPath,
		false, hasMessages);
}

version (unittest)
private DiscoveryScanOutput testScanOutput(ScannedSessionRecord[] records)
{
	DiscoveryScanOutput output;
	output.records = records;
	return output;
}

unittest
{
	DiscoveryTaskSnapshot[int] tasks;
	auto service = new DiscoveryService(DiscoveryServiceHost(
		snapshotTasks: () => tasks,
	));

	tasks[1] = DiscoveryTaskSnapshot(1, 0, "", "", "", "", "/tmp/other");
	tasks[2] = DiscoveryTaskSnapshot(2, 1, "", "", "", "",
		"/tmp/ws/.cydo/tasks/42/worktree");

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
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	int createCount;
	int upsertCount;
	bool[] scanTransitions;
	int snapshotCount;

	DiscoveryTaskSnapshot[int] knownTasks;
	CydoConfig config;
	AgentConfig workClaude;
	workClaude.driver = typeof(workClaude.driver)(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;
	Agent agent = new ClaudeCodeAgent();
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
			snapshotNativeHistoryContexts: () => ConfiguredNativeHistoryContext[].init,
			tryConfiguredAgent: (string agentName) => agentName == "work-claude"
				? agent : null,
			resolveCurrentNativeHistoryContext: (Agent actual,
				const ref ConfiguredNativeHistoryContext context) =>
				testResolvedNativeHistoryContext(actual, context),
			loadSessionMetaCache: () => Persistence.CacheRow[].init,
			withMutationTransaction: (scope void delegate() work) => work(),
			reconcileImportableTasks: (ulong scanGeneration,
				ImportableTaskSpec[] desired) {
				createCount += desired.length;
				return ImportableReconciliationCommit.init;
			},
			broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
			broadcastScanStatus: (bool active) {
				scanTransitions ~= active;
			},
			deleteSessionMetaCacheEntry: (string driverName, string profileRoot,
				string sessionId) {},
			deleteSessionMetaCacheGroup: (string driverName, string profileRoot) {},
			upsertSessionMetaCache: (string driverName, string profileRoot,
				string sessionId, long mtime, string projectPath, string title,
				bool hasMessages) {
				upsertCount++;
			},
		),
		(DiscoveryScanInput input) {
			ScannedSessionRecord[] results = [
				testScannedSession(agent, "work-claude", "session-1", 1, "Imported", ""),
			];
			return resolve(testScanOutput(results));
		},
	);

	knownTasks[1] = DiscoveryTaskSnapshot(1, 0, "completed", "session-1",
		"work-claude", "", "");

	service.enumerateSessions();
	socketManager.loop().assertNotThrown;

	assert(createCount == 0,
		"enumerateSessions must treat custom agent definition keys as the persisted task identity");
	assert(upsertCount == 0,
		"enumerateSessions must not upsert cache rows for sessions already owned by a task");
	assert(snapshotCount >= 2, "enumerateSessions must snapshot tasks again after scan");
	assert(scanTransitions == [true, false]);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto root = buildPath("/tmp", "cydo-discovery-project-path-unittest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto project = buildPath(root, "project");
	auto projectLink = buildPath(root, "project-link");
	auto missing = buildPath(root, "missing", "project");
	mkdirRecurse(project);
	symlink(project, projectLink);

	ImportableTaskSpec[] imported;
	string[] cachedPaths;
	DiscoveryTaskSnapshot[int] tasks;
	Agent agent = new ClaudeCodeAgent();
	auto service = new DiscoveryService(
		DiscoveryServiceHost(
			snapshotTasks: () => tasks,
			snapshotNativeHistoryContexts: () => ConfiguredNativeHistoryContext[].init,
			tryConfiguredAgent: (string agentName) => agentName == "claude" ? agent : null,
			resolveCurrentNativeHistoryContext: (Agent actual,
				const ref ConfiguredNativeHistoryContext context) =>
				testResolvedNativeHistoryContext(actual, context),
			loadSessionMetaCache: () => Persistence.CacheRow[].init,
			withMutationTransaction: (scope void delegate() work) => work(),
			reconcileImportableTasks: (ulong scanGeneration,
				ImportableTaskSpec[] desired) {
				imported ~= desired;
				return ImportableReconciliationCommit.init;
			},
			broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
			broadcastScanStatus: (bool active) {},
			deleteSessionMetaCacheEntry: (string driverName, string profileRoot,
				string sessionId) {},
			deleteSessionMetaCacheGroup: (string driverName, string profileRoot) {},
			upsertSessionMetaCache: (string driverName, string profileRoot,
				string sessionId, long mtime, string projectPath, string title,
				bool hasMessages) { cachedPaths ~= projectPath; },
		),
		(DiscoveryScanInput input) => resolve(testScanOutput([
			testScannedSession(agent, "claude", "existing", 1, "Existing", projectLink),
			testScannedSession(agent, "claude", "missing", 1, "Missing", missing),
		])),
	);

	service.enumerateSessions();
	socketManager.loop();

	auto canonical = canonicalProjectPath(project);
	assert(imported.length == 2);
	assert(imported[0].projectPath == canonical);
	assert(cachedPaths[0] == canonical);
	assert(imported[1].projectPath == bestEffortProjectPathIdentity(missing));
	assert(cachedPaths[1] == bestEffortProjectPathIdentity(missing));
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-discovery-virtual-project-path-unittest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto project = buildPath(root, "project");
	auto projectLink = buildPath(root, "project-link");
	mkdirRecurse(project);
	symlink(project, projectLink);

	DiscoveryTaskSnapshot[int] tasks;
	tasks[1] = DiscoveryTaskSnapshot(1, 0, "", "", "", "", project);
	tasks[2] = DiscoveryTaskSnapshot(2, 0, "", "", "", "", projectLink);
	auto service = new DiscoveryService(DiscoveryServiceHost(
		snapshotTasks: () => tasks,
	));

	service.discoverAllWorkspaces(CydoConfig.init);
	assert(service.workspacesInfo.length == 1);
	assert(service.workspacesInfo[0].projects.length == 1);
	assert(service.workspacesInfo[0].projects[0].path == canonicalProjectPath(project));
}

unittest
{
	import std.exception : assertNotThrown;
	import ae.net.asockets : socketManager;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	int createCount;

	DiscoveryTaskSnapshot[int] knownTasks;
	CydoConfig config;
	AgentConfig claude;
	claude.driver = typeof(claude.driver)(AgentDriver.claude, true);
	config.agents["claude"] = claude;
	Agent agent = new ClaudeCodeAgent();

	auto service = new DiscoveryService(
		DiscoveryServiceHost(
			snapshotTasks: () => knownTasks,
			snapshotNativeHistoryContexts: () => ConfiguredNativeHistoryContext[].init,
			tryConfiguredAgent: (string agentName) =>
				agentName == "claude" || agentName == "work-claude" ? agent : null,
			resolveCurrentNativeHistoryContext: (Agent actual,
				const ref ConfiguredNativeHistoryContext context) =>
				testResolvedNativeHistoryContext(actual, context),
			loadSessionMetaCache: () => Persistence.CacheRow[].init,
			withMutationTransaction: (scope void delegate() work) => work(),
			reconcileImportableTasks: (ulong scanGeneration,
				ImportableTaskSpec[] desired) {
				createCount += desired.length;
				return ImportableReconciliationCommit.init;
			},
			broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
			broadcastScanStatus: (bool active) {},
			deleteSessionMetaCacheEntry: (string driverName, string profileRoot,
				string sessionId) {},
			deleteSessionMetaCacheGroup: (string driverName, string profileRoot) {},
			upsertSessionMetaCache: (string driverName, string profileRoot,
				string sessionId, long mtime, string projectPath, string title,
				bool hasMessages) {},
		),
		(DiscoveryScanInput input) {
			return resolve(testScanOutput([
				testScannedSession(agent, "claude", "session-1", 1, "Imported", ""),
			]));
		},
	);

	knownTasks[1] = DiscoveryTaskSnapshot(1, 0, "completed", "session-1",
		"work-claude", "", "");

	service.enumerateSessions();
	socketManager.loop().assertNotThrown;

	assert(createCount == 1,
		"sessions under a different resolved profile must remain importable");
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.datetime.systime : SysTime;
	import std.file : exists, mkdirRecurse, rmdirRecurse, setTimes, write;
	import std.path : buildPath;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto root = buildPath("/tmp", "cydo-discovery-duplicate-profile-unittest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto firstProject = buildPath(root, "projects", "first");
	auto secondProject = buildPath(root, "projects", "second");
	mkdirRecurse(firstProject);
	mkdirRecurse(secondProject);
	enum sessionId = "same-session";
	auto oldPath = buildPath(firstProject, sessionId ~ ".jsonl");
	auto newPath = buildPath(secondProject, sessionId ~ ".jsonl");
	write(oldPath, "{}");
	write(newPath, "{}");
	auto older = SysTime.fromUnixTime(1_000_000);
	auto newer = SysTime.fromUnixTime(2_000_000);
	setTimes(oldPath, older, older);
	setTimes(newPath, newer, newer);

	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, root);
	auto context = ConfiguredNativeHistoryContext("claude", "", "", false);
	DiscoveryScanInput input;
	input.groups = [DiscoveryGroup(agent, profile, "claude", [context])];

	bool completed;
	DiscoveryScanOutput output;
	DiscoveryService.runScanAsync(input).then((DiscoveryScanOutput result) {
		output = result;
		completed = true;
	}).ignoreResult();
	socketManager.loop();

	assert(completed);
	assert(output.records.length == 1);
	assert(output.records[0].scanRecord.key.sessionId == sessionId);
	assert(output.records[0].scanRecord.discovered.exactHistoryPath == newPath);
	assert(DiscoveryService.groupKey(agent.driver, root) !in output.failedGroupKeys);
}

unittest
{
	import ae.net.asockets : socketManager;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : ResolvedSandbox;

	enum profileRoot = "/tmp/cydo-discovery-conflicted-cache-profile";
	int entryDeletes;
	Agent agent = new ClaudeCodeAgent();
	auto context = ConfiguredNativeHistoryContext("claude", "", "", false);
	auto service = new DiscoveryService(
		DiscoveryServiceHost(
			snapshotTasks: () {
				DiscoveryTaskSnapshot[int] snapshot;
				return snapshot;
			},
			snapshotNativeHistoryContexts: () => [context],
			tryConfiguredAgent: (string name) => name == "claude" ? agent : null,
			resolveCurrentNativeHistoryContext: (Agent actual,
				const ref ConfiguredNativeHistoryContext current) =>
				ResolvedNativeHistoryContext(actual, ResolvedSandbox.init,
					actual.nativeHistoryRule, NativeHistoryProfile(actual.driver, profileRoot)),
			loadSessionMetaCache: () => [Persistence.CacheRow("claude", profileRoot,
				"same-session", 1, "", "cached", true)],
			withMutationTransaction: (scope void delegate() work) => work(),
			reconcileImportableTasks: (ulong generation, ImportableTaskSpec[] desired) {
				assert(desired.length == 0);
				return ImportableReconciliationCommit.init;
			},
			broadcastWorkspaces: (WorkspaceInfo[] workspaces) {},
			broadcastScanStatus: (bool active) {},
			deleteSessionMetaCacheEntry: (string driverName, string root,
				string sessionId) { entryDeletes++; },
			deleteSessionMetaCacheGroup: (string driverName, string root) {
				assert(false, "a currently configured conflicted group must not be pruned");
			},
			upsertSessionMetaCache: (string driverName, string root, string sessionId,
				long mtime, string projectPath, string title, bool hasMessages) {
				assert(false, "a conflicted group must not write cache metadata");
			},
		),
		(DiscoveryScanInput input) {
			DiscoveryScanOutput output;
			output.failedGroupKeys[DiscoveryService.groupKey(agent.driver, profileRoot)] = true;
			return resolve(output);
		},
	);

	service.enumerateSessions();
	socketManager.loop();
	assert(entryDeletes == 0,
		"a failed profile group must preserve its root-qualified cache entries");
}
