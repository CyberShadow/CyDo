module cydo.foundation.testing.unittest_runner;

version (unittest):

import ae.sys.timing : mainTimer;
import core.exception : AssertError;
import core.runtime : Runtime, UnitTestResult;
import core.stdc.stdio : fprintf, printf, stderr;

import cydo.foundation.platform.signals : initializeProcessSignals;

private extern (C) void _d_print_throwable(Throwable throwable);

shared static this()
{
	Runtime.extendedModuleUnitTester = &runUnitTests;
}

private UnitTestResult runUnitTests()
{
	// The server sets this disposition, and Nix builder inheritance can hide its absence.
	initializeProcessSignals();

	UnitTestResult result;
	result.summarize = true;
	foreach (moduleInfo; ModuleInfo)
	{
		if (!moduleInfo)
			continue;
		// Calling moduleInfo.unitTest directly would only invoke the accessor.
		auto testModule = moduleInfo.unitTest;
		if (!testModule)
			continue;

		++result.executed;
		bool passed;
		try
		{
			testModule();
			passed = true;
		}
		catch (Throwable throwable)
		{
			// Match druntime's compact diagnostic for assertions in the tested module.
			auto name = moduleInfo.name;
			auto file = throwable.file;
			if (typeid(throwable) == typeid(AssertError) && name.length
				&& file.length > name.length && file[0 .. name.length] == name)
			{
				auto message = throwable.message;
				printf("%.*s(%llu): [unittest] %.*s\n", cast(int) file.length,
					file.ptr, cast(ulong) throwable.line, cast(int) message.length, message.ptr);
			}
			else
				_d_print_throwable(throwable);
		}

		if (!checkNoLeakedLoopWork(moduleInfo.name))
			break;
		if (passed)
			++result.passed;
	}
	return result;
}

private bool checkNoLeakedLoopWork(string where)
{
	import core.sys.posix.signal : SIGCHLD, SIG_DFL, sigaction, sigaction_t;
	import std.exception : errnoEnforce;

	// ae installs the SIGCHLD handler exactly while asyncWait registrations exist.
	// CyDo installs no SIGCHLD handler in this process.
	sigaction_t action;
	errnoEnforce(sigaction(SIGCHLD, null, &action) == 0, "query SIGCHLD");
	if (action.sa_handler != SIG_DFL)
	{
		fprintf(stderr, "%.*s: [unittest] a test left a child process unawaited (ae asyncWait "
			~ "outstanding), which would stall the next socketManager.loop() and can crash "
			~ "runtime shutdown\n", cast(int) where.length, where.ptr);
		return false;
	}
	if (mainTimer.hasNonDaemonTasks())
	{
		fprintf(stderr, "%.*s: [unittest] a test left a non-daemon ae timer pending, "
			~ "which would stall the next socketManager.loop()\n",
			cast(int) where.length, where.ptr);
		return false;
	}
	return true;
}
