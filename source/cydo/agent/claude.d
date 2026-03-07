module cydo.agent.claude;

import std.conv : to;
import std.format : format;
import std.path : dirName, expandTilde;

import ae.utils.json : toJson;

import cydo.agent.agent : Agent;
import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

/// Agent descriptor for Claude Code CLI.
class ClaudeCodeAgent : Agent
{
	private PathMode[string] paths;

	this()
	{
		paths = [
			expandTilde("~/.claude"):              PathMode.rw,
			expandTilde("~/.claude.json"):          PathMode.rw,
			expandTilde("~/.cache/claude-status"):  PathMode.rw,
		];

		// Resolve the claude binary and add its directory as ro
		auto claudePath = resolveClaudeBinary();
		if (claudePath.length > 0)
			paths[claudePath] = PathMode.ro;

		// Add the cydo binary's directory so the MCP server can be spawned inside the sandbox
		auto cydoDir = cydoBinaryDir();
		if (cydoDir.length > 0)
			paths[cydoDir] = PathMode.ro;
	}

	@property PathMode[string] sandboxPaths() { return paths; }
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }

	/// The MCP config temp file path from the most recent createSession call.
	/// Exposed for cleanup tracking by the caller.
	string lastMcpConfigPath;

	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix)
	{
		lastMcpConfigPath = generateMcpConfig(tid);
		return new ClaudeCodeSession(resumeSessionId, bwrapPrefix, lastMcpConfigPath);
	}
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private void delegate(string line) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	this(string resumeSessionId = null, string[] bwrapPrefix = null, string mcpConfigPath = null)
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
		];

		if (mcpConfigPath !is null)
			claudeArgs ~= ["--mcp-config", mcpConfigPath];

		if (resumeSessionId !is null)
			claudeArgs ~= ["--resume", resumeSessionId];

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

	void interrupt()
	{
		process.interrupt();
	}

	void stop()
	{
		process.terminate();
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
string generateMcpConfig(int tid)
{
	import std.file : exists, mkdirRecurse, write;
	import std.path : buildPath;

	auto configDir = buildPath(expandTilde("~/.claude"), "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto cydoBin = cydoBinaryPath();
	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	// MCP config pointing to our binary in MCP server mode
	auto config = `{"mcpServers":{"cydo":{"type":"stdio","command":"`
		~ escapeJsonString(cydoBin) ~ `","args":["--mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_PORT":"3456"}}}}`;

	write(configPath, config);
	return configPath;
}

/// Get the absolute path to the currently running cydo binary.
string cydoBinaryPath()
{
	import std.file : thisExePath;
	return thisExePath();
}

/// Get the directory containing the cydo binary.
string cydoBinaryDir()
{
	auto path = cydoBinaryPath();
	return path.length > 0 ? dirName(path) : "";
}

/// Escape a string for embedding in JSON.
string escapeJsonString(string s)
{
	import std.array : replace;
	return s.replace(`\`, `\\`).replace(`"`, `\"`);
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
