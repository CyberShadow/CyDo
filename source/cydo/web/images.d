/// Image blocks arriving from a browser, normalized into what the agent APIs
/// accept before any handler sees them.
///
/// The case that made this necessary: an iPhone camera photo is HEIC, and a
/// mobile browser hands it over as the original file. No agent API takes HEIC,
/// so the block is transcoded to JPEG here with ImageMagick. The conversion is
/// asynchronous: the event loop is single-threaded and shared by every client,
/// so blocking it for the second a transcode takes would stall everyone's
/// streaming.
module cydo.web.images;

import std.base64 : Base64;
import std.process : Config, Pid, pipe, spawnProcess;
import std.stdio : File;

import ae.net.asockets : DisconnectType, FileConnection;
import ae.sys.data : Data;
import ae.sys.process : asyncWait;
import ae.utils.array : asBytes;

import cydo.protocol : ContentBlock;

/// media types the agent APIs accept as-is
bool isNativeImageType(string mediaType)
{
	switch (mediaType)
	{
		case "image/jpeg", "image/png", "image/gif", "image/webp": return true;
		default: return false;
	}
}

/// media types this module can turn into a native one
bool isConvertibleImageType(string mediaType)
{
	return mediaType == "image/heic" || mediaType == "image/heif";
}

/// Outcome of normalizing one message's blocks.
struct ImageNormalization
{
	ContentBlock[] blocks;
	string error; /// non-empty when a block could not be made acceptable
}

/// Rewrite any convertible image block in `blocks` and hand the result to
/// `done`. Calls `done` synchronously when nothing needs converting, so the
/// ordinary path keeps its ordering guarantees; otherwise `done` runs once
/// every conversion has finished.
void normalizeImageBlocks(ContentBlock[] blocks, void delegate(ImageNormalization) done)
{
	size_t pending = 0;
	foreach (ref b; blocks)
		if (b.type == "image" && isConvertibleImageType(b.media_type))
			pending++;
	if (pending == 0)
	{
		done(ImageNormalization(blocks, null));
		return;
	}

	auto result = ImageNormalization(blocks.dup, null);
	size_t remaining = pending;

	// one frame per conversion: a delegate made in a loop body shares the
	// function's single closure frame, so every one of them would otherwise
	// see the final loop index and write into the same block. a parameter of
	// a helper call is a fresh variable each time
	void convertBlock(size_t index)
	{
		convertToJpeg(Base64.decode(result.blocks[index].data), (ubyte[] jpeg, string error) {
			if (error.length > 0)
			{
				if (result.error.length == 0)
					result.error = error;
			}
			else
			{
				result.blocks[index].data = Base64.encode(jpeg).idup;
				result.blocks[index].media_type = "image/jpeg";
			}
			if (--remaining == 0)
				done(result);
		});
	}

	foreach (i, ref b; result.blocks)
		if (b.type == "image" && isConvertibleImageType(b.media_type))
			convertBlock(i);
}

/// Transcode one image to JPEG with ImageMagick, asynchronously.
///
/// `magick` is resolved through PATH at call time, so a missing install is an
/// error for the one attachment rather than a startup failure for the server.
void convertToJpeg(ubyte[] input, void delegate(ubyte[] jpeg, string error) done)
{
	import std.process : environment;
	import std.file : exists;
	import std.path : buildPath;
	import std.algorithm : splitter;

	string magick;
	foreach (dir; environment.get("PATH", "").splitter(':'))
	{
		auto candidate = buildPath(dir, "magick");
		if (candidate.exists)
		{
			magick = candidate;
			break;
		}
	}
	if (magick.length == 0)
	{
		done(null, "cannot convert this image: ImageMagick (magick) is not installed on the server");
		return;
	}

	auto stdinPipe = pipe();
	auto stdoutPipe = pipe();
	auto stderrPipe = pipe();
	// quality 90 keeps a phone photo well under the agent APIs' size limits
	// while staying visually lossless for their purposes
	auto pid = spawnProcess(
		[magick, "-", "-auto-orient", "-quality", "90", "jpeg:-"],
		stdinPipe.readEnd, stdoutPipe.writeEnd, stderrPipe.writeEnd,
		null, Config.none);
	stdinPipe.readEnd.close();
	stdoutPipe.writeEnd.close();
	stderrPipe.writeEnd.close();

	import core.sys.posix.unistd : dup;
	auto stdinConn = new FileConnection(dup(stdinPipe.writeEnd.fileno));
	auto stdoutConn = new FileConnection(dup(stdoutPipe.readEnd.fileno));
	auto stderrConn = new FileConnection(dup(stderrPipe.readEnd.fileno));
	stdinPipe.writeEnd.close();
	stdoutPipe.readEnd.close();
	stderrPipe.readEnd.close();

	ubyte[] output;
	ubyte[] errors;
	bool stdoutDone, stderrDone, exited;
	int status;
	bool finished;

	void finish()
	{
		if (finished || !stdoutDone || !stderrDone || !exited)
			return;
		finished = true;
		if (status != 0 || output.length == 0)
		{
			import std.string : strip;
			auto detail = (cast(string) errors).strip;
			done(null, "cannot convert this image to JPEG"
				~ (detail.length ? ": " ~ detail : ""));
		}
		else
			done(output, null);
	}

	stdoutConn.handleReadData = (Data data) { output ~= cast(ubyte[]) data.toGC(); };
	stdoutConn.handleDisconnect = (string, DisconnectType) { stdoutDone = true; finish(); };
	stderrConn.handleReadData = (Data data) { errors ~= cast(ubyte[]) data.toGC(); };
	stderrConn.handleDisconnect = (string, DisconnectType) { stderrDone = true; finish(); };
	asyncWait(pid, (int code) { status = code; exited = true; finish(); });

	// a requested disconnect on a connection with queued writes closes the fd
	// only after everything has been flushed, which is what hands magick its EOF
	stdinConn.send(Data(input));
	stdinConn.disconnect("input written");
}

unittest
{
	import std.process : environment, execute;
	import ae.net.asockets : socketManager;
	import ae.utils.json : JSONFragment;

	// needs a real ImageMagick with HEIC support; the nix sandbox has none, so
	// the test proves the pipeline where it can and is silent where it cannot
	auto probe = execute(["sh", "-c", "command -v magick >/dev/null 2>&1 && magick -list format | grep -q HEIC"]);
	if (probe.status != 0)
		return;

	auto heic = execute(["magick", "-size", "8x6", "xc:tomato", "heic:-"]);
	assert(heic.status == 0 && heic.output.length > 12, "could not produce a HEIC fixture");

	auto blocks = [
		ContentBlock("text", "caption"),
		ContentBlock("image", null, null, null, JSONFragment.init,
			Base64.encode(cast(ubyte[]) heic.output).idup, "image/heic"),
	];
	ImageNormalization got;
	bool called;
	normalizeImageBlocks(blocks, (ImageNormalization r) { got = r; called = true; });
	assert(!called, "a convertible block must not complete synchronously");
	while (!called)
		socketManager.loop();
	assert(got.error.length == 0, got.error);
	assert(got.blocks[0].type == "text" && got.blocks[0].text == "caption", "other blocks pass through untouched");
	assert(got.blocks[1].media_type == "image/jpeg");
	auto jpeg = Base64.decode(got.blocks[1].data);
	assert(jpeg.length > 2 && jpeg[0] == 0xFF && jpeg[1] == 0xD8, "output must be a JPEG");

	// two photos in one message: each must land in its own block. a single
	// shared closure frame made both conversions write the second slot, so the
	// first went to the agent still as HEIC
	auto second = execute(["magick", "-size", "12x9", "xc:navy", "heic:-"]);
	assert(second.status == 0);
	auto pair = [
		ContentBlock("image", null, null, null, JSONFragment.init,
			Base64.encode(cast(ubyte[]) heic.output).idup, "image/heic"),
		ContentBlock("text", "between"),
		ContentBlock("image", null, null, null, JSONFragment.init,
			Base64.encode(cast(ubyte[]) second.output).idup, "image/heic"),
	];
	ImageNormalization both;
	bool pairDone;
	normalizeImageBlocks(pair, (ImageNormalization r) { both = r; pairDone = true; });
	while (!pairDone)
		socketManager.loop();
	assert(both.error.length == 0, both.error);
	assert(both.blocks[0].media_type == "image/jpeg" && both.blocks[2].media_type == "image/jpeg",
		"every convertible block is converted, not just the last");
	assert(both.blocks[0].data != both.blocks[2].data, "each block keeps its own image");
	assert(both.blocks[1].text == "between");

	// nothing convertible: the continuation runs synchronously, in order
	bool sync;
	normalizeImageBlocks([ContentBlock("text", "plain")], (ImageNormalization r) { sync = true; });
	assert(sync, "an unconvertible batch must complete synchronously");
}
