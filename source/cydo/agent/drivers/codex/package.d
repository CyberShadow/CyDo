module cydo.agent.drivers.codex;

import core.time : Duration, seconds;

import std.conv : to;
import std.exception : enforce;
import std.logger : errorf, tracef, warningf;
import std.path : buildPath, dirName, isAbsolute;
import std.typecons : Nullable;

import ae.sys.data : Data;
import ae.sys.timing : setTimeout, TimerTask;
import ae.utils.time.types : AbsTime;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);
import ae.utils.promise : Promise, resolve;
import ae.net.asockets : onNextTick, socketManager;

version (unittest) import ae.net.asockets : ConnectionState, DisconnectType,
	IConnection;
version (unittest) import ae.utils.jsonrpc : JsonRpcRequest;

import cydo.foundation.system.framing : isSystemFramed;
import cydo.agent.contract : Agent, HistoryReplay, DiscoveredSession, DriverHistory, DriverHistoryLaunch,
	DriverServedHistoryAgent, InterruptedToolCallRepair,
	PersistedHistoryBoundary, OneShotHandle, RewindResult, SessionConfig,
	SessionMeta;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.drivers.codex.app_server : CodexSessionRouteTarget;
import cydo.agent.drivers.codex.history : readThreadHistory;
public import cydo.agent.drivers.codex.process : AppServerProcess;
import cydo.agent.drivers.codex.user_message : isCodexContextualFragment, isCodexPermissionsInstructionsText;
public import cydo.agent.drivers.codex.rollout;
public import cydo.agent.drivers.codex.rpc;
public import cydo.agent.drivers.codex.thread_items;
import cydo.protocol : ContentBlock, HistoryBoundary, HistoryBoundaryKind,
	ProcessStderrEvent, TranslatedEvent;
import cydo.agent.session : AbortedToolCallCorrection, AgentSession,
	AgentSubmissionReceipt, BackgroundWork, MessageSource, SubmissionHistoryCancelled;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;
import cydo.runtime.launch.sandbox : cleanup, cydoBinaryDir, cydoBinaryPath, effectiveEnvValue,
	executableMountPaths, resolveExecutablePath;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.foundation.text.title : truncateTitle;

// ---------------------------------------------------------------------------
// CodexAgent — Agent descriptor for OpenAI Codex CLI.
// ---------------------------------------------------------------------------

struct ThreadForkOutcome
{
	bool ok;
	string threadId;
	string rawResultJson;
	string error;
}

/// A real, private source-thread owner used only to issue a native fork after
/// the normal task session has been stopped. It is route-ready only after the
/// app server has registered the exact resumed thread route.
final class CodexForkSourceOwner
{
private:
	CodexSession session_;
	string sourceThreadId_;
	Promise!CodexSession routeReady_;
	bool routeReadySettled_;
	bool closing_;
	bool closed_;
	void delegate() closedHandler_;

public:
	this(CodexSession session, string sourceThreadId)
	{
		enforce(session !is null,
			"Codex fork source owner requires a Codex session");
		enforce(sourceThreadId.length > 0,
			"Codex fork source owner requires a source thread ID");
		session_ = session;
		sourceThreadId_ = sourceThreadId;
		routeReady_ = new Promise!CodexSession;
		session_.onRouteReady = {
			if (routeReadySettled_)
				return;
			try
			{
				enforce(session_.alive,
					"Codex fork source owner exited before its route was ready");
				enforce(session_.currentThreadId == sourceThreadId_,
					"Codex fork source owner resumed a different thread");
				routeReadySettled_ = true;
				routeReady_.fulfill(session_);
			}
			catch (Exception e)
			{
				routeReadySettled_ = true;
				routeReady_.reject(e);
				closeStdin();
			}
		};
		session_.onExit = (int) {
			if (!routeReadySettled_)
			{
				routeReadySettled_ = true;
				routeReady_.reject(session_.threadStartError_ is null
					? new Exception("Codex fork source owner exited before its route was ready")
					: session_.threadStartError_);
			}
			notifyClosed();
		};
	}

	@property Promise!CodexSession routeReady() { return routeReady_; }

	void closeStdin()
	{
		if (closed_ || closing_ || session_.server.dead)
			return;
		closing_ = true;
		if (!routeReadySettled_)
		{
			routeReadySettled_ = true;
			routeReady_.reject(new Exception(
				"Codex fork source owner closed before its route was ready"));
		}
		session_.closeStdin();
	}

	@property void onClosed(void delegate() handler)
	{
		closedHandler_ = handler;
		if (closed_ && closedHandler_)
			closedHandler_();
	}

private:
	void notifyClosed()
	{
		if (closed_)
			return;
		closed_ = true;
		if (closedHandler_)
			closedHandler_();
	}
}

private enum RouteOwnerKind { task, forkOperation }

class CodexAgent : DriverServedHistoryAgent
{
	private AppServerProcess[string] serverPool; // keyed by workspace+sandbox signature
	private AppServerStartupGate[string] appServerStartupGates;
	private ModelSpec[string] modelAliasOverrides;
	private string systemKeyword_;
	private string lastMcpConfigPath_;
	HistoryReplay createHistoryReplay()
	{
		bool seenTaskStarted;
		return HistoryReplay((line, lineNum) {
			auto evidence = parseRolloutLineEvidence(line, lineNum);
			return translateLegacyRolloutLine(line, evidence, seenTaskStarted);
		});
	}

	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		import std.process : environment;

		auto codexPath = resolveExecutablePath(executableName(env), env);
		foreach (path; executableMountPaths(codexPath))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "codex",
					"Codex executable"));
		auto home = environment.get("HOME", "/tmp");
		if (dirName(codexPath) == home ~ "/.npm-packages/bin")
			paths.requireReadVisible(home ~ "/.npm-packages",
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "codex",
					"Codex npm package root"));

		// Pass through Codex-required env vars so they survive --clearenv
		void passthrough(string key)
		{
			if (key in env)
				return;
			auto val = environment.get(key, "");
			if (val.length > 0)
				env[key] = val;
		}

		passthrough("PATH");
		passthrough("OPENAI_API_KEY");
		passthrough("OPENAI_BASE_URL");
		passthrough("CODEX_API_KEY");
	}

	@property string gitName() { return "Codex CLI"; }
	@property string gitEmail() { return "noreply@openai.com"; }
	override @property AgentDriver driver() { return AgentDriver.codex; }
	override @property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	}
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_CODEX_BIN", "codex");
	}

	private string serverPoolKey(string workspace, ProcessLaunch launch)
	{
		import std.regex : regex, replaceAll;
		auto prefixSig = launch.cmdPrefix is null ? "[]" : toJson(launch.cmdPrefix);
		// Task-local scratch paths differ by tid but are safe to share across
		// Codex threads in the same workspace; ignore only that variance.
		prefixSig = replaceAll(prefixSig, regex(`/\.cydo\/tasks\/\d+/`), "/.cydo/tasks/*");
		return workspace ~ "\n" ~ launch.executablePath ~ "\n" ~ prefixSig;
	}

	private static string buildDeveloperInstructions()
	{
		string devInstructions = "IMPORTANT: Do NOT use the following tools: "
			~ "spawn_agent,update_plan,request_user_input"
			~ ". If you attempt to use them, they will fail.";
		return devInstructions;
	}

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, launch), launch);
		auto session = makeSession(server, tid, config, RouteOwnerKind.task);
		beginSession(server, session, tid, resumeSessionId, launch, config);
		return session;
	}

	/// Resume a stopped source thread into a private owner used exclusively by
	/// one native fork. The caller owns closeStdin after the fork continuation.
	package(cydo) CodexForkSourceOwner openForkSourceOwner(int sourceTid,
		string sourceThreadId, ProcessLaunch launch, SessionConfig config)
	{
		enforce(sourceTid >= 0,
			"Codex fork source owner requires a task ID");
		enforce(sourceThreadId.length > 0,
			"Codex fork source owner requires a source thread ID");
		enforce(launch.nativeHistoryProfile.driver == driver,
			"Codex fork source owner requires a Codex launch profile");
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, launch), launch);
		auto routeTid = server.reserveOperationRouteTid();
		CodexSession session;
		CodexForkSourceOwner owner;
		try
		{
			session = makeSession(server, routeTid, config,
				RouteOwnerKind.forkOperation);
			owner = new CodexForkSourceOwner(session, sourceThreadId);
			beginSession(server, session, sourceTid, sourceThreadId, launch, config);
			return owner;
		}
		catch (Exception e)
		{
			if (owner !is null)
				owner.closeStdin();
			else if (session !is null)
				session.closeStdin();
			else
				server.cancelOperationRouteReservation(routeTid);
			throw e;
		}
	}

	private CodexSession makeSession(AppServerProcess server, int routeTid,
		SessionConfig config, RouteOwnerKind ownerKind)
	{
		auto session = new CodexSession(server, routeTid, config, systemKeyword_);
		final switch (ownerKind)
		{
		case RouteOwnerKind.task:
			server.registerSessionByTid(routeTid, session.asRouteTarget());
			break;
		case RouteOwnerKind.forkOperation:
			server.registerOperationSessionByTid(routeTid, session.asRouteTarget());
			break;
		}
		return session;
	}

	private void beginSession(AppServerProcess server, CodexSession session,
		int mcpTid, string resumeSessionId, ProcessLaunch launch, SessionConfig config)
	{

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");
		auto devInstructions = buildDeveloperInstructions();

		// Build config override (reasoning summary + MCP tools).
		auto configOverride = buildConfigOverride(mcpTid, config);

		server.onReady(() {
			if (!session.alive)
				return;
			void startFreshThread()
			{
				ThreadStartParams tsp;
				tsp.cwd = workDir;
				tsp.model = model;
				tsp.approvalPolicy = "never";
				tsp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					tsp.developerInstructions = devInstructions;
				tsp.config = JSONFragment(configOverride);

				session.startThread("thread/start", toJson(tsp), null,
					model, workDir);
			}

			if (resumeSessionId.length > 0)
			{
				ThreadResumeParams trp;
				trp.threadId = resumeSessionId;
				trp.excludeTurns = true;
				trp.model = model;
				trp.cwd = workDir;
				trp.approvalPolicy = "never";
				trp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					trp.developerInstructions = devInstructions;
				// Spike finding (.cydo/tasks/34497/output.md): if the pooled
				// app-server still holds this thread open, a changed effort here
				// is silently ignored — the thread keeps its original effort.
				trp.config = JSONFragment(configOverride);

				session.startThread("thread/resume", toJson(trp), resumeSessionId,
					model, workDir);
			}
			else
				startFreshThread();
		}, &session.onThreadStartFailed);
	}

	/// Read a thread's history on the app-server of its live session, or on
	/// the task's own pooled app-server, which a reservation keeps running
	/// for as long as the read takes.
	Promise!DriverHistory loadHistory(string sessionId,
		const ref NativeHistoryProfile profile, AgentSession delegate() currentOwner,
		DriverHistoryLaunch delegate() obtainLaunch)
	{
		CodexSession liveOwner()
		{
			auto owner = currentOwner();
			auto codexOwner = cast(CodexSession) owner;
			enforce(owner is null || codexOwner !is null,
				"A Codex history belongs to a Codex session");
			return codexOwner;
		}

		AppServerProcess server;
		try
		{
			if (auto owner = liveOwner())
				server = owner.server;
			else
			{
				auto launch = obtainLaunch();
				enforce(launch.processLaunch.nativeHistoryProfile == profile,
					"Codex history for session " ~ sessionId ~ " belongs to " ~ profile.root
					~ " but the launch resolves to " ~ launch.processLaunch.nativeHistoryProfile.root);
				auto workspace = launch.sessionConfig.workspace.length > 0
					? launch.sessionConfig.workspace : "default";
				server = getOrCreateServer(serverPoolKey(workspace, launch.processLaunch),
					launch.processLaunch);
			}
		}
		catch (Exception e)
		{
			// A process that cannot be launched is a history that cannot be read.
			auto unavailable = new Promise!DriverHistory;
			unavailable.reject(e);
			return unavailable;
		}
		return readHistoryOn(server, sessionId, () {
			auto owner = liveOwner();
			return owner is null ? null : owner.liveTurnIds;
		});
	}

	private Promise!DriverHistory readHistoryOn(AppServerProcess server, string threadId,
		const(bool[string]) delegate() liveTurnIds)
	{
		import std.file : readText;

		auto result = new Promise!DriverHistory;
		auto reservation = server.reserveOperationRouteTid();
		void fail(Exception e)
		{
			server.cancelOperationRouteReservation(reservation);
			result.reject(e);
		}
		server.onReady(() {
			readThreadHistory((string method, string params) => server.sendRequest(method, params),
				threadId, systemKeyword_, liveTurnIds, (string path) => readText(path))
			.then((DriverHistory history) {
				server.cancelOperationRouteReservation(reservation);
				result.fulfill(history);
			}, &fail).ignoreResult();
		}, &fail);
		return result;
	}

	Promise!ThreadForkOutcome forkSession(CodexSession forkOwner, int childTid,
		string sourceThreadId, string turnId, HistoryBoundaryKind boundaryKind,
		ProcessLaunch childLaunch, SessionConfig childConfig)
	{
		enforce(forkOwner !is null && forkOwner.alive,
			"Codex native fork requires a live parent session");
		enforce(forkOwner.currentThreadId == sourceThreadId,
			"Codex native fork source does not match its parent session");
		enforce(childLaunch.nativeHistoryProfile.driver == driver,
			"Codex native fork child launch does not carry a Codex profile");
		auto outcome = new Promise!ThreadForkOutcome;
		auto server = forkOwner.server;
		ThreadForkParams tfp;
		tfp.threadId = sourceThreadId;
		tfp.excludeTurns = true;
		tfp.config = JSONFragment(buildConfigOverride(childTid, childConfig));
		if (turnId.length > 0)
		{
			final switch (boundaryKind)
			{
			case HistoryBoundaryKind.user:
				tfp.beforeTurnId = turnId;
				break;
			case HistoryBoundaryKind.agent_turn:
				tfp.lastTurnId = turnId;
				break;
			case HistoryBoundaryKind.provisional_user:
				assert(false, "A provisional user message cannot anchor a Codex fork");
			}
			tfp.model = childConfig.model.length > 0 ? childConfig.model : "codex-mini-latest";
			tfp.cwd = childLaunch.workDir.length > 0
				? childLaunch.workDir
				: (childConfig.workDir.length > 0 ? childConfig.workDir : ".");
			tfp.approvalPolicy = "never";
			tfp.sandbox = "danger-full-access";
			tfp.developerInstructions = buildDeveloperInstructions();
		}

		server.onReady(() {
			server.sendRequest("thread/fork", toJson(tfp))
				.then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", "", e.msg));
						return;
					}
					if (result.thread.id.length == 0)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", resp.result.toJson(),
							"thread/fork returned empty thread id"));
						return;
					}
					void failRelease(string detail)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", resp.result.toJson(),
							"Could not release fork child subscription " ~ result.thread.id ~ detail));
					}
					// A fork is publishable only after unsubscribe succeeds. A
					// release primitive for publishing after owner loss is deferred.
					if (server.dead)
						return failRelease(" because the Codex app-server exited");
					auto release = server.unsubscribeThread(result.thread.id);
					try
					{
						enforce(forkOwner.alive, "Codex fork parent exited");
					}
					catch (Exception e)
					{
						release.then((JsonRpcResponse) {}, (Exception releaseError) {
							warningf("thread/unsubscribe failed: %s", releaseError.msg);
						}).ignoreResult();
						outcome.fulfill(ThreadForkOutcome(false, "",
							resp.result.toJson(), e.msg));
						return;
					}
					release
						.then((JsonRpcResponse unsubscribed) {
							if (unsubscribed.isError)
								return failRelease(": " ~ unsubscribed.error.get.message);
							outcome.fulfill(ThreadForkOutcome(true, result.thread.id,
								resp.result.toJson(), ""));
						}, (Exception e) {
							failRelease(": " ~ e.msg);
						}).ignoreResult();
				}, (Exception e) {
					outcome.fulfill(ThreadForkOutcome(false, "", "", e.msg));
				}).ignoreResult();
		}, (Exception e) {
			outcome.fulfill(ThreadForkOutcome(false, "", "", e.msg));
		});

		return outcome;
	}

	private AppServerProcess getOrCreateServer(string poolKey, ProcessLaunch launch)
	{
		if (auto existing = poolKey in serverPool)
			if (!existing.dead)
				return *existing;

		auto codexBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		// Disable Codex's "goals" feature. It gives the model goal tools, and
		// an active goal makes Codex start turns on its own while idle, which
		// breaks CyDo's ownership of turns (a waiting or blocked task must stay
		// idle); CyDo's tasks already cover what goals do. This has to be the
		// app-server's own configuration: a per-thread override leaves it
		// sending goal snapshots (thread/goal/cleared) on resume.
		string[] codexArgs = [codexBin, "-c", "features.goals=false",
			"app-server", "--listen", "stdio://"];
		string[] args;
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto codexHome = launch.nativeHistoryProfile.root;
		auto server = new AppServerProcess(args);
		serverPool[poolKey] = server;
		AppServerStartupRequest startupRequest;
		server.onShutdown_ = {
			if (auto current = poolKey in serverPool)
				if (*current is server)
					serverPool.remove(poolKey);
			cancelQueuedAppServerStartup(startupRequest);
		};
		startupRequest = queueAppServerStartup(codexHome, server);
		// A synchronous failure has already settled and evicted the server.
		if (auto error = server.startupError)
			throw error;
		return server;
	}

	private AppServerStartupRequest queueAppServerStartup(string codexHome,
		AppServerProcess server)
	{
		auto gate = codexHome in appServerStartupGates;
		if (gate is null)
		{
			appServerStartupGates[codexHome] = new AppServerStartupGate;
			gate = codexHome in appServerStartupGates;
		}
		auto request = new AppServerStartupRequest(codexHome, server);
		(*gate).queue ~= request;
		startNextAppServerStartup(codexHome);
		return request;
	}

	private void startNextAppServerStartup(string codexHome)
	{
		auto gate = codexHome in appServerStartupGates;
		if (gate is null || (*gate).busy)
			return;
		while ((*gate).queue.length > 0)
		{
			auto request = (*gate).queue[0];
			(*gate).queue = (*gate).queue[1 .. $];
			if (request.cancelled)
				continue;
			(*gate).busy = true;
			auto lease = new AppServerStartupLease(codexHome, request);
			request.lease = lease;
			lease.timeout = setTimeout({
				// The retiring owner releases its lease at confirmed-exit fanout.
				if (!request.server.dead)
					releaseAppServerStartup(lease);
			}, 30.seconds);
			request.server.startProcess({ releaseAppServerStartup(lease); });
			return;
		}
		appServerStartupGates.remove(codexHome);
	}

	private void releaseAppServerStartup(AppServerStartupLease lease)
	{
		if (lease.released)
			return;
		lease.released = true;
		if (lease.timeout !is null && lease.timeout.isWaiting)
			lease.timeout.cancel();
		auto gate = lease.codexHome in appServerStartupGates;
		if (gate is null)
			return;
		(*gate).busy = false;
		startNextAppServerStartup(lease.codexHome);
	}

	private void cancelQueuedAppServerStartup(AppServerStartupRequest request)
	{
		if (request is null || request.lease !is null)
			return;
		request.cancelled = true;
		auto gate = request.codexHome in appServerStartupGates;
		if (gate is null)
			return;
		foreach (i, queued; (*gate).queue)
			if (queued is request)
			{
				(*gate).queue = (*gate).queue[0 .. i] ~ (*gate).queue[i + 1 .. $];
				break;
			}
	}

	/// Shut down all pooled server processes (safety net for app shutdown).
	void shutdownAllServers()
	{
		auto servers = serverPool.values;
		serverPool = null;
		foreach (server; servers)
			server.shutdown();
	}

	string extractResultText(string line)
	{
		import std.algorithm : canFind;
		if (!line.canFind(`"turn/result"`))
			return "";

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			if (probe.type == "turn/result")
				return probe.result;

			warningf("Unexpected turn/result event: %s", line);
			return "";
		}
		catch (Exception e)
		{
			warningf("Error parsing result: %s", e.msg);
			return "";
		}
	}

	string extractAssistantText(string line)
	{
		import std.algorithm : canFind;

		// New format: item/started with item_type=text
		if (line.canFind(`"item/started"`))
		{
			@JSONPartial static struct ItemStartedProbe { string type; string item_type; string text; }
			try
			{
				auto probe = jsonParse!ItemStartedProbe(line);
				if (probe.type == "item/started" && probe.item_type == "text" && probe.text.length > 0)
					return probe.text;
			}
			catch (Exception) {}
		}

		return "";
	}

	void setSystemKeyword(string keyword)
	{
		systemKeyword_ = keyword;
	}

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "gpt-5.6-luna";
			case "medium": return "gpt-5.6-terra";
			case "large":  return "gpt-5.6-sol";
			default:       return modelClass; // open-ended labels pass through
		}
	}

	ModelSpec resolveModelSpec(string modelClass)
	{
		ModelSpec spec;
		if (auto p = modelClass in modelAliasOverrides)
			spec = *p;
		if (spec.model.length == 0)
			spec.model = defaultModelForClass(modelClass);
		return spec;
	}

	unittest
	{
		auto agent = new CodexAgent();

		// 14. with no overrides, hardcoded defaults and empty effort
		assert(agent.resolveModelSpec("small") == ModelSpec(ModelSpecFields("gpt-5.6-luna")));
		assert(agent.resolveModelSpec("medium") == ModelSpec(ModelSpecFields("gpt-5.6-terra")));
		assert(agent.resolveModelSpec("large") == ModelSpec(ModelSpecFields("gpt-5.6-sol")));

		// 15. an override replaces the default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
		assert(agent.resolveModelSpec("large").model == "custom-model");

		// 16. an effort-only override keeps the driver's default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
		auto effortOnly = agent.resolveModelSpec("large");
		assert(effortOnly.model == "gpt-5.6-sol");
		assert(effortOnly.effort == "high");

		// 17. an unknown class passes through, and can still be overridden
		agent.setModelAliases(null);
		auto passthrough = agent.resolveModelSpec("best");
		assert(passthrough.model == "best");
		assert(passthrough.effort == "");
		agent.setModelAliases(["best": ModelSpec(ModelSpecFields("opus", "max"))]);
		auto customClass = agent.resolveModelSpec("best");
		assert(customClass.model == "opus");
		assert(customClass.effort == "max");

		// 18. the empty-class edge stays inert
		agent.setModelAliases(null);
		assert(agent.resolveModelSpec("").model == "");
	}

	string historyPath(string sessionId, const ref NativeHistoryProfile profile) { assert(false); }
	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile) { assert(false); }
	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile) { assert(false); }
	void resetHistoryReplay() { assert(false); }
	TranslatedEvent[] translateHistoryLine(string line, int lineNum) { assert(false); }

	private void validateProfile(const ref NativeHistoryProfile profile)
	{
		enforce(profile.driver == driver,
			"Codex history profile driver does not match Codex");
		enforce(profile.root.length > 0 && isAbsolute(profile.root),
			"Codex history profile requires an absolute root");
	}

	private DiscoveredSession[] scanSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, SpanMode;
		import std.path : baseName, buildPath;
		import std.regex : ctRegex, matchFirst;

		validateProfile(profile);
		auto sessionsDir = buildPath(profile.root, "sessions");
		if (!exists(sessionsDir))
			return [];

		// rollout-<time>-<thread id>.jsonl; a thread Codex has reverted keeps
		// its superseded rollouts and names the later ones
		// rollout-<time>-<thread id>_<rollout id>.jsonl.
		enum rolloutRx = ctRegex!(`^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-`
			~ `([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(_.+)?$`);
		DiscoveredSession[string] newest;
		foreach (DirEntry entry; dirEntries(sessionsDir, "*.jsonl", SpanMode.depth))
		{
			auto base = baseName(entry.name, ".jsonl");
			auto match = base.matchFirst(rolloutRx);
			DiscoveredSession session;
			session.sessionId = match.empty ? base : match[1];
			session.mtime = entry.timeLastModified.stdTime;
			session.exactHistoryPath = entry.name;
			auto known = session.sessionId in newest;
			if (known is null || known.mtime < session.mtime)
				newest[session.sessionId] = session;
		}
		return newest.values;
	}

	package static TranslatedEvent[] translateLegacyRolloutLine(string line, const ref RolloutLineEvidence evidence,
		ref bool seenTaskStarted)
	{
		import std.conv : to;
		import cydo.protocol : parseIso8601Timestamp;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		@JSONPartial static struct TimestampProbe { @JSONOptional Nullable!string timestamp; }
		if (!evidence.parsed)
			return [];
		auto timestamp = jsonParse!TimestampProbe(line).timestamp;
		auto ts = timestamp.isNull ? AbsTime.init : parseIso8601Timestamp(timestamp.get);

		auto probe = evidence.probe;
		if (probe.isSessionMeta)
		{
			auto t = translateRolloutSessionMeta(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		else if (probe.isTurnContext)
		{
			auto t = translateRolloutTurnContext(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		else if (probe.isResponseItem)
		{
			// Pass line-number fork ID for user/assistant messages
			string forkId = null;
			if (probe.isForkableMessage)
				forkId = "line:" ~ to!string(evidence.lineNumber);
			// Lines before task_started are system context injected by Codex — mark as meta.
			bool forceMeta = !seenTaskStarted;
			auto results = probe.isUserMessage
				? translateRolloutUserItem(line, evidence.user, forkId, forceMeta)
				: translateNonUserRolloutResponseItem(line, evidence.lineNumber, forkId);
			TranslatedEvent[] evs;
			foreach (r; results)
				evs ~= TranslatedEvent(r, line, ts);
			return evs;
		}
		else if (probe.isEventMsg)
		{
			if (!seenTaskStarted && probe.isTaskStarted)
				seenTaskStarted = true;
			auto t = translateRolloutEventMsg(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		// Skip compacted, unknown
		return [];
	}

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// CodexSession emits new-format events natively; pass through unchanged.
		import std.datetime : Clock;
		return [TranslatedEvent(rawLine, null, AbsTime(Clock.currStdTime))];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isHistoryPrompt(string rawLine) { assert(false); }

	string rewriteSessionId(string line, string oldId, string newId) { assert(false); }
	bool[int] inactiveHistoryLines(string content) { assert(false); }
	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content,
		int lineOffset = 0) { assert(false); }
	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText) { assert(false); }
	bool forkIdMatchesLine(string line, int lineNum, string forkId) { assert(false); }
	@property bool supportsJsonlMessageEditing() const { return false; }

	bool historyRecordIdMatchesLine(string line, int lineNum, string recordId) { assert(false); }
	bool isForkableLine(string line) { assert(false); }

	@property bool needsBash() { return false; }
	@property bool supportsFileRevert() { return false; }
	// https://github.com/openai/codex/issues/19045
	// Codex app-server developerInstructions are unreliable after
	// thread/resume and keep-context mode switches, so task system prompts
	// must be delivered via normal user input instead.
	@property bool supportsDeveloperPrompt() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch)
	{
		return RewindResult(false, "File revert is not supported for Codex sessions");
	}

	/// Currently unused — no callers in the codebase. Implement if a caller is added.
	string extractUserText(string line) { return ""; }

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		return scanSessions(profile);
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.stdio : File;

		import cydo.agent.drivers.codex.ledger : parseRolloutLineEvidence;

		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		@JSONPartial
		static struct SessionMetaProbe
		{
			@JSONPartial
			static struct Payload { string cwd; }
			Payload payload;
		}

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
			foreach (line; f.byLine)
			{
				auto lineStr = line.idup;
				auto evidence = parseRolloutLineEvidence(lineStr, ++lineCount);
				if (meta.projectPath.length == 0 && evidence.probe.isSessionMeta)
				{
					try
						meta.projectPath = jsonParse!SessionMetaProbe(lineStr).payload.cwd;
					catch (Exception) {}
				}
				if (!meta.hasMessages && evidence.user.isTurnBoundary)
					meta.title = truncateTitle(evidence.user.preview(), 80);
				if (meta.hasMessages && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{ tracef("readSessionMeta(codex, %s): error: %s", session.sessionId, e.msg); }
		return meta;
	}

	unittest
	{
		import std.array : join;
		import std.file : exists, remove, tempDir, write;
		import std.path : buildPath;
		import std.range : repeat;
		import std.uuid : randomUUID;

		auto path = buildPath(tempDir(), "cydo-codex-session-meta-" ~ randomUUID().toString ~ ".jsonl");
		scope (exit)
			if (exists(path))
				remove(path);
		auto session = DiscoveredSession("019fd6d2-f60f-7850-8924-e3566e56f9e6", 0, path);
		auto agent = new CodexAgent();

		enum header = `{"timestamp":"2026-08-06T11:26:17.667Z","type":"session_meta","payload":{"id":"019fd6d2-f60f-7850-8924-e3566e56f9e6","cwd":"/workspace"}}
`;
		enum context = `{"timestamp":"2026-08-06T11:26:17.668Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /workspace\n\n<INSTRUCTIONS>\nUse Nix.\n</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>\n  <cwd>/workspace</cwd>\n</environment_context>"}]}}
`;
		write(path, header ~ context);
		auto meta = agent.readSessionMeta(session);
		assert(meta.title == "");
		assert(!meta.hasMessages);
		assert(meta.projectPath == "/workspace");

		enum prompt = `{"timestamp":"2026-08-06T11:26:17.670Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a regression test."}]}}
`;
		foreach (contextCount; [1, 55])
		{
			write(path, header ~ context.repeat(contextCount).join ~ prompt);
			meta = agent.readSessionMeta(session);
			assert(meta.title == "Add a regression test.");
			assert(meta.hasMessages);
			assert(meta.projectPath == "/workspace");
		}

		enum imagePrompt = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/workspace/diagram.png\">"},{"type":"input_image","image_url":"data:image/png;base64,AA=="},{"type":"input_text","text":"</image>"},{"type":"output_text","text":"ignored"},{"type":"input_text","text":"Explain this diagram."}]}}
`;
		write(path, header ~ imagePrompt);
		meta = agent.readSessionMeta(session);
		assert(meta.title == "Explain this diagram.");
		assert(meta.hasMessages);

		enum imageOnly = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,AA=="}]}}
`;
		write(path, header ~ imageOnly ~ prompt);
		meta = agent.readSessionMeta(session);
		assert(meta.title == "[Image]" && meta.hasMessages);

		enum systemPrompt = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[SYSTEM: Task prompt: x]\n\nbody\n\n[/SYSTEM]"}]}}
`;
		write(path, header ~ systemPrompt ~ prompt);
		meta = agent.readSessionMeta(session);
		assert(meta.title == "[SYSTEM: Task prompt: x] body [/SYSTEM]" && meta.hasMessages);

		foreach (part; [
			`{"type":"input_image","file_id":"image","detail":42}`,
			`{"type":"input_audio","file_id":42}`,
			`{"type":"output_text","text":"output","annotations":{}}`,
			`{"type":"output_text","text":"output","logprobs":42}`,
		])
		{
			auto malformed = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Invalid prompt."},`
				~ part ~ "]}}\n";
			write(path, header ~ malformed ~ prompt);
			assert(agent.readSessionMeta(session).title == "Add a regression test.");
		}

		import cydo.agent.drivers.codex.history_fixtures : nativeUserSchemaCases, nativeUserSchemaLine;

		foreach (fixture; nativeUserSchemaCases)
		{
			auto response = nativeUserSchemaLine(fixture);
			write(path, header ~ response ~ "\n" ~ prompt);
			assert(agent.readSessionMeta(session).title
				== (fixture.title is null ? "Add a regression test." : fixture.title), response);
		}

		enum outputOnly = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"output_text","text":"ignored"}]}}
`;
		write(path, header ~ outputOnly ~ prompt);
		assert(agent.readSessionMeta(session).title == "Add a regression test.");
	}

	private string prepareIsolatedOneShotHome(ProcessLaunch launch)
	{
		import std.file : copy, exists, mkdirRecurse;
		import std.uuid : randomUUID;

		// Codex 0.139 roots its SQLite state runtime at CODEX_HOME.  Keep
		// short-lived `codex exec` runs off the app-server's state database,
		// while preserving the configured provider/auth settings.
		auto codexHome = launch.nativeHistoryProfile.root;
		auto oneShotHome = buildPath(codexHome, "oneshot", randomUUID().toString());
		scope (failure)
			removeOneShotHome(oneShotHome);
		mkdirRecurse(oneShotHome);

		auto configPath = buildPath(codexHome, "config.toml");
		if (exists(configPath))
			copy(configPath, buildPath(oneShotHome, "config.toml"));
		mkdirRecurse(buildPath(oneShotHome, "shell_snapshots"));
		return oneShotHome;
	}

	private static string[] buildOneShotArgs(string executablePath, string prompt,
		string model, string effort, string[] cmdPrefix)
	{
		string[] codexArgs = [
			executablePath,
			"exec",
			"--ephemeral",
			"--skip-git-repo-check",
			"-m", model,
		];
		// The TOML quotes are deliberate: `-c` parses the value as TOML and only
		// falls back to a raw string literal on parse failure, so quoting makes
		// the intent explicit.
		if (effort.length > 0)
			codexArgs ~= ["-c", `model_reasoning_effort="` ~ effort ~ `"`];
		codexArgs ~= prompt;
		return cmdPrefix !is null ? cmdPrefix ~ codexArgs : codexArgs;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		// 24. -c is immediately followed by model_reasoning_effort="high" when
		// effort is set; absent when it is not. prompt stays the final positional.
		auto withEffort = buildOneShotArgs("codex", "hi", "gpt-5.6-sol", "high", null);
		auto i = withEffort.countUntil("-c");
		assert(i >= 0 && withEffort[i + 1] == `model_reasoning_effort="high"`);
		assert(withEffort[$ - 1] == "hi");

		auto withoutEffort = buildOneShotArgs("codex", "hi", "gpt-5.6-sol", "", null);
		assert(!withoutEffort.canFind("-c"));
		assert(withoutEffort[$ - 1] == "hi");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		import std.string : strip;

		auto promise = new Promise!string;
		string oneShotHome;
		ProcessLaunch oneShotLaunch;
		bool hasOneShotLaunch;
		AgentProcess proc;
		try
		{
			oneShotHome = prepareIsolatedOneShotHome(launch);
			oneShotLaunch = launchSandbox.withProcessLaunchEnv(launch, "CODEX_HOME",
				oneShotHome);
			hasOneShotLaunch = true;

			auto spec = resolveModelSpec(modelClass);
			auto executablePath = oneShotLaunch.executablePath.length > 0
				? oneShotLaunch.executablePath
				: executableName(oneShotLaunch.sandbox.env);
			auto args = buildOneShotArgs(executablePath, prompt, spec.model,
				spec.effort, oneShotLaunch.cmdPrefix);

			// When sandboxed, cmdPrefix carries the resolved env/cwd. Otherwise
			// inherit the parent environment, matching AppServerProcess.
			// --skip-git-repo-check avoids the "not inside a trusted directory"
			// error when the process CWD is not a git repo root.
			proc = new AgentProcess(args, noStdin: true,
				mode: FramingMode.raw, logName: "codex-oneshot");
		}
		catch (Exception e)
		{
			if (hasOneShotLaunch)
				cleanup(oneShotLaunch.sandbox);
			removeOneShotHome(oneShotHome);
			errorf("completeOneShot: failed to prepare or spawn codex: %s", e.msg);
			promise.reject(new Exception("failed to prepare or spawn codex: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		// When stdout is a pipe (not a TTY), codex exec writes only the final
		// response text to stdout; all headers and diagnostics go to stderr.
		string responseText;
		string stderrText;

		proc.onStdoutLine = (string chunk) {
			responseText ~= chunk;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			cleanup(oneShotLaunch.sandbox);
			removeOneShotHome(oneShotHome);

			if (status != 0)
			{
				auto msg = "codex exited with status " ~ status.to!string;
				if (stderrText.length > 0)
					errorf("completeOneShot: %s\n%s", msg, stderrText);
				promise.reject(new Exception(msg));
			}
			else
			{
				if (stderrText.length > 0)
					warningf("codex oneshot stderr: %s", stderrText.strip());
				promise.fulfill(responseText.strip());
			}
		};

		void cancel() { proc.killAfterTimeout(0.seconds); }

		return OneShotHandle(promise, &cancel);
	}

	private void removeOneShotHome(string oneShotHome)
	{
		import std.file : exists, rmdirRecurse;

		if (oneShotHome.length == 0 || !exists(oneShotHome))
			return;
		try
			rmdirRecurse(oneShotHome);
		catch (Exception e)
			warningf("completeOneShot: failed to remove %s: %s", oneShotHome, e.msg);
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-codex-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH", "CODEX_HOME", "OPENAI_API_KEY",
		"OPENAI_BASE_URL", "CODEX_API_KEY"];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}

	auto home = buildPath(root, "home");
	auto codexHome = buildPath(home, "configured-codex-home");
	auto npmRoot = buildPath(home, ".npm-packages");
	auto executableDir = buildPath(npmRoot, "bin");
	auto executable = buildPath(executableDir, "codex");
	mkdirRecurse(codexHome);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["CODEX_HOME"] = codexHome;
	environment["OPENAI_API_KEY"] = "test-openai-key";
	environment["OPENAI_BASE_URL"] = "https://codex.test.invalid/v1";
	environment["CODEX_API_KEY"] = "test-codex-key";
	environment["PATH"] = executableDir;

	auto agent = new CodexAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
	];
	auto executableMounts = executableMountPaths(resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "codex";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Native history is materialized by prepareProcessLaunch, not while the
	// driver configures executable visibility and credential passthrough.
	assert(resolved.paths.exact(codexHome).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.codex);
	assert(nativeRule.profileEnvName == "CODEX_HOME");
	assert(nativeRule.homeRelativeDefault == ".codex");
	assert(nativeRule.homeSupportRequirements.length == 0);
	assert(resolved.env["PATH"] == executableDir);
	assert(("CODEX_HOME" in resolved.env) is null);
	assert(resolved.env["OPENAI_API_KEY"] == "test-openai-key");
	assert(resolved.env["OPENAI_BASE_URL"] == "https://codex.test.invalid/v1");
	assert(resolved.env["CODEX_API_KEY"] == "test-codex-key");

	// A configured profile selector remains in the resolved child environment,
	// but configureSandbox must not turn it into a native-history mount.
	auto configuredCodexHome = buildPath(home, "sandbox-codex-home");
	SandboxConfig configuredGlobal;
	configuredGlobal.env = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
		"CODEX_HOME": configuredCodexHome,
	];
	auto configuredResolved = resolveSandbox(configuredGlobal, SandboxConfig.init,
		SandboxConfig.init, agentSandbox, "");
	assert(configuredResolved.paths.exact(configuredCodexHome).isNull);
	assert(configuredResolved.paths.exact(codexHome).isNull);
	assert(configuredResolved.env["CODEX_HOME"] == configuredCodexHome);

	// Missing launch values do not inherit host CODEX_HOME during driver setup.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_CODEX_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(("CODEX_HOME" in defaultEnv) is null);
	assert(defaultPaths.exact(codexHome).isNull);
	assert(defaultEnv["OPENAI_API_KEY"] == "test-openai-key");
	assert(defaultEnv["OPENAI_BASE_URL"] == "https://codex.test.invalid/v1");
	assert(defaultEnv["CODEX_API_KEY"] == "test-codex-key");
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);
	auto npmView = defaultPaths.exact(npmRoot).get;
	assert(npmView.requirement.get.access == PathAccess.ro);
	assert(npmView.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"codex test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	string[string] ancestorEnv = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
}

unittest
{
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.config : PathMode;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-native-profile-clone");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto childHome = buildPath(root, "child-home");
	auto suppliedProfile = buildPath(root, "supplied-profile");
	auto hostProfile = buildPath(root, "host-profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(childHome);
	mkdirRecurse(suppliedProfile);
	mkdirRecurse(hostProfile);
	write(buildPath(fakeBin, "bwrap"), "");
	write(buildPath(suppliedProfile, "config.toml"), "provider = \"supplied\"\n");
	write(buildPath(hostProfile, "config.toml"), "provider = \"host\"\n");

	auto oldCodexHome = environment.get("CODEX_HOME", "");
	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	auto oldUser = environment.get("USER", "");
	bool hadCodexHome = "CODEX_HOME" in environment;
	bool hadTmpDir = "TMPDIR" in environment;
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		if (hadCodexHome)
			environment["CODEX_HOME"] = oldCodexHome;
		else
			environment.remove("CODEX_HOME");
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["CODEX_HOME"] = hostProfile;
	environment["HOME"] = childHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["CODEX_HOME"] = suppliedProfile;
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, buildPath(root, "workdir"));
	bool sourceCleaned;
	scope (exit)
		if (!sourceCleaned)
			cleanup(source.sandbox);
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.length > 0);
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));

	auto oneShotHome = agent.prepareIsolatedOneShotHome(source);
	assert(dirName(oneShotHome) == buildPath(suppliedProfile, "oneshot"));
	assert(exists(buildPath(oneShotHome, "shell_snapshots")));
	assert(readText(buildPath(oneShotHome, "config.toml")) == "provider = \"supplied\"\n");
	assert(!exists(buildPath(hostProfile, "oneshot")));

	auto clone = launchSandbox.withProcessLaunchEnv(source, "CODEX_HOME", oneShotHome);
	auto cloneTempFiles = clone.sandbox.tempFiles.dup;
	assert(clone.nativeHistoryProfile.driver == AgentDriver.codex);
	assert(clone.nativeHistoryProfile.root == oneShotHome);
	assert(clone.sandbox.env["CODEX_HOME"] == oneShotHome);
	assert(clone.sandbox.paths.exact(suppliedProfile).isNull);
	assert(clone.sandbox.paths.exact(oneShotHome).get.effectiveMode == PathMode.rw);
	assert(clone.sandbox.tempFiles.length > 0);
	foreach (tempFile; cloneTempFiles)
		assert(!sourceTempFiles.canFind(tempFile));
	assert(!cloneTempFiles.canFind(sourceOwnedTemp));
	assert(clone.cmdPrefix != sourcePrefix);
	assert(!clone.cmdPrefix.canFind(suppliedProfile));
	assert(clone.cmdPrefix.canFind(oneShotHome));

	assert(source.nativeHistoryProfile.driver == AgentDriver.codex);
	assert(source.nativeHistoryProfile.root == suppliedProfile);
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.env == sourceEnv);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.cmdPrefix == sourcePrefix);
	assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
	assert(source.preProfileSandbox.env == sourcePreProfileEnv);
	assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);

	cleanup(clone.sandbox);
	foreach (tempFile; cloneTempFiles)
		assert(!exists(tempFile));
	foreach (tempFile; sourceTempFiles)
		assert(exists(tempFile));
	rmdirRecurse(oneShotHome);
	assert(!exists(oneShotHome));
	cleanup(source.sandbox);
	sourceCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
	string[] order;
	session.onRouteReady = {
		assert(server.hasThreadRouteForTest("codex-native-id"));
		order ~= "route";
	};
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };
	ThreadStartResult started;
	started.thread.id = "codex-native-id";
	session.onThreadStarted(started, null, "test-model", "/test/workdir",
		`{"thread":{"id":"codex-native-id"}}`);
	assert(order.length >= 3
		&& order[0] == "native:codex-native-id"
		&& order[1] == "route"
		&& order[2] == "output",
		"Codex must register its route before publishing route readiness");

	auto lateConnection = new TestCodexConnection;
	auto lateServer = makeTestAppServerProcess(lateConnection);
	auto lateSession = new CodexSession(lateServer, 2, SessionConfig.init, "SYSTEM");
	ThreadStartResult lateStarted;
	lateStarted.thread.id = "codex-late-id";
	lateSession.onThreadStarted(lateStarted, "codex-late-id", "test-model",
		"/test/workdir", `{"thread":{"id":"codex-late-id"}}`);
	string delivered;
	lateSession.onNativeSessionStarted = (string sessionId) { delivered = sessionId; };
	assert(delivered == "codex-late-id");
}

unittest
{
	import std.json : parseJSON;
	import std.conv : to;
	import ae.net.asockets : socketManager;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	void drainNextTicks()
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

	JsonRpcResponse threadResponse(string threadId)
	{
		ThreadStartResult result;
		result.thread.id = threadId;
		JsonRpcResponse response;
		response.result = SO.from(result);
		return response;
	}

	auto comparableConfig(JsonRpcRequest request, int tid)
	{
		auto config = parseJSON(toJson(request.params))["config"];
		auto env = config["mcp_servers.cydo"]["env"].object;
		assert(env["CYDO_TID"].str == to!string(tid));
		env.remove("CYDO_TID");
		assert(config["thread_unload_delay_secs"].integer == 0);
		assert(config["model_reasoning_effort"].str == "high");
		return config;
	}

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto agent = new CodexAgent;
	ProcessLaunch sourceLaunch;
	sourceLaunch.executablePath = "unused-test-codex";
	sourceLaunch.workDir = "/test/source-workdir";
	sourceLaunch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex,
		"/test/source-profile");
	SessionConfig sourceConfig;
	sourceConfig.workspace = "operation-owner";
	sourceConfig.model = "test-model";
	sourceConfig.effort = "high";
	sourceConfig.mcpSocketPath = "/test/cydo.sock";
	agent.serverPool[agent.serverPoolKey(sourceConfig.workspace, sourceLaunch)] = server;

	auto operation = agent.openForkSourceOwner(71, "source-thread", sourceLaunch,
		sourceConfig);
	CodexSession owner;
	bool ownerReady;
	operation.routeReady.then((CodexSession value) {
		owner = value;
		ownerReady = true;
	}, (Exception e) {
		assert(false, e.msg);
	}).ignoreResult();

	auto resumeRequest = connection.takeRequest("thread/resume");
	auto expectedConfig = comparableConfig(resumeRequest, 71);
	auto resumeParams = parseJSON(toJson(resumeRequest.params));
	assert(resumeParams["threadId"].str == "source-thread"
		&& resumeParams["excludeTurns"].boolean
		&& resumeParams["cwd"].str == "/test/source-workdir");
	connection.respond(resumeRequest, threadResponse("source-thread"));
	drainNextTicks();
	assert(ownerReady && owner !is null && owner.alive);
	assert(server.hasThreadRouteForTest("source-thread"));

	ProcessLaunch childLaunch;
	childLaunch.workDir = "/test/child-workdir";
	childLaunch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex,
		"/test/child-profile");
	auto fresh = agent.createSession(74, null, sourceLaunch, sourceConfig);
	auto freshRequest = connection.takeRequest("thread/start");
	assert(comparableConfig(freshRequest, 74) == expectedConfig);
	connection.respond(freshRequest, threadResponse("fresh-thread"));
	drainNextTicks();
	fresh.closeStdin();
	JsonRpcResponse unsubscribed;
	unsubscribed.result = SO.from(["status": "unsubscribed"]);
	connection.respond(connection.takeRequest("thread/unsubscribe"), unsubscribed);
	drainNextTicks();
	auto childConfig = sourceConfig;
	auto fork = agent.forkSession(owner, 72, "source-thread",
		"source-turn", HistoryBoundaryKind.agent_turn, childLaunch, childConfig);
	auto forkRequest = connection.takeRequest("thread/fork");
	assert(comparableConfig(forkRequest, 72) == expectedConfig);
	auto forkParams = parseJSON(toJson(forkRequest.params));
	assert(forkParams["threadId"].str == "source-thread"
		&& forkParams["lastTurnId"].str == "source-turn"
		&& forkParams["excludeTurns"].boolean
		&& "path" !in forkParams.object);

	ThreadForkOutcome outcome;
	bool forkSettled;
	fork.then((ThreadForkOutcome value) {
		outcome = value;
		forkSettled = true;
	}, (Exception e) {
		assert(false, e.msg);
	}).ignoreResult();
	connection.respond(forkRequest, threadResponse("child-thread"));
	drainNextTicks();
	// The fork is not this app-server's to keep loaded.
	assert(!forkSettled);
	auto unsubscribe = connection.takeRequest("thread/unsubscribe");
	assert(parseJSON(toJson(unsubscribe.params))["threadId"].str == "child-thread");
	connection.respond(unsubscribe, unsubscribed);
	drainNextTicks();
	assert(forkSettled && outcome.ok && outcome.threadId == "child-thread");

	agent.forkSession(owner, 73, "source-thread", null,
		HistoryBoundaryKind.agent_turn, childLaunch, childConfig)
		.then((ThreadForkOutcome backupOutcome) {
			assert(backupOutcome.ok, backupOutcome.error);
		}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	auto backupRequest = connection.takeRequest("thread/fork");
	auto backup = parseJSON(toJson(backupRequest.params));
	assert(backup["threadId"].str == "source-thread" && backup["excludeTurns"].boolean);
	assert("lastTurnId" !in backup.object && "path" !in backup.object);
	assert(comparableConfig(backupRequest, 73) == expectedConfig);
	connection.respond(backupRequest, threadResponse("backup-thread"));
	drainNextTicks();
	connection.respond(connection.takeRequest("thread/unsubscribe"), unsubscribed);
	drainNextTicks();

	bool userForkSettled;
	agent.forkSession(owner, 75, "source-thread", "source-turn",
		HistoryBoundaryKind.user, childLaunch, childConfig)
		.then((ThreadForkOutcome userForkOutcome) {
			assert(userForkOutcome.ok, userForkOutcome.error);
			assert(userForkOutcome.threadId == "user-fork-thread");
			userForkSettled = true;
		}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	auto userForkRequest = connection.takeRequest("thread/fork");
	auto userForkParams = parseJSON(toJson(userForkRequest.params));
	assert(userForkParams["threadId"].str == "source-thread"
		&& userForkParams["beforeTurnId"].str == "source-turn"
		&& userForkParams["excludeTurns"].boolean
		&& "lastTurnId" !in userForkParams.object
		&& "path" !in userForkParams.object);
	connection.respond(userForkRequest, threadResponse("user-fork-thread"));
	drainNextTicks();
	assert(!userForkSettled);
	connection.respond(connection.takeRequest("thread/unsubscribe"), unsubscribed);
	drainNextTicks();
	assert(userForkSettled);

	// Keep the app-server available after explicitly closing the fork owner.
	auto reservation = server.reserveOperationRouteTid();
	scope (exit) server.cancelOperationRouteReservation(reservation);
	auto lateFork = agent.forkSession(owner, 74, "source-thread", "source-turn",
		HistoryBoundaryKind.agent_turn, childLaunch, childConfig);
	lateFork.then((ThreadForkOutcome lateOutcome) {
	}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	auto lateForkRequest = connection.takeRequest("thread/fork");

	bool disconnectedForkSettled;
	agent.forkSession(owner, 76, "source-thread", "source-turn",
		HistoryBoundaryKind.agent_turn, childLaunch, childConfig)
		.then((ThreadForkOutcome failedFork) {
			assert(!failedFork.ok);
			assert(failedFork.error == "JSON-RPC connection closed: app-server disconnected");
			disconnectedForkSettled = true;
		}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	connection.takeRequest("thread/fork");

	bool forkReplyBeforeDisconnectSettled;
	agent.forkSession(owner, 77, "source-thread", "source-turn",
		HistoryBoundaryKind.agent_turn, childLaunch, childConfig)
		.then((ThreadForkOutcome failedFork) {
			assert(!failedFork.ok && failedFork.error
				== "Could not release fork child subscription disconnected-child-thread"
				~ " because the Codex app-server exited");
			forkReplyBeforeDisconnectSettled = true;
		}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	auto forkReplyBeforeDisconnect = connection.takeRequest("thread/fork");

	operation.closeStdin();
	assert(!owner.alive && !server.dead);
	assert(!server.hasThreadRouteForTest("source-thread"));
	auto sourceUnsubscribe = connection.takeRequest("thread/unsubscribe");
	assert(parseJSON(toJson(sourceUnsubscribe.params))["threadId"].str == "source-thread");
	connection.respond(sourceUnsubscribe, unsubscribed);

	connection.respond(lateForkRequest, threadResponse("late-child-thread"));
	drainNextTicks();
	assert(!server.hasThreadRouteForTest("late-child-thread"),
		"A fork reply after parent close must not install a child route");
	assert(connection.sentMessages.length > 0,
		"A fork reply after parent close must unsubscribe the child thread");
	auto lateUnsubscribe = connection.takeRequest("thread/unsubscribe");
	assert(parseJSON(toJson(lateUnsubscribe.params))["threadId"].str == "late-child-thread");
	connection.respond(lateUnsubscribe, unsubscribed);
	drainNextTicks();
	assert(!server.hasThreadRouteForTest("late-child-thread"));
	assert(!disconnectedForkSettled);
	connection.respond(forkReplyBeforeDisconnect, threadResponse("disconnected-child-thread"));
	connection.peerDisconnected("app-server disconnected");
	drainNextTicks();
	assert(disconnectedForkSettled && forkReplyBeforeDisconnectSettled);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm : canFind;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-clone-temp-ownership");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto fakeBwrap = buildPath(fakeBin, "bwrap");
	auto fakeCodex = buildPath(fakeBin, "codex");
	auto hostHome = buildPath(root, "host-home");
	auto childHome = buildPath(root, "child-home");
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(buildPath(hostHome, ".config", "git"));
	mkdirRecurse(childHome);
	mkdirRecurse(profileRoot);
	auto shell = environment.get("SHELL", "/bin/sh");
	auto hostEnv = environment.toAA();
	auto sleep = resolveExecutablePath("sleep", hostEnv);
	assert(sleep.length > 0);
	write(fakeBwrap, "#!" ~ shell ~ "\n"
		~ "while [ \"$1\" != \"--\" ]; do shift; done\n"
		~ "shift\n"
		~ "exec \"$@\"\n");
	write(fakeCodex, "#!" ~ shell ~ "\n"
		~ "case \"$*\" in\n"
		~ "*one-shot-failure*)\n"
		~ "\t\"" ~ sleep ~ "\" 0.05\n"
		~ "\tprintf 'one-shot failure\\n' >&2\n"
		~ "\texit 17\n"
		~ "\t;;\n"
		~ "*)\n"
		~ "\tprintf 'one-shot success\\n'\n"
		~ "\t;;\n"
		~ "esac\n");
	assert(execute(["chmod", "+x", fakeBwrap]).status == 0);
	assert(execute(["chmod", "+x", fakeCodex]).status == 0);

	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldUser = environment.get("USER", "");
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["HOME"] = hostHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["PATH"] = fakeBin;
	sandbox.env["CODEX_HOME"] = profileRoot;
	sandbox.gitName = "one-shot clone temp ownership";
	sandbox.paths.require(root, PathAccess.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			"one-shot clone temp ownership", "test root"));
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, "", fakeCodex);
	bool sourceCleaned;
	scope (exit)
		if (!sourceCleaned)
			cleanup(source.sandbox);
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	string[] tempEntries()
	{
		string[] entries;
		foreach (entry; dirEntries(tempDir(), SpanMode.shallow))
			entries ~= entry.name;
		return entries;
	}
	void assertSourceUnchanged()
	{
		assert(source.nativeHistoryProfile.driver == AgentDriver.codex);
		assert(source.nativeHistoryProfile.root == profileRoot);
		assert(source.sandbox.paths.snapshot == sourcePaths);
		assert(source.sandbox.env == sourceEnv);
		assert(source.sandbox.tempFiles == sourceTempFiles);
		assert(source.cmdPrefix == sourcePrefix);
		assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
		assert(source.preProfileSandbox.env == sourcePreProfileEnv);
		assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);
	}
	void assertOneShotArtifactsRemoved(string outcome, const string[] tempEntriesBefore)
	{
		assert(exists(sourceOwnedTemp), outcome ~ " removed source-owned temp file");
		foreach (tempFile; sourceTempFiles)
			assert(exists(tempFile), outcome ~ " removed source temp file: " ~ tempFile);
		if (exists(oneShotParent))
			foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
				assert(false, outcome ~ " leaked one-shot home: " ~ entry.name);
		foreach (entry; dirEntries(tempDir(), SpanMode.shallow))
			assert(tempEntriesBefore.canFind(entry.name),
				outcome ~ " leaked clone prefix temp file: " ~ entry.name);
		assertSourceUnchanged();
	}

	auto tempEntriesBeforeSuccess = tempEntries();
	auto success = agent.completeOneShot("one-shot-success", "small", source);
	assert(success.cancel !is null);
	bool fulfilled;
	bool successRejected;
	bool baselineAtSuccess;
	string response;
	success.promise.then((string result) {
		fulfilled = true;
		baselineAtSuccess = exists(sourceOwnedTemp);
		response = result;
	}).except((Exception) {
		successRejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(fulfilled);
	assert(!successRejected);
	assert(response == "one-shot success");
	assert(baselineAtSuccess);
	assertOneShotArtifactsRemoved("successful one-shot", tempEntriesBeforeSuccess);

	auto tempEntriesBeforeFailure = tempEntries();
	auto failure = agent.completeOneShot("one-shot-failure", "small", source);
	assert(failure.cancel !is null);
	bool failureFulfilled;
	bool rejected;
	bool baselineAtFailure;
	failure.promise.then((string) {
		failureFulfilled = true;
	}).except((Exception) {
		rejected = true;
		baselineAtFailure = exists(sourceOwnedTemp);
	}).ignoreResult();
	socketManager.loop();
	assert(!failureFulfilled);
	assert(rejected);
	assert(baselineAtFailure);
	assertOneShotArtifactsRemoved("nonzero one-shot", tempEntriesBeforeFailure);

	cleanup(source.sandbox);
	sourceCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.types : NativeHistoryProfile, ProcessLaunch;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-settings-copy-failure");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(buildPath(profileRoot, "config.toml"));

	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, profileRoot);
	auto handle = (new CodexAgent()).completeOneShot("prompt", "small", launch);
	assert(handle.cancel is null);
	bool rejected;
	handle.promise.except((Exception e) {
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	if (exists(oneShotParent))
		foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
			assert(false, "settings-copy failure leaked one-shot home: " ~ entry.name);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm : canFind;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-clone-materialization-failure");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto hostHome = buildPath(root, "host-home");
	auto childHome = buildPath(root, "child-home");
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(hostHome);
	mkdirRecurse(childHome);
	mkdirRecurse(profileRoot);
	write(buildPath(fakeBin, "bwrap"), "");
	write(buildPath(profileRoot, "config.toml"), "provider = \"configured\"\n");

	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	auto oldUser = environment.get("USER", "");
	bool hadTmpDir = "TMPDIR" in environment;
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["HOME"] = hostHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["CODEX_HOME"] = profileRoot;
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, "");
	cleanup(source.sandbox);
	source.preProfileSandbox.gitName = "clone materialization failure";
	mkdirRecurse(buildPath(hostHome, ".config", "git", "config"));
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));
	bool sourceBaselineCleaned;
	scope (exit)
		if (!sourceBaselineCleaned)
			cleanup(source.sandbox);

	auto handle = agent.completeOneShot("prompt", "small", source);
	assert(handle.cancel is null);
	bool rejected;
	handle.promise.except((Exception e) {
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);
	assert(exists(sourceOwnedTemp));
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.env == sourceEnv);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.cmdPrefix == sourcePrefix);
	assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
	assert(source.preProfileSandbox.env == sourcePreProfileEnv);
	assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	if (exists(oneShotParent))
		foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
			assert(false, "clone materialization failure leaked one-shot home: " ~ entry.name);
	foreach (entry; dirEntries(prefixTempDir, SpanMode.shallow))
		assert(false, "clone materialization failure leaked prefix temp file: " ~ entry.name);
	cleanup(source.sandbox);
	sourceBaselineCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

private class AppServerStartupGate
{
	bool busy;
	AppServerStartupRequest[] queue;
}

private class AppServerStartupRequest
{
	this(string codexHome, AppServerProcess server)
	{
		this.codexHome = codexHome;
		this.server = server;
	}
	string codexHome;
	AppServerProcess server;
	bool cancelled;
	AppServerStartupLease lease;
}

private class AppServerStartupLease
{
	this(string codexHome, AppServerStartupRequest request)
	{
		this.codexHome = codexHome;
		this.request = request;
	}
	string codexHome;
	AppServerStartupRequest request;
	TimerTask timeout;
	bool released;
}

// ---------------------------------------------------------------------------
// CodexSession — one Codex thread, implementing AgentSession.
// ---------------------------------------------------------------------------


class CodexSession : AgentSession, AbortedToolCallCorrection
{
	private AppServerProcess server;
	private int tid;
	private string threadId;
	private string nativeSessionId_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private bool routeReady_;
	private void delegate() routeReadyHandler_;
	private string activeTurnId_;
	/// The turns this session started. Their events reach the task's history
	/// live, so a read of the thread leaves them out.
	private bool[string] liveTurnIds_;
	/// Whether the running turn already has the user message it can be cut before.
	private bool turnHasUserOpener_;
	/// The request in flight that needs the thread to itself, if any.
	private Promise!void threadRequest_;
	private Exception threadStartError_;
	private bool startupOutstanding_;
	private bool closing_;
	/// A correction accepted before the thread was attached, and its promise.
	private void delegate() pendingCorrection_;
	private Promise!void pendingCorrectionPromise_;
	private string model;
	private string workDir;
	private bool alive_;
	private bool turnInProgress;
	private bool hadItemsSinceLastStop_;

	// Active item tracking for item/delta routing.
	private string activeItemId_;              // most recently started item (for delta routing)
	private string[string] activeItemTypes_;   // itemId → itemType for all active items
	private string lastResultText_;             // last completed text content, for turn/result

	private string sessionId;
	private string agentName_;
	private string systemKeyword_;

	private enum SubmissionOperation { queued, starting, steering }

	/// One caller-owned submission through readiness, request response, and echo.
	private static final class PendingMessage
	{
		ContentBlock[] content;
		string text;
		string correlationId;
		bool isContextBootstrap;
		SubmissionOperation operation;
		Promise!AgentSubmissionReceipt promise;
		bool settled;
		bool accepted;
		TranslatedEvent gatedUserEcho;
		bool hasGatedUserEcho;

		this(const(ContentBlock)[] content, string text, string correlationId,
			bool isContextBootstrap)
		{
			this.content = content.dup;
			this.text = text;
			this.correlationId = correlationId;
			this.isContextBootstrap = isContextBootstrap;
			this.operation = SubmissionOperation.queued;
			this.promise = new Promise!AgentSubmissionReceipt;
		}
	}

	// Records pending thread readiness or a request response.
	private PendingMessage[] pendingMessages_;
	private PendingMessage[] inFlightMessages_;
	// Sent records stay in native echo order until either their response and
	// echo have both arrived or their request is rejected.
	private PendingMessage[] expectedEchoMessages_;
	private bool startInFlight_;

	// Callbacks
	package void delegate(TranslatedEvent) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;
	private void delegate() toolCallsAbandonedHandler_;
	private void delegate() revertAvailabilityChangedHandler_;

	this(AppServerProcess server, int tid, SessionConfig config, string systemKeyword)
	{
		this.server = server;
		this.tid = tid;
		this.alive_ = true;
		this.agentName_ = config.agentName;
		this.systemKeyword_ = systemKeyword;
	}

	package @property string currentThreadId() { return threadId; }

	package void notifyNativeSessionStarted(string id)
	{
		if (nativeSessionId_ !is null)
		{
			enforce(nativeSessionId_ == id,
				"Codex session reported conflicting native session IDs");
			return;
		}
		nativeSessionId_ = id;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(id);
	}

	package void notifyRouteReady()
	{
		enforce(threadId.length > 0,
			"Codex route readiness requires a thread ID");
		routeReady_ = true;
		if (routeReadyHandler_)
			routeReadyHandler_();
	}

	package CodexSessionRouteTarget asRouteTarget()
	{
		return CodexSessionRouteTarget(
			&handleItemStarted,
			&handleDelta,
			&handleTerminalInteraction,
			&handleItemCompleted,
			&handleTurnCompleted,
			&handleTurnStarted,
			&handleTokenUsageUpdated,
			&onServerExit,
			(string line) {
				if (stderrHandler_)
					stderrHandler_(line);
			},
			(TranslatedEvent ev) {
				if (outputHandler_)
					outputHandler_(ev);
			},
		);
	}

	protected Promise!JsonRpcResponse sendCodexRequest(string method, string params)
	{
		return server.sendRequest(method, params);
	}

	package void startThread(string method, string params, string resumeId,
		string model, string workDir)
	{
		assert(alive_ && !closing_ && !startupOutstanding_ && threadId.length == 0);
		startupOutstanding_ = true;
		void failed(Exception e)
		{
			startupOutstanding_ = false;
			if (alive_)
				warningf("%s error: %s", method, e.msg);
			onThreadStartFailed(e);
		}

		Promise!JsonRpcResponse request;
		try
			request = sendCodexRequest(method, params);
		catch (Exception e)
			return failed(e);
		request.then((JsonRpcResponse response) {
			startupOutstanding_ = false;
			if (!alive_)
				return;
			try
			{
				auto result = response.getResult!ThreadStartResult();
				// A retiring owner will settle this tid route at confirmed exit.
				if (server.dead)
					return;
				enforce(result.thread.id.length > 0, method ~ " returned an empty thread id");
				scope (exit)
					if (threadId.length == 0)
						server.releaseUnroutedThread(result.thread.id);
				enforce(resumeId.length == 0 || result.thread.id == resumeId,
					"thread/resume returned a different thread id");
				if (!closing_)
					onThreadStarted(result, resumeId, model, workDir, response.result.toJson());
			}
			catch (Exception e)
				return failed(e);
			if (closing_ && !server.dead)
				finishClose(0);
		}, &failed).ignoreResult();
	}

	/// Called when thread/start or thread/resume response arrives.
	package void onThreadStarted(ThreadStartResult result, string resumeId,
		string model, string workDir, string rawResultJson)
	{
		this.model = model;
		this.workDir = workDir;

		auto loadedThreadId = result.thread.id.length > 0 ? result.thread.id : resumeId;
		if (loadedThreadId.length == 0)
		{
			if (outputHandler_)
			{
				ProcessStderrEvent ev;
				ev.text = "Failed to start Codex thread";
				outputHandler_(TranslatedEvent(toJson(ev), null));
			}
			onThreadStartFailed(new Exception("Failed to start Codex thread"));
			return;
		}

		server.registerSession(loadedThreadId, asRouteTarget());
		auto wasAvailable = canRevertThread;
		threadId = sessionId = loadedThreadId;
		notifyNativeSessionStarted(threadId);
		notifyRouteReady();
		notifyRevertAvailability(wasAvailable);

		// Emit synthetic session/init with raw RPC response as _raw.
		import cydo.protocol : SessionInitEvent, SessionMetadataEvent;
		SessionInitEvent initEv;
		initEv.session_id      = threadId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "codex";
		initEv.agent_name      = agentName_;

		// On resume the JSONL-derived session_meta line provides a canonical
		// session/init; a second synthetic one here would duplicate it.
		if (outputHandler_ && resumeId.length == 0)
			outputHandler_(TranslatedEvent(toJson(initEv), rawResultJson.length > 0 ? rawResultJson : null));

		if (outputHandler_)
		{
			SessionMetadataEvent metadataEv;
			metadataEv.model = model;
			outputHandler_(TranslatedEvent(toJson(metadataEv), null));
		}

		// Drain queued messages now that the thread is ready.
		deliverPendingCorrection();
		drainPendingMessages();
	}

	package void onThreadStartFailed(Exception error)
	{
		if (!alive_)
			return;
		threadStartError_ = error;
		// Queued submissions cannot reach the wire after setup fails.
		rejectUnsettledMessages(error);
		closeStdin();
	}

	private void drainPendingMessages()
	{
		if (!alive)
			return;
		while (pendingMessages_.length > 0)
		{
			// A message sent during a revert starts its turn on what remains.
			if (threadId.length == 0 || startInFlight_ || threadRequest_ !is null
				|| (turnInProgress && activeTurnId_.length == 0))
				return;
			auto submission = pendingMessages_[0];
			pendingMessages_ = pendingMessages_[1 .. $];
			submitMessage(submission);
			if (submission.operation == SubmissionOperation.starting)
				return;
		}
	}

	private void removeInFlightMessage(PendingMessage submission)
	{
		foreach (i, candidate; inFlightMessages_)
			if (candidate is submission)
			{
				auto wasAvailable = canRevertThread;
				inFlightMessages_ = inFlightMessages_[0 .. i]
					~ inFlightMessages_[i + 1 .. $];
				notifyRevertAvailability(wasAvailable);
				return;
			}
		assert(false, "Codex submission response has no in-flight record");
	}

	private void removeExpectedEchoMessage(PendingMessage submission)
	{
		foreach (i, candidate; expectedEchoMessages_)
			if (candidate is submission)
			{
				expectedEchoMessages_ = expectedEchoMessages_[0 .. i]
					~ expectedEchoMessages_[i + 1 .. $];
				return;
			}
		assert(false, "Codex submission response has no expected user echo");
	}

	private void rejectSubmission(PendingMessage submission, Exception error)
	{
		if (submission.settled)
			return;
		submission.settled = true;
		submission.promise.reject(error);
	}

	private void emitAcceptedUserEcho(PendingMessage submission,
		TranslatedEvent event)
	{
		assert(submission.accepted,
			"Codex user echo emitted before request acceptance");
		auto output = outputHandler_;
		// Queue after fulfillment so App commits acceptance before translating it.
		onNextTick(socketManager, {
			if (output)
				output(event);
		});
	}

	private void releaseGatedUserEcho(PendingMessage submission)
	{
		if (!submission.hasGatedUserEcho)
			return;
		auto event = submission.gatedUserEcho;
		submission.gatedUserEcho = TranslatedEvent.init;
		submission.hasGatedUserEcho = false;
		removeExpectedEchoMessage(submission);
		emitAcceptedUserEcho(submission, event);
	}

	private void fulfillSubmission(PendingMessage submission)
	{
		assert(!submission.settled,
			"Codex submission settled more than once");
		submission.accepted = true;
		submission.settled = true;
		submission.promise.fulfill(AgentSubmissionReceipt.appServerAccepted);
		releaseGatedUserEcho(submission);
	}

	private void rejectUnsettledMessages(Exception error)
	{
		auto queued = pendingMessages_;
		pendingMessages_ = null;
		foreach (submission; queued)
			rejectSubmission(submission, error);

		auto wasAvailable = canRevertThread;
		auto inFlight = inFlightMessages_;
		inFlightMessages_ = null;
		notifyRevertAvailability(wasAvailable);
		foreach (submission; inFlight)
			rejectSubmission(submission, error);

		expectedEchoMessages_ = null;
		startInFlight_ = false;
	}

	private void resetRejectedStart()
	{
		auto wasAvailable = canRevertThread;
		startInFlight_ = false;
		turnInProgress = false;
		activeTurnId_ = null;
		activeItemId_ = null;
		activeItemTypes_ = null;
		hadItemsSinceLastStop_ = false;
		notifyRevertAvailability(wasAvailable);
	}

	private void submitSteer(PendingMessage submission)
	{
		submission.operation = SubmissionOperation.steering;
		trackSubmission(submission, canRevertThread);
		try
		{
			TurnSteerParams steerParams;
			steerParams.threadId = threadId;
			// Bootstrap input is deliberately anonymous: it has no user message
			// in the UI, so Codex must not correlate an echo back to one.
			if (!submission.isContextBootstrap)
				steerParams.clientUserMessageId = submission.correlationId;
			steerParams.input = [TurnStartInput("text", submission.text)];
			steerParams.expectedTurnId = activeTurnId_;
			sendCodexRequest("turn/steer", toJson(steerParams))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					if (response.isError)
					{
						removeExpectedEchoMessage(submission);
						rejectSubmission(submission,
							new Exception(response.error.get.message));
						return;
					}
					fulfillSubmission(submission);
				}, (Exception e) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					removeExpectedEchoMessage(submission);
					rejectSubmission(submission, e);
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeInFlightMessage(submission);
			removeExpectedEchoMessage(submission);
			rejectSubmission(submission, e);
		}
	}

	private void noteLiveTurn(string turnId)
	{
		activeTurnId_ = turnId;
		liveTurnIds_[turnId] = true;
	}

	package(cydo) const(bool[string]) liveTurnIds() const
	{
		return liveTurnIds_;
	}

	/// Send a request that needs the thread idle and to itself: submissions
	/// wait for it. `accept` checks the response and throws to reject.
	private Promise!void sendThreadRequest(string method, string params,
		void delegate(JsonRpcResponse) accept)
	{
		auto wasAvailable = canRevertThread;
		enforce(wasAvailable, "Codex " ~ method ~ " requires a live, idle session");
		threadRequest_ = new Promise!void;
		auto request = threadRequest_;
		notifyRevertAvailability(wasAvailable);
		void settle(void delegate() how)
		{
			// The session has ended meanwhile, and settled it.
			if (threadRequest_ !is request)
				return;
			clearThreadRequest();
			how();
		}
		void rejectRequest(Exception error)
		{
			// Submissions queued behind this request have no wire outcome to preserve.
			rejectUnsettledMessages(error);
			request.reject(error);
		}
		Promise!JsonRpcResponse responsePromise;
		try
			responsePromise = sendCodexRequest(method, params);
		catch (Exception e)
		{
			settle(() { rejectRequest(e); });
			return request;
		}
		responsePromise.then((JsonRpcResponse response) {
			settle(() {
				try
				{
					if (response.isError)
						throw new Exception(response.error.get.message);
					accept(response);
				}
				catch (Exception e)
				{
					rejectRequest(e);
					return;
				}
				request.fulfill();
				drainPendingMessages();
			});
		}, (Exception e) {
			settle(() { rejectRequest(e); });
		}).ignoreResult();
		return request;
	}

	/// Cut the thread before `beforeTurnId`, the turn and everything after it.
	/// Codex would interrupt a running turn to do it, so the session must be
	/// idle. What remains of the thread is then all read from Codex again:
	/// the caller resets the task's history when this fulfills.
	Promise!void revertThread(string beforeTurnId)
	{
		enforce(beforeTurnId.length > 0, "Codex revert requires a turn");
		return sendThreadRequest("thread/revert",
			toJson(ThreadRevertParams(threadId, beforeTurnId)), (JsonRpcResponse response) {
				enforce(response.getResult!ThreadStartResult().thread.id == threadId,
					"thread/revert returned a different thread");
				liveTurnIds_ = null;
			});
	}

	/// Codex records a tool call cut short by the session's end as aborted
	/// and keeps no way to amend the record, so the model is told in a
	/// developer message appended to the thread.
	Promise!void correctAbortedToolCall(string correction)
	{
		enforce(alive && !closing_, "Codex session is no longer alive");
		enforce(pendingCorrection_ is null, "Codex session already has a correction to deliver");
		auto delivered = new Promise!void;
		pendingCorrection_ = () {
			ThreadInjectItemsParams params;
			params.threadId = threadId;
			params.items = [ThreadInjectItemsParams.Message("message", "developer",
				[ThreadInjectItemsParams.Text("input_text", correction)])];
			sendThreadRequest("thread/inject_items", toJson(params), (JsonRpcResponse) {})
				.then(() { delivered.fulfill(); }, (Exception e) { delivered.reject(e); })
				.ignoreResult();
		};
		pendingCorrectionPromise_ = delivered;
		if (threadId.length > 0)
			deliverPendingCorrection();
		return delivered;
	}

	/// The session ended before its thread was attached.
	private void abandonPendingCorrection()
	{
		auto abandoned = pendingCorrectionPromise_;
		if (abandoned is null)
			return;
		pendingCorrection_ = null;
		pendingCorrectionPromise_ = null;
		abandoned.reject(new Exception("Codex session ended before its thread was attached"));
	}

	private void deliverPendingCorrection()
	{
		if (pendingCorrection_ is null)
			return;
		auto deliver = pendingCorrection_;
		pendingCorrection_ = null;
		pendingCorrectionPromise_ = null;
		deliver();
	}

	private void trackSubmission(PendingMessage submission, bool wasAvailable)
	{
		inFlightMessages_ ~= submission;
		expectedEchoMessages_ ~= submission;
		notifyRevertAvailability(wasAvailable);
	}

	private void submitStart(PendingMessage submission)
	{
		auto wasAvailable = canRevertThread;
		submission.operation = SubmissionOperation.starting;
		turnInProgress = true;
		startInFlight_ = true;
		activeTurnId_ = null;
		activeItemId_ = null;
		activeItemTypes_ = null;
		hadItemsSinceLastStop_ = false;
		trackSubmission(submission, wasAvailable);
		try
		{
			TurnStartParams startParams;
			startParams.threadId = threadId;
			if (!submission.isContextBootstrap)
				startParams.clientUserMessageId = submission.correlationId;
			startParams.input = [TurnStartInput("text", submission.text)];
			startParams.sandboxPolicy = SandboxPolicy("externalSandbox", "enabled");
			sendCodexRequest("turn/start", toJson(startParams))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					try
					{
						auto result = response.getResult!TurnStartResult();
						if (result.turn.id.length == 0)
							throw new Exception("turn/start returned an empty turn id");
						noteLiveTurn(result.turn.id);
						startInFlight_ = false;
						fulfillSubmission(submission);
						drainPendingMessages();
					}
					catch (Exception e)
					{
						removeExpectedEchoMessage(submission);
						resetRejectedStart();
						rejectSubmission(submission, e);
						drainPendingMessages();
					}
				}, (Exception e) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					removeExpectedEchoMessage(submission);
					resetRejectedStart();
					rejectSubmission(submission, e);
					drainPendingMessages();
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeInFlightMessage(submission);
			removeExpectedEchoMessage(submission);
			resetRejectedStart();
			rejectSubmission(submission, e);
			drainPendingMessages();
		}
	}

	private void submitMessage(PendingMessage submission)
	{
		assert(!submission.settled,
			"Codex queued submission was already settled");
		assert(threadId.length > 0,
			"Codex submission requires a ready thread");
		if (turnInProgress)
		{
			assert(activeTurnId_.length > 0,
				"Codex submission cannot steer without an active turn id");
			submitSteer(submission);
		}
		else
			submitStart(submission);
	}

	package void handleTurnStarted(TurnRef turn)
	{
		if (turn.id.length == 0)
			return;
		noteLiveTurn(turn.id);
		if (!startInFlight_)
			drainPendingMessages();
	}

	private void clearThreadRequest()
	{
		auto wasAvailable = canRevertThread;
		threadRequest_ = null;
		notifyRevertAvailability(wasAvailable);
	}

	private void closeThreadWork(string reason)
	{
		rejectUnsettledMessages(new Exception(reason ~ " before accepting message submission"));
		if (auto request = threadRequest_)
		{
			clearThreadRequest();
			request.reject(new Exception(reason ~ " during a thread request"));
		}
	}

	/// Called when the app-server process dies.
	package void onServerExit(int status)
	{
		closeThreadWork("Codex app-server exited");
		abandonPendingCorrection();
		if (!alive_)
			return;
		auto wasAvailable = canRevertThread;
		alive_ = false;
		notifyRevertAvailability(wasAvailable);
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(status);
	}

	// ----- AgentSession interface -----

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false, string nativeSubmissionUuid = null,
		MessageSource source = MessageSource.harness)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Codex: " ~ b.type);
		}

		auto submission = new PendingMessage(content, text, correlationId,
			isContextBootstrap);
		if (!alive || closing_)
		{
			submission.promise.reject(new Exception(
				"Codex session is no longer alive"));
			return submission.promise;
		}

		if (threadId.length == 0 || startInFlight_ || threadRequest_ !is null
			|| (turnInProgress && activeTurnId_.length == 0))
			pendingMessages_ ~= submission;
		else
			submitMessage(submission);
		return submission.promise;
	}

	void invalidatePendingSubmittedMessages()
	{
		if (!alive)
			return;
		rejectUnsettledMessages(new SubmissionHistoryCancelled(
			"Codex message submission was invalidated"));
	}

	@property bool supportsImages() const { return false; }

	private void notifyRevertAvailability(bool wasAvailable)
	{
		if (revertAvailabilityChangedHandler_ && canRevertThread != wasAvailable)
			revertAvailabilityChangedHandler_();
	}

	/// Whether the live thread can accept an idle-only operation changed.
	@property void onRevertAvailabilityChanged(void delegate() dg)
	{
		revertAvailabilityChangedHandler_ = dg;
	}

	@property bool canRevertThread() const
	{
		// startInFlight_ needs no separate check: its own start submission sits in
		// inFlightMessages_ for exactly as long as startInFlight_ is set, so the
		// check below already covers it. turnInProgress does not — handleTurnCompleted
		// clears it without consulting either.
		return acceptsWork && threadId.length > 0 && !turnInProgress
			&& inFlightMessages_.length == 0 && threadRequest_ is null;
	}

	void interrupt()
	{
		if (!alive || threadId.length == 0 || !turnInProgress || activeTurnId_.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			toJson(TurnInterruptParams(threadId, activeTurnId_)))
			.then((JsonRpcResponse) {}, (Exception e) {
				warningf("turn/interrupt failed: %s", e.msg);
			}).ignoreResult();
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive)
			return;
		rejectUnsettledMessages(new Exception(
			"Codex session closed before accepting message submission"));
		// Codex sessions share a pooled app-server process. Kill is an
		// emergency stop that terminates that process and lets onServerExit
		// propagate the real exit to all attached sessions.
		server.terminate();
	}

	void closeStdin()
	{
		if (!alive_ || server.dead)
			return;
		closeThreadWork("Codex session closed");
		abandonPendingCorrection();
		if (startupOutstanding_)
		{
			closing_ = true;
			return;
		}
		finishClose(threadStartError_ is null ? 0 : 1);
	}

	private void finishClose(int status)
	{
		if (threadId.length > 0)
			server.unregisterSession(threadId, &onServerExit);
		server.unregisterSessionByTid(tid, &onServerExit);
		activeTurnId_ = null;
		auto wasAvailable = canRevertThread;
		alive_ = false;
		notifyRevertAvailability(wasAvailable);
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(status);
	}

	void killAfterTimeout(Duration timeout) {} // app-server lifetime is shared

	@property bool canStopAfterCloseStdin() const
	{
		return true;
	}

	// Not tracked: a command outliving its turn reports to the UI only.
	@property const(BackgroundWork)[] backgroundWork()
	{
		return null;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionId_ !is null && nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(nativeSessionId_);
	}
	package @property void onRouteReady(void delegate() callback)
	{
		routeReadyHandler_ = callback;
		if (routeReady_ && routeReadyHandler_)
			routeReadyHandler_();
	}

	@property string startupFailure()
	{
		return threadStartError_ is null ? null : threadStartError_.msg;
	}

	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property void onToolCallsAbandoned(void delegate() dg) { toolCallsAbandonedHandler_ = dg; }
	@property bool toolCallsSurviveStdinClose() { return false; }
	private @property bool acceptsWork() const { return alive_ && (server is null || !server.dead); }
	@property bool alive() { return acceptsWork; }

	// ----- Notification handling (routed by CodexServerRouter) -----

	package void handleItemStarted(ItemStartedParams params, string rawNotification)
	{
		if (params.turnId.length > 0)
			noteLiveTurn(params.turnId);

		auto item = params.item;

		if (item.type == "userMessage")
		{
			// Echo of a submitted message: emitted once the submission is accepted.
			if (outputHandler_ is null)
				return;
			string[] unrecognized;
			auto ev = userMessageEvent(item, unrecognized);
			foreach (event; unrecognized)
				outputHandler_(TranslatedEvent(event, rawNotification));
			assert(expectedEchoMessages_.length > 0,
				"Codex native user echo has no expected submission");
			auto submission = expectedEchoMessages_[0];
			assert(userMessageText(item) == submission.text,
				"Codex native user echo text does not match expected submission");
			ev.correlation_id = submission.correlationId;
			// The context bootstrap occupies the opener position too.
			assert(activeTurnId_.length > 0, "Codex user message belongs to no turn");
			attachUserBoundary(ev, activeTurnId_, submission.isContextBootstrap
				|| isSystemFramed(systemKeyword_, submission.text)
				|| isCodexContextualFragment(submission.text)
				|| isCodexPermissionsInstructionsText(submission.text), turnHasUserOpener_);
			auto translated = TranslatedEvent(toJson(ev), rawNotification,
				AbsTime.init, 0, submission.isContextBootstrap);
			if (submission.accepted)
			{
				expectedEchoMessages_ = expectedEchoMessages_[1 .. $];
				emitAcceptedUserEcho(submission, translated);
			}
			else
			{
				assert(!submission.hasGatedUserEcho,
					"Codex submission received multiple native user echoes");
				submission.gatedUserEcho = translated;
				submission.hasGatedUserEcho = true;
			}
			return;
		}

		activeItemId_ = item.id;

		if (item.type == "contextCompaction")
		{
			// The compaction itself is reported when the item completes;
			// until then, show that it is running.
			activeItemTypes_[item.id] = "contextCompaction";
			import cydo.protocol : SessionStatusEvent;
			SessionStatusEvent statusEv;
			statusEv.status = "Compacting context...";
			if (outputHandler_)
				outputHandler_(TranslatedEvent(toJson(statusEv), rawNotification));
			return;
		}

		auto ev = itemStartedEvent(item);
		activeItemTypes_[item.id] = ev.item_type;
		// Reset + capture text for result extraction. Text may arrive
		// fully formed here (no deltas) or be empty with deltas following.
		if (item.type == "agentMessage")
			lastResultText_ = item.text;
		hadItemsSinceLastStop_ = true;

		if (outputHandler_)
			outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	/// Handle any delta notification (text, thinking, or command output).
	package void handleDelta(DeltaParams params, string deltaType, string rawNotification)
	{
		if (outputHandler_ is null)
			return;
		auto itemId = params.itemId.length > 0 ? params.itemId : activeItemId_;
		if (itemId.length == 0)
			return;

		// Accumulate text deltas for result extraction.
		if (deltaType == "text_delta")
		{
			auto pType = itemId in activeItemTypes_;
			if (pType !is null && *pType == "text")
				lastResultText_ ~= params.delta;
		}

		import cydo.protocol : ItemDeltaEvent;
		ItemDeltaEvent ev;
		ev.item_id = itemId;
		ev.delta_type = deltaType;
		ev.content = params.delta;
		outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	/// Handle terminal interaction notification (stdin written to a running process).
	package void handleTerminalInteraction(TerminalInteractionParams params, string rawNotification)
	{
		if (outputHandler_ is null)
			return;

		import cydo.protocol : ItemDeltaEvent;
		ItemDeltaEvent ev;
		ev.item_id = params.itemId.length > 0 ? params.itemId : activeItemId_;
		ev.delta_type = "stdin_delta";
		ev.content = params.stdin;
		outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	package void handleItemCompleted(ItemCompletedParams params, string rawNotification)
	{
		auto item = params.item;

		// Only items this session saw start are tracked; a user message is not.
		auto pType = item.id in activeItemTypes_;
		if (pType is null)
			return;

		if (outputHandler_)
		{
			if (*pType == "contextCompaction")
			{
				// Clear the transient status before the durable compact boundary.
				import cydo.protocol : SessionStatusEvent;
				outputHandler_(TranslatedEvent(toJson(SessionStatusEvent()), rawNotification));
				foreach (event; compactionEvents(item))
					outputHandler_(TranslatedEvent(event, rawNotification));
			}
			else
				foreach (event; itemCompletedEvents(item))
					outputHandler_(TranslatedEvent(event, rawNotification));
		}

		// Remove from tracking.
		activeItemTypes_.remove(item.id);
		if (activeItemId_ == item.id)
			activeItemId_ = null;
	}

	package void handleTurnCompleted(TurnCompletedParams params, string rawNotification)
	{
		auto wasAvailable = canRevertThread;
		turnInProgress = false;
		activeTurnId_ = null;
		turnHasUserOpener_ = false;
		if (toolCallsAbandonedHandler_)
			toolCallsAbandonedHandler_();

		// Do NOT clear activeItemId_ or activeItemTypes_ here — background items
		// may still complete after the turn ends.

		// 1. turn/stop — only if items were emitted since the last intermediate stop
		if (hadItemsSinceLastStop_ && outputHandler_)
		{
			import cydo.protocol : TurnStopEvent, UsageInfo;
			TurnStopEvent tsev;
			tsev.model = model;
			tsev.usage = UsageInfo(0, 0);
			outputHandler_(TranslatedEvent(toJson(tsev), rawNotification));
		}
		hadItemsSinceLastStop_ = false;

		// 2. turn/result — always emitted
		if (outputHandler_)
		{
			auto result = TranslatedEvent(
				toJson(turnResultEvent(params.turn, lastResultText_)), rawNotification);
			result.turnBoundary = HistoryBoundary("through:" ~ params.turn.id,
				HistoryBoundaryKind.agent_turn);
			outputHandler_(result);
		}
		lastResultText_ = null;
		notifyRevertAvailability(wasAvailable);
		drainPendingMessages();
	}

	package void handleTokenUsageUpdated(TokenUsageUpdatedParams params, string rawNotification)
	{
		if (!turnInProgress || !hadItemsSinceLastStop_)
			return;

		hadItemsSinceLastStop_ = false;

		if (outputHandler_)
		{
			import cydo.protocol : TurnStopEvent, UsageInfo;
			TurnStopEvent tsev;
			tsev.model = model;
			if (params.tokenUsage != TokenUsagePayload.init
				&& params.tokenUsage.last != TokenUsageBreakdown.init)
				tsev.usage = UsageInfo(params.tokenUsage.last.inputTokens,
					params.tokenUsage.last.outputTokens);
			else
				tsev.usage = UsageInfo(0, 0);
			outputHandler_(TranslatedEvent(toJson(tsev), rawNotification));
		}
	}
}

version (unittest) package(cydo) Session makeUnattachedCodexSessionForTest(Session = CodexSession)(
	int tid, SessionConfig config, out void delegate(int) confirmedExit)
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	auto server = makeTestAppServerProcess(new TestCodexConnection);
	auto session = new Session(server, tid, config, "SYSTEM");
	CodexSession route = session;
	server.registerSessionByTid(tid, route.asRouteTarget());
	confirmedExit = &server.confirmedExit;
	return session;
}

version (unittest) package(cydo) CodexSession makeCodexSubmissionSessionForTest(
	int tid, out void delegate(int) replyThenExit)
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto session = new CodexAgent().makeSession(server, tid, SessionConfig.init, RouteOwnerKind.task);
	ThreadStartResult started;
	started.thread.id = "submission-thread";
	session.onThreadStarted(started, null, "model", "/work", "");
	replyThenExit = (int status) {
		JsonRpcResponse response;
		response.result = jsonParse!SO(`{"turn":{"id":"started"}}`);
		connection.respond(connection.takeRequest("turn/start"), response);
		connection.disconnect("after turn/start reply", DisconnectType.graceful);
		server.confirmedExit(status);
	};
	return session;
}

version (unittest) private final class TestCodexConnection : IConnection
{
	string[] sentMessages;
	private ReadDataHandler readDataHandler;
	private DisconnectHandler disconnectHandler;
	private ConnectionState state_ = ConnectionState.connected;

	@property ConnectionState state()
	{
		return state_;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state_ == ConnectionState.connected);
		ubyte[] message;
		foreach (ref datum; data)
			datum.enter((contents) { message ~= cast(ubyte[]) contents; });
		sentMessages ~= cast(string) message;
	}
	alias send = IConnection.send;

	JsonRpcRequest takeRequest(string expectedMethod)
	{
		assert(sentMessages.length > 0,
			"Codex test connection has no pending request");
		auto request = jsonParse!JsonRpcRequest(sentMessages[0]);
		sentMessages = sentMessages[1 .. $];
		assert(request.method == expectedMethod,
			"Unexpected Codex request method: " ~ request.method);
		assert(request.id, "Codex request has no JSON-RPC id");
		return request;
	}

	JsonRpcRequest takeRequest(Params)(string expectedMethod, string expectedText)
	{
		auto request = takeRequest(expectedMethod);
		auto params = jsonParse!Params(toJson(request.params));
		assert(params.input.length == 1 && params.input[0].text == expectedText,
			"Unexpected Codex request input");
		return request;
	}

	void respond(JsonRpcRequest request, JsonRpcResponse response)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Codex test connection has no response handler");
		response.id = request.id;
		readDataHandler(Data(toJson(response).asBytes));
	}

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		disconnectHandler(reason, type);
	}

	void peerDisconnected(string reason)
	{
		state_ = ConnectionState.disconnected;
		disconnectHandler(reason, DisconnectType.error);
	}
	@property void handleConnect(ConnectHandler value) {}
	@property void handleReadData(ReadDataHandler value) { readDataHandler = value; }
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	@property void handleBufferFlushed(BufferFlushedHandler value) {}
}

version (unittest) private final class TestSubmissionOutcome
{
	int acceptedCount;
	int rejectedCount;
	string rejectionMessage;

	this(Promise!AgentSubmissionReceipt promise)
	{
		promise.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			acceptedCount++;
		}, (Exception error) {
			rejectedCount++;
			rejectionMessage = error.msg;
		}).ignoreResult();
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Build a JSON config override object passed as the "config" field in
/// thread/start params. Includes reasoning summary and, when available,
/// MCP server config for CyDo tools.
string buildConfigOverride(int tid, SessionConfig config)
{
	import std.array : join;
	import std.process : environment;

	JSONFragment[string] overrides;

	// Always request reasoning summaries from the model.
	overrides["model_reasoning_summary"] = JSONFragment(`"auto"`);

	// Verified against codex v0.147.0 (.cydo/tasks/34497/output.md): an unknown
	// config key here is silently ignored, so this key string is load-bearing.
	if (config.effort.length > 0)
		overrides["model_reasoning_effort"] = JSONFragment(toJson(config.effort));

	// Disable Codex's built-in multi-agent collaboration feature. CyDo agents must
	// delegate only via mcp__cydo__Task, never Codex's own spawn_agent/team tools.
	// Turning the feature off removes both the collaboration tools and the injected
	// "team of agents" framing in one shot.
	overrides["features.multi_agent"] = JSONFragment("false");

	// A loaded thread holds its writer lock, across processes, until Codex
	// unloads it: by default a minute after its last subscriber left. CyDo
	// unsubscribes when a thread's session ends, and the thread must then be
	// free for whichever app-server resumes it next.
	overrides["thread_unload_delay_secs"] = JSONFragment("0");

	// Force CyDo's MCP tools to be exposed as top-level DIRECT model tools rather
	// than nested inside Codex's code-mode `exec` sandbox. In code mode the exec
	// cell yields control back to the model after a 10s timer while an awaited
	// tools.mcp__cydo__Task(...) is still pending, which breaks the strict-blocking
	// invariant (parent must do no inference until the child completes). The
	// direct-call path awaits the full MCP result with no yield timer.
	// Note: features.code_mode=false is insufficient — model tool_mode metadata
	// ("code_mode_only") overrides the feature flag; this per-namespace knob wins.
	overrides["features.code_mode.direct_only_tool_namespaces"] = JSONFragment(`["mcp__cydo"]`);

	// If CYDO_CODEX_COMPACT_LIMIT is set (test-only), override compaction threshold.
	auto compactLimit = environment.get("CYDO_CODEX_COMPACT_LIMIT", "");
	if (compactLimit.length > 0)
	{
		overrides["model_auto_compact_token_limit"] = JSONFragment(compactLimit);
		overrides["model_context_window"] = JSONFragment(compactLimit);
	}

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length > 0)
	{
		string[string] env;
		env["CYDO_TID"] = to!string(tid);
		env["CYDO_SOCKET"] = config.mcpSocketPath;
		env["CYDO_TOOL_PLACEHOLDERS"] = toJson(config.toolPlaceholders);
		env["CYDO_INCLUDE_TOOLS"] = config.includeTools is null ? "" : config.includeTools.join(",");

		auto toolTimeout = environment.get("CYDO_TEST_CODEX_MCP_TOOL_TIMEOUT_SEC", "");
		auto serverConfig = McpServerConfig(
			cydoBin,
			["mcp-server"],
			env,
			toolTimeout.length > 0 ? to!uint(toolTimeout) : 100000000,
			true,
		);

		overrides["mcp_servers.cydo"] = JSONFragment(toJson(serverConfig));
	}

	return toJson(overrides);
}

unittest
{
	SessionConfig config;
	config.toolPlaceholders = [
		"singletons": "- integrate: Integrate changes.",
		"creatable_entry_points": "- agentic: Orchestrated session",
	];
	auto overrides = jsonParse!(JSONFragment[string])(buildConfigOverride(31, config));
	auto server = jsonParse!McpServerConfig(overrides["mcp_servers.cydo"].json);
	assert(server.required);
	assert(jsonParse!(string[string])(server.env["CYDO_TOOL_PLACEHOLDERS"])
		== config.toolPlaceholders);
	foreach (key; ["CYDO_CREATABLE_TYPES", "CYDO_SWITCHMODES", "CYDO_HANDOFFS", "CYDO_SINGLETONS"])
		assert(key !in server.env);
}

unittest
{
	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	@JSONPartial struct CompletedNotification { ItemCompletedParams params; }
	import cydo.protocol : TurnStopEvent;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);
	session.handleTurnStarted(TurnRef("turn"));
	auto compactStarted = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn","item":{"id":"compact","type":"contextCompaction"}}}`);
	session.handleItemStarted(compactStarted.params, "compact-start");
	session.handleTokenUsageUpdated(TokenUsageUpdatedParams.init, "usage");
	auto compactCompleted = jsonParse!CompletedNotification(
		`{"params":{"item":{"id":"compact","type":"contextCompaction"}}}`);
	session.handleItemCompleted(compactCompleted.params, "compact-complete");
	import std.algorithm : canFind;
	assert(!emitted.canFind!(event => event.canFind(`"type":"turn/stop"`)));
	auto realStarted = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn","item":{"id":"message","type":"agentMessage"}}}`);
	session.handleItemStarted(realStarted.params, "message-start");
	session.handleTurnCompleted(TurnCompletedParams("thread"), "turn-complete");
	int stops;
	foreach (event; emitted)
		if (event.canFind(`"type":"turn/stop"`)) stops++;
	assert(stops == 1);
}

unittest
{
	import std.string : indexOf;
	@JSONPartial struct EmittedTurnResult
	{
		string type;
		string subtype;
		@JSONOptional bool is_error;
		@JSONOptional string result;
		@JSONOptional string[] errors;
	}
	@JSONPartial struct CompletedNotification { TurnCompletedParams params; }
	@JSONPartial struct StartedNotification { ItemStartedParams params; }

	// A terminal turn failure (e.g. usage limit exceeded) must surface the
	// error in the turn/result event instead of reporting an empty success.
	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	session.onOutput((TranslatedEvent ev) { emitted ~= ev.translated; });
	auto failed = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-1","status":"failed",`
		~ `"error":{"message":"You've hit your usage limit.",`
		~ `"codexErrorInfo":"usageLimitExceeded","additionalDetails":null}}}}`);
	session.handleTurnCompleted(failed.params, "raw-failed");
	auto ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.type == "turn/result");
	assert(ev.subtype == "error");
	assert(ev.is_error);
	assert(ev.result == "You've hit your usage limit.");
	assert(ev.errors == ["You've hit your usage limit."]);
	auto agent = new CodexAgent;
	assert(agent.isTurnResult(emitted[$ - 1]));
	assert(agent.extractResultText(emitted[$ - 1]) == "You've hit your usage limit.");

	// A failed turn that produced partial agent text keeps that text and
	// appends the error message.
	auto partialStarted = jsonParse!StartedNotification(
		`{"params":{"threadId":"thread-failed","turnId":"turn-2",`
		~ `"item":{"id":"msg","type":"agentMessage","text":"Partial answer."}}}`);
	session.handleItemStarted(partialStarted.params, "partial-start");
	session.handleTurnCompleted(failed.params, "raw-failed");
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.is_error);
	assert(ev.result == "Partial answer.\n\nYou've hit your usage limit.");
	assert(ev.errors == ["You've hit your usage limit."]);

	// A failed turn with no error payload still reports an error.
	auto failedNoDetail = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-3","status":"failed","error":null}}}`);
	session.handleTurnCompleted(failedNoDetail.params, "raw-failed-no-detail");
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.is_error);
	assert(ev.result == "Unknown error");
	assert(ev.errors == ["Unknown error"]);

	// A successful turn keeps the success subtype.
	int abandonments;
	session.onToolCallsAbandoned = () { abandonments++; };
	auto ok = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-4","status":"completed","error":null}}}`);
	session.handleTurnCompleted(ok.params, "raw-ok");
	assert(abandonments == 1);
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.subtype == "success");
	assert(!ev.is_error);
	assert(indexOf(emitted[$ - 1], `"end_reason"`) < 0);

	// An interrupted turn says so.
	auto interrupted = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-5","status":"interrupted","error":null}}}`);
	session.handleTurnCompleted(interrupted.params, "raw-interrupted");
	assert(abandonments == 2);
	assert(indexOf(emitted[$ - 1], `"end_reason":"interrupted"`) >= 0, emitted[$ - 1]);
}

unittest
{
	import std.string : indexOf;

	SessionConfig noEffort;
	auto overrides = buildConfigOverride(1, noEffort);
	assert(overrides.indexOf(`"features.multi_agent":false`) >= 0,
		"Codex config must disable the built-in multi-agent feature; actual=" ~ overrides
		~ " (this knob does NOT determine turn_context.multi_agent_version: for a"
		~ " catalogued model Codex 0.144.1 reports the catalog's own value, which"
		~ " rollout.d's capturedModelShapes table carries per slug)");
	assert(overrides.indexOf(`"model_reasoning_summary":"auto"`) >= 0,
		"Codex config must request reasoning summaries; actual=" ~ overrides
		~ " (rollout.d isExactCapturedThreadSettings expects a \"reasoning_summary\":\"auto\" key "
		~ "from this knob; if it changes, that predicate's key list and exact value must change too)");
	assert(overrides.indexOf(`"features.code_mode.direct_only_tool_namespaces":["mcp__cydo"]`) >= 0,
		"Codex config must expose CyDo MCP tools as direct calls; actual=" ~ overrides);
	assert(overrides.indexOf(`"model_reasoning_effort"`) < 0,
		"empty effort must not add the key at all; actual=" ~ overrides);

	// 22. a non-empty effort adds the model_reasoning_effort key verbatim
	SessionConfig withEffort;
	withEffort.effort = "high";
	auto overridesWithEffort = buildConfigOverride(1, withEffort);
	assert(overridesWithEffort.indexOf(`"model_reasoning_effort":"high"`) >= 0,
		"Codex config must carry model_reasoning_effort; actual=" ~ overridesWithEffort);
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct EmittedStartedEvent
	{
		string type;
		string name;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	struct ParsedCommandInput
	{
		string command;
		string description;
	}

	enum userCommand =
		`/run/current-system/sw/bin/zsh -lc "python - <<'PY'\nprint(\"wrapped\")\nPY"`;
	enum wrappedCommand =
		`/nix/store/v8sa6r6q037ihghxfbwzjj4p59v2x0pv-bash-5.3p9/bin/bash -lc "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint(\\\"wrapped\\\")\nPY\""`;
	auto startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-command","turnId":"turn-command","item":{"id":"call_command","type":"commandExecution","command":`
		~ toJson(wrappedCommand)
		~ `,"commandActions":[{"type":"unknown","command":`
		~ toJson(userCommand)
		~ `}]}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	assert(startedEvent.type == "item/started");
	assert(startedEvent.name == "commandExecution");
	assert(startedEvent.input.json !is null);

	auto input = jsonParse!ParsedCommandInput(startedEvent.input.json);
	assert(
		input.command == userCommand && input.description == "",
		"expected multiline commandAction to preserve semantic command; actual=" ~ input.command,
	);
}

unittest
{
	import ae.net.asockets : socketManager;
	import cydo.protocol : ItemStartedEvent;

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

	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	TranslatedEvent[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev; }
	session.onOutput(&sink);
	auto bootstrapSubmission = new CodexSession.PendingMessage(
		[ContentBlock("text", "ignored")], "ignored", null, true);
	auto ordinarySubmission = new CodexSession.PendingMessage(
		[ContentBlock("text", "ordinary")], "ordinary", "ordinary-nonce", false);
	bootstrapSubmission.accepted = true;
	bootstrapSubmission.settled = true;
	ordinarySubmission.accepted = true;
	ordinarySubmission.settled = true;
	session.expectedEchoMessages_ ~= bootstrapSubmission;
	session.expectedEchoMessages_ ~= ordinarySubmission;
	auto bootstrap = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn-1","item":{"id":"bootstrap","type":"userMessage","content":[{"type":"text","text":"ignored"}]}}}`);
	session.handleItemStarted(bootstrap.params, "bootstrap");
	drainPromiseNextTicks();
	assert(emitted.length == 1 && emitted[0].isContextBootstrap);
	auto ordinary = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn-1","item":{"id":"ordinary","type":"userMessage","content":[{"type":"text","text":"ordinary"}]}}}`);
	session.handleItemStarted(ordinary.params, "ordinary");
	drainPromiseNextTicks();
	auto ordinaryEvent = jsonParse!ItemStartedEvent(emitted[1].translated);
	assert(emitted.length == 2 && !emitted[1].isContextBootstrap
		&& ordinaryEvent.correlation_id == "ordinary-nonce"
		&& session.expectedEchoMessages_.length == 0);

	// Neither the context opener nor a message steered into its turn anchors undo.
	assert(jsonParse!ItemStartedEvent(emitted[0].translated).history_boundary
		== HistoryBoundary.init);
	assert(ordinaryEvent.history_boundary == HistoryBoundary.init);
	void echo(string turnId, string text)
	{
		auto submission = new CodexSession.PendingMessage(
			[ContentBlock("text", text)], text, text ~ "-nonce", false);
		submission.accepted = true;
		submission.settled = true;
		session.expectedEchoMessages_ ~= submission;
		session.handleItemStarted(jsonParse!StartedNotification(`{"params":{"turnId":"`
			~ turnId ~ `","item":{"id":` ~ toJson(text) ~ `,"type":"userMessage","content":`
			~ `[{"type":"text","text":` ~ toJson(text) ~ `}]}}}`).params, text);
		drainPromiseNextTicks();
	}
	echo("turn-1", "steer");
	assert(jsonParse!ItemStartedEvent(emitted[2].translated).history_boundary
		== HistoryBoundary.init);

	// The end of the turn is reported with its result, for the pipeline to
	// place on the turn's last turn/stop.
	@JSONPartial struct CompletedNotification { TurnCompletedParams params; }
	session.handleTurnCompleted(jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread","turn":{"id":"turn-1","status":"completed"}}}`).params,
		"completed");
	assert(emitted[$ - 1].turnBoundary
		== HistoryBoundary("through:turn-1", HistoryBoundaryKind.agent_turn));
	echo("turn-2", "next");
	assert(jsonParse!ItemStartedEvent(emitted[$ - 1].translated).history_boundary
		== HistoryBoundary("before:turn-2", HistoryBoundaryKind.user));
	assert(session.liveTurnIds.length == 2 && "turn-1" in session.liveTurnIds
		&& "turn-2" in session.liveTurnIds);

	session.handleTurnCompleted(jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread","turn":{"id":"turn-2","status":"completed"}}}`).params,
		"completed");
	enum contextPrefixedPrompt = "<environment_context>explain this marker";
	echo("turn-3", contextPrefixedPrompt);
	auto confirmed = jsonParse!ItemStartedEvent(emitted[$ - 1].translated);
	assert(confirmed.correlation_id == contextPrefixedPrompt ~ "-nonce");
	assert(!confirmed.is_meta, "A confirmed submission echo must remain non-meta");
	assert(confirmed.history_boundary == HistoryBoundary("before:turn-3", HistoryBoundaryKind.user));

	session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "CYDO");
	emitted = null;
	session.onOutput(&sink);
	echo("turn-1", "[CYDO: Mode switch: a -> b]\n\nx\n\n[/CYDO]");
	assert(emitted.length == 1);
	auto modeSwitch = jsonParse!ItemStartedEvent(emitted[0].translated);
	assert(!modeSwitch.is_meta);
	assert(modeSwitch.history_boundary == HistoryBoundary.init);

	session.handleTurnCompleted(jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread","turn":{"id":"turn-1","status":"completed"}}}`).params,
		"completed");
	auto beforeEcho = emitted.length;
	echo("turn-2", "[SYSTEM: not ours]");
	assert(emitted.length == beforeEcho + 1);
	auto nextOpener = jsonParse!ItemStartedEvent(emitted[$ - 1].translated);
	assert(nextOpener.history_boundary == HistoryBoundary("before:turn-2", HistoryBoundaryKind.user));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	@JSONPartial struct StartedNotification { ItemStartedParams params; }

	void ignoreOutput(TranslatedEvent event) {}

	// Native echoes must match the expected submission FIFO. A second echo
	// arriving before the first is a text/order mismatch, not an event that can
	// be correlated to whichever matching submission happens to be queued.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init, "SYSTEM");
		session.onOutput(&ignoreOutput);
		auto first = new CodexSession.PendingMessage(
			[ContentBlock("text", "first")], "first", "first-nonce", false);
		auto second = new CodexSession.PendingMessage(
			[ContentBlock("text", "second")], "second", "second-nonce", false);
		first.accepted = true;
		second.accepted = true;
		session.expectedEchoMessages_ = [first, second];
		auto outOfOrder = jsonParse!StartedNotification(
			`{"params":{"turnId":"turn-1","item":{"id":"native-second","type":"userMessage","content":[{"type":"text","text":"second"}]}}}`);
		assertThrown!AssertError(session.handleItemStarted(outOfOrder.params,
			"out-of-order"));
		assert(session.expectedEchoMessages_ == [first, second]);
	}

	// A gated first echo remains attached to its submission until request
	// acceptance, so a second native echo for that submission is invalid.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init, "SYSTEM");
		session.onOutput(&ignoreOutput);
		auto submission = new CodexSession.PendingMessage(
			[ContentBlock("text", "once")], "once", "once-nonce", false);
		session.expectedEchoMessages_ = [submission];
		auto echo = jsonParse!StartedNotification(
			`{"params":{"turnId":"turn-1","item":{"id":"native-once","type":"userMessage","content":[{"type":"text","text":"once"}]}}}`);
		session.handleItemStarted(echo.params, "first-echo");
		assert(submission.hasGatedUserEcho);
		assertThrown!AssertError(session.handleItemStarted(echo.params,
			"duplicate-echo"));
	}

	// A native user echo without a live originating submission is an invariant
	// violation rather than an uncorrelated output event.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init, "SYSTEM");
		session.onOutput(&ignoreOutput);
		auto unexpected = jsonParse!StartedNotification(
			`{"params":{"turnId":"turn-1","item":{"id":"native-unexpected","type":"userMessage","content":[{"type":"text","text":"unexpected"}]}}}`);
		assertThrown!AssertError(session.handleItemStarted(unexpected.params,
			"no-expected-echo"));
	}
}

unittest
{
	import std.algorithm.searching : canFind;

	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	@JSONPartial struct EmittedStartedEvent { JSONFragment input; }
	@JSONPartial struct ParsedCommandInput { string command; }

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"019f815e-a188-7ae1-8802-4bb069784c21","turnId":"019f8595-526f-7df3-9824-f7bda4b4c0f9","item":{"type":"commandExecution","id":"exec-24065314-fcdb-4934-8299-1cd7bd4095bc","command":"/run/current-system/sw/bin/zsh -lc \"wc -l /home/vladimir/work/cydo/.cydo/tasks/32026/output.md && sed -n '1,520p' /home/vladimir/work/cydo/.cydo/tasks/32026/output.md\"","cwd":"/home/vladimir/work/cydo/.cydo/tasks/31903/worktree","status":"inProgress","processId":"16474","commandActions":[{"type":"read","command":"sed -n '1,520p' /home/vladimir/work/cydo/.cydo/tasks/32026/output.md","name":"output.md","path":"/home/vladimir/work/cydo/.cydo/tasks/32026/output.md"}],"source":"unifiedExecStartup"}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);
	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto input = jsonParse!ParsedCommandInput(startedEvent.input.json);
	assert(
		input.command.canFind("wc -l") && input.command.canFind("sed -n"),
		"expected compound commandExecution input to preserve both wc and sed; actual="
			~ input.command,
	);
}

unittest
{
	@JSONPartial
	struct ParsedCommandInput
	{
		string command;
		string description;
	}

	enum multiActions =
		`[{"type":"read","command":"sed -n '1,1p' file"},{"type":"read","command":"sed -n '2,2p' file"}]`;
	enum wrappedCommand =
		`/nix/store/bash/bin/bash -lc "sed -n '1,1p' file\nprintf '\n--- section ---\n'\nsed -n '2,2p' file"`;

	auto input = jsonParse!ParsedCommandInput(
		extractCommandExecutionInput(JSONFragment(multiActions), JSONFragment.init, wrappedCommand));
	assert(
		input.command == wrappedCommand && input.description == "",
		"expected multi-action commandExecution input to preserve wrapper; actual=" ~ input.command,
	);
}

unittest
{
	class RecordingCodexSession : CodexSession
	{
		string[] methods;
		string[] sentParams;

		this()
		{
			super(new AppServerProcess([]), 1, SessionConfig.init, "SYSTEM");
		}

		override protected Promise!JsonRpcResponse sendCodexRequest(string method,
			string params)
		{
			methods ~= method;
			sentParams ~= params;
			JsonRpcResponse response;
			response.result = jsonParse!SO(method == "turn/start"
				? "{\"turn\":{\"id\":\"started-turn\"}}"
				: "{}");
			return resolve(response);
		}
	}

	ThreadForkParams tfp;
	tfp.threadId = "thread-parent";
	tfp.lastTurnId = "turn-boundary";
	tfp.excludeTurns = true;
	tfp.model = "gpt-5.3-codex";
	tfp.cwd = "/tmp/worktree";
	tfp.approvalPolicy = "never";
	tfp.sandbox = "danger-full-access";
	tfp.developerInstructions = "dev-instructions";
	tfp.config = JSONFragment(`{"mcp_servers.cydo":{"command":"cydo"}}`);
	auto forkJson = toJson(tfp);
	assert(
		forkJson == `{"threadId":"thread-parent","lastTurnId":"turn-boundary","excludeTurns":true,"model":"gpt-5.3-codex","cwd":"/tmp/worktree","approvalPolicy":"never","sandbox":"danger-full-access","developerInstructions":"dev-instructions","config":{"mcp_servers.cydo":{"command":"cydo"}}}`,
		"thread/fork payload must include the source thread and turn boundary; actual=" ~ forkJson,
	);

	// A direct turn/start carries the browser correlation UUID to Codex.
	TurnStartParams startParams;
	startParams.threadId = "thread-start";
	startParams.clientUserMessageId = "caller-uuid-start";
	startParams.input = [TurnStartInput("text", "stage and nix flake check")];
	startParams.sandboxPolicy = SandboxPolicy("externalSandbox", "enabled");
	auto startJson = toJson(startParams);
	assert(
		startJson == `{"threadId":"thread-start","clientUserMessageId":"caller-uuid-start","input":[{"type":"text","text":"stage and nix flake check"}],"sandboxPolicy":{"type":"externalSandbox","networkAccess":"enabled"}}`,
		"turn/start payload must preserve the caller UUID; actual=" ~ startJson,
	);

	// An active turn/steer carries its own browser correlation UUID as well.
	TurnSteerParams steerParams;
	steerParams.threadId = "thread-steer";
	steerParams.clientUserMessageId = "caller-uuid-steer";
	steerParams.input = [TurnStartInput("text", "stage and nix flake check")];
	steerParams.expectedTurnId = "turn-steer";
	auto steerJson = toJson(steerParams);
	assert(
		steerJson == `{"threadId":"thread-steer","clientUserMessageId":"caller-uuid-steer","input":[{"type":"text","text":"stage and nix flake check"}],"expectedTurnId":"turn-steer"}`,
		"turn/steer payload must preserve the caller UUID; actual=" ~ steerJson,
	);

	// A message queued before thread/start retains its own UUID until the
	// thread is ready and drainPendingMessages resubmits it.
	auto queuedStart = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	queuedStart.sendMessage([ContentBlock("text", "queued start")], "uuid-queued-start").ignoreResult();
	assert(queuedStart.pendingMessages_.length == 1
		&& queuedStart.pendingMessages_[0].correlationId == "uuid-queued-start"
		&& !queuedStart.pendingMessages_[0].isContextBootstrap);

	// The same association is retained while waiting for an active turn's
	// native ID, before the message is resubmitted as turn/steer.
	auto queuedSteer = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	queuedSteer.threadId = "thread-queued-steer";
	queuedSteer.turnInProgress = true;
	queuedSteer.sendMessage([ContentBlock("text", "queued steer")], "uuid-queued-steer").ignoreResult();
	assert(queuedSteer.pendingMessages_.length == 1
		&& queuedSteer.pendingMessages_[0].correlationId == "uuid-queued-steer"
		&& !queuedSteer.pendingMessages_[0].isContextBootstrap);

	// Context bootstrap deliberately has no native user-message ID for either
	// turn/start or turn/steer.
	TurnStartParams bootstrapStart;
	bootstrapStart.threadId = "thread-bootstrap";
	bootstrapStart.input = [TurnStartInput("text", "bootstrap context")];
	bootstrapStart.sandboxPolicy = SandboxPolicy("externalSandbox", "enabled");
	assert(toJson(bootstrapStart)
		== `{"threadId":"thread-bootstrap","input":[{"type":"text","text":"bootstrap context"}],"sandboxPolicy":{"type":"externalSandbox","networkAccess":"enabled"}}`);
	TurnSteerParams bootstrapSteer;
	bootstrapSteer.threadId = "thread-bootstrap";
	bootstrapSteer.input = [TurnStartInput("text", "bootstrap context")];
	bootstrapSteer.expectedTurnId = "turn-bootstrap";
	assert(toJson(bootstrapSteer)
		== `{"threadId":"thread-bootstrap","input":[{"type":"text","text":"bootstrap context"}],"expectedTurnId":"turn-bootstrap"}`);

	// The real immediate start and active steer branches preserve the browser
	// UUID in the request handed to Codex.
	auto direct = new RecordingCodexSession;
	direct.threadId = "thread-direct";
	direct.sendMessage([ContentBlock("text", "direct message")], "uuid-direct").ignoreResult();
	assert(direct.methods == ["turn/start"]);
	assert(direct.sentParams[0]
		== "{\"threadId\":\"thread-direct\",\"clientUserMessageId\":\"uuid-direct\",\"input\":[{\"type\":\"text\",\"text\":\"direct message\"}],\"sandboxPolicy\":{\"type\":\"externalSandbox\",\"networkAccess\":\"enabled\"}}");

	auto active = new RecordingCodexSession;
	active.threadId = "thread-active";
	active.turnInProgress = true;
	active.activeTurnId_ = "turn-active";
	active.sendMessage([ContentBlock("text", "steered message")], "uuid-steered").ignoreResult();
	assert(active.methods == ["turn/steer"]);
	assert(active.sentParams[0]
		== "{\"threadId\":\"thread-active\",\"clientUserMessageId\":\"uuid-steered\",\"input\":[{\"type\":\"text\",\"text\":\"steered message\"}],\"expectedTurnId\":\"turn-active\"}");

	// A pre-thread queued message drains to turn/start with its stored UUID.
	auto queuedStartDrain = new RecordingCodexSession;
	queuedStartDrain.sendMessage([ContentBlock("text", "queued start")],
		"uuid-queued-start-drain").ignoreResult();
	assert(queuedStartDrain.methods.length == 0);
	ThreadStartResult queuedStartResult;
	queuedStartResult.thread.id = "thread-queued-start";
	queuedStartDrain.onThreadStarted(queuedStartResult, null, "model", "/workspace", "");
	assert(queuedStartDrain.methods == ["turn/start"]);
	assert(queuedStartDrain.sentParams[0]
		== "{\"threadId\":\"thread-queued-start\",\"clientUserMessageId\":\"uuid-queued-start-drain\",\"input\":[{\"type\":\"text\",\"text\":\"queued start\"}],\"sandboxPolicy\":{\"type\":\"externalSandbox\",\"networkAccess\":\"enabled\"}}");

	// A message queued before Codex knows the active turn drains to turn/steer
	// with the same stored UUID.
	auto queuedSteerDrain = new RecordingCodexSession;
	queuedSteerDrain.threadId = "thread-queued-steer";
	queuedSteerDrain.turnInProgress = true;
	queuedSteerDrain.sendMessage([ContentBlock("text", "queued steer")],
		"uuid-queued-steer-drain").ignoreResult();
	assert(queuedSteerDrain.methods.length == 0);
	queuedSteerDrain.handleTurnStarted(TurnRef("turn-queued-steer"));
	assert(queuedSteerDrain.methods == ["turn/steer"]);
	assert(queuedSteerDrain.sentParams[0]
		== "{\"threadId\":\"thread-queued-steer\",\"clientUserMessageId\":\"uuid-queued-steer-drain\",\"input\":[{\"type\":\"text\",\"text\":\"queued steer\"}],\"expectedTurnId\":\"turn-queued-steer\"}");

	// Bootstrap/context traffic alone omits a native client ID while retaining
	// the existing UI reconciliation correlation.
	auto bootstrapStartDrain = new RecordingCodexSession;
	bootstrapStartDrain.threadId = "thread-bootstrap-start";
	bootstrapStartDrain.sendMessage([ContentBlock("text", "bootstrap context")],
		"bootstrap-ui-start", true).ignoreResult();
	assert(bootstrapStartDrain.methods == ["turn/start"]);
	assert(bootstrapStartDrain.sentParams[0]
		== "{\"threadId\":\"thread-bootstrap-start\",\"input\":[{\"type\":\"text\",\"text\":\"bootstrap context\"}],\"sandboxPolicy\":{\"type\":\"externalSandbox\",\"networkAccess\":\"enabled\"}}");
	assert(bootstrapStartDrain.expectedEchoMessages_.length == 1
		&& bootstrapStartDrain.expectedEchoMessages_[0].correlationId == "bootstrap-ui-start");

	auto bootstrapSteerDrain = new RecordingCodexSession;
	bootstrapSteerDrain.threadId = "thread-bootstrap-steer";
	bootstrapSteerDrain.turnInProgress = true;
	bootstrapSteerDrain.activeTurnId_ = "turn-bootstrap-steer";
	bootstrapSteerDrain.sendMessage([ContentBlock("text", "bootstrap context")],
		"bootstrap-ui-steer", true).ignoreResult();
	assert(bootstrapSteerDrain.methods == ["turn/steer"]);
	assert(bootstrapSteerDrain.sentParams[0]
		== "{\"threadId\":\"thread-bootstrap-steer\",\"input\":[{\"type\":\"text\",\"text\":\"bootstrap context\"}],\"expectedTurnId\":\"turn-bootstrap-steer\"}");
	assert(bootstrapSteerDrain.expectedEchoMessages_.length == 1
		&& bootstrapSteerDrain.expectedEchoMessages_[0].correlationId == "bootstrap-ui-steer");

	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedStartedEvent
	{
		string type;
		string tool_server;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	struct AskQuestionOption
	{
		string label;
		string description;
	}

	@JSONPartial
	struct AskQuestion
	{
		string header;
		string question;
		AskQuestionOption[] options;
		@JSONOptional bool multiSelect;
	}

	@JSONPartial
	struct AskUserQuestionInput
	{
		AskQuestion[] questions;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		JSONFragment content;
	}

	@JSONPartial
	struct DeltaNotification
	{
		DeltaParams params;
	}

	@JSONPartial
	struct EmittedDeltaEvent
	{
		string type;
		string item_id;
		string delta_type;
		string content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-ask","turnId":"turn-ask","item":{"id":"mcp-call-ask","type":"mcpToolCall","server":"cydo","tool":"AskUserQuestion","arguments":{"questions":[{"header":"Test","question":"Do you agree?","options":[{"label":"Yes","description":"Confirm"},{"label":"No","description":"Deny"}],"multiSelect":false}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-ask","item":{"id":"mcp-call-ask","type":"mcpToolCall","result":{"content":[{"type":"text","text":"User has answered your questions: \"Do you agree?\"=\"Yes\"."}]}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);

	// The task runner tells the announcement of a CyDo tool call from the
	// agent's other work by its server.
	assert(startedEvent.tool_server == "cydo");

	bool inputOk = false;
	string actualInput = "<missing>";
	if (startedEvent.input.json !is null)
	{
		actualInput = startedEvent.input.json;
		const parsedInput = jsonParse!AskUserQuestionInput(startedEvent.input.json);
		inputOk =
			parsedInput.questions.length == 1
			&& parsedInput.questions[0].header == "Test"
			&& parsedInput.questions[0].question == "Do you agree?"
			&& parsedInput.questions[0].options.length == 2
			&& parsedInput.questions[0].options[0].label == "Yes";
	}

	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	const actualResult =
		blocks.length > 0 && blocks[0].text.length > 0 ? blocks[0].text : "<empty>";
	const resultOk =
		blocks.length == 1
		&& blocks[0].type == "text"
		&& actualResult == `User has answered your questions: "Do you agree?"="Yes".`;

	assert(
		inputOk && resultOk,
		"expected Codex mcpToolCall AskUserQuestion payload to survive translation; "
			~ "actual input=" ~ actualInput ~ " actual result=" ~ actualResult,
	);

	enum lateDeltaPayload =
		`{"jsonrpc":"2.0","method":"item/commandExecution/outputDelta","params":{"threadId":"thread-ask","turnId":"turn-ask","itemId":"mcp-call-ask","delta":"late-output-marker\n"}}`;

	auto lateDelta = jsonParse!DeltaNotification(lateDeltaPayload);
	session.handleTurnCompleted(TurnCompletedParams("thread-ask"),
		`{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-ask"}}`);
	session.handleDelta(lateDelta.params, "output_delta", lateDeltaPayload);

	auto lateDeltaEvent = jsonParse!EmittedDeltaEvent(emitted[$ - 1]);
	assert(
		lateDeltaEvent.type == "item/delta"
			&& lateDeltaEvent.item_id == "mcp-call-ask"
			&& lateDeltaEvent.delta_type == "output_delta"
			&& lateDeltaEvent.content == "late-output-marker\n",
		"expected late Codex output_delta to keep its itemId after turn completion",
	);
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		string item_id;
		@JSONOptional bool is_error;
		JSONFragment content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-task-failed","turnId":"turn-task-failed","item":{"id":"call_qQ5hScvoPoBX2kntB3IYtUM9","type":"mcpToolCall","server":"cydo","tool":"Task","arguments":{"tasks":[{"description":"demo","prompt":"demo","task_type":"review"}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-task-failed","item":{"id":"call_qQ5hScvoPoBX2kntB3IYtUM9","status":"failed","type":"mcpToolCall","result":null,"server":"cydo","tool":"Task","error":{"message":"tool call error: tool call failed for cydo/Task\n\nCaused by:\n    Transport closed"}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);
	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	auto actualResult = blocks.length > 0 ? blocks[0].text : "<empty>";

	const marker = "Transport closed";
	const hasTransportClosed =
		actualResult.length >= marker.length
		&& actualResult[$ - marker.length .. $] == marker;

	assert(
		resultEvent.type == "item/result"
			&& resultEvent.item_id == "call_qQ5hScvoPoBX2kntB3IYtUM9"
			&& resultEvent.is_error
			&& blocks.length == 1
			&& blocks[0].type == "text"
			&& hasTransportClosed,
		"expected failed mcp tool result to surface error text; actual result=" ~ actualResult,
	);
}

unittest
{
	import std.algorithm : canFind;

	enum before = `{"timestamp":"2026-03-27T07:32:23.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"before"},{"type":"input_text","text":"start"}]}}`;
	enum taskStarted = `{"timestamp":"2026-03-27T07:32:24.000Z","type":"event_msg","payload":{"type":"task_started"}}`;
	enum later = `{"timestamp":"2026-03-27T07:32:25.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"before"},{"type":"input_text","text":"start"}]}}`;

	auto agent = new CodexAgent;
	auto replay = agent.createHistoryReplay();
	auto first = replay.translateHistoryLine(before, 1);
	assert(first.length == 1 && first[0].raw == before);
	assert(first[0].translated.canFind(`"uuid":"line:1"`));
	assert(first[0].translated.canFind(`"is_meta":true`));
	assert(first[0].translated.canFind(`"text":"before"`));
	assert(first[0].translated.canFind(`"text":"start"`));

	replay.translateHistoryLine(taskStarted, 2);
	auto after = replay.translateHistoryLine(later, 3);
	assert(after.length == 1 && after[0].raw == later);
	assert(after[0].translated.canFind(`"uuid":"line:3"`));
	assert(!after[0].translated.canFind(`"is_meta":true`));
	assert(after[0].translated.canFind(`"text":"before"`));
	assert(after[0].translated.canFind(`"text":"start"`));

	replay = agent.createHistoryReplay();
	auto restarted = replay.translateHistoryLine(before, 1);
	assert(restarted.length == 1 && restarted[0].translated.canFind(`"is_meta":true`));
}

unittest
{
	import std.datetime.systime : SysTime;

	enum line = `{"timestamp":"2026-03-30T14:29:14.993Z","type":"response_item",`
		~ `"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}`;
	auto evidence = parseRolloutLineEvidence(line, 1);
	bool seenTaskStarted = true;
	auto events = CodexAgent.translateLegacyRolloutLine(line, evidence, seenTaskStarted);
	assert(events.length == 1);
	assert(events[0].ts.stdTime == SysTime.fromISOExtString("2026-03-30T14:29:14.993Z").stdTime);
}

unittest
{
	import ae.net.asockets : socketManager;
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import std.algorithm.searching : canFind;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.protocol : ItemStartedEvent;

	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

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

	JsonRpcResponse turnStartResponse(string turnId)
	{
		JsonRpcResponse response;
		response.result = SO.from(TurnStartResult(TurnRef(turnId)));
		return response;
	}

	JsonRpcResponse rejectedResponse(string message)
	{
		JsonRpcResponse response;
		response.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest,
			message);
		return response;
	}

	JsonRpcResponse acceptedResponse()
	{
		JsonRpcResponse response;
		response.result = SO.from(true);
		return response;
	}

	void assertAcceptedOnce(TestSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 1 && outcome.rejectedCount == 0);
	}

	void assertRejectedOnce(TestSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 1);
		assert(outcome.rejectionMessage.length > 0);
	}

	void exerciseThreadSetupFailure(string resumeSessionId,
		string expectedMethod)
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.executablePath = "unused-test-codex";
		launch.workDir = "/test/workdir";
		SessionConfig config;
		config.workspace = expectedMethod;
		config.model = "test-model";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;

		auto session = cast(CodexSession) agent.createSession(
			31, resumeSessionId, launch, config);
		assert(session !is null);
		string[] startupFailures;
		int[] exitStatuses;
		session.onExit = (int status) {
			startupFailures ~= session.startupFailure;
			exitStatuses ~= status;
		};
		auto setupRequest = connection.takeRequest(expectedMethod);
		if (resumeSessionId.length > 0)
		{
			auto params = jsonParse!ThreadResumeParams(toJson(setupRequest.params));
			assert(params.threadId == resumeSessionId
				&& params.model == "test-model"
				&& params.cwd == "/test/workdir");
		}
		else
		{
			auto params = jsonParse!ThreadStartParams(toJson(setupRequest.params));
			assert(params.model == "test-model"
				&& params.cwd == "/test/workdir");
		}

		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "queued setup first")], "setup-first"));
		auto second = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "queued setup second")], "setup-second"));
		assert(connection.sentMessages.length == 0);
		assert(session.pendingMessages_.length == 2
			&& session.inFlightMessages_.length == 0);

		enum timeoutMessage = "error creating thread: Fatal error: Failed to initialize session: "
			~ "required MCP servers failed to initialize: cydo: timed out handshaking "
			~ "with MCP server after 29.9999994s: deadline has elapsed";
		JsonRpcResponse response;
		response.error = JsonRpcError.fromCode(JsonRpcErrorCode.internalError,
			timeoutMessage);
		connection.respond(setupRequest, response);
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assertRejectedOnce(second);
		assert(first.rejectionMessage == timeoutMessage
			&& second.rejectionMessage == timeoutMessage);
		assert(!session.alive_);
		assert(session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);

		session.onThreadStartFailed(new Exception("duplicate setup failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assertRejectedOnce(second);
		assert(startupFailures == [timeoutMessage]);
		assert(exitStatuses == [1]);
		assert(connection.sentMessages.length == 0);
	}

	exerciseThreadSetupFailure(null, "thread/start");
	exerciseThreadSetupFailure("resume-thread", "thread/resume");

	// 23. SessionConfig.effort flows into the thread/start config override.
	{
		import std.algorithm : canFind;

		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.executablePath = "unused-test-codex";
		launch.workDir = "/test/workdir";
		SessionConfig config;
		config.workspace = "effort-test";
		config.model = "test-model";
		config.effort = "high";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;

		auto session = cast(CodexSession) agent.createSession(32, null, launch, config);
		assert(session !is null);
		auto setupRequest = connection.takeRequest("thread/start");
		auto params = jsonParse!ThreadStartParams(toJson(setupRequest.params));
		assert(params.model == "test-model");
		assert(params.config.json.canFind(`"model_reasoning_effort":"high"`));
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "first")], "first-nonce", true));
		assert(session.pendingMessages_.length == 1);
		assert(connection.sentMessages.length == 0);

		ThreadStartResult ready;
		ready.thread.id = "thread";
		session.onThreadStarted(ready, null, "test-model", "/test/workdir",
			`{"thread":{"id":"thread"}}`);
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "first");
		auto firstParams = jsonParse!TurnStartParams(toJson(firstRequest.params));
		assert(firstParams.threadId == "thread");
		connection.respond(firstRequest, turnStartResponse("turn-first"));
		drainPromiseNextTicks();
		assertAcceptedOnce(first);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-first");

		auto steerAccepted = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "accepted steer")], "steer-nonce"));
		auto steerRejected = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "stale steer")], "stale-nonce"));
		auto acceptedSteerRequest = connection.takeRequest!TurnSteerParams(
			"turn/steer", "accepted steer");
		auto rejectedSteerRequest = connection.takeRequest!TurnSteerParams(
			"turn/steer", "stale steer");
		auto acceptedSteerParams = jsonParse!TurnSteerParams(
			toJson(acceptedSteerRequest.params));
		auto rejectedSteerParams = jsonParse!TurnSteerParams(
			toJson(rejectedSteerRequest.params));
		assert(acceptedSteerParams.threadId == "thread"
			&& acceptedSteerParams.expectedTurnId == "turn-first");
		assert(rejectedSteerParams.threadId == "thread"
			&& rejectedSteerParams.expectedTurnId == "turn-first");
		assert(acceptedSteerRequest.id.toJson()
			!= rejectedSteerRequest.id.toJson());

		connection.respond(rejectedSteerRequest,
			rejectedResponse("stale expected turn"));
		drainPromiseNextTicks();
		assertRejectedOnce(steerRejected);
		assert(steerRejected.rejectionMessage == "stale expected turn");
		assert(steerAccepted.acceptedCount == 0
			&& steerAccepted.rejectedCount == 0);
		assert(session.turnInProgress
			&& session.activeTurnId_ == "turn-first");
		assert(session.expectedEchoMessages_.length == 2);

		connection.respond(acceptedSteerRequest, acceptedResponse());
		drainPromiseNextTicks();
		assertAcceptedOnce(steerAccepted);
		assert(session.turnInProgress
			&& session.activeTurnId_ == "turn-first");
		assert(session.expectedEchoMessages_.length == 2);

		TranslatedEvent[] emitted;
		session.onOutput = (TranslatedEvent event) { emitted ~= event; };
		enum firstEcho = `{"params":{"threadId":"thread","turnId":"turn-first","item":{"id":"user-first","type":"userMessage","content":[{"type":"text","text":"first"}]}}}`;
		auto notification = jsonParse!StartedNotification(firstEcho);
		session.handleItemStarted(notification.params, firstEcho);
		drainPromiseNextTicks();
		auto emittedUser = jsonParse!ItemStartedEvent(emitted[0].translated);
		assert(emittedUser.correlation_id == "first-nonce"
			&& emitted[0].isContextBootstrap);

		enum steerEcho = `{"params":{"threadId":"thread","turnId":"turn-first","item":{"id":"user-steer","type":"userMessage","content":[{"type":"text","text":"accepted steer"}]}}}`;
		notification = jsonParse!StartedNotification(steerEcho);
		session.handleItemStarted(notification.params, steerEcho);
		drainPromiseNextTicks();
		emittedUser = jsonParse!ItemStartedEvent(emitted[1].translated);
		assert(emittedUser.correlation_id == "steer-nonce"
			&& !emitted[1].isContextBootstrap);
		assert(session.expectedEchoMessages_.length == 0);
	}

	// A successful request response and item/started notification can arrive
	// back-to-back. The App acceptance continuation must run before either echo.
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
		session.threadId = "echo-order";

		bool firstAccepted;
		bool secondAccepted;
		string[] correlations;
		session.onOutput = (TranslatedEvent event) {
			if (!event.translated.canFind(`"item_type":"user_message"`))
				return;
			auto user = jsonParse!ItemStartedEvent(event.translated);
			if (user.correlation_id == "first-nonce")
				assert(firstAccepted);
			else
			{
				assert(user.correlation_id == "second-nonce");
				assert(secondAccepted);
			}
			correlations ~= user.correlation_id;
		};

		session.sendMessage([ContentBlock("text", "first prompt")],
			"first-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			firstAccepted = true;
		}).ignoreResult();
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "first prompt");
		connection.respond(firstRequest, turnStartResponse("first-turn"));
		enum firstEcho = `{"params":{"threadId":"echo-order","turnId":"first-turn","item":{"id":"first-native","type":"userMessage","content":[{"type":"text","text":"first prompt"}]}}}`;
		auto notification = jsonParse!StartedNotification(firstEcho);
		session.handleItemStarted(notification.params, firstEcho);
		assert(!firstAccepted && correlations.length == 0);
		drainPromiseNextTicks();
		assert(firstAccepted && correlations == ["first-nonce"]);

		session.handleTurnCompleted(TurnCompletedParams("echo-order"),
			`{"method":"turn/completed"}`);
		session.sendMessage([ContentBlock("text", "second prompt")],
			"second-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			secondAccepted = true;
		}).ignoreResult();
		auto secondRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "second prompt");
		connection.respond(secondRequest, turnStartResponse("second-turn"));
		enum secondEcho = `{"params":{"threadId":"echo-order","turnId":"second-turn","item":{"id":"second-native","type":"userMessage","content":[{"type":"text","text":"second prompt"}]}}}`;
		notification = jsonParse!StartedNotification(secondEcho);
		session.handleItemStarted(notification.params, secondEcho);
		assert(!secondAccepted && correlations == ["first-nonce"]);
		drainPromiseNextTicks();
		assert(secondAccepted && correlations == ["first-nonce", "second-nonce"]);
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
		session.threadId = "thread";

		auto rejected = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "rejected start")], "rejected"));
		auto rejectedRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "rejected start");
		connection.respond(rejectedRequest,
			rejectedResponse("no successor failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(rejected);
		assert(rejected.rejectionMessage == "no successor failure");
		assert(!session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_.length == 0
			&& session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);

		auto later = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "later valid start")], "later"));
		auto laterRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "later valid start");
		assert(rejectedRequest.id.toJson() != laterRequest.id.toJson());
		connection.respond(laterRequest, turnStartResponse("turn-later"));
		drainPromiseNextTicks();
		assertAcceptedOnce(later);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-later");
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
		session.threadId = "thread";

		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "rejected start")], "first"));
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "rejected start");
		auto second = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "accepted successor")], "second"));
		assert(connection.sentMessages.length == 0);
		assert(session.pendingMessages_.length == 1);

		connection.respond(firstRequest,
			rejectedResponse("queued successor failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assert(first.rejectionMessage == "queued successor failure");
		assert(second.acceptedCount == 0 && second.rejectedCount == 0);
		assert(session.turnInProgress && session.startInFlight_
			&& session.activeTurnId_.length == 0);
		auto secondRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "accepted successor");
		assert(firstRequest.id.toJson() != secondRequest.id.toJson());

		connection.respond(secondRequest, turnStartResponse("turn-successor"));
		drainPromiseNextTicks();
		assertAcceptedOnce(second);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-successor"
			&& session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);
	}

	void exerciseLifecycleLoss(string label,
		void delegate(CodexSession) loseLifecycle, bool remainsAlive)
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init, "SYSTEM");
		session.threadId = "thread-" ~ label;

		auto inFlight = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", label ~ " in flight")], label ~ "-flight"));
		auto captured = connection.takeRequest!TurnStartParams(
			"turn/start", label ~ " in flight");
		auto queued = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", label ~ " queued")], label ~ "-queued"));
		assert(connection.sentMessages.length == 0);
		assert(session.inFlightMessages_.length == 1
			&& session.pendingMessages_.length == 1);

		loseLifecycle(session);
		loseLifecycle(session);
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.alive_ == remainsAlive);
		assert(!session.startInFlight_
			&& session.inFlightMessages_.length == 0
			&& session.pendingMessages_.length == 0);

		connection.respond(captured, turnStartResponse("late-" ~ label));
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.activeTurnId_.length == 0);
		assert(session.expectedEchoMessages_.length == 0);
		// Nothing is sent for the lost submissions; a session that closed
		// only let go of its thread.
		foreach (message; connection.sentMessages)
			assert(jsonParse!JsonRpcRequest(message).method == "thread/unsubscribe");
	}

	exerciseLifecycleLoss("thread-setup-owner",
		(CodexSession session) {
			session.onThreadStartFailed(new Exception("thread setup failed"));
		}, false);
	exerciseLifecycleLoss("invalidation",
		(CodexSession session) {
			session.invalidatePendingSubmittedMessages();
		}, true);
	int[] exitStatuses;
	int abandonments;
	exerciseLifecycleLoss("close-stdin",
		(CodexSession session) {
			if (exitStatuses.length == 0)
			{
				session.onExit = (int status) { exitStatuses ~= status; };
				session.onToolCallsAbandoned = () { abandonments++; };
			}
			session.closeStdin();
		}, false);
	assert(exitStatuses == [0]);
	assert(abandonments == 0);
	exerciseLifecycleLoss("server-exit",
		(CodexSession session) {
			session.onServerExit(17);
		}, false);
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		string item_id;
		@JSONOptional JSONFragment tool_result;
		JSONFragment content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	@JSONPartial
	struct StructuredTaskResult
	{
		string status;
		int tid;
		string summary;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-task-structured","turnId":"turn-task-structured","item":{"id":"call_structuredTask","type":"mcpToolCall","server":"cydo","tool":"Task","arguments":{"tasks":[{"description":"demo","prompt":"demo","task_type":"review"}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-task-structured","item":{"id":"call_structuredTask","status":"completed","type":"mcpToolCall","server":"cydo","tool":"Task","result":{"content":[{"type":"text","text":"{\"status\":\"success\",\"tid\":2,\"summary\":\"structured-success\"}"}],"structuredContent":{"status":"success","tid":2,"summary":"structured-success"}}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);
	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	auto structured = jsonParse!StructuredTaskResult(resultEvent.tool_result.json);

	assert(
		resultEvent.type == "item/result"
			&& resultEvent.item_id == "call_structuredTask"
			&& blocks.length == 1
			&& blocks[0].type == "text"
			&& blocks[0].text == `{"status":"success","tid":2,"summary":"structured-success"}`
			&& structured.status == "success"
			&& structured.tid == 2
			&& structured.summary == "structured-success",
		"expected structuredContent to populate tool_result while preserving text content",
	);
}

/// The text each content item ends up displayed with, by item id, as the
/// frontend builds it (reduceItemStarted, reduceItemDelta and
/// reduceItemCompleted in web/src/sessionReducer.ts): the text the item
/// started with, then its text and thinking deltas, replaced by the text of
/// its item/completed if that has one.
version (unittest) private string[string] finalItemTexts(TranslatedEvent[] events)
{
	@JSONPartial static struct Probe
	{
		string type;
		@JSONOptional string item_id;
		@JSONOptional string item_type;
		@JSONOptional string text;
	}

	string[string] texts;
	foreach (ref event; events)
	{
		import cydo.protocol : ItemDeltaEvent;

		auto probe = jsonParse!Probe(event.translated);
		if (probe.type == "item/started" && probe.item_type != "user_message")
			texts[probe.item_id] = probe.text;
		else if (probe.type == "item/delta")
		{
			auto delta = jsonParse!ItemDeltaEvent(event.translated);
			if (delta.delta_type == "text_delta" || delta.delta_type == "thinking_delta")
				texts[delta.item_id] ~= delta.content;
		}
		else if (probe.type == "item/completed" && probe.text !is null)
			texts[probe.item_id] = probe.text;
	}
	return texts;
}

// Reasoning reads the same live and replayed, however its text arrives.
unittest
{
	import std.string : lineSplitter;
	import cydo.agent.drivers.codex.thread_items_fixtures : reasoningItemEntry,
		reasoningLiveNotifications;

	@JSONPartial struct Notification { string method; JSONFragment params; }

	// `deltas`: the summary deltas to deliver between the item's start and end.
	string liveText(string[] deltas)
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
		TranslatedEvent[] live;
		session.onOutput((TranslatedEvent event) { live ~= event; });
		foreach (line; reasoningLiveNotifications.lineSplitter)
		{
			auto notification = jsonParse!Notification(line);
			if (notification.method == "item/started")
			{
				session.handleItemStarted(
					jsonParse!ItemStartedParams(notification.params.json), line);
				foreach (delta; deltas)
					session.handleDelta(DeltaParams("thread", "rs_stitch_fixture", "turn", delta),
						"thinking_delta", "delta");
			}
			else
			{
				assert(notification.method == "item/completed");
				session.handleItemCompleted(
					jsonParse!ItemCompletedParams(notification.params.json), line);
			}
		}
		return finalItemTexts(live)["rs_stitch_fixture"];
	}

	auto entry = jsonParse!ThreadItemEntry(reasoningItemEntry);
	TranslatedEvent[] replay;
	replay ~= TranslatedEvent(toJson(itemStartedEvent(entry.item)), null);
	foreach (event; itemCompletedEvents(entry.item))
		replay ~= TranslatedEvent(event, null);
	auto replayText = finalItemTexts(replay)["rs_stitch_fixture"];
	assert(replayText == "reason before shell");

	// As captured: Codex had the whole summary when the item started and
	// sent no deltas.
	assert(liveText(null) == replayText);
	// Not captured: the same summary also streamed as deltas. It is shown once.
	assert(liveText(["reason before", " shell"]) == replayText);
}

// A thread's history read from Codex translates to the events the session
// that ran the thread emitted for it.
unittest
{
	import std.json : JSONValue, parseJSON;
	import std.string : lineSplitter;
	import cydo.agent.drivers.codex.thread_items_fixtures : nineTurnItemsPage,
		nineTurnLiveNotifications, nineTurnTurnsPage;
	import cydo.protocol : ItemStartedEvent;

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

	// What the two sides legitimately do not share is taken out of both:
	// - session/init: a session reports its own when it starts the thread;
	// - session/status: shown only while a compaction runs;
	// - how an item's text arrives: a session's item starts empty and
	//   grows by deltas, a history item is complete. Each item is given the
	//   text it ends up with (see `finalItemTexts`);
	// - every turn/stop but a turn's last: a session stops after each model
	//   response, which the history does not record. Token usage likewise.
	// A session reports the end of a turn with its turn/result, and the
	// pipeline puts that boundary on the turn's last turn/stop; so is it here.
	JSONValue[] comparable(TranslatedEvent[] events)
	{
		auto texts = finalItemTexts(events);
		JSONValue[] result;
		size_t turnStart;
		foreach (ref event; events)
		{
			auto json = parseJSON(event.translated);
			auto type = json["type"].str;
			if (type == "session/init" || type == "session/status" || type == "item/delta")
				continue;
			if (type == "item/started" && json["item_type"].str != "user_message")
				json["text"] = texts[json["item_id"].str];
			if (type == "item/completed")
				json.object.remove("text");
			if (type == "turn/stop")
				json.object.remove("usage");
			if (type == "turn/result")
			{
				// Keep the turn's last turn/stop only.
				JSONValue[] turn;
				ptrdiff_t lastStop = -1;
				foreach (i, ref turnEvent; result[turnStart .. $])
					if (turnEvent["type"].str == "turn/stop")
						lastStop = i;
				if (lastStop >= 0 && event.turnBoundary.anchor.length > 0)
					result[turnStart + lastStop]["history_boundary"] =
						parseJSON(toJson(event.turnBoundary));
				foreach (i, ref turnEvent; result[turnStart .. $])
					if (turnEvent["type"].str != "turn/stop" || i == lastStop)
						turn ~= turnEvent;
				result = result[0 .. turnStart] ~ turn;
				turnStart = result.length + 1;
			}
			result ~= json;
		}
		return result;
	}

	@JSONPartial struct Notification { string method; JSONFragment params; }

	auto thread = fixtureThread();
	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init, "SYSTEM");
	session.model = thread.model;
	TranslatedEvent[] live;
	session.onOutput((TranslatedEvent event) { live ~= event; });
	auto turns = ascendingTurns(nineTurnTurnsPage);
	auto items = pageItems(nineTurnItemsPage);
	assert(items[0].turnId == turns[0].id && items[0].item.type == "userMessage");
	auto bootstrap = items[0];
	bootstrap.item.id = "bootstrap";
	enum bootstrapText = "[SYSTEM: Session start: test]\n\nfirst prompt\n\n[/SYSTEM]";
	bootstrap.item.content = jsonParse!SO(toJson([ContentBlock("text", bootstrapText)]));
	foreach (line; nineTurnLiveNotifications.lineSplitter)
	{
		auto notification = jsonParse!Notification(line);
		auto params = notification.params.json;
		switch (notification.method)
		{
			case "turn/started":
				// As accepting the turn's turn/start does.
				session.turnInProgress = true;
				session.handleTurnStarted(jsonParse!TurnStartedParams(params).turn);
				break;
			case "item/started":
				auto started = jsonParse!ItemStartedParams(params);
				if (started.item.type == "userMessage")
				{
					// The submission this message echoes, already accepted.
					if (started.item.id == items[0].item.id)
					{
						// The first captured prompt is now a steer into this bootstrap turn.
						auto bootstrapStarted = started;
						bootstrapStarted.item = bootstrap.item;
						auto context = new CodexSession.PendingMessage(
							[ContentBlock("text", bootstrapText)], bootstrapText, null, true);
						context.accepted = true;
						context.settled = true;
						session.expectedEchoMessages_ ~= context;
						session.handleItemStarted(bootstrapStarted, toJson(bootstrapStarted));
						drainPromiseNextTicks();
						auto bootstrapEvent = jsonParse!ItemStartedEvent(live[$ - 1].translated);
						assert(!bootstrapEvent.is_meta
							&& bootstrapEvent.history_boundary == HistoryBoundary.init);
					}
					auto text = userMessageText(started.item);
					auto submission = new CodexSession.PendingMessage(
						[ContentBlock("text", text)], text, null, false);
					submission.accepted = true;
					submission.settled = true;
					session.expectedEchoMessages_ ~= submission;
				}
				session.handleItemStarted(started, line);
				drainPromiseNextTicks();
				break;
			case "item/agentMessage/delta":
				session.handleDelta(jsonParse!DeltaParams(params), "text_delta", line);
				break;
			case "item/completed":
				session.handleItemCompleted(jsonParse!ItemCompletedParams(params), line);
				break;
			case "thread/tokenUsage/updated":
				session.handleTokenUsageUpdated(jsonParse!TokenUsageUpdatedParams(params), line);
				break;
			case "turn/completed":
				session.handleTurnCompleted(jsonParse!TurnCompletedParams(params), line);
				break;
			default:
				assert(false, notification.method);
		}
	}

	auto replay = translateThreadHistory(thread, turns, [bootstrap] ~ items, "SYSTEM");

	auto liveEvents = comparable(live);
	auto replayEvents = comparable(replay);
	// Ten user messages, a compaction, twelve content items (five with
	// tool results), six turn stops, and nine turn results.
	assert(replayEvents.length == 10 + 1 + 12 * 2 + 5 + 6 + 9);
	foreach (i; 0 .. replayEvents.length)
		assert(i < liveEvents.length && liveEvents[i] == replayEvents[i],
			"event " ~ to!string(i) ~ ":\nlive   "
			~ (i < liveEvents.length ? liveEvents[i].toString() : "(none)")
			~ "\nreplay " ~ replayEvents[i].toString());
	assert(liveEvents.length == replayEvents.length);
}

// Requests that need the thread to itself: thread/inject_items and
// thread/revert. Messages wait for them.
unittest
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	CodexSession attached(TestCodexConnection connection)
	{
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexAgent().makeSession(server, 1, SessionConfig.init, RouteOwnerKind.task);
		session.onOutput = (TranslatedEvent event) {};
		ThreadStartResult started;
		started.thread.id = "thread";
		session.onThreadStarted(started, "thread", "model", "/work",
			`{"thread":{"id":"thread"}}`);
		return session;
	}
	JsonRpcResponse result(string json)
	{
		JsonRpcResponse response;
		response.result = jsonParse!SO(json);
		return response;
	}
	string[] outcomes;
	void observe(Promise!void promise)
	{
		promise.then(() { outcomes ~= "done"; }, (Exception e) { outcomes ~= e.msg; })
			.ignoreResult();
	}

	// A correction accepted before the thread is attached is the first thing
	// the thread is sent, and the continuation's message follows it.
	auto connection = new TestCodexConnection;
	auto session = new CodexSession(makeTestAppServerProcess(connection), 1,
		SessionConfig.init, "SYSTEM");
	session.onOutput = (TranslatedEvent event) {};
	observe(session.correctAbortedToolCall("the call was accepted"));
	session.sendMessage([ContentBlock("text", "continue")], "nonce").ignoreResult();
	assert(connection.sentMessages.length == 0);
	ThreadStartResult started;
	started.thread.id = "thread";
	session.onThreadStarted(started, "thread", "model", "/work", `{"thread":{"id":"thread"}}`);
	auto inject = connection.takeRequest("thread/inject_items");
	auto injected = jsonParse!ThreadInjectItemsParams(toJson(inject.params));
	assert(injected.threadId == "thread" && injected.items.length == 1
		&& injected.items[0].type == "message" && injected.items[0].role == "developer"
		&& injected.items[0].content == [ThreadInjectItemsParams.Text("input_text",
			"the call was accepted")]);
	assert(connection.sentMessages.length == 0, "the message waits for the correction");
	connection.respond(inject, result(`{}`));
	drainNextTicks();
	assert(outcomes == ["done"]);
	connection.takeRequest!TurnStartParams("turn/start", "continue");

	// A rejected correction fails; nothing is retried.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	observe(session.correctAbortedToolCall("the call was accepted"));
	inject = connection.takeRequest("thread/inject_items");
	JsonRpcResponse refused;
	refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest, "thread not found");
	connection.respond(inject, refused);
	drainNextTicks();
	assert(outcomes == ["thread not found"] && connection.sentMessages.length == 0);

	// thread/revert names the thread and the turn to cut before. What the
	// session ran itself is then Codex's to tell again.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	session.noteLiveTurn("turn-1");
	observe(session.revertThread("turn-2"));
	assert(!session.canRevertThread, "one thread request at a time");
	auto revert = connection.takeRequest("thread/revert");
	assert(jsonParse!ThreadRevertParams(toJson(revert.params))
		== ThreadRevertParams("thread", "turn-2"));
	session.sendMessage([ContentBlock("text", "next")], "nonce").ignoreResult();
	assert(connection.sentMessages.length == 0, "the message waits for the revert");
	connection.respond(revert, result(
		`{"thread":{"id":"thread","path":"/profile/sessions/new.jsonl"},"turns":[]}`));
	drainNextTicks();
	assert(outcomes == ["done"] && session.liveTurnIds.length == 0);
	connection.takeRequest!TurnStartParams("turn/start", "next");

	// A response that names another thread is a failure, and so is Codex's.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	session.noteLiveTurn("turn-1");
	observe(session.revertThread("turn-2"));
	connection.respond(connection.takeRequest("thread/revert"),
		result(`{"thread":{"id":"other"},"turns":[]}`));
	drainNextTicks();
	assert(outcomes == ["thread/revert returned a different thread"]);
	assert(session.liveTurnIds.length == 1 && session.canRevertThread);
	observe(session.revertThread("turn-9"));
	auto rejectedRevert = connection.takeRequest("thread/revert");
	string submissionFailure;
	session.sendMessage([ContentBlock("text", "queued behind revert")], "queued")
		.then((AgentSubmissionReceipt) { assert(false, "queued submission was accepted"); },
			(Exception e) { submissionFailure = e.msg; }).ignoreResult();
	refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest, "turn not found");
	connection.respond(rejectedRevert, refused);
	drainNextTicks();
	assert(outcomes[1] == "turn not found");
	assert(submissionFailure == "turn not found", "queued submission must be rejected");
	assert(connection.sentMessages.length == 0);

	// The app-server ending mid-request settles it.
	observe(session.revertThread("turn-2"));
	session.onServerExit(1);
	drainNextTicks();
	assert(outcomes[2] == "Codex app-server exited during a thread request");

	// A rejected transport promise reports the revert failure to its caller
	// and rejects any message queued behind the revert.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	session.noteLiveTurn("turn-1");
	observe(session.revertThread("turn-2"));
	connection.takeRequest("thread/revert");
	auto waiting = new TestSubmissionOutcome(session.sendMessage(
		[ContentBlock("text", "queued during revert")], "revert-queued"));
	connection.disconnect("revert EOF", DisconnectType.graceful);
	drainNextTicks();
	enum disconnectError = "JSON-RPC connection closed: revert EOF";
	assert(outcomes == [disconnectError]);
	assert(waiting.rejectedCount == 1 && waiting.acceptedCount == 0
		&& waiting.rejectionMessage == disconnectError);
	assert(session.liveTurnIds.length == 1 && connection.sentMessages.length == 0);

	// Receipts already read win over the owner exit. RPCs still in flight
	// keep the codec's more specific failure.
	foreach (method; ["turn/start", "turn/steer", "thread/inject_items"])
		foreach (answered; [false, true])
		{
			connection = new TestCodexConnection;
			session = attached(connection);
			if (method == "turn/steer")
			{
				session.sendMessage([ContentBlock("text", "start")], "start").ignoreResult();
				connection.respond(connection.takeRequest("turn/start"),
					result(`{"turn":{"id":"active"}}`));
				drainNextTicks();
			}
			outcomes = null;
			TestSubmissionOutcome submission;
			if (method == "thread/inject_items")
				observe(session.correctAbortedToolCall("accepted correction"));
			else
				submission = new TestSubmissionOutcome(
					session.sendMessage([ContentBlock("text", "message")], "nonce"));
			auto request = connection.takeRequest(method);
			if (answered)
				connection.respond(request, result(method == "turn/start"
					? `{"turn":{"id":"started"}}` : "{}"));
			connection.disconnect("receipt EOF", DisconnectType.graceful);
			session.server.confirmedExit(1);
			drainNextTicksAndDueTimers();

			enum error = "JSON-RPC connection closed: receipt EOF";
			if (method == "thread/inject_items")
				assert(outcomes == [answered ? "done" : error]);
			else if (answered)
				assert(submission.acceptedCount == 1 && submission.rejectedCount == 0);
			else
				assert(submission.acceptedCount == 0 && submission.rejectedCount == 1
					&& submission.rejectionMessage == error);
		}

	// The owner delivers a reply already read before notifying its routes of exit.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	session.noteLiveTurn("turn-1");
	observe(session.revertThread("turn-2"));
	connection.respond(connection.takeRequest("thread/revert"),
		result(`{"thread":{"id":"thread"}}`));
	connection.disconnect("after successful revert reply", DisconnectType.graceful);
	session.server.confirmedExit(0);
	drainNextTicksAndDueTimers();
	assert(outcomes == ["done"] && session.liveTurnIds.length == 0,
		"successful revert reply discarded: " ~ toJson(outcomes));

	// Closing the last route must settle the revert even without a server exit.
	outcomes = null;
	connection = new TestCodexConnection;
	session = attached(connection);
	observe(session.revertThread("turn-2"));
	auto closedRevert = connection.takeRequest("thread/revert");
	auto queued = new TestSubmissionOutcome(session.sendMessage(
		[ContentBlock("text", "queued during close")], "close-queued"));
	session.closeStdin();
	drainNextTicks();
	assert(outcomes == ["Codex session closed during a thread request"],
		"explicit close left a dispatched revert unsettled");
	assert(queued.rejectedCount == 1 && queued.acceptedCount == 0);
	assert(session.pendingMessages_.length == 0 && session.threadRequest_ is null);
	connection.respond(closedRevert, result(`{"thread":{"id":"thread"}}`));
	drainNextTicks();
	assert(outcomes.length == 1 && queued.rejectedCount == 1);

	// Codex would interrupt a running turn to revert: only an idle session may.
	connection = new TestCodexConnection;
	session = attached(connection);
	session.turnInProgress = true;
	import std.exception : assertThrown;
	assertThrown!Exception(session.revertThread("turn-1"));
	assert(connection.sentMessages.length == 0);
}

// Retirement leaves already-read submission replies and exit status with the owner.
unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicksAndDueTimers;

	foreach (retireAction; [
		(CodexSession session) { session.stop(); },
		(CodexSession session) { session.closeStdin(); },
		(CodexSession session) { session.invalidatePendingSubmittedMessages(); },
	])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = (new CodexAgent).makeSession(server, 1, SessionConfig.init,
			RouteOwnerKind.task);
		ThreadStartResult started;
		started.thread.id = "thread";
		session.onThreadStarted(started, null, "model", "/work", "");
		int[] exits;
		session.onExit = (int status) { exits ~= status; };
		auto submitted = new TestSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "submitted")], "submitted"));
		JsonRpcResponse response;
		response.result = jsonParse!SO(`{"turn":{"id":"started"}}`);
		connection.respond(connection.takeRequest("turn/start"), response);

		connection.disconnect("after send reply", DisconnectType.graceful);
		retireAction(session);
		assert(exits.length == 0);
		server.confirmedExit(42);
		assert(exits.length == 0);
		drainNextTicksAndDueTimers();
		assert(exits == [42]);
		assert(submitted.acceptedCount == 1 && submitted.rejectedCount == 0);
		assert(connection.sentMessages.length == 0);
	}
}

// EOF settles pending forks without invalidating replies already received.
unittest
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto agent = new CodexAgent;
	auto owner = agent.makeSession(server, 1, SessionConfig.init, RouteOwnerKind.task);
	owner.onOutput = (TranslatedEvent event) {};
	ThreadStartResult started;
	started.thread.id = "source";
	owner.onThreadStarted(started, "source", "model", "/work",
		`{"thread":{"id":"source"}}`);

	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
	ThreadForkOutcome[int] outcomes;
	void observe(int tid)
	{
		agent.forkSession(owner, tid, "source", null, HistoryBoundaryKind.agent_turn,
			launch, SessionConfig.init)
			.then((ThreadForkOutcome outcome) {
				assert(tid !in outcomes, "fork must report its outcome once");
				outcomes[tid] = outcome;
			},
				(Exception e) { assert(false, e.msg); }).ignoreResult();
	}

	observe(2);
	JsonRpcResponse forked;
	forked.result = jsonParse!SO(`{"thread":{"id":"child"}}`);
	connection.respond(connection.takeRequest("thread/fork"), forked);
	drainNextTicks();
	connection.takeRequest("thread/unsubscribe");

	observe(3);
	connection.takeRequest("thread/fork");

	observe(4);
	forked.result = jsonParse!SO(`{"thread":{"id":"released-child"}}`);
	connection.respond(connection.takeRequest("thread/fork"), forked);
	drainNextTicks();
	auto successfulRelease = connection.takeRequest("thread/unsubscribe");

	observe(5);
	forked.result = jsonParse!SO(`{"thread":{"id":"refused-child"}}`);
	connection.respond(connection.takeRequest("thread/fork"), forked);
	drainNextTicks();
	auto refusedRelease = connection.takeRequest("thread/unsubscribe");

	observe(6);
	forked.result = jsonParse!SO(`{"thread":{"id":"unreleased-child"}}`);
	connection.respond(connection.takeRequest("thread/fork"), forked);
	JsonRpcResponse released;
	released.result = SO.from(["status": "unsubscribed"]);
	connection.respond(successfulRelease, released);
	JsonRpcResponse refused;
	refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest,
		"unsubscribe refused by peer");
	connection.respond(refusedRelease, refused);
	// EOF can arrive before either reply continuation runs.
	connection.disconnect("test EOF", DisconnectType.graceful);
	// Check the retiring server before fanout clears its routes.
	onNextTick(socketManager, {
		assert(!server.hasThreadRouteForTest("unreleased-child"));
	});
	server.confirmedExit(1);
	drainNextTicksAndDueTimers();

	assert(outcomes.length == 5, "all forks must settle after EOF");
	foreach (tid, childId; [2: "child", 6: "unreleased-child"])
	{
		auto outcome = outcomes[tid];
		assert(!outcome.ok && outcome.threadId.length == 0);
		auto detail = tid == 2 ? ": JSON-RPC connection closed: test EOF"
			: " because the Codex app-server exited";
		assert(outcome.error == "Could not release fork child subscription " ~ childId
			~ detail, outcome.error);
		assert(jsonParse!ThreadStartResult(outcome.rawResultJson).thread.id == childId);
	}
	assert(!outcomes[3].ok && outcomes[3].threadId.length == 0
		&& outcomes[3].rawResultJson.length == 0
		&& outcomes[3].error == "JSON-RPC connection closed: test EOF");
	assert(outcomes[4].ok && outcomes[4].threadId == "released-child");
	assert(!outcomes[5].ok && outcomes[5].threadId.length == 0);
	assert(outcomes[5].error ==
		"Could not release fork child subscription refused-child: unsubscribe refused by peer",
		outcomes[5].error);
	assert(jsonParse!ThreadStartResult(outcomes[5].rawResultJson).thread.id == "refused-child");
	assert(connection.sentMessages.length == 0, "retiring fork must not send unsubscribe");
}

// A history is read on the app-server of the task's live session, else on
// the task's own pooled one. The read holds the process until it settles.
unittest
{
	import cydo.agent.drivers.codex.history : CodexHistoryMode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	enum silentThread = `{"thread":{"id":"thread","historyMode":"paginated","cwd":"/work",`
		~ `"cliVersion":"0.171.0","modelProvider":"openai","preview":""}}`;
	enum emptyPage = `{"data":[],"nextCursor":null}`;
	JsonRpcResponse result(string json)
	{
		JsonRpcResponse response;
		response.result = jsonParse!SO(json);
		return response;
	}
	auto profile = NativeHistoryProfile(AgentDriver.codex, "/profile");
	auto agent = new CodexAgent;
	agent.setSystemKeyword("SYSTEM");
	string[] outcomes;
	void observe(Promise!DriverHistory read)
	{
		read.then((DriverHistory history) {
			assert(history.mode == CodexHistoryMode.paginated);
			outcomes ~= "read";
		}, (Exception e) { outcomes ~= e.msg; }).ignoreResult();
	}
	DriverHistoryLaunch noLaunch()
	{
		assert(false, "a live session's history is read on its own app-server");
	}

	// The live session's app-server; the session leaving does not end it
	// while the read lasts.
	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto owner = agent.makeSession(server, 1, SessionConfig.init, RouteOwnerKind.task);
	observe(agent.loadHistory("thread", profile, () => owner, &noLaunch));
	auto read = connection.takeRequest("thread/read");
	owner.closeStdin();
	assert(!server.dead, "the read keeps the app-server");
	connection.respond(read, result(silentThread));
	drainNextTicks();
	connection.respond(connection.takeRequest("thread/turns/list"), result(emptyPage));
	drainNextTicks();
	connection.respond(connection.takeRequest("thread/items/list"), result(emptyPage));
	drainNextTicks();
	assert(outcomes == ["read"] && server.dead, "the settled read lets the app-server go");

	// Without a session: the app-server of the task's own pool key.
	outcomes = null;
	connection = new TestCodexConnection;
	server = makeTestAppServerProcess(connection);
	ProcessLaunch launch;
	launch.nativeHistoryProfile = profile;
	launch.executablePath = "/bin/codex";
	agent.serverPool[agent.serverPoolKey("workspace", launch)] = server;
	SessionConfig config;
	config.workspace = "workspace";
	observe(agent.loadHistory("thread", profile, () => null,
		() => DriverHistoryLaunch(launch, config)));
	read = connection.takeRequest("thread/read");

	// The codec settles the read when the app-server exits.
	connection.disconnect("history server exit", DisconnectType.graceful);
	server.confirmedExit(1);
	drainNextTicksAndDueTimers();
	assert(outcomes == ["JSON-RPC connection closed: history server exit"]);

	// EOF during pagination rejects the history read and releases its server.
	outcomes = null;
	connection = new TestCodexConnection;
	server = makeTestAppServerProcess(connection);
	owner = agent.makeSession(server, 1, SessionConfig.init, RouteOwnerKind.task);
	observe(agent.loadHistory("thread", profile, () => owner, &noLaunch));
	connection.respond(connection.takeRequest("thread/read"), result(silentThread));
	drainNextTicks();
	connection.takeRequest("thread/turns/list");
	owner.closeStdin();
	assert(!server.dead && outcomes.length == 0);
	assert(__traits(getMember, server, "operationRouteReservations_").length == 1);
	connection.disconnect("history EOF", DisconnectType.graceful);
	server.confirmedExit(1);
	drainNextTicksAndDueTimers();
	assert(outcomes == ["JSON-RPC connection closed: history EOF"] && server.dead);
	assert(__traits(getMember, server, "operationRouteReservations_").length == 0);

	// A final page received just before exit still completes the history read.
	outcomes = null;
	connection = new TestCodexConnection;
	server = makeTestAppServerProcess(connection);
	owner = agent.makeSession(server, 1, SessionConfig.init, RouteOwnerKind.task);
	owner.onExit = (int status) { outcomes ~= "exit"; };
	agent.loadHistory("thread", profile, () => owner, &noLaunch)
		.then((DriverHistory history) {
			assert(history.mode == CodexHistoryMode.paginated);
			outcomes ~= "read";
			onNextTick(socketManager, { outcomes ~= "publish"; });
		}, (Exception e) { assert(false, e.msg); }).ignoreResult();
	connection.respond(connection.takeRequest("thread/read"), result(silentThread));
	drainNextTicks();
	connection.respond(connection.takeRequest("thread/turns/list"), result(emptyPage));
	drainNextTicks();
	connection.respond(connection.takeRequest("thread/items/list"), result(emptyPage));
	connection.disconnect("after final history page", DisconnectType.graceful);
	server.confirmedExit(0);
	drainNextTicksAndDueTimers();
	assert(outcomes == ["read", "publish", "exit"]);

	// A cold read cannot use a launch from a different profile.
	outcomes = null;
	auto otherProfile = NativeHistoryProfile(AgentDriver.codex, "/other-codex-profile");
	observe(agent.loadHistory("thread", otherProfile, () => null,
		() => DriverHistoryLaunch(launch, config)));
	drainNextTicks();
	assert(outcomes == ["Codex history for session thread belongs to " ~ otherProfile.root
		~ " but the launch resolves to " ~ profile.root]);

	// A launch that cannot be had is a history that cannot be read.
	outcomes = null;
	observe(agent.loadHistory("thread", profile, () => null,
		delegate DriverHistoryLaunch() { throw new Exception("no sandbox"); }));
	drainNextTicks();
	assert(outcomes == ["no sandbox"]);
}

version (unittest) private struct TestCodexStartup
{
	enum spawnError = "test app-server spawn failed";
	enum profile = NativeHistoryProfile(AgentDriver.codex, "/test-startup-profile");
	enum failingExecutable = "/test-startup/fail";
	enum workingExecutable = "/test-startup/succeed";
	CodexAgent agent;
	TestCodexConnection connection;
	int spawnAttempts;

	static TestCodexStartup create()
	{
		auto agent = new CodexAgent;
		agent.setSystemKeyword("SYSTEM");
		return TestCodexStartup(agent, new TestCodexConnection);
	}

	IConnection spawn(string[] args)
	{
		++spawnAttempts;
		if (args[0] == failingExecutable)
			throw new Exception(spawnError);
		assert(args[0] == workingExecutable);
		return connection;
	}

	Promise!DriverHistory read(string workspace, string executable)
	{
		ProcessLaunch launch;
		launch.nativeHistoryProfile = profile;
		launch.executablePath = executable;
		SessionConfig config;
		config.workspace = workspace;
		return agent.loadHistory("thread", launch.nativeHistoryProfile, () => null,
			() => DriverHistoryLaunch(launch, config));
	}
}

version (unittest) private class TestCodexHistoryFailure
{
	string[] errors;

	this(Promise!DriverHistory read)
	{
		read.then((DriverHistory) { assert(false, "expected history to fail"); },
			(Exception e) { errors ~= e.msg; }).ignoreResult();
	}
}

// A synchronous spawn failure must leave the same pool key available for retry.
unittest
{
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto startup = TestCodexStartup.create();
	AppServerProcess.spawnForTest = &startup.spawn;
	scope (exit) AppServerProcess.spawnForTest = null;

	auto first = new TestCodexHistoryFailure(startup.read("retry", startup.failingExecutable));
	drainNextTicksAndDueTimers();
	assert(first.errors == [startup.spawnError]);
	assert(startup.agent.serverPool.length == 0 && startup.agent.appServerStartupGates.length == 0);
	auto second = new TestCodexHistoryFailure(startup.read("retry", startup.failingExecutable));
	drainNextTicksAndDueTimers();
	assert(second.errors == [startup.spawnError], "same-key retry did not receive the spawn error");

	// Keep the pool key unchanged and let the third attempt supply a connection.
	AppServerProcess.spawnForTest = (string[] args) {
		assert(args[0] == startup.failingExecutable);
		++startup.spawnAttempts;
		return startup.connection;
	};
	startup.read("retry", startup.failingExecutable).ignoreResult();
	auto initialize = startup.connection.takeRequest("initialize");
	assert(startup.spawnAttempts == 3);
	JsonRpcResponse initialized;
	initialized.result = jsonParse!SO("{}");
	startup.connection.respond(initialize, initialized);
	drainNextTicks();
	auto server = startup.agent.serverPool.values[0];
	startup.agent.shutdownAllServers();
	startup.connection.disconnect("cleanup", DisconnectType.graceful);
	server.confirmedExit(0);
	drainNextTicksAndDueTimers();
}

// A failure after a reader has joined the startup queue must reject that reader.
unittest
{
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;
	import std.exception : collectException;

	auto startup = TestCodexStartup.create();
	AppServerProcess.spawnForTest = &startup.spawn;
	scope (exit) AppServerProcess.spawnForTest = null;

	auto gate = new AppServerStartupGate;
	gate.busy = true;
	startup.agent.appServerStartupGates[startup.profile.root] = gate;
	auto reader = new TestCodexHistoryFailure(startup.read("queued", startup.failingExecutable));
	drainNextTicks();
	assert(startup.spawnAttempts == 0 && reader.errors.length == 0);

	gate.busy = false;
	auto escaped = collectException(startup.agent.startNextAppServerStartup(startup.profile.root));
	drainNextTicksAndDueTimers();
	assert(reader.errors == [startup.spawnError], "queued reader did not receive the spawn error");
	assert(escaped is null, "queued spawn failure escaped startup");
	assert(startup.agent.serverPool.length == 0 && startup.agent.appServerStartupGates.length == 0);
}

// A queued spawn failure released by initialize must leave the first server's login intact.
unittest
{
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;
	import std.process : environment;

	auto startup = TestCodexStartup.create();
	AppServerProcess.spawnForTest = &startup.spawn;
	scope (exit) AppServerProcess.spawnForTest = null;
	auto previousKey = environment.get("CODEX_API_KEY", null);
	environment["CODEX_API_KEY"] = "test-startup-key";
	scope (exit)
	{
		if (previousKey is null)
			environment.remove("CODEX_API_KEY");
		else
			environment["CODEX_API_KEY"] = previousKey;
	}

	startup.read("initializing", startup.workingExecutable).ignoreResult();
	auto initialize = startup.connection.takeRequest("initialize");
	startup.read("queued", startup.failingExecutable).ignoreResult();
	assert(startup.spawnAttempts == 1, "second startup must wait for initialize");

	JsonRpcResponse initialized;
	initialized.result = jsonParse!SO("{}");
	startup.connection.respond(initialize, initialized);
	drainNextTicks();
	assert(startup.spawnAttempts == 2, "initialize must release the queued startup");
	assert(startup.connection.sentMessages.length > 0,
		"queued spawn failure prevented the initialized server from logging in");
	auto login = startup.connection.takeRequest("account/login/start");
	JsonRpcResponse loggedIn;
	loggedIn.result = jsonParse!SO(`{"success":true}`);
	startup.connection.respond(login, loggedIn);
	drainNextTicks();
	startup.connection.takeRequest("thread/read");
	auto server = startup.agent.serverPool.values[0];
	startup.agent.shutdownAllServers();
	startup.connection.disconnect("cleanup", DisconnectType.graceful);
	server.confirmedExit(0);
	drainNextTicksAndDueTimers();
}

unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;
	import std.process : environment;

	auto previousKey = environment.get("CODEX_API_KEY", null);
	environment["CODEX_API_KEY"] = "test-startup-key";
	scope (exit)
	{
		if (previousKey is null)
			environment.remove("CODEX_API_KEY");
		else
			environment["CODEX_API_KEY"] = previousKey;
	}

	foreach (phase; ["initialize", "login notification", "confirmed exit"])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection, true);
		auto agent = new CodexAgent;
		auto pending = new TestCodexHistoryFailure(agent.readHistoryOn(server, "thread",
			delegate const(bool[string])() { return null; }));
		int shutdowns;
		server.onShutdown_ = { ++shutdowns; };
		JsonRpcResponse initialized;
		initialized.result = jsonParse!SO("{}");
		connection.respond(connection.takeRequest("initialize"), initialized);
		if (phase == "login notification")
		{
			drainNextTicks();
			JsonRpcResponse acknowledged;
			acknowledged.result = jsonParse!SO("{}");
			connection.respond(connection.takeRequest("account/login/start"), acknowledged);
			drainNextTicks();
			assert(server.state == AppServerProcess.State.authenticating);
		}
		connection.disconnect(phase, DisconnectType.graceful);
		assert(server.dead && shutdowns == 1);
		if (phase != "confirmed exit")
		{
			drainNextTicks();
			assert(pending.errors.length == 0);
		}
		server.confirmedExit(1);
		drainNextTicksAndDueTimers();
		assert(server.state == AppServerProcess.State.dead && shutdowns == 1);
		assert(pending.errors == ["JSON-RPC connection closed: " ~ phase]);
		string[] lateErrors;
		server.onReady({ assert(false); }, (Exception e) { lateErrors ~= e.msg; });
		assert(lateErrors == pending.errors);
		assert(connection.sentMessages.length == 0, "disconnected server attempted another request");
	}
}

// A late initialize failure must preserve the replacement at the same pool key.
unittest
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto startup = TestCodexStartup.create();
	AppServerProcess.spawnForTest = &startup.spawn;
	scope (exit) AppServerProcess.spawnForTest = null;

	ProcessLaunch launch;
	launch.nativeHistoryProfile = startup.profile;
	launch.executablePath = startup.workingExecutable;
	auto key = startup.agent.serverPoolKey("replacement", launch);
	auto original = startup.agent.getOrCreateServer(key, launch);
	auto initialize = startup.connection.takeRequest("initialize");

	auto replacement = makeTestAppServerProcess(new TestCodexConnection);
	startup.agent.serverPool[key] = replacement;
	scope (exit) replacement.shutdown();

	JsonRpcResponse refused;
	refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest,
		"mock initialize rejected");
	startup.connection.respond(initialize, refused);
	drainNextTicks();
	assert(original.dead, "initialize rejection must shut down the original server");
	auto pooled = key in startup.agent.serverPool;
	assert(pooled !is null && *pooled is replacement,
		"failed startup evicted its same-key replacement");
	assert(startup.agent.getOrCreateServer(key, launch) is replacement);
	original.confirmedExit(0);
	drainNextTicksAndDueTimers();
	assert(startup.agent.appServerStartupGates.length == 0);
}

// An initialize error settles every startup waiter with the server diagnostic.
unittest
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection, true);
	auto initialize = connection.takeRequest("initialize");
	auto agent = new CodexAgent;
	agent.setSystemKeyword("SYSTEM");
	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
	launch.executablePath = "/unused/codex";
	SessionConfig config;
	config.workspace = "startup-error";
	agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;
	auto session = cast(CodexSession) agent.createSession(1, null, launch, config);
	auto queued = new TestSubmissionOutcome(session.sendMessage(
		[ContentBlock("text", "queued during initialize")], "startup-queued"));
	int[] exits;
	session.onExit = (int status) { exits ~= status; };
	auto operation = agent.openForkSourceOwner(2, "thread", launch, config);
	string routeFailure;
	operation.routeReady.then((CodexSession) { assert(false, "failed startup acquired a route"); },
		(Exception e) { routeFailure = e.msg; }).ignoreResult();
	string historyFailure;
	agent.loadHistory("thread", launch.nativeHistoryProfile, () => null,
		() => DriverHistoryLaunch(launch, config))
		.then((DriverHistory) { assert(false, "failed startup loaded history"); },
			(Exception e) { historyFailure = e.msg; }).ignoreResult();

	enum diagnostic = "mock initialize rejected";
	JsonRpcResponse refused;
	refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest, diagnostic);
	connection.respond(initialize, refused);
	drainNextTicks();
	assert(server.dead && exits.length == 0 && historyFailure is null && routeFailure is null);
	assert(queued.rejectedCount == 0 && queued.acceptedCount == 0);
	server.confirmedExit(0);
	drainNextTicksAndDueTimers();
	assert(historyFailure == diagnostic, "history must receive the initialize error");
	assert(routeFailure == diagnostic);
	assert(queued.rejectedCount == 1 && queued.rejectionMessage == diagnostic);
	assert(server.dead && exits == [1]);
	assert(__traits(getMember, server, "operationRouteReservations_").length == 0);
	assert(connection.sentMessages.length == 0, "a rejected initialize must not start login or a thread");
}


// A closed startup still owns its task route until the reply or server exit.
unittest
{
	import std.algorithm : canFind;
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	enum End { attachReply, startupFailure, serverExit }
	string[] prematureExits;
	void exercise(string resumeId, End end, string label)
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.executablePath = "/unused/codex";
		launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
		SessionConfig config;
		config.workspace = "close-startup";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;
		auto reasonToKeepServer = resumeId.length == 0
			? server.reserveOperationRouteTid() : 0;
		if (resumeId.length != 0)
		{
			agent.createSession(2, null, launch, config);
			connection.takeRequest("thread/start");
		}

		auto session = cast(CodexSession) agent.createSession(1, resumeId, launch, config);
		auto method = resumeId.length == 0 ? "thread/start" : "thread/resume";
		auto request = connection.takeRequest(method);
		int[] exits;
		session.onExit = (int status) { exits ~= status; };
		session.closeStdin();
		auto submitted = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "after close")], "after-close"));
		drainNextTicks();
		assert(submitted.rejectedCount == 1 && submitted.acceptedCount == 0);
		assert(!server.dead);
		if (!session.alive || exits.length != 0)
			prematureExits ~= label;

		auto threadId = resumeId.length == 0 ? "fresh-thread" : resumeId;
		JsonRpcResponse resp;
		if (end == End.attachReply)
		{
			ThreadStartResult result;
			result.thread.id = threadId;
			resp.result = SO.from(result);
		}
		else
			resp.error = JsonRpcError.fromCode(JsonRpcErrorCode.internalError, "startup interrupted");

		if (end == End.serverExit)
		{
			server.terminate();
			server.confirmedExit(0);
		}
		connection.respond(request, resp);
		drainNextTicksAndDueTimers();
		// On the baseline the orphan route is observable even after the early exit.
		if (server.hasThreadRouteForTest(threadId))
			prematureExits ~= label ~ ": orphan route";
		if (prematureExits.canFind(label))
			return;
		assert(!session.alive && exits.length == 1);
		if (end == End.attachReply)
		{
			auto release = connection.takeRequest("thread/unsubscribe");
			assert(jsonParse!ThreadUnsubscribeParams(toJson(release.params)).threadId == threadId);
			if (resumeId.length != 0)
			{
				auto next = cast(CodexSession) agent.createSession(1, resumeId, launch, config);
				connection.respond(connection.takeRequest("thread/resume"), resp);
				drainNextTicks();
				assert(next.alive && server.hasThreadRouteForTest(threadId));
			}
		}
		assert(connection.sentMessages.length == 0);
		if (reasonToKeepServer != 0 && end != End.serverExit)
		{
			server.cancelOperationRouteReservation(reasonToKeepServer);
			assert(server.dead);
		}
	}
	exercise("thread-a", End.attachReply, "late resume success");
	exercise(null, End.attachReply, "late start success");
	exercise("thread-a", End.serverExit, "server exit during close");
	exercise(null, End.startupFailure, "startup rejection during close");
	assert(prematureExits.length == 0, toJson(prematureExits));
}

// Session discovery names each thread once, by its newest rollout.
unittest
{
	import core.time : seconds;
	import std.datetime.systime : Clock;
	import std.file : mkdirRecurse, rmdirRecurse, setTimes, tempDir, write;
	import std.process : thisProcessID;

	auto root = buildPath(tempDir, "cydo-codex-discovery-" ~ thisProcessID.to!string);
	scope (exit) rmdirRecurse(root);
	auto day = buildPath(root, "sessions", "2026", "11", "22");
	mkdirRecurse(day);
	enum thread = "01a1feac-c4fb-7600-9ec5-7f31ac22c94a";
	enum other = "01a1feae-9e4c-7d83-a43c-dbd595e0221d";
	auto now = Clock.currTime;
	string rollout(string name, int age)
	{
		auto path = buildPath(day, name ~ ".jsonl");
		write(path, "");
		setTimes(path, now - age.seconds, now - age.seconds);
		return path;
	}
	rollout("rollout-2026-11-22T10-00-00-" ~ thread, 30);
	auto newest = rollout("rollout-2026-11-22T10-05-00-" ~ thread ~ "_r2", 10);
	rollout("rollout-2026-11-22T10-02-00-" ~ thread ~ "_r1", 20);
	auto single = rollout("rollout-2026-11-22T11-00-00-" ~ other, 5);

	auto profile = NativeHistoryProfile(AgentDriver.codex, root);
	string[string] found;
	foreach (session; (new CodexAgent).enumerateAllSessions(profile))
	{
		assert(session.sessionId !in found);
		found[session.sessionId] = session.exactHistoryPath;
	}
	assert(found == [thread: newest, other: single]);
}

// A start reply that still needs a live owner leaves settlement to confirmed exit.
unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	foreach (exitInSameTick; [false, true])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
		launch.executablePath = "/unused/codex";
		SessionConfig config;
		config.workspace = "start-reply-eof";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;
		auto session = cast(CodexSession) agent.createSession(1, null, launch, config);
		int[] exits;
		session.onExit = (int status) { exits ~= status; };
		auto submission = new TestSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "queued")], "queued"));

		JsonRpcResponse reply;
		reply.result = jsonParse!SO(`{"thread":{"id":"thread"}}`);
		connection.respond(connection.takeRequest("thread/start"), reply);
		connection.disconnect("after thread/start reply", DisconnectType.graceful);
		if (!exitInSameTick)
		{
			drainNextTicks();
			assert(server.dead && exits.length == 0);
			assert(submission.acceptedCount == 0 && submission.rejectedCount == 0);
			assert(connection.sentMessages.length == 0);
		}
		server.confirmedExit(7);
		drainNextTicksAndDueTimers();

		assert(exits == [7]);
		assert(submission.acceptedCount == 0 && submission.rejectedCount == 1);
		assert(connection.sentMessages.length == 0);
	}
}

unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto agent = new CodexAgent;
	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
	launch.executablePath = "/unused/codex";
	SessionConfig config;
	config.workspace = "resume-reply-eof";
	agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;
	auto owner = agent.openForkSourceOwner(2, "thread", launch, config);
	int closed;
	string[] errors;
	owner.onClosed = { ++closed; };
	owner.routeReady.then((CodexSession) { assert(false, "acquired a route after EOF"); },
		(Exception e) { errors ~= e.msg; }).ignoreResult();

	JsonRpcResponse reply;
	reply.result = jsonParse!SO(`{"thread":{"id":"thread"}}`);
	connection.respond(connection.takeRequest("thread/resume"), reply);
	connection.disconnect("after thread/resume reply", DisconnectType.graceful);
	drainNextTicks();
	assert(closed == 0 && errors.length == 0 && connection.sentMessages.length == 0);
	server.confirmedExit(7);
	drainNextTicksAndDueTimers();

	assert(closed == 1 && errors.length == 1 && connection.sentMessages.length == 0);
}

// Retirement fixes the route's status and stops new requests in the EOF tick.
unittest
{
	import cydo.agent.drivers.codex.app_server : CodexSessionRouteTarget;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicksAndDueTimers;
	import std.exception : assertThrown;

	enum Cause { readyEOF, terminate, shutdown, initializeEOF }
	foreach (cause; [Cause.readyEOF, Cause.terminate, Cause.shutdown, Cause.initializeEOF])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection, cause == Cause.initializeEOF);
		if (cause == Cause.initializeEOF)
			connection.takeRequest("initialize");
		int[] exits;
		CodexSessionRouteTarget route;
		route.onServerExit = (int status) { exits ~= status; };
		server.registerSessionByTid(1, route);
		auto reservation = server.reserveOperationRouteTid();
		int expected;
		final switch (cause)
		{
		case Cause.readyEOF: expected = 7; break;
		case Cause.terminate: server.terminate(); expected = 143; break;
		case Cause.shutdown: server.shutdown(); expected = 1; break;
		case Cause.initializeEOF: expected = 1; break;
		}
		connection.disconnect("test EOF", DisconnectType.graceful);
		string[] rejected;
		server.sendRequest("test/new", "{}")
			.then((JsonRpcResponse) { assert(false, "retired server answered a request"); },
				(Exception e) { rejected ~= e.msg; }).ignoreResult();
		assert(server.dead && connection.sentMessages.length == 0);
		server.shutdown();
		server.confirmedExit(cause == Cause.readyEOF || cause == Cause.initializeEOF ? 7 : 0);
		server.confirmedExit(99);
		assert(exits.length == 0);
		drainNextTicksAndDueTimers();

		assert(rejected == ["Codex app-server is not running"] && exits == [expected]);
		assertThrown!Exception(server.registerSessionByTid(2, route));
		server.cancelOperationRouteReservation(reservation);
	}
}

unittest
{
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	auto startup = TestCodexStartup.create();
	auto replacementConnection = new TestCodexConnection;
	AppServerProcess.spawnForTest = (string[] args) {
		return ++startup.spawnAttempts == 1 ? startup.connection : replacementConnection;
	};
	scope (exit) AppServerProcess.spawnForTest = null;
	ProcessLaunch launch;
	launch.nativeHistoryProfile = startup.profile;
	launch.executablePath = startup.workingExecutable;
	auto key = startup.agent.serverPoolKey("same-key", launch);
	auto first = startup.agent.getOrCreateServer(key, launch);
	startup.connection.takeRequest("initialize");

	startup.connection.disconnect("gate holder EOF", DisconnectType.graceful);
	assert(key !in startup.agent.serverPool);
	auto replacement = startup.agent.getOrCreateServer(key, launch);
	drainNextTicks();
	assert(startup.spawnAttempts == 1 && startup.agent.appServerStartupGates[startup.profile.root].busy);
	assert(replacementConnection.sentMessages.length == 0);

	first.confirmedExit(1);
	drainNextTicksAndDueTimers();
	assert(startup.spawnAttempts == 2 && startup.agent.serverPool[key] is replacement);
	replacementConnection.takeRequest("initialize");
	replacementConnection.disconnect("cleanup", DisconnectType.graceful);
	replacement.confirmedExit(1);
	drainNextTicksAndDueTimers();
	assert(startup.agent.appServerStartupGates.length == 0);
}

// A startup deadline releases a live initializer's lease. After EOF, the
// lease must stay held until confirmed exit.
unittest
{
	import core.time : MonoTime;
	import cydo.foundation.testing : drainNextTicksAndDueTimers;

	foreach (retiring; [false, true])
	{
		auto startup = TestCodexStartup.create();
		auto replacementConnection = new TestCodexConnection;
		AppServerProcess.spawnForTest = (string[] args) {
			return ++startup.spawnAttempts == 1 ? startup.connection : replacementConnection;
		};
		scope (exit) AppServerProcess.spawnForTest = null;
		auto first = new AppServerProcess([startup.workingExecutable]);
		auto replacement = new AppServerProcess([startup.workingExecutable]);
		auto request = startup.agent.queueAppServerStartup(startup.profile.root, first);
		startup.connection.takeRequest("initialize");
		if (retiring)
			startup.connection.disconnect("gate holder EOF", DisconnectType.graceful);
		startup.agent.queueAppServerStartup(startup.profile.root, replacement);
		assert(startup.spawnAttempts == 1);

		request.lease.timeout.restart(MonoTime.currTime());
		drainNextTicksAndDueTimers();
		if (retiring)
		{
			assert(startup.spawnAttempts == 1 && replacementConnection.sentMessages.length == 0,
				"startup deadline started a replacement before confirmed exit");
		}
		else
		{
			assert(first.state == AppServerProcess.State.initializing);
			assert(startup.spawnAttempts == 2, "live initializer held its lease past the deadline");
			startup.connection.disconnect("cleanup", DisconnectType.graceful);
		}

		first.confirmedExit(7);
		drainNextTicksAndDueTimers();
		assert(startup.spawnAttempts == 2);
		replacementConnection.takeRequest("initialize");
		replacementConnection.disconnect("cleanup", DisconnectType.graceful);
		replacement.confirmedExit(1);
		drainNextTicksAndDueTimers();
		assert(startup.agent.appServerStartupGates.length == 0);
	}
}

// Read the handshake failure before EOF, without running its continuation
// until the server has begun retiring.
unittest
{
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import cydo.agent.drivers.codex.app_server : CodexSessionRouteTarget;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;
	import std.process : environment;

	auto previousKey = environment.get("CODEX_API_KEY", null);
	environment["CODEX_API_KEY"] = "test-startup-key";
	scope (exit)
	{
		if (previousKey is null)
			environment.remove("CODEX_API_KEY");
		else
			environment["CODEX_API_KEY"] = previousKey;
	}

	foreach (method; ["initialize", "account/login/start"])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection, true);
		auto request = connection.takeRequest("initialize");
		if (method == "account/login/start")
		{
			JsonRpcResponse initialized;
			initialized.result = jsonParse!SO("{}");
			connection.respond(request, initialized);
			drainNextTicks();
			request = connection.takeRequest(method);
		}

		string[] errors;
		int[] exits;
		server.onReady({ assert(false, "failed startup reached readiness"); },
			(Exception e) { errors ~= e.msg; });
		CodexSessionRouteTarget route;
		route.onServerExit = (int status) { exits ~= status; };
		server.registerSessionByTid(1, route);

		auto diagnostic = method ~ " refused by peer";
		JsonRpcResponse refused;
		refused.error = JsonRpcError.fromCode(JsonRpcErrorCode.internalError, diagnostic);
		connection.respond(request, refused);
		connection.disconnect("handshake EOF", DisconnectType.graceful);
		drainNextTicks();
		assert(server.state == AppServerProcess.State.retiring);
		assert(errors.length == 0 && exits.length == 0 && connection.sentMessages.length == 0);

		server.confirmedExit(42);
		drainNextTicksAndDueTimers();
		assert(server.state == AppServerProcess.State.dead && connection.sentMessages.length == 0);
		assert(errors == [diagnostic], toJson(errors));
		assert(exits == [1]);
	}
}

// An unanswered setup RPC rejects queued work before the owner reports child exit.
unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.foundation.testing : drainNextTicks, drainNextTicksAndDueTimers;

	foreach (resumeId; [null, "thread"])
	foreach (terminate; [false, true])
	foreach (queueSubmission; [false, true])
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, "/profile");
		launch.executablePath = "/unused/codex";
		SessionConfig config;
		config.workspace = "pending-setup-eof";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;
		auto session = agent.createSession(1, resumeId, launch, config);
		int[] exits;
		enum error = "JSON-RPC connection closed: while setup is pending";
		session.onExit = (int status) {
			assert(session.startupFailure == error, session.startupFailure);
			exits ~= status;
		};
		TestSubmissionOutcome submission;
		if (queueSubmission)
			submission = new TestSubmissionOutcome(
				session.sendMessage([ContentBlock("text", "queued")], "queued"));
		connection.takeRequest(resumeId is null ? "thread/start" : "thread/resume");

		if (terminate)
			server.terminate();
		connection.disconnect("while setup is pending", DisconnectType.graceful);
		drainNextTicks();
		assert(exits.length == 0);
		assert(session.startupFailure == error, session.startupFailure);
		if (queueSubmission)
			assert(submission.acceptedCount == 0 && submission.rejectedCount == 1
				&& submission.rejectionMessage == error);

		server.confirmedExit(73);
		drainNextTicksAndDueTimers();
		server.confirmedExit(74);
		drainNextTicksAndDueTimers();
		assert(exits == [terminate ? 143 : 73] && !session.alive);
		if (queueSubmission)
			assert(submission.acceptedCount == 0 && submission.rejectedCount == 1);
		assert(connection.sentMessages.length == 0);
	}
}
