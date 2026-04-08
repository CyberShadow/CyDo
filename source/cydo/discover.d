module cydo.discover;

import std.path : baseName, buildPath, relativePath;
import std.file : exists, isDir, dirEntries, SpanMode;
import std.logger : warningf;

// ---------------------------------------------------------------------------
// ProjectDiscoveryConfig — holds the djinja expression strings for discovery
// ---------------------------------------------------------------------------

struct ProjectDiscoveryConfig
{
	import configy.attributes : Optional;

	@Optional string is_project;
	@Optional string recurse_when;
}

// ---------------------------------------------------------------------------
// Discovery constants and types
// ---------------------------------------------------------------------------

enum HARD_DEPTH_CAP = 20;

struct DiscoveredProject
{
	string workspace;   // workspace name
	string path;        // absolute path to repo root
	string name;        // path relative to workspace root (e.g., "cydo", "libs/ae")
}

// ---------------------------------------------------------------------------
// Djinja expression evaluation helpers
// ---------------------------------------------------------------------------

// Thread-local directory path used by has_* predicates during evaluation
private string _evalDirPath;

private bool has_entry(string name)
{
	return exists(buildPath(_evalDirPath, name));
}

private bool has_file(string name)
{
	auto p = buildPath(_evalDirPath, name);
	return exists(p) && !isDir(p);
}

private bool has_dir(string name)
{
	auto p = buildPath(_evalDirPath, name);
	return exists(p) && isDir(p);
}

// Context struct for djinja evaluation
private struct DiscoverCtx
{
	long depth;
	string relative_path;
	string name;
	bool is_project;
}

/// Evaluate a djinja expression string as a boolean.
private bool evalExprBool(string expr, string dirPath,
	uint depth, string relativePath, string dirName,
	bool isProject = false)
{
	import djinja.djinja : JinjaConfig, loadData;
	import djinja.render : Render, registerFunction;
	import uninode.serialization : serialize = serializeToUniNode;

	_evalDirPath = dirPath;

	enum JinjaConfig conf = { cmntOpInline: "$$", stmtOpInline: "$$$" };
	auto renderer = new Render(loadData!conf(expr));
	registerFunction!has_entry(renderer);
	registerFunction!has_file(renderer);
	registerFunction!has_dir(renderer);

	auto data = serialize(DiscoverCtx(cast(long) depth, relativePath, dirName, isProject));
	string result = renderer.render(data);

	import std.string : strip;
	return result.strip() == "true";
}

// ---------------------------------------------------------------------------
// runDiscover — entry point for the CLI subcommand
// ---------------------------------------------------------------------------

/// Handle the discover subcommand.
/// Writes a JSON array of {path, name} objects to stdout and exits.
void runDiscover(string root, string name,
	string isProjectExpr, string recurseWhenExpr, string[] exclude)
{
	import std.json : JSONValue;
	import std.stdio : writeln;

	ProjectDiscoveryConfig pdConfig;
	pdConfig.is_project = isProjectExpr;
	pdConfig.recurse_when = recurseWhenExpr;

	auto projects = discoverProjects(root, name, exclude, pdConfig);

	JSONValue[] arr;
	foreach (ref p; projects)
		arr ~= JSONValue(["path": JSONValue(p.path), "name": JSONValue(p.name)]);

	writeln(JSONValue(arr).toString());
}

// ---------------------------------------------------------------------------
// discoverProjects — main discovery entry point
// ---------------------------------------------------------------------------

/// Discover projects within a workspace using configurable djinja expressions.
DiscoveredProject[] discoverProjects(
	string root, string name, string[] exclude, ProjectDiscoveryConfig pdConfig)
{
	import std.path : expandTilde;

	root = expandTilde(root);

	if (!exists(root) || !isDir(root))
		return null;

	string isProjectExpr = pdConfig.is_project.length > 0
		? pdConfig.is_project
		: "{{ has_entry('.git') }}";

	string recurseWhenExpr = pdConfig.recurse_when.length > 0
		? pdConfig.recurse_when
		: "{{ not is_project and depth < 3 }}";

	DiscoveredProject[] results;

	bool rootIsProject = evalExprBool(isProjectExpr, root, 0, ".", baseName(root));
	if (rootIsProject)
		results ~= DiscoveredProject(name, root, baseName(root));

	if (evalExprBool(recurseWhenExpr, root, 0, ".", baseName(root), rootIsProject))
		scanDir(root, root, 1, exclude, name, isProjectExpr, recurseWhenExpr, results);

	return results;
}

// ---------------------------------------------------------------------------
// scanDir — recursive directory scanner
// ---------------------------------------------------------------------------

private void scanDir(string dir, string wsRoot, uint depth,
	const(string)[] exclude, string wsName,
	string isProjectExpr, string recurseWhenExpr,
	ref DiscoveredProject[] results)
{
	if (depth >= HARD_DEPTH_CAP)
		return;

	try
	{
		foreach (entry; dirEntries(dir, SpanMode.shallow))
		{
			if (!entry.isDir)
				continue;

			auto dirName = baseName(entry.name);

			// Skip hidden directories
			if (dirName.length > 0 && dirName[0] == '.')
				continue;

			// Skip excluded names
			bool excluded = false;
			foreach (ex; exclude)
			{
				if (dirName == ex)
				{
					excluded = true;
					break;
				}
			}
			if (excluded)
				continue;

			auto relPath = relativePath(entry.name, wsRoot);

			bool isProj = evalExprBool(isProjectExpr, entry.name, depth, relPath, dirName);

			if (isProj)
				results ~= DiscoveredProject(wsName, entry.name, relPath);

			if (evalExprBool(recurseWhenExpr, entry.name, depth, relPath, dirName, isProj))
				scanDir(entry.name, wsRoot, depth + 1, exclude, wsName,
					isProjectExpr, recurseWhenExpr, results);
		}
	}
	catch (Exception e)
	{
		warningf("scanDir: error scanning %s: %s", dir, e.msg);
	}
}
