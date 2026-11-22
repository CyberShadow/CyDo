/// Task type definitions — schema, YAML loader, validation, and prompt rendering.
///
/// Task types define agent behavior, capabilities, and flow control.
/// See docs/task-types.md for the design document.
module cydo.domain.task_types.definition;

import configy.attributes : Key, Optional;

import std.algorithm : canFind, filter, map, reverse, sort;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.string : lineSplitter, strip;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

enum OutputType : string
{
	report = "report",
	commit = "commit",
	worktree = "worktree",
}

enum WorktreeMode : string
{
	inherit = "inherit",
	require = "require",
	fork = "fork",
}

/// Default agent expression — pass the parent's agent type through unchanged.
enum string defaultAgentExpr = "{{ parent_agent_type }}";

/// A Djinja template loaded from a YAML scalar. Keeping it distinct from
/// `string` forces every runtime consumer to render it explicitly.
struct DjinjaTemplate
{
private:
	string source_;

public:
	this(string source)
	{
		source_ = source;
	}

	static DjinjaTemplate fromString(string source)
	{
		return DjinjaTemplate(source);
	}

	void opAssign(string source)
	{
		source_ = source;
	}

	string render(string[string] vars) const
	{
		return substituteVars(source_, vars);
	}

	bool empty() const pure nothrow @safe @nogc
	{
		return source_.length == 0;
	}

	bool dynamic() const
	{
		return source_.canFind("{{");
	}

	/// Raw template source for validation, diagnostics, and configuration UI.
	string source() const pure nothrow @safe @nogc
	{
		return source_;
	}
}

struct ContinuationDef
{
	string task_type;
	bool requires_approval;
	bool keep_context;
	@Optional WorktreeMode worktree;
	@Optional string prompt_template;
	@Optional string description;
}

struct CreatableTaskDef
{
	string name;
	@Optional string task_type; // actual type to create (defaults to name)
	@Optional WorktreeMode worktree;
	@Optional string prompt_template;
	@Optional string result_note;
	@Optional string description;

	/// Resolve the actual task type (task_type field, or name if unset).
	string resolvedType() const
	{
		return task_type.length > 0 ? task_type : name;
	}
}

struct UserEntryPointDef
{
	string name; // from YAML mapping key
	@Optional string task_type; // defaults to name
	string description; // required — shown in UI
	@Optional string prompt_template;
	@Optional WorktreeMode worktree;
	/// CyDo starts tasks here itself; the UI does not offer it.
	@Optional bool system;

	string resolvedType() const
	{
		return task_type.length > 0 ? task_type : name;
	}
}

struct TaskTypeDef
{
	// Name (populated from YAML mapping key via @Key)
	string name;

	// Identity
	@Optional string icon;
	@Optional string agent_description;
	@Optional string tool_guidance;
	@Optional string prompt_template;
	@Optional string system_prompt_template;

	// Capabilities
	DjinjaTemplate model_class = DjinjaTemplate("large");
	@Optional bool read_only;
	@Optional OutputType[] output_type;
	@Optional bool allow_native_subagents;

	// Flow control
	@Optional @Key("name") CreatableTaskDef[] creatable_tasks;
	@Optional ContinuationDef[string] continuations;
	@Optional ContinuationDef on_yield; // auto-continuation on clean exit

	// Execution
	@Optional bool serial;
	@Optional uint max_turns;
	DjinjaTemplate agent = DjinjaTemplate(defaultAgentExpr);

	// Memory
	@Optional bool memory;

	// Steward
	@Optional bool steward;
	@Optional string steward_domain;
	@Optional string knowledge_base;
}

// Top-level wrapper struct for YAML parsing (configy requires a struct).
struct TaskTypesFile
{
	@Key("name") TaskTypeDef[] task_types;
	@Optional @Key("name") UserEntryPointDef[] user_entry_points;
	@Optional @Key("name") SingletonDef[] singletons;
}

enum SingletonAudience : string
{
	interactive = "interactive",
	all = "all",
}

struct SingletonDef
{
	string name;
	string task_type;
	string prompt_template;
	string title;
	@Optional SingletonAudience offered_to = SingletonAudience.interactive;
	@Optional string description;
}

/// Combined result of loading task types (types + entry points).
struct TaskTypeConfig
{
	TaskTypeDef[] types;
	UserEntryPointDef[] entryPoints;
	SingletonDef[] singletons;
}

/// Look up a task type by name. Returns a pointer into the array, or null.
inout(TaskTypeDef)* byName(inout TaskTypeDef[] types, string name)
{
	foreach (ref t; types)
		if (t.name == name)
			return &t;
	return null;
}

/// Look up a creatable task def by name.
inout(CreatableTaskDef)* byName(inout CreatableTaskDef[] defs, string name)
{
	foreach (ref d; defs)
		if (d.name == name)
			return &d;
	return null;
}

/// Look up a user entry point def by name.
inout(UserEntryPointDef)* byName(inout UserEntryPointDef[] defs, string name)
{
	foreach (ref d; defs)
		if (d.name == name)
			return &d;
	return null;
}

inout(SingletonDef)* byName(inout SingletonDef[] defs, string name)
{
	foreach (ref d; defs)
		if (d.name == name)
			return &d;
	return null;
}

/// Returns the "interactive cluster": the set of types reachable from any
/// entry point type via keep_context continuations.
bool[string] interactiveTypeSet(TaskTypeDef[] types, UserEntryPointDef[] entryPoints)
{
	bool[string] result;
	void walk(string name)
	{
		if (name in result)
			return;
		result[name] = true;
		auto d = types.byName(name);
		if (d is null)
			return;
		foreach (_, ref c; d.continuations)
			if (c.keep_context)
				walk(c.task_type);
	}
	foreach (ref ep; entryPoints)
		walk(ep.resolvedType);
	return result;
}

/// Returns true if the given type name is in the interactive cluster.
/// These types are all permitted to call AskUserQuestion.
bool isInteractive(TaskTypeDef[] types, UserEntryPointDef[] entryPoints, string typeName)
{
	return (typeName in interactiveTypeSet(types, entryPoints)) !is null;
}

SingletonDef[] singletonsOfferedTo(TaskTypeDef[] types, UserEntryPointDef[] entryPoints,
	SingletonDef[] singletons, string typeName)
{
	auto interactive = isInteractive(types, entryPoints, typeName);
	return singletons.filter!(s => s.task_type != typeName
		&& (s.offered_to == SingletonAudience.all || interactive)).array;
}

unittest
{
	TaskTypeDef interactiveTask;
	interactiveTask.name = "conversation";
	TaskTypeDef isolatedTask;
	isolatedTask.name = "isolated";
	TaskTypeDef integratorTask;
	integratorTask.name = "integrator";
	TaskTypeDef reviewerTask;
	reviewerTask.name = "reviewer";
	auto types = [interactiveTask, isolatedTask, integratorTask, reviewerTask];
	auto entryPoints = [UserEntryPointDef("chat", "conversation")];
	auto interactiveOnly = SingletonDef("review", "reviewer");
	auto integrator = SingletonDef("integrate", "integrator", "", "", SingletonAudience.all);
	auto reviewer = SingletonDef("review", "reviewer", "", "", SingletonAudience.all);

	assert(singletonsOfferedTo(types, entryPoints, [interactiveOnly, integrator],
		"conversation") == [interactiveOnly, integrator]);
	assert(singletonsOfferedTo(types, entryPoints, [interactiveOnly, integrator],
		"isolated") == [integrator]);

	// The all audience includes other singleton types outside the interactive cluster.
	assert(singletonsOfferedTo(types, entryPoints, [integrator, reviewer],
		"integrator") == [reviewer]);
	assert(singletonsOfferedTo(types, entryPoints, [integrator, reviewer],
		"reviewer") == [integrator]);

	entryPoints ~= [UserEntryPointDef("integrate", "integrator", system: true),
		UserEntryPointDef("review", "reviewer", system: true)];
	auto interactiveIntegrator = SingletonDef("integrate", "integrator");
	assert(singletonsOfferedTo(types, entryPoints, [interactiveIntegrator, interactiveOnly],
		"integrator") == [interactiveOnly]);
	assert(singletonsOfferedTo(types, entryPoints, [interactiveIntegrator, interactiveOnly],
		"reviewer") == [interactiveIntegrator]);
}

string formatCompactSingletonToolSummary(SingletonDef[] singletons)
{
	return singletons.map!(s => "- " ~ s.name ~ ": "
		~ (s.description.length ? s.description.lineSplitter.front : "")).join("\n");
}

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

import dyaml.node : Node, NodeID;

/// Load task types from one or more YAML files, merging them in order
/// (later files override earlier ones at the YAML level).
TaskTypeConfig loadTaskTypes(string[] paths...)
{
	import configy.read : parseConfig, CLIArgs;
	import dyaml.loader : Loader;
	import std.file : exists;

	Node root;
	bool hasRoot = false;

	foreach (path; paths)
	{
		if (path.length == 0 || !exists(path))
			continue;
		auto node = Loader.fromFile(path).load();
		if (!hasRoot)
		{
			root = node;
			hasRoot = true;
		}
		else
			root = deepMerge(root, node);
	}

	if (!hasRoot)
		throw new Exception("No task type files found in: " ~ paths.join(", "));

	auto result = parseConfig!TaskTypesFile(CLIArgs(paths[0]), root);

	// Ensure "blank" type always exists even if not in any config file.
	if (result.task_types.byName("blank") is null)
	{
		TaskTypeDef blank;
		blank.name = "blank";
		blank.icon = "blank";
		blank.model_class = DjinjaTemplate("large");
		blank.allow_native_subagents = true;
		result.task_types = blank ~ result.task_types;
	}
	if (result.user_entry_points.byName("blank") is null)
	{
		UserEntryPointDef ep;
		ep.name = "blank";
		ep.task_type = "blank";
		ep.description = "Raw agent session with no prompt wrapping or tool restrictions";
		ep.prompt_template = "prompts/blank.md";
		result.user_entry_points = ep ~ result.user_entry_points;
	}

	SingletonDef[] singletons;
	foreach (ref singleton; result.singletons)
	{
		enforce(result.user_entry_points.byName(singleton.name) is null,
			"singletons: '" ~ singleton.name ~ "' is already an entry point");
		if (singleton.task_type.length == 0)
			continue;
		enforce(result.task_types.byName(singleton.task_type) !is null,
			"singletons: '" ~ singleton.name ~ "' has unknown task type '" ~ singleton.task_type ~ "'");
		UserEntryPointDef ep;
		ep.name = singleton.name;
		ep.task_type = singleton.task_type;
		ep.prompt_template = singleton.prompt_template;
		ep.system = true;
		result.user_entry_points ~= ep;
		singletons ~= singleton;
	}

	return TaskTypeConfig(result.task_types, result.user_entry_points, singletons);
}

unittest
{
	import std.exception : assertThrown, collectException;
	import std.file : remove, write;

	enum path = "/tmp/cydo-task-types-singleton-test.yaml";
	scope(exit) remove(path);
	enum types = "task_types:\n  lander:\n    model_class: large\n";
	enum singletonFields = "    prompt_template: p.md\n    title: Integrator\n";
	enum singleton = "singletons:\n  integrator:\n    task_type: lander\n" ~ singletonFields;

	write(path, types);
	auto config = loadTaskTypes(path);
	assert(config.singletons.length == 0);
	assert(config.entryPoints.byName("integrator") is null);

	write(path, types ~ singleton);
	config = loadTaskTypes(path);
	assert(config.singletons.length == 1);
	assert(config.singletons[0].name == "integrator");
	assert(config.singletons[0].title == "Integrator");
	auto ep = config.entryPoints.byName("integrator");
	assert(ep !is null);
	assert(ep.name == "integrator" && ep.resolvedType == "lander"
		&& ep.prompt_template == "p.md" && ep.system);
	assert(isInteractive(config.types, config.entryPoints, "lander"));

	write(path, types ~ "singletons:\n  integrator:\n    task_type: missing\n" ~ singletonFields);
	auto error = collectException(loadTaskTypes(path));
	assert(error !is null && error.msg == "singletons: 'integrator' has unknown task type 'missing'");

	enum collidingEntryPoint = "user_entry_points:\n  integrator:\n    task_type: lander\n"
		~ "    description: Lands\n";
	enum disabledSingleton = "singletons:\n  integrator:\n    task_type: \"\"\n" ~ singletonFields;
	foreach (declaration; [singleton, disabledSingleton])
	{
		write(path, types ~ collidingEntryPoint ~ declaration);
		error = collectException(loadTaskTypes(path));
		assert(error !is null && error.msg == "singletons: 'integrator' is already an entry point");
	}

	write(path, types ~ disabledSingleton);
	config = loadTaskTypes(path);
	assert(config.singletons.length == 0);
	assert(config.entryPoints.byName("integrator") is null);

	write(path, types ~ singleton ~ "  reviewer:\n    task_type: blank\n"
		~ "    prompt_template: review.md\n    title: Reviewer\n");
	config = loadTaskTypes(path);
	assert(config.singletons.length == 2);
	ep = config.entryPoints.byName("integrator");
	assert(ep !is null && ep.system);
	ep = config.entryPoints.byName("reviewer");
	assert(ep !is null && ep.system && ep.resolvedType == "blank" && ep.prompt_template == "review.md");

	write(path, types ~ "integrator:\n  task_type: lander\n  prompt_template: p.md\n");
	assertThrown(loadTaskTypes(path));
}

/// Deep-merge two YAML nodes. For mappings, keys from `overlay` are merged
/// into `base` recursively. For all other types, `overlay` wins outright.
private Node deepMerge(Node base, Node overlay)
{
	if (base.nodeID != NodeID.mapping)
		return overlay;
	if (overlay.nodeID != NodeID.mapping)
		return base;

	auto basePairs = base.get!(Node.Pair[]).dup;
	outer: foreach (ref oPair; overlay.get!(Node.Pair[]))
	{
		foreach (ref bPair; basePairs)
		{
			if (bPair.key == oPair.key)
			{
				bPair.value = deepMerge(bPair.value, oPair.value);
				continue outer;
			}
		}
		basePairs ~= oPair;
	}
	return Node(basePairs);
}

// ---------------------------------------------------------------------------
// Agent resolution
// ---------------------------------------------------------------------------

/// Render an `agent:` expression against the task creation context.
/// Returns empty string when the substitution produces nothing — caller decides
/// how to surface that.
string resolveAgent(DjinjaTemplate expr, string parentAgentType, string workspace = "")
{
	if (expr.empty)
		expr = DjinjaTemplate(defaultAgentExpr);
	return expr.render([
		"parent_agent_type": parentAgentType,
		"workspace": workspace,
	]).strip;
}

/// Render a `model_class:` expression after the task's agent has been resolved.
string resolveModelClass(DjinjaTemplate expr, string workspace, string agent)
{
	return expr.render(["workspace": workspace, "agent": agent]).strip;
}

// ---------------------------------------------------------------------------
// Validator
// ---------------------------------------------------------------------------

string[] validateTaskTypes(TaskTypeDef[] types, UserEntryPointDef[] entryPoints,
	SingletonDef[] singletons, bool delegate(string) isConfiguredAgentName,
	string[] typesDirs = null)
{
	import std.file : exists, readText;
	import std.path : buildPath;
	import cydo.foundation.system.framing : validateTemplateSource;

	string[] errors;
	foreach (ref singleton; singletons)
		if (singleton.description.strip.length == 0)
			errors ~= "singleton '" ~ singleton.name ~ "' has no description";


	/// Check that a prompt_template file exists on disk and has no adjacent placeholders.
	void checkTemplateFile(string context, string tmpl)
	{
		if (tmpl.length == 0 || typesDirs.length == 0)
			return;
		auto templateText = promptTemplateSource(typesDirs, tmpl);
		if (templateText is null)
			errors ~= format("%s: prompt_template '%s' not found", context, tmpl);
		else if (auto err = validateTemplateSource(templateText))
			errors ~= format("%s: prompt_template '%s': %s", context, tmpl, err);
	}

	/// Validate a single ContinuationDef, returning any errors found.
	string[] validateContinuationDef(string context, ref ContinuationDef cont)
	{
		string[] errs;
		if (types.byName(cont.task_type) is null)
			errs ~= format("%s: references unknown type '%s'", context, cont.task_type);
		if (cont.keep_context && cont.worktree != WorktreeMode.inherit)
			errs ~= format("%s: has keep_context and worktree: %s — keep_context requires worktree: inherit",
				context, cont.worktree);
		if (cont.keep_context && cont.prompt_template.length == 0)
			errs ~= format("%s: has keep_context but no prompt_template"
				~ " — mode switches need an entry prompt", context);
		checkTemplateFile(context, cont.prompt_template);
		return errs;
	}

	bool hasSteward = false;
	foreach (ref def; types)
	{
		if (def.steward)
			hasSteward = true;

		checkTemplateFile(def.name, def.prompt_template);
		checkTemplateFile(def.name, def.system_prompt_template);

		// Check creatable_tasks references
		foreach (ref edge; def.creatable_tasks)
		{
			if (types.byName(edge.resolvedType) is null)
				errors ~= format("%s: creatable_tasks '%s' references unknown type '%s'",
					def.name, edge.name, edge.resolvedType);
			checkTemplateFile(format("%s: creatable_tasks '%s'", def.name, edge.name), edge.prompt_template);
		}

		// Check continuation references
		foreach (cname, ref cont; def.continuations)
			errors ~= validateContinuationDef(
				format("%s: continuation '%s'", def.name, cname), cont);

		// Check on_yield
		if (def.on_yield.task_type.length > 0)
			errors ~= validateContinuationDef(format("%s: on_yield", def.name), def.on_yield);

		// Steward validation
		if (def.steward)
		{
			if (def.output_type.canFind(OutputType.commit) || def.output_type.canFind(OutputType.worktree))
				errors ~= format("%s: steward should not have commit or worktree outputs", def.name);
			if (!def.serial)
				errors ~= format("%s: steward should have serial: true", def.name);
		}

		// output_type is validated by D enum deserialization — unknown values cause parse errors

		if (def.allow_native_subagents && def.creatable_tasks.length > 0)
			errors ~= format("%s: allow_native_subagents and creatable_tasks are mutually exclusive", def.name);
	}

	// Check that requires_approval has stewards available
	foreach (ref def; types)
	{
		foreach (cname, ref cont; def.continuations)
		{
			if (cont.requires_approval && !hasSteward)
				errors ~= format("%s: continuation '%s' requires approval but no steward types defined",
					def.name, cname);
		}
	}

	// Worktree/commit reachability: for each type that declares worktree or
	// commit output, verify it is never reachable from a user-visible type
	// via a path where no edge along the way has worktree: true.
	// Types can inherit a worktree from their parent (via keep_context or
	// continuation edges), so we track the has_worktree state along each path.
	{
		// BFS state encoded as "typeName|0" (no worktree) or "typeName|1" (has worktree).
		// Predecessor info: how did we reach this state?
		struct Pred { string fromKey; string edgeLabel; }
		Pred[string] visited;
		string[] queue;

		void enqueue(string toType, bool toWt, string fromKey, string edgeLabel)
		{
			auto k = toType ~ "|" ~ (toWt ? "1" : "0");
			if (k !in visited)
			{
				visited[k] = Pred(fromKey, edgeLabel);
				queue ~= k;
			}
		}

		// Seed from all entry point types with hasWorktree from the entry point config.
		foreach (ref ep; entryPoints)
			enqueue(ep.resolvedType, ep.worktree != WorktreeMode.inherit, "", "");

		while (queue.length > 0)
		{
			auto curKey = queue[0];
			queue = queue[1 .. $];
			auto sep = curKey.length - 2; // "|0" or "|1" at end
			auto curType = curKey[0 .. sep];
			auto curWt = curKey[sep + 1] == '1';

			auto def = types.byName(curType);
			if (def is null)
				continue;

			foreach (ref edge; def.creatable_tasks)
				enqueue(edge.resolvedType, curWt || edge.worktree != WorktreeMode.inherit, curKey,
					format("creatable '%s'", edge.name));

			foreach (cname, ref cont; def.continuations)
				enqueue(cont.task_type, curWt || cont.worktree != WorktreeMode.inherit, curKey,
					format("continuation '%s'", cname));

			if (def.on_yield.task_type.length > 0)
				enqueue(def.on_yield.task_type, curWt || def.on_yield.worktree != WorktreeMode.inherit,
					curKey, "on_yield");
		}

		// Report types with worktree/commit output that can be reached without a worktree.
		foreach (ref def; types)
		{
			bool needsWorktree = def.output_type.canFind(OutputType.commit)
				|| def.output_type.canFind(OutputType.worktree);
			if (!needsWorktree)
				continue;

			auto badKey = def.name ~ "|0";
			if (badKey !in visited)
				continue;

			// Reconstruct path for the error message.
			string[] parts;
			auto k = badKey;
			while (k.length > 0)
			{
				auto pi = k in visited;
				if (pi is null)
					break;
				auto tn = k[0 .. k.length - 2];
				if (pi.fromKey.length == 0)
				{
					parts ~= tn;
					break;
				}
				parts ~= tn ~ " (via " ~ pi.edgeLabel ~ ")";
				k = pi.fromKey;
			}
			parts.reverse();
			errors ~= format("type '%s' declares worktree/commit output but is reachable "
				~ "without a worktree: %s", def.name, parts.join(" → "));
		}
	}

	// Interactive types must have empty output_type (they produce no structured output)
	{
		auto interactive = interactiveTypeSet(types, entryPoints);
		foreach (ref def; types)
		{
			if (def.name in interactive && def.output_type.length > 0)
				errors ~= format("%s: interactive type should have output_type: [] but has [%s]",
					def.name, def.output_type.map!(o => cast(string) o).join(", "));
		}
	}

	// Interactive session integrity: types reachable from entry point types
	// via keep_context must not have !keep_context continuations,
	// because a Handoff would complete the interactive task and orphan
	// the user's session.
	{
		auto interactive = interactiveTypeSet(types, entryPoints);

		// Check that interactive types only have keep_context continuations
		foreach (ref def; types)
		{
			if (def.name !in interactive)
				continue;
			foreach (cname, ref cont; def.continuations)
			{
				if (!cont.keep_context)
					errors ~= format("%s: continuation '%s' is !keep_context but '%s' is "
						~ "reachable from an entry point type via keep_context — "
						~ "Handoff would orphan the interactive session",
						def.name, cname, def.name);
			}
			if (def.on_yield.task_type.length > 0)
				errors ~= format("%s: on_yield is not allowed on interactive types "
					~ "(reachable from entry point via keep_context)", def.name);
		}
	}

	// Prompt template invariant:
	// - Entry points MUST have description and prompt_template
	// - Non-steward types MUST NOT have node-level prompt_template
	//   (prompt comes from the edge that spawns them)
	// - Edges to types without node-level prompt_template MUST carry prompt_template
	{
		// Validate entry points
		foreach (ref ep; entryPoints)
		{
			if (!ep.system && ep.description.length == 0)
				errors ~= format("entry_point '%s': missing required description", ep.name);
			if (ep.prompt_template.length == 0)
				errors ~= format("entry_point '%s': missing required prompt_template", ep.name);
			if (types.byName(ep.resolvedType) is null)
				errors ~= format("entry_point '%s': references unknown type '%s'", ep.name, ep.resolvedType);
			checkTemplateFile(format("entry_point '%s'", ep.name), ep.prompt_template);
		}

		foreach (ref def; types)
		{
			if (def.steward)
				continue;
			if (def.prompt_template.length > 0)
				errors ~= format("%s: non-steward type has node-level prompt_template"
					~ " — prompt should be on the edges or entry points that reference it", def.name);
		}

		// Every edge to a target without node-level prompt_template must carry prompt_template
		foreach (ref def; types)
		{
			foreach (ref edge; def.creatable_tasks)
			{
				auto target = types.byName(edge.resolvedType);
				if (target !is null && !target.steward && target.prompt_template.length == 0
					&& edge.prompt_template.length == 0)
					errors ~= format("%s: creatable_tasks '%s' targets type without node-level"
						~ " prompt_template but has no prompt_template", def.name, edge.name);
			}

			foreach (cname, ref cont; def.continuations)
			{
				if (cont.keep_context)
					continue;
				auto target = types.byName(cont.task_type);
				if (target !is null && !target.steward && target.prompt_template.length == 0
					&& cont.prompt_template.length == 0)
					errors ~= format("%s: continuation '%s' targets type '%s' without node-level"
						~ " prompt_template but has no prompt_template", def.name, cname, cont.task_type);
			}

			// on_yield is also a continuation edge
			if (def.on_yield.task_type.length > 0 && !def.on_yield.keep_context)
			{
				auto target = types.byName(def.on_yield.task_type);
				if (target !is null && !target.steward && target.prompt_template.length == 0
					&& def.on_yield.prompt_template.length == 0)
					errors ~= format("%s: on_yield targets type '%s' without node-level"
						~ " prompt_template but has no prompt_template", def.name, def.on_yield.task_type);
			}
		}
	}

	// Check for pure-continuation cycles (A→B→A with no modal break)
	foreach (ref def; types)
	{
		foreach (cname, ref cont; def.continuations)
		{
			if (auto cycle = detectCycle(types, cont.task_type, [def.name]))
				errors ~= format("%s: continuation '%s' creates cycle: %s",
					def.name, cname, cycle);
		}
	}

	// Check on_yield edges for cycles
	foreach (ref def; types)
	{
		if (def.on_yield.task_type.length > 0)
		{
			if (auto cycle = detectCycle(types, def.on_yield.task_type, [def.name]))
				errors ~= format("%s: on_yield creates cycle: %s", def.name, cycle);
		}
	}

	// Agent checks -------------------------------------------------------

	// 1. Literal-agent check: hardcoded values (no '{{') must name a configured agent.
	foreach (ref def; types)
	{
		if (!def.agent.dynamic && !isConfiguredAgentName(def.agent.source))
			errors ~= format("%s: agent '%s' is not a configured agent", def.name,
				def.agent.source);
	}

	// 2. keep_context cluster-agreement check (union-find on undirected edges).
	//    Hardcoded agent literals within the same cluster must agree.
	{
		string[string] ufParent;
		foreach (ref t; types)
			ufParent[t.name] = t.name;

		string ufFind(string x)
		{
			string root = x;
			while (ufParent[root] != root)
				root = ufParent[root];
			// path compression
			string cur = x;
			while (cur != root)
			{
				auto next = ufParent[cur];
				ufParent[cur] = root;
				cur = next;
			}
			return root;
		}

		void ufUnite(string a, string b)
		{
			auto ra = ufFind(a), rb = ufFind(b);
			if (ra != rb)
				ufParent[ra] = rb;
		}

		foreach (ref t; types)
		{
			foreach (_, ref cont; t.continuations)
				if (cont.keep_context && types.byName(cont.task_type) !is null)
					ufUnite(t.name, cont.task_type);
			if (t.on_yield.task_type.length > 0 && t.on_yield.keep_context
				&& types.byName(t.on_yield.task_type) !is null)
				ufUnite(t.name, t.on_yield.task_type);
		}

		// Group types by cluster root
		string[][string] clusterMembers;
		foreach (ref t; types)
			clusterMembers[ufFind(t.name)] ~= t.name;

		foreach (root, ref members; clusterMembers)
		{
			if (members.length < 2)
				continue;

			// Collect hardcoded agent values per member
			string[string] hardcodedAgents;
			foreach (m; members)
			{
				auto dp = types.byName(m);
				if (dp !is null && !dp.agent.dynamic)
					hardcodedAgents[m] = dp.agent.source;
			}

			// Check for disagreement
			bool[string] distinctVals;
			foreach (v; hardcodedAgents.values)
				distinctVals[v] = true;
			if (distinctVals.length <= 1)
				continue;

			sort(members);
			string[] disagreements;
			foreach (m; members)
				if (auto p = m in hardcodedAgents)
					disagreements ~= m ~ "='" ~ *p ~ "'";
			errors ~= format("keep_context cluster {%s}: hardcoded agent values disagree (%s)",
				members.join(", "), disagreements.join(", "));
		}
	}

	// 3. Root-bypass warning: entry point targets with non-default agent are ignored.
	foreach (ref ep; entryPoints)
	{
		auto targetDef = types.byName(ep.resolvedType);
		if (targetDef !is null && targetDef.agent.source != defaultAgentExpr)
			errors ~= format("entry_point '%s': target type '%s' has non-default agent '%s'"
				~ " which is ignored at root creation — set default_agent in config"
				~ " or move the override to a sub-task type",
				ep.name, ep.resolvedType, targetDef.agent.source);
	}

	return errors;
}

string[] validateTaskTypes(TaskTypeDef[] types, UserEntryPointDef[] entryPoints,
	SingletonDef[] singletons, bool function(string) isConfiguredAgentName,
	string[] typesDirs = null)
{
	return validateTaskTypes(types, entryPoints, singletons,
		(string name) => isConfiguredAgentName(name), typesDirs);
}

/// Compute which types are "tree-read-only": the type itself is read_only,
/// and every descendant reachable without a fork edge is also read_only.
/// A fork edge provides isolation, so the subtree behind it doesn't matter.
bool[string] computeTreeReadOnly(TaskTypeDef[] types)
{
	bool[string] cache;
	bool[string] inProgress;

	bool isTreeRO(string typeName)
	{
		if (auto p = typeName in cache)
			return *p;
		if (typeName in inProgress)
			return true; // optimistic for cycles of read_only types

		inProgress[typeName] = true;
		scope(exit) inProgress.remove(typeName);

		auto def = types.byName(typeName);
		if (def is null || !def.read_only)
		{
			cache[typeName] = false;
			return false;
		}

		foreach (ref edge; def.creatable_tasks)
			if (edge.worktree != WorktreeMode.fork && !isTreeRO(edge.resolvedType))
			{
				cache[typeName] = false;
				return false;
			}

		foreach (cname, ref cont; def.continuations)
			if (cont.worktree != WorktreeMode.fork && !isTreeRO(cont.task_type))
			{
				cache[typeName] = false;
				return false;
			}

		if (def.on_yield.task_type.length > 0)
			if (def.on_yield.worktree != WorktreeMode.fork && !isTreeRO(def.on_yield.task_type))
			{
				cache[typeName] = false;
				return false;
			}

		cache[typeName] = true;
		return true;
	}

	foreach (ref def; types)
		isTreeRO(def.name);

	return cache;
}

/// Compute which task types can transitively reach a worktree (require or fork)
/// via any edge (creatable_tasks, continuations, on_yield). Types that reach a
/// worktree need writable git dirs in their sandbox so they can integrate
/// worktree results (cherry-pick, merge).
bool[string] computeReachesWorktree(TaskTypeDef[] types)
{
	bool[string] cache;
	bool[string] inProgress;

	bool reaches(string typeName)
	{
		if (auto p = typeName in cache)
			return *p;
		if (typeName in inProgress)
			return false; // pessimistic for cycles

		inProgress[typeName] = true;
		scope(exit) inProgress.remove(typeName);

		auto def = types.byName(typeName);
		if (def is null)
		{
			cache[typeName] = false;
			return false;
		}

		foreach (ref edge; def.creatable_tasks)
			if (edge.worktree != WorktreeMode.inherit || reaches(edge.resolvedType))
			{
				cache[typeName] = true;
				return true;
			}

		foreach (cname, ref cont; def.continuations)
			if (cont.worktree != WorktreeMode.inherit || reaches(cont.task_type))
			{
				cache[typeName] = true;
				return true;
			}

		if (def.on_yield.task_type.length > 0)
			if (def.on_yield.worktree != WorktreeMode.inherit || reaches(def.on_yield.task_type))
			{
				cache[typeName] = true;
				return true;
			}

		cache[typeName] = false;
		return false;
	}

	foreach (ref def; types)
		reaches(def.name);

	return cache;
}

/// Detect unconditional cycles in continuation chains.
/// A cycle is only problematic if every type in the loop has exactly one
/// continuation (no agent decision). Types with multiple continuations
/// represent decision points where the agent chooses — these break cycles.
private string detectCycle(TaskTypeDef[] types, string current, string[] visited)
{
	if (visited.canFind(current))
	{
		// Check if any type in the cycle has multiple continuations
		// (a decision point that makes the cycle conditional)
		foreach (name; visited)
		{
			auto d = types.byName(name);
			if (d !is null && d.continuations.length > 1)
				return null; // conditional cycle, OK
		}
		return visited.join(" → ") ~ " → " ~ current;
	}

	auto def = types.byName(current);
	if (def is null)
		return null;

	foreach (_, ref cont; def.continuations)
	{
		if (auto cycle = detectCycle(types, cont.task_type, visited ~ current))
			return cycle;
	}
	if (def.on_yield.task_type.length > 0)
	{
		if (auto cycle = detectCycle(types, def.on_yield.task_type, visited ~ current))
			return cycle;
	}
	return null;
}

// ---------------------------------------------------------------------------
// Prompt Rendering
// ---------------------------------------------------------------------------

/// The source of the prompt template `name`: the file from the first
/// directory of `dirs` that has it, or null if none does. A `{{ default }}`
/// in it stands for the source of the same template further down `dirs`, so
/// that an override can extend what it overrides instead of replacing it.
string promptTemplateSource(const(string)[] dirs, string name)
{
	import std.file : exists, readText;
	import std.path : buildPath;
	import std.regex : ctRegex, matchFirst, replaceAll;

	foreach (i, dir; dirs)
	{
		auto path = buildPath(dir, name);
		if (!exists(path))
			continue;
		auto source = readText(path);
		static immutable defaultPlaceholder = ctRegex!`\{\{\s*default\s*\}\}`;
		if (source.matchFirst(defaultPlaceholder).empty)
			return source;
		auto overridden = promptTemplateSource(dirs[i + 1 .. $], name);
		enforce(overridden !is null, format(
			"%s extends {{ default }}, but nothing further down the prompt search path has '%s'",
			path, name));
		return source.replaceAll!(m => overridden)(defaultPlaceholder);
	}
	return null;
}

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto root = buildPath(tempDir, "cydo-test-prompt-template-source");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	auto project = buildPath(root, "project");
	auto user = buildPath(root, "user");
	auto shipped = buildPath(root, "shipped");
	foreach (dir; [project, user, shipped])
		mkdirRecurse(buildPath(dir, "prompts"));
	auto dirs = [project, user, shipped];

	write(buildPath(shipped, "prompts/a.md"), "shipped {{x}}");
	assert(promptTemplateSource(dirs, "prompts/a.md") == "shipped {{x}}");
	assert(promptTemplateSource(dirs, "prompts/missing.md") is null);

	// An override replaces what it overrides ...
	write(buildPath(user, "prompts/a.md"), "user");
	assert(promptTemplateSource(dirs, "prompts/a.md") == "user");
	// ... unless it extends it, at every level.
	write(buildPath(user, "prompts/a.md"), "{{ default }}\nuser");
	write(buildPath(project, "prompts/a.md"), "project\n{{default}}");
	assert(promptTemplateSource(dirs, "prompts/a.md") == "project\nshipped {{x}}\nuser");

	write(buildPath(user, "prompts/b.md"), "{{ default }}");
	assertThrown(promptTemplateSource(dirs, "prompts/b.md"));
}

/// `read_file(path)` in a prompt template: the text of a file outside the
/// prompt search path, as it is (it is not itself a template). `path` is
/// absolute or starts with `~`.
private string readFileForTemplate(string path)
{
	import std.file : readText;
	import std.path : expandTilde, isAbsolute;

	auto expanded = expandTilde(path);
	enforce(expanded.isAbsolute, format(
		"read_file(\"%s\"): the path must be absolute or start with ~", path));
	return readText(expanded);
}

/// Render a prompt template: `{{key}}` placeholders take their values from
/// the given map, and `{{ read_file("path") }}` is the text of that file.
string substituteVars(string text, string[string] vars)
{
	import djinja.djinja : loadData, JinjaConfig;
	import djinja.render : Render, registerFunction;
	import uninode.serialization : serialize = serializeToUniNode;

    enum JinjaConfig conf = { cmntOpInline: "$$", stmtOpInline: "$$$" };
	auto tmpl = loadData!conf(text);
	auto renderer = new Render(tmpl);
	renderer.registerFunction!readFileForTemplate("read_file");
	return renderer.render(serialize(vars));
}

unittest
{
	import std.exception : assertThrown;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;

	auto path = buildPath(tempDir, "cydo-test-read-file-for-template.md");
	write(path, "literal {{not_a_var}}\n");
	scope(exit) remove(path);

	assert(substituteVars("a {{x}}\n{{ read_file(path) }}b", ["x": "1", "path": path])
		== "a 1\nliteral {{not_a_var}}\nb");
	assertThrown(substituteVars(`{{ read_file("relative.md") }}`, null));
	assertThrown(substituteVars(`{{ read_file("/nonexistent/cydo-test.md") }}`, null));
}

/// Render a prompt template by reading the template file and substituting
/// placeholders. Returns the raw description if no template is defined.
string renderPrompt(ref TaskTypeDef def, string description, string[] typesDirs,
	string outputFile = "", string edgeTemplate = "", string[string] extraVars = null)
{
	import std.path : dirName;

	auto templateName = edgeTemplate.length > 0 ? edgeTemplate : def.prompt_template;
	if (templateName.length == 0)
		return description;

	auto templateText = promptTemplateSource(typesDirs, templateName);
	if (templateText is null)
		return description;

	string[string] vars;
	vars["task_description"] = description;
	if (def.knowledge_base.length > 0)
		vars["knowledge_base"] = def.knowledge_base;
	if (outputFile.length > 0)
	{
		vars["output_file"] = outputFile;
		vars["output_dir"] = dirName(outputFile);
	}
	foreach (k, v; extraVars)
		vars[k] = v;
	return substituteVars(templateText, vars);
}

/// Load and render a system prompt template from disk. Returns null if the
/// type has no system_prompt_template or the role prompt file does not exist.
/// Wraps the role prompt in system_prompts/master.md and substitutes
/// {{output_file}}, {{output_dir}}, {{knowledge_base}}, and extraVars.
string loadSystemPrompt(ref TaskTypeDef def, string[] typesDirs,
	string outputFile = "", string[string] extraVars = null)
{
	import std.path : buildPath, dirName;

	if (def.system_prompt_template.length == 0 || typesDirs.length == 0)
		return null;
	auto rolePromptText = promptTemplateSource(typesDirs, def.system_prompt_template);
	if (rolePromptText is null)
		return null;
	if ("generated_guidance" !in extraVars)
		throw new Exception(format(
			"Task type '%s' requires generated_guidance when loading a system prompt.",
			def.name));
	string[string] vars;
	if (def.knowledge_base.length > 0)
		vars["knowledge_base"] = def.knowledge_base;
	if (outputFile.length > 0)
	{
		vars["output_file"] = outputFile;
		vars["output_dir"] = dirName(outputFile);
	}
	foreach (k, v; extraVars)
		vars[k] = v;
	auto rolePrompt = substituteVars(rolePromptText, vars);

	auto masterText = promptTemplateSource(typesDirs, "system_prompts/master.md");
	enforce(masterText !is null, format(
		"Task type '%s' could not resolve system prompt master template. Searched: %s",
		def.name, typesDirs.map!(dir => buildPath(dir, "system_prompts/master.md")).join(", ")));

	vars["role_prompt"] = rolePrompt;
	return substituteVars(masterText, vars);
}

/// Read the project's MEMORY.md and wrap it in a preamble block.
/// Returns null when def is null, def.memory is false, or projectPath is empty.
/// Creates MEMORY.md on demand if missing. An empty or whitespace-only file
/// renders as the placeholder "(Memory is currently empty.)".
/// Re-reads from disk on every call — supports mid-session memory updates.
string loadProjectMemory(TaskTypeDef* def, string projectPath, string[] typesDirs)
{
	import std.file : exists, mkdirRecurse, readText;
	import std.file : write;
	import std.path : buildPath;

	if (def is null || !def.memory)
		return null;
	if (projectPath.length == 0)
		return null;

	auto memoryDir = buildPath(projectPath, ".cydo", "memory");
	auto memoryFile = buildPath(memoryDir, "MEMORY.md");
	mkdirRecurse(memoryDir);
	if (!exists(memoryFile))
		write(memoryFile, "");

	auto raw = readText(memoryFile);
	auto contents = raw.strip.length == 0
		? "(Memory is currently empty.)"
		: raw;

	auto preamble = promptTemplateSource(typesDirs, "system_prompts/memory_preamble.md");
	if (preamble is null)
		return "[CYDO PROJECT MEMORY]\n" ~ contents ~ "\n[/CYDO PROJECT MEMORY]\n";

	return substituteVars(preamble, [
		"memory_dir": memoryDir,
		"memory_contents": contents,
	]);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto tmp = "/tmp/cydo-test-loadprojectmemory";
	scope (exit) { if (exists(tmp)) rmdirRecurse(tmp); }
	mkdirRecurse(tmp);

	TaskTypeDef defOn;
	defOn.memory = true;
	TaskTypeDef defOff;
	defOff.memory = false;

	// null def → null
	assert(loadProjectMemory(null, tmp, []) is null);
	// def.memory false → null
	assert(loadProjectMemory(&defOff, tmp, []) is null);
	// projectPath empty → null
	assert(loadProjectMemory(&defOn, "", []) is null);

	// MEMORY.md absent → created on demand, placeholder injected
	auto memDir = buildPath(tmp, ".cydo", "memory");
	auto memFile = buildPath(memDir, "MEMORY.md");
	assert(!exists(memFile));
	auto absent = loadProjectMemory(&defOn, tmp, []);
	assert(absent !is null);
	assert(exists(memFile)); // file was created
	assert(absent.canFind("[CYDO PROJECT MEMORY]"), absent);
	assert(absent.canFind("(Memory is currently empty.)"), absent);

	// MEMORY.md empty → placeholder
	write(memFile, "");
	auto empty = loadProjectMemory(&defOn, tmp, []);
	assert(empty.canFind("(Memory is currently empty.)"), empty);

	// MEMORY.md whitespace-only → placeholder
	write(memFile, "   \n  ");
	auto ws = loadProjectMemory(&defOn, tmp, []);
	assert(ws.canFind("(Memory is currently empty.)"), ws);

	// MEMORY.md non-empty → verbatim contents
	write(memFile, "- entry one\n");
	auto result = loadProjectMemory(&defOn, tmp, []);
	assert(result !is null);
	assert(result.canFind("[CYDO PROJECT MEMORY]"), result);
	assert(result.canFind("entry one"), result);
	assert(result.canFind("[/CYDO PROJECT MEMORY]"), result);

	// with preamble template → substitution
	auto defsDir = buildPath(tmp, "defs");
	mkdirRecurse(buildPath(defsDir, "system_prompts"));
	write(buildPath(defsDir, "system_prompts", "memory_preamble.md"),
		"{{memory_dir}}\n---\n{{memory_contents}}");
	auto withPreamble = loadProjectMemory(&defOn, tmp, [defsDir]);
	assert(withPreamble.canFind(memDir), withPreamble);
	assert(withPreamble.canFind("entry one"), withPreamble);
}

// ---------------------------------------------------------------------------
// Agent field unit tests
// ---------------------------------------------------------------------------

version (unittest) private bool isKnownTestAgent(string name)
{
	return ["claude", "codex", "copilot"].canFind(name);
}

version (unittest) private bool isConfiguredCustomTestAgent(string name)
{
	return name == "work-claude";
}

version (unittest) private bool rejectAllTestAgents(string name)
{
	return false;
}

unittest // 1. loadTaskTypes injects defaultAgentExpr when no agent: field is present
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto tmp = "/tmp/cydo-test-agent-default-inject";
	scope (exit) { if (exists(tmp)) rmdirRecurse(tmp); }
	mkdirRecurse(tmp);

	auto yamlPath = buildPath(tmp, "task-types.yaml");
	write(yamlPath, "task_types:\n  foo:\n    model_class: large\n");

	auto config = loadTaskTypes(yamlPath);

	auto foo = config.types.byName("foo");
	assert(foo !is null);
	assert(foo.agent.source == defaultAgentExpr, foo.agent.source);

	auto blank = config.types.byName("blank");
	assert(blank !is null);
	assert(blank.agent.source == defaultAgentExpr, blank.agent.source);
}

unittest // 2. resolveAgent substitutes parent_agent_type correctly
{
	assert(resolveAgent(DjinjaTemplate(defaultAgentExpr), "claude") == "claude");
	assert(resolveAgent(DjinjaTemplate(defaultAgentExpr), "") == "");
	assert(resolveAgent(DjinjaTemplate("codex"), "claude") == "codex");
	assert(resolveAgent(DjinjaTemplate("{{ workspace }}-{{ parent_agent_type }}"),
		"codex", "work")
		== "work-codex");
	assert(resolveModelClass(DjinjaTemplate(
		"{{ 'best' if agent == 'claude-personal' else 'large' }}"),
		"work", "claude-personal") == "best");
	assert(resolveModelClass(DjinjaTemplate(
		"{{ 'best' if agent == 'claude-personal' else 'large' }}"),
		"work", "codex") == "large");
}

unittest // 3. Validator emits error for unconfigured hardcoded literal
{
	TaskTypeDef t;
	t.name = "foo";
	t.model_class = "large";
	t.agent = "codeex"; // typo

	auto errors = validateTaskTypes([t], [], [], &isKnownTestAgent);
	assert(errors.canFind("foo: agent 'codeex' is not a configured agent"), errors.to!string);
}

unittest // 3b. Validator accepts configured custom agent names and rejects raw drivers
{
	TaskTypeDef custom;
	custom.name = "custom";
	custom.model_class = "large";
	custom.agent = "work-claude";

	auto errors = validateTaskTypes([custom], [], [], &isConfiguredCustomTestAgent);
	assert(!errors.canFind("custom: agent 'work-claude' is not a configured agent"),
		errors.to!string);

	TaskTypeDef driver;
	driver.name = "driver";
	driver.model_class = "large";
	driver.agent = "claude";

	errors = validateTaskTypes([driver], [], [], &isConfiguredCustomTestAgent);
	assert(errors.canFind("driver: agent 'claude' is not a configured agent"),
		errors.to!string);
}

unittest // 26. Validator accepts an open-ended model_class label
{
	TaskTypeDef t;
	t.name = "foo";
	t.model_class = "best";
	t.agent = "claude";

	auto errors = validateTaskTypes([t], [], [], &isKnownTestAgent);
	assert(errors.length == 0, errors.to!string);
}

unittest // 4. Validator errors on keep_context cluster with disagreeing hardcoded agents (with entry points)
{
	TaskTypeDef triage;
	triage.name = "triage";
	triage.model_class = "large";
	triage.agent = "claude";
	ContinuationDef cont;
	cont.task_type = "implement";
	cont.keep_context = true;
	cont.prompt_template = "switch.md"; // prevent prompt_template error
	triage.continuations["go"] = cont;

	TaskTypeDef implement;
	implement.name = "implement";
	implement.model_class = "large";
	implement.agent = "codex";

	UserEntryPointDef ep;
	ep.name = "start";
	ep.task_type = "triage";
	ep.description = "Start triage";
	ep.prompt_template = "start.md";

	auto errors = validateTaskTypes([triage, implement], [ep], [], &isKnownTestAgent);
	import std.algorithm : any;
	assert(errors.any!(e => e.canFind("keep_context cluster")
		&& e.canFind("triage") && e.canFind("implement")), errors.to!string);
}

unittest // 5. Validator enforces keep_context cluster even without any entry points reaching it
{
	TaskTypeDef a;
	a.name = "atype";
	a.model_class = "large";
	a.agent = "claude";
	ContinuationDef cont;
	cont.task_type = "btype";
	cont.keep_context = true;
	cont.prompt_template = "switch.md";
	a.continuations["go"] = cont;

	TaskTypeDef b;
	b.name = "btype";
	b.model_class = "large";
	b.agent = "codex";

	// Separate type targeted by entry point — not in the cluster
	TaskTypeDef root;
	root.name = "root";
	root.model_class = "large";
	root.agent = defaultAgentExpr;

	UserEntryPointDef ep;
	ep.name = "start";
	ep.task_type = "root";
	ep.description = "Start";
	ep.prompt_template = "start.md";

	auto errors = validateTaskTypes([a, b, root], [ep], [], &isKnownTestAgent);
	import std.algorithm : any;
	assert(errors.any!(e => e.canFind("keep_context cluster")
		&& e.canFind("atype") && e.canFind("btype")), errors.to!string);
}

unittest // 6. Validator allows {{ parent_agent_type }} / defaultAgentExpr even when predicate rejects the raw string
{
	TaskTypeDef implement;
	implement.name = "implement";
	implement.model_class = "large";
	implement.agent = defaultAgentExpr; // dynamic — not hardcoded

	auto errors = validateTaskTypes([implement], [], [], &rejectAllTestAgents);
	assert(!errors.canFind("implement: agent '{{ parent_agent_type }}' is not a configured agent"),
		errors.to!string);
}

unittest // 7. Validator errors when on_yield keep_context connects disagreeing hardcoded agents
{
	TaskTypeDef a;
	a.name = "atype";
	a.model_class = "large";
	a.agent = "claude";
	ContinuationDef oyield;
	oyield.task_type = "btype";
	oyield.keep_context = true;
	oyield.prompt_template = "switch.md";
	a.on_yield = oyield;

	TaskTypeDef b;
	b.name = "btype";
	b.model_class = "large";
	b.agent = "codex";

	auto errors = validateTaskTypes([a, b], [], [], &isKnownTestAgent);
	import std.algorithm : any;
	assert(errors.any!(e => e.canFind("keep_context cluster")
		&& e.canFind("atype") && e.canFind("btype")), errors.to!string);
}

unittest
{
	auto types = [TaskTypeDef(name: "integrator")];
	auto singletons = [SingletonDef(name: "integrate", task_type: "integrator",
		description: "  ")];

	auto warnings = validateTaskTypes(types, [], singletons, &isKnownTestAgent);
	assert(warnings.canFind("singleton 'integrate' has no description"));

	singletons[0].description = "Integrate changes.";
	warnings = validateTaskTypes(types, [], singletons, &isKnownTestAgent);
	assert(!warnings.canFind("singleton 'integrate' has no description"));
}

unittest // 8. Validator warns when entry point target has non-default agent (root creation ignores it)
{
	TaskTypeDef triage;
	triage.name = "triage";
	triage.model_class = "large";
	triage.agent = "codex";

	UserEntryPointDef ep;
	ep.name = "start";
	ep.task_type = "triage";
	ep.description = "Start";
	ep.prompt_template = "start.md";

	auto errors = validateTaskTypes([triage], [ep], [], &isKnownTestAgent);
	import std.algorithm : any;
	assert(errors.any!(e => e.canFind("entry_point") && e.canFind("start")
		&& e.canFind("triage") && e.canFind("ignored at root creation")), errors.to!string);
}

/// Render a continuation's prompt template. The continuation must have a
/// prompt_template set (enforced by validation for keep_context continuations).
string renderContinuationPrompt(ref ContinuationDef contDef, string fallback, string[] typesDirs,
	string[string] extraVars = null)
{
	if (contDef.prompt_template.length == 0)
		return fallback;

	auto text = promptTemplateSource(typesDirs, contDef.prompt_template);
	assert(text !is null, "Continuation prompt template not found: " ~ contDef.prompt_template);

	if (extraVars.length > 0)
		text = substituteVars(text, extraVars);
	return text;
}

/// Get description for an edge: edge description, then first line of target's
/// agent_description, then target's name.
private string edgeDesc(string contDesc, TaskTypeDef* targetDef)
{
	if (contDesc.length > 0) return contDesc;
	if (targetDef !is null && targetDef.agent_description.length > 0)
		return targetDef.agent_description.strip.lineSplitter.front.to!string;
	return targetDef !is null ? targetDef.name : "";
}

private enum compactToolGuidanceNote = "Refer to the session instructions for when to use each.";

private string formatCompactIdToolSummary(string[] ids)
{
	if (ids.length == 0)
		return null;

	string result;
	foreach (id; ids)
		result ~= format("- %s\n", id);
	result ~= "\n" ~ compactToolGuidanceNote;
	return result;
}

private void appendDetailedGuidanceEntry(ref string result, string heading,
	string id, string targetType, string description, TaskTypeDef* targetDef)
{
	result ~= format("### %s `%s`\n", heading, id);
	if (targetType.length > 0)
		result ~= format("Target task type: `%s`\n", targetType);
	if (description.length > 0)
		result ~= "When to use it: " ~ description ~ "\n";
	if (targetDef !is null && targetDef.agent_description.length > 0)
		result ~= "\n" ~ targetDef.agent_description.strip ~ "\n";
	if (targetDef !is null && targetDef.tool_guidance.length > 0)
		result ~= "\nTool guidance:\n" ~ targetDef.tool_guidance.strip ~ "\n";
	result ~= "\n";
}

/// Format an IDs-only summary of keep_context continuations for a task type.
/// Used to fill the {{switchmodes}} placeholder in the SwitchMode tool description.
string formatCompactSwitchModeToolSummary(TaskTypeDef[] allTypes, string typeName)
{
	auto def = allTypes.byName(typeName);
	if (def is null || def.continuations.length == 0)
		return null;

	string[] ids;
	foreach (cname, ref cont; def.continuations)
	{
		if (cont.keep_context)
			ids ~= cname;
	}
	return formatCompactIdToolSummary(ids);
}

/// Format an IDs-only summary of !keep_context continuations for a task type.
/// Used to fill the {{handoffs}} placeholder in the Handoff tool description.
string formatCompactHandoffToolSummary(TaskTypeDef[] allTypes, string typeName)
{
	auto def = allTypes.byName(typeName);
	if (def is null || def.continuations.length == 0)
		return null;

	string[] ids;
	foreach (cname, ref cont; def.continuations)
	{
		if (!cont.keep_context)
			ids ~= cname;
	}
	return formatCompactIdToolSummary(ids);
}

/// Format an IDs-only summary of available child task edges for a parent type.
/// Used to fill the {{creatable_task_types}} placeholder in MCP tool descriptions.
string formatCompactCreatableTaskTypeToolSummary(TaskTypeDef[] allTypes,
	string parentTypeName)
{
	auto parentDef = allTypes.byName(parentTypeName);
	if (parentDef is null || parentDef.creatable_tasks.length == 0)
		return null;

	string[] ids;
	foreach (ref edge; parentDef.creatable_tasks)
		ids ~= edge.name;
	return formatCompactIdToolSummary(ids);
}

private enum string createSubTasksPolicy =
	"Every child starts a fresh session and does not inherit this conversation or "
	~ "any other task's conversation. Make each Task prompt self-contained with all "
	~ "necessary context, including requirements, relevant findings and artifact paths, "
	~ "constraints, and completion criteria.\n\n"
	~ "Do not redo or reassign work already covered by a live child; give intentionally "
	~ "overlapping children distinct purposes. Use child results without repeating their "
	~ "work by default; review or independently verify them when the workflow, uncertainty, "
	~ "or risk warrants it.\n\n";

/// Build the full task/mode/handoff guidance injected into session instructions.
string formatGeneratedTaskGuidance(TaskTypeDef[] allTypes, string typeName,
	SingletonDef[] singletons = null)
{
	auto def = allTypes.byName(typeName);
	if (def is null)
		return "";

	string result;
	if (def.creatable_tasks.length > 0)
	{
		result ~= "## Create Sub-Tasks\n\n" ~ createSubTasksPolicy;
		foreach (ref edge; def.creatable_tasks)
		{
			auto targetDef = allTypes.byName(edge.resolvedType);
			if (targetDef is null)
				continue;
			appendDetailedGuidanceEntry(result, "Task", edge.name,
				edge.resolvedType, edgeDesc(edge.description, targetDef), targetDef);
		}
	}

	if (singletons.length > 0)
	{
		result ~= "## Singletons\n\n";
		foreach (ref singleton; singletons)
			result ~= "### " ~ singleton.name ~ "\n\n" ~ singleton.description.strip ~ "\n\n";
	}

	if (def.continuations.length > 0)
	{
		string switchModes;
		string handoffs;
		foreach (cname, ref cont; def.continuations)
		{
			auto targetDef = allTypes.byName(cont.task_type);
			auto desc = edgeDesc(cont.description, targetDef);
			if (cont.keep_context)
				appendDetailedGuidanceEntry(switchModes, "Mode", cname,
					cont.task_type, desc, targetDef);
			else
				appendDetailedGuidanceEntry(handoffs, "Handoff", cname,
					cont.task_type, desc, targetDef);
		}
		if (switchModes.length > 0)
			result ~= "## Switch Modes\n\n" ~ switchModes;
		if (handoffs.length > 0)
			result ~= "## Handoffs\n\n" ~ handoffs;
	}

	return result.strip.length > 0 ? result.strip ~ "\n" : "";
}

unittest
{
	TaskTypeDef task;
	task.name = "isolated";
	auto types = [task];
	auto offered = [
		SingletonDef("integrate", "integrator", "", "", SingletonAudience.all,
			"Integrate changes.\nReport the resulting commit."),
		SingletonDef("review", "reviewer", "", "", SingletonAudience.all,
			"Review changes.\nReport actionable findings."),
	];

	assert(formatGeneratedTaskGuidance(types, task.name, offered)
		== "## Singletons\n\n"
		~ "### integrate\n\nIntegrate changes.\nReport the resulting commit.\n\n"
		~ "### review\n\nReview changes.\nReport actionable findings.\n");
	assert(formatGeneratedTaskGuidance(types, task.name, []) == "");
}

/// Build the generated vars required by loadSystemPrompt() for task guidance.
string[string] buildTaskGuidancePromptVars(TaskTypeDef[] allTypes, string typeName,
	SingletonDef[] singletons)
{
	return ["generated_guidance": formatGeneratedTaskGuidance(allTypes, typeName, singletons)];
}

/// Load a task type system prompt with generated task/mode/handoff guidance.
string loadTaskTypeSystemPrompt(ref TaskTypeDef def, TaskTypeDef[] allTypes,
	string typeName, string[] typesDirs, string outputFile = "",
	string[string] extraVars = null, SingletonDef[] singletons = null)
{
	auto vars = buildTaskGuidancePromptVars(allTypes, typeName, singletons);
	foreach (k, v; extraVars)
		vars[k] = v;
	return loadSystemPrompt(def, typesDirs, outputFile, vars);
}

unittest
{
	TaskTypeDef parent;
	parent.name = "parent";
	parent.creatable_tasks = [
		CreatableTaskDef("execute", "implement", WorktreeMode.inherit, "", "",
			"Implement the requested change."),
	];
	parent.continuations = [
		"switch": ContinuationDef("review", false, true, WorktreeMode.inherit, "",
			"Continue in the same session."),
		"handoff": ContinuationDef("verify", false, false, WorktreeMode.inherit, "",
			"Start verification in a fresh session."),
	];

	TaskTypeDef implement;
	implement.name = "implement";
	implement.agent_description = "Write the code change.";
	implement.tool_guidance = "Edit files and return a clean diff.";

	TaskTypeDef review;
	review.name = "review";
	review.agent_description = "Review the implementation carefully.";
	review.tool_guidance = "Focus on defects first.";

	TaskTypeDef verify;
	verify.name = "verify";
	verify.agent_description = "Run the verification steps.";
	verify.tool_guidance = "Report failures precisely.";

	auto types = [parent, implement, review, verify];

	auto creatable = formatCompactCreatableTaskTypeToolSummary(types, "parent");
	assert(creatable == "- execute\n\n" ~ compactToolGuidanceNote, creatable);
	assert(!creatable.canFind("Write the code change."), creatable);
	assert(!creatable.canFind("Edit files and return a clean diff."), creatable);

	auto switchModes = formatCompactSwitchModeToolSummary(types, "parent");
	assert(switchModes == "- switch\n\n" ~ compactToolGuidanceNote, switchModes);
	assert(!switchModes.canFind("Review the implementation carefully."), switchModes);
	assert(!switchModes.canFind("Focus on defects first."), switchModes);

	auto handoffs = formatCompactHandoffToolSummary(types, "parent");
	assert(handoffs == "- handoff\n\n" ~ compactToolGuidanceNote, handoffs);
	assert(!handoffs.canFind("Run the verification steps."), handoffs);
	assert(!handoffs.canFind("Report failures precisely."), handoffs);
}

unittest
{
	enum createSubTasksHeading = "## Create Sub-Tasks\n\n";
	auto expectedCreateSubTasksPolicy =
		"Every child starts a fresh session and does not inherit this conversation or "
		~ "any other task's conversation. Make each Task prompt self-contained with all "
		~ "necessary context, including requirements, relevant findings and artifact paths, "
		~ "constraints, and completion criteria.\n\n"
		~ "Do not redo or reassign work already covered by a live child; give intentionally "
		~ "overlapping children distinct purposes. Use child results without repeating their "
		~ "work by default; review or independently verify them when the workflow, uncertainty, "
		~ "or risk warrants it.\n\n";

	TaskTypeDef parent;
	parent.name = "parent";
	parent.creatable_tasks = [
		CreatableTaskDef("execute", "implement", WorktreeMode.inherit, "", "",
			"Implement the requested change."),
	];
	parent.continuations = [
		"switch": ContinuationDef("review", false, true, WorktreeMode.inherit, "",
			"Continue in the same session."),
		"handoff": ContinuationDef("verify", false, false, WorktreeMode.inherit, "",
			"Start verification in a fresh session."),
	];

	TaskTypeDef implement;
	implement.name = "implement";
	implement.agent_description = "Write the code change.";
	implement.tool_guidance = "Edit files and return a clean diff.";

	TaskTypeDef review;
	review.name = "review";
	review.agent_description = "Review the implementation carefully.";
	review.tool_guidance = "Focus on defects first.";

	TaskTypeDef verify;
	verify.name = "verify";
	verify.agent_description = "Run the verification steps.";
	verify.tool_guidance = "Report failures precisely.";

	TaskTypeDef sparseParent;
	sparseParent.name = "sparse-parent";
	sparseParent.creatable_tasks = [
		CreatableTaskDef("bare", "sparse-child", WorktreeMode.inherit, "", "", ""),
	];

	TaskTypeDef sparseChild;
	sparseChild.name = "sparse-child";

	TaskTypeDef continuationOnly;
	continuationOnly.name = "continuation-only";
	continuationOnly.continuations = [
		"continue": ContinuationDef("continuation-target", false, true,
			WorktreeMode.inherit, "", ""),
	];

	TaskTypeDef continuationTarget;
	continuationTarget.name = "continuation-target";

	TaskTypeDef noOutgoing;
	noOutgoing.name = "no-outgoing";

	auto types = [parent, implement, review, verify, sparseParent, sparseChild,
		continuationOnly, continuationTarget, noOutgoing];
	foreach (ref def; types)
	{
		if (def.creatable_tasks.length == 0)
			continue;

		auto generated = formatGeneratedTaskGuidance(types, def.name);
		auto expectedSectionStart = createSubTasksHeading
			~ expectedCreateSubTasksPolicy ~ "### Task";
		assert(generated.length >= expectedSectionStart.length, generated);
		assert(generated[0 .. expectedSectionStart.length] == expectedSectionStart,
			generated);

		auto renderedPolicy = generated[createSubTasksHeading.length ..
			createSubTasksHeading.length + expectedCreateSubTasksPolicy.length];
		assert(renderedPolicy == expectedCreateSubTasksPolicy, generated);
		assert(!renderedPolicy.canFind("If the harness restarts"), renderedPolicy);
		assert(!renderedPolicy.canFind("Accepted multi-task batches"), renderedPolicy);
		assert(!renderedPolicy.canFind("After this session exits"), renderedPolicy);
	}

	auto guidance = formatGeneratedTaskGuidance(types, "parent");
	assert(guidance.canFind("## Create Sub-Tasks"), guidance);
	assert(guidance.canFind("### Task `execute`"), guidance);
	assert(guidance.canFind("Target task type: `implement`"), guidance);
	assert(guidance.canFind("Write the code change."), guidance);
	assert(guidance.canFind("Edit files and return a clean diff."), guidance);
	assert(guidance.canFind("## Switch Modes"), guidance);
	assert(guidance.canFind("### Mode `switch`"), guidance);
	assert(guidance.canFind("Review the implementation carefully."), guidance);
	assert(guidance.canFind("Focus on defects first."), guidance);
	assert(guidance.canFind("## Handoffs"), guidance);
	assert(guidance.canFind("### Handoff `handoff`"), guidance);
	assert(guidance.canFind("Run the verification steps."), guidance);
	assert(guidance.canFind("Report failures precisely."), guidance);

	auto sparseGuidance = formatGeneratedTaskGuidance(types, "sparse-parent");
	assert(sparseGuidance.canFind("### Task `bare`"), sparseGuidance);
	assert(sparseGuidance.canFind("Target task type: `sparse-child`"), sparseGuidance);

	auto continuationGuidance = formatGeneratedTaskGuidance(types, "continuation-only");
	assert(continuationGuidance.canFind("## Switch Modes"), continuationGuidance);
	assert(continuationGuidance.canFind("### Mode `continue`"), continuationGuidance);
	assert(!continuationGuidance.canFind("## Create Sub-Tasks"), continuationGuidance);
	assert(!continuationGuidance.canFind("## Handoffs"), continuationGuidance);

	assert(formatGeneratedTaskGuidance(types, "no-outgoing") == "");
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto tmp = "/tmp/cydo-test-loadsystemprompt-master";
	scope (exit) { if (exists(tmp)) rmdirRecurse(tmp); }
	mkdirRecurse(buildPath(tmp, "system_prompts"));

	write(buildPath(tmp, "system_prompts", "role.md"),
		"Role prompt {{custom}} {{knowledge_base}} {{output_file}}");
	write(buildPath(tmp, "system_prompts", "master.md"),
		"MASTER\n{{role_prompt}}\nGUIDE\n{{generated_guidance}}\nDIR {{output_dir}}");

	TaskTypeDef def;
	def.name = "implement";
	def.system_prompt_template = "system_prompts/role.md";
	def.knowledge_base = "kb/path";

	TaskTypeDef parent;
	parent.name = "parent";
	parent.creatable_tasks = [
		CreatableTaskDef("execute", "implement", WorktreeMode.inherit, "", "",
			"Implement the requested change."),
	];

	auto rendered = loadTaskTypeSystemPrompt(def, [parent, def], "parent", [tmp],
		buildPath(tmp, "out", "result.md"), ["custom": "value"]);
	assert(rendered.canFind("MASTER"), rendered);
	assert(rendered.canFind("Role prompt value kb/path"), rendered);
	assert(rendered.canFind("### Task `execute`"), rendered);
	assert(rendered.canFind("Target task type: `implement`"), rendered);
	assert(rendered.canFind(buildPath(tmp, "out")), rendered);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto tmp = "/tmp/cydo-test-loadsystemprompt-missing-master";
	scope (exit) { if (exists(tmp)) rmdirRecurse(tmp); }
	mkdirRecurse(buildPath(tmp, "system_prompts"));

	write(buildPath(tmp, "system_prompts", "role.md"), "Role prompt");

	TaskTypeDef def;
	def.name = "implement";
	def.system_prompt_template = "system_prompts/role.md";

	bool threw;
	try
	{
		loadSystemPrompt(def, [tmp], "", ["generated_guidance": "Detailed guidance"]);
	}
	catch (Exception e)
	{
		threw = true;
		assert(e.msg.canFind("system prompt master template"), e.msg);
		assert(e.msg.canFind(buildPath(tmp, "system_prompts", "master.md")), e.msg);
	}
	assert(threw);
}
