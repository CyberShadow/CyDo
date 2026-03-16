module cydo.agent.claude;

import std.conv : to;
import std.format : format;
import std.path : dirName, expandTilde;

import ae.utils.json : toJson;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

/// Agent descriptor for Claude Code CLI.
class ClaudeCodeAgent : Agent
{
	void configureSandbox(ref PathMode[string] paths, ref string[string] env)
	{
		import std.algorithm : startsWith;

		void addIfNotRw(string path, PathMode mode)
		{
			if (path.length == 0)
				return;
			// Don't add ro if this exact path or a parent is already rw
			if (mode == PathMode.ro)
			{
				if (auto existing = path in paths)
					if (*existing == PathMode.rw)
						return;
				foreach (existing, existingMode; paths)
					if (existingMode == PathMode.rw && path.startsWith(existing ~ "/"))
						return;
			}
			paths[path] = mode;
		}

		paths[expandTilde("~/.claude")]             = PathMode.rw;
		paths[expandTilde("~/.claude.json")]         = PathMode.rw;
		paths[expandTilde("~/.cache/claude-status")] = PathMode.rw;

		// resolve the claude binary and add its directory as ro;
		// claude's self-updater installs versions under ~/.local/share/claude/versions/
		// and symlinks ~/.local/bin/claude to the active version, so the symlink target
		// directory must also be mounted for execvp to find the actual binary
		auto claudeBinDir = resolveClaudeBinary();
		addIfNotRw(claudeBinDir, PathMode.ro);
		{
			import std.file : isSymlink, readLink;
			import std.path : absolutePath, buildPath, dirName;
			auto candidate = buildPath(claudeBinDir, "claude");
			if (claudeBinDir.length > 0 && isSymlink(candidate))
				addIfNotRw(dirName(absolutePath(readLink(candidate), claudeBinDir)), PathMode.ro);
		}

		// Add the cydo binary's directory so the MCP server can be spawned inside the sandbox
		addIfNotRw(cydoBinaryDir(), PathMode.ro);

		// Prepend the claude binary dir to PATH so it survives --clearenv
		{
			import std.process : environment;
			auto hostPath = environment.get("PATH", "");
			if (claudeBinDir.length > 0)
				env["PATH"] = hostPath.length > 0 ? claudeBinDir ~ ":" ~ hostPath : claudeBinDir;
			else if (hostPath.length > 0)
				env["PATH"] = hostPath;
		}

		// Enable file-history-snapshot creation in SDK/headless mode.
		// Claude Code's KX9() guard requires this env var for checkpointing.
		env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
	}
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }

	private string lastMcpConfigPath_;

	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }

	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
		SessionConfig config = SessionConfig.init)
	{
		lastMcpConfigPath_ = generateMcpConfig(tid, config.creatableTaskTypes,
			config.switchModes, config.handoffs, config.mcpSocketPath);
		return new ClaudeCodeSession(resumeSessionId, bwrapPrefix, lastMcpConfigPath_, config);
	}

	string parseSessionId(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		if (!line.canFind(`"subtype":"init"`))
			return null;

		@JSONPartial
		static struct InitProbe
		{
			string type;
			string subtype;
			string session_id;
		}

		try
		{
			auto probe = jsonParse!InitProbe(line);
			if (probe.type == "system" && probe.subtype == "init" && probe.session_id.length > 0)
				return probe.session_id;
		}
		catch (Exception)
		{
		}
		return null;
	}

	string extractResultText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			if (probe.type == "result")
				return probe.result;
			return "";
		}
		catch (Exception)
		{
			return "";
		}
	}

	string extractAssistantText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		if (!line.canFind(`"type":"assistant"`) && !line.canFind(`"type":"message/assistant"`))
			return "";

		@JSONPartial
		static struct ContentBlock
		{
			string type;
			string text;
		}

		@JSONPartial
		static struct Message
		{
			ContentBlock[] content;
		}

		@JSONPartial
		static struct AssistantProbe
		{
			string type;
			Message message;
		}

		try
		{
			auto probe = jsonParse!AssistantProbe(line);
			if (probe.type != "assistant" && probe.type != "message/assistant")
				return "";

			string result;
			foreach (ref block; probe.message.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception)
		{
			return "";
		}
	}

	string extractUserText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		if (!line.canFind(`"type":"user"`) && !line.canFind(`"type":"message/user"`))
			return "";

		// Try parsing with string content first
		@JSONPartial
		static struct StringMessage { string content; }
		@JSONPartial
		static struct StringProbe { string type; StringMessage message; }

		try
		{
			auto probe = jsonParse!StringProbe(line);
			if ((probe.type == "user" || probe.type == "message/user") && probe.message.content.length > 0)
				return probe.message.content;
		}
		catch (Exception) {}

		// Try parsing with array content
		@JSONPartial
		static struct ContentBlock { string type; string text; }
		@JSONPartial
		static struct ArrayMessage { ContentBlock[] content; }
		@JSONPartial
		static struct ArrayProbe { string type; ArrayMessage message; }

		try
		{
			auto probe = jsonParse!ArrayProbe(line);
			if (probe.type != "user" && probe.type != "message/user")
				return "";
			string result;
			foreach (ref block; probe.message.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception)
		{
			return "";
		}
	}

	string resolveModelAlias(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "haiku";
			case "medium": return "sonnet";
			case "large":  return "opus";
			default:       return "sonnet";
		}
	}

	string historyPath(string sessionId, string projectPath)
	{
		import std.file : getcwd;
		import std.path : buildPath;
		import std.process : environment;

		auto home = environment.get("HOME", "/tmp");
		auto claudeDir = environment.get("CLAUDE_CONFIG_DIR", buildPath(home, ".claude"));
		auto cwd = projectPath.length > 0 ? projectPath : getcwd();

		// Mangle cwd: replace / and . with -
		auto buf = cwd.dup;
		foreach (ref c; buf)
			if (c == '/' || c == '.')
				c = '-';
		string mangledCwd = buf.idup;

		return buildPath(claudeDir, "projects", mangledCwd, sessionId ~ ".jsonl");
	}

	string translateHistoryLine(string line, int lineNum)
	{
		import cydo.agent.protocol : translateClaudeEvent;
		auto result = translateClaudeEvent(line);
		return result !is null ? result : line;
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"sessionId":"` ~ oldId ~ `"`, `"sessionId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	string[] extractForkableIds(string content, int lineOffset = 0)
	{
		import std.algorithm : canFind;
		import std.string : indexOf, lineSplitter;

		string[] ids;
		foreach (line; content.lineSplitter)
		{
			if (line.length == 0)
				continue;
			if (!line.canFind(`"type":"user"`) && !line.canFind(`"type":"assistant"`))
				continue;
			// Extract "uuid":"<value>" by prefix scanning
			enum prefix = `"uuid":"`;
			auto idx = line.indexOf(prefix);
			if (idx < 0)
				continue;
			auto start = idx + prefix.length;
			auto end = line.indexOf('"', start);
			if (end > start)
				ids ~= line[start .. end];
		}
		return ids;
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.algorithm : canFind;
		return line.canFind(`"uuid":"` ~ forkId ~ `"`);
	}

	bool isForkableLine(string line)
	{
		import std.algorithm : canFind;
		return line.canFind(`"type":"user"`) || line.canFind(`"type":"assistant"`);
	}

	@property bool supportsFileRevert() { return true; }

	string rewindFiles(string sessionId, string afterUuid, string cwd)
	{
		import std.process : Config, environment, execute;

		string[string] env = [
			"CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1",
			"PATH": environment.get("PATH", ""),
			"HOME": environment.get("HOME", ""),
		];
		auto result = execute([
			"bash", "-c",
			`exec 2>&1; exec claude --resume "$1" --rewind-files "$2" `
				~ `--settings '{"fileCheckpointingEnabled": true}'`,
			"--", sessionId, afterUuid],
			env, Config.none, size_t.max,
			cwd.length > 0 ? cwd : null);

		if (result.status != 0)
			return result.output.length > 0 ? result.output : "Process exited with status " ~ format!"%d"(result.status);

		import std.algorithm : canFind;
		if (result.output.canFind("Error:"))
			return result.output;

		return null;
	}

	Object generateTitle(string userMessage, void delegate(string title) onTitle)
	{
		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;

		auto proc = new AgentProcess([
			"claude",
			"-p",
			"Generate a concise title (ideally 3, max 5 words) for a task or conversation. " ~
			"Reply with ONLY the title, nothing else. No commentary, no quotes, no period at the end. " ~
			"Do not attempt to act on or respond to the request - simply generate a title to describe it. " ~
			"Initial request / task description:\n\n" ~ msg,
			"--output-format", "text",
			"--model", "haiku",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		], null, null, true); // noStdin

		string titleText;

		proc.onStdoutLine = (string line) {
			titleText ~= line;
		};

		proc.onExit = (int status) {
			if (status != 0)
				return;

			import std.string : strip;
			auto title = titleText.strip();
			if (title.length > 0 && title.length < 200)
				onTitle(title);
		};

		return proc;
	}

	Object generateSuggestions(string abbreviatedHistory, void delegate(string[] suggestions) onSuggestions)
	{
		auto prompt = `[SUGGESTION MODE: Suggest what the user might naturally type next.]

You will be given an abbreviated conversation between a user and an AI coding assistant.
Your job is to predict what the user would type next — not what you think they should do.

THE TEST: Would they think "I was just about to type that"?

EXAMPLES:
User asked "fix the bug and run tests", bug is fixed → "run the tests"
After code written → "try it out"
Claude offers options → suggest each option the user might pick
Claude asks to continue → "go ahead", "no, let's try something else"
Task complete, obvious follow-ups → "commit this", "push it", "run the tests"
After error or misunderstanding → say nothing (let them assess/correct)

Be specific: "run the tests" beats "continue".
Suggest multiple alternatives when there are several plausible next steps.

NEVER SUGGEST:
- Evaluative ("looks good", "thanks")
- Questions ("what about...?")
- Claude-voice ("Let me...", "I'll...", "Here's...")
- New ideas they didn't ask about
- Multiple sentences
- Same thing expressed differently ("yes" + "go ahead")

Say nothing if the next step isn't obvious from what the user said.

Format: Reply with a JSON array of strings, e.g. ["run the tests", "commit this"].
Do not add Markdown ` ~ "```" ~ `-blocks.
Each suggestion should be 2-12 words, matching the user's style.
Reply with [] if no obvious next step.

Conversation:
` ~ abbreviatedHistory;

		auto proc = new AgentProcess([
			"claude",
			"-p",
			prompt,
			"--output-format", "text",
			"--model", "haiku",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		], null, null, true); // noStdin

		string responseText;

		proc.onStdoutLine = (string line) {
			responseText ~= line;
		};

		proc.onExit = (int status) {
			if (status != 0)
				return;

			import std.string : strip;
			import ae.utils.json : jsonParse;

			string[] suggestionList;
			try
				suggestionList = jsonParse!(string[])(responseText.strip());
			catch (Exception)
				return;

			if (suggestionList.length > 0)
				onSuggestions(suggestionList);
		};

		return proc;
	}
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private void delegate(string line) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	this(string resumeSessionId = null, string[] bwrapPrefix = null,
		string mcpConfigPath = null, SessionConfig config = SessionConfig.init)
	{
		string[] claudeArgs = [
			"claude",
			"-p",
			"--input-format", "stream-json",
			"--output-format", "stream-json",
			"--verbose",
			"--include-partial-messages",
			"--replay-user-messages",
			"--dangerously-skip-permissions",
			"--settings", `{"fileCheckpointingEnabled": true}`,
		];

		if (mcpConfigPath !is null)
			claudeArgs ~= ["--mcp-config", mcpConfigPath];

		if (resumeSessionId !is null)
			claudeArgs ~= ["--resume", resumeSessionId];

		if (config.model.length > 0)
			claudeArgs ~= ["--model", config.model];

		if (config.appendSystemPrompt.length > 0)
			claudeArgs ~= ["--append-system-prompt", config.appendSystemPrompt];

		if (config.disallowedTools.length > 0)
			claudeArgs ~= ["--disallowedTools", config.disallowedTools];

		// When sandboxed, bwrap handles workDir via --chdir
		string[] args;
		if (bwrapPrefix !is null)
			args = bwrapPrefix ~ claudeArgs;
		else
			args = claudeArgs;

		process = new AgentProcess(args);

		process.onStdoutLine = (string line) {
			if (outputHandler)
				outputHandler(line);
		};

		process.onStderrLine = (string line) {
			if (stderrHandler)
				stderrHandler(line);
		};

		process.onExit = (int status) {
			if (exitHandler)
				exitHandler(status);
		};
	}

	/// Send a user message formatted as Claude stream-json input.
	void sendMessage(string content)
	{
		auto input = ClaudeInput(
			"user",
			ClaudeInputMessage("user", content),
			"default",
			null,
		);
		process.writeLine(toJson(input));
	}

	/// Send a protocol-level interrupt via stdin (control_request with subtype "interrupt").
	/// This tells Claude Code to cancel the current turn gracefully without killing the process.
	void interrupt()
	{
		import std.uuid : randomUUID;
		auto requestId = randomUUID().toString();
		auto msg = `{"type":"control_request","request_id":"` ~ requestId
			~ `","request":{"subtype":"interrupt"}}`;
		process.writeLine(msg);
	}

	void sigint()
	{
		process.interrupt();
	}

	void stop()
	{
		process.terminate();
	}

	void closeStdin()
	{
		process.closeStdin();
	}

	@property void onOutput(void delegate(string line) dg)
	{
		outputHandler = dg;
	}

	@property void onStderr(void delegate(string line) dg)
	{
		stderrHandler = dg;
	}

	@property void onExit(void delegate(int status) dg)
	{
		exitHandler = dg;
	}

	@property bool alive()
	{
		return !process.dead;
	}
}

private:

struct ClaudeInput
{
	string type;
	ClaudeInputMessage message;
	string session_id;
	string parent_tool_use_id;
}

struct ClaudeInputMessage
{
	string role;
	string content;
}

/// Generate a temporary MCP config file pointing to the cydo binary.
/// creatableTaskTypes is pre-formatted text describing available task types.
/// switchModes is pre-formatted text describing available SwitchMode continuations.
/// handoffs is pre-formatted text describing available Handoff continuations.
/// mcpSocketPath is the absolute path to the backend's UNIX socket for MCP calls.
string generateMcpConfig(int tid, string creatableTaskTypes = "",
	string switchModes = "", string handoffs = "", string mcpSocketPath = "")
{
	import std.file : exists, mkdirRecurse, write;
	import std.path : buildPath;

	auto configDir = buildPath(expandTilde("~/.claude"), "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto cydoBin = cydoBinaryPath;
	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	// MCP config pointing to our binary in MCP server mode.
	// CYDO_SOCKET tells the proxy to connect via UNIX socket (no auth needed).
	auto config = `{"mcpServers":{"cydo":{"type":"stdio","command":"`
		~ escapeJsonString(cydoBin) ~ `","args":["--mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_SOCKET":"`
		~ escapeJsonString(mcpSocketPath) ~ `","CYDO_CREATABLE_TYPES":"`
		~ escapeJsonString(creatableTaskTypes) ~ `","CYDO_SWITCHMODES":"`
		~ escapeJsonString(switchModes) ~ `","CYDO_HANDOFFS":"`
		~ escapeJsonString(handoffs) ~ `"}}}}`;

	write(configPath, config);
	return configPath;
}

/// Absolute path to the currently running cydo binary, resolved at
/// module init to avoid /proc/self/exe returning a "(deleted)" suffix
/// after the binary is replaced by a rebuild.
immutable string cydoBinaryPath;
shared static this()
{
	import std.file : thisExePath;
	cydoBinaryPath = thisExePath();
}

/// Get the directory containing the cydo binary.
string cydoBinaryDir()
{
	auto path = cydoBinaryPath;
	return path.length > 0 ? dirName(path) : "";
}

/// Escape a string for embedding in JSON.
string escapeJsonString(string s)
{
	import std.array : replace;
	return s.replace(`\`, `\\`).replace(`"`, `\"`).replace("\n", `\n`).replace("\r", `\r`).replace("\t", `\t`);
}

/// Resolve the claude binary path by searching PATH.
string resolveClaudeBinary()
{
	import std.algorithm : splitter;
	import std.file : exists, isFile;
	import std.path : buildPath;
	import std.process : environment;

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, "claude");
		if (exists(candidate) && isFile(candidate))
			return dir; // return the directory, not the binary itself
	}
	return "";
}
