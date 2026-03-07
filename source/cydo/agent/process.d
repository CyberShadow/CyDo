module cydo.agent.process;

import core.sys.posix.signal : SIGINT, SIGTERM;
import core.sys.posix.unistd : dup;

import std.process : Pid, Pipe, Redirect, Config, spawnProcess, pipe, kill;
import std.stdio : File;

import ae.net.asockets : ConnectionState, DisconnectType, Duplex, FileConnection, LineBufferedAdapter;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;
import ae.utils.array : asBytes;

/// Manages a child process with event-loop-integrated I/O.
/// Uses FileConnection to wrap pipe fds, Duplex to combine stdin/stdout,
/// and LineBufferedAdapter for NDJSON line splitting.
class AgentProcess
{
	private Pid pid;
	private FileConnection stdinConn;
	private LineBufferedAdapter stdoutLines;
	private LineBufferedAdapter stderrLines;
	private Duplex duplex;
	private bool exited;

	private bool disconnected;

	void delegate(string line) onStdoutLine;
	void delegate(string line) onStderrLine;
	void delegate(int status) onExit;

	/// Spawn a child process with the given arguments and optional environment/workdir.
	/// If noStdin is true, stdin is redirected from /dev/null (no Duplex needed).
	this(string[] args, string[string] env = null, string workDir = null, bool noStdin = false)
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

			// Line-buffered adapter reads from duplex
			stdoutLines = new LineBufferedAdapter(duplex, "\n");
		}
		else
		{
			stdoutFd = dup(stdoutPipe.readEnd.fileno);
			stderrFd = dup(stderrPipe.readEnd.fileno);

			stdoutPipe.readEnd.close();
			stderrPipe.readEnd.close();

			auto stdoutConn = new FileConnection(stdoutFd);

			// No Duplex — read stdout directly
			stdoutLines = new LineBufferedAdapter(stdoutConn, "\n");
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
		};

		stderrLines = new LineBufferedAdapter(stderrConn, "\n");
		stderrLines.handleReadData = (Data data) {
			if (onStderrLine)
			{
				auto text = cast(string) data.toGC();
				onStderrLine(text);
			}
		};

		// Async process exit notification
		asyncWait(pid, (int status) {
			exited = true;
			if (onExit)
				onExit(status);
		});
	}

	/// Write a line to the process stdin (appends newline via LineBufferedAdapter).
	void writeLine(string line)
	{
		if (disconnected)
			return;
		stdoutLines.send(Data(line.asBytes));
	}

	/// Whether the process pipes have been disconnected.
	@property bool dead() { return disconnected || exited; }

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
