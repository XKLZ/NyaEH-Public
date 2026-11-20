"""Lifetimes of unit-test fixtures and one-shot builds, independent of the QA app lock."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

from owned_files import atomic_json, canonical, directory_lock, owned_identity, same_identity

DAY = 86400
UNIT_PREFIX = 'dev.gazelee.NyaEH.unit.'


def valid_id(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def register(folder, sid):
    if not valid_id(sid):
        raise ValueError('Expected a canonical run UUID')
    work = canonical(folder / sid)
    journal = work.with_suffix('.json')
    if os.path.lexists(journal) or os.path.lexists(work):
        raise RuntimeError(f'Run already exists: {sid}')
    record = dict(id=sid, registry=str(folder), created=time.time(), status='running',
                  lease=owned_identity(work.with_suffix('.lease')), work=None)
    session = os.environ.get('NYAEH_TEST_SESSION')
    if folder.name == 'unit-runs' and session and valid_id(session):
        record['qaSession'] = session
    atomic_json(journal, record)
    work.mkdir(mode=0o700)
    record['work'] = owned_identity(work)
    atomic_json(journal, record)
    return work


@contextlib.contextmanager
def available_lease(path, record):
    if not os.path.lexists(path):
        if record.get('status') != 'cleaned':
            raise RuntimeError(f'Missing run lease: {path}')
        yield True
        return
    if record['lease'] != owned_identity(path):
        raise RuntimeError(f'Replaced run lease: {path}')
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(fd)


def qa_waiting_for_result(base, session):
    # The verify parent writes the exit code and relocates a failed log before releasing
    # its unit fixtures. A dead parent cannot strand a run: its workspace lock drops.
    manifest = canonical(base / 'sessions' / session / 'session.json')
    if not manifest.exists() or json.loads(manifest.read_bytes()).get('tests') != 'running':
        return False
    with canonical(base / 'lock').open('rb') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False


def collect_one(folder, sid, clear_domains, now, releasing_session=None):
    """Called under the registry lock. Only a dead process can surrender its lease."""
    journal = canonical(folder / (sid + '.json'))
    if not journal.exists():
        return
    owned_identity(journal)
    record = json.loads(journal.read_bytes())
    if not valid_id(sid) or record['id'] != sid or record['registry'] != str(folder):
        raise RuntimeError(f'Run ownership mismatch: {journal}')
    work = canonical(folder / sid)
    lease = work.with_suffix('.lease')
    is_unit = folder.name == 'unit-runs'
    session = record.get('qaSession')
    if is_unit and session and releasing_session != session and record['status'] != 'cleaned':
        if not valid_id(session):
            raise RuntimeError(f'Invalid QA owner: {journal}')
        if qa_waiting_for_result(folder.parent, session):
            return
    with available_lease(lease, record) as available:
        if not available:
            return
        if record['status'] == 'running':
            record.update(status='interrupted', finished=now)
            atomic_json(journal, record)
        age = now - record['finished']
        if not is_unit and record['status'] in ('interrupted', 'failed') and age < 7 * DAY:
            return
        if os.path.lexists(work):
            if record['status'] == 'cleaned' or record['work'] != owned_identity(work):
                raise RuntimeError(f'Unregistered or replaced run directory: {work}')
            if is_unit:
                registry = canonical(work / 'domains')
                tokens = sorted(p.name for p in registry.iterdir()) if registry.exists() else []
                if not all(valid_id(t) for t in tokens):
                    raise RuntimeError(f'Unexpected preference marker in {registry}')
                record['domains'] = tokens
                atomic_json(journal, record)
            if record['work'] != owned_identity(work):
                raise RuntimeError(f'Run directory changed during cleanup: {work}')
            shutil.rmtree(work)
        if is_unit:
            tokens = record.get('domains', [])
            if not all(valid_id(t) for t in tokens):
                raise RuntimeError(f'Invalid preference receipt: {journal}')
            names = [f'{UNIT_PREFIX}{sid}.{token}' for token in tokens]
            try:
                clear_domains(names, record['status'] == 'cleaned')
            except Exception as error:
                record['cleanupIssue'] = str(error)
                atomic_json(journal, record)
                raise
        previous_issue = record.pop('cleanupIssue', None)
        if record['status'] != 'cleaned' or previous_issue:
            record['status'] = 'cleaned'
            atomic_json(journal, record)
        lease.unlink(missing_ok=True)
        # Retain only the names needed to reconcile late cfprefsd writes.
        if not record.get('domains') or age >= 30 * DAY:
            journal.unlink()


def collect_locked(folder, clear_domains):
    now = time.time()
    for journal in sorted(folder.glob('*.json')):
        if valid_id(journal.stem):
            try:
                collect_one(folder, journal.stem, clear_domains, now)
            except Exception as error:
                print(f'Retained run {journal}: {error}', file=sys.stderr)
    # A test may die after atomically creating its lease but before registration.
    for lease in folder.glob('*.lease'):
        if not valid_id(lease.stem) or lease.with_suffix('.json').exists():
            continue
        if os.path.lexists(folder / lease.stem):
            print(f'Retained unregistered work directory for {lease}', file=sys.stderr)
            continue
        with available_lease(lease, {'lease': owned_identity(lease)}) as available:
            if available and lease.read_bytes() == f'NyaEH run lease {lease.stem}\n'.encode():
                lease.unlink()


def collect(base, clear_domains):
    for name in ('unit-runs', 'scratch-runs'):
        folder = base / name
        if folder.exists():
            with directory_lock(folder):
                collect_locked(folder, clear_domains)


def finish_session_units(base, session, clear_domains):
    """A killed test host never runs atexit. Reconcile its run before reporting QA cleanup."""
    folder = base / 'unit-runs'
    if not folder.exists():
        return
    with directory_lock(folder):
        for journal in folder.glob('*.json'):
            if not valid_id(journal.stem) or json.loads(canonical(journal).read_bytes()).get('qaSession') != session:
                continue
            collect_one(folder, journal.stem, clear_domains, time.time(), releasing_session=session)
            if journal.exists() and json.loads(journal.read_bytes())['status'] != 'cleaned':
                raise RuntimeError(f'Test resources still in use: {journal.stem}')


def wait_for_test_exit(folder, sid):
    # Wait outside the registry lock. A collector for a different test process can
    # continue starting or finishing while the OS tears down this test host.
    lease = canonical(folder / (sid + '.lease'))
    try:
        fd = os.open(lease, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return  # Recovery may already have finished.
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    finally:
        os.close(fd)


def unit(base, action, sid, clear_domains):
    if not valid_id(sid):
        raise ValueError('Expected a canonical unit run ID')
    folder = base / 'unit-runs'
    if action == 'end':
        wait_for_test_exit(folder, sid)
    with directory_lock(folder):
        if action == 'begin':
            collect_locked(folder, clear_domains)
            work = register(folder, sid)
            (work / 'files').mkdir()
            (work / 'domains').mkdir()
        elif action == 'end':
            journal = folder / (sid + '.json')
            if not journal.exists():
                return  # A concurrent collector has already finished this run.
            record = json.loads(canonical(journal).read_bytes())
            if record['status'] == 'running':
                record.update(status='finished', finished=time.time())
                atomic_json(journal, record)
            collect_one(folder, sid, clear_domains, time.time())
        else:
            raise ValueError('Unknown unit lifecycle action')


def scratch(base, project, command):
    if not command:
        raise ValueError('scratch requires -- COMMAND [ARG ...]')
    folder = base / 'scratch-runs'
    sid = str(uuid.uuid4())
    with directory_lock(folder):
        collect_locked(folder, None)
        fd = os.open(folder / (sid + '.lease'), os.O_RDWR | os.O_EXCL | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_SH)
        try:
            os.write(fd, f'NyaEH run lease {sid}\n'.encode())
            work = register(folder, sid)
        except BaseException:
            os.close(fd)
            raise
    print(f'Scratch {sid}: {work}', flush=True)
    code = 1
    interrupted = False
    try:
        tmp = work / 'tmp'
        tmp.mkdir()
        modules = str(work / 'modules')
        derived = str(work / 'DerivedData')
        env = dict(os.environ, TMPDIR=str(tmp), NYAEH_SCRATCH_DIR=str(work),
                   NYAEH_PROJECT_ROOT=str(project), NYAEH_SCRATCH_DERIVED_DATA=derived,
                   CLANG_MODULE_CACHE_PATH=modules, SWIFTPM_MODULECACHE_OVERRIDE=modules)
        tool_bin = Path(__file__).resolve().parent / 'scratch-bin'
        real_xcode = shutil.which('xcodebuild')
        if real_xcode == str(tool_bin / 'xcodebuild'):
            real_xcode = env['NYAEH_SCRATCH_XCODEBUILD']
        if Path(command[0]).is_absolute() and Path(command[0]).name == 'xcodebuild':
            real_xcode = command[0]
            command = ['xcodebuild', *command[1:]]
        if real_xcode:
            env.update(NYAEH_SCRATCH_XCODEBUILD=real_xcode, PATH=str(tool_bin) + os.pathsep + env['PATH'])
        code = subprocess.run(command, cwd=work, env=env, pass_fds=(fd,)).returncode
        return code if code >= 0 else 128 - code
    except KeyboardInterrupt:
        code = 130
        interrupted = True
        raise
    finally:
        with directory_lock(folder):
            journal = folder / (sid + '.json')
            record = json.loads(canonical(journal).read_bytes())
            status = 'interrupted' if interrupted or code < 0 else ('passed' if code == 0 else 'failed')
            record.update(status=status, finished=time.time(), exitCode=code)
            atomic_json(journal, record)
            os.close(fd)
            collect_one(folder, sid, None, time.time())
        if work.exists():
            print(f'Scratch retained: {work}', file=sys.stderr)
