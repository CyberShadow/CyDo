module cydo.agent.claude;

import std.format : format;

import ae.utils.json : toJson;

import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private void delegate(string line) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;

	this(string resumeSessionId = null)
	{
		string[] args = [
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
			args ~= ["--resume", resumeSessionId];

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
