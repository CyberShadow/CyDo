"""Exercise HEIC conversion and its real Bubblewrap jail through CyDo."""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path


TIMEOUT = 40
JPEG_PREFIX = b"\xff\xd8\xff"


def jpeg_dimensions(jpeg):
    # Before the scan, JPEG segments are length-prefixed. The SOF segment
    # stores the height followed by the width, after the sample precision.
    offset = 2
    while offset < len(jpeg) and jpeg[offset] == 0xFF:
        marker = jpeg[offset + 1]
        offset += 2
        if marker == 0xFF:
            offset -= 1
            continue
        size = int.from_bytes(jpeg[offset:offset + 2], "big")
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
            height = int.from_bytes(jpeg[offset + 3:offset + 5], "big")
            width = int.from_bytes(jpeg[offset + 5:offset + 7], "big")
            return width, height
        if marker in {0xD9, 0xDA} or size < 2:
            break
        offset += size
    raise AssertionError("JPEG has no start-of-frame segment")


class ImageJailTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FIXTURE.read_bytes()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.config = self.directory / "config"
        self.config.mkdir()

    def convert(self, data, *, omit=None, probe=None, cleaner=None, sandbox=True):
        env = os.environ.copy()
        env["HOME"] = str(self.config)
        path = self.directory / "bin"
        path.mkdir(exist_ok=True)
        for name in ("heif-dec", "jpegtran", "bwrap"):
            link = path / name
            link.unlink(missing_ok=True)
            if name != omit:
                tool = {"heif-dec": probe, "jpegtran": cleaner}.get(name) or shutil.which(name)
                link.symlink_to(tool)
        env["PATH"] = str(path)
        if not sandbox:
            config = self.config / ".config" / "cydo"
            config.mkdir(parents=True, exist_ok=True)
            (config / "config.yaml").write_text(
                "workspaces: {}\nsandbox:\n  isolate_filesystem: false\n  isolate_processes: false\n"
            )
        return subprocess.run(
            [CYDO, "convert-image"], input=data, capture_output=True,
            env=env, timeout=TIMEOUT,
        )

    def assert_exit(self, process, expected):
        self.assertEqual(process.returncode, expected, process.stderr.decode(errors="replace"))

    @contextmanager
    def host_resources(self):
        marker = self.directory / "host-marker"
        marker.write_text("host marker")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            yield str(marker), str(listener.getsockname()[1])

    def test_converts_heic_to_jpeg(self):
        result = self.convert(self.fixture)
        self.assert_exit(result, 0)
        self.assertTrue(result.stdout.startswith(JPEG_PREFIX))
        self.assertEqual(jpeg_dimensions(result.stdout), (64, 48))

    def test_runs_decoder_from_tmp(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            decoder = Path(directory) / "heif-dec"
            shutil.copy2(self.probe("static-decoder"), decoder)
            self.assertTrue(decoder.resolve().is_relative_to("/tmp"))
            result = self.convert(self.fixture, probe=decoder)
        self.assert_exit(result, 0)
        self.assertEqual(jpeg_dimensions(result.stdout), (64, 48))

    def test_refuses_non_heic(self):
        avif = bytearray(self.fixture)
        avif[8:12] = b"avif"
        avif[20:24] = b"avif"
        for kind, data in {
            "PNG": b"\x89PNG\r\n\x1a\n",
            "AVIF": avif,
        }.items():
            with self.subTest(kind=kind):
                result = self.convert(data)
                self.assert_exit(result, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr.strip(), b"not a HEIC/HEIF still image")

    def test_missing_tools_are_named(self):
        for name in ("heif-dec", "jpegtran", "bwrap"):
            with self.subTest(name=name):
                result = self.convert(self.fixture, omit=name)
                self.assert_exit(result, 1)
                self.assertIn(f"requires {name} on PATH".encode(), result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_direct_works_without_bwrap(self):
        result = self.convert(self.fixture, omit="bwrap", sandbox=False)
        self.assert_exit(result, 0)
        self.assertEqual(jpeg_dimensions(result.stdout), (64, 48))

    def test_rejects_multi_image_heic(self):
        data = self.probe("multi.heic").read_bytes()
        for sandbox in (True, False):
            with self.subTest(sandbox=sandbox):
                result = self.convert(data, sandbox=sandbox)
                self.assert_exit(result, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(
                    result.stderr.splitlines()[-1:], [b"multi-image HEIC is not supported"],
                )

    def probe(self, name="heif-dec"):
        return Path(os.environ["CYDO_IMAGE_JAIL_PROBE"]) / name

    def test_jail_denies_host_access(self):
        with self.host_resources() as args:
            payload = self.fixture + b"\0probe:" + json.dumps(args).encode()
            result = self.convert(payload, probe=self.probe())
        self.assert_exit(result, 0)
        self.assertEqual(jpeg_dimensions(result.stdout), (64, 48))

    def test_jail_rejects_two_gib_allocation(self):
        result = self.convert(self.fixture + b"\0probe:allocate", probe=self.probe())
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr.splitlines()[-1:], [b"conversion failed"])
        self.assertIn(
            b"image-jail: RLIMIT_AS=1073741824, 2 GiB mmap returned ENOMEM",
            result.stderr,
        )

    def assert_startup_failure(self, result, stage, stderr):
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        _, prefix, diagnostic = result.stderr.partition(b"HEIC converter self-check failed: ")
        self.assertTrue(prefix, result.stderr)
        self.assertIn(stage, diagnostic)
        self.assertIn(stderr, diagnostic)

    def test_startup_reports_empty_decoder_output_with_bounded_stderr(self):
        result = self.convert(self.fixture, probe=self.probe("heif-dec-empty"))
        self.assert_startup_failure(
            result, b"heif-dec uses libde265: empty JPEG output: exit status 0",
            b"image-jail: decoder emitted no JPEG",
        )
        self.assertNotIn(b"image-jail: end of decoder stderr", result.stderr)

    def test_startup_reports_invalid_cleaner_output(self):
        result = self.convert(self.fixture, cleaner=self.probe("jpegtran-invalid"))
        self.assert_startup_failure(
            result, b"jpegtran: invalid JPEG output: exit status 0",
            b"image-jail: cleaner emitted invalid JPEG",
        )

    def test_failed_startup_probe_prevents_stdin_conversion(self):
        result = self.convert(self.fixture + b"\0probe:unexpected",
                              probe=self.probe("heif-dec-fail-startup"))
        self.assertNotIn(b"image-jail: attempted stdin conversion", result.stderr)
        self.assert_startup_failure(
            result, b"heif-dec uses libde265: exit status 1",
            b"image-jail: rejected startup probe",
        )


if __name__ == "__main__":
    CYDO = sys.argv.pop(1)
    FIXTURE = Path(sys.argv.pop(1)).resolve()
    unittest.main(verbosity=2)
