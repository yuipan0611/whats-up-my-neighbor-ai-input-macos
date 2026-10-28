"""DockerRunner against a real Docker daemon (tasks/H3-runner-docker-v1.md, section 6).

Off by default: runs only with NEKO_DOCKER_TEST=1 and a reachable daemon. It builds office/sandbox/Dockerfile,
uses its own network and a synthetic repository in a temporary folder, and removes every container it made.
Whether a container can reach back to the host is measured separately; on Docker Desktop for Mac that
path goes through Docker's own VM and says nothing about a Linux host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

from test_office import app, FakeModel

import runner as rn
import runner_docker as rd

IMAGE, NETWORK, REPO = 'neko-runner:test', 'neko-runner-test', 'owner/test-repo'
SANDBOX_DIR = Path(__file__).resolve().parents[1] / 'sandbox'
CANARY = 'fictional-canary-secret-5521'


def docker(*args, check=True):
    return subprocess.run(['docker', *args], capture_output=True, text=True, check=check, timeout=600)


def available():
    if os.environ.get('NEKO_DOCKER_TEST') != '1':
        return False
    try:
        return docker('info', check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


@unittest.skipUnless(available(), 'real Docker test: set NEKO_DOCKER_TEST=1 with a running Docker daemon')
class RealDockerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docker('build', '--quiet', '-t', IMAGE, str(SANDBOX_DIR))
        if docker('network', 'inspect', NETWORK, check=False).returncode != 0:
            docker('network', 'create', NETWORK)

    def setUp(self):
        os.environ['NEKO_CANARY_SECRET'] = CANARY  # present in the office's environment; must not reach a container
        self.addCleanup(os.environ.pop, 'NEKO_CANARY_SECRET', None)
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remotes' / REPO
        self.remote.mkdir(parents=True)
        git(self.remote, 'init', '-q', '-b', 'main')
        git(self.remote, 'config', 'user.name', 'neko-test')
        git(self.remote, 'config', 'user.email', 'neko-test@example.test')
        (self.remote / 'README.md').write_text('old\n')
        git(self.remote, 'add', '-A')
        git(self.remote, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'base')
        (self.root / 'host-canary.txt').write_text('host file, never visible inside\n')
        self.store = app.Store(self.root / 'data')
        self.docker = rd.DockerRunner(IMAGE, network=NETWORK)
        # Docker Desktop fails the self-check (test_self_check_on_this_host); the functional tests run on it anyway.
        self.docker.self_check = lambda timeout=2: []
        self.checkouts = rn.Checkouts(self.root / 'checkouts', remote=str(self.root / 'remotes') + '/{repo}')
        self.office = app.Office(self.store, FakeModel(), sandbox=self.docker, checkouts=self.checkouts)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：改 README', 'executor': 'hands'})['task']
        self.lease = self.store.claim_hands()['lease']
        self.office.bind_repo(self.task['id'], {'repo': REPO})

    def tearDown(self):
        for thread in self.office.run_threads.values():
            thread.join(120)
        left = docker('ps', '-aq', '--filter', 'label=neko_run').stdout.split()
        if left:
            docker('rm', '-f', *left, check=False)
        self.temp.cleanup()

    def ready(self, **limits):
        worktree, _, rev = self.checkouts.prepare(self.task['id'], REPO, 'main')
        run = self.office.runs.start(self.task['id'], self.lease, worktree, ['README.md'], rev, limits=limits or None)
        self.assertEqual(run['state'], 'ready', run)
        return run

    def containers(self, run_id):
        return docker('ps', '-aq', '--filter', f'label=neko_run={run_id}').stdout.split()

    def inside(self, run, *command):
        return docker('exec', run['sandbox_id'], *command, check=False)

    def test_full_run_lands_on_the_task_branch_and_leaves_no_container(self):
        started = self.office.run_start({'task_id': self.task['id'], 'lease': self.lease, 'paths': ['README.md'],
                                         'command': ['sh', '-c', 'echo new > README.md && echo built']})
        for thread in self.office.run_threads.values():
            thread.join(120)
        status = self.office.run_status({'task_id': self.task['id'], 'lease': self.lease})
        self.assertEqual((status['state'], status['log']), ('published', 'built\n'), status)
        worktree = self.checkouts.worktree(self.task['id'])
        self.assertEqual((worktree / 'README.md').read_text(), 'new\n')
        self.assertEqual(git(worktree, 'rev-parse', '--abbrev-ref', 'HEAD'), f"neko/{self.task['id'][:8]}")
        self.assertEqual((self.remote / 'README.md').read_text(), 'old\n')  # the original repository is untouched
        self.assertEqual(self.containers(started['run_id']), [])

    def test_container_has_no_host_files_no_secrets_and_no_privilege(self):
        run = self.ready()
        info = json.loads(docker('inspect', run['sandbox_id']).stdout)[0]
        host = info['HostConfig']
        self.assertEqual(info['Mounts'], [])
        self.assertFalse(host['Privileged'])
        self.assertEqual(host['CapDrop'], ['ALL'])
        self.assertIn('no-new-privileges', host['SecurityOpt'])
        self.assertEqual((info['Config']['User'], host['NetworkMode']), ('10001:10001', NETWORK))
        self.assertFalse(host.get('PortBindings'))
        self.assertEqual(self.inside(run, 'id', '-u').stdout.strip(), '10001')
        env = self.inside(run, 'env').stdout
        self.assertNotIn(CANARY, env)
        self.assertNotIn(CANARY, json.dumps(info))
        self.assertEqual(sorted(self.inside(run, 'ls', '-A', '/work').stdout.split()), ['.git', 'README.md'])
        found = self.inside(run, 'sh', '-c', 'find / -name host-canary.txt 2>/dev/null; true').stdout
        self.assertEqual(found.strip(), '')
        self.assertNotEqual(self.inside(run, 'ls', '/var/run/docker.sock').returncode, 0)

    def test_time_limit_ends_the_run_and_removes_the_container(self):
        run = self.ready(seconds=3)
        started = time.monotonic()
        run = self.office.runs.execute(run['run_id'], self.lease, ['sleep', '60'])
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual((run['state'], run['detail'], run['cleanup']), ('failed', 'time_limit', 'done'))
        self.assertEqual(self.containers(run['run_id']), [])

    def test_failing_command_keeps_its_log_and_publishes_nothing(self):
        run = self.office.runs.execute(self.ready()['run_id'], self.lease, ['sh', '-c', 'echo broken >&2; exit 3'])
        self.assertEqual((run['state'], run['detail'], run['exit_code']), ('failed', 'nonzero_exit', 3))
        log = self.office.runs.runs_dir(run) / 'staging' / 'log.txt'
        self.assertEqual(log.read_text(), 'broken\n')

    def test_command_text_is_not_run_as_shell(self):
        run = self.ready()
        result = self.docker.execute(run['sandbox_id'], ['echo', 'x; touch /tmp/pwned'], 30)
        self.assertEqual(result['exit_code'], 0)
        self.assertNotEqual(self.inside(run, 'ls', '/tmp/pwned').returncode, 0)

    def test_outbound_network_is_allowed(self):
        run = self.office.runs.execute(self.ready()['run_id'], self.lease, [
            'python3', '-c', 'import urllib.request; urllib.request.urlopen("https://pypi.org/simple/six/", timeout=20)'])
        self.assertEqual(run['exit_code'], 0, run)

    def test_cancel_removes_the_live_container_at_the_next_sweep(self):
        run = self.ready()
        self.assertEqual(len(self.containers(run['run_id'])), 1)
        self.store.cancel(self.task['id'])
        self.office.runs.sweep()
        self.assertEqual(self.containers(run['run_id']), [])

    def test_self_check_on_this_host(self):
        reachable = rd.DockerRunner(IMAGE, network=NETWORK).self_check()
        desktop = 'docker desktop' in docker('info', '--format', '{{.OperatingSystem}}').stdout.lower()
        if desktop:
            self.assertIn('host_loopback', reachable)  # measured 2026-10-28: Docker Desktop forwards the Mac's loopback
            office = app.Office(self.store, FakeModel(), sandbox=rd.DockerRunner(IMAGE, network=NETWORK),
                                checkouts=self.checkouts)
            with self.assertRaises(app.OfficeError) as e:
                office.run_start({'task_id': self.task['id'], 'lease': self.lease, 'paths': ['README.md'], 'command': ['true']})
            self.assertEqual(e.exception.extra['reason_code'], 'sandbox_unsafe')
            self.assertEqual(docker('ps', '-aq', '--filter', 'label=neko_run').stdout.split(), [])
        elif os.environ.get('NEKO_DOCKER_EXPECT_ISOLATED') == '1':
            self.assertEqual(reachable, [])  # a host whose firewall is in place
        else:
            self.skipTest(f'not Docker Desktop; reachable={reachable}; set NEKO_DOCKER_EXPECT_ISOLATED=1 to require none')
        self.assertEqual(docker('ps', '-aq', '--filter', 'label=neko_probe').stdout.split(), [])  # --rm left nothing

    def test_restart_finds_and_removes_a_container_whose_create_answer_was_lost(self):
        worktree, _, rev = self.checkouts.prepare(self.task['id'], REPO, 'main')
        original = self.docker.create
        def lost(run_id, labels):
            original(run_id, labels)
            raise rn.RunnerUnknown('create answer lost')  # the container exists; the office did not hear back
        self.docker.create = lost
        run = self.office.runs.start(self.task['id'], self.lease, worktree, ['README.md'], rev)
        self.assertEqual((run['state'], len(self.containers(run['run_id']))), ('create_unknown', 1))
        self.docker.create = original
        app.Office(self.store, FakeModel(), sandbox=self.docker, checkouts=self.checkouts)  # the office restarts
        self.assertEqual(self.containers(run['run_id']), [])


if __name__ == '__main__':
    unittest.main()
