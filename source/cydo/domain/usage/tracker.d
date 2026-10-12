module cydo.domain.usage.tracker;

import std.math : fabs, isFinite, isNaN;

import ae.utils.json : JSONOptional, jsonParse, toJson;

import cydo.runtime.config : AgentDriver;
import cydo.protocol : SessionRateLimitEvent;

private struct AgentUsageLimitWindowMessage
{
	@JSONOptional double utilization;
	@JSONOptional double resetsAt;
	@JSONOptional string status;
	@JSONOptional string label;
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
	bool hasLabel;
	string label;
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

	bool updateFromClaudeEvent(AgentDriver driver, string translated, out string payload)
	{
		import std.datetime.systime : Clock;

		if (driver != AgentDriver.claude || !isSessionRateLimitEvent(translated))
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

	/// Update the claude windows from a usage poll (GET /api/oauth/usage):
	/// five_hour, seven_day, and the model-scoped weekly row as "model" with
	/// its label (e.g. "Fable") when there is one. Utilizations are 0-100;
	/// resets are unix epoch seconds (0 = unknown). Returns true (with
	/// payload) if anything changed.
	bool updateFromUsagePoll(double fiveUtil, double fiveReset,
		double sevenUtil, double sevenReset,
		string modelLabel, double modelUtil, double modelReset, out string payload)
	{
		import std.datetime.systime : Clock;

		auto state = agentUsageByAgent.get("claude", AgentUsageState("claude", 0, null));
		bool changed = false;
		changed |= setPolledWindow(state, "five_hour", fiveUtil, fiveReset);
		changed |= setPolledWindow(state, "seven_day", sevenUtil, sevenReset);
		if (modelLabel.length > 0)
			changed |= setPolledWindow(state, "model", modelUtil, modelReset, modelLabel);
		if (!changed)
			return false;

		state.agent = "claude";
		state.updatedAt = cast(long) Clock.currTime.toUnixTime;
		agentUsageByAgent["claude"] = state;
		payload = toJson(buildAgentUsageMessage(state));
		return true;
	}

	private static bool setPolledWindow(ref AgentUsageState state, string key,
		double util, double reset, string label = null)
	{
		auto window = state.limits.get(key, AgentUsageLimitWindowState.init);
		auto normUtil = clampUtilizationPercent(util);
		bool changed = false;
		if (!isNaN(normUtil)
			&& (!window.hasUtilization || fabs(window.utilization - normUtil) > 0.0001))
		{
			window.hasUtilization = true;
			window.utilization = normUtil;
			changed = true;
		}
		if (reset > 0
			&& (!window.hasResetsAt || fabs(window.resetsAt - reset) > 0.0001))
		{
			window.hasResetsAt = true;
			window.resetsAt = reset;
			changed = true;
		}
		if (label.length > 0 && (!window.hasLabel || window.label != label))
		{
			window.hasLabel = true;
			window.label = label;
			changed = true;
		}
		if (changed)
			state.limits[key] = window;
		return changed;
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
	return clampUtilizationPercent(pct);
}

/// Clamp an already-percent value to 0-100. The poll endpoint
/// (/api/oauth/usage) always reports percentages, so the fraction rescaling
/// above must not be applied to it: a genuine 1% would be read as 100%, which
/// is what a freshly-reset weekly window reports.
private double clampUtilizationPercent(double raw)
{
	if (isNaN(raw) || !isFinite(raw))
		return double.nan;
	if (raw < 0) return 0;
	if (raw > 100) return 100;
	return raw;
}

private AgentUsageMessage buildAgentUsageMessage(ref const AgentUsageState state)
{
	AgentUsageMessage msg;
	msg.agent = state.agent;
	msg.updated_at = state.updatedAt;
	foreach (limitType, ref window; state.limits)
	{
		if (!window.hasUtilization && !window.hasResetsAt && !window.hasStatus
			&& !window.hasLabel)
			continue;
		AgentUsageLimitWindowMessage outWindow;
		if (window.hasUtilization)
			outWindow.utilization = window.utilization;
		if (window.hasResetsAt)
			outWindow.resetsAt = window.resetsAt;
		if (window.hasStatus)
			outWindow.status = window.status;
		if (window.hasLabel)
			outWindow.label = window.label;
		msg.limits[limitType] = outWindow;
	}
	return msg;
}

unittest
{
	auto tracker = new AgentUsageTracker();

	string payload;
	auto changed = tracker.updateFromClaudeEvent(AgentDriver.claude,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"five_hour","utilization":0.42,"resetsAt":1000,"status":"allowed"}}`,
		payload);
	assert(changed);
	assert("claude" in tracker.agentUsageByAgent);
	assert("five_hour" in tracker.agentUsageByAgent["claude"].limits);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].hasUtilization);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].utilization == 42);

	changed = tracker.updateFromClaudeEvent(AgentDriver.claude,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"seven_day","utilization":71.5}}`,
		payload);
	assert(changed);
	assert("seven_day" in tracker.agentUsageByAgent["claude"].limits);
	assert(tracker.agentUsageByAgent["claude"].limits["five_hour"].utilization == 42);
	assert(tracker.agentUsageByAgent["claude"].limits["seven_day"].utilization == 71.5);

	changed = tracker.updateFromClaudeEvent(AgentDriver.claude,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"five_hour","resetsAt":2000,"status":"allowed_warning"}}`,
		payload);
	assert(changed);
	auto msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("five_hour" in msg.limits);
	assert(msg.limits["five_hour"].utilization == 42);
	assert(msg.limits["five_hour"].resetsAt == 2000);
	assert(msg.limits["five_hour"].status == "allowed_warning");

	changed = tracker.updateFromClaudeEvent(AgentDriver.claude,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"seven_day","status":"allowed"}}`,
		payload);
	assert(changed);
	msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("seven_day" in msg.limits);
	assert(msg.limits["seven_day"].utilization == 71.5);
	assert(msg.limits["seven_day"].status == "allowed");

	changed = tracker.updateFromClaudeEvent(AgentDriver.claude,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"overage","status":"rejected","resetsAt":3000}}`,
		payload);
	assert(changed);
	msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert("overage" in msg.limits);
	assert(msg.limits["overage"].status == "rejected");
	assert(msg.limits["overage"].resetsAt == 3000);
	assert(isNaN(msg.limits["overage"].utilization));
}

unittest
{
	auto tracker = new AgentUsageTracker();

	string payload;
	auto changed = tracker.updateFromClaudeEvent(AgentDriver.codex,
		`{"type":"session/rate_limit","rate_limit_info":{"rateLimitType":"five_hour","utilization":0.42,"resetsAt":1000,"status":"allowed"}}`,
		payload);
	assert(!changed);
	assert(tracker.agentUsageByAgent.length == 0);
}

unittest
{
	// polled percentages are percentages, never fractions: a freshly-reset
	// weekly window reports 1, which the pushed-event heuristic would have
	// turned into 100 (reported as "0% remaining" in the banner)
	auto tracker = new AgentUsageTracker();
	string payload;
	auto changed = tracker.updateFromUsagePoll(8.0, 0, 1.0, 0, "Fable", 1.0, 0, payload);
	assert(changed);
	auto msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert(msg.limits["five_hour"].utilization == 8.0);
	assert(msg.limits["seven_day"].utilization == 1.0);
	assert(msg.limits["model"].utilization == 1.0);
	assert(msg.limits["model"].label == "Fable");

	// 0 stays 0, and out-of-range values still clamp
	changed = tracker.updateFromUsagePoll(0.0, 0, 140.0, 0, "Fable", -5.0, 0, payload);
	assert(changed);
	msg = buildAgentUsageMessage(tracker.agentUsageByAgent["claude"]);
	assert(msg.limits["five_hour"].utilization == 0.0);
	assert(msg.limits["seven_day"].utilization == 100.0);
	assert(msg.limits["model"].utilization == 0.0);
}
