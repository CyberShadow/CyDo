module cydo.discover;

import std.path : baseName, buildPath, relativePath;
import std.file : exists, isDir, dirEntries, SpanMode;
import std.logger : warningf;

import dyaml.node : Node, NodeID, NodeType;

// ---------------------------------------------------------------------------
// Expression value type (for evaluation results)
// ---------------------------------------------------------------------------

struct ExprValue
{
	private enum Type : ubyte { bool_, int_, string_ }
	private Type _type;
	private union
	{
		bool _bool;
		int _int;
		string _str;
	}

	this(bool v) { _type = Type.bool_; _bool = v; }
	this(int v)  { _type = Type.int_;  _int  = v; }
	this(string v) { _type = Type.string_; _str = v; }

	T get(T)() const
	{
		static if (is(T == bool))
		{
			assert(_type == Type.bool_, "ExprValue: expected bool");
			return _bool;
		}
		else static if (is(T == int))
		{
			assert(_type == Type.int_, "ExprValue: expected int");
			return _int;
		}
		else static if (is(T == string))
		{
			assert(_type == Type.string_, "ExprValue: expected string");
			return _str;
		}
		else static assert(0, "ExprValue.get: unsupported type " ~ T.stringof);
	}

	bool opEquals(const ExprValue other) const
	{
		if (_type != other._type) return false;
		final switch (_type)
		{
			case Type.bool_:   return _bool == other._bool;
			case Type.int_:    return _int  == other._int;
			case Type.string_: return _str  == other._str;
		}
	}
}

// ---------------------------------------------------------------------------
// DiscoverExpr — expression tree for project discovery configuration
// ---------------------------------------------------------------------------

struct DiscoverExpr
{
	enum Kind : ubyte
	{
		default_,              // sentinel: not configured
		// Constants
		true_, false_,
		int_literal,
		string_literal,
		// Variables
		var_depth,             // int
		var_relative_path,     // string
		var_name,              // string
		var_is_project,        // bool (recurse_when expr only)
		// Leaf predicates (bool-returning, string value)
		has_file, has_dir, has_entry,
		// Bool combinators
		and_, or_, not_,
		// Comparisons (bool-returning, 2 operands)
		less_than, greater_than, equals_,
	}

	enum ValueType : ubyte { bool_, int_, string_ }

	Kind kind;
	string value;              // for leaf predicates, string_literal
	int intValue;              // for int_literal
	DiscoverExpr[] operands;   // for combinators and comparisons

	bool isConfigured() const { return kind != Kind.default_; }

	// -----------------------------------------------------------------------
	// Static type of the result
	// -----------------------------------------------------------------------

	ValueType resultType() const
	{
		final switch (kind)
		{
			case Kind.true_, Kind.false_,
			     Kind.has_file, Kind.has_dir, Kind.has_entry,
			     Kind.and_, Kind.or_, Kind.not_,
			     Kind.less_than, Kind.greater_than, Kind.equals_,
			     Kind.var_is_project:
				return ValueType.bool_;
			case Kind.int_literal, Kind.var_depth:
				return ValueType.int_;
			case Kind.string_literal, Kind.var_relative_path, Kind.var_name:
				return ValueType.string_;
			case Kind.default_:
				assert(0, "resultType called on default expression");
		}
	}

	// -----------------------------------------------------------------------
	// YAML parsing hook (called by configy)
	// -----------------------------------------------------------------------

	static DiscoverExpr fromYAML(scope ConfigParser!DiscoverExpr parser)
	{
		auto n = parser.node;
		return fromNode(n, parser.path);
	}

	private static DiscoverExpr fromNode(ref const(Node) node, string path)
	{
		if (node.nodeID == NodeID.scalar)
		{
			if (node.type == NodeType.boolean)
				return DiscoverExpr(node.as!bool ? Kind.true_ : Kind.false_);

			if (node.type == NodeType.integer)
				return DiscoverExpr(Kind.int_literal, null, node.as!int);

			// String scalar: check for variable reference
			string s = node.as!string;
			if (s.length > 0 && s[0] == '$')
				return parseVariable(s, path);

			return DiscoverExpr(Kind.string_literal, s);
		}

		if (node.nodeID == NodeID.mapping)
		{
			// Expect exactly one key; dispatch inside the loop to avoid copying const(Node)
			if (node.length != 1)
				throw new Exception("expression must have exactly one key at " ~ path);

			foreach (ref const pair; node.mapping)
			{
				string key = pair.key.as!string;
				switch (key)
				{
					case "has_file":  return DiscoverExpr(Kind.has_file, pair.value.as!string);
					case "has_dir":   return DiscoverExpr(Kind.has_dir, pair.value.as!string);
					case "has_entry": return DiscoverExpr(Kind.has_entry, pair.value.as!string);
					case "literal":   return DiscoverExpr(Kind.string_literal, pair.value.as!string);
					case "and":       return parseListCombinator(Kind.and_, pair.value, path);
					case "or":        return parseListCombinator(Kind.or_, pair.value, path);
					case "not":       return DiscoverExpr(Kind.not_, null, 0,
					                      [fromNode(pair.value, path)]);
					case "less_than":
						return parseBinaryComparison(Kind.less_than, pair.value, path);
					case "greater_than":
						return parseBinaryComparison(Kind.greater_than, pair.value, path);
					case "equals":
						return parseBinaryComparison(Kind.equals_, pair.value, path);
					default:
						throw new Exception(
							"unknown expression key '" ~ key ~ "' at " ~ path);
				}
			}
			assert(0, "unreachable");
		}

		throw new Exception("expression must be a scalar or mapping at " ~ path);
	}

	private static DiscoverExpr parseVariable(string s, string path)
	{
		switch (s)
		{
			case "$depth":         return DiscoverExpr(Kind.var_depth);
			case "$relative_path": return DiscoverExpr(Kind.var_relative_path);
			case "$name":          return DiscoverExpr(Kind.var_name);
			case "$is_project":    return DiscoverExpr(Kind.var_is_project);
			default:
				throw new Exception("unknown variable '" ~ s ~ "' at " ~ path);
		}
	}

	private static DiscoverExpr parseListCombinator(Kind kind, ref const(Node) valueNode, string path)
	{
		DiscoverExpr[] ops;
		foreach (ref const child; valueNode.sequence)
			ops ~= fromNode(child, path);
		return DiscoverExpr(kind, null, 0, ops);
	}

	private static DiscoverExpr parseBinaryComparison(Kind kind, ref const(Node) valueNode, string path)
	{
		DiscoverExpr[] ops;
		foreach (ref const child; valueNode.sequence)
			ops ~= fromNode(child, path);
		if (ops.length != 2)
			throw new Exception("comparison requires exactly 2 operands at " ~ path);
		return DiscoverExpr(kind, null, 0, ops);
	}

	// -----------------------------------------------------------------------
	// JSON serialization (for CLI boundary between parent and subprocess)
	// -----------------------------------------------------------------------

	import std.json : JSONValue;

	JSONValue toJson() const
	{
		final switch (kind)
		{
			case Kind.true_:          return JSONValue(true);
			case Kind.false_:         return JSONValue(false);
			case Kind.int_literal:    return JSONValue(intValue);
			case Kind.string_literal: return JSONValue(["literal": JSONValue(value)]);
			case Kind.var_depth:         return JSONValue("$depth");
			case Kind.var_relative_path: return JSONValue("$relative_path");
			case Kind.var_name:          return JSONValue("$name");
			case Kind.var_is_project:    return JSONValue("$is_project");
			case Kind.has_file:  return JSONValue(["has_file":  JSONValue(value)]);
			case Kind.has_dir:   return JSONValue(["has_dir":   JSONValue(value)]);
			case Kind.has_entry: return JSONValue(["has_entry": JSONValue(value)]);
			case Kind.not_:
				return JSONValue(["not": operands[0].toJson()]);
			case Kind.and_:
			{
				JSONValue[] ops;
				foreach (ref op; operands) ops ~= op.toJson();
				return JSONValue(["and": JSONValue(ops)]);
			}
			case Kind.or_:
			{
				JSONValue[] ops;
				foreach (ref op; operands) ops ~= op.toJson();
				return JSONValue(["or": JSONValue(ops)]);
			}
			case Kind.less_than:
				return JSONValue(["less_than":
					JSONValue([operands[0].toJson(), operands[1].toJson()])]);
			case Kind.greater_than:
				return JSONValue(["greater_than":
					JSONValue([operands[0].toJson(), operands[1].toJson()])]);
			case Kind.equals_:
				return JSONValue(["equals":
					JSONValue([operands[0].toJson(), operands[1].toJson()])]);
			case Kind.default_:
				assert(0, "toJson called on default expression");
		}
	}

	static DiscoverExpr fromJson(JSONValue v)
	{
		import std.json : JSONType;
		switch (v.type)
		{
			case JSONType.true_:  return DiscoverExpr(Kind.true_);
			case JSONType.false_: return DiscoverExpr(Kind.false_);
			case JSONType.integer:
				return DiscoverExpr(Kind.int_literal, null, cast(int) v.integer);
			case JSONType.string:
				return parseVariable(v.str, "<JSON>");
			case JSONType.object:
			{
				auto obj = v.object;
				if (obj.length != 1)
					throw new Exception("expression JSON object must have exactly one key");
				string key = obj.keys[0];
				auto child = obj[key];
				switch (key)
				{
					case "has_file":  return DiscoverExpr(Kind.has_file, child.str);
					case "has_dir":   return DiscoverExpr(Kind.has_dir, child.str);
					case "has_entry": return DiscoverExpr(Kind.has_entry, child.str);
					case "literal":   return DiscoverExpr(Kind.string_literal, child.str);
					case "not":
						return DiscoverExpr(Kind.not_, null, 0, [fromJson(child)]);
					case "and":
					{
						DiscoverExpr[] ops;
						foreach (ref op; child.array) ops ~= fromJson(op);
						return DiscoverExpr(Kind.and_, null, 0, ops);
					}
					case "or":
					{
						DiscoverExpr[] ops;
						foreach (ref op; child.array) ops ~= fromJson(op);
						return DiscoverExpr(Kind.or_, null, 0, ops);
					}
					case "less_than":
					case "greater_than":
					case "equals":
					{
						auto arr = child.array;
						if (arr.length != 2)
							throw new Exception(
								"comparison requires exactly 2 operands in JSON");
						auto k = key == "less_than" ? Kind.less_than
						       : key == "greater_than" ? Kind.greater_than
						       : Kind.equals_;
						return DiscoverExpr(k, null, 0,
							[fromJson(arr[0]), fromJson(arr[1])]);
					}
					default:
						throw new Exception(
							"unknown expression key '" ~ key ~ "' in JSON");
				}
			}
			default:
				throw new Exception("unexpected JSON type for expression");
		}
	}

	// -----------------------------------------------------------------------
	// Evaluation
	// -----------------------------------------------------------------------

	ExprValue evaluate(ref const EvalContext ctx) const
	{
		final switch (kind)
		{
			case Kind.true_:  return ExprValue(true);
			case Kind.false_: return ExprValue(false);
			case Kind.int_literal:    return ExprValue(intValue);
			case Kind.string_literal: return ExprValue(value);
			case Kind.var_depth:         return ExprValue(cast(int) ctx.depth);
			case Kind.var_relative_path: return ExprValue(ctx.relativePath);
			case Kind.var_name:          return ExprValue(ctx.dirName);
			case Kind.var_is_project:
				assert(ctx.isProjectAvailable, "$is_project not available in this context");
				return ExprValue(ctx.isProjectValue);
			case Kind.has_file:
			{
				auto p = buildPath(ctx.dirPath, value);
				return ExprValue(exists(p) && !isDir(p));
			}
			case Kind.has_dir:
			{
				auto p = buildPath(ctx.dirPath, value);
				return ExprValue(exists(p) && isDir(p));
			}
			case Kind.has_entry:
				return ExprValue(exists(buildPath(ctx.dirPath, value)));
			case Kind.and_:
				foreach (ref op; operands)
					if (!op.evaluate(ctx).get!bool) return ExprValue(false);
				return ExprValue(true);
			case Kind.or_:
				foreach (ref op; operands)
					if (op.evaluate(ctx).get!bool) return ExprValue(true);
				return ExprValue(false);
			case Kind.not_:
				return ExprValue(!operands[0].evaluate(ctx).get!bool);
			case Kind.less_than:
				return ExprValue(
					operands[0].evaluate(ctx).get!int <
					operands[1].evaluate(ctx).get!int);
			case Kind.greater_than:
				return ExprValue(
					operands[0].evaluate(ctx).get!int >
					operands[1].evaluate(ctx).get!int);
			case Kind.equals_:
				return ExprValue(operands[0].evaluate(ctx) == operands[1].evaluate(ctx));
			case Kind.default_:
				assert(0, "evaluate called on default expression");
		}
	}

	bool evaluateBool(ref const EvalContext ctx) const
	{
		return evaluate(ctx).get!bool;
	}
}

// ---------------------------------------------------------------------------
// Evaluation context
// ---------------------------------------------------------------------------

struct EvalContext
{
	string dirPath;
	string dirName;
	string relativePath;
	uint depth;
	bool isProjectAvailable;   // true when evaluating recurse_when expr
	bool isProjectValue;       // result of is_project evaluation
}

// ---------------------------------------------------------------------------
// ProjectDiscoveryConfig — holds the expression pair used during discovery
// ---------------------------------------------------------------------------

struct ProjectDiscoveryConfig
{
	import configy.attributes : Optional;

	@Optional DiscoverExpr is_project;
	@Optional DiscoverExpr recurse_when;

	void validate() const
	{
		if (is_project.isConfigured)
			validateBool(is_project, "is_project", false);
		if (recurse_when.isConfigured)
			validateBool(recurse_when, "recurse_when", true);
	}

	private static void validateBool(
		ref const DiscoverExpr expr, string ctx, bool allowIsProject)
	{
		import std.format : format;
		validateExpr(expr, ctx, allowIsProject);
		if (expr.resultType() != DiscoverExpr.ValueType.bool_)
			throw new Exception(format("%s expression must return bool", ctx));
	}

	private static void validateExpr(
		ref const DiscoverExpr expr, string ctx, bool allowIsProject)
	{
		import std.format : format;
		alias K = DiscoverExpr.Kind;
		final switch (expr.kind)
		{
			case K.default_,
			     K.true_, K.false_,
			     K.int_literal, K.string_literal,
			     K.var_depth, K.var_relative_path, K.var_name,
			     K.has_file, K.has_dir, K.has_entry:
				break;
			case K.var_is_project:
				if (!allowIsProject)
					throw new Exception(
						format("%s: $is_project is only valid in recurse_when", ctx));
				break;
			case K.not_:
				validateExpr(expr.operands[0], ctx, allowIsProject);
				if (expr.operands[0].resultType() != DiscoverExpr.ValueType.bool_)
					throw new Exception(format("%s: 'not' operand must be bool", ctx));
				break;
			case K.and_, K.or_:
				foreach (ref op; expr.operands)
				{
					validateExpr(op, ctx, allowIsProject);
					if (op.resultType() != DiscoverExpr.ValueType.bool_)
						throw new Exception(format("%s: '%s' operands must be bool",
							ctx, expr.kind == K.and_ ? "and" : "or"));
				}
				break;
			case K.less_than, K.greater_than:
				validateExpr(expr.operands[0], ctx, allowIsProject);
				validateExpr(expr.operands[1], ctx, allowIsProject);
				if (expr.operands[0].resultType() != DiscoverExpr.ValueType.int_ ||
				    expr.operands[1].resultType() != DiscoverExpr.ValueType.int_)
					throw new Exception(format(
						"%s: 'less_than'/'greater_than' operands must be int", ctx));
				break;
			case K.equals_:
				validateExpr(expr.operands[0], ctx, allowIsProject);
				validateExpr(expr.operands[1], ctx, allowIsProject);
				if (expr.operands[0].resultType() != expr.operands[1].resultType())
					throw new Exception(format(
						"%s: 'equals' operands must have matching types", ctx));
				break;
		}
	}
}

// ---------------------------------------------------------------------------
// Bring ConfigParser into scope for the fromYAML hook
// ---------------------------------------------------------------------------

import configy.read : ConfigParser;

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
// runDiscover — entry point for the CLI subcommand
// ---------------------------------------------------------------------------

/// Handle the discover subcommand.
/// Writes a JSON array of {path, name} objects to stdout and exits.
void runDiscover(string root, string name,
	string isProjectJson, string recurseWhenJson, string[] exclude)
{
	import std.json : JSONValue, parseJSON;
	import std.stdio : writeln;

	ProjectDiscoveryConfig pdConfig;
	if (isProjectJson.length > 0)
		pdConfig.is_project = DiscoverExpr.fromJson(parseJSON(isProjectJson));
	if (recurseWhenJson.length > 0)
		pdConfig.recurse_when = DiscoverExpr.fromJson(parseJSON(recurseWhenJson));

	auto projects = discoverProjects(root, name, exclude, pdConfig);

	JSONValue[] arr;
	foreach (ref p; projects)
		arr ~= JSONValue(["path": JSONValue(p.path), "name": JSONValue(p.name)]);

	writeln(JSONValue(arr).toString());
}

// ---------------------------------------------------------------------------
// discoverProjects — main discovery entry point
// ---------------------------------------------------------------------------

/// Discover projects within a workspace using configurable expressions.
DiscoveredProject[] discoverProjects(
	string root, string name, string[] exclude, ProjectDiscoveryConfig pdConfig)
{
	import std.path : expandTilde;

	root = expandTilde(root);

	if (!exists(root) || !isDir(root))
		return null;

	// Resolve is_project expression (default: has_entry: .git)
	auto isProjectExpr = pdConfig.is_project.isConfigured
		? pdConfig.is_project
		: DiscoverExpr(DiscoverExpr.Kind.has_entry, ".git");

	// Resolve recurse_when expression
	// Default: and: [not: $is_project, less_than: [$depth, 3]]
	DiscoverExpr recurseWhenExpr;
	if (pdConfig.recurse_when.isConfigured)
		recurseWhenExpr = pdConfig.recurse_when;
	else
	{
		auto notIsProject = DiscoverExpr(DiscoverExpr.Kind.not_, null, 0,
			[DiscoverExpr(DiscoverExpr.Kind.var_is_project)]);
		auto depthCheck = DiscoverExpr(DiscoverExpr.Kind.less_than, null, 0,
			[DiscoverExpr(DiscoverExpr.Kind.var_depth),
			 DiscoverExpr(DiscoverExpr.Kind.int_literal, null, 3)]);
		recurseWhenExpr = DiscoverExpr(DiscoverExpr.Kind.and_, null, 0,
			[notIsProject, depthCheck]);
	}

	DiscoveredProject[] results;

	// Evaluate root like any other directory at depth 0
	auto rootCtx = EvalContext(root, baseName(root), ".", 0);
	bool rootIsProject = isProjectExpr.evaluateBool(rootCtx);
	if (rootIsProject)
		results ~= DiscoveredProject(name, root, baseName(root));

	rootCtx.isProjectAvailable = true;
	rootCtx.isProjectValue = rootIsProject;
	if (recurseWhenExpr.evaluateBool(rootCtx))
		scanDir(root, root, 1, exclude, name, isProjectExpr, recurseWhenExpr, results);

	return results;
}

// ---------------------------------------------------------------------------
// scanDir — recursive directory scanner
// ---------------------------------------------------------------------------

private void scanDir(string dir, string wsRoot, uint depth,
	const(string)[] exclude, string wsName,
	ref const DiscoverExpr isProjectExpr, ref const DiscoverExpr recurseWhenExpr,
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
			auto ctx = EvalContext(entry.name, dirName, relPath, depth);

			// Evaluate is_project
			bool isProj = isProjectExpr.evaluateBool(ctx);

			if (isProj)
				results ~= DiscoveredProject(wsName, entry.name, relPath);

			// Evaluate recurse_when (with $is_project available)
			ctx.isProjectAvailable = true;
			ctx.isProjectValue = isProj;
			if (recurseWhenExpr.evaluateBool(ctx))
				scanDir(entry.name, wsRoot, depth + 1, exclude, wsName,
					isProjectExpr, recurseWhenExpr, results);
		}
	}
	catch (Exception e)
	{
		warningf("scanDir: error scanning %s: %s", dir, e.msg);
	}
}
