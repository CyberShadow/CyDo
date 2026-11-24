module cydo.workflow.workspace.worktree_dedup;

import core.stdc.errno : ELOOP, ENOENT, ENOTDIR, ENOTTY, EOPNOTSUPP, EXDEV, errno;
import core.sys.posix.dirent : DIR, closedir, readdir;
import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK, O_RDONLY, open;
import core.sys.posix.sys.stat : S_ISDIR, S_ISREG, fstat, stat_t;
import core.sys.posix.unistd : close;
import std.algorithm : among, min;
import core.time : MonoTime;
import std.exception : ErrnoException, enforce, errnoEnforce;
import std.functional : toDelegate;
import std.logger : infof;
import std.stdio : File;
import std.string : fromStringz, toStringz;

import ae.sys.btrfs.extent_same : Extent, sameExtent;
import ae.utils.promise.concurrency : threadAsync;

struct WorktreeDedupSummary
{
	size_t filesDeduped;
	ulong bytesDeduped;
	size_t filesSkipped;
	string abortReason;
}

// These Linux interfaces are missing from druntime.
private extern (C) nothrow @nogc
{
	int openat(int fd, const(char)* path, int flags, ...);
	int fstatat(int fd, const(char)* path, stat_t* info, int flags);
	DIR* fdopendir(int fd);
}

private enum AT_SYMLINK_NOFOLLOW = 0x100;
private enum directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;

private int openRoot(string path)
{
	auto fd = open(path.length ? path.toStringz : ".", directoryFlags);
	errnoEnforce(fd >= 0, path);
	return fd;
}

private int openSubdirectory(int parentFd, const(char)* name)
{
	auto fd = openat(parentFd, name, directoryFlags | O_NOFOLLOW);
	if (fd < 0 && !errno.among(ENOENT, ELOOP, ENOTDIR))
		throw new ErrnoException(name.fromStringz.idup);
	return fd;
}

alias DedupeFile = void delegate(int sourceDir, int destDir, const(char)* name, ulong size,
	ref ulong bytesDeduped);

/// Walk matching regular files without following symlinks or entering .git.
/// The delegate borrows both directory descriptors and the entry name, and
/// adds bytes as they are shared so that partial progress survives exceptions.
/// Per-file errors are classified here. Walk errors propagate to the caller.
WorktreeDedupSummary dedupTree(string source, string dest, DedupeFile dedupeFile)
{
	WorktreeDedupSummary summary;
	dedupTree(source, dest, dedupeFile, summary);
	return summary;
}

private void dedupTree(string source, string dest, DedupeFile dedupeFile,
	ref WorktreeDedupSummary summary)
{
	// Each call takes ownership of destDir. The source directory is borrowed.
	void walk(int sourceDir, int destDir)
	{
		auto dir = fdopendir(destDir);
		if (dir is null)
		{
			auto failure = new ErrnoException("fdopendir");
			close(destDir);
			throw failure;
		}
		scope(exit) closedir(dir);

		while (true)
		{
			errno = 0;
			auto entry = readdir(dir);
			if (entry is null)
			{
				errnoEnforce(errno == 0, "readdir");
				return;
			}

			auto name = entry.d_name.ptr;
			if (name.fromStringz.among(".", "..", ".git"))
				continue;

			stat_t destInfo;
			if (fstatat(destDir, name, &destInfo, AT_SYMLINK_NOFOLLOW) != 0)
			{
				if (errno == ENOENT)
					continue;
				throw new ErrnoException(name.fromStringz.idup);
			}
			if (!S_ISDIR(destInfo.st_mode) &&
				(!S_ISREG(destInfo.st_mode) || destInfo.st_size <= 0))
				continue;

			stat_t sourceInfo;
			if (fstatat(sourceDir, name, &sourceInfo, AT_SYMLINK_NOFOLLOW) != 0)
			{
				if (errno == ENOENT)
					continue;
				throw new ErrnoException(name.fromStringz.idup);
			}

			if (S_ISDIR(destInfo.st_mode))
			{
				if (!S_ISDIR(sourceInfo.st_mode))
					continue;
				auto sourceChild = openSubdirectory(sourceDir, name);
				if (sourceChild < 0)
					continue;
				scope(exit) close(sourceChild);
				auto destChild = openSubdirectory(destDir, name);
				if (destChild < 0)
					continue;
				walk(sourceChild, destChild);
				if (summary.abortReason.length)
					return;
				continue;
			}
			if (!S_ISREG(sourceInfo.st_mode) || sourceInfo.st_size != destInfo.st_size)
				continue;

			try
			{
				dedupeFile(sourceDir, destDir, name, destInfo.st_size, summary.bytesDeduped);
				summary.filesDeduped++;
			}
			catch (ErrnoException e)
			{
				if (e.errno.among(EOPNOTSUPP, ENOTTY, EXDEV))
				{
					summary.abortReason = e.msg;
					return;
				}
				summary.filesSkipped++;
			}
			catch (Exception)
				summary.filesSkipped++;
		}
	}

	auto sourceDir = openRoot(source);
	scope(exit) close(sourceDir);
	walk(sourceDir, openRoot(dest));
}

private File openRegularFile(int dir, const(char)* name, ulong size)
{
	auto fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	errnoEnforce(fd >= 0, name.fromStringz.idup);
	scope(failure) close(fd);

	stat_t info;
	errnoEnforce(fstat(fd, &info) == 0, name.fromStringz.idup);
	enforce(S_ISREG(info.st_mode) && info.st_size == size, "Dedup candidate changed");

	File file;
	file.fdopen(fd);
	return file;
}

/// Open both files read-only and share matching extents in 16 MiB chunks.
void dedupeFileExtents(int sourceDir, int destDir, const(char)* name, ulong size,
	ref ulong bytesDeduped)
{
	enum chunkSize = 16 << 20;
	auto source = openRegularFile(sourceDir, name, size);
	auto dest = openRegularFile(destDir, name, size);
	Extent[2] extents = [Extent(source, 0), Extent(dest, 0)];
	for (ulong offset; offset < size;)
	{
		auto length = min(chunkSize, size - offset);
		extents[0].offset = extents[1].offset = offset;
		bytesDeduped += sameExtent(extents[], length).totalBytesDeduped;
		offset += length;
	}
}

/// Run a synchronous best-effort pass, logging its outcome.
void dedupWorktree(string source, string dest)
{
	auto start = MonoTime.currTime;
	WorktreeDedupSummary summary;
	try
		dedupTree(source, dest, toDelegate(&dedupeFileExtents), summary);
	catch (Exception e)
		summary.abortReason = e.msg;

	if (summary.abortReason.length)
		infof("Worktree dedup %s against %s skipped after %d files, %d bytes shared, %d skipped: %s",
			dest, source, summary.filesDeduped, summary.bytesDeduped, summary.filesSkipped,
			summary.abortReason);
	else
		infof("Worktree dedup %s against %s: %d files, %d bytes shared, %d skipped, in %s",
			dest, source, summary.filesDeduped, summary.bytesDeduped, summary.filesSkipped,
			MonoTime.currTime - start);
}

/// Dispatch the pass from the event-loop thread.
void dedupWorktreeInBackground(string source, string dest)
{
	threadAsync({ dedupWorktree(source, dest); }).ignoreResult();
}

version (unittest)
{
	import core.memory : GC;
	import core.stdc.errno : EINVAL;
	import core.sys.posix.sys.stat : S_IRUSR, S_IWUSR, mkfifo;
	import core.sys.posix.unistd : alarm, symlink;
	import std.file : SpanMode, dirEntries, mkdir, mkdirRecurse, readLink, readText, remove,
		rmdir, rmdirRecurse, tempDir, write;
	import std.conv : to;
	import std.path : buildPath;
	import std.range : walkLength;
	import std.uuid : randomUUID;

	private struct DedupTestTrees
	{
		string root;
		string source;
		string dest;

		static DedupTestTrees create()
		{
			auto root = buildPath(tempDir(), "cydo-worktree-dedup-" ~ randomUUID().toString());
			auto trees = DedupTestTrees(root, buildPath(root, "source"), buildPath(root, "dest"));
			mkdirRecurse(trees.source);
			mkdir(trees.dest);
			return trees;
		}

		void writePair(string path, string contents)
		{
			write(buildPath(source, path), contents);
			write(buildPath(dest, path), contents);
		}
	}
}

unittest // Only matching regular non-empty files outside .git are candidates.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);

	foreach (root; [trees.source, trees.dest])
	{
		mkdir(buildPath(root, "sub"));
		mkdirRecurse(buildPath(root, "nested", ".git"));
	}

	trees.writePair("a.txt", "one");
	trees.writePair("sub/b.txt", "three");
	trees.writePair("empty.txt", "");
	trees.writePair(".git", "gitdir");
	trees.writePair("nested/.git/config", "config");
	write(buildPath(trees.source, "size.txt"), "small");
	write(buildPath(trees.dest, "size.txt"), "larger");
	write(buildPath(trees.dest, "onlydest.txt"), "destination");
	write(buildPath(trees.source, "link"), "one");
	assert(symlink("a.txt", buildPath(trees.dest, "link").toStringz) == 0);
	write(buildPath(trees.dest, "rev"), "one");
	assert(symlink("a.txt", buildPath(trees.source, "rev").toStringz) == 0);
	mkdir(buildPath(trees.source, "dirfile"));
	write(buildPath(trees.dest, "dirfile"), "file");
	assert(symlink("sub", buildPath(trees.source, "sdir").toStringz) == 0);
	mkdir(buildPath(trees.dest, "sdir"));
	write(buildPath(trees.dest, "sdir", "b.txt"), "three");

	string[string] expectedSources = [
		buildPath(trees.dest, "a.txt"): buildPath(trees.source, "a.txt"),
		buildPath(trees.dest, "sub", "b.txt"): buildPath(trees.source, "sub", "b.txt"),
	];
	ulong[string] expectedSizes = [
		buildPath(trees.dest, "a.txt"): 3UL,
		buildPath(trees.dest, "sub", "b.txt"): 5UL,
	];
	auto summary = dedupTree(trees.source, trees.dest, (int sourceDir, int destDir, const(char)* name, ulong size,
		ref ulong bytesDeduped) {
		auto sourceFile = buildPath(readLink("/proc/self/fd/" ~ sourceDir.to!string), name.fromStringz);
		auto destFile = buildPath(readLink("/proc/self/fd/" ~ destDir.to!string), name.fromStringz);
		assert(destFile in expectedSources, destFile);
		assert(sourceFile == expectedSources[destFile], sourceFile);
		assert(size == expectedSizes[destFile], destFile);
		expectedSources.remove(destFile);
		bytesDeduped += size;
	});

	assert(expectedSources.length == 0);
	assert(summary.filesDeduped == 2);
	assert(summary.bytesDeduped == 8);
	assert(summary.filesSkipped == 0);
	assert(summary.abortReason.length == 0);
}

unittest // Per-file failures leave the other candidates eligible.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	foreach (name; ["differs", "vanished", "resized", "match"])
		trees.writePair(name, "data");

	auto summary = dedupTree(trees.source, trees.dest, (int sourceDir, int destDir, const(char)* name, ulong size,
		ref ulong bytesDeduped) {
		switch (name.fromStringz)
		{
			case "differs": throw new Exception("Extent differs");
			case "vanished": throw new ErrnoException("x", ENOENT);
			case "resized": throw new ErrnoException("x", EINVAL);
			case "match": bytesDeduped += size; break;
			default: assert(0, name.fromStringz);
		}
	});

	assert(summary.filesSkipped == 3);
	assert(summary.filesDeduped == 1);
	assert(summary.abortReason.length == 0);
}

unittest // A failed file retains the bytes shared before the error.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	trees.writePair("file", "data");

	auto summary = dedupTree(trees.source, trees.dest, (int sourceDir, int destDir, const(char)* name, ulong size,
		ref ulong bytesDeduped) {
		bytesDeduped += 2;
		throw new Exception("Later extent differs");
	});

	assert(summary.filesSkipped == 1);
	assert(summary.filesDeduped == 0);
	assert(summary.bytesDeduped == 2);
	assert(summary.abortReason.length == 0);
}

unittest // Both roots can be reached through symlinked ancestors.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	trees.writePair("file", "data");

	auto aliasPath = buildPath(trees.root, "linked-parent");
	assert(symlink(".", aliasPath.toStringz) == 0);
	auto summary = dedupTree(buildPath(aliasPath, "source"), buildPath(aliasPath, "dest"),
		(int sourceDir, int destDir, const(char)* name, ulong size, ref ulong bytesDeduped) {
			assert(readLink("/proc/self/fd/" ~ sourceDir.to!string) == trees.source);
			assert(readLink("/proc/self/fd/" ~ destDir.to!string) == trees.dest);
			bytesDeduped += size;
		});

	assert(summary.filesDeduped == 1);
	assert(summary.bytesDeduped == 4);
	assert(summary.filesSkipped == 0);
	assert(summary.abortReason.length == 0);
}

unittest // Unsupported filesystems stop the pass, including across nested directories.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	foreach (subdir; ["a", "b"])
	{
		mkdir(buildPath(trees.source, subdir));
		mkdir(buildPath(trees.dest, subdir));
		trees.writePair(buildPath(subdir, "file"), "data");
	}

	foreach (error; [EOPNOTSUPP, ENOTTY, EXDEV])
	{
		size_t calls;
		auto summary = dedupTree(trees.source, trees.dest,
			(int sourceDir, int destDir, const(char)* name, ulong size, ref ulong bytesDeduped) {
				calls++;
				throw new ErrnoException("x", error);
			});

		assert(calls == 1);
		assert(summary.abortReason.length != 0);
		assert(summary.filesDeduped == 0);
	}
}

unittest // The real ioctl preserves both trees on supported and unsupported filesystems.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	string[string] contents = ["a.txt": "one", "b.txt": "three"];
	foreach (name, data; contents)
		trees.writePair(name, data);

	dedupWorktree(trees.source, trees.dest);
	foreach (name, data; contents)
	{
		assert(readText(buildPath(trees.source, name)) == data);
		assert(readText(buildPath(trees.dest, name)) == data);
	}

	auto summary = dedupTree(trees.source, trees.dest, toDelegate(&dedupeFileExtents));
	assert(summary.abortReason.length != 0 || summary.filesDeduped == 2);
}

unittest // Repeated real passes release their descriptors without garbage collection.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	foreach (root; [trees.source, trees.dest])
		mkdir(buildPath(root, "sub"));
	trees.writePair(buildPath("sub", "file"), "data");

	GC.disable();
	scope(exit) GC.enable();
	auto before = dirEntries("/proc/self/fd", SpanMode.shallow).walkLength;
	foreach (pass; 0 .. 5)
		dedupWorktree(trees.source, trees.dest);
	auto after = dirEntries("/proc/self/fd", SpanMode.shallow).walkLength;
	assert(after == before);
}

unittest // A missing destination is handled at the pass boundary.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	rmdir(trees.dest);

	dedupWorktree(trees.source, trees.dest);
}

unittest // A candidate replaced by a symlink is skipped.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	trees.writePair("file", "data");
	write(buildPath(trees.dest, "target"), "data");

	auto summary = dedupTree(trees.source, trees.dest, (int sourceDir, int destDir, const(char)* name, ulong size,
		ref ulong bytesDeduped) {
		auto candidate = buildPath(trees.dest, name.fromStringz);
		remove(candidate);
		assert(symlink("target", candidate.toStringz) == 0);
		dedupeFileExtents(sourceDir, destDir, name, size, bytesDeduped);
	});

	assert(summary.filesSkipped == 1);
	assert(summary.filesDeduped == 0);
	assert(summary.abortReason.length == 0);
}

unittest // A candidate replaced by a FIFO is skipped without waiting for a writer.
{
	auto trees = DedupTestTrees.create();
	scope(exit) rmdirRecurse(trees.root);
	trees.writePair("file", "data");

	auto summary = dedupTree(trees.source, trees.dest, (int sourceDir, int destDir, const(char)* name, ulong size,
		ref ulong bytesDeduped) {
		auto candidate = buildPath(trees.dest, name.fromStringz);
		remove(candidate);
		assert(mkfifo(candidate.toStringz, S_IRUSR | S_IWUSR) == 0);

		// A blocking open of this FIFO would otherwise hang the test suite.
		alarm(5);
		scope(exit) alarm(0);
		dedupeFileExtents(sourceDir, destDir, name, size, bytesDeduped);
	});

	assert(summary.filesSkipped == 1);
	assert(summary.filesDeduped == 0);
	assert(summary.abortReason.length == 0);
}
