module cydo.workflow.history.operations;

import ae.utils.json : JSONOptional;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;

enum HistoryOperation { fork, undo }
enum HistoryOperationMechanism { none, jsonl, codex_native }
enum CodexForkSourceState { dead, liveReady, liveBusy }

struct HistoryOperationKinds
{
	@JSONOptional HistoryOperationMechanism user;
	@JSONOptional HistoryOperationMechanism provisional_user;
	@JSONOptional HistoryOperationMechanism agent_turn;
}

struct HistoryOperations
{
	HistoryOperationKinds fork;
	HistoryOperationKinds undo;
}

HistoryOperations selectHistoryOperations(AgentDriver driver,
	CodexForkSourceState codexForkSource)
{
	HistoryOperations result;
	if (driver != AgentDriver.codex)
	{
		result.fork.user = HistoryOperationMechanism.jsonl;
		result.fork.agent_turn = HistoryOperationMechanism.jsonl;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		if (driver == AgentDriver.claude)
			result.undo.provisional_user = HistoryOperationMechanism.jsonl;
		return result;
	}

	final switch (codexForkSource)
	{
	case CodexForkSourceState.dead:
		// The pinned Codex 0.144.1 thread/fork accepts completed turns only; it has no
		// user/response cut parameter, so user-boundary forks are unsupported.
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	case CodexForkSourceState.liveReady:
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.codex_native;
		break;
	case CodexForkSourceState.liveBusy:
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	}
	return result;
}

bool allowsOperation(const HistoryBoundary boundary, const HistoryOperations operations,
	HistoryOperation operation)
{
	return boundary.anchor.length > 0
		&& operationMechanism(boundary, operations, operation) != HistoryOperationMechanism.none;
}

bool allowsFileRevert(const HistoryBoundary boundary)
{
	return boundary.kind != HistoryBoundaryKind.provisional_user
		&& boundary.checkpoint_uuid.length > 0;
}

HistoryOperationMechanism operationMechanism(const HistoryBoundary boundary,
	const HistoryOperations operations, HistoryOperation operation)
{
	auto kinds = operation == HistoryOperation.fork ? operations.fork : operations.undo;
	if (boundary.kind == HistoryBoundaryKind.user)
		return kinds.user;
	if (boundary.kind == HistoryBoundaryKind.provisional_user)
		return kinds.provisional_user;
	return kinds.agent_turn;
}

unittest
{
	import cydo.protocol : HistoryBoundary;
	auto offline = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.dead);
	assert(offline.fork.user == HistoryOperationMechanism.none);
	assert(offline.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(offline.undo.user == HistoryOperationMechanism.jsonl);
	assert(offline.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto native = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.liveReady);
	assert(native.fork.user == HistoryOperationMechanism.none);
	assert(native.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(native.undo.user == HistoryOperationMechanism.codex_native);
	assert(native.undo.agent_turn == HistoryOperationMechanism.none);
	auto busy = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.liveBusy);
	assert(busy.fork.user == HistoryOperationMechanism.none);
	assert(busy.fork.agent_turn == HistoryOperationMechanism.none);
	assert(busy.undo.user == HistoryOperationMechanism.jsonl);
	assert(busy.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto claude = selectHistoryOperations(AgentDriver.claude,
		CodexForkSourceState.dead);
	assert(claude.fork.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto provisional = HistoryBoundary("enqueue-4",
		HistoryBoundaryKind.provisional_user, "");
	assert(!allowsOperation(provisional, claude, HistoryOperation.fork),
		"provisional queue boundaries must not be forkable");
	assert(allowsOperation(provisional, claude, HistoryOperation.undo),
		"provisional queue boundaries must remain undoable");
	auto boundary = HistoryBoundary("a", HistoryBoundaryKind.agent_turn, "");
	assert(allowsOperation(boundary, offline, HistoryOperation.undo));
	assert(!allowsOperation(boundary, native, HistoryOperation.undo));
	boundary.kind = HistoryBoundaryKind.user;
	assert(!allowsOperation(boundary, offline, HistoryOperation.fork));
	assert(!allowsOperation(boundary, native, HistoryOperation.fork));
	assert(!allowsFileRevert(boundary));
	boundary.checkpoint_uuid = "checkpoint";
	assert(allowsFileRevert(boundary));
}
