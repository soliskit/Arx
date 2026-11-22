"""Proposed synthetic tests only. Not imported or run during preparation."""
import importlib.util
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


if __name__ == "__main__":
    unittest.main(failfast=True)
