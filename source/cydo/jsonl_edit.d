module cydo.jsonl_edit;

/// Replace text content for editable user-facing messages in JSONL.
/// Supports both type:"user" message lines and queue-operation enqueue lines.
string replaceUserMessageContent(string line, string newContent)
{
	import std.json : parseJSON, JSONValue;

	auto json = parseJSON(line);
	if ("message" in json)
		json["message"]["content"] = JSONValue(newContent);
	else if ("type" in json && "operation" in json
		&& json["type"].str == "queue-operation"
		&& json["operation"].str == "enqueue")
		json["content"] = JSONValue(newContent);
	return json.toString();
}

unittest
{
	import std.json : parseJSON;

	auto updated = parseJSON(replaceUserMessageContent(
		`{"type":"user","uuid":"u1","message":{"content":"a"}}`,
		"updated user message"));
	assert(updated["type"].str == "user");
	assert(updated["uuid"].str == "u1");
	assert(updated["message"]["content"].str == "updated user message");
}

unittest
{
	import std.json : parseJSON;

	auto updated = parseJSON(replaceUserMessageContent(
		`{"type":"queue-operation","operation":"enqueue","content":"steer"}`,
		"updated steering"));
	assert(updated["type"].str == "queue-operation");
	assert(updated["operation"].str == "enqueue");
	assert(updated["content"].str == "updated steering");
}
