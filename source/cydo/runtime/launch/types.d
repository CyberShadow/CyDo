module cydo.runtime.launch.types;

import cydo.runtime.config : PathMode;

struct AgentSandboxConfig
{
	void delegate(ref PathMode[string] paths, ref string[string] env) configureSandbox;
	string gitName;
	string gitEmail;
}

struct ResolvedSandbox
{
	bool isolate_filesystem;
	bool isolate_processes;
	bool isolate_environment;
	PathMode[string] paths;
	string[string] env;
	string gitName;
	string gitEmail;
	string[] tempFiles;
	string sharedTmpPath;

	@property bool useBwrap() const { return isolate_filesystem || isolate_processes; }
}

struct ProcessLaunch
{
	ResolvedSandbox sandbox;
	string workDir;
	string[] cmdPrefix;
	string executablePath;
}
