module cydo.runtime.image.bounded_filter;

import core.time : Duration, MonoTime, seconds;

import ae.utils.promise : Promise;
import cydo.agent.process : ProcessResourceLimits;

enum FilterFailureKind { failed, timedOut, tooLarge, multiImage, reconfigured }

final class FilterFailure : Exception
{
	immutable FilterFailureKind kind;
	immutable string diagnostic;

	this(FilterFailureKind kind, string diagnostic = null)
	{
		super(["conversion failed", "timed out", "result too large",
			"multi-image HEIC is not supported", "image converter reconfigured; resubmit"][kind]);
		this.kind = kind;
		this.diagnostic = diagnostic;
	}
}

struct FilterLimits
{
	ProcessResourceLimits resources;
	MonoTime deadline;
	size_t outputBytes;
}

struct FilterOutput
{
	immutable(ubyte)[] bytes;
	string stderr;
}

string filterExitDiagnostic(int status, string stderr)
{
	import std.conv : to;

	auto diagnostic = "exit status " ~ status.to!string;
	if (stderr.length)
		diagnostic ~= ": " ~ stderr;
	return diagnostic;
}

version (Posix)
Promise!FilterOutput runBoundedFilter(string[] command,
	immutable(ubyte)[] input, FilterLimits limits, bool allowEmptyOutput = false)
{
	import core.sys.posix.signal : SIGKILL;
	import std.algorithm : max, min;
	import std.array : appender;
	import std.logger : warningf;
	import cydo.agent.process : AgentProcess, FramingMode;

	auto result = new Promise!FilterOutput;
	if (limits.deadline <= MonoTime.currTime)
	{
		result.reject(new FilterFailure(FilterFailureKind.timedOut));
		return result;
	}

	AgentProcess process;
	try
		process = new AgentProcess(command, mode: FramingMode.raw,
			resourceLimits: limits.resources, independentPipes: true);
	catch (Exception e)
	{
		warningf("Could not start filter: %s", e.msg);
		result.reject(new FilterFailure(FilterFailureKind.failed));
		return result;
	}

	auto output = appender!(immutable(ubyte)[]);
	auto diagnostics = appender!string();
	FilterFailureKind failure;
	void stop(FilterFailureKind kind, bool killImmediately)
	{
		if (failure == FilterFailureKind.failed)
			failure = kind;
		if (killImmediately)
			process.sendSignal(SIGKILL);
		process.forceClosePipes();
	}
	process.onStdoutLine = (string chunk) {
		if (chunk.length > limits.outputBytes - output.data.length)
			return stop(FilterFailureKind.tooLarge, true);
		output.put(cast(immutable(ubyte)[]) chunk);
	};
	process.onStderrLine = (string chunk) {
		diagnostics.put(chunk[0 .. min(chunk.length, 4096 - diagnostics.data.length)]);
	};
	process.onExit = (int status) {
		process.forceClosePipes();
		if (failure == FilterFailureKind.failed && status == 0
			&& (output.data.length || allowEmptyOutput))
			result.fulfill(FilterOutput(output.data, diagnostics.data));
		else
		{
			if (diagnostics.data.length)
				warningf("Filter stderr: %s", diagnostics.data);
			result.reject(new FilterFailure(failure, filterExitDiagnostic(status, diagnostics.data)));
		}
	};
	process.killAfterTimeout(max(0.seconds, limits.deadline - MonoTime.currTime), { stop(FilterFailureKind.timedOut, false); });
	process.sendMessage(cast(string) input);
	process.closeStdin();
	return result;
}

version (Posix) version (unittest)
{
	import ae.utils.promise.await : awaitSync;
	import core.time : msecs;
	import std.exception : collectException;
	import std.typecons : Nullable, nullable;

	private FilterLimits testLimits()
	{
		return FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 15.seconds, 32 * 1024 * 1024);
	}

	unittest
	{
		auto limits = testLimits;
		limits.deadline = MonoTime.currTime;
		auto failure = collectException!FilterFailure(
			runBoundedFilter(["/nonexistent/cydo-filter"], null, limits).awaitSync());
		assert(failure !is null && failure.kind == FilterFailureKind.timedOut);
	}

	unittest
	{
		import std.exception : assumeUnique;

		auto input = new ubyte[20 * 1024 * 1024];
		foreach (i, ref byteValue; input)
			byteValue = cast(ubyte) (i ^ (i >> 8) ^ (i >> 16));

		auto bytes = input.assumeUnique;
		assert(runBoundedFilter(["cat"], bytes, testLimits).awaitSync().bytes == bytes);
	}

	unittest
	{
		// Nonempty stdout would succeed if the filter ignored the exit status.
		auto failure = collectException!FilterFailure(
			runBoundedFilter(["sh", "-c", "printf partial; exit 3"], null, testLimits).awaitSync());
		assert(failure !is null && failure.kind == FilterFailureKind.failed);
	}

	private void assertStopsWithInheritedPipes(string workload, FilterLimits limits,
		FilterFailureKind expected, Duration deadline)
	{
		import core.stdc.errno : errno, ESRCH;
		import core.sys.posix.signal : kill, SIGKILL;
		import core.sys.posix.sys.types : pid_t;
		import std.conv : to;
		import std.file : exists, readText, remove, tempDir;
		import std.path : buildPath;
		import std.string : lineSplitter;
		import std.uuid : randomUUID;

		auto pidFile = buildPath(tempDir, "cydo-bounded-filter-" ~ randomUUID().toString());
		scope (exit)
		{
			if (exists(pidFile))
			{
				auto pids = readText(pidFile).lineSplitter;
				if (!pids.empty)
					pids.popFront();
				if (!pids.empty)
					kill(pids.front.to!pid_t, SIGKILL);
				remove(pidFile);
			}
		}

		enum setup = `sleep 30 & printf '%s\n%s\n' "$$" "$!" > "$1"; `;
		auto start = MonoTime.currTime;
		auto failure = collectException!FilterFailure(runBoundedFilter(
			["sh", "-c", setup ~ workload, "test", pidFile], null, limits).awaitSync());
		assert(failure !is null && failure.kind == expected);
		assert(MonoTime.currTime - start < deadline, "the filter must settle while inherited pipes remain open");
		auto pids = readText(pidFile).lineSplitter;
		auto pid = pids.front.to!pid_t;
		assert(kill(pid, 0) == -1 && errno == ESRCH, "the launched child must be reaped");
		pids.popFront();
		assert(kill(pids.front.to!pid_t, 0) == 0, "the descendant must outlive the filter");
	}

	unittest
	{
		auto limits = FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 20.seconds, 1024 * 1024);
		assertStopsWithInheritedPipes("head -c 40M /dev/zero && exec sleep 30",
			limits, FilterFailureKind.tooLarge, 3.seconds);
	}

	unittest
	{
		auto limits = FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 200.msecs, testLimits.outputBytes);
		assertStopsWithInheritedPipes("exec sleep 30", limits, FilterFailureKind.timedOut, 2.seconds);
	}

	private struct FilterObservation
	{
		immutable(ubyte)[] output;
		Exception failure;
		Duration settled;
		Duration drained;
	}

	private FilterObservation observeFilter(string[] command,
		immutable(ubyte)[] input, FilterLimits limits)
	{
		import ae.net.asockets : socketManager;

		FilterObservation observation;
		auto start = MonoTime.currTime;
		runBoundedFilter(command, input, limits).then((FilterOutput output) {
			observation.output = output.bytes;
			observation.settled = MonoTime.currTime - start;
		}).except((Exception failure) {
			observation.failure = failure;
			observation.settled = MonoTime.currTime - start;
		}).ignoreResult();
		socketManager.loop();
		observation.drained = MonoTime.currTime - start;
		return observation;
	}

	private void assertStopsWithDescendant(string workload, string descendantRedirections,
		FilterLimits limits, Nullable!FilterFailureKind expected, Duration deadline = 2.seconds)
	{
		import core.stdc.errno : errno, ESRCH;
		import core.sys.posix.signal : kill, SIGKILL;
		import core.sys.posix.sys.types : pid_t;
		import std.conv : to;
		import std.file : exists, readText, remove, tempDir;
		import std.path : buildPath;
		import std.string : splitLines;
		import std.uuid : randomUUID;

		auto pidFile = buildPath(tempDir, "cydo-bounded-filter-" ~ randomUUID().toString());
		scope (exit)
		{
			if (exists(pidFile))
			{
				auto pids = readText(pidFile).splitLines;
				if (pids.length == 2)
					kill(pids[1].to!pid_t, SIGKILL);
				remove(pidFile);
			}
		}

		auto script = "exec 3<&0; sleep 10 <&3 3<&-"
			~ descendantRedirections
			~ ` & printf '%s\n%s\n' "$$" "$!" > "$1"; ` ~ workload;
		auto observation = observeFilter(["sh", "-c", script, "test", pidFile],
			new immutable(ubyte)[4 * 1024 * 1024], limits);
		if (expected.isNull)
			assert(observation.failure is null && cast(string) observation.output == "ok");
		else
		{
			auto failure = cast(FilterFailure) observation.failure;
			assert(failure !is null && failure.kind == expected.get);
		}
		assert(observation.settled < deadline, "the filter must settle before the descendant exits");
		auto pids = readText(pidFile).splitLines;
		assert(kill(pids[0].to!pid_t, 0) == -1 && errno == ESRCH, "the launched child must be reaped");
		assert(observation.drained < deadline, "the event loop must drain before the descendant exits");
		assert(kill(pids[1].to!pid_t, 0) == 0, "the descendant must outlive the filter");
	}

	unittest
	{
		assertStopsWithDescendant("head -c 8192 /dev/zero; exec sleep 30", "",
			FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 20.seconds, 1024), nullable(FilterFailureKind.tooLarge));
	}

	unittest
	{
		assertStopsWithDescendant("exec sleep 30", "",
			FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 300.msecs, testLimits.outputBytes),
			nullable(FilterFailureKind.timedOut));
	}

	unittest
	{
		assertStopsWithDescendant("printf ok", " >/dev/null 2>&1", testLimits, Nullable!FilterFailureKind.init);
	}

	unittest
	{
		import ae.sys.timing : mainTimer;
		import std.array : array;

		// Daemon timers do not keep the loop alive, so also inspect the timer queue.
		auto pendingTimers = mainTimer.pendingTasks().array;
		auto limits = FilterLimits(ProcessResourceLimits.init, MonoTime.currTime + 30.seconds, testLimits.outputBytes);
		assertStopsWithDescendant("printf ok", " </dev/null >/dev/null", limits,
			Nullable!FilterFailureKind.init, 4.seconds);
		assert(mainTimer.pendingTasks().array == pendingTimers, "stderr drain fallback leaked a timer");
	}

	unittest
	{
		auto observation = observeFilter(["/nonexistent/cydo-filter"],
			new immutable(ubyte)[4 * 1024 * 1024], testLimits);
		auto failure = cast(FilterFailure) observation.failure;
		assert(failure !is null && failure.kind == FilterFailureKind.failed);
		assert(observation.settled < 1.seconds && observation.drained < 1.seconds);
	}

	unittest
	{
		enum script = `v=$(head -c 200000000 /dev/zero | tr '\0' x) &&
			[ "${#v}" -eq 200000000 ] && printf '%s' "${#v}"`;
		auto command = ["sh", "-c", script];
		auto limits = FilterLimits(ProcessResourceLimits(64 * 1024 * 1024, 0, 0),
			MonoTime.currTime + 30.seconds, testLimits.outputBytes);
		auto failure = collectException!FilterFailure(
			runBoundedFilter(command, null, limits).awaitSync());
		assert(failure !is null && failure.kind == FilterFailureKind.failed);

		limits.resources = ProcessResourceLimits.init;
		assert(cast(string) runBoundedFilter(command, null, limits).awaitSync().bytes == "200000000");
	}

	unittest
	{
		auto failure = collectException!FilterFailure(runBoundedFilter(
			["sh", "-c", "printf 'private converter diagnostic\\n' >&2; exit 3"],
			null, testLimits).awaitSync());
		assert(failure !is null && failure.msg == "conversion failed");
	}
}
