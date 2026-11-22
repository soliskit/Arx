"""Proposed synthetic tests only. Not imported or run during preparation."""
import importlib.util
import contextlib
import io
import json
import os
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
                         {"reason": "git_nonzero", "exit_code": 128})
        self.assertEqual(self.module.error_summary(errors[1]), {"reason": "git_timeout"})
        self.assertEqual(self.module.error_summary(errors[2]), {"reason": "os_error", "errno": 13})
        with mock.patch("builtins.print", side_effect=BrokenPipeError):
            self.module.emit_observation({"kind": "fixture"})

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


if __name__ == "__main__":
    unittest.main(failfast=True)
