/// Task type definitions — schema, YAML loader, validator, and mock simulator.
///
/// Task types define agent behavior, capabilities, and flow control.
/// See defs/task-types/README.md for the design document.
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
	@Optional string prompt_template;
}

struct TaskTypeDef
{
	// Name (populated from YAML mapping key via @Key)
	string name;

	// Identity
	string description;
	@Optional string agent_description;
	@Optional string tool_guidance;
	@Optional string prompt_template;

	// Capabilities
	string model_class = "large";
	@Optional bool read_only;
	string output_type = "report";

	// Flow control
	@Optional string[] creatable_tasks;
	@Optional ContinuationDef[string] continuations;

	// Execution
	bool parallelizable;
	@Optional bool serial;
	@Optional bool worktree;
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

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

TaskTypeDef[] loadTaskTypes(string path)
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

	bool hasSteward = false;
	foreach (ref def; types)
	{
		if (def.steward)
			hasSteward = true;

		checkTemplateFile(def.name, def.prompt_template);

		// Check creatable_tasks references
		foreach (ct; def.creatable_tasks)
		{
			if (types.byName(ct) is null)
				errors ~= format("%s: creatable_tasks references unknown type '%s'", def.name, ct);
		}

		// Check continuation references
		foreach (cname, ref cont; def.continuations)
		{
			if (types.byName(cont.task_type) is null)
				errors ~= format("%s: continuation '%s' references unknown type '%s'",
					def.name, cname, cont.task_type);

			// keep_context + worktree are incompatible: --resume needs the
			// same cwd to find the JSONL, but worktree changes the cwd.
			auto target = types.byName(cont.task_type);
			if (cont.keep_context && target !is null && target.worktree)
				errors ~= format("%s: continuation '%s' has keep_context but target '%s' "
					~ "has worktree: true — these are incompatible",
					def.name, cname, cont.task_type);

			// keep_context continuations should have a prompt_template
			// (the prompt injected when the mode switch happens).
			if (cont.keep_context && cont.prompt_template.length == 0)
				errors ~= format("%s: continuation '%s' has keep_context but no "
					~ "prompt_template — mode switches need an entry prompt",
					def.name, cname);

			// !keep_context continuations should not have a prompt_template
			// (the target type's own prompt_template is used instead).
			if (!cont.keep_context && cont.prompt_template.length > 0)
				errors ~= format("%s: continuation '%s' has prompt_template but "
					~ "!keep_context — only keep_context continuations use "
					~ "continuation-level prompts",
					def.name, cname);

			checkTemplateFile(format("%s: continuation '%s'", def.name, cname), cont.prompt_template);
		}

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
		// Collect all types reachable via keep_context from user_visible roots
		bool[string] interactive;
		void walkKeepContext(string name)
		{
			if (name in interactive)
				return;
			interactive[name] = true;
			auto d = types.byName(name);
			if (d is null)
				return;
			foreach (_, ref c; d.continuations)
				if (c.keep_context)
					walkKeepContext(c.task_type);
		}
		foreach (ref def; types)
			if (def.user_visible)
				walkKeepContext(def.name);

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
		}
	}

	// Prompt template invariant: types that are only reachable via
	// keep_context continuations should NOT have their own prompt_template
	// (they get their entry prompt from the continuation). Types that are
	// directly invokable (user_visible, creatable_tasks targets, or
	// !keep_context continuation targets) SHOULD have a prompt_template.
	{
		// Collect types that are directly invokable (not via keep_context)
		bool[string] directlyInvokable;
		foreach (ref def; types)
		{
			if (def.user_visible)
				directlyInvokable[def.name] = true;
			// Targets of creatable_tasks
			foreach (ct; def.creatable_tasks)
				directlyInvokable[ct] = true;
			// Targets of !keep_context continuations
			foreach (_, ref cont; def.continuations)
				if (!cont.keep_context)
					directlyInvokable[cont.task_type] = true;
		}

		foreach (ref def; types)
		{
			if (def.steward)
				continue; // stewards have their own prompt rules

			bool isDirect = (def.name in directlyInvokable) !is null;
			if (isDirect && def.prompt_template.length == 0)
				errors ~= format("%s: directly invokable type has no prompt_template",
					def.name);
			if (!isDirect && def.prompt_template.length > 0)
				errors ~= format("%s: type is only reachable via keep_context but has "
					~ "prompt_template — entry prompt should be on the continuation",
					def.name);
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
		writefln("    model: %s | output: %s%s%s",
			def.model_class, def.output_type,
			def.read_only ? " (read-only)" : "",
			def.worktree ? " (worktree)" : "");

		if (def.creatable_tasks.length > 0)
			writefln("    Can create sub-tasks: %s", def.creatable_tasks.join(", "));

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
					def.creatable_tasks.join(", "));
				auto choice = prompt();
				if (eof || choice == "no" || choice == "n" || choice.length == 0)
					break;
				if (!def.creatable_tasks.canFind(choice))
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
			// No continuations — task completes
			writefln("    (no continuations — task completes)");
			tasks[taskIdx].status = "completed";
			writeln();
			return;
		}

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

/// Render a prompt template by reading the template file and substituting
/// placeholders. Returns the raw description if no template is defined.
string renderPrompt(ref TaskTypeDef def, string description, string typesDir, string outputFile = "")
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
	if (outputFile.length > 0)
		tmpl = tmpl.replace("{{output_file}}", outputFile);
	return tmpl;
}

/// Render a continuation's prompt template. The continuation must have a
/// prompt_template set (enforced by validation for keep_context continuations).
string renderContinuationPrompt(ref ContinuationDef contDef, string fallback, string typesDir)
{
	import std.file : exists, readText;
	import std.path : buildPath;

	if (contDef.prompt_template.length == 0)
		return fallback;

	auto templatePath = buildPath(typesDir, contDef.prompt_template);
	assert(exists(templatePath), "Continuation prompt template not found: " ~ templatePath);

	return readText(templatePath);
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
	foreach (name; parentDef.creatable_tasks)
	{
		auto def = allTypes.byName(name);
		if (def is null)
			continue;
		result ~= format("- %s: %s\n", name, def.description);
		if (def.agent_description.length > 0)
			result ~= indentLines(def.agent_description.strip, "  ");
		if (def.tool_guidance.length > 0)
			result ~= indentLines(def.tool_guidance.strip, "  ");
		result ~= "\n";
	}
	return result.length > 0 ? result : null;
}

/// Return the comma-separated list of Claude Code tools to disallow.
/// The built-in "Task" tool is always disallowed (replaced by our MCP tool).
/// Plan mode tools are disallowed (replaced by our SwitchMode continuations).
/// Read-only enforcement is handled by the sandbox (ro mount), not by tool removal.
string disallowedTools()
{
	return "Task,EnterPlanMode,ExitPlanMode";
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
		auto label = format("%s\\n%s%s%s", def.name, def.model_class,
			def.read_only ? " ro" : "",
			def.worktree ? " ⎘" : "");
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
			auto attrs = format("label=\"%s\"", label);
			if (cont.requires_approval)
				attrs ~= " style=bold color=\"#856404\"";
			writefln("    %s -> %s [%s];", def.name, cont.task_type, attrs);
		}
	}

	// Creatable task edges (dashed arrows)
	foreach (ref def; types)
	{
		foreach (ct; def.creatable_tasks)
			writefln("    %s -> %s [style=dashed arrowhead=open label=\"creates\"];",
				def.name, ct);
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
	writeln("        leg2 [label=\"Solid arrow = continuation\\lDashed arrow = creates sub-task\\lBold arrow = requires approval\\lDotted diamond = steward review\\l⟳ = keep context (session fork)\\l⎘ = own worktree\\l\"];");
	writeln("    }");

	writeln("}");
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

/// Load and validate task types from a YAML file, returning null on error.
private TaskTypeDef[] loadAndValidate(string flag, string[] args)
{
	import std.algorithm : find;

	string path;
	auto rest = args.find(flag);
	if (rest.length > 1)
		path = rest[1];

	if (path.length == 0)
	{
		stderr.writefln("Usage: cydo %s <types.yaml>", flag);
		return null;
	}

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

void runSimulator(string[] args)
{
	auto types = loadAndValidate("--simulate", args);
	if (types is null)
		return;

	printTypes(types);
	writeln();
	simulateWorkflow(types);
}

void runDot(string[] args)
{
	auto types = loadAndValidate("--dot", args);
	if (types is null)
		return;

	generateDot(types);
}

// ---------------------------------------------------------------------------
// Context Dump — show what an agent would see for a given task type
// ---------------------------------------------------------------------------

void runDumpContext(string[] args)
{
	import std.algorithm : find;
	import std.path : dirName;

	// Parse: --dump-context <types.yaml> <type-name>
	auto rest = args.find("--dump-context");
	if (rest.length < 3)
	{
		stderr.writefln("Usage: cydo --dump-context <types.yaml> <type-name>");
		return;
	}

	auto path = rest[1];
	auto typeName = rest[2];
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
	writefln("Model:          %s (%s)", def.model_class, modelClassToAlias(def.model_class));
	writefln("Output:         %s", def.output_type);
	writefln("Read-only:      %s", def.read_only);
	writefln("Worktree:       %s", def.worktree);
	writefln("Parallelizable: %s", def.parallelizable);
	writefln("User-visible:   %s", def.user_visible);
	if (def.steward)
	{
		writefln("Steward:        true");
		writefln("Steward domain: %s", def.steward_domain.strip);
	}
	if (def.max_turns > 0)
		writefln("Max turns:      %d", def.max_turns);
	writefln("Disallowed:     %s", disallowedTools());
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

	auto toolsJson = buildToolsListJson!CydoTools([
		"creatable_task_types": formatCreatableTaskTypes(types, typeName),
		"switchmodes": formatSwitchModes(types, typeName),
		"handoffs": formatHandoffs(types, typeName),
	]);

	auto toolsList = jsonParse!ToolsList(toolsJson);
	foreach (ref tool; toolsList.tools)
	{
		writefln("### %s\n", tool.name);
		if (tool.description.length > 0)
			writefln("%s\n", tool.description);
	}
}
