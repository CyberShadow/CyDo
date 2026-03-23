module cydo.discover;

import std.path : baseName, buildPath, relativePath;
import std.file : exists, isDir, dirEntries, SpanMode;
import std.logger : warningf;

import cydo.config : WorkspaceConfig;

/// Handle the discover subcommand.
/// Writes a JSON array of {path, name} objects to stdout and exits.
void runDiscover(string root, string name, uint maxDepth, string[] exclude)
{
	import std.json : JSONValue;
	import std.stdio : writeln;

	auto ws = WorkspaceConfig(
		name,
		root,
		maxDepth,
		exclude,
	);

	auto projects = discoverProjects(ws);

	JSONValue[] arr;
	foreach (ref p; projects)
		arr ~= JSONValue(["path": JSONValue(p.path), "name": JSONValue(p.name)]);

	writeln(JSONValue(arr).toString());
}

struct DiscoveredProject
{
	string workspace;   // workspace name
	string path;        // absolute path to repo root
	string name;        // path relative to workspace root (e.g., "cydo", "libs/ae")
}

/// Discover git projects within a workspace.
/// If the workspace root itself is a git repo, returns a single project.
/// Otherwise, scans recursively up to max_depth for .git directories.
DiscoveredProject[] discoverProjects(WorkspaceConfig ws)
{
	import std.path : expandTilde;

	ws.root = expandTilde(ws.root);

	if (!exists(ws.root) || !isDir(ws.root))
		return null;

	// Check if the workspace root itself is a git repo
	if (exists(buildPath(ws.root, ".git")))
	{
		return [DiscoveredProject(ws.name, ws.root, baseName(ws.root))];
	}

	// Recursive scan
	DiscoveredProject[] results;
	scanDir(ws.root, ws.root, 0, ws.max_depth, ws.exclude, ws.name, results);
	return results;
}

private void scanDir(string dir, string wsRoot, uint depth, uint maxDepth,
	const(string)[] exclude, string wsName, ref DiscoveredProject[] results)
{
	if (depth >= maxDepth)
		return;

	try
	{
		foreach (entry; dirEntries(dir, SpanMode.shallow))
		{
			if (!entry.isDir)
				continue;

			auto name = baseName(entry.name);

			// Skip hidden directories
			if (name.length > 0 && name[0] == '.')
				continue;

			// Skip excluded names
			bool excluded = false;
			foreach (ex; exclude)
			{
				if (name == ex)
				{
					excluded = true;
					break;
				}
			}
			if (excluded)
				continue;

			// Check if this directory is a git repo
			if (exists(buildPath(entry.name, ".git")))
			{
				auto relPath = relativePath(entry.name, wsRoot);
				results ~= DiscoveredProject(wsName, entry.name, relPath);
				// Don't recurse into git repos
				continue;
			}

			// Recurse deeper
			scanDir(entry.name, wsRoot, depth + 1, maxDepth, exclude, wsName, results);
		}
	}
	catch (Exception e)
	{
		warningf("scanDir: error scanning %s: %s", dir, e.msg);
	}
}
