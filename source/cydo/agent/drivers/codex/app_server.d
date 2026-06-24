module cydo.agent.drivers.codex.app_server;

import ae.net.jsonrpc.binding : RPCName, RPCNamedParams;
import ae.utils.json : JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, resolve;

import cydo.agent.drivers.codex.rpc;
import cydo.protocol : SessionCompactedEvent, TranslatedEvent;

package struct CodexSessionRouteTarget
{
	void delegate(ItemStartedParams, string) handleItemStarted;
	void delegate(DeltaParams, string, string) handleDelta;
	void delegate(TerminalInteractionParams, string) handleTerminalInteraction;
	void delegate(ItemCompletedParams, string) handleItemCompleted;
	void delegate(string) handleTurnCompleted;
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
	Promise!void turnCompleted(ThreadIdParams params);

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
}

// ---------------------------------------------------------------------------
// CodexServerRouter — routes incoming Codex notifications to sessions.
// ---------------------------------------------------------------------------

private string buildRawNotification(string method, string paramsJson)
{
	return `{"jsonrpc":"2.0","method":"` ~ method ~ `","params":` ~ paramsJson ~ `}`;
}

private string extractErrorMessage(ErrorParams params)
{
	string message;
	if (params.error)
	{
		@JSONPartial static struct ErrorInfo { @JSONOptional string message; }
		try { message = jsonParse!ErrorInfo(toJson(params.error)).message; }
		catch (Exception) {}
	}
	return message;
}

private TranslatedEvent makeAgentErrorTranslatedEvent(ErrorParams params)
{
	import cydo.protocol : AgentErrorEvent;

	AgentErrorEvent ev;
	ev.message = extractErrorMessage(params);
	ev.willRetry = params.willRetry;
	return TranslatedEvent(toJson(ev), buildRawNotification("error", toJson(params)));
}

private TranslatedEvent makeAgentWarningTranslatedEvent(WarningParams params)
{
	import cydo.protocol : AgentWarningEvent;

	AgentWarningEvent ev;
	ev.message = params.message;
	return TranslatedEvent(toJson(ev), buildRawNotification("warning", toJson(params)));
}

unittest
{
	@JSONPartial
	struct EmittedWarningEvent
	{
		string type;
		string message;
	}

	WarningParams params;
	params.threadId = "thread-warning";
	params.turnId = "turn-warning";
	params.message =
		"Heads up: Long threads and multiple compactions can cause the model to be less accurate.";

	auto translated = makeAgentWarningTranslatedEvent(params);
	auto ev = jsonParse!EmittedWarningEvent(translated.translated);

	assert(ev.type == "agent/warning");
	assert(ev.message
		== "Heads up: Long threads and multiple compactions can cause the model to be less accurate.");
	assert(translated.raw
		== `{"jsonrpc":"2.0","method":"warning","params":{"threadId":"thread-warning","turnId":"turn-warning","message":"Heads up: Long threads and multiple compactions can cause the model to be less accurate."}}`);
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

	Promise!void turnCompleted(ThreadIdParams params)
	{
		auto raw = buildRawNotification("turn/completed", toJson(params));
		routeToSession(params.threadId,
			(session) => session.handleTurnCompleted(raw));
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
	if (method.length >= 12 && method[0 .. 12] == "codex/event/")
		return true;
	// Codex app-server emits MCP startup status updates that are not useful
	// for CyDo's translated session stream.
	return method == "mcpServer/startupStatus/updated";
}

unittest
{
	assert(isSilentlyIgnoredCodexNotificationMethod("codex/event/item.started"));
	assert(isSilentlyIgnoredCodexNotificationMethod("mcpServer/startupStatus/updated"));
	assert(!isSilentlyIgnoredCodexNotificationMethod("mcpServer/other"));
}
