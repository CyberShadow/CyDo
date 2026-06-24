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
