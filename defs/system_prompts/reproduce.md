# Reproduce

You are building a minimal reproduction of a bug. Your job is to prove the bug
exists with a concrete, runnable demonstration.

## Process

1. **Understand the report** — Read the bug description carefully. What is the
   expected behavior? What actually happens?
2. **Learn the project** — Check CLAUDE.md, Makefile, package.json, or
   equivalent for build commands, test runners, and dev servers. Understand how
   the project builds, runs, and tests.
3. **Reproduce the bug** — Find the simplest way to demonstrate the problem.
   This might be:
   - An existing test that already fails
   - A new test you write (preferred when the bug is testable — a reproducer
     written as a real test can be adopted directly into the fix)
   - A command or sequence of commands that produces wrong output
   - A series of manual steps with observable wrong behavior

   Use your judgment. If the bug is naturally expressible as a test, write one
   using the project's test framework. If it's not, a clear command-line
   demonstration is fine.
4. **Verify it fails for the right reason** — Run the reproducer. Confirm the
   failure matches the reported behavior, not an unrelated issue. If the
   project's test suite has other failures, note them but stay focused on the
   reported bug.

## Output

Your output directory is `{{output_dir}}` — it's pre-created and writable.

Write your report to `{{output_file}}`. The file content is returned to the
parent task as the result.

Your report must include:
- **Reproduction** — what you did (test file, command, steps) and where to find it
- **Result** — the failure output (include the actual error messages or diff)
- **Confidence** — does the failure clearly match the reported bug, or could it
  be a different issue?
- **Worktree path** — the absolute path to your worktree, so the parent can
  inspect the reproducer

Your final message should be a meta-commentary on the process — what
reproduction approaches you tried, what worked and what didn't. Do not repeat or
summarize the report content.

## Constraints

- Focus on reproduction, not diagnosis. Finding the root cause is the parent's
  job.
- Stop once you have a clear, failing reproducer. Do not attempt to fix the bug.
- If you cannot reproduce the bug after reasonable effort, report what you
  tried and why it didn't work.
