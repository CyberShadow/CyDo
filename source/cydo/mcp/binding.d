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

/// Generate a complete JSON Schema object string for a D type.
/// Handles primitives, arrays, and structs (with @Description on fields).
template jsonSchemaFor(T)
{
	static if (is(T == string))
		enum jsonSchemaFor = `{"type":"string"}`;
	else static if (is(T == bool))
		enum jsonSchemaFor = `{"type":"boolean"}`;
	else static if (is(T == int) || is(T == long) || is(T == uint) || is(T == ulong))
		enum jsonSchemaFor = `{"type":"integer"}`;
	else static if (is(T == float) || is(T == double))
		enum jsonSchemaFor = `{"type":"number"}`;
	else static if (is(T : E[], E) && !is(T == string))
		enum jsonSchemaFor = `{"type":"array","items":` ~ jsonSchemaFor!E ~ `}`;
	else static if (is(T == struct))
		enum jsonSchemaFor = generateStructSchema!T();
	else
		static assert(false, "Unsupported MCP parameter type: " ~ T.stringof);
}

/// Generate JSON Schema for a struct type, including @Description on fields.
private string generateStructSchema(T)()
{
	string props;
	string required;
	bool first = true;

	static foreach (i, field; T.tupleof)
	{{
		if (!first) { props ~= ","; required ~= ","; }
		first = false;

		enum fieldName = __traits(identifier, field);
		string schema = jsonSchemaFor!(typeof(field));

		// Inject @Description from field UDAs
		static foreach (uda; __traits(getAttributes, field))
		{
			static if (is(typeof(uda) == Description))
				schema = injectIntoSchema(schema, `"description":"` ~ jsonEscape(uda.text) ~ `"`);
		}

		props ~= `"` ~ fieldName ~ `":` ~ schema;
		required ~= `"` ~ fieldName ~ `"`;
	}}

	return `{"type":"object","properties":{` ~ props ~ `},"required":[` ~ required ~ `]}`;
}

/// Inject an extra JSON field into a schema object (inserts before the closing brace).
private string injectIntoSchema(string schema, string extraField)
{
	return schema[0 .. $ - 1] ~ `,` ~ extraField ~ `}`;
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
			string schema = jsonSchemaFor!P;

			// Inject @Description from parameter UDAs
			static foreach (uda; __traits(getAttributes, PT[i .. i + 1]))
			{
				static if (is(typeof(uda) == Description))
					schema = injectIntoSchema(schema, `"description":"` ~ jsonEscape(uda.text) ~ `"`);
			}

			props ~= `"` ~ paramName ~ `":` ~ schema;
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
