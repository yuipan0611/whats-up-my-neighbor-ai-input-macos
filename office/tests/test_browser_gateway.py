"""Private Unix HTTP and raw RFB bridge tests; no GUI or real credentials."""
import asyncio
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    import aiohttp
    from aiohttp import web
except ImportError:
    aiohttp = None

from browser_workspace import PageSnapshot
from browser_workspace.controller import BrowserController, ControllerError
if aiohttp:
    from browser_workspace.gateway import _Bridge, create_app, serve_unix, validate_private_socket


class IdleProvider:
    def __init__(self):
        self.closed = False
        self.closing = asyncio.Event()
        self.close_gate = asyncio.Event()
        self.close_gate.set()
    async def start(self): pass
    async def close(self):
        self.closing.set()
        await self.close_gate.wait()
        self.closed = True
    async def current(self): return PageSnapshot("about:blank", "")
    async def navigate(self, url): return PageSnapshot(url, "")


@unittest.skipUnless(aiohttp, "Optional aiohttp browser gateway dependency is not installed")
class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.received = {"view": [], "control": []}
        self.writers = set()
        self.servers = []
        for mode in ("view", "control"):
            async def echo(reader, writer, name=mode):
                self.writers.add(writer)
                try:
                    writer.write(name.encode())
                    await writer.drain()
                    while data := await reader.read(65536):
                        self.received[name].append(data)
                        writer.write(data)
                        await writer.drain()
                except (ConnectionError, asyncio.CancelledError):
                    pass
                finally:
                    writer.close()
                    await writer.wait_closed()
                    self.writers.discard(writer)
            path = self.root / f"{mode}.sock"
            self.servers.append(await asyncio.start_unix_server(echo, path=path))
            path.chmod(0o600)
        self.static = self.root / "static"
        self.static.mkdir()
        (self.static / "index.html").write_text("<!doctype html><title>Test display</title>")
        self.provider = IdleProvider()
        self.controller = BrowserController(self.provider)
        await self.controller.start()
        app = create_app(self.controller, self.root / "view.sock", self.root / "control.sock",
                         static_root=self.static)
        self.gateway = await serve_unix(app, self.root / "gateway.sock")
        self.client = aiohttp.ClientSession(connector=aiohttp.UnixConnector(path=self.gateway.path))
        self.headers = {"X-Neko-Device": "owner-a"}

    async def asyncTearDown(self):
        await self.client.close()
        await self.gateway.close()
        for server in self.servers:
            server.close()
            await server.wait_closed()
        for writer in list(self.writers):
            writer.close()
            await writer.wait_closed()

    async def state(self):
        async with self.client.get("http://office/api/browser/state", headers=self.headers) as response:
            self.assertEqual(response.status, 200)
            return await response.json()

    async def takeover(self):
        async with self.client.post("http://office/api/browser/takeover", headers=self.headers,
                                    json={}) as response:
            self.assertEqual(response.status, 200)
            return await response.json()

    async def connect(self, mode, epoch, *, device="owner-a"):
        return await self.client.ws_connect(f"http://office/api/browser/ws?mode={mode}&epoch={epoch}",
                                            headers={"X-Neko-Device": device}, protocols=("binary",))

    async def test_private_socket_and_identity_are_required_for_api_and_static(self):
        self.assertEqual(self.gateway.path.stat().st_mode & 0o777, 0o600)
        for path in ("/api/browser/state", "/browser/"):
            async with self.client.get("http://office" + path) as response:
                self.assertEqual(response.status, 403)
            async with self.client.get("http://office" + path, headers=self.headers) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
        async with self.client.get("http://office/api/browser/state", headers=[
                ("X-Neko-Device", "owner-a"), ("X-Neko-Device", "owner-b")]) as response:
            self.assertEqual(response.status, 403)

    async def test_only_allowlisted_routes_and_bounded_state_actions_exist(self):
        for path in ("/api/browser/navigate", "/browser/../../office.py", "/browser/secrets"):
            async with self.client.get("http://office" + path, headers=self.headers) as response:
                self.assertEqual(response.status, 404)
        cases = [("takeover", {"device": "owner-b"}, 400),
                 ("release", {"epoch": True}, 400),
                 ("takeover", {"padding": "x" * 5000}, 413)]
        for path, body, status in cases:
            async with self.client.post("http://office/api/browser/" + path,
                                        headers=self.headers, json=body) as response:
                self.assertEqual(response.status, status)

    async def test_view_bytes_only_reach_view_upstream_and_disconnect_keeps_browser(self):
        state = await self.state()
        ws = await self.connect("view", state["epoch"])
        self.assertEqual((await ws.receive()).data, b"view")
        # The actual view-only server enforces RFB input policy. The gateway
        # cannot be tricked into sending these bytes to the control upstream.
        await ws.send_bytes(b"forged-input")
        self.assertEqual((await ws.receive()).data, b"forged-input")
        await ws.close()
        self.assertEqual(self.received["view"], [b"forged-input"])
        self.assertEqual(self.received["control"], [])
        self.assertFalse(self.provider.closed)

    async def test_takeover_disconnects_view_rejects_duplicates_and_release_fences_input(self):
        state = await self.state()
        viewer = await self.connect("view", state["epoch"])
        await viewer.receive()
        closing_view = asyncio.create_task(viewer.receive())
        human = await self.takeover()
        await closing_view
        await viewer.close()
        for mode, device in (("view", "owner-a"), ("control", "owner-b")):
            with self.assertRaises(aiohttp.WSServerHandshakeError) as error:
                await self.connect(mode, human["epoch"], device=device)
            self.assertEqual(error.exception.status, 403)
        control = await self.connect("control", human["epoch"])
        self.assertEqual((await control.receive()).data, b"control")
        with self.assertRaises(aiohttp.WSServerHandshakeError) as error:
            await self.connect("control", human["epoch"])
        self.assertEqual(error.exception.status, 409)
        await control.send_bytes(b"approved-input")
        self.assertEqual((await control.receive()).data, b"approved-input")
        closing_control = asyncio.create_task(control.receive())
        async with self.client.post("http://office/api/browser/release", headers=self.headers,
                                    json={"epoch": human["epoch"]}) as response:
            self.assertEqual(response.status, 200)
            agent = await response.json()
        await closing_control
        await control.close()
        self.assertEqual(agent["mode"], "agent")
        self.assertEqual(self.received["control"], [b"approved-input"])
        with self.assertRaises(aiohttp.WSServerHandshakeError) as error:
            await self.connect("control", human["epoch"])
        self.assertIn(error.exception.status, (403, 409))

    async def test_human_disconnect_preserves_private_pause_and_rejects_other_device(self):
        human = await self.takeover()
        control = await self.connect("control", human["epoch"])
        await control.receive()
        await control.close()
        for _ in range(20):
            state = await self.state()
            if state["mode"] == "paused":
                break
            await asyncio.sleep(0.01)
        self.assertEqual(state["mode"], "paused")
        self.assertTrue(state["private"])
        self.assertFalse(state["can_view"])
        async with self.client.post("http://office/api/browser/takeover", json={},
                                    headers={"X-Neko-Device": "owner-b"}) as response:
            self.assertEqual(response.status, 403)

    async def test_backpressure_is_bounded_and_release_does_not_deadlock_with_bridge_close(self):
        human = await self.takeover()
        control = await self.connect("control", human["epoch"])
        await control.receive()
        sending = asyncio.Event()
        async def blocked_send(bridge, data):
            sending.set()
            await asyncio.Event().wait()
        with patch.object(_Bridge, "send_tcp", blocked_send):
            await control.send_bytes(b"backpressure")
            await asyncio.wait_for(sending.wait(), timeout=2)
            receiving_close = asyncio.create_task(control.receive())
            async with asyncio.timeout(5):
                async with self.client.post("http://office/api/browser/release", headers=self.headers,
                                            json={"epoch": human["epoch"]}) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual((await response.json())["mode"], "agent")
                await receiving_close
        await control.close()
        self.assertEqual(self.received["control"], [])

    async def test_cancelled_gateway_close_still_owns_provider_cleanup_and_its_socket(self):
        self.provider.close_gate.clear()
        closing = asyncio.create_task(self.gateway.close())
        await asyncio.wait_for(self.provider.closing.wait(), timeout=2)
        closing.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await closing
        self.assertFalse(self.provider.closed)
        self.assertTrue(self.gateway.path.exists())
        self.provider.close_gate.set()
        await asyncio.wait_for(self.gateway.close(), timeout=2)
        self.assertTrue(self.provider.closed)
        self.assertFalse(self.gateway.path.exists())

    async def test_tcp_listener_cannot_use_the_unix_peer_trust_boundary(self):
        other = BrowserController(IdleProvider())
        app = create_app(other, self.root / "view.sock", self.root / "control.sock")
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        try:
            port = site._server.sockets[0].getsockname()[1]
            async with aiohttp.ClientSession() as client:
                async with client.get(f"http://127.0.0.1:{port}/api/browser/state",
                                      headers=self.headers) as response:
                    self.assertEqual(response.status, 403)
        finally:
            await runner.cleanup()

    async def test_socket_validation_rejects_permissions_links_and_existing_listener(self):
        view = self.root / "view.sock"
        view.chmod(0o666)
        with self.assertRaises(ControllerError):
            validate_private_socket(view)
        view.chmod(0o600)
        linked = self.root / "linked.sock"
        linked.symlink_to(view)
        with self.assertRaises(ControllerError):
            validate_private_socket(linked)
        with self.assertRaises(ControllerError):
            validate_private_socket(self.gateway.path, must_exist=False)
        self.assertEqual((await self.state())["mode"], "paused")


if __name__ == "__main__":
    unittest.main()
