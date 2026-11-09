module cydo.domain.policy.permissions;

import core.time : Duration;
import std.logger : warningf;

import ae.utils.json : JSONFragment, toJson;

import cydo.protocol : PermissionAllow, PermissionDeny;

import uninode.node : UniNode;

string makePermissionAllowJson(string inputJson)
{
	return toJson(PermissionAllow("allow", JSONFragment(inputJson)));
}

string makePermissionDenyJson(string message)
{
	return toJson(PermissionDeny("deny", message));
}

/// Convert a JSON string to a UniNode for use as a Djinja template context variable.
UniNode jsonToUniNode(string json)
{
	import std.json : parseJSON, JSONValue, JSONType;

	UniNode convert(JSONValue v)
	{
		final switch (v.type)
		{
		case JSONType.null_:   return UniNode(null);
		case JSONType.string:  return UniNode(v.str);
		case JSONType.integer: return UniNode(v.integer);
		case JSONType.uinteger: return UniNode(v.uinteger);
		case JSONType.float_:  return UniNode(v.floating);
		case JSONType.true_:   return UniNode(true);
		case JSONType.false_:  return UniNode(false);
		case JSONType.array:
			UniNode[] seq;
			foreach (ref el; v.array)
				seq ~= convert(el);
			return UniNode(seq);
		case JSONType.object:
			UniNode[string] map;
			foreach (key, ref val; v.objectNoRef)
				map[key] = convert(val);
			return UniNode(map);
		}
	}

	try
		return convert(parseJSON(json));
	catch (Exception)
		return UniNode(null);
}

/// How a workspace decides on tool calls, from its configuration.
struct PermissionSettings
{
	/// "allow", "deny", "ask", "auto", or a Djinja expression rendering
	/// one of them; empty = defaultPermissionPolicy.
	string policy;
	/// Whether Claude Code's auto mode classifier judges the calls the
	/// policy leaves to it ("auto").
	bool autoMode;
	/// How long a permission prompt waits for a person before it denies;
	/// zero = indefinitely.
	Duration promptTimeout;

	/// Whether the host must answer the agent's permission requests, as
	/// opposed to letting every tool call run.
	@property bool hostDecides() const
	{
		return policy.length > 0 || autoMode;
	}
}

/// What a permission policy rules for one tool call.
enum ToolCallDecision
{
	allow,
	deny,
	ask,        /// prompt a person
	classifier, /// leave it to the auto mode classifier ("auto")
}

struct ToolCallRuling
{
	ToolCallDecision decision;
	string denyReason; /// for `deny`: shown to the agent
}

/// The policy of a workspace that configures none.
enum defaultPermissionPolicy = `{{ "auto" if auto_mode else "allow" }}`;

/// Evaluate a permission policy for one tool call. Returns "allow", "deny",
/// "ask", or "auto" (leave it to the auto mode classifier).
string evaluatePermissionPolicy(string policy, bool autoMode, string toolName,
	string inputJson)
{
	if (policy.length == 0)
		policy = defaultPermissionPolicy;
	if (isPermissionDecision(policy))
		return policy;

	// Evaluate as Djinja template expression
	try
	{
		import djinja.djinja : loadData;
		import djinja.render : Render;
		import std.string : strip;

		auto renderer = new Render(loadData(policy));

		UniNode[string] ctx;
		ctx["tool_name"] = UniNode(toolName);
		ctx["input"] = jsonToUniNode(inputJson);
		ctx["auto_mode"] = UniNode(autoMode);

		string result = renderer.render(UniNode(ctx)).strip();

		if (isPermissionDecision(result))
			return result;

		warningf("Permission policy expression returned invalid value %(%s%), defaulting to deny", [result]);
		return "deny";
	}
	catch (Exception e)
	{
		warningf("Permission policy expression evaluation failed: %s", e.msg);
		return "deny";
	}
}

private bool isPermissionDecision(string value)
{
	return value == "allow" || value == "deny" || value == "ask" || value == "auto";
}

unittest
{
	assert(evaluatePermissionPolicy("", false, "Bash", `{}`) == "allow");
	assert(evaluatePermissionPolicy("", true, "Bash", `{}`) == "auto");
	assert(evaluatePermissionPolicy("auto", false, "Bash", `{}`) == "auto");
	enum policy = `{{ "ask" if tool_name == "Bash" else ("auto" if auto_mode else "allow") }}`;
	assert(evaluatePermissionPolicy(policy, true, "Bash", `{}`) == "ask");
	assert(evaluatePermissionPolicy(policy, true, "Read", `{}`) == "auto");
	assert(evaluatePermissionPolicy(policy, false, "Read", `{}`) == "allow");
}
