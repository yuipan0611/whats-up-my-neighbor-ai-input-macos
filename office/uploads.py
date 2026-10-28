"""General file and ZIP uploads for hands tasks (施工單 2026-10-28 第五節; H5/H7 later build on it).

Sits next to the existing inbox APIs and changes none of them: 48KB text and 8MB PDF/image uploads
keep their formats, limits and attachment handling. This adds:
- versioned files: the same name gives a new version, the old one is kept; contents are stored once
  by SHA-256 and never rewritten;
- ZIP archives checked before anything is extracted: paths, symlinks, entry count, total size and
  compression ratio;
- task inputs that name a fixed version and hash, extracted read-only apart from the writable output
  folder, with sign-ins, keys, browser profiles and office databases left out and listed.
Not wired to an HTTP route or the web UI yet: those changes go through a preview first.
Python standard library only."""
from __future__ import annotations
import hashlib
import io
import json
import os
import stat
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

import runner

MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_ZIP_BYTES = 24 * 1024 * 1024        # the request cap the office already uses for attachments
MAX_ZIP_ENTRIES = 2000
MAX_UNPACKED_BYTES = 100 * 1024 * 1024
MAX_RATIO = 100                          # per entry: more than this many bytes out per byte in is refused
SCHEMA = '''
CREATE TABLE IF NOT EXISTS upload_versions (upload_id TEXT NOT NULL, version INTEGER NOT NULL, name TEXT NOT NULL,
    kind TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, entries TEXT NOT NULL DEFAULT '[]',
    excluded TEXT NOT NULL DEFAULT '[]', created TEXT NOT NULL, PRIMARY KEY (upload_id, version));
CREATE UNIQUE INDEX IF NOT EXISTS upload_name_version ON upload_versions(name, version);
'''


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


class UploadRefused(Exception):
    def __init__(self, reason, message, status=400):
        super().__init__(message)
        self.reason, self.status = reason, status


def check_name(name):
    """A plain relative path such as `src/app.py`; the same rules as what may go into a sandbox."""
    if not runner.safe_relative(name) or any(ord(ch) < 32 for ch in name) or name.endswith('/'):
        raise UploadRefused('unsafe_name', f'檔名或路徑不安全：{name!r}')
    return name


def zip_entries(data):
    """Read the central directory and check every entry before a single byte is extracted.
    Returns (entries, excluded): files to keep, and files left out on purpose (with the reason)."""
    if len(data) > MAX_ZIP_BYTES:
        raise UploadRefused('zip_too_large', 'ZIP 上限為 24MB。', 413)
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        raise UploadRefused('not_zip', '不是可讀的 ZIP 檔。')
    infos = archive.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        raise UploadRefused('too_many_entries', f'ZIP 最多 {MAX_ZIP_ENTRIES} 個項目。')
    seen, entries, excluded, total = set(), [], [], 0
    for info in infos:
        name = info.filename
        if info.flag_bits & 0x1:
            raise UploadRefused('encrypted', '不接受加密的 ZIP。')
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise UploadRefused('symlink', f'ZIP 裡有符號連結：{name}')
        if name.endswith('/'):
            continue  # directories are implied by the files in them
        if stat.S_IFMT(mode) and not stat.S_ISREG(mode):  # no file type at all is how most tools write regular files
            raise UploadRefused('special_file', f'ZIP 裡有特殊檔案：{name}')
        if not runner.safe_relative(name) or any(ord(ch) < 32 for ch in name):
            raise UploadRefused('unsafe_path', f'ZIP 裡的路徑不安全：{name!r}')
        folded = name.casefold()
        if folded in seen:  # also catches A.txt / a.txt, which collide on macOS and Windows
            raise UploadRefused('duplicate', f'ZIP 裡有重複的路徑：{name}')
        seen.add(folded)
        if info.file_size > MAX_FILE_BYTES:
            raise UploadRefused('entry_too_large', f'ZIP 裡的檔案太大：{name}', 413)
        if info.file_size > max(info.compress_size, 1) * MAX_RATIO:
            raise UploadRefused('ratio', f'ZIP 裡的檔案壓縮比異常：{name}', 413)
        total += info.file_size
        if total > MAX_UNPACKED_BYTES:
            raise UploadRefused('unpacked_too_large', '解壓後總量超過 100MB。', 413)
        if runner.excluded(name):
            excluded.append({'path': name, 'reason': 'excluded_path'})
            continue
        entries.append(info)
    if not entries:
        raise UploadRefused('empty_zip', 'ZIP 裡沒有可以使用的檔案。')
    return archive, entries, excluded


class Uploads:
    def __init__(self, store):
        self.store = store
        self.blobs = store.root / 'uploads' / 'blobs'
        for path in (store.root / 'uploads', self.blobs):
            if path.is_symlink():
                raise UploadRefused('symlink', '上傳資料夾不可為符號連結。')
            path.mkdir(mode=0o700, exist_ok=True)
        with store.connect() as c:
            c.executescript(SCHEMA)

    def _blob(self, data):
        digest = hashlib.sha256(data).hexdigest()
        path = self.blobs / digest
        if not path.exists():
            temp = self.blobs / f'.{digest}.{uuid.uuid4().hex}.tmp'
            with temp.open('xb') as f:
                f.write(data); f.flush(); os.fsync(f.fileno())
            temp.chmod(0o400)
            os.replace(temp, path)
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise UploadRefused('blob_corrupt', '已保存的檔案內容和雜湊不符，先不要使用。', 500)
        return digest

    def _record(self, name, kind, data, entries=(), excluded=()):
        digest = self._blob(data)
        with self.store.lock:
            with self.store.connect() as c:
                row = c.execute('SELECT upload_id,MAX(version) AS v,sha256 FROM upload_versions WHERE name=?', (name,)).fetchone()
                if row['upload_id']:
                    last = c.execute('SELECT * FROM upload_versions WHERE upload_id=? AND version=?',
                                     (row['upload_id'], row['v'])).fetchone()
                    if last['sha256'] == digest and last['kind'] == kind:
                        return dict(last), False  # the same content again: no new version
                    upload_id, version = row['upload_id'], row['v'] + 1
                else:
                    upload_id, version = str(uuid.uuid4()), 1
                c.execute('INSERT INTO upload_versions VALUES (?,?,?,?,?,?,?,?,?)',
                          (upload_id, version, name, kind, digest, len(data), json.dumps(list(entries)),
                           json.dumps(list(excluded)), now()))
                return dict(c.execute('SELECT * FROM upload_versions WHERE upload_id=? AND version=?',
                                      (upload_id, version)).fetchone()), True

    def add_file(self, name, data):
        check_name(name)
        if runner.excluded(name):
            raise UploadRefused('excluded_path', f'這類檔案不收（登入資料、金鑰、瀏覽器資料或資料庫）：{name}')
        if not isinstance(data, bytes) or not data:
            raise UploadRefused('empty', '檔案不可為空。')
        if len(data) > MAX_FILE_BYTES:
            raise UploadRefused('too_large', '單一檔案上限為 16MB。', 413)
        row, new = self._record(name, 'file', data)
        return self.view(row, new)

    def add_zip(self, name, data):
        check_name(name)
        if not name.lower().endswith('.zip'):
            raise UploadRefused('not_zip', 'ZIP 檔名要以 .zip 結尾。')
        archive, entries, excluded = zip_entries(data)
        listing = [{'path': i.filename, 'bytes': i.file_size, 'crc': i.CRC} for i in entries]
        row, new = self._record(name, 'zip', data, listing, excluded)
        return self.view(row, new)

    @staticmethod
    def view(row, new=True):
        return {'upload_id': row['upload_id'], 'version': row['version'], 'name': row['name'], 'kind': row['kind'],
                'sha256': row['sha256'], 'bytes': row['bytes'], 'new_version': new,
                'files': len(json.loads(row['entries'])) if row['kind'] == 'zip' else 1,
                'excluded': json.loads(row['excluded'])}

    def versions(self, upload_id):
        with self.store.connect() as c:
            return [self.view(r) for r in c.execute('SELECT * FROM upload_versions WHERE upload_id=? ORDER BY version', (upload_id,))]

    def resolve(self, ref):
        """A task names {upload_id, version, sha256}; anything else, or a hash that does not match, is refused."""
        if not isinstance(ref, dict) or set(ref) != {'upload_id', 'version', 'sha256'}:
            raise UploadRefused('bad_ref', '任務要指定 upload_id、version 與 sha256。')
        with self.store.connect() as c:
            row = c.execute('SELECT * FROM upload_versions WHERE upload_id=? AND version=?',
                            (ref['upload_id'], ref['version'])).fetchone()
        if row is None:
            raise UploadRefused('unknown_upload', '找不到這個檔案版本。', 404)
        if row['sha256'] != ref['sha256']:
            raise UploadRefused('hash_mismatch', '檔案版本和雜湊對不上。', 409)
        data = (self.blobs / row['sha256']).read_bytes()
        if hashlib.sha256(data).hexdigest() != row['sha256']:
            raise UploadRefused('blob_corrupt', '已保存的檔案內容和雜湊不符，先不要使用。', 500)
        return dict(row), data

    def prepare_task(self, task_id, refs):
        """Lay out the task's inputs: tasks/<id>/inputs (read only) and tasks/<id>/outputs (writable).
        Calling it again with the same refs changes nothing; with other refs it is refused, so a
        running task never sees its inputs change under it."""
        if str(uuid.UUID(task_id)) != task_id:
            raise UploadRefused('bad_task', '任務編號格式不正確。')
        if not isinstance(refs, list) or not 1 <= len(refs) <= 20:
            raise UploadRefused('bad_ref', '一件任務一次指定 1 到 20 個檔案版本。')
        base = self.store.root / 'tasks' / task_id
        inputs, outputs = base / 'inputs', base / 'outputs'
        for path in (base, inputs, outputs):
            if path.is_symlink():
                raise UploadRefused('symlink', '任務資料夾不可為符號連結。')
        stamp = hashlib.sha256(json.dumps(sorted((r.get('upload_id'), r.get('version'), r.get('sha256')) for r in refs
                                                 if isinstance(r, dict))).encode()).hexdigest()
        manifest_path = base / 'inputs.json'
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text())
            if manifest['stamp'] != stamp:
                raise UploadRefused('inputs_fixed', '這件任務的輸入已經固定，不能換成別的版本。', 409)
            return manifest
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        staging = base / f'.inputs-{uuid.uuid4().hex}'
        staging.mkdir(mode=0o700)
        files, excluded, used = [], [], set()
        try:
            for ref in refs:
                row, data = self.resolve(ref)
                folder = f"{row['upload_id']}-v{row['version']}"
                if row['kind'] == 'file':
                    items = [(row['name'], data)]
                else:
                    archive, entries, left_out = zip_entries(data)
                    excluded += [{**e, 'upload': folder} for e in left_out]
                    items = []
                    for info in entries:
                        blob = archive.read(info)
                        if len(blob) != info.file_size:
                            raise UploadRefused('zip_changed', 'ZIP 內容和目錄不符。')
                        items.append((info.filename, blob))
                for rel, blob in items:
                    target = PurePosixPath(folder) / rel
                    if str(target).casefold() in used:
                        raise UploadRefused('duplicate', f'輸入路徑重複：{target}')
                    used.add(str(target).casefold())
                    path = staging.joinpath(*target.parts)
                    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    with path.open('xb') as f:
                        f.write(blob)
                    path.chmod(0o400)
                    files.append({'path': str(target), 'sha256': hashlib.sha256(blob).hexdigest(), 'bytes': len(blob)})
            for directory, _, _ in os.walk(staging, topdown=False):
                Path(directory).chmod(0o500)
            if inputs.exists():  # left over from an attempt that died before writing the manifest
                raise UploadRefused('inputs_unclear', '這件任務有沒寫完的輸入資料夾，先人工確認。', 409)
            os.replace(staging, inputs)
        except Exception:
            _remove_tree(staging)
            raise
        outputs.mkdir(mode=0o700, exist_ok=True)
        manifest = {'stamp': stamp, 'refs': refs, 'files': files, 'excluded': excluded, 'created': now()}
        temp = base / 'inputs.json.tmp'
        temp.write_text(json.dumps(manifest, ensure_ascii=False))
        os.replace(temp, manifest_path)
        return manifest


def _remove_tree(path):
    if not path.exists():
        return
    for directory, dirs, names in os.walk(path, topdown=False):
        os.chmod(directory, 0o700)
        for name in names:
            os.unlink(os.path.join(directory, name))
        for name in dirs:
            os.rmdir(os.path.join(directory, name))
    os.rmdir(path)
