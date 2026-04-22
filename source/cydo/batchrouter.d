module cydo.batchrouter;

import std.format : format;

import ae.utils.promise : PromiseQueue;

import cydo.mcp : McpResult;
import cydo.task : BatchSignal;

package(cydo):

struct BatchState
{
	ulong batchId;
	McpResult[] results;
	bool[] done;
	size_t completed;
	size_t totalChildren;
	int[] childTids;            // ordered child tids
	size_t[int] slotByChildTid; // child tid -> slot in childTids/results
	PromiseQueue!BatchSignal eventQueue;

	bool trySlotForChild(int childTid, out size_t slot) const
	{
		auto slotPtr = childTid in slotByChildTid;
		if (slotPtr is null)
			return false;
		slot = *slotPtr;
		return true;
	}
}

enum BatchConsumeKind { ignored, childDone, question, invalid }

struct BatchConsumeResult
{
	BatchConsumeKind kind = BatchConsumeKind.ignored;
	string error;
	int childTid;
	int qid;
	string questionText;
}

BatchState buildBatchState(ulong batchId, int[] childTids, out string error)
{
	BatchState batch;
	batch.batchId = batchId;
	batch.totalChildren = childTids.length;
	batch.results = new McpResult[childTids.length];
	batch.done = new bool[childTids.length];
	batch.childTids = childTids.dup;

	foreach (i, childTid; childTids)
	{
		if (childTid <= 0)
		{
			error = format!"invalid child tid in batch: %d"(childTid);
			return batch;
		}
		if (childTid in batch.slotByChildTid)
		{
			error = format!"duplicate child tid in batch: %d"(childTid);
			return batch;
		}
		batch.slotByChildTid[childTid] = i;
	}

	error = "";
	return batch;
}

BatchConsumeResult consumeBatchSignal(ref BatchState batch, BatchSignal sig,
	scope bool delegate(int childTid, int qid) hasPendingQuestion)
{
	BatchConsumeResult result;
	if (sig.batchId != batch.batchId)
		return result;

	if (sig.slot >= batch.childTids.length)
	{
		result.kind = BatchConsumeKind.invalid;
		result.error = format!"slot %s out of range for child count %s"(sig.slot, batch.childTids.length);
		return result;
	}

	if (batch.childTids[sig.slot] != sig.childTid)
	{
		result.kind = BatchConsumeKind.invalid;
		result.error = format!"slot %s expects child tid %d but got %d"(sig.slot, batch.childTids[sig.slot], sig.childTid);
		return result;
	}

	size_t mappedSlot;
	if (!batch.trySlotForChild(sig.childTid, mappedSlot) || mappedSlot != sig.slot)
	{
		result.kind = BatchConsumeKind.invalid;
		result.error = format!"child tid %d maps to slot %s, signal targeted slot %s"(sig.childTid, mappedSlot, sig.slot);
		return result;
	}

	if (sig.kind == BatchSignal.Kind.childDone)
	{
		if (batch.done[sig.slot])
			return result; // duplicate completion for finished slot
		batch.results[sig.slot] = sig.result;
		batch.done[sig.slot] = true;
		batch.completed++;
		result.kind = BatchConsumeKind.childDone;
		return result;
	}

	if (!hasPendingQuestion(sig.childTid, sig.qid))
		return result; // stale question

	result.kind = BatchConsumeKind.question;
	result.childTid = sig.childTid;
	result.qid = sig.qid;
	result.questionText = sig.questionText;
	return result;
}

string validateBatchCompletion(in BatchState batch)
{
	if (batch.totalChildren != batch.childTids.length)
		return format!"batch child count mismatch: total=%s childTids=%s"(batch.totalChildren, batch.childTids.length);
	if (batch.completed != batch.totalChildren)
		return format!"batch completed mismatch: completed=%s total=%s"(batch.completed, batch.totalChildren);
	foreach (i, d; batch.done)
		if (!d)
			return format!"batch slot %s unfinished"(i);
	return "";
}

unittest
{
	string err;
	auto batch = buildBatchState(10, [101, 202], err);
	assert(err.length == 0);

	auto foreignBatch = consumeBatchSignal(batch,
		BatchSignal.childDone(99, 0, 101, McpResult("foreign-batch", false)),
		(int childTid, int qid) => false);
	assert(foreignBatch.kind == BatchConsumeKind.ignored);
	assert(batch.completed == 0);

	auto wrongSlot = consumeBatchSignal(batch,
		BatchSignal.childDone(10, 1, 101, McpResult("wrong-slot", false)),
		(int childTid, int qid) => false);
	assert(wrongSlot.kind == BatchConsumeKind.invalid);
	assert(batch.completed == 0);
}

unittest
{
	string err;
	auto batch = buildBatchState(11, [501], err);
	assert(err.length == 0);

	auto first = consumeBatchSignal(batch,
		BatchSignal.childDone(11, 0, 501, McpResult("first", false)),
		(int childTid, int qid) => false);
	assert(first.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 1);
	assert(batch.results[0].text == "first");

	auto duplicate = consumeBatchSignal(batch,
		BatchSignal.childDone(11, 0, 501, McpResult("duplicate", false)),
		(int childTid, int qid) => false);
	assert(duplicate.kind == BatchConsumeKind.ignored);
	assert(batch.completed == 1);
	assert(batch.results[0].text == "first");
}

unittest
{
	string err;
	auto batch = buildBatchState(12, [1, 2, 3], err);
	assert(err.length == 0);

	consumeBatchSignal(batch, BatchSignal.childDone(12, 2, 3, McpResult("C", false)),
		(int childTid, int qid) => false);
	consumeBatchSignal(batch, BatchSignal.childDone(12, 0, 1, McpResult("A", false)),
		(int childTid, int qid) => false);
	consumeBatchSignal(batch, BatchSignal.childDone(12, 1, 2, McpResult("B", false)),
		(int childTid, int qid) => false);

	assert(batch.completed == 3);
	assert(batch.results[0].text == "A");
	assert(batch.results[1].text == "B");
	assert(batch.results[2].text == "C");
	assert(validateBatchCompletion(batch).length == 0);
}

unittest
{
	string err;
	auto batch = buildBatchState(13, [7, 8], err);
	assert(err.length == 0);

	auto doneA = consumeBatchSignal(batch,
		BatchSignal.childDone(13, 0, 7, McpResult("slot-a", false)),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(doneA.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 1);

	auto staleQuestion = consumeBatchSignal(batch,
		BatchSignal.question(13, 1, 8, "stale", 41),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(staleQuestion.kind == BatchConsumeKind.ignored);
	assert(batch.completed == 1);
	assert(batch.done[0] && !batch.done[1]);

	auto question = consumeBatchSignal(batch,
		BatchSignal.question(13, 1, 8, "ready", 42),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(question.kind == BatchConsumeKind.question);
	assert(question.childTid == 8);
	assert(question.qid == 42);
	assert(question.questionText == "ready");
	assert(batch.completed == 1);
	assert(batch.done[0] && !batch.done[1]);

	auto doneB = consumeBatchSignal(batch,
		BatchSignal.childDone(13, 1, 8, McpResult("slot-b", false)),
		(int childTid, int qid) => false);
	assert(doneB.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 2);
	assert(batch.results[0].text == "slot-a");
	assert(batch.results[1].text == "slot-b");
	assert(validateBatchCompletion(batch).length == 0);
}
