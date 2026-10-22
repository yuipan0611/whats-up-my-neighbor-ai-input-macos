import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from test_office import app, FakeModel

PUBLIC_HOST = 'office.test.example'
PUBLIC = 'https://' + PUBLIC_HOST
OFFICE_PY = Path(__file__).parents[1] / 'office.py'


def uid():
    return str(uuid.uuid4())


class WS:
    """Minimal RFC 6455 client: masked frames out, unmasked frames in."""
    def __init__(self, port, path, headers):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.key = base64.b64encode(os.urandom(16)).decode()
        lines = [f'GET {path} HTTP/1.1', 'Upgrade: websocket', 'Connection: Upgrade',
                 f'Sec-WebSocket-Key: {self.key}', 'Sec-WebSocket-Version: 13']
        lines += [f'{k}: {v}' for k, v in headers.items()]
        self.sock.sendall(('\r\n'.join(lines) + '\r\n\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, self.buffer = data.partition(b'\r\n\r\n')
        status_line, *header_lines = head.decode().split('\r\n')
        self.status = int(status_line.split()[1])
        self.headers = {k.lower(): v.strip() for k, _, v in (h.partition(':') for h in header_lines)}

    def read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError('closed')
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def frame(self):
        first, second = self.read(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack('!H', self.read(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.read(8))[0]
        return first & 0x0F, self.read(length)

    def until_close(self):
        while True:
            message = self.message()
            if 'close' in message:
                return message

    def message(self):
        while True:
            opcode, payload = self.frame()
            if opcode == 0x1:
                return json.loads(payload)
            if opcode == 0x8:
                return {'close': struct.unpack('!H', payload[:2])[0]}

    def send(self, opcode, payload=b'', mask=True, fin=True):
        size = len(payload)
        head = bytes([(0x80 if fin else 0) | opcode])
        flag = 0x80 if mask else 0
        if size < 126:
            head += bytes([flag | size])
        else:
            head += bytes([flag | 126]) + struct.pack('!H', size)
        key = os.urandom(4)
        body = bytes(b ^ key[i % 4] for i, b in enumerate(payload)) if mask else payload
        self.sock.sendall(head + (key if mask else b'') + body)

    def close(self):
        self.sock.close()


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name) / 'data'
        self.store = app.Store(self.data)
        self.office = app.Office(self.store, FakeModel())
        self.server = app.Server(0, self.office, PUBLIC)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_port
        self.url = f'http://127.0.0.1:{self.port}'
        self.local = {'Host': f'127.0.0.1:{self.port}'}
        self.sockets = []

    def tearDown(self):
        for ws in self.sockets:
            ws.close()
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def request(self, path, body=None, headers=None, method=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data, headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json_or_bytes(r.read()), r.headers
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json_or_bytes(e.read()), e.headers

    def public(self, ip='203.0.113.7', cookie=None, origin=True, token=None, json_body=False):
        headers = {'Host': PUBLIC_HOST, 'X-Forwarded-For': ip}
        if origin:
            headers['Origin'] = PUBLIC if origin is True else origin
        if cookie:
            headers['Cookie'] = cookie
        if token:
            headers['X-Office-Token'] = token
        if json_body:
            headers['Content-Type'] = 'application/json'
        return headers

    def pair(self, name='YUI iPhone', ip='203.0.113.7'):
        code, _ = self.store.create_pairing_code()
        status, body, headers = self.request('/api/pair', {'code': code, 'name': name}, self.public(ip, json_body=True))
        self.assertEqual(status, 201, body)
        cookie = headers['Set-Cookie'].split(';')[0]
        return cookie, body

    def ws(self, path='/api/ws?after=0', headers=None):
        ws = WS(self.port, path, headers if headers is not None else {'Host': f'127.0.0.1:{self.port}'})
        self.sockets.append(ws)
        return ws


def json_or_bytes(data):
    try:
        return json.loads(data)
    except ValueError:
        return data


class SyncTests(Base):
    def test_sync_pages_in_seq_order_without_gaps(self):
        for i in range(5):
            self.office.command({'id': uid(), 'prompt': f'任務 {i}'})
        self.store.set_paused(True)
        status, body, _ = self.request('/api/sync?after=0&limit=3', headers=self.local)
        self.assertEqual(status, 200)
        self.assertTrue(body['more'])
        self.assertFalse(body['stale'])
        seen = [e['seq'] for e in body['events']]
        while body['more']:
            body = self.request(f'/api/sync?after={seen[-1]}&limit=3', headers=self.local)[1]
            seen += [e['seq'] for e in body['events']]
        self.assertEqual(seen, list(range(1, body['latest_seq'] + 1)))
        self.assertEqual(self.request(f"/api/sync?after={body['latest_seq']}", headers=self.local)[1]['events'], [])
        self.assertTrue(body['paused'])

    def test_stale_cursor_and_bad_parameters(self):
        self.office.command({'id': uid(), 'prompt': 'x'})
        body = self.request('/api/sync?after=999', headers=self.local)[1]
        self.assertTrue(body['stale'])
        self.assertEqual(body['events'], [])
        for query in ('after=-1', 'after=x', 'limit=0', 'limit=1001'):
            self.assertEqual(self.request('/api/sync?' + query, headers=self.local)[0], 400)

    def test_office_level_events_only_on_real_change(self):
        self.store.set_paused(True); self.store.set_paused(True); self.store.set_paused(False)
        entry = {'id': uid(), 'day': '2026-10-22', 'text': '合成紀錄'}
        self.store.add_journal(entry); self.store.add_journal(entry)
        self.store.upload('note.md', 'hello')
        office = [(e['task_id'], e['status']) for e in self.store.sync(0)['events']]
        self.assertEqual(office, [('_office', 'paused'), ('_office', 'resumed'), ('_office', 'journal_added'), ('_office', 'file_added')])
        self.assertNotIn('合成紀錄', json.dumps(self.store.sync(0), ensure_ascii=False))

    def test_tasks_snapshot_carries_latest_seq(self):
        self.office.command({'id': uid(), 'prompt': 'x'})
        body = self.request('/api/tasks', headers=self.local)[1]
        self.assertEqual(body['latest_seq'], self.store.latest_seq())


class BoundaryTests(Base):
    def test_modes(self):
        self.assertEqual(self.request('/api/bootstrap', headers=self.local)[0], 200)
        self.assertEqual(self.request('/api/tasks', headers={'Host': f'127.0.0.1:{self.port}', 'X-Forwarded-For': '1.2.3.4'})[0], 421)
        self.assertEqual(self.request('/api/tasks', headers={'Host': 'other.example'})[0], 421)
        status, _, headers = self.request('/', headers=self.public())
        self.assertEqual(status, 200)
        self.assertIn(f'connect-src \'self\' wss://{PUBLIC_HOST}', headers['Content-Security-Policy'])
        self.assertIn('max-age', headers['Strict-Transport-Security'])

    def test_cross_site_navigation_can_open_pairing_page_but_not_api(self):
        headers = {**self.public(origin=False), 'Sec-Fetch-Site': 'cross-site'}
        self.assertEqual(self.request('/', headers=headers)[0], 200)
        self.assertEqual(self.request('/app.js', headers=headers)[0], 200)
        self.assertEqual(self.request('/api/session', headers=headers)[0], 403)

    def test_public_mode_disabled_without_origin_flag(self):
        server = app.Server(0, self.office)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/', headers={'Host': PUBLIC_HOST})
            with self.assertRaises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(req, timeout=5)
            self.assertEqual(e.exception.code, 421)
        finally:
            server.shutdown(); server.server_close(); thread.join()
        with self.assertRaises(ValueError):
            app.Server(0, self.office, 'http://office.test.example')

    def test_unpaired_public_cannot_get_write_token_or_data(self):
        self.assertEqual(self.request('/api/bootstrap', headers=self.public())[0], 404)
        for path in ('/api/tasks', '/api/sync?after=0', '/api/journal', '/api/files', '/api/health'):
            status, body, _ = self.request(path, headers=self.public())
            self.assertEqual(status, 401, path)
            self.assertTrue(body['pair_required'])
        status, body, _ = self.request('/api/session', headers=self.public())
        self.assertEqual((status, body['pair_required']), (401, True))
        status, _, _ = self.request('/api/command', {'id': uid(), 'prompt': 'x'}, self.public(json_body=True, token=self.server.token))
        self.assertEqual(status, 401)
        self.assertEqual(self.store.list(), [])

    def test_static_whitelist(self):
        self.assertEqual(self.request('/app.js', headers=self.public())[0], 200)
        for path in ('/../office.py', '/office.py', '/.hidden.js', '/index.html', '/static/app.js', '/App.js'):
            self.assertEqual(self.request(path, headers=self.public())[0], 404, path)


class PairingTests(Base):
    def test_pair_sets_strict_cookie_and_session_token(self):
        cookie, body = self.pair()
        self.assertEqual(body['device']['name'], 'YUI iPhone')
        code, _ = self.store.create_pairing_code()
        _, _, headers = self.request('/api/pair', {'code': code, 'name': 'x'}, self.public(json_body=True))
        attrs = headers['Set-Cookie']
        for part in ('__Host-office=', 'Path=/', 'Secure', 'HttpOnly', 'SameSite=Strict', 'Max-Age=2592000'):
            self.assertIn(part, attrs)
        status, session, headers = self.request('/api/session', headers=self.public(cookie=cookie))
        self.assertEqual(status, 200)
        self.assertEqual(session['mode'], 'public')
        self.assertEqual(session['token'], body['token'])
        self.assertIn('Max-Age=2592000', headers['Set-Cookie'])
        self.assertNotEqual(session['token'], self.server.token)

    def test_code_is_single_use_expires_and_is_replaced(self):
        code, _ = self.store.create_pairing_code()
        ok = self.request('/api/pair', {'code': code, 'name': 'a'}, self.public(json_body=True))
        again = self.request('/api/pair', {'code': code, 'name': 'b'}, self.public(json_body=True))
        self.assertEqual((ok[0], again[0]), (201, 403))
        old, _ = self.store.create_pairing_code()
        self.store.create_pairing_code()
        self.assertEqual(self.request('/api/pair', {'code': old, 'name': 'c'}, self.public(json_body=True))[0], 403)
        late, _ = self.store.create_pairing_code()
        with self.store.connect() as c:
            c.execute('UPDATE pairing_codes SET expires=? WHERE used=0', (time.time() - 1,))
        status, body, _ = self.request('/api/pair', {'code': late, 'name': 'd'}, self.public(json_body=True))
        self.assertEqual((status, body['error']), (403, '配對碼不正確或已失效。'))

    def test_code_voided_after_ten_failures_across_ips(self):
        code, _ = self.store.create_pairing_code()
        wrong = '00000000' if code != '00000000' else '11111111'
        for i in range(10):
            self.request('/api/pair', {'code': wrong, 'name': 'x'}, self.public(f'198.51.100.{i}', json_body=True))
        self.assertEqual(self.request('/api/pair', {'code': code, 'name': 'x'}, self.public('192.0.2.1', json_body=True))[0], 403)

    def test_rate_limit_per_forwarded_ip(self):
        self.store.create_pairing_code()
        for _ in range(5):
            self.assertEqual(self.request('/api/pair', {'code': '99999999', 'name': 'x'}, self.public('203.0.113.9', json_body=True))[0] in (403,), True)
        status, body, headers = self.request('/api/pair', {'code': '99999999', 'name': 'x'}, self.public('203.0.113.9', json_body=True))
        self.assertEqual(status, 429)
        self.assertGreater(body['retry_after'], 0)
        self.assertEqual(headers['Retry-After'], str(body['retry_after']))
        code, _ = self.store.create_pairing_code()
        locked = self.request('/api/pair', {'code': code, 'name': 'x'}, self.public('203.0.113.9', json_body=True))
        self.assertEqual(locked[0], 429)
        spoofed = self.public('203.0.113.9', json_body=True)
        spoofed['X-Forwarded-For'] = '10.0.0.1, 203.0.113.9'
        self.assertEqual(self.request('/api/pair', {'code': code, 'name': 'x'}, spoofed)[0], 429)
        self.assertEqual(self.request('/api/pair', {'code': code, 'name': 'x'}, self.public('203.0.113.10', json_body=True))[0], 201)

    def test_pair_requires_origin_json_and_public_mode(self):
        code, _ = self.store.create_pairing_code()
        body = {'code': code, 'name': 'x'}
        self.assertEqual(self.request('/api/pair', body, self.public(origin=False, json_body=True))[0], 403)
        self.assertEqual(self.request('/api/pair', body, self.public(origin='https://evil.example', json_body=True))[0], 403)
        self.assertEqual(self.request('/api/pair', body, self.public())[0], 415)
        self.assertEqual(self.request('/api/pair', body, {**self.local, 'Content-Type': 'application/json'})[0], 404)
        for bad in ({'code': '1234', 'name': 'x'}, {'code': code, 'name': ''}, {'code': code, 'name': 'x' * 41}, {'code': code, 'name': 'a\nb'}):
            self.assertEqual(self.request('/api/pair', bad, self.public(json_body=True))[0], 400)
        self.assertEqual(self.request('/api/pair', body, self.public(json_body=True))[0], 201)


class WriteTests(Base):
    def test_cookie_origin_and_token_all_required(self):
        cookie, paired = self.pair()
        token = paired['token']
        task = {'id': uid(), 'prompt': '手機交辦'}
        ok = self.public(cookie=cookie, token=token, json_body=True)
        self.assertEqual(self.request('/api/command', task, ok)[0], 202)
        self.assertEqual(self.request('/api/command', task, ok)[0], 202)
        self.assertEqual(len(self.store.list()), 1)
        status, body, _ = self.request('/api/command', task, self.public(cookie=cookie, json_body=True))
        self.assertEqual((status, body.get('token_expired')), (403, True))
        status, body, _ = self.request('/api/command', task, self.public(cookie=cookie, token=self.server.token, json_body=True))
        self.assertEqual((status, body.get('token_expired')), (403, True))
        status, body, _ = self.request('/api/command', task, self.public(cookie=cookie, token=token, json_body=True, origin='https://evil.example'))
        self.assertEqual(status, 403); self.assertNotIn('token_expired', body)
        status, body, _ = self.request('/api/command', task, self.public(cookie=cookie, token=token, json_body=True, origin=False))
        self.assertEqual(status, 403); self.assertNotIn('token_expired', body)
        forged = cookie.split('.')[0] + '.forged'
        self.assertEqual(self.request('/api/command', task, self.public(cookie=forged, token=token, json_body=True))[0], 401)

    def test_local_flow_unchanged(self):
        headers = {**self.local, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token}
        self.assertEqual(self.request('/api/command', {'id': uid(), 'prompt': 'x'}, headers)[0], 202)
        session = self.request('/api/session', headers=self.local)[1]
        self.assertEqual((session['mode'], session['device'], session['token']), ('local', None, self.server.token))

    def test_revoke_forget_and_expiry(self):
        cookie, paired = self.pair()
        device = paired['device']['id']
        status, body, _ = self.request(f'/api/devices/{device}/revoke', {}, {**self.local, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token})
        self.assertEqual((status, body['device']['revoked']), (200, 1))
        self.assertEqual(self.request('/api/session', headers=self.public(cookie=cookie))[0], 401)
        self.assertEqual(self.request(f'/api/devices/{device}/revoke', {}, self.public(cookie=cookie, json_body=True))[0], 401)
        cookie2, paired2 = self.pair('second')
        self.assertEqual(self.request('/api/devices', headers=self.public(cookie=cookie2))[0], 404)
        status, _, headers = self.request('/api/session/forget', {}, self.public(cookie=cookie2, token=paired2['token'], json_body=True))
        self.assertEqual(status, 200)
        self.assertIn('Max-Age=0', headers['Set-Cookie'])
        self.assertEqual(self.request('/api/session', headers=self.public(cookie=cookie2))[0], 401)
        cookie3, paired3 = self.pair('third')
        with self.store.connect() as c:
            c.execute("UPDATE devices SET last_seen='2026-01-01T00:00:00+00:00' WHERE id=?", (paired3['device']['id'],))
        self.assertEqual(self.request('/api/session', headers=self.public(cookie=cookie3))[0], 401)


class WebSocketTests(Base):
    def setUp(self):
        super().setUp()
        self.saved = (app.Handler.REVOKE_CHECK, app.Handler.IDLE_LIMIT)
        app.Handler.REVOKE_CHECK = 0.2

    def tearDown(self):
        app.Handler.REVOKE_CHECK, app.Handler.IDLE_LIMIT = self.saved
        super().tearDown()

    def public_ws(self, cookie, after=0, origin=PUBLIC):
        headers = {'Host': PUBLIC_HOST, 'X-Forwarded-For': '203.0.113.7', 'Cookie': cookie}
        if origin:
            headers['Origin'] = origin
        return self.ws(f'/api/ws?after={after}', headers)

    def test_handshake_hello_backlog_and_live(self):
        first = self.office.command({'id': uid(), 'prompt': '先交辦'})['task']['id']
        ws = self.ws()
        self.assertEqual(ws.status, 101)
        expected = base64.b64encode(hashlib.sha1((ws.key + app.WS_GUID).encode()).digest()).decode()
        self.assertEqual(ws.headers['sec-websocket-accept'], expected)
        hello = ws.message()
        self.assertEqual((hello['type'], hello['latest_seq']), ('hello', 1))
        backlog = ws.message()
        self.assertEqual((backlog['type'], backlog['event']['task_id'], backlog['event']['seq']), ('event', first, 1))
        second = self.office.command({'id': uid(), 'prompt': '之後交辦'})['task']['id']
        live = ws.message()
        self.assertEqual((live['event']['task_id'], live['event']['seq']), (second, 2))

    def test_reconnect_after_seq_has_no_gap_or_duplicate(self):
        ws = self.ws()
        ws.message()
        for i in range(3):
            self.office.command({'id': uid(), 'prompt': f't{i}'})
        got = [ws.message()['event']['seq'] for _ in range(3)]
        ws.close()
        for i in range(2):
            self.office.command({'id': uid(), 'prompt': f'offline {i}'})
        again = self.ws(f'/api/ws?after={got[-1]}')
        self.assertEqual(again.message()['type'], 'hello')
        got += [again.message()['event']['seq'] for _ in range(2)]
        self.assertEqual(got, [1, 2, 3, 4, 5])

    def test_resync_when_cursor_is_stale_or_too_far_behind(self):
        self.office.command({'id': uid(), 'prompt': 'x'})
        ws = self.ws('/api/ws?after=50')
        ws.message()
        self.assertEqual(ws.message(), {'type': 'resync', 'latest_seq': 1})
        with self.store.connect() as c:
            for _ in range(app.Handler.BACKLOG + 1):
                self.store._office_event(c, 'file_added', 'synthetic')
        behind = self.ws('/api/ws?after=0')
        behind.message()
        self.assertEqual(behind.message()['type'], 'resync')

    def test_handshake_rejections(self):
        cookie, _ = self.pair()
        self.assertEqual(self.public_ws('').status, 401)
        self.assertEqual(self.public_ws(cookie, origin='https://evil.example').status, 403)
        self.assertEqual(self.public_ws(cookie, origin=None).status, 403)
        self.assertEqual(self.public_ws(cookie).status, 101)
        status, _, headers = self.request('/api/ws', headers=self.local)
        self.assertEqual((status, headers['Upgrade']), (426, 'websocket'))
        bad = WS(self.port, '/api/ws', {**self.local})
        self.sockets.append(bad)
        bad.sock.close()
        raw = socket.create_connection(('127.0.0.1', self.port), timeout=5)
        raw.sendall(f'GET /api/ws HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: short\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        self.assertIn(b' 400 ', raw.recv(200)); raw.close()

    def test_revoke_closes_socket_with_4401(self):
        cookie, paired = self.pair()
        ws = self.public_ws(cookie)
        ws.message()
        subprocess.run([sys.executable, '-I', str(OFFICE_PY), 'revoke', paired['device']['id'], '--data', str(self.data)],
                       check=True, capture_output=True)
        start = time.monotonic()
        self.assertEqual(ws.message(), {'close': 4401})
        self.assertLess(time.monotonic() - start, 3)
        cookie2, paired2 = self.pair('second')
        ws2 = self.public_ws(cookie2)
        ws2.message()
        self.request(f"/api/devices/{paired2['device']['id']}/revoke", {}, {**self.local, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token})
        self.assertEqual(ws2.message(), {'close': 4401})

    def test_open_socket_closes_when_device_session_expires(self):
        cookie, paired = self.pair()
        ws = self.public_ws(cookie)
        ws.message()
        self.office.command({'id': uid(), 'prompt': '到期前的事件'})
        self.assertEqual(ws.message()['type'], 'event')
        expired = (datetime.now(timezone.utc) - timedelta(days=app.Store.DEVICE_DAYS, minutes=1)).isoformat(timespec='seconds')
        with self.store.connect() as c:
            c.execute('UPDATE devices SET last_seen=? WHERE id=?', (expired, paired['device']['id']))
        start = time.monotonic()
        self.assertEqual(ws.until_close(), {'close': 4401})
        self.assertLess(time.monotonic() - start, 3)
        self.assertFalse(self.store.device_active(paired['device']['id']))
        self.assertEqual(self.request('/api/session', headers=self.public(cookie=cookie))[0], 401)
        self.assertEqual(self.public_ws(cookie).status, 401)

    def test_socket_stays_open_just_inside_device_window(self):
        cookie, paired = self.pair()
        ws = self.public_ws(cookie)
        ws.message()
        recent = (datetime.now(timezone.utc) - timedelta(days=app.Store.DEVICE_DAYS - 1)).isoformat(timespec='seconds')
        with self.store.connect() as c:
            c.execute('UPDATE devices SET last_seen=? WHERE id=?', (recent, paired['device']['id']))
        time.sleep(0.6)
        self.office.command({'id': uid(), 'prompt': '仍在有效期內'})
        self.assertEqual(ws.message()['type'], 'event')

    def test_third_connection_kicks_oldest(self):
        cookie, _ = self.pair()
        a, b = self.public_ws(cookie), self.public_ws(cookie)
        a.message(); b.message()
        c = self.public_ws(cookie)
        c.message()
        self.assertEqual(a.until_close(), {'close': 4008})

    def test_ping_ack_idle_and_protocol_errors(self):
        cookie, paired = self.pair()
        self.office.command({'id': uid(), 'prompt': 'x'})
        ws = self.public_ws(cookie)
        ws.message(); ws.message()
        ws.send(0x9, b'hi')
        opcode, payload = ws.frame()
        while opcode != 0xA:
            opcode, payload = ws.frame()
        self.assertEqual(payload, b'hi')
        ws.send(0x1, json.dumps({'type': 'ack', 'seq': 1}).encode())
        ws.send(0x1, json.dumps({'type': 'ack', 'seq': 99}).encode())
        ws.send(0x9, b'sync')
        while ws.frame()[0] != 0xA:
            pass
        self.assertEqual([d['last_seq'] for d in self.store.devices()], [1])
        unmasked = self.public_ws(cookie)
        unmasked.message()
        unmasked.send(0x1, b'{}', mask=False)
        self.assertEqual(unmasked.until_close(), {'close': 1002})
        big = self.public_ws(cookie)
        big.message()
        big.send(0x1, b'x' * 5000)
        self.assertEqual(big.until_close(), {'close': 1009})
        app.Handler.IDLE_LIMIT = 0.5
        idle = self.ws()
        idle.message()
        self.assertEqual(idle.until_close(), {'close': 4000})


class CLITests(unittest.TestCase):
    def test_pair_devices_revoke(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / 'data'
            run = lambda *a: subprocess.run([sys.executable, '-I', str(OFFICE_PY), *a, '--data', str(data)], check=True, capture_output=True, text=True).stdout
            out = run('pair')
            code = out.split('配對碼：')[1].split()[0]
            self.assertRegex(code, r'^\d{8}$')
            store = app.Store(data)
            device, _ = store.redeem_pairing_code(code, 'cli phone')
            self.assertIn(device['id'], run('devices'))
            self.assertIn('已撤銷', run('revoke', device['id']))
            self.assertFalse(store.device_active(device['id']))
            with store.connect() as c:
                stored = c.execute('SELECT code_hash FROM pairing_codes').fetchone()[0]
            self.assertNotEqual(stored, code)


if __name__ == '__main__':
    unittest.main(verbosity=2)
