module cydo.task_session_runner;

import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.process : execute;
import std.string : strip;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.config : PathMode, SandboxConfig;
import cydo.sandbox : ProcessLaunch, prepareProcessLaunch, resolveSandbox;
import cydo.task : TaskData;
import cydo.task_type_catalog : TaskTypeCatalog;
import cydo.tasktype : TaskTypeDef, formatCreatableTaskTypes, formatHandoffs,
	isInteractive, formatSwitchModes, loadSystemPrompt;

package(cydo):

struct TaskSessionLaunch
{
	ProcessLaunch processLaunch;
	SessionConfig sessionConfig;
}

struct TaskSessionRunnerHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) effectiveCwd;
	string delegate(const TaskData* td) worktreePath;
	SandboxConfig delegate() globalSandbox;
	SandboxConfig delegate(string workspaceName) findWorkspaceSandbox;
	string delegate(string workspaceName) findWorkspaceRoot;
	string delegate(string workspaceName) findWorkspacePermissionPolicy;
	SandboxConfig delegate(string agentName) findAgentSandbox;
	string delegate(int tid) resolveSharedTmpPath;
	string delegate() mcpSocketPath;
	TaskTypeCatalog taskTypeCatalog;
}

class TaskSessionRunner
{
	private TaskSessionRunnerHost host_;

	this(TaskSessionRunnerHost host)
	{
		host_ = host;
	}

	TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, "Task must exist before preparing session launch");

		SessionConfig sessionConfig;
		if (typeDef !is null)
		{
			sessionConfig.model = taskAgent.resolveModelAlias(typeDef.model_class);
			if (taskAgent.supportsDeveloperPrompt)
				sessionConfig.appendSystemPrompt = loadSystemPrompt(*typeDef,
					host_.taskTypeCatalog.promptSearchPath(td.projectPath),
					host_.outputPath(td));
		}
		auto taskTypes = host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(taskTypes, td.taskType);
		sessionConfig.switchModes = formatSwitchModes(taskTypes, td.taskType);
		sessionConfig.handoffs = formatHandoffs(taskTypes, td.taskType);
		sessionConfig.mcpSocketPath = host_.mcpSocketPath();

		auto workDir = td.repoPath.length > 0 ? td.repoPath : null;

		auto tdDir = host_.taskDir(td);
		mkdirRecurse(tdDir);

		auto taskCwd = host_.effectiveCwd(td);
		auto chdir = taskCwd.length > 0 ? taskCwd : workDir;

		auto wsSandbox = host_.findWorkspaceSandbox(td.workspace);
		auto wsRoot = host_.findWorkspaceRoot(td.workspace);
		auto agentTypeSandbox = host_.findAgentSandbox(td.agentType);
		bool readOnly = typeDef !is null && typeDef.read_only;
		auto sandbox = resolveSandbox(host_.globalSandbox(), agentTypeSandbox, wsSandbox,
			taskAgent, workDir, wsRoot, readOnly);

		sandbox.paths[tdDir] = PathMode.rw;

		if (td.worktreeTid > 0 && !readOnly && workDir.length > 0)
		{
			sandbox.paths[workDir] = PathMode.ro;

			auto wtPath = host_.worktreePath(td);
			sandbox.paths[wtPath] = PathMode.rw;

			auto gitDirResult = execute(["git", "-C", wtPath, "rev-parse", "--git-dir"]);
			if (gitDirResult.status == 0)
			{
				auto gitDir = gitDirResult.output.strip.absolutePath(wtPath);
				sandbox.paths[gitDir] = PathMode.rw;
			}
			auto gitCommonResult = execute(["git", "-C", wtPath, "rev-parse", "--git-common-dir"]);
			if (gitCommonResult.status == 0)
			{
				auto gitCommonDir = gitCommonResult.output.strip.absolutePath(wtPath);
				sandbox.paths[gitCommonDir] = PathMode.rw;
			}
		}

		auto reachesWorktree = host_.taskTypeCatalog.reachesWorktreeFor(td.projectPath);
		if (workDir.length > 0 && td.taskType in reachesWorktree
			&& reachesWorktree[td.taskType])
		{
			auto gitDirResult = execute(["git", "-C", workDir, "rev-parse", "--git-dir"]);
			if (gitDirResult.status == 0)
			{
				auto gitDir = gitDirResult.output.strip.absolutePath(workDir);
				sandbox.paths[gitDir] = PathMode.always_rw;
			}
			auto gitCommonResult = execute(["git", "-C", workDir, "rev-parse", "--git-common-dir"]);
			if (gitCommonResult.status == 0)
			{
				auto gitCommonDir = gitCommonResult.output.strip.absolutePath(workDir);
				sandbox.paths[gitCommonDir] = PathMode.always_rw;
			}
		}

		auto mcpSocketPath = host_.mcpSocketPath();
		if (mcpSocketPath.length > 0)
			sandbox.paths[mcpSocketPath] = PathMode.ro;

		if (workDir.length > 0)
		{
			auto memoryDir = buildPath(workDir, ".cydo", "memory");
			mkdirRecurse(memoryDir);
			sandbox.paths[memoryDir] = PathMode.always_rw;
		}

		sandbox.sharedTmpPath = host_.resolveSharedTmpPath(tid);
		td.launch = prepareProcessLaunch(sandbox, chdir,
			taskAgent.executableName(sandbox.env));

		sessionConfig.workspace = td.workspace;
		sessionConfig.workDir = chdir !is null ? chdir : "";
		if (taskAgent.needsBash())
			sessionConfig.includeTools ~= "Bash";
		if (sessionConfig.creatableTaskTypes.length > 0)
			sessionConfig.includeTools ~= "Task";
		if (sessionConfig.switchModes.length > 0)
			sessionConfig.includeTools ~= "SwitchMode";
		if (sessionConfig.handoffs.length > 0)
			sessionConfig.includeTools ~= "Handoff";
		if (taskTypes.isInteractive(host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath),
			td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		sessionConfig.includeTools ~= "Ask";
		sessionConfig.includeTools ~= "Answer";
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		sessionConfig.permissionPolicy = host_.findWorkspacePermissionPolicy(td.workspace);
		sessionConfig.agentName = td.agentType;

		return TaskSessionLaunch(td.launch, sessionConfig);
	}
}
