#!/usr/bin/env python3
import argparse
import json
import shutil
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


DEFAULT_DB_PATH = Path.home() / "Library" / "Application Support" / "NyaEH" / "NyaEH.sqlite"
JAPANESE_TAG = "language:japanese"


@dataclass(frozen=True)
class CandidateBook:
    book_id: int
    title: str
    filepath: str
    tags: list[str]


@dataclass(frozen=True)
class SelectionResult:
    candidates: list[CandidateBook]
    skipped_existing_language: int
    skipped_invalid_tags: int
    skipped_untraced: int
    has_japanese_tag: bool


def normalize_db_path(path: str | None) -> Path:
    return Path(path).expanduser() if path else DEFAULT_DB_PATH


def now_milliseconds() -> int:
    return int(datetime.now().timestamp() * 1000)


def parse_tags(tags_json: str | None) -> list[str] | None:
    if tags_json is None or tags_json.strip() == "":
        return []
    try:
        value = json.loads(tags_json)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, list):
        return None

    tags: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            return None
        tag = item.strip()
        key = tag.lower()
        if tag and key not in seen:
            tags.append(tag)
            seen.add(key)
    return tags


def has_language_tag(tags: Iterable[str]) -> bool:
    return any(tag.strip().lower().startswith("language:") for tag in tags)


def has_metadata_trace(row: sqlite3.Row, tags: list[str], include_unscanned: bool) -> bool:
    if include_unscanned:
        return True
    return bool(tags) or bool(row["metadata_exists"])


def load_selection(conn: sqlite3.Connection, include_unscanned: bool) -> SelectionResult:
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """
        SELECT
            library_books.id,
            library_books.title,
            library_books.filepath,
            library_books.tags,
            library_books.status,
            EXISTS (
                SELECT 1
                FROM gallery_metadata
                WHERE gallery_metadata.hash = library_books.hash
            ) AS metadata_exists
        FROM library_books
        WHERE language_code IS NULL
           OR lower(trim(language_code)) IN ('', 'unknown')
        ORDER BY title COLLATE NOCASE ASC, filepath COLLATE NOCASE ASC
        """
    ).fetchall()

    candidates: list[CandidateBook] = []
    skipped_existing_language = 0
    skipped_invalid_tags = 0
    skipped_untraced = 0

    for row in rows:
        tags = parse_tags(row["tags"])
        if tags is None:
            skipped_invalid_tags += 1
            continue
        if has_language_tag(tags):
            skipped_existing_language += 1
            continue
        if not has_metadata_trace(row, tags, include_unscanned):
            skipped_untraced += 1
            continue
        candidates.append(
            CandidateBook(
                book_id=row["id"],
                title=row["title"],
                filepath=row["filepath"],
                tags=tags,
            )
        )

    has_japanese_tag = (
        conn.execute("SELECT 1 FROM tags WHERE raw_value = ? LIMIT 1", (JAPANESE_TAG,)).fetchone()
        is not None
    )

    return SelectionResult(
        candidates=candidates,
        skipped_existing_language=skipped_existing_language,
        skipped_invalid_tags=skipped_invalid_tags,
        skipped_untraced=skipped_untraced,
        has_japanese_tag=has_japanese_tag,
    )


def backup_database(db_path: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = db_path.with_name(f"{db_path.name}.bak-{timestamp}")
    if backup_path.exists():
        backup_path = db_path.with_name(f"{db_path.name}.bak-{timestamp}-{datetime.now().microsecond}")

    source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        destination = sqlite3.connect(backup_path)
        try:
            source.backup(destination)
        finally:
            destination.close()
    finally:
        source.close()

    shutil.copystat(db_path, backup_path, follow_symlinks=True)
    return backup_path


def ensure_japanese_tag(cursor: sqlite3.Cursor, now: int) -> int:
    cursor.execute(
        """
        INSERT INTO tags (namespace, name, raw_value, created_at, updated_at)
        VALUES ('language', 'japanese', ?, ?, ?)
        ON CONFLICT(raw_value) DO UPDATE SET
            namespace = excluded.namespace,
            name = excluded.name,
            updated_at = excluded.updated_at
        """,
        (JAPANESE_TAG, now, now),
    )
    row = cursor.execute("SELECT id FROM tags WHERE raw_value = ?", (JAPANESE_TAG,)).fetchone()
    if row is None:
        raise RuntimeError("Failed to create language:japanese tag")
    return int(row[0])


def tags_json_with_japanese(tags: list[str]) -> str:
    updated = list(tags)
    if not any(tag.lower() == JAPANESE_TAG for tag in updated):
        updated.append(JAPANESE_TAG)
    return json.dumps(updated, ensure_ascii=False, separators=(",", ":"))


def apply_updates(conn: sqlite3.Connection, candidates: list[CandidateBook]) -> int:
    now = now_milliseconds()
    cursor = conn.cursor()
    cursor.execute("BEGIN IMMEDIATE")
    try:
        tag_id = ensure_japanese_tag(cursor, now)
        for candidate in candidates:
            cursor.execute(
                """
                UPDATE library_books
                SET language_code = 'japanese',
                    tags = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (tags_json_with_japanese(candidate.tags), now, candidate.book_id),
            )
            cursor.execute(
                """
                INSERT OR IGNORE INTO book_tags (book_id, tag_id)
                VALUES (?, ?)
                """,
                (candidate.book_id, tag_id),
            )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    return len(candidates)


def preview(selection: SelectionResult, apply: bool) -> None:
    mode = "apply" if apply else "dry-run"
    print(f"Mode: {mode}")
    print(f"language:japanese tag exists: {'yes' if selection.has_japanese_tag else 'no'}")
    print(f"Books to update: {len(selection.candidates)}")
    print(f"Skipped with existing language tag: {selection.skipped_existing_language}")
    print(f"Skipped with invalid tags JSON: {selection.skipped_invalid_tags}")
    print(f"Skipped without metadata/tag trace: {selection.skipped_untraced}")
    if selection.candidates:
        print()
        print("Preview:")
        for candidate in selection.candidates[:20]:
            print(f"- #{candidate.book_id} {candidate.title}")
            print(f"  {candidate.filepath}")
        if len(selection.candidates) > 20:
            print(f"... and {len(selection.candidates) - 20} more")


def run(
    db_path: Path,
    apply: bool,
    backup: bool,
    include_unscanned: bool,
) -> int:
    if not db_path.exists():
        raise FileNotFoundError(f"SQLite database not found: {db_path}")
    if not db_path.is_file():
        raise FileNotFoundError(f"SQLite database path is not a file: {db_path}")

    print("Tip: close NyaEH before applying database maintenance.")
    print(f"Database: {db_path}")
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        selection = load_selection(conn, include_unscanned=include_unscanned)
        preview(selection, apply=apply)

        if not apply:
            print()
            print("Dry-run only. Re-run with --apply to write changes.")
            return len(selection.candidates)
        if not selection.candidates:
            print()
            print("No changes needed.")
            return 0
    finally:
        conn.close()

    if backup:
        backup_path = backup_database(db_path)
        print(f"Backup: {backup_path}")

    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        updated = apply_updates(conn, selection.candidates)
    finally:
        conn.close()

    print(f"Updated books: {updated}")
    return updated


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fill unknown NyaEH book language metadata with Japanese and keep tag indexes in sync."
    )
    parser.add_argument(
        "--db",
        default=str(DEFAULT_DB_PATH),
        help=f"Path to NyaEH.sqlite. Default: {DEFAULT_DB_PATH}",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write changes. Without this flag the script only previews matching books.",
    )
    parser.add_argument(
        "--include-unscanned",
        action="store_true",
        help="Also update pure unscanned books without existing metadata or tags.",
    )

    backup_group = parser.add_mutually_exclusive_group()
    backup_group.add_argument(
        "--backup",
        dest="backup",
        action="store_true",
        default=True,
        help="Create a timestamped backup before --apply writes. This is the default.",
    )
    backup_group.add_argument(
        "--no-backup",
        dest="backup",
        action="store_false",
        help="Do not create a backup before --apply writes.",
    )

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        run(
            db_path=normalize_db_path(args.db),
            apply=args.apply,
            backup=args.backup,
            include_unscanned=args.include_unscanned,
        )
    except (FileNotFoundError, RuntimeError, sqlite3.Error) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
