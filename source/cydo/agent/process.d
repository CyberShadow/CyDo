module cydo.agent.process;

import core.sys.posix.signal : SIGINT, SIGKILL, SIGTERM;
import core.sys.posix.unistd : dup;
import core.time : Duration, seconds;

import std.exception : enforce;
import std.logger : tracef, warningf;
import std.process : Pid, Pipe, Redirect, Config, spawnProcess, pipe, kill;
import std.stdio : File;

import ae.net.asockets : ConnectionAdapter, ConnectionState, DisconnectType,
    disconnectable, Duplex, FileConnection, IConnection, LineBufferedAdapter,
	onNextTick, socketManager;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;
import ae.sys.timing : setTimeout, TimerTask;
import ae.utils.array : asBytes;
import ae.utils.jsonrpc : JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise;

import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.net.jsonrpc.contentlength : ContentLengthAdapter;

/// Selects the framing mode for stdout of an AgentProcess.
enum FramingMode { ndjson, contentLength, raw }

struct ProcessResourceLimits
{
	ulong addressSpace, cpuSeconds, fileSize;
}

/// Run one line handler, containing any fault and reporting it through
/// `report` (which may be null). Lives outside AgentProcess so the
/// containment contract is testable without a child process or an event loop.
private void runContainedLineHandler(string source, scope void delegate() handler,
	scope void delegate(string source, Exception e) report)
{
	try
		handler();
	catch (Exception e)
	{
		warningf("agent %s line handler error: %s", source, e.msg);
		tracef("agent %s line handler error detail: %s", source, e.toString());
		if (report is null)
			return;
		try
			report(source, e);
		catch (Exception reportError)
			warningf("agent %s line handler error report failed: %s",
				source, reportError.msg);
	}
}

unittest
{
	// 1. a handler that returns normally runs once and reports nothing
	int handled, reported;
	runContainedLineHandler("stdout", { handled++; },
		(string source, Exception e) { reported++; });
	assert(handled == 1 && reported == 0);

	// 2. a throwing handler is contained, and the fault reaches the report
	string reportedSource, reportedMessage;
	runContainedLineHandler("stdout", { throw new Exception("bad line"); },
		(string source, Exception e) {
			reportedSource = source;
			reportedMessage = e.msg;
		});
	assert(reportedSource == "stdout" && reportedMessage == "bad line");

	// 3. with no report hook the fault is still contained
	runContainedLineHandler("stderr", { throw new Exception("bad line"); }, null);

	// 4. a report hook that throws in turn is contained as well: nothing may
	// escape into the event loop, however badly a driver misbehaves
	runContainedLineHandler("stdout", { throw new Exception("bad line"); },
		(string source, Exception e) { throw new Exception("bad report"); });
}

/// RPC operations on a transport whose disconnect handler is fixed at construction.
package(cydo.agent) final class AgentRpcCodec
{
	private JsonRpcCodec codec;

	this(IConnection connection, IConnection.DisconnectHandler onDisconnect = null)
	{
		codec = new JsonRpcCodec(connection);
		codec.handleDisconnect = onDisconnect;
	}

	@property void handleRequest(Promise!JsonRpcResponse delegate(JsonRpcRequest) handler)
	{
		codec.handleRequest = handler;
	}

	Promise!JsonRpcResponse sendRequest(JsonRpcRequest request)
	{
		return codec.sendRequest(request);
	}

	void sendNotification(JsonRpcRequest request)
	{
		codec.sendNotification(request);
	}
}

/// Notify routes after all promise continuations synchronously reachable from
/// work already queued have drained, including submission commit and ACK,
/// inject forwarding, and final history publication. Chains awaiting further
/// I/O are outside this boundary. Entry points before fanout still follow the
/// retiring-state rules.
package(cydo.agent) void scheduleOwnerExit(void delegate() fanout)
{
	// Arm the timer from a tick so epoll cannot run it in the I/O batch
	// that reported exit, before the promise queue drains.
	onNextTick(socketManager, { setTimeout(fanout, Duration.zero); });
}

/// Readiness remains open until the owner reports its terminal event.
package(cydo.agent) struct ReadinessQueue
{
	private enum State { pending, open, closed }
	private State state;
	private Exception error;

	private struct Waiter
	{
		void delegate() ready;
		void delegate(Exception) failed;
	}
	private Waiter[] waiting;

	@property bool isOpen() const { return state == State.open; }

	void wait(void delegate() ready, void delegate(Exception) failed)
	{
		final switch (state)
		{
		case State.pending:
			waiting ~= Waiter(ready, failed);
			break;
		case State.open:
			try
				ready();
			catch (Exception e)
				failed(e);
			break;
		case State.closed:
			failed(error);
			break;
		}
	}

	void open()
	{
		enforce(state == State.pending, "Readiness must be pending to open");
		state = State.open;
		auto batch = waiting;
		waiting = null;
		foreach (waiter; batch)
			wait(waiter.ready, waiter.failed);
	}

	void close(Exception failure)
	{
		enforce(state != State.closed, "Readiness already closed");
		state = State.closed;
		error = failure;
		auto batch = waiting;
		waiting = null;
		foreach (waiter; batch)
			waiter.failed(error);
	}
}

/// Grace before starting escalation for an RPC child.
package(cydo.agent) enum RpcRetirement { codex, copilot }

/// Manages a child process with event-loop-integrated I/O.
/// Uses FileConnection to wrap pipe fds, Duplex to combine stdin/stdout,
/// and a framing adapter (LineBufferedAdapter or ContentLengthAdapter) for message splitting.
class AgentProcess
{
	private Pid pid;
	private FileConnection stdinConn;
	private bool independentPipes;
	private bool stdinClosed;
	private ConnectionAdapter stdoutLines;
	private ConnectionAdapter stderrLines;
	private Duplex duplex;
	private bool exited;
	private int exitStatus;
	private bool stdoutEOF;
	private bool stderrEOF;

	private bool codecAttached;
	private bool retiring;
	private bool exitFired;
	private TimerTask stderrDrainTimer;
	private TimerTask killTimer;
	private TimerTask killForcedTimer;
	private TimerTask killStdoutDrainTimer;
	private bool waitForPipeDrain;

	void delegate(string line) onStdoutLine;
	void delegate(string line) onStderrLine;
	void delegate(int status) onExit;

	/// Called when a line handler throws. These handlers run from the socket
	/// event loop, which has no way to attribute a fault to one agent: an
	/// exception that escapes unwinds out of the loop and ends the process,
	/// so a single session's bad line would take down every other session
	/// with it. Faults are contained here and reported through this hook
	/// instead; drivers set it to surface the fault on the affected task.
	void delegate(string source, Exception e) onLineHandlerError;

	/// Spawn a child process with the given arguments and optional environment/workdir.
	/// If noStdin is true, stdin is redirected from /dev/null (no Duplex needed).
	/// If logName is non-empty, a LoggingAdapter is inserted above the framing adapter
	/// to trace-log logical messages at the trace level.
	/// With independentPipes, this process owns all three endpoints until they
	/// close. Stdin never enters disconnecting, so forceClosePipes can abort it
	/// even while queued writes are pending.
	this(string[] args, string[string] env = null, string workDir = null, bool noStdin = false,
		FramingMode mode = FramingMode.ndjson, string logName = null,
		bool waitForPipeDrain = true, ProcessResourceLimits resourceLimits = ProcessResourceLimits.init,
		bool independentPipes = false)
	{
		enforce(!(noStdin && independentPipes), "Independent pipes require stdin");
		this.independentPipes = independentPipes;
		this.waitForPipeDrain = waitForPipeDrain;
		Pipe stdinPipe;
		if (!noStdin)
			stdinPipe = pipe();
		auto stdoutPipe = pipe();
		auto stderrPipe = pipe();

		tracef("Spawning agent process: %s", args);
		tracef("Environment: %s", env);
		auto config = Config.none;
		version (Posix)
		{
			if (resourceLimits != ProcessResourceLimits.init)
				config.preExecDelegate = delegate() nothrow @nogc @trusted {
					import core.sys.posix.sys.resource : RLIMIT_AS, RLIMIT_CPU, RLIMIT_FSIZE,
						rlimit, setrlimit;

					bool apply(int resource, ulong value) nothrow @nogc
					{
						if (!value)
							return true;
						auto limit = rlimit(value, value);
						return setrlimit(resource, &limit) == 0;
					}

					return apply(RLIMIT_AS, resourceLimits.addressSpace)
						&& apply(RLIMIT_CPU, resourceLimits.cpuSeconds)
						&& apply(RLIMIT_FSIZE, resourceLimits.fileSize);
				};
		}
		pid = spawnProcess(
			args,
			noStdin ? File("/dev/null") : stdinPipe.readEnd,
			stdoutPipe.writeEnd,
			stderrPipe.writeEnd,
			env,
			config,
			workDir,
		);

		// Close the child-side ends in the parent
		if (!noStdin)
			stdinPipe.readEnd.close();
		stdoutPipe.writeEnd.close();
		stderrPipe.writeEnd.close();

		int stdoutFd, stderrFd;

		if (!noStdin)
		{
			// Dup the fds so FileConnection can own them independently
			auto stdinFd = dup(stdinPipe.writeEnd.fileno);
			stdoutFd = dup(stdoutPipe.readEnd.fileno);
			stderrFd = dup(stderrPipe.readEnd.fileno);

			// Close the originals now that we have dups
			stdinPipe.writeEnd.close();
			stdoutPipe.readEnd.close();
			stderrPipe.readEnd.close();

			// Wrap fds into event loop
			stdinConn = new FileConnection(stdinFd);
			auto stdoutConn = new FileConnection(stdoutFd);

			IConnection transport = stdoutConn;
			if (!independentPipes)
			{
				duplex = new Duplex(stdoutConn, stdinConn);
				transport = duplex;
			}

			ConnectionAdapter framedConn;
			if (mode == FramingMode.contentLength)
				framedConn = new ContentLengthAdapter(transport);
			else if (mode == FramingMode.raw)
				framedConn = new ConnectionAdapter(transport);
			else
				framedConn = new LineBufferedAdapter(transport, "\n");

			// Optionally log logical messages above the framing adapter.
			stdoutLines = logName.length ? new LoggingAdapter(framedConn, logName) : framedConn;
		}
		else
		{
			stdoutFd = dup(stdoutPipe.readEnd.fileno);
			stderrFd = dup(stderrPipe.readEnd.fileno);

			stdoutPipe.readEnd.close();
			stderrPipe.readEnd.close();

			auto stdoutConn = new FileConnection(stdoutFd);

			ConnectionAdapter framedConn;
			if (mode == FramingMode.contentLength)
				framedConn = new ContentLengthAdapter(stdoutConn);
			else if (mode == FramingMode.raw)
				framedConn = new ConnectionAdapter(stdoutConn);
			else
				framedConn = new LineBufferedAdapter(stdoutConn, "\n");

			// Optionally log logical messages above the framing adapter.
			stdoutLines = logName.length ? new LoggingAdapter(framedConn, logName) : framedConn;
		}

		auto stderrConn = new FileConnection(stderrFd);

		stdoutLines.handleReadData = (Data data) {
			if (onStdoutLine)
			{
				auto text = cast(string) data.toGC();
				contained("stdout", { onStdoutLine(text); });
			}
		};

		stdoutLines.handleDisconnect = &onStdoutDisconnect;

		if (independentPipes)
			stderrLines = new ConnectionAdapter(stderrConn);
		else
			stderrLines = new LineBufferedAdapter(stderrConn, "\n");
		stderrLines.handleReadData = (Data data) {
			if (onStderrLine)
			{
				auto text = cast(string) data.toGC();
				contained("stderr", { onStderrLine(text); });
			}
		};
		stderrLines.handleDisconnect = (string, DisconnectType) {
			stderrEOF = true;
			tryFireExit();
		};

		// Async process exit notification via SIGCHLD.
		// The process may have exited but stdout pipe data can still be
		// buffered in the kernel.  Defer onExit until both the process
		// has exited AND stdout has reached EOF so all output is drained.
		asyncWait(pid, (int status) {
			exited = true;
			exitStatus = status;
			tryFireExit();
		});
	}

	/// Run a line handler, keeping any fault out of the socket event loop.
	private void contained(string source, scope void delegate() handler)
	{
		runContainedLineHandler(source, handler, onLineHandlerError);
	}

	/// Fire onExit only once all conditions are met:
	/// the process has exited AND both stdout and stderr have been fully drained (EOF).
	/// If stderr is slow to drain (e.g. child processes hold the fd), a short
	/// timer fires onExit anyway to avoid blocking indefinitely.
	private void tryFireExit()
	{
		import core.time : msecs;

		if (exitFired)
			return;
		if (exited && (!waitForPipeDrain || (stdoutEOF && stderrEOF)))
			fireExit();
		else if (waitForPipeDrain && exited && stdoutEOF && !stderrEOF && stderrDrainTimer is null)
			stderrDrainTimer = setTimeout({
				stderrDrainTimer = null;
				fireExit(closeStderr: true);
			}, 2000.msecs);
	}

	private void fireExit(bool closeStderr = false)
	{
		exitFired = true;
		foreach (timer; [&stderrDrainTimer, &killTimer, &killForcedTimer, &killStdoutDrainTimer])
			if (*timer !is null)
			{
				(*timer).cancel();
				*timer = null;
			}
		if (closeStderr && stderrLines !is null)
		{
			auto lines = stderrLines;
			stderrLines = null;
			if (lines.state.disconnectable)
				lines.disconnect("stderr drain timeout");
		}
		if (onExit)
			onExit(exitStatus);
	}

	/// Send a message to the process stdin. The framing adapter handles encoding.
	void sendMessage(string line)
	{
		if (dead)
			throw new Exception("Agent process is no longer running");
		// Independent pipes keep stdout open when the stdin writer disconnects.
		if (independentPipes)
		{
			enforce(!stdinClosed, "Process stdin is closed");
			stdinConn.send(Data(line.asBytes));
		}
		else
			stdoutLines.send(Data(line.asBytes));
	}

	private void onStdoutDisconnect(string, DisconnectType)
	{
		stdoutEOF = true;
		tryFireExit();
	}

	private @property bool stdoutDisconnected() { return stdoutEOF; }
	/// Pipe liveness for line-based drivers. RPC owners use their own lifecycle.
	@property bool dead() { return stdoutDisconnected || exited; }

	/// Transfer the framed transport to a codec, forwarding disconnect after
	/// the codec settles its pending requests.
	package(cydo.agent) AgentRpcCodec attachJsonRpcCodec(
		IConnection.DisconnectHandler onDisconnect = null)
	{
		enforce(!codecAttached && !stdoutDisconnected,
			"JSON-RPC codec requires an open process transport without a codec");
		codecAttached = true;
		return new AgentRpcCodec(stdoutLines, (string reason, DisconnectType type) {
			if (stdoutEOF)
				return;
			stdoutEOF = true;
			scope (exit) tryFireExit();
			if (onDisconnect !is null)
				onDisconnect(reason, type);
		});
	}

	/// The underlying process PID, for use with asyncWait.
	@property Pid processId() { return pid; }

	/// Close all remaining endpoints, discarding queued input in independent mode.
	/// Safe after exit, including when descendants still hold inherited pipe FDs.
	void forceClosePipes()
	{
		if (independentPipes)
		{
			if (stdinConn.state == ConnectionState.connected)
				stdinConn.disconnect("force close", DisconnectType.error);
		}
		else
			closeStdin();
		if (stdoutLines !is null)
		{
			auto lines = stdoutLines;
			stdoutLines = null;
			if (lines.state.disconnectable)
				lines.disconnect("force close after SIGKILL");
		}
		if (stderrLines !is null)
		{
			auto lines = stderrLines;
			stderrLines = null;
			if (lines.state.disconnectable)
				lines.disconnect("force close after SIGKILL");
		}
		stdoutEOF = true;
		stderrEOF = true;
		tryFireExit();
	}

	/// Send a signal to the child process.
	void sendSignal(int sig)
	{
		if (!exited)
			kill(pid, sig);
	}

	/// Close stdin to signal EOF — the process will exit gracefully.
	void closeStdin()
	{
		if (independentPipes)
			return finishStdin();
		if (stdinConn !is null)
		{
			if (stdinConn.state.disconnectable)
				stdinConn.disconnect("closing stdin");
			stdinConn = null;
		}
	}

	private void finishStdin()
	{
		enforce(!stdinClosed, "Process stdin is closed");
		stdinClosed = true;
		if (stdinConn.state != ConnectionState.connected)
			return;
		// ae cannot abort a disconnecting writer. Wait for the queue to drain
		// before requesting a disconnect so forceClosePipes can still abort it.
		if (stdinConn.writePending)
			stdinConn.handleBufferFlushed = { stdinConn.disconnect("closing stdin"); };
		else
			stdinConn.disconnect("closing stdin");
	}

	/// Send SIGINT.
	void interrupt()
	{
		sendSignal(SIGINT);
	}

	/// Send SIGTERM.
	void terminate()
	{
		sendSignal(SIGTERM);
	}

	package(cydo.agent) void retire(RpcRetirement policy)
	{
		if (retiring)
			return;
		retiring = true;
		closeStdin();
		terminate();
		final switch (policy)
		{
		case RpcRetirement.codex:
			killAfterTimeout(0.seconds);
			break;
		case RpcRetirement.copilot:
			killAfterTimeout(3.seconds);
			break;
		}
	}

	/// If the process has not exited within `timeout`, send SIGTERM.
	/// If it still hasn't exited after another 2 seconds, send SIGKILL.
	void killAfterTimeout(Duration timeout, void delegate() onTimeout = null)
	{
		if (exitFired)
			return;
		killTimer = setTimeout({
			killTimer = null;
			if (exitFired)
				return;
			if (onTimeout !is null)
				onTimeout();
			if (exitFired)
				return;
			sendSignal(SIGTERM);
			killForcedTimer = setTimeout({
				killForcedTimer = null;
				if (exitFired)
					return;
				sendSignal(SIGKILL);
				import core.time : msecs;
				killStdoutDrainTimer = setTimeout({
					killStdoutDrainTimer = null;
					if (exitFired)
						return;
					forceClosePipes();
				}, 500.msecs);
				killStdoutDrainTimer.daemon = true;
			}, 2.seconds);
			killForcedTimer.daemon = true;
		}, timeout);
		killTimer.daemon = true;
	}

}

/// Wraps a framed connection to trace-log logical messages passing through it.
/// Use `<` prefix for inbound messages and `>` for outbound messages.
class LoggingAdapter : ConnectionAdapter
{
	string name;

	this(IConnection next, string name)
	{
		super(next);
		this.name = name;
	}

	override void onReadData(Data data)
	{
		data.enter((scope contents) {
			tracef("[%s] < %s", name, cast(string)contents);
		});
		super.onReadData(data);
	}

	override void send(scope Data[] data, int priority)
	{
		foreach (ref datum; data)
			datum.enter((scope contents) {
				tracef("[%s] > %s", name, cast(string)contents);
			});
		super.send(data, priority);
	}
}

// The codec owns the stdout transport, but EOF must still complete process exit.
unittest
{
	import std.exception : assertThrown;
	import ae.net.asockets : socketManager;

	auto child = new AgentProcess(["sh", "-c", "exit 23"]);
	auto codec = child.attachJsonRpcCodec();
	static assert(!__traits(hasMember, typeof(codec), "handleDisconnect"));
	assertThrown!Exception(child.attachJsonRpcCodec());

	int[] statuses;
	child.onExit = (int status) { statuses ~= status; };
	socketManager.loop();

	assert(child.stdoutDisconnected, "stdout EOF must reach AgentProcess");
	assert(statuses == [23], "EOF and child exit must produce one onExit callback");
}

// A socket callback can queue more work after scheduling owner exit.
unittest
{
	import ae.sys.timing : mainTimer;

	string[] order;
	auto child = new AgentProcess(["sh", "-c", "exit 0"]);
	auto codec = child.attachJsonRpcCodec((string, DisconnectType) {
		order ~= "socket EOF";
		auto nextTimer = mainTimer.getNextEvent();
		scheduleOwnerExit({ order ~= "owner exit"; });
		assert(mainTimer.getNextEvent() == nextTimer,
			"The socket callback must leave the existing timer schedule intact");
		onNextTick(socketManager, {
			order ~= "tick";
			onNextTick(socketManager, { order ~= "nested tick"; });
		});
	});
	socketManager.loop();

	assert(order == ["socket EOF", "tick", "nested tick", "owner exit"]);
}

// Give a child that survives retirement time to leave a marker, then exit so
// a regression cannot hang the suite. Keep the sleeper off the agent pipes.
version (unittest) package(cydo.agent) enum rpcChildSurvivalProbe =
	q"SH
	sleep 3 </dev/null >/dev/null 2>&1 &
	wait $!
	touch "$1"
SH";

unittest
{
	import ae.net.asockets : socketManager;
	import std.conv : to;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;

	auto marker = buildPath(tempDir, "cydo-rpc-eof-" ~ thisProcessID.to!string);
	scope (exit) if (exists(marker)) remove(marker);
	auto child = new AgentProcess(["sh", "-c",
		`trap 'exit 42' TERM; exec 1>&-;` ~ rpcChildSurvivalProbe, "test", marker]);
	int disconnects;
	int[] statuses;
	auto codec = child.attachJsonRpcCodec((string, DisconnectType) {
		++disconnects;
		child.retire(RpcRetirement.codex);
	});
	child.onExit = (int status) { statuses ~= status; };
	socketManager.loop();

	assert(disconnects == 1);
	assert(statuses == [42]);
	assert(!exists(marker));
}
