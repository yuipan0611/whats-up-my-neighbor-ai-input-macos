"""Fixed Unix-socket adapter for the optional browser service (stdlib only).

Office owns authentication. No browser credentials, page tokens, user-selected
upstreams or caller-supplied identity headers cross this boundary.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import select
import socket
import stat
import threading
import time
from urllib.parse import parse_qs, urlsplit


READ_PATHS = {
    '/browser/', '/browser/viewer.js', '/browser/viewer.css', '/browser/novnc.js',
    '/browser/notices.txt', '/api/browser/state',
}
WRITE_PATHS = {'/api/browser/takeover', '/api/browser/release'}
WS_PATH = '/api/browser/ws'
MAX_BODY = 4096
MAX_RESPONSE = 2 * 1024 * 1024
MAX_BUFFER = 256 * 1024


class BrowserProxyError(Exception):
    def __init__(self, code='browser_unavailable', status=503):
        self.code, self.status = code, status
        super().__init__(code)


def private_socket(value: Path) -> None:
    """Reject symlinks and sockets accessible to other local users."""
    try:
        if not value.is_absolute() or '..' in value.parts:
            raise ValueError()
        for part in (value, *value.parents):
            if part.is_symlink():
                raise ValueError()
        parent, item = value.parent.stat(), value.stat()
        if (parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700
                or item.st_uid != os.getuid() or not stat.S_ISSOCK(item.st_mode)
                or stat.S_IMODE(item.st_mode) != 0o600):
            raise ValueError()
    except (OSError, ValueError):
        raise BrowserProxyError() from None


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=15):
        super().__init__('localhost', timeout=timeout)
        self.path = path

    def connect(self):
        private_socket(self.path)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


class BrowserProxy:
    """One fixed upstream; viewer sockets have their own bounded registry."""
    def __init__(self, path):
        self.path = Path(path)
        if not self.path.is_absolute() or '..' in self.path.parts:
            raise ValueError('--browser-socket must be an absolute private Unix socket')
        self._lock = threading.Lock()
        self._streams = {}
        self._stopping = threading.Event()

    def kick_device(self, device):
        with self._lock:
            for actor, stop in self._streams.values():
                if actor == device:
                    stop.set()

    def shutdown(self):
        self._stopping.set()

    def request(self, method, path, device, body=None):
        allowed = READ_PATHS if method == 'GET' else WRITE_PATHS if method == 'POST' else set()
        if path not in allowed:
            raise BrowserProxyError('browser_route_not_found', 404)
        data = None if body is None else json.dumps(body, separators=(',', ':')).encode()
        if data and len(data) > MAX_BODY:
            raise BrowserProxyError('browser_request_too_large', 413)
        # A takeover may drain a 35s agent action and spend 5s closing viewers.
        # Reads stay short; mutations are never automatically retried here.
        connection = UnixHTTPConnection(self.path, timeout=45 if method == 'POST' else 15)
        try:
            connection.request(method, path, data, {
                'X-Neko-Device': device, 'Content-Type': 'application/json',
                'Connection': 'close',
            })
            response = connection.getresponse()
            mime = response.getheader('Content-Type', '').split(';')[0].strip()
            if mime not in {'application/json', 'text/html', 'text/css', 'text/javascript', 'application/javascript', 'text/plain'}:
                raise BrowserProxyError()
            payload = response.read(MAX_RESPONSE + 1)
            if (len(payload) > MAX_RESPONSE or not 200 <= response.status < 600
                    or (response.status >= 400 and mime != 'application/json')):
                raise BrowserProxyError()
            if mime == 'application/json':
                payload = json.loads(payload)
                if not isinstance(payload, dict):
                    raise BrowserProxyError()
            return response.status, payload, mime + '; charset=utf-8'
        except (OSError, ValueError, http.client.HTTPException):
            raise BrowserProxyError() from None
        finally:
            connection.close()

    @staticmethod
    def websocket_path(query):
        try:
            values = parse_qs(query, strict_parsing=True)
            if set(values) != {'mode', 'epoch'} or any(len(v) != 1 for v in values.values()):
                raise ValueError()
            mode, raw = values['mode'][0], values['epoch'][0]
            if mode not in ('view', 'control') or not raw.isascii() or not raw.isdecimal():
                raise ValueError()
            epoch = int(raw)
            if not 0 <= epoch < 2 ** 48:
                raise ValueError()
            return f'{WS_PATH}?mode={mode}&epoch={epoch}'
        except ValueError:
            raise BrowserProxyError('browser_invalid_connection', 400) from None

    def websocket(self, handler, device):
        """Relay RFC6455 unchanged after Office's cookie and Origin checks.

        aiohttp terminates/validates RFC6455; Office does not invent a second
        frame parser. Buffers are bounded, and device expiry is rechecked even
        when both peers are idle. Closing this stream only pauses human control.
        """
        path = self.websocket_path(urlsplit(handler.path).query)
        key = handler.headers.get('Sec-WebSocket-Key', '')
        try:
            valid = len(base64.b64decode(key, validate=True)) == 16
        except ValueError:
            valid = False
        if (not valid or handler.headers.get('Upgrade', '').lower() != 'websocket'
                or 'upgrade' not in {p.strip().lower() for p in handler.headers.get('Connection', '').split(',')}
                or handler.headers.get('Sec-WebSocket-Version') != '13'):
            raise BrowserProxyError('browser_websocket_required', 426)
        stop, identifier = threading.Event(), object()
        with self._lock:
            if self._stopping.is_set():
                raise BrowserProxyError()
            if len(self._streams) >= 32 or sum(actor == device for actor, _ in self._streams.values()) >= 4:
                raise BrowserProxyError('browser_connection_limit', 429)
            self._streams[identifier] = (device, stop)
        upstream = None
        upgraded = False
        try:
            private_socket(self.path)
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.settimeout(15)
            upstream.connect(str(self.path))
            fields = [f'GET {path} HTTP/1.1', 'Host: localhost',
                      'Upgrade: websocket', 'Connection: Upgrade',
                      f'Sec-WebSocket-Key: {key}', 'Sec-WebSocket-Version: 13',
                      f'X-Neko-Device: {device}']
            offered = handler.headers.get('Sec-WebSocket-Protocol', '').split(',')
            if 'binary' in {p.strip() for p in offered}:
                fields.append('Sec-WebSocket-Protocol: binary')
            upstream.sendall(('\r\n'.join(fields) + '\r\n\r\n').encode('ascii'))
            data = bytearray()
            while b'\r\n\r\n' not in data:
                block = upstream.recv(4096)
                if not block or len(data) + len(block) > 16384:
                    raise BrowserProxyError()
                data.extend(block)
            head, _, prefix = bytes(data).partition(b'\r\n\r\n')
            lines = head.decode('ascii').split('\r\n')
            status = int(lines[0].split(' ')[1])
            headers = {name.lower(): value.strip() for name, _, value in (line.partition(':') for line in lines[1:])}
            if status != 101:
                raise BrowserProxyError('browser_connection_rejected', status if status in (400, 403, 409, 429) else 503)
            expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            protocol = headers.get('sec-websocket-protocol')
            if (headers.get('sec-websocket-accept') != expected
                    or protocol not in (None, 'binary')
                    or headers.get('sec-websocket-extensions')):
                raise BrowserProxyError()
            handler.send_response_only(101)
            handler.send_header('Upgrade', 'websocket')
            handler.send_header('Connection', 'Upgrade')
            handler.send_header('Sec-WebSocket-Accept', expected)
            if protocol:
                handler.send_header('Sec-WebSocket-Protocol', protocol)
            handler.end_headers()
            handler.wfile.flush()
            upgraded = True
            self._relay(handler, upstream, device, stop, prefix)
        except (OSError, ValueError, UnicodeError):
            if not upgraded:
                raise BrowserProxyError() from None
        finally:
            handler.close_connection = True
            if upstream is not None:
                upstream.close()
            with self._lock:
                self._streams.pop(identifier, None)

    def _relay(self, handler, upstream, device, stop, prefix):
        client = handler.connection
        client.setblocking(False)
        upstream.setblocking(False)
        # BaseHTTPRequestHandler may already have buffered the first client
        # frame together with the HTTP request. Drain that buffer exactly once.
        initial = handler.rfile.read1(65536) or b''
        pending = {client: bytearray(prefix), upstream: bytearray(initial)}
        peers = {client: upstream, upstream: client}
        check_at = 0.0
        ending_at = None
        while not stop.is_set() and not self._stopping.is_set():
            if time.monotonic() >= check_at:
                if device != 'local-owner' and not handler.server.office.store.device_active(device):
                    return
                check_at = time.monotonic() + 1.0
            if ending_at is not None and (not any(pending.values()) or time.monotonic() >= ending_at):
                return
            readable = [] if ending_at is not None else [s for s, peer in peers.items() if len(pending[peer]) < MAX_BUFFER]
            writable = [s for s in peers if pending[s]]
            reads, writes, _ = select.select(readable, writable, [], .25)
            for sock in reads:
                try:
                    chunk = sock.recv(min(65536, MAX_BUFFER - len(pending[peers[sock]])))
                except BlockingIOError:
                    continue
                if not chunk:
                    # Preserve an already-buffered RFC6455 close frame on a
                    # normal EOF. Revocation/shutdown still discard buffers
                    # immediately. Never keep a dying stream alive indefinitely.
                    ending_at = time.monotonic() + 1.0
                    continue
                pending[peers[sock]].extend(chunk)
            for sock in writes:
                if stop.is_set() or self._stopping.is_set():
                    return
                try:
                    count = sock.send(pending[sock])
                except BlockingIOError:
                    continue
                except (BrokenPipeError, ConnectionResetError):
                    if ending_at is None:
                        raise
                    pending[sock].clear()
                    continue
                del pending[sock][:count]
