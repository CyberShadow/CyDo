module cydo.workflow.batch.registry;

import std.format : format;

import cydo.mcp : McpResult;

package(cydo):

struct BatchHandle
{
	int parentTid;
	ulong batchId;
}

struct BatchState
{
	int parentTid;
	int[] childTids;
	McpResult[] results;
	bool[] done;
	size_t completed;
	bool complete() const { return completed == childTids.length; }
}

struct BatchRegistry
{
private:
	BatchState[ulong] batches_;
	ulong[int] ownerByChild_;

public:
	bool create(int parentTid, int[] childTids, out BatchHandle handle,
		out string error)
	{
		if (childTids.length == 0)
		{
			error = "Task batch must contain a child";
			return false;
		}
		bool[int] seen;
		foreach (childTid; childTids)
		{
			if (childTid <= 0)
			{
				error = format!"invalid child tid in batch: %d"(childTid);
				return false;
			}
			if (childTid in ownerByChild_)
			{
				error = format!"child tid=%d already owned by a batch"(childTid);
				return false;
			}
			if (childTid in seen)
			{
				error = format!"duplicate child tid in batch: %d"(childTid);
				return false;
			}
			seen[childTid] = true;
		}
		auto batchId = cast(ulong) childTids[0];
		handle = rebuild(parentTid, batchId, childTids);
		error = null;
		return true;
	}

	BatchHandle rebuild(int parentTid, ulong batchId, int[] childTids)
	{
		assert((batchId in batches_) is null, "duplicate batch ID");
		BatchState batch;
		batch.parentTid = parentTid;
		batch.childTids = childTids.dup;
		batch.results = new McpResult[childTids.length];
		batch.done = new bool[childTids.length];
		batches_[batchId] = batch;
		foreach (childTid; childTids)
			ownerByChild_[childTid] = batchId;
		return BatchHandle(parentTid, batchId);
	}

	bool exists(BatchHandle handle) const
	{
		auto batch = handle.batchId in batches_;
		return batch !is null && batch.parentTid == handle.parentTid;
	}

	bool hasBatches(int parentTid) const
	{
		foreach (batch; batches_)
			if (batch.parentTid == parentTid)
				return true;
		return false;
	}

	bool findOwnerOfChild(int childTid, out BatchHandle handle, out size_t slot) const
	{
		auto id = childTid in ownerByChild_;
		if (id is null) return false;
		auto batch = *id in batches_;
		assert(batch !is null);
		foreach (i, tid; batch.childTids)
			if (tid == childTid)
			{
				if (batch.done[i]) return false;
				handle = BatchHandle(batch.parentTid, *id);
				slot = i;
				return true;
			}
		assert(0, "batch owner has no child slot");
	}

	bool recordChildDone(BatchHandle handle, size_t slot, int childTid,
		McpResult result)
	{
		auto batch = handle.batchId in batches_;
		assert(batch !is null && batch.parentTid == handle.parentTid);
		assert(slot < batch.childTids.length && batch.childTids[slot] == childTid);
		assert(!batch.done[slot]);
		batch.results[slot] = result;
		batch.done[slot] = true;
		batch.completed++;
		return batch.complete;
	}

	bool dropPendingChild(int childTid, out BatchHandle handle)
	{
		size_t slot;
		if (!findOwnerOfChild(childTid, handle, slot))
		{
			assert(!hasChild(childTid), "Deleted batch child cannot have recorded a result");
			return false;
		}
		auto batch = &batches_[handle.batchId];
		batch.childTids = batch.childTids[0 .. slot] ~ batch.childTids[slot + 1 .. $];
		batch.results = batch.results[0 .. slot] ~ batch.results[slot + 1 .. $];
		batch.done = batch.done[0 .. slot] ~ batch.done[slot + 1 .. $];
		ownerByChild_.remove(childTid);
		return batch.complete;
	}

	bool hasChild(int childTid) const
	{
		return (childTid in ownerByChild_) !is null;
	}

	int parentOfChild(int childTid) const
	{
		auto id = childTid in ownerByChild_;
		return id is null ? 0 : batches_[*id].parentTid;
	}

	bool isRecorded(int childTid) const
	{
		auto id = childTid in ownerByChild_;
		if (id is null) return false;
		auto batch = *id in batches_;
		assert(batch !is null);
		foreach (i, tid; batch.childTids)
			if (tid == childTid) return batch.done[i];
		assert(0, "batch owner has no child slot");
	}

	int[] children(BatchHandle handle) const
	{
		auto batch = handle.batchId in batches_;
		assert(batch !is null && batch.parentTid == handle.parentTid);
		return batch.childTids.dup;
	}

	McpResult[] envelope(BatchHandle handle) const
	{
		auto batch = handle.batchId in batches_;
		assert(batch !is null && batch.parentTid == handle.parentTid);
		assert(batch.complete);
		return batch.results.dup;
	}

	bool complete(BatchHandle handle) const
	{
		auto batch = handle.batchId in batches_;
		assert(batch !is null && batch.parentTid == handle.parentTid);
		return batch.complete;
	}

	void replaceChild(int oldTid, int newTid)
	{
		BatchHandle handle;
		size_t slot;
		assert(findOwnerOfChild(oldTid, handle, slot));
		assert((newTid in ownerByChild_) is null);
		batches_[handle.batchId].childTids[slot] = newTid;
		ownerByChild_.remove(oldTid);
		ownerByChild_[newTid] = handle.batchId;
	}

	void remove(BatchHandle handle)
	{
		auto batch = handle.batchId in batches_;
		if (batch is null)
			return;
		assert(batch.parentTid == handle.parentTid);
		foreach (childTid; batch.childTids)
			ownerByChild_.remove(childTid);
		batches_.remove(handle.batchId);
	}
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle, owner;
	string error;
	size_t slot;
	assert(registry.create(1, [2, 3], handle, error));
	assert(handle.batchId == 2);
	assert(registry.hasBatches(1));
	assert(registry.findOwnerOfChild(2, owner, slot) && slot == 0);
	assert(!registry.recordChildDone(handle, 1, 3, McpResult("third", false)));
	assert(!registry.findOwnerOfChild(3, owner, slot));
	assert(registry.isRecorded(3) && !registry.isRecorded(2));
	assert(registry.recordChildDone(handle, 0, 2, McpResult("second", false)));
	assert(registry.envelope(handle)[0].text == "second");
	assert(registry.envelope(handle)[1].text == "third");
	registry.remove(handle);
	assert(!registry.isRecorded(3));
	assert(!registry.hasBatches(1));
}

unittest
{
	BatchRegistry registry;
	// A handoff can make the first child's tid differ from the batch id.
	auto handle = registry.rebuild(1, 2, [9, 3]);
	assert(handle.batchId == 2);
	assert(!registry.recordChildDone(handle, 0, 9, McpResult("A", false)));
	assert(!registry.complete(handle));

	BatchHandle owner;
	size_t slot;
	assert(registry.findOwnerOfChild(3, owner, slot));
	assert(owner == handle && slot == 1);
	assert(registry.recordChildDone(owner, slot, 3, McpResult("B", false)));

	auto results = registry.envelope(handle);
	assert(results.length == 2);
	assert(results[0].text == "A" && results[1].text == "B");
}
