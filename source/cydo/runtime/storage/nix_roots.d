module cydo.runtime.storage.nix_roots;

import ae.sys.file : realPath;
import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.signal : SIGKILL;
import core.sys.posix.unistd : read;
import core.stdc.errno : errno, EINTR;
import core.time : MonoTime, msecs;
import std.algorithm : startsWith;
import std.file : exists;
import std.exception : errnoEnforce;
import std.json : JSONType, parseJSON;
import std.path : buildPath, dirName, isAbsolute;
import std.process : pipe, spawnProcess, tryWait, wait, kill;
import std.stdio : File;
import std.typecons : Nullable;

import cydo.runtime.launch.sandbox_renderer : resolveExecutablePath;
import cydo.runtime.storage.disk_usage : DiskSymlink;

immutable string nixClosureLabel = "Nix closure references (NAR bytes; may be GC roots)";

struct NixClosureEntry
{
	string[] linkPaths;
	string storePath;
	long closureSize;
}

struct NixClosureReport
{
	NixClosureEntry[] entries;
}

private struct CommandResult
{
	int status;
	string output;
	bool timedOut;
}

private CommandResult runNix(string executable, string target, int timeoutMs)
{
	auto stdoutPipe = pipe();
	auto stderrPipe = pipe();
	auto pid = spawnProcess([executable, "--extra-experimental-features", "nix-command",
		"path-info", "-S", "--json", "--json-format", "1", target],
		File("/dev/null"), stdoutPipe.writeEnd, stderrPipe.writeEnd);
	stdoutPipe.writeEnd.close();
	stderrPipe.writeEnd.close();
	auto deadline = MonoTime.currTime + timeoutMs.msecs;
	CommandResult result;
	bool finished;
	bool stdoutEOF;
	bool stderrEOF;
	while (!finished || !stdoutEOF || !stderrEOF)
	{
		if (MonoTime.currTime >= deadline)
		{
			if (!finished)
			{
				kill(pid, SIGKILL);
				wait(pid);
			}
			result.timedOut = true;
			break;
		}
		pollfd[2] descriptors = [
			pollfd(stdoutEOF ? -1 : stdoutPipe.readEnd.fileno, POLLIN, 0),
			pollfd(stderrEOF ? -1 : stderrPipe.readEnd.fileno, POLLIN, 0),
		];
		if (poll(descriptors.ptr, descriptors.length, 20) > 0)
		{
			foreach (index, descriptor; descriptors)
			{
				if (descriptor.revents == 0) continue;
				char[4096] buffer;
				auto count = read(descriptor.fd, buffer.ptr, buffer.length);
				if (count > 0)
				{
					if (index == 0) result.output ~= buffer[0 .. count];
				}
				else if (count == 0)
				{
					if (index == 0) stdoutEOF = true;
					else stderrEOF = true;
				}
				else if (errno == EINTR) continue;
				else errnoEnforce(false, "read from nix pipe");
			}
		}
		if (!finished)
		{
			auto state = tryWait(pid);
			if (state.terminated)
			{
				finished = true;
				result.status = state.status;
			}
		}
	}
	stdoutPipe.readEnd.close();
	stderrPipe.readEnd.close();
	return result;
}

private struct ClosureInfo
{
	string storePath;
	long size;
}

private Nullable!ClosureInfo parseClosureSize(string output, string target)
{
	try
	{
		auto value = parseJSON(output);
		if (value.type != JSONType.object || value.object.length != 1)
			throw new Exception("missing target key");
		string key;
		foreach (path, _; value.object) key = path;
		if (key != target && !target.startsWith(key ~ "/"))
			throw new Exception("missing target key");
		auto item = value.object[key];
		if (item.type == JSONType.null_) return Nullable!ClosureInfo.init;
		if (item.type != JSONType.object || "closureSize" !in item.object)
			throw new Exception("missing closureSize");
		auto size = item.object["closureSize"];
		if (size.type != JSONType.integer || size.integer < 0)
			throw new Exception("invalid closureSize");
		return Nullable!ClosureInfo(ClosureInfo(key, size.integer));
	}
	catch (Exception e)
		throw new Exception("Invalid nix path-info response for " ~ target ~ ": " ~ e.msg);
}

NixClosureReport reportNixClosures(DiskSymlink[] links, string executable = null,
	int timeoutMs = 30_000)
{
	NixClosureReport report;
	string[][string] targets;
	string[] orderedTargets;
	foreach (link; links)
	{
		auto path = isAbsolute(link.rawTarget) ? link.rawTarget
			: buildPath(dirName(link.linkPath), link.rawTarget);
		if (!exists(path)) continue;
		auto target = realPath(path);
		if (!target.startsWith("/nix/store/")) continue;
		if (target !in targets) orderedTargets ~= target;
		targets[target] ~= link.linkPath;
	}
	if (orderedTargets.length == 0) return report;
	if (executable is null) executable = resolveExecutablePath("nix", null);
	if (executable.length == 0) return report;
	size_t[string] entryIndex;
	foreach (target; orderedTargets)
	{
		auto command = runNix(executable, target, timeoutMs);
		if (command.timedOut || command.status != 0) continue;
		auto size = parseClosureSize(command.output, target);
		if (size.isNull) continue;
		auto info = size.get;
		if (auto index = info.storePath in entryIndex)
			report.entries[*index].linkPaths ~= targets[target];
		else
		{
			entryIndex[info.storePath] = report.entries.length;
			report.entries ~= NixClosureEntry(targets[target], info.storePath, info.size);
		}
	}
	return report;
}
