module cydo.server.attachment_intake;

import std.algorithm : any;
import std.base64 : Base64, Base64Exception;

import ae.net.asockets : onNextTick, socketManager;
import ae.utils.promise : Promise, Result, resolve, toResult;
import ae.utils.promise.await : async, await;

import cydo.protocol : ContentBlock;
import cydo.runtime.image.bounded_filter : FilterFailure;
import cydo.runtime.image.converter : HeicConverter, maxHeicInputBytes;
import cydo.runtime.image.heif : isHeifStill;

final class AttachmentRejection : Exception
{
	immutable int attachment;

	this(int attachment, string reason)
	{
		super(reason);
		this.attachment = attachment;
	}
}

private bool isHeic(const ref ContentBlock block)
{
	return block.type == "image" && (block.media_type == "image/heic" || block.media_type == "image/heif");
}

bool needsNormalization(const(ContentBlock)[] blocks)
{
	return blocks.any!isHeic;
}

final class SubmissionIntake
{
	private HeicConverter converter;
	private Promise!void[int] tails;

	this(HeicConverter converter)
	{
		this.converter = converter;
	}

	void setConverter(HeicConverter converter)
	{
		this.converter.retire();
		this.converter = converter;
	}

	Promise!(ContentBlock[]) normalize(ContentBlock[] blocks)
	{
		return async({
			auto normalized = blocks.dup;
			int attachment = -1;
			foreach (ref block; normalized)
			{
				if (block.type == "image")
					attachment++;
				if (!isHeic(block))
					continue;

				auto status = converter.status;
				if (!status.available)
					throw new AttachmentRejection(attachment,
						"HEIC conversion is unavailable on this server: " ~ status.reason);

				ubyte[] data;
				try
					data = Base64.decode(block.data);
				catch (Base64Exception)
					throw new AttachmentRejection(attachment, "invalid base64");
				if (data.length > maxHeicInputBytes)
					throw new AttachmentRejection(attachment, "too large");
				if (!isHeifStill(data))
					throw new AttachmentRejection(attachment, "not a HEIC/HEIF still image");

				immutable(ubyte)[] jpeg;
				try
					jpeg = converter.toJpeg(cast(immutable) data).await();
				catch (FilterFailure e)
					throw new AttachmentRejection(attachment, e.msg);
				catch (Exception)
					throw new AttachmentRejection(attachment, "conversion failed");
				block.data = cast(string) Base64.encode(jpeg);
				block.media_type = "image/jpeg";
			}
			return normalized;
		});
	}

	void submit(int tid, ContentBlock[] blocks, void delegate(ContentBlock[]) proceed,
		void delegate(AttachmentRejection) refuse)
	{
		auto previous = tid in tails;
		auto convert = needsNormalization(blocks);
		if (previous is null && !convert)
			return proceed(blocks);

		auto normalized = (convert ? normalize(blocks) : resolve(blocks)).toResult();
		auto ready = previous is null ? normalized : (*previous).then(() => normalized);
		auto tail = new Promise!void;
		tails[tid] = tail;
		ready.then((Result!(ContentBlock[]) result) {
			onNextTick(socketManager, {
				scope (exit)
				{
					if (tails[tid] is tail)
						tails.remove(tid);
					tail.fulfill();
				}
				if (result.error)
				{
					auto rejection = cast(AttachmentRejection) result.error;
					assert(rejection !is null);
					refuse(rejection);
				}
				else
					proceed(result.unwrap());
			});
		}).ignoreResult();
		tail.ignoreResult();
	}
}

version (unittest)
{
	import cydo.foundation.testing : drainNextTicks;
	import cydo.runtime.image.converter : HeicConversionStatus;

	final class GatedFakeConverter : HeicConverter
	{
		HeicConversionStatus conversionStatus = HeicConversionStatus(true);
		immutable(ubyte)[][] inputs;
		Promise!(immutable(ubyte)[])[] gates;

		override @property HeicConversionStatus status()
		{
			return conversionStatus;
		}

		override void retire() {}

		override Promise!(immutable(ubyte)[]) toJpeg(immutable(ubyte)[] input)
		{
			inputs ~= input;
			auto gate = new Promise!(immutable(ubyte)[]);
			gates ~= gate;
			return gate;
		}
	}

	// The brand box is sufficient for intake validation. The fake supplies the JPEG.
	enum testHeicBytes = "\x00\x00\x00\x10ftypheic\x00\x00\x00\x00";
	enum testJpegBytes = cast(immutable(ubyte)[]) "\xff\xd8\xff\xd9";

	ContentBlock testHeicBlock(string mediaType = "image/heic", string bytes = testHeicBytes)
	{
		return ContentBlock(type: "image", data: Base64.encode(cast(const(ubyte)[]) bytes),
			media_type: mediaType);
	}

	private enum testPngBlock = ContentBlock(type: "image", data: "iVBORw0KGgo=",
		media_type: "image/png");

	private enum unexpectedIntakeRefusal = delegate(AttachmentRejection rejection) {
		assert(false, rejection.msg);
	};
}

unittest
{
	auto converter = new GatedFakeConverter;
	auto intake = new SubmissionIntake(converter);
	auto blocks = [ContentBlock("text", "fast path"), testPngBlock];
	bool proceeded;
	assert(!needsNormalization(blocks));
	intake.submit(1, blocks, (ContentBlock[] result) {
		assert(result.ptr is blocks.ptr);
		proceeded = true;
	}, unexpectedIntakeRefusal);
	assert(proceeded && converter.inputs.length == 0);
}

unittest
{
	import cydo.runtime.image.bounded_filter : FilterFailureKind;

	foreach (failFirst; [false, true])
	{
		auto converter = new GatedFakeConverter;
		auto intake = new SubmissionIntake(converter);
		string[] order;
		intake.submit(1, [testHeicBlock()], (ContentBlock[]) {
			assert(!failFirst);
			order ~= "first accepted";
		}, (AttachmentRejection refusal) {
			assert(failFirst);
			assert(refusal.attachment == 0 && refusal.msg == "conversion failed");
			order ~= "first refused";
		});
		intake.submit(1, [ContentBlock("text", "second")], (ContentBlock[]) {
			order ~= "second accepted";
		}, unexpectedIntakeRefusal);
		drainNextTicks();
		assert(order.length == 0 && converter.gates.length == 1);

		if (failFirst)
			converter.gates[0].reject(new FilterFailure(FilterFailureKind.failed));
		else
			converter.gates[0].fulfill(testJpegBytes);
		drainNextTicks();
		assert(order == [failFirst ? "first refused" : "first accepted", "second accepted"]);
	}
}

unittest
{
	import std.exception : collectException;

	auto converter = new GatedFakeConverter;
	auto intake = new SubmissionIntake(converter);
	auto failure = new Exception("queued submission failed during dispatch");
	bool advanced;
	intake.submit(1, [testHeicBlock()], (ContentBlock[]) { throw failure; },
		unexpectedIntakeRefusal);
	intake.submit(1, [ContentBlock("text", "next submission")],
		(ContentBlock[]) { advanced = true; }, unexpectedIntakeRefusal);
	drainNextTicks();
	assert(converter.gates.length == 1 && !advanced);
	converter.gates[0].fulfill(testJpegBytes);
	assert(collectException(drainNextTicks()) is failure);
	drainNextTicks();
	assert(advanced);
}

unittest
{
	auto converter = new GatedFakeConverter;
	auto intake = new SubmissionIntake(converter);
	bool first, independent;
	intake.submit(1, [testHeicBlock()], (ContentBlock[]) { first = true; },
		unexpectedIntakeRefusal);
	drainNextTicks();
	assert(!first && converter.gates.length == 1);
	intake.submit(2, [ContentBlock("text", "independent")],
		(ContentBlock[]) { independent = true; }, unexpectedIntakeRefusal);
	assert(independent && !first);
	converter.gates[0].fulfill(testJpegBytes);
	drainNextTicks();
	assert(first);
}

unittest
{
	auto converter = new GatedFakeConverter;
	auto intake = new SubmissionIntake(converter);

	void assertInvalid(ContentBlock block, string reason)
	{
		AttachmentRejection refusal;
		intake.submit(1, [block], (ContentBlock[]) { assert(false, "Invalid image accepted"); },
			(AttachmentRejection error) { refusal = error; });
		drainNextTicks();
		assert(refusal !is null && refusal.attachment == 0 && refusal.msg == reason);
		assert(converter.inputs.length == 0);
	}

	assertInvalid(testHeicBlock("image/heic", "\x00\x00\x00\x10ftypavif\x00\x00\x00\x00"),
		"not a HEIC/HEIF still image");
	assertInvalid(ContentBlock(type: "image", data: "!!!!", media_type: "image/heic"),
		"invalid base64");
	auto oversized = new ubyte[maxHeicInputBytes + 1];
	oversized[0 .. testHeicBytes.length] = cast(const(ubyte)[]) testHeicBytes;
	assertInvalid(ContentBlock(type: "image", data: Base64.encode(oversized),
		media_type: "image/heic"), "too large");
	converter.conversionStatus = HeicConversionStatus(false, "no bwrap");
	assertInvalid(testHeicBlock(), "HEIC conversion is unavailable on this server: no bwrap");
}

unittest
{
	auto converter = new GatedFakeConverter;
	auto intake = new SubmissionIntake(converter);
	enum secondInput = testHeicBytes ~ "second";
	enum secondJpeg = cast(immutable(ubyte)[]) "\xff\xd8\xff\x02\xff\xd9";
	auto blocks = [testHeicBlock(), ContentBlock("text", "keep this"), testPngBlock,
		testHeicBlock("image/heif", secondInput)];
	auto original = blocks.dup;
	ContentBlock[] result;
	assert(needsNormalization(blocks[$ - 1 .. $]));
	intake.normalize(blocks).then((ContentBlock[] normalized) {
		result = normalized;
	}, (Exception error) { assert(false, error.msg); }).ignoreResult();
	drainNextTicks();
	assert(converter.inputs == [cast(immutable(ubyte)[]) testHeicBytes]);
	converter.gates[0].fulfill(testJpegBytes);
	drainNextTicks();
	assert(result is null && converter.inputs.length == 2
		&& converter.inputs[1] == cast(immutable(ubyte)[]) secondInput);
	converter.gates[1].fulfill(secondJpeg);
	drainNextTicks();
	assert(result.length == blocks.length && blocks == original);
	assert(result[0] == ContentBlock(type: "image", data: Base64.encode(testJpegBytes),
		media_type: "image/jpeg"));
	assert(result[1 .. 3] == original[1 .. 3]);
	assert(result[3] == ContentBlock(type: "image", data: Base64.encode(secondJpeg),
		media_type: "image/jpeg"));
}

unittest
{
	import cydo.runtime.image.bounded_filter : FilterFailureKind;

	// The failing image is index 1 whether the preceding image needed conversion or not.
	foreach (first; [testHeicBlock(), testPngBlock])
	{
		auto converter = new GatedFakeConverter;
		auto intake = new SubmissionIntake(converter);
		AttachmentRejection refusal;
		intake.submit(1, [first, ContentBlock("text", "between images"), testHeicBlock()],
			(ContentBlock[]) { assert(false, "Partially converted submission accepted"); },
			(AttachmentRejection error) { refusal = error; });
		drainNextTicks();
		assert(converter.gates.length == 1 && refusal is null);
		if (first.media_type == "image/heic")
		{
			converter.gates[0].fulfill(testJpegBytes);
			drainNextTicks();
			assert(converter.gates.length == 2 && refusal is null);
		}
		converter.gates[$ - 1].reject(new FilterFailure(FilterFailureKind.timedOut));
		drainNextTicks();
		assert(refusal !is null && refusal.attachment == 1 && refusal.msg == "timed out");
	}
}
