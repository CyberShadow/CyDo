module cydo.config;

import configy.attributes : Key, Optional;
import configy.read : parseConfigFileSimple;

import std.typecons : Nullable;

enum PathMode { ro, rw, always_rw, tmpfs, empty_dir, empty_file }

struct GitIdentityConfig
{
	string name;
	string email;
}

struct SandboxConfig
{
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
	uint max_depth = 3;
	@Optional string[] exclude;
	@Optional SandboxConfig sandbox;
	@Optional string task_types;
	@Optional string default_agent_type;
}

struct CydoConfig
{
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
	@Optional string default_agent_type = "claude";
	@Optional AgentConfig[string] agents;
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
			WorkspaceConfig("local", expandTilde("~"), 3, null),
		];
	}

	return config;
}

/// Re-parse config file. Returns null on parse error (caller keeps old config).
Nullable!CydoConfig reloadConfig()
{
	return parseConfigFileSimple!CydoConfig(configPath);
}
