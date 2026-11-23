module cydo.agent.terminal;

import core.stdc.errno : errno, ESRCH;
import core.sys.posix.signal : SIGKILL, SIGTERM, siginfo_t, signalProcess = kill;
import core.sys.posix.unistd : close, dup, setsid;
import core.sys.posix.sys.types : pid_t;

import std.exception : errnoEnforce;
import std.process : Pid, Config, spawnProcess, pipe, wait, killProcess = kill;
import std.stdio : File;

import ae.net.asockets : DisconnectType, FileConnection;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;

private extern(C) int pidfd_open(pid_t pid, uint flags) nothrow @nogc;
private extern(C) int pidfd_send_signal(int fd, int sig, siginfo_t* info, uint flags) nothrow @nogc;
private enum PIDFD_SIGNAL_PROCESS_GROUP = 1u << 2;

/// Manages a terminal process: spawns a command with combined stdout+stderr,
/// captures raw output bytes, and ends group supervision once the leader is
/// reaped and output is drained. Detached survivors of natural exits can continue.
class TerminalProcess
{
	private Pid pid;
	private bool ownProcessGroup;
	private bool terminationRequested;
	private int groupFd = -1;
	private FileConnection outConn;
	private bool exited;
	private int exitStatus_;
	private bool outputEOF;
	private bool truncated_;
	private ubyte[] outputBuf;
	private size_t outputByteLimit_;

	/// Called after the leader is reaped, output is drained, and group supervision ends.
	void delegate() onExit;

	this(string[] args, string[string] env, string workDir, size_t outputByteLimit, bool ownProcessGroup = false)
	{
		this.ownProcessGroup = ownProcessGroup;
		outputByteLimit_ = outputByteLimit;
		auto outPipe = pipe();

		pid = spawnProcess(
			args,
			File("/dev/null"),
			outPipe.writeEnd,
			outPipe.writeEnd,
			env,
			ownProcessGroup ? Config(preExecFunction: () @trusted => setsid() != -1) : Config.none,
			workDir.length > 0 ? workDir : null,
		);
		scope (failure) abortLaunch(pid, ownProcessGroup);

		if (ownProcessGroup)
		{
			// Keep a reference to the original group before asyncWait can reap its leader.
			groupFd = pidfd_open(pid.processID, 0);
			errnoEnforce(groupFd >= 0, "Cannot open terminal process group pidfd");
		}
		scope (failure) closeGroupFd();

		outPipe.writeEnd.close();

		auto outFd = dup(outPipe.readEnd.fileno);
		errnoEnforce(outFd >= 0, "Cannot duplicate terminal output descriptor");
		// FileConnection adopts the descriptor even if its constructor throws.
		outConn = new FileConnection(outFd);
		scope (failure) outConn.disconnect("Terminal launch failed", DisconnectType.error);
		outPipe.readEnd.close();

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

	private void closeGroupFd() nothrow @nogc
	{
		if (groupFd >= 0)
		{
			close(groupFd);
			groupFd = -1;
		}
	}

	/// Buffered output as UTF-8 string.
	string output() { return outputBuf.length > 0 ? cast(string) outputBuf : ""; }

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

	/// Send SIGTERM. In group mode, completion escalates to SIGKILL if needed.
	void kill()
	{
		if (ownProcessGroup)
		{
			terminationRequested = true;
			signalGroup(SIGTERM);
		}
		else if (!exited)
			killProcess(pid, SIGTERM);
	}

	/// Send SIGKILL immediately. In group mode, supervision ends once SIGKILL
	/// has reached every member CyDo is permitted to signal.
	void forceKill()
	{
		if (ownProcessGroup)
			signalGroup(SIGKILL);
		else if (!exited)
			killProcess(pid, SIGKILL);
	}

	private void signalGroup(int signal)
	{
		// Shutdown can request SIGKILL again while a killed group is still draining.
		if (groupFd < 0)
			return;
		if (pidfd_send_signal(groupFd, signal, null, PIDFD_SIGNAL_PROCESS_GROUP) == 0)
		{
			if (signal == SIGKILL)
				closeGroupFd();
			return;
		}
		errnoEnforce(errno == ESRCH, "Cannot signal terminal process group");
		closeGroupFd();
	}

	private void tryFireExit()
	{
		if (exited && outputEOF)
		{
			if (ownProcessGroup)
			{
				if (terminationRequested)
					signalGroup(SIGKILL);
				else
					closeGroupFd();
			}
			if (onExit)
				onExit();
		}
	}
}

private void abortLaunch(Pid pid, bool ownProcessGroup)
{
	// The leader is still unreaped, so its numeric ID cannot be reused.
	auto target = ownProcessGroup ? -pid.processID : pid.processID;
	errnoEnforce(signalProcess(target, SIGKILL) == 0, "Cannot kill terminal after launch failure");
	wait(pid);
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

unittest
{
	import core.memory : GC;
	import core.sys.posix.signal : sendSignal = kill;
	import core.time : msecs, seconds;
	import std.conv : to;
	import std.string : indexOf;

	import ae.net.asockets : socketManager;
	import ae.sys.timing : TimerTask, setInterval, setTimeout;

	GC.disable();
	scope (exit) GC.enable();
	auto baseline = openPidfds();

	// Close the grandchild's output descriptors so the exit callback can
	// fire even if a regression leaves the grandchild running.
	auto terminal = new TerminalProcess([
		"/bin/sh", "-c",
		"sleep 60 >/dev/null 2>&1 & printf '%s\\n' \"$!\"; wait",
	], null, "", 1024, true);

	int grandchild;
	bool exited;
	scope (failure)
	{
		if (grandchild > 0)
			sendSignal(grandchild, SIGKILL);
		terminal.forceKill();
	}

	TimerTask readiness;
	readiness = setInterval({
		auto output = terminal.output();
		auto newline = output.indexOf('\n');
		if (newline < 0)
			return;
		readiness.cancel();
		grandchild = output[0 .. newline].to!int;
		assert(grandchild > 0 && !grandchildStopped(grandchild), "expected a running grandchild");
		assert(terminal.alive && openPidfds() == baseline + 1);
		terminal.forceKill();
		assert(!exited && openPidfds() == baseline);
	}, 10.msecs);
	scope (exit) if (readiness.isWaiting()) readiness.cancel();

	auto watchdog = setTimeout({
		assert(false, "timed out waiting for terminal readiness or onExit");
	}, 5.seconds);
	scope (exit) if (watchdog.isWaiting()) watchdog.cancel();
	terminal.onExit = {
		exited = true;
		watchdog.cancel();
	};
	scope (exit) terminal.onExit = null;
	socketManager.loop();

	assert(exited, "forceKill did not fire onExit");
	assert(grandchild > 0, "terminal exited before reporting its grandchild");
	waitForGrandchildToStop(grandchild);
	terminal.forceKill();
	terminal.kill();
}

version (unittest) private size_t openPidfds()
{
	import std.algorithm : count;
	import std.file : dirEntries, SpanMode, readLink;

	return dirEntries("/proc/self/fd", SpanMode.shallow)
		.count!(entry => readLink(entry.name) == "anon_inode:[pidfd]");
}

version (unittest) private bool grandchildStopped(int grandchild)
{
	import core.stdc.errno : ENOENT;
	import std.conv : to;
	import std.file : FileException, readText;
	import std.string : lastIndexOf;

	try
	{
		auto stat = readText("/proc/" ~ grandchild.to!string ~ "/stat");
		// The command name is parenthesized and may itself contain ')'.
		return stat[stat.lastIndexOf(") ") + 2] == 'Z';
	}
	catch (FileException e)
	{
		// procfs can return ESRCH if the process is reaped during the read.
		if (e.errno == ENOENT || e.errno == ESRCH)
			return true;
		throw e;
	}
}

version (unittest) private void waitForGrandchildToStop(int grandchild)
{
	import core.thread : Thread;
	import core.time : MonoTime, msecs, seconds;

	auto deadline = MonoTime.currTime + 2.seconds;
	while (!grandchildStopped(grandchild))
	{
		assert(MonoTime.currTime < deadline, "the signalled grandchild is still running");
		Thread.sleep(10.msecs);
	}
}

unittest
{
	import core.memory : GC;
	import core.time : msecs, seconds;
	import std.conv : to;
	import std.string : indexOf;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : TimerTask, setInterval, setTimeout;

	GC.disable();
	scope (exit) GC.enable();
	auto baseline = openPidfds();

	// The shell exits, leaving the grandchild holding the output pipe open.
	auto terminal = new TerminalProcess([
		"/bin/sh", "-c", "sleep 60 & printf '%s\\n' \"$!\"",
	], null, "", 1024, true);
	int grandchild;
	scope (failure) if (grandchild > 0) signalProcess(grandchild, SIGKILL);

	TimerTask readiness;
	readiness = setInterval({
		auto output = terminal.output();
		auto newline = output.indexOf('\n');
		if (terminal.alive || newline < 0)
			return;
		readiness.cancel();
		grandchild = output[0 .. newline].to!int;
		assert(grandchild > 0 && !grandchildStopped(grandchild));
		assert(!terminal.done, "expected the grandchild to hold the output pipe open");
		assert(openPidfds() == baseline + 1);
		terminal.forceKill();
		assert(openPidfds() == baseline);
	}, 10.msecs);
	scope (exit) if (readiness.isWaiting()) readiness.cancel();

	bool exited;
	auto watchdog = setTimeout({
		assert(false, "timed out waiting for onExit after forceKill");
	}, 5.seconds);
	scope (exit) if (watchdog.isWaiting()) watchdog.cancel();
	terminal.onExit = {
		assert(grandchild > 0, "terminal completed before forceKill");
		exited = true;
		watchdog.cancel();
	};
	scope (exit) terminal.onExit = null;
	socketManager.loop();

	assert(exited && terminal.done, "forceKill did not complete the terminal");
	waitForGrandchildToStop(grandchild);
}

unittest
{
	import core.memory : GC;
	import core.time : msecs, seconds;
	import std.array : split;
	import std.conv : to;
	import std.string : indexOf;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : TimerTask, setInterval, setTimeout;

	GC.disable();
	scope (exit) GC.enable();
	auto baseline = openPidfds();

	// Both grandchildren close the output pipe. Only the second ignores SIGTERM.
	// The leader waits for the sensitive child in its trap, so completion
	// requires SIGTERM to reach that child before any escalation can occur.
	auto terminal = new TerminalProcess([
		"/bin/sh", "-c",
		"sleep 60 >/dev/null 2>&1 & sensitive=$!; " ~
		"trap '' TERM; sleep 60 >/dev/null 2>&1 & " ~
		"trap 'wait \"$sensitive\"; trap - TERM; kill -TERM \"$$\"' TERM; " ~
		"printf '%s %s\\n' \"$sensitive\" \"$!\"; wait",
	], null, "", 1024, true);
	int sensitive;
	int grandchild;
	scope (failure)
	{
		if (sensitive > 0 && !grandchildStopped(sensitive))
			signalProcess(sensitive, SIGKILL);
		if (grandchild > 0 && !grandchildStopped(grandchild))
			signalProcess(grandchild, SIGKILL);
	}

	TimerTask readiness;
	readiness = setInterval({
		auto output = terminal.output();
		auto newline = output.indexOf('\n');
		if (newline < 0)
			return;
		readiness.cancel();
		auto pids = output[0 .. newline].split();
		assert(pids.length == 2);
		sensitive = pids[0].to!int;
		grandchild = pids[1].to!int;
		assert(sensitive > 0 && !grandchildStopped(sensitive));
		assert(grandchild > 0 && !grandchildStopped(grandchild));
		assert(openPidfds() == baseline + 1);
		terminal.kill();
	}, 10.msecs);
	scope (exit) if (readiness.isWaiting()) readiness.cancel();

	bool exited;
	auto watchdog = setTimeout({
		assert(false, "timed out waiting for onExit after kill");
	}, 5.seconds);
	scope (exit) if (watchdog.isWaiting()) watchdog.cancel();
	terminal.onExit = {
		assert(terminal.done && terminal.exitSignal() == "SIGTERM");
		assert(openPidfds() == baseline);
		exited = true;
		watchdog.cancel();
	};
	scope (exit) terminal.onExit = null;
	socketManager.loop();

	assert(exited, "kill did not complete the terminal");
	waitForGrandchildToStop(sensitive);
	waitForGrandchildToStop(grandchild);
	terminal.forceKill();
}

unittest
{
	import core.memory : GC;
	import core.thread : Thread;
	import core.time : MonoTime, msecs, seconds;
	import std.conv : to;
	import std.string : strip;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : setTimeout;

	GC.disable();
	scope (exit) GC.enable();
	auto baseline = openPidfds();

	auto terminal = new TerminalProcess([
		"/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & printf '%s\\n' \"$!\"",
	], null, "", 1024, true);
	assert(openPidfds() == baseline + 1);

	int grandchild;
	scope (exit) if (grandchild > 0 && !grandchildStopped(grandchild))
		signalProcess(grandchild, SIGKILL);
	auto watchdog = setTimeout({
		assert(false, "timed out waiting for natural terminal completion");
	}, 5.seconds);
	scope (exit) if (watchdog.isWaiting()) watchdog.cancel();
	terminal.onExit = {
		grandchild = terminal.output().strip().to!int;
		assert(grandchild > 0);
		assert(openPidfds() == baseline);
		watchdog.cancel();
	};
	scope (exit) terminal.onExit = null;
	socketManager.loop();

	assert(grandchild > 0 && !grandchildStopped(grandchild));
	terminal.forceKill();
	auto deadline = MonoTime.currTime + 200.msecs;
	do
	{
		Thread.sleep(10.msecs);
		assert(!grandchildStopped(grandchild), "forceKill stopped a released survivor");
	}
	while (MonoTime.currTime < deadline);
}

unittest
{
	import core.memory : GC;
	import core.time : seconds;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : setTimeout;

	GC.disable();
	scope (exit) GC.enable();
	auto baseline = openPidfds();

	foreach (signal; [0, SIGKILL, SIGTERM])
	{
		foreach (iteration; 0 .. 50)
		{
			auto terminal = new TerminalProcess([
				"/bin/sh", "-c", signal == 0 ? "exit 0" : "exec sleep 60",
			], null, "", 1024, true);
			scope (failure) terminal.forceKill();
			assert(openPidfds() == baseline + 1);

			bool exited;
			auto watchdog = setTimeout({
				assert(false, "timed out waiting for sequential terminal completion");
			}, 5.seconds);
			scope (exit) if (watchdog.isWaiting()) watchdog.cancel();
			terminal.onExit = {
				exited = true;
				watchdog.cancel();
			};
			scope (exit) terminal.onExit = null;

			if (signal == SIGKILL)
				terminal.forceKill();
			else if (signal == SIGTERM)
				terminal.kill();
			socketManager.loop();

			assert(exited && terminal.done);
			assert(openPidfds() == baseline);
		}
	}
}

unittest
{
	import core.memory : GC;
	import std.conv : to;
	import std.process : tryWait;
	import std.string : strip;

	GC.disable();
	scope (exit) GC.enable();

	auto output = pipe();
	auto pid = spawnProcess([
		"/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & printf '%s\\n' \"$!\"; wait",
	], File("/dev/null"), output.writeEnd, output.writeEnd, null,
		Config(preExecFunction: () @trusted => setsid() != -1));
	output.writeEnd.close();
	auto grandchild = output.readEnd.readln().strip().to!int;
	assert(grandchild > 0 && !grandchildStopped(grandchild));
	scope (failure) if (!grandchildStopped(grandchild))
		signalProcess(grandchild, SIGKILL);

	abortLaunch(pid, true);
	assert(pid.processID < 0, "rollback returned before reaping the group leader");
	auto result = tryWait(pid);
	assert(result.terminated && result.status == -SIGKILL);
	waitForGrandchildToStop(grandchild);
}

unittest
{
	import core.memory : GC;
	import std.process : tryWait;

	GC.disable();
	scope (exit) GC.enable();

	auto pid = spawnProcess(["sleep", "60"]);
	abortLaunch(pid, false);
	assert(pid.processID < 0, "rollback returned before reaping the child");
	auto result = tryWait(pid);
	assert(result.terminated && result.status == -SIGKILL);
}
