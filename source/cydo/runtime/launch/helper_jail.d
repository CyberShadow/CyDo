module cydo.runtime.launch.helper_jail;

version (linux):

import std.conv : to;
import std.exception : enforce;

import cydo.runtime.config : PathMode;
import cydo.runtime.launch.sandbox_paths : SandboxPaths;
import cydo.runtime.launch.sandbox_renderer : findBwrap;
import cydo.runtime.launch.sandbox_resolver : planMounts;

struct HelperJail
{
	SandboxPaths paths;
	ulong tmpfsBytes;
	string[string] env;
}

string[] buildHelperJailCommand(const ref HelperJail jail, const string[] command)
{
	auto args = [findBwrap(), "--unshare-user", "--unshare-ipc", "--unshare-pid",
		"--unshare-net", "--unshare-uts", "--unshare-cgroup", "--disable-userns",
		"--die-with-parent", "--new-session", "--clearenv"];
	auto plan = planMounts(jail.paths, null, null);
	foreach (mount; plan.mounts)
	{
		enforce(mount.source == mount.destination,
			"Helper jail mount must bind host content: " ~ mount.destination);
		enforce(mount.mode == PathMode.ro,
			"Helper jail mount must be read-only: " ~ mount.destination);
		args ~= ["--ro-bind", mount.source, mount.destination];
	}
	foreach (link; plan.symlinks)
		args ~= ["--symlink", link.target, link.location];
	args ~= ["--size", jail.tmpfsBytes.to!string, "--tmpfs", "/tmp", "--remount-ro", "/"];
	foreach (key, value; jail.env)
		args ~= ["--setenv", key, value];
	return args ~ ["--chdir", "/tmp", "--"] ~ command;
}

unittest
{
	import std.algorithm : canFind, count;
	import std.exception : collectException;
	import std.file : mkdirRecurse, rmdirRecurse, symlink, tempDir, write;
	import std.path : buildPath;
	import std.process : environment;

	import ae.sys.file : realPath;
	import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind;

	auto root = buildPath(realPath(tempDir()), "cydo-helper-jail");
	mkdirRecurse(root);
	scope (exit) rmdirRecurse(root);
	write(buildPath(root, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = root ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto first = buildPath(root, "first");
	auto second = buildPath(root, "second");
	auto link = buildPath(root, "link");
	mkdirRecurse(first);
	mkdirRecurse(second);
	symlink("second", link);
	auto jail = HelperJail(SandboxPaths.init, 4096, ["NAME": "value"]);
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, "helper", "test");
	jail.paths.require(first, PathAccess.ro, origin);
	jail.paths.require(link, PathAccess.ro, origin);

	auto command = [first ~ "/helper", "arg"];
	auto args = buildHelperJailCommand(jail, command);
	foreach (flag; ["--unshare-user", "--unshare-ipc", "--unshare-pid",
		"--unshare-net", "--unshare-uts", "--unshare-cgroup", "--disable-userns",
		"--die-with-parent", "--new-session", "--clearenv"])
		assert(args.canFind(flag), flag);
	foreach (flag; ["--share-net", "--proc", "--dev", "--bind", "/home", "/etc", "/run", "/sys"])
		assert(!args.canFind(flag), flag);
	assert(args.count("--ro-bind") == 2);
	assert(args.canFind(["--ro-bind", first, first]));
	assert(args.canFind(["--ro-bind", second, second]));
	assert(args.canFind(["--symlink", "second", link]));
	auto tail = ["--size", "4096", "--tmpfs", "/tmp", "--remount-ro", "/",
		"--setenv", "NAME", "value", "--chdir", "/tmp", "--"] ~ command;
	assert(args[$ - tail.length .. $] == tail);

	HelperJail invalid;
	invalid.paths.set(first, PathMode.rw, origin);
	auto writable = collectException(buildHelperJailCommand(invalid, command));
	assert(writable !is null && writable.msg == "Helper jail mount must be read-only: " ~ first);

	invalid.paths.set(first, PathMode.tmpfs, origin);
	auto synthetic = collectException(buildHelperJailCommand(invalid, command));
	assert(synthetic !is null && synthetic.msg == "Helper jail mount must bind host content: " ~ first);
}
