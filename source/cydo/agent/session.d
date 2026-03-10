module cydo.agent.session;

/// Abstract agent session interface.
/// Decouples the transport (WebSocket) from the agent implementation.
interface AgentSession
{
	/// Send a user message to the agent.
	void sendMessage(string content);

	/// Send a protocol-level interrupt (cancel current turn gracefully).
	void interrupt();

	/// Send SIGINT signal to the agent process.
	void sigint();

	/// Stop the agent (SIGTERM).
	void stop();

	/// Close stdin to signal EOF — agent exits gracefully.
	void closeStdin();

	/// Callback: called for each line of output from the agent.
	@property void onOutput(void delegate(string line) dg);

	/// Callback: called for each line of stderr from the agent.
	@property void onStderr(void delegate(string line) dg);

	/// Callback: called when the agent process exits.
	@property void onExit(void delegate(int status) dg);

	/// Whether the session is still alive (process running, pipes open).
	@property bool alive();
}
