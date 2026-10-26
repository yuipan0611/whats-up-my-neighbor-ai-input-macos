"""G3 against a real Chrome on this machine: a throwaway profile and a synthetic local site.

Real Chrome (headless), fake everything else: no accounts, no real sites, fictional data.
Skipped when Google Chrome is not installed. It still covers the broker path only (G0)."""
import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_office import app, FakeModel

sys.path.insert(0, str(Path(__file__).parents[1]))
import browser_actions as ba  # noqa: E402
import browser_cdp  # noqa: E402
from test_browser_adapter import HANDS, worker_mod  # noqa: E402

FAKE_CODEX = r'''#!{python}
import json, os, re, subprocess, sys
args = sys.argv[1:]
output, cwd = args[args.index('--output-last-message') + 1], args[args.index('--cd') + 1]
config = dict(args[i + 1][len('mcp_servers.browser.'):].split('=', 1) for i, a in enumerate(args)
              if a == '-c' and args[i + 1].startswith('mcp_servers.browser.'))
url = re.search(r'http://127\.0\.0\.1:\d+/index\.html', sys.stdin.read()).group(0)
server = subprocess.Popen([json.loads(config['command'])] + json.loads(config['args']), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def call(i, name, arguments):
    server.stdin.write(json.dumps({{'jsonrpc': '2.0', 'id': i, 'method': 'tools/call', 'params': {{'name': name, 'arguments': arguments}}}}) + '\n')
    server.stdin.flush()
    return json.loads(server.stdout.readline())['result']
seen = {{'open': call(1, 'open_url', {{'url': url}})}}
snap = json.loads(call(2, 'observe_page', {{}})['content'][0]['text'])
ref = {{t['name']: r for r, t in snap['targets'].items()}}
seen['logout'] = call(3, 'click', {{'snapshot_id': snap['snapshot_id'], 'target_ref': ref['登出']}})
seen['docs'] = call(4, 'click', {{'snapshot_id': snap['snapshot_id'], 'target_ref': ref['說明']}})
seen['read'] = call(5, 'read_page', {{}})
server.stdin.close(); server.wait(10)
with open(os.path.join(cwd, 'seen.json'), 'w') as f:
    json.dump(seen, f, ensure_ascii=False)
with open(output, 'w') as f:
    json.dump({{'outcome': 'incomplete', 'content': '登出要你親手按。', 'reason': '需要使用者'}}, f)
'''

CHROME = next((p for p in ('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome',
                           '/opt/google/chrome/chrome') if os.path.exists(p)), None)
PAGES = {
    '/index.html': '''<!doctype html><meta charset="utf-8"><title>合成首頁</title>
<script>document.querySelectorAll = () => [];</script>
<h1>合成首頁</h1><p>這是虛構的測試網站。</p>
<a href="/docs.html?ref=home">說明</a> <a href="/logout">登出</a>
<form method="post" action="/delete"><button>刪除帳號</button></form>
<input name="q" placeholder="搜尋">''',
    '/docs.html': '<!doctype html><meta charset="utf-8"><title>說明</title><p>說明頁內容</p>',
    '/swap.html': '''<!doctype html><meta charset="utf-8"><title>會變的頁面</title>
<a href="/docs.html">說明</a>
<script>setTimeout(() => document.body.insertAdjacentHTML('afterbegin', '<a href="/logout">登出</a>'), 1500);</script>''',
}


class Site(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        Site.seen.append(('GET', self.path.split('?')[0]))
        body = PAGES.get(self.path.split('?')[0])
        self.send_response(200 if body else 404)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write((body or 'not found').encode())

    def do_POST(self):
        Site.seen.append(('POST', self.path))
        self.send_response(200); self.end_headers()

    def log_message(self, *a):
        pass


@unittest.skipUnless(CHROME, 'Google Chrome is not installed')
class RealChromeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.mkdtemp(prefix='neko-g3-')
        cls.site = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Site)
        threading.Thread(target=cls.site.serve_forever, daemon=True).start()
        cls.base = f'http://127.0.0.1:{cls.site.server_address[1]}'
        profile = os.path.join(cls.temp, 'profile')
        cls.chrome = subprocess.Popen([CHROME, '--headless=new', '--remote-debugging-port=0', f'--user-data-dir={profile}',
                                       '--no-first-run', '--no-default-browser-check', '--disable-extensions', 'about:blank'],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        port_file = Path(profile) / 'DevToolsActivePort'
        for _ in range(100):
            if port_file.exists() and port_file.read_text().strip():
                break
            time.sleep(0.1)
        cls.endpoint = f'http://127.0.0.1:{port_file.read_text().split()[0]}'

    @classmethod
    def tearDownClass(cls):
        cls.chrome.terminate(); cls.chrome.wait(10)
        cls.site.shutdown(); cls.site.server_close()
        shutil.rmtree(cls.temp, ignore_errors=True)

    def setUp(self):
        self.data = tempfile.TemporaryDirectory()
        self.store = app.Store(Path(self.data.name) / 'data')
        self.shots = Path(self.data.name) / 'shots'
        self.broker = ba.Broker(self.store, browser_cdp.ChromeBrowser(self.endpoint, str(self.shots)))
        self.office = app.Office(self.store, FakeModel(), broker=self.broker)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': f'合成任務：看 {self.base}/index.html', 'executor': 'hands'})['task']
        self.claimed = self.store.claim_hands()
        Site.seen.clear()

    def tearDown(self):
        self.data.cleanup()

    def act(self, tool, args=None, **extra):
        with self.store.connect() as c:
            epoch = c.execute("SELECT control_epoch FROM browser_sessions WHERE id='cat-chrome'").fetchone()[0]
        return self.broker.act({'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': str(uuid.uuid4()),
                                'control_epoch': epoch, 'tool': tool, 'args': args or {}, **extra})

    def snapshot(self):
        status, body = self.act('take_snapshot')
        self.assertEqual((status, body['outcome']), (200, 'succeeded'), body)
        return body['result']

    def ref(self, snap, name):
        return next(ref for ref, t in snap['targets'].items() if t['name'] == name)

    def test_read_navigate_and_click_a_link_on_real_chrome(self):
        self.assertEqual(self.act('navigate', {'url': self.base + '/index.html'})[1]['outcome'], 'succeeded')
        snap = self.snapshot()
        names = {t['name']: t['role'] for t in snap['targets'].values()}
        self.assertEqual({k: names.get(k) for k in ('說明', '登出', '刪除帳號', '搜尋')},
                         {'說明': 'link', '登出': 'link', '刪除帳號': 'button', '搜尋': 'textbox'})  # page override did not hide them
        self.assertIn('合成首頁', self.act('read_text')[1]['result']['title'])
        status, body = self.act('click', snapshot_id=snap['snapshot_id'], target_ref=self.ref(snap, '說明'))
        self.assertEqual(body['outcome'], 'succeeded', body)
        self.assertIn('說明頁內容', self.act('read_text')[1]['result']['text'])
        status, body = self.act('click', snapshot_id=snap['snapshot_id'], target_ref=self.ref(snap, '說明'))
        self.assertEqual((status, body['reason_code']), (409, 'stale_target'))  # the document changed
        shot = self.act('take_screenshot')[1]['result']
        self.assertTrue((self.shots / shot['screenshot']).read_bytes().startswith(b'\x89PNG'))

    def test_effects_wait_for_a_person_and_never_reach_the_site(self):
        self.act('navigate', {'url': self.base + '/index.html'})
        snap = self.snapshot()
        for name in ('登出', '刪除帳號'):
            status, body = self.act('click', snapshot_id=snap['snapshot_id'], target_ref=self.ref(snap, name))
            self.assertEqual((body['decision'], body['outcome']), ('needs_human', 'not_dispatched'), name)
        status, body = self.act('type_text', {'text': '虛構關鍵字'}, snapshot_id=snap['snapshot_id'], target_ref=self.ref(snap, '搜尋'))
        self.assertEqual(body['decision'], 'needs_human')
        for tool in ('evaluate_script', 'take_heapsnapshot'):
            self.assertEqual(self.act(tool)[0], 403)
        self.assertEqual(self.act('navigate', {'url': 'javascript:document.forms[0].submit()'})[0], 403)
        time.sleep(0.5)
        self.assertNotIn(('GET', '/logout'), Site.seen)
        self.assertNotIn(('POST', '/delete'), Site.seen)

    def test_click_checks_the_element_when_the_same_document_changes(self):
        self.act('navigate', {'url': self.base + '/swap.html'})
        snap = self.snapshot()
        ref = self.ref(snap, '說明')
        time.sleep(2.5)  # the page puts another link at the snapshotted index, without a new document
        status, body = self.act('click', snapshot_id=snap['snapshot_id'], target_ref=ref)
        self.assertEqual((body['decision'], body['outcome']), ('allow', 'failed'), body)
        time.sleep(0.5)
        self.assertNotIn(('GET', '/logout'), Site.seen)

    def test_the_cdp_hand_clicks_links_only(self):
        browser = browser_cdp.ChromeBrowser(self.endpoint, str(self.shots))
        browser.execute('navigate', {'url': self.base + '/index.html'}, None)
        snap = browser.execute('take_snapshot', {}, None)
        button = next(t for t in snap['targets'].values() if t['name'] == '刪除帳號')
        with self.assertRaises(ba.BrowserFailed):
            browser.execute('click', {}, button)  # policy already sends buttons to a person; this is the second wall
        time.sleep(0.5)
        self.assertNotIn(('POST', '/delete'), Site.seen)


    def test_worker_adapter_broker_and_chrome_end_to_end(self):
        root = Path(self.data.name)
        worker_socket = root / 'w' / 'worker.sock'
        server = app.Server(0, self.office, worker_socket=worker_socket)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            fake = root / 'fake-codex'
            fake.write_text(FAKE_CODEX.format(python=sys.executable)); fake.chmod(0o755)
            worker = worker_mod.Worker(worker_mod.Office(worker_socket), fake, root / 'codex-home', root / 'ws',
                                       browser=('/usr/bin/false', []), adapter=HANDS / 'browser_adapter.py')
            worker.HEARTBEAT_SECONDS, worker.FLUSH_SECONDS = 0.3, 0.1
            task = self.task
            self.assertEqual(worker.handle(self.claimed), 'incomplete')
        finally:
            server.shutdown(); server.server_close(); thread.join()
        seen = json.loads((root / 'ws' / task['id'] / 'attempt-1' / 'seen.json').read_text())
        self.assertFalse(seen['open']['isError'])
        self.assertIn('使用者親手做', seen['logout']['content'][0]['text'])
        self.assertFalse(seen['docs']['isError'], seen['docs'])
        self.assertIn('說明頁內容', seen['read']['content'][0]['text'])
        self.assertNotIn(('GET', '/logout'), Site.seen)
        self.assertIn(('GET', '/docs.html'), Site.seen)
        with self.store.connect() as c:
            rows = c.execute("SELECT decision FROM browser_audit_events WHERE task_id=? AND event_type='decision' ORDER BY seq", (task['id'],)).fetchall()
        self.assertEqual([r[0] for r in rows], ['allow', 'allow', 'needs_human', 'allow', 'allow'])


if __name__ == '__main__':
    unittest.main()
