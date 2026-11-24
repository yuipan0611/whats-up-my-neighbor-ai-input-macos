"""Optional Chrome adapter. No HTTP server, CDP port, cookies API or trace."""
from __future__ import annotations

import asyncio
from pathlib import Path
from urllib.parse import urlsplit

from .ports import BrowserWorkspaceError, PageSnapshot
from .profiles import ProfileLease


class PlaywrightChromeProvider:
    """One dedicated persistent Chrome; call from a single asyncio event loop.

    Navigation is a trusted lab capability, not a URL policy or permission
    broker. Do not connect this provider directly to an untrusted agent.
    """

    def __init__(self, profile_root: str | Path, profile_id: str, *, headless: bool = False):
        self._lease = ProfileLease(profile_root, profile_id)
        self._headless = headless
        self._manager = None
        self._driver = None
        self._context = None
        self._page = None
        self._state = "stopped"
        self._operation = asyncio.Lock()
        self._closed = asyncio.Event()
        self._startup_task = None
        self._cleanup_task = None

    async def start(self) -> None:
        async with self._operation:
            if self._state != "stopped":
                raise BrowserWorkspaceError("workspace_already_started")
            self._state = "starting"
            self._closed.clear()
            self._cleanup_task = None
            try:
                profile = self._lease.acquire()
                try:
                    from playwright.async_api import async_playwright
                except ImportError:
                    raise BrowserWorkspaceError("playwright_not_installed") from None
                # start() schedules a background connection before returning a
                # driver. Keep ownership even when that await is cancelled.
                self._manager = async_playwright()
                self._startup_task = asyncio.create_task(self._manager.start())
                self._startup_task.add_done_callback(
                    lambda task: None if task.cancelled() else task.exception())
                self._driver = await asyncio.shield(self._startup_task)
                self._context = await self._driver.chromium.launch_persistent_context(
                    user_data_dir=str(profile), channel="chrome",
                    headless=self._headless, chromium_sandbox=True,
                    accept_downloads=False, no_viewport=True, timeout=30_000)
                self._context.on("close", lambda _: self._closed.set())
                self._page = (self._context.pages[0] if self._context.pages
                              else await self._context.new_page())
                self._context.set_default_timeout(15_000)
                self._context.set_default_navigation_timeout(30_000)
                self._state = "running"
            except BaseException as error:
                try:
                    await self._cleanup()
                except BrowserWorkspaceError:
                    if isinstance(error, (asyncio.CancelledError, KeyboardInterrupt, SystemExit)):
                        raise error
                    raise BrowserWorkspaceError("workspace_cleanup_failed") from None
                if isinstance(error, (BrowserWorkspaceError, asyncio.CancelledError,
                                      KeyboardInterrupt, SystemExit)):
                    raise
                raise BrowserWorkspaceError("chrome_launch_failed") from None

    def _require_page(self):
        if self._state != "running" or self._closed.is_set():
            raise BrowserWorkspaceError("workspace_not_running")
        if self._page is None or self._page.is_closed():
            raise BrowserWorkspaceError("workspace_page_closed")
        return self._page

    async def navigate(self, url: str) -> PageSnapshot:
        try:
            parts = urlsplit(url)
            if (len(url) > 8192 or parts.scheme not in ("http", "https")
                    or not parts.hostname or parts.username is not None
                    or parts.password is not None or any(ord(c) < 32 for c in url)):
                raise ValueError
            _ = parts.port
        except (ValueError, TypeError, AttributeError):
            raise BrowserWorkspaceError("navigation_url_invalid") from None
        async with self._operation:
            page = self._require_page()
            try:
                await page.goto(url, wait_until="load", timeout=30_000)
                return PageSnapshot(url=page.url, title=await page.title())
            except Exception:
                # No automatic retry: a navigation may already have had effects.
                raise BrowserWorkspaceError("navigation_failed") from None

    async def current(self) -> PageSnapshot:
        async with self._operation:
            page = self._require_page()
            try:
                return PageSnapshot(url=page.url, title=await page.title())
            except Exception:
                raise BrowserWorkspaceError("observation_failed") from None

    async def wait_closed(self) -> None:
        """Listen only for lifecycle closure; never inspect a login page."""
        if self._state != "running":
            raise BrowserWorkspaceError("workspace_not_running")
        await self._closed.wait()

    async def close(self) -> None:
        async with self._operation:
            await self._cleanup()

    async def _cleanup(self) -> None:
        if self._state == "stopped":
            return
        if self._cleanup_task is None:
            self._state = "closing"
            self._cleanup_task = asyncio.create_task(self._shutdown())
            # A cancelled caller may not return to collect this fixed error.
            self._cleanup_task.add_done_callback(
                lambda task: None if task.cancelled() else task.exception())
        # Playwright's manager exit is one-shot. Never cancel it with the caller
        # and later mistake its second, no-op exit for confirmed termination.
        await asyncio.shield(self._cleanup_task)

    async def _shutdown(self) -> None:
        # A very early manager exit can run before its transport is initialized.
        # Settle the owned startup first; a hung startup fails closed, rather
        # than releasing the profile while a background transport is starting.
        if self._startup_task is not None:
            try:
                self._driver = await asyncio.wait_for(
                    asyncio.shield(self._startup_task), timeout=10)
            except (TimeoutError, asyncio.CancelledError):
                self._state = "failed"
                raise BrowserWorkspaceError("workspace_cleanup_failed") from None
            except Exception:
                pass  # Still attempt to dispose the partially started manager.
            self._startup_task = None
        failed = False
        if self._context is not None:
            try:
                await asyncio.wait_for(self._context.close(), timeout=10)
                self._context = None
                self._page = None
            except Exception:
                failed = True
        if self._manager is not None:
            try:
                await asyncio.wait_for(self._manager.__aexit__(None, None, None), timeout=10)
                self._manager = None
                self._driver = None
            except Exception:
                failed = True
        if failed:
            # Do not hand the profile to a second owner after uncertain shutdown.
            # Actual shutdown failure requires stopping this dedicated process.
            # Retrying close re-raises the same failed task, never a no-op exit.
            self._state = "failed"
            raise BrowserWorkspaceError("workspace_cleanup_failed") from None
        self._lease.release()
        self._closed.set()
        self._state = "stopped"
