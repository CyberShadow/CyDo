module cydo.runtime.launch.sandbox_renderer;

import std.algorithm : canFind, splitter, startsWith, sort;
import std.array : array;
import std.file : exists, isFile, isSymlink, readLink;
import std.logger : tracef;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.string : toStringz;

import core.sys.posix.unistd : X_OK, access;

import cydo.runtime.config : PathMode;
import cydo.runtime.launch.sandbox_materialization : createGitConfigTempFile, createGroupTempFile,
	createPasswdTempFile, emptyDirPath, emptyFilePath;
import cydo.runtime.launch.types : ProcessLaunch, ResolvedSandbox;

/// Absolute path to the currently running cydo binary, resolved at
/// module init to avoid /proc/self/exe returning a "(deleted)" suffix
/// after the binary is replaced by a rebuild.
immutable string cydoBinaryPath;
shared static this()
{
	import std.file : thisExePath;
	cydoBinaryPath = thisExePath();
}

/// Get the directory containing the cydo binary.
string cydoBinaryDir()
{
	auto path = cydoBinaryPath;
	return path.length > 0 ? dirName(path) : "";
}

/// Look up an env value from the prepared launch environment, falling back to
/// the backend process environment when the sandbox did not override it.
string effectiveEnvValue(const string[string] env, string key, string fallback = "")
{
	if (auto value = key in env)
		return *value;
	return environment.get(key, fallback);
}

/// Resolve an executable using the effective launch PATH.
/// Returns an absolute path, or "" when it cannot be found/executed.
string resolveExecutablePath(string executable, const string[string] env)
{
	if (executable.length == 0)
		return "";

	auto requested = expandTilde(executable);
	if (requested.startsWith("/"))
		return isExecutableFile(requested) ? requested : "";

	auto pathVar = effectiveEnvValue(env, "PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		if (dir.length == 0)
			continue;
		auto candidate = buildPath(expandTilde(dir), requested);
		if (isExecutableFile(candidate))
			return candidate;
	}
	return "";
}

/// Return directories that must be mounted for an executable path.
/// Includes both the requested path's directory and the final symlink target's
/// directory when they differ.
string[] executableMountPaths(string executablePath)
{
	if (executablePath.length == 0)
		return null;

	string[] mounts;
	bool[string] seen;

	void addMount(string path)
	{
		if (path.length == 0)
			return;
		if (path in seen)
			return;
		seen[path] = true;
		mounts ~= path;
	}

	addMount(dirName(executablePath));
	auto resolved = resolveSymlinkChain(executablePath);
	if (resolved != executablePath)
		addMount(dirName(resolved));
	return mounts;
}

/// Build the command prefix for running a process with sandbox settings.
/// Returns bwrap args when filesystem or process isolation is needed,
/// env args when only environment/workdir management is needed,
/// or null when no prefix is required.
/// Append the inner command after the returned prefix.
string[] buildCommandPrefix(ref ResolvedSandbox sandbox, string workDir)
{
	if (!sandbox.useBwrap)
		return buildEnvPrefix(sandbox, workDir);

	string[] args;

	args ~= findBwrap();

	// Process isolation — gated on sandbox.isolate_processes
	if (sandbox.isolate_processes)
	{
		args ~= [
			"--unshare-ipc",
			"--unshare-pid",
			"--as-pid-1",
			"--unshare-uts",
			"--unshare-cgroup",
		];
	}

	args ~= "--share-net";
	args ~= "--die-with-parent";

	if (sandbox.isolate_filesystem)
	{
		// Restricted mode: selective bind mounts

		// Pseudo-filesystems
		args ~= ["--dev", "/dev"];
		args ~= ["--proc", "/proc"];
		if (sandbox.sharedTmpPath.length > 0)
			args ~= ["--bind", sandbox.sharedTmpPath, "/tmp"];
		else
			args ~= ["--tmpfs", "/tmp"];

		auto currentSystem = resolveNixCurrentSystem();

		if (currentSystem.length > 0)
		{
			// NixOS: mount nix store, system binaries, and minimal /etc + /run
			// entries needed for DNS, TLS, and bwrap-wrapped binaries.
			static immutable nixPaths = [
				"/nix",
				"/bin",
				"/lib64",
				"/usr/bin",
				"/etc/nix",
				"/etc/static/nix",
				"/etc/resolv.conf",
				"/etc/ssl",
				"/etc/static/ssl",
			];
			foreach (p; nixPaths)
				if (exists(p))
					args ~= ["--ro-bind", p, p];

			args ~= ["--tmpfs", "/run"];
			args ~= ["--symlink", currentSystem, "/run/current-system"];
			if (exists("/run/wrappers"))
				args ~= ["--ro-bind", "/run/wrappers", "/run/wrappers"];
		}
		else
		{
			// non-NixOS: bind-mount system directories so dynamically linked
			// binaries can find shared libraries, the ELF interpreter (ld-linux),
			// DNS resolver (systemd-resolved socket in /run), and CA certificates
			if (exists("/run"))
				args ~= ["--ro-bind", "/run", "/run"];
			if (exists("/etc"))
				args ~= ["--ro-bind", "/etc", "/etc"];
			if (exists("/usr"))
				args ~= ["--ro-bind", "/usr", "/usr"];
			if (exists("/lib64") && isSymlink("/lib64"))
				args ~= ["--symlink", readLink("/lib64"), "/lib64"];
			else if (exists("/lib64"))
				args ~= ["--ro-bind", "/lib64", "/lib64"];
			if (exists("/lib") && isSymlink("/lib"))
				args ~= ["--symlink", readLink("/lib"), "/lib"];
			else if (exists("/lib") && !exists("/lib64"))
				args ~= ["--ro-bind", "/lib", "/lib"];
		}

		// Cgroup filesystem
		if (exists("/sys/fs/cgroup"))
			args ~= ["--bind", "/sys/fs/cgroup", "/sys/fs/cgroup"];

		// Configured path binds — sorted by length so parent dirs are bound before
		// children. This ensures a child rw bind overrides a parent ro bind.
		auto sortedPaths = sandbox.paths.byKeyValue.array;
		sortedPaths.sort!((a, b) => a.key.length < b.key.length);
		foreach (entry; sortedPaths)
		{
			final switch (entry.value)
			{
				case PathMode.ro: args ~= ["--ro-bind", entry.key, entry.key]; break;
				case PathMode.rw: args ~= ["--bind", entry.key, entry.key]; break;
				case PathMode.always_rw: args ~= ["--bind", entry.key, entry.key]; break;
				case PathMode.tmpfs:
					args ~= ["--tmpfs", entry.key];
					break;
				case PathMode.empty_dir:
					args ~= ["--ro-bind", emptyDirPath(), entry.key];
					break;
				case PathMode.empty_file:
					args ~= ["--ro-bind", emptyFilePath(), entry.key];
					break;
			}
		}

		// /etc/passwd injection
		auto passwdTmp = createPasswdTempFile();
		if (passwdTmp.length > 0)
		{
			args ~= ["--ro-bind", passwdTmp, "/etc/passwd"];
			sandbox.tempFiles ~= passwdTmp;
		}

		// /etc/group injection
		auto groupTmp = createGroupTempFile();
		if (groupTmp.length > 0)
		{
			args ~= ["--ro-bind", groupTmp, "/etc/group"];
			sandbox.tempFiles ~= groupTmp;
		}

		// Git config injection
		auto gitTmp = createGitConfigTempFile(sandbox.gitName, sandbox.gitEmail);
		if (gitTmp.length > 0)
		{
			auto home = environment.get("HOME", "");
			args ~= ["--ro-bind", gitTmp, buildPath(home, ".config/git/config")];
			sandbox.tempFiles ~= gitTmp;
		}
	}
	else
	{
		// Unrestricted filesystem: --dev-bind / / gives the child full host
		// filesystem access including device nodes, /proc, etc.
		// bwrap always creates a mount namespace, so this is required.
		args ~= ["--dev-bind", "/", "/"];
	}

	// Environment
	if (sandbox.isolate_environment)
	{
		args ~= "--clearenv";
		args ~= ["--setenv", "HOME", environment.get("HOME", "/tmp")];

		auto nixPath = environment.get("NIX_PATH", "");
		if (nixPath.length > 0)
			args ~= ["--setenv", "NIX_PATH", nixPath];
	}

	foreach (k, v; sandbox.env)
		args ~= ["--setenv", k, v];

	// Working directory
	if (workDir.length > 0)
		args ~= ["--chdir", workDir];

	// Separator
	args ~= "--";

	return args;
}

/// Materialize a reusable process launch from a resolved sandbox and cwd.
ProcessLaunch prepareProcessLaunch(ResolvedSandbox sandbox, string workDir,
	string executable = "")
{
	ProcessLaunch launch;
	launch.sandbox = sandbox;
	launch.workDir = workDir;
	launch.executablePath = resolveExecutablePath(executable, launch.sandbox.env);
	launch.cmdPrefix = buildCommandPrefix(launch.sandbox, workDir);
	return launch;
}

/// Return a launch clone with an additional runtime environment variable.
/// The command prefix is recompiled from the sandbox model rather than patched
/// after argv generation. The executable path is intentionally left unchanged;
/// use this only for env vars that do not affect executable resolution.
ProcessLaunch withProcessLaunchEnv(ProcessLaunch launch, string key, string value)
{
	launch.sandbox.tempFiles = null;
	launch.sandbox.env = launch.sandbox.env.dup;
	launch.sandbox.env[key] = value;
	launch.cmdPrefix = buildCommandPrefix(launch.sandbox, launch.workDir);
	return launch;
}

private:

bool isExecutableFile(string path)
{
	return exists(path) && isFile(path) && access(toStringz(path), X_OK) == 0;
}

string resolveSymlinkChain(string path)
{
	auto current = path;
	for (int i = 0; i < 32 && exists(current) && isSymlink(current); i++)
	{
		auto target = readLink(current);
		if (!target.startsWith("/"))
			target = buildPath(dirName(current), target);
		current = target;
	}
	return current;
}

/// Build an env-based command prefix for non-bwrap mode.
string[] buildEnvPrefix(ref ResolvedSandbox sandbox, string workDir)
{
	bool hasEnv = (sandbox.env !is null && sandbox.env.length > 0) || sandbox.isolate_environment;
	bool hasWorkDir = workDir.length > 0;

	if (!hasEnv && !hasWorkDir)
		return null;

	string[] args = ["env"];

	// Options (-i, -C) must come before KEY=VALUE assignments;
	// GNU env stops option parsing at the first NAME=VALUE argument.
	if (sandbox.isolate_environment)
		args ~= "-i";

	if (hasWorkDir)
		args ~= ["-C", workDir];

	if (sandbox.isolate_environment)
	{
		args ~= "HOME=" ~ environment.get("HOME", "/tmp");
		auto nixPath = environment.get("NIX_PATH", "");
		if (nixPath.length > 0)
			args ~= "NIX_PATH=" ~ nixPath;
	}

	foreach (k, v; sandbox.env)
		args ~= k ~ "=" ~ v;

	return args;
}

/// Find the bwrap binary.
string findBwrap()
{
	foreach (candidate; ["/run/wrappers/bin/bwrap", "/usr/bin/bwrap"])
		if (exists(candidate))
			return candidate;

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, "bwrap");
		if (exists(candidate))
			return candidate;
	}

	assert(false, "bwrap binary not found");
}

/// Resolve /run/current-system symlink target (NixOS).
string resolveNixCurrentSystem()
{
	enum path = "/run/current-system";
	if (exists(path) && isSymlink(path))
	{
		try
			return readLink(path);
		catch (Exception e)
		{
			tracef("nixCurrentSystem: readLink failed: %s", e.msg);
			return "";
		}
	}
	return "";
}

unittest
{
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["CYDO_TEST_TOKEN"] = "value";

	auto launch = prepareProcessLaunch(sandbox, "/tmp/cydo-launch");
	assert(launch.workDir == "/tmp/cydo-launch");
	assert(launch.cmdPrefix == [
		"env",
		"-C", "/tmp/cydo-launch",
		"CYDO_TEST_TOKEN=value",
	]);

	// Preparing a launch should not mutate the caller's sandbox state.
	assert(sandbox.tempFiles.length == 0);
}

unittest
{
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["A"] = "1";

	auto launch = prepareProcessLaunch(sandbox, "/tmp/cydo-launch");
	launch.sandbox.tempFiles = ["/tmp/original-temp"];

	auto derived = withProcessLaunchEnv(launch, "B", "2");
	assert(("B" in launch.sandbox.env) is null);
	assert(launch.sandbox.tempFiles == ["/tmp/original-temp"]);
	assert(derived.sandbox.env["B"] == "2");
	assert(derived.sandbox.tempFiles.length == 0);
	assert(derived.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(derived.cmdPrefix.canFind("A=1"));
	assert(derived.cmdPrefix.canFind("B=2"));
}

unittest
{
	import std.file : mkdirRecurse, remove, write;
	import std.process : execute;

	auto binDir = buildPath("/tmp", "cydo-launch-bin");
	auto binPath = buildPath(binDir, "cydo-test-exec");
	mkdirRecurse(binDir);
	scope(exit)
	{
		if (exists(binPath))
			remove(binPath);
	}

	write(binPath, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", binPath]);

	ResolvedSandbox sandbox;
	sandbox.env["PATH"] = binDir;

	auto launch = prepareProcessLaunch(sandbox, "", "cydo-test-exec");
	assert(launch.executablePath == binPath);
	assert(executableMountPaths(binPath).canFind(binDir));
}
