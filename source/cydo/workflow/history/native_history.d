/// Resolves profile-qualified ACCESS ownership for a task's native history:
/// agent, profile, session, effective CWD, and path. Codex DISPLAY
/// reconstruction and native ROLLBACK admission are deliberately separate.
module cydo.workflow.history.native_history;

import std.exception : enforce;
import std.file : exists, isFile;
import std.path : isAbsolute;
import std.stdio : File;

import cydo.agent.contract : Agent;
import cydo.agent.resolver : resolveConfiguredAgent;
import cydo.runtime.config : CydoConfig, SandboxConfig;
import cydo.runtime.launch.environment : resolveNativeHistoryProfile;
import cydo.runtime.launch.sandbox_paths : SandboxPaths;
import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
import cydo.runtime.launch.types : AgentSandboxConfig, NativeHistoryProfile,
	NativeHistoryRule, ResolvedSandbox;

struct ConfiguredNativeHistoryContext
{
	string agentName;
	string workspaceName;
	string projectDir;
	bool readOnly;
}

struct ResolvedNativeHistoryContext
{
	Agent agent;
	ResolvedSandbox sandbox;
	NativeHistoryRule rule;
	NativeHistoryProfile profile;
}

enum TaskHistoryResolutionKind
{
	noSession,
	access,
	orphanAgent,
	unavailable,
}

struct HistoryAccess
{
	Agent agent;
	NativeHistoryProfile profile;
	string sessionId;
	string path;
}

enum UnavailableHistoryKind
{
	context,
	profilePath,
}

struct UnavailableHistory
{
	UnavailableHistoryKind kind;
	string agentName;
	string sessionId;
	string detail;
	NativeHistoryRule rule;
	NativeHistoryProfile profile;
}

struct TaskHistoryResolution
{
private:
	TaskHistoryResolutionKind kind_;
	HistoryAccess access_;
	UnavailableHistory unavailable_;
	string orphanAgentName_;
	string orphanSessionId_;

public:
	@property TaskHistoryResolutionKind kind() const { return kind_; }

	static TaskHistoryResolution noSession()
	{
		TaskHistoryResolution result;
		result.kind_ = TaskHistoryResolutionKind.noSession;
		return result;
	}

	static TaskHistoryResolution access(HistoryAccess value)
	{
		validateHistoryAccess(value);
		TaskHistoryResolution result;
		result.kind_ = TaskHistoryResolutionKind.access;
		result.access_ = value;
		return result;
	}

	static TaskHistoryResolution orphanAgent(string agentName, string sessionId)
	{
		enforce(agentName.length > 0,
			"Orphaned history resolution requires an agent name");
		enforce(sessionId.length > 0,
			"Orphaned history resolution requires a session ID");
		TaskHistoryResolution result;
		result.kind_ = TaskHistoryResolutionKind.orphanAgent;
		result.orphanAgentName_ = agentName;
		result.orphanSessionId_ = sessionId;
		return result;
	}

	static TaskHistoryResolution unavailable(UnavailableHistory value)
	{
		enforce(value.agentName.length > 0,
			"Unavailable history resolution requires an agent name");
		enforce(value.sessionId.length > 0,
			"Unavailable history resolution requires a session ID");
		enforce(value.detail.length > 0,
			"Unavailable history resolution requires diagnostic detail");
		if (value.kind == UnavailableHistoryKind.profilePath)
		{
			enforce(value.rule.profileEnvName.length > 0,
				"Profile-path history resolution requires a profile rule");
			enforce(value.profile.root.length > 0 && isAbsolute(value.profile.root),
				"Profile-path history resolution requires an absolute profile root");
			enforce(value.rule.driver == value.profile.driver,
				"Profile-path history rule and profile drivers must match");
		}
		TaskHistoryResolution result;
		result.kind_ = TaskHistoryResolutionKind.unavailable;
		result.unavailable_ = value;
		return result;
	}

	HistoryAccess requireAccess() const
	{
		enforce(kind_ == TaskHistoryResolutionKind.access,
			"History resolution does not contain readable history access");
		return cast(HistoryAccess) access_;
	}

	UnavailableHistory requireUnavailable() const
	{
		enforce(kind_ == TaskHistoryResolutionKind.unavailable,
			"History resolution does not contain unavailable-history detail");
		return cast(UnavailableHistory) unavailable_;
	}

	string requireOrphanAgentName() const
	{
		enforce(kind_ == TaskHistoryResolutionKind.orphanAgent,
			"History resolution does not contain an orphaned agent");
		return orphanAgentName_;
	}

	string requireOrphanSessionId() const
	{
		enforce(kind_ == TaskHistoryResolutionKind.orphanAgent,
			"History resolution does not contain an orphaned session ID");
		return orphanSessionId_;
	}
}

struct LiveHistoryContext
{
	Agent agent;
	NativeHistoryProfile profile;
	string sessionId;
	bool resuming;
}

enum LiveHistoryWatchResolutionKind
{
	noLiveBinding,
	awaitingPath,
	target,
}

struct LiveHistoryWatchTarget
{
	LiveHistoryContext context;
	string path;

	package(cydo) bool matchesExactly(
		scope const LiveHistoryWatchTarget other) const
	{
		return context.agent is other.context.agent
			&& context.profile == other.context.profile
			&& context.sessionId == other.context.sessionId
			&& path == other.path;
	}
}

struct LiveHistoryWatchResolution
{
private:
	LiveHistoryWatchResolutionKind kind_;
	LiveHistoryContext context_;
	LiveHistoryWatchTarget target_;

public:
	@property LiveHistoryWatchResolutionKind kind() const { return kind_; }

	static LiveHistoryWatchResolution noLiveBinding()
	{
		LiveHistoryWatchResolution result;
		result.kind_ = LiveHistoryWatchResolutionKind.noLiveBinding;
		return result;
	}

	static LiveHistoryWatchResolution awaitingPath(LiveHistoryContext context)
	{
		validateLiveHistoryContext(context);
		LiveHistoryWatchResolution result;
		result.kind_ = LiveHistoryWatchResolutionKind.awaitingPath;
		result.context_ = context;
		return result;
	}

	static LiveHistoryWatchResolution target(LiveHistoryWatchTarget value)
	{
		validateLiveHistoryContext(value.context);
		enforce(value.path.length > 0 && isAbsolute(value.path),
			"Live history watch target must be an absolute path");
		LiveHistoryWatchResolution result;
		result.kind_ = LiveHistoryWatchResolutionKind.target;
		result.context_ = value.context;
		result.target_ = value;
		return result;
	}

	LiveHistoryContext requireContext() const
	{
		enforce(kind_ == LiveHistoryWatchResolutionKind.awaitingPath
			|| kind_ == LiveHistoryWatchResolutionKind.target,
			"Live history watch resolution does not contain a context");
		return cast(LiveHistoryContext) context_;
	}

	LiveHistoryWatchTarget requireTarget() const
	{
		enforce(kind_ == LiveHistoryWatchResolutionKind.target,
			"Live history watch resolution does not contain a target");
		return cast(LiveHistoryWatchTarget) target_;
	}
}

unittest
{
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.runtime.config : AgentDriver;

	auto agent = new CodexAgent;
	auto baseline = LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch.jsonl");
	assert(baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch.jsonl")));

	auto secondAgent = new CodexAgent;
	assert(!baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(secondAgent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch.jsonl")));
	assert(!baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.claude,
			"/tmp/cydo-live-history-watch-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch.jsonl")));
	assert(!baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-other-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch.jsonl")));
	assert(!baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-profile"), "sid-b"),
		"/tmp/cydo-live-history-watch.jsonl")));
	assert(!baseline.matchesExactly(LiveHistoryWatchTarget(
		LiveHistoryContext(agent, NativeHistoryProfile(AgentDriver.codex,
			"/tmp/cydo-live-history-watch-profile"), "sid-a"),
		"/tmp/cydo-live-history-watch-other.jsonl")));
}

private void validateLiveHistoryContext(ref LiveHistoryContext value)
{
	enforce(value.agent !is null,
		"Live history context requires an Agent");
	enforce(value.profile.driver == value.agent.driver,
		"Live history context Agent and profile drivers must match");
	enforce(value.profile.root.length > 0 && isAbsolute(value.profile.root),
		"Live history context requires an absolute profile root");
	enforce(value.sessionId.length > 0,
		"Live history context requires a session ID");
}

private bool isReadableRegularFile(string path)
{
	if (!exists(path) || !isFile(path))
		return false;
	try
	{
		auto file = File(path, "r");
		return true;
	}
	catch (Exception)
		return false;
}

private void validateHistoryAccess(ref HistoryAccess value)
{
	auto context = LiveHistoryContext(value.agent, value.profile, value.sessionId);
	validateLiveHistoryContext(context);
	enforce(value.path.length > 0 && isAbsolute(value.path),
		"History access requires an absolute path");
	enforce(isReadableRegularFile(value.path),
		"History access requires an existing readable regular file");
}

ResolvedNativeHistoryContext resolveNativeHistoryContext(
	ref CydoConfig config,
	Agent agent,
	const ref ConfiguredNativeHistoryContext context)
{
	enforce(agent !is null,
		"Configured native history resolution requires a supplied Agent");
	auto configured = resolveConfiguredAgent(config, context.agentName);
	enforce(agent.driver == configured.driver,
		"Configured native history agent driver does not match supplied Agent: "
		~ context.agentName);

	SandboxConfig workspaceSandbox;
	string workspaceRoot;
	if (context.workspaceName.length > 0)
	{
		bool foundWorkspace;
		foreach (ref workspace; config.workspaces)
			if (workspace.name == context.workspaceName)
			{
				workspaceSandbox = workspace.sandbox;
				workspaceRoot = workspace.root;
				foundWorkspace = true;
				break;
			}
		enforce(foundWorkspace,
			"Configured native history workspace was deleted or is unknown: "
			~ context.workspaceName);
	}

	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.gitName = agent.gitName;
	agentSandbox.gitEmail = agent.gitEmail;
	agentSandbox.agentName = context.agentName;
	agentSandbox.workspaceName = context.workspaceName;

	auto sandbox = resolveSandbox(config.sandbox, configured.config.sandbox,
		workspaceSandbox, agentSandbox, context.projectDir, workspaceRoot,
		context.readOnly);
	auto rule = agent.nativeHistoryRule;
	enforce(rule.driver == configured.driver && rule.driver == agent.driver,
		"Configured native history rule driver does not match the configured Agent: "
		~ context.agentName);
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	enforce(profile.driver == rule.driver && profile.driver == agent.driver,
		"Configured native history profile driver does not match the configured Agent: "
		~ context.agentName);

	return ResolvedNativeHistoryContext(agent, sandbox, rule, profile);
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.agent.drivers.copilot : CopilotAgent;
	import cydo.runtime.config : AgentDriver;
	import cydo.runtime.launch.sandbox_paths : PathAccess;

	auto claudeRule = (new ClaudeCodeAgent()).nativeHistoryRule;
	assert(claudeRule.driver == AgentDriver.claude);
	assert(claudeRule.profileEnvName == "CLAUDE_CONFIG_DIR");
	assert(claudeRule.homeRelativeDefault == ".claude");
	assert(claudeRule.homeSupportRequirements.length == 2);
	assert(claudeRule.homeSupportRequirements[0].homeRelativePath == ".claude.json");
	assert(claudeRule.homeSupportRequirements[0].access == PathAccess.rw);
	assert(claudeRule.homeSupportRequirements[1].homeRelativePath
		== ".local/share/claude");
	assert(claudeRule.homeSupportRequirements[1].access == PathAccess.ro);

	auto codexRule = (new CodexAgent()).nativeHistoryRule;
	assert(codexRule.driver == AgentDriver.codex);
	assert(codexRule.profileEnvName == "CODEX_HOME");
	assert(codexRule.homeRelativeDefault == ".codex");
	assert(codexRule.homeSupportRequirements.length == 0);

	auto copilotRule = (new CopilotAgent()).nativeHistoryRule;
	assert(copilotRule.driver == AgentDriver.copilot);
	assert(copilotRule.profileEnvName == "COPILOT_HOME");
	assert(copilotRule.homeRelativeDefault == ".copilot");
	assert(copilotRule.homeSupportRequirements.length == 0);
}

unittest
{
	import configy.attributes : SetInfo;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.runtime.config : AgentConfig, AgentDriver, PathMode, WorkspaceConfig;

	auto root = buildPath("/tmp", "cydo-configured-native-history");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	mkdirRecurse(root);

	auto globalHome = buildPath(root, "global-home");
	auto globalProfile = buildPath(root, "global-profile");
	auto agentProfile = buildPath(root, "agent-profile");
	auto workspaceProfile = buildPath(root, "workspace-profile");
	auto workspaceRoot = buildPath(root, "workspace");
	auto projectDir = buildPath(workspaceRoot, "project");
	auto precedencePath = buildPath(root, "configured-path");
	mkdirRecurse(projectDir);

	CydoConfig config;
	config.sandbox.env = [
		"HOME": globalHome,
		"CODEX_HOME": globalProfile,
	];
	config.sandbox.paths = [precedencePath: PathMode.ro];
	AgentConfig configuredCodex;
	configuredCodex.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
	configuredCodex.sandbox.env["CODEX_HOME"] = agentProfile;
	configuredCodex.sandbox.paths = [precedencePath: PathMode.rw];
	config.agents["configured-codex"] = configuredCodex;
	WorkspaceConfig workspace;
	workspace.name = "selected-workspace";
	workspace.root = workspaceRoot;
	workspace.sandbox.env["CODEX_HOME"] = workspaceProfile;
	workspace.sandbox.paths = [precedencePath: PathMode.tmpfs];
	config.workspaces = [workspace];

	auto codex = new CodexAgent();
	auto workspaceRequest = ConfiguredNativeHistoryContext("configured-codex",
		"selected-workspace", projectDir, false);
	auto workspaceContext = resolveNativeHistoryContext(config, codex,
		workspaceRequest);
	assert(workspaceContext.profile.driver == AgentDriver.codex);
	assert(workspaceContext.profile.root == workspaceProfile);
	assert(workspaceContext.sandbox.env["CODEX_HOME"] == workspaceProfile);
	assert(workspaceContext.sandbox.paths.exact(workspaceProfile).isNull);
	assert(workspaceContext.sandbox.paths.exact(workspaceRoot).get.effectiveMode == PathMode.ro);
	assert(workspaceContext.sandbox.paths.exact(projectDir).get.effectiveMode == PathMode.rw);
	assert(workspaceContext.sandbox.paths.exact(precedencePath).get.effectiveMode
		== PathMode.tmpfs);
	assert(!exists(workspaceProfile));
	auto readOnlyRequest = ConfiguredNativeHistoryContext("configured-codex",
		"selected-workspace", projectDir, true);
	auto readOnlyContext = resolveNativeHistoryContext(config, codex, readOnlyRequest);
	assert(readOnlyContext.sandbox.paths.exact(projectDir).get.effectiveMode == PathMode.ro);

	auto noWorkspaceRequest = ConfiguredNativeHistoryContext("configured-codex", "", "", false);
	auto noWorkspaceContext = resolveNativeHistoryContext(config, codex, noWorkspaceRequest);
	assert(noWorkspaceContext.profile.root == agentProfile);
	assert(noWorkspaceContext.sandbox.env["CODEX_HOME"] == agentProfile);
	assert(noWorkspaceContext.sandbox.paths.exact(agentProfile).isNull);
	assert(noWorkspaceContext.sandbox.paths.exact(workspaceRoot).isNull);
	assert(!exists(agentProfile));

	CydoConfig globalOnlyConfig;
	globalOnlyConfig.sandbox.env = [
		"HOME": globalHome,
		"CODEX_HOME": globalProfile,
	];
	AgentConfig globalOnlyCodex;
	globalOnlyCodex.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
	globalOnlyConfig.agents["configured-codex"] = globalOnlyCodex;
	auto globalOnlyRequest = ConfiguredNativeHistoryContext("configured-codex", "", "", false);
	auto globalOnlyContext = resolveNativeHistoryContext(globalOnlyConfig, codex,
		globalOnlyRequest);
	assert(globalOnlyContext.profile.root == globalProfile);
	assert(globalOnlyContext.sandbox.env["CODEX_HOME"] == globalProfile);
	assert(globalOnlyContext.sandbox.paths.exact(globalProfile).isNull);
	assert(!exists(globalProfile));

	auto missingWorkspaceRequest = ConfiguredNativeHistoryContext("configured-codex",
		"missing-workspace", "", false);
	assertThrown!Exception(resolveNativeHistoryContext(config, codex, missingWorkspaceRequest));
	auto missingAgentRequest = ConfiguredNativeHistoryContext("missing-agent", "", "", false);
	assertThrown!Exception(resolveNativeHistoryContext(config, codex, missingAgentRequest));
	auto mismatchRequest = ConfiguredNativeHistoryContext("configured-codex", "", "", false);
	assertThrown!Exception(resolveNativeHistoryContext(config, new ClaudeCodeAgent(), mismatchRequest));
}

unittest
{
	import configy.attributes : SetInfo;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.runtime.config : AgentConfig, AgentDriver;

	auto root = buildPath("/tmp", "cydo-native-history-rendered-config");
	auto firstKey = "CYDO_NATIVE_HISTORY_RENDER_ONCE";
	auto secondKey = "CYDO_NATIVE_HISTORY_MUST_NOT_RENDER";
	auto oldFirst = environment.get(firstKey, "");
	auto oldSecond = environment.get(secondKey, "");
	bool hadFirst = firstKey in environment;
	bool hadSecond = secondKey in environment;
	scope (exit)
	{
		if (hadFirst)
			environment[firstKey] = oldFirst;
		else
			environment.remove(firstKey);
		if (hadSecond)
			environment[secondKey] = oldSecond;
		else
			environment.remove(secondKey);
	}
	environment[firstKey] = root ~ "/{{ env." ~ secondKey ~ " }}";
	environment[secondKey] = "expanded-on-a-second-pass";

	CydoConfig config;
	config.sandbox.env["CODEX_HOME"] = buildPath(root, "global-profile");
	AgentConfig configuredCodex;
	configuredCodex.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
	configuredCodex.sandbox.env = [
		"HOME": buildPath(root, "home"),
		"CODEX_HOME": "{{ env." ~ firstKey ~ " }}",
	];
	config.agents["configured-codex"] = configuredCodex;

	auto request = ConfiguredNativeHistoryContext("configured-codex", "", "", false);
	auto context = resolveNativeHistoryContext(config, new CodexAgent(), request);
	// The rendered agent value wins over global config and is not rendered again.
	assert(context.profile.root == root ~ "/{{ env." ~ secondKey ~ " }}");
}

unittest
{
	import ae.net.asockets : socketManager;
	import ae.utils.promise : Promise;
	import configy.attributes : SetInfo;
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.agent.resolver : createConfiguredAgent;
	import cydo.runtime.config : AgentConfig, AgentDriver;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch;

	auto root = buildPath("/tmp", "cydo-replay-native-history-launch");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	void verifyCompletionCleanup(bool succeeds)
	{
		auto name = succeeds ? "success" : "failure";
		auto home = buildPath(root, name ~ "-home");
		auto profileRoot = buildPath(root, name ~ "-profile");

		CydoConfig config;
		config.sandbox.isolate_filesystem = SetInfo!bool(true);
		config.sandbox.isolate_processes = SetInfo!bool(false);
		config.sandbox.isolate_environment = SetInfo!bool(false);
		config.sandbox.env["HOME"] = home;
		AgentConfig configured;
		configured.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
		configured.sandbox.env["CODEX_HOME"] = profileRoot;
		config.agents["standalone-codex"] = configured;

		auto agent = createConfiguredAgent(config, "standalone-codex");
		auto context = ConfiguredNativeHistoryContext("standalone-codex", "", "", false);
		auto resolved = resolveNativeHistoryContext(config, agent, context);
		assert(resolved.profile.root == profileRoot);
		assert(!exists(profileRoot));

		auto launch = prepareProcessLaunch(resolved.sandbox, resolved.rule,
			resolved.profile, "", agent.executableName(resolved.sandbox.env));
		assert(launch.nativeHistoryRule.driver == AgentDriver.codex);
		assert(launch.nativeHistoryProfile.root == profileRoot);
		assert(exists(profileRoot));
		write(buildPath(profileRoot, "config.toml"), "provider = \"configured\"\n");
		auto sourceTempFiles = launch.sandbox.tempFiles.dup;
		assert(sourceTempFiles.length > 0);
		foreach (tempFile; sourceTempFiles)
			assert(launch.cmdPrefix.canFind(tempFile));

		bool failed;
		auto completion = new Promise!string;
		completion.then((string result) {
		}).except((Exception e) {
			failed = true;
		}).finish({
			cleanup(launch.sandbox);
		}).ignoreResult();
		if (succeeds)
			completion.fulfill("result");
		else
			completion.reject(new Exception("failed"));
		socketManager.loop();

		assert(failed == !succeeds);
		assert(launch.sandbox.tempFiles.length == 0);
		foreach (tempFile; sourceTempFiles)
			assert(!exists(tempFile));
		assert(exists(profileRoot));
		assert(readText(buildPath(profileRoot, "config.toml"))
			== "provider = \"configured\"\n");
	}

	verifyCompletionCleanup(true);
	verifyCompletionCleanup(false);
}

unittest
{
	import ae.net.asockets : socketManager;
	import configy.attributes : SetInfo;
	import std.algorithm : canFind, sort;
	import std.conv : to;
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.agent.contract : Agent, SessionConfig;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.agent.drivers.copilot : CopilotAgent;
	import cydo.runtime.config : AgentConfig, AgentDriver;
	import cydo.runtime.launch.sandbox : cydoBinaryDir, prepareProcessLaunch;
	import cydo.runtime.launch.types : ProcessLaunch;

	struct LaunchGolden
	{
		string agentName;
		Agent agent;
		string executableEnvName;
		string executableFileName;
		string profileEnvName;
		string homeRelativeDefault;
		bool hasMcpConfig;
	}

	auto root = buildPath("/tmp", "cydo-native-history-default-launch-goldens");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	mkdirRecurse(root);
	auto backendHome = buildPath(root, "backend-home");
	mkdirRecurse(backendHome);

	auto environmentKeys = [
		"HOME", "PATH", "NIX_PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME",
		"OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "COPILOT_GITHUB_TOKEN",
		"GH_TOKEN", "GITHUB_TOKEN", "COPILOT_MODEL", "HTTPS_PROXY",
		"NODE_TLS_REJECT_UNAUTHORIZED",
	];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
		environment.remove(key);
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}
	environment["HOME"] = backendHome;
	environment["PATH"] = previousEnvironment["PATH"];

	LaunchGolden[] goldens = [
		LaunchGolden("claude", new ClaudeCodeAgent(), "CYDO_CLAUDE_BIN", "claude",
			"CLAUDE_CONFIG_DIR", ".claude", true),
		LaunchGolden("codex", new CodexAgent(), "CYDO_CODEX_BIN", "codex",
			"CODEX_HOME", ".codex", false),
		LaunchGolden("copilot", new CopilotAgent(), "CYDO_COPILOT_BIN", "copilot",
			"COPILOT_HOME", ".copilot", true),
	];

	string[] pathGolden(string executableDir, string profileRoot, string childHome,
		const ref LaunchGolden golden)
	{
		string[string] modes = [
			executableDir: "ro|ro",
			cydoBinaryDir(): "ro|ro",
			profileRoot: "rw|rw",
		];
		if (golden.agentName == "claude")
		{
			modes[buildPath(childHome, ".claude.json")] = "rw|rw";
			modes[buildPath(childHome, ".local", "share", "claude")] = "ro|ro";
		}
		string[] paths;
		foreach (path, _; modes)
			paths ~= path;
		paths.sort;
		string[] expected;
		foreach (path; paths)
			expected ~= path ~ "|" ~ modes[path];
		return expected;
	}

	string[] renderedPathGolden(ProcessLaunch launch)
	{
		string[] actual;
		foreach (view; launch.sandbox.paths.snapshot)
		{
			assert(!view.requirement.isNull);
			actual ~= view.path ~ "|" ~ view.requirement.get.access.to!string
				~ "|" ~ view.effectiveMode.to!string;
		}
		return actual;
	}

	void assertFullPrefix(ProcessLaunch launch, string workDir, bool isolated,
		string isolatedBaselineHome = "")
	{
		string[] expected = ["env"];
		if (isolated)
			expected ~= "-i";
		expected ~= ["-C", workDir];
		if (isolated)
			expected ~= "HOME=" ~ isolatedBaselineHome;
		// The caller already compares this environment to the complete golden;
		// preserve its runtime iteration order in the emitted argv.
		foreach (key, value; launch.sandbox.env)
			expected ~= key ~ "=" ~ value;
		assert(launch.cmdPrefix == expected);
	}

	foreach (golden; goldens)
	{
		auto driverRoot = buildPath(root, golden.agentName);
		auto childHome = buildPath(driverRoot, "child-home");
		auto executableDir = buildPath(driverRoot, "bin");
		auto executable = buildPath(executableDir, golden.executableFileName);
		auto workDir = buildPath(driverRoot, "workdir");
		mkdirRecurse(childHome);
		mkdirRecurse(executableDir);
		mkdirRecurse(workDir);
		write(executable, "#!/bin/sh\nexit 0\n");
		assert(execute(["chmod", "+x", executable]).status == 0);
		environment["HOME"] = childHome;

		string[string] expectedEnv = [
			"HOME": childHome,
			"PATH": executableDir,
		];
		expectedEnv[golden.executableEnvName] = executable;
		if (golden.agentName == "claude")
		{
			expectedEnv["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
			expectedEnv["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] = "0";
			expectedEnv["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false";
		}

		CydoConfig config;
		config.sandbox.isolate_filesystem = SetInfo!bool(false);
		config.sandbox.isolate_processes = SetInfo!bool(false);
		config.sandbox.isolate_environment = SetInfo!bool(false);
		config.sandbox.env = expectedEnv.dup;
		AgentConfig configured;
		configured.driver = SetInfo!AgentDriver(golden.agent.driver, true);
		config.agents[golden.agentName] = configured;
		auto context = ConfiguredNativeHistoryContext(golden.agentName, "", "", false);
		auto resolved = resolveNativeHistoryContext(config, golden.agent, context);
		auto profileRoot = buildPath(childHome, golden.homeRelativeDefault);
		auto launch = prepareProcessLaunch(resolved.sandbox, resolved.rule,
			resolved.profile, workDir, golden.agent.executableName(resolved.sandbox.env));

		assert(resolved.profile.driver == golden.agent.driver);
		assert(resolved.profile.root == profileRoot);
		assert(launch.sandbox.env == expectedEnv);
		assert((golden.profileEnvName in launch.sandbox.env) is null);
		auto actualPaths = renderedPathGolden(launch);
		auto expectedPaths = pathGolden(executableDir, profileRoot, childHome, golden);
		assert(actualPaths == expectedPaths);
		assert(launch.requestedExecutable == executable);
		assert(launch.executablePath == executable);
		assertFullPrefix(launch, workDir, false);

		if (golden.hasMcpConfig)
		{
			auto mcpSocket = buildPath(driverRoot, "mcp.sock");
			write(mcpSocket, "");
			auto session = golden.agent.createSession(71, "", launch,
				SessionConfig(mcpSocketPath: mcpSocket));
			auto mcpPath = buildPath(profileRoot, "mcp-configs", "cydo-71.json");
			assert(golden.agent.lastMcpConfigPath == mcpPath);
			assert(exists(mcpPath));
			session.closeStdin();
			socketManager.loop();
		}
		else
			assert(golden.agent.lastMcpConfigPath.length == 0);

		auto isolatedRoot = buildPath(driverRoot, "isolated");
		auto isolatedHome = buildPath(isolatedRoot, "child-home");
		auto isolatedExecutableDir = buildPath(isolatedRoot, "bin");
		auto isolatedExecutable = buildPath(isolatedExecutableDir, golden.executableFileName);
		auto isolatedWorkDir = buildPath(isolatedRoot, "workdir");
		auto backendProfileSentinel = buildPath(isolatedRoot, "backend-profile-sentinel");
		mkdirRecurse(isolatedHome);
		mkdirRecurse(isolatedExecutableDir);
		mkdirRecurse(isolatedWorkDir);
		write(isolatedExecutable, "#!/bin/sh\nexit 0\n");
		assert(execute(["chmod", "+x", isolatedExecutable]).status == 0);
		environment["HOME"] = isolatedHome;
		environment[golden.profileEnvName] = backendProfileSentinel;

		string[string] isolatedExpectedEnv = [
			"HOME": isolatedHome,
			"PATH": isolatedExecutableDir,
		];
		isolatedExpectedEnv[golden.executableEnvName] = isolatedExecutable;
		if (golden.agentName == "claude")
		{
			isolatedExpectedEnv["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
			isolatedExpectedEnv["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] = "0";
			isolatedExpectedEnv["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false";
		}

		CydoConfig isolatedConfig;
		isolatedConfig.sandbox.isolate_filesystem = SetInfo!bool(false);
		isolatedConfig.sandbox.isolate_processes = SetInfo!bool(false);
		isolatedConfig.sandbox.isolate_environment = SetInfo!bool(true);
		isolatedConfig.sandbox.env = isolatedExpectedEnv.dup;
		AgentConfig isolatedConfigured;
		isolatedConfigured.driver = SetInfo!AgentDriver(golden.agent.driver, true);
		isolatedConfig.agents[golden.agentName] = isolatedConfigured;
		auto isolatedResolved = resolveNativeHistoryContext(isolatedConfig, golden.agent,
			context);
		auto isolatedProfileRoot = buildPath(isolatedHome, golden.homeRelativeDefault);
		auto isolatedLaunch = prepareProcessLaunch(isolatedResolved.sandbox,
			isolatedResolved.rule, isolatedResolved.profile, isolatedWorkDir,
			golden.agent.executableName(isolatedResolved.sandbox.env));

		assert(isolatedResolved.profile.root == isolatedProfileRoot);
		assert(isolatedResolved.profile.root != backendProfileSentinel);
		assert((golden.profileEnvName in isolatedLaunch.sandbox.env) is null);
		assert(isolatedLaunch.sandbox.env == isolatedExpectedEnv);
		assert(renderedPathGolden(isolatedLaunch)
			== pathGolden(isolatedExecutableDir, isolatedProfileRoot, isolatedHome, golden));
		assert(isolatedLaunch.requestedExecutable == isolatedExecutable);
		assert(isolatedLaunch.executablePath == isolatedExecutable);
		assertFullPrefix(isolatedLaunch, isolatedWorkDir, true,
			isolatedHome);
		assert(!isolatedLaunch.cmdPrefix.canFind(backendProfileSentinel));
		environment.remove(golden.profileEnvName);
	}
}
