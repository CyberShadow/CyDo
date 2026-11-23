module cydo.foundation.platform.path;

import std.exception : enforce;
import std.file : exists, isDir;
import std.path : absolutePath, buildNormalizedPath, expandTilde;

import ae.sys.file : realPath;

string canonicalProjectPath(string path)
{
	enforce(path.length > 0, "project path must not be empty");
	string absolute = buildNormalizedPath(absolutePath(expandTilde(path)));
	enforce(exists(absolute) && isDir(absolute), "project path must be an existing directory");
	return buildNormalizedPath(realPath(absolute));
}

string bestEffortProjectPathIdentity(string path)
{
	if (path.length == 0)
		return "";
	auto absolute = buildNormalizedPath(absolutePath(expandTilde(path)));
	if (exists(absolute) && isDir(absolute))
		return canonicalProjectPath(path);
	return absolute;
}

/// Snapshot names without asking the directory iterator for lazy metadata.
string[] directoryEntryPaths(string path)
{
	import core.stdc.errno : ENOENT, ENOTDIR;
	import std.file : dirEntries, FileException, SpanMode;

	string[] paths;
	try
	{
		foreach (entry; dirEntries(path, SpanMode.shallow))
			paths ~= entry.name;
	}
	catch (FileException e)
	{
		if (e.errno != ENOENT && e.errno != ENOTDIR)
			throw e;
	}
	return paths;
}

/// Obtain the file type of a path that may disappear between readdir and stat.
uint existingPathAttributes(string path, bool followLinks = true)
{
	import core.stdc.errno : ENOENT, ENOTDIR;
	import std.file : FileException, getAttributes, getLinkAttributes;

	try
		return followLinks ? getAttributes(path) : getLinkAttributes(path);
	catch (FileException e)
	{
		if (e.errno != ENOENT && e.errno != ENOTDIR)
			throw e;
		return 0;
	}
}

version (unittest)
{
	import std.exception : assertThrown;
	import std.file : mkdirRecurse, remove, rmdirRecurse, symlink, write;
	import std.path : buildPath;

	unittest
	{
		auto root = buildPath(realPath("/tmp"), "cydo-test-project-path");
		if (exists(root))
			rmdirRecurse(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto project = buildPath(root, "project");
		auto projectLink = buildPath(root, "project-link");
		auto missing = buildPath(root, "missing", "project");
		auto missingWithComponents = buildPath(root, "missing", "..", "missing", "project");
		auto regularFile = buildPath(root, "file");
		mkdirRecurse(project);
		symlink(project, projectLink);
		write(regularFile, "file");

		auto canonical = canonicalProjectPath(project);
		assert(canonical == buildNormalizedPath(realPath(project)));
		assert(canonicalProjectPath(projectLink) == canonical);
		assert(canonicalProjectPath(project ~ "/") == canonical);
		assert(canonicalProjectPath(".") == buildNormalizedPath(realPath(absolutePath("."))));
		assertThrown!Exception(canonicalProjectPath(missingWithComponents));
		assertThrown!Exception(canonicalProjectPath(regularFile));
		assert(bestEffortProjectPathIdentity(missingWithComponents) ==
			buildNormalizedPath(absolutePath(missing)));
		assert(bestEffortProjectPathIdentity(regularFile) ==
			buildNormalizedPath(absolutePath(regularFile)));
	}
}
