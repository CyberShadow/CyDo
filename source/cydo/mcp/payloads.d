module cydo.mcp.payloads;

import ae.utils.json : JSONFragment;

/// Structured result returned to the parent agent as JSON via MCP.
struct TaskResult
{
	import ae.utils.json : JSONOptional;

	string summary;                   // agent's final message (one-sentence summary)
	@JSONOptional string output_file; // path to output artifact, if any
	@JSONOptional string worktree;    // path to worktree, if any
	@JSONOptional string note;        // contextual guidance for the parent agent
	@JSONOptional string error;       // canonical per-task error message
	@JSONOptional int tid;            // child task ID for follow-up via Ask
	@JSONOptional int qid;            // reserved for compatibility; QuestionResult carries qid for questions
	@JSONOptional string[] commits;   // commit SHAs from worktree (for commit output type)
	string status = "success";
}

struct McpContentItem
{
	string type;
	string text;
}

struct McpContentResult
{
	import ae.utils.json : JSONOptional;

	McpContentItem[] content;
	bool isError;
	@JSONOptional JSONFragment structuredContent;
}
