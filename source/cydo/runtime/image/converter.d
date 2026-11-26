module cydo.runtime.image.converter;

import ae.utils.json : JSONOptional;
import ae.utils.promise : Promise, Result, reject, resolve, toResult;

struct HeicConversionStatus
{
	bool available;
	@JSONOptional string reason;
}

interface HeicConverter
{
	@property HeicConversionStatus status();
	void retire();
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

	override void retire() {}

	override Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] heic)
	{
		return reject!(immutable(ubyte)[])(new Exception(reason));
	}
}

enum maxHeicInputBytes = 32 * 1024 * 1024;

HeicConverter createHeicConverter(bool jailed, void delegate() statusChanged = null)
{
	version (linux)
	{
		try
			return BoundedHeicConverter.fromPath(jailed, statusChanged);
		catch (Exception e)
			return new UnavailableHeicConverter(e.msg);
	}
	else
		return new UnavailableHeicConverter("HEIC conversion needs Linux");
}

version (linux)
{
	import core.time : MonoTime, seconds;
	import std.algorithm : startsWith;
	import std.exception : enforce;
	import std.file : exists, rmdirRecurse, symlink, tempDir, write;
	import std.path : absolutePath, buildPath;

	import ae.net.asockets : onNextTick, socketManager;
	import ae.sys.file : realPath;

	import cydo.agent.process : ProcessResourceLimits;
	import cydo.runtime.image.bounded_filter : FilterFailure, FilterFailureKind, FilterLimits,
		FilterOutput, filterExitDiagnostic, runBoundedFilter;
	import cydo.runtime.launch.sandbox : HelperJail, PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind, buildHelperJailCommand, resolveExecutablePath;

	private alias Filter = Promise!FilterOutput delegate(
		immutable(ubyte)[] input, FilterLimits limits);

	final class BoundedHeicConverter : HeicConverter
	{
		private enum decoderStage = "heif-dec uses libde265";
		private enum cleanerStage = "jpegtran";

		private struct Conversion
		{
			immutable(ubyte)[] input;
			Promise!(immutable(ubyte)[]) result;
			bool startupProbe;
		}

		private Filter decode;
		private Filter clean;
		private bool retired;
		private Conversion[] queue;
		private HeicConversionStatus conversionStatus =
			HeicConversionStatus(false, "checking the HEIC converter");

		private this(Filter decode, Filter clean, immutable(ubyte)[] probeInput,
			void delegate() statusChanged)
		{
			this.decode = decode;
			this.clean = clean;
			onNextTick(socketManager, {
				if (retired)
					return;
				enqueue(probeInput, true).then((immutable(ubyte)[]) {
					if (!retired)
						conversionStatus = HeicConversionStatus(true);
				}).except((Exception e) {
					if (retired)
						return;
					auto reason = "HEIC converter self-check failed: " ~ e.msg;
					auto failure = cast(FilterFailure) e;
					if (failure !is null && failure.diagnostic.length)
						reason ~= " - " ~ failure.diagnostic;
					conversionStatus = HeicConversionStatus(false, reason);
				}).finish({
					if (!retired && statusChanged !is null)
						statusChanged();
				}).ignoreResult();
			});
		}

		static BoundedHeicConverter fromPath(bool jailed, void delegate() statusChanged)
		{
			static string findTool(string name)
			{
				auto path = resolveExecutablePath(name, null);
				enforce(path.length, "HEIC conversion requires " ~ name ~ " on PATH");
				return realPath(absolutePath(path));
			}

			auto heif = findTool("heif-dec");
			auto jpegtran = findTool("jpegtran");
			enum decoderOptions = ["--quiet", "-d", "libde265", "--codec-threads", "2"];
			auto clean = [jpegtran, "-copy", "icc"];
			Filter decode;
			if (jailed)
			{
				auto bwrap = findTool("bwrap");
				auto decoderJail = toolJail(heif);
				decoderJail.stdinFile = "/tmp/in.heic";
				decoderJail.stdoutLink = "/tmp/out.jpg";
				auto decoderCommand = buildHelperJailCommand(decoderJail,
					[heif] ~ decoderOptions ~ [decoderJail.stdinFile, decoderJail.stdoutLink], bwrap);
				auto cleanerJail = toolJail(jpegtran);
				clean = buildHelperJailCommand(cleanerJail, clean, bwrap);
				decode = (input, limits) => runBoundedFilter(decoderCommand, input, limits,
					allowEmptyOutput: true);
			}
			else
				decode = (input, limits) => decodeDirect(heif, decoderOptions, input, limits);

			enum probe = cast(immutable(ubyte)[]) import("colors.heic");
			return new BoundedHeicConverter(decode,
				(input, limits) => runBoundedFilter(clean, input, limits), probe, statusChanged);
		}

		private Promise!FilterOutput runStage(Filter filter,
			immutable(ubyte)[] input, FilterLimits limits, string stage)
		{
			return resolve().then(() {
				if (retired)
					throw new FilterFailure(FilterFailureKind.reconfigured);
				return filter(input, limits);
			}).then((FilterOutput output) => output,
				delegate FilterOutput(Exception error) {
					auto failure = cast(FilterFailure) error;
					if (failure is null)
						throw new FilterFailure(FilterFailureKind.failed, stage ~ ": " ~ error.msg);
					auto diagnostic = stage;
					if (failure.diagnostic.length)
						diagnostic ~= ": " ~ failure.diagnostic;
					throw new FilterFailure(failure.kind, diagnostic);
				});
		}

		private static HelperJail toolJail(string executable)
		{
			HelperJail jail;
			jail.tmpfsBytes = 96 * 1024 * 1024;
			auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				"HEIC converter", "tool runtime");
			if (executable.startsWith("/nix/store/"))
				jail.paths.require("/nix/store", PathAccess.ro, origin);
			else
			{
				foreach (path; ["/usr/lib", "/usr/lib32", "/usr/lib64", "/usr/libx32",
					"/lib", "/lib32", "/lib64", "/libx32", "/etc/ld.so.cache"])
					if (exists(path))
						jail.paths.require(path, PathAccess.ro, origin);
				jail.paths.require(executable, PathAccess.ro, origin);
			}
			return jail;
		}

		private static Promise!FilterOutput decodeDirect(string heif,
			string[] options, immutable(ubyte)[] input, FilterLimits limits)
		{
			import core.sys.posix.stdlib : mkdtemp;

			auto templateName = (buildPath(absolutePath(tempDir()), "cydo-heic-XXXXXX") ~ '\0').dup;
			enforce(mkdtemp(templateName.ptr) !is null, "Could not create HEIC staging directory");
			auto staging = templateName[0 .. $ - 1].idup;
			scope (failure) rmdirRecurse(staging);
			auto source = buildPath(staging, "in.heic");
			auto destination = buildPath(staging, "out.jpg");
			write(source, input);
			symlink("/proc/self/fd/1", destination);
			return runBoundedFilter([heif] ~ options ~ [source, destination], null, limits,
				allowEmptyOutput: true)
				.then((FilterOutput output) {
					rmdirRecurse(staging);
					return output;
				}, delegate FilterOutput(Exception error) {
					rmdirRecurse(staging);
					throw error;
				});
		}

		override @property HeicConversionStatus status()
		{
			return conversionStatus;
		}

		override void retire()
		{
			retired = true;
			conversionStatus = HeicConversionStatus(false,
				new FilterFailure(FilterFailureKind.reconfigured).msg);
			foreach (conversion; queue)
				conversion.result.reject(new FilterFailure(FilterFailureKind.reconfigured));
			queue = null;
		}

		override Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] heic)
		{
			if (retired)
				return reject!(immutable(ubyte)[], Exception)(new FilterFailure(FilterFailureKind.reconfigured));
			if (heic.length > maxHeicInputBytes)
				return reject!(immutable(ubyte)[])(new Exception("too large"));

			return enqueue(heic, false);
		}

		private Promise!(immutable(ubyte)[]) enqueue(immutable(ubyte)[] heic, bool startupProbe)
		{
			auto result = new Promise!(immutable(ubyte)[]);
			queue ~= Conversion(heic, result, startupProbe);
			if (queue.length == 1)
				startConversion();
			return result;
		}

		private void startConversion()
		{
			auto limits = FilterLimits(ProcessResourceLimits(1024UL * 1024 * 1024,
				30, 64 * 1024 * 1024), MonoTime.currTime + 30.seconds, 32 * 1024 * 1024);
			auto conversion = queue[0];
			runStage(decode, conversion.input, limits, decoderStage)
				.then((FilterOutput decoded) {
					if (decoded.bytes.length)
						return runStage(clean, decoded.bytes, limits, cleanerStage);
					if (conversion.startupProbe)
						throw new FilterFailure(FilterFailureKind.failed, decoderStage ~
							": empty JPEG output: " ~ filterExitDiagnostic(0, decoded.stderr));
					// A successful multi-image decode writes numbered files instead of the stdout symlink.
					throw new FilterFailure(FilterFailureKind.multiImage);
				}).then((FilterOutput cleaned) {
					enum ubyte[3] jpegPrefix = [0xff, 0xd8, 0xff];
					auto jpeg = cleaned.bytes;
					if (jpeg.length < jpegPrefix.length || jpeg[0 .. jpegPrefix.length] != jpegPrefix[])
						throw new FilterFailure(FilterFailureKind.failed, cleanerStage ~
							": invalid JPEG output: " ~ filterExitDiagnostic(0, cleaned.stderr));
					return jpeg;
				}).toResult().then((Result!(immutable(ubyte)[]) result) {
					if (retired)
						return;
					queue = queue[1 .. $];
					conversion.result.resolve(result);
					if (queue.length)
						startConversion();
				}).ignoreResult();
		}
	}
}

version (linux) version (unittest)
{
	import cydo.foundation.testing : drainNextTicks;

	private Promise!(immutable(ubyte)[]) startupFilterResult;
	private enum startupInput = cast(immutable(ubyte)[]) "startup HEIC";

	private Promise!FilterOutput startupFilter(immutable(ubyte)[] input, FilterLimits)
	{
		assert(input == startupInput);
		auto result = startupFilterResult;
		assert(result !is null, "unexpected second startup filter call");
		startupFilterResult = null;
		return result.then((immutable(ubyte)[] output) => FilterOutput(output));
	}

	BoundedHeicConverter makeGatedStartupConverter(Promise!(immutable(ubyte)[]) result,
		void delegate() statusChanged)
	{
		startupFilterResult = result;
		auto converter = new BoundedHeicConverter((input, limits) => startupFilter(input, limits),
			(input, limits) => resolve(FilterOutput(input)), startupInput, statusChanged);
		drainNextTicks();
		assert(startupFilterResult is null, "startup filter did not run");
		return converter;
	}

	unittest
	{
		auto result = new Promise!(immutable(ubyte)[]);
		HeicConversionStatus[] notifications;
		BoundedHeicConverter converter;
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
		BoundedHeicConverter converter;
		converter = makeGatedStartupConverter(result, { notifications ~= converter.status; });
		assert(notifications.length == 0);

		result.reject(new FilterFailure(FilterFailureKind.timedOut));
		drainNextTicks();
		auto unavailable = HeicConversionStatus(false, "HEIC converter self-check failed: timed out - heif-dec uses libde265");
		assert(converter.status == unavailable);
		assert(notifications == [unavailable]);
	}

	unittest
	{
		auto converter = new BoundedHeicConverter((input, limits) => resolve(FilterOutput(input)),
			(input, limits) => reject!(FilterOutput, Exception)(
				new FilterFailure(FilterFailureKind.failed, "exit status 1: invalid data")),
			startupInput, null);
		drainNextTicks();
		assert(converter.status == HeicConversionStatus(false,
			"HEIC converter self-check failed: conversion failed - jpegtran: exit status 1: invalid data"));
	}

	unittest
	{
		alias Bytes = immutable(ubyte)[];
		auto decodeGate = new Promise!FilterOutput;
		enum jpeg = cast(Bytes) "\xff\xd8\xff\xd9";
		size_t decoderCalls, cleanerCalls;
		auto converter = new BoundedHeicConverter((input, limits) {
			return ++decoderCalls == 1 ? resolve(FilterOutput(jpeg)) : decodeGate;
		}, (input, limits) {
			cleanerCalls++;
			return resolve(FilterOutput(input));
		}, startupInput, null);
		drainNextTicks();
		assert(converter.status.available);

		string[] refusals;
		void refused(Exception error) { refusals ~= error.msg; }
		converter.toJpeg(startupInput).except(&refused).ignoreResult();
		converter.toJpeg(startupInput).except(&refused).ignoreResult();
		drainNextTicks();
		assert(decoderCalls == 2 && cleanerCalls == 1);

		converter.retire();
		drainNextTicks();
		enum reason = "image converter reconfigured; resubmit";
		assert(refusals == [reason, reason]);

		decodeGate.fulfill(FilterOutput(jpeg));
		drainNextTicks();
		assert(decoderCalls == 2 && cleanerCalls == 1);
		assert(refusals == [reason, reason]);
	}
}
