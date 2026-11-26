module cydo.runtime.storage.disk_usage_test;

version (unittest)
{
    import cydo.runtime.storage.disk_usage;
    import std.algorithm : canFind;
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    private DiskEntry diskEntry(DiskCategory category, string path, long bytes,
        ulong device = 1, ulong inode = 0)
    {
        DiskEntry entry;
        entry.category = category;
        entry.relativePath = path;
        entry.absolutePath = "/task/" ~ path;
        entry.apparentBytes = bytes;
        entry.device = device;
        entry.inode = inode;
        return entry;
    }

    private struct DiskFixture
    {
        string root;

        this(string name)
        {
            root = buildPath(tempDir(), "cydo-disk-" ~ name ~ "-" ~ randomUUID().toString());
            mkdirRecurse(root);
        }

        ~this()
        {
            rmdirRecurse(root);
        }
    }
}

// Git's NUL records may contain whitespace in paths, and gitlinks have no
// blob size to subtract.
unittest
{
    auto blobs = parseLsTreeBlobs(
        "100644 blob 0123456789abcdef       12\tspace name\0" ~
        "100644 blob 0123456789abcdef 7\ttab\tand\nline\0" ~
        "160000 commit 0123456789abcdef       -\tsubmodule\0");
    assert(blobs.length == 2);
    assert(blobs["space name"] == 12);
    assert(blobs["tab\tand\nline"] == 7);
}

// Baseline paths with no current entry must remain signed and offset growth.
unittest
{
    DiskScanInput input;
    input.taskDir = "/task";
    input.temporaryDir = "/tmp/task";
    input.forkWorktree = "/task/fork";
    input.forkBaseSha = "base";

    long[string] baseline;
    baseline["old"] = 20;
    baseline["grown"] = 5;
    auto entries = [
        diskEntry(DiskCategory.task, "fork/grown", 15, 1, 1),
        diskEntry(DiskCategory.task, "new", 4, 1, 2),
        diskEntry(DiskCategory.temporary, "cache", 3, 1, 3),
    ];
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.taskBytes == -6);
    assert(result.temporaryBytes == 3);
    assert(result.totalBytes == -3);
}

// One physical file is charged once across the two owned categories.
unittest
{
    DiskScanInput input;
    input.taskDir = "/task";
    input.temporaryDir = "/tmp/task";
    auto entries = [
        diskEntry(DiskCategory.task, "first", 11, 7, 42),
        diskEntry(DiskCategory.temporary, "alias", 11, 7, 42),
    ];
    long[string] baseline;
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.taskBytes == 11);
    assert(result.temporaryBytes == 0);
    assert(result.totalBytes == 11);
}

// Candidates are positive signed subtrees, ranked deterministically, and
// must not list both an ancestor and its descendant.
unittest
{
    DiskScanInput input;
    input.taskDir = "/task";
    input.temporaryDir = "/tmp/task";
    auto entries = [
        diskEntry(DiskCategory.task, "dir/a", 20, 1, 1),
        diskEntry(DiskCategory.task, "dir/b", 5, 1, 2),
        diskEntry(DiskCategory.task, "other", 10, 1, 3),
    ];
    long[string] baseline;
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.topPaths.length >= 2);
    assert(result.topPaths[0].relativePath == "dir");
    assert(result.topPaths[0].bytes == 25);
    assert(result.topPaths[1].relativePath == "other");
    assert(result.topPaths[1].bytes == 10);
}

// A deleted tracked child reduces its ancestor's rank, rather than being
// omitted when positive candidates are selected.
unittest
{
    DiskScanInput input;
    input.taskDir = "/task";
    input.forkWorktree = "/task/fork";
    input.forkBaseSha = "base";
    auto entries = [
        diskEntry(DiskCategory.task, "fork/dir/new", 20, 1, 1),
        diskEntry(DiskCategory.task, "sibling", 15, 1, 2),
    ];
    long[string] baseline;
    baseline["dir/deleted"] = 10;
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.taskBytes == 25);
    assert(result.topPaths.length >= 1);
    assert(result.topPaths[0].relativePath == "fork/dir/new");
    assert(result.topPaths[1].relativePath == "sibling");
    foreach (path; result.topPaths)
        assert(path.relativePath != "fork/dir");
}

// Directory inode sizes are excluded; sparse files use apparent st_size.
unittest
{
    import core.sys.posix.fcntl : O_CREAT, O_WRONLY, open;
    import core.sys.posix.unistd : close, ftruncate;
    import std.string : toStringz;

    DiskFixture fixture = DiskFixture("sparse");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(buildPath(task, "nested"));
    mkdirRecurse(temporary);
    write(buildPath(task, "nested", "file"), "abc");
    write(buildPath(temporary, "cache"), "12345");
    auto sparse = buildPath(task, "nested", "sparse");
    auto fd = open(sparse.toStringz, O_CREAT | O_WRONLY, 420);
    assert(fd >= 0);
    assert(ftruncate(fd, 1_048_576) == 0);
    close(fd);

    DiskScanInput input;
    input.taskDir = task;
    input.temporaryDir = temporary;
    auto result = measureDiskUsage(input);
    assert(result.taskBytes == 1_048_579);
    assert(result.temporaryBytes == 5);
    assert(result.totalBytes == 1_048_584);
}

// Only new top-level shared entries count, including their nested contents.
unittest
{
    import cydo.runtime.launch.sandbox_materialization : taskTmpHostPath, tmpRuntimeDirName;
    import std.file : symlink;

    DiskFixture fixture = DiskFixture("shared-tmp");
    auto task = buildPath(fixture.root, "task");
    auto sharedTmp = buildPath(fixture.root, "shared");
    auto temporary = taskTmpHostPath(sharedTmp, 1);
    auto siblingTmp = taskTmpHostPath(sharedTmp, 2);
    auto runtime = buildPath(sharedTmp, tmpRuntimeDirName());
    auto oldDir = buildPath(sharedTmp, "old-dir");
    mkdirRecurse(task);
    mkdirRecurse(oldDir);
    write(buildPath(sharedTmp, "old-file"), "old");

    auto baseline = snapshotSharedTmp(sharedTmp);

    auto nested = buildPath(sharedTmp, "new-dir", "nested");
    mkdirRecurse(nested);
    write(buildPath(nested, "new-file"), "123456789");
    symlink("missing", buildPath(sharedTmp, "new-link"));
    write(buildPath(oldDir, "new-file"), "ignored");
    write(buildPath(sharedTmp, "old-file"), "still ignored after rewriting");

    foreach (dir; [temporary, siblingTmp, runtime])
    {
        mkdirRecurse(dir);
        write(buildPath(dir, "scratch"), "12345");
    }
    // Similar names outside the reserved directories still count.
    auto runtimeLookalike = tmpRuntimeDirName() ~ "-notes";
    foreach (name; [runtimeLookalike, "cydo-task-notes", "cydo-task-01",
        "cydo-task--1", "cydo-task-2147483648"])
    {
        auto dir = buildPath(sharedTmp, name);
        mkdirRecurse(dir);
        write(buildPath(dir, "file"), "123");
    }

    auto result = measureDiskUsage(DiskScanInput(task, temporary,
        sharedTmpDir: sharedTmp, sharedBaseline: baseline));
    assert(result.temporaryBytes == 5);
    assert(result.sharedTemporaryBytes == 31);
    assert(result.totalBytes == 36);
    assert(result.topPaths == [
        DiskTopPath(DiskCategory.sharedTemporary, "new-dir", 9),
        DiskTopPath(DiskCategory.sharedTemporary, "new-link", 7),
        DiskTopPath(DiskCategory.temporary, "scratch", 5),
        DiskTopPath(DiskCategory.sharedTemporary, runtimeLookalike, 3),
        DiskTopPath(DiskCategory.sharedTemporary, "cydo-task--1", 3),
        DiskTopPath(DiskCategory.sharedTemporary, "cydo-task-01", 3),
        DiskTopPath(DiskCategory.sharedTemporary, "cydo-task-2147483648", 3),
        DiskTopPath(DiskCategory.sharedTemporary, "cydo-task-notes", 3),
    ]);
    assert(result.symlinks == [
        DiskSymlink(buildPath(sharedTmp, "new-link"), "missing", "new-link"),
    ]);
}

unittest
{
    import std.exception : collectException;

    auto error = collectException(measureDiskUsage(DiskScanInput("/task", "/task/tmp",
        sharedTmpDir: "/shared")));
    assert(error !is null);
    assert(error.msg.canFind("requires a launch baseline: /shared"));
}

// An entry created immediately after the launch snapshot counts.
unittest
{
    DiskFixture fixture = DiskFixture("shared-tmp-launch-boundary");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    auto sharedTmp = buildPath(fixture.root, "shared");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    mkdirRecurse(sharedTmp);

    auto baseline = snapshotSharedTmp(sharedTmp);
    write(buildPath(sharedTmp, "immediate"), "123");
    auto result = measureDiskUsage(DiskScanInput(task, temporary,
        sharedTmpDir: sharedTmp, sharedBaseline: baseline));
    assert(result.sharedTemporaryBytes == 3);
}

// Replacements count at their new sizes, while renaming an old entry leaves it excluded.
unittest
{
    import std.file : remove, rename;
    import std.stdio : File;

    DiskFixture fixture = DiskFixture("shared-tmp-replacements");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    auto sharedTmp = buildPath(fixture.root, "shared");
    auto replaced = buildPath(sharedTmp, "replaced");
    auto renamed = buildPath(sharedTmp, "renamed-src");
    auto overwritten = buildPath(sharedTmp, "overwritten");
    auto incoming = buildPath(sharedTmp, "incoming");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    mkdirRecurse(sharedTmp);
    write(replaced, "old");
    write(renamed, "stay excluded");
    write(overwritten, "old");
    auto baseline = snapshotSharedTmp(sharedTmp);

    // Keep the unlinked inode alive so filesystem inode reuse cannot make the
    // fixture depend on birth-time precision.
    auto oldFile = File(replaced, "rb");
    remove(replaced);
    write(replaced, "123456789");
    rename(renamed, buildPath(sharedTmp, "renamed-dst"));
    write(incoming, "12345");
    rename(incoming, overwritten);

    auto result = measureDiskUsage(DiskScanInput(task, temporary,
        sharedTmpDir: sharedTmp, sharedBaseline: baseline));
    assert(result.sharedTemporaryBytes == 14);
    assert(result.topPaths == [
        DiskTopPath(DiskCategory.sharedTemporary, "replaced", 9),
        DiskTopPath(DiskCategory.sharedTemporary, "overwritten", 5),
    ]);
}

unittest
{
    import core.stdc.errno : EACCES;
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : geteuid;
    import std.file : FileException;
    import std.string : toStringz;

    DiskFixture fixture = DiskFixture("shared-tmp-blocked");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    auto sharedTmp = buildPath(fixture.root, "shared");
    auto blocked = buildPath(sharedTmp, "blocked");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    mkdirRecurse(sharedTmp);
    auto baseline = snapshotSharedTmp(sharedTmp);
    mkdirRecurse(blocked);
    write(buildPath(blocked, "hidden"), "unmeasured");
    write(buildPath(sharedTmp, "readable"), "123");

    auto input = DiskScanInput(task, temporary,
        sharedTmpDir: sharedTmp, sharedBaseline: baseline);
    assert(chmod(blocked.toStringz, 0) == 0);
    scope (exit) assert(chmod(blocked.toStringz, 448) == 0);
    auto result = geteuid() == 0
        ? measureDiskUsage(input, (string dir) {
            if (dir == blocked) throw new FileException(dir, EACCES);
            return listDirectory(dir);
        })
        : measureDiskUsage(input);
    assert(result.sharedTemporaryBytes == 3);
    assert(result.unmeasured.length == 1);
    assert(result.unmeasured[0].category == DiskCategory.sharedTemporary);
    assert(result.unmeasured[0].relativePath == "blocked");
}

// Root overlap counts each path once, and ranking keeps ten disjoint paths.
unittest
{
    auto input = DiskScanInput("/task", "/task/tmp");
    DiskEntry[] entries;
    foreach (i; 0 .. 12)
    {
        auto path = "item" ~ i.to!string;
        entries ~= diskEntry(DiskCategory.task, path, 1, 1, i + 1);
    }
    auto duplicate = diskEntry(DiskCategory.temporary, "copy", 10, 2, 99);
    duplicate.absolutePath = "/task/item0";
    entries ~= duplicate;
    long[string] baseline;
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.taskBytes == 12);
    assert(result.temporaryBytes == 0);
    assert(result.topPaths.length == 10);
    auto order = ["item0", "item1", "item10", "item11", "item2",
        "item3", "item4", "item5", "item6", "item7"];
    foreach (i, path; order)
        assert(result.topPaths[i].relativePath == path);
    auto taskTie = diskEntry(DiskCategory.task, "tie", 1, 3, 100);
    auto tempTie = diskEntry(DiskCategory.temporary, "tie", 1, 4, 101);
    tempTie.absolutePath = "/task/tmp/tie";
    auto withTie = aggregateDiskUsage(input, [tempTie, taskTie], baseline);
    assert(withTie.topPaths.length == 2);
    assert(withTie.topPaths[0].category == DiskCategory.task);
    assert(withTie.topPaths[1].category == DiskCategory.temporary);
}

// A supplied fork base remains authoritative after the child commits again.
unittest
{
    import std.process : execute;
    import std.file : getSize, remove, symlink;
    import std.string : strip;

    DiskFixture fixture = DiskFixture("git-base");
    auto task = buildPath(fixture.root, "task");
    auto repo = buildPath(task, "repo");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(repo);
    mkdirRecurse(temporary);
    assert(execute(["git", "init", "-q", "--separate-git-dir",
        buildPath(fixture.root, "git-metadata"), repo]).status == 0);
    write(buildPath(repo, "same"), "abc");
    write(buildPath(repo, "grow"), "abc");
    write(buildPath(repo, "delete"), "abcdef");
    symlink("same", buildPath(repo, "link"));
    assert(execute(["git", "-C", repo, "add", "."]).status == 0);
    assert(execute(["git", "-C", repo, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;
    auto input = DiskScanInput(task, temporary, repo, base,
        buildPath(fixture.root, "git-metadata"));
    auto pointerBytes = cast(long) getSize(buildPath(repo, ".git"));
    // Base checkout: unchanged blobs and the tracked link net to zero.
    auto unchanged = measureDiskUsage(input);
    assert(unchanged.taskBytes == pointerBytes);
    assert(unchanged.topPaths.length == 1);
    assert(unchanged.topPaths[0].relativePath == "repo");
    assert(unchanged.topPaths[0].bytes == pointerBytes);
    assert(unchanged.symlinks.length == 1);
    assert(unchanged.symlinks[0].rawTarget == "same");
    // A same-size edit has zero delta.
    write(buildPath(repo, "same"), "xyz");
    assert(measureDiskUsage(input).taskBytes == pointerBytes);
    // Growth charges only the four added apparent bytes.
    write(buildPath(repo, "grow"), "abcdefg");
    assert(measureDiskUsage(input).taskBytes == pointerBytes + 4);
    // Deleting a tracked six-byte blob subtracts six.
    remove(buildPath(repo, "delete"));
    assert(measureDiskUsage(input).taskBytes == pointerBytes - 2);
    // An untracked five-byte file counts fully.
    write(buildPath(repo, "new"), "12345");
    assert(measureDiskUsage(input).taskBytes == pointerBytes + 3);
    assert(execute(["git", "-C", repo, "add", "."]).status == 0);
    assert(execute(["git", "-C", repo, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "child"]).status == 0);
    // Moving child HEAD does not replace the supplied fork-base SHA.
    auto afterCommit = measureDiskUsage(input);
    assert(afterCommit.taskBytes == pointerBytes + 3);
    assert(afterCommit.symlinks.length == 1);
    assert(afterCommit.symlinks[0].rawTarget == "same");
    // Supplying child HEAD explicitly makes the edited tree the baseline.
    input.forkBaseSha = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;
    assert(measureDiskUsage(input).taskBytes == pointerBytes);
}

// Link target text is charged, while linked targets are never traversed.
unittest
{
    import std.file : symlink;
    import core.sys.posix.unistd : link;
    import std.string : toStringz;

    DiskFixture fixture = DiskFixture("links");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    auto source = buildPath(task, "file");
    write(source, "1234567");
    assert(link(source.toStringz, buildPath(temporary, "hard").toStringz) == 0);
    assert(link(source.toStringz, buildPath(task, "hard2").toStringz) == 0);
    symlink("missing-target", buildPath(task, "dangling"));
    symlink(source, buildPath(temporary, "external"));
    auto result = measureDiskUsage(DiskScanInput(task, temporary));
    assert(result.taskBytes == 7 + "missing-target".length);
    assert(result.temporaryBytes == source.length);
    assert(result.symlinks.length == 2);
    assert(result.symlinks[0].linkPath == buildPath(task, "dangling"));
    assert(result.symlinks[0].rawTarget == "missing-target");
    assert(result.symlinks[1].linkPath == buildPath(temporary, "external"));
    assert(result.symlinks[1].rawTarget == source);
}

// Addition must reject overflow instead of wrapping a threshold-ready total.
unittest
{
    auto input = DiskScanInput("/task", "/tmp/task");
    auto entries = [diskEntry(DiskCategory.task, "a", long.max, 1, 1),
        diskEntry(DiskCategory.task, "b", 1, 1, 2)];
    long[string] baseline;
    bool threw;
    try aggregateDiskUsage(input, entries, baseline);
    catch (Exception) threw = true;
    assert(threw);
}

unittest
{
    auto input = DiskScanInput("/task", "/tmp/task", "/task/fork", "");
    bool threw;
    try measureDiskUsage(input);
    catch (Exception e)
    {
        assert(e.msg.canFind("/task/fork"));
        threw = true;
    }
    assert(threw);
}

unittest
{
    auto input = DiskScanInput("/task", "/tmp/task", "/elsewhere/fork", "base");
    long[string] baseline;
    baseline["file"] = 2;
    bool threw;
    try aggregateDiskUsage(input, [], baseline);
    catch (Exception e)
    {
        assert(e.msg.canFind("/elsewhere/fork"));
        assert(e.msg.canFind("/task"));
        threw = true;
    }
    assert(threw);
}

// A missing task or temporary root is a failed scan, not a zero report.
unittest
{
    DiskFixture fixture = DiskFixture("missing-root");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(task);
    foreach (missingTask; [false, true])
    {
        if (missingTask)
        {
            mkdirRecurse(temporary);
            rmdirRecurse(task);
        }
        auto input = DiskScanInput(task, temporary);
        bool threw;
        try measureDiskUsage(input);
        catch (Exception e)
        {
            assert(e.msg.canFind(missingTask ? task : temporary));
            threw = true;
        }
        assert(threw);
    }
}

// Non-normalized roots would break fork-relative baseline matching.
unittest
{
    import std.path : baseName;

    DiskFixture fixture = DiskFixture("trailing-fork");
    auto task = buildPath(fixture.root, "task");
    auto fork = buildPath(task, "fork");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(fork);
    mkdirRecurse(temporary);
    foreach (badRoot; [fork ~ "/", task ~ "/.",
        task ~ "/../" ~ baseName(task), "relative/task"])
    {
        auto input = badRoot == fork ~ "/"
            ? DiskScanInput(task, temporary, badRoot, "base")
            : DiskScanInput(badRoot, temporary);
        bool threw;
        try measureDiskUsage(input);
        catch (Exception e)
        {
            assert(e.msg.canFind(badRoot));
            threw = true;
        }
        assert(threw);
    }
}

// A root disappearing between lstat and listing rejects with its path.
unittest
{
    DiskFixture fixture = DiskFixture("vanishing-root");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    string[] delegate(string) vanish = (string dir) {
        if (dir == task) rmdirRecurse(task);
        return listDirectory(dir);
    };
    bool threw;
    try measureDiskUsage(DiskScanInput(task, temporary), vanish);
    catch (Exception e)
    {
        assert(e.msg.canFind(task));
        threw = true;
    }
    assert(threw);
}

// A shared entry can disappear before statx or after its metadata was read.
unittest
{
    import std.file : remove;

    DiskFixture fixture = DiskFixture("vanishing-shared-entries");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    auto sharedTmp = buildPath(fixture.root, "shared");
    auto missing = buildPath(sharedTmp, "file");
    auto vanishing = buildPath(sharedTmp, "dir");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    mkdirRecurse(sharedTmp);
    auto baseline = snapshotSharedTmp(sharedTmp);
    mkdirRecurse(vanishing);
    write(buildPath(vanishing, "hidden"), "discarded");
    write(missing, "discarded");
    write(buildPath(sharedTmp, "retained"), "123");

    auto result = measureDiskUsage(DiskScanInput(task, temporary,
        sharedTmpDir: sharedTmp, sharedBaseline: baseline), (string dir) {
        if (dir == vanishing)
            rmdirRecurse(vanishing);
        auto children = listDirectory(dir);
        if (dir == sharedTmp)
            remove(missing);
        return children;
    });
    assert(result.sharedTemporaryBytes == 3);
    assert(result.unmeasured.length == 0);
}

// Tracked hardlinks charge the first inode once but subtract both blobs.
unittest
{
    auto input = DiskScanInput("/task", "/tmp/task", "/task/fork", "base");
    long[string] baseline;
    baseline["a"] = 10;
    baseline["b"] = 10;
    auto result = aggregateDiskUsage(input,
        [diskEntry(DiskCategory.task, "fork/a", 10, 3, 7),
         diskEntry(DiskCategory.task, "fork/b", 10, 3, 7)], baseline);
    assert(result.taskBytes == -10);
    assert(result.totalBytes == -10);
    assert(result.topPaths.length == 0);
}

// A: linked worktree baseline excludes the project checkout.
unittest
{
    import std.file : getSize;
    import std.process : execute;
    import std.string : strip;

    DiskFixture fixture = DiskFixture("linked-worktree");
    auto repo = buildPath(fixture.root, "project");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    auto fork = buildPath(task, "fork");
    mkdirRecurse(repo);
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    assert(execute(["git", "-C", repo, "init", "-q"]).status == 0);
    write(buildPath(repo, "one"), "abc");
    write(buildPath(repo, "two"), "12345");
    assert(execute(["git", "-C", repo, "add", "."]).status == 0);
    assert(execute(["git", "-C", repo, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;
    assert(execute(["git", "-C", repo, "worktree", "add", "-q", fork, "HEAD"]).status == 0);
    write(buildPath(repo, "large-untracked"), new char[1_000_000]);
    auto result = measureDiskUsage(DiskScanInput(task, temporary, fork, base, repo));
    assert(result.taskBytes == getSize(buildPath(fork, ".git")));
    assert(result.temporaryBytes == 0);
    assert(result.topPaths.length == 1);
    assert(result.topPaths[0].relativePath == "fork");
}

// C: gitlinks have no blob baseline; live submodule files count fully.
unittest
{
    auto input = DiskScanInput("/task", "/tmp/task", "/task/fork", "base");
    auto baseline = parseLsTreeBlobs(
        "160000 commit 0123456789abcdef -\tsub\0" ~
        "100644 blob 0123456789abcdef 3\tunchanged\0" ~
        "100644 blob 0123456789abcdef 1\tremoved\0");
    auto entries = [diskEntry(DiskCategory.task, "fork/sub/a", 4, 1, 1),
        diskEntry(DiskCategory.task, "fork/sub/b", 6, 1, 2),
        diskEntry(DiskCategory.task, "fork/unchanged", 3, 1, 3)];
    auto result = aggregateDiskUsage(input, entries, baseline);
    assert(result.taskBytes == 9);
    assert(result.topPaths[0].relativePath == "fork/sub");
    assert(result.topPaths[0].bytes == 10);
}

// E: a deleted ancestor carries its negative baseline into the total.
unittest
{
    auto input = DiskScanInput("/task", "/tmp/task", "/task/fork", "base");
    long[string] baseline;
    baseline["gone/a"] = 5;
    baseline["gone/b"] = 7;
    auto result = aggregateDiskUsage(input,
        [diskEntry(DiskCategory.task, "keep", 3, 1, 1)], baseline);
    assert(result.taskBytes == -9);
    assert(result.totalBytes == -9);
    assert(result.topPaths.length == 1);
    assert(result.topPaths[0].relativePath == "keep");
    assert(result.topPaths[0].bytes == 3);
}

// G: a child vanished after listing leaves its tracked baseline negative.
unittest
{
    import std.file : dirEntries, getSize, remove, SpanMode;
    import std.process : execute;
    import std.string : strip;

    DiskFixture fixture = DiskFixture("vanished");
    auto task = buildPath(fixture.root, "task");
    auto fork = buildPath(task, "fork");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(fork);
    mkdirRecurse(temporary);
    assert(execute(["git", "init", "-q", "--separate-git-dir",
        buildPath(fixture.root, "git-metadata"), fork]).status == 0);
    write(buildPath(fork, "vanished"), "12345");
    assert(execute(["git", "-C", fork, "add", "."]).status == 0);
    assert(execute(["git", "-C", fork, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", fork, "rev-parse", "HEAD"]).output.strip;
    remove(buildPath(fork, "vanished"));
    write(buildPath(fork, "real"), "abc");
    string[] delegate(string) list = (string dir) {
        string[] paths;
        foreach (child; dirEntries(dir, SpanMode.shallow)) paths ~= child.name;
        if (dir == fork) paths ~= buildPath(fork, "vanished");
        return paths;
    };
    auto result = measureDiskUsage(DiskScanInput(task, temporary, fork, base,
        buildPath(fixture.root, "git-metadata")), list);
    assert(result.taskBytes == getSize(buildPath(fork, ".git")) - 2);
}

// A blocked subtree is reported without losing the bytes from readable siblings.
unittest
{
    import core.stdc.errno : EACCES;
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : geteuid;
    import std.file : FileException;
    import std.string : toStringz;

    DiskFixture fixture = DiskFixture("unreadable-subtree");
    auto task = buildPath(fixture.root, "task");
    auto blocked = buildPath(task, "nested", "blocked");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(blocked);
    mkdirRecurse(temporary);
    write(buildPath(blocked, "hidden"), "unmeasured bytes");
    write(buildPath(task, "nested", "sibling"), "12345");
    auto input = DiskScanInput(task, temporary);
    void check(DiskUsageResult result)
    {
        assert(result.taskBytes == 5);
        assert(result.totalBytes == 5);
        assert(result.unmeasured.length == 1);
        assert(result.unmeasured[0].category == DiskCategory.task);
        assert(result.unmeasured[0].relativePath == "nested/blocked");
        assert(result.unmeasured[0].error.length != 0);
    }

    if (geteuid() == 0)
    {
        check(measureDiskUsage(input, (string dir) {
            if (dir == blocked) throw new FileException(dir, EACCES);
            return listDirectory(dir);
        }));
        return;
    }
    foreach (mode; [0, 64, 256]) // 0000, 0100, 0400
    {
        assert(chmod(blocked.toStringz, mode) == 0);
        scope (exit) assert(chmod(blocked.toStringz, 448) == 0);
        check(measureDiskUsage(input));
    }
}

// An unreadable or unsearchable scan root still fails the scan.
unittest
{
    import core.stdc.errno : EACCES;
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : geteuid;
    import std.exception : collectException;
    import std.file : FileException;
    import std.string : toStringz;

    DiskFixture fixture = DiskFixture("unreadable-root");
    auto task = buildPath(fixture.root, "task");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    write(buildPath(task, "file"), "task bytes");
    write(buildPath(temporary, "file"), "temporary bytes");
    auto input = DiskScanInput(task, temporary);

    if (geteuid() == 0)
    {
        auto failure = collectException(measureDiskUsage(input, (string dir) {
            if (dir == task) throw new FileException(dir, EACCES);
            return listDirectory(dir);
        }));
        assert(failure && failure.msg.canFind(task));
        return;
    }

    foreach (path; [task, temporary])
        foreach (mode; [0, 256]) // 0000, 0400
        {
            assert(chmod(path.toStringz, mode) == 0);
            scope (exit) assert(chmod(path.toStringz, 448) == 0);
            auto failure = collectException(measureDiskUsage(input));
            assert(failure && failure.msg.canFind(path));
        }
}

// A blocked tracked subtree has zero delta, while a deleted sibling still subtracts.
unittest
{
    import core.stdc.errno : EACCES;
    import std.file : FileException, remove;
    import std.process : execute;
    import std.string : strip;

    DiskFixture fixture = DiskFixture("unreadable-baseline");
    auto task = buildPath(fixture.root, "task");
    auto fork = buildPath(task, "fork");
    auto temporary = buildPath(fixture.root, "tmp");
    auto blocked = buildPath(fork, "foo");
    auto deleted = buildPath(fork, "foobar");
    mkdirRecurse(blocked);
    mkdirRecurse(temporary);
    assert(execute(["git", "init", "-q", "--separate-git-dir",
        buildPath(fixture.root, "git-metadata"), fork]).status == 0);
    write(buildPath(blocked, "tracked"), new ubyte[1000]);
    write(deleted, "12345");
    assert(execute(["git", "-C", fork, "add", "."]).status == 0);
    assert(execute(["git", "-C", fork, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", fork, "rev-parse", "HEAD"]).output.strip;
    auto input = DiskScanInput(task, temporary, fork, base,
        buildPath(fixture.root, "git-metadata"));
    auto readable = measureDiskUsage(input);
    string[] delegate(string) list = (string dir) {
        if (dir == blocked) throw new FileException(dir, EACCES);
        return listDirectory(dir);
    };
    auto unreadable = measureDiskUsage(input, list);
    assert(unreadable.totalBytes == readable.totalBytes);
    assert(unreadable.topPaths == readable.topPaths);
    assert(unreadable.unmeasured.length == 1);

    remove(deleted);
    auto afterDeletion = measureDiskUsage(input, list);
    assert(afterDeletion.totalBytes == readable.totalBytes - 5);
    assert(afterDeletion.topPaths.length == 1);
    assert(afterDeletion.topPaths[0].relativePath == "fork/.git");
    assert(afterDeletion.topPaths[0].bytes == readable.topPaths[0].bytes);
}

// The baseline comes from the project even when the linked fork is blocked.
unittest
{
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : geteuid;
    import std.exception : assertThrown, collectException;
    import std.file : remove;
    import std.process : execute;
    import std.string : strip, toStringz;

    DiskFixture fixture = DiskFixture("blocked-fork-baseline");
    auto project = buildPath(fixture.root, "project");
    auto task = buildPath(fixture.root, "task");
    auto fork = buildPath(task, "fork");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(project);
    mkdirRecurse(task);
    mkdirRecurse(temporary);
    assert(execute(["git", "-C", project, "init", "-q"]).status == 0);
    write(buildPath(project, "tracked"), new ubyte[1000]);
    write(buildPath(project, "deleted"), new ubyte[500]);
    assert(execute(["git", "-C", project, "add", "."]).status == 0);
    assert(execute(["git", "-C", project, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", project, "rev-parse", "HEAD"]).output.strip;
    assert(execute(["git", "-C", project, "worktree", "add", "-q", "--detach", fork]).status == 0);
    remove(buildPath(fork, "deleted"));
    write(buildPath(task, "sibling"), "12345");

    auto input = DiskScanInput(task, temporary, fork, base, project);
    auto invalid = input;
    invalid.forkBaseSha = "invalid-revision";
    auto badRevision = collectException(measureDiskUsage(invalid));
    assert(badRevision && badRevision.msg.canFind(fork));
    auto invalidRepository = input;
    invalidRepository.forkRepository = buildPath(fixture.root, "no-such-repo");
    assertThrown(measureDiskUsage(invalidRepository));
    invalidRepository.forkRepository = "";
    auto emptyRepository = collectException(measureDiskUsage(invalidRepository));
    assert(emptyRepository && emptyRepository.msg.canFind("Cannot resolve fork repository"));

    auto readable = measureDiskUsage(input);
    assert(readable.unmeasured.length == 0);
    if (geteuid() == 0) return;
    foreach (mode; [0, 256]) // 0000, 0400
    {
        assert(chmod(fork.toStringz, mode) == 0);
        scope (exit) assert(chmod(fork.toStringz, 448) == 0);

        auto result = measureDiskUsage(input);
        assert(result.totalBytes == 5);
        assert(result.topPaths == [DiskTopPath(DiskCategory.task, "sibling", 5)]);
        assert(result.unmeasured.length == 1);
        assert(result.unmeasured[0].category == DiskCategory.task);
        assert(result.unmeasured[0].relativePath == "fork");
    }
    auto pointer = buildPath(fork, ".git");
    {
        assert(chmod(pointer.toStringz, 0) == 0);
        scope (exit) assert(chmod(pointer.toStringz, 384) == 0);
        assert(measureDiskUsage(input) == readable);
    }
    auto metadata = buildPath(project, ".git", "worktrees", "fork");
    assert(chmod(metadata.toStringz, 0) == 0);
    scope (exit) assert(chmod(metadata.toStringz, 448) == 0);
    assert(measureDiskUsage(input) == readable);
}

// Task-owned worktree metadata is measured by the walk alone.
unittest
{
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : geteuid;
    import std.process : execute;
    import std.string : strip, toStringz;

    if (geteuid() == 0) return;
    DiskFixture fixture = DiskFixture("blocked-worktree-metadata");
    auto task = buildPath(fixture.root, "task");
    auto primary = buildPath(task, "primary");
    auto fork = buildPath(task, "fork");
    auto temporary = buildPath(fixture.root, "tmp");
    mkdirRecurse(primary);
    mkdirRecurse(temporary);
    assert(execute(["git", "-C", primary, "init", "-q"]).status == 0);
    write(buildPath(primary, "tracked"), "base");
    assert(execute(["git", "-C", primary, "add", "."]).status == 0);
    assert(execute(["git", "-C", primary, "-c", "user.name=CyDo",
        "-c", "user.email=cydo@example.test", "commit", "-qm", "base"]).status == 0);
    auto base = execute(["git", "-C", primary, "rev-parse", "HEAD"]).output.strip;
    assert(execute(["git", "-C", primary, "worktree", "add", "-q", "--detach", fork]).status == 0);
    write(buildPath(temporary, "sibling"), "abc");

    auto metadata = buildPath(primary, ".git", "worktrees", "fork");
    assert(chmod(metadata.toStringz, 0) == 0);
    scope (exit) assert(chmod(metadata.toStringz, 448) == 0);
    auto result = measureDiskUsage(DiskScanInput(task, temporary, fork, base, primary));
    assert(result.temporaryBytes == 3);
    assert(result.unmeasured.length == 1);
    assert(result.unmeasured[0].category == DiskCategory.task);
    assert(result.unmeasured[0].relativePath == "primary/.git/worktrees/fork");
}
