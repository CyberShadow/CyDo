module cydo.config;

import configy.attributes : Optional;
import configy.read : parseConfigFileSimple;

import std.file : getcwd;
import std.typecons : Nullable;

struct WorkspaceConfig
{
	string name;
	string root;
	uint max_depth = 3;
	@Optional string[] exclude;
}

struct CydoConfig
{
	WorkspaceConfig[] workspaces;
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
