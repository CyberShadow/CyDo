module cydo.runtime.image.converter;

import ae.utils.json : JSONOptional;
import ae.utils.promise : Promise, reject;

struct HeicConversionStatus
{
	bool available;
	@JSONOptional string reason;
}

interface HeicConverter
{
	@property HeicConversionStatus status();
	Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] heic);
}

final class UnavailableHeicConverter : HeicConverter
{
	private string reason;

	this(string reason)
	{
		this.reason = reason;
	}

	override @property HeicConversionStatus status()
	{
		return HeicConversionStatus(false, reason);
	}

	override Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] heic)
	{
		return reject!(immutable(ubyte)[])(new Exception(reason));
	}
}

enum maxHeicInputBytes = 32 * 1024 * 1024;

HeicConverter createHeicConverter(string manifestPath, void delegate() statusChanged = null)
{
	version (linux)
	{
		if (!manifestPath.length)
			return new UnavailableHeicConverter("not configured");
		try
			return JailedHeicConverter.loadManifest(manifestPath, statusChanged);
		catch (Exception e)
			return new UnavailableHeicConverter(e.msg);
	}
	else
		return new UnavailableHeicConverter("HEIC conversion needs the Linux bubblewrap sandbox");
}

version (linux)
{
	import core.time : seconds;
	import std.algorithm : any, startsWith;
	import std.exception : enforce;
	import std.file : exists, read, readText;
	import std.json : JSONType, parseJSON;
	import std.path : dirName;
	import std.string : lineSplitter;

	import ae.net.asockets : onNextTick, socketManager;
	import ae.sys.file : realPath;

	import cydo.agent.process : ProcessResourceLimits;
	import cydo.runtime.image.bounded_filter : FilterFailure, FilterFailureKind, FilterLimits,
		runBoundedFilter;
	import cydo.runtime.launch.sandbox : HelperJail, PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind, buildHelperJailCommand, resolveExecutablePath;

	final class JailedHeicConverter : HeicConverter
	{
		private struct Manifest
		{
			string[] argv;
			string[string] env;
			string store_paths;
			string probe_input;
		}

		private struct Conversion
		{
			immutable(ubyte)[] input;
			Promise!(immutable(ubyte)[]) result;
		}

		private string[] command;
		private Conversion[] queue;
		private typeof(&runBoundedFilter) filter;
		private HeicConversionStatus conversionStatus =
			HeicConversionStatus(false, "checking the HEIC converter");

		private this(string[] command, immutable(ubyte)[] probeInput,
			void delegate() statusChanged, typeof(&runBoundedFilter) filter = &runBoundedFilter)
		{
			this.command = command;
			this.filter = filter;
			onNextTick(socketManager, {
				toJpeg(probeInput).then((immutable(ubyte)[]) {
					conversionStatus = HeicConversionStatus(true);
				}).except((Exception e) {
					conversionStatus = HeicConversionStatus(false,
						"HEIC converter self-check failed: " ~ e.msg);
				}).finish({
					if (statusChanged !is null)
						statusChanged();
				}).ignoreResult();
			});
		}

		static JailedHeicConverter loadManifest(string path, void delegate() statusChanged = null)
		{
			enforce(exists(path), "HEIC converter manifest file does not exist");
			auto json = parseJSON(readText(path));
			enforce(json.type == JSONType.object, "HEIC converter manifest must be an object");
			foreach (field; ["argv", "env", "store_paths", "probe_input"])
				enforce(field in json.object, "HEIC converter manifest has missing fields: " ~ field);

			Manifest manifest;
			foreach (arg; json["argv"].array)
				manifest.argv ~= arg.str;
			foreach (key, value; json["env"].object)
				manifest.env[key] = value.str;
			manifest.store_paths = json["store_paths"].str;
			manifest.probe_input = json["probe_input"].str;
			enforce(manifest.argv.length && manifest.argv[0].length && manifest.store_paths.length
				&& manifest.probe_input.length, "HEIC converter manifest has empty fields");

			HelperJail jail;
			jail.tmpfsBytes = 96 * 1024 * 1024;
			jail.env = manifest.env;
			auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				"HEIC converter", "closure");
			string[] storePaths;
			foreach (storePath; readText(manifest.store_paths).lineSplitter)
			{
				enforce(dirName(storePath) == "/nix/store" && exists(storePath)
					&& realPath(storePath) == storePath,
					"HEIC converter closure contains an invalid or missing store path: " ~ storePath);
				jail.paths.require(storePath, PathAccess.ro, origin);
				storePaths ~= storePath;
			}

			auto executable = manifest.argv[0];
			enforce(executable.startsWith("/nix/store/") && resolveExecutablePath(executable, null).length,
				"HEIC converter executable must be an absolute store executable");
			enforce(realPath(executable) == executable,
				"HEIC converter executable must be a physical path");
			enforce(storePaths.any!(p => executable == p || executable.startsWith(p ~ "/")),
				"HEIC converter executable is outside the closure");

			foreach (arg; manifest.argv[1 .. $])
			{
				if (!arg.startsWith("/nix/store/"))
					continue;
				enforce(realPath(arg) == arg,
					"HEIC converter store argument must be a physical path: " ~ arg);
				enforce(storePaths.any!(p => arg == p || arg.startsWith(p ~ "/")),
					"HEIC converter store argument is outside the closure: " ~ arg);
			}
			enforce(exists(manifest.probe_input), "HEIC converter probe input does not exist");
			auto command = buildHelperJailCommand(jail, manifest.argv);
			auto probeInput = cast(immutable(ubyte)[]) read(manifest.probe_input, maxHeicInputBytes + 1);
			return new JailedHeicConverter(command, probeInput, statusChanged);
		}

		override @property HeicConversionStatus status()
		{
			return conversionStatus;
		}

		override Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] heic)
		{
			if (heic.length > maxHeicInputBytes)
				return reject!(immutable(ubyte)[])(new Exception("too large"));

			auto result = new Promise!(immutable(ubyte)[]);
			queue ~= Conversion(heic, result);
			if (queue.length == 1)
				startConversion();
			return result;
		}

		private void startConversion()
		{
			enum limits = FilterLimits(ProcessResourceLimits(1024UL * 1024 * 1024,
				30, 64 * 1024 * 1024), 30.seconds, 32 * 1024 * 1024);
			auto conversion = queue[0];
			filter(command, conversion.input, limits).then((immutable(ubyte)[] jpeg) {
				enum ubyte[3] jpegPrefix = [0xff, 0xd8, 0xff];
				if (jpeg.length < jpegPrefix.length || jpeg[0 .. jpegPrefix.length] != jpegPrefix[])
					throw new FilterFailure(FilterFailureKind.failed);
				conversion.result.fulfill(jpeg);
			}).except((Exception e) {
				conversion.result.reject(e);
			}).finish({
				queue = queue[1 .. $];
				if (queue.length)
					startConversion();
			}).ignoreResult();
		}
	}
}

version (linux) unittest
{
	import std.algorithm : startsWith;
	import std.exception : collectException;
	import std.file : mkdir, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment;
	import std.uuid : randomUUID;

	import ae.utils.json : toJson;

	auto dir = buildPath(tempDir(), "cydo-heic-manifest-" ~ randomUUID().toString());
	mkdir(dir);
	scope (exit) rmdirRecurse(dir);

	auto manifestPath = buildPath(dir, "converter.json");
	auto closurePath = buildPath(dir, "store-paths");

	void assertRefusal(string reason)
	{
		auto error = collectException(JailedHeicConverter.loadManifest(manifestPath));
		assert(error !is null, "accepted a bad HEIC converter manifest");
		assert(error.msg.startsWith(reason), error.msg);
	}

	assertRefusal("HEIC converter manifest file does not exist");
	write(manifestPath, `{}`);
	assertRefusal("HEIC converter manifest has missing fields");

	auto aliasExecutable = environment.get("CYDO_TEST_HEIC_EXECUTABLE_ALIAS");
	if (aliasExecutable is null)
		return; // The store-path cases use the Nix check's fixture.

	auto executable = realPath(environment["CYDO_TEST_CYDO_BIN"]);
	auto executableOutput = dirName(dirName(executable));
	auto otherOutput = environment["CYDO_TEST_DEFS"];
	auto probeInput = buildPath(dir, "probe.heic");
	write(probeInput, "");
	string[string] env;
	auto manifest = JailedHeicConverter.Manifest([executable], env, closurePath, probeInput);
	write(manifestPath, toJson(manifest));
	enum missingStorePath = "/nix/store/00000000000000000000000000000000-cydo-missing-heic-test";
	write(closurePath, missingStorePath ~ "\n");
	assertRefusal("HEIC converter closure contains an invalid or missing store path: " ~ missingStorePath);

	write(closurePath, otherOutput ~ "\n");
	assertRefusal("HEIC converter executable is outside the closure");

	write(closurePath, executableOutput ~ "\n");
	manifest.argv = [aliasExecutable];
	write(manifestPath, toJson(manifest));
	assertRefusal("HEIC converter executable must be a physical path");

	manifest.argv = [executable, aliasExecutable];
	write(manifestPath, toJson(manifest));
	assertRefusal("HEIC converter store argument must be a physical path");

	manifest.argv = [executable, otherOutput];
	write(manifestPath, toJson(manifest));
	assertRefusal("HEIC converter store argument is outside the closure");
}

version (linux) unittest
{
	foreach (path; ["", null])
	{
		auto status = createHeicConverter(path).status;
		assert(!status.available);
		assert(status.reason == "not configured", status.reason);
	}
}

version (linux) version (unittest)
{
	import cydo.foundation.testing : drainNextTicks;

	private Promise!(immutable(ubyte)[]) startupFilterResult;
	private enum startupInput = cast(immutable(ubyte)[]) "startup HEIC";

	private Promise!(immutable(ubyte)[]) startupFilter(string[], immutable(ubyte)[] input, FilterLimits)
	{
		assert(input == startupInput);
		auto result = startupFilterResult;
		assert(result !is null, "unexpected second startup filter call");
		startupFilterResult = null;
		return result;
	}

	JailedHeicConverter makeGatedStartupConverter(Promise!(immutable(ubyte)[]) result,
		void delegate() statusChanged)
	{
		startupFilterResult = result;
		auto converter = new JailedHeicConverter(["startup-filter"], startupInput,
			statusChanged, &startupFilter);
		drainNextTicks();
		assert(startupFilterResult is null, "startup filter did not run");
		return converter;
	}

	unittest
	{
		auto result = new Promise!(immutable(ubyte)[]);
		HeicConversionStatus[] notifications;
		JailedHeicConverter converter;
		converter = makeGatedStartupConverter(result, { notifications ~= converter.status; });
		assert(converter.status == HeicConversionStatus(false, "checking the HEIC converter"));
		assert(notifications.length == 0);

		result.fulfill(cast(immutable(ubyte)[]) "\xff\xd8\xff\xd9");
		drainNextTicks();
		assert(converter.status == HeicConversionStatus(true));
		assert(notifications == [HeicConversionStatus(true)]);
	}

	unittest
	{
		auto result = new Promise!(immutable(ubyte)[]);
		HeicConversionStatus[] notifications;
		JailedHeicConverter converter;
		converter = makeGatedStartupConverter(result, { notifications ~= converter.status; });
		assert(notifications.length == 0);

		result.reject(new FilterFailure(FilterFailureKind.timedOut));
		drainNextTicks();
		auto unavailable = HeicConversionStatus(false, "HEIC converter self-check failed: timed out");
		assert(converter.status == unavailable);
		assert(notifications == [unavailable]);
	}
}
