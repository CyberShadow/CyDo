/// System message framing, template compilation, and round-trip matching.
///
/// Provides the `[SYSTEM: ...]` wrapper format and the regex-based
/// reverse-matcher that recovers template vars from a rendered body.
///
/// IMPORTANT — D `std.regex` backreference quirk:
///   `\k<x>`, `\g<x>`, and `(?P=name)` either throw at compile time or
///   silently match literal characters — they do NOT perform backreferences.
///   Only numeric backreferences (`\1`, `\2`, …) work correctly.
module cydo.system_message;

import std.array : array;
import std.algorithm : canFind, endsWith, startsWith;
import std.conv : to;
import std.regex : Regex, matchFirst, regex;
import std.string : indexOf, strip;

// ---------------------------------------------------------------------------
// Wrapper format
// ---------------------------------------------------------------------------

/// Wrap a body in `[<keyword>: <subject>]...[/<keyword>]` framing.
/// When body is null or empty, emits the single-line form with no body.
string wrapSystemMessage(string keyword, string subject, string body = null)
{
    if (body.length == 0)
        return "[" ~ keyword ~ ": " ~ subject ~ "]";
    return "[" ~ keyword ~ ": " ~ subject ~ "]\n\n" ~ body ~ "\n\n[/" ~ keyword ~ "]";
}

struct ParsedSystemFraming
{
    string subject;
    string body;
}

/// Parse `[keyword: subject]\n\nbody\n\n[/keyword]` into subject + body.
/// Returns false when text doesn't match the framing (not a system message,
/// or missing closing tag, or empty body).
bool tryParseSystemFraming(string keyword, string text, out ParsedSystemFraming result)
{
    auto openPrefix = "[" ~ keyword ~ ": ";
    if (!text.startsWith(openPrefix))
        return false;
    auto afterOpen = text[openPrefix.length .. $];
    auto closeTag = "]";
    auto closeIdx = afterOpen.indexOf(closeTag);
    if (closeIdx <= 0)
        return false;
    auto subject = afterOpen[0 .. cast(size_t) closeIdx];
    auto afterSubjectClose = afterOpen[cast(size_t) closeIdx + closeTag.length .. $];

    auto bodyPrefix = "\n\n";
    auto closingTag = "\n\n[/" ~ keyword ~ "]";
    if (!afterSubjectClose.startsWith(bodyPrefix))
        return false;
    auto bodyText = afterSubjectClose[bodyPrefix.length .. $];
    if (!bodyText.endsWith(closingTag))
        return false;
    auto body = bodyText[0 .. $ - closingTag.length];
    if (body.length == 0)
        return false;
    result = ParsedSystemFraming(subject, body);
    return true;
}

/// Extract only the subject from the first line of a wrapped system message.
bool tryExtractSubject(string keyword, string text, out string subject)
{
    auto prefix = "[" ~ keyword ~ ": ";
    if (!text.startsWith(prefix))
        return false;
    auto remaining = text[prefix.length .. $];
    auto closeIdx = remaining.indexOf("]");
    if (closeIdx <= 0)
        return false;
    subject = remaining[0 .. cast(size_t) closeIdx];
    return true;
}

/// Strip the framing added by prependTaskFraming(), returning only the
/// rendered prompt body.  Handles three cases in order:
///   1. [TASK DESCRIPTION]...[TASK PROMPT]\n prefix (system prompt present)
///   2. [CYDO PROJECT MEMORY]...[/CYDO PROJECT MEMORY] prefix (memory only,
///      no system prompt — the new path enabled by v2 injection)
///   3. No framing — body returned unchanged.
string stripTaskSystemPromptWrapper(string body)
{
    // Case 1: system prompt framing → strip up to and including [TASK PROMPT]\n
    enum taskPromptMarker = "\n[TASK PROMPT]\n";
    auto idx = body.indexOf(taskPromptMarker);
    if (idx >= 0)
        return body[cast(size_t) idx + taskPromptMarker.length .. $];

    // Case 2: memory-only framing (no system prompt) → strip the memory block
    enum memoryOpenTag = "[CYDO PROJECT MEMORY]";
    enum memoryCloseTag = "[/CYDO PROJECT MEMORY]";
    if (body.startsWith(memoryOpenTag))
    {
        auto closeIdx = body.indexOf(memoryCloseTag);
        if (closeIdx >= 0)
        {
            auto pos = cast(size_t) closeIdx + memoryCloseTag.length;
            // Skip the newline separator inserted by prependTaskFraming
            while (pos < body.length && (body[pos] == '\n' || body[pos] == '\r'))
                pos++;
            return body[pos .. $];
        }
    }

    return body;
}

// ---------------------------------------------------------------------------
// Template compilation and matching
// ---------------------------------------------------------------------------

struct CompiledTemplate
{
    Regex!char re;
    string[] varNames; // ordered list of distinct placeholder names (first occurrence order)
}

/// Compile a template string into a regex that can reverse-match rendered bodies.
///
/// Template syntax: `{{varName}}` placeholders; everything else is literal.
/// First occurrence of each var becomes a named capture `(?P<var>.*?)`.
/// Subsequent occurrences become numeric backreferences `\N`.
/// The pattern is anchored (`^...$`) and compiled with the `s` (dotall) flag.
CompiledTemplate compileTemplate(string templateText)
{
    import std.regex : escaper;

    string pattern = "^";
    string[] varNames;
    int[string] groupIndex; // var → 1-based group number in pattern
    int nextGroup = 1;

    auto remaining = templateText;
    while (remaining.length > 0)
    {
        auto openIdx = remaining.indexOf("{{");
        if (openIdx < 0)
        {
            // No more placeholders — append rest as literal
            pattern ~= escaper(remaining).to!string;
            break;
        }
        // Append literal segment before the placeholder
        if (openIdx > 0)
            pattern ~= escaper(remaining[0 .. cast(size_t) openIdx]).to!string;
        remaining = remaining[cast(size_t) openIdx + 2 .. $];
        auto closeIdx = remaining.indexOf("}}");
        if (closeIdx < 0)
        {
            // Malformed — treat remainder as literal
            pattern ~= escaper("{{" ~ remaining).to!string;
            break;
        }
        auto varName = remaining[0 .. cast(size_t) closeIdx];
        remaining = remaining[cast(size_t) closeIdx + 2 .. $];

        if (auto idxP = varName in groupIndex)
        {
            // Repeated placeholder — numeric backref
            pattern ~= "\\" ~ to!string(*idxP);
        }
        else
        {
            groupIndex[varName] = nextGroup++;
            varNames ~= varName;
            pattern ~= "(?P<" ~ varName ~ ">.*?)";
        }
    }
    pattern ~= "$";
    return CompiledTemplate(regex(pattern, "s"), varNames);
}

/// Match a rendered body against a compiled template.
/// Populates vars with captured values. Returns false if no match.
bool tryMatchTemplate(ref CompiledTemplate compiled, string body, out string[string] vars)
{
    auto m = matchFirst(body, compiled.re);
    if (!m)
        return false;
    foreach (name; compiled.varNames)
        vars[name] = m[name];
    return true;
}

/// Validate a template source for the adjacent-placeholder ambiguity.
/// Returns a non-null error string if two placeholders appear with no
/// literal text between them (non-greedy capture is ambiguous in that case).
/// Returns null if the template is valid.
string validateTemplateSource(string templateText)
{
    auto remaining = templateText;
    bool lastWasPlaceholder = false;
    while (remaining.length > 0)
    {
        auto openIdx = remaining.indexOf("{{");
        if (openIdx < 0)
            break;
        bool hasLiteralBefore = openIdx > 0;
        if (lastWasPlaceholder && !hasLiteralBefore)
            return "template has adjacent placeholders with no literal text between them — "
                ~ "non-greedy capture is ambiguous";
        remaining = remaining[cast(size_t) openIdx + 2 .. $];
        auto closeIdx = remaining.indexOf("}}");
        if (closeIdx < 0)
            break;
        remaining = remaining[cast(size_t) closeIdx + 2 .. $];
        lastWasPlaceholder = true;
        // Check if next char is immediately another placeholder
        if (remaining.startsWith("{{"))
        {
            return "template has adjacent placeholders with no literal text between them — "
                ~ "non-greedy capture is ambiguous";
        }
        lastWasPlaceholder = false; // reset — we only error when immediately adjacent
    }
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

unittest
{
    // --- 1a. wrapSystemMessage / tryParseSystemFraming round-trip ---

    // Single-line form (no body)
    auto noBody = wrapSystemMessage("SYSTEM", "Session start: blank");
    assert(noBody == "[SYSTEM: Session start: blank]", noBody);
    ParsedSystemFraming framing;
    assert(!tryParseSystemFraming("SYSTEM", noBody, framing));

    // Full form
    auto wrapped = wrapSystemMessage("SYSTEM", "Task prompt: conversation -> plan", "hello world");
    assert(wrapped == "[SYSTEM: Task prompt: conversation -> plan]\n\nhello world\n\n[/SYSTEM]", wrapped);
    assert(tryParseSystemFraming("SYSTEM", wrapped, framing));
    assert(framing.subject == "Task prompt: conversation -> plan", framing.subject);
    assert(framing.body == "hello world", framing.body);

    // Different keyword
    auto customKw = wrapSystemMessage("AGENT", "Handoff: src -> dst", "body text");
    ParsedSystemFraming f2;
    assert(tryParseSystemFraming("AGENT", customKw, f2));
    assert(f2.subject == "Handoff: src -> dst");
    assert(f2.body == "body text");

    // Multiline body
    auto multiBody = "line one\nline two\nline three";
    auto wrappedMulti = wrapSystemMessage("SYSTEM", "Sub", multiBody);
    ParsedSystemFraming f3;
    assert(tryParseSystemFraming("SYSTEM", wrappedMulti, f3));
    assert(f3.body == multiBody, f3.body);

    // tryExtractSubject
    string subj;
    assert(tryExtractSubject("SYSTEM", wrapped, subj));
    assert(subj == "Task prompt: conversation -> plan", subj);
    assert(!tryExtractSubject("SYSTEM", "not a system message", subj));
}

unittest
{
    // --- 1b. compileTemplate / tryMatchTemplate ---

    // Single placeholder
    auto ct = compileTemplate("{{task_description}}\n");
    string[string] vars;
    assert(tryMatchTemplate(ct, "hello world\n", vars));
    assert(vars["task_description"] == "hello world", vars["task_description"]);

    // Repeated placeholder (backref)
    auto ct2 = compileTemplate("START {{x}} MID {{x}} END");
    string[string] v2;
    assert(tryMatchTemplate(ct2, "START foo MID foo END", v2));
    assert(v2["x"] == "foo");
    assert(!tryMatchTemplate(ct2, "START foo MID bar END", v2));

    // Multiple distinct placeholders
    auto ct3 = compileTemplate("Name: {{name}}\nAge: {{age}}\n");
    string[string] v3;
    assert(tryMatchTemplate(ct3, "Name: Alice\nAge: 30\n", v3));
    assert(v3["name"] == "Alice");
    assert(v3["age"] == "30");

    // Multiline body captured across newlines
    auto ct4 = compileTemplate("{{body}}\nEnd");
    string[string] v4;
    assert(tryMatchTemplate(ct4, "line1\nline2\nEnd", v4));
    assert(v4["body"] == "line1\nline2", v4["body"]);

    // No match
    auto ct5 = compileTemplate("PREFIX {{x}} SUFFIX");
    string[string] v5;
    assert(!tryMatchTemplate(ct5, "wrong prefix", v5));
}

unittest
{
    // --- 1c. validateTemplateSource ---
    assert(validateTemplateSource("{{a}}{{b}}") !is null);
    assert(validateTemplateSource("{{a}} {{b}}") is null);
    assert(validateTemplateSource("{{a}}\n{{b}}") is null);
    assert(validateTemplateSource("no placeholders") is null);
    assert(validateTemplateSource("{{only_one}}") is null);
}

unittest
{
    // --- 1d. stripTaskSystemPromptWrapper ---
    // Case 1: system prompt framing
    auto withWrapper = "[TASK DESCRIPTION]\nsys prompt\n\n[END TASK DESCRIPTION]\n\n[TASK PROMPT]\nactual body";
    assert(stripTaskSystemPromptWrapper(withWrapper) == "actual body");

    // Case 1b: memory + system prompt (memory before [TASK DESCRIPTION], stripped at [TASK PROMPT])
    auto withBoth = "[CYDO PROJECT MEMORY]\nmem\n[/CYDO PROJECT MEMORY]\n\n[TASK DESCRIPTION]\nsys\n\n[END TASK DESCRIPTION]\n\n[TASK PROMPT]\nactual body";
    assert(stripTaskSystemPromptWrapper(withBoth) == "actual body");

    // Case 2: memory only (no system prompt, no [TASK PROMPT] marker)
    auto withMemoryOnly = "[CYDO PROJECT MEMORY]\nsome memory\n[/CYDO PROJECT MEMORY]\n\nactual body";
    assert(stripTaskSystemPromptWrapper(withMemoryOnly) == "actual body");

    // Case 2b: memory only with extra newlines after closing tag
    auto withMemoryOnlyExtra = "[CYDO PROJECT MEMORY]\nmem\n[/CYDO PROJECT MEMORY]\n\n\nactual body";
    assert(stripTaskSystemPromptWrapper(withMemoryOnlyExtra) == "actual body");

    // Case 3: no framing — returned as-is
    assert(stripTaskSystemPromptWrapper("plain body") == "plain body");
}

unittest
{
    // --- 2. Real templates: render → wrap → parse → match ---
    import std.file : dirEntries, exists, readText, SpanMode, thisExePath;
    import std.path : buildPath, dirName;
    import std.string : endsWith;

    // Locate defs/prompts/ relative to the executable or source root.
    // dub test runs from the project root, so use a relative path first.
    string defsDir = "defs/prompts";
    if (!exists(defsDir))
    {
        // Fallback: walk up from executable location
        auto exeDir = dirName(thisExePath);
        defsDir = buildPath(exeDir, "../defs/prompts");
        if (!exists(defsDir))
            return; // skip if not found (e.g. CI sandbox without sources)
    }

    // Fixture values to test with
    string[] fixtureValues = [
        "",
        "simple ASCII text",
        "contains separator: " ~ "---" ~ replicate('-', 77),
        "contains [/SYSTEM] closing tag",
        "has\nnewlines\nhere",
        "has {{x}} literal syntax",
    ];

    foreach (entry; dirEntries(defsDir, "*.md", SpanMode.shallow))
    {
        auto templateText = readText(entry.name);
        // Skip templates with adjacent placeholders (they'd fail validateTemplateSource)
        if (validateTemplateSource(templateText) !is null)
            continue;

        auto compiled = compileTemplate(templateText);

        foreach (fixture; fixtureValues)
        {
            // Build a vars map with every placeholder set to the fixture value
            string[string] renderVars;
            foreach (varName; compiled.varNames)
                renderVars[varName] = fixture;

            // Render by substituting placeholders
            string rendered = templateText;
            foreach (varName; compiled.varNames)
            {
                import std.array : replace;
                rendered = rendered.replace("{{" ~ varName ~ "}}", fixture);
            }

            // Wrap and parse framing
            auto wrapped = wrapSystemMessage("SYSTEM", "Test: template", rendered);
            ParsedSystemFraming framing;
            assert(tryParseSystemFraming("SYSTEM", wrapped, framing),
                "framing parse failed for " ~ entry.name);

            // Strip task system prompt wrapper if needed (for templates that get prepended)
            auto inner = stripTaskSystemPromptWrapper(framing.body);

            // Reverse-match
            string[string] recoveredVars;
            bool matched = tryMatchTemplate(compiled, inner, recoveredVars);
            if (compiled.varNames.length > 0)
            {
                assert(matched, "template match failed for " ~ entry.name
                    ~ " with fixture: " ~ fixture);
                foreach (varName; compiled.varNames)
                    assert(recoveredVars[varName] == fixture,
                        "var mismatch for " ~ varName ~ " in " ~ entry.name);
            }
        }
    }
}

unittest
{
    // --- 5. Synthetic templates round-trip ---
    struct SyntheticCase
    {
        string template_;
        string[string] vars;
        string bodyVar;
    }

    auto cases = [
        SyntheticCase(
            "{{message}}\n\nAnswer with mcp__cydo__Answer({{qid}}, \"your response\").",
            ["message": "What is X?", "qid": "42"],
            "message"
        ),
        SyntheticCase(
            "{{message}}\n\nAnswer with mcp__cydo__Answer({{qid}}, \"your response\").",
            ["message": "Multi\nline\nquestion", "qid": "7"],
            "message"
        ),
        SyntheticCase(
            "{{message}}\n\nAnswer with mcp__cydo__Answer({{qid}}, \"your response\").",
            ["message": "Short?", "qid": "1"],
            "message"
        ),
        SyntheticCase(
            "Question: {{question}}\n\nUse mcp__cydo__Answer({{qid}}, \"your answer\") to respond. You must answer before you can complete your turn.",
            ["question": "What is the answer?", "qid": "10"],
            "question"
        ),
        SyntheticCase(
            "Question: {{question}}\n\nUse mcp__cydo__Answer({{qid}}, \"your answer\") to respond. You must answer before you can complete your turn.",
            ["question": "Multi\nline?", "qid": "99"],
            "question"
        ),
        SyntheticCase(
            "Question: {{question}}\n\nUse mcp__cydo__Answer({{qid}}, \"your answer\") to respond. You must answer before you can complete your turn.",
            ["question": "Brief.", "qid": "3"],
            "question"
        ),
    ];

    foreach (ref c; cases)
    {
        import std.array : replace;
        // Render template
        string rendered = c.template_;
        foreach (k, v; c.vars)
            rendered = rendered.replace("{{" ~ k ~ "}}", v);

        // Wrap and parse
        auto wrapped = wrapSystemMessage("SYSTEM", "Test", rendered);
        ParsedSystemFraming framing;
        assert(tryParseSystemFraming("SYSTEM", wrapped, framing));

        // Match
        auto compiled = compileTemplate(c.template_);
        string[string] recovered;
        assert(tryMatchTemplate(compiled, framing.body, recovered),
            "synthetic template match failed for template: " ~ c.template_);
        assert(recovered[c.bodyVar] == c.vars[c.bodyVar],
            "bodyVar mismatch: got '" ~ recovered[c.bodyVar]
            ~ "' expected '" ~ c.vars[c.bodyVar] ~ "'");
    }
}

unittest
{
    // --- 4. Legacy body (no edge identity) degrades gracefully ---
    // A legacy [SYSTEM: Task prompt: triage] message (no ->) parses fine but
    // has no edge to look up — the caller handles that with label-only meta.
    auto legacy = "[SYSTEM: Task prompt: triage]\n\nsome task description\n\n[/SYSTEM]";
    ParsedSystemFraming framing;
    assert(tryParseSystemFraming("SYSTEM", legacy, framing));
    assert(framing.subject == "Task prompt: triage");
    assert(framing.body == "some task description");
    // No assertion on match — the caller (app.d) handles edgeName == "" → label-only
}

// Helper for unittest block 2
private string replicate(char ch, int n)
{
    char[] buf = new char[n];
    buf[] = ch;
    return cast(string) buf;
}
