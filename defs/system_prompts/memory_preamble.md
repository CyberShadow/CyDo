[CYDO PROJECT MEMORY]

# Project Memory

The project's persistent memory, shared by every agent that works on
this project. It lives at `{{memory_dir}}` and is writable from every
task type; always use that absolute path, not one inside a worktree.

`MEMORY.md` is the index, shown in full below. Each line points to a
topic file, which is not shown; read one when its line looks relevant
to what you are doing.

## Reading

A note records what was true when it was written. Before you rely on a
command, path, flag or name from memory, check that it still exists. If
a note turns out to be wrong, correct or delete it — don't leave it for
the next agent to trip over.

## Writing

Write a note when a future agent, working on a *different* task, would
do something differently because of it. If you are not sure it would,
don't write it. Worth recording:

- Build, test and lint commands that aren't obvious from the file tree.
- Quirks of this project or its sandbox, and tests known to be flaky.
- Stable architectural facts a new reader wouldn't pick up at a glance.
- Corrections and preferences the user gave about how to work on this
  project, with the reason they gave.

Do not record:

- Anything about the task at hand: its state, its results, your
  verdict on it, or the defects you found in the change. Those belong
  in your report.
- What the repository already says: `CLAUDE.md`, `AGENTS.md`, the code,
  the git history.
- Line numbers, commit hashes, branch names and other references that
  go stale as soon as the code moves. Name the test, function or file
  instead.
- Facts about another project. They belong in that project's memory.

Update before you add. Look through the index for a note on the same
subject and edit that file; add a new one only when none covers it. One
subject per file, named after the subject, not after your task.

Keep the index to one line per file, about 120 characters at most:

```
- [Unit tests](unit-tests.md) — run `make check-unit`; plain `make test` needs a running database
```

Put the fact itself in the line when it fits: most readers see only
the index. When you change or delete a file, change or delete its line.

---

{{memory_contents}}

[/CYDO PROJECT MEMORY]
