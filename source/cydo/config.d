module cydo.config;

import configy.attributes : Key, Optional;
import configy.read : parseConfigFileSimple;

import std.file : getcwd;
import std.typecons : Nullable;

enum PathMode { ro, rw }

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

struct WorkspaceConfig
{
	string name;
	string root;
	uint max_depth = 3;
	@Optional string[] exclude;
	@Optional SandboxConfig sandbox;
}

struct CydoConfig
{
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
}

CydoConfig loadConfig()
{
	import std.path : buildPath, expandTilde;

	auto configPath = buildPath(expandTilde("~/.config/cydo"), "config.yaml");
	auto result = parseConfigFileSimple!CydoConfig(configPath);

	if (result.isNull())
	{
		// No config file or parse error — fall back to single workspace at cwd
		return CydoConfig([
			WorkspaceConfig("local", getcwd(), 3, null),
		]);
	}

	return result.get();
}
