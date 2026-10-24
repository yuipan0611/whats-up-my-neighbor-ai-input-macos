"""Optional, metadata-only OpenTelemetry bridge for the office's actual execution.

SQLite events remain the durable progress log. This module is loaded only when
NEKO_TRACE_ENABLED=1; exporters, batching and wire format come from the OTel SDK.
"""
from contextlib import contextmanager
import logging
import os
import re
import threading
from urllib.parse import urlsplit

from openinference.semconv.trace import SpanAttributes, OpenInferenceSpanKindValues
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import SpanLimits, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


class OfficeTelemetry:
    """Keep instrumentation failures separate from task failures."""

    def __init__(self, provider):
        self.provider = provider
        self.tracer = provider.get_tracer('nekonode.office')
        self._warned = False
        self._shutdown_thread = None

    def _warn(self):
        if not self._warned:
            self._warned = True
            # Never log exception text: it may include user data or credentials.
            logging.getLogger(__name__).warning('Office tracing failed; task execution continues.')

    def call(self, function, *args, **kwargs):
        try:
            return function(*args, **kwargs)
        except Exception:
            self._warn()

    def attributes(self, span, attributes):
        if span is not None:
            self.call(span.set_attributes, attributes)

    def outcome(self, span, status, error_type=None):
        attributes = {'nekonode.status': status}
        if error_type:
            attributes['error.type'] = error_type[:80]
        self.attributes(span, attributes)
        if span is not None and status in ('failed', 'interrupted'):
            self.call(span.set_status, trace.StatusCode.ERROR)
        elif span is not None and status == 'completed':
            self.call(span.set_status, trace.StatusCode.OK)

    @contextmanager
    def scope(self, name, kind, attributes):
        manager, span, entered = None, None, False
        try:
            manager = self.tracer.start_as_current_span(
                name,
                attributes={SpanAttributes.OPENINFERENCE_SPAN_KIND: kind.value, **attributes},
                record_exception=False, set_status_on_exception=False,
            )
            span = manager.__enter__()
            entered = True
        except Exception:
            self._warn()
        try:
            yield span
        except BaseException as error:
            # Cancellation is a requested outcome, not an application failure.
            cancelled = type(error).__name__ == 'Cancelled'
            self.outcome(span, 'cancelled' if cancelled else 'failed',
                         None if cancelled else type(error).__name__)
            raise
        finally:
            if entered:
                # Explicitly recorded safe metadata above; do not auto-export
                # exception messages or stack traces via the SDK context manager.
                self.call(manager.__exit__, None, None, None)

    def task(self, task):
        attributes = {'nekonode.task.id': task['id'],
                      'nekonode.executor': task.get('executor', 'gemma')}
        if task.get('parent_id'):
            # A manual continuation is another task, not a child-agent span.
            attributes['nekonode.task.previous_id'] = task['parent_id']
        return self.scope('office.task', OpenInferenceSpanKindValues.CHAIN, attributes)

    @contextmanager
    def agent(self, task):
        with self.scope('codex.run', OpenInferenceSpanKindValues.AGENT,
                        {'nekonode.task.id': task['id'], 'nekonode.executor': 'codex'}) as span:
            observer = CodexObservation(self, span)
            try:
                yield observer
            except BaseException as error:
                observer.close('cancelled' if type(error).__name__ == 'Cancelled' else 'interrupted')
                raise
            else:
                observer.close('unfinished')
                self.outcome(span, 'completed')

    def shutdown(self, timeout_seconds=2.0):
        # The SDK's bounded queue is best-effort, not the durable event store.
        # Its public shutdown has no timeout argument and can drain many batches.
        # Bound the caller's wait so a failed collector cannot delay office exit.
        if self._shutdown_thread is None:
            self._shutdown_thread = threading.Thread(
                target=lambda: self.call(self.provider.shutdown), name='office-tracing-stop', daemon=True)
            self._shutdown_thread.start()
        self._shutdown_thread.join(timeout_seconds)
        if self._shutdown_thread.is_alive():
            self._warn()


class CodexObservation:
    MAX_TOOL_SPANS = 64
    MAX_EVENTS = 128
    ITEM_ID = re.compile(r'[A-Za-z0-9_.:-]{1,128}')
    ITEM_TYPES = frozenset(('agent_message', 'reasoning', 'web_search', 'error'))
    EVENT_TYPES = frozenset(('thread.started', 'turn.started', 'turn.completed',
                             'turn.failed', 'item.started', 'item.completed', 'error'))

    def __init__(self, telemetry, span):
        self.telemetry, self.span = telemetry, span
        self.active = {}
        self.seen_tool_ids = set()
        self.tool_count = self.event_count = self.dropped_events = 0

    def event(self, event):
        self.telemetry.call(self._event, event)

    def _event(self, event):
        if self.span is None or not isinstance(event, dict):
            return
        phase = event.get('type')
        if not isinstance(phase, str) or phase not in self.EVENT_TYPES:
            return
        attributes = {}
        item = event.get('item')
        item = item if isinstance(item, dict) else {}
        kind = item.get('type')
        kind = kind if isinstance(kind, str) and kind in self.ITEM_TYPES else 'other'
        item_id = item.get('id')
        item_id = item_id if isinstance(item_id, str) and self.ITEM_ID.fullmatch(item_id) else None
        if phase.startswith('item.'):
            attributes['nekonode.item.type'] = kind
            if item_id:
                attributes['nekonode.item.id'] = item_id
        if self.event_count < self.MAX_EVENTS:
            self.telemetry.call(self.span.add_event, 'codex.' + phase, attributes)
            self.event_count += 1
        else:
            self.dropped_events += 1
        # Only this existing CLI tool is currently connected. Completion-only
        # events remain timestamped events; no start time is invented for them.
        if kind == 'web_search' and item_id:
            if phase == 'item.started' and item_id not in self.seen_tool_ids and self.tool_count < self.MAX_TOOL_SPANS:
                child = self.telemetry.call(
                    self.telemetry.tracer.start_span, 'codex.web_search',
                    context=trace.set_span_in_context(self.span),
                    attributes={SpanAttributes.OPENINFERENCE_SPAN_KIND: OpenInferenceSpanKindValues.TOOL.value,
                                SpanAttributes.TOOL_NAME: 'web_search', **attributes},
                )
                if child is not None:
                    self.active[item_id] = child
                    self.seen_tool_ids.add(item_id)
                    self.tool_count += 1
            elif phase == 'item.completed' and item_id in self.active:
                child = self.active.pop(item_id)
                self.telemetry.outcome(child, 'failed' if item.get('status') == 'failed' else 'completed')
                self.telemetry.call(child.end)
        if phase == 'turn.completed':
            usage = event.get('usage')
            if isinstance(usage, dict):
                safe = {}
                for source, target in (('input_tokens', SpanAttributes.LLM_TOKEN_COUNT_PROMPT),
                                       ('output_tokens', SpanAttributes.LLM_TOKEN_COUNT_COMPLETION)):
                    value = usage.get(source)
                    if type(value) is int and 0 <= value < 2 ** 63:
                        safe[target] = value
                self.telemetry.attributes(self.span, safe)

    def close(self, status):
        for child in self.active.values():
            self.telemetry.outcome(child, status)
            self.telemetry.call(child.end)
        self.active.clear()
        self.telemetry.attributes(self.span, {'nekonode.trace.dropped_events': self.dropped_events})


def create_telemetry(version):
    endpoint = os.environ.get('OTEL_EXPORTER_OTLP_TRACES_ENDPOINT', '')
    parsed = urlsplit(endpoint)
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or
            parsed.password or parsed.query or parsed.fragment):
        raise ValueError('Set OTEL_EXPORTER_OTLP_TRACES_ENDPOINT to the collector HTTP(S) traces URL.')
    provider = TracerProvider(
        resource=Resource.create({'service.name': 'nekonode-office', 'service.version': version}),
        span_limits=SpanLimits(max_attributes=32, max_events=128, max_attribute_length=256),
        shutdown_on_exit=False,
    )
    exporter = OTLPSpanExporter(endpoint=endpoint, timeout=2)
    provider.add_span_processor(BatchSpanProcessor(
        exporter, max_queue_size=512, max_export_batch_size=64, schedule_delay_millis=1000,
        export_timeout_millis=2000,
    ))
    return OfficeTelemetry(provider)
