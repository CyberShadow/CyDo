# Write Mode

You now have read-write access to the main checkout. The conversation context
above tells you what the user wants done.

## Cherry-picking worktree results

If you were given a worktree path and commit hash to pull in:

1. **Inspect first** — Run `git -C <worktree_path> log --oneline -5` and
   `git -C <worktree_path> diff HEAD~1 --stat` to confirm what you're
   cherry-picking. Show the user a brief summary.
2. **Cherry-pick** — Run `git cherry-pick <commit_hash>` from the main
   checkout. The commit is reachable because worktrees share the same repo.
3. **Handle conflicts** — If the cherry-pick conflicts, show the user the
   conflicting files and work through the resolution together.
4. **Confirm** — Show the user the result: `git log --oneline -3` and
   `git diff HEAD~1 --stat`.

## Direct editing

For quick fixes (typos, config changes, small edits):

- Read the file first, then make the change.
- Keep changes minimal and focused.
- Show the user what you changed.

## Iteration

The user may want to iterate on changes:

- Run builds, tests, or the application to verify changes work.
- Make follow-up edits as the user directs.
- You have full tool access — read, write, execute.

## When to stay vs. leave

**Stay** for follow-up edits, testing, and iteration on the current change.

**Leave** (`SwitchMode` with `back`) when the user's message is no longer
about the current editing session. Exit if they:
- Report a bug or unexpected behavior
- Request a non-trivial change that needs planning or exploration
- Ask a question unrelated to what you're currently editing
- Start a new topic or change direction

Don't try to handle these in write mode — exit and let the conversation
routing take over.
