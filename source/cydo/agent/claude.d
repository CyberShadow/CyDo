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

		// Resolve the claude binary and add its directory as ro
		addIfNotRw(resolveClaudeBinary(), PathMode.ro);

		// Add the cydo binary's directory so the MCP server can be spawned inside the sandbox
		addIfNotRw(cydoBinaryDir(), PathMode.ro);

		// Enable file-history-snapshot creation in SDK/headless mode.
		// Claude Code's KX9() guard requires this env var for checkpointing.
		env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
	}
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }

	/// The MCP config temp file path from the most recent createSession call.
	/// Exposed for cleanup tracking by the caller.
	string lastMcpConfigPath;

	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
		SessionConfig config = SessionConfig.init)
	{
		lastMcpConfigPath = generateMcpConfig(tid, config.creatableTaskTypes,
			config.switchModes, config.handoffs);
		return new ClaudeCodeSession(resumeSessionId, bwrapPrefix, lastMcpConfigPath, config);
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

		if (!line.canFind(`"type":"assistant"`))
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
			if (probe.type != "assistant")
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
string generateMcpConfig(int tid, string creatableTaskTypes = "",
	string switchModes = "", string handoffs = "")
{
	import std.file : exists, mkdirRecurse, write;
	import std.path : buildPath;

	auto configDir = buildPath(expandTilde("~/.claude"), "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto cydoBin = cydoBinaryPath;
	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	// MCP config pointing to our binary in MCP server mode
	auto config = `{"mcpServers":{"cydo":{"type":"stdio","command":"`
		~ escapeJsonString(cydoBin) ~ `","args":["--mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_PORT":"3456","CYDO_CREATABLE_TYPES":"`
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
