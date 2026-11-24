module cydo.foundation.text.ecmascript;

/// Trim the WhiteSpace and LineTerminator code points used by JavaScript's
/// String.prototype.trim. This includes BOM and excludes NEL.
string trimEcmaScript(string text)
{
	import std.utf : decode, strideBack;

	size_t start;
	size_t end = text.length;
	while (start < end)
	{
		auto next = start;
		if (!isEcmaScriptWhitespace(decode(text, next)))
			break;
		start = next;
	}
	while (start < end)
	{
		auto previous = end - strideBack(text, end);
		auto index = previous;
		if (!isEcmaScriptWhitespace(decode(text, index)))
			break;
		end = previous;
	}
	return text[start .. end];
}

private bool isEcmaScriptWhitespace(dchar codePoint)
{
	switch (codePoint)
	{
		case '\t': .. case '\r':
		case ' ':
		case '\u00A0':
		case '\u1680':
		case '\u2000': .. case '\u200A':
		case '\u2028':
		case '\u2029':
		case '\u202F':
		case '\u205F':
		case '\u3000':
		case '\uFEFF':
			return true;
		default:
			return false;
	}
}

unittest
{
	enum whitespace = "\t\n\v\f\r \u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
		~ "\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF";
	assert(trimEcmaScript("").length == 0);
	assert(trimEcmaScript(whitespace).length == 0);
	assert(trimEcmaScript(whitespace ~ "a\u00A0b" ~ whitespace) == "a\u00A0b");
	foreach (text; ["\u0085", "\u180E", "\u200B"])
		assert(trimEcmaScript(whitespace ~ text ~ whitespace) == text);
}

unittest
{
	import std.array : replicate;

	auto interior = "α" ~ " ".replicate(64_000) ~ "😀";
	assert(trimEcmaScript("\uFEFF" ~ interior ~ "\u3000") == interior);
}
