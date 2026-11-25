module cydo.domain.usage.tracker;

import core.time : MonoTime;
import std.datetime.systime : Clock;
import std.math : fabs, isFinite, isNaN;

import ae.utils.json : JSONOptional, toJson;

import cydo.protocol : RateLimitInfo;

private struct AgentUsageLimitWindowMessage
{
	@JSONOptional double utilization;
	@JSONOptional double resetsAt;
	@JSONOptional string status;
}

private struct AgentUsageMessage
{
	string type = "agent_usage";
	string profile;
	long updated_at;
	AgentUsageLimitWindowMessage[string] limits;
	@JSONOptional string credential_expires_at;
}

private struct AgentUsageLimitWindowState
{
	MonoTime observedAt;
	bool hasUtilization;
	double utilization;
	bool hasResetsAt;
	double resetsAt;
	bool hasStatus;
	string status;
}

private struct ProfileUsage
{
	string profile;
	long updatedAt;
	AgentUsageLimitWindowState[string] limits;
	string credentialExpiresAt;
}

class AgentUsageTracker
{
	private ProfileUsage[string] usageByProfile;

	string[] snapshotMessages()
	{
		string[] payloads;
		foreach (ref usageState; usageByProfile)
			payloads ~= toJson(buildAgentUsageMessage(usageState));
		return payloads;
	}

	bool applyPush(string profile, RateLimitInfo info, MonoTime receivedAt, out string payload)
	{
		auto limitType = info.rateLimitType;
		if (limitType.length == 0)
			return false;

		auto normalizedUtilization = normalizeUtilizationPercent(
			info.utilization);
		const hasUtilization = !isNaN(normalizedUtilization);
		const hasResetsAt = !isNaN(info.resetsAt);
		const hasStatus = info.status.length > 0;
		if (!hasUtilization && !hasResetsAt && !hasStatus)
			return false;

		auto state = usageByProfile.get(profile, ProfileUsage(profile));
		auto window = state.limits.get(limitType, AgentUsageLimitWindowState.init);
		if (receivedAt < window.observedAt)
			return false;
		window.observedAt = receivedAt;
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
				|| fabs(window.resetsAt - info.resetsAt) > 0.0001))
		{
			window.hasResetsAt = true;
			window.resetsAt = info.resetsAt;
			changed = true;
		}
		if (hasStatus
			&& (!window.hasStatus
				|| window.status != info.status))
		{
			window.hasStatus = true;
			window.status = info.status;
			changed = true;
		}
		state.limits[limitType] = window;
		if (!changed)
			return false;

		state.updatedAt = Clock.currTime.toUnixTime;
		usageByProfile[profile] = state;
		payload = toJson(buildAgentUsageMessage(state));
		return true;
	}

	bool applyCredentialExpiry(string profile, string expiresAt, out string payload)
	{
		auto state = usageByProfile.get(profile, ProfileUsage(profile));
		if (expiresAt.length == 0 || expiresAt == state.credentialExpiresAt)
			return false;
		state.credentialExpiresAt = expiresAt;
		state.updatedAt = Clock.currTime.toUnixTime;
		usageByProfile[profile] = state;
		payload = toJson(buildAgentUsageMessage(state));
		return true;
	}
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

private AgentUsageMessage buildAgentUsageMessage(ref const ProfileUsage state)
{
	AgentUsageMessage msg;
	msg.profile = state.profile;
	msg.updated_at = state.updatedAt;
	msg.credential_expires_at = state.credentialExpiresAt;
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

version (unittest)
	import ae.utils.json : jsonParse;

unittest
{
	auto tracker = new AgentUsageTracker();
	const receivedAt = MonoTime.currTime;
	string payload;

	assert(tracker.applyPush("claude", jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":0.42,"resetsAt":1000,"status":"allowed"}`),
		receivedAt, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 42);

	assert(tracker.applyPush("claude", jsonParse!RateLimitInfo(
		`{"rateLimitType":"seven_day","utilization":71.5}`), receivedAt, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 42);
	assert(msg.limits["seven_day"].utilization == 71.5);

	assert(tracker.applyPush("claude", jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","resetsAt":2000,"status":"allowed_warning"}`),
		receivedAt, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 42);
	assert(msg.limits["five_hour"].resetsAt == 2000);
	assert(msg.limits["five_hour"].status == "allowed_warning");

	assert(tracker.applyPush("claude", jsonParse!RateLimitInfo(
		`{"rateLimitType":"seven_day","status":"allowed"}`), receivedAt, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["seven_day"].utilization == 71.5);
	assert(msg.limits["seven_day"].status == "allowed");

	assert(tracker.applyPush("claude", jsonParse!RateLimitInfo(
		`{"rateLimitType":"overage","status":"rejected","resetsAt":3000}`),
		receivedAt, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["overage"].status == "rejected");
	assert(msg.limits["overage"].resetsAt == 3000);
	assert(isNaN(msg.limits["overage"].utilization));
}

unittest
{
	auto tracker = new AgentUsageTracker();
	const receivedAt = MonoTime.currTime;
	string payload;
	assert(tracker.snapshotMessages().length == 0);

	assert(tracker.applyPush("personal", jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":20,"status":"allowed"}`),
		receivedAt, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.profile == "personal");
	assert(msg.limits["five_hour"].utilization == 20);

	assert(tracker.applyPush("work", jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":80}`), receivedAt, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.profile == "work");
	assert(msg.limits["five_hour"].utilization == 80);
	assert(msg.limits["five_hour"].status == "");

	auto snapshots = tracker.snapshotMessages();
	assert(snapshots.length == 2);
	AgentUsageMessage[string] byProfile;
	foreach (snapshot; snapshots)
	{
		msg = jsonParse!AgentUsageMessage(snapshot);
		byProfile[msg.profile] = msg;
	}
	assert(byProfile["personal"].limits["five_hour"].utilization == 20);
	assert(byProfile["personal"].limits["five_hour"].status == "allowed");
	assert(byProfile["work"].limits["five_hour"].utilization == 80);
}

unittest
{
	import core.time : seconds;

	auto tracker = new AgentUsageTracker();
	const earlier = MonoTime.currTime;
	const later = earlier + 1.seconds;
	string payload;
	auto newest = jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":80}`);
	auto stale = jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":20}`);

	assert(tracker.applyPush("personal", newest, later, payload));
	assert(!tracker.applyPush("personal", stale, earlier, payload));
	assert(tracker.applyPush("work", stale, earlier, payload));

	stale.rateLimitType = "seven_day";
	assert(tracker.applyPush("personal", stale, earlier, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 80);
	assert(msg.limits["seven_day"].utilization == 20);

	assert(!tracker.applyPush("personal", newest, later + 1.seconds, payload));
	stale.rateLimitType = "five_hour";
	assert(!tracker.applyPush("personal", stale, later, payload));
}

unittest
{
	auto tracker = new AgentUsageTracker();
	string payload;
	enum expiry = "2026-11-12T12:31:33Z";
	enum updatedExpiry = "2026-11-13T12:31:33Z";

	assert(!tracker.applyCredentialExpiry("work", "", payload));
	assert(tracker.snapshotMessages().length == 0);
	assert(tracker.applyCredentialExpiry("personal", expiry, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.profile == "personal");
	assert(msg.credential_expires_at == expiry);
	assert(!tracker.applyCredentialExpiry("personal", expiry, payload));

	assert(tracker.applyCredentialExpiry("work", expiry, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.profile == "work");
	assert(msg.credential_expires_at == expiry);
	assert(tracker.applyCredentialExpiry("personal", updatedExpiry, payload));
	assert(!tracker.applyCredentialExpiry("personal", "", payload));

	auto snapshots = tracker.snapshotMessages();
	assert(snapshots.length == 2);
	string[string] expiryByProfile;
	foreach (snapshot; snapshots)
	{
		msg = jsonParse!AgentUsageMessage(snapshot);
		expiryByProfile[msg.profile] = msg.credential_expires_at;
	}
	assert(expiryByProfile["personal"] == updatedExpiry);
	assert(expiryByProfile["work"] == expiry);
}
