module cydo.main_test;

import cydo.cli.initialize : configTemplate, taskTypesTemplate;
import cydo.runtime.config.paths : configPath, userTaskTypesPath;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : SpanMode, chdir, dirEntries, exists, getcwd, mkdirRecurse,
	read, rmdirRecurse, tempDir;
import std.path : buildPath, isAbsolute, relativePath;
import std.process : Config, environment, execute;

private string cydoCli()
{
	auto executable = environment.get("CYDO_TEST_CYDO_BIN", "");
	assert(isAbsolute(executable) && exists(executable),
		"CYDO_TEST_CYDO_BIN must name an existing absolute path. "
		~ "Run nix develop -ic dub build and set CYDO_TEST_CYDO_BIN=$PWD/build/cydo.");
	return executable;
}

private typeof(execute(["true"])) runCydo(string[] arguments)
{
	auto command = ["bash", "-c", "exec \"$1\" \"${@:2}\" 2>&1", "cydo", cydoCli()];
	command ~= arguments;
	return execute(command);
}

private typeof(execute(["true"])) runCydoWithoutAuth(string listenAddress)
{
	auto env = environment.toAA();
	env["CYDO_AUTH_PASS"] = "";
	env["CYDO_LISTEN_ADDRESS"] = listenAddress;
	env.remove("CYDO_AUTH_USER");
	env.remove("CYDO_LISTEN_SOCKET");
	return execute(["timeout", "30", "bash", "-c", "exec \"$1\" 2>&1", "cydo", cydoCli()],
		env, Config.newEnv);
}

private void withInitCliFixture(string name, void delegate(string root) body)
{
	auto root = buildPath(tempDir(), name);
	if (exists(root))
		rmdirRecurse(root);
	mkdirRecurse(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);

	auto originalCwd = getcwd();
	scope (exit) chdir(originalCwd);
	auto cwd = buildPath(root, "cwd");
	mkdirRecurse(cwd);
	chdir(cwd);

	enum profileVariables = ["HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
		"COPILOT_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME"];
	string[string] originalValues;
	bool[string] originallyPresent;
	foreach (variable; profileVariables)
	{
		originallyPresent[variable] = variable in environment;
		if (originallyPresent[variable])
			originalValues[variable] = environment[variable];
	}
	scope (exit)
		foreach (variable; profileVariables)
			if (originallyPresent[variable])
				environment[variable] = originalValues[variable];
			else
				environment.remove(variable);

	environment["HOME"] = root;
	environment["XDG_RUNTIME_DIR"] = buildPath(root, "runtime");
	environment["XDG_DATA_HOME"] = buildPath(root, "data-home");
	foreach (variable; profileVariables[1 .. 4])
		environment.remove(variable);
	body(root);
}

private void assertFixtureContents(string root, string[] expected)
{
	string[] entries;
	foreach (entry; dirEntries(root, SpanMode.depth))
		entries ~= relativePath(entry.name, root);
	entries.sort;
	assert(entries == expected, "Unexpected fixture contents: " ~ entries.to!string);
}

unittest // The server refuses unauthenticated non-loopback TCP binds before opening the database.
{
	foreach (address; ["*", "0.0.0.0"])
	{
		withInitCliFixture("cydo-main-unauthenticated-bind", (string root)
		{
			auto result = runCydoWithoutAuth(address);
			assert(result.status != 0 && result.status != 124, result.output);
			assert(result.output.canFind("CYDO_LISTEN_ADDRESS is '" ~ address ~ "'")
				&& result.output.canFind("CYDO_AUTH_PASS"), result.output);
			assert(!exists(buildPath(root, "data-home", "cydo", "cydo.db")), result.output);
		});
	}
}

unittest // Actual Program/FunOpt root help documents init.
{
	withInitCliFixture("cydo-main-init-cli-root-help", (string root)
	{
		auto result = runCydo(["--help"]);
		assert(result.status == 0, result.output);
		assert(result.output.canFind("init") && result.output.canFind("Install documented"));
		assertFixtureContents(root, ["cwd"]);
	});
}

unittest // Actual init dispatch writes its canonical pair.
{
	withInitCliFixture("cydo-main-init-cli-success", (string root)
	{
		auto result = runCydo(["init"]);
		assert(result.status == 0, result.output);
		assertFixtureContents(root, [".config", ".config/cydo", ".config/cydo/config.yaml",
			".config/cydo/task-types.yaml", "cwd"]);
		assert(cast(string) read(configPath()) == configTemplate);
		assert(cast(string) read(userTaskTypesPath()) == taskTypesTemplate);
	});
}

unittest // Action help and rejected arguments leave the fixture untouched.
{
	withInitCliFixture("cydo-main-init-cli-no-side-effects", (string root)
	{
		auto help = runCydo(["init", "--help"]);
		assert(help.status == 0, help.output);
		assert(help.output.canFind("Usage: cydo init")
			&& help.output.canFind("Install documented user configuration templates."), help.output);
		assertFixtureContents(root, ["cwd"]);

		auto option = runCydo(["init", "--unknown"]);
		assert(option.status != 0 && option.output.canFind("Unrecognized option"), option.output);
		assertFixtureContents(root, ["cwd"]);

		auto positional = runCydo(["init", "unexpected"]);
		assert(positional.status != 0 && positional.output.canFind("Extra parameters"), positional.output);
		assertFixtureContents(root, ["cwd"]);
	});
}

unittest // Init rejects invalid native history profile overrides before writing.
{
	withInitCliFixture("cydo-main-init-cli-invalid-profiles", (string root)
	{
		foreach (name; ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME"])
		{
			environment[name] = "";
			auto empty = runCydo(["init"]);
			assert(empty.status != 0 && empty.output.canFind(name ~ " must not be empty"), empty.output);
			assertFixtureContents(root, ["cwd"]);

			environment[name] = "relative";
			auto relative = runCydo(["init"]);
			assert(relative.status != 0 && relative.output.canFind(name ~ " must be an absolute path"),
				relative.output);
			assertFixtureContents(root, ["cwd"]);
			environment.remove(name);
		}
	});
}

unittest // Init requires an existing absolute HOME before writing.
{
	withInitCliFixture("cydo-main-init-cli-invalid-home", (string root)
	{
		environment.remove("HOME");
		auto missing = runCydo(["init"]);
		assert(missing.status != 0 && missing.output.canFind("requires a nonempty effective HOME"),
			missing.output);
		assertFixtureContents(root, ["cwd"]);

		environment["HOME"] = "relative";
		auto relative = runCydo(["init"]);
		assert(relative.status != 0 && relative.output.canFind("requires an absolute effective HOME"),
			relative.output);
		assertFixtureContents(root, ["cwd"]);

		environment["HOME"] = buildPath(root, "missing-home");
		auto nonexistent = runCydo(["init"]);
		assert(nonexistent.status != 0 && nonexistent.output.canFind("project path must be an existing directory"),
			nonexistent.output);
		assertFixtureContents(root, ["cwd"]);
	});
}
