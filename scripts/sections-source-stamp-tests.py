"""Proposed synthetic tests only. Not imported or run during preparation."""
import importlib.util
import contextlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


class SourceStampTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="sections-stamp-fixture-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        (self.root / "source.txt").write_text("fixture\n")
        (self.root / "scripts").mkdir()
        (self.root / "scripts/sections-stamp-inputs.xcfilelist").write_text(
            "$(SRCROOT)/scripts/sections-stamp-inputs.xcfilelist\n$(SRCROOT)/source.txt\n")
        self.git("add", "source.txt", "scripts/sections-stamp-inputs.xcfilelist")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "-m", "Fixture")
        source = Path(__file__).with_name("sections-source-stamp.py")
        spec = importlib.util.spec_from_file_location("sections_stamp_candidate", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def git(self, *arguments):
        return subprocess.run(["/usr/bin/git", "-C", str(self.root), *arguments],
                              check=True, capture_output=True, timeout=5).stdout

    def test_clean_snapshot_is_deterministic_and_revision_bound(self):
        first = self.module.snapshot(self.root)
        self.assertEqual(first, self.module.snapshot(self.root))
        self.assertEqual(first["revision"], self.git("rev-parse", "HEAD").decode().strip())
        self.assertEqual(first["files"], 2)
        self.assertEqual(len(first["manifestSHA256"]), 64)

    def test_dirty_and_untracked_source_refuse(self):
        (self.root / "source.txt").write_text("changed\n")
        with self.assertRaises(ValueError):
            self.module.snapshot(self.root)
        self.git("checkout", "--", "source.txt")
        (self.root / "new.swift").write_text("// fixture\n")
        with self.assertRaises(ValueError):
            self.module.snapshot(self.root)

    def test_tracked_symlink_refuses(self):
        os.symlink("source.txt", self.root / "link")
        (self.root / "scripts/sections-stamp-inputs.xcfilelist").write_text(
            "$(SRCROOT)/link\n$(SRCROOT)/scripts/sections-stamp-inputs.xcfilelist\n$(SRCROOT)/source.txt\n")
        self.git("add", "link", "scripts/sections-stamp-inputs.xcfilelist")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "-m", "Symlink fixture")
        with self.assertRaises((ValueError, OSError)):
            self.module.snapshot(self.root)

    def test_default_build_does_not_query_source(self):
        with tempfile.TemporaryDirectory(prefix="sections-derived-") as build:
            with mock.patch.dict(os.environ, {"DERIVED_FILE_DIR": build,
                                              "ARX_SECTIONS_ATTRIBUTION": "NO"}):
                with mock.patch.object(self.module, "snapshot", side_effect=AssertionError):
                    self.module.main()
            self.assertIn('REVISION @""', (Path(build) / "ArxSectionsBuildStamp.h").read_text())

    def test_dirty_optin_emits_unavailable_without_build_failure(self):
        (self.root / "source.txt").write_text("dirty fixture\n")
        with tempfile.TemporaryDirectory(prefix="sections-derived-") as build:
            with mock.patch.dict(os.environ, {"DERIVED_FILE_DIR": build,
                                              "SRCROOT": str(self.root),
                                              "ARX_SECTIONS_ATTRIBUTION": "YES"}):
                self.module.main()
            self.assertIn('REVISION @""', (Path(build) / "ArxSectionsBuildStamp.h").read_text())


    def test_status_summary_retains_only_counts_and_fixed_roles(self):
        status = (b" M Package.resolved\n"
                  b" M Arx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved\n"
                  b"?? untracked-sensitive-fixture-name\n")
        summary = self.module.status_summary(status)
        self.assertEqual(summary["entries"], 3)
        self.assertEqual(summary["untracked_entries"], 1)
        self.assertEqual(summary["root_lockfile"], " M")
        self.assertEqual(summary["workspace_lockfile"], " M")
        self.assertNotIn("sensitive-fixture", json.dumps(summary))

    def test_error_summary_never_includes_exception_payloads(self):
        marker = "sensitive-fixture-payload"
        errors = [subprocess.CalledProcessError(128, [marker], stderr=marker),
                  subprocess.TimeoutExpired([marker], 5, stderr=marker),
                  OSError(13, marker), ValueError(marker)]
        for error in errors:
            self.assertNotIn(marker, json.dumps(self.module.error_summary(error)))
        self.assertEqual(self.module.error_summary(errors[0]),
                         {"reason": "git_nonzero", "exit_code": 128,
                          "git_fatal_class": "git_stderr_unavailable"})
        self.assertEqual(self.module.error_summary(errors[1]), {"reason": "git_timeout"})
        self.assertEqual(self.module.error_summary(errors[2]), {"reason": "os_error", "errno": 13})
        with mock.patch("builtins.print", side_effect=BrokenPipeError):
            self.module.emit_observation({"kind": "fixture"})

    def test_git_fatal_classification_fixed_labels_and_order(self):
        marker = "sensitive-fixture-payload"
        cases = [
            (b"fatal: detected dubious ownership in repository at '" + marker.encode() + b"'\n",
             "git_dubious_ownership"),
            (b"fatal: unsafe repository ('" + marker.encode() + b"' is owned by someone else)\n",
             "git_dubious_ownership"),
            (b"fatal: unable to read config file '" + marker.encode() +
             b"': Operation not permitted\n", "git_config_unreadable"),
            (b"fatal: bad config file line 3 in file " + marker.encode() + b"\n",
             "git_config_invalid"),
            (b"fatal: not a git repository (or any of the parent directories): .git\n",
             "git_not_a_repository"),
            (b"fatal: cannot change to '" + marker.encode() + b"': Operation not permitted\n",
             "git_cannot_chdir"),
            (b"fatal: fixture operation failed: Operation not permitted\n",
             "git_operation_not_permitted"),
            (b"fatal: cannot open '" + marker.encode() + b"': Permission denied\n",
             "git_permission_denied"),
            (b"fatal: unable to access '" + marker.encode() + b"': fixture error\n",
             "git_unable_to_access"),
            (b"fatal: fixture failure without a known signature\n", "git_fatal_other"),
        ]
        for stderr, label in cases:
            summary = self.module.error_summary(
                subprocess.CalledProcessError(128, ["git"], stderr=stderr))
            self.assertEqual(summary["reason"], "git_nonzero")
            self.assertEqual(summary["exit_code"], 128)
            self.assertEqual(summary["git_fatal_class"], label)
            self.assertEqual(summary["git_stderr_length"], len(stderr))
            self.assertNotIn(marker, json.dumps(summary))
        empty = self.module.error_summary(subprocess.CalledProcessError(128, ["git"], stderr=b""))
        self.assertEqual(empty["git_fatal_class"], "git_stderr_empty")
        self.assertEqual(empty["git_stderr_length"], 0)
        missing = self.module.error_summary(subprocess.CalledProcessError(128, ["git"]))
        self.assertEqual(missing, {"reason": "git_nonzero", "exit_code": 128,
                                   "git_fatal_class": "git_stderr_unavailable"})

    def test_git_fatal_classification_bounded_scan(self):
        beyond = b"x" * 5000 + b"not a git repository"
        summary = self.module.error_summary(
            subprocess.CalledProcessError(128, ["git"], stderr=beyond))
        self.assertEqual(summary["git_fatal_class"], "git_fatal_other")
        self.assertEqual(summary["git_stderr_length"], len(beyond))
        within = b"not a git repository" + b"y" * 5000
        summary = self.module.error_summary(
            subprocess.CalledProcessError(128, ["git"], stderr=within))
        self.assertEqual(summary["git_fatal_class"], "git_not_a_repository")
        self.assertEqual(summary["git_stderr_length"], len(within))

    def test_dirty_generator_receipt_preserves_unavailable_attribution(self):
        (self.root / "source.txt").write_text("sensitive-fixture-content\n")
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="sections-derived-") as build:
            with mock.patch.dict(os.environ, {"DERIVED_FILE_DIR": build,
                    "SRCROOT": str(self.root), "ARX_SECTIONS_ATTRIBUTION": "YES"}):
                with contextlib.redirect_stdout(output):
                    self.module.main()
            text = (Path(build) / "ArxSectionsBuildStamp.h").read_text()
            self.assertIn('REVISION @""', text)
            self.assertIn('MANIFEST @""', text)
            self.assertIn('REQUIRES_ATTRIBUTION 1', text)
        receipt = json.loads(output.getvalue().split(": ", 1)[1])
        self.assertEqual(receipt["observation"]["reason"], "source_not_clean")
        self.assertEqual(receipt["observation"]["stage"], "status_before")
        self.assertEqual(receipt["observation"]["status_before"]["entries"], 1)
        self.assertNotIn("sensitive-fixture", output.getvalue())
        self.assertLess(len(output.getvalue()), 2048)

    def test_clean_generator_receipt_and_before_after_state(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="sections-derived-") as build:
            with mock.patch.dict(os.environ, {"DERIVED_FILE_DIR": build,
                    "SRCROOT": str(self.root), "ARX_SECTIONS_ATTRIBUTION": "YES"}):
                with contextlib.redirect_stdout(output):
                    self.module.main()
        receipt = json.loads(output.getvalue().split(": ", 1)[1])
        self.assertEqual(receipt["observation"]["stage"], "complete")
        self.assertEqual(receipt["observation"]["status_before"]["entries"], 0)
        self.assertEqual(receipt["observation"]["status_after"]["entries"], 0)
        self.assertEqual(len(receipt["revision"]), 40)
        self.assertEqual(len(receipt["manifestSHA256"]), 64)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.module.observe_build_state("before_build", self.root)
            (self.root / "source.txt").write_text("changed fixture\n")
            (self.root / "sensitive-untracked-fixture").write_text("private fixture\n")
            self.module.observe_build_state("after_build", self.root)
        records = [json.loads(line.split(": ", 1)[1]) for line in output.getvalue().splitlines()]
        self.assertEqual(records[0]["status"]["entries"], 0)
        self.assertEqual(records[1]["status"]["entries"], 2)
        self.assertEqual(records[1]["status"]["untracked_entries"], 1)
        self.assertNotIn("sensitive-untracked-fixture", output.getvalue())
        self.assertNotIn("private fixture", output.getvalue())


    def test_git_visibility_fixed_schema_and_no_values(self):
        marker = "sensitive-visibility-fixture-value"
        with mock.patch.dict(os.environ, {"GIT_DIR": marker,
                                         "GIT_WORK_TREE": marker}):
            with mock.patch.object(self.module.time, "monotonic", return_value=0.0):
                with mock.patch.object(self.module.os, "read", side_effect=AssertionError(marker)):
                    result = self.module.git_visibility(self.root, 1.0)
        self.assertEqual(set(result["roles"]),
                         {"metadata", "head", "refs", "packed_refs", "objects", "config", "index"})
        self.assertEqual(result["roles"]["metadata"],
                         {"kind": "directory", "stat": "ok", "open": "opened"})
        self.assertEqual(result["roles"]["head"]["open"], "opened")
        self.assertTrue(result["env_presence"]["git_dir_set"])
        self.assertTrue(result["env_presence"]["work_tree_set"])
        self.assertTrue(all(type(v) is bool for v in result["env_presence"].values()))
        encoded = json.dumps(result)
        self.assertNotIn(marker, encoded)
        self.assertNotIn(str(self.root), encoded)
        self.assertLess(len(encoded), 1024)

    def test_git_visibility_denials_symlinks_and_descriptor_cleanup(self):
        marker = "sensitive-visibility-fixture-value"
        target = self.root / marker
        target.write_text(marker)
        packed = self.root / ".git" / "packed-refs"
        packed.unlink(missing_ok=True)
        packed.symlink_to(target)
        real_open, real_close = os.open, os.close
        outstanding, forbidden = set(), []

        def opened(name, *args, **kwargs):
            if name == "HEAD":
                raise PermissionError(13, marker)
            if name == "packed-refs":
                forbidden.append(name)
                raise OSError(40, marker)
            descriptor = real_open(name, *args, **kwargs)
            outstanding.add(descriptor)
            return descriptor

        def closed(descriptor):
            real_close(descriptor)
            outstanding.remove(descriptor)

        with mock.patch.object(self.module.time, "monotonic", return_value=0.0):
            with mock.patch.object(self.module.os, "open", side_effect=opened):
                with mock.patch.object(self.module.os, "close", side_effect=closed):
                    result = self.module.git_visibility(self.root, 1.0)
        self.assertEqual(result["roles"]["head"]["open"], "denied")
        self.assertEqual(result["roles"]["packed_refs"]["kind"], "symlink")
        self.assertEqual(result["roles"]["packed_refs"]["open"], "symlink_refused")
        self.assertEqual(outstanding, set())
        self.assertEqual(forbidden, [])
        self.assertNotIn(marker, json.dumps(result))
        original = self.root / ".git-owned-fixture"
        (self.root / ".git").rename(original)
        (self.root / ".git").symlink_to(original, target_is_directory=True)
        with mock.patch.object(self.module.time, "monotonic", return_value=0.0):
            with mock.patch.object(self.module.os, "open") as no_open:
                result = self.module.git_visibility(self.root, 1.0)
        no_open.assert_not_called()
        self.assertEqual(result["roles"]["metadata"]["open"], "symlink_refused")

    def test_git_visibility_expired_deadline_starts_no_filesystem_probe(self):
        with mock.patch.object(self.module.time, "monotonic", return_value=1.0):
            with mock.patch.object(self.module.os, "stat") as no_stat:
                with mock.patch.object(self.module.os, "open") as no_open:
                    result = self.module.git_visibility(self.root, 0.0)
        no_stat.assert_not_called()
        no_open.assert_not_called()
        self.assertEqual(result["roles"]["metadata"]["stat"], "budget_exhausted")
        self.assertLess(len(json.dumps(result)), 1024)

    def test_git_visibility_failure_never_overrides_existing_admission(self):
        marker = "sensitive-visibility-fixture-value"
        observation = {}
        output, header_output = io.StringIO(), io.StringIO()
        with mock.patch.object(self.module, "git_visibility", side_effect=RuntimeError(marker)):
            snapshot = self.module.snapshot(self.root, observation)
            with contextlib.redirect_stdout(output):
                self.module.observe_build_state("before_build", self.root)
            with tempfile.TemporaryDirectory(prefix="sections-derived-") as build:
                with mock.patch.dict(os.environ, {"DERIVED_FILE_DIR": build,
                        "SRCROOT": str(self.root), "ARX_SECTIONS_ATTRIBUTION": "YES"}):
                    with contextlib.redirect_stdout(header_output):
                        self.module.main()
                header = (Path(build) / "ArxSectionsBuildStamp.h").read_text()
        self.assertEqual(len(snapshot["revision"]), 40)
        self.assertIn('REVISION @"' + snapshot["revision"] + '"', header)
        self.assertIn('MANIFEST @"' + snapshot["manifestSHA256"] + '"', header)
        self.assertIn('REQUIRES_ATTRIBUTION 1', header)
        self.assertNotIn(marker, header_output.getvalue())
        self.assertEqual(observation["git_visibility"], {"status": "unavailable"})
        record = json.loads(output.getvalue().split(": ", 1)[1])
        self.assertEqual(record["git_visibility"], {"status": "unavailable"})
        self.assertEqual(record["status"]["entries"], 0)
        self.assertNotIn(marker, output.getvalue())



    def test_metadata_inputs_are_sorted_fixed_scope_without_content_reads(self):
        metadata = self.root / ".git"
        (metadata / "info/attributes").write_text("fixture\n")
        (metadata / "info/private-note").write_text("private fixture\n")
        with mock.patch.object(self.module.os, "read", side_effect=AssertionError):
            with mock.patch.object(self.module, "git", side_effect=AssertionError):
                lines = self.module.metadata_input_lines(self.root)
        self.assertEqual(lines, sorted(set(lines)))
        for role in ("", "/HEAD", "/config", "/index", "/refs", "/objects",
                     "/info/exclude", "/info/attributes"):
            self.assertIn("$(SRCROOT)/.git" + role, lines)
        self.assertTrue(all(line.startswith("$(SRCROOT)/.git") for line in lines))
        self.assertFalse(any("/hooks" in line or "/logs" in line or
                             "private-note" in line for line in lines))
        self.assertNotIn(str(self.root), "\n".join(lines))

    def test_metadata_optional_fixed_files_and_missing_optional_roles(self):
        metadata = self.root / ".git"
        for name in ("config.worktree", "packed-refs", "shallow"):
            path = metadata / name
            path.unlink(missing_ok=True)
            self.assertNotIn("$(SRCROOT)/.git/" + name,
                             self.module.metadata_input_lines(self.root))
            path.write_text("sensitive-metadata-fixture\n")
            self.assertIn("$(SRCROOT)/.git/" + name,
                          self.module.metadata_input_lines(self.root))
        self.assertNotIn("sensitive-metadata-fixture",
                         "\n".join(self.module.metadata_input_lines(self.root)))

    def test_metadata_missing_or_wrong_type_required_file_refuses(self):
        index = self.root / ".git/index"
        index.unlink()
        with self.assertRaises(ValueError):
            self.module.metadata_input_lines(self.root)
        index.mkdir()
        with self.assertRaises(ValueError):
            self.module.metadata_input_lines(self.root)

    def test_metadata_symlink_root_and_descendant_refuse(self):
        link = self.root / ".git/refs/unsafe"
        link.symlink_to(self.root / "source.txt")
        with self.assertRaises(ValueError):
            self.module.metadata_input_lines(self.root)
        link.unlink()
        (self.root / ".git").rename(self.root / ".git-original")
        (self.root / ".git").symlink_to(self.root / ".git-original")
        with self.assertRaises(OSError):
            self.module.metadata_input_lines(self.root)

    def test_metadata_unsafe_components_refuse_without_output(self):
        for name in ("unsafe$(name)", "unsafe\nname", "unsafe name"):
            with self.subTest(name=name):
                path = self.root / ".git/refs" / name
                path.write_text("fixture\n")
                try:
                    with self.assertRaises(ValueError):
                        self.module.metadata_input_lines(self.root)
                finally:
                    path.unlink()
        self.assertFalse((self.root / ".build").exists())

    def test_metadata_shared_and_external_object_stores_refuse(self):
        for name in ("commondir", "objects/info/alternates",
                     "objects/info/http-alternates"):
            with self.subTest(role=name):
                path = self.root / ".git" / name
                path.write_text("sensitive-external-fixture\n")
                try:
                    with self.assertRaises(ValueError):
                        self.module.metadata_input_lines(self.root)
                finally:
                    path.unlink()

    def test_metadata_entry_depth_elapsed_and_output_bounds_refuse(self):
        for constant, value in (("METADATA_MAX_ENTRIES", 2),
                                ("METADATA_MAX_DEPTH", 0), ("MAX_OUTPUT", 8)):
            with self.subTest(bound=constant):
                with mock.patch.object(self.module, constant, value):
                    with self.assertRaises(ValueError):
                        self.module.metadata_input_lines(self.root)
        with mock.patch.object(self.module.time, "monotonic", side_effect=[0.0, 16.0]):
            with self.assertRaises(ValueError):
                self.module.metadata_input_lines(self.root)
        self.assertFalse((self.root / ".build").exists())

    def test_metadata_preparation_writes_only_fixed_private_input_list(self):
        with mock.patch.object(self.module, "snapshot", side_effect=AssertionError):
            with mock.patch.object(self.module, "git", side_effect=AssertionError):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    receipt = self.module.prepare_git_metadata_inputs(self.root)
        destination = self.root / ".build" / self.module.METADATA_OUTPUT
        text = destination.read_text()
        self.assertEqual(text, "\n".join(self.module.metadata_input_lines(self.root)) + "\n")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(receipt, {"entries": len(text.splitlines()),
                                   "bytes": len(text.encode("utf-8"))})
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(list((self.root / ".build").iterdir()), [destination])

    def test_metadata_existing_output_and_output_symlink_are_not_overwritten(self):
        build = self.root / ".build"
        build.mkdir()
        destination = build / self.module.METADATA_OUTPUT
        destination.write_text("preserve fixture\n")
        with self.assertRaises(FileExistsError):
            self.module.prepare_git_metadata_inputs(self.root)
        self.assertEqual(destination.read_text(), "preserve fixture\n")
        destination.unlink()
        destination.symlink_to(self.root / "source.txt")
        with self.assertRaises(FileExistsError):
            self.module.prepare_git_metadata_inputs(self.root)
        self.assertEqual((self.root / "source.txt").read_text(), "fixture\n")

    def test_metadata_build_directory_symlink_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="sections-output-fixture-") as other:
            (self.root / ".build").symlink_to(other)
            with self.assertRaises(OSError):
                self.module.prepare_git_metadata_inputs(self.root)
            self.assertEqual(list(Path(other).iterdir()), [])

    def test_metadata_directory_open_failure_closes_owned_descriptors(self):
        real_open, real_close = os.open, os.close
        outstanding = set()

        def opened(name, *args, **kwargs):
            if name == "refs":
                raise PermissionError(13, "sensitive-fixture")
            descriptor = real_open(name, *args, **kwargs)
            outstanding.add(descriptor)
            return descriptor

        def closed(descriptor):
            outstanding.remove(descriptor)
            real_close(descriptor)

        with mock.patch.object(self.module.os, "open", side_effect=opened):
            with mock.patch.object(self.module.os, "close", side_effect=closed):
                with self.assertRaises(PermissionError):
                    self.module.metadata_input_lines(self.root)
        self.assertFalse(outstanding)


class OrdinaryInputListBindingTests(unittest.TestCase):
    """Source/config regression checks only, not Xcode scheduling proof."""
    def test_distinct_default_metadata_list_preserves_non_git_dependency(self):
        root = Path(__file__).resolve().parent.parent
        project = (root / "Arx.xcodeproj/project.xcproj").read_text()
        prefix = "$(SRCROOT)/scripts/"
        values = {}
        for key in ("ARX_SECTIONS_ATTRIBUTION_INPUTS", "ARX_SECTIONS_METADATA_INPUTS"):
            matches = re.findall(r'"' + re.escape(key) + r'":\s*"([^"\n]+)"', project)
            self.assertEqual(len(matches), 1)
            values[key] = matches[0]
        self.assertNotEqual(values["ARX_SECTIONS_ATTRIBUTION_INPUTS"],
                            values["ARX_SECTIONS_METADATA_INPUTS"])
        self.assertEqual(values["ARX_SECTIONS_ATTRIBUTION_INPUTS"],
                         prefix + "sections-stamp-default-inputs.xcfilelist")
        self.assertEqual(values["ARX_SECTIONS_METADATA_INPUTS"],
                         prefix + "sections-stamp-default-metadata-inputs.xcfilelist")
        expected = b"$(SRCROOT)/scripts/sections-source-stamp.py\n"
        for value in values.values():
            path = root / value.removeprefix("$(SRCROOT)/")
            self.assertFalse(path.is_symlink())
            self.assertTrue(path.is_file())
            self.assertEqual(path.read_bytes(), expected)
        declarations = re.findall(r'"input-file-list-paths":\s*\[([^\]]+)\]', project)
        self.assertEqual(len(declarations), 2)
        for declaration in declarations:
            roles = re.findall(r'"\$\((ARX_SECTIONS_[A-Z_]+)\)"', declaration)
            self.assertEqual(roles, ["ARX_SECTIONS_ATTRIBUTION_INPUTS",
                                     "ARX_SECTIONS_METADATA_INPUTS"])
            self.assertEqual(len({values[role] for role in roles}), len(roles))

    def test_optin_lists_stay_distinct_and_use_existing_bounded_metadata(self):
        root = Path(__file__).resolve().parent.parent
        text = (root / "scripts/sections-attribution.xcconfig").read_text()
        values = {}
        for line in text.splitlines():
            if line.startswith("ARX_SECTIONS_") and " = " in line:
                key, value = line.split(" = ", 1)
                values[key] = value
        self.assertEqual(values["ARX_SECTIONS_ATTRIBUTION_INPUTS"],
                         "$(SRCROOT)/scripts/sections-stamp-inputs.xcfilelist")
        self.assertEqual(values["ARX_SECTIONS_METADATA_INPUTS"],
                         "$(SRCROOT)/.build/sections-proof-git-metadata.xcfilelist")
        self.assertNotEqual(values["ARX_SECTIONS_ATTRIBUTION_INPUTS"],
                            values["ARX_SECTIONS_METADATA_INPUTS"])


if __name__ == "__main__":
    unittest.main(failfast=True)
