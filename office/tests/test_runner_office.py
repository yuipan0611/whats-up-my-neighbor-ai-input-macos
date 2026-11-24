"""Sandbox runs through the office (tasks/H3-runner-docker-v1.md 5.3–5.5), with FakeRunner as the provider.

The "remote" is a git repository in a temporary folder; nothing goes to GitHub or a real sandbox.
What is checked: the worker cannot pick the repository, branch or commit; results land only on the
task branch in the office's own checkout; a cancelled or taken-back task loses its sandbox at the
next sweep; nothing is pushed anywhere."""
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import uuid

from test_office import app, FakeModel, local_request, LOCAL_HOST

import runner as rn

REPO = 'owner/test-repo'


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


class OfficeRunBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remotes' / REPO
        self.remote.mkdir(parents=True)
        git(self.remote, 'init', '-q', '-b', 'main')
        git(self.remote, 'config', 'user.name', 'neko-test')
        git(self.remote, 'config', 'user.email', 'neko-test@example.test')
        (self.remote / 'README.md').write_text('old\n')
        (self.remote / '.env').write_text('TOKEN=fictional-canary-4410\n')
        git(self.remote, 'add', '-A')
        git(self.remote, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'base')
        self.store = app.Store(self.root / 'data')
        self.fake = rn.FakeRunner()
        self.checkouts = rn.Checkouts(self.root / 'checkouts', remote=str(self.root / 'remotes') + '/{repo}')
        self.office = app.Office(self.store, FakeModel(), sandbox=self.fake, checkouts=self.checkouts)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：改 README', 'executor': 'hands'})['task']
        self.claimed = self.store.claim_hands()
        self.lease = self.claimed['lease']

    def tearDown(self):
        for thread in self.office.run_threads.values():
            thread.join(10)
        self.temp.cleanup()

    def request(self, **extra):
        return {'task_id': self.task['id'], 'lease': self.lease, 'paths': ['README.md'], 'command': ['make'], **extra}

    def bind(self):
        return self.office.bind_repo(self.task['id'], {'repo': REPO, 'base': 'main'})

    def finish(self):
        for thread in self.office.run_threads.values():
            thread.join(10)
        return self.office.run_status({'task_id': self.task['id'], 'lease': self.lease})

    def branch(self):
        return f"neko/{self.task['id'][:8]}"

    def refused(self, body, code):
        with self.assertRaises(app.OfficeError) as e:
            self.office.run_start(body)
        self.assertEqual(e.exception.code, code)
        return e.exception.extra.get('reason_code')


class FlowTests(OfficeRunBase):
    def test_a_run_lands_only_on_the_task_branch_of_the_office_checkout(self):
        self.bind()
        started = self.office.run_start(self.request())
        self.assertEqual(started['state'], 'ready')
        self.assertNotIn('sandbox_id', started)
        status = self.finish()
        self.assertEqual((status['state'], status['published'], status['log']), ('published', True, 'ok\n'))
        worktree = self.checkouts.worktree(self.task['id'])
        self.assertEqual((worktree / 'README.md').read_text(), 'new\n')
        self.assertEqual(git(worktree, 'rev-parse', '--abbrev-ref', 'HEAD'), self.branch())
        self.assertIn(f"Neko-Run: {started['run_id']}", git(worktree, 'log', '-1', '--format=%B'))
        # The original repository is untouched and nothing was pushed to it.
        self.assertEqual((self.remote / 'README.md').read_text(), 'old\n')
        self.assertEqual(git(self.remote, 'branch', '--list', 'neko/*'), '')
        self.assertEqual(git(self.checkouts.bare(REPO), 'rev-list', '--count', 'main'), '1')

    def test_the_worker_cannot_name_repo_branch_commit_or_base(self):
        self.bind()
        for key in ('repo', 'branch', 'base', 'source_rev', 'remote'):
            self.assertEqual(self.refused(self.request(**{key: 'x'}), 400), 'bad_request', key)
        for command in ([], 'make', [1], ['a\x00b']):
            self.assertEqual(self.refused(self.request(command=command), 400), 'bad_command')
        self.assertFalse((self.root / 'checkouts').exists())

    def test_no_repo_or_an_old_lease_gets_nothing_cloned(self):
        self.assertEqual(self.refused(self.request(), 409), 'no_repo')
        self.bind()
        self.assertEqual(self.refused(self.request(lease='not-the-lease'), 409), 'superseded')
        self.assertFalse((self.root / 'checkouts').exists())
        self.assertEqual(self.fake.calls, [])

    def test_secrets_in_the_repo_are_not_sent(self):
        self.bind()
        self.assertEqual(self.refused(self.request(paths=['.env']), 409), 'excluded_path')
        self.assertEqual(self.fake.calls, [])

    def test_one_task_one_repo(self):
        self.bind()
        with self.assertRaises(app.OfficeError):
            self.office.bind_repo(self.task['id'], {'repo': 'owner/other', 'base': 'main'})

    def test_private_repo_fails_without_asking_for_a_sign_in(self):
        self.checkouts.remote = 'https://127.0.0.1:9/{repo}.git'  # nothing listens there; no prompt, no stored credential
        self.bind()
        self.assertEqual(self.refused(self.request(), 409), 'checkout_failed')


class SweepTests(OfficeRunBase):
    def ready_run(self):
        self.bind()
        worktree, _, rev = self.checkouts.prepare(self.task['id'], REPO, 'main')
        return self.office.runs.start(self.task['id'], self.lease, worktree, ['README.md'], rev)

    def test_cancelled_task_loses_its_sandbox_at_the_next_sweep(self):
        run = self.ready_run()
        self.store.cancel(self.task['id'])
        self.assertEqual(self.office.runs.sweep(), [run['run_id']])
        run = self.office.runs.run(run['run_id'])
        self.assertEqual((run['state'], run['detail'], run['cleanup']), ('cancelled', 'task_stopped', 'done'))
        self.assertEqual(self.fake.boxes[run['sandbox_id']]['state'], 'gone')

    def test_taking_the_hands_back_removes_every_sandbox(self):
        run = self.ready_run()
        self.store.set_hands_locked(True)
        self.office.runs.sweep()
        self.assertEqual(self.office.runs.run(run['run_id'])['detail'], 'hands_locked')

    def test_a_live_run_is_left_alone(self):
        self.ready_run()
        self.assertEqual(self.office.runs.sweep(), [])

    def test_cancel_during_execute_stays_cancelled_and_publishes_nothing(self):
        run = self.ready_run()
        original = self.fake.execute
        def execute(sandbox_id, command, seconds):
            result = original(sandbox_id, command, seconds)
            self.store.cancel(self.task['id'])
            self.office.runs.sweep()  # the office's tick lands while the command is still running
            return result
        self.fake.execute = execute
        thread = threading.Thread(target=self.office.drive_run, args=(self.task['id'], run['run_id'], self.lease, ['make']))
        thread.start(); thread.join(10)
        self.assertEqual(self.office.runs.run(run['run_id'])['state'], 'cancelled')
        self.assertEqual((self.checkouts.worktree(self.task['id']) / 'README.md').read_text(), 'old\n')

    def test_restart_mid_publish_settles_on_the_office_checkout(self):
        run = self.ready_run()
        run = self.office.runs.execute(run['run_id'], self.lease, ['make'])
        self.office.runs.verify(run['run_id'])
        target = self.checkouts.target(self.task['id'])
        target.apply(run['run_id'], rn.FakeRunner().result['patch'])  # landed, then the office died
        self.office.runs.set(run['run_id'], 'publishing')
        office = app.Office(self.store, FakeModel(), sandbox=self.fake, checkouts=self.checkouts)
        self.assertEqual(office.runs.run(run['run_id'])['state'], 'published')
        self.assertEqual(git(target.worktree, 'rev-list', '--count', self.branch()), '2')  # applied once


class CheckedRunner(rn.FakeRunner):
    """FakeRunner with the self-check DockerRunner has: reachable is what the probe container could reach."""

    def __init__(self, reachable):
        super().__init__()
        self.reachable, self.checks = reachable, 0

    def self_check(self):
        self.checks += 1
        return list(self.reachable)


class SelfCheckTests(OfficeRunBase):
    def office_with(self, reachable):
        self.fake = CheckedRunner(reachable)
        self.office = app.Office(self.store, FakeModel(), sandbox=self.fake, checkouts=self.checkouts)
        self.bind()

    def test_a_sandbox_that_reaches_the_host_is_never_started(self):
        self.office_with(['host_loopback'])
        self.assertEqual(self.office.sandbox_check['reachable'], ['host_loopback'])  # measured at start
        self.assertEqual(self.refused(self.request(), 409), 'sandbox_unsafe')
        self.assertFalse((self.root / 'checkouts').exists())
        self.assertEqual([c for c in self.fake.calls if c[0] == 'create'], [])

    def test_a_passed_check_lasts_ten_minutes_then_is_measured_again(self):
        self.office_with([])
        now = [1000.0]
        self.office.clock = lambda: now[0]
        self.office.sandbox_check['at'] = now[0]
        self.office.run_start(self.request())
        self.assertEqual(self.fake.checks, 1)  # only the start-up check
        now[0] += 601
        self.fake.reachable = ['network_gateway']  # e.g. the firewall rules were lost in a reboot
        for thread in self.office.run_threads.values():
            thread.join(10)
        self.assertEqual(self.office.run_status({'task_id': self.task['id'], 'lease': self.lease})['state'], 'published')
        self.store.cancel(self.task['id'])
        task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：第二件', 'executor': 'hands'})['task']
        lease = self.store.claim_hands()['lease']
        self.office.bind_repo(task['id'], {'repo': REPO})
        with self.assertRaises(app.OfficeError) as e:
            self.office.run_start({**self.request(), 'task_id': task['id'], 'lease': lease})
        self.assertEqual((e.exception.extra['reason_code'], self.fake.checks), ('sandbox_unsafe', 2))

    def test_a_fixed_firewall_is_noticed_at_the_next_request(self):
        self.office_with(['host_address'])
        self.fake.reachable = []
        self.assertEqual(self.office.run_start(self.request())['state'], 'ready')


class RouteTests(OfficeRunBase):
    def setUp(self):
        super().setUp()
        self.worker_path = self.root / 'worker' / 'worker.sock'
        self.local_path = self.root / 'run' / 'office.sock'
        self.server = app.Server(0, self.office, local_socket=self.local_path, worker_socket=self.worker_path)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def post(self, socket_path, path, body):
        headers = {'Content-Type': 'application/json'}
        if socket_path == self.local_path:  # the owner's page sends its token with every change
            headers.update({'Host': LOCAL_HOST, 'X-Office-Token': self.server.token})
        status, raw, _ = local_request(socket_path, path, json.dumps(body).encode(), headers)
        return status, json.loads(raw) if raw else None

    def test_owner_binds_and_worker_runs_through_the_sockets(self):
        status, _ = self.post(self.worker_path, f"/api/tasks/{self.task['id']}/repo", {'repo': REPO})
        self.assertEqual(status, 404)  # the worker cannot bind a repository
        status, body = self.post(self.local_path, f"/api/tasks/{self.task['id']}/repo", {'repo': REPO})
        self.assertEqual((status, body.get('repo')), (200, REPO), body)
        status, body = self.post(self.worker_path, '/api/worker/run/start', self.request())
        self.assertEqual((status, body['state']), (200, 'ready'))
        self.assertEqual(self.finish()['state'], 'published')
        status, body = self.post(self.worker_path, '/api/worker/run/status', {'task_id': self.task['id'], 'lease': 'x'})
        self.assertEqual((status, body.get('reason_code')), (409, 'superseded'))


class OffTests(unittest.TestCase):
    def test_without_a_sandbox_the_routes_do_not_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            office = app.Office(app.Store(root / 'data'), FakeModel())
            self.assertIsNone(office.checkouts)
            worker_path = root / 'worker' / 'worker.sock'
            server = app.Server(0, office, local_socket=root / 'run' / 'office.sock', worker_socket=worker_path)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                status, _, _ = local_request(worker_path, '/api/worker/run/start', b'{"task_id":"x"}', {'Content-Type': 'application/json'})
                self.assertEqual(status, 404)
            finally:
                server.shutdown(); server.server_close()


if __name__ == '__main__':
    unittest.main()
