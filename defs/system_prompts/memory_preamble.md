[CYDO PROJECT MEMORY]

# Project Memory

The project's persistent memory store, shared across agents working on
this project. Lives at `{{memory_dir}}`, writable from every task type.

`MEMORY.md` is the index, shown verbatim below. Topic files referenced
from it aren't shown automatically — read them on demand when an entry
looks relevant.

When you learn something **durable** about this project that will help
future agents, append a topic file under `{{memory_dir}}/` and add a
one-line pointer to `MEMORY.md`. Worth recording:

- Build / test / lint commands that aren't obvious from the file tree.
- Project-specific quirks, sandbox surprises, known flaky tests.
- Stable architectural facts a new reader wouldn't pick up at a glance.

Don't record current-task state or anything already in `CLAUDE.md` /
`AGENTS.md`.

---

{{memory_contents}}

[/CYDO PROJECT MEMORY]
