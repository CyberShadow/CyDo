"""Report observable filesystem and network access from the converter process."""

import errno
import json
import mmap
import os
import resource
import socket
import sys
import tempfile
from pathlib import Path


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
            path for path in ("/etc/passwd", "/home", "/run", "/sys")
            if os.path.lexists(path)
        ],
        "store_write_errno": error_number(lambda: write_tempfile("/nix/store")),
        "closure_read_only": bool(os.statvfs(python_output).f_flag & os.ST_RDONLY),
        "tmp_write_ok": error_number(lambda: write_tempfile("/tmp")) is None,
        "root_entries": sorted(os.listdir("/")),
        "proc_pids": sorted(int(n) for n in os.listdir("/proc") if n.isdigit()),
    }
    isolated = (
        report["marker_errno"] == errno.ENOENT
        and report["loopback_errno"] in {errno.ECONNREFUSED, errno.ENETUNREACH}
        and report["lookup_failed"]
        and report["visible_host_paths"] == []
        and report["store_write_errno"] in {errno.EROFS, errno.EACCES}
        and report["closure_read_only"]
        and report["tmp_write_ok"]
        and report["root_entries"] == ["nix", "proc", "tmp"]
        and report["proc_pids"] == [1, os.getpid()]
    )
    if not isolated:
        raise RuntimeError(json.dumps(report))


if __name__ == "__main__":
    executable = Path(sys.argv[0])
    if executable.name == "jpegtran-invalid":
        sys.stdin.buffer.read()
        sys.stdout.buffer.write(b"not a JPEG")
        print("image-jail: cleaner emitted invalid JPEG", file=sys.stderr)
        sys.exit(0)

    source, destination = map(Path, sys.argv[-2:])
    _, _, control = source.read_bytes().partition(b"\0probe:")
    if executable.name.endswith("-fail-startup"):
        phase = "attempted stdin conversion" if control else "rejected startup probe"
        print(f"image-jail: {phase}", file=sys.stderr)
        sys.exit(1)
    if executable.name == "heif-dec-empty":
        print("image-jail: decoder emitted no JPEG", file=sys.stderr)
        print("padding\n" * 1024 + "image-jail: end of decoder stderr", file=sys.stderr)
        sys.exit(0)
    if control == b"allocate":
        limit, _ = resource.getrlimit(resource.RLIMIT_AS)
        if limit == 1024**3 and error_number(lambda: mmap.mmap(-1, 2 * 1024**3)) == errno.ENOMEM:
            print("image-jail: RLIMIT_AS=1073741824, 2 GiB mmap returned ENOMEM", file=sys.stderr)
            sys.exit(1)
    elif control:
        marker, port = json.loads(control)
        check_isolation(marker, int(port))
    destination.write_bytes(executable.with_name("colors.jpg").read_bytes())
