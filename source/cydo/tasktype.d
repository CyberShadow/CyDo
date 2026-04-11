/// Task type definitions — schema, YAML loader, validator, and mock simulator.
///
/// Task types define agent behavior, capabilities, and flow control.
/// See docs/task-types.md for the design document.
module cydo.tasktype;

import configy.attributes : Key, Optional;

import std.algorithm : canFind, filter, map, reverse, sort;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.stdio : readln, stderr, stdin, stdout, write, writef, writefln, writeln;
import std.string : chomp, lineSplitter, strip;

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
	string model_class = "large";
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
}

/// Combined result of loading task types (types + entry points).
struct TaskTypeConfig
{
	TaskTypeDef[] types;
	UserEntryPointDef[] entryPoints;
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
		blank.model_class = "large";
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

	return TaskTypeConfig(result.task_types, result.user_entry_points);
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
// Validator
// ---------------------------------------------------------------------------

string[] validateTaskTypes(TaskTypeDef[] types, UserEntryPointDef[] entryPoints, string[] typesDirs = null)
{
	import std.file : exists;
	import std.path : buildPath;

	string[] errors;

	/// Check that a prompt_template file exists on disk.
	void checkTemplateFile(string context, string tmpl)
	{
		if (tmpl.length == 0 || typesDirs.length == 0)
			return;
		foreach (dir; typesDirs)
			if (exists(buildPath(dir, tmpl)))
				return;
		errors ~= format("%s: prompt_template '%s' not found", context, tmpl);
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

		// Validate enum-like fields
		if (!["small", "medium", "large"].canFind(def.model_class))
			errors ~= format("%s: invalid model_class '%s'", def.name, def.model_class);
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
			if (ep.description.length == 0)
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

	return errors;
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
// Printer
// ---------------------------------------------------------------------------

void printTypes(TaskTypeDef[] types, UserEntryPointDef[] entryPoints)
{
	bool[string] entryPointTargets;
	foreach (ref ep; entryPoints)
		entryPointTargets[ep.resolvedType] = true;

	writeln("=== Task Type Definitions ===\n");
	foreach (ref def; types)
	{
		auto outputStr = def.output_type.length == 0 ? "—"
			: def.output_type.map!(o => cast(string) o).join("+");
		writefln("  %-20s  model: %-6s  output: %-14s%s%s%s%s",
			def.name,
			def.model_class,
			outputStr,
			def.read_only ? "  [ro]" : "",
			def.steward ? "  [steward]" : "",
			def.serial ? "  [serial]" : "",
			def.name in entryPointTargets ? "  [entry-point]" : "",
		);
	}

	// Summary
	auto stewards = types.filter!(d => d.steward).array;
	writefln("\n  %d types total, %d entry points, %d stewards",
		types.length, entryPoints.length, stewards.length);
}

// ---------------------------------------------------------------------------
// Mock Simulator
// ---------------------------------------------------------------------------

private struct SimTask
{
	int id;
	string typeName;
	string description;
	int parentId;
	string status; // active, completed, rejected
	string chosenContinuation;
}

void simulateWorkflow(TaskTypeDef[] types, UserEntryPointDef[] entryPoints)
{
	writeln("=== Workflow Simulator ===\n");

	auto stewardNames = types.filter!(d => d.steward).map!(d => d.name).array;
	auto epNames = entryPoints.map!(ep => ep.name).array;

	if (epNames.length == 0)
	{
		writeln("No user entry points defined.");
		return;
	}

	writefln("User entry points: %s", epNames.join(", "));
	if (stewardNames.length > 0)
		writefln("Active stewards: %s", stewardNames.join(", "));
	writeln();

	SimTask[] tasks;
	int nextId = 1;
	bool eof = false;

	/// Read a line from stdin, handling EOF gracefully.
	string prompt()
	{
		stdout.flush();
		if (stdin.eof)
		{
			eof = true;
			return null;
		}
		auto line = readln();
		if (line is null)
		{
			eof = true;
			return null;
		}
		return line.chomp.strip;
	}

	// Pick starting entry point (or type name for non-entry-point types)
	write("> Start entry point: ");
	auto startInput = prompt();
	if (eof)
		return;
	// Resolve entry point name to type name
	auto epDef = entryPoints.byName(startInput);
	auto startType = epDef !is null ? epDef.resolvedType : startInput;
	if (types.byName(startType) is null)
	{
		writefln("Unknown entry point or type '%s'", startInput);
		return;
	}

	write("> Description: ");
	auto description = prompt();
	if (eof)
		return;

	writeln();

	void createTask(string typeName, string desc, int parentId)
	{
		if (eof)
			return;
		auto defp = types.byName(typeName);
		if (defp is null)
		{
			writefln("  ERROR: unknown type '%s' — cannot create task", typeName);
			return;
		}
		auto def = *defp;
		auto id = nextId++;
		auto taskIdx = tasks.length;
		tasks ~= SimTask(id, typeName, desc, parentId, "active");

		// Print task info
		writefln("[%d] %s%s\"%s\"",
			id, typeName,
			parentId > 0 ? format(" (from #%d)  ", parentId) : "  ",
			desc.length > 60 ? desc[0 .. 60] ~ "…" : desc);
		auto outputStr = def.output_type.length == 0 ? "—"
			: def.output_type.map!(o => cast(string) o).join("+");
		writefln("    model: %s | output: %s%s",
			def.model_class, outputStr,
			def.read_only ? " (read-only)" : "");

		if (def.creatable_tasks.length > 0)
			writefln("    Can create sub-tasks: %s",
				def.creatable_tasks.map!(c => c.name).join(", "));

		if (def.continuations.length > 0)
		{
			auto contNames = def.continuations.keys.array.sort.release;
			string[] labels;
			foreach (cn; contNames)
			{
				auto cont = def.continuations[cn];
				string flags;
				if (cont.requires_approval)
					flags ~= " (approval)";
				if (cont.keep_context)
					flags ~= " (keep-context)";
				labels ~= format("%s → %s%s", cn, cont.task_type, flags);
			}
			writefln("    Continuations: %s", labels.join(", "));
		}

		if (def.steward)
			writefln("    Domain: %s", def.steward_domain);

		// Simulate agent work
		if (def.steward)
		{
			// Steward: ask for approve/reject
			write("    > Approve? (y/n): ");
			auto response = prompt();
			if (eof)
				return;
			if (response == "y" || response == "Y")
			{
				writefln("    → APPROVED");
				tasks[taskIdx].status = "completed";
			}
			else
			{
				write("    > Reason: ");
				auto reason = prompt();
				if (eof)
					return;
				writefln("    → REJECTED: %s", reason);
				tasks[taskIdx].status = "rejected";
			}
			writeln();
			return;
		}

		// Simulate creatable sub-tasks (modal: agent stays alive, gets results)
		if (def.creatable_tasks.length > 0)
		{
			bool createdAny = false;
			while (!eof)
			{
				writef("    > Create sub-task? (%s, or 'no'): ",
					def.creatable_tasks.map!(c => c.name).join(", "));
				auto choice = prompt();
				if (eof || choice == "no" || choice == "n" || choice.length == 0)
					break;
				if (def.creatable_tasks.byName(choice) is null)
				{
					writefln("    Invalid choice '%s'", choice);
					continue;
				}
				write("    > Sub-task description: ");
				auto subDesc = prompt();
				if (eof)
					break;
				if (subDesc.length == 0)
					subDesc = desc;
				writeln();
				createTask(choice, subDesc, id);
				createdAny = true;
			}
			if (createdAny)
				writeln();
		}

		if (def.continuations.length == 0)
		{
			if (def.on_yield.task_type.length > 0)
			{
				// on_yield fires automatically on clean exit
				writefln("    (on_yield → %s)", def.on_yield.task_type);
				tasks[taskIdx].status = "completed";
				createTask(def.on_yield.task_type, desc, id);
			}
			else
			{
				// No continuations — task completes
				writefln("    (no continuations — task completes)");
				tasks[taskIdx].status = "completed";
			}
			writeln();
			return;
		}

		if (def.on_yield.task_type.length > 0)
			writefln("    (on_yield: auto-continues to %s if no explicit continuation)",
				def.on_yield.task_type);

		// Pick a continuation (modeled as a tool call that can be retried on rejection)
		auto contNames = def.continuations.keys.array.sort.release;
		while (!eof)
		{
			string chosen;
			if (contNames.length == 1)
			{
				writefln("    > Continuation: %s (only option)", contNames[0]);
				chosen = contNames[0];
			}
			else
			{
				writef("    > Choose continuation (%s): ", contNames.join(", "));
				auto choice = prompt();
				if (eof)
					return;
				if (!contNames.canFind(choice))
				{
					writefln("    Invalid choice '%s', using '%s'", choice, contNames[0]);
					choice = contNames[0];
				}
				chosen = choice;
			}

			auto cont = def.continuations[chosen];

			// Handle approval gate (tool call blocks while stewards review)
			if (cont.requires_approval && stewardNames.length > 0)
			{
				writefln("    Approval required — invoking %d steward(s)...\n",
					stewardNames.length);

				// Record where this round's steward tasks start
				auto roundStart = tasks.length;

				foreach (s; stewardNames)
					createTask(s, format("Review: %s", desc), id);

				// Check only this round's steward results
				bool allApproved = true;
				string rejectionFeedback;
				foreach (ref t; tasks[roundStart .. $])
				{
					if (t.status == "rejected")
					{
						allApproved = false;
						rejectionFeedback = format("steward #%d (%s) rejected",
							t.id, t.typeName);
						break;
					}
				}

				if (!allApproved)
				{
					writefln("    REJECTED — %s. Agent can rework and retry.\n",
						rejectionFeedback);
					continue; // agent retries continuation tool call
				}

				writeln("    All stewards approved.\n");
			}

			// Approved (or no approval needed) — commit the continuation
			tasks[taskIdx].status = "completed";
			tasks[taskIdx].chosenContinuation = chosen;

			// Create successor
			createTask(cont.task_type, desc, id);
			break;
		}
	}

	createTask(startType, description, 0);

	// Print task tree
	writeln("\n=== Task Tree ===");
	foreach (ref t; tasks)
	{
		auto indent = "";
		// Simple indentation based on parent chain
		int depth = 0;
		int pid = t.parentId;
		while (pid > 0)
		{
			depth++;
			bool found = false;
			foreach (ref p; tasks)
			{
				if (p.id == pid)
				{
					pid = p.parentId;
					found = true;
					break;
				}
			}
			if (!found)
				break;
		}
		foreach (_; 0 .. depth)
			indent ~= "  ";

		auto contInfo = t.chosenContinuation.length > 0
			? format(" → %s", t.chosenContinuation) : "";
		auto typeDef = types.byName(t.typeName);
		writefln("%s#%d %s [%s%s]%s",
			indent, t.id, t.typeName, t.status, contInfo,
			(typeDef !is null && typeDef.steward) ? "" :
				(t.description.length > 40
					? format(" \"%s…\"", t.description[0 .. 40])
					: format(" \"%s\"", t.description)));
	}
	writeln();
}

// ---------------------------------------------------------------------------
// Prompt Rendering
// ---------------------------------------------------------------------------

/// Replace `{{key}}` placeholders in a string with values from the given map.
string substituteVars(string text, string[string] vars)
{
	import djinja.djinja : loadData, JinjaConfig;
	import djinja.render : Render;
	import uninode.serialization : serialize = serializeToUniNode;

    enum JinjaConfig conf = { cmntOpInline: "$$", stmtOpInline: "$$$" };
	auto tmpl = loadData!conf(text);
	auto renderer = new Render(tmpl);
	return renderer.render(serialize(vars));
}

/// Render a prompt template by reading the template file and substituting
/// placeholders. Returns the raw description if no template is defined.
string renderPrompt(ref TaskTypeDef def, string description, string[] typesDirs,
	string outputFile = "", string edgeTemplate = "", string[string] extraVars = null)
{
	import std.file : exists, readText;
	import std.path : buildPath, dirName;

	auto templateName = edgeTemplate.length > 0 ? edgeTemplate : def.prompt_template;
	if (templateName.length == 0)
		return description;

	string templatePath;
	foreach (dir; typesDirs)
	{
		auto candidate = buildPath(dir, templateName);
		if (exists(candidate))
		{
			templatePath = candidate;
			break;
		}
	}
	if (templatePath.length == 0)
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
	return substituteVars(readText(templatePath), vars);
}

/// Load and render a system prompt template from disk. Returns null if the
/// type has no system_prompt_template or the file does not exist.
/// Substitutes {{output_file}}, {{output_dir}}, and {{knowledge_base}}.
string loadSystemPrompt(ref TaskTypeDef def, string[] typesDirs,
	string outputFile = "", string[string] extraVars = null)
{
	import std.file : exists, readText;
	import std.path : buildPath, dirName;

	if (def.system_prompt_template.length == 0 || typesDirs.length == 0)
		return null;
	string path;
	foreach (dir; typesDirs)
	{
		auto candidate = buildPath(dir, def.system_prompt_template);
		if (exists(candidate))
		{
			path = candidate;
			break;
		}
	}
	if (path.length == 0)
		return null;
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
	auto text = readText(path);
	return vars.length > 0 ? substituteVars(text, vars) : text;
}

/// Render a continuation's prompt template. The continuation must have a
/// prompt_template set (enforced by validation for keep_context continuations).
string renderContinuationPrompt(ref ContinuationDef contDef, string fallback, string[] typesDirs,
	string[string] extraVars = null)
{
	import std.file : exists, readText;
	import std.path : buildPath;

	if (contDef.prompt_template.length == 0)
		return fallback;

	string templatePath;
	foreach (dir; typesDirs)
	{
		auto candidate = buildPath(dir, contDef.prompt_template);
		if (exists(candidate))
		{
			templatePath = candidate;
			break;
		}
	}
	assert(templatePath.length > 0, "Continuation prompt template not found: " ~ contDef.prompt_template);

	auto text = readText(templatePath);
	if (extraVars.length > 0)
		text = substituteVars(text, extraVars);
	return text;
}

/// Indent every line of a multi-line string with the given prefix.
string indentLines(string text, string prefix)
{
	string result;
	foreach (line; text.lineSplitter)
		result ~= prefix ~ line ~ "\n";
	return result;
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

/// Format a description of keep_context continuations for a given task type.
/// Used to fill the {{switchmodes}} placeholder in the SwitchMode tool description.
string formatSwitchModes(TaskTypeDef[] allTypes, string typeName)
{
	auto def = allTypes.byName(typeName);
	if (def is null || def.continuations.length == 0)
		return null;

	string result;
	foreach (cname, ref cont; def.continuations)
	{
		if (!cont.keep_context)
			continue;
		auto targetDef = allTypes.byName(cont.task_type);
		auto desc = edgeDesc(cont.description, targetDef);
		result ~= format("- %s: switches to '%s' — %s\n", cname, cont.task_type, desc);
		if (targetDef !is null && targetDef.agent_description.length > 0)
			result ~= indentLines(targetDef.agent_description.strip, "  ");
		if (targetDef !is null && targetDef.tool_guidance.length > 0)
			result ~= indentLines(targetDef.tool_guidance.strip, "  ");
		result ~= "\n";
	}
	return result.length > 0 ? result : null;
}

/// Format a description of !keep_context continuations for a given task type.
/// Used to fill the {{handoffs}} placeholder in the Handoff tool description.
string formatHandoffs(TaskTypeDef[] allTypes, string typeName)
{
	auto def = allTypes.byName(typeName);
	if (def is null || def.continuations.length == 0)
		return null;

	string result;
	foreach (cname, ref cont; def.continuations)
	{
		if (cont.keep_context)
			continue;
		auto targetDef = allTypes.byName(cont.task_type);
		auto desc = edgeDesc(cont.description, targetDef);
		result ~= format("- %s: hands off to '%s' — %s\n", cname, cont.task_type, desc);
		result ~= "\n";
	}
	return result.length > 0 ? result : null;
}

/// Format a description of available task types for a given parent type.
/// Used to fill the {{creatable_task_types}} placeholder in MCP tool descriptions.
string formatCreatableTaskTypes(TaskTypeDef[] allTypes, string parentTypeName)
{
	auto parentDef = allTypes.byName(parentTypeName);
	if (parentDef is null || parentDef.creatable_tasks.length == 0)
		return null;

	string result;
	foreach (ref edge; parentDef.creatable_tasks)
	{
		auto def = allTypes.byName(edge.resolvedType);
		if (def is null)
			continue;
		auto desc = edgeDesc(edge.description, def);
		result ~= format("- %s: %s\n", edge.name, desc);
		if (def.agent_description.length > 0)
			result ~= indentLines(def.agent_description.strip, "  ");
		if (def.tool_guidance.length > 0)
			result ~= indentLines(def.tool_guidance.strip, "  ");
		result ~= "\n";
	}
	return result.length > 0 ? result : null;
}

// ---------------------------------------------------------------------------
// Dot (Graphviz) Generator
// ---------------------------------------------------------------------------

void generateDot(TaskTypeDef[] types, UserEntryPointDef[] entryPoints)
{
	auto stewardNames = types.filter!(d => d.steward).map!(d => d.name).array;

	// Build a set of entry point target types for coloring
	bool[string] entryPointTargets;
	foreach (ref ep; entryPoints)
		entryPointTargets[ep.resolvedType] = true;

	writeln("digraph task_types {");
	writeln("    rankdir=LR;");
	writeln("    node [fontname=\"Helvetica\" fontsize=10];");
	writeln("    edge [fontname=\"Helvetica\" fontsize=9];");
	writeln();

	// User node
	writeln("    user [label=\"user\" shape=house style=\"filled\" fillcolor=\"#cce5ff\"];");
	foreach (ref ep; entryPoints)
		writefln("    user -> %s [style=dashed arrowhead=open label=\"%s\"];",
			ep.resolvedType, ep.name);
	writeln();

	// Node definitions with shape/color by category
	foreach (ref def; types)
	{
		string shape, style, fillcolor;

		if (def.steward)
		{
			shape = "octagon";
			fillcolor = "#fff3cd";
		}
		else if (def.name in entryPointTargets)
		{
			shape = "box";
			fillcolor = "#d4edda";
		}
		else
		{
			shape = "box";
			fillcolor = "#e2e3e5";
		}

		style = "filled,rounded";
		auto label = format("%s\\n%s%s", def.name, def.model_class,
			def.read_only ? " ro" : "");
		writefln("    %s [label=\"%s\" shape=%s style=\"%s\" fillcolor=\"%s\"];",
			def.name, label, shape, style, fillcolor);
	}
	writeln();

	// Continuation edges (solid arrows)
	foreach (ref def; types)
	{
		foreach (cname, ref cont; def.continuations)
		{
			string label = cname;
			if (cont.keep_context)
				label ~= " ⟳";
			if (cont.worktree == WorktreeMode.fork)
				label ~= " ⎘";
			else if (cont.worktree == WorktreeMode.require)
				label ~= " ⎘?";
			auto attrs = format("label=\"%s\"", label);
			if (cont.requires_approval)
				attrs ~= " style=bold color=\"#856404\"";
			writefln("    %s -> %s [%s];", def.name, cont.task_type, attrs);
		}
	}

	// on_yield edges (dashed with normal arrowhead)
	foreach (ref def; types)
	{
		if (def.on_yield.task_type.length > 0)
		{
			string label = "on_yield";
			if (def.on_yield.keep_context)
				label ~= " ⟳";
			if (def.on_yield.worktree == WorktreeMode.fork)
				label ~= " ⎘";
			else if (def.on_yield.worktree == WorktreeMode.require)
				label ~= " ⎘?";
			writefln("    %s -> %s [label=\"%s\" style=dashed arrowhead=normal color=\"#6c757d\"];",
				def.name, def.on_yield.task_type, label);
		}
	}

	// Creatable task edges (dashed arrows)
	foreach (ref def; types)
	{
		foreach (ref ct; def.creatable_tasks)
		{
			string label = "creates";
			if (ct.task_type.length > 0)
				label ~= format(" (%s)", ct.name);
			if (ct.worktree == WorktreeMode.fork)
				label ~= " ⎘";
			else if (ct.worktree == WorktreeMode.require)
				label ~= " ⎘?";
			writefln("    %s -> %s [style=dashed arrowhead=open label=\"%s\"];",
				def.name, ct.resolvedType, label);
		}
	}

	// Steward review edges (dotted, from approval-gated continuations to stewards)
	if (stewardNames.length > 0)
	{
		writeln();
		writeln("    // Steward review relationships");
		foreach (ref def; types)
		{
			foreach (_, ref cont; def.continuations)
			{
				if (cont.requires_approval)
				{
					foreach (s; stewardNames)
						writefln("    %s -> %s [style=dotted arrowhead=diamond color=\"#856404\" constraint=false];",
							def.name, s);
					break; // one set of steward edges per source node
				}
			}
		}
	}

	// Legend
	writeln();
	writeln("    subgraph cluster_legend {");
	writeln("        label=\"Legend\" style=dashed fontname=\"Helvetica\" fontsize=10;");
	writeln("        node [shape=plaintext fontsize=9];");
	writeln("        leg1 [label=\"Green = user entry point\\lGray = agent-initiated\\lYellow = steward\\l\"];");
	writeln("        leg2 [label=\"Solid arrow = continuation\\lDashed arrow = creates sub-task\\lBold arrow = requires approval\\lDotted diamond = steward review\\l⟳ = keep context (session fork)\\l⎘ = fork worktree\\l⎘? = require worktree\\l\"];");
	writeln("    }");

	writeln("}");
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

/// Load and validate task types from a YAML file, returning null on error.
private TaskTypeConfig* loadAndValidate(string path)
{
	TaskTypeConfig config;
	try
		config = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return null;
	}

	import std.path : dirName;
	auto errors = validateTaskTypes(config.types, config.entryPoints, [dirName(path)]);
	if (errors.length > 0)
	{
		writeln("=== Validation Errors ===\n");
		foreach (e; errors)
			writefln("  ERROR: %s", e);
		writeln();
	}

	return new TaskTypeConfig(config.types, config.entryPoints);
}

void runSimulator(string path)
{
	auto config = loadAndValidate(path);
	if (config is null)
		return;

	printTypes(config.types, config.entryPoints);
	writeln();
	simulateWorkflow(config.types, config.entryPoints);
}

void runDot(string path)
{
	auto config = loadAndValidate(path);
	if (config is null)
		return;

	generateDot(config.types, config.entryPoints);
}

// ---------------------------------------------------------------------------
// Context Dump — show what an agent would see for a given task type
// ---------------------------------------------------------------------------

void runDumpContext(string path, string typeName)
{
	import std.path : dirName;

	auto typesDir = dirName(path);

	TaskTypeConfig config;
	try
		config = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return;
	}

	auto errors = validateTaskTypes(config.types, config.entryPoints, [typesDir]);
	if (errors.length > 0)
	{
		foreach (e; errors)
			stderr.writefln("  WARN: %s", e);
		stderr.writeln();
	}

	auto types = config.types;
	auto entryPoints = config.entryPoints;

	auto defp = types.byName(typeName);
	if (defp is null)
	{
		stderr.writefln("Unknown task type '%s'", typeName);
		stderr.writefln("Available types: %s",
			types.map!(d => d.name).join(", "));
		return;
	}
	auto def = *defp;

	// Header
	writefln("=== Agent Context for '%s' ===\n", typeName);

	// Task type metadata
	{
		auto firstLine = def.agent_description.length > 0
			? def.agent_description.strip.lineSplitter.front.to!string : "—";
		writefln("Description:    %s", firstLine);
	}
	writefln("Model:          %s", def.model_class);
	writefln("Output:         %s", def.output_type.length == 0 ? "—"
		: def.output_type.map!(o => cast(string) o).join("+"));
	writefln("Read-only:      %s", def.read_only);
	auto treeRO = computeTreeReadOnly(types);
	writefln("Tree-read-only: %s", typeName in treeRO ? treeRO[typeName] : false);
	auto reachesWt = computeReachesWorktree(types);
	writefln("Reaches worktree: %s", typeName in reachesWt ? reachesWt[typeName] : false);
	{
		auto epNames = entryPoints.filter!(ep => ep.resolvedType == typeName).map!(ep => ep.name).join(", ");
		writefln("Entry points:   %s", epNames.length > 0 ? epNames : "—");
	}
	if (def.steward)
	{
		writefln("Steward:        true");
		writefln("Steward domain: %s", def.steward_domain.strip);
	}
	if (def.max_turns > 0)
		writefln("Max turns:      %d", def.max_turns);
	if (def.on_yield.task_type.length > 0)
		writefln("On-yield:       %s%s%s%s",
			def.on_yield.task_type,
			def.on_yield.keep_context ? " (keep-context)" : "",
			def.on_yield.worktree != WorktreeMode.inherit
				? format(" (worktree: %s)", def.on_yield.worktree) : "",
			def.on_yield.requires_approval ? " (approval)" : "");
	writefln("Disallowed:     (agent-specific)");
	writeln();

	// Rendered prompt
	writeln("─── Rendered Prompt (with placeholder \"<task description>\") ───");
	writeln();
	auto rendered = renderPrompt(def, "<task description>", [typesDir]);
	writeln(rendered);
	writeln();

	// Incoming continuation prompts — what this type sees when entered
	// via a keep_context continuation from another type.
	{
		import std.file : exists, readText;
		import std.path : buildPath;

		bool headerPrinted = false;
		foreach (ref srcDef; types)
		{
			foreach (cname, ref cont; srcDef.continuations)
			{
				if (cont.task_type != typeName || !cont.keep_context)
					continue;
				if (cont.prompt_template.length == 0)
					continue;
				if (!headerPrinted)
				{
					writeln("─── Incoming Continuation Prompts ───");
					writeln();
					headerPrinted = true;
				}
				writefln("From %s via '%s':", srcDef.name, cname);
				auto tmplPath = buildPath(typesDir, cont.prompt_template);
				if (exists(tmplPath))
					writeln(readText(tmplPath));
				else
					writefln("  (template not found: %s)", cont.prompt_template);
				writeln();
			}
		}
	}

	// MCP tools — generated from the same binding the real MCP server uses
	writeln("─── MCP Tools ───");
	writeln();

	import cydo.mcp.binding : buildToolsListJson, ToolsList;
	import cydo.mcp.tools : CydoTools;
	import ae.utils.json : jsonParse;

	auto ct = formatCreatableTaskTypes(types, typeName);
	auto sm = formatSwitchModes(types, typeName);
	auto ho = formatHandoffs(types, typeName);

	string[] includeTools;
	includeTools ~= "Bash";  // dump-context always shows Bash for completeness
	if (ct.length > 0) includeTools ~= "Task";
	if (sm.length > 0) includeTools ~= "SwitchMode";
	if (ho.length > 0) includeTools ~= "Handoff";
	if (isInteractive(types, entryPoints, typeName)) includeTools ~= "AskUserQuestion";

	auto toolsJson = buildToolsListJson!CydoTools([
		"creatable_task_types": ct,
		"switchmodes": sm,
		"handoffs": ho,
	], includeTools);

	auto toolsList = jsonParse!ToolsList(toolsJson);
	foreach (ref tool; toolsList.tools)
	{
		writefln("### %s\n", tool.name);
		if (tool.description.length > 0)
			writefln("%s\n", tool.description);
	}
}
