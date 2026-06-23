module cydo.runtime.config_resolution;

import configy.attributes : SetInfo;

import std.conv : to;
import std.typecons : Nullable;

import cydo.agent.drivers.registry : agentRegistry;
import cydo.config : AgentConfig, AgentDriver, CydoConfig, loadConfig, reloadConfig;

void resolveConfig(ref CydoConfig config)
{
	// Pass 1: infer driver from the AA key when it matches a known driver name
	foreach (name, ref ac; config.agents)
	{
		if (!ac.driver.set)
		{
			try
				ac.driver = SetInfo!AgentDriver(to!AgentDriver(name), true);
			catch (Exception e)
				throw new Exception(
					"agents['" ~ name ~ "']: driver field is required (not a known driver name)");
		}
	}

	// Pass 2: synthesize default entries for any driver not yet covered
	foreach (reg; agentRegistry)
	{
		auto driverEnum = to!AgentDriver(reg.name);
		bool covered = false;
		foreach (name, ref ac; config.agents)
		{
			if (name == reg.name) { covered = true; break; }
			if (ac.driver.set && ac.driver.value == driverEnum) { covered = true; break; }
		}
		if (!covered)
		{
			AgentConfig synthesized;
			synthesized.driver = SetInfo!AgentDriver(driverEnum, true);
			config.agents[reg.name] = synthesized;
		}
	}
}

CydoConfig loadRuntimeConfig()
{
	auto config = loadConfig();
	resolveConfig(config);
	return config;
}

Nullable!CydoConfig reloadRuntimeConfig()
{
	auto result = reloadConfig();
	if (!result.isNull())
	{
		auto config = result.get();
		resolveConfig(config);
		result = Nullable!CydoConfig(config);
	}
	return result;
}

unittest
{
	CydoConfig config;
	resolveConfig(config);
	assert(config.agents.length == agentRegistry.length);
	foreach (ref reg; agentRegistry)
	{
		assert((reg.name in config.agents) !is null);
		assert(config.agents[reg.name].driver.set);
		assert(config.agents[reg.name].driver.value == to!AgentDriver(reg.name));
	}
}

unittest
{
	CydoConfig config;
	config.agents["work-claude"] = AgentConfig.init;
	config.agents["work-claude"].driver = SetInfo!AgentDriver(AgentDriver.claude, true);

	resolveConfig(config);

	assert(("work-claude" in config.agents) !is null);
	assert(("claude" in config.agents) is null);
	assert(config.agents.length == agentRegistry.length);
	assert(config.agents["work-claude"].driver.value == AgentDriver.claude);
	assert(config.agents["codex"].driver.value == AgentDriver.codex);
	assert(config.agents["copilot"].driver.value == AgentDriver.copilot);
}

unittest
{
	CydoConfig config;
	config.agents["codex"] = AgentConfig.init;

	resolveConfig(config);

	assert(config.agents["codex"].driver.set);
	assert(config.agents["codex"].driver.value == AgentDriver.codex);
}

unittest
{
	CydoConfig config;
	config.agents["custom"] = AgentConfig.init;

	try
	{
		resolveConfig(config);
		assert(false, "expected resolveConfig to throw");
	}
	catch (Exception e)
		assert(e.msg == "agents['custom']: driver field is required (not a known driver name)");
}
