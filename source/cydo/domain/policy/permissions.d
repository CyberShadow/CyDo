module cydo.domain.policy.permissions;

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

/// Evaluate a permission policy string. Returns "allow", "deny", or "ask".
string evaluatePermissionPolicy(string policy, string toolName, string inputJson)
{
	if (policy == "allow" || policy == "deny" || policy == "ask")
		return policy;

	// Empty policy defaults to allow
	if (policy.length == 0)
		return "allow";

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

		string result = renderer.render(UniNode(ctx)).strip();

		if (result == "allow" || result == "deny" || result == "ask")
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
