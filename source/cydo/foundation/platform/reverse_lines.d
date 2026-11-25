module cydo.foundation.platform.reverse_lines;

/// Visit the newline-terminated lines of `path` from last to first, reading
/// backwards in `chunkSize` pieces. A trailing segment without its newline (a
/// record still being written, or cut off by a crash) is not a line and is
/// skipped; empty lines are skipped. `visit` returns false to stop. Slices are
/// GC-owned and never overwritten, so they remain valid after the callback.
void foreachLineReverse(string path, scope bool delegate(string line) visit,
	size_t chunkSize = 64 << 10)
{
	import std.algorithm : min;
	import std.exception : enforce;
	import std.stdio : File;

	assert(chunkSize > 0);
	auto file = File(path, "rb");
	auto dataStart = file.size();
	bool foundNewline;
	string[] pieces;
	size_t pendingLength;

	bool visitLine(string first)
	{
		if (pieces.length == 0)
			return first.length == 0 || visit(first);

		auto line = new char[first.length + pendingLength];
		line[0 .. first.length] = first;
		auto offset = first.length;
		foreach_reverse (piece; pieces)
		{
			line[offset .. offset + piece.length] = piece;
			offset += piece.length;
		}
		pieces = null;
		pendingLength = 0;
		return visit(cast(string) line);
	}

	while (dataStart > 0)
	{
		auto size = cast(size_t) min(dataStart, chunkSize);
		dataStart -= size;
		auto bytes = new char[size];
		file.seek(dataStart);
		enforce(file.rawRead(bytes).length == size, "Short read from " ~ path);
		// Each buffer is filled once. The callback may retain its slices.
		auto data = cast(string) bytes;
		auto end = data.length;
		foreach_reverse (i; 0 .. data.length)
		{
			if (data[i] != '\n')
				continue;
			if (foundNewline && !visitLine(data[i + 1 .. end]))
				return;
			foundNewline = true;
			end = i;
		}
		if (foundNewline && end != 0)
		{
			// Collect slices newest first and assemble the line once at its start.
			pieces ~= data[0 .. end];
			pendingLength += end;
		}
	}
	if (foundNewline)
		visitLine(null);
}

unittest
{
	import std.exception : assertThrown;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto path = buildPath(tempDir(), "cydo-reverse-lines-" ~ randomUUID().toString());
	assertThrown(foreachLineReverse(path, line => true));

	scope (exit) remove(path);
	foreach (chunkSize; [1, 2, 3, 64])
	{
		foreach (tail; ["", "unfinished"])
		{
			write(path, "a\nbb\n\nccc\n" ~ tail);
			string[] lines;
			foreachLineReverse(path, line => (lines ~= line).length > 0, chunkSize);
			assert(lines == ["ccc", "bb", "a"]);

			lines = null;
			foreachLineReverse(path, delegate bool(string line) { lines ~= line; return false; }, chunkSize);
			assert(lines == ["ccc"]);
		}

		enum longLine = "0123456789abcdefghijklmnopqrstuvwxyz"
			~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"
			~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz";
		write(path, longLine ~ "\nshort\n" ~ longLine ~ "\nunfinished");
		string[] lines;
		foreachLineReverse(path, line => (lines ~= line).length > 0, chunkSize);
		assert(lines == [longLine, "short", longLine]);

		foreach (contents; ["", "unfinished"])
		{
			write(path, contents);
			foreachLineReverse(path, delegate bool(string line) {
				assert(false, "Unexpected line: " ~ line);
			}, chunkSize);
		}
	}
}
