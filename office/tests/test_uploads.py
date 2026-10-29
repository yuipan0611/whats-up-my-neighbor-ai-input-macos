"""General file and ZIP uploads (施工單 2026-10-28 第五節). Backend only: no HTTP route or UI yet.
Fictional data only."""
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import uuid
import zipfile

from test_office import app

sys.path.insert(0, str(Path(__file__).parents[1]))
import uploads as up  # noqa: E402

CANARY = b'fictional-canary-secret-7731'


def make_zip(files, symlinks=(), compression=zipfile.ZIP_DEFLATED):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression) as z:
        for name, data in files.items():
            z.writestr(name, data)
        for name, target in symlinks:
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, target)
    return buffer.getvalue()


class UploadBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = app.Store(Path(self.temp.name) / 'data')
        self.uploads = up.Uploads(self.store)

    def tearDown(self):
        self.temp.cleanup()

    def refused(self, reason, call, *args):
        with self.assertRaises(up.UploadRefused) as e:
            call(*args)
        self.assertEqual(e.exception.reason, reason)


class FileTests(UploadBase):
    def test_same_name_keeps_every_version(self):
        first = self.uploads.add_file('src/app.py', b'print(1)\n')
        second = self.uploads.add_file('src/app.py', b'print(2)\n')
        again = self.uploads.add_file('src/app.py', b'print(2)\n')
        self.assertEqual((first['version'], second['version'], again['version']), (1, 2, 2))
        self.assertEqual(first['upload_id'], second['upload_id'])
        self.assertFalse(again['new_version'])
        old = self.uploads.resolve({k: first[k] for k in ('upload_id', 'version', 'sha256')})[1]
        self.assertEqual(old, b'print(1)\n')  # the first version is still there, unchanged

    def test_binary_and_source_files_are_accepted(self):
        self.assertEqual(self.uploads.add_file('assets/logo.bin', bytes(range(256)))['bytes'], 256)

    def test_unsafe_names_secrets_and_size(self):
        for name in ('../x', '/etc/passwd', 'a\\b', 'dir/', 'a\x00b', ''):
            self.refused('unsafe_name', self.uploads.add_file, name, b'x')
        for name in ('.env', 'config/.env.local', 'keys/id_ed25519', 'office.sqlite3', 'node_modules/a.js', 'x.pem'):
            self.refused('excluded_path', self.uploads.add_file, name, b'x')
        self.refused('empty', self.uploads.add_file, 'a.txt', b'')
        self.refused('too_large', self.uploads.add_file, 'a.txt', b'x' * (up.MAX_FILE_BYTES + 1))

    def test_reference_must_match_version_and_hash(self):
        row = self.uploads.add_file('a.txt', b'one')
        self.refused('hash_mismatch', self.uploads.resolve, {'upload_id': row['upload_id'], 'version': 1, 'sha256': '0' * 64})
        self.refused('unknown_upload', self.uploads.resolve, {'upload_id': row['upload_id'], 'version': 9, 'sha256': row['sha256']})
        self.refused('bad_ref', self.uploads.resolve, {'upload_id': row['upload_id']})

    def test_stored_blob_tampered_is_refused(self):
        row = self.uploads.add_file('a.txt', b'one')
        blob = self.uploads.blobs / row['sha256']
        blob.chmod(0o600); blob.write_bytes(b'two')
        self.refused('blob_corrupt', self.uploads.resolve, {k: row[k] for k in ('upload_id', 'version', 'sha256')})

    def test_existing_inbox_api_is_unchanged(self):
        self.assertEqual(self.store.upload('note.md', '# hi')['bytes'], 4)
        with self.assertRaises(app.OfficeError):
            self.store.upload('note.md', '# again')  # still no silent overwrite, still 409
        with self.assertRaises(app.OfficeError):
            self.store.upload('big.md', 'x' * 48001)  # still the 48KB limit


class ZipTests(UploadBase):
    def test_good_zip_lists_files_and_leaves_out_secrets(self):
        data = make_zip({'README.md': b'hi', 'src/a.py': b'x=1', '.env': b'TOKEN=' + CANARY,
                         'node_modules/p/index.js': b'', 'dir/': b''})
        row = self.uploads.add_zip('project.zip', data)
        self.assertEqual(row['files'], 2)
        self.assertEqual(sorted(e['path'] for e in row['excluded']), ['.env', 'node_modules/p/index.js'])

    def test_bad_archives_are_refused_before_extraction(self):
        cases = {
            'unsafe_path': make_zip({'../evil.txt': b'x'}),
            'symlink': make_zip({'a.txt': b'x'}, symlinks=[('link', '/etc/passwd')]),
            'duplicate': make_zip({'A.txt': b'x', 'a.txt': b'y'}),
            'ratio': make_zip({'bomb.txt': b'0' * (2 * 1024 * 1024)}),
            'empty_zip': make_zip({'.env': b'x'}),
            'not_zip': b'not a zip at all',
        }
        for reason, data in cases.items():
            with self.subTest(reason=reason):
                self.refused(reason, self.uploads.add_zip, 'p.zip', data)

    def test_special_file_inside_zip_is_refused(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as z:
            info = zipfile.ZipInfo('pipe')
            info.external_attr = (stat.S_IFIFO | 0o600) << 16
            z.writestr(info, b'')
            z.writestr('a.txt', b'x')
        self.refused('special_file', self.uploads.add_zip, 'p.zip', buffer.getvalue())

    def test_absolute_path_inside_zip_is_refused(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as z:
            z.writestr(zipfile.ZipInfo('a.txt'), b'x')
        raw = buffer.getvalue().replace(b'a.txt', b'/a.tx', 2)  # same length, so the archive stays readable
        self.refused('unsafe_path', self.uploads.add_zip, 'p.zip', raw)

    def test_entry_count_and_total_size(self):
        many = make_zip({f'f{i}.txt': b'' for i in range(up.MAX_ZIP_ENTRIES + 1)}, compression=zipfile.ZIP_STORED)
        self.refused('too_many_entries', self.uploads.add_zip, 'p.zip', many)
        original = up.MAX_UNPACKED_BYTES
        up.MAX_UNPACKED_BYTES = 10
        try:
            self.refused('unpacked_too_large', self.uploads.add_zip, 'p.zip', make_zip({'a.txt': b'x' * 11}, compression=zipfile.ZIP_STORED))
        finally:
            up.MAX_UNPACKED_BYTES = original
        self.refused('not_zip', self.uploads.add_zip, 'p.tar', make_zip({'a.txt': b'x'}))


class TaskInputTests(UploadBase):
    def ref(self, row):
        return {k: row[k] for k in ('upload_id', 'version', 'sha256')}

    def test_inputs_are_read_only_outputs_writable_and_secrets_absent(self):
        z = self.uploads.add_zip('p.zip', make_zip({'README.md': b'hi', '.env': b'TOKEN=' + CANARY, 'src/a.py': b'x=1'}))
        f = self.uploads.add_file('notes/brief.md', b'# brief')
        task = str(uuid.uuid4())
        manifest = self.uploads.prepare_task(task, [self.ref(z), self.ref(f)])
        base = self.store.root / 'tasks' / task
        paths = sorted(m['path'] for m in manifest['files'])
        self.assertEqual(len(paths), 3)
        self.assertEqual([e['path'] for e in manifest['excluded']], ['.env'])
        everything = b''.join(p.read_bytes() for p in (base / 'inputs').rglob('*') if p.is_file())
        self.assertNotIn(CANARY, everything)
        some = next((base / 'inputs').rglob('a.py'))
        self.assertEqual(stat.S_IMODE(some.stat().st_mode), 0o400)
        with self.assertRaises(PermissionError):
            (some.parent / 'new.txt').write_text('x')
        (base / 'outputs' / 'result.txt').write_text('ok')  # the writable side

    def test_same_refs_again_change_nothing_other_refs_are_refused(self):
        a = self.uploads.add_file('a.txt', b'one')
        b = self.uploads.add_file('a.txt', b'two')
        task = str(uuid.uuid4())
        first = self.uploads.prepare_task(task, [self.ref(a)])
        self.assertEqual(self.uploads.prepare_task(task, [self.ref(a)]), first)
        self.refused('inputs_fixed', self.uploads.prepare_task, task, [self.ref(b)])
        content = next((self.store.root / 'tasks' / task / 'inputs').rglob('a.txt')).read_bytes()
        self.assertEqual(content, b'one')  # the task keeps the version it was given

    def test_failed_preparation_leaves_nothing_half_written(self):
        a = self.uploads.add_file('a.txt', b'one')
        task = str(uuid.uuid4())
        self.refused('hash_mismatch', self.uploads.prepare_task, task, [self.ref(a), {**self.ref(a), 'sha256': '0' * 64}])
        base = self.store.root / 'tasks' / task
        self.assertEqual([p.name for p in base.iterdir()], [])
        self.assertEqual(self.uploads.prepare_task(task, [self.ref(a)])['files'][0]['bytes'], 3)


if __name__ == '__main__':
    unittest.main()
