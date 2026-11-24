"""Opt-in real Google Chrome checks against a local synthetic account fixture.

NEKO_BROWSER_E2E=1 enables this suite and makes missing Chrome/SDK a failure.
No real sites, account credentials, screenshots, or browser profiles are uploaded.
"""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

OFFICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OFFICE))
from browser_workspace import BrowserWorkspaceError, PlaywrightChromeProvider
from browser_workspace.profiles import ProfileLease


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        if self.path == '/sign-in':
            self.send_header('Set-Cookie', 'test_session=synthetic; Max-Age=3600; HttpOnly; SameSite=Strict; Path=/')
        elif self.path == '/sign-out':
            self.send_header('Set-Cookie', 'test_session=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/')
        self.end_headers()
        if self.path == '/sign-in':
            body = '''<title>pending</title><script>
localStorage.setItem('test_owner', 'synthetic');
const req = indexedDB.open('neko-fixture', 1);
req.onupgradeneeded = () => req.result.createObjectStore('markers');
req.onsuccess = () => {
  const db = req.result;
  const tx = db.transaction('markers', 'readwrite');
  tx.objectStore('markers').put('synthetic', 'owner');
  tx.oncomplete = () => { db.close(); document.title = 'fixture-ready'; };
};
</script>'''
        elif self.path == '/sign-out':
            body = '''<title>signed-out</title><script>
localStorage.removeItem('test_owner'); indexedDB.deleteDatabase('neko-fixture');
</script>'''
        elif 'test_session=synthetic' in self.headers.get('Cookie', ''):
            body = '''<title>pending</title><script>
if (localStorage.getItem('test_owner') !== 'synthetic') {
  document.title = 'login-required';
} else {
  const req = indexedDB.open('neko-fixture', 1);
  req.onupgradeneeded = () => req.result.createObjectStore('markers');
  req.onsuccess = () => {
    const db = req.result;
    const read = db.transaction('markers').objectStore('markers').get('owner');
    read.onsuccess = () => {
      document.title = read.result === 'synthetic' ? 'fixture-ready' : 'login-required';
      db.close();
    };
  };
}
</script>'''
        else:
            body = '<title>login-required</title>'
        self.wfile.write(body.encode())


CHILD = r'''
import asyncio, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from browser_workspace import PlaywrightChromeProvider

async def run():
    browser = PlaywrightChromeProvider(Path(sys.argv[2]), sys.argv[3],
                                       headless=(sys.argv[5] == '1'))
    try:
        await browser.start()
        result = await browser.navigate(sys.argv[4])
        for _ in range(100):
            if result.title != 'pending':
                break
            await asyncio.sleep(.05)
            result = await browser.current()
        print(json.dumps({'title': result.title}))
    finally:
        await browser.close()
asyncio.run(run())
'''


@unittest.skipUnless(os.environ.get('NEKO_BROWSER_E2E') == '1',
                     'Set NEKO_BROWSER_E2E=1 with Google Chrome installed')
class ChromePersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'profiles'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f'http://127.0.0.1:{self.server.server_port}'
        self.headless = os.environ.get('NEKO_BROWSER_HEADLESS', '1')

    def visit_in_fresh_process(self, profile, path):
        result = subprocess.run(
            [sys.executable, '-I', '-c', CHILD, str(OFFICE), str(self.root),
             profile, self.url + path, self.headless],
            capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)['title']

    def test_cookie_localstorage_and_indexeddb_survive_process_recreation(self):
        self.assertEqual(self.visit_in_fresh_process('owner-a', '/sign-in'), 'fixture-ready')
        self.assertEqual(self.visit_in_fresh_process('owner-a', '/account'), 'fixture-ready')
        self.assertEqual(self.visit_in_fresh_process('owner-b', '/account'), 'login-required')
        self.assertEqual(self.visit_in_fresh_process('owner-a', '/account'), 'fixture-ready')
        self.assertEqual(self.visit_in_fresh_process('owner-a', '/sign-out'), 'signed-out')
        self.assertEqual(self.visit_in_fresh_process('owner-a', '/account'), 'login-required')

    def test_real_chrome_keeps_exclusive_profile_and_lifecycle(self):
        async def run():
            first = PlaywrightChromeProvider(self.root, 'owner', headless=self.headless == '1')
            second = PlaywrightChromeProvider(self.root, 'owner', headless=self.headless == '1')
            try:
                await first.start()
                with self.assertRaises(BrowserWorkspaceError) as duplicate:
                    await first.start()
                self.assertEqual(duplicate.exception.code, 'workspace_already_started')
                with self.assertRaises(BrowserWorkspaceError) as blocked:
                    await second.start()
                self.assertEqual(blocked.exception.code, 'profile_in_use')
                self.assertEqual((await first.navigate(self.url + '/account')).title, 'login-required')
                await first.close()
                await second.start()
                self.assertEqual((await second.navigate(self.url + '/account')).title, 'login-required')
            finally:
                await first.close()
                await second.close()
        asyncio.run(run())

    def test_launch_failure_releases_profile_and_hides_diagnostics(self):
        async def run():
            # A headed Chrome with an unusable display must fail without an
            # unsafe no-sandbox fallback or raw launch diagnostics in the error.
            old = os.environ.get('DISPLAY')
            os.environ['DISPLAY'] = ':65534'
            browser = PlaywrightChromeProvider(self.root, 'broken-display')
            try:
                with self.assertRaises(BrowserWorkspaceError) as error:
                    await browser.start()
                self.assertEqual(str(error.exception), 'chrome_launch_failed')
            finally:
                await browser.close()
                if old is None:
                    os.environ.pop('DISPLAY', None)
                else:
                    os.environ['DISPLAY'] = old
            lease = ProfileLease(self.root, 'broken-display')
            try:
                lease.acquire()
            finally:
                lease.release()
        asyncio.run(run())


if __name__ == '__main__':
    unittest.main()
