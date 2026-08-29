module cydo.runtime.config;

import configy.attributes : ConfigParser, Key, Optional, SetInfo;
import configy.read : parseConfigFileSimple;

import dyaml.node : NodeID;

import std.typecons : Nullable;

enum PathMode { ro, rw, always_rw, tmpfs, empty_dir, empty_file }

struct GitIdentityConfig
{
	string name;
	string email;
}

struct SandboxConfig
{
	@Optional SetInfo!bool isolate_filesystem;
	@Optional SetInfo!bool isolate_processes;
	@Optional SetInfo!bool isolate_environment;
	@Optional PathMode[string] paths;
	@Optional string[string] env;
	@Optional GitIdentityConfig git;
}

enum AgentDriver { claude, codex, copilot }

/// Whether a driver has any mechanism for the `effort` launch parameter.
/// The *values* are not validated — they pass through to the CLI, which owns
/// the value space.
bool driverSupportsEffort(AgentDriver driver)
{
	final switch (driver)
	{
		case AgentDriver.claude:  return true;   // `--effort <value>`
		case AgentDriver.codex:   return true;   // `model_reasoning_effort` config key
		case AgentDriver.copilot: return false;  // no reasoning-effort knob
	}
}

/// The driver an agent entry resolves to: its explicit `driver:` field, or the
/// map key when that names a driver. Null when neither applies — `resolveConfig`
/// turns that into the "driver field is required" error.
Nullable!AgentDriver effectiveDriver(string name, const ref AgentConfig ac)
{
	import std.conv : to;
	if (ac.driver.set)
		return Nullable!AgentDriver(ac.driver.value);
	try
		return Nullable!AgentDriver(to!AgentDriver(name));
	catch (Exception)
		return Nullable!AgentDriver.init;
}

/// Fields of a `model_aliases` entry's mapping form.
struct ModelSpecFields
{
	@Optional string model;   /// Driver-specific model name; empty = the driver's class default
	@Optional string effort;  /// Reasoning/thinking effort; empty = the driver's default
}

/// A `model_aliases` target: either a bare model name or a mapping.
struct ModelSpec
{
	ModelSpecFields fields;
	alias fields this;

	static ModelSpec fromYAML(scope ConfigParser!ModelSpec parser)
	{
		if (parser.node.nodeID == NodeID.mapping)
			return ModelSpec(parser.parseAs!ModelSpecFields);
		if (parser.node.nodeID != NodeID.scalar)
			throw new Exception(
				"expected a model name or a mapping with `model:`/`effort:`");
		return ModelSpec(ModelSpecFields(parser.node.as!string));
	}
}

struct AgentConfig
{
	@Optional SetInfo!AgentDriver driver;
	@Optional SandboxConfig sandbox;
	@Optional ModelSpec[string] model_aliases;
	@Optional string display_name;
}

struct ProjectDiscoveryConfig
{
	@Optional string is_project;
	@Optional string recurse_when;
}

struct WorkspaceConfig
{
	string name;
	string root; /// Normalized to an absolute path at config load time.
	@Optional string[] exclude;
	@Optional SandboxConfig sandbox;
	@Optional string default_agent;
	@Optional string default_task_type;
	@Optional string permission_policy; /// Permission policy: "allow", "deny", "ask", or Djinja expression
	@Optional ProjectDiscoveryConfig project_discovery;
}

struct CydoConfig
{
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
	@Optional string task_dir; /// Global per-task directory template (Djinja)
	@Optional string default_agent;
	@Optional string default_task_type;
	@Optional AgentConfig[string] agents;
	/// Generate next-message suggestions (a small-model one-shot at each turn
	/// end and on opening a live task). Set false to stop the backend from
	/// creating them at all; title generation is separate and unaffected.
	@Optional SetInfo!bool suggestions;
	@Optional bool dev_mode;
	@Optional string log_level = "info";
	@Optional string system_keyword = "SYSTEM";

	/// Called by configy during parsing (configy/read.d:650), so a semantic
	/// error surfaces on the same path as a YAML syntax error.
	void validate() const
	{
		import std.format : format;
		foreach (name, ref ac; agents)
		{
			auto driver = effectiveDriver(name, ac);
			// An unresolvable driver is resolveConfig's error to report.
			if (driver.isNull || driverSupportsEffort(driver.get))
				continue;
			foreach (modelClass, ref spec; ac.model_aliases)
				if (spec.effort.length > 0)
					throw new Exception(format(
						"agents['%s'].model_aliases['%s']: the %s driver does not support `effort`",
						name, modelClass, driver.get));
		}
	}
}

string configPath()
{
	import std.path : buildPath, expandTilde;
	return buildPath(expandTilde("~/.config/cydo"), "config.yaml");
}

CydoConfig loadConfig()
{
	auto result = parseConfigFileSimple!CydoConfig(configPath);
	CydoConfig config = result.isNull() ? CydoConfig.init : result.get();
	applyPostLoadFixups(config);
	return config;
}

/// Re-parse config file. Returns null on parse error (caller keeps old config).
Nullable!CydoConfig reloadConfig()
{
	auto result = parseConfigFileSimple!CydoConfig(configPath);
	if (!result.isNull())
	{
		auto inner = result.get();
		applyPostLoadFixups(inner);
		result = Nullable!CydoConfig(inner);
	}
	return result;
}

/// Apply all post-parse fixups to a freshly loaded config. Single source of
/// truth so loadConfig and reloadConfig stay in sync.
private void applyPostLoadFixups(ref CydoConfig config)
{
	ensureDefaultWorkspace(config);
	normalizeWorkspacePaths(config);
}

private void ensureDefaultWorkspace(ref CydoConfig config)
{
	if (config.workspaces.length == 0)
		config.workspaces = [WorkspaceConfig("local", "~")];
}

private void normalizeWorkspacePaths(ref CydoConfig config)
{
	import cydo.foundation.platform.path : bestEffortProjectPathIdentity;
	import std.exception : enforce;
	import std.file : exists, isDir;
	foreach (ref ws; config.workspaces)
	{
		auto root = bestEffortProjectPathIdentity(ws.root);
		enforce(!exists(root) || isDir(root),
			"workspace root must be a directory");
		ws.root = root;
	}
}

version (unittest)
{
	import ae.sys.file : realPath;
	import configy.read : parseConfigString;
	import std.algorithm : canFind;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
	import std.path : buildPath, buildNormalizedPath;

	unittest
	{
		auto root = buildPath(realPath("/tmp"), "cydo-test-workspace-config-path");
		if (exists(root))
			rmdirRecurse(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto workspace = buildPath(root, "workspace");
		auto workspaceLink = buildPath(root, "workspace-link");
		auto missing = buildPath(root, "missing", "workspace");
		auto regularFile = buildPath(root, "file");
		mkdirRecurse(workspace);
		symlink(workspace, workspaceLink);
		write(regularFile, "file");

		CydoConfig loaded;
		loaded.workspaces = [WorkspaceConfig("real", workspace),
			WorkspaceConfig("link", workspaceLink)];
		applyPostLoadFixups(loaded);
		assert(loaded.workspaces[0].root == buildNormalizedPath(realPath(workspace)));
		assert(loaded.workspaces[1].root == loaded.workspaces[0].root);

		CydoConfig reloaded;
		reloaded.workspaces = [WorkspaceConfig("link", workspaceLink)];
		applyPostLoadFixups(reloaded);
		assert(reloaded.workspaces[0].root == loaded.workspaces[0].root);

		CydoConfig legacy;
		legacy.workspaces = [WorkspaceConfig("missing", missing)];
		applyPostLoadFixups(legacy);
		assert(legacy.workspaces[0].root == buildNormalizedPath(missing));

		CydoConfig invalid;
		invalid.workspaces = [WorkspaceConfig("file", regularFile)];
		assertThrown!Exception(applyPostLoadFixups(invalid));
	}

	private enum workspacesYAML = "workspaces:\n  local:\n    root: /tmp\n";

	// 1. A scalar entry parses to model == the scalar, effort == "".
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      small: haiku\n";
		auto config = parseConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["small"];
		assert(spec.model == "haiku");
		assert(spec.effort == "");
	}

	// 2. A mapping entry with both keys parses both.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        model: opus\n        effort: high\n";
		auto config = parseConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "opus");
		assert(spec.effort == "high");
	}

	// 3. A mapping entry with only effort: keeps model empty ("keep the class default").
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		auto config = parseConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "");
		assert(spec.effort == "high");
	}

	// 4. A mapping entry with only model: leaves effort empty.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        model: opus\n";
		auto config = parseConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "opus");
		assert(spec.effort == "");
	}

	// 5. Scalar and mapping entries coexist in the same model_aliases map.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      small: haiku\n      large:\n        model: opus\n        effort: high\n";
		auto config = parseConfigString!CydoConfig(yaml, "/dev/null");
		auto aliases = config.agents["my-claude"].model_aliases;
		assert(aliases["small"].model == "haiku");
		assert(aliases["large"].model == "opus");
		assert(aliases["large"].effort == "high");
	}

	// 6. A sequence value throws, mentioning the config path and the expected shape.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large: [a, b]\n";
		try
		{
			parseConfigString!CydoConfig(yaml, "/dev/null");
			assert(false, "expected a ConfigException");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("agents[my-claude].model_aliases[large]"));
			assert(e.toString().canFind("expected a model name or a mapping"));
		}
	}

	// 7. An unknown key inside the mapping form throws (configy's strict mode).
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        modle: opus\n";
		try
		{
			parseConfigString!CydoConfig(yaml, "/dev/null");
			assert(false, "expected a ConfigException");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("agents[my-claude].model_aliases[large]"));
			assert(e.toString().canFind("modle"));
		}
	}

	// 8. effort on an agent with an explicit `driver: copilot` throws.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-copilot:\n    driver: copilot\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		try
		{
			parseConfigString!CydoConfig(yaml, "/dev/null");
			assert(false, "expected a ConfigException");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("my-copilot"));
			assert(e.toString().canFind("large"));
			assert(e.toString().canFind("copilot"));
			assert(e.toString().canFind("does not support"));
		}
	}

	// 9. effort on a key-inferred copilot agent throws the same message.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  copilot:\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		try
		{
			parseConfigString!CydoConfig(yaml, "/dev/null");
			assert(false, "expected a ConfigException");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("copilot"));
			assert(e.toString().canFind("large"));
			assert(e.toString().canFind("does not support"));
		}
	}

	// 10. effort on a claude agent and on a codex agent parses without throwing.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        effort: high\n"
			~ "  my-codex:\n    driver: codex\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		parseConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 11. An arbitrary, unrecognised effort value on claude parses without throwing.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        effort: some-future-level\n";
		parseConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 12. A model-only alias on a copilot agent parses without throwing.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-copilot:\n    driver: copilot\n"
			~ "    model_aliases:\n      small: gpt-4.1\n      large:\n        model: gpt-4.1\n";
		parseConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 13. An agent whose key is not a driver name and has no driver: field, with
	// effort set, parses without throwing from validate() — resolveConfig
	// reports the "driver field is required" error, not validate().
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  custom:\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		parseConfigString!CydoConfig(yaml, "/dev/null");
	}
}
