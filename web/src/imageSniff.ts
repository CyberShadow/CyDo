const HEADER_BYTES = 4096;
const HEIC_STILL_BRANDS = new Set(["heic", "heix", "heim", "heis"]);

export function isHeicType(type: string) {
  return type === "image/heic" || type === "image/heif";
}

export async function sniffImageType(file: File) {
  const buffer = await new Promise<ArrayBuffer | undefined>((resolve) => {
    const reader = new FileReader();
    reader.onload = () => {
      resolve(reader.result as ArrayBuffer);
    };
    reader.onerror = reader.onabort = () => {
      resolve(undefined);
    };
    reader.readAsArrayBuffer(file.slice(0, HEADER_BYTES));
  });
  if (buffer === undefined) return undefined;
  const head = new Uint8Array(buffer);

  if ([0xff, 0xd8, 0xff].every((byte, i) => head[i] === byte))
    return "image/jpeg";
  if (
    [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10].every(
      (byte, i) => head[i] === byte,
    )
  )
    return "image/png";

  const ascii = (start: number, end: number) =>
    String.fromCharCode(...head.subarray(start, end));
  const gif = ascii(0, 6);
  if (gif === "GIF87a" || gif === "GIF89a") return "image/gif";
  if (ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "image/webp";

  if (head.length < 16 || ascii(4, 8) !== "ftyp") return null;
  const size = new DataView(head.buffer).getUint32(0);
  if (size < 16 || size > head.length || size % 4 !== 0) return null;

  let still = false;
  for (let offset = 8; offset < size; offset += offset === 8 ? 8 : 4) {
    const brand = ascii(offset, offset + 4);
    if (brand === "avif" || brand === "avis") return null;
    if (HEIC_STILL_BRANDS.has(brand)) still = true;
  }
  return still ? "image/heic" : null;
}
