"""Ownership and takeover races against a controlled provider, no real account."""
import asyncio
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser_workspace import PageSnapshot
from browser_workspace.controller import BrowserController, ControllerError


async def noop(): pass


class ControlledProvider:
    def __init__(self):
        self.inflight = asyncio.Event()
        self.finish = asyncio.Event()
        self.finish.set()
        self.closed = False
        self.calls = []

    async def start(self): pass

    async def navigate(self, url):
        self.calls.append(url)
        self.inflight.set()
        await self.finish.wait()
        return PageSnapshot(url, "synthetic")

    async def current(self):
        return await self.navigate("about:blank")

    async def close(self):
        self.closed = True


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.provider = ControlledProvider()
        self.controller = BrowserController(self.provider, claim_timeout=0.1)
        await self.controller.start()
        self.addAsyncCleanup(self.controller.close)

    async def enable_agent(self):
        human = await self.controller.takeover("owner-a")
        return await self.controller.release("owner-a", human["epoch"])

    async def test_takeover_revokes_epoch_before_waiting_for_inflight_agent(self):
        agent = await self.enable_agent()
        self.provider.finish.clear()
        action = asyncio.create_task(self.controller.agent_navigate(agent["epoch"], "https://test.invalid"))
        await self.provider.inflight.wait()
        taking = asyncio.create_task(self.controller.takeover("owner-a"))
        await asyncio.sleep(0)
        state = await self.controller.state("owner-a")
        self.assertEqual(state["mode"], "handoff")
        self.assertGreater(state["epoch"], agent["epoch"])
        self.assertFalse(taking.done())
        with self.assertRaises(ControllerError):
            await self.controller.attach_control("owner-a", state["epoch"], noop)
        self.provider.finish.set()
        with self.assertRaises(ControllerError) as error:
            await action
        self.assertEqual(error.exception.code, "stale_epoch")
        human = await taking
        self.assertEqual(human["mode"], "human")
        with self.assertRaises(ControllerError):
            await self.controller.agent_current(agent["epoch"])

    async def test_private_takeover_disconnects_viewers_and_rejects_agent_observation(self):
        disconnected = asyncio.Event()
        async def close_view(): disconnected.set()
        viewer = await self.controller.register_viewer(close_view)
        human = await self.controller.takeover("owner-a")
        self.assertTrue(disconnected.is_set())
        with self.assertRaises(ControllerError):
            await self.controller.register_viewer(noop)
        with self.assertRaises(ControllerError):
            await self.controller.agent_current(human["epoch"])
        with self.assertRaises(ControllerError):
            await self.controller.forward_view(viewer, b"old", lambda data: noop())
        self.assertEqual(self.provider.calls, [])

    async def test_only_one_controller_and_disconnect_stays_private_for_same_owner(self):
        human = await self.controller.takeover("owner-a")
        channel = await self.controller.attach_control("owner-a", human["epoch"], noop)
        for device in ("owner-a", "owner-b"):
            with self.assertRaises(ControllerError):
                await self.controller.attach_control(device, human["epoch"], noop)
        with self.assertRaises(ControllerError):
            await self.controller.takeover("owner-b")
        await self.controller.detach_control(channel)
        state = await self.controller.state("owner-a")
        self.assertEqual(state["mode"], "paused")
        self.assertTrue(state["private"])
        self.assertTrue(state["can_takeover"])
        self.assertFalse((await self.controller.state("owner-b"))["can_takeover"])
        with self.assertRaises(ControllerError):
            await self.controller.register_viewer(noop)
        again = await self.controller.takeover("owner-a")
        self.assertGreater(again["epoch"], human["epoch"])

    async def test_release_closes_old_channel_before_enabling_agent(self):
        human = await self.controller.takeover("owner-a")
        closing, finish = asyncio.Event(), asyncio.Event()
        async def close_control():
            closing.set()
            await finish.wait()
        channel = await self.controller.attach_control("owner-a", human["epoch"], close_control)
        release = asyncio.create_task(self.controller.release("owner-a", human["epoch"]))
        await closing.wait()
        self.assertEqual((await self.controller.state())["mode"], "handoff")
        with self.assertRaises(ControllerError):
            await self.controller.forward_control(channel, b"stale-input", lambda data: noop())
        finish.set()
        agent = await release
        self.assertEqual(agent["mode"], "agent")
        self.assertFalse(agent["private"])
        with self.assertRaises(ControllerError):
            await self.controller.agent_current(human["epoch"])
        await self.controller.agent_current(agent["epoch"])

    async def test_forwarding_fence_drains_before_release_and_rejects_later_bytes(self):
        human = await self.controller.takeover("owner-a")
        channel = await self.controller.attach_control("owner-a", human["epoch"], noop)
        sending, finish = asyncio.Event(), asyncio.Event()
        sent = []
        async def send(data):
            sending.set()
            await finish.wait()
            sent.append(data)
        forward = asyncio.create_task(self.controller.forward_control(channel, b"before", send))
        await sending.wait()
        release = asyncio.create_task(self.controller.release("owner-a", human["epoch"]))
        await asyncio.sleep(0)
        self.assertFalse(release.done())
        finish.set()
        await forward
        await release
        with self.assertRaises(ControllerError):
            await self.controller.forward_control(channel, b"after", send)
        self.assertEqual(sent, [b"before"])

    async def test_unconnected_claim_expires_paused_and_viewer_close_does_not_stop_browser(self):
        viewer = await self.controller.register_viewer(noop)
        await self.controller.unregister_viewer(viewer)
        self.assertFalse(self.provider.closed)
        human = await self.controller.takeover("owner-a")
        await asyncio.sleep(0.12)
        state = await self.controller.state("owner-a")
        self.assertEqual(state["mode"], "paused")
        self.assertTrue(state["private"])
        with self.assertRaises(ControllerError):
            await self.controller.attach_control("owner-a", human["epoch"], noop)
        self.assertFalse(self.provider.closed)


if __name__ == "__main__":
    unittest.main()
