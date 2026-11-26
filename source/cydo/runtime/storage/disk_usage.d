module cydo.runtime.storage.disk_usage;

import cydo.runtime.launch.sandbox_materialization : isTaskTmpDirName, tmpRuntimeDirName;
import core.stdc.errno : EACCES, ENOENT, EPERM, errno;
import core.sys.posix.dirent : closedir, opendir, readdir;
import core.sys.posix.fcntl : AT_FDCWD, AT_SYMLINK_NOFOLLOW;
import core.sys.posix.unistd : X_OK, access;
import core.sys.posix.sys.stat : S_ISDIR, S_ISLNK, S_ISREG, lstat, stat_t;
import core.sys.posix.sys.types : mode_t;
import std.algorithm : sort, startsWith;
import std.conv : to;
import std.datetime.systime : SysTime, unixTimeToStdTime;
import std.exception : enforce;
import std.file : FileException, readLink;
import std.path : baseName, buildNormalizedPath, buildPath, isAbsolute;
import std.process : execute;
import std.string : indexOf, fromStringz, lastIndexOf, split, toStringz;
import std.traits : EnumMembers;

enum DiskCategory { task, temporary, sharedTemporary }

struct DiskScanInput
{
	string taskDir;
	string temporaryDir;
	string forkWorktree;
	string forkBaseSha;
	string forkRepository;
	string sharedTmpDir;
	SysTime sharedSince;
}

struct DiskEntry
{
	DiskCategory category;
	string relativePath;
	string absolutePath;
	long apparentBytes;
	ulong device;
	ulong inode;
	bool symlink;
	string symlinkTarget;
}

struct DiskTopPath
{
	DiskCategory category;
	string relativePath;
	long bytes;
}

struct DiskSymlink
{
	string linkPath;
	string rawTarget;
	string sharedRelativePath;
}

struct DiskUnmeasured
{
	DiskCategory category;
	string relativePath;
	string error;
}

struct DiskUsageResult
{
	long taskBytes;
	long temporaryBytes;
	long sharedTemporaryBytes;
	long totalBytes;
	DiskTopPath[] topPaths;
	DiskSymlink[] symlinks;
	DiskUnmeasured[] unmeasured;
}

private long checkedAdd(long a, long b)
{
	if (b > 0 && a > long.max - b || b < 0 && a < long.min - b)
		throw new Exception("Disk usage arithmetic overflow");
	return a + b;
}

long[string] parseLsTreeBlobs(string output)
{
	long[string] blobs;
	foreach (record; output.split("\0"))
	{
		if (record.length == 0)
			continue;
		auto tab = record.indexOf('\t');
		enforce(tab >= 0, "Invalid git ls-tree record");
		auto fields = record[0 .. tab].split();
		enforce(fields.length == 4, "Invalid git ls-tree metadata");
		if (fields[1] == "blob")
			blobs[record[tab + 1 .. $]] = fields[3].to!long;
	}
	return blobs;
}

private bool beneath(string path, string root)
{
	return root.length > 0 && path.startsWith(root ~ "/");
}

DiskUsageResult aggregateDiskUsage(DiskScanInput input, DiskEntry[] entries,
	long[string] baseline, DiskUnmeasured[] unmeasured = null)
{
	if (input.forkWorktree.length > 0)
		enforce(beneath(input.forkWorktree, input.taskDir),
			"Fork worktree " ~ input.forkWorktree ~ " is not inside task directory " ~ input.taskDir);
	unmeasured.sort!((a, b) => a.category != b.category
		? a.category < b.category : a.relativePath < b.relativePath);
	DiskUsageResult result;
	result.unmeasured = unmeasured;
	long[string][EnumMembers!DiskCategory.length] deltas;
	bool[string] visitedPaths;
	bool[string] visitedInodes;
	bool[string] baselinePaths;
	entries.sort!((a, b) => a.category != b.category
		? a.category < b.category : a.relativePath < b.relativePath);
	foreach (entry; entries)
	{
		if (entry.absolutePath in visitedPaths)
			continue;
		visitedPaths[entry.absolutePath] = true;
		long bytes;
		auto inodeKey = entry.device.to!string ~ ":" ~ entry.inode.to!string;
		if (inodeKey !in visitedInodes)
		{
			visitedInodes[inodeKey] = true;
			bytes = entry.apparentBytes;
		}
		if (entry.category == DiskCategory.task && beneath(entry.absolutePath, input.forkWorktree))
		{
			auto forkRelative = entry.absolutePath[input.forkWorktree.length + 1 .. $];
			if (auto base = forkRelative in baseline)
			{
				bytes = checkedAdd(bytes, -(*base));
				baselinePaths[forkRelative] = true;
			}
		}
		deltas[entry.category][entry.relativePath] = checkedAdd(
			deltas[entry.category].get(entry.relativePath, 0), bytes);
		if (entry.symlink)
			result.symlinks ~= DiskSymlink(entry.absolutePath, entry.symlinkTarget,
				entry.category == DiskCategory.sharedTemporary ? entry.relativePath : null);
	}
	bool[string] unmeasuredTaskPaths;
	foreach (path; unmeasured)
		if (path.category == DiskCategory.task)
			unmeasuredTaskPaths[path.relativePath] = true;
	baselineEntry: foreach (path, bytes; baseline)
	{
		if (path in baselinePaths)
			continue;
		auto absolute = buildPath(input.forkWorktree, path);
		if (absolute in visitedPaths)
			continue;
		auto relative = absolute[input.taskDir.length + 1 .. $];
		for (auto ancestor = relative; unmeasuredTaskPaths.length > 0;)
		{
			if (ancestor in unmeasuredTaskPaths)
				continue baselineEntry;
			auto slash = ancestor.lastIndexOf('/');
			if (slash < 0) break;
			ancestor = ancestor[0 .. slash];
		}
		deltas[DiskCategory.task][relative] = checkedAdd(
			deltas[DiskCategory.task].get(relative, 0), -bytes);
	}
	DiskTopPath[] candidates;
	foreach (index, paths; deltas)
	{
		auto category = cast(DiskCategory) index;
		long categoryBytes;
		long[string] subtrees;
		foreach (relative, delta; paths)
		{
			categoryBytes = checkedAdd(categoryBytes, delta);
			for (auto end = relative.length; end > 0;)
			{
				auto parent = relative[0 .. end];
				subtrees[parent] = checkedAdd(subtrees.get(parent, 0), delta);
				auto slash = parent.lastIndexOf('/');
				if (slash < 0) break;
				end = slash;
			}
		}
		final switch (category)
		{
		case DiskCategory.task: result.taskBytes = categoryBytes; break;
		case DiskCategory.temporary: result.temporaryBytes = categoryBytes; break;
		case DiskCategory.sharedTemporary: result.sharedTemporaryBytes = categoryBytes; break;
		}
		foreach (path, bytes; subtrees)
			if (bytes > 0)
				candidates ~= DiskTopPath(category, path, bytes);
	}
	result.totalBytes = checkedAdd(checkedAdd(result.taskBytes, result.temporaryBytes),
		result.sharedTemporaryBytes);
	candidates.sort!((a, b) => a.bytes != b.bytes ? a.bytes > b.bytes
		: a.category != b.category ? a.category < b.category
		: a.relativePath < b.relativePath);
	foreach (candidate; candidates)
	{
		bool overlaps;
		foreach (selected; result.topPaths)
			if (candidate.category == selected.category &&
				(candidate.relativePath == selected.relativePath ||
				beneath(candidate.relativePath, selected.relativePath) ||
				beneath(selected.relativePath, candidate.relativePath)))
				overlaps = true;
		if (!overlaps)
			result.topPaths ~= candidate;
		if (result.topPaths.length == 10) break;
	}
	return result;
}

string[] listDirectory(string path)
{
	auto dir = opendir(path.toStringz);
	if (dir is null)
		throw new FileException(path, errno);
	scope (exit) closedir(dir);

	string[] children;
	while (true)
	{
		errno = 0;
		auto child = readdir(dir);
		if (child is null)
		{
			if (errno != 0)
				throw new FileException(path, errno);
			return children;
		}
		auto name = (&child.d_name[0]).fromStringz;
		if (name != "." && name != "..")
			children ~= buildPath(path, name.idup);
	}
}

private bool permissionDenied(int error)
{
	return error == EACCES || error == EPERM;
}

// Linux statx ABI.
private struct StatxTimestamp
{
	long seconds;
	uint nanoseconds;
	int reserved;
}

private struct Statx
{
	uint mask;
	uint blockSize;
	ulong attributes;
	uint links;
	uint uid;
	uint gid;
	ushort mode;
	ushort reserved;
	ulong inode;
	ulong size;
	ulong blocks;
	ulong attributesMask;
	StatxTimestamp accessTime;
	StatxTimestamp birthTime;
	StatxTimestamp changeTime;
	StatxTimestamp modificationTime;
	uint rdevMajor;
	uint rdevMinor;
	uint devMajor;
	uint devMinor;
	ulong[14] remaining;
}

static assert(Statx.birthTime.offsetof == 80 && Statx.devMajor.offsetof == 136
	&& Statx.sizeof == 256);
private enum STATX_BTIME = 0x0800;
private enum STATX_TYPE = 0x0001;
private enum STATX_INO = 0x0100;
private enum STATX_SIZE = 0x0200;
private extern(C) ulong gnu_dev_makedev(uint major, uint minor) nothrow @nogc;
private extern(C) int statx(int dirfd, const(char)* path, int flags, uint mask,
	Statx* info) nothrow @nogc;

private void walkRoot(string root, DiskCategory category, ref DiskEntry[] entries,
	ref DiskUnmeasured[] unmeasured, string[] delegate(string dir) list,
	SysTime sharedSince = SysTime.init)
{
	void recordUnmeasured(string path, string error)
	{
		unmeasured ~= DiskUnmeasured(category, path[root.length + 1 .. $], error);
	}

	auto runtimeName = category == DiskCategory.sharedTemporary ? tmpRuntimeDirName() : null;

	void walk(string path, bool isRoot, bool sharedTopLevel = false)
	{
		mode_t mode;
		long bytes;
		ulong device, inode;
		if (sharedTopLevel)
		{
			Statx info;
			enum basicMask = STATX_TYPE | STATX_INO | STATX_SIZE;
			if (statx(AT_FDCWD, path.toStringz, AT_SYMLINK_NOFOLLOW, basicMask | STATX_BTIME, &info) != 0)
			{
				auto error = errno;
				if (error == ENOENT) return;
				throw new FileException(path, error);
			}
			enforce((info.mask & basicMask) == basicMask, "Disk usage metadata unavailable for " ~ path);
			auto name = path.baseName;
			if (S_ISDIR(info.mode) && (isTaskTmpDirName(name) || name == runtimeName))
				return;
			enforce((info.mask & STATX_BTIME) != 0, "Disk usage birth time unavailable for " ~ path);
			if (unixTimeToStdTime(info.birthTime.seconds) + info.birthTime.nanoseconds / 100
				< sharedSince.stdTime)
				return;
			mode = info.mode;
			bytes = cast(long) info.size;
			device = gnu_dev_makedev(info.devMajor, info.devMinor);
			inode = info.inode;
		}
		else
		{
			stat_t info;
			if (lstat(path.toStringz, &info) != 0)
			{
				auto error = errno;
				if (error == ENOENT && !isRoot) return;
				if (error == ENOENT) throw new Exception("Disk usage root does not exist: " ~ root);
				throw new Exception("Cannot inspect disk usage path: " ~ path);
			}
			mode = info.st_mode;
			bytes = info.st_size;
			device = info.st_dev;
			inode = info.st_ino;
		}
		auto isDirectory = S_ISDIR(mode) != 0;
		if (isRoot && !isDirectory)
			throw new Exception("Disk usage root is not a directory: " ~ root);
		if (isDirectory)
		{
			// Listing needs read permission, but measuring children also needs search permission.
			if (access(path.toStringz, X_OK) != 0)
			{
				auto error = errno;
				if (error == ENOENT && !isRoot) return;
				auto failure = new FileException(path, error);
				if (!isRoot && permissionDenied(error))
				{
					recordUnmeasured(path, failure.msg);
					return;
				}
				throw new Exception("Cannot search disk usage directory " ~ path ~ ": " ~ failure.msg);
			}
			string[] children;
			try
				children = list(path);
			catch (FileException e)
			{
				if (e.errno == ENOENT && !isRoot) return;
				if (!isRoot && permissionDenied(e.errno))
				{
					recordUnmeasured(path, e.msg);
					return;
				}
				throw new Exception("Cannot read disk usage directory " ~ path ~ ": " ~ e.msg);
			}
			children.sort();
			foreach (child; children) walk(child, false, isRoot && category == DiskCategory.sharedTemporary);
			return;
		}
		if (!S_ISREG(mode) && !S_ISLNK(mode)) return;
		DiskEntry entry;
		entry.category = category;
		entry.absolutePath = path;
		entry.relativePath = path[root.length + 1 .. $];
		entry.apparentBytes = bytes;
		entry.device = device;
		entry.inode = inode;
		entry.symlink = S_ISLNK(mode);
		if (entry.symlink)
		{
			try entry.symlinkTarget = readLink(path);
			catch (FileException e)
			{
				if (e.errno == ENOENT) return;
				throw new Exception("Cannot read disk usage symlink " ~ path ~ ": " ~ e.msg);
			}
		}
		entries ~= entry;
	}
	walk(root, true);
}

DiskUsageResult measureDiskUsage(DiskScanInput input)
{
	return measureDiskUsage(input, (string dir) => listDirectory(dir));
}

DiskUsageResult measureDiskUsage(DiskScanInput input,
	string[] delegate(string dir) list)
{
	foreach (root; [input.taskDir, input.temporaryDir, input.forkWorktree, input.sharedTmpDir])
		if (root.length > 0)
			enforce(root.isAbsolute && root == buildNormalizedPath(root),
				"Disk usage root must be a normalized absolute path: " ~ root);
	if (input.sharedTmpDir.length > 0)
		enforce(input.sharedSince.stdTime != SysTime.init.stdTime,
			"Disk usage shared temporary directory requires a birth-time cutoff: " ~ input.sharedTmpDir);
	long[string] baseline;
	if (input.forkWorktree.length > 0)
	{
		enforce(input.forkBaseSha.length > 0,
			"Cannot resolve fork base for " ~ input.forkWorktree);
		enforce(input.forkRepository.length > 0,
			"Cannot resolve fork repository for " ~ input.forkWorktree);
		auto listing = execute(["git", "-C", input.forkRepository, "ls-tree",
			"--full-tree", "-r", "-l", "-z", input.forkBaseSha]);
		enforce(listing.status == 0, "Cannot list fork base for " ~ input.forkWorktree
			~ " in " ~ input.forkRepository ~ ": " ~ listing.output);
		baseline = parseLsTreeBlobs(listing.output);
	}
	DiskEntry[] entries;
	DiskUnmeasured[] unmeasured;
	walkRoot(input.taskDir, DiskCategory.task, entries, unmeasured, list);
	walkRoot(input.temporaryDir, DiskCategory.temporary, entries, unmeasured, list);
	if (input.sharedTmpDir.length > 0)
		walkRoot(input.sharedTmpDir, DiskCategory.sharedTemporary, entries, unmeasured, list,
			input.sharedSince);
	return aggregateDiskUsage(input, entries, baseline, unmeasured);
}
