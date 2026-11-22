module cydo.domain.tasks.lifecycle;

import cydo.domain.tasks.model : TaskData, TaskStatus;
import std.exception : enforce;

enum TaskNotificationChange
{
	preserve,
	clearBody,
	clearAttention,
}

bool isLegalTaskStatusTransition(TaskStatus from, TaskStatus to)
{
	final switch (from)
	{
	case TaskStatus.pending:
		return to == TaskStatus.active || to == TaskStatus.waiting || to == TaskStatus.failed;
	case TaskStatus.active:
		return to == TaskStatus.alive || to == TaskStatus.waiting
			|| to == TaskStatus.completed || to == TaskStatus.failed;
	case TaskStatus.alive:
		return to == TaskStatus.active || to == TaskStatus.waiting
			|| to == TaskStatus.completed || to == TaskStatus.failed;
	case TaskStatus.waiting:
		return to == TaskStatus.active || to == TaskStatus.alive
			|| to == TaskStatus.completed || to == TaskStatus.failed;
	case TaskStatus.completed:
		return to == TaskStatus.active || to == TaskStatus.alive || to == TaskStatus.failed;
	case TaskStatus.failed:
		return to == TaskStatus.active || to == TaskStatus.alive || to == TaskStatus.completed;
	case TaskStatus.importable:
		return to == TaskStatus.completed;
	}
}

struct TaskLifecycle
{
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, string status) persistStatus;
	void delegate(int tid, bool needsAttention) persistNeedsAttention;
	void delegate(int tid) publishSnapshot;
	void delegate(int tid) onTaskTerminal;

	void transitionTask(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification = TaskNotificationChange.preserve)
	{
		transitionTask(tid, [expectedFrom], to, notification);
	}

	void transitionTask(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification = TaskNotificationChange.preserve)
	{
		applyTransition(tid, expectedFrom, to, notification);
		publishSnapshot(tid);
	}

	/// Apply and persist the status when the caller owns the snapshot.
	void applyTransition(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification)
	{
		enforce(expectedFrom.length > 0, "Task transition requires an expected origin");
		auto td = getTask(tid);
		enforce(td !is null, "Task transition requested for missing task");
		bool expected;
		foreach (from; expectedFrom)
			expected = expected || td.status == from;
		enforce(expected, "Task transition origin mismatch");
		enforce(isLegalTaskStatusTransition(td.status, to), "Illegal task status transition");

		bool attentionChanged = notification == TaskNotificationChange.clearAttention
			&& td.needsAttention;
		td.status = to;
		final switch (notification)
		{
		case TaskNotificationChange.preserve:
			break;
		case TaskNotificationChange.clearBody:
			td.notificationBody = "";
			break;
		case TaskNotificationChange.clearAttention:
			td.notificationBody = "";
			td.needsAttention = false;
			break;
		}

		persistStatus(tid, cast(string) to);
		if (to == TaskStatus.completed || to == TaskStatus.failed)
			if (onTaskTerminal !is null)
				onTaskTerminal(tid);
		if (attentionChanged)
			persistNeedsAttention(tid, false);
	}
}

unittest
{
	TaskStatus[][TaskStatus] allowed = [
		TaskStatus.pending: [TaskStatus.active, TaskStatus.waiting, TaskStatus.failed],
		TaskStatus.active: [TaskStatus.alive, TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed],
		TaskStatus.alive: [TaskStatus.active, TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed],
		TaskStatus.waiting: [TaskStatus.active, TaskStatus.alive, TaskStatus.completed, TaskStatus.failed],
		TaskStatus.completed: [TaskStatus.active, TaskStatus.alive, TaskStatus.failed],
		TaskStatus.failed: [TaskStatus.active, TaskStatus.alive, TaskStatus.completed],
		TaskStatus.importable: [TaskStatus.completed],
	];
	foreach (from; [TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
		TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed, TaskStatus.importable])
	{
		foreach (to; allowed[from])
			assert(isLegalTaskStatusTransition(from, to));
		assert(!isLegalTaskStatusTransition(from, from));
	}
	assert(!isLegalTaskStatusTransition(TaskStatus.importable, TaskStatus.active));
}

unittest
{
	import std.exception : assertThrown;

	TaskData[int] tasks;
	tasks[1] = TaskData(1, "local", "/tmp/project");
	tasks[1].notificationBody = "notice";
	tasks[1].needsAttention = true;
	string[] events;
	auto lifecycle = TaskLifecycle(
		getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
		persistStatus: (int tid, string status) {
			assert(cast(string) tasks[tid].status == status);
			events ~= "status:" ~ status;
		},
		persistNeedsAttention: (int tid, bool needsAttention) {
			assert(!tasks[tid].needsAttention);
			events ~= "attention";
		},
		publishSnapshot: (int tid) {
			events ~= "snapshot";
		},
	);

	lifecycle.transitionTask(1, TaskStatus.pending, TaskStatus.active,
		TaskNotificationChange.clearBody);
	assert(tasks[1].notificationBody.length == 0);
	assert(tasks[1].needsAttention);
	assert(events == ["status:active", "snapshot"]);

	events.length = 0;
	tasks[1].notificationBody = "notice";
	tasks[1].hasPendingQuestion = true;
	lifecycle.transitionTask(1, TaskStatus.active, TaskStatus.waiting,
		TaskNotificationChange.clearAttention);
	assert(!tasks[1].needsAttention);
	assert(tasks[1].notificationBody.length == 0);
	assert(tasks[1].hasPendingQuestion);
	assert(events == ["status:waiting", "attention", "snapshot"]);

	events.length = 0;
	tasks[1].notificationBody = "notice";
	lifecycle.transitionTask(1, TaskStatus.waiting, TaskStatus.alive,
		TaskNotificationChange.clearAttention);
	assert(tasks[1].notificationBody.length == 0);
	assert(events == ["status:alive", "snapshot"]);

	events.length = 0;
	assertThrown!Exception(lifecycle.transitionTask(1, TaskStatus.active, TaskStatus.alive));
	assert(events.length == 0);
	assertThrown!Exception(lifecycle.transitionTask(1, TaskStatus.waiting, TaskStatus.waiting));
	assert(events.length == 0);
	assertThrown!Exception(lifecycle.transitionTask(2, TaskStatus.pending, TaskStatus.active));
	assert(events.length == 0);
}
