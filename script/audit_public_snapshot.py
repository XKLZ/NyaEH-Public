"""Check the public source index or a candidate ZIP without printing matched data."""
import argparse
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import zipfile


SECRET = re.compile(rb"(?:gh[opusr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|"
                    rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|"
                    rb"(?:AKIA|ASIA)[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{40,}|"
                    rb"xox[baprs]-[A-Za-z0-9-]{20,}|"
                    rb"(?i:ipb_pass_hash|igneous)\s*=\s*[\"']?[a-fA-F0-9]{20,})")
HOME = re.compile(rb"/Users/[A-Za-z0-9_.-]+/")


def payload_issue(data, prefixes):
    for view in (data, data.replace(b"\0", b"")):
        if HOME.search(view):
            return "absolute home path"
        if any(prefix in view for prefix in prefixes):
            return "private build path"
        if SECRET.search(view):
            return "potential credential"
    return None


def source_files():
    entries = subprocess.check_output(["git", "ls-files", "-s", "-z"]).split(b"\0")
    for record in entries:
        if not record:
            continue
        metadata, name = record.split(b"\t", 1)
        mode, object_id, index = metadata.split()
        if mode not in (b"100644", b"100755") or index != b"0":
            raise ValueError("public source index has a nonregular or conflicted entry")
        path = PurePosixPath(os.fsdecode(name))
        data = subprocess.check_output(["git", "cat-file", "blob", object_id.decode("ascii")])
        yield path, data


def zip_files(filename):
    with zipfile.ZipFile(filename) as archive:
        visited = set()
        for member in archive.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or path in visited:
                raise ValueError("invalid or repeated ZIP member path")
            visited.add(path)
            if member.is_dir():
                continue
            mode = member.external_attr >> 16
            with archive.open(member) as stream:
                data = stream.read()
            if stat.S_ISLNK(mode) and (data.startswith(b"/") or b".." in data.split(b"/")):
                raise ValueError("ZIP symlink points outside its containing directory")
            yield path, data


def check(entries, prefixes):
    count = 0
    for path, payload in entries:
        count += 1
        if (
            set(path.parts) & {"Booklib", "cover_distance", "importTest", "xcuserdata"}
            or path.suffix.lower() in {".zip", ".cbz", ".sqlite", ".db", ".nyaehbackup", ".p12", ".mobileprovision"}
            or path.name in {"credentials.json", "development-credentials.json", "collectionList.json", ".env"}
        ):
            raise ValueError(f"fixture or credential payload at entry #{count}")
        if issue := payload_issue(str(path).encode(), prefixes) or payload_issue(payload, prefixes):
            raise ValueError(f"{issue} at entry #{count}")
    if count == 0:
        raise ValueError("no files to audit")
    print(f"Public payload audit passed: {count} files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", type=Path, help="read an archive instead of the Git index")
    parser.add_argument("--reject-prefix", action="append", default=[])
    args = parser.parse_args()
    try:
        check(zip_files(args.zip) if args.zip else source_files(), [os.fsencode(p) for p in args.reject_prefix])
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Public payload audit failed: {error}\n")
