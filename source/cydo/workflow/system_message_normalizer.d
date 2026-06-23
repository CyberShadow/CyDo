module cydo.workflow.system_message_normalizer;

import std.logger : warningf;

import ae.utils.json : JSONOptional, toJson;

import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, byName;
import cydo.foundation.system.framing : CompiledTemplate, ParsedSystemFraming,
	compileTemplate, stripTaskSystemPromptWrapper, tryExtractSubject,
	tryMatchTemplate, tryParseSystemFraming;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	KnownSystemMessageMatch, systemMessageSubject, tryKnownSystemMessageMatch;
import cydo.workflow.history.abbrev : extractMessageText;

package(cydo):

struct SystemMessageNormalizerHost
{
	string delegate() systemKeyword;
	string delegate(int tid) projectPathForTask;
	TaskTypeDef[] delegate(string projectPath) taskTypesForProject;
	UserEntryPointDef[] delegate(string projectPath) entryPointsForProject;
	string delegate(string templateName, string projectPath) loadTemplateText;
}

string buildCydoMeta(string label, string[string] vars = null,
	string bodyVar = null, bool bodyMarkdown = false, string severity = null)
{
	struct CydoMeta
	{
		string label;
		@JSONOptional string[string] vars;
		@JSONOptional string bodyVar;
		@JSONOptional bool bodyMarkdown;
		@JSONOptional string severity;
	}

	CydoMeta meta;
	meta.label = label;
	meta.vars = vars;
	meta.bodyVar = bodyVar;
	meta.bodyMarkdown = bodyMarkdown;
	meta.severity = severity;
	return toJson(meta);
}

class SystemMessageNormalizer
{
private:
	SystemMessageNormalizerHost host_;
	CompiledTemplate[string] compiledTemplateCache_;

public:
	this(SystemMessageNormalizerHost host)
	{
		host_ = host;
	}

	string buildKnownSystemMessageMeta(KnownSystemMessageKind kind,
		string subject = null, string[string] vars = null, string bodyVar = null)
	{
		auto resolvedSubject = subject.length > 0 ? subject : systemMessageSubject(kind);
		KnownSystemMessageMatch match;
		auto label = tryKnownSystemMessageMatch(resolvedSubject, match)
			? match.label
			: resolvedSubject;
		return buildCydoMeta(label, vars, bodyVar, bodyMarkdownForKind(kind));
	}

	string normalizeKnownSystemMessageMeta(string translated, int tid = -1)
	{
		import std.algorithm : canFind;

		if (translated.length == 0
			|| translated.canFind(`"meta":`)
			|| !translated.canFind(`"type":"item/started"`)
			|| !translated.canFind(`"item_type":"user_message"`))
			return translated;

		string subject;
		auto text = extractMessageText(translated);
		if (!tryExtractSystemMessageSubject(text, subject))
			return translated;

		auto meta = cydoMetaForKnownSystemSubject(tid, subject, text);
		if (meta.length == 0)
			return translated;
		return translated[0 .. $ - 1] ~ `,"meta":` ~ meta ~ `}`;
	}

private:
	bool tryExtractSystemMessageSubject(string text, out string subject)
	{
		return tryExtractSubject(host_.systemKeyword(), text, subject);
	}

	/// Return the template variable name that holds the body content for a given
	/// kind, or null if the kind produces label-only meta.
	static string bodyVarForKind(KnownSystemMessageKind kind)
	{
		switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
		case KnownSystemMessageKind.sessionStart:
		case KnownSystemMessageKind.handoff:
			return "task_description";
		case KnownSystemMessageKind.followUpFromParent:
		case KnownSystemMessageKind.questionFromTask:
			return "message";
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "question";
		default:
			return null;
		}
	}

	/// Whether the body of a known-system-message of this kind should be rendered
	/// as Markdown.
	///
	/// Rule: Markdown for content originating from an LLM/agent or a .md prompt
	/// file; plain text for content typed by the user. `sessionStart` is the only
	/// kind whose body is user-typed (the user's first message wrapped into a
	/// session-start system message); everything else carries agent-generated content.
	static bool bodyMarkdownForKind(KnownSystemMessageKind kind)
	{
		final switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
		case KnownSystemMessageKind.followUpFromParent:
		case KnownSystemMessageKind.questionFromTask:
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
		case KnownSystemMessageKind.handoff:
			return true;
		case KnownSystemMessageKind.sessionStart:
			return false;
		case KnownSystemMessageKind.missingRequiredOutputs:
		case KnownSystemMessageKind.subTaskResults:
		case KnownSystemMessageKind.restartNudge:
		case KnownSystemMessageKind.postCompactionTaskModeReminder:
		case KnownSystemMessageKind.modeSwitch:
			return false;
		}
	}

	/// Resolve (sourceType, edgeName) → prompt-template path using the same
	/// project-scoped task-type config the renderer used.
	/// Returns null when the edge can't be resolved (renamed/removed/legacy).
	string resolveEdgePromptTemplate(string projectPath, KnownSystemMessageKind kind,
		string sourceType, string edgeName)
	{
		switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
			if (sourceType.length == 0 || edgeName.length == 0)
				return null;
			auto parentDef = host_.taskTypesForProject(projectPath).byName(sourceType);
			if (parentDef is null)
				return null;
			auto edge = parentDef.creatable_tasks.byName(edgeName);
			return edge !is null ? edge.prompt_template : null;

		case KnownSystemMessageKind.sessionStart:
			if (edgeName.length == 0)
				return null;
			auto ep = host_.entryPointsForProject(projectPath).byName(edgeName);
			return ep !is null ? ep.prompt_template : null;

		case KnownSystemMessageKind.handoff:
		case KnownSystemMessageKind.modeSwitch:
			if (sourceType.length == 0 || edgeName.length == 0)
				return null;
			auto srcDef = host_.taskTypesForProject(projectPath).byName(sourceType);
			if (srcDef is null)
				return null;
			if (edgeName == "on_yield")
				return srcDef.on_yield.prompt_template;
			if (auto contP = edgeName in srcDef.continuations)
				return contP.prompt_template;
			return null;

		case KnownSystemMessageKind.followUpFromParent:
			return "prompts/follow_up_from_parent.md";

		case KnownSystemMessageKind.questionFromTask:
			return "prompts/question_from_task.md";

		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "prompts/sub_task_waiting_for_answer.md";

		default:
			return null;
		}
	}

	/// Reverse-extract meta from a known-system-message user event by matching
	/// the rendered body against the template that produced it.
	/// tid is used to look up the project path for template resolution.
	string cydoMetaForKnownSystemSubject(int tid, string subject, string text)
	{
		KnownSystemMessageMatch match;
		if (!tryKnownSystemMessageMatch(subject, match))
			return null;

		auto bodyVar = bodyVarForKind(match.kind);
		if (bodyVar is null)
			return buildCydoMeta(match.label);

		ParsedSystemFraming framing;
		if (!tryParseSystemFraming(host_.systemKeyword(), text, framing))
			return buildCydoMeta(match.label);

		auto inner = stripTaskSystemPromptWrapper(framing.body);

		auto projectPath = host_.projectPathForTask(tid);
		auto templatePath = resolveEdgePromptTemplate(projectPath, match.kind,
			match.sourceType, match.edgeName);
		if (templatePath.length == 0)
			return buildCydoMeta(match.label);

		auto templateText = host_.loadTemplateText(templatePath, projectPath);
		if (templateText.length == 0)
		{
			warningf("template '%s' not found on prompt search path; falling back to label-only meta",
				templatePath);
			return buildCydoMeta(match.label);
		}

		if (templateText !in compiledTemplateCache_)
			compiledTemplateCache_[templateText] = compileTemplate(templateText);
		auto compiled = compiledTemplateCache_[templateText];

		string[string] vars;
		if (!tryMatchTemplate(compiled, inner, vars))
			return buildCydoMeta(match.label);

		string[string] bodyVars;
		if (auto value = bodyVar in vars)
			bodyVars[bodyVar] = *value;

		return buildCydoMeta(match.label, bodyVars, bodyVar,
			bodyMarkdownForKind(match.kind));
	}
}
