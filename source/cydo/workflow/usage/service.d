module cydo.workflow.usage.service;

import core.time : Duration, MonoTime;
import std.algorithm : startsWith;
import std.exception : enforce;
import std.json : parseJSON;
import std.logger : errorf, tracef;

import ae.utils.json : JSONOptional, JSONPartial, jsonParse;

import cydo.domain.usage.claude_usage : ClaudeUsageReport, UsageSource;
import cydo.domain.usage.tracker : AgentUsageTracker;
import cydo.protocol : SessionRateLimitEvent;
import cydo.runtime.config : CydoConfig, UsagePollingPeriod;

private struct RefreshSchedule
{
	bool inFlight;
	uint turnsSinceRefresh;
	MonoTime lastRefreshSentAt;
	Duration armedPeriod;
	void delegate() cancelTimer;

	bool shouldRefreshOnTurn(UsagePollingPeriod period) pure
	{
		turnsSinceRefresh++;
		return !inFlight && period.turns.set && turnsSinceRefresh >= period.turns.value;
	}

	void sent(MonoTime sentAt) pure
	{
		assert(!inFlight);
		inFlight = true;
		turnsSinceRefresh = 0;
		lastRefreshSentAt = sentAt;
	}
}

class ClaudeUsageService
{
	private struct Registration
	{
		UsageSource source;
		string profile;
		string agentName;
		MonoTime registeredAt;
	}

	private Registration[int] sessions_;
	private RefreshSchedule*[string] schedules_;
	private UsagePollingPeriod[string] periods_;
	private void delegate() delegate(Duration, void delegate()) arm_;
	private MonoTime delegate() now_;
	private AgentUsageTracker tracker_;
	private void delegate(string) broadcast_;

	this(void delegate(string) broadcast, void delegate() delegate(Duration, void delegate()) arm,
		MonoTime delegate() now)
	{
		tracker_ = new AgentUsageTracker();
		broadcast_ = broadcast;
		arm_ = arm;
		now_ = now;
	}

	void sessionStarted(int tid, UsageSource source, string profile, string agentName)
	{
		auto previous = profileForSession(tid);
		if (previous.length > 0 && previous != profile)
			sessionEnded(tid);

		sessions_[tid] = Registration(source, profile, agentName, now_());
		if (profile !in schedules_)
			schedules_[profile] = new RefreshSchedule;
		auto schedule = schedules_[profile];
		auto period = effectivePeriod(profile);
		if (source.alive && (period.turns.set || period.timespan.set) && !schedule.inFlight)
			send(profile, schedule, source, period);
		else
			updateTimer(profile, schedule, period);
	}

	void sessionEnded(int tid)
	{
		auto registration = tid in sessions_;
		if (registration is null)
			return;
		auto profile = registration.profile;
		sessions_.remove(tid);

		auto schedule = schedules_[profile];
		foreach (ref session; sessions_)
		{
			if (session.profile != profile)
				continue;
			updateTimer(profile, schedule, effectivePeriod(profile));
			return;
		}
		cancelTimer(schedule);
		schedules_.remove(profile);
	}

	string profileForSession(int tid)
	{
		return sessions_.get(tid, Registration.init).profile;
	}

	void observeEvent(int tid, string translated)
	{
		auto registration = tid in sessions_;
		if (registration is null)
			return;

		@JSONPartial static struct TypeProbe { string type; }
		@JSONPartial static struct CredentialProbe { @JSONOptional string credential_expires_at; }

		string payload;
		auto probe = jsonParse!TypeProbe(translated);
		enforce(probe.type !is null, "Usage event requires a type");
		switch (probe.type)
		{
			case "session/rate_limit":
				enforce("rate_limit_info" in parseJSON(translated).object,
					"Usage event requires rate_limit_info");
				if (tracker_.applyPush(registration.profile,
					jsonParse!SessionRateLimitEvent(translated).rate_limit_info,
					now_(), payload))
					broadcast_(payload);
				break;
			case "turn/result":
				if (tracker_.applyCredentialExpiry(registration.profile,
					jsonParse!CredentialProbe(translated).credential_expires_at, payload))
					broadcast_(payload);
				auto schedule = schedules_[registration.profile];
				auto period = effectivePeriod(registration.profile);
				if (schedule.shouldRefreshOnTurn(period) && registration.source.alive)
					send(registration.profile, schedule, registration.source, period);
				break;
			default:
				break;
		}
	}

	void configChanged(const ref CydoConfig config)
	{
		UsagePollingPeriod[string] periods;
		foreach (name, ref agent; config.agents)
			if (agent.usage_polling_period.set)
				periods[name] = agent.usage_polling_period.value;
		periods_ = periods;

		foreach (profile, schedule; schedules_)
			updateTimer(profile, schedule, effectivePeriod(profile));
	}

	private UsagePollingPeriod effectivePeriod(string profile)
	{
		UsagePollingPeriod effective;
		foreach (ref session; sessions_)
		{
			if (session.profile != profile)
				continue;
			if (auto period = session.agentName in periods_)
			{
				if (period.turns.set && (!effective.turns.set || period.turns.value < effective.turns.value))
					effective.turns = period.turns;
				if (period.timespan.set
					&& (!effective.timespan.set || period.timespan.value < effective.timespan.value))
					effective.timespan = period.timespan;
			}
		}
		return effective;
	}

	private static void cancelTimer(RefreshSchedule* schedule)
	{
		if (schedule.cancelTimer !is null)
		{
			schedule.cancelTimer();
			schedule.cancelTimer = null;
		}
	}

	private UsageSource latestAliveSource(string profile)
	{
		Registration* latest;
		foreach (ref session; sessions_)
			if (session.profile == profile && session.source.alive
				&& (latest is null || session.registeredAt >= latest.registeredAt))
				latest = &session;
		return latest is null ? null : latest.source;
	}

	private void updateTimer(string profile, RefreshSchedule* schedule, UsagePollingPeriod period)
	{
		if (!period.timespan.set || latestAliveSource(profile) is null)
		{
			cancelTimer(schedule);
			return;
		}
		auto timespan = period.timespan.value;
		if (schedule.cancelTimer !is null && schedule.armedPeriod == timespan)
			return;

		import std.algorithm : max;
		auto delay = schedule.lastRefreshSentAt == MonoTime.init ? timespan
			: max(Duration.zero, schedule.lastRefreshSentAt + timespan - now_());
		armTimer(profile, schedule, timespan, delay);
	}

	private void armTimer(string profile, RefreshSchedule* schedule, Duration timespan, Duration delay)
	{
		cancelTimer(schedule);
		schedule.armedPeriod = timespan;
		schedule.cancelTimer = arm_(delay, {
			schedule.cancelTimer = null;
			// Process reaping can precede the exit callback when stdout remains open.
			auto source = latestAliveSource(profile);
			if (source is null)
				return;
			auto currentPeriod = effectivePeriod(profile);
			if (schedule.inFlight)
			{
				auto interval = currentPeriod.timespan.value;
				armTimer(profile, schedule, interval, interval);
				return;
			}
			send(profile, schedule, source, currentPeriod);
		});
	}

	private void send(string profile, RefreshSchedule* schedule, UsageSource source, UsagePollingPeriod period)
	{
		auto sentAt = now_();
		schedule.sent(sentAt);
		if (period.timespan.set)
			armTimer(profile, schedule, period.timespan.value, period.timespan.value);
		else
			cancelTimer(schedule);

		source.requestUsage().then((ClaudeUsageReport report) {
			if (schedules_.get(profile, null) !is schedule)
				return;
			schedule.inFlight = false;
			string payload;
			if (tracker_.applyPoll(profile, report, sentAt, payload))
				broadcast_(payload);
		}).except((Exception e) {
			if (schedules_.get(profile, null) !is schedule)
				return;
			schedule.inFlight = false;
			if (e.msg.startsWith("Claude exited before answering"))
				tracef("Claude usage refresh for %s: %s", profile, e.msg);
			else
				errorf("Claude usage refresh for %s: %s", profile, e.msg);
		}).ignoreResult();
	}

	string[] snapshotMessages()
	{
		return tracker_.snapshotMessages();
	}
}

version (unittest)
{
	import ae.utils.promise : Promise;
	import cydo.foundation.testing : drainNextTicks;

	private final class TestUsageSource : UsageSource
	{
		bool running = true;
		uint requests;
		Promise!ClaudeUsageReport pending;

		@property bool alive() { return running; }

		Promise!ClaudeUsageReport requestUsage()
		{
			requests++;
			pending = new Promise!ClaudeUsageReport;
			return pending;
		}

		void settle(string window = "five_hour")
		{
			pending.fulfill(jsonParse!ClaudeUsageReport(`{
				"rate_limits_available":true,
				"rate_limits":{"` ~ window ~ `":{"utilization":25,"resets_at":null}}
			}`));
			drainNextTicks();
		}
	}

	private final class UsageTestFixture
	{
		ClaudeUsageService service;
		Duration delay;
		MonoTime now = MonoTime(1);
		void delegate() timer;
		uint arms;
		uint cancels;
		string[] broadcasts;

		this()
		{
			service = new ClaudeUsageService((string payload) {
				broadcasts ~= payload;
			}, &arm, () => now);
		}

		private void delegate() arm(Duration duration, void delegate() callback)
		{
			assert(timer is null);
			delay = duration;
			timer = callback;
			arms++;
			return {
				assert(timer is callback);
				cancels++;
				timer = null;
			};
		}

		void fire()
		{
			auto callback = timer;
			assert(callback !is null);
			timer = null;
			now += delay;
			callback();
		}

		void configure(string agents)
		{
			import cydo.runtime.config.yaml : parseYamlConfigString;
			auto config = parseYamlConfigString!CydoConfig("workspaces: {}\nagents: " ~ agents, "config.yaml");
			service.configChanged(config);
		}
	}
}

unittest
{
	auto fixture = new UsageTestFixture;
	auto source = new TestUsageSource;
	fixture.service.sessionStarted(1, source, "work", "claude");
	assert(source.requests == 0);
	assert(fixture.arms == 0);
	fixture.service.observeEvent(1, `{"type":"session/rate_limit",
		"rate_limit_info":{"rateLimitType":"five_hour","utilization":0.42}}`);
	assert(fixture.broadcasts.length == 1);
	assert(source.requests == 0);

	fixture.configure("{claude: {usage_polling_period: {timespan: {seconds: 2}}}}");
	assert(fixture.arms == 1);
	assert(source.requests == 0);
	fixture.fire();
	assert(source.requests == 1);
	assert(fixture.arms == 2);
	fixture.configure("{}");
	assert(fixture.timer is null);
	assert(fixture.cancels == 1);
	fixture.service.sessionEnded(1);
	auto snapshot = fixture.service.snapshotMessages();
	source.settle("seven_day");
	assert(fixture.broadcasts.length == 1);
	assert(fixture.service.snapshotMessages() == snapshot);
}

unittest
{
	import core.time : seconds;

	auto fixture = new UsageTestFixture;
	fixture.configure("{claude: {usage_polling_period: {turns: 3, timespan: {seconds: 5}}}, "
		~ "custom: {driver: claude, usage_polling_period: {turns: 2, timespan: {seconds: 2}}}}");
	auto first = new TestUsageSource;
	auto second = new TestUsageSource;
	fixture.service.sessionStarted(1, first, "work", "claude");
	assert(first.requests == 1);
	assert(fixture.arms == 1);
	assert(fixture.delay == 5.seconds);
	fixture.now += 1.seconds;
	fixture.service.sessionStarted(2, second, "work", "custom");
	assert(second.requests == 0);
	assert(fixture.delay == 1.seconds);
	assert(fixture.arms == 2);
	fixture.fire();
	assert(first.requests == 1 && second.requests == 0);
	assert(fixture.arms == 3);

	first.settle();
	assert(fixture.broadcasts.length == 1);
	enum turn = `{"type":"turn/result"}`;
	fixture.service.observeEvent(1, turn);
	assert(first.requests == 1);
	fixture.service.observeEvent(1, turn);
	assert(first.requests == 2);
	assert(fixture.arms == 4);
	first.settle();

	fixture.service.observeEvent(1, turn);
	fixture.fire();
	assert(second.requests == 1);
	assert(fixture.arms == 5);
	second.settle();
	fixture.service.observeEvent(1, turn);
	assert(first.requests == 2);

	second.running = false;
	fixture.fire();
	assert(first.requests == 3 && second.requests == 1);
	assert(fixture.arms == 6);
	fixture.service.sessionEnded(2);
	assert(fixture.delay == 5.seconds);
	fixture.service.sessionEnded(1);
	assert(fixture.timer is null);
	auto snapshot = fixture.service.snapshotMessages();
	first.settle("seven_day");
	assert(fixture.broadcasts.length == 1);
	assert(fixture.service.snapshotMessages() == snapshot);
}

unittest
{
	auto fixture = new UsageTestFixture;
	enum config = "{claude: {usage_polling_period: {turns: 1, timespan: {seconds: 5}}}}";
	fixture.configure(config);
	auto source = new TestUsageSource;
	fixture.service.sessionStarted(1, source, "work", "claude");
	source.settle();
	source.running = false;

	fixture.fire();
	assert(source.requests == 1);
	assert(fixture.timer is null);
	fixture.configure(config);
	fixture.service.observeEvent(1, `{"type":"turn/result"}`);
	fixture.service.sessionStarted(2, source, "work", "claude");
	fixture.service.sessionEnded(2);
	assert(source.requests == 1);
	assert(fixture.timer is null);

	auto replacement = new TestUsageSource;
	fixture.service.sessionStarted(3, replacement, "work", "claude");
	assert(replacement.requests == 1);
	assert(fixture.timer !is null);
}

unittest
{
	import core.time : seconds;

	auto fixture = new UsageTestFixture;
	enum longPeriod = "{claude: {usage_polling_period: {timespan: {seconds: 10}}}}";
	enum shortPeriod = "{claude: {usage_polling_period: {timespan: {seconds: 5}}}}";
	fixture.configure(longPeriod);
	auto source = new TestUsageSource;
	fixture.service.sessionStarted(1, source, "work", "claude");
	source.settle();

	auto deadline = fixture.now + fixture.delay;
	auto timer = fixture.timer;
	fixture.now += 3.seconds;
	fixture.configure(longPeriod);
	assert(fixture.timer is timer);
	assert(fixture.arms == 1);

	fixture.configure(shortPeriod);
	assert(fixture.arms == 2);
	assert(fixture.delay == 2.seconds);
	fixture.fire();
	assert(fixture.now == deadline - 5.seconds);
	assert(source.requests == 2);
}

unittest
{
	import std.exception : assertThrown;
	import std.algorithm : canFind;

	auto fixture = new UsageTestFixture;
	fixture.service.sessionStarted(1, new TestUsageSource, "work", "claude");
	assertThrown!Exception(fixture.service.observeEvent(1, `{}`));
	assertThrown!Exception(fixture.service.observeEvent(1, `{"type":"session/rate_limit"}`));
	fixture.service.observeEvent(1, `{"type":"turn/result"}`);
	assert(fixture.service.snapshotMessages().length == 0);

	fixture.service.observeEvent(1,
		`{"type":"turn/result","credential_expires_at":"2099-01-01T00:00:00Z"}`);
	assert(fixture.broadcasts.length == 1);
	assert(fixture.service.snapshotMessages()[0].canFind("2099-01-01T00:00:00Z"));
}

unittest
{
	import core.time : seconds;
	import std.conv : to;

	auto fixture = new UsageTestFixture;
	fixture.configure("{claude: {usage_polling_period: {turns: 1}}}");
	auto source = new TestUsageSource;
	fixture.service.sessionStarted(1, source, "work", "claude");
	fixture.now += 1.seconds;
	fixture.service.observeEvent(1, `{"type":"session/rate_limit",
		"rate_limit_info":{"rateLimitType":"five_hour","utilization":0.42}}`);
	fixture.now += 1.seconds;
	source.settle();

	auto message = parseJSON(fixture.service.snapshotMessages()[0]);
	assert(to!double(message["limits"]["five_hour"]["utilization"].toString()) == 42);
	assert(fixture.broadcasts.length == 1);
}

unittest
{
	auto fixture = new UsageTestFixture;
	fixture.configure("{claude: {usage_polling_period: {turns: 1}}}");
	auto source = new TestUsageSource;
	fixture.service.sessionStarted(1, source, "work", "claude");
	assert(source.requests == 1);
	source.settle();

	fixture.service.observeEvent(1, `{"type":"turn/noop"}`);
	assert(source.requests == 1);
	assert(fixture.service.schedules_["work"].turnsSinceRefresh == 0);
	fixture.service.observeEvent(1, `{"type":"turn/result"}`);
	assert(source.requests == 2);
}
