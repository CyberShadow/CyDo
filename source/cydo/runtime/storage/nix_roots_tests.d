module cydo.runtime.storage.nix_roots_tests;

version (unittest)
{
    import ae.net.asockets : socketManager;
    import cydo.runtime.storage.disk_usage : DiskScanInput, DiskSymlink, measureDiskUsage;
    import cydo.runtime.storage.nix_roots : NixClosureReport, nixClosureLabel, reportNixClosures;
    import cydo.workflow.sessions.disk_usage : DiskEvaluation, measureDiskUsageAsync;
    import core.sys.posix.sys.stat : chmod;
    import std.algorithm : canFind, startsWith;
    import std.exception : collectExceptionMsg;
    import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse,
        symlink, tempDir, write, readText;
    import std.path : buildPath, dirName, relativePath;
    import std.process : environment;
    import std.string : toStringz;
    import std.uuid : randomUUID;
    import core.time : Duration, MonoTime, seconds;

    private struct Fixture
    {
        string root;
        string executable;

        this(string script)
        {
            root = buildPath(tempDir(), "cydo-nix-roots-" ~ randomUUID().toString());
            mkdirRecurse(root);
            executable = buildPath(root, "fake-nix");
            write(executable, "#!/bin/sh\nfor target do :; done\n" ~ script ~ "\n");
            assert(chmod(executable.toStringz, 493) == 0);
        }

        ~this() { rmdirRecurse(root); }
    }

    private string liveStorePath()
    {
        import ae.sys.file : realPath;
        import cydo.runtime.launch.sandbox_renderer : resolveExecutablePath;
        return realPath(resolveExecutablePath("dub", null));
    }

    private bool skipStore() { return environment.get("CYDO_TEST_SKIP_NIX_STORE", "") == "1"; }

    private NixClosureReport timed(lazy NixClosureReport call,
        Duration limit = 5.seconds)
    {
        auto start = MonoTime.currTime;
        auto result = call;
        assert(MonoTime.currTime - start < limit);
        return result;
    }
}

@("nix roots resolve arbitrary link names and relative targets, then deduplicate") unittest
{
    auto fixture = Fixture("echo \"$target\" >> \"$0.calls\"; printf '{\"%s\":{\"closureSize\":123}}' \"$target\"");
    auto target = liveStorePath();
    auto first = buildPath(fixture.root, "arbitrary package link");
    auto second = buildPath(fixture.root, "another-name");
    symlink(target, first);
    symlink(target, second);
    auto relative = buildPath(fixture.root, "relative");
    auto relativeTarget = relativePath(target, fixture.root);
    symlink(relativeTarget, relative);
    auto links = [DiskSymlink(first, target), DiskSymlink(second, target),
        DiskSymlink(relative, relativeTarget)];
    auto report = reportNixClosures(links, fixture.executable);
    assert(report.entries.length == 1);
    assert(report.entries[0].storePath == target);
    assert(report.entries[0].linkPaths == [first, second, relative]);
    assert(report.entries[0].closureSize == 123);
    assert(nixClosureLabel == "Nix closure references (NAR bytes; may be GC roots)");
    assert(readText(fixture.executable ~ ".calls") == target ~ "\n");
}

@("nix roots ignore non-store targets without invoking nix") unittest
{
    auto fixture = Fixture("exit 99");
    auto ordinary = buildPath(fixture.root, "ordinary");
    write(ordinary, "data");
    auto link = buildPath(fixture.root, "named link");
    symlink("ordinary", link);
    auto report = reportNixClosures([DiskSymlink(link, "ordinary")], fixture.executable);
    assert(report.entries.length == 0);
}


@("nix roots return empty when the optional executable is unavailable") unittest
{
    auto fixture = Fixture("exit 0");
    auto target = liveStorePath();
    auto originalPath = environment.get("PATH", "");
    scope (exit) environment["PATH"] = originalPath;
    environment["PATH"] = fixture.root;
    assert(timed(reportNixClosures([DiskSymlink("/tmp/named", target)])).entries.length == 0);
}

@("nix roots skip unsuccessful commands") unittest
{
    auto target = liveStorePath();
    auto link = DiskSymlink("/tmp/arbitrary-name", target);

    auto unsupported = Fixture("echo \"error: unrecognised flag '--json-format'\" >&2; exit 1");
    assert(timed(reportNixClosures([link], unsupported.executable)).entries.length == 0);
    auto daemon = Fixture("echo 'daemon unavailable' >&2; exit 1");
    assert(timed(reportNixClosures([link], daemon.executable)).entries.length == 0);
    auto timeout = Fixture("trap '' TERM; sleep 2");
    assert(timed(reportNixClosures([link], timeout.executable, 10),
        1.seconds).entries.length == 0);
}

@("nix roots merge distinct targets that share one store path") unittest
{
    auto fixture = Fixture("echo \"$target\" >> \"$0.calls\"; root=$(printf '%s' \"$target\" | cut -d/ -f1-4); printf '{\"%s\":{\"closureSize\":9}}' \"$root\"");
    auto fileTarget = liveStorePath();
    auto directoryTarget = dirName(fileTarget);
    auto storeRoot = dirName(directoryTarget);
    auto fileLink = buildPath(fixture.root, "executable-link");
    auto directoryLink = buildPath(fixture.root, "directory-link");
    symlink(fileTarget, fileLink);
    symlink(directoryTarget, directoryLink);
    auto report = reportNixClosures([
        DiskSymlink(fileLink, fileTarget), DiskSymlink(directoryLink, directoryTarget)],
        fixture.executable);
    assert(readText(fixture.executable ~ ".calls") ==
        fileTarget ~ "\n" ~ directoryTarget ~ "\n");
    assert(report.entries.length == 1);
    assert(report.entries[0].storePath == storeRoot);
    assert(report.entries[0].linkPaths == [fileLink, directoryLink]);
    assert(report.entries[0].closureSize == 9);
}

@("nix roots reject malformed successful responses and ignore JSON null") unittest
{
    auto target = liveStorePath();
    auto link = DiskSymlink("/tmp/arbitrary-name", target);
    foreach (payload; ["garbage", "{}", "[]", "{\"wrong\":{\"closureSize\":1}}",
        "{\"" ~ target ~ "\":{}}", "{\"" ~ target ~ "\":{\"closureSize\":-1}}",
        "{\"" ~ target ~ "\":{\"closureSize\":1.5}}",
        "{\"info\":{\"" ~ target ~ "\":{\"closureSize\":1}}}"])
    {
        auto fixture = Fixture("printf '%s' '" ~ payload ~ "'");
        assert(collectExceptionMsg(reportNixClosures([link], fixture.executable)).canFind(target));
    }
    auto nullFixture = Fixture("printf '{\"%s\":null}' \"$target\"");
    assert(reportNixClosures([link], nullFixture.executable).entries.length == 0);
    auto formatOne = Fixture("printf '{\"%s\":{\"narSize\":7,\"closureSize\":23}}' \"$target\"");
    assert(reportNixClosures([link], formatOne.executable).entries[0].closureSize == 23);
    auto warning = Fixture("echo 'warning: something' >&2; printf '{\"%s\":{\"closureSize\":5}}' \"$target\"");
    auto warned = reportNixClosures([link], warning.executable);
    assert(warned.entries.length == 1);
    assert(warned.entries[0].closureSize == 5);
}

@("disk worker returns owned usage and Nix report together") unittest
{
    import cydo.runtime.storage.nix_roots : NixClosureEntry, NixClosureReport;
    auto fixture = Fixture("exit 0");
    auto task = buildPath(fixture.root, "task");
    mkdirRecurse(task);
    write(buildPath(task, "data"), "abc");
    DiskScanInput input;
    input.taskDir = task;
    input.temporaryDir = buildPath(fixture.root, "temporary");
    mkdirRecurse(input.temporaryDir);
    auto target = liveStorePath();
    auto taskLink = buildPath(task, "build-link");
    auto tempLink = buildPath(input.temporaryDir, "deps-link");
    symlink(target, taskLink);
    symlink(target, tempLink);
    string[] delegate(string) list = (string dir) {
        assert(!dir.startsWith("/nix/store/"), "worker traversed Nix store");
        string[] paths;
        foreach (entry; dirEntries(dir, SpanMode.shallow)) paths ~= entry.name;
        return paths;
    };
    auto baseline = measureDiskUsage(input, list);
    assert(baseline.symlinks.length == 2);
    bool completed;
    string error;
    DiskEvaluation withClosure;
    measureDiskUsageAsync(input, list, (DiskSymlink[] links) {
        assert(links.length == 2);
        assert(links[0].linkPath == taskLink);
        assert(links[1].linkPath == tempLink);
        return NixClosureReport([NixClosureEntry([taskLink, tempLink], target, 41)]);
    }).then((DiskEvaluation result) {
        withClosure = result;
        completed = true;
    }, (Exception e) { error = e.msg; }).ignoreResult();
    socketManager.loop();
    assert(completed, error);
    assert(withClosure.usage.taskBytes == baseline.taskBytes);
    assert(withClosure.usage.temporaryBytes == baseline.temporaryBytes);
    assert(withClosure.usage.totalBytes == baseline.totalBytes);
    assert(withClosure.nix.entries.length == 1);
    assert(withClosure.nix.entries[0].closureSize == 41);

    completed = false;
    DiskEvaluation withoutClosure;
    measureDiskUsageAsync(input, list, (DiskSymlink[] links) {
        assert(links.length == 2);
        assert(links[0].linkPath == taskLink);
        assert(links[1].linkPath == tempLink);
        return NixClosureReport.init;
    }).then((DiskEvaluation result) {
        withoutClosure = result;
        completed = true;
    }, (Exception e) { error = e.msg; }).ignoreResult();
    socketManager.loop();
    assert(completed, error);
    assert(withoutClosure.usage.taskBytes == baseline.taskBytes);
    assert(withoutClosure.usage.temporaryBytes == baseline.temporaryBytes);
    assert(withoutClosure.usage.totalBytes == baseline.totalBytes);
    assert(withoutClosure.nix.entries.length == 0);
}

@("disk worker keeps apparent bytes unchanged when Nix reporting is unavailable") unittest
{
    auto fixture = Fixture("exit 0");
    DiskScanInput input;
    input.taskDir = buildPath(fixture.root, "task");
    input.temporaryDir = buildPath(fixture.root, "temporary");
    mkdirRecurse(input.taskDir);
    mkdirRecurse(input.temporaryDir);
    auto target = liveStorePath();
    auto taskLink = buildPath(input.taskDir, "build-link");
    auto tempLink = buildPath(input.temporaryDir, "deps-link");
    symlink(target, taskLink);
    symlink(target, tempLink);
    string[] delegate(string) list = (string dir) {
        assert(!dir.startsWith("/nix/store/"));
        string[] paths;
        foreach (entry; dirEntries(dir, SpanMode.shallow)) paths ~= entry.name;
        return paths;
    };
    auto baseline = measureDiskUsage(input, list);
    auto unsupported = Fixture("echo \"error: unrecognised flag '--json-format'\" >&2; exit 2");
    auto daemon = Fixture("echo 'daemon unavailable' >&2; exit 1");
    auto timeout = Fixture("trap '' TERM; sleep 2");
    foreach (scenario; 0 .. 4)
    {
        string executable;
        int timeoutMs = 30_000;
        final switch (scenario)
        {
            case 0: executable = null; break;
            case 1: executable = unsupported.executable; break;
            case 2: executable = daemon.executable; break;
            case 3: executable = timeout.executable; timeoutMs = 10; break;
        }
        auto originalPath = environment.get("PATH", "");
        scope (exit) environment["PATH"] = originalPath;
        if (scenario == 0) environment["PATH"] = fixture.root;
        bool completed;
        string error;
        DiskEvaluation evaluation;
        auto start = MonoTime.currTime;
        measureDiskUsageAsync(input, list, (DiskSymlink[] links) {
            assert(links.length == 2);
            assert(links[0].linkPath == taskLink);
            assert(links[1].linkPath == tempLink);
            return reportNixClosures(links, executable, timeoutMs);
        }).then((DiskEvaluation result) {
            evaluation = result;
            completed = true;
        }, (Exception e) { error = e.msg; }).ignoreResult();
        socketManager.loop();
        assert(completed, error);
        assert(MonoTime.currTime - start < 5.seconds);
        assert(evaluation.usage.taskBytes == baseline.taskBytes);
        assert(evaluation.usage.temporaryBytes == baseline.temporaryBytes);
        assert(evaluation.usage.totalBytes == baseline.totalBytes);
        assert(evaluation.nix.entries.length == 0);
    }
}

@("nix roots ignore stale links and zero candidates") unittest
{
    auto fixture = Fixture("touch \"$0.invoked\"");
    auto missing = buildPath(fixture.root, "stale");
    symlink("missing-target", missing);
    auto loop = buildPath(fixture.root, "a");
    symlink("a", loop);
    write(buildPath(fixture.root, "file"), "");
    auto throughFile = buildPath(fixture.root, "through-file");
    symlink("file/x", throughFile);

    assert(timed(reportNixClosures([
        DiskSymlink(missing, "missing-target"),
        DiskSymlink(loop, "a"),
        DiskSymlink(throughFile, "file/x"),
    ], fixture.executable)).entries.length == 0);
    assert(timed(reportNixClosures([], fixture.executable)).entries.length == 0);
    assert(!exists(fixture.executable ~ ".invoked"));
}

@("disk worker rejects reporter diagnostics") unittest
{
    auto fixture = Fixture("exit 0");
    auto task = buildPath(fixture.root, "task");
    mkdirRecurse(task);
    DiskScanInput input;
    input.taskDir = task;
    input.temporaryDir = buildPath(fixture.root, "temporary");
    mkdirRecurse(input.temporaryDir);
    bool rejected;
    measureDiskUsageAsync(input, (string dir) {
        assert(!dir.startsWith("/nix/store/"), "worker traversed Nix store");
        string[] paths;
        if (exists(dir))
            foreach (entry; dirEntries(dir, SpanMode.shallow)) paths ~= entry.name;
        return paths;
    }, (DiskSymlink[] links) {
        import cydo.runtime.storage.nix_roots : NixClosureReport;
        throw new Exception("invalid nix diagnostic");
        return NixClosureReport.init;
    }).then((DiskEvaluation result) {
        assert(false, "expected worker rejection");
    }, (Exception error) {
        assert(error.msg.canFind("invalid nix diagnostic"));
        rejected = true;
    }).ignoreResult();
    socketManager.loop();
    assert(rejected);
}

@("nix roots query a live store path with the real executable") unittest
{
    if (skipStore()) return;
    import cydo.runtime.launch.sandbox_renderer : resolveExecutablePath;
    auto nix = resolveExecutablePath("nix", null);
    assert(nix.length > 0, "live Nix fixture requires nix on PATH");
    auto fixture = Fixture("exit 0");
    auto target = liveStorePath();
    auto link = buildPath(fixture.root, "deps-link");
    symlink(target, link);
    auto report = reportNixClosures([DiskSymlink(link, target)]);
    assert(report.entries.length == 1);
    assert(report.entries[0].storePath.startsWith("/nix/store/"));
    assert(report.entries[0].linkPaths == [link]);
    assert(report.entries[0].closureSize > 0);
    auto dangling = buildPath(fixture.root, "dangling-link");
    auto missing = "/nix/store/00000000000000000000000000000000-nope";
    symlink(missing, dangling);
    assert(reportNixClosures([DiskSymlink(dangling, missing)]).entries.length == 0);
}
