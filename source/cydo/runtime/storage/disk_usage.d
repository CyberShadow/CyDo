module cydo.runtime.storage.disk_usage;

import core.stdc.errno : EACCES, ENOENT, EPERM, errno;
import core.sys.posix.unistd : X_OK, access;
import core.sys.posix.sys.stat : S_ISDIR, S_ISLNK, S_ISREG, lstat, stat_t;
import std.algorithm : sort, startsWith;
import std.conv : to;
import std.exception : enforce;
import std.file : FileException, SpanMode, dirEntries, readLink;
import std.path : buildNormalizedPath, buildPath, isAbsolute;
import std.process : execute;
import std.string : indexOf, lastIndexOf, split, toStringz;

enum DiskCategory { task, temporary }

struct DiskScanInput
{
	string taskDir;
	string temporaryDir;
	string forkWorktree;
	string forkBaseSha;
	string forkRepository;
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
	long[string] deltas;
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
		auto key = entry.category.to!string ~ ":" ~ entry.relativePath;
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
		deltas[key] = checkedAdd(key in deltas ? deltas[key] : 0, bytes);
		if (entry.symlink)
			result.symlinks ~= DiskSymlink(entry.absolutePath, entry.symlinkTarget);
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
		auto key = DiskCategory.task.to!string ~ ":" ~ relative;
		deltas[key] = checkedAdd(key in deltas ? deltas[key] : 0, -bytes);
	}
	long[string] subtrees;
	foreach (key, delta; deltas)
	{
		auto separator = key.indexOf(':');
		auto category = key[0 .. separator];
		if (category == DiskCategory.task.to!string)
			result.taskBytes = checkedAdd(result.taskBytes, delta);
		else
			result.temporaryBytes = checkedAdd(result.temporaryBytes, delta);
		auto relative = key[separator + 1 .. $];
		for (auto end = relative.length; end > 0;)
		{
			auto parentKey = category ~ ":" ~ relative[0 .. end];
			subtrees[parentKey] = checkedAdd(parentKey in subtrees ? subtrees[parentKey] : 0, delta);
			auto slash = relative[0 .. end].lastIndexOf('/');
			if (slash < 0) break;
			end = slash;
		}
	}
	result.totalBytes = checkedAdd(result.taskBytes, result.temporaryBytes);
	DiskTopPath[] candidates;
	foreach (key, bytes; subtrees)
		if (bytes > 0)
		{
			auto separator = key.indexOf(':');
			candidates ~= DiskTopPath(key[0 .. separator] == DiskCategory.task.to!string
				? DiskCategory.task : DiskCategory.temporary, key[separator + 1 .. $], bytes);
		}
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
	string[] children;
	foreach (child; dirEntries(path, SpanMode.shallow))
		children ~= child.name;
	return children;
}

private bool permissionDenied(int error)
{
	return error == EACCES || error == EPERM;
}

private void walkRoot(string root, DiskCategory category, ref DiskEntry[] entries,
	ref DiskUnmeasured[] unmeasured, string[] delegate(string dir) list)
{
	void recordUnmeasured(string path, string error)
	{
		unmeasured ~= DiskUnmeasured(category, path[root.length + 1 .. $], error);
	}

	void walk(string path, bool isRoot)
	{
		stat_t info;
		if (lstat(path.toStringz, &info) != 0)
		{
			auto error = errno;
			if (error == ENOENT)
			{
				if (isRoot) throw new Exception("Disk usage root does not exist: " ~ root);
				return;
			}
			throw new Exception("Cannot inspect disk usage path: " ~ path);
		}
		if (isRoot && !S_ISDIR(info.st_mode))
			throw new Exception("Disk usage root is not a directory: " ~ root);
		if (S_ISDIR(info.st_mode))
		{
			// Listing needs read permission, but measuring children also needs search permission.
			if (access(path.toStringz, X_OK) != 0)
			{
				auto error = errno;
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
			foreach (child; children) walk(child, false);
			return;
		}
		if (!S_ISREG(info.st_mode) && !S_ISLNK(info.st_mode)) return;
		DiskEntry entry;
		entry.category = category;
		entry.absolutePath = path;
		entry.relativePath = path[root.length + 1 .. $];
		entry.apparentBytes = info.st_size;
		entry.device = info.st_dev;
		entry.inode = info.st_ino;
		entry.symlink = S_ISLNK(info.st_mode);
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
	foreach (root; [input.taskDir, input.temporaryDir, input.forkWorktree])
		if (root.length > 0)
			enforce(root.isAbsolute && root == buildNormalizedPath(root),
				"Disk usage root must be a normalized absolute path: " ~ root);
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
	return aggregateDiskUsage(input, entries, baseline, unmeasured);
}
