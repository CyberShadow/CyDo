module cydo.domain.tasks.yield_gate;

enum YieldGate : uint
{
	outputs = 1,
	diskCleanup = 2,
	worktreeBranch = 4,
}

enum uint supportedYieldGateMask = cast(uint) YieldGate.outputs | cast(uint) YieldGate.diskCleanup
	| cast(uint) YieldGate.worktreeBranch;

struct NaggedYieldGates
{
	uint bits;

	static NaggedYieldGates fromStored(long value)
	{
		import std.exception : enforce;

		enforce(value >= 0 && (value & ~cast(long) supportedYieldGateMask) == 0,
			"Invalid persisted yield gate mask");
		return NaggedYieldGates(cast(uint) value);
	}

	bool contains(YieldGate gate) const
	{
		return (bits & gate) != 0;
	}

	void mark(YieldGate gate)
	{
		bits |= gate;
	}
}
