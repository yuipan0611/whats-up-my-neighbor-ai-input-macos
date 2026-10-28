"""Structural contracts for the existing observation injection points.

This module depends only on Python's standard library. Implementations need not
inherit these protocols. Task code never inspects the adapter's opaque handle;
OTel span types, exporters and backend-specific APIs stay in the adapter.
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import ContextManager, Protocol, runtime_checkable


@runtime_checkable
class TaskObserver(Protocol):
    """Diagnostic observer, not a task store, scheduler or replay log.

An implementation must execute a scope body exactly once, preserve its exception
and isolate its own diagnostic failures. ``task`` receives a private task record:
only documented metadata may be exported, never the whole mapping. Shutdown must
bound its caller's wait. A handle is adapter-owned and must not be persisted or
sent to the frontend. ``None`` is a valid handle when recording is unavailable.

These are behavioral requirements, not guarantees supplied by isinstance().
They must also be checked by integration tests for each adapter.
"""

    def task(self, task: Mapping[str, object]) -> ContextManager[object]:
        """Observe one execution. No scheduling, retries or task-state writes."""
        ...

    def outcome(self, handle: object, status: str,
                error_type: str | None = None) -> None:
        """Record safe outcome metadata for this adapter's own handle."""
        ...

    def shutdown(self, timeout_seconds: float = 2.0) -> None:
        """Bound the caller's wait; diagnostics are allowed to be lost."""
        ...


@runtime_checkable
class CodexEventReceiver(Protocol):
    """Provider-specific boundary: raw CLI JSON never becomes a generic API.

Only the Codex adapter uses this contract. A future provider gets its own event
translator; it must not fabricate Codex item IDs, token counts or lifecycle data.
"""

    def event(self, event: Mapping[str, object]) -> None:
        """Consume an observed CLI event without altering task execution."""
        ...


@runtime_checkable
class CodexObserver(TaskObserver, Protocol):
    """Optional Codex extension; the Office task core needs only TaskObserver."""

    def agent(self, task: Mapping[str, object]) -> ContextManager[CodexEventReceiver]:
        """Observe one CLI process and provide its provider-specific translator."""
        ...
