module cydo.workflow.mailbox;

import ae.utils.promise : Promise, resolve;

package(cydo):

struct MailboxEvent
{
	enum Kind { batch, question, answer, failed }
	Kind kind;
	ulong batchId;
	int qid;
	string error;
}

struct Mailbox
{
	MailboxEvent[] events;
	Promise!MailboxEvent[] waiters;

	void push(MailboxEvent event)
	{
		if (waiters.length)
		{
			auto waiter = waiters[0];
			waiters = waiters[1 .. $];
			waiter.fulfill(event);
		}
		else
			events ~= event;
	}

	Promise!MailboxEvent take()
	{
		if (events.length)
		{
			auto event = events[0];
			events = events[1 .. $];
			return resolve(event);
		}
		auto waiter = new Promise!MailboxEvent;
		waiters ~= waiter;
		return waiter;
	}

	bool remove(bool delegate(in MailboxEvent) pred)
	{
		MailboxEvent[] remaining;
		bool removed;
		foreach (event; events)
			if (pred(event)) removed = true;
			else remaining ~= event;
		events = remaining;
		return removed;
	}

	void release(Exception cause)
	{
		foreach (waiter; waiters)
			waiter.reject(cause);
		waiters = null;
	}

	bool hasWaiter() const { return waiters.length != 0; }
	bool empty() const { return events.length == 0; }
}

unittest
{
	import ae.net.asockets : socketManager;
	void drain()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0) return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers) handler();
		}
	}
	Mailbox mailbox;
	MailboxEvent.Kind[] kinds;
	mailbox.push(MailboxEvent(MailboxEvent.Kind.question));
	mailbox.push(MailboxEvent(MailboxEvent.Kind.batch));
	mailbox.take().then((MailboxEvent e) { kinds ~= e.kind; }).ignoreResult();
	mailbox.take().then((MailboxEvent e) { kinds ~= e.kind; }).ignoreResult();
	drain();
	assert(kinds == [MailboxEvent.Kind.question, MailboxEvent.Kind.batch]);
	assert(mailbox.empty);
	auto first = mailbox.take();
	auto second = mailbox.take();
	first.then((MailboxEvent e) { kinds ~= e.kind; }).ignoreResult();
	second.then((MailboxEvent e) { kinds ~= e.kind; }).ignoreResult();
	mailbox.push(MailboxEvent(MailboxEvent.Kind.answer));
	mailbox.push(MailboxEvent(MailboxEvent.Kind.failed));
	drain();
	assert(kinds[$ - 2 .. $] == [MailboxEvent.Kind.answer, MailboxEvent.Kind.failed]);
	bool rejectedFirst, rejectedSecond;
	mailbox.take().except((Exception e) { rejectedFirst = e.msg == "ended"; }).ignoreResult();
	mailbox.take().except((Exception e) { rejectedSecond = e.msg == "ended"; }).ignoreResult();
	mailbox.release(new Exception("ended"));
	drain();
	assert(rejectedFirst && rejectedSecond && !mailbox.hasWaiter);
}
