"""Optional SDK integration: actual CLI parsing, trace hierarchy and failure isolation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

from test_office import app, FakeModel

try:
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor, SpanExporter
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
    from opentelemetry.sdk.trace.sampling import ALWAYS_ON
    from opentelemetry.trace import StatusCode
    import openinference.semconv.trace
except ImportError:
    SDK_AVAILABLE = False
else:
    SDK_AVAILABLE = True
    spec = importlib.util.spec_from_file_location('tested_office_telemetry', Path(app.__file__).with_name('telemetry.py'))
    telemetry_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(telemetry_module)


PRIVATE = 'PRIVATE_CONTENT_SENTINEL'
FINAL = {'kind': 'completed', 'content': '合成測試成果', 'next_step': ''}


class TracingFeatureGateTests(unittest.TestCase):
    def test_disabled_does_not_load_optional_module(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch(
                'importlib.util.spec_from_file_location', side_effect=AssertionError('unexpected optional import')):
            self.assertIsNone(app.load_telemetry())
            os.environ['NEKO_TRACE_ENABLED'] = '0'
            self.assertIsNone(app.load_telemetry())

    def test_missing_dependencies_give_actionable_error_without_raw_exception(self):
        loader = mock.Mock()
        loader.exec_module.side_effect = ImportError(PRIVATE)
        spec = importlib.util.spec_from_loader('missing_trace_dependencies', loader)
        with mock.patch.dict(os.environ, {'NEKO_TRACE_ENABLED': '1'}, clear=True), mock.patch(
                'importlib.util.spec_from_file_location', return_value=spec):
            with self.assertRaises(SystemExit) as raised:
                app.load_telemetry()
        self.assertIn('requirements-observability.txt', str(raised.exception))
        self.assertNotIn(PRIVATE, str(raised.exception))


@unittest.skipUnless(SDK_AVAILABLE, 'optional tracing dependencies are not installed')
class TracingIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = app.Store(self.root / 'data')
        self.exporter = InMemorySpanExporter()
        self.provider = TracerProvider(shutdown_on_exit=False, sampler=ALWAYS_ON)
        self.provider.add_span_processor(SimpleSpanProcessor(self.exporter))
        self.addCleanup(self.provider.shutdown)
        self.telemetry = telemetry_module.OfficeTelemetry(self.provider)

    def codex(self, body=None, final=FINAL):
        agent = app.CodexAgent(self.root / 'runtime', self.telemetry)
        agent.binary.parent.mkdir(parents=True, exist_ok=True)
        body = body if body is not None else (
            "emit('item.completed', id='reasoning-1', type='reasoning', text=private)\n"
            "emit('item.started', id='search-1', type='web_search', query=private)\n"
            "emit('item.completed', id='search-1', type='web_search', query=private)\n"
            "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':11,'output_tokens':5}}), flush=True)\n"
        )
        script = (
            '#!/usr/bin/env python3\nimport json,sys,pathlib,time\n'
            "if sys.argv[1:]==['login','status']: sys.exit(0)\n"
            'args=sys.argv\nsys.stdin.read()\n'
            f'private={PRIVATE!r}\n'
            "def emit(phase, **item): print(json.dumps({'type':phase,'item':item}), flush=True)\n"
            + body
        )
        if final is not None:
            script += ('\npathlib.Path(args[args.index("--output-last-message")+1]).write_text('
                       f'json.dumps({final!r}, ensure_ascii=False))\n')
        agent.binary.write_text(script)
        agent.binary.chmod(0o700)
        (agent.binary.parent / 'codex-code-mode-host').write_text('synthetic fixture host presence')
        return agent

    def submit(self, agent=None, **body):
        office = app.Office(self.store, FakeModel(), agent, self.telemetry)
        task = office.command({'id': str(uuid.uuid4()), 'prompt': '合成測試交辦', **body})['task']
        return office, task

    def spans(self):
        return self.exporter.get_finished_spans()

    def assert_private_content_absent(self):
        payload = '\n'.join(span.to_json() for span in self.spans())
        self.assertNotIn(PRIVATE, payload)
        self.assertNotIn('exception.message', payload)
        self.assertNotIn('exception.stacktrace', payload)

    def test_real_cli_events_form_task_agent_tool_tree_without_private_payloads(self):
        source = PRIVATE + '.txt'
        self.store.upload(source, PRIVATE)
        journal_id = str(uuid.uuid4())
        self.store.add_journal({'id': journal_id, 'day': '2026-10-24', 'text': PRIVATE})
        office, task = self.submit(self.codex(), prompt=PRIVATE, source=source, journal_ids=[journal_id])
        office.execute(self.store.claim())
        spans = {span.name: span for span in self.spans()}
        self.assertEqual(set(spans), {'office.task', 'codex.run', 'codex.web_search'})
        task_span, run_span, tool_span = (spans[name] for name in ('office.task', 'codex.run', 'codex.web_search'))
        self.assertIsNone(task_span.parent)
        self.assertEqual(run_span.parent.span_id, task_span.context.span_id)
        self.assertEqual(tool_span.parent.span_id, run_span.context.span_id)
        self.assertEqual(len({span.context.trace_id for span in spans.values()}), 1)
        self.assertEqual(task_span.attributes['nekonode.task.id'], task['id'])
        self.assertEqual([span.attributes['openinference.span.kind'] for span in (task_span, run_span, tool_span)],
                         ['CHAIN', 'AGENT', 'TOOL'])
        self.assertEqual(run_span.attributes['llm.token_count.prompt'], 11)
        self.assertEqual(run_span.attributes['llm.token_count.completion'], 5)
        self.assertEqual(tool_span.attributes['nekonode.item.id'], 'search-1')
        self.assertTrue(all(span.start_time <= span.end_time for span in spans.values()))
        self.assertTrue(all(span.attributes['nekonode.status'] == 'completed' for span in spans.values()))
        saved = self.store.get(task['id'])
        self.assertEqual(saved['status'], 'completed')
        self.assertEqual((self.store.root / saved['artifact']).read_text(), FINAL['content'])
        self.assertIn('thinking', [event['status'] for event in saved['events']])
        self.assert_private_content_absent()

    def test_completion_without_start_is_an_event_not_an_invented_tool_duration(self):
        agent = self.codex("emit('item.completed', id='search-1', type='web_search', query=private)\n")
        office, _ = self.submit(agent)
        office.execute(self.store.claim())
        self.assertEqual({span.name for span in self.spans()}, {'office.task', 'codex.run'})
        run = next(span for span in self.spans() if span.name == 'codex.run')
        self.assertIn('codex.item.completed', [event.name for event in run.events])

    def test_duplicate_tool_lifecycle_does_not_create_duplicate_spans(self):
        body = ("for _ in range(2):\n"
                "    emit('item.started', id='search-1', type='web_search')\n"
                "    emit('item.started', id='search-1', type='web_search')\n"
                "    emit('item.completed', id='search-1', type='web_search')\n"
                "    emit('item.completed', id='search-1', type='web_search')\n")
        office, _ = self.submit(self.codex(body))
        office.execute(self.store.claim())
        self.assertEqual(sum(span.name == 'codex.web_search' for span in self.spans()), 1)

    def test_cancelled_real_process_ends_spans_and_never_saves_completed_result(self):
        office, task = self.submit(self.codex(
            "emit('item.started', id='search-1', type='web_search')\ntime.sleep(30)\n", final=None))
        original_change = self.store.change

        def cancel_after_search_started(id_, status, message, **fields):
            original_change(id_, status, message, **fields)
            if message == 'Codex 正在查詢公開來源。':
                self.store.cancel(id_)

        with mock.patch.object(self.store, 'change', side_effect=cancel_after_search_started):
            with self.assertRaises(app.Cancelled):
                office.execute(self.store.claim())
        self.assertEqual({span.name for span in self.spans()}, {'office.task', 'codex.run', 'codex.web_search'})
        self.assertTrue(all(span.attributes['nekonode.status'] == 'cancelled' for span in self.spans()))
        self.assertTrue(all(span.status.status_code != StatusCode.ERROR for span in self.spans()))
        self.assertEqual(self.store.get(task['id'])['status'], 'cancelled')
        self.assertIsNone(self.store.get(task['id'])['artifact'])
        self.assertEqual(list((self.root / 'runtime/agent-runs').iterdir()), [])

    def test_provider_error_ends_open_tool_and_preserves_original_exception(self):
        office, task = self.submit(self.codex("emit('item.started', id='search-1', type='web_search')\n", final=None))
        with self.assertRaises(app.ProviderError):
            office.execute(self.store.claim())
        spans = {span.name: span for span in self.spans()}
        self.assertEqual(spans['codex.web_search'].attributes['nekonode.status'], 'interrupted')
        self.assertEqual(spans['codex.run'].attributes['error.type'], 'ProviderError')
        self.assertEqual(spans['office.task'].attributes['error.type'], 'ProviderError')
        self.assertTrue(all(span.status.status_code == StatusCode.ERROR for span in spans.values()))
        self.assertIsNone(self.store.get(task['id'])['artifact'])

    def test_application_exception_text_is_not_exported_or_swallowed(self):
        office, _ = self.submit()
        error = RuntimeError(PRIVATE)
        office.model.hook = mock.Mock(side_effect=error)
        with self.assertRaises(RuntimeError) as raised:
            office.execute(self.store.claim())
        self.assertIs(raised.exception, error)
        self.assertEqual(self.spans()[0].attributes['error.type'], 'RuntimeError')
        self.assert_private_content_absent()

    def test_manual_continuation_has_separate_trace_and_previous_task_reference(self):
        office, first = self.submit()
        office.execute(self.store.claim())
        second = office.command({'id': str(uuid.uuid4()), 'prompt': '接續合成工作', 'parent_id': first['id']})['task']
        office.execute(self.store.claim())
        spans = {span.attributes['nekonode.task.id']: span for span in self.spans()}
        self.assertIsNone(spans[first['id']].parent)
        self.assertIsNone(spans[second['id']].parent)
        self.assertNotEqual(spans[first['id']].context.trace_id, spans[second['id']].context.trace_id)
        self.assertEqual(spans[second['id']].attributes['nekonode.task.previous_id'], first['id'])

    def test_tracer_initialization_failure_does_not_change_task_result(self):
        office, task = self.submit(self.codex())
        with mock.patch.object(self.telemetry.tracer, 'start_as_current_span', side_effect=RuntimeError(PRIVATE)):
            with self.assertLogs(telemetry_module.__name__, level='WARNING') as logs:
                office.execute(self.store.claim())
        self.assertNotIn(PRIVATE, '\n'.join(logs.output))
        self.assertEqual(self.store.get(task['id'])['status'], 'completed')
        self.assertEqual(self.store.get(task['id'])['result'], FINAL['content'])

    def test_event_observer_failure_does_not_change_durable_progress_or_result(self):
        office, task = self.submit(self.codex())
        with mock.patch.object(telemetry_module.CodexObservation, '_event', side_effect=RuntimeError(PRIVATE)):
            with self.assertLogs(telemetry_module.__name__, level='WARNING'):
                office.execute(self.store.claim())
        saved = self.store.get(task['id'])
        self.assertEqual(saved['status'], 'completed')
        self.assertIn('tool', [event['status'] for event in saved['events']])
        self.assert_private_content_absent()

    def test_sdk_exporter_failure_does_not_fail_successful_work(self):
        attempted = threading.Event()

        class FailingExporter(SpanExporter):
            def export(self, spans):
                attempted.set()
                raise ConnectionError('synthetic collector outage')

        self.provider.add_span_processor(BatchSpanProcessor(FailingExporter(), schedule_delay_millis=60000))
        office, task = self.submit(self.codex())
        with self.assertLogs(level='ERROR'):
            office.execute(self.store.claim())
            self.provider.force_flush(timeout_millis=2000)
        self.assertTrue(attempted.is_set())
        self.assertEqual(self.store.get(task['id'])['status'], 'completed')
        self.assertEqual(self.store.get(task['id'])['result'], FINAL['content'])

    def test_limits_bound_events_and_tools_while_late_usage_is_still_recorded(self):
        with self.telemetry.agent({'id': str(uuid.uuid4())}) as observer:
            for i in range(observer.MAX_TOOL_SPANS + 20):
                for phase in ('item.started', 'item.completed'):
                    observer.event({'type': phase, 'item': {'type': 'web_search', 'id': f'search-{i}'}})
            observer.event({'type': 'turn.completed', 'usage': {'input_tokens': 17, 'output_tokens': 9}})
        run = next(span for span in self.spans() if span.name == 'codex.run')
        self.assertEqual(sum(span.name == 'codex.web_search' for span in self.spans()), observer.MAX_TOOL_SPANS)
        self.assertLessEqual(len(run.events), observer.MAX_EVENTS)
        self.assertGreater(run.attributes['nekonode.trace.dropped_events'], 0)
        self.assertEqual(run.attributes['llm.token_count.prompt'], 17)
        self.assertEqual(run.attributes['llm.token_count.completion'], 9)

    def test_malformed_metadata_and_invalid_usage_are_ignored(self):
        with self.telemetry.agent({'id': str(uuid.uuid4())}) as observer:
            for event in (None, [], {'type': []}, {'type': 'unknown', 'text': PRIVATE},
                          {'type': 'item.started', 'item': None},
                          {'type': 'item.started', 'item': {'type': [], 'id': []}},
                          {'type': 'item.started', 'item': {'type': 'web_search', 'id': 'x' * 129}}):
                observer.event(event)
            observer.event({'type': 'turn.completed', 'usage': {'input_tokens': True, 'output_tokens': -1}})
            observer.event({'type': 'turn.completed', 'usage': {'input_tokens': 2 ** 63, 'output_tokens': PRIVATE}})
        self.assertEqual(len(self.spans()), 1)
        self.assertNotIn('llm.token_count.prompt', self.spans()[0].attributes)
        self.assertNotIn('llm.token_count.completion', self.spans()[0].attributes)
        self.assert_private_content_absent()

    def test_enabled_loader_works_in_isolated_python_mode(self):
        script = (
            'import importlib.util\n'
            f'spec=importlib.util.spec_from_file_location("office", {app.__file__!r})\n'
            'app=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(app)\n'
            'telemetry=app.load_telemetry()\nassert telemetry is not None\ntelemetry.shutdown()\n'
        )
        result = subprocess.run([sys.executable, '-I', '-c', script], capture_output=True, text=True, timeout=5,
                                env={**os.environ, 'NEKO_TRACE_ENABLED': '1',
                                     'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': 'http://127.0.0.1:1/v1/traces'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shutdown_does_not_wait_indefinitely_for_blocked_exporter(self):
        release, finished = threading.Event(), threading.Event()

        def blocked_shutdown():
            try:
                release.wait(2)
            finally:
                finished.set()

        provider = mock.Mock()
        provider.shutdown.side_effect = blocked_shutdown
        telemetry = telemetry_module.OfficeTelemetry(provider)
        started = time.monotonic()
        try:
            with self.assertLogs(telemetry_module.__name__, level='WARNING'):
                telemetry.shutdown(timeout_seconds=0.02)
            self.assertLess(time.monotonic() - started, 0.5)
            self.assertFalse(finished.is_set())
        finally:
            release.set()
        self.assertTrue(finished.wait(1))


if __name__ == '__main__':
    unittest.main()
