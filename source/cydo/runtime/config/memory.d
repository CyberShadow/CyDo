module cydo.runtime.config.memory;

import configy.attributes : ConfigParser, Optional, SetInfo;
import cydo.runtime.config : CydoConfig;

struct MemorySize
{
	private enum Kind { bytes, percent, infinity }
	private Kind kind;
	private ulong amount;

	static MemorySize fromYAML(scope ConfigParser!MemorySize parser)
	{
		import dyaml.node : NodeType;
		import std.exception : enforce;

		switch (parser.node.type)
		{
			case NodeType.integer:
				auto bytes = parser.node.as!long;
				enforce(bytes >= 0 && cast(ulong) bytes <= maxFiniteBytes(),
					"Memory byte count is out of range");
				return MemorySize(Kind.bytes, cast(ulong) bytes);
			case NodeType.string:
				return fromString(parser.node.as!string);
			default:
				throw new Exception("Expected a memory size string or integer byte count");
		}
	}

	static MemorySize fromString(string value)
	{
		import std.algorithm : all;
		import std.conv : to;
		import std.exception : enforce;

		if (value == "infinity")
			return MemorySize(Kind.infinity, 0);

		auto digits = value;
		ulong multiplier = 1;
		auto kind = Kind.bytes;
		if (digits.length)
		{
			switch (digits[$ - 1])
			{
				case 'K': multiplier = 1UL << 10; break;
				case 'M': multiplier = 1UL << 20; break;
				case 'G': multiplier = 1UL << 30; break;
				case 'T': multiplier = 1UL << 40; break;
				case '%': kind = Kind.percent; break;
				default: break;
			}
			if (multiplier != 1 || kind == Kind.percent)
				digits = digits[0 .. $ - 1];
		}

		auto diagnostic = "Invalid memory size: " ~ value;
		enforce(digits.length && digits.all!(c => c >= '0' && c <= '9'), diagnostic);
		auto amount = digits.to!ulong;
		auto limit = kind == Kind.percent ? 100 : maxFiniteBytes() / multiplier;
		enforce(amount <= limit, diagnostic);
		return MemorySize(kind, amount * multiplier);
	}

	private static ulong maxFiniteBytes()
	{
		version (linux)
		{
			import core.stdc.config : c_long;
			import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;

			// Linux clamps memory limits at PAGE_COUNTER_MAX, where it reports "max".
			auto pageSize = sysconf(_SC_PAGESIZE);
			assert(pageSize > 0);
			static if (c_long.sizeof == 4)
				return cast(ulong) c_long.max * pageSize - 1;
			else
				return cast(ulong) (c_long.max / pageSize * pageSize) - 1;
		}
		else
			return ulong.max - 1;
	}

	string toSystemd() const
	{
		import std.conv : to;

		final switch (kind)
		{
			case Kind.bytes: return amount.to!string;
			case Kind.percent: return amount.to!string ~ "%";
			case Kind.infinity: return "infinity";
		}
	}
}

struct MemoryLimitsConfig
{
	@Optional SetInfo!MemorySize max;
	@Optional SetInfo!MemorySize high;
	@Optional SetInfo!MemorySize swap_max;

	void validate(string path) const
	{
		import std.exception : enforce;

		if (max.set)
			enforce(max.value.kind == MemorySize.Kind.infinity || max.value.amount > 0,
				path ~ ".max must be greater than zero");
		if (high.set)
			enforce(high.value.kind == MemorySize.Kind.infinity || high.value.amount > 0,
				path ~ ".high must be greater than zero");
	}

	bool anySet() const
	{
		return max.set || high.set || swap_max.set;
	}
}

bool memoryLimitingInUse(const ref CydoConfig config)
{
	if (config.total_agent_memory.anySet() || config.sandbox.memory.anySet())
		return true;
	foreach (ref agent; config.agents)
		if (agent.sandbox.memory.anySet())
			return true;
	foreach (ref workspace; config.workspaces)
		if (workspace.sandbox.memory.anySet())
			return true;
	return false;
}

unittest // Each configuration layer can enable memory limiting on its own.
{
	import cydo.runtime.config : AgentConfig, WorkspaceConfig;

	CydoConfig empty;
	assert(!memoryLimitingInUse(empty));
	auto limit = SetInfo!MemorySize(MemorySize.fromString("infinity"), true);

	CydoConfig total;
	total.total_agent_memory.max = limit;
	assert(memoryLimitingInUse(total));

	CydoConfig globalSandbox;
	globalSandbox.sandbox.memory.max = limit;
	assert(memoryLimitingInUse(globalSandbox));

	CydoConfig agent;
	agent.agents["claude"] = AgentConfig.init;
	agent.agents["claude"].sandbox.memory.high = limit;
	assert(memoryLimitingInUse(agent));

	CydoConfig workspace;
	workspace.workspaces = [WorkspaceConfig.init];
	workspace.workspaces[0].sandbox.memory.swap_max = limit;
	assert(memoryLimitingInUse(workspace));
}

unittest // Memory sizes render in systemd's canonical form.
{
	foreach (input, expected; [
		"8G": "8589934592", "512M": "536870912", "1024K": "1048576",
		"1T": "1099511627776", "1073741824": "1073741824", "0": "0",
		"0%": "0%", "50%": "50%", "infinity": "infinity",
	])
		assert(MemorySize.fromString(input).toSystemd() == expected, input);
}

unittest // Invalid units, syntax, percentages, and overflow are rejected.
{
	import std.exception : assertThrown;

	foreach (input; ["8GB", "8g", "1.5G", "-1", "150%", "+1", "0x10", "1e3", "abc", "", "99999999999999T",
		"18446744073709551615", "16777216T"])
		assertThrown(MemorySize.fromString(input), "Accepted invalid memory size: " ~ input);
}

version (linux) unittest // Numeric caps must stay below the kernel's unlimited value.
{
	import std.conv : to;
	import std.exception : assertThrown;

	auto largest = MemorySize.maxFiniteBytes();
	assert(MemorySize.fromString(largest.to!string).toSystemd() == largest.to!string);
	assertThrown(MemorySize.fromString((largest + 1).to!string));
	assertThrown(MemorySize.fromString("8388608T"));
}
