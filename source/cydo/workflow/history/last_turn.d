module cydo.workflow.history.last_turn;

// When a task was last actually worked on, read from the tail of its
// transcript.
//
// The obvious signals do not survive a backend restart. The startup sweep
// resumes every in-flight session, and each resume appends to that session's
// transcript, so the file's mtime becomes the restart time for every task at
// once. last_active is worse still: it is cleared on session start and
// recovered from that same mtime, so a restart collapses every task onto one
// timestamp and the ordering it feeds is noise.
//
// A resume writes session and meta records, never a conversation turn, so the
// newest user/assistant record in the file steps over the restart entirely.
// That is the value this module recovers.

import std.datetime.systime : SysTime;

/// Newest user/assistant timestamp in a transcript, as StdTime. Returns 0 when
/// the file is missing, unreadable, or holds no conversation turn (an empty or
/// resume-only transcript), which callers treat as "unknown" and fall back on.
///
/// Only the tail is read: transcripts run to tens of megabytes and this is
/// called for every task at startup. The window grows if the tail holds no
/// turn, so a session that was resumed repeatedly without being used still
/// resolves rather than silently reporting 0.
long lastTurnStdTime(string path, size_t maxBytes = 8 << 20) nothrow
{
	static immutable size_t[] windows = [64 << 10, 1 << 20, 8 << 20];
	foreach (window; windows)
	{
		if (window > maxBytes)
			break;
		bool wholeFile;
		auto found = scanTail(path, window, wholeFile);
		if (found != 0 || wholeFile)
			return found;
	}
	return 0;
}

/// Scan the last `window` bytes for the newest conversation turn. Sets
/// `wholeFile` when the window covered the entire file, so the caller knows a
/// miss is final rather than an artifact of the window size.
private long scanTail(string path, size_t window, out bool wholeFile) nothrow
{
	import std.stdio : File;

	wholeFile = false;
	try
	{
		auto f = File(path, "rb");
		scope(exit) f.close();
		auto size = f.size();
		if (size == 0)
		{
			wholeFile = true;
			return 0;
		}

		ulong start = size > window ? size - window : 0;
		wholeFile = start == 0;
		f.seek(start);
		auto buf = new ubyte[cast(size_t)(size - start)];
		auto chunk = f.rawRead(buf);

		auto text = cast(string) chunk.idup;
		// a mid-file window almost certainly starts inside a record; that
		// partial first line would fail to parse anyway, but dropping it keeps
		// the intent explicit
		if (!wholeFile)
		{
			import std.string : indexOf;
			auto nl = text.indexOf('\n');
			text = nl < 0 ? "" : text[nl + 1 .. $];
		}

		long newest = 0;
		import std.algorithm : splitter;
		foreach (line; text.splitter('\n'))
		{
			auto ts = turnTimestamp(line);
			if (ts > newest)
				newest = ts;
		}
		return newest;
	}
	catch (Exception)
		return 0;
	catch (Error)
		return 0;
}

/// StdTime of one transcript line, or 0 if it is not a conversation turn.
///
/// Parsed by hand rather than by deserializing: this runs over every line of
/// every task's tail at startup, and the records carry large nested payloads
/// that would be built and thrown away.
///
/// The agents write different shapes, so both are recognized:
///   claude: {"type":"user"|"assistant", ..., "timestamp":"..."}
///   codex:  {"timestamp":"...", "type":"response_item", "payload":{...}}
/// What matters either way is excluding the records a resume writes (claude's
/// summary and queue-operation, codex's session_meta and turn_context), since
/// counting those is what made every task look equally recent.
private long turnTimestamp(const(char)[] line) nothrow
{
	import std.string : indexOf;

	if (line.length == 0)
		return 0;
	if (line.indexOf(`"type":"user"`) < 0
		&& line.indexOf(`"type":"assistant"`) < 0
		&& line.indexOf(`"type":"response_item"`) < 0)
		return 0;

	auto key = line.indexOf(`"timestamp":"`);
	if (key < 0)
		return 0;
	auto valueStart = key + `"timestamp":"`.length;
	auto rest = line[valueStart .. $];
	auto close = rest.indexOf('"');
	if (close < 0)
		return 0;

	try
		return SysTime.fromISOExtString(rest[0 .. close]).stdTime;
	catch (Exception)
		return 0;
}

unittest
{
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.exception : collectException;

	auto path = buildPath(tempDir(), "cydo-last-turn-test.jsonl");
	scope(exit) collectException(remove(path));

	// a transcript whose newest records are the meta ones a resume writes:
	// the reported time must be the last real turn, not the resume
	write(path,
		`{"type":"user","timestamp":"2026-07-20T10:00:00.000Z"}` ~ "\n" ~
		`{"type":"assistant","timestamp":"2026-07-25T18:52:09.643Z"}` ~ "\n" ~
		`{"type":"summary","timestamp":"2026-07-27T22:50:00.000Z"}` ~ "\n" ~
		`{"type":"queue-operation","timestamp":"2026-07-27T22:50:01.000Z"}` ~ "\n");
	auto expected = SysTime.fromISOExtString("2026-07-25T18:52:09.643Z").stdTime;
	assert(lastTurnStdTime(path) == expected);

	// a transcript with no turns at all reports unknown rather than guessing
	write(path, `{"type":"session","timestamp":"2026-07-27T22:50:00.000Z"}` ~ "\n");
	assert(lastTurnStdTime(path) == 0);

	// malformed lines are skipped, not fatal
	write(path,
		"not json\n" ~
		`{"type":"user","timestamp":"garbage"}` ~ "\n" ~
		`{"type":"user","timestamp":"2026-07-26T08:00:00.000Z"}` ~ "\n");
	assert(lastTurnStdTime(path) ==
		SysTime.fromISOExtString("2026-07-26T08:00:00.000Z").stdTime);

	assert(lastTurnStdTime(buildPath(tempDir(), "cydo-no-such-file.jsonl")) == 0);

	// codex writes a different shape: response_item is the real work, while
	// session_meta and turn_context are what a resume leaves behind
	write(path,
		`{"timestamp":"2026-07-21T21:51:07.249Z","type":"response_item","payload":{"type":"message","role":"assistant"}}` ~ "\n" ~
		`{"timestamp":"2026-07-27T23:50:00.000Z","type":"session_meta","payload":{"session_id":"x"}}` ~ "\n" ~
		`{"timestamp":"2026-07-27T23:50:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/project"}}` ~ "\n");
	assert(lastTurnStdTime(path) ==
		SysTime.fromISOExtString("2026-07-21T21:51:07.249Z").stdTime);

	// a turn buried behind more than the first window of resume records is
	// still found, because the window grows
	import std.array : replicate;
	string padded;
	padded ~= `{"type":"user","timestamp":"2026-07-26T08:00:00.000Z"}` ~ "\n";
	foreach (i; 0 .. 2000)
		padded ~= `{"type":"session","timestamp":"2026-07-27T22:50:00.000Z","pad":"`
			~ "x".replicate(64) ~ `"}` ~ "\n";
	write(path, padded);
	assert(lastTurnStdTime(path) ==
		SysTime.fromISOExtString("2026-07-26T08:00:00.000Z").stdTime);
}
