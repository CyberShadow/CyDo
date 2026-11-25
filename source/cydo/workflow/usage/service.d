module cydo.workflow.usage.service;

import core.time : MonoTime;
import std.exception : enforce;
import std.json : parseJSON;

import ae.utils.json : JSONOptional, JSONPartial, jsonParse;

import cydo.domain.usage.tracker : AgentUsageTracker;
import cydo.protocol : SessionRateLimitEvent;

class ClaudeUsageService
{
	private struct Registration
	{
		string profile;
		string agentName;
	}

	private Registration[int] sessions_;
	private AgentUsageTracker tracker_;
	private void delegate(string) broadcast_;

	this(void delegate(string) broadcast)
	{
		tracker_ = new AgentUsageTracker();
		broadcast_ = broadcast;
	}

	void sessionStarted(int tid, string profile, string agentName)
	{
		sessions_[tid] = Registration(profile, agentName);
	}

	void sessionEnded(int tid)
	{
		sessions_.remove(tid);
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
					MonoTime.currTime, payload))
					broadcast_(payload);
				break;
			case "turn/result":
				if (tracker_.applyCredentialExpiry(registration.profile,
					jsonParse!CredentialProbe(translated).credential_expires_at, payload))
					broadcast_(payload);
				break;
			default:
				break;
		}
	}

	string[] snapshotMessages()
	{
		return tracker_.snapshotMessages();
	}
}
