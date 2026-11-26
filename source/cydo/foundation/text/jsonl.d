module cydo.foundation.text.jsonl;

/// Iterate physical JSONL rows without interpreting bytes inside each record.
auto jsonlRows(string content)
{
	import std.algorithm.searching : find;
	import std.string : representation;

	static struct Rows
	{
		private string remaining;
		private size_t lf;

		this(string content)
		{
			remaining = content;
			locateLf();
		}

		private void locateLf()
		{
			lf = remaining.length - remaining.representation.find(cast(ubyte) '\n').length;
		}

		@property bool empty() const { return remaining.length == 0; }

		@property string front() const
		{
			assert(!empty);
			size_t end = lf;
			if (end < remaining.length && end > 0 && remaining[end - 1] == '\r')
				end--;
			return remaining[0 .. end];
		}

		void popFront()
		{
			assert(!empty);
			remaining = remaining[lf + (lf < remaining.length) .. $];
			locateLf();
		}
	}

	return Rows(content);
}

package(cydo) string completeJsonlPrefix(string content)
{
	import std.string : lastIndexOf;
	return content[0 .. content.lastIndexOf('\n') + 1];
}

unittest
{
	import std.array : array;
	import std.json : parseJSON;

	assert(jsonlRows("").empty);
	assert(jsonlRows("\n").array == [""]);
	assert(jsonlRows("a\r\n\n\r\nb\rc\nlast\r").array == ["a", "", "", "b\rc", "last\r"]);
	assert(jsonlRows("a\n").array == ["a"]);

	enum payload = "before\u2028\u2029\u0085after";
	enum row = `{"content":"` ~ payload ~ `"}`;
	assert(jsonlRows(row ~ "\n").array == [row]);
	assert(parseJSON(jsonlRows(row).front)["content"].str == payload);
}
