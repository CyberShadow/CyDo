module cydo.runtime.shutdown;

import ae.net.asockets : DisconnectType;
import ae.sys.data : Data;

// Write end of the shutdown self-pipe; written to by the C signal handler.
// Initialised in setupShutdownPipe() before socketManager.loop() runs.
private shared int shutdownPipeFd = -1;

/// Async-signal-safe SIGTERM/SIGINT handler: writes one byte to the self-pipe
/// so the event loop thread picks it up without any GC interaction.
extern(C) private nothrow @nogc
void shutdownSignalHandler(int sig) @system
{
	import core.sys.posix.unistd : write;
	int fd = shutdownPipeFd;
	if (fd >= 0)
	{
		ubyte[1] b = [1];
		write(fd, b.ptr, 1);
	}
}

/// Self-pipe shutdown: installs signal handlers that write to a pipe; a
/// daemon FileConnection on the read end drives the shutdown callback from
/// within the event loop thread without acquiring the GC lock.
// pipe2 is Linux-only; declare it directly rather than relying on druntime bindings.
private extern(C) int pipe2(int* pipefd, int flags) nothrow @nogc @system;

void setupShutdownPipe(void delegate() onShutdown)
{
	import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK;
	import core.sys.posix.signal : SIGTERM, SIGINT, SIGPIPE, SIG_IGN, sigaction, sigaction_t, sigemptyset, SA_RESETHAND;
	import ae.net.asockets : FileConnection;

	// pipe2 with O_CLOEXEC|O_NONBLOCK: FDs are not inherited by child processes
	// (claude, codex, etc.) and the write end never blocks in the signal handler.
	int[2] fds;
	pipe2(fds.ptr, O_CLOEXEC | O_NONBLOCK);

	// Store write fd globally for the C-level signal handler.
	shutdownPipeFd = fds[1];

	// Daemon read connection — does not keep the event loop alive by itself.
	auto readConn = new FileConnection(fds[0]);
	readConn.daemonRead = true;
	bool shutdownTriggered;
	readConn.handleReadData = (Data) {
		import std.logger : infof;
		if (!shutdownTriggered)
		{
			shutdownTriggered = true;
			infof("shutdown pipe fired, calling app.shutdown()");
			onShutdown();
			infof("app.shutdown() returned");
		}
	};
	readConn.handleDisconnect = (string reason, DisconnectType) {
		import std.logger : infof;
		infof("shutdown pipe read end disconnected: %s", reason);
	};

	// Install raw signal handler — no D runtime involved, no GC.
	sigaction_t sa;
	sa.sa_handler = &shutdownSignalHandler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESETHAND; // reset to SIG_DFL after first delivery
	sigaction(SIGTERM, &sa, null);
	sigaction(SIGINT,  &sa, null);

	// SIGPIPE: ignore. Writes to closed pipes return EPIPE which ae
	// propagates as a normal disconnect; killing the process on SIGPIPE
	// is never desirable for a long-lived event-loop server.
	sigaction_t saPipe;
	saPipe.sa_handler = SIG_IGN;
	sigemptyset(&saPipe.sa_mask);
	sigaction(SIGPIPE, &saPipe, null);
}
