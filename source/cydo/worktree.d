module cydo.worktree;

import std.algorithm : filter;
import std.array : array;
import std.format : format;
import std.logger : infof, errorf;
import std.path : buildPath, dirName;
import std.process : execute, pipeProcess, Redirect, wait;
import std.string : strip;

/// Returns true if `refs/cydo/worktree-archive/<tid>` exists in the project repo.
bool hasArchiveRef(string projectPath, int tid)
{
    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);
    auto result = execute(["git", "-C", projectPath, "rev-parse", "--verify", refName]);
    return result.status == 0;
}

/// Save dirty worktree state into a custom ref chain and remove the worktree.
///
/// Creates up to 3 layered commits on top of the worktree's current HEAD:
///   base → [cydo:archive:staged] → [cydo:archive:modified] → [cydo:archive:untracked]
/// Only layers with actual changes are created. The final SHA is stored as
/// refs/cydo/worktree-archive/<tid>, then the worktree directory is removed.
///
/// Returns true on success, false on failure (errors logged via std.logger).
/// Idempotent: no-op if the archive ref already exists.
bool archiveWorktree(string worktreePath, string projectPath, int tid)
{
    if (hasArchiveRef(projectPath, tid))
    {
        infof("archiveWorktree: ref already exists for tid=%d, skipping", tid);
        return true;
    }

    // Get current HEAD
    auto headResult = execute(["git", "-C", worktreePath, "rev-parse", "HEAD"]);
    if (headResult.status != 0)
    {
        errorf("archiveWorktree: rev-parse HEAD failed for tid=%d: %s", tid, headResult.output);
        return false;
    }
    string currentHead = headResult.output.strip();

    // Layer 1: staged changes (index differs from HEAD)
    auto stagedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet"]);
    if (stagedDiff.status != 0)
    {
        auto treeResult = execute(["git", "-C", worktreePath, "write-tree"]);
        if (treeResult.status != 0)
        {
            errorf("archiveWorktree: write-tree (staged) failed for tid=%d: %s", tid, treeResult.output);
            return false;
        }
        auto commitResult = execute(["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:staged]"]);
        if (commitResult.status != 0)
        {
            errorf("archiveWorktree: commit-tree (staged) failed for tid=%d: %s", tid, commitResult.output);
            return false;
        }
        currentHead = commitResult.output.strip();
    }

    // Layer 2: unstaged tracked modifications
    execute(["git", "-C", worktreePath, "add", "-u"]);
    auto modifiedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet", currentHead]);
    if (modifiedDiff.status != 0)
    {
        auto treeResult = execute(["git", "-C", worktreePath, "write-tree"]);
        if (treeResult.status != 0)
        {
            errorf("archiveWorktree: write-tree (modified) failed for tid=%d: %s", tid, treeResult.output);
            return false;
        }
        auto commitResult = execute(["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:modified]"]);
        if (commitResult.status != 0)
        {
            errorf("archiveWorktree: commit-tree (modified) failed for tid=%d: %s", tid, commitResult.output);
            return false;
        }
        currentHead = commitResult.output.strip();
    }

    // Layer 3: untracked files
    execute(["git", "-C", worktreePath, "add", "-A"]);
    auto untrackedDiff = execute(["git", "-C", worktreePath, "diff", "--cached", "--quiet", currentHead]);
    if (untrackedDiff.status != 0)
    {
        auto treeResult = execute(["git", "-C", worktreePath, "write-tree"]);
        if (treeResult.status != 0)
        {
            errorf("archiveWorktree: write-tree (untracked) failed for tid=%d: %s", tid, treeResult.output);
            return false;
        }
        auto commitResult = execute(["git", "-C", worktreePath, "commit-tree",
            treeResult.output.strip(), "-p", currentHead, "-m", "[cydo:archive:untracked]"]);
        if (commitResult.status != 0)
        {
            errorf("archiveWorktree: commit-tree (untracked) failed for tid=%d: %s", tid, commitResult.output);
            return false;
        }
        currentHead = commitResult.output.strip();
    }

    // Store archive ref
    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);
    auto updateRefResult = execute(["git", "-C", projectPath, "update-ref", refName, currentHead]);
    if (updateRefResult.status != 0)
    {
        errorf("archiveWorktree: update-ref failed for tid=%d: %s", tid, updateRefResult.output);
        return false;
    }

    // Remove the worktree
    auto removeResult = execute(["git", "-C", projectPath, "worktree", "remove", "--force", worktreePath]);
    if (removeResult.status != 0)
    {
        errorf("archiveWorktree: worktree remove failed for tid=%d: %s", tid, removeResult.output);
        // Clean up ref since worktree removal failed
        execute(["git", "-C", projectPath, "update-ref", "-d", refName]);
        return false;
    }

    infof("archiveWorktree: archived tid=%d at %s", tid, refName);
    return true;
}

/// Restore a worktree from the archive ref, recreating all dirty state.
///
/// Reads the commit chain stored at refs/cydo/worktree-archive/<tid>, recreates
/// the worktree at the base commit, then unrolls each layer: staged files to the
/// index, modified files to the working tree, untracked files to the filesystem.
/// Deletes the archive ref after successful restoration.
///
/// Returns true on success, false on failure (errors logged via std.logger).
/// Idempotent: no-op if the worktree directory already exists.
bool unarchiveWorktree(string projectPath, int tid, string worktreePath)
{
    import std.file : exists;

    if (exists(worktreePath))
    {
        infof("unarchiveWorktree: worktree already exists for tid=%d, skipping", tid);
        return true;
    }

    auto refName = format!"refs/cydo/worktree-archive/%d"(tid);

    // Get the tip SHA stored in the archive ref
    auto tipResult = execute(["git", "-C", projectPath, "rev-parse", refName]);
    if (tipResult.status != 0)
    {
        errorf("unarchiveWorktree: rev-parse ref failed for tid=%d: %s", tid, tipResult.output);
        return false;
    }
    string tipSha = tipResult.output.strip();

    // Walk at most 4 commits (3 archive layers + base)
    auto logResult = execute(["git", "-C", projectPath, "log",
        "--max-count=4", "--format=%H%n%s", tipSha]);
    if (logResult.status != 0)
    {
        errorf("unarchiveWorktree: git log failed for tid=%d: %s", tid, logResult.output);
        return false;
    }

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
    {
        errorf("unarchiveWorktree: could not find base commit for tid=%d", tid);
        return false;
    }

    // Recreate the worktree at the base commit
    auto addResult = execute(["git", "-C", projectPath, "worktree", "add",
        "--detach", worktreePath, baseSha]);
    if (addResult.status != 0)
    {
        errorf("unarchiveWorktree: worktree add failed for tid=%d: %s", tid, addResult.output);
        return false;
    }

    // Restore staged layer: set index to staged tree, check out files to working tree
    if (stagedSha.length > 0)
    {
        auto readTreeResult = execute(["git", "-C", worktreePath,
            "read-tree", stagedSha ~ "^{tree}"]);
        if (readTreeResult.status != 0)
        {
            errorf("unarchiveWorktree: read-tree staged failed for tid=%d: %s", tid, readTreeResult.output);
            return false;
        }
        auto checkoutResult = execute(["git", "-C", worktreePath, "checkout-index", "-a", "-f"]);
        if (checkoutResult.status != 0)
        {
            errorf("unarchiveWorktree: checkout-index failed for tid=%d: %s", tid, checkoutResult.output);
            return false;
        }
    }

    // Restore modified layer: apply diff to working tree only (leaves index unchanged)
    if (modifiedSha.length > 0)
    {
        string modifiedParent = stagedSha.length > 0 ? stagedSha : baseSha;
        auto diffResult = execute(["git", "-C", worktreePath, "diff",
            modifiedParent ~ ".." ~ modifiedSha]);
        if (diffResult.status != 0)
        {
            errorf("unarchiveWorktree: diff (modified) failed for tid=%d: %s", tid, diffResult.output);
            return false;
        }
        if (diffResult.output.length > 0)
        {
            auto applyPipes = pipeProcess(["git", "-C", worktreePath, "apply"], Redirect.stdin);
            applyPipes.stdin.write(diffResult.output);
            applyPipes.stdin.close();
            auto applyStatus = wait(applyPipes.pid);
            if (applyStatus != 0)
            {
                errorf("unarchiveWorktree: git apply failed for tid=%d", tid);
                return false;
            }
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
        {
            errorf("unarchiveWorktree: diff-tree failed for tid=%d: %s", tid, diffTreeResult.output);
            return false;
        }

        import std.file : mkdirRecurse, write;
        import std.string : split;
        auto files = diffTreeResult.output.split("\0").filter!(f => f.length > 0).array;
        foreach (file; files)
        {
            auto showResult = execute(["git", "-C", projectPath, "show",
                untrackedSha ~ ":" ~ file]);
            if (showResult.status != 0)
            {
                errorf("unarchiveWorktree: git show failed for '%s' in tid=%d: %s",
                    file, tid, showResult.output);
                return false;
            }
            auto filePath = buildPath(worktreePath, file);
            mkdirRecurse(dirName(filePath));
            write(filePath, showResult.output);
        }
    }

    // Delete the archive ref
    execute(["git", "-C", projectPath, "update-ref", "-d", refName]);

    infof("unarchiveWorktree: restored tid=%d at %s", tid, worktreePath);
    return true;
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
    bool ok = archiveWorktree(wtDir, repoDir, 42);
    assert(ok, "archiveWorktree failed");

    // Worktree directory should be gone
    assert(!exists(wtDir), "worktree should be removed after archive");

    // Archive ref should exist
    assert(hasArchiveRef(repoDir, 42), "archive ref should exist");

    // Unarchive the worktree
    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 42, wtDir2);
    assert(ok2, "unarchiveWorktree failed");

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
    bool ok = archiveWorktree(wtDir, repoDir, 99);
    assert(ok, "archiveWorktree (clean) failed");
    assert(!exists(wtDir));
    assert(hasArchiveRef(repoDir, 99));

    // Unarchive
    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 99, wtDir2);
    assert(ok2, "unarchiveWorktree (clean) failed");
    assert(exists(wtDir2) && isDir(wtDir2));

    // HEAD should be same as original
    auto headResult2 = execute(["git", "-C", wtDir2, "rev-parse", "HEAD"]);
    assert(headResult2.output.strip() == originalHead, "HEAD should match original after clean round-trip");

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

    bool ok = archiveWorktree(wtDir, repoDir, 11);
    assert(ok);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 11, wtDir2);
    assert(ok2);

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

    bool ok = archiveWorktree(wtDir, repoDir, 22);
    assert(ok);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 22, wtDir2);
    assert(ok2);

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

    bool ok = archiveWorktree(wtDir, repoDir, 33);
    assert(ok);
    assert(!exists(wtDir));

    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 33, wtDir2);
    assert(ok2);

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
    bool ok = archiveWorktree(wtDir, repoDir, 66);
    assert(ok, "first archiveWorktree should succeed");
    assert(!exists(wtDir));
    assert(hasArchiveRef(repoDir, 66));

    // Second archive: ref already exists → no-op, returns true
    // The worktree is already gone; archiveWorktree checks hasArchiveRef first.
    bool ok2 = archiveWorktree(wtDir, repoDir, 66);
    assert(ok2, "second archiveWorktree should be a no-op returning true");
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

    bool ok = archiveWorktree(wtDir, repoDir, 55);
    assert(ok);

    // First unarchive
    auto wtDir2 = buildPath(repoDir, "wt2");
    bool ok2 = unarchiveWorktree(repoDir, 55, wtDir2);
    assert(ok2, "first unarchive should succeed");

    // Second unarchive: worktree exists → no-op, returns true
    bool ok3 = unarchiveWorktree(repoDir, 55, wtDir2);
    assert(ok3, "second unarchive should be a no-op returning true");
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
