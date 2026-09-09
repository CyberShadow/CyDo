module cydo.workflow.tasks.mutations;

import core.lifetime : move;

import std.exception : enforce;
import std.file : exists, readText;
import std.logger : warningf;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.json : jsonParse, toJson;
import ae.utils.promise : Promise;
import ae.utils.statequeue : StateQueue;

import cydo.agent.contract : Agent, PersistedHistoryBoundaryKind, SessionConfig;
import cydo.agent.drivers.codex : CodexAgent, CodexSession,
	NativeUndoExecutionResult, NativeUndoExecutionStatus, NativeUndoPlan,
	ThreadForkOutcome,
	countActiveFallbackRecordsFromBoundary;
import cydo.agent.drivers.codex.rollout : resolveCodexFallbackUndoAnchor;
import cydo.agent.session : AgentSession;
import cydo.domain.storage.persistence : Persistence, createForkTask;
import cydo.domain.task_types.definition : TaskTypeDef;
import cydo.domain.tasks.model : ArchiveState, CodexNativeUndoState, ErrorMessage,
	ProcessState, TaskCreatedMessage, TaskData, TaskStatus, UndoPreviewMessage,
	UndoResultMessage, Watermark, WsMessage, watermarkFromPath;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.workflow.history.jsonl_edit : replaceUserMessageContent;
import cydo.workflow.history.operations : CodexForkSourceState, HistoryOperation,
	HistoryOperationMechanism, allowsFileRevert, allowsOperation, operationMechanism,
	selectHistoryOperations;
import cydo.workflow.history.jsonl_store : countLinesAfterForkId,
	editJsonlMessage, forkTask, HistoryForkDestination, spliceJsonlByLine,
	truncateJsonl, writeJsonlPrefix;
import cydo.workflow.history.native_history : HistoryAccess,
	TaskHistoryResolution, TaskHistoryResolutionKind;
import cydo.workflow.sessions.task_runner : CodexForkSourceOperation,
	TaskSessionLaunch;
import cydo.runtime.launch.types : ProcessLaunch;
import cydo.runtime.launch.sandbox : cleanup;
import cydo.runtime.config : AgentDriver;

package(cydo):

alias MutationReply = void delegate(Data);

private struct MutationReplySocket
{
	MutationReply reply;
	void send(Data data) { reply(data); }
}


struct TaskMutationServiceHost
{
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, TaskData td) putTask;
	void delegate(int tid) removeTask;

	Agent delegate(int tid) agentForTask;
	AgentSession delegate(int tid) sessionForTask;
	bool delegate(int tid) taskAlive;
	void delegate(int tid) stopTask;

	TaskSessionLaunch delegate(int tid, Agent taskAgent,
		TaskTypeDef* typeDef) prepareTaskSessionLaunch;
	TaskSessionLaunch delegate(int tid, Agent taskAgent,
		TaskTypeDef* typeDef) prepareOperationSessionLaunch;
	TaskTypeDef* delegate(string projectPath, string taskTypeName) taskTypeForProject;
	Promise!ProcessState delegate(ProcessState) delegate(int tid) makeProcessQueueSF;
	Promise!ArchiveState delegate(ArchiveState) delegate(int tid) makeArchiveQueueSF;

	Persistence* delegate() persistence;
	void delegate(int tid) deleteTask;
	void delegate(int tid, string agentSessionId) setAgentSessionId;
	void delegate(int tid, string relationType) setRelationType;
	void delegate(int tid, string title) setTitle;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;

	void delegate(int tid) ensureHistoryLoaded;
	TaskHistoryResolution delegate(int tid) resolveTaskHistory;
	void delegate(int tid, const ref TaskHistoryResolution resolution)
		reportUnavailableHistory;
	ProcessLaunch delegate(int tid, const ref HistoryAccess access)
		requireLiveHistoryLaunch;
	CodexForkSourceOperation delegate(int tid, const ref HistoryAccess access)
		openCodexForkSourceOperation;
	CodexForkSourceState delegate(int tid) codexForkSourceState;
	bool delegate(int tid, const ref HistoryAccess access,
		string requestedAnchor, out HistoryBoundary boundary)
		resolveFreshPersistedBoundary;
	HistoryForkDestination delegate(int sourceTid) prepareHistoryForkDestination;
	string delegate(int tid) getUndoJsonl;
	void delegate(int tid) clearUndoJsonl;
	void delegate(int tid) invalidateJsonlLineage;
	void delegate(int tid) startJsonlWatch;
	void delegate(int tid) stopJsonlWatch;

	void delegate(int tid) generateSuggestions;
	void delegate(int tid) unsubscribeTaskHistorySubscribers;
	void delegate(int tid, string reason) emitTaskReload;
	void delegate(TaskCreatedMessage message) broadcastTaskCreated;
	void delegate(int tid) broadcastTaskUpdate;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
}

private final class FallbackUndoTransaction
{
	private bool finalized_;
	private void delegate() finalize_;

	this(void delegate() finalize)
	{
		finalize_ = finalize;
	}

	bool finalize()
	{
		if (finalized_)
			return false;
		finalized_ = true;
		finalize_();
		return true;
	}

	void fail(void delegate() report)
	{
		if (finalize())
			report();
	}
}

private void gateLiveUndoBackup(
	void delegate(void delegate() success, void delegate(string) failure) beginBackup,
	void delegate() beginStop, void delegate(string) reportFailure)
{
	bool settled;
	beginBackup(() {
		if (settled)
			return;
		settled = true;
		beginStop();
	}, (string message) {
		if (settled)
			return;
		settled = true;
		reportFailure(message);
	});
}

unittest
{
	string[] calls;
	auto transaction = new FallbackUndoTransaction(() { calls ~= "reset"; calls ~= "reload"; });
	transaction.finalize();
	transaction.finalize();
	transaction.fail(() { calls ~= "error"; });
	assert(calls == ["reset", "reload"]);

	string[] rejectionCalls;
	auto rejected = new FallbackUndoTransaction(() {
		rejectionCalls ~= "reset";
		rejectionCalls ~= "reload";
	});
	rejected.fail(() { rejectionCalls ~= "dead-rejected"; });
	assert(rejectionCalls == ["reset", "reload", "dead-rejected"]);

	string[] rewindCalls;
	auto rewindFailed = new FallbackUndoTransaction(() {
		rewindCalls ~= "reset";
		rewindCalls ~= "reload";
	});
	rewindFailed.fail(() { rewindCalls ~= "rewind-failed"; });
	assert(rewindCalls == ["reset", "reload", "rewind-failed"]);

	void delegate() success;
	void delegate(string) failure;
	int backupCalls;
	int stopCalls;
	int gateErrors;
	gateLiveUndoBackup((void delegate() onSuccess, void delegate(string) onFailure) {
		backupCalls++;
		success = onSuccess;
		failure = onFailure;
	}, () { stopCalls++; }, (string) { gateErrors++; });
	assert(backupCalls == 1 && stopCalls == 0);
	failure("failure");
	assert(stopCalls == 0);
	success();
	assert(stopCalls == 0 && gateErrors == 1);

	gateLiveUndoBackup((void delegate() onSuccess, void delegate(string) onFailure) {
		success = onSuccess;
		failure = onFailure;
	}, () { stopCalls++; }, (string) { gateErrors++; });
	success();
	success();
	failure("late");
	assert(stopCalls == 1 && gateErrors == 1);
}

class TaskMutationService
{
private:
	TaskMutationServiceHost host_;
	alias RunLiveCodexUndoBackup = void delegate(MutationReplySocket, int,
		HistoryAccess, string, CodexSession, void delegate(), void delegate(string));
	RunLiveCodexUndoBackup runLiveCodexUndoBackup_;

public:
	this(TaskMutationServiceHost host, RunLiveCodexUndoBackup runLiveCodexUndoBackup = null)
	{
		host_ = host;
		runLiveCodexUndoBackup_ = runLiveCodexUndoBackup;
	}

	void handleForkTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}

		HistoryAccess source;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Fork failed: task history file not found", source))
			return;
		auto ta = source.agent;
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, source, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSession = cast(CodexSession) host_.sessionForTask(tid);
		auto operations = selectHistoryOperations(ta.driver,
			host_.codexForkSourceState(tid));
		if (!allowsOperation(boundary, operations, HistoryOperation.fork))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto mechanism = operationMechanism(boundary, operations, HistoryOperation.fork);
		if (mechanism == HistoryOperationMechanism.codex_native)
		{
			auto ca = cast(CodexAgent) ta;
			assert(ca !is null, "Codex-native fork requires Codex agent");
			if (codexSession !is null)
			{
				beginCodexNativeFork(ws, tid, source, boundary, ca, codexSession, null);
				return;
			}
			CodexForkSourceOperation operation;
			try
				operation = host_.openCodexForkSourceOperation(tid, source);
			catch (Exception e)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: " ~ e.msg, tid)).representation));
				return;
			}
			operation.routeReady.then((CodexSession owner) {
				beginCodexNativeFork(ws, tid, source, boundary, ca, owner, operation);
			}, (Exception e) {
				operation.closeStdin();
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: " ~ e.msg, tid)).representation));
			}).ignoreResult();
			return;
		}

		enforce(ta.driver != AgentDriver.codex,
			"Codex history forks must use the native source-owner path");
		auto destination = host_.prepareHistoryForkDestination(tid);
		auto result = forkTask(*host_.persistence(), tid, source, boundary.anchor,
			td.projectPath, td.workspace, td.title, destination,
			&ta.rewriteSessionId, &ta.forkIdMatchesLine, td.description, td.taskType,
			td.agentName);
		if (result.tid < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}

		import std.datetime : Clock;

		if (td.worktreeTid > 0)
			host_.persistence().setWorktreeTid(result.tid, td.worktreeTid);
		auto newTd = TaskData(result.tid, td.workspace, td.projectPath);
		newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
		newTd.agentSessionId = result.agentSessionId;
		newTd.parentTid = tid;
		newTd.relationType = "fork";
		newTd.status = TaskStatus.completed;
		newTd.agentName = td.agentName;
		newTd.description = td.description;
		newTd.taskType = td.taskType;
		newTd.worktreeTid = td.worktreeTid;
		newTd.createdAt = Clock.currStdTime;
		newTd.lastActive = newTd.createdAt;
		host_.putTask(result.tid, move(newTd));
		auto child = host_.getTask(result.tid);
		assert(child !is null, "Fork child task must exist after insertion");
		child.processQueue = new StateQueue!ProcessState(
			host_.makeProcessQueueSF(result.tid),
			ProcessState.Dead,
		);
		child.archiveQueue = new StateQueue!ArchiveState(
			host_.makeArchiveQueueSF(result.tid),
			ArchiveState.Unarchived,
		);
		child.history.reset(watermarkFromPath(result.destinationPath));

		host_.broadcastTaskCreated(TaskCreatedMessage("task_created", result.tid,
			td.workspace, td.projectPath, tid, "fork"));
		host_.broadcastTaskUpdate(result.tid);
		host_.broadcastFocusHint(tid, result.tid);
	}

	void handleUndoTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		handleUndoTaskMsg((Data data) => ws.send(data), json);
	}

	void handleUndoTaskMsg(MutationReply reply, WsMessage json)
	{
		auto ws = MutationReplySocket(reply);
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}
		if (!json.dry_run && td.codexNativeUndoState == CodexNativeUndoState.inFlight)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Native Codex undo is already in progress", tid)).representation));
			return;
		}

		HistoryAccess access;
		if (!requireHistoryAccess(ws, tid, "UUID not found in task history", access))
			return;
		auto ta = access.agent;
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, access, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSourceState = host_.codexForkSourceState(tid);
		auto operations = selectHistoryOperations(ta.driver, codexSourceState);
		if (!allowsOperation(boundary, operations, HistoryOperation.undo))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto mechanism = operationMechanism(boundary, operations, HistoryOperation.undo);
		auto codexSession = cast(CodexSession) host_.sessionForTask(tid);
		if (json.revert_files && !allowsFileRevert(boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "File revert is unavailable for this history boundary", tid)).representation));
			return;
		}
		if (json.dry_run)
		{
			if (mechanism == HistoryOperationMechanism.codex_native)
			{
				if (td.codexNativeUndoState != CodexNativeUndoState.idle)
				{
					auto message = td.codexNativeUndoState == CodexNativeUndoState.inFlight
						? "Native Codex undo is in progress; request a new preview after it finishes"
						: "Codex may already have changed or lost history; native undo is blocked in this running CyDo process";
					ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
					return;
				}
				assert(codexSession !is null,
					"Codex-native undo policy requires a live Codex session");
				codexSession.prepareNativeUndo(boundary).then((NativeUndoPlan plan) {
					ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
						cast(int) plan.numTurns, "codex_turns")).representation));
				}, (Exception e) {
					ws.send(Data(toJson(ErrorMessage("error",
						"Native Codex undo preparation refused: " ~ e.msg, tid)).representation));
				}).ignoreResult();
				return;
			}
			if (cast(CodexAgent) ta !is null)
			{
				import std.file : exists, readText;

				auto jsonlPath = access.path;
				auto count = countActiveFallbackRecordsFromBoundary(readText(jsonlPath), boundary.anchor);
				if (count < 0)
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid, count,
					"history_entries")).representation));
				return;
			}

			auto count = countLinesAfterForkId(
				access.path,
				boundary.anchor,
				&ta.forkIdMatchesLine,
				&ta.isForkableLine);
			if (count < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
				return;
			}
			ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
				count + 1, "history_entries")).representation));
			return;
		}

		if (json.expected_num_turns
			&& mechanism != HistoryOperationMechanism.codex_native)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Native Codex undo preview is stale; request a new preview", tid)).representation));
			return;
		}

		if (mechanism == HistoryOperationMechanism.codex_native)
		{
			if (td.codexNativeUndoState != CodexNativeUndoState.idle)
			{
				auto message = td.codexNativeUndoState == CodexNativeUndoState.inFlight
					? "Native Codex undo is already in progress"
					: "Codex may already have changed or lost history; native undo is blocked in this running CyDo process";
				ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
				return;
			}
			if (!json.expected_num_turns || json.expected_num_turns.get == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Native Codex undo confirmation is stale; request a new preview", tid)).representation));
				return;
			}
			assert(codexSession !is null,
				"Codex-native undo policy requires a live Codex session");
			auto expectedNumTurns = json.expected_num_turns.get;
			td.beginConfirmedNativeUndo();
			codexSession.prepareNativeUndo(boundary).then((NativeUndoPlan plan) {
				auto current = host_.getTask(tid);
				assert(current !is null,
					"Undo target task must exist while native preparation completes");
				if (plan.numTurns != expectedNumTurns)
				{
					current.clearNativeUndoRefusalBeforeDispatch();
					ws.send(Data(toJson(ErrorMessage("error",
						"Native Codex undo count changed; request a new preview", tid)).representation));
					return;
				}
				try
				{
					codexSession.executeNativeUndo(plan, {
						host_.invalidateJsonlLineage(tid);
					}).then((NativeUndoExecutionResult outcome) {
						auto completed = host_.getTask(tid);
						assert(completed !is null,
							"Undo target task must exist while native execution completes");
						final switch (outcome.status)
						{
							case NativeUndoExecutionStatus.refusedBeforeDispatch:
								completed.clearNativeUndoRefusalBeforeDispatch();
								ws.send(Data(toJson(ErrorMessage("error",
									"Native Codex undo refused before dispatch: "
										~ outcome.diagnostic, tid)).representation));
								return;
							case NativeUndoExecutionStatus.unverifiableAfterDispatch:
								completed.markCodexNativeUndoUnverified();
								ws.send(Data(toJson(ErrorMessage("error",
									"Native Codex undo could not be verified after dispatch; Codex may already have changed or lost history. Sends are blocked only in this running CyDo process. "
										~ outcome.diagnostic, tid)).representation));
								return;
							case NativeUndoExecutionStatus.verified:
								break;
						}

						try
						{
							host_.clearUndoJsonl(tid);
							completed.history.reset(watermarkFromPath(access.path));
							host_.unsubscribeTaskHistorySubscribers(tid);

							if (completed.pendingSteeringTexts.length > 0)
							{
								import std.file : exists, readText;

								auto histPath = access.path;
								if (histPath.exists)
								{
									auto boundaries = ta.extractPersistedHistoryBoundaries(readText(histPath));
									int remaining = 0;
									foreach (ref f; boundaries)
										if (f.kind == PersistedHistoryBoundaryKind.user)
											remaining++;
									if (remaining < cast(int) completed.pendingSteeringTexts.length)
										completed.pendingSteeringTexts =
											completed.pendingSteeringTexts[0 .. remaining].dup;
								}
							}

							if (auto session = host_.sessionForTask(tid))
								session.invalidatePendingSubmittedMessages();
							host_.emitTaskReload(tid, "");
							host_.startJsonlWatch(tid);
							host_.broadcastTaskUpdate(tid);
						}
						catch (Exception e)
						{
							completed.markCodexNativeUndoUnverified();
							ws.send(Data(toJson(ErrorMessage("error",
								"Native Codex undo cleanup could not be verified; Codex may already have changed or lost history. Sends are blocked only in this running CyDo process. "
									~ e.msg, tid)).representation));
							return;
						}
						completed.completeVerifiedNativeUndoCleanup();
						ws.send(Data(toJson(UndoResultMessage("undo_result", tid, "")).representation));
					}, (Exception e) {
						auto failed = host_.getTask(tid);
						assert(failed !is null,
							"Undo target task must exist while native execution fails");
						failed.markCodexNativeUndoUnverified();
						ws.send(Data(toJson(ErrorMessage("error",
							"Native Codex undo could not be verified after dispatch; Codex may already have changed or lost history. Sends are blocked only in this running CyDo process. "
								~ e.msg, tid)).representation));
					}).ignoreResult();
				}
				catch (Exception e)
				{
					current.markCodexNativeUndoUnverified();
					ws.send(Data(toJson(ErrorMessage("error",
						"Native Codex undo could not be verified after dispatch; Codex may already have changed or lost history. Sends are blocked only in this running CyDo process. "
							~ e.msg, tid)).representation));
				}
			}, (Exception e) {
				auto refused = host_.getTask(tid);
				assert(refused !is null,
					"Undo target task must exist while native preparation fails");
				refused.clearNativeUndoRefusalBeforeDispatch();
				ws.send(Data(toJson(ErrorMessage("error",
					"Native Codex undo preparation refused: " ~ e.msg, tid)).representation));
			}).ignoreResult();
			return;
		}

		string truncationAnchor = boundary.anchor;
		if (ta.driver == AgentDriver.codex && json.revert_conversation)
		{
			import std.file : readText;

			// Resolve before backup/stop side effects; carry the result through the
			// asynchronous fallback execution path unchanged.
			truncationAnchor = resolveCodexFallbackUndoAnchor(readText(access.path),
				boundary.kind == HistoryBoundaryKind.agent_turn
					? PersistedHistoryBoundaryKind.agent_turn
					: PersistedHistoryBoundaryKind.user, boundary.anchor);
			if (truncationAnchor.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"UUID not found for truncation", tid)).representation));
				return;
			}
		}

		if (host_.taskAlive(tid))
		{
			auto liveLaunch = host_.requireLiveHistoryLaunch(tid, access);
			fallbackUndoKillAndTruncate(ws, tid, json, boundary, mechanism, access,
				liveLaunch, false, truncationAnchor);
			return;
		}

		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		performUndoExecution(ws, tid, json, boundary, mechanism, access,
			ProcessLaunch.init, ta.driver == AgentDriver.codex
			&& codexSourceState == CodexForkSourceState.dead
			? UndoBackupDisposition.deadCodexNative : UndoBackupDisposition.generic,
			null, null, truncationAnchor);
	}

	void handleEditMessage(WebSocketAdapter ws, WsMessage json)
	{
		import std.algorithm : startsWith;

		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}
		if (host_.taskAlive(tid))
		{
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing messages", tid)).representation));
			return;
		}

		HistoryAccess access;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Message UUID not found in history", access))
			return;
		auto ta = access.agent;
		auto jsonlPath = access.path;
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		auto targetUuid = json.after_uuid;
		string fallbackUuid;
		if (targetUuid.startsWith("enqueue-"))
		{
			host_.ensureHistoryLoaded(tid);
			fallbackUuid = td.checkpointUuidForAnchor(targetUuid);
		}
		if (targetUuid.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		auto edited = editJsonlMessage(jsonlPath, targetUuid,
			&ta.forkIdMatchesLine,
			(string line) => replaceUserMessageContent(line, newContent));
		if (!edited && fallbackUuid.length > 0)
		{
			edited = editJsonlMessage(jsonlPath, fallbackUuid,
				&ta.forkIdMatchesLine,
				(string line) => replaceUserMessageContent(line, newContent));
		}
		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		host_.invalidateJsonlLineage(tid);
		td.history.reset(watermarkFromPath(jsonlPath));
		host_.unsubscribeTaskHistorySubscribers(tid);
		host_.emitTaskReload(tid, "edit");
		host_.broadcastTaskUpdate(tid);
	}

	void handleEditRawEvent(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}
		if (host_.taskAlive(tid))
		{
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing events", tid)).representation));
			return;
		}

		auto seq = json.seq;
		if (seq < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Invalid seq number", tid)).representation));
			return;
		}

		host_.ensureHistoryLoaded(tid);
		if (seq >= td.history.length || td.history.rawAt(seq) is null)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Seq out of range or no raw source", tid)).representation));
			return;
		}

		auto sourceLine = td.history.sourceLineAt(seq);
		HistoryAccess access;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Raw event not found in JSONL file", access))
			return;
		auto ta = access.agent;
		auto jsonlPath = access.path;
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";

		string[] compactLines;
		try
		{
			compactLines = compactRawEventObjectSequence(newContent);
		}
		catch (Exception e)
		{
			ws.send(Data(toJson(ErrorMessage("error", e.msg, tid)).representation));
			return;
		}

		auto edited = spliceJsonlByLine(jsonlPath, sourceLine, compactLines);
		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Raw event not found in JSONL file", tid)).representation));
			return;
		}

		host_.invalidateJsonlLineage(tid);
		td.history.reset(watermarkFromPath(jsonlPath));
		host_.unsubscribeTaskHistorySubscribers(tid);
		host_.emitTaskReload(tid, "edit");
		host_.broadcastTaskUpdate(tid);
	}

private:
	bool requireHistoryAccess(MutationReplySocket ws, int tid, string failure,
		out HistoryAccess access)
	{
		auto resolution = host_.resolveTaskHistory(tid);
		final switch (resolution.kind)
		{
		case TaskHistoryResolutionKind.access:
			access = resolution.requireAccess();
			return true;
		case TaskHistoryResolutionKind.unavailable:
			host_.reportUnavailableHistory(tid, resolution);
			break;
		case TaskHistoryResolutionKind.noSession:
		case TaskHistoryResolutionKind.orphanAgent:
			break;
		}
		ws.send(Data(toJson(ErrorMessage("error", failure, tid)).representation));
		return false;
	}

	private struct CodexNativeChildSpec
	{
		string titleSuffix;
		string emptyTitle;
		string relationType;
		string failurePrefix;
	}

	private alias CodexNativeChildMaterialized =
		void delegate(int childTid, string workspace, string projectPath);

	/// The Codex cold scanner recursively examines only profile.root/sessions.
	/// Keep the temporary thread/fork input inside the mounted profile root but
	/// outside that namespace, so it cannot impersonate a rollout during the
	/// native operation.
	private string makeCodexForkInputPath(const ref HistoryAccess source)
	{
		import std.algorithm : startsWith;
		import std.path : buildPath, isAbsolute;
		import std.uuid : randomUUID;

		enforce(source.profile.driver == AgentDriver.codex,
			"Codex native fork input requires a Codex history profile");
		auto sessionsRoot = buildPath(source.profile.root, "sessions");
		enforce(source.path.length > 0 && isAbsolute(source.path)
			&& source.path.startsWith(sessionsRoot ~ "/"),
			"Codex native fork source is not inside the captured sessions directory");
		auto inputPath = buildPath(source.profile.root,
			".cydo-fork-input-" ~ randomUUID().toString() ~ ".jsonl");
		enforce(!(inputPath == sessionsRoot || inputPath.startsWith(sessionsRoot ~ "/")),
			"Codex native fork input must not be cold-scanned as a session");
		return inputPath;
	}

	void beginCodexNativeFork(WebSocketAdapter ws, int tid, HistoryAccess source,
		HistoryBoundary boundary, CodexAgent ca, CodexSession forkOwner,
		CodexForkSourceOperation operation)
	{
		CodexNativeChildSpec childSpec;
		childSpec.titleSuffix = " (fork)";
		childSpec.emptyTitle = "(fork)";
		childSpec.relationType = "fork";
		childSpec.failurePrefix = "Fork failed";
		materializeCodexNativeChild(
			MutationReplySocket((Data data) => ws.send(data)), tid, source,
			boundary.anchor, ca, forkOwner, operation, childSpec,
			(int childTid, string workspace, string projectPath) {
				host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
					workspace, projectPath, tid, "fork"));
				host_.broadcastTaskUpdate(childTid);
				host_.broadcastFocusHint(tid, childTid);
			},
		);
	}

	void materializeCodexNativeChild(MutationReplySocket ws, int tid,
		HistoryAccess source, string forkAnchor, CodexAgent ca,
		CodexSession forkOwner, CodexForkSourceOperation operation,
		CodexNativeChildSpec childSpec,
		CodexNativeChildMaterialized onMaterialized)
	{
		import std.datetime : Clock;
		import std.file : isFile, remove;
		import std.path : isAbsolute;
		import std.stdio : File;

		auto td = host_.getTask(tid);
		if (td is null)
		{
			if (operation !is null)
				operation.closeStdin();
			return;
		}
		assert(forkOwner !is null,
			"Codex-native fork requires its exact live source owner");
		enforce(forkAnchor.length > 0,
			"Codex-native fork requires a source boundary");
		enforce(childSpec.titleSuffix.length > 0 && childSpec.emptyTitle.length > 0
			&& childSpec.relationType.length > 0 && childSpec.failurePrefix.length > 0,
			"Codex-native child requires complete durable child metadata");
		enforce(onMaterialized !is null,
			"Codex-native child requires a completion continuation");

		auto sourceAgent = source.agent;
		auto sourcePath = source.path;
		auto sourceWorkspace = td.workspace.idup;
		auto sourceProjectPath = td.projectPath.idup;
		auto sourceTitle = td.title.idup;
		auto sourceDescription = td.description.idup;
		auto sourceTaskType = td.taskType.idup;
		auto sourceAgentName = td.agentName.idup;
		auto sourceWorktreeTid = td.worktreeTid;
		string prefixPath;
		int childTid = -1;
		ProcessLaunch childLaunch;
		bool ownsChildLaunch;
		bool settled;

		void removePrefix()
		{
			try
			{
				if (prefixPath.length > 0 && exists(prefixPath))
					remove(prefixPath);
			}
			catch (Exception)
			{
			}
		}

		void cleanupChildLaunch()
		{
			if (!ownsChildLaunch)
				return;
			ownsChildLaunch = false;
			cleanup(childLaunch.sandbox);
		}

		void cleanupFailure()
		{
			cleanupChildLaunch();
			removePrefix();
			if (childTid >= 0)
			{
				host_.removeTask(childTid);
				host_.deleteTask(childTid);
				childTid = -1;
			}
			if (operation !is null)
				operation.closeStdin();
		}

		void fail(string message)
		{
			if (settled)
				return;
			settled = true;
			cleanupFailure();
			ws.send(Data(toJson(ErrorMessage("error", childSpec.failurePrefix ~ ": " ~ message,
				tid)).representation));
		}

		try
		{
			prefixPath = makeCodexForkInputPath(source);
			if (!writeJsonlPrefix(sourcePath, prefixPath, forkAnchor,
				&sourceAgent.forkIdMatchesLine))
			{
				fail("message UUID not found in task history");
				return;
			}

			childTid = createForkTask(*host_.persistence(), tid, "", sourceProjectPath,
				sourceWorkspace, sourceTitle, sourceDescription, sourceTaskType,
				sourceAgentName);
			if (sourceWorktreeTid > 0)
				host_.persistence().setWorktreeTid(childTid, sourceWorktreeTid);
			auto newTd = TaskData(childTid, sourceWorkspace, sourceProjectPath);
			newTd.title = sourceTitle.length > 0
				? sourceTitle ~ childSpec.titleSuffix : childSpec.emptyTitle;
			newTd.parentTid = tid;
			newTd.relationType = childSpec.relationType;
			newTd.status = TaskStatus.completed;
			newTd.agentName = sourceAgentName;
			newTd.description = sourceDescription;
			newTd.taskType = sourceTaskType;
			newTd.worktreeTid = sourceWorktreeTid;
			newTd.createdAt = Clock.currStdTime;
			newTd.lastActive = newTd.createdAt;
			host_.setRelationType(childTid, childSpec.relationType);
			host_.setTitle(childTid, newTd.title);
			host_.putTask(childTid, move(newTd));
			auto child = host_.getTask(childTid);
			assert(child !is null, "Fork child task must exist after insertion");
			child.history.reset(Watermark.none());

			auto childAgent = host_.agentForTask(childTid);
			auto childTypeDef = host_.taskTypeForProject(child.projectPath,
				child.taskType);
			auto launch = host_.prepareOperationSessionLaunch(childTid, childAgent,
				childTypeDef);
			childLaunch = launch.processLaunch;
			ownsChildLaunch = true;
			enforce(childLaunch.nativeHistoryProfile.driver == source.profile.driver
				&& childLaunch.nativeHistoryProfile.root == source.profile.root,
				"Codex native fork child launch must use the captured source profile");

			auto fork = ca.forkSession(forkOwner, childTid, source.sessionId,
				prefixPath, childLaunch, launch.sessionConfig);
			fork.then((ThreadForkOutcome outcome) {
				if (settled)
					return;
				if (!outcome.ok)
				{
					fail(outcome.error);
					return;
				}

				bool releasedLease;
				try
				{
					enforce(outcome.historyLease !is null,
						"Codex native fork returned no history-path lease");
					auto historyPath = outcome.historyLease.path;
					enforce(historyPath.length > 0 && isAbsolute(historyPath),
						"Codex native fork returned a non-absolute history path");
					enforce(exists(historyPath) && isFile(historyPath),
						"Codex native fork returned an unreadable history path");
					auto readable = File(historyPath, "r");
					scope(exit) readable.close();

					auto currentChild = host_.getTask(childTid);
					assert(currentChild !is null,
						"Fork child task must exist until fork completion");
					currentChild.agentSessionId = outcome.threadId;
					host_.setAgentSessionId(childTid, outcome.threadId);
					currentChild.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(childTid), ProcessState.Dead);
					currentChild.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(childTid), ArchiveState.Unarchived);
					currentChild.history.reset(watermarkFromPath(historyPath));

					outcome.historyLease.release();
					releasedLease = true;
					removePrefix();
					cleanupChildLaunch();
					if (operation !is null)
						operation.closeStdin();
					settled = true;
					onMaterialized(childTid, sourceWorkspace, sourceProjectPath);
				}
				catch (Exception e)
				{
					if (!releasedLease && outcome.historyLease !is null)
						outcome.historyLease.release();
					fail(e.msg);
				}
			}, (Exception e) {
				fail(e.msg);
			}).ignoreResult();
		}
		catch (Exception e)
		{
			fail(e.msg);
		}
	}

	/// A JSONL undo keeps its outer truncate semantics, but a dead Codex source
	/// can create the durable pre-undo child only through the route-ready
	/// operation owner and its owner-bound thread/fork lease.
	void beginCodexJsonlUndoBackup(MutationReplySocket ws, int tid,
		HistoryAccess source, string lastForkId, void delegate() continueUndo)
	{
		auto codex = cast(CodexAgent) source.agent;
		assert(codex !is null && source.profile.driver == AgentDriver.codex,
			"Codex JSONL undo backup requires Codex history access");
		enforce(lastForkId.length > 0,
			"Codex JSONL undo backup requires the last persisted boundary");
		enforce(continueUndo !is null,
			"Codex JSONL undo backup requires a truncate continuation");

		CodexForkSourceOperation operation;
		try
			operation = host_.openCodexForkSourceOperation(tid, source);
		catch (Exception e)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Undo failed: pre-undo backup: " ~ e.msg, tid)).representation));
			return;
		}

		operation.routeReady.then((CodexSession owner) {
			CodexNativeChildSpec childSpec;
			childSpec.titleSuffix = " (pre-undo)";
			childSpec.emptyTitle = "(pre-undo)";
			childSpec.relationType = "undo-backup";
			childSpec.failurePrefix = "Undo failed: pre-undo backup";
			materializeCodexNativeChild(ws, tid, source, lastForkId, codex,
				owner, operation, childSpec,
				(int childTid, string workspace, string projectPath) {
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
						workspace, projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(childTid);
					continueUndo();
				},
			);
		}, (Exception e) {
			operation.closeStdin();
			ws.send(Data(toJson(ErrorMessage("error",
				"Undo failed: pre-undo backup: " ~ e.msg, tid)).representation));
		}).ignoreResult();
	}

	void beginLiveCodexJsonlUndoBackup(MutationReplySocket ws, int tid,
		HistoryAccess source, string lastForkId, CodexSession owner,
		void delegate() continueUndo)
	{
		auto codex = cast(CodexAgent) source.agent;
		assert(codex !is null && owner !is null);
		CodexNativeChildSpec childSpec;
		childSpec.titleSuffix = " (pre-undo)";
		childSpec.emptyTitle = "(pre-undo)";
		childSpec.relationType = "undo-backup";
		childSpec.failurePrefix = "Undo failed: pre-undo backup";
		materializeCodexNativeChild(ws, tid, source, lastForkId, codex, owner,
			null, childSpec, (int childTid, string workspace, string projectPath) {
				host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
					workspace, projectPath, tid, "undo-backup"));
				host_.broadcastTaskUpdate(childTid);
				continueUndo();
			},
		);
	}

	static size_t findJsonObjectEnd(string input, size_t start)
	{
		assert(start < input.length && input[start] == '{');

		int depth = 0;
		bool inString = false;
		bool escaping = false;

		foreach (i, ch; input[start .. $])
		{
			if (inString)
			{
				if (escaping)
				{
					escaping = false;
					continue;
				}
				if (ch == '\\')
				{
					escaping = true;
					continue;
				}
				if (ch == '"')
					inString = false;
				continue;
			}

			switch (ch)
			{
				case '"':
					inString = true;
					break;
				case '{':
					depth++;
					break;
				case '}':
					depth--;
					if (depth == 0)
						return start + i + 1;
					break;
				default:
					break;
			}
		}

		throw new Exception("Invalid JSON in edited event");
	}

	static string[] compactRawEventObjectSequence(string input)
	{
		import std.ascii : isWhite;
		import std.json : JSONType, parseJSON;

		string[] compactLines;
		size_t pos = 0;
		while (true)
		{
			while (pos < input.length && input[pos].isWhite)
				pos++;
			if (pos >= input.length)
				return compactLines;
			if (input[pos] != '{')
				throw new Exception("Edited event must contain only JSON objects");

			auto end = findJsonObjectEnd(input, pos);
			try
			{
				auto parsed = parseJSON(input[pos .. end]);
				if (parsed.type != JSONType.object)
					throw new Exception("Edited event must contain only JSON objects");
				compactLines ~= parsed.toString();
			}
			catch (Exception e)
			{
				if (e.msg == "Edited event must contain only JSON objects")
					throw e;
				throw new Exception("Invalid JSON in edited event");
			}
			pos = end;
		}
	}

	unittest
	{
		import std.exception : assertThrown;
		import std.json : parseJSON;

		assert(compactRawEventObjectSequence(" \n\t ").length == 0);

		auto compact = compactRawEventObjectSequence(
			"{\n"
			~ "  \"message\": \"brace: } and quote: \\\\\\\"\",\n"
			~ "  \"nested\": {\"value\": 1}\n"
			~ "}\n"
			~ "{\"message\":\"two\"}{\"message\":\"three\"}");
		assert(compact.length == 3);
		assert(parseJSON(compact[0])["message"].str == `brace: } and quote: \"`);
		assert(parseJSON(compact[1])["message"].str == "two");
		assert(parseJSON(compact[2])["message"].str == "three");

		assertThrown!Exception(compactRawEventObjectSequence("null"));
		assertThrown!Exception(compactRawEventObjectSequence("{\"message\":1} trailing"));
		assertThrown!Exception(compactRawEventObjectSequence("{\"message\":"));
	}

	void fallbackUndoKillAndTruncate(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism,
		HistoryAccess access, ProcessLaunch liveLaunch, bool backupMaterialized = false,
		string truncationAnchor = null)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;
		if (ta.driver == AgentDriver.codex && json.revert_conversation && !backupMaterialized)
		{
			import std.file : exists, readText;
			auto boundaries = exists(access.path)
				? ta.extractPersistedHistoryBoundaries(readText(access.path)) : null;
			string lastForkId;
			foreach_reverse (persisted; boundaries)
			{
				if (persisted.kind == PersistedHistoryBoundaryKind.agent_turn)
				{
					lastForkId = persisted.anchor;
					break;
				}
			}
			if (lastForkId.length > 0)
			{
				auto owner = cast(CodexSession) host_.sessionForTask(tid);
				assert(owner !is null);
				auto continueUndo = () {
					fallbackUndoKillAndTruncate(ws, tid, json, boundary, mechanism,
						access, liveLaunch, true, truncationAnchor);
				};
				auto failUndo = (string message) {
					ws.send(Data(toJson(ErrorMessage("error",
						"Undo failed: pre-undo backup: " ~ message, tid)).representation));
				};
				try
				{
					gateLiveUndoBackup((void delegate() onSuccess,
						void delegate(string) onFailure) {
					if (runLiveCodexUndoBackup_ !is null)
						runLiveCodexUndoBackup_(ws, tid, access, lastForkId, owner,
							onSuccess, onFailure);
					else
						beginLiveCodexJsonlUndoBackup(ws, tid, access, lastForkId, owner,
							onSuccess);
					}, continueUndo, failUndo);
				}
				catch (Exception e)
					failUndo(e.msg);
				return;
			}
		}

		auto jsonlPathSnap = access.path;
		auto jsonlSnap = host_.getUndoJsonl(tid);
		host_.clearUndoJsonl(tid);
		auto transaction = new FallbackUndoTransaction(() {
			finalizeFallbackUndo(tid, access);
		});
		void delegate(string) failUndo = (string message) {
			if (transaction.finalize())
				ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
		};

		bool snapshotContainsUndoAnchor(string snapshot, string forkId)
		{
			import std.string : lineSplitter;

			if (snapshot.length == 0 || forkId.length == 0)
				return false;

			int lnum = 0;
			foreach (rawLine; snapshot.lineSplitter)
			{
				lnum++;
				if (rawLine.length == 0)
					continue;
				if (ta.forkIdMatchesLine(rawLine, lnum, forkId))
					return true;
			}
			return false;
		}

		td.undoStopInProgress = true;
		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		host_.invalidateJsonlLineage(tid);
		host_.unsubscribeTaskHistorySubscribers(tid);
		try
		{
			td.processQueue.setGoal(ProcessState.Dead).then(() {
			try
			{
				if (jsonlSnap.length > 0 && jsonlPathSnap.length > 0 &&
					snapshotContainsUndoAnchor(jsonlSnap, boundary.anchor))
				{
					import std.file : write;

					write(jsonlPathSnap, jsonlSnap);
				}
				if (ta.driver == AgentDriver.codex)
				{
					performUndoExecution(ws, tid, json, boundary, mechanism, access,
						liveLaunch, UndoBackupDisposition.alreadyMaterialized, (string message) {
						failUndo(message);
					}, () { transaction.finalize(); }, truncationAnchor);
				}
				else
					performUndoExecution(ws, tid, json, boundary, mechanism, access,
						liveLaunch, UndoBackupDisposition.generic, failUndo,
						() { transaction.finalize(); });
			}
			catch (Exception e)
			{
				failUndo(e.msg);
			}
		}, (Exception e) {
			failUndo(e.msg);
		}).ignoreResult();
			host_.stopTask(tid);
		}
		catch (Exception e)
			failUndo(e.msg);
	}

	void finalizeFallbackUndo(int tid, HistoryAccess access)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		td.undoStopInProgress = false;
		td.history.reset(watermarkFromPath(access.path));
		host_.emitTaskReload(tid, "");
	}

	enum UndoBackupDisposition { generic, deadCodexNative, alreadyMaterialized }

	void performUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism,
		HistoryAccess access, ProcessLaunch capturedLiveLaunch,
		UndoBackupDisposition backupDisposition,
		void delegate(string) onFailure = null, void delegate() onSuccess = null,
		string truncationAnchor = null)
	{
		import std.algorithm : canFind, startsWith;

		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;

		auto ta = access.agent;
		assert(mechanism == HistoryOperationMechanism.jsonl,
			"JSONL undo execution requires the JSONL mechanism");
		auto rewindLaunch = capturedLiveLaunch;
		bool ownsFreshLaunch;
		if (json.revert_files && rewindLaunch.nativeHistoryProfile.root.length == 0)
		{
			auto typeDef = host_.taskTypeForProject(td.projectPath, td.taskType);
			auto fresh = host_.prepareTaskSessionLaunch(tid, ta, typeDef);
			rewindLaunch = fresh.processLaunch;
			td.launch = ProcessLaunch.init;
			ownsFreshLaunch = true;
		}
		scope(exit)
			if (ownsFreshLaunch)
				cleanup(rewindLaunch.sandbox);

		string rewindOutput;
		if (json.revert_files)
		{
			auto rewindResult = ta.rewindFiles(access.sessionId,
				boundary.checkpoint_uuid, rewindLaunch);
			if (rewindResult.success)
				rewindOutput = rewindResult.output;
			else if (!rewindResult.output.canFind("No file checkpoint found"))
			{
				if (onFailure !is null)
					onFailure("File revert failed: " ~ rewindResult.output);
				else
					ws.send(Data(toJson(ErrorMessage("error", "File revert failed: " ~ rewindResult.output, tid)).representation));
				return;
			}
		}

		if (json.revert_conversation)
		{
			import std.datetime : Clock;

			auto historyPath = access.path;
			auto boundaries = exists(historyPath)
				? ta.extractPersistedHistoryBoundaries(readText(historyPath)) : null;
			auto lastForkId = boundaries.length > 0 ? boundaries[$ - 1].anchor : null;
			if (lastForkId.length > 0)
			{
				if (backupDisposition == UndoBackupDisposition.deadCodexNative)
				{
					beginCodexJsonlUndoBackup(ws, tid, access, lastForkId, () {
						finishUndoExecution(ws, tid, json, boundary, access,
							rewindOutput, onFailure, null, truncationAnchor);
					});
					return;
				}
				else if (backupDisposition == UndoBackupDisposition.generic)
				{
				auto destination = host_.prepareHistoryForkDestination(tid);
				auto backup = forkTask(*host_.persistence(), tid, access,
					lastForkId, td.projectPath, td.workspace, td.title, destination,
					&ta.rewriteSessionId, &ta.forkIdMatchesLine,
					td.description, td.taskType, td.agentName);
				if (backup.tid >= 0)
				{
					if (td.worktreeTid > 0)
						host_.persistence().setWorktreeTid(backup.tid, td.worktreeTid);
					auto bTd = TaskData(backup.tid, td.workspace, td.projectPath);
					bTd.title = td.title.length > 0 ? td.title ~ " (pre-undo)" : "(pre-undo)";
					bTd.agentSessionId = backup.agentSessionId;
					bTd.parentTid = tid;
					bTd.relationType = "undo-backup";
					bTd.status = TaskStatus.completed;
					bTd.agentName = td.agentName;
					bTd.description = td.description;
					bTd.taskType = td.taskType;
					bTd.worktreeTid = td.worktreeTid;
					bTd.createdAt = Clock.currStdTime;
					bTd.lastActive = bTd.createdAt;
					host_.setRelationType(backup.tid, "undo-backup");
					host_.setTitle(backup.tid, bTd.title);
					host_.putTask(backup.tid, move(bTd));
					auto backupTd = host_.getTask(backup.tid);
					assert(backupTd !is null,
						"Undo backup task must exist after insertion");
					backupTd.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(backup.tid),
						ProcessState.Dead,
					);
					backupTd.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(backup.tid),
						ArchiveState.Unarchived,
					);
					backupTd.history.reset(watermarkFromPath(backup.destinationPath));
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
						backup.tid, td.workspace, td.projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(backup.tid);
				}
				}
			}
		}

		finishUndoExecution(ws, tid, json, boundary, access, rewindOutput, onFailure,
			onSuccess, truncationAnchor);
	}

	void finishUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryAccess access, string rewindOutput,
		void delegate(string) onFailure = null, void delegate() onSuccess = null,
		string truncationAnchor = null)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;

		if (json.revert_conversation)
		{
			auto histJsonlPath = access.path;
			if (truncationAnchor.length == 0)
				truncationAnchor = boundary.anchor;
			auto removed = truncateJsonl(histJsonlPath, truncationAnchor,
				&ta.forkIdMatchesLine, true);
			if (removed < 0)
			{
				if (onFailure !is null)
					onFailure("UUID not found for truncation");
				else
					ws.send(Data(toJson(ErrorMessage("error",
						"UUID not found for truncation", tid)).representation));
				return;
			}
			if (td.pendingSteeringTexts.length > 0)
			{
				import std.file : exists, readText;
				import std.string : splitLines;

				auto histPath = access.path;
				if (histPath.exists)
				{
					int remaining = 0;
					foreach (line; readText(histPath).splitLines())
						if (ta.isUserMessageLine(line))
							remaining++;
					if (remaining < cast(int) td.pendingSteeringTexts.length)
						td.pendingSteeringTexts = td.pendingSteeringTexts[0 .. remaining].dup;
				}
			}
		}

		if (onSuccess !is null)
			onSuccess();
		else if (json.revert_conversation)
		{
			host_.invalidateJsonlLineage(tid);
			td.history.reset(watermarkFromPath(access.path));
			host_.unsubscribeTaskHistorySubscribers(tid);
		}

		ws.send(Data(toJson(UndoResultMessage("undo_result", tid, rewindOutput)).representation));
		if (onFailure is null)
			host_.emitTaskReload(tid, "");

		if (json.revert_conversation && td.agentSessionId.length > 0)
		{
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				auto current = host_.getTask(tid);
				assert(current !is null,
					"Undo task must exist while auto-resume is scheduled");
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.alive, TaskStatus.waiting,
						TaskStatus.completed, TaskStatus.failed], TaskStatus.active,
					TaskNotificationChange.preserve);
				try
					host_.generateSuggestions(tid);
				catch (Exception e)
					warningf("Error generating suggestions: %s", e.msg);
			}).ignoreResult();
		}

		host_.broadcastTaskUpdate(tid);
	}
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : NativeHistoryProfile;
	import std.file : remove, write;

	enum tid = 71;
	auto task = TaskData(tid, "local", "/tmp");
	task.agentName = "claude";
	task.agentSessionId = "session";
	Agent agent = new ClaudeCodeAgent();
	auto historyPath = "/tmp/cydo-mutations-undo-resolution.jsonl";
	write(historyPath, "");
	scope(exit) remove(historyPath);
	int replies;
	int sideEffects;
	enum Resolution { forged, stale, noCheckpoint }
	Resolution resolution;

	TaskMutationServiceHost host;
	host.getTask = (int value) => value == tid ? &task : null;
	host.agentForTask = (int) => agent;
	host.sessionForTask = (int) => null;
	host.taskAlive = (int) => false;
	host.codexForkSourceState = (int) => CodexForkSourceState.dead;
	host.stopTask = (int) { sideEffects++; assert(false); };
	host.resolveTaskHistory = (int) => TaskHistoryResolution.access(HistoryAccess(
		agent, NativeHistoryProfile(agent.driver, "/tmp"), task.agentSessionId,
		historyPath));
	host.clearUndoJsonl = (int) { sideEffects++; assert(false); };
	host.invalidateJsonlLineage = (int) { sideEffects++; assert(false); };
	host.startJsonlWatch = (int) { sideEffects++; assert(false); };
	host.unsubscribeTaskHistorySubscribers = (int) { sideEffects++; assert(false); };
	host.emitTaskReload = (int, string) { sideEffects++; assert(false); };
	host.broadcastTaskUpdate = (int) { sideEffects++; assert(false); };
	host.transitionTaskFrom = (int, TaskStatus[], TaskStatus, TaskNotificationChange) {
		sideEffects++; assert(false);
	};
	host.generateSuggestions = (int) { sideEffects++; assert(false); };
	host.resolveFreshPersistedBoundary = (int, const ref HistoryAccess access,
		string, out HistoryBoundary boundary) {
		if (resolution != Resolution.noCheckpoint)
			return false;
		boundary = HistoryBoundary("assistant", HistoryBoundaryKind.agent_turn, "");
		return true;
	};

	auto service = new TaskMutationService(host);
	void delegate(Data) reply = (Data) { replies++; };

	foreach (dryRun; [true, false])
	{
		resolution = Resolution.forged;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "line:999999", dry_run: dryRun,
			revert_conversation: true));
	}
	assert(replies == 2);
	assert(sideEffects == 0);

	// A syntactically plausible line anchor which was invalidated by rollback is
	// rejected by fresh resolution before either preview or execution can mutate.
	foreach (dryRun; [true, false])
	{
		resolution = Resolution.stale;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "line:4", dry_run: dryRun, revert_conversation: true));
	}
	assert(replies == 4);
	assert(sideEffects == 0);

	// A resolved assistant boundary is valid for conversation undo but never for
	// file rewind; both preview and confirmation reject the forged file request.
	foreach (dryRun; [true, false])
	{
		resolution = Resolution.noCheckpoint;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "assistant", dry_run: dryRun, revert_conversation: true,
			revert_files: true));
	}
	assert(replies == 6);
	assert(sideEffects == 0);
}

unittest
{
	import ae.net.asockets : socketManager;
	import cydo.agent.drivers.codex : AppServerProcess;
	import cydo.agent.contract : SessionConfig;
	import cydo.runtime.launch.types : NativeHistoryProfile;
	import std.algorithm : canFind, min;
	import std.conv : to;
	import std.file : exists, remove, write;

	enum tid = 72;

	NativeUndoPlan plan(uint numTurns)
	{
		NativeUndoPlan result;
		result.numTurns = numTurns;
		return result;
	}

	class StubCodexSession : CodexSession
	{
		NativeUndoPlan[] preparedPlans;
		NativeUndoExecutionResult execution;
		bool rejectPreparation;
		bool invokePointOfNoReturn;
		bool rollbackAvailable = true;
		uint prepareCalls;
		uint executeCalls;

		this()
		{
			super(cast(AppServerProcess) null, tid, SessionConfig.init);
		}

		override @property bool canRollbackThread() const
		{
			return rollbackAvailable;
		}

		override Promise!NativeUndoPlan prepareNativeUndo(HistoryBoundary)
		{
			prepareCalls++;
			auto result = new Promise!NativeUndoPlan;
			if (rejectPreparation)
			{
				result.reject(new Exception("native ledger read refused"));
				return result;
			}
			assert(preparedPlans.length > 0, "native test needs a prepared plan");
			result.fulfill(preparedPlans[min(cast(size_t) prepareCalls - 1,
				preparedPlans.length - 1)]);
			return result;
		}

		override Promise!NativeUndoExecutionResult executeNativeUndo(NativeUndoPlan,
			void delegate() pointOfNoReturn)
		{
			executeCalls++;
			if (invokePointOfNoReturn)
				pointOfNoReturn();
			auto result = new Promise!NativeUndoExecutionResult;
			result.fulfill(execution);
			return result;
		}
	}

	auto task = TaskData(tid, "local", "/tmp");
	task.agentName = "codex";
	task.agentSessionId = "native-session";
	auto session = new StubCodexSession;
	auto agent = new CodexAgent;
	Agent taskAgent = agent;
	AgentSession taskSession = session;
	bool taskIsAlive = true;
	string[] replies;
	int lineageCalls;
	int clearCalls;
	int unsubscribeCalls;
	int reloadCalls;
	int watchCalls;
	int updateCalls;
	int backupCalls;
	int stopCalls;
	int liveLaunchCalls;
	int boundaryCalls;
	int historyAccessCalls;
	bool fallbackAnchorMatrix;
	CodexForkSourceState selectedSourceState;
	enum rolloutPath = "/tmp/cydo-native-undo-unittest.jsonl";
	if (exists(rolloutPath))
		remove(rolloutPath);
	write(rolloutPath, "");
	scope(exit) if (exists(rolloutPath)) remove(rolloutPath);

	TaskMutationServiceHost host;
	host.getTask = (int value) => value == tid ? &task : null;
	host.agentForTask = (int) => taskAgent;
	host.sessionForTask = (int) => taskIsAlive ? taskSession : null;
	host.taskAlive = (int) => taskIsAlive;
	host.resolveTaskHistory = (int) {
		historyAccessCalls++;
		return TaskHistoryResolution.access(HistoryAccess(
			taskAgent, NativeHistoryProfile(taskAgent.driver, "/tmp"), task.agentSessionId,
			rolloutPath));
	};
	host.codexForkSourceState = (int) {
		selectedSourceState = !taskIsAlive ? CodexForkSourceState.dead
			: session.rollbackAvailable ? CodexForkSourceState.liveReady
			: CodexForkSourceState.liveBusy;
		return selectedSourceState;
	};
	host.resolveFreshPersistedBoundary = (int, const ref HistoryAccess,
		string, out HistoryBoundary boundary) {
		boundaryCalls++;
		boundary = fallbackAnchorMatrix
			? HistoryBoundary("line:3", HistoryBoundaryKind.agent_turn, null)
			: HistoryBoundary("line:2", HistoryBoundaryKind.user, null);
		return true;
	};
	host.requireLiveHistoryLaunch = (int, const ref HistoryAccess) {
		liveLaunchCalls++;
		return ProcessLaunch.init;
	};
	host.invalidateJsonlLineage = (int) { lineageCalls++; };
	host.clearUndoJsonl = (int) { clearCalls++; };
	host.unsubscribeTaskHistorySubscribers = (int) { unsubscribeCalls++; };
	host.emitTaskReload = (int, string) { reloadCalls++; };
	host.startJsonlWatch = (int) { watchCalls++; };
	host.broadcastTaskUpdate = (int) { updateCalls++; };
	host.stopTask = (int) { stopCalls++; };
	host.getUndoJsonl = (int) { assert(false); return null; };

	auto service = new TaskMutationService(host,
		(MutationReplySocket, int, HistoryAccess, string, CodexSession,
			void delegate(), void delegate(string)) { backupCalls++; });
	void delegate(Data) reply = (Data data) {
		replies ~= cast(string) data.toGC();
	};
	WsMessage previewRequest() => WsMessage(type: "undo_task", tid: tid,
		after_uuid: "line:2", dry_run: true, revert_conversation: true);
	WsMessage nativeConfirmation(uint expected) => jsonParse!WsMessage(
		`{"type":"undo_task","tid":72,"after_uuid":"line:2","expected_num_turns":`
		~ expected.to!string ~ `}`);
	void resetEffects()
	{
		replies = null;
		lineageCalls = clearCalls = unsubscribeCalls = reloadCalls = watchCalls = updateCalls = 0;
		backupCalls = stopCalls = liveLaunchCalls = 0;
		boundaryCalls = 0;
		historyAccessCalls = 0;
		fallbackAnchorMatrix = false;
		selectedSourceState = CodexForkSourceState.dead;
		session.prepareCalls = session.executeCalls = 0;
		session.rejectPreparation = false;
		session.invokePointOfNoReturn = false;
		session.rollbackAvailable = true;
		taskIsAlive = true;
		task.codexNativeUndoState = CodexNativeUndoState.idle;
	}

	// Native preview reports the fresh ledger count and preserves no plan.
	resetEffects();
	session.preparedPlans = [plan(2)];
	service.handleUndoTaskMsg(reply, previewRequest());
	socketManager.loop();
	assert(session.prepareCalls == 1 && session.executeCalls == 0
		&& replies.length == 1 && replies[0].canFind(`"messages_removed":2`)
		&& replies[0].canFind(`"count_unit":"codex_turns"`)
		&& task.codexNativeUndoState == CodexNativeUndoState.idle);

	// A rejected native preview remains a no-dispatch refusal and cannot fall
	// through to either JSONL counting or fallback execution.
	resetEffects();
	session.rejectPreparation = true;
	service.handleUndoTaskMsg(reply, previewRequest());
	socketManager.loop();
	assert(session.prepareCalls == 1 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind("preparation refused"));

	// Confirmation obtains a fresh plan, and count drift refuses before lineage
	// invalidation or a provider call.
	resetEffects();
	session.preparedPlans = [plan(2), plan(3)];
	service.handleUndoTaskMsg(reply, previewRequest());
	socketManager.loop();
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	socketManager.loop();
	assert(session.prepareCalls == 2 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies[$ - 1].canFind("count changed"));

	// A native confirmation without an echoed count does not prepare or mutate.
	resetEffects();
	service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
		after_uuid: "line:2"));
	assert(session.prepareCalls == 0 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind("stale"));

	// A zero native echo is present on the wire but is equally stale.
	resetEffects();
	service.handleUndoTaskMsg(reply, nativeConfirmation(0));
	assert(session.prepareCalls == 0 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind("stale"));

	// A second confirmation is rejected at the state gate before it resolves a
	// boundary or starts another native preparation.
	resetEffects();
	task.beginConfirmedNativeUndo();
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	assert(historyAccessCalls == 0 && boundaryCalls == 0 && session.prepareCalls == 0
		&& session.executeCalls == 0 && lineageCalls == 0 && clearCalls == 0
		&& unsubscribeCalls == 0 && reloadCalls == 0 && watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.inFlight
		&& replies.length == 1 && replies[0].canFind("already in progress"));
	task.clearNativeUndoRefusalBeforeDispatch();

	// Neither a new preview nor another confirmation can restart native work
	// while the task is in flight or fail-stopped as unverified.
	resetEffects();
	task.beginConfirmedNativeUndo();
	service.handleUndoTaskMsg(reply, previewRequest());
	assert(session.prepareCalls == 0 && session.executeCalls == 0 && lineageCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.inFlight
		&& replies.length == 1 && replies[0].canFind("in progress"));
	task.markCodexNativeUndoUnverified();
	service.handleUndoTaskMsg(reply, previewRequest());
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	assert(session.prepareCalls == 0 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.unverified
		&& replies.length == 3
		&& replies[1].canFind("may already have changed or lost history")
		&& replies[2].canFind("may already have changed or lost history"));

	// Preparation errors are ordinary no-dispatch refusals and never select the
	// JSONL fallback.
	resetEffects();
	session.rejectPreparation = true;
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	socketManager.loop();
	assert(session.prepareCalls == 1 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind("preparation refused"));

	// A driver pre-dispatch refusal clears the in-flight state without invoking
	// the lineage point of no return.
	resetEffects();
	session.preparedPlans = [plan(2)];
	session.execution = NativeUndoExecutionResult(
		NativeUndoExecutionStatus.refusedBeforeDispatch, "plan changed");
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	socketManager.loop();
	assert(session.prepareCalls == 1 && session.executeCalls == 1 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind("before dispatch")
		&& !replies[0].canFind(`"type":"undo_result"`));

	// Verified execution runs the existing cleanup exactly once before emitting
	// the empty-output success result and returning to idle.
	resetEffects();
	session.preparedPlans = [plan(2)];
	session.execution = NativeUndoExecutionResult(NativeUndoExecutionStatus.verified, "");
	session.invokePointOfNoReturn = true;
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	socketManager.loop();
	assert(session.executeCalls == 1 && lineageCalls == 1 && clearCalls == 1
		&& unsubscribeCalls == 1 && reloadCalls == 1 && watchCalls == 1 && updateCalls == 1
		&& task.codexNativeUndoState == CodexNativeUndoState.idle
		&& replies.length == 1 && replies[0].canFind(`"type":"undo_result"`)
		&& replies[0].canFind(`"output":""`));

	// Any result that becomes uncertain after the point of no return leaves the
	// task fail-stopped and suppresses all verified-success cleanup.
	resetEffects();
	session.preparedPlans = [plan(2)];
	session.execution = NativeUndoExecutionResult(
		NativeUndoExecutionStatus.unverifiableAfterDispatch, "marker missing");
	session.invokePointOfNoReturn = true;
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	socketManager.loop();
	assert(session.executeCalls == 1 && lineageCalls == 1 && clearCalls == 0
		&& unsubscribeCalls == 0 && reloadCalls == 0 && watchCalls == 0 && updateCalls == 0
		&& task.codexNativeUndoState == CodexNativeUndoState.unverified
		&& replies.length == 1 && replies[0].canFind("may already have changed or lost history")
		&& !replies[0].canFind(`"type":"undo_result"`));

	// A native-preview confirmation cannot silently fall through to the JSONL
	// path after capability drift.
	resetEffects();
	session.rollbackAvailable = false;
	service.handleUndoTaskMsg(reply, nativeConfirmation(2));
	assert(session.prepareCalls == 0 && session.executeCalls == 0 && lineageCalls == 0
		&& clearCalls == 0 && unsubscribeCalls == 0 && reloadCalls == 0
		&& watchCalls == 0 && updateCalls == 0
		&& replies.length == 1 && replies[0].canFind("preview is stale"));

	// A live but busy Codex session retains the JSONL preview policy and never
	// calls the native ledger API.
	resetEffects();
	write(rolloutPath,
		`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`);
	session.rollbackAvailable = false;
	service.handleUndoTaskMsg(reply, previewRequest());
	assert(selectedSourceState == CodexForkSourceState.liveBusy
		&& session.prepareCalls == 0 && session.executeCalls == 0 && replies.length == 1
		&& replies[0].canFind(`"messages_removed":2`)
		&& replies[0].canFind(`"count_unit":"history_entries"`));

	struct FallbackAnchorFailureCase
	{
		string name;
		string rollout;
	}
	foreach (failureCase; [
		FallbackAnchorFailureCase("missing", `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"selected"}]}}`),
		FallbackAnchorFailureCase("malformed", `{"type":"event_msg","payload":{"type":"agent_message","message":[]}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"selected"}]}}`),
		FallbackAnchorFailureCase("ambiguous", `{"type":"event_msg","payload":{"type":"agent_message","message":"selected","phase":null,"memory_citation":null}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"agent_message","message":"selected","phase":null,"memory_citation":null}}` ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"selected"}]}}`),
	])
	{
		resetEffects();
		fallbackAnchorMatrix = true;
		session.rollbackAvailable = false;
		write(rolloutPath, failureCase.rollout);
		auto before = readText(rolloutPath);
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "line:3", dry_run: false, revert_conversation: true));
		assert(selectedSourceState == CodexForkSourceState.liveBusy
			&& liveLaunchCalls == 0 && backupCalls == 0 && stopCalls == 0
			&& lineageCalls == 0 && clearCalls == 0 && unsubscribeCalls == 0
			&& reloadCalls == 0 && watchCalls == 0 && updateCalls == 0
			&& session.prepareCalls == 0 && session.executeCalls == 0
			&& taskIsAlive && !task.undoStopInProgress
			&& replies.length == 1 && replies[0].canFind("UUID not found for truncation")
			&& readText(rolloutPath) == before, failureCase.name);
	}

	// Once stopped, a fresh JSONL preview uses the dead-source policy and never
	// carries the native ledger count unit.
	resetEffects();
	write(rolloutPath,
		`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`);
	taskIsAlive = false;
	service.handleUndoTaskMsg(reply, previewRequest());
	assert(selectedSourceState == CodexForkSourceState.dead
		&& session.prepareCalls == 0 && session.executeCalls == 0 && replies.length == 1
		&& replies[0].canFind(`"messages_removed":2`)
		&& replies[0].canFind(`"count_unit":"history_entries"`));

}
