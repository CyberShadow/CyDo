module cydo.runtime.config.watcher;

import core.stdc.errno : ENOENT, ENOTDIR;
import core.sys.posix.sys.stat : S_ISDIR, S_ISLNK;
import core.time : Duration, MonoTime, msecs;
import std.exception : ErrnoException;
import std.file : exists, FileException, getLinkAttributes, readLink;
import std.logger : warningf;
import std.path : baseName, buildPath, dirName;

import ae.sys.inotify : INotify;
import ae.sys.timing : mainTimer, setTimeout, TimerTask;

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

/// Reconcile every read before attributing records.
/// Track exact dirent interest and per-scope directory ownership.
/// Attribute named content records to their final owners.
/// Append an incomplete event for losses or unobserved gains.
/// The last attributed content event sets the deadline. Metadata only schedules idle scopes.
/// Snapshot ownership and observation after each batch, with a registration baseline for new projects.
class ConfigWatcher
{
	private enum watchMask = INotify.Mask.create | INotify.Mask.remove | INotify.Mask.move
		| INotify.Mask.modify | INotify.Mask.closeWrite | INotify.Mask.attrib | INotify.Mask.onlyDir;
	private enum completeMask = INotify.Mask.closeWrite | INotify.Mask.movedTo;
	private enum incompleteMask = INotify.Mask.create | INotify.Mask.remove | INotify.Mask.movedFrom
		| INotify.Mask.modify;

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

	private static struct WatchEvent
	{
		int wd;
		string name;
		INotify.Mask mask;
	}

	private ConfigWatcherHost host_;
	private KernelINotify kernel_;
	private Interest[int] interest_;
	private bool[int][Scope] owned_;
	private bool[int][Scope] baseline_;
	private bool[int] observed_;
	version (unittest) private void delegate(const(WatchEvent)[], MonoTime) batchObserver_;
	private bool[string] projects_;
	private MonoTime[Scope] dirty_;
	private WatchEvent[] batch_;
	private TimerTask flush_;
	private Duration graceDelay_;

	this(ConfigWatcherHost host, Duration graceDelay = 100.msecs)
	{
		host_ = host;
		graceDelay_ = graceDelay;
	}

	void start()
	{
		kernel_ = new KernelINotify(&onEvent, &onBatch);
		auto cfgDir = dirName(configPath());
		if (!exists(cfgDir))
			warningf("Config directory %s does not exist, skipping config watch", cfgDir);
		reconcile();
		resetWindow();
	}

	void stop()
	{
		if (flush_ !is null)
			flush_.cancel();
		flush_ = null;
		kernel_.close();
		interest_ = null;
		owned_ = null;
		baseline_ = null;
		observed_ = null;
		batch_ = null;
		projects_ = null;
		dirty_ = null;
	}

	void ensureProjectWatch(string projectPath)
	{
		if (projectPath in projects_)
			return;
		projects_[projectPath] = true;
		reconcile();
		// The initial catalog load covers the new project's registration state.
		auto target = Scope(Kind.project, projectPath);
		baseline_[target] = owned_[target];
	}

	string[] watchedProjects()
	{
		return projects_.keys;
	}

private:
	Scope[] scopes()
	{
		Scope[] targets = [Scope(Kind.config), Scope(Kind.userTaskTypes)];
		foreach (project; projects_.byKey)
			targets ~= Scope(Kind.project, project);
		return targets;
	}

	void resetWindow()
	{
		baseline_ = owned_.dup;
		observed_ = null;
		foreach (wd; interest_.byKey)
			observed_[wd] = true;
	}

	void reconcile()
	{
		Interest[int] next;
		bool[int][Scope] nextOwned;
		foreach (target; scopes())
			nextOwned[target] = null;

		void watchDir(string dir, Scope target, string[] names...)
		{
			int wd;
			if (!probe(dir, { wd = kernel_.add(dir, watchMask); }))
				return;
			nextOwned[target][wd] = true;
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
		owned_ = nextOwned;
	}

	void onEvent(int wd, in char[] name, INotify.Mask mask)
	{
		// A retired descriptor cannot become owned again in this watch lifetime.
		if ((mask & INotify.Mask.qOverflow) || wd in interest_)
			batch_ ~= WatchEvent(wd, name.idup, mask);
	}

	void onBatch()
	{
		auto records = batch_;
		batch_ = null;
		reconcile();
		auto now = MonoTime.currTime();
		auto targets = scopes();

		void mark(Scope target, bool complete, bool metadataOnly = false)
		{
			if (metadataOnly)
				dirty_.require(target, now);
			else
				dirty_[target] = complete ? now : now + graceDelay_;
		}

		foreach (record; records)
		{
			if (record.mask & INotify.Mask.qOverflow)
			{
				foreach (target; targets)
					mark(target, true);
				continue;
			}
			bool complete = (record.mask & completeMask) != 0;
			bool metadataOnly = !complete && !(record.mask & incompleteMask);
			if (record.name.length == 0 || (metadataOnly && !(record.mask & INotify.Mask.attrib)))
				continue;
			if (auto interest = record.wd in interest_)
			{
				foreach (target; interest.named.get(record.name, null))
					mark(target, complete, metadataOnly);
				foreach (target; interest.anyName)
					mark(target, complete, metadataOnly);
			}
		}
		foreach (target; targets)
			if (structureUnordered(target))
				mark(target, false);
		resetWindow();
		version (unittest)
			if (batchObserver_ !is null)
				batchObserver_(records, now);
		scheduleFlush();
	}

	bool structureUnordered(Scope target)
	{
		auto before = baseline_[target];
		auto after = owned_[target];
		foreach (wd; before.byKey)
			if (wd !in after)
				return true;
		foreach (wd; after.byKey)
			if (wd !in before && wd !in observed_)
				return true;
		return false;
	}

	void scheduleFlush()
	{
		import std.algorithm : minElement;

		if (dirty_.length == 0)
			return;
		auto when = dirty_.byValue.minElement;
		if (flush_ is null)
		{
			flush_ = new TimerTask((_, __) { flush(); });
			mainTimer.add(flush_, when);
		}
		else if (when != flush_.when)
			flush_.restart(when);
	}

	void flush()
	{
		flush_ = null;
		auto now = MonoTime.currTime();
		Scope[] ready;
		foreach (target, deadline; dirty_)
			if (deadline <= now)
				ready ~= target;
		foreach (target; ready)
			dirty_.remove(target);
		scheduleFlush();
		foreach (target; ready)
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
			{
				watcher.onEvent(-1, "", INotify.Mask.qOverflow);
				watcher.onBatch();
			}, "project recreated", "user recreated"),
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
		{
			catalog.reloadGlobal();
			catalog.reloadProjects();
		}
		else
			foreach (path; notifiedScopes.keys)
				if (path != "config")
					catalog.reloadProject(path);

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
	), 2.msecs);
	watcher.start();
	scope (exit) if (!stopped) stop();
	watcher.ensureProjectWatch(project);
	watcher.ensureProjectWatch(otherProject);

	applyStep();
	setTimeout(&settle, 0.msecs);
	socketManager.loop();
	assert(nextStep == steps.length);
}

unittest // Config reloads observe completed saves and settled removals.
{
	import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_WRONLY, open;
	import core.sys.posix.unistd : close, writeFd = write;
	import std.conv : octal;
	import core.time : MonoTime;
	import std.file : mkdirRecurse, remove, rename, rmdirRecurse, symlink, tempDir, write;
	import std.process : environment;
	import std.string : toStringz;
	import std.uuid : randomUUID;

	import ae.net.asockets : socketManager;

	import cydo.server.config_resolution : loadRuntimeConfig;

	auto root = buildPath(tempDir, "cydo-config-watcher-" ~ randomUUID().toString());
	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	environment["HOME"] = root;
	auto path = configPath();
	mkdirRecurse(dirName(path));
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		rmdirRecurse(root);
	}

	enum initial = "workspaces: {}\ndefault_agent: codex\n";
	enum replacement = "workspaces: {}\ndefault_agent: copilot\n";
	enum grace = 60.msecs;
	enum prompt = 40.msecs;
	auto defaults = loadRuntimeConfig();
	auto moved = buildPath(root, "moved.yaml");
	auto staged = buildPath(dirName(path), "replacement.yaml");
	auto target = buildPath(root, "target.yaml");
	ConfigWatcher watcher;
	TimerTask delivery;

	void afterEvent(bool settled, void delegate() next)
	{
		assert(watcher.kernel_.pendingBytes() > 0);
		void checkDelivery()
		{
			auto flush = watcher.flush_;
			auto ready = settled ? flush is null
				: flush !is null && flush.when > MonoTime.currTime();
			if (watcher.kernel_.pendingBytes() == 0 && ready)
			{
				delivery = null;
				next();
			}
			else
				delivery = setTimeout(&checkDelivery, 1.msecs);
		}
		delivery = setTimeout(&checkDelivery, 0.msecs);
	}

	void check(string operation, bool initiallyPresent, bool[] expected,
		void delegate(void delegate() markComplete) change)
	{
		if (initiallyPresent)
			write(path, initial);

		bool[] present;
		MonoTime started, completed;
		watcher = new ConfigWatcher(ConfigWatcherHost({
			auto notified = MonoTime.currTime();
			auto found = exists(path);
			assert(present.length < expected.length, operation ~ ": extra callback");
			assert(found == expected[present.length], operation ~ ": unexpected file state");
			present ~= found;
			auto config = loadRuntimeConfig();
			if (found)
			{
				assert(completed >= started, operation ~ ": callback before the save completed");
				assert(notified - completed < prompt, operation ~ ": completed save was deferred");
				assert(config.default_agent == "copilot", operation ~ ": replacement did not load");
			}
			else
			{
				assert(notified - started >= grace, operation ~ ": removal was reported during grace");
				assert(config == defaults, operation ~ ": removal did not load startup defaults");
			}
		}, null, null), grace);
		watcher.start();

		started = MonoTime.currTime();
		change(() { completed = MonoTime.currTime(); });
		// Keep listening beyond the last possible grace timeout to catch duplicates.
		setTimeout({
			if (delivery !is null)
				delivery.cancel();
			watcher.stop();
		}, grace * 5);
		socketManager.loop();
		assert(delivery is null, operation ~ ": first event did not settle");
		assert(present == expected, operation ~ ": missing callback");
		if (exists(path))
			remove(path);
	}

	check("unlink", true, [false], (_) { remove(path); });
	check("rename away", true, [false], (_) { rename(path, moved); });

	check("unlink and replace within grace", true, [true], (markComplete) {
		remove(path);
		afterEvent(false, {
			markComplete();
			write(path, replacement);
		});
	});
	check("rename away and replace within grace", true, [true], (markComplete) {
		rename(path, moved);
		afterEvent(false, {
			markComplete();
			write(path, replacement);
		});
	});
	check("completed write then rename away in the same batch", true, [true], (markComplete) {
		write(path, initial);
		rename(path, moved);
		afterEvent(false, {
			markComplete();
			write(path, replacement);
		});
	});
	check("unlink and replace after grace", true, [false, true], (markComplete) {
		remove(path);
		afterEvent(true, {
			markComplete();
			write(path, replacement);
		});
	});

	check("atomic rename over config", true, [true], (markComplete) {
		write(staged, replacement);
		markComplete();
		rename(staged, path);
	});
	check("in-place save", true, [true], (markComplete) {
		markComplete();
		write(path, replacement);
	});
	void finishReplacement(int fd, void delegate() markComplete)
	{
		afterEvent(false, {
			auto written = writeFd(fd, replacement.ptr, replacement.length);
			assert(written == replacement.length);
			markComplete();
			auto closed = close(fd);
			assert(closed == 0);
		});
	}

	check("create and write before closing", false, [true], (markComplete) {
		// Keep the descriptor open across event-loop turns.
		auto fd = open(path.toStringz(), O_WRONLY | O_CREAT | O_EXCL, octal!600);
		assert(fd >= 0);
		finishReplacement(fd, markComplete);
	});
	check("create symlink then write its target", false, [true], (markComplete) {
		write(target, initial);
		symlink(target, path);
		afterEvent(false, {
			markComplete();
			write(target, replacement);
		});
	});

	symlink(target, path);
	check("a detached symlink target cannot complete its replacement", false, [true], (markComplete) {
		remove(path);
		auto fd = open(path.toStringz(), O_WRONLY | O_CREAT | O_EXCL, octal!600);
		assert(fd >= 0);
		write(target, initial);
		finishReplacement(fd, markComplete);
	});

	auto userYaml = userTaskTypesPath();
	write(userYaml, "old");
	MonoTime saved, userDeadline;
	string[] notifications;
	watcher = new ConfigWatcher(ConfigWatcherHost({
		assert(MonoTime.currTime() - saved < prompt, "config save was deferred");
		notifications ~= "config";
	}, null, {
		assert(!exists(userYaml));
		assert(MonoTime.currTime() >= userDeadline, "user removal was reported during grace");
		notifications ~= "user";
	}), grace);
	watcher.start();
	remove(userYaml);
	afterEvent(false, {
		userDeadline = watcher.flush_.when;
		saved = MonoTime.currTime();
		write(path, replacement);
	});
	setTimeout({
		if (delivery !is null)
			delivery.cancel();
		watcher.stop();
	}, grace * 5);
	socketManager.loop();
	assert(delivery is null);
	assert(notifications == ["config", "user"]);

	watcher = new ConfigWatcher(ConfigWatcherHost({
		assert(false, "stopped watcher delivered a pending removal");
	}, null, null), grace);
	watcher.start();
	remove(path);
	afterEvent(false, &watcher.stop);
	setTimeout({
		if (delivery !is null)
		{
			delivery.cancel();
			watcher.stop();
		}
	}, grace * 2);
	socketManager.loop();
	assert(delivery is null);
	assert(watcher.flush_ is null);
}

version (unittest) private void testWatchAttribution(bool structural)
{
	import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_TRUNC, O_WRONLY, open;
	import core.sys.posix.sys.stat : fchmod;
	import core.sys.posix.unistd : close, writeFd = write;
	import std.conv : octal;
	import std.file : mkdir, mkdirRecurse, FileException, readText, remove, rename, rmdir, setAttributes,
		rmdirRecurse, symlink, tempDir, write;
	import std.format : format;
	import std.process : environment;
	import std.string : toStringz;
	import std.uuid : randomUUID;

	import ae.net.asockets : socketManager;
	import cydo.domain.task_types.catalog : TaskTypeCatalog;

	alias Mask = INotify.Mask;
	alias Scope = ConfigWatcher.Scope;
	alias Kind = ConfigWatcher.Kind;
	alias Event = ConfigWatcher.WatchEvent;
	enum grace = 500.msecs;
	enum content = "written";
	enum absent = "<absent>";
	enum { untouched = -1, complete, incomplete, pending }
	enum { C, U, P, P2 }

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}

	string row, root, dir, cfg, user, project, other, projectDir, projectYaml,
		userPacks, projectPacks, target, staged, away;
	string[4] paths;
	string[][4] reads;
	Scope[4] scopes;
	MonoTime[4] deadlines;
	ConfigWatcher watcher;
	int dirWd, fd;

	int wd(string directory)
	{
		auto descriptor = watcher.kernel_.add(directory, ConfigWatcher.watchMask);
		assert(descriptor in watcher.interest_, row ~ ": directory was not already watched");
		return descriptor;
	}

	// Check the records before the deadlines, in the same observer call.
	void batch(Event[] premise, int[] classes, void delegate() followup = null, bool exact = false)
	{
		assert(watcher.batchObserver_ is null);
		watcher.batchObserver_ = (const(Event)[] actual, MonoTime now) {
			watcher.batchObserver_ = null;
			size_t matched;
			foreach (record; actual)
				if (matched < premise.length && record == premise[matched])
					++matched;
			assert(matched == premise.length && (!exact || actual.length == premise.length),
				format("%s: expected one batch containing %s, got %s", row, premise, actual));
			foreach (i, scopeTarget; scopes)
			{
				auto expected = i < classes.length ? classes[i] : untouched;
				auto deadline = scopeTarget in watcher.dirty_;
				if (expected == untouched)
					assert(deadline is null, format("%s: unexpected deadline for %s", row, scopeTarget));
				else
				{
					auto due = expected == pending ? deadlines[i] : now + expected * grace;
					assert(deadline !is null && *deadline == due,
						format("%s: wrong deadline for %s (expected class %s)", row, scopeTarget, expected));
					deadlines[i] = due;
				}
			}
			if (followup !is null)
				followup();
		};
	}

	void hold(string path)
	{
		fd = open(path.toStringz(), O_WRONLY | O_CREAT | O_EXCL, octal!600);
		assert(fd >= 0);
	}

	void finish(string path, int descriptor, int[] classes)
	{
		setTimeout({
			batch([Event(descriptor, baseName(path), Mask.closeWrite)], classes);
			auto written = writeFd(fd, content.ptr, content.length);
			assert(written == content.length);
			auto closed = close(fd);
			assert(closed == 0);
		}, 1.msecs);
	}

	void run(string name, void delegate() setup, void delegate() mutate, string[][] expected)
	{
		row = name;
		root = buildPath(tempDir, "cydo-watch-batch-" ~ randomUUID().toString());
		environment["HOME"] = root;
		scope (exit) rmdirRecurse(root);
		cfg = configPath();
		dir = dirName(cfg);
		user = userTaskTypesPath();
		project = buildPath(root, "project");
		other = buildPath(root, "other");
		projectDir = buildPath(project, ".cydo");
		projectYaml = buildPath(projectDir, "task-types.yaml");
		userPacks = buildPath(dir, "packs");
		projectPacks = buildPath(projectDir, "packs");
		target = buildPath(dir, "target.yaml");
		staged = buildPath(root, "staged");
		away = buildPath(root, "away");
		paths = [cfg, user, projectYaml, buildPath(other, ".cydo", "task-types.yaml")];
		scopes = [Scope(Kind.config), Scope(Kind.userTaskTypes),
			Scope(Kind.project, project), Scope(Kind.project, other)];
		reads = typeof(reads).init;
		deadlines = typeof(deadlines).init;
		mkdirRecurse(dir);
		mkdir(project);
		mkdir(other);
		setup();

		TaskTypeCatalog catalog;
		if (expected.length > P && expected[P].length && !expected[C].length && !expected[U].length)
		{
			auto defs = buildPath(root, "defs");
			mkdirRecurse(buildPath(defs, "prompts"));
			write(buildPath(defs, "prompts", "blank.md"), "Blank prompt\n");
			auto yaml = buildPath(defs, "task-types.yaml");
			write(yaml, "task_types:\n  sample:\n    model_class: large\n");
			catalog = new TaskTypeCatalog(defs, yaml, (string) => true);
		}
		auto snapshot = catalog is null ? null : catalog.getTaskTypesForProject(other);

		void record(int i)
		{
			assert(i < expected.length && reads[i].length < expected[i].length,
				format("%s: extra callback for %s", row, scopes[i]));
			auto now = MonoTime.currTime();
			assert(now >= deadlines[i] && now - deadlines[i] < grace,
				format("%s: callback outside its deadline window for %s", row, scopes[i]));
			string value;
			try
				value = readText(paths[i]);
			catch (FileException e)
			{
				if (e.errno != ENOENT)
					throw e;
				value = absent;
			}
			assert(value == expected[i][reads[i].length],
				format("%s: unexpected contents for %s: %s", row, scopes[i], value));
			reads[i] ~= value;
		}

		watcher = new ConfigWatcher(ConfigWatcherHost(
			{ record(C); },
			(path) {
				assert(path == project || path == other);
				if (catalog !is null)
					catalog.reloadProject(path);
				record(path == project ? P : P2);
			},
			{ record(U); },
		), grace);
		watcher.start();
		watcher.ensureProjectWatch(project);
		if (name != "F1" && name != "F2")
			watcher.ensureProjectWatch(other);
		dirWd = wd(dir);
		// Start the test window after registration so existing project watches
		// have observed the whole window.
		batch([Event(wd(project), "warmup", Mask.closeWrite)], [], {
			setTimeout(mutate, 0.msecs);
		});
		write(buildPath(project, "warmup"), content);
		setTimeout({
			watcher.stop();
		}, name == "D1" ? 3 * grace : 2 * grace);
		socketManager.loop();
		assert(watcher.batchObserver_ is null, row ~ ": missing observed batch");
		foreach (i, observed; reads)
			assert(observed == (i < expected.length ? expected[i] : null),
				format("%s: missing callback for %s", row, scopes[i]));
		if (catalog !is null)
			assert(catalog.getTaskTypesForProject(other) is snapshot, row ~ ": other project cache changed");
	}

	if (!structural)
	{
		foreach (i; [C, U, P])
		{
			run(["A1", "A3", "A4"][i], {
				mkdirRecurse(dirName(paths[i]));
				write(paths[i], "old");
			}, {
				auto path = paths[i];
				auto descriptor = wd(dirName(path));
				int[] first = [untouched, untouched, untouched];
				first[i] = incomplete;
				auto next = first.dup;
				next[i] = complete;
				batch([Event(descriptor, baseName(path), Mask.closeWrite),
					Event(descriptor, baseName(path), Mask.movedFrom)], first, {
					setTimeout({
						batch([Event(descriptor, baseName(path), Mask.closeWrite)], next);
						write(path, content);
					}, 1.msecs);
				});
				write(path, "first");
				rename(path, away);
			}, [i == C ? [content] : [], i == U ? [content] : [], i == P ? [content] : []]);
		}

		run("A2", { write(cfg, "old"); }, {
			batch([Event(dirWd, baseName(cfg), Mask.movedFrom),
				Event(dirWd, baseName(cfg), Mask.closeWrite)], [complete]);
			rename(cfg, away);
			write(cfg, content);
		}, [[content]]);

		foreach (split; [false, true])
		{
			run(split ? "chmod while creation grace is pending" : "create and chmod in one batch", {}, {
				auto create = Event(dirWd, baseName(cfg), Mask.create);
				auto attrib = Event(dirWd, baseName(cfg), Mask.attrib);
				void chmodOpenFile()
				{
					auto result = fchmod(fd, octal!640);
					assert(result == 0);
				}
				void finishWrite()
				{
					finish(cfg, dirWd, [complete]);
				}
				if (split)
					batch([create], [incomplete], {
						setTimeout({
							batch([attrib], [pending], &finishWrite, true);
							chmodOpenFile();
						}, 1.msecs);
					}, true);
				else
					batch([create, attrib], [incomplete], &finishWrite, true);
				hold(cfg);
				if (!split)
					chmodOpenFile();
			}, [[content]]);
		}

		run("chmod settled config", { write(cfg, content); }, {
			batch([Event(dirWd, baseName(cfg), Mask.attrib)], [complete], null, true);
			setAttributes(cfg, octal!600);
		}, [[content]]);

		run("chmod then delete config in one batch", { write(cfg, content); }, {
			batch([Event(dirWd, baseName(cfg), Mask.attrib), Event(dirWd, baseName(cfg), Mask.remove)],
				[incomplete], null, true);
			setAttributes(cfg, octal!600);
			remove(cfg);
		}, [[absent]]);

		void truncateConfig()
		{
			fd = open(cfg.toStringz(), O_WRONLY | O_TRUNC);
			assert(fd >= 0);
		}

		run("truncate and chmod in one batch", { write(cfg, "old"); }, {
			batch([Event(dirWd, baseName(cfg), Mask.modify), Event(dirWd, baseName(cfg), Mask.attrib)],
				[incomplete], { finish(cfg, dirWd, [complete]); }, true);
			truncateConfig();
			auto result = fchmod(fd, octal!640);
			assert(result == 0);
		}, [[content]]);

		run("completed save then truncate in one batch", { write(cfg, "old"); }, {
			auto modify = Event(dirWd, baseName(cfg), Mask.modify);
			batch([modify, Event(dirWd, baseName(cfg), Mask.closeWrite), modify],
				[incomplete], { finish(cfg, dirWd, [complete]); });
			write(cfg, "first");
			truncateConfig();
		}, [[content]]);

		foreach (multiWrite; [false, true])
		{
			run(multiWrite ? "multi-write in-place save" : "plain in-place save", { write(cfg, "old"); }, {
				batch([Event(dirWd, baseName(cfg), Mask.modify),
					Event(dirWd, baseName(cfg), Mask.closeWrite)], [complete]);
				truncateConfig();
				foreach (part; multiWrite ? ["writ", "ten"] : [content])
				{
					auto written = writeFd(fd, part.ptr, part.length);
					assert(written == part.length);
				}
				auto closed = close(fd);
				assert(closed == 0);
			}, [[content]]);
		}

		run("A5", {
			paths[P] = buildPath(projectPacks, "x", "task-types.yaml");
			mkdirRecurse(dirName(paths[P]));
			write(paths[P], "old");
		}, {
			auto descriptor = wd(dirName(paths[P]));
			batch([Event(descriptor, baseName(paths[P]), Mask.closeWrite),
				Event(descriptor, baseName(paths[P]), Mask.remove)], [untouched, untouched, incomplete]);
			write(paths[P], "updated");
			remove(paths[P]);
		}, [[], [], [absent]]);

		foreach (reverse; [false, true])
		{
			run(reverse ? "B1r" : "B1", { write(target, "old"); }, {
				auto create = Event(dirWd, baseName(cfg), Mask.create);
				auto save = Event(dirWd, baseName(target), Mask.closeWrite);
				batch(reverse ? [save, create] : [create, save], [reverse ? incomplete : complete]);
				if (reverse)
					write(target, content);
				symlink(target, cfg);
				if (!reverse)
					write(target, content);
			}, [[content]]);
		}

		run("B2", { symlink(target, staged); }, {
			batch([Event(dirWd, baseName(cfg), Mask.movedTo), Event(dirWd, baseName(target), Mask.create)],
				[incomplete], { finish(target, dirWd, [complete]); });
			rename(staged, cfg);
			hold(target);
		}, [[content]]);

		run("B3", { write(user, "old"); }, {
			batch([Event(dirWd, baseName(cfg), Mask.create), Event(dirWd, baseName(user), Mask.closeWrite)],
				[complete, complete]);
			symlink(user, cfg);
			write(user, content);
		}, [[content], [content]]);

		run("B4", {
			mkdir(userPacks);
			paths[P] = buildPath(projectPacks, "p", "task-types.yaml");
			paths[U] = buildPath(userPacks, "alias", "task-types.yaml");
			mkdirRecurse(dirName(paths[P]));
			write(paths[P], "old");
		}, {
			batch([Event(wd(userPacks), "alias", Mask.create),
				Event(wd(dirName(paths[P])), baseName(paths[P]), Mask.closeWrite)],
				[untouched, complete, complete]);
			symlink(dirName(paths[P]), buildPath(userPacks, "alias"));
			write(paths[P], content);
		}, [[], [content], [content]]);

		foreach (holdOpen; [false, true])
		{
			run(holdOpen ? "B6" : "B5", {
				mkdir(projectDir);
				target = buildPath(projectDir, "real.yaml");
				if (holdOpen)
					symlink(target, staged);
				else
					write(target, "old");
			}, {
				auto descriptor = wd(projectDir);
				batch([Event(descriptor, baseName(projectYaml), holdOpen ? Mask.movedTo : Mask.create),
					Event(descriptor, baseName(target), holdOpen ? Mask.create : Mask.closeWrite)],
					[untouched, untouched, holdOpen ? incomplete : complete], {
						if (holdOpen)
							finish(target, descriptor, [untouched, untouched, complete]);
					});
				if (holdOpen)
				{
					rename(staged, projectYaml);
					hold(target);
				}
				else
				{
					symlink(target, projectYaml);
					write(target, content);
				}
			}, [[], [], [content]]);
		}

		foreach (i; 0 .. 3)
		{
			run(["C1", "C2", "C3"][i], {
				target = [buildPath(root, "target.yaml"), target, user][i];
				write(target, "old");
				symlink(target, cfg);
			}, {
				auto targetWd = wd(dirName(target));
				batch([Event(dirWd, baseName(cfg), Mask.remove), Event(dirWd, baseName(cfg), Mask.create),
					Event(targetWd, baseName(target), Mask.closeWrite)],
					[incomplete, i == 2 ? complete : untouched], {
						if (i == 0)
							assert(targetWd !in watcher.interest_);
						finish(cfg, dirWd, [complete]);
					});
				remove(cfg);
				hold(cfg);
				write(target, content);
			}, [[content], i == 2 ? [content] : []]);
		}

		run("C4", {
			paths[U] = buildPath(userPacks, "p", "task-types.yaml");
			mkdirRecurse(dirName(paths[U]));
			write(paths[U], "old");
		}, {
			batch([Event(wd(userPacks), "p", Mask.movedFrom | Mask.isDir),
				Event(wd(dirName(paths[U])), "task-types.yaml", Mask.closeWrite)],
				[untouched, incomplete]);
			rename(dirName(paths[U]), away);
			write(buildPath(away, "task-types.yaml"), content);
		}, [[], [absent]]);

		run("C5", {
			mkdirRecurse(projectPacks);
			mkdir(away);
			paths[P] = buildPath(projectPacks, "x", "task-types.yaml");
			write(buildPath(away, "task-types.yaml"), "old");
			symlink(away, dirName(paths[P]));
		}, {
			auto packsWd = wd(projectPacks);
			batch([Event(packsWd, "x", Mask.remove), Event(packsWd, "x", Mask.create | Mask.isDir),
				Event(wd(away), "task-types.yaml", Mask.closeWrite)], [untouched, untouched, incomplete]);
			remove(dirName(paths[P]));
			mkdir(dirName(paths[P]));
			write(buildPath(away, "task-types.yaml"), content);
		}, [[], [], [absent]]);
		return;
	}

	run("D1", {}, {
		batch([Event(dirWd, "", Mask.ignored)], [incomplete, incomplete], {
			auto oldWd = dirWd;
			dirWd = wd(dir);
			assert(dirWd != oldWd && oldWd !in watcher.interest_);
			setTimeout({
				batch([Event(dirWd, baseName(cfg), Mask.create),
					Event(dirWd, baseName(cfg), Mask.closeWrite)], [complete]);
				write(cfg, content);
			}, grace + 10.msecs);
		}, true);
		rmdir(dir);
		mkdir(dir);
	}, [[absent, content], [absent]]);

	run("D2", { mkdir(projectDir); write(projectYaml, "old"); }, {
		auto previous = wd(projectDir);
		auto projectWd = wd(project);
		batch([Event(previous, baseName(projectYaml), Mask.remove),
			Event(projectWd, ".cydo", Mask.remove | Mask.isDir),
			Event(projectWd, ".cydo", Mask.create | Mask.isDir)],
			[untouched, untouched, incomplete], {
				auto descriptor = wd(projectDir);
				assert(descriptor != previous);
				setTimeout({
					batch([Event(descriptor, baseName(projectYaml), Mask.closeWrite)],
						[untouched, untouched, complete]);
					write(projectYaml, content);
				}, 1.msecs);
			});
		rmdirRecurse(projectDir);
		mkdir(projectDir);
	}, [[], [], [content]]);

	foreach (removeTarget; [false, true])
	{
		run(removeTarget ? "D4" : "D3", {
			target = buildPath(root, "sub", "target.yaml");
			mkdir(dirName(target));
			write(target, "old");
			if (removeTarget)
				symlink(target, cfg);
		}, {
			if (removeTarget)
			{
				auto descriptor = wd(dirName(target));
				batch([Event(descriptor, baseName(target), Mask.remove), Event(descriptor, "", Mask.ignored)],
					[incomplete]);
				rmdirRecurse(dirName(target));
			}
			else
			{
				batch([Event(dirWd, baseName(cfg), Mask.create)], [incomplete], {
					auto descriptor = wd(dirName(target));
					setTimeout({
						batch([Event(descriptor, baseName(target), Mask.closeWrite)], [complete]);
						write(target, content);
					}, 1.msecs);
				});
				symlink(target, cfg);
			}
		}, [[removeTarget ? absent : content]]);
	}

	foreach (i; 0 .. 3)
	{
		auto scopeIndex = i == 2 ? P : U;
		run(["E1", "E2", "E3"][i], {
			auto packs = scopeIndex == P ? projectPacks : userPacks;
			mkdirRecurse(packs);
			mkdir(staged);
			paths[scopeIndex] = buildPath(packs, "new", "task-types.yaml");
			if (i != 1)
				write(buildPath(staged, "task-types.yaml"), content);
		}, {
			auto pack = dirName(paths[scopeIndex]);
			int[] classes = [untouched, untouched, untouched];
			classes[scopeIndex] = incomplete;
			batch([Event(wd(dirName(pack)), "new", Mask.movedTo | Mask.isDir)], classes, {
				if (i == 1)
				{
					classes[scopeIndex] = complete;
					finish(paths[scopeIndex], wd(pack), classes);
				}
			}, true);
			rename(staged, pack);
			if (i == 1)
				hold(paths[scopeIndex]);
		}, [[], scopeIndex == U ? [content] : [], scopeIndex == P ? [content] : []]);
	}

	foreach (register; [false, true])
	{
		run(register ? "F1" : "E4", {
			target = buildPath(root, "new", "target.yaml");
			mkdir(dirName(target));
			write(target, content);
			symlink(target, staged);
			if (!register)
			{
				auto oldTarget = buildPath(root, "old.yaml");
				write(oldTarget, "old");
				symlink(oldTarget, cfg);
			}
		}, {
			batch([Event(dirWd, baseName(cfg), Mask.movedTo)], [incomplete]);
			rename(staged, cfg);
			if (register)
			{
				watcher.ensureProjectWatch(other);
				wd(dirName(target));
			}
		}, [[content]]);
	}

	run("F2", { write(user, "old"); }, {
		batch([Event(dirWd, baseName(user), Mask.closeWrite)], [untouched, complete]);
		watcher.ensureProjectWatch(other);
		write(user, content);
	}, [[], [content]]);

	run("G1", {}, {
		batch([Event(-1, "", Mask.qOverflow), Event(dirWd, "noise", Mask.closeWrite)],
			[complete, complete, complete, complete]);
		watcher.onEvent(-1, "", Mask.qOverflow);
		write(buildPath(dir, "noise"), content);
	}, [[absent], [absent], [absent], [absent]]);

	run("G2", {
		mkdir(userPacks);
		mkdir(staged);
		write(buildPath(staged, "task-types.yaml"), content);
		paths[U] = buildPath(userPacks, "new", "task-types.yaml");
	}, {
		batch([Event(-1, "", Mask.qOverflow), Event(wd(userPacks), "new", Mask.movedTo | Mask.isDir)],
			[complete, incomplete, complete, complete]);
		watcher.onEvent(-1, "", Mask.qOverflow);
		rename(staged, dirName(paths[U]));
	}, [[absent], [content], [absent], [absent]]);

	run("G3", { write(user, "old"); }, {
		batch([Event(dirWd, baseName(user), Mask.remove)], [untouched, incomplete], {
			setTimeout({
				batch([Event(dirWd, baseName(cfg), Mask.closeWrite)], [complete, pending]);
				write(cfg, content);
			}, 1.msecs);
		});
		remove(user);
	}, [[content], [absent]]);
}

unittest // Stable, attached and detached dirents within a read.
{
	testWatchAttribution(false);
}

unittest // Structural changes, observation windows and overflow.
{
	testWatchAttribution(true);
}
