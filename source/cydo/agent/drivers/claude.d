module cydo.agent.drivers.claude;

import core.time : Duration, seconds;

import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName, expandTilde;
import std.logger : errorf, tracef, warningf;
import std.math : isNaN;
import std.typecons : Nullable;

import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, reject, resolve;
import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	PersistedHistoryBoundary, PersistedHistoryBoundaryKind, OneShotHandle,
	RewindResult, SessionConfig, SessionMeta;
import cydo.protocol;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	NativeProfileSupportRequirement, ProcessLaunch, ResolvedSandbox;
import cydo.runtime.launch.sandbox : buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	effectiveEnvValue, executableMountPaths, resolveExecutablePath;
import cydo.foundation.text.title : truncateTitle;

/// Agent descriptor for Claude Code CLI.
class ClaudeCodeAgent : Agent
{
	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		foreach (path; executableMountPaths(resolveExecutablePath(executableName(env), env)))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "claude",
					"Claude executable"));

		// Add the cydo binary's directory so the MCP server can be spawned inside the sandbox
		paths.requireReadVisible(cydoBinaryDir(),
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "claude",
				"CyDo binary"));

		if ("PATH" !in env)
		{
			auto hostPath = effectiveEnvValue(env, "PATH", "");
			if (hostPath.length > 0)
				env["PATH"] = hostPath;
		}

		// Enable file-history-snapshot creation in SDK/headless mode.
		// Claude Code's KX9() guard requires this env var for checkpointing.
		env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";

		// Disable Claude Code's MCP tool idle watchdog. The generated cydo server
		// config separately raises its hard wall-clock timeout to the maximum.
		// CyDo task-interop calls can intentionally block while a sub-task works.
		env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] = "0";
	}
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }
	override @property AgentDriver driver() { return AgentDriver.claude; }
	override @property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(
			AgentDriver.claude,
			"CLAUDE_CONFIG_DIR",
			".claude",
			[
				NativeProfileSupportRequirement(".claude.json", PathAccess.rw,
					"Claude state file"),
				NativeProfileSupportRequirement(".local/share/claude", PathAccess.ro,
					"Claude data directory"),
			],
		);
	}
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_CLAUDE_BIN", "claude");
	}

	private ModelSpec[string] modelAliasOverrides;
	private string lastMcpConfigPath_;
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		lastMcpConfigPath_ = generateMcpConfig(tid, launch.nativeHistoryProfile,
			config.creatableTaskTypes,
			config.switchModes, config.handoffs, config.includeTools, config.mcpSocketPath,
			config.permissionPolicy);
		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		return new ClaudeCodeSession(claudeBin, resumeSessionId, launch.cmdPrefix,
			lastMcpConfigPath_, config);
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

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, isDir, SpanMode;
		import std.path : baseName, buildPath;

		enforce(profile.driver == driver,
			"Claude history profile driver does not match Claude");
		auto projectsDir = buildPath(profile.root, "projects");
		if (!exists(projectsDir) || !isDir(projectsDir))
			return [];

		DiscoveredSession[] result;
		foreach (DirEntry projEntry; dirEntries(projectsDir, SpanMode.shallow))
		{
			if (!projEntry.isDir)
				continue;

			try
			{
				foreach (DirEntry fileEntry; dirEntries(projEntry.name, "*.jsonl", SpanMode.shallow))
				{
					auto sessionId = baseName(fileEntry.name, ".jsonl");
					DiscoveredSession ds;
					ds.sessionId = sessionId;
					ds.mtime = fileEntry.timeLastModified.stdTime;
					ds.projectPath = "";
					ds.exactHistoryPath = fileEntry.name;
					result ~= ds;
				}
			}
			catch (Exception e)
			{ tracef("enumerateAllSessions: error scanning %s: %s", projEntry.name, e.msg); }
		}
		return result;
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.stdio : File;
		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
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
		{ tracef("readSessionMeta(%s): error: %s", session.sessionId, e.msg); }
		meta.hasMessages = meta.title.length > 0;
		return meta;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths)
	{
		import std.path : baseName, dirName;

		if (session.exactHistoryPath.length == 0)
			return "";
		auto dirName_ = baseName(dirName(session.exactHistoryPath));
		foreach (known; knownProjectPaths)
		{
			if (mangleProjectPath(known) == dirName_)
				return known;
		}
		return "";
	}

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "haiku";
			case "medium": return "sonnet";
			case "large":  return "opus";
			default:       return modelClass; // open-ended labels pass through
		}
	}

	ModelSpec resolveModelSpec(string modelClass)
	{
		ModelSpec spec;
		if (auto p = modelClass in modelAliasOverrides)
			spec = *p;
		if (spec.model.length == 0)
			spec.model = defaultModelForClass(modelClass);
		return spec;
	}

	unittest
	{
		auto agent = new ClaudeCodeAgent();

		// 14. with no overrides, hardcoded defaults and empty effort
		assert(agent.resolveModelSpec("small") == ModelSpec(ModelSpecFields("haiku")));
		assert(agent.resolveModelSpec("medium") == ModelSpec(ModelSpecFields("sonnet")));
		assert(agent.resolveModelSpec("large") == ModelSpec(ModelSpecFields("opus")));

		// 15. an override replaces the default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
		assert(agent.resolveModelSpec("large").model == "custom-model");

		// 16. an effort-only override keeps the driver's default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
		auto effortOnly = agent.resolveModelSpec("large");
		assert(effortOnly.model == "opus");
		assert(effortOnly.effort == "high");

		// 17. an unknown class passes through, and can still be overridden
		agent.setModelAliases(null);
		auto passthrough = agent.resolveModelSpec("best");
		assert(passthrough.model == "best");
		assert(passthrough.effort == "");
		agent.setModelAliases(["best": ModelSpec(ModelSpecFields("opus", "max"))]);
		auto customClass = agent.resolveModelSpec("best");
		assert(customClass.model == "opus");
		assert(customClass.effort == "max");

		// 18. the empty-class edge stays inert
		agent.setModelAliases(null);
		assert(agent.resolveModelSpec("").model == "");
	}

	string historyPath(string sessionId, string effectiveCwd,
		const ref NativeHistoryProfile profile)
	{
		import std.path : buildPath;
		enforce(profile.driver == driver,
			"Claude history profile driver does not match Claude");
		enforce(sessionId.length > 0,
			"Claude history path requires a session ID");
		enforce(effectiveCwd.length > 0,
			"Claude history path requires an effective CWD");
		return buildPath(profile.root, "projects", mangleProjectPath(effectiveCwd),
			sessionId ~ ".jsonl");
	}

	string createHistoryForkDestination(string sessionId, string effectiveCwd,
		const ref NativeHistoryProfile profile)
	{
		return historyPath(sessionId, effectiveCwd, profile);
	}

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		return translateClaudeHistoryEvent(line);
	}

	void resetHistoryReplay() {} // no state to reset for Claude

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// ClaudeCodeSession handles translation statefully inline.
		// This is an identity pass-through for pre-translated events.
		return [TranslatedEvent(rawLine, null)];
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

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content, int lineOffset = 0)
	{
		import std.algorithm : canFind;
		import std.format : format;
		import std.string : indexOf, lineSplitter;

		PersistedHistoryBoundary[] ids;
		int lineNum = lineOffset;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			if (line.canFind(`"queue-operation"`))
			{
				import ae.utils.json : jsonParse, JSONPartial;
				@JSONPartial static struct QueueOpProbe { string operation; }
				try
				{
					auto qop = jsonParse!QueueOpProbe(line);
					if (qop.operation == "enqueue")
						ids ~= PersistedHistoryBoundary(format!"enqueue-%d"(lineNum), PersistedHistoryBoundaryKind.user, null, lineNum);
				}
				catch (Exception e) { tracef("history scan: queue op parse error: %s", e.msg); }
				continue;
			}
			bool isUser = line.canFind(`"type":"user"`);
			// A mid-turn absorption records its delivery as a queued_command
			// attachment rather than a user line, and that record is the
			// visible message, so it anchors checkpoints like any other one.
			if (!isUser && line.canFind(`"type":"attachment"`)
				&& line.canFind(`"queued_command"`))
				isUser = true;
			if (!isUser && !line.canFind(`"type":"assistant"`))
				continue;
			enum prefix = `"uuid":"`;
			auto idx = line.indexOf(prefix);
			bool hasUuid;
			if (idx >= 0)
			{
				auto start = idx + prefix.length;
				auto end = line.indexOf('"', start);
				if (end >= 0 && end > idx + cast(ptrdiff_t) prefix.length)
				{
					auto uuid = line[start .. end];
					ids ~= PersistedHistoryBoundary(uuid,
						isUser ? PersistedHistoryBoundaryKind.user : PersistedHistoryBoundaryKind.agent_turn,
						null, lineNum);
					hasUuid = true;
				}
			}
			if (!hasUuid)
				ids ~= PersistedHistoryBoundary(format!"line:%d"(lineNum),
					isUser ? PersistedHistoryBoundaryKind.user : PersistedHistoryBoundaryKind.agent_turn,
					null, lineNum);
		}
		return ids;
	}

	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText)
	{
		return repairInterruptedToolCallImpl(lines, toolName, resultText);
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
		if (forkId.startsWith("line:"))
		{
			import std.conv : to;
			return lineNum == forkId["line:".length .. $].to!int;
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
	@property bool supportsDeveloperPrompt() { return true; }

	RewindResult rewindFiles(string sessionId, string afterUuid, string cwd,
		ProcessLaunch launch)
	{
		import std.process : Config, execute;

		enforce(launch.nativeHistoryProfile.driver == driver,
			"Claude rewind launch does not carry a Claude history profile");
		enforce(launch.nativeHistoryProfile.root.length > 0,
			"Claude rewind launch does not carry a history profile root");

		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: resolveExecutablePath(executableName(null), null);
		if (claudeBin.length == 0)
			claudeBin = executableName(null);

		// Pass claudeBin as positional $3 to avoid needing it in env.
		// Use /bin/sh (absolute) so the shell is found even inside bwrap with --clearenv.
		string[] shArgs = [
			"/bin/sh", "-c",
			`exec 2>&1; exec "$3" --resume "$1" --rewind-files "$2" ` ~
				`--settings '{"fileCheckpointingEnabled": true}'`,
			"--", sessionId, afterUuid, claudeBin,
		];

		string[] args;
		string[string] procEnv;
		ResolvedSandbox freshSandbox;
		if (launch.cmdPrefix !is null)
		{
			// Regenerate a fresh command prefix with new temp files,
			// since the original ones were cleaned up after session exit.
			freshSandbox = launch.sandbox;
			args = buildCommandPrefix(freshSandbox, cwd) ~ shArgs;
		}
		else
		{
			args = shArgs;
			procEnv = launch.sandbox.env.dup;
			procEnv["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
		}

		auto result = execute(args, procEnv, Config.none, size_t.max,
			cwd.length > 0 ? cwd : null);

		// Clean up temp files created by buildCommandPrefix above.
		if (freshSandbox.tempFiles.length > 0)
			cleanup(freshSandbox);

		if (result.status != 0)
		{
			auto msg = result.output.length > 0 ? result.output
				: "Process exited with status " ~ format!"%d"(result.status);
			return RewindResult(false, msg);
		}

		import std.algorithm : canFind;
		if (result.output.canFind("Error:"))
			return RewindResult(false, result.output);

		return RewindResult(true, result.output);
	}

	private static string[] buildOneShotArgs(string claudeBin, string prompt,
		string model, string effort, ProcessLaunch launch)
	{
		string[] args = [
			claudeBin,
			"-p", prompt,
			"--output-format", "text",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		];
		// an empty alias means no explicit model; omit the flag so claude
		// uses its own configured default
		if (model.length > 0)
			args ~= ["--model", model];
		// an empty effort means no explicit effort; omit the flag so claude
		// uses its own configured default
		if (effort.length > 0)
			args ~= ["--effort", effort];
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ args;
		return args;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		ProcessLaunch launch; // .init: no cmdPrefix

		// an empty alias omits --model entirely
		assert(!buildOneShotArgs("claude", "hi", "", "", launch).canFind("--model"));

		// a resolved model is passed through as `--model <x>`
		auto withModel = buildOneShotArgs("claude", "hi", "opus", "", launch);
		auto i = withModel.countUntil("--model");
		assert(i >= 0 && withModel[i + 1] == "opus");

		// an empty effort omits --effort entirely
		assert(!buildOneShotArgs("claude", "hi", "opus", "", launch).canFind("--effort"));

		// a resolved effort is passed through as `--effort <x>`
		auto withEffort = buildOneShotArgs("claude", "hi", "opus", "xhigh", launch);
		auto j = withEffort.countUntil("--effort");
		assert(j >= 0 && withEffort[j + 1] == "xhigh");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		import std.path : buildPath;
		import std.process : environment;
		import std.string : strip;
		import ae.utils.promise : Promise;

		auto promise = new Promise!string;
		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);

		string[string] env = [
			"PATH": environment.get("PATH", ""),
			"HOME": environment.get("HOME", ""),
		];

		auto spec = resolveModelSpec(modelClass);
		auto args = buildOneShotArgs(claudeBin, prompt, spec.model, spec.effort, launch);

		auto procEnv = launch.cmdPrefix is null ? env : null;

		AgentProcess proc;
		try
			proc = new AgentProcess(args, procEnv, noStdin: true,
				mode: FramingMode.raw, logName: "claude-oneshot");
		catch (Exception e)
		{
			errorf("completeOneShot: failed to spawn claude: %s", e.msg);
			promise.reject(new Exception("failed to spawn claude: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		string responseText;
		string stderrText;

		proc.onStdoutLine = (string chunk) {
			responseText ~= chunk;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			tracef("claude oneshot exit: status=%d stdout=%d bytes stderr=%d bytes",
				status, responseText.length, stderrText.length);
			if (status != 0)
			{
				auto msg = "claude exited with status " ~ status.to!string;
				auto details = stderrText.strip();
				if (details.length > 0)
					msg ~= ": " ~ details;
				promise.reject(new Exception(msg));
			}
			else
			{
				if (stderrText.length > 0)
					warningf("claude oneshot stderr: %s", stderrText.strip());
				promise.fulfill(responseText.strip());
			}
		};

		void cancel() { proc.killAfterTimeout(0.seconds); }

		return OneShotHandle(promise, &cancel);
	}
}

private bool interruptedToolCallHasKey(ref JSONValue value, string key)
{
	return value.type == JSONType.object && key in value.object;
}

private string interruptedToolCallStringAt(ref JSONValue value, string key)
{
	if (!interruptedToolCallHasKey(value, key))
		return null;
	auto field = value.object[key];
	return field.type == JSONType.string ? field.str : null;
}

/// Repair the Claude JSONL records emitted after CyDo interrupts a successful
/// continuation MCP call. Returns null when the expected call/result pair is
/// not present, leaving the caller's file untouched.
InterruptedToolCallRepair repairInterruptedToolCallImpl(string[] lines, string toolName,
	string resultText)
{
	string toolUseId;
	foreach (line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
			continue;
		if (interruptedToolCallStringAt(record, "type") != "assistant"
			|| !interruptedToolCallHasKey(record, "message"))
			continue;

		auto message = record.object["message"];
		if (!interruptedToolCallHasKey(message, "content")
			|| message.object["content"].type != JSONType.array)
			continue;
		foreach (block_; message.object["content"].array)
		{
			auto block = block_;
			if (interruptedToolCallStringAt(block, "type") == "tool_use"
				&& interruptedToolCallStringAt(block, "name") == toolName)
				toolUseId = interruptedToolCallStringAt(block, "id");
		}
	}
	if (toolUseId.length == 0)
		return null;

	string resultUuid;
	bool rewroteResult;
	string[] rewritten;
	foreach (line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			rewritten ~= line;
			continue;
		}

		if (!rewroteResult && interruptedToolCallStringAt(record, "type") == "user"
			&& interruptedToolCallHasKey(record, "message"))
		{
			auto message = record.object["message"];
			if (interruptedToolCallHasKey(message, "content")
				&& message.object["content"].type == JSONType.array
				&& message.object["content"].array.length > 0)
			{
				auto content = message.object["content"];
				auto block = content.array[0];
				if (interruptedToolCallStringAt(block, "type") == "tool_result"
					&& interruptedToolCallStringAt(block, "tool_use_id") == toolUseId)
				{
					block.object["content"] = JSONValue(resultText);
					block.object.remove("is_error");
					content.array[0] = block;
					message.object["content"] = content;
					record.object["message"] = message;
					record.object["toolUseResult"] = JSONValue(resultText);
					record.object.remove("toolDenialKind");
					resultUuid = interruptedToolCallStringAt(record, "uuid");
					rewritten ~= record.toString();
					rewroteResult = true;
					continue;
				}
			}
		}
		rewritten ~= line;
	}
	if (!rewroteResult || resultUuid.length == 0)
		return null;

	string interruptionUuid;
	string[] withoutInterruption;
	foreach (line; rewritten)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			withoutInterruption ~= line;
			continue;
		}

		if (interruptionUuid.length == 0
			&& interruptedToolCallStringAt(record, "type") == "user"
			&& interruptedToolCallStringAt(record, "parentUuid") == resultUuid
			&& interruptedToolCallHasKey(record, "message"))
		{
			auto message = record.object["message"];
			if (interruptedToolCallHasKey(message, "content")
				&& message.object["content"].type == JSONType.array
				&& message.object["content"].array.length == 1)
			{
				auto block = message.object["content"].array[0];
				auto text = interruptedToolCallStringAt(block, "text");
				if (interruptedToolCallStringAt(block, "type") == "text"
					&& (text == "[Request interrupted by user for tool use]"
						|| text == "[Request interrupted by user]"))
				{
					interruptionUuid = interruptedToolCallStringAt(record, "uuid");
					if (interruptionUuid.length > 0)
						continue;
				}
			}
		}
		withoutInterruption ~= line;
	}
	if (interruptionUuid.length == 0)
		return new InterruptedToolCallRepair(withoutInterruption);

	string[] repaired;
	foreach (line; withoutInterruption)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			repaired ~= line;
			continue;
		}

		bool changed;
		foreach (key; ["leafUuid", "parentUuid"])
			if (interruptedToolCallStringAt(record, key) == interruptionUuid)
			{
				record.object[key] = JSONValue(resultUuid);
				changed = true;
			}
		repaired ~= changed ? record.toString() : line;
	}
	return new InterruptedToolCallRepair(repaired, interruptionUuid);
}

unittest
{
	auto assistant = `{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_switch","name":"mcp__cydo__SwitchMode","input":{"continuation":"plan"}}]}}`;
	auto rejected = `{"type":"user","uuid":"u1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use.","is_error":true,"tool_use_id":"toolu_switch"}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}`;
	auto interruption = `{"type":"user","uuid":"u2","parentUuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto lastPrompt = `{"type":"last-prompt","leafUuid":"u2","sessionId":"session"}`;

	auto repaired = repairInterruptedToolCallImpl(
		[assistant, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(repaired !is null && repaired.lines.length == 3);
	assert(repaired.removedInterruptionUuid == "u2");
	auto result = parseJSON(repaired.lines[1]);
	auto resultBlock = result["message"]["content"][0];
	assert(resultBlock["content"].str == "RESULT");
	assert("is_error" !in resultBlock.object);
	assert(result["toolUseResult"].str == "RESULT");
	assert("toolDenialKind" !in result.object);
	assert(parseJSON(repaired.lines[2])["leafUuid"].str == "u1");

	auto older = repairInterruptedToolCallImpl([
		assistant, rejected,
		`{"type":"user","uuid":"u2","parentUuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
		lastPrompt,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(older !is null && older.lines.length == 3);
	assert(older.removedInterruptionUuid == "u2");
	assert(parseJSON(older.lines[2])["leafUuid"].str == "u1");

	auto noInterruption = repairInterruptedToolCallImpl([assistant, rejected],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(noInterruption !is null && noInterruption.lines.length == 2);
	assert(noInterruption.removedInterruptionUuid.length == 0);
	assert(parseJSON(noInterruption.lines[1])["toolUseResult"].str == "RESULT");

	auto oldAssistant = `{"type":"assistant","uuid":"old-a","message":{"content":[{"type":"tool_use","id":"old-call","name":"mcp__cydo__SwitchMode","input":{}}]}}`;
	auto oldResult = `{"type":"user","uuid":"old-u","message":{"content":[{"type":"tool_result","content":"OLD","tool_use_id":"old-call"}]}}`;
	auto multiple = repairInterruptedToolCallImpl(
		[oldAssistant, oldResult, assistant, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(multiple !is null && multiple.lines[1] == oldResult);

	auto mixedAssistant = `{"type":"assistant","uuid":"mixed-a","message":{"content":[{"type":"tool_use","id":"bash-call","name":"Bash","input":{}},{"type":"tool_use","id":"toolu_switch","name":"mcp__cydo__SwitchMode","input":{}}]}}`;
	auto bashResult = `{"type":"user","uuid":"bash-u","message":{"content":[{"type":"tool_result","content":"BASH","tool_use_id":"bash-call"}]}}`;
	auto unrelated = repairInterruptedToolCallImpl(
		[mixedAssistant, bashResult, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(unrelated !is null && unrelated.lines[1] == bashResult);

	auto handoffAssistant = `{"type":"assistant","uuid":"h-a","message":{"content":[{"type":"tool_use","id":"handoff-call","name":"mcp__cydo__Handoff","input":{}}]}}`;
	auto handoffResult = `{"type":"user","uuid":"h-u","message":{"content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"handoff-call"}]},"toolDenialKind":"user-rejected"}`;
	auto handoff = repairInterruptedToolCallImpl([handoffAssistant, handoffResult],
		"mcp__cydo__Handoff", "HANDOFF RESULT");
	assert(handoff !is null
		&& parseJSON(handoff.lines[1])["toolUseResult"].str == "HANDOFF RESULT");
	assert(handoff.removedInterruptionUuid.length == 0);
	auto malformed = repairInterruptedToolCallImpl([assistant, rejected, "not json"],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(malformed !is null && malformed.removedInterruptionUuid.length == 0);
	assert(repairInterruptedToolCallImpl([assistant, rejected],
		"mcp__cydo__Handoff", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([`{"type":"user"}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([assistant],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-claude-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH"];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}

	auto home = buildPath(root, "home");
	auto profileRoot = buildPath(root, "configured-claude-profile");
	auto executableDir = buildPath(root, "bin");
	auto executable = buildPath(executableDir, "claude");
	mkdirRecurse(home);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["PATH"] = executableDir;

	auto agent = new ClaudeCodeAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_CLAUDE_BIN": executable,
		"PATH": executableDir,
		"CLAUDE_CONFIG_DIR": profileRoot,
	];
	auto executableMounts = executableMountPaths(resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "claude";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Native-history paths belong to the launch phase. configureSandbox only
	// keeps a configured profile selector in the child environment.
	assert(resolved.paths.exact(profileRoot).isNull);
	assert(resolved.paths.exact(buildPath(home, ".claude")).isNull);
	assert(resolved.paths.exact(buildPath(home, ".claude.json")).isNull);
	assert(resolved.paths.exact(buildPath(home, ".local", "share", "claude")).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.claude);
	assert(nativeRule.profileEnvName == "CLAUDE_CONFIG_DIR");
	assert(nativeRule.homeRelativeDefault == ".claude");
	assert(nativeRule.homeSupportRequirements.length == 2);
	assert(nativeRule.homeSupportRequirements[0].homeRelativePath == ".claude.json");
	assert(nativeRule.homeSupportRequirements[0].access == PathAccess.rw);
	assert(nativeRule.homeSupportRequirements[1].homeRelativePath
		== ".local/share/claude");
	assert(nativeRule.homeSupportRequirements[1].access == PathAccess.ro);
	assert(resolved.env["PATH"] == executableDir);
	assert(resolved.env["CLAUDE_CONFIG_DIR"] == profileRoot);
	assert(resolved.env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1");
	assert(resolved.env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] == "0");

	// With no configured PATH, Claude keeps its existing host-PATH defaulting.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_CLAUDE_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(("CLAUDE_CONFIG_DIR" in defaultEnv) is null);
	assert(defaultPaths.exact(buildPath(home, ".claude")).isNull);
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"claude test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	auto cydoParent = dirName(cydoDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	ancestorPaths.require(cydoParent, PathAccess.alwaysRw, origin);
	string[string] ancestorEnv = [
		"CYDO_CLAUDE_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
	assert(ancestorPaths.exact(cydoParent).get.effectiveMode == PathMode.always_rw);
	assert(ancestorPaths.exact(cydoDir).isNull);
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private string nativeSessionId_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private void delegate(TranslatedEvent) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	// Stateful translation: track active content blocks per index.
	private string[] activeItemIds_;   // index → item_id for current turn
	private string[] activeItemTypes_; // index → "text", "thinking", "tool_use"
	private JSONFragment[string] blockExtras_; // item_id → extras from assistant event
	private AbsTime lineReceiptTs_;    // receipt time captured at start of each live line
	private string executablePath_;
	private string agentName_;

	private static string[] buildSessionArgs(string executablePath, string resumeSessionId,
		string[] cmdPrefix, string mcpConfigPath, SessionConfig config)
	{
		string[] claudeArgs = [
			executablePath.length > 0 ? executablePath : "claude",
			"-p",
			"--input-format", "stream-json",
			"--output-format", "stream-json",
			"--verbose",
			"--include-partial-messages",
			"--replay-user-messages",
			// Opt back into thinking content on Opus 4.7 (omitted by default since 4.7).
			"--thinking-display", "summarized",
			"--settings", `{"fileCheckpointingEnabled": true}`,
		];

		// Mutually exclusive: Claude Code ≥2.1.2xx gives
		// --dangerously-skip-permissions precedence over the prompt tool,
		// which would bypass the configured permission policy entirely.
		if (config.permissionPolicy.length > 0)
			claudeArgs ~= ["--permission-prompt-tool", "mcp__cydo__PermissionPrompt"];
		else
			claudeArgs ~= ["--dangerously-skip-permissions"];

		if (mcpConfigPath !is null)
			claudeArgs ~= ["--mcp-config", mcpConfigPath];

		if (resumeSessionId !is null)
			claudeArgs ~= ["--resume", resumeSessionId];

		if (config.model.length > 0)
			claudeArgs ~= ["--model", config.model];

		// Passed through verbatim; `claude` owns the accepted value set.
		if (config.effort.length > 0)
			claudeArgs ~= ["--effort", config.effort];

		if (config.appendSystemPrompt.length > 0)
			claudeArgs ~= ["--append-system-prompt", config.appendSystemPrompt];

		// Monitor interacts poorly with batch execution: the agent may yield its
		// turn (producing a result) after calling Monitor, expecting a ping when
		// the command finishes, but the session is ended instead.
		string taskTools = "TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate";
		string disallowed = config.allowNativeSubagents
			? taskTools ~ ",Monitor,EnterPlanMode,ExitPlanMode,AskUserQuestion"
			: "Task," ~ taskTools ~ ",Monitor,EnterPlanMode,ExitPlanMode,AskUserQuestion";
		claudeArgs ~= ["--disallowedTools", disallowed];

		// When sandboxed, cmdPrefix handles workDir via --chdir (bwrap) or -C (env)
		string[] args;
		if (cmdPrefix !is null)
			args = cmdPrefix ~ claudeArgs;
		else
			args = claudeArgs;

		return args;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		SessionConfig config; // .init: no model, no effort, no cmdPrefix
		auto args = buildSessionArgs("claude", null, null, null, config);
		assert(!args.canFind("--model"));
		assert(!args.canFind("--effort"));

		auto withBoth = config;
		withBoth.model = "opus";
		withBoth.effort = "xhigh";
		auto bothArgs = buildSessionArgs("claude", null, null, null, withBoth);
		auto modelIdx = bothArgs.countUntil("--model");
		assert(modelIdx >= 0 && bothArgs[modelIdx + 1] == "opus");
		auto effortIdx = bothArgs.countUntil("--effort");
		assert(effortIdx >= 0 && bothArgs[effortIdx + 1] == "xhigh");

		// pinning the Step 1 extraction's ordering: cmdPrefix comes first
		auto withPrefix = buildSessionArgs("claude", null, ["prefix"], null, config);
		assert(withPrefix[0] == "prefix");
	}

	this(string executablePath, string resumeSessionId = null, string[] cmdPrefix = null,
		string mcpConfigPath = null, SessionConfig config = SessionConfig.init)
	{
		executablePath_ = executablePath;
		agentName_ = config.agentName;

		auto args = buildSessionArgs(executablePath, resumeSessionId, cmdPrefix,
			mcpConfigPath, config);
		process = new AgentProcess(args, logName: "claude");

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
	/// correlationId is accepted for interface compatibility but not used:
	/// Claude has no separable app-server acknowledgment beyond local enqueue.
	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false)
	{
		try
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
		catch (Exception e)
			return reject!AgentSubmissionReceipt(e);
		return resolve(AgentSubmissionReceipt.localEnqueued);
	}

	void invalidatePendingSubmittedMessages() {}

	@property bool supportsImages() const { return true; }

	/// Send a protocol-level interrupt via stdin (control_request with subtype "interrupt").
	/// This tells Claude Code to cancel the current turn gracefully without killing the process.
	void interrupt()
	{
		import std.uuid : randomUUID;
		ClaudeControlRequest req;
		req.request_id = randomUUID().toString();
		req.request.subtype = "interrupt";
		process.sendMessage(toJson(req));
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

	void killAfterTimeout(Duration timeout)
	{
		process.killAfterTimeout(timeout);
	}

	@property bool canStopAfterCloseStdin() const
	{
		return true;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionId_ !is null && nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(nativeSessionId_);
	}

	private void notifyNativeSessionStarted(string sessionId)
	{
		enforce(sessionId.length > 0,
			"Claude session initialization did not provide a native session ID");
		if (nativeSessionId_ !is null)
		{
			enforce(nativeSessionId_ == sessionId,
				"Claude session reported conflicting native session IDs");
			return;
		}
		nativeSessionId_ = sessionId;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(sessionId);
	}

	@property void onOutput(void delegate(TranslatedEvent) dg)
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

	private void emitEvent(TranslatedEvent ev)
	{
		if (ev.ts == AbsTime.init)
			ev.ts = lineReceiptTs_;
		if (outputHandler && ev.translated.length > 0)
			outputHandler(ev);
	}

	private void translateLiveLine(string rawLine)
	{
		import std.datetime : Clock;
		lineReceiptTs_ = AbsTime(Clock.currStdTime);
		import std.algorithm : canFind;

		// Queue operations must pass through raw so broadcastTask can intercept them.
		if (rawLine.canFind(`"queue-operation"`))
		{
			emitEvent(TranslatedEvent(rawLine, null));
			return;
		}

		@JSONPartial static struct TypeProbe { string type; string subtype; }
		TypeProbe probe;
		try
			probe = jsonParse!TypeProbe(rawLine);
		catch (Exception)
		{
			import cydo.protocol : makeUnrecognizedEvent;
			import ae.utils.json : toJson;
			emitEvent(TranslatedEvent(makeUnrecognizedEvent("non-JSON output"), toJson(rawLine)));
			return;
		}

		if (probe.type == "system" && probe.subtype == "init")
		{
			@JSONPartial static struct InitProbe { @JSONOptional string session_id; }
			string sessionId;
			try
				sessionId = jsonParse!InitProbe(rawLine).session_id;
			catch (Exception e)
			{
				tracef("Claude native session init parse error: %s", e.msg);
				return;
			}
			notifyNativeSessionStarted(sessionId);
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
				auto t = translateClaudeEvent(rawLine, agentName_);
				if (t.translated !is null)
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

					import cydo.protocol : ItemStartedEvent, decomposeToolName;
					ItemStartedEvent ev;
					ev.item_id = itemId;
					ev.item_type = blockType;
					if (blockType == "tool_use")
						decomposeToolName(probe.content_block.name, ev.name, ev.tool_server, ev.tool_source);
					emitEvent(TranslatedEvent(toJson(ev), rawLine));
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

					import cydo.protocol : ItemDeltaEvent;
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
					emitEvent(TranslatedEvent(toJson(ev), null));
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
						import cydo.protocol : ItemCompletedEvent;
						ItemCompletedEvent ev;
						ev.item_id = activeItemIds_[idx];
						if (auto extras = activeItemIds_[idx] in blockExtras_)
							ev.extras = *extras;
						emitEvent(TranslatedEvent(toJson(ev), rawLine));
					}
				}
				catch (Exception e)
				{ tracef("content_block_stop: parse error: %s", e.msg); }
				return;
			}

			case "message_stop":
			{
				import cydo.protocol : TurnStopEvent;
				TurnStopEvent tsev;
				emitEvent(TranslatedEvent(toJson(tsev), rawLine));
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
	/// Exception: sub-agent messages (parent_tool_use_id set) arrive as complete
	/// messages even in the live stream, so they are processed like history.
	private void translateAssistantLive(string rawLine)
	{
		import cydo.protocol : TurnDeltaEvent, UsageInfo;

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
			@JSONOptional string entrypoint;
			@JSONOptional JSONFragment diagnostics;
			JSONExtras _extras;
		}

		ClaudeAssistant raw;
		try
			raw = jsonParse!ClaudeAssistant(rawLine);
		catch (Exception e)
		{ tracef("translateAssistantLive: parse error: %s", e.msg); return; }

		if (raw.isApiErrorMessage && raw.parent_tool_use_id.length == 0)
		{
			string errorText;
			foreach (ref b; raw.message.content)
				if (b.text.length > 0) errorText ~= b.text;
			TaskDiagnosticEvent ev;
			ev.severity = TaskDiagnosticSeverity.error;
			ev.subject = "Agent error";
			ev.body = errorText;
			emitEvent(TranslatedEvent(toJson(ev), rawLine));
			return;
		}

		// Sub-agent messages arrive as complete messages with parent_tool_use_id
		// set even in the live stream.  Emitting a TurnDeltaEvent for them would
		// corrupt the main streaming turn (M_main) by setting its parentToolUseId.
		// Process them like history messages instead (ItemStarted+Completed+TurnStop).
		if (raw.parent_tool_use_id.length > 0)
		{
			import cydo.protocol : ItemStartedEvent, ItemCompletedEvent,
				TurnStopEvent, decomposeToolName;

			foreach (idx, ref b; raw.message.content)
			{
				auto itemId = b.type == "tool_use" && b.id.length > 0
					? b.id : "cc-subagent-" ~ to!string(idx);

				ItemStartedEvent startEv;
				startEv.item_id              = itemId;
				startEv.item_type            = b.type;
				startEv.parent_tool_use_id   = raw.parent_tool_use_id;
				startEv.is_sidechain         = raw.isSidechain;
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
				emitEvent(TranslatedEvent(toJson(startEv), rawLine));

				ItemCompletedEvent compEv;
				compEv.item_id = itemId;
				if (b.type == "tool_use")
					compEv.input = b.input;
				else
				{
					auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
					compEv.text = text;
				}
				compEv.extras = extrasToFragment(b._extras);
				emitEvent(TranslatedEvent(toJson(compEv), rawLine));
			}

			UsageInfo subUsage;
			if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
			{
				@JSONPartial static struct UP2 { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
				try
				{
					auto u = jsonParse!UP2(raw.message.usage.json);
					subUsage.input_tokens  = u.input_tokens;
					subUsage.output_tokens = u.output_tokens;
				}
				catch (Exception) {}
			}

			TurnStopEvent tsev;
			tsev.model              = raw.message.model;
			tsev.usage              = subUsage;
			tsev.parent_tool_use_id = raw.parent_tool_use_id;
			tsev.is_sidechain       = raw.isSidechain;
			tsev.uuid               = raw.uuid;
			tsev.extras = extrasToFragment(collectAllExtras(raw));
			emitEvent(TranslatedEvent(toJson(tsev), rawLine));
			return;
		}

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
		ev.uuid               = raw.uuid;
		ev.extras             = extrasToFragment(raw._extras);
		emitEvent(TranslatedEvent(toJson(ev), rawLine));
	}

	private void normalizeUserLive(string rawLine)
	{
		import cydo.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent;

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
			ev.content   = [cb];
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering        = raw.isSteering;
			ev.pending            = raw.pending;
			ev.uuid               = raw.uuid;
			ev.parent_tool_use_id = raw.parent_tool_use_id;
			ev.is_sidechain       = raw.isSidechain;
			emitEvent(TranslatedEvent(toJson(ev), rawLine));
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
					emitEvent(TranslatedEvent(toJson(ev), rawLine));
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
				ItemStartedEvent ev;
				ev.item_id   = "cc-user-msg";
				ev.item_type = "user_message";
				ev.content   = userBlocks;
				ev.is_replay   = raw.isReplay;
				ev.is_synthetic = raw.isSynthetic;
				ev.is_meta     = raw.isMeta;
				ev.is_steering        = raw.isSteering;
				ev.pending            = raw.pending;
				ev.uuid               = raw.uuid;
				ev.parent_tool_use_id = raw.parent_tool_use_id;
				ev.is_sidechain       = raw.isSidechain;
				emitEvent(TranslatedEvent(toJson(ev), rawLine));
			}
		}
	}
}

unittest
{
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	string[] order;
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };
	session.translateLiveLine(
		`{"type":"system","subtype":"init","session_id":"claude-native-id"}`);
	assert(order.length >= 2
		&& order[0] == "native:claude-native-id"
		&& order[1] == "output",
		"Claude must deliver its native ID before translated session initialization");

	auto lateSession = new ClaudeCodeSession("true");
	scope(exit) lateSession.stop();
	lateSession.translateLiveLine(
		`{"type":"system","subtype":"init","session_id":"claude-late-id"}`);
	string delivered;
	lateSession.onNativeSessionStarted = (string sessionId) { delivered = sessionId; };
	assert(delivered == "claude-late-id");
}

unittest
{
	@JSONPartial static struct DiagnosticProbe
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	auto liveRaw =
		`{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"thinking","thinking":"live reasoning"},{"type":"text","text":"live error"}]}}`;
	TranslatedEvent[] liveEvents;
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	session.onOutput = (TranslatedEvent event) { liveEvents ~= event; };
	session.translateAssistantLive(liveRaw);
	assert(liveEvents.length == 1);
	auto live = jsonParse!DiagnosticProbe(liveEvents[0].translated);
	assert(live.type == "cydo/task_diagnostic");
	assert(live.severity == "error");
	assert(live.subject == "Agent error");
	assert(live.body == "live error");
	assert(liveEvents[0].raw == liveRaw);

	auto historyRaw =
		`{"type":"assistant","isApiErrorMessage":true,"message":{"id":"history-error","content":[{"type":"thinking","thinking":"history reasoning"},{"type":"text","text":"history error"}]}}`;
	auto historyEvents = translateAssistantHistory(historyRaw);
	assert(historyEvents.length == 1);
	auto history = jsonParse!DiagnosticProbe(historyEvents[0].translated);
	assert(history.type == "cydo/task_diagnostic");
	assert(history.severity == "error");
	assert(history.subject == "Agent error");
	assert(history.body == "history reasoninghistory error");
	assert(historyEvents[0].raw == historyRaw);
}

unittest
{
	import ae.net.asockets : socketManager;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	void assertRejected(Promise!AgentSubmissionReceipt submission,
		string expectedMessage)
	{
		bool fulfilled;
		string rejectionMessage;
		submission.then((AgentSubmissionReceipt receipt) {
			fulfilled = true;
		}, (Exception error) {
			rejectionMessage = error.msg;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!fulfilled && rejectionMessage == expectedMessage);
	}

	// A live local stdin enqueue is Claude's only submission receipt; it must
	// not wait for an app-server response that Claude does not provide.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();

		bool fulfilled;
		session.sendMessage([ContentBlock("text", "local enqueue")],
			"ignored-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.localEnqueued);
			fulfilled = true;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(fulfilled);
	}

	// A disconnected local transport rejects through the returned promise.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();
		session.process.forceClosePipes();

		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage([ContentBlock("text", "dead")]);
		catch (Exception error)
			assert(false, "sendMessage threw instead of returning a rejection: "
				~ error.msg);
		assertRejected(submission, "Agent process is no longer running");
	}

	// Content conversion failures likewise belong to the promise contract,
	// rather than escaping synchronously before a caller can attach rejection
	// handling.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();

		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage([
				ContentBlock("unsupported", "cannot serialize"),
			]);
		catch (Exception error)
			assert(false, "sendMessage threw instead of returning a rejection: "
				~ error.msg);
		assertRejected(submission,
			"Unsupported content block type for Claude: unsupported");
	}
}

private:

struct ClaudeControlRequest
{
	string type = "control_request";
	string request_id;
	struct Req { string subtype; }
	Req request;
}

struct ClaudeTextBlock { string type = "text"; string text; }
struct ClaudeImageSource { string type = "base64"; string data; string media_type; }
struct ClaudeImageBlock { string type = "image"; ClaudeImageSource source; }

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

/// Mangle a project path the same way Claude CLI does: replace every
/// non-alphanumeric character with '-'.
private string mangleProjectPath(string path)
{
	auto buf = path.dup;
	foreach (ref c; buf)
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
			c = '-';
	return buf.idup;
}

private struct McpConfigEnv
{
	string CYDO_TID;
	string CYDO_SOCKET;
	string CYDO_CREATABLE_TYPES;
	string CYDO_SWITCHMODES;
	string CYDO_HANDOFFS;
	string CYDO_INCLUDE_TOOLS;
	string CYDO_PERMISSION_POLICY;
}

private struct McpConfigServer
{
	string type = "stdio";
	string command;
	string[] args;
	McpConfigEnv env;
	// Claude Code ≥2.1.2xx defers MCP tools behind ToolSearch by default.
	// cydo's tools are the session's core workflow verbs (Task, SwitchMode,
	// Ask, …); they must stay in the model's tool list unconditionally.
	bool alwaysLoad = true;
	int timeout = 2_147_483_647;
}

private struct McpConfigServers { McpConfigServer cydo; }
private struct McpConfig { McpConfigServers mcpServers; }

/// Generate a temporary MCP config file pointing to the cydo binary.
/// creatableTaskTypes is pre-formatted text describing available task types.
/// switchModes is pre-formatted text describing available SwitchMode continuations.
/// handoffs is pre-formatted text describing available Handoff continuations.
/// mcpSocketPath is the absolute path to the backend's UNIX socket for MCP calls.
string generateMcpConfig(int tid, const ref NativeHistoryProfile profile,
	string creatableTaskTypes = "",
	string switchModes = "", string handoffs = "", string[] includeTools = null,
	string mcpSocketPath = "", string permissionPolicy = "")
{
	import std.array : join;
	import std.exception : enforce;
	import std.file : exists, mkdirRecurse, write;
	import std.path : buildPath;

	enforce(profile.driver == AgentDriver.claude,
		"Claude MCP config requires a Claude native history profile");
	auto configDir = buildPath(profile.root, "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto cydoBin = cydoBinaryPath;
	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	import ae.utils.array : nonNull;

	// MCP config pointing to our binary in MCP server mode.
	// CYDO_SOCKET tells the proxy to connect via UNIX socket (no auth needed).
	auto cfg = McpConfig(McpConfigServers(McpConfigServer(
		"stdio",
		cydoBin,
		["mcp-server"],
		McpConfigEnv(
			to!string(tid),
			mcpSocketPath.nonNull,
			creatableTaskTypes.nonNull,
			switchModes.nonNull,
			handoffs.nonNull,
			includeTools is null ? "" : includeTools.join(","),
			permissionPolicy.nonNull,
		),
	)));
	write(configPath, toJson(cfg));
	return configPath;
}

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-claude-mcp-native-profile");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto profile = NativeHistoryProfile(AgentDriver.claude,
		buildPath(root, "supplied-profile"));
	auto configPath = generateMcpConfig(42, profile);
	assert(configPath == buildPath(profile.root, "mcp-configs", "cydo-42.json"));
	assert(exists(configPath));
	auto wrongDriverProfile = NativeHistoryProfile(AgentDriver.codex,
		buildPath(root, "wrong-driver"));
	assertThrown!Exception(generateMcpConfig(42, wrongDriverProfile));
}

/// Build a Claude-wire-format content array from agnostic ContentBlock[].
/// Returns a JSONFragment suitable for embedding in ClaudeInputMessage.content.
private JSONFragment buildClaudeContentBlocks(const(ContentBlock)[] blocks)
{
	import cydo.protocol : ContentBlock;

	string json = "[";
	foreach (i, ref b; blocks)
	{
		if (i > 0) json ~= ",";
		if (b.type == "text")
		{
			ClaudeTextBlock tb;
			tb.text = b.text;
			json ~= toJson(tb);
		}
		else if (b.type == "image")
		{
			ClaudeImageBlock ib;
			ib.source.data = b.data;
			ib.source.media_type = b.media_type;
			json ~= toJson(ib);
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
/// Returns zero or more agnostic event pairs.
private TranslatedEvent[] translateClaudeHistoryEvent(string rawLine)
{
	import cydo.protocol : parseIso8601Timestamp;

	@JSONPartial static struct TypeProbe { string type; string subtype; }
	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception e)
	{
		import cydo.protocol : makeUnrecognizedEvent;
		tracef("translateClaudeHistoryEvent: type probe parse error: %s", e.msg);
		return [TranslatedEvent(makeUnrecognizedEvent("history parse error: " ~ e.msg), rawLine)];
	}

	// Probe timestamp from the JSONL line (present on history lines).
	@JSONPartial static struct TimestampProbe { @JSONOptional string timestamp; }
	AbsTime ts;
	try { ts = parseIso8601Timestamp(jsonParse!TimestampProbe(rawLine).timestamp); }
	catch (Exception) {}

	TranslatedEvent[] result;
	switch (probe.type)
	{
		case "assistant":
			result = translateAssistantHistory(rawLine);
			break;
		case "user":
			result = normalizeUserHistory(rawLine);
			break;
		case "attachment":
			result = translateQueuedCommandAttachment(rawLine);
			break;
		case "stream_event":
			return []; // not stored in JSONL history
		default:
			auto t = translateClaudeEvent(rawLine, "");
			result = t.translated !is null ? [t] : [];
			break;
	}
	foreach (ref ev; result)
		if (ev.ts == AbsTime.init)
			ev.ts = ts;
	return result;
}

unittest
{
	@JSONPartial static struct EventTypeProbe
	{
		string type;
	}

	auto translated = translateClaudeHistoryEvent("null");
	assert(translated.length == 1);
	assert(translated[0].translated != "null");
	assert(translated[0].translated.length > 0);
	assert(translated[0].raw == "null");

	auto ev = jsonParse!EventTypeProbe(translated[0].translated);
	assert(ev.type == "agent/unrecognized");
}

/// Translate a Claude history assistant message to item/started+completed per block + turn/stop.
private TranslatedEvent[] translateAssistantHistory(string rawLine)
{
	import cydo.protocol : ItemStartedEvent, ItemCompletedEvent, TurnStopEvent,
		UsageInfo, decomposeToolName;

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
		@JSONOptional JSONFragment stop_details;
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
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeAssistant raw;
	try
		raw = jsonParse!ClaudeAssistant(rawLine);
	catch (Exception e)
	{ tracef("translateAssistantHistory: parse error: %s", e.msg); return []; }

	if (raw.isApiErrorMessage)
	{
		string errorText;
		foreach (ref b; raw.message.content)
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			if (text.length > 0) errorText ~= text;
		}
		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.error;
		ev.subject = "Agent error";
		ev.body = errorText;
		return [TranslatedEvent(toJson(ev), rawLine)];
	}

	TranslatedEvent[] events;

	foreach (idx, ref b; raw.message.content)
	{
		auto itemId = b.type == "tool_use" && b.id.length > 0
			? b.id : "cc-hist-" ~ to!string(idx);

		ItemStartedEvent startEv;
		startEv.item_id              = itemId;
		startEv.item_type            = b.type;
		startEv.parent_tool_use_id   = raw.parent_tool_use_id;
		startEv.is_sidechain         = raw.isSidechain;
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
		events ~= TranslatedEvent(toJson(startEv), rawLine);

		ItemCompletedEvent compEv;
		compEv.item_id = itemId;
		if (b.type == "tool_use")
			compEv.input = b.input;
		else
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			compEv.text = text;
		}
		compEv.extras = extrasToFragment(b._extras);
		events ~= TranslatedEvent(toJson(compEv), rawLine);
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
	tsev.uuid              = raw.uuid;
	tsev.extras = extrasToFragment(collectAllExtras(raw));
	events ~= TranslatedEvent(toJson(tsev), rawLine);

	return events;
}

/// Translate a Claude history user message to item/result + item/started events.
private TranslatedEvent[] normalizeUserHistory(string rawLine)
{
	import cydo.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent;

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

	TranslatedEvent[] events;

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
		ev.content     = [cb];
		ev.is_replay   = raw.isReplay;
		ev.is_synthetic = raw.isSynthetic;
		ev.is_meta     = raw.isMeta;
		ev.is_steering        = raw.isSteering;
		ev.pending            = raw.pending;
		ev.uuid               = raw.uuid;
		ev.parent_tool_use_id = raw.parent_tool_use_id;
		ev.is_sidechain       = raw.isSidechain;
		events ~= TranslatedEvent(toJson(ev), rawLine);
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
				events ~= TranslatedEvent(toJson(ev), rawLine);
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
			ItemStartedEvent ev;
			ev.item_id     = "cc-user-msg";
			ev.item_type   = "user_message";
			ev.content     = userBlocks;
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering        = raw.isSteering;
			ev.pending            = raw.pending;
			ev.uuid               = raw.uuid;
			ev.parent_tool_use_id = raw.parent_tool_use_id;
			ev.is_sidechain       = raw.isSidechain;
			events ~= TranslatedEvent(toJson(ev), rawLine);
		}
	}

	return events;
}

/// Translate a queued_command attachment record to a user message.
///
/// Recent Claude CLIs absorb queued messages into the running turn at a tool
/// boundary instead of holding them for the next turn: it removes each entry
/// from the queue and records the delivery as an attachment rather than as a
/// user line, so this record is the only canonical fact for a message the
/// model demonstrably received. Its uuid is the one the CLI replays on stdout
/// for the same delivery, so live and replayed histories agree on identity.
///
/// Older versions dequeued the whole queue at the turn boundary and wrote one
/// joined user line; those histories carry no attachment records and are
/// unaffected.
private TranslatedEvent[] translateQueuedCommandAttachment(string rawLine)
{
	import cydo.protocol : ContentBlock, ItemStartedEvent;

	@JSONPartial static struct Attachment
	{
		string type;
		@JSONOptional JSONFragment prompt;
		@JSONOptional string commandMode;
	}
	@JSONPartial static struct Record
	{
		Attachment attachment;
		@JSONOptional string uuid;
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
	}

	Record raw;
	try
		raw = jsonParse!Record(rawLine);
	catch (Exception e)
	{ tracef("translateQueuedCommandAttachment: parse error: %s", e.msg); return []; }

	if (raw.attachment.type != "queued_command")
		return [];

	auto promptJson = raw.attachment.prompt.json;
	if (promptJson is null || promptJson.length == 0)
		return [];

	ContentBlock[] blocks;
	if (promptJson[0] == '"')
	{
		string text;
		try text = jsonParse!string(promptJson);
		catch (Exception) { return []; }
		ContentBlock cb;
		cb.type = "text";
		cb.text = text;
		blocks ~= cb;
	}
	else if (promptJson[0] == '[')
	{
		@JSONPartial static struct ImageSource
		{
			@JSONOptional string data;
			@JSONOptional string media_type;
		}
		@JSONPartial static struct PromptBlock
		{
			string type;
			@JSONOptional string text;
			@JSONOptional ImageSource source;
		}
		PromptBlock[] items;
		try items = jsonParse!(PromptBlock[])(promptJson);
		catch (Exception e)
		{ tracef("translateQueuedCommandAttachment: prompt parse error: %s", e.msg); return []; }
		foreach (ref item; items)
		{
			ContentBlock cb;
			if (item.type == "text")
			{
				cb.type = "text";
				cb.text = item.text;
			}
			else if (item.type == "image")
			{
				cb.type       = "image";
				cb.data       = item.source.data;
				cb.media_type = item.source.media_type;
			}
			else
				continue;
			blocks ~= cb;
		}
	}
	if (blocks.length == 0)
		return [];

	ItemStartedEvent ev;
	ev.item_id     = "cc-queued-command";
	ev.item_type   = "user_message";
	ev.content     = blocks;
	ev.uuid        = raw.uuid;
	ev.parent_tool_use_id = raw.parent_tool_use_id;
	ev.is_sidechain       = raw.isSidechain;
	return [TranslatedEvent(toJson(ev), rawLine)];
}

/// Prompt text carried by a queued_command attachment record, or null when the
/// line is not one. Used to pair a delivery with the queue entry it consumed.
package(cydo) string queuedCommandAttachmentPrompt(string rawLine)
{
	import std.algorithm : canFind;

	if (!rawLine.canFind(`"queued_command"`))
		return null;
	auto events = translateQueuedCommandAttachment(rawLine);
	if (events.length == 0)
		return null;

	@JSONPartial static struct ContentBlockProbe
	{
		@JSONOptional string type;
		@JSONOptional string text;
	}
	@JSONPartial static struct Probe
	{
		@JSONOptional ContentBlockProbe[] content;
		@JSONOptional string uuid;
	}
	Probe probe;
	try
		probe = jsonParse!Probe(events[0].translated);
	catch (Exception)
		return null;
	foreach (ref block; probe.content)
		if (block.type == "text")
			return block.text;
	return null;
}

/// Uuid of a queued_command attachment record, or null when the line is not
/// one. This is the identity the delivered message carries.
package(cydo) string queuedCommandAttachmentUuid(string rawLine)
{
	import std.algorithm : canFind;

	if (!rawLine.canFind(`"queued_command"`))
		return null;
	@JSONPartial static struct Probe
	{
		@JSONOptional string type;
		@JSONOptional string uuid;
	}
	Probe probe;
	try
		probe = jsonParse!Probe(rawLine);
	catch (Exception)
		return null;
	return probe.type == "attachment" ? probe.uuid : null;
}

/// Translate a Claude stream-json event to the agent-agnostic protocol.
/// Returns TranslatedEvent.init for events that should be consumed (not forwarded).
private TranslatedEvent translateClaudeEvent(string rawLine, string agentName)
{
	auto translated = translateClaudeEventInner(rawLine, agentName);
	if (translated is null)
		return TranslatedEvent.init;
	return TranslatedEvent(translated, rawLine);
}

private string translateClaudeEventInner(string rawLine, string agentName)
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
		import cydo.protocol : makeUnrecognizedEvent;
		return makeUnrecognizedEvent("JSON parse error: " ~ e.msg);
	}

	switch (probe.type)
	{
		case "system":
			return translateSystemEvent(rawLine, probe.subtype, agentName);
		case "result":
			return normalizeTurnResult(rawLine);
		case "summary":
			return translateSummary(rawLine);
		case "rate_limit_event":
			return translateRateLimitEvent(rawLine);
		case "control_response":
			return translateControlResponse(rawLine);
		case "stderr":
			return translateStderr(rawLine);
		case "exit":
			return translateExit(rawLine);
		case "queue-operation":
			return null; // consumed — handled by broadcastTask / stateful replay closure
		case "progress":
		case "file-history-snapshot":
			return null; // not used by frontend
		default:
			import cydo.protocol : makeUnrecognizedEvent;
			return makeUnrecognizedEvent("unknown event type: " ~ probe.type);
	}
}

/// Translate system events by mapping subtype to the agnostic type string.
private string translateSystemEvent(string rawLine, string subtype, string agentName)
{
	switch (subtype)
	{
		case "init":
			return translateSessionInit(rawLine, agentName);
		case "status":
			return translateSystemStatus(rawLine);
		case "compact_boundary":
			return translateCompactBoundary(rawLine);
		case "task_started":
			return normalizeTaskStarted(rawLine);
		case "task_notification":
			return normalizeTaskNotification(rawLine);
		case "api_retry":
			return translateApiRetry(rawLine);
		default:
			return rawLine; // unknown subtypes pass through
	}
}

/// Normalize a Claude session/init event to the agnostic SessionInitEvent format.
/// Renames fields and drops Claude-specific fields.
private string translateSessionInit(string rawLine, string agentName)
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
		@JSONOptional JSONFragment[] mcp_servers;
		@JSONOptional JSONFragment[] agents;
		@JSONOptional JSONFragment[] plugins;
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
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeInit raw;
	try
		raw = jsonParse!ClaudeInit(rawLine);
	catch (Exception e)
	{ tracef("translateSystemInit: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("session/init parse error: " ~ e.msg); }

	SessionInitEvent ev;
	ev.session_id    = raw.session_id;
	ev.model         = raw.model;
	ev.cwd           = raw.cwd;
	ev.tools         = raw.tools;
	ev.agent_version = raw.claude_code_version;
	ev.permission_mode = raw.permissionMode;
	ev.agent         = raw.agent.length > 0 ? raw.agent : "claude";
	ev.agent_name    = agentName;
	ev.api_key_source  = raw.apiKeySource;
	ev.fast_mode_state = raw.fast_mode_state;
	ev.skills        = raw.skills;
	ev.mcp_servers   = raw.mcp_servers;
	ev.agents        = raw.agents;
	ev.plugins       = raw.plugins;
	ev.supports_file_revert = true;
	ev.extras = extrasToFragment(collectAllExtras(raw));
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
		// Known Claude usage fields — listed so they are not captured as extras.
		@JSONOptional int cache_creation_input_tokens;
		@JSONOptional int cache_read_input_tokens;
		@JSONOptional JSONFragment server_tool_use;
		@JSONOptional string service_tier;
		@JSONOptional JSONFragment cache_creation;
		@JSONOptional string inference_geo;
		@JSONOptional JSONFragment iterations;
		@JSONOptional string speed;
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
		@JSONOptional ModelUsageInfo[string] modelUsage;
		@JSONOptional ModelUsageInfo[string] model_usage;
		@JSONOptional JSONFragment[] permission_denials;
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
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeResult raw;
	try
		raw = jsonParse!ClaudeResult(rawLine);
	catch (Exception e)
	{ tracef("translateResult: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("turn/result parse error: " ~ e.msg); }

	TurnResultEvent ev;
	ev.subtype            = raw.subtype;
	ev.is_error           = raw.is_error;
	ev.result             = raw.result;
	ev.num_turns          = raw.num_turns;
	ev.duration_ms        = raw.duration_ms;
	ev.duration_api_ms    = raw.duration_api_ms;
	ev.total_cost_usd     = raw.total_cost_usd;
	ev.usage              = UsageInfo(raw.usage.input_tokens, raw.usage.output_tokens);
	if (raw.modelUsage.length > 0)
		ev.model_usage = raw.modelUsage;
	else if (raw.model_usage.length > 0)
		ev.model_usage = raw.model_usage;
	ev.permission_denials = raw.permission_denials;
	ev.stop_reason        = raw.stop_reason;
	ev.errors             = raw.errors;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Translate "summary" event to session/summary.
private string translateSummary(string rawLine)
{
	@JSONPartial static struct RawSummary { string summary; }
	try
	{
		auto raw = jsonParse!RawSummary(rawLine);
		SessionSummaryEvent ev;
		ev.summary = raw.summary;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateSummary: parse error: %s", e.msg); return makeUnrecognizedEvent("summary parse error: " ~ e.msg); }
}

/// Translate "rate_limit_event" event to session/rate_limit.
private string translateRateLimitEvent(string rawLine)
{
	static struct ClaudeRawRateLimitInfo
	{
		@JSONOptional string status;
		@JSONOptional string rateLimitType;
		@JSONOptional double resetsAt;
		@JSONOptional double utilization;
		@JSONOptional string overageStatus;
		@JSONOptional double overageResetsAt;
		@JSONOptional string overageDisabledReason;
		@JSONOptional bool isUsingOverage;
		@JSONOptional double surpassedThreshold;
		JSONExtras _extras;
	}
	@JSONPartial static struct RawRateLimit { ClaudeRawRateLimitInfo rate_limit_info; }
	try
	{
		auto raw = jsonParse!RawRateLimit(rawLine);
		RateLimitInfo info;
		info.status = raw.rate_limit_info.status;
		info.rateLimitType = raw.rate_limit_info.rateLimitType;
		info.resetsAt = raw.rate_limit_info.resetsAt;
		info.utilization = raw.rate_limit_info.utilization;
		info.overageStatus = raw.rate_limit_info.overageStatus;
		info.overageResetsAt = raw.rate_limit_info.overageResetsAt;
		info.overageDisabledReason = raw.rate_limit_info.overageDisabledReason;
		info.isUsingOverage = raw.rate_limit_info.isUsingOverage;
		info.surpassedThreshold = raw.rate_limit_info.surpassedThreshold;
		info.extras = raw.rate_limit_info._extras;
		SessionRateLimitEvent ev;
		ev.rate_limit_info = info;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateRateLimitEvent: parse error: %s", e.msg); return makeUnrecognizedEvent("rate_limit_event parse error: " ~ e.msg); }
}

unittest
{
	@JSONPartial static struct RateLimitProbe
	{
		string type;
		RateLimitInfo rate_limit_info;
	}

	auto translated = translateRateLimitEvent(
		`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","resetsAt":1715702400,"utilization":0.42,"overageStatus":"allowed","overageResetsAt":1715800000,"overageDisabledReason":"unknown","isUsingOverage":false,"surpassedThreshold":0.25},"uuid":"123e4567-e89b-42d3-a456-426614174000","session_id":"123e4567-e89b-42d3-a456-426614174001"}`);
	auto ev = jsonParse!RateLimitProbe(translated);
	assert(ev.type == "session/rate_limit");
	assert(ev.rate_limit_info.status == "allowed_warning");
	assert(ev.rate_limit_info.rateLimitType == "five_hour");
	assert(ev.rate_limit_info.resetsAt == 1715702400);
	assert(ev.rate_limit_info.utilization == 0.42);
	assert(ev.rate_limit_info.overageStatus == "allowed");
	assert(ev.rate_limit_info.overageResetsAt == 1715800000);
	assert(ev.rate_limit_info.overageDisabledReason == "unknown");
	assert(ev.rate_limit_info.isUsingOverage == false);
	assert(ev.rate_limit_info.surpassedThreshold == 0.25);
}

/// Translate "control_response" event to control/response.
private string translateControlResponse(string rawLine)
{
	import cydo.protocol : ControlResponse;
	@JSONPartial static struct RawControlResponse { ControlResponse response; }
	try
	{
		auto raw = jsonParse!RawControlResponse(rawLine);
		ControlResponseEvent ev;
		ev.response = raw.response;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateControlResponse: parse error: %s", e.msg); return makeUnrecognizedEvent("control_response parse error: " ~ e.msg); }
}

/// Translate "stderr" event to process/stderr.
private string translateStderr(string rawLine)
{
	@JSONPartial static struct RawStderr { string text; }
	try
	{
		auto raw = jsonParse!RawStderr(rawLine);
		ProcessStderrEvent ev;
		ev.text = raw.text;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateStderr: parse error: %s", e.msg); return makeUnrecognizedEvent("stderr parse error: " ~ e.msg); }
}

/// Translate "exit" event to process/exit.
private string translateExit(string rawLine)
{
	@JSONPartial static struct RawExit { int code; @JSONOptional bool is_continuation; }
	try
	{
		auto raw = jsonParse!RawExit(rawLine);
		ProcessExitEvent ev;
		ev.code = raw.code;
		ev.is_continuation = raw.is_continuation;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateExit: parse error: %s", e.msg); return makeUnrecognizedEvent("exit parse error: " ~ e.msg); }
}

/// Translate "system/status" event to session/status.
private string translateSystemStatus(string rawLine)
{
	static struct RawStatus
	{
		@JSONOptional string status;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}
	try
	{
		auto raw = jsonParse!RawStatus(rawLine);
		SessionStatusEvent ev;
		ev.status = raw.status;
		ev.permission_mode = raw.permissionMode;
		ev.extras = extrasToFragment(raw._extras);
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateSystemStatus: parse error: %s", e.msg); return makeUnrecognizedEvent("system/status parse error: " ~ e.msg); }
}

unittest
{
	import std.algorithm : canFind;

	@JSONPartial static struct StatusProbe
	{
		string type;
		@JSONOptional string status;
		@JSONOptional string permission_mode;
		@JSONOptional JSONFragment extras;
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":"compacting","permissionMode":"acceptEdits","foo":"bar"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status == "compacting");
		assert(ev.permission_mode == "acceptEdits");
		assert(ev.extras.json !is null);
		assert(ev.extras.json.canFind(`"foo":"bar"`));
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status.length == 0);
		assert(ev.permission_mode == "acceptEdits");
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":"future-status"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status == "future-status");
	}
}

/// Translate "system/api_retry" event to a retrying task diagnostic.
private string translateApiRetry(string rawLine)
{
	@JSONPartial static struct RawApiRetry
	{
		int attempt;
		int max_retries;
		@JSONOptional Nullable!int error_status;
		string error;
	}
	try
	{
		import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;
		auto raw = jsonParse!RawApiRetry(rawLine);
		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.warning;
		ev.subject = "Agent error (retrying)";
		if (raw.error_status.isNull)
			ev.body = format("API error: %s (attempt %d/%d)",
				raw.error, raw.attempt, raw.max_retries);
		else
			ev.body = format("API error: %d %s (attempt %d/%d)",
				raw.error_status.get, raw.error, raw.attempt, raw.max_retries);
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateApiRetry: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("api_retry parse error: " ~ e.msg); }
}

unittest
{
	import std.algorithm : canFind;

	@JSONPartial static struct ErrorProbe
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	auto translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":8,"max_retries":10,"retry_delay_ms":39354.3,"error_status":529,"error":"rate_limit","session_id":"abc","uuid":"def"}`,
		"claude");
	auto ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: 529 rate_limit (attempt 8/10)");
	assert(!translated.canFind(`"willRetry"`));

	translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":538.56,"error_status":null,"error":"unknown","session_id":"abc","uuid":"def"}`,
		"claude");
	ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: unknown (attempt 1/10)");
	assert(!translated.canFind(`"willRetry"`));

	translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":2,"max_retries":3,"retry_delay_ms":1000,"error":"timeout","session_id":"abc","uuid":"def"}`,
		"claude");
	ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: timeout (attempt 2/3)");
	assert(!translated.canFind(`"willRetry"`));
}

/// Translate "system/compact_boundary" event to session/compacted.
private string translateCompactBoundary(string rawLine)
{
	@JSONPartial static struct RawCompact { @JSONOptional CompactMetadata compact_metadata; }
	try
	{
		auto raw = jsonParse!RawCompact(rawLine);
		SessionCompactedEvent ev;
		ev.compact_metadata = raw.compact_metadata;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateCompactBoundary: parse error: %s", e.msg); return makeUnrecognizedEvent("system/compact_boundary parse error: " ~ e.msg); }
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
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeTaskStarted raw;
	try
		raw = jsonParse!ClaudeTaskStarted(rawLine);
	catch (Exception e)
	{ tracef("translateTaskStarted: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("task/started parse error: " ~ e.msg); }

	TaskStartedEvent ev;
	ev.task_id      = raw.task_id;
	ev.tool_use_id  = raw.tool_use_id;
	ev.description  = raw.description;
	ev.task_type    = raw.task_type;
	ev.extras = extrasToFragment(collectAllExtras(raw));
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
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeTaskNotification raw;
	try
		raw = jsonParse!ClaudeTaskNotification(rawLine);
	catch (Exception e)
	{ tracef("translateTaskNotification: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("task/notification parse error: " ~ e.msg); }

	TaskNotificationEvent ev;
	ev.task_id     = raw.task_id;
	ev.status      = raw.status;
	ev.output_file = raw.output_file;
	ev.summary     = raw.summary;
	ev.extras = extrasToFragment(collectAllExtras(raw));
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
