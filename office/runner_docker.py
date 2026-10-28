"""Local Docker as a runner.Runner provider (tasks/H3-runner-docker-v1.md).

YUI's two red lines decide what is fixed here; everything else is loosened:
- files: the container gets copies only. No host folder is mounted, no Docker socket, no --privileged,
  no host network; the result leaves only as a patch, which runner.RunService publishes to a neko/* branch.
- card charges: no credential reaches the container. Its environment is HOME, PATH, LANG and CI only;
  the inputs already passed runner.select_inputs, which leaves out keys and sign-ins.
Network at run time is allowed (outbound). Blocking the way back to the host, private ranges and
cloud metadata is the host firewall's job on the named network; it is set up outside this module.

The image has to provide: git, coreutils `timeout`, `sleep`, `sh`, a user 10001 and a /work folder.
Any docker failure maps to RunnerUnknown, RunnerGone or RunnerFailed; nothing ever falls back to the host.
Python standard library only."""
from __future__ import annotations
import io
import subprocess
import tarfile
import time
from pathlib import Path

import runner

UID = 10001
WORKDIR = '/work'
LOG = '/tmp/neko-run.log'
ENV = {'HOME': '/tmp', 'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'CI': '1'}
TIMED_OUT = 124  # coreutils timeout: the command ran out of time
GONE = ('no such container', 'no such object', 'is not running', 'is paused')


class DockerRunner(runner.Runner):
    name = 'docker'

    def __init__(self, image, network='neko-runner', docker='docker', memory='2g', cpus='2', pids=512, run=subprocess.run):
        if network in ('host', 'none', 'bridge', 'default') or not network:
            raise ValueError('use a dedicated network whose way back to the host is firewalled')
        self.image, self.network, self.docker = image, network, docker
        self.memory, self.cpus, self.pids = memory, cpus, pids
        self.run = run  # replaced in tests: nothing here needs a Docker daemon to be checked

    # -- calling docker --------------------------------------------------------------------

    def call(self, *args, data=None, timeout=60, gone_ok=False):
        try:
            out = self.run([self.docker, *args], input=data, capture_output=True, timeout=timeout)
        except FileNotFoundError:
            raise runner.RunnerFailed('docker is not installed')
        except subprocess.TimeoutExpired:
            raise runner.RunnerUnknown(f'docker {args[0]} timed out')  # it may have taken effect
        if out.returncode == 0:
            return out
        err = out.stderr.decode('utf-8', 'replace').lower()
        if any(m in err for m in GONE):
            if gone_ok:
                return out
            raise runner.RunnerGone(err[:200])
        raise runner.RunnerFailed(err[:200] or f'docker {args[0]} failed')

    @staticmethod
    def container(run_id):
        return f'neko-run-{run_id}'

    def create_args(self, run_id):
        """Every flag the container starts with. Nothing here mounts, shares or grants from the host."""
        args = ['create', '--name', self.container(run_id), '--label', f'neko_run={run_id}',
                '--user', f'{UID}:{UID}', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                '--pids-limit', str(self.pids), '--memory', self.memory, '--cpus', self.cpus,
                '--network', self.network, '--workdir', WORKDIR]
        for key, value in ENV.items():
            args += ['--env', f'{key}={value}']
        return args + [self.image, 'sleep', 'infinity']

    # -- runner.Runner ---------------------------------------------------------------------

    def create(self, run_id, labels):
        # The name is fixed by run_id: a create repeated after a lost answer conflicts instead of making a second one.
        self.call(*self.create_args(run_id))
        name = self.container(run_id)
        try:
            self.call('start', name)
        except runner.RunnerError:
            try:
                self.call('rm', '-f', name, gone_ok=True)
            except runner.RunnerError:
                raise runner.RunnerUnknown('container created but neither started nor removed')  # find() picks it up
            raise runner.RunnerFailed('container did not start')
        return name

    def find(self, run_id):
        out = self.call('ps', '-a', '--filter', f'label=neko_run={run_id}', '--format', '{{.Names}}')
        names = out.stdout.decode().split()
        return names[0] if names else None

    @staticmethod
    def archive(root, manifest):
        """The manifest's files as a tar under work/, owned by the sandbox user. Only listed files go in."""
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as tar:
            folders = {'work'}
            for entry in manifest:
                parts = entry['path'].split('/')
                folders.update('/'.join(['work', *parts[:i]]) for i in range(1, len(parts)))
            for folder in sorted(folders):
                info = tarfile.TarInfo(folder)
                info.type, info.mode, info.uid, info.gid, info.mtime = tarfile.DIRTYPE, 0o755, UID, UID, 0
                tar.addfile(info)
            for entry in manifest:
                data = (Path(root) / entry['path']).read_bytes()
                info = tarfile.TarInfo(f"work/{entry['path']}")
                info.size, info.mode, info.uid, info.gid, info.mtime = len(data), 0o644, UID, UID, 0
                tar.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def upload(self, sandbox_id, root, manifest):
        self.call('cp', '--archive', '-', f'{sandbox_id}:/', data=self.archive(root, manifest), timeout=120)
        # A baseline commit inside the container, so collect() can return exactly what the run changed.
        self.call('exec', sandbox_id, 'sh', '-c', 'git init -q && git add -A && '
                  'git -c user.name=neko -c user.email=neko@invalid -c commit.gpgsign=false commit -q --allow-empty -m base')

    def execute(self, sandbox_id, command, seconds):
        if not isinstance(command, list) or not command or not all(isinstance(a, str) for a in command):
            raise runner.RunnerFailed('command must be a list of strings')
        started = time.monotonic()
        code = self.exec_command(sandbox_id, command, seconds)
        return {'exit_code': code, 'seconds': round(time.monotonic() - started, 3), 'timed_out': code == TIMED_OUT}

    def exec_command(self, sandbox_id, command, seconds):
        """The command's own exit code. A non-zero exit is the run's result, not a docker failure.
        The command is passed as arguments, never pasted into a shell string; its output goes to a file collect() reads."""
        args = ['exec', sandbox_id, 'sh', '-c', f'timeout -k 5 {int(seconds)} "$@" >{LOG} 2>&1', 'sh', *command]
        try:
            out = self.run([self.docker, *args], input=None, capture_output=True, timeout=seconds + 30)
        except FileNotFoundError:
            raise runner.RunnerFailed('docker is not installed')
        except subprocess.TimeoutExpired:
            raise runner.RunnerUnknown('docker exec did not return in time')
        err = out.stderr.decode('utf-8', 'replace').lower()
        if out.returncode != 0 and any(m in err for m in GONE):
            raise runner.RunnerGone(err[:200])
        if out.returncode in (125, 126, 127) and err:  # docker exec could not start the command at all
            raise runner.RunnerFailed(err[:200])
        return out.returncode

    def status(self, sandbox_id):
        out = self.call('inspect', '--format', '{{.State.Status}}', sandbox_id, gone_ok=True)
        if out.returncode != 0:
            return 'gone'
        state = out.stdout.decode().strip()
        return state if state in ('running', 'paused') else 'exited'

    def collect(self, sandbox_id, output_bytes):
        where = self.status(sandbox_id)
        if where == 'gone':
            raise runner.RunnerGone(sandbox_id)
        if where == 'paused':
            self.call('unpause', sandbox_id)
        elif where == 'exited':
            self.call('start', sandbox_id)
        log = self.call('exec', sandbox_id, 'sh', '-c', f'head -c {int(output_bytes)} {LOG} 2>/dev/null; true').stdout  # no log yet is not an error
        patch = self.call('exec', sandbox_id, 'sh', '-c', 'git add -A && git diff --cached --binary HEAD').stdout
        return {'log': log, 'patch': patch}

    def pause(self, sandbox_id):
        self.call('pause', sandbox_id)

    def destroy(self, sandbox_id):
        self.call('rm', '-f', sandbox_id, gone_ok=True)
