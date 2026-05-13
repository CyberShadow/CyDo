module cydo.config;

import configy.attributes : Key, Optional, SetInfo;
import configy.read : parseConfigFileSimple;

import std.typecons : Nullable;

import cydo.discover : ProjectDiscoveryConfig;

enum PathMode { ro, rw, always_rw, tmpfs, empty_dir, empty_file }

struct GitIdentityConfig
{
	string name;
	string email;
}

struct SandboxConfig
{
	@Optional SetInfo!bool isolate_filesystem;
	@Optional SetInfo!bool isolate_processes;
	@Optional SetInfo!bool isolate_environment;
	@Optional PathMode[string] paths;
	@Optional string[string] env;
	@Optional GitIdentityConfig git;
}

enum AgentDriver { claude, codex, copilot }

struct AgentConfig
{
	@Optional SetInfo!AgentDriver driver;
	@Optional SandboxConfig sandbox;
	@Optional string[string] model_aliases;
	@Optional string display_name;
}

struct WorkspaceConfig
{
	string name;
	string root;
	@Optional string[] exclude;
	@Optional SandboxConfig sandbox;
	@Optional string default_agent;
	@Optional string default_task_type;
	@Optional string permission_policy; /// Permission policy: "allow", "deny", "ask", or Djinja expression
	@Optional ProjectDiscoveryConfig project_discovery;
}

struct CydoConfig
{
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
	@Optional string task_dir; /// Global per-task directory template (Djinja)
	@Optional string default_agent = "claude";
	@Optional string default_task_type;
	@Optional AgentConfig[string] agents;
	@Optional bool dev_mode;
	@Optional string log_level = "info";
	@Optional string system_keyword = "SYSTEM";
}

string configPath()
{
	import std.path : buildPath, expandTilde;
	return buildPath(expandTilde("~/.config/cydo"), "config.yaml");
}

CydoConfig loadConfig()
{
	auto result = parseConfigFileSimple!CydoConfig(configPath);

	CydoConfig config = result.isNull() ? CydoConfig.init : result.get();

	if (config.workspaces.length == 0)
	{
		import std.path : expandTilde;
		config.workspaces = [
			WorkspaceConfig("local", expandTilde("~")),
		];
	}

	applyAgentDriverOverlay(config);
	return config;
}

/// Re-parse config file. Returns null on parse error (caller keeps old config).
Nullable!CydoConfig reloadConfig()
{
	auto result = parseConfigFileSimple!CydoConfig(configPath);
	if (!result.isNull())
	{
		auto inner = result.get();
		applyAgentDriverOverlay(inner);
		result = Nullable!CydoConfig(inner);
	}
	return result;
}

private void applyAgentDriverOverlay(ref CydoConfig config)
{
	import std.conv : to;
	import cydo.agent.registry : agentRegistry;

	// Pass 1: infer driver from the AA key when it matches a known driver name
	foreach (name, ref ac; config.agents)
	{
		if (!ac.driver.set)
		{
			try
				ac.driver = SetInfo!AgentDriver(to!AgentDriver(name), true);
			catch (Exception e)
				throw new Exception(
					"agents['" ~ name ~ "']: driver field is required (not a known driver name)");
		}
	}

	// Pass 2: synthesize default entries for any driver not yet covered
	foreach (reg; agentRegistry)
	{
		auto driverEnum = to!AgentDriver(reg.name);
		bool covered = false;
		foreach (name, ref ac; config.agents)
		{
			if (name == reg.name) { covered = true; break; }
			if (ac.driver.set && ac.driver.value == driverEnum) { covered = true; break; }
		}
		if (!covered)
		{
			AgentConfig synthesized;
			synthesized.driver = SetInfo!AgentDriver(driverEnum, true);
			config.agents[reg.name] = synthesized;
		}
	}
}
