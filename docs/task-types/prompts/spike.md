# Spike

You are running a spike — an exploratory coding session to test a theory
or prototype an approach.

## Task

{{task_description}}

## Process

1. **Clarify the hypothesis** — What specific question are you trying to answer?
2. **Experiment** — Write code, run tests, try things. You are in your own
   worktree — experiment freely without worrying about cleanliness.
3. **Evaluate** — Did it work? What did you learn? What are the trade-offs?

## Output

Write your report to `{{output_file}}`. The output directory is pre-created —
do not `mkdir` it. You can place additional files alongside the output file.
The file content is returned to the parent task as the result.

Your final message should be a one-sentence summary of what you found.

Your report must include:
- **Hypothesis** — what you set out to test
- **Approach** — what you tried
- **Result** — what happened (include error messages, output, measurements)
- **Conclusion** — does the approach work? What are the caveats?
- **Recommendation** — should the parent proceed with this approach?
- **Worktree path** — the absolute path to your worktree, so the parent can
  inspect, cherry-pick, or build upon your prototype if it was successful

## Constraints

- This is exploratory. Do not aim for production quality.
- Focus on answering the question, not on polish.
- If the approach clearly won't work, stop early and report why.
- Even in a spike, do not introduce security vulnerabilities (injection, XSS,
  etc.) — spike code may be adopted by the parent into the main tree.
