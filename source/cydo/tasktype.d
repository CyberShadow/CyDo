/// Task type definitions — schema, YAML loader, validator, and mock simulator.
///
/// Task types define agent behavior, capabilities, and flow control.
/// See docs/task-types/README.md for the design document.
module cydo.tasktype;

import configy.attributes : Optional;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.stdio : readln, stderr, stdin, stdout, write, writef, writefln, writeln;
import std.string : chomp, strip;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

struct ContinuationDef
{
	string task_type;
	bool requires_approval;
}

struct TaskTypeDef
{
	// Identity
	string description;
	@Optional string agent_description;
	@Optional string tool_guidance;
	@Optional string prompt_template;

	// Capabilities
	string model_class = "large";
	string tool_preset = "full";
	string output_type = "report";

	// Flow control
	@Optional string[] creatable_tasks;
	@Optional ContinuationDef[string] continuations;

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
	TaskTypeDef[string] task_types;
}

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

TaskTypeDef[string] loadTaskTypes(string path)
{
	import configy.read : parseConfigFileSimple;

	auto result = parseConfigFileSimple!TaskTypesFile(path);
	if (result.isNull())
		throw new Exception("Failed to parse task types from " ~ path);
	return result.get().task_types;
}

// ---------------------------------------------------------------------------
// Validator
// ---------------------------------------------------------------------------

string[] validateTaskTypes(TaskTypeDef[string] types)
{
	string[] errors;

	bool hasSteward = false;
	foreach (name, ref def; types)
	{
		if (def.steward)
			hasSteward = true;

		// Check creatable_tasks references
		foreach (ct; def.creatable_tasks)
		{
			if (ct !in types)
				errors ~= format("%s: creatable_tasks references unknown type '%s'", name, ct);
		}

		// Check continuation references
		foreach (cname, ref cont; def.continuations)
		{
			if (cont.task_type !in types)
				errors ~= format("%s: continuation '%s' references unknown type '%s'",
					name, cname, cont.task_type);
		}

		// Steward validation
		if (def.steward)
		{
			if (def.output_type != "report")
				errors ~= format("%s: steward should have output_type 'report', got '%s'",
					name, def.output_type);
			if (!def.serial)
				errors ~= format("%s: steward should have serial: true", name);
		}

		// Validate enum-like fields
		if (!["small", "medium", "large"].canFind(def.model_class))
			errors ~= format("%s: invalid model_class '%s'", name, def.model_class);
		if (!["full", "read-only", "code", "execute"].canFind(def.tool_preset))
			errors ~= format("%s: invalid tool_preset '%s'", name, def.tool_preset);
		if (!["commit", "patch", "report"].canFind(def.output_type))
			errors ~= format("%s: invalid output_type '%s'", name, def.output_type);
	}

	// Check that requires_approval has stewards available
	foreach (name, ref def; types)
	{
		foreach (cname, ref cont; def.continuations)
		{
			if (cont.requires_approval && !hasSteward)
				errors ~= format("%s: continuation '%s' requires approval but no steward types defined",
					name, cname);
		}
	}

	// Check for pure-continuation cycles (A→B→A with no modal break)
	foreach (name, ref def; types)
	{
		foreach (cname, ref cont; def.continuations)
		{
			if (auto cycle = detectCycle(types, cont.task_type, [name]))
				errors ~= format("%s: continuation '%s' creates cycle: %s",
					name, cname, cycle);
		}
	}

	return errors;
}

/// Detect cycles in continuation chains. Returns the cycle path or null.
private string detectCycle(TaskTypeDef[string] types, string current, string[] visited)
{
	if (visited.canFind(current))
		return visited.join(" → ") ~ " → " ~ current;

	auto def = current in types;
	if (!def)
		return null;

	foreach (_, ref cont; def.continuations)
	{
		if (auto cycle = detectCycle(types, cont.task_type, visited ~ current))
			return cycle;
	}
	return null;
}

// ---------------------------------------------------------------------------
// Printer
// ---------------------------------------------------------------------------

void printTypes(TaskTypeDef[string] types)
{
	auto names = types.keys.array.sort.release;

	writeln("=== Task Type Definitions ===\n");
	foreach (name; names)
	{
		auto def = types[name];
		writefln("  %-20s  model: %-6s  tools: %-9s  output: %-6s%s%s%s",
			name,
			def.model_class,
			def.tool_preset,
			def.output_type,
			def.steward ? "  [steward]" : "",
			def.serial ? "  [serial]" : "",
			def.user_visible ? "" : "  [hidden]",
		);
	}

	// Summary
	auto stewards = names.filter!(n => types[n].steward).array;
	auto visible = names.filter!(n => types[n].user_visible).array;
	writefln("\n  %d types total, %d user-visible, %d stewards",
		names.length, visible.length, stewards.length);
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

void simulateWorkflow(TaskTypeDef[string] types)
{
	writeln("=== Workflow Simulator ===\n");

	auto stewards = types.keys.filter!(n => types[n].steward).array.sort.release;
	auto visible = types.keys.filter!(n => types[n].user_visible).array.sort.release;

	if (visible.length == 0)
	{
		writeln("No user-visible task types defined.");
		return;
	}

	writefln("User-visible types: %s", visible.join(", "));
	if (stewards.length > 0)
		writefln("Active stewards: %s", stewards.join(", "));
	writeln();

	// Pick starting type
	write("> Start type: ");
	stdout.flush();
	auto startType = readln().chomp.strip;
	if (startType !in types)
	{
		writefln("Unknown type '%s'", startType);
		return;
	}

	write("> Description: ");
	stdout.flush();
	auto description = readln().chomp.strip;

	writeln();

	SimTask[] tasks;
	int nextId = 1;

	void createTask(string typeName, string desc, int parentId)
	{
		if (typeName !in types)
		{
			writefln("  ERROR: unknown type '%s' — cannot create task", typeName);
			return;
		}
		auto def = types[typeName];
		auto id = nextId++;
		auto taskIdx = tasks.length;
		tasks ~= SimTask(id, typeName, desc, parentId, "active");

		// Print task info
		writefln("[%d] %s%s\"%s\"",
			id, typeName,
			parentId > 0 ? format(" (from #%d)  ", parentId) : "  ",
			desc.length > 60 ? desc[0 .. 60] ~ "…" : desc);
		writefln("    model: %s | tools: %s | output: %s%s",
			def.model_class, def.tool_preset, def.output_type,
			def.output_type == "commit" ? " (worktree)" : "");

		if (def.creatable_tasks.length > 0)
			writefln("    Can create sub-tasks: %s", def.creatable_tasks.join(", "));

		if (def.continuations.length > 0)
		{
			auto contNames = def.continuations.keys.array.sort.release;
			string[] labels;
			foreach (cn; contNames)
			{
				auto cont = def.continuations[cn];
				labels ~= format("%s → %s%s", cn, cont.task_type,
					cont.requires_approval ? " (approval)" : "");
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
			stdout.flush();
			auto response = readln().chomp.strip;
			if (response == "y" || response == "Y")
			{
				writefln("    → APPROVED");
				tasks[taskIdx].status = "completed";
			}
			else
			{
				write("    > Reason: ");
				stdout.flush();
				auto reason = readln().chomp.strip;
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
			while (true)
			{
				writef("    > Create sub-task? (%s, or 'no'): ",
					def.creatable_tasks.join(", "));
				stdout.flush();
				auto choice = readln().chomp.strip;
				if (choice == "no" || choice == "n" || choice.length == 0)
					break;
				if (!def.creatable_tasks.canFind(choice))
				{
					writefln("    Invalid choice '%s'", choice);
					continue;
				}
				write("    > Sub-task description: ");
				stdout.flush();
				auto subDesc = readln().chomp.strip;
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
			// No continuations — task completes
			writefln("    (no continuations — task completes)");
			tasks[taskIdx].status = "completed";
			writeln();
			return;
		}

		// Pick a continuation
		auto contNames = def.continuations.keys.array.sort.release;
		if (contNames.length == 1)
		{
			writefln("    > Continuation: %s (only option)", contNames[0]);
		}
		else
		{
			writef("    > Choose continuation (%s): ", contNames.join(", "));
			stdout.flush();
			auto choice = readln().chomp.strip;
			if (!contNames.canFind(choice))
			{
				writefln("    Invalid choice '%s', using '%s'", choice, contNames[0]);
				choice = contNames[0];
			}
			contNames = [choice]; // narrow to chosen
		}

		auto chosen = contNames[0];
		auto cont = def.continuations[chosen];
		tasks[taskIdx].status = "completed";
		tasks[taskIdx].chosenContinuation = chosen;
		writeln();

		// Handle approval gate
		if (cont.requires_approval && stewards.length > 0)
		{
			writefln("    Approval required — invoking %d steward(s)...\n",
				stewards.length);

			bool allApproved = true;
			int rejectedBy = -1;

			foreach (s; stewards)
				createTask(s, format("Review: %s", desc), id);

			// Check results
			foreach (ref t; tasks)
			{
				if (t.parentId == id && types[t.typeName].steward)
				{
					if (t.status == "rejected")
					{
						allApproved = false;
						rejectedBy = t.id;
						break;
					}
				}
			}

			if (!allApproved)
			{
				writefln("    APPROVAL BLOCKED — task #%d was rejected by steward #%d.",
					id, rejectedBy);
				writeln("    (In production: caller would be resumed with feedback)\n");
				return;
			}

			writeln("    All stewards approved. Creating successor...\n");
		}

		// Create successor
		createTask(cont.task_type, desc, id);
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
		writefln("%s#%d %s [%s%s]%s",
			indent, t.id, t.typeName, t.status, contInfo,
			types[t.typeName].steward ? "" :
				(t.description.length > 40
					? format(" \"%s…\"", t.description[0 .. 40])
					: format(" \"%s\"", t.description)));
	}
	writeln();
}

// ---------------------------------------------------------------------------
// Prompt Rendering
// ---------------------------------------------------------------------------

/// Render a prompt template by reading the template file and substituting
/// placeholders. Returns the raw description if no template is defined.
string renderPrompt(ref TaskTypeDef def, string description, string typesDir)
{
	import std.file : exists, readText;
	import std.path : buildPath;
	import std.string : replace;

	if (def.prompt_template.length == 0)
		return description;

	auto templatePath = buildPath(typesDir, def.prompt_template);
	if (!exists(templatePath))
		return description;

	auto tmpl = readText(templatePath);
	tmpl = tmpl.replace("{{task_description}}", description);
	if (def.knowledge_base.length > 0)
		tmpl = tmpl.replace("{{knowledge_base}}", def.knowledge_base);
	return tmpl;
}

/// Format a description of available task types for a given parent type.
/// Used to fill the {{creatable_task_types}} placeholder in MCP tool descriptions.
string formatCreatableTaskTypes(TaskTypeDef[string] allTypes, string parentTypeName)
{
	auto parentDef = parentTypeName in allTypes;
	if (parentDef is null || parentDef.creatable_tasks.length == 0)
		return "(none available)";

	string result;
	foreach (name; parentDef.creatable_tasks)
	{
		auto def = name in allTypes;
		if (def is null)
			continue;
		auto desc = def.agent_description.length > 0
			? def.agent_description.strip
			: def.description;
		result ~= format("- %s: %s\n", name, desc);
		if (def.tool_guidance.length > 0)
			result ~= format("  %s\n", def.tool_guidance.strip);
	}
	return result.length > 0 ? result : "(none available)";
}

/// Map tool_preset to a comma-separated list of Claude Code tools to disallow.
/// The built-in "Task" tool is always disallowed (replaced by our MCP tool).
string toolPresetToDisallowedTools(string toolPreset)
{
	// Write/execute tools to disallow for read-only presets
	enum writeTools = "Write,Edit,MultiEdit,NotebookEdit,Bash";

	switch (toolPreset)
	{
		case "read-only":
			return "Task," ~ writeTools;
		case "full":
			return "Task";
		case "code":
			return "Task,Bash";
		case "execute":
			return "Task";
		default:
			throw new Exception("Unknown tool_preset: " ~ toolPreset);
	}
}

/// Map model_class to Claude CLI model alias.
string modelClassToAlias(string modelClass)
{
	switch (modelClass)
	{
		case "small":  return "haiku";
		case "medium": return "sonnet";
		case "large":  return "opus";
		default:       return "sonnet";
	}
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

void runSimulator(string[] args)
{
	import std.algorithm : find;

	// Find the YAML path argument (first non-flag arg after --simulate)
	string path;
	auto rest = args.find("--simulate");
	if (rest.length > 1)
		path = rest[1];

	if (path.length == 0)
	{
		stderr.writeln("Usage: cydo --simulate <types.yaml>");
		return;
	}

	TaskTypeDef[string] types;
	try
		types = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return;
	}

	// Validate
	auto errors = validateTaskTypes(types);
	if (errors.length > 0)
	{
		writeln("=== Validation Errors ===\n");
		foreach (e; errors)
			writefln("  ERROR: %s", e);
		writeln();
	}

	// Print summary
	printTypes(types);
	writeln();

	// Run interactive simulation
	simulateWorkflow(types);
}
