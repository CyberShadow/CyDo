module cydo.system.known_messages;

import std.typecons : Nullable;

import cydo.system.framing : wrapSystemMessage;

enum KnownSystemMessageKind
{
	taskPrompt,
	sessionStart,
	followUpFromParent,
	questionFromTask,
	subTaskWaitingForAnswer,
	missingRequiredOutputs,
	handoff,
	subTaskResults,
	restartNudge,
	postCompactionTaskModeReminder,
	modeSwitch,
}

struct KnownSystemMessageMatch
{
	KnownSystemMessageKind kind;
	string label;          // user-friendly collapsed label
	string sourceType;     // populated when subject has "<source> -> <edge>" tail
	string edgeName;       // populated for edge-bearing kinds
	Nullable!int qid;
	Nullable!int tid;
	Nullable!string title;
}

string systemMessageSubject(KnownSystemMessageKind kind)
{
	final switch (kind)
	{
	case KnownSystemMessageKind.taskPrompt:
		return "Task prompt";
	case KnownSystemMessageKind.sessionStart:
		return "Session start";
	case KnownSystemMessageKind.followUpFromParent:
		return "Follow-up question from parent task";
	case KnownSystemMessageKind.questionFromTask:
		return "Question from task";
	case KnownSystemMessageKind.subTaskWaitingForAnswer:
		return "Sub-task waiting for answer";
	case KnownSystemMessageKind.missingRequiredOutputs:
		return "Missing required outputs";
	case KnownSystemMessageKind.handoff:
		return "Handoff";
	case KnownSystemMessageKind.subTaskResults:
		return "Sub-task results";
	case KnownSystemMessageKind.restartNudge:
		return "Restart nudge";
	case KnownSystemMessageKind.postCompactionTaskModeReminder:
		return "Post-compaction task mode reminder";
	case KnownSystemMessageKind.modeSwitch:
		return "Mode switch";
	}
}

/// Build the task-prompt subject line encoding the edge identity.
/// When parentType and edgeName are both non-empty, encodes
/// "Task prompt: <parentType> -> <edgeName>". Otherwise degrades to
/// "Task prompt: <edgeName>" (degenerate — no edge traversed).
string taskPromptSubject(string parentType, string edgeName)
{
	if (parentType.length > 0 && edgeName.length > 0)
		return "Task prompt: " ~ parentType ~ " -> " ~ edgeName;
	return "Task prompt: " ~ (edgeName.length > 0 ? edgeName : parentType);
}

string sessionStartSubject(string entryPointName)
{
	return "Session start: " ~ entryPointName;
}

string followUpFromParentSubject(int qid)
{
	import std.conv : to;
	return systemMessageSubject(KnownSystemMessageKind.followUpFromParent)
		~ " (qid=" ~ to!string(qid) ~ ")";
}

string questionFromTaskSubject(int askerTid, int qid)
{
	import std.conv : to;
	return "Question from task " ~ to!string(askerTid) ~ " (qid=" ~ to!string(qid) ~ ")";
}

string subTaskWaitingForAnswerSubject(string title, int tid, int qid)
{
	import std.conv : to;
	return "Sub-task \"" ~ title ~ "\" (tid=" ~ to!string(tid)
		~ ") is waiting for your answer (qid=" ~ to!string(qid) ~ ")";
}

string modeSwitchSubject(string sourceType, string edgeName)
{
	return "Mode switch: " ~ sourceType ~ " -> " ~ edgeName;
}

string handoffSubject(string sourceType, string edgeName)
{
	return "Handoff: " ~ sourceType ~ " -> " ~ edgeName;
}

string systemMessagePrefix(string systemKeyword, KnownSystemMessageKind kind)
{
	return "[" ~ systemKeyword ~ ": " ~ systemMessageSubject(kind) ~ "]";
}

string wrapKnownSystemMessage(string systemKeyword, KnownSystemMessageKind kind, string body = null,
	string subject = null)
{
	auto resolvedSubject = subject.length > 0 ? subject : systemMessageSubject(kind);
	return wrapSystemMessage(systemKeyword, resolvedSubject, body);
}

bool tryParseStrictPositiveInt(string text, out int value)
{
	import std.conv : to;

	if (text.length == 0)
		return false;
	foreach (ch; text)
		if (ch < '0' || ch > '9')
			return false;
	try
		value = to!int(text);
	catch (Exception)
		return false;
	return true;
}

/// Try to match a system-message subject line to a known kind.
///
/// For edge-bearing kinds (taskPrompt, handoff, modeSwitch), the subject
/// encodes `<source> -> <edge>`. The label exposed to the frontend uses only
/// the edge name (e.g. "Mode switch: plan_mode") — the source type is an
/// internal routing detail that the user never sees.
///
/// Legacy subjects without "->" parse with edgeName == "" → label-only meta.
bool tryKnownSystemMessageMatch(string subject, out KnownSystemMessageMatch match)
{
	import std.algorithm : startsWith, endsWith;
	import std.algorithm.searching : countUntil;
	import std.string : indexOf;

	match = KnownSystemMessageMatch.init;

	/// Parse the suffix of an edge-bearing subject as either
	/// "<source> -> <edge>" or "<single>", populating the match fields.
	static void parseEdgeSuffix(string suffix, ref KnownSystemMessageMatch m, string kindLabel)
	{
		enum arrowSep = " -> ";
		auto arrowIdx = suffix.indexOf(arrowSep);
		if (arrowIdx >= 0)
		{
			m.sourceType = suffix[0 .. cast(size_t) arrowIdx];
			m.edgeName = suffix[cast(size_t) arrowIdx + arrowSep.length .. $];
			m.label = kindLabel ~ ": " ~ m.edgeName;
		}
		else
		{
			// Legacy format or degenerate path — single token, no edge
			m.edgeName = "";
			m.sourceType = "";
			m.label = kindLabel ~ ": " ~ suffix;
		}
	}

	enum taskPromptPrefix = "Task prompt: ";
	if (subject.startsWith(taskPromptPrefix) && subject.length > taskPromptPrefix.length)
	{
		match.kind = KnownSystemMessageKind.taskPrompt;
		parseEdgeSuffix(subject[taskPromptPrefix.length .. $], match, "Task prompt");
		return true;
	}

	enum sessionStartPrefix = "Session start: ";
	if (subject.startsWith(sessionStartPrefix) && subject.length > sessionStartPrefix.length)
	{
		match.kind = KnownSystemMessageKind.sessionStart;
		// Entry points are top-level — no source needed; edgeName is the entry point name
		match.edgeName = subject[sessionStartPrefix.length .. $];
		match.label = subject;
		return true;
	}

	enum modeSwitchPrefix = "Mode switch: ";
	if (subject.startsWith(modeSwitchPrefix) && subject.length > modeSwitchPrefix.length)
	{
		match.kind = KnownSystemMessageKind.modeSwitch;
		parseEdgeSuffix(subject[modeSwitchPrefix.length .. $], match, "Mode switch");
		return true;
	}

	enum handoffPrefix = "Handoff: ";
	if (subject.startsWith(handoffPrefix) && subject.length > handoffPrefix.length)
	{
		match.kind = KnownSystemMessageKind.handoff;
		parseEdgeSuffix(subject[handoffPrefix.length .. $], match, "Handoff");
		return true;
	}

	enum followUpPrefix = "Follow-up question from parent task (qid=";
	enum followUpSuffix = ")";
	if (subject.startsWith(followUpPrefix) && subject.endsWith(followUpSuffix))
	{
		auto qidText = subject[followUpPrefix.length .. $ - followUpSuffix.length];
		int qid;
		if (!tryParseStrictPositiveInt(qidText, qid))
			return false;
		match.kind = KnownSystemMessageKind.followUpFromParent;
		match.label = "Follow-up from parent";
		match.qid = Nullable!int(qid);
		return true;
	}

	enum questionFromTaskPrefix = "Question from task ";
	if (subject.startsWith(questionFromTaskPrefix) && subject.endsWith(")"))
	{
		// Format: "Question from task <tid> (qid=<qid>)"
		auto tail = subject[questionFromTaskPrefix.length .. $];
		enum qidSep = " (qid=";
		auto qidSepIdx = tail.indexOf(qidSep);
		if (qidSepIdx < 0)
			return false;
		auto tidText = tail[0 .. cast(size_t) qidSepIdx];
		auto qidText = tail[cast(size_t) qidSepIdx + qidSep.length .. $ - 1];
		int tid, qid;
		if (!tryParseStrictPositiveInt(tidText, tid) || !tryParseStrictPositiveInt(qidText, qid))
			return false;
		match.kind = KnownSystemMessageKind.questionFromTask;
		match.label = "Question from task";
		match.tid = Nullable!int(tid);
		match.qid = Nullable!int(qid);
		return true;
	}

	enum waitingPrefix = "Sub-task \"";
	enum waitingTitleSuffix = "\" (tid=";
	enum waitingMid = ") is waiting for your answer (qid=";
	enum waitingSuffix = ")";
	if (subject.startsWith(waitingPrefix) && subject.endsWith(waitingSuffix))
	{
		auto tail = subject[waitingPrefix.length .. $];
		auto titleEnd = tail.countUntil(waitingTitleSuffix);
		if (titleEnd < 0)
			return false;
		auto titleLen = cast(size_t) titleEnd;
		auto title = tail[0 .. titleLen];
		auto afterTitle = tail[titleLen + waitingTitleSuffix.length .. $];

		auto midPos = afterTitle.countUntil(waitingMid);
		if (midPos < 0)
			return false;
		auto tidText = afterTitle[0 .. cast(size_t) midPos];
		auto qidText = afterTitle[cast(size_t) midPos + waitingMid.length .. $ - waitingSuffix.length];
		int tid, qid;
		if (!tryParseStrictPositiveInt(tidText, tid) || !tryParseStrictPositiveInt(qidText, qid))
			return false;
		match.kind = KnownSystemMessageKind.subTaskWaitingForAnswer;
		match.label = "Sub-task waiting for answer";
		match.tid = Nullable!int(tid);
		match.qid = Nullable!int(qid);
		match.title = Nullable!string(title);
		return true;
	}

	if (subject == systemMessageSubject(KnownSystemMessageKind.missingRequiredOutputs))
	{
		match.kind = KnownSystemMessageKind.missingRequiredOutputs;
		match.label = subject;
		return true;
	}
	if (subject == systemMessageSubject(KnownSystemMessageKind.subTaskResults))
	{
		match.kind = KnownSystemMessageKind.subTaskResults;
		match.label = subject;
		return true;
	}
	if (subject == systemMessageSubject(KnownSystemMessageKind.restartNudge))
	{
		match.kind = KnownSystemMessageKind.restartNudge;
		match.label = subject;
		return true;
	}
	if (subject == systemMessageSubject(KnownSystemMessageKind.postCompactionTaskModeReminder))
	{
		match.kind = KnownSystemMessageKind.postCompactionTaskModeReminder;
		match.label = subject;
		return true;
	}
	return false;
}

unittest
{
	auto subject = questionFromTaskSubject(42, 999);
	KnownSystemMessageMatch m;
	assert(tryKnownSystemMessageMatch(subject, m), subject);
	assert(m.kind == KnownSystemMessageKind.questionFromTask);
	assert(m.tid.get == 42);
	assert(m.qid.get == 999);
	assert(m.label == "Question from task");

	KnownSystemMessageMatch bad;
	assert(!tryKnownSystemMessageMatch("Question from task abc (qid=1)", bad));
	assert(!tryKnownSystemMessageMatch("Question from task 1 (qid=abc)", bad));
	assert(!tryKnownSystemMessageMatch("Question from task 1 (noqid)", bad));
}

unittest
{
	import std.conv : to;
	import std.file : exists, thisExePath;
	import std.path : buildPath, dirName;
	import std.traits : EnumMembers;

	static string sampleSubject(KnownSystemMessageKind kind)
	{
		final switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
			return "Task prompt: parent -> edge";
		case KnownSystemMessageKind.sessionStart:
			return "Session start: agentic";
		case KnownSystemMessageKind.followUpFromParent:
			return "Follow-up question from parent task (qid=1)";
		case KnownSystemMessageKind.questionFromTask:
			return "Question from task 1 (qid=2)";
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "Sub-task \"test\" (tid=1) is waiting for your answer (qid=2)";
		case KnownSystemMessageKind.missingRequiredOutputs:
		case KnownSystemMessageKind.subTaskResults:
		case KnownSystemMessageKind.restartNudge:
		case KnownSystemMessageKind.postCompactionTaskModeReminder:
			return systemMessageSubject(kind);
		case KnownSystemMessageKind.handoff:
			return "Handoff: source -> target";
		case KnownSystemMessageKind.modeSwitch:
			return "Mode switch: source -> target";
		}
	}

	foreach (kind; EnumMembers!KnownSystemMessageKind)
	{
		auto subject = sampleSubject(kind);

		KnownSystemMessageMatch m;
		assert(tryKnownSystemMessageMatch(subject, m),
			"tryKnownSystemMessageMatch failed for kind " ~ to!string(kind)
			~ " with subject: " ~ subject);
		assert(m.kind == kind,
			"kind mismatch: expected " ~ to!string(kind)
			~ ", got " ~ to!string(m.kind));
	}

	string defsDir = "defs/prompts";
	if (!exists(defsDir))
	{
		auto exeDir = dirName(thisExePath);
		defsDir = buildPath(exeDir, "../defs/prompts");
		if (!exists(defsDir))
			return;
	}

	foreach (templateName; [
		"follow_up_from_parent.md",
		"question_from_task.md",
		"sub_task_waiting_for_answer.md",
	])
	{
		auto fullPath = buildPath(defsDir, templateName);
		assert(exists(fullPath), "template file missing: " ~ fullPath);
	}
}
