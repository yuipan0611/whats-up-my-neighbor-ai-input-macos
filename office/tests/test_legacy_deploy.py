"""Exercise the legacy deploy's actual source stream without any remote connection."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class LegacyDeployTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo, self.stage = self.root / 'source', self.root / 'staged'
        self.repo.mkdir(); self.stage.mkdir()
        source = Path(__file__).resolve().parents[2]
        files = subprocess.check_output(['git', '-C', str(source), 'ls-files', '--', 'office'], text=True).splitlines()
        for name in files:
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, target)
        self.git('init', '--quiet', '--template=')
        self.git('add', 'office')
        self.git('-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'source fixture')
        tools = self.root / 'tools'
        tools.mkdir()
        ssh = tools / 'ssh'
        ssh.write_text('''#!/usr/bin/env python3
import os, sys, tarfile
from pathlib import Path
stage = Path(os.environ['OFFICE_DEPLOY_TEST_STAGE'])
command = sys.argv[-1]
if command.startswith('if grep '):
    print('legacy')
elif command.startswith('tar '):
    with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as archive:
        archive.extractall(stage, filter='data')
elif command.startswith('python3 -I -m unittest '):
    (stage / 'restart-requested').touch()
''')
        ssh.chmod(0o755)
        scp = tools / 'scp'
        scp.write_text('#!/bin/sh\nexit 91\n')
        scp.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                    'OFFICE_DEPLOY_TEST_STAGE': str(self.stage)}

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.repo), '-c', 'core.hooksPath=/dev/null', *args],
                       check=True, capture_output=True)

    def deploy(self):
        return subprocess.run(['sh', str(self.repo / 'office/deploy.sh')], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_committed_bundle_starts_and_includes_test_helpers_without_account_data(self):
        private = self.repo / 'office/data/auth.json'
        private.parent.mkdir(); private.write_text('fictional untracked account data')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.stage / 'restart-requested').is_file())
        self.assertFalse((self.stage / 'data/auth.json').exists())
        help_result = subprocess.run([sys.executable, '-I', str(self.stage / 'office.py'), '--help'], capture_output=True)
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        tests = subprocess.run([sys.executable, '-I', '-m', 'unittest', 'discover', '-s', str(self.stage / 'tests'),
                                '-p', 'test_workbench_deploy.py'], capture_output=True, timeout=30)
        self.assertEqual(tests.returncode, 0, tests.stderr)

    def test_dirty_source_refuses_to_deploy_an_older_committed_version(self):
        with (self.repo / 'office/office.py').open('a') as source:
            source.write('\n# uncommitted change\n')
        result = self.deploy()
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.stage / 'office.py').exists())
        self.assertFalse((self.stage / 'restart-requested').exists())
