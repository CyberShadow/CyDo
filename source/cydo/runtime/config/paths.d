module cydo.runtime.config.paths;

import std.path : buildPath, expandTilde;

string configDir()
{
	return expandTilde("~/.config/cydo");
}

string configPath()
{
	return buildPath(configDir(), "config.yaml");
}

string userTaskTypesPath()
{
	return buildPath(configDir(), "task-types.yaml");
}

string userDefsDir()
{
	return buildPath(configDir(), "defs");
}
