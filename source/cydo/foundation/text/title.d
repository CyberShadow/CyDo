module cydo.foundation.text.title;

/// Truncate text to maxLen code points, collapsing whitespace and appending "…" if needed.
string truncateTitle(string text, size_t maxLen)
{
	import std.range : walkLength;
	import std.regex : ctRegex, replaceAll;
	import std.utf : byDchar, toUTFindex;

	auto cleaned = text.replaceAll(ctRegex!`\s+`, " ");
	if (cleaned.byDchar.walkLength <= maxLen)
		return cleaned;
	return cleaned[0 .. cleaned.toUTFindex(maxLen)] ~ "…";
}

unittest
{
	assert(truncateTitle("short title", 20) == "short title");
}

unittest
{
	assert(truncateTitle("This title is too long", 10) == "This title…");
}

unittest
{
	assert(truncateTitle("", 10) == "");
}

unittest
{
	assert(truncateTitle("alpha\t\tbeta\n\ngamma", 100) == "alpha beta gamma");
}

unittest
{
	import std.array : join;
	import std.range : repeat;
	import std.utf : validate;

	auto prefix = "a".repeat(79).join;
	auto title = truncateTitle(prefix ~ "é…", 80);
	validate(title);
	assert(title == prefix ~ "é…");
	assert(truncateTitle("ééé", 2) == "éé…");
}
