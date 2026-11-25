module cydo.runtime.config;

import configy.attributes : ConfigParser, Key, Optional, SetInfo;
import cydo.runtime.config.yaml : parseYamlConfigFile;

import dyaml.node : NodeID;

import core.time : Duration;
import std.typecons : Nullable;

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

struct UiConfig
{
	@Optional UsageUiConfig usage;
}

struct CydoConfig
{
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

	/// Called by configy during parsing (configy/read.d:650), so a semantic
	/// error surfaces on the same path as a YAML syntax error.
	void validate() const
	{
		import std.format : format;
		if (system_keyword.length == 0)
			throw new Exception("system_keyword must be nonempty");
		if (disk_cleanup_threshold_bytes <= 0)
			throw new Exception("disk_cleanup_threshold_bytes must be positive");
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
	auto result = parseYamlConfigFile!CydoConfig(configPath);
	CydoConfig config = result.isNull() ? CydoConfig.init : result.get();
	applyPostLoadFixups(config);
	return config;
}

/// Re-parse config file. Returns null on parse error (caller keeps old config).
Nullable!CydoConfig reloadConfig()
{
	auto result = parseYamlConfigFile!CydoConfig(configPath);
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
	import std.algorithm : canFind;
	import ae.sys.file : realPath;
	import cydo.runtime.config.yaml : parseYamlConfigString;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
	import std.path : buildPath, buildNormalizedPath;
	import std.process : environment;

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
