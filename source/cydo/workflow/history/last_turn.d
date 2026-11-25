module cydo.workflow.history.last_turn;

// When a transcript last saw work: the time of its newest conversation record,
// as the transcript's own agent recognizes them, found by reading the file
// newest line first. Startup uses this to recover last_active for tasks that
// were alive when the backend stopped.
//
// A memo carries how far the previous read got. A transcript that has only
// grown since is read from that point on, so a restart costs the bytes
// appended since the last one rather than the file's size; one that shrank or
// was rewritten in place (an edit, an undo) is read whole again.

import ae.utils.time.types : AbsTime;

import cydo.agent.contract : Agent;

/// What one read of a transcript leaves for the next.
struct LastTurnMemo
{
	/// complete lines up to this offset were read
	ulong scannedEnd;
	/// the bytes just before scannedEnd, as they were read; a file holding
	/// different bytes there was rewritten rather than appended to
	const(ubyte)[] endTail;
	/// the newest conversation record before scannedEnd, AbsTime.init if none
	AbsTime lastTurn;
}

/// How many bytes before scannedEnd a memo keeps to recognize the file.
enum size_t lastTurnMemoTail = 256;

/// The newest conversation record in the transcript at `path`, AbsTime.init
/// if it holds none, updating `memo` to cover the file as it stands.
AbsTime lastConversationTime(Agent agent, string path, ref LastTurnMemo memo)
{
	import std.file : getSize;
	import cydo.foundation.platform.jsonl_reverse : foreachLineReverse;

	auto size = getSize(path);
	if (memo.scannedEnd > size || readTail(path, memo.scannedEnd) != memo.endTail)
		memo = LastTurnMemo.init;

	// appended lines come after older ones, so the first record found from the
	// end is the newest
	AbsTime newest;
	auto covered = foreachLineReverse(path, size, memo.scannedEnd, (line, start) {
		newest = agent.conversationRecordTime(line);
		return newest == AbsTime.init;
	});
	if (newest != AbsTime.init)
		memo.lastTurn = newest;
	memo.scannedEnd = covered;
	memo.endTail = readTail(path, covered);
	return memo.lastTurn;
}

private ubyte[] readTail(string path, ulong end)
{
	import std.exception : enforce;
	import std.stdio : File;

	auto length = end < lastTurnMemoTail ? cast(size_t) end : lastTurnMemoTail;
	auto buf = new ubyte[length];
	if (length == 0)
		return buf;
	auto f = File(path, "rb");
	f.seek(end - length);
	enforce(f.rawRead(buf).length == length, "short read from " ~ path);
	return buf;
}

unittest
{
	import std.conv : to;
	import std.exception : collectException;
	import std.file : append, remove, tempDir, write;
	import std.path : buildPath;
	import std.process : thisProcessID;

	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.datetime.systime : SysTime;

	auto agent = new ClaudeCodeAgent;
	auto path = buildPath(tempDir(), "cydo-last-turn-" ~ thisProcessID.to!string ~ ".jsonl");
	scope (exit) collectException(remove(path));

	string user(string ts) { return `{"type":"user","message":{"content":"x"},"timestamp":"` ~ ts ~ `"}` ~ "\n"; }
	string noise(string ts) { return `{"type":"queue-operation","operation":"enqueue","timestamp":"` ~ ts ~ `"}` ~ "\n"; }
	auto at(string ts) { return AbsTime(SysTime.fromISOExtString(ts).stdTime); }

	// the newest conversation record, past the bookkeeping after it
	write(path, user("2026-07-20T10:00:00Z") ~ user("2026-07-25T18:52:09.643Z")
		~ noise("2026-07-27T22:50:00Z") ~ `{"type":"last-prompt","lastPrompt":"x"}` ~ "\n");
	LastTurnMemo memo;
	assert(lastConversationTime(agent, path, memo) == at("2026-07-25T18:52:09.643Z"));
	auto firstEnd = memo.scannedEnd;

	// appended bookkeeping alone keeps the remembered time, and the read
	// starts where the last one stopped
	append(path, noise("2026-07-28T09:00:00Z"));
	assert(lastConversationTime(agent, path, memo) == at("2026-07-25T18:52:09.643Z"));
	assert(memo.scannedEnd > firstEnd);

	// a record appended later wins
	append(path, user("2026-07-29T12:00:00Z"));
	assert(lastConversationTime(agent, path, memo) == at("2026-07-29T12:00:00Z"));

	// a half-written record is left for the next read
	append(path, `{"type":"user","timestamp":"2026-07-30T00:00:00Z"`);
	assert(lastConversationTime(agent, path, memo) == at("2026-07-29T12:00:00Z"));
	append(path, "}\n");
	assert(lastConversationTime(agent, path, memo) == at("2026-07-30T00:00:00Z"));

	// a file rewritten to the same length or longer is recognized by its bytes
	// and read whole: the remembered time is not carried over
	write(path, user("2026-07-01T00:00:00Z") ~ noise("2026-08-01T00:00:00Z")
		~ noise("2026-08-01T00:00:01Z") ~ noise("2026-08-01T00:00:02Z")
		~ noise("2026-08-01T00:00:03Z") ~ noise("2026-08-01T00:00:04Z"));
	assert(lastConversationTime(agent, path, memo) == at("2026-07-01T00:00:00Z"));

	// a shrunk file is read whole too
	write(path, noise("2026-08-02T00:00:00Z"));
	assert(lastConversationTime(agent, path, memo) == AbsTime.init);

	// a fresh memo reads the whole file
	write(path, user("2026-08-03T00:00:00Z"));
	LastTurnMemo fresh;
	assert(lastConversationTime(agent, path, fresh) == at("2026-08-03T00:00:00Z"));
}
