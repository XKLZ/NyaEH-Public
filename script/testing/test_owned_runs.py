import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import owned_runs as runs


class OwnedRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.folder = self.base / 'unit-runs'
        self.folder.mkdir()
        self.cleared = []

    def clear(self, domains, recheck):
        self.cleared.append((domains, recheck))

    @contextlib.contextmanager
    def process(self):
        sid = str(uuid.uuid4())
        lease = self.folder / (sid + '.lease')
        # Same independently held file lease that the Swift runner holds across tests.
        child = subprocess.Popen([sys.executable, '-c',
            'import fcntl, sys; f=open(sys.argv[1], "x"); fcntl.flock(f, fcntl.LOCK_EX); '
            'print("ready", flush=True); sys.stdin.readline()', str(lease)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertEqual(child.stdout.readline(), b'ready\n')
            runs.unit(self.base, 'begin', sid, self.clear)
            yield sid, child
        finally:
            child.stdin.close()
            child.wait(timeout=10)
            child.stdout.close()

    def test_killed_run_recovered_while_parallel_owner_keeps_files_and_domain(self):
        with self.process() as (dead, child), self.process() as (live, _):
            token = str(uuid.uuid4())
            for sid in (dead, live):
                (self.folder / sid / 'files/NyaEH.sqlite').write_text('fixture')
                (self.folder / sid / 'domains' / token).touch()
            child.kill()
            child.wait(timeout=10)
            runs.collect(self.base, self.clear)
            self.assertFalse((self.folder / dead).exists())
            self.assertTrue((self.folder / live / 'files/NyaEH.sqlite').exists())
            self.assertIn(([f'{runs.UNIT_PREFIX}{dead}.{token}'], False), self.cleared)
            self.assertFalse(any(live in d for names, _ in self.cleared for d in names))
        runs.unit(self.base, 'end', live, self.clear)
        self.assertFalse((self.folder / live).exists())

    def test_replacement_and_symlink_never_removed(self):
        with self.process() as (sid, _):
            pass
        work = self.folder / sid
        sentinel = self.base / 'elsewhere'
        work.rename(sentinel)
        work.symlink_to(sentinel)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            runs.unit(self.base, 'end', sid, self.clear)
        self.assertTrue(sentinel.exists())
        work.unlink()
        work.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'replaced'):
            runs.unit(self.base, 'end', sid, self.clear)
        self.assertTrue(work.is_dir())

    def test_scratch_success_failure_expiry_and_export(self):
        exported = self.base / 'exported.png'
        command = [sys.executable, '-c',
            'from pathlib import Path; import os, sys; p=Path("screenshot.png"); p.write_bytes(b"image"); '
            'Path(sys.argv[1]).write_bytes(p.read_bytes()); assert Path(os.environ["TMPDIR"]).parent == Path.cwd()',
            str(exported)]
        self.assertEqual(runs.scratch(self.base, self.base, command), 0)
        folder = self.base / 'scratch-runs'
        self.assertFalse(list(folder.iterdir()))
        self.assertEqual(runs.scratch(self.base, self.base, [sys.executable, '-c', 'raise SystemExit(19)']), 19)
        journal, = folder.glob('*.json')
        record = json.loads(journal.read_bytes())
        work = folder / journal.stem
        self.assertEqual(record['exitCode'], 19)
        runs.collect(self.base, self.clear)
        self.assertTrue(work.exists())
        with patch.object(time, 'time', return_value=record['finished'] + 7 * runs.DAY):
            runs.collect(self.base, self.clear)
        self.assertFalse(list(folder.iterdir()))
        self.assertEqual(exported.read_bytes(), b'image')

    def test_nested_scratch_xcodebuild_uses_local_derived_data_and_honors_override(self):
        fake = self.base / 'xcodebuild'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$EXPORTED_ARGS"\n')
        fake.chmod(0o700)
        exported = self.base / 'args'
        with patch.dict(os.environ, PATH=str(self.base) + os.pathsep + os.environ['PATH'], EXPORTED_ARGS=str(exported)):
            for explicit in (False, True):
                command = 'xcodebuild -scheme Probe' + (' -derivedDataPath chosen' if explicit else '')
                self.assertEqual(runs.scratch(self.base, self.base, ['sh', '-c', command]), 0)
                args = exported.read_text().splitlines()
                self.assertEqual(args[:3], ['-scheme', 'Probe', '-derivedDataPath'])
                self.assertEqual(len(args), 4)
                if explicit:
                    self.assertEqual(args[3], 'chosen')
                else:
                    self.assertEqual(Path(args[3]).parents[1], self.base / 'scratch-runs')

    def test_only_registered_session_is_reaped_after_failed_test_host(self):
        parent = str(uuid.uuid4())
        with patch.dict(os.environ, NYAEH_TEST_SESSION=parent):
            with self.process() as (sid, child):
                child.kill(); child.wait(timeout=10)
                runs.finish_session_units(self.base, str(uuid.uuid4()), self.clear)
                self.assertTrue((self.folder / sid).exists())
                runs.finish_session_units(self.base, parent, self.clear)
                self.assertFalse((self.folder / sid).exists())

    def test_verify_parent_owns_fixtures_until_exit_status_and_log_are_saved(self):
        session = str(uuid.uuid4())
        manifest = self.base / 'sessions' / session / 'session.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'tests': 'running'}))
        with (self.base / 'lock').open('wb') as parent_lock, patch.dict(os.environ, NYAEH_TEST_SESSION=session):
            fcntl.flock(parent_lock, fcntl.LOCK_EX)
            with self.process() as (sid, _):
                pass
            runs.unit(self.base, 'end', sid, self.clear)
            runs.collect(self.base, self.clear)
            self.assertTrue((self.folder / sid).exists())
            manifest.write_text(json.dumps({'tests': 'failed', 'testExitCode': 1}))
            runs.finish_session_units(self.base, session, self.clear)
            self.assertFalse((self.folder / sid).exists())

    def test_interrupted_scratch_child_lease_delays_expiration(self):
        folder = self.base / 'scratch-runs'
        folder.mkdir()
        sid = str(uuid.uuid4())
        with (folder / (sid + '.lease')).open('x') as lease:
            fcntl.flock(lease, fcntl.LOCK_SH)
            work = runs.register(folder, sid)
            with patch.object(time, 'time', return_value=time.time() + 10 * runs.DAY):
                runs.collect(self.base, self.clear)
                self.assertTrue(work.exists())
        runs.collect(self.base, self.clear)
        self.assertTrue(work.exists())
        with patch.object(time, 'time', return_value=time.time() + 8 * runs.DAY):
            runs.collect(self.base, self.clear)
        self.assertFalse(work.exists())
