"""Report observable filesystem and network access from the converter process."""

import errno
import json
import mmap
import os
import socket
import sys
import tempfile
import time
from pathlib import Path


JPEG_PREFIX = b"\xff\xd8\xff"


def error_number(operation):
    try:
        operation()
    except OSError as error:
        return error.errno
    return None


def connect(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2):
        pass


def lookup_failed():
    try:
        socket.getaddrinfo("example.com", 80)
    except socket.gaierror:
        return True
    return False


def write_tempfile(directory):
    with tempfile.NamedTemporaryFile(dir=directory) as output:
        output.write(b"probe")
        output.flush()


def check_isolation(marker, port):
    python_output = Path(sys.executable).parent.parent
    report = {
        "marker_errno": error_number(Path(marker).read_bytes),
        "loopback_errno": error_number(lambda: connect(port)),
        "lookup_failed": lookup_failed(),
        "visible_host_paths": [
            path for path in ("/etc/passwd", "/home", "/proc/self")
            if os.path.lexists(path)
        ],
        "store_write_errno": error_number(lambda: write_tempfile("/nix/store")),
        "closure_read_only": bool(os.statvfs(python_output).f_flag & os.ST_RDONLY),
        "tmp_write_ok": error_number(lambda: write_tempfile("/tmp")) is None,
        "root_entries": sorted(os.listdir("/")),
    }
    isolated = (
        report["marker_errno"] == errno.ENOENT
        and report["loopback_errno"] in {errno.ECONNREFUSED, errno.ENETUNREACH}
        and report["lookup_failed"]
        and report["visible_host_paths"] == []
        and report["store_write_errno"] in {errno.EROFS, errno.EACCES}
        and report["closure_read_only"]
        and report["tmp_write_ok"]
        and report["root_entries"] == ["nix", "tmp"]
    )
    if isolated:
        sys.stdout.buffer.write(JPEG_PREFIX + json.dumps(report).encode())
        return 0
    print(json.dumps(report), file=sys.stderr)
    return 1


def allocate_memory():
    # A mapping reserves address space without committing 2 GiB of RAM on
    # a regression. If it succeeds, the converter will accept this output.
    with mmap.mmap(-1, 2 * 1024**3):
        sys.stdout.buffer.write(JPEG_PREFIX)
    return 0


if __name__ == "__main__":
    mode = sys.argv[1:]
    if mode in (["--allocate"], ["--close-stdin"], ["--fail-startup"]):
        # The manifest's one-byte startup input lets the helper distinguish
        # the phases even when the preload pauses the writer after one byte.
        first = os.read(0, 1)
        if not first:
            sys.exit(2)
        if mode == ["--fail-startup"]:
            diagnostic = (
                "rejected startup probe" if first == b"P" else "attempted stdin conversion"
            )
            print(f"image-jail: {diagnostic}", file=sys.stderr)
            sys.exit(1)
        if first == b"P":
            sys.stdout.buffer.write(JPEG_PREFIX)
            sys.exit(0)
        if mode == ["--allocate"]:
            sys.exit(allocate_memory())
        os.close(0)
        time.sleep(0.2)
        sys.exit(7)
    marker, port = sys.argv[1:]
    sys.exit(check_isolation(marker, int(port)))
