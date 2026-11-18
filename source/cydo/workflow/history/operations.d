module cydo.workflow.history.operations;

import ae.utils.json : JSONOptional;
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
	/// The conversation's first user message: a `user` boundary no other
	/// precedes.
	@JSONOptional HistoryOperationMechanism first_user;
	@JSONOptional HistoryOperationMechanism provisional_user;
	@JSONOptional HistoryOperationMechanism agent_turn;
}

struct HistoryOperations
{
	HistoryOperationKinds fork;
	HistoryOperationKinds undo;
}

HistoryOperations selectHistoryOperations(AgentDriver driver,
	NativeSessionState session)
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

	final switch (session)
	{
	case NativeSessionState.dead:
		// The pinned Codex 0.144.1 thread/fork accepts completed turns only; it has no
		// user/response cut parameter, so user-boundary forks are unsupported.
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	case NativeSessionState.liveReady:
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.codex_native;
		break;
	case NativeSessionState.liveBusy:
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	}
	result.fork.first_user = result.fork.user;
	result.undo.first_user = result.undo.user;
	return result;
}

/// `opensConversation`: no other `user` boundary precedes `boundary`.
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
	import cydo.protocol : HistoryBoundary;
	auto offline = selectHistoryOperations(AgentDriver.codex,
		NativeSessionState.dead);
	assert(offline.fork.user == HistoryOperationMechanism.none);
	assert(offline.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(offline.undo.user == HistoryOperationMechanism.jsonl);
	assert(offline.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto native = selectHistoryOperations(AgentDriver.codex,
		NativeSessionState.liveReady);
	assert(native.fork.user == HistoryOperationMechanism.none);
	assert(native.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(native.undo.user == HistoryOperationMechanism.codex_native);
	assert(native.undo.agent_turn == HistoryOperationMechanism.none);
	auto busy = selectHistoryOperations(AgentDriver.codex,
		NativeSessionState.liveBusy);
	assert(busy.fork.user == HistoryOperationMechanism.none);
	assert(busy.fork.agent_turn == HistoryOperationMechanism.none);
	assert(busy.undo.user == HistoryOperationMechanism.jsonl);
	assert(busy.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto claude = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.dead);
	assert(claude.fork.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto claudeBusy = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.liveBusy);
	assert(claudeBusy.undo.user == HistoryOperationMechanism.jsonl);
	auto claudeReady = selectHistoryOperations(AgentDriver.claude,
		NativeSessionState.liveReady);
	assert(claudeReady.fork.user == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.user == HistoryOperationMechanism.claude_native);
	assert(claudeReady.undo.agent_turn == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.provisional_user == HistoryOperationMechanism.jsonl);
	assert(claudeReady.undo.first_user == HistoryOperationMechanism.claude_native);
	assert(claude.undo.first_user == HistoryOperationMechanism.none,
		"a stopped Claude session must keep its first message");
	assert(claudeBusy.undo.first_user == HistoryOperationMechanism.none);
	assert(claude.fork.first_user == HistoryOperationMechanism.jsonl);
	assert(offline.undo.first_user == HistoryOperationMechanism.jsonl);
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
	auto boundary = HistoryBoundary("a", HistoryBoundaryKind.agent_turn, "");
	assert(allowsOperation(boundary, false, offline, HistoryOperation.undo));
	assert(!allowsOperation(boundary, false, native, HistoryOperation.undo));
	boundary.kind = HistoryBoundaryKind.user;
	assert(!allowsOperation(boundary, false, offline, HistoryOperation.fork));
	assert(!allowsOperation(boundary, false, native, HistoryOperation.fork));
	assert(!allowsFileRevert(boundary));
	boundary.checkpoint_uuid = "checkpoint";
	assert(allowsFileRevert(boundary));
}
