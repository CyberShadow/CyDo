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

enum ConfigErrorKind { unreadable, syntax, invalid }

class ConfigFileException : Exception
{
	ConfigErrorKind kind;
	string path;

	this(ConfigErrorKind kind, string path, string detail)
	{
		super(path ~ ": " ~ errorLabel(kind) ~ ": " ~ detail);
		this.kind = kind;
		this.path = path;
	}

	private static string errorLabel(ConfigErrorKind kind)
	{
		final switch (kind)
		{
			case ConfigErrorKind.unreadable: return "cannot be read";
			case ConfigErrorKind.syntax: return "syntax error";
			case ConfigErrorKind.invalid: return "invalid";
		}
	}
}

bool readConfigText(string path, out string text)
{
	import core.stdc.errno : errno, EINTR, ENOENT, ENOTDIR;
	import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK, O_RDONLY, open;
	import core.sys.posix.sys.stat : S_ISREG, fstat, lstat, stat_t;
	import core.sys.posix.unistd : close, read;
	import std.array : appender;
	import std.file : FileException;
	import std.string : toStringz;

	auto filename = path.toStringz;
	stat_t info;
	if (lstat(filename, &info) != 0)
	{
		auto error = errno;
		if (error == ENOENT || error == ENOTDIR)
			return false;
		throw new ConfigFileException(ConfigErrorKind.unreadable, path,
			(new FileException(path, error)).msg);
	}

	auto fd = open(filename, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0)
		throw new ConfigFileException(ConfigErrorKind.unreadable, path,
			(new FileException(path, errno)).msg);
	scope (exit) close(fd);

	if (fstat(fd, &info) != 0)
		throw new ConfigFileException(ConfigErrorKind.unreadable, path,
			(new FileException(path, errno)).msg);
	if (!S_ISREG(info.st_mode))
		throw new ConfigFileException(ConfigErrorKind.unreadable, path, "expected a regular file");

	auto contents = appender!string();
	char[8192] buffer;
	while (true)
	{
		auto count = read(fd, buffer.ptr, buffer.length);
		if (count == 0)
			break;
		if (count < 0)
		{
			auto error = errno;
			if (error == EINTR)
				continue;
			throw new ConfigFileException(ConfigErrorKind.unreadable, path,
				(new FileException(path, error)).msg);
		}
		contents.put(buffer[0 .. count]);
	}
	text = contents.data;
	return true;
}

Node loadConfigYaml(string text, string path)
{
	try
		return loadYamlString(text, path);
	catch (Exception e)
		throw new ConfigFileException(ConfigErrorKind.syntax, path, yamlConfigDiagnostic(e));
}

T parseConfigNode(T)(Node node, string path)
{
	try
		return parseYamlConfigNode!T(node, path);
	catch (Exception e)
		throw new ConfigFileException(ConfigErrorKind.invalid, path, yamlConfigDiagnostic(e));
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

unittest // An invalid config diagnostic includes the filename, position, and key.
{
	import std.algorithm : canFind;
	import std.exception : collectException;

	struct Config { bool b; }
	enum path = "invalid.yaml";
	auto error = collectException!ConfigFileException(
		parseConfigNode!Config(loadConfigYaml("# comment\nb: no\n", path), path));
	assert(error !is null && error.kind == ConfigErrorKind.invalid);
	assert(error.msg.canFind("invalid.yaml(1:3): b:"), error.msg);
}
