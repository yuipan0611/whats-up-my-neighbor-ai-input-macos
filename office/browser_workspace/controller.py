"""One browser, one input owner; epochs fence stale agent and human actions.

Only trusted in-process adapters may use the agent methods. This controller
does not grant arbitrary websites or authenticated actions to an LLM.
"""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
import re
import secrets
import uuid

from .ports import BrowserSessionProvider, BrowserWorkspaceError, PageSnapshot

CloseChannel = Callable[[], Awaitable[None]]
SendBytes = Callable[[bytes], Awaitable[None]]
_DEVICE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


class ControllerError(BrowserWorkspaceError):
    def __init__(self, code: str, status: int = 409):
        super().__init__(code)
        self.status = status


@dataclass(frozen=True)
class _ControlChannel:
    id: str
    device: str
    epoch: int
    close: CloseChannel


class BrowserController:
    def __init__(self, provider: BrowserSessionProvider, *, claim_timeout: float = 30):
        self._provider = provider
        self._session_id = str(uuid.uuid4())
        self._epoch = secrets.randbits(48)  # Safe in JavaScript; not an auth token.
        self._mode = "paused"
        self._private = False
        self._owner: str | None = None
        self._control: _ControlChannel | None = None
        self._viewers: dict[str, CloseChannel] = {}
        self._state_lock = asyncio.Lock()
        self._agent_lock = asyncio.Lock()
        self._started = False
        self._closed = False
        self._claim_timeout = claim_timeout
        self._claim_task: asyncio.Task | None = None
        self._close_task: asyncio.Task | None = None

    @staticmethod
    def _device(device: str) -> None:
        if not isinstance(device, str) or not _DEVICE.fullmatch(device):
            raise ControllerError("invalid_device", 400)

    def _available(self) -> None:
        if not self._started or self._closed:
            raise ControllerError("browser_not_running", 503)

    def _state(self, device: str | None) -> dict:
        available = self._started and not self._closed
        mine = device is not None and device == self._owner
        return {"session_id": self._session_id, "mode": self._mode,
                "epoch": self._epoch, "private": self._private,
                "is_owner": mine, "control_connected": self._control is not None,
                "can_view": available and not self._private and self._mode in ("paused", "agent"),
                "can_takeover": available and self._mode in ("paused", "agent")
                and (not self._private or mine),
                "can_release": available and self._mode == "human" and mine}

    async def state(self, device: str | None = None) -> dict:
        async with self._state_lock:
            return self._state(device)

    async def start(self) -> None:
        async with self._agent_lock:
            if self._started or self._closed:
                raise ControllerError("browser_busy")
            await self._provider.start()
            self._started = True

    def _cancel_claim(self) -> None:
        if self._claim_task is not None:
            self._claim_task.cancel()
            self._claim_task = None

    async def _close_channels(self, callbacks: list[CloseChannel]) -> None:
        if not callbacks:
            return
        results = await asyncio.gather(
            *(asyncio.wait_for(close(), timeout=5) for close in callbacks),
            return_exceptions=True)
        if any(isinstance(result, BaseException) for result in results):
            raise ControllerError("handoff_failed", 503)

    async def _pause_transition(self, epoch: int) -> None:
        async with self._state_lock:
            if self._epoch == epoch and self._mode == "handoff":
                self._epoch += 1
                self._mode = "paused"

    async def takeover(self, device: str) -> dict:
        self._device(device)
        async with self._state_lock:
            self._available()
            if self._private and self._owner != device:
                raise ControllerError("owner_mismatch", 403)
            if self._mode == "human" and self._owner == device:
                return self._state(device)
            if self._mode not in ("paused", "agent"):
                raise ControllerError("browser_busy")
            self._epoch += 1
            epoch = self._epoch
            self._mode, self._owner, self._private = "handoff", device, True
            viewers = list(self._viewers.values())
            self._viewers.clear()
        try:
            # Revoke first, drain agent work and viewer bytes before human input.
            await self._close_channels(viewers)
            async with asyncio.timeout(35):
                async with self._agent_lock:
                    async with self._state_lock:
                        self._available()
                        if self._epoch != epoch or self._mode != "handoff":
                            raise ControllerError("stale_epoch")
                        self._mode = "human"
                        self._claim_task = asyncio.create_task(self._expire_claim(epoch))
                        return self._state(device)
        except BaseException as error:
            await self._pause_transition(epoch)
            if isinstance(error, TimeoutError):
                raise ControllerError("handoff_failed", 503) from None
            raise

    async def _expire_claim(self, epoch: int) -> None:
        await asyncio.sleep(self._claim_timeout)
        async with self._state_lock:
            if self._mode == "human" and self._epoch == epoch and self._control is None:
                self._epoch += 1
                self._mode = "paused"
                self._claim_task = None
                # Keep owner and privacy until that owner explicitly returns.

    def _assert_owner(self, device: str, epoch: int) -> None:
        self._available()
        if self._owner != device:
            raise ControllerError("owner_mismatch", 403)
        if type(epoch) is not int or epoch != self._epoch:
            raise ControllerError("stale_epoch")
        if self._mode != "human":
            raise ControllerError("browser_busy")

    async def release(self, device: str, epoch: int) -> dict:
        self._device(device)
        async with self._state_lock:
            self._assert_owner(device, epoch)
            self._cancel_claim()
            self._epoch += 1
            transition = self._epoch
            self._mode = "handoff"
            control, self._control = self._control, None
        try:
            await self._close_channels([control.close] if control else [])
            async with self._state_lock:
                self._available()
                if self._mode != "handoff" or self._epoch != transition:
                    raise ControllerError("stale_epoch")
                self._mode, self._owner, self._private = "agent", None, False
                return self._state(device)
        except BaseException:
            await self._pause_transition(transition)
            raise

    async def attach_control(self, device: str, epoch: int, close: CloseChannel) -> str:
        self._device(device)
        async with self._state_lock:
            self._assert_owner(device, epoch)
            if self._control is not None:
                raise ControllerError("control_already_connected")
            self._cancel_claim()
            channel = _ControlChannel(str(uuid.uuid4()), device, epoch, close)
            self._control = channel
            return channel.id

    async def detach_control(self, connection_id: str) -> None:
        async with self._state_lock:
            if self._control is None or self._control.id != connection_id:
                return
            self._control = None
            self._cancel_claim()
            self._epoch += 1
            self._mode = "paused"
            # Never expose the possibly unfinished login page to viewers.
            self._private = True

    async def register_viewer(self, close: CloseChannel, *, epoch: int | None = None) -> str:
        async with self._state_lock:
            self._available()
            if epoch is not None and (type(epoch) is not int or epoch != self._epoch):
                raise ControllerError("stale_epoch")
            if self._private or self._mode not in ("paused", "agent"):
                raise ControllerError("private_session", 403)
            connection_id = str(uuid.uuid4())
            self._viewers[connection_id] = close
            return connection_id

    async def unregister_viewer(self, connection_id: str) -> None:
        async with self._state_lock:
            self._viewers.pop(connection_id, None)

    async def forward_control(self, connection_id: str, payload: bytes, send: SendBytes) -> None:
        async with self._state_lock:
            control = self._control
            if control is None or control.id != connection_id:
                raise ControllerError("control_not_connected")
            self._assert_owner(control.device, control.epoch)
            # Bound backpressure while holding the fence; release cannot race
            # a check and then permit bytes to be written under an old epoch.
            await asyncio.wait_for(send(payload), timeout=2)

    async def forward_view(self, connection_id: str, payload: bytes, send: SendBytes) -> None:
        async with self._state_lock:
            if connection_id not in self._viewers or self._private:
                raise ControllerError("private_session", 403)
            await asyncio.wait_for(send(payload), timeout=2)

    async def _agent_action(self, epoch: int, action: Callable[[], Awaitable[PageSnapshot]]) -> PageSnapshot:
        async with self._agent_lock:
            async with self._state_lock:
                self._available()
                if type(epoch) is not int or epoch != self._epoch:
                    raise ControllerError("stale_epoch")
                if self._mode != "agent" or self._private:
                    raise ControllerError("browser_busy")
            result = await action()
            async with self._state_lock:
                if self._epoch != epoch or self._mode != "agent":
                    raise ControllerError("stale_epoch")
            return result

    async def agent_navigate(self, epoch: int, url: str) -> PageSnapshot:
        return await self._agent_action(epoch, lambda: self._provider.navigate(url))

    async def agent_current(self, epoch: int) -> PageSnapshot:
        return await self._agent_action(epoch, self._provider.current)

    async def close(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._shutdown())
            self._close_task.add_done_callback(
                lambda task: None if task.cancelled() else task.exception())
        await asyncio.shield(self._close_task)

    async def _shutdown(self) -> None:
        async with self._state_lock:
            self._closed = True
            self._epoch += 1
            self._mode = "paused"
            self._cancel_claim()
            callbacks = list(self._viewers.values())
            self._viewers.clear()
            if self._control:
                callbacks.append(self._control.close)
                self._control = None
        try:
            await self._close_channels(callbacks)
        finally:
            async with self._agent_lock:
                await self._provider.close()
