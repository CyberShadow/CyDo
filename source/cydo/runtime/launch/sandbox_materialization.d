module cydo.runtime.launch.sandbox_materialization;

import std.algorithm : canFind;
import std.file : SpanMode, dirEntries, exists, isDir, isFile, mkdirRecurse, readText,
	remove, rmdirRecurse, tempDir, write;
import std.logger : warningf;
import std.path : buildPath;
import std.process : environment;
import std.random : uniform;

import core.sys.posix.unistd : getgid, getuid;

import cydo.runtime.launch.types : ResolvedSandbox;

/// Remove temp files created during sandbox setup.
void cleanup(ref ResolvedSandbox sandbox)
{
	foreach (path; sandbox.tempFiles)
	{
		try
			remove(path);
		catch (Exception e)
			warningf("sandbox: failed to remove temp file %s: %s", path, e.msg);
	}
	sandbox.tempFiles = null;
}

/// Return the CyDo runtime directory (e.g. /run/user/1000/cydo/).
/// Uses $XDG_RUNTIME_DIR if set, otherwise /tmp/cydo-<uid>/.
string runtimeDir()
{
	import std.conv : to;

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

/// Return the base directory for sandboxed tasks' shared /tmp trees.
/// Deliberately not under $XDG_RUNTIME_DIR: /run/user/<uid> is a small tmpfs
/// unsuited to bulk /tmp data.
string sharedTmpBaseDir()
{
	import core.stdc.errno : EEXIST, errno;
	import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_NOFOLLOW, O_PATH, open;
	import core.sys.posix.sys.stat : S_ISDIR, chmod, fstat, mkdir, stat_t;
	import core.sys.posix.sys.types : mode_t;
	import core.sys.posix.unistd : close;
	import std.conv : octal, to;
	import std.exception : enforce, errnoEnforce;
	import std.string : toStringz;

	auto base = buildPath(tempDir(), "cydo-shared-tmp-" ~ getuid().to!string);
	auto basez = base.toStringz;
	auto operatorGuidance = "; remove or fix it: " ~ base;
	if (mkdir(basez, cast(mode_t) octal!700) != 0 && errno != EEXIST)
		errnoEnforce(false, "Cannot create shared task /tmp base" ~ operatorGuidance);

	// O_PATH can pin a base made unreadable by a restrictive umask.
	auto fd = open(basez, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	errnoEnforce(fd >= 0, "Cannot securely open shared task /tmp base" ~ operatorGuidance);
	scope(exit) close(fd);

	stat_t fdMetadata = void;
	errnoEnforce(fstat(fd, &fdMetadata) == 0,
		"Cannot inspect opened shared task /tmp base" ~ operatorGuidance);
	enforce(S_ISDIR(fdMetadata.st_mode),
		"Shared task /tmp base is not a real directory" ~ operatorGuidance);
	enforce(fdMetadata.st_uid == getuid(),
		"Shared task /tmp base has unexpected owner" ~ operatorGuidance);

	// O_PATH descriptors cannot use fchmod. This procfs descriptor reference
	// resolves to the pinned inode, never the mutable base pathname.
	auto fdPath = buildPath("/proc/self/fd", fd.to!string);
	errnoEnforce(chmod(fdPath.toStringz, cast(mode_t) octal!700) == 0,
		"Cannot set shared task /tmp base permissions" ~ operatorGuidance);
	errnoEnforce(fstat(fd, &fdMetadata) == 0,
		"Cannot inspect opened shared task /tmp base" ~ operatorGuidance);
	enforce(fdMetadata.st_uid == getuid(),
		"Shared task /tmp base has unexpected owner" ~ operatorGuidance);
	enforce((fdMetadata.st_mode & octal!7777) == octal!700,
		"Shared task /tmp base has insecure permissions" ~ operatorGuidance);
	return base;
}

/// Return the task-owned child of a tree's shared temporary directory.
string taskTmpHostPath(string sharedTmpPath, int tid)
{
	import std.conv : to;

	return buildPath(sharedTmpPath, "cydo-task-" ~ tid.to!string);
}

/// Return the path used by the launched process for its task-owned directory.
string taskTmpAgentPath(string sharedTmpPath, int tid, bool isolateFilesystem)
{
	return taskTmpHostPath(isolateFilesystem ? "/tmp" : sharedTmpPath, tid);
}

/// Return path to a guaranteed-empty directory for ro-bind mounts.
package(cydo.runtime.launch) string emptyDirPath()
{
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
package(cydo.runtime.launch) string emptyFilePath()
{
	auto path = buildPath(runtimeDir(), "empty-file");

	// If it exists as a directory, remove it
	if (exists(path) && isDir(path))
		rmdirRecurse(path);

	if (!exists(path) || !isFile(path))
		write(path, "");

	return path;
}

/// Create a temp file containing the current user's /etc/passwd entry.
string createPasswdTempFile()
{
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

/// Create a temp file containing the current user's relevant /etc/group entries.
/// Includes the user's primary group (matched by GID) and any supplementary
/// groups where the username appears in the member list.
string createGroupTempFile()
{
	import std.conv : to;
	import std.string : lineSplitter, split;

	if (!exists("/etc/group"))
		return "";

	auto user = environment.get("USER", "");
	if (user.length == 0)
		return "";

	auto primaryGid = to!string(getgid());
	auto content = readText("/etc/group");

	string result;
	foreach (line; content.lineSplitter())
	{
		auto fields = line.split(":");
		if (fields.length < 3)
			continue;
		// Primary group match by GID (field index 2)
		if (fields[2] == primaryGid)
		{
			result ~= line ~ "\n";
			continue;
		}
		// Supplementary group: user appears in member list (field index 3)
		if (fields.length >= 4)
		{
			foreach (member; fields[3].split(","))
				if (member == user)
				{
					result ~= line ~ "\n";
					break;
				}
		}
	}

	if (result.length == 0)
		return "";

	return writeTempFile("cydo-group-", result);
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

private:

/// Write content to a temp file and return its path.
string writeTempFile(string prefix, string content)
{
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

version (unittest)
{
	// tempDir caches its result process-wide. Select /tmp before unit tests so
	// the shared base and runtimeDir()'s no-XDG fallback are sibling paths.
	private string originalTmpDir;
	private bool hadOriginalTmpDir;

	static this()
	{
		originalTmpDir = environment.get("TMPDIR");
		hadOriginalTmpDir = originalTmpDir !is null;
		environment["TMPDIR"] = "/tmp";
	}

	static ~this()
	{
		if (hadOriginalTmpDir)
			environment["TMPDIR"] = originalTmpDir;
		else
			environment.remove("TMPDIR");
	}

	private void removeSandboxMaterializationTestPath(string path)
	{
		import std.file : isSymlink;

		if (!exists(path))
			return;
		if (!isSymlink(path) && isDir(path))
			rmdirRecurse(path);
		else
			remove(path);
	}

	private struct SandboxMaterializationTestPath
	{
		string base;
		string backup;
		bool hadOriginal;

		this(string base, string suffix)
		{
			import core.sys.posix.unistd : getpid;
			import std.conv : to;
			import std.file : rename;

			this.base = base;
			backup = base ~ "." ~ suffix ~ "-" ~ getpid().to!string;
			assert(!exists(backup));
			hadOriginal = exists(base);
			if (hadOriginal)
				rename(base, backup);
		}

		void restore()
		{
			import std.file : rename;

			removeSandboxMaterializationTestPath(base);
			if (hadOriginal)
				rename(backup, base);
		}
	}
}

// Without XDG_RUNTIME_DIR, runtimeDir() retains its /tmp/cydo-<uid> fallback
// while sharedTmpBaseDir() uses the distinct /tmp/cydo-shared-tmp-<uid> base.
unittest
{
	import std.conv : octal, to;
	import std.file : getAttributes, isDir, setAttributes;

	auto oldXdgRuntimeDir = environment.get("XDG_RUNTIME_DIR");
	scope (exit)
	{
		if (oldXdgRuntimeDir is null)
			environment.remove("XDG_RUNTIME_DIR");
		else
			environment["XDG_RUNTIME_DIR"] = oldXdgRuntimeDir;
	}
	environment.remove("XDG_RUNTIME_DIR");

	auto runtimeBase = buildPath("/tmp", "cydo-" ~ getuid().to!string);
	auto sharedBase = buildPath(tempDir(), "cydo-shared-tmp-" ~ getuid().to!string);
	assert(buildPath(tempDir(), "cydo-" ~ getuid().to!string) == runtimeBase);
	assert(sharedBase != runtimeBase);
	auto runtimePath = SandboxMaterializationTestPath(
		runtimeBase, "runtime-dir-fallback-unittest");
	scope (exit) runtimePath.restore();
	auto sharedPath = SandboxMaterializationTestPath(
		sharedBase, "shared-tmp-base-dir-unittest");
	scope (exit) sharedPath.restore();

	assert(runtimeDir() == runtimeBase);
	assert(isDir(runtimeBase));
	setAttributes(runtimeBase, octal!777);
	assert((getAttributes(runtimeBase) & octal!7777) == octal!777);

	assert(sharedTmpBaseDir() == sharedBase);
	assert(isDir(sharedBase));
	assert((getAttributes(sharedBase) & octal!7777) == octal!700);
	assert((getAttributes(runtimeBase) & octal!7777) == octal!777);
}

// A restrictive process umask must not prevent a newly created shared base
// from receiving its required private permissions.
unittest
{
	import core.sys.posix.sys.stat : umask;
	import std.conv : octal, to;
	import std.file : getAttributes, isDir;

	auto base = buildPath(tempDir(), "cydo-shared-tmp-" ~ getuid().to!string);
	auto path = SandboxMaterializationTestPath(
		base, "restrictive-umask-shared-tmp-base-dir-unittest");
	scope (exit) path.restore();
	assert(!exists(base));

	auto originalUmask = umask(octal!777);
	scope (exit) umask(originalUmask);

	assert(sharedTmpBaseDir() == base);
	assert(isDir(base));
	assert((getAttributes(base) & octal!7777) == octal!700);
	assert(umask(octal!777) == octal!777);
}

// A permissive base owned by the current user is normalized to the required
// private permissions.
unittest
{
	import std.conv : octal, to;
	import std.file : getAttributes, isDir, mkdirRecurse, setAttributes;

	auto base = buildPath(tempDir(), "cydo-shared-tmp-" ~ getuid().to!string);
	auto path = SandboxMaterializationTestPath(
		base, "permissive-shared-tmp-base-dir-unittest");
	scope (exit) path.restore();

	mkdirRecurse(base);
	setAttributes(base, octal!777);
	assert((getAttributes(base) & octal!7777) == octal!777);

	assert(sharedTmpBaseDir() == base);
	assert(isDir(base));
	assert((getAttributes(base) & octal!7777) == octal!700);
}

// A symlink at the shared base must be rejected without touching its target.
unittest
{
	import core.sys.posix.unistd : getpid;
	import std.conv : octal, to;
	import std.exception : assertThrown;
	import std.file : getAttributes, isSymlink, mkdirRecurse, setAttributes, symlink;

	auto base = buildPath(tempDir(), "cydo-shared-tmp-" ~ getuid().to!string);
	auto target = base ~ ".shared-tmp-base-dir-symlink-target-" ~ getpid().to!string;
	assert(!exists(target));
	scope (exit)
		if (exists(target))
			rmdirRecurse(target);

	auto path = SandboxMaterializationTestPath(base, "symlink-shared-tmp-base-dir-unittest");
	scope (exit) path.restore();

	mkdirRecurse(target);
	setAttributes(target, octal!755);
	auto targetMode = getAttributes(target) & octal!7777;
	symlink(target, base);
	assert(isSymlink(base));

	assertThrown!Exception(sharedTmpBaseDir());
	assert(isSymlink(base));
	assert((getAttributes(target) & octal!7777) == targetMode);
}

unittest
{
	import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse, write;

	auto oldHome = environment.get("HOME", "");
	scope(exit)
		environment["HOME"] = oldHome;

	auto home = buildPath("/tmp", "cydo-sandbox-git-home");
	auto gitDir = buildPath(home, ".config", "git");
	if (exists(home))
		rmdirRecurse(home);
	scope(exit)
		if (exists(home))
			rmdirRecurse(home);

	mkdirRecurse(gitDir);
	write(buildPath(gitDir, "config"), "[core]\n\teditor = vim\n");

	environment["HOME"] = home;

	auto path = createGitConfigTempFile("CyDo Test", "test@example.com");
	scope(exit)
		if (path.length > 0 && exists(path))
			remove(path);

	auto content = readText(path);
	assert(content.canFind("[core]\n\teditor = vim\n"));
	assert(content.canFind("\tname = CyDo Test\n"));
	assert(content.canFind("\temail = test@example.com\n"));
	assert(content.canFind("\tsigningkey =\n"));
	assert(content.canFind("[commit]\n\tgpgsign = false\n"));
}
