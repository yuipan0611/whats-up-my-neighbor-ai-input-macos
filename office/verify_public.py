"""Checks to rerun after every office deploy (docs/mobile/DEPLOY.md). Run from the Mac:

    python3 -I office/verify_public.py --expect-version 0.4.0

Pairs a short-lived test device through the VPS CLI and revokes it before exiting.
Never prints pairing codes, cookies or tokens."""
import argparse
import base64
from datetime import datetime, timezone
import http.client
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--host', default='office.nekonode.cloud')
parser.add_argument('--ssh', default='neighbor-vps')
parser.add_argument('--expect-version', required=True)
args = parser.parse_args()
ORIGIN = 'https://' + args.host
OFFICE = '~/neighbor-office/current/office.py'
SOCKET = '~/neighbor-office/run/office.sock'
LOCAL_HOST = '127.0.0.1:18421'
failures = []


def check(name, ok):
    print(('PASS ' if ok else 'FAIL ') + name, flush=True)
    if not ok:
        failures.append(name)


def https(method, path, headers=None, body=None):
    conn = http.client.HTTPSConnection(args.host, timeout=15, context=ssl.create_default_context())
    try:
        conn.request(method, path, body, headers or {})
        r = conn.getresponse()
        return r.status, r.read(), r.headers
    finally:
        conn.close()


def remote(command):
    return subprocess.run(['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', args.ssh, command],
                          capture_output=True, text=True, timeout=60)


class WSS:
    """Just enough RFC 6455 over TLS to read the server's frames."""
    def __init__(self, headers):
        raw = socket.create_connection((args.host, 443), timeout=15)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=args.host)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = ['GET /api/ws?after=0 HTTP/1.1', f'Host: {args.host}', 'Upgrade: websocket', 'Connection: Upgrade',
                 f'Sec-WebSocket-Key: {key}', 'Sec-WebSocket-Version: 13'] + [f'{k}: {v}' for k, v in headers.items()]
        self.sock.sendall(('\r\n'.join(lines) + '\r\n\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, self.buffer = data.partition(b'\r\n\r\n')
        self.status = int(head.split(b' ')[1]) if head else 0

    def read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError('closed')
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def message(self):
        while True:
            first, second = self.read(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack('!H', self.read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.read(8))[0]
            payload, opcode = self.read(length), first & 0x0F
            if opcode == 0x1:
                return json.loads(payload)
            if opcode == 0x8:
                return {'close': struct.unpack('!H', payload[:2])[0]}

    def until_close(self):
        """Skip the backlog of earlier events the server replays after hello."""
        while True:
            message = self.message()
            if 'close' in message:
                return message

    def close(self):
        self.sock.close()


def transport_and_anonymous():
    conn = http.client.HTTPConnection(args.host, 80, timeout=15)
    conn.request('GET', '/')
    r = conn.getresponse(); r.read(); conn.close()
    check('HTTP redirects to HTTPS with 308', r.status == 308 and (r.getheader('Location') or '').startswith(ORIGIN))
    check('TLS certificate verifies and the pairing page is 200', https('GET', '/')[0] == 200)
    for path in ('/api/session', '/api/tasks', '/api/health', '/api/sync?after=0'):
        check(f'anonymous {path} is 401', https('GET', path)[0] == 401)
    check('anonymous /api/bootstrap is 404', https('GET', '/api/bootstrap')[0] == 404)
    ws = WSS({'Origin': ORIGIN})
    check('anonymous WSS handshake is 401', ws.status == 401)
    ws.close()
    cross = {'Origin': 'https://evil.example', 'Sec-Fetch-Site': 'cross-site', 'Content-Type': 'application/json'}
    check('cross-site POST is 403', https('POST', '/api/command', cross, b'{}')[0] == 403)
    for path, mime in (('/mobile.js', 'application/javascript'), ('/pdf-main.mjs', 'application/javascript'), ('/neko-claude.png', 'image/png')):
        status, _, headers = https('GET', path)
        check(f'{path} is served as {mime}', status == 200 and (headers.get('Content-Type') or '').startswith(mime))


def temporary_device():
    out = remote(f'python3 -I {OFFICE} pair')
    code = out.stdout.split('配對碼：')[1].split()[0] if out.returncode == 0 and '配對碼：' in out.stdout else None
    check('VPS CLI issued a pairing code', bool(code))
    if not code:
        return
    name = 'deploy-check-' + datetime.now(timezone.utc).strftime('%H%M%S')
    body = json.dumps({'code': code, 'name': name}).encode()
    status, raw, headers = https('POST', '/api/pair', {'Origin': ORIGIN, 'Content-Type': 'application/json'}, body)
    check(f'test device {name} pairs with 201', status == 201)
    if status != 201:
        return
    device = json.loads(raw)['device']['id']
    try:
        set_cookie = headers.get('Set-Cookie') or ''
        check('cookie has __Host- prefix, Secure, HttpOnly, SameSite=Strict',
              set_cookie.startswith('__Host-office=') and all(p in set_cookie for p in ('Secure', 'HttpOnly', 'SameSite=Strict')))
        cookie = {'Cookie': set_cookie.split(';')[0]}
        check('paired /api/session is 200', https('GET', '/api/session', cookie)[0] == 200)
        check('paired /api/tasks is 200', https('GET', '/api/tasks', cookie)[0] == 200)
        status, raw, _ = https('GET', '/api/health', cookie)
        check(f'paired /api/health is 200 with version {args.expect_version}', status == 200 and json.loads(raw)['version'] == args.expect_version)
        ws = WSS({**cookie, 'Origin': ORIGIN})
        hello = ws.message() if ws.status == 101 else {}
        check('paired WSS is 101 and says hello', ws.status == 101 and hello.get('type') == 'hello')
        remote(f'python3 -I {OFFICE} revoke {device}')
        start = time.monotonic()
        closed = ws.until_close() if ws.status == 101 else {}
        check(f'revoked device: open WSS closes with 4401 ({time.monotonic() - start:.1f}s)', closed == {'close': 4401})
        ws.close()
        check('revoked device: /api/session is 401', https('GET', '/api/session', cookie)[0] == 401)
        ws = WSS({**cookie, 'Origin': ORIGIN})
        check('revoked device: new WSS is 401', ws.status == 401)
        ws.close()
    finally:
        remote(f'python3 -I {OFFICE} revoke {device}')


def private_local_entry():
    out = remote(f"stat -c '%A %U' {SOCKET}")
    check('local socket is srw------- neighbor', out.stdout.strip() == 'srw------- neighbor')
    out = remote("curl -s -o /dev/null -w '%{http_code}' -H 'Host: 127.0.0.1:8421' http://127.0.0.1:8421/api/bootstrap")
    check('VPS loopback TCP with a local Host is 421', out.stdout.strip() == '421')
    out = remote(f"curl -s --unix-socket {SOCKET} -H 'Host: {LOCAL_HOST}' http://{LOCAL_HOST}/api/health")
    try:
        version = json.loads(out.stdout)['version']
    except (ValueError, KeyError):
        version = None
    check(f'local socket /api/health reports {args.expect_version}', version == args.expect_version)


def mac_tunnel():
    out = remote(f'sock={SOCKET}; [ -S "$sock" ] && printf %s "$sock"')
    target = out.stdout.strip()
    check('open-office.command would tunnel to the socket', target.endswith('/neighbor-office/run/office.sock'))
    if not target:
        return
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    tunnel = subprocess.Popen(['/usr/bin/ssh', '-N', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ExitOnForwardFailure=yes',
                               '-L', f'127.0.0.1:{port}:{target}', args.ssh], stderr=subprocess.DEVNULL)
    try:
        status = None
        for _ in range(20):
            try:
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                conn.request('GET', '/api/health', headers={'Host': LOCAL_HOST})
                status = conn.getresponse().status
                conn.close()
                break
            except OSError:
                time.sleep(0.5)
        check('Mac SSH tunnel to the socket: /api/health is 200', status == 200)
    finally:
        tunnel.terminate()
        tunnel.wait()


transport_and_anonymous()
temporary_device()
private_local_entry()
mac_tunnel()
print(f'{len(failures)} failed' if failures else 'ALL PASS')
sys.exit(1 if failures else 0)
