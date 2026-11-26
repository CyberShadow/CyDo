/** @vitest-environment jsdom */
import { expect, it } from "vitest";
import { sniffImageType } from "./imageSniff";

function ftyp(major: string, compatible = "", size = 16 + compatible.length) {
  return new Uint8Array([
    0,
    0,
    0,
    size,
    ...new TextEncoder().encode(`ftyp${major}\0\0\0\0${compatible}`),
  ]);
}

it.each([
  ["JPEG", new Uint8Array([0xff, 0xd8, 0xff]), "image/jpeg"],
  [
    "PNG",
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]),
    "image/png",
  ],
  ["GIF87a", "GIF87a", "image/gif"],
  ["GIF89a", "GIF89a", "image/gif"],
  ["WebP", "RIFF\x04\0\0\0WEBP", "image/webp"],
  ["HEIC major brand", ftyp("heic"), "image/heic"],
  ["HEIC compatible brand", ftyp("mif1", "heic"), "image/heic"],
  ["HEIX major brand", ftyp("heix"), "image/heic"],
] as const)("recognizes %s from its bytes", async (_, bytes, expected) => {
  expect(await sniffImageType(new File([bytes], "untyped.bin"))).toBe(expected);
});

it.each([
  ["AVIF", ftyp("avif", "heic")],
  ["AVIF compatible brand", ftyp("heic", "avis")],
  ["sequence-only HEIF", ftyp("msf1", "hevc")],
  ["truncated ftyp", ftyp("heic", "", 20)],
  ["misaligned ftyp", ftyp("heic", "x")],
  ["unrecognized bytes", "this is an unknown format"],
  ["short ftyp", ftyp("heic").slice(0, 11)],
] as const)("returns null for %s", async (_, bytes) => {
  expect(await sniffImageType(new File([bytes], "photo.heic"))).toBeNull();
});
