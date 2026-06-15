module cydo.config_watcher;

import std.file : exists;
import std.logger : warningf;
import std.path : baseName, buildPath, dirName;

import ae.sys.inotify : INotify, iNotify;

import cydo.config : configPath;
import cydo.inotify : RefCountedINotify;

package(cydo):

struct ConfigWatcherHost
{
	void delegate() onConfigChanged;
	void delegate(string projectPath) onProjectConfigChanged;
}

class ConfigWatcher
{
	private ConfigWatcherHost host_;
	private INotify.WatchDescriptor configFileWatch_;
	private INotify.WatchDescriptor configDirWatch_;
	private bool configFileWatchActive_;
	private bool configDirWatchActive_;
	private RefCountedINotify projectINotify_;
	private RefCountedINotify.Handle[string] projectDirWatches_;
	private RefCountedINotify.Handle[string] projectFileWatches_;

	this(ConfigWatcherHost host)
	{
		host_ = host;
	}

	void start()
	{
		auto cfgPath = configPath;
		auto cfgDir = dirName(cfgPath);
		auto cfgFileName = baseName(cfgPath);

		if (!exists(cfgDir))
		{
			warningf("Config directory %s does not exist, skipping config watch", cfgDir);
			return;
		}

		if (exists(cfgPath))
			watchConfigFile(cfgPath);

		configDirWatch_ = iNotify.add(cfgDir, INotify.Mask.create | INotify.Mask.movedTo,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				if (name != cfgFileName)
					return;
				if (configFileWatchActive_)
				{
					iNotify.remove(configFileWatch_);
					configFileWatchActive_ = false;
				}
				watchConfigFile(cfgPath);
				host_.onConfigChanged();
			}
		);
		configDirWatchActive_ = true;
	}

	void stop()
	{
		if (configFileWatchActive_)
		{
			iNotify.remove(configFileWatch_);
			configFileWatchActive_ = false;
		}
		if (configDirWatchActive_)
		{
			iNotify.remove(configDirWatch_);
			configDirWatchActive_ = false;
		}
		foreach (projectPath, handle; projectFileWatches_)
			projectINotify_.remove(handle);
		projectFileWatches_ = null;
		foreach (projectPath, handle; projectDirWatches_)
			projectINotify_.remove(handle);
		projectDirWatches_ = null;
	}

	void ensureProjectWatch(string projectPath)
	{
		if (projectPath in projectDirWatches_)
			return;

		auto cydoDir = buildPath(projectPath, ".cydo");
		if (!exists(cydoDir))
			return;

		projectDirWatches_[projectPath] = projectINotify_.add(
			cydoDir,
			INotify.Mask.closeWrite | INotify.Mask.create | INotify.Mask.movedTo,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				if (name == "task-types.yaml" || name == "defs")
					host_.onProjectConfigChanged(projectPath);
			}
		);

		auto typesFile = buildPath(cydoDir, "task-types.yaml");
		if (!exists(typesFile))
			return;

		projectFileWatches_[projectPath] = projectINotify_.add(
			typesFile,
			INotify.Mask.closeWrite,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				host_.onProjectConfigChanged(projectPath);
			}
		);
	}

private:
	void watchConfigFile(string cfgPath)
	{
		configFileWatch_ = iNotify.add(cfgPath, INotify.Mask.closeWrite,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				host_.onConfigChanged();
			}
		);
		configFileWatchActive_ = true;
	}
}
