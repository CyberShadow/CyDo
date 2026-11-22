module cydo.cli.init_detection;

import std.algorithm : sort;
import std.array : array;
import std.exception : ErrnoException, enforce;
import std.file : FileException, exists, getcwd, isDir, tempDir;
import std.path : baseName, isAbsolute;
import std.process : ProcessException;
import std.string : split;
import core.stdc.errno : ENOENT, ENOTDIR;

import cydo.agent.resolver : createAgentByDriver;
import cydo.cli.open_matching : pathIsUnderRoot;
import cydo.domain.tasks.model : ProjectRepoResolution, resolveProjectRepo;
import cydo.foundation.platform.path : canonicalProjectPath;
import cydo.runtime.config : AgentDriver;
import cydo.runtime.config.paths : configPath;
import cydo.runtime.launch.environment : effectiveChildEnvValue,
	resolveNativeHistoryProfile;
import cydo.runtime.launch.types : NativeHistoryProfile, ResolvedSandbox;

struct DetectedWorkspace
{
	string name;
	string root;
}

/// Detect Git workspaces from the invocation directory and native histories.
DetectedWorkspace[] detectInitWorkspaces()
{
	auto sandbox = ResolvedSandbox.init;
	auto homeValue = effectiveChildEnvValue(sandbox, "HOME");
	enforce(homeValue.present && homeValue.value.length > 0,
		"Native history configuration requires a nonempty effective HOME");
	enforce(isAbsolute(homeValue.value),
		"Native history configuration requires an absolute effective HOME: "
		~ homeValue.value);

	auto mainConfigPath = configPath();
	enforce(mainConfigPath.length > 0 && isAbsolute(mainConfigPath),
		"CyDo configuration path must be nonempty and absolute: " ~ mainConfigPath);
	auto home = canonicalProjectPath(homeValue.value);
	auto systemTemp = canonicalProjectPath(tempDir());

	NativeHistoryProfile[] profiles;
	foreach (driver; [AgentDriver.claude, AgentDriver.codex, AgentDriver.copilot])
	{
		auto agent = createAgentByDriver(driver);
		auto rule = agent.nativeHistoryRule;
		profiles ~= resolveNativeHistoryProfile(sandbox, rule);
	}

	auto candidates = [getcwd()];
	candidates ~= collectNativeHistoryCandidatePaths(profiles);
	return selectDetectedWorkspaces(candidates, home, systemTemp);
}

/// Read all native session CWDs using the concrete driver for each profile.
string[] collectNativeHistoryCandidatePaths(NativeHistoryProfile[] profiles)
{
	string[] candidates;
	foreach (profile; profiles)
	{
		auto agent = createAgentByDriver(profile.driver);
		foreach (session; agent.enumerateAllSessions(profile))
		{
			auto meta = agent.readSessionMeta(session);
			if (meta.projectPath.length > 0)
				candidates ~= meta.projectPath;
		}
	}
	return candidates;
}

/// Select canonical Git roots from candidate directories.
DetectedWorkspace[] selectDetectedWorkspaces(string[] candidates, string canonicalHome,
	string canonicalTemp)
{
	return selectDetectedWorkspaces(candidates, canonicalHome, canonicalTemp,
		delegate ProjectRepoResolution(string path) { return resolveProjectRepo(path); });
}

/// Select canonical Git roots using a typed test seam for the Git probe.
DetectedWorkspace[] selectDetectedWorkspaces(string[] candidates, string canonicalHome,
	string canonicalTemp, ProjectRepoResolution delegate(string) probe)
{
	bool[string] canonicalCandidates;
	foreach (candidate; candidates)
	{
		auto canonical = canonicalExistingDirectory(candidate);
		if (canonical.length == 0)
			continue;
		if (!isTaskWorktreePath(canonical) && !pathIsUnderRoot(canonical, canonicalTemp))
			canonicalCandidates[canonical] = true;
	}

	string[] roots;
	foreach (candidate; canonicalCandidates.keys)
	{
		ProjectRepoResolution result;
		try
			result = probe(candidate);
		catch (ProcessException)
			continue;
		if (!result.isGitCheckout || result.repoPath.length == 0 || !isAbsolute(result.repoPath))
			continue;
		auto root = canonicalExistingDirectory(result.repoPath);
		if (root.length == 0)
			continue;
		if (!isTaskWorktreePath(root) && !pathIsUnderRoot(root, canonicalTemp)
			&& root != canonicalHome)
			roots ~= root;
	}
	return consolidateDetectedWorkspaceRoots(roots);
}

private string canonicalExistingDirectory(string path)
{
	try
	{
		if (!isDir(path))
			return "";
	}
	catch (FileException e)
	{
		if (e.errno == ENOENT || e.errno == ENOTDIR)
			return "";
		throw e;
	}
	try
		return canonicalProjectPath(path);
	catch (ErrnoException e)
	{
		if (e.errno == ENOENT || e.errno == ENOTDIR)
			return "";
		throw e;
	}
	catch (Exception e)
	{
		try
		{
			if (!isDir(path))
				return "";
		}
		catch (FileException race)
		{
			if (race.errno == ENOENT || race.errno == ENOTDIR)
				return "";
			throw race;
		}
		throw e;
	}
}

/// Deduplicate, consolidate, and deterministically name canonical Git roots.
DetectedWorkspace[] consolidateDetectedWorkspaceRoots(string[] roots)
{
	bool[string] uniqueRoots;
	foreach (root; roots)
		uniqueRoots[root] = true;
	auto sortedRoots = uniqueRoots.keys.array;
	sort(sortedRoots);

	string[] retained;
	foreach (root; sortedRoots)
	{
		bool covered;
		foreach (parent; retained)
			if (root != parent && pathIsUnderRoot(root, parent))
			{
				covered = true;
				break;
			}
		if (!covered)
			retained ~= root;
	}

	bool[string] usedNames;
	DetectedWorkspace[] result;
	foreach (root; retained)
	{
		auto base = root == "/" ? "root" : baseName(root);
		auto name = base;
		int suffix = 2;
		while (name in usedNames)
		{
			import std.format : format;
			name = format!"%s-%d"(base, suffix);
			++suffix;
		}
		usedNames[name] = true;
		result ~= DetectedWorkspace(name, root);
	}
	return result;
}

private bool isTaskWorktreePath(string path)
{
	auto components = path.split("/");
	foreach (i; 0 .. components.length - 1)
		if (components[i] == ".cydo" && components[i + 1] == "tasks")
			return true;
	return false;
}

version (unittest)
{
	import std.algorithm : sort;
	import std.exception : assertThrown;
	import std.file : chdir, exists, mkdirRecurse, remove, rmdirRecurse, symlink, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.launch.types : NativeHistoryRule;

	private void resetInitDetectionTestDir(string path)
	{
		if (exists(path))
			rmdirRecurse(path);
		mkdirRecurse(path);
	}

	private void initInitDetectionTestRepo(string path)
	{
		mkdirRecurse(path);
		assert(execute(["git", "-C", path, "init", "-q"]).status == 0);
	}

	private string claudeHistoryUserRecord(string cwd)
	{
		import std.json : JSONValue;

		return `{"type":"user","parentUuid":null,"isSidechain":false,"userType":"external",`
			~ `"cwd":` ~ JSONValue(cwd).toString()
			~ `,"message":{"role":"user","content":"Inspect this project"}}` ~ "\n";
	}

	private ProjectRepoResolution failInitDetectionGitProbe(string path)
	{
		import std.process : ProcessException;
		throw new ProcessException("git launch failed");
	}

	unittest
	{
		auto loop = buildPath(tempDir(), "cydo-init-detection-loop");
		try remove(loop); catch (Exception) {}
		symlink(loop, loop);
		scope (exit) remove(loop);
		assertThrown!FileException(canonicalExistingDirectory(loop));
	}

	unittest
	{
		auto root = buildPath(tempDir(), "cydo-init-detection-native-history");
		resetInitDetectionTestDir(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto claudeProject = buildPath(root, "claude-project");
		auto codexProject = buildPath(root, "codex-project");
		auto copilotProject = buildPath(root, "copilot-project");
		mkdirRecurse(claudeProject);
		mkdirRecurse(codexProject);
		mkdirRecurse(copilotProject);

		auto claudeRoot = buildPath(root, "claude");
		auto codexRoot = buildPath(root, "codex");
		auto copilotRoot = buildPath(root, "copilot");
		mkdirRecurse(buildPath(claudeRoot, "projects", "project"));
		write(buildPath(claudeRoot, "projects", "project", "claude-session.jsonl"),
			claudeHistoryUserRecord(claudeProject));
		write(buildPath(claudeRoot, "projects", "project", "no-cwd.jsonl"),
			`{"type":"system","subtype":"init","cwd":"` ~ claudeRoot ~ `"}` ~ "\n"
			~ `{"type":"user","message":{"role":"user","content":"Missing cwd"}}` ~ "\n");

		auto codexHistory = buildPath(codexRoot, "sessions", "2026", "09", "04",
			"rollout-123e4567-e89b-12d3-a456-426614174000.jsonl");
		mkdirRecurse(buildPath(codexRoot, "sessions", "2026", "09", "04"));
		write(codexHistory,
			`{"type":"session_meta","payload":{"cwd":"` ~ codexProject ~ `"}}` ~ "\n");
		assert(execute(["touch", "-d", "2000-01-01", codexHistory]).status == 0);
		write(buildPath(codexRoot, "sessions", "2026", "09", "04", "no-cwd.jsonl"),
			`{"type":"session_meta","payload":{}}` ~ "\n");

		mkdirRecurse(buildPath(copilotRoot, "session-state", "copilot-session"));
		write(buildPath(copilotRoot, "session-state", "copilot-session", "events.jsonl"),
			`{"type":"session.start","data":{"cwd":"` ~ buildPath(root, "nested-cwd-must-not-count") ~ `"}}` ~ "\n"
			~ `{"type":"session.start","cwd":"` ~ copilotProject ~ `"}` ~ "\n");
		mkdirRecurse(buildPath(copilotRoot, "session-state", "no-cwd"));
		write(buildPath(copilotRoot, "session-state", "no-cwd", "events.jsonl"),
			`{"type":"session.start","data":{"cwd":"` ~ buildPath(root, "also-nested") ~ `"}}` ~ "\n");

		auto candidates = collectNativeHistoryCandidatePaths([
			NativeHistoryProfile(AgentDriver.claude, claudeRoot),
			NativeHistoryProfile(AgentDriver.codex, codexRoot),
			NativeHistoryProfile(AgentDriver.copilot, copilotRoot),
		]);
		sort(candidates);
		assert(candidates == [claudeProject, codexProject, copilotProject]);
		assert(collectNativeHistoryCandidatePaths([
			NativeHistoryProfile(AgentDriver.claude, buildPath(root, "missing-claude")),
			NativeHistoryProfile(AgentDriver.codex, buildPath(root, "missing-codex")),
			NativeHistoryProfile(AgentDriver.copilot, buildPath(root, "missing-copilot")),
		]).length == 0);
	}

	unittest
	{
		auto root = buildPath(tempDir(), "cydo-init-detection-selection");
		resetInitDetectionTestDir(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto parent = buildPath(root, "parent");
		auto nested = buildPath(parent, "nested");
		auto firstWork = buildPath(root, "one", "work");
		auto secondWork = buildPath(root, "two", "work");
		auto taskWorktree = buildPath(root, ".cydo", "tasks", "1", "worktree");
		auto tasksOld = buildPath(root, ".cydo", "tasks-old");
		auto nonGit = buildPath(root, "not-a-repo");
		auto regularFile = buildPath(root, "file");
		auto excludedTempRoot = buildPath(tempDir(), "cydo-init-detection-excluded-temp");
		auto tempWorktree = buildPath(excludedTempRoot, "repo");
		auto tempSibling = excludedTempRoot ~ "-sibling";
		initInitDetectionTestRepo(parent);
		mkdirRecurse(nested);
		initInitDetectionTestRepo(firstWork);
		initInitDetectionTestRepo(secondWork);
		initInitDetectionTestRepo(taskWorktree);
		initInitDetectionTestRepo(tasksOld);
		mkdirRecurse(nonGit);
		write(regularFile, "not a directory");
		resetInitDetectionTestDir(tempWorktree);
		scope (exit)
			if (exists(tempWorktree))
				rmdirRecurse(tempWorktree);
		initInitDetectionTestRepo(tempWorktree);
		initInitDetectionTestRepo(tempSibling);
		scope (exit) if (exists(tempSibling)) rmdirRecurse(tempSibling);

		auto selected = selectDetectedWorkspaces(
			[parent, nested, firstWork, secondWork, taskWorktree, tasksOld, tempWorktree, tempSibling,
				buildPath(root, "stale"), regularFile, nonGit],
			buildPath(root, "home"), excludedTempRoot);
		assert(selected == [
			DetectedWorkspace("cydo-init-detection-excluded-temp-sibling", tempSibling),
			DetectedWorkspace("tasks-old", tasksOld),
			DetectedWorkspace("work", firstWork),
			DetectedWorkspace("parent", parent),
			DetectedWorkspace("work-2", secondWork),
		]);

		assert(selectDetectedWorkspaces([firstWork], buildPath(root, "home"), excludedTempRoot,
			delegate ProjectRepoResolution(string path) { return failInitDetectionGitProbe(path); }).length == 0);

		auto parentLink = buildPath(root, "parent-alias");
		symlink(parent, parentLink);
		assert(selectDetectedWorkspaces([parent, nested, parentLink], buildPath(root, "home"),
			excludedTempRoot) == [DetectedWorkspace("parent", parent)]);
	}

	unittest
	{
		assert(consolidateDetectedWorkspaceRoots([
			"/workspace/a", "/workspace/a/child", "/workspace/b", "/workspace/a",
			"/other/a",
		]) == [
			DetectedWorkspace("a", "/other/a"),
			DetectedWorkspace("a-2", "/workspace/a"),
			DetectedWorkspace("b", "/workspace/b"),
		]);
		assert(consolidateDetectedWorkspaceRoots([
			"/roots/a/foo", "/roots/b/foo", "/roots/c/foo-2", "/roots/d/foo-3", "/local",
		]) == [
			DetectedWorkspace("local", "/local"),
			DetectedWorkspace("foo", "/roots/a/foo"),
			DetectedWorkspace("foo-2", "/roots/b/foo"),
			DetectedWorkspace("foo-2-2", "/roots/c/foo-2"),
			DetectedWorkspace("foo-3", "/roots/d/foo-3"),
		]);
		assert(consolidateDetectedWorkspaceRoots(["/"]) == [DetectedWorkspace("root", "/")]);
		assert(consolidateDetectedWorkspaceRoots(["/work/a", "/work/ab", "/work/b"]) == [
			DetectedWorkspace("a", "/work/a"), DetectedWorkspace("ab", "/work/ab"),
			DetectedWorkspace("b", "/work/b"),
		]);
		assert(consolidateDetectedWorkspaceRoots(["/work/b", "/work/ab", "/work/a"])
			== consolidateDetectedWorkspaceRoots(["/work/a", "/work/ab", "/work/b"]));
	}

	unittest
	{
		auto root = buildPath(tempDir(), "cydo-init-detection-probe-results");
		resetInitDetectionTestDir(root);
		scope (exit) if (exists(root)) rmdirRecurse(root);
		auto candidate = buildPath(root, "candidate");
		auto home = buildPath(root, "home");
		auto temp = buildPath(root, "temp");
		auto task = buildPath(root, ".cydo", "tasks");
		auto taskSource = buildPath(task, "source");
		auto valid = buildPath(root, "valid");
		auto validLink = buildPath(root, "valid-link");
		auto underHome = buildPath(home, "project");
		auto tempChild = buildPath(temp, "child");
		auto tempAlias = buildPath(root, "temp-alias");
		auto missing = buildPath(root, "missing");
		mkdirRecurse(candidate);
		mkdirRecurse(home);
		mkdirRecurse(temp);
		mkdirRecurse(task);
		mkdirRecurse(taskSource);
		mkdirRecurse(valid);
		mkdirRecurse(underHome);
		mkdirRecurse(tempChild);
		symlink(valid, validLink);
		symlink(temp, tempAlias);
		ProjectRepoResolution[string] results = [
			candidate: ProjectRepoResolution(valid, true),
		];
		auto probe = delegate ProjectRepoResolution(string path)
		{
			auto result = path in results;
			return result is null ? ProjectRepoResolution("", false) : *result;
		};
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe) == [DetectedWorkspace("valid", valid)]);
		results[candidate] = ProjectRepoResolution(validLink, true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe) == [DetectedWorkspace("valid", valid)]);
		results[taskSource] = ProjectRepoResolution(valid, true);
		assert(selectDetectedWorkspaces([taskSource], home, temp, probe).length == 0);
		assert(selectDetectedWorkspaces([temp, tempChild, tempAlias], home, temp, probe).length == 0);
		results[candidate] = ProjectRepoResolution(temp, true);
		assert(selectDetectedWorkspaces([candidate], home, temp, probe).length == 0);
		results[candidate] = ProjectRepoResolution(tempChild, true);
		assert(selectDetectedWorkspaces([candidate], home, temp, probe).length == 0);
		results[candidate] = ProjectRepoResolution(tempAlias, true);
		assert(selectDetectedWorkspaces([candidate], home, temp, probe).length == 0);
		results[candidate] = ProjectRepoResolution(underHome, true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe) == [DetectedWorkspace("project", underHome)]);
		results[candidate] = ProjectRepoResolution("", true);
		assert(selectDetectedWorkspaces([candidate], home, temp, probe).length == 0);
		results[candidate] = ProjectRepoResolution(valid, false);
		assert(selectDetectedWorkspaces([candidate], home, temp, probe).length == 0);

		int probes;
		auto countingProbe = delegate ProjectRepoResolution(string path)
		{
			++probes;
			return ProjectRepoResolution(valid, true);
		};
		assert(selectDetectedWorkspaces([candidate, candidate], home, temp, countingProbe).length == 1);
		assert(probes == 1);
		results[candidate] = ProjectRepoResolution("relative", true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe).length == 0);
		results[candidate] = ProjectRepoResolution(missing, true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe).length == 0);
		results[candidate] = ProjectRepoResolution(home, true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe).length == 0);
		results[candidate] = ProjectRepoResolution(task, true);
		assert(selectDetectedWorkspaces([candidate], home, temp,
			probe).length == 0);
	}

	unittest
	{
		auto root = buildPath("/build", "cydo-init-detection-host-environment");
		resetInitDetectionTestDir(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto originalCwd = getcwd();
		scope (exit) chdir(originalCwd);
		chdir(root);

		auto oldHome = environment.get("HOME", "");
		auto oldClaudeHome = environment.get("CLAUDE_CONFIG_DIR", "");
		auto oldCodexHome = environment.get("CODEX_HOME", "");
		auto oldCopilotHome = environment.get("COPILOT_HOME", "");
		bool hadHome = "HOME" in environment;
		bool hadClaudeHome = "CLAUDE_CONFIG_DIR" in environment;
		bool hadCodexHome = "CODEX_HOME" in environment;
		bool hadCopilotHome = "COPILOT_HOME" in environment;
		scope (exit)
		{
			if (hadHome) environment["HOME"] = oldHome;
			else environment.remove("HOME");
			if (hadClaudeHome) environment["CLAUDE_CONFIG_DIR"] = oldClaudeHome;
			else environment.remove("CLAUDE_CONFIG_DIR");
			if (hadCodexHome) environment["CODEX_HOME"] = oldCodexHome;
			else environment.remove("CODEX_HOME");
			if (hadCopilotHome) environment["COPILOT_HOME"] = oldCopilotHome;
			else environment.remove("COPILOT_HOME");
		}

		auto home = buildPath(root, "home");
		auto claudeHome = buildPath(root, "claude-profile");
		auto codexHome = buildPath(root, "codex-profile");
		auto copilotHome = buildPath(root, "copilot-profile");
		auto invocationRepo = buildPath(root, "invocation");
		auto claudeRepo = buildPath(root, "claude-default");
		auto codexRepo = buildPath(root, "codex-default");
		auto copilotRepo = buildPath(root, "copilot-default");
		auto claudeOverrideRepo = buildPath(root, "claude-override");
		auto codexOverrideRepo = buildPath(root, "codex-override");
		auto copilotOverrideRepo = buildPath(root, "copilot-override");
		mkdirRecurse(home);
		foreach (repo; [invocationRepo, claudeRepo, codexRepo, copilotRepo,
			claudeOverrideRepo, codexOverrideRepo, copilotOverrideRepo])
			initInitDetectionTestRepo(repo);
		mkdirRecurse(buildPath(home, ".claude", "projects", "p"));
		mkdirRecurse(buildPath(home, ".codex", "sessions", "2026", "09", "04"));
		mkdirRecurse(buildPath(home, ".copilot", "session-state", "p"));
		write(buildPath(home, ".claude", "projects", "p", "s.jsonl"),
			claudeHistoryUserRecord(claudeRepo));
		write(buildPath(home, ".codex", "sessions", "2026", "09", "04", "rollout-x.jsonl"),
			`{"type":"session_meta","payload":{"cwd":"` ~ codexRepo ~ `"}}` ~ "\n");
		write(buildPath(home, ".copilot", "session-state", "p", "events.jsonl"),
			`{"type":"session.start","cwd":"` ~ copilotRepo ~ `"}` ~ "\n");
		mkdirRecurse(buildPath(claudeHome, "projects", "p"));
		mkdirRecurse(buildPath(codexHome, "sessions", "2026", "09", "04"));
		mkdirRecurse(buildPath(copilotHome, "session-state", "p"));
		write(buildPath(claudeHome, "projects", "p", "s.jsonl"),
			claudeHistoryUserRecord(claudeOverrideRepo));
		write(buildPath(codexHome, "sessions", "2026", "09", "04", "rollout-x.jsonl"),
			`{"type":"session_meta","payload":{"cwd":"` ~ codexOverrideRepo ~ `"}}` ~ "\n");
		write(buildPath(copilotHome, "session-state", "p", "events.jsonl"),
			`{"type":"session.start","cwd":"` ~ copilotOverrideRepo ~ `"}` ~ "\n");
		auto tempRepo = buildPath(tempDir(), "cydo-init-detection-real-temp-repo");
		resetInitDetectionTestDir(tempRepo);
		scope (exit)
			if (exists(tempRepo))
				rmdirRecurse(tempRepo);
		initInitDetectionTestRepo(tempRepo);
		write(buildPath(home, ".claude", "projects", "p", "temp.jsonl"),
			claudeHistoryUserRecord(tempRepo));
		environment["HOME"] = home;
		environment.remove("CLAUDE_CONFIG_DIR");
		environment.remove("CODEX_HOME");
		environment.remove("COPILOT_HOME");
		chdir(invocationRepo);
		assert(detectInitWorkspaces() == [
			DetectedWorkspace("claude-default", claudeRepo),
			DetectedWorkspace("codex-default", codexRepo),
			DetectedWorkspace("copilot-default", copilotRepo),
			DetectedWorkspace("invocation", invocationRepo),
		]);
		ResolvedSandbox sandbox;
		auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
		auto codexProfile = resolveNativeHistoryProfile(sandbox, rule);
		assert(codexProfile.root == buildPath(home, ".codex"));

		environment["CLAUDE_CONFIG_DIR"] = claudeHome;
		environment["CODEX_HOME"] = codexHome;
		environment["COPILOT_HOME"] = copilotHome;
		assert(detectInitWorkspaces() == [
			DetectedWorkspace("claude-override", claudeOverrideRepo),
			DetectedWorkspace("codex-override", codexOverrideRepo),
			DetectedWorkspace("copilot-override", copilotOverrideRepo),
			DetectedWorkspace("invocation", invocationRepo),
		]);

		environment.remove("CLAUDE_CONFIG_DIR"); environment.remove("CODEX_HOME"); environment.remove("COPILOT_HOME");
		auto claudeRule = NativeHistoryRule(AgentDriver.claude, "CLAUDE_CONFIG_DIR", ".claude", null);
		auto copilotRule = NativeHistoryRule(AgentDriver.copilot, "COPILOT_HOME", ".copilot", null);
		assert(resolveNativeHistoryProfile(sandbox, rule).root == buildPath(home, ".codex"));
		assert(resolveNativeHistoryProfile(sandbox, claudeRule).root
			== buildPath(home, ".claude"));
		assert(resolveNativeHistoryProfile(sandbox, copilotRule).root
			== buildPath(home, ".copilot"));
	}
}
