module cydo.foundation.testing.unittest_runner;

version (unittest):

import ae.sys.timing : mainTimer;
import core.exception : AssertError;
import core.runtime : Runtime, UnitTestResult;
import core.stdc.stdio : fprintf, printf, stderr;

private extern (C) void _d_print_throwable(Throwable throwable);

shared static this()
{
	Runtime.extendedModuleUnitTester = &runUnitTests;
}

private UnitTestResult runUnitTests()
{
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

		if (mainTimer.hasNonDaemonTasks())
		{
			auto name = moduleInfo.name;
			fprintf(stderr, "%.*s: [unittest] a test left a non-daemon ae timer pending, "
				~ "which would stall the next socketManager.loop()\n",
				cast(int) name.length, name.ptr);
			// The pending timer would contaminate the remaining modules.
			break;
		}
		if (passed)
			++result.passed;
	}
	return result;
}
