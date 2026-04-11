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

struct AgentConfig
{
	@Optional SandboxConfig sandbox;
	@Optional string[string] model_aliases;
}

struct WorkspaceConfig
{
	string name;
	string root;
	@Optional string[] exclude;
	@Optional SandboxConfig sandbox;
	@Optional string default_agent_type;
	@Optional string default_task_type;
	@Optional string permission_policy; /// Permission policy: "allow", "deny", "ask", or Djinja expression
	@Optional ProjectDiscoveryConfig project_discovery;
}

struct CydoConfig
{
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
	@Optional string default_agent_type = "claude";
	@Optional string default_task_type;
	@Optional AgentConfig[string] agents;
	@Optional bool dev_mode;
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

	return config;
}

/// Re-parse config file. Returns null on parse error (caller keeps old config).
Nullable!CydoConfig reloadConfig()
{
	return parseConfigFileSimple!CydoConfig(configPath);
}
