#!/usr/bin/env python3
"""Trusted orchestration, strict docs-patch validation, and a separate PR publisher."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from runner import MAX_ARTIFACT, PILOT_PATHS, validate_task

REPOSITORY = 'yuipan0611/whats-up-my-neighbor-ai-input-macos'
PROMPT = '''請新增 docs/CLOUD_DEVELOPMENT.md，以繁體中文說明 Neko 的雲端開發流程，
並在 README.md 加上一個相對連結。請先閱讀 .github/workflows/build.yml、
scripts/build.sh 與 scripts/test-all.sh，引用真實的建置與測試方式。
說明 GCP Linux 可處理程式修改與靜態檢查，GitHub macOS runner 執行原生建置與離線測試；
麥克風、輔助使用權限、實際 UI 與更新安裝仍需真機驗證。清楚區分 Draft PR、測試通過與正式發布。
不要聲稱此試跑已成功部署、已測試或已發布。不要加入金鑰、帳號、私人路徑或錄音資料。
只修改 README.md 與新增 docs/CLOUD_DEVELOPMENT.md；不要更動其他檔案。'''


def run(args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True,
                          timeout=120).stdout.decode().strip()


def output(**fields):
    target = os.environ.get('GITHUB_OUTPUT')
    if target:
        with open(target, 'a') as file:
            for key, value in fields.items():
                if '\n' in str(value) or '\r' in str(value):
                    raise ValueError('Output must be a single line.')
                file.write(f'{key}={value}\n')
    print(json.dumps(fields))


def prepare(destination, task_id, sha):
    task = validate_task(dict(id=task_id, repo='https://github.com/' + REPOSITORY,
                             sha=sha, mode='develop', prompt=PROMPT))
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'task.json').write_text(json.dumps(task, ensure_ascii=False, indent=2))
    output(task_id=task_id, source_sha=sha)
    return task


def cloud(destination, project, region, job, bucket):
    for value in (project, region, job, bucket):
        if not re.fullmatch(r'[a-z][a-z0-9.-]{2,62}', value):
            raise ValueError('Invalid cloud resource name.')
    task = validate_task(json.loads((destination / 'task.json').read_text()))
    base = ['gcloud', '--quiet', '--project', project]
    upload_request(base, bucket, destination, task)
    # CLI waits for the remote job, but the job itself survives a disconnected Mac.
    # No automatic retry on nonzero exit: inspect status/log before retrying.
    subprocess.run(base + ['run', 'jobs', 'execute', job, '--region', region,
        '--args', task['id'], '--wait'], check=True, timeout=1250)
    for name in ('status.json', 'changes.patch'):
        run(base + ['storage', 'cp', f'gs://{bucket}/tasks/{task["id"]}/{name}', str(destination / name)])
    verify_result(destination)


def upload_request(base, bucket, destination, task):
    request = f'gs://{bucket}/requests/{task["id"]}.json'
    # Re-runs use the same manifest. Verify immutable input before re-executing.
    exists = subprocess.run(base + ['storage', 'objects', 'describe', request],
                            capture_output=True, timeout=60)
    if exists.returncode == 0:
        stored = json.loads(run(base + ['storage', 'cat', request]))
        if stored != task:
            raise ValueError('Existing task manifest differs; choose a new task id.')
    else:
        run(base + ['storage', 'cp', str(destination / 'task.json'), request, '--if-generation-match=0'])


def verify_status(directory, task):
    status = json.loads((directory / 'status.json').read_text())
    digest = hashlib.sha256(json.dumps(task, sort_keys=True).encode()).hexdigest()
    if (status.get('id') != task['id'] or status.get('source_sha') != task['sha']
            or status.get('task_digest') != digest or status.get('state') != 'succeeded'):
        raise ValueError('Task result does not match the immutable request.')
    return status


def cloud_audit(destination, project, region, job, bucket, task_id, sha):
    for value in (project, region, job, bucket):
        if not re.fullmatch(r'[a-z][a-z0-9.-]{2,62}', value):
            raise ValueError('Invalid cloud resource name.')
    task = validate_task(dict(id=task_id, repo='https://github.com/' + REPOSITORY,
                             sha=sha, mode='audit', prompt='Inventory only. No model call or code modification.'))
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'task.json').write_text(json.dumps(task, ensure_ascii=False, indent=2))
    base = ['gcloud', '--quiet', '--project', project]
    upload_request(base, bucket, destination, task)
    subprocess.run(base + ['run', 'jobs', 'execute', job + '-audit', '--region', region,
                          '--args', task_id, '--wait'], check=True, timeout=360)
    for name in ('status.json', 'audit.json'):
        run(base + ['storage', 'cp', f'gs://{bucket}/tasks/{task_id}/{name}', str(destination / name)])
    verify_status(destination, task)
    inventory = json.loads((destination / 'audit.json').read_text())
    if inventory.get('source_sha') != sha:
        raise ValueError('Audit inventory does not match the requested source SHA.')
    output(task_id=task_id, source_sha=sha, tracked_files=inventory['tracked_files'])
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as file:
            file.write(f'GCP keyless sandbox + audit passed. Task `{task_id}`, source `{sha}`. '
                       'No model call, code modification, PR, merge or release.\n')


def verify_result(directory):
    task = validate_task(json.loads((directory / 'task.json').read_text()))
    if task['repo'] != 'https://github.com/' + REPOSITORY or task['prompt'] != PROMPT or task['mode'] != 'develop':
        raise ValueError('Publisher accepts only the fixed Neko documentation pilot.')
    verify_status(directory, task)
    patch = directory / 'changes.patch'
    if not 0 < patch.stat().st_size <= MAX_ARTIFACT:
        raise ValueError('Expected a nonempty patch of at most 2 MiB.')
    return task


def apply_patch(repo, directory):
    task = verify_result(directory)
    if run(['git', 'rev-parse', 'HEAD'], repo) != task['sha']:
        raise ValueError('Publisher checkout must be exactly the requested source SHA.')
    if run(['git', 'status', '--porcelain'], repo):
        raise ValueError('Publisher checkout is not clean.')
    patch = str((directory / 'changes.patch').resolve())
    run(['git', '-c', 'core.hooksPath=/dev/null', 'apply', '--index', '--check', patch], repo)
    run(['git', '-c', 'core.hooksPath=/dev/null', 'apply', '--index', patch], repo)
    paths = set(run(['git', 'diff', '--cached', '--name-only', '--no-renames'], repo).splitlines())
    if paths != PILOT_PATHS:
        raise ValueError('Patch must add the pilot document and only change the approved documentation paths.')
    for path in paths:
        item = repo / path
        mode = run(['git', 'ls-files', '--stage', '--', path], repo).split()[0]
        if mode != '100644' or item.is_symlink() or not item.is_file():
            raise ValueError('Documentation must be regular non-executable files, without deletions.')
        item.read_text(encoding='utf-8')
    if 'docs/CLOUD_DEVELOPMENT.md' not in (repo / 'README.md').read_text():
        raise ValueError('README is missing the requested cloud development guide link.')
    run(['git', 'diff', '--cached', '--check'], repo)
    return task


def publish(repo, directory):
    task = apply_patch(repo, directory)
    branch = 'codex/cloud-pilot-' + task['id']
    message = f'docs: explain Neko cloud development boundaries\n\nNeko-Task: {task["id"]}'
    run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Neko Cloud Agent',
         '-c', 'user.email=neko-agent@users.noreply.github.com', 'commit', '-m', message], repo)
    sha = run(['git', 'rev-parse', 'HEAD'], repo)
    # Supply the token only through the trusted publisher's environment.
    env = dict(os.environ)
    header = base64.b64encode(('x-access-token:' + env['GH_TOKEN']).encode()).decode()
    env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
               GIT_CONFIG_VALUE_0='AUTHORIZATION: basic ' + header)
    existing = run(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], repo, env)
    if existing:
        previous = existing.split()[0]
        run(['git', 'fetch', 'origin', 'refs/heads/' + branch], repo, env)
        if (run(['git', 'rev-parse', previous + '^{tree}'], repo) != run(['git', 'rev-parse', 'HEAD^{tree}'], repo)
                or run(['git', 'rev-parse', previous + '^'], repo) != task['sha']):
            raise ValueError('Existing pilot branch differs; inspect it instead of overwriting it.')
        sha = previous
    else:
        run(['git', 'push', 'origin', f'HEAD:refs/heads/{branch}'], repo, env)
    pulls = json.loads(run(['gh', 'pr', 'list', '--repo', REPOSITORY, '--head', branch,
        '--state', 'all', '--json', 'url,state'], repo))
    if pulls:
        if len(pulls) != 1 or pulls[0]['state'] != 'OPEN':
            raise ValueError('Pilot already has a closed/merged PR. Do not create a duplicate.')
        url = pulls[0]['url']
    else:
        body = (f'Adds the cloud development guide and README link generated by the bounded Codex pilot.\n\n'
                f'Source: `{task["sha"]}`. Task: `{task["id"]}`.\n\n'
                'Only the two approved documentation paths were accepted by the publisher. '
                'The linked orchestration run performs macOS build and offline tests on this exact PR commit. '
                'Physical microphone, permissions, UI, updater installation and release are outside this pilot.\n\n'
                f'Orchestration: {os.environ["GITHUB_SERVER_URL"]}/{REPOSITORY}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n')
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=directory, suffix='.md') as file:
            file.write(body)
            file.flush()
            url = run(['gh', 'pr', 'create', '--repo', REPOSITORY, '--base', 'main', '--head', branch,
                '--draft', '--title', 'docs: explain Neko cloud development and macOS verification',
                '--body-file', file.name], repo)
    output(pr_url=url, head_sha=sha)


def report(sha, result):
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or result not in ('success', 'failure', 'cancelled', 'skipped'):
        raise ValueError('Invalid check result.')
    payload = dict(name='Neko cloud pilot / macOS exact commit', head_sha=sha, status='completed',
        conclusion='success' if result == 'success' else 'failure',
        details_url=f'{os.environ["GITHUB_SERVER_URL"]}/{REPOSITORY}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
        output=dict(title='macOS build and offline tests: ' + result,
                    summary='Native build and offline regression suites for this PR SHA. Physical-device behavior and release are unverified.'))
    subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{REPOSITORY}/check-runs', '--input', '-'],
                   input=json.dumps(payload).encode(), check=True, capture_output=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'cloud', 'audit', 'publish', 'report'])
    parser.add_argument('--directory', type=Path, default=Path('pilot-results'))
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--task-id')
    parser.add_argument('--sha')
    parser.add_argument('--result')
    for name in ('project', 'region', 'job', 'bucket'):
        parser.add_argument('--' + name, default=os.environ.get('NEKO_' + name.upper()))
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.directory, args.task_id, args.sha)
    elif args.action == 'cloud':
        cloud(args.directory, args.project, args.region, args.job, args.bucket)
    elif args.action == 'audit':
        cloud_audit(args.directory, args.project, args.region, args.job, args.bucket, args.task_id, args.sha)
    elif args.action == 'publish':
        publish(args.repo.resolve(), args.directory.resolve())
    else:
        report(args.sha, args.result)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as exc:
        # Do not include command/environment values that may contain credentials.
        sys.exit(f'Pipeline command failed (exit {exc.returncode}); no later step was run. Inspect provider run details.')
