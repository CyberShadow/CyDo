module cydo.batch.registry;

/**
 * Live batch registry for CyDo's `Task(...)` tool calls.
 *
 * In CyDo terms, a batch is the live backend state for one `Task(...)` call.
 * It tracks the child tids launched by that call, each child's result slot,
 * completion flags, result values, and the event queue that wakes the waiting
 * parent task.
 *
 * Batches exist because a single `Task(...)` can launch multiple children and
 * then wait for a stream of child completion/question events until all slots
 * are complete. If a child asks the parent a question, the batch is suspended
 * and must remain live so `Answer(qid)` can resume that exact `Task(...)`.
 *
 * A parent can therefore own multiple live batches at once: while one batch is
 * suspended on a child question, the parent may launch a newer `Task(...)` that
 * creates another live batch.
 *
 * `BatchRegistry` owns live batch identity and indexes. `App` owns task
 * lifecycle and question-routing policy.
 */
import std.format : format;
import std.conv : to;

import ae.utils.promise : Promise;

import cydo.batch.router : BatchConsumeKind, BatchConsumeResult, BatchState, buildBatchState,
	consumeBatchSignal, validateBatchCompletion;
import cydo.mcp : McpResult;
import cydo.tasks.model : BatchSignal;

package(cydo):

/// Exact identity handle for one live batch owned by one parent task.
struct BatchHandle
{
	int parentTid;
	ulong batchId;
}

/// Hash key equivalent of `BatchHandle` used in registry maps.
struct ActiveBatchKey
{
	int parentTid;
	ulong batchId;

	size_t toHash() const nothrow @safe @nogc
	{
		size_t h = cast(size_t)parentTid;
		h ^= cast(size_t)(batchId ^ (batchId >> 32));
		return h;
	}

	bool opEquals(scope const ActiveBatchKey other) const nothrow @safe @nogc
	{
		return parentTid == other.parentTid && batchId == other.batchId;
	}
}

/**
 * Registry of live `Task(...)` batches.
 *
 * Invariants:
 * - Live batch identity is `(parentTid, batchId)`.
 * - A parent may own multiple live batches.
 * - A child tid is owned by zero or one live batch.
 * - Child ownership is released when that child slot completes.
 * - Finalizing/removing a batch affects only that exact batch handle.
 * - Exact routing uses batch handle, qid route, or child ownership; never
 *   parent recency.
 * - Parent-wide scans are only for predicates like "any live batch?" or
 *   "find any pending child question owned by this parent."
 */
struct BatchRegistry
{
private:
	BatchState[ActiveBatchKey] activeBatches;
	ulong[][int] batchIdsByParentTid;
	ActiveBatchKey[int] batchKeyByChildTid;
	ulong nextBatchId = 1;

	ActiveBatchKey batchKey(BatchHandle handle) const
	{
		return ActiveBatchKey(handle.parentTid, handle.batchId);
	}

	BatchState* findBatch(BatchHandle handle)
	{
		auto key = batchKey(handle);
		return key in activeBatches;
	}

	BatchState* findBatch(ActiveBatchKey key)
	{
		return key in activeBatches;
	}

	void addActiveBatch(int parentTid, ref BatchState batch)
	{
		auto key = ActiveBatchKey(parentTid, batch.batchId);
		assert((key in activeBatches) is null);
		activeBatches[key] = batch;
		batchIdsByParentTid[parentTid] ~= batch.batchId;
		foreach (childTid; batch.childTids)
			batchKeyByChildTid[childTid] = key;
	}

	string clearChildOwnershipForCompletedSlot(ActiveBatchKey key, size_t slot)
	{
		auto batchPtr = key in activeBatches;
		if (batchPtr is null)
			return format!"missing batch while clearing child ownership parent=%d batch=%s slot=%s"
				(key.parentTid, key.batchId, slot);
		if (slot >= batchPtr.childTids.length)
			return format!"slot out of range while clearing child ownership parent=%d batch=%s slot=%s child_count=%s"
				(key.parentTid, key.batchId, slot, batchPtr.childTids.length);
		if (!batchPtr.done[slot])
			return format!"attempted to clear unfinished child ownership parent=%d batch=%s slot=%s child=%d"
				(key.parentTid, key.batchId, slot, batchPtr.childTids[slot]);
		auto childTid = batchPtr.childTids[slot];
		auto owner = childTid in batchKeyByChildTid;
		if (owner is null)
			return format!"missing child owner index while clearing completed slot parent=%d batch=%s child=%d slot=%s"
				(key.parentTid, key.batchId, childTid, slot);
		if (*owner != key)
			return format!"child owner mismatch while clearing completed slot parent=%d batch=%s child=%d slot=%s owner_parent=%d owner_batch=%s"
				(key.parentTid, key.batchId, childTid, slot, owner.parentTid, owner.batchId);
		batchKeyByChildTid.remove(childTid);
		return "";
	}

public:
	/**
	 * Register a new live batch for one parent and child tid set.
	 *
	 * Use when handling a new `Task(...)` launch result, before waiting for any
	 * child events. This is an exact registration call: ownership is tied to the
	 * returned `(parentTid, batchId)` handle.
	 *
	 * Returns `false` with non-empty `error` when input/state is invalid
	 * (duplicate batch id, duplicate child ownership, or invalid batch state).
	 */
	bool create(int parentTid, int[] childTids, out BatchHandle handle, out string error)
	{
		auto batch = buildBatchState(nextBatchId++, childTids, error);
		if (error.length > 0)
		{
			handle = BatchHandle.init;
			return false;
		}
		auto key = ActiveBatchKey(parentTid, batch.batchId);
		if (key in activeBatches)
		{
			error = format!"duplicate active batch registration for parent=%d batch=%s"(parentTid, batch.batchId);
			handle = BatchHandle.init;
			return false;
		}
		foreach (childTid; childTids)
			if (auto owner = childTid in batchKeyByChildTid)
			{
				error = format!"child tid=%d already owned by parent=%d batch=%s"(childTid, owner.parentTid, owner.batchId);
				handle = BatchHandle.init;
				return false;
			}
		addActiveBatch(parentTid, batch);
		handle = BatchHandle(parentTid, batch.batchId);
		error = "";
		return true;
	}

	/// Exact lookup: `true` only when that specific `(parentTid, batchId)` is live.
	bool exists(BatchHandle handle)
	{
		return findBatch(handle) !is null;
	}

	/**
	 * Parent-wide predicate: does this parent currently own any live batch?
	 *
	 * Callers use this for broad routing policy checks, not exact event routing.
	 * Returns `false` with non-empty `error` only when parent index invariants
	 * are broken.
	 */
	bool parentHasLiveBatches(int parentTid, out bool hasLive, out string error)
	{
		auto ids = parentTid in batchIdsByParentTid;
		if (ids is null || ids.length == 0)
		{
			hasLive = false;
			error = "";
			return true;
		}
		hasLive = false;
		foreach (batchId; *ids)
		{
			if (findBatch(BatchHandle(parentTid, batchId)) is null)
			{
				hasLive = false;
				error = format!"parent index points to missing batch parent=%d batch=%s"
					(parentTid, batchId);
				return false;
			}
			hasLive = true;
		}
		error = "";
		return true;
	}

	/**
	 * Exact child-ownership lookup across all live batches.
	 *
	 * Use for routing events keyed by child tid. If ownership exists, returns
	 * `true` and fills the owning handle/slot plus current completion state.
	 *
	 * Returns `false` with empty `error` when no live batch owns `childTid`.
	 * Returns `true` with non-empty `error` when ownership index points to an
	 * inconsistent/missing batch (invariant failure).
	 */
	bool findOwnerOfChild(int childTid,
		out BatchHandle handle, out size_t slot, out bool done,
		out string error)
	{
		auto keyPtr = childTid in batchKeyByChildTid;
		if (keyPtr is null)
		{
			handle = BatchHandle.init;
			slot = 0;
			done = false;
			error = "";
			return false;
		}
		auto key = *keyPtr;
		handle = BatchHandle(key.parentTid, key.batchId);
		auto batch = findBatch(key);
		if (batch is null)
		{
			error = format!"child owner index points to missing batch child=%d owner_parent=%d owner_batch=%s"
				(childTid, key.parentTid, key.batchId);
			return true;
		}
		if (!batch.trySlotForChild(childTid, slot))
		{
			error = format!"child owner index points to batch that does not own child child=%d owner_parent=%d owner_batch=%s"
				(childTid, key.parentTid, key.batchId);
			return true;
		}
		done = batch.done[slot];
		error = "";
		return true;
	}

	/**
	 * Parent-wide scan for the first child tid matching `matches`.
	 *
	 * Use only for parent-level predicates/questions (for example, find any
	 * pending child question for a parent). Do not use for exact routing of a
	 * known batch event.
	 *
	 * Returns `true` when a match is found. Returns `false` with empty `error`
	 * when no matching live child exists. Returns `false` with non-empty `error`
	 * when parent index invariants are broken.
	 */
	bool findFirstLiveChild(int parentTid,
		scope bool delegate(int childTid) matches,
		out int childTid, out string error)
	{
		auto ids = parentTid in batchIdsByParentTid;
		if (ids is null || ids.length == 0)
		{
			childTid = 0;
			error = "";
			return false;
		}
		foreach (batchId; *ids)
		{
			auto batch = findBatch(BatchHandle(parentTid, batchId));
			if (batch is null)
			{
				error = format!"parent index points to missing batch parent=%d batch=%s"(parentTid, batchId);
				return false;
			}
			foreach (cTid; batch.childTids)
				if (matches(cTid))
				{
					childTid = cTid;
					error = "";
					return true;
				}
		}
		childTid = 0;
		error = "";
		return false;
	}

	/**
	 * Wait for one queued signal on an exact live batch handle.
	 *
	 * Callers should use this only after successful `create`, and only with that
	 * exact handle. Returns a promise for the next childDone/question event.
	 *
	 * Returns `false` with empty `error` when the batch is already complete.
	 * Returns `false` with non-empty `error` when the batch disappeared.
	 */
	bool waitOne(BatchHandle handle,
		out Promise!BatchSignal event, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			event = null;
			error = format!"batch disappeared while waiting for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return false;
		}
		if (batch.completed >= batch.totalChildren)
		{
			event = null;
			error = "";
			return false;
		}
		event = batch.eventQueue.waitOne();
		error = "";
		return true;
	}

	/**
	 * Consume one signal for an exact live batch and update batch state.
	 *
	 * Use this immediately after `waitOne` resolves. This is exact routing; pass
	 * the same handle that produced the signal. On `childDone`, ownership for
	 * the completed slot is released.
	 *
	 * `error` is non-empty only for invariant failures (for example missing
	 * batch after event, ownership/index mismatch while clearing a done slot).
	 */
	BatchConsumeResult consume(BatchHandle handle, BatchSignal signal,
		scope bool delegate(int childTid, int qid) hasPendingQuestion,
		out string error)
	{
		BatchConsumeResult ignored;
		auto batch = findBatch(handle);
		if (batch is null)
		{
			error = format!"batch disappeared after event for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return ignored;
		}
		auto consumed = consumeBatchSignal(*batch, signal, hasPendingQuestion);
		if (consumed.kind == BatchConsumeKind.childDone)
		{
			auto clearError = clearChildOwnershipForCompletedSlot(batchKey(handle), signal.slot);
			if (clearError.length > 0)
			{
				error = clearError;
				return consumed;
			}
		}
		error = "";
		return consumed;
	}

	/**
	 * Finalize an exact completed batch and return ordered child results.
	 *
	 * Use only after the batch reaches completion. This validates completion
	 * invariants, copies results, and removes that exact batch from the live
	 * registry.
	 *
	 * Returns `false` with non-empty `error` when the batch is missing or any
	 * completion/index invariant is broken.
	 */
	bool finalize(BatchHandle handle,
		out McpResult[] results, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			results = null;
			error = format!"batch missing before finalization for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return false;
		}

		auto invariantError = validateBatchCompletion(*batch);
		if (invariantError.length > 0)
		{
			string removeError;
			if (!remove(handle, removeError))
			{
				results = null;
				error = format!"cannot finalize parent tid=%d batch=%s: %s; cleanup failed: %s"
					(handle.parentTid, handle.batchId, invariantError, removeError);
				return false;
			}
			results = null;
			error = format!"cannot finalize parent tid=%d batch=%s: %s"
				(handle.parentTid, handle.batchId, invariantError);
			return false;
		}

		results = batch.results.dup;
		string removeError;
		if (!remove(handle, removeError))
		{
			results = null;
			error = removeError;
			return false;
		}
		error = "";
		return true;
	}

	/**
	 * Enqueue a `childDone` signal for an exact live batch slot ownership.
	 *
	 * Returns `true` with empty `error` when the target batch is already gone;
	 * this is treated as a stale late signal and safely ignored.
	 *
	 * Returns `false` with non-empty `error` when slot/child ownership does not
	 * match the live batch (invariant/routing bug).
	 */
	bool enqueueChildDone(BatchHandle handle, size_t slot, int childTid,
		McpResult result, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			error = "";
			return true;
		}
		if (slot >= batch.childTids.length || batch.childTids[slot] != childTid)
		{
			error = format!"dropping childDone with invalid slot ownership: parent=%d batch=%s child=%d slot=%s"
				(handle.parentTid, handle.batchId, childTid, slot);
			return false;
		}
		batch.eventQueue.fulfillOne(BatchSignal.childDone(handle.batchId, slot, childTid, result));
		error = "";
		return true;
	}

	/**
	 * Enqueue a child question signal for an exact live batch slot ownership.
	 *
	 * Returns `true` with empty `error` when the target batch is already gone;
	 * this is treated as a stale late signal and safely ignored.
	 *
	 * Returns `false` with non-empty `error` when slot/child ownership does not
	 * match the live batch (invariant/routing bug).
	 */
	bool enqueueQuestion(BatchHandle handle, size_t slot, int childTid,
		string questionText, int qid, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			error = "";
			return true;
		}
		if (slot >= batch.childTids.length || batch.childTids[slot] != childTid)
		{
			error = format!"dropping question with invalid slot ownership: parent=%d batch=%s child=%d slot=%s qid=%d"
				(handle.parentTid, handle.batchId, childTid, slot, qid);
			return false;
		}
		batch.eventQueue.fulfillOne(BatchSignal.question(handle.batchId, slot, childTid, questionText, qid));
		error = "";
		return true;
	}

	/**
	 * Remove one exact batch handle from all live indexes.
	 *
	 * `remove` is batch-specific and never targets "latest for parent". Returns
	 * `true` with empty `error` when the batch is already absent (stale late
	 * cleanup signal). Returns `false` with non-empty `error` on index invariant
	 * failures encountered while removing ownership/index entries.
	 */
	bool remove(BatchHandle handle, out string error)
	{
		auto key = batchKey(handle);
		auto batchPtr = key in activeBatches;
		if (batchPtr is null)
		{
			error = "";
			return true;
		}
		auto childTids = batchPtr.childTids.dup;
		auto doneSlots = batchPtr.done.dup;
		bool ok = true;
		string firstError;
		activeBatches.remove(key);

		if (auto idsPtr = key.parentTid in batchIdsByParentTid)
		{
			auto ids = *idsPtr;
			size_t write = 0;
			bool foundBatchId;
			foreach (id; ids)
			{
				if (id == key.batchId)
					foundBatchId = true;
				else
					ids[write++] = id;
			}
			ids.length = write;
			if (ids.length > 0)
				batchIdsByParentTid[key.parentTid] = ids;
			else
				batchIdsByParentTid.remove(key.parentTid);
			if (!foundBatchId)
			{
				ok = false;
				firstError = format!"parent index missing batch id while removing batch parent=%d batch=%s"
					(key.parentTid, key.batchId);
			}
		}
		else
		{
			ok = false;
			firstError = format!"missing parent index while removing batch parent=%d batch=%s"
				(key.parentTid, key.batchId);
		}

		foreach (i, childTid; childTids)
		{
			if (auto owner = childTid in batchKeyByChildTid)
			{
				if (*owner == key)
					batchKeyByChildTid.remove(childTid);
				else if (!doneSlots[i])
				{
					ok = false;
					if (firstError.length == 0)
						firstError = format!"unfinished child owner mismatch while removing batch parent=%d batch=%s child=%d owner_parent=%d owner_batch=%s"
							(key.parentTid, key.batchId, childTid, owner.parentTid, owner.batchId);
				}
			}
			else if (!doneSlots[i])
			{
				ok = false;
				if (firstError.length == 0)
					firstError = format!"missing unfinished child owner index while removing batch parent=%d batch=%s child=%d"
						(key.parentTid, key.batchId, childTid);
			}
		}
		error = firstError;
		return ok;
	}
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);
	assert(registry.exists(first));
	assert(registry.exists(second));

	size_t slot;
	bool done;
	BatchHandle owner;
	assert(registry.findOwnerOfChild(11, owner, slot, done, error), error);
	assert(error.length == 0);
	assert(owner.parentTid == 100 && owner.batchId == first.batchId);
	assert(!done);
	assert(registry.findOwnerOfChild(22, owner, slot, done, error), error);
	assert(error.length == 0);
	assert(owner.parentTid == 100 && owner.batchId == second.batchId);
	assert(!done);
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(!registry.create(100, [11], second, error));
	assert(error == "child tid=11 already owned by parent=100 batch=" ~ first.batchId.to!string);
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11, 22], handle, error), error);

	auto consumed = registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 11, McpResult("done", false)),
		(int childTid, int qid) => false,
		error);
	assert(error.length == 0);
	assert(consumed.kind == BatchConsumeKind.childDone);

	size_t slot;
	bool done;
	BatchHandle owner;
	assert(!registry.findOwnerOfChild(11, owner, slot, done, error));
	assert(error.length == 0);
	assert(registry.findOwnerOfChild(22, owner, slot, done, error), error);
	assert(error.length == 0);
	assert(owner.batchId == handle.batchId);
	assert(slot == 1);
	assert(!done);
	assert(registry.exists(handle));
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);

	assert(registry.remove(first, error), error);
	assert(!registry.exists(first));
	assert(registry.exists(second));
	bool hasLive;
	assert(registry.parentHasLiveBatches(100, hasLive, error), error);
	assert(hasLive);

	size_t slot;
	bool done;
	BatchHandle owner;
	assert(!registry.findOwnerOfChild(11, owner, slot, done, error));
	assert(registry.findOwnerOfChild(22, owner, slot, done, error), error);
	assert(error.length == 0);
	assert(owner.batchId == second.batchId);
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [31, 32], first, error), error);
	assert(registry.create(100, [41], second, error), error);

	int childTid;
	assert(registry.findFirstLiveChild(100, (int cTid) => cTid > 0, childTid, error), error);
	assert(error.length == 0);
	assert(childTid == 31);

	assert(registry.findFirstLiveChild(100, (int cTid) => cTid == 41, childTid, error), error);
	assert(error.length == 0);
	assert(childTid == 41);
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle;
	string error;
	bool hasLive;
	assert(registry.create(100, [11], handle, error), error);
	registry.batchIdsByParentTid[100] ~= handle.batchId + 1000;
	assert(!registry.parentHasLiveBatches(100, hasLive, error));
	assert(!hasLive);
	assert(error == "parent index points to missing batch parent=100 batch=" ~ (handle.batchId + 1000).to!string);
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	registry.batchIdsByParentTid.remove(100);
	assert(!registry.remove(handle, error));
	assert(error == "missing parent index while removing batch parent=100 batch=" ~ handle.batchId.to!string);
	assert(!registry.exists(handle));
}
