module cydo.workflow.history.operations;

import ae.utils.json : JSONOptional, JSONPartial;
import cydo.agent.drivers.codex.history : CodexHistoryMode;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;

enum HistoryOperation { fork, undo }
enum HistoryOperationMechanism { none, jsonl, codex_native, claude_native }
/// Whether the task's agent session is live and, if so, ready for an
/// in-process history operation (no turn running or queued, and the agent
/// supports the operation).
enum NativeSessionState { dead, liveReady, liveBusy }

struct HistoryOperationKinds
{
	@JSONOptional HistoryOperationMechanism user;
	/// A user boundary on the conversation's first user message.
	@JSONOptional HistoryOperationMechanism first_user;
	@JSONOptional HistoryOperationMechanism provisional_user;
	@JSONOptional HistoryOperationMechanism agent_turn;
}

struct HistoryOperations
{
	HistoryOperationKinds fork;
	HistoryOperationKinds undo;
}

/// `historyMode` is what the driver said of the history it served, 0 when it
/// served none (a file-backed history, or a conversation that began in this
/// session).
HistoryOperations selectHistoryOperations(AgentDriver driver,
	NativeSessionState session, ubyte historyMode)
{
	HistoryOperations result;
	if (driver != AgentDriver.codex)
	{
		result.fork.user = HistoryOperationMechanism.jsonl;
		result.fork.agent_turn = HistoryOperationMechanism.jsonl;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		if (driver == AgentDriver.claude)
		{
			result.undo.provisional_user = HistoryOperationMechanism.jsonl;
			// rewind_conversation accepts an assistant target only mid-turn,
			// after a tool result, so undoing a response while keeping its
			// prompt stays on the JSONL mechanism.
			if (session == NativeSessionState.liveReady)
				result.undo.user = HistoryOperationMechanism.claude_native;
			// Rewriting the session file back to before its first message
			// leaves Claude no conversation to resume ("No conversation
			// found"), and every later message fails the same way.
			result.undo.first_user = session == NativeSessionState.liveReady
				? HistoryOperationMechanism.claude_native
				: HistoryOperationMechanism.none;
		}
		else
			result.undo.first_user = result.undo.user;
		result.fork.first_user = result.fork.user;
		return result;
	}

	// Codex forks before a user turn or through an agent turn. A running
	// turn blocks forks, while undo stops it before reverting.
	if (session != NativeSessionState.liveBusy)
	{
		result.fork.user = HistoryOperationMechanism.codex_native;
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
	}
	// Codex reverts only the threads it keeps a history index of.
	if (historyMode != CodexHistoryMode.legacy)
		result.undo.user = HistoryOperationMechanism.codex_native;
	result.fork.first_user = HistoryOperationMechanism.none;
	result.undo.first_user = result.undo.user;
	return result;
}

/// The fields that identify a user message and its optional history boundary.
@JSONPartial
package(cydo) struct HistoryBoundaryEvent
{
	string type;
	@JSONOptional string item_type;
	@JSONOptional string uuid;
	@JSONOptional string item_id;
	@JSONOptional bool is_meta;
	@JSONOptional bool is_synthetic;
	@JSONOptional bool is_sidechain;
	@JSONOptional bool pending;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional HistoryBoundary history_boundary;

	bool isConversationUser() const
	{
		return type == "item/started" && item_type == "user_message"
			&& !is_meta && !is_synthetic && !is_sidechain && !pending && parent_tool_use_id.length == 0;
	}
}

/// `opensConversation`: no user message precedes `boundary`.
bool allowsOperation(const HistoryBoundary boundary, bool opensConversation,
	const HistoryOperations operations, HistoryOperation operation)
{
	return boundary.anchor.length > 0
		&& operationMechanism(boundary, opensConversation, operations, operation)
			!= HistoryOperationMechanism.none;
}

bool allowsFileRevert(const HistoryBoundary boundary)
{
	return boundary.kind != HistoryBoundaryKind.provisional_user
		&& boundary.checkpoint_uuid.length > 0;
}

HistoryOperationMechanism operationMechanism(const HistoryBoundary boundary,
	bool opensConversation, const HistoryOperations operations, HistoryOperation operation)
{
	auto kinds = operation == HistoryOperation.fork ? operations.fork : operations.undo;
	if (boundary.kind == HistoryBoundaryKind.user)
		return opensConversation ? kinds.first_user : kinds.user;
	if (boundary.kind == HistoryBoundaryKind.provisional_user)
		return kinds.provisional_user;
	return kinds.agent_turn;
}

unittest
{
	auto codex = selectHistoryOperations(AgentDriver.codex, NativeSessionState.dead,
		CodexHistoryMode.paginated);
	auto first = HistoryBoundary("before:first", HistoryBoundaryKind.user, "");
	assert(!allowsOperation(first, true, codex, HistoryOperation.fork),
		"Codex must refuse a fork at the first anchored user message");
	auto later = HistoryBoundary("before:later", HistoryBoundaryKind.user, "");
	assert(allowsOperation(later, false, codex, HistoryOperation.fork));

	foreach (session; [NativeSessionState.dead, NativeSessionState.liveReady,
		NativeSessionState.liveBusy])
	{
		auto forkable = session == NativeSessionState.liveBusy
			? HistoryOperationMechanism.none : HistoryOperationMechanism.codex_native;
		foreach (mode; [ubyte(0), ubyte(CodexHistoryMode.paginated)])
		{
			auto paginated = selectHistoryOperations(AgentDriver.codex, session, mode);
			assert(paginated.fork.user == forkable);
			assert(paginated.fork.first_user == HistoryOperationMechanism.none);
			assert(paginated.fork.agent_turn == forkable);
			assert(paginated.undo.user == HistoryOperationMechanism.codex_native);
			assert(paginated.undo.first_user == HistoryOperationMechanism.codex_native);
			assert(paginated.undo.agent_turn == HistoryOperationMechanism.none);
		}
		auto legacy = selectHistoryOperations(AgentDriver.codex, session,
			CodexHistoryMode.legacy);
		assert(legacy.fork.agent_turn == forkable);
		assert(legacy.fork.user == forkable);
		assert(legacy.fork.first_user == HistoryOperationMechanism.none);
		assert(legacy.undo == HistoryOperationKinds.init);
	}
	auto claude = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.dead, 0);
	assert(claude.fork.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto claudeBusy = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.liveBusy, 0);
	assert(claudeBusy.undo.user == HistoryOperationMechanism.jsonl);
	auto claudeReady = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.liveReady, 0);
	assert(claudeReady.fork.user == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.user == HistoryOperationMechanism.claude_native);
	assert(claudeReady.undo.agent_turn == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.provisional_user == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.first_user == HistoryOperationMechanism.claude_native);
	assert(claude.undo.first_user == HistoryOperationMechanism.none,
		"a stopped Claude session must keep its first message");
	assert(claudeBusy.undo.first_user == HistoryOperationMechanism.none);
	assert(claude.fork.first_user == HistoryOperationMechanism.jsonl);
	auto opening = HistoryBoundary("first", HistoryBoundaryKind.user, "");
	assert(!allowsOperation(opening, true, claude, HistoryOperation.undo));
	assert(allowsOperation(opening, false, claude, HistoryOperation.undo));
	assert(allowsOperation(opening, true, claudeReady, HistoryOperation.undo));
	auto provisional = HistoryBoundary("enqueue-4",
		HistoryBoundaryKind.provisional_user, "");
	assert(!allowsOperation(provisional, false, claude, HistoryOperation.fork),
		"provisional queue boundaries must not be forkable");
	assert(allowsOperation(provisional, false, claude, HistoryOperation.undo),
		"provisional queue boundaries must remain undoable");
	auto boundary = HistoryBoundary("through:t", HistoryBoundaryKind.agent_turn, "");
	assert(allowsOperation(boundary, false, codex, HistoryOperation.fork));
	assert(!allowsOperation(boundary, false, codex, HistoryOperation.undo));
	boundary = HistoryBoundary("before:t", HistoryBoundaryKind.user, "");
	assert(allowsOperation(boundary, false, codex, HistoryOperation.undo));
	assert(!allowsFileRevert(boundary));
	boundary.checkpoint_uuid = "checkpoint";
	assert(allowsFileRevert(boundary));
}
