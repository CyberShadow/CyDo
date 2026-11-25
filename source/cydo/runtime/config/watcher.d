module cydo.runtime.config.watcher;

import core.stdc.errno : ENOENT, ENOTDIR;
import core.sys.posix.sys.stat : S_ISDIR, S_ISLNK;
import core.time : msecs;
import std.exception : ErrnoException;
import std.file : exists, FileException, getLinkAttributes, readLink;
import std.logger : warningf;
import std.path : baseName, buildPath, dirName;

import ae.sys.inotify : INotify;
import ae.sys.timing : setTimeout, TimerTask;

import cydo.foundation.platform.inotify : KernelINotify;
import cydo.foundation.platform.path : directoryEntryPaths;
import cydo.runtime.config : configPath;
import cydo.runtime.config.paths : userTaskTypesPath;

package(cydo):

struct ConfigWatcherHost
{
	void delegate() onConfigChanged;
	void delegate(string projectPath) onProjectConfigChanged;
	void delegate() onUserTaskTypesChanged;
}

class ConfigWatcher
{
	private enum watchMask = INotify.Mask.create | INotify.Mask.remove | INotify.Mask.move
		| INotify.Mask.closeWrite | INotify.Mask.attrib | INotify.Mask.onlyDir;

	private enum Kind { config, userTaskTypes, project }

	private static struct Scope
	{
		Kind kind;
		string project;
	}

	private static struct Interest
	{
		Scope[][string] named;
		Scope[] anyName;
	}

	private ConfigWatcherHost host_;
	private KernelINotify kernel_;
	private Interest[int] interest_;
	private bool[string] projects_;
	private bool[Scope] dirty_;
	private TimerTask flush_;

	this(ConfigWatcherHost host)
	{
		host_ = host;
	}

	void start()
	{
		kernel_ = new KernelINotify(&onEvent);
		auto cfgDir = dirName(configPath());
		if (!exists(cfgDir))
			warningf("Config directory %s does not exist, skipping config watch", cfgDir);
		reconcile();
	}

	void stop()
	{
		if (flush_ !is null)
			flush_.cancel();
		flush_ = null;
		kernel_.close();
		interest_ = null;
		projects_ = null;
		dirty_ = null;
	}

	void ensureProjectWatch(string projectPath)
	{
		if (projectPath in projects_)
			return;
		projects_[projectPath] = true;
		reconcile();
	}

	string[] watchedProjects()
	{
		return projects_.keys;
	}

private:
	void reconcile()
	{
		Interest[int] next;

		void watchDir(string dir, Scope target, string[] names...)
		{
			int wd;
			if (!probe(dir, { wd = kernel_.add(dir, watchMask); }))
				return;
			auto interest = &next.require(wd);
			if (names.length == 0)
				interest.anyName ~= target;
			else
				foreach (name; names)
					interest.named[name] ~= target;
		}

		void follow(string path, Scope target, scope void delegate(string, Scope) onDir = null)
		{
			// Inspect the final target as well as up to 40 symlinks.
			enum maxSymlinks = 40;
			foreach (hop; 0 .. maxSymlinks + 1)
			{
				uint attributes;
				if (!probe(path, { attributes = getLinkAttributes(path); }))
					return;
				if (S_ISDIR(attributes))
				{
					if (onDir !is null)
						onDir(path, target);
					return;
				}
				if (!S_ISLNK(attributes) || hop == maxSymlinks)
					return;
				if (!probe(path, { path = buildPath(dirName(path), readLink(path)); }))
					return;
				// Inspect the last named component before the kernel follows it.
				while (path.length > 1)
				{
					if (path[$ - 1] == '/' || path[$ - 2 .. $] == "/.")
						path = path[0 .. $ - 1];
					else
						break;
				}
				watchDir(dirName(path), target, baseName(path));
			}
		}

		void packDir(string dir, Scope target)
		{
			watchDir(dir, target, "task-types.yaml");
			follow(buildPath(dir, "task-types.yaml"), target);
		}

		void packsDir(string dir, Scope target)
		{
			watchDir(dir, target);
			string[] entries;
			if (probe(dir, { entries = directoryEntryPaths(dir); }))
				foreach (entry; entries)
					follow(entry, target, &packDir);
		}

		void cydoDir(string dir, Scope target)
		{
			watchDir(dir, target, "task-types.yaml", "defs", "packs");
			follow(buildPath(dir, "task-types.yaml"), target);
			follow(buildPath(dir, "packs"), target, &packsDir);
		}

		auto cfgPath = configPath();
		auto cfgDir = dirName(cfgPath);
		auto config = Scope(Kind.config);
		auto user = Scope(Kind.userTaskTypes);
		watchDir(cfgDir, config, baseName(cfgPath));
		watchDir(cfgDir, user, "task-types.yaml", "packs");
		follow(cfgPath, config);
		follow(userTaskTypesPath(), user);
		follow(buildPath(cfgDir, "packs"), user, &packsDir);
		foreach (project; projects_.keys)
		{
			auto target = Scope(Kind.project, project);
			watchDir(project, target, ".cydo");
			follow(buildPath(project, ".cydo"), target, &cydoDir);
		}

		foreach (wd; interest_.keys)
			if (wd !in next)
				kernel_.remove(wd);
		interest_ = next;
	}

	void onEvent(int wd, in char[] name, INotify.Mask mask)
	{
		if (mask & INotify.Mask.qOverflow)
		{
			dirty_[Scope(Kind.config)] = true;
			dirty_[Scope(Kind.userTaskTypes)] = true;
			foreach (project; projects_.keys)
				dirty_[Scope(Kind.project, project)] = true;
		}
		else if (name.length > 0)
		{
			if (auto interest = wd in interest_)
			{
				if (auto named = name in interest.named)
					foreach (target; *named)
						dirty_[target] = true;
				foreach (target; interest.anyName)
					dirty_[target] = true;
			}
		}
		if (dirty_.length > 0 && flush_ is null)
			flush_ = setTimeout(&flush, 0.msecs);
	}

	void flush()
	{
		flush_ = null;
		reconcile();
		auto dirty = dirty_;
		dirty_ = null;
		foreach (target; dirty.keys)
			final switch (target.kind)
			{
				case Kind.config: host_.onConfigChanged(); break;
				case Kind.userTaskTypes: host_.onUserTaskTypesChanged(); break;
				case Kind.project: host_.onProjectConfigChanged(target.project); break;
			}
	}

	static bool probe(string path, scope void delegate() query)
	{
		uint code;
		string message;
		try
		{
			query();
			return true;
		}
		catch (FileException e)
		{
			code = e.errno;
			message = e.msg;
		}
		catch (ErrnoException e)
		{
			code = e.errno;
			message = e.msg;
		}
		if (code != ENOENT && code != ENOTDIR)
			warningf("Could not watch configuration path %s: %s", path, message);
		return false;
	}
}

unittest
{
	import core.time : MonoTime, msecs, seconds;
	import std.algorithm : sort;
	import std.conv : octal;
	import std.file : mkdir, mkdirRecurse, remove, rename, rmdir, rmdirRecurse,
		setAttributes, symlink, tempDir, write;
	import std.format : format;
	import std.process : environment;

	import ae.net.asockets : socketManager;

	import cydo.domain.task_types.catalog : TaskTypeCatalog;
	import cydo.domain.task_types.definition : byName;

	auto root = buildPath(tempDir, "cydo-test-config-pack-watcher");
	auto home = buildPath(root, "home");
	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	environment["HOME"] = home;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		rmdirRecurse(root);
	}

	auto userConfig = dirName(configPath());
	auto userPacks = buildPath(userConfig, "packs");
	auto userPack = buildPath(userPacks, "user-pack");
	auto project = buildPath(root, "project");
	auto otherProject = buildPath(root, "other-project");
	auto projectPacks = buildPath(project, ".cydo", "packs");
	auto projectPack = buildPath(projectPacks, "project-pack");
	auto targets = buildPath(root, "targets");
	auto stagedPack = buildPath(targets, "staged-pack");
	auto middle = buildPath(root, "middle");
	auto hop = buildPath(middle, "hop");
	auto replacement = buildPath(root, "replacement.yaml");
	auto replacementPack = buildPath(root, "replacement-pack");
	auto movedTarget = buildPath(root, "moved-target");
	auto replacementHop = buildPath(root, "replacement-hop");
	auto shipped = buildPath(root, "shipped");
	enum yamlName = "task-types.yaml";
	enum base = "task_types:\n  sample:\n    agent_description: ";
	mkdirRecurse(userConfig);
	mkdirRecurse(projectPacks);
	mkdirRecurse(otherProject);
	mkdirRecurse(middle);
	mkdirRecurse(stagedPack);
	symlink("../targets/staged-pack", hop);
	symlink(movedTarget, replacementHop);
	mkdirRecurse(replacementPack);
	mkdirRecurse(buildPath(shipped, "prompts"));
	write(buildPath(shipped, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(shipped, yamlName), base ~ "shipped\n");
	write(buildPath(stagedPack, yamlName), base ~ "original\n");
	write(buildPath(replacementPack, yamlName), base ~ "replacement\n");
	write(replacement, base ~ "user pack\n");
	auto catalog = new TaskTypeCatalog(shipped, buildPath(shipped, yamlName),
		(string name) => true);
	assert(catalog.getTaskTypesForProject(project).byName("sample").agent_description == "shipped");
	auto otherSnapshot = catalog.getTaskTypesForProject(otherProject);
	assert(otherSnapshot.byName("sample").agent_description == "shipped");

	auto cfg = configPath();
	auto late = buildPath(root, "late-project");
	auto latePack = buildPath(late, ".cydo", "packs", "pack");
	auto sharedDir = buildPath(root, "shared");
	auto sharedYaml = buildPath(sharedDir, "pack.yaml");
	auto replacementYamlLink = buildPath(sharedDir, "link");
	auto dangling = buildPath(root, "late-target");
	auto locked = buildPath(root, "locked");
	auto lockedPack = buildPath(projectPacks, "zz-locked");
	auto lockedYaml = buildPath(lockedPack, yamlName);
	auto rapid = buildPath(userPacks, "rapid");
	auto rapidFinal = buildPath(userPacks, "zz-rapid-final");
	auto projectYaml = buildPath(project, ".cydo", yamlName);
	auto userYaml = buildPath(userConfig, yamlName);
	auto stagedYaml = buildPath(root, "staged.yaml");
	mkdir(late);
	mkdir(sharedDir);
	mkdir(locked);
	write(cfg, "original");
	write(sharedYaml, base ~ "shared pack\n");
	symlink(sharedYaml, replacementYamlLink);
	write(buildPath(locked, yamlName), base ~ "locked pack\n");
	scope (exit)
	{
		if (exists(lockedPack))
			setAttributes(lockedPack, octal!700);
		if (exists(locked))
			setAttributes(locked, octal!700);
	}

	ConfigWatcher watcher;
	int[] descriptorsBeforeMove;
	int movedDescriptor;
	struct Step
	{
		string name;
		string[] expected;
		void delegate() change;
		string expectedDescription;
		string expectedOther = "shipped";
		void delegate() verify;
	}
	Step[] steps = [
		Step("create user packs directory", ["user"], { mkdirRecurse(userPacks); }),
		Step("add user pack", ["user"], { mkdirRecurse(userPack); }),
		Step("alias the already watched user config directory", ["user"],
			{ symlink(userConfig, buildPath(userPacks, "local")); }),
		Step("move in project pack", [project], {
			descriptorsBeforeMove = watcher.interest_.keys;
			rename(stagedPack, projectPack);
		}, "original", "shipped", {
			assert(watcher.interest_.length == descriptorsBeforeMove.length + 1);
			import std.algorithm : canFind;
			foreach (wd; watcher.interest_.keys)
				if (!descriptorsBeforeMove.canFind(wd))
					movedDescriptor = wd;
		}),
		Step("write project pack YAML", [project],
			{ write(buildPath(projectPack, yamlName), base ~ "edited regular pack\n"); }, "edited regular pack"),
		Step("move out project pack", [project], { rename(projectPack, stagedPack); }, "shipped", "shipped", {
			assert(watcher.interest_.length == descriptorsBeforeMove.length);
			auto wd = watcher.kernel_.add(stagedPack, ConfigWatcher.watchMask);
			scope (exit) watcher.kernel_.remove(wd);
			assert(wd != movedDescriptor, "The kernel still watches the retired directory");
		}),
		Step("replace user pack YAML", ["user"],
			{ rename(replacement, buildPath(userPack, yamlName)); }, "user pack", "user pack"),
		Step("activate a two-hop project pack symlink ending in /.", [project],
			{ symlink(hop ~ "/././", projectPack); }, "edited regular pack", "user pack"),
		Step("move the final pack target away", [project],
			{ rename(stagedPack, movedTarget); }, "user pack", "user pack"),
		Step("replace the final pack target", [project],
			{ rename(replacementPack, stagedPack); }, "replacement", "user pack"),
		Step("write to the replacement target", [project],
			{ write(buildPath(stagedPack, yamlName), base ~ "edited\n"); }, "edited", "user pack"),
		Step("replace the middle symlink", [project],
			{ rename(replacementHop, hop); }, "edited regular pack", "user pack"),
		Step("write config.yaml", ["config"], { write(cfg, "updated"); }, null, "user pack"),
		Step("delete config.yaml", ["config"], { remove(cfg); }, null, "user pack"),
		Step("arm late project before creating its configuration", [late], {
			watcher.ensureProjectWatch(late);
			mkdirRecurse(latePack);
		}, null, "user pack"),
		Step("symlink pack YAML to an external file", [project],
			{ rename(replacementYamlLink, buildPath(movedTarget, yamlName)); }, "shared pack", "user pack"),
		Step("write through the external YAML target", [project],
			{ write(sharedYaml, base ~ "shared pack edit\n"); }, "shared pack edit", "user pack"),
		Step("create a dangling user pack symlink", ["user"],
			{ symlink(dangling, buildPath(userPacks, "z-late")); }, "shared pack edit", "user pack"),
		Step("create the dangling pack target", ["user"], {
			mkdir(dangling);
			write(buildPath(dangling, yamlName), base ~ "late pack\n");
		}, "shared pack edit", "late pack"),
		Step("alias a user pack from a project", [project],
			{ symlink(userPack, buildPath(projectPacks, "shared-user")); }, "user pack", "late pack"),
		Step("write the aliased user pack YAML", ["user", project],
			{ write(buildPath(userPack, yamlName), base ~ "shared alias edit\n"); }, "shared alias edit", "late pack"),
		Step("move in a directory without read permission", [project], {
			setAttributes(locked, octal!300);
			rename(locked, lockedPack);
		}, "locked pack", "late pack"),
		Step("restore read permission", [project],
			{ setAttributes(lockedPack, octal!700); }, "locked pack", "late pack"),
		Step("write the readable pack YAML", [project],
			{ write(lockedYaml, base ~ "locked edited\n"); }, "locked edited", "late pack"),
		Step("coalesce rapid directory churn", ["user"], {
			foreach (_; 0 .. 200)
			{
				mkdir(rapid);
				rmdir(rapid);
			}
			mkdir(rapidFinal);
			write(buildPath(rapidFinal, yamlName), base ~ "churn pack\n");
		}, "locked edited", "churn pack"),
		Step("write the pack left after churn", ["user"],
			{ write(buildPath(rapidFinal, yamlName), base ~ "churn saved\n"); }, "locked edited", "churn saved"),
		Step("create project task-types.yaml", [project], {
			write(stagedYaml, base ~ "project file\n");
			rename(stagedYaml, projectYaml);
		}, "project file", "churn saved"),
		Step("delete project task-types.yaml", [project],
			{ remove(projectYaml); }, "locked edited", "churn saved"),
		Step("recreate project task-types.yaml", [project], {
			write(stagedYaml, base ~ "project recreated\n");
			rename(stagedYaml, projectYaml);
		}, "project recreated", "churn saved"),
		Step("create user task-types.yaml", ["user"], {
			write(stagedYaml, base ~ "user file\n");
			rename(stagedYaml, userYaml);
		}, "project recreated", "user file"),
		Step("delete user task-types.yaml", ["user"],
			{ remove(userYaml); }, "project recreated", "churn saved"),
		Step("recreate user task-types.yaml", ["user"], {
			write(stagedYaml, base ~ "user recreated\n");
			rename(stagedYaml, userYaml);
		}, "project recreated", "user recreated"),
		Step("mark every scope after kernel queue overflow", ["config", "user", project, otherProject, late],
			{ watcher.onEvent(-1, "", INotify.Mask.qOverflow); }, "project recreated", "user recreated"),
	];

	size_t nextStep;
	bool waiting;
	bool stopped;
	bool[string] notifiedScopes;
	void stop()
	{
		watcher.stop();
		stopped = true;
	}

	void finishStep()
	{
		auto step = steps[nextStep];
		assert(notifiedScopes.length > 0, "Missing notification for " ~ step.name);
		assert(sort(notifiedScopes.keys).release == sort(step.expected.dup).release,
			step.name ~ ": unexpected notification scopes");
		if ("user" in notifiedScopes)
			catalog.invalidateAll();
		else
			foreach (path; notifiedScopes.keys)
				if (path != "config")
					catalog.invalidateProject(path);

		auto other = catalog.getTaskTypesForProject(otherProject);
		if (step.expected == [project])
			assert(other is otherSnapshot, "Project pack event invalidated another project's cache");
		assert(other.byName("sample").agent_description == step.expectedOther, step.name);
		otherSnapshot = other;
		if (step.expectedDescription.length > 0)
			assert(catalog.getTaskTypesForProject(project).byName("sample").agent_description
				== step.expectedDescription, step.name);
		if (step.verify !is null)
			step.verify();

		waiting = false;
		notifiedScopes = null;
		++nextStep;
	}

	void notified(string label)
	{
		assert(waiting, "Notification outside a watcher test step");
		assert(label !in notifiedScopes, "Duplicate notification during " ~ steps[nextStep].name);
		notifiedScopes[label] = true;
	}

	size_t previousBytes;
	TimerTask previousFlush;
	MonoTime lastProgress;

	void applyStep()
	{
		waiting = true;
		steps[nextStep].change();
		previousBytes = watcher.kernel_.pendingBytes();
		previousFlush = watcher.flush_;
		lastProgress = MonoTime.currTime();
	}

	void settle()
	{
		// The mutation queues inotify events synchronously. Let the loop read them
		// and run the deferred flush before checking the callbacks.
		auto pendingBytes = watcher.kernel_.pendingBytes();
		auto flush = watcher.flush_;
		if (pendingBytes == 0 && flush is null)
		{
			finishStep();
			if (nextStep == steps.length)
			{
				stop();
				return;
			}
			applyStep();
		}
		else
		{
			// Check liveness after observing I/O and flush progress on this turn.
			auto now = MonoTime.currTime();
			if (pendingBytes < previousBytes || flush !is previousFlush)
				lastProgress = now;
			assert(now - lastProgress < 60.seconds,
				format("watcher did not settle after %s (pendingBytes=%s, flush pending=%s)",
					steps[nextStep].name, pendingBytes, flush !is null));
			previousBytes = pendingBytes;
			previousFlush = flush;
		}
		setTimeout(&settle, 0.msecs);
	}

	watcher = new ConfigWatcher(ConfigWatcherHost(
		{ notified("config"); },
		&notified,
		{ notified("user"); },
	));
	watcher.start();
	scope (exit) if (!stopped) stop();
	watcher.ensureProjectWatch(project);
	watcher.ensureProjectWatch(otherProject);

	applyStep();
	setTimeout(&settle, 0.msecs);
	socketManager.loop();
	assert(nextStep == steps.length);
}
