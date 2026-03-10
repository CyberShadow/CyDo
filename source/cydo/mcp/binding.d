/// Compile-time MCP tool binding.
///
/// Generates MCP tool metadata and dispatch logic from D interface
/// definitions with UDAs, analogous to ae.net.jsonrpc.binding.
module cydo.mcp.binding;

import std.traits : FunctionTypeOf, isCallable, Parameters, ParameterIdentifierTuple, ReturnType;

import ae.utils.json : JSONFragment, JSONOptional, jsonParse, toJson;
import ae.utils.meta : hasAttribute, getAttribute;

import cydo.mcp : Description, McpName, McpResult;

// ---- JSON Schema structs ----

/// JSON Schema object, serialized via ae.utils.json.toJson.
/// Optional fields are omitted when at their default (null) value.
struct SchemaObj
{
	string type;
	@JSONOptional string description;
	@JSONOptional JSONFragment items;            /// Element schema for arrays (pre-serialized).
	@JSONOptional SchemaObj[string] properties;  /// Named property schemas for objects.
	@JSONOptional string[] required;             /// Required property names for objects.
}

/// A single MCP tool definition.
struct ToolDef
{
	string name;
	@JSONOptional string description;
	SchemaObj inputSchema;
}

/// Top-level tools/list response body.
struct ToolsList
{
	ToolDef[] tools;
}

// ---- Tool name resolution ----

/// Get the MCP tool name for a method.
/// Uses @McpName if present, otherwise the D method name.
template getMcpToolName(alias method, string defaultName)
{
	static if (hasAttribute!(McpName, method))
		enum getMcpToolName = getAttribute!(McpName, method).name;
	else
		enum getMcpToolName = defaultName;
}

// ---- Schema generation ----

/// Generate a SchemaObj for a D type.
/// Handles primitives, arrays, and structs (with @Description on fields).
SchemaObj jsonSchemaFor(T)()
{
	SchemaObj s;

	static if (is(T == string))
		s.type = "string";
	else static if (is(T == bool))
		s.type = "boolean";
	else static if (is(T == int) || is(T == long) || is(T == uint) || is(T == ulong))
		s.type = "integer";
	else static if (is(T == float) || is(T == double))
		s.type = "number";
	else static if (is(T : E[], E) && !is(T == string))
	{
		s.type = "array";
		s.items = JSONFragment(toJson(jsonSchemaFor!E()));
	}
	else static if (is(T == struct))
		return generateStructSchema!T();
	else
		static assert(false, "Unsupported MCP parameter type: " ~ T.stringof);

	return s;
}

/// Generate a SchemaObj for a struct type, including @Description on fields.
private SchemaObj generateStructSchema(T)()
{
	SchemaObj s;
	s.type = "object";

	static foreach (i, field; T.tupleof)
	{{
		enum fieldName = __traits(identifier, field);
		auto propSchema = jsonSchemaFor!(typeof(field))();

		static foreach (uda; __traits(getAttributes, field))
		{
			static if (is(typeof(uda) == Description))
				propSchema.description = uda.text;
		}

		s.properties[fieldName] = propSchema;
		s.required ~= fieldName;
	}}

	return s;
}

// ---- Tool metadata generation ----

/// Check if a member is a valid tool method (returns McpResult).
template isToolMethod(I, string memberName)
{
	static if (__traits(compiles, __traits(getMember, I, memberName)))
	{
		alias member = __traits(getMember, I, memberName);
		static if (isCallable!member)
			enum isToolMethod = is(ReturnType!member == McpResult);
		else
			enum isToolMethod = false;
	}
	else
		enum isToolMethod = false;
}

/// Generate ToolDef[] from an interface using compile-time introspection.
private ToolDef[] mcpToolDefs(I)()
{
	ToolDef[] tools;

	static foreach (memberName; __traits(allMembers, I))
	{
		static if (isToolMethod!(I, memberName))
		{{
			alias method = __traits(getMember, I, memberName);

			ToolDef tool;
			tool.name = getMcpToolName!(method, memberName);

			static if (hasAttribute!(Description, method))
				tool.description = getAttribute!(Description, method).text;

			tool.inputSchema = generateInputSchema!(I, memberName)();
			tools ~= tool;
		}}
	}

	return tools;
}

/// Generate the inputSchema for a method's parameters.
SchemaObj generateInputSchema(I, string memberName)()
{
	alias method = __traits(getMember, I, memberName);
	alias Params = Parameters!method;
	alias ParamNames = ParameterIdentifierTuple!method;

	SchemaObj s;
	s.type = "object";

	static if (Params.length == 0)
		return s;

	// Use __parameters to access parameter UDAs
	static if (is(FunctionTypeOf!method PT == __parameters))
	{
		static foreach (i, P; Params)
		{{
			enum paramName = ParamNames[i];
			auto propSchema = jsonSchemaFor!P();

			// Inject @Description from parameter UDAs
			static foreach (uda; __traits(getAttributes, PT[i .. i + 1]))
			{
				static if (is(typeof(uda) == Description))
					propSchema.description = uda.text;
			}

			s.properties[paramName] = propSchema;
			s.required ~= paramName;
		}}
	}

	return s;
}

// ---- Tool dispatch ----

/// MCP tool dispatcher. Dispatches tools/call requests to interface methods.
struct McpToolDispatcher(I) if (is(I == interface))
{
	private I impl;

	this(I implementation)
	{
		this.impl = implementation;
	}

	/// Dispatch a tool call by name with JSON arguments.
	/// Returns the tool result.
	McpResult dispatch(string toolName, JSONFragment args)
	{
		switch (toolName)
		{
			static foreach (memberName; __traits(allMembers, I))
			{
				static if (isToolMethod!(I, memberName))
				{
					case getMcpToolName!(__traits(getMember, I, memberName), memberName):
						return callMethod!memberName(args);
				}
			}

			default:
				return McpResult("Unknown tool: " ~ toolName, true);
		}
	}

	private McpResult callMethod(string memberName)(JSONFragment args)
	{
		alias method = __traits(getMember, I, memberName);
		alias Params = Parameters!method;
		alias ParamNames = ParameterIdentifierTuple!method;

		static if (Params.length == 0)
		{
			try
				return __traits(getMember, impl, memberName)();
			catch (Exception e)
				return McpResult("Tool error: " ~ e.msg, true);
		}
		else
		{
			// Parse named parameters from JSON object
			JSONFragment[string] argsObj;
			try
				argsObj = args.json.jsonParse!(JSONFragment[string]);
			catch (Exception e)
				return McpResult("Invalid arguments: " ~ e.msg, true);

			Params callArgs;
			static foreach (i, P; Params)
			{{
				enum paramName = ParamNames[i];
				auto val = paramName in argsObj;
				if (val is null)
					return McpResult("Missing required parameter: " ~ paramName, true);
				try
					callArgs[i] = (*val).json.jsonParse!P;
				catch (Exception e)
					return McpResult("Invalid parameter '" ~ paramName ~ "': " ~ e.msg, true);
			}}

			try
				return __traits(getMember, impl, memberName)(callArgs);
			catch (Exception e)
				return McpResult("Tool error: " ~ e.msg, true);
		}
	}
}

/// Create a dispatcher for an interface implementation.
McpToolDispatcher!I mcpToolDispatcher(I)(I impl) if (is(I == interface))
{
	return McpToolDispatcher!I(impl);
}

// ---- Utilities ----

/// Build the final tools/list JSON by substituting {{placeholders}} in tool
/// descriptions. Tools whose placeholder values are empty are excluded entirely.
/// Shared by the MCP server and --dump-context.
string buildToolsListJson(I)(string[string] vars)
{
	import std.algorithm : canFind;
	import std.array : replace;

	// Cache the template tool definitions (generated from interface on first call)
	static ToolDef[] templateTools;
	if (templateTools is null)
		templateTools = mcpToolDefs!I();

	// Filter out tools with empty placeholder values, substitute the rest
	ToolDef[] result;
	outer: foreach (ref tool; templateTools)
	{
		foreach (key, value; vars)
		{
			if (value.length == 0 && tool.description.canFind("{{" ~ key ~ "}}"))
				continue outer;
		}
		// Shallow copy — only description is modified; schema references are safe to share
		ToolDef copy = tool;
		foreach (key, value; vars)
			copy.description = copy.description.replace("{{" ~ key ~ "}}", value);
		result ~= copy;
	}

	return toJson(ToolsList(result));
}
