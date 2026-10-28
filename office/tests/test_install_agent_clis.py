"""The pinned Claude Code / Gemini CLI installer (ADR-003 P2): checksum first, safe unpack, logins untouched."""
import importlib.util
import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('install_agent_clis', Path(__file__).parents[1] / 'install_agent_clis.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def tarball(files):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, body in files.items():
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(body), 0o755
            archive.addfile(info, io.BytesIO(body))
    return buffer.getvalue()


CLAUDE = tarball({'package/claude': b'#!/bin/sh\necho "2.1.183 (Claude Code)"\n', 'package/package.json': b'{}'})
GEMINI = tarball({'package/bundle/gemini.js': b'console.log("0.47.0")\n', 'package/package.json': b'{}'})


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name) / 'runtime'
        self.runtime.mkdir()

    def pinned(self, name, data):
        return mock.patch.dict(installer.PACKAGES, {name: {**installer.PACKAGES[name], 'integrity': installer.integrity(data)}})

    def test_mismatched_download_installs_nothing(self):
        with self.assertRaises(SystemExit) as e:
            installer.install('claude', self.runtime, download=lambda url: CLAUDE)  # real pin, fake bytes
        self.assertIn('SHA-512 mismatch', str(e.exception))
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_claude_binary_installed_and_logins_kept_on_reinstall(self):
        home = self.runtime / 'claude-home'
        home.mkdir()
        (home / '.credentials.json').write_text('owner login')
        with self.pinned('claude', CLAUDE):
            installer.install('claude', self.runtime, download=lambda url: CLAUDE)
            root = installer.install('claude', self.runtime, download=lambda url: CLAUDE)
        self.assertTrue((root / 'claude').is_file())
        self.assertEqual((root / 'claude').stat().st_mode & 0o777, 0o700)
        self.assertEqual((root / 'VERSION').read_text(), '2.1.183\n')
        self.assertEqual(installer.check_version('claude', root), '2.1.183 (Claude Code)')
        self.assertEqual((home / '.credentials.json').read_text(), 'owner login')
        self.assertEqual(sorted(p.name for p in self.runtime.iterdir()), ['claude', 'claude-home'])

    @unittest.skipUnless(shutil.which('node'), 'needs Node.js, as Gemini CLI does')
    def test_gemini_gets_a_launcher_for_the_bundled_script(self):
        with self.pinned('gemini', GEMINI):
            root = installer.install('gemini', self.runtime, download=lambda url: GEMINI)
        self.assertEqual(installer.check_version('gemini', root), '0.47.0')

    def test_unsafe_or_unexpected_archives_are_refused(self):
        for files in ({'package/../../evil': b'x'}, {'/abs/claude': b'x'}, {'other/claude': b'x'}, {'package/README.md': b'x'}):
            with self.subTest(list(files)[0]):
                data = tarball(files)
                with self.pinned('claude', data), self.assertRaises(SystemExit):
                    installer.install('claude', self.runtime, download=lambda url: data)
                self.assertFalse((self.runtime / 'claude').exists())
                self.assertFalse((Path(self.temp.name) / 'evil').exists())


if __name__ == '__main__':
    unittest.main()
