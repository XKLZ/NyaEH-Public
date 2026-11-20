"""Filesystem identity and serialization for project-owned verification resources."""
import contextlib
import fcntl
import json
import os
from pathlib import Path


def canonical(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise RuntimeError(f'Non-canonical or symlink path: {path}')
    return path


def owned_identity(path):
    p = canonical(path)
    s = p.stat()
    if s.st_uid != os.getuid():
        raise RuntimeError(f'Not owned by current user: {p}')
    return {'path': str(p), 'device': s.st_dev, 'inode': s.st_ino}


def same_identity(record):
    try:
        current = owned_identity(record['path'])
        return current == {k: record[k] for k in current}
    except FileNotFoundError:
        return True


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False))
    temp.replace(path)


@contextlib.contextmanager
def directory_lock(path):
    canonical(path)
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    owned_identity(path)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)
