module cydo.agent.claude;

import std.conv : to;
import std.format : format;
import std.path : dirName, expandTilde;
import std.stdio : stderr;

import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.protocol;
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

		paths[expandTilde("~/.claude")]              = PathMode.rw;
		paths[expandTilde("~/.claude.json")]         = PathMode.rw;
		paths[expandTilde("~/.local/share/claude")]  = PathMode.ro;

		// resolve the claude binary and add its directory as ro;
		// claude's self-updater installs versions under ~/.local/share/claude/versions/
		// and symlinks ~/.local/bin/claude to the active version, so the symlink target
		// directory must also be mounted for execvp to find the actual binary
		auto claudeBinDir = resolveClaudeBinary();
		addIfNotRw(claudeBinDir, PathMode.ro);

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

	private string[string] modelAliasOverrides;
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
		catch (Exception e)
		{ stderr.writeln("extractSessionId: parse error: ", e.msg); }
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
		catch (Exception e)
		{ stderr.writeln("extractResultText: parse error: ", e.msg); return ""; }
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
		catch (Exception e)
		{ stderr.writeln("extractAssistantText: parse error: ", e.msg); return ""; }
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
		catch (Exception e)
		{ stderr.writeln("extractUserContent: all parse attempts failed: ", e.msg); return ""; }
	}

	void setModelAliases(string[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	string resolveModelAlias(string modelClass)
	{
		if (auto p = modelClass in modelAliasOverrides)
			return *p;
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
		return translateClaudeEvent(line);
	}

	string translateLiveEvent(string rawLine)
	{
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
				catch (Exception e) { stderr.writeln("history scan: queue op parse error: ", e.msg); }
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
				catch (Exception e) { stderr.writeln("matchesForkId: queue op parse error: ", e.msg); return false; }
			}
			catch (Exception e)
			{ stderr.writeln("matchesForkId: error: ", e.msg); return false; }
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

// ─── Protocol translation (moved from protocol.d) ────────────────────────

/// Translate a Claude stream-json event to the agent-agnostic protocol.
/// Returns null for events that should be consumed (not forwarded).
package string translateClaudeEvent(string rawLine)
{
	@JSONPartial
	static struct TypeProbe
	{
		string type;
		string subtype;
	}

	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateEvent: type probe parse error: ", e.msg); return rawLine; }

	switch (probe.type)
	{
		case "system":
			return translateSystemEvent(rawLine, probe.subtype);
		case "assistant":
			return translateAssistantMessage(rawLine);
		case "user":
			return normalizeUserMessage(rawLine);
		case "stream_event":
			return translateStreamEvent(rawLine);
		case "result":
			return normalizeTurnResult(rawLine);
		case "summary":
			return renameType(rawLine, "session/summary");
		case "rate_limit_event":
			return renameType(rawLine, "session/rate_limit");
		case "control_response":
			return renameType(rawLine, "control/response");
		case "stderr":
			return renameType(rawLine, "process/stderr");
		case "exit":
			return renameType(rawLine, "process/exit");
		case "queue-operation":
			return null; // consumed — handled by broadcastTask / stateful replay closure
		case "progress":
		case "file-history-snapshot":
			return null; // not used by frontend
		default:
			return rawLine; // unknown → pass through
	}
}

/// Translate system events by mapping subtype to the agnostic type string.
private string translateSystemEvent(string rawLine, string subtype)
{
	switch (subtype)
	{
		case "init":
			return translateSessionInit(rawLine);
		case "status":
			return replaceTypeRemoveSubtype(rawLine, "session/status");
		case "compact_boundary":
			return replaceTypeRemoveSubtype(rawLine, "session/compacted");
		case "task_started":
			return normalizeTaskStarted(rawLine);
		case "task_notification":
			return normalizeTaskNotification(rawLine);
		default:
			return rawLine; // unknown subtypes pass through
	}
}

/// Normalize a Claude session/init event to the agnostic SessionInitEvent format.
/// Renames fields and drops Claude-specific fields.
private string translateSessionInit(string rawLine)
{
	static struct ClaudeInit
	{
		string session_id;
		string model;
		string cwd;
		@JSONOptional string[] tools;
		@JSONOptional string claude_code_version;
		@JSONOptional string permissionMode;
		@JSONOptional string apiKeySource;
		@JSONOptional string fast_mode_state;
		@JSONOptional string[] skills;
		@JSONOptional JSONFragment mcp_servers;
		@JSONOptional JSONFragment agents;
		@JSONOptional JSONFragment plugins;
		@JSONOptional string agent;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		JSONExtras _extras;
	}

	ClaudeInit raw;
	try
		raw = jsonParse!ClaudeInit(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateSystemInit: parse error: ", e.msg); return replaceTypeRemoveSubtype(rawLine, "session/init"); }

	SessionInitEvent ev;
	ev.session_id    = raw.session_id;
	ev.model         = raw.model;
	ev.cwd           = raw.cwd;
	ev.tools         = raw.tools;
	ev.agent_version = raw.claude_code_version;
	ev.permission_mode = raw.permissionMode;
	ev.agent         = raw.agent;
	ev.api_key_source  = raw.apiKeySource;
	ev.fast_mode_state = raw.fast_mode_state;
	ev.skills        = raw.skills;
	ev.mcp_servers   = raw.mcp_servers;
	ev.agents        = raw.agents;
	ev.plugins       = raw.plugins;
	ev.supports_file_revert = true;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Normalize a Claude assistant message to the agnostic AssistantMessageEvent format.
/// Flattens message.* fields to top level, renames isSidechain/isApiErrorMessage,
/// renames thinking blocks' "thinking" field to "text", drops signature.
private string translateAssistantMessage(string rawLine)
{
	static struct ClaudeThinkingBlock
	{
		string type;     // "thinking"
		@JSONOptional string thinking;
		@JSONOptional string text;
		@JSONOptional string id;
		@JSONOptional string name;
		@JSONOptional JSONFragment input;
		@JSONOptional string signature;
		JSONExtras _extras;
	}

	static struct ClaudeMessage
	{
		string id;
		ClaudeThinkingBlock[] content;
		@JSONOptional string model;
		@JSONOptional string stop_reason;
		@JSONOptional int input_tokens;
		@JSONOptional int output_tokens;
		@JSONOptional JSONFragment usage;
		@JSONOptional string stop_sequence;          // TODO: metadata, not forwarded
		@JSONOptional string type;                   // TODO: metadata — always "message", not forwarded
		@JSONOptional string role;                   // TODO: metadata — always "assistant", not forwarded
		@JSONOptional JSONFragment context_management; // TODO: context compaction metadata, not forwarded
		JSONExtras _extras;
	}

	static struct ClaudeAssistant
	{
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isApiErrorMessage;
		@JSONOptional string uuid;
		ClaudeMessage message;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}

	ClaudeAssistant raw;
	try
		raw = jsonParse!ClaudeAssistant(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateAssistant: parse error: ", e.msg); return renameType(rawLine, "message/assistant"); }

	// Build normalized content blocks
	ContentBlock[] content;
	foreach (ref b; raw.message.content)
	{
		ContentBlock cb;
		cb.type = b.type;
		if (b.type == "thinking")
		{
			// Rename "thinking" field → "text"; drop signature
			cb.text = b.thinking.length > 0 ? b.thinking : b.text;
		}
		else if (b.type == "text")
		{
			cb.text = b.text;
		}
		else if (b.type == "tool_use")
		{
			cb.id    = b.id;
			cb.name  = b.name;
			cb.input = b.input;
		}
		cb._extras = extrasToFragment(b._extras);
		content ~= cb;
	}

	// Extract usage
	UsageInfo usage;
	if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
	{
		@JSONPartial
		static struct UsageProbe { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
		try
		{
			auto u = jsonParse!UsageProbe(raw.message.usage.json);
			usage.input_tokens  = u.input_tokens;
			usage.output_tokens = u.output_tokens;
		}
		catch (Exception e) { stderr.writeln("translateAssistant: usage parse error: ", e.msg); }
	}

	AssistantMessageEvent ev;
	ev.id                  = raw.message.id;
	ev.content             = content;
	ev.model               = raw.message.model;
	ev.stop_reason         = raw.message.stop_reason;
	ev.usage               = usage;
	ev.parent_tool_use_id  = raw.parent_tool_use_id;
	ev.is_sidechain        = raw.isSidechain;
	ev.is_api_error        = raw.isApiErrorMessage;
	ev.uuid                = raw.uuid;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}


/// Normalize a Claude user message to the agnostic UserMessageEvent format.
/// Flattens message.content to top level, renames camelCase flags, unifies
/// toolUseResult/tool_use_result → tool_result, drops session_id/slug/role/uuid-less fields.
private string normalizeUserMessage(string rawLine)
{
	static struct ClaudeUserMsg
	{
		JSONFragment content;
		@JSONOptional string role; // TODO: metadata — always "user", not forwarded
		JSONExtras _extras;
	}

	static struct ClaudeUser
	{
		ClaudeUserMsg message;
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isReplay;
		@JSONOptional bool isSynthetic;
		@JSONOptional bool isMeta;
		@JSONOptional bool isSteering;
		@JSONOptional bool pending;
		@JSONOptional string uuid;
		@JSONOptional JSONFragment toolUseResult;
		@JSONOptional JSONFragment tool_use_result;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}

	ClaudeUser raw;
	try
		raw = jsonParse!ClaudeUser(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateUser: parse error: ", e.msg); return renameType(rawLine, "message/user"); }

	UserMessageEvent ev;
	ev.content            = raw.message.content;
	ev.parent_tool_use_id = raw.parent_tool_use_id;
	ev.is_sidechain       = raw.isSidechain;
	ev.is_replay          = raw.isReplay;
	ev.is_synthetic       = raw.isSynthetic;
	ev.is_meta            = raw.isMeta;
	ev.is_steering        = raw.isSteering;
	ev.pending            = raw.pending;
	ev.uuid               = raw.uuid;
	if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
		ev.tool_result = raw.toolUseResult;
	else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
		ev.tool_result = raw.tool_use_result;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Normalize a Claude result event to the agnostic TurnResultEvent format.
/// Renames modelUsage → model_usage, normalizes usage to input/output only,
/// drops uuid and session_id.
private string normalizeTurnResult(string rawLine)
{
	static struct ClaudeUsage
	{
		@JSONOptional int input_tokens;
		@JSONOptional int output_tokens;
		JSONExtras _extras;
	}

	static struct ClaudeResult
	{
		string subtype;
		bool is_error;
		@JSONOptional string result;
		int num_turns;
		int duration_ms;
		@JSONOptional int duration_api_ms;
		double total_cost_usd;
		@JSONOptional ClaudeUsage usage;
		@JSONOptional JSONFragment modelUsage;
		@JSONOptional JSONFragment model_usage;
		@JSONOptional JSONFragment permission_denials;
		@JSONOptional string stop_reason;
		@JSONOptional string[] errors;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}

	ClaudeResult raw;
	try
		raw = jsonParse!ClaudeResult(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateResult: parse error: ", e.msg); return renameType(rawLine, "turn/result"); }

	TurnResultEvent ev;
	ev.subtype            = raw.subtype;
	ev.is_error           = raw.is_error;
	ev.result             = raw.result;
	ev.num_turns          = raw.num_turns;
	ev.duration_ms        = raw.duration_ms;
	ev.duration_api_ms    = raw.duration_api_ms;
	ev.total_cost_usd     = raw.total_cost_usd;
	ev.usage              = UsageInfo(raw.usage.input_tokens, raw.usage.output_tokens);
	if (raw.modelUsage.json !is null && raw.modelUsage.json.length > 0)
		ev.model_usage = raw.modelUsage;
	else if (raw.model_usage.json !is null && raw.model_usage.json.length > 0)
		ev.model_usage = raw.model_usage;
	ev.permission_denials = raw.permission_denials;
	ev.stop_reason        = raw.stop_reason;
	ev.errors             = raw.errors;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Translate stream_event: unwrap inner event and map to stream/* types.
private string translateStreamEvent(string rawLine)
{
	import std.algorithm : canFind;
	import std.string : indexOf;

	// Extract the inner event object
	auto eventStart = rawLine.indexOf(`"event":`);
	if (eventStart < 0)
		return rawLine;

	// Find the start of the event value (skip whitespace after colon)
	auto valueStart = eventStart + `"event":`.length;
	while (valueStart < rawLine.length && rawLine[valueStart] == ' ')
		valueStart++;

	if (valueStart >= rawLine.length || rawLine[valueStart] != '{')
		return rawLine;

	// Find matching closing brace
	auto innerEnd = findMatchingBrace(rawLine, valueStart);
	if (innerEnd < 0)
		return rawLine;

	auto innerEvent = rawLine[valueStart .. innerEnd + 1];

	// Probe the inner event's type
	@JSONPartial
	static struct InnerProbe
	{
		string type;
	}

	InnerProbe inner;
	try
		inner = jsonParse!InnerProbe(innerEvent);
	catch (Exception e)
	{ stderr.writeln("translateStreamEvent: inner probe parse error: ", e.msg); return rawLine; }

	string newType;
	switch (inner.type)
	{
		case "content_block_start":
			newType = "stream/block_start";
			break;
		case "content_block_delta":
		{
			// Probe delta type — drop signature_delta, rename thinking_delta field
			@JSONPartial
			static struct BlockDeltaProbe
			{
				@JSONPartial
				static struct DeltaProbe
				{
					string type;
					@JSONOptional string thinking;
				}
				int index;
				DeltaProbe delta;
			}
			try
			{
				auto probe = jsonParse!BlockDeltaProbe(innerEvent);
				if (probe.delta.type == "signature_delta")
					return null; // drop
				if (probe.delta.type == "thinking_delta")
				{
					StreamBlockDeltaEvent ev;
					ev.index = probe.index;
					ev.delta.type = "thinking_delta";
					ev.delta.text = probe.delta.thinking;
					return toJson(ev);
				}
			}
			catch (Exception e) { stderr.writeln("translateStreamEvent: thinking delta parse error: ", e.msg); }
			newType = "stream/block_delta";
			break;
		}
		case "content_block_stop":
			newType = "stream/block_stop";
			break;
		case "message_stop":
			newType = "stream/turn_stop";
			break;
		case "message_start":
		case "message_delta":
			return null; // consumed — usage/stop_reason arrives in turn/result
		default:
			return rawLine; // unknown inner types pass through
	}

	// Replace the inner event's type with the agnostic type and promote to top level.
	// The result is: the inner event object with its "type" replaced.
	return renameType(innerEvent, newType);
}

/// Rename the top-level "type" field in a JSON line. Preserves all other fields.
/// Uses brace-depth tracking so nested "type" fields (e.g. inside "message")
/// are not accidentally matched.
private string renameType(string rawLine, string newType)
{
	auto typeIdx = findTopLevelType(rawLine);
	if (typeIdx < 0)
		return rawLine;

	auto valueStart = typeIdx + `"type":"`.length;
	// Find closing quote of value
	foreach (i; valueStart .. rawLine.length)
	{
		if (rawLine[i] == '"')
			return rawLine[0 .. typeIdx] ~ `"type":"` ~ newType ~ `"` ~ rawLine[i + 1 .. $];
	}
	return rawLine;
}

/// Convert a JSONExtras map to a JSONFragment wrapping it in a JSON object.
/// Returns JSONFragment.init (null) if the extras map is empty.
private JSONFragment extrasToFragment(JSONExtras extras)
{
	if (extras._data is null || extras._data.length == 0)
		return JSONFragment.init;
	return JSONFragment(toJson(extras._data));
}

/// Recursively collect all JSONExtras from a struct and its nested struct fields.
/// Arrays are skipped (content blocks are handled per-element by the caller).
private JSONExtras collectAllExtras(S)(ref const S s)
{
	JSONExtras result;
	static foreach (i, field; S.tupleof)
	{{
		alias FT = typeof(field);
		static if (is(FT == JSONExtras))
		{
			if (s.tupleof[i]._data !is null)
				foreach (k, v; s.tupleof[i]._data)
					result[k] = v;
		}
		else static if (is(FT == struct) && !is(FT == JSONFragment))
		{
			auto nested = collectAllExtras(s.tupleof[i]);
			if (nested._data !is null)
				foreach (k, v; nested._data)
					result[k] = v;
		}
	}}
	return result;
}

/// Find the byte offset of the top-level `"type":"` in a JSON object string.
/// Returns -1 if not found.  Only matches at brace depth 1 (top-level keys).
private int findTopLevelType(string s)
{
	int depth = 0;
	bool inString = false;
	bool escaped = false;
	enum needle = `"type":"`;

	foreach (i; 0 .. s.length)
	{
		auto c = s[i];
		if (escaped)
		{
			escaped = false;
			continue;
		}
		if (c == '\\' && inString)
		{
			escaped = true;
			continue;
		}
		if (c == '"' && !inString)
		{
			// Starting a key or value at the current depth.
			// Check for needle match at top-level (depth 1).
			if (depth == 1 && i + needle.length <= s.length
				&& s[i .. i + needle.length] == needle)
				return cast(int) i;
			inString = true;
			continue;
		}
		if (c == '"')
		{
			inString = false;
			continue;
		}
		if (inString)
			continue;
		if (c == '{')
			depth++;
		else if (c == '}')
			depth--;
	}
	return -1;
}

/// Replace "type":"system" with the new type and remove "subtype":"..." field.
private string replaceTypeRemoveSubtype(string rawLine, string newType)
{
	import std.string : indexOf;

	// First rename the type
	auto renamed = renameType(rawLine, newType);

	// Then remove the subtype field
	auto subtypeIdx = renamed.indexOf(`"subtype":"`);
	if (subtypeIdx < 0)
		return renamed;

	// Find the extent of "subtype":"value"
	auto subtypeValueStart = subtypeIdx + `"subtype":"`.length;
	auto subtypeValueEnd = renamed.indexOf('"', subtypeValueStart);
	if (subtypeValueEnd < 0)
		return renamed;

	auto fieldEnd = subtypeValueEnd + 1;

	// Remove trailing comma if present, or leading comma
	if (fieldEnd < renamed.length && renamed[fieldEnd] == ',')
		fieldEnd++;
	else if (subtypeIdx > 0 && renamed[subtypeIdx - 1] == ',')
		subtypeIdx--;

	return renamed[0 .. subtypeIdx] ~ renamed[fieldEnd .. $];
}

/// Normalize a Claude task_started system event to the agnostic TaskStartedEvent format.
/// Drops uuid and session_id fields.
private string normalizeTaskStarted(string rawLine)
{
	static struct ClaudeTaskStarted
	{
		string task_id;
		@JSONOptional string tool_use_id;
		@JSONOptional string description;
		@JSONOptional string task_type;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}

	ClaudeTaskStarted raw;
	try
		raw = jsonParse!ClaudeTaskStarted(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateTaskStarted: parse error: ", e.msg); return replaceTypeRemoveSubtype(rawLine, "task/started"); }

	TaskStartedEvent ev;
	ev.task_id      = raw.task_id;
	ev.tool_use_id  = raw.tool_use_id;
	ev.description  = raw.description;
	ev.task_type    = raw.task_type;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Normalize a Claude task_notification system event to the agnostic TaskNotificationEvent format.
/// Drops uuid and session_id fields.
private string normalizeTaskNotification(string rawLine)
{
	static struct ClaudeTaskNotification
	{
		string task_id;
		string status;
		@JSONOptional string output_file;
		@JSONOptional string summary;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}

	ClaudeTaskNotification raw;
	try
		raw = jsonParse!ClaudeTaskNotification(rawLine);
	catch (Exception e)
	{ stderr.writeln("translateTaskNotification: parse error: ", e.msg); return replaceTypeRemoveSubtype(rawLine, "task/notification"); }

	TaskNotificationEvent ev;
	ev.task_id     = raw.task_id;
	ev.status      = raw.status;
	ev.output_file = raw.output_file;
	ev.summary     = raw.summary;
	ev._extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Find the index of the closing brace matching the opening brace at pos.
private int findMatchingBrace(string s, size_t pos)
{
	if (pos >= s.length || s[pos] != '{')
		return -1;

	int depth = 0;
	bool inString = false;
	bool escaped = false;

	foreach (i; pos .. s.length)
	{
		auto c = s[i];
		if (escaped)
		{
			escaped = false;
			continue;
		}
		if (c == '\\' && inString)
		{
			escaped = true;
			continue;
		}
		if (c == '"')
		{
			inString = !inString;
			continue;
		}
		if (inString)
			continue;
		if (c == '{')
			depth++;
		else if (c == '}')
		{
			depth--;
			if (depth == 0)
				return cast(int) i;
		}
	}
	return -1;
}
