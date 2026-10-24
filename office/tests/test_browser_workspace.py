"""Profile boundary tests; no Playwright, Chrome, accounts, or network needed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

OFFICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OFFICE))
from browser_workspace import BrowserWorkspaceError
from browser_workspace.profiles import ProfileLease


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'profiles'

    def lease(self, profile='research'):
        lease = ProfileLease(self.root, profile)
        self.addCleanup(lease.release)
        return lease

    def test_profile_is_private_persistent_and_separate_from_other_profile(self):
        first = self.lease()
        path = first.acquire()
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        (path / 'synthetic-state').write_text('no real credentials')
        first.release()
        self.assertEqual((self.lease().acquire() / 'synthetic-state').read_text(),
                         'no real credentials')
        other = self.lease('another-account').acquire()
        self.assertFalse((other / 'synthetic-state').exists())

    def test_competing_process_cannot_acquire_until_owner_releases(self):
        first = self.lease()
        first.acquire()
        code = '''
import sys
sys.path.insert(0, sys.argv[1])
from browser_workspace.profiles import ProfileLease
from browser_workspace import BrowserWorkspaceError
lease = ProfileLease(sys.argv[2], 'research')
try:
    lease.acquire()
except BrowserWorkspaceError as error:
    print(error.code)
else:
    print('acquired')
finally:
    lease.release()
'''
        def attempt():
            return subprocess.run([sys.executable, '-I', '-c', code, str(OFFICE),
                                   str(self.root)], capture_output=True, text=True,
                                  check=True, timeout=10).stdout.strip()
        self.assertEqual(attempt(), 'profile_in_use')
        with self.assertRaises(BrowserWorkspaceError):
            first.acquire()
        self.assertEqual(attempt(), 'profile_in_use')
        first.release()
        self.assertEqual(attempt(), 'acquired')

    def test_process_exit_releases_lock_without_deleting_profile(self):
        code = '''
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from browser_workspace.profiles import ProfileLease
lease = ProfileLease(sys.argv[2], 'research')
(lease.acquire() / 'marker').write_text('synthetic')
os._exit(0)
'''
        subprocess.run([sys.executable, '-I', '-c', code, str(OFFICE), str(self.root)],
                       check=True, timeout=10)
        self.assertEqual((self.lease().acquire() / 'marker').read_text(), 'synthetic')

    def test_rejects_traversal_absolute_ids_and_nonidentifiers(self):
        for value in ('', '..', '../private', '/tmp/x', 'a/b', 'a\\b', 'UPPER',
                      'a' * 49, 'space here', 'nul\x00', None):
            with self.subTest(value=value), self.assertRaises(BrowserWorkspaceError):
                ProfileLease(self.root, value)
        for root in ('relative', '/', str(self.base / '..' / 'outside')):
            with self.subTest(root=root), self.assertRaises(BrowserWorkspaceError):
                ProfileLease(root, 'research')

    def test_rejects_existing_nonprivate_or_unrelated_root(self):
        self.root.mkdir(mode=0o755)
        with self.assertRaises(BrowserWorkspaceError):
            self.lease().acquire()
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.root.chmod(0o700)
        (self.root / 'Cookies').write_text('do not adopt unrelated data')
        with self.assertRaises(BrowserWorkspaceError):
            self.lease().acquire()

    def test_rejects_root_and_profile_symlinks(self):
        target = self.base / 'target'
        target.mkdir(mode=0o700)
        self.root.symlink_to(target, target_is_directory=True)
        with self.assertRaises(BrowserWorkspaceError):
            self.lease().acquire()
        self.root.unlink()
        first = self.lease()
        first.acquire()
        first.release()
        (self.root / 'another-account').symlink_to(target, target_is_directory=True)
        with self.assertRaises(BrowserWorkspaceError):
            self.lease('another-account').acquire()
        self.assertEqual(list(target.iterdir()), [])

    def test_rejects_lock_hardlink_and_git_worktree(self):
        first = self.lease()
        first.acquire()
        first.release()
        os.link(self.root / '.research.lock', self.base / 'duplicate-lock')
        with self.assertRaises(BrowserWorkspaceError):
            self.lease().acquire()
        repo = self.base / 'repo'
        repo.mkdir(mode=0o700)
        (repo / '.git').write_text('gitdir: another-worktree')
        with self.assertRaises(BrowserWorkspaceError):
            ProfileLease(repo / 'profiles', 'research')


class InterfaceTests(unittest.TestCase):
    def test_contract_import_does_not_load_optional_sdk(self):
        code = '''
import sys
sys.path.insert(0, sys.argv[1])
from browser_workspace import BrowserSessionProvider, PlaywrightChromeProvider
assert not any(k == 'playwright' or k.startswith('playwright.') for k in sys.modules)
print('optional-sdk-not-loaded')
'''
        result = subprocess.run([sys.executable, '-I', '-c', code, str(OFFICE)],
                                check=True, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.stdout.strip(), 'optional-sdk-not-loaded')

if __name__ == '__main__':
    unittest.main()
