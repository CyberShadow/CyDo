module cydo.workflow.sessions.yield_gates;

import cydo.domain.tasks.yield_gate : NaggedYieldGates, YieldGate;

struct YieldGateFinding
{
	YieldGate gate;
	string detail;

	bool found() const
	{
		return detail !is null;
	}
}

YieldGateFinding checkYieldGates(int tid,
	YieldGateFinding delegate(int tid) checkOutputs)
{
	return checkOutputs(tid);
}

bool shouldRetryYieldGate(NaggedYieldGates nagged, YieldGateFinding finding)
{
	return finding.found && !nagged.contains(finding.gate);
}
