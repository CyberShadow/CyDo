module cydo.runtime.launch.sandbox_paths;

import std.algorithm : canFind, endsWith, sort, splitter, startsWith;
import std.exception : enforce;
import std.format : format;
import std.path : dirName, expandTilde;
import std.typecons : Nullable;

import cydo.runtime.config : PathMode;

enum PathAccess { ro, rw, alwaysRw }

enum SandboxPathOriginKind
{
	builtinDefault,
	globalConfig,
	agentConfig,
	workspaceConfig,
	agentRequirement,
	launchRequirement,
	taskReadOnly,
	discoveryReadOnly,
	exactReadOnly,
}

struct SandboxPathOrigin
{
	SandboxPathOriginKind kind;
	string scope_;
	string detail;
}

struct DeclaredSandboxPath
{
	PathMode mode;
	SandboxPathOrigin origin;
}

struct RequiredSandboxPath
{
	PathAccess access;
	SandboxPathOrigin origin;
}

struct SandboxPathEntry
{
	Nullable!DeclaredSandboxPath declaration;
	Nullable!RequiredSandboxPath requirement;
	Nullable!SandboxPathOrigin taskReadOnlyBy;
	Nullable!SandboxPathOrigin finalReadOnlyBy;
}

struct SandboxPathView
{
	string path;
	PathMode effectiveMode;
	Nullable!DeclaredSandboxPath declaration;
	Nullable!RequiredSandboxPath requirement;
	Nullable!SandboxPathOrigin taskReadOnlyBy;
	Nullable!SandboxPathOrigin finalReadOnlyBy;
}

struct PlannedSandboxMount
{
	string source;
	string destination;
	PathMode mode;
	SandboxPathOrigin[] origins;
}

/// A host symlink recreated in the sandbox so that logical spellings resolve
/// to mounts planned at physical paths.
struct PlannedSandboxSymlink
{
	/// The symlink's own physical path.
	string location;
	/// The symlink's contents, verbatim.
	string target;
}

struct SandboxMountPlan
{
	PlannedSandboxMount[] mounts;
	PlannedSandboxSymlink[] symlinks;
}

/// Owns the normalized logical sandbox path namespace.
///
/// The postblit gives this value type ownership of its associative array. D
/// otherwise aliases associative arrays when structs are copied.
struct SandboxPaths
{
	private SandboxPathEntry[string] entries_;

	this(this)
	{
		entries_ = entries_.dup;
	}

	package(cydo.runtime.launch) void set(string rawPath, PathMode mode,
		SandboxPathOrigin origin)
	{
		auto path = normalizeSandboxPath(rawPath, describeOrigin(origin));
		if (auto entry = path in entries_)
			(*entry).declaration = Nullable!DeclaredSandboxPath(
				DeclaredSandboxPath(mode, origin));
		else
		{
			SandboxPathEntry entry;
			entry.declaration = Nullable!DeclaredSandboxPath(
				DeclaredSandboxPath(mode, origin));
			entries_[path] = entry;
		}
	}

	/// Apply one raw configuration layer after resolving spelling aliases inside
	/// that layer. Later calls express layer precedence through normal `set`.
	package(cydo.runtime.launch) void applyConfigLayer(
		PathMode[string] configured, SandboxPathOrigin layerOrigin)
	{
		NormalizedConfigPath[string] normalized;
		string[] rawPaths;
		foreach (rawPath, _; configured)
			rawPaths ~= rawPath;
		sort(rawPaths);

		foreach (rawPath; rawPaths)
		{
			auto path = normalizeSandboxPath(rawPath, describeOrigin(layerOrigin));
			auto mode = configured[rawPath];
			if (auto previous = path in normalized)
			{
				enforce((*previous).mode == mode, format(
					"sandbox config paths %s (%s) and %s (%s) normalize to %s in %s",
					quotedPath((*previous).rawPath), pathModeName((*previous).mode),
					quotedPath(rawPath), pathModeName(mode), quotedPath(path),
					describeOrigin(layerOrigin)));
				continue;
			}

			normalized[path] = NormalizedConfigPath(mode, rawPath);
		}

		string[] paths;
		foreach (path, _; normalized)
			paths ~= path;
		sort(paths);
		foreach (path; paths)
		{
			auto configuredPath = normalized[path];
			auto origin = originWithRawPath(layerOrigin, configuredPath.rawPath);
			set(path, configuredPath.mode, origin);
		}
	}

	/// Guarantee host-content access at the exact normalized path.
	void require(string rawPath, PathAccess access, SandboxPathOrigin origin)
	{
		auto path = normalizeSandboxPath(rawPath, describeOrigin(origin));
		if (auto entry = path in entries_)
		{
			if (rejectsWriteRequirement(*entry, access))
				enforce(false, writeRequirementConflict(path, (*entry).declaration.get,
					access, origin));
			joinRequirement(*entry, access, origin);
			return;
		}

		SandboxPathEntry entry;
		entry.requirement = Nullable!RequiredSandboxPath(
			RequiredSandboxPath(access, origin));
		entries_[path] = entry;
	}

	/// Require read visibility without narrowing the nearest writable logical
	/// ancestor. This is intentionally narrower than an ancestor-satisfiable
	/// access requirement.
	void requireReadVisible(string rawPath, SandboxPathOrigin origin)
	{
		auto path = normalizeSandboxPath(rawPath, describeOrigin(origin));
		if (path == "/nix" || path.startsWith("/nix/"))
			require("/nix", PathAccess.ro, origin);
		if (path in entries_)
		{
			require(path, PathAccess.ro, origin);
			return;
		}

		auto ancestor = nearestAncestor(path);
		if (!ancestor.isNull)
		{
			auto mode = ancestor.get.effectiveMode;
			if (mode == PathMode.rw || mode == PathMode.always_rw)
				return;
		}
		require(path, PathAccess.ro, origin);
	}

	/// Reduce declared ordinary writes while retaining the declaration needed to
	/// restore an exact runtime write requirement later in launch preparation.
	void applyTaskReadOnly(SandboxPathOrigin origin)
	{
		foreach (ref entry; entries_)
			if (!entry.declaration.isNull
				&& entry.declaration.get.mode == PathMode.rw)
				entry.taskReadOnlyBy = Nullable!SandboxPathOrigin(origin);
	}

	/// Apply the terminal discovery read-only cap to currently writable host
	/// content without changing a standalone mask.
	void applyDiscoveryReadOnly(SandboxPathOrigin origin)
	{
		foreach (ref entry; entries_)
		{
			auto mode = effectiveMode(entry);
			if (mode == PathMode.rw || mode == PathMode.always_rw)
				entry.finalReadOnlyBy = Nullable!SandboxPathOrigin(origin);
		}
	}

	/// Apply a non-restorable exact read-only cap when an existing exact entry
	/// produces host content. A standalone mask remains unchanged.
	void restrictExactToReadOnly(string rawPath, SandboxPathOrigin origin)
	{
		auto path = normalizeSandboxPath(rawPath, describeOrigin(origin));
		if (auto entry = path in entries_)
			if (isHostContent(effectiveMode(*entry)))
				(*entry).finalReadOnlyBy = Nullable!SandboxPathOrigin(origin);
	}

	/// Look up one logical entry through the same namespace normalization used
	/// by all writes. The returned view is detached from registry storage.
	Nullable!SandboxPathView exact(string rawPath) const
	{
		auto path = normalizeSandboxPath(rawPath, "query");
		if (auto entry = path in entries_)
			return Nullable!SandboxPathView(toView(path, *entry));
		return Nullable!SandboxPathView.init;
	}

	/// Return detached logical entries in deterministic path order.
	SandboxPathView[] snapshot() const
	{
		string[] paths;
		foreach (path, _; entries_)
			paths ~= path;
		sort(paths);

		SandboxPathView[] result;
		result.reserve(paths.length);
		foreach (path; paths)
			result ~= toView(path, entries_[path]);
		return result;
	}

	private struct NormalizedConfigPath
	{
		PathMode mode;
		string rawPath;
	}

	private Nullable!SandboxPathView nearestAncestor(string path) const
	{
		if (path == "/")
			return Nullable!SandboxPathView.init;

		for (auto ancestor = dirName(path); ancestor != ".";
			ancestor = dirName(ancestor))
		{
			if (auto entry = ancestor in entries_)
				return Nullable!SandboxPathView(toView(ancestor, *entry));
			if (ancestor == "/")
				break;
		}
		return Nullable!SandboxPathView.init;
	}

	private static void joinRequirement(ref SandboxPathEntry entry,
		PathAccess access, SandboxPathOrigin origin)
	{
		if (entry.requirement.isNull
			|| pathAccessStrength(access)
				> pathAccessStrength(entry.requirement.get.access)
			|| (pathAccessStrength(access)
				== pathAccessStrength(entry.requirement.get.access)
				&& compareOrigins(origin, entry.requirement.get.origin) < 0))
			entry.requirement = Nullable!RequiredSandboxPath(
				RequiredSandboxPath(access, origin));
	}

	private static bool rejectsWriteRequirement(const ref SandboxPathEntry entry,
		PathAccess access)
	{
		if (!isWriteAccess(access) || entry.declaration.isNull)
			return false;

		auto declaration = entry.declaration.get;
		return isExplicitUserDeclaration(declaration.origin.kind)
			&& (declaration.mode == PathMode.ro || !isHostContent(declaration.mode));
	}

	private static PathMode effectiveMode(const ref SandboxPathEntry entry)
	{
		PathMode mode;
		if (entry.declaration.isNull)
		{
			assert(!entry.requirement.isNull);
			mode = pathModeForAccess(entry.requirement.get.access);
		}
		else
		{
			auto declaration = entry.declaration.get;
			mode = declaration.mode;
			if (!entry.taskReadOnlyBy.isNull && mode == PathMode.rw)
				mode = PathMode.ro;

			if (!entry.requirement.isNull)
			{
				auto required = pathModeForAccess(entry.requirement.get.access);
				mode = isHostContent(declaration.mode)
					? strongerHostMode(mode, required)
					: required;
			}
		}

		if (!entry.finalReadOnlyBy.isNull && isHostContent(mode))
			mode = PathMode.ro;
		return mode;
	}

	private static SandboxPathView toView(string path,
		const ref SandboxPathEntry entry)
	{
		return SandboxPathView(path, effectiveMode(entry), entry.declaration,
			entry.requirement, entry.taskReadOnlyBy, entry.finalReadOnlyBy);
	}
}

private string normalizeSandboxPath(string rawPath, string source)
{
	enforce(rawPath.length > 0, pathError(rawPath, source, "path must not be empty"));
	auto expanded = expandTilde(rawPath);
	enforce(expanded.length > 0, pathError(rawPath, source, "path must not be empty"));
	enforce(!expanded.startsWith("~"),
		pathError(rawPath, source, "leading '~' could not be resolved"));
	enforce(expanded.startsWith("/"),
		pathError(rawPath, source, "path must be absolute after tilde expansion"));
	enforce(!expanded.startsWith("//"),
		pathError(rawPath, source, "path must not begin with '//'"));
	enforce(expanded == "/" || !expanded.endsWith("/"),
		pathError(rawPath, source, "path must not have a non-root trailing slash"));

	string normalized;
	foreach (component; expanded.splitter('/'))
	{
		if (component.length == 0 || component == ".")
			continue;
		enforce(component != "..",
			pathError(rawPath, source, "path must not contain '..'"));
		normalized ~= "/" ~ component;
	}
	return normalized.length > 0 ? normalized : "/";
}

private SandboxPathOrigin originWithRawPath(SandboxPathOrigin origin,
	string rawPath)
{
	origin.detail = origin.detail.length == 0
		? rawPath
		: origin.detail ~ " (" ~ rawPath ~ ")";
	return origin;
}

private string pathError(string rawPath, string source, string detail)
{
	return format("invalid sandbox path %s from %s: %s", quotedPath(rawPath),
		source, detail);
}

private string quotedPath(string path)
{
	return "'" ~ path ~ "'";
}

private string writeRequirementConflict(string path,
	DeclaredSandboxPath declaration, PathAccess access,
	SandboxPathOrigin requirementOrigin)
{
	return format(
		"sandbox write requirement %s for normalized path %s from %s conflicts "
		~ "with configured %s declaration from %s",
		pathAccessName(access), quotedPath(path), describeOrigin(requirementOrigin),
		pathModeName(declaration.mode), describeOrigin(declaration.origin));
}

private bool isExplicitUserDeclaration(SandboxPathOriginKind kind)
{
	final switch (kind)
	{
	case SandboxPathOriginKind.globalConfig:
	case SandboxPathOriginKind.agentConfig:
	case SandboxPathOriginKind.workspaceConfig:
		return true;
	case SandboxPathOriginKind.builtinDefault:
	case SandboxPathOriginKind.agentRequirement:
	case SandboxPathOriginKind.launchRequirement:
	case SandboxPathOriginKind.taskReadOnly:
	case SandboxPathOriginKind.discoveryReadOnly:
	case SandboxPathOriginKind.exactReadOnly:
		return false;
	}
}

private bool isHostContent(PathMode mode)
{
	final switch (mode)
	{
	case PathMode.ro:
	case PathMode.rw:
	case PathMode.always_rw:
		return true;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		return false;
	}
}

private bool isWriteAccess(PathAccess access)
{
	return access == PathAccess.rw || access == PathAccess.alwaysRw;
}

private int pathAccessStrength(PathAccess access)
{
	final switch (access)
	{
	case PathAccess.ro: return 0;
	case PathAccess.rw: return 1;
	case PathAccess.alwaysRw: return 2;
	}
}

private int pathModeAccessStrength(PathMode mode)
{
	final switch (mode)
	{
	case PathMode.ro: return 0;
	case PathMode.rw: return 1;
	case PathMode.always_rw: return 2;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		assert(false, "mask modes have no access strength");
	}
}

private PathMode pathModeForAccess(PathAccess access)
{
	final switch (access)
	{
	case PathAccess.ro: return PathMode.ro;
	case PathAccess.rw: return PathMode.rw;
	case PathAccess.alwaysRw: return PathMode.always_rw;
	}
}

private PathMode strongerHostMode(PathMode left, PathMode right)
{
	return pathModeAccessStrength(left) >= pathModeAccessStrength(right)
		? left : right;
}

private int compareOrigins(SandboxPathOrigin left, SandboxPathOrigin right)
{
	if (left.kind != right.kind)
		return cast(int) left.kind < cast(int) right.kind ? -1 : 1;
	if (left.scope_ != right.scope_)
		return left.scope_ < right.scope_ ? -1 : 1;
	if (left.detail != right.detail)
		return left.detail < right.detail ? -1 : 1;
	return 0;
}

private string describeOrigin(SandboxPathOrigin origin)
{
	return format("%s(scope=%s, detail=%s)", originKindName(origin.kind),
		origin.scope_, origin.detail);
}

private string originKindName(SandboxPathOriginKind kind)
{
	final switch (kind)
	{
	case SandboxPathOriginKind.builtinDefault: return "builtinDefault";
	case SandboxPathOriginKind.globalConfig: return "globalConfig";
	case SandboxPathOriginKind.agentConfig: return "agentConfig";
	case SandboxPathOriginKind.workspaceConfig: return "workspaceConfig";
	case SandboxPathOriginKind.agentRequirement: return "agentRequirement";
	case SandboxPathOriginKind.launchRequirement: return "launchRequirement";
	case SandboxPathOriginKind.taskReadOnly: return "taskReadOnly";
	case SandboxPathOriginKind.discoveryReadOnly: return "discoveryReadOnly";
	case SandboxPathOriginKind.exactReadOnly: return "exactReadOnly";
	}
}

private string pathAccessName(PathAccess access)
{
	final switch (access)
	{
	case PathAccess.ro: return "ro";
	case PathAccess.rw: return "rw";
	case PathAccess.alwaysRw: return "alwaysRw";
	}
}

private string pathModeName(PathMode mode)
{
	final switch (mode)
	{
	case PathMode.ro: return "ro";
	case PathMode.rw: return "rw";
	case PathMode.always_rw: return "always_rw";
	case PathMode.tmpfs: return "tmpfs";
	case PathMode.empty_dir: return "empty_dir";
	case PathMode.empty_file: return "empty_file";
	}
}

version (unittest)
{
	import std.process : environment;

	private SandboxPathOrigin testOrigin(SandboxPathOriginKind kind,
		string sourceScope, string detail)
	{
		return SandboxPathOrigin(kind, sourceScope, detail);
	}

	private string assertFailureContains(void delegate() action,
		string[] expectedFragments)
	{
		bool thrown;
		string message;
		try
			action();
		catch (Exception e)
		{
			thrown = true;
			message = e.msg;
			foreach (fragment; expectedFragments)
				assert(e.msg.canFind(fragment), e.msg);
		}
		assert(thrown);
		return message;
	}

	private PathMode expectedRequirementMode(PathMode declaration,
		PathAccess access)
	{
		if (!isHostContent(declaration))
			return pathModeForAccess(access);
		return strongerHostMode(declaration, pathModeForAccess(access));
	}

	private void assertOriginEqual(SandboxPathOrigin left,
		SandboxPathOrigin right)
	{
		assert(left.kind == right.kind);
		assert(left.scope_ == right.scope_);
		assert(left.detail == right.detail);
	}

	private void assertViewsEqual(const SandboxPathView[] left,
		const SandboxPathView[] right)
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
				assertOriginEqual(leftView.declaration.get.origin,
					rightView.declaration.get.origin);
			}
			if (!leftView.requirement.isNull)
			{
				assert(leftView.requirement.get.access == rightView.requirement.get.access);
				assertOriginEqual(leftView.requirement.get.origin,
					rightView.requirement.get.origin);
			}
			if (!leftView.taskReadOnlyBy.isNull)
				assertOriginEqual(leftView.taskReadOnlyBy.get,
					rightView.taskReadOnlyBy.get);
			if (!leftView.finalReadOnlyBy.isNull)
				assertOriginEqual(leftView.finalReadOnlyBy.get,
					rightView.finalReadOnlyBy.get);
		}
	}

	unittest
	{
		auto oldHome = environment.get("HOME", "");
		scope (exit) environment["HOME"] = oldHome;
		environment["HOME"] = "/tmp/cydo-sandbox-paths-home";

		auto origin = testOrigin(SandboxPathOriginKind.builtinDefault,
			"normalization-scope", "normalization-detail");
		SandboxPaths paths;
		foreach (rawPath; ["~/state/./cache",
			"/tmp/cydo-sandbox-paths-home/state/cache",
			"/tmp/cydo-sandbox-paths-home/state//cache"])
			paths.set(rawPath, PathMode.ro, origin);
		auto normalized = paths.exact("/tmp/cydo-sandbox-paths-home/state//cache");
		assert(!normalized.isNull);
		assert(normalized.get.path == "/tmp/cydo-sandbox-paths-home/state/cache");
		assert(paths.snapshot.length == 1);

		paths.set("/", PathMode.ro, origin);
		assert(!paths.exact("/").isNull);

		foreach (rawPath; ["", "~unresolved-cydo-user/cache", "relative",
			"//leading", "/tmp/../target", "/tmp/trailing/"])
		{
			SandboxPaths invalid;
			assertFailureContains(() {
				invalid.set(rawPath, PathMode.ro, origin);
			}, [quotedPath(rawPath), origin.scope_, origin.detail]);
		}

		assertFailureContains(() {
			paths.exact("/query/../target");
		}, [quotedPath("/query/../target"), "query"]);

		SandboxPaths logicalAliases;
		logicalAliases.set("/does-not-need-to-exist/link", PathMode.ro, origin);
		logicalAliases.set("/does-not-need-to-exist/target", PathMode.ro, origin);
		assert(logicalAliases.snapshot.length == 2);
	}

	unittest
	{
		auto oldHome = environment.get("HOME", "");
		scope (exit) environment["HOME"] = oldHome;
		environment["HOME"] = "/tmp/cydo-config-layer-home";

		auto global = testOrigin(SandboxPathOriginKind.globalConfig,
			"global-layer", "global-detail");
		SandboxPaths aliases;
		aliases.applyConfigLayer([
			"~/state/./cache": PathMode.ro,
			"/tmp/cydo-config-layer-home/state//cache": PathMode.ro,
		], global);
		assert(aliases.snapshot.length == 1);
		assert(aliases.exact("/tmp/cydo-config-layer-home/state/cache").get
			.effectiveMode == PathMode.ro);
		SandboxPaths reversedAliases;
		reversedAliases.applyConfigLayer([
			"/tmp/cydo-config-layer-home/state//cache": PathMode.ro,
			"~/state/./cache": PathMode.ro,
		], global);
		assertViewsEqual(aliases.snapshot, reversedAliases.snapshot);

		auto firstRaw = "/layer/conflict";
		auto secondRaw = "/layer/./conflict";
		auto conflictMessage = assertFailureContains(() {
			aliases.applyConfigLayer([
				firstRaw: PathMode.ro,
				secondRaw: PathMode.rw,
			], global);
		}, [firstRaw, secondRaw, "ro", "rw", "/layer/conflict",
			global.scope_, global.detail]);
		auto reversedConflictMessage = assertFailureContains(() {
			aliases.applyConfigLayer([
				secondRaw: PathMode.rw,
				firstRaw: PathMode.ro,
			], global);
		}, [firstRaw, secondRaw, "ro", "rw", "/layer/conflict",
			global.scope_, global.detail]);
		assert(conflictMessage == reversedConflictMessage);

		SandboxPaths precedence;
		precedence.set("/ordered/./entry", PathMode.ro,
			testOrigin(SandboxPathOriginKind.builtinDefault, "default", "default"));
		assert(precedence.exact("/ordered/entry").get.declaration.get.mode
			== PathMode.ro);
		precedence.applyConfigLayer(["/ordered/entry": PathMode.rw], global);
		assert(precedence.exact("/ordered/entry").get.declaration.get.mode
			== PathMode.rw);
		precedence.applyConfigLayer(["/ordered//entry": PathMode.always_rw],
			testOrigin(SandboxPathOriginKind.agentConfig, "agent-layer", "agent-detail"));
		assert(precedence.exact("/ordered/entry").get.declaration.get.mode
			== PathMode.always_rw);
		precedence.applyConfigLayer(["/ordered/entry": PathMode.empty_dir],
			testOrigin(SandboxPathOriginKind.workspaceConfig, "workspace-layer",
				"workspace-detail"));
		auto winning = precedence.exact("/ordered/entry").get;
		assert(winning.declaration.get.mode == PathMode.empty_dir);
		assert(winning.declaration.get.origin.kind
			== SandboxPathOriginKind.workspaceConfig);
		assert(winning.declaration.get.origin.scope_ == "workspace-layer");
	}

	unittest
	{
		auto modes = [PathMode.ro, PathMode.rw, PathMode.always_rw,
			PathMode.tmpfs, PathMode.empty_dir, PathMode.empty_file];
		auto accesses = [PathAccess.ro, PathAccess.rw, PathAccess.alwaysRw];
		auto builtin = testOrigin(SandboxPathOriginKind.builtinDefault,
			"builtin", "builtin-default");
		auto configured = testOrigin(SandboxPathOriginKind.globalConfig,
			"configured-layer", "/configured/raw-key");
		auto requirement = testOrigin(SandboxPathOriginKind.agentRequirement,
			"requirement-scope", "requirement-detail");

		foreach (mode; modes)
		foreach (access; accesses)
		{
			SandboxPaths defaults;
			defaults.set("/defaults/table", mode, builtin);
			defaults.require("/defaults/table", access, requirement);
			auto defaultView = defaults.exact("/defaults/table").get;
			assert(defaultView.effectiveMode
				== expectedRequirementMode(mode, access));
			assert(!defaultView.requirement.isNull);
			assert(defaultView.requirement.get.access == access);

			SandboxPaths explicitUser;
			explicitUser.set("/configured/./table", mode, configured);
			auto rejectsWrite = isWriteAccess(access)
				&& (mode == PathMode.ro || !isHostContent(mode));
			if (rejectsWrite)
			{
				assertFailureContains(() {
					explicitUser.require("/configured//table", access, requirement);
				}, ["/configured/table", pathModeName(mode), configured.scope_,
					configured.detail, pathAccessName(access), requirement.scope_,
					requirement.detail]);
			}
			else
			{
				explicitUser.require("/configured//table", access, requirement);
				auto explicitView = explicitUser.exact("/configured/table").get;
				assert(explicitView.effectiveMode
					== expectedRequirementMode(mode, access));
				assert(!explicitView.requirement.isNull);
				assert(explicitView.requirement.get.access == access);
			}
		}

		foreach (kind; [SandboxPathOriginKind.agentConfig,
			SandboxPathOriginKind.workspaceConfig])
		{
			auto otherConfigured = testOrigin(kind, "other-configured-layer",
				"other-configured-detail");
			SandboxPaths explicitReadOnly;
			explicitReadOnly.set("/other-configured", PathMode.ro, otherConfigured);
			assertFailureContains(() {
				explicitReadOnly.require("/other-configured", PathAccess.alwaysRw,
					requirement);
			}, [otherConfigured.scope_, otherConfigured.detail,
				requirement.scope_, requirement.detail]);
		}

		SandboxPaths upward;
		upward.require("/joins", PathAccess.ro,
			testOrigin(SandboxPathOriginKind.launchRequirement, "z", "z"));
		upward.require("/joins", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.launchRequirement, "y", "y"));
		upward.require("/joins", PathAccess.alwaysRw,
			testOrigin(SandboxPathOriginKind.launchRequirement, "x", "x"));
		assert(upward.exact("/joins").get.effectiveMode == PathMode.always_rw);

		SandboxPaths reverse;
		reverse.require("/joins", PathAccess.alwaysRw,
			testOrigin(SandboxPathOriginKind.launchRequirement, "x", "x"));
		reverse.require("/joins", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.launchRequirement, "y", "y"));
		reverse.require("/joins", PathAccess.ro,
			testOrigin(SandboxPathOriginKind.launchRequirement, "z", "z"));
		assert(reverse.exact("/joins").get.effectiveMode == PathMode.always_rw);

		SandboxPaths equalStrength;
		equalStrength.require("/equal", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.launchRequirement, "z", "z"));
		equalStrength.require("/equal", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.agentRequirement, "a", "a"));
		auto joined = equalStrength.exact("/equal").get.requirement.get;
		assert(joined.origin.kind == SandboxPathOriginKind.agentRequirement);
		assert(joined.origin.scope_ == "a");

		SandboxPaths equalKind;
		equalKind.require("/equal-kind", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.agentRequirement, "z", "same-kind"));
		equalKind.require("/equal-kind", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.agentRequirement, "a", "same-kind"));
		assert(equalKind.exact("/equal-kind").get.requirement.get.origin.scope_
			== "a");

		SandboxPaths equalScope;
		equalScope.require("/equal-scope", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.agentRequirement, "scope", "z"));
		equalScope.require("/equal-scope", PathAccess.rw,
			testOrigin(SandboxPathOriginKind.agentRequirement, "scope", "a"));
		assert(equalScope.exact("/equal-scope").get.requirement.get.origin.detail
			== "a");

		SandboxPaths rwNoDowngrade;
		rwNoDowngrade.require("/rw-no-downgrade", PathAccess.rw, requirement);
		rwNoDowngrade.require("/rw-no-downgrade", PathAccess.ro, builtin);
		assert(rwNoDowngrade.exact("/rw-no-downgrade").get.effectiveMode
			== PathMode.rw);

		SandboxPaths noDowngrade;
		noDowngrade.require("/no-downgrade", PathAccess.alwaysRw, requirement);
		noDowngrade.require("/no-downgrade", PathAccess.ro, builtin);
		assert(noDowngrade.exact("/no-downgrade").get.effectiveMode
			== PathMode.always_rw);
	}

	unittest
	{
		auto configured = testOrigin(SandboxPathOriginKind.workspaceConfig,
			"workspace", "workspace-layer");
		auto reader = testOrigin(SandboxPathOriginKind.agentRequirement,
			"reader", "read visibility");
		auto writer = testOrigin(SandboxPathOriginKind.launchRequirement,
			"writer", "write requirement");
		foreach (mask; [PathMode.tmpfs, PathMode.empty_dir, PathMode.empty_file])
		{
			SandboxPaths paths;
			paths.applyConfigLayer(["/masked/./entry": mask], configured);
			paths.require("/masked//entry", PathAccess.ro, reader);
			auto pierced = paths.exact("/masked/entry").get;
			assert(pierced.effectiveMode == PathMode.ro);
			assert(pierced.declaration.get.mode == mask);
			assertFailureContains(() {
				paths.require("/masked/entry", PathAccess.rw, writer);
			}, ["/masked/entry", "/masked/./entry", pathModeName(mask),
				configured.scope_, configured.detail,
				writer.scope_, writer.detail]);
		}
	}

	unittest
	{
		auto modes = [PathMode.ro, PathMode.rw, PathMode.always_rw,
			PathMode.tmpfs, PathMode.empty_dir, PathMode.empty_file];
		auto declared = testOrigin(SandboxPathOriginKind.builtinDefault,
			"declared", "declared");
		auto task = testOrigin(SandboxPathOriginKind.taskReadOnly,
			"task", "task read-only");
		auto discovery = testOrigin(SandboxPathOriginKind.discoveryReadOnly,
			"discovery", "discovery read-only");
		auto exact = testOrigin(SandboxPathOriginKind.exactReadOnly,
			"exact", "exact read-only");

		foreach (mode; modes)
		{
			SandboxPaths taskPaths;
			taskPaths.set("/task", mode, declared);
			taskPaths.applyTaskReadOnly(task);
			auto taskView = taskPaths.exact("/task").get;
			assert(taskView.effectiveMode
				== (mode == PathMode.rw ? PathMode.ro : mode));
			assert(taskView.taskReadOnlyBy.isNull == (mode != PathMode.rw));

			SandboxPaths discoveryPaths;
			discoveryPaths.set("/discovery", mode, declared);
			discoveryPaths.applyDiscoveryReadOnly(discovery);
			auto discoveryView = discoveryPaths.exact("/discovery").get;
			auto discoveryExpected = mode == PathMode.rw || mode == PathMode.always_rw
				? PathMode.ro : mode;
			assert(discoveryView.effectiveMode == discoveryExpected);
			assert(discoveryView.finalReadOnlyBy.isNull
				== !(mode == PathMode.rw || mode == PathMode.always_rw));

			SandboxPaths exactPaths;
			exactPaths.set("/exact", mode, declared);
			exactPaths.restrictExactToReadOnly("/exact", exact);
			auto exactView = exactPaths.exact("/exact").get;
			assert(exactView.effectiveMode
				== (isHostContent(mode) ? PathMode.ro : mode));
			assert(exactView.finalReadOnlyBy.isNull == !isHostContent(mode));
		}

		auto userRw = testOrigin(SandboxPathOriginKind.globalConfig,
			"user-rw", "/user/rw");
		auto userRo = testOrigin(SandboxPathOriginKind.globalConfig,
			"user-ro", "/user/ro");
		auto writer = testOrigin(SandboxPathOriginKind.agentRequirement,
			"writer", "restore write");
		SandboxPaths restorable;
		restorable.set("/restorable", PathMode.rw, userRw);
		restorable.applyTaskReadOnly(task);
		assert(restorable.exact("/restorable").get.effectiveMode == PathMode.ro);
		restorable.require("/restorable", PathAccess.rw, writer);
		assert(restorable.exact("/restorable").get.effectiveMode == PathMode.rw);
		restorable.require("/restorable", PathAccess.alwaysRw, writer);
		assert(restorable.exact("/restorable").get.effectiveMode
			== PathMode.always_rw);

		SandboxPaths explicitRo;
		explicitRo.set("/explicit-ro", PathMode.ro, userRo);
		explicitRo.applyTaskReadOnly(task);
		assertFailureContains(() {
			explicitRo.require("/explicit-ro", PathAccess.rw, writer);
		}, [userRo.scope_, userRo.detail, writer.scope_, writer.detail]);

		SandboxPaths capped;
		capped.set("/cap", PathMode.rw, declared);
		capped.restrictExactToReadOnly("/cap", exact);
		capped.require("/cap", PathAccess.alwaysRw, writer);
		auto capView = capped.exact("/cap").get;
		assert(capView.effectiveMode == PathMode.ro);
		assert(!capView.finalReadOnlyBy.isNull);

		SandboxPaths discoveryCapped;
		discoveryCapped.set("/discovery-cap", PathMode.rw, declared);
		discoveryCapped.applyDiscoveryReadOnly(discovery);
		discoveryCapped.require("/discovery-cap", PathAccess.alwaysRw, writer);
		assert(discoveryCapped.exact("/discovery-cap").get.effectiveMode
			== PathMode.ro);
	}

	unittest
	{
		auto declaration = testOrigin(SandboxPathOriginKind.builtinDefault,
			"declaration", "visibility declaration");
		auto requirement = testOrigin(SandboxPathOriginKind.agentRequirement,
			"visibility", "visibility requirement");

		SandboxPaths noAncestor;
		noAncestor.requireReadVisible("/no-ancestor/child", requirement);
		assert(noAncestor.exact("/no-ancestor/child").get.effectiveMode == PathMode.ro);

		SandboxPaths nearestRo;
		nearestRo.set("/tree", PathMode.ro, declaration);
		nearestRo.requireReadVisible("/tree/child", requirement);
		assert(!nearestRo.exact("/tree/child").isNull);

		SandboxPaths nearestRw;
		nearestRw.set("/tree", PathMode.rw, declaration);
		nearestRw.requireReadVisible("/tree/child", requirement);
		assert(nearestRw.exact("/tree/child").isNull);

		SandboxPaths nearestAlwaysRw;
		nearestAlwaysRw.set("/tree", PathMode.always_rw, declaration);
		nearestAlwaysRw.requireReadVisible("/tree/child", requirement);
		assert(nearestAlwaysRw.exact("/tree/child").isNull);

		SandboxPaths nearerRo;
		nearerRo.set("/tree", PathMode.rw, declaration);
		nearerRo.set("/tree/near", PathMode.ro, declaration);
		nearerRo.requireReadVisible("/tree/near/child", requirement);
		assert(!nearerRo.exact("/tree/near/child").isNull);

		SandboxPaths nearerMask;
		nearerMask.set("/tree", PathMode.rw, declaration);
		nearerMask.set("/tree/near", PathMode.tmpfs, declaration);
		nearerMask.requireReadVisible("/tree/near/child", requirement);
		assert(!nearerMask.exact("/tree/near/child").isNull);

		SandboxPaths exactMask;
		exactMask.set("/exact-mask", PathMode.empty_dir, declaration);
		exactMask.requireReadVisible("/exact-mask", requirement);
		auto exactMaskView = exactMask.exact("/exact-mask").get;
		assert(exactMaskView.effectiveMode == PathMode.ro);
		assert(exactMaskView.declaration.get.mode == PathMode.empty_dir);

		SandboxPaths componentBoundary;
		componentBoundary.set("/tree", PathMode.rw, declaration);
		componentBoundary.requireReadVisible("/treehouse/child", requirement);
		assert(!componentBoundary.exact("/treehouse/child").isNull);
	}

	unittest
	{
		auto declaration = testOrigin(SandboxPathOriginKind.builtinDefault,
			"hierarchy", "hierarchy declaration");
		auto requirement = testOrigin(SandboxPathOriginKind.agentRequirement,
			"hierarchy", "hierarchy requirement");
		auto masks = [PathMode.tmpfs, PathMode.empty_dir, PathMode.empty_file];
		auto hostModes = [PathMode.ro, PathMode.rw, PathMode.always_rw];
		foreach (mask; masks)
		foreach (host; hostModes)
		foreach (parentFirst; [true, false])
		{
			SandboxPaths paths;
			if (parentFirst)
			{
				paths.set("/tree", mask, declaration);
				paths.set("/tree/public", host, declaration);
			}
			else
			{
				paths.set("/tree/public", host, declaration);
				paths.set("/tree", mask, declaration);
			}
			assert(paths.snapshot.length == 2);
			assert(paths.exact("/tree").get.declaration.get.mode == mask);
			assert(paths.exact("/tree/public").get.declaration.get.mode == host);
		}

		foreach (pair; [
			[PathMode.ro, PathMode.empty_dir],
			[PathMode.tmpfs, PathMode.empty_file],
			[PathMode.ro, PathMode.rw],
			[PathMode.ro, PathMode.always_rw],
			[PathMode.rw, PathMode.ro],
		])
		{
			SandboxPaths paths;
			paths.set("/parent", pair[0], declaration);
			paths.set("/parent/child", pair[1], declaration);
			assert(paths.snapshot.length == 2);
			assert(paths.exact("/parent").get.declaration.get.mode == pair[0]);
			assert(paths.exact("/parent/child").get.declaration.get.mode == pair[1]);
		}

		SandboxPaths exactChild;
		exactChild.set("/masked-parent", PathMode.tmpfs, declaration);
		exactChild.require("/masked-parent/child", PathAccess.rw, requirement);
		assert(exactChild.exact("/masked-parent").get.effectiveMode
			== PathMode.tmpfs);
		assert(exactChild.exact("/masked-parent/child").get.effectiveMode
			== PathMode.rw);
	}

	unittest
	{
		auto declaration = testOrigin(SandboxPathOriginKind.builtinDefault,
			"copy", "copy declaration");
		auto requirement = testOrigin(SandboxPathOriginKind.launchRequirement,
			"copy", "copy requirement");
		SandboxPaths original;
		original.set("/copy/a", PathMode.ro, declaration);
		original.set("/copy/b", PathMode.rw, declaration);

		auto constructed = original;
		constructed.require("/copy/a", PathAccess.alwaysRw, requirement);
		assert(original.exact("/copy/a").get.effectiveMode == PathMode.ro);
		assert(constructed.exact("/copy/a").get.effectiveMode == PathMode.always_rw);

		SandboxPaths assigned;
		assigned = original;
		assigned.require("/copy/b", PathAccess.alwaysRw, requirement);
		assert(original.exact("/copy/b").get.effectiveMode == PathMode.rw);
		assert(assigned.exact("/copy/b").get.effectiveMode == PathMode.always_rw);

		auto detachedExact = constructed.exact("/copy/a").get;
		detachedExact.effectiveMode = PathMode.ro;
		assert(constructed.exact("/copy/a").get.effectiveMode == PathMode.always_rw);

		auto detachedSnapshot = constructed.snapshot;
		detachedSnapshot[0] = SandboxPathView.init;
		auto swap = detachedSnapshot[0];
		detachedSnapshot[0] = detachedSnapshot[1];
		detachedSnapshot[1] = swap;
		assert(constructed.exact("/copy/a").get.effectiveMode == PathMode.always_rw);
		auto snapshotAfterMutation = constructed.snapshot;
		assert(snapshotAfterMutation.length == 2);
		assert(snapshotAfterMutation[0].path == "/copy/a");
		assert(snapshotAfterMutation[0].effectiveMode == PathMode.always_rw);
		assert(snapshotAfterMutation[1].path == "/copy/b");
		assert(snapshotAfterMutation[1].effectiveMode == PathMode.rw);

		SandboxPaths forward;
		forward.set("/order/z", PathMode.rw, declaration);
		forward.set("/order/a", PathMode.ro, declaration);
		SandboxPaths reverse;
		reverse.set("/order/a", PathMode.ro, declaration);
		reverse.set("/order/z", PathMode.rw, declaration);
		auto forwardSnapshot = forward.snapshot;
		assert(forwardSnapshot[0].path == "/order/a");
		assert(forwardSnapshot[1].path == "/order/z");
		assertViewsEqual(forwardSnapshot, reverse.snapshot);
	}
}
