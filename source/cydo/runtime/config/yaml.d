/// Use YAML 1.2 core scalar resolution so YAML 1.1 boolean spellings such as
/// yes, no, on, and off are preserved in string fields.
/// Keep dyaml's merge keys. Bare leading-zero numbers such as 0755 resolve
/// as decimal floats, avoiding dyaml's octal integer interpretation.
/// 0o octals, numbers with underscores such as 1_000, and timestamps remain strings.
module cydo.runtime.config.yaml;

import configy.exceptions : ConfigException;
import configy.read : CLIArgs, parseConfig;
import dyaml.loader : Loader;
import dyaml.node : Node;
import dyaml.resolver : Resolver;
import std.regex : regex;
import std.format : format;
import std.stdio : File, stderr;
import std.typecons : Nullable, nullable;

private void useCoreSchema(ref Loader loader)
{
	loader.resolver = Resolver.init;
	loader.resolver.addImplicitResolver("tag:yaml.org,2002:bool",
		regex(`^(?:true|True|TRUE|false|False|FALSE)$`), "tTfF");
	loader.resolver.addImplicitResolver("tag:yaml.org,2002:int",
		regex(`^(?:[-+]?(?:0|[1-9][0-9]*)|0x[0-9a-fA-F]+)$`), "-+0123456789");
	loader.resolver.addImplicitResolver("tag:yaml.org,2002:float",
		regex(`^(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$`),
		"-+0123456789.");
	loader.resolver.addImplicitResolver("tag:yaml.org,2002:null",
		regex(`^(?:~|null|Null|NULL|)$`), "~nN\0");
	loader.resolver.addImplicitResolver("tag:yaml.org,2002:merge", regex(`^<<$`), "<");
}

Node loadYamlFile(string path)
{
	auto loader = Loader.fromFile(path);
	useCoreSchema(loader);
	return loader.load();
}

Node loadYamlString(string data, string name)
{
	auto loader = Loader.fromString(data, name);
	useCoreSchema(loader);
	return loader.load();
}

T parseYamlConfigNode(T)(Node node, string name)
{
	return parseConfig!T(CLIArgs(name), node);
}

/// configy keeps the source location and key in its formatted diagnostic.
string yamlConfigDiagnostic(Exception error)
{
	if (auto configError = cast(ConfigException) error)
		return format("%s", configError);
	return error.message().idup;
}

private Nullable!T reportYamlConfigFailure(T)(lazy T parse, File diagnostics)
{
	try
		return nullable(parse);
	catch (Exception error)
	{
		diagnostics.writeln(yamlConfigDiagnostic(error));
		return Nullable!T.init;
	}
}

Nullable!T parseYamlConfigFile(T)(string path)
{
	return reportYamlConfigFailure(parseYamlConfigNode!T(loadYamlFile(path), path), stderr);
}

T parseYamlConfigString(T)(string data, string name)
{
	return parseYamlConfigNode!T(loadYamlString(data, name), name);
}

unittest // YAML 1.1 boolean spellings retain their text in string fields.
{
	struct Config { string x; }
	foreach (value; ["no", "yes", "on", "off"])
		assert(parseYamlConfigString!Config("x: " ~ value, "strings.yaml").x == value, value);
}

unittest // Core booleans retain their values.
{
	struct Config { bool b; }
	assert(parseYamlConfigString!Config("b: true", "booleans.yaml").b);
	assert(!parseYamlConfigString!Config("b: False", "booleans.yaml").b);
}

unittest // Boolean type errors identify the configuration file and key.
{
	import std.algorithm : canFind;
	import std.exception : collectException;

	struct Config { bool b; }
	enum file = "booleans.yaml";
	foreach (value; ["yes", "no", "on"])
	{
		auto error = collectException(parseYamlConfigString!Config("b: " ~ value, file));
		assert(error !is null, value);
		auto diagnostic = error.toString();
		assert(diagnostic.canFind(file) && diagnostic.canFind("b:"), diagnostic);
	}
}

unittest // Decimal and hexadecimal integers load into an int field.
{
	struct Config { int x; }
	assert(parseYamlConfigString!Config("x: 12", "integers.yaml").x == 12);
	assert(parseYamlConfigString!Config("x: 0x10", "integers.yaml").x == 16);
}

unittest // A leading-zero number follows decimal float resolution.
{
	struct Config { double x; }
	assert(parseYamlConfigString!Config("x: 0755", "numbers.yaml").x == 755.0);
}

unittest // Merge keys populate fields from a mapping.
{
	struct Config { string x; }
	assert(parseYamlConfigString!Config("<<: {x: merged}", "merge.yaml").x == "merged");
}

unittest // YAML reader and parser errors report where loading failed.
{
	import std.algorithm : canFind;
	import std.exception : collectException;

	struct Config { string x; }
	auto error = collectException(parseYamlConfigString!Config("# comment\nx: ]\n", "syntax.yaml"));
	assert(error !is null);
	auto diagnostic = yamlConfigDiagnostic(error);
	assert(diagnostic.canFind("syntax.yaml:2,"), diagnostic);

	error = collectException(parseYamlConfigString!Config("x: \0", "reader.yaml"));
	assert(error !is null);
	diagnostic = yamlConfigDiagnostic(error);
	assert(diagnostic.canFind("\nreader.yaml:"), diagnostic);
}

unittest // The suggestions setting requires a core boolean.
{
	import cydo.runtime.config : CydoConfig;
	import std.exception : assertThrown;

	enum yaml = "workspaces: {}\nsuggestions: ";
	assert(!parseYamlConfigString!CydoConfig(yaml ~ "false", "config.yaml").suggestions);
	assertThrown(parseYamlConfigString!CydoConfig(yaml ~ "no", "config.yaml"));
}

unittest // A redirected diagnostic includes the filename, position, and key.
{
	import std.algorithm : canFind;

	struct Config { bool b; }
	auto diagnostics = File.tmpfile();
	auto result = reportYamlConfigFailure(
		parseYamlConfigString!Config("# comment\nb: no\n", "redirected.yaml"), diagnostics);
	assert(result.isNull());
	diagnostics.rewind();
	auto line = diagnostics.readln();
	assert(line.canFind("redirected.yaml(1:3): b:"), line);
}
