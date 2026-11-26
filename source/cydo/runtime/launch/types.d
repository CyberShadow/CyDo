module cydo.runtime.launch.types;

import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.config : AgentDriver, MemorySize;
import std.typecons : Nullable;

struct AgentSandboxConfig
{
	void delegate(ref SandboxPaths paths, ref string[string] env) configureSandbox;
	string gitName;
	string gitEmail;
	string agentName;
	string workspaceName;
}

struct MemoryLimits
{
	Nullable!MemorySize max;
	Nullable!MemorySize high;
	Nullable!MemorySize swapMax;
}

struct AgentScopeHost
{
	string slice;
	string boundUnit;
}

struct AgentMemoryScope
{
	MemoryLimits limits;
	AgentScopeHost host;
}

struct ResolvedSandbox
{
	bool isolate_filesystem;
	bool isolate_processes;
	bool isolate_environment;
	SandboxPaths paths;
	string[string] env;
	string gitName;
	string gitEmail;
	string[] tempFiles;
	string sharedTmpPath;
	Nullable!AgentMemoryScope memoryScope;

	@property bool useBwrap() const { return isolate_filesystem || isolate_processes; }
}

struct NativeProfileSupportRequirement
{
	string homeRelativePath;
	PathAccess access;
	string purpose;
}

struct NativeHistoryRule
{
	AgentDriver driver;
	string profileEnvName;
	string homeRelativeDefault;
	NativeProfileSupportRequirement[] homeSupportRequirements;
}

struct NativeHistoryProfile
{
	AgentDriver driver;
	string root;
}

struct ProcessLaunch
{
	ResolvedSandbox preProfileSandbox;
	ResolvedSandbox sandbox;
	NativeHistoryRule nativeHistoryRule;
	NativeHistoryProfile nativeHistoryProfile;
	string workDir;
	string requestedExecutable;
	string[] cmdPrefix;
	string[] sandboxPrefix;
	string executablePath;
}

unittest
{
	import cydo.runtime.config : PathMode;

	auto sourceOrigin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"copy test", "source");
	auto copyOrigin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"copy test", "copy");
	enum path = "/tmp/cydo-resolved-sandbox-copy";

	ResolvedSandbox source;
	source.paths.require(path, PathAccess.ro, sourceOrigin);

	auto constructed = source;
	constructed.paths.require(path, PathAccess.rw, copyOrigin);
	assert(source.paths.exact(path).get.effectiveMode == PathMode.ro);
	assert(constructed.paths.exact(path).get.effectiveMode == PathMode.rw);

	ResolvedSandbox assigned;
	assigned = source;
	assigned.paths.require(path, PathAccess.alwaysRw, copyOrigin);
	assert(source.paths.exact(path).get.effectiveMode == PathMode.ro);
	assert(assigned.paths.exact(path).get.effectiveMode == PathMode.always_rw);
}

unittest
{
	import cydo.runtime.config : PathMode;

	auto sourceOrigin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"copy test", "source");
	auto copyOrigin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"copy test", "copy");
	enum path = "/tmp/cydo-process-launch-copy";

	ProcessLaunch source;
	source.sandbox.paths.require(path, PathAccess.ro, sourceOrigin);

	auto constructed = source;
	constructed.sandbox.paths.require(path, PathAccess.rw, copyOrigin);
	assert(source.sandbox.paths.exact(path).get.effectiveMode == PathMode.ro);
	assert(constructed.sandbox.paths.exact(path).get.effectiveMode == PathMode.rw);

	ProcessLaunch assigned;
	assigned = source;
	assigned.sandbox.paths.require(path, PathAccess.alwaysRw, copyOrigin);
	assert(source.sandbox.paths.exact(path).get.effectiveMode == PathMode.ro);
	assert(assigned.sandbox.paths.exact(path).get.effectiveMode == PathMode.always_rw);
}
