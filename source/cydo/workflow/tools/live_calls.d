module cydo.workflow.tools.live_calls;

import std.datetime : Clock;
import std.logger : tracef;

import ae.utils.json : toJson;
import ae.utils.time.types : AbsTime;

import cydo.mcp : ToolCallCancellation;
import cydo.mcp.tools : ToolCallEnricher;
import cydo.protocol : CydoItemEnrichedEvent, TranslatedEvent;

package(cydo):

struct LiveToolCallsHost
{
	void delegate(int tid, TranslatedEvent ev) appendTaskEvent;
	ulong delegate(int tid) historyGeneration;
}

/// A task has a scope only while its agent session owns the mapping. Calls
/// publish through their own scope, and closing it cancels all unsettled calls.
/// Starts come only from live appends in this turn. Their history generation
/// must still match to publish immediately. Only a fresh live start releases
/// a hold, and a turn end or scope close discards the per-turn state.
private final class SessionToolCalls
{
	LiveToolCallsHost host;
	int tid;
	bool closed;
	LiveToolCall[] admitted;
	ulong[string] turnStarts;
	private struct HeldEnrichment
	{
		TranslatedEvent event;
		ToolCallCancellation cancellation;
	}

	HeldEnrichment[][string] held;

	this(LiveToolCallsHost host, int tid)
	{
		this.host = host;
		this.tid = tid;
	}

	void publish(CydoItemEnrichedEvent enrichment, ToolCallCancellation cancellation)
	{
		auto event = TranslatedEvent(toJson(enrichment), null, AbsTime(Clock.currStdTime));
		auto started = enrichment.item_id in turnStarts;
		if (started !is null && *started == host.historyGeneration(tid))
			host.appendTaskEvent(tid, event);
		else
			held[enrichment.item_id] ~= HeldEnrichment(event, cancellation);
	}

	void toolStarted(string itemId, ulong generation)
	{
		turnStarts[itemId] = generation;
		if (auto pending = itemId in held)
		{
			auto events = *pending;
			held.remove(itemId);
			foreach (entry; events)
			{
				if (entry.cancellation.cancelled)
				{
					tracef("Task %d discarding held enrichment for cancelled tool call %s", tid, itemId);
					continue;
				}
				host.appendTaskEvent(tid, entry.event);
			}
		}
	}

	void turnEnded()
	{
		if (held.length > 0)
			tracef("Task %d discarding tool enrichments awaiting starts: %s", tid, held.keys);
		turnStarts = null;
		held = null;
	}

	void abandon()
	{
		foreach (call; admitted.dup)
			call.cancellation_.cancel();
	}

	void close()
	{
		closed = true;
		turnEnded();
		abandon();
	}
}

final class LiveToolCall : ToolCallEnricher
{
	private SessionToolCalls session_;
	private string itemId_;
	private ToolCallCancellation cancellation_;
	private bool settled_;

	private this(SessionToolCalls session, string itemId, ToolCallCancellation cancellation)
	{
		session_ = session;
		itemId_ = itemId;
		cancellation_ = cancellation;
	}

	void enrich(CydoItemEnrichedEvent enrichment)
	{
		assert(!settled_, "Enrichment from a settled tool call");
		assert(enrichment.item_id.length == 0
			&& (enrichment.target_tid != 0 || enrichment.spawned_child != enrichment.spawned_child.init));
		enrichment.item_id = itemId_;
		if (cancellation_.cancelled)
			return;
		assert(!session_.closed);
		session_.publish(enrichment, cancellation_);
	}
}

final class LiveToolCalls
{
	private LiveToolCallsHost host_;
	private SessionToolCalls[int] scopes_;
	private bool allClosed_;

	this(LiveToolCallsHost host)
	{
		host_ = host;
	}

	void openTask(int tid)
	{
		closeTask(tid);
		if (!allClosed_)
			scopes_[tid] = new SessionToolCalls(host_, tid);
	}

	void closeTask(int tid)
	{
		if (auto entry = tid in scopes_)
		{
			auto scope_ = *entry;
			scopes_.remove(tid);
			scope_.close();
		}
	}

	void closeAll()
	{
		allClosed_ = true;
		foreach (tid; scopes_.keys)
			closeTask(tid);
	}

	LiveToolCall register(int tid, string itemId, ToolCallCancellation cancellation)
	{
		auto session = scopes_.get(tid, null);
		auto call = new LiveToolCall(session, itemId, cancellation);
		if (session is null)
			cancellation.cancel();
		else
			session.admitted ~= call;
		return call;
	}

	void settle(LiveToolCall call)
	{
		import std.algorithm.mutation : remove;
		import std.algorithm.searching : countUntil;

		assert(!call.settled_);
		call.settled_ = true;
		if (auto session = call.session_)
		{
			auto index = session.admitted.countUntil(call);
			assert(index >= 0);
			session.admitted = session.admitted.remove(index);
			call.session_ = null;
		}
	}

	void abandonToolCalls(int tid)
	{
		if (auto session = tid in scopes_)
			(*session).abandon();
	}

	void toolStarted(int tid, string itemId, ulong generation)
	{
		if (auto session = tid in scopes_)
			(*session).toolStarted(itemId, generation);
	}

	void turnEnded(int tid)
	{
		if (auto session = tid in scopes_)
			(*session).turnEnded();
	}
}

version (unittest) private final class LiveToolCallsFixture
{
	import ae.utils.json : jsonParse;

	ulong generation = 1;
	CydoItemEnrichedEvent[][int] events;
	TranslatedEvent lastEvent;
	LiveToolCalls calls;

	this()
	{
		calls = new LiveToolCalls(LiveToolCallsHost(
			appendTaskEvent: (int tid, TranslatedEvent event) {
				lastEvent = event;
				events[tid] ~= jsonParse!CydoItemEnrichedEvent(event.translated);
			},
			historyGeneration: (int tid) => generation,
		));
	}

	LiveToolCall registerX()
	{
		return calls.register(1, "x", new ToolCallCancellation);
	}
}

// A live start already in history allows immediate publication.
unittest
{
	import std.algorithm : canFind;

	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.toolStarted(1, "x", f.generation);
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 1);
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 3)]);
	assert(!f.lastEvent.translated.canFind(`"spawned_child"`));
}

unittest
{
	import std.algorithm : canFind;
	import cydo.protocol : ItemEnrichmentSpawnedChild;

	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.toolStarted(1, "x", f.generation);
	auto child = ItemEnrichmentSpawnedChild(0, 3);
	f.registerX().enrich(CydoItemEnrichedEvent(spawned_child: child));
	assert(f.events.length == 1);
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", spawned_child: child)]);
	assert(!f.lastEvent.translated.canFind(`"target_tid"`));
}

// An early call waits for its own start, then flushes in emission order.
unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.openTask(2);
	auto call = f.registerX();
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	call.enrich(CydoItemEnrichedEvent(target_tid: 4));
	assert(f.events.length == 0);
	f.calls.toolStarted(1, "other", f.generation);
	f.calls.toolStarted(2, "x", f.generation);
	assert(f.events.length == 0);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events[1] == [
		CydoItemEnrichedEvent(item_id: "x", target_tid: 3),
		CydoItemEnrichedEvent(item_id: "x", target_tid: 4),
	]);
}

// Cancelling a call after it enriches prevents publication when its start arrives.
unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto cancellation = new ToolCallCancellation;
	auto call = f.calls.register(1, "x", cancellation);
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	cancellation.cancel();
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events.length == 0);
}

// Abandoning a task's calls suppresses enrichment already held for a late start.
unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto call = f.registerX();
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	f.calls.abandonToolCalls(1);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events.length == 0);
}

// An Answer can settle before its start is read.
unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto call = f.registerX();
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	f.calls.settle(call);
	assert(f.events.length == 0);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 3)]);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto cancellation = new ToolCallCancellation;
	auto call = f.calls.register(1, "x", cancellation);
	f.calls.toolStarted(1, "x", f.generation);
	f.calls.closeTask(1);
	assert(cancellation.cancelled);
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	f.calls.openTask(1);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events.length == 0);
	call.enrich(CydoItemEnrichedEvent(target_tid: 4));
	assert(f.events.length == 0);
}

// Abandoning a task's calls only cancels its unsettled calls, and keeps it open.
unittest
{
	auto f = new LiveToolCallsFixture;
	auto first = new ToolCallCancellation;
	auto second = new ToolCallCancellation;
	auto settled = new ToolCallCancellation;
	auto unrelated = new ToolCallCancellation;
	f.calls.openTask(1);
	f.calls.openTask(2);
	auto call = f.calls.register(1, "x", first);
	f.calls.register(1, "second", second);
	f.calls.settle(f.calls.register(1, "settled", settled));
	f.calls.register(2, "unrelated", unrelated);
	f.calls.toolStarted(1, "x", f.generation);

	f.calls.abandonToolCalls(1);
	assert(first.cancelled && second.cancelled);
	assert(!settled.cancelled && !unrelated.cancelled);
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 4));
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 4)]);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.toolStarted(1, "other", f.generation);
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 3));
	f.calls.turnEnded(1);
	assert(f.calls.scopes_[1].turnStarts.length == 0);
	assert(f.calls.scopes_[1].held.length == 0);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events.length == 0);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.toolStarted(1, "x", f.generation);
	f.calls.turnEnded(1);
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 3)]);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	f.calls.toolStarted(1, "x", f.generation);
	++f.generation;
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 3));
	assert(f.events.length == 0);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 3)]);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	void assertRejected(int tid)
	{
		auto cancellation = new ToolCallCancellation;
		auto call = f.calls.register(tid, "x", cancellation);
		assert(cancellation.cancelled);
		call.enrich(CydoItemEnrichedEvent(target_tid: 3));
		f.calls.settle(call);
		assert(f.events.length == 0);
	}

	assertRejected(3);
	f.calls.openTask(1);
	f.calls.openTask(2);
	auto first = new ToolCallCancellation;
	auto second = new ToolCallCancellation;
	f.calls.register(1, "x", first);
	f.calls.register(2, "x", second);
	f.calls.closeTask(1);
	assert(first.cancelled && !second.cancelled);
	assertRejected(1);

	f.calls.openTask(1);
	auto reopened = new ToolCallCancellation;
	f.calls.register(1, "x", reopened);
	assert(!reopened.cancelled);
	f.calls.closeAll();
	assert(second.cancelled && reopened.cancelled);
	assertRejected(3);
	f.calls.openTask(1);
	assertRejected(1);
	assert(f.calls.scopes_.length == 0);
}

// Replacing a session cancels its calls and discards its held enrichments.
unittest
{
	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto cancellation = new ToolCallCancellation;
	auto call = f.calls.register(1, "x", cancellation);
	call.enrich(CydoItemEnrichedEvent(target_tid: 3));
	f.calls.openTask(1);
	assert(cancellation.cancelled);
	f.calls.toolStarted(1, "x", f.generation);
	assert(f.events.length == 0);
	f.registerX().enrich(CydoItemEnrichedEvent(target_tid: 4));
	assert(f.events[1] == [CydoItemEnrichedEvent(item_id: "x", target_tid: 4)]);
}

unittest
{
	auto f = new LiveToolCallsFixture;
	foreach (tid; 1 .. 4)
	{
		f.calls.openTask(tid);
		f.calls.toolStarted(tid, "x", f.generation);
		f.calls.closeTask(tid);
		f.calls.toolStarted(tid, "x", f.generation);
		f.calls.turnEnded(tid);
	}
	f.calls.toolStarted(99, "x", f.generation);
	f.calls.turnEnded(99);
	assert(f.calls.scopes_.length == 0);
}

debug unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	auto f = new LiveToolCallsFixture;
	f.calls.openTask(1);
	auto call = f.registerX();
	assertThrown!AssertError(call.enrich(CydoItemEnrichedEvent(item_id: "other", target_tid: 3)));
	assertThrown!AssertError(call.enrich(CydoItemEnrichedEvent.init));
	f.calls.settle(call);
	assertThrown!AssertError(call.enrich(CydoItemEnrichedEvent(target_tid: 3)));
}
