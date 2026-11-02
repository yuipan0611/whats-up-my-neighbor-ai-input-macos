#!/usr/bin/env python3
"""Bounded task runner. Model output is a private patch, never a direct push."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen
import uuid

MAX_ARTIFACT = 2 * 1024 * 1024
PILOT_PATHS = {'README.md', 'docs/CLOUD_DEVELOPMENT.md'}
PROTECTED = ('.github/', 'Resources/Info.plist', 'RELEASE_NOTES.md',
             'PRIVACY.md', 'SECURITY.md', 'cat.config.json',
             'scripts/release', 'scripts/validate-signing', 'scripts/package-release',
             'scripts/fetch-sparkle', 'scripts/validate-release')


class Conflict(Exception):
    pass


def validate_task(task):
    required = {'id', 'repo', 'sha', 'mode', 'prompt'}
    if not isinstance(task, dict) or set(task) != required:
        raise ValueError('Task must contain exactly: id, repo, sha, mode, prompt.')
    if not all(isinstance(task[k], str) for k in required):
        raise ValueError('All task fields must be strings.')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', task['id']):
        raise ValueError('Task id: lowercase letters, numbers and hyphens; 1-63 characters.')
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', task['repo']):
        raise ValueError('Use a public HTTPS github.com owner/repo URL without credentials or query parameters.')
    if not re.fullmatch(r'[0-9a-f]{40}', task['sha']):
        raise ValueError('Pin an exact 40-character lowercase commit SHA, not a moving branch.')
    if task['mode'] not in ('audit', 'develop'):
        raise ValueError('Mode must be audit or develop.')
    if len(task['prompt'].encode()) > 20000:
        raise ValueError('Prompt exceeds 20 KB; provide a smaller, focused task.')
    return task


class LocalStore:
    """Single-process fixture store. Cloud execution always uses GCS CAS."""
    def __init__(self, root):
        self.root = Path(root)

    def read(self, key):
        path = self.root / key
        if not path.exists():
            return None, None
        value = path.read_bytes()
        return value, hashlib.sha256(value).hexdigest()

    def write(self, key, value, generation=None):
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        if generation == '0':
            try:
                with path.open('xb') as out:
                    out.write(value)
            except FileExistsError as exc:
                raise Conflict(key) from exc
        else:
            if generation is not None and self.read(key)[1] != generation:
                raise Conflict(key)
            temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
            temporary.write_bytes(value)
            os.replace(temporary, path)
        return hashlib.sha256(value).hexdigest()


class GCSStore:
    def __init__(self, bucket):
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,220}[a-z0-9]', bucket):
            raise ValueError('Invalid results bucket name.')
        self.bucket = quote(bucket, safe='')

    def request(self, url, data=None, method='GET'):
        # The job uses its dedicated service account; no saved credential file.
        metadata = Request('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
                           headers={'Metadata-Flavor': 'Google'})
        with urlopen(metadata, timeout=10) as response:
            token = json.load(response)['access_token']
        headers = {'Authorization': 'Bearer ' + token}
        if data is not None:
            headers['Content-Type'] = 'application/octet-stream'
        request = Request(url, data=data, headers=headers, method=method)
        return urlopen(request, timeout=60)

    def read(self, key):
        base = f'https://storage.googleapis.com/storage/v1/b/{self.bucket}/o/{quote(key, safe="")}'
        try:
            with self.request(base) as response:
                metadata = json.load(response)
            generation = metadata['generation']
            with self.request(base + '?' + urlencode({'alt': 'media', 'generation': generation})) as response:
                value = response.read(MAX_ARTIFACT + 1)
            if len(value) > MAX_ARTIFACT:
                raise ValueError('Stored object exceeds 2 MiB limit.')
            return value, generation
        except HTTPError as exc:
            if exc.code == 404:
                return None, None
            raise

    def write(self, key, value, generation=None):
        if len(value) > MAX_ARTIFACT:
            raise ValueError('Artifact exceeds 2 MiB; reduce task scope.')
        query = {'uploadType': 'media', 'name': key}
        if generation is not None:
            query['ifGenerationMatch'] = generation
        url = f'https://storage.googleapis.com/upload/storage/v1/b/{self.bucket}/o?' + urlencode(query)
        try:
            with self.request(url, data=value, method='POST') as response:
                return json.load(response)['generation']
        except HTTPError as exc:
            if exc.code == 412:
                raise Conflict(key) from exc
            raise


def read_json(store, key):
    raw, generation = store.read(key)
    return (json.loads(raw) if raw else None), generation


def write_json(store, key, value, generation=None):
    return store.write(key, json.dumps(value, ensure_ascii=False, indent=2).encode(), generation)


def git(repo, *args, timeout=120):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT='0', GIT_LFS_SKIP_SMUDGE='1')
    identity = {}
    # Never execute Git as root inside the model-owned working directory.
    if os.geteuid() == 0 and Path(repo).stat().st_uid == 10001:
        identity = dict(user=10001, group=10001, extra_groups=[])
    return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', *args], cwd=repo,
                          env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, **identity).stdout


def collect_patch(repo, allowed_paths=None):
    git(repo, 'add', '--all')
    # Disabling rename detection checks both deletion and destination paths.
    paths = git(repo, 'diff', '--cached', '--name-only', '--no-renames', '-z').decode().split('\0')
    paths = [p for p in paths if p]
    rejected = [p for p in paths if any(p == prefix or p.startswith(prefix) for prefix in PROTECTED)]
    if rejected:
        raise ValueError('Protected paths changed; create a separately reviewed task: ' + ', '.join(rejected))
    if allowed_paths is not None and set(paths) - set(allowed_paths):
        raise ValueError('Pilot changed paths outside its approved documentation scope.')
    for path in paths:
        item = Path(repo) / path
        if item.is_symlink() or not item.is_file():
            raise ValueError('Pilot output must contain regular files; no symlinks or deletions.')
    patch = git(repo, 'diff', '--cached', '--binary')
    if len(patch) > MAX_ARTIFACT:
        raise ValueError('Patch exceeds 2 MiB; split the task.')
    git(repo, 'diff', '--cached', '--check')
    return patch, paths


def process_limit():
    # Adapter output cannot grow without bound in Cloud Run's temporary filesystem.
    import resource
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ARTIFACT, MAX_ARTIFACT))


def run_adapter(adapter, task_file, repo, log, timeout):
    process = subprocess.Popen(['/bin/bash', str(adapter), str(task_file), str(repo)],
        cwd=repo, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, preexec_fn=process_limit)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise TimeoutError('Adapter timed out. Process group stopped; inspect status before retrying.') from exc
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def execute(task, store, adapter=None, fixture_repo=None, adapter_timeout=600, allowed_paths=None):
    validate_task(task)
    prefix = 'tasks/' + task['id'] + '/'
    digest = hashlib.sha256(json.dumps(task, sort_keys=True).encode()).hexdigest()
    previous, _ = read_json(store, prefix + 'status.json')
    if previous and previous.get('task_digest') != digest:
        raise ValueError('Task id already belongs to different input; choose a new id.')
    if previous and previous.get('state') == 'succeeded':
        return previous
    owner = uuid.uuid4().hex
    lease, generation = read_json(store, prefix + 'lease.json')
    if lease and lease['expires_at'] > time.time():
        raise Conflict('Task already running; inspect its status instead of starting a duplicate.')
    lease_generation = write_json(store, prefix + 'lease.json',
        {'owner': owner, 'expires_at': time.time() + 1800}, generation or '0')
    status = {'id': task['id'], 'task_digest': digest, 'source_sha': task['sha'],
              'state': 'running', 'stage': 'claimed', 'attempt': (previous or {}).get('attempt', 0) + 1}

    def checkpoint(stage, **fields):
        status.update(stage=stage, updated_at=time.time(), **fields)
        write_json(store, prefix + 'status.json', status)

    try:
        checkpoint('claimed')
        with tempfile.TemporaryDirectory(prefix='agent-task-') as temporary:
            root = Path(temporary)
            repo = root / 'repo'
            if fixture_repo:
                # Local regression fixtures only; this branch is unavailable to cloud input.
                subprocess.run(['git', 'clone', '--no-hardlinks', str(fixture_repo), str(repo)],
                               check=True, capture_output=True, timeout=60)
            else:
                repo.mkdir()
                git(repo, 'init')
                git(repo, 'remote', 'add', 'origin', task['repo'])
                git(repo, 'fetch', '--depth=1', 'origin', task['sha'])
            git(repo, 'checkout', '--detach', task['sha'])
            actual_sha = git(repo, 'rev-parse', 'HEAD').decode().strip()
            if actual_sha != task['sha']:
                raise ValueError('Checked-out commit differs from the requested commit.')
            checkpoint('checkout_complete')
            if task['mode'] == 'audit':
                files = git(repo, 'ls-files').decode().splitlines()
                write_json(store, prefix + 'audit.json', {'source_sha': actual_sha,
                    'tracked_files': len(files), 'root_files': [p for p in files if '/' not in p],
                    'note': 'Repository inventory only. No model call, build or native macOS validation.'})
                patch, paths = b'', []
            else:
                adapter = Path(adapter or '/app/adapter.sh').resolve()
                if not adapter.is_file():
                    raise ValueError('Install your chosen Coding Agent and provide adapter.sh; see README.')
                task_file = root / 'task.json'
                task_file.write_text(json.dumps(task, ensure_ascii=False))
                log_file = root / 'adapter.log'
                checkpoint('adapter_running')
                # No shell interpolation of repo URLs, task text, paths or prompts.
                try:
                    with log_file.open('wb') as log:
                        returncode = run_adapter(adapter, task_file, repo, log, adapter_timeout)
                finally:
                    if log_file.exists():
                        store.write(prefix + 'adapter.log', log_file.read_bytes()[:MAX_ARTIFACT])
                if returncode != 0:
                    raise ValueError(f'Coding Agent adapter exited {returncode}; inspect its private log.')
                checkpoint('adapter_complete')
                patch, paths = collect_patch(repo, allowed_paths)
            checkpoint('patch_checked', changed_paths=paths)
            store.write(prefix + 'changes.patch', patch)
            checkpoint('complete', state='succeeded', native_macos_tested=False,
                       message='Patch saved for review. No push, PR, merge, release or native macOS test performed.')
            return status
    except Exception as exc:
        checkpoint('failed', state='failed', error=str(exc))
        raise
    finally:
        # Generation precondition prevents another owner releasing our lease accidentally.
        write_json(store, prefix + 'lease.json', {'owner': owner, 'expires_at': 0}, lease_generation)


def main():
    if len(sys.argv) != 2:
        raise ValueError('Expected one task id. Use quickstart.py submit, not arbitrary commands.')
    task_id = sys.argv[1]
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', task_id):
        raise ValueError('Invalid task id.')
    store = GCSStore(os.environ['RESULTS_BUCKET'])
    task, _ = read_json(store, 'requests/' + task_id + '.json')
    if not task:
        raise ValueError('Task manifest missing. Upload it using quickstart.py submit.')
    if task.get('id') != task_id:
        raise ValueError('Manifest id does not match requested id.')
    if task['repo'] != os.environ['ALLOWED_REPO']:
        raise ValueError('Repository is not allowed by this job deployment.')
    result = execute(task, store, allowed_paths=PILOT_PATHS)
    print(json.dumps({'id': task_id, 'state': result['state'], 'stage': result['stage']}))


if __name__ == '__main__':
    try:
        main()
    except Conflict as exc:
        print(json.dumps({'state': 'already_running', 'message': str(exc)}))
    except Exception as exc:
        print(json.dumps({'state': 'failed', 'message': str(exc)}), file=sys.stderr)
        sys.exit(1)
