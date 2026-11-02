import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import codex_adapter
import pipeline
import quickstart
import runner


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        runner.git(self.repo, 'init')
        (self.repo / 'README.md').write_text('Neko\n')
        runner.git(self.repo, 'add', '.')
        runner.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'source')
        self.sha = runner.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        self.results = self.root / 'results'
        with patch('builtins.print'):
            self.task = pipeline.prepare(self.results, 'pilot-123', self.sha)

    def tearDown(self):
        self.tmp.cleanup()

    def result(self, changes):
        if 'README.md' not in changes:
            changes = dict(changes, **{'README.md': 'Neko\n[開發](docs/CLOUD_DEVELOPMENT.md)\n'})
        for name, content in changes.items():
            item = self.repo / name
            item.parent.mkdir(parents=True, exist_ok=True)
            item.write_text(content)
        runner.git(self.repo, 'add', '--all')
        (self.results / 'changes.patch').write_bytes(runner.git(self.repo, 'diff', '--cached', '--binary'))
        runner.git(self.repo, 'reset', '--hard', self.sha)
        runner.git(self.repo, 'clean', '-fd')
        status = dict(id=self.task['id'], source_sha=self.sha, state='succeeded',
            task_digest=hashlib.sha256(json.dumps(self.task, sort_keys=True).encode()).hexdigest())
        (self.results / 'status.json').write_text(json.dumps(status))

    def test_accepts_regular_docs_at_exact_sha(self):
        self.result({'README.md': 'Neko\n[開發](docs/CLOUD_DEVELOPMENT.md)\n',
                     'docs/CLOUD_DEVELOPMENT.md': '雲端修改，macOS 測試。\n'})
        result = pipeline.apply_patch(self.repo, self.results)
        self.assertEqual(result['sha'], self.sha)
        self.assertEqual((self.repo / 'docs/CLOUD_DEVELOPMENT.md').read_text(), '雲端修改，macOS 測試。\n')

    def test_rejects_patch_outside_approved_docs(self):
        self.result({'docs/CLOUD_DEVELOPMENT.md': 'guide\n', '.github/workflows/evil.yml': 'run: anything\n'})
        with self.assertRaisesRegex(ValueError, 'approved documentation'):
            pipeline.apply_patch(self.repo, self.results)

    def test_rejects_symlink_even_at_allowed_path(self):
        (self.repo / 'docs').mkdir()
        (self.repo / 'docs/CLOUD_DEVELOPMENT.md').symlink_to('../README.md')
        (self.repo / 'README.md').write_text('Neko\n[開發](docs/CLOUD_DEVELOPMENT.md)\n')
        runner.git(self.repo, 'add', '--all')
        patch_data = runner.git(self.repo, 'diff', '--cached', '--binary')
        runner.git(self.repo, 'reset', '--hard', self.sha)
        self.result({'docs/CLOUD_DEVELOPMENT.md': 'normal\n'})
        (self.results / 'changes.patch').write_bytes(patch_data)
        with self.assertRaisesRegex(ValueError, 'regular non-executable'):
            pipeline.apply_patch(self.repo, self.results)

    def test_rejects_forged_success_result(self):
        self.result({'docs/CLOUD_DEVELOPMENT.md': 'guide\n'})
        status = json.loads((self.results / 'status.json').read_text())
        status['source_sha'] = '0' * 40
        (self.results / 'status.json').write_text(json.dumps(status))
        with self.assertRaisesRegex(ValueError, 'immutable request'):
            pipeline.apply_patch(self.repo, self.results)

    def test_rejects_modified_prompt_and_empty_patch(self):
        self.result({'docs/CLOUD_DEVELOPMENT.md': 'guide\n'})
        task = dict(self.task, prompt='Publish something else.')
        (self.results / 'task.json').write_text(json.dumps(task))
        with self.assertRaisesRegex(ValueError, 'fixed Neko'):
            pipeline.verify_result(self.results)
        (self.results / 'task.json').write_text(json.dumps(self.task))
        (self.results / 'changes.patch').write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'nonempty'):
            pipeline.verify_result(self.results)

    def test_rejects_wrong_checkout_before_apply(self):
        self.result({'docs/CLOUD_DEVELOPMENT.md': 'guide\n'})
        runner.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'later')
        with self.assertRaisesRegex(ValueError, 'exactly'):
            pipeline.apply_patch(self.repo, self.results)

    def test_unprivileged_environment_excludes_inherited_secrets(self):
        with patch.dict(os.environ, OPENAI_API_KEY='fixture-not-a-real-key', GH_TOKEN='fixture-token',
                        GOOGLE_APPLICATION_CREDENTIALS='/private/fixture'):
            env = codex_adapter.child_environment(Path('/isolated/home'))
        for key in ('OPENAI_API_KEY', 'GH_TOKEN', 'GOOGLE_APPLICATION_CREDENTIALS'):
            self.assertNotIn(key, env)
        command = codex_adapter.command(self.repo, 34567)
        self.assertIn('workspace-write', command)
        self.assertIn('sandbox_workspace_write.network_access=false', command)
        self.assertNotIn('danger-full-access', command)

    def test_provision_limits_federation_and_defers_real_key(self):
        args = type('Args', (), dict(action='provision', project='example-project', region='us-central1',
            job='neko-agent', bucket='example-results-bucket', image_tag='test', project_number='123456789012'))()
        commands = quickstart.commands(args)
        text = json.dumps(commands)
        self.assertIn('1297905701', text)
        self.assertIn('workflow_ref', text)
        self.assertIn('pull_request', text)
        self.assertNotIn('roles/editor', text)
        self.assertFalse(any('versions' in command for command in commands))
        args.action = 'deploy'
        args.secret_version = None
        with self.assertRaisesRegex(ValueError, 'secret-version'):
            quickstart.commands(args)
        args.action = 'check-runtime'
        probe = quickstart.commands(args)
        self.assertFalse(any('--set-secrets' in part for command in probe for part in command))
        self.assertTrue(any('--task-timeout=120s' in command for command in probe))

    def test_native_check_records_exact_sha(self):
        with patch.dict(os.environ, GITHUB_SERVER_URL='https://github.com', GITHUB_RUN_ID='123'), \
             patch('subprocess.run') as called:
            pipeline.report(self.sha, 'failure')
        payload = json.loads(called.call_args.kwargs['input'])
        self.assertEqual(payload['head_sha'], self.sha)
        self.assertEqual(payload['conclusion'], 'failure')

    def test_new_service_account_visibility_is_retried(self):
        missing = subprocess.CompletedProcess([], 1, '', 'HTTPError 400: Service account fixture@example.invalid does not exist.')
        success = subprocess.CompletedProcess([], 0, 'bound\n', '')
        command = ['gcloud', 'storage', 'buckets', 'add-iam-policy-binding', 'gs://fixture']
        with patch('subprocess.run', side_effect=[missing, success]) as called, \
             patch('time.sleep') as sleep, patch('builtins.print'):
            quickstart.apply_command(command)
        self.assertEqual(called.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_permission_denial_and_creation_collision_are_not_retried(self):
        for command, error in [(['gcloud', 'add-iam-policy-binding'], 'PERMISSION_DENIED'),
                               (['gcloud', 'service-accounts', 'create'], 'Service account fixture does not exist')]:
            with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', error)) as called, \
                 patch('time.sleep') as sleep, patch('builtins.print'):
                with self.assertRaises(subprocess.CalledProcessError):
                    quickstart.apply_command(command)
            called.assert_called_once()
            sleep.assert_not_called()

    def test_cloud_audit_uses_no_model_and_checks_returned_inventory_sha(self):
        for mismatch in (False, True):
            def fake_command(args, **kwargs):
                if 'describe' in args:
                    return subprocess.CompletedProcess(args, 1, b'', b'not found')
                if 'cp' in args and args[args.index('cp') + 1].startswith('gs://'):
                    task = json.loads((self.results / 'task.json').read_text())
                    self.assertEqual(task['mode'], 'audit')
                    self.assertNotIn('--set-secrets', args)
                    if args[-1].endswith('status.json'):
                        value = dict(id=task['id'], source_sha=task['sha'], state='succeeded',
                            task_digest=hashlib.sha256(json.dumps(task, sort_keys=True).encode()).hexdigest())
                    else:
                        value = dict(source_sha='0' * 40 if mismatch else task['sha'], tracked_files=1)
                    Path(args[-1]).write_text(json.dumps(value))
                return subprocess.CompletedProcess(args, 0, b'', b'')

            with patch('subprocess.run', side_effect=fake_command), patch('builtins.print'):
                if mismatch:
                    with self.assertRaisesRegex(ValueError, 'inventory does not match'):
                        pipeline.cloud_audit(self.results, 'example-project', 'us-central1',
                            'neko-agent', 'example-results-bucket', 'audit-123', self.sha)
                else:
                    pipeline.cloud_audit(self.results, 'example-project', 'us-central1',
                        'neko-agent', 'example-results-bucket', 'audit-123', self.sha)

    def test_publisher_reuses_branch_and_pr_without_force_push(self):
        self.result({'docs/CLOUD_DEVELOPMENT.md': '雲端開發\n'})
        origin = self.root / 'origin.git'
        subprocess.run(['git', 'init', '--bare', str(origin)], check=True, capture_output=True)
        runner.git(self.repo, 'remote', 'add', 'origin', str(origin))
        calls = []
        real_run = pipeline.run

        def fake_gh(args, cwd=None, env=None):
            calls.append(args)
            if args[:3] == ['gh', 'pr', 'list']:
                created = any(item[:3] == ['gh', 'pr', 'create'] for item in calls)
                return json.dumps([dict(state='OPEN', url='https://github.com/example/repo/pull/1')] if created else [])
            if args[:3] == ['gh', 'pr', 'create']:
                return 'https://github.com/example/repo/pull/1'
            return real_run(args, cwd, env)

        with patch.dict(os.environ, GH_TOKEN='fixture-token', GITHUB_SERVER_URL='https://github.com', GITHUB_RUN_ID='123'), \
             patch.object(pipeline, 'run', side_effect=fake_gh), patch('builtins.print'):
            pipeline.publish(self.repo, self.results)
            runner.git(self.repo, 'reset', '--hard', self.sha)
            pipeline.publish(self.repo, self.results)
        self.assertEqual(sum(args[:3] == ['gh', 'pr', 'create'] for args in calls), 1)
        self.assertEqual(sum(args[:2] == ['git', 'push'] for args in calls), 1)
        self.assertFalse(any('--force' in args for args in calls))


if __name__ == '__main__':
    unittest.main()
