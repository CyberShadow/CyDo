module cydo.agent.session;

import core.time : Duration;

import ae.utils.promise : Promise;

import cydo.protocol : ContentBlock, TranslatedEvent;

/// The earliest submission boundary a concrete agent driver can prove.
enum AgentSubmissionReceipt
{
	/// Claude serialized the input and queued it to a live local stdin connection.
	localEnqueued,
	/// Codex or Copilot received a non-error response to the matching submission RPC.
	appServerAccepted,
}

/// Abstract agent session interface.
/// Decouples the transport (WebSocket) from the agent implementation.
interface AgentSession
{
	/// Send a user message to the agent.
	///
	/// Fulfills at the driver's earliest definitive submission boundary:
	/// Claude after input serialization and enqueue to a live local stdin
	/// connection; Codex after the matching non-error turn/start or turn/steer
	/// response; Copilot after the matching non-error session.send response.
	/// This does not promise a flush, model-context entry, user echo, or turn
	/// completion. Rejects when the session lifecycle is lost before that boundary.
	/// correlationId is the nonce from the originating UI send (may be null).
	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false, string nativeSubmissionUuid = null);

	/// Discard submitted messages buffered locally across a history-lineage reset.
	void invalidatePendingSubmittedMessages();

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

	/// Callback: called once the native agent session ID is known.
	@property void onNativeSessionStarted(void delegate(string sessionId) callback);

	/// Callback: called for each translated event from the agent.
	@property void onOutput(void delegate(TranslatedEvent) dg);

	/// Callback: called for each line of stderr from the agent.
	@property void onStderr(void delegate(string line) dg);

	/// Callback: called when the agent process exits.
	@property void onExit(void delegate(int status) dg);

	/// Whether the session is still alive (process running, pipes open).
	@property bool alive();
}
