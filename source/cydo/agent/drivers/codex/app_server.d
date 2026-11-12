module cydo.agent.drivers.codex.app_server;

import ae.net.jsonrpc.binding : RPCName, RPCNamedParams;
import ae.utils.json : JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, resolve;

import cydo.agent.drivers.codex.rpc;
import cydo.protocol : SessionCompactedEvent, TaskDiagnosticEvent,
	TaskDiagnosticSeverity, TranslatedEvent;

package struct CodexSessionRouteTarget
{
	void delegate(ItemStartedParams, string) handleItemStarted;
	void delegate(DeltaParams, string, string) handleDelta;
	void delegate(TerminalInteractionParams, string) handleTerminalInteraction;
	void delegate(ItemCompletedParams, string) handleItemCompleted;
	void delegate(TurnCompletedParams, string) handleTurnCompleted;
	void delegate(TurnRef) handleTurnStarted;
	void delegate(TokenUsageUpdatedParams, string) handleTokenUsageUpdated;
	void delegate(int) onServerExit;
	void delegate(string) emitStderr;
	void delegate(TranslatedEvent) emitTranslatedEvent;

	@property bool valid() const
	{
		return emitTranslatedEvent !is null;
	}
}

package struct CodexServerOwner
{
	CodexSessionRouteTarget delegate(string) sessionForThread;
	CodexSessionRouteTarget[] delegate() allSessions;
	void delegate() onLoginCompleted;
}

// ---------------------------------------------------------------------------
// ICodexServer — methods Codex app-server calls on CyDo.
// ---------------------------------------------------------------------------

@RPCNamedParams
package interface ICodexServer
{
	@RPCName("item/started")
	Promise!void itemStarted(ItemStartedParams params);

	@RPCName("item/agentMessage/delta")
	Promise!void itemAgentMessageDelta(DeltaParams params);

	@RPCName("item/reasoning/textDelta")
	Promise!void itemReasoningTextDelta(DeltaParams params);

	@RPCName("item/reasoning/summaryTextDelta")
	Promise!void itemReasoningSummaryTextDelta(DeltaParams params);

	@RPCName("item/reasoning/summaryPartAdded")
	Promise!void itemReasoningSummaryPartAdded(IgnoredParams params);

	@RPCName("item/commandExecution/outputDelta")
	Promise!void itemCommandExecutionOutputDelta(DeltaParams params);

	@RPCName("item/commandExecution/terminalInteraction")
	Promise!void itemCommandExecutionTerminalInteraction(TerminalInteractionParams params);

	@RPCName("item/completed")
	Promise!void itemCompleted(ItemCompletedParams params);

	@RPCName("turn/completed")
	Promise!void turnCompleted(TurnCompletedParams params);

	@RPCName("thread/compacted")
	Promise!void threadCompacted(ThreadIdParams params);

	@RPCName("thread/started")
	Promise!void threadStarted(IgnoredParams params);

	@RPCName("thread/status/changed")
	Promise!void threadStatusChanged(IgnoredParams params);

	@RPCName("turn/started")
	Promise!void turnStarted(TurnStartedParams params);

	@RPCName("turn/diff/updated")
	Promise!void turnDiffUpdated(TurnDiffUpdatedParams params);

	@RPCName("thread/tokenUsage/updated")
	Promise!void threadTokenUsageUpdated(TokenUsageUpdatedParams params);

	@RPCName("account/rateLimits/updated")
	Promise!void accountRateLimitsUpdated(IgnoredParams params);

	@RPCName("account/updated")
	Promise!void accountUpdated(IgnoredParams params);

	@RPCName("account/login/completed")
	Promise!void accountLoginCompleted();

	@RPCName("item/commandExecution/requestApproval")
	Promise!ApprovalDecision commandExecutionApproval(ItemStartedParams params);

	@RPCName("item/fileChange/requestApproval")
	Promise!ApprovalDecision fileChangeApproval(ItemStartedParams params);

	@RPCName("item/fileChange/outputDelta")
	Promise!void itemFileChangeOutputDelta(DeltaParams params);

	@RPCName("error")
	Promise!void error(ErrorParams params);

	@RPCName("warning")
	Promise!void warning(WarningParams params);

	@RPCName("deprecationNotice")
	Promise!void deprecationNotice(NoticeParams params);

	@RPCName("configWarning")
	Promise!void configWarning(NoticeParams params);
}

// ---------------------------------------------------------------------------
// CodexServerRouter — routes incoming Codex notifications to sessions.
// ---------------------------------------------------------------------------

private string buildRawNotification(string method, string paramsJson)
{
	return `{"jsonrpc":"2.0","method":"` ~ method ~ `","params":` ~ paramsJson ~ `}`;
}

package string extractCodexErrorMessage(SO error)
{
	string message;
	if (error)
	{
		@JSONPartial static struct ErrorInfo { @JSONOptional string message; }
		try { message = jsonParse!ErrorInfo(toJson(error)).message; }
		catch (Exception) {}
	}
	return message;
}

private TranslatedEvent makeAgentErrorTranslatedEvent(ErrorParams params)
{
	TaskDiagnosticEvent ev;
	ev.severity = params.willRetry ? TaskDiagnosticSeverity.warning : TaskDiagnosticSeverity.error;
	ev.subject = params.willRetry ? "Agent error (retrying)" : "Agent error";
	ev.body = extractCodexErrorMessage(params.error);
	if (ev.body.length == 0)
		ev.body = "Unknown error";
	return TranslatedEvent(toJson(ev), buildRawNotification("error", toJson(params)));
}

private TranslatedEvent makeAgentWarningTranslatedEvent(WarningParams params)
{
	TaskDiagnosticEvent ev;
	ev.severity = TaskDiagnosticSeverity.warning;
	ev.subject = "Agent warning";
	ev.body = params.message;
	return TranslatedEvent(toJson(ev), buildRawNotification("warning", toJson(params)));
}

private TranslatedEvent makeAgentNoticeTranslatedEvent(string method, string subject,
	NoticeParams params)
{
	TaskDiagnosticEvent ev;
	ev.severity = TaskDiagnosticSeverity.warning;
	ev.subject = subject;
	ev.body = params.summary;
	if (params.details.length > 0)
		ev.body ~= "\n\n" ~ params.details;
	if (params.path.length > 0)
		ev.body ~= "\n\nIn `" ~ params.path ~ "`.";
	return TranslatedEvent(toJson(ev), buildRawNotification(method, toJson(params)));
}

unittest
{
	auto params = jsonParse!NoticeParams(
		`{"summary":"thread/rollback is deprecated and will be removed soon","details":null}`);
	auto translated = makeAgentNoticeTranslatedEvent("deprecationNotice", "Agent deprecation notice", params);
	assert(translated.translated == `{"type":"cydo/task_diagnostic","severity":"warning",`
		~ `"subject":"Agent deprecation notice","body":"thread/rollback is deprecated and will be removed soon"}`,
		translated.translated);
	assert(translated.raw == `{"jsonrpc":"2.0","method":"deprecationNotice","params":`
		~ `{"summary":"thread/rollback is deprecated and will be removed soon"}}`, translated.raw);
}

unittest
{
	@JSONPartial
	struct EmittedWarningEvent
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	WarningParams params;
	params.threadId = "thread-warning";
	params.turnId = "turn-warning";
	params.message =
		"Heads up: Long threads and multiple compactions can cause the model to be less accurate.";

	auto translated = makeAgentWarningTranslatedEvent(params);
	auto ev = jsonParse!EmittedWarningEvent(translated.translated);

	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent warning");
	assert(ev.body
		== "Heads up: Long threads and multiple compactions can cause the model to be less accurate.");
	assert(translated.raw
		== `{"jsonrpc":"2.0","method":"warning","params":{"threadId":"thread-warning","turnId":"turn-warning","message":"Heads up: Long threads and multiple compactions can cause the model to be less accurate."}}`);
}

unittest
{
	@JSONPartial struct EmittedErrorEvent
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	auto retrying = jsonParse!ErrorParams(
		`{"threadId":"thread-retrying","willRetry":true,"error":{"message":"try again"}}`);
	auto retryingEvent = makeAgentErrorTranslatedEvent(retrying);
	auto ev = jsonParse!EmittedErrorEvent(retryingEvent.translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "try again");
	assert(retryingEvent.raw
		== `{"jsonrpc":"2.0","method":"error","params":{"threadId":"thread-retrying","willRetry":true,"error":{"message":"try again"}}}`);

	auto terminal = jsonParse!ErrorParams(
		`{"threadId":"thread-terminal","willRetry":false,"error":{"message":"do not retry"}}`);
	auto terminalEvent = makeAgentErrorTranslatedEvent(terminal);
	ev = jsonParse!EmittedErrorEvent(terminalEvent.translated);
	assert(ev.severity == "error");
	assert(ev.subject == "Agent error");
	assert(ev.body == "do not retry");
	assert(terminalEvent.raw
		== `{"jsonrpc":"2.0","method":"error","params":{"threadId":"thread-terminal","error":{"message":"do not retry"}}}`);

	auto unspecified = jsonParse!ErrorParams(
		`{"threadId":"thread-unspecified","error":{"message":"still terminal"}}`);
	ev = jsonParse!EmittedErrorEvent(makeAgentErrorTranslatedEvent(unspecified).translated);
	assert(ev.severity == "error");
	assert(ev.subject == "Agent error");
	assert(ev.body == "still terminal");

	auto missingMessage = jsonParse!ErrorParams(
		`{"threadId":"thread-missing","willRetry":false,"error":{}}`);
	ev = jsonParse!EmittedErrorEvent(makeAgentErrorTranslatedEvent(missingMessage).translated);
	assert(ev.severity == "error");
	assert(ev.subject == "Agent error");
	assert(ev.body == "Unknown error");

	TranslatedEvent[] threadEvents;
	TranslatedEvent[] allEvents;
	CodexSessionRouteTarget threadTarget;
	threadTarget.emitTranslatedEvent = (TranslatedEvent event) {
		threadEvents ~= event;
	};
	CodexSessionRouteTarget allTarget;
	allTarget.emitTranslatedEvent = (TranslatedEvent event) {
		allEvents ~= event;
	};
	CodexServerOwner owner;
	owner.sessionForThread = (string threadId) {
		assert(threadId == "thread-terminal");
		return threadTarget;
	};
	owner.allSessions = () => [threadTarget, allTarget];
	auto router = new CodexServerRouter(owner);
	router.error(terminal);
	assert(threadEvents.length == 1);
	assert(allEvents.length == 0);
	assert(threadEvents[0].raw == terminalEvent.raw);

	auto broadcast = jsonParse!ErrorParams(
		`{"error":{"message":"broadcast error"}}`);
	router.error(broadcast);
	assert(threadEvents.length == 2);
	assert(allEvents.length == 1);
	assert(threadEvents[1].raw
		== `{"jsonrpc":"2.0","method":"error","params":{"error":{"message":"broadcast error"}}}`);
	assert(allEvents[0].raw == threadEvents[1].raw);
}

package class CodexServerRouter : ICodexServer
{
	private CodexServerOwner owner;

	this(CodexServerOwner owner)
	{
		this.owner = owner;
	}

	private void routeToSession(string threadId,
		scope void delegate(CodexSessionRouteTarget) handler)
	{
		auto session = owner.sessionForThread(threadId);
		if (session.valid)
			handler(session);
	}

	private void emitToThreadOrAll(string threadId, TranslatedEvent tev)
	{
		if (threadId.length > 0)
			routeToSession(threadId, (session) => session.emitTranslatedEvent(tev));
		else
			foreach (session; owner.allSessions())
				session.emitTranslatedEvent(tev);
	}

	Promise!void itemStarted(ItemStartedParams params)
	{
		auto raw = buildRawNotification("item/started", toJson(params));
		routeToSession(params.threadId, (session) => session.handleItemStarted(params, raw));
		return resolve();
	}

	Promise!void itemAgentMessageDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/agentMessage/delta", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleDelta(params, "text_delta", raw));
		return resolve();
	}

	Promise!void itemReasoningTextDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/reasoning/textDelta", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleDelta(params, "thinking_delta", raw));
		return resolve();
	}

	Promise!void itemReasoningSummaryTextDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/reasoning/summaryTextDelta", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleDelta(params, "thinking_delta", raw));
		return resolve();
	}

	Promise!void itemCommandExecutionOutputDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/commandExecution/outputDelta", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleDelta(params, "output_delta", raw));
		return resolve();
	}

	Promise!void itemFileChangeOutputDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/fileChange/outputDelta", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleDelta(params, "output_delta", raw));
		return resolve();
	}

	Promise!void itemCommandExecutionTerminalInteraction(TerminalInteractionParams params)
	{
		auto raw = buildRawNotification("item/commandExecution/terminalInteraction", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleTerminalInteraction(params, raw));
		return resolve();
	}

	Promise!void itemCompleted(ItemCompletedParams params)
	{
		auto raw = buildRawNotification("item/completed", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleItemCompleted(params, raw));
		return resolve();
	}

	Promise!void turnCompleted(TurnCompletedParams params)
	{
		auto raw = buildRawNotification("turn/completed", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleTurnCompleted(params, raw));
		return resolve();
	}

	Promise!void threadStarted(IgnoredParams params) { return resolve(); }
	Promise!void threadStatusChanged(IgnoredParams params) { return resolve(); }

	Promise!void turnStarted(TurnStartedParams params)
	{
		routeToSession(params.threadId,
			(session) => session.handleTurnStarted(params.turn));
		return resolve();
	}

	Promise!void itemReasoningSummaryPartAdded(IgnoredParams) { return resolve(); }
	Promise!void turnDiffUpdated(TurnDiffUpdatedParams params) { return resolve(); }

	Promise!void threadTokenUsageUpdated(TokenUsageUpdatedParams params)
	{
		auto raw = buildRawNotification("thread/tokenUsage/updated", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleTokenUsageUpdated(params, raw));
		return resolve();
	}

	Promise!void accountRateLimitsUpdated(IgnoredParams params) { return resolve(); }
	Promise!void accountUpdated(IgnoredParams params) { return resolve(); }

	Promise!void error(ErrorParams params)
	{
		emitToThreadOrAll(params.threadId, makeAgentErrorTranslatedEvent(params));
		return resolve();
	}

	Promise!void warning(WarningParams params)
	{
		emitToThreadOrAll(params.threadId, makeAgentWarningTranslatedEvent(params));
		return resolve();
	}

	Promise!void deprecationNotice(NoticeParams params)
	{
		emitToThreadOrAll(null, makeAgentNoticeTranslatedEvent("deprecationNotice",
			"Agent deprecation notice", params));
		return resolve();
	}

	Promise!void configWarning(NoticeParams params)
	{
		emitToThreadOrAll(null, makeAgentNoticeTranslatedEvent("configWarning",
			"Agent configuration warning", params));
		return resolve();
	}

	Promise!void threadCompacted(ThreadIdParams params)
	{
		auto raw = buildRawNotification("thread/compacted", toJson(params));
		routeToSession(params.threadId, (session) {
			session.emitTranslatedEvent(TranslatedEvent(toJson(SessionCompactedEvent()), raw));
		});
		return resolve();
	}

	Promise!void accountLoginCompleted()
	{
		owner.onLoginCompleted();
		return resolve();
	}

	Promise!ApprovalDecision commandExecutionApproval(ItemStartedParams params)
	{
		return resolve(ApprovalDecision("acceptForSession"));
	}

	Promise!ApprovalDecision fileChangeApproval(ItemStartedParams params)
	{
		return resolve(ApprovalDecision("acceptForSession"));
	}
}

package bool isSilentlyIgnoredCodexNotificationMethod(string method)
{
	// v1 legacy notifications duplicate v2 item/* / turn/* methods.
	// (Notifications CyDo has no use for at all are opted out of at
	// initialize instead.)
	return method.length >= 12 && method[0 .. 12] == "codex/event/";
}

unittest
{
	assert(isSilentlyIgnoredCodexNotificationMethod("codex/event/item.started"));
	assert(!isSilentlyIgnoredCodexNotificationMethod("mcpServer/other"));
}
