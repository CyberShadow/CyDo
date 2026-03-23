/// Task type definitions — schema, YAML loader, validator, and mock simulator.
///
/// Task types define agent behavior, capabilities, and flow control.
/// See docs/task-types.md for the design document.
module cydo.tasktype;

import configy.attributes : Key, Optional;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.stdio : readln, stderr, stdin, stdout, write, writef, writefln, writeln;
import std.string : chomp, lineSplitter, strip;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

struct ContinuationDef
{
	string task_type;
	bool requires_approval;
	bool keep_context;
	@Optional bool worktree;
	@Optional string prompt_template;
}

struct CreatableTaskDef
{
	string name;
	@Optional string task_type; // actual type to create (defaults to name)
	@Optional bool worktree;
	@Optional string prompt_template;
	@Optional string result_note;

	/// Resolve the actual task type (task_type field, or name if unset).
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
	string description;
	@Optional string display_name;
	@Optional string icon;
	@Optional string agent_description;
	@Optional string tool_guidance;
	@Optional string prompt_template;

	// Capabilities
	string model_class = "large";
	@Optional bool read_only;
	string output_type = "report";

	// Flow control
	@Optional @Key("name") CreatableTaskDef[] creatable_tasks;
	@Optional ContinuationDef[string] continuations;
	@Optional ContinuationDef on_yield; // auto-continuation on clean exit

	// Execution
	bool parallelizable;
	@Optional bool serial;
	bool user_visible = true;
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

/// Returns the "interactive cluster": the set of types reachable from any
/// user_visible type via keep_context continuations.
bool[string] interactiveTypeSet(TaskTypeDef[] types)
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
	foreach (ref def; types)
		if (def.user_visible)
			walk(def.name);
	return result;
}

/// Returns true if the given type name is in the interactive cluster.
/// These types are all permitted to call AskUserQuestion.
bool isInteractive(TaskTypeDef[] types, string typeName)
{
	return (typeName in types.interactiveTypeSet) !is null;
}

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

import dyaml.node : Node, NodeID;

/// Load task types from one or more YAML files, merging them in order
/// (later files override earlier ones at the YAML level).
TaskTypeDef[] loadTaskTypes(string[] paths...)
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
	return result.task_types;
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

string[] validateTaskTypes(TaskTypeDef[] types, string typesDir = "")
{
	import std.file : exists;
	import std.path : buildPath;

	string[] errors;

	/// Check that a prompt_template file exists on disk.
	void checkTemplateFile(string context, string tmpl)
	{
		if (tmpl.length == 0 || typesDir.length == 0)
			return;
		if (!exists(buildPath(typesDir, tmpl)))
			errors ~= format("%s: prompt_template '%s' not found", context, tmpl);
	}

	/// Validate a single ContinuationDef, returning any errors found.
	string[] validateContinuationDef(string context, ref ContinuationDef cont)
	{
		string[] errs;
		if (types.byName(cont.task_type) is null)
			errs ~= format("%s: references unknown type '%s'", context, cont.task_type);
		if (cont.keep_context && cont.worktree)
			errs ~= format("%s: has keep_context and worktree: true — these are incompatible",
				context);
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
			if (def.output_type != "report")
				errors ~= format("%s: steward should have output_type 'report', got '%s'",
					def.name, def.output_type);
			if (!def.serial)
				errors ~= format("%s: steward should have serial: true", def.name);
		}

		// Validate enum-like fields
		if (!["small", "medium", "large"].canFind(def.model_class))
			errors ~= format("%s: invalid model_class '%s'", def.name, def.model_class);
		if (!["commit", "patch", "report"].canFind(def.output_type))
			errors ~= format("%s: invalid output_type '%s'", def.name, def.output_type);
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

	// Interactive session integrity: types reachable from user_visible
	// types via keep_context must not have !keep_context continuations,
	// because a Handoff would complete the interactive task and orphan
	// the user's session.
	{
		auto interactive = types.interactiveTypeSet;

		// Check that interactive types only have keep_context continuations
		foreach (ref def; types)
		{
			if (def.name !in interactive)
				continue;
			foreach (cname, ref cont; def.continuations)
			{
				if (!cont.keep_context)
					errors ~= format("%s: continuation '%s' is !keep_context but '%s' is "
						~ "reachable from a user_visible type via keep_context — "
						~ "Handoff would orphan the interactive session",
						def.name, cname, def.name);
			}
			if (def.on_yield.task_type.length > 0)
				errors ~= format("%s: on_yield is not allowed on interactive types "
					~ "(reachable from user_visible via keep_context)", def.name);
		}
	}

	// Prompt template invariant:
	// - user_visible types MUST have node-level prompt_template (user creates them directly)
	// - non-user_visible, non-steward types MUST NOT have node-level prompt_template
	//   (prompt comes from the edge that spawns them)
	// - edges to non-user_visible targets MUST carry prompt_template
	{
		foreach (ref def; types)
		{
			if (def.steward)
				continue;

			if (def.user_visible && def.prompt_template.length == 0)
				errors ~= format("%s: user_visible type has no prompt_template", def.name);
			if (!def.user_visible && def.prompt_template.length > 0)
				errors ~= format("%s: non-user_visible type has node-level prompt_template"
					~ " — prompt should be on the edges that reference it", def.name);
		}

		// Every edge to a non-user_visible target must carry prompt_template
		foreach (ref def; types)
		{
			foreach (ref edge; def.creatable_tasks)
			{
				auto target = types.byName(edge.resolvedType);
				if (target !is null && !target.user_visible && edge.prompt_template.length == 0)
					errors ~= format("%s: creatable_tasks '%s' targets non-user_visible type"
						~ " but has no prompt_template", def.name, edge.name);
			}

			foreach (cname, ref cont; def.continuations)
			{
				if (cont.keep_context)
					continue;
				auto target = types.byName(cont.task_type);
				if (target !is null && !target.user_visible && cont.prompt_template.length == 0)
					errors ~= format("%s: continuation '%s' targets non-user_visible type '%s'"
						~ " but has no prompt_template", def.name, cname, cont.task_type);
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

void printTypes(TaskTypeDef[] types)
{
	writeln("=== Task Type Definitions ===\n");
	foreach (ref def; types)
	{
		writefln("  %-20s  model: %-6s  output: %-6s%s%s%s%s",
			def.name,
			def.model_class,
			def.output_type,
			def.read_only ? "  [ro]" : "",
			def.steward ? "  [steward]" : "",
			def.serial ? "  [serial]" : "",
			def.user_visible ? "" : "  [hidden]",
		);
	}

	// Summary
	auto stewards = types.filter!(d => d.steward).array;
	auto visible = types.filter!(d => d.user_visible).array;
	writefln("\n  %d types total, %d user-visible, %d stewards",
		types.length, visible.length, stewards.length);
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

void simulateWorkflow(TaskTypeDef[] types)
{
	writeln("=== Workflow Simulator ===\n");

	auto stewardNames = types.filter!(d => d.steward).map!(d => d.name).array;
	auto visibleNames = types.filter!(d => d.user_visible).map!(d => d.name).array;

	if (visibleNames.length == 0)
	{
		writeln("No user-visible task types defined.");
		return;
	}

	writefln("User-visible types: %s", visibleNames.join(", "));
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

	// Pick starting type
	write("> Start type: ");
	auto startType = prompt();
	if (eof || types.byName(startType) is null)
	{
		if (!eof)
			writefln("Unknown type '%s'", startType);
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
		writefln("    model: %s | output: %s%s",
			def.model_class, def.output_type,
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
	import std.string : replace;

	foreach (key, value; vars)
		text = text.replace("{{" ~ key ~ "}}", value);
	return text;
}

/// Render a prompt template by reading the template file and substituting
/// placeholders. Returns the raw description if no template is defined.
string renderPrompt(ref TaskTypeDef def, string description, string typesDir,
	string outputFile = "", string edgeTemplate = "", string[string] extraVars = null)
{
	import std.file : exists, readText;
	import std.path : buildPath, dirName;

	auto templateName = edgeTemplate.length > 0 ? edgeTemplate : def.prompt_template;
	if (templateName.length == 0)
		return description;

	auto templatePath = buildPath(typesDir, templateName);
	if (!exists(templatePath))
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

/// Render a continuation's prompt template. The continuation must have a
/// prompt_template set (enforced by validation for keep_context continuations).
string renderContinuationPrompt(ref ContinuationDef contDef, string fallback, string typesDir,
	string[string] extraVars = null)
{
	import std.file : exists, readText;
	import std.path : buildPath;

	if (contDef.prompt_template.length == 0)
		return fallback;

	auto templatePath = buildPath(typesDir, contDef.prompt_template);
	assert(exists(templatePath), "Continuation prompt template not found: " ~ templatePath);

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
		auto desc = targetDef !is null ? targetDef.description : cont.task_type;
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
		auto desc = targetDef !is null ? targetDef.description : cont.task_type;
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
		result ~= format("- %s: %s\n", edge.name, def.description);
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

void generateDot(TaskTypeDef[] types)
{
	auto stewardNames = types.filter!(d => d.steward).map!(d => d.name).array;

	writeln("digraph task_types {");
	writeln("    rankdir=LR;");
	writeln("    node [fontname=\"Helvetica\" fontsize=10];");
	writeln("    edge [fontname=\"Helvetica\" fontsize=9];");
	writeln();

	// User node
	writeln("    user [label=\"user\" shape=house style=\"filled\" fillcolor=\"#cce5ff\"];");
	foreach (ref def; types)
		if (def.user_visible)
			writefln("    user -> %s [style=dashed arrowhead=open label=\"creates\"];", def.name);
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
		else if (def.user_visible)
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
			if (cont.worktree)
				label ~= " ⎘";
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
			if (def.on_yield.worktree)
				label ~= " ⎘";
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
			if (ct.worktree)
				label ~= " ⎘";
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
	writeln("        leg1 [label=\"Green = user-visible\\lGray = agent-initiated\\lYellow = steward\\l\"];");
	writeln("        leg2 [label=\"Solid arrow = continuation\\lDashed arrow = creates sub-task\\lBold arrow = requires approval\\lDotted diamond = steward review\\l⟳ = keep context (session fork)\\l⎘ = new worktree\\l\"];");
	writeln("    }");

	writeln("}");
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

/// Load and validate task types from a YAML file, returning null on error.
private TaskTypeDef[] loadAndValidate(string path)
{
	TaskTypeDef[] types;
	try
		types = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return null;
	}

	import std.path : dirName;
	auto errors = validateTaskTypes(types, dirName(path));
	if (errors.length > 0)
	{
		writeln("=== Validation Errors ===\n");
		foreach (e; errors)
			writefln("  ERROR: %s", e);
		writeln();
	}

	return types;
}

void runSimulator(string path)
{
	auto types = loadAndValidate(path);
	if (types is null)
		return;

	printTypes(types);
	writeln();
	simulateWorkflow(types);
}

void runDot(string path)
{
	auto types = loadAndValidate(path);
	if (types is null)
		return;

	generateDot(types);
}

// ---------------------------------------------------------------------------
// Context Dump — show what an agent would see for a given task type
// ---------------------------------------------------------------------------

void runDumpContext(string path, string typeName)
{
	import std.path : dirName;

	auto typesDir = dirName(path);

	TaskTypeDef[] types;
	try
		types = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return;
	}

	auto errors = validateTaskTypes(types, typesDir);
	if (errors.length > 0)
	{
		foreach (e; errors)
			stderr.writefln("  WARN: %s", e);
		stderr.writeln();
	}

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
	writefln("Description:    %s", def.description);
	writefln("Model:          %s", def.model_class);
	writefln("Output:         %s", def.output_type);
	writefln("Read-only:      %s", def.read_only);
	writefln("Parallelizable: %s", def.parallelizable);
	writefln("User-visible:   %s", def.user_visible);
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
			def.on_yield.worktree ? " (worktree)" : "",
			def.on_yield.requires_approval ? " (approval)" : "");
	writefln("Disallowed:     (agent-specific)");
	writeln();

	// Rendered prompt
	writeln("─── Rendered Prompt (with placeholder \"<task description>\") ───");
	writeln();
	auto rendered = renderPrompt(def, "<task description>", typesDir);
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
	if (types.isInteractive(typeName)) includeTools ~= "AskUserQuestion";

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
