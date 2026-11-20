import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import verify as v


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.patches = [patch.object(v, 'ROOT', self.root), patch.object(v, 'BASE', self.root / 'verification'),
                        patch.object(v, 'SESSIONS', self.root / 'verification/sessions'), patch.object(v, 'REPORTS', self.root / 'verification/reports'),
                        patch.object(v, 'apps', return_value=[]), patch.object(v, 'helper', return_value='cleared')]
        for p in self.patches: p.start()
        v.SESSIONS.mkdir(parents=True); v.REPORTS.mkdir()
    def tearDown(self):
        for p in reversed(self.patches): p.stop()
        self.temp.cleanup()
    def test_success_cleanup_is_idempotent_and_preserves_sentinel(self):
        sentinel = self.root / 'production.sqlite'; sentinel.write_text('untouched')
        s = v.new_session(False); v.cleanup(s); v.cleanup(s)
        self.assertEqual(s['cleanup'], 'complete')
        self.assertFalse(Path(s['work']).exists())
        self.assertEqual(sentinel.read_text(), 'untouched')
    def test_backup_trash_requires_an_exact_session_tree(self):
        s = v.new_session(False)
        source = Path(s['data']) / 'Backups' / 'automatic-test.nyaehbackup'
        moved = self.root / '.Trash' / source.name
        moved.mkdir(parents=True)
        (moved / 'manifest.json').write_bytes(b'synthetic')
        record = v.owned_identity(moved) | dict(session=s['id'], source=str(source), backupFiles={
            '': 'directory', '/manifest.json': hashlib.sha256(b'synthetic').hexdigest()})
        folder = Path(s['data']) / 'trash-records'
        folder.mkdir()
        (folder / 'one.json').write_text(json.dumps(record))
        other = moved / 'unexpected'
        other.write_text('preserve')
        self.assertTrue(v.clean_trash(s))
        self.assertTrue(other.is_file())
        other.unlink()
        self.assertEqual(v.clean_trash(s), [])
        self.assertFalse(moved.exists())

    def test_resource_replacement_is_not_deleted(self):
        s = v.new_session(False)
        s['resources'][0]['inode'] += 1
        v.cleanup(s)
        self.assertEqual(s['cleanup'], 'incomplete')
        self.assertTrue(Path(s['work']).exists())
    def test_symlink_escape_is_rejected(self):
        outside = self.root / 'outside'; outside.mkdir()
        alias = self.root / 'alias'; alias.symlink_to(outside)
        with self.assertRaises(RuntimeError): v.canonical(alias)
    def test_legacy_development_root_migrates_only_when_the_app_is_stopped(self):
        old = self.root / '.treec-dev'
        old.mkdir()
        (old / 'data').write_text('retained')
        with patch.object(v, 'apps', return_value=[{'pid': 123, 'started': 2}]):
            with self.assertRaisesRegex(RuntimeError, 'Close the previous development app'):
                v.development_root(self.root)
        self.assertTrue(old.exists())
        new = v.development_root(self.root)
        self.assertEqual(new, self.root / '.nyaeh-dev')
        self.assertEqual((new / 'data').read_text(), 'retained')
        self.assertFalse(old.exists())
        self.assertEqual(v.development_root(self.root), new)
    def test_stale_process_identity_never_stops_replacement(self):
        s = v.new_session(False); s['process'] = {'pid': 123, 'started': 1}
        with patch.object(v, 'apps', return_value=[{'pid': 123, 'started': 2}]):
            with self.assertRaises(RuntimeError): v.stop(s)
        v.helper.assert_not_called()
    def test_active_session_prevents_second_host(self):
        v.new_session(False)
        with patch.object(v, 'apps', return_value=[{'pid': 42}]):
            with self.assertRaises(RuntimeError): v.new_session(False)
    def test_failed_session_expires_after_seven_days(self):
        s = v.new_session(False); s.update(status='failed', finished=time.time()); v.save(s)
        v.expire(); self.assertTrue(Path(s['work']).exists())
        s['finished'] -= 8 * 86400; v.save(s)
        v.expire(); self.assertFalse(Path(s['work']).exists())
    def test_expiration_does_not_clean_running_session(self):
        s = v.new_session(False); s['created'] -= 8 * 86400; v.save(s)
        with patch.object(v, 'apps', return_value=[{'pid': 42}]): v.expire()
        self.assertTrue(Path(s['work']).exists())
    def test_unregistered_interrupted_resource_is_reported(self):
        s = v.new_session(False)
        unknown = self.root / 'unknown'; unknown.mkdir()
        s['intents'].append(str(unknown)); v.cleanup(s)
        self.assertTrue(unknown.exists()); self.assertEqual(s['cleanup'], 'incomplete')
    def test_trash_identity_change_retains_retry_journal(self):
        s = v.new_session(False)
        trash = self.root / '.Trash'; trash.mkdir(); item = trash / 'synthetic'; item.write_text('original')
        r = v.owned_identity(item); r.update(session=s['id'], source=s['source'] + '/QA-1.cbz', size=8, sha256='wrong')
        records = Path(s['data']) / 'trash-records'; records.mkdir(); v.atomic_json(records / 'item.json', r)
        v.cleanup(s)
        self.assertTrue(item.exists()); self.assertTrue(records.exists()); self.assertEqual(s['cleanup'], 'incomplete')
    def test_manifest_cannot_redirect_cleanup_to_unrelated_data(self):
        s = v.new_session(False)
        s['work'] = str(self.root / 'production')
        v.save(s)
        with self.assertRaises(RuntimeError): v.load(s['id'])
    def test_empty_preference_file_is_removed(self):
        s = v.new_session(False)
        prefs = self.root / 'Library/Preferences'; prefs.mkdir(parents=True)
        p = prefs / (s['suite'] + '.plist'); p.write_bytes(v.plistlib.dumps({}))
        with patch.object(Path, 'home', return_value=self.root): v.remove_preferences(s)
        self.assertFalse(p.exists())
    def test_changed_preference_file_requires_retry(self):
        s = v.new_session(False)
        prefs = self.root / 'Library/Preferences'; prefs.mkdir(parents=True)
        p = prefs / (s['suite'] + '.plist'); p.write_bytes(v.plistlib.dumps({'not-cleared': True}))
        def clear_then_unexpected_write(*args):
            p.write_bytes(v.plistlib.dumps({'unexpected-new-writer': True}))
            return 'cleared'
        with patch.object(Path, 'home', return_value=self.root), patch.object(v, 'helper', side_effect=clear_then_unexpected_write):
            with self.assertRaises(RuntimeError): v.remove_preferences(s)
        self.assertTrue(p.exists())
    def test_completed_session_rechecks_late_preferences_before_expiring_record(self):
        s = v.new_session(False)
        s.update(status='passed', finished=time.time() - 31 * 86400)
        v.cleanup(s)
        prefs = self.root / 'Library/Preferences'
        prefs.mkdir(parents=True)
        late = prefs / (s['suite'] + '.plist')
        sentinel = prefs / 'NyaEH.Development.plist'
        late.write_bytes(v.plistlib.dumps({'NSWindow Frame': 'test'}))
        sentinel.write_bytes(b'unrelated')
        with patch.object(Path, 'home', return_value=self.root), patch.object(v, 'helper', side_effect=RuntimeError('busy')):
            v.expire()
            retained = v.load(s['id'])
            self.assertTrue(retained['preferenceRetry'])
            self.assertTrue(late.exists())
        with patch.object(Path, 'home', return_value=self.root), patch.object(v, 'PREFERENCE_RECHECK_DELAYS', (0,)):
            v.expire()
        self.assertFalse(late.exists())
        self.assertFalse((v.SESSIONS / s['id']).exists())
        self.assertEqual(sentinel.read_bytes(), b'unrelated')

    def test_swift_test_failure_keeps_only_output_and_exit_status(self):
        def fail_tests(command, log, env, **options):
            if command[:2] == ['swift', 'test']:
                Path(log).write_text('a test assertion failed')
                raise v.CommandFailed(7, log)
        with patch.object(v, 'ensure_helper'), patch.object(v, 'run', side_effect=fail_tests), patch.object(v.sys, 'argv', ['verify']):
            with self.assertRaises(v.CommandFailed):
                v.main()
        f, = v.SESSIONS.glob('*/session.json')
        result = v.load(f.parent.name)
        self.assertEqual((result['cleanup'], result['testExitCode'], result['tests']), ('complete', 7, 'failed'))
        self.assertEqual(Path(result['unitLog']['path']).read_text(), 'a test assertion failed')
        self.assertFalse(Path(result['work']).exists())
        with patch.object(time, 'time', return_value=time.time() + 31 * 86400):
            v.expire()
        self.assertFalse(f.parent.exists())

    def test_expiration_only_removes_the_completed_sessions_own_report(self):
        exported = v.REPORTS / 'exported-metrics.json'
        exported.write_text('{"score": 1}')
        s = v.new_session(False)
        s.update(status='passed', finished=time.time())
        v.cleanup(s)
        with patch.object(time, 'time', return_value=time.time() + 31 * 86400):
            v.expire()
        self.assertFalse((v.REPORTS / (s['id'] + '.json')).exists())
        self.assertEqual(exported.read_text(), '{"score": 1}')

    def test_qa_shutdown_waits_for_final_window_write_before_clearing(self):
        s = v.new_session(False)
        s.update(status='passed', finished=time.time(), process={'pid': 42, 'started': 1})
        prefs = self.root / 'Library/Preferences'
        prefs.mkdir(parents=True)
        late = prefs / (s['suite'] + '.plist')
        writes = [dict(window='closed'), None, {}, {}]
        def write_snapshot(_):
            snapshot = writes.pop(0)
            if snapshot is not None:
                late.write_bytes(v.plistlib.dumps(snapshot))
        with patch.object(Path, 'home', return_value=self.root), patch.object(time, 'sleep', side_effect=write_snapshot):
            v.cleanup(s)
        self.assertFalse(writes)
        self.assertEqual(s['cleanup'], 'complete')
        self.assertFalse(late.exists())

    def test_stop_timeout_preserves_all_resources(self):
        s = v.new_session(False)
        with patch.object(v, 'stop', side_effect=RuntimeError('timeout')):
            with self.assertRaises(RuntimeError): v.cleanup(s)
        self.assertTrue(Path(s['work']).exists())


class DevelopmentReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.root_patch = patch.object(v, 'ROOT', self.root)
        self.root_patch.start()
        self.app = self.root / 'dist/NyaEHDev.app'
        self.app.mkdir(parents=True)
        (self.app / 'version').write_text('old')
        self.data = self.root / '.nyaeh-dev/Application Support/NyaEH'
        self.data.mkdir(parents=True)
        (self.data / 'sentinel').write_text('retained')
        self.record = self.root / '.nyaeh-dev/launch.json'
        self.s = dict(id='development', app=str(self.app), bundleID='dev.gazelee.NyaEH',
                      data=str(self.data), source=str(self.root / '.nyaeh-dev/comic'),
                      suite='NyaEH.Development', log=str(self.root / '.nyaeh-dev/build.log'))
        v.atomic_json(self.record, dict(self.s, process={'pid': 1, 'started': 1}))
    def tearDown(self):
        self.root_patch.stop()
        self.temp.cleanup()
    def stage(self, candidate, profile):
        app = Path(candidate['app'])
        app.mkdir()
        (app / 'version').write_text('new')
    def launched(self, s):
        s['process'] = {'pid': 2, 'started': 2}
    def test_repeated_replacement_preserves_data(self):
        with patch.object(v, 'stage_swiftpm', side_effect=self.stage), \
             patch.object(v, 'stop'), patch.object(v, 'launch', side_effect=self.launched):
            v.replace_development_app(self.s, self.record)
            self.assertEqual((self.app / 'version').read_text(), 'new')
            v.replace_development_app(self.s, self.record)
        self.assertEqual((self.data / 'sentinel').read_text(), 'retained')
        self.assertEqual(json.loads(self.record.read_text())['process']['pid'], 2)
    def test_build_failure_keeps_old_app_and_record(self):
        prior = self.record.read_bytes()
        with patch.object(v, 'stage_swiftpm', side_effect=RuntimeError('build failed')), \
             patch.object(v, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                v.replace_development_app(self.s, self.record)
        stop.assert_not_called()
        self.assertEqual((self.app / 'version').read_text(), 'old')
        self.assertEqual(self.record.read_bytes(), prior)
    def test_launch_failure_restores_and_restarts_old_app(self):
        def launch(s):
            if (self.app / 'version').read_text() == 'new': raise RuntimeError('launch failed')
            s['process'] = {'pid': 3, 'started': 3}
        with patch.object(v, 'stage_swiftpm', side_effect=self.stage), \
             patch.object(v, 'stop') as stop, patch.object(v, 'launch', side_effect=launch):
            with self.assertRaisesRegex(RuntimeError, 'launch failed'):
                v.replace_development_app(self.s, self.record)
        self.assertEqual(stop.call_count, 2)
        self.assertEqual((self.app / 'version').read_text(), 'old')
        self.assertEqual(json.loads(self.record.read_text())['process']['pid'], 3)
    def test_swap_failure_restores_old_app(self):
        rename = Path.rename
        def fail_new_bundle(path, target):
            if path.name == 'NyaEHDev.app' and '.NyaEHDev-stage-' in str(path.parent):
                raise OSError('swap failed')
            return rename(path, target)
        with patch.object(v, 'stage_swiftpm', side_effect=self.stage), \
             patch.object(v, 'stop'), patch.object(Path, 'rename', fail_new_bundle), \
             patch.object(v, 'launch', side_effect=self.launched) as launch:
            with self.assertRaisesRegex(OSError, 'swap failed'):
                v.replace_development_app(self.s, self.record)
        launch.assert_called_once()
        self.assertEqual((self.app / 'version').read_text(), 'old')
    def test_stale_identity_refuses_replacement(self):
        with patch.object(v, 'stage_swiftpm', side_effect=self.stage), \
             patch.object(v, 'stop', side_effect=RuntimeError('identity mismatch')):
            with self.assertRaisesRegex(RuntimeError, 'identity mismatch'):
                v.replace_development_app(self.s, self.record)
        self.assertEqual((self.app / 'version').read_text(), 'old')

if __name__ == '__main__': unittest.main()
