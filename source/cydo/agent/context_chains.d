/// What a transcript reader needs to know to place the context records an
/// agent's harness adds around a turn: each record chains to the one before
/// it, and the chain starts at the record the context came with, which is
/// either a prompt (the context goes with that message) or something else,
/// typically a tool result (the context arrived mid-turn).
module cydo.agent.context_chains;

struct ContextChains
{
	/// attachment record uuid -> the uuid of its chain's first record
	string[string] rootOf;
	/// uuids of the prompt records seen (user records that are not tool
	/// results); a chain rooted elsewhere is mid-turn context
	bool[string] promptRecords;
}
