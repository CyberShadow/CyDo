module cydo.text.title;

/// Truncate text to maxLen chars, collapsing whitespace and appending "…" if needed.
string truncateTitle(string text, size_t maxLen)
{
	import std.regex : ctRegex, replaceAll;

	auto cleaned = text.replaceAll(ctRegex!`\s+`, " ");
	if (cleaned.length <= maxLen)
		return cleaned;
	return cleaned[0 .. maxLen] ~ "…";
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
