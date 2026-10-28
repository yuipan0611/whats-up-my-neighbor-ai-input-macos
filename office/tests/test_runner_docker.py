"""DockerRunner against a recording stand-in for the docker command (tasks/H3-runner-docker-v1.md).

No Docker daemon is started or needed: every docker call goes to FakeDocker, which records the
arguments and answers the way docker does. What these tests prove is what the office asks docker
to do; whether a real container behaves that way is NOT RUN until a real Docker test is approved."""
import io
import json
import socket
import subprocess
import sys
import tarfile
import unittest

from test_runner import RunnerBase, PATCH, CANARY, git, rn

import runner_docker as rd


class FakeDocker:
    def __init__(self):
        self.calls, self.inputs, self.answers, self.state = [], [], {}, 'running'
        self.log, self.patch, self.exit_code = b'tests passed\n', PATCH, 0

    def __call__(self, argv, input=None, capture_output=True, timeout=None):
        self.calls.append(argv)
        self.inputs.append(input)
        args = argv[1:]
        command = args[0]
        answer = self.answers.pop(command, None)
        if isinstance(answer, BaseException):
            raise answer
        if answer is not None:
            return answer
        if command == 'inspect':
            return self.done(self.state.encode())
        if command == 'ps':
            return self.done(b'')
        if command == 'exec':
            line = ' '.join(args)
            if 'git diff' in line:
                return self.done(self.patch)
            if 'head -c' in line:
                return self.done(self.log)
            if 'timeout -k' in line:
                return self.done(b'', code=self.exit_code)
        return self.done(b'')

    @staticmethod
    def done(stdout, code=0, stderr=b''):
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def commands(self):
        return [c[1] for c in self.calls]


class FlagTests(unittest.TestCase):
    def test_container_flags_hold_both_red_lines(self):
        args = rd.DockerRunner('neko-runner:v1').create_args('r1')
        joined = ' '.join(args)
        for needed in ('--cap-drop ALL', '--security-opt no-new-privileges', '--user 10001:10001',
                       '--network neko-runner', '--label neko_run=r1', '--pids-limit 512'):
            self.assertIn(needed, joined)
        for never in ('-v', '--volume', '--mount', '--privileged', '--network host', 'docker.sock', '--env-file',
                      '--cap-add', '-p', '--publish'):
            self.assertNotIn(never, args)
        env = [args[i + 1] for i, a in enumerate(args) if a == '--env']
        self.assertEqual(sorted(e.split('=')[0] for e in env), ['CI', 'HOME', 'LANG', 'PATH'])

    def test_shared_networks_are_refused(self):
        for network in ('host', 'none', 'bridge', 'default', ''):
            with self.assertRaises(ValueError, msg=network):
                rd.DockerRunner('img', network=network)


class CallTests(unittest.TestCase):
    def setUp(self):
        self.docker = FakeDocker()
        self.runner = rd.DockerRunner('img', run=self.docker)

    def test_failures_map_to_runner_errors_and_never_fall_back(self):
        cases = [(FileNotFoundError(), rn.RunnerFailed),
                 (subprocess.TimeoutExpired('docker', 60), rn.RunnerUnknown),
                 (FakeDocker.done(b'', 1, b'Error: No such container: x'), rn.RunnerGone),
                 (FakeDocker.done(b'', 1, b'permission denied'), rn.RunnerFailed)]
        for answer, error in cases:
            with self.subTest(error=error.__name__):
                self.docker.answers['pause'] = answer
                with self.assertRaises(error):
                    self.runner.pause('neko-run-x')

    def test_start_failure_removes_the_container(self):
        self.docker.answers['start'] = FakeDocker.done(b'', 1, b'oci runtime error')
        with self.assertRaises(rn.RunnerFailed):
            self.runner.create('r1', {})
        self.assertEqual(self.docker.commands(), ['create', 'start', 'rm'])

    def test_start_and_remove_failing_is_unknown_so_restart_finds_it(self):
        self.docker.answers['start'] = FakeDocker.done(b'', 1, b'oci runtime error')
        self.docker.answers['rm'] = subprocess.TimeoutExpired('docker', 60)
        with self.assertRaises(rn.RunnerUnknown):
            self.runner.create('r1', {})

    def test_command_is_passed_as_arguments_not_shell_text(self):
        evil = 'x; touch /tmp/pwned'
        result = self.runner.execute('c1', ['echo', evil], 30)
        argv = self.docker.calls[-1]
        self.assertIn(evil, argv)  # one argument, after the fixed script
        self.assertNotIn(evil, argv[argv.index('-c') + 1])
        self.assertEqual(result['exit_code'], 0)

    def test_exit_codes_timeouts_and_lost_answers(self):
        self.docker.exit_code = 3
        self.assertEqual(self.runner.execute('c1', ['make'], 30)['exit_code'], 3)  # the run's result, not a docker error
        self.docker.exit_code = rd.TIMED_OUT
        self.assertTrue(self.runner.execute('c1', ['make'], 30)['timed_out'])
        self.docker.answers['exec'] = subprocess.TimeoutExpired('docker', 60)
        with self.assertRaises(rn.RunnerUnknown):
            self.runner.execute('c1', ['make'], 30)
        self.docker.answers['exec'] = FakeDocker.done(b'', 1, b'Error: container c1 is not running')
        with self.assertRaises(rn.RunnerGone):
            self.runner.execute('c1', ['make'], 30)
        self.docker.answers['exec'] = FakeDocker.done(b'', 126, b'OCI runtime exec failed')
        with self.assertRaises(rn.RunnerFailed):
            self.runner.execute('c1', ['make'], 30)
        for bad in ([], 'make', [1]):
            with self.assertRaises(rn.RunnerFailed):
                self.runner.execute('c1', bad, 30)

    def test_status_and_collect(self):
        for docker_state, ours in (('running', 'running'), ('paused', 'paused'), ('exited', 'exited'), ('created', 'exited')):
            self.docker.state = docker_state
            self.assertEqual(self.runner.status('c1'), ours)
        self.docker.answers['inspect'] = FakeDocker.done(b'', 1, b'Error: No such object: c1')
        self.assertEqual(self.runner.status('c1'), 'gone')
        self.docker.state = 'exited'
        got = self.runner.collect('c1', 1000)
        self.assertEqual(got, {'log': b'tests passed\n', 'patch': PATCH})
        self.assertIn('start', self.docker.commands())  # a stopped container is started to read what it left
        self.docker.answers['inspect'] = FakeDocker.done(b'', 1, b'Error: No such object: c1')
        with self.assertRaises(rn.RunnerGone):
            self.runner.collect('c1', 1000)

    def test_destroying_a_gone_container_is_fine(self):
        self.docker.answers['rm'] = FakeDocker.done(b'', 1, b'Error: No such container: c1')
        self.runner.destroy('c1')


class SelfCheckTests(unittest.TestCase):
    def setUp(self):
        self.docker = FakeDocker()
        self.runner = rd.DockerRunner('img', network='neko-runner', run=self.docker)

    def probe(self, answers):
        self.docker.answers['network'] = FakeDocker.done(b'172.18.0.1 ')
        self.docker.answers['run'] = FakeDocker.done(json.dumps(answers).encode()) if isinstance(answers, list) else answers
        return self.runner.self_check()

    def targets(self):
        argv = next(c for c in self.docker.calls if c[1] == 'run')
        return [tuple(t) for t in json.loads(argv[argv.index(rd.PROBE) + 1])]

    def test_all_blocked_passes(self):
        self.assertEqual(self.probe(['blocked'] * 5), [])
        self.docker.answers['network'] = FakeDocker.done(b'172.18.0.1 ')
        names = [t[0] for t in self.runner.probe_targets(1234)]
        self.assertEqual(names[:3] + names[-1:], ['host_loopback', 'network_gateway', 'network_gateway_ssh', 'cloud_metadata'])

    def test_any_answer_even_a_refusal_fails(self):
        self.assertEqual(self.probe(['refused', 'blocked', 'blocked', 'blocked', 'blocked']), ['host_loopback'])
        self.assertEqual(self.probe(['blocked', 'connected', 'blocked', 'blocked', 'blocked']), ['network_gateway'])

    def test_a_probe_that_cannot_run_counts_as_unsafe(self):
        for answer in (FakeDocker.done(b'', 125, b'Unable to find image'), FakeDocker.done(b'not json'),
                       FakeDocker.done(b'["blocked"]'), FileNotFoundError(), subprocess.TimeoutExpired('docker', 60)):
            with self.subTest(answer=repr(answer)[:40]):
                self.assertEqual(self.probe(answer), ['self_check_failed'])

    def test_the_probe_container_is_confined_like_a_sandbox(self):
        self.probe(['blocked'] * 5)
        argv = next(c for c in self.docker.calls if c[1] == 'run')
        joined = ' '.join(argv)
        for needed in ('--rm', '--cap-drop ALL', '--network neko-runner', '--user 10001:10001',
                       '--add-host host.docker.internal:host-gateway'):
            self.assertIn(needed, joined)
        for never in ('-v', '--volume', '--mount', '--privileged'):
            self.assertNotIn(never, argv)
        hosts = [t[0] for t in self.targets()]
        self.assertEqual(hosts[:3], ['host.docker.internal', '172.18.0.1', '172.18.0.1'])
        self.assertIn('169.254.169.254', hosts)


class ProbeScriptTests(unittest.TestCase):
    """The script that runs inside the probe container, run here with this Python against local addresses."""

    def answers(self, targets, timeout='0.5'):
        out = subprocess.run([sys.executable, '-I', '-c', rd.PROBE, json.dumps(targets), timeout],
                             capture_output=True, text=True, timeout=30, check=True)
        return json.loads(out.stdout)

    def test_listening_closed_and_silent(self):
        listening = socket.socket(); listening.bind(('127.0.0.1', 0)); listening.listen(1)
        closed = socket.socket(); closed.bind(('127.0.0.1', 0)); closed_port = closed.getsockname()[1]; closed.close()
        try:
            got = self.answers([['127.0.0.1', listening.getsockname()[1]], ['127.0.0.1', closed_port],
                                ['192.0.2.1', 80], ['no-such-host.invalid', 80]])
        finally:
            listening.close()
        self.assertEqual(got, ['connected', 'refused', 'blocked', 'blocked'])


class ServiceTests(RunnerBase):
    """The whole run through RunService, with DockerRunner as the provider."""

    def setUp(self):
        super().setUp()
        self.docker = FakeDocker()
        self.fake = rd.DockerRunner('neko-runner:v1', run=self.docker)
        self.service = rn.RunService(self.store, self.fake)

    def test_only_listed_files_go_in_owned_by_the_sandbox_user(self):
        run = self.start()
        self.assertEqual(run['state'], 'ready')
        index = self.docker.commands().index('cp')
        self.assertEqual(self.docker.calls[index][1:], ['cp', '--archive', '-', f"{run['sandbox_id']}:/"])
        data = self.docker.inputs[index]  # exactly what docker received
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            members = tar.getmembers()
            files = sorted(m.name for m in members if m.isfile())
            self.assertEqual(files, ['work/README.md', 'work/src/app.py'])
            self.assertTrue(all(m.uid == rd.UID and m.gid == rd.UID for m in members))
            self.assertFalse(any(m.issym() or m.islnk() for m in members))
        self.assertNotIn(CANARY.encode(), data)

    def test_no_host_path_ever_reaches_docker(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make', 'test'])
        self.assertEqual(run['state'], 'collected')
        for argv in self.docker.calls:
            self.assertFalse(any(str(self.root) in a for a in argv), argv)

    def test_happy_path_publishes_once_on_the_task_branch(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.service.verify(run['run_id'])
        repo, target = self.repo()
        self.assertEqual(self.service.publish(run['run_id'], self.lease, target)['state'], 'published')
        self.assertEqual(self.service.run(run['run_id'])['cleanup'], 'done')
        self.assertEqual(self.docker.commands()[-1], 'rm')
        self.assertEqual(git(repo, 'rev-list', '--count', 'neko/t1').strip(), '2')
        self.assertEqual((repo / 'README.md').read_text(), 'new\n')

    def test_failing_command_is_collected_then_removed_not_published(self):
        self.docker.exit_code = 1
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.assertEqual((run['state'], run['detail'], run['cleanup']), ('failed', 'nonzero_exit', 'done'))
        self.assertIsNotNone(run['log_hash'])

    def test_restart_finds_a_container_whose_create_answer_was_lost(self):
        self.docker.answers['create'] = subprocess.TimeoutExpired('docker', 60)
        run = self.start()
        self.assertEqual(run['state'], 'create_unknown')
        name = rd.DockerRunner.container(run['run_id'])
        self.docker.answers['ps'] = FakeDocker.done(f'{name}\n'.encode())
        moved = rn.RunService(self.store, self.fake).recover()
        self.assertEqual(moved[run['run_id']], 'interrupted')
        self.assertEqual(self.docker.calls[-1][1:], ['rm', '-f', name])


if __name__ == '__main__':
    unittest.main()
