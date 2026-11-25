module cydo.workflow.history.last_work;

import std.typecons : Nullable;

import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent;
import cydo.foundation.platform.reverse_lines : foreachLineReverse;

Nullable!AbsTime lastWorkRecordTime(Agent agent, string path)
{
	Nullable!AbsTime result;
	foreachLineReverse(path, line => (result = agent.workRecordTime(line)).isNull);
	return result;
}

unittest
{
	import std.datetime : SysTime;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto path = buildPath(tempDir(), "cydo-last-claude-work-" ~ randomUUID().toString());
	scope (exit) remove(path);
	auto agent = new ClaudeCodeAgent;
	enum bookkeeping =
		"{\"type\":\"last-prompt\"}\n"
		~ "{\"type\":\"mode\"}\n"
		~ "{\"type\":\"session-owner\"}\n"
		~ "{\"type\":\"cost-state\"}\n"
		~ "{\"type\":\"attachment\",\"timestamp\":\"2026-03-30T16:00:00Z\"}\n";

	write(path,
		"{\"type\":\"user\",\"timestamp\":\"2026-03-30T12:00:00Z\"}\n"
		~ "{\"type\":\"assistant\",\"timestamp\":\"2026-03-30T13:00:00Z\"}\n"
		~ "{\"type\":\"assistant\",\"timestamp\":\"2026-03-30T14:00:00Z\"}\n"
		~ bookkeeping);
	assert(lastWorkRecordTime(agent, path).get.stdTime
		== SysTime.fromISOExtString("2026-03-30T14:00:00Z").stdTime);

	write(path, bookkeeping);
	assert(lastWorkRecordTime(agent, path).isNull);
}

unittest
{
	import std.datetime : SysTime;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;
	import cydo.agent.drivers.copilot : CopilotAgent;

	auto path = buildPath(tempDir(), "cydo-last-copilot-work-" ~ randomUUID().toString());
	scope (exit) remove(path);
	write(path,
		"{\"type\":\"assistant.message\",\"id\":\"1\",\"timestamp\":\"2026-03-30T14:00:00Z\"}\n"
		~ "{\"type\":\"user.message\",\"id\":\"2\",\"data\":{\"content\":\"steer\"}}\n");
	assert(lastWorkRecordTime(new CopilotAgent, path).get.stdTime
		== SysTime.fromISOExtString("2026-03-30T14:00:00Z").stdTime);
}
