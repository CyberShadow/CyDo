module cydo.domain.usage.poller;

// Parsing for the Claude usage endpoint (GET <api>/api/oauth/usage), the one
// Claude Code's /usage reads. The request and its schedule live in the server
// host; this module holds the pure, testable part.

import ae.utils.json : JSONOptional, JSONName, JSONExtras, jsonParse;

// ── /api/oauth/usage response shape (only the fields used) ──────────────────

struct UsageWindow
{
	@JSONOptional double utilization = double.nan;
	@JSONOptional string resets_at;
	JSONExtras extras;
}

struct UsageScopeModel
{
	@JSONOptional string id;
	@JSONOptional string display_name;
	JSONExtras extras;
}

struct UsageScope
{
	@JSONOptional UsageScopeModel model;
	JSONExtras extras;
}

struct UsageLimit
{
	@JSONOptional string kind;
	@JSONOptional string group;
	@JSONOptional double percent = double.nan;
	@JSONOptional string severity;
	@JSONOptional bool is_active;
	@JSONOptional string resets_at;
	@JSONName("scope") @JSONOptional UsageScope* scope_; // "scope" is a D keyword; pointer so JSON null parses
	JSONExtras extras;
}

struct UsageResponse
{
	@JSONOptional UsageWindow five_hour;
	@JSONOptional UsageWindow seven_day;
	@JSONOptional UsageLimit[] limits;
	JSONExtras extras;
}

/// Parse the usage endpoint body. Returns UsageResponse.init on failure (the
/// caller treats a failed poll as a no-op, keeping prior state).
UsageResponse parseUsageResponse(string body)
{
	try
		return jsonParse!UsageResponse(body);
	catch (Exception)
		return UsageResponse.init;
}

/// Parse an ISO-8601 timestamp to a unix epoch (seconds). Returns 0 on failure.
long isoToEpoch(string iso)
{
	import std.datetime.systime : SysTime;
	if (iso.length == 0)
		return 0;
	try
		return SysTime.fromISOExtString(iso).toUnixTime;
	catch (Exception)
		return 0;
}

struct ScopedModelUsage
{
	bool found;
	string displayName; // e.g. "Fable"
	double percent = double.nan;
	long resetsAt;
}

/// The single model-scoped usage row (the one limits[] entry with a non-empty
/// scope.model.display_name), for the per-model banner row. found=false unless
/// exactly one scoped row is present.
ScopedModelUsage scopedModelRow(ref const UsageResponse resp)
{
	const(UsageLimit)*[] scoped;
	foreach (ref l; resp.limits)
		if (l.scope_ !is null && l.scope_.model.display_name.length > 0)
			scoped ~= &l;
	if (scoped.length != 1)
		return ScopedModelUsage.init;
	auto s = scoped[0];
	return ScopedModelUsage(true, s.scope_.model.display_name, s.percent,
		isoToEpoch(s.resets_at));
}

unittest
{
	// real-shaped response, with one model-scoped weekly row
	enum body = `{"five_hour":{"utilization":8.0,"resets_at":"2026-07-15T06:40:00+00:00"},`
		~ `"seven_day":{"utilization":54.0,"resets_at":"2026-07-17T12:00:00+00:00"},`
		~ `"seven_day_opus":null,"seven_day_sonnet":null,`
		~ `"limits":[`
		~ `{"kind":"session","group":"session","percent":8,"severity":"normal","resets_at":"2026-07-15T06:40:00+00:00","scope":null,"is_active":false},`
		~ `{"kind":"weekly_all","group":"weekly","percent":54,"severity":"normal","resets_at":"2026-07-17T12:00:00+00:00","scope":null,"is_active":false},`
		~ `{"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-07-17T12:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}`;

	auto resp = parseUsageResponse(body);
	assert(resp.limits.length == 3);
	assert(resp.five_hour.utilization == 8.0);
	assert(resp.seven_day.utilization == 54.0);
	assert(isoToEpoch(resp.seven_day.resets_at) == 1784289600);

	auto sm = scopedModelRow(resp);
	assert(sm.found && sm.displayName == "Fable" && sm.percent == 100
		&& sm.resetsAt == 1784289600);

	// no scoped row: nothing to show for a model
	enum unscoped = `{"limits":[`
		~ `{"kind":"session","group":"session","percent":5,"scope":null,"is_active":false},`
		~ `{"kind":"weekly_all","group":"weekly","percent":30,"scope":null,"is_active":false}]}`;
	auto resp2 = parseUsageResponse(unscoped);
	assert(!scopedModelRow(resp2).found);

	// a malformed body parses to an empty response
	assert(parseUsageResponse("not json").limits.length == 0);
	assert(isoToEpoch("not a time") == 0);
}
