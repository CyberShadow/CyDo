module cydo.workflow.workspace.task_path_resolver;

import std.algorithm : startsWith;
import std.exception : enforce;
import std.format : format;

import cydo.domain.tasks.model : TaskData, outputPathForTaskDir,
	resolveProjectRepoPath, resolveTaskDir, worktreePathForTaskDir;
import cydo.runtime.config : WorkspaceConfig;

package(cydo):

struct TaskPathResolverHost
{
	TaskData* delegate(int tid) getTask;
	WorkspaceConfig[] delegate() workspaces;
	string delegate() taskDirTemplate;
}

class TaskPathResolver
{
	private TaskPathResolverHost host_;

	this(TaskPathResolverHost host)
	{
		host_ = host;
	}

	string findWorkspaceRoot(string workspaceName)
	{
		foreach (ref ws; host_.workspaces())
			if (ws.name == workspaceName)
				return ws.root;
		return "";
	}

	string workspaceRootForTask(int tid, string workspace, string projectPath)
	{
		if (workspace.length > 0)
		{
			auto wsRoot = findWorkspaceRoot(workspace);
			if (wsRoot.length == 0)
				throw new Exception(format!"Cannot resolve task_dir for task %d: unknown workspace '%s'"(
					tid, workspace));
			return wsRoot;
		}

		string matchedRoot;
		if (projectPath.length > 0)
			foreach (ref ws; host_.workspaces())
				if (pathIsUnderRoot(projectPath, ws.root))
				{
					if (matchedRoot.length > 0 && matchedRoot != ws.root)
						throw new Exception(format!"Cannot resolve task_dir for task %d: project path '%s' matches multiple workspace roots ('%s' and '%s')"(
							tid, projectPath, matchedRoot, ws.root));
					matchedRoot = ws.root;
				}
		if (matchedRoot.length > 0)
			return matchedRoot;

		throw new Exception(format!"Cannot resolve task_dir for task %d: missing workspace_root"(tid));
	}

	string resolveTaskDirForTask(int tid, string workspace, string projectPath)
	{
		auto repoPath = resolveProjectRepoPath(projectPath);
		auto wsRoot = workspaceRootForTask(tid, workspace, projectPath);
		return resolveTaskDir(tid, workspace, wsRoot, projectPath, repoPath,
			host_.taskDirTemplate());
	}

	string taskDir(ref const TaskData td)
	{
		return resolveTaskDirForTask(td.tid, td.workspace, td.projectPath);
	}

	string taskDir(const TaskData* td)
	{
		enforce(td !is null, "TaskData pointer must not be null");
		return taskDir(*td);
	}

	string outputPath(ref const TaskData td)
	{
		return outputPathForTaskDir(taskDir(td));
	}

	string outputPath(const TaskData* td)
	{
		enforce(td !is null, "TaskData pointer must not be null");
		return outputPath(*td);
	}

	string tryTaskDir(ref const TaskData td)
	{
		try
			return taskDir(td);
		catch (Exception)
			return "";
	}

	string tryResolveTaskDir(int tid, string workspace, string projectPath)
	{
		try
			return resolveTaskDirForTask(tid, workspace, projectPath);
		catch (Exception)
			return "";
	}

	string worktreePath(const TaskData* td)
	{
		enforce(td !is null, "TaskData pointer must not be null");
		if (td.worktreeTid <= 0)
			return "";

		auto ownerTd = host_.getTask(td.worktreeTid);
		if (ownerTd is null)
			throw new Exception(format!"Task %d references missing worktree owner task %d"(
				td.tid, td.worktreeTid));
		return worktreePathForTaskDir(taskDir(ownerTd));
	}

	string effectiveCwd(const TaskData* td)
	{
		enforce(td !is null, "TaskData pointer must not be null");
		return td.effectiveCwd(worktreePath(td));
	}

private:
	static bool pathIsUnderRoot(string path, string root)
	{
		return root.length > 0 && (path == root || path.startsWith(root ~ "/"));
	}
}

version(unittest)
{
	private TaskData* getTaskFromMap(TaskData[int]* tasks, int tid)
	{
		auto td = tid in *tasks;
		return td is null ? null : &(*tasks)[tid];
	}
}

unittest
{
	TaskData[int] tasks;
	auto resolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int tid) => getTaskFromMap(&tasks, tid),
		workspaces: () => [
			WorkspaceConfig(name: "outer", root: "/tmp/cydo-path-resolver"),
			WorkspaceConfig(name: "inner", root: "/tmp/cydo-path-resolver/project"),
		],
		taskDirTemplate: () => "{{ workspace_root }}/.cydo/tasks/{{ tid }}",
	));

	try
	{
		resolver.resolveTaskDirForTask(7, "", "/tmp/cydo-path-resolver/project/repo");
		assert(false, "expected resolveTaskDirForTask to throw");
	}
	catch (Exception ex)
	{
		assert(ex.msg == "Cannot resolve task_dir for task 7: project path '/tmp/cydo-path-resolver/project/repo' matches multiple workspace roots ('/tmp/cydo-path-resolver' and '/tmp/cydo-path-resolver/project')");
	}
}
