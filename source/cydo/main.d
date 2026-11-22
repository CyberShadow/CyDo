module cydo.main;

import core.lifetime : move;

import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation;

import ae.utils.funopt : funopt, funoptDispatch, funoptDispatchUsage, FunOptConfig, Option, Parameter;
import ae.utils.main : main;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.websocket : WebSocketAdapter;
import ae.net.ssl.openssl;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.pidfile : createPidFile;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, resolve, reject;
import std.typecons : Nullable;
import ae.utils.promise.concurrency : threadAsync;
import ae.utils.statequeue : StateQueue;

mixin SSLUseLib;

import cydo.mcp : McpResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend, ValidatedTask;
import cydo.workflow.workspace.archive_manager : ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;
import cydo.workflow.batch.registry : BatchHandle, BatchRegistry;
import cydo.web.client_hub : ClientHub;
import cydo.runtime.config.watcher : ConfigWatcher, ConfigWatcherHost;
import cydo.workflow.discovery.service : DiscoveryService, DiscoveryServiceHost,
	DiscoveryTaskSnapshot, ImportableTaskSpec;
import cydo.cli.open_matching : findOpenProjectName, pathIsUnderRoot;
import cydo.web.snapshots : buildAgentsList, buildNoticesList,
	buildServerStatus, buildTaskEntry, buildTasksList, buildTaskTypesList,
	buildTaskTypesListForProject, buildWorkspacesList;
import cydo.workflow.history.pipeline : HistoryBroadcastPlan, HistoryEventPipeline,
	HistoryEventPipelineHost;
import cydo.workflow.history.abbrev : buildAbbreviatedHistoryFromStrings, extractMessageText;
import cydo.workflow.history.jsonl_edit : replaceUserMessageContent;
import cydo.runtime.logging : installRobustLogger;
import cydo.workflow.questions.router : makeQuestionMessage;
import cydo.domain.policy.permissions : evaluatePermissionPolicy, makePermissionAllowJson, makePermissionDenyJson;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.workflow.sessions.task_runner : TaskSessionLaunch, TaskSessionRunner,
	TaskSessionRunnerHost;
import cydo.web.transport : McpCallbacks, RawSourceLookupResult, RawSourceLookupStatus,
	TransportAdapter, WebSocketCallbacks;
import cydo.domain.usage.tracker : AgentUsageTracker;
import cydo.mcp.tool_descriptions : checkConfiguredToolDescriptions, mcpToolDescriptionMaxChars;

import cydo.agent.resolver : createConfiguredAgent, isConfiguredAgentName;
import cydo.agent.contract : Agent;
import cydo.protocol : AgentAckEnvelope, BatchResultEnvelope, ContentBlock,
	ItemStartedEvent, SessionRateLimitEvent, TaskEventEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, extractContentText;
import cydo.agent.session : AgentSession;
import cydo.agent.terminal : TerminalProcess;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, SandboxConfig, WorkspaceConfig;
import cydo.domain.storage.persistence : Persistence, openDatabase;
import cydo.runtime.launch.sandbox : cleanup, resolveExecutablePath, runtimeDir;
import cydo.domain.task_types.definition : TaskTypeConfig, TaskTypeDef, ContinuationDef,
	OutputType, WorktreeMode, byName, isInteractive, loadTaskTypes,
	renderPrompt, renderContinuationPrompt, substituteVars, loadSystemPrompt,
	loadProjectMemory, resolveAgent;
import cydo.foundation.system.framing : tryParseSystemFraming, tryExtractSubject,
	stripTaskSystemPromptWrapper, ParsedSystemFraming, CompiledTemplate, compileTemplate,
	tryMatchTemplate, validateTemplateSource;
import cydo.foundation.system.known_messages : KnownSystemMessageKind, KnownSystemMessageMatch,
	handoffSubject, modeSwitchSubject, sessionStartSubject,
	subTaskWaitingForAnswerSubject, systemMessagePrefix, systemMessageSubject,
	taskPromptSubject, tryKnownSystemMessageMatch, wrapKnownSystemMessage;
import cydo.domain.tasks.model;
import cydo.workflow.workspace.worktree;
import cydo.server.app : App, initLogger, applyConfiguredLogLevel;
import cydo.server.config_resolution : loadRuntimeConfig;
import cydo.runtime.shutdown : setupShutdownPipe;

private string resolveTaskTypesPath()
{
	import ae.utils.path : findProgramDirectory;
	import std.path : buildPath;
	auto dir = findProgramDirectory("defs/task-types.yaml");
	if (dir is null)
	{
		warningf("Could not locate defs/task-types.yaml relative to binary");
		return "defs/task-types.yaml";
	}
	return buildPath(dir, "defs/task-types.yaml");
}

@JSONPartial
private struct ReplayMeta
{
	@JSONOptional string agentName;
	@JSONOptional string agentType;
}

private string replayConfiguredAgentName(ReplayMeta meta, ref CydoConfig config)
{
	if (meta.agentName.length > 0)
		return meta.agentName;
	if (meta.agentType.length > 0)
		return meta.agentType;
	return config.default_agent;
}

unittest
{
	import configy.attributes : SetInfo;

	CydoConfig config;
	config.default_agent = "codex";
	AgentConfig workClaude;
	workClaude.driver = SetInfo!AgentDriver(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;

	assert(replayConfiguredAgentName(ReplayMeta(agentName: "work-claude"), config)
		== "work-claude");
	assert(replayConfiguredAgentName(ReplayMeta(agentType: "work-claude"), config)
		== "work-claude");
	assert(replayConfiguredAgentName(ReplayMeta.init, config) == "codex");

	auto agent = createConfiguredAgent(config,
		replayConfiguredAgentName(ReplayMeta(agentType: "work-claude"), config));
	assert(agent.driver == AgentDriver.claude);
}

@(`CyDo backend and tooling.`)
struct Program
{
static:
	@(`Start the CyDo backend.`)
	void server()
	{
		auto app = new App();
		app.start();

		// Install signal-safe SIGTERM/SIGINT handlers using a self-pipe.
		//
		// ae.net.shutdown (and ae.sys.shutdown) calls thread_suspendAll() inside
		// the signal handler to acquire the GC lock before invoking callbacks.
		// When SIGTERM fires while the main thread holds the GC lock (e.g. during
		// a GC allocation), thread_suspendAll() deadlocks and App.shutdown() is
		// never called, leaving the event loop hanging indefinitely.
		//
		// Instead we bypass that mechanism entirely: a raw POSIX signal handler
		// writes one byte to a pipe (write(2) is async-signal-safe), and a daemon
		// FileConnection on the read end calls app.shutdown() from inside the
		// event loop thread — no GC lock involved.
		setupShutdownPipe({ app.shutdown(); });

		socketManager.loop();
	}

	/// Run the MCP server.
	void mcpServer()
	{
		import cydo.mcp.server : runMcpServer;
		runMcpServer();
	}

	version (linux)
	{
		@(`Run a command as the main child of the sandbox init.`)
		void sandboxInit(immutable(string)[] command)
		{
			import cydo.runtime.launch.sandbox_init : runSandboxInit;
			runSandboxInit(command);
		}
	}

	@(`Simulate task type workflow.`)
	void simulate()
	{
		import cydo.cli.tasktype_tooling : runSimulator;
		auto config = loadRuntimeConfig();
		runSimulator(resolveTaskTypesPath(),
			(string name) => isConfiguredAgentName(config, name));
	}

	@(`Generate Graphviz dot output for task types.`)
	void dot()
	{
		import cydo.cli.tasktype_tooling : runDot;
		auto config = loadRuntimeConfig();
		runDot(resolveTaskTypesPath(),
			(string name) => isConfiguredAgentName(config, name));
	}

	@(`Dump agent context for a task type.`)
	void dumpContext(
		Parameter!(string, "Task type name.") typeName,
	)
	{
		import cydo.cli.tasktype_context : runDumpContext;
		auto config = loadRuntimeConfig();
		runDumpContext(resolveTaskTypesPath(), typeName,
			(string name) => isConfiguredAgentName(config, name));
	}

	@(`Check rendered MCP tool descriptions against the shared length policy.`)
	void checkToolDescriptions(
		Option!(size_t, "Maximum top-level tool description length in characters.") maxDescriptionChars = mcpToolDescriptionMaxChars,
	)
	{
		import core.stdc.stdlib : exit;
		import std.stdio : stderr, writeln;

		if (maxDescriptionChars > mcpToolDescriptionMaxChars)
		{
			stderr.writefln("Error: --max-description-chars may not exceed %s",
				mcpToolDescriptionMaxChars);
			exit(1);
		}

		auto taskTypesPath = resolveTaskTypesPath();
		TaskTypeConfig config;
		try
			config = loadTaskTypes(taskTypesPath);
		catch (Exception e)
		{
			stderr.writefln("Error loading %s: %s", taskTypesPath, e.msg);
			exit(1);
		}

		auto violations = checkConfiguredToolDescriptions(config, maxDescriptionChars);
		foreach (ref violation; violations)
			stderr.writefln("%s: %s description is %s chars (max %s)",
				violation.taskType, violation.toolName, violation.actualChars,
				violation.maxChars);
		if (violations.length > 0)
			exit(1);

		writeln("All rendered CyDo tool descriptions are within the limit.");
	}

	/// Discover projects in a workspace.
	void discover(
		Parameter!(string, "Workspace root path.") root,
		Parameter!(string, "Workspace name.") name,
		Parameter!(string, "is_project expression (djinja).") isProjectExpr,
		Parameter!(string, "recurse_when expression (djinja).") recurseWhenExpr,
		Parameter!(immutable(string)[], "Patterns to exclude.") exclude = null,
	)
	{
		import cydo.workflow.discovery.scanner : runDiscover;
		runDiscover(root, name, isProjectExpr, recurseWhenExpr, cast(string[]) exclude);
	}

	@(`Open CyDo in a browser.`)
	void open(
		Parameter!(string, "Path to open.") path = null,
	)
	{
		import cydo.runtime.config : ProjectDiscoveryConfig, loadConfig;
		import cydo.workflow.discovery.scanner : discoverProjects;
		import std.file : getcwd;
		import cydo.foundation.platform.path : canonicalProjectPath;
		import std.process : browse, environment, execute, spawnProcess;
		import std.string : replace, strip;

		auto config = loadConfig();

		// Determine target directory
		string targetDir = canonicalProjectPath(path.length > 0 ? path : getcwd());

		// Discover workspace and project for targetDir
		string workspace;
		string projectName;

		foreach (ref ws; config.workspaces)
		{
			auto wsRoot = ws.root;

			// Check if targetDir is under this workspace root
			if (!pathIsUnderRoot(targetDir, wsRoot))
				continue;

			// Run discovery for this workspace
			auto projects = discoverProjects(wsRoot, ws.name, ws.exclude, ws.project_discovery);

			// Find the project that contains targetDir (longest match)
			auto bestName = findOpenProjectName(targetDir, projects);

			if (bestName.length > 0)
			{
				workspace = ws.name;
				projectName = bestName;
				break;
			}

			// targetDir is under workspace but not a discovered project —
			// still use this workspace (will open at workspace level)
			workspace = ws.name;
			break;
		}

		// Build URL
		auto sslCert = environment.get("CYDO_TLS_CERT", null);
		auto proto = sslCert ? "https" : "http";
		auto listenAddr = environment.get("CYDO_LISTEN_ADDRESS", "localhost");
		if (listenAddr == "*") listenAddr = "localhost";
		auto listenPort = environment.get("CYDO_LISTEN_PORT", "3940");
		auto authUser = environment.get("CYDO_AUTH_USER", null);

		string hostPort = listenAddr ~ ":" ~ listenPort;

		// Build path portion: /{workspace}/{encoded-project}
		// Project names use : instead of / in URLs
		string urlPath = "/";
		if (workspace.length > 0)
		{
			urlPath = "/" ~ workspace ~ "/";
			if (projectName.length > 0)
				urlPath ~= projectName.replace("/", ":");
		}

		string url;
		if (authUser.length > 0)
			url = proto ~ "://" ~ authUser ~ "@" ~ hostPort ~ urlPath;
		else
			url = proto ~ "://" ~ hostPort ~ urlPath;

		// Try chromium --app mode first, fall back to browse()
		auto chromiumResult = execute(["which", "chromium"]);
		if (chromiumResult.status == 0)
		{
			auto chromiumPath = chromiumResult.output.strip();
			spawnProcess([chromiumPath, "--app=" ~ url]);
		}
		else
			browse(url);
	}

	@(`Replay suggestion generation from a debug dump directory.`)
	void replaySuggestions(
		Parameter!(string, "Path to suggestion debug dump directory.") dumpDir,
	)
	{
		import std.file : exists, readText;
		import std.path : buildPath;
		import std.string : strip, splitLines;
		import ae.utils.json : jsonParse;
		import cydo.agent.contract : Agent;
		import cydo.domain.task_types.definition : substituteVars;
		import cydo.runtime.launch.sandbox : prepareProcessLaunch;
		import cydo.runtime.launch.types : ProcessLaunch;
		import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
			resolveNativeHistoryContext;

		initLogger();
		auto config = loadRuntimeConfig();
		applyConfiguredLogLevel(config.log_level);

		// Verify required files exist
		auto metaPath = buildPath(dumpDir, "meta.json");
		auto contextPath = buildPath(dumpDir, "context.jsonl");
		if (!exists(metaPath))
		{
			stderr.writeln("Error: meta.json not found in ", dumpDir);
			import core.stdc.stdlib : exit;
			exit(1);
		}
		if (!exists(contextPath))
		{
			stderr.writeln("Error: context.jsonl not found in ", dumpDir);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Parse meta.json
		auto meta = jsonParse!ReplayMeta(readText(metaPath));

		// Parse context.jsonl — one envelope per non-empty line
		string[] envelopes;
		foreach (line; readText(contextPath).splitLines())
		{
			auto s = line.strip();
			if (s.length > 0)
				envelopes ~= s;
		}

		// Build abbreviated history and prompt
		auto history = buildAbbreviatedHistoryFromStrings(envelopes);
		stderr.writeln("=== Abbreviated Context ===");
		stderr.writeln(history);
		stderr.writeln("===========================");

		import ae.utils.path : findProgramDirectory;
		auto defsBase = () { auto d = findProgramDirectory("defs/task-types.yaml"); return d !is null ? d : ""; }();
		auto promptPath = buildPath(defsBase, "defs", "prompts/generate-suggestions.md");
		if (!exists(promptPath))
		{
			stderr.writeln("Error: prompt file not found: ", promptPath);
			import core.stdc.stdlib : exit;
			exit(1);
		}
		auto prompt = substituteVars(readText(promptPath), ["conversation": history]);

		auto selectedAgentName = replayConfiguredAgentName(meta, config);
		Agent agent;
		ProcessLaunch launch;
		try
		{
			agent = createConfiguredAgent(config, selectedAgentName);
			auto context = ConfiguredNativeHistoryContext(selectedAgentName, "", "", false);
			auto resolved = resolveNativeHistoryContext(config, agent, context);
			launch = prepareProcessLaunch(resolved.sandbox, resolved.rule,
				resolved.profile, "", agent.executableName(resolved.sandbox.env));
		}
		catch (Exception e)
		{
			stderr.writeln("Error: ", e.msg);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Run the one-shot and print result to stdout
		bool failed;
		try
		{
			auto handle = agent.completeOneShot(prompt, "small", launch);
			handle.promise.then((string result) {
				import std.stdio : writeln;
				if (result.length == 0)
					stderr.writeln("Warning: got empty response from agent");
				writeln(result);
			}).except((Exception e) {
				stderr.writeln("Error: ", e.msg);
				failed = true;
			}).finish({
				cleanup(launch.sandbox);
			}).ignoreResult();
		}
		catch (Exception e)
		{
			cleanup(launch.sandbox);
			stderr.writeln("Error: ", e.msg);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		socketManager.loop();

		if (failed)
		{
			import core.stdc.stdlib : exit;
			exit(1);
		}
	}

	@(`Export tasks as a self-contained HTML file.`)
	void exportHtml(
		Parameter!(int[], "Task IDs to export.") tids,
		Option!(string, "Output file path (default: export.html).") output = "export.html",
	)
	{
		import std.file : write;
		import std.format : format;
		import std.path : buildPath;

		import ae.utils.path : findProgramDirectory;

		import cydo.workflow.exporter.html : buildExportHtml, collectTaskTree, exportTaskData;
		import cydo.domain.storage.persistence : Persistence, openDatabase;

		if (tids.length == 0)
		{
			stderr.writeln("Error: at least one task ID is required");
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Open database
		Persistence persistence;
		try
			persistence = openDatabase();
		catch (Exception e)
		{
			stderr.writeln("Error: could not open database: ", e.msg);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Collect task tree
		auto taskRows = collectTaskTree(persistence, tids);
		if (taskRows.length == 0)
		{
			stderr.writeln("Error: no tasks found for the given IDs");
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Check for invalid TIDs
		bool[int] foundTids;
		foreach (ref t; taskRows)
			foundTids[t.tid] = true;
		foreach (tid; tids)
			if (tid !in foundTids)
				stderr.writeln("Warning: task ID ", tid, " not found in database");

		// Locate the export HTML template
		auto baseDir = findProgramDirectory("defs/task-types.yaml");
		if (baseDir is null)
		{
			stderr.writeln("Error: could not locate application directory");
			import core.stdc.stdlib : exit;
			exit(1);
		}
		auto templatePath = buildPath(baseDir, "web/dist-export/export.html");

		// Load task type definitions for icon info
		import cydo.domain.tasks.model : TypeInfoEntry;
		import cydo.domain.task_types.definition : loadTaskTypes;
		auto taskTypesPath = buildPath(baseDir, "defs/task-types.yaml");
		auto taskTypeConfig = loadTaskTypes(taskTypesPath);
		TypeInfoEntry[] typeInfo;
		foreach (ref def; taskTypeConfig.types)
			typeInfo ~= TypeInfoEntry(def.name, def.icon);

		// Export task data as JSON
		auto config = loadRuntimeConfig();
		auto allRows = persistence.loadTasks();
		TaskData[int] allTasks;
		foreach (ref row; allRows)
		{
			auto task = TaskData(row.tid, row.workspace, row.projectPath);
			task.agentName = row.agentName;
			task.agentSessionId = row.agentSessionId;
			task.worktreeTid = row.worktreeTid;
			allTasks[row.tid] = move(task);
		}
		import cydo.workflow.workspace.task_path_resolver : TaskPathResolver,
			TaskPathResolverHost;
		auto taskDirTemplate = config.task_dir.length > 0
			? config.task_dir : defaultTaskDirTemplate;
		auto taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
			getTask: (int tid) => tid in allTasks ? &allTasks[tid] : null,
			workspaces: () => config.workspaces,
			taskDirTemplate: () => taskDirTemplate,
		));
		string jsonData;
		try
			jsonData = exportTaskData(taskRows, config, &allTasks, taskPathResolver,
				typeInfo);
		catch (Exception e)
		{
			stderr.writeln("Error: ", e.msg);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Inject data and write output
		auto html = buildExportHtml(templatePath, jsonData);
		write(output, html);
		stderr.writeln(format!"Exported %d task(s) to %s"(taskRows.length, output));
	}
}

/// Self-pipe shutdown: installs signal handlers that write to a pipe; a
void usageFun(string usage)
{
	stderr.writeln(usage, funoptDispatchUsage!Program);
}

void dispatch(
	Parameter!(string, "Action to perform (see list below)") action = "server",
	immutable(string)[] actionArguments = null,
)
{
	funoptDispatch!Program([thisExePath, action] ~ actionArguments);
}

void run(string[] args)
{
	enum config = () { import std.getopt : config; FunOptConfig c; c.getoptConfig = [config.stopOnFirstNonOption]; return c; }();
	funopt!(dispatch, config, usageFun)(args);
}

mixin main!run;
