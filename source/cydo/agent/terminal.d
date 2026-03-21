module cydo.agent.terminal;

import core.sys.posix.signal : SIGKILL, SIGTERM;
import core.sys.posix.unistd : dup;

import std.process : Pid, Config, spawnProcess, pipe, killProcess = kill;
import std.stdio : File;

import ae.net.asockets : DisconnectType, FileConnection;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;

/// Manages a terminal process: spawns a command with combined stdout+stderr,
/// captures raw output bytes, and defers exit notification until fully drained.
class TerminalProcess
{
	private Pid pid;
	private FileConnection outConn;
	private bool exited;
	private int exitStatus_;
	private bool outputEOF;
	private bool truncated_;
	private ubyte[] outputBuf;
	private size_t outputByteLimit_;

	void delegate() onExit;

	this(string[] args, string[string] env, string workDir, size_t outputByteLimit)
	{
		outputByteLimit_ = outputByteLimit;
		auto outPipe = pipe();

		pid = spawnProcess(
			args,
			File("/dev/null"),
			outPipe.writeEnd,
			outPipe.writeEnd,
			env,
			Config.none,
			workDir.length > 0 ? workDir : null,
		);

		outPipe.writeEnd.close();

		auto outFd = dup(outPipe.readEnd.fileno);
		outPipe.readEnd.close();

		outConn = new FileConnection(outFd);

		outConn.handleReadData = (Data data) {
			if (truncated_)
				return;
			auto bytes = cast(ubyte[]) data.toGC();
			auto available = outputByteLimit_ - outputBuf.length;
			if (bytes.length > available)
			{
				outputBuf ~= bytes[0 .. available];
				truncated_ = true;
			}
			else
				outputBuf ~= bytes;
		};

		outConn.handleDisconnect = (string reason, DisconnectType type) {
			outputEOF = true;
			tryFireExit();
		};

		asyncWait(pid, (int status) {
			exited = true;
			exitStatus_ = status;
			tryFireExit();
		});
	}

	/// Buffered output as UTF-8 string.
	string output() { return cast(string) outputBuf; }

	/// Whether the output byte limit was reached.
	@property bool truncated() { return truncated_; }

	/// Whether the process is still running.
	@property bool alive() { return !exited; }

	/// Whether the process has fully exited and all output has been drained.
	@property bool done() { return exited && outputEOF; }

	/// Normal exit code (0 if killed by signal).
	int exitCode() { return exitStatus_ >= 0 ? exitStatus_ : 0; }

	/// Signal name if the process was killed by a signal, null otherwise.
	string exitSignal()
	{
		return exitStatus_ < 0 ? signalName(-exitStatus_) : null;
	}

	/// Send SIGTERM to the process.
	void kill()
	{
		if (!exited)
			killProcess(pid, SIGTERM);
	}

	/// Send SIGKILL to the process immediately.
	void forceKill()
	{
		if (!exited)
			killProcess(pid, SIGKILL);
	}

	private void tryFireExit()
	{
		if (exited && outputEOF)
			if (onExit)
				onExit();
	}
}

private string signalName(int sig)
{
	switch (sig)
	{
		case 1:  return "SIGHUP";
		case 2:  return "SIGINT";
		case 3:  return "SIGQUIT";
		case 6:  return "SIGABRT";
		case 9:  return "SIGKILL";
		case 11: return "SIGSEGV";
		case 13: return "SIGPIPE";
		case 15: return "SIGTERM";
		default:
			import std.conv : to;
			return "SIG" ~ to!string(sig);
	}
}
