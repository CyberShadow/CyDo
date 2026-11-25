module cydo.agent.drivers.codex.user_message;

/// The native ContentItem variants used in a persisted Codex response item.
package struct CodexContentItem
{
	enum Type { inputText, inputImage, inputAudio, outputText }
	Type type;
	string text;
	string mediaUrl;
}

package enum CodexUserItemKind
{
	unrecognized,
	message,
	context,
	turnAborted,
}

package enum CodexUserMessageLineClassification
{
	normal,
	contextOnly,
	turnAborted,
}

package struct CodexUserItem
{
	CodexUserItemKind kind;
	CodexContentItem[] inputs;

	/// Legacy per-block classification used for rollback.
	CodexUserMessageLineClassification classification;

	bool isTurnBoundary() const { return kind == CodexUserItemKind.message; }

	string message() const
	{
		import std.array : appender;

		auto text = appender!string();
		foreach (ref input; inputs)
			if (input.type == CodexContentItem.Type.inputText)
				text.put(input.text);
		return text.data;
	}

	/// Match rust-v0.171.0 protocol/src/protocol.rs::user_message_preview.
	string preview() const
	{
		import std.algorithm : any;
		import std.string : indexOf, strip;

		enum prefix = "## My request for Codex:";
		auto text = message();
		auto index = text.indexOf(prefix);
		if (index >= 0)
			text = text[index + prefix.length .. $];
		text = text.strip;
		if (text.length > 0)
			return text;
		if (inputs.any!(input => input.type == CodexContentItem.Type.inputImage))
			return "[Image]";
		return inputs.any!(input => input.type == CodexContentItem.Type.inputAudio) ? "[Audio]" : null;
	}
}

/// Project native user content using rust-v0.171.0
/// core/src/event_mapping.rs::parse_user_message.
package CodexUserItem parseCodexUserItem(const(CodexContentItem)[] content)
{
	alias Type = CodexContentItem.Type;
	alias Kind = CodexUserItemKind;
	alias Classification = CodexUserMessageLineClassification;

	CodexUserItem result;
	result.kind = Kind.message;
	foreach (ref block; content)
	{
		if (block.type != Type.inputText)
			continue;
		if (isCodexTurnAbortedUserText(block.text))
		{
			result.kind = Kind.turnAborted;
			break;
		}
		if (isCodexContextualFragment(block.text))
			result.kind = Kind.context;
	}

	if (!result.isTurnBoundary)
		result.classification = result.kind == Kind.turnAborted
			? Classification.turnAborted : Classification.contextOnly;

	foreach (i, ref block; content)
	{
		if (block.type == Type.inputText)
		{
			if (!result.isTurnBoundary || !isCodexMediaWrapper(block.text,
				i > 0 ? content[i - 1].type : Type.inputText,
				i + 1 < content.length ? content[i + 1].type : Type.inputText))
				result.inputs ~= block;
		}
		else if (result.isTurnBoundary && (block.type == Type.inputImage || block.type == Type.inputAudio))
			result.inputs ~= block;
	}
	return result;
}

/// Legacy Codex permissions preamble, emitted as native context.
package bool isCodexPermissionsInstructionsText(string text)
{
	import std.string : startsWith, stripLeft;

	return text.stripLeft.startsWith("<permissions instructions>");
}

package bool isCodexContextualFragment(string text)
{
	import std.algorithm : endsWith;
	import std.ascii : toLower;
	import std.regex : ctRegex, matchFirst;
	import std.string : indexOf, startsWith, strip;

	auto trimmed = text.strip;
	// Codex rust-v0.171.0: core/src/context/contextual_user_message.rs and
	// context-fragments/src/fragment.rs (ASCII-insensitive paired markers).
	enum markers = [
		["# AGENTS.md instructions", "</INSTRUCTIONS>"],
		["<environment_context>", "</environment_context>"],
		["<recommended_plugins>", "</recommended_plugins>"],
		["<skill>", "</skill>"],
		["<user_shell_command>", "</user_shell_command>"],
		["<subagent_notification>", "</subagent_notification>"],
		["<agent_message_board_notification>", "</agent_message_board_notification>"],
	];
	alias sameAscii = (a, b) => toLower(a) == toLower(b);
	foreach (pair; markers)
		if (trimmed.startsWith!sameAscii(pair[0]) && trimmed.endsWith!sameAscii(pair[1]))
			return true;

	if (trimmed.startsWith("<external_"))
	{
		auto endOfTag = trimmed.indexOf('>');
		return endOfTag >= 0 && trimmed[endOfTag + 1 .. $].endsWith("</" ~ trimmed[1 .. endOfTag + 1]);
	}

	return (trimmed.startsWith("<goal_context>") && trimmed.endsWith("</goal_context>"))
		|| (!trimmed.matchFirst(ctRegex!`^<codex_internal_context source="[a-z][a-z0-9_]*">`).empty
			&& trimmed.endsWith("</codex_internal_context>"))
		|| (trimmed.startsWith("Warning: apply_patch was requested via ")
			&& trimmed.endsWith("Use the apply_patch tool instead of exec_command."))
		|| trimmed.startsWith("Warning: The maximum number of unified exec processes you can keep open is")
		|| trimmed.startsWith("Warning: Your account was flagged for potentially high-risk cyber activity")
		|| isCodexHookPrompt(trimmed)
		|| isCodexTurnAbortedUserText(trimmed);
}

/// Match the text-only hook element written by Codex rust-v0.171.0
/// protocol/src/items.rs. The protocol requires a nonblank hook run ID.
private bool isCodexHookPrompt(string text)
{
	import std.regex : ctRegex, matchFirst;
	import std.string : strip;

	import ae.utils.xml.entities : decodeEntities;

	enum entity = `&(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);`;
	enum opening = `^<hook_prompt\s+hook_run_id\s*=\s*(?:"((?:[^"<&]|` ~ entity
		~ `)*)"|'((?:[^'<&]|` ~ entity ~ `)*)')\s*`;
	enum body = `(?:/>|>(?:[^<&]|` ~ entity ~ `)*</hook_prompt\s*>)$`;
	auto match = text.matchFirst(ctRegex!(opening ~ body));
	if (match.empty)
		return false;
	try
		return decodeEntities(match[1] ~ match[2]).strip.length > 0;
	catch (Exception)
		return false;
}

package bool isCodexTurnAbortedUserText(string text)
{
	import std.ascii : toLower;
	import std.string : stripLeft, stripRight;

	enum openingMarker = "<turn_aborted>";
	enum closingMarker = "</turn_aborted>";

	auto leftTrimmed = text.stripLeft;
	if (leftTrimmed.length < openingMarker.length)
		return false;
	foreach (i, c; openingMarker)
		if (leftTrimmed[i].toLower != c)
			return false;

	auto trimmed = leftTrimmed.stripRight;
	if (trimmed.length < closingMarker.length)
		return false;
	foreach (i, c; closingMarker)
		if (trimmed[trimmed.length - closingMarker.length + i].toLower != c)
			return false;
	return true;
}

/// Match wrapper blocks adjacent to media as in Codex rust-v0.171.0
/// core/src/event_mapping.rs::parse_user_message.
private bool isCodexMediaWrapper(string text, CodexContentItem.Type previous, CodexContentItem.Type next)
{
	import std.algorithm : endsWith, startsWith;

	alias Type = CodexContentItem.Type;
	return (previous == Type.inputImage && text == "</image>")
		|| (previous == Type.inputAudio && text == "</audio>")
		|| (next == Type.inputImage && (text == "<image>"
			|| (text.startsWith("<image name=") && text.endsWith(">"))))
		|| (next == Type.inputAudio && (text == "<audio>"
			|| (text.startsWith("<audio name=") && text.endsWith(">"))));
}

unittest
{
	alias Type = CodexContentItem.Type;
	auto ordinary = CodexContentItem(Type.inputText, "Ordinary text");
	foreach (fragment; [
		"# AGENTS.md instructions\n\n<INSTRUCTIONS>\nUse Nix.\n</INSTRUCTIONS>",
		"# AGENTS.md instructions for /workspace\n\n<INSTRUCTIONS>\nUse Nix.\n</INSTRUCTIONS>",
		"<recommended_plugins>\n- Example\n</recommended_plugins>",
		"<skill>\nFollow the project conventions.\n</skill>",
		"<user_shell_command>\n<command>pwd</command>\n</user_shell_command>",
		"<subagent_notification>\nThe task is complete.\n</subagent_notification>",
		"<AGENT_MESSAGE_BOARD_NOTIFICATION>\nReview is complete.\n</AGENT_MESSAGE_BOARD_NOTIFICATION>",
		"<external_workspace>Workspace changed.</external_workspace>",
		"<ENVIRONMENT_CONTEXT>Workspace changed.</ENVIRONMENT_CONTEXT>",
		"<goal_context>Continue working.</goal_context>",
		`<hook_prompt hook_run_id="hook-run-1">Retry &amp; summarize.</hook_prompt>`,
		"Warning: apply_patch was requested via exec_command. Use the apply_patch tool instead of exec_command.",
		"Warning: The maximum number of unified exec processes you can keep open is 64.",
		"Warning: Your account was flagged for potentially high-risk cyber activity.",
		`<codex_internal_context source="model_switch">The model changed.</codex_internal_context>`,
	])
	{
		auto block = CodexContentItem(Type.inputText, fragment);
		assert(parseCodexUserItem([block]).kind == CodexUserItemKind.context, fragment);
		assert(parseCodexUserItem([ordinary, block]).kind == CodexUserItemKind.context, fragment);
	}

	foreach (prompt; [
		"Add a regression test.",
		"# AGENTS.md instructions\n\nPlease help me write them.",
		"<skill>unfinished example",
		"<external_workspace>Example</external_other>",
		"<environment_context>unfinished example",
		`<hook_prompt hook_run_id=" ">Missing run ID.</hook_prompt>`,
		`<hook_prompt hook_run_id="&#32;">Missing run ID.</hook_prompt>`,
		`<hook_prompt hook_run_id="&#999999999999;">Invalid run ID.</hook_prompt>`,
		`<hook_prompt hook_run_id="hook-run-1">Missing closing tag.`,
		"<subagent_notification>Example</subagent_notification> What does this mean?",
		"<agent_message_board_notification>unfinished example",
	])
		assert(parseCodexUserItem([CodexContentItem(Type.inputText, prompt)]).isTurnBoundary, prompt);

	auto agents = CodexContentItem(Type.inputText, "# AGENTS.md instructions\n<INSTRUCTIONS>Use Nix.</INSTRUCTIONS>");
	auto environment = CodexContentItem(Type.inputText, "<environment_context>cwd</environment_context>");
	assert(parseCodexUserItem([agents, environment]).kind == CodexUserItemKind.context);
	auto aborted = CodexContentItem(Type.inputText, "<turn_aborted>Interrupted.</turn_aborted>");
	assert(parseCodexUserItem([agents, aborted, environment]).kind == CodexUserItemKind.turnAborted);

	auto framed = CodexContentItem(Type.inputText, "[SYSTEM: Task prompt: x]\n\nbody\n\n[/SYSTEM]");
	auto system = parseCodexUserItem([framed]);
	assert(system.isTurnBoundary && system.classification == CodexUserMessageLineClassification.normal);
	auto mixed = parseCodexUserItem([ordinary, framed]);
	assert(mixed.isTurnBoundary && mixed.classification == CodexUserMessageLineClassification.normal);

	auto wrappedImage = [
		CodexContentItem(Type.inputText, `<image name=[Image #1] path="/w/d.png">`),
		CodexContentItem(Type.inputImage, null, "data:image/png;base64,AA=="),
		CodexContentItem(Type.inputText, "</image>"),
	];
	auto image = parseCodexUserItem(wrappedImage);
	assert(image.isTurnBoundary && image.inputs.length == 1 && image.inputs[0].type == Type.inputImage);
	assert(image.message() == "" && image.preview() == "[Image]");
	auto text = CodexContentItem(Type.inputText, "Explain this diagram.");
	auto imageAndText = parseCodexUserItem(wrappedImage ~ text);
	assert(imageAndText.inputs.length == 2 && imageAndText.inputs[0].type == Type.inputImage);
	assert(imageAndText.message() == text.text && imageAndText.preview() == text.text);
	auto literal = CodexContentItem(Type.inputText, "<image>");
	assert(parseCodexUserItem([literal]).message() == literal.text);

	auto output = CodexContentItem(Type.outputText, "<goal_context>Continue.</goal_context>");
	auto outputOnly = parseCodexUserItem([output]);
	assert(outputOnly.isTurnBoundary && outputOnly.inputs.length == 0 && outputOnly.preview() is null);
	auto prefixed = CodexContentItem(Type.inputText, "## My request for Codex: do X");
	assert(parseCodexUserItem([prefixed]).preview() == "do X");
}

unittest
{
	alias Type = CodexContentItem.Type;
	auto wrappedAudio = [
		CodexContentItem(Type.inputText, `<audio name=[Audio #1] path="/w/clip.wav">`),
		CodexContentItem(Type.inputAudio, null, "data:audio/wav;base64,UklGRg=="),
		CodexContentItem(Type.inputText, "</audio>"),
	];
	auto audio = parseCodexUserItem(wrappedAudio);
	assert(audio.isTurnBoundary && audio.message() == "" && audio.preview() == "[Audio]");
	auto fileImage = CodexContentItem(Type.inputImage);
	assert(parseCodexUserItem(wrappedAudio ~ fileImage).preview() == "[Image]");
}
