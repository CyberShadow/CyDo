Your worktree {{worktree_path}} is assigned the branch `{{branch}}`, but it is
on {{head}}. Other tasks and the integrator find your work through
`{{branch}}`, so please put the worktree back on it before finishing.

If the current HEAD holds the work that belongs on the branch,
`git switch -C {{branch}}` moves the branch here and switches to it.
Otherwise bring the work onto `{{branch}}` first, then `git switch {{branch}}`.

This request is sent once per task and will not be repeated.
