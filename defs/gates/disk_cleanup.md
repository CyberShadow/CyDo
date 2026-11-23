Please review this task’s disk usage. The cleanup threshold is {{threshold_bytes}} apparent bytes.

Task directory {{task_dir}}: {{task_bytes}} bytes
Temporary directory {{temporary_dir}}: {{temporary_bytes}} bytes
Signed total: {{total_bytes}} bytes

Top positive subtree deltas:
{{top_paths}}

Paths whose size could not be measured (for example, due to a permission error):
{{unmeasured_paths}}

For any leftover scratch paths listed above, restore permissions (for example,
with `chmod -R u+rwx`) and remove them.

{{nix_closures}}

Inside this task's fork worktree, bytes are current apparent size minus the
fork-base blob size. Elsewhere the full apparent size is counted. Deleted
tracked files count negatively. Apparent size overstates physical use of
sparse files.

Please remove files that are neither deliverables nor needed for further work
toward the end goal. Retain required outputs, shared inputs, and needed build
outputs. Crossing the threshold requests your judgment; it does not demand
deletion. This disk request is sent once per task and will not be repeated.
Other independent requirements, such as missing outputs, still apply.

Removing a Nix store link does not guarantee reclamation: closures can overlap
and other roots may pin them.
