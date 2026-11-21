module cydo.workflow.questions.router;

import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;

import ae.utils.json : toJson;
import ae.utils.promise : Promise, resolve, race;
import ae.utils.promise.await : async, await;

import cydo.protocol : AnswerResult, ContentBlock, QuestionResult;
import cydo.workflow.batch.registry : BatchHandle, BatchRegistry;
import cydo.mcp : McpResult;
import cydo.foundation.system.known_messages : KnownSystemMessageKind, followUpFromParentSubject,
	questionFromTaskSubject, wrapKnownSystemMessage;
import cydo.domain.tasks.model : TaskData, TaskStatus;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.text.title : truncateTitle;

package(cydo):

enum QuestionDelivery { batchQuestion, injectedMessage }
enum QuestionWait { directPromise, batchLoop }
enum QuestionAfterAnswer
{
	continueBatch,
	completeAnswererOnIdle,
	leaveAnswererAlive,
	/// The answerer serves requests from several askers, and its turns span
	/// several requests, so its turn end says nothing about any one of them.
	/// The request ends when the answerer answers it: Answer releases the
	/// asker at once, and the answerer's status stays with its own turn-end
	/// handling.
	endRequestOnAnswer,
}

struct QuestionRoute
{
	int qid;
	int askerTid;
	int answererTid;
	QuestionDelivery delivery;
	QuestionWait wait;
	QuestionAfterAnswer afterAnswer;
	bool hasBatch;
	ulong batchId;
	size_t batchSlot;
	int batchChildTid;
	bool delivered;
}

struct QuestionRegistration
{
	int qid;
	Promise!McpResult promise;
}

struct QuestionRouterHost
{
	TaskData* delegate(int tid) getTask;
	bool delegate(int tid) isTaskAlive;
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	string delegate() systemKeyword;
	string delegate(string relativePath, string projectPath,
		string[string] vars) readPromptFile;
	string delegate(KnownSystemMessageKind kind, string subject,
		string[string] vars, string bodyVar) buildKnownSystemMessageMeta;
	Promise!void delegate(int tid, const(ContentBlock)[] content, string cydoMeta,
		string nonce) sendTaskMessage;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, void delegate() cb) addIdleCallback;
	Promise!void delegate(int tid) reactivateTask;
	bool delegate(int tid) hasPendingSubTask;
	void delegate(int parentTid, int childTid,
		BatchHandle handle) registerFollowUpBatchChild;
	void delegate(int childTid) cleanupAfterFollowUpAnswerDelivery;
	Promise!McpResult delegate(int parentTid, ulong batchId) awaitBatchLoop;
	McpResult delegate(string message) makeInternalBatchError;
}

class QuestionRouter
{
private:
	QuestionRouterHost host_;
	BatchRegistry* batchRegistry_;
	int nextQid_;
	Promise!McpResult[int] pendingQuestions_;
	QuestionRoute[int] questionRoutes_;

	/// Return the asker to active after its question was answered.
	///
	/// The asker is not necessarily still waiting: the agent dispatches a
	/// completed Ask tool_use block eagerly, before the rest of its assistant
	/// message has streamed, and the remaining stream events flip the asker
	/// back to active (task_runner's assistant-turn-work resume). Both states
	/// legitimately receive the answer; any other state is a logic error.
	void reactivateAskerAfterAnswer(int askerTid)
	{
		auto askerTd = host_.getTask(askerTid);
		if (askerTd is null)
			return;
		if (askerTd.status == TaskStatus.waiting)
			host_.transitionTask(askerTid, TaskStatus.waiting,
				TaskStatus.active, TaskNotificationChange.clearBody);
		else
			assert(askerTd.status == TaskStatus.active,
				"Ask answer delivered with asker in unexpected status: "
				~ cast(string) askerTd.status);
	}

public:
	this(QuestionRouterHost host, BatchRegistry* batchRegistry)
	{
		assert(batchRegistry !is null,
			"QuestionRouter requires a live BatchRegistry");
		host_ = host;
		batchRegistry_ = batchRegistry;
		nextQid_ = cast(int) Clock.currTime.toUnixTime;
	}

	bool childHasPendingQuestion(int childTid, int qid)
	{
		auto routePtr = qid in questionRoutes_;
		if (routePtr is null)
			return false;
		auto route = *routePtr;
		return route.askerTid == childTid
			&& route.afterAnswer == QuestionAfterAnswer.continueBatch
			&& (qid in pendingQuestions_) !is null;
	}

	void failQuestionRoute(int qid, string message)
	{
		if (auto qp = qid in pendingQuestions_)
			(*qp).fulfill(McpResult(message, true));
		clearQuestionRoute(qid);
	}

	void failQuestionRoutesForAnswerer(int answererTid, string message)
	{
		int[] qids;
		foreach (qid, route; questionRoutes_)
			if (route.answererTid == answererTid)
				qids ~= qid;
		foreach (qid; qids)
			failQuestionRoute(qid, message);
	}

	McpResult buildQuestionResult(int childTid, int qid, string questionText)
	{
		auto childTd = host_.getTask(childTid);
		auto childTitle = childTd is null ? null : childTd.title;
		auto questionJson = toJson(QuestionResult("question", childTid, qid,
			childTitle, questionText));
		return McpResult.structured(questionJson);
	}

	Promise!McpResult handleAsk(string callerTidStr, string message, int targetTid)
	{
		int callerTidInt;
		try
			callerTidInt = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto callerTd = host_.getTask(callerTidInt);
		if (callerTd is null)
			return resolve(McpResult("Task not found", true));
		bool explicitTarget = targetTid != -1;

		if (targetTid == -1)
		{
			if (callerTd.parentTid <= 0)
				return resolve(McpResult("No parent task — tid is required", true));
			targetTid = callerTd.parentTid;
		}

		auto targetTd = host_.getTask(targetTid);
		if (targetTd is null)
			return resolve(McpResult("Target task not found: " ~ to!string(targetTid), true));

		if (targetTid == callerTidInt)
			return resolve(McpResult("Ask target must be a different task", true));

		if (explicitTarget && targetTd.status == "importable")
		{
			return resolve(McpResult(
				"Cannot Ask importable task " ~ to!string(targetTid)
				~ "; import or resume it first", true));
		}

		if (!host_.tasksShareWorkspace(callerTidInt, targetTid))
		{
			return resolve(McpResult(
				"Ask target must be in the same workspace (caller="
				~ host_.taskWorkspaceLabel(callerTidInt) ~ ", target="
				~ host_.taskWorkspaceLabel(targetTid) ~ ")", true));
		}

		QuestionRoute route;
		route.askerTid = callerTidInt;
		route.answererTid = targetTid;

		if (callerTd.parentTid == targetTid)
		{
			BatchHandle ownerHandle;
			size_t slot;
			if (!batchRegistry_.findOwnerOfChild(callerTidInt, ownerHandle, slot))
			{
				return resolve(host_.makeInternalBatchError(
					format!"no active batch owning child tid=%d while asking parent tid=%d"
						(callerTidInt, targetTid)));
			}
			if (ownerHandle.parentTid != targetTid)
			{
				return resolve(host_.makeInternalBatchError(
					format!"child tid=%d routed to parent tid=%d but is owned by parent tid=%d batch=%s"
						(callerTidInt, targetTid, ownerHandle.parentTid, ownerHandle.batchId)));
			}

			route.delivery = QuestionDelivery.batchQuestion;
			route.wait = QuestionWait.directPromise;
			route.afterAnswer = QuestionAfterAnswer.continueBatch;
			route.hasBatch = true;
			route.batchId = ownerHandle.batchId;
			route.batchSlot = slot;
			route.batchChildTid = callerTidInt;
			return startQuestionRoute(route, message);
		}

		if (targetTd.parentTid == callerTidInt)
		{
			if (targetTd.pendingAskPromise !is null)
			{
				return resolve(McpResult(
					"Sub-task has a pending question (qid="
					~ to!string(targetTd.pendingAskQid)
					~ "). Use Answer(qid, message) instead.", true));
			}

			route.delivery = QuestionDelivery.injectedMessage;
			route.wait = QuestionWait.batchLoop;
			route.afterAnswer = QuestionAfterAnswer.completeAnswererOnIdle;
			route.batchChildTid = targetTid;

			BatchHandle batchHandle;
			size_t childSlot;
			bool reuseExistingBatch;
			bool resumeChildForFollowUp =
				targetTd.status == "completed"
				|| targetTd.status == "failed"
				|| targetTd.status == "active";
			string batchError;
			if (batchRegistry_.findOwnerOfChild(targetTid, batchHandle, childSlot))
			{
				if (batchHandle.parentTid != callerTidInt)
				{
					return resolve(host_.makeInternalBatchError(
						format!"child tid=%d owned by parent tid=%d batch=%s, cannot reuse for parent tid=%d"
							(targetTid, batchHandle.parentTid, batchHandle.batchId, callerTidInt)));
				}
				if (targetTd.status == "completed" || targetTd.status == "failed")
				{}
				else if (host_.hasPendingSubTask(targetTid))
					reuseExistingBatch = true;
				else
				{
					return resolve(host_.makeInternalBatchError(
						format!"unfinished batch slot has no pending sub-task promise: parent tid=%d batch=%s child tid=%d slot=%s status=%s"
							(batchHandle.parentTid, batchHandle.batchId, targetTid, childSlot, targetTd.status)));
				}
			}

			if (!reuseExistingBatch)
			{
				if (resumeChildForFollowUp && host_.hasPendingSubTask(targetTid))
				{
					return resolve(host_.makeInternalBatchError(
						format!"pending sub-task promise already exists for child tid=%d while creating follow-up batch parent tid=%d"
							(targetTid, callerTidInt)));
				}

				if (!batchRegistry_.create(callerTidInt, [targetTid], batchHandle,
					batchError))
					return resolve(host_.makeInternalBatchError(batchError));
				childSlot = 0;

				if (resumeChildForFollowUp)
					host_.registerFollowUpBatchChild(callerTidInt, targetTid, batchHandle);
			}

			route.hasBatch = true;
			route.batchId = batchHandle.batchId;
			route.batchSlot = childSlot;
			return startQuestionRoute(route, message);
		}

		route.delivery = QuestionDelivery.injectedMessage;
		route.wait = QuestionWait.directPromise;
		route.afterAnswer = QuestionAfterAnswer.leaveAnswererAlive;
		return startQuestionRoute(route, message);
	}

	/// Ask a task that serves requests from several askers (see
	/// `QuestionAfterAnswer.endRequestOnAnswer`).
	Promise!McpResult handleServedRequest(int askerTid, string message, int servingTid)
	{
		assert(host_.getTask(askerTid) !is null, "Served request from a missing task");
		assert(host_.getTask(servingTid) !is null, "Served request to a missing task");
		assert(askerTid != servingTid, "A task cannot serve its own request");
		assert(host_.tasksShareWorkspace(askerTid, servingTid),
			"Served request across workspaces");

		QuestionRoute route;
		route.askerTid = askerTid;
		route.answererTid = servingTid;
		route.delivery = QuestionDelivery.injectedMessage;
		route.wait = QuestionWait.directPromise;
		route.afterAnswer = QuestionAfterAnswer.endRequestOnAnswer;
		return startQuestionRoute(route, message);
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid, string message)
	{
		int callerTidInt;
		try
			callerTidInt = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto callerTd = host_.getTask(callerTidInt);
		if (callerTd is null)
			return resolve(McpResult("Task not found", true));

		auto routePtr = qid in questionRoutes_;
		if (routePtr is null)
			return resolve(McpResult("Unknown question ID: " ~ to!string(qid), true));
		auto route = *routePtr;
		if (callerTidInt != route.answererTid)
			return resolve(McpResult("Unknown question ID: " ~ to!string(qid), true));

		auto questionPromise = qid in pendingQuestions_;
		if (questionPromise is null)
			return resolve(McpResult("Unknown question ID: " ~ to!string(qid), true));

		final switch (route.afterAnswer)
		{
			case QuestionAfterAnswer.continueBatch:
			{
				if (!route.hasBatch)
				{
					return resolve(host_.makeInternalBatchError(
						format!"missing originating batch for child question: parent tid=%d qid=%d"
							(callerTidInt, qid)));
				}
				if (!batchRegistry_.exists(BatchHandle(route.answererTid, route.batchId)))
				{
					return resolve(host_.makeInternalBatchError(
						format!"no active batch while answering child question: parent tid=%d qid=%d"
							(callerTidInt, qid)));
				}

				auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
					callerTd.title, message,
					"Use Ask(question) to ask follow-up questions."));
				reactivateAskerAfterAnswer(route.askerTid);
				(*questionPromise).fulfill(McpResult.structured(answerJson));
				clearQuestionRoute(qid);

				// The answerer re-blocks on the batch below; restore the waiting
				// status that assistant-work activation replaced while it was
				// processing the question. Both batch-loop exits reactivate it:
				// a further question via assistant-work output, a final batch
				// result via onToolCallDelivered.
				if (callerTd.status != TaskStatus.waiting)
					host_.transitionTask(route.answererTid, TaskStatus.active,
						TaskStatus.waiting, TaskNotificationChange.preserve);

				return host_.awaitBatchLoop(route.answererTid, route.batchId);
			}
			case QuestionAfterAnswer.completeAnswererOnIdle:
			{
				auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
					callerTd.title, message,
					"Use Ask(question, " ~ to!string(callerTidInt)
					~ ") for further follow-ups."));
				deferOrDeliverAnswer(route, McpResult.structured(answerJson));
				auto deliveredJson = toJson(AnswerResult("delivered", route.askerTid,
					qid, null, null,
					"Answer delivered to parent task. End the session now."));
				return resolve(McpResult.structured(deliveredJson));
			}
			case QuestionAfterAnswer.leaveAnswererAlive:
			{
				auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
					callerTd.title, message,
					"Use Ask(question, " ~ to!string(callerTidInt)
					~ ") for follow-up questions."));
				deferOrDeliverAnswer(route, McpResult.structured(answerJson));
				auto deliveredJson = toJson(AnswerResult("delivered", route.askerTid,
					qid, null, null, "Answer delivered to asking task."));
				return resolve(McpResult.structured(deliveredJson));
			}
			case QuestionAfterAnswer.endRequestOnAnswer:
			{
				auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
					callerTd.title, message,
					"Use Ask(question, " ~ to!string(callerTidInt)
					~ ") for follow-up questions."));
				reactivateAskerAfterAnswer(route.askerTid);
				(*questionPromise).fulfill(McpResult.structured(answerJson));
				host_.broadcastFocusHint(route.answererTid, route.askerTid);
				clearQuestionRoute(qid);
				auto deliveredJson = toJson(AnswerResult("delivered", route.askerTid,
					qid, null, null, "Answer delivered to asking task."));
				return resolve(McpResult.structured(deliveredJson));
			}
		}
	}

private:
	QuestionRegistration registerQuestionRoute(QuestionRoute route)
	{
		int qid = nextQid_++;
		auto promise = new Promise!McpResult;
		route.qid = qid;
		pendingQuestions_[qid] = promise;
		questionRoutes_[qid] = route;
		return QuestionRegistration(qid, promise);
	}

	void clearQuestionRoute(int qid)
	{
		if (auto routePtr = qid in questionRoutes_)
		{
			auto askerTd = host_.getTask((*routePtr).askerTid);
			if (askerTd !is null && askerTd.pendingAskQid == qid)
			{
				askerTd.pendingAskPromise = null;
				askerTd.pendingAskQuestion = null;
				askerTd.pendingAskQid = 0;
			}
			questionRoutes_.remove(qid);
		}
		pendingQuestions_.remove(qid);
	}

	string makeQuestionMessage(int askerTid, int qid, string message,
		string answererProjectPath = null)
	{
		auto subject = questionFromTaskSubject(askerTid, qid);
		auto body = host_.readPromptFile("prompts/question_from_task.md",
			answererProjectPath,
			["message": message, "qid": to!string(qid)]);
		return wrapKnownSystemMessage(host_.systemKeyword(),
			KnownSystemMessageKind.questionFromTask, body, subject);
	}

	void deliverInjectedQuestion(QuestionRoute route, string message)
	{
		auto sendQuestion = (QuestionRoute currentRoute) {
			assert((currentRoute.qid in questionRoutes_) !is null,
				"Question route disappeared before injected delivery");

			auto currentAnswerer = host_.getTask(currentRoute.answererTid);
			assert(currentAnswerer !is null,
				"Injected question answerer task must exist");
			assert(host_.isTaskAlive(currentRoute.answererTid),
				"Injected question answerer session must be live");

			if (currentAnswerer.status != TaskStatus.active)
				host_.transitionTaskFrom(currentRoute.answererTid,
					[TaskStatus.pending, TaskStatus.alive, TaskStatus.waiting,
						TaskStatus.completed, TaskStatus.failed], TaskStatus.active,
					TaskNotificationChange.preserve);
			host_.broadcastFocusHint(currentRoute.askerTid, currentRoute.answererTid);

			string prompt;
			string meta;
			string promptNonce;
			try
			{
				if (currentRoute.afterAnswer
					== QuestionAfterAnswer.completeAnswererOnIdle)
				{
					auto followUpMsgSubject = followUpFromParentSubject(currentRoute.qid);
					auto followUpBody = host_.readPromptFile(
						"prompts/follow_up_from_parent.md",
						currentAnswerer.projectPath, [
							"message": message,
							"qid": to!string(currentRoute.qid),
						]);
					prompt = wrapKnownSystemMessage(host_.systemKeyword(),
						KnownSystemMessageKind.followUpFromParent, followUpBody,
						followUpMsgSubject);
					meta = host_.buildKnownSystemMessageMeta(
						KnownSystemMessageKind.followUpFromParent,
						followUpMsgSubject,
						["message": message], "message");
					promptNonce = "follow-up:" ~ to!string(currentRoute.qid);
				}
				else
				{
					prompt = makeQuestionMessage(currentRoute.askerTid, currentRoute.qid,
						message, currentAnswerer.projectPath);
					auto qftSubject = questionFromTaskSubject(currentRoute.askerTid,
						currentRoute.qid);
					meta = host_.buildKnownSystemMessageMeta(
						KnownSystemMessageKind.questionFromTask, qftSubject,
						["message": message], "message");
					promptNonce = "question:" ~ to!string(currentRoute.qid);
				}
			}
			catch (Exception e)
			{
				assert(0, "Unable to prepare injected question prompt: " ~ e.msg);
			}

			Promise!void sendPromise;
			try
			{
				sendPromise = host_.sendTaskMessage(currentRoute.answererTid,
					[ContentBlock("text", prompt)], meta, promptNonce);
			}
			catch (Exception e)
			{
				failQuestionRoute(currentRoute.qid,
					"Failed to submit Ask question to task "
						~ to!string(currentRoute.answererTid) ~ ": " ~ e.msg);
				return resolve();
			}

			return sendPromise.then(() {
				auto routePtr = currentRoute.qid in questionRoutes_;
				assert(routePtr !is null,
					"Question route disappeared before injected delivery acceptance");
				(*routePtr).delivered = true;
			}, (Exception e) {
				failQuestionRoute(currentRoute.qid,
					"Failed to submit Ask question to task "
						~ to!string(currentRoute.answererTid) ~ ": " ~ e.msg);
			});
		};

		assert(host_.getTask(route.answererTid) !is null,
			"Injected question target task must exist");

		auto answererTd = host_.getTask(route.answererTid);
		if (answererTd.status == TaskStatus.waiting && answererTd.isProcessing)
		{
			host_.addIdleCallback(route.answererTid, () {
				auto routePtr = route.qid in questionRoutes_;
				if (routePtr is null)
					return;
				sendQuestion(*routePtr).ignoreResult();
			});
			return;
		}

		Promise!void reactivationPromise;
		try
		{
			reactivationPromise = host_.reactivateTask(route.answererTid);
		}
		catch (Exception e)
		{
			failQuestionRoute(route.qid,
				"Failed to reactivate Ask target "
					~ to!string(route.answererTid) ~ ": " ~ e.msg);
			return;
		}

		auto deliveryPromise = reactivationPromise.then(() {
			auto routePtr = route.qid in questionRoutes_;
			assert(routePtr !is null,
				"Question route disappeared during target reactivation");
			return sendQuestion(*routePtr);
		}, (Exception e) {
			failQuestionRoute(route.qid,
				"Failed to reactivate Ask target "
					~ to!string(route.answererTid) ~ ": " ~ e.msg);
			return resolve();
		});
		deliveryPromise.ignoreResult();
	}

	void deferOrDeliverAnswer(QuestionRoute route, McpResult answerResult)
	{
		if (host_.getTask(route.answererTid) is null)
		{
			failQuestionRoute(route.qid,
				"Session ended while waiting for Ask response");
			return;
		}

		host_.addIdleCallback(route.answererTid, () {
			auto routePtr = route.qid in questionRoutes_;
			if (routePtr is null)
				return;

			auto currentRoute = *routePtr;
			auto answererTd = host_.getTask(currentRoute.answererTid);
			if (answererTd is null || !host_.isTaskAlive(currentRoute.answererTid))
			{
				failQuestionRoute(currentRoute.qid,
					"Session ended while waiting for Ask response");
				return;
			}

			reactivateAskerAfterAnswer(currentRoute.askerTid);

			if (auto qp = currentRoute.qid in pendingQuestions_)
				(*qp).fulfill(answerResult);

			if (currentRoute.afterAnswer
				== QuestionAfterAnswer.completeAnswererOnIdle)
			{
				host_.persistResultText(currentRoute.answererTid,
					answererTd.resultText);
				host_.transitionTask(currentRoute.answererTid, TaskStatus.active,
					TaskStatus.completed, TaskNotificationChange.preserve);
				host_.cleanupAfterFollowUpAnswerDelivery(
					currentRoute.answererTid);
				host_.broadcastFocusHint(currentRoute.answererTid,
					currentRoute.askerTid);
				clearQuestionRoute(currentRoute.qid);
				return;
			}

			if (currentRoute.afterAnswer
				== QuestionAfterAnswer.leaveAnswererAlive)
			{
				host_.transitionTask(currentRoute.answererTid, TaskStatus.active,
					TaskStatus.alive, TaskNotificationChange.preserve);
			}
			host_.broadcastFocusHint(currentRoute.answererTid,
				currentRoute.askerTid);
			clearQuestionRoute(currentRoute.qid);
		});
	}

	Promise!McpResult startQuestionRoute(QuestionRoute route, string message)
	{
		if (route.wait == QuestionWait.batchLoop && !route.hasBatch)
		{
			return resolve(host_.makeInternalBatchError(
				"missing batch metadata for batch-loop Ask route"));
		}
		if (route.delivery == QuestionDelivery.batchQuestion && !route.hasBatch)
		{
			return resolve(host_.makeInternalBatchError(
				"missing batch metadata for question-signal Ask route"));
		}

		auto reg = registerQuestionRoute(route);
		int qid = reg.qid;
		auto promise = reg.promise;

		auto routePtr = qid in questionRoutes_;
		assert(routePtr !is null);
		auto currentRoute = *routePtr;

		if (currentRoute.afterAnswer == QuestionAfterAnswer.continueBatch)
		{
			auto askerTd = host_.getTask(currentRoute.askerTid);
			assert(askerTd !is null);
			askerTd.pendingAskPromise = promise;
			askerTd.pendingAskQuestion = message;
			askerTd.pendingAskQid = qid;
		}

		Promise!McpResult routeErrorPromise;
		if (currentRoute.wait == QuestionWait.batchLoop)
		{
			routeErrorPromise = new Promise!McpResult;
			auto handle = BatchHandle(currentRoute.askerTid, currentRoute.batchId);
			auto slot = currentRoute.batchSlot;
			auto childTid = currentRoute.batchChildTid;
			promise.then((McpResult r) {
				if (r.isError)
					routeErrorPromise.fulfill(r);
				batchRegistry_.enqueueChildDone(handle, slot, childTid, r);
				clearQuestionRoute(qid);
			});
		}

		if (currentRoute.afterAnswer == QuestionAfterAnswer.continueBatch)
		{
			auto askerTd = host_.getTask(currentRoute.askerTid);
			assert(askerTd !is null);
			askerTd.notificationBody = "Asking parent: "
				~ truncateTitle(message, 100);
		}
		else if (currentRoute.afterAnswer == QuestionAfterAnswer.leaveAnswererAlive
				|| currentRoute.afterAnswer == QuestionAfterAnswer.endRequestOnAnswer)
		{
			auto askerTd = host_.getTask(currentRoute.askerTid);
			assert(askerTd !is null);
			askerTd.notificationBody = "Asking task "
				~ to!string(currentRoute.answererTid)
				~ ": " ~ truncateTitle(message, 100);
		}
		host_.transitionTask(currentRoute.askerTid, TaskStatus.active,
			TaskStatus.waiting, TaskNotificationChange.preserve);

		host_.broadcastFocusHint(currentRoute.askerTid, currentRoute.answererTid);

		if (currentRoute.delivery == QuestionDelivery.batchQuestion)
		{
			batchRegistry_.enqueueQuestion(
				BatchHandle(currentRoute.answererTid, currentRoute.batchId),
				currentRoute.batchSlot,
				currentRoute.batchChildTid,
				message,
				currentRoute.qid);
		}
		else
			deliverInjectedQuestion(currentRoute, message);

		if (currentRoute.wait == QuestionWait.batchLoop)
		{
			auto batchPromise = async(host_.awaitBatchLoop(currentRoute.askerTid,
				currentRoute.batchId).await);
			return race([routeErrorPromise, batchPromise]);
		}
		return promise;
	}
}

unittest
{
	import ae.net.asockets : socketManager;
	import ae.utils.promise : reject;
	import core.exception : AssertError;
	import cydo.domain.tasks.model : BatchSignal;
	import cydo.workflow.batch.router : BatchConsumeKind;
	import std.exception : assertThrown;

	void drainPromiseNextTicks()
	{
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

	enum DeliveryFailure
	{
		none,
		reactivateSync,
		reactivateRejected,
		sendSync,
		sendRejected,
	}

	struct DeliveryCase
	{
		string name;
		TaskStatus childStatus;
		bool childIsProcessing;
		bool invokeIdleCallback;
		bool gateReactivation;
		bool gateSend;
		DeliveryFailure failure;
		size_t initialIdleCallbacks;
		size_t initialReactivations;
		size_t initialSends;
		size_t routesAfterStart;
		size_t finalReactivations;
		size_t finalSends;
		bool checkDeliveredGate;
		bool assertPreSendInvariant;
		string failureCause;
		string expectedError;
	}

	auto cases = [
		DeliveryCase(
			name: "busy waiting child defers injected Ask until idle",
			childStatus: TaskStatus.waiting,
			childIsProcessing: true,
			invokeIdleCallback: true,
			initialIdleCallbacks: 1,
			routesAfterStart: 1,
			finalSends: 1,
		),
		DeliveryCase(
			name: "restored idle waiting child reactivates immediately",
			childStatus: TaskStatus.waiting,
			childIsProcessing: false,
			gateReactivation: true,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			finalSends: 1,
		),
		DeliveryCase(
			name: "active processing child reactivates immediately",
			childStatus: TaskStatus.active,
			childIsProcessing: true,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			finalSends: 1,
		),
		DeliveryCase(
			name: "synchronous reactivation failure completes Ask",
			childStatus: TaskStatus.active,
			failure: DeliveryFailure.reactivateSync,
			initialReactivations: 1,
			routesAfterStart: 0,
			finalReactivations: 1,
			failureCause: "reactivate synchronously failed",
			expectedError: "Failed to reactivate Ask target 2: reactivate synchronously failed",
		),
		DeliveryCase(
			name: "rejected reactivation completes Ask",
			childStatus: TaskStatus.active,
			failure: DeliveryFailure.reactivateRejected,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			failureCause: "reactivate asynchronously failed",
			expectedError: "Failed to reactivate Ask target 2: reactivate asynchronously failed",
		),
		DeliveryCase(
			name: "synchronous send failure completes Ask",
			childStatus: TaskStatus.active,
			failure: DeliveryFailure.sendSync,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			finalSends: 1,
			failureCause: "send synchronously failed",
			expectedError: "Failed to submit Ask question to task 2: send synchronously failed",
		),
		DeliveryCase(
			name: "rejected send completes Ask",
			childStatus: TaskStatus.active,
			failure: DeliveryFailure.sendRejected,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			finalSends: 1,
			failureCause: "send asynchronously failed",
			expectedError: "Failed to submit Ask question to task 2: send asynchronously failed",
		),
		DeliveryCase(
			name: "delivered is set only after the send fulfills",
			childStatus: TaskStatus.active,
			gateSend: true,
			initialReactivations: 1,
			routesAfterStart: 1,
			finalReactivations: 1,
			finalSends: 1,
			checkDeliveredGate: true,
		),
		DeliveryCase(
			name: "illegal post-reactivation state asserts before injected send",
			childStatus: TaskStatus.waiting,
			gateReactivation: true,
			initialReactivations: 1,
			routesAfterStart: 1,
			assertPreSendInvariant: true,
		),
	];

	foreach (test; cases)
	{
		TaskData[int] tasks;
		tasks[1] = TaskData(1, "local", "/tmp/question-router-test");
		tasks[1].status = TaskStatus.active;
		tasks[2] = TaskData(2, "local", "/tmp/question-router-test");
		tasks[2].parentTid = 1;
		tasks[2].status = test.childStatus;
		tasks[2].isProcessing = test.childIsProcessing;

		auto batchLoop = new Promise!McpResult;
		Promise!void reactivationGate;
		if (test.gateReactivation)
			reactivationGate = new Promise!void;
		Promise!void sendGate;
		if (test.gateSend)
			sendGate = new Promise!void;

		void delegate()[] idleCallbacks;
		size_t reactivationCalls;
		size_t sendCalls;

		auto host = QuestionRouterHost(
			getTask: (int tid) {
				auto task = tid in tasks;
				return task is null ? null : task;
			},
			isTaskAlive: (int tid) => (tid in tasks) !is null,
			tasksShareWorkspace: (int aTid, int bTid) => true,
			taskWorkspaceLabel: (int tid) => "local",
			systemKeyword: () => "SYSTEM",
			readPromptFile: (string relativePath, string projectPath,
				string[string] vars) => "",
			buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
				string subject, string[string] vars, string bodyVar) => "{}",
			sendTaskMessage: (int tid, const(ContentBlock)[] content,
				string cydoMeta, string nonce) {
				assert(tid == 2, test.name);
				sendCalls++;
				if (test.failure == DeliveryFailure.sendSync)
					throw new Exception(test.failureCause);
				if (test.failure == DeliveryFailure.sendRejected)
					return reject!void(new Exception(test.failureCause));
				return sendGate is null ? resolve() : sendGate;
			},
			transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
				TaskNotificationChange notification) {
				assert(tasks[tid].status == expectedFrom, test.name);
				tasks[tid].status = to;
			},
			transitionTaskFrom: (int tid, TaskStatus[] expectedFrom,
				TaskStatus to, TaskNotificationChange notification) {
				bool expected;
				foreach (from; expectedFrom)
					expected = expected || tasks[tid].status == from;
				assert(expected, test.name);
				tasks[tid].status = to;
			},
			persistResultText: (int tid, string resultText) {},
			broadcastFocusHint: (int fromTid, int toTid) {},
			addIdleCallback: (int tid, void delegate() cb) {
				assert(tid == 2, test.name);
				idleCallbacks ~= cb;
			},
			reactivateTask: (int tid) {
				assert(tid == 2, test.name);
				reactivationCalls++;
				if (test.failure == DeliveryFailure.reactivateSync)
					throw new Exception(test.failureCause);
				if (test.failure == DeliveryFailure.reactivateRejected)
					return reject!void(new Exception(test.failureCause));
				return reactivationGate is null ? resolve() : reactivationGate;
			},
			hasPendingSubTask: (int tid) => false,
			registerFollowUpBatchChild: (int parentTid, int childTid,
				BatchHandle handle) {},
			cleanupAfterFollowUpAnswerDelivery: (int childTid) {},
			awaitBatchLoop: (int parentTid, ulong batchId) {
				assert(parentTid == 1, test.name);
				assert(batchId > 0, test.name);
				return batchLoop;
			},
			makeInternalBatchError: (string message) => McpResult(message, true),
		);

		BatchRegistry batchRegistry;
		auto router = new QuestionRouter(host, &batchRegistry);
		bool callerResolved;
		string callerPromiseError;
		McpResult callerResult;
		router.handleAsk("1", "follow-up", 2).then((McpResult result) {
			callerResolved = true;
			callerResult = result;
		}, (Exception e) {
			callerPromiseError = e.msg;
		}).ignoreResult();

		BatchHandle batchHandle;
		size_t batchSlot;
		string batchError;
		assert(batchRegistry.findOwnerOfChild(2, batchHandle, batchSlot), test.name);
		assert(batchSlot == 0, test.name);

		Promise!BatchSignal batchEventPromise;
		BatchSignal batchEvent;
		bool receivedBatchEvent;
		if (test.failure != DeliveryFailure.none)
		{
			assert(batchRegistry.waitOne(batchHandle, batchEventPromise, batchError),
				test.name);
			assert(batchError.length == 0, test.name);
			batchEventPromise.then((BatchSignal signal) {
				batchEvent = signal;
				receivedBatchEvent = true;
			}).ignoreResult();
		}

		assert(idleCallbacks.length == test.initialIdleCallbacks, test.name);
		assert(reactivationCalls == test.initialReactivations, test.name);
		assert(sendCalls == test.initialSends, test.name);
		assert(router.questionRoutes_.length == test.routesAfterStart, test.name);

		if (test.invokeIdleCallback)
		{
			auto callback = idleCallbacks[0];
			idleCallbacks = null;
			callback();
		}

		if (test.gateReactivation)
		{
			assert(sendCalls == 0, test.name);
			if (test.assertPreSendInvariant)
				tasks[2].status = TaskStatus.importable;
			reactivationGate.fulfill();
			if (test.assertPreSendInvariant)
			{
				assertThrown!AssertError(drainPromiseNextTicks());
				continue;
			}
		}

		drainPromiseNextTicks();

		if (test.checkDeliveredGate)
		{
			auto qid = router.nextQid_ - 1;
			auto route = qid in router.questionRoutes_;
			assert(route !is null, test.name);
			assert(!(*route).delivered, test.name);
			assert(!callerResolved, test.name);
			sendGate.fulfill();
			drainPromiseNextTicks();
			assert((*route).delivered, test.name);
		}

		assert(callerPromiseError.length == 0, test.name);
		assert(reactivationCalls == test.finalReactivations, test.name);
		assert(sendCalls == test.finalSends, test.name);

		if (test.failure != DeliveryFailure.none)
		{
			assert(callerResolved, test.name);
			assert(callerResult.isError, test.name);
			assert(callerResult.text == test.expectedError, test.name);
			assert(router.questionRoutes_.length == 0, test.name);
			assert(router.pendingQuestions_.length == 0, test.name);
		}
		else
		{
			assert(!callerResolved, test.name);
			assert(router.questionRoutes_.length == 1, test.name);
			assert(router.pendingQuestions_.length == 1, test.name);
		}

		if (test.failure != DeliveryFailure.none)
		{
			assert(receivedBatchEvent, test.name);
			auto consumed = batchRegistry.consume(batchHandle, batchEvent,
				(int childTid, int qid) => false, batchError);
			assert(batchError.length == 0, test.name);
			assert(consumed.kind == BatchConsumeKind.childDone, test.name);
			McpResult[] results;
			assert(batchRegistry.finalize(batchHandle, results, batchError), test.name);
			assert(batchError.length == 0, test.name);
		}
		else
		{
			assert(batchRegistry.remove(batchHandle, batchError), test.name);
			assert(batchError.length == 0, test.name);
			router.failQuestionRoute(router.nextQid_ - 1, "test cleanup");
		}
		batchLoop.fulfill(McpResult("", false));
		drainPromiseNextTicks();
	}
}

// When an answer reaches the asker. In these tests the answerer's turn never
// ends unless a test runs its idle callbacks: that is what an answerer with
// background work running looks like here, since its turn-end handling does
// not drain idle callbacks while the work runs.
unittest
{
	import ae.net.asockets : socketManager;
	import cydo.domain.tasks.model : BatchSignal;
	import std.algorithm : canFind;

	void drainPromiseNextTicks()
	{
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

	struct Fixture
	{
		TaskData[int] tasks;
		void delegate()[] idleCallbacks;
		BatchRegistry batchRegistry;
		QuestionRouter router;
	}

	Fixture* makeFixture(int answererParentTid)
	{
		auto f = new Fixture;
		f.tasks[1] = TaskData(1, "local", "/tmp/question-router-test");
		f.tasks[1].status = TaskStatus.active;
		f.tasks[2] = TaskData(2, "local", "/tmp/question-router-test");
		f.tasks[2].parentTid = answererParentTid;
		f.tasks[2].status = TaskStatus.alive;

		auto host = QuestionRouterHost(
			getTask: (int tid) => tid in f.tasks,
			isTaskAlive: (int tid) => (tid in f.tasks) !is null,
			tasksShareWorkspace: (int aTid, int bTid) => true,
			taskWorkspaceLabel: (int tid) => "local",
			systemKeyword: () => "SYSTEM",
			readPromptFile: (string relativePath, string projectPath,
				string[string] vars) => "",
			buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
				string subject, string[string] vars, string bodyVar) => "{}",
			sendTaskMessage: (int tid, const(ContentBlock)[] content,
				string cydoMeta, string nonce) => resolve(),
			transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
				TaskNotificationChange notification) {
				assert(f.tasks[tid].status == expectedFrom);
				f.tasks[tid].status = to;
			},
			transitionTaskFrom: (int tid, TaskStatus[] expectedFrom,
				TaskStatus to, TaskNotificationChange notification) {
				assert(expectedFrom.canFind(f.tasks[tid].status));
				f.tasks[tid].status = to;
			},
			persistResultText: (int tid, string resultText) {},
			broadcastFocusHint: (int fromTid, int toTid) {},
			addIdleCallback: (int tid, void delegate() cb) {
				assert(tid == 2);
				f.idleCallbacks ~= cb;
			},
			reactivateTask: (int tid) => resolve(),
			hasPendingSubTask: (int tid) => false,
			registerFollowUpBatchChild: (int parentTid, int childTid,
				BatchHandle handle) {},
			cleanupAfterFollowUpAnswerDelivery: (int childTid) {},
			awaitBatchLoop: (int parentTid, ulong batchId) => new Promise!McpResult,
			makeInternalBatchError: (string message) => McpResult(message, true),
		);
		f.router = new QuestionRouter(host, &f.batchRegistry);
		return f;
	}

	// A served request ends at Answer, whatever the answerer's status
	// (`waiting` when it answers in a turn its background work started).
	foreach (answererStatus; [TaskStatus.active, TaskStatus.waiting])
	{
		auto f = makeFixture(0);
		McpResult askerResult;
		bool askerResolved;
		f.router.handleServedRequest(1, "land this", 2).then((McpResult r) {
			askerResult = r;
			askerResolved = true;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(f.tasks[1].status == TaskStatus.waiting);
		assert(f.tasks[2].status == TaskStatus.active);
		auto qid = f.router.nextQid_ - 1;
		assert(f.router.questionRoutes_[qid].delivered);

		f.tasks[2].status = answererStatus;
		McpResult answererResult;
		f.router.handleAnswer("2", qid, "landed").then((McpResult r) {
			answererResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(askerResolved);
		assert(!askerResult.isError);
		assert(askerResult.text.canFind("landed"));
		assert(f.tasks[1].status == TaskStatus.active);
		assert(!answererResult.isError);
		assert(answererResult.text.canFind("delivered"));
		assert(f.tasks[2].status == answererStatus);
		assert(f.idleCallbacks.length == 0);
		assert(f.router.questionRoutes_.length == 0);
		assert(f.router.pendingQuestions_.length == 0);
	}

	// A parent's follow-up to its child is answered when the child goes idle,
	// not at Answer: the child may still be woken by its background work.
	{
		auto f = makeFixture(1);
		f.router.handleAsk("1", "follow-up", 2).ignoreResult();
		drainPromiseNextTicks();
		assert(f.tasks[2].status == TaskStatus.active);
		auto qid = f.router.nextQid_ - 1;

		BatchHandle batchHandle;
		size_t batchSlot;
		assert(f.batchRegistry.findOwnerOfChild(2, batchHandle, batchSlot));
		Promise!BatchSignal batchEventPromise;
		string batchError;
		assert(f.batchRegistry.waitOne(batchHandle, batchEventPromise, batchError));
		bool childDone;
		batchEventPromise.then((BatchSignal signal) { childDone = true; }).ignoreResult();

		McpResult answererResult;
		f.router.handleAnswer("2", qid, "answer").then((McpResult r) {
			answererResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(answererResult.text.canFind("delivered"));
		assert(!childDone);
		assert((qid in f.router.pendingQuestions_) !is null);
		assert(f.tasks[1].status == TaskStatus.waiting);
		assert(f.tasks[2].status == TaskStatus.active);
		assert(f.idleCallbacks.length == 1);

		f.idleCallbacks[0]();
		drainPromiseNextTicks();
		assert(childDone);
		assert(f.router.pendingQuestions_.length == 0);
		assert(f.tasks[1].status == TaskStatus.active);
		assert(f.tasks[2].status == TaskStatus.completed);
	}
}
