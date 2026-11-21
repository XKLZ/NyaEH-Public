import contextlib
import importlib.util
import io
from pathlib import Path, PurePosixPath
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location(
    "public_audit", Path(__file__).resolve().parents[1] / "audit_public_snapshot.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PublicAuditTests(unittest.TestCase):
    def test_rejects_home_paths_in_plaintext_and_wide_strings(self):
        hidden = "/Users/" + "fixture/private"
        self.assertEqual(audit.payload_issue(hidden.encode(), []), "absolute home path")
        self.assertEqual(audit.payload_issue(hidden.encode("utf-16-le"), []), "absolute home path")
        self.assertIsNone(audit.payload_issue(b"/nyaeh/source/example.swift", []))

    def test_rejects_the_specific_build_root_without_printing_it(self):
        root = b"/some/private/staging-root"
        self.assertEqual(audit.payload_issue(root + b"/test", [root]), "private build path")

    def test_rejects_embedded_database(self):
        with self.assertRaisesRegex(ValueError, "fixture or credential payload"):
            audit.check([(PurePosixPath("App.app/database.sqlite"), b"not used")], [])

    def test_scans_zip_members(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "example.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("App.app/Contents/MacOS/app", b"binary\0" + b"/Users/" + b"fixture/path")
            with self.assertRaisesRegex(ValueError, "absolute home path at entry #1"):
                audit.check(audit.zip_files(archive), [])

    def test_python_cache_directory_is_rejected_without_private_paths(self):
        with self.assertRaisesRegex(ValueError, "Python cache payload"):
            audit.check([(PurePosixPath("script/__pycache__/cache.bin"), b"synthetic")], [])

    def test_python_bytecode_is_rejected_outside_cache_directory(self):
        for suffix in [".pyc", ".pyo", ".pyd", ".PYC"]:
            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(ValueError, "Python cache payload"):
                    audit.check([(PurePosixPath("script/cache" + suffix), b"synthetic")], [])

    def test_ordinary_source_is_allowed(self):
        with contextlib.redirect_stdout(io.StringIO()):
            audit.check([(PurePosixPath("script/helper.py"), b"print('synthetic')")], [])

    def test_database_fixture_is_still_rejected(self):
        with self.assertRaisesRegex(ValueError, "fixture or credential"):
            audit.check([(PurePosixPath("data/sample.sqlite"), b"synthetic")], [])

    def test_zip_audit_rejects_bytecode(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "candidate.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("NyaEH.app/Contents/Resources/helper.pyc", b"synthetic")
            with self.assertRaisesRegex(ValueError, "Python cache payload"):
                audit.check(audit.zip_files(archive), [])
