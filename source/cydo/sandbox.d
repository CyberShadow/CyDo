module cydo.sandbox;

import std.file : exists, isSymlink, readLink, readText;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.logger : tracef, warningf;

import configy.attributes : SetInfo;

import cydo.agent.agent : Agent;
import cydo.config : GitIdentityConfig, PathMode, SandboxConfig;

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

/// Resolved sandbox configuration after merging all layers.
struct ResolvedSandbox
{
	bool isolate_filesystem;
	bool isolate_processes;
	bool isolate_environment;
	PathMode[string] paths;
	string[string] env;
	string gitName;
	string gitEmail;
	string[] tempFiles; // temp files to clean up on exit

	@property bool useBwrap() const { return isolate_filesystem || isolate_processes; }
}

/// Merge four layers of sandbox config: agent defaults → global config → per-agent config → per-workspace config.
/// When readOnly is true, all config/workspace/project paths are downgraded
/// to ro before the agent layer runs — so agent-declared paths (e.g. ~/.claude)
/// stay rw while the project tree becomes read-only.
ResolvedSandbox resolveSandbox(SandboxConfig global, SandboxConfig agentTypeConfig,
	SandboxConfig workspace, Agent agent, string projectDir, bool readOnly = false)
{
	ResolvedSandbox result;

	// Layer 1: global config paths
	mergePaths(result.paths, global.paths);

	// Layer 1.5: per-agent config paths (overrides global)
	mergePaths(result.paths, agentTypeConfig.paths);

	// Layer 2: per-workspace config paths (overrides per-agent)
	mergePaths(result.paths, workspace.paths);

	// Add project directory
	if (projectDir.length > 0)
		result.paths[expandTilde(projectDir)] = PathMode.rw;

	// Read-only mode: downgrade all rw paths to ro before agent layer
	if (readOnly)
		foreach (ref mode; result.paths)
			if (mode == PathMode.rw)
				mode = PathMode.ro;

	// Layer 3: agent-declared paths/env (last — always rw for agent state)
	agent.configureSandbox(result.paths, result.env);

	// Expand ~ in all path keys and filter non-existent
	PathMode[string] expanded;
	foreach (path, mode; result.paths)
	{
		auto resolved = expandTilde(path);
		if (exists(resolved))
			expanded[resolved] = mode;
		else
			warningf("sandbox: skipping non-existent path: %s", resolved);
	}
	result.paths = expanded;

	// Merge env: global, then per-agent, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, agentTypeConfig.env);
	mergeEnv(result.env, workspace.env);

	// Expand ~ in env values (replace all occurrences, not just leading ~)
	auto home = environment.get("HOME", "");
	string[string] expandedEnv;
	foreach (k, v; result.env)
		expandedEnv[k] = expandAllTildes(v, home);
	result.env = expandedEnv;

	// Git identity: agent defaults, overridden by global, per-agent, workspace
	result.gitName = agent.gitName;
	result.gitEmail = agent.gitEmail;
	if (global.git.name.length > 0)
		result.gitName = global.git.name;
	if (global.git.email.length > 0)
		result.gitEmail = global.git.email;
	if (agentTypeConfig.git.name.length > 0)
		result.gitName = agentTypeConfig.git.name;
	if (agentTypeConfig.git.email.length > 0)
		result.gitEmail = agentTypeConfig.git.email;
	if (workspace.git.name.length > 0)
		result.gitName = workspace.git.name;
	if (workspace.git.email.length > 0)
		result.gitEmail = workspace.git.email;

	// Resolve isolation flags (last-writer-wins across layers)
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, agentTypeConfig.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, agentTypeConfig.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, agentTypeConfig.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);

	return result;
}

/// Resolve sandbox for project discovery (no agent layer).
/// Merges global + workspace sandbox layers; all paths are downgraded to ro.
ResolvedSandbox resolveSandboxForDiscovery(SandboxConfig global, SandboxConfig workspace,
	string wsRoot, string cydoBinDir)
{
	ResolvedSandbox result;

	// Layer 1: global config paths
	mergePaths(result.paths, global.paths);

	// Layer 2: workspace config paths (overrides global)
	mergePaths(result.paths, workspace.paths);

	// Add workspace root as ro
	if (wsRoot.length > 0)
		result.paths[expandTilde(wsRoot)] = PathMode.ro;

	// Add cydo binary directory as ro
	if (cydoBinDir.length > 0)
		result.paths[cydoBinDir] = PathMode.ro;

	// Downgrade all rw paths to ro (discovery is read-only)
	foreach (ref mode; result.paths)
		if (mode == PathMode.rw || mode == PathMode.always_rw)
			mode = PathMode.ro;

	// Expand ~ in all path keys and filter non-existent
	PathMode[string] expanded;
	foreach (path, mode; result.paths)
	{
		auto resolved = expandTilde(path);
		if (exists(resolved))
			expanded[resolved] = mode;
		else
			warningf("sandbox: skipping non-existent path: %s", resolved);
	}
	result.paths = expanded;

	// Merge env: global, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, workspace.env);

	// Expand ~ in env values
	auto home = environment.get("HOME", "");
	string[string] expandedEnv;
	foreach (k, v; result.env)
		expandedEnv[k] = expandAllTildes(v, home);
	result.env = expandedEnv;

	// Resolve isolation flags (last-writer-wins across layers)
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);

	return result;
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
		// children.  This ensures a child rw bind overrides a parent ro bind.
		import std.algorithm : sort;
		import std.array : array;
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

/// Remove temp files created during sandbox setup.
void cleanup(ref ResolvedSandbox sandbox)
{
	import std.file : remove;

	foreach (path; sandbox.tempFiles)
	{
		try
			remove(path);
		catch (Exception e)
			warningf("sandbox: failed to remove temp file %s: %s", path, e.msg);
	}
	sandbox.tempFiles = null;
}

private:

/// Override dest with source value if source was explicitly set in config.
void overrideBool(ref bool dest, SetInfo!bool source)
{
	if (source.set)
		dest = source.value;
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

/// Return the CyDo runtime directory (e.g. /run/user/1000/cydo/).
/// Uses $XDG_RUNTIME_DIR if set, otherwise /tmp/cydo-<uid>/.
string runtimeDir()
{
	import std.conv : to;
	import std.file : mkdirRecurse, exists;
	import core.sys.posix.unistd : getuid;

	auto xdg = environment.get("XDG_RUNTIME_DIR", "");
	string base;
	if (xdg.length > 0)
		base = buildPath(xdg, "cydo");
	else
		base = buildPath("/tmp", "cydo-" ~ getuid().to!string);

	if (!exists(base))
		mkdirRecurse(base);
	return base;
}

/// Return path to a guaranteed-empty directory for ro-bind mounts.
string emptyDirPath()
{
	import std.file : exists, isDir, isFile, mkdirRecurse, dirEntries,
		SpanMode, remove, rmdirRecurse;

	auto path = buildPath(runtimeDir(), "empty-dir");

	// If it exists as a file, remove it
	if (exists(path) && !isDir(path))
		remove(path);

	if (!exists(path))
		mkdirRecurse(path);

	// Ensure empty (in case leftover from previous run)
	foreach (entry; dirEntries(path, SpanMode.shallow))
	{
		if (isDir(entry.name))
			rmdirRecurse(entry.name);
		else
			remove(entry.name);
	}
	return path;
}

/// Return path to a guaranteed-empty file for ro-bind mounts.
string emptyFilePath()
{
	import std.file : exists, isDir, isFile, write, rmdirRecurse;

	auto path = buildPath(runtimeDir(), "empty-file");

	// If it exists as a directory, remove it
	if (exists(path) && isDir(path))
		rmdirRecurse(path);

	if (!exists(path) || !isFile(path))
		write(path, "");

	return path;
}

/// Find the bwrap binary.
string findBwrap()
{
	foreach (candidate; ["/run/wrappers/bin/bwrap", "/usr/bin/bwrap"])
		if (exists(candidate))
			return candidate;

	// Search PATH
	import std.algorithm : splitter;
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
		{ tracef("nixCurrentSystem: readLink failed: %s", e.msg); return ""; }
	}
	return "";
}

/// Replace all occurrences of ~ with the home directory.
/// Handles ~/path at the start, and :~/path in PATH-like variables.
string expandAllTildes(string value, string home)
{
	import std.array : replace;
	if (home.length == 0)
		return value;
	return value.replace("~/", home ~ "/");
}

/// Merge source paths into destination (source wins on conflicts).
void mergePaths(ref PathMode[string] dest, PathMode[string] source)
{
	if (source is null)
		return;
	foreach (path, mode; source)
		dest[path] = mode;
}

/// Merge source env into destination (source wins on conflicts).
void mergeEnv(ref string[string] dest, string[string] source)
{
	if (source is null)
		return;
	foreach (k, v; source)
		dest[k] = v;
}

/// Create a temp file containing the current user's /etc/passwd entry.
string createPasswdTempFile()
{
	import std.algorithm : canFind;
	import std.string : lineSplitter;

	if (!exists("/etc/passwd"))
		return "";

	auto user = environment.get("USER", "");
	if (user.length == 0)
		return "";

	auto content = readText("/etc/passwd");
	auto prefix = user ~ ":";

	foreach (line; content.lineSplitter())
	{
		if (line.length > prefix.length && line[0 .. prefix.length] == prefix)
			return writeTempFile("cydo-passwd-", line ~ "\n");
	}

	return "";
}

/// Create a temp file with the host git config + identity overrides.
string createGitConfigTempFile(string gitName, string gitEmail)
{
	if (gitName.length == 0 && gitEmail.length == 0)
		return "";

	auto home = environment.get("HOME", "");
	auto gitConfigPath = buildPath(home, ".config/git/config");

	string content;
	if (exists(gitConfigPath))
		content = readText(gitConfigPath);

	content ~= "\n[user]\n";
	if (gitName.length > 0)
		content ~= "\tname = " ~ gitName ~ "\n";
	if (gitEmail.length > 0)
		content ~= "\temail = " ~ gitEmail ~ "\n";
	content ~= "\tsigningkey =\n";
	content ~= "[commit]\n\tgpgsign = false\n";

	return writeTempFile("cydo-gitconfig-", content);
}

/// Write content to a temp file and return its path.
string writeTempFile(string prefix, string content)
{
	import std.file : tempDir, write;
	import std.path : buildPath;
	import std.random : uniform;
	import std.conv : to;

	// Generate a unique temp file path
	auto dir = tempDir();
	string path;
	foreach (_; 0 .. 100)
	{
		path = buildPath(dir, prefix ~ to!string(uniform(0, int.max)));
		if (!exists(path))
			break;
	}

	write(path, content);
	return path;
}
