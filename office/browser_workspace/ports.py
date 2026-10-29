"""Browser lifecycle contract; no automation SDK types cross this boundary."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable


class BrowserWorkspaceError(Exception):
    """A fixed error code, never the underlying browser's diagnostic output."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class PageSnapshot:
    url: str
    title: str


@runtime_checkable
class BrowserSessionProvider(Protocol):
    async def start(self) -> None: ...

    async def navigate(self, url: str) -> PageSnapshot: ...

    async def current(self) -> PageSnapshot: ...

    async def close(self) -> None: ...
