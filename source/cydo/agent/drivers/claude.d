module cydo.agent.drivers.claude;

import core.time : Duration, seconds;

import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName, expandTilde;
import std.logger : errorf, tracef, warningf;
import std.math : isNaN;
import std.typecons : Nullable;

import ae.sys.file : realPath;
import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, reject, resolve;
import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	PersistedHistoryBoundary, PersistedHistoryBoundaryKind, OneShotHandle,
	RewindResult, SessionConfig, SessionMeta;
import cydo.protocol;
import cydo.domain.policy.permissions : PermissionEscalation, PermissionPrompt,
	ToolCallDecision, ToolCallRuling;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt, BackgroundWork, MessageSource;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	NativeProfileSupportRequirement, ProcessLaunch, ResolvedSandbox;
import cydo.runtime.launch.sandbox : buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	effectiveEnvValue, executableMountPaths, resolveExecutablePath;
import cydo.foundation.text.title : truncateTitle;

/// Agent descriptor for Claude Code CLI.
class ClaudeCodeAgent : Agent
{
	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		foreach (path; executableMountPaths(resolveExecutablePath(executableName(env), env)))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "claude",
					"Claude executable"));

		if ("PATH" !in env)
		{
			auto hostPath = effectiveEnvValue(env, "PATH", "");
			if (hostPath.length > 0)
				env["PATH"] = hostPath;
		}

		// Enable file-history-snapshot creation in SDK/headless mode.
		// Claude Code's KX9() guard requires this env var for checkpointing.
		env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";

		// The user's claude.ai connectors (mail, calendar, ...) belong to
		// their account, not to the task. A configured value re-enables them.
		if ("ENABLE_CLAUDEAI_MCP_SERVERS" !in env)
			env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false";

		// Disable Claude Code's MCP tool idle watchdog. The generated cydo server
		// config separately raises its hard wall-clock timeout to the maximum.
		// CyDo task-interop calls can intentionally block while a sub-task works.
		env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] = "0";
	}
	@property string gitName() { return "Claude Code"; }
	@property string gitEmail() { return "noreply@anthropic.com"; }
	override @property AgentDriver driver() { return AgentDriver.claude; }
	override @property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(
			AgentDriver.claude,
			"CLAUDE_CONFIG_DIR",
			".claude",
			[
				NativeProfileSupportRequirement(".claude.json", PathAccess.rw,
					"Claude state file"),
				NativeProfileSupportRequirement(".local/share/claude", PathAccess.ro,
					"Claude data directory"),
			],
		);
	}
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_CLAUDE_BIN", "claude");
	}

	private ModelSpec[string] modelAliasOverrides;
	private string lastMcpConfigPath_;
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }

	// Claude names its per-project history directory after the CLI process's
	// own observed CWD. Sandbox path rewriting can spell that CWD differently
	// from any path CyDo derives (a symlink kept literal inside the sandbox
	// resolves on the host), so sessions are located by ID, never derived
	// from a CWD. registeredHistoryPaths_ holds exact locations CyDo learned
	// first-hand (live session init, fork creation, discovery import);
	// scannedHistoryPaths_ is a once-per-profile disk snapshot. The snapshot
	// is authoritative for its root: a miss never rescans, so a profile is
	// scanned exactly once per process no matter how many absent sessions
	// are looked up.
	private string[string][string] registeredHistoryPaths_; // root → session ID → path
	private string[string][string] scannedHistoryPaths_;    // root → session ID → path

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		lastMcpConfigPath_ = generateMcpConfig(tid, launch.nativeHistoryProfile,
			config.creatableTaskTypes,
			config.switchModes, config.handoffs, config.includeTools, config.mcpSocketPath);
		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		auto profile = launch.nativeHistoryProfile;
		return new ClaudeCodeSession(claudeBin, resumeSessionId, launch.cmdPrefix,
			lastMcpConfigPath_, config,
			(string sessionId, string cwd) {
				registerLiveHistoryPath(sessionId, cwd, profile);
			});
	}

	string extractResultText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			// ClaudeCodeSession emits translated turn/result events.
			if (probe.type == "turn/result" || probe.type == "result")
				return probe.result;
			return "";
		}
		catch (Exception e)
		{ tracef("extractResultText: parse error: %s", e.msg); return ""; }
	}

	string extractAssistantText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		// New format: item/started with item_type=text carries the full text
		// (present in history-translated events from translateAssistantHistory).
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

	string extractUserText(string line)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		if (!line.canFind(`"type":"user"`) && !line.canFind(`"type":"message/user"`))
			return "";

		// Try parsing with string content first
		@JSONPartial
		static struct StringMessage { string content; }
		@JSONPartial
		static struct StringProbe { string type; StringMessage message; }

		try
		{
			auto probe = jsonParse!StringProbe(line);
			if ((probe.type == "user" || probe.type == "message/user") && probe.message.content.length > 0)
				return probe.message.content;
		}
		catch (Exception) {}

		// Try parsing with array content
		@JSONPartial
		static struct ContentBlock { string type; string text; }
		@JSONPartial
		static struct ArrayMessage { ContentBlock[] content; }
		@JSONPartial
		static struct ArrayProbe { string type; ArrayMessage message; }

		try
		{
			auto probe = jsonParse!ArrayProbe(line);
			if (probe.type != "user" && probe.type != "message/user")
				return "";
			string result;
			foreach (ref block; probe.message.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception e)
		{ tracef("extractUserContent: all parse attempts failed: %s", e.msg); return ""; }
	}

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, isDir, SpanMode;
		import std.path : baseName, buildPath;

		enforce(profile.driver == driver,
			"Claude history profile driver does not match Claude");
		auto projectsDir = buildPath(profile.root, "projects");
		if (!exists(projectsDir) || !isDir(projectsDir))
			return [];

		DiscoveredSession[] result;
		size_t[string] sessionIndices;
		foreach (DirEntry projEntry; dirEntries(projectsDir, SpanMode.shallow))
		{
			if (!projEntry.isDir)
				continue;

			try
			{
				foreach (DirEntry fileEntry; dirEntries(projEntry.name, "*.jsonl", SpanMode.shallow))
				{
					auto sessionId = baseName(fileEntry.name, ".jsonl");
					DiscoveredSession ds;
					ds.sessionId = sessionId;
					ds.mtime = fileEntry.timeLastModified.stdTime;
					ds.projectPath = "";
					ds.exactHistoryPath = fileEntry.name;
					if (auto index = sessionId in sessionIndices)
					{
						if (ds.mtime > result[*index].mtime)
							result[*index] = ds;
					}
					else
					{
						sessionIndices[sessionId] = result.length;
						result ~= ds;
					}
				}
			}
			catch (Exception e)
			{ tracef("enumerateAllSessions: error scanning %s: %s", projEntry.name, e.msg); }
		}
		return result;
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.stdio : File;
		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				// Extract cwd from init event (first line is typically system/init)
				if (meta.projectPath.length == 0 && lineStr.length > 0)
				{
					import std.algorithm : canFind;
					if (lineStr.canFind(`"type":"system"`) && lineStr.canFind(`"subtype":"init"`))
					{
						@JSONPartial
						static struct InitProbe
						{
							string type;
							string subtype;
							string cwd;
						}
						try
						{
							auto probe = jsonParse!InitProbe(lineStr);
							if (probe.type == "system" && probe.subtype == "init" && probe.cwd.length > 0)
								meta.projectPath = probe.cwd;
						}
						catch (Exception) {}
					}
				}
				// Extract title from first user message
				if (meta.title.length == 0)
				{
					auto text = extractUserText(lineStr);
					if (text.length > 0)
						meta.title = truncateTitle(text, 80);
				}
				if (meta.title.length > 0 && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{ tracef("readSessionMeta(%s): error: %s", session.sessionId, e.msg); }
		meta.hasMessages = meta.title.length > 0;
		return meta;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths)
	{
		import std.path : baseName, dirName;

		if (session.exactHistoryPath.length == 0)
			return "";
		auto dirName_ = baseName(dirName(session.exactHistoryPath));
		foreach (known; knownProjectPaths)
		{
			if (mangleProjectPath(known) == dirName_)
				return known;
		}
		return "";
	}

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "haiku";
			case "medium": return "sonnet";
			case "large":  return "opus";
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
		auto agent = new ClaudeCodeAgent();

		// 14. with no overrides, hardcoded defaults and empty effort
		assert(agent.resolveModelSpec("small") == ModelSpec(ModelSpecFields("haiku")));
		assert(agent.resolveModelSpec("medium") == ModelSpec(ModelSpecFields("sonnet")));
		assert(agent.resolveModelSpec("large") == ModelSpec(ModelSpecFields("opus")));

		// 15. an override replaces the default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
		assert(agent.resolveModelSpec("large").model == "custom-model");

		// 16. an effort-only override keeps the driver's default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
		auto effortOnly = agent.resolveModelSpec("large");
		assert(effortOnly.model == "opus");
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

	string historyPath(string sessionId, const ref NativeHistoryProfile profile)
	{
		enforce(profile.driver == driver,
			"Claude history profile driver does not match Claude");
		enforce(sessionId.length > 0,
			"Claude history path requires a session ID");
		if (auto registered = profile.root in registeredHistoryPaths_)
			if (auto path = sessionId in *registered)
				return *path;
		if (auto scanned = profile.root in scannedHistoryPaths_)
		{
			if (auto path = sessionId in *scanned)
				return *path;
			return null;
		}
		// First lookup for this root: take the one snapshot. Sessions that
		// appear later are registered at their point of creation, so an
		// absent session cannot trigger repeated scans.
		string[string] paths;
		foreach (ref session; enumerateAllSessions(profile))
			paths[session.sessionId] = session.exactHistoryPath;
		scannedHistoryPaths_[profile.root] = paths;
		if (auto path = sessionId in paths)
			return *path;
		return null;
	}

	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile)
	{
		import std.algorithm.searching : startsWith;
		import std.path : buildPath, isAbsolute;
		enforce(profile.driver == driver,
			"Claude history profile driver does not match Claude");
		enforce(sessionId.length > 0,
			"Claude history registration requires a session ID");
		auto projectsDir = buildPath(profile.root, "projects");
		enforce(path.length > 0 && isAbsolute(path)
			&& path.startsWith(projectsDir ~ "/"),
			"Claude history path is not inside the supplied profile projects directory");
		if (auto registered = profile.root in registeredHistoryPaths_)
			if (auto existing = sessionId in *registered)
			{
				enforce(*existing == path,
					"Claude session " ~ sessionId
					~ " is already registered at a different history path");
				return;
			}
		registeredHistoryPaths_[profile.root][sessionId] = path;
	}

	/// Bind a live session to its history file, given the CWD its init event
	/// reported.
	///
	/// Claude names a project directory after the CLI process's own observed
	/// CWD, so that CWD locates the transcript of a session Claude is
	/// *creating*. It does not locate the transcript of one that already
	/// exists — Claude keeps appending to the file it has, wherever that is,
	/// and merely materializes an empty project directory for the new name.
	/// The two disagree in two ways seen in practice:
	///
	/// - the session CWD moves under a running process (a `cd` in a Bash tool
	///   call), and Claude re-announces it in a fresh init event on a later
	///   turn of that same process;
	/// - a process resumes a session somewhere other than where it was
	///   created, because the project directory moved or its CWD is respelled
	///   across sandbox changes.
	///
	/// The derived location is therefore a candidate, never an authority.
	private void registerLiveHistoryPath(string sessionId, string cwd,
		const ref NativeHistoryProfile profile)
	{
		import std.logger : tracef;
		import std.path : buildPath;
		enforce(cwd.length > 0,
			"Claude session initialization did not provide a CWD");
		auto derived = buildPath(profile.root, "projects", mangleProjectPath(cwd),
			sessionId ~ ".jsonl");
		auto chosen = preferExistingHistoryPath(derived,
			historyPath(sessionId, profile));
		if (chosen != derived)
			tracef("Claude session %s reported CWD %s; keeping its history at %s "
				~ "rather than the CWD-derived %s", sessionId, cwd, chosen, derived);
		registeredHistoryPaths_[profile.root][sessionId] = chosen;
	}

	/// Choose between a CWD-derived candidate and a location CyDo already
	/// knows. A file that exists beats one that does not; when both exist the
	/// newest wins, the same way the profile scan resolves a session ID that
	/// appears in two project directories. When neither exists the known path
	/// wins: it was learned first-hand (a fork destination, an imported
	/// locator, an earlier init of this same session), while the candidate is
	/// only a guess about where a file is about to appear.
	private static string preferExistingHistoryPath(string derived, string known)
	{
		import std.file : exists, timeLastModified;
		if (known.length == 0 || known == derived)
			return derived;
		auto derivedExists = exists(derived);
		if (derivedExists && exists(known))
			return timeLastModified(derived) >= timeLastModified(known)
				? derived : known;
		return derivedExists ? derived : known;
	}

	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile)
	{
		import std.path : buildPath, dirName, isAbsolute;
		enforce(sourceHistoryPath.length > 0 && isAbsolute(sourceHistoryPath),
			"Claude history forks require an absolute source history path");
		auto destination = buildPath(dirName(sourceHistoryPath),
			sessionId ~ ".jsonl");
		registerHistoryPath(sessionId, destination, profile);
		return destination;
	}

	// historyPath locates sessions by ID: the file may sit in a project
	// directory whose name CyDo cannot derive, because Claude mangles the
	// CLI's own observed CWD. The scan snapshot is taken once and misses
	// settle; paths learned afterwards arrive via registerHistoryPath.
	unittest
	{
		import std.algorithm : count, find;
		import std.datetime.systime : SysTime;
		import std.exception : assertThrown;
		import std.file : exists, mkdirRecurse, rmdirRecurse, setTimes, write;
		import std.path : buildPath;

		auto root = buildPath("/tmp", "cydo-claude-history-path-cache");
		if (exists(root))
			rmdirRecurse(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);
		auto logicalDir = buildPath(root, "projects", "-home-user-proj");
		auto sandboxDir = buildPath(root, "projects", "-mnt-scratch-home-user-proj");
		mkdirRecurse(logicalDir);
		mkdirRecurse(sandboxDir);
		enum idA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
		enum idB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
		enum idC = "cccccccc-cccc-cccc-cccc-cccccccccccc";
		enum idD = "dddddddd-dddd-dddd-dddd-dddddddddddd";
		auto pathA = buildPath(sandboxDir, idA ~ ".jsonl");
		write(pathA, "");
		auto dupOld = buildPath(logicalDir, idD ~ ".jsonl");
		auto dupNew = buildPath(sandboxDir, idD ~ ".jsonl");
		write(dupOld, "");
		write(dupNew, "");
		auto older = SysTime.fromUnixTime(1_000_000);
		auto newer = SysTime.fromUnixTime(2_000_000);
		setTimes(dupOld, older, older);
		setTimes(dupNew, newer, newer);

		auto agent = new ClaudeCodeAgent();
		auto profile = NativeHistoryProfile(AgentDriver.claude, root);

		auto sessions = agent.enumerateAllSessions(profile);
		assert(sessions.count!(session => session.sessionId == idD) == 1);
		auto duplicate = sessions.find!(session => session.sessionId == idD)[0];
		assert(duplicate.exactHistoryPath == dupNew);
		assert(duplicate.mtime == newer.stdTime);
		assert(sessions.count!(session => session.sessionId == idA
			&& session.exactHistoryPath == pathA) == 1);

		// 19. the session is found by ID in whichever project directory
		// holds it, and a duplicated ID resolves to the newest file
		assert(agent.historyPath(idA, profile) == pathA);
		assert(agent.historyPath(idD, profile) == dupNew);

		// 20. the snapshot is authoritative: a file written after the scan
		// stays unknown rather than triggering a rescan
		auto pathB = buildPath(logicalDir, idB ~ ".jsonl");
		write(pathB, "");
		assert(agent.historyPath(idB, profile) is null);

		// 21. registration resolves it without a rescan, and re-registering
		// must agree with the recorded location
		agent.registerHistoryPath(idB, pathB, profile);
		assert(agent.historyPath(idB, profile) == pathB);
		agent.registerHistoryPath(idB, pathB, profile);
		assertThrown(agent.registerHistoryPath(idB, pathA, profile));

		// 22. a fork destination lands beside its source and is registered
		auto destination = agent.createHistoryForkDestination(idC, pathA, profile);
		assert(destination == buildPath(sandboxDir, idC ~ ".jsonl"));
		assert(agent.historyPath(idC, profile) == destination);
	}

	// A live session's init CWD locates a new session's transcript, but not
	// an existing one's: Claude keeps appending to the file it already has
	// and leaves the CWD-derived project directory empty, whether the CWD
	// moved under the running process or the session resumed elsewhere.
	unittest
	{
		import std.datetime.systime : SysTime;
		import std.file : exists, mkdirRecurse, rmdirRecurse, setTimes, write;
		import std.path : buildPath;

		auto root = buildPath("/tmp", "cydo-claude-live-history-path");
		if (exists(root))
			rmdirRecurse(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);
		enum created = "/home/user/proj";
		enum resumed = "/home/user/proj-moved";
		auto createdDir = buildPath(root, "projects", "-home-user-proj");
		auto resumedDir = buildPath(root, "projects", "-home-user-proj-moved");
		mkdirRecurse(createdDir);
		mkdirRecurse(resumedDir);  // Claude materializes it, empty
		enum idA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
		enum idB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";

		auto agent = new ClaudeCodeAgent();
		auto profile = NativeHistoryProfile(AgentDriver.claude, root);
		auto createdPath = buildPath(createdDir, idA ~ ".jsonl");

		// 23. a session Claude is creating has no transcript yet, so the
		// CWD-derived location is all there is to go on
		agent.registerLiveHistoryPath(idA, created, profile);
		assert(agent.historyPath(idA, profile) == createdPath);

		// 24. a later init naming a different CWD — the session moved, or it
		// resumed elsewhere — keeps the transcript Claude is actually
		// writing, rather than the empty directory that CWD names
		write(createdPath, "");
		agent.registerLiveHistoryPath(idA, resumed, profile);
		assert(agent.historyPath(idA, profile) == createdPath);

		// 25. repeating that init is stable, and never throws the way a plain
		// re-registration of a conflicting path does
		agent.registerLiveHistoryPath(idA, resumed, profile);
		assert(agent.historyPath(idA, profile) == createdPath);

		// 26. when both locations hold a transcript the newest wins, matching
		// how the profile scan resolves a session ID in two directories
		auto stale = buildPath(createdDir, idB ~ ".jsonl");
		auto fresh = buildPath(resumedDir, idB ~ ".jsonl");
		write(stale, "");
		write(fresh, "");
		auto older = SysTime.fromUnixTime(1_000_000);
		auto newer = SysTime.fromUnixTime(2_000_000);
		setTimes(stale, older, older);
		setTimes(fresh, newer, newer);
		agent.registerHistoryPath(idB, stale, profile);
		agent.registerLiveHistoryPath(idB, resumed, profile);
		assert(agent.historyPath(idB, profile) == fresh);
	}

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		return translateClaudeHistoryEvent(line);
	}

	void resetHistoryReplay() {} // no state to reset for Claude

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// ClaudeCodeSession handles translation statefully inline.
		// This is an identity pass-through for pre-translated events.
		return [TranslatedEvent(rawLine, null)];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		// ClaudeCodeSession emits translated turn/result events.
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"user"`);
	}

	bool isAssistantMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"assistant"`);
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"sessionId":"` ~ oldId ~ `"`, `"sessionId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	bool[int] inactiveHistoryLines(string content)
	{
		import cydo.agent.drivers.claude_branches : claudeRewoundLines;
		return claudeRewoundLines(content);
	}

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content, int lineOffset = 0)
	{
		import std.algorithm : canFind;
		import std.format : format;
		import std.string : indexOf, lineSplitter;

		PersistedHistoryBoundary[] ids;
		int lineNum = lineOffset;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			if (line.canFind(`"queue-operation"`))
			{
				import ae.utils.json : jsonParse, JSONPartial;
				@JSONPartial static struct QueueOpProbe { string operation; }
				try
				{
					auto qop = jsonParse!QueueOpProbe(line);
					if (qop.operation == "enqueue")
						ids ~= PersistedHistoryBoundary(format!"enqueue-%d"(lineNum), PersistedHistoryBoundaryKind.provisional_user, null, lineNum);
				}
				catch (Exception e) { tracef("history scan: queue op parse error: %s", e.msg); }
				continue;
			}
			bool isUser = line.canFind(`"type":"user"`);
			if (!isUser && !line.canFind(`"type":"assistant"`))
				continue;
			if (isUser && !hasCanonicalUserContent(line))
				continue;
			enum prefix = `"uuid":"`;
			auto idx = line.indexOf(prefix);
			bool hasUuid;
			if (idx >= 0)
			{
				auto start = idx + prefix.length;
				auto end = line.indexOf('"', start);
				if (end >= 0 && end > idx + cast(ptrdiff_t) prefix.length)
				{
					auto uuid = line[start .. end];
					ids ~= PersistedHistoryBoundary(uuid,
						isUser ? PersistedHistoryBoundaryKind.user : PersistedHistoryBoundaryKind.agent_turn,
						null, lineNum);
					hasUuid = true;
				}
			}
			if (!hasUuid)
				ids ~= PersistedHistoryBoundary(format!"line:%d"(lineNum),
					isUser ? PersistedHistoryBoundaryKind.user : PersistedHistoryBoundaryKind.agent_turn,
					null, lineNum);
		}
		return ids;
	}

	private static bool hasCanonicalUserContent(string line)
	{
		@JSONPartial static struct UserMessage { JSONFragment content; }
		@JSONPartial static struct UserRecord { UserMessage message; }
		UserRecord record;
		try
			record = jsonParse!UserRecord(line);
		catch (Exception)
			return false;

		auto content = record.message.content.json;
		if (content is null || content.length == 0)
			return false;
		if (content[0] == '"')
			return true;
		if (content[0] != '[')
			return false;

		@JSONPartial static struct ContentItem { string type; }
		ContentItem[] items;
		try
			items = jsonParse!(ContentItem[])(content);
		catch (Exception)
			return false;
		foreach (item; items)
			if (item.type == "text" || item.type == "image")
				return true;
		return false;
	}

	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText)
	{
		return repairInterruptedToolCallImpl(lines, toolName, resultText);
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.algorithm : canFind, startsWith;
		// Handle synthetic enqueue UUID "enqueue-N" (line-number-based).
		// The undo anchor for a steering message is the queue-op-enqueue line;
		// truncating there (excludeMatch=true) removes it and all following lines.
		if (forkId.startsWith("enqueue-"))
		{
			import std.conv : to;
			try
			{
				auto targetLine = forkId["enqueue-".length .. $].to!int;
				if (lineNum != targetLine || !line.canFind(`"queue-operation"`))
					return false;
				// Parse operation field to avoid whitespace sensitivity.
				import ae.utils.json : jsonParse, JSONPartial;
				@JSONPartial static struct QueueOpProbe { string operation; }
				try { return jsonParse!QueueOpProbe(line).operation == "enqueue"; }
				catch (Exception e) { tracef("matchesForkId: queue op parse error: %s", e.msg); return false; }
			}
			catch (Exception e)
			{ tracef("matchesForkId: error: %s", e.msg); return false; }
		}
		if (forkId.startsWith("line:"))
		{
			import std.conv : to;
			return lineNum == forkId["line:".length .. $].to!int;
		}
		return line.canFind(`"uuid":"` ~ forkId ~ `"`);
	}

	bool isForkableLine(string line)
	{
		import std.algorithm : canFind;
		return line.canFind(`"type":"user"`) || line.canFind(`"type":"assistant"`);
	}

	@property bool needsBash() { return false; }
	@property bool supportsFileRevert() { return true; }
	@property bool supportsDeveloperPrompt() { return true; }

	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch)
	{
		import std.process : Config, execute;

		enforce(launch.nativeHistoryProfile.driver == driver,
			"Claude rewind launch does not carry a Claude history profile");
		enforce(launch.nativeHistoryProfile.root.length > 0,
			"Claude rewind launch does not carry a history profile root");

		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: resolveExecutablePath(executableName(null), null);
		if (claudeBin.length == 0)
			claudeBin = executableName(null);

		// Pass claudeBin as positional $3 to avoid needing it in env.
		// Use /bin/sh (absolute) so the shell is found even inside bwrap with --clearenv.
		string[] shArgs = [
			"/bin/sh", "-c",
			`exec 2>&1; exec "$3" --resume "$1" --rewind-files "$2" ` ~
				`--settings '{"fileCheckpointingEnabled": true}'`,
			"--", sessionId, afterUuid, claudeBin,
		];

		string[] args;
		string[string] procEnv;
		ResolvedSandbox freshSandbox;
		if (launch.cmdPrefix !is null)
		{
			// Regenerate a fresh command prefix with new temp files,
			// since the original ones were cleaned up after session exit.
			freshSandbox = launch.sandbox;
			args = buildCommandPrefix(freshSandbox, launch.workDir) ~ shArgs;
		}
		else
		{
			args = shArgs;
			procEnv = launch.sandbox.env.dup;
			procEnv["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1";
		}

		auto result = execute(args, procEnv, Config.none, size_t.max,
			launch.workDir.length > 0 ? launch.workDir : null);

		// Clean up temp files created by buildCommandPrefix above.
		if (freshSandbox.tempFiles.length > 0)
			cleanup(freshSandbox);

		if (result.status != 0)
		{
			auto msg = result.output.length > 0 ? result.output
				: "Process exited with status " ~ format!"%d"(result.status);
			return RewindResult(false, msg);
		}

		import std.algorithm : canFind;
		if (result.output.canFind("Error:"))
			return RewindResult(false, result.output);

		return RewindResult(true, result.output);
	}

	private static string[] buildOneShotArgs(string claudeBin, string prompt,
		string model, string effort, ProcessLaunch launch)
	{
		string[] args = [
			claudeBin,
			"-p", prompt,
			"--output-format", "text",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		];
		// an empty alias means no explicit model; omit the flag so claude
		// uses its own configured default
		if (model.length > 0)
			args ~= ["--model", model];
		// an empty effort means no explicit effort; omit the flag so claude
		// uses its own configured default
		if (effort.length > 0)
			args ~= ["--effort", effort];
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ args;
		return args;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		ProcessLaunch launch; // .init: no cmdPrefix

		// an empty alias omits --model entirely
		assert(!buildOneShotArgs("claude", "hi", "", "", launch).canFind("--model"));

		// a resolved model is passed through as `--model <x>`
		auto withModel = buildOneShotArgs("claude", "hi", "opus", "", launch);
		auto i = withModel.countUntil("--model");
		assert(i >= 0 && withModel[i + 1] == "opus");

		// an empty effort omits --effort entirely
		assert(!buildOneShotArgs("claude", "hi", "opus", "", launch).canFind("--effort"));

		// a resolved effort is passed through as `--effort <x>`
		auto withEffort = buildOneShotArgs("claude", "hi", "opus", "xhigh", launch);
		auto j = withEffort.countUntil("--effort");
		assert(j >= 0 && withEffort[j + 1] == "xhigh");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		import std.path : buildPath;
		import std.process : environment;
		import std.string : strip;
		import ae.utils.promise : Promise;

		auto promise = new Promise!string;
		auto claudeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);

		string[string] env = [
			"PATH": environment.get("PATH", ""),
			"HOME": environment.get("HOME", ""),
		];

		auto spec = resolveModelSpec(modelClass);
		auto args = buildOneShotArgs(claudeBin, prompt, spec.model, spec.effort, launch);

		auto procEnv = launch.cmdPrefix is null ? env : null;

		AgentProcess proc;
		try
			proc = new AgentProcess(args, procEnv, noStdin: true,
				mode: FramingMode.raw, logName: "claude-oneshot");
		catch (Exception e)
		{
			errorf("completeOneShot: failed to spawn claude: %s", e.msg);
			promise.reject(new Exception("failed to spawn claude: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		string responseText;
		string stderrText;

		proc.onStdoutLine = (string chunk) {
			responseText ~= chunk;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			tracef("claude oneshot exit: status=%d stdout=%d bytes stderr=%d bytes",
				status, responseText.length, stderrText.length);
			if (status != 0)
			{
				auto msg = "claude exited with status " ~ status.to!string;
				auto details = stderrText.strip();
				if (details.length > 0)
					msg ~= ": " ~ details;
				promise.reject(new Exception(msg));
			}
			else
			{
				if (stderrText.length > 0)
					warningf("claude oneshot stderr: %s", stderrText.strip());
				promise.fulfill(responseText.strip());
			}
		};

		void cancel() { proc.killAfterTimeout(0.seconds); }

		return OneShotHandle(promise, &cancel);
	}
}

private bool interruptedToolCallHasKey(ref JSONValue value, string key)
{
	return value.type == JSONType.object && key in value.object;
}

private string interruptedToolCallStringAt(ref JSONValue value, string key)
{
	if (!interruptedToolCallHasKey(value, key))
		return null;
	auto field = value.object[key];
	return field.type == JSONType.string ? field.str : null;
}

/// Repair the Claude JSONL records emitted after CyDo interrupts a successful
/// continuation MCP call. Returns null when the expected call/result pair is
/// not present, leaving the caller's file untouched.
InterruptedToolCallRepair repairInterruptedToolCallImpl(string[] lines, string toolName,
	string resultText)
{
	string toolUseId;
	foreach (line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
			continue;
		if (interruptedToolCallStringAt(record, "type") != "assistant"
			|| !interruptedToolCallHasKey(record, "message"))
			continue;

		auto message = record.object["message"];
		if (!interruptedToolCallHasKey(message, "content")
			|| message.object["content"].type != JSONType.array)
			continue;
		foreach (block_; message.object["content"].array)
		{
			auto block = block_;
			if (interruptedToolCallStringAt(block, "type") == "tool_use"
				&& interruptedToolCallStringAt(block, "name") == toolName)
				toolUseId = interruptedToolCallStringAt(block, "id");
		}
	}
	if (toolUseId.length == 0)
		return null;

	string resultUuid;
	string resultPromptId;
	bool rewroteResult;
	string[] rewritten;
	foreach (line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			rewritten ~= line;
			continue;
		}

		if (!rewroteResult && interruptedToolCallStringAt(record, "type") == "user"
			&& interruptedToolCallHasKey(record, "message"))
		{
			auto message = record.object["message"];
			if (interruptedToolCallHasKey(message, "content")
				&& message.object["content"].type == JSONType.array
				&& message.object["content"].array.length > 0)
			{
				auto content = message.object["content"];
				auto block = content.array[0];
				if (interruptedToolCallStringAt(block, "type") == "tool_result"
					&& interruptedToolCallStringAt(block, "tool_use_id") == toolUseId)
				{
					block.object["content"] = JSONValue(resultText);
					block.object.remove("is_error");
					content.array[0] = block;
					message.object["content"] = content;
					record.object["message"] = message;
					record.object["toolUseResult"] = JSONValue(resultText);
					record.object.remove("toolDenialKind");
					resultUuid = interruptedToolCallStringAt(record, "uuid");
					resultPromptId = interruptedToolCallStringAt(record, "promptId");
					rewritten ~= record.toString();
					rewroteResult = true;
					continue;
				}
			}
		}
		rewritten ~= line;
	}
	if (!rewroteResult || resultUuid.length == 0)
		return null;

	string interruptionUuid;
	string interruptionParentUuid;
	string[] withoutInterruption;
	foreach (line; rewritten)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			withoutInterruption ~= line;
			continue;
		}

		if (interruptionUuid.length == 0
			&& interruptedToolCallStringAt(record, "type") == "user"
			&& (interruptedToolCallStringAt(record, "parentUuid") == resultUuid
				|| (resultPromptId.length > 0
					&& interruptedToolCallStringAt(record, "promptId") == resultPromptId))
			&& interruptedToolCallHasKey(record, "message"))
		{
			auto markerUuid = interruptedToolCallStringAt(record, "uuid");
			auto markerParentUuid = interruptedToolCallStringAt(record, "parentUuid");
			if (markerUuid.length == 0 || markerParentUuid.length == 0)
			{
				withoutInterruption ~= line;
				continue;
			}
			auto message = record.object["message"];
			if (interruptedToolCallHasKey(message, "content")
				&& message.object["content"].type == JSONType.array
				&& message.object["content"].array.length == 1)
			{
				auto block = message.object["content"].array[0];
				auto text = interruptedToolCallStringAt(block, "text");
				if (interruptedToolCallStringAt(block, "type") == "text"
					&& (text == "[Request interrupted by user for tool use]"
						|| text == "[Request interrupted by user]"))
				{
					interruptionUuid = markerUuid;
					interruptionParentUuid = markerParentUuid;
					continue;
				}
			}
		}
		withoutInterruption ~= line;
	}
	if (interruptionUuid.length == 0)
		return new InterruptedToolCallRepair(withoutInterruption);
	assert(interruptionParentUuid.length > 0);

	string[] repaired;
	foreach (line; withoutInterruption)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			repaired ~= line;
			continue;
		}

		bool changed;
		foreach (key; ["leafUuid", "parentUuid"])
			if (interruptedToolCallStringAt(record, key) == interruptionUuid)
			{
				record.object[key] = JSONValue(interruptionParentUuid);
				changed = true;
			}
		repaired ~= changed ? record.toString() : line;
	}
	return new InterruptedToolCallRepair(repaired, interruptionUuid);
}

unittest
{
	auto assistant = `{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_switch","name":"mcp__cydo__SwitchMode","input":{"continuation":"plan"}}]}}`;
	auto rejected = `{"type":"user","uuid":"u1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use.","is_error":true,"tool_use_id":"toolu_switch"}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}`;
	auto interruption = `{"type":"user","uuid":"u2","parentUuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto lastPrompt = `{"type":"last-prompt","leafUuid":"u2","sessionId":"session"}`;

	auto repaired = repairInterruptedToolCallImpl(
		[assistant, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(repaired !is null && repaired.lines.length == 3);
	assert(repaired.removedInterruptionUuid == "u2");
	auto result = parseJSON(repaired.lines[1]);
	auto resultBlock = result["message"]["content"][0];
	assert(resultBlock["content"].str == "RESULT");
	assert("is_error" !in resultBlock.object);
	assert(result["toolUseResult"].str == "RESULT");
	assert("toolDenialKind" !in result.object);
	assert(parseJSON(repaired.lines[2])["leafUuid"].str == "u1");

	auto older = repairInterruptedToolCallImpl([
		assistant, rejected,
		`{"type":"user","uuid":"u2","parentUuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
		lastPrompt,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(older !is null && older.lines.length == 3);
	assert(older.removedInterruptionUuid == "u2");
	assert(parseJSON(older.lines[2])["leafUuid"].str == "u1");

	// Claude 2.1.272 may put an attachment between the rewritten result and
	// its native interruption marker. promptId links the two records; removing
	// the marker must retain that attachment as the parent of subsequent rows.
	auto attachment = `{"type":"attachment","uuid":"at1","parentUuid":"u1","promptId":"p1"}`;
	auto attachedInterruption = `{"type":"user","uuid":"u3","parentUuid":"at1","promptId":"p1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto attachedChild = `{"type":"assistant","uuid":"a2","parentUuid":"u3","promptId":"p1","message":{"content":[]}}`;
	auto attachedLastPrompt = `{"type":"last-prompt","leafUuid":"u3","sessionId":"session"}`;
	auto promptLinked = repairInterruptedToolCallImpl([
		assistant,
		`{"type":"user","uuid":"u1","parentUuid":"a1","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"toolu_switch"}]}}`,
		attachment, attachedInterruption, attachedChild, attachedLastPrompt,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(promptLinked !is null && promptLinked.lines.length == 5);
	assert(promptLinked.removedInterruptionUuid == "u3");
	assert(parseJSON(promptLinked.lines[2])["uuid"].str == "at1");
	assert(parseJSON(promptLinked.lines[3])["parentUuid"].str == "at1");
	assert(parseJSON(promptLinked.lines[4])["leafUuid"].str == "at1");

	// Exact native marker text alone is not enough: a different transaction's
	// interruption must survive when it is neither a result child nor prompt-linked.
	auto unrelatedInterruption = `{"type":"user","uuid":"other-u","parentUuid":"other-parent","promptId":"other-prompt","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto unrelatedMarker = repairInterruptedToolCallImpl([
		assistant,
		`{"type":"user","uuid":"u1","parentUuid":"a1","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"toolu_switch"}]}}`,
		unrelatedInterruption,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(unrelatedMarker !is null && unrelatedMarker.lines.length == 3);
	assert(unrelatedMarker.removedInterruptionUuid.length == 0);
	assert(unrelatedMarker.lines[2] == unrelatedInterruption);

	// Missing prompt IDs cannot link an indirect marker to the repaired result.
	auto missingPromptMarker = `{"type":"user","uuid":"u3","parentUuid":"at1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto missingPromptIds = repairInterruptedToolCallImpl([
		assistant, rejected,
		`{"type":"attachment","uuid":"at1","parentUuid":"u1"}`,
		missingPromptMarker,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(missingPromptIds !is null && missingPromptIds.lines.length == 4);
	assert(missingPromptIds.removedInterruptionUuid.length == 0);
	assert(missingPromptIds.lines[3] == missingPromptMarker);

	// A prompt-linked native marker without a usable linkage cannot be removed
	// because descendants have no valid parent to target.
	auto missingParentMarker = `{"type":"user","uuid":"u3","promptId":"p1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto missingParent = repairInterruptedToolCallImpl([
		assistant,
		`{"type":"user","uuid":"u1","parentUuid":"a1","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"toolu_switch"}]}}`,
		missingParentMarker,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(missingParent !is null && missingParent.lines.length == 3);
	assert(missingParent.removedInterruptionUuid.length == 0);
	assert(missingParent.lines[2] == missingParentMarker);

	// A marker UUID is likewise required before an indirect marker can be
	// selected and subsequently relinked.
	auto missingUuidMarker = `{"type":"user","parentUuid":"at1","promptId":"p1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}`;
	auto missingUuid = repairInterruptedToolCallImpl([
		assistant,
		`{"type":"user","uuid":"u1","parentUuid":"a1","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"toolu_switch"}]}}`,
		missingUuidMarker,
	], "mcp__cydo__SwitchMode", "RESULT");
	assert(missingUuid !is null && missingUuid.lines.length == 3);
	assert(missingUuid.removedInterruptionUuid.length == 0);
	assert(missingUuid.lines[2] == missingUuidMarker);

	auto noInterruption = repairInterruptedToolCallImpl([assistant, rejected],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(noInterruption !is null && noInterruption.lines.length == 2);
	assert(noInterruption.removedInterruptionUuid.length == 0);
	assert(parseJSON(noInterruption.lines[1])["toolUseResult"].str == "RESULT");

	auto oldAssistant = `{"type":"assistant","uuid":"old-a","message":{"content":[{"type":"tool_use","id":"old-call","name":"mcp__cydo__SwitchMode","input":{}}]}}`;
	auto oldResult = `{"type":"user","uuid":"old-u","message":{"content":[{"type":"tool_result","content":"OLD","tool_use_id":"old-call"}]}}`;
	auto multiple = repairInterruptedToolCallImpl(
		[oldAssistant, oldResult, assistant, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(multiple !is null && multiple.lines[1] == oldResult);

	auto mixedAssistant = `{"type":"assistant","uuid":"mixed-a","message":{"content":[{"type":"tool_use","id":"bash-call","name":"Bash","input":{}},{"type":"tool_use","id":"toolu_switch","name":"mcp__cydo__SwitchMode","input":{}}]}}`;
	auto bashResult = `{"type":"user","uuid":"bash-u","message":{"content":[{"type":"tool_result","content":"BASH","tool_use_id":"bash-call"}]}}`;
	auto unrelated = repairInterruptedToolCallImpl(
		[mixedAssistant, bashResult, rejected, interruption, lastPrompt],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(unrelated !is null && unrelated.lines[1] == bashResult);

	auto handoffAssistant = `{"type":"assistant","uuid":"h-a","message":{"content":[{"type":"tool_use","id":"handoff-call","name":"mcp__cydo__Handoff","input":{}}]}}`;
	auto handoffResult = `{"type":"user","uuid":"h-u","message":{"content":[{"type":"tool_result","content":"rejected","is_error":true,"tool_use_id":"handoff-call"}]},"toolDenialKind":"user-rejected"}`;
	auto handoff = repairInterruptedToolCallImpl([handoffAssistant, handoffResult],
		"mcp__cydo__Handoff", "HANDOFF RESULT");
	assert(handoff !is null
		&& parseJSON(handoff.lines[1])["toolUseResult"].str == "HANDOFF RESULT");
	assert(handoff.removedInterruptionUuid.length == 0);
	auto malformed = repairInterruptedToolCallImpl([assistant, rejected, "not json"],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(malformed !is null && malformed.removedInterruptionUuid.length == 0);
	assert(repairInterruptedToolCallImpl([assistant, rejected],
		"mcp__cydo__Handoff", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([`{"type":"user"}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([assistant],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-claude-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH"];
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
	auto profileRoot = buildPath(root, "configured-claude-profile");
	auto executableDir = buildPath(root, "bin");
	auto executable = buildPath(executableDir, "claude");
	mkdirRecurse(home);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["PATH"] = executableDir;

	auto agent = new ClaudeCodeAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_CLAUDE_BIN": executable,
		"PATH": executableDir,
		"CLAUDE_CONFIG_DIR": profileRoot,
	];
	auto executableMounts = executableMountPaths(resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "claude";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Native-history paths belong to the launch phase. configureSandbox only
	// keeps a configured profile selector in the child environment.
	assert(resolved.paths.exact(profileRoot).isNull);
	assert(resolved.paths.exact(buildPath(home, ".claude")).isNull);
	assert(resolved.paths.exact(buildPath(home, ".claude.json")).isNull);
	assert(resolved.paths.exact(buildPath(home, ".local", "share", "claude")).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.claude);
	assert(nativeRule.profileEnvName == "CLAUDE_CONFIG_DIR");
	assert(nativeRule.homeRelativeDefault == ".claude");
	assert(nativeRule.homeSupportRequirements.length == 2);
	assert(nativeRule.homeSupportRequirements[0].homeRelativePath == ".claude.json");
	assert(nativeRule.homeSupportRequirements[0].access == PathAccess.rw);
	assert(nativeRule.homeSupportRequirements[1].homeRelativePath
		== ".local/share/claude");
	assert(nativeRule.homeSupportRequirements[1].access == PathAccess.ro);
	assert(resolved.env["PATH"] == executableDir);
	assert(resolved.env["CLAUDE_CONFIG_DIR"] == profileRoot);
	assert(resolved.env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1");
	assert(resolved.env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] == "0");
	assert(resolved.env["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false");

	// With no configured PATH, Claude keeps its existing host-PATH defaulting.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_CLAUDE_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(("CLAUDE_CONFIG_DIR" in defaultEnv) is null);
	assert(defaultPaths.exact(buildPath(home, ".claude")).isNull);
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"claude test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	string[string] ancestorEnv = [
		"CYDO_CLAUDE_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
}

/// A tool call the CLI asks the host to allow or deny (`can_use_tool`).
struct ToolPermissionRequest
{
	string toolUseId;
	string toolName;
	JSONFragment input;
}

/// Claude Code session using stream-json protocol.
class ClaudeCodeSession : AgentSession
{
	private AgentProcess process;
	private string nativeSessionId_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private void delegate(string sessionId, string cwd) historyPathRegistrar_;
	private void delegate(TranslatedEvent) outputHandler;
	private void delegate(string line) stderrHandler;
	private void delegate(int status) exitHandler;
	private Promise!string delegate(PermissionPrompt, PermissionEscalation) permissionRequestHandler_;
	private ToolCallRuling delegate(ToolPermissionRequest) preToolUseHandler_;
	private void delegate(string toolUseId) permissionRequestWithdrawnHandler_;
	/// can_use_tool requests the CLI still awaits an answer to: request_id → tool_use_id.
	private string[string] pendingPermissionRequests_;
	/// Permission requests (can_use_tool and policy hook_callback) we have
	/// answered and the CLI has yet to take the answer to:
	/// request_id → tool_use_id. The CLI echoes each answer it takes (we
	/// run it with --replay-user-messages).
	private string[string] answeredPermissionRequests_;
	/// User messages (by the UUID we sent them with) the CLI has started
	/// processing and not yet finished, per its `command_lifecycle` reports.
	/// A message replayed while another is in progress was absorbed into
	/// that turn as steering.
	private bool[string] startedCommands_;
	/// User messages the CLI has queued and not yet started or withdrawn.
	private bool[string] queuedCommands_;
	/// Control requests we sent and await the CLI's answer to, by request_id.
	private Promise!JSONFragment[string] pendingControlRequests_;
	/// Whether this CLI version supports in-process `rewind_conversation`.
	/// Unknown until the version is known and, for an unseen version, the
	/// capability probe answered.
	private Nullable!bool rewindSupported_;
	private Promise!bool rewindProbe_;
	private void delegate() rewindAvailabilityChangedHandler_;
	/// Probe outcomes by CLI version, shared by all sessions of this process.
	private static bool[string] rewindSupportByVersion_;

	// Stateful translation: track active content blocks per index.
	private string[] activeItemIds_;   // index → item_id for current turn
	private string[] activeItemTypes_; // index → "text", "thinking", "tool_use"
	/// What an assistant frame says about a streamed block, held until the
	/// block's content_block_stop (the frame arrives just before it).
	private static struct BlockCompletion
	{
		JSONFragment extras;
		bool isNarration;
	}
	private BlockCompletion[string] blockCompletions_; // item_id → from assistant event
	private AbsTime lineReceiptTs_;    // receipt time captured at start of each live line
	/// The background tasks (commands, monitors, agents) the CLI reports as
	/// live, per its latest `background_tasks_changed`.
	private BackgroundWork[] liveBackgroundTasks_;
	private string executablePath_;
	private string agentName_;

	private static string[] buildSessionArgs(string executablePath, string resumeSessionId,
		string[] cmdPrefix, string mcpConfigPath, SessionConfig config)
	{
		string[] claudeArgs = [
			executablePath.length > 0 ? executablePath : "claude",
			"-p",
			"--input-format", "stream-json",
			"--output-format", "stream-json",
			"--verbose",
			"--include-partial-messages",
			"--replay-user-messages",
			// Opt back into thinking content on Opus 4.7 (omitted by default since 4.7).
			"--thinking-display", "summarized",
			"--settings", `{"fileCheckpointingEnabled": true}`,
		];

		// The permission policy rules on every tool call first, through a
		// PreToolUse hook (registerPreToolUseHook). Outside auto mode the hook
		// always answers, so the default mode runs what the policy allows;
		// auto mode has its classifier judge what the policy leaves to it.
		// `stdio` makes the CLI ask over the control channel (can_use_tool
		// control requests, answered by onToolPermissionRequest) about what
		// remains: the policy's "ask", the classifier's referrals, and calls
		// its own safety checks flag, which a hook "allow" does not override.
		// (Not bypass mode: there, a hook "ask" on a call a safety check also
		// flags, e.g. a write into .claude/, is dropped and the call runs.)
		if (config.permissions.autoMode)
			claudeArgs ~= ["--permission-mode", "auto"];
		claudeArgs ~= ["--permission-prompt-tool", "stdio"];

		// The task writes its notes and output to its task directory, which
		// may be reached through a symlink (`.cydo/tasks` on another volume).
		// The CLI has a person confirm any write whose target, as spelled or
		// fully resolved, lies outside its working directories, and a hook
		// "allow" does not override that. It counts each working directory
		// both as given and resolved, but drops an --add-dir that, as spelled,
		// already lies inside one. So pass both spellings: the resolved one
		// covers the task directory when the cwd is the project, the given
		// one when the cwd is a worktree inside the task directory.
		if (config.taskDir.length > 0)
			claudeArgs ~= ["--add-dir", config.taskDir,
				"--add-dir", config.taskDir.realPath];

		if (mcpConfigPath !is null)
			claudeArgs ~= ["--mcp-config", mcpConfigPath];

		if (resumeSessionId !is null)
			claudeArgs ~= ["--resume", resumeSessionId];

		if (config.model.length > 0)
			claudeArgs ~= ["--model", config.model];

		// Passed through verbatim; `claude` owns the accepted value set.
		if (config.effort.length > 0)
			claudeArgs ~= ["--effort", config.effort];

		if (config.appendSystemPrompt.length > 0)
			claudeArgs ~= [
				"--append-system-prompt", config.appendSystemPrompt,
				"--system-prompt-snapshot", "off",
			];

		import std.array : join;

		auto disallowed = disallowedTools(config.allowNativeSubagents,
			config.allowScheduledWakeups);
		claudeArgs ~= ["--disallowedTools", disallowed.join(",")];

		// When sandboxed, cmdPrefix handles workDir via --chdir (bwrap) or -C (env)
		string[] args;
		if (cmdPrefix !is null)
			args = cmdPrefix ~ claudeArgs;
		else
			args = claudeArgs;

		return args;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		SessionConfig config; // .init: no model, no effort, no cmdPrefix
		auto args = buildSessionArgs("claude", null, null, null, config);
		assert(!args.canFind("--model"));
		assert(!args.canFind("--effort"));

		auto withBoth = config;
		withBoth.model = "opus";
		withBoth.effort = "xhigh";
		auto bothArgs = buildSessionArgs("claude", null, null, null, withBoth);
		auto modelIdx = bothArgs.countUntil("--model");
		assert(modelIdx >= 0 && bothArgs[modelIdx + 1] == "opus");
		auto effortIdx = bothArgs.countUntil("--effort");
		assert(effortIdx >= 0 && bothArgs[effortIdx + 1] == "xhigh");

		// pinning the Step 1 extraction's ordering: cmdPrefix comes first
		auto withPrefix = buildSessionArgs("claude", null, ["prefix"], null, config);
		assert(withPrefix[0] == "prefix");
	}

	unittest
	{
		import std.algorithm : canFind;
		import std.file : mkdirRecurse, rmdirRecurse, symlink, tempDir;
		import std.path : buildPath;

		auto root = buildPath(tempDir, "cydo-claude-task-dir-args");
		scope (exit) rmdirRecurse(root);
		auto physical = buildPath(root, "volume", "tasks");
		mkdirRecurse(buildPath(physical, "7"));
		mkdirRecurse(buildPath(root, "project", ".cydo"));
		symlink(physical, buildPath(root, "project", ".cydo", "tasks"));

		SessionConfig config;
		config.taskDir = buildPath(root, "project", ".cydo", "tasks", "7");
		auto args = buildSessionArgs("claude", null, null, null, config);
		assert(args.canFind(["--add-dir", config.taskDir]));
		assert(args.canFind(["--add-dir", buildPath(physical, "7")]));

		assert(!buildSessionArgs("claude", null, null, null, SessionConfig.init)
			.canFind("--add-dir"));
	}

	this(string executablePath, string resumeSessionId = null, string[] cmdPrefix = null,
		string mcpConfigPath = null, SessionConfig config = SessionConfig.init,
		void delegate(string sessionId, string cwd) historyPathRegistrar = null)
	{
		executablePath_ = executablePath;
		agentName_ = config.agentName;
		historyPathRegistrar_ = historyPathRegistrar;

		auto args = buildSessionArgs(executablePath, resumeSessionId, cmdPrefix,
			mcpConfigPath, config);
		process = new AgentProcess(args, logName: "claude");

		process.onStdoutLine = (string line) {
			translateLiveLine(line);
		};

		process.onStderrLine = (string line) {
			if (stderrHandler)
				stderrHandler(line);
		};

		process.onExit = (int status) {
			pendingPermissionRequests_ = null;
			startedCommands_ = null;
			queuedCommands_ = null;
			auto unanswered = pendingControlRequests_;
			pendingControlRequests_ = null;
			foreach (_, promise; unanswered)
				promise.reject(new Exception("Claude exited before answering"));
			if (exitHandler)
				exitHandler(status);
		};

		process.onLineHandlerError = (string source, Exception e) {
			reportLineHandlerError(source, e);
		};

		registerPreToolUseHook();
	}

	/// Have the CLI consult the permission policy (onPreToolUse) before each
	/// tool call, ahead of its own checks and its auto mode classifier. A
	/// hook is the only decision point that precedes them.
	private void registerPreToolUseHook()
	{
		static struct Matcher
		{
			string[] hookCallbackIds;
			// A failed answer blocks the call rather than letting it run.
			string onFailure;
		}
		static struct Hooks { Matcher[] PreToolUse; }
		static struct Request { string subtype; Hooks hooks; }
		sendControlRequest(Request("initialize",
			Hooks([Matcher([preToolUseCallbackId], "block")])))
			.then((JSONFragment) {}, (Exception e) {
				reportLineHandlerError("initialize response", new Exception(
					"Claude did not register the permission policy hook: " ~ e.msg));
			}).ignoreResult();
	}

	private enum preToolUseCallbackId = "cydo-permission-policy";

	/// Surface a contained line-handler fault on the task it belongs to.
	/// The session keeps running: the agent process is unaffected by CyDo
	/// failing to translate one of its lines, and the rest of the turn is
	/// still worth showing.
	private void reportLineHandlerError(string source, Exception e)
	{
		import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;

		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.error;
		ev.subject = "CyDo error";
		ev.body = "Failed to process agent " ~ source ~ ": " ~ e.msg;
		emitEvent(TranslatedEvent(toJson(ev), null));
	}

	/// Send a user message formatted as Claude stream-json input.
	/// correlationId is accepted for interface compatibility but not used:
	/// Claude has no separable app-server acknowledgment beyond local enqueue.
	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false, string nativeSubmissionUuid = null,
		MessageSource source = MessageSource.harness)
	{
		try
		{
			process.sendMessage(serializeClaudeInput(content, nativeSubmissionUuid, source));
		}
		catch (Exception e)
			return reject!AgentSubmissionReceipt(e);
		return resolve(AgentSubmissionReceipt.localEnqueued);
	}

	private static string serializeClaudeInput(const(ContentBlock)[] content,
		string nativeSubmissionUuid, MessageSource source)
	{
		import std.uuid : UUID, randomUUID;
		JSONFragment claudeContent;
		if (content.length == 1 && content[0].type == "text")
			claudeContent = JSONFragment(toJson(content[0].text));
		else
			claudeContent = buildClaudeContentBlocks(content);
		auto inputUuid = nativeSubmissionUuid.length > 0
			? nativeSubmissionUuid : randomUUID().toString();
		if (nativeSubmissionUuid.length > 0)
			enforce(!UUID(nativeSubmissionUuid).empty,
				"Claude submission UUID must not be nil");
		// The CLI treats a message without an origin as unattributed; one
		// stamped "human" counts as the person's (and is recorded so in the
		// session file).
		ClaudeInputOrigin origin;
		final switch (source)
		{
			case MessageSource.harness:
				break;
			case MessageSource.user:
				origin.kind = "human";
				break;
		}
		return toJson(ClaudeInput("user", inputUuid,
			ClaudeInputMessage("user", claudeContent), "default", null, origin));
	}

	unittest
	{
		import std.algorithm : canFind;

		enum uuid = "6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b";
		auto typed = serializeClaudeInput([ContentBlock("text", "hi")], uuid, MessageSource.user);
		assert(typed.canFind(`"origin":{"kind":"human"}`), typed);
		auto harness = serializeClaudeInput([ContentBlock("text", "hi")], uuid, MessageSource.harness);
		assert(!harness.canFind(`"origin"`), harness);
	}

	void invalidatePendingSubmittedMessages() {}

	@property bool supportsImages() const { return true; }

	/// Send a protocol-level interrupt via stdin (control_request with subtype "interrupt").
	/// This tells Claude Code to cancel the current turn gracefully without killing the process.
	void interrupt()
	{
		import std.uuid : randomUUID;
		ClaudeControlRequest req;
		req.request_id = randomUUID().toString();
		req.request.subtype = "interrupt";
		process.sendMessage(toJson(req));
	}

	void sigint()
	{
		process.interrupt();
	}

	void stop()
	{
		process.terminate();
	}

	void closeStdin()
	{
		process.closeStdin();
	}

	void killAfterTimeout(Duration timeout)
	{
		process.killAfterTimeout(timeout);
	}

	@property bool canStopAfterCloseStdin() const
	{
		return true;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionId_ !is null && nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(nativeSessionId_);
	}

	private void notifyNativeSessionStarted(string sessionId)
	{
		enforce(sessionId.length > 0,
			"Claude session initialization did not provide a native session ID");
		if (nativeSessionId_ !is null)
		{
			enforce(nativeSessionId_ == sessionId,
				"Claude session reported conflicting native session IDs");
			return;
		}
		nativeSessionId_ = sessionId;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(sessionId);
	}

	@property void onOutput(void delegate(TranslatedEvent) dg)
	{
		outputHandler = dg;
	}

	@property void onStderr(void delegate(string line) dg)
	{
		stderrHandler = dg;
	}

	@property void onExit(void delegate(int status) dg)
	{
		exitHandler = dg;
	}

	/// Callback: the CLI asks whether a tool call may run, after the
	/// policy's ruling (onPreToolUse) left it open. Fulfil with the decision
	/// payload: `{"behavior":"allow","updatedInput":{…}}` or
	/// `{"behavior":"deny","message":"…"}`.
	@property void onToolPermissionRequest(
		Promise!string delegate(PermissionPrompt, PermissionEscalation) dg)
	{
		permissionRequestHandler_ = dg;
	}

	/// Callback: the CLI no longer awaits the decision for this tool call
	/// (e.g. the turn was interrupted while the prompt was pending).
	@property void onToolPermissionRequestWithdrawn(void delegate(string toolUseId) dg)
	{
		permissionRequestWithdrawnHandler_ = dg;
	}

	/// Callback: rule on a tool call before the CLI's own permission checks
	/// (and its auto mode classifier) run.
	@property void onPreToolUse(ToolCallRuling delegate(ToolPermissionRequest) dg)
	{
		preToolUseHandler_ = dg;
	}

	@property bool alive()
	{
		return !process.dead;
	}

	@property const(BackgroundWork)[] backgroundWork()
	{
		return liveBackgroundTasks_;
	}

	/// A `control_request` the CLI sent to us. CyDo registers for nothing but
	/// permission prompts and the permission policy hook, so any other
	/// subtype is refused.
	private void handleCliControlRequest(string rawLine)
	{
		@JSONPartial static struct Request
		{
			string subtype;
			@JSONOptional string tool_name;
			@JSONOptional string tool_use_id;
			@JSONOptional JSONFragment input;
			@JSONOptional string callback_id;
			@JSONOptional string decision_reason_type;
			@JSONOptional string decision_reason;
		}
		@JSONPartial static struct Envelope { string request_id; Request request; }
		auto envelope = jsonParse!Envelope(rawLine);
		enforce(envelope.request_id.length > 0,
			"Claude control request carries no request_id");

		if (envelope.request.subtype == "hook_callback")
		{
			enforce(envelope.request.callback_id == preToolUseCallbackId,
				"Claude invoked an unknown hook callback: " ~ envelope.request.callback_id);
			auto input = parsePreToolUseHookInput(envelope.request.input);
			answerPermissionRequest(envelope.request_id, input.tool_use_id,
				answerPreToolUseHook(input));
			return;
		}

		if (envelope.request.subtype != "can_use_tool")
		{
			import cydo.protocol : makeUnrecognizedEvent;
			emitEvent(TranslatedEvent(makeUnrecognizedEvent(
				"control_request subtype: " ~ envelope.request.subtype), rawLine));
			sendControlResponse(ClaudeControlResponse.error(envelope.request_id,
				"Unsupported control request subtype: " ~ envelope.request.subtype));
			return;
		}

		enforce(envelope.request.tool_use_id.length > 0,
			"Claude can_use_tool request carries no tool_use_id");
		assert(permissionRequestHandler_ !is null,
			"Claude asked for a tool permission, but no permission handler is attached");
		auto requestId = envelope.request_id;
		assert(requestId !in pendingPermissionRequests_,
			"Claude repeated a pending can_use_tool request_id");
		pendingPermissionRequests_[requestId] = envelope.request.tool_use_id;
		emitPermissionStage(envelope.request.tool_use_id, ItemPermissionStage.asked);
		// With the policy hook answering first, the CLI is left three reasons
		// to ask: the hook said "ask", the classifier defers to a person, or
		// one of its own safety checks (dangerous removals, sensitive files,
		// …) flags the call.
		PermissionEscalation escalation;
		switch (envelope.request.decision_reason_type)
		{
			case "hook":       escalation = PermissionEscalation.policyAsk; break;
			case "classifier": escalation = PermissionEscalation.classifier; break;
			default:           escalation = PermissionEscalation.safetyCheck; break;
		}
		auto prompt = PermissionPrompt(envelope.request.tool_use_id,
			envelope.request.tool_name, envelope.request.input,
			escalation == PermissionEscalation.policyAsk ? null : envelope.request.decision_reason);
		permissionRequestHandler_(prompt, escalation).then((string decision) {
			// Withdrawn or process exited while the decision was pending.
			auto toolUseId = requestId in pendingPermissionRequests_;
			if (toolUseId is null)
				return;
			auto answeredToolUseId = *toolUseId;
			pendingPermissionRequests_.remove(requestId);
			answerPermissionRequest(requestId, answeredToolUseId, decision);
		}).ignoreResult();
	}

	/// Send our answer to a permission request about `toolUseId`, and await
	/// the CLI's echo of it (settleControlResponse).
	private void answerPermissionRequest(string requestId, string toolUseId,
		string answer)
	{
		assert(requestId !in answeredPermissionRequests_,
			"Claude permission request answered twice");
		sendControlResponse(ClaudeControlResponse.success(requestId,
			JSONFragment(answer)));
		answeredPermissionRequests_[requestId] = toolUseId;
		emitPermissionStage(toolUseId, ItemPermissionStage.answered);
	}

	private void emitPermissionStage(string toolUseId, ItemPermissionStage stage,
		string rawLine = null)
	{
		emitEvent(TranslatedEvent(toJson(ItemPermissionEvent("item/permission",
			toolUseId, stage)), rawLine));
	}

	@JSONPartial private static struct PreToolUseHookInput
	{
		string hook_event_name;
		string tool_name;
		string tool_use_id;
		JSONFragment tool_input;
	}

	private static PreToolUseHookInput parsePreToolUseHookInput(JSONFragment hookInput)
	{
		auto input = jsonParse!PreToolUseHookInput(hookInput.json);
		enforce(input.hook_event_name == "PreToolUse",
			"Claude invoked the permission policy hook for " ~ input.hook_event_name);
		return input;
	}

	/// The hook output for a PreToolUse `hook_callback`: the policy's ruling,
	/// or nothing to leave the call to the CLI (and its classifier).
	private string answerPreToolUseHook(PreToolUseHookInput input)
	{
		assert(preToolUseHandler_ !is null,
			"Claude consulted the permission policy hook, but no handler is attached");
		auto ruling = preToolUseHandler_(ToolPermissionRequest(input.tool_use_id,
			input.tool_name, input.tool_input));

		static struct Decision
		{
			string hookEventName;
			string permissionDecision;
			string permissionDecisionReason;
		}
		static struct Output { Decision hookSpecificOutput; }
		Output decide(string decision, string reason)
		{
			return Output(Decision("PreToolUse", decision, reason));
		}
		final switch (ruling.decision)
		{
			case ToolCallDecision.allow:
				return toJson(decide("allow", "Allowed by the CyDo permission policy"));
			case ToolCallDecision.deny:
				return toJson(decide("deny", ruling.denyReason));
			case ToolCallDecision.ask:
				return toJson(decide("ask", "The CyDo permission policy asks a person"));
			case ToolCallDecision.classifier:
				return "{}";
		}
	}

	/// The CLI withdrew a `control_request` it sent earlier.
	private void handleCliControlCancel(string rawLine)
	{
		@JSONPartial static struct Cancel { string request_id; }
		auto requestId = jsonParse!Cancel(rawLine).request_id;
		if (auto answered = requestId in answeredPermissionRequests_)
		{
			// The cancellation crossed our answer, which the CLI will not
			// take (or echo).
			auto toolUseId = *answered;
			answeredPermissionRequests_.remove(requestId);
			emitPermissionStage(toolUseId, ItemPermissionStage.withdrawn, rawLine);
			return;
		}
		auto toolUseId = requestId in pendingPermissionRequests_;
		// Not a permission request: one we refused, the refusal crossing
		// the cancellation.
		if (toolUseId is null)
			return;
		auto withdrawn = *toolUseId;
		pendingPermissionRequests_.remove(requestId);
		emitPermissionStage(withdrawn, ItemPermissionStage.withdrawn, rawLine);
		permissionRequestWithdrawnHandler_(withdrawn);
	}

	/// Withdraw a user message the CLI has queued but not yet consumed
	/// (`cancel_async_message`). Resolves to whether it was withdrawn; false
	/// when the CLI had already consumed it.
	Promise!bool withdrawQueuedMessage(string uuid)
	{
		static struct Request { string subtype; string message_uuid; }
		@JSONPartial static struct Response { bool cancelled; }
		return sendControlRequest(Request("cancel_async_message", uuid))
			.then((JSONFragment response) => jsonParse!Response(response.json).cancelled);
	}

	/// Callback: `canRewindConversation` changed (the capability probe
	/// answered, or the CLI started or settled a command).
	@property void onRewindAvailabilityChanged(void delegate() dg)
	{
		rewindAvailabilityChangedHandler_ = dg;
	}

	/// Whether an in-process `rewind_conversation` can be issued now: the
	/// CLI supports it and has no turn running or queued. The CLI re-checks
	/// the latter itself and refuses a rewind racing a submission.
	@property bool canRewindConversation()
	{
		return alive && !rewindSupported_.isNull && rewindSupported_.get
			&& startedCommands_.length == 0 && queuedCommands_.length == 0;
	}

	/// Restore the files changed since the user message `userMessageId` was
	/// sent, in-process (`rewind_files`). Resolves to a description of the
	/// outcome.
	Promise!string rewindFiles(string userMessageId)
	{
		static struct Request { string subtype; string user_message_id; }
		return sendControlRequest(Request("rewind_files", userMessageId))
			.then((JSONFragment) => "Files rewound to state at message " ~ userMessageId);
	}

	/// Drop the user message `targetUuid` and everything after it from the
	/// CLI's in-memory conversation (`rewind_conversation`). The CLI leaves
	/// the abandoned rows in the session file; the next turn chains onto the
	/// row preceding the target. `lastSeenUuid` names the latest user message
	/// the caller knows of; the CLI refuses to rewind over later turns the
	/// caller has not seen. Resolves to the UUID of the message the CLI
	/// rewound to (it resolves targets by UUID prefix); rejects when the CLI
	/// refused and left the conversation unchanged.
	Promise!string rewindConversation(string targetUuid, string lastSeenUuid)
	{
		static struct Request
		{
			string subtype;
			string target_message_uuid;
			string last_seen_user_message_uuid;
		}
		@JSONPartial static struct Response
		{
			bool rewound;
			@JSONOptional string targetMessageUuid;
			@JSONOptional string reason;
		}
		return sendControlRequest(Request("rewind_conversation", targetUuid, lastSeenUuid))
			.then((JSONFragment fragment) {
				auto response = jsonParse!Response(fragment.json);
				if (!response.rewound)
					throw new Exception("Claude refused to rewind: " ~ response.reason);
				return response.targetMessageUuid;
			});
	}

	/// Learn whether this CLI version supports `rewind_conversation`. An
	/// unseen version is probed once per CyDo process with a target that
	/// matches no message: a supporting CLI answers with a refusal, an older
	/// one rejects the subtype.
	private void resolveRewindSupport(string version_)
	{
		import std.algorithm : canFind;
		import std.uuid : randomUUID;

		enforce(version_.length > 0, "Claude init event carries no claude_code_version");
		if (!rewindSupported_.isNull || rewindProbe_ !is null)
			return;
		if (auto known = version_ in rewindSupportByVersion_)
		{
			rewindSupported_ = *known;
			return;
		}
		static struct Request { string subtype; string target_message_uuid; }
		rewindProbe_ = sendControlRequest(Request("rewind_conversation", randomUUID().toString()))
			.then((JSONFragment) => true, (Exception e) {
				enum unsupported = "Unsupported control request subtype";
				if (!e.msg.canFind(unsupported))
					throw e;
				return false;
			});
		rewindProbe_.then((bool supported) {
				rewindSupportByVersion_[version_] = supported;
				rewindSupported_ = supported;
				if (rewindAvailabilityChangedHandler_)
					rewindAvailabilityChangedHandler_();
			}, (Exception e) {
				errorf("Claude rewind capability probe failed: %s", e.msg);
			}).ignoreResult();
	}

	private Promise!JSONFragment sendControlRequest(Request)(Request request)
	{
		import std.uuid : randomUUID;

		static struct Envelope { string type; string request_id; Request request; }
		auto requestId = randomUUID().toString();
		auto promise = new Promise!JSONFragment;
		pendingControlRequests_[requestId] = promise;
		try
			process.sendMessage(toJson(Envelope("control_request", requestId, request)));
		catch (Exception e)
		{
			pendingControlRequests_.remove(requestId);
			return reject!JSONFragment(e);
		}
		return promise;
	}

	/// Settle the request a `control_response` answers, if it is one of ours
	/// awaiting an answer, or take the CLI's echo of our answer to one of its
	/// permission requests. Returns false for responses nobody awaits (e.g.
	/// to fire-and-forget interrupts), which are translated as events.
	private bool settleControlResponse(string rawLine)
	{
		@JSONPartial static struct Body
		{
			string subtype;
			string request_id;
			@JSONOptional JSONFragment response;
			@JSONOptional string error;
		}
		@JSONPartial static struct Envelope { Body response; }
		auto answer = jsonParse!Envelope(rawLine).response;
		if (auto toolUseId = answer.request_id in answeredPermissionRequests_)
		{
			enforce(answer.subtype == "success",
				"Claude echoed a failed answer to its permission request");
			auto accepted = *toolUseId;
			answeredPermissionRequests_.remove(answer.request_id);
			emitPermissionStage(accepted, ItemPermissionStage.accepted, rawLine);
			return true;
		}
		auto promise = answer.request_id in pendingControlRequests_;
		if (promise is null)
			return false;
		auto awaiting = *promise;
		pendingControlRequests_.remove(answer.request_id);
		if (answer.subtype == "success")
			awaiting.fulfill(answer.response);
		else
			awaiting.reject(new Exception("Claude refused the control request: "
				~ answer.error));
		return true;
	}

	private void observeCommandLifecycle(string rawLine)
	{
		@JSONPartial static struct Lifecycle { string command_uuid; string state; }
		auto lifecycle = jsonParse!Lifecycle(rawLine);
		auto couldRewind = canRewindConversation;
		scope(success)
			if (canRewindConversation != couldRewind && rewindAvailabilityChangedHandler_)
				rewindAvailabilityChangedHandler_();
		switch (lifecycle.state)
		{
			case "queued":
				queuedCommands_[lifecycle.command_uuid] = true;
				break;
			case "started":
				queuedCommands_.remove(lifecycle.command_uuid);
				startedCommands_[lifecycle.command_uuid] = true;
				break;
			case "completed":
			case "cancelled":
				queuedCommands_.remove(lifecycle.command_uuid);
				startedCommands_.remove(lifecycle.command_uuid);
				break;
			default:
				import cydo.protocol : makeUnrecognizedEvent;
				emitEvent(TranslatedEvent(makeUnrecognizedEvent(
					"command_lifecycle state: " ~ lifecycle.state), rawLine));
		}
	}

	/// Whether the CLI replayed this user message into a turn already in
	/// progress (mid-turn absorption) rather than opening a turn with it.
	/// Claude Code no longer flags steering on the replay itself: an absorbed
	/// message is replayed before its own `started` report, while another
	/// message's turn is still running.
	private bool isAbsorbedReplay(bool isReplay, string uuid)
	{
		if (!isReplay)
			return false;
		foreach (started, _; startedCommands_)
			if (started != uuid)
				return true;
		return false;
	}

	private void sendControlResponse(ClaudeControlResponse response)
	{
		process.sendMessage(toJson(response));
	}

	// ── Stateful per-line translation ──────────────────────────────────────

	private void emitEvent(TranslatedEvent ev)
	{
		if (ev.ts == AbsTime.init)
			ev.ts = lineReceiptTs_;
		if (outputHandler && ev.translated.length > 0)
			outputHandler(ev);
	}

	private void translateLiveLine(string rawLine)
	{
		import std.datetime : Clock;
		lineReceiptTs_ = AbsTime(Clock.currStdTime);
		import std.algorithm : canFind;

		// Queue operations must pass through raw so broadcastTask can intercept them.
		if (rawLine.canFind(`"queue-operation"`))
		{
			emitEvent(TranslatedEvent(rawLine, null));
			return;
		}

		@JSONPartial static struct TypeProbe { string type; string subtype; }
		TypeProbe probe;
		try
			probe = jsonParse!TypeProbe(rawLine);
		catch (Exception)
		{
			import cydo.protocol : makeUnrecognizedEvent;
			import ae.utils.json : toJson;
			emitEvent(TranslatedEvent(makeUnrecognizedEvent("non-JSON output"), toJson(rawLine)));
			return;
		}

		if (probe.type == "system" && probe.subtype == "init")
		{
			@JSONPartial static struct InitProbe
			{
				@JSONOptional string session_id;
				@JSONOptional string cwd;
				@JSONOptional string claude_code_version;
			}
			InitProbe init;
			try
				init = jsonParse!InitProbe(rawLine);
			catch (Exception e)
			{
				tracef("Claude native session init parse error: %s", e.msg);
				return;
			}
			// Register before the native-ID notification so the live binding
			// and JSONL watch set up by that callback can already resolve
			// this session's history path.
			if (historyPathRegistrar_)
				historyPathRegistrar_(init.session_id, init.cwd);
			notifyNativeSessionStarted(init.session_id);
			resolveRewindSupport(init.claude_code_version);
		}

		if (probe.type == "system" && probe.subtype == "background_tasks_changed")
			liveBackgroundTasks_ = parseLiveBackgroundTasks(rawLine);

		switch (probe.type)
		{
			case "stream_event":
				translateStreamEventLive(rawLine);
				return;
			case "assistant":
				translateAssistantLive(rawLine);
				return;
			case "user":
				normalizeUserLive(rawLine);
				return;
			case "control_request":
				handleCliControlRequest(rawLine);
				return;
			case "control_cancel_request":
				handleCliControlCancel(rawLine);
				return;
			case "command_lifecycle":
				observeCommandLifecycle(rawLine);
				return;
			case "control_response":
				if (settleControlResponse(rawLine))
					return;
				goto default;
			default:
				// Stateless translation for system, result, summary, control, etc.
				auto t = translateClaudeEvent(rawLine, agentName_);
				if (t.translated !is null)
					emitEvent(t);
				return;
		}
	}

	private void translateStreamEventLive(string rawLine)
	{
		import std.string : indexOf;

		// Extract the inner event object from {type:"stream_event", event:{...}}
		auto eventStart = rawLine.indexOf(`"event":`);
		if (eventStart < 0) return;
		auto valueStart = cast(size_t)(eventStart + `"event":`.length);
		while (valueStart < rawLine.length && rawLine[valueStart] == ' ')
			valueStart++;
		if (valueStart >= rawLine.length || rawLine[valueStart] != '{') return;
		auto innerEnd = findMatchingBrace(rawLine, valueStart);
		if (innerEnd < 0) return;
		auto innerEvent = rawLine[valueStart .. innerEnd + 1];

		@JSONPartial static struct InnerProbe { string type; }
		InnerProbe inner;
		try
			inner = jsonParse!InnerProbe(innerEvent);
		catch (Exception e)
		{ tracef("translateStreamEventLive: inner probe error: %s", e.msg); return; }

		switch (inner.type)
		{
			case "content_block_start":
			{
				@JSONPartial
				static struct BlockStartProbe
				{
					int index;
					@JSONPartial
					static struct BD { string type; @JSONOptional string id; @JSONOptional string name; }
					BD content_block;
				}
				try
				{
					auto probe = jsonParse!BlockStartProbe(innerEvent);
					auto idx = probe.index;
					auto blockType = probe.content_block.type;

					// Assign item_id: use block.id for tool_use, generate for text/thinking.
					string itemId = blockType == "tool_use" && probe.content_block.id.length > 0
						? probe.content_block.id
						: "cc-block-" ~ to!string(idx);

					// Grow tracking arrays.
					while (activeItemIds_.length <= idx) activeItemIds_ ~= null;
					while (activeItemTypes_.length <= idx) activeItemTypes_ ~= null;
					activeItemIds_[idx] = itemId;
					activeItemTypes_[idx] = blockType;

					import cydo.protocol : ItemStartedEvent, decomposeToolName;
					ItemStartedEvent ev;
					ev.item_id = itemId;
					ev.item_type = blockType;
					if (blockType == "tool_use")
						decomposeToolName(probe.content_block.name, ev.name, ev.tool_server, ev.tool_source);
					emitEvent(TranslatedEvent(toJson(ev), rawLine));
				}
				catch (Exception e)
				{ tracef("translateStreamEventLive: block_start error: %s", e.msg); }
				return;
			}

			case "content_block_delta":
			{
				@JSONPartial
				static struct BlockDeltaProbe
				{
					int index;
					@JSONPartial
					static struct DP
					{
						string type;
						@JSONOptional string text;
						@JSONOptional string partial_json;
						@JSONOptional string thinking;
					}
					DP delta;
				}
				try
				{
					auto probe = jsonParse!BlockDeltaProbe(innerEvent);
					auto idx = probe.index;
					if (probe.delta.type == "signature_delta")
						return; // drop
					if (idx >= activeItemIds_.length || activeItemIds_[idx] is null)
						return;

					import cydo.protocol : ItemDeltaEvent;
					ItemDeltaEvent ev;
					ev.item_id = activeItemIds_[idx];
					if (probe.delta.type == "thinking_delta")
					{
						ev.delta_type = "thinking_delta";
						ev.content = probe.delta.thinking;
					}
					else if (probe.delta.type == "input_json_delta")
					{
						ev.delta_type = "input_json_delta";
						ev.content = probe.delta.partial_json;
					}
					else
					{
						ev.delta_type = "text_delta";
						ev.content = probe.delta.text;
					}
					emitEvent(TranslatedEvent(toJson(ev), null));
				}
				catch (Exception e)
				{ tracef("translateStreamEventLive: block_delta error: %s", e.msg); }
				return;
			}

			case "content_block_stop":
			{
				@JSONPartial static struct StopProbe { int index; }
				try
				{
					auto probe = jsonParse!StopProbe(innerEvent);
					auto idx = probe.index;
					if (idx < activeItemIds_.length && activeItemIds_[idx] !is null)
					{
						import cydo.protocol : ItemCompletedEvent;
						ItemCompletedEvent ev;
						ev.item_id = activeItemIds_[idx];
						if (auto completion = activeItemIds_[idx] in blockCompletions_)
						{
							ev.extras = completion.extras;
							ev.is_narration = completion.isNarration;
						}
						emitEvent(TranslatedEvent(toJson(ev), rawLine));
					}
				}
				catch (Exception e)
				{ tracef("content_block_stop: parse error: %s", e.msg); }
				return;
			}

			case "message_stop":
			{
				import cydo.protocol : TurnStopEvent;
				TurnStopEvent tsev;
				emitEvent(TranslatedEvent(toJson(tsev), rawLine));
				activeItemIds_ = null;
				activeItemTypes_ = null;
				blockCompletions_ = null;
				return;
			}
			case "message_start":
			case "message_delta":
				return; // drop

			default:
				return; // unknown inner events — drop
		}
	}

	/// Translate an assistant NDJSON event to a turn/delta metadata event.
	/// Content promotion is handled by content_block_stop → item/completed.
	/// Exception: sub-agent messages (parent_tool_use_id set) arrive as complete
	/// messages even in the live stream, so they are processed like history.
	private void translateAssistantLive(string rawLine)
	{
		import cydo.protocol : TurnDeltaEvent, UsageInfo;

		@JSONPartial static struct ClaudeBlock
		{
			string type;
			@JSONOptional string id;
			@JSONOptional string name;
			@JSONOptional JSONFragment input;
			@JSONOptional string text;
			@JSONOptional string thinking;
			@JSONOptional string signature;
			JSONExtras _extras;
		}
		@JSONPartial static struct ClaudeMessage
		{
			@JSONOptional string model;
			@JSONOptional JSONFragment usage;
			@JSONOptional ClaudeBlock[] content;
		}
		// Full struct with JSONExtras to capture unknown top-level fields.
		// All known Claude Code fields are listed so they are not captured as extras.
		static struct ClaudeAssistant
		{
			@JSONOptional string parent_tool_use_id;
			@JSONOptional bool isSidechain;
			@JSONOptional bool isApiErrorMessage;
			@JSONOptional string uuid;
			ClaudeMessage message;
			/// Indexes into message.content of the thinking blocks the server
			/// tagged as narration. Claude Code decodes the tag from the block
			/// signature and reports it on live frames only; it is not
			/// persisted to the session file.
			@JSONOptional size_t[] narration_block_indexes;
			@JSONOptional string type;
			@JSONOptional string session_id;
			@JSONOptional string sessionId;
			@JSONOptional string agentId;
			@JSONOptional string parentUuid;
			@JSONOptional string requestId;
			@JSONOptional string cwd;
			@JSONOptional string gitBranch;
			@JSONName("version") @JSONOptional string version_;
			@JSONOptional string userType;
			@JSONOptional string timestamp;
			@JSONOptional string slug;
			@JSONOptional string permissionMode;
			@JSONOptional string entrypoint;
			@JSONOptional JSONFragment diagnostics;
			mixin ClaudeAssistantUnhandledFields;
			JSONExtras _extras;
		}

		ClaudeAssistant raw;
		try
			raw = jsonParse!ClaudeAssistant(rawLine);
		catch (Exception e)
		{ tracef("translateAssistantLive: parse error: %s", e.msg); return; }

		// A listed block with no thinking text gets ordinary thinking
		// treatment (Claude Code documents this for narration_block_indexes).
		bool isNarration(size_t idx)
		{
			import std.algorithm.searching : canFind;
			import std.string : strip;
			auto b = &raw.message.content[idx];
			return raw.narration_block_indexes.canFind(idx)
				&& b.type == "thinking" && b.thinking.strip().length > 0;
		}

		if (raw.isApiErrorMessage && raw.parent_tool_use_id.length == 0)
		{
			string errorText;
			foreach (ref b; raw.message.content)
				if (b.text.length > 0) errorText ~= b.text;
			TaskDiagnosticEvent ev;
			ev.severity = TaskDiagnosticSeverity.error;
			ev.subject = "Agent error";
			ev.body = errorText;
			emitEvent(TranslatedEvent(toJson(ev), rawLine));
			return;
		}

		// Sub-agent messages arrive as complete messages with parent_tool_use_id
		// set even in the live stream.  Emitting a TurnDeltaEvent for them would
		// corrupt the main streaming turn (M_main) by setting its parentToolUseId.
		// Process them like history messages instead (ItemStarted+Completed+TurnStop).
		if (raw.parent_tool_use_id.length > 0)
		{
			import cydo.protocol : ItemStartedEvent, ItemCompletedEvent,
				TurnStopEvent, decomposeToolName;

			foreach (idx, ref b; raw.message.content)
			{
				auto itemId = b.type == "tool_use" && b.id.length > 0
					? b.id : "cc-subagent-" ~ to!string(idx);

				ItemStartedEvent startEv;
				startEv.item_id              = itemId;
				startEv.item_type            = b.type;
				startEv.parent_tool_use_id   = raw.parent_tool_use_id;
				startEv.is_sidechain         = raw.isSidechain;
				if (b.type == "tool_use")
				{
					decomposeToolName(b.name, startEv.name, startEv.tool_server, startEv.tool_source);
					startEv.input = b.input;
				}
				else
				{
					auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
					startEv.text = text;
				}
				emitEvent(TranslatedEvent(toJson(startEv), rawLine));

				ItemCompletedEvent compEv;
				compEv.item_id = itemId;
				if (b.type == "tool_use")
					compEv.input = b.input;
				else
				{
					auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
					compEv.text = text;
				}
				compEv.is_narration = isNarration(idx);
				compEv.extras = extrasToFragment(b._extras);
				emitEvent(TranslatedEvent(toJson(compEv), rawLine));
			}

			UsageInfo subUsage;
			if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
			{
				@JSONPartial static struct UP2 { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
				try
				{
					auto u = jsonParse!UP2(raw.message.usage.json);
					subUsage.input_tokens  = u.input_tokens;
					subUsage.output_tokens = u.output_tokens;
				}
				catch (Exception) {}
			}

			TurnStopEvent tsev;
			tsev.model              = raw.message.model;
			tsev.usage              = subUsage;
			tsev.parent_tool_use_id = raw.parent_tool_use_id;
			tsev.is_sidechain       = raw.isSidechain;
			tsev.uuid               = raw.uuid;
			tsev.extras = extrasToFragment(collectAllExtras(raw));
			emitEvent(TranslatedEvent(toJson(tsev), rawLine));
			return;
		}

		UsageInfo usage;
		if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
		{
			@JSONPartial static struct UP { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
			try
			{
				auto u = jsonParse!UP(raw.message.usage.json);
				usage.input_tokens  = u.input_tokens;
				usage.output_tokens = u.output_tokens;
			}
			catch (Exception) {}
		}

		// Hold what the frame says about each block for its content_block_stop.
		// A live frame carries the blocks most recently started on the stream
		// (in practice one, sent just before that block's stop), so its
		// content indexes are relative to the frame, not the stream. A frame
		// with more blocks than were started was not streamed (a synthetic
		// message), so no stop will come to pick anything up.
		if (raw.message.content.length <= activeItemIds_.length)
		{
			auto firstStreamIdx = activeItemIds_.length - raw.message.content.length;
			foreach (idx, ref b; raw.message.content)
			{
				BlockCompletion completion;
				completion.extras = extrasToFragment(b._extras);
				completion.isNarration = isNarration(idx);
				auto itemId = activeItemIds_[firstStreamIdx + idx];
				enforce(itemId !is null, "assistant frame block has no started stream block");
				blockCompletions_[itemId] = completion;
			}
		}

		TurnDeltaEvent ev;
		ev.model              = raw.message.model;
		ev.usage              = usage;
		ev.parent_tool_use_id = raw.parent_tool_use_id;
		ev.is_sidechain       = raw.isSidechain;
		ev.uuid               = raw.uuid;
		ev.extras             = extrasToFragment(raw._extras);
		emitEvent(TranslatedEvent(toJson(ev), rawLine));
	}

	private void normalizeUserLive(string rawLine)
	{
		import cydo.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent;

		@JSONPartial static struct ClaudeUserMsg { JSONFragment content; }
		@JSONPartial static struct ClaudeUser
		{
			ClaudeUserMsg message;
			@JSONOptional bool isReplay;
			@JSONOptional bool isSynthetic;
			@JSONOptional bool isMeta;
			@JSONOptional bool isSteering;
			@JSONOptional bool pending;
			@JSONOptional string uuid;
			@JSONOptional string parent_tool_use_id;
			@JSONOptional bool isSidechain;
			@JSONOptional JSONFragment toolUseResult;
			@JSONOptional JSONFragment tool_use_result;
		}

		ClaudeUser raw;
		try
			raw = jsonParse!ClaudeUser(rawLine);
		catch (Exception e)
		{ tracef("normalizeUserLive: parse error: %s", e.msg); return; }

		auto contentJson = raw.message.content.json;
		if (contentJson is null || contentJson.length == 0)
			return;

		if (contentJson[0] == '"')
		{
			// String content → user_message item.
			string text;
			try text = jsonParse!string(contentJson);
			catch (Exception) {}

			ContentBlock cb;
			cb.type = "text";
			cb.text = text;

			ItemStartedEvent ev;
			ev.item_id   = "cc-user-msg";
			ev.item_type = "user_message";
			ev.content   = [cb];
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering        = raw.isSteering || isAbsorbedReplay(raw.isReplay, raw.uuid);
			ev.pending            = raw.pending;
			ev.uuid               = raw.uuid;
			ev.parent_tool_use_id = raw.parent_tool_use_id;
			ev.is_sidechain       = raw.isSidechain;
			emitEvent(TranslatedEvent(toJson(ev), rawLine));
		}
		else if (contentJson[0] == '[')
		{
			// Array content — tool_results and/or text/image blocks.
			@JSONPartial
			static struct ImageSource
			{
				@JSONOptional string data;
				@JSONOptional string media_type;
			}
			@JSONPartial
			static struct ContentItem
			{
				string type;
				@JSONOptional string tool_use_id;
				@JSONOptional JSONFragment content;
				@JSONOptional bool is_error;
				@JSONOptional string text;
				@JSONOptional ImageSource source;
			}
			ContentItem[] items;
			try items = jsonParse!(ContentItem[])(contentJson);
			catch (Exception e) { tracef("normalizeUserLive: content parse error: %s", e.msg); return; }

			// Collect user content blocks (text + image); emit tool_results separately.
			ContentBlock[] userBlocks;
			foreach (ref item; items)
			{
				if (item.type == "tool_result")
				{
					ItemResultEvent ev;
					ev.item_id  = item.tool_use_id;
					auto cj = item.content.json;
					if (cj is null || cj.length == 0)
						ev.content = JSONFragment(`[{"type":"text","text":""}]`);
					else if (cj[0] == '"')
						ev.content = JSONFragment(`[{"type":"text","text":` ~ cj ~ `}]`);
					else
						ev.content = item.content;
					ev.is_error = item.is_error;
					if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
						ev.tool_result = raw.toolUseResult;
					else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
						ev.tool_result = raw.tool_use_result;
					emitEvent(TranslatedEvent(toJson(ev), rawLine));
				}
				else if (item.type == "text")
				{
					ContentBlock cb;
					cb.type = "text";
					cb.text = item.text;
					userBlocks ~= cb;
				}
				else if (item.type == "image")
				{
					ContentBlock cb;
					cb.type       = "image";
					cb.data       = item.source.data;
					cb.media_type = item.source.media_type;
					userBlocks ~= cb;
				}
			}

			if (userBlocks.length > 0)
			{
				ItemStartedEvent ev;
				ev.item_id   = "cc-user-msg";
				ev.item_type = "user_message";
				ev.content   = userBlocks;
				ev.is_replay   = raw.isReplay;
				ev.is_synthetic = raw.isSynthetic;
				ev.is_meta     = raw.isMeta;
				ev.is_steering        = raw.isSteering || isAbsorbedReplay(raw.isReplay, raw.uuid);
				ev.pending            = raw.pending;
				ev.uuid               = raw.uuid;
				ev.parent_tool_use_id = raw.parent_tool_use_id;
				ev.is_sidechain       = raw.isSidechain;
				emitEvent(TranslatedEvent(toJson(ev), rawLine));
			}
		}
	}
}

unittest
{
	ClaudeCodeSession.rewindSupportByVersion_["fixture"] = false;
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	string[] order;
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };
	session.translateLiveLine(
		`{"type":"system","subtype":"init","session_id":"claude-native-id","claude_code_version":"fixture"}`);
	assert(order.length >= 2
		&& order[0] == "native:claude-native-id"
		&& order[1] == "output",
		"Claude must deliver its native ID before translated session initialization");

	auto lateSession = new ClaudeCodeSession("true");
	scope(exit) lateSession.stop();
	lateSession.translateLiveLine(
		`{"type":"system","subtype":"init","session_id":"claude-late-id","claude_code_version":"fixture"}`);
	string delivered;
	lateSession.onNativeSessionStarted = (string sessionId) { delivered = sessionId; };
	assert(delivered == "claude-late-id");
}

// can_use_tool requests reach the permission handler; a cancel for a pending
// request withdraws it, and a cancel for an unknown request is ignored.
unittest
{
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	PermissionPrompt[] requests;
	PermissionEscalation[] escalations;
	string[] withdrawn;
	session.onToolPermissionRequest = (PermissionPrompt req, PermissionEscalation escalation) {
		requests ~= req;
		escalations ~= escalation;
		return new Promise!string;
	};
	session.onToolPermissionRequestWithdrawn = (string toolUseId) { withdrawn ~= toolUseId; };

	session.translateLiveLine(`{"type":"control_request","request_id":"req-1","request":`
		~ `{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_1",`
		~ `"input":{"command":"touch x"},"permission_suggestions":[]}}`);
	assert(requests.length == 1);
	assert(requests[0].toolUseId == "toolu_1");
	assert(requests[0].toolName == "Bash");
	assert(requests[0].input.json == `{"command":"touch x"}`);
	assert(escalations == [PermissionEscalation.safetyCheck]);

	session.translateLiveLine(`{"type":"control_request","request_id":"req-2","request":`
		~ `{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_2",`
		~ `"input":{"command":"cat x | rm -rf /"},"decision_reason_type":"subcommandResults",`
		~ `"decision_reason":"Dangerous rm operation on critical path: /"}}`);
	assert(requests[1].reason == "Dangerous rm operation on critical path: /");
	session.translateLiveLine(`{"type":"control_request","request_id":"req-3","request":`
		~ `{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_3",`
		~ `"input":{},"decision_reason_type":"hook","decision_reason":"The CyDo permission policy asks a person"}}`);
	assert(escalations[2] == PermissionEscalation.policyAsk);
	assert(requests[2].reason is null);

	session.translateLiveLine(`{"type":"control_cancel_request","request_id":"req-other"}`);
	assert(withdrawn.length == 0);
	session.translateLiveLine(`{"type":"control_cancel_request","request_id":"req-1"}`);
	assert(withdrawn == ["toolu_1"]);
	session.translateLiveLine(`{"type":"control_cancel_request","request_id":"req-1"}`);
	assert(withdrawn == ["toolu_1"]);
}

// Each permission request reports its stages: asked (can_use_tool only),
// answered once we reply, then accepted when the CLI echoes our answer
// (the echo itself is not forwarded), or withdrawn when the CLI cancels.
unittest
{
	import ae.net.asockets : socketManager;

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

	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	string[] events;
	session.onOutput = (TranslatedEvent ev) { events ~= ev.translated; };
	Promise!string[] decisions;
	session.onToolPermissionRequest = (PermissionPrompt req, PermissionEscalation escalation) {
		decisions ~= new Promise!string;
		return decisions[$ - 1];
	};
	session.onToolPermissionRequestWithdrawn = (string toolUseId) {};
	session.onPreToolUse = (ToolPermissionRequest req) => ToolCallRuling(ToolCallDecision.allow);
	string stage(string toolUseId, string stage_)
	{
		return `{"type":"item/permission","item_id":"` ~ toolUseId ~ `","stage":"` ~ stage_ ~ `"}`;
	}
	string echo(string requestId)
	{
		return `{"type":"control_response","response":{"subtype":"success","request_id":"`
			~ requestId ~ `","response":{}}}`;
	}

	session.translateLiveLine(`{"type":"control_request","request_id":"hook-1","request":`
		~ `{"subtype":"hook_callback","callback_id":"cydo-permission-policy","input":`
		~ `{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_1",`
		~ `"tool_input":{}}}}`);
	assert(events == [stage("toolu_1", "answered")]);
	session.translateLiveLine(echo("hook-1"));
	assert(events[1 .. $] == [stage("toolu_1", "accepted")]);

	session.translateLiveLine(`{"type":"control_request","request_id":"req-2","request":`
		~ `{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_2","input":{}}}`);
	assert(events[2 .. $] == [stage("toolu_2", "asked")]);
	decisions[0].fulfill(`{"behavior":"allow"}`);
	drainNextTicks();
	assert(events[3 .. $] == [stage("toolu_2", "answered")]);
	session.translateLiveLine(echo("req-2"));
	assert(events[4 .. $] == [stage("toolu_2", "accepted")]);

	session.translateLiveLine(`{"type":"control_request","request_id":"req-3","request":`
		~ `{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu_3","input":{}}}`);
	decisions[1].fulfill(`{"behavior":"allow"}`);
	drainNextTicks();
	session.translateLiveLine(`{"type":"control_cancel_request","request_id":"req-3"}`);
	assert(events[5 .. $] == [stage("toolu_3", "asked"), stage("toolu_3", "answered"),
		stage("toolu_3", "withdrawn")]);
	assert(session.answeredPermissionRequests_.length == 0);
}

// The rewind capability is probed once per CLI version: a supporting CLI
// answers the probe (with a refusal), an older one rejects the subtype.
unittest
{
	import ae.net.asockets : socketManager;

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
	string answerProbe(ClaudeCodeSession session, string body)
	{
		assert(session.pendingControlRequests_.length == 1);
		auto requestId = session.pendingControlRequests_.keys[0];
		session.translateLiveLine(`{"type":"control_response","response":{"request_id":"`
			~ requestId ~ `",` ~ body ~ `}}`);
		drainNextTicks();
		return requestId;
	}
	void init(ClaudeCodeSession session, string version_)
	{
		session.translateLiveLine(`{"type":"system","subtype":"init","session_id":"s",`
			~ `"claude_code_version":"` ~ version_ ~ `"}`);
	}
	// Every session registers the permission policy hook as it starts.
	ClaudeCodeSession start()
	{
		auto session = new ClaudeCodeSession("true");
		answerProbe(session, `"subtype":"success","response":{}`);
		return session;
	}

	auto supporting = start();
	scope(exit) supporting.stop();
	size_t changes;
	supporting.onRewindAvailabilityChanged = () { changes++; };
	init(supporting, "probe-supported");
	init(supporting, "probe-supported");
	answerProbe(supporting, `"subtype":"success","response":{"rewound":false,`
		~ `"error":"target not found","reason":"target_not_found"}`);
	assert(changes == 1);
	assert(supporting.rewindSupported_.get);
	init(supporting, "probe-supported");
	assert(supporting.pendingControlRequests_.length == 0);

	auto cached = start();
	scope(exit) cached.stop();
	init(cached, "probe-supported");
	assert(cached.pendingControlRequests_.length == 0);
	assert(cached.rewindSupported_.get);

	auto older = start();
	scope(exit) older.stop();
	init(older, "probe-unsupported");
	answerProbe(older, `"subtype":"error",`
		~ `"error":"Unsupported control request subtype: rewind_conversation"}`);
	assert(!older.rewindSupported_.get);
	assert(!ClaudeCodeSession.rewindSupportByVersion_["probe-unsupported"]);
}

// A message replayed while another message's turn is running was absorbed
// as steering; a turn opener is replayed after its own `started` report.
unittest
{
	@JSONPartial static struct Probe { string type; @JSONOptional bool is_steering; }
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	bool[] steering;
	session.onOutput = (TranslatedEvent event) {
		auto probe = jsonParse!Probe(event.translated);
		if (probe.type == "item/started")
			steering ~= probe.is_steering;
	};
	void lifecycle(string uuid, string state)
	{
		session.translateLiveLine(`{"type":"command_lifecycle","command_uuid":"` ~ uuid
			~ `","state":"` ~ state ~ `"}`);
	}
	void replay(string uuid)
	{
		session.translateLiveLine(`{"type":"user","uuid":"` ~ uuid
			~ `","isReplay":true,"message":{"role":"user","content":"m"}}`);
	}

	lifecycle("u1", "queued");
	lifecycle("u1", "started");
	replay("u1");
	lifecycle("u2", "queued");
	replay("u2");
	lifecycle("u2", "started");
	lifecycle("u2", "completed");
	lifecycle("u1", "completed");
	// Interrupted turn: the running message is cancelled, and a message
	// queued behind it opens the next turn.
	lifecycle("u3", "started");
	replay("u3");
	lifecycle("u4", "queued");
	lifecycle("u3", "cancelled");
	lifecycle("u4", "started");
	replay("u4");
	assert(steering == [false, true, false, false]);
}

// The history path registrar receives the init event's session ID and cwd
// before the native-ID callback fires, so the live binding created in that
// callback can already resolve the session's history path.
unittest
{
	ClaudeCodeSession.rewindSupportByVersion_["fixture"] = false;
	string[] order;
	auto session = new ClaudeCodeSession("true", null, null, null, SessionConfig.init,
		(string sessionId, string cwd) { order ~= "register:" ~ sessionId ~ ":" ~ cwd; });
	scope(exit) session.stop();
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	session.translateLiveLine(
		`{"type":"system","subtype":"init","session_id":"reg-id","cwd":"/mnt/scratch/proj","claude_code_version":"fixture"}`);
	assert(order.length >= 2
		&& order[0] == "register:reg-id:/mnt/scratch/proj"
		&& order[1] == "native:reg-id",
		"Claude must register the history path before delivering its native ID");
}

// Live assistant frames carry the block they announce at frame index 0, just
// before that block's content_block_stop (as Claude Code 2.1.319 streams a
// reasoning block, a narration block, then text). What the frame says about
// the block (narration, extras) must land on that stream block's item.
unittest
{
	@JSONPartial static struct CompletedProbe
	{
		string type;
		@JSONOptional string item_id;
		@JSONOptional bool is_narration;
		@JSONOptional JSONFragment extras;
	}

	TranslatedEvent[] events;
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	session.onOutput = (TranslatedEvent event) { events ~= event; };

	string streamEvent(string event) { return `{"type":"stream_event","event":` ~ event ~ `}`; }
	void block(int index, string type, string frameBlock, string frameFields)
	{
		auto i = to!string(index);
		session.translateLiveLine(streamEvent(`{"type":"content_block_start","index":` ~ i
			~ `,"content_block":{"type":"` ~ type ~ `"}}`));
		session.translateLiveLine(`{"type":"assistant","message":{"content":[` ~ frameBlock ~ `]}`
			~ frameFields ~ `}`);
		session.translateLiveLine(streamEvent(`{"type":"content_block_stop","index":` ~ i ~ `}`));
	}

	session.translateLiveLine(streamEvent(`{"type":"message_start","message":{}}`));
	block(0, "thinking", `{"type":"thinking","thinking":"private reasoning","signature":"s"}`, ``);
	block(1, "thinking", `{"type":"thinking","thinking":"Checking the fixture.","signature":"s","fixture_extra":1}`,
		`,"narration_block_indexes":[0]`);
	block(2, "thinking", `{"type":"thinking","thinking":"","signature":"s"}`,
		`,"narration_block_indexes":[0]`);
	block(3, "text", `{"type":"text","text":"done"}`, ``);

	CompletedProbe[string] completed;
	foreach (ev; events)
	{
		auto probe = jsonParse!CompletedProbe(ev.translated);
		if (probe.type == "item/completed")
			completed[probe.item_id] = probe;
	}
	assert(completed.length == 4);
	assert(!completed["cc-block-0"].is_narration);
	assert(completed["cc-block-0"].extras.json is null);
	assert(completed["cc-block-1"].is_narration);
	assert(completed["cc-block-1"].extras.json == `{"fixture_extra":1}`);
	assert(!completed["cc-block-2"].is_narration,
		"a listed block without thinking text is ordinary thinking");
	assert(!completed["cc-block-3"].is_narration);
}

unittest
{
	@JSONPartial static struct DiagnosticProbe
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	auto liveRaw =
		`{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"thinking","thinking":"live reasoning"},{"type":"text","text":"live error"}]}}`;
	TranslatedEvent[] liveEvents;
	auto session = new ClaudeCodeSession("true");
	scope(exit) session.stop();
	session.onOutput = (TranslatedEvent event) { liveEvents ~= event; };
	session.translateAssistantLive(liveRaw);
	assert(liveEvents.length == 1);
	auto live = jsonParse!DiagnosticProbe(liveEvents[0].translated);
	assert(live.type == "cydo/task_diagnostic");
	assert(live.severity == "error");
	assert(live.subject == "Agent error");
	assert(live.body == "live error");
	assert(liveEvents[0].raw == liveRaw);

	auto historyRaw =
		`{"type":"assistant","isApiErrorMessage":true,"message":{"id":"history-error","content":[{"type":"thinking","thinking":"history reasoning"},{"type":"text","text":"history error"}]}}`;
	auto historyEvents = translateAssistantHistory(historyRaw);
	assert(historyEvents.length == 1);
	auto history = jsonParse!DiagnosticProbe(historyEvents[0].translated);
	assert(history.type == "cydo/task_diagnostic");
	assert(history.severity == "error");
	assert(history.subject == "Agent error");
	assert(history.body == "history reasoninghistory error");
	assert(historyEvents[0].raw == historyRaw);
}

unittest
{
	import ae.net.asockets : socketManager;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	void assertRejected(Promise!AgentSubmissionReceipt submission,
		string expectedMessage)
	{
		bool fulfilled;
		string rejectionMessage;
		submission.then((AgentSubmissionReceipt receipt) {
			fulfilled = true;
		}, (Exception error) {
			rejectionMessage = error.msg;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!fulfilled && rejectionMessage == expectedMessage);
	}

	// A live local stdin enqueue is Claude's only submission receipt; it must
	// not wait for an app-server response that Claude does not provide.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();

		bool fulfilled;
		session.sendMessage([ContentBlock("text", "local enqueue")],
			"ignored-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.localEnqueued);
			fulfilled = true;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(fulfilled);
	}

	{
		enum supplied = "A32A27AF-7CC1-429D-888D-637C6CFCF9DD";
		auto input = jsonParse!ClaudeInput(ClaudeCodeSession.serializeClaudeInput(
			[ContentBlock("text", "uuid transport")], supplied, MessageSource.harness));
		assert(input.uuid == supplied);
	}

	{
		auto input = jsonParse!ClaudeInput(ClaudeCodeSession.serializeClaudeInput(
			[ContentBlock("text", "uuid transport")], null, MessageSource.harness));
		import std.uuid : UUID;
		assert(!UUID(input.uuid).empty);
	}

	foreach (invalid; ["not-a-uuid", "00000000-0000-0000-0000-000000000000"])
	{
		bool rejected;
		try ClaudeCodeSession.serializeClaudeInput([ContentBlock("text", "invalid uuid")], invalid,
			MessageSource.harness);
		catch (Exception) rejected = true;
		assert(rejected);
	}

	// A disconnected local transport rejects through the returned promise.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();
		session.process.forceClosePipes();

		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage([ContentBlock("text", "dead")]);
		catch (Exception error)
			assert(false, "sendMessage threw instead of returning a rejection: "
				~ error.msg);
		assertRejected(submission, "Agent process is no longer running");
	}

	// Content conversion failures likewise belong to the promise contract,
	// rather than escaping synchronously before a caller can attach rejection
	// handling.
	{
		auto session = new ClaudeCodeSession("true");
		scope(exit) session.stop();

		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage([
				ContentBlock("unsupported", "cannot serialize"),
			]);
		catch (Exception error)
			assert(false, "sendMessage threw instead of returning a rejection: "
				~ error.msg);
		assertRejected(submission,
			"Unsupported content block type for Claude: unsupported");
	}
}

private:

struct ClaudeControlRequest
{
	string type = "control_request";
	string request_id;
	struct Req { string subtype; }
	Req request;
}

/// Our answer to a `control_request` the CLI sent.
struct ClaudeControlResponse
{
	string type = "control_response";
	static struct Body
	{
		string subtype;
		string request_id;
		@JSONOptional JSONFragment response;
		@JSONOptional string error;
	}
	Body response;

	static ClaudeControlResponse success(string requestId, JSONFragment payload)
	{
		ClaudeControlResponse r;
		r.response = Body("success", requestId, payload, null);
		return r;
	}

	static ClaudeControlResponse error(string requestId, string message)
	{
		ClaudeControlResponse r;
		r.response = Body("error", requestId, JSONFragment.init, message);
		return r;
	}
}

struct ClaudeTextBlock { string type = "text"; string text; }
struct ClaudeImageSource { string type = "base64"; string data; string media_type; }
struct ClaudeImageBlock { string type = "image"; ClaudeImageSource source; }

struct ClaudeInput
{
	string type;
	string uuid;
	ClaudeInputMessage message;
	string session_id;
	string parent_tool_use_id;
	@JSONOptional ClaudeInputOrigin origin;
}

/// Provenance of a user-role message (`origin`); absent = unattributed.
struct ClaudeInputOrigin
{
	string kind;
}

struct ClaudeInputMessage
{
	string role;
	JSONFragment content;  // string or content block array (JSONFragment serializes as-is)
}

/// Mangle a project path the same way Claude CLI does: replace every
/// non-alphanumeric character with '-'.
private string mangleProjectPath(string path)
{
	auto buf = path.dup;
	foreach (ref c; buf)
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
			c = '-';
	return buf.idup;
}

private struct McpConfigEnv
{
	string CYDO_TID;
	string CYDO_SOCKET;
	string CYDO_CREATABLE_TYPES;
	string CYDO_SWITCHMODES;
	string CYDO_HANDOFFS;
	string CYDO_INCLUDE_TOOLS;
}

private struct McpConfigServer
{
	string type = "stdio";
	string command;
	string[] args;
	McpConfigEnv env;
	// Claude Code ≥2.1.2xx defers MCP tools behind ToolSearch by default.
	// cydo's tools are the session's core workflow verbs (Task, SwitchMode,
	// Ask, …); they must stay in the model's tool list unconditionally.
	bool alwaysLoad = true;
	int timeout = 2_147_483_647;
}

private struct McpConfigServers { McpConfigServer cydo; }
private struct McpConfig { McpConfigServers mcpServers; }

/// Generate a temporary MCP config file pointing to the cydo binary.
/// creatableTaskTypes is pre-formatted text describing available task types.
/// switchModes is pre-formatted text describing available SwitchMode continuations.
/// handoffs is pre-formatted text describing available Handoff continuations.
/// mcpSocketPath is the absolute path to the backend's UNIX socket for MCP calls.
string generateMcpConfig(int tid, const ref NativeHistoryProfile profile,
	string creatableTaskTypes = "",
	string switchModes = "", string handoffs = "", string[] includeTools = null,
	string mcpSocketPath = "")
{
	import std.array : join;
	import std.exception : enforce;
	import std.file : exists, mkdirRecurse, write;
	import std.path : buildPath;

	enforce(profile.driver == AgentDriver.claude,
		"Claude MCP config requires a Claude native history profile");
	auto configDir = buildPath(profile.root, "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto cydoBin = cydoBinaryPath;
	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	import ae.utils.array : nonNull;

	// MCP config pointing to our binary in MCP server mode.
	// CYDO_SOCKET tells the proxy to connect via UNIX socket (no auth needed).
	auto cfg = McpConfig(McpConfigServers(McpConfigServer(
		"stdio",
		cydoBin,
		["mcp-server"],
		McpConfigEnv(
			to!string(tid),
			mcpSocketPath.nonNull,
			creatableTaskTypes.nonNull,
			switchModes.nonNull,
			handoffs.nonNull,
			includeTools is null ? "" : includeTools.join(","),
		),
	)));
	write(configPath, toJson(cfg));
	return configPath;
}

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-claude-mcp-native-profile");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto profile = NativeHistoryProfile(AgentDriver.claude,
		buildPath(root, "supplied-profile"));
	auto configPath = generateMcpConfig(42, profile);
	assert(configPath == buildPath(profile.root, "mcp-configs", "cydo-42.json"));
	assert(exists(configPath));
	auto wrongDriverProfile = NativeHistoryProfile(AgentDriver.codex,
		buildPath(root, "wrong-driver"));
	assertThrown!Exception(generateMcpConfig(42, wrongDriverProfile));
}

/// Build a Claude-wire-format content array from agnostic ContentBlock[].
/// Returns a JSONFragment suitable for embedding in ClaudeInputMessage.content.
private JSONFragment buildClaudeContentBlocks(const(ContentBlock)[] blocks)
{
	import cydo.protocol : ContentBlock;

	string json = "[";
	foreach (i, ref b; blocks)
	{
		if (i > 0) json ~= ",";
		if (b.type == "text")
		{
			ClaudeTextBlock tb;
			tb.text = b.text;
			json ~= toJson(tb);
		}
		else if (b.type == "image")
		{
			ClaudeImageBlock ib;
			ib.source.data = b.data;
			ib.source.media_type = b.media_type;
			json ~= toJson(ib);
		}
		else
		{
			throw new Exception("Unsupported content block type for Claude: " ~ b.type);
		}
	}
	json ~= "]";
	return JSONFragment(json);
}

// ─── Protocol translation (moved from protocol.d) ────────────────────────

// ─── History translation (stateless — complete JSONL messages) ────────────

/// Route a raw Claude JSONL history line to the appropriate translator.
/// Returns zero or more agnostic event pairs.
private TranslatedEvent[] translateClaudeHistoryEvent(string rawLine)
{
	import cydo.protocol : parseIso8601Timestamp;

	@JSONPartial static struct TypeProbe { string type; string subtype; }
	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception e)
	{
		import cydo.protocol : makeUnrecognizedEvent;
		tracef("translateClaudeHistoryEvent: type probe parse error: %s", e.msg);
		return [TranslatedEvent(makeUnrecognizedEvent("history parse error: " ~ e.msg), rawLine)];
	}

	// Probe timestamp from the JSONL line (present on history lines).
	@JSONPartial static struct TimestampProbe { @JSONOptional string timestamp; }
	AbsTime ts;
	try { ts = parseIso8601Timestamp(jsonParse!TimestampProbe(rawLine).timestamp); }
	catch (Exception) {}

	TranslatedEvent[] result;
	switch (probe.type)
	{
		case "assistant":
			result = translateAssistantHistory(rawLine);
			break;
		case "user":
			result = normalizeUserHistory(rawLine);
			break;
		case "stream_event":
			return []; // not stored in JSONL history
		default:
			auto t = translateClaudeEvent(rawLine, "");
			result = t.translated !is null ? [t] : [];
			break;
	}
	foreach (ref ev; result)
		if (ev.ts == AbsTime.init)
			ev.ts = ts;
	return result;
}

unittest
{
	@JSONPartial static struct EventTypeProbe
	{
		string type;
	}

	auto translated = translateClaudeHistoryEvent("null");
	assert(translated.length == 1);
	assert(translated[0].translated != "null");
	assert(translated[0].translated.length > 0);
	assert(translated[0].raw == "null");

	auto ev = jsonParse!EventTypeProbe(translated[0].translated);
	assert(ev.type == "agent/unrecognized");
}

/// Claude Code assistant-message fields that CyDo does not use yet.
/// Listed so they are not reported as unknown agent data.
// TODO: evaluate and either consume or deliberately drop each of these.
private mixin template ClaudeAssistantUnhandledFields()
{
	// Live stream only
	@JSONOptional JSONFragment tool_use_meta;
	@JSONOptional JSONFragment thinking_duration_ms; // on single-thinking-block frames
	@JSONOptional string thinking_display;           // the display mode the request asked for
	@JSONOptional string user_message_uuid;
	@JSONOptional string[] user_message_uuids;
	@JSONOptional string agent_id;
	@JSONOptional string subagent_type;
	@JSONOptional string task_description;
	@JSONOptional string request_id;
	@JSONOptional JSONFragment wire_tool_inputs;
	// Session file only
	@JSONOptional string requestedModel;
	@JSONOptional string requestRef;
	@JSONOptional string promptCacheRequested;
	@JSONOptional JSONFragment apiBlockIndex;
	@JSONOptional string effort;
	@JSONOptional string perTurnEffort;
	@JSONOptional string advisorModel;
	@JSONOptional JSONFragment toolInputStreamMs;
	@JSONOptional string attributionAgent;
	@JSONOptional string attributionMcpServer;
	@JSONOptional string attributionMcpTool;
	@JSONOptional JSONFragment thinkingDisplay;
	@JSONOptional JSONFragment thinkingDurationMs;
	@JSONOptional JSONFragment wireToolInputs;
	@JSONOptional JSONFragment wireIngestContext;
	@JSONOptional JSONFragment serverClassifierRequest;
	@JSONOptional string sessionKind;
	@JSONOptional JSONFragment apiErrorCode;
	@JSONOptional JSONFragment apiErrorStatus;
	@JSONOptional JSONFragment error;

	// Deliberately dropped: on a fallback model's response, the messages of
	// the refused one it replaces. The model_refusal_fallback notice, which
	// precedes it, lists the same messages (turn/retracted).
	@JSONOptional string[] supersedes;       // live stream
	@JSONOptional string[] supersedesUuids;  // session file
}

/// Translate a Claude history assistant message to item/started+completed per block + turn/stop.
private TranslatedEvent[] translateAssistantHistory(string rawLine)
{
	import cydo.protocol : ItemStartedEvent, ItemCompletedEvent, TurnStopEvent,
		UsageInfo, decomposeToolName;

	static struct ClaudeThinkingBlock
	{
		string type;
		@JSONOptional string thinking;
		@JSONOptional string text;
		@JSONOptional string id;
		@JSONOptional string name;
		@JSONOptional JSONFragment input;
		@JSONOptional string signature;
		JSONExtras _extras;
	}
	static struct ClaudeMessage
	{
		string id;
		ClaudeThinkingBlock[] content;
		@JSONOptional string model;
		@JSONOptional JSONFragment usage;
		@JSONOptional string stop_reason;
		@JSONOptional string stop_sequence;
		@JSONOptional JSONFragment stop_details;
		@JSONOptional string type;   // always "message", not forwarded
		@JSONOptional string role;   // always "assistant", not forwarded
		@JSONOptional JSONFragment context_management;
		// TODO: not used yet
		@JSONOptional JSONFragment diagnostics;
		@JSONOptional JSONFragment container;
		@JSONOptional JSONFragment input_transformations;
		JSONExtras _extras;
	}
	static struct ClaudeAssistant
	{
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isApiErrorMessage;
		@JSONOptional string uuid;
		ClaudeMessage message;
		@JSONOptional string type;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		mixin ClaudeAssistantUnhandledFields;
		JSONExtras _extras;
	}

	ClaudeAssistant raw;
	try
		raw = jsonParse!ClaudeAssistant(rawLine);
	catch (Exception e)
	{ tracef("translateAssistantHistory: parse error: %s", e.msg); return []; }

	if (raw.isApiErrorMessage)
	{
		string errorText;
		foreach (ref b; raw.message.content)
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			if (text.length > 0) errorText ~= text;
		}
		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.error;
		ev.subject = "Agent error";
		ev.body = errorText;
		return [TranslatedEvent(toJson(ev), rawLine)];
	}

	TranslatedEvent[] events;

	foreach (idx, ref b; raw.message.content)
	{
		auto itemId = b.type == "tool_use" && b.id.length > 0
			? b.id : "cc-hist-" ~ to!string(idx);

		ItemStartedEvent startEv;
		startEv.item_id              = itemId;
		startEv.item_type            = b.type;
		startEv.parent_tool_use_id   = raw.parent_tool_use_id;
		startEv.is_sidechain         = raw.isSidechain;
		if (b.type == "tool_use")
		{
			decomposeToolName(b.name, startEv.name, startEv.tool_server, startEv.tool_source);
			startEv.input = b.input;
		}
		else
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			startEv.text = text;
		}
		events ~= TranslatedEvent(toJson(startEv), rawLine);

		ItemCompletedEvent compEv;
		compEv.item_id = itemId;
		if (b.type == "tool_use")
			compEv.input = b.input;
		else
		{
			auto text = b.type == "thinking" && b.thinking.length > 0 ? b.thinking : b.text;
			compEv.text = text;
		}
		compEv.extras = extrasToFragment(b._extras);
		events ~= TranslatedEvent(toJson(compEv), rawLine);
	}

	// Extract usage.
	UsageInfo usage;
	if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
	{
		@JSONPartial static struct UP { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
		try
		{
			auto u = jsonParse!UP(raw.message.usage.json);
			usage.input_tokens  = u.input_tokens;
			usage.output_tokens = u.output_tokens;
		}
		catch (Exception) {}
	}

	TurnStopEvent tsev;
	tsev.model             = raw.message.model;
	tsev.usage             = usage;
	tsev.parent_tool_use_id = raw.parent_tool_use_id;
	tsev.is_sidechain      = raw.isSidechain;
	tsev.uuid              = raw.uuid;
	tsev.extras = extrasToFragment(collectAllExtras(raw));
	events ~= TranslatedEvent(toJson(tsev), rawLine);

	return events;
}

/// Translate a Claude history user message to item/result + item/started events.
private TranslatedEvent[] normalizeUserHistory(string rawLine)
{
	import cydo.protocol : ContentBlock, ItemStartedEvent, ItemResultEvent;

	@JSONPartial static struct ClaudeUserMsg { JSONFragment content; }
	@JSONPartial static struct ClaudeUser
	{
		ClaudeUserMsg message;
		@JSONOptional bool isReplay;
		@JSONOptional bool isSynthetic;
		@JSONOptional bool isMeta;
		@JSONOptional bool isSteering;
		@JSONOptional bool pending;
		@JSONOptional string uuid;
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional JSONFragment toolUseResult;
		@JSONOptional JSONFragment tool_use_result;
	}

	ClaudeUser raw;
	try
		raw = jsonParse!ClaudeUser(rawLine);
	catch (Exception e)
	{ tracef("normalizeUserHistory: parse error: %s", e.msg); return []; }

	auto contentJson = raw.message.content.json;
	if (contentJson is null || contentJson.length == 0)
		return [];

	TranslatedEvent[] events;

	if (contentJson[0] == '"')
	{
		// String content → user_message item.
		string text;
		try text = jsonParse!string(contentJson);
		catch (Exception) {}

		ContentBlock cb;
		cb.type = "text";
		cb.text = text;

		ItemStartedEvent ev;
		ev.item_id     = "cc-user-msg";
		ev.item_type   = "user_message";
		ev.content     = [cb];
		ev.is_replay   = raw.isReplay;
		ev.is_synthetic = raw.isSynthetic;
		ev.is_meta     = raw.isMeta;
		ev.is_steering        = raw.isSteering;
		ev.pending            = raw.pending;
		ev.uuid               = raw.uuid;
		ev.parent_tool_use_id = raw.parent_tool_use_id;
		ev.is_sidechain       = raw.isSidechain;
		events ~= TranslatedEvent(toJson(ev), rawLine);
	}
	else if (contentJson[0] == '[')
	{
		@JSONPartial
		static struct ImageSource
		{
			@JSONOptional string data;
			@JSONOptional string media_type;
		}
		@JSONPartial
		static struct ContentItem
		{
			string type;
			@JSONOptional string tool_use_id;
			@JSONOptional JSONFragment content;
			@JSONOptional bool is_error;
			@JSONOptional string text;
			@JSONOptional ImageSource source;
		}
		ContentItem[] items;
		try items = jsonParse!(ContentItem[])(contentJson);
		catch (Exception e) { tracef("normalizeUserHistory: content parse error: %s", e.msg); return events; }

		// Collect user content blocks (text + image); emit tool_results separately.
		ContentBlock[] userBlocks;
		foreach (ref item; items)
		{
			if (item.type == "tool_result")
			{
				ItemResultEvent ev;
				ev.item_id  = item.tool_use_id;
				auto cj2 = item.content.json;
				if (cj2 is null || cj2.length == 0)
					ev.content = JSONFragment(`[{"type":"text","text":""}]`);
				else if (cj2[0] == '"')
					ev.content = JSONFragment(`[{"type":"text","text":` ~ cj2 ~ `}]`);
				else
					ev.content = item.content;
				ev.is_error = item.is_error;
				if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
					ev.tool_result = raw.toolUseResult;
				else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
					ev.tool_result = raw.tool_use_result;
				events ~= TranslatedEvent(toJson(ev), rawLine);
			}
			else if (item.type == "text")
			{
				ContentBlock cb;
				cb.type = "text";
				cb.text = item.text;
				userBlocks ~= cb;
			}
			else if (item.type == "image")
			{
				ContentBlock cb;
				cb.type       = "image";
				cb.data       = item.source.data;
				cb.media_type = item.source.media_type;
				userBlocks ~= cb;
			}
		}

		if (userBlocks.length > 0)
		{
			ItemStartedEvent ev;
			ev.item_id     = "cc-user-msg";
			ev.item_type   = "user_message";
			ev.content     = userBlocks;
			ev.is_replay   = raw.isReplay;
			ev.is_synthetic = raw.isSynthetic;
			ev.is_meta     = raw.isMeta;
			ev.is_steering        = raw.isSteering;
			ev.pending            = raw.pending;
			ev.uuid               = raw.uuid;
			ev.parent_tool_use_id = raw.parent_tool_use_id;
			ev.is_sidechain       = raw.isSidechain;
			events ~= TranslatedEvent(toJson(ev), rawLine);
		}
	}

	return events;
}

/// Translate a Claude stream-json event to the agent-agnostic protocol.
/// Returns TranslatedEvent.init for events that should be consumed (not forwarded).
private TranslatedEvent translateClaudeEvent(string rawLine, string agentName)
{
	auto translated = translateClaudeEventInner(rawLine, agentName);
	if (translated is null)
		return TranslatedEvent.init;
	return TranslatedEvent(translated, rawLine);
}

private string translateClaudeEventInner(string rawLine, string agentName)
{
	@JSONPartial
	static struct TypeProbe
	{
		string type;
		string subtype;
	}

	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception e)
	{
		tracef("translateEvent: type probe parse error: %s", e.msg);
		import cydo.protocol : makeUnrecognizedEvent;
		return makeUnrecognizedEvent("JSON parse error: " ~ e.msg);
	}

	switch (probe.type)
	{
		case "system":
			return translateSystemEvent(rawLine, probe.subtype, agentName);
		case "result":
			return normalizeTurnResult(rawLine);
		case "summary":
			return translateSummary(rawLine);
		case "cost-state": // session file only: no result rows there
			return translateCostState(rawLine);
		case "rate_limit_event":
			return translateRateLimitEvent(rawLine);
		case "control_response":
			return translateControlResponse(rawLine);
		case "stderr":
			return translateStderr(rawLine);
		case "exit":
			return translateExit(rawLine);
		case "queue-operation":
			return null; // consumed — handled by broadcastTask / stateful replay closure
		case "tool_progress":
			return null; // The frontend already shows the tool as running.
		case "progress":
		case "file-history-snapshot":
			return null; // not used by frontend
		// TODO: session file rows not used yet
		case "atis-latch":
		case "last-prompt":
		case "attachment":
		case "api-request":
		case "api-request-blob":
		case "api-request-shape":
		case "tools-used":
		case "mode":
		case "file-history-delta":
		case "session-owner":
		case "ai-title":
		case "permission-mode":
		case "agent-name":
		case "continued-in":
			return null;
		default:
			import cydo.protocol : makeUnrecognizedEvent;
			return makeUnrecognizedEvent("unknown event type: " ~ probe.type);
	}
}

unittest
{
	enum heartbeat = `{"type":"tool_progress","tool_use_id":"toolu_mock_00002-heartbeat-0",`
		~ `"tool_name":"mcp__cydo__Ask","parent_tool_use_id":"toolu_mock_00002",`
		~ `"elapsed_time_seconds":30,"heartbeat":true,"session_id":"s","uuid":"u"}`;
	assert(translateClaudeEvent(heartbeat, "claude") == TranslatedEvent.init);
}

/// Translate system events by mapping subtype to the agnostic type string.
private string translateSystemEvent(string rawLine, string subtype, string agentName)
{
	switch (subtype)
	{
		case "init":
			return translateSessionInit(rawLine, agentName);
		case "status":
			return translateSystemStatus(rawLine);
		case "compact_boundary":
			return translateCompactBoundary(rawLine);
		case "task_started":
			return normalizeTaskStarted(rawLine);
		case "task_notification":
			return normalizeTaskNotification(rawLine);
		case "api_retry":
			return translateApiRetry(rawLine);
		case "model_fallback":
			return translateModelSwitch(rawLine, "Model switched");
		case "model_refusal_fallback":
			return translateRefusalFallback(rawLine);
		case "model_refusal_no_fallback":
			return translateModelSwitch(rawLine, "Model refused");
		case "model_consent_fallback":
			return translateModelSwitch(rawLine, "Model switched");
		case "permission_denied":
			return translatePermissionDenied(rawLine);
		case "task_updated":
			return normalizeTaskUpdated(rawLine);
		// Consumed by the live session (ClaudeCodeSession.backgroundWork).
		case "background_tasks_changed":
			return null;
		// TODO: system events not used yet
		case "post_turn_summary":
		case "away_summary":
		case "permission_retry":
		case "informational":
			return null;
		default:
			return rawLine; // unknown subtypes pass through
	}
}

/// Normalize a Claude session/init event to the agnostic SessionInitEvent format.
/// Renames fields and drops Claude-specific fields.
private string translateSessionInit(string rawLine, string agentName)
{
	static struct ClaudeInit
	{
		string session_id;
		string model;
		string cwd;
		@JSONOptional string[] tools;
		@JSONOptional string claude_code_version;
		@JSONOptional string permissionMode;
		@JSONOptional string apiKeySource;
		@JSONOptional string fast_mode_state;
		@JSONOptional string[] skills;
		@JSONOptional JSONFragment[] mcp_servers;
		@JSONOptional JSONFragment[] agents;
		@JSONOptional JSONFragment[] plugins;
		@JSONOptional string agent;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeInit raw;
	try
		raw = jsonParse!ClaudeInit(rawLine);
	catch (Exception e)
	{ tracef("translateSystemInit: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("session/init parse error: " ~ e.msg); }

	SessionInitEvent ev;
	ev.session_id    = raw.session_id;
	ev.model         = raw.model;
	ev.cwd           = raw.cwd;
	ev.tools         = raw.tools;
	ev.agent_version = raw.claude_code_version;
	ev.permission_mode = raw.permissionMode;
	ev.agent         = raw.agent.length > 0 ? raw.agent : "claude";
	ev.agent_name    = agentName;
	ev.api_key_source  = raw.apiKeySource;
	ev.fast_mode_state = raw.fast_mode_state;
	ev.skills        = raw.skills;
	ev.mcp_servers   = raw.mcp_servers;
	ev.agents        = raw.agents;
	ev.plugins       = raw.plugins;
	ev.supports_file_revert = true;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Normalize a Claude result event to the agnostic TurnResultEvent format.
/// Renames modelUsage → model_usage, normalizes usage to input/output only,
/// drops uuid and session_id.
private string normalizeTurnResult(string rawLine)
{
	static struct ClaudeUsage
	{
		@JSONOptional int input_tokens;
		@JSONOptional int output_tokens;
		// Known Claude usage fields — listed so they are not captured as extras.
		@JSONOptional int cache_creation_input_tokens;
		@JSONOptional int cache_read_input_tokens;
		@JSONOptional JSONFragment server_tool_use;
		@JSONOptional string service_tier;
		@JSONOptional JSONFragment cache_creation;
		@JSONOptional string inference_geo;
		@JSONOptional JSONFragment iterations;
		@JSONOptional string speed;
		@JSONOptional JSONFragment output_tokens_details;
		@JSONOptional JSONFragment fallback_credit;
		JSONExtras _extras;
	}

	static struct ClaudeResult
	{
		string subtype;
		bool is_error;
		@JSONOptional string result;
		int num_turns;
		int duration_ms;
		@JSONOptional int duration_api_ms;
		double total_cost_usd;
		@JSONOptional ClaudeUsage usage;
		@JSONOptional ModelUsageInfo[string] modelUsage;
		@JSONOptional ModelUsageInfo[string] model_usage;
		@JSONOptional JSONFragment[] permission_denials;
		@JSONOptional string stop_reason;
		@JSONOptional string[] errors;
		@JSONOptional string terminal_reason;
		@JSONOptional bool stopped_by_permission_check;
		@JSONOptional string credential_expires_at;
		// TODO: Claude Code result fields not used yet
		@JSONOptional JSONFragment origin;
		@JSONOptional JSONFragment subagent_stats;
		@JSONOptional string user_message_uuid;
		@JSONOptional string[] user_message_uuids;
		@JSONOptional JSONFragment result_index;
		@JSONOptional JSONFragment queued_turn_count;
		@JSONOptional string fast_mode_state;
		@JSONOptional string fast_mode_disabled_reason;
		@JSONOptional JSONFragment model_usage_since_last_result;
		@JSONOptional JSONFragment safety_stops;
		@JSONOptional JSONFragment api_error_status;
		@JSONOptional JSONFragment ttft_ms;
		@JSONOptional JSONFragment ttft_stream_ms;
		@JSONOptional JSONFragment time_to_request_ms;
		@JSONOptional JSONFragment first_content_frame_ms;
		@JSONOptional JSONFragment first_request_input_tokens;
		@JSONOptional JSONFragment request_sent_wall_ms;
		@JSONOptional JSONFragment fallback_credit;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeResult raw;
	try
		raw = jsonParse!ClaudeResult(rawLine);
	catch (Exception e)
	{ tracef("translateResult: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("turn/result parse error: " ~ e.msg); }

	TurnResultEvent ev;
	ev.subtype            = raw.subtype;
	ev.is_error           = raw.is_error;
	ev.result             = raw.result;
	ev.num_turns          = raw.num_turns;
	ev.duration_ms        = raw.duration_ms;
	ev.duration_api_ms    = raw.duration_api_ms;
	ev.total_cost_usd     = raw.total_cost_usd;
	ev.usage              = UsageInfo(raw.usage.input_tokens, raw.usage.output_tokens);
	if (raw.modelUsage.length > 0)
		ev.model_usage = raw.modelUsage;
	else if (raw.model_usage.length > 0)
		ev.model_usage = raw.model_usage;
	ev.permission_denials = raw.permission_denials;
	ev.stop_reason        = raw.stop_reason;
	ev.errors             = raw.errors;
	ev.end_reason         = raw.stopped_by_permission_check
		? TurnEndReason.auto_mode_stopped
		: claudeTurnEndReason(raw.terminal_reason);
	ev.credential_expires_at = raw.credential_expires_at;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

unittest
{
	// A whole Claude Code 2.1.319 result: every field is known. (Collapsed
	// successful results would not show unknown extras in the UI.)
	enum line = `{"duration_api_ms":18,"stop_reason":"end_turn","session_id":"s","total_cost_usd":0.00034,"`
		~ `usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"out`
		~ `put_tokens":15,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_searc`
		~ `h_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemer`
		~ `al_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"s`
		~ `peed":"standard","fallback_credit":null},"modelUsage":{"claude-opus-5-5":{"inputTokens":10`
		~ `,"outputTokens":15,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequest`
		~ `s":0,"costUSD":0.00034,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":0`
		~ `,"cacheCreationEphemeral5mInputTokens":0,"cacheCreationEphemeral1hInputTokens":0,"canonica`
		~ `lModel":"claude-opus-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials`
		~ `":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sd`
		~ `k_opt_in_required","origin":{"kind":"human"},"subagent_stats":{"spawned":0,"requested":{"b`
		~ `ackground":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by`
		~ `_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused"`
		~ `:{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_err`
		~ `or":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"first-undo-k`
		~ `ept","ttft_ms":59,"type":"result","duration_ms":65,"uuid":"u","ttft_stream_ms":58,"time_to`
		~ `_request_ms":49,"first_content_frame_ms":58,"user_message_uuid":"m","user_message_uuids":[`
		~ `"m"],"request_sent_wall_ms":1795004930470,"first_request_input_tokens":10,"queued_turn_cou`
		~ `nt":0,"result_index":0,"model_usage_since_last_result":{"claude-opus-5-5":{"inputTokens":1`
		~ `0,"outputTokens":15,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchReques`
		~ `ts":0,"costUSD":0.00034,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":`
		~ `0,"cacheCreationEphemeral5mInputTokens":0,"cacheCreationEphemeral1hInputTokens":0,"canonic`
		~ `alModel":"claude-opus-5-5","provider":"firstParty","costBasis":"list"}}}`;
	import std.algorithm.searching : canFind;
	auto translated = normalizeTurnResult(line);
	assert(!translated.canFind(`"extras"`), translated);
}

/// Map Claude's `terminal_reason` (why its query loop ended).
private TurnEndReason claudeTurnEndReason(string terminalReason)
{
	switch (terminalReason)
	{
		case "completed":
			return TurnEndReason.completed;
		case "aborted_streaming":
		case "aborted_tools":
			return TurnEndReason.interrupted;
		case "hook_stopped":
		case "stop_hook_prevented":
			return TurnEndReason.hook_stopped;
		case "prompt_too_long":
		case "blocking_limit":
			return TurnEndReason.context_limit;
		case "max_turns":
			return TurnEndReason.max_turns;
		default: // older CLIs send none; the rest have no dedicated presentation
			return TurnEndReason.unspecified;
	}
}

unittest
{
	import std.algorithm.searching : canFind;

	auto translated = normalizeTurnResult(`{"type":"result","subtype":"error_during_execution",`
		~ `"is_error":true,"num_turns":1,"duration_ms":5,"total_cost_usd":0,`
		~ `"terminal_reason":"aborted_tools"}`);
	assert(translated.canFind(`"end_reason":"interrupted"`), translated);
	translated = normalizeTurnResult(`{"type":"result","subtype":"error_during_execution",`
		~ `"is_error":true,"num_turns":1,"duration_ms":5,"total_cost_usd":0,`
		~ `"terminal_reason":"tool_deferred","stopped_by_permission_check":true}`);
	assert(translated.canFind(`"end_reason":"auto_mode_stopped"`), translated);
}

/// Translate "summary" event to session/summary.
private string translateSummary(string rawLine)
{
	@JSONPartial static struct RawSummary { string summary; }
	try
	{
		auto raw = jsonParse!RawSummary(rawLine);
		SessionSummaryEvent ev;
		ev.summary = raw.summary;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateSummary: parse error: %s", e.msg); return makeUnrecognizedEvent("summary parse error: " ~ e.msg); }
}

/// Translate a session file's "cost-state" row to session/cost.
private string translateCostState(string rawLine)
{
	@JSONPartial static struct RawCostState { double totalCostUSD; }
	try
	{
		SessionCostEvent ev;
		ev.total_cost_usd = jsonParse!RawCostState(rawLine).totalCostUSD;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateCostState: parse error: %s", e.msg); return makeUnrecognizedEvent("cost-state parse error: " ~ e.msg); }
}

unittest
{
	assert(translateCostState(`{"type":"cost-state","sessionId":"s","totalCostUSD":1.5,"modelUsage":{}}`)
		== `{"type":"session/cost","total_cost_usd":1.5}`);
}

/// Translate "rate_limit_event" event to session/rate_limit.
private string translateRateLimitEvent(string rawLine)
{
	static struct ClaudeRawRateLimitInfo
	{
		@JSONOptional string status;
		@JSONOptional string rateLimitType;
		@JSONOptional double resetsAt;
		@JSONOptional double utilization;
		@JSONOptional string overageStatus;
		@JSONOptional double overageResetsAt;
		@JSONOptional string overageDisabledReason;
		@JSONOptional bool isUsingOverage;
		@JSONOptional double surpassedThreshold;
		JSONExtras _extras;
	}
	@JSONPartial static struct RawRateLimit { ClaudeRawRateLimitInfo rate_limit_info; }
	try
	{
		auto raw = jsonParse!RawRateLimit(rawLine);
		RateLimitInfo info;
		info.status = raw.rate_limit_info.status;
		info.rateLimitType = raw.rate_limit_info.rateLimitType;
		info.resetsAt = raw.rate_limit_info.resetsAt;
		info.utilization = raw.rate_limit_info.utilization;
		info.overageStatus = raw.rate_limit_info.overageStatus;
		info.overageResetsAt = raw.rate_limit_info.overageResetsAt;
		info.overageDisabledReason = raw.rate_limit_info.overageDisabledReason;
		info.isUsingOverage = raw.rate_limit_info.isUsingOverage;
		info.surpassedThreshold = raw.rate_limit_info.surpassedThreshold;
		info.extras = raw.rate_limit_info._extras;
		SessionRateLimitEvent ev;
		ev.rate_limit_info = info;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateRateLimitEvent: parse error: %s", e.msg); return makeUnrecognizedEvent("rate_limit_event parse error: " ~ e.msg); }
}

unittest
{
	@JSONPartial static struct RateLimitProbe
	{
		string type;
		RateLimitInfo rate_limit_info;
	}

	auto translated = translateRateLimitEvent(
		`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","resetsAt":1715702400,"utilization":0.42,"overageStatus":"allowed","overageResetsAt":1715800000,"overageDisabledReason":"unknown","isUsingOverage":false,"surpassedThreshold":0.25},"uuid":"123e4567-e89b-42d3-a456-426614174000","session_id":"123e4567-e89b-42d3-a456-426614174001"}`);
	auto ev = jsonParse!RateLimitProbe(translated);
	assert(ev.type == "session/rate_limit");
	assert(ev.rate_limit_info.status == "allowed_warning");
	assert(ev.rate_limit_info.rateLimitType == "five_hour");
	assert(ev.rate_limit_info.resetsAt == 1715702400);
	assert(ev.rate_limit_info.utilization == 0.42);
	assert(ev.rate_limit_info.overageStatus == "allowed");
	assert(ev.rate_limit_info.overageResetsAt == 1715800000);
	assert(ev.rate_limit_info.overageDisabledReason == "unknown");
	assert(ev.rate_limit_info.isUsingOverage == false);
	assert(ev.rate_limit_info.surpassedThreshold == 0.25);
}

/// Translate "control_response" event to control/response.
private string translateControlResponse(string rawLine)
{
	import cydo.protocol : ControlResponse;
	@JSONPartial static struct RawControlResponse { ControlResponse response; }
	try
	{
		auto raw = jsonParse!RawControlResponse(rawLine);
		ControlResponseEvent ev;
		ev.response = raw.response;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateControlResponse: parse error: %s", e.msg); return makeUnrecognizedEvent("control_response parse error: " ~ e.msg); }
}

/// Translate "stderr" event to process/stderr.
private string translateStderr(string rawLine)
{
	@JSONPartial static struct RawStderr { string text; }
	try
	{
		auto raw = jsonParse!RawStderr(rawLine);
		ProcessStderrEvent ev;
		ev.text = raw.text;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateStderr: parse error: %s", e.msg); return makeUnrecognizedEvent("stderr parse error: " ~ e.msg); }
}

/// Translate "exit" event to process/exit.
private string translateExit(string rawLine)
{
	@JSONPartial static struct RawExit { int code; @JSONOptional bool is_continuation; }
	try
	{
		auto raw = jsonParse!RawExit(rawLine);
		ProcessExitEvent ev;
		ev.code = raw.code;
		ev.is_continuation = raw.is_continuation;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateExit: parse error: %s", e.msg); return makeUnrecognizedEvent("exit parse error: " ~ e.msg); }
}

/// Translate "system/status" event to session/status.
private string translateSystemStatus(string rawLine)
{
	static struct RawStatus
	{
		@JSONOptional string status;
		@JSONOptional string permissionMode;
		JSONExtras _extras;
	}
	try
	{
		auto raw = jsonParse!RawStatus(rawLine);
		SessionStatusEvent ev;
		ev.status = raw.status;
		ev.permission_mode = raw.permissionMode;
		ev.extras = extrasToFragment(raw._extras);
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateSystemStatus: parse error: %s", e.msg); return makeUnrecognizedEvent("system/status parse error: " ~ e.msg); }
}

unittest
{
	import std.algorithm : canFind;

	@JSONPartial static struct StatusProbe
	{
		string type;
		@JSONOptional string status;
		@JSONOptional string permission_mode;
		@JSONOptional JSONFragment extras;
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":"compacting","permissionMode":"acceptEdits","foo":"bar"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status == "compacting");
		assert(ev.permission_mode == "acceptEdits");
		assert(ev.extras.json !is null);
		assert(ev.extras.json.canFind(`"foo":"bar"`));
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status.length == 0);
		assert(ev.permission_mode == "acceptEdits");
	}

	{
		auto translated = translateSystemStatus(
			`{"type":"system","subtype":"status","status":"future-status"}`);
		auto ev = jsonParse!StatusProbe(translated);
		assert(ev.type == "session/status");
		assert(ev.status == "future-status");
	}
}

/// Translate "system/permission_denied": the CLI refused a tool call
/// without asking anyone. The tool_result that follows carries the denial
/// to the conversation either way; item/denied says who refused it, where
/// that is not CyDo itself (a policy hook "deny") or a mode CyDo never sets.
private string translatePermissionDenied(string rawLine)
{
	import cydo.protocol : ItemDenier;

	@JSONPartial static struct RawDenial
	{
		string tool_use_id;
		@JSONOptional string decision_reason_type;
		@JSONOptional string decision_reason;
	}
	auto raw = jsonParse!RawDenial(rawLine);
	ItemDenier by;
	switch (raw.decision_reason_type)
	{
		case "classifier": by = ItemDenier.classifier; break;
		case "rule":       by = ItemDenier.settingsRule; break;
		case "asyncAgent": by = ItemDenier.backgroundAgent; break;
		default:           return null;
	}
	return toJson(ItemDeniedEvent("item/denied", raw.tool_use_id, by, raw.decision_reason));
}

unittest
{
	assert(translatePermissionDenied(`{"type":"system","subtype":"permission_denied","tool_name":"Bash",`
		~ `"tool_use_id":"toolu_1","decision_reason_type":"classifier","decision_reason":"risky",`
		~ `"message":"Permission for this action was denied"}`)
		== `{"type":"item/denied","item_id":"toolu_1","by":"classifier","reason":"risky"}`);
	assert(translatePermissionDenied(`{"type":"system","subtype":"permission_denied","tool_use_id":"toolu_2",`
		~ `"decision_reason_type":"rule"}`)
		== `{"type":"item/denied","item_id":"toolu_2","by":"settingsRule"}`);
	assert(translatePermissionDenied(`{"type":"system","subtype":"permission_denied","tool_use_id":"toolu_3",`
		~ `"decision_reason_type":"asyncAgent","decision_reason":"no prompt"}`)
		== `{"type":"item/denied","item_id":"toolu_3","by":"backgroundAgent","reason":"no prompt"}`);
	assert(translatePermissionDenied(`{"type":"system","subtype":"permission_denied","tool_use_id":"toolu_4",`
		~ `"decision_reason_type":"hook","decision_reason":"Permission denied by policy"}`) is null);
}

/// Translate a notice that the CLI swapped, or could not swap, the model
/// (overload, refusal, consent) into a warning. The CLI words it itself.
private string translateModelSwitch(string rawLine, string subject)
{
	@JSONPartial static struct RawNotice { string content; }
	try
	{
		import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;
		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.warning;
		ev.subject = subject;
		ev.body = jsonParse!RawNotice(rawLine).content;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateModelSwitch: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("model switch notice parse error: " ~ e.msg); }
}

unittest
{
	assert(translateClaudeEventInner(`{"type":"system","subtype":"model_fallback","trigger":"overloaded",`
		~ `"original_model":"a","fallback_model":"b","content":"Switched to b due to high demand for a",`
		~ `"uuid":"u","session_id":"s"}`, "claude")
		== `{"type":"cydo/task_diagnostic","severity":"warning","subject":"Model switched",`
		~ `"body":"Switched to b due to high demand for a"}`);
}

/// Translate a notice that the model refused and the turn went on with a
/// fallback model. The response it refused is withdrawn: turn/retracted
/// names it, where the CLI says which messages that was.
private string translateRefusalFallback(string rawLine)
{
	import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity, TurnRetractedEvent;

	@JSONPartial static struct RawNotice
	{
		string content;
		@JSONOptional string[] retracted_message_uuids; // stdout
		@JSONOptional string[] retractedMessageUuids;   // session file
	}
	auto raw = jsonParse!RawNotice(rawLine);
	auto notice = TaskDiagnosticEvent("cydo/task_diagnostic",
		TaskDiagnosticSeverity.warning, "Model refused; switched", raw.content);
	auto uuids = raw.retracted_message_uuids ~ raw.retractedMessageUuids;
	// Absent from older CLIs, and when nothing had been delivered yet.
	if (uuids.length == 0)
		return toJson(notice);
	return toJson(TurnRetractedEvent("turn/retracted", uuids, notice));
}

unittest
{
	enum line = `{"type":"system","subtype":"model_refusal_fallback","trigger":"refusal",`
		~ `"direction":"retry","original_model":"a","fallback_model":"b","content":"Refused; using b",`
		~ `"retracted_message_uuids":["u1","u2"],"uuid":"u","session_id":"s"}`;
	assert(translateClaudeEventInner(line, "claude")
		== `{"type":"turn/retracted","uuids":["u1","u2"],"notice":{"type":"cydo/task_diagnostic",`
		~ `"severity":"warning","subject":"Model refused; switched","body":"Refused; using b"}}`);
	assert(translateClaudeEventInner(`{"type":"system","subtype":"model_refusal_fallback",`
		~ `"content":"Refused; using b","retractedMessageUuids":["u1"]}`, "claude")
		== `{"type":"turn/retracted","uuids":["u1"],"notice":{"type":"cydo/task_diagnostic",`
		~ `"severity":"warning","subject":"Model refused; switched","body":"Refused; using b"}}`);
	assert(translateClaudeEventInner(`{"type":"system","subtype":"model_refusal_fallback",`
		~ `"content":"Refused; using b"}`, "claude")
		== `{"type":"cydo/task_diagnostic","severity":"warning","subject":"Model refused; switched",`
		~ `"body":"Refused; using b"}`);
}

/// Translate "system/api_retry" event to a retrying task diagnostic.
private string translateApiRetry(string rawLine)
{
	@JSONPartial static struct RawApiRetry
	{
		int attempt;
		int max_retries;
		@JSONOptional Nullable!int error_status;
		string error;
	}
	try
	{
		import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;
		auto raw = jsonParse!RawApiRetry(rawLine);
		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.warning;
		ev.subject = "Agent error (retrying)";
		if (raw.error_status.isNull)
			ev.body = format("API error: %s (attempt %d/%d)",
				raw.error, raw.attempt, raw.max_retries);
		else
			ev.body = format("API error: %d %s (attempt %d/%d)",
				raw.error_status.get, raw.error, raw.attempt, raw.max_retries);
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateApiRetry: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("api_retry parse error: " ~ e.msg); }
}

unittest
{
	import std.algorithm : canFind;

	@JSONPartial static struct ErrorProbe
	{
		string type;
		string severity;
		string subject;
		string body;
	}

	auto translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":8,"max_retries":10,"retry_delay_ms":39354.3,"error_status":529,"error":"rate_limit","session_id":"abc","uuid":"def"}`,
		"claude");
	auto ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: 529 rate_limit (attempt 8/10)");
	assert(!translated.canFind(`"willRetry"`));

	translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":538.56,"error_status":null,"error":"unknown","session_id":"abc","uuid":"def"}`,
		"claude");
	ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: unknown (attempt 1/10)");
	assert(!translated.canFind(`"willRetry"`));

	translated = translateClaudeEventInner(
		`{"type":"system","subtype":"api_retry","attempt":2,"max_retries":3,"retry_delay_ms":1000,"error":"timeout","session_id":"abc","uuid":"def"}`,
		"claude");
	ev = jsonParse!ErrorProbe(translated);
	assert(ev.type == "cydo/task_diagnostic");
	assert(ev.severity == "warning");
	assert(ev.subject == "Agent error (retrying)");
	assert(ev.body == "API error: timeout (attempt 2/3)");
	assert(!translated.canFind(`"willRetry"`));
}

/// Translate "system/compact_boundary" event to session/compacted.
private string translateCompactBoundary(string rawLine)
{
	@JSONPartial static struct RawCompact { @JSONOptional CompactMetadata compact_metadata; }
	try
	{
		auto raw = jsonParse!RawCompact(rawLine);
		SessionCompactedEvent ev;
		ev.compact_metadata = raw.compact_metadata;
		return toJson(ev);
	}
	catch (Exception e)
	{ tracef("translateCompactBoundary: parse error: %s", e.msg); return makeUnrecognizedEvent("system/compact_boundary parse error: " ~ e.msg); }
}

/// Recursively collect all JSONExtras from a struct and its nested struct fields.
/// Arrays are skipped (content blocks are handled per-element by the caller).
private JSONExtras collectAllExtras(S)(ref const S s)
{
	JSONExtras result;
	static foreach (i, field; S.tupleof)
	{{
		alias FT = typeof(field);
		static if (is(FT == JSONExtras))
		{
			if (s.tupleof[i]._data !is null)
				foreach (k, v; s.tupleof[i]._data)
					result[k] = v;
		}
		else static if (is(FT == struct) && !is(FT == JSONFragment))
		{
			auto nested = collectAllExtras(s.tupleof[i]);
			if (nested._data !is null)
				foreach (k, v; nested._data)
					result[k] = v;
		}
	}}
	return result;
}

/// Normalize a Claude task_started system event to the agnostic TaskStartedEvent format.
/// Drops uuid and session_id fields.
private string normalizeTaskStarted(string rawLine)
{
	static struct ClaudeTaskStarted
	{
		string task_id;
		@JSONOptional string tool_use_id;
		@JSONOptional string description;
		@JSONOptional string task_type;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeTaskStarted raw;
	try
		raw = jsonParse!ClaudeTaskStarted(rawLine);
	catch (Exception e)
	{ tracef("translateTaskStarted: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("task/started parse error: " ~ e.msg); }

	TaskStartedEvent ev;
	ev.task_id      = raw.task_id;
	ev.tool_use_id  = raw.tool_use_id;
	ev.description  = raw.description;
	ev.task_type    = raw.task_type;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// The live background tasks a `background_tasks_changed` event reports.
/// The event carries the whole set, replacing the previous one. Ambient
/// tasks (housekeeping, live-update watchers) are not activity: the CLI
/// asks hosts to leave them out of activity indicators.
private BackgroundWork[] parseLiveBackgroundTasks(string rawLine)
{
	import std.algorithm : filter, map;
	import std.array : array;

	@JSONPartial static struct BackgroundTask
	{
		string task_id;
		string description;
		@JSONOptional bool ambient;
	}
	@JSONPartial static struct BackgroundTasksChanged
	{
		BackgroundTask[] tasks;
	}

	return jsonParse!BackgroundTasksChanged(rawLine).tasks
		.filter!(t => !t.ambient)
		.map!(t => BackgroundWork(t.task_id, t.description))
		.array;
}

unittest
{
	assert(parseLiveBackgroundTasks(`{"type":"system","subtype":"background_tasks_changed","tasks":[`
		~ `{"task_id":"b1","run_id":"r","task_type":"local_bash","description":"Running command"}],`
		~ `"uuid":"u","session_id":"s"}`) == [BackgroundWork("b1", "Running command")]);
	assert(parseLiveBackgroundTasks(`{"type":"system","subtype":"background_tasks_changed","tasks":[`
		~ `{"task_id":"b1","task_type":"local_bash","description":"d","ambient":true}]}`) == []);
	assert(parseLiveBackgroundTasks(
		`{"type":"system","subtype":"background_tasks_changed","tasks":[]}`) == []);
}

/// Normalize a Claude task_updated event (a patch to one task's state).
private string normalizeTaskUpdated(string rawLine)
{
	static struct Patch
	{
		@JSONOptional string status;
		@JSONOptional string error;
		// TODO: not used yet
		@JSONOptional string description;
		@JSONOptional JSONFragment end_time;
		@JSONOptional JSONFragment total_paused_ms;
		@JSONOptional bool is_backgrounded;
		JSONExtras _extras;
	}
	static struct ClaudeTaskUpdated
	{
		string task_id;
		Patch patch;
		@JSONOptional string run_id;
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		JSONExtras _extras;
	}

	ClaudeTaskUpdated raw;
	try
		raw = jsonParse!ClaudeTaskUpdated(rawLine);
	catch (Exception e)
	{ tracef("normalizeTaskUpdated: parse error: %s", e.msg); return makeUnrecognizedEvent("task/updated parse error: " ~ e.msg); }

	TaskUpdatedEvent ev;
	ev.task_id = raw.task_id;
	ev.status  = raw.patch.status;
	ev.error   = raw.patch.error;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

unittest
{
	assert(translateClaudeEventInner(`{"type":"system","subtype":"task_updated","task_id":"a2",`
		~ `"run_id":"r","patch":{"status":"killed","end_time":1794341131907},"uuid":"u","session_id":"s"}`, "claude")
		== `{"type":"task/updated","task_id":"a2","status":"killed"}`);
}

/// Normalize a Claude task_notification system event to the agnostic TaskNotificationEvent format.
/// Drops uuid and session_id fields.
private string normalizeTaskNotification(string rawLine)
{
	static struct ClaudeTaskNotification
	{
		string task_id;
		string status;
		@JSONOptional string output_file;
		@JSONOptional string summary;
		// TODO: Claude Code JSONL metadata fields — not forwarded to the agnostic protocol
		@JSONOptional string type;
		@JSONOptional string subtype;
		@JSONOptional string uuid;
		@JSONOptional string session_id;
		@JSONOptional string sessionId;
		@JSONOptional string agentId;
		@JSONOptional string parentUuid;
		@JSONOptional string requestId;
		@JSONOptional string cwd;
		@JSONOptional string gitBranch;
		@JSONName("version") @JSONOptional string version_;
		@JSONOptional string userType;
		@JSONOptional string timestamp;
		@JSONOptional string slug;
		@JSONOptional string permissionMode;
		@JSONOptional string entrypoint;
		@JSONOptional JSONFragment diagnostics;
		JSONExtras _extras;
	}

	ClaudeTaskNotification raw;
	try
		raw = jsonParse!ClaudeTaskNotification(rawLine);
	catch (Exception e)
	{ tracef("translateTaskNotification: parse error: %s", e.msg); import cydo.protocol : makeUnrecognizedEvent; return makeUnrecognizedEvent("task/notification parse error: " ~ e.msg); }

	TaskNotificationEvent ev;
	ev.task_id     = raw.task_id;
	ev.status      = raw.status;
	ev.output_file = raw.output_file;
	ev.summary     = raw.summary;
	ev.extras = extrasToFragment(collectAllExtras(raw));
	return toJson(ev);
}

/// Find the index of the closing brace matching the opening brace at pos.
private int findMatchingBrace(string s, size_t pos)
{
	if (pos >= s.length || s[pos] != '{')
		return -1;

	int depth = 0;
	bool inString = false;
	bool escaped = false;

	foreach (i; pos .. s.length)
	{
		auto c = s[i];
		if (escaped)
		{
			escaped = false;
			continue;
		}
		if (c == '\\' && inString)
		{
			escaped = true;
			continue;
		}
		if (c == '"')
		{
			inString = !inString;
			continue;
		}
		if (inString)
			continue;
		if (c == '{')
			depth++;
		else if (c == '}')
		{
			depth--;
			if (depth == 0)
				return cast(int) i;
		}
	}
	return -1;
}

/// The Claude Code tools a CyDo session does not get, because each one
/// bypasses or duplicates something CyDo provides.
private string[] disallowedTools(bool allowNativeSubagents, bool allowScheduledWakeups)
{
	string[] tools = [
		// The task list; not TaskOutput and TaskStop, which read and stop
		// background work.
		"TaskCreate", "TaskGet", "TaskList", "TaskUpdate",
		// CyDo has its own modes and its own way to ask the user.
		"EnterPlanMode", "ExitPlanMode", "AskUserQuestion",
		// CyDo places each task in its checkout or worktree; an agent that
		// needs another worktree uses git.
		"EnterWorktree", "ExitWorktree",
	];
	// Claude Code's own sub-agents, and the tools that address them. CyDo
	// neither shows nor manages them; its task system takes their place.
	if (!allowNativeSubagents)
		tools ~= ["Task", "Workflow", "SendMessage", "ListAgents"];
	// A scheduled prompt starts a turn at a later time. Only a session the
	// user converses with stays around for that; a sub-task's process ends
	// with the turn that delivers its result.
	if (!allowScheduledWakeups)
		tools ~= ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"];
	return tools;
}

unittest
{
	import std.algorithm : canFind;

	auto subTask = disallowedTools(false, false);
	assert(subTask.canFind("Task") && subTask.canFind("SendMessage"));
	assert(subTask.canFind("CronCreate") && subTask.canFind("ScheduleWakeup"));
	assert(subTask.canFind("EnterWorktree"));

	auto interactive = disallowedTools(false, true);
	assert(interactive.canFind("Workflow") && !interactive.canFind("CronCreate"));

	auto nativeSubagents = disallowedTools(true, true);
	assert(!nativeSubagents.canFind("Task") && !nativeSubagents.canFind("SendMessage"));
	assert(nativeSubagents.canFind("TaskCreate") && nativeSubagents.canFind("ExitWorktree"));
}
