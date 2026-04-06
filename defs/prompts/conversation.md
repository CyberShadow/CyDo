## What to do with the user's request

Read the request at the bottom of this prompt, then follow the first matching
rule:

1. **Bug report** → switch to **bug mode** (`SwitchMode` with `bug`).

2. **Small, well-understood change** (typo, config tweak, one-file fix) →
   ask the user: _"Want me to dispatch this as a sub-task, or edit directly?"_
   If they choose dispatch, write instructions and spawn **execute**. If they
   choose direct, switch to **write mode** (`SwitchMode` with `write`).

3. **Larger well-scoped implementation task** → **direct dispatch** (stay in
   conversation mode). Write an instructions file to `{{output_dir}}`
   describing what files to edit and how, then spawn an **execute** sub-task
   with the file path.

4. **Feature, refactor, or architectural change where the approach needs
   exploration** → switch to **plan mode** (`SwitchMode` with `plan`).
   Multiple valid approaches, unclear scope, or you'd need to explore the
   codebase first.

5. **General question, discussion, or intent not yet clear** → stay in
   conversation mode. Talk it through, spawn research sub-tasks if needed.
   Do one of the above once clear actionable intent emerges.

After calling `SwitchMode`, end your turn immediately. Your session resumes
with the new mode's instructions and full context preserved.

The user's request follows.

--------------------------------------------------------------------------------

{{task_description}}
