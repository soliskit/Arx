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
import sys
import time

MAX_FILES = 2048
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024
MAX_OUTPUT = 256 * 1024
MAX_SECONDS = 15
GIT_FATAL_SCAN = 4096
GIT_FATAL_CLASSES = (
    # Ordered: specific target signatures before generic errno signatures, so a
    # denied config read reports its config class rather than the bare errno.
    (b"detected dubious ownership", "git_dubious_ownership"),
    (b"unsafe repository", "git_dubious_ownership"),
    (b"unable to read config file", "git_config_unreadable"),
    (b"bad config", "git_config_invalid"),
    (b"not a git repository", "git_not_a_repository"),
    (b"cannot change to", "git_cannot_chdir"),
    (b"Operation not permitted", "git_operation_not_permitted"),
    (b"Permission denied", "git_permission_denied"),
    (b"unable to access", "git_unable_to_access"),
)


def git(root, *arguments):
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(root), *arguments],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if len(result.stdout) > MAX_OUTPUT:
        raise ValueError("git output exceeds stamp bound")
    return result.stdout


def status_summary(status):
    # Never retain or print porcelain operands, untracked names, or contents.
    lines = status.splitlines()
    result = {"entries": len(lines),
              "untracked_entries": sum(line[:2] == b"??" for line in lines),
              "root_lockfile": "not_listed", "workspace_lockfile": "not_listed"}
    roles = {b"Package.resolved": "root_lockfile",
             b"Arx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved":
             "workspace_lockfile"}
    for line in lines:
        if line[3:] in roles:
            code = line[:2].decode("ascii", errors="replace")
            result[roles[line[3:]]] = (code if len(code) == 2 and
                all(c in " MADRCU?!T" for c in code) else "other")
    return result


def git_fatal_summary(error):
    # Fixed labels only: the matched signature class and stderr length, never
    # raw text, paths, operands, or environment values. Matching scans at most
    # the first GIT_FATAL_SCAN bytes; the recorded length is the full count.
    data = error.stderr if isinstance(error.stderr, bytes) else None
    if data is None:
        return {"reason": "git_nonzero", "exit_code": error.returncode,
                "git_fatal_class": "git_stderr_unavailable"}
    summary = {"reason": "git_nonzero", "exit_code": error.returncode,
               "git_stderr_length": len(data)}
    if not data:
        summary["git_fatal_class"] = "git_stderr_empty"
        return summary
    scanned = data[:GIT_FATAL_SCAN]
    for signature, label in GIT_FATAL_CLASSES:
        if signature in scanned:
            summary["git_fatal_class"] = label
            break
    else:
        summary["git_fatal_class"] = "git_fatal_other"
    return summary


def error_summary(error):
    # No exception text, command, raw stderr, source operands, or environment
    # values; captured Git stderr is only classified into fixed labels.
    reasons = {
        "git output exceeds stamp bound": "git_output_bound",
        "unsupported revision format": "revision_format",
        "source is not clean": "source_not_clean",
        "source file count outside bound": "source_count_bound",
        "tracked source differs from declared build inputs": "declared_inputs_mismatch",
        "source stamp elapsed budget exceeded": "elapsed_budget",
        "invalid tracked path": "invalid_tracked_path",
        "non-directory source ancestor": "source_ancestor_type",
        "source file type or size outside bound": "source_type_or_size",
        "total source size outside bound": "source_total_size",
        "source truncated during stamp": "source_truncated",
        "source grew during stamp": "source_grew",
        "source changed during stamp": "source_changed",
        "source changed while stamping": "source_status_changed",
        "revision changed while stamping": "revision_changed",
    }
    if isinstance(error, subprocess.TimeoutExpired):
        return {"reason": "git_timeout"}
    if isinstance(error, subprocess.CalledProcessError):
        return git_fatal_summary(error)
    if isinstance(error, OSError):
        return {"reason": "os_error", "errno": error.errno}
    if isinstance(error, UnicodeError):
        return {"reason": "unicode_error"}
    if isinstance(error, ValueError):
        return {"reason": reasons.get(str(error), "value_error")}
    return {"reason": "subprocess_error"}


def emit_observation(record):
    try:
        print("Sections stamp observation: " + json.dumps(record, sort_keys=True), flush=True)
    except OSError:
        # Diagnostic output failure must not change source admission or header writing.
        pass


def observe_build_state(phase, root=None):
    # Explicit proof-workflow observation only. Not called by ordinary compilation.
    # One existing bounded read-only status command; no file content is printed.
    record = {"kind": "build_state", "phase": phase if phase in
              ("before_build", "after_build") else "other"}
    try:
        root = (Path.cwd() if root is None else root).resolve(strict=True)
        record["status"] = status_summary(git(root, "status", "--porcelain=v1",
                                               "--untracked-files=normal"))
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError) as error:
        record.update(error_summary(error))
    emit_observation(record)


def snapshot(root, observation=None):
    observation = {} if observation is None else observation
    started = time.monotonic()
    observation["stage"] = "revision_before"
    revision = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("unsupported revision format")
    observation["stage"] = "status_before"
    status = git(root, "status", "--porcelain=v1", "--untracked-files=normal")
    observation["status_before"] = status_summary(status)
    if status:
        raise ValueError("source is not clean")
    observation["stage"] = "tracked_paths"
    paths = git(root, "ls-files", "-z").split(b"\0")
    paths = sorted(path for path in paths if path)
    if not paths or len(paths) > MAX_FILES:
        raise ValueError("source file count outside bound")
    observation["stage"] = "declared_inputs"
    declared = (root / "scripts/sections-stamp-inputs.xcfilelist").read_text().splitlines()
    expected = ["$(SRCROOT)/" + os.fsdecode(path) for path in paths]
    if declared != expected:
        raise ValueError("tracked source differs from declared build inputs")
    digest = hashlib.sha256()
    total = 0
    for source_index, name in enumerate(paths, 1):
        observation["stage"] = "source_file"
        observation["source_index"] = source_index
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
    observation.pop("source_index", None)
    observation["stage"] = "status_after"
    status = git(root, "status", "--porcelain=v1", "--untracked-files=normal")
    observation["status_after"] = status_summary(status)
    if status:
        raise ValueError("source changed while stamping")
    observation["stage"] = "revision_after"
    if git(root, "rev-parse", "--verify", "HEAD").decode().strip() != revision:
        raise ValueError("revision changed while stamping")
    observation["stage"] = "complete"
    return {"schema": 1, "revision": revision, "manifestSHA256": digest.hexdigest(),
            "files": len(paths), "sourceBytes": total, "claim": "clean source snapshot"}


def main():
    observed = None
    observation = {"stage": "not_requested"}
    required = os.environ.get("ARX_SECTIONS_ATTRIBUTION") == "YES"
    if required:
        try:
            observation["stage"] = "source_root"
            observed = snapshot(Path(os.environ["SRCROOT"]).resolve(strict=True), observation)
        except (OSError, ValueError, UnicodeError, subprocess.SubprocessError) as error:
            observation.update(error_summary(error))
            # Ordinary compilation is not made conditional on source cleanliness.
            # Unverified attribution is represented by empty compiled fields.
            observed = None
    revision = observed["revision"] if observed else ""
    manifest = observed["manifestSHA256"] if observed else ""
    target = {"Arx": "app", "ArxSectionsWorker": "helper"}.get(
        os.environ.get("TARGET_NAME"), "other")
    emit_observation({"kind": "source_snapshot", "target": target,
                      "required": required, "revision": revision,
                      "manifestSHA256": manifest, "observation": observation})
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
    if sys.argv[1:] in (["--observe-build-state", "before_build"],
                        ["--observe-build-state", "after_build"]):
        observe_build_state(sys.argv[2])
    else:
        main()
