module cydo.workflow.workspace.worktree;

import std.algorithm : filter;
import std.array : array, join;
import std.file : exists, readText;
import std.format : format;
import std.logger : infof, errorf;
import std.path : baseName, buildPath, dirName;
import std.process : execute, pipeProcess, Redirect, wait;
import std.string : strip;
import cydo.workflow.workspace.worktree_dedup : dedupWorktree;

/// Link files of a repository's main checkout into one of its worktrees:
/// the untracked ones (personal instruction files, local settings) that a
/// new worktree does not have. `relativePaths` are relative to the root of
/// both. A file the checkout lacks is not linked, and one the worktree
/// already has (it is tracked, or already linked) is left alone.
void linkCheckoutFiles(string checkoutRoot, string worktreeRoot, const(string)[] relativePaths)
{
    import std.algorithm : canFind;
    import std.exception : enforce;
    import std.file : isSymlink, mkdirRecurse, symlink;
    import std.path : isAbsolute, pathSplitter;

    foreach (relativePath; relativePaths)
    {
        enforce(!relativePath.isAbsolute && !relativePath.pathSplitter.canFind(".."),
            format!"worktree_links: '%s' is not a path inside the checkout"(relativePath));
        auto source = buildPath(checkoutRoot, relativePath);
        auto link = buildPath(worktreeRoot, relativePath);
        if (!exists(source) || exists(link) || isSymlinkPath(link))
            continue;
        mkdirRecurse(dirName(link));
        symlink(source, link);
        infof("Linked %s into worktree %s", source, worktreeRoot);
    }
}

/// Whether `path` is a symlink, including one whose target is gone.
private bool isSymlinkPath(string path)
{
    import core.sys.posix.sys.stat : lstat, S_ISLNK, stat_t;
    import std.string : toStringz;

    stat_t st;
    return lstat(path.toStringz, &st) == 0 && S_ISLNK(st.st_mode);
}

unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, readLink, readText, rmdirRecurse, tempDir, write;

    auto root = buildPath(tempDir, "cydo-test-link-checkout-files");
    if (exists(root))
        rmdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto checkout = buildPath(root, "checkout");
    auto worktree = buildPath(root, "worktree");
    mkdirRecurse(buildPath(checkout, "sub"));
    mkdirRecurse(worktree);
    write(buildPath(checkout, "CLAUDE.md"), "personal\n");
    write(buildPath(checkout, "sub", "local.env"), "local\n");
    write(buildPath(checkout, "tracked.md"), "checkout version\n");
    write(buildPath(worktree, "tracked.md"), "worktree version\n");

    auto paths = ["CLAUDE.md", "sub/local.env", "tracked.md", "absent.md"];
    // Twice: the second call finds the links in place.
    foreach (_; 0 .. 2)
        linkCheckoutFiles(checkout, worktree, paths);

    assert(readLink(buildPath(worktree, "CLAUDE.md")) == buildPath(checkout, "CLAUDE.md"));
    assert(readText(buildPath(worktree, "sub", "local.env")) == "local\n");
    assert(readText(buildPath(worktree, "tracked.md")) == "worktree version\n");
    assert(!exists(buildPath(worktree, "absent.md")));

    assertThrown(linkCheckoutFiles(checkout, worktree, ["../outside"]));
    assertThrown(linkCheckoutFiles(checkout, worktree, ["/etc/hostname"]));
}

private enum ArchiveRefState
{
    Missing,
    Present,
}

private ArchiveRefState getArchiveRefState(string projectPath, int tid)
{
    // a non-git projectPath (e.g. an "unrestricted" workspace rooted at a plain
    // directory like $HOME) can't hold an archive ref at all; rev-parse would
    // bail with "not a git repository" (exit 128), so resolve to Missing before
    // the strict status check below treats non-0/1 exits as genuine git failures
    auto insideWorkTree = execute(["git", "-C", projectPath, "rev-parse", "--is-inside-work-tree"]);
    if (insideWorkTree.status != 0)
        return ArchiveRefState.Missing;

    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);
    auto cmd = ["git", "-C", projectPath, "rev-parse", "--verify", "--quiet", refName];
    auto result = execute(cmd);
    if (result.status == 0)
        return ArchiveRefState.Present;
    if (result.status == 1)
        return ArchiveRefState.Missing;
    throw new Exception(format!"getArchiveRefState failed for tid=%d: cmd='%s' output='%s'"(
        tid, cmd.join(" "), result.output.strip()));
}

/// Returns true if `refs/cydo/worktree-archive/<tid>` exists in the project repo.
bool hasArchiveRef(string projectPath, int tid)
{
    return getArchiveRefState(projectPath, tid) == ArchiveRefState.Present;
}

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : execute;

    auto dir = buildPath(tempDir(), "cydo-archive-ref-state-unittest");
    if (exists(dir))
        rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope(exit) rmdirRecurse(dir);

    // a non-git projectPath makes `git -C` exit 128; before the fix that
    // non-0/1 status was treated as a genuine git failure and threw. it must
    // resolve to Missing instead.
    assert(getArchiveRefState(dir, 1) == ArchiveRefState.Missing);

    // inside a real repo the genuine 0/1 path still holds: Missing until the
    // ref exists, Present once it does, and per-tid.
    execute(["git", "-C", dir, "init", "-q"]);
    assert(getArchiveRefState(dir, 1) == ArchiveRefState.Missing);

    execute(["git", "-C", dir, "commit", "-q", "--allow-empty", "-m", "seed"]);
    execute(["git", "-C", dir, "update-ref", "refs/cydo/worktree-archive/1", "HEAD"]);
    assert(getArchiveRefState(dir, 1) == ArchiveRefState.Present);
    assert(getArchiveRefState(dir, 2) == ArchiveRefState.Missing);
}

private noreturn throwGitFailure(string context, int tid, string[] cmd, string output)
{
    auto details = output.strip();
    throw new Exception(format!"%s failed for tid=%d: cmd='%s' output='%s'"(
        context, tid, cmd.join(" "), details.length > 0 ? details : "<empty>"));
}

string worktreeBranchName(int tid)
{
    return format!"cydo/%d"(tid);
}

string worktreeBranchTip(string repoDir, int tid)
{
    auto cmd = ["git", "-C", repoDir, "rev-parse", "--verify", "--quiet",
        "refs/heads/" ~ worktreeBranchName(tid) ~ "^{commit}"];
    auto result = execute(cmd);
    if (result.status == 0)
        return result.output.strip();
    if (result.status == 1)
        return null;
    throwGitFailure("worktreeBranchTip: rev-parse", tid, cmd, result.output);
}

struct WorktreeHeadStatus
{
    string branchTip;
    string currentBranch;
    string headSha;
}

WorktreeHeadStatus worktreeHeadStatus(string worktreePath, int worktreeTid)
{
    auto tip = worktreeBranchTip(worktreePath, worktreeTid);
    if (tip is null)
        return WorktreeHeadStatus.init;
    auto branchCmd = ["git", "-C", worktreePath, "branch", "--show-current"];
    auto branch = execute(branchCmd);
    if (branch.status != 0)
        throwGitFailure("worktreeHeadStatus: branch --show-current", worktreeTid, branchCmd, branch.output);
    auto currentBranch = branch.output.strip();
    if (currentBranch.length != 0)
        return WorktreeHeadStatus(tip, currentBranch);
    auto headCmd = ["git", "-C", worktreePath, "rev-parse", "HEAD"];
    auto head = execute(headCmd);
    if (head.status != 0)
        throwGitFailure("worktreeHeadStatus: rev-parse HEAD", worktreeTid, headCmd, head.output);
    return WorktreeHeadStatus(tip, currentBranch, head.output.strip());
}

private auto executeGitWithInput(string[] cmd, string input)
{
    import std.typecons : tuple;

    auto pipes = pipeProcess(cmd, Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
    pipes.stdin.write(input);
    pipes.stdin.close();
    auto output = pipes.stdout.byChunk(4096).join;
    return tuple!("status", "output")(wait(pipes.pid), cast(string) output);
}

private void runGitWithInput(string context, int tid, string[] cmd, string input)
{
    auto result = executeGitWithInput(cmd, input);
    if (result.status != 0)
        throwGitFailure(context, tid, cmd, result.output);
}

/// Create a worktree on a new branch `cydo/<tid>` with a registration id
/// derived from its host task.
void addWorktree(string repoDir, int tid, string worktreePath, string commitish = null)
{
    import std.array : replicate;
    import std.exception : enforce;
    import std.path : absolutePath, buildNormalizedPath, isAbsolute;

    enforce(isAbsolute(worktreePath), format!"addWorktree: worktree path '%s' must be absolute for tid=%d"(
        worktreePath, tid));

    auto expectedId = format!"cydo-workspace-%d"(tid);
    auto temporaryPath = buildPath(dirName(worktreePath), expectedId);
    // Git can adopt an existing temporary directory or move inside an existing destination.
    foreach (path; [worktreePath, temporaryPath])
        if (exists(path) || isSymlinkPath(path))
            throw new Exception(format!"addWorktree: worktree path '%s' already exists for tid=%d"(
                path, tid));

    string runGit(string context, string[] cmd)
    {
        auto result = execute(cmd);
        if (result.status != 0)
            throwGitFailure(context, tid, cmd, result.output);
        return result.output;
    }

    auto addCmd = ["git", "-C", repoDir, "worktree", "add", "--no-checkout",
        "-b", worktreeBranchName(tid), temporaryPath];
    if (commitish !is null)
        addCmd ~= commitish;
    runGit("addWorktree: worktree add", addCmd);

    string registrationDir;
    try
    {
        registrationDir = runGit("addWorktree: resolve temporary registration",
            ["git", "-C", temporaryPath, "rev-parse", "--absolute-git-dir"]).strip();
        auto actualId = baseName(registrationDir);
        if (actualId != expectedId)
            throw new Exception(format!"addWorktree: expected registration '%s' for tid=%d in repo '%s', got '%s'"(
                expectedId, tid, repoDir, actualId));

        runGit("addWorktree: worktree move",
            ["git", "-C", repoDir, "worktree", "move", temporaryPath, worktreePath]);
        // Git may move inside a destination created after our existence check.
        auto destinationRegistration = runGit("addWorktree: resolve destination registration",
            ["git", "-C", worktreePath, "rev-parse", "--absolute-git-dir"]).strip();
        if (destinationRegistration != registrationDir)
            throw new Exception(format!"addWorktree: checkout '%s' for tid=%d resolves to '%s', expected '%s'"(
                worktreePath, tid, destinationRegistration, registrationDir));

        // Populate after the move so the initial hook can initialize submodules.
        runGit("addWorktree: reset",
            ["git", "-C", worktreePath, "reset", "--hard", "--no-recurse-submodules"]);
        auto head = runGit("addWorktree: rev-parse HEAD",
            ["git", "-C", worktreePath, "rev-parse", "HEAD"]).strip();
        // Requires Git 2.36. Unlike worktree add, hook run resolves relative
        // hooks from the new checkout and uses Git's normal hook environment.
        runGit("addWorktree: post-checkout hook",
            ["git", "-C", worktreePath, "hook", "run", "--ignore-missing", "post-checkout",
                "--", "0".replicate(head.length), head, "1"]);
    }
    catch (Exception failure)
    {
        try
        {
            auto registeredPath = temporaryPath;
            if (registrationDir !is null)
            {
                auto gitFile = readText(buildPath(registrationDir, "gitdir")).strip();
                // Git writes links between canonical paths, even if the checkout is now gone.
                registeredPath = dirName(buildNormalizedPath(absolutePath(gitFile, registrationDir)));
            }
            runGit("addWorktree: rollback",
                ["git", "-C", repoDir, "worktree", "remove", "-f", "-f", registeredPath]);
            runGit("addWorktree: rollback branch",
                ["git", "-C", repoDir, "branch", "-D", worktreeBranchName(tid)]);
        }
        catch (Exception rollbackFailure)
            throw new Exception(failure.msg ~ "\n" ~ rollbackFailure.msg, __FILE__, __LINE__, failure);
        throw failure;
    }
}

/// Save dirty worktree state into a custom ref chain and remove the worktree.
///
/// Creates up to 3 layered commits on top of the worktree's current HEAD:
///   base → [cydo:archive:staged] → [cydo:archive:modified] → [cydo:archive:untracked]
/// Only layers with actual changes are created. The final SHA is stored as
/// refs/cydo/worktree-archive/<tid>, then the worktree directory is removed.
/// Deletes branch `cydo/<tid>`. Refuses if the branch holds commits not in HEAD
/// or is checked out in another worktree.
///
/// Throws on failure (with command details); logs successes/skips via std.logger.
/// Idempotent: no-op if the archive ref already exists.
void archiveWorktree(string worktreePath, string projectPath, int tid)
{
    if (getArchiveRefState(projectPath, tid) == ArchiveRefState.Present)
    {
        if (exists(worktreePath))
            throw new Exception(format!"archiveWorktree: stale archive ref for tid=%d with live worktree '%s'"(
                tid, worktreePath));
        infof("archiveWorktree: ref already exists for tid=%d, skipping", tid);
        return;
    }

    // Get current HEAD
    auto headCmd = ["git", "-C", worktreePath, "rev-parse", "HEAD"];
    auto headResult = execute(headCmd);
    if (headResult.status != 0)
        throwGitFailure("archiveWorktree: rev-parse HEAD", tid, headCmd, headResult.output);
    string currentHead = headResult.output.strip();

    auto branch = worktreeBranchName(tid);
    auto branchRef = "refs/heads/" ~ branch;
    auto symrefCmd = ["git", "-C", projectPath, "symbolic-ref", "-q", branchRef];
    auto symrefResult = execute(symrefCmd);
    if (symrefResult.status == 0)
        throw new Exception(format!"archiveWorktree: branch '%s' is a symbolic ref for tid=%d; refusing to archive"(
            branch, tid));
    if (symrefResult.status != 1)
        throwGitFailure("archiveWorktree: symbolic-ref", tid, symrefCmd, symrefResult.output);

    auto branchTip = worktreeBranchTip(projectPath, tid);
    if (branchTip !is null)
    {
        auto cmd = ["git", "-C", projectPath, "merge-base", "--is-ancestor", branchTip, currentHead];
        auto result = execute(cmd);
        if (result.status == 1)
            throw new Exception(format!"archiveWorktree: branch '%s' at %s has commits that are not in the worktree HEAD %s for tid=%d; put them into the worktree (or switch it back to %s) before archiving"(
                branch, branchTip, currentHead, tid, branch));
        if (result.status != 0)
            throwGitFailure("archiveWorktree: merge-base --is-ancestor", tid, cmd, result.output);

        import std.string : split, startsWith;

        auto listCmd = ["git", "-C", projectPath, "worktree", "list", "--porcelain", "-z"];
        auto listResult = execute(listCmd);
        if (listResult.status != 0)
            throwGitFailure("archiveWorktree: worktree list", tid, listCmd, listResult.output);
        auto rootCmd = ["git", "-C", worktreePath, "rev-parse", "--show-toplevel"];
        auto rootResult = execute(rootCmd);
        if (rootResult.status != 0)
            throwGitFailure("archiveWorktree: rev-parse --show-toplevel", tid, rootCmd, rootResult.output);
        auto checkoutRoot = rootResult.output[0 .. $ - 1]; // Strip only Git’s terminating newline.
        enum prefix = "worktree ";
        string registeredPath;
        foreach (field; listResult.output.split("\0"))
        {
            if (field.startsWith(prefix))
                registeredPath = field[prefix.length .. $];
            if (field == "branch " ~ branchRef && registeredPath != checkoutRoot)
                throw new Exception(format!"archiveWorktree: branch '%s' is checked out in another worktree %s for tid=%d; switch that worktree off it before archiving"(
                    branch, registeredPath, tid));
        }
    }

    // Layer 1: staged changes (index differs from HEAD)
    auto stagedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet"]);
    if (stagedDiff.status != 0)
    {
        auto treeCmd = ["git", "-C", worktreePath, "write-tree"];
        auto treeResult = execute(treeCmd);
        if (treeResult.status != 0)
            throwGitFailure("archiveWorktree: write-tree (staged)", tid, treeCmd, treeResult.output);
        auto commitCmd = ["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:staged]"];
        auto commitResult = execute(commitCmd);
        if (commitResult.status != 0)
            throwGitFailure("archiveWorktree: commit-tree (staged)", tid, commitCmd, commitResult.output);
        currentHead = commitResult.output.strip();
    }

    // Layer 2: unstaged tracked modifications
    auto addTrackedCmd = ["git", "-C", worktreePath, "add", "-u"];
    auto addTrackedResult = execute(addTrackedCmd);
    if (addTrackedResult.status != 0)
        throwGitFailure("archiveWorktree: git add -u", tid, addTrackedCmd, addTrackedResult.output);
    auto modifiedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet", currentHead]);
    if (modifiedDiff.status != 0)
    {
        auto treeCmd = ["git", "-C", worktreePath, "write-tree"];
        auto treeResult = execute(treeCmd);
        if (treeResult.status != 0)
            throwGitFailure("archiveWorktree: write-tree (modified)", tid, treeCmd, treeResult.output);
        auto commitCmd = ["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:modified]"];
        auto commitResult = execute(commitCmd);
        if (commitResult.status != 0)
            throwGitFailure("archiveWorktree: commit-tree (modified)", tid, commitCmd, commitResult.output);
        currentHead = commitResult.output.strip();
    }

    // Layer 3: untracked files
    auto addAllCmd = ["git", "-C", worktreePath, "add", "-A"];
    auto addAllResult = execute(addAllCmd);
    if (addAllResult.status != 0)
        throwGitFailure("archiveWorktree: git add -A", tid, addAllCmd, addAllResult.output);
    auto untrackedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet", currentHead]);
    if (untrackedDiff.status != 0)
    {
        auto treeCmd = ["git", "-C", worktreePath, "write-tree"];
        auto treeResult = execute(treeCmd);
        if (treeResult.status != 0)
            throwGitFailure("archiveWorktree: write-tree (untracked)", tid, treeCmd, treeResult.output);
        auto commitCmd = ["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:untracked]"];
        auto commitResult = execute(commitCmd);
        if (commitResult.status != 0)
            throwGitFailure("archiveWorktree: commit-tree (untracked)", tid, commitCmd, commitResult.output);
        currentHead = commitResult.output.strip();
    }

    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);
    auto updateRefCmd = ["git", "-C", projectPath, "update-ref", "--no-deref", "--stdin"];
    auto archiveInput = format!"create %s %s\n"(refName, currentHead);
    if (branchTip !is null)
        archiveInput ~= format!"delete %s %s\n"(branchRef, branchTip);
    else
        archiveInput ~= format!"verify %s\n"(branchRef);
    runGitWithInput("archiveWorktree: update-ref", tid, updateRefCmd, archiveInput);

    // Remove the worktree
    auto removeCmd = ["git", "-C", projectPath, "worktree", "remove", "--force", worktreePath];
    auto removeResult = execute(removeCmd);
    if (removeResult.status != 0)
    {
        errorf("archiveWorktree: worktree remove failed for tid=%d: cmd='%s' output='%s'",
            tid, removeCmd.join(" "), removeResult.output.strip());
        auto rollbackInput = format!"delete %s %s\n"(refName, currentHead);
        if (branchTip !is null)
            rollbackInput ~= format!"create %s %s\n"(branchRef, branchTip);
        auto cleanupResult = executeGitWithInput(updateRefCmd, rollbackInput);
        if (cleanupResult.status != 0)
            throw new Exception(format!"archiveWorktree: worktree remove failed for tid=%d: cmd='%s' output='%s'; cleanup failed: cmd='%s' output='%s'"(
                tid,
                removeCmd.join(" "), removeResult.output.strip(),
                updateRefCmd.join(" "), cleanupResult.output.strip()));
        throwGitFailure("archiveWorktree: worktree remove", tid, removeCmd, removeResult.output);
    }

    infof("archiveWorktree: archived tid=%d at %s", tid, refName);
}

/// Restore a worktree from the archive ref, recreating all dirty state.
///
/// Reads the commit chain stored at refs/cydo/worktree-archive/<tid>, recreates
/// the worktree on a new branch `cydo/<tid>` at the base commit, then unrolls
/// each layer: staged files to the index, modified files to the working tree,
/// untracked files to the filesystem.
/// Deletes the archive ref after successful restoration.
///
/// Throws on failure (with command details); logs successes/skips via std.logger.
/// Idempotent: no-op if the worktree directory already exists.
void unarchiveWorktree(string projectPath, int tid, string worktreePath)
{
    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);

    if (exists(worktreePath))
    {
        if (getArchiveRefState(projectPath, tid) == ArchiveRefState.Present)
            throw new Exception(format!"unarchiveWorktree: worktree already exists for tid=%d and archive ref still present (%s); refusing to delete ref to avoid losing archived state"(
                tid, refName));
        infof("unarchiveWorktree: worktree already exists for tid=%d, skipping", tid);
        return;
    }

    // Get the tip SHA stored in the archive ref
    auto tipCmd = ["git", "-C", projectPath, "rev-parse", refName];
    auto tipResult = execute(tipCmd);
    if (tipResult.status != 0)
        throwGitFailure("unarchiveWorktree: rev-parse ref", tid, tipCmd, tipResult.output);
    string tipSha = tipResult.output.strip();

    // Walk at most 4 commits (3 archive layers + base)
    auto logCmd = ["git", "-C", projectPath, "log",
        "--max-count=4", "--format=%H%n%s", tipSha];
    auto logResult = execute(logCmd);
    if (logResult.status != 0)
        throwGitFailure("unarchiveWorktree: git log", tid, logCmd, logResult.output);

    // Parse alternating sha/subject lines, stop at first non-archive commit
    string stagedSha, modifiedSha, untrackedSha, baseSha;
    {
        import std.string : split, splitLines;
        auto lines = logResult.output.split('\n').filter!(l => l.strip().length > 0).array;
        for (size_t i = 0; i + 1 < lines.length; i += 2)
        {
            auto sha = lines[i].strip();
            auto subject = lines[i + 1].strip();
            if (subject == "[cydo:archive:staged]")
                stagedSha = sha;
            else if (subject == "[cydo:archive:modified]")
                modifiedSha = sha;
            else if (subject == "[cydo:archive:untracked]")
                untrackedSha = sha;
            else
            {
                baseSha = sha;
                break;
            }
        }
    }

    if (baseSha.length == 0)
        throw new Exception(format!"unarchiveWorktree: could not find base commit for tid=%d ref='%s'"(
            tid, refName));

    // Recreate the worktree at the base commit
    addWorktree(projectPath, tid, worktreePath, baseSha);

    // Restore staged layer: set index to staged tree, check out files to working tree
    if (stagedSha.length > 0)
    {
        auto readTreeResult = execute(["git", "-C", worktreePath,
            "read-tree", stagedSha ~ "^{tree}"]);
        if (readTreeResult.status != 0)
            throwGitFailure("unarchiveWorktree: read-tree staged", tid,
                ["git", "-C", worktreePath, "read-tree", stagedSha ~ "^{tree}"], readTreeResult.output);
        auto checkoutCmd = ["git", "-C", worktreePath, "checkout-index", "-a", "-f"];
        auto checkoutResult = execute(checkoutCmd);
        if (checkoutResult.status != 0)
            throwGitFailure("unarchiveWorktree: checkout-index", tid, checkoutCmd, checkoutResult.output);
    }

    // Restore modified layer: apply diff to working tree only (leaves index unchanged)
    if (modifiedSha.length > 0)
    {
        string modifiedParent = stagedSha.length > 0 ? stagedSha : baseSha;
        auto diffResult = execute(["git", "-C", worktreePath, "diff",
            modifiedParent ~ ".." ~ modifiedSha]);
        if (diffResult.status != 0)
            throwGitFailure("unarchiveWorktree: diff (modified)", tid,
                ["git", "-C", worktreePath, "diff", modifiedParent ~ ".." ~ modifiedSha], diffResult.output);
        if (diffResult.output.length > 0)
        {
            auto applyPipes = pipeProcess(["git", "-C", worktreePath, "apply"], Redirect.stdin);
            applyPipes.stdin.write(diffResult.output);
            applyPipes.stdin.close();
            auto applyStatus = wait(applyPipes.pid);
            if (applyStatus != 0)
                throw new Exception(format!"unarchiveWorktree: git apply failed for tid=%d: cmd='git -C %s apply'"(
                    tid, worktreePath));
        }
    }

    // Restore untracked layer: extract added files directly from the tree
    if (untrackedSha.length > 0)
    {
        string untrackedParent = modifiedSha.length > 0 ? modifiedSha :
            (stagedSha.length > 0 ? stagedSha : baseSha);
        auto diffTreeResult = execute(["git", "-C", projectPath, "diff-tree",
            "--diff-filter=A", "--name-only", "-z", "-r", untrackedParent, untrackedSha]);
        if (diffTreeResult.status != 0)
            throwGitFailure("unarchiveWorktree: diff-tree", tid,
                ["git", "-C", projectPath, "diff-tree", "--diff-filter=A", "--name-only",
                    "-z", "-r", untrackedParent, untrackedSha],
                diffTreeResult.output);

        import std.file : mkdirRecurse, write;
        import std.string : split;
        auto files = diffTreeResult.output.split("\0").filter!(f => f.length > 0).array;
        foreach (file; files)
        {
            auto showResult = execute(["git", "-C", projectPath, "show",
                untrackedSha ~ ":" ~ file]);
            if (showResult.status != 0)
                throwGitFailure("unarchiveWorktree: git show '" ~ file ~ "'", tid,
                    ["git", "-C", projectPath, "show", untrackedSha ~ ":" ~ file], showResult.output);
            auto filePath = buildPath(worktreePath, file);
            mkdirRecurse(dirName(filePath));
            write(filePath, showResult.output);
        }
    }

    // Delete the archive ref
    auto deleteRefCmd = ["git", "-C", projectPath, "update-ref", "-d", refName];
    auto deleteRefResult = execute(deleteRefCmd);
    if (deleteRefResult.status != 0)
        throwGitFailure("unarchiveWorktree: update-ref -d", tid, deleteRefCmd, deleteRefResult.output);

    dedupWorktree(projectPath, worktreePath);
    infof("unarchiveWorktree: restored tid=%d at %s", tid, worktreePath);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

version(unittest)
{
    // Set git identity env vars so commit-tree works in the test sandbox
    // where no global git config may be present.
    shared static this()
    {
        import std.process : environment;
        environment["GIT_AUTHOR_NAME"] = "CyDo Test";
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com";
        environment["GIT_COMMITTER_NAME"] = "CyDo Test";
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com";
    }

    /// Set up a fresh temp git repo with an initial commit.
    string setupTestRepo(string name)
    {
        import std.file : exists, mkdirRecurse, rmdirRecurse, write;
        import std.path : buildPath;
        import std.process : execute;

        auto repoDir = buildPath("/tmp", name);
        if (exists(repoDir))
            rmdirRecurse(repoDir);
        mkdirRecurse(repoDir);
        execute(["git", "-C", repoDir, "init", "-q"]);
        execute(["git", "-C", repoDir, "config", "user.email", "test@test"]);
        execute(["git", "-C", repoDir, "config", "user.name", "Test"]);
        write(buildPath(repoDir, "README.md"), "initial\n");
        execute(["git", "-C", repoDir, "add", "."]);
        execute(["git", "-C", repoDir, "commit", "-qm", "init"]);
        return repoDir;
    }

    private string testGit(string repoDir, string[] args...)
    {
        import std.string : stripRight;

        auto result = execute(["git", "-C", repoDir] ~ args);
        assert(result.status == 0, result.output);
        return result.output.stripRight();
    }
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.string : splitLines;

    auto repoDir = setupTestRepo("cydo-wt-test-add");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");

    addWorktree(repoDir, 101, wtDir);

    assert(baseName(readText(buildPath(wtDir, ".git")).strip()) == "cydo-workspace-101");
    assert(testGit(wtDir, "symbolic-ref", "HEAD") == "refs/heads/cydo/101");
    assert(testGit(repoDir, "rev-parse", "cydo/101") == testGit(repoDir, "rev-parse", "HEAD"));
    assert(!exists(buildPath(repoDir, "cydo-workspace-101")));

    auto worktrees = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(worktrees.status == 0, worktrees.output);
    assert(worktrees.output.splitLines().canFind("worktree " ~ wtDir), worktrees.output);
}

unittest
{
    import std.algorithm : startsWith;
    import std.file : mkdirRecurse, remove, rmdirRecurse, symlink;
    import std.path : isAbsolute;

    auto repoDir = setupTestRepo("cydo-wt-test-add-relative-paths");
    scope(exit) rmdirRecurse(repoDir);
    auto taskDir = buildPath(repoDir, "tasks", "110");
    mkdirRecurse(taskDir);
    // Git writes the relative link from the physical checkout directory.
    auto taskLink = buildPath(repoDir, "task-link");
    symlink(taskDir, taskLink);
    scope(exit) remove(taskLink);
    auto wtDir = buildPath(taskLink, "wt");
    auto config = execute(["git", "-C", repoDir, "config", "worktree.useRelativePaths", "true"]);
    assert(config.status == 0, config.output);

    addWorktree(repoDir, 110, wtDir);

    auto registration = execute(["git", "-C", wtDir, "rev-parse", "--absolute-git-dir"]);
    assert(registration.status == 0, registration.output);
    assert(baseName(registration.output.strip()) == "cydo-workspace-110", registration.output);
    enum prefix = "gitdir: ";
    auto gitFile = readText(buildPath(wtDir, ".git")).strip();
    assert(gitFile.startsWith(prefix), gitFile);
    assert(!isAbsolute(gitFile[prefix.length .. $]), gitFile);
}

unittest
{
    import std.algorithm : canFind;
    import std.file : chdir, getcwd, rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-add-relative-destination");
    scope(exit) rmdirRecurse(repoDir);
    auto previousDir = getcwd();
    chdir(repoDir);
    scope(exit) chdir(previousDir);

    try
    {
        addWorktree(repoDir, 112, "relative-checkout");
        assert(0, "expected relative destination to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("'relative-checkout' must be absolute"), e.msg);
        assert(e.msg.canFind("tid=112"), e.msg);
    }

    assert(!exists(buildPath(repoDir, "relative-checkout")));
    assert(!exists(buildPath(repoDir, "cydo-workspace-112")));
    assert(!exists(buildPath(repoDir, ".git", "worktrees")));
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-add-revision");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto olderHead = execute(["git", "-C", repoDir, "rev-parse", "HEAD"]);
    assert(olderHead.status == 0, olderHead.output);
    auto commit = execute(["git", "-C", repoDir, "commit", "--allow-empty", "-qm", "new tip"]);
    assert(commit.status == 0, commit.output);

    addWorktree(repoDir, 102, wtDir, olderHead.output.strip());

    auto head = execute(["git", "-C", wtDir, "rev-parse", "HEAD"]);
    assert(head.status == 0, head.output);
    assert(head.output.strip() == olderHead.output.strip(), head.output);
    assert(testGit(repoDir, "rev-parse", "cydo/102") == olderHead.output.strip());
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-branch-collision");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto sha = testGit(repoDir, "rev-parse", "HEAD");
    testGit(repoDir, "branch", "cydo/113", sha);
    auto before = testGit(repoDir, "worktree", "list", "--porcelain");

    try
    {
        addWorktree(repoDir, 113, wtDir);
        assert(0, "expected existing branch to prevent worktree creation");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("a branch named 'cydo/113' already exists"), e.msg);
        assert(e.msg.canFind("tid=113"), e.msg);
    }

    assert(testGit(repoDir, "rev-parse", "cydo/113") == sha);
    assert(testGit(repoDir, "worktree", "list", "--porcelain") == before);
    assert(!exists(wtDir));
    assert(!exists(buildPath(repoDir, "cydo-workspace-113")));
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-fork-base");
    scope(exit) rmdirRecurse(repoDir);
    auto parent = buildPath(repoDir, "parent");
    auto child = buildPath(repoDir, "child");
    addWorktree(repoDir, 114, parent);
    testGit(parent, "commit", "--allow-empty", "-qm", "parent work");

    addWorktree(parent, 115, child);

    assert(testGit(child, "symbolic-ref", "HEAD") == "refs/heads/cydo/115");
    assert(testGit(repoDir, "rev-parse", "cydo/115") == testGit(parent, "rev-parse", "HEAD"));
}

unittest
{
    import std.algorithm : canFind, startsWith;
    import std.file : rmdirRecurse;
    import std.string : splitLines;

    auto repoDir = setupTestRepo("cydo-wt-test-add-duplicate-id");
    scope(exit) rmdirRecurse(repoDir);
    auto first = buildPath(repoDir, "other", "cydo-workspace-103");
    auto second = buildPath(repoDir, "second");
    testGit(repoDir, "worktree", "add", "--detach", first);

    try
    {
        addWorktree(repoDir, 103, second);
        assert(0, "expected duplicate task ID to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("expected registration 'cydo-workspace-103'"), e.msg);
        assert(e.msg.canFind("got 'cydo-workspace-103"), e.msg);
    }

    auto worktrees = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(worktrees.status == 0, worktrees.output);
    auto entries = worktrees.output.splitLines().filter!(line => line.startsWith("worktree ")).array;
    assert(entries == ["worktree " ~ repoDir, "worktree " ~ first], worktrees.output);
    assert(!exists(second));
    assert(!exists(buildPath(repoDir, "cydo-workspace-103")));
    auto branch = execute(["git", "-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/heads/cydo/103"]);
    assert(branch.status == 1, branch.output);
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-add-move-failure");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto add = execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);
    assert(add.status == 0, add.output);
    auto lock = execute(["git", "-C", repoDir, "worktree", "lock", wtDir]);
    assert(lock.status == 0, lock.output);
    rmdirRecurse(wtDir);
    auto before = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(before.status == 0, before.output);

    try
    {
        addWorktree(repoDir, 107, wtDir);
        assert(0, "expected move to a missing locked worktree to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("worktree move failed"), e.msg);
        assert(e.msg.canFind("is a missing but locked worktree"), e.msg);
    }

    auto after = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(after.status == 0, after.output);
    assert(after.output == before.output, after.output);
    assert(!exists(wtDir));
    assert(!exists(buildPath(repoDir, "cydo-workspace-107")));
    auto branch = execute(["git", "-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/heads/cydo/107"]);
    assert(branch.status == 1, branch.output);
}

unittest
{
    import std.array : replicate;
    import std.conv : octal;
    import std.file : rmdirRecurse, setAttributes, write;

    auto repoDir = setupTestRepo("cydo-wt-test-add-submodule-hook");
    scope(exit) rmdirRecurse(repoDir);
    auto subRepo = setupTestRepo("cydo-wt-test-add-submodule-source");
    scope(exit) rmdirRecurse(subRepo);
    auto wtDir = buildPath(repoDir, "wt");

    auto submodule = execute(["git", "-C", repoDir, "-c", "protocol.file.allow=always",
        "submodule", "add", subRepo, "dep"]);
    assert(submodule.status == 0, submodule.output);
    auto commit = execute(["git", "-C", repoDir, "commit", "-qm", "add submodule"]);
    assert(commit.status == 0, commit.output);
    auto head = execute(["git", "-C", repoDir, "rev-parse", "HEAD"]);
    assert(head.status == 0, head.output);

    auto hooksDir = buildPath(repoDir, ".git", "hooks");
    auto hook = buildPath(hooksDir, "post-checkout");
    write(hook, "#!/bin/sh\n"
        ~ "printf '%s\\n' \"$PWD\" \"$@\" >> hook-args\n"
        ~ "git -c protocol.file.allow=always submodule update --init\n");
    setAttributes(hook, octal!755);
    auto config = execute(["git", "-C", repoDir, "config", "core.hooksPath", hooksDir]);
    assert(config.status == 0, config.output);

    addWorktree(repoDir, 108, wtDir);

    assert(baseName(readText(buildPath(wtDir, ".git")).strip()) == "cydo-workspace-108");
    assert(readText(buildPath(wtDir, "dep", "README.md")) == "initial\n");
    auto oid = head.output.strip();
    auto args = readText(buildPath(wtDir, "hook-args"));
    assert(args == wtDir ~ "\n" ~ "0".replicate(oid.length) ~ "\n" ~ oid ~ "\n1\n", args);
}

unittest
{
    import std.algorithm : canFind;
    import std.conv : octal;
    import std.file : rmdirRecurse, setAttributes, write;

    auto repoDir = setupTestRepo("cydo-wt-test-add-hook-failure");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto hooksDir = buildPath(repoDir, ".git", "hooks");
    auto hook = buildPath(hooksDir, "post-checkout");
    write(hook, "#!/bin/sh\n"
        ~ "git worktree lock \"$PWD\" || exit 2\n"
        ~ "echo 'checkout hook rejected worktree' >&2\n"
        ~ "exit 1\n");
    setAttributes(hook, octal!755);
    auto config = execute(["git", "-C", repoDir, "config", "core.hooksPath", hooksDir]);
    assert(config.status == 0, config.output);
    auto before = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(before.status == 0, before.output);

    try
    {
        addWorktree(repoDir, 109, wtDir);
        assert(0, "expected failing post-checkout hook to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("post-checkout hook failed"), e.msg);
        assert(e.msg.canFind("checkout hook rejected worktree"), e.msg);
    }

    auto after = execute(["git", "-C", repoDir, "worktree", "list", "--porcelain"]);
    assert(after.status == 0, after.output);
    assert(after.output == before.output, after.output);
    assert(!exists(wtDir));
    assert(!exists(buildPath(repoDir, "cydo-workspace-109")));
    auto branch = execute(["git", "-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/heads/cydo/109"]);
    assert(branch.status == 1, branch.output);
}

unittest
{
    import std.algorithm : canFind;
    import std.file : mkdir, rmdirRecurse, write;

    auto repoDir = setupTestRepo("cydo-wt-test-add-existing-destination");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    mkdir(wtDir);
    write(buildPath(wtDir, "existing.txt"), "keep\n");

    try
    {
        addWorktree(repoDir, 106, wtDir);
        assert(0, "expected existing destination to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("already exists"), e.msg);
    }

    assert(readText(buildPath(wtDir, "existing.txt")) == "keep\n");
    assert(!exists(buildPath(repoDir, ".git", "worktrees", "cydo-workspace-106")));
    assert(!exists(buildPath(repoDir, "cydo-workspace-106")));
}

unittest
{
    import std.algorithm : canFind;
    import std.file : dirEntries, isDir, mkdir, rmdirRecurse, SpanMode;

    auto repoDir = setupTestRepo("cydo-wt-test-add-existing-temporary-path");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto temporaryPath = buildPath(repoDir, "cydo-workspace-111");
    mkdir(temporaryPath);

    try
    {
        addWorktree(repoDir, 111, wtDir);
        assert(0, "expected existing temporary directory to throw");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("already exists"), e.msg);
    }

    assert(isDir(temporaryPath));
    assert(dirEntries(temporaryPath, SpanMode.shallow).empty);
    assert(!exists(wtDir));
    assert(!exists(buildPath(repoDir, ".git", "worktrees", "cydo-workspace-111")));
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-add-after-prune");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto gitFilePath = buildPath(wtDir, ".git");
    addWorktree(repoDir, 104, wtDir);
    auto originalGitFile = readText(gitFilePath).strip();
    auto registration = execute(["git", "-C", wtDir, "rev-parse", "--absolute-git-dir"]);
    assert(registration.status == 0, registration.output);
    auto originalRegistration = registration.output.strip();
    assert(exists(originalRegistration), originalRegistration);

    rmdirRecurse(wtDir);
    auto prune = execute(["git", "-C", repoDir, "worktree", "prune"]);
    assert(prune.status == 0, prune.output);
    addWorktree(repoDir, 105, wtDir);

    assert(!exists(originalRegistration), originalRegistration);
    assert(readText(gitFilePath).strip() != originalGitFile);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!Exception(archiveWorktree(
        "/tmp/cydo-archive-missing-worktree",
        "/tmp/cydo-archive-missing-repo",
        9001,
    ));
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!Exception(unarchiveWorktree(
        "/tmp/cydo-unarchive-missing-repo",
        9002,
        "/tmp/cydo-unarchive-missing-worktree",
    ));
}

unittest
{
    import std.exception : assertThrown;

    auto repoDir = setupTestRepo("cydo-test-worktree-stale-ref-archive");
    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);
    auto head = execute(["git", "-C", repoDir, "rev-parse", "HEAD"]).output.strip();
    execute(["git", "-C", repoDir, "update-ref", "refs/cydo/worktree-archive/777", head]);

    assertThrown!Exception(archiveWorktree(wtDir, repoDir, 777));
}

unittest
{
    import std.exception : assertThrown;

    auto repoDir = setupTestRepo("cydo-test-worktree-stale-ref-unarchive");
    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);
    auto head = execute(["git", "-C", repoDir, "rev-parse", "HEAD"]).output.strip();
    execute(["git", "-C", repoDir, "update-ref", "refs/cydo/worktree-archive/778", head]);

    assertThrown!Exception(unarchiveWorktree(repoDir, 778, wtDir));
    assert(hasArchiveRef(repoDir, 778), "archive ref should be preserved when worktree already exists");
}

unittest
{
    // Test: full 3-layer archive and restore (staged + modified + untracked)
    import std.file : exists, isDir, mkdirRecurse, readText, rmdirRecurse, write;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-full");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    auto gitResult = execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);
    assert(gitResult.status == 0, "worktree add failed: " ~ gitResult.output);

    // Test: hasArchiveRef returns false before archive
    assert(!hasArchiveRef(repoDir, 42));

    // Set up dirty state: staged, modified, untracked
    write(buildPath(wtDir, "staged.txt"), "staged content\n");
    execute(["git", "-C", wtDir, "add", "staged.txt"]);

    write(buildPath(wtDir, "README.md"), "modified content\n");  // tracked + modified (unstaged)

    write(buildPath(wtDir, "untracked.txt"), "untracked content\n");  // untracked

    // Archive the worktree
    archiveWorktree(wtDir, repoDir, 42);

    // Worktree directory should be gone
    assert(!exists(wtDir), "worktree should be removed after archive");

    // Archive ref should exist
    assert(hasArchiveRef(repoDir, 42), "archive ref should exist");

    // Unarchive the worktree
    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 42, wtDir2);

    // Worktree should exist
    assert(exists(wtDir2) && isDir(wtDir2), "worktree should be recreated");

    // Archive ref should be gone after unarchive
    assert(!hasArchiveRef(repoDir, 42), "archive ref should be deleted after unarchive");

    // Check staged file is staged (in index)
    auto stagedCheck = execute(["git", "-C", wtDir2, "diff", "--cached", "--name-only"]);
    assert(stagedCheck.status == 0);
    assert(stagedCheck.output.strip() == "staged.txt",
        "staged.txt should be staged, got: " ~ stagedCheck.output);

    // Check staged file content
    assert(readText(buildPath(wtDir2, "staged.txt")) == "staged content\n",
        "staged.txt content mismatch");

    // Check modified file is unstaged (working tree differs from index)
    auto modCheck = execute(["git", "-C", wtDir2, "diff", "--name-only"]);
    assert(modCheck.status == 0);
    assert(modCheck.output.strip() == "README.md",
        "README.md should be unstaged-modified, got: " ~ modCheck.output);

    // Check modified file content
    assert(readText(buildPath(wtDir2, "README.md")) == "modified content\n",
        "README.md content mismatch");

    // Check untracked file
    auto untrackedCheck = execute(["git", "-C", wtDir2, "ls-files", "--others", "--exclude-standard"]);
    assert(untrackedCheck.status == 0);
    assert(untrackedCheck.output.strip() == "untracked.txt",
        "untracked.txt should be untracked, got: " ~ untrackedCheck.output);

    // Check untracked file content
    assert(readText(buildPath(wtDir2, "untracked.txt")) == "untracked content\n",
        "untracked.txt content mismatch");
}

unittest
{
    // Test: clean worktree round-trip (no dirty state)
    import std.file : exists, isDir, rmdirRecurse;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-clean");
    scope(exit) rmdirRecurse(repoDir);

    // Get current HEAD
    auto headResult = execute(["git", "-C", repoDir, "rev-parse", "HEAD"]);
    auto originalHead = headResult.output.strip();

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // Archive clean worktree
    archiveWorktree(wtDir, repoDir, 99);
    assert(!exists(wtDir));
    assert(hasArchiveRef(repoDir, 99));

    // Unarchive
    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 99, wtDir2);
    assert(exists(wtDir2) && isDir(wtDir2));

    // HEAD should be same as original
    auto headResult2 = execute(["git", "-C", wtDir2, "rev-parse", "HEAD"]);
    assert(headResult2.output.strip() == originalHead, "HEAD should match original after clean round-trip");
    assert(testGit(wtDir2, "symbolic-ref", "HEAD") == "refs/heads/cydo/99");

    // No staged or unstaged changes
    auto stagedCheck = execute(["git", "-C", wtDir2, "diff", "--cached", "--quiet"]);
    assert(stagedCheck.status == 0, "should have no staged changes after clean round-trip");
    auto diffCheck = execute(["git", "-C", wtDir2, "diff", "--quiet"]);
    assert(diffCheck.status == 0, "should have no unstaged changes after clean round-trip");
}

unittest
{
    // Test: only-staged round-trip
    import std.file : exists, rmdirRecurse, write;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-staged");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // Only staged
    write(buildPath(wtDir, "newfile.txt"), "new staged\n");
    execute(["git", "-C", wtDir, "add", "newfile.txt"]);

    archiveWorktree(wtDir, repoDir, 11);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 11, wtDir2);

    // newfile.txt should be staged
    auto stagedCheck = execute(["git", "-C", wtDir2, "diff", "--cached", "--name-only"]);
    assert(stagedCheck.output.strip() == "newfile.txt",
        "newfile.txt should be staged, got: " ~ stagedCheck.output);
    // No unstaged changes
    auto diffCheck = execute(["git", "-C", wtDir2, "diff", "--quiet"]);
    assert(diffCheck.status == 0, "should have no unstaged changes");
}

unittest
{
    // Test: only-modified round-trip
    import std.file : exists, rmdirRecurse, readText, write;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-modified");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // Only modified (no staged, no untracked)
    write(buildPath(wtDir, "README.md"), "modified content\n");

    archiveWorktree(wtDir, repoDir, 22);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 22, wtDir2);

    // No staged changes
    auto stagedCheck = execute(["git", "-C", wtDir2, "diff", "--cached", "--quiet"]);
    assert(stagedCheck.status == 0, "should have no staged changes");
    // README.md should be unstaged-modified
    auto diffCheck = execute(["git", "-C", wtDir2, "diff", "--name-only"]);
    assert(diffCheck.output.strip() == "README.md",
        "README.md should be unstaged-modified, got: " ~ diffCheck.output);
    assert(readText(buildPath(wtDir2, "README.md")) == "modified content\n");
}

unittest
{
    // Test: only-untracked round-trip
    import std.file : exists, rmdirRecurse, readText, write;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-untracked");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // Only untracked
    write(buildPath(wtDir, "new.txt"), "new untracked\n");

    archiveWorktree(wtDir, repoDir, 33);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 33, wtDir2);

    // No staged or unstaged changes
    auto stagedCheck = execute(["git", "-C", wtDir2, "diff", "--cached", "--quiet"]);
    assert(stagedCheck.status == 0, "should have no staged changes");
    auto diffCheck = execute(["git", "-C", wtDir2, "diff", "--quiet"]);
    assert(diffCheck.status == 0, "should have no unstaged changes");
    // new.txt should be untracked
    auto untrackedCheck = execute(["git", "-C", wtDir2, "ls-files", "--others", "--exclude-standard"]);
    assert(untrackedCheck.output.strip() == "new.txt",
        "new.txt should be untracked, got: " ~ untrackedCheck.output);
    assert(readText(buildPath(wtDir2, "new.txt")) == "new untracked\n");
}

unittest
{
    // Test: idempotency of archiveWorktree (second call is a no-op)
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-arch-idem");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // First archive
    archiveWorktree(wtDir, repoDir, 66);
    assert(!exists(wtDir));
    assert(hasArchiveRef(repoDir, 66));

    // Second archive: ref already exists → no-op, returns true
    // The worktree is already gone; archiveWorktree checks hasArchiveRef first.
    archiveWorktree(wtDir, repoDir, 66);
    // Ref should still exist
    assert(hasArchiveRef(repoDir, 66));
}

unittest
{
    // Test: idempotency of unarchiveWorktree (second call is a no-op)
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-idem");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    archiveWorktree(wtDir, repoDir, 55);

    // First unarchive
    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 55, wtDir2);

    // Second unarchive: worktree exists → no-op, returns true
    unarchiveWorktree(repoDir, 55, wtDir2);
}

unittest
{
    // Test: hasArchiveRef lifecycle — false before, true after archive, false after unarchive
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;
    import std.process : execute;

    auto repoDir = setupTestRepo("cydo-wt-test-ref");
    scope(exit) rmdirRecurse(repoDir);

    auto wtDir = buildPath(repoDir, "wt");
    execute(["git", "-C", repoDir, "worktree", "add", "--detach", wtDir]);

    // Before archive: ref does not exist
    assert(!hasArchiveRef(repoDir, 77));

    archiveWorktree(wtDir, repoDir, 77);

    // After archive: ref exists
    assert(hasArchiveRef(repoDir, 77));

    auto wtDir2 = buildPath(repoDir, "wt2");
    unarchiveWorktree(repoDir, 77, wtDir2);

    // After unarchive: ref is deleted
    assert(!hasArchiveRef(repoDir, 77));
}

unittest
{
    import std.file : rmdirRecurse, write;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-branch");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto restored = buildPath(repoDir, "restored");
    addWorktree(repoDir, 120, wtDir);
    testGit(wtDir, "commit", "--allow-empty", "-qm", "task work");
    auto sha = testGit(wtDir, "rev-parse", "HEAD");
    write(buildPath(wtDir, "staged.txt"), "staged\n");
    testGit(wtDir, "add", "staged.txt");
    write(buildPath(wtDir, "README.md"), "modified\n");
    write(buildPath(wtDir, "untracked.txt"), "untracked\n");

    archiveWorktree(wtDir, repoDir, 120);

    assert(!exists(wtDir));
    assert(hasArchiveRef(repoDir, 120));
    auto branch = execute(["git", "-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/heads/cydo/120"]);
    assert(branch.status == 1, branch.output);

    unarchiveWorktree(repoDir, 120, restored);

    assert(testGit(restored, "symbolic-ref", "HEAD") == "refs/heads/cydo/120");
    assert(testGit(repoDir, "rev-parse", "cydo/120") == sha);
    assert(!hasArchiveRef(repoDir, 120));
    assert(testGit(restored, "status", "--porcelain", "--untracked-files=all")
        == " M README.md\nA  staged.txt\n?? untracked.txt");
    assert(testGit(restored, "show", ":staged.txt") == "staged");
    assert(readText(buildPath(restored, "README.md")) == "modified\n");
    assert(readText(buildPath(restored, "untracked.txt")) == "untracked\n");
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse, write;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-branch-ahead");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 121, wtDir);
    testGit(wtDir, "commit", "--allow-empty", "-qm", "task work");
    auto sha = testGit(wtDir, "rev-parse", "HEAD");
    testGit(wtDir, "switch", "--detach", "HEAD~1");
    write(buildPath(wtDir, "README.md"), "modified\n");

    try
    {
        archiveWorktree(wtDir, repoDir, 121);
        assert(0, "expected archive to refuse commits outside worktree HEAD");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("branch 'cydo/121'"), e.msg);
    }

    assert(!hasArchiveRef(repoDir, 121));
    assert(exists(wtDir));
    assert(testGit(repoDir, "rev-parse", "cydo/121") == sha);
    testGit(wtDir, "diff", "--cached", "--quiet");
    assert(testGit(wtDir, "diff", "--name-only") == "README.md");
    assert(readText(buildPath(wtDir, "README.md")) == "modified\n");
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-branch-behind");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 122, wtDir);
    testGit(wtDir, "switch", "--detach");
    testGit(wtDir, "commit", "--allow-empty", "-qm", "detached work");
    auto sha = testGit(wtDir, "rev-parse", "HEAD");

    archiveWorktree(wtDir, repoDir, 122);

    auto branch = execute(["git", "-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/heads/cydo/122"]);
    assert(branch.status == 1, branch.output);

    unarchiveWorktree(repoDir, 122, wtDir);

    assert(testGit(wtDir, "symbolic-ref", "HEAD") == "refs/heads/cydo/122");
    assert(testGit(repoDir, "rev-parse", "cydo/122") == sha);
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-unarchive-branch-collision");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    testGit(repoDir, "worktree", "add", "--detach", wtDir);
    archiveWorktree(wtDir, repoDir, 123);
    testGit(repoDir, "branch", "cydo/123");
    enum archiveRef = "refs/cydo/worktree-archive/123";
    auto archived = testGit(repoDir, "rev-parse", archiveRef);

    try
    {
        unarchiveWorktree(repoDir, 123, wtDir);
        assert(0, "expected existing branch to prevent restoration");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("a branch named 'cydo/123' already exists"), e.msg);
    }

    assert(testGit(repoDir, "rev-parse", archiveRef) == archived);
    assert(!exists(wtDir));
}

unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-branch-rollback");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 124, wtDir);
    auto sha = testGit(wtDir, "rev-parse", "HEAD");
    testGit(repoDir, "worktree", "lock", wtDir);
    scope(exit) testGit(repoDir, "worktree", "unlock", wtDir);

    try
    {
        archiveWorktree(wtDir, repoDir, 124);
        assert(0, "expected locked worktree to prevent removal");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind("worktree remove failed"), e.msg);
    }

    assert(!hasArchiveRef(repoDir, 124));
    assert(testGit(repoDir, "rev-parse", "cydo/124") == sha);
    assert(exists(wtDir));
    assert(testGit(wtDir, "symbolic-ref", "HEAD") == "refs/heads/cydo/124");
}

unittest
{
    import std.conv : octal;
    import std.exception : collectException;
    import std.file : mkdir, remove, rmdirRecurse, setAttributes, write;
    import std.string : startsWith;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-rollback-new-branch");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    testGit(repoDir, "worktree", "add", "--detach", wtDir);
    auto tip = testGit(wtDir, "rev-parse", "HEAD");
    assert(worktreeBranchTip(repoDir, 133) is null);
    testGit(repoDir, "worktree", "lock", wtDir);

    auto hooksDir = buildPath(repoDir, ".git", "test-hooks");
    mkdir(hooksDir);
    testGit(repoDir, "config", "core.hooksPath", hooksDir);
    auto hook = buildPath(hooksDir, "reference-transaction");
    write(hook, "#!/bin/sh\n"
        ~ "[ \"$1\" = committed ] || exit 0\n"
        ~ "while read -r old new ref; do\n"
        ~ "    [ \"$ref\" = refs/cydo/worktree-archive/133 ] || continue\n"
        ~ "    case \"$old\" in\n"
        ~ "        *[!0]*) continue ;;\n"
        ~ "    esac\n"
        ~ "    git update-ref refs/heads/cydo/133 HEAD\n"
        ~ "    exit $?\n"
        ~ "done\n");
    setAttributes(hook, octal!755);

    auto error = collectException!Exception(archiveWorktree(wtDir, repoDir, 133));
    assert(error !is null);
    assert(error.msg.startsWith("archiveWorktree: worktree remove failed for tid=133"), error.msg);
    assert(!hasArchiveRef(repoDir, 133), error.msg);
    assert(testGit(repoDir, "rev-parse", "refs/heads/cydo/133") == tip);
    assert(exists(wtDir));
    assert(testGit(wtDir, "rev-parse", "HEAD") == tip);

    remove(hook);
    testGit(repoDir, "worktree", "unlock", wtDir);
    archiveWorktree(wtDir, repoDir, 133);

    assert(testGit(repoDir, "rev-parse", "refs/cydo/worktree-archive/133") == tip);
    assert(worktreeBranchTip(repoDir, 133) is null);
    assert(!exists(wtDir));
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-head-status");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 125, wtDir);
    auto tip = testGit(wtDir, "rev-parse", "HEAD");
    assert(worktreeBranchTip(repoDir, 125) == tip);
    auto assigned = worktreeHeadStatus(wtDir, 125);
    assert(assigned.branchTip == tip);
    assert(assigned.currentBranch == "cydo/125");
    assert(assigned.headSha is null);

    testGit(wtDir, "switch", "--detach");
    testGit(wtDir, "commit", "--allow-empty", "-qm", "detached work");
    auto detached = worktreeHeadStatus(wtDir, 125);
    assert(detached.branchTip == tip);
    assert(detached.currentBranch == "");
    assert(detached.headSha == testGit(wtDir, "rev-parse", "HEAD"));

    testGit(wtDir, "switch", "-c", "feature");
    assert(worktreeHeadStatus(wtDir, 125).currentBranch == "feature");
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-orphan-head-status");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 130, wtDir);
    auto tip = testGit(wtDir, "rev-parse", "HEAD");
    testGit(wtDir, "switch", "--orphan", "scratch");

    auto status = worktreeHeadStatus(wtDir, 130);
    assert(status.currentBranch == "scratch");
    assert(status.headSha is null);
    assert(status.branchTip == tip);
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-legacy-head-status");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    testGit(repoDir, "worktree", "add", "--detach", wtDir);
    assert(worktreeBranchTip(repoDir, 126) is null);
    assert(worktreeHeadStatus(wtDir, 126).branchTip is null);
}

unittest
{
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-deleted-branch-head-status");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    addWorktree(repoDir, 128, wtDir);
    testGit(repoDir, "update-ref", "-d", "refs/heads/cydo/128");
    assert(testGit(wtDir, "symbolic-ref", "HEAD") == "refs/heads/cydo/128");
    assert(worktreeHeadStatus(wtDir, 128) == WorktreeHeadStatus.init);
}

unittest
{
    import std.exception : collectException;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-symbolic-branch");
    scope(exit) rmdirRecurse(repoDir);
    testGit(repoDir, "branch", "-M", "master");
    auto master = testGit(repoDir, "rev-parse", "refs/heads/master");
    auto wtDir = buildPath(repoDir, "wt");
    testGit(repoDir, "worktree", "add", "--detach", wtDir);
    testGit(repoDir, "symbolic-ref", "refs/heads/cydo/131", "refs/heads/master");

    auto error = collectException!Exception(archiveWorktree(wtDir, repoDir, 131));
    assert(error !is null);
    assert(error.msg == "archiveWorktree: branch 'cydo/131' is a symbolic ref for tid=131; refusing to archive",
        error.msg);
    assert(testGit(repoDir, "rev-parse", "refs/heads/master") == master);
    assert(testGit(repoDir, "symbolic-ref", "refs/heads/cydo/131") == "refs/heads/master");
    assert(!hasArchiveRef(repoDir, 131));
    assert(exists(wtDir));
}

unittest
{
    import std.conv : octal;
    import std.exception : collectException;
    import std.file : mkdir, rmdirRecurse, setAttributes, write;
    import std.string : startsWith;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-new-branch");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    testGit(repoDir, "worktree", "add", "--detach", wtDir);
    auto tip = testGit(wtDir, "rev-parse", "HEAD");
    assert(worktreeBranchTip(repoDir, 132) is null);

    auto hooksDir = buildPath(repoDir, ".git", "test-hooks");
    mkdir(hooksDir);
    testGit(repoDir, "config", "core.hooksPath", hooksDir);
    // Stage a tracked edit during archive to create the branch after it sampled the refs.
    auto hook = buildPath(hooksDir, "post-index-change");
    write(hook, "#!/bin/sh\ngit update-ref refs/heads/cydo/132 HEAD\n");
    setAttributes(hook, octal!755);
    write(buildPath(wtDir, "README.md"), "modified\n");

    auto error = collectException!Exception(archiveWorktree(wtDir, repoDir, 132));
    assert(error !is null);
    assert(error.msg.startsWith("archiveWorktree: update-ref failed for tid=132"), error.msg);
    assert(testGit(repoDir, "rev-parse", "refs/heads/cydo/132") == tip);
    assert(!hasArchiveRef(repoDir, 132));
    assert(exists(wtDir));
}

unittest
{
    import std.file : rmdirRecurse, write;

    auto repoDir = setupTestRepo("cydo-wt-test-archive-branch-in-other-worktree");
    scope(exit) rmdirRecurse(repoDir);
    auto wtDir = buildPath(repoDir, "wt");
    auto otherDir = buildPath(repoDir, "other wt");
    addWorktree(repoDir, 129, wtDir);
    auto sha = testGit(wtDir, "rev-parse", "HEAD");
    testGit(wtDir, "switch", "--detach");
    testGit(repoDir, "worktree", "add", otherDir, "cydo/129");
    auto otherRoot = testGit(otherDir, "rev-parse", "--show-toplevel");
    auto worktrees = testGit(repoDir, "worktree", "list", "--porcelain");
    auto readme = buildPath(wtDir, "README.md");
    write(readme, "modified\n");

    try
    {
        archiveWorktree(wtDir, repoDir, 129);
        assert(0, "expected archive to refuse a branch checked out elsewhere");
    }
    catch (Exception e)
    {
        assert(e.msg == "archiveWorktree: branch 'cydo/129' is checked out in another worktree "
            ~ otherRoot ~ " for tid=129; switch that worktree off it before archiving", e.msg);
    }

    assert(!hasArchiveRef(repoDir, 129));
    assert(exists(wtDir) && exists(otherDir));
    assert(testGit(repoDir, "worktree", "list", "--porcelain") == worktrees);
    assert(testGit(repoDir, "rev-parse", "cydo/129") == sha);
    testGit(wtDir, "diff", "--cached", "--quiet");
    assert(testGit(wtDir, "diff", "--name-only") == "README.md");
    assert(readText(readme) == "modified\n");
}

unittest
{
    import std.exception : assertThrown;
    import std.file : rmdirRecurse;

    auto repoDir = setupTestRepo("cydo-wt-test-invalid-head-status");
    scope(exit) rmdirRecurse(repoDir);
    rmdirRecurse(buildPath(repoDir, ".git"));

    assertThrown(worktreeBranchTip(repoDir, 127));
}
