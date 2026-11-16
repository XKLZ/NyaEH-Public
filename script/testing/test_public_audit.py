import importlib.util
from pathlib import Path, PurePosixPath
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location(
    "public_audit", Path(__file__).resolve().parents[1] / "audit_public_snapshot.py"
)
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
