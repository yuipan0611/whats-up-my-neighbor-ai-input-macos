"""Replacement tests use existing injection points, not another task framework."""
import ast
from contextlib import contextmanager, nullcontext
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from test_office import app, FakeModel

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('observation_ports', ROOT / 'observation_ports.py')
ports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ports)


class RecordingTaskObserver:
    """Independent stdlib implementation: no OTel API, SDK, span or exporter."""

    def __init__(self):
        self.calls = []
        self.handles = []

    @contextmanager
    def task(self, task):
        handle = object()  # Intentionally has no OTel attributes or methods.
        self.handles.append(handle)
        self.calls.append(('start', task['id']))
        try:
            yield handle
        finally:
            self.calls.append(('end', task['id']))

    def outcome(self, handle, status, error_type=None):
        if not any(handle is known for known in self.handles):
            raise AssertionError('Core passed a foreign observation handle')
        self.calls.append(('outcome', status))

    def shutdown(self, timeout_seconds=2.0):
        pass


class DiscardingTaskObserver:
    """A second independently implemented adapter, with a different handle."""

    def task(self, task):
        return nullcontext(None)

    def outcome(self, handle, status, error_type=None):
        if handle is not None:
            raise AssertionError('Core inspected or replaced the opaque handle')

    def shutdown(self, timeout_seconds=2.0):
        pass


class RecordingCodexObserver(RecordingTaskObserver):
    @contextmanager
    def agent(self, task):
        self.calls.append(('agent_start', task['id']))
        try:
            yield self
        finally:
            self.calls.append(('agent_end', task['id']))

    def event(self, event):
        # Do not export text/query/prompt, even in this recording test double.
        self.calls.append(('event', event['type']))


class ObservationPortabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def execute(self, name, observer):
        store = app.Store(self.root / name)
        office = app.Office(store, FakeModel(), telemetry=observer)
        task = office.command({'id': str(uuid.uuid4()), 'prompt': '寫一句問候'})['task']
        office.execute(store.claim())
        saved = store.get(task['id'])
        # Compare the durable public result and replay payload, not UUID/time.
        return (saved['status'], saved['result'],
                [(e['status'], e['message']) for e in store.sync(0)['events']],
                (store.root / saved['artifact']).read_text())

    def test_task_core_accepts_two_unrelated_adapters_and_disabled_mode(self):
        expected = self.execute('disabled', None)
        for index, observer in enumerate((RecordingTaskObserver(), DiscardingTaskObserver())):
            with self.subTest(adapter=type(observer).__name__):
                self.assertIsInstance(observer, ports.TaskObserver)
                self.assertNotIsInstance(observer, ports.CodexObserver)
                self.assertEqual(self.execute(str(index), observer), expected)

    def test_core_passes_opaque_handle_back_without_using_sdk_methods(self):
        observer = RecordingTaskObserver()
        self.execute('opaque', observer)
        self.assertEqual([entry[0] for entry in observer.calls], ['start', 'outcome', 'end'])
        self.assertEqual(observer.calls[1], ('outcome', 'completed'))
        self.assertEqual(len(observer.handles), 1)
        self.assertFalse(hasattr(observer.handles[0], 'set_attributes'))

    def test_replacing_observer_preserves_prior_results_and_event_cursor(self):
        store = app.Store(self.root / 'shared')
        first = app.Office(store, FakeModel(), telemetry=RecordingTaskObserver())
        original = first.command({'id': str(uuid.uuid4()), 'prompt': '寫一句問候'})['task']
        first.execute(store.claim())
        before = store.sync(0)
        cursor = before['latest_seq']
        second = app.Office(store, FakeModel(), telemetry=DiscardingTaskObserver())
        new = second.command({'id': str(uuid.uuid4()), 'prompt': '寫一句晚安'})['task']
        second.execute(store.claim())
        self.assertEqual(store.get(original['id'])['status'], 'completed')
        self.assertEqual(store.sync(0)['events'][:len(before['events'])], before['events'])
        replay = store.sync(cursor)['events']
        self.assertTrue(replay)
        self.assertTrue(all(event['seq'] > cursor and event['task_id'] == new['id'] for event in replay))
        self.assertEqual(replay[-1]['status'], 'completed')

    def test_cancellation_propagates_and_does_not_publish_a_completed_artifact(self):
        observer = RecordingTaskObserver()
        store = app.Store(self.root / 'cancel')
        model = FakeModel()
        office = app.Office(store, model, telemetry=observer)
        task = office.command({'id': str(uuid.uuid4()), 'prompt': '寫一句問候'})['task']
        model.hook = lambda check: (store.cancel(task['id']), check())
        with self.assertRaises(app.Cancelled):
            office.execute(store.claim())
        self.assertEqual(store.get(task['id'])['status'], 'cancelled')
        self.assertIsNone(store.get(task['id'])['artifact'])
        self.assertEqual([entry[0] for entry in observer.calls], ['start', 'end'])

    def test_application_error_identity_is_preserved_across_adapter(self):
        observer = RecordingTaskObserver()
        error = RuntimeError('synthetic application error')

        def fail(check):
            raise error

        store = app.Store(self.root / 'error')
        office = app.Office(store, FakeModel(hook=fail), telemetry=observer)
        task = office.command({'id': str(uuid.uuid4()), 'prompt': '寫一句問候'})['task']
        with self.assertRaises(RuntimeError) as raised:
            office.execute(store.claim())
        self.assertIs(raised.exception, error)
        self.assertIsNone(store.get(task['id'])['artifact'])
        self.assertEqual([entry[0] for entry in observer.calls], ['start', 'end'])

    def test_actual_cli_parser_accepts_a_non_otel_observer(self):
        observer = RecordingCodexObserver()
        self.assertIsInstance(observer, ports.CodexObserver)
        self.assertIsInstance(observer, ports.CodexEventReceiver)
        agent = app.CodexAgent(self.root / 'runtime', observer)
        agent.binary.parent.mkdir(parents=True)
        # Synthetic executable, never a real provider or authenticated session.
        agent.binary.write_text(
            '#!/usr/bin/env python3\nimport json,sys,pathlib\n'
            "if sys.argv[1:]==['login','status']: sys.exit(0)\n"
            'sys.stdin.read()\n'
            "for phase in ('item.started','item.completed'):\n"
            " print(json.dumps({'type':phase,'item':{'id':'search-1','type':'web_search','query':'PRIVATE_REPLACEMENT_SENTINEL'}}),flush=True)\n"
            "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':3,'output_tokens':2}}),flush=True)\n"
            "pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(json.dumps({'kind':'completed','content':'synthetic result','next_step':''}))\n"
        )
        agent.binary.chmod(0o700)
        (agent.binary.parent / 'codex-code-mode-host').write_text('synthetic fixture')
        store = app.Store(self.root / 'cli-data')
        office = app.Office(store, FakeModel(), agent, observer)
        task = office.command({'id': str(uuid.uuid4()), 'prompt': '合成替換測試'})['task']
        office.execute(store.claim())
        self.assertEqual(store.get(task['id'])['result'], 'synthetic result')
        self.assertEqual([entry[0] for entry in observer.calls],
                         ['start', 'agent_start', 'event', 'event', 'event', 'agent_end', 'outcome', 'end'])
        self.assertNotIn('PRIVATE_REPLACEMENT_SENTINEL', json.dumps(observer.calls))

    def test_task_core_has_no_direct_framework_or_backend_imports(self):
        # This is a direct-import guard, not proof against every dynamic import.
        forbidden = {'opentelemetry', 'openinference', 'phoenix', 'langfuse',
                     'dbos', 'langgraph', 'crewai'}
        tree = ast.parse((ROOT / 'office.py').read_text())
        imported = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.extend(alias.name.split('.')[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.append(node.module.split('.')[0])
        self.assertFalse(forbidden.intersection(imported))

    def test_observation_contract_imports_are_standard_library_only(self):
        tree = ast.parse((ROOT / 'observation_ports.py').read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split('.')[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split('.')[0])
        self.assertLessEqual(imported, {'__future__', 'typing', 'collections'})


if __name__ == '__main__':
    unittest.main()
