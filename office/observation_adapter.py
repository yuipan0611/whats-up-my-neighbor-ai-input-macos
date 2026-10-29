"""Standard-library bridge between the two retained observation contracts."""
from contextlib import contextmanager


class TraceObserverAdapter:
    """Bridge the metadata TracePort to the separately tested task/opaque-handle API.

    Framework-specific handles stay in this adapter. The Codex translator is
    supplied by CodexAgent; raw provider events never reach the generic port.
    """
    def __init__(self, port, normalise=None):
        self.port, self.normalise = port, normalise

    @contextmanager
    def task(self, task):
        with self.port.task(task['id'], task.get('executor', 'gemma'), task.get('parent_id', '')) as reporter:
            yield reporter

    def outcome(self, handle, status, error_type=None):
        handle.outcome(status)

    @contextmanager
    def agent(self, task):
        with self.port.agent(task['id'], 'codex') as reporter:
            normalise = self.normalise
            class Receiver:
                def event(self, raw):
                    event = normalise(raw)
                    if event is not None:
                        reporter.event(event)
            yield Receiver()

    def shutdown(self, timeout_seconds=2.0):
        self.port.shutdown(timeout_seconds)


def as_observer(port, normalise=None):
    if port is None:
        return port
    if getattr(port, 'observation_contract', None) != 'metadata-v1' and callable(getattr(port, 'outcome', None)):
        return port
    return TraceObserverAdapter(port, normalise)
