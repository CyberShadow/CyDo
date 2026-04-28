// Shared pattern matching module for mock API servers.
// Imported by server.mjs (Claude/Codex) and copilot-proxy.mjs (Copilot).

// Match a user text against known patterns and return a structured intent.
// Returns one of:
//   { type: "text", text: string }
//   { type: "shell", command: string }
//   { type: "background_shell", command: string }
//   { type: "tool_call", name: string, input: object }
//   { type: "stall" }  — keep the LLM connection open indefinitely (for kill tests)
export function matchPattern(userText) {
  // Suggestion generation — must be checked before other patterns
  // because the prompt contains abbreviated history that may match them.
  // Uses includes() because Copilot prepends <current_datetime>...</current_datetime>
  // before the actual content, so startsWith() would fail.
  if (userText.includes("[SUGGESTION MODE:")) {
    if (process.env.MOCK_SUGGESTIONS) {
      return { type: "text", text: process.env.MOCK_SUGGESTIONS };
    }
    // Extract the [Session: ...] header so tests can assert on its content.
    const headerMatch = userText.match(/\[Session: [^\]]*\]/);
    const header = headerMatch ? headerMatch[0] : "no session header";
    // Extract the conversation body (everything after "Conversation:\n")
    // so tests can assert on assistant entries (A: ...) too.
    const convStart = userText.indexOf("Conversation:\n");
    const convBody =
      convStart >= 0
        ? userText.slice(convStart + "Conversation:\n".length).trim()
        : "";
    return {
      type: "text",
      text: JSON.stringify(["run the tests", header, convBody]),
    };
  }

  // Title generation subprocess — extract a recognizable title from the prompt.
  // Uses includes() for the same reason as SUGGESTION MODE above.
  if (userText.includes("Generate a concise title")) {
    const innerMatch = userText.match(/reply with "([^"]*)"/i);
    return { type: "text", text: innerMatch ? innerMatch[1] : "Test Task" };
  }

  // [SYSTEM: Follow-up question from parent task (qid=N)] — backend wraps Ask
  // messages in SYSTEM tags. Extract qid from the subject and respond with Answer.
  {
    let m = userText.match(
      /\[SYSTEM: Follow-up question from parent task \(qid=(\d+)\)\][\s\S]*deferred-test/,
    );
    if (m)
      return {
        type: "multi_tool_call",
        tool_calls: [
          {
            name: "mcp__cydo__Answer",
            input: { qid: parseInt(m[1]), message: "deferred-answer-result" },
          },
          {
            name: "Bash",
            input: {
              command: "echo post-answer-work",
              description: "Post-answer work",
            },
          },
        ],
      };
    m = userText.match(
      /\[SYSTEM: Follow-up question from parent task \(qid=(\d+)\)\]/,
    );
    if (m)
      return {
        type: "tool_call",
        name: "mcp__cydo__Answer",
        input: { qid: parseInt(m[1]), message: "follow-up-answered" },
      };
  }

  // [SYSTEM: Task prompt / Session start / Mode switch / Handoff] wraps
  // executable content. Extract the body and re-match so task-level patterns
  // (call task, reply with, stall, etc.) remain visible to the mock.
  // Newer CyDo builds encode label detail in the subject:
  //   [SYSTEM: Task prompt: <task_type>]
  //   [SYSTEM: Session start: <entry_point_or_task_type>]
  //   [SYSTEM: Mode switch: <task_type>]
  //   [SYSTEM: Handoff: <task_type>]
  // Keep matching both legacy and subject-encoded forms.
  // No ^ or $ anchors: Copilot prepends <current_datetime> before the tag.
  // \n{2,} before [/SYSTEM]: the body may end with a trailing newline from
  // the prompt template, producing three newlines before the closing tag.
  {
    const m = userText.match(
      /\[SYSTEM: (?:(?:Task prompt|Session start|Mode switch|Handoff)(?:: [^\]\n]+)?)\]\n\n([\s\S]*)\n{2,}\[\/SYSTEM\]/,
    );
    if (m) {
      if (process.env.MOCK_STALL_SYSTEM) return { type: "stall" };
      return matchPattern(m[1]);
    }
  }

  // [SYSTEM: Sub-task "..." (tid=N) is waiting for your answer (qid=M)]
  // When the body contains "switch-mode-question", this is the post-SwitchMode reminder
  // from the switchmode-after-child-asks fixture. Extract qid and answer.
  {
    const m = userText.match(
      /\[SYSTEM: Sub-task "[^"]*" \(tid=\d+\) is waiting for your answer \(qid=(\d+)\)\][\s\S]*switch-mode-question/,
    );
    if (m)
      return {
        type: "tool_call",
        name: "mcp__cydo__Answer",
        input: { qid: parseInt(m[1]), message: "switch-mode-answer" },
      };
  }

  // Backend restart nudge and other system injections — acknowledge with Done.
  // Uses includes() for the same reason as SUGGESTION MODE above.
  // When MOCK_STALL_SYSTEM is set, stall instead (for screenshot chain tasks).
  if (userText.includes("[SYSTEM:")) {
    if (process.env.MOCK_STALL_SYSTEM) return { type: "stall" };
    return { type: "text", text: "Done." };
  }

  let match;

  // Task-creation patterns must come before "reply with" and "run command"
  // because a task prompt like "call task research reply with X" contains
  // "reply with" as a substring, which would otherwise match first.
  // "call task" (singular) must come before "call N tasks" (plural) so that
  // nested prompts like "call task X call 2 tasks Y Z" match correctly.

  // Codex file-viewer deterministic fixtures
  // Keep these before broad "call task ..." matching because codex prompts
  // include instruction text that can otherwise shadow these fixtures.
  if (/codex filechange create fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Add File: tmp/codex-fileviewer-create.txt\n+hello from create fixture\n*** End Patch\n",
      },
    };
  }
  if (/codex filechange update fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Update File: tmp/codex-fileviewer-create.txt\n@@\n-hello from create fixture\n+hello from update fixture\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown partial first hunk fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Update File: tmp/codex-rendered-fragments.md\n@@ -1,3 +1,3 @@\n # Existing title\n-old first paragraph\n+first collected fragment\n keep line\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown partial second hunk fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Update File: tmp/codex-rendered-fragments.md\n@@ -20,3 +20,3 @@\n ## Existing later section\n-old second paragraph\n+second collected fragment\n keep later line\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown add fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Add File: tmp/codex-inline-preview.md\n+# Inline Preview\n+\n+This is **markdown** from Codex.\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown update fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Update File: tmp/codex-inline-preview.md\n@@ -1,3 +1,3 @@\n-# Inline Preview\n+# Inline Preview Updated\n \n-This is **markdown** from Codex.\n+This is **updated markdown** from Codex.\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown ambiguous fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Update File: tmp/codex-inline-preview.md\n@@ -1,1 +1,1 @@\n*broken-line\n*** End Patch\n",
      },
    };
  }
  if (/codex markdown mixed multi-file fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Add File: tmp/multi-preview.md\n+# Multi Markdown\n+\n+first paragraph\n*** Update File: tmp/multi-preview.txt\n@@ -1 +1 @@\n-old text\n+new text\n*** End Patch\n",
      },
    };
  }
  if (/codex filechange delete fixture/i.test(userText)) {
    return {
      type: "tool_call",
      name: "apply_patch",
      input: {
        input:
          "*** Begin Patch\n*** Delete File: tmp/codex-fileviewer-create.txt\n*** End Patch\n",
      },
    };
  }

  // "call task <type> <prompt>" → MCP Task tool call (create sub-task)
  // Checked before "call N tasks" so "call task X call 2 tasks Y Z" nests correctly.
  match = userText.match(/call task (\S+) (.*)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: match[1].trim(),
            prompt: match[2].trim(),
            description: "Test task",
          },
        ],
      },
    };

  // "call N tasks <type> <prompt>" → MCP Task tool call (create multiple sub-tasks)
  match = userText.match(/call (\d+) tasks (\S+) (.*)/is);
  if (match) {
    const count = parseInt(match[1]);
    const type = match[2].trim();
    const prompt = match[3].trim();
    const tasks = [];
    for (let i = 0; i < count; i++) {
      tasks.push({
        task_type: type,
        prompt,
        description: `Test task ${i + 1}`,
      });
    }
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: { tasks },
    };
  }

  // "call ask <tid> <message>" → Ask with specific tid
  // Must come before "call ask <message>" to avoid capturing tid as message text.
  match = userText.match(/call ask (\d+) (.+)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Ask",
      input: { message: match[2].trim(), tid: parseInt(match[1]) },
    };

  // "call ask <message>" → Ask parent (no tid)
  match = userText.match(/call ask (.+)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Ask",
      input: { message: match[1].trim() },
    };

  // "call answer <qid> <message>" → Answer a question
  match = userText.match(/call answer (\d+) (.+)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Answer",
      input: { qid: parseInt(match[1]), message: match[2].trim() },
    };

  // (Follow-up from parent patterns handled above, before the [SYSTEM:] check.)

  // "call mixed batch <type>" → two tasks with different behavior
  match = userText.match(/call mixed batch (\S+)/i);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: match[1],
            prompt: 'reply with "normal-child-done"',
            description: "Normal child",
          },
          {
            task_type: match[1],
            prompt: "call ask what approach should I use?",
            description: "Questioning child",
          },
        ],
      },
    };

  // "call active-child-test" → one stalling child + one questioning child
  if (/call active-child-test/i.test(userText))
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: "stall session",
            description: "Stalling child",
          },
          {
            task_type: "research",
            prompt: "call ask am I doing this right?",
            description: "Questioning child",
          },
        ],
      },
    };

  // "call busy-child-test" → two children:
  //   - child A (tid+1): creates a grandchild that stalls → becomes "waiting"
  //   - child B (tid+2): asks parent → makes parent's Task return early
  // The grandchild gets the next tid after both children are allocated.
  if (/call busy-child-test/i.test(userText))
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: "call task research stall session",
            description: "Busy child",
          },
          {
            task_type: "research",
            prompt: "call ask any updates?",
            description: "Helper child",
          },
        ],
      },
    };

  // "call partial-restart-batch" → two children with staggered completion:
  //   - child A completes quickly before the backend restart
  //   - child B is still running at restart time and completes after recovery
  if (/call partial-restart-batch/i.test(userText))
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: 'reply with "first-child-done"',
            description: "Fast child",
          },
          {
            task_type: "research",
            prompt: "run command sleep 20 && echo second-child-done",
            description: "Slow child",
          },
        ],
      },
    };

  // "spawn task <prompt>" → Claude's built-in Task tool (triggers native sub-agent)
  match = userText.match(/spawn task (.*)/is);
  if (match)
    return {
      type: "tool_call",
      name: "Task",
      input: {
        description: "test subtask",
        prompt: match[1].trim(),
        subagent_type: "general-purpose",
      },
    };

  // "check context contains <base64>" — check if decoded string appears in request
  match = userText.match(/check context contains ([A-Za-z0-9+/]+=*)/i);
  if (match) return { type: "check_context", needle: match[1] };

  // "check user text contains <base64>" — check if decoded string appears in
  // the final user message text itself (proves prompt text arrived via input).
  match = userText.match(/check user text contains ([A-Za-z0-9+/]+=*)/i);
  if (match)
    return { type: "check_user_text", needle: match[1] };

  // Autonomous compaction reminder fixture: force a SwitchMode tool call with
  // a huge token count so the follow-up keep-context continuation compacts
  // without any additional user message.
  if (/autonomous compaction reminder fixture/i.test(userText))
    return { type: "autonomous_compaction_switchmode" };

  // Decompose continuation fixture: if the resumed keep-context prompt uses the
  // strengthened decompose handoff instructions, dispatch a deterministic
  // sub-task.
  if (
    userText.includes("`SwitchMode` to `decompose` succeeded.") &&
    userText.includes("You are already in decompose mode.") &&
    userText.includes("Do not re-run triage")
  ) {
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: 'reply with "decompose-child-created"',
            description: "Decompose child",
          },
        ],
      },
    };
  }

  // "semantic shell cat <path>" — run cat on a file for semantic shell tests
  match = userText.match(/semantic shell cat (\S+)/i);
  if (match) return { type: "shell", command: `cat ${match[1]}` };

  // "semantic shell nl <path>" — run nl on a file
  match = userText.match(/semantic shell nl (\S+)/i);
  if (match) return { type: "shell", command: `nl -ba ${match[1]}` };

  // "semantic shell heredoc" — cat heredoc writing markdown
  if (/semantic shell heredoc/i.test(userText))
    return {
      type: "shell",
      command:
        "cat > /tmp/test-output.md <<EOF\n# Hello World\n\nThis is **markdown** content.\nEOF",
    };

  // "semantic shell pipe read <path>" — pipe that SHOULD get semantic rendering
  match = userText.match(/semantic shell pipe read (\S+)/i);
  if (match) return { type: "shell", command: `cat ${match[1]} | head -5` };

  // "semantic shell pipe reject <path>" — pipe with unrecognized stage (should NOT get semantic rendering)
  match = userText.match(/semantic shell pipe reject (\S+)/i);
  if (match) return { type: "shell", command: `cat ${match[1]} | rm -rf /` };

  // Legacy: "semantic shell pipe <path>" — keep for backwards compatibility
  match = userText.match(/semantic shell pipe (\S+)/i);
  if (match) return { type: "shell", command: `cat ${match[1]} | rm -rf /` };

  // "semantic shell diff" — git log -p for semantic diff rendering tests
  if (/semantic shell diff/i.test(userText))
    return { type: "shell", command: "git log -p -1 --no-color -- README.md" };

  // "semantic shell script" — heredoc Python script for semantic script-exec tests
  if (/semantic shell script/i.test(userText))
    return {
      type: "shell",
      command:
        "python3 - <<PY\nimport json\nprint(json.dumps({\"result\": 42}))\nPY",
    };

  // Compatibility fixture: JSON-looking final text should remain literal
  // summary text instead of being reparsed as a nested CyDo result object.
  if (/reply with json-summary-fixture/i.test(userText)) {
    return {
      type: "text",
      text: '{"qid":3,"message":"**Summary**\\n\\nHello"}',
    };
  }

  match = userText.match(/reply with "([^"]*)"/i);
  if (match) return { type: "text", text: match[1] };

  // "stall session" → keep LLM connection open without completing
  if (/stall session/i.test(userText)) return { type: "stall" };

  // "run parallel commands" — two parallel tool_use blocks in a single response
  match = userText.match(/run parallel commands/i);
  if (match)
    return { type: "parallel_shell", commands: ["echo one", "echo two"] };

  // "run quick-yield command <cmd>" — exec_command with yield_time_ms=1
  // (must come before "run background command" to avoid substring match)
  match = userText.match(/run quick-yield command (.+)/i);
  if (match) return { type: "quick_yield_shell", command: match[1].trim() };

  // "run two background commands" — two sequential exec_command with yield_time_ms
  // (must come before single "run background command" to avoid substring match)
  match = userText.match(/run two background commands/i);
  if (match) return { type: "background_shell", command: "sleep 8" };

  // "run background command <cmd>" — exec_command with short yield_time_ms
  match = userText.match(/run background command (.+)/i);
  if (match) return { type: "background_shell", command: match[1].trim() };

  // "run command with timeout <N> <cmd>" — Bash tool call with timeout_ms
  match = userText.match(/run command with timeout (\d+) (.+)/i);
  if (match)
    return {
      type: "timed_shell",
      command: match[2].trim(),
      timeout: parseInt(match[1]),
    };

  // "run command <cmd>"
  match = userText.match(/run command (.+)/i);
  if (match) return { type: "shell", command: match[1].trim() };

  // "edit file <path> replace <old> with <new>"
  match = userText.match(/edit file (\S+) replace (.+?) with (.+)/i);
  if (match)
    return {
      type: "tool_call",
      name: "Edit",
      input: {
        file_path: match[1],
        old_string: match[2],
        new_string: match[3],
      },
    };

  // "create file <path> with content <text>"
  match = userText.match(/create file (\S+) with content (.+)/is);
  if (match)
    return {
      type: "tool_call",
      name: "write_file",
      input: { path: match[1], content: match[2] },
    };

  // "read file <path>"
  match = userText.match(/read file (\S+)/i);
  if (match)
    return { type: "tool_call", name: "read_file", input: { path: match[1] } };

  // "handoff while child asks" — create a research child that calls Ask,
  // then the parent tries Handoff (which should be rejected with a pending-question error).
  // The multi-step handler in server.mjs returns Handoff on the first tool_result,
  // then Answer after the rejection.
  if (/handoff while child asks/i.test(userText))
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: "call ask handoff-test-question",
            description: "Asking child",
          },
        ],
      },
    };

  // "switchmode after child asks" — create a research child that calls Ask,
  // then the parent calls SwitchMode (reproduces the pending-question + mode-switch bug).
  if (/switchmode after child asks/i.test(userText))
    return {
      type: "tool_call",
      name: "mcp__cydo__Task",
      input: {
        tasks: [
          {
            task_type: "research",
            prompt: "call ask switch-mode-question",
            description: "Asking child",
          },
        ],
      },
    };

  // "run orphan then switchmode" — timed bash (sleep 999) followed by switchmode
  if (/run orphan then switchmode/i.test(userText))
    return { type: "orphan_then_switchmode" };

  // "call switchmode <continuation>" → MCP SwitchMode tool call
  match = userText.match(/call switchmode (\S+)/i);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__SwitchMode",
      input: { continuation: match[1] },
    };

  // "call handoff <continuation> <prompt>" → MCP Handoff tool call
  match = userText.match(/call handoff (\S+) (.*)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__Handoff",
      input: { continuation: match[1].trim(), prompt: match[2].trim() },
    };

  // "call askuserquestion <question>" → MCP AskUserQuestion tool call
  match = userText.match(/call askuserquestion (.*)/is);
  if (match)
    return {
      type: "tool_call",
      name: "mcp__cydo__AskUserQuestion",
      input: {
        questions: [
          {
            header: "Test",
            question: match[1].trim(),
            options: [
              { label: "Yes", description: "Confirm" },
              { label: "No", description: "Deny" },
            ],
            multiSelect: false,
          },
        ],
      },
    };

  // "trigger compaction" — response with inflated totalTokens to exceed compact limit
  if (/trigger compaction/i.test(userText)) {
    return {
      type: "text",
      text: "Ready for compaction.",
      totalTokens: 500_000,
    };
  }

  // "call permissiontool <toolname> <json>" → tool_use for a named tool (triggers permission prompt)
  match = userText.match(/call permissiontool (\S+) (.*)/is);
  if (match)
    return {
      type: "tool_call",
      name: match[1].trim(),
      input: JSON.parse(match[2].trim()),
    };

  // "use builtin view <path>" → Copilot built-in view tool (triggers permission.requested)
  match = userText.match(/use builtin view (\S+)/i);
  if (match)
    return { type: "builtin_tool", name: "view", input: { path: match[1] } };

  // "web search <query>" — trigger a web_search_call response
  match = userText.match(/web search (.+)/i);
  if (match) return { type: "web_search", query: match[1].trim() };

  // Default: echo back
  return { type: "text", text: userText };
}
