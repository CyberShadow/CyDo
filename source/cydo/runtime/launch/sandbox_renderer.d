module cydo.runtime.launch.sandbox_renderer;

import std.algorithm : canFind, splitter, startsWith;
import std.exception : enforce;
import std.file : exists, isDir, isFile, isSymlink, mkdirRecurse, readLink;
import std.logger : tracef;
import std.path : buildPath, dirName, expandTilde, isAbsolute;
import std.process : environment;
import std.string : toStringz;

import core.sys.posix.unistd : X_OK, access;

import ae.sys.file : realPath;

import cydo.runtime.config : PathMode;
import cydo.runtime.launch.sandbox_materialization : createGitConfigTempFile, createGroupTempFile,
	createPasswdTempFile, cleanup, emptyDirPath, emptyFilePath;
import cydo.runtime.launch.environment : effectiveChildEnvValue,
	isolatedChildHomeBaseline, resolveNativeHistoryProfile;
import cydo.runtime.launch.sandbox_paths : PathAccess, PlannedSandboxSymlink,
	SandboxPathOrigin, SandboxPathOriginKind;
import cydo.runtime.launch.sandbox_resolver : cydoBinaryPath, planMounts;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	NativeProfileSupportRequirement, ProcessLaunch, ResolvedSandbox;

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
	// Resolve to the physical location: symlink chains with relative targets
	// (e.g. npm's bin/codex -> ../lib/node_modules/.../codex.js) would
	// otherwise yield a '..' spelling, which path registration rejects.
	auto resolved = realPath(executablePath);
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
	return buildCommandPrefix(sandbox, workDir, resolveNixCurrentSystem());
}

private string[] buildCommandPrefix(ref ResolvedSandbox sandbox, string workDir,
	string currentSystem)
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

		// Host content and symlinks the renderer always provides; planned
		// together with the registry so that every mount lands at its
		// physical path.
		PathMode[string] builtinMounts;
		PlannedSandboxSymlink[] builtinSymlinks;

		// Pseudo-filesystems
		args ~= ["--dev", "/dev"];
		args ~= ["--proc", "/proc"];
		if (sandbox.sharedTmpPath.length > 0)
			args ~= ["--bind", sandbox.sharedTmpPath, "/tmp"];
		else
			args ~= ["--tmpfs", "/tmp"];

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
				"/run/wrappers",
			];
			foreach (p; nixPaths)
				if (exists(p))
					builtinMounts[p] = PathMode.ro;

			args ~= ["--tmpfs", "/run"];
			builtinSymlinks ~= PlannedSandboxSymlink("/run/current-system", currentSystem);
		}
		else
		{
			// non-NixOS: bind-mount system directories so dynamically linked
			// binaries can find shared libraries, the ELF interpreter (ld-linux),
			// DNS resolver (systemd-resolved socket in /run), and CA certificates
			foreach (p; ["/run", "/etc", "/usr"])
				if (exists(p))
					builtinMounts[p] = PathMode.ro;
			if (exists("/lib64") && isSymlink("/lib64"))
				builtinSymlinks ~= PlannedSandboxSymlink("/lib64", readLink("/lib64"));
			else if (exists("/lib64"))
				builtinMounts["/lib64"] = PathMode.ro;
			if (exists("/lib") && isSymlink("/lib"))
				builtinSymlinks ~= PlannedSandboxSymlink("/lib", readLink("/lib"));
			else if (exists("/lib") && !exists("/lib64"))
				builtinMounts["/lib"] = PathMode.ro;
		}

		// Cgroup filesystem
		if (exists("/sys/fs/cgroup"))
			builtinMounts["/sys/fs/cgroup"] = PathMode.rw;

		auto plan = planMounts(sandbox.paths, builtinMounts, builtinSymlinks);

		// A tmpfs directory parent supports later child binds. The current
		// read-only empty_dir lowering cannot create missing child mountpoints,
		// and empty_file is a leaf. This is a representation limitation, not
		// registry policy.
		foreach (entry; plan.mounts)
		{
			final switch (entry.mode)
			{
				case PathMode.ro:
					args ~= ["--ro-bind", entry.source, entry.destination];
					break;
				case PathMode.rw:
				case PathMode.always_rw:
					args ~= ["--bind", entry.source, entry.destination];
					break;
				case PathMode.tmpfs:
					args ~= ["--tmpfs", entry.destination];
					break;
				case PathMode.empty_dir:
					args ~= ["--ro-bind", emptyDirPath(), entry.destination];
					break;
				case PathMode.empty_file:
					args ~= ["--ro-bind", emptyFilePath(), entry.destination];
					break;
			}
		}

		// Planned mount destinations are physical paths, which never traverse
		// these symlinks, so creating them after all mounts is order-safe.
		foreach (symlink; plan.symlinks)
			args ~= ["--symlink", symlink.target, symlink.location];

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
		args ~= ["--setenv", "HOME", isolatedChildHomeBaseline()];

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
	if (sandbox.isolate_processes)
		args ~= [cydoBinaryPath, "sandbox-init", "--"];

	return args;
}

/// Materialize a reusable process launch from a resolved sandbox and cwd.
ProcessLaunch prepareProcessLaunch(ResolvedSandbox sandbox,
	const ref NativeHistoryRule rule, const ref NativeHistoryProfile profile,
	string workDir, string executable = "")
{
	auto evaluatedProfile = resolveNativeHistoryProfile(sandbox, rule);
	enforce(profile.driver == rule.driver,
		"Native history profile driver does not match its launch rule");
	enforce(profile.driver == evaluatedProfile.driver && profile.root == evaluatedProfile.root,
		"Native history profile does not match the rendered launch sandbox");
	return materializeProcessLaunch(sandbox, rule, profile, workDir, executable);
}

/// Return a launch clone with an additional runtime environment variable.
/// Rebuild the clone from the unmaterialized sandbox so its profile paths,
/// temporary files, executable, and prefix all reflect the overridden child env.
ProcessLaunch withProcessLaunchEnv(ProcessLaunch launch, string key, string value)
{
	auto sandbox = launch.preProfileSandbox;
	sandbox.env = launch.preProfileSandbox.env.dup;
	// The source launch retains ownership of its baseline temporary files.
	// Materialization records only resources created for this clone.
	sandbox.tempFiles = null;
	sandbox.env[key] = value;
	auto profile = resolveNativeHistoryProfile(sandbox, launch.nativeHistoryRule);
	return materializeProcessLaunch(sandbox, launch.nativeHistoryRule, profile,
		launch.workDir, launch.requestedExecutable);
}

private:

ProcessLaunch materializeProcessLaunch(ResolvedSandbox sandbox,
	const ref NativeHistoryRule rule, const ref NativeHistoryProfile profile,
	string workDir, string executable)
{
	ProcessLaunch launch;
	launch.preProfileSandbox = sandbox;
	launch.preProfileSandbox.env = sandbox.env.dup;
	launch.preProfileSandbox.tempFiles = sandbox.tempFiles.dup;
	launch.sandbox = launch.preProfileSandbox;
	launch.sandbox.env = launch.preProfileSandbox.env.dup;
	launch.sandbox.tempFiles = launch.preProfileSandbox.tempFiles.dup;
	launch.nativeHistoryRule = NativeHistoryRule(rule.driver, rule.profileEnvName,
		rule.homeRelativeDefault, rule.homeSupportRequirements.dup);
	launch.nativeHistoryProfile = NativeHistoryProfile(profile.driver, profile.root);
	launch.workDir = workDir;
	launch.requestedExecutable = executable;

	materializeNativeHistoryProfile(launch.sandbox, rule, profile);
	launch.executablePath = resolveExecutablePath(executable, launch.sandbox.env);
	auto prefixTempFileCount = launch.sandbox.tempFiles.length;
	try
		launch.cmdPrefix = buildCommandPrefix(launch.sandbox, workDir);
	catch (Exception e)
	{
		ResolvedSandbox prefixTemps;
		prefixTemps.tempFiles = launch.sandbox.tempFiles[prefixTempFileCount .. $].dup;
		cleanup(prefixTemps);
		launch.sandbox.tempFiles = launch.sandbox.tempFiles[0 .. prefixTempFileCount].dup;
		throw e;
	}
	return launch;
}

void materializeNativeHistoryProfile(ref ResolvedSandbox sandbox,
	const ref NativeHistoryRule rule, const ref NativeHistoryProfile profile)
{
	enforce(profile.root.length > 0 && isAbsolute(profile.root),
		"Native history launch profile root must be an absolute directory: "
		~ profile.root);
	mkdirRecurse(profile.root);
	enforce(isDir(profile.root),
		"Native history launch profile root is not a directory: " ~ profile.root);
	sandbox.paths.require(profile.root, PathAccess.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			rule.profileEnvName, "native history profile root"));
	auto rootView = sandbox.paths.exact(profile.root);
	enforce(!rootView.isNull && (rootView.get.effectiveMode == PathMode.rw
		|| rootView.get.effectiveMode == PathMode.always_rw),
		"Native history launch profile root is capped read-only by sandbox configuration: "
		~ profile.root);

	auto home = effectiveChildEnvValue(sandbox, "HOME");
	foreach (requirement; rule.homeSupportRequirements)
		sandbox.paths.require(buildPath(home.value, requirement.homeRelativePath),
			requirement.access,
			SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				rule.profileEnvName, requirement.purpose));
}

bool isExecutableFile(string path)
{
	return exists(path) && isFile(path) && access(toStringz(path), X_OK) == 0;
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
		args ~= "HOME=" ~ isolatedChildHomeBaseline();
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

	throw new Exception("bubblewrap (bwrap) is required for process/filesystem "
		~ "sandboxing of spawned agents, which is enabled by default, but the "
		~ "bwrap binary was not found. Looked in "
		~ "/run/wrappers/bin/bwrap, /usr/bin/bwrap, and the backend PATH. "
		~ "Install bubblewrap using your distribution's package manager.");
}

unittest
{
	if (exists("/run/wrappers/bin/bwrap") || exists("/usr/bin/bwrap"))
		return;

	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = "/tmp/cydo-find-bwrap-without-binary";
	scope (exit) environment["PATH"] = oldPath;

	bool thrown;
	try
		findBwrap();
	catch (Exception e)
	{
		thrown = true;
		assert(e.msg.canFind("bwrap"), e.msg);
		assert(e.msg.canFind("bubblewrap"), e.msg);
	}
	assert(thrown);
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

version (unittest) private NativeHistoryRule rendererTestNativeHistoryRule()
{
	import cydo.runtime.config : AgentDriver;

	return NativeHistoryRule(AgentDriver.codex,
		"CYDO_TEST_NATIVE_HISTORY_ROOT", ".cydo-test", null);
}

version (unittest) private NativeHistoryProfile rendererTestNativeHistoryProfile(
	ref ResolvedSandbox sandbox, const ref NativeHistoryRule rule, string root)
{
	if ("HOME" !in sandbox.env)
		sandbox.env["HOME"] = "/tmp";
	sandbox.env[rule.profileEnvName] = root;
	return resolveNativeHistoryProfile(sandbox, rule);
}

version (unittest) private size_t rendererSequenceIndex(const string[] args,
	const string[] sequence)
{
	foreach (i; 0 .. args.length)
		if (i + sequence.length <= args.length
			&& args[i .. i + sequence.length] == sequence)
			return i;
	assert(false, "argument sequence not found");
}

version (unittest) private size_t rendererSequenceCount(const string[] args,
	const string[] sequence)
{
	size_t count;
	foreach (i; 0 .. args.length)
		if (i + sequence.length <= args.length
			&& args[i .. i + sequence.length] == sequence)
			++count;
	return count;
}

unittest
{
	import std.file : exists, rmdirRecurse;

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["CYDO_TEST_TOKEN"] = "value";
	auto profileRoot = "/tmp/cydo-renderer-basic-profile";
	if (exists(profileRoot))
		rmdirRecurse(profileRoot);
	scope (exit)
		if (exists(profileRoot))
			rmdirRecurse(profileRoot);
	auto rule = rendererTestNativeHistoryRule();
	auto profile = rendererTestNativeHistoryProfile(sandbox, rule, profileRoot);

	auto launch = prepareProcessLaunch(sandbox, rule, profile, "/tmp/cydo-launch");
	assert(launch.workDir == "/tmp/cydo-launch");
	assert(launch.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(launch.cmdPrefix.canFind("CYDO_TEST_TOKEN=value"));
	assert(launch.cmdPrefix.canFind("CYDO_TEST_NATIVE_HISTORY_ROOT=" ~ profileRoot));

	// Preparing a launch should not mutate the caller's sandbox state.
	assert(sandbox.tempFiles.length == 0);
}

unittest
{
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-launch-native-history-materialization");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto home = buildPath(root, "home");
	auto profileRoot = buildPath(root, "claude-profile");
	auto stateFile = buildPath(home, ".claude.json");
	auto dataDir = buildPath(home, ".local", "share", "claude");
	mkdirRecurse(fakeBin);
	mkdirRecurse(dataDir);
	write(buildPath(fakeBin, "bwrap"), "");
	write(stateFile, "{}");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto rule = NativeHistoryRule(
		AgentDriver.claude,
		"CLAUDE_CONFIG_DIR",
		".claude",
		[
			NativeProfileSupportRequirement(".claude.json", PathAccess.rw,
				"Claude state file"),
			NativeProfileSupportRequirement(".local/share/claude", PathAccess.ro,
				"Claude data directory"),
		],
	);
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = home;
	sandbox.env["CLAUDE_CONFIG_DIR"] = profileRoot;
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	assert(!exists(profileRoot));
	assert(sandbox.paths.exact(profileRoot).isNull);

	auto launch = prepareProcessLaunch(sandbox, rule, profile, "");
	scope (exit)
		foreach (tempFile; launch.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
	assert(exists(profileRoot));
	assert(launch.preProfileSandbox.paths.exact(profileRoot).isNull);
	auto rootView = launch.sandbox.paths.exact(profileRoot).get;
	assert(rootView.requirement.get.access == PathAccess.rw);
	assert(rootView.effectiveMode == PathMode.rw);
	auto stateView = launch.sandbox.paths.exact(stateFile).get;
	assert(stateView.requirement.get.access == PathAccess.rw);
	assert(stateView.effectiveMode == PathMode.rw);
	auto dataView = launch.sandbox.paths.exact(dataDir).get;
	assert(dataView.requirement.get.access == PathAccess.ro);
	assert(dataView.effectiveMode == PathMode.ro);
	assert(launch.cmdPrefix.canFind(["--bind", profileRoot, profileRoot]));
	assert(launch.cmdPrefix.canFind(["--bind", stateFile, stateFile]));
	assert(launch.cmdPrefix.canFind(["--ro-bind", dataDir, dataDir]));
}

unittest
{
	import std.algorithm : canFind;
	import cydo.runtime.config : AgentDriver;

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = "/tmp/cydo-native-history-invalid-home";
	sandbox.env["CODEX_HOME"] = "cydo-native-history-relative-root";
	auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	auto profile = NativeHistoryProfile(AgentDriver.codex,
		"cydo-native-history-relative-root");
	bool thrown;
	try
		prepareProcessLaunch(sandbox, rule, profile, "");
	catch (Exception e)
	{
		thrown = true;
		assert(e.msg.canFind("CODEX_HOME"), e.msg);
	}
	assert(thrown);
}

unittest
{
	import std.exception : assertThrown;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-launch-native-history-readonly-profile");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto home = buildPath(root, "home");
	auto readOnlyWorktree = buildPath(root, "read-only-worktree");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(home);
	mkdirRecurse(readOnlyWorktree);
	write(buildPath(fakeBin, "bwrap"), "");

	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	bool hadTmpDir = "TMPDIR" in environment;
	scope (exit)
	{
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
	}
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = home;
	sandbox.env["CODEX_HOME"] = readOnlyWorktree;
	sandbox.paths.set(readOnlyWorktree, PathMode.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			"task checkout", "configured writable checkout"));
	sandbox.paths.restrictExactToReadOnly(readOnlyWorktree,
		SandboxPathOrigin(SandboxPathOriginKind.exactReadOnly,
			"task checkout", "read-only active worktree"));
	auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	auto profile = resolveNativeHistoryProfile(sandbox, rule);

	bool rejected;
	try
		prepareProcessLaunch(sandbox, rule, profile, "");
	catch (Exception e)
	{
		rejected = true;
		assert(e.msg.canFind("capped read-only"), e.msg);
	}
	assert(rejected);
	foreach (entry; dirEntries(prefixTempDir, SpanMode.shallow))
		assert(false, "profile writability rejection created prefix temp file: " ~ entry.name);
}

unittest
{
	import std.exception : assertThrown;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-launch-native-history-prefix-cleanup");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto hostHome = buildPath(root, "host-home");
	auto childHome = buildPath(root, "child-home");
	auto profileRoot = buildPath(root, "profile");
	auto retainedTemp = buildPath(root, "retained-temp");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(buildPath(hostHome, ".config", "git", "config"));
	mkdirRecurse(childHome);
	write(buildPath(fakeBin, "bwrap"), "");
	write(retainedTemp, "retained");

	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	auto oldUser = environment.get("USER", "");
	bool hadTmpDir = "TMPDIR" in environment;
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["HOME"] = hostHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;
	environment["USER"] = "root";

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.gitName = "prefix cleanup";
	sandbox.env["HOME"] = childHome;
	sandbox.env["CODEX_HOME"] = profileRoot;
	sandbox.tempFiles = [retainedTemp];
	auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	assertThrown!Exception(prepareProcessLaunch(sandbox, rule, profile, ""));
	assert(exists(retainedTemp));
	foreach (entry; dirEntries(prefixTempDir, SpanMode.shallow))
		assert(false, "failed prefix materialization leaked temp file: " ~ entry.name);
}

unittest
{
	import std.file : exists, rmdirRecurse;

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["A"] = "1";
	auto profileRoot = "/tmp/cydo-renderer-clone-profile";
	if (exists(profileRoot))
		rmdirRecurse(profileRoot);
	scope (exit)
		if (exists(profileRoot))
			rmdirRecurse(profileRoot);
	auto rule = rendererTestNativeHistoryRule();
	auto profile = rendererTestNativeHistoryProfile(sandbox, rule, profileRoot);

	auto source = prepareProcessLaunch(sandbox, rule, profile, "/tmp/cydo-launch");
	source.sandbox.tempFiles = ["/tmp/original-temp"];
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourcePrefix = source.cmdPrefix.dup;

	auto first = withProcessLaunchEnv(source, "B", "2");
	auto second = withProcessLaunchEnv(source, "C", "3");
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.sandbox.env == sourceEnv);
	assert(source.cmdPrefix == sourcePrefix);
	assert(("B" in source.sandbox.env) is null);
	assert(("C" in source.sandbox.env) is null);
	assert(first.sandbox.env["A"] == "1");
	assert(first.sandbox.env["B"] == "2");
	assert(second.sandbox.env["A"] == "1");
	assert(second.sandbox.env["C"] == "3");
	assert(first.sandbox.tempFiles.length == 0);
	assert(second.sandbox.tempFiles.length == 0);
	assert(first.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(second.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(first.cmdPrefix.canFind("A=1"));
	assert(first.cmdPrefix.canFind("B=2"));
	assert(second.cmdPrefix.canFind("A=1"));
	assert(second.cmdPrefix.canFind("C=3"));
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-launch-native-history-clone");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto firstHome = buildPath(root, "first-home");
	auto secondHome = buildPath(root, "second-home");
	auto explicitProfile = buildPath(root, "explicit-profile");
	mkdirRecurse(firstHome);
	mkdirRecurse(secondHome);

	auto rule = NativeHistoryRule(
		AgentDriver.claude,
		"CLAUDE_CONFIG_DIR",
		".claude",
		[
			NativeProfileSupportRequirement(".claude.json", PathAccess.rw,
				"Claude state file"),
			NativeProfileSupportRequirement(".local/share/claude", PathAccess.ro,
				"Claude data directory"),
		],
	);
	ResolvedSandbox sandbox;
	sandbox.env["HOME"] = firstHome;
	auto sourceProfile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, sourceProfile, "");
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto oldStateFile = buildPath(firstHome, ".claude.json");
	auto oldDataDir = buildPath(firstHome, ".local", "share", "claude");
	assert(source.preProfileSandbox.paths.exact(sourceProfile.root).isNull);
	assert(source.preProfileSandbox.paths.exact(oldStateFile).isNull);
	assert(source.preProfileSandbox.paths.exact(oldDataDir).isNull);

	auto homeOverride = withProcessLaunchEnv(source, "HOME", secondHome);
	auto secondProfileRoot = buildPath(secondHome, ".claude");
	assert(homeOverride.nativeHistoryProfile.root == secondProfileRoot);
	assert(exists(secondProfileRoot));
	assert(homeOverride.sandbox.paths.exact(sourceProfile.root).isNull);
	assert(homeOverride.sandbox.paths.exact(oldStateFile).isNull);
	assert(homeOverride.sandbox.paths.exact(oldDataDir).isNull);
	assert(homeOverride.sandbox.paths.exact(secondProfileRoot).get.effectiveMode == PathMode.rw);
	assert(homeOverride.sandbox.paths.exact(buildPath(secondHome, ".claude.json"))
		.get.effectiveMode == PathMode.rw);
	assert(homeOverride.sandbox.paths.exact(buildPath(secondHome, ".local", "share", "claude"))
		.get.effectiveMode == PathMode.ro);

	auto profileOverride = withProcessLaunchEnv(source, "CLAUDE_CONFIG_DIR", explicitProfile);
	assert(profileOverride.nativeHistoryProfile.root == explicitProfile);
	assert(exists(explicitProfile));
	assert(profileOverride.sandbox.paths.exact(sourceProfile.root).isNull);
	assert(profileOverride.sandbox.paths.exact(oldStateFile).get.effectiveMode == PathMode.rw);
	assert(profileOverride.sandbox.paths.exact(oldDataDir).get.effectiveMode == PathMode.ro);

	assert(source.nativeHistoryProfile.root == sourceProfile.root);
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.env == sourceEnv);
	assert(source.cmdPrefix == sourcePrefix);
	assert(source.sandbox.paths.exact(sourceProfile.root).get.effectiveMode == PathMode.rw);
	assert(source.sandbox.paths.exact(oldStateFile).get.effectiveMode == PathMode.rw);
	assert(source.sandbox.paths.exact(oldDataDir).get.effectiveMode == PathMode.ro);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-launch-native-history-profile-overrides");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto home = buildPath(root, "home");
	mkdirRecurse(home);
	NativeHistoryRule[] rules = [
		NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null),
		NativeHistoryRule(AgentDriver.copilot, "COPILOT_HOME", ".copilot", null),
	];

	foreach (rule; rules)
	{
		auto sourceRoot = buildPath(root, rule.profileEnvName ~ "-source");
		auto overrideRoot = buildPath(root, rule.profileEnvName ~ "-override");
		ResolvedSandbox sandbox;
		sandbox.env["HOME"] = home;
		sandbox.env[rule.profileEnvName] = sourceRoot;
		auto sourceProfile = resolveNativeHistoryProfile(sandbox, rule);
		auto source = prepareProcessLaunch(sandbox, rule, sourceProfile, "");
		auto sourcePaths = source.sandbox.paths.snapshot;
		auto sourceEnv = source.sandbox.env.dup;
		auto sourceTempFiles = source.sandbox.tempFiles.dup;
		auto sourcePrefix = source.cmdPrefix.dup;

		auto clone = withProcessLaunchEnv(source, rule.profileEnvName, overrideRoot);
		assert(clone.nativeHistoryProfile.root == overrideRoot);
		assert(exists(overrideRoot));
		assert(clone.sandbox.paths.exact(sourceRoot).isNull);
		assert(clone.sandbox.paths.exact(overrideRoot).get.effectiveMode == PathMode.rw);
		assert(source.sandbox.paths.exact(overrideRoot).isNull);
		assert(source.nativeHistoryProfile.root == sourceRoot);
		assert(source.sandbox.paths.snapshot == sourcePaths);
		assert(source.sandbox.env == sourceEnv);
		assert(source.sandbox.tempFiles == sourceTempFiles);
		assert(source.cmdPrefix == sourcePrefix);
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : PathAccess;

	auto root = buildPath("/tmp", "cydo-renderer-derived-launch");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto logicalHostMount = buildPath(root, "logical-host-mount");
	auto logicalSecondHostMount = buildPath(root, "logical-second-host-mount");
	mkdirRecurse(logicalHostMount);
	mkdirRecurse(logicalSecondHostMount);
	string[] plannedMountSubsequence(string[] args, string[] configuredPaths)
	{
		bool isConfiguredPath(string path)
		{
			foreach (configuredPath; configuredPaths)
				if (path == configuredPath)
					return true;
			return false;
		}

		string[] result;
		foreach (i; 0 .. args.length)
		{
			if (args[i] == "--tmpfs" && i + 1 < args.length
				&& isConfiguredPath(args[i + 1]))
				result ~= args[i .. i + 2];
			else if ((args[i] == "--ro-bind" || args[i] == "--bind")
				&& i + 2 < args.length
				&& (isConfiguredPath(args[i + 1])
					|| isConfiguredPath(args[i + 2])))
				result ~= args[i .. i + 3];
		}
		return result;
	}

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["A"] = "1";
	sandbox.paths.set(logicalHostMount, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
			"derived launch", "logical host mount"));
	sandbox.paths.set(logicalSecondHostMount, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
			"derived launch", "second logical host mount"));

	auto rule = rendererTestNativeHistoryRule();
	auto profile = rendererTestNativeHistoryProfile(sandbox, rule,
		buildPath(root, "profile"));
	auto source = prepareProcessLaunch(sandbox, rule, profile, "");
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto configuredPaths = [logicalHostMount, logicalSecondHostMount];
	auto sourceMounts = plannedMountSubsequence(sourcePrefix, configuredPaths);
	assert(sourceMounts == [
		"--ro-bind", logicalHostMount, logicalHostMount,
		"--ro-bind", logicalSecondHostMount, logicalSecondHostMount,
	]);

	auto first = withProcessLaunchEnv(source, "B", "2");
	auto second = withProcessLaunchEnv(source, "C", "3");
	scope (exit)
	{
		foreach (tempFile; source.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
		foreach (tempFile; first.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
		foreach (tempFile; second.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
	}

	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.sandbox.env == sourceEnv);
	assert(source.cmdPrefix == sourcePrefix);
	assert(first.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);
	assert(first.sandbox.env["A"] == "1");
	assert(first.sandbox.env["B"] == "2");
	assert(second.sandbox.env["A"] == "1");
	assert(second.sandbox.env["C"] == "3");
	assert(first.cmdPrefix.canFind(["--setenv", "A", "1"]));
	assert(first.cmdPrefix.canFind(["--setenv", "B", "2"]));
	assert(second.cmdPrefix.canFind(["--setenv", "A", "1"]));
	assert(second.cmdPrefix.canFind(["--setenv", "C", "3"]));
	assert(plannedMountSubsequence(first.cmdPrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(second.cmdPrefix, configuredPaths) == sourceMounts);
	size_t separator = first.cmdPrefix.length;
	size_t firstMountStart = first.cmdPrefix.length;
	size_t secondMountStart = first.cmdPrefix.length;
	foreach (i; 0 .. first.cmdPrefix.length)
	{
		if (first.cmdPrefix[i] == "--")
		{
			separator = i;
		}
		else if ((first.cmdPrefix[i] == "--ro-bind" || first.cmdPrefix[i] == "--bind")
			&& i + 2 < first.cmdPrefix.length
			&& first.cmdPrefix[i + 1] == logicalHostMount
			&& first.cmdPrefix[i + 2] == logicalHostMount)
			firstMountStart = i;
		else if ((first.cmdPrefix[i] == "--ro-bind" || first.cmdPrefix[i] == "--bind")
			&& i + 2 < first.cmdPrefix.length
			&& first.cmdPrefix[i + 1] == logicalSecondHostMount
			&& first.cmdPrefix[i + 2] == logicalSecondHostMount)
			secondMountStart = i;
	}
	assert(separator < first.cmdPrefix.length);
	assert(firstMountStart < secondMountStart);
	auto divergentFirstPrefix = first.cmdPrefix[0 .. separator].dup;
	divergentFirstPrefix ~= ["--bind", logicalHostMount, logicalHostMount];
	divergentFirstPrefix ~= first.cmdPrefix[separator .. $];
	assert(plannedMountSubsequence(divergentFirstPrefix,
		configuredPaths) != sourceMounts);
	auto missingFirstPrefix = first.cmdPrefix[0 .. firstMountStart].dup;
	missingFirstPrefix ~= first.cmdPrefix[firstMountStart + 3 .. $];
	assert(plannedMountSubsequence(missingFirstPrefix, configuredPaths) != sourceMounts);
	auto swappedFirstPrefix = first.cmdPrefix.dup;
	swappedFirstPrefix[firstMountStart .. firstMountStart + 3]
		= first.cmdPrefix[secondMountStart .. secondMountStart + 3];
	swappedFirstPrefix[secondMountStart .. secondMountStart + 3]
		= first.cmdPrefix[firstMountStart .. firstMountStart + 3];
	assert(plannedMountSubsequence(swappedFirstPrefix, configuredPaths) != sourceMounts);

	auto repeatedSourcePrefix = buildCommandPrefix(source.sandbox, source.workDir);
	auto repeatedFirstPrefix = buildCommandPrefix(first.sandbox, first.workDir);
	auto repeatedSecondPrefix = buildCommandPrefix(second.sandbox, second.workDir);
	assert(plannedMountSubsequence(repeatedSourcePrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(repeatedFirstPrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(repeatedSecondPrefix, configuredPaths) == sourceMounts);
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(first.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);

	auto sourceTempFilesBeforeMutation = source.sandbox.tempFiles.dup;
	auto sourceEnvBeforeMutation = source.sandbox.env.dup;
	auto secondTempFilesBeforeMutation = second.sandbox.tempFiles.dup;
	auto secondEnvBeforeMutation = second.sandbox.env.dup;
	auto derivedTempFile = buildPath(root, "derived-temp");
	write(derivedTempFile, "");
	first.sandbox.env["DERIVED_ONLY"] = "present";
	first.sandbox.tempFiles ~= derivedTempFile;
	first.sandbox.paths.require(logicalHostMount, PathAccess.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			"derived launch", "derived write"));
	assert(("B" in source.sandbox.env) is null);
	assert(("C" in source.sandbox.env) is null);
	assert(("DERIVED_ONLY" in source.sandbox.env) is null);
	assert(source.sandbox.tempFiles == sourceTempFilesBeforeMutation);
	assert(source.sandbox.env == sourceEnvBeforeMutation);
	assert(second.sandbox.tempFiles == secondTempFilesBeforeMutation);
	assert(second.sandbox.env == secondEnvBeforeMutation);
	assert(first.sandbox.tempFiles.canFind(derivedTempFile));
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.ro);
	assert(second.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.ro);
	assert(first.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.rw);
}

unittest
{
	import std.file : mkdirRecurse, remove, rmdirRecurse, symlink, write;
	import std.path : buildPath;

	import ae.sys.file : realPath;

	// Paths are added to the sandbox after resolveSandbox (task dir,
	// worktree, git dirs); they must still be mounted at their physical paths
	// with the traversed symlinks recreated, so planning happens at render time.
	auto root = buildPath(realPath("/tmp"), "cydo-renderer-symlink");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	// findBwrap only produces argv[0]; satisfy it in environments without a
	// real bwrap (the Nix build sandbox).
	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope(exit)
		environment["PATH"] = oldPath;

	auto wsRoot = buildPath(root, "ws");
	auto projectDir = buildPath(wsRoot, "project");
	auto hop = buildPath(root, "hop"); // hop → moved
	auto taskDir = buildPath(root, "moved", "tasks", "1");
	auto tasksLink = buildPath(wsRoot, ".cydo", "tasks"); // → hop/tasks
	mkdirRecurse(taskDir);
	mkdirRecurse(projectDir);
	mkdirRecurse(buildPath(wsRoot, ".cydo"));
	symlink("moved", hop);
	symlink(buildPath(hop, "tasks"), tasksLink);

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.paths.set(wsRoot, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault, "renderer test",
			"workspace root"));
	sandbox.paths.set(projectDir, PathMode.rw,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault, "renderer test",
			"project"));
	sandbox.paths.set(buildPath(tasksLink, "1"), PathMode.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, "renderer test",
			"task directory"));

	auto args = buildCommandPrefix(sandbox, "");
	scope(exit)
		foreach (tempFile; sandbox.tempFiles)
			remove(tempFile);
	assert(args.canFind(["--ro-bind", wsRoot, wsRoot]));
	assert(args.canFind(["--bind", projectDir, projectDir]));
	assert(args.canFind(["--bind", taskDir, taskDir]));
	assert(!args.canFind(buildPath(tasksLink, "1")));
	// The workspace mount exposes tasksLink itself; only hop is recreated, and
	// only after every mount.
	assert(!args.canFind(["--symlink", buildPath(hop, "tasks"), tasksLink]));
	auto hopIndex = rendererSequenceIndex(args, ["--symlink", "moved", hop]);
	assert(rendererSequenceIndex(args, ["--bind", taskDir, taskDir]) < hopIndex);
}

unittest
{
	import std.file : mkdirRecurse, remove, rmdirRecurse, write;
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

	auto profileRoot = buildPath(binDir, "profile");
	if (exists(profileRoot))
		rmdirRecurse(profileRoot);
	scope (exit)
		if (exists(profileRoot))
			rmdirRecurse(profileRoot);
	auto rule = rendererTestNativeHistoryRule();
	auto profile = rendererTestNativeHistoryProfile(sandbox, rule, profileRoot);
	auto launch = prepareProcessLaunch(sandbox, rule, profile, "", "cydo-test-exec");
	assert(launch.executablePath == binPath);
	assert(executableMountPaths(binPath).canFind(binDir));
}

unittest
{
	import std.file : readText, remove, rmdirRecurse, write;
	import std.process : execute, environment;
	import cydo.runtime.launch.sandbox_materialization : taskTmpAgentPath,
		taskTmpHostPath;

	auto root = buildPath("/tmp", "cydo-renderer-task-tmp");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto sharedTmp = buildPath(root, "shared");
	auto hostTmp = taskTmpHostPath(sharedTmp, 7);
	mkdirRecurse(hostTmp);
	write(buildPath(hostTmp, "input"), "from-host\n");

	auto oldTmpDir = environment.get("TMPDIR", "");
	auto hadTmpDir = "TMPDIR" in environment;
	scope (exit)
	{
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
	}
	environment["TMPDIR"] = buildPath(root, "inherited");

	foreach (isolated; [false, true])
	{
		// Only the sandboxed Nix unit-test derivation opts out of real bwrap.
		if (isolated && environment.get("CYDO_TEST_SKIP_BWRAP", "") != "")
			continue;
		if (isolated)
			assert(resolveExecutablePath("bwrap", null).length > 0,
				"bwrap is required for the isolated renderer test; run under nix develop "
				~ "or set CYDO_TEST_SKIP_BWRAP");
		ResolvedSandbox sandbox;
		sandbox.isolate_filesystem = isolated;
		sandbox.isolate_processes = false;
		sandbox.isolate_environment = false;
		sandbox.sharedTmpPath = sharedTmp;
		sandbox.env["TMPDIR"] = taskTmpAgentPath(sharedTmp, 7, isolated);
		auto prefix = buildCommandPrefix(sandbox, "");
		auto result = execute(prefix ~ ["/bin/sh", "-c",
			"cat \"$TMPDIR/input\" && printf '%s' \"$TMPDIR\" > \"$TMPDIR/output\""]);
		assert(result.status == 0, result.output);
		assert(result.output == "from-host\n");
		assert(readText(buildPath(hostTmp, "output")) == sandbox.env["TMPDIR"]);
		foreach (tempFile; sandbox.tempFiles)
			remove(tempFile);
	}
}

// An executable reached through a symlink with a relative target (npm's
// global-install layout) must resolve to its physical package directory,
// not a '..' spelling, which path registration rejects.
unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
	import std.process : execute;

	auto root = buildPath("/tmp", "cydo-launch-npm-layout");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto binDir = buildPath(root, "bin");
	auto pkgBinDir = buildPath(root, "lib", "node_modules", "@openai", "codex", "bin");
	mkdirRecurse(binDir);
	mkdirRecurse(pkgBinDir);
	auto script = buildPath(pkgBinDir, "codex.js");
	write(script, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", script]);
	auto link = buildPath(binDir, "codex");
	symlink("../lib/node_modules/@openai/codex/bin/codex.js", link);

	auto mounts = executableMountPaths(link);
	assert(mounts.canFind(binDir));
	assert(mounts.canFind(realPath(pkgBinDir)));
	foreach (mount; mounts)
		assert(!mount.canFind(".."));
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-renderer-all-modes");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto roPath = buildPath(root, "ro");
	auto rwPath = buildPath(root, "rw");
	auto alwaysRwPath = buildPath(root, "always-rw");
	auto tmpfsPath = buildPath(root, "tmpfs");
	auto emptyDirPath_ = buildPath(root, "empty-dir");
	auto emptyFilePath_ = buildPath(root, "empty-file");
	foreach (path; [roPath, rwPath, alwaysRwPath, tmpfsPath, emptyDirPath_])
		mkdirRecurse(path);
	write(emptyFilePath_, "");

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"renderer modes", "configured mount");
	sandbox.paths.set(roPath, PathMode.ro, origin);
	sandbox.paths.set(rwPath, PathMode.rw, origin);
	sandbox.paths.set(alwaysRwPath, PathMode.always_rw, origin);
	sandbox.paths.set(tmpfsPath, PathMode.tmpfs, origin);
	sandbox.paths.set(emptyDirPath_, PathMode.empty_dir, origin);
	sandbox.paths.set(emptyFilePath_, PathMode.empty_file, origin);
	auto logicalBefore = sandbox.paths.snapshot;

	auto args = buildCommandPrefix(sandbox, "");
	auto repeatedArgs = buildCommandPrefix(sandbox, "");
	scope (exit)
		foreach (tempFile; sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
	assert(args.canFind(["--ro-bind", roPath, roPath]));
	assert(args.canFind(["--bind", rwPath, rwPath]));
	assert(args.canFind(["--bind", alwaysRwPath, alwaysRwPath]));
	assert(args.canFind(["--tmpfs", tmpfsPath]));
	assert(args.canFind(["--ro-bind", emptyDirPath(), emptyDirPath_]));
	assert(args.canFind(["--ro-bind", emptyFilePath(), emptyFilePath_]));
	assert(repeatedArgs.canFind(["--ro-bind", roPath, roPath]));
	assert(repeatedArgs.canFind(["--bind", rwPath, rwPath]));
	assert(repeatedArgs.canFind(["--bind", alwaysRwPath, alwaysRwPath]));
	assert(repeatedArgs.canFind(["--tmpfs", tmpfsPath]));
	assert(repeatedArgs.canFind(["--ro-bind", emptyDirPath(), emptyDirPath_]));
	assert(repeatedArgs.canFind(["--ro-bind", emptyFilePath(), emptyFilePath_]));

	auto logicalAfter = sandbox.paths.snapshot;
	assert(logicalAfter.length == logicalBefore.length);
	foreach (i, view; logicalBefore)
	{
		assert(logicalAfter[i].path == view.path);
		assert(logicalAfter[i].effectiveMode == view.effectiveMode);
		assert(logicalAfter[i].declaration.get.mode == view.declaration.get.mode);
		assert(logicalAfter[i].declaration.get.origin.kind == view.declaration.get.origin.kind);
		assert(logicalAfter[i].declaration.get.origin.scope_
			== view.declaration.get.origin.scope_);
		assert(logicalAfter[i].declaration.get.origin.detail
			== view.declaration.get.origin.detail);
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	import cydo.runtime.config : SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : cydoBinaryDir, resolveSandbox;
	import cydo.runtime.launch.sandbox_paths : SandboxPaths;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	assert(exists("/nix/store"), "renderer /nix mount test requires /nix/store");

	auto root = buildPath("/tmp", "cydo-renderer-nix-mount");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
	{
		if (exists(root))
			rmdirRecurse(root);
	}

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto nixMount = ["--ro-bind", "/nix", "/nix"];
	auto requirementOrigin = SandboxPathOrigin(
		SandboxPathOriginKind.launchRequirement, "renderer nix mount", "required path");
	auto configOrigin = SandboxPathOrigin(
		SandboxPathOriginKind.globalConfig, "renderer nix mount", "user path");

	ResolvedSandbox required;
	required.isolate_filesystem = true;
	required.paths.requireReadVisible("/nix/store", requirementOrigin);
	assert(!required.paths.exact("/nix").isNull);
	auto requiredArgs = buildCommandPrefix(required, "", "");
	assert(rendererSequenceCount(requiredArgs, nixMount) == 1);

	ResolvedSandbox withoutNix;
	withoutNix.isolate_filesystem = true;
	auto withoutNixArgs = buildCommandPrefix(withoutNix, "", "");
	assert(rendererSequenceCount(withoutNixArgs, nixMount) == 0);

	ResolvedSandbox nixOs;
	nixOs.isolate_filesystem = true;
	auto nixOsArgs = buildCommandPrefix(nixOs, "", "/run/current-system");
	assert(rendererSequenceCount(nixOsArgs, nixMount) == 1);

	ResolvedSandbox configured;
	configured.isolate_filesystem = true;
	configured.paths.set("/nix", PathMode.ro, configOrigin);
	configured.paths.requireReadVisible("/nix/store", requirementOrigin);
	auto configuredArgs = buildCommandPrefix(configured, "", "");
	assert(rendererSequenceCount(configuredArgs, nixMount) == 1);

	assert(withoutNixArgs[$ - 1] == "--");
	assert(!withoutNixArgs.canFind("sandbox-init"));

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};
	auto isolated = resolveSandbox(SandboxConfig.init, SandboxConfig.init,
		SandboxConfig.init, agent, "");
	auto isolatedArgs = buildCommandPrefix(isolated, "", "");
	assert(isolatedArgs.canFind(["--unshare-pid", "--as-pid-1"]));
	assert(isolatedArgs[$ - 4 .. $] == ["--", cydoBinaryPath, "sandbox-init", "--"]);
	assert(isolatedArgs.canFind(["--ro-bind", cydoBinaryDir(), cydoBinaryDir()]));
	assert(isolated.paths.exact(cydoBinaryDir()).get.requirement.get.access == PathAccess.ro);

	foreach (sandbox; [required, withoutNix, configured, isolated])
		foreach (tempFile; sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, symlink, write;
	import std.path : buildPath;

	// /bin/sh is a symlink into /nix/store in Nix test environments. The test
	// only creates a link in /tmp and never writes to the store itself.
	auto physicalTarget = realPath("/bin/sh");
	if (!exists("/nix/store") || !physicalTarget.startsWith("/nix/"))
		return;

	auto root = buildPath("/tmp", "cydo-renderer-nix-symlink");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
	{
		if (exists(root))
			rmdirRecurse(root);
	}

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto executable = buildPath(fakeBin, "nix-shell");
	symlink("/bin/sh", executable);
	auto resolvedExecutable = resolveExecutablePath(executable, null);
	assert(resolvedExecutable == executable);
	assert(realPath(resolvedExecutable).startsWith("/nix/"));

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	auto origin = SandboxPathOrigin(
		SandboxPathOriginKind.agentRequirement, "renderer nix symlink", "executable");
	foreach (path; executableMountPaths(resolvedExecutable))
		sandbox.paths.requireReadVisible(path, origin);

	auto args = buildCommandPrefix(sandbox, "", "");
	assert(rendererSequenceCount(args, ["--ro-bind", "/nix", "/nix"]) == 1);

	foreach (tempFile; sandbox.tempFiles)
		if (exists(tempFile))
			remove(tempFile);
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	size_t sequenceIndex(string[] args, string[] sequence)
	{
		foreach (i; 0 .. args.length - sequence.length + 1)
			if (args[i .. i + sequence.length] == sequence)
				return i;
		assert(false, "missing renderer argument sequence");
	}

	auto root = buildPath("/tmp", "cydo-renderer-tmpfs-children");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto parent = buildPath(root, "masked");
	auto alpha = buildPath(parent, "alpha");
	auto bravo = buildPath(parent, "bravo");
	auto cider = buildPath(parent, "cider");
	foreach (path; [alpha, bravo, cider])
		mkdirRecurse(path);
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"renderer ordering", "configured mount");

	foreach (reverseRegistration; [false, true])
	{
		ResolvedSandbox sandbox;
		sandbox.isolate_filesystem = true;
		sandbox.isolate_processes = false;
		sandbox.isolate_environment = false;
		if (reverseRegistration)
		{
			sandbox.paths.set(cider, PathMode.always_rw, origin);
			sandbox.paths.set(bravo, PathMode.rw, origin);
			sandbox.paths.set(alpha, PathMode.ro, origin);
			sandbox.paths.set(parent, PathMode.tmpfs, origin);
		}
		else
		{
			sandbox.paths.set(parent, PathMode.tmpfs, origin);
			sandbox.paths.set(alpha, PathMode.ro, origin);
			sandbox.paths.set(bravo, PathMode.rw, origin);
			sandbox.paths.set(cider, PathMode.always_rw, origin);
		}

		auto args = buildCommandPrefix(sandbox, "");
		scope (exit)
			foreach (tempFile; sandbox.tempFiles)
				if (exists(tempFile))
					remove(tempFile);
		auto parentIndex = sequenceIndex(args, ["--tmpfs", parent]);
		auto alphaIndex = sequenceIndex(args, ["--ro-bind", alpha, alpha]);
		auto bravoIndex = sequenceIndex(args, ["--bind", bravo, bravo]);
		auto ciderIndex = sequenceIndex(args, ["--bind", cider, cider]);
		assert(parentIndex < alphaIndex);
		assert(parentIndex < bravoIndex);
		assert(parentIndex < ciderIndex);
		assert(alphaIndex < bravoIndex);
		assert(bravoIndex < ciderIndex);
	}
}
