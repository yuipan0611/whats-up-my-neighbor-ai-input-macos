import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import runner
from costs import estimate


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'fixture'
        self.repo.mkdir()
        runner.git(self.repo, 'init')
        (self.repo / 'README.md').write_text('Original\n')
        runner.git(self.repo, 'add', '.')
        runner.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
        self.sha = runner.git(self.repo, 'rev-parse', 'HEAD').decode().strip()
        self.store = runner.LocalStore(self.root / 'results')
        self.task = {'id': 'fixture-001', 'repo': 'https://github.com/example/fixture',
                     'sha': self.sha, 'mode': 'audit', 'prompt': 'Inspect only.'}

    def tearDown(self):
        self.temporary.cleanup()

    def adapter(self, content):
        path = self.root / 'adapter.sh'
        path.write_text('set -euo pipefail\n' + content)
        return path

    def test_audit_is_durable_and_duplicate_skips_checkout(self):
        result = runner.execute(self.task, self.store, fixture_repo=self.repo)
        self.assertEqual(result['state'], 'succeeded')
        (self.repo / 'README.md').unlink()
        duplicate = runner.execute(self.task, self.store, fixture_repo='/does/not/exist')
        self.assertEqual(duplicate['attempt'], 1)
        self.assertFalse(result['native_macos_tested'])

    def test_develop_collects_new_file_and_does_not_modify_source(self):
        self.task['mode'] = 'develop'
        adapter = self.adapter('printf "A new note\\n" > "$2/NOTES.md"\n')
        result = runner.execute(self.task, self.store, adapter, self.repo)
        self.assertEqual(result['changed_paths'], ['NOTES.md'])
        self.assertIn(b'+A new note', self.store.read('tasks/fixture-001/changes.patch')[0])
        self.assertFalse((self.repo / 'NOTES.md').exists())

    def test_protected_workflow_change_is_rejected(self):
        self.task['mode'] = 'develop'
        adapter = self.adapter('mkdir -p "$2/.github/workflows"\nprintf "changed" > "$2/.github/workflows/release.yml"\n')
        with self.assertRaisesRegex(ValueError, 'Protected paths'):
            runner.execute(self.task, self.store, adapter, self.repo)
        self.assertIsNone(self.store.read('tasks/fixture-001/changes.patch')[0])

    def test_running_lease_blocks_duplicate(self):
        runner.write_json(self.store, 'tasks/fixture-001/lease.json', {'owner': 'other', 'expires_at': 1e20}, '0')
        with self.assertRaises(runner.Conflict):
            runner.execute(self.task, self.store, fixture_repo=self.repo)

    def test_same_id_different_prompt_rejected(self):
        runner.execute(self.task, self.store, fixture_repo=self.repo)
        self.task['prompt'] = 'Different request'
        with self.assertRaisesRegex(ValueError, 'different input'):
            runner.execute(self.task, self.store, fixture_repo=self.repo)

    def test_failed_adapter_can_retry_same_task(self):
        self.task['mode'] = 'develop'
        with self.assertRaisesRegex(ValueError, 'exited 7'):
            runner.execute(self.task, self.store, self.adapter('exit 7\n'), self.repo)
        result = runner.execute(self.task, self.store, self.adapter('printf "fixed\\n" > "$2/NOTES.md"\n'), self.repo)
        self.assertEqual(result['attempt'], 2)

    def test_manifest_rejects_shell_urls_and_moving_refs(self):
        for field, value in [('repo', 'https://github.com/a/b;touch /tmp/unwanted'), ('sha', 'main'), ('id', '../bad')]:
            bad = dict(self.task, **{field: value})
            with self.assertRaises(ValueError):
                runner.validate_task(bad)

    def test_timeout_stops_work_and_preserves_failed_state(self):
        self.task['mode'] = 'develop'
        marker = self.root / 'descendant-survived'
        script = '(sleep .3; printf "alive" > ' + json.dumps(str(marker)) + ') &\nwait\n'
        with self.assertRaises(TimeoutError):
            runner.execute(self.task, self.store, self.adapter(script), self.repo, adapter_timeout=.05)
        time.sleep(.4)
        self.assertFalse(marker.exists())
        status, _ = runner.read_json(self.store, 'tasks/fixture-001/status.json')
        self.assertEqual(status['state'], 'failed')
        lease, _ = runner.read_json(self.store, 'tasks/fixture-001/lease.json')
        self.assertEqual(lease['expires_at'], 0)

    def test_renaming_a_protected_file_is_rejected(self):
        (self.repo / 'Resources').mkdir()
        (self.repo / 'Resources/Info.plist').write_text('protected')
        runner.git(self.repo, 'add', '.')
        runner.git(self.repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'protected fixture')
        self.task.update(mode='develop', sha=runner.git(self.repo, 'rev-parse', 'HEAD').decode().strip())
        with self.assertRaisesRegex(ValueError, 'Protected paths'):
            runner.execute(self.task, self.store, self.adapter('mv "$2/Resources/Info.plist" "$2/moved.plist"\n'), self.repo)

    def test_gcs_lease_uses_compare_and_swap(self):
        store = runner.GCSStore('fixture-results-bucket')
        conflict = HTTPError('https://storage.googleapis.com/', 412, 'precondition', {}, None)
        with patch.object(store, 'request', side_effect=conflict) as request:
            with self.assertRaises(runner.Conflict):
                store.write('tasks/a/lease.json', b'{}', generation='0')
            self.assertIn('ifGenerationMatch=0', request.call_args.args[0])

    def test_plan_does_not_execute_cloud_commands(self):
        import quickstart
        args = type('Arguments', (), dict(project='example-project', region='us-central1',
            job='always-on-dev', bucket='example-results-bucket', image_tag='test',
            action='provision', project_number='123456789012', apply=False))()
        with patch('subprocess.run') as run, patch('builtins.print'):
            quickstart.deploy(args)
        run.assert_not_called()

    def test_price_calculation(self):
        self.assertAlmostEqual(estimate(60, .2)['gcp_jobs_compute_usd'], 6.012)
        self.assertAlmostEqual(estimate(60, .2)['cloudflare_subscription_and_container_usd'], 10.5645)


if __name__ == '__main__':
    unittest.main()
