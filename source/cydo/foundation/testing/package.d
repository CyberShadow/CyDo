/// Helpers for unit tests.
module cydo.foundation.testing;

version (unittest):

/// Run what has been scheduled for the next event-loop tick, and whatever
/// that schedules in turn, without running the event loop itself: promise
/// handlers, in tests that own no sockets or timers.
void drainNextTicks()
{
	import ae.net.asockets : socketManager;

	for (;;)
	{
		auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
		if (handlers.length == 0)
			return;
		mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
		foreach (handler; handlers)
			handler();
	}
}
