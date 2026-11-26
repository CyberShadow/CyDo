module cydo.runtime.launch.memory_scope;

version (linux):

import core.sys.posix.unistd : getuid;
import cydo.runtime.config : CydoConfig, MemoryLimitsConfig, SandboxConfig;
import cydo.runtime.config.paths : configDir;
import cydo.runtime.launch.sandbox_renderer : resolveExecutablePath;
import cydo.runtime.launch.types : AgentMemoryScope, AgentScopeHost, MemoryLimits, ResolvedSandbox;
import std.algorithm : canFind, endsWith, startsWith;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.file : readText;
import std.logger : infof;
import std.path : absolutePath;
import std.process : execute, thisProcessID;
import std.string : replace, split, strip, toLower;
import std.typecons : Nullable;

string agentSliceName()
{
	return "cydo-" ~ sha256Of(configDir()).toHexString[0 .. 12].toLower ~ ".slice";
}

Nullable!AgentMemoryScope resolveAgentMemoryScope(const ref CydoConfig config,
	const ref SandboxConfig agentLayer, const ref SandboxConfig workspaceLayer,
	Nullable!AgentScopeHost host)
{
	if (host.isNull)
		return Nullable!AgentMemoryScope.init;

	MemoryLimits limits;
	foreach (layer; [config.sandbox.memory, agentLayer.memory, workspaceLayer.memory])
	{
		if (layer.max.set)
			limits.max = layer.max.value;
		if (layer.high.set)
			limits.high = layer.high.value;
		if (layer.swap_max.set)
			limits.swapMax = layer.swap_max.value;
	}

	if (limits.max.isNull && limits.high.isNull && limits.swapMax.isNull
		&& !config.total_agent_memory.anySet())
		return Nullable!AgentMemoryScope.init;
	return Nullable!AgentMemoryScope(AgentMemoryScope(limits, host.get));
}

string findSystemdRun()
{
	auto executable = resolveExecutablePath("systemd-run", null);
	enforce(executable.length,
		"systemd-run was not found on PATH and is required for agent memory limits");
	return absolutePath(executable);
}

string[] memoryScopePrefix(const ref ResolvedSandbox sandbox)
{
	if (sandbox.memoryScope.isNull)
		return null;
	const scopeConfig = sandbox.memoryScope.get;
	const host = scopeConfig.host;
	const limits = scopeConfig.limits;
	// systemd-run parses dependency values as words and removes one level of escaping.
	auto boundUnit = host.boundUnit.replace(`\`, `\\`);
	string[] args = [findSystemdRun(), "--user", "--scope", "--quiet", "--collect",
		"--expand-environment=no", "--slice=" ~ host.slice, "--property=OOMPolicy=continue",
		"--property=BindsTo=" ~ boundUnit, "--property=StopPropagatedFrom=" ~ boundUnit,
		"--property=Before=" ~ boundUnit];
	if (!limits.max.isNull)
		args ~= "--property=MemoryMax=" ~ limits.max.get.toSystemd();
	if (!limits.high.isNull)
		args ~= "--property=MemoryHigh=" ~ limits.high.get.toSystemd();
	if (!limits.swapMax.isNull)
		args ~= "--property=MemorySwapMax=" ~ limits.swapMax.get.toSystemd();
	return args ~ "--";
}

private enum serviceRemedy = "\nMemory limits need CyDo to run as a systemd user service, "
	~ "so agents stop when CyDo stops and do not outlive it. Use a user unit "
	~ "(`systemctl --user start cydo`), or `systemd-run --user --unit=cydo "
	~ "[--setenv=VAR …] cydo`. For development: "
	~ "`systemd-run --user --pty --same-dir --wait --collect --unit=cydo-dev "
	~ "--setenv=… ./build/cydo`.";

string serviceUnitFromCgroup(string procSelfCgroup, uint uid)
{
	import std.string : splitLines;

	auto lines = procSelfCgroup.splitLines();
	enforce(lines.length == 1 && lines[0].startsWith("0::/"),
		"Memory limits require the cgroup v2 unified hierarchy" ~ serviceRemedy);
	auto path = lines[0][3 .. $];
	auto components = path.split("/");
	enforce(components.canFind("user@" ~ uid.to!string ~ ".service"),
		"CyDo is not running under your systemd user manager (cgroup " ~ path ~ ")" ~ serviceRemedy);
	auto unit = components[$ - 1];
	// systemd cg_unescape strips exactly one leading underscore.
	if (unit.startsWith("_"))
		unit = unit[1 .. $];
	enforce(unit.endsWith(".service"),
		"CyDo runs in " ~ unit ~ ", which is a scope, not a service" ~ serviceRemedy);
	return unit;
}

private string runSystemctl(string[] args)
{
	auto result = execute(args);
	enforce(result.status == 0, "systemctl failed: " ~ result.output.strip ~ serviceRemedy);
	return result.output.strip;
}

void requireMainProcess(string unit)
{
	auto mainPid = runSystemctl(["systemctl", "--user", "show", "--property=MainPID", "--value", "--", unit]);
	auto pid = thisProcessID.to!string;
	enforce(mainPid == pid, "CyDo PID " ~ pid ~ " is not MainPID " ~ mainPid ~ " of " ~ unit ~ serviceRemedy);
}

void requireMemoryControllerDelegated()
{
	auto group = runSystemctl(["systemctl", "--user", "show", "--property=ControlGroup", "--value"]);
	auto controllers = readText("/sys/fs/cgroup" ~ group ~ "/cgroup.controllers").split();
	enforce(controllers.canFind("memory"), "The systemd user manager lacks memory controller delegation");
}

private string[] sliceSetPropertyArgs(string slice, const ref MemoryLimitsConfig limits)
{
	return ["systemctl", "--user", "set-property", "--runtime", "--", slice,
		"MemoryMax=" ~ (limits.max.set ? limits.max.value.toSystemd() : "infinity"),
		"MemoryHigh=" ~ (limits.high.set ? limits.high.value.toSystemd() : "infinity"),
		"MemorySwapMax=" ~ (limits.swap_max.set ? limits.swap_max.value.toSystemd() : "infinity")];
}

string[] agentSliceSetPropertyArgs(const ref CydoConfig config, string slice = agentSliceName())
{
	return sliceSetPropertyArgs(slice, config.total_agent_memory);
}

void resetAgentSlice(string slice)
{
	const limits = MemoryLimitsConfig.init;
	runSystemctl(sliceSetPropertyArgs(slice, limits));
}

AgentScopeHost establishAgentScopeHost(const ref CydoConfig config)
{
	auto unit = serviceUnitFromCgroup(readText("/proc/self/cgroup"), getuid());
	requireMainProcess(unit);
	requireMemoryControllerDelegated();
	auto slice = agentSliceName();
	runSystemctl(agentSliceSetPropertyArgs(config, slice));
	infof("Agent memory limits use %s (bound to %s)", slice, unit);
	return AgentScopeHost(slice, unit);
}

unittest // Scope limits merge field by field, including explicit infinity.
{
	import configy.attributes : SetInfo;
	import cydo.runtime.config : MemorySize;

	CydoConfig config;
	SandboxConfig agent, workspace;
	auto host = Nullable!AgentScopeHost(AgentScopeHost("cydo-test.slice", "cydo.service"));
	assert(resolveAgentMemoryScope(config, agent, workspace, host).isNull);

	config.sandbox.memory.max = SetInfo!MemorySize(MemorySize.fromString("8G"), true);
	agent.memory.high = SetInfo!MemorySize(MemorySize.fromString("6G"), true);
	workspace.memory.max = SetInfo!MemorySize(MemorySize.fromString("infinity"), true);
	auto scopeConfig = resolveAgentMemoryScope(config, agent, workspace, host);
	assert(!scopeConfig.isNull);
	assert(scopeConfig.get.limits.max.get.toSystemd() == "infinity");
	assert(scopeConfig.get.limits.high.get.toSystemd() == "6442450944");
	assert(scopeConfig.get.limits.swapMax.isNull);
	assert(resolveAgentMemoryScope(config, agent, workspace, Nullable!AgentScopeHost.init).isNull);
}

unittest // The leaf service can be a regular or instantiated unit.
{
	enum prefix = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/";
	foreach (leaf, unit; ["cydo.service": "cydo.service", "cydo@prod.service": "cydo@prod.service",
		"__cydo.service": "_cydo.service", "-cydo.service": "-cydo.service"])
		assert(serviceUnitFromCgroup(prefix ~ leaf ~ "\n", 1000) == unit);
}

unittest // Other cgroup placements are rejected with an actionable diagnostic.
{
	import std.exception : collectException;

	foreach (cgroup, diagnostic; [
		"0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot-1234.scope":
			"scope, not a service",
		"0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope":
			"scope, not a service",
		"0::/user.slice/user-1000.slice/session-3.scope":
			"not running under your systemd user manager",
		"0::/system.slice/cydo.service": "not running under your systemd user manager",
		"0::/user.slice/user-1001.slice/user@1001.service/app.slice/cydo.service":
			"not running under your systemd user manager",
		"2:cpu:/user.slice\n1:memory:/user.slice\n": "cgroup v2",
	])
	{
		auto error = collectException(serviceUnitFromCgroup(cgroup, 1000));
		assert(error !is null, cgroup);
		assert(error.msg.canFind(diagnostic), error.msg);
	}
}

unittest // The user manager must identify this process as MainPID.
{
	import std.conv : octal;
	import std.exception : collectException;
	import std.file : mkdir, rmdirRecurse, setAttributes, tempDir, write;
	import std.path : buildPath;
	import std.process : environment;
	import std.string : splitLines;
	import std.uuid : randomUUID;

	auto bin = buildPath(tempDir(), "cydo-mainpid-" ~ randomUUID().toString());
	mkdir(bin);
	scope (exit) rmdirRecurse(bin);
	auto oldPath = environment["PATH"];
	environment["PATH"] = bin;
	scope (exit) environment["PATH"] = oldPath;
	auto systemctl = buildPath(bin, "systemctl");
	auto argsFile = buildPath(bin, "args");
	auto pid = thisProcessID.to!string;
	auto otherPid = (thisProcessID + 1).to!string;

	void replyWithPid(string value)
	{
		write(systemctl, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \""
			~ argsFile ~ "\"\nprintf '%s\\n' " ~ value ~ "\n");
		setAttributes(systemctl, octal!700);
	}

	replyWithPid(pid);
	foreach (unit; ["_cydo.service", "-cydo.service"])
	{
		requireMainProcess(unit);
		assert(readText(argsFile).splitLines()
			== ["--user", "show", "--property=MainPID", "--value", "--", unit]);
	}

	replyWithPid(otherPid);
	auto error = collectException(requireMainProcess("cydo.service"));
	assert(error !is null);
	assert(error.msg.canFind("CyDo PID " ~ pid ~ " is not MainPID " ~ otherPid), error.msg);
}

unittest // Setting only the aggregate maximum clears the other slice limits.
{
	import configy.attributes : SetInfo;
	import cydo.runtime.config : MemorySize;

	CydoConfig config;
	config.total_agent_memory.max = SetInfo!MemorySize(MemorySize.fromString("24G"), true);
	assert(agentSliceSetPropertyArgs(config) == [
		"systemctl", "--user", "set-property", "--runtime", "--", agentSliceName(),
		"MemoryMax=25769803776", "MemoryHigh=infinity", "MemorySwapMax=infinity",
	]);
}

unittest // Aggregate limits still place the agent in a scope tied to the service.
{
	import configy.attributes : SetInfo;
	import cydo.runtime.config : MemorySize;
	import std.conv : octal;
	import std.file : mkdir, rmdirRecurse, setAttributes, tempDir, write;
	import std.path : buildPath;
	import std.process : environment;
	import std.uuid : randomUUID;

	auto bin = buildPath(tempDir(), "cydo-scope-prefix-" ~ randomUUID().toString());
	mkdir(bin);
	scope (exit) rmdirRecurse(bin);
	auto oldPath = environment["PATH"];
	environment["PATH"] = bin;
	scope (exit) environment["PATH"] = oldPath;
	auto systemdRun = buildPath(bin, "systemd-run");
	write(systemdRun, "#!/bin/sh\nexit 0\n");
	setAttributes(systemdRun, octal!700);

	CydoConfig config;
	config.total_agent_memory.max = SetInfo!MemorySize(MemorySize.fromString("24G"), true);
	auto host = Nullable!AgentScopeHost(AgentScopeHost("cydo-test.slice", "cydo.service"));
	SandboxConfig agent, workspace;
	ResolvedSandbox sandbox;
	sandbox.memoryScope = resolveAgentMemoryScope(config, agent, workspace, host);
	auto args = memoryScopePrefix(sandbox);
	assert(args.canFind("--slice=cydo-test.slice"));
	assert(args.canFind("--property=BindsTo=cydo.service"));
	assert(args.canFind("--property=StopPropagatedFrom=cydo.service"));
	assert(args.canFind("--property=Before=cydo.service"));
	foreach (arg; args)
		assert(!arg.startsWith("--property=Memory"), arg);
}

unittest // Resetting the slice clears every memory limit and reports systemctl failures.
{
	import std.conv : octal;
	import std.exception : collectException;
	import std.file : mkdir, rmdirRecurse, setAttributes, tempDir, write;
	import std.path : buildPath;
	import std.process : environment;
	import std.string : splitLines;
	import std.uuid : randomUUID;

	auto bin = buildPath(tempDir(), "cydo-reset-slice-" ~ randomUUID().toString());
	mkdir(bin);
	scope (exit) rmdirRecurse(bin);
	auto oldPath = environment["PATH"];
	environment["PATH"] = bin;
	scope (exit) environment["PATH"] = oldPath;
	auto systemctl = buildPath(bin, "systemctl");
	auto argsFile = buildPath(bin, "args");
	enum slice = "cydo-test.slice";

	write(systemctl, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" ~ argsFile ~ "\"\n");
	setAttributes(systemctl, octal!700);
	resetAgentSlice(slice);
	assert(readText(argsFile).splitLines() == [
		"--user", "set-property", "--runtime", "--", slice,
		"MemoryMax=infinity", "MemoryHigh=infinity", "MemorySwapMax=infinity",
	]);

	write(systemctl, "#!/bin/sh\nprintf '%s\\n' 'Failed to connect to bus' >&2\nexit 1\n");
	auto error = collectException(resetAgentSlice(slice));
	assert(error !is null);
	assert(error.msg.canFind("Failed to connect to bus"), error.msg);
}
