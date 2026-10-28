"""Sandbox runner skeleton: run agent code somewhere other than the office host, and bring back only a
log and a patch (施工單 2026-10-28 第四節; serves H3 now and P3/P5 later).

What this module is and is not:
- One small provider interface (`Runner`) plus `FakeRunner` for tests. No real provider is wired up:
  E2B (Python SDK) is the first candidate for shareable synthetic data, a restricted local Docker is a
  separate decision, BoxLite waits for KVM. Nothing here ever falls back to running on the host.
- Runs belong to an existing hands task and attempt and are guarded by that task's lease and status.
  No new queue, daemon or database: one table in the office SQLite.
- Persistence is write-ahead: the row is written before every external call, so a restart finds
  what may have happened. A sandbox that died keeps only what was already collected; nothing here
  promises to recover changes made inside it after the last collection.
- A patch is staged, checked and then published at most once; the target is asked whether a run was
  already applied before applying it, which is what makes a retry after a crash safe.
Python standard library only."""
from __future__ import annotations
import fnmatch
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

import github_app

ACTIVE =('planning', 'running', 'saving')
TERMINAL = ('published', 'failed', 'rejected', 'cancelled', 'lost', 'interrupted', 'superseded')
NAMESPACE = uuid.UUID('5f0c8a52-3e7d-4c55-9b0e-6a1e2d7c9f41')  # run ids: one run per task attempt
DEFAULT_LIMITS = {'seconds': 600, 'output_bytes': 1_000_000, 'artifact_bytes': 4_000_000,
                  'input_files': 500, 'input_bytes': 20_000_000, 'budget_usd': 0.10, 'usd_per_second': 0.000046,
                  'min_free_bytes': 2_000_000_000}  # a full disk breaks the office database's writes
SCHEMA = '''
CREATE TABLE IF NOT EXISTS runner_runs (run_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, attempt INTEGER NOT NULL,
    provider TEXT NOT NULL, sandbox_id TEXT, state TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
    manifest TEXT NOT NULL, manifest_hash TEXT NOT NULL, source_rev TEXT NOT NULL, limits TEXT NOT NULL,
    exit_code INTEGER, seconds REAL, log_hash TEXT, patch_hash TEXT, patch_bytes INTEGER,
    paused INTEGER NOT NULL DEFAULT 0, cleanup TEXT NOT NULL DEFAULT 'none', created TEXT NOT NULL, updated TEXT NOT NULL,
    UNIQUE (task_id, attempt));
'''

# Never sent to a sandbox, whatever the selection says: sign-ins, keys, browser profiles, the office
# database and large dependency trees. Matched against every path component and the file name.
EXCLUDED_DIRS = {'.git', 'node_modules', '.ssh', '.aws', '.gnupg', '.config', '.codex', '.claude', '.gemini', '.docker',
                 '.kube', '.venv', 'venv', '__pycache__', 'runtime', 'claude-home', 'gemini-home', 'codex-home',
                 'chrome-profile', 'Chrome', 'google-chrome', 'chromium'}
EXCLUDED_FILES = ('.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', 'id_rsa*', 'id_ed25519*', 'id_ecdsa*',
                  '.git-credentials', '.netrc', '.npmrc', '.pypirc', '*.sqlite3', '*.sqlite3-*', '*.db', 'auth.json',
                  'credentials*', 'Cookies', 'Login Data*', 'Local State')


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


class RunnerError(Exception):
    """Base for provider errors."""


class RunnerUnknown(RunnerError):
    """Timeout or lost connection: whether the call took effect is not known."""


class RunnerGone(RunnerError):
    """The sandbox no longer exists (killed, expired or crashed)."""


class RunnerFailed(RunnerError):
    """The provider reported a definite failure: the call did nothing."""


class RunRefused(Exception):
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def excluded(relative):
    parts = PurePosixPath(relative).parts
    if any(p in EXCLUDED_DIRS for p in parts[:-1]) or parts[-1] in EXCLUDED_DIRS:
        return True
    return any(fnmatch.fnmatchcase(parts[-1], pattern) for pattern in EXCLUDED_FILES)


def safe_relative(relative):
    """A plain relative POSIX path with no '..', no absolute root, no backslash or NUL."""
    if not isinstance(relative, str) or not relative or len(relative) > 400 or '\\' in relative or '\x00' in relative:
        return False
    path = PurePosixPath(relative)
    return not path.is_absolute() and '..' not in path.parts and bool(path.parts) and path.parts != ('.',)


def select_inputs(root, paths, limits=DEFAULT_LIMITS):
    """An explicit list of files under root, checked one by one: the manifest the sandbox receives.

    Directories are not expanded and nothing is picked up by default; a refused path stops the run
    rather than being skipped silently, so the person sees what was not sent."""
    root = Path(root).resolve()
    if not isinstance(paths, list) or not paths:
        raise RunRefused('no_inputs', '要明列要傳進沙盒的檔案。')
    if len(paths) > limits['input_files']:
        raise RunRefused('too_many_inputs', f"一次最多 {limits['input_files']} 個檔案。")
    manifest, total = [], 0
    for relative in sorted(set(paths)):
        if not safe_relative(relative):
            raise RunRefused('unsafe_path', f'路徑不安全：{relative!r}')
        if excluded(relative):
            raise RunRefused('excluded_path', f'這個檔案不會送進沙盒：{relative}')
        path = root / relative
        current = root
        for part in PurePosixPath(relative).parts:  # no symlink anywhere along the way
            current = current / part
            if current.is_symlink():
                raise RunRefused('symlink', f'不接受符號連結：{relative}')
        if not path.is_file():
            raise RunRefused('not_a_file', f'不是一般檔案：{relative}')
        data = path.read_bytes()
        total += len(data)
        if total > limits['input_bytes']:
            raise RunRefused('inputs_too_large', '要傳進沙盒的檔案太大。')
        manifest.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    return manifest


def manifest_hash(manifest, source_rev):
    return hashlib.sha256(json.dumps({'source_rev': source_rev, 'files': manifest}, sort_keys=True).encode()).hexdigest()


DIFF_PATH = re.compile(r'^(?:diff --git a/(\S+) b/(\S+)|--- (?:a/)?(\S+)|\+\+\+ (?:b/)?(\S+)|(?:rename|copy) (?:from|to) (\S+))')


def patch_problems(patch):
    """Reasons a unified diff may not be published: paths outside the tree or into excluded places,
    symlinks, CI workflows. An empty list means the patch can be published. Binary changes are allowed
    (YUI 2026-10-28): they land on a task branch like any other change and are reverted the same way."""
    try:
        text = patch.decode('utf-8')
    except UnicodeDecodeError:
        return ['not_utf8']
    problems = set()
    for line in text.splitlines():
        if line.startswith('Binary files '):
            problems.add('binary_without_content')  # a diff made without --binary cannot be applied
        if re.match(r'^(new file mode|old mode|new mode|deleted file mode) 120000', line):
            problems.add('symlink')
        match = DIFF_PATH.match(line)
        if match:
            for path in filter(None, match.groups()):
                if path == '/dev/null':
                    continue
                if not safe_relative(path):
                    problems.add('unsafe_path')
                elif excluded(path):
                    problems.add('excluded_path')
                elif path.startswith('.github/workflows/'):
                    problems.add('workflow')  # CI can spend paid minutes and read repository secrets
    return sorted(problems)


class Runner:
    """What a sandbox provider has to offer. Every method may raise RunnerUnknown, RunnerGone or RunnerFailed."""
    name = 'abstract'

    def create(self, run_id, labels):          # -> sandbox_id; labels carry run_id so find() can look it up later
        raise NotImplementedError

    def find(self, run_id):                    # -> sandbox_id or None: reconciles a create whose answer was lost
        raise NotImplementedError

    def upload(self, sandbox_id, root, manifest):
        raise NotImplementedError

    def execute(self, sandbox_id, command, seconds):  # -> {'exit_code': int|None, 'seconds': float, 'timed_out': bool}
        raise NotImplementedError

    def status(self, sandbox_id):              # -> 'running' | 'paused' | 'exited' | 'gone'
        raise NotImplementedError

    def collect(self, sandbox_id, output_bytes):  # -> {'log': bytes, 'patch': bytes}
        raise NotImplementedError

    def pause(self, sandbox_id):
        raise NotImplementedError

    def destroy(self, sandbox_id):             # idempotent: destroying a gone sandbox is not an error
        raise NotImplementedError


class FakeRunner(Runner):
    """In-memory provider for tests. Knobs make each call fail the way a real one can."""
    name = 'fake'

    def __init__(self):
        self.boxes, self.calls = {}, []
        self.fail = {}            # method name -> exception instance to raise once
        self.lose_answer = set()  # methods that act and then raise RunnerUnknown (the effect happened, the answer was lost)
        self.result = {'exit_code': 0, 'seconds': 1.0, 'timed_out': False, 'log': b'ok\n',
                       'patch': b'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n'}

    def _call(self, method, *args):
        self.calls.append((method, *args))
        if method in self.fail:
            raise self.fail.pop(method)

    def _box(self, sandbox_id):
        box = self.boxes.get(sandbox_id)
        if box is None or box['state'] == 'gone':
            raise RunnerGone(sandbox_id)
        return box

    def create(self, run_id, labels):
        self._call('create', run_id)
        sandbox_id = f'fake-{len(self.boxes) + 1}'
        self.boxes[sandbox_id] = {'run_id': run_id, 'state': 'running', 'files': {}, 'log': b'', 'patch': b''}
        if 'create' in self.lose_answer:
            self.lose_answer.discard('create')
            raise RunnerUnknown('create timed out')
        return sandbox_id

    def find(self, run_id):
        self._call('find', run_id)
        return next((i for i, b in self.boxes.items() if b['run_id'] == run_id and b['state'] != 'gone'), None)

    def upload(self, sandbox_id, root, manifest):
        self._call('upload', sandbox_id)
        box = self._box(sandbox_id)
        for entry in manifest:
            box['files'][entry['path']] = (Path(root) / entry['path']).read_bytes()

    def execute(self, sandbox_id, command, seconds):
        self._call('execute', sandbox_id, command)
        box = self._box(sandbox_id)
        box['log'], box['patch'] = self.result['log'], self.result['patch']
        box['state'] = 'exited'
        if 'execute' in self.lose_answer:
            self.lose_answer.discard('execute')
            raise RunnerUnknown('execute timed out')
        return {k: self.result[k] for k in ('exit_code', 'seconds', 'timed_out')}

    def status(self, sandbox_id):
        self._call('status', sandbox_id)
        box = self.boxes.get(sandbox_id)
        return 'gone' if box is None else box['state']

    def collect(self, sandbox_id, output_bytes):
        self._call('collect', sandbox_id)
        box = self._box(sandbox_id)
        return {'log': box['log'][:output_bytes], 'patch': box['patch']}

    def pause(self, sandbox_id):
        self._call('pause', sandbox_id)
        self._box(sandbox_id)['state'] = 'paused'

    def destroy(self, sandbox_id):
        self._call('destroy', sandbox_id)
        if sandbox_id in self.boxes:
            self.boxes[sandbox_id]['state'] = 'gone'

    def die(self, sandbox_id):
        self.boxes[sandbox_id]['state'] = 'gone'


class GitTarget:
    """Publishes a patch as one commit on a task branch in an existing worktree. The commit message
    carries `Neko-Run: <run_id>`, so applied() can tell after a crash whether the run already landed."""

    def __init__(self, worktree, branch):
        if not re.fullmatch(r'neko/[A-Za-z0-9._-]{1,80}', branch):
            raise ValueError('branch must be neko/<task>')
        self.worktree, self.branch = Path(worktree), branch

    def git(self, *args, data=None):
        return subprocess.run(['git', '-C', str(self.worktree), *args], input=data, capture_output=True, timeout=60)

    def current_branch(self):
        out = self.git('symbolic-ref', '--short', 'HEAD')
        return out.stdout.decode().strip() if out.returncode == 0 else None

    def applied(self, run_id):
        out = self.git('log', self.branch, '--format=%B', '-n', '200', '--')
        if out.returncode != 0:
            raise RunnerUnknown('cannot read the task branch')
        return f'Neko-Run: {run_id}' in out.stdout.decode('utf-8', 'replace').splitlines()

    def apply(self, run_id, patch):
        if self.current_branch() != self.branch:
            raise RunnerFailed('worktree is not on the task branch')
        check = self.git('apply', '--check', '--index', data=patch)
        if check.returncode != 0:
            raise RunnerFailed('patch does not apply')
        if self.git('apply', '--index', data=patch).returncode != 0:
            raise RunnerFailed('patch did not apply')
        commit = self.git('-c', 'commit.gpgsign=false', 'commit', '-q', '--no-verify', '-m', f'Apply sandbox run {run_id[:8]}\n\nNeko-Run: {run_id}')
        if commit.returncode != 0:
            raise RunnerUnknown('commit did not report success')


class Checkouts:
    """The office's own copy of a task's repository (tasks/H3-runner-docker-v1.md 5.3): one bare clone per
    repository and one worktree per task on neko/<task short id>, the branch H4 pushes. Inputs are read here
    at a fixed commit and patches land here, so the office never reads the hands workspace.

    No credential is used: git runs with no credential helper and no prompt, so v1 reaches public or local
    repositories only; private ones wait for the GitHub App (H4)."""

    def __init__(self, root, remote='https://github.com/{repo}.git'):
        self.root, self.remote = Path(root), remote

    @staticmethod
    def git(*args, timeout=300):
        out = subprocess.run(['git', '-c', 'credential.helper=', *args], capture_output=True, timeout=timeout,
                             env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'GIT_TERMINAL_PROMPT': '0',
                                  'HOME': '/nonexistent', 'GIT_CONFIG_NOSYSTEM': '1'})  # no user config, no stored sign-in
        if out.returncode != 0:
            raise RunRefused('checkout_failed', '辦公室拿不到這個 repo（v1 只支援公開或本機 repo）。')
        return out.stdout.decode().strip()

    def bare(self, repo):
        return self.root / 'repos' / (repo.replace('/', '__') + '.git')

    def worktree(self, task_id):
        return self.root / 'worktrees' / github_app.branch_for(task_id).split('/', 1)[1]

    def prepare(self, task_id, repo, base):
        """Clone or fetch, then the task's worktree on its branch. Returns (worktree, branch, source_rev)."""
        bare, branch, worktree = self.bare(repo), github_app.branch_for(task_id), self.worktree(task_id)
        if not bare.is_dir():
            bare.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.git('clone', '--bare', '--quiet', self.remote.format(repo=repo), str(bare))
            self.git('-C', str(bare), 'config', 'user.name', 'neko-office')
            self.git('-C', str(bare), 'config', 'user.email', 'neko-office@invalid')
        else:
            self.git('-C', str(bare), 'fetch', '--quiet', 'origin', f'+refs/heads/{base}:refs/heads/{base}')
        if not worktree.is_dir():
            worktree.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            has_branch = subprocess.run(['git', '-C', str(bare), 'rev-parse', '--verify', '--quiet', f'refs/heads/{branch}'],
                                        capture_output=True).returncode == 0
            if has_branch:  # an earlier attempt of this task: keep building on what it published
                self.git('-C', str(bare), 'worktree', 'add', '--quiet', str(worktree), branch)
            else:
                self.git('-C', str(bare), 'worktree', 'add', '--quiet', '-b', branch, str(worktree), base)
        return worktree, branch, self.git('-C', str(worktree), 'rev-parse', 'HEAD')

    def target(self, task_id):
        worktree = self.worktree(task_id)
        return GitTarget(worktree, github_app.branch_for(task_id)) if worktree.is_dir() else None


class RunService:
    def __init__(self, store, runner, clock=time.time):
        self.store, self.runner, self.clock = store, runner, clock
        with store.connect() as c:
            c.executescript(SCHEMA)

    # -- helpers ---------------------------------------------------------------------------

    def run(self, run_id):
        with self.store.connect() as c:
            row = c.execute('SELECT * FROM runner_runs WHERE run_id=?', (run_id,)).fetchone()
        if row is None:
            raise RunRefused('unknown_run', '找不到這次執行。')
        return dict(row)

    def runs_dir(self, run):
        return self.store.root / 'tasks' / run['task_id'] / 'runs' / run['run_id']

    def set(self, run_id, state=None, **fields):
        fields = {**({'state': state} if state else {}), **fields, 'updated': now()}
        with self.store.connect() as c:
            c.execute(f"UPDATE runner_runs SET {','.join(k + '=?' for k in fields)} WHERE run_id=?", [*fields.values(), run_id])

    def event(self, task_id, message):
        try:
            self.store.note(task_id, 'tool', message)
        except Exception:
            pass  # progress notes are best effort; the run row is the record

    def guard(self, run, lease):
        """The run's task is still this attempt, still active and still holds this lease; otherwise the
        result is from an old attempt or a cancelled task and is not accepted."""
        with self.store.connect() as c:
            task = c.execute('SELECT status,attempts,lease,executor FROM tasks WHERE id=?', (run['task_id'],)).fetchone()
            stopped = c.execute("SELECT 1 FROM settings WHERE key IN ('paused','hands_locked') AND value='1'").fetchone()
        if task is None or task['executor'] != 'hands':
            raise RunRefused('unknown_task', '找不到這件工作。')
        if task['status'] not in ACTIVE:
            raise RunRefused('task_stopped', '這件工作已經停止。')
        if task['attempts'] != run['attempt'] or not isinstance(lease, str) or not hmac.compare_digest(task['lease'].encode(), lease.encode()):
            raise RunRefused('superseded', '這件工作已經交給新的一輪。')
        if stopped:
            raise RunRefused('stopped', '辦公室暫停中或已收回權限。')

    def refuse_stale(self, run, lease):
        """Guard, and on refusal close the run so an old attempt's sandbox does not linger."""
        try:
            self.guard(run, lease)
        except RunRefused as e:
            if run['state'] not in TERMINAL:
                state = 'superseded' if e.reason == 'superseded' else 'cancelled'
                self.set(run['run_id'], state, detail=e.reason, cleanup='pending' if run['sandbox_id'] else run['cleanup'])
                self.cleanup(run['run_id'])
            raise

    # -- lifecycle -------------------------------------------------------------------------

    def start(self, task_id, lease, root, paths, source_rev, limits=None):
        limits = {**DEFAULT_LIMITS, **(limits or {})}
        if limits['seconds'] * limits['usd_per_second'] > limits['budget_usd']:
            raise RunRefused('over_budget', '這次執行可能超出預算上限，沒有開始。')
        if not re.fullmatch(r'[0-9a-f]{7,64}', source_rev or ''):
            raise RunRefused('source_rev', '需要固定的來源版本（commit）。')
        if shutil.disk_usage(self.store.root).free < limits['min_free_bytes']:
            raise RunRefused('low_disk', '辦公室的磁碟空間不夠，沒有開新沙盒。')
        with self.store.connect() as c:
            task = c.execute('SELECT attempts FROM tasks WHERE id=?', (task_id,)).fetchone()
        if task is None:
            raise RunRefused('unknown_task', '找不到這件工作。')
        run_id = str(uuid.uuid5(NAMESPACE, f'{task_id}:{task["attempts"]}'))
        try:
            existing = self.run(run_id)
        except RunRefused:
            existing = None
        if existing:  # the same attempt asked again: the same run, never a second sandbox
            return existing
        stub = {'run_id': run_id, 'task_id': task_id, 'attempt': task['attempts'], 'state': 'new', 'sandbox_id': None, 'cleanup': 'none'}
        self.guard(stub, lease)
        manifest = select_inputs(root, paths, limits)
        with self.store.connect() as c:  # written before the provider is called: a restart knows a create may have happened
            c.execute('INSERT OR IGNORE INTO runner_runs(run_id,task_id,attempt,provider,state,manifest,manifest_hash,source_rev,limits,'
                      'created,updated) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                      (run_id, task_id, task['attempts'], self.runner.name, 'creating', json.dumps(manifest),
                       manifest_hash(manifest, source_rev), source_rev, json.dumps(limits), now(), now()))
        self.event(task_id, f'準備沙盒（{len(manifest)} 個檔案）。')
        try:
            sandbox_id = self.runner.create(run_id, {'neko_run': run_id})
        except RunnerUnknown:
            self.set(run_id, 'create_unknown', detail='create_unknown')
            return self.run(run_id)
        except RunnerError as e:
            self.set(run_id, 'failed', detail=f'create_{type(e).__name__}')
            return self.run(run_id)
        self.set(run_id, 'creating', sandbox_id=sandbox_id, cleanup='pending')
        for entry in manifest:  # the files must still be the ones the manifest names
            if hashlib.sha256((Path(root) / entry['path']).read_bytes()).hexdigest() != entry['sha256']:
                self.set(run_id, 'failed', detail='input_changed')
                self.cleanup(run_id)
                return self.run(run_id)
        try:
            self.runner.upload(sandbox_id, root, manifest)
        except RunnerError as e:
            self.set(run_id, 'failed', detail=f'upload_{type(e).__name__}')
            self.cleanup(run_id)
            return self.run(run_id)
        self.set(run_id, 'ready')
        return self.run(run_id)

    def execute(self, run_id, lease, command):
        run = self.run(run_id)
        if run['state'] != 'ready':
            raise RunRefused('wrong_state', f"現在是 {run['state']}，不能執行。")
        self.refuse_stale(run, lease)
        limits = json.loads(run['limits'])
        self.set(run_id, 'running', paused=0)  # before the call: a restart sees that it may have run
        self.event(run['task_id'], '沙盒開始執行。')
        try:
            result = self.runner.execute(run['sandbox_id'], command, limits['seconds'])
        except RunnerError as e:
            if self.closed(run_id):  # sweep() closed it meanwhile (task cancelled or hands taken back): that stands
                return self.run(run_id)
            if isinstance(e, RunnerGone):
                self.set(run_id, 'lost', detail='sandbox_gone_during_execute', cleanup='done')
            elif isinstance(e, RunnerUnknown):
                self.set(run_id, 'unknown', detail='execute_unknown')  # never executed again on its own
            else:
                self.set(run_id, 'failed', detail='execute_failed')
                self.cleanup(run_id)
            return self.run(run_id)
        if self.closed(run_id):
            return self.run(run_id)
        self.set(run_id, exit_code=result.get('exit_code'), seconds=result.get('seconds'))
        # Collected whatever the exit code: a failing run's log is what explains it.
        state = self.collect(run_id)
        if state == 'collected' and (result.get('timed_out') or result.get('exit_code') != 0):
            self.set(run_id, 'failed', detail='time_limit' if result.get('timed_out') else 'nonzero_exit')
        self.cleanup(run_id)
        return self.run(run_id)

    def closed(self, run_id):
        return self.run(run_id)['state'] in TERMINAL

    def collect(self, run_id, then='collected'):
        """Stage log and patch from a sandbox that is still reachable. Staged files are hashed, capped
        and never published from here."""
        run = self.run(run_id)
        limits = json.loads(run['limits'])
        try:
            got = self.runner.collect(run['sandbox_id'], limits['output_bytes'])
        except RunnerGone:
            self.set(run_id, 'lost', detail='sandbox_gone_before_collect', cleanup='done')
            return 'lost'
        except RunnerError:
            self.set(run_id, 'unknown', detail='collect_failed')
            return 'unknown'
        log, patch = got.get('log', b'')[:limits['output_bytes']], got.get('patch', b'')
        if len(log) + len(patch) > limits['artifact_bytes'] or len(patch) > limits['output_bytes']:
            self.set(run_id, 'rejected', detail='artifact_too_large')
            return 'rejected'
        staging = self.runs_dir(run) / 'staging'
        staging.mkdir(parents=True, exist_ok=True, mode=0o700)
        for name, data in (('log.txt', log), ('result.patch', patch)):
            tmp = staging / (name + '.tmp')
            tmp.write_bytes(data)
            tmp.replace(staging / name)
        self.set(run_id, then, log_hash=hashlib.sha256(log).hexdigest(), patch_hash=hashlib.sha256(patch).hexdigest(),
                 patch_bytes=len(patch))
        self.event(run['task_id'], f'收回沙盒結果（log {len(log)} bytes、patch {len(patch)} bytes）。')
        return then

    def verify(self, run_id):
        run = self.run(run_id)
        if run['state'] != 'collected' or run['exit_code'] != 0:
            raise RunRefused('wrong_state', '只有正常結束且已收回的結果能檢查。')
        patch = (self.runs_dir(run) / 'staging' / 'result.patch').read_bytes()
        if hashlib.sha256(patch).hexdigest() != run['patch_hash']:
            self.set(run_id, 'rejected', detail='patch_changed')
        elif not patch.strip():
            self.set(run_id, 'rejected', detail='empty_patch')
        elif patch_problems(patch):
            self.set(run_id, 'rejected', detail='patch_' + '_'.join(patch_problems(patch)))
        else:
            self.set(run_id, 'verified')
        return self.run(run_id)

    def publish(self, run_id, lease, target):
        """Apply a verified patch once. A second call, or a retry after a crash, finds it already applied."""
        run = self.run(run_id)
        if run['state'] == 'published':
            return run
        if run['state'] != 'verified':
            raise RunRefused('wrong_state', '只有檢查過的結果能套用。')
        self.refuse_stale(run, lease)
        with self.store.connect() as c:  # claim the publish: only one caller moves verified → publishing
            moved = c.execute("UPDATE runner_runs SET state='publishing',updated=? WHERE run_id=? AND state='verified'",
                              (now(), run_id)).rowcount
        if not moved:
            return self.run(run_id)
        return self.finish_publish(run_id, target)

    def finish_publish(self, run_id, target):
        run = self.run(run_id)
        try:
            if not target.applied(run_id):
                patch = (self.runs_dir(run) / 'staging' / 'result.patch').read_bytes()
                if hashlib.sha256(patch).hexdigest() != run['patch_hash']:
                    self.set(run_id, 'rejected', detail='patch_changed')
                    return self.run(run_id)
                target.apply(run_id, patch)
        except RunnerFailed as e:
            self.set(run_id, 'verified', detail=f'apply_failed: {str(e)[:80]}')  # definite: nothing landed
            return self.run(run_id)
        except RunnerError:
            try:
                landed = target.applied(run_id)
            except RunnerError:
                self.set(run_id, 'publishing', detail='publish_unknown')  # left for recover() or a person
                return self.run(run_id)
            if not landed:
                self.set(run_id, 'verified', detail='apply_not_landed')
                return self.run(run_id)
        self.set(run_id, 'published', detail='')
        self.event(run['task_id'], '沙盒結果已套用到任務分支。')
        return self.run(run_id)

    def pause(self, run_id):
        """Between steps only: a paused sandbox stops costing compute. A gone one is simply recorded."""
        run = self.run(run_id)
        if run['state'] not in ('ready', 'collected', 'verified') or not run['sandbox_id'] or run['cleanup'] == 'done':
            return run
        try:
            self.runner.pause(run['sandbox_id'])
            self.set(run_id, paused=1)
        except RunnerGone:
            self.set(run_id, cleanup='done', detail='sandbox_gone_while_idle')
        except RunnerError:
            pass
        return self.run(run_id)

    def cleanup(self, run_id):
        run = self.run(run_id)
        if not run['sandbox_id'] or run['cleanup'] == 'done':
            return run['cleanup']
        try:
            self.runner.destroy(run['sandbox_id'])
            state = 'done'
        except RunnerGone:
            state = 'done'
        except RunnerError:
            state = 'failed'  # retried by recover(); a leaked sandbox costs money, so it is never forgotten
        self.set(run_id, cleanup=state)
        return state

    def summary(self):
        """For /api/health: counts only, no paths, sandbox ids or logs."""
        with self.store.connect() as c:
            rows = c.execute('SELECT state,detail,cleanup FROM runner_runs').fetchall()
        return {'enabled': True, 'provider': self.runner.name,
                'open': sum(r['state'] not in TERMINAL for r in rows),
                # Left for a person: whether it took effect is not known, and nothing retries it on its own.
                'needs_person': sum(r['state'] in ('unknown', 'create_unknown') or r['detail'] == 'publish_unknown' for r in rows),
                'cleanup_failed': sum(r['cleanup'] == 'failed' for r in rows)}

    def sweep(self):
        """Called every few seconds by the office: a run whose task was cancelled, moved to a new attempt or
        lost its hands (收回) is closed and its sandbox removed now, not at the next call or restart.
        A run being published or whose create is unknown is left to finish_publish() and recover()."""
        with self.store.connect() as c:
            locked = c.execute("SELECT 1 FROM settings WHERE key='hands_locked' AND value='1'").fetchone()
            rows = c.execute("SELECT r.run_id,r.attempt,r.sandbox_id,r.cleanup,t.status,t.attempts FROM runner_runs r "
                             "LEFT JOIN tasks t ON t.id=r.task_id WHERE r.state NOT IN (%s) AND r.state NOT IN "
                             "('publishing','create_unknown')" % ','.join('?' * len(TERMINAL)), TERMINAL).fetchall()
        closed = []
        for row in rows:
            moved_on = row['status'] in ACTIVE and row['attempts'] != row['attempt']
            if row['status'] in ACTIVE and not moved_on and not locked:
                continue
            self.set(row['run_id'], 'superseded' if moved_on else 'cancelled',
                     detail='hands_locked' if locked else ('superseded' if moved_on else 'task_stopped'),
                     cleanup='pending' if row['sandbox_id'] else row['cleanup'])
            self.cleanup(row['run_id'])
            closed.append(row['run_id'])
        return closed

    # -- restart ---------------------------------------------------------------------------

    def recover(self, target_for=None):
        """At office start. Nothing in between is trusted: no run is executed again and no patch is applied
        without first asking where things stand. Returns {run_id: new_state}."""
        moved = {}
        with self.store.connect() as c:
            rows = [dict(r) for r in c.execute("SELECT * FROM runner_runs WHERE state NOT IN ('published','failed','rejected',"
                                               "'cancelled','lost','interrupted','superseded') OR cleanup IN ('pending','failed')")]
        for run in rows:
            run_id, state = run['run_id'], run['state']
            with self.store.connect() as c:
                task = c.execute('SELECT status,attempts FROM tasks WHERE id=?', (run['task_id'],)).fetchone()
            task_live = task is not None and task['status'] in ACTIVE and task['attempts'] == run['attempt']
            if state in ('creating', 'create_unknown'):
                try:
                    found = run['sandbox_id'] or self.runner.find(run_id)
                except RunnerError:
                    moved[run_id] = 'create_unknown'
                    self.set(run_id, 'create_unknown', detail='find_failed')
                    continue
                self.set(run_id, 'interrupted', detail='restart_during_create', sandbox_id=found,
                         cleanup='pending' if found else 'none')
            elif state in ('ready', 'running', 'unknown'):
                try:
                    where = self.runner.status(run['sandbox_id'])
                except RunnerError:
                    where = None
                if where == 'gone':
                    self.set(run_id, 'lost', detail='sandbox_gone_after_restart', cleanup='done')
                elif where is None:
                    self.set(run_id, 'unknown', detail='status_unknown_after_restart')
                    moved[run_id] = 'unknown'
                    continue
                else:
                    if state != 'ready':
                        self.collect(run_id, then='interrupted')  # keep what can still be read; never run it again
                    self.set(run_id, 'interrupted', detail=f'restart_during_{state}', cleanup='pending')
            elif state == 'publishing':
                target = target_for(run) if target_for else None
                if target is None:
                    self.set(run_id, 'publishing', detail='publish_unknown')
                    moved[run_id] = 'publishing'
                    continue
                try:
                    landed = target.applied(run_id)
                except RunnerError:
                    self.set(run_id, 'publishing', detail='publish_unknown')
                    moved[run_id] = 'publishing'
                    continue
                self.set(run_id, 'published' if landed else 'verified', detail='' if landed else 'not_applied_before_restart')
            elif state in ('collected', 'verified') and not task_live:
                self.set(run_id, 'cancelled', detail='task_not_active_after_restart', cleanup='pending')
            run = self.run(run_id)
            if run['state'] in TERMINAL or not task_live:
                self.cleanup(run_id)
            moved[run_id] = self.run(run_id)['state']
        return moved
