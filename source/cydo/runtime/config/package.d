module cydo.runtime.config;

import configy.attributes : ConfigParser, Key, Optional, SetInfo;
import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException, loadConfigYaml, parseConfigNode, readConfigText;

import dyaml.node : NodeID;

import core.time : Duration;
import std.typecons : Nullable;

public import cydo.runtime.config.memory : MemoryLimitsConfig, MemorySize, memoryLimitingInUse;
public import cydo.runtime.config.paths : configPath;

enum PathMode { ro, rw, always_rw, tmpfs, empty_dir, empty_file }

struct GitIdentityConfig
{
	string name;
	string email;
}

/// Whether a task is offered the host command tool, and whether each call
/// needs the user's approval.
///
/// The sandbox and this verdict guard against accidental host damage. They
/// do not form a trust boundary against a malicious agent, so `yes` (run
/// without asking) is a legitimate operator choice: it suits trusted local
/// setups and task types that routinely need host tooling, where per-call
/// prompts would only cause approval fatigue.
enum UnsandboxedCommandExecution
{
	no,  /// the tool is not offered, and calls are rejected
	yes, /// the tool is offered, and calls run without approval
	ask, /// the tool is offered, and each call needs the user's approval
}

UnsandboxedCommandExecution parseUnsandboxedCommandExecution(string value, string source)
{
	import std.format : format;

	switch (value)
	{
		case "no":  return UnsandboxedCommandExecution.no;
		case "yes": return UnsandboxedCommandExecution.yes;
		case "ask": return UnsandboxedCommandExecution.ask;
		default:
			throw new Exception(format(
				"%s: unsandboxed_command_execution received %s; expected no, yes or ask",
				source, value));
	}
}

struct SandboxConfig
{
	@Optional MemoryLimitsConfig memory;
	@Optional SetInfo!bool isolate_filesystem;
	@Optional SetInfo!bool isolate_processes;
	@Optional SetInfo!bool isolate_environment;
	@Optional PathMode[string] paths;
	@Optional string[string] env;
	@Optional GitIdentityConfig git;
	/// "no", "yes", "ask", or a Djinja expression using task_type, interactive,
	/// and default (the task type's rendered verdict).
	@Optional SetInfo!string unsandboxed_command_execution;
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

/// Claude consults policy and auto_mode. CyDo also uses prompt_timeout
/// for its own prompts on every driver. Layered like `sandbox`: global,
/// then agent, then workspace.
struct PermissionsConfig
{
	/// "allow", "deny", "ask", "auto", or a Djinja expression rendering one
	/// of them (variables: tool_name, input, auto_mode, and dangerous: the
	/// agent's own safety checks flag the call). Unset = `{{ "ask" if
	/// dangerous else ("auto" if auto_mode else "allow") }}`.
	@Optional SetInfo!string policy;
	/// Run Claude Code in auto mode: its classifier judges the tool calls
	/// the policy answers "auto" for.
	@Optional SetInfo!bool auto_mode;
	/// Seconds a permission prompt waits for an answer before it denies the
	/// call; 0 = indefinitely. Unset = 120, matching Claude Code's own
	/// prompts.
	@Optional SetInfo!uint prompt_timeout;
}

struct UsagePollingPeriod
{
	@Optional SetInfo!uint turns;
	@Optional SetInfo!Duration timespan;
}

struct AgentConfig
{
	@Optional SetInfo!AgentDriver driver;
	@Optional SandboxConfig sandbox;
	@Optional PermissionsConfig permissions;
	@Optional ModelSpec[string] model_aliases;
	@Optional string display_name;
	@Optional SetInfo!UsagePollingPeriod usage_polling_period;
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
	@Optional PermissionsConfig permissions;
	@Optional ProjectDiscoveryConfig project_discovery;
	/// Files of a project's main checkout to link into each task worktree
	/// of it, as paths relative to the repository root: the untracked files
	/// (personal instruction files, local settings) a worktree does not
	/// have. Each entry is a Djinja template (variables: workspace,
	/// workspace_root, project_path, repo_path); one that renders empty is
	/// skipped, as is a file the project does not have.
	@Optional string[] worktree_links;
}

enum UsageColoring { pace, percent }

struct UsageUiConfig
{
	@Optional UsageColoring coloring = UsageColoring.pace;
	@Optional bool remaining;
}

enum SidebarOrder { oldest_first, newest_first }

enum SidebarSort { creation, activity }

struct SidebarUiConfig
{
	@Optional SidebarOrder order = SidebarOrder.oldest_first;
	@Optional SidebarSort sort = SidebarSort.creation;
}

struct UiConfig
{
	@Optional UsageUiConfig usage;
	@Optional SidebarUiConfig sidebar;
}

struct CydoConfig
{
	@Optional MemoryLimitsConfig total_agent_memory;
	@Key("name") WorkspaceConfig[] workspaces;
	@Optional SandboxConfig sandbox;
	@Optional PermissionsConfig permissions;
	@Optional string task_dir; /// Global per-task directory template (Djinja)
	@Optional string default_agent;
	@Optional string default_task_type;
	@Optional AgentConfig[string] agents;
	/// Generate next-message suggestions (a small-model one-shot at each turn
	/// end and on opening a live task). Set false to stop the backend from
	/// creating them at all; title generation is separate and unaffected.
	@Optional bool suggestions = true;
	@Optional bool dev_mode;
	@Optional string log_level = "info";
	@Optional UiConfig ui;
	@Optional string system_keyword = "SYSTEM";
	@Optional long disk_cleanup_threshold_bytes = 10_485_760;

	/// Called by configy during parsing.
	void validate() const
	{
		import std.format : format;
		import std.algorithm : canFind;
		if (!["trace", "info", "warning", "error"].canFind(log_level))
			throw new Exception("unknown log_level: " ~ log_level);
		if (system_keyword.length == 0)
			throw new Exception("system_keyword must be nonempty");
		if (disk_cleanup_threshold_bytes <= 0)
			throw new Exception("disk_cleanup_threshold_bytes must be positive");
		version (linux) {}
		else
			if (memoryLimitingInUse(this))
				throw new Exception("memory limits (sandbox.memory, total_agent_memory) "
					~ "are only supported on Linux with systemd");
		total_agent_memory.validate("total_agent_memory");
		validateSandbox(sandbox, "sandbox");
		foreach (ref ws; workspaces)
			validateSandbox(ws.sandbox, format("workspaces['%s'].sandbox", ws.name));
		foreach (name, ref ac; agents)
		{
			validateSandbox(ac.sandbox, format("agents['%s'].sandbox", name));
			auto driver = effectiveDriver(name, ac);
			// An unresolvable driver is resolveConfig's error to report.
			if (driver.isNull)
				continue;
			if (ac.usage_polling_period.set)
			{
				auto period = ac.usage_polling_period.value;
				auto source = format("agents['%s'].usage_polling_period", name);
				if (driver.get != AgentDriver.claude)
					throw new Exception(source ~ ": only the claude driver reports usage");
				if (!period.turns.set && !period.timespan.set)
					throw new Exception(source ~ ": set turns or timespan");
				if (period.turns.set && period.turns.value == 0)
					throw new Exception(source ~ ": turns must be positive");
				if (period.timespan.set && period.timespan.value <= Duration.zero)
					throw new Exception(source ~ ": timespan must be positive");
			}
			if (driver.get != AgentDriver.claude
				&& (ac.permissions.policy.set || ac.permissions.auto_mode.set))
				throw new Exception(format(
					"agents['%s'].permissions: the %s driver does not consult a permission policy",
					name, driver.get));
			if (driverSupportsEffort(driver.get))
				continue;
			foreach (modelClass, ref spec; ac.model_aliases)
				if (spec.effort.length > 0)
					throw new Exception(format(
						"agents['%s'].model_aliases['%s']: the %s driver does not support `effort`",
						name, modelClass, driver.get));
		}
	}
}

private void validateSandbox(const ref SandboxConfig sandbox, string source)
{
	import djinja.djinja : loadData;
	import std.algorithm : canFind;

	sandbox.memory.validate(source ~ ".memory");
	if (!sandbox.unsandboxed_command_execution.set)
		return;

	auto value = sandbox.unsandboxed_command_execution.value;
	if (!value.canFind("{{"))
	{
		parseUnsandboxedCommandExecution(value, source);
		return;
	}

	try
		loadData(value);
	catch (Exception e)
		throw new Exception(source ~ ": unsandboxed_command_execution: " ~ e.msg, e);
}

CydoConfig loadConfig()
{
	import std.logger : infof;

	auto path = configPath();
	CydoConfig config;
	string text;
	if (readConfigText(path, text))
		config = parseConfigNode!CydoConfig(loadConfigYaml(text, path), path);
	else
		infof("No config file at %s; using defaults", path);

	try
		applyPostLoadFixups(config);
	catch (Exception e)
		throw new ConfigFileException(ConfigErrorKind.invalid, path, e.msg);
	return config;
}

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
	import std.algorithm : canFind;
	import ae.sys.file : realPath;
	import cydo.runtime.config.yaml : parseYamlConfigString;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
	import std.path : buildPath, buildNormalizedPath;
	import std.process : environment;

	private void withConfigFileFixture(void delegate(string path) body)
	{
		import std.file : tempDir;
		import std.path : dirName;
		import std.uuid : randomUUID;

		auto root = buildPath(tempDir(), "cydo-config-load-" ~ randomUUID().toString());
		auto oldHome = environment.get("HOME", "");
		auto hadHome = "HOME" in environment;
		environment["HOME"] = root;
		auto path = configPath();
		mkdirRecurse(dirName(path));
		scope (exit)
		{
			if (hadHome)
				environment["HOME"] = oldHome;
			else
				environment.remove("HOME");
			rmdirRecurse(root);
		}
		body(path);
	}

	unittest // An absent config file yields the local workspace rooted at HOME.
	{
		withConfigFileFixture((string path)
		{
			assert(!exists(path));
			auto config = loadConfig();
			assert(config.workspaces.length == 1);
			assert(config.workspaces[0].name == "local");
			assert(config.workspaces[0].root == realPath(environment["HOME"]));
		});
	}

	unittest // An existing path that cannot be read is a typed error.
	{
		import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException;
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			mkdirRecurse(path);
			auto error = collectException!ConfigFileException(loadConfig());
			assert(error !is null, "expected an unreadable config directory");
			assert(error.kind == ConfigErrorKind.unreadable, error.msg);
			assert(error.path == path && error.msg.canFind(path ~ ": cannot be read: ")
				&& error.msg.canFind("expected a regular file"), error.msg);
		});
		withConfigFileFixture((string path)
		{
			symlink(path ~ ".missing", path);
			auto error = collectException!ConfigFileException(loadConfig());
			assert(error !is null, "expected an unreadable dangling config symlink");
			assert(error.kind == ConfigErrorKind.unreadable, error.msg);
			assert(error.path == path && error.msg.canFind(path ~ ": cannot be read: ")
				&& error.msg.canFind("No such file or directory"), error.msg);
		});
	}

	unittest // Reject a FIFO after opening it in nonblocking mode.
	{
		import core.sys.posix.sys.stat : S_IRUSR, S_IWUSR, mkfifo;
		import std.exception : collectException;
		import std.string : toStringz;

		withConfigFileFixture((string path)
		{
			assert(mkfifo(path.toStringz, S_IRUSR | S_IWUSR) == 0);
			auto error = collectException!ConfigFileException(loadConfig());
			assert(error !is null && error.kind == ConfigErrorKind.unreadable);
			assert(error.path == path && error.msg.canFind("expected a regular file"), error.msg);
		});
	}

	unittest // YAML syntax failures retain the source line.
	{
		import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException;
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			write(path, "x: ]\n");
			auto error = collectException!ConfigFileException(loadConfig());
			assert(error !is null, "expected a config syntax error");
			assert(error.kind == ConfigErrorKind.syntax, error.msg);
			assert(error.path == path && error.msg.canFind(path ~ ":1"), error.msg);
		});
	}

	unittest // Invalid explicit tags fail during YAML construction.
	{
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			write(path, "dev_mode: !!timestamp garbage\n");
			auto error = collectException!ConfigFileException(loadConfig());
			assert(error !is null && error.kind == ConfigErrorKind.syntax);
			assert(error.path == path && error.msg.canFind(path
				~ ": syntax error: Unable to parse timestamp value: garbage"), error.msg);
		});
	}

	unittest // Schema, validation, and workspace fixup failures are invalid config.
	{
		import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException;
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			auto invalidConfigs = [
				"workspaces: {}\nunknown_key: true\n": "unknown_key",
				"workspaces: {}\nsystem_keyword: ''\n": "system_keyword",
				"workspaces: {}\nlog_level: verbose\n": "log_level",
				"workspaces: {local: {root: '~/.config/cydo/config.yaml'}}\n":
					"workspace root must be a directory",
			];
			foreach (yaml, diagnostic; invalidConfigs)
			{
				write(path, yaml);
				auto error = collectException!ConfigFileException(loadConfig());
				assert(error !is null, "expected invalid config for " ~ yaml);
				assert(error.kind == ConfigErrorKind.invalid && error.path == path, error.msg);
				assert(error.msg.canFind(diagnostic), error.msg);
			}
		});
	}

	version (linux) unittest // YAML integers use the core schema before size parsing.
	{
		withConfigFileFixture((string path)
		{
			foreach (scalar, expected; ["1024": "1024", "8G": "8589934592", "50%": "50%",
				"+1": "1", "0x10": "16"])
			{
				write(path, "workspaces: {}\nsandbox: {memory: {max: " ~ scalar ~ "}}\n");
				assert(loadConfig().sandbox.memory.max.value.toSystemd() == expected, scalar);
			}
			foreach (zero; ["0", "0%"])
			{
				write(path, "workspaces: {}\nsandbox: {memory: {swap_max: " ~ zero ~ "}}\n");
				assert(loadConfig().sandbox.memory.swap_max.value.toSystemd() == zero);
			}
		});
	}

	unittest // Invalid limits identify the offending field and file.
	{
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			foreach (field; ["max", "high", "swap_max"])
				foreach (scalar; ["8GB", "'+1'", "'0x10'", "'1e3'", "-1",
					"123456.4", "1e3", "1e5", "1e6", "{=: 1G, other: garbage}",
					"[1G]", "null", "true", "'18446744073709551615'", "16777216T"])
				{
					write(path, "workspaces: {}\nsandbox: {memory: {" ~ field ~ ": " ~ scalar ~ "}}\n");
					auto error = collectException!ConfigFileException(loadConfig());
					assert(error !is null, scalar);
					assert(error.kind == ConfigErrorKind.invalid && error.path == path, error.msg);
					assert(error.msg.canFind(field), error.msg);
				}

			write(path, "workspaces: {}\nsandbox: {memory: {max: 18446744073709551615}}\n");
			auto oversized = collectException!ConfigFileException(loadConfig());
			assert(oversized !is null && oversized.kind == ConfigErrorKind.syntax);
			assert(oversized.path == path, oversized.msg);
		});
	}

	version (linux) unittest // All sandbox layers reject a zero max or high.
	{
		import std.exception : collectException;
		import std.format : format;

		withConfigFileFixture((string path)
		{
			foreach (layout, location; [
				"workspaces: {}\nsandbox: {memory: {%s: %s}}":
					"sandbox.memory.",
				"workspaces: {}\nagents: {claude: {sandbox: {memory: {%s: %s}}}}":
					"agents['claude'].sandbox.memory.",
				"workspaces: {local: {root: /tmp, sandbox: {memory: {%s: %s}}}}":
					"workspaces['local'].sandbox.memory.",
			])
				foreach (field; ["max", "high"])
					foreach (zero; ["0", "0%"])
					{
						write(path, format(layout, field, zero) ~ "\n");
						auto error = collectException!ConfigFileException(loadConfig());
						assert(error !is null);
						assert(error.kind == ConfigErrorKind.invalid && error.path == path, error.msg);
						assert(error.msg.canFind(location ~ field), error.msg);
					}
		});
	}

	version (linux) unittest // Aggregate limits enforce the same property bounds as scoped limits.
	{
		import std.exception : collectException;

		withConfigFileFixture((string path)
		{
			foreach (field, values; ["max": ["0", "0%", "8388608T"],
				"high": ["0", "0%", "'18446744073709551615'"],
				"swap_max": ["8388608T", "'18446744073709551615'"]])
				foreach (scalar; values)
				{
					write(path, "workspaces: {}\ntotal_agent_memory: {" ~ field ~ ": " ~ scalar ~ "}\n");
					auto error = collectException!ConfigFileException(loadConfig());
					assert(error !is null, scalar);
					assert(error.kind == ConfigErrorKind.invalid && error.path == path, error.msg);
					assert(error.msg.canFind(field), error.msg);
				}

			foreach (zero; ["0", "0%"])
			{
				write(path, "workspaces: {}\ntotal_agent_memory: {swap_max: " ~ zero ~ "}\n");
				assert(loadConfig().total_agent_memory.swap_max.value.toSystemd() == zero);
			}
		});
	}

	unittest // Runtime config paths expand HOME and the package re-exports configPath.
	{
		import cydo.runtime.config.paths : configDir, pathsConfigPath = configPath,
			userTaskTypesPath, userDefsDir;

		auto oldHome = environment.get("HOME", "");
		auto hadHome = "HOME" in environment;
		scope (exit)
		{
			if (hadHome)
				environment["HOME"] = oldHome;
			else
				environment.remove("HOME");
		}

		environment["HOME"] = "/tmp/cydo-test-runtime-config-paths-home";
		auto expectedDir = buildPath(environment["HOME"], ".config", "cydo");
		assert(configDir() == expectedDir);
		assert(configPath() == buildPath(expectedDir, "config.yaml"));
		assert(pathsConfigPath() == configPath());
		assert(userTaskTypesPath() == buildPath(expectedDir, "task-types.yaml"));
		assert(userDefsDir() == buildPath(expectedDir, "defs"));
	}

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

	unittest
	{
		parseYamlConfigString!CydoConfig(workspacesYAML, "/dev/null");
		parseYamlConfigString!CydoConfig(workspacesYAML ~ "ui: {}\n", "/dev/null");
	}

	unittest
	{
		try
		{
			parseYamlConfigString!CydoConfig(workspacesYAML ~ "system_keyword: ''\n", "/dev/null");
			assert(false, "expected an empty system keyword to be rejected");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("system_keyword must be nonempty"));
		}
	}

	// 1. A scalar entry parses to model == the scalar, effort == "".
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      small: haiku\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["small"];
		assert(spec.model == "haiku");
		assert(spec.effort == "");
	}

	// 2. A mapping entry with both keys parses both.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        model: opus\n        effort: high\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "opus");
		assert(spec.effort == "high");
	}

	// 3. A mapping entry with only effort: keeps model empty ("keep the class default").
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "");
		assert(spec.effort == "high");
	}

	// 4. A mapping entry with only model: leaves effort empty.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        model: opus\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
		auto spec = config.agents["my-claude"].model_aliases["large"];
		assert(spec.model == "opus");
		assert(spec.effort == "");
	}

	// 5. Scalar and mapping entries coexist in the same model_aliases map.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      small: haiku\n      large:\n        model: opus\n        effort: high\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
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
			parseYamlConfigString!CydoConfig(yaml, "/dev/null");
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
			parseYamlConfigString!CydoConfig(yaml, "/dev/null");
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
			parseYamlConfigString!CydoConfig(yaml, "/dev/null");
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
			parseYamlConfigString!CydoConfig(yaml, "/dev/null");
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
		parseYamlConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 11. An arbitrary, unrecognised effort value on claude parses without throwing.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-claude:\n    driver: claude\n"
			~ "    model_aliases:\n      large:\n        effort: some-future-level\n";
		parseYamlConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 12. A model-only alias on a copilot agent parses without throwing.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  my-copilot:\n    driver: copilot\n"
			~ "    model_aliases:\n      small: gpt-4.1\n      large:\n        model: gpt-4.1\n";
		parseYamlConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 13. An agent whose key is not a driver name and has no driver: field, with
	// effort set, parses without throwing from validate() — resolveConfig
	// reports the "driver field is required" error, not validate().
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  custom:\n"
			~ "    model_aliases:\n      large:\n        effort: high\n";
		parseYamlConfigString!CydoConfig(yaml, "/dev/null");
	}

	// 14. A permissions block parses at every layer, recording which fields
	// each layer sets.
	unittest
	{
		auto yaml = "permissions:\n  prompt_timeout: 30\n"
			~ "agents:\n  claude-auto:\n    driver: claude\n"
			~ "    permissions:\n      auto_mode: true\n"
			~ "workspaces:\n  local:\n    root: /tmp\n"
			~ "    permissions:\n      policy: ask\n";
		auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
		assert(config.permissions.prompt_timeout.set);
		assert(config.permissions.prompt_timeout == 30);
		assert(!config.permissions.auto_mode.set);
		auto agent = config.agents["claude-auto"].permissions;
		assert(agent.auto_mode.set && agent.auto_mode);
		assert(!agent.policy.set);
		auto workspace = config.workspaces[0].permissions;
		assert(workspace.policy.set && workspace.policy == "ask");
		assert(!workspace.auto_mode.set);
	}

	// 15. permissions on an agent entry whose driver does not consult them
	// throws.
	unittest
	{
		auto yaml = workspacesYAML ~ "agents:\n  codex:\n"
			~ "    permissions:\n      auto_mode: true\n";
		try
		{
			parseYamlConfigString!CydoConfig(yaml, "/dev/null");
			assert(false, "expected a ConfigException");
		}
		catch (Exception e)
		{
			assert(e.toString().canFind("agents['codex'].permissions"));
			assert(e.toString().canFind("does not consult a permission policy"));
		}
	}

	// 16. The old flat workspace keys are rejected (configy's strict mode).
	unittest
	{
		auto yaml = "workspaces:\n  local:\n    root: /tmp\n    auto_mode: true\n";
		assertThrown!Exception(parseYamlConfigString!CydoConfig(yaml, "/dev/null"));
	}

	// Disk cleanup has a positive, wide threshold and preserves its default.
	unittest
	{
		assert(parseYamlConfigString!CydoConfig(workspacesYAML, "/dev/null")
			.disk_cleanup_threshold_bytes == 10_485_760);
		assert(parseYamlConfigString!CydoConfig(workspacesYAML
			~ "disk_cleanup_threshold_bytes: 4294967296\n", "/dev/null")
			.disk_cleanup_threshold_bytes == 4_294_967_296L);
		foreach (value; ["0", "-1", "\"9223372036854775808\""])
		{
			bool rejected;
			try
				parseYamlConfigString!CydoConfig(workspacesYAML
					~ "disk_cleanup_threshold_bytes: " ~ value ~ "\n", "/dev/null");
			catch (Exception e)
			{
				assert(e.toString.canFind("disk_cleanup_threshold_bytes"),
					value ~ ": " ~ e.toString);
				rejected = true;
			}
			assert(rejected);
		}
		assertThrown!Exception(parseYamlConfigString!CydoConfig(workspacesYAML
			~ "disk_cleanup_threshold_bytes: 9223372036854775808\n", "/dev/null"));
	}
}

unittest
{
	import std.algorithm : canFind;
	import std.exception : collectException;
	import std.format : format;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (layer; [
		["workspaces: {}\nsandbox: {unsandboxed_command_execution: %s}\n", "sandbox"],
		["workspaces: {}\nagents: {codex: {sandbox: {unsandboxed_command_execution: %s}}}\n",
			"agents['codex'].sandbox"],
		["workspaces: {local: {root: /tmp, sandbox: {unsandboxed_command_execution: %s}}}\n",
			"workspaces['local'].sandbox"],
	])
	{
		foreach (valid; ["no", "yes", "ask"])
		{
			auto cfg = parseYamlConfigString!CydoConfig(format(layer[0], valid), "config.yaml");
			switch (layer[1])
			{
				case "sandbox":
					assert(cfg.sandbox.unsandboxed_command_execution.value == valid);
					break;
				case "agents['codex'].sandbox":
					assert(cfg.agents["codex"].sandbox.unsandboxed_command_execution.value == valid);
					break;
				default:
					assert(cfg.workspaces[0].sandbox.unsandboxed_command_execution.value == valid);
					break;
			}
		}
		foreach (invalid; ["on", "maybe", "'{{ \"a\" if }}'"])
		{
			auto error = collectException(parseYamlConfigString!CydoConfig(
				format(layer[0], invalid), "config.yaml"));
			assert(error && error.toString().canFind(layer[1])
				&& error.toString().canFind("unsandboxed_command_execution"));
		}
	}

	auto settings = parseYamlConfigString!CydoConfig(
		"workspaces: {}\nagents: {codex: {permissions: {prompt_timeout: 30}}}\n",
		"config.yaml");
	assert(settings.agents["codex"].permissions.prompt_timeout.value == 30);
	assert(collectException(parseYamlConfigString!CydoConfig(
		"workspaces: {}\nagents: {codex: {permissions: {policy: ask}}}\n", "config.yaml")));
}

unittest // Claude usage polling accepts both a turn count and a duration.
{
	import core.time : minutes;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	auto config = parseYamlConfigString!CydoConfig(
		"workspaces: {}\nagents: {claude: {usage_polling_period: {turns: 3, timespan: {minutes: 20}}}}\n",
		"config.yaml");
	auto period = config.agents["claude"].usage_polling_period;
	assert(period.set);
	assert(period.value.turns.set && period.value.turns.value == 3);
	assert(period.value.timespan.set && period.value.timespan.value == 20.minutes);
}

unittest // A custom agent can opt in through its explicit Claude driver.
{
	import cydo.runtime.config.yaml : parseYamlConfigString;

	auto config = parseYamlConfigString!CydoConfig(
		"workspaces: {}\nagents: {my-claude: {driver: claude, usage_polling_period: {turns: 1}}}\n",
		"config.yaml");
	auto period = config.agents["my-claude"].usage_polling_period;
	assert(period.set);
	assert(period.value.turns.set && period.value.turns.value == 1);
	assert(!period.value.timespan.set);
}

unittest // Usage polling is opt-in.
{
	import cydo.runtime.config.yaml : parseYamlConfigString;

	auto config = parseYamlConfigString!CydoConfig(
		"workspaces: {}\nagents: {claude: {}}\n", "config.yaml");
	assert(!config.agents["claude"].usage_polling_period.set);
}

unittest // Only Claude agents can enable usage polling.
{
	import std.algorithm : canFind;
	import std.exception : collectException;
	import std.format : format;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (agent; ["codex", "copilot"])
	{
		auto error = collectException(parseYamlConfigString!CydoConfig(format(
			"workspaces: {}\nagents: {%s: {usage_polling_period: {turns: 1}}}\n", agent),
			"config.yaml"));
		assert(error, agent);
		assert(error.toString().canFind(format("agents['%s'].usage_polling_period", agent)),
			error.toString());
		assert(error.toString().canFind("only the claude driver"), error.toString());
	}
}

unittest // A polling period must specify at least one positive interval.
{
	import std.algorithm : canFind;
	import std.exception : collectException;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (testCase; [
		["{}", "set turns or timespan"],
		["{turns: 0}", "turns must be positive"],
		["{timespan: {seconds: 0}}", "timespan must be positive"],
	])
	{
		auto error = collectException(parseYamlConfigString!CydoConfig(
			"workspaces: {}\nagents: {claude: {usage_polling_period: " ~ testCase[0] ~ "}}\n",
			"config.yaml"));
		assert(error, testCase[0]);
		assert(error.toString().canFind("agents['claude'].usage_polling_period")
			&& error.toString().canFind(testCase[1]), error.toString());
	}
}

unittest // A polling duration must be a mapping of known units.
{
	import std.algorithm : canFind;
	import std.exception : collectException;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (timespan; ["soon", "{fortnights: 1}"])
	{
		auto error = collectException(parseYamlConfigString!CydoConfig(
			"workspaces: {}\nagents: {claude: {usage_polling_period: {timespan: " ~ timespan ~ "}}}\n",
			"config.yaml"));
		assert(error, timespan);
		assert(error.toString().canFind("usage_polling_period.timespan"), error.toString());
	}
}

unittest
{
	import std.exception : assertThrown;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	auto config = parseYamlConfigString!CydoConfig(
		"workspaces: {}\nui: { usage: { coloring: percent, remaining: true } }\n",
		"config.yaml");
	assert(config.ui.usage.coloring == UsageColoring.percent);
	assert(config.ui.usage.remaining);

	assertThrown!Exception(parseYamlConfigString!CydoConfig(
		"workspaces: {}\nui: { usage: { coloring: rainbow } }\n", "config.yaml"));
}

unittest // Sidebar order defaults to oldest first at every optional level.
{
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (ui; ["", "ui: {}\n", "ui: { sidebar: {} }\n"])
	{
		auto config = parseYamlConfigString!CydoConfig(
			"workspaces: {}\n" ~ ui, "config.yaml");
		assert(config.ui.sidebar.order == SidebarOrder.oldest_first);
	}
}

unittest // Sidebar order accepts both directions and rejects unknown values.
{
	import std.exception : assertThrown;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	enum prefix = "workspaces: {}\nui: { sidebar: { order: ";
	assert(parseYamlConfigString!CydoConfig(
		prefix ~ "oldest_first } }\n", "config.yaml").ui.sidebar.order == SidebarOrder.oldest_first);
	assert(parseYamlConfigString!CydoConfig(
		prefix ~ "newest_first } }\n", "config.yaml").ui.sidebar.order == SidebarOrder.newest_first);
	assertThrown!Exception(parseYamlConfigString!CydoConfig(
		prefix ~ "recent_first } }\n", "config.yaml"));
}

unittest // Sidebar sort defaults to creation at every optional level.
{
	import cydo.runtime.config.yaml : parseYamlConfigString;

	foreach (ui; ["", "ui: {}\n", "ui: { sidebar: {} }\n"])
	{
		auto config = parseYamlConfigString!CydoConfig(
			"workspaces: {}\n" ~ ui, "config.yaml");
		assert(config.ui.sidebar.sort == SidebarSort.creation);
	}
}

unittest // Sidebar sort accepts both modes and rejects unknown values.
{
	import std.exception : assertThrown;
	import cydo.runtime.config.yaml : parseYamlConfigString;

	enum prefix = "workspaces: {}\nui: { sidebar: { sort: ";
	assert(parseYamlConfigString!CydoConfig(
		prefix ~ "creation } }\n", "config.yaml").ui.sidebar.sort == SidebarSort.creation);
	assert(parseYamlConfigString!CydoConfig(
		prefix ~ "activity } }\n", "config.yaml").ui.sidebar.sort == SidebarSort.activity);
	assertThrown!Exception(parseYamlConfigString!CydoConfig(
		prefix ~ "alphabetical } }\n", "config.yaml"));
}
