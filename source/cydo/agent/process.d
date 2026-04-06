module cydo.agent.process;

import core.sys.posix.signal : SIGINT, SIGKILL, SIGTERM;
import core.sys.posix.unistd : dup;
import core.time : Duration, seconds;

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
	private TimerTask killTimer;
	private TimerTask killForcedTimer;
	private bool waitForPipeDrain;

	void delegate(string line) onStdoutLine;
	void delegate(string line) onStderrLine;
	void delegate(int status) onExit;

	/// Spawn a child process with the given arguments and optional environment/workdir.
	/// If noStdin is true, stdin is redirected from /dev/null (no Duplex needed).
	/// If logName is non-empty, a LoggingAdapter is inserted above the framing adapter
	/// to trace-log logical messages at the trace level.
	this(string[] args, string[string] env = null, string workDir = null, bool noStdin = false,
		FramingMode mode = FramingMode.ndjson, string logName = null,
		bool waitForPipeDrain = true)
	{
		this.waitForPipeDrain = waitForPipeDrain;
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

			ConnectionAdapter framedConn;
			if (mode == FramingMode.contentLength)
				framedConn = new ContentLengthAdapter(duplex);
			else
				framedConn = new LineBufferedAdapter(duplex, "\n");

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
		if (exited && (!waitForPipeDrain || (stdoutEOF && stderrEOF)))
		{
			exitFired = true;
			if (stderrDrainTimer !is null)
			{
				stderrDrainTimer.cancel();
				stderrDrainTimer = null;
			}
			if (killTimer !is null)
			{
				killTimer.cancel();
				killTimer = null;
			}
			if (killForcedTimer !is null)
			{
				killForcedTimer.cancel();
				killForcedTimer = null;
			}
			if (onExit)
				onExit(exitStatus);
		}
		else if (waitForPipeDrain && exited && stdoutEOF && !stderrEOF && stderrDrainTimer is null)
		{
			stderrDrainTimer = setTimeout({
				if (exitFired)
					return;
				exitFired = true;
				if (stderrLines !is null)
				{
					auto lines = stderrLines;
					stderrLines = null;
					lines.disconnect("stderr drain timeout");
				}
				if (onExit)
					onExit(exitStatus);
			}, 2000.msecs);
		}
	}

	/// Send a message to the process stdin. The framing adapter handles encoding.
	void sendMessage(string line)
	{
		if (dead)
			return;
		stdoutLines.send(Data(line.asBytes));
	}

	/// Whether the process pipes have been disconnected.
	@property bool dead() { return disconnected || exited; }

	/// The framed connection (LineBufferedAdapter or ContentLengthAdapter over Duplex).
	/// When used with JsonRpcCodec, the codec takes over handleReadData
	/// and onStdoutLine will no longer be called.
	@property ConnectionAdapter connection() { return stdoutLines; }

	/// The underlying process PID, for use with asyncWait.
	@property Pid processId() { return pid; }

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

	/// If the process has not exited within `timeout`, send SIGTERM.
	/// If it still hasn't exited after another 2 seconds, send SIGKILL.
	void killAfterTimeout(Duration timeout)
	{
		if (exitFired)
			return;
		killTimer = setTimeout({
			killTimer = null;
			if (exitFired)
				return;
			sendSignal(SIGTERM);
			killForcedTimer = setTimeout({
				killForcedTimer = null;
				if (exitFired)
					return;
				sendSignal(SIGKILL);
			}, 2.seconds);
		}, timeout);
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
