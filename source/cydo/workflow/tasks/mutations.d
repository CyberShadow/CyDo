module cydo.workflow.tasks.mutations;

import core.lifetime : move;

import std.exception : enforce;
import std.file : exists, readText;
import std.logger : warningf;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.json : JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise;
import ae.utils.statequeue : StateQueue;

import cydo.agent.contract : Agent, PersistedHistoryBoundary, PersistedHistoryBoundaryKind,
	SessionConfig;
import cydo.agent.drivers.claude : ClaudeCodeSession;
import cydo.agent.drivers.codex : CodexAgent, CodexSession, ThreadForkOutcome;
import cydo.agent.session : AgentSession;
import cydo.domain.storage.persistence : Persistence, createForkTask;
import cydo.domain.task_types.definition : TaskTypeDef;
import cydo.domain.tasks.model : ArchiveState, HistoryStore, NativeUndoState, ErrorMessage,
	extractEventFromEnvelope,
	ProcessState, TaskCreatedMessage, TaskData, TaskStatus, UndoPreviewMessage,
	UndoResultMessage, Watermark, WsMessage, watermarkFromPath;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind, ContentBlock, extractContentText;
import cydo.workflow.history.jsonl_edit : replaceUserMessageContent;
import cydo.workflow.history.operations : NativeSessionState, HistoryOperation,
	HistoryBoundaryEvent, HistoryOperationMechanism, allowsFileRevert, allowsOperation, operationMechanism,
	selectHistoryOperations;
import cydo.workflow.history.jsonl_store : countLinesAfterForkId,
	editJsonlMessage, forkTask, HistoryForkDestination, spliceJsonlByLine,
	truncateJsonl;
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

	Agent delegate(int tid) agentForTask;
	AgentSession delegate(int tid) sessionForTask;
	bool delegate(int tid) taskAlive;
	void delegate(int tid) stopTask;

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
	void delegate(int tid, void delegate() ready) whenHistoryLoaded;
	ubyte delegate(int tid) servedHistoryMode;
	TaskHistoryResolution delegate(int tid) resolveTaskHistory;
	void delegate(int tid, const ref TaskHistoryResolution resolution)
		reportUnavailableHistory;
	ProcessLaunch delegate(int tid, const ref HistoryAccess access)
		requireLiveHistoryLaunch;
	CodexForkSourceOperation delegate(int tid, const ref HistoryAccess access)
		openCodexForkSourceOperation;
	NativeSessionState delegate(int tid) nativeSessionState;
	bool delegate(int tid, const ref HistoryAccess access,
		string requestedAnchor, out HistoryBoundary boundary, out bool opensConversation)
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
}

class TaskMutationService
{
private:
	TaskMutationServiceHost host_;

public:
	this(TaskMutationServiceHost host)
	{
		host_ = host;
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
		if (source.isDriverServed)
		{
			forkCodexTask(ws, tid, json.anchor, source);
			return;
		}
		HistoryBoundary boundary;
		bool opensConversation;
		if (!host_.resolveFreshPersistedBoundary(tid, source, json.anchor, boundary,
			opensConversation))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto operations = selectHistoryOperations(ta.driver,
			host_.nativeSessionState(tid), 0);
		if (!allowsOperation(boundary, opensConversation, operations, HistoryOperation.fork))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		assert(operationMechanism(boundary, opensConversation, operations,
			HistoryOperation.fork) == HistoryOperationMechanism.jsonl,
			"A file-backed history forks by its file");

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
		if (!json.dry_run && (td.nativeUndoState == NativeUndoState.backingUp
			|| td.nativeUndoState == NativeUndoState.inFlight))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Native undo is already in progress", tid)).representation));
			return;
		}

		HistoryAccess access;
		if (!requireHistoryAccess(ws, tid, "UUID not found in task history", access))
			return;
		auto ta = access.agent;
		if (access.isDriverServed)
		{
			undoCodexTask(ws, tid, json, access);
			return;
		}
		HistoryBoundary boundary;
		bool opensConversation;
		if (!host_.resolveFreshPersistedBoundary(tid, access, json.anchor, boundary,
			opensConversation))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto nativeSourceState = host_.nativeSessionState(tid);
		auto operations = selectHistoryOperations(ta.driver, nativeSourceState, 0);
		if (!allowsOperation(boundary, opensConversation, operations, HistoryOperation.undo))
		{
			ws.send(Data(toJson(ErrorMessage("error", opensConversation
				? "Undoing the first message needs its agent session running and idle"
				: "UUID not found in task history", tid)).representation));
			return;
		}
		auto mechanism = operationMechanism(boundary, opensConversation, operations,
			HistoryOperation.undo);
		if (json.revert_files && !allowsFileRevert(boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "File revert is unavailable for this history boundary", tid)).representation));
			return;
		}
		if (json.dry_run)
		{
			auto count = countLinesAfterForkId(
				access.path,
				boundary.anchor,
				&ta.forkIdMatchesLine,
				&ta.isForkableLine,
				ta.inactiveHistoryLines(readText(access.path)));
			if (count < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
				return;
			}
			ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
				count + 1, "history_entries")).representation));
			return;
		}

		if (mechanism == HistoryOperationMechanism.claude_native)
		{
			if (td.nativeUndoState == NativeUndoState.unverified)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Claude may already have changed history; native undo is blocked in this running CyDo process",
					tid)).representation));
				return;
			}
			auto claudeSession = cast(ClaudeCodeSession) host_.sessionForTask(tid);
			assert(claudeSession !is null,
				"Claude-native undo policy requires a live Claude session");
			executeClaudeNativeUndo(ws, tid, json, boundary, access, claudeSession);
			return;
		}

		if (host_.taskAlive(tid))
		{
			auto liveLaunch = host_.requireLiveHistoryLaunch(tid, access);
			fallbackUndoKillAndTruncate(ws, tid, json, boundary, mechanism, access,
				liveLaunch);
			return;
		}

		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		performUndoExecution(ws, tid, json, boundary, mechanism, access,
			ProcessLaunch.init);
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
		if (access.isDriverServed)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Editing messages is not supported for this agent", tid)).representation));
			return;
		}
		auto ta = access.agent;
		auto jsonlPath = access.path;
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		auto targetUuid = json.anchor;
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
			&ta.historyRecordIdMatchesLine,
			(string line) => replaceUserMessageContent(line, newContent));
		if (!edited && fallbackUuid.length > 0)
		{
			edited = editJsonlMessage(jsonlPath, fallbackUuid,
				&ta.historyRecordIdMatchesLine,
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

		HistoryAccess access;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Raw event not found in JSONL file", access))
			return;
		if (access.isDriverServed)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Editing events is not supported for this agent", tid)).representation));
			return;
		}
		host_.ensureHistoryLoaded(tid);
		if (seq >= td.history.length || td.history.rawAt(seq) is null)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Seq out of range or no raw source", tid)).representation));
			return;
		}

		auto sourceLine = td.history.sourceLineAt(seq);
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
		string draft;
	}

	private alias CodexNativeChildMaterialized =
		void delegate(int childTid, string workspace, string projectPath);

	void beginCodexNativeFork(WebSocketAdapter ws, int tid, HistoryAccess source,
		HistoryBoundary boundary, string prompt, CodexAgent ca, CodexSession forkOwner,
		CodexForkSourceOperation operation)
	{
		CodexNativeChildSpec childSpec;
		childSpec.titleSuffix = " (fork)";
		childSpec.emptyTitle = "(fork)";
		childSpec.relationType = "fork";
		childSpec.failurePrefix = "Fork failed";
		childSpec.draft = prompt;
		materializeCodexNativeChild(
			MutationReplySocket((Data data) => ws.send(data)), tid, source,
			codexTurnId(boundary), boundary.kind, ca, forkOwner, operation, childSpec,
			(int childTid, string workspace, string projectPath) {
				host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
					workspace, projectPath, tid, "fork"));
				host_.broadcastTaskUpdate(childTid);
				host_.broadcastFocusHint(tid, childTid);
			},
		);
	}

	void materializeCodexNativeChild(MutationReplySocket ws, int tid,
		HistoryAccess source, string turnId, HistoryBoundaryKind boundaryKind, CodexAgent ca,
		CodexSession forkOwner, CodexForkSourceOperation operation,
		CodexNativeChildSpec childSpec,
		CodexNativeChildMaterialized onMaterialized, void delegate() onFailure = null)
	{
		import std.datetime : Clock;

		auto td = host_.getTask(tid);
		if (td is null)
		{
			if (operation !is null)
				operation.closeStdin();
			return;
		}
		assert(forkOwner !is null,
			"Codex-native fork requires its exact live source owner");
		enforce(childSpec.titleSuffix.length > 0 && childSpec.emptyTitle.length > 0
			&& childSpec.relationType.length > 0 && childSpec.failurePrefix.length > 0,
			"Codex-native child requires complete durable child metadata");
		enforce(onMaterialized !is null,
			"Codex-native child requires a completion continuation");

		auto sourceWorkspace = td.workspace.idup;
		auto sourceProjectPath = td.projectPath.idup;
		auto sourceTitle = td.title.idup;
		auto sourceDescription = td.description.idup;
		auto sourceTaskType = td.taskType.idup;
		auto sourceAgentName = td.agentName.idup;
		auto sourceWorktreeTid = td.worktreeTid;
		int childTid = -1;
		ProcessLaunch childLaunch;
		bool ownsChildLaunch;
		bool settled;

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
			if (childTid >= 0)
			{
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
			if (onFailure)
				onFailure();
			ws.send(Data(toJson(ErrorMessage("error", childSpec.failurePrefix ~ ": " ~ message,
				tid)).representation));
		}

		try
		{
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
			newTd.draft = childSpec.draft;
			if (newTd.draft.length > 0)
				host_.persistence().setDraft(childTid, newTd.draft);
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
				turnId, boundaryKind, childLaunch, launch.sessionConfig);
			fork.then((ThreadForkOutcome outcome) {
				if (settled)
					return;
				if (!outcome.ok)
				{
					fail(outcome.error);
					return;
				}

				try
				{
					auto currentChild = host_.getTask(childTid);
					assert(currentChild !is null,
						"Fork child task must exist until fork completion");
					currentChild.agentSessionId = outcome.threadId;
					host_.setAgentSessionId(childTid, outcome.threadId);
					currentChild.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(childTid), ProcessState.Dead);
					currentChild.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(childTid), ArchiveState.Unarchived);
					// The child's history is Codex's to serve, like its parent's.
					currentChild.history.reset(Watermark.driverServed());

					cleanupChildLaunch();
					if (operation !is null)
						operation.closeStdin();
					settled = true;
					onMaterialized(childTid, sourceWorkspace, sourceProjectPath);
				}
				catch (Exception e)
				{
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

	/// The pre-undo copy of a Codex thread: a fork of all of it, an unfinished
	/// turn included. `owner` is the thread's live session; a stopped thread
	/// is resumed into an operation of its own for the fork.
	void backUpCodexThread(MutationReplySocket ws, int tid, HistoryAccess source,
		CodexSession owner, void delegate() continueUndo, void delegate() onFailure)
	{
		auto codex = cast(CodexAgent) source.agent;
		assert(codex !is null, "Only a Codex thread has a Codex backup");
		CodexNativeChildSpec childSpec;
		childSpec.titleSuffix = " (pre-undo)";
		childSpec.emptyTitle = "(pre-undo)";
		childSpec.relationType = "undo-backup";
		childSpec.failurePrefix = "Undo failed: pre-undo backup";
		void materialize(CodexSession forkOwner, CodexForkSourceOperation operation)
		{
			materializeCodexNativeChild(ws, tid, source, null, HistoryBoundaryKind.agent_turn,
				codex, forkOwner, operation, childSpec,
				(int childTid, string workspace, string projectPath) {
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
						workspace, projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(childTid);
					continueUndo();
				}, onFailure);
		}
		if (owner !is null)
		{
			materialize(owner, null);
			return;
		}
		withCodexOperation(ws, tid, source, childSpec.failurePrefix,
			(CodexSession operationOwner, CodexForkSourceOperation operation) {
				materialize(operationOwner, operation);
			}, onFailure);
	}

	/// Resume a stopped Codex thread into an operation of its own and hand
	/// it over once its route is ready. The receiver closes the operation.
	void withCodexOperation(MutationReplySocket ws, int tid, HistoryAccess source,
		string failurePrefix,
		void delegate(CodexSession owner, CodexForkSourceOperation operation) run,
		void delegate() onFailure = null)
	{
		void fail(string message)
		{
			if (onFailure)
				onFailure();
			ws.send(Data(toJson(ErrorMessage("error",
				failurePrefix ~ ": " ~ message, tid)).representation));
		}
		CodexForkSourceOperation operation;
		try
			operation = host_.openCodexForkSourceOperation(tid, source);
		catch (Exception e)
		{
			fail(e.msg);
			return;
		}
		operation.routeReady.then((CodexSession owner) {
			run(owner, operation);
		}, (Exception e) {
			operation.closeStdin();
			fail(e.msg);
		}).ignoreResult();
	}

	/// The turn a Codex boundary names: Codex cuts a thread at its turns.
	static string codexTurnId(HistoryBoundary boundary)
	{
		import std.algorithm : startsWith;

		auto prefix = boundary.kind == HistoryBoundaryKind.user ? "before:" : "through:";
		assert(boundary.kind != HistoryBoundaryKind.provisional_user
			&& boundary.anchor.startsWith(prefix) && boundary.anchor.length > prefix.length,
			"Not a Codex history boundary: " ~ boundary.anchor);
		return boundary.anchor[prefix.length .. $];
	}

	/// The boundary `anchor` names in a loaded history.
	/// `opensConversation`: no user message precedes it.
	/// `userBoundariesFrom`: the user boundaries from it on, itself included.
	static bool resolveLoadedBoundary(ref HistoryStore history, string anchor,
		out HistoryBoundary boundary, out bool opensConversation, out int userBoundariesFrom,
		out string matchedEvent)
	{
		import ae.utils.array : as;

		if (anchor.length == 0)
			return false;
		bool found, userBefore;
		foreach (ref entry; history)
		{
			HistoryBoundaryEvent probe;
			entry.enter((scope const(ubyte)[] bytes) {
				auto event = extractEventFromEnvelope(bytes.as!(char[]));
				probe = jsonParse!HistoryBoundaryEvent(event);
				if (!found && probe.history_boundary.anchor == anchor)
					matchedEvent = event.idup;
			});
			auto current = probe.history_boundary;
			if (!found && current.anchor == anchor)
			{
				found = true;
				boundary = current;
				opensConversation = current.kind == HistoryBoundaryKind.user && !userBefore;
			}
			userBefore = userBefore || probe.isConversationUser;
			if (found && current.anchor.length > 0 && current.kind == HistoryBoundaryKind.user)
				userBoundariesFrom++;
		}
		return found;
	}

	/// Fork a Codex thread at the boundary the client names, which must be
	/// one of the task's loaded history.
	void forkCodexTask(WebSocketAdapter ws, int tid, string anchor, HistoryAccess source)
	{
		auto ca = cast(CodexAgent) source.agent;
		assert(ca !is null, "Only Codex serves and forks its own history");
		void refuse()
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
		}
		host_.whenHistoryLoaded(tid, () {
			auto td = host_.getTask(tid);
			if (td is null)
				return;
			if (td.nativeUndoBlocksDelivery)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"An undo is already in progress", tid)).representation));
				return;
			}
			HistoryBoundary boundary;
			bool opensConversation;
			int userBoundariesFrom;
			string matchedEvent;
			if (!resolveLoadedBoundary(td.history, anchor, boundary, opensConversation,
				userBoundariesFrom, matchedEvent))
				return refuse();
			auto operations = selectHistoryOperations(ca.driver,
				host_.nativeSessionState(tid), host_.servedHistoryMode(tid));
			if (!allowsOperation(boundary, opensConversation, operations, HistoryOperation.fork))
				return refuse();
			string prompt;
			if (boundary.kind == HistoryBoundaryKind.user)
			{
				@JSONPartial static struct UserPrompt
				{
					@JSONOptional ContentBlock[] content;
					@JSONOptional string text;
				}
				auto item = jsonParse!UserPrompt(matchedEvent);
				prompt = item.content.length > 0 ? extractContentText(item.content) : item.text;
			}
			if (auto owner = cast(CodexSession) host_.sessionForTask(tid))
			{
				beginCodexNativeFork(ws, tid, source, boundary, prompt, ca, owner, null);
				return;
			}
			withCodexOperation(MutationReplySocket((Data data) => ws.send(data)), tid, source,
				"Fork failed", (CodexSession owner, CodexForkSourceOperation operation) {
					beginCodexNativeFork(ws, tid, source, boundary, prompt, ca, owner, operation);
				});
		});
	}

	/// Undo a Codex thread back to before the user message the client names:
	/// `thread/revert` at that message's turn.
	void undoCodexTask(MutationReplySocket ws, int tid, WsMessage json, HistoryAccess access)
	{
		void fail(string message)
		{
			ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
		}
		host_.whenHistoryLoaded(tid, () {
			auto td = host_.getTask(tid);
			if (td is null)
				return;
			HistoryBoundary boundary;
			bool opensConversation;
			int userBoundariesFrom;
			string matchedEvent;
			if (!resolveLoadedBoundary(td.history, json.anchor, boundary, opensConversation,
				userBoundariesFrom, matchedEvent))
				return fail("UUID not found in task history");
			auto operations = selectHistoryOperations(access.agent.driver,
				host_.nativeSessionState(tid), host_.servedHistoryMode(tid));
			if (!allowsOperation(boundary, opensConversation, operations, HistoryOperation.undo))
				return fail("UUID not found in task history");
			if (json.revert_files)
				return fail("File revert is unavailable for this history boundary");
			if (json.dry_run)
			{
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
					userBoundariesFrom, "codex_turns")).representation));
				return;
			}
			if (!json.revert_conversation)
			{
				ws.send(Data(toJson(UndoResultMessage("undo_result", tid, "")).representation));
				return;
			}
			if (td.nativeUndoState != NativeUndoState.idle)
				return fail("An undo is already in progress");

			auto turnId = codexTurnId(boundary);
			auto session = cast(CodexSession) host_.sessionForTask(tid);
			if (session !is null && session.canRevertThread)
				(new CodexRevert(ws, tid, CodexRevertKind.live, session)).dispatch(session, turnId);
			else
			{
				td.nativeUndoState = NativeUndoState.backingUp;
				void releaseBackupClaim()
				{
					if (auto current = host_.getTask(tid))
					{
						assert(current.nativeUndoState == NativeUndoState.backingUp);
						current.nativeUndoState = NativeUndoState.idle;
					}
				}
				backUpCodexThread(ws, tid, access, session, () {
					releaseBackupClaim();
					if (session !is null)
						stopAndRevertBusyCodexThread(
							new CodexRevert(ws, tid, CodexRevertKind.busy), access, turnId);
					else
						revertStoppedCodexThread(
							new CodexRevert(ws, tid, CodexRevertKind.stopped), access, turnId);
				}, &releaseBackupClaim);
			}
		});
	}

	enum CodexRevertKind { live, stopped, busy }

	final class CodexRevert
	{
		int tid;
		private MutationReplySocket ws_;
		private CodexRevertKind kind_;
		private CodexSession live_;
		private CodexForkSourceOperation operation_;
		private bool settled_;

		this(MutationReplySocket ws, int tid, CodexRevertKind kind, CodexSession live = null)
		{
			this.tid = tid;
			ws_ = ws;
			kind_ = kind;
			live_ = live;
			host_.getTask(tid).beginConfirmedNativeUndo();
		}

		void attach(CodexForkSourceOperation operation)
		{
			assert(operation_ is null && kind_ != CodexRevertKind.live);
			operation_ = operation;
		}

		void dispatch(CodexSession session, string turnId)
		{
			Promise!void request;
			try
				request = session.revertThread(turnId);
			catch (Exception e)
				return settle(e);
			request.then(() { settle(null); }, &settle).ignoreResult();
		}

		void settle(Exception failure)
		{
			assert(!settled_, "Codex revert settled twice");
			settled_ = true;

			if (operation_ !is null)
				operation_.closeStdin();
			if (kind_ == CodexRevertKind.live && failure !is null
				&& host_.sessionForTask(tid) is live_ && live_.alive)
			{
				host_.getTask(tid).processQueue.setGoal(ProcessState.Dead).ignoreResult();
				live_.closeStdin();
			}

			auto task = host_.getTask(tid);
			assert(task !is null, "Reverted Codex task must exist");
			final switch (kind_)
			{
			case CodexRevertKind.live:
				break;
			case CodexRevertKind.stopped:
				break;
			case CodexRevertKind.busy:
				task.undoStopInProgress = false;
				auto applyStopStatus = task.applyCodexUndoStopStatus;
				task.applyCodexUndoStopStatus = null;
				if (failure !is null && applyStopStatus !is null)
					applyStopStatus();
				break;
			}

			if (failure is null)
				task.completeVerifiedNativeUndoCleanup();
			else
				task.clearNativeUndoRefusalBeforeDispatch();

			task.history.reset(Watermark.driverServed());
			host_.unsubscribeTaskHistorySubscribers(tid);
			host_.emitTaskReload(tid, "");
			if (kind_ == CodexRevertKind.busy && failure is null)
				resumeAfterUndo(tid);
			host_.broadcastTaskUpdate(tid);
			if (failure is null)
				ws_.send(Data(toJson(UndoResultMessage("undo_result", tid, "")).representation));
			else
				ws_.send(Data(toJson(ErrorMessage("error", "Undo failed: " ~ failure.msg,
					tid)).representation));
		}
	}

	/// Resume a stopped thread into a private operation for the revert.
	void revertStoppedCodexThread(CodexRevert revert, HistoryAccess access, string turnId)
	{
		CodexForkSourceOperation operation;
		try
			operation = host_.openCodexForkSourceOperation(revert.tid, access);
		catch (Exception e)
			return revert.settle(e);
		revert.attach(operation);
		operation.routeReady.then((CodexSession owner) {
			revert.dispatch(owner, turnId);
		}, &revert.settle).ignoreResult();
	}

	void stopAndRevertBusyCodexThread(CodexRevert revert, HistoryAccess access, string turnId)
	{
		auto tid = revert.tid;
		auto td = host_.getTask(tid);
		td.undoStopInProgress = true;
		if (auto live = host_.sessionForTask(tid))
			live.invalidatePendingSubmittedMessages();
		host_.unsubscribeTaskHistorySubscribers(tid);
		td.processQueue.setGoal(ProcessState.Dead).then(() {
			revertStoppedCodexThread(revert, access, turnId);
		}, &revert.settle).ignoreResult();
		host_.stopTask(tid);
	}

	/// Start the task's session again on the history an undo left.
	void resumeAfterUndo(int tid)
	{
		auto td = host_.getTask(tid);
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
		HistoryAccess access, ProcessLaunch liveLaunch)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;
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
				performUndoExecution(ws, tid, json, boundary, mechanism, access,
					liveLaunch, failUndo, () { transaction.finalize(); });
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

	/// Undo through the live Claude process (`rewind_files`,
	/// `rewind_conversation`) instead of stopping and resuming it. The CLI
	/// records the rewind in its session file without removing the undone
	/// turns; history readers leave them out (Agent.inactiveHistoryLines).
	void executeClaudeNativeUndo(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryAccess access, ClaudeCodeSession session)
	{
		import core.time : msecs;
		import std.algorithm : canFind;
		import ae.sys.timing : setTimeout;
		import ae.utils.promise : resolve;

		void fail(string message)
		{
			ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
		}

		host_.getTask(tid).beginConfirmedNativeUndo();
		auto files = json.revert_files
			? session.rewindFiles(boundary.checkpoint_uuid).then(
				(string output) => output,
				(Exception e) {
					// Same tolerance as the JSONL mechanism's --rewind-files.
					if (!e.msg.canFind("No file checkpoint found"))
						throw new Exception("File revert failed: " ~ e.msg);
					return string.init;
				})
			: resolve(string.init);
		files.then((string rewindOutput) {
			auto td = host_.getTask(tid);
			if (!json.revert_conversation)
			{
				td.completeVerifiedNativeUndoCleanup();
				ws.send(Data(toJson(UndoResultMessage("undo_result", tid,
					rewindOutput)).representation));
				return;
			}
			// Read before the rewind: afterwards the conversation no longer
			// holds the undone turns.
			auto lastForkId = lastHistoryBoundaryAnchor(access);
			session.rewindConversation(boundary.anchor, lastUserBoundaryAnchor(access))
				.then((string rewoundTo) {
				auto current = host_.getTask(tid);
				if (rewoundTo != boundary.anchor)
				{
					current.markNativeUndoUnverified();
					fail("Claude rewound to " ~ rewoundTo ~ " instead of " ~ boundary.anchor
						~ "; sends are blocked only in this running CyDo process");
					return;
				}
				void unconfirmed(string reason)
				{
					current.markNativeUndoUnverified();
					fail("Claude rewound its conversation, but CyDo could not confirm it in the session file; sends are blocked only in this running CyDo process. "
						~ reason);
				}
				void apply()
				{
					// The backup copies the file up to the last boundary of
					// the undone conversation, which precedes the rewind.
					if (lastForkId.length > 0)
						createUndoBackup(tid, access, lastForkId);
					trimPendingSteeringTexts(tid, access);
					host_.invalidateJsonlLineage(tid);
					host_.clearUndoJsonl(tid);
					current.history.reset(watermarkFromPath(access.path));
					host_.unsubscribeTaskHistorySubscribers(tid);
					session.invalidatePendingSubmittedMessages();
					host_.emitTaskReload(tid, "");
					host_.startJsonlWatch(tid);
					host_.broadcastTaskUpdate(tid);
					current.completeVerifiedNativeUndoCleanup();
					ws.send(Data(toJson(UndoResultMessage("undo_result", tid,
						rewindOutput)).representation));
				}
				// The CLI answers before its session writer flushes the
				// rewind marker (it batches appends on a 100 ms timer), so
				// wait for the file to record the rewind. The undone turns
				// stay there as a rewound branch.
				void awaitRecordedRewind(uint attemptsRemaining)
				{
					bool recorded;
					try
						recorded = !activeHistoryBoundaries(access)
							.canFind!(persisted => persisted.anchor == boundary.anchor);
					catch (Exception e)
						return unconfirmed(e.msg);
					if (!recorded && attemptsRemaining == 0)
						return unconfirmed("the session file does not record the rewind");
					if (!recorded)
					{
						setTimeout({ awaitRecordedRewind(attemptsRemaining - 1); }, 10.msecs);
						return;
					}
					try
						apply();
					catch (Exception e)
					{
						current.markNativeUndoUnverified();
						fail("Claude rewound its conversation, but CyDo failed to follow it; sends are blocked only in this running CyDo process. "
							~ e.msg);
					}
				}
				awaitRecordedRewind(500);
			}, (Exception e) {
				host_.getTask(tid).clearNativeUndoRefusalBeforeDispatch();
				fail(e.msg);
			}).ignoreResult();
		}, (Exception e) {
			host_.getTask(tid).clearNativeUndoRefusalBeforeDispatch();
			fail(e.msg);
		}).ignoreResult();
	}

	/// The boundaries of the conversation the agent continues, leaving out
	/// turns it rolled back or rewound in place.
	PersistedHistoryBoundary[] activeHistoryBoundaries(HistoryAccess access)
	{
		import std.algorithm : filter;
		import std.array : array;

		auto content = readText(access.path);
		auto inactive = access.agent.inactiveHistoryLines(content);
		return access.agent.extractPersistedHistoryBoundaries(content)
			.filter!(boundary => boundary.sourceLine !in inactive).array;
	}

	/// Anchor of the conversation's last user message boundary.
	string lastUserBoundaryAnchor(HistoryAccess access)
	{
		foreach_reverse (boundary; activeHistoryBoundaries(access))
			if (boundary.kind == PersistedHistoryBoundaryKind.user)
				return boundary.anchor;
		assert(false, "Undoing a user message requires a user boundary in the history");
	}

	/// Anchor of the conversation's last boundary, or null when it has none.
	string lastHistoryBoundaryAnchor(HistoryAccess access)
	{
		auto boundaries = exists(access.path) ? activeHistoryBoundaries(access) : null;
		return boundaries.length > 0 ? boundaries[$ - 1].anchor : null;
	}

	/// Cut the history file at `anchor`, dropping it and everything after.
	/// Returns false when the anchor is not in the file.
	bool truncateUndoneHistory(int tid, HistoryAccess access, string anchor)
	{
		if (truncateJsonl(access.path, anchor, &access.agent.forkIdMatchesLine, true) < 0)
			return false;
		trimPendingSteeringTexts(tid, access);
		return true;
	}

	/// Drop the recorded sends beyond the user messages the conversation
	/// still holds after an undo, so a reload does not recover them.
	void trimPendingSteeringTexts(int tid, HistoryAccess access)
	{
		import std.string : splitLines;

		auto td = host_.getTask(tid);
		if (td.pendingSteeringTexts.length == 0 || !exists(access.path))
			return;
		auto content = readText(access.path);
		auto inactive = access.agent.inactiveHistoryLines(content);
		int remaining = 0;
		foreach (i, line; content.splitLines())
			if (cast(int) i + 1 !in inactive && access.agent.isHistoryPrompt(line))
				remaining++;
		if (remaining < cast(int) td.pendingSteeringTexts.length)
			td.pendingSteeringTexts = td.pendingSteeringTexts[0 .. remaining].dup;
	}

	/// Preserve the history about to be undone as a completed "(pre-undo)"
	/// child task forked at the history's last boundary.
	void createUndoBackup(int tid, HistoryAccess access, string lastForkId)
	{
		import std.datetime : Clock;

		auto td = host_.getTask(tid);
		auto ta = access.agent;
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

	void performUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism,
		HistoryAccess access, ProcessLaunch capturedLiveLaunch,
		void delegate(string) onFailure = null, void delegate() onSuccess = null)
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
			auto fresh = host_.prepareOperationSessionLaunch(tid, ta, typeDef);
			rewindLaunch = fresh.processLaunch;
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
			auto lastForkId = lastHistoryBoundaryAnchor(access);
			if (lastForkId.length > 0)
				createUndoBackup(tid, access, lastForkId);
		}

		finishUndoExecution(ws, tid, json, boundary, access, rewindOutput, onFailure,
			onSuccess);
	}

	void finishUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryAccess access, string rewindOutput,
		void delegate(string) onFailure = null, void delegate() onSuccess = null)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;

		if (json.revert_conversation)
		{
			if (!truncateUndoneHistory(tid, access, boundary.anchor))
			{
				if (onFailure !is null)
					onFailure("UUID not found for truncation");
				else
					ws.send(Data(toJson(ErrorMessage("error",
						"UUID not found for truncation", tid)).representation));
				return;
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
			resumeAfterUndo(tid);

		host_.broadcastTaskUpdate(tid);
	}
}

unittest
{
	// Browser history mutations accept the canonical boundary field only.  Keep
	// this parser test here with the mutation entry points so a compatibility
	// alias cannot silently reintroduce the retired wire name.
	auto canonical = jsonParse!WsMessage(
		`{"type":"undo_task","tid":71,"anchor":"before:t"}`);
	assert(canonical.anchor == "before:t");

	bool rejectedLegacyField;
	try
		jsonParse!WsMessage(`{"type":"undo_task","tid":71,"after_` ~ "uuid" ~ `":"line:2"}`);
	catch (Exception)
		rejectedLegacyField = true;
	assert(rejectedLegacyField);
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
	host.nativeSessionState = (int) => NativeSessionState.dead;
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
		string, out HistoryBoundary boundary, out bool opensConversation) {
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
			anchor: "line:999999", dry_run: dryRun,
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
			anchor: "line:4", dry_run: dryRun, revert_conversation: true));
	}
	assert(replies == 4);
	assert(sideEffects == 0);

	// A resolved assistant boundary is valid for conversation undo but never for
	// file rewind; both preview and confirmation reject the forged file request.
	foreach (dryRun; [true, false])
	{
		resolution = Resolution.noCheckpoint;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			anchor: "assistant", dry_run: dryRun, revert_conversation: true,
			revert_files: true));
	}
	assert(replies == 6);
	assert(sideEffects == 0);
}

// Codex fork and undo address the boundaries of the task's loaded history.
unittest
{
	import cydo.agent.contract : SessionConfig;
	import cydo.agent.drivers.codex : AppServerProcess, CodexForkSourceOwner;
	import cydo.agent.drivers.codex.history : CodexHistoryMode;
	import cydo.domain.storage.persistence : LoadedHistory;
	import cydo.protocol : TaskEventEnvelope;
	import cydo.runtime.launch.types : NativeHistoryProfile;
	import std.algorithm : canFind, move;
	import std.string : representation;
	import ae.utils.json : JSONFragment, JSONPartial;
	import core.exception : AssertError;
	import std.exception : assertThrown;
	import ae.utils.promise : resolve;

	enum tid = 72;

	class StubCodexSession : CodexSession
	{
		bool idle = true;
		bool closed;
		bool throwOnRevert;

		override @property bool alive() { return !closed; }
		override void closeStdin() { closed = true; }
		string[] reverts;
		Promise!void revert;

		this()
		{
			super(cast(AppServerProcess) null, tid, SessionConfig.init);
		}

		override @property bool canRevertThread() const
		{
			return idle;
		}

		override Promise!void revertThread(string beforeTurnId)
		{
			reverts ~= beforeTurnId;
			if (throwOnRevert)
				throw new Exception("revert dispatch failed");
			revert = new Promise!void;
			return revert;
		}
	}

	auto agent = new CodexAgent;
	auto access = HistoryAccess.driverServed(agent,
		NativeHistoryProfile(agent.driver, "/unused-profile"), "thread");
	auto task = TaskData(tid, "local", "/tmp");
	task.agentName = "codex";
	task.agentSessionId = "thread";
	ubyte mode = CodexHistoryMode.paginated;
	void loadHistory(bool firstUserAnchored = true)
	{
		task.history.reset(Watermark.driverServed());
		LoadedHistory loaded;
		foreach (event; [
			firstUserAnchored
				? `{"type":"item/started","item_type":"user_message","history_boundary":{"anchor":"before:t1","kind":"user"}}`
				: `{"type":"item/started","item_type":"user_message"}`,
			`{"type":"turn/stop","history_boundary":{"anchor":"through:t1","kind":"agent_turn"}}`,
			`{"type":"item/started","item_type":"user_message","item_id":"u2","content":[{"type":"text","text":"second prompt"}],"history_boundary":{"anchor":"before:t2","kind":"user"}}`,
			`{"type":"item/started","item_type":"user_message"}`,
			`{"type":"turn/stop","history_boundary":{"anchor":"through:t2","kind":"agent_turn"}}`,
		])
		{
			loaded.history ~= Data(toJson(TaskEventEnvelope(tid, 0,
				JSONFragment(event))).representation);
			loaded.rawSource ~= null;
			loaded.sourceLine ~= 0;
		}
		task.history.completeDriverLoad(task.history.beginDriverLoad(), move(loaded), mode);
	}
	loadHistory();

	HistoryBoundary boundary;
	bool opensConversation;
	int userBoundariesFrom;
	string matchedEvent;
	assert(TaskMutationService.resolveLoadedBoundary(task.history, "before:t1", boundary,
		opensConversation, userBoundariesFrom, matchedEvent));
	assert(boundary.kind == HistoryBoundaryKind.user && opensConversation
		&& userBoundariesFrom == 2);
	assert(TaskMutationService.resolveLoadedBoundary(task.history, "before:t2", boundary,
		opensConversation, userBoundariesFrom, matchedEvent));
	assert(!opensConversation && userBoundariesFrom == 1);
	assert(TaskMutationService.resolveLoadedBoundary(task.history, "through:t2", boundary,
		opensConversation, userBoundariesFrom, matchedEvent));
	assert(boundary.kind == HistoryBoundaryKind.agent_turn && userBoundariesFrom == 0);
	foreach (forged; ["", "before:t3", "through:t", "line:2"])
		assert(!TaskMutationService.resolveLoadedBoundary(task.history, forged, boundary,
			opensConversation, userBoundariesFrom, matchedEvent));

	loadHistory(false);
	assert(TaskMutationService.resolveLoadedBoundary(task.history, "before:t2", boundary,
		opensConversation, userBoundariesFrom, matchedEvent));
	assert(!opensConversation && userBoundariesFrom == 1);
	loadHistory();

	auto session = new StubCodexSession;
	bool alive = true;
	string[] replies;
	string[] effects;
	TaskMutationServiceHost host;
	host.getTask = (int value) => value == tid ? &task : null;
	host.sessionForTask = (int) => alive ? session : null;
	host.taskAlive = (int) => alive;
	host.resolveTaskHistory = (int) => TaskHistoryResolution.access(access);
	host.whenHistoryLoaded = (int, void delegate() ready) {
		assert(task.history.isLoaded);
		ready();
	};
	host.servedHistoryMode = (int) => mode;
	host.nativeSessionState = (int) => !alive ? NativeSessionState.dead
		: session.idle ? NativeSessionState.liveReady : NativeSessionState.liveBusy;
	host.unsubscribeTaskHistorySubscribers = (int) { effects ~= "unsubscribe"; };
	host.emitTaskReload = (int, string) { effects ~= "reload"; };
	bool expectResume;
	host.broadcastTaskUpdate = (int) {
		if (expectResume)
		{
			assert(task.processQueue.goalState == ProcessState.Alive);
			effects ~= "resume";
		}
		effects ~= "update";
	};
	host.transitionTaskFrom = (int, TaskStatus[], TaskStatus, TaskNotificationChange) {};
	host.generateSuggestions = (int) {};
	host.stopTask = (int) { effects ~= "stop"; };
	auto privateSession = new StubCodexSession;
	auto owner = new CodexForkSourceOwner(privateSession, access.sessionId);
	auto operation = new CodexForkSourceOperation(ProcessLaunch.init);
	operation.attachOwner(owner);
	bool openFails;
	host.openCodexForkSourceOperation = (int value, const ref HistoryAccess source) {
		assert(!alive && value == tid && source.sessionId == access.sessionId);
		if (openFails)
			throw new Exception("operation open failed");
		return operation;
	};
	auto service = new TaskMutationService(host);
	void delegate(Data) reply = (Data data) { replies ~= cast(string) data.toGC(); };
	WsMessage undo(string anchor, bool dryRun = false) => WsMessage(type: "undo_task",
		tid: tid, anchor: anchor, dry_run: dryRun, revert_conversation: true);
	void drain()
	{
		import ae.net.asockets : socketManager;

		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	// A forged anchor, an anchor Codex does not undo at, and a legacy thread
	// are refused before anything happens.
	foreach (refused; ["before:t3", "line:2", "through:t2"])
	{
		service.handleUndoTaskMsg(reply, undo(refused));
		service.handleUndoTaskMsg(reply, undo(refused, true));
	}
	mode = CodexHistoryMode.legacy;
	service.handleUndoTaskMsg(reply, undo("before:t2"));
	mode = CodexHistoryMode.paginated;
	assert(replies.length == 7);
	foreach (refusal; replies)
		assert(refusal.canFind("UUID not found in task history"));
	assert(effects.length == 0 && session.reverts.length == 0 && task.history.isLoaded);
	// The preview counts the turns the undo removes.
	replies = null;
	service.handleUndoTaskMsg(reply, undo("before:t1", true));
	assert(replies.length == 1 && replies[0].canFind(`"undo_preview"`)
		&& replies[0].canFind(`"messages_removed":2`) && replies[0].canFind("codex_turns"),
		replies[0]);
	assert(effects.length == 0 && session.reverts.length == 0);

	alias Kind = TaskMutationService.CodexRevertKind;
	enum Outcome { verified, rejected, exited, closed, dispatchFailure,
		openFailure, routeFailure, stopFailure }

	@JSONPartial struct ReplyType { string type; }
	void replyInOrder(Data data)
	{
		reply(data);
		effects ~= "reply:" ~ jsonParse!ReplyType(replies[$-1]).type;
	}

	foreach (row; [
		Kind.live: [Outcome.verified, Outcome.rejected, Outcome.exited, Outcome.closed,
			Outcome.dispatchFailure],
		Kind.stopped: [Outcome.verified, Outcome.rejected, Outcome.openFailure,
			Outcome.routeFailure],
		Kind.busy: [Outcome.verified, Outcome.rejected, Outcome.routeFailure,
			Outcome.stopFailure],
	].byKeyValue)
	foreach (outcome; row.value)
	{
		auto kind = row.key;
		bool live = kind == Kind.live;
		bool busy = kind == Kind.busy;
		bool verified = outcome == Outcome.verified;
		auto scenario = toJson(kind) ~ " " ~ toJson(outcome);
		loadHistory();
		task.status = kind == Kind.stopped ? TaskStatus.completed : TaskStatus.active;
		alive = kind != Kind.stopped;
		session = new StubCodexSession;
		privateSession = new StubCodexSession;
		owner = new CodexForkSourceOwner(privateSession, access.sessionId);
		operation = new CodexForkSourceOperation(ProcessLaunch.init);
		operation.attachOwner(owner);
		openFails = outcome == Outcome.openFailure;
		expectResume = busy && verified;
		replies = null;
		effects = null;

		auto stopped = new Promise!ProcessState;
		task.processQueue = new StateQueue!ProcessState((ProcessState goal) {
			if (goal == ProcessState.Alive)
			{
				assert(expectResume, "failed undo requested a resume");
				return resolve(ProcessState.Alive);
			}
			return busy ? stopped : resolve(ProcessState.Dead);
		}, alive ? ProcessState.Alive : ProcessState.Dead);

		auto transaction = service.new CodexRevert(MutationReplySocket(&replyInOrder),
			tid, kind, live ? session : null);
		if (live)
		{
			session.throwOnRevert = outcome == Outcome.dispatchFailure;
			transaction.dispatch(session, "t2");
			if (outcome == Outcome.exited)
			{
				alive = false;
				session.closed = true;
			}
			else if (outcome == Outcome.closed)
				session.closeStdin();
		}
		else if (busy)
		{
			service.stopAndRevertBusyCodexThread(transaction, access, "t2");
			drain();
			assert(task.undoStopInProgress && effects == ["unsubscribe", "stop"]);
			if (outcome == Outcome.stopFailure)
				stopped.reject(new Exception("busy stop failed"));
			else
			{
				alive = false;
				task.applyCodexUndoStopStatus = () {
					task.status = TaskStatus.failed;
					effects ~= "status";
				};
				stopped.fulfill(ProcessState.Dead);
			}
		}
		else
			service.revertStoppedCodexThread(transaction, access, "t2");

		drain();
		if (!live && outcome != Outcome.openFailure && outcome != Outcome.stopFailure)
		{
			if (outcome == Outcome.routeFailure)
				operation.closeStdin();
			else
			{
				__traits(getMember, privateSession, "threadId") = access.sessionId;
				__traits(getMember, privateSession, "routeReadyHandler_")();
			}
			drain();
		}

		auto reverted = live ? session : privateSession;
		if (auto response = reverted.revert)
		{
			assert(reverted.reverts == ["t2"]);
			if (verified)
				response.fulfill();
			else
				response.reject(new Exception(outcome == Outcome.rejected && busy
					? "Codex app-server exited during a thread request" : "revert rejected"));
			drain();
		}

		string[] expected;
		if (busy)
		{
			expected ~= ["unsubscribe", "stop"];
			if (!verified && outcome != Outcome.stopFailure)
				expected ~= "status";
		}
		expected ~= ["unsubscribe", "reload"];
		if (expectResume)
			expected ~= "resume";
		expected ~= ["update", verified ? "reply:undo_result" : "reply:error"];
		assert(effects == expected, scenario ~ ": " ~ toJson(effects));
		assert(replies.length == 1);
		if (busy && outcome == Outcome.rejected)
			assert(replies[0].canFind("Undo failed: Codex app-server exited during a thread request"));
		assert(!task.history.isLoaded && task.history.isDriverServed);
		assert(task.nativeUndoState == NativeUndoState.idle && !task.undoStopInProgress);
		assert(task.applyCodexUndoStopStatus is null);
		if (busy)
			assert(task.status == (verified || outcome == Outcome.stopFailure
				? TaskStatus.active : TaskStatus.failed));
		if (live)
			assert(session.closed == !verified);
		else if (outcome != Outcome.openFailure && outcome != Outcome.stopFailure)
			assert(privateSession.closed);
		assertThrown!AssertError(transaction.settle(null));
	}
}
