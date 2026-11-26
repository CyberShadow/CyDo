module cydo.runtime.launch.helper_jail;

version (linux):

import std.conv : to;
import std.exception : enforce;

import cydo.runtime.config : PathMode;
import cydo.runtime.launch.sandbox_paths : SandboxPaths;
import cydo.runtime.launch.sandbox_resolver : isStrictlyInside, planMounts;

struct HelperJail
{
	SandboxPaths paths;
	ulong tmpfsBytes;
	string[string] env;
	string stdinFile;
	string stdoutLink;
}

string[] buildHelperJailCommand(const ref HelperJail jail, const string[] command, string bwrap)
{
	auto args = [bwrap, "--unshare-user", "--unshare-ipc", "--unshare-pid",
		"--unshare-net", "--unshare-uts", "--unshare-cgroup", "--disable-userns",
		"--die-with-parent", "--new-session", "--clearenv"];
	args ~= ["--size", jail.tmpfsBytes.to!string, "--tmpfs", "/tmp"];
	if (jail.stdinFile.length)
		args ~= ["--file", "0", jail.stdinFile];
	if (jail.stdoutLink.length)
		args ~= ["--proc", "/proc", "--symlink", "/proc/self/fd/1", jail.stdoutLink];

	void checkMountTarget(string destination)
	{
		foreach (directory; ["/tmp", jail.stdoutLink.length ? "/proc" : null])
			if (directory.length)
				enforce(destination != directory && !isStrictlyInside(directory, destination),
					"Helper jail runtime path " ~ destination ~ " conflicts with synthetic mount " ~ directory);
		foreach (file; [jail.stdinFile, jail.stdoutLink])
			if (file.length)
				enforce(destination != file && !isStrictlyInside(file, destination)
					&& !isStrictlyInside(destination, file),
					"Helper jail runtime path " ~ destination ~ " conflicts with staging path " ~ file);
	}

	auto plan = planMounts(jail.paths, null, null);
	foreach (mount; plan.mounts)
	{
		enforce(mount.source == mount.destination,
			"Helper jail mount must bind host content: " ~ mount.destination);
		enforce(mount.mode == PathMode.ro,
			"Helper jail mount must be read-only: " ~ mount.destination);
		checkMountTarget(mount.destination);
		args ~= ["--ro-bind", mount.source, mount.destination];
	}
	foreach (link; plan.symlinks)
	{
		checkMountTarget(link.location);
		args ~= ["--symlink", link.target, link.location];
	}
	if (jail.stdoutLink.length)
		args ~= ["--remount-ro", "/proc"];
	args ~= ["--remount-ro", "/"];
	foreach (key, value; jail.env)
		args ~= ["--setenv", key, value];
	return args ~ ["--chdir", "/tmp", "--"] ~ command;
}

unittest
{
	import std.algorithm : canFind, count, countUntil;
	import std.exception : collectException;
	import std.file : mkdirRecurse, rmdirRecurse, symlink, tempDir;
	import std.path : buildPath;

	import ae.sys.file : realPath;
	import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind;

	auto root = buildPath(realPath(tempDir()), "cydo-helper-jail");
	mkdirRecurse(root);
	scope (exit) rmdirRecurse(root);
	auto bwrap = buildPath(root, "bwrap");

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
	auto args = buildHelperJailCommand(jail, command, bwrap);
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
	assert(args.countUntil(["--size", "4096", "--tmpfs", "/tmp"]) < args.countUntil("--ro-bind"));
	auto tail = ["--remount-ro", "/",
		"--setenv", "NAME", "value", "--chdir", "/tmp", "--"] ~ command;
	assert(args[$ - tail.length .. $] == tail);

	jail.stdinFile = first;
	auto collision = collectException(buildHelperJailCommand(jail, command, bwrap));
	assert(collision !is null && collision.msg ==
		"Helper jail runtime path " ~ first ~ " conflicts with staging path " ~ first);

	HelperJail invalid;
	invalid.paths.set(first, PathMode.rw, origin);
	auto writable = collectException(buildHelperJailCommand(invalid, command, bwrap));
	assert(writable !is null && writable.msg == "Helper jail mount must be read-only: " ~ first);

	invalid.paths.set(first, PathMode.tmpfs, origin);
	auto synthetic = collectException(buildHelperJailCommand(invalid, command, bwrap));
	assert(synthetic !is null && synthetic.msg == "Helper jail mount must bind host content: " ~ first);
}
