module cydo.domain.usage.claude_usage;

import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.typecons : Nullable;

import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
import ae.utils.promise : Promise;

@JSONPartial struct ClaudeUsageWindow
{
	Nullable!double utilization;
	Nullable!string resets_at;
}

@JSONPartial struct ClaudeModelUsageWindow
{
	string display_name;
	Nullable!double utilization;
	Nullable!string resets_at;
}

@JSONPartial struct ClaudeRateLimits
{
	@JSONOptional Nullable!ClaudeUsageWindow five_hour;
	@JSONOptional Nullable!ClaudeUsageWindow seven_day;
	@JSONOptional Nullable!(ClaudeModelUsageWindow[]) model_scoped;
}

@JSONPartial struct ClaudeUsageReport
{
	bool rate_limits_available;
	Nullable!ClaudeRateLimits rate_limits;
}

ClaudeUsageReport parseClaudeUsageReport(string json)
{
	auto report = parseJSON(json);
	requireMembers(report, "rate_limits_available", "rate_limits");
	auto limits = report["rate_limits"];
	if (limits.type != JSONType.null_)
	{
		foreach (name; ["five_hour", "seven_day"])
			if (auto window = name in limits.object)
				if (window.type != JSONType.null_)
					requireMembers(*window, "utilization", "resets_at");

		if (auto models = "model_scoped" in limits.object)
			if (models.type != JSONType.null_)
				foreach (model; models.array)
					requireMembers(model, "display_name", "utilization", "resets_at");
	}
	return jsonParse!ClaudeUsageReport(json);
}

private void requireMembers(JSONValue object, string[] members...)
{
	foreach (member; members)
		enforce(member in object.object, "Claude usage response is missing " ~ member);
}

unittest
{
	import std.exception : assertThrown;

	foreach (json; [
		`{"rate_limits":null}`,
		`{"rate_limits_available":true}`,
		`{"rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":null}}}`,
		`{"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":null}}}`,
		`{"rate_limits_available":true,"rate_limits":{"model_scoped":[{"utilization":null,"resets_at":null}]}}`,
		`{"rate_limits_available":true,"rate_limits":{"model_scoped":[{"display_name":"Fable","resets_at":null}]}}`,
		`{"rate_limits_available":true,"rate_limits":{"model_scoped":[{"display_name":"Fable","utilization":null}]}}`,
	])
		assertThrown!Exception(parseClaudeUsageReport(json));

	assert(parseClaudeUsageReport(`{"rate_limits_available":false,"rate_limits":null}`).rate_limits.isNull);
	auto limits = parseClaudeUsageReport(`{"rate_limits_available":true,"rate_limits":{
		"five_hour":{"utilization":null,"resets_at":null},
		"model_scoped":[{"display_name":"Fable","utilization":null,"resets_at":null}]
	}}`).rate_limits.get;
	assert(limits.five_hour.get.utilization.isNull);
	assert(limits.model_scoped.get[0].resets_at.isNull);
}

interface UsageSource
{
	Promise!ClaudeUsageReport requestUsage();
	@property bool alive();
}
