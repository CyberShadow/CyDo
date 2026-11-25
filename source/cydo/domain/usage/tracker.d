module cydo.domain.usage.tracker;

import core.time : MonoTime;
import std.datetime.systime : Clock, SysTime;
import std.math : fabs, isFinite, isNaN;
import std.typecons : Nullable;

import ae.utils.json : JSONOptional, toJson;

import cydo.domain.usage.claude_usage : ClaudeUsageReport, ClaudeUsageWindow;
import cydo.protocol : RateLimitInfo;

private struct AgentUsageLimitWindowMessage
{
	@JSONOptional double utilization;
	@JSONOptional double resetsAt;
	@JSONOptional string status;
}

private struct ModelUsageWindowMessage
{
	string label;
	@JSONOptional Nullable!double utilization;
	@JSONOptional Nullable!long resetsAt;
}

private struct AgentUsageMessage
{
	string type = "agent_usage";
	string profile;
	long updated_at;
	AgentUsageLimitWindowMessage[string] limits;
	@JSONOptional ModelUsageWindowMessage[] model_weekly;
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
	ModelUsageWindowMessage[] modelWeekly;
	MonoTime modelWeeklyObservedAt;
	string credentialExpiresAt;
}

class AgentUsageTracker
{
	private ProfileUsage[string] usageByProfile;

	string[] snapshotMessages()
	{
		string[] payloads;
		foreach (ref usageState; usageByProfile)
			if (usageState.updatedAt != 0)
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

	bool applyPoll(string profile, ClaudeUsageReport report, MonoTime sentAt, out string payload)
	{
		if (!report.rate_limits_available || report.rate_limits.isNull)
			return false;

		auto state = usageByProfile.get(profile, ProfileUsage(profile));
		auto limits = report.rate_limits.get;
		struct WindowUpdate
		{
			string limitType;
			AgentUsageLimitWindowState window;
			bool changed;
		}
		WindowUpdate[2] updates;
		size_t updateCount;

		static foreach (field; ["five_hour", "seven_day"])
		{{
			auto observed = __traits(getMember, limits, field);
			auto window = state.limits.get(field, AgentUsageLimitWindowState.init);
			if (!observed.isNull && sentAt >= window.observedAt
				&& (!observed.get.utilization.isNull || !observed.get.resets_at.isNull))
			{
				bool changed = mergePolledWindow(window, observed.get);
				window.observedAt = sentAt;
				updates[updateCount++] = WindowUpdate(field, window, changed);
			}
		}}

		bool changed;
		if (!limits.model_scoped.isNull && sentAt >= state.modelWeeklyObservedAt)
		{
			ModelUsageWindowMessage[] modelWeekly;
			foreach (model; limits.model_scoped.get)
			{
				auto row = ModelUsageWindowMessage(model.display_name);
				if (!model.utilization.isNull)
					row.utilization = clampPercent(model.utilization.get);
				if (!model.resets_at.isNull)
					row.resetsAt = SysTime.fromISOExtString(model.resets_at.get).toUnixTime;
				modelWeekly ~= row;
			}
			changed = state.modelWeekly != modelWeekly;
			state.modelWeekly = modelWeekly;
			state.modelWeeklyObservedAt = sentAt;
		}

		foreach (ref update; updates[0 .. updateCount])
		{
			state.limits[update.limitType] = update.window;
			changed |= update.changed;
		}
		if (changed)
		{
			state.updatedAt = Clock.currTime.toUnixTime;
			payload = toJson(buildAgentUsageMessage(state));
		}
		if (updateCount != 0 || !limits.model_scoped.isNull)
			usageByProfile[profile] = state;
		return changed;
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

private bool mergePolledWindow(ref AgentUsageLimitWindowState window, ClaudeUsageWindow observed)
{
	bool changed;
	if (!observed.utilization.isNull)
	{
		auto utilization = clampPercent(observed.utilization.get);
		changed |= !window.hasUtilization || window.utilization != utilization;
		window.hasUtilization = true;
		window.utilization = utilization;
	}
	if (!observed.resets_at.isNull)
	{
		auto resetsAt = SysTime.fromISOExtString(observed.resets_at.get).toUnixTime;
		changed |= !window.hasResetsAt || window.resetsAt != resetsAt;
		window.hasResetsAt = true;
		window.resetsAt = resetsAt;
	}
	return changed;
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
	return clampPercent(pct);
}

private double clampPercent(double percent)
{
	import std.algorithm : clamp;
	return clamp(percent, 0.0, 100.0);
}

private AgentUsageMessage buildAgentUsageMessage(ref ProfileUsage state)
{
	AgentUsageMessage msg;
	msg.profile = state.profile;
	msg.updated_at = state.updatedAt;
	msg.credential_expires_at = state.credentialExpiresAt;
	msg.model_weekly = state.modelWeekly;
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

unittest
{
	import core.time : seconds;

	auto tracker = new AgentUsageTracker;
	auto t1 = MonoTime.currTime;
	auto t2 = t1 + 1.seconds;
	auto t3 = t2 + 1.seconds;
	string payload;
	assert(tracker.applyPush("work", jsonParse!RateLimitInfo(
		`{"rateLimitType":"five_hour","utilization":0.42,"status":"allowed"}`), t2, payload));
	auto report = jsonParse!ClaudeUsageReport(`{
		"rate_limits_available":true,
		"rate_limits":{
			"five_hour":{"utilization":0.5,"resets_at":"2026-11-27T00:00:00Z"},
			"seven_day":{"utilization":150,"resets_at":"2026-11-27T00:00:00.000Z"}
		}
	}`);
	assert(tracker.applyPoll("work", report, t1, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 42);
	assert(isNaN(msg.limits["five_hour"].resetsAt));
	assert(msg.limits["seven_day"].utilization == 100);
	assert(msg.limits["seven_day"].resetsAt == 1_795_737_600);

	assert(tracker.applyPoll("work", report, t3, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 0.5);
	assert(msg.limits["five_hour"].resetsAt == msg.limits["seven_day"].resetsAt);
	assert(msg.limits["five_hour"].status == "allowed");

	auto snapshot = tracker.snapshotMessages();
	foreach (noInformation; [
		`{"rate_limits_available":false,"rate_limits":{"five_hour":{"utilization":99,"resets_at":null}}}`,
		`{"rate_limits_available":true,"rate_limits":null}`,
		`{"rate_limits_available":true,"rate_limits":{}}`,
		`{"rate_limits_available":true,"rate_limits":{"five_hour":null}}`,
		`{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":null,"resets_at":null}}}`,
	])
	{
		assert(!tracker.applyPoll("work", jsonParse!ClaudeUsageReport(noInformation), t3, payload));
		assert(payload is null);
		assert(tracker.snapshotMessages() == snapshot);
	}
	assert(tracker.applyPoll("work", jsonParse!ClaudeUsageReport(`{
		"rate_limits_available":true,
		"rate_limits":{"five_hour":{"utilization":10,"resets_at":null}}
	}`), t3, payload));
	msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.limits["five_hour"].utilization == 10);
	assert(msg.limits["five_hour"].resetsAt == 1_795_737_600);
}

unittest
{
	import core.time : seconds;

	auto tracker = new AgentUsageTracker;
	auto t1 = MonoTime.currTime;
	auto t2 = t1 + 1.seconds;
	string payload;
	auto fable = jsonParse!ClaudeUsageReport(`{
		"rate_limits_available":true,
		"rate_limits":{"model_scoped":[
			{"display_name":"Fable","utilization":42.5,"resets_at":"2026-11-27T00:00:00.000Z"}
		]}
	}`);
	assert(tracker.applyPoll("work", fable, t1, payload));
	auto msg = jsonParse!AgentUsageMessage(payload);
	assert(msg.model_weekly.length == 1);
	assert(msg.model_weekly[0].label == "Fable");
	assert(msg.model_weekly[0].utilization.get == 42.5);
	assert(msg.model_weekly[0].resetsAt.get == 1_795_737_600);

	assert(!tracker.applyPoll("work", jsonParse!ClaudeUsageReport(
		`{"rate_limits_available":true,"rate_limits":{}}`), t2, payload));
	assert(jsonParse!AgentUsageMessage(tracker.snapshotMessages()[0]).model_weekly.length == 1);

	auto empty = jsonParse!ClaudeUsageReport(
		`{"rate_limits_available":true,"rate_limits":{"model_scoped":[]}}`);
	assert(tracker.applyPoll("work", empty, t2, payload));
	assert(jsonParse!AgentUsageMessage(payload).model_weekly.length == 0);
	assert(!tracker.applyPoll("work", fable, t1, payload));
	assert(tracker.applyPoll("work", fable, t2, payload));
}
