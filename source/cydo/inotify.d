/// Ref-counting wrapper around ae's global iNotify.
///
/// Linux's inotify_add_watch returns the same watch descriptor when the
/// same path is watched twice on the same fd.  ae's INotify assumes a
/// 1:1 mapping from WD to handler, so duplicate adds would overwrite
/// the first handler and corrupt the active-handler count.
///
/// This wrapper deduplicates: multiple consumers can watch the same path
/// and each gets their own callback via fan-out.  The kernel watch is
/// created on first add and removed when the last consumer unregisters.
module cydo.inotify;

import ae.sys.inotify : INotify, iNotify;

struct RefCountedINotify
{
	/// Opaque handle identifying a single consumer's watch registration.
	static struct Handle
	{
		private size_t id;
	}

	alias Handler = INotify.INotifyHandler;

	/// Register a watch.  If the same path is already watched (must use
	/// the same mask), the handler joins the existing kernel watch.
	Handle add(string path, INotify.Mask mask, Handler handler)
	{
		assert(handler);
		auto id = nextId++;

		if (auto g = path in groups)
		{
			assert(g.mask == mask,
				"Cannot watch same path with different masks");
			g.entries ~= Entry(id, handler);
			g.activeCount++;
		}
		else
		{
			auto wd = iNotify.add(path, mask,
				(in char[] name, INotify.Mask m, uint cookie)
				{
					dispatchEvent(path, name, m, cookie);
				}
			);
			groups[path] = Group(wd, mask, [Entry(id, handler)], 1);
		}
		idPath[id] = path;
		return Handle(id);
	}

	/// Unregister a watch handle.  The kernel watch is removed when the
	/// last consumer for that path unregisters.
	void remove(Handle handle)
	{
		auto ppath = handle.id in idPath;
		assert(ppath !is null, "Invalid watch handle");
		auto path = *ppath;
		idPath.remove(handle.id);

		auto g = path in groups;
		assert(g !is null);

		foreach (ref e; g.entries)
		{
			if (e.id == handle.id)
			{
				assert(e.handler !is null, "Watch handle already removed");
				e.handler = null;
				break;
			}
		}

		g.activeCount--;
		if (g.activeCount == 0)
		{
			iNotify.remove(g.wd);
			groups.remove(path);
		}
	}

private:

	struct Entry
	{
		size_t id;
		Handler handler; // null = tombstone
	}

	struct Group
	{
		INotify.WatchDescriptor wd;
		INotify.Mask mask;
		Entry[] entries;
		size_t activeCount;
	}

	Group[string] groups;
	string[size_t] idPath; // handle id → path (for remove lookup)
	size_t nextId;

	void dispatchEvent(string path, in char[] name,
		INotify.Mask mask, uint cookie)
	{
		auto g = path in groups;
		if (g is null)
			return;

		foreach (i; 0 .. g.entries.length)
		{
			if (g.entries[i].handler !is null)
				g.entries[i].handler(name, mask, cookie);
			// Handler may have called remove(); re-check group
			g = path in groups;
			if (g is null)
				return;
		}
	}
}
