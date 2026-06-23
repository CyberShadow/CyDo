module cydo.cli.tasktype_tooling;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.format : format;
import std.path : dirName;
import std.stdio : readln, stderr, stdin, stdout, write, writef, writefln, writeln;
import std.string : chomp, strip;

import cydo.domain.task_types.definition : TaskTypeConfig, TaskTypeDef, UserEntryPointDef,
	WorktreeMode, byName, loadTaskTypes, validateTaskTypes;

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
private TaskTypeConfig* loadAndValidate(string path, bool function(string) isKnownAgent)
{
	TaskTypeConfig config;
	try
		config = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return null;
	}

	auto errors = validateTaskTypes(config.types, config.entryPoints, isKnownAgent, [dirName(path)]);
	if (errors.length > 0)
	{
		writeln("=== Validation Errors ===\n");
		foreach (e; errors)
			writefln("  ERROR: %s", e);
		writeln();
	}

	return new TaskTypeConfig(config.types, config.entryPoints);
}

void runSimulator(string path, bool function(string) isKnownAgent)
{
	auto config = loadAndValidate(path, isKnownAgent);
	if (config is null)
		return;

	printTypes(config.types, config.entryPoints);
	writeln();
	simulateWorkflow(config.types, config.entryPoints);
}

void runDot(string path, bool function(string) isKnownAgent)
{
	auto config = loadAndValidate(path, isKnownAgent);
	if (config is null)
		return;

	generateDot(config.types, config.entryPoints);
}
