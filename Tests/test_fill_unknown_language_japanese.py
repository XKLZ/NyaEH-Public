#!/usr/bin/env python3
import contextlib
import io
import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT_DIR / "script" / "fill_unknown_language_japanese.py"
SPEC = importlib.util.spec_from_file_location("fill_unknown_language_japanese", SCRIPT_PATH)
module = importlib.util.module_from_spec(SPEC)
sys.modules["fill_unknown_language_japanese"] = module
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


class FillUnknownLanguageJapaneseTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp_dir.name) / "NyaEH.sqlite"
        self.conn = sqlite3.connect(self.db_path)
        self.conn.row_factory = sqlite3.Row
        self.create_schema()

    def tearDown(self):
        self.conn.close()
        self.temp_dir.cleanup()

    def create_schema(self):
        self.conn.executescript(
            """
            CREATE TABLE library_books (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                filepath TEXT NOT NULL UNIQUE,
                hash TEXT NOT NULL,
                status TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '[]',
                language_code TEXT NOT NULL DEFAULT 'unknown',
                is_translated INTEGER NOT NULL DEFAULT 0,
                is_full_color INTEGER NOT NULL DEFAULT 0,
                censorship TEXT NOT NULL DEFAULT 'unknown',
                has_extraneous_ads INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE gallery_metadata (
                hash TEXT PRIMARY KEY
            );

            CREATE TABLE tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                namespace TEXT NOT NULL,
                name TEXT NOT NULL,
                raw_value TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE book_tags (
                book_id INTEGER NOT NULL,
                tag_id INTEGER NOT NULL,
                PRIMARY KEY (book_id, tag_id),
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE,
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );
            """
        )
        self.conn.commit()

    def insert_book(
        self,
        title,
        *,
        status="correct",
        tags="[]",
        language_code="unknown",
        hash_value=None,
        is_translated=0,
        is_full_color=0,
        censorship="unknown",
    ):
        hash_value = hash_value or f"hash-{title}"
        cursor = self.conn.execute(
            """
            INSERT INTO library_books (
                title, filepath, hash, status, tags, language_code,
                is_translated, is_full_color, censorship, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """,
            (
                title,
                f"/tmp/{title}.cbz",
                hash_value,
                status,
                tags,
                language_code,
                is_translated,
                is_full_color,
                censorship,
            ),
        )
        self.conn.commit()
        return cursor.lastrowid, hash_value

    def run_script(self, *, apply, backup=False, include_unscanned=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return module.run(
                db_path=self.db_path,
                apply=apply,
                backup=backup,
                include_unscanned=include_unscanned,
            )

    def fetch_book(self, book_id):
        return self.conn.execute(
            "SELECT * FROM library_books WHERE id = ?",
            (book_id,),
        ).fetchone()

    def test_dry_run_does_not_write(self):
        book_id, _ = self.insert_book("candidate", tags='["artist:sample"]')

        updated = self.run_script(apply=False)

        book = self.fetch_book(book_id)
        self.assertEqual(updated, 1)
        self.assertEqual(book["language_code"], "unknown")
        self.assertEqual(book["tags"], '["artist:sample"]')
        self.assertIsNone(
            self.conn.execute("SELECT 1 FROM tags WHERE raw_value = 'language:japanese'").fetchone()
        )

    def test_apply_updates_book_tags_and_tag_index(self):
        book_id, _ = self.insert_book("candidate", tags='["Artist:Sample"]')

        updated = self.run_script(apply=True)

        book = self.fetch_book(book_id)
        language_tag = self.conn.execute(
            "SELECT id FROM tags WHERE raw_value = 'language:japanese'"
        ).fetchone()
        link = self.conn.execute(
            "SELECT 1 FROM book_tags WHERE book_id = ? AND tag_id = ?",
            (book_id, language_tag["id"]),
        ).fetchone()

        self.assertEqual(updated, 1)
        self.assertEqual(book["language_code"], "japanese")
        self.assertEqual(book["tags"], '["Artist:Sample","language:japanese"]')
        self.assertIsNotNone(link)

    def test_skips_books_that_already_have_language_tags(self):
        chinese_id, _ = self.insert_book(
            "chinese",
            tags='["language:chinese"]',
            language_code="unknown",
        )
        japanese_id, _ = self.insert_book(
            "japanese",
            tags='["language:japanese"]',
            language_code="japanese",
        )

        updated = self.run_script(apply=True, include_unscanned=True)

        self.assertEqual(updated, 0)
        self.assertEqual(self.fetch_book(chinese_id)["tags"], '["language:chinese"]')
        self.assertEqual(self.fetch_book(japanese_id)["tags"], '["language:japanese"]')

    def test_default_skips_books_without_metadata_or_tag_trace(self):
        pure_id, _ = self.insert_book("pure", status="unscanned", tags="[]")
        scanned_id, _ = self.insert_book("scanned", status="correct", tags="[]")

        updated = self.run_script(apply=True)
        self.assertEqual(updated, 0)
        self.assertEqual(self.fetch_book(pure_id)["language_code"], "unknown")
        self.assertEqual(self.fetch_book(scanned_id)["language_code"], "unknown")

    def test_include_unscanned_updates_books_without_metadata_or_tag_trace(self):
        pure_id, _ = self.insert_book("pure", status="unscanned", tags="[]")

        applied = self.run_script(apply=True, include_unscanned=True)
        self.assertEqual(applied, 1)
        self.assertEqual(self.fetch_book(pure_id)["language_code"], "japanese")

    def test_default_includes_books_with_gallery_metadata_trace(self):
        book_id, hash_value = self.insert_book("traced", status="unscanned", tags="[]")
        self.conn.execute("INSERT INTO gallery_metadata (hash) VALUES (?)", (hash_value,))
        self.conn.commit()

        updated = self.run_script(apply=True)

        self.assertEqual(updated, 1)
        self.assertEqual(self.fetch_book(book_id)["language_code"], "japanese")

    def test_apply_preserves_non_language_metadata_fields(self):
        book_id, _ = self.insert_book(
            "metadata-fields",
            tags='["artist:sample"]',
            is_translated=1,
            is_full_color=1,
            censorship="uncensored",
        )

        updated = self.run_script(apply=True)
        book = self.fetch_book(book_id)

        self.assertEqual(updated, 1)
        self.assertEqual(book["language_code"], "japanese")
        self.assertEqual(book["is_translated"], 1)
        self.assertEqual(book["is_full_color"], 1)
        self.assertEqual(book["censorship"], "uncensored")


if __name__ == "__main__":
    unittest.main()
