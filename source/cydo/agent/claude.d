module cydo.agent.claude;

import std.conv : to;
import std.format : format;
import std.path : dirName, expandTilde;
import std.logger : errorf, tracef, warningf;

import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.agent.agent : Agent, DiscoveredSession, OneShotHandle, SessionConfig, SessionMeta;
import cydo.agent.protocol;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;
import cydo.sandbox : cydoBinaryDir, cydoBinaryPath;

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
	// Background thread: sessionId → file path (populated by enumerateAllSessions)
	private string[string] sessionIdToPath_;

	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }

	AgentSession createSession(int tid, string resumeSessionId, string[] cmdPrefix,
		SessionConfig config = SessionConfig.init)
	{
		lastMcpConfigPath_ = generateMcpConfig(tid, config.creatableTaskTypes,
			config.switchModes, config.handoffs, config.includeTools, config.mcpSocketPath);
		return new ClaudeCodeSession(resumeSessionId, cmdPrefix, lastMcpConfigPath_, config);
	}

	string parseSessionId(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		// ClaudeCodeSession emits translated session/init events.
		if (!line.canFind(`"session/init"`) && !line.canFind(`"subtype":"init"`))
			return null;

		@JSONPartial
		static struct InitProbe
		{
			string type;
			@JSONOptional string session_id;
		}

		try
		{
			auto probe = jsonParse!InitProbe(line);
			if (probe.type == "session/init" && probe.session_id.length > 0)
				return probe.session_id;
		}
		catch (Exception e)
		{ tracef("extractSessionId: parse error: %s", e.msg); }
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
			// ClaudeCodeSession emits translated turn/result events.
			if (probe.type == "turn/result" || probe.type == "result")
				return probe.result;
			return "";
		}
		catch (Exception e)
		{ tracef("extractResultText: parse error: %s", e.msg); return ""; }
	}

	string extractAssistantText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		// New format: item/started with item_type=text carries the full text
		// (present in history-translated events from translateAssistantHistory).
		if (line.canFind(`"item/started"`))
		{
			@JSONPartial static struct ItemStartedProbe { string type; string item_type; string text; }
			try
			{
				auto probe = jsonParse!ItemStartedProbe(line);
				if (probe.type == "item/started" && probe.item_type == "text" && probe.text.length > 0)
					return probe.text;
			}
			catch (Exception) {}
		}

		return "";
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
		{ tracef("extractUserContent: all parse attempts failed: %s", e.msg); return ""; }
	}

	DiscoveredSession[] enumerateAllSessions()
	{
		import std.file : DirEntry, dirEntries, exists, isDir, SpanMode;
		import std.path : baseName, buildPath;
		import std.process : environment;

		auto home = environment.get("HOME", "/tmp");
		auto claudeDir = environment.get("CLAUDE_CONFIG_DIR", buildPath(home, ".claude"));
		auto projectsDir = buildPath(claudeDir, "projects");
		if (!exists(projectsDir) || !isDir(projectsDir))
			return [];

		sessionIdToPath_ = null;
		DiscoveredSession[] result;
		foreach (DirEntry projEntry; dirEntries(projectsDir, SpanMode.shallow))
		{
			if (!projEntry.isDir)
				continue;
			// Best-effort reverse-mangle: replace - with / (correct for paths without dots)
			auto mangledName = baseName(projEntry.name);
			auto projectPathBuf = mangledName.dup;
			foreach (ref c; projectPathBuf)
				if (c == '-')
					c = '/';
			string projectPath = projectPathBuf.idup;

			try
			{
				foreach (DirEntry fileEntry; dirEntries(projEntry.name, "*.jsonl", SpanMode.shallow))
				{
					auto sessionId = baseName(fileEntry.name, ".jsonl");
					sessionIdToPath_[sessionId] = fileEntry.name;
					DiscoveredSession ds;
					ds.sessionId = sessionId;
					ds.mtime = fileEntry.timeLastModified.stdTime;
					ds.projectPath = projectPath;
					result ~= ds;
				}
			}
			catch (Exception e)
			{ tracef("enumerateAllSessions: error scanning %s: %s", projEntry.name, e.msg); }
		}
		return result;
	}

	SessionMeta readSessionMeta(string sessionId)
	{
		import std.stdio : File;
		import cydo.task : truncateTitle;

		auto pathp = sessionId in sessionIdToPath_;
		if (pathp is null)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(*pathp, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				// Extract cwd from init event (first line is typically system/init)
				if (meta.projectPath.length == 0 && lineStr.length > 0)
				{
					import std.algorithm : canFind;
					if (lineStr.canFind(`"type":"system"`) && lineStr.canFind(`"subtype":"init"`))
					{
						@JSONPartial
						static struct InitProbe
						{
							string type;
							string subtype;
							string cwd;
						}
						try
						{
							auto probe = jsonParse!InitProbe(lineStr);
							if (probe.type == "system" && probe.subtype == "init" && probe.cwd.length > 0)
								meta.projectPath = probe.cwd;
						}
						catch (Exception) {}
					}
				}
				// Extract title from first user message
				if (meta.title.length == 0)
				{
					auto text = extractUserText(lineStr);
					if (text.length > 0)
						meta.title = truncateTitle(text, 80);
				}
				if (meta.title.length > 0 && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{ tracef("readSessionMeta(%s): error: %s", sessionId, e.msg); }
		return meta;
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

	string[] translateHistoryLine(string line, int lineNum)
	{
		return translateClaudeHistoryEvent(line);
	}

	string[] translateLiveEvent(string rawLine)
	{
		// ClaudeCodeSession handles translation statefully inline.
		// This is an identity pass-through for pre-translated events.
		return [rawLine];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		// ClaudeCodeSession emits translated turn/result events.
		return rawLine.canFind(`"type":"turn/result"`);
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
				catch (Exception e) { tracef("history scan: queue op parse error: %s", e.msg); }
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
				catch (Exception e) { tracef("matchesForkId: queue op parse error: %s", e.msg); return false; }
			}
			catch (Exception e)
			{ tracef("matchesForkId: error: %s", e.msg); return false; }
		}
		return line.canFind(`"uuid":"` ~ forkId ~ `"`);
	}

	bool isForkableLine(string line)
	{
		import std.algorithm : canFind;
		return line.canFind(`"type":"user"`) || line.canFind(`"type":"assistant"`);
	}

	@property bool needsBash() { return false; }
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

	OneShotHandle completeOneShot(string prompt, string modelClass)
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
			errorf("completeOneShot: failed to spawn claude: %s", e.msg);
			promise.reject(new Exception("failed to spawn claude: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		string responseText;
		string stderrText;

		proc.onStdoutLine = (string line) {
			responseText ~= line;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			if (status != 0)
			{
				auto msg = "claude exited with status " ~ status.to!string;
				auto details = stderrText.strip();
				if (details.length > 0)
					msg ~= ": " ~ details;
				promise.reject(new Exception(msg));
			}
			else
				promise.fulfill(responseText.strip());
		};

		void cancel() { proc.sendSignal(15); } // SIGTERM; no-op if already exited

		return OneShotHandle(promise, &cancel);
	}
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private void delegate(string line) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	// Stateful translation: track active content blocks per index.
	private string[] activeItemIds_;   // index → item_id for current turn
	private string[] activeItemTypes_; // index → "text", "thinking", "tool_use"
	private JSONFragment[string] blockExtras_; // item_id → extras from assistant event

	this(string resumeSessionId = null, string[] cmdPrefix = null,
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

		string disallowed = config.allowNativeSubagents
			? "EnterPlanMode,ExitPlanMode,AskUserQuestion"
			: "Task,EnterPlanMode,ExitPlanMode,AskUserQuestion";
		claudeArgs ~= ["--disallowedTools", disallowed];

		// When sandboxed, cmdPrefix handles workDir via --chdir (bwrap) or -C (env)
		string[] args;
		if (cmdPrefix !is null)
			args = cmdPrefix ~ claudeArgs;
		else
			args = claudeArgs;

		process = new AgentProcess(args, null, null, false, FramingMode.ndjson, "claude");

		process.onStdoutLine = (string line) {
			translateLiveLine(line);
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
	void sendMessage(const(ContentBlock)[] content)
	{
		// Use plain string content when possible (single text block) for backward
		// compatibility with Claude CLI's JSONL format.  Array content is only
		// needed when images or multiple blocks are present.
		JSONFragment claudeContent;
		if (content.length == 1 && content[0].type == "text")
			claudeContent = JSONFragment(toJson(content[0].text));
		else
			claudeContent = buildClaudeContentBlocks(content);
		auto input = ClaudeInput(
			"user",
			ClaudeInputMessage("user", claudeContent),
			"default",
			null,
		);
		process.sendMessage(toJson(input));
	}

	@property bool supportsImages() const { return true; }

	/// Send a protocol-level interrupt via stdin (control_request with subtype "interrupt").
	/// This tells Claude Code to cancel the current turn gracefully without killing the process.
	void interrupt()
	{
		import std.uuid : randomUUID;
		auto requestId = randomUUID().toString();
		auto msg = `{"type":"control_request","request_id":"` ~ requestId
			~ `","request":{"subtype":"interrupt"}}`;
		process.sendMessage(msg);
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

	// ── Stateful per-line translation ──────────────────────────────────────

	private void emitEvent(string event)
	{
		if (outputHandler && event.length > 0)
			outputHandler(event);
	}

	private void translateLiveLine(string rawLine)
	{
		import std.algorithm : canFind;

		// Queue operations must pass through raw so broadcastTask can intercept them.
		if (rawLine.canFind(`"queue-operation"`))
		{
			emitEvent(rawLine);
			return;
		}

		@JSONPartial static struct TypeProbe { string type; string subtype; }
		TypeProbe probe;
		try
			probe = jsonParse!TypeProbe(rawLine);
		catch (Exception)
		{
			import cydo.agent.protocol : makeUnrecognizedEvent;
			emitEvent(makeUnrecognizedEvent("non-JSON output", rawLine));
			return;
		}

		switch (probe.type)
		{
			case "stream_event":
				translateStreamEventLive(rawLine);
				return;
			case "assistant":
				translateAssistantLive(rawLine);
				return;
			case "user":
				normalizeUserLive(rawLine);
				return;
			default:
				// Stateless translation for system, result, summary, control, etc.
				auto t = translateClaudeEvent(rawLine);
				if (t !is null)
					emitEvent(t);
				return;
		}
	}

	private void translateStreamEventLive(string rawLine)
	{
		import std.string : indexOf;

		// Extract the inner event object from {type:"stream_event", event:{...}}
		auto eventStart = rawLine.indexOf(`"event":`);
		if (eventStart < 0) return;
		auto valueStart = cast(size_t)(eventStart + `"event":`.length);
		while (valueStart < rawLine.length && rawLine[valueStart] == ' ')
			valueStart++;
		if (valueStart >= rawLine.length || rawLine[valueStart] != '{') return;
		auto innerEnd = findMatchingBrace(rawLine, valueStart);
		if (innerEnd < 0) return;
		auto innerEvent = rawLine[valueStart .. innerEnd + 1];

		@JSONPartial static struct InnerProbe { string type; }
		InnerProbe inner;
		try
			inner = jsonParse!InnerProbe(innerEvent);
		catch (Exception e)
		{ tracef("translateStreamEventLive: inner probe error: %s", e.msg); return; }

		switch (inner.type)
		{
			case "content_block_start":
			{
				@JSONPartial
				static struct BlockStartProbe
				{
					int index;
					@JSONPartial
					static struct BD { string type; @JSONOptional string id; @JSONOptional string name; }
					BD content_block;
				}
				try
				{
					auto probe = jsonParse!BlockStartProbe(innerEvent);
					auto idx = probe.index;
					auto blockType = probe.content_block.type;

					// Assign item_id: use block.id for tool_use, generate for text/thinking.
					string itemId = blockType == "tool_use" && probe.content_block.id.length > 0
						? probe.content_block.id
						: "cc-block-" ~ to!string(idx);

					// Grow tracking arrays.
					while (activeItemIds_.length <= idx) activeItemIds_ ~= null;
					while (activeItemTypes_.length <= idx) activeItemTypes_ ~= null;
					activeItemIds_[idx] = itemId;
					activeItemTypes_[idx] = blockType;

					import cydo.agent.protocol : ItemStartedEvent, injectRawField, decomposeToolName;
					ItemStartedEvent ev;
					ev.item_id = itemId;
					ev.item_type = blockType;
					if (blockType == "tool_use")
						decomposeToolName(probe.content_block.name, ev.name, ev.tool_server, ev.tool_source);
					emitEvent(injectRawField(toJson(ev), rawLine));
				}
				catch (Exception e)
				{ tracef("translateStreamEventLive: block_start error: %s", e.msg); }
				return;
			}

			case "content_block_delta":
			{
				@JSONPartial
				static struct BlockDeltaProbe
				{
					int index;
					@JSONPartial
					static struct DP
					{
						string type;
						@JSONOptional string text;
						@JSONOptional string partial_json;
						@JSONOptional string thinking;
					}
					DP delta;
				}
				try
				{
					auto probe = jsonParse!BlockDeltaProbe(innerEvent);
					auto idx = probe.index;
					if (probe.delta.type == "signature_delta")
						return; // drop
					if (idx >= activeItemIds_.length || activeItemIds_[idx] is null)
						return;

					import cydo.agent.protocol : ItemDeltaEvent;
					ItemDeltaEvent ev;
					ev.item_id = activeItemIds_[idx];
					if (probe.delta.type == "thinking_delta")
					{
						ev.delta_type = "thinking_delta";
						ev.content = probe.delta.thinking;
					}
					else if (probe.delta.type == "input_json_delta")
					{
						ev.delta_type = "input_json_delta";
						ev.content = probe.delta.partial_json;
					}
					else
					{
						ev.delta_type = "text_delta";
						ev.content = probe.delta.text;
					}
					emitEvent(toJson(ev));
				}
				catch (Exception e)
				{ tracef("translateStreamEventLive: block_delta error: %s", e.msg); }
				return;
			}

			case "content_block_stop":
			{
				@JSONPartial static struct StopProbe { int index; }
				try
				{
					auto probe = jsonParse!StopProbe(innerEvent);
					auto idx = probe.index;
					if (idx < activeItemIds_.length && activeItemIds_[idx] !is null)
					{
						import cydo.agent.protocol : ItemCompletedEvent, injectRawField;
						ItemCompletedEvent ev;
						ev.item_id = activeItemIds_[idx];
						if (auto extras = activeItemIds_[idx] in blockExtras_)
							ev._extras = *extras;
						emitEvent(injectRawField(toJson(ev), rawLine));
					}
				}
				catch (Exception e)
				{ tracef("content_block_stop: parse error: %s", e.msg); }
				return;
			}

			case "message_stop":
			{
				import cydo.agent.protocol : TurnStopEvent, injectRawField;
				TurnStopEvent tsev;
				emitEvent(injectRawField(toJson(tsev), rawLine));
				activeItemIds_ = null;
				activeItemTypes_ = null;
				blockExtras_ = null;
				return;
			}
			case "message_start":
			case "message_delta":
				return; // drop

			default:
				return; // unknown inner events — drop
		}
	}

	/// Translate an assistant NDJSON event to a turn/delta metadata event.
	/// Content promotion is handled by content_block_stop → item/completed.
	private void translateAssistantLive(string rawLine)
	{
		import cydo.agent.protocol : TurnDeltaEvent, UsageInfo, injectRawField;

		@JSONPartial static struct ClaudeBlock
		{
			string type;
			@JSONOptional string id;
			@JSONOptional string name;
			@JSONOptional JSONFragment input;
			@JSONOptional string text;
			@JSONOptional string thinking;
			@JSONOptional string signature;
			JSONExtras _extras;
		}
		@JSONPartial static struct ClaudeMessage
		{
			@JSONOptional string model;
			@JSONOptional JSONFragment usage;
			@JSONOptional ClaudeBlock[] content;
		}
		// Full struct with JSONExtras to capture unknown top-level fields.
		// All known Claude Code fields are listed so they are not captured as extras.
		static struct ClaudeAssistant
		{
			@JSONOptional string parent_tool_use_id;
			@JSONOptional bool isSidechain;
			@JSONOptional bool isApiErrorMessage;
			@JSONOptional string uuid;
			ClaudeMessage message;
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
		{ tracef("translateAssistantLive: parse error: %s", e.msg); return; }

		UsageInfo usage;
		if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
		{
			@JSONPartial static struct UP { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
			try
			{
				auto u = jsonParse!UP(raw.message.usage.json);
				usage.input_tokens  = u.input_tokens;
				usage.output_tokens = u.output_tokens;
			}
			catch (Exception) {}
		}

		// Cache per-block extras so content_block_stop can attach them.
		foreach (idx, ref b; raw.message.content)
		{
			auto frag = extrasToFragment(b._extras);
			if (frag.json !is null && frag.json.length > 0)
			{
				string itemId;
				if (idx < activeItemIds_.length && activeItemIds_[idx].length > 0)
					itemId = activeItemIds_[idx];
				else if (b.type == "tool_use" && b.id.length > 0)
					itemId = b.id;
				else
					itemId = "cc-block-" ~ to!string(idx);
				blockExtras_[itemId] = frag;
			}
		}

		TurnDeltaEvent ev;
		ev.model              = raw.message.model;
		ev.usage              = usage;
		ev.parent_tool_use_id = raw.parent_tool_use_id;
		ev.is_sidechain       = raw.isSidechain;
		ev.is_api_error       = raw.isApiErrorMessage;
		ev.uuid               = raw.uuid;
		ev._extras            = extrasToFragment(raw._extras);
		emitEvent(injectRawField(toJson(ev), rawLine));
	}

	private void normalizeUserLive(string rawLine)
	{
		import cydo.agent.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent, injectRawField;

		@JSONPartial static struct ClaudeUserMsg { JSONFragment content; }
		@JSONPartial static struct ClaudeUser
		{
			ClaudeUserMsg message;
			@JSONOptional bool isReplay;
			@JSONOptional bool isSynthetic;
			@JSONOptional bool isMeta;
			@JSONOptional bool isSteering;
			@JSONOptional bool pending;
			@JSONOptional string uuid;
			@JSONOptional string parent_tool_use_id;
			@JSONOptional bool isSidechain;
			@JSONOptional JSONFragment toolUseResult;
			@JSONOptional JSONFragment tool_use_result;
		}

		ClaudeUser raw;
		try
			raw = jsonParse!ClaudeUser(rawLine);
		catch (Exception e)
		{ tracef("normalizeUserLive: parse error: %s", e.msg); return; }

		auto contentJson = raw.message.content.json;
		if (contentJson is null || contentJson.length == 0)
			return;

		if (contentJson[0] == '"')
		{
			// String content → user_message item.
			string text;
			try text = jsonParse!string(contentJson);
			catch (Exception) {}

			ContentBlock cb;
			cb.type = "text";
			cb.text = text;

			ItemStartedEvent ev;
			ev.item_id   = "cc-user-msg";
			ev.item_type = "user_message";
			ev.text      = text;
			ev.content   = [cb];
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering = raw.isSteering;
			ev.pending     = raw.pending;
			ev.uuid        = raw.uuid;
			emitEvent(injectRawField(toJson(ev), rawLine));
		}
		else if (contentJson[0] == '[')
		{
			// Array content — tool_results and/or text/image blocks.
			@JSONPartial
			static struct ImageSource
			{
				@JSONOptional string data;
				@JSONOptional string media_type;
			}
			@JSONPartial
			static struct ContentItem
			{
				string type;
				@JSONOptional string tool_use_id;
				@JSONOptional JSONFragment content;
				@JSONOptional bool is_error;
				@JSONOptional string text;
				@JSONOptional ImageSource source;
			}
			ContentItem[] items;
			try items = jsonParse!(ContentItem[])(contentJson);
			catch (Exception e) { tracef("normalizeUserLive: content parse error: %s", e.msg); return; }

			// Collect user content blocks (text + image); emit tool_results separately.
			ContentBlock[] userBlocks;
			foreach (ref item; items)
			{
				if (item.type == "tool_result")
				{
					ItemResultEvent ev;
					ev.item_id  = item.tool_use_id;
					auto cj = item.content.json;
					if (cj is null || cj.length == 0)
						ev.content = JSONFragment(`[{"type":"text","text":""}]`);
					else if (cj[0] == '"')
						ev.content = JSONFragment(`[{"type":"text","text":` ~ cj ~ `}]`);
					else
						ev.content = item.content;
					ev.is_error = item.is_error;
					if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
						ev.tool_result = raw.toolUseResult;
					else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
						ev.tool_result = raw.tool_use_result;
					emitEvent(injectRawField(toJson(ev), rawLine));
				}
				else if (item.type == "text")
				{
					ContentBlock cb;
					cb.type = "text";
					cb.text = item.text;
					userBlocks ~= cb;
				}
				else if (item.type == "image")
				{
					ContentBlock cb;
					cb.type       = "image";
					cb.data       = item.source.data;
					cb.media_type = item.source.media_type;
					userBlocks ~= cb;
				}
			}

			if (userBlocks.length > 0)
			{
				import cydo.agent.protocol : extractContentText;
				ItemStartedEvent ev;
				ev.item_id   = "cc-user-msg";
				ev.item_type = "user_message";
				ev.text      = extractContentText(userBlocks);
				ev.content   = userBlocks;
				ev.is_replay   = raw.isReplay;
				ev.is_synthetic = raw.isSynthetic;
				ev.is_meta     = raw.isMeta;
				ev.is_steering = raw.isSteering;
				ev.pending     = raw.pending;
				ev.uuid        = raw.uuid;
				emitEvent(injectRawField(toJson(ev), rawLine));
			}
		}
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
	JSONFragment content;  // string or content block array (JSONFragment serializes as-is)
}

/// Generate a temporary MCP config file pointing to the cydo binary.
/// creatableTaskTypes is pre-formatted text describing available task types.
/// switchModes is pre-formatted text describing available SwitchMode continuations.
/// handoffs is pre-formatted text describing available Handoff continuations.
/// mcpSocketPath is the absolute path to the backend's UNIX socket for MCP calls.
string generateMcpConfig(int tid, string creatableTaskTypes = "",
	string switchModes = "", string handoffs = "", string[] includeTools = null, string mcpSocketPath = "")
{
	import std.array : join;
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
		~ escapeJsonString(cydoBin) ~ `","args":["mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_SOCKET":"`
		~ escapeJsonString(mcpSocketPath) ~ `","CYDO_CREATABLE_TYPES":"`
		~ escapeJsonString(creatableTaskTypes) ~ `","CYDO_SWITCHMODES":"`
		~ escapeJsonString(switchModes) ~ `","CYDO_HANDOFFS":"`
		~ escapeJsonString(handoffs) ~ `","CYDO_INCLUDE_TOOLS":"`
		~ escapeJsonString(includeTools is null ? "" : includeTools.join(",")) ~ `"}}}}`;

	write(configPath, config);
	return configPath;
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
package string resolveClaudeBinary()
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

/// Build a Claude-wire-format content array from agnostic ContentBlock[].
/// Returns a JSONFragment suitable for embedding in ClaudeInputMessage.content.
private JSONFragment buildClaudeContentBlocks(const(ContentBlock)[] blocks)
{
	import cydo.agent.protocol : ContentBlock;

	string json = "[";
	foreach (i, ref b; blocks)
	{
		if (i > 0) json ~= ",";
		if (b.type == "text")
		{
			json ~= `{"type":"text","text":` ~ toJson(b.text) ~ `}`;
		}
		else if (b.type == "image")
		{
			json ~= `{"type":"image","source":{"type":"base64","data":` ~ toJson(b.data)
				~ `,"media_type":` ~ toJson(b.media_type) ~ `}}`;
		}
		else
		{
			throw new Exception("Unsupported content block type for Claude: " ~ b.type);
		}
	}
	json ~= "]";
	return JSONFragment(json);
}

// ─── Protocol translation (moved from protocol.d) ────────────────────────

// ─── History translation (stateless — complete JSONL messages) ────────────

/// Route a raw Claude JSONL history line to the appropriate translator.
/// Returns zero or more agnostic event strings.
private string[] translateClaudeHistoryEvent(string rawLine)
{
	@JSONPartial static struct TypeProbe { string type; string subtype; }
	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception)
	{ return [rawLine]; }

	switch (probe.type)
	{
		case "assistant":
			return translateAssistantHistory(rawLine);
		case "user":
			return normalizeUserHistory(rawLine);
		case "stream_event":
			return []; // not stored in JSONL history
		default:
			auto t = translateClaudeEvent(rawLine);
			return t !is null ? [t] : [];
	}
}

/// Translate a Claude history assistant message to item/started+completed per block + turn/stop.
private string[] translateAssistantHistory(string rawLine)
{
	import cydo.agent.protocol : ItemStartedEvent, ItemCompletedEvent, TurnStopEvent,
		UsageInfo, injectRawField, decomposeToolName;

	static struct ClaudeThinkingBlock
	{
		string type;
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
		@JSONOptional JSONFragment usage;
		@JSONOptional string stop_reason;
		@JSONOptional string stop_sequence;
		@JSONOptional string type;   // always "message", not forwarded
		@JSONOptional string role;   // always "assistant", not forwarded
		@JSONOptional JSONFragment context_management;
		JSONExtras _extras;
	}
	static struct ClaudeAssistant
	{
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isApiErrorMessage;
		@JSONOptional string uuid;
		ClaudeMessage message;
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
	{ tracef("translateAssistantHistory: parse error: %s", e.msg); return []; }

	string[] events;

	foreach (idx, ref b; raw.message.content)
	{
		auto itemId = b.type == "tool_use" && b.id.length > 0
			? b.id : "cc-hist-" ~ to!string(idx);

		ItemStartedEvent startEv;
		startEv.item_id   = itemId;
		startEv.item_type = b.type;
		if (b.type == "tool_use")
		{
			decomposeToolName(b.name, startEv.name, startEv.tool_server, startEv.tool_source);
			startEv.input = b.input;
		}
		else
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			startEv.text = text;
		}
		events ~= injectRawField(toJson(startEv), rawLine);

		ItemCompletedEvent compEv;
		compEv.item_id = itemId;
		if (b.type == "tool_use")
			compEv.input = b.input;
		else
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			compEv.text = text;
		}
		compEv._extras = extrasToFragment(b._extras);
		events ~= injectRawField(toJson(compEv), rawLine);
	}

	// Extract usage.
	UsageInfo usage;
	if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
	{
		@JSONPartial static struct UP { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
		try
		{
			auto u = jsonParse!UP(raw.message.usage.json);
			usage.input_tokens  = u.input_tokens;
			usage.output_tokens = u.output_tokens;
		}
		catch (Exception) {}
	}

	TurnStopEvent tsev;
	tsev.model             = raw.message.model;
	tsev.usage             = usage;
	tsev.parent_tool_use_id = raw.parent_tool_use_id;
	tsev.is_sidechain      = raw.isSidechain;
	tsev.is_api_error      = raw.isApiErrorMessage;
	tsev.uuid              = raw.uuid;
	tsev._extras = extrasToFragment(collectAllExtras(raw));
	events ~= injectRawField(toJson(tsev), rawLine);

	return events;
}

/// Translate a Claude history user message to item/result + item/started events.
private string[] normalizeUserHistory(string rawLine)
{
	import cydo.agent.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent, injectRawField;

	@JSONPartial static struct ClaudeUserMsg { JSONFragment content; }
	@JSONPartial static struct ClaudeUser
	{
		ClaudeUserMsg message;
		@JSONOptional bool isReplay;
		@JSONOptional bool isSynthetic;
		@JSONOptional bool isMeta;
		@JSONOptional bool isSteering;
		@JSONOptional bool pending;
		@JSONOptional string uuid;
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional JSONFragment toolUseResult;
		@JSONOptional JSONFragment tool_use_result;
	}

	ClaudeUser raw;
	try
		raw = jsonParse!ClaudeUser(rawLine);
	catch (Exception e)
	{ tracef("normalizeUserHistory: parse error: %s", e.msg); return []; }

	auto contentJson = raw.message.content.json;
	if (contentJson is null || contentJson.length == 0)
		return [];

	string[] events;

	if (contentJson[0] == '"')
	{
		// String content → user_message item.
		string text;
		try text = jsonParse!string(contentJson);
		catch (Exception) {}

		ContentBlock cb;
		cb.type = "text";
		cb.text = text;

		ItemStartedEvent ev;
		ev.item_id     = "cc-user-msg";
		ev.item_type   = "user_message";
		ev.text        = text;
		ev.content     = [cb];
		ev.is_replay   = raw.isReplay;
		ev.is_synthetic = raw.isSynthetic;
		ev.is_meta     = raw.isMeta;
		ev.is_steering = raw.isSteering;
		ev.pending     = raw.pending;
		ev.uuid        = raw.uuid;
		events ~= injectRawField(toJson(ev), rawLine);
	}
	else if (contentJson[0] == '[')
	{
		@JSONPartial
		static struct ImageSource
		{
			@JSONOptional string data;
			@JSONOptional string media_type;
		}
		@JSONPartial
		static struct ContentItem
		{
			string type;
			@JSONOptional string tool_use_id;
			@JSONOptional JSONFragment content;
			@JSONOptional bool is_error;
			@JSONOptional string text;
			@JSONOptional ImageSource source;
		}
		ContentItem[] items;
		try items = jsonParse!(ContentItem[])(contentJson);
		catch (Exception e) { tracef("normalizeUserHistory: content parse error: %s", e.msg); return events; }

		// Collect user content blocks (text + image); emit tool_results separately.
		ContentBlock[] userBlocks;
		foreach (ref item; items)
		{
			if (item.type == "tool_result")
			{
				ItemResultEvent ev;
				ev.item_id  = item.tool_use_id;
				auto cj2 = item.content.json;
				if (cj2 is null || cj2.length == 0)
					ev.content = JSONFragment(`[{"type":"text","text":""}]`);
				else if (cj2[0] == '"')
					ev.content = JSONFragment(`[{"type":"text","text":` ~ cj2 ~ `}]`);
				else
					ev.content = item.content;
				ev.is_error = item.is_error;
				if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
					ev.tool_result = raw.toolUseResult;
				else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
					ev.tool_result = raw.tool_use_result;
				events ~= injectRawField(toJson(ev), rawLine);
			}
			else if (item.type == "text")
			{
				ContentBlock cb;
				cb.type = "text";
				cb.text = item.text;
				userBlocks ~= cb;
			}
			else if (item.type == "image")
			{
				ContentBlock cb;
				cb.type       = "image";
				cb.data       = item.source.data;
				cb.media_type = item.source.media_type;
				userBlocks ~= cb;
			}
		}

		if (userBlocks.length > 0)
		{
			import cydo.agent.protocol : extractContentText;
			ItemStartedEvent ev;
			ev.item_id     = "cc-user-msg";
			ev.item_type   = "user_message";
			ev.text        = extractContentText(userBlocks);
			ev.content     = userBlocks;
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering = raw.isSteering;
			ev.pending     = raw.pending;
			ev.uuid        = raw.uuid;
			events ~= injectRawField(toJson(ev), rawLine);
		}
	}

	return events;
}

/// Translate a Claude stream-json event to the agent-agnostic protocol.
/// Returns null for events that should be consumed (not forwarded).
private string translateClaudeEvent(string rawLine)
{
	auto translated = translateClaudeEventInner(rawLine);
	if (translated is null || translated is rawLine)
		return translated;
	import cydo.agent.protocol : injectRawField;
	return injectRawField(translated, rawLine);
}

private string translateClaudeEventInner(string rawLine)
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
	{
		tracef("translateEvent: type probe parse error: %s", e.msg);
		import cydo.agent.protocol : makeUnrecognizedEvent;
		return makeUnrecognizedEvent("JSON parse error: " ~ e.msg, rawLine);
	}

	switch (probe.type)
	{
		case "system":
			return translateSystemEvent(rawLine, probe.subtype);
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
			import cydo.agent.protocol : makeUnrecognizedEvent;
			return makeUnrecognizedEvent("unknown event type: " ~ probe.type, rawLine);
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
	{ tracef("translateSystemInit: parse error: %s", e.msg); return replaceTypeRemoveSubtype(rawLine, "session/init"); }

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
	{ tracef("translateResult: parse error: %s", e.msg); return renameType(rawLine, "turn/result"); }

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
	{ tracef("translateTaskStarted: parse error: %s", e.msg); return replaceTypeRemoveSubtype(rawLine, "task/started"); }

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
	{ tracef("translateTaskNotification: parse error: %s", e.msg); return replaceTypeRemoveSubtype(rawLine, "task/notification"); }

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
