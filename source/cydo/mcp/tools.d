/// CyDo MCP tool definitions and implementations.
module cydo.mcp.tools;

import cydo.protocol : CydoItemEnrichedEvent;

import ae.utils.json : JSONFragment;
import cydo.mcp : Description, McpName, McpResult, ToolCallCancellation;
import cydo.mcp.payloads : TaskResult;

private enum string mailboxDescription =
	"Any blocked Task, Ask, or Answer call returns the next event in arrival order. "
	~ "It may belong to an earlier call. In a call's result, check `status` (`question` or `answered`) "
	~ "and `qid` for questions and replies, or the child `tid`s in the `tasks` list for batch results. "
	~ "Question failures returned by a call are tool errors. "
	~ "When you go idle, queued events arrive as system messages.";

enum string taskToolDescription =
	"Create sub-tasks that run autonomously and return their output.\n\n"
	~ "Use this when work can stand alone in its own session. Detailed task-type guidance "
	~ "lives in the session instructions.\n\n"
	~ "Each created child appears in the CyDo task tree; the returned `tid` opens that "
	~ "child session.\n\n"
	~ "Accepted multi-task batches launch every child before waiting, so the children run "
	~ "concurrently. Once every child settles, the batch result contains one item per requested "
	~ "task in request order, regardless of completion order. Each item includes the child's "
	~ "output file path and `tid` when available. Use Ask with the child's `tid` to follow up.\n\n"
	~ mailboxDescription ~ "\n\n"
	~ "After a restart, CyDo resumes in-flight children and keeps unfinished batches grouped. "
	~ "Unanswered questions and recovered results are queued again and delivered like any other event.";

enum string askToolDescription =
	"Ask a question to another task in your workspace. Omit `tid` to ask your parent, or pass "
	~ "a task's `tid` to ask that task. If that task is your child and you have received a question "
	~ "from it that you have not answered, use Answer with that `qid` instead. "
	~ "Ask waits for the next event.\n\n"
	~ "Use Ask when you need information to continue. Your final message and output "
	~ "are delivered to your parent automatically when your task ends.\n\n"
	~ mailboxDescription ~ " The answer to your question may arrive through a later call.";

enum string answerToolDescription =
	"Answer a question from a related task using the `qid` you received. "
	~ "A cancelled question returns an error. If answering requires work, finish it "
	~ "before calling Answer.\n\n"
	~ "After a successful Answer, the call returns `status: \"delivered\"` immediately unless "
	~ "you owe no other received question an answer and are still waiting for a Task batch result "
	~ "or for a reply or failure to your own question. In that case, it waits for the next event.\n\n"
	~ mailboxDescription;

/// Static Handoff description shared by MCP-backed agents and Copilot's SDK tools.
enum string handoffToolDescription =
	"Hand off this task to a successor in a fresh session.\n\n"
	~ "Use this when the next phase should start in a fresh session. Detailed handoff "
	~ "guidance lives in the session instructions.\n\n"
	~ "After this session exits, a valid Handoff marks this task completed, then creates a "
	~ "child successor in a fresh session from the supplied prompt; the successor does not "
	~ "inherit this conversation.\n\n"
	~ "**This is a terminal action.** After calling mcp__cydo__Handoff, your session will end. "
	~ "Do not call any other tools after Handoff.";

enum string unsandboxedCommandToolDescription =
	"Run a shell command on the host with the user's shell, outside the task sandbox, "
	~ "with CyDo's environment. Use it only for work the sandbox prevents. "
	~ "The user may have to approve each call. A denied, unanswered, or cancelled request "
	~ "returns an error. A command that exceeds the timeout returns its output so far.";

enum string requestToolDescription =
	"Send a request to a singleton. Results follow the same delivery rules as Ask.\n\nAvailable singletons:\n\n";

enum string createTaskToolDescription =
	"Create a new top-level CyDo task for the user. It is not your sub-task: "
	~ "you do not wait for it or receive its result, and it records you as its creator.\n\n"
	~ "Use this only when the user, or the project's instructions, tell you to create tasks. For example:\n"
	~ "- Triaging a list of bugs and creating a task for each\n"
	~ "- Opening a task for an unrelated bug you noticed while working on another task\n"
	~ "- Fanning out standalone follow-up improvements once a base feature has landed\n\n"
	~ "By default the task is a draft. It appears in the user's task list with `prompt` as its unsent first message, "
	~ "for the user to review, edit and send. Set `start` only when explicitly instructed to start the task. "
	~ "It then begins right away with `prompt` as its first message. "
	~ "You can start tasks only in your own workspace; elsewhere, create a draft.\n\n"
	~ "The new task does not see this conversation, so make `prompt` self-contained. "
	~ "The result contains the new task's `tid`.";

/// Specification for a single sub-task.
struct TaskSpec
{
	@Description("A short (3-5 word) description of the task")
	string description;
	@Description("The task type to create")
	string task_type;
	@Description("The child task prompt; see the session's Create Sub-Tasks guidance for context requirements")
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

	@Description(unsandboxedCommandToolDescription)
	@McpName("UnsandboxedCommand")
	McpResult unsandboxedCommand(
		@Description("The command to run with the user's shell")
		string command,
		@Description("Absolute host directory to run in")
		string cwd,
		@Description("Seconds before the command's process group is killed")
		int timeout
	);

	/+
	@Description("Read the contents of a file from the filesystem. Returns the file content as text.")
	@McpName("Read")
	McpResult read(
		@Description("The absolute path to the file to read")
		string file_path
	);
	+/

	@Description(taskToolDescription ~ "\n\nAvailable task types:\n\n{{creatable_task_types}}")
	@McpName("Task")
	McpResult createTasks(
		@Description("Task specifications to create")
		TaskSpec[] tasks
	);

	@Description(
		"Switch this task to a different mode within the same session.\n\n"
		~ "The current conversation context is preserved, you will receive new instructions, "
		~ "and the available tool set may change. Detailed mode guidance lives in the session "
		~ "instructions.\n\n"
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

	@Description(handoffToolDescription ~ "\n\nAvailable handoffs:\n\n{{handoffs}}")
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

	@Description(askToolDescription)
	@McpName("Ask")
	McpResult ask(
	    @Description("The question to ask")
	    string message,
	    @Description("Target task ID. Omit to ask your parent task. "
	        ~ "Pass tid when asking a specific task by ID.")
	    int tid = -1
	);

	@Description(answerToolDescription)
	@McpName("Answer")
	McpResult answer(
	    @Description("The ID of the question received in a tool result or system message")
	    int qid,
	    @Description("Your answer")
	    string message
	);

	@Description(requestToolDescription ~ "{{singletons}}")
	@McpName("Request")
	McpResult request(
	    @Description("Name of the singleton to ask") string to,
	    @Description("The request to send") string message
	);

	@Description(createTaskToolDescription ~ "\n\nAvailable entry points:\n\n{{creatable_entry_points}}")
	@McpName("CreateTask")
	McpResult createUserTask(
		@Description("The task's request, self-contained: the draft text, or the first message if started")
		string prompt,
		@Description("Short title for the task list. Omit to derive it from the prompt")
		string title = "",
		@Description("Entry point to create the task at, from the list above. Omit to use the one marked (default)")
		string entry_point = "",
		@Description("Absolute path of the project to create the task in. Defaults to your current project")
		string project = "",
		@Description("Start the task immediately instead of leaving it as a draft. Only when explicitly instructed")
		bool start = false
	);
}

import ae.utils.promise : Promise;

/// Child task launch result preserved in request order.
struct LaunchedTask
{
	int childTid;
}

/// Result of validating a single Task spec.
/// On validation success, `launch` is non-null and creates the child task when called.
/// On validation failure, `launch` is null and `error` contains the reason.
struct ValidatedTask
{
	McpResult error;
	LaunchedTask delegate() launch;
}

/// Backend interface — methods that CydoToolsImpl needs from the application.
/// App implements this; the indirection breaks the compile-time dependency on cydo.server.app.
/// CyDo-side metadata about this call, shown on its card. Leave item_id unset.
interface ToolCallEnricher
{
	void enrich(CydoItemEnrichedEvent enrichment);
}

interface ToolsBackend
{
	ValidatedTask handleCreateTask(string callerTid, int specIndex,
		string description, string taskType, string prompt);
	bool wouldBeWriter(string callerTid, string taskType);
	McpResult handleSwitchMode(string callerTid, string continuation);
	McpResult handleHandoff(string callerTid, string continuation, string prompt);
	Promise!McpResult handleAskUserQuestion(string callerTid, AskQuestion[] questions);
	Promise!McpResult handleBash(string callerTid, string command);
	Promise!McpResult handleUnsandboxedCommand(string callerTid, string command,
		string cwd, int timeout, ToolCallCancellation cancellation);
	Promise!McpResult registerBatchAndAwait(string callerTid, LaunchedTask[] launchedTasks);
	Promise!McpResult handleAsk(string callerTid, ToolCallEnricher call, string message, int targetTid);
	Promise!McpResult handleAnswer(string callerTid, ToolCallEnricher call, int qid, string message);
	Promise!McpResult handleRequest(string callerTid, ToolCallEnricher call, string target, string message);
	Promise!McpResult handleCreateUserTask(string callerTid, string prompt, string title,
		string entryPoint, string project, bool start);
}

/// Tool implementation — constructed per MCP call with the calling App and task ID.
/// Async tools (e.g. Task) use fiber-based await to block until completion.
class CydoToolsImpl : CydoTools
{
	private ToolsBackend app;
	private string callerTid;
	private ToolCallEnricher call;
	private ToolCallCancellation cancellation;

	this(ToolsBackend app, string callerTid, ToolCallEnricher call, ToolCallCancellation cancellation = null)
	{
		this.app = app;
		this.callerTid = callerTid;
		this.call = call;
		this.cancellation = cancellation;
	}

	McpResult bash(string command)
	{
		import ae.utils.promise.await : await;
		return app.handleBash(callerTid, command).await();
	}

	McpResult unsandboxedCommand(string command, string cwd, int timeout)
	{
		import ae.utils.promise.await : await;
		return app.handleUnsandboxedCommand(callerTid, command, cwd, timeout, cancellation).await();
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
		import std.array : join;
		import std.conv : to;

		if (tasks.length == 0)
			return McpResult("No tasks provided", true);

		// Pre-flight: reject batches with multiple writers to avoid worktree conflicts.
		int writerCount;
		foreach (ref spec; tasks)
			if (app.wouldBeWriter(callerTid, spec.task_type))
				writerCount++;
		if (writerCount > 1)
			return McpResult(
				"Cannot run multiple non-read-only tasks in parallel: they would share the same worktree. Run them sequentially, or use task types which work in their own worktrees.",
				true);

		// Phase 1: validate all specs without executing any.
		auto validated = new ValidatedTask[tasks.length];
		foreach (i, ref spec; tasks)
			validated[i] = app.handleCreateTask(callerTid, cast(int)i, spec.description, spec.task_type, spec.prompt);

		// If any spec failed validation, report all errors and abort.
		string[] errors;
		ValidatedTask firstError;
		foreach (i, ref vt; validated)
			if (vt.launch is null)
			{
				if (errors.length == 0) firstError = vt;
				errors ~= tasks.length == 1
					? vt.error.text
					: "Task " ~ to!string(i + 1) ~ " (" ~ tasks[i].task_type ~ "): " ~ vt.error.text;
			}
		if (errors.length > 0)
		{
			// For a single failure, preserve the structured content from validation.
			if (errors.length == 1)
				return firstError.error;
			// Multiple failures: aggregate into a single TaskResult.
			auto msg = errors.join("\n");
			return McpResult.structured(toJson(TaskResult(
				summary: msg,
				error: msg,
				status: "error",
			)), true);
		}

		// Phase 2: all specs valid — launch all tasks.
		auto launched = new LaunchedTask[tasks.length];
		foreach (i, ref vt; validated)
			launched[i] = vt.launch();

		// Register batch state and enter the event-driven wait loop.
		// Returns when all children complete or a child asks a question.
		return app.registerBatchAndAwait(callerTid, launched).await();
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
		return app.handleAsk(callerTid, call, message, tid).await();
	}

	McpResult answer(int qid, string message)
	{
		import ae.utils.promise.await : await;
		return app.handleAnswer(callerTid, call, qid, message).await();
	}

	McpResult request(string to, string message)
	{
		import ae.utils.promise.await : await;
		return app.handleRequest(callerTid, call, to, message).await();
	}

	McpResult createUserTask(string prompt, string title, string entry_point,
		string project, bool start)
	{
		import ae.utils.promise.await : await;
		return app.handleCreateUserTask(callerTid, prompt, title, entry_point, project, start).await();
	}
}

unittest
{
	import ae.utils.json : jsonParse, toJson;
	import cydo.mcp.payloads : TaskResult;
	import std.algorithm.searching : canFind;

	final class FakeToolsBackend : ToolsBackend
	{
		ValidatedTask handleCreateTask(string callerTid, int specIndex,
			string description, string taskType, string prompt)
		{
			auto message = "invalid " ~ taskType;
			return ValidatedTask(McpResult.structured(toJson(TaskResult(
				summary: message,
				error: message,
				status: "error",
			)), true));
		}

		bool wouldBeWriter(string callerTid, string taskType)
		{
			return false;
		}

		McpResult handleSwitchMode(string callerTid, string continuation)
		{
			assert(0, "unexpected call");
		}

		McpResult handleHandoff(string callerTid, string continuation, string prompt)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleAskUserQuestion(string callerTid, AskQuestion[] questions)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleBash(string callerTid, string command)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleUnsandboxedCommand(string callerTid, string command,
			string cwd, int timeout, ToolCallCancellation cancellation)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult registerBatchAndAwait(string callerTid, LaunchedTask[] launchedTasks)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleAsk(string callerTid, ToolCallEnricher call, string message, int targetTid)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleAnswer(string callerTid, ToolCallEnricher call, int qid, string message)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleRequest(string callerTid, ToolCallEnricher call, string target, string message)
		{
			assert(0, "unexpected call");
		}

		Promise!McpResult handleCreateUserTask(string callerTid, string prompt, string title,
			string entryPoint, string project, bool start)
		{
			assert(0, "unexpected call");
		}
	}

	auto impl = new CydoToolsImpl(new FakeToolsBackend, "17", null);
	auto result = impl.createTasks([
		TaskSpec("first", "alpha", "prompt a"),
		TaskSpec("second", "beta", "prompt b"),
	]);

	assert(result.isError);
	assert(result.structuredContent.json == result.text);
	assert(!result.text.canFind(`"output_file"`));
	assert(!result.text.canFind(`"worktree"`));
	assert(!result.text.canFind(`"note"`));
	assert(!result.text.canFind(`"tid"`));
	assert(!result.text.canFind(`"qid"`));
	assert(!result.text.canFind(`"commits"`));

	auto payload = jsonParse!TaskResult(result.text);
	auto expected = "Task 1 (alpha): " ~ toJson(TaskResult(
		summary: "invalid alpha",
		error: "invalid alpha",
		status: "error",
	)) ~ "\nTask 2 (beta): " ~ toJson(TaskResult(
		summary: "invalid beta",
		error: "invalid beta",
		status: "error",
	));
	assert(payload.summary == expected);
	assert(payload.error == expected);
	assert(payload.status == "error");
	assert(payload.output_file is null);
	assert(payload.worktree is null);
	assert(payload.note is null);
	assert(payload.tid == 0);
	assert(payload.commits is null);
}
