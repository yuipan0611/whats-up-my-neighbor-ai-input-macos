"""Lifecycle cancellation tests with a synthetic SDK transport, no Chrome."""
import asyncio
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

OFFICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OFFICE))
from browser_workspace import BrowserWorkspaceError, PlaywrightChromeProvider
from browser_workspace.profiles import ProfileLease


class SyntheticContext:
    def __init__(self):
        self.pages = [object()]
        self.closing = asyncio.Event()
        self.close_gate = asyncio.Event()
        self.close_gate.set()
        self.callbacks = {}

    def on(self, event, callback):
        self.callbacks[event] = callback

    def set_default_timeout(self, value): pass
    def set_default_navigation_timeout(self, value): pass

    async def close(self):
        self.closing.set()
        await self.close_gate.wait()
        self.callbacks["close"](self)


class SyntheticManager:
    """Like the SDK, transport starts before start() returns a driver handle."""
    def __init__(self, *, pause_start=False, fail_launch=False):
        self.started = asyncio.Event()
        self.start_gate = asyncio.Event()
        if not pause_start:
            self.start_gate.set()
        self.exiting = asyncio.Event()
        self.exit_gate = asyncio.Event()
        self.exit_gate.set()
        self.stopped = asyncio.Event()
        self.transport = None
        self.exit_calls = 0
        self.exit_was_called = False
        self.fail_launch = fail_launch
        self.context = SyntheticContext()
        self.driver = types.SimpleNamespace(chromium=self)

    async def start(self):
        self.transport = asyncio.create_task(self.stopped.wait())
        self.started.set()
        await self.start_gate.wait()
        return self.driver

    async def launch_persistent_context(self, **options):
        if self.fail_launch:
            raise RuntimeError("synthetic-secret-must-not-escape")
        return self.context

    async def __aexit__(self, *args):
        # Model the real manager's one-shot exit semantics.
        self.exit_calls += 1
        if self.exit_was_called:
            return
        self.exit_was_called = True
        self.exiting.set()
        await self.exit_gate.wait()
        self.stopped.set()
        await self.transport


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "profiles"

    def install_sdk(self, manager):
        module = types.ModuleType("playwright.async_api")
        module.async_playwright = lambda: manager
        patcher = patch.dict(sys.modules, {
            "playwright": types.ModuleType("playwright"),
            "playwright.async_api": module,
        })
        patcher.start()
        self.addCleanup(patcher.stop)

    def assert_profile_locked(self):
        contender = ProfileLease(self.root, "research")
        with self.assertRaises(BrowserWorkspaceError) as raised:
            contender.acquire()
        self.assertEqual(raised.exception.code, "profile_in_use")

    def assert_profile_available(self):
        contender = ProfileLease(self.root, "research")
        contender.acquire()
        contender.release()

    async def test_early_start_cancellation_settles_transport_before_releasing_profile(self):
        manager = SyntheticManager(pause_start=True)
        manager.exit_gate.clear()
        self.install_sdk(manager)
        provider = PlaywrightChromeProvider(self.root, "research")
        start = asyncio.create_task(provider.start())
        await asyncio.wait_for(manager.started.wait(), timeout=2)
        start.cancel()
        await asyncio.sleep(0)
        self.assert_profile_locked()
        self.assertFalse(manager.transport.done())
        self.assertEqual(manager.exit_calls, 0)
        manager.start_gate.set()
        await asyncio.wait_for(manager.exiting.wait(), timeout=2)
        self.assert_profile_locked()
        manager.exit_gate.set()
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(start, timeout=2)
        self.assertTrue(manager.transport.done())
        self.assertEqual(manager.exit_calls, 1)
        self.assert_profile_available()

    async def test_launch_failure_stops_transport_and_sanitizes_error(self):
        manager = SyntheticManager(fail_launch=True)
        self.install_sdk(manager)
        provider = PlaywrightChromeProvider(self.root, "research")
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await provider.start()
        self.assertEqual(str(raised.exception), "chrome_launch_failed")
        self.assertTrue(manager.transport.done())
        self.assertEqual(manager.exit_calls, 1)
        self.assert_profile_available()

    async def test_close_cancellation_keeps_cleanup_running_and_lock_until_stopped(self):
        manager = SyntheticManager()
        self.install_sdk(manager)
        provider = PlaywrightChromeProvider(self.root, "research")
        await provider.start()
        with self.assertRaises(BrowserWorkspaceError):
            await provider.start()
        self.assert_profile_locked()
        manager.context.close_gate.clear()
        closing = asyncio.create_task(provider.close())
        await asyncio.wait_for(manager.context.closing.wait(), timeout=2)
        closing.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await closing
        self.assert_profile_locked()
        manager.context.close_gate.set()
        await asyncio.wait_for(provider.close(), timeout=2)
        await provider.close()
        self.assertTrue(manager.transport.done())
        self.assertEqual(manager.exit_calls, 1)
        self.assert_profile_available()


if __name__ == "__main__":
    unittest.main()
