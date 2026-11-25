/// Reject cross-site WebSocket upgrades that could reuse cached Basic-auth
/// credentials. The no-auth Host and bind restrictions address DNS rebinding
/// and LAN exposure. The loopback lists are deliberately non-configurable.
module cydo.web.request_policy;

import std.algorithm : canFind;
import std.conv : ConvOverflowException, to;
import std.format : format;
import std.string : indexOf, toLower;
import std.typecons : Nullable;

import ae.net.http.common : HttpStatusCode;

package(cydo):

struct Authority
{
	string host;
	ushort port;
	bool hasPort;
}

struct Origin
{
	string scheme;
	Authority authority;
}

struct RequestRejection
{
	HttpStatusCode status;
	string responseText;
	string logMessage;
}

private enum loopbackHosts = ["localhost", "127.0.0.1", "[::1]"];

enum noAuthHostText = "Authentication is disabled, so CyDo only accepts requests "
	~ "addressed to localhost, 127.0.0.1 or [::1]. Set CYDO_AUTH_PASS to access CyDo "
	~ "by other names.\n";

enum originMismatchText = "WebSocket connection refused: the Origin header does "
	~ "not match the Host header. If CyDo is behind a reverse proxy, the proxy must "
	~ "forward the original Host header.\n";

/// Parse a Host header, keeping brackets around an IPv6 literal.
Nullable!Authority parseHostHeader(string value)
{
	size_t hostEnd;
	if (value.length > 0 && value[0] == '[')
	{
		auto closeBracket = value.indexOf(']');
		if (closeBracket <= 1)
			return Nullable!Authority.init;
		hostEnd = closeBracket + 1;
	}
	else
	{
		auto colon = value.indexOf(':');
		hostEnd = colon < 0 ? value.length : colon;
		if (hostEnd == 0)
			return Nullable!Authority.init;
	}

	auto host = value[0 .. hostEnd].toLower();
	if (hostEnd == value.length)
		return Nullable!Authority(Authority(host, 0, false));

	auto portText = value[hostEnd + 1 .. $];
	if (value[hostEnd] != ':' || portText.length == 0 || portText.length > 5)
		return Nullable!Authority.init;
	foreach (char c; portText)
		if (c < '0' || c > '9')
			return Nullable!Authority.init;
	ushort port;
	try
		port = portText.to!ushort;
	catch (ConvOverflowException)
		return Nullable!Authority.init;
	if (port == 0)
		return Nullable!Authority.init;
	return Nullable!Authority(Authority(host, port, true));
}

/// Parse a serialized HTTP or HTTPS origin.
Nullable!Origin parseOrigin(string value)
{
	auto separator = value.indexOf("://");
	if (separator < 0)
		return Nullable!Origin.init;
	auto scheme = value[0 .. separator].toLower();
	if (scheme != "http" && scheme != "https")
		return Nullable!Origin.init;
	auto parsed = parseHostHeader(value[separator + 3 .. $]);
	if (parsed.isNull)
		return Nullable!Origin.init;

	auto host = parsed.get.host;
	if (host[0] == '[')
		host = host[1 .. $ - 1];
	foreach (char c; host)
		if ("/@?#\\[]".canFind(c))
			return Nullable!Origin.init;
	return Nullable!Origin(Origin(scheme, parsed.get));
}

private string describeHeaders(const(string)[] values)
{
	return values.length == 0 ? "(none)" : format!"%(%s, %)"(values);
}

Nullable!RequestRejection checkRequestPolicy(
	const(string)[] hostHeaders, const(string)[] originHeaders,
	bool webSocket, bool authEnabled, string resource)
{
	auto host = hostHeaders.length == 1 ? parseHostHeader(hostHeaders[0]) : Nullable!Authority.init;
	if (!authEnabled && (host.isNull || !loopbackHosts.canFind(host.get.host)))
		return Nullable!RequestRejection(RequestRejection(HttpStatusCode.Forbidden, noAuthHostText,
			format!"Rejected request for %s: Host %s is not a loopback name and authentication is disabled"(
				resource, describeHeaders(hostHeaders))));

	if (!webSocket || originHeaders.length == 0)
		return Nullable!RequestRejection.init;

	auto origin = originHeaders.length == 1 ? parseOrigin(originHeaders[0]) : Nullable!Origin.init;
	if (!host.isNull && !origin.isNull)
	{
		auto authority = origin.get.authority;
		auto defaultPort = origin.get.scheme == "https" ? 443 : 80;
		auto originPort = authority.hasPort ? authority.port : defaultPort;
		auto hostPort = host.get.hasPort ? host.get.port : defaultPort;
		if (authority.host == host.get.host && originPort == hostPort)
			return Nullable!RequestRejection.init;
	}

	return Nullable!RequestRejection(RequestRejection(HttpStatusCode.Forbidden,
		originMismatchText, format!"Rejected WebSocket upgrade: Origin %s does not match Host %s"(
			describeHeaders(originHeaders), describeHeaders(hostHeaders))));
}

/// TCP listen addresses allowed without authentication.
bool isLoopbackListenAddress(string address)
{
	enum loopbackListenAddresses = ["localhost", "127.0.0.1", "::1"];
	return loopbackListenAddresses.canFind(address);
}

// Unauthenticated TCP listeners accept only the exact configured loopback literals.
unittest
{
	foreach (address; ["localhost", "127.0.0.1", "::1"])
		assert(isLoopbackListenAddress(address), address);

	foreach (address; ["*", "0.0.0.0", "::", "127.0.0.2", "[::1]", "LOCALHOST", "192.168.1.5", ""])
		assert(!isLoopbackListenAddress(address), format!"Accepted listen address %s"(address));
}

// Host authorities preserve IPv6 brackets and distinguish an omitted port.
unittest
{
	struct TestCase
	{
		string value;
		Authority expected;
	}

	foreach (test; [
		TestCase("localhost", Authority("localhost", 0, false)),
		TestCase("localhost:3940", Authority("localhost", 3940, true)),
		TestCase("LOCALHOST:3940", Authority("localhost", 3940, true)),
		TestCase("127.0.0.1:1", Authority("127.0.0.1", 1, true)),
		TestCase("[::1]", Authority("[::1]", 0, false)),
		TestCase("[::1]:3940", Authority("[::1]", 3940, true)),
		TestCase("[2001:db8::1]:443", Authority("[2001:db8::1]", 443, true)),
	])
	{
		auto parsed = parseHostHeader(test.value);
		assert(!parsed.isNull && parsed.get == test.expected, test.value);
	}

	foreach (value; ["", ":3940", "localhost:", "localhost:0", "localhost:65536",
		"localhost:12a", "localhost:3940:1", "::1", "[::1", "[]", "[::1]x", "[::1]:"])
		assert(parseHostHeader(value).isNull, format!"Accepted malformed Host %s"(value));
}

// Only serialized HTTP(S) origins are accepted.
unittest
{
	struct TestCase
	{
		string value;
		Origin expected;
	}

	foreach (test; [
		TestCase("http://localhost:3940", Origin("http", Authority("localhost", 3940, true))),
		TestCase("https://cydo.example", Origin("https", Authority("cydo.example", 0, false))),
		TestCase("HTTPS://Cydo.Example:8443", Origin("https", Authority("cydo.example", 8443, true))),
		TestCase("http://[::1]:3940", Origin("http", Authority("[::1]", 3940, true))),
	])
	{
		auto parsed = parseOrigin(test.value);
		assert(!parsed.isNull && parsed.get == test.expected, test.value);
	}

	foreach (value; ["null", "file://", "chrome-extension://abc", "http://", "http://host/",
		"http://host/path", "http://user@host", "ws://host", "http://cydo.example?x",
		"http://cydo.example#x", "http://cydo.example:3940?x",
		"http://cydo.example:3940#x", "http://cydo.example?x:3940",
		"http://cydo.example#x:3940", "http://host\\path", "http://host[",
		"http://host]", "http://[[::1]", "http://[::1?x]:3940"])
		assert(parseOrigin(value).isNull, format!"Accepted malformed Origin %s"(value));
}

// With auth enabled, only WebSocket requests carrying an Origin require a match.
unittest
{
	assert(checkRequestPolicy(["cydo.example"], [], true, true, "/ws").isNull);
	assert(checkRequestPolicy(["cydo.example"], ["https://evil.example"], false, true, "/").isNull);

	struct TestCase
	{
		string host;
		string origin;
	}

	foreach (test; [
		TestCase("localhost:3940", "http://localhost:3940"),
		TestCase("cydo.example", "https://cydo.example"),
		TestCase("cydo.example:443", "https://cydo.example"),
		TestCase("cydo.example:80", "http://cydo.example"),
		TestCase("[::1]:3940", "http://[::1]:3940"),
	])
		assert(checkRequestPolicy([test.host], [test.origin], true, true, "/ws").isNull,
			format!"Rejected Host %s with Origin %s"(test.host, test.origin));
}

// A WebSocket Origin requires an unambiguous, matching authority.
unittest
{
	import std.array : join;

	struct TestCase
	{
		string[] hosts;
		string[] origins;
	}

	foreach (test; [
		TestCase(["cydo.example"], ["https://evil.example"]),
		TestCase(["cydo.example:80"], ["https://cydo.example"]),
		TestCase(["cydo.example"], ["http://cydo.example:8080"]),
		TestCase(["localhost:3940"], ["http://localhost:3941"]),
		TestCase(["cydo.example"], ["null"]),
		TestCase(["cydo.example"], ["https://cydo.example", "https://cydo.example"]),
		TestCase([], ["https://cydo.example"]),
		TestCase(["cydo.example", "cydo.example"], ["https://cydo.example"]),
	])
	{
		auto rejection = checkRequestPolicy(test.hosts, test.origins, true, true, "/ws");
		assert(!rejection.isNull, format!"Accepted Host %s with Origin %s"(test.hosts, test.origins));
		assert(rejection.get.status == HttpStatusCode.Forbidden);
		assert(rejection.get.responseText == originMismatchText);
		auto expectedHost = test.hosts.length == 0 ? "(none)" : "\"" ~ test.hosts.join("\", \"") ~ "\"";
		auto expectedOrigin = "\"" ~ test.origins.join("\", \"") ~ "\"";
		assert(rejection.get.logMessage == "Rejected WebSocket upgrade: Origin "
			~ expectedOrigin ~ " does not match Host " ~ expectedHost,
			rejection.get.logMessage);
	}
}

// Without auth, the same loopback names are accepted on HTTP and WebSocket routes.
unittest
{
	foreach (host; ["localhost", "localhost:3940", "127.0.0.1", "127.0.0.1:80",
		"[::1]", "[::1]:3940", "LOCALHOST:3940"])
	{
		assert(checkRequestPolicy([host], [], false, false, "/").isNull, host);
		assert(checkRequestPolicy([host], [], true, false, "/ws").isNull, host);
	}
}

// Without auth, every route requires one valid loopback Host.
unittest
{
	import std.array : join;

	foreach (hosts; [[], ["localhost", "localhost"], ["evil.example"],
		["localhost.evil.example"], ["127.0.0.2"], ["0.0.0.0"], ["[::ffff:127.0.0.1]"],
		["[0:0:0:0:0:0:0:1]"], ["localhost."], ["192.168.1.5:3940"], ["localhost:"]])
	{
		foreach (resource; ["/", "/manifest.json", "/ws"])
		{
			auto rejection = checkRequestPolicy(hosts, [], resource == "/ws", false, resource);
			assert(!rejection.isNull, format!"Accepted Host %s for %s"(hosts, resource));
			assert(rejection.get.status == HttpStatusCode.Forbidden);
			assert(rejection.get.responseText == noAuthHostText);
			auto expectedHost = hosts.length == 0 ? "(none)" : "\"" ~ hosts.join("\", \"") ~ "\"";
			assert(rejection.get.logMessage == "Rejected request for " ~ resource ~ ": Host "
				~ expectedHost ~ " is not a loopback name and authentication is disabled",
				rejection.get.logMessage);
		}
	}
}

// The Host rejection takes precedence over an Origin mismatch.
unittest
{
	auto rejection = checkRequestPolicy(["evil.example"], ["http://localhost"], true, false, "/ws");
	assert(!rejection.isNull);
	assert(rejection.get.status == HttpStatusCode.Forbidden);
	assert(rejection.get.responseText == noAuthHostText);
}
