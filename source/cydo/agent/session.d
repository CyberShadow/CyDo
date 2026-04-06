module cydo.agent.session;

import core.time : Duration;

import cydo.agent.protocol : ContentBlock;

/// Abstract agent session interface.
/// Decouples the transport (WebSocket) from the agent implementation.
interface AgentSession
{
	/// Send a user message to the agent.
	void sendMessage(const(ContentBlock)[] content);

	/// Whether this agent supports image content blocks.
	@property bool supportsImages() const;

	/// Send a protocol-level interrupt (cancel current turn gracefully).
	void interrupt();

	/// Send SIGINT signal to the agent process.
	void sigint();

	/// Stop the agent (SIGTERM).
	void stop();

	/// Close stdin to signal EOF — agent exits gracefully.
	void closeStdin();

	/// Force-kill the agent if it has not exited within `timeout` (SIGTERM, then SIGKILL after 2s).
	void killAfterTimeout(Duration timeout);

	/// Callback: called for each line of output from the agent.
	@property void onOutput(void delegate(string line) dg);

	/// Callback: called for each line of stderr from the agent.
	@property void onStderr(void delegate(string line) dg);

	/// Callback: called when the agent process exits.
	@property void onExit(void delegate(int status) dg);

	/// Whether the session is still alive (process running, pipes open).
	@property bool alive();
}
