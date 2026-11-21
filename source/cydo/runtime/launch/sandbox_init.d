module cydo.runtime.launch.sandbox_init;

version (linux):

import core.stdc.errno : EINTR, errno;
import core.stdc.stdio : perror;
import core.sys.posix.signal;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED, WNOHANG,
	WTERMSIG, waitpid;
import core.sys.posix.unistd : _exit, execvp, fork;
import std.exception : enforce;
import std.string : toStringz;

void runSandboxInit(immutable(string)[] command)
{
	enforce(command.length > 0, "Usage: cydo sandbox-init -- <command> [args…]");
	auto argv = new const(char)*[command.length + 1];
	foreach (i, arg; command)
		argv[i] = arg.toStringz;

	sigset_t watched;
	sigemptyset(&watched);
	foreach (sig; [SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2])
		sigaddset(&watched, sig);
	sigset_t inheritedMask;
	if (sigprocmask(SIG_BLOCK, &watched, &inheritedMask) < 0)
		fail("sandbox-init: sigprocmask", 1);

	// Clear SIG_IGN and SA_NOCLDWAIT so waitpid can collect child statuses.
	sigaction_t disposition;
	disposition.sa_handler = SIG_DFL;
	sigemptyset(&disposition.sa_mask);
	sigaction_t inheritedChld;
	if (sigaction(SIGCHLD, &disposition, &inheritedChld) < 0)
		fail("sandbox-init: sigaction", 1);

	auto child = fork();
	if (child < 0)
		fail("sandbox-init: fork", 1);
	if (child == 0)
	{
		// Hand the command the signal state the launcher gave us (e.g. an
		// ignored SIGHUP under nohup), undoing only our own changes.
		if (sigaction(SIGCHLD, &inheritedChld, null) < 0)
			fail("sandbox-init: sigaction", 1);
		if (sigprocmask(SIG_SETMASK, &inheritedMask, null) < 0)
			fail("sandbox-init: sigprocmask", 1);
		execvp(argv[0], argv.ptr);
		fail(argv[0], 127);
	}

	while (true)
	{
		auto sig = sigwaitinfo(&watched, null);
		if (sig < 0)
		{
			if (errno == EINTR)
				continue;
			fail("sandbox-init: sigwaitinfo", 1);
		}
		if (sig != SIGCHLD)
		{
			// The main child may have exited while this signal was pending.
			kill(child, sig);
			continue;
		}
		// One SIGCHLD can represent several exits.
		while (true)
		{
			int status;
			auto reaped = waitpid(-1, &status, WNOHANG);
			if (reaped < 0)
			{
				if (errno == EINTR)
					continue;
				fail("sandbox-init: waitpid", 1);
			}
			if (reaped == 0)
				break;
			if (reaped == child)
			{
				if (WIFEXITED(status))
					_exit(WEXITSTATUS(status));
				if (WIFSIGNALED(status))
					_exit(128 + WTERMSIG(status));
			}
		}
	}
}

private void fail(const(char)* message, int status)
{
	perror(message);
	_exit(status);
}
