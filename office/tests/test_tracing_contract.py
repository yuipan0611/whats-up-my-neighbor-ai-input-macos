"""SDK-free contract proof: provider metadata and business outcomes are portable."""
from collections import deque
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from test_office import app, FakeModel


spec = importlib.util.spec_from_file_location('tested_tracing_contract', Path(app.__file__).with_name('tracing_contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

PRIVATE = 'PRIVATE_PORTABLE_SENTINEL'
RESULT = '合成介面替換測試成果'


class RecordingTaskReporter:
    def __init__(self, record):
        self.record = record

    def outcome(self, status):
        self.record['status'] = status


class RecordingAgentReporter:
    def __init__(self, record):
        self.record = record

    def event(self, event):
        # Record everything supplied at this boundary so a leaked raw payload
        # fails the tests instead of being silently sanitized by the recorder.
        if event.get('schema_version') != 1:
            raise AssertionError('provider did not emit the application event contract')
        self.record['events'].append(dict(event))


class RecordingTelemetry:
    """Bounded standard-library test double, not another production trace store."""
    def __init__(self):
        self.records = deque(maxlen=64)

    @contextmanager
    def task(self, task_id, executor, previous_task_id=''):
        record = {'kind': 'task', 'task_id': task_id, 'executor': executor,
                  'previous_task_id': previous_task_id, 'status': 'started'}
        self.records.append(record)
        try:
            yield RecordingTaskReporter(record)
        except BaseException as error:
            record['status'] = 'cancelled' if type(error).__name__ == 'Cancelled' else 'failed'
            raise

    @contextmanager
    def agent(self, task_id, executor):
        record = {'kind': 'agent', 'task_id': task_id, 'executor': executor,
                  'status': 'started', 'events': deque(maxlen=128)}
        self.records.append(record)
        try:
            yield RecordingAgentReporter(record)
        except BaseException as error:
            record['status'] = 'cancelled' if type(error).__name__ == 'Cancelled' else 'failed'
            raise
        else:
            record['status'] = 'completed'

    def shutdown(self, timeout_seconds=2.0):
        pass


def run_fixture(root, tracing, task_id):
    """The same real Office/CLI parsing path for disabled, recording and OTel."""
    store = app.Store(root / 'data')
    store.upload('selected.txt', PRIVATE)
    agent = app.CodexAgent(root / 'runtime', tracing)
    agent.binary.parent.mkdir(parents=True, exist_ok=True)
    script = '''#!/usr/bin/env python3
import json,sys,pathlib
if sys.argv[1:]==['login','status']: sys.exit(0)
args=sys.argv
sys.stdin.read()
private="PRIVATE_PORTABLE_SENTINEL"
def emit(phase, **item):
    print(json.dumps({'type':phase,'item':item,'private_extra':private}),flush=True)
print(json.dumps({'type':'thread.started','thread_id':private}),flush=True)
print(json.dumps({'type':'turn.started','prompt':private}),flush=True)
emit('item.completed',type='reasoning',id='reason-1',text=private)
emit('item.started',type='web_search',id='search-1',query=private)
emit('item.completed',type='web_search',id='search-1',query=private)
emit('item.completed',type='agent_message',id='message-1',text=private)
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':7,'output_tokens':4,'private':private}}),flush=True)
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(
    {'kind':'completed','content':'合成介面替換測試成果','next_step':''},ensure_ascii=False))
'''
    agent.binary.write_text(script)
    agent.binary.chmod(0o700)
    (agent.binary.parent / 'codex-code-mode-host').write_text('synthetic fixture host presence')
    office = app.Office(store, FakeModel(), agent, tracing)
    office.command({'id': task_id, 'prompt': PRIVATE, 'source': 'selected.txt'})
    office.execute(store.claim())
    saved = store.get(task_id)
    return {'status': saved['status'], 'result': saved['result'],
            'artifact_text': (store.root / saved['artifact']).read_text(),
            'event_statuses': [event['status'] for event in saved['events']],
            # Durations and timestamps are inherently variable; compare the
            # persisted notes and statuses which define the behavior contract.
            'notes': [(event['status'], event['message']) for event in saved['events']
                      if event['status'] in app.Store.NOTE_KINDS],
            'usage': json.loads(saved['metrics'])['usage']}


class PortableTracingContractTests(unittest.TestCase):
    def test_recording_backend_replaces_sdk_without_changing_business_behavior(self):
        recording = RecordingTelemetry()
        self.assertIsInstance(recording, contract.TracePort)
        task_id = str(uuid.uuid4())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = run_fixture(root / 'disabled', None, task_id)
            recorded = run_fixture(root / 'recording', recording, task_id)
        self.assertEqual(recorded, baseline)
        self.assertEqual(recorded['status'], 'completed')
        self.assertEqual(recorded['result'], RESULT)
        self.assertEqual(recorded['artifact_text'], RESULT)
        self.assertEqual([row['kind'] for row in recording.records], ['task', 'agent'])
        self.assertTrue(all(row['task_id'] == task_id and row['status'] == 'completed' for row in recording.records))
        events = list(recording.records[-1]['events'])
        self.assertEqual([event['phase'] for event in events],
                         ['session.started', 'run.started', 'item.completed', 'item.started',
                          'item.completed', 'item.completed', 'run.completed'])
        self.assertEqual(events[3]['tool_name'], 'web_search')
        self.assertEqual(events[-1], {'schema_version': 1, 'phase': 'run.completed',
                                    'input_tokens': 7, 'output_tokens': 4})
        self.assertNotIn(PRIVATE, repr(recording.records))

    def test_core_and_recording_work_with_all_site_packages_disabled(self):
        # -S proves the entire tracing SDK can be absent even when the parent
        # test process runs inside the optional SDK venv.
        test_dir = Path(__file__).parent
        script = f'''
import importlib.util,sys,tempfile
from pathlib import Path
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    sys.modules[name]=module
    spec.loader.exec_module(module)
    return module
load('test_office',{str(test_dir / 'test_office.py')!r})
test=load('test_tracing_contract',{str(Path(__file__))!r})
with tempfile.TemporaryDirectory() as directory:
    tracing=test.RecordingTelemetry()
    result=test.run_fixture(Path(directory),tracing,'11111111-1111-4111-8111-111111111111')
    assert result['status']=='completed' and result['result']==test.RESULT
    assert len(tracing.records)==2
assert not any(name.split('.')[0] in ('opentelemetry','openinference','phoenix') for name in sys.modules)
print('stdlib-only contract passed')
'''
        result = subprocess.run([sys.executable, '-I', '-S', '-c', script],
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'stdlib-only contract passed')

    def test_codex_normalizer_uses_only_versioned_neutral_metadata(self):
        raw = {'type': 'item.completed', 'item': {'type': 'web_search', 'id': 'search-1',
               'status': 'failed', 'query': PRIVATE, 'output': PRIVATE}, 'prompt': PRIVATE}
        event = app.CodexAgent.normalise_trace_event(raw)
        self.assertEqual(event, {'schema_version': 1, 'phase': 'item.completed', 'item_kind': 'tool',
                                 'item_id': 'search-1', 'tool_name': 'web_search', 'outcome': 'failed'})
        self.assertNotIn(PRIVATE, json.dumps(event))
        self.assertEqual(raw['item']['query'], PRIVATE)  # Source event is not mutated.
        for raw in (None, [], {'type': []}, {'type': 'vendor.future', 'data': PRIVATE}):
            self.assertIsNone(app.CodexAgent.normalise_trace_event(raw))
        for raw in ({'type': 'item.started', 'item': None},
                    {'type': 'item.started', 'item': {'type': [], 'id': []}},
                    {'type': 'item.started', 'item': {'type': 'web_search', 'id': 'x' * 129}},
                    {'type': 'item.completed', 'item': {'type': 'reasoning', 'text': PRIVATE}}):
            event = app.CodexAgent.normalise_trace_event(raw)
            self.assertEqual(event['schema_version'], 1)
            self.assertNotIn(PRIVATE, json.dumps(event))
            self.assertNotIn('item_id', event)

    def test_normalizer_drops_non_integer_negative_and_out_of_range_usage(self):
        for value in (True, False, -1, 2 ** 63, 1.5, PRIVATE, None):
            event = app.CodexAgent.normalise_trace_event(
                {'type': 'turn.completed', 'usage': {'input_tokens': value, 'output_tokens': value}})
            self.assertEqual(event, {'schema_version': 1, 'phase': 'run.completed'})
        self.assertEqual(app.CodexAgent.normalise_trace_event(
            {'type': 'turn.completed', 'usage': {'input_tokens': 0, 'output_tokens': 2 ** 63 - 1, 'extra': PRIVATE}}),
            {'schema_version': 1, 'phase': 'run.completed', 'input_tokens': 0, 'output_tokens': 2 ** 63 - 1})

    def test_reporter_contract_preserves_cancellation_and_original_exception(self):
        recording = RecordingTelemetry()
        with recording.task('synthetic', 'fixture') as reporter:
            self.assertIsInstance(reporter, contract.TaskReporter)
            reporter.outcome('needs_input')
        self.assertEqual(recording.records[-1]['status'], 'needs_input')
        cancelled = app.Cancelled()
        with self.assertRaises(app.Cancelled) as raised:
            with recording.task('synthetic', 'fixture'):
                with recording.agent('synthetic', 'fixture') as reporter:
                    self.assertIsInstance(reporter, contract.AgentReporter)
                    raise cancelled
        self.assertIs(raised.exception, cancelled)
        self.assertEqual([row['status'] for row in list(recording.records)[-2:]], ['cancelled', 'cancelled'])


if __name__ == '__main__':
    unittest.main()
