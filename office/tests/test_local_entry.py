"""Local mode only through the private Unix socket (agent-hands PRD 5.8).

Any process on the VPS can reach 127.0.0.1, so a local Host header on loopback TCP
must not unlock the token, tasks or life journal."""
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from test_office import app, FakeModel, LOCAL_HOST, local_request
from test_mobile import WS

PUBLIC_HOST = 'office.test.example'
OFFICE_PY = Path(__file__).parents[1] / 'office.py'


def stale_socket(path):
    """A socket file left behind by a process that died without cleaning up."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.bind(str(path))


class LocalEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.office = app.Office(app.Store(self.root / 'data'), FakeModel())
        self.socket_path = self.root / 'run' / 'office.sock'
        self.servers = []

    def tearDown(self):
        for server, thread in self.servers:
            server.shutdown(); server.server_close(); thread.join()
        self.temp.cleanup()

    def start(self, **options):
        server = app.Server(0, self.office, **options)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append((server, thread))
        return server

    def tcp(self, server, path, host):
        req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}{path}', headers={'Host': host})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status
        except urllib.error.HTTPError as e:
            with e:
                return e.code

    def local(self, path='/api/bootstrap', headers=None):
        return local_request(self.socket_path, path, headers={'Host': LOCAL_HOST, **(headers or {})})

    def test_loopback_tcp_never_reaches_local_mode(self):
        server = self.start(public_origin='https://' + PUBLIC_HOST, local_socket=self.socket_path)
        port = server.server_port
        for host in (f'127.0.0.1:{port}', f'localhost:{port}', LOCAL_HOST, 'localhost:18421'):
            for path in ('/api/bootstrap', '/api/session', '/api/tasks', '/api/journal', '/api/devices', '/api/sync?after=0'):
                self.assertEqual(self.tcp(server, path, host), 421, (host, path))
        self.assertEqual(self.tcp(server, '/api/session', PUBLIC_HOST), 401)

    def test_private_socket_serves_local_mode(self):
        server = self.start(local_socket=self.socket_path)
        status, body, _ = self.local()
        self.assertEqual((status, json.loads(body)['token']), (200, server.token))
        status, body, _ = self.local('/api/session')
        self.assertEqual((status, json.loads(body)['mode']), (200, 'local'))

    def test_socket_and_directory_are_owner_only(self):
        self.start(local_socket=self.socket_path)
        sock, parent = self.socket_path.lstat(), self.socket_path.parent.lstat()
        self.assertTrue(stat.S_ISSOCK(sock.st_mode))
        self.assertEqual(stat.S_IMODE(sock.st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(parent.st_mode), 0o700)
        self.assertEqual((sock.st_uid, parent.st_uid), (os.getuid(), os.getuid()))

    def test_socket_still_rejects_rebinding_forwarding_and_public_host(self):
        self.start(public_origin='https://' + PUBLIC_HOST, local_socket=self.socket_path)
        self.assertEqual(self.local(headers={'Host': 'evil.example:18421'})[0], 421)
        self.assertEqual(self.local(headers={'X-Forwarded-For': '203.0.113.7'})[0], 421)
        self.assertEqual(self.local(headers={'Forwarded': 'for=203.0.113.7'})[0], 421)
        self.assertEqual(self.local('/api/session', {'Host': PUBLIC_HOST})[0], 421)

    def test_dev_tcp_local_is_opt_in(self):
        plain = self.start()
        self.assertEqual(self.tcp(plain, '/api/bootstrap', f'127.0.0.1:{plain.server_port}'), 421)
        dev = self.start(dev_tcp_local=True)
        self.assertEqual(self.tcp(dev, '/api/bootstrap', f'127.0.0.1:{dev.server_port}'), 200)

    def test_local_websocket_over_socket(self):
        self.start(local_socket=self.socket_path)
        ws = WS(self.socket_path, '/api/ws?after=0', {'Host': LOCAL_HOST})
        try:
            self.assertEqual(ws.status, 101)
            self.assertEqual(ws.message()['type'], 'hello')
        finally:
            ws.close()

    def test_stale_socket_is_replaced(self):
        self.socket_path.parent.mkdir(mode=0o700)
        stale_socket(self.socket_path)
        self.start(local_socket=self.socket_path)
        self.assertEqual(self.local()[0], 200)

    def test_live_socket_is_not_taken_over(self):
        self.start(local_socket=self.socket_path)
        with self.assertRaisesRegex(ValueError, 'already listening'):
            app.Server(0, self.office, local_socket=self.socket_path)
        self.assertEqual(self.local()[0], 200)

    def test_foreign_files_are_refused_not_deleted(self):
        run = self.root / 'other'
        run.mkdir(mode=0o700)
        regular = run / 'office.sock'
        regular.write_text('keep me')
        with self.assertRaisesRegex(ValueError, 'not a socket'):
            app.Server(0, self.office, local_socket=regular)
        self.assertEqual(regular.read_text(), 'keep me')
        link = run / 'link.sock'
        link.symlink_to(regular)
        with self.assertRaisesRegex(ValueError, 'not a socket'):
            app.Server(0, self.office, local_socket=link)
        self.assertTrue(link.is_symlink())

    def test_directory_open_to_others_is_refused(self):
        shared = self.root / 'shared'
        shared.mkdir()
        shared.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'mode 700'):
            app.Server(0, self.office, local_socket=shared / 'office.sock')
        self.assertFalse((shared / 'office.sock').exists())

    def test_port_in_use_reports_the_bind_error(self):
        with socket.socket() as taken:
            taken.bind(('127.0.0.1', 0)); taken.listen()
            with self.assertRaises(OSError):
                app.Server(taken.getsockname()[1], self.office, local_socket=self.socket_path)
        self.assertFalse(self.socket_path.exists())

    def test_overlong_path_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'longer than'):
            app.Server(0, self.office, local_socket=self.root / ('x' * 120) / 'office.sock')

    def test_close_removes_only_its_own_socket(self):
        server = self.start(local_socket=self.socket_path)
        server.shutdown(); server.server_close(); self.servers.pop()[1].join()
        self.assertFalse(self.socket_path.exists())
        other = self.root / 'run' / 'second.sock'
        server = self.start(local_socket=other)
        other.unlink()
        stale_socket(other)
        server.shutdown(); server.server_close(); self.servers.pop()[1].join()
        self.assertTrue(stat.S_ISSOCK(other.lstat().st_mode))


class EntryPointTests(unittest.TestCase):
    def test_service_creates_socket_beside_data_and_removes_it_on_stop(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            socket_path = root / 'run' / 'office.sock'
            proc = subprocess.Popen([sys.executable, '-I', str(OFFICE_PY), '--data', str(root / 'data'), '--port', '0'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                line = proc.stdout.readline()
                self.assertIn(f'local entry {socket_path}', line)
                port = int(line.split('loopback:')[1].split()[0].rstrip(';'))
                self.assertEqual(local_request(socket_path, '/api/bootstrap', headers={'Host': LOCAL_HOST})[0], 200)
                req = urllib.request.Request(f'http://127.0.0.1:{port}/api/bootstrap', headers={'Host': f'127.0.0.1:{port}'})
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(req, timeout=5)
                with caught.exception as e:
                    self.assertEqual(e.code, 421)
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=15), 0)
                self.assertFalse(socket_path.exists())
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                proc.stdout.close(); proc.stderr.close()


if __name__ == '__main__':
    unittest.main()
