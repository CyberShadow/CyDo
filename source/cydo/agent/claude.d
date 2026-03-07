module cydo.agent.claude;

import std.format : format;
import std.path : expandTilde;

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
	}

	@property PathMode[string] sandboxPaths() { return paths; }
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }

	AgentSession createSession(string resumeSessionId, string[] bwrapPrefix)
	{
		return new ClaudeCodeSession(resumeSessionId, bwrapPrefix);
	}
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private void delegate(string line) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	this(string resumeSessionId = null, string[] bwrapPrefix = null)
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
