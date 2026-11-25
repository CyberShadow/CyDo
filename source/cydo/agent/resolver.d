module cydo.agent.resolver;

import std.conv : to;
import configy.attributes : SetInfo;

import cydo.agent.contract : Agent;
import cydo.agent.drivers.registry : agentRegistry;
import cydo.domain.policy.permissions : PermissionSettings;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, PermissionsConfig;

struct ResolvedAgent
{
	string name;
	AgentConfig config;
	AgentDriver driver;
}

ResolvedAgent resolveConfiguredAgent(ref CydoConfig config, string agentName)
{
	auto ac = agentName in config.agents;
	if (!ac)
		throw new Exception("Unknown configured agent: " ~ agentName);
	if (!ac.driver.set)
		throw new Exception("Configured agent is missing a driver: " ~ agentName);
	return ResolvedAgent(agentName, *ac, ac.driver.value);
}

bool isConfiguredAgentName(ref CydoConfig config, string agentName)
{
	return (agentName in config.agents) !is null;
}

Agent createAgentByDriver(AgentDriver driver)
{
	auto driverName = to!string(driver);
	foreach (ref entry; agentRegistry)
		if (entry.name == driverName)
			return entry.create();
	throw new Exception("Unknown driver: " ~ driverName);
}

Agent createConfiguredAgent(ref CydoConfig config, string agentName)
{
	auto resolved = resolveConfiguredAgent(config, agentName);
	auto agent = createAgentByDriver(resolved.driver);
	agent.setSystemKeyword(config.system_keyword);
	return agent;
}

Agent tryCreateConfiguredAgent(ref CydoConfig config, string agentName)
{
	if (!isConfiguredAgentName(config, agentName))
		return null;
	return createConfiguredAgent(config, agentName);
}

unittest
{
	CydoConfig config;
	config.system_keyword = "CYDO";
	AgentConfig configured;
	configured.driver = SetInfo!AgentDriver(AgentDriver.copilot, true);
	config.agents["custom-copilot"] = configured;
	auto agent = tryCreateConfiguredAgent(config, "custom-copilot");
	auto boundaries = agent.extractPersistedHistoryBoundaries(
		`{"type":"user.message","id":"wrapped","data":{"content":"[CYDO: bootstrap]"}}` ~ "\n"
		~ `{"type":"user.message","id":"ordinary","data":{"content":"[SYSTEM: bootstrap]"}}`);
	assert(boundaries.length == 1 && boundaries[0].anchor == "ordinary");
}

/// How tool calls of a task of the configured agent `agentName` in
/// `workspaceName` (empty = none) are decided: the `permissions` layers of
/// the global config, the agent entry and the workspace, in that order, as
/// `resolveSandbox` layers `sandbox`.
PermissionSettings resolvePermissionSettings(ref CydoConfig config,
	string agentName, string workspaceName)
{
	import core.time : seconds;
	import std.exception : enforce;

	PermissionsConfig[] layers = [config.permissions,
		resolveConfiguredAgent(config, agentName).config.permissions];
	if (workspaceName.length > 0)
	{
		bool foundWorkspace;
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
			{
				layers ~= ws.permissions;
				foundWorkspace = true;
				break;
			}
		enforce(foundWorkspace,
			"Permission settings for a deleted or unknown workspace: " ~ workspaceName);
	}

	PermissionSettings result;
	uint promptTimeout = 120;
	foreach (ref layer; layers)
	{
		if (layer.policy.set)
			result.policy = layer.policy.value;
		if (layer.auto_mode.set)
			result.autoMode = layer.auto_mode.value;
		if (layer.prompt_timeout.set)
			promptTimeout = layer.prompt_timeout.value;
	}
	result.promptTimeout = promptTimeout.seconds;
	return result;
}

SetInfo!string resolveUnsandboxedCommandExecution(ref CydoConfig config,
	string agentName, string workspaceName, out string source)
{
	auto result = config.sandbox.unsandboxed_command_execution;
	source = "sandbox";
	auto agentVerdict = resolveConfiguredAgent(config, agentName)
		.config.sandbox.unsandboxed_command_execution;
	if (agentVerdict.set)
	{
		result = agentVerdict;
		source = "agents['" ~ agentName ~ "'].sandbox";
	}
	if (workspaceName.length == 0)
		return result;

	foreach (ref workspace; config.workspaces)
		if (workspace.name == workspaceName)
		{
			if (workspace.sandbox.unsandboxed_command_execution.set)
			{
				source = "workspaces['" ~ workspaceName ~ "'].sandbox";
				return workspace.sandbox.unsandboxed_command_execution;
			}
			return result;
		}
	throw new Exception("Unsandboxed command settings for a deleted or unknown workspace: "
		~ workspaceName);
}

string effectiveDefaultAgentName(ref CydoConfig config, string workspaceName = "")
{
	if (workspaceName.length > 0)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_agent.length > 0)
			{
				if (!isConfiguredAgentName(config, ws.default_agent))
					throw new Exception("Workspace '" ~ workspaceName
						~ "' default_agent references unknown configured agent: "
						~ ws.default_agent);
				return ws.default_agent;
			}
	}

	if (config.default_agent.length > 0)
	{
		if (!isConfiguredAgentName(config, config.default_agent))
			throw new Exception("default_agent references unknown configured agent: "
				~ config.default_agent);
		return config.default_agent;
	}

	if (isConfiguredAgentName(config, "claude"))
		return "claude";

	string[] claudeAgentNames;
	foreach (name, ref ac; config.agents)
	{
		if (!ac.driver.set)
			throw new Exception("Configured agent is missing a driver: " ~ name);
		if (ac.driver.value == AgentDriver.claude)
			claudeAgentNames ~= name;
	}

	if (claudeAgentNames.length == 1)
		return claudeAgentNames[0];
	if (claudeAgentNames.length > 1)
		throw new Exception("Multiple Claude-configured agents exist; set default_agent explicitly");

	throw new Exception("No default agent could be resolved");
}

string displayNameForDriver(AgentDriver driver)
{
	auto driverName = to!string(driver);
	foreach (ref entry; agentRegistry)
		if (entry.name == driverName)
			return entry.displayName;
	return driverName;
}

unittest
{
	CydoConfig config;
	AgentConfig workClaude;
	workClaude.driver = typeof(workClaude.driver)(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;

	auto resolved = resolveConfiguredAgent(config, "work-claude");
	assert(resolved.name == "work-claude");
	assert(resolved.driver == AgentDriver.claude);
	assert(resolved.config.driver.set);
	assert(resolved.config.driver.value == AgentDriver.claude);
}

unittest
{
	CydoConfig config;
	try
	{
		resolveConfiguredAgent(config, "missing");
		assert(false, "expected resolveConfiguredAgent to throw");
	}
	catch (Exception e)
		assert(e.msg == "Unknown configured agent: missing");
}

unittest
{
	import core.time : seconds;
	import configy.attributes : SetInfo;
	import cydo.runtime.config : WorkspaceConfig;

	CydoConfig config;
	config.permissions.policy = SetInfo!string("allow");
	config.permissions.prompt_timeout = SetInfo!uint(30);
	AgentConfig plain;
	plain.driver = SetInfo!AgentDriver(AgentDriver.claude);
	config.agents["claude"] = plain;
	AgentConfig auto_;
	auto_.driver = SetInfo!AgentDriver(AgentDriver.claude);
	auto_.permissions.auto_mode = SetInfo!bool(true);
	auto_.permissions.policy = SetInfo!string("auto");
	config.agents["claude-auto"] = auto_;
	auto ws = WorkspaceConfig("work", "/tmp");
	ws.permissions.policy = SetInfo!string("ask");
	config.workspaces = [ws, WorkspaceConfig("bare", "/tmp")];

	// Nothing set anywhere: the defaults.
	CydoConfig empty;
	empty.agents["claude"] = plain;
	auto defaults = resolvePermissionSettings(empty, "claude", "");
	assert(defaults.policy == "" && !defaults.autoMode && defaults.promptTimeout == 120.seconds);

	// Global only.
	auto global = resolvePermissionSettings(config, "claude", "bare");
	assert(global.policy == "allow" && !global.autoMode && global.promptTimeout == 30.seconds);

	// The agent layer replaces what it sets and keeps the rest.
	auto agent = resolvePermissionSettings(config, "claude-auto", "bare");
	assert(agent.policy == "auto" && agent.autoMode && agent.promptTimeout == 30.seconds);

	// The workspace layer comes last.
	auto workspace = resolvePermissionSettings(config, "claude-auto", "work");
	assert(workspace.policy == "ask" && workspace.autoMode);

	import std.exception : assertThrown;
	assertThrown!Exception(resolvePermissionSettings(config, "claude", "missing"));
	assertThrown!Exception(resolvePermissionSettings(config, "missing", "work"));
}

unittest
{
	import cydo.runtime.config : WorkspaceConfig;
	import std.exception : assertThrown;

	CydoConfig config;
	AgentConfig agent;
	agent.driver = SetInfo!AgentDriver(AgentDriver.codex);
	config.agents["codex"] = agent;
	config.workspaces = [WorkspaceConfig("local", "/tmp")];
	string source;
	assert(!resolveUnsandboxedCommandExecution(config, "codex", "local", source).set);
	config.sandbox.unsandboxed_command_execution = SetInfo!string("ask");
	assert(resolveUnsandboxedCommandExecution(config, "codex", "local", source).value == "ask");
	assert(source == "sandbox");
	config.agents["codex"].sandbox.unsandboxed_command_execution = SetInfo!string("no");
	assert(resolveUnsandboxedCommandExecution(config, "codex", "local", source).value == "no");
	assert(source == "agents['codex'].sandbox");
	config.workspaces[0].sandbox.unsandboxed_command_execution = SetInfo!string("ask");
	assert(resolveUnsandboxedCommandExecution(config, "codex", "local", source).value == "ask");
	assert(source == "workspaces['local'].sandbox");
	assertThrown!Exception(resolveUnsandboxedCommandExecution(config, "codex", "missing", source));
}
