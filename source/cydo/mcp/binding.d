/// Compile-time MCP tool binding.
///
/// Generates MCP tool metadata and dispatch logic from D interface
/// definitions with UDAs, analogous to ae.net.jsonrpc.binding.
module cydo.mcp.binding;

import std.traits : FunctionTypeOf, isCallable, Parameters, ParameterIdentifierTuple, ReturnType;

import ae.utils.json : JSONFragment, jsonParse;
import ae.utils.meta : hasAttribute, getAttribute;

import cydo.mcp : Description, McpName, McpResult;

/// Get the MCP tool name for a method.
/// Uses @McpName if present, otherwise the D method name.
template getMcpToolName(alias method, string defaultName)
{
	static if (hasAttribute!(McpName, method))
		enum getMcpToolName = getAttribute!(McpName, method).name;
	else
		enum getMcpToolName = defaultName;
}

/// Map a D type to a JSON Schema type string.
template jsonSchemaType(T)
{
	static if (is(T == string))
		enum jsonSchemaType = `"string"`;
	else static if (is(T == bool))
		enum jsonSchemaType = `"boolean"`;
	else static if (is(T == int) || is(T == long) || is(T == uint) || is(T == ulong))
		enum jsonSchemaType = `"integer"`;
	else static if (is(T == float) || is(T == double))
		enum jsonSchemaType = `"number"`;
	else
		static assert(false, "Unsupported MCP parameter type: " ~ T.stringof);
}

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

/// Generate the tools/list result JSON for an interface.
string mcpToolListJson(I)()
{
	string tools;
	bool first = true;

	static foreach (memberName; __traits(allMembers, I))
	{
		static if (isToolMethod!(I, memberName))
		{{
			alias method = __traits(getMember, I, memberName);
			enum toolName = getMcpToolName!(method, memberName);

			if (!first) tools ~= ",";
			first = false;

			tools ~= `{"name":"` ~ jsonEscape(toolName) ~ `"`;

			static if (hasAttribute!(Description, method))
				tools ~= `,"description":"` ~ jsonEscape(getAttribute!(Description, method).text) ~ `"`;

			tools ~= `,"inputSchema":` ~ generateInputSchema!(I, memberName);
			tools ~= `}`;
		}}
	}

	return `{"tools":[` ~ tools ~ `]}`;
}

/// Generate inputSchema JSON for a method's parameters.
string generateInputSchema(I, string memberName)()
{
	alias method = __traits(getMember, I, memberName);
	alias Params = Parameters!method;
	alias ParamNames = ParameterIdentifierTuple!method;

	static if (Params.length == 0)
		return `{"type":"object","properties":{}}`;

	string props;
	string required;

	// Use __parameters to access parameter UDAs
	static if (is(FunctionTypeOf!method PT == __parameters))
	{
		static foreach (i, P; Params)
		{{
			static if (i > 0)
			{
				props ~= ",";
				required ~= ",";
			}

			enum paramName = ParamNames[i];
			props ~= `"` ~ paramName ~ `":{"type":` ~ jsonSchemaType!P;

			// Extract @Description from parameter UDAs
			static foreach (uda; __traits(getAttributes, PT[i .. i + 1]))
			{
				static if (is(typeof(uda) == Description))
					props ~= `,"description":"` ~ jsonEscape(uda.text) ~ `"`;
			}

			props ~= `}`;
			required ~= `"` ~ paramName ~ `"`;
		}}
	}

	return `{"type":"object","properties":{` ~ props ~ `},"required":[` ~ required ~ `]}`;
}

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

/// Runtime-callable JSON string escaping (same logic as jsonEscape).
string jsonEscapeRuntime(string s) { return jsonEscape(s); }

/// Escape a string for embedding in a JSON string literal.
/// Usable at compile time (CTFE-compatible).
private string jsonEscape(string s)
{
	string result;
	foreach (c; s)
	{
		switch (c)
		{
			case '"':  result ~= `\"`; break;
			case '\\': result ~= `\\`; break;
			case '\n': result ~= `\n`; break;
			case '\r': result ~= `\r`; break;
			case '\t': result ~= `\t`; break;
			default:   result ~= c; break;
		}
	}
	return result;
}
