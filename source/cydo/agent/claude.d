module cydo.agent.claude;

import std.conv : to;
import std.format : format;
import std.path : dirName, expandTilde;
import std.stdio : stderr;

import ae.utils.json : toJson;
import ae.utils.promise : Promise;

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
					if (*existing == PathMode.rw || *existing == PathMode.always_rw)
						return;
				foreach (existing, existingMode; paths)
					if ((existingMode == PathMode.rw || existingMode == PathMode.always_rw) && path.startsWith(existing ~ "/"))
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
			import std.file : exists, isSymlink, readLink;
			import std.path : absolutePath, buildPath, dirName;
			auto candidate = buildPath(claudeBinDir, "claude");
			if (claudeBinDir.length > 0 && exists(candidate) && isSymlink(candidate))
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

		// Agnostic format (post-translation): flat, content at top level.
		@JSONPartial
		static struct AssistantProbe
		{
			string type;
			ContentBlock[] content;
		}

		// Raw Claude format (pre-translation): nested message wrapper.
		@JSONPartial
		static struct WrappedMessage { ContentBlock[] content; }
		@JSONPartial
		static struct WrappedProbe { string type; WrappedMessage message; }

		try
		{
			auto probe = jsonParse!AssistantProbe(line);
			if (probe.type != "assistant" && probe.type != "message/assistant")
				return "";

			// Flat format (agnostic)
			if (probe.content.length > 0)
			{
				string result;
				foreach (ref block; probe.content)
					if (block.type == "text")
						result ~= block.text;
				return result;
			}

			// Wrapped format (raw Claude, before translation)
			auto wrapped = jsonParse!WrappedProbe(line);
			string result;
			foreach (ref block; wrapped.message.content)
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

	string translateLiveEvent(string rawLine)
	{
		import cydo.agent.protocol : translateClaudeEvent;
		return translateClaudeEvent(rawLine);
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"user"`);
	}

	bool isAssistantMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"assistant"`);
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
		import std.format : format;
		import std.string : indexOf, lineSplitter;

		string[] ids;
		int lineNum = lineOffset;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			// Queue-op enqueue lines become undo anchors for steering messages.
			// Truncating at the enqueue naturally removes the enqueue itself plus
			// all subsequent lines (tool_result, responses, dequeue, echo).
			// Parse the operation field properly to avoid whitespace sensitivity.
			if (line.canFind(`"queue-operation"`))
			{
				import ae.utils.json : jsonParse, JSONPartial;
				@JSONPartial static struct QueueOpProbe { string operation; }
				try
				{
					auto qop = jsonParse!QueueOpProbe(line);
					if (qop.operation == "enqueue")
						ids ~= format!"enqueue-%d"(lineNum);
				}
				catch (Exception) {}
				continue;
			}
			if (!line.canFind(`"type":"user"`) && !line.canFind(`"type":"assistant"`))
				continue;
			// Extract "uuid":"<value>" by prefix scanning
			enum prefix = `"uuid":"`;
			auto idx = line.indexOf(prefix);
			if (idx >= 0)
			{
				auto start = idx + prefix.length;
				auto end = line.indexOf('"', start);
				if (end >= 0 && end > idx + cast(ptrdiff_t) prefix.length)
					ids ~= line[start .. end];
			}
		}
		return ids;
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.algorithm : canFind, startsWith;
		// Handle synthetic enqueue UUID "enqueue-N" (line-number-based).
		// The undo anchor for a steering message is the queue-op-enqueue line;
		// truncating there (excludeMatch=true) removes it and all following lines.
		if (forkId.startsWith("enqueue-"))
		{
			import std.conv : to;
			try
			{
				auto targetLine = forkId["enqueue-".length .. $].to!int;
				if (lineNum != targetLine || !line.canFind(`"queue-operation"`))
					return false;
				// Parse operation field to avoid whitespace sensitivity.
				import ae.utils.json : jsonParse, JSONPartial;
				@JSONPartial static struct QueueOpProbe { string operation; }
				try { return jsonParse!QueueOpProbe(line).operation == "enqueue"; }
				catch (Exception) { return false; }
			}
			catch (Exception)
				return false;
		}
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
			"CLAUDE_BIN": getClaudeBinName(),
		];
		auto result = execute([
			"bash", "-c",
			`exec 2>&1; exec "$CLAUDE_BIN" --resume "$1" --rewind-files "$2" `
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

	Promise!string completeOneShot(string prompt, string modelClass)
	{
		import std.path : buildPath;
		import std.process : environment;
		import std.string : strip;
		import ae.utils.promise : Promise;

		auto promise = new Promise!string;

		auto claudeBinDir = resolveClaudeBinary();
		auto binName = getClaudeBinName();
		import std.algorithm : startsWith;
		auto claudeBin = claudeBinDir.length > 0 && !binName.startsWith("/")
			? buildPath(claudeBinDir, binName) : binName;

		string[string] env = [
			"PATH": environment.get("PATH", ""),
			"HOME": environment.get("HOME", ""),
		];

		AgentProcess proc;
		try
			proc = new AgentProcess([
				claudeBin,
				"-p", prompt,
				"--output-format", "text",
				"--model", resolveModelAlias(modelClass),
				"--max-turns", "1",
				"--tools", "",
				"--no-session-persistence",
			], env, null, true); // noStdin
		catch (Exception e)
		{
			stderr.writeln("completeOneShot: failed to spawn claude: ", e.msg);
			promise.reject(new Exception("failed to spawn claude: " ~ e.msg));
			return promise;
		}

		string responseText;

		proc.onStdoutLine = (string line) {
			responseText ~= line;
		};

		proc.onExit = (int status) {
			if (status != 0)
				promise.reject(new Exception("claude exited with status " ~ status.to!string));
			else
				promise.fulfill(responseText.strip());
		};

		return promise;
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
			getClaudeBinName(),
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

		claudeArgs ~= ["--disallowedTools", "Task,EnterPlanMode,ExitPlanMode,AskUserQuestion"];

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

/// Get the claude binary name/path.
/// If CYDO_CLAUDE_BIN is set, use it (can be absolute path); else "claude".
private string getClaudeBinName()
{
	import std.process : environment;
	return environment.get("CYDO_CLAUDE_BIN", "claude");
}

/// Resolve the claude binary path by searching PATH.
string resolveClaudeBinary()
{
	import std.algorithm : splitter, startsWith;
	import std.file : exists, isFile;
	import std.path : buildPath;
	import std.process : environment;

	auto binName = getClaudeBinName();
	if (binName.startsWith("/"))
		return dirName(binName);

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, binName);
		if (exists(candidate) && isFile(candidate))
			return dir; // return the directory, not the binary itself
	}
	return "";
}
