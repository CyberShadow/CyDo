/// Supplies the lossless, exact-shape evidence required for fail-closed
/// Codex ROLLBACK admission. Do not reuse rollout.d's tolerant DISPLAY
/// projection here: doing so would weaken admission.
module cydo.agent.drivers.codex.ledger;

import std.conv : to;
import std.algorithm : canFind;

import ae.utils.json : JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.serialization.json : JsonParser;
import ae.utils.serialization.serialization : isProtocolArray, isProtocolBoolean,
	isProtocolField, isProtocolMap, isProtocolNull, isProtocolNumeric,
	isProtocolString;

import cydo.agent.drivers.codex.rollout;

/// A lossless-enough JSON shape used by the rollout scan. Unlike the generic
/// serialized-object store, this retains repeated object keys so native undo
/// can refuse malformed provider records instead of silently accepting the
/// last duplicate value.
package enum RolloutValueType
{
	none,
	null_,
	boolean,
	numeric,
	string_,
	array,
	object,
}

/// The two complete token_count payload forms observed in the pinned Codex
/// captures. Keep this separate from the generic telemetry bit because their
/// lifecycle positions are different native-admission predicates.
package enum CodexTokenCountRateLimitsShape
{
	unknown,
	object,
	null_,
}

/// Post-terminal telemetry is tied to the exact materialized terminal shape.
/// The captures distinguish ordinary completions, compaction completions, and
/// v1 interruption terminals; do not collapse those into a bool.
package enum CodexNativeTerminalKind
{
	unknown,
	completedSimple,
	completedCompaction,
	interrupted,
}

package struct RolloutValue
{
	RolloutValueType type;
	bool boolean;
	string text;
	RolloutValue[] values;
	string[] keys;
}

private struct RolloutValueSink
{
	RolloutValue* output;

	void handle(V)(V value)
	{
		static if (isProtocolNull!V)
			output.type = RolloutValueType.null_;
		else static if (isProtocolBoolean!V)
		{
			output.type = RolloutValueType.boolean;
			output.boolean = value.value;
		}
		else static if (isProtocolNumeric!V)
		{
			output.type = RolloutValueType.numeric;
			output.text = value.text.to!string;
		}
		else static if (isProtocolString!V)
		{
			output.type = RolloutValueType.string_;
			output.text = value.text.to!string;
		}
		else static if (isProtocolArray!V)
		{
			output.type = RolloutValueType.array;
			value.reader(RolloutArraySink(&output.values));
		}
		else static if (isProtocolMap!V)
		{
			output.type = RolloutValueType.object;
			value.reader(RolloutMapSink(output));
		}
		else
			static assert(false, "Unsupported rollout JSON value");
	}
}

private struct RolloutArraySink
{
	RolloutValue[]* output;

	void handle(V)(V value)
	{
		RolloutValue item;
		RolloutValueSink(&item).handle(value);
		*output ~= item;
	}
}

private struct RolloutMapSink
{
	RolloutValue* output;

	void handle(V)(V field)
	{
		static if (isProtocolField!V)
		{
			string key;
			field.nameReader(RolloutKeySink(&key));
			RolloutValue value;
			value.type = RolloutValueType.none;
			field.valueReader(RolloutValueSink(&value));
			output.keys ~= key;
			output.values ~= value;
		}
		else
			static assert(false, "Rollout JSON object expected a field");
	}
}

private struct RolloutKeySink
{
	string* output;

	void handle(V)(V value)
	{
		static if (isProtocolString!V)
			*output = value.text.to!string;
		else
			static assert(false, "Rollout JSON object key must be a string");
	}
}

private bool parseRolloutValue(string line, out RolloutValue result)
{
	try
	{
		auto parser = JsonParser!(immutable char)(cast(immutable char[]) line, 0);
		parser.read(RolloutValueSink(&result));
		parser.skipWhitespace();
		return parser.eof;
	}
	catch (Exception)
		return false;
}

private const(RolloutValue)* rolloutField(const ref RolloutValue object,
	string key, out size_t count)
{
	const(RolloutValue)* result;
	if (object.type != RolloutValueType.object)
		return null;
	foreach (i, ref value; object.values)
	{
		if (object.keys[i] != key)
			continue;
		count++;
		if (count == 1)
			result = &value;
	}
	return result;
}

private bool rolloutHasOnlyKeys(const ref RolloutValue object,
	scope const string[] allowed)
{
	if (object.type != RolloutValueType.object)
		return false;
	foreach (key; object.keys)
	{
		if (!allowed.canFind(key))
			return false;
		size_t count;
		rolloutField(object, key, count);
		if (count != 1)
			return false;
	}
	return true;
}

private bool rolloutString(const(RolloutValue)* value, out string text)
{
	if (value is null || value.type != RolloutValueType.string_)
		return false;
	text = value.text;
	return true;
}

private bool rolloutNull(const(RolloutValue)* value)
{
	return value !is null && value.type == RolloutValueType.null_;
}

private bool rolloutNumeric(const(RolloutValue)* value)
{
	return value !is null && value.type == RolloutValueType.numeric;
}

private bool rolloutBoolean(const(RolloutValue)* value)
{
	return value !is null && value.type == RolloutValueType.boolean;
}

private bool rolloutExactBoolean(const(RolloutValue)* value, bool expected)
{
	return rolloutBoolean(value) && value.boolean == expected;
}

private bool rolloutNonemptyString(const(RolloutValue)* value)
{
	string text;
	return rolloutString(value, text) && text.length > 0;
}

private bool rolloutExactString(const(RolloutValue)* value, string expected)
{
	string text;
	return rolloutString(value, text) && text == expected;
}

package struct RolloutLineProbe
{
	bool isSessionMeta;
	bool isTurnContext;
	bool isResponseItem;
	bool isEventMsg;
	bool isTaskStarted;
	bool isThreadRolledBack;
	uint rollbackNumTurns;
	ForkableMessageRole messageRole = ForkableMessageRole.none;

	@property bool isUserMessage() const
	{
		return messageRole == ForkableMessageRole.user;
	}

	@property bool isAssistantMessage() const
	{
		return messageRole == ForkableMessageRole.assistant;
	}

	@property bool isForkableMessage() const
	{
		return isUserMessage || isAssistantMessage;
	}
}

/// All native-undo-relevant facts for one physical rollout line. The scan
/// keeps the raw parsed shape as well as the focused projections used by
/// boundaries, replay, and native admission.
package struct RolloutLineEvidence
{
	int lineNumber;
	string rawLine;
	RolloutValue raw;
	bool parsed;
	RolloutTopLevelKind topLevelKind;
	bool topLevelEnvelopeKnown;
	bool contextualPayloadKnown;
	bool contextualTurnIdValid;
	string contextualTurnId;
	RolloutLineProbe probe;

	bool payloadKnown;
	string payloadType;
	string role;
	bool responseUnknownFields;
	bool metadataPresent;
	bool metadataKnown;
	bool turnIdPresent;
	bool turnIdValid;
	string turnId;

	CodexUserMessageLineClassification userClassification;
	bool userClassificationKnown;
	string inputText;
	string contentText;
	size_t contentCount;
	string[] contentTypes;
	bool contentKnown;
	bool contentTextsNonempty;
	bool contentClassificationKnown;
	bool contentSingleInputText;
	bool contentSingleOutputText;
	string itemId;
	bool itemIdPresent;
	bool itemIdValid;

	bool eventKnown;
	bool eventTurnIdPresent;
	bool eventTurnIdValid;
	string eventTurnId;
	bool eventClientIdPresent;
	bool eventClientIdValid;
	string eventClientId;
	bool eventMessagePresent;
	bool eventMessageValid;
	string eventMessage;
	bool eventLastAgentMessagePresent;
	bool eventLastAgentMessageValid;
	bool eventLastAgentMessageIsNull;
	string eventLastAgentMessage;
	bool eventImagesValid;
	size_t eventImagesCount;
	bool eventLocalImagesValid;
	size_t eventLocalImagesCount;
	bool eventTextElementsValid;
	size_t eventTextElementsCount;
	bool eventPhaseIsNull;
	bool eventMemoryCitationIsNull;
	bool eventReasonValid;
	string eventReason;
	bool eventTelemetryKnown;
	CodexTokenCountRateLimitsShape tokenCountRateLimitsShape;
	bool isCompacted;
	bool compactedKnown;
	string[] compactedReplacementTurnIds;
	int immediateUserEventIndex = -1;

	/// Rollback markers make matching raw segments dead. Persisted-boundary
	/// extraction and replay consume this historical user-segment view.
	bool active = true;

	/// Native rollback counts materialized turns rather than role=user records.
	/// This separately tracks task_started-delimited lifecycle segments, including
	/// compaction-only turns, so contextual user records cannot consume a native
	/// rollback slot.
	bool nativeActive = true;
}

package struct RolloutTurnLifecycleEvidence
{
	size_t starts;
	size_t completes;
	size_t aborts;
	int startIndex = -1;
	int completeIndex = -1;
	int abortIndex = -1;
	bool known = true;
}

package struct RolloutScan
{
	RolloutLineEvidence[] lines;
	NativeRolloutSegment[] nativeSegments;
	/// Historical replay-facing lifecycle view, derived from active user
	/// segments for compatibility with existing boundary behavior.
	RolloutTurnLifecycleEvidence[string] lifecycles;
	/// Native lifecycle view, derived from task_started segments so marker
	/// liveness follows provider materialized-turn counting.
	RolloutTurnLifecycleEvidence[string] nativeLifecycles;
}

private bool decodeContent(ref RolloutLineEvidence evidence,
	const(RolloutValue)* value)
{
	if (value is null || value.type != RolloutValueType.array)
		return false;
	evidence.contentCount = value.values.length;
	bool allKnown = true;
	bool allTextsNonempty = value.values.length > 0;
	bool classificationKnown = true;
	bool oneInput = value.values.length == 1;
	bool oneOutput = value.values.length == 1;
	foreach (ref item; value.values)
	{
		if (item.type != RolloutValueType.object)
		{
			allKnown = false;
			allTextsNonempty = false;
			classificationKnown = false;
			oneInput = false;
			oneOutput = false;
			continue;
		}
		size_t typeCount;
		auto type = rolloutField(item, "type", typeCount);
		string contentType;
		if (typeCount != 1 || !rolloutString(type, contentType))
		{
			allKnown = false;
			allTextsNonempty = false;
			classificationKnown = false;
			oneInput = false;
			oneOutput = false;
			continue;
		}
		evidence.contentTypes ~= contentType;
		size_t textCount;
		auto text = rolloutField(item, "text", textCount);
		string textValue;
		auto textKnown = textCount == 1 && rolloutString(text, textValue);
		if (!textKnown)
		{
			allKnown = false;
			allTextsNonempty = false;
			if (contentType == "input_text" || contentType == "text")
				classificationKnown = false;
		}
		else
		{
			if (textValue.length == 0)
				allTextsNonempty = false;
			if (contentType == "input_text" || contentType == "text")
			{
				evidence.inputText ~= textValue;
				evidence.contentText ~= textValue;
			}
			else if (contentType == "output_text")
				evidence.contentText ~= textValue;
			else
				allKnown = false;
		}
		if (!rolloutHasOnlyKeys(item, ["type", "text"]))
			allKnown = false;
		if (contentType != "input_text")
			oneInput = false;
		if (contentType != "output_text")
			oneOutput = false;
	}
	evidence.contentKnown = allKnown;
	evidence.contentTextsNonempty = allTextsNonempty;
	evidence.contentClassificationKnown = classificationKnown;
	evidence.contentSingleInputText = allKnown && oneInput;
	evidence.contentSingleOutputText = allKnown && oneOutput;
	return allKnown;
}

private bool isExactCapturedPermissionProfile(const(RolloutValue)* profile)
{
	if (profile is null || profile.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*profile, ["type", "network"]))
		return false;
	size_t typeCount, networkCount;
	auto type = rolloutField(*profile, "type", typeCount);
	auto network = rolloutField(*profile, "network", networkCount);
	return typeCount == 1 && rolloutExactString(type, "external")
		&& networkCount == 1 && rolloutExactString(network, "enabled");
}

private bool isExactCapturedSandboxPolicy(const(RolloutValue)* policy)
{
	if (policy is null || policy.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*policy, ["type", "network_access"]))
		return false;
	size_t typeCount, networkCount;
	auto type = rolloutField(*policy, "type", typeCount);
	auto network = rolloutField(*policy, "network_access", networkCount);
	return typeCount == 1 && rolloutExactString(type, "external-sandbox")
		&& networkCount == 1 && rolloutExactString(network, "enabled");
}

private bool isExactCapturedCollaborationMode(const(RolloutValue)* collaboration,
	string model)
{
	if (collaboration is null || collaboration.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*collaboration, ["mode", "settings"]))
		return false;
	size_t modeCount, settingsCount;
	auto mode = rolloutField(*collaboration, "mode", modeCount);
	auto settings = rolloutField(*collaboration, "settings", settingsCount);
	if (modeCount != 1 || !rolloutExactString(mode, "default")
		|| settingsCount != 1 || settings is null || settings.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*settings,
			["model", "reasoning_effort", "developer_instructions"]))
		return false;
	size_t modelCount, reasoningEffortCount, developerInstructionsCount;
	auto settingsModel = rolloutField(*settings, "model", modelCount);
	auto reasoningEffort = rolloutField(*settings, "reasoning_effort", reasoningEffortCount);
	auto developerInstructions = rolloutField(*settings, "developer_instructions",
		developerInstructionsCount);
	return modelCount == 1 && rolloutExactString(settingsModel, model)
		&& reasoningEffortCount == 1 && rolloutNull(reasoningEffort)
		&& developerInstructionsCount == 1 && rolloutNull(developerInstructions);
}

private bool isExactCapturedWorldState(const ref RolloutValue payload)
{
	if (!rolloutHasOnlyKeys(payload, ["full", "state"]))
		return false;
	size_t fullCount, stateCount;
	auto full = rolloutField(payload, "full", fullCount);
	auto state = rolloutField(payload, "state", stateCount);
	if (fullCount != 1 || !rolloutExactBoolean(full, true)
		|| stateCount != 1 || state is null || state.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*state, ["agents_md", "apps_instructions", "environments",
			"plugins_instructions", "skills"]))
		return false;
	size_t agentsMdCount, appsInstructionsCount, environmentsCount;
	size_t pluginsInstructionsCount, skillsCount;
	auto agentsMd = rolloutField(*state, "agents_md", agentsMdCount);
	auto appsInstructions = rolloutField(*state, "apps_instructions", appsInstructionsCount);
	auto environments = rolloutField(*state, "environments", environmentsCount);
	auto pluginsInstructions = rolloutField(*state, "plugins_instructions",
		pluginsInstructionsCount);
	auto skills = rolloutField(*state, "skills", skillsCount);
	if (agentsMdCount != 1 || agentsMd is null || agentsMd.type != RolloutValueType.object
		|| agentsMd.keys.length != 0 || appsInstructionsCount != 1
		|| !rolloutExactBoolean(appsInstructions, false)
		|| environmentsCount != 1 || environments is null
		|| environments.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*environments,
			["environments", "current_date", "timezone", "filesystem"])
		|| pluginsInstructionsCount != 1 || !rolloutExactBoolean(pluginsInstructions, false)
		|| skillsCount != 1 || skills is null || skills.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*skills, ["includeInstructions"]))
		return false;
	size_t localEnvironmentsCount, currentDateCount, timezoneCount, filesystemCount;
	auto localEnvironments = rolloutField(*environments, "environments",
		localEnvironmentsCount);
	auto currentDate = rolloutField(*environments, "current_date", currentDateCount);
	auto timezone = rolloutField(*environments, "timezone", timezoneCount);
	auto filesystem = rolloutField(*environments, "filesystem", filesystemCount);
	if (localEnvironmentsCount != 1 || localEnvironments is null
		|| localEnvironments.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*localEnvironments, ["local"])
		|| currentDateCount != 1 || !rolloutNonemptyString(currentDate)
		|| timezoneCount != 1 || !rolloutNonemptyString(timezone)
		|| filesystemCount != 1 || !rolloutNonemptyString(filesystem))
		return false;
	size_t localCount;
	auto local = rolloutField(*localEnvironments, "local", localCount);
	if (localCount != 1 || local is null || local.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*local, ["cwd", "status", "shell"]))
		return false;
	size_t cwdCount, statusCount, shellCount, includeInstructionsCount;
	auto cwd = rolloutField(*local, "cwd", cwdCount);
	auto status = rolloutField(*local, "status", statusCount);
	auto shell = rolloutField(*local, "shell", shellCount);
	auto includeInstructions = rolloutField(*skills, "includeInstructions",
		includeInstructionsCount);
	return cwdCount == 1 && rolloutNonemptyString(cwd)
		&& statusCount == 1 && rolloutExactString(status, "available")
		&& shellCount == 1 && rolloutExactString(shell, "zsh")
		&& includeInstructionsCount == 1 && rolloutExactBoolean(includeInstructions, true);
}

/// One row of the provider model catalog, as it surfaces in `turn_context`.
private struct CapturedModelShape
{
	string slug;
	string multiAgentVersion;
	string compHash;
	/// null means Codex omits the key entirely for this model.
	string multiAgentMode;
}

// Observed from the model catalog compiled into the pinned Codex CLI 0.144.1
// binary, captured by driving `codex app-server` with CyDo's exact
// thread/start parameters. These are provider catalog data, NOT products of
// CyDo's config: features.multi_agent=false is inert for catalogued models.
// A Codex version bump can change them and must re-capture.
private static immutable CapturedModelShape[] capturedModelShapes = [
	CapturedModelShape("gpt-5.6-luna",  "v1", "3000", null),
	CapturedModelShape("gpt-5.6-terra", "v2", "3000", "explicitRequestOnly"),
	CapturedModelShape("gpt-5.6-sol",   "v2", "3000", "explicitRequestOnly"),
];

unittest
{
	// Anti-drift: capturedModelShapes is a transcription of the model catalog
	// compiled into the pinned Codex binary. Read that catalog back out and
	// require it still says what the table says. A Codex version bump that
	// changes comp_hash or multi_agent_version fails here instead of silently
	// making every native undo refuse at runtime.
	import std.algorithm.searching : countUntil;
	import std.file : exists;
	import std.mmfile : MmFile;
	import std.process : environment;

	string codexBinary()
	{
		auto configured = environment.get("CYDO_TEST_CODEX_BIN", "");
		if (configured.length > 0)
			return configured;
		import std.path : buildPath;
		import std.string : split;
		foreach (dir; environment.get("PATH", "").split(':'))
			if (dir.length > 0 && exists(buildPath(dir, "codex")))
				return buildPath(dir, "codex");
		return null;
	}

	auto binary = codexBinary();
	assert(binary !is null && exists(binary),
		"the pinned Codex binary is required to verify capturedModelShapes;"
		~ " set CYDO_TEST_CODEX_BIN or put codex on PATH");

	scope mapped = new MmFile(binary);
	// Search as bytes: the image is not valid UTF-8, so a char[] range would
	// throw decoding it long before reaching the catalog.
	auto image = cast(const(ubyte)[]) mapped[];
	static immutable ubyte[] catalogMarker = cast(immutable(ubyte)[]) "{\n  \"models\": [\n";
	auto start = image.countUntil(catalogMarker);
	assert(start >= 0,
		"no embedded model catalog in " ~ binary
		~ "; the Codex build no longer embeds it as pretty-printed JSON and"
		~ " capturedModelShapes must be re-captured another way");

	// The catalog is the one balanced object starting at the marker. Track
	// string state so braces inside slugs or prompts cannot end it early.
	size_t depth;
	bool inString, escaped;
	size_t end;
	foreach (i; start .. image.length)
	{
		auto c = image[i];
		if (inString)
		{
			if (escaped)
				escaped = false;
			else if (c == '\\')
				escaped = true;
			else if (c == '"')
				inString = false;
			continue;
		}
		if (c == '"')
			inString = true;
		else if (c == '{')
			depth++;
		else if (c == '}' && --depth == 0)
		{
			end = i + 1;
			break;
		}
	}
	assert(end > cast(size_t) start, "embedded model catalog is not brace-balanced");

	@JSONPartial static struct CatalogModel
	{
		string slug;
		@JSONOptional string comp_hash;
		@JSONOptional string multi_agent_version;
	}
	@JSONPartial static struct Catalog { CatalogModel[] models; }

	auto catalog = jsonParse!Catalog(cast(string) image[start .. end].idup);
	assert(catalog.models.length > 0, "embedded model catalog has no models");

	foreach (ref shape; capturedModelShapes)
	{
		auto index = catalog.models.countUntil!(m => m.slug == shape.slug);
		assert(index >= 0,
			"pinned Codex no longer ships model " ~ shape.slug
			~ "; re-capture capturedModelShapes from the current binary");
		auto model = catalog.models[index];
		assert(model.comp_hash == shape.compHash,
			"pinned Codex catalog reports comp_hash=" ~ model.comp_hash ~ " for "
			~ shape.slug ~ " but capturedModelShapes says " ~ shape.compHash
			~ "; re-capture turn_context from this binary");
		assert(model.multi_agent_version == shape.multiAgentVersion,
			"pinned Codex catalog reports multi_agent_version="
			~ model.multi_agent_version ~ " for " ~ shape.slug
			~ " but capturedModelShapes says " ~ shape.multiAgentVersion
			~ "; re-capture turn_context from this binary");
	}
}

private immutable(CapturedModelShape)* capturedModelShapeFor(string slug)
{
	foreach (ref shape; capturedModelShapes)
		if (shape.slug == slug)
			return &shape;
	return null;
}

/// Whether the per-slug turn_context shape for `slug` was captured from the
/// pinned Codex binary. Slugs outside the catalog fail closed.
package bool hasCapturedModelShape(string slug)
{
	return capturedModelShapeFor(slug) !is null;
}

/// The exact slug set the captured-shape table covers.
package string[] capturedModelShapeSlugs()
{
	string[] slugs;
	foreach (ref shape; capturedModelShapes)
		slugs ~= shape.slug;
	return slugs;
}

private bool isExactCapturedTurnContext(const ref RolloutValue payload,
	string expectedTurnId)
{
	// The admissible key set and the exact values of comp_hash /
	// multi_agent_version / multi_agent_mode are per-model catalog data, so the
	// record's own model must be read and looked up before anything else.
	size_t modelCount;
	auto model = rolloutField(payload, "model", modelCount);
	string modelText;
	if (modelCount != 1 || !rolloutString(model, modelText) || modelText.length == 0)
		return false;
	auto shape = capturedModelShapeFor(modelText);
	if (shape is null)
		return false;
	static immutable string[] keysWithoutMultiAgentMode = [
		"turn_id", "cwd", "workspace_roots", "current_date", "timezone",
		"approval_policy", "approvals_reviewer", "sandbox_policy", "permission_profile",
		"model", "comp_hash", "personality", "collaboration_mode", "multi_agent_version",
		"realtime_active", "summary"];
	static immutable string[] keysWithMultiAgentMode =
		keysWithoutMultiAgentMode ~ "multi_agent_mode";
	if (!rolloutHasOnlyKeys(payload, shape.multiAgentMode is null
			? keysWithoutMultiAgentMode
			: keysWithMultiAgentMode))
		return false;
	size_t turnIdCount, cwdCount, workspaceRootsCount, currentDateCount, timezoneCount;
	size_t approvalPolicyCount, approvalsReviewerCount, sandboxPolicyCount;
	size_t permissionProfileCount, compHashCount, personalityCount, collaborationModeCount;
	size_t multiAgentVersionCount, multiAgentModeCount, realtimeActiveCount, summaryCount;
	auto turnId = rolloutField(payload, "turn_id", turnIdCount);
	auto cwd = rolloutField(payload, "cwd", cwdCount);
	auto workspaceRoots = rolloutField(payload, "workspace_roots", workspaceRootsCount);
	auto currentDate = rolloutField(payload, "current_date", currentDateCount);
	auto timezone = rolloutField(payload, "timezone", timezoneCount);
	auto approvalPolicy = rolloutField(payload, "approval_policy", approvalPolicyCount);
	auto approvalsReviewer = rolloutField(payload, "approvals_reviewer", approvalsReviewerCount);
	auto sandboxPolicy = rolloutField(payload, "sandbox_policy", sandboxPolicyCount);
	auto permissionProfile = rolloutField(payload, "permission_profile", permissionProfileCount);
	auto compHash = rolloutField(payload, "comp_hash", compHashCount);
	auto personality = rolloutField(payload, "personality", personalityCount);
	auto collaborationMode = rolloutField(payload, "collaboration_mode", collaborationModeCount);
	auto multiAgentVersion = rolloutField(payload, "multi_agent_version", multiAgentVersionCount);
	auto multiAgentMode = rolloutField(payload, "multi_agent_mode", multiAgentModeCount);
	auto realtimeActive = rolloutField(payload, "realtime_active", realtimeActiveCount);
	auto summary = rolloutField(payload, "summary", summaryCount);
	string cwdText;
	if (turnIdCount != 1 || !rolloutExactString(turnId, expectedTurnId)
		|| cwdCount != 1 || !rolloutString(cwd, cwdText) || cwdText.length == 0
		|| workspaceRootsCount != 1 || workspaceRoots is null
		|| workspaceRoots.type != RolloutValueType.array || workspaceRoots.values.length != 1
		|| !rolloutExactString(&workspaceRoots.values[0], cwdText)
		|| currentDateCount != 1 || !rolloutNonemptyString(currentDate)
		|| timezoneCount != 1 || !rolloutNonemptyString(timezone)
		|| approvalPolicyCount != 1 || !rolloutExactString(approvalPolicy, "never")
		|| approvalsReviewerCount != 1 || !rolloutExactString(approvalsReviewer, "user")
		|| sandboxPolicyCount != 1 || !isExactCapturedSandboxPolicy(sandboxPolicy)
		|| permissionProfileCount != 1 || !isExactCapturedPermissionProfile(permissionProfile)
		|| compHashCount != 1 || !rolloutExactString(compHash, shape.compHash)
		|| personalityCount != 1 || !rolloutExactString(personality, "pragmatic")
		|| collaborationModeCount != 1
		|| !isExactCapturedCollaborationMode(collaborationMode, modelText)
		|| multiAgentVersionCount != 1
		|| !rolloutExactString(multiAgentVersion, shape.multiAgentVersion)
		|| realtimeActiveCount != 1 || !rolloutExactBoolean(realtimeActive, false)
		|| summaryCount != 1 || !rolloutExactString(summary, "auto"))
		return false;
	// keysWithoutMultiAgentMode already refused the key for shapes that omit it.
	if (shape.multiAgentMode !is null
		&& (multiAgentModeCount != 1
			|| !rolloutExactString(multiAgentMode, shape.multiAgentMode)))
		return false;
	return true;
}

unittest
{
	import std.array : replace;

	// Verbatim turn_context records written by the pinned Codex CLI 0.144.1 for
	// the two slugs CyDo actually requests, differing only in the catalog data
	// this predicate keys on. A single expected shape cannot cover both.
	enum solTurnContext = `{"type":"turn_context","payload":{"turn_id":"CTX","cwd":"/workspace","workspace_roots":["/workspace"],"current_date":"2026-08-08","timezone":"Etc/UTC","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"external-sandbox","network_access":"enabled"},"permission_profile":{"type":"external","network":"enabled"},"model":"gpt-5.6-sol","comp_hash":"3000","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":null,"developer_instructions":null}},"multi_agent_version":"v2","multi_agent_mode":"explicitRequestOnly","realtime_active":false,"summary":"auto"}}`;
	enum lunaTurnContext = `{"type":"turn_context","payload":{"turn_id":"CTX","cwd":"/workspace","workspace_roots":["/workspace"],"current_date":"2026-08-08","timezone":"Etc/UTC","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"external-sandbox","network_access":"enabled"},"permission_profile":{"type":"external","network":"enabled"},"model":"gpt-5.6-luna","comp_hash":"3000","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.6-luna","reasoning_effort":null,"developer_instructions":null}},"multi_agent_version":"v1","realtime_active":false,"summary":"auto"}}`;
	// The pre-catalog shape: no comp_hash, multi_agent_version "disabled", and a
	// slug CyDo never requests for a task session.
	enum miniTurnContext = `{"type":"turn_context","payload":{"turn_id":"CTX","cwd":"/workspace","workspace_roots":["/workspace"],"current_date":"2026-08-08","timezone":"Etc/UTC","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"external-sandbox","network_access":"enabled"},"permission_profile":{"type":"external","network":"enabled"},"model":"codex-mini-latest","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null}},"multi_agent_version":"disabled","realtime_active":false,"summary":"auto"}}`;

	foreach (accepted; [solTurnContext, lunaTurnContext])
		assert(parseRolloutLineEvidence(accepted, 0).contextualPayloadKnown,
			"captured per-slug turn_context must be admitted: " ~ accepted);

	auto refusals = [
		// multi_agent_mode is present for v2 slugs and absent for v1 ones; each
		// slug must refuse the other slug's presence decision.
		lunaTurnContext.replace(`"multi_agent_version":"v1",`,
			`"multi_agent_version":"v1","multi_agent_mode":"explicitRequestOnly",`),
		solTurnContext.replace(`,"multi_agent_mode":"explicitRequestOnly"`, ``),
		solTurnContext.replace(`"multi_agent_version":"v2"`, `"multi_agent_version":"v1"`),
		lunaTurnContext.replace(`"multi_agent_version":"v1"`, `"multi_agent_version":"v2"`),
		solTurnContext.replace(`"comp_hash":"3000",`, ``),
		lunaTurnContext.replace(`"comp_hash":"3000",`, ``),
		solTurnContext.replace(`"comp_hash":"3000"`, `"comp_hash":"2911"`),
		lunaTurnContext.replace(`"comp_hash":"3000"`, `"comp_hash":"2911"`),
		miniTurnContext,
		// An operator model_aliases override can name an uncatalogued slug; the
		// shape for it was never captured, so admission must fail closed.
		solTurnContext.replace(`gpt-5.6-sol`, `gpt-5.6-nova`),
	];
	foreach (i, refused; refusals)
	{
		assert(refused != solTurnContext && refused != lunaTurnContext,
			"refusal case " ~ i.to!string ~ " did not mutate its base record");
		assert(!parseRolloutLineEvidence(refused, 0).contextualPayloadKnown,
			"turn_context off the captured per-slug shape must be refused: " ~ refused);
	}
}

private bool isExactCapturedThreadSettings(const(RolloutValue)* settings)
{
	if (settings is null || settings.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*settings,
			["model", "model_provider_id", "approval_policy", "approvals_reviewer",
			"permission_profile", "cwd", "reasoning_summary", "personality",
			"collaboration_mode"]))
		return false;
	size_t modelCount, providerCount, approvalPolicyCount, approvalsReviewerCount;
	size_t permissionProfileCount, cwdCount, reasoningSummaryCount, personalityCount;
	size_t collaborationModeCount;
	auto model = rolloutField(*settings, "model", modelCount);
	auto provider = rolloutField(*settings, "model_provider_id", providerCount);
	auto approvalPolicy = rolloutField(*settings, "approval_policy", approvalPolicyCount);
	auto approvalsReviewer = rolloutField(*settings, "approvals_reviewer", approvalsReviewerCount);
	auto permissionProfile = rolloutField(*settings, "permission_profile", permissionProfileCount);
	auto cwd = rolloutField(*settings, "cwd", cwdCount);
	// buildConfigOverride (package.d) sets model_reasoning_summary = "auto" on
	// every session; Codex 0.144.1 writes that as a "reasoning_summary" key.
	auto reasoningSummary = rolloutField(*settings, "reasoning_summary", reasoningSummaryCount);
	auto personality = rolloutField(*settings, "personality", personalityCount);
	auto collaborationMode = rolloutField(*settings, "collaboration_mode", collaborationModeCount);
	string modelText;
	return modelCount == 1 && rolloutString(model, modelText) && modelText.length > 0
		&& providerCount == 1 && rolloutNonemptyString(provider)
		&& approvalPolicyCount == 1 && rolloutExactString(approvalPolicy, "never")
		&& approvalsReviewerCount == 1 && rolloutExactString(approvalsReviewer, "user")
		&& permissionProfileCount == 1 && isExactCapturedPermissionProfile(permissionProfile)
		&& cwdCount == 1 && rolloutNonemptyString(cwd)
		&& reasoningSummaryCount == 1 && rolloutExactString(reasoningSummary, "auto")
		&& personalityCount == 1 && rolloutExactString(personality, "pragmatic")
		&& collaborationModeCount == 1
		&& isExactCapturedCollaborationMode(collaborationMode, modelText);
}

private void decodeContextualTopLevel(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	if (evidence.topLevelKind == RolloutTopLevelKind.worldState)
	{
		evidence.contextualPayloadKnown = isExactCapturedWorldState(payload);
		return;
	}
	if (evidence.topLevelKind != RolloutTopLevelKind.turnContext)
		return;

	size_t turnIdCount;
	auto turnId = rolloutField(payload, "turn_id", turnIdCount);
	if (turnIdCount == 1 && rolloutString(turnId, evidence.contextualTurnId))
		evidence.contextualTurnIdValid = evidence.contextualTurnId.length > 0;
	evidence.contextualPayloadKnown = evidence.contextualTurnIdValid
		&& isExactCapturedTurnContext(payload, evidence.contextualTurnId);
}

private void decodeResponseItem(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	size_t typeCount;
	auto payloadType = rolloutField(payload, "type", typeCount);
	if (typeCount != 1 || !rolloutString(payloadType, evidence.payloadType))
		return;
	evidence.payloadKnown = true;

	size_t roleCount;
	auto role = rolloutField(payload, "role", roleCount);
	rolloutString(role, evidence.role);

	size_t metadataCount;
	auto metadata = rolloutField(payload, "internal_chat_message_metadata_passthrough",
		metadataCount);
	evidence.metadataPresent = metadataCount > 0;
	if (metadataCount == 1 && metadata !is null && metadata.type == RolloutValueType.object)
	{
		size_t turnIdCount;
		auto turnId = rolloutField(*metadata, "turn_id", turnIdCount);
		evidence.turnIdPresent = turnIdCount > 0;
		if (turnIdCount == 1 && rolloutString(turnId, evidence.turnId))
			evidence.turnIdValid = evidence.turnId.length > 0;
		evidence.metadataKnown = rolloutHasOnlyKeys(*metadata, ["turn_id"])
			&& evidence.turnIdPresent && evidence.turnIdValid;
	}

	size_t idCount;
	auto id = rolloutField(payload, "id", idCount);
	evidence.itemIdPresent = idCount > 0;
	if (idCount == 1 && rolloutString(id, evidence.itemId))
		evidence.itemIdValid = evidence.itemId.length > 0;

	if (evidence.payloadType != "message")
	{
		evidence.responseUnknownFields = !rolloutHasOnlyKeys(payload,
			["type", "id", "internal_chat_message_metadata_passthrough", "arguments",
			"call_id", "name", "input", "output", "action", "summary", "content",
			"namespace", "reasoning", "role"]);
		return;
	}

	if (evidence.role == "user")
		evidence.probe.messageRole = ForkableMessageRole.user;
	else if (evidence.role == "assistant")
		evidence.probe.messageRole = ForkableMessageRole.assistant;

	size_t contentCount;
	auto content = rolloutField(payload, "content", contentCount);
	if (contentCount == 1)
		decodeContent(evidence, content);

	if (evidence.probe.isUserMessage)
	{
		evidence.userClassificationKnown = evidence.contentClassificationKnown;
		if (evidence.userClassificationKnown)
		{
			if (isCodexTurnAbortedUserText(evidence.inputText))
				evidence.userClassification = CodexUserMessageLineClassification.turnAborted;
			else if (isCodexContextOnlyUserText(evidence.inputText))
				evidence.userClassification = CodexUserMessageLineClassification.contextOnly;
			else
				evidence.userClassification = CodexUserMessageLineClassification.normal;
		}
		evidence.responseUnknownFields = !rolloutHasOnlyKeys(payload,
			["type", "role", "content", "internal_chat_message_metadata_passthrough", "id"]);
	}
	else if (evidence.probe.isAssistantMessage)
	{
		evidence.responseUnknownFields = !rolloutHasOnlyKeys(payload,
			["type", "role", "content", "internal_chat_message_metadata_passthrough", "id"]);
	}
	else
		evidence.responseUnknownFields = !rolloutHasOnlyKeys(payload,
			["type", "role", "content", "internal_chat_message_metadata_passthrough", "id"]);
}

private bool isExactTokenUsage(const(RolloutValue)* usage)
{
	if (usage is null || usage.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*usage, ["input_tokens", "cached_input_tokens",
			"output_tokens", "reasoning_output_tokens", "total_tokens"]))
		return false;
	foreach (field; ["input_tokens", "cached_input_tokens", "output_tokens",
		"reasoning_output_tokens", "total_tokens"])
	{
		size_t count;
		auto value = rolloutField(*usage, field, count);
		if (count != 1 || !rolloutNumeric(value))
			return false;
	}
	return true;
}

private bool isExactTokenCountInfo(const(RolloutValue)* info)
{
	if (info is null || info.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*info, ["total_token_usage", "last_token_usage",
			"model_context_window"]))
		return false;
	size_t totalUsageCount, lastUsageCount, contextWindowCount;
	auto totalUsage = rolloutField(*info, "total_token_usage", totalUsageCount);
	auto lastUsage = rolloutField(*info, "last_token_usage", lastUsageCount);
	auto contextWindow = rolloutField(*info, "model_context_window", contextWindowCount);
	return totalUsageCount == 1 && isExactTokenUsage(totalUsage)
		&& lastUsageCount == 1 && isExactTokenUsage(lastUsage)
		&& contextWindowCount == 1 && rolloutNumeric(contextWindow);
}

private bool isExactTokenCountRateLimits(const(RolloutValue)* rateLimits)
{
	if (rateLimits is null || rateLimits.type != RolloutValueType.object
		|| !rolloutHasOnlyKeys(*rateLimits, ["limit_id", "limit_name", "primary",
			"secondary", "credits", "individual_limit", "plan_type",
			"rate_limit_reached_type"]))
		return false;
	size_t limitIdCount;
	string limitId;
	auto limitIdValue = rolloutField(*rateLimits, "limit_id", limitIdCount);
	if (limitIdCount != 1 || !rolloutString(limitIdValue, limitId)
		|| limitId != "codex")
		return false;
	foreach (field; ["limit_name", "primary", "secondary", "credits",
		"individual_limit", "plan_type", "rate_limit_reached_type"])
	{
		size_t count;
		auto value = rolloutField(*rateLimits, field, count);
		if (count != 1 || !rolloutNull(value))
			return false;
	}
	return true;
}

private void decodeEventMessage(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	size_t typeCount;
	auto type = rolloutField(payload, "type", typeCount);
	if (typeCount != 1 || !rolloutString(type, evidence.payloadType))
		return;
	evidence.payloadKnown = true;

	size_t turnIdCount;
	auto turnId = rolloutField(payload, "turn_id", turnIdCount);
	evidence.eventTurnIdPresent = turnIdCount > 0;
	if (turnIdCount == 1 && rolloutString(turnId, evidence.eventTurnId))
		evidence.eventTurnIdValid = evidence.eventTurnId.length > 0;

	if (evidence.payloadType == "task_started")
	{
		size_t startedAtCount, contextWindowCount, collaborationModeCount;
		auto startedAt = rolloutField(payload, "started_at", startedAtCount);
		auto contextWindow = rolloutField(payload, "model_context_window", contextWindowCount);
		auto collaborationMode = rolloutField(payload, "collaboration_mode_kind",
			collaborationModeCount);
		evidence.probe.isTaskStarted = true;
		evidence.eventKnown = rolloutHasOnlyKeys(payload,
			["type", "turn_id", "started_at", "model_context_window", "collaboration_mode_kind"])
			&& evidence.eventTurnIdValid && startedAtCount == 1 && rolloutNumeric(startedAt)
			&& contextWindowCount == 1 && rolloutNumeric(contextWindow)
			&& collaborationModeCount == 1 && rolloutExactString(collaborationMode, "default");
		return;
	}
	if (evidence.payloadType == "thread_rolled_back")
	{
		evidence.probe.isThreadRolledBack = true;
		size_t count;
		auto numTurns = rolloutField(payload, "num_turns", count);
		if (count == 1 && numTurns !is null && numTurns.type == RolloutValueType.numeric)
		{
			try evidence.probe.rollbackNumTurns = to!uint(numTurns.text);
			catch (Exception) {}
		}
		evidence.eventKnown = rolloutHasOnlyKeys(payload, ["type", "num_turns"])
			&& evidence.probe.rollbackNumTurns > 0;
		return;
	}
	if (evidence.payloadType == "user_message")
	{
		size_t clientCount;
		auto client = rolloutField(payload, "client_id", clientCount);
		evidence.eventClientIdPresent = clientCount > 0;
		if (clientCount == 1 && rolloutString(client, evidence.eventClientId))
			evidence.eventClientIdValid = evidence.eventClientId.length > 0;

		size_t messageCount;
		auto message = rolloutField(payload, "message", messageCount);
		evidence.eventMessagePresent = messageCount > 0;
		evidence.eventMessageValid = messageCount == 1
			&& rolloutString(message, evidence.eventMessage);

		size_t imagesCount;
		auto images = rolloutField(payload, "images", imagesCount);
		evidence.eventImagesValid = imagesCount == 1 && images !is null
			&& images.type == RolloutValueType.array;
		if (evidence.eventImagesValid)
			evidence.eventImagesCount = images.values.length;

		size_t localImagesCount;
		auto localImages = rolloutField(payload, "local_images", localImagesCount);
		evidence.eventLocalImagesValid = localImagesCount == 1 && localImages !is null
			&& localImages.type == RolloutValueType.array;
		if (evidence.eventLocalImagesValid)
			evidence.eventLocalImagesCount = localImages.values.length;

		size_t textElementsCount;
		auto textElements = rolloutField(payload, "text_elements", textElementsCount);
		evidence.eventTextElementsValid = textElementsCount == 1 && textElements !is null
			&& textElements.type == RolloutValueType.array;
		if (evidence.eventTextElementsValid)
			evidence.eventTextElementsCount = textElements.values.length;

		evidence.eventKnown = rolloutHasOnlyKeys(payload,
			["type", "client_id", "message", "images", "local_images", "text_elements"])
			&& evidence.eventMessageValid && evidence.eventImagesValid
			&& evidence.eventLocalImagesValid && evidence.eventTextElementsValid
			&& (!evidence.eventClientIdPresent || evidence.eventClientIdValid);
		return;
	}
	if (evidence.payloadType == "agent_message")
	{
		size_t messageCount;
		auto message = rolloutField(payload, "message", messageCount);
		evidence.eventMessagePresent = messageCount > 0;
		evidence.eventMessageValid = messageCount == 1
			&& rolloutString(message, evidence.eventMessage);
		size_t phaseCount;
		auto phase = rolloutField(payload, "phase", phaseCount);
		evidence.eventPhaseIsNull = phaseCount == 1 && rolloutNull(phase);
		size_t memoryCitationCount;
		auto memoryCitation = rolloutField(payload, "memory_citation", memoryCitationCount);
		evidence.eventMemoryCitationIsNull = memoryCitationCount == 1
			&& rolloutNull(memoryCitation);
		evidence.eventKnown = rolloutHasOnlyKeys(payload,
			["type", "message", "phase", "memory_citation"])
			&& evidence.eventMessageValid && evidence.eventPhaseIsNull
			&& evidence.eventMemoryCitationIsNull;
		return;
	}
	if (evidence.payloadType == "task_complete")
	{
		size_t lastMessageCount, completedAtCount, durationCount, firstTokenCount;
		auto lastMessage = rolloutField(payload, "last_agent_message", lastMessageCount);
		auto completedAt = rolloutField(payload, "completed_at", completedAtCount);
		auto duration = rolloutField(payload, "duration_ms", durationCount);
		auto firstToken = rolloutField(payload, "time_to_first_token_ms", firstTokenCount);
		evidence.eventLastAgentMessagePresent = lastMessageCount > 0;
		evidence.eventLastAgentMessageIsNull = lastMessageCount == 1 && rolloutNull(lastMessage);
		evidence.eventLastAgentMessageValid = lastMessageCount == 1
			&& (evidence.eventLastAgentMessageIsNull
				|| rolloutString(lastMessage, evidence.eventLastAgentMessage));
		evidence.eventKnown = rolloutHasOnlyKeys(payload,
			["type", "turn_id", "last_agent_message", "completed_at", "duration_ms",
			"time_to_first_token_ms"]) && evidence.eventTurnIdValid
			&& evidence.eventLastAgentMessageValid
			&& completedAtCount == 1 && rolloutNumeric(completedAt)
			&& durationCount == 1 && rolloutNumeric(duration)
			&& (firstTokenCount == 0 || (firstTokenCount == 1 && rolloutNumeric(firstToken)));
		return;
	}
	if (evidence.payloadType == "turn_aborted")
	{
		size_t reasonCount;
		auto reason = rolloutField(payload, "reason", reasonCount);
		size_t completedAtCount, durationCount;
		auto completedAt = rolloutField(payload, "completed_at", completedAtCount);
		auto duration = rolloutField(payload, "duration_ms", durationCount);
		evidence.eventReasonValid = reasonCount == 1
			&& rolloutString(reason, evidence.eventReason);
		evidence.eventKnown = rolloutHasOnlyKeys(payload,
			["type", "turn_id", "reason", "completed_at", "duration_ms"])
			&& evidence.eventTurnIdValid && evidence.eventReasonValid
			&& completedAtCount == 1 && rolloutNumeric(completedAt)
			&& durationCount == 1 && rolloutNumeric(duration);
		return;
	}
	if (evidence.payloadType == "context_compacted")
	{
		evidence.eventKnown = rolloutHasOnlyKeys(payload, ["type"]);
		return;
	}
	if (evidence.payloadType == "token_count")
	{
		size_t infoCount, rateLimitsCount;
		auto info = rolloutField(payload, "info", infoCount);
		auto rateLimits = rolloutField(payload, "rate_limits", rateLimitsCount);
		if (!rolloutHasOnlyKeys(payload, ["type", "info", "rate_limits"])
			|| infoCount != 1 || !isExactTokenCountInfo(info)
			|| rateLimitsCount != 1)
			return;
		if (isExactTokenCountRateLimits(rateLimits))
			evidence.tokenCountRateLimitsShape = CodexTokenCountRateLimitsShape.object;
		else if (rolloutNull(rateLimits))
			evidence.tokenCountRateLimitsShape = CodexTokenCountRateLimitsShape.null_;
		evidence.eventTelemetryKnown = evidence.tokenCountRateLimitsShape
			!= CodexTokenCountRateLimitsShape.unknown;
		return;
	}
	if (evidence.payloadType == "thread_settings_applied")
	{
		size_t settingsCount;
		auto settings = rolloutField(payload, "thread_settings", settingsCount);
		evidence.eventTelemetryKnown = rolloutHasOnlyKeys(payload,
			["type", "thread_settings"])
			&& settingsCount == 1 && isExactCapturedThreadSettings(settings);
		return;
	}
}

private void decodeCompacted(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	evidence.isCompacted = true;
	size_t messageCount, historyCount, windowNumberCount, firstWindowCount;
	size_t previousWindowCount, windowIdCount;
	auto message = rolloutField(payload, "message", messageCount);
	auto history = rolloutField(payload, "replacement_history", historyCount);
	auto windowNumber = rolloutField(payload, "window_number", windowNumberCount);
	auto firstWindow = rolloutField(payload, "first_window_id", firstWindowCount);
	auto previousWindow = rolloutField(payload, "previous_window_id", previousWindowCount);
	auto windowId = rolloutField(payload, "window_id", windowIdCount);
	string messageText, firstWindowId, previousWindowId, compactedWindowId;
	evidence.compactedKnown = rolloutHasOnlyKeys(payload,
		["message", "replacement_history", "window_number", "first_window_id",
		"previous_window_id", "window_id"])
		&& messageCount == 1 && rolloutString(message, messageText)
		&& historyCount == 1 && history !is null && history.type == RolloutValueType.array
		&& windowNumberCount == 1 && rolloutNumeric(windowNumber)
		&& firstWindowCount == 1 && rolloutString(firstWindow, firstWindowId)
		&& previousWindowCount == 1 && rolloutString(previousWindow, previousWindowId)
		&& windowIdCount == 1 && rolloutString(windowId, compactedWindowId);
	if (!evidence.compactedKnown)
	{
		return;
	}
	foreach (ref entry; history.values)
	{
		if (entry.type != RolloutValueType.object)
		{
			evidence.compactedKnown = false;
			continue;
		}
		size_t typeCount, roleCount, contentCount, metadataCount;
		auto type = rolloutField(entry, "type", typeCount);
		auto role = rolloutField(entry, "role", roleCount);
		auto content = rolloutField(entry, "content", contentCount);
		auto metadata = rolloutField(entry, "internal_chat_message_metadata_passthrough",
			metadataCount);
		string entryType, entryRole;
		if (!rolloutHasOnlyKeys(entry,
			["type", "role", "content", "internal_chat_message_metadata_passthrough"])
			|| typeCount != 1 || !rolloutString(type, entryType) || entryType != "message"
			|| roleCount != 1 || !rolloutString(role, entryRole) || entryRole != "user"
			|| contentCount != 1 || content is null || content.type != RolloutValueType.array
			|| content.values.length != 1 || content.values[0].type != RolloutValueType.object
			|| !rolloutHasOnlyKeys(content.values[0], ["type", "text"])
			|| metadataCount != 1 || metadata is null
			|| metadata.type != RolloutValueType.object)
		{
			evidence.compactedKnown = false;
			continue;
		}
		size_t contentTypeCount, contentTextCount;
		auto contentType = rolloutField(content.values[0], "type", contentTypeCount);
		auto contentText = rolloutField(content.values[0], "text", contentTextCount);
		string entryContentType, entryText;
		if (contentTypeCount != 1 || !rolloutString(contentType, entryContentType)
			|| entryContentType != "input_text" || contentTextCount != 1
			|| !rolloutString(contentText, entryText))
		{
			evidence.compactedKnown = false;
			continue;
		}
		size_t turnIdCount;
		auto turnId = rolloutField(*metadata, "turn_id", turnIdCount);
		string value;
		if (!rolloutHasOnlyKeys(*metadata, ["turn_id"])
			|| turnIdCount != 1 || !rolloutString(turnId, value) || value.length == 0)
		{
			evidence.compactedKnown = false;
			continue;
		}
		evidence.compactedReplacementTurnIds ~= value;
	}
}

package RolloutLineEvidence parseRolloutLineEvidence(string line, int lineNumber)
{
	RolloutLineEvidence result;
	result.lineNumber = lineNumber;
	result.rawLine = line;
	result.parsed = parseRolloutValue(line, result.raw);
	if (!result.parsed || result.raw.type != RolloutValueType.object)
		return result;

	size_t typeCount;
	auto type = rolloutField(result.raw, "type", typeCount);
	string topType;
	if (typeCount != 1 || !rolloutString(type, topType))
		return result;
	switch (topType)
	{
		case "session_meta": result.topLevelKind = RolloutTopLevelKind.sessionMeta; break;
		case "world_state": result.topLevelKind = RolloutTopLevelKind.worldState; break;
		case "turn_context": result.topLevelKind = RolloutTopLevelKind.turnContext; break;
		case "response_item": result.topLevelKind = RolloutTopLevelKind.responseItem; break;
		case "event_msg": result.topLevelKind = RolloutTopLevelKind.eventMsg; break;
		case "compacted": result.topLevelKind = RolloutTopLevelKind.compacted; break;
		default: break;
	}
	result.probe.isSessionMeta = result.topLevelKind == RolloutTopLevelKind.sessionMeta;
	result.probe.isTurnContext = result.topLevelKind == RolloutTopLevelKind.turnContext;
	result.probe.isResponseItem = result.topLevelKind == RolloutTopLevelKind.responseItem;
	result.probe.isEventMsg = result.topLevelKind == RolloutTopLevelKind.eventMsg;

	size_t payloadCount;
	auto payload = rolloutField(result.raw, "payload", payloadCount);
	size_t timestampCount;
	auto timestamp = rolloutField(result.raw, "timestamp", timestampCount);
	string timestampText;
	result.topLevelEnvelopeKnown = rolloutHasOnlyKeys(result.raw,
		["timestamp", "type", "payload"])
		&& timestampCount <= 1
		&& (timestampCount == 0 || rolloutString(timestamp, timestampText))
		&& payloadCount == 1 && payload !is null && payload.type == RolloutValueType.object;
	if (payloadCount != 1 || payload is null || payload.type != RolloutValueType.object)
		return result;
	if (result.probe.isResponseItem)
		decodeResponseItem(result, *payload);
	else if (result.probe.isEventMsg)
		decodeEventMessage(result, *payload);
	else if (topType == "compacted")
		decodeCompacted(result, *payload);
	else
		decodeContextualTopLevel(result, *payload);
	return result;
}

private void recordLifecycle(ref RolloutTurnLifecycleEvidence[string] lifecycles,
	const ref RolloutLineEvidence line, int lineIndex)
{
	auto lifecycle = line.eventTurnId in lifecycles;
	if (lifecycle is null)
	{
		lifecycles[line.eventTurnId] = RolloutTurnLifecycleEvidence.init;
		lifecycle = line.eventTurnId in lifecycles;
	}
	if (line.payloadType == "task_started")
	{
		lifecycle.starts++;
		lifecycle.startIndex = lineIndex;
		lifecycle.known = lifecycle.known && line.eventKnown;
	}
	else if (line.payloadType == "task_complete")
	{
		lifecycle.completes++;
		lifecycle.completeIndex = lineIndex;
		lifecycle.known = lifecycle.known && line.eventKnown;
	}
	else if (line.payloadType == "turn_aborted")
	{
		lifecycle.aborts++;
		lifecycle.abortIndex = lineIndex;
		lifecycle.known = lifecycle.known && line.eventKnown;
	}
}

/// A native rollback marker counts provider-materialized lifecycle segments.
/// Keep this stricter than the historical replay projection: a malformed or
/// orphan start remains live evidence for preparation to reject, rather than
/// becoming a phantom marker slot.
package bool isKnownNativeLifecycleRecord(const ref RolloutLineEvidence line,
	string payloadType)
{
	return line.parsed && line.topLevelEnvelopeKnown && line.probe.isEventMsg
		&& line.payloadKnown && line.payloadType == payloadType
		&& line.eventKnown && line.eventTurnIdValid;
}

private bool isKnownNativeRollbackMarker(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown && line.probe.isEventMsg
		&& line.payloadKnown && line.payloadType == "thread_rolled_back"
		&& line.eventKnown && line.probe.rollbackNumTurns > 0;
}

package bool isExactNativeCompletedTerminal(const ref RolloutLineEvidence line,
	string turnId, string agentText)
{
	return agentText.length > 0 && isKnownNativeLifecycleRecord(line, "task_complete")
		&& line.eventTurnId == turnId && line.eventLastAgentMessageValid
		&& !line.eventLastAgentMessageIsNull && line.eventLastAgentMessage == agentText;
}

package bool isExactNativeCompactionTerminal(const ref RolloutLineEvidence line,
	string turnId)
{
	return isKnownNativeLifecycleRecord(line, "task_complete")
		&& line.eventTurnId == turnId && line.eventLastAgentMessageValid
		&& line.eventLastAgentMessageIsNull;
}

package bool isExactNativeInterruptedTerminal(const ref RolloutLineEvidence line,
	string turnId)
{
	return isKnownNativeLifecycleRecord(line, "turn_aborted")
		&& line.eventTurnId == turnId && line.eventReasonValid
		&& line.eventReason == "interrupted";
}

package CodexNativeTerminalKind nativeTerminalKind(const ref RolloutLineEvidence line)
{
	if (isKnownNativeLifecycleRecord(line, "task_complete")
		&& line.eventLastAgentMessageValid)
		return line.eventLastAgentMessageIsNull
			? CodexNativeTerminalKind.completedCompaction
			: CodexNativeTerminalKind.completedSimple;
	if (isKnownNativeLifecycleRecord(line, "turn_aborted")
		&& line.eventReasonValid && line.eventReason == "interrupted")
		return CodexNativeTerminalKind.interrupted;
	return CodexNativeTerminalKind.unknown;
}

package bool isExactNativePreTerminalTelemetry(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.eventMsg && line.probe.isEventMsg
		&& line.payloadKnown && line.payloadType == "token_count"
		&& line.eventTelemetryKnown && line.tokenCountRateLimitsShape
			== CodexTokenCountRateLimitsShape.object;
}

package bool isExactNativePostTerminalTelemetry(const ref RolloutLineEvidence line,
	CodexNativeTerminalKind terminalKind)
{
	if (!(line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.eventMsg && line.probe.isEventMsg
		&& line.payloadKnown && line.eventTelemetryKnown))
		return false;
	if (line.payloadType == "thread_settings_applied")
		return terminalKind == CodexNativeTerminalKind.completedSimple
			|| terminalKind == CodexNativeTerminalKind.completedCompaction;
	if (line.payloadType != "token_count")
		return false;
	switch (terminalKind)
	{
		case CodexNativeTerminalKind.completedSimple:
			return line.tokenCountRateLimitsShape == CodexTokenCountRateLimitsShape.null_;
		case CodexNativeTerminalKind.completedCompaction:
			return line.tokenCountRateLimitsShape == CodexTokenCountRateLimitsShape.null_
				|| line.tokenCountRateLimitsShape == CodexTokenCountRateLimitsShape.object;
		case CodexNativeTerminalKind.interrupted:
			return line.tokenCountRateLimitsShape == CodexTokenCountRateLimitsShape.object;
		case CodexNativeTerminalKind.unknown:
			return false;
		default:
			return false;
	}
}

package struct NativeRolloutSegment
{
	size_t start;
	size_t end;
	string turnId;
}

package bool hasExactCompactionReplacementHistory(const ref RolloutLineEvidence line,
	scope const string[] expectedTurnIds)
{
	if (!line.isCompacted || !line.compactedKnown || expectedTurnIds.length == 0
		|| line.compactedReplacementTurnIds.length != expectedTurnIds.length)
		return false;
	bool[string] seenTurnIds;
	foreach (i, turnId; expectedTurnIds)
	{
		if (turnId.length == 0 || turnId in seenTurnIds
			|| line.compactedReplacementTurnIds[i] != turnId)
			return false;
		seenTurnIds[turnId] = true;
	}
	return true;
}

private bool knownNativeLifecycleSegment(const ref RolloutLineEvidence[] lines,
	size_t start, size_t end, out string turnId, out size_t terminalIndex)
{
	if (start >= end || !isKnownNativeLifecycleRecord(lines[start], "task_started"))
		return false;
	turnId = lines[start].eventTurnId;
	size_t terminals;
	foreach (i; start + 1 .. end)
	{
		auto line = lines[i];
		if (!line.probe.isEventMsg || (line.payloadType != "task_complete"
			&& line.payloadType != "turn_aborted"))
			continue;
		if (!isKnownNativeLifecycleRecord(line, line.payloadType)
			|| line.eventTurnId != turnId)
			return false;
		terminalIndex = i;
		terminals++;
	}
	return terminals == 1;
}

package bool isExactNativeSubmittedUser(const ref RolloutLineEvidence line,
	string turnId)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.responseItem
		&& line.probe.isUserMessage && line.payloadKnown && line.payloadType == "message"
		&& line.role == "user"
		&& line.userClassification == CodexUserMessageLineClassification.normal
		&& line.userClassificationKnown && line.contentKnown && line.contentSingleInputText
		&& !line.responseUnknownFields && !line.itemIdPresent
		&& line.metadataKnown && line.turnIdValid && line.turnId == turnId;
}

package bool isExactNativeUserEvent(const ref RolloutLineEvidence event,
	const ref RolloutLineEvidence response)
{
	return event.parsed && event.topLevelEnvelopeKnown
		&& event.topLevelKind == RolloutTopLevelKind.eventMsg
		&& event.probe.isEventMsg && event.payloadKnown && event.payloadType == "user_message"
		&& event.eventKnown && event.eventMessageValid
		&& event.eventMessage == response.inputText
		&& event.eventImagesCount == 0 && event.eventLocalImagesCount == 0
		&& event.eventTextElementsCount == 0;
}

package enum capturedNativeV1AbortWrapper = "<turn_aborted>\n"
	~ "The user interrupted the previous turn on purpose. Any running unified exec "
	~ "processes may still be running in the background. If any tools/commands "
	~ "were aborted, they may have partially executed.\n</turn_aborted>";

package bool isExactNativeV1AbortWrapper(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.responseItem
		&& line.probe.isUserMessage && line.payloadKnown && line.payloadType == "message"
		&& line.role == "user" && line.userClassification
		== CodexUserMessageLineClassification.turnAborted
		&& line.userClassificationKnown && line.contentKnown
		&& line.contentSingleInputText && line.contentCount == 1
		&& !line.responseUnknownFields && !line.itemIdPresent
		&& line.metadataPresent && line.metadataKnown && line.turnIdPresent
		&& line.turnIdValid && line.inputText == capturedNativeV1AbortWrapper;
}

package bool isExactNativeAssistantResponse(const ref RolloutLineEvidence line,
	string turnId)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.responseItem
		&& line.probe.isAssistantMessage && line.payloadKnown && line.payloadType == "message"
		&& line.role == "assistant" && line.metadataKnown && line.turnIdValid
		&& line.turnId == turnId && line.itemIdValid && line.contentSingleOutputText
		&& line.contentText.length > 0 && !line.responseUnknownFields;
}

package bool isExactNativeAgentEvent(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.eventMsg && line.probe.isEventMsg
		&& line.payloadKnown && line.payloadType == "agent_message" && line.eventKnown
		&& line.eventMessageValid && line.eventMessage.length > 0;
}

package bool isExactNativePreSubmissionContext(const ref RolloutLineEvidence line,
	string turnId)
{
	if (!line.parsed || !line.topLevelEnvelopeKnown || !line.probe.isResponseItem
		|| !line.payloadKnown || line.payloadType != "message"
		|| !line.metadataKnown || line.turnId != turnId || line.responseUnknownFields
		|| line.itemIdPresent || !line.contentKnown || !line.contentTextsNonempty
		|| line.contentCount == 0 || line.contentTypes.length != line.contentCount)
		return false;
	foreach (contentType; line.contentTypes)
		if (contentType != "input_text")
			return false;
	if (line.role == "developer")
		return true;
	return line.probe.isUserMessage && line.contentCount == 1
		&& line.contentSingleInputText && line.userClassificationKnown
		&& line.userClassification == CodexUserMessageLineClassification.contextOnly;
}

package bool isExactNativePreSubmissionEnvelope(const ref RolloutLineEvidence line,
	string turnId)
{
	return line.parsed && line.topLevelEnvelopeKnown && line.contextualPayloadKnown
		&& (line.topLevelKind == RolloutTopLevelKind.worldState
			|| (line.topLevelKind == RolloutTopLevelKind.turnContext
				&& line.contextualTurnIdValid && line.contextualTurnId == turnId));
}

private bool isExactNativePreSubmissionRecord(const ref RolloutLineEvidence line,
	string turnId)
{
	return isExactNativePreSubmissionEnvelope(line, turnId)
		|| isExactNativePreSubmissionContext(line, turnId);
}

private bool hasCorroborableNativeSubmittedUser(const ref RolloutLineEvidence[] lines,
	size_t start, size_t terminalIndex, string turnId)
{
	int submittedResponseIndex = -1;
	int submittedEventIndex = -1;
	int assistantIndex = -1;
	int agentIndex = -1;
	int abortWrapperIndex = -1;
	foreach (i; start + 1 .. terminalIndex)
	{
		auto line = lines[i];
		if (isExactNativePreTerminalTelemetry(line))
			continue;
		if (isExactNativePreSubmissionRecord(line, turnId))
		{
			if (submittedResponseIndex >= 0)
				return false;
			continue;
		}
		if (isExactNativeSubmittedUser(line, turnId))
		{
			if (submittedResponseIndex >= 0 || i + 1 >= terminalIndex
				|| lines[i + 1].lineNumber != line.lineNumber + 1
				|| !isExactNativeUserEvent(lines[i + 1], line))
				return false;
			submittedResponseIndex = cast(int)i;
			submittedEventIndex = cast(int)(i + 1);
			continue;
		}
		if (cast(int)i == submittedEventIndex)
			continue;
		if (isExactNativeV1AbortWrapper(line))
		{
			if (lines[terminalIndex].payloadType != "turn_aborted"
				|| submittedEventIndex < 0 || abortWrapperIndex >= 0
				|| line.turnId != turnId || i + 1 != terminalIndex)
				return false;
			abortWrapperIndex = cast(int)i;
			continue;
		}
		if (isExactNativeAssistantResponse(line, turnId))
		{
			if (submittedEventIndex < 0 || i <= cast(size_t)submittedEventIndex
				|| assistantIndex >= 0)
				return false;
			assistantIndex = cast(int)i;
			continue;
		}
		if (isExactNativeAgentEvent(line))
		{
			if (submittedEventIndex < 0 || i <= cast(size_t)submittedEventIndex
				|| agentIndex >= 0)
				return false;
			agentIndex = cast(int)i;
			continue;
		}
		return false;
	}
	if (submittedResponseIndex < 0 || submittedEventIndex < 0)
		return false;
	if (lines[terminalIndex].payloadType == "task_complete")
		return abortWrapperIndex < 0 && assistantIndex >= 0 && agentIndex >= 0
			&& lines[assistantIndex].contentText == lines[agentIndex].eventMessage
			&& isExactNativeCompletedTerminal(lines[terminalIndex], turnId,
				lines[assistantIndex].contentText);
	return lines[terminalIndex].payloadType == "turn_aborted"
		&& assistantIndex < 0 && agentIndex < 0 && abortWrapperIndex >= 0
		&& isExactNativeInterruptedTerminal(lines[terminalIndex], turnId);
}

/// The observed task lifecycle can carry one exact contextual role=user tail
/// after completion. It belongs to the historical user projection, not to a
/// second native turn. Keep that established shape separate from semantic
/// native evidence, which must not appear after the terminal record.
private bool isApprovedNativePostTerminalContext(const ref RolloutLineEvidence line,
	string turnId)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.responseItem
		&& line.probe.isUserMessage && line.payloadKnown && line.payloadType == "message"
		&& line.role == "user" && line.userClassificationKnown
		&& line.userClassification == CodexUserMessageLineClassification.contextOnly
		&& line.contentKnown && line.contentSingleInputText && line.contentTextsNonempty
		&& line.contentCount == 1 && line.contentTypes.length == 1
		&& !line.responseUnknownFields && !line.itemIdPresent
		&& line.metadataKnown && line.turnIdValid && line.turnId == turnId;
}

private bool hasOnlyApprovedNativePostTerminalRecords(
	const ref RolloutLineEvidence[] lines, size_t terminalIndex, size_t end,
	string turnId, bool endsAtKnownRollbackMarker)
{
	auto terminalKind = nativeTerminalKind(lines[terminalIndex]);
	if (terminalKind == CodexNativeTerminalKind.unknown)
		return false;
	size_t contextualTails;
	foreach (i; terminalIndex + 1 .. end)
		if (isApprovedNativePostTerminalContext(lines[i], turnId))
		{
			if (lines[terminalIndex].payloadType != "task_complete"
				|| ++contextualTails != 1)
				return false;
		}
		else if (!isExactNativePostTerminalTelemetry(lines[i], terminalKind)
			&& !(endsAtKnownRollbackMarker && i + 1 == end
				&& isExactNativeRollbackRecomputedTelemetry(lines[i])))
			return false;
	return true;
}

/// thread/rollback recomputes the thread's token usage and appends that
/// token_count immediately before the thread_rolled_back marker it also
/// appends. That record carries an object rate_limits even when the segment's
/// own terminal was a plain completion, which the per-terminal-kind post
/// telemetry shape deliberately refuses. Admit it only in that exact position:
/// the record directly preceding a known rollback marker.
private bool isExactNativeRollbackRecomputedTelemetry(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.eventMsg && line.probe.isEventMsg
		&& line.payloadKnown && line.eventTelemetryKnown
		&& line.payloadType == "token_count"
		&& line.tokenCountRateLimitsShape == CodexTokenCountRateLimitsShape.object;
}

private bool hasExactKnownNativeCompaction(const ref RolloutLineEvidence[] lines,
	size_t start, string turnId, size_t terminalIndex,
	const ref NativeRolloutSegment[] activeNativeSegments)
{
	auto terminal = lines[terminalIndex];
	if (!isExactNativeCompactionTerminal(terminal, turnId))
		return false;

	string[] expectedHistoryTurnIds;
	foreach (segment; activeNativeSegments)
		expectedHistoryTurnIds ~= segment.turnId;
	expectedHistoryTurnIds ~= turnId;

	size_t assistants;
	size_t compacted;
	size_t contextCompacted;
	size_t assistantIndex;
	size_t compactedIndex;
	size_t contextCompactedIndex;
	foreach (i; start + 1 .. terminalIndex)
	{
		auto line = lines[i];
		if (line.probe.isAssistantMessage)
		{
			if (!isExactNativeAssistantResponse(line, turnId))
				return false;
			assistants++;
			assistantIndex = i;
		}
		else if (line.isCompacted)
		{
			if (!line.parsed || !line.topLevelEnvelopeKnown || !line.compactedKnown
				|| !hasExactCompactionReplacementHistory(line, expectedHistoryTurnIds))
				return false;
			compacted++;
			compactedIndex = i;
		}
		else if (line.probe.isEventMsg && line.payloadType == "context_compacted")
		{
			if (!line.parsed || !line.topLevelEnvelopeKnown || !line.eventKnown)
				return false;
			contextCompacted++;
			contextCompactedIndex = i;
		}
		else if (!isExactNativePreTerminalTelemetry(line))
			return false;
	}
	return assistants == 1 && compacted == 1 && contextCompacted == 1
		&& assistantIndex < compactedIndex && compactedIndex < contextCompactedIndex;
}

private bool isCompleteKnownNativeSegment(const ref RolloutLineEvidence[] lines,
	size_t start, size_t end, const ref NativeRolloutSegment[] activeNativeSegments,
	bool endsAtKnownRollbackMarker)
{
	string turnId;
	size_t terminalIndex;
	return knownNativeLifecycleSegment(lines, start, end, turnId, terminalIndex)
		&& hasOnlyApprovedNativePostTerminalRecords(lines, terminalIndex, end, turnId,
			endsAtKnownRollbackMarker)
		&& (hasCorroborableNativeSubmittedUser(lines, start, terminalIndex, turnId)
			|| hasExactKnownNativeCompaction(lines, start, turnId, terminalIndex,
				activeNativeSegments));
}

private void appendCompleteKnownNativeSegment(ref NativeRolloutSegment[] segments,
	ref bool[string] seenLifecycleTurnIds, const ref RolloutLineEvidence[] lines,
	size_t start, size_t end, bool endsAtKnownRollbackMarker)
{
	string turnId;
	size_t terminalIndex;
	if (!knownNativeLifecycleSegment(lines, start, end, turnId, terminalIndex))
		return;
	if (turnId in seenLifecycleTurnIds)
	{
		foreach (i; 0 .. segments.length)
			if (segments[i].turnId == turnId)
			{
				segments = segments[0 .. i] ~ segments[i + 1 .. $];
				break;
			}
		return;
	}
	seenLifecycleTurnIds[turnId] = true;
	if (isCompleteKnownNativeSegment(lines, start, end, segments, endsAtKnownRollbackMarker))
		segments ~= NativeRolloutSegment(start, end, turnId);
}

/// Scan rollout JSONL once in physical line order. Markers are applied both to
/// the historical replay user segments and to native task_started lifecycle
/// segments. They intentionally remain separate: replay excludes rollback-
/// eligible role=user groups, while native rollback counts materialized turns.
package RolloutScan scanRollout(string content, int lineOffset = 0)
{
	import std.string : lineSplitter;

	RolloutScan result;
	int lineNumber = lineOffset;
	foreach (line; content.lineSplitter)
	{
		lineNumber++;
		result.lines ~= parseRolloutLineEvidence(line, lineNumber);
	}

	bool seenTaskStarted = lineOffset > 0;
	size_t[] activeUserSegments;
	foreach (i, ref line; result.lines)
	{
		if (!seenTaskStarted && line.probe.isTaskStarted)
			seenTaskStarted = true;
		if (line.probe.isThreadRolledBack)
		{
			line.active = false;
			auto removeUserCount = line.probe.rollbackNumTurns > activeUserSegments.length
				? activeUserSegments.length : line.probe.rollbackNumTurns;
			auto removedUsers = activeUserSegments[$ - removeUserCount .. $];
			activeUserSegments = activeUserSegments[0 .. $ - removeUserCount];
			foreach (removedIndex, start; removedUsers)
			{
				auto end = removedIndex + 1 < removedUsers.length
					? removedUsers[removedIndex + 1] : i;
				foreach (lineIndex; start .. end)
					result.lines[lineIndex].active = false;
			}
			continue;
		}
		if (seenTaskStarted && line.probe.isUserMessage
			&& line.userClassification != CodexUserMessageLineClassification.turnAborted)
			activeUserSegments ~= i;
	}

	// Native marker liveness is intentionally separate from the historical
	// role=user view above. Only a complete exact task_started lifecycle can
	// occupy a provider turn slot when it has a corroborable submitted caller or
	// exact compaction projection. Every malformed, orphan, uncorroborated, or
	// duplicate lifecycle remains live strict evidence so native preparation
	// cannot silently select behind it.
	NativeRolloutSegment[] activeNativeSegments;
	bool[string] seenNativeLifecycleTurnIds;
	int nativeSegmentStart = -1;
	foreach (i, ref line; result.lines)
	{
		if (line.probe.isTaskStarted)
		{
			if (nativeSegmentStart >= 0)
				appendCompleteKnownNativeSegment(activeNativeSegments,
					seenNativeLifecycleTurnIds, result.lines,
					cast(size_t) nativeSegmentStart, i, false);
			nativeSegmentStart = cast(int) i;
			continue;
		}
		if (!line.probe.isThreadRolledBack)
			continue;

		if (nativeSegmentStart >= 0)
			appendCompleteKnownNativeSegment(activeNativeSegments,
				seenNativeLifecycleTurnIds, result.lines,
				cast(size_t) nativeSegmentStart, i, isKnownNativeRollbackMarker(line));
		nativeSegmentStart = -1;
		if (!isKnownNativeRollbackMarker(line))
			continue;

		line.nativeActive = false;
		auto removeNativeCount = line.probe.rollbackNumTurns > activeNativeSegments.length
			? activeNativeSegments.length : line.probe.rollbackNumTurns;
		auto removedNative = activeNativeSegments[$ - removeNativeCount .. $];
		activeNativeSegments = activeNativeSegments[0 .. $ - removeNativeCount];
		foreach (segment; removedNative)
			foreach (lineIndex; segment.start .. segment.end)
				result.lines[lineIndex].nativeActive = false;
	}
	if (nativeSegmentStart >= 0)
		appendCompleteKnownNativeSegment(activeNativeSegments,
			seenNativeLifecycleTurnIds, result.lines,
			cast(size_t) nativeSegmentStart, result.lines.length, false);

	foreach (i, ref line; result.lines)
	{
		if (!line.probe.isUserMessage
			|| line.userClassification != CodexUserMessageLineClassification.normal)
			continue;
		if (i + 1 < result.lines.length
			&& result.lines[i + 1].lineNumber == line.lineNumber + 1
			&& result.lines[i + 1].probe.isEventMsg
			&& result.lines[i + 1].payloadType == "user_message")
				line.immediateUserEventIndex = cast(int)(i + 1);
	}
	result.nativeSegments = activeNativeSegments;

	foreach (i, ref line; result.lines)
	{
		if (!line.active || !line.probe.isEventMsg || !line.eventTurnIdValid)
			continue;
		recordLifecycle(result.lifecycles, line, cast(int)i);
	}
	foreach (i, ref line; result.lines)
	{
		if (!line.nativeActive || !line.probe.isEventMsg || !line.eventTurnIdValid)
			continue;
		recordLifecycle(result.nativeLifecycles, line, cast(int)i);
	}
	return result;
}

/// Parse one rollout JSONL line and return only the fields relevant to
/// history/forkable-line classification.
package RolloutLineProbe parseRolloutLineProbe(string line)
{
	return parseRolloutLineEvidence(line, 0).probe;
}

/// Classification used by the native rollback postcondition. A record with a
/// rollback-shaped payload is not sufficient: the provider marker must retain
/// the exact known envelope and a positive count.
package enum NativeRollbackMarkerStatus
{
	none,
	valid,
	malformed,
}

package struct NativeRollbackMarker
{
	NativeRollbackMarkerStatus status;
	uint numTurns;
}

/// Detect the payload discriminant independently of the top-level envelope.
/// A broken envelope is still an unsafe post-dispatch marker rather than an
/// unrelated record that a later valid marker could hide.
private bool hasRollbackMarkerPayloadShape(const ref RolloutLineEvidence evidence)
{
	if (!evidence.parsed || evidence.raw.type != RolloutValueType.object)
		return false;
	foreach (i, key; evidence.raw.keys)
	{
		if (key != "payload" || evidence.raw.values[i].type != RolloutValueType.object)
			continue;
		foreach (j, payloadKey; evidence.raw.values[i].keys)
			if (payloadKey == "type"
				&& evidence.raw.values[i].values[j].type == RolloutValueType.string_
				&& evidence.raw.values[i].values[j].text == "thread_rolled_back")
				return true;
	}
	return false;
}

package NativeRollbackMarker classifyNativeRollbackMarker(string line)
{
	auto evidence = parseRolloutLineEvidence(line, 0);
	if (!evidence.parsed)
	{
		if (!line.canFind(`"thread_rolled_back"`))
			return NativeRollbackMarker.init;
		NativeRollbackMarker malformed;
		malformed.status = NativeRollbackMarkerStatus.malformed;
		return malformed;
	}
	if (!evidence.probe.isThreadRolledBack && !hasRollbackMarkerPayloadShape(evidence))
		return NativeRollbackMarker.init;

	NativeRollbackMarker result;
	result.numTurns = evidence.probe.rollbackNumTurns;
	result.status = isKnownNativeRollbackMarker(evidence)
		? NativeRollbackMarkerStatus.valid
		: NativeRollbackMarkerStatus.malformed;
	return result;
}

unittest
{
	foreach (duplicateRollbackMarker; [
		`{"timestamp":"first","timestamp":"second","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		`{"type":"event_msg","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1},"payload":{"type":"task_complete"}}`,
		`{"type":"event_msg","payload":{"type":"task_complete"},"payload":{"type":"thread_rolled_back","num_turns":1}}`,
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","type":"thread_rolled_back","num_turns":1}}`,
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1,"num_turns":1}}`,
	])
		assert(classifyNativeRollbackMarker(duplicateRollbackMarker).status
			== NativeRollbackMarkerStatus.malformed);
}

unittest
{
	import std.array : replace;

	// The native planner consumes this scan instead of reparsing a parallel
	// history view. Keep physical adjacency, client identity, contextual
	// classification, and marker liveness together in that one evidence stream.
	string jsonl =
		`{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-retained","started_at":1,"model_context_window":1,"collaboration_mode_kind":"default"}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"retained prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-retained"},"id":"item-retained"}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"user_message","client_id":"client-retained","message":"retained prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"retained answer"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-retained"},"id":"assistant-retained"}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-retained","last_agent_message":"retained answer","completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rolled back prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-dead"},"id":"item-dead"}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"user_message","client_id":"client-dead","message":"rolled back prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[SYSTEM: future contextual input]"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-context"},"id":"item-context"}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"user_message","message":"[SYSTEM: future contextual input]","images":[],"local_images":[],"text_elements":[]}}`;

	auto scan = scanRollout(jsonl);
	assert(scan.lines.length == 10);
	auto retained = scan.lines[1];
	assert(retained.lineNumber == 2 && retained.active
		&& retained.inputText == "retained prompt"
		&& retained.turnId == "turn-retained"
		&& retained.immediateUserEventIndex == 2);
	auto retainedEvent = scan.lines[retained.immediateUserEventIndex];
	assert(retainedEvent.eventKnown && retainedEvent.eventClientId == "client-retained"
		&& retainedEvent.eventMessage == "retained prompt"
		&& retainedEvent.eventImagesCount == 0
		&& retainedEvent.eventLocalImagesCount == 0
		&& retainedEvent.eventTextElementsCount == 0);
	auto retainedLifecycle = "turn-retained" in scan.lifecycles;
	assert(retainedLifecycle !is null && retainedLifecycle.starts == 1
		&& retainedLifecycle.completes == 1 && retainedLifecycle.aborts == 0
		&& retainedLifecycle.known);

	// The marker removes the raw user segment and the marker itself, while
	// leaving the retained prefix available for association.
	assert(!scan.lines[5].active && !scan.lines[6].active && !scan.lines[7].active);
	assert(scan.lines[1].active);

	// A future role=user contextual record remains visible to the planner so it
	// can refuse it rather than mistaking it for a submitted caller input.
	auto contextual = scan.lines[8];
	assert(contextual.active, "future contextual record must remain active");
	assert(contextual.userClassification == CodexUserMessageLineClassification.contextOnly,
		"future contextual record must retain its classification");
	assert(contextual.immediateUserEventIndex < 0,
		"future contextual record must not acquire submitted-user association");

	// Client association is physical, not a search through later events.
	auto nonAdjacent = scanRollout(
		`{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn","started_at":1,"model_context_window":1,"collaboration_mode_kind":"default"}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn"},"id":"item"}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn","last_agent_message":"","completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"user_message","client_id":"late-client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`);
	assert(nonAdjacent.lines[1].immediateUserEventIndex < 0);
	auto blankSeparated = scanRollout(
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn"}}}` ~ "\n\n" ~
		`{"type":"event_msg","payload":{"type":"user_message","client_id":"late-client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`);
	assert(blankSeparated.lines.length == 3 && !blankSeparated.lines[1].parsed
		&& blankSeparated.lines[1].lineNumber == 2);
	assert(blankSeparated.lines[0].immediateUserEventIndex < 0);
	auto terminated = scanRollout(
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn"}}}` ~ "\n");
	assert(terminated.lines.length == 1 && terminated.lines[0].lineNumber == 1);
}

unittest
{
	import std.string : replace;

	string joinParts(scope const string[] values)
	{
		string result;
		foreach (i, value; values)
		{
			if (i > 0)
				result ~= "\n";
			result ~= value;
		}
		return result;
	}

	string started(string turnId)
	{
		return `{"type":"event_msg","payload":{"type":"task_started","turn_id":"`
			~ turnId ~ `","started_at":1,"model_context_window":1,"collaboration_mode_kind":"default"}}`;
	}
	string complete(string turnId, bool compacted = false)
	{
		return `{"type":"event_msg","payload":{"type":"task_complete","turn_id":"`
			~ turnId ~ `","last_agent_message":` ~ (compacted ? "null" : `"answer"`)
			~ `,"completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}`;
	}
	string completeWithLastAgentMessage(string turnId, string message)
	{
		return `{"type":"event_msg","payload":{"type":"task_complete","turn_id":`
			~ toJson(turnId) ~ `,"last_agent_message":` ~ toJson(message)
			~ `,"completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}`;
	}
	string submitted(string turnId)
	{
		return started(turnId) ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"`
			~ turnId ~ `"}}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}` ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}],"internal_chat_message_metadata_passthrough":{"turn_id":"`
			~ turnId ~ `"},"id":"agent-` ~ turnId ~ `"}}` ~ "\n"
			~ complete(turnId);
	}
	string submittedWithPreTerminalTelemetry(string turnId, string telemetry)
	{
		auto terminal = complete(turnId);
		auto rollout = submitted(turnId);
		return rollout[0 .. $ - terminal.length] ~ telemetry ~ "\n" ~ terminal;
	}
	enum compacted = `{"type":"compacted","payload":{"message":"summary","replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U1"}},{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U2"}},{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U3"}},{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":"C"}}],"window_number":1,"first_window_id":"first","previous_window_id":"previous","window_id":"C"}}`;
	string compactedWithHistory(scope const string[] replacementTurnIds)
	{
		string history;
		foreach (i, turnId; replacementTurnIds)
		{
			if (i > 0)
				history ~= ",";
			history ~= `{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":`
				~ toJson(turnId) ~ `}}`;
		}
		return `{"type":"compacted","payload":{"message":"summary","replacement_history":[`
			~ history
			~ `],"window_number":1,"first_window_id":"first","previous_window_id":"previous","window_id":"C"}}`;
	}
	enum compactionAssistant = `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"summary"}],"internal_chat_message_metadata_passthrough":{"turn_id":"C"},"id":"compact-agent"}}`;
	enum rollbackOne = `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	enum rollbackTwo = `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`;
	enum capturedTokenInfo = `{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":258400}`;
	enum capturedNullRateLimits = `{"type":"event_msg","payload":{"type":"token_count","info":`
		~ capturedTokenInfo ~ `,"rate_limits":null}}`;
	enum capturedObjectRateLimits = `{"type":"event_msg","payload":{"type":"token_count","info":`
		~ capturedTokenInfo ~ `,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null}}}`;
	enum capturedThreadSettings = `{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"codex-mini-latest","model_provider_id":"cydo-mock","approval_policy":"never","approvals_reviewer":"user","permission_profile":{"type":"external","network":"enabled"},"cwd":"/workspace","reasoning_summary":"auto","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null}}}}}`;
	enum capturedWorldState = `{"type":"world_state","payload":{"full":true,"state":{"agents_md":{},"apps_instructions":false,"environments":{"environments":{"local":{"cwd":"/workspace","status":"available","shell":"zsh"}},"current_date":"2026-08-06","timezone":"Etc/UTC","filesystem":"<filesystem/>"},"plugins_instructions":false,"skills":{"includeInstructions":true}}}}`;
	enum capturedTurnContext = `{"type":"turn_context","payload":{"turn_id":"CTX","cwd":"/workspace","workspace_roots":["/workspace"],"current_date":"2026-08-06","timezone":"Etc/UTC","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"external-sandbox","network_access":"enabled"},"permission_profile":{"type":"external","network":"enabled"},"model":"gpt-5.6-sol","comp_hash":"3000","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":null,"developer_instructions":null}},"multi_agent_version":"v2","multi_agent_mode":"explicitRequestOnly","realtime_active":false,"summary":"auto"}}`;

	// Codex emits this exact post-terminal token_count envelope before the
	// rollback marker. Explicit null is a known rate_limits state, but omitted,
	// mistyped, and future payload variants remain strict-invalid evidence.
	auto capturedTelemetry = parseRolloutLineEvidence(capturedNullRateLimits, 0);
	assert(capturedTelemetry.eventTelemetryKnown
		&& capturedTelemetry.tokenCountRateLimitsShape
			== CodexTokenCountRateLimitsShape.null_
		&& isExactNativePostTerminalTelemetry(capturedTelemetry,
			CodexNativeTerminalKind.completedSimple)
		&& isExactNativePostTerminalTelemetry(capturedTelemetry,
			CodexNativeTerminalKind.completedCompaction)
		&& !isExactNativePostTerminalTelemetry(capturedTelemetry,
			CodexNativeTerminalKind.interrupted)
		&& !isExactNativePreTerminalTelemetry(capturedTelemetry));
	auto capturedObjectTelemetry = parseRolloutLineEvidence(capturedObjectRateLimits, 0);
	assert(capturedObjectTelemetry.eventTelemetryKnown
		&& capturedObjectTelemetry.tokenCountRateLimitsShape
			== CodexTokenCountRateLimitsShape.object
		&& isExactNativePreTerminalTelemetry(capturedObjectTelemetry)
		&& !isExactNativePostTerminalTelemetry(capturedObjectTelemetry,
			CodexNativeTerminalKind.completedSimple)
		&& isExactNativePostTerminalTelemetry(capturedObjectTelemetry,
			CodexNativeTerminalKind.completedCompaction)
		&& isExactNativePostTerminalTelemetry(capturedObjectTelemetry,
			CodexNativeTerminalKind.interrupted));
	foreach (invalidTelemetry; [
		`{"type":"event_msg","payload":{"type":"token_count","info":{}}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":null}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":{"future":true},"rate_limits":{}}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":` ~ capturedTokenInfo
			~ `,"rate_limits":{}}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":` ~ capturedTokenInfo
			~ `,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null,"future":true}}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":258400},"rate_limits":null}}`,
		`{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":"bad"},"rate_limits":null}}`,
	])
		assert(!parseRolloutLineEvidence(invalidTelemetry, 0).eventTelemetryKnown);

	auto threadSettings = parseRolloutLineEvidence(capturedThreadSettings, 0);
	assert(threadSettings.eventTelemetryKnown
		&& isExactNativePostTerminalTelemetry(threadSettings,
			CodexNativeTerminalKind.completedSimple)
		&& isExactNativePostTerminalTelemetry(threadSettings,
			CodexNativeTerminalKind.completedCompaction)
		&& !isExactNativePostTerminalTelemetry(threadSettings,
			CodexNativeTerminalKind.interrupted));
	foreach (invalidThreadSettings; [
		`{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{}}}`,
		`{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"codex-mini-latest","model_provider_id":"cydo-mock","approval_policy":"never","approvals_reviewer":"user","permission_profile":{"type":"external","network":"enabled","future":true},"cwd":"/workspace","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null}}}}}`,
		`{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"codex-mini-latest","model_provider_id":"cydo-mock","approval_policy":"never","approvals_reviewer":"user","permission_profile":{"type":"external","network":"enabled"},"cwd":"/workspace","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null,"future":true}}}}}`,
		`{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"codex-mini-latest","model_provider_id":"cydo-mock","approval_policy":"never","approvals_reviewer":"user","permission_profile":{"type":"external","network":"enabled"},"cwd":"/workspace","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null}},"model":"codex-mini-latest"}}}`,
	])
		assert(!parseRolloutLineEvidence(invalidThreadSettings, 0).eventTelemetryKnown);

	auto worldState = parseRolloutLineEvidence(capturedWorldState, 0);
	auto turnContext = parseRolloutLineEvidence(capturedTurnContext, 0);
	assert(worldState.contextualPayloadKnown && turnContext.contextualPayloadKnown
		&& turnContext.contextualTurnId == "CTX");
	// Each invalid turn_context is the accepted fixture plus exactly one
	// intended mutation, so it must keep refusing for that reason and not
	// merely because it drifted off the captured per-slug shape.
	auto futureSandboxPolicyTurnContext = capturedTurnContext.replace(
		`"network_access":"enabled"}`, `"network_access":"enabled","future":true}`);
	auto futureCollaborationSettingsTurnContext = capturedTurnContext.replace(
		`"developer_instructions":null}`, `"developer_instructions":null,"future":true}`);
	assert(futureSandboxPolicyTurnContext != capturedTurnContext
		&& futureCollaborationSettingsTurnContext != capturedTurnContext);
	foreach (invalidContextual; [
		`{"type":"world_state","payload":{"full":true,"state":{"future":true}}}`,
		`{"type":"world_state","payload":{"full":true,"state":{"agents_md":{"future":true},"apps_instructions":false,"environments":{"environments":{"local":{"cwd":"/workspace","status":"available","shell":"zsh"}},"current_date":"2026-08-06","timezone":"Etc/UTC","filesystem":"<filesystem/>"},"plugins_instructions":false,"skills":{"includeInstructions":true}}}}`,
		futureSandboxPolicyTurnContext,
		futureCollaborationSettingsTurnContext,
	])
		assert(!parseRolloutLineEvidence(invalidContextual, 0).contextualPayloadKnown);

	// The provider's marker counts [U1,U2,U3,C], including the compaction-only
	// lifecycle. A rollback of two keeps U1/U2, rather than removing two
	// role=user records and accidentally retaining C.
	auto withCompaction = submitted("U1") ~ "\n" ~ submitted("U2") ~ "\n"
		~ submitted("U3") ~ "\n"
		~ started("C") ~ "\n" ~ compactionAssistant ~ "\n" ~ compacted ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"context_compacted"}}` ~ "\n"
		~ complete("C", true)
		~ "\n" ~ rollbackTwo;
	auto scan = scanRollout(withCompaction);
	assert(scan.lines[0].nativeActive && scan.lines[6].nativeActive);
	assert(!scan.lines[12].nativeActive, "U3 must be removed by rollback two");
	assert(!scan.lines[18].nativeActive, "C must be removed by rollback two");
	assert("U1" in scan.nativeLifecycles && "U2" in scan.nativeLifecycles);
	assert(!("U3" in scan.nativeLifecycles) && !("C" in scan.nativeLifecycles));
	assert(!scan.lines[7].active && scan.lines[7].nativeActive,
		"the replay-facing role=user projection remains independent of native liveness");

	// Repeated markers consume the surviving native stack in order.
	auto repeated = scanRollout(withCompaction[0 .. withCompaction.length - rollbackTwo.length]
		~ rollbackOne ~ "\n" ~ rollbackOne);
	assert(repeated.lines[0].nativeActive && repeated.lines[6].nativeActive);
	assert(!repeated.lines[12].nativeActive && !repeated.lines[18].nativeActive);

	// The pinned ordinary and compaction captures put an explicit-null
	// token_count between their terminal lifecycle record and the marker. It is
	// approved telemetry, so the marker retires U2/C and leaves U1 available for
	// the next native undo.
	auto ordinaryAfterRollback = scanRollout(submitted("U1") ~ "\n" ~ submitted("U2")
		~ "\n" ~ capturedNullRateLimits ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(ordinaryAfterRollback.lines[i].nativeActive);
	foreach (i; 6 .. 13)
		assert(!ordinaryAfterRollback.lines[i].nativeActive);
	assert("U1" in ordinaryAfterRollback.nativeLifecycles
		&& !("U2" in ordinaryAfterRollback.nativeLifecycles));

	// Object-valued usage telemetry is captured within a lifecycle, while the
	// complete null form is captured after its terminal. Both variants retain
	// the actual slot they corroborate; swapping their positions leaves U2 live.
	auto ordinaryObjectTelemetry = scanRollout(submitted("U1") ~ "\n"
		~ submittedWithPreTerminalTelemetry("U2", capturedObjectRateLimits) ~ "\n"
		~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(ordinaryObjectTelemetry.lines[i].nativeActive);
	foreach (i; 6 .. ordinaryObjectTelemetry.lines.length - 1)
		assert(!ordinaryObjectTelemetry.lines[i].nativeActive);
	assert("U1" in ordinaryObjectTelemetry.nativeLifecycles
		&& !("U2" in ordinaryObjectTelemetry.nativeLifecycles));

	// The object rate_limits token_count directly before the marker is the
	// recomputation thread/rollback appends alongside it, so U2 keeps its
	// marker slot and the marker retires U2 rather than U1.
	auto objectAfterTerminal = scanRollout(submitted("U1") ~ "\n" ~ submitted("U2")
		~ "\n" ~ capturedObjectRateLimits ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(objectAfterTerminal.lines[i].nativeActive);
	foreach (i; 6 .. objectAfterTerminal.lines.length - 1)
		assert(!objectAfterTerminal.lines[i].nativeActive);
	// One line further from the marker it is ordinary post-terminal telemetry
	// again, which a plainly completed lifecycle still refuses.
	auto objectBeforeMarkerTail = scanRollout(submitted("U1") ~ "\n" ~ submitted("U2")
		~ "\n" ~ capturedObjectRateLimits ~ "\n" ~ capturedNullRateLimits
		~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!objectBeforeMarkerTail.lines[i].nativeActive);
	foreach (i; 6 .. objectBeforeMarkerTail.lines.length - 2)
		assert(objectBeforeMarkerTail.lines[i].nativeActive);
	auto nullBeforeTerminal = scanRollout(submitted("U1") ~ "\n"
		~ submittedWithPreTerminalTelemetry("U2", capturedNullRateLimits) ~ "\n"
		~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!nullBeforeTerminal.lines[i].nativeActive);
	foreach (i; 6 .. nullBeforeTerminal.lines.length - 1)
		assert(nullBeforeTerminal.lines[i].nativeActive);

	auto compactionAfterRollback = scanRollout(submitted("U1") ~ "\n" ~ started("C")
		~ "\n" ~ compactionAssistant ~ "\n"
		~ compactedWithHistory(["U1", "C"]) ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"context_compacted"}}` ~ "\n"
		~ complete("C", true) ~ "\n" ~ capturedNullRateLimits ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(compactionAfterRollback.lines[i].nativeActive);
	foreach (i; 6 .. 12)
		assert(!compactionAfterRollback.lines[i].nativeActive);
	assert("U1" in compactionAfterRollback.nativeLifecycles
		&& !("C" in compactionAfterRollback.nativeLifecycles));

	auto compactionObjectTelemetry = scanRollout(submitted("U1") ~ "\n" ~ started("C")
		~ "\n" ~ compactionAssistant ~ "\n" ~ capturedObjectRateLimits ~ "\n"
		~ compactedWithHistory(["U1", "C"]) ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"context_compacted"}}` ~ "\n"
		~ complete("C", true) ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(compactionObjectTelemetry.lines[i].nativeActive);
	foreach (i; 6 .. compactionObjectTelemetry.lines.length - 1)
		assert(!compactionObjectTelemetry.lines[i].nativeActive);
	assert("U1" in compactionObjectTelemetry.nativeLifecycles
		&& !("C" in compactionObjectTelemetry.nativeLifecycles));

	auto compactionObjectAfterTerminal = scanRollout(submitted("U1") ~ "\n" ~ started("C")
		~ "\n" ~ compactionAssistant ~ "\n" ~ compactedWithHistory(["U1", "C"])
		~ "\n" ~ `{"type":"event_msg","payload":{"type":"context_compacted"}}`
		~ "\n" ~ complete("C", true) ~ "\n" ~ capturedObjectRateLimits ~ "\n"
		~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(compactionObjectAfterTerminal.lines[i].nativeActive);
	foreach (i; 6 .. compactionObjectAfterTerminal.lines.length - 1)
		assert(!compactionObjectAfterTerminal.lines[i].nativeActive);
	assert("U1" in compactionObjectAfterTerminal.nativeLifecycles
		&& !("C" in compactionObjectAfterTerminal.nativeLifecycles));

	// The captured cross-compaction tail has object-valued telemetry after C.
	// A rollback of two therefore retires [U3,C] and leaves U1/U2 for the next
	// native undo; treating all completed terminals like ordinary turns would
	// instead consume U2/U3.
	auto compactionCrossObjectAfterRollback = scanRollout(submitted("U1") ~ "\n"
		~ submitted("U2") ~ "\n" ~ submitted("U3") ~ "\n" ~ started("C")
		~ "\n" ~ compactionAssistant ~ "\n"
		~ compactedWithHistory(["U1", "U2", "U3", "C"]) ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"context_compacted"}}`
		~ "\n" ~ complete("C", true) ~ "\n" ~ capturedObjectRateLimits ~ "\n"
		~ rollbackTwo);
	foreach (i; 0 .. 12)
		assert(compactionCrossObjectAfterRollback.lines[i].nativeActive);
	foreach (i; 12 .. compactionCrossObjectAfterRollback.lines.length - 1)
		assert(!compactionCrossObjectAfterRollback.lines[i].nativeActive);
	assert("U1" in compactionCrossObjectAfterRollback.nativeLifecycles
		&& "U2" in compactionCrossObjectAfterRollback.nativeLifecycles
		&& !("U3" in compactionCrossObjectAfterRollback.nativeLifecycles)
		&& !("C" in compactionCrossObjectAfterRollback.nativeLifecycles));

	string interruptedSubmitted(string turnId, string reason = "interrupted")
	{
		return started(turnId) ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupt prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":`
			~ toJson(turnId) ~ `}}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"interrupt-client","message":"interrupt prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":`
			~ toJson(capturedNativeV1AbortWrapper)
			~ `}],"internal_chat_message_metadata_passthrough":{"turn_id":`
			~ toJson(turnId) ~ `}}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":`
			~ toJson(turnId) ~ `,"reason":` ~ toJson(reason)
			~ `,"completed_at":1,"duration_ms":1}}`;
	}
	// The pinned interrupted rollback places the complete object-valued form
	// after turn_aborted. It retires I, leaving U1 available for the next undo.
	auto interruptedAfterRollback = scanRollout(submitted("U1") ~ "\n"
		~ interruptedSubmitted("I") ~ "\n" ~ capturedObjectRateLimits ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(interruptedAfterRollback.lines[i].nativeActive);
	foreach (i; 6 .. 13)
		assert(!interruptedAfterRollback.lines[i].nativeActive);
	assert("U1" in interruptedAfterRollback.nativeLifecycles
		&& !("I" in interruptedAfterRollback.nativeLifecycles));

	// Explicit-null telemetry belongs to completed terminals, not an
	// interrupted terminal. The marker cannot hide I behind that wrong shape.
	auto interruptedNullAfterRollback = scanRollout(submitted("U1") ~ "\n"
		~ interruptedSubmitted("I") ~ "\n" ~ capturedNullRateLimits ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!interruptedNullAfterRollback.lines[i].nativeActive);
	foreach (i; 6 .. interruptedNullAfterRollback.lines.length - 1)
		assert(interruptedNullAfterRollback.lines[i].nativeActive);

	// A compaction marker slot must corroborate the entire replacement history,
	// not merely its final compaction id. Otherwise the malformed C would hide
	// behind the marker instead of leaving strict evidence live.
	struct MarkerCompactionHistoryCase
	{
		string name;
		string[] replacementTurnIds;
	}
	MarkerCompactionHistoryCase[] markerCompactionHistories = [
		MarkerCompactionHistoryCase("foreign compaction history",
			["foreign-one", "foreign-two", "foreign-three", "C"]),
		MarkerCompactionHistoryCase("duplicate compaction history",
			["U1", "U1", "U3", "C"]),
		MarkerCompactionHistoryCase("missing compaction history", ["U1", "U2", "C"]),
		MarkerCompactionHistoryCase("reordered compaction history", ["U2", "U1", "U3", "C"]),
		MarkerCompactionHistoryCase("extra compaction history",
			["U1", "U2", "U3", "extra", "C"]),
	];
	foreach (ref test; markerCompactionHistories)
	{
		auto malformedHistory = scanRollout(submitted("U1") ~ "\n" ~ submitted("U2")
			~ "\n" ~ submitted("U3") ~ "\n" ~ started("C") ~ "\n"
			~ compactionAssistant ~ "\n" ~ compactedWithHistory(test.replacementTurnIds)
			~ "\n" ~ `{"type":"event_msg","payload":{"type":"context_compacted"}}`
			~ "\n" ~ complete("C", true) ~ "\n" ~ rollbackOne);
		foreach (i; 0 .. 12)
			assert(malformedHistory.lines[i].nativeActive, test.name);
		foreach (i; 12 .. 18)
			assert(!malformedHistory.lines[i].nativeActive, test.name);
		foreach (i; 18 .. 23)
			assert(malformedHistory.lines[i].nativeActive, test.name);
	}

	// A context-only role=user line is part of CTX's task_started segment. It
	// does not form an additional native slot, so one marker removes CTX rather
	// than only the context tail. The historical user view stays unchanged.
	auto contextTail = started("CTX") ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"}}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}],"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"},"id":"agent"}}` ~ "\n"
		~ complete("CTX") ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[SYSTEM: context tail]"}],"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"}}}` ~ "\n"
		~ rollbackOne;
	auto contextScan = scanRollout(contextTail);
	assert(!contextScan.lines[1].nativeActive && !contextScan.lines[6].nativeActive);
	assert(!("CTX" in contextScan.nativeLifecycles));
	assert(contextScan.lines[1].active,
		"the historical user-segment view must not be repurposed for native counts");
	auto repeatedContextTail = contextTail[0 .. $ - rollbackOne.length]
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[SYSTEM: context tail]"}],"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"}}}`
		~ "\n" ~ rollbackOne;
	auto repeatedContextScan = scanRollout(repeatedContextTail);
	assert(repeatedContextScan.lines[1].nativeActive
		&& repeatedContextScan.lines[5].nativeActive
		&& repeatedContextScan.lines[6].nativeActive,
		"repeated contextual tails must remain strict native evidence");

	// A complete U1 remains the one marker slot even when a later orphan or
	// malformed task_started is present. The invalid start stays native-active
	// evidence instead of being hidden with U1 behind the marker.
	auto validU1 = started("U1") ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U1"}}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U1"},"id":"agent"}}` ~ "\n"
		~ complete("U1");
	auto exposedSegment = scanRollout(validU1);
	assert(exposedSegment.nativeSegments.length == 1
		&& exposedSegment.nativeSegments[0].start == 0
		&& exposedSegment.nativeSegments[0].end == 6
		&& exposedSegment.nativeSegments[0].turnId == "U1");
	// task_started's mode is a pinned discriminant, not arbitrary string data.
	// An empty or future value makes U2 strict live evidence while the marker
	// still retires the only corroborated U1 slot.
	foreach (mode; ["", "future"])
	{
		auto unsupportedMode = submitted("U2").replace(
			`"collaboration_mode_kind":"default"`,
			`"collaboration_mode_kind":` ~ toJson(mode));
		auto modeScan = scanRollout(validU1 ~ "\n" ~ unsupportedMode ~ "\n" ~ rollbackOne);
		foreach (i; 0 .. 6)
			assert(!modeScan.lines[i].nativeActive);
		foreach (i; 6 .. modeScan.lines.length - 1)
			assert(modeScan.lines[i].nativeActive);
	}
	string submittedWithProjection(scope const string[] records, string terminal = null)
	{
		if (terminal is null)
			terminal = complete("U2");
		string result = started("U2") ~ "\n"
			~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U2"}}}` ~ "\n"
			~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`;
		foreach (record; records)
			result ~= "\n" ~ record;
		return result ~ "\n" ~ terminal;
	}
	string nativeAgent()
	{
		return `{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}`;
	}
	string nativeAssistant(bool futureMetadata = false)
	{
		return `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U2"`
			~ (futureMetadata ? `,"future":true` : "")
			~ `},"id":"agent-U2"}}`;
	}
	void assertInvalidSubmittedMarkerProjection(string name, string submittedU2)
	{
		auto invalidProjection = scanRollout(validU1 ~ "\n" ~ submittedU2 ~ "\n" ~ rollbackOne);
		foreach (i; 0 .. 6)
			assert(!invalidProjection.lines[i].nativeActive, name);
		foreach (i; 6 .. invalidProjection.lines.length - 1)
			assert(invalidProjection.lines[i].nativeActive, name);
	}

	// A marker can retire a submitted lifecycle only when every pre-terminal
	// physical record belongs to its exact simple projection. Otherwise the
	// invalid U2 range remains live rather than hiding it behind the marker.
	struct InvalidSubmittedMarkerProjectionCase
	{
		string name;
		string rollout;
	}
	InvalidSubmittedMarkerProjectionCase[] invalidSubmittedMarkerProjections = [
		InvalidSubmittedMarkerProjectionCase("function-call response item", submittedWithProjection([
			`{"type":"response_item","payload":{"type":"function_call","id":"call","name":"future"}}`,
			nativeAgent(), nativeAssistant(),
		])),
		InvalidSubmittedMarkerProjectionCase("malformed agent event", submittedWithProjection([
			`{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null}}`,
			nativeAssistant(),
		])),
		InvalidSubmittedMarkerProjectionCase("unknown top-level record", submittedWithProjection([
			`{"type":"future_rollout_record","payload":{}}`, nativeAgent(), nativeAssistant(),
		])),
		InvalidSubmittedMarkerProjectionCase("blank physical line", submittedWithProjection([
			"", nativeAgent(), nativeAssistant(),
		])),
		InvalidSubmittedMarkerProjectionCase("future assistant metadata", submittedWithProjection([
			nativeAgent(), nativeAssistant(true),
		])),
		InvalidSubmittedMarkerProjectionCase("duplicate adjacent user event", submittedWithProjection([
			`{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`,
			nativeAgent(), nativeAssistant(),
		])),
	];
	foreach (ref test; invalidSubmittedMarkerProjections)
		assertInvalidSubmittedMarkerProjection(test.name, test.rollout);
	assertInvalidSubmittedMarkerProjection("terminal message mismatch", submittedWithProjection([
		nativeAgent(), nativeAssistant(),
	], completeWithLastAgentMessage("U2", "different answer")));
	assertInvalidSubmittedMarkerProjection("terminal message explicit null", submittedWithProjection([
		nativeAgent(), nativeAssistant(),
	], complete("U2", true)));
	foreach (reason; ["other", "cancelled", "", "Interrupted", "interrupted "])
		assertInvalidSubmittedMarkerProjection("non-interrupted terminal reason " ~ reason,
			interruptedSubmitted("U2", reason));
	auto assistantBeforeCaller = joinParts([
		started("U2"), nativeAssistant(),
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U2"}}}`,
		`{"type":"event_msg","payload":{"type":"user_message","client_id":"client","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`,
		nativeAgent(), complete("U2"),
	]);
	assertInvalidSubmittedMarkerProjection("assistant before caller", assistantBeforeCaller);
	auto orphanStart = scanRollout(validU1 ~ "\n" ~ started("orphan") ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!orphanStart.lines[i].nativeActive);
	assert(orphanStart.lines[6].nativeActive && !orphanStart.lines[7].nativeActive);
	auto malformedStart = scanRollout(validU1 ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!malformedStart.lines[i].nativeActive);
	assert(malformedStart.lines[6].nativeActive && !malformedStart.lines[7].nativeActive);

	// An assistant-only completed range has no submitted-user or compaction
	// projection, so it cannot hide U1 from the marker.
	auto assistantOnly = scanRollout(validU1 ~ "\n" ~ started("phantom") ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"phantom"}],"internal_chat_message_metadata_passthrough":{"turn_id":"phantom"},"id":"phantom-agent"}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"agent_message","message":"phantom","phase":null,"memory_citation":null}}` ~ "\n"
		~ complete("phantom") ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!assistantOnly.lines[i].nativeActive);
	foreach (i; 6 .. 10)
		assert(assistantOnly.lines[i].nativeActive);

	// A caller/event pair after task_complete is strict lifecycle evidence, not
	// a materialized turn that can consume U1's rollback slot.
	auto postTerminalCaller = scanRollout(validU1 ~ "\n" ~ started("phantom") ~ "\n"
		~ complete("phantom") ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"late prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"phantom"}}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"user_message","client_id":"late-client","message":"late prompt","images":[],"local_images":[],"text_elements":[]}}` ~ "\n"
		~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!postTerminalCaller.lines[i].nativeActive);
	foreach (i; 6 .. 10)
		assert(postTerminalCaller.lines[i].nativeActive);

	// Compaction occupies a native slot only in its captured physical order:
	// assistant response, compacted record, context_compacted, terminal.
	auto misorderedCompaction = scanRollout(validU1 ~ "\n" ~ started("C") ~ "\n"
		~ compacted ~ "\n" ~ compactionAssistant ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"context_compacted"}}` ~ "\n"
		~ complete("C", true) ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 6)
		assert(!misorderedCompaction.lines[i].nativeActive);
	foreach (i; 6 .. 11)
		assert(misorderedCompaction.lines[i].nativeActive);

	// A repeated complete lifecycle ID cannot identify one provider slot. Keep
	// both ranges live so the native admission path observes the ambiguity.
	auto duplicateTurnId = scanRollout(validU1 ~ "\n" ~ submitted("U1") ~ "\n" ~ rollbackOne);
	foreach (i; 0 .. 12)
		assert(duplicateTurnId.lines[i].nativeActive);
	auto duplicateLifecycle = "U1" in duplicateTurnId.nativeLifecycles;
	assert(duplicateLifecycle !is null && duplicateLifecycle.starts == 2
		&& duplicateLifecycle.completes == 2);
}
