module cydo.question_router;

import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.logger : errorf;

import ae.utils.json : toJson;
import ae.utils.promise : Promise, resolve;

import cydo.agent.protocol : AnswerResult, ContentBlock, QuestionResult;
import cydo.batchregistry : BatchHandle, BatchRegistry;
import cydo.mcp : McpResult;
import cydo.system.known_messages : KnownSystemMessageKind, followUpFromParentSubject,
	questionFromTaskSubject, wrapKnownSystemMessage;
import cydo.task : TaskData;
import cydo.text.title : truncateTitle;

package(cydo):

enum QuestionDelivery { batchQuestion, injectedMessage }
enum QuestionWait { directPromise, batchLoop }
enum QuestionAfterAnswer
{
	continueBatch,
	completeAnswererOnIdle,
	leaveAnswererAlive,
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
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	string delegate() systemKeyword;
	string delegate(string relativePath, string projectPath,
		string[string] vars) readPromptFile;
	string delegate(KnownSystemMessageKind kind, string subject,
		string[string] vars, string bodyVar) buildKnownSystemMessageMeta;
	void delegate(int tid, const(ContentBlock)[] content, string cydoMeta,
		string nonce) sendTaskMessage;
	void delegate(int tid, string status) persistStatus;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid) broadcastTaskUpdate;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, void delegate() cb) addIdleCallback;
	void delegate(int tid, void delegate() onReady) reactivateTask;
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
			bool done;
			string batchError;
			if (!batchRegistry_.findOwnerOfChild(callerTidInt, ownerHandle, slot,
				done, batchError))
			{
				return resolve(host_.makeInternalBatchError(
					format!"no active batch owning child tid=%d while asking parent tid=%d"
						(callerTidInt, targetTid)));
			}
			if (batchError.length > 0)
				return resolve(host_.makeInternalBatchError(batchError));
			if (ownerHandle.parentTid != targetTid)
			{
				return resolve(host_.makeInternalBatchError(
					format!"child tid=%d routed to parent tid=%d but is owned by parent tid=%d batch=%s"
						(callerTidInt, targetTid, ownerHandle.parentTid, ownerHandle.batchId)));
			}
			if (done)
			{
				return resolve(host_.makeInternalBatchError(
					format!"child tid=%d owned by completed slot while asking parent tid=%d batch=%s"
						(callerTidInt, targetTid, ownerHandle.batchId)));
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
			bool childDone;
			if (batchRegistry_.findOwnerOfChild(targetTid, batchHandle, childSlot,
				childDone, batchError))
			{
				if (batchError.length > 0)
					return resolve(host_.makeInternalBatchError(batchError));
				if (batchHandle.parentTid != callerTidInt)
				{
					return resolve(host_.makeInternalBatchError(
						format!"child tid=%d owned by parent tid=%d batch=%s, cannot reuse for parent tid=%d"
							(targetTid, batchHandle.parentTid, batchHandle.batchId, callerTidInt)));
				}
				if (!childDone)
				{
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
				(*questionPromise).fulfill(McpResult.structured(answerJson));
				clearQuestionRoute(qid);

				auto askerTd = host_.getTask(route.askerTid);
				if (askerTd !is null)
				{
					askerTd.status = "active";
					askerTd.notificationBody = "";
					host_.persistStatus(route.askerTid, "active");
					host_.broadcastTaskUpdate(route.askerTid);
				}

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
		if (body.length == 0)
			body = message ~ "\n\nAnswer with Answer(" ~ to!string(qid)
				~ ", \"your response\").";
		return wrapKnownSystemMessage(host_.systemKeyword(),
			KnownSystemMessageKind.questionFromTask, body, subject);
	}

	void deliverInjectedQuestion(QuestionRoute route, string message)
	{
		auto sendQuestion = (QuestionRoute currentRoute) {
			if (currentRoute.qid !in questionRoutes_)
				return;

			auto currentAnswerer = host_.getTask(currentRoute.answererTid);
			if (currentAnswerer is null || !currentAnswerer.alive)
			{
				failQuestionRoute(currentRoute.qid,
					"Session ended while waiting for Ask response");
				return;
			}

			currentAnswerer.status = "active";
			host_.persistStatus(currentRoute.answererTid, "active");
			host_.broadcastTaskUpdate(currentRoute.answererTid);
			host_.broadcastFocusHint(currentRoute.askerTid, currentRoute.answererTid);

			string prompt;
			string meta;
			string promptNonce;
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
				if (followUpBody.length == 0)
				{
					followUpBody = message
						~ "\n\nAnswer with mcp__cydo__Answer("
						~ to!string(currentRoute.qid) ~ ", \"your response\").";
				}
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
			host_.sendTaskMessage(currentRoute.answererTid,
				[ContentBlock("text", prompt)], meta, promptNonce);

			if (auto routePtr = currentRoute.qid in questionRoutes_)
				(*routePtr).delivered = true;
		};

		if (host_.getTask(route.answererTid) is null)
		{
			failQuestionRoute(route.qid,
				"Target task not found: " ~ to!string(route.answererTid));
			return;
		}

		auto answererTd = host_.getTask(route.answererTid);
		if (answererTd.status == "waiting")
		{
			host_.addIdleCallback(route.answererTid, () {
				auto routePtr = route.qid in questionRoutes_;
				if (routePtr is null)
					return;
				auto currentAnswerer = host_.getTask((*routePtr).answererTid);
				if (currentAnswerer is null || !currentAnswerer.alive)
				{
					failQuestionRoute((*routePtr).qid,
						"Session ended while waiting for Ask response");
					return;
				}
				sendQuestion(*routePtr);
			});
			return;
		}

		host_.reactivateTask(route.answererTid, () {
			auto routePtr = route.qid in questionRoutes_;
			if (routePtr is null)
				return;
			sendQuestion(*routePtr);
		});
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
			if (answererTd is null || !answererTd.alive)
			{
				failQuestionRoute(currentRoute.qid,
					"Session ended while waiting for Ask response");
				return;
			}

			if (auto qp = currentRoute.qid in pendingQuestions_)
				(*qp).fulfill(answerResult);

			if (currentRoute.afterAnswer
				== QuestionAfterAnswer.completeAnswererOnIdle)
			{
				answererTd.status = "completed";
				host_.persistStatus(currentRoute.answererTid, "completed");
				host_.persistResultText(currentRoute.answererTid,
					answererTd.resultText);
				host_.broadcastTaskUpdate(currentRoute.answererTid);
				host_.cleanupAfterFollowUpAnswerDelivery(
					currentRoute.answererTid);
				host_.broadcastFocusHint(currentRoute.answererTid,
					currentRoute.askerTid);
				clearQuestionRoute(currentRoute.qid);
				return;
			}

			auto askerTd = host_.getTask(currentRoute.askerTid);
			if (askerTd !is null)
			{
				askerTd.status = "active";
				askerTd.notificationBody = "";
				host_.persistStatus(currentRoute.askerTid, "active");
				host_.broadcastTaskUpdate(currentRoute.askerTid);
			}
			if (currentRoute.afterAnswer
				== QuestionAfterAnswer.leaveAnswererAlive)
			{
				answererTd.status = "alive";
				host_.persistStatus(currentRoute.answererTid, "alive");
				host_.broadcastTaskUpdate(currentRoute.answererTid);
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

		if (currentRoute.wait == QuestionWait.batchLoop)
		{
			auto handle = BatchHandle(currentRoute.askerTid, currentRoute.batchId);
			auto slot = currentRoute.batchSlot;
			auto childTid = currentRoute.batchChildTid;
			promise.then((McpResult r) {
				string error;
				if (!batchRegistry_.enqueueChildDone(handle, slot, childTid, r, error))
					errorf("batch router error: %s", error);
				clearQuestionRoute(qid);
			});
		}

		auto askerTd = host_.getTask(currentRoute.askerTid);
		if (askerTd !is null)
		{
			askerTd.status = "waiting";
			if (currentRoute.afterAnswer == QuestionAfterAnswer.continueBatch)
			{
				askerTd.notificationBody = "Asking parent: "
					~ truncateTitle(message, 100);
			}
			else if (currentRoute.afterAnswer
				== QuestionAfterAnswer.leaveAnswererAlive)
			{
				askerTd.notificationBody = "Asking task "
					~ to!string(currentRoute.answererTid)
					~ ": " ~ truncateTitle(message, 100);
			}
			host_.persistStatus(currentRoute.askerTid, "waiting");
			host_.broadcastTaskUpdate(currentRoute.askerTid);
		}

		host_.broadcastFocusHint(currentRoute.askerTid, currentRoute.answererTid);

		if (currentRoute.delivery == QuestionDelivery.batchQuestion)
		{
			string error;
			if (!batchRegistry_.enqueueQuestion(
				BatchHandle(currentRoute.answererTid, currentRoute.batchId),
				currentRoute.batchSlot,
				currentRoute.batchChildTid,
				message,
				currentRoute.qid,
				error))
				return resolve(host_.makeInternalBatchError(error));
		}
		else
			deliverInjectedQuestion(currentRoute, message);

		if (currentRoute.wait == QuestionWait.batchLoop)
			return host_.awaitBatchLoop(currentRoute.askerTid, currentRoute.batchId);
		return promise;
	}
}
