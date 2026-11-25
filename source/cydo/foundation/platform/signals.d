module cydo.foundation.platform.signals;

import core.sys.posix.signal : SIGPIPE, SIG_IGN, sigaction, sigaction_t, sigemptyset;
import std.exception : errnoEnforce;

/// Ignore SIGPIPE so writes to closed pipes return EPIPE, which ae propagates
/// as a normal disconnect. The unittest runner calls this too, so tests see
/// production behavior.
void initializeProcessSignals()
{
	sigaction_t sa;
	sa.sa_handler = SIG_IGN;
	sigemptyset(&sa.sa_mask);
	errnoEnforce(sigaction(SIGPIPE, &sa, null) == 0, "sigaction(SIGPIPE)");
}

unittest
{
	import core.stdc.errno : EPIPE, errno;
	import core.sys.posix.signal : SIG_DFL;
	import core.sys.posix.unistd : close, pipe, write;

	sigaction_t current;
	errnoEnforce(sigaction(SIGPIPE, null, &current) == 0, "query SIGPIPE");
	assert(current.sa_handler == SIG_IGN, "The unittest runner must ignore SIGPIPE before running tests");

	sigaction_t defaults;
	defaults.sa_handler = SIG_DFL;
	sigemptyset(&defaults.sa_mask);
	errnoEnforce(sigaction(SIGPIPE, &defaults, null) == 0, "restore default SIGPIPE disposition");

	initializeProcessSignals();

	errnoEnforce(sigaction(SIGPIPE, null, &current) == 0, "query SIGPIPE");
	assert(current.sa_handler == SIG_IGN, "initializeProcessSignals must ignore SIGPIPE");

	int[2] fds;
	errnoEnforce(pipe(fds) == 0, "pipe");
	scope (exit) close(fds[1]);
	errnoEnforce(close(fds[0]) == 0, "close pipe reader");

	ubyte byteToWrite = 0;
	auto written = write(fds[1], &byteToWrite, 1);
	auto writeError = errno;
	assert(written == -1 && writeError == EPIPE, "Writing to a pipe with no reader must fail with EPIPE");
}
