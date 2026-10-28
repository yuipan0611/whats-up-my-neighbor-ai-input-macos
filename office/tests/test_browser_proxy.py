"""Office authentication boundary exercised through real HTTP/Unix sockets."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import socketserver
import sys
import subprocess
import threading
import time

sys.path.insert(0, str(Path(__file__).parents[1]))
from browser_proxy import BrowserProxy, BrowserProxyError
from test_mobile import Base, PUBLIC, WS


class UpstreamHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.observed.append(dict(self.headers))
        if self.path.startswith('/api/browser/ws'):
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            self.wfile.write(b'\x82\x05hello')
            if self.path.endswith('epoch=2'):
                self.wfile.write(b'\x88\x02\x03\xe8')
                self.wfile.flush()
                return
            self.wfile.flush()
            self.connection.settimeout(4)
            try:
                while self.rfile.read(1):
                    pass
            except OSError:
                pass
            return
        if self.path == '/browser/':
            data, mime = b'<!doctype html><title>Browser</title>', 'text/html'
        else:
            data, mime = json.dumps({'actor': self.headers['X-Neko-Device']}).encode(), 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.do_GET()


class UnixServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


class BrowserProxyTests(Base):
    def setUp(self):
        super().setUp()
        root = Path(self.temp.name) / 'browser'
        root.mkdir(mode=0o700)
        self.socket_path = root / 'gateway.sock'
        self.upstream = UnixServer(str(self.socket_path), UpstreamHandler)
        os.chmod(self.socket_path, 0o600)
        self.upstream.observed = []
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()
        self.server.browser = BrowserProxy(self.socket_path)
        self.server.browser_error = BrowserProxyError

    def tearDown(self):
        super().tearDown()
        self.upstream.shutdown()
        self.upstream.server_close()
        self.upstream_thread.join()

    def test_page_and_api_require_pairing_and_reject_forged_actor(self):
        for path in ('/browser/', '/browser/novnc.js', '/api/browser/state'):
            self.assertEqual(self.request(path, headers=self.public())[0], 401)
        self.assertEqual(self.upstream.observed, [])
        cookie, session = self.pair()
        headers = self.public(cookie=cookie)
        headers['X-Neko-Device'] = 'forged-owner'
        status, body, _ = self.request('/api/browser/state', headers=headers)
        self.assertEqual(status, 200)
        self.assertEqual(body['actor'], session['device']['id'])
        seen = self.upstream.observed[-1]
        self.assertNotIn('Cookie', seen)
        self.assertNotIn('X-Office-Token', seen)
        self.assertNotIn('Origin', seen)
        self.assertEqual(self.request('/browser/../private', headers=headers)[0], 404)

    def test_writes_preserve_origin_token_and_body_limits(self):
        cookie, session = self.pair()
        good = self.public(cookie=cookie, token=session['token'], json_body=True)
        for change in ({'Origin': 'https://attacker.example'}, {'X-Office-Token': 'bad'}):
            self.assertEqual(self.request('/api/browser/takeover', {}, {**good, **change})[0], 403)
        self.assertEqual(self.upstream.observed, [])
        self.assertEqual(self.request('/api/browser/takeover', {}, good)[0], 200)
        self.assertEqual(self.request('/api/browser/takeover', {'x': 'a' * 4096}, good)[0], 413)
        self.assertEqual(self.request('/api/browser/navigate', {}, good)[0], 404)

    def test_websocket_rechecks_revocation_without_using_task_socket_limit(self):
        cookie, session = self.pair()
        headers = self.public(cookie=cookie)
        no_origin = {k: v for k, v in headers.items() if k != 'Origin'}
        self.assertEqual(self.ws('/api/browser/ws?mode=view&epoch=1', no_origin).status, 403)
        self.assertEqual(self.ws('/api/browser/ws?mode=view&epoch=1&host=evil', headers).status, 400)
        first = self.ws('/api/browser/ws?mode=view&epoch=1', headers)
        self.assertEqual(first.status, 101)
        self.assertEqual(first.frame(), (2, b'hello'))
        second = self.ws('/api/browser/ws?mode=view&epoch=1', headers)
        self.assertEqual(second.status, 101)
        self.assertEqual(second.frame(), (2, b'hello'))
        self.assertEqual(len(self.server.sockets), 0)
        self.store.revoke_device(session['device']['id'])
        first.sock.settimeout(3)
        with self.assertRaises(ConnectionError):
            first.frame()
        second.sock.settimeout(3)
        with self.assertRaises(ConnectionError):
            second.frame()

    def test_disabled_missing_or_public_socket_fails_closed(self):
        self.server.browser = None
        self.assertEqual(self.request('/api/browser/state', headers=self.local)[1]['error'], 'browser_disabled')
        self.server.browser = BrowserProxy(self.socket_path)
        os.chmod(self.socket_path, 0o666)
        self.assertEqual(self.request('/api/browser/state', headers=self.local)[0], 503)
        self.assertEqual(self.upstream.observed, [])
        os.chmod(self.socket_path, 0o600)
        self.assertEqual(self.request('/api/browser/state', headers=self.local)[1]['actor'], 'local-owner')

    def test_upstream_eof_preserves_already_received_websocket_close_frame(self):
        stream = self.ws('/api/browser/ws?mode=view&epoch=2')
        self.assertEqual(stream.status, 101)
        self.assertEqual(stream.frame(), (2, b'hello'))
        self.assertEqual(stream.frame(), (8, b'\x03\xe8'))

    def test_production_isolated_python_can_load_only_the_optional_sibling_adapter(self):
        # -I intentionally excludes the script directory from import search.
        # Do not let the test suite's sys.path setup hide a production failure.
        code = '''import importlib.util, pathlib, sys, tempfile
path=pathlib.Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('isolated_office', path)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as root:
    office=module.Office(module.Store(pathlib.Path(root)/'data'), object())
    server=module.Server(0, office, browser_socket=pathlib.Path(root)/'gateway.sock')
    assert server.browser is not None
    server.server_close()
'''
        result = subprocess.run([sys.executable, '-I', '-c', code, str(Path(__file__).parents[1] / 'office.py')],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
