"""Opt-in real Chrome + TigerVNC + noVNC + authenticated Office-path checks.

All pages, keyboard input, and account markers are synthetic. No external site
or production profile is used. Both Chrome processes retain their sandbox.
"""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

OFFICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OFFICE))
from browser_workspace import PlaywrightChromeProvider
from browser_workspace.controller import BrowserController, ControllerError
from test_office import app as office_app, FakeModel


class RemoteFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Set-Cookie', 'remote_session=synthetic; SameSite=Strict; Path=/')
        self.end_headers()
        self.wfile.write(b'''<!doctype html><title>Synthetic remote workspace</title>
<style>body{background:#fcf7ed;color:#143d31;font:28px sans-serif;padding:50px}input{font:32px sans-serif;width:600px;padding:20px}</style>
<h1>Same Chrome, one owner</h1><input id="remote" autofocus aria-label="Synthetic input">
<p id="marker">Synthetic session only</p><script>
localStorage.setItem('synthetic-owner', 'preserved');
window.pointerEvents=0; window.syntheticKeys=[];
document.addEventListener('pointerdown',()=>window.pointerEvents++);
document.addEventListener('keydown',event=>syntheticKeys.push(event.key));
</script>''')


@unittest.skipUnless(os.environ.get('NEKO_VIEWER_E2E') == '1',
                     'Set NEKO_VIEWER_E2E=1 with sandboxed Chrome, Xvfb and TigerVNC installed')
class ViewerE2E(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from playwright.async_api import async_playwright
        from browser_workspace.desktop import DesktopSession
        from browser_workspace.gateway import create_app, serve_unix

        self.temp = tempfile.TemporaryDirectory(prefix='neko-viewer-')
        self.root = Path(self.temp.name)
        self.original_env = {key: os.environ.get(key) for key in ('DISPLAY', 'XAUTHORITY')}
        self.desktop = DesktopSession(self.root / 'run')
        self.gateway = self.viewer = self.pw = self.server = self.fixture = None
        self.controller = None
        self.addAsyncCleanup(self.cleanup)
        await self.desktop.start()
        os.environ.update(self.desktop.environment())
        self.provider = PlaywrightChromeProvider(self.root / 'profiles', 'synthetic', headless=False)
        self.controller = BrowserController(self.provider)
        await self.controller.start()
        self.gateway = await serve_unix(create_app(
            self.controller, self.desktop.view_socket, self.desktop.control_socket), self.root / 'run/gateway.sock')

        self.fixture = ThreadingHTTPServer(('127.0.0.1', 0), RemoteFixture)
        self.fixture_thread = threading.Thread(target=self.fixture.serve_forever, daemon=True)
        self.fixture_thread.start()
        self.fixture_url = f'http://127.0.0.1:{self.fixture.server_port}/'
        lease = await self.controller.takeover('local-owner')
        state = await self.controller.release('local-owner', lease['epoch'])
        await self.controller.agent_navigate(state['epoch'], self.fixture_url)
        self.remote_page = self.provider._page  # Test fixture only; never an Office/LLM API.
        await self.remote_page.locator('#remote').focus()

        office = office_app.Office(office_app.Store(self.root / 'office-data'), FakeModel())
        self.server = office_app.Server(0, office, browser_socket=self.root / 'run/gateway.sock')
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.pw = await async_playwright().start()
        self.viewer = await self.pw.chromium.launch(channel='chrome', headless=True, chromium_sandbox=True)

    async def cleanup(self):
        if self.viewer:
            await self.viewer.close()
        if self.pw:
            await self.pw.stop()
        if self.server:
            await asyncio.to_thread(self.server.shutdown)
            self.server.server_close()
            self.server_thread.join(timeout=2)
        if self.gateway:
            await self.gateway.close()
        elif self.controller:
            await self.controller.close()
        await self.desktop.close()
        if self.fixture:
            await asyncio.to_thread(self.fixture.shutdown)
            self.fixture.server_close()
            self.fixture_thread.join(timeout=2)
        for key, value in self.original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.temp.cleanup()

    async def state_until(self, predicate):
        for _ in range(100):
            state = await self.controller.state('local-owner')
            if predicate(state):
                return state
            await asyncio.sleep(.05)
        self.fail('Browser state transition did not complete')

    async def connected(self, page, mode):
        await page.locator(f'#browser-app[data-stream-mode="{mode}"][data-connection="connected"]').wait_for(timeout=15000)

    async def test_real_view_only_takeover_disconnect_resume_and_mobile_layout(self):
        # The real application page must render and connect through Office's
        # standard-library proxy, not directly to the private gateway.
        page = await self.viewer.new_page(viewport={'width': 1366, 'height': 1000})
        errors = []
        page.on('pageerror', lambda error: errors.append(type(error).__name__))
        await page.goto(self.base + '/browser/')
        self.assertEqual((await page.request.get(self.base + '/browser/notices.txt')).status, 200)
        await self.connected(page, 'view')
        canvas = page.locator('#rfb-screen canvas')
        await canvas.wait_for()
        self.assertGreater(await canvas.evaluate('c => c.width * c.height'), 100000)
        # Actual decoded RFB pixels, rather than only a successful WebSocket.
        await page.wait_for_function('''() => {
          const c=document.querySelector('#rfb-screen canvas');
          const p=c?.getContext('2d').getImageData(0,0,c.width,c.height).data;
          if(!p)return false; const colors=new Set();
          for(let i=0;i<p.length;i+=160)colors.add(`${p[i]},${p[i+1]},${p[i+2]}`);
          return colors.size>20;
        }''', timeout=15000)
        self.assertFalse(await page.locator('#takeover').is_disabled())

        # An adversarial authenticated viewer ignores the UI's viewOnly flag.
        # TigerVNC's view socket must still reject real RFB keyboard/pointer.
        adversary = await self.viewer.new_page(viewport={'width': 1280, 'height': 900})
        await adversary.route('**/browser/viewer.js', lambda route: route.fulfill(body='', content_type='text/javascript'))
        await adversary.goto(self.base + '/browser/')
        initial = await self.controller.state('local-owner')
        await adversary.evaluate('''async ({epoch}) => {
          const {default:RFB}=await import('/browser/novnc.js');
          const host=document.createElement('div'); host.style.height='700px';
          document.body.replaceChildren(host);
          window.syntheticRfb=new RFB(host, `ws://${location.host}/api/browser/ws?mode=view&epoch=${epoch}`);
          syntheticRfb.viewOnly=false; syntheticRfb.scaleViewport=true;
          await new Promise((resolve,reject)=>{
            syntheticRfb.addEventListener('connect',resolve,{once:true});
            syntheticRfb.addEventListener('disconnect',()=>reject(new Error('fixture connection failed')),{once:true});
          });
        }''', {'epoch': initial['epoch']})
        await adversary.evaluate("syntheticRfb.sendKey(0x61,'KeyA')")
        await adversary.locator('canvas').click(position={'x': 100, 'y': 200})
        await asyncio.sleep(.3)  # Allow the real VNC/X11 input path to execute.
        self.assertEqual(await self.remote_page.locator('#remote').input_value(), '')
        self.assertEqual(await self.remote_page.evaluate('pointerEvents'), 0)

        await page.bring_to_front()
        await page.locator('#takeover').click()
        await self.connected(page, 'control')
        state = await self.controller.state('local-owner')
        self.assertTrue(state['private'])
        self.assertTrue(state['control_connected'])
        with self.assertRaises(ControllerError):
            await self.controller.agent_current(initial['epoch'])
        await adversary.wait_for_function("!syntheticRfb._rfbConnectionState || syntheticRfb._rfbConnectionState === 'disconnected'")

        # A second control connection from the same paired device is refused.
        rejected = await page.evaluate('''epoch => new Promise(resolve => {
          const ws=new WebSocket(`ws://${location.host}/api/browser/ws?mode=control&epoch=${epoch}`,'binary');
          ws.onopen=()=>{ws.close();resolve(false)};
          ws.onerror=()=>resolve(true);
        })''', state['epoch'])
        self.assertTrue(rejected)
        self.assertTrue((await self.controller.state('local-owner'))['control_connected'])

        # Input through the actual UI lands in that same headed Chrome/profile.
        # CDP DOM focus in setUp does not set X11 window focus on a bare Xvfb.
        # A human first taps the visible remote field, then opens the keyboard.
        point = await self.remote_page.evaluate('''() => {
          const r=document.querySelector('#remote').getBoundingClientRect();
          return {x:screenX+(outerWidth-innerWidth)/2+r.x+r.width/2,
                  y:screenY+(outerHeight-innerHeight)+r.y+r.height/2};
        }''')
        control_canvas = page.locator('#rfb-screen canvas')
        bounds = await control_canvas.bounding_box()
        dimensions = await control_canvas.evaluate('c => ({w:c.width,h:c.height})')
        await control_canvas.click(position={'x': point['x'] * bounds['width'] / dimensions['w'],
                                             'y': point['y'] * bounds['height'] / dimensions['h']})
        await self.remote_page.wait_for_function('pointerEvents > 0')
        await self.remote_page.wait_for_function("document.activeElement.id === 'remote' && document.hasFocus()")
        await page.locator('#keyboard-toggle').click()
        keyboard = page.locator('#keyboard-input')
        await keyboard.press('a')
        self.assertEqual(await keyboard.input_value(), '_' * 32)
        try:
            await self.remote_page.wait_for_function("document.querySelector('#remote').value === 'a'")
        except Exception:
            # This fixture contains only test-generated text. Never add this
            # diagnostic to the application or a real-account acceptance run.
            diagnostic = await self.remote_page.evaluate('''() => ({
              value:document.querySelector('#remote').value,
              focused:document.activeElement.id, pointerEvents, keys:syntheticKeys
            })''')
            self.fail('Synthetic keyboard fixture: ' + json.dumps(diagnostic))
        self.assertEqual(await self.remote_page.evaluate("localStorage.getItem('synthetic-owner')"), 'preserved')
        self.assertIn('remote_session=synthetic', await self.remote_page.evaluate('document.cookie'))

        # Responsive rendering is checked in Chromium; a physical iPhone and
        # Safari IME remain a separate acceptance check.
        await page.set_viewport_size({'width': 390, 'height': 844})
        self.assertTrue(await page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
        self.assertTrue(await page.locator('#takeover').is_visible())
        self.assertTrue(await page.locator('#release').is_visible())

        # Closing the controller page must preserve the Chrome process and
        # private hold, and reconnecting must never automatically reclaim it.
        await page.close()
        paused = await self.state_until(lambda s: s['mode'] == 'paused' and s['private'])
        self.assertFalse(paused['control_connected'])
        self.assertEqual(await self.remote_page.locator('#remote').input_value(), 'a')
        replacement = await self.viewer.new_page(viewport={'width': 390, 'height': 844})
        await replacement.goto(self.base + '/browser/')
        await replacement.locator('#browser-app[data-mode="paused"][data-private="true"]').wait_for()
        self.assertEqual(await replacement.locator('#rfb-screen canvas').count(), 0)
        await replacement.locator('#reconnect').click()
        self.assertFalse((await self.controller.state('local-owner'))['control_connected'])
        await replacement.locator('#takeover').click()
        await self.connected(replacement, 'control')
        await replacement.locator('#release').click()
        await self.connected(replacement, 'view')
        released = await self.controller.state('local-owner')
        self.assertEqual(released['mode'], 'agent')
        self.assertFalse(released['private'])
        self.assertFalse(released['control_connected'])
        snapshot = await self.controller.agent_current(released['epoch'])
        self.assertEqual(snapshot.title, 'Synthetic remote workspace')

        # Repeat the hostile view input AFTER proving native focus and working
        # control input. Otherwise an unfocused window could make the first
        # view-only keyboard assertion pass for the wrong reason.
        pointer_count = await self.remote_page.evaluate('pointerEvents')
        await adversary.bring_to_front()
        await adversary.evaluate('''async epoch => {
          const {default:RFB}=await import('/browser/novnc.js');
          const host=document.body.firstElementChild;
          syntheticRfb.disconnect(); host.replaceChildren();
          window.syntheticRfb=new RFB(host, `ws://${location.host}/api/browser/ws?mode=view&epoch=${epoch}`);
          syntheticRfb.viewOnly=false; syntheticRfb.scaleViewport=true;
          await new Promise((resolve,reject)=>{
            syntheticRfb.addEventListener('connect',resolve,{once:true});
            syntheticRfb.addEventListener('disconnect',()=>reject(new Error('fixture connection failed')),{once:true});
          });
          syntheticRfb.sendKey(0x62,'KeyB');
        }''', released['epoch'])
        await adversary.locator('canvas').click(position={'x': 100, 'y': 200})
        await asyncio.sleep(.3)
        self.assertEqual(await self.remote_page.locator('#remote').input_value(), 'a')
        self.assertEqual(await self.remote_page.evaluate('pointerEvents'), pointer_count)
        self.assertEqual(errors, [])
