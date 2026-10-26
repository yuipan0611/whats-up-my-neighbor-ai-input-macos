"""The broker's own hand on Chrome over the DevTools protocol (ADR-002 4.2, G3).

Only fixed operations: list interactive targets, read visible text, screenshot, navigate,
click a snapshotted link. The scripts below are part of this file, never supplied by the
agent. Python standard library only."""
from __future__ import annotations
import base64
import json
import os
import socket
import struct
import time
import urllib.request
from urllib.parse import urlsplit

from browser_actions import BrowserFailed, BrowserUnknown

SNAPSHOT_JS = r'''(() => {
  const nodes = [...document.querySelectorAll('a[href], button, input, textarea, select, [role=button], [role=link]')];
  return nodes.slice(0, 200).map((el, i) => {
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'button' ? 'button'
      : (tag === 'input' && ['submit', 'button', 'reset'].includes(el.type)) ? 'button' : 'textbox');
    const name = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.name || '').trim().slice(0, 120);
    return {index: i, role, name, href: tag === 'a' ? el.href : ''};
  });
})()'''
TEXT_JS = "({title: document.title, text: (document.body ? document.body.innerText : '').slice(0, 20000)})"
CLICK_FN = 'function () { this.click(); return true; }'
DESCRIBE_FN = "function () { return {tag: this.tagName.toLowerCase(), href: this.tagName === 'A' ? this.href : ''}; }"
TARGET_JS = "document.querySelectorAll('a[href], button, input, textarea, select, [role=button], [role=link]')[%d]"


class WebSocket:
    """Just enough RFC 6455 for a local DevTools endpoint: masked frames out, text frames in."""
    def __init__(self, url, timeout=15):
        parts = urlsplit(url)
        self.sock = socket.create_connection((parts.hostname, parts.port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET {parts.path} HTTP/1.1\r\nHost: {parts.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                           f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise BrowserUnknown('devtools closed the handshake')
            head += chunk
        if b' 101 ' not in head.split(b'\r\n', 1)[0]:
            raise BrowserFailed('devtools refused the connection')
        self.buffer = head.split(b'\r\n\r\n', 1)[1]

    def send(self, text):
        data, mask = text.encode(), os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('!H', n) if n < 65536
                                else bytes([0x80 | 127]) + struct.pack('!Q', n))
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise BrowserUnknown('devtools connection closed')
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def recv(self):
        message = b''
        while True:
            first, second = self.read(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack('!H', self.read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.read(8))[0]
            payload = self.read(length)
            if first & 0x0F == 0x8:
                raise BrowserUnknown('devtools closed the connection')
            if first & 0x0F in (0x1, 0x0):
                message += payload
                if first & 0x80:
                    return json.loads(message)

    def close(self):
        self.sock.close()


class ChromeBrowser:
    """One page target of a Chrome started with --remote-debugging-port, as the broker's browser."""
    def __init__(self, endpoint, screenshot_dir, timeout=20):
        self.endpoint, self.screenshot_dir, self.timeout = endpoint.rstrip('/'), screenshot_dir, timeout
        self.ids = 0

    def page(self):
        with urllib.request.urlopen(self.endpoint + '/json/list', timeout=5) as r:
            pages = [p for p in json.load(r) if p.get('type') == 'page']
        if not pages:
            raise BrowserFailed('no page open')
        return pages[0]

    def call(self, ws, method, params=None):
        self.ids += 1
        ws.send(json.dumps({'id': self.ids, 'method': method, 'params': params or {}}))
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            message = ws.recv()
            if message.get('id') == self.ids:
                if 'error' in message:
                    raise BrowserFailed(message['error'].get('message', 'devtools error')[:200])
                return message['result']
        raise BrowserUnknown('devtools timed out')

    def session(self):
        page = self.page()
        try:
            return page, WebSocket(page['webSocketDebuggerUrl'], self.timeout)
        except OSError as e:
            raise BrowserUnknown(e.__class__.__name__)

    def world(self, ws):
        """A fresh JavaScript world on the main frame: the page's own overrides of DOM methods do not reach it."""
        frame = self.call(ws, 'Page.getFrameTree')['frameTree']['frame']['id']
        return self.call(ws, 'Page.createIsolatedWorld', {'frameId': frame, 'worldName': 'neko-broker'})['executionContextId']

    def evaluate(self, ws, expression, context=None, by_value=True):
        params = {'expression': expression, 'returnByValue': by_value, 'contextId': context or self.world(ws)}
        result = self.call(ws, 'Runtime.evaluate', params)
        if 'exceptionDetails' in result:
            raise BrowserFailed('page script failed')
        return result['result'].get('value')

    def generation(self, tab_id):
        page, ws = self.session()
        try:
            if page['id'] != tab_id:
                return 'other-tab'
            return self.call(ws, 'Page.getFrameTree')['frameTree']['frame']['loaderId']
        finally:
            ws.close()

    def execute(self, tool, args, target):
        page, ws = self.session()
        try:
            if tool == 'take_snapshot':
                generation = self.call(ws, 'Page.getFrameTree')['frameTree']['frame']['loaderId']
                items = self.evaluate(ws, SNAPSHOT_JS) or []
                return {'tab_id': page['id'], 'generation': generation,
                        'targets': {f"e{i['index']}": {'role': i['role'], 'name': i['name'], 'href': i['href'], 'index': i['index']} for i in items}}
            if tool == 'read_text':
                return self.evaluate(ws, TEXT_JS)
            if tool == 'take_screenshot':
                data = base64.b64decode(self.call(ws, 'Page.captureScreenshot', {'format': 'png'})['data'])
                os.makedirs(self.screenshot_dir, mode=0o700, exist_ok=True)
                name = f'shot-{int(time.time() * 1000)}.png'
                with open(os.path.join(self.screenshot_dir, name), 'xb') as f:
                    f.write(data)
                return {'screenshot': name, 'bytes': len(data)}
            if tool == 'navigate':
                self.call(ws, 'Page.navigate', {'url': args['url']})
                self.wait_loaded(ws)
                return {'navigated': True}
            if tool == 'click':
                if target.get('role') != 'link':
                    raise BrowserFailed('only snapshotted links are clicked here')
                context = self.world(ws)
                node = self.call(ws, 'Runtime.evaluate', {'expression': TARGET_JS % int(target['index']), 'contextId': context})['result']
                if not node.get('objectId'):
                    raise BrowserFailed('target is gone')
                seen = self.call(ws, 'Runtime.callFunctionOn', {'objectId': node['objectId'], 'functionDeclaration': DESCRIBE_FN,
                                                                 'returnByValue': True})['result']['value']
                href = urlsplit(seen['href'])
                if seen['tag'] != 'a' or f'{href.scheme}://{href.netloc}{href.path}' != target.get('href'):
                    raise BrowserFailed('the page changed under the snapshot')  # same document, different element
                self.call(ws, 'Runtime.callFunctionOn', {'objectId': node['objectId'], 'functionDeclaration': CLICK_FN})
                self.wait_loaded(ws)
                return {'clicked': True}
            raise BrowserFailed('tool not implemented in the broker')
        finally:
            ws.close()

    def wait_loaded(self, ws):
        deadline = time.monotonic() + self.timeout
        time.sleep(0.2)
        while time.monotonic() < deadline:
            try:
                if self.evaluate(ws, 'document.readyState') == 'complete':
                    return
            except BrowserFailed:
                pass  # mid-navigation the old context is gone
            time.sleep(0.2)
        raise BrowserUnknown('page did not finish loading')
