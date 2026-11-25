module cydo.workflow.show;

import core.sys.posix.fcntl : open, O_CLOEXEC, O_NOCTTY, O_NONBLOCK, O_RDONLY;
import core.sys.posix.sys.stat : fstat, S_ISREG, stat_t;
import core.sys.posix.unistd : close, read;
import std.algorithm : min;
import std.exception : assumeUnique, enforce, errnoEnforce;
import std.format : format;
import std.path : extension, isAbsolute;
import std.string : toStringz;
import std.uni : toLower;
import std.utf : validate, UTFException;

import ae.utils.promise : Promise;
import cydo.runtime.launch.sandbox : cydoBinaryPath;
import cydo.workflow.sessions.task_runner : SandboxedCommandResult;

enum size_t showMaxBytes = 16 * 1024 * 1024;

immutable(ubyte)[] readShowableFile(string path)
{
	enforce(isAbsolute(path), path ~ ": expected an absolute path");
	auto fd = open(path.toStringz, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
	errnoEnforce(fd >= 0, path);
	scope (exit) close(fd);

	stat_t info;
	errnoEnforce(fstat(fd, &info) == 0, path);
	enforce(S_ISREG(info.st_mode), path ~ " is not a regular file");
	enforce(info.st_size <= showMaxBytes,
		format("%s is %s bytes; at most %s bytes can be shown", path, info.st_size, showMaxBytes));

	ubyte[] bytes;
	ubyte[64 * 1024] buffer;
	while (bytes.length <= showMaxBytes)
	{
		auto count = read(fd, buffer.ptr, min(buffer.length, showMaxBytes + 1 - bytes.length));
		errnoEnforce(count >= 0, path);
		if (count == 0)
			break;
		bytes ~= buffer[0 .. count];
	}
	enforce(bytes.length <= showMaxBytes,
		format("%s exceeds %s bytes; at most %s bytes can be shown", path, showMaxBytes, showMaxBytes));
	return assumeUnique(bytes);
}

struct ShownFile
{
	string mediaType;
	immutable(ubyte)[] bytes;
}

Promise!ShownFile readShownFile(Promise!SandboxedCommandResult delegate(int, string[]) run,
	int tid, string path)
{
	import std.algorithm : canFind;
	import std.string : strip;

	enforce(isAbsolute(path), "The file path must be absolute");
	enforce(!path.canFind('\0'), "The file path contains a NUL character");
	return run(tid, [cydoBinaryPath, "read-shown-file", "--", path])
		.then((SandboxedCommandResult result) {
			enforce(result.status == 0, result.stderr.strip);
			return classifyShownFile(path, result.stdout);
		});
}

unittest
{
	import std.exception : collectException;

	auto failure = collectException(readShownFile(
		delegate Promise!SandboxedCommandResult(int, string[]) {
			assert(0, "A path containing NUL must never reach the sandbox runner");
		}, 1, "/tmp/first\0second"));
	assert(failure !is null && failure.msg == "The file path contains a NUL character");
}

ShownFile classifyShownFile(string path, immutable(ubyte)[] bytes)
{
	string mediaType;
	switch (path.extension.toLower)
	{
	case ".png": mediaType = "image/png"; break;
	case ".jpg", ".jpeg": mediaType = "image/jpeg"; break;
	case ".gif": mediaType = "image/gif"; break;
	case ".webp": mediaType = "image/webp"; break;
	default:
		try validate(cast(string) bytes);
		catch (UTFException)
			throw new Exception(path ~ " is neither a PNG/JPEG/GIF/WebP image nor UTF-8 text");
		mediaType = "text/plain; charset=utf-8";
		break;
	}
	return ShownFile(mediaType, bytes);
}

unittest
{
	import core.sys.posix.sys.stat : mkfifo;
	import core.sys.posix.unistd : truncate;
	import std.algorithm : canFind;
	import std.exception : collectException, assertThrown;
	import std.file : mkdir, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto temp = buildPath(tempDir(), "cydo-show-" ~ randomUUID().toString());
	mkdir(temp);
	scope (exit) rmdirRecurse(temp);
	auto path = buildPath(temp, "file");
	write(path, "contents");
	assert(readShowableFile(path) == cast(immutable(ubyte)[]) "contents");
	assertThrown(readShowableFile("relative"));

	auto missing = buildPath(temp, "missing");
	assert(collectException(readShowableFile(missing)).msg.canFind(missing));
	assert(collectException(readShowableFile(temp)).msg.canFind("not a regular file"));
	auto fifo = buildPath(temp, "fifo");
	errnoEnforce(mkfifo(fifo.toStringz, 0x180) == 0, fifo);
	assert(collectException(readShowableFile(fifo)).msg.canFind("not a regular file"));
	assert(collectException(readShowableFile("/dev/null")).msg.canFind("not a regular file"));

	errnoEnforce(truncate(path.toStringz, showMaxBytes + 1) == 0, path);
	assert(collectException(readShowableFile(path)).msg.canFind("16777217 bytes"));
}

unittest
{
	import std.exception : assertThrown;

	assert(classifyShownFile("image.PNG", [0xFF]).mediaType == "image/png");
	assert(classifyShownFile("image.jpeg", [0xFF]).mediaType == "image/jpeg");
	assert(classifyShownFile("text.md", cast(immutable(ubyte)[]) "# Héading")
		.mediaType == "text/plain; charset=utf-8");
	assertThrown(classifyShownFile("text.txt", [0xFF]));
}
