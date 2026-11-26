/// Helpers for unit tests.
module cydo.foundation.testing;

version (unittest):

/// Run what has been scheduled for the next event-loop tick, and whatever
/// that schedules in turn, without running the event loop itself: promise
/// handlers, in tests that own no sockets or timers.
void drainNextTicks()
{
	import ae.net.asockets : socketManager;

	// Use ae's batch drain so callbacks scheduled during a drain stay queued
	// for the next batch. Tests using this helper intentionally leave I/O alone.
	while (__traits(getMember, socketManager, "nextTickHandlers").length)
		__traits(getMember, socketManager, "nextTickHandlers").drain();
}

/// Drain promise callbacks and run timers already due without waiting for I/O
/// or advancing the clock to a future deadline.
void drainNextTicksAndDueTimers()
{
	import core.time : MonoTime;
	import ae.sys.timing : mainTimer;

	do
		drainNextTicks();
	while (mainTimer.prod(MonoTime.currTime()));
}
