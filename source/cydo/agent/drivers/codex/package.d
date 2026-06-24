module cydo.agent.drivers.codex;

import core.time : Duration, seconds;

import std.conv : to;
import std.logger : errorf, tracef, warningf;
import std.path : buildPath, dirName;

import ae.sys.data : Data;
import ae.utils.time.types : AbsTime;
import ae.utils.json : JSONExtras, JSONFragment, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.serialization.json : JSONName;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);
import ae.utils.promise : Promise, resolve;

import cydo.agent.contract : Agent, DiscoveredSession, ForkableIdInfo, OneShotHandle, RewindResult, SessionConfig, SessionMeta;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.drivers.codex.app_server : CodexSessionRouteTarget;
public import cydo.agent.drivers.codex.process : AppServerProcess;
public import cydo.agent.drivers.codex.rollout;
public import cydo.agent.drivers.codex.rpc;
import cydo.protocol : ContentBlock, ProcessStderrEvent, SessionCompactedEvent,
	TranslatedEvent, extrasToFragment;
import cydo.agent.session : AgentSession;
import cydo.runtime.config : AgentDriver, PathMode;
import cydo.runtime.launch.types : ProcessLaunch;
import cydo.runtime.launch.sandbox : cleanup, cydoBinaryDir, cydoBinaryPath, effectiveEnvValue,
	executableMountPaths, resolveExecutablePath;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.foundation.text.title : truncateTitle;

// ---------------------------------------------------------------------------
// CodexAgent — Agent descriptor for OpenAI Codex CLI.
// ---------------------------------------------------------------------------

class CodexAgent : Agent
{
	private AppServerProcess[string] serverPool; // keyed by workspace+sandbox signature
	private string[string] modelAliasOverrides;
	private string lastMcpConfigPath_;
	// sessionId → rollout JSONL path. Populated lazily by populateSessionIndex
	// (called from historyPath on first use and from enumerateAllSessions).
	private string[string] sessionIdToPath_;
	private bool sessionIndexBuilt_;
	// History replay state: tracks whether task_started has been seen in the current replay.
	private bool histSeenTaskStarted_;

	void resetHistoryReplay()
	{
		histSeenTaskStarted_ = false;
	}

	void configureSandbox(ref PathMode[string] paths, ref string[string] env)
	{
		import std.algorithm : startsWith;
		import std.process : environment;

		void addIfNotRw(string path, PathMode mode)
		{
			if (path.length == 0)
				return;
			if (mode == PathMode.ro)
			{
				if (auto existing = path in paths)
					if (*existing == PathMode.rw)
						return;
				foreach (existing, existingMode; paths)
					if (existingMode == PathMode.rw && path.startsWith(existing ~ "/"))
						return;
			}
			paths[path] = mode;
		}

		// Codex home directory (config, sessions)
		auto home = environment.get("HOME", "/tmp");
		auto codexHome = environment.get("CODEX_HOME", buildPath(home, ".codex"));
		paths[codexHome] = PathMode.rw;

		auto codexPath = resolveExecutablePath(executableName(env), env);
		foreach (path; executableMountPaths(codexPath))
			addIfNotRw(path, PathMode.ro);
		if (dirName(codexPath) == home ~ "/.npm-packages/bin")
			addIfNotRw(home ~ "/.npm-packages", PathMode.ro);

		addIfNotRw(cydoBinaryDir(), PathMode.ro);

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
		passthrough("CODEX_HOME");
	}

	@property string gitName() { return "Codex CLI"; }
	@property string gitEmail() { return "noreply@openai.com"; }
	override @property AgentDriver driver() { return AgentDriver.codex; }
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
		auto session = new CodexSession(server, tid, config);
		server.registerSessionByTid(tid, session.asRouteTarget());

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");
		auto devInstructions = buildDeveloperInstructions();

		// Build config override (reasoning summary + MCP tools).
		auto configOverride = buildConfigOverride(tid,
			config.creatableTaskTypes, config.switchModes, config.handoffs,
			config.includeTools, config.mcpSocketPath);

		server.onReady(() {
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

				server.sendRequest("thread/start",
					toJson(tsp)
				).then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
						warningf("thread/start error: %s", e.msg);
					registerSessionPath(result.thread.id, result.thread.path);
					session.onThreadStarted(result, null, model, workDir,
						resp.result.toJson());
				});
			}

			if (resumeSessionId.length > 0)
			{
				ThreadResumeParams trp;
				trp.threadId = resumeSessionId;
				trp.model = model;
				trp.cwd = workDir;
				trp.approvalPolicy = "never";
				trp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					trp.developerInstructions = devInstructions;
				trp.config = JSONFragment(configOverride);

				server.sendRequest("thread/resume",
					toJson(trp)
				).then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
					{
						warningf("thread/resume error: %s", e.msg);
						if (session.outputHandler_)
						{
							ProcessStderrEvent ev;
							ev.text = "thread/resume error: " ~ e.msg;
							session.outputHandler_(TranslatedEvent(toJson(ev), null));
						}
						session.closeStdin();
						return;
					}
					if (result.thread.id.length == 0)
					{
						warningf("thread/resume returned empty thread id");
						if (session.outputHandler_)
						{
							ProcessStderrEvent ev;
							ev.text = "thread/resume returned empty thread id";
							session.outputHandler_(TranslatedEvent(toJson(ev), null));
						}
						session.closeStdin();
						return;
					}
					registerSessionPath(result.thread.id, result.thread.path);
					session.onThreadStarted(result, resumeSessionId, model, workDir,
						resp.result.toJson());
				});
			}
			else
				startFreshThread();
		});

		return session;
	}

	Promise!ThreadForkOutcome forkSession(int tid, string sourceThreadId,
		ProcessLaunch launch, SessionConfig config = SessionConfig.init,
		string sourcePath = null)
	{
		auto outcome = new Promise!ThreadForkOutcome;
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, launch), launch);
		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");
		auto devInstructions = buildDeveloperInstructions();
		auto configOverride = buildConfigOverride(tid,
			config.creatableTaskTypes, config.switchModes, config.handoffs,
			config.includeTools, config.mcpSocketPath);

		server.onReady(() {
			ThreadForkParams tfp;
			tfp.threadId = sourceThreadId;
			if (sourcePath.length > 0)
				tfp.path = sourcePath;
			tfp.model = model;
			tfp.cwd = workDir;
			tfp.approvalPolicy = "never";
			tfp.sandbox = "danger-full-access";
			if (devInstructions.length > 0)
				tfp.developerInstructions = devInstructions;
			tfp.config = JSONFragment(configOverride);

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
					outcome.fulfill(ThreadForkOutcome(true, result.thread.id,
						resp.result.toJson(), ""));
				});
		});

		return outcome;
	}

	/// Roll back `numTurns` turns from the end of the given thread.
	/// The session must be alive and idle (no turn in progress).
	Promise!ThreadRollbackOutcome rollbackThread(string threadId, uint numTurns,
		ProcessLaunch launch, string workspace = "")
	{
		auto outcome = new Promise!ThreadRollbackOutcome;
		auto ws = workspace.length > 0 ? workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(ws, launch), launch);

		server.onReady(() {
			ThreadRollbackParams params;
			params.threadId = threadId;
			params.numTurns = numTurns;

			server.sendRequest("thread/rollback", toJson(params))
				.then((JsonRpcResponse resp) {
					try
						resp.getResult!SO(); // throws on RPC error
					catch (Exception e)
					{
						outcome.fulfill(ThreadRollbackOutcome(false, e.msg));
						return;
					}
					outcome.fulfill(ThreadRollbackOutcome(true, ""));
				});
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
		string[] codexArgs = [codexBin, "app-server", "--listen", "stdio://"];
		string[] args;
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto server = new AppServerProcess(args);
		serverPool[poolKey] = server;
		server.onShutdown_ = { serverPool.remove(poolKey); };
		return server;
	}

	/// Shut down all pooled server processes (safety net for app shutdown).
	void shutdownAllServers()
	{
		auto servers = serverPool.values;
		serverPool = null;
		foreach (server; servers)
			server.shutdown();
	}

	string parseSessionId(string line)
	{
		import std.algorithm : canFind;
		// CodexSession emits agnostic events; look for session/init.
		if (!line.canFind(`"session/init"`))
			return null;

		@JSONPartial
		static struct InitProbe
		{
			string type;
			string session_id;
		}

		try
		{
			auto probe = jsonParse!InitProbe(line);
			if (probe.type == "session/init" && probe.session_id.length > 0)
				return probe.session_id;

			warningf("Unexpected session/init event: %s", line);
			return null;
		}
		catch (Exception e)
		{
			warningf("Error parsing session id: %s", e.msg);
			return null;
		}
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

	void setModelAliases(string[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	string resolveModelAlias(string modelClass)
	{
		if (auto p = modelClass in modelAliasOverrides)
			return *p;
		switch (modelClass)
		{
			case "small":  return "gpt-5.3-codex-spark";
			case "medium": return "gpt-5.4";
			case "large":  return "gpt-5.5";
			default:       return "gpt-5.4-mini";
		}
	}

	string historyPath(string sessionId, string projectPath)
	{
		if (sessionId.length == 0)
			return null;
		if (auto p = sessionId in sessionIdToPath_)
			return *p;
		// Codex stores sessions at ~/.codex/sessions/YYYY/MM/DD/rollout-*-<threadId>.jsonl
		// with an unknown timestamp prefix, so we maintain an in-memory index built
		// by a single recursive scan rather than scanning per call (O(tasks × N) at
		// startup otherwise).
		if (!sessionIndexBuilt_)
			populateSessionIndex(null);
		if (auto p = sessionId in sessionIdToPath_)
			return *p;
		// Miss after initial build — could be a session created after the scan
		// (e.g. a fresh fork). Rebuild once and retry. Repeated lookups for the
		// same missing session will still rescan, but that path is exercised only
		// by runtime callers, not the M-task startup loop.
		populateSessionIndex(null);
		if (auto p = sessionId in sessionIdToPath_)
			return *p;
		return null;
	}

	private void registerSessionPath(string sessionId, string path)
	{
		if (sessionId.length == 0 || path.length == 0)
			return;
		sessionIdToPath_[sessionId] = path;
	}

	private void populateSessionIndex(DiscoveredSession[]* outDiscovered)
	{
		import std.file : DirEntry, dirEntries, exists, SpanMode;
		import std.path : baseName, buildPath;
		import std.process : environment;
		import std.regex : ctRegex, matchFirst;

		auto home = environment.get("HOME", "/tmp");
		auto codexHome = environment.get("CODEX_HOME", buildPath(home, ".codex"));
		auto sessionsDir = buildPath(codexHome, "sessions");

		sessionIdToPath_ = null;
		sessionIndexBuilt_ = true;
		if (!exists(sessionsDir))
			return;

		// Codex rollout filenames: rollout-<YYYY>-<MM>-<DD>T<HH>-<MM>-<SS>-<UUID>.jsonl
		// The UUID (8-4-4-4-12 hex) is the session id; it matches parseSessionId.
		enum uuidRx = ctRegex!`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`;
		try
		{
			foreach (DirEntry entry; dirEntries(sessionsDir, "*.jsonl", SpanMode.depth))
			{
				auto base = baseName(entry.name, ".jsonl");
				auto m = base.matchFirst(uuidRx);
				auto sessionId = m.empty ? base : m.hit;
				sessionIdToPath_[sessionId] = entry.name;
				if (outDiscovered !is null)
				{
					DiscoveredSession ds;
					ds.sessionId = sessionId;
					ds.mtime = entry.timeLastModified.stdTime;
					ds.projectPath = "";
					*outDiscovered ~= ds;
				}
			}
		}
		catch (Exception e)
		{ tracef("populateSessionIndex(codex): error scanning %s: %s", sessionsDir, e.msg); }
	}

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		import std.conv : to;
		import cydo.protocol : parseIso8601Timestamp;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		@JSONPartial static struct TimestampProbe { @JSONOptional string timestamp; }
		AbsTime ts;
		try { ts = parseIso8601Timestamp(jsonParse!TimestampProbe(line).timestamp); }
		catch (Exception) {}

		auto probe = parseRolloutLineProbe(line);
		if (probe.isSessionMeta)
		{
			auto t = translateRolloutSessionMeta(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		else if (probe.isResponseItem)
		{
			// Pass line-number fork ID for user/assistant messages
			string forkId = null;
			if (probe.isForkableMessage)
				forkId = "line:" ~ to!string(lineNum);
			// Lines before task_started are system context injected by Codex — mark as meta.
			bool forceMeta = !histSeenTaskStarted_;
			auto results = translateRolloutResponseItem(line, forkId, forceMeta);
			TranslatedEvent[] evs;
			foreach (r; results)
				evs ~= TranslatedEvent(r, line, ts);
			return evs;
		}
		else if (probe.isEventMsg)
		{
			if (!histSeenTaskStarted_ && probe.isTaskStarted)
				histSeenTaskStarted_ = true;
			auto t = translateRolloutEventMsg(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		// Skip turn_context, compacted, unknown
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

	bool isUserMessageLine(string rawLine)
	{
		return parseRolloutLineProbe(rawLine).isUserMessage;
	}

	bool isAssistantMessageLine(string rawLine)
	{
		return parseRolloutLineProbe(rawLine).isAssistantMessage;
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"threadId":"` ~ oldId ~ `"`, `"threadId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	string[] extractForkableIds(string content, int lineOffset = 0)
	{
		import std.conv : to;
		import std.string : lineSplitter;

		string[] ids;
		int lineNum = lineOffset;
		// Codex prepends system context as a role=user response_item before the
		// first task_started event.  Skip role=user lines until task_started is
		// seen so the system context is not treated as a forkable user message.
		// lineOffset > 0 means we're reading past the startup section already.
		bool seenTaskStarted = lineOffset > 0;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			auto probe = parseRolloutLineProbe(line);
			if (!seenTaskStarted && probe.isTaskStarted)
			{
				seenTaskStarted = true;
				continue;
			}
			// Handle ThreadRolledBack markers: remove last N user-turn groups
			if (probe.isThreadRolledBack)
			{
				if (probe.rollbackNumTurns > 0)
					ids = applyRollbackToIds(ids, probe.rollbackNumTurns);
				continue;
			}
			// Forkable: message response_item with role user or assistant
			if (!probe.isForkableMessage)
				continue;
			// Skip pre-session role=user lines (system context injected before task_started).
			if (probe.isUserMessage && !seenTaskStarted)
				continue;
			if (probe.isUserMessage && isCodexContextOnlyUserMessageLine(line))
				continue;
			ids ~= "line:" ~ to!string(lineNum);
		}
		return ids;
	}

	ForkableIdInfo[] extractForkableIdsWithInfo(string content, int lineOffset = 0)
	{
		return extractForkableIdsWithInfoImpl(content, lineOffset);
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.conv : to;
		// Fork IDs are "line:<N>" — match on line number
		if (forkId.length > 5 && forkId[0 .. 5] == "line:")
		{
			try
				return lineNum == to!int(forkId[5 .. $]);
			catch (Exception)
				return false;
		}
		return false;
	}

	bool isForkableLine(string line)
	{
		return parseRolloutLineProbe(line).isForkableMessage;
	}

	@property bool needsBash() { return false; }
	@property bool supportsFileRevert() { return false; }
	// https://github.com/openai/codex/issues/19045
	// Codex app-server developerInstructions are unreliable after
	// thread/resume and keep-context mode switches, so task system prompts
	// must be delivered via normal user input instead.
	@property bool supportsDeveloperPrompt() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, string cwd,
		ProcessLaunch launch = ProcessLaunch.init)
	{
		return RewindResult(false, "File revert is not supported for Codex sessions");
	}

	/// Currently unused — no callers in the codebase. Implement if a caller is added.
	string extractUserText(string line) { return ""; }

	DiscoveredSession[] enumerateAllSessions()
	{
		DiscoveredSession[] result;
		populateSessionIndex(&result);
		return result;
	}

	SessionMeta readSessionMeta(string sessionId)
	{
		import std.algorithm : canFind;
		import std.stdio : File;
		auto pathp = sessionId in sessionIdToPath_;
		if (pathp is null)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(*pathp, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				// Extract cwd from session_meta line
				if (meta.projectPath.length == 0 && lineStr.canFind(`"type":"session_meta"`))
				{
					@JSONPartial
					static struct SessionMetaProbe
					{
						@JSONPartial
						static struct Payload { string cwd; }
						Payload payload;
					}
					try
					{
						auto probe = jsonParse!SessionMetaProbe(lineStr);
						if (probe.payload.cwd.length > 0)
							meta.projectPath = probe.payload.cwd;
					}
					catch (Exception) {}
				}
				// Extract title from first user response_item
				if (meta.title.length == 0 && lineStr.canFind(`"type":"response_item"`)
					&& lineStr.canFind(`"role":"user"`))
				{
					@JSONPartial
					static struct RiProbe
					{
						@JSONPartial
						static struct Payload
						{
							string role;
							@JSONPartial
							static struct ContentItem { string type; string text; }
							ContentItem[] content;
						}
						Payload payload;
					}
					try
					{
						auto probe = jsonParse!RiProbe(lineStr);
						if (probe.payload.role == "user")
						{
							string text;
							foreach (ref ci; probe.payload.content)
								if (ci.type == "input_text" || ci.type == "text")
									text ~= ci.text;
							if (text.length > 0)
								meta.title = truncateTitle(text, 80);
						}
					}
					catch (Exception) {}
				}
				if (meta.title.length > 0 && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{ tracef("readSessionMeta(codex, %s): error: %s", sessionId, e.msg); }
		return meta;
	}

	string matchProject(string sessionId, const string[] knownProjectPaths) { return ""; }

	private string codexHomeForLaunch(ProcessLaunch launch)
	{
		import std.process : environment;

		auto home = environment.get("HOME", "/tmp");
		return effectiveEnvValue(launch.sandbox.env, "CODEX_HOME",
			buildPath(home, ".codex"));
	}

	private string prepareIsolatedOneShotHome(ProcessLaunch launch)
	{
		import std.file : copy, exists, mkdirRecurse;
		import std.uuid : randomUUID;

		// Codex 0.139 roots its SQLite state runtime at CODEX_HOME.  Keep
		// short-lived `codex exec` runs off the app-server's state database,
		// while preserving the configured provider/auth settings.
		auto codexHome = codexHomeForLaunch(launch);
		auto oneShotHome = buildPath(codexHome, "oneshot", randomUUID().toString());
		mkdirRecurse(oneShotHome);

		auto configPath = buildPath(codexHome, "config.toml");
		if (exists(configPath))
			copy(configPath, buildPath(oneShotHome, "config.toml"));
		mkdirRecurse(buildPath(oneShotHome, "shell_snapshots"));
		return oneShotHome;
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch = ProcessLaunch.init)
	{
		import std.file : rmdirRecurse;
		import std.string : strip;

		auto promise = new Promise!string;
		auto oneShotHome = prepareIsolatedOneShotHome(launch);
		auto oneShotLaunch = launchSandbox.withProcessLaunchEnv(launch, "CODEX_HOME",
			oneShotHome);

		string[] codexArgs = [
			oneShotLaunch.executablePath.length > 0
				? oneShotLaunch.executablePath
				: executableName(oneShotLaunch.sandbox.env),
			"exec",
			"--ephemeral",
			"--skip-git-repo-check",
			"-m", resolveModelAlias(modelClass),
			prompt,
		];
		auto args = oneShotLaunch.cmdPrefix !is null
			? oneShotLaunch.cmdPrefix ~ codexArgs
			: codexArgs;

		AgentProcess proc;
		try
			// When sandboxed, cmdPrefix carries the resolved env/cwd. Otherwise
			// inherit the parent environment, matching AppServerProcess.
			// --skip-git-repo-check avoids the "not inside a trusted directory"
			// error when the process CWD is not a git repo root.
			proc = new AgentProcess(args, noStdin: true,
				mode: FramingMode.raw, logName: "codex-oneshot");
		catch (Exception e)
		{
			cleanup(oneShotLaunch.sandbox);
			try rmdirRecurse(oneShotHome);
			catch (Exception cleanupError)
				warningf("completeOneShot: failed to remove %s: %s",
					oneShotHome, cleanupError.msg);
			errorf("completeOneShot: failed to spawn codex: %s", e.msg);
			promise.reject(new Exception("failed to spawn codex: " ~ e.msg));
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
			try rmdirRecurse(oneShotHome);
			catch (Exception e)
				warningf("completeOneShot: failed to remove %s: %s",
					oneShotHome, e.msg);

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
}

// ---------------------------------------------------------------------------
// CodexSession — one Codex thread, implementing AgentSession.
// ---------------------------------------------------------------------------

class CodexSession : AgentSession
{
	private AppServerProcess server;
	private int tid;
	private string threadId;
	private string activeTurnId_;
	private string model;
	private string workDir;
	private bool alive_;
	private bool turnInProgress;
	private bool hadItemsSinceLastStop_;

	// Active item tracking for item/delta routing.
	private string activeItemId_;              // most recently started item (for delta routing)
	private string[string] activeItemTypes_;   // itemId → itemType for all active items
	private int itemCounter_;                  // monotonic counter for generating item IDs
	private string lastResultText_;             // last completed text content, for turn/result

	private string sessionId;
	private string agentName_;

	// Queued messages waiting for thread to be ready.
	private ContentBlock[][] pendingMessages;

	// Nonce of the in-flight user message; tagged onto the user_message echo.
	private string pendingTurnCorrelationId_;

	// Callbacks
	package void delegate(TranslatedEvent) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;
	private void delegate(string nonce) agentAckHandler_;

	this(AppServerProcess server, int tid, SessionConfig config)
	{
		this.server = server;
		this.tid = tid;
		this.alive_ = true;
		this.agentName_ = config.agentName;
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

	/// Called when thread/start or thread/resume response arrives.
	package void onThreadStarted(ThreadStartResult result, string resumeId,
		string model, string workDir, string rawResultJson)
	{
		this.model = model;
		this.workDir = workDir;

		if (result.thread.id.length > 0)
			threadId = result.thread.id;

		if (threadId.length == 0 && resumeId.length > 0)
			threadId = resumeId;

		if (threadId.length == 0)
		{
			if (outputHandler_)
			{
				ProcessStderrEvent ev;
				ev.text = "Failed to start Codex thread";
				outputHandler_(TranslatedEvent(toJson(ev), null));
			}
			return;
		}

		sessionId = threadId;
		server.registerSession(threadId, asRouteTarget());

		// Emit synthetic session/init with raw RPC response as _raw.
		import cydo.protocol : SessionInitEvent;
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

		// Drain queued messages now that the thread is ready.
		drainPendingMessages();
	}

	private void drainPendingMessages()
	{
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (msg; queued)
			sendMessage(msg);
	}

	package void handleTurnStarted(TurnRef turn)
	{
		if (turn.id.length == 0)
			return;
		activeTurnId_ = turn.id;
		drainPendingMessages();
	}

	/// Called when the app-server process dies.
	package void onServerExit(int status)
	{
		if (!alive_)
			return; // Already stopped; avoid double-invocation of exitHandler_.
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(status);
	}

	// ----- AgentSession interface -----

	void sendMessage(const(ContentBlock)[] content, string correlationId = null)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Codex: " ~ b.type);
		}

		if (!alive_)
			return;

		// Queue message if thread hasn't been created yet.
		if (threadId.length == 0)
		{
			pendingMessages ~= content.dup;
			return;
		}

		if (turnInProgress)
		{
			if (activeTurnId_.length == 0)
			{
				pendingMessages ~= content.dup;
				return;
			}
			pendingTurnCorrelationId_ = correlationId;
			auto steerCid = correlationId;
			server.sendRequest("turn/steer",
				toJson(TurnSteerParams(
					threadId,
					[TurnStartInput("text", text)],
					activeTurnId_))).then((JsonRpcResponse resp) {
				if (!resp.isError && steerCid.length > 0 && agentAckHandler_)
					agentAckHandler_(steerCid);
			});
		}
		else
		{
			turnInProgress = true;
			activeTurnId_ = null;
			activeItemId_ = null;
			activeItemTypes_ = null;
			hadItemsSinceLastStop_ = false;
			pendingTurnCorrelationId_ = correlationId;

			auto startCid = correlationId;
			server.sendRequest("turn/start",
				toJson(TurnStartParams(
					threadId,
					[TurnStartInput("text", text)],
					SandboxPolicy("externalSandbox", "enabled"))))
				.then((JsonRpcResponse resp) {
				try
				{
					auto result = resp.getResult!TurnStartResult();
					handleTurnStarted(result.turn);
					if (startCid.length > 0 && agentAckHandler_)
						agentAckHandler_(startCid);
				}
				catch (Exception e)
				{
					warningf("turn/start error: %s", e.msg);
				}
			});
		}
	}

	@property bool supportsImages() const { return false; }

	@property bool canRollbackThread() const
	{
		return alive_ && threadId.length > 0 && !turnInProgress;
	}

	void interrupt()
	{
		if (!alive_ || threadId.length == 0 || !turnInProgress || activeTurnId_.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			toJson(TurnInterruptParams(threadId, activeTurnId_))).ignoreResult();
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		// Codex sessions share a pooled app-server process. Kill is an
		// emergency stop that terminates that process and lets onServerExit
		// propagate the real exit to all attached sessions.
		server.terminate();
	}

	void closeStdin()
	{
		if (!alive_)
			return;
		if (threadId.length > 0)
			server.unregisterSession(threadId);
		server.unregisterSessionByTid(tid);
		activeTurnId_ = null;
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(0); // zero = clean close
	}

	void killAfterTimeout(Duration timeout) {} // no-op: closeStdin fires exit immediately

	@property bool canStopAfterCloseStdin() const
	{
		return true;
	}

	@property void onAgentAck(void delegate(string nonce) dg) { agentAckHandler_ = dg; }
	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- Notification handling (routed by CodexServerRouter) -----

	package void handleItemStarted(ItemStartedParams params, string rawNotification)
	{
		import cydo.protocol : ItemStartedEvent;
		if (params.turnId.length > 0)
			activeTurnId_ = params.turnId;

		auto item = params.item;

		ItemStartedEvent ev;

		if (item.type == "userMessage")
		{
			// Echo user message as item/started type=user_message.
			if (item.content && outputHandler_)
			{
				ev.item_type = "user_message";
				// Extract text from content array: [{type:"input_text",text:"..."}]
				@JSONPartial
				static struct InputTextItem { @JSONOptional string text; }
				string userText;
				try
				{
					auto items = jsonParse!(InputTextItem[])(toJson(item.content));
					foreach (ref i; items)
						userText ~= i.text;
				}
				catch (Exception) {}
				if (userText.length == 0)
					userText = item.text;
				ev.item_id = "codex-user-" ~ to!string(itemCounter_++);
				ContentBlock cb;
				cb.type = "text";
				cb.text = userText;
				ev.content = [cb];
				ev.correlation_id = pendingTurnCorrelationId_;
				pendingTurnCorrelationId_ = null;
				outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
			}
			return;
		}

		hadItemsSinceLastStop_ = true;

		// Assign item ID: use native id if available, else generate one.
		auto itemId = item.id.length > 0 ? item.id : "codex-item-" ~ to!string(itemCounter_++);
		activeItemId_ = itemId;

		switch (item.type)
		{
			case "agentMessage":
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				// Reset + capture text for result extraction. Text may arrive
				// fully formed here (no deltas) or be empty with deltas following.
				lastResultText_ = item.text;
				break;
			case "reasoning":
				activeItemTypes_[itemId] = "thinking";
				ev.item_type = "thinking";
				break;
			case "commandExecution":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "commandExecution";
				string cmdInput = extractCommandExecutionInput(
					item.commandActions ? JSONFragment(toJson(item.commandActions)) : JSONFragment.init,
					item.action ? JSONFragment(toJson(item.action)) : JSONFragment.init,
					item.command);
				if (cmdInput.length > 0 && cmdInput != `{}`)
					ev.input = JSONFragment(cmdInput);
				break;
			case "fileChange":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "fileChange";
				// Include changes directly so the frontend can show the File Viewer button
				// without relying on _raw (which is stripped before broadcast).
				if (item.changes)
					ev.input = JSONFragment(`{"changes":` ~ toJson(item.changes) ~ `}`);
				break;
			case "mcpToolCall":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				if (item.tool.length > 0)
				{
					ev.name = item.tool;
					if (item.server.length > 0)
					{
						ev.tool_server = item.server;
						ev.tool_source = "mcp";
					}
				}
				else
					ev.name = item.name.length > 0 ? item.name : "unknown";
				if (item.arguments_)
					ev.input = JSONFragment(toJson(item.arguments_));
				break;
			case "webSearch":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "webSearch";
				if (item.query)
					ev.input = JSONFragment(`{"query":` ~ toJson(item.query) ~ `}`);
				break;
			case "contextCompaction":
				activeItemTypes_[itemId] = "contextCompaction";
				import cydo.protocol : SessionStatusEvent;
				SessionStatusEvent statusEv;
				statusEv.status = "Compacting context...";
				if (outputHandler_)
					outputHandler_(TranslatedEvent(toJson(statusEv), rawNotification));
				return;  // Emit session/status instead of item/started
			default:
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				break;
		}

		ev.item_id = itemId;

		// If item/started already contains text (e.g. during history replay),
		// include it directly in the event.
		if (item.text.length > 0)
			ev.text = item.text;

		// Forward Codex extras (processId, status, cwd, commandActions, etc.) to extras.
		ev.extras = extrasToFragment(item.extras);

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
		// Determine which item completed: prefer explicit ID from params.
		string itemId = (params.item.id.length > 0) ? params.item.id : activeItemId_;
		if (itemId.length == 0)
			return;

		// Look up item type from map.
		auto pType = itemId in activeItemTypes_;
		if (pType is null)
			return; // unknown item, skip
		string itemType = *pType;

		if (itemType == "contextCompaction")
		{
			// Codex 0.139 reports compaction as an item instead of sending the
			// older thread/compacted notification.  Clear the transient status
			// and emit CyDo's durable compact-boundary event.
			import cydo.protocol : SessionStatusEvent;
			SessionStatusEvent clearEv;
			if (outputHandler_)
			{
				outputHandler_(TranslatedEvent(toJson(clearEv), rawNotification));
				outputHandler_(TranslatedEvent(toJson(SessionCompactedEvent()), rawNotification));
			}
			activeItemTypes_.remove(itemId);
			if (activeItemId_ == itemId)
				activeItemId_ = null;
			return;
		}

		import cydo.protocol : ItemCompletedEvent, ItemResultEvent;
		ItemCompletedEvent ev;
		ev.item_id = itemId;
		ev.is_error = params.item.is_error;
		// Derive is_error from Codex status field (Codex uses "failed" instead of is_error).
		if (!ev.is_error && params.item.status == "failed")
			ev.is_error = true;

		if (itemType == "tool_use" && params.item.aggregatedOutput.length > 0)
			ev.output = params.item.aggregatedOutput;

		// Forward remaining Codex extras (processId, commandActions, type, etc.) to extras.
		ev.extras = extrasToFragment(params.item.extras);

		// For webSearch items, propagate the completed query into the input field
		// so the frontend subtitle updates from the empty started-query to the real query.
		if (params.item.type == "webSearch" && params.item.query)
			ev.input = JSONFragment(`{"query":` ~ toJson(params.item.query) ~ `}`);

		if (outputHandler_)
			outputHandler_(TranslatedEvent(toJson(ev), rawNotification));

		// Emit item/result for tool_use items so the frontend can display the output.
		// item/result must come AFTER item/completed so the tool_use block is
		// already in content[] when reduceItemResult searches for it.
		if (itemType == "tool_use" && outputHandler_)
		{
			ItemResultEvent resEv;
			resEv.item_id = itemId;
			resEv.is_error = ev.is_error;
			string toolErrorMessage;
			if (resEv.is_error && params.item.error)
			{
				@JSONPartial
				static struct ItemErrorPayload
				{
					@JSONOptional string message;
				}

				try
				{
					toolErrorMessage = jsonParse!ItemErrorPayload(toJson(params.item.error)).message;
				}
				catch (Exception) {}

				if (toolErrorMessage.length == 0)
				{
					try
					{
						toolErrorMessage = jsonParse!string(toJson(params.item.error));
					}
					catch (Exception) {}
				}
			}

			// Item type is now an explicit field.
			string itemTypeName = params.item.type;

			if (params.item.aggregatedOutput.length > 0)
				resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(params.item.aggregatedOutput) ~ `}]`);
			else
			{
				@JSONPartial
				static struct ResultPayload
				{
					@JSONOptional JSONFragment content;
					@JSONName("structuredContent") @JSONOptional JSONFragment structuredContent;
				}

				bool hasResultContent = false;
				if (params.item.result)
				{
					try
					{
						auto payload = jsonParse!ResultPayload(toJson(params.item.result));
						if (payload.content.json !is null)
						{
							resEv.content = payload.content;
							hasResultContent = true;
						}
						if (payload.structuredContent.json !is null)
							resEv.tool_result = payload.structuredContent;
					}
					catch (Exception) {}
				}

				if (!hasResultContent)
				{
					if (itemTypeName == "webSearch")
					{
						// Pass Codex web search data as structured tool_result for the frontend
						// to interpret. Set content to empty text (required field).
						if (toolErrorMessage.length > 0)
							resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
						else
							resEv.content = JSONFragment(`[{"type":"text","text":""}]`);

						import std.array : appender;
						auto tr = appender!string;
						tr ~= `{`;

						// Include the main query
						if (params.item.query)
							tr ~= `"query":` ~ toJson(params.item.query);

						// Include the queries array from action
						if (params.item.action)
						{
							@JSONPartial
							static struct WebSearchAction
							{
								@JSONOptional JSONFragment queries;  // preserve raw JSON
							}
							try
							{
								auto act = jsonParse!WebSearchAction(toJson(params.item.action));
								if (act.queries.json !is null)
								{
									if (params.item.query)
										tr ~= `,`;
									tr ~= `"queries":` ~ act.queries.json;
								}
							}
							catch (Exception) {}
						}

						tr ~= `}`;
						resEv.tool_result = JSONFragment(tr.data);
					}
					else if (toolErrorMessage.length > 0)
						resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
					else
						resEv.content = JSONFragment(`[{"type":"text","text":""}]`);
				}
			}

			// Build structured tool_result for commandExecution items.
			// Surfaces exitCode, status, durationMs, command, cwd for frontend rendering.
			if (itemTypeName == "commandExecution")
			{
				import std.array : appender;
				auto tr = appender!string;
				tr ~= `{`;
				bool trFirst = true;
				if (params.item.status.length > 0)
				{
					tr ~= `"status":` ~ toJson(params.item.status);
					trFirst = false;
				}
				// Always include exitCode for commandExecution items.
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"exitCode":` ~ to!string(params.item.exitCode);
					trFirst = false;
				}
				if (params.item.durationMs > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"durationMs":` ~ to!string(params.item.durationMs);
					trFirst = false;
				}
				if (params.item.command.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"command":` ~ toJson(params.item.command);
					trFirst = false;
				}
				if (params.item.cwd.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"cwd":` ~ toJson(params.item.cwd);
					trFirst = false;
				}
				if (params.item.processId.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"processId":` ~ toJson(params.item.processId);
					trFirst = false;
				}
				if (params.item.commandActions)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"commandActions":` ~ toJson(params.item.commandActions);
					trFirst = false;
				}
				tr ~= `}`;
				if (!trFirst)
					resEv.tool_result = JSONFragment(tr.data);
			}

			outputHandler_(TranslatedEvent(toJson(resEv), rawNotification));
		}

		// Remove from tracking.
		activeItemTypes_.remove(itemId);
		if (activeItemId_ == itemId)
			activeItemId_ = null;
	}

	package void handleTurnCompleted(string rawNotification)
	{
		turnInProgress = false;
		activeTurnId_ = null;

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
			import cydo.protocol : TurnResultEvent, UsageInfo;
			TurnResultEvent tre;
			tre.subtype = "success";
			tre.num_turns = 1;
			tre.usage = UsageInfo(0, 0);
			tre.result = lastResultText_;
			outputHandler_(TranslatedEvent(toJson(tre), rawNotification));
		}
		lastResultText_ = null;
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

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Build a JSON config override object passed as the "config" field in
/// thread/start params. Includes reasoning summary and, when available,
/// MCP server config for CyDo tools.
string buildConfigOverride(int tid, string creatableTaskTypes,
	string switchModes, string handoffs, string[] includeTools, string mcpSocketPath)
{
	import std.array : join;
	import std.process : environment;

	JSONFragment[string] config;

	// Always request reasoning summaries from the model.
	config["model_reasoning_summary"] = JSONFragment(`"auto"`);

	// If CYDO_CODEX_COMPACT_LIMIT is set (test-only), override compaction threshold.
	auto compactLimit = environment.get("CYDO_CODEX_COMPACT_LIMIT", "");
	if (compactLimit.length > 0)
	{
		config["model_auto_compact_token_limit"] = JSONFragment(compactLimit);
		config["model_context_window"] = JSONFragment(compactLimit);
	}

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length > 0)
	{
		string[string] env;
		env["CYDO_TID"] = to!string(tid);
		env["CYDO_SOCKET"] = mcpSocketPath;
		env["CYDO_CREATABLE_TYPES"] = creatableTaskTypes;
		env["CYDO_SWITCHMODES"] = switchModes;
		env["CYDO_HANDOFFS"] = handoffs;
		env["CYDO_INCLUDE_TOOLS"] = includeTools is null ? "" : includeTools.join(",");

		auto serverConfig = McpServerConfig(
			cydoBin,
			["mcp-server"],
			env,
			100000000,
		);

		config["mcp_servers.cydo"] = JSONFragment(toJson(serverConfig));
	}

	return toJson(config);
}

/// Extract display-level command input from a live Codex commandExecution item.
string extractCommandExecutionInput(JSONFragment commandActions, JSONFragment action, string command)
{
	import std.algorithm.searching : canFind;
	import cydo.protocol : CommandInput;

	auto actionCommand = extractCommandActionsCommand(commandActions);
	if (actionCommand.length > 0)
	{
		if (command.length == 0 || !command.canFind('\n') || actionCommand.canFind('\n'))
			return toJson(CommandInput(actionCommand, ""));
	}

	auto fromAction = extractCommandInput(action);
	if (fromAction.length > 0 && fromAction != `{}`)
		return fromAction;

	if (command.length > 0)
		return toJson(CommandInput(command, ""));

	return actionCommand.length > 0 ? toJson(CommandInput(actionCommand, "")) : `{}`;
}

/// Extract a fallback command from Codex commandActions when no executed command
/// field is available.
string extractCommandActionsInput(JSONFragment commandActions)
{
	auto command = extractCommandActionsCommand(commandActions);
	if (command.length == 0)
		return `{}`;

	import cydo.protocol : CommandInput;
	return toJson(CommandInput(command, ""));
}

/// Extract a single user-level command from Codex commandActions.
string extractCommandActionsCommand(JSONFragment commandActions)
{
	if (commandActions.json is null || commandActions.json.length == 0)
		return "";

	@JSONPartial
	static struct CommandAction
	{
		@JSONOptional string command;
	}

	try
	{
		auto actions = jsonParse!(CommandAction[])(commandActions.json);
		if (actions.length != 1 || actions[0].command.length == 0)
			return "";
		return actions[0].command;
	}
	catch (Exception e)
	{ tracef("extractCommandActionsInput: parse error: %s", e.msg); }
	return "";
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

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
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
	ThreadForkParams tfp;
	tfp.threadId = "thread-parent";
	tfp.path = "/tmp/fork-source.jsonl";
	tfp.model = "gpt-5.3-codex";
	tfp.cwd = "/tmp/worktree";
	tfp.approvalPolicy = "never";
	tfp.sandbox = "danger-full-access";
	tfp.developerInstructions = "dev-instructions";
	tfp.config = JSONFragment(`{"mcp_servers.cydo":{"command":"cydo"}}`);
	auto forkJson = toJson(tfp);
	assert(
		forkJson == `{"threadId":"thread-parent","path":"/tmp/fork-source.jsonl","model":"gpt-5.3-codex","cwd":"/tmp/worktree","approvalPolicy":"never","sandbox":"danger-full-access","developerInstructions":"dev-instructions","config":{"mcp_servers.cydo":{"command":"cydo"}}}`,
		"thread/fork payload must preserve the source thread id/path; actual=" ~ forkJson,
	);

	auto steerJson = toJson(TurnSteerParams(
		"thread-steer",
		[TurnStartInput("text", "stage and nix flake check")],
		"turn-steer",
	));
	assert(
		steerJson == `{"threadId":"thread-steer","input":[{"type":"text","text":"stage and nix flake check"}],"expectedTurnId":"turn-steer"}`,
		"turn/steer payload must use input + expectedTurnId for Codex v2; actual=" ~ steerJson,
	);

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
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-ask","item":{"id":"mcp-call-ask","result":{"content":[{"type":"text","text":"User has answered your questions: \"Do you agree?\"=\"Yes\"."}]}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);

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
	session.handleTurnCompleted(`{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-ask"}}`);
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

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
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

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
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
