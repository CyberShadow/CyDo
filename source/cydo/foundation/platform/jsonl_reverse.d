module cydo.foundation.platform.jsonl_reverse;

/// Visit the complete lines of a JSONL file from newest to oldest, within the
/// byte range [`stopAt`, `end`). `stopAt` must be the start of a line (0, or an
/// offset an earlier call returned). A trailing segment without its newline,
/// a record still being written or cut off by a crash, is not a line yet and
/// is skipped. `visit` gets each non-empty line without its newline, and the
/// line's starting offset; it returns false to stop early. A line is only valid
/// during its callback.
///
/// Returns the offset just past the last complete line in the range (`stopAt`
/// when it holds none), which is where a later call resuming after this one
/// should stop.
///
/// The file is read backwards in `chunk`-sized pieces, so reaching the newest
/// line costs one read however large the file is; a line longer than a chunk
/// is carried across reads whole.
ulong foreachLineReverse(string path, ulong end, ulong stopAt,
	scope bool delegate(const(char)[] line, ulong lineStart) visit,
	size_t chunk = 64 << 10)
{
	import std.exception : enforce;
	import std.stdio : File;

	enforce(stopAt <= end, "foreachLineReverse: stopAt past end");
	enforce(chunk > 0, "foreachLineReverse: empty chunk");

	auto f = File(path, "rb");
	enforce(f.size() >= end, "foreachLineReverse: end past the end of " ~ path);

	// data holds the bytes from dataStart that are not handed out yet; its
	// first `fresh` bytes were just read, and the rest, carried over, are known
	// to hold no newline
	char[] data;
	ulong dataStart = end;
	size_t fresh = 0;
	ulong completeEnd = stopAt; // set once the newest newline is found
	bool haveNewline = false;
	ulong lineEnd; // absolute offset of the newline ending the current line

	while (true)
	{
		// scan the fresh bytes, right to left, for newlines
		for (auto i = cast(ptrdiff_t) fresh - 1; i >= 0; i--)
		{
			if (data[i] != '\n')
				continue;
			auto nl = dataStart + i;
			if (!haveNewline)
			{
				haveNewline = true;
				completeEnd = nl + 1;
			}
			else if (lineEnd > nl + 1)
			{
				if (!visit(data[i + 1 .. lineEnd - dataStart], nl + 1))
					return completeEnd;
			}
			lineEnd = nl;
		}

		if (dataStart == stopAt)
			break;

		// keep only the unconsumed head, then read the chunk before it
		auto keep = haveNewline ? data[0 .. cast(size_t)(lineEnd - dataStart)] : data;
		auto readStart = dataStart - stopAt > chunk ? dataStart - chunk : stopAt;
		fresh = cast(size_t)(dataStart - readStart);
		auto next = new char[fresh + keep.length];
		f.seek(readStart);
		auto got = f.rawRead(next[0 .. fresh]);
		enforce(got.length == fresh, "foreachLineReverse: short read from " ~ path);
		next[fresh .. $] = keep[];
		data = next;
		dataStart = readStart;
	}

	// stopAt starts a line, so what precedes the oldest newline is one
	if (haveNewline && lineEnd > stopAt)
		visit(data[0 .. lineEnd - dataStart], stopAt);
	return completeEnd;
}

unittest
{
	import std.exception : assertThrown, collectException;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;

	auto path = buildPath(tempDir(), "cydo-jsonl-reverse-" ~ thisProcessID.to!string ~ ".jsonl");
	scope (exit) collectException(remove(path));

	string[] lines(ulong end, ulong stopAt, size_t chunk, out ulong covered,
		size_t limit = size_t.max)
	{
		string[] seen;
		covered = foreachLineReverse(path, end, stopAt, (line, start) {
			seen ~= line.idup ~ "@" ~ start.to!string;
			return seen.length < limit;
		}, chunk);
		return seen;
	}

	ulong covered;
	write(path, "a\nbb\n\nccc\n");
	foreach (chunk; [1, 2, 3, 64])
	{
		// newest first, empty lines skipped, offsets of each line's start
		assert(lines(10, 0, chunk, covered) == ["ccc@6", "bb@2", "a@0"]);
		assert(covered == 10);
	}

	// a trailing record without its newline is not a line yet
	write(path, "a\nbb\npartial");
	assert(lines(12, 0, 2, covered) == ["bb@2", "a@0"]);
	assert(covered == 5);

	// a range that stops at an earlier call's end visits only what follows
	write(path, "a\nbb\nccc\ndddd\n");
	assert(lines(14, 5, 3, covered) == ["dddd@9", "ccc@5"]);
	assert(covered == 14);
	assert(lines(14, 14, 3, covered) == []);
	assert(covered == 14);

	// stopping early still reports the whole range as covered
	assert(lines(14, 0, 4, covered, 1) == ["dddd@9"]);
	assert(covered == 14);

	// a line longer than the chunk is carried whole
	write(path, "short\n" ~ "x".to!string ~ "0123456789abcdef" ~ "\nend\n");
	assert(lines(28, 0, 4, covered) == ["end@24", "x0123456789abcdef@6", "short@0"]);

	// no newline at all: nothing complete, nothing covered
	write(path, "no newline");
	assert(lines(10, 0, 4, covered) == []);
	assert(covered == 0);

	assertThrown(foreachLineReverse(path, 11, 0, (l, s) => true));
	assertThrown(foreachLineReverse(path, 4, 5, (l, s) => true));
}
