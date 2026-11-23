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

/// The pending submission was cancelled by a change to task history.
final class SubmissionHistoryCancelled : Exception
{
	this(string reason)
	{
		super(reason);
	}
}

/// Abstract agent session interface.
/// Decouples the transport (WebSocket) from the agent implementation.
/// Whom a message sent to the agent speaks for.
enum MessageSource
{
	/// CyDo itself: deliveries, reminders, nudges.
	harness,
	/// The person using CyDo: what they typed, or a decision they made
	/// (possibly worded by a CyDo template).
	user,
}

/// One piece of work an agent started that runs outside its turns: a
/// background command, a monitor.
struct BackgroundWork
{
	string id;          /// the agent's own handle for it
	string description;
}

/// A session whose agent can be told, in its own conversation, that a tool
/// call it recorded as aborted had been accepted. An agent that offers this
/// keeps its own history; the others have the record itself corrected in
/// their history file (Agent.repairInterruptedToolCall).
interface AbortedToolCallCorrection
{
	/// Fulfills once the agent holds `correction` and will see it before its
	/// next turn.
	Promise!void correctAbortedToolCall(string correction);
}

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
		bool isContextBootstrap = false, string nativeSubmissionUuid = null,
		MessageSource source = MessageSource.harness);

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

	/// Startup failure message, available when the session exits.
	@property string startupFailure();

	/// Callback: called when the agent process exits.
	@property void onExit(void delegate(int status) dg);

	/// The agent no longer awaits any CyDo tool call it has in flight.
	@property void onToolCallsAbandoned(void delegate() dg);

	/// Whether the session is still alive (process running, pipes open).
	@property bool alive();

	/// The work the agent started that is still running outside its turns.
	/// The agent starts a turn of its own when that work reports, so a
	/// turn ending meanwhile need not mean the agent is done.
	@property const(BackgroundWork)[] backgroundWork();
}
