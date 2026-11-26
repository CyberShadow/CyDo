module cydo.runtime.launch.sandbox_resolver;

import std.algorithm : canFind, sort, startsWith;
import std.array : join;
import std.exception : enforce;
import std.file : exists, isSymlink, readLink;
import std.format : format;
import std.logger : warningf;
import std.path : dirName, expandTilde, isAbsolute, pathSplitter;
import std.process : environment, execute;
import std.string : lastIndexOf, strip;

import ae.sys.file : realPath;

import configy.attributes : SetInfo;

import cydo.runtime.config : GitIdentityConfig, PathMode, SandboxConfig;
import cydo.runtime.launch.sandbox_paths : PathAccess, PlannedSandboxMount,
	PlannedSandboxSymlink, SandboxMountPlan, SandboxPathOrigin, SandboxPathOriginKind,
	SandboxPaths, SandboxPathView;
import cydo.runtime.launch.types : AgentSandboxConfig, ResolvedSandbox;

/// Absolute path to the currently running cydo binary, resolved at
/// module init to avoid /proc/self/exe returning a "(deleted)" suffix
/// after the binary is replaced by a rebuild.
immutable string cydoBinaryPath;
shared static this()
{
	import std.file : thisExePath;
	cydoBinaryPath = thisExePath();
}

/// Get the directory containing the cydo binary.
string cydoBinaryDir()
{
	auto path = cydoBinaryPath;
	return path.length > 0 ? dirName(path) : "";
}

/// Resolve declarations in built-in, global, configured-agent, and workspace
/// order before applying task read-only and agent requirements.
ResolvedSandbox resolveSandbox(SandboxConfig global, SandboxConfig agentTypeConfig,
	SandboxConfig workspace, AgentSandboxConfig agent, string projectDir,
	string wsRoot = "",
	bool readOnly = false)
{
	ResolvedSandbox result;

	// Built-in declarations are deliberately first so every selected config
	// layer can replace the same normalized path.
	if (wsRoot.length > 0)
		result.paths.set(wsRoot, PathMode.ro,
			SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
				"workspace-root", "workspace root default"));

	if (projectDir.length > 0)
		result.paths.set(projectDir, PathMode.rw,
			SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
				"project", "project default"));

	result.paths.applyConfigLayer(global.paths,
		SandboxPathOrigin(SandboxPathOriginKind.globalConfig, "global", "sandbox.paths"));
	result.paths.applyConfigLayer(agentTypeConfig.paths,
		SandboxPathOrigin(SandboxPathOriginKind.agentConfig, agent.agentName,
			"sandbox.paths"));
	result.paths.applyConfigLayer(workspace.paths,
		SandboxPathOrigin(SandboxPathOriginKind.workspaceConfig, agent.workspaceName,
			"sandbox.paths"));

	if (readOnly)
		result.paths.applyTaskReadOnly(SandboxPathOrigin(
			SandboxPathOriginKind.taskReadOnly, "task", "task read-only"));

	// Merge env: global, then per-agent, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, agentTypeConfig.env);
	mergeEnv(result.env, workspace.env);

	// Agent requirements run after declarations and task read-only processing.
	// Agent sandbox setup sees the merged config env so binary/path resolution
	// can honor sandbox.env overrides such as PATH.
	agent.configureSandbox(result.paths, result.env);
	requireCydoBinary(result.paths);

	renderResolvedEnv(result.env);
	resolveGitIdentity(result, agent.gitName, agent.gitEmail,
		global.git, agentTypeConfig.git, workspace.git);
	resolveIsolationFlags(result, global, agentTypeConfig, workspace);

	return result;
}

/// Resolve sandbox for project discovery without an agent layer.
ResolvedSandbox resolveSandboxForDiscovery(SandboxConfig global, SandboxConfig workspace,
	string wsRoot, string workspaceName)
{
	ResolvedSandbox result;

	if (wsRoot.length > 0)
		result.paths.set(wsRoot, PathMode.ro,
			SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
				"workspace-root", "discovery workspace root default"));

	result.paths.applyConfigLayer(global.paths,
		SandboxPathOrigin(SandboxPathOriginKind.globalConfig, "global", "sandbox.paths"));
	result.paths.applyConfigLayer(workspace.paths,
		SandboxPathOrigin(SandboxPathOriginKind.workspaceConfig, workspaceName,
			"sandbox.paths"));

	requireCydoBinary(result.paths);

	result.paths.applyDiscoveryReadOnly(SandboxPathOrigin(
		SandboxPathOriginKind.discoveryReadOnly, "discovery", "terminal read-only"));

	// Merge env: global, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, workspace.env);
	renderResolvedEnv(result.env);
	resolveIsolationFlags(result, global, workspace);

	return result;
}

private void requireCydoBinary(ref SandboxPaths paths)
{
	paths.requireReadVisible(cydoBinaryDir(),
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, "sandbox",
			"CyDo binary directory"));
}

/// Grant both real Git metadata directories with joined exact access.
void grantGitMetadata(ref SandboxPaths paths, string checkoutPath, PathAccess access,
	SandboxPathOrigin baseOrigin)
{
	foreach (flag; ["--git-dir", "--git-common-dir"])
	{
		auto result = execute(["git", "-C", checkoutPath, "rev-parse",
			"--path-format=absolute", flag]);
		auto metadataPath = result.output.strip;
		enforce(result.status == 0 && metadataPath.length > 0 && isAbsolute(metadataPath),
			"Failed to resolve Git metadata " ~ flag ~ " for " ~ checkoutPath
			~ ": " ~ result.output);
		auto origin = baseOrigin;
		origin.detail = origin.detail.length > 0 ? origin.detail ~ " " ~ flag : flag;
		paths.require(metadataPath, access, origin);
	}
}

/// Resolve the namespace policy for server helpers, which have no workspace or agent.
bool globalUsesBwrap(SandboxConfig global)
{
	ResolvedSandbox resolved;
	resolveIsolationFlags(resolved, global, SandboxConfig.init);
	return resolved.useBwrap;
}

private:

/// Produce mounts from a detached logical snapshot without changing the
/// registry, together with the renderer's built-in mounts and symlinks.
///
/// Every mount is placed at the physical (fully symlink-resolved) host path
/// of its logical spelling, and each host symlink a spelling traverses is
/// recreated unless a host-content mount already exposes it. The sandbox
/// therefore resolves both the logical spelling and the physical path the
/// way the host does, which is what host tools recording canonical paths
/// (e.g. Git worktree backlinks) rely on.
///
/// Built-in mounts are lowered after the registry: a registry path planned
/// at the same destination replaces the built-in mount there.
public SandboxMountPlan planMounts(
	const ref SandboxPaths paths,
	const PathMode[string] builtinHostMounts,
	const PlannedSandboxSymlink[] builtinSymlinks)
{
	string[string] symlinkTargets;
	void recordSymlink(PlannedSandboxSymlink symlink)
	{
		if (auto target = symlink.location in symlinkTargets)
		{
			enforce(*target == symlink.target,
				format("sandbox symlink %s planned with conflicting targets %s and %s",
					symlink.location, *target, symlink.target));
			return;
		}
		symlinkTargets[symlink.location] = symlink.target;
	}
	foreach (symlink; builtinSymlinks)
		recordSymlink(symlink);

	SandboxMountPlan plan;
	string[] firstLogicalPaths;
	size_t[string] destinationIndexes;
	foreach (view; paths.snapshot)
	{
		if (!exists(view.path))
		{
			warningf("sandbox: skipping non-existent path: %s", view.path);
			continue;
		}

		auto destination = resolvePhysicalPath(view.path, &recordSymlink);
		auto source = isHostContent(view.effectiveMode) ? destination : "";
		auto origins = viewOrigins(view);
		if (auto index = destination in destinationIndexes)
		{
			ref existing = plan.mounts[*index];
			enforce(existing.source == source && existing.mode == view.effectiveMode,
				format("sandbox mount planning ambiguity at destination %s: "
					~ "logical paths %s (%s; origins %s) and %s (%s; origins %s) "
					~ "produce incompatible mounts (sources %s and %s)",
					existing.destination, firstLogicalPaths[*index], existing.mode,
					describeOrigins(existing.origins), view.path, view.effectiveMode,
					describeOrigins(origins), existing.source, source));
			existing.origins ~= origins;
			continue;
		}

		destinationIndexes[destination] = plan.mounts.length;
		firstLogicalPaths ~= view.path;
		plan.mounts ~= PlannedSandboxMount(source, destination, view.effectiveMode,
			origins);
	}

	foreach (hostPath, mode; builtinHostMounts)
	{
		assert(isHostContent(mode), "built-in sandbox mounts carry host content");
		auto destination = resolvePhysicalPath(hostPath, &recordSymlink);
		if (destination in destinationIndexes)
			continue;
		destinationIndexes[destination] = plan.mounts.length;
		firstLogicalPaths ~= hostPath;
		plan.mounts ~= PlannedSandboxMount(destination, destination, mode,
			[SandboxPathOrigin(SandboxPathOriginKind.builtinDefault, "renderer",
				hostPath)]);
	}

	foreach (ref mount; plan.mounts)
		sortAndDeduplicateOrigins(mount.origins);
	plan.mounts.sort!((left, right) => left.destination.length != right.destination.length
		? left.destination.length < right.destination.length
		: left.destination < right.destination);

	foreach (location, target; symlinkTargets)
		if (!isExposedByHostMount(plan.mounts, location))
			plan.symlinks ~= PlannedSandboxSymlink(location, target);
	plan.symlinks.sort!((left, right) => left.location < right.location);
	return plan;
}

/// Resolve `logical` the way the host kernel does, reporting each symlink
/// traversed at its physical location. The result contains no symlinks.
string resolvePhysicalPath(string logical,
	scope void delegate(PlannedSandboxSymlink) onSymlink)
{
	// Terminates: mirrors the host resolution of `logical`, whose full
	// resolvability the caller proved with exists().
	string current; // physical path so far; "" is the root
	auto remaining = pathComponents(logical);
	while (remaining.length)
	{
		auto component = remaining[0];
		remaining = remaining[1 .. $];
		if (component == ".")
			continue;
		if (component == "..")
		{
			auto slash = current.lastIndexOf('/');
			current = slash <= 0 ? "" : current[0 .. slash];
			continue;
		}
		auto candidate = current ~ "/" ~ component;
		if (isSymlink(candidate))
		{
			auto target = readLink(candidate);
			onSymlink(PlannedSandboxSymlink(candidate, target));
			remaining = pathComponents(target) ~ remaining;
			if (target.startsWith("/"))
				current = "";
		}
		else
			current = candidate;
	}
	return current.length > 0 ? current : "/";
}

/// Whether the topmost mount containing `location` already shows the host
/// symlink there. `mounts` is sorted parents-first, and every mount
/// containing `location` is one of its ancestors, so the last match is the
/// topmost.
private bool isExposedByHostMount(const PlannedSandboxMount[] mounts, string location)
{
	const(PlannedSandboxMount)* topmost;
	foreach (ref mount; mounts)
		if (isStrictlyInside(location, mount.destination))
			topmost = &mount;
	if (topmost is null)
		return false;
	final switch (topmost.mode)
	{
		case PathMode.ro:
		case PathMode.rw:
		case PathMode.always_rw:
			return true;
		case PathMode.tmpfs:
			return false;
		case PathMode.empty_dir:
		case PathMode.empty_file:
			throw new Exception(format("sandbox symlink %s cannot be recreated "
				~ "inside %s mount %s (origins %s)", location, topmost.mode,
				topmost.destination, describeOrigins(topmost.origins)));
	}
}

private bool isHostContent(PathMode mode)
{
	return mode == PathMode.ro || mode == PathMode.rw
		|| mode == PathMode.always_rw;
}

package(cydo.runtime.launch) bool isStrictlyInside(string path, string ancestor)
{
	return ancestor == "/"
		? path != "/" && path.startsWith("/")
		: path.startsWith(ancestor ~ "/");
}

private SandboxPathOrigin[] viewOrigins(const ref SandboxPathView view)
{
	SandboxPathOrigin[] origins;
	if (!view.declaration.isNull)
		origins ~= view.declaration.get.origin;
	if (!view.requirement.isNull)
		origins ~= view.requirement.get.origin;
	if (!view.taskReadOnlyBy.isNull)
		origins ~= view.taskReadOnlyBy.get;
	if (!view.finalReadOnlyBy.isNull)
		origins ~= view.finalReadOnlyBy.get;
	return origins;
}

private void sortAndDeduplicateOrigins(ref SandboxPathOrigin[] origins)
{
	origins.sort!originLess;
	size_t retained;
	foreach (origin; origins)
		if (retained == 0 || !sameOrigin(origins[retained - 1], origin))
			origins[retained++] = origin;
	origins.length = retained;
}

private bool originLess(SandboxPathOrigin left, SandboxPathOrigin right)
{
	if (left.kind != right.kind)
		return cast(int) left.kind < cast(int) right.kind;
	if (left.scope_ != right.scope_)
		return left.scope_ < right.scope_;
	return left.detail < right.detail;
}

private bool sameOrigin(SandboxPathOrigin left, SandboxPathOrigin right)
{
	return left.kind == right.kind && left.scope_ == right.scope_
		&& left.detail == right.detail;
}

private string describeOrigins(const SandboxPathOrigin[] origins)
{
	string[] descriptions;
	foreach (origin; origins)
		descriptions ~= format("%s(scope=%s, detail=%s)", origin.kind,
			origin.scope_, origin.detail);
	return "[" ~ descriptions.join(", ") ~ "]";
}

string[] pathComponents(string path)
{
	string[] result;
	foreach (component; path.pathSplitter)
		if (component != "/")
			result ~= component;
	return result;
}

void renderResolvedEnv(ref string[string] env)
{
	auto hostEnv = environment.toAA();
	auto home = environment.get("HOME", "");
	string[string] expandedEnv;
	foreach (k, v; env)
		expandedEnv[k] = expandAllTildes(renderSandboxEnvValue(v, hostEnv), home);
	env = expandedEnv;
}

void resolveGitIdentity(ref ResolvedSandbox result, string agentGitName, string agentGitEmail,
	GitIdentityConfig globalGit, GitIdentityConfig agentTypeGit,
	GitIdentityConfig workspaceGit)
{
	result.gitName = agentGitName;
	result.gitEmail = agentGitEmail;
	if (globalGit.name.length > 0)
		result.gitName = globalGit.name;
	if (globalGit.email.length > 0)
		result.gitEmail = globalGit.email;
	if (agentTypeGit.name.length > 0)
		result.gitName = agentTypeGit.name;
	if (agentTypeGit.email.length > 0)
		result.gitEmail = agentTypeGit.email;
	if (workspaceGit.name.length > 0)
		result.gitName = workspaceGit.name;
	if (workspaceGit.email.length > 0)
		result.gitEmail = workspaceGit.email;
}

void resolveIsolationFlags(ref ResolvedSandbox result, SandboxConfig global,
	SandboxConfig agentTypeConfig, SandboxConfig workspace)
{
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, agentTypeConfig.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, agentTypeConfig.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, agentTypeConfig.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);
}

void resolveIsolationFlags(ref ResolvedSandbox result, SandboxConfig global,
	SandboxConfig workspace)
{
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);
}

/// Override dest with source value if source was explicitly set in config.
void overrideBool(ref bool dest, SetInfo!bool source)
{
	if (source.set)
		dest = source.value;
}

/// Replace all occurrences of ~ with the home directory.
/// Handles ~/path at the start, and :~/path in PATH-like variables.
string expandAllTildes(string value, string home)
{
	import std.array : replace;
	if (home.length == 0)
		return value;
	return value.replace("~/", home ~ "/");
}

string renderSandboxEnvValue(string raw, const string[string] hostEnv)
{
	if (raw.length == 0 || !raw.canFind("{{"))
		return raw;

	import djinja.djinja : loadData;
	import djinja.render : Render;
	import uninode.node : UniNode;

	UniNode[string] envMap;
	foreach (k, v; hostEnv)
		envMap[k] = UniNode(v);

	UniNode[string] data;
	data["env"] = UniNode(envMap);

	try
	{
		auto tmpl = loadData(raw);
		return (new Render(tmpl)).render(UniNode(data));
	}
	catch (Exception e)
	{
		warningf("sandbox.env: failed to render template %s: %s", raw, e.msg);
		return "";
	}
}

/// Merge source env into destination (source wins on conflicts).
void mergeEnv(ref string[string] dest, string[string] source)
{
	if (source is null)
		return;
	foreach (k, v; source)
		dest[k] = v;
}

unittest
{
	import ae.sys.file : realPath;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-ws-root");
	auto wsRoot = buildPath(root, "workspace");
	auto wsLink = buildPath(root, "workspace-link");
	auto projectDir = buildPath(wsRoot, "project");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	mkdirRecurse(projectDir);
	symlink(wsRoot, wsLink);

	SandboxConfig workspace;
	// Config preserves its written spelling, while task defaults use the
	// canonical workspace/project identities.
	workspace.paths = [wsLink : PathMode.tmpfs];

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};
	agent.agentName = "test-agent";
	agent.workspaceName = "test-workspace";
	auto taskSandbox = resolveSandbox(SandboxConfig.init, SandboxConfig.init,
		workspace, agent, projectDir, wsRoot);
	assert(taskSandbox.paths.exact(wsRoot).get.effectiveMode == PathMode.ro);
	assert(taskSandbox.paths.exact(projectDir).get.effectiveMode == PathMode.rw);
	assert(taskSandbox.paths.exact(wsLink).get.effectiveMode == PathMode.tmpfs);

	auto discoverySandbox = resolveSandboxForDiscovery(SandboxConfig.init,
		workspace, wsRoot, "test-workspace");
	// Discovery uses the canonical workspace root (ro) while the configured
	// symlink spelling keeps its written mode.
	assert(discoverySandbox.paths.exact(wsRoot).get.effectiveMode == PathMode.ro);
	assert(discoverySandbox.paths.exact(wsLink).get.effectiveMode == PathMode.tmpfs);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-sandbox-agent-config");
	auto wsRoot = buildPath(root, "workspace");
	auto projectDir = buildPath(wsRoot, "project");
	auto globalDir = buildPath(root, "global");
	auto agentTypeDir = buildPath(root, "agent-type");
	auto workspaceDir = buildPath(root, "workspace-layer");
	auto agentStateDir = buildPath(root, "agent-state");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	foreach (path; [projectDir, globalDir, agentTypeDir, workspaceDir, agentStateDir])
		mkdirRecurse(path);

	SandboxConfig global;
	global.paths[globalDir] = PathMode.rw;
	global.env["GLOBAL_ONLY"] = "global";
	global.env["MERGED"] = "global";
	global.git.name = "Global Name";
	global.git.email = "global@example.com";

	SandboxConfig agentTypeConfig;
	agentTypeConfig.paths[agentTypeDir] = PathMode.rw;
	agentTypeConfig.env["AGENT_ONLY"] = "agent";
	agentTypeConfig.env["MERGED"] = "agent";
	agentTypeConfig.git.name = "Agent Type Name";

	SandboxConfig workspace;
	workspace.paths[workspaceDir] = PathMode.rw;
	workspace.env["WORKSPACE_ONLY"] = "workspace";
	workspace.env["MERGED"] = "workspace";
	workspace.git.email = "workspace@example.com";

	bool configureCalled;
	AgentSandboxConfig agent;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		configureCalled = true;
		assert(env["GLOBAL_ONLY"] == "global");
		assert(env["AGENT_ONLY"] == "agent");
		assert(env["WORKSPACE_ONLY"] == "workspace");
		assert(env["MERGED"] == "workspace");
		assert(paths.exact(wsRoot).get.effectiveMode == PathMode.ro);
		assert(paths.exact(projectDir).get.effectiveMode == PathMode.ro);
		assert(paths.exact(globalDir).get.effectiveMode == PathMode.ro);
		assert(paths.exact(agentTypeDir).get.effectiveMode == PathMode.ro);
		assert(paths.exact(workspaceDir).get.effectiveMode == PathMode.ro);
		paths.require(agentStateDir, PathAccess.rw,
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "test-agent",
				"agent state"));
		env["AGENT_ADDED"] = "present";
	};
	agent.gitName = "Agent Default Name";
	agent.gitEmail = "agent@example.com";
	agent.agentName = "test-agent";
	agent.workspaceName = "test-workspace";

	auto resolved = resolveSandbox(global, agentTypeConfig, workspace, agent,
		projectDir, wsRoot, true);
	assert(configureCalled);
	assert(resolved.paths.exact(wsRoot).get.effectiveMode == PathMode.ro);
	assert(resolved.paths.exact(projectDir).get.effectiveMode == PathMode.ro);
	assert(resolved.paths.exact(globalDir).get.effectiveMode == PathMode.ro);
	assert(resolved.paths.exact(agentTypeDir).get.effectiveMode == PathMode.ro);
	assert(resolved.paths.exact(workspaceDir).get.effectiveMode == PathMode.ro);
	assert(resolved.paths.exact(agentStateDir).get.effectiveMode == PathMode.rw);
	assert(resolved.env["AGENT_ADDED"] == "present");
	assert(resolved.gitName == "Agent Type Name");
	assert(resolved.gitEmail == "workspace@example.com");
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-sandbox-declaration-order");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto sharedPath = buildPath(root, "shared");
	auto agentOnlyPath = buildPath(root, "selected-agent-only");
	mkdirRecurse(sharedPath);
	mkdirRecurse(agentOnlyPath);

	SandboxConfig global;
	SandboxConfig configuredAgent;
	SandboxConfig workspace;
	configuredAgent.paths[agentOnlyPath] = PathMode.rw;
	auto globalAlias = root ~ "/./shared";
	auto agentAlias = root ~ "//shared";
	auto workspaceAlias = root ~ "//./shared";

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};
	agent.agentName = "selected-agent";
	agent.workspaceName = "selected-workspace";

	global.isolate_filesystem = SetInfo!bool(false);
	auto builtin = resolveSandbox(global, configuredAgent, workspace, agent,
		sharedPath, sharedPath);
	auto builtinView = builtin.paths.exact(sharedPath).get;
	assert(!builtin.isolate_filesystem);
	assert(builtinView.effectiveMode == PathMode.rw);
	assert(builtinView.declaration.get.mode == PathMode.rw);
	assert(builtinView.declaration.get.origin.kind
		== SandboxPathOriginKind.builtinDefault);
	assert(builtinView.declaration.get.origin.scope_ == "project");
	assert(builtinView.declaration.get.origin.detail == "project default");
	assert(!builtin.paths.exact(agentOnlyPath).isNull);

	global.paths[globalAlias] = PathMode.ro;
	global.isolate_filesystem = SetInfo!bool(false);
	auto globalResolved = resolveSandbox(global, configuredAgent, workspace, agent,
		sharedPath, sharedPath);
	auto globalView = globalResolved.paths.exact(sharedPath).get;
	assert(!globalResolved.isolate_filesystem);
	assert(globalView.effectiveMode == PathMode.ro);
	assert(globalView.declaration.get.mode == PathMode.ro);
	assert(globalView.declaration.get.origin.kind
		== SandboxPathOriginKind.globalConfig);
	assert(globalView.declaration.get.origin.scope_ == "global");
	assert(globalView.declaration.get.origin.detail
		== "sandbox.paths (" ~ globalAlias ~ ")");

	configuredAgent.paths[agentAlias] = PathMode.always_rw;
	global.isolate_filesystem = SetInfo!bool(false);
	auto agentResolved = resolveSandbox(global, configuredAgent, workspace, agent,
		sharedPath, sharedPath);
	auto agentView = agentResolved.paths.exact(sharedPath).get;
	assert(!agentResolved.isolate_filesystem);
	assert(agentView.effectiveMode == PathMode.always_rw);
	assert(agentView.declaration.get.mode == PathMode.always_rw);
	assert(agentView.declaration.get.origin.kind
		== SandboxPathOriginKind.agentConfig);
	assert(agentView.declaration.get.origin.scope_ == "selected-agent");
	assert(agentView.declaration.get.origin.detail
		== "sandbox.paths (" ~ agentAlias ~ ")");

	workspace.paths[workspaceAlias] = PathMode.rw;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		auto beforeRequirement = paths.exact(sharedPath).get;
		assert(beforeRequirement.declaration.get.mode == PathMode.rw);
		assert(beforeRequirement.declaration.get.origin.kind
			== SandboxPathOriginKind.workspaceConfig);
		assert(beforeRequirement.declaration.get.origin.scope_ == "selected-workspace");
		assert(beforeRequirement.declaration.get.origin.detail
			== "sandbox.paths (" ~ workspaceAlias ~ ")");
		assert(beforeRequirement.effectiveMode == PathMode.ro);
		paths.require(sharedPath, PathAccess.rw,
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "selected-agent",
				"restores required write access"));
	};
	global.isolate_filesystem = SetInfo!bool(false);
	auto resolved = resolveSandbox(global, configuredAgent, workspace, agent,
		sharedPath, sharedPath, true);
	auto view = resolved.paths.exact(sharedPath).get;
	assert(!resolved.isolate_filesystem);
	assert(view.effectiveMode == PathMode.rw);
	assert(view.declaration.get.mode == PathMode.rw);
	assert(view.declaration.get.origin.kind == SandboxPathOriginKind.workspaceConfig);
	assert(view.declaration.get.origin.scope_ == "selected-workspace");
	assert(view.declaration.get.origin.detail == "sandbox.paths (" ~ workspaceAlias ~ ")");

	auto discoveryKey = root;
	auto discoveryGlobalAlias = root ~ "/.";
	auto discoveryWorkspaceAlias = root ~ "//.";
	auto cydoDir = cydoBinaryDir();
	auto builtinDiscovery = resolveSandboxForDiscovery(SandboxConfig.init,
		SandboxConfig.init, discoveryKey, "discovery-workspace");
	auto builtinDiscoveryView = builtinDiscovery.paths.exact(discoveryKey).get;
	assert(builtinDiscoveryView.effectiveMode == PathMode.ro);
	assert(builtinDiscoveryView.declaration.get.mode == PathMode.ro);
	assert(builtinDiscoveryView.declaration.get.origin.kind
		== SandboxPathOriginKind.builtinDefault);
	assert(builtinDiscoveryView.declaration.get.origin.scope_ == "workspace-root");
	assert(builtinDiscoveryView.declaration.get.origin.detail
		== "discovery workspace root default");
	assert(builtinDiscovery.paths.exact(agentOnlyPath).isNull);

	SandboxConfig discoveryGlobal;
	discoveryGlobal.paths[discoveryGlobalAlias] = PathMode.rw;
	auto globalDiscovery = resolveSandboxForDiscovery(discoveryGlobal, SandboxConfig.init,
		discoveryKey, "discovery-workspace");
	auto globalDiscoveryView = globalDiscovery.paths.exact(discoveryKey).get;
	assert(globalDiscoveryView.effectiveMode == PathMode.ro);
	assert(globalDiscoveryView.declaration.get.mode == PathMode.rw);
	assert(globalDiscoveryView.declaration.get.origin.kind
		== SandboxPathOriginKind.globalConfig);
	assert(globalDiscoveryView.declaration.get.origin.scope_ == "global");
	assert(globalDiscoveryView.declaration.get.origin.detail
		== "sandbox.paths (" ~ discoveryGlobalAlias ~ ")");
	assert(globalDiscovery.paths.exact(agentOnlyPath).isNull);

	SandboxConfig discoveryWorkspace;
	discoveryWorkspace.paths[discoveryWorkspaceAlias] = PathMode.always_rw;
	auto discovery = resolveSandboxForDiscovery(discoveryGlobal, discoveryWorkspace,
		discoveryKey, "discovery-workspace");
	auto discoveryView = discovery.paths.exact(discoveryKey).get;
	assert(discoveryView.effectiveMode == PathMode.ro);
	assert(discoveryView.declaration.get.mode == PathMode.always_rw);
	assert(discoveryView.declaration.get.origin.kind
		== SandboxPathOriginKind.workspaceConfig);
	assert(discoveryView.declaration.get.origin.scope_ == "discovery-workspace");
	assert(discoveryView.declaration.get.origin.detail
		== "sandbox.paths (" ~ discoveryWorkspaceAlias ~ ")");
	assert(discovery.paths.exact(agentOnlyPath).isNull);
	// Check the real executable directory when process isolation is disabled.
	SandboxConfig discoveryWithoutPidNamespace;
	discoveryWithoutPidNamespace.isolate_processes = SetInfo!bool(false);
	auto withoutPidNamespace = resolveSandboxForDiscovery(discoveryWithoutPidNamespace,
		SandboxConfig.init, discoveryKey, "discovery-workspace");
	assert(withoutPidNamespace.isolate_filesystem);
	assert(!withoutPidNamespace.isolate_processes);
	assert(withoutPidNamespace.paths.exact(cydoDir).get.requirement.get.access == PathAccess.ro);

	discoveryWithoutPidNamespace.paths[dirName(cydoDir)] = PathMode.always_rw;
	auto ancestorDiscovery = resolveSandboxForDiscovery(discoveryWithoutPidNamespace,
		SandboxConfig.init, discoveryKey, "discovery-workspace");
	assert(ancestorDiscovery.paths.exact(dirName(cydoDir)).get.effectiveMode == PathMode.ro);
	assert(ancestorDiscovery.paths.exact(cydoDir).isNull);

	SandboxConfig maskedWorkspace;
	maskedWorkspace.paths[cydoDir] = PathMode.tmpfs;
	auto maskedDiscovery = resolveSandboxForDiscovery(SandboxConfig.init,
		maskedWorkspace, root, "discovery-workspace");
	assert(maskedDiscovery.paths.exact(cydoDir).get.effectiveMode == PathMode.ro);
	assert(maskedDiscovery.paths.exact(agentOnlyPath).isNull);
}

unittest // Project discovery stays outside the agent memory scope.
{
	import configy.attributes : SetInfo;
	import cydo.runtime.config : MemorySize;

	SandboxConfig global, workspace;
	global.memory.max = SetInfo!MemorySize(MemorySize.fromString("8G"), true);
	workspace.memory.high = SetInfo!MemorySize(MemorySize.fromString("6G"), true);
	assert(resolveSandboxForDiscovery(global, workspace, "/tmp", "discovery-workspace")
		.memoryScope.isNull);
}

unittest
{
	import std.exception : assertThrown;
	import std.file : mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-symlink");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	// ws/.cydo/tasks is an absolute symlink whose target spelling traverses
	// another (relative) symlink, mirroring a tasks directory relocated to
	// another volume that is itself reached through a symlink.
	auto wsRoot = buildPath(root, "ws");
	auto movedTasks = buildPath(root, "moved", "tasks");
	auto taskDir = buildPath(movedTasks, "1");
	auto hop = buildPath(root, "hop"); // hop → moved
	auto tasksLink = buildPath(wsRoot, ".cydo", "tasks"); // → hop/tasks
	mkdirRecurse(buildPath(wsRoot, ".cydo"));
	mkdirRecurse(taskDir);
	symlink("moved", hop);
	symlink(buildPath(hop, "tasks"), tasksLink);
	auto logicalTaskDir = buildPath(tasksLink, "1");
	auto hopSymlink = PlannedSandboxSymlink(hop, "moved");
	auto tasksSymlink = PlannedSandboxSymlink(tasksLink, buildPath(hop, "tasks"));

	auto providerOrigin = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"symlink-provider", wsRoot);
	auto taskOrigin = planTestOrigin(SandboxPathOriginKind.launchRequirement,
		"symlink-task", logicalTaskDir);

	// Mounts land at the physical path. Symlinks a host-content mount already
	// exposes are not recreated; the others are, so the logical spelling
	// resolves inside the sandbox as it does on the host.
	SandboxPaths providerVisible;
	providerVisible.set(wsRoot, PathMode.ro, providerOrigin);
	providerVisible.set(logicalTaskDir, PathMode.rw, taskOrigin);
	auto providerVisiblePlan = planMounts(providerVisible, null, null);
	assert(providerVisiblePlan.mounts.length == 2);
	auto taskMount = providerVisiblePlan.mounts[planMountIndex(
		providerVisiblePlan.mounts, taskDir)];
	assert(taskMount.source == taskDir);
	assert(taskMount.mode == PathMode.rw);
	assert(providerVisiblePlan.symlinks == [hopSymlink]);

	SandboxPaths uncoveredPaths;
	uncoveredPaths.set(logicalTaskDir, PathMode.rw, taskOrigin);
	auto uncoveredPlan = planMounts(uncoveredPaths, null, null);
	assert(uncoveredPlan.mounts.length == 1);
	assert(uncoveredPlan.mounts[0].source == taskDir);
	assert(uncoveredPlan.mounts[0].destination == taskDir);
	assert(uncoveredPlan.symlinks == [hopSymlink, tasksSymlink]);

	// Built-in host mounts expose symlinks like registry mounts do.
	SandboxPaths builtinVisible;
	builtinVisible.set(logicalTaskDir, PathMode.rw, taskOrigin);
	auto builtinVisiblePlan = planMounts(builtinVisible, [wsRoot: PathMode.ro], null);
	assert(builtinVisiblePlan.mounts.length == 2);
	assert(builtinVisiblePlan.mounts[planMountIndex(builtinVisiblePlan.mounts,
		wsRoot)].origins[0].kind == SandboxPathOriginKind.builtinDefault);
	assert(builtinVisiblePlan.symlinks == [hopSymlink]);

	// A registry path at a built-in's destination replaces the built-in.
	auto builtinReplacedPlan = planMounts(providerVisible,
		[wsRoot: PathMode.rw], null);
	auto replacedMount = builtinReplacedPlan.mounts[planMountIndex(
		builtinReplacedPlan.mounts, wsRoot)];
	assert(replacedMount.mode == PathMode.ro);
	assertPlanOriginsEqual(replacedMount.origins, [providerOrigin]);

	// The root mount strictly contains every symlink.
	SandboxPaths rootVisible;
	rootVisible.set("/", PathMode.ro, providerOrigin);
	rootVisible.set(logicalTaskDir, PathMode.rw, taskOrigin);
	auto rootVisiblePlan = planMounts(rootVisible, null, null);
	assert(rootVisiblePlan.mounts.length == 2);
	assert(rootVisiblePlan.symlinks.length == 0);

	// A tmpfs mask applies to the physical path, and the symlinks under the
	// tmpfs are recreated inside it.
	SandboxPaths masked;
	masked.set(wsRoot, PathMode.tmpfs, providerOrigin);
	masked.set(logicalTaskDir, PathMode.ro, taskOrigin);
	auto maskedPlan = planMounts(masked, null, null);
	assert(maskedPlan.mounts[planMountIndex(maskedPlan.mounts, wsRoot)].mode
		== PathMode.tmpfs);
	assert(maskedPlan.symlinks == [hopSymlink, tasksSymlink]);

	// A symlink under an empty_dir mask cannot be recreated.
	SandboxPaths emptied;
	emptied.set(wsRoot, PathMode.empty_dir, providerOrigin);
	emptied.set(logicalTaskDir, PathMode.ro, taskOrigin);
	assertThrown(planMounts(emptied, null, null));

	// Built-in symlinks merge with traversed ones and must agree on targets.
	auto builtinSymlinkPlan = planMounts(uncoveredPaths, null, [hopSymlink]);
	assert(builtinSymlinkPlan.symlinks == [hopSymlink, tasksSymlink]);
	assertThrown(planMounts(uncoveredPaths, null,
		[PlannedSandboxSymlink(hop, "elsewhere")]));

	// Two spellings resolving to the same path with conflicting modes fail at
	// the pure planning boundary without changing their logical registrations.
	auto tasksLink2 = buildPath(wsRoot, ".cydo", "tasks2"); // → hop/tasks too
	symlink(buildPath(hop, "tasks"), tasksLink2);
	SandboxPaths conflicting;
	conflicting.set(wsRoot, PathMode.ro, providerOrigin);
	conflicting.set(logicalTaskDir, PathMode.rw, taskOrigin);
	conflicting.set(buildPath(tasksLink2, "1"), PathMode.ro,
		planTestOrigin(SandboxPathOriginKind.launchRequirement, "symlink-conflict",
			buildPath(tasksLink2, "1")));
	assertThrown(planMounts(conflicting, null, null));
}

unittest
{
	import std.process : environment;

	auto oldHome = environment.get("HOME", "");
	scope(exit)
		environment["HOME"] = oldHome;

	environment["HOME"] = "/tmp/cydo-sandbox-home";

	SandboxConfig workspace;
	workspace.env["CYDO_TEMPLATE"] = "{{ env.HOME }}/cfg:~/bin";

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};

	auto resolved = resolveSandbox(SandboxConfig.init, SandboxConfig.init,
		workspace, agent, "", "");
	assert(resolved.env["CYDO_TEMPLATE"] == "/tmp/cydo-sandbox-home/cfg:/tmp/cydo-sandbox-home/bin");
}

version (unittest)
{
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;
	import std.logger.core : Logger, LogLevel, stdThreadLocalLog;

	private final class PlanWarningLogger : Logger
	{
		string[] messages;

		this()
		{
			super(LogLevel.all);
		}

		override protected void writeLogMsg(ref LogEntry payload) @safe
		{
			messages ~= payload.msg;
		}
	}

	private SandboxPathOrigin planTestOrigin(SandboxPathOriginKind kind,
		string scope_, string detail)
	{
		return SandboxPathOrigin(kind, scope_, detail);
	}

	private void assertPlanOriginEqual(SandboxPathOrigin left,
		SandboxPathOrigin right)
	{
		assert(left.kind == right.kind);
		assert(left.scope_ == right.scope_);
		assert(left.detail == right.detail);
	}

	private void assertPlanOriginsEqual(SandboxPathOrigin[] left,
		SandboxPathOrigin[] right)
	{
		assert(left.length == right.length);
		foreach (i, leftOrigin; left)
			assertPlanOriginEqual(leftOrigin, right[i]);
	}

	private void assertPlannedMountsEqual(PlannedSandboxMount[] left,
		PlannedSandboxMount[] right)
	{
		assert(left.length == right.length);
		foreach (i, leftMount; left)
		{
			auto rightMount = right[i];
			assert(leftMount.source == rightMount.source);
			assert(leftMount.destination == rightMount.destination);
			assert(leftMount.mode == rightMount.mode);
			assertPlanOriginsEqual(leftMount.origins, rightMount.origins);
		}
	}

	private void assertPlanViewsEqual(SandboxPathView[] left,
		SandboxPathView[] right)
	{
		assert(left.length == right.length);
		foreach (i, leftView; left)
		{
			auto rightView = right[i];
			assert(leftView.path == rightView.path);
			assert(leftView.effectiveMode == rightView.effectiveMode);
			assert(leftView.declaration.isNull == rightView.declaration.isNull);
			assert(leftView.requirement.isNull == rightView.requirement.isNull);
			assert(leftView.taskReadOnlyBy.isNull == rightView.taskReadOnlyBy.isNull);
			assert(leftView.finalReadOnlyBy.isNull == rightView.finalReadOnlyBy.isNull);
			if (!leftView.declaration.isNull)
			{
				assert(leftView.declaration.get.mode == rightView.declaration.get.mode);
				assertPlanOriginEqual(leftView.declaration.get.origin,
					rightView.declaration.get.origin);
			}
			if (!leftView.requirement.isNull)
			{
				assert(leftView.requirement.get.access == rightView.requirement.get.access);
				assertPlanOriginEqual(leftView.requirement.get.origin,
					rightView.requirement.get.origin);
			}
			if (!leftView.taskReadOnlyBy.isNull)
				assertPlanOriginEqual(leftView.taskReadOnlyBy.get,
					rightView.taskReadOnlyBy.get);
			if (!leftView.finalReadOnlyBy.isNull)
				assertPlanOriginEqual(leftView.finalReadOnlyBy.get,
					rightView.finalReadOnlyBy.get);
		}
	}

	private size_t planMountIndex(PlannedSandboxMount[] plan,
		string destination)
	{
		foreach (i, mount; plan)
			if (mount.destination == destination)
				return i;
		assert(false, "planned mount is missing destination " ~ destination);
		return 0;
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-order");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto parent = buildPath(root, "tree");
	auto alpha = buildPath(parent, "alpha");
	auto bravo = buildPath(parent, "bravo");
	auto child = buildPath(parent, "child");
	foreach (path; [alpha, bravo, child])
		mkdirRecurse(path);

	auto origin = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"ordering", "declared ordering");
	SandboxPaths forward;
	forward.set("/", PathMode.tmpfs, origin);
	forward.set(parent, PathMode.ro, origin);
	forward.set(alpha, PathMode.ro, origin);
	forward.set(bravo, PathMode.ro, origin);
	forward.set(child, PathMode.ro, origin);
	SandboxPaths reverse;
	reverse.set(child, PathMode.ro, origin);
	reverse.set(bravo, PathMode.ro, origin);
	reverse.set(alpha, PathMode.ro, origin);
	reverse.set(parent, PathMode.ro, origin);
	reverse.set("/", PathMode.tmpfs, origin);

	auto forwardPlan = planMounts(forward, null, null).mounts;
	auto reversePlan = planMounts(reverse, null, null).mounts;
	assertPlannedMountsEqual(forwardPlan, reversePlan);
	assert(forwardPlan.length == 5);
	assert(forwardPlan[0].destination == "/");
	assert(forwardPlan[0].source == "");
	assert(forwardPlan[0].mode == PathMode.tmpfs);
	assert(forwardPlan[1].destination == parent);
	assert(forwardPlan[2].destination == alpha);
	assert(forwardPlan[3].destination == bravo);
	assert(forwardPlan[4].destination == child);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-coalesce");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto target = buildPath(root, "target");
	auto aliasA = buildPath(root, "alias-a");
	auto aliasB = buildPath(root, "alias-b");
	mkdirRecurse(target);
	symlink(target, aliasA);
	symlink(target, aliasB);

	auto provider = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"provider", root);
	auto declarationA = planTestOrigin(SandboxPathOriginKind.workspaceConfig,
		"z-scope", "declaration-a");
	auto requirementA = planTestOrigin(SandboxPathOriginKind.launchRequirement,
		"b-scope", "requirement-a");
	auto declarationB = planTestOrigin(SandboxPathOriginKind.globalConfig,
		"same-scope", "declaration-b");
	auto requirementB = planTestOrigin(SandboxPathOriginKind.agentRequirement,
		"a-scope", "requirement-b");
	auto taskReadOnly = planTestOrigin(SandboxPathOriginKind.taskReadOnly,
		"task", "task read-only");
	auto discoveryReadOnly = planTestOrigin(SandboxPathOriginKind.discoveryReadOnly,
		"discovery", "discovery read-only");

	SandboxPaths paths;
	paths.set(root, PathMode.ro, provider);
	paths.set(aliasA, PathMode.rw, declarationA);
	paths.require(aliasA, PathAccess.rw, requirementA);
	paths.set(aliasB, PathMode.rw, declarationB);
	paths.require(aliasB, PathAccess.rw, requirementB);
	paths.applyDiscoveryReadOnly(discoveryReadOnly);
	paths.applyTaskReadOnly(taskReadOnly);
	foreach (logicalAlias; [aliasA, aliasB])
	{
		auto view = paths.exact(logicalAlias).get;
		assert(!view.declaration.isNull);
		assert(!view.requirement.isNull);
		assert(!view.taskReadOnlyBy.isNull);
		assert(!view.finalReadOnlyBy.isNull);
	}

	auto plan = planMounts(paths, null, null).mounts;
	assert(plan.length == 2);
	auto targetMount = plan[planMountIndex(plan, target)];
	assert(targetMount.source == target);
	assert(targetMount.destination == target);
	assert(targetMount.mode == PathMode.ro);
	assertPlanOriginsEqual(targetMount.origins, [
		declarationB,
		declarationA,
		requirementB,
		requirementA,
		taskReadOnly,
		discoveryReadOnly,
	]);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-conflict");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto target = buildPath(root, "target");
	auto logicalRw = buildPath(root, "logical-rw");
	auto logicalTmpfs = buildPath(root, "logical-tmpfs");
	mkdirRecurse(target);
	symlink(target, logicalRw);
	symlink(target, logicalTmpfs);

	auto provider = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"provider-scope", root);
	auto rwOrigin = planTestOrigin(SandboxPathOriginKind.launchRequirement,
		"rw-scope", "rw-detail");
	auto tmpfsOrigin = planTestOrigin(SandboxPathOriginKind.workspaceConfig,
		"tmpfs-scope", "tmpfs-detail");
	SandboxPaths paths;
	paths.set(root, PathMode.ro, provider);
	paths.set(logicalRw, PathMode.rw, rwOrigin);
	paths.set(logicalTmpfs, PathMode.tmpfs, tmpfsOrigin);

	bool thrown;
	try
		planMounts(paths, null, null);
	catch (Exception e)
	{
		thrown = true;
		foreach (fragment; [target, logicalRw, logicalTmpfs, "rw", "tmpfs",
			rwOrigin.scope_, rwOrigin.detail, tmpfsOrigin.scope_, tmpfsOrigin.detail])
			assert(e.msg.canFind(fragment), e.msg);
	}
	assert(thrown);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-missing");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto present = buildPath(root, "present");
	auto missing = buildPath(root, "missing");
	mkdirRecurse(present);
	auto origin = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"missing", "missing logical path");
	SandboxPaths paths;
	paths.set(present, PathMode.ro, origin);
	paths.set(missing, PathMode.rw, origin);
	auto snapshotBeforePlanning = paths.snapshot;

	auto previousLogger = stdThreadLocalLog;
	scope(exit) stdThreadLocalLog = previousLogger;
	auto warningLogger = new PlanWarningLogger;
	stdThreadLocalLog = warningLogger;

	// A missing logical entry is warned about and skipped, but remains in the
	// registry's detached logical snapshot.
	auto plan = planMounts(paths, null, null).mounts;
	assert(plan.length == 1);
	assert(plan[0].destination == present);
	assert(warningLogger.messages.length == 1);
	assert(warningLogger.messages[0].canFind("sandbox: skipping non-existent path"));
	assert(warningLogger.messages[0].canFind(missing));
	assertPlanViewsEqual(snapshotBeforePlanning, paths.snapshot);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-detached");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto mounted = buildPath(root, "mounted");
	mkdirRecurse(mounted);
	auto origin = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"detached", "original origin");
	SandboxPaths paths;
	paths.set(mounted, PathMode.ro, origin);
	auto snapshotBeforePlanning = paths.snapshot;
	auto firstPlan = planMounts(paths, null, null).mounts;
	auto separatelyReturnedPlan = planMounts(paths, null, null).mounts;
	assertPlannedMountsEqual(firstPlan, separatelyReturnedPlan);
	assertPlanViewsEqual(snapshotBeforePlanning, paths.snapshot);

	firstPlan[0].source = "changed-source";
	firstPlan[0].destination = "changed-destination";
	firstPlan[0].mode = PathMode.tmpfs;
	firstPlan[0].origins[0].detail = "changed-origin";
	assertPlanViewsEqual(snapshotBeforePlanning, paths.snapshot);
	assert(separatelyReturnedPlan[0].source == mounted);
	assert(separatelyReturnedPlan[0].destination == mounted);
	assert(separatelyReturnedPlan[0].mode == PathMode.ro);
	assertPlanOriginEqual(separatelyReturnedPlan[0].origins[0], origin);

	auto repeatedPlan = planMounts(paths, null, null).mounts;
	assertPlannedMountsEqual(separatelyReturnedPlan, repeatedPlan);
	assertPlanViewsEqual(snapshotBeforePlanning, paths.snapshot);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : SandboxPathOriginKind;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-plan-masked-children");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto parent = buildPath(root, "masked");
	auto alpha = buildPath(parent, "alpha");
	auto bravo = buildPath(parent, "bravo");
	auto cider = buildPath(parent, "cider");
	foreach (path; [alpha, bravo, cider])
		mkdirRecurse(path);

	auto origin = planTestOrigin(SandboxPathOriginKind.builtinDefault,
		"masked-children", "declared mount");
	SandboxPaths parentFirst;
	parentFirst.set(parent, PathMode.tmpfs, origin);
	parentFirst.set(alpha, PathMode.ro, origin);
	parentFirst.set(bravo, PathMode.rw, origin);
	parentFirst.set(cider, PathMode.always_rw, origin);
	SandboxPaths childrenFirst;
	childrenFirst.set(cider, PathMode.always_rw, origin);
	childrenFirst.set(bravo, PathMode.rw, origin);
	childrenFirst.set(alpha, PathMode.ro, origin);
	childrenFirst.set(parent, PathMode.tmpfs, origin);

	auto parentFirstPlan = planMounts(parentFirst, null, null).mounts;
	auto childrenFirstPlan = planMounts(childrenFirst, null, null).mounts;
	assertPlannedMountsEqual(parentFirstPlan, childrenFirstPlan);
	assert(parentFirstPlan.length == 4);
	assert(parentFirstPlan[0].destination == parent);
	assert(parentFirstPlan[0].source == "");
	assert(parentFirstPlan[0].mode == PathMode.tmpfs);
	assert(parentFirstPlan[1].destination == alpha);
	assert(parentFirstPlan[1].source == alpha);
	assert(parentFirstPlan[1].mode == PathMode.ro);
	assert(parentFirstPlan[2].destination == bravo);
	assert(parentFirstPlan[2].source == bravo);
	assert(parentFirstPlan[2].mode == PathMode.rw);
	assert(parentFirstPlan[3].destination == cider);
	assert(parentFirstPlan[3].source == cider);
	assert(parentFirstPlan[3].mode == PathMode.always_rw);
}
