module cydo.domain.usage.tracker;

import std.math : fabs, isFinite, isNaN;

import ae.utils.json : JSONOptional, jsonParse, toJson;

import cydo.agent.protocol : SessionRateLimitEvent;

private struct AgentUsageLimitWindowMessage
{
	@JSONOptional double utilization;
	@JSONOptional double resetsAt;
	@JSONOptional string status;
}

private struct AgentUsageMessage
{
	string type = "agent_usage";
	string agent;
	long updated_at;
	AgentUsageLimitWindowMessage[string] limits;
}

private struct AgentUsageLimitWindowState
{
	bool hasUtilization;
	double utilization;
	bool hasResetsAt;
	double resetsAt;
	bool hasStatus;
	string status;
}

private struct AgentUsageState
{
	string agent;
	long updatedAt;
	AgentUsageLimitWindowState[string] limits;
}

class AgentUsageTracker
{
	private AgentUsageState[string] agentUsageByAgent;

	string[] snapshotMessages()
	{
		string[] payloads;
		foreach (ref usageState; agentUsageByAgent)
			payloads ~= toJson(buildAgentUsageMessage(usageState));
		return payloads;
	}

	bool updateFromClaudeEvent(string agentType, string translated, out string payload)
	{
		import std.datetime.systime : Clock;

		if (agentType != "claude" || !isSessionRateLimitEvent(translated))
			return false;

		SessionRateLimitEvent rateLimitEvent;
		try
			rateLimitEvent = jsonParse!SessionRateLimitEvent(translated);
		catch (Exception)
			return false;

		auto limitType = rateLimitEvent.rate_limit_info.rateLimitType;
		if (limitType.length == 0)
			return false;

		auto normalizedUtilization = normalizeUtilizationPercent(
			rateLimitEvent.rate_limit_info.utilization);
		const hasUtilization = !isNaN(normalizedUtilization);
		const hasResetsAt = !isNaN(rateLimitEvent.rate_limit_info.resetsAt);
		const hasStatus = rateLimitEvent.rate_limit_info.status.length > 0;
		if (!hasUtilization && !hasResetsAt && !hasStatus)
			return false;

		auto state = agentUsageByAgent.get("claude", AgentUsageState("claude", 0, null));
		auto window = state.limits.get(limitType, AgentUsageLimitWindowState.init);
		bool changed = false;

		if (hasUtilization
			&& (!window.hasUtilization
				|| fabs(window.utilization - normalizedUtilization) > 0.0001))
		{
			window.hasUtilization = true;
			window.utilization = normalizedUtilization;
			changed = true;
		}
		if (hasResetsAt
			&& (!window.hasResetsAt
				|| fabs(window.resetsAt - rateLimitEvent.rate_limit_info.resetsAt) > 0.0001))
		{
			window.hasResetsAt = true;
			window.resetsAt = rateLimitEvent.rate_limit_info.resetsAt;
			changed = true;
		}
		if (hasStatus
			&& (!window.hasStatus
				|| window.status != rateLimitEvent.rate_limit_info.status))
		{
			window.hasStatus = true;
			window.status = rateLimitEvent.rate_limit_info.status;
			changed = true;
		}
		if (!changed)
			return false;

		state.agent = "claude";
		state.updatedAt = cast(long) Clock.currTime.toUnixTime;
		state.limits[limitType] = window;
		agentUsageByAgent["claude"] = state;
		payload = toJson(buildAgentUsageMessage(state));
		return true;
	}
}

private bool isSessionRateLimitEvent(string translated)
{
	import std.algorithm : canFind;
	return translated.canFind(`"type":"session/rate_limit"`)
		|| translated.canFind(`"type":"session\/rate_limit"`);
}

private double normalizeUtilizationPercent(double raw)
{
	// Pushed rate_limit_event utilization (0-1 or 0-100) is distinct from
	// status-line used_percentage fields.
	if (isNaN(raw) || !isFinite(raw))
		return double.nan;
	double pct = raw;
	if (pct >= 0 && pct <= 1)
		pct *= 100;
	if (pct < 0) pct = 0;
	if (pct > 100) pct = 100;
	return pct;
}

private AgentUsageMessage buildAgentUsageMessage(ref const AgentUsageState state)
{
	AgentUsageMessage msg;
	msg.agent = state.agent;
	msg.updated_at = state.updatedAt;
	foreach (limitType, ref window; state.limits)
	{
		if (!window.hasUtilization && !window.hasResetsAt && !window.hasStatus)
			continue;
		AgentUsageLimitWindowMessage outWindow;
		if (window.hasUtilization)
			outWindow.utilization = window.utilization;
		if (window.hasResetsAt)
			outWindow.resetsAt = window.resetsAt;
		if (window.hasStatus)
			outWindow.status = window.status;
		msg.limits[limitType] = outWindow;
	}
	return msg;
}

unittest
{
	auto tracker = new AgentUsageTracker();

	string payload;
	auto changed = tracker.updateFromClaudeEvent("claude",
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"five_hour","utilization":0.42,"resetsAt":1000,"status":"allowed"}}`,
		payload);
	assert(changed);
	assert("claude" in tracker.agentUsageByAgent);
	assert("five_hour" in tracker.agentUsageByAgent["claude"].limits);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].hasUtilization);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].utilization == 42);

	changed = tracker.updateFromClaudeEvent("claude",
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"seven_day","utilization":71.5}}`,
		payload);
	assert(changed);
	assert("seven_day" in tracker.agentUsageByAgent["claude"].limits);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].utilization == 42);
	assert(tracker.agentUsageByAgent["claude"].limits["seven_day"].utilization == 71.5);

	changed = tracker.updateFromClaudeEvent("claude",
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"five_hour","resetsAt":2000,"status":"allowed_warning"}}`,
		payload);
	assert(changed);
	auto msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("five_hour" in msg.limits);
	assert(msg.limits["five_hour"].utilization == 42);
	assert(msg.limits["five_hour"].resetsAt == 2000);
	assert(msg.limits["five_hour"].status == "allowed_warning");

	changed = tracker.updateFromClaudeEvent("claude",
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"seven_day","status":"allowed"}}`,
		payload);
	assert(changed);
	msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("seven_day" in msg.limits);
	assert(msg.limits["seven_day"].utilization == 71.5);
	assert(msg.limits["seven_day"].status == "allowed");

	changed = tracker.updateFromClaudeEvent("claude",
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"overage","status":"rejected","resetsAt":3000}}`,
		payload);
	assert(changed);
	msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("overage" in msg.limits);
	assert(msg.limits["overage"].status == "rejected");
	assert(msg.limits["overage"].resetsAt == 3000);
	assert(isNaN(msg.limits["overage"].utilization));
}
