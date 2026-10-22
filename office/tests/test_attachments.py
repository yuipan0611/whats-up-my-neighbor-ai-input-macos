import base64
from pathlib import Path
import tempfile
import unittest
import uuid

from test_office import app, FakeModel
from test_mobile import Base


def encoded(data):
    return base64.b64encode(data).decode()


JPEG = b'\xff\xd8\xff\xe0synthetic-page\xff\xd9'
PNG = b'\x89PNG\r\n\x1a\nsynthetic-image'


class AttachmentStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = app.Store(Path(self.temp.name) / 'data')

    def tearDown(self):
        self.temp.cleanup()

    def test_image_and_pdf_are_frozen_for_codex(self):
        self.store.upload_attachment('scene.png', encoded(PNG))
        image = self.store.submit(str(uuid.uuid4()), '描述圖片', 'scene.png', 'Codex', 'codex')
        self.assertEqual(self.store.media_images(image)[0].read_bytes(), PNG)
        (self.store.root / 'inbox/scene.png').write_bytes(PNG + b'changed')
        self.assertEqual(self.store.media_images(image)[0].read_bytes(), PNG)
        self.store.upload_attachment('notes.pdf', encoded(b'%PDF-1.4 synthetic'), [encoded(JPEG), encoded(JPEG)])
        pdf = self.store.submit(str(uuid.uuid4()), '整理 PDF', 'notes.pdf', 'Codex', 'codex')
        self.assertEqual([p.name for p in self.store.media_images(pdf)], ['page-01.jpg', 'page-02.jpg'])
        with self.assertRaises(app.OfficeError):
            self.store.submit(str(uuid.uuid4()), '整理 PDF', 'notes.pdf', 'Gemma', 'gemma')

    def test_rejects_bad_types_paths_and_overwrite(self):
        for name, data in [('x.pdf', PNG), ('../x.png', PNG), ('x.html', PNG), ('x.jpg', PNG)]:
            with self.assertRaises(app.OfficeError):
                self.store.upload_attachment(name, encoded(data))
        with self.assertRaises(app.OfficeError):
            self.store.upload_attachment('x.pdf', encoded(b'%PDF-1.4'), [])
        self.store.upload_attachment('same.png', encoded(PNG))
        with self.assertRaises(app.OfficeError) as error:
            self.store.upload_attachment('same.png', encoded(PNG))
        self.assertEqual(error.exception.code, 409)
        self.assertEqual((self.store.root / 'inbox/same.png').read_bytes(), PNG)

    def test_codex_receives_pdf_pages_as_images(self):
        runtime = Path(self.temp.name) / 'runtime'
        agent = app.CodexAgent(runtime)
        agent.binary.parent.mkdir(parents=True, exist_ok=True)
        agent.binary.write_text('''#!/usr/bin/env python3
import json,pathlib,sys
if sys.argv[1:] == ['login','status']: sys.exit(0)
args = sys.argv
images = [args[i+1] for i,x in enumerate(args) if x == '--image']
assert len(images) == 2
assert all(pathlib.Path(p).read_bytes().startswith(b'\\xff\\xd8\\xff') for p in images)
assert 'PDF' in sys.stdin.read()
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps({'kind':'completed','content':'兩頁已讀','next_step':''}))
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':4}}))
''')
        agent.binary.chmod(0o700)
        (agent.binary.parent / 'codex-code-mode-host').write_text('test')
        self.store.upload_attachment('document.pdf', encoded(b'%PDF-1.4 synthetic'), [encoded(JPEG), encoded(JPEG)])
        task = self.store.submit(str(uuid.uuid4()), '讀取 PDF', 'document.pdf', agent.model, 'codex')
        task['image_paths'] = [str(path) for path in self.store.media_images(task)]
        result, _ = agent.run(task, lambda: None, lambda _: None)
        self.assertEqual(result['content'], '兩頁已讀')


class AttachmentHttpTests(Base):
    def test_upload_requires_token_and_keeps_media_private(self):
        payload = {'name': 'photo.png', 'data': encoded(PNG)}
        self.assertEqual(self.request('/api/attachments', payload, {'Content-Type': 'application/json'})[0], 403)
        token = self.request('/api/bootstrap')[1]['token']
        headers = {'Content-Type': 'application/json', 'X-Office-Token': token}
        status, body, _ = self.request('/api/attachments', payload, headers)
        self.assertEqual(status, 201, body)
        self.assertEqual(body['bytes'], len(PNG))
        self.assertEqual(self.request('/inbox/photo.png')[0], 404)


if __name__ == '__main__':
    unittest.main()
