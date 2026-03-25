module cydo.agent.process;

import core.sys.posix.signal : SIGINT, SIGTERM;
import core.sys.posix.unistd : dup;

import std.logger : tracef;
import std.process : Pid, Pipe, Redirect, Config, spawnProcess, pipe, kill;
import std.stdio : File;

import ae.net.asockets : ConnectionAdapter, ConnectionState, DisconnectType, Duplex, FileConnection, IConnection, LineBufferedAdapter;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;
import ae.sys.timing : setTimeout, TimerTask;
import ae.utils.array : asBytes;

import ae.net.jsonrpc.contentlength : ContentLengthAdapter;

/// Selects the framing mode for stdout of an AgentProcess.
enum FramingMode { ndjson, contentLength }

/// Manages a child process with event-loop-integrated I/O.
/// Uses FileConnection to wrap pipe fds, Duplex to combine stdin/stdout,
/// and a framing adapter (LineBufferedAdapter or ContentLengthAdapter) for message splitting.
class AgentProcess
{
	private Pid pid;
	private FileConnection stdinConn;
	private ConnectionAdapter stdoutLines;
	private LineBufferedAdapter stderrLines;
	private Duplex duplex;
	private bool exited;
	private int exitStatus;
	private bool stdoutEOF;
	private bool stderrEOF;

	private bool disconnected;
	private bool exitFired;
	private TimerTask stderrDrainTimer;

	void delegate(string line) onStdoutLine;
	void delegate(string line) onStderrLine;
	void delegate(int status) onExit;

	/// Spawn a child process with the given arguments and optional environment/workdir.
	/// If noStdin is true, stdin is redirected from /dev/null (no Duplex needed).
	/// If logName is non-empty, a LoggingAdapter is inserted below the framing adapter
	/// to trace-log raw I/O at the trace level.
	this(string[] args, string[string] env = null, string workDir = null, bool noStdin = false,
		FramingMode mode = FramingMode.ndjson, string logName = null)
	{
		Pipe stdinPipe;
		if (!noStdin)
			stdinPipe = pipe();
		auto stdoutPipe = pipe();
		auto stderrPipe = pipe();

		pid = spawnProcess(
			args,
			noStdin ? File("/dev/null") : stdinPipe.readEnd,
			stdoutPipe.writeEnd,
			stderrPipe.writeEnd,
			env,
			Config.none,
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

			// Duplex for stdin (write) / stdout (read)
			duplex = new Duplex(stdoutConn, stdinConn);

			// Optionally log raw bytes below the framing adapter
			IConnection rawConn = logName.length ? new LoggingAdapter(duplex, logName) : cast(IConnection) duplex;

			if (mode == FramingMode.contentLength)
				stdoutLines = new ContentLengthAdapter(rawConn);
			else
				stdoutLines = new LineBufferedAdapter(rawConn, "\n");
		}
		else
		{
			stdoutFd = dup(stdoutPipe.readEnd.fileno);
			stderrFd = dup(stderrPipe.readEnd.fileno);

			stdoutPipe.readEnd.close();
			stderrPipe.readEnd.close();

			auto stdoutConn = new FileConnection(stdoutFd);

			// Optionally log raw bytes below the framing adapter
			IConnection rawConn = logName.length ? new LoggingAdapter(stdoutConn, logName) : cast(IConnection) stdoutConn;

			if (mode == FramingMode.contentLength)
				stdoutLines = new ContentLengthAdapter(rawConn);
			else
				stdoutLines = new LineBufferedAdapter(rawConn, "\n");
		}

		auto stderrConn = new FileConnection(stderrFd);

		stdoutLines.handleReadData = (Data data) {
			if (onStdoutLine)
			{
				auto text = cast(string) data.toGC();
				onStdoutLine(text);
			}
		};

		stdoutLines.handleDisconnect = (string reason, DisconnectType type) {
			disconnected = true;
			stdoutEOF = true;
			tryFireExit();
		};

		stderrLines = new LineBufferedAdapter(stderrConn, "\n");
		stderrLines.handleReadData = (Data data) {
			if (onStderrLine)
			{
				auto text = cast(string) data.toGC();
				onStderrLine(text);
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

	/// Fire onExit only once all conditions are met:
	/// the process has exited AND both stdout and stderr have been fully drained (EOF).
	/// If stderr is slow to drain (e.g. child processes hold the fd), a short
	/// timer fires onExit anyway to avoid blocking indefinitely.
	private void tryFireExit()
	{
		import core.time : msecs;

		if (exitFired)
			return;
		if (exited && stdoutEOF && stderrEOF)
		{
			exitFired = true;
			if (stderrDrainTimer !is null)
			{
				stderrDrainTimer.cancel();
				stderrDrainTimer = null;
			}
			if (onExit)
				onExit(exitStatus);
		}
		else if (exited && stdoutEOF && !stderrEOF && stderrDrainTimer is null)
		{
			stderrDrainTimer = setTimeout({
				exitFired = true;
				if (onExit)
					onExit(exitStatus);
			}, 2000.msecs);
		}
	}

	/// Send a message to the process stdin. The framing adapter handles encoding.
	void sendMessage(string line)
	{
		if (disconnected)
			return;
		stdoutLines.send(Data(line.asBytes));
	}

	/// Whether the process pipes have been disconnected.
	@property bool dead() { return disconnected || exited; }

	/// The framed connection (LineBufferedAdapter or ContentLengthAdapter over Duplex).
	/// When used with JsonRpcCodec, the codec takes over handleReadData
	/// and onStdoutLine will no longer be called.
	@property ConnectionAdapter connection() { return stdoutLines; }

	/// Send a signal to the child process.
	void sendSignal(int sig)
	{
		if (!exited)
			kill(pid, sig);
	}

	/// Close stdin to signal EOF — the process will exit gracefully.
	void closeStdin()
	{
		if (stdinConn !is null)
		{
			stdinConn.disconnect("closing stdin");
			stdinConn = null;
		}
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

}

/// Wraps an IConnection to trace-log all data passing through it.
/// Use `<` prefix for inbound data and `>` for outbound data.
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
