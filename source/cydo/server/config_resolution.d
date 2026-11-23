module cydo.server.config_resolution;

import configy.attributes : SetInfo;

import std.conv : to;
import std.typecons : Nullable;

import cydo.agent.resolver : effectiveDefaultAgentName, isConfiguredAgentName;
import cydo.agent.drivers.registry : agentRegistry;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, effectiveDriver, loadConfig, reloadConfig;

void resolveConfig(ref CydoConfig config)
{
	// Pass 1: infer driver from the AA key when it matches a known driver name
	foreach (name, ref ac; config.agents)
	{
		if (!ac.driver.set)
		{
			auto driver = effectiveDriver(name, ac);
			if (driver.isNull)
				throw new Exception(
					"agents['" ~ name ~ "']: driver field is required (not a known driver name)");
			ac.driver = SetInfo!AgentDriver(driver.get, true);
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

	if (config.default_agent.length > 0)
	{
		if (!isConfiguredAgentName(config, config.default_agent))
			throw new Exception("default_agent references unknown configured agent: "
				~ config.default_agent);
	}
	else
		config.default_agent = effectiveDefaultAgentName(config);
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
	assert(config.default_agent == "claude");
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
	assert(config.default_agent == "work-claude");
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

unittest
{
	CydoConfig config;
	AgentConfig workClaude;
	workClaude.driver = typeof(workClaude.driver)(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;
	config.default_agent = "claude";

	try
	{
		resolveConfig(config);
		assert(false, "expected resolveConfig to throw");
	}
	catch (Exception e)
		assert(e.msg == "default_agent references unknown configured agent: claude");
}

unittest
{
	CydoConfig config;
	AgentConfig workClaude;
	workClaude.driver = typeof(workClaude.driver)(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;
	AgentConfig reviewClaude;
	reviewClaude.driver = typeof(reviewClaude.driver)(AgentDriver.claude, true);
	config.agents["review-claude"] = reviewClaude;

	try
	{
		resolveConfig(config);
		assert(false, "expected resolveConfig to throw");
	}
	catch (Exception e)
		assert(e.msg == "Multiple Claude-configured agents exist; set default_agent explicitly");
}

// 27. End-to-end: parse → resolveConfig → createAgentByDriver → setModelAliases →
// resolveModelSpec, for both a configured and an unconfigured model_class.
unittest
{
	import cydo.runtime.config.yaml : parseYamlConfigString;
	import cydo.agent.resolver : createAgentByDriver, resolveConfiguredAgent;

	auto yaml = "workspaces:\n  local:\n    root: /tmp\n"
		~ "agents:\n  claude:\n    model_aliases:\n      large:\n        model: custom-model\n        effort: high\n";
	auto config = parseYamlConfigString!CydoConfig(yaml, "/dev/null");
	resolveConfig(config);

	auto resolved = resolveConfiguredAgent(config, "claude");
	auto agent = createAgentByDriver(resolved.driver);
	agent.setModelAliases(resolved.config.model_aliases);

	auto configured = agent.resolveModelSpec("large");
	assert(configured.model == "custom-model");
	assert(configured.effort == "high");

	auto unconfigured = agent.resolveModelSpec("medium");
	assert(unconfigured.model == "sonnet");
	assert(unconfigured.effort == "");
}
