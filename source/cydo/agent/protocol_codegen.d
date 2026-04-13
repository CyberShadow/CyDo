/// CTFE-based TypeScript codegen for cydo.agent.protocol structs.
/// Emits TypeScript interface declarations to stdout.
module cydo.agent.protocol_codegen;

import std.meta : AliasSeq, Filter, staticIndexOf, templateNot;
import std.traits : Fields, FieldNameTuple, isArray, ForeachType;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONExtras;
import cydo.agent.protocol;

// ---------------------------------------------------------------------------
// Compile-time type name mapping
// ---------------------------------------------------------------------------

template tsTypeName(T)
{
	static if (is(T == string))
		enum tsTypeName = "string";
	else static if (is(T == bool))
		enum tsTypeName = "boolean";
	else static if (is(T == int) || is(T == double) || is(T == float) || is(T == long))
		enum tsTypeName = "number";
	else static if (is(T == JSONFragment))
		enum tsTypeName = "unknown";
	else static if (is(T == JSONExtras))
		enum tsTypeName = "__jsonextras__";
	else static if (isArray!T && !is(T == string))
		enum tsTypeName = tsTypeName!(ForeachType!T) ~ "[]";
	else static if (is(T == struct))
		enum tsTypeName = T.stringof;
	else
		enum tsTypeName = "unknown";
}

// ---------------------------------------------------------------------------
// UDA helpers
// ---------------------------------------------------------------------------

template hasUDA(alias sym, UDA)
{
	enum hasUDA = (){
		foreach (attr; __traits(getAttributes, sym))
			static if (is(typeof(attr) == UDA) || is(attr == UDA))
				return true;
		return false;
	}();
}

template getJSONName(alias sym)
{
	enum getJSONName = (){
		foreach (attr; __traits(getAttributes, sym))
			static if (is(typeof(attr) == JSONName))
				return attr.name;
		return null;
	}();
}

// ---------------------------------------------------------------------------
// Automatic struct discovery
// ---------------------------------------------------------------------------

// Detect event structs: structs with a `string type` field whose .init
// contains '/' (e.g. "item/started").
template isEventStruct(T)
{
	static if (!is(T == struct))
		enum isEventStruct = false;
	else
		enum isEventStruct = (){
			static foreach (i, FT; Fields!T)
				static if (is(FT == string) && FieldNameTuple!T[i] == "type")
					if (T.init.tupleof[i].length > 0)
						foreach (c; T.init.tupleof[i])
							if (c == '/') return true;
			return false;
		}();
}

// Collect all structs from the protocol module using recursive expansion.
private template _buildProtocolStructList(names...)
{
	static if (names.length == 0)
		alias _buildProtocolStructList = AliasSeq!();
	else
	{
		alias _T = __traits(getMember, cydo.agent.protocol, names[0]);
		static if (is(_T == struct))
			alias _buildProtocolStructList = AliasSeq!(_T, _buildProtocolStructList!(names[1 .. $]));
		else
			alias _buildProtocolStructList = _buildProtocolStructList!(names[1 .. $]);
	}
}

alias allProtocolStructs = _buildProtocolStructList!(__traits(allMembers, cydo.agent.protocol));

// Filter to event structs only.
alias EventStructs = Filter!(isEventStruct, allProtocolStructs);

// ---------------------------------------------------------------------------
// Dependency collection
// ---------------------------------------------------------------------------

// Check if a struct type T is referenced in any field of any EventStruct.
template isReferencedByEvents(T)
{
	enum isReferencedByEvents = (){
		static foreach (E; EventStructs)
			static foreach (i, FT; Fields!E)
			{
				static if (is(FT == T))
					return true;
				else static if (isArray!FT && is(ForeachType!FT == T))
					return true;
			}
		return false;
	}();
}

// Non-event protocol structs that are referenced by event structs (deps).
alias DepStructs = Filter!(isReferencedByEvents, Filter!(templateNot!isEventStruct, allProtocolStructs));

// ---------------------------------------------------------------------------
// Code generation
// ---------------------------------------------------------------------------

string generateStruct(S)() pure
{
	string out_ = "export interface " ~ S.stringof ~ " {\n";
	bool hasExtras = false;

	static foreach (i, FT; Fields!S)
	{{
		enum fname = FieldNameTuple!S[i];

		// JSONExtras — emit as index signature at end, skip the field itself
		static if (is(FT == JSONExtras))
		{
			hasExtras = true;
		}
		// Skip `extras` fields of type JSONFragment: the index signature covers these
		else static if (is(FT == JSONFragment) && fname == "extras")
		{
			// skip
		}
		else
		{
			// Pass S.tupleof[i] directly to UDA helpers — no alias needed
			enum jsonName = getJSONName!(S.tupleof[i]);
			enum fieldKey = (jsonName !is null && jsonName.length > 0) ? jsonName : fname;
			enum optional = hasUDA!(S.tupleof[i], JSONOptional);
			enum tsType = tsTypeName!FT;

			// Emit string `type` field as a literal type if it has a non-empty default
			static if (is(FT == string) && fname == "type")
			{
				enum defaultVal = S.init.tupleof[i];
				static if (defaultVal.length > 0)
					out_ ~= "  " ~ fieldKey ~ ": \"" ~ defaultVal ~ "\";\n";
				else
					out_ ~= "  " ~ fieldKey ~ (optional ? "?: " : ": ") ~ tsType ~ ";\n";
			}
			else
			{
				out_ ~= "  " ~ fieldKey ~ (optional ? "?: " : ": ") ~ tsType ~ ";\n";
			}
		}
	}}

	if (hasExtras)
		out_ ~= "  [key: string]: unknown;\n";

	out_ ~= "}\n";
	return out_;
}

string generateAll() pure
{
	string out_;

	// Dependency structs first (so they're declared before event structs reference them)
	static foreach (S; DepStructs)
		out_ ~= generateStruct!S() ~ "\n";

	// Event structs
	static foreach (S; EventStructs)
		out_ ~= generateStruct!S() ~ "\n";

	return out_;
}

// Compute the entire output at compile time.
enum tsOutput = generateAll();

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void main(string[] args)
{
	import std.stdio : write, File;
	if (args.length > 1)
	{
		auto f = File(args[1], "w");
		f.write(tsOutput);
	}
	else
	{
		write(tsOutput);
	}
}
