#!/usr/bin/env python3
"""Owned, bounded macOS verification sessions. No production data discovery or name-based kills."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
import zlib

from owned_files import atomic_json, canonical, directory_lock, owned_identity, same_identity
import owned_runs

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / '.nyaeh-verification'
SESSIONS = BASE / 'sessions'
REPORTS = BASE / 'reports'
HELPER = BASE / 'tools/host'
PREFIX = 'dev.gazelee.NyaEH.qa.'


def save(s):
    atomic_json(SESSIONS / s['id'] / 'session.json', s)


def load(session):
    if str(uuid.UUID(session)) != session:
        raise RuntimeError('Invalid session ID')
    folder = canonical(SESSIONS / session)
    s = json.loads((folder / 'session.json').read_text())
    if s['id'] != session or s['workspace'] != str(ROOT) or s['bundleID'] != PREFIX + session:
        raise RuntimeError('Session ownership mismatch')
    work = folder / 'work'
    container = Path.home() / 'Library/Containers' / (PREFIX + session)
    expected_data = container / 'Data/Library/Application Support/QA' if s['host'] == 'sandbox' else work / session / 'Data'
    expected = {'work': str(work), 'app': str(work / 'NyaEHQA.app'), 'source': str(work / session / 'Comics'),
                'data': str(expected_data), 'suite': PREFIX + session, 'log': str(work / 'verification.log')}
    if any(s.get(k) != value for k, value in expected.items()) or s['host'] not in ['swiftpm', 'sandbox']:
        raise RuntimeError('Session resource paths differ from the owned layout')
    if s.get('container', str(container)) != str(container): raise RuntimeError('Container ownership mismatch')
    return s


class CommandFailed(RuntimeError):
    def __init__(self, code, log):
        super().__init__(f'Command failed ({code}); see {log}')
        self.code = code


def run(command, log=None, env=None, pass_fds=()):
    if log:
        with open(log, 'a') as output:
            result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, pass_fds=pass_fds)
        if result.returncode:
            raise CommandFailed(result.returncode, log)
    else:
        subprocess.run([str(x) for x in command], cwd=ROOT, env=env, check=True)


def helper(*args):
    return subprocess.check_output([str(HELPER), *map(str, args)], text=True).strip()


def ensure_helper():
    source = ROOT / 'script/testing/host.swift'
    with directory_lock(HELPER.parent):
        if not HELPER.exists() or HELPER.stat().st_mtime < source.stat().st_mtime:
            with tempfile.TemporaryDirectory(dir=HELPER.parent) as stage:
                candidate = Path(stage) / 'host'
                run(['swiftc', source, '-o', candidate])
                candidate.replace(HELPER)


def apps(s):
    return json.loads(helper('list', s['app'], s['bundleID']))


def stop(s):
    running = apps(s)
    expected = s.get('process')
    if running and (len(running) != 1 or not expected or running[0] != expected):
        raise RuntimeError('Live application identity differs from recorded process; refusing stop')
    for app in running:
        helper('stop', s['app'], s['bundleID'], app['pid'], app['started'], 10)
    if apps(s):
        raise RuntimeError('Application is still running')
    return bool(running)


def resource(s, path):
    r = owned_identity(path)
    if r not in s['resources']:
        s['resources'].append(r)
    save(s)


def owned_directory(s, path):
    # Intent is durable before creation. A crash between creation and identity registration
    # leaves an explicitly reported unverified resource, never something guessed by cleanup.
    path = canonical(path)
    s['intents'].append(str(path)); save(s)
    path.mkdir(parents=True, exist_ok=False)
    resource(s, path)


def environment(s):
    env = os.environ.copy()
    # Do not inherit unrelated testing or benchmark switches into this host.
    for key in list(env):
        if key.startswith('NYAEH_'):
            del env[key]
    env.update(NYAEH_APP_SUPPORT_DIR=s['data'], NYAEH_USER_DEFAULTS_SUITE=s['suite'],
               NYAEH_CREDENTIAL_STORE='developmentPlaintext', NYAEH_TEST_SESSION=s['id'],
               NYAEH_TEST_SOURCE_ROOT=s['source'], NYAEH_DEVELOPMENT_COMIC_PATH=str(Path(s['source']) / ('comictest.zip' if s['id'] == 'development' else 'QA-1.cbz')))
    return env


def fixture_files(folder):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 32, 48, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress((b'\x00' + bytes([40, 110, 180]) * 32) * 48)) + chunk(b'IEND', b'')
    files = []
    for n in [1, 2]:
        path = folder / f'QA-{n}.cbz'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('1.png', png); archive.writestr('2.png', png)
        info = owned_identity(path)
        info.update(size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        files.append(info)
    return files


def info_for(s, profile='qa'):
    return {'CFBundleIdentifier': s['bundleID'], 'CFBundleName': s['name'], 'CFBundleDisplayName': s['name'],
            'NyaEHTestProfile': profile, 'NyaEHTestSession': s['id'], 'NyaEHTestDataRoot': s['data'],
            'NyaEHTestSourceRoot': s['source'], 'NyaEHTestDefaultsSuite': s['suite'], 'NyaEHTestHost': s['host']}


def stage_swiftpm(s, profile='qa'):
    log = s['log']
    run(['swift', 'build', '--product', 'NyaEHDevRunner'], log)
    binpath = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()
    app = Path(s['app']); (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    executable = 'NyaEHDev' if profile == 'development' else 'NyaEHQA'
    executable_path = app / 'Contents/MacOS' / executable
    shutil.copy2(Path(binpath) / 'NyaEHDevRunner', executable_path)
    sparkle = Path(binpath) / 'Sparkle.framework'
    if not sparkle.is_dir():
        raise RuntimeError(f'Missing SwiftPM Sparkle framework: {sparkle}')
    (app / 'Contents/Frameworks').mkdir(parents=True, exist_ok=True)
    shutil.copytree(sparkle, app / 'Contents/Frameworks/Sparkle.framework', symlinks=True)
    # SwiftPM's executable uses an @rpath framework; its build-directory rpath
    # is unavailable after staging the independent QA/development app bundle.
    # SwiftPM signs its executable in the build directory. Change only the copied
    # executable, removing that signature before editing its load commands.
    subprocess.run(['codesign', '--remove-signature', executable_path], check=True)
    subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', executable_path], check=True)
    subprocess.run(['codesign', '--sign', '-', executable_path], check=True)
    subprocess.run(['codesign', '--verify', '--strict', executable_path], check=True)
    info = info_for(s, profile)
    info.update(CFBundleExecutable=executable, CFBundlePackageType='APPL', LSMinimumSystemVersion='26.0', NSPrincipalClass='NSApplication')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))


def stage_sandbox(s):
    # Xcode product identity is overridden only for this build, never in the project.
    build = Path(s['work']) / 'XcodeProducts'
    run(['xcodebuild', '-project', ROOT / 'Packaging/NyaEH/NyaEH.xcodeproj', '-scheme', 'NyaEH',
         '-configuration', 'Debug', 'build', f'PRODUCT_BUNDLE_IDENTIFIER={s["bundleID"]}',
         f'CONFIGURATION_BUILD_DIR={build}', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_ALLOWED=YES',
         'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM='], s['log'])
    shutil.move(str(build / 'NyaEH.app'), s['app'])
    info_path = Path(s['app']) / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes()); info.update(info_for(s))
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-write': True,
                    'com.apple.security.network.client': True, 'com.apple.security.network.server': True,
                    'com.apple.security.files.bookmarks.app-scope': True,
                    'com.apple.security.get-task-allow': True,
                    'com.apple.security.temporary-exception.mach-lookup.global-name':
                    [f'{s["bundleID"]}-spks', f'{s["bundleID"]}-spki']}
    ent = Path(s['work']) / 'entitlements.plist'; ent.write_bytes(plistlib.dumps(entitlements))
    run(['codesign', '--force', '--deep', '--sign', '-', '--options', 'runtime', '--entitlements', ent, s['app']], s['log'])
    run(['codesign', '--verify', '--deep', '--strict', s['app']], s['log'])
    blob = subprocess.check_output(['codesign', '-d', '--entitlements', '-', s['app']], stderr=subprocess.DEVNULL)
    for key in ['com.apple.security.app-sandbox', 'com.apple.security.files.user-selected.read-write', 'com.apple.security.files.bookmarks.app-scope']:
        if key.encode() not in blob or b'<false/>' in blob:
            raise RuntimeError('Sandbox entitlement verification failed')
    s['localResign'] = True; save(s)


def launch(s):
    ready = Path(s['data']) / 'ready.json'
    if ready.exists(): ready.unlink()
    env = environment(s)
    command = ['open', '-n']
    for k, v in env.items():
        if k.startswith('NYAEH_'): command += ['--env', f'{k}={v}']
    if s.get('benchmark'): command += ['--env', 'NYAEH_SEARCH_SCROLL_BENCHMARK=1']
    command.append(s['app'])
    run(command, s['log'])
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        running = apps(s)
        if len(running) > 1: raise RuntimeError('Multiple matching hosts')
        if running:
            s['process'] = running[0]
            if s['id'] != 'development': save(s)
        if ready.exists() and running:
            record = json.loads(ready.read_text())
            expected = dict(session=s['id'], pid=running[0]['pid'], host=s['host'], dataRoot=s['data'], bundleID=s['bundleID'], appPath=s['app'])
            if any(record.get(key) != value for key, value in expected.items()):
                raise RuntimeError('Ready record mismatch')
            s['startup'] = 'passed'
            return
        time.sleep(0.2)
    raise RuntimeError('No verified readiness record within 30 seconds')


def allowed_resource(s, path):
    work = Path(s['work'])
    return path == work or path == Path(s.get('container', '/nonexistent-nyaeh-container'))


def clean_trash(s):
    errors = []
    folder = Path(s['data']) / 'trash-records'
    for record_path in folder.glob('*.json'):
        try:
            r = json.loads(record_path.read_text()); p = canonical(r['path'])
            source = canonical(r['source'])
            if r['session'] != s['id']:
                raise RuntimeError('trash ownership mismatch')
            if not ('.Trash' in p.parts or '.Trashes' in p.parts): raise RuntimeError('target is not a Trash location')
            if 'backupFiles' in r:
                roots = [Path(s['data']), Path(s['source']).parent]
                if not any(source.is_relative_to(root) for root in roots) or source.suffix not in ('.nyaehbackup', '.sqlite'):
                    raise RuntimeError('backup trash ownership mismatch')
                if p.exists():
                    if not same_identity(r):
                        raise RuntimeError('backup trash identity changed')
                    entries = [p, *p.rglob('*')] if p.is_dir() else [p]
                    hashes = {}
                    for entry in entries:
                        canonical(entry)
                        if not entry.is_dir() and not entry.is_file():
                            raise RuntimeError('unexpected backup entry')
                        key = '' if entry == p else '/' + str(entry.relative_to(p))
                        hashes[key] = 'directory' if entry.is_dir() else hashlib.sha256(entry.read_bytes()).hexdigest()
                    if hashes != r['backupFiles']:
                        raise RuntimeError('backup trash contents changed')
                    if p.is_dir(): shutil.rmtree(p)
                    else: p.unlink()
            else:
                if source.parent != Path(s['source']):
                    raise RuntimeError('trash ownership mismatch')
                if p.exists():
                    if not same_identity(r) or p.stat().st_size != r['size'] or hashlib.sha256(p.read_bytes()).hexdigest() != r['sha256']:
                        raise RuntimeError('trash file identity changed')
                    p.unlink()
            record_path.unlink()
        except Exception as e: errors.append(str(e))
    return errors


def report(s):
    REPORTS.mkdir(parents=True, exist_ok=True)
    fields = ['id', 'name', 'host', 'created', 'finished', 'status', 'build', 'tests', 'startup', 'ui', 'cleanup', 'issues', 'localResign', 'testSummary', 'testExitCode', 'testFailure', 'unitLog']
    atomic_json(REPORTS / (s['id'] + '.json'), {k: s.get(k) for k in fields})


def preference_path(domain):
    return Path.home() / 'Library/Preferences' / (domain + '.plist')


def preference_snapshot(path):
    canonical(path.parent)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as f:
        identity = os.fstat(f.fileno())
        if not stat.S_ISREG(identity.st_mode) or identity.st_uid != os.getuid() or identity.st_nlink != 1:
            raise RuntimeError(f'Unexpected preference file identity: {path.name}')
        return identity.st_dev, identity.st_ino, f.read()


def discard_snapshot(path, snapshot):
    latest = preference_snapshot(path)
    if latest is None:
        return
    if latest != snapshot:
        raise RuntimeError(f'Preference identity or contents changed: {path.name}')
    path.unlink(missing_ok=True)


def remove_domains(domains):
    if not domains:
        return
    paths = [preference_path(d) for d in domains]
    before = {path: preference_snapshot(path) for path in paths}
    if helper('preferences-delete', *domains) != 'cleared':
        raise RuntimeError('Preference backend did not confirm domain removal')
    for path in paths:
        snapshot = preference_snapshot(path)
        if snapshot is None:
            continue
        # A cleared domain can still have its old snapshot or an empty replacement on disk.
        if plistlib.loads(snapshot[2]) != {} and snapshot != before[path]:
            raise RuntimeError(f'Preference file changed during cleanup: {path.name}')
        discard_snapshot(path, snapshot)


# AppKit and cfprefsd have independent writeback schedules. Recheck the entire
# registered batch at 1, 5 and 15 seconds; a later write still has a 30-day receipt.
QA_EXIT_SETTLE_SECONDS = 15
PREFERENCE_RECHECK_DELAYS = (1, 4, 10)


def check_delayed_snapshots(domains):
    paths = [preference_path(domain) for domain in domains]
    for delay in PREFERENCE_RECHECK_DELAYS:
        time.sleep(delay)
        for path in paths:
            snapshot = preference_snapshot(path)
            if snapshot is not None:
                if plistlib.loads(snapshot[2]) != {}:
                    raise RuntimeError(f'Preferences changed after synchronization: {path.name}')
                discard_snapshot(path, snapshot)


def clear_unit_domains(domains, recheck):
    if recheck:
        domains = [d for d in domains if os.path.lexists(preference_path(d))]
    if domains:
        ensure_helper()
        remove_domains(domains)
        check_delayed_snapshots(domains)


def remove_preferences(s):
    remove_domains([s['suite']])


def cleanup(s):
    stopped_now = stop(s)
    errors = clean_trash(s)
    # Never remove the journal that is required to retry an uncleaned Trash item.
    if errors:
        s['cleanup'] = 'incomplete'; s['issues'] = errors; save(s); report(s); return
    try:
        if s.get('process'):
            # AppKit can publish window state after the host has disappeared from
            # NSWorkspace. Let that last write land before clearing its domain.
            stopped_at = time.time() if stopped_now else s.get('finished', 0)
            remaining = QA_EXIT_SETTLE_SECONDS - max(0, time.time() - stopped_at)
            if remaining > 0:
                time.sleep(remaining)
        remove_preferences(s)
        if s.get('process'):
            check_delayed_snapshots([s['suite']])
    except Exception as error:
        s['cleanup'] = 'incomplete'; s['issues'] = [str(error)]; save(s); report(s); return
    registered = {r['path'] for r in s['resources']}
    for intent in s['intents']:
        if intent not in registered and Path(intent).exists():
            errors.append(f'Unverified resource left after interruption: {intent}')
    for r in reversed(s['resources']):
        try:
            p = canonical(r['path'])
            if not allowed_resource(s, p) or not same_identity(r): raise RuntimeError(f'Resource ownership changed: {p}')
            if p.exists(): shutil.rmtree(p)
        except Exception as e: errors.append(str(e))
    s['cleanup'] = 'incomplete' if errors else 'complete'
    s['issues'] = errors; save(s); report(s)


def finish_failed_unit_stage(s):
    # Commit the log and exit status before disposing of the unused QA scaffolding.
    log = SESSIONS / s['id'] / 'unit-tests.log'
    source = canonical(Path(s['log']))
    if 'unitLog' not in s:
        if os.path.lexists(log):
            raise RuntimeError(f'Unregistered unit output: {log}')
        s['unitLog'] = dict(owned_identity(source), path=str(log))
        save(s)
    expected = s['unitLog']
    if expected['path'] != str(log):
        raise RuntimeError('Invalid unit output path')
    if not os.path.lexists(log):
        if owned_identity(source) != dict(expected, path=str(source)):
            raise RuntimeError('Unit test output changed before retention')
        source.rename(log)
    if owned_identity(log) != expected:
        raise RuntimeError(f'Replaced unit test output: {log}')
    s['tests'] = 'failed'
    save(s); report(s)
    clean_failed_unit_resources(s)


def clean_failed_unit_resources(s):
    try:
        owned_runs.finish_session_units(BASE, s['id'], clear_unit_domains)
    except Exception as error:
        unit_issue = str(error)
    else:
        unit_issue = None
    cleanup(s)
    if unit_issue:
        s['cleanup'] = 'incomplete'
        s['issues'].append(unit_issue)
        save(s); report(s)


def expire():
    owned_runs.collect(BASE, clear_unit_domains)
    now = time.time()
    for f in SESSIONS.glob('*/session.json'):
        s = load(f.parent.name)
        if apps(s): continue
        if s['status'] == 'preparing':
            s.update(status='interrupted', finished=s['created']); save(s); report(s)
        if s.get('tests') == 'running':
            finish_failed_unit_stage(s)
        elif 'unitLog' in s and s.get('cleanup') != 'complete':
            clean_failed_unit_resources(s)
        age = now - s.get('finished', s['created'])
        late_preferences = s.get('cleanup') == 'complete' and os.path.lexists(preference_path(s['suite']))
        if late_preferences or s.get('preferenceRetry'):
            try:
                remove_preferences(s)
                check_delayed_snapshots([s['suite']])
                if os.path.lexists(preference_path(s['suite'])):
                    raise RuntimeError('QA preferences reappeared during reconciliation')
                if s.pop('preferenceRetry', False):
                    s.update(cleanup='complete', issues=[]); save(s); report(s)
            except Exception as error:
                s.update(cleanup='incomplete', preferenceRetry=True, issues=[str(error)])
                save(s); report(s)
                continue
        elif s.get('cleanup') != 'complete' and age >= 7 * 86400:
            cleanup(s)
        if s.get('cleanup') == 'complete' and age >= 30 * 86400:
            if 'unitLog' in s:
                log = f.parent / 'unit-tests.log'
                if s['unitLog']['path'] != str(log) or not same_identity(s['unitLog']):
                    s['issues'] = ['Retained replaced unit test log']; save(s); report(s)
                    continue
                log.unlink(missing_ok=True)
            compact = REPORTS / (s['id'] + '.json')
            if os.path.lexists(compact):
                identity = owned_identity(compact)
                contents = json.loads(compact.read_bytes())
                if any(contents.get(k) != s[k] for k in ('id', 'created', 'host')) or not same_identity(identity):
                    print(f'Retained mismatched report: {compact}', file=sys.stderr)
                else:
                    compact.unlink()
            f.unlink(); f.parent.rmdir()


@contextlib.contextmanager
def lock():
    BASE.mkdir(exist_ok=True); canonical(BASE)
    with open(BASE / 'lock', 'a') as f:
        try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('Another verification command owns this workspace')
        yield f


def new_session(sandbox):
    for f in SESSIONS.glob('*/session.json'):
        previous = load(f.parent.name)
        if apps(previous): raise RuntimeError(f'Finish active session first: {previous["id"]}')
    sid = str(uuid.uuid4()); folder = SESSIONS / sid; folder.mkdir(parents=True)
    work = folder / 'work'; bundle = PREFIX + sid
    container = Path.home() / 'Library/Containers' / bundle
    # All session data/source paths include the exact UUID, including sandbox fixtures.
    data = container / 'Data/Library/Application Support/QA' if sandbox else work / sid / 'Data'
    source = work / sid / 'Comics'
    s = dict(id=sid, workspace=str(ROOT), created=time.time(), status='preparing', host='sandbox' if sandbox else 'swiftpm',
             name=f'NyaEH 验收版 · {sid[:8]}' + (' · 沙盒' if sandbox else ''), bundleID=bundle, suite=bundle,
             work=str(work), app=str(work / 'NyaEHQA.app'), data=str(data), source=str(source),
             log=str(work / 'verification.log'), resources=[], intents=[], issues=[], ui='not-requested', cleanup='pending')
    save(s); owned_directory(s, work)
    if sandbox:
        s['container'] = str(container); save(s); owned_directory(s, container)
    data.mkdir(parents=True); source.mkdir(parents=True)
    atomic_json(data / 'ownership.json', {'session': sid, 'files': fixture_files(source)})
    return s


def development_root(workspace):
    root = workspace / '.nyaeh-dev'
    legacy = workspace / '.treec-dev'
    if legacy.is_symlink() or root.is_symlink():
        raise RuntimeError('Development data must not be a symbolic link')
    if not root.exists() and legacy.exists():
        owned_identity(legacy)
        if not legacy.is_dir():
            raise RuntimeError('Previous development data is not a directory')
        app = {'app': str(workspace / 'dist/NyaEHDev.app'), 'bundleID': 'dev.gazelee.NyaEH'}
        if apps(app):
            raise RuntimeError('Close the previous development app before migrating its data')
        legacy.rename(root)
    return root


def dev(mode):
    if mode not in ['run', '--logs', 'logs', '--telemetry', 'telemetry', '--debug', 'debug', '--scroll-benchmark', 'scroll-benchmark']:
        raise RuntimeError('Unknown development mode')
    root = development_root(ROOT); data = root / 'Application Support/NyaEH'; source = root / 'comic'
    data.mkdir(parents=True, exist_ok=True); source.mkdir(exist_ok=True)
    launch_file = root / 'active-launch.json'
    s = dict(id='development', app=str(ROOT / 'dist/NyaEHDev.app'), bundleID='dev.gazelee.NyaEH',
             name='NyaEH 开发版', data=str(data), source=str(source), suite='NyaEH.Development', host='swiftpm', log=str(root / 'build.log'))
    if mode in ['--scroll-benchmark', 'scroll-benchmark']:
        s['benchmark'] = True
    replace_development_app(s, launch_file)
    print(s['name'], s['app'])
    if mode in ['--logs', 'logs', '--telemetry', 'telemetry']:
        run(['log', 'stream', '--info', '--style', 'compact', '--predicate', f'processIdentifier == {s["process"]["pid"]}'])
    elif mode in ['--debug', 'debug']:
        run(['lldb', '-p', str(s['process']['pid'])])
    elif mode not in ['run', '--scroll-benchmark', 'scroll-benchmark']:
        raise RuntimeError('Unknown development mode')


def replace_development_app(s, launch_file):
    app = canonical(s['app']) if Path(s['app']).exists() else Path(s['app'])
    app.parent.mkdir(parents=True, exist_ok=True)
    dist = canonical(app.parent)
    old = json.loads(launch_file.read_text()) if launch_file.exists() else None
    if old and any(old.get(key) != s[key] for key in ['id', 'app', 'bundleID', 'data', 'source', 'suite']):
        raise RuntimeError('Development launch record does not match this workspace')
    if not old and apps(s):
        raise RuntimeError('Unregistered development process; close it before rebuilding')
    # A failed build cannot disturb the currently running app or retained data.
    with tempfile.TemporaryDirectory(prefix='.NyaEHDev-stage-', dir=dist) as stage_dir:
        staged = Path(stage_dir) / app.name
        candidate = dict(s, app=str(staged))
        stage_swiftpm(candidate, 'development')
        backup = dist / f'.NyaEHDev-backup-{uuid.uuid4().hex}.app'
        replaced = False
        stopped_old = False
        try:
            if old:
                stop(old)
                stopped_old = True
            elif apps(s): raise RuntimeError('Unregistered development process appeared during build')
            if app.exists(): app.rename(backup)
            staged.rename(app)
            replaced = True
            launch(s)
            atomic_json(launch_file, s)
        except Exception as error:
            rollback_errors = []
            if replaced:
                # Only the exact newly recorded process may be stopped.
                try: stop(s)
                except Exception as failure: rollback_errors.append(str(failure))
                if not rollback_errors:
                    try:
                        failed = dist / f'.NyaEHDev-failed-{uuid.uuid4().hex}.app'
                        app.rename(failed)
                        restored_backup = backup.exists()
                        if restored_backup: backup.rename(app)
                        if old and restored_backup:
                            restored = dict(old)
                            restored.pop('process', None)
                            launch(restored)
                            atomic_json(launch_file, restored)
                        shutil.rmtree(failed)
                    except Exception as failure: rollback_errors.append(str(failure))
            elif stopped_old:
                try:
                    if backup.exists(): backup.rename(app)
                    if old:
                        restored = dict(old)
                        restored.pop('process', None)
                        launch(restored)
                        atomic_json(launch_file, restored)
                except Exception as failure: rollback_errors.append(str(failure))
            if rollback_errors:
                raise RuntimeError(f'{error}; rollback incomplete: {"; ".join(rollback_errors)}') from error
            raise
        else:
            if backup.exists(): shutil.rmtree(backup)


def main():
    if sys.argv[1:2] == ['scratch']:
        if sys.argv[2:3] != ['--'] or not sys.argv[3:]:
            raise ValueError('usage: verify.sh scratch -- COMMAND [ARG ...]')
        with lock():
            ensure_helper()
            expire()
        return owned_runs.scratch(BASE, ROOT, sys.argv[3:])
    parser = argparse.ArgumentParser()
    parser.add_argument('command', nargs='?', default='run', choices=['run', 'dev', 'status', 'finish', 'restart', 'cleanup'])
    parser.add_argument('value', nargs='?')
    parser.add_argument('--ui', action='store_true'); parser.add_argument('--sandbox', action='store_true')
    parser.add_argument('--startup-only', action='store_true'); parser.add_argument('--expired', action='store_true')
    result = parser.add_mutually_exclusive_group(); result.add_argument('--passed', action='store_true'); result.add_argument('--failed', action='store_true')
    args = parser.parse_args()
    with lock() as workspace_lock:
        ensure_helper(); SESSIONS.mkdir(exist_ok=True); REPORTS.mkdir(exist_ok=True)
        expire()
        if args.command == 'dev': dev(args.value or 'run'); return
        if args.command == 'status':
            for f in SESSIONS.glob('*/session.json'):
                s = load(f.parent.name)
                print(json.dumps({k: s.get(k) for k in ['id', 'host', 'status', 'ui', 'cleanup', 'issues']}, ensure_ascii=False))
            return
        if args.command == 'cleanup':
            if args.value:
                s = load(args.value); cleanup(s)
                if s['cleanup'] != 'complete': raise RuntimeError('Cleanup incomplete; see session report')
            elif not args.expired: parser.error('cleanup requires --expired or a session ID')
            return
        if args.command == 'restart':
            if not args.value: parser.error('restart requires a session ID')
            s = load(args.value)
            if s.get('cleanup') == 'complete': raise RuntimeError('Session was cleaned; start a new one')
            for f in SESSIONS.glob('*/session.json'):
                other = load(f.parent.name)
                if other['id'] != s['id'] and apps(other): raise RuntimeError('Another QA host is active')
            stop(s); launch(s); s.update(status='pending-ui', ui='pending'); save(s); report(s)
            print(f'Restarted pending UI session: {s["id"]}'); return
        if args.command == 'finish':
            if not args.value or not (args.passed or args.failed): parser.error('finish ID --passed/--failed')
            s = load(args.value)
            if args.passed and s.get('startup') != 'passed': raise RuntimeError('Cannot pass a session without verified startup')
            stop(s)
            s.update(status='passed' if args.passed else 'failed', ui=('passed' if args.passed else 'failed') if s.get('ui') == 'pending' else s.get('ui'), finished=time.time()); save(s)
            if args.passed:
                cleanup(s)
                if s['cleanup'] != 'complete': raise RuntimeError('Cleanup incomplete; see session report')
            else: report(s)
            return
        s = new_session(args.sandbox)
        try:
            if not args.startup_only:
                run(['swift', 'build'], s['log'], environment(s)); s['build'] = 'passed'; save(s)
                s['tests'] = 'running'; save(s)
                run(['swift', 'test'], s['log'], environment(s), pass_fds=(workspace_lock.fileno(),))
                s['testExitCode'] = 0; save(s)
                owned_runs.finish_session_units(BASE, s['id'], clear_unit_domains)
                s['tests'] = 'passed'
                summaries = [line.strip() for line in Path(s['log']).read_text().splitlines() if 'Test run with ' in line]
                s['testSummary'] = summaries[-1] if summaries else 'swift test exited successfully'; save(s)
                run([sys.executable, '-m', 'unittest', 'discover', '-s', 'script/testing', '-p', 'test_*.py'], s['log']); save(s)
            if args.sandbox: stage_sandbox(s)
            else: stage_swiftpm(s)
            s['build'] = 'passed'; save(s)
            launch(s)
            if args.ui:
                s.update(status='pending-ui', ui='pending'); save(s); report(s)
                print(f'Pending UI verification: {s["id"]}\nApp: {s["app"]}\nSynthetic library: {s["source"]}\nFinish explicitly with: ./script/verify.sh finish {s["id"]} --passed/--failed')
            else:
                stop(s); s.update(status='passed', finished=time.time()); save(s); cleanup(s)
                print(f'Session {s["id"]}: passed; cleanup {s["cleanup"]}')
                if s['cleanup'] != 'complete': raise RuntimeError('Cleanup incomplete; see session report')
        except BaseException as error:
            issues = list(s.get('issues', []))
            if str(error) not in issues:
                issues.append(str(error))
            s.update(status='interrupted' if isinstance(error, KeyboardInterrupt) else 'failed', finished=time.time(), issues=issues)
            if s.get('tests') == 'running':
                s['testFailure'] = str(error)
                s['testExitCode'] = s.get('testExitCode', getattr(error, 'code', 130 if isinstance(error, KeyboardInterrupt) else None))
                save(s)
                finish_failed_unit_stage(s)
                print(f'Swift tests {s["status"]}; log: {s["unitLog"]["path"]}; cleanup {s["cleanup"]}', file=sys.stderr)
                raise
            try: stop(s)
            except Exception as stop_error: s['issues'].append(str(stop_error))
            save(s); report(s)
            print(f'Session retained for 7 days: {s["id"]}; log: {s["log"]}', file=sys.stderr)
            raise


if __name__ == '__main__':
    try: sys.exit(main())
    except CommandFailed as error:
        print(str(error), file=sys.stderr); sys.exit(error.code if error.code > 0 else 128 - error.code)
    except Exception as error:
        print(str(error), file=sys.stderr); sys.exit(1)
