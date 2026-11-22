#!/usr/bin/env python3
"""Review-only candidate: bounded clean-source snapshot stamp for Sections builds.

Invoked by proposed per-target build phases, not run during preparation.
Both targets compile their source stamp through a generated header.
This observes source for attribution; it does not attest the compiler or kernel.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

MAX_FILES = 2048
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024
MAX_OUTPUT = 256 * 1024
MAX_SECONDS = 15


def git(root, *arguments):
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(root), *arguments],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if len(result.stdout) > MAX_OUTPUT:
        raise ValueError("git output exceeds stamp bound")
    return result.stdout


def snapshot(root):
    started = time.monotonic()
    revision = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("unsupported revision format")
    if git(root, "status", "--porcelain=v1", "--untracked-files=normal"):
        raise ValueError("source is not clean")
    paths = git(root, "ls-files", "-z").split(b"\0")
    paths = sorted(path for path in paths if path)
    if not paths or len(paths) > MAX_FILES:
        raise ValueError("source file count outside bound")
    declared = (root / "scripts/sections-stamp-inputs.xcfilelist").read_text().splitlines()
    expected = ["$(SRCROOT)/" + os.fsdecode(path) for path in paths]
    if declared != expected:
        raise ValueError("tracked source differs from declared build inputs")
    digest = hashlib.sha256()
    total = 0
    for name in paths:
        if time.monotonic() - started > MAX_SECONDS:
            raise ValueError("source stamp elapsed budget exceeded")
        relative = Path(os.fsdecode(name))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("invalid tracked path")
        path = root / relative
        # Reject symlinked parent components, not only the final component.
        cursor = root
        for component in relative.parts[:-1]:
            cursor = cursor / component
            if not stat.S_ISDIR(cursor.lstat().st_mode):
                raise ValueError("non-directory source ancestor")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE:
                raise ValueError("source file type or size outside bound")
            total += before.st_size
            if total > MAX_TOTAL:
                raise ValueError("total source size outside bound")
            content = hashlib.sha256()
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    raise ValueError("source truncated during stamp")
                content.update(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise ValueError("source grew during stamp")
            after = os.fstat(descriptor)
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
            ):
                raise ValueError("source changed during stamp")
        finally:
            os.close(descriptor)
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update((before.st_mode & 0o777).to_bytes(2, "big"))
        digest.update(content.digest())
    if git(root, "status", "--porcelain=v1", "--untracked-files=normal"):
        raise ValueError("source changed while stamping")
    if git(root, "rev-parse", "--verify", "HEAD").decode().strip() != revision:
        raise ValueError("revision changed while stamping")
    return {"schema": 1, "revision": revision, "manifestSHA256": digest.hexdigest(),
            "files": len(paths), "sourceBytes": total, "claim": "clean source snapshot"}


def main():
    observed = None
    required = os.environ.get("ARX_SECTIONS_ATTRIBUTION") == "YES"
    if required:
        try:
            observed = snapshot(Path(os.environ["SRCROOT"]).resolve(strict=True))
        except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
            # Ordinary compilation is not made conditional on source cleanliness.
            # Unverified attribution is represented by empty compiled fields.
            observed = None
    revision = observed["revision"] if observed else ""
    manifest = observed["manifestSHA256"] if observed else ""
    destination = Path(os.environ["DERIVED_FILE_DIR"]) / "ArxSectionsBuildStamp.h"
    header = ("// Generated source attribution, empty means unavailable.\n"
              "#define ARX_SECTIONS_SOURCE_REVISION @\"" + revision + "\"\n"
              "#define ARX_SECTIONS_SOURCE_MANIFEST @\"" + manifest + "\"\n"
              "#define ARX_SECTIONS_REQUIRES_ATTRIBUTION " + ("1" if required else "0") + "\n")
    # The only file written is the explicitly declared build output. A failed
    # or interrupted write fails this script/compile, never emits a valid stamp.
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(header)
        stream.flush()
        os.fsync(stream.fileno())


if __name__ == "__main__":
    main()
