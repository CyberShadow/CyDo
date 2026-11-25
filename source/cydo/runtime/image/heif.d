module cydo.runtime.image.heif;

bool isHeifStill(const(ubyte)[] head)
{
	if (head.length < 16)
		return false;

	const size = (cast(uint) head[0] << 24) | (cast(uint) head[1] << 16)
		| (cast(uint) head[2] << 8) | head[3];
	if (size < 16 || size > 4096 || size > head.length || size % 4 != 0
		|| cast(const(char)[]) head[4 .. 8] != "ftyp")
		return false;

	bool still;
	for (size_t offset = 8; offset < size; offset += offset == 8 ? 8 : 4)
	{
		switch (cast(const(char)[]) head[offset .. offset + 4])
		{
		case "avif", "avis": return false;
		case "heic", "heix", "heim", "heis": still = true; break;
		default: break;
		}
	}
	return still;
}

unittest
{
	// The ftyp box from tests/data/colors.heic. The backend source omits fixtures.
	enum fixtureHeader = "\x00\x00\x00\x1cftypheic\x00\x00\x00\x00mif1heicmiaf";
	assert(isHeifStill(cast(const(ubyte)[]) fixtureHeader));
	assert(isHeifStill(cast(const(ubyte)[]) "\x00\x00\x00\x14ftypmif1\x00\x00\x00\x00heic"));
	foreach (brand; ["heix", "heim", "heis"])
		assert(isHeifStill(cast(const(ubyte)[]) ("\x00\x00\x00\x10ftyp" ~ brand ~ "\x00\x00\x00\x00")), brand);
}

unittest
{
	foreach (brands; ["avif....heic", "heic....avif", "avis....heic", "heic....avis", "hevc....msf1"])
		assert(!isHeifStill(cast(const(ubyte)[]) ("\x00\x00\x00\x14ftyp" ~ brands)), brands);
	assert(!isHeifStill(cast(const(ubyte)[]) "\x00\x00\x00\x10ftypmif1\x00\x00\x00\x00"));
	assert(!isHeifStill(cast(const(ubyte)[]) "\xff\xd8\xff\xe0............"));
	assert(!isHeifStill(cast(const(ubyte)[]) "\x89PNG\r\n\x1a\n........"));
}

unittest
{
	enum header = "\x00\x00\x00\x14ftypheic\x00\x00\x00\x00mif1";
	assert(!isHeifStill(cast(const(ubyte)[]) header[0 .. 15]));
	assert(!isHeifStill(cast(const(ubyte)[]) header[0 .. 19]));
	assert(!isHeifStill(cast(const(ubyte)[]) "\x00\x00\x00\x10freeheic\x00\x00\x00\x00"));

	// Each malformed size has enough backing bytes except the declared size of 24.
	foreach (size; [0, 1, 12, 17, 24])
	{
		auto box = cast(ubyte[]) header.dup;
		box[3] = cast(ubyte) size;
		assert(!isHeifStill(box));
	}

	ubyte[4100] oversized;
	oversized[0 .. 16] = cast(const(ubyte)[]) "\x00\x00\x10\x04ftypheic\x00\x00\x00\x00";
	assert(!isHeifStill(oversized));
}
