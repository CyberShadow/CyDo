module cydo.agent.session;

import core.time : Duration;

import cydo.agent.protocol : ContentBlock, TranslatedEvent;

/// Abstract agent session interface.
/// Decouples the transport (WebSocket) from the agent implementation.
interface AgentSession
{
	/// Send a user message to the agent.
	/// correlationId is the nonce from the originating UI send (may be null).
	void sendMessage(const(ContentBlock)[] content, string correlationId = null);

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

	/// Whether force-stop remains actionable after closeStdin() has been requested.
	/// Used by UI capability rendering during "Ending..." state.
	@property bool canStopAfterCloseStdin() const;

	/// Force-kill the agent if it has not exited within `timeout` (SIGTERM, then SIGKILL after 2s).
	void killAfterTimeout(Duration timeout);

	/// Callback: called when the agent acknowledges a user message before it
	/// enters the LLM context. Argument is the correlationId (nonce) from the
	/// originating send. Only fired by agents with a separable ack signal.
	@property void onAgentAck(void delegate(string nonce) dg);

	/// Callback: called for each translated event from the agent.
	@property void onOutput(void delegate(TranslatedEvent) dg);

	/// Callback: called for each line of stderr from the agent.
	@property void onStderr(void delegate(string line) dg);

	/// Callback: called when the agent process exits.
	@property void onExit(void delegate(int status) dg);

	/// Whether the session is still alive (process running, pipes open).
	@property bool alive();
}
