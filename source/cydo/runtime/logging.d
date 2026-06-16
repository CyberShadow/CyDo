module cydo.runtime.logging;

import core.stdc.errno : EINTR, errno;
import core.sys.posix.unistd : STDERR_FILENO, write;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.logger.core : LogLevel, Logger, sharedLog, systimeToISOString;
import std.string : lastIndexOf, representation;

/// Logger implementation that writes directly to stderr via POSIX write(2)
/// and tolerates interrupted/partial writes.
class RobustStderrLogger : Logger
{
	this(this This)(LogLevel lv = LogLevel.all)
	{
		super(lv);
	}

	override protected void writeLogMsg(ref LogEntry payload) @safe
	{
		auto line = formatLogLine(payload);
		writeAllIgnoringErrors(STDERR_FILENO, cast(const(ubyte)[]) line.representation);
	}

	private string formatLogLine(ref LogEntry payload) @safe
	{
		auto ts = appender!string();
		systimeToISOString(ts, payload.timestamp);

		ptrdiff_t fnIdx = payload.file.lastIndexOf('/') + 1;
		ptrdiff_t funIdx = payload.funcName.lastIndexOf('.') + 1;
		return format("%s [%s] %s:%u:%s %s\n",
			ts.data,
			payload.logLevel.to!string,
			payload.file[fnIdx .. $],
			payload.line,
			payload.funcName[funIdx .. $],
			payload.msg);
	}
}

/// Install the robust stderr logger as sharedLog.
void installRobustLogger()
{
	auto oldLog = sharedLog;
	if (cast(RobustStderrLogger) cast() oldLog !is null)
		return;

	auto logger = new shared RobustStderrLogger();
	if (oldLog !is null)
		(cast() logger).logLevel = (cast() oldLog).logLevel;
	sharedLog = logger;
}

private bool writeAllIgnoringErrors(int fd, scope const(ubyte)[] msg) @trusted
{
	return writeAllIgnoringErrors(fd, msg,
		(int wfd, const scope void* data, size_t n) => write(wfd, data, n));
}

private bool writeAllIgnoringErrors(
	int fd,
	scope const(ubyte)[] msg,
	scope ptrdiff_t delegate(int, const scope void*, size_t) writer,
) @trusted
{
	size_t pos = 0;
	while (pos < msg.length)
	{
		auto written = writer(fd, msg.ptr + pos, msg.length - pos);
		if (written > 0)
		{
			pos += cast(size_t) written;
			continue;
		}
		if (written < 0 && errno == EINTR)
			continue;
		return false;
	}
	return true;
}

@safe unittest
{
	static size_t callCount;
	static size_t[] callLengths;
	callCount = 0;
	callLengths.length = 0;

	ptrdiff_t writer(int, const scope void*, size_t len) @trusted
	{
		callLengths ~= len;
		++callCount;
		if (callCount == 1)
			return 2;
		if (callCount == 2)
			return 1;
		return cast(ptrdiff_t) len;
	}

	const(ubyte)[] payload = cast(const(ubyte)[]) "abcdef".representation;
	assert(writeAllIgnoringErrors(2, payload, &writer));
	assert(callCount == 3);
	assert(callLengths == [6, 4, 3]);
}

@safe unittest
{
	static size_t callCount;
	callCount = 0;

	ptrdiff_t writer(int, const scope void*, size_t len) @trusted
	{
		++callCount;
		if (callCount == 1)
		{
			errno = EINTR;
			return -1;
		}
		return cast(ptrdiff_t) len;
	}

	const(ubyte)[] payload = cast(const(ubyte)[]) "abc".representation;
	assert(writeAllIgnoringErrors(2, payload, &writer));
	assert(callCount == 2);
}

@safe unittest
{
	static size_t callCount;
	callCount = 0;

	ptrdiff_t writer(int, const scope void*, size_t) @trusted
	{
		++callCount;
		errno = 5;
		return -1;
	}

	const(ubyte)[] payload = cast(const(ubyte)[]) "abc".representation;
	assert(!writeAllIgnoringErrors(2, payload, &writer));
	assert(callCount == 1);
}
