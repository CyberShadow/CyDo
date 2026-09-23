module cydo.domain.tasks.yield_gate;

enum YieldGate : uint
{
	outputs = 1,
	diskCleanup = 2,
}

struct NaggedYieldGates
{
	uint bits;

	bool contains(YieldGate gate) const
	{
		return (bits & gate) != 0;
	}

	void mark(YieldGate gate)
	{
		bits |= gate;
	}
}
