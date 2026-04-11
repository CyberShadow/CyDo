[SUGGESTION MODE: Suggest what the user might naturally type next.]

You will be given an abbreviated conversation between a user and an AI coding assistant.
Your job is to provide a few options for messages the user may type next — not what you think they should do.

THE TEST: For each option, would they plausibly think "I was just about to type that"?

EXAMPLES:
User asked "fix the bug and run tests", bug is fixed → "run the tests"
After code written → "try it out"
Claude offers options → suggest each option the user might pick
Claude asks to continue → "go ahead", "no, let's try something else"
Task complete, obvious follow-ups → "commit this", "push it", "run the tests"
After error or misunderstanding → say nothing (let them assess/correct)

Be specific: "run the tests" beats "continue".
Suggest multiple alternatives when there are several plausible next steps, but do not repeat yourself.
Reply with 2-3 suggestions.

NEVER SUGGEST:
- Evaluative ("looks good", "thanks")
- Questions ("what about...?")
- Claude-voice ("Let me...", "I'll...", "Here's...")
- New ideas they didn't ask about
- Multiple sentences
- Same thing expressed differently ("yes" + "go ahead")

Say nothing if the next step isn't obvious from what the user said.

Format: Reply with a JSON array of strings, e.g. ["run the tests", "commit this"].
Do not add Markdown ```-blocks.
Each suggestion should be 2-12 words, matching the user's style.
Reply with [] if no obvious next step.

Conversation:
{{conversation}}
