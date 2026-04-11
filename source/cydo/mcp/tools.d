/// CyDo MCP tool definitions and implementations.
module cydo.mcp.tools;

import cydo.mcp : Description, McpName, McpResult;

/// Specification for a single sub-task.
struct TaskSpec
{
	@Description("A short (3-5 word) description of the task")
	string description;
	@Description("The task type to create (e.g., 'research', 'plan', 'implement')")
	string task_type;
	@Description("The task for the agent to perform")
	string prompt;
}

/// A single option for an AskUserQuestion question.
struct AskOption
{
	@Description("Short label for this option")
	string label;
	@Description("Longer description of what this option means")
	string description;
}

/// A single question in an AskUserQuestion request.
struct AskQuestion
{
	@Description("Short header/label for the question (max 12 chars)")
	string header;
	@Description("The question text")
	string question;
	@Description("Available options to choose from (user can always type a custom answer)")
	AskOption[] options;
	@Description("Allow selecting multiple options (default: false)")
	bool multiSelect;
}

/// Tool interface — each method is an MCP tool.
/// Compile-time introspection generates metadata and dispatch.
interface CydoTools
{
	@Description("Execute a shell command and return its output.")
	@McpName("Bash")
	McpResult bash(
		@Description("The shell command to execute")
		string command
	);

	/+
	@Description("Read the contents of a file from the filesystem. Returns the file content as text.")
	@McpName("Read")
	McpResult read(
		@Description("The absolute path to the file to read")
		string file_path
	);
	+/

	@Description(
		"Create sub-tasks that run autonomously and return their output.\n\n"
		~ "**Prefer creating sub-tasks for any work that can stand alone.** Sub-tasks "
		~ "run as independent agent sessions, protect your context window, and make work "
		~ "visible in the CyDo task tree. When in doubt, delegate — sub-tasks are cheap "
		~ "and keep you focused on orchestration.\n\n"
		~ "## When to use this tool\n"
		~ "- Investigating something: \"how does the auth subsystem work?\"\n"
		~ "- Planning multi-file changes before implementing them\n"
		~ "- Implementing a scoped piece of work with clear requirements\n"
		~ "- Testing a theory or prototyping an approach in isolation\n"
		~ "- Exploring an unfamiliar part of the codebase\n"
		~ "- Any task you could describe in a sentence and hand to a colleague\n\n"
		~ "## When NOT to use this tool\n"
		~ "- Reading a single known file (use the Read tool directly)\n"
		~ "- Searching for a specific symbol or filename (use Grep or Glob directly)\n"
		~ "- Trivial one-step work you are certain about\n\n"
		~ "## How results work\n"
		~ "- The sub-task writes to its own output file; you receive the path and can read it\n"
		~ "- Results are also visible in the CyDo web UI task tree\n"
		~ "- Sub-tasks are persisted and survive backend restarts\n\n"
		~ "## Parallel execution\n"
		~ "- Pass multiple tasks in the array to run them in parallel\n"
		~ "- All tasks execute concurrently; the tool returns when all complete\n"
		~ "- Results are returned in order, one section per task\n\n"
		~ "## Usage notes\n"
		~ "- Provide clear, detailed prompts so the agent can work autonomously "
		~ "and return exactly the information you need.\n"
		~ "- Clearly tell the agent whether you expect it to write code or just "
		~ "do research, since it is not aware of your broader context.\n"
		~ "- Avoid duplicating work that sub-tasks are already doing.\n"
		~ "- The agent's outputs should generally be trusted.\n\n"
		~ "Available task types:\n\n{{creatable_task_types}}\n\n"
		~ "## Follow-up\n"
		~ "- Each result includes a `tid` field identifying the sub-task\n"
		~ "- Use Ask(message, tid) to ask follow-up questions to completed sub-tasks\n"
		~ "- If a sub-task asks you a question, the Task/Ask call returns early with "
		~ "a question result including a `qid`. Answer with Answer(qid, answer).\n"
	)
	@McpName("Task")
	McpResult createTasks(
		@Description("Array of tasks to execute (in parallel if more than one)")
		TaskSpec[] tasks
	);

	@Description(
		"Switch this task to a different mode within the same session.\n\n"
		~ "The current conversation context is preserved — you will receive a new "
		~ "prompt describing the new mode's expectations, and may get a different "
		~ "tool set. Use this when your current phase is complete and the next phase "
		~ "needs the same context (e.g., plan → triage).\n\n"
		~ "**This is a terminal action.** After calling mcp__cydo__SwitchMode, yield your turn "
		~ "immediately — do not call any other tools or generate further output. "
		~ "The mode has not switched yet; you will receive new instructions when "
		~ "your session resumes.\n\n"
		~ "Available modes:\n\n{{switchmodes}}"
	)
	@McpName("SwitchMode")
	McpResult switchMode(
		@Description("The mode to switch to (e.g., 'done', 'implement', 'decompose')")
		string continuation
	);

	@Description(
		"Hand off this task to a successor with a fresh session.\n\n"
		~ "Use this when your work is complete and the next phase does NOT need "
		~ "your full conversation context — only the information you pass in the "
		~ "prompt. The current session ends, a new task is created with the prompt "
		~ "you provide, and your task is marked completed.\n\n"
		~ "**This is a terminal action.** After calling mcp__cydo__Handoff, your session will end. "
		~ "Do not call any other tools after Handoff.\n\n"
		~ "Available handoffs:\n\n{{handoffs}}"
	)
	@McpName("Handoff")
	McpResult handoff(
		@Description("The handoff name to follow (e.g., 'small_fix', 'needs_plan', 'done')")
		string continuation,
		@Description("The prompt for the successor task — include all findings and context needed")
		string prompt
	);

	@Description(
	    "Ask the user one or more questions during execution. Use when you need to:\n"
	    ~ "- Gather user preferences or requirements\n"
	    ~ "- Clarify ambiguous instructions\n"
	    ~ "- Get decisions on implementation choices\n"
	    ~ "- Offer choices about what direction to take\n\n"
	    ~ "Users can always choose \"Other\" to provide custom text input.\n"
	    ~ "Use multiSelect: true to allow multiple answers per question.\n"
	    ~ "If you recommend a specific option, make it the first option with \"(Recommended)\" in the label."
	)
	@McpName("AskUserQuestion")
	McpResult askUserQuestion(
	    @Description("Array of questions to ask the user")
	    AskQuestion[] questions
	);

	@Description(
	    "Ask a question to a related task and wait for the answer.\n\n"
	    ~ "## Ask your parent (tid omitted)\n"
	    ~ "Call Ask(message) to ask your parent task a question. Your execution "
	    ~ "pauses until the parent answers with Answer(qid, response).\n\n"
	    ~ "## Ask a completed sub-task (follow-up)\n"
	    ~ "After a Task call completes, use Ask(message, tid) to ask a follow-up "
	    ~ "question. The sub-task is resumed with your question and must answer "
	    ~ "with Answer(qid, response).\n\n"
	    ~ "The result includes a `qid` (question ID) that the answerer uses.\n"
	    ~ "If a sub-task has a pending question, use Answer instead of Ask."
	)
	@McpName("Ask")
	McpResult ask(
	    @Description("The question to ask")
	    string message,
	    @Description("Target task ID. Omit to ask your parent task. "
	        ~ "Required when asking a sub-task (tid from Task/Ask results).")
	    int tid = -1
	);

	@Description(
	    "Answer a question from a related task.\n\n"
	    ~ "When a sub-task asks you a question (returned from Task or Ask with "
	    ~ "a qid), use Answer(qid, message) to respond.\n\n"
	    ~ "When your parent asks you a follow-up question (delivered with a qid), "
	    ~ "use Answer(qid, message) to respond.\n\n"
	    ~ "After answering a sub-task's question, this call blocks until the "
	    ~ "batch completes or another question arrives."
	)
	@McpName("Answer")
	McpResult answer(
	    @Description("The question ID to answer (from the question result)")
	    int qid,
	    @Description("Your answer")
	    string message
	);
}

import ae.utils.promise : Promise;

/// Backend interface — methods that CydoToolsImpl needs from the application.
/// App implements this; the indirection breaks the compile-time dependency on cydo.app.
interface ToolsBackend
{
	Promise!McpResult handleCreateTask(string callerTid,
		string description, string taskType, string prompt);
	bool wouldBeWriter(string callerTid, string taskType);
	McpResult handleSwitchMode(string callerTid, string continuation);
	McpResult handleHandoff(string callerTid, string continuation, string prompt);
	Promise!McpResult handleAskUserQuestion(string callerTid, AskQuestion[] questions);
	Promise!McpResult handleBash(string callerTid, string command);
	Promise!McpResult registerBatchAndAwait(string callerTid, Promise!McpResult[] childPromises);
	Promise!McpResult handleAsk(string callerTid, string message, int targetTid);
	Promise!McpResult handleAnswer(string callerTid, int qid, string message);
}

/// Tool implementation — constructed per MCP call with the calling App and task ID.
/// Async tools (e.g. Task) use fiber-based await to block until completion.
class CydoToolsImpl : CydoTools
{
	private ToolsBackend app;
	private string callerTid;

	this(ToolsBackend app, string callerTid)
	{
		this.app = app;
		this.callerTid = callerTid;
	}

	McpResult bash(string command)
	{
		import ae.utils.promise.await : await;
		return app.handleBash(callerTid, command).await();
	}

	/+
	McpResult read(string file_path)
	{
		import std.file : exists, isFile, readText;

		if (!exists(file_path))
			return McpResult("File not found: " ~ file_path, true);

		if (!isFile(file_path))
			return McpResult("Not a file: " ~ file_path, true);

		try
		{
			auto content = readText(file_path);
			return McpResult(content, false);
		}
		catch (Exception e)
			return McpResult("Error reading file: " ~ e.msg, true);
	}
	+/

	McpResult createTasks(TaskSpec[] tasks)
	{
		import ae.utils.json : JSONFragment, toJson;
		import ae.utils.promise : Promise;
		import ae.utils.promise.await : await;

		if (tasks.length == 0)
			return McpResult("No tasks provided", true);

		// Pre-flight: reject batches with multiple writers to avoid worktree conflicts.
		int writerCount;
		foreach (ref spec; tasks)
			if (app.wouldBeWriter(callerTid, spec.task_type))
				writerCount++;
		if (writerCount > 1)
			return McpResult(
				"Cannot run multiple non-read-only tasks in parallel: they would share the same worktree. Run them sequentially, or use fork worktrees.",
				true);

		// Launch all tasks — each returns a promise.
		auto promises = new Promise!McpResult[tasks.length];
		foreach (i, ref spec; tasks)
			promises[i] = app.handleCreateTask(callerTid, spec.description, spec.task_type, spec.prompt);

		// Register batch state and enter the event-driven wait loop.
		// Returns when all children complete or a child asks a question.
		return app.registerBatchAndAwait(callerTid, promises).await();
	}

	McpResult switchMode(string continuation)
	{
		return app.handleSwitchMode(callerTid, continuation);
	}

	McpResult handoff(string continuation, string prompt)
	{
		return app.handleHandoff(callerTid, continuation, prompt);
	}

	McpResult askUserQuestion(AskQuestion[] questions)
	{
		import ae.utils.promise.await : await;
		return app.handleAskUserQuestion(callerTid, questions).await();
	}

	McpResult ask(string message, int tid = -1)
	{
		import ae.utils.promise.await : await;
		return app.handleAsk(callerTid, message, tid).await();
	}

	McpResult answer(int qid, string message)
	{
		import ae.utils.promise.await : await;
		return app.handleAnswer(callerTid, qid, message).await();
	}
}
