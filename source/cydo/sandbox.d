module cydo.sandbox;

import std.file : exists, isSymlink, readLink, readText;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.stdio : stderr;

import cydo.agent.agent : Agent;
import cydo.config : GitIdentityConfig, PathMode, SandboxConfig;

/// Resolved sandbox configuration after merging all layers.
struct ResolvedSandbox
{
	PathMode[string] paths;
	string[string] env;
	string gitName;
	string gitEmail;
	string[] tempFiles; // temp files to clean up on exit
}

/// Merge three layers of sandbox config: agent defaults → global config → per-workspace config.
/// When readOnly is true, all config/workspace/project paths are downgraded
/// to ro before the agent layer runs — so agent-declared paths (e.g. ~/.claude)
/// stay rw while the project tree becomes read-only.
ResolvedSandbox resolveSandbox(SandboxConfig global, SandboxConfig workspace, Agent agent,
	string projectDir, bool readOnly = false)
{
	ResolvedSandbox result;

	// Layer 1: global config paths
	mergePaths(result.paths, global.paths);

	// Layer 2: per-workspace config paths
	mergePaths(result.paths, workspace.paths);

	// Add project directory
	if (projectDir.length > 0)
		result.paths[expandTilde(projectDir)] = PathMode.rw;

	// Read-only mode: downgrade all rw paths to ro before agent layer
	if (readOnly)
		foreach (ref mode; result.paths)
			if (mode != PathMode.always_rw)
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
			stderr.writefln("sandbox: skipping non-existent path: %s", resolved);
	}
	result.paths = expanded;

	// Merge env: global, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, workspace.env);

	// Expand ~ in env values (replace all occurrences, not just leading ~)
	auto home = environment.get("HOME", "");
	string[string] expandedEnv;
	foreach (k, v; result.env)
		expandedEnv[k] = expandAllTildes(v, home);
	result.env = expandedEnv;

	// Git identity: agent defaults, overridden by config
	result.gitName = agent.gitName;
	result.gitEmail = agent.gitEmail;
	if (global.git.name.length > 0)
		result.gitName = global.git.name;
	if (global.git.email.length > 0)
		result.gitEmail = global.git.email;
	if (workspace.git.name.length > 0)
		result.gitName = workspace.git.name;
	if (workspace.git.email.length > 0)
		result.gitEmail = workspace.git.email;

	return result;
}

/// Build the full bwrap command-line arguments.
/// Returns the bwrap prefix including all flags — append the inner command after this.
string[] buildBwrapArgs(ref ResolvedSandbox sandbox, string workDir)
{
	string[] args;

	args ~= findBwrap();

	// Namespace isolation (hardcoded)
	args ~= [
		"--unshare-ipc",
		"--unshare-pid",
		"--as-pid-1",
		"--unshare-uts",
		"--unshare-cgroup",
		"--share-net",
		"--die-with-parent",
	];

	// Pseudo-filesystems (hardcoded)
	args ~= ["--dev", "/dev"];
	args ~= ["--proc", "/proc"];
	args ~= ["--tmpfs", "/tmp"];

	auto currentSystem = resolveNixCurrentSystem();

	if (currentSystem.length > 0)
	{
		// NixOS: tmpfs /run with just the current-system symlink
		args ~= ["--tmpfs", "/run"];
		args ~= ["--symlink", currentSystem, "/run/current-system"];
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

	// Environment
	args ~= "--clearenv";
	args ~= ["--setenv", "HOME", environment.get("HOME", "/tmp")];

	auto nixPath = environment.get("NIX_PATH", "");
	if (nixPath.length > 0)
		args ~= ["--setenv", "NIX_PATH", nixPath];

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
			stderr.writefln("sandbox: failed to remove temp file %s: %s", path, e.msg);
	}
	sandbox.tempFiles = null;
}

private:

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
		catch (Exception)
			return "";
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
