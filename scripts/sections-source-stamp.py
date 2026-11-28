#!/usr/bin/env python3
"""Review-only candidate: bounded clean-source snapshot stamp for Sections builds.

Invoked by proposed per-target build phases, not run during preparation.
Both targets compile their source stamp through a generated header.
This observes source for attribution; it does not attest the compiler or kernel.
"""
import errno
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


VISIBILITY_SECONDS = 0.25
VISIBILITY_ROLES = (("head", "HEAD"), ("refs", "refs"),
                    ("packed_refs", "packed-refs"), ("objects", "objects"),
                    ("config", "config"), ("index", "index"))
VISIBILITY_ENV = (("git_dir_set", "GIT_DIR"),
                  ("work_tree_set", "GIT_WORK_TREE"),
                  ("common_dir_set", "GIT_COMMON_DIR"),
                  ("ceiling_set", "GIT_CEILING_DIRECTORIES"),
                  ("cross_filesystem_set", "GIT_DISCOVERY_ACROSS_FILESYSTEM"))


def visibility_error(error):
    if error.errno in (errno.EACCES, errno.EPERM):
        return "denied"
    if error.errno in (errno.ENOENT, errno.ENOTDIR):
        return "missing"
    if error.errno == errno.ELOOP:
        return "symlink_refused"
    return "other_error"


def git_visibility(root, deadline):
    # Fixed roles only. No directory listing, file data, paths or env values
    # are retained. This deadline stops new probes, not in-flight OS calls.
    records = {role: {"kind": "unknown", "stat": "not_attempted",
                      "open": "not_attempted"}
               for role in ("metadata", *(role for role, _ in VISIBILITY_ROLES))}
    result = {"roles": records,
              "env_presence": {role: name in os.environ for role, name in VISIBILITY_ENV}}

    def entry(role, name, parent=None, retain=False):
        record = records[role]
        if time.monotonic() >= deadline:
            record["stat"] = "budget_exhausted"
            return None
        try:
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            record["stat"] = visibility_error(error)
            return None
        record["stat"] = "ok"
        mode = before.st_mode
        record["kind"] = ("symlink" if stat.S_ISLNK(mode) else
                          "directory" if stat.S_ISDIR(mode) else
                          "regular" if stat.S_ISREG(mode) else "other")
        if stat.S_ISLNK(mode):
            record["open"] = "symlink_refused"
            return None
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            record["open"] = "wrong_type"
            return None
        if time.monotonic() >= deadline:
            record["open"] = "budget_exhausted"
            return None
        descriptor = None
        try:
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if stat.S_ISDIR(mode):
                flags |= os.O_DIRECTORY
            descriptor = os.open(name, flags, dir_fd=parent)
            after = os.fstat(descriptor)
            if (before.st_dev, before.st_ino, before.st_mode) != (
                    after.st_dev, after.st_ino, after.st_mode):
                record["open"] = "changed"
                return None
            record["open"] = "opened"
            if retain and stat.S_ISDIR(after.st_mode):
                owned = descriptor
                descriptor = None
                return owned
        except OSError as error:
            record["open"] = visibility_error(error)
        finally:
            if descriptor is not None:
                os.close(descriptor)
        return None

    descriptor = entry("metadata", root / ".git", retain=True)
    if descriptor is not None:
        try:
            for role, name in VISIBILITY_ROLES:
                entry(role, name, parent=descriptor)
        finally:
            os.close(descriptor)
    return result


def observed_git_visibility(root, deadline=None):
    # Best-effort observation never overrides snapshot admission. Its time
    # consumes the caller's existing snapshot elapsed window when provided.
    checked_deadline = time.monotonic() + VISIBILITY_SECONDS
    if deadline is not None:
        checked_deadline = min(checked_deadline, deadline)
    try:
        return git_visibility(root, checked_deadline)
    except Exception:
        return {"status": "unavailable"}


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
        record["git_visibility"] = observed_git_visibility(root)
        record["status"] = status_summary(git(root, "status", "--porcelain=v1",
                                               "--untracked-files=normal"))
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError) as error:
        record.update(error_summary(error))
    emit_observation(record)


def snapshot(root, observation=None):
    observation = {} if observation is None else observation
    started = time.monotonic()
    observation["git_visibility"] = observed_git_visibility(root, started + MAX_SECONDS)
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


METADATA_MAX_ENTRIES = 2048
METADATA_MAX_DEPTH = 32
METADATA_MAX_SECONDS = 15
METADATA_OUTPUT = "sections-proof-git-metadata.xcfilelist"
METADATA_ROLES = (("HEAD", "file", True), ("config", "file", True),
                  ("index", "file", True), ("refs", "directory", True),
                  ("objects", "directory", True),
                  ("config.worktree", "file", False),
                  ("packed-refs", "file", False), ("shallow", "file", False),
                  ("info", "directory", False))


def metadata_input_lines(root):
    # Explicit proof preparation only. No file contents, Git execution or
    # grants outside this checkout. This is not a sealed metadata snapshot.
    root = Path(root).resolve(strict=True)
    started = time.monotonic()
    entries = 1
    paths = {"$(SRCROOT)/.git"}
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK

    def check_bound():
        if time.monotonic() - started > METADATA_MAX_SECONDS:
            raise ValueError("metadata elapsed bound")

    def same_identity(before, after):
        return (before.st_dev, before.st_ino, before.st_mode) == (
            after.st_dev, after.st_ino, after.st_mode)

    def visit(parent, name, relative, expected=None, required=True, depth=0):
        nonlocal entries
        check_bound()
        entries += 1
        if entries > METADATA_MAX_ENTRIES or depth > METADATA_MAX_DEPTH:
            raise ValueError("metadata inventory bound")
        if name in (".", "..") or re.fullmatch(r"[A-Za-z0-9._-]+", name) is None:
            raise ValueError("unsafe metadata component")
        if relative in ("objects/info/alternates", "objects/info/http-alternates"):
            raise ValueError("external object store unsupported")
        try:
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            if not required:
                return
            raise ValueError("required metadata missing") from None
        kind = ("directory" if stat.S_ISDIR(before.st_mode) else
                "file" if stat.S_ISREG(before.st_mode) else "other")
        if kind == "other" or (expected is not None and kind != expected):
            raise ValueError("metadata type refused")
        paths.add("$(SRCROOT)/.git/" + relative)
        if kind == "directory":
            descriptor = os.open(name, directory_flags, dir_fd=parent)
            try:
                if not same_identity(before, os.fstat(descriptor)):
                    raise ValueError("metadata directory changed")
                if relative == "info":
                    # status can consult these two fixed per-repository files.
                    # No recursive grant for unrelated info-directory data.
                    for child in ("exclude", "attributes"):
                        visit(descriptor, child, relative + "/" + child,
                              "file", False, depth + 1)
                else:
                    with os.scandir(descriptor) as children:
                        for child in children:
                            visit(descriptor, child.name, relative + "/" + child.name,
                                  depth=depth + 1)
                after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if not same_identity(before, after):
                    raise ValueError("metadata directory changed")
            finally:
                os.close(descriptor)

    root_descriptor = os.open(root, directory_flags)
    try:
        before = os.stat(".git", dir_fd=root_descriptor, follow_symlinks=False)
        metadata = os.open(".git", directory_flags, dir_fd=root_descriptor)
        try:
            if not same_identity(before, os.fstat(metadata)):
                raise ValueError("metadata root changed")
            try:
                os.stat("commondir", dir_fd=metadata, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("shared metadata unsupported")
            for name, expected, required in METADATA_ROLES:
                visit(metadata, name, name, expected, required)
            after = os.stat(".git", dir_fd=root_descriptor, follow_symlinks=False)
            if not same_identity(before, after):
                raise ValueError("metadata root changed")
            check_bound()
        finally:
            os.close(metadata)
    finally:
        os.close(root_descriptor)
    result = sorted(paths)
    if len(("\n".join(result) + "\n").encode("utf-8")) > MAX_OUTPUT:
        raise ValueError("metadata output bound")
    return result


def prepare_git_metadata_inputs(root=None):
    root = (Path.cwd() if root is None else Path(root)).resolve(strict=True)
    lines = metadata_input_lines(root)
    text = "\n".join(lines) + "\n"
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
    root_descriptor = os.open(root, directory_flags)
    try:
        try:
            os.mkdir(".build", mode=0o700, dir_fd=root_descriptor)
        except FileExistsError:
            pass
        build = os.open(".build", directory_flags, dir_fd=root_descriptor)
        try:
            descriptor = os.open(METADATA_OUTPUT,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK,
                0o600, dir_fd=build)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(text)
                stream.flush()
                os.fsync(stream.fileno())
        finally:
            os.close(build)
    finally:
        os.close(root_descriptor)
    return {"entries": len(lines), "bytes": len(text.encode("utf-8"))}


def replace_generated_metadata_inputs(root=None):
    # Repeatable preparation for the documented build script. Removes only the
    # one generated list this script writes: a regular file directly under
    # .build, never followed through a symlink. Anything else is left alone and
    # the exclusive create below then refuses.
    root = (Path.cwd() if root is None else Path(root)).resolve(strict=True)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
    root_descriptor = os.open(root, directory_flags)
    try:
        try:
            build = os.open(".build", directory_flags, dir_fd=root_descriptor)
        except FileNotFoundError:
            build = None
        if build is not None:
            try:
                try:
                    existing = os.stat(METADATA_OUTPUT, dir_fd=build, follow_symlinks=False)
                except FileNotFoundError:
                    existing = None
                if existing is not None and stat.S_ISREG(existing.st_mode):
                    os.unlink(METADATA_OUTPUT, dir_fd=build)
            finally:
                os.close(build)
    finally:
        os.close(root_descriptor)
    return prepare_git_metadata_inputs(root)


if __name__ == "__main__":
    if sys.argv[1:] == ["--replace-generated-metadata-inputs"]:
        try:
            result = replace_generated_metadata_inputs()
        except (OSError, ValueError):
            emit_observation({"kind": "metadata_input_preparation", "status": "unavailable"})
            raise SystemExit(1) from None
        emit_observation({"kind": "metadata_input_preparation", "status": "prepared", **result})
    elif sys.argv[1:] == ["--prepare-git-metadata-inputs"]:
        try:
            result = prepare_git_metadata_inputs()
        except (OSError, ValueError):
            emit_observation({"kind": "metadata_input_preparation", "status": "unavailable"})
            raise SystemExit(1) from None
        emit_observation({"kind": "metadata_input_preparation", "status": "prepared", **result})
    elif sys.argv[1:] in (["--observe-build-state", "before_build"],
                        ["--observe-build-state", "after_build"]):
        observe_build_state(sys.argv[2])
    else:
        main()
