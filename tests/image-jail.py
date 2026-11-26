"""Exercise HEIC conversion and its real Bubblewrap jail through CyDo."""

import errno
import json
import os
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
        self.probe = [
            str(Path(sys.executable).resolve()),
            os.environ["CYDO_IMAGE_JAIL_PROBE"],
        ]

    def convert(self, data, probe_args=None, *, preload=None, probe_input=None):
        env = os.environ.copy()
        env.pop("CYDO_HEIC_CONVERTER", None)
        if preload is not None:
            env["LD_PRELOAD"] = preload
        if probe_args is not None:
            probe_path = FIXTURE
            if probe_input is not None:
                probe_path = self.directory / "startup-input"
                probe_path.write_bytes(probe_input)
            manifest = self.directory / "probe.json"
            manifest.write_text(json.dumps({
                "argv": [*self.probe, *probe_args],
                "env": {},
                "store_paths": env["CYDO_IMAGE_JAIL_PROBE_PATHS"],
                "probe_input": str(probe_path),
            }))
            env["CYDO_HEIC_CONVERTER"] = str(manifest)
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

    def test_jail_denies_host_access(self):
        with self.host_resources() as args:
            result = self.convert(self.fixture, args)
        self.assert_exit(result, 0)
        self.assertTrue(result.stdout.startswith(JPEG_PREFIX))
        report = json.loads(result.stdout[len(JPEG_PREFIX):])
        self.assertEqual(report["marker_errno"], errno.ENOENT)
        self.assertIn(report["loopback_errno"], {errno.ECONNREFUSED, errno.ENETUNREACH})
        self.assertTrue(report["lookup_failed"])
        self.assertEqual(report["visible_host_paths"], [])
        self.assertIn(report["store_write_errno"], {errno.EROFS, errno.EACCES})
        self.assertTrue(report["closure_read_only"])
        self.assertTrue(report["tmp_write_ok"])
        self.assertEqual(report["root_entries"], ["nix", "tmp"])

    def test_probe_can_access_host_resources_directly(self):
        with self.host_resources() as args:
            result = subprocess.run(
                [*self.probe, *args], capture_output=True, timeout=TIMEOUT,
            )
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        report = json.loads(result.stderr)
        self.assertIsNone(report["marker_errno"])
        self.assertIsNone(report["loopback_errno"])

    def test_helper_closes_stdin_with_input_pending(self):
        result = self.convert(
            self.fixture.ljust(4 * 1024**2, b"\0"),
            ["--close-stdin"],
            preload=os.environ["CYDO_IMAGE_JAIL_PIPE_PROBE"],
            probe_input=b"P",
        )
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"image-jail: queued write returned EPIPE", result.stderr.splitlines())
        self.assertEqual(result.stderr.splitlines()[-1:], [b"conversion failed"])

    def test_jail_rejects_two_gib_allocation(self):
        result = self.convert(self.fixture, ["--allocate"], probe_input=b"P")
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr.splitlines()[-1:], [b"conversion failed"])

    def test_failed_startup_probe_prevents_stdin_conversion(self):
        result = self.convert(self.fixture, ["--fail-startup"], probe_input=b"P")
        self.assert_exit(result, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"image-jail: rejected startup probe", result.stderr)
        self.assertNotIn(b"image-jail: attempted stdin conversion", result.stderr)
        self.assertEqual(
            result.stderr.splitlines()[-1:],
            [b"HEIC converter self-check failed: conversion failed"],
        )


if __name__ == "__main__":
    CYDO = sys.argv.pop(1)
    FIXTURE = Path(sys.argv.pop(1)).resolve()
    unittest.main(verbosity=2)
