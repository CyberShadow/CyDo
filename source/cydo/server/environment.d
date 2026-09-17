module cydo.server.environment;

import std.process : environment;

/// Server-level settings taken from the process environment.
///
/// These variables address the CyDo server itself (where to listen, how to
/// authenticate clients). Nothing CyDo spawns — agent harnesses, the
/// subprocesses they run, git, bwrap — has any use for them, and
/// `CYDO_AUTH_PASS` in particular must not leak there. They are therefore
/// removed from the environment as they are read, before any child process
/// exists, so that every spawn path inherits a clean environ regardless of
/// whether it goes through the sandbox.
///
/// A `null` string means the variable was not set; an empty string means it
/// was set to the empty value (the distinction matters for `CYDO_AUTH_PASS`).
struct ServerEnvironment
{
	string tlsCert;
	string tlsKey;
	string authUser;
	string authPass;
	string listenSocket;
	string listenAddress;
	string listenPort;
}

/// Read the server-level settings from the process environment and unset
/// them so that they are not inherited by any child process.
ServerEnvironment consumeServerEnvironment()
{
	static string take(string name)
	{
		auto value = environment.get(name, null);
		environment.remove(name);
		return value;
	}

	return ServerEnvironment(
		tlsCert: take("CYDO_TLS_CERT"),
		tlsKey: take("CYDO_TLS_KEY"),
		authUser: take("CYDO_AUTH_USER"),
		authPass: take("CYDO_AUTH_PASS"),
		listenSocket: take("CYDO_LISTEN_SOCKET"),
		listenAddress: take("CYDO_LISTEN_ADDRESS"),
		listenPort: take("CYDO_LISTEN_PORT"),
	);
}

unittest
{
	import std.process : execute;

	environment["CYDO_AUTH_USER"] = "alice";
	environment["CYDO_AUTH_PASS"] = "";
	environment["CYDO_LISTEN_PORT"] = "4000";
	environment.remove("CYDO_TLS_CERT");
	environment.remove("CYDO_TLS_KEY");
	environment.remove("CYDO_LISTEN_SOCKET");
	environment.remove("CYDO_LISTEN_ADDRESS");

	auto serverEnv = consumeServerEnvironment();
	assert(serverEnv.authUser == "alice");
	assert(serverEnv.authPass !is null && serverEnv.authPass.length == 0);
	assert(serverEnv.listenPort == "4000");
	assert(serverEnv.tlsCert is null);
	assert(serverEnv.tlsKey is null);
	assert(serverEnv.listenSocket is null);
	assert(serverEnv.listenAddress is null);

	// Nothing consumed remains visible to the backend or to its children.
	foreach (name; ["CYDO_AUTH_USER", "CYDO_AUTH_PASS", "CYDO_LISTEN_PORT"])
	{
		assert(name !in environment, name);
		assert(execute(["sh", "-c", "printf %s \"${" ~ name ~ "+set}\""]).output == "", name);
	}
}
