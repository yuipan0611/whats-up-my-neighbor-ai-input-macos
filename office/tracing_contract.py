"""Application-owned tracing ports: standard-library types, no vendor SDK.

This is an in-process adapter contract, not a new telemetry wire protocol.
OTLP remains the wire format. Implementations must not change task outcomes.
TypedDict/Protocol document shape; contract tests verify behavior.
"""
from typing import ContextManager, Literal, Protocol, TypedDict, runtime_checkable


class AgentEvent(TypedDict, total=False):
    # Every event requires schema_version=1 and phase. All other fields are
    # optional, metadata-only, and omitted when absent in the source event.
    schema_version: Literal[1]
    phase: Literal['session.started', 'run.started', 'run.completed', 'run.failed',
                   'run.error', 'item.started', 'item.completed']
    item_kind: Literal['message', 'reasoning_summary', 'tool', 'error', 'other']
    item_id: str
    tool_name: str
    outcome: Literal['completed', 'failed']
    input_tokens: int
    output_tokens: int


@runtime_checkable
class TaskReporter(Protocol):
    def outcome(self, status: str) -> None: ...


@runtime_checkable
class AgentReporter(Protocol):
    def event(self, event: AgentEvent) -> None: ...


@runtime_checkable
class TracePort(Protocol):
    def task(self, task_id: str, executor: str,
             previous_task_id: str = '') -> ContextManager[TaskReporter]: ...

    def agent(self, task_id: str, executor: str) -> ContextManager[AgentReporter]: ...

    def shutdown(self, timeout_seconds: float = 2.0) -> None: ...
