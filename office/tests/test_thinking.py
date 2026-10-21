"""Codex reasoning summaries, interim reports and searches reach the task events."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from test_office import app, FakeModel


def uid():
    return str(uuid.uuid4())


FAKE_CODEX = '''import json,sys,pathlib
if sys.argv[1:]==['login','status']: sys.exit(0)
args=sys.argv
assert 'model_reasoning_summary="detailed"' in args and 'hide_agent_reasoning=false' in args
sys.stdin.read()
def emit(kind, phase='item.completed', **item):
    print(json.dumps({'type': phase, 'item': dict(id='i', type=kind, **item)}), flush=True)
emit('reasoning', text='**先確認範圍**\\n使用者要比較三家方案。')
emit('agent_message', text='我先查官方價格頁。')
emit('web_search', phase='item.started', query='')
emit('web_search', query='Hostinger KVM 2 price')
emit('reasoning', summary=[{'type': 'summary_text', 'text': '整理成表格'}])
final = {'kind': 'completed', 'content': '三家價格表', 'next_step': ''}
emit('agent_message', text=json.dumps(final, ensure_ascii=False))
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(final, ensure_ascii=False))
print(json.dumps({'type': 'turn.completed', 'usage': {}}))
'''


class ThinkingNotes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = app.Store(Path(self.temp.name) / 'data')
        self.agent = app.CodexAgent(Path(self.temp.name) / 'runtime')
        self.agent.binary.parent.mkdir()
        self.agent.binary.write_text('#!/usr/bin/env python3\n' + FAKE_CODEX)
        self.agent.binary.chmod(0o700)
        (self.agent.binary.parent / 'codex-code-mode-host').write_text('fixture host presence')
    def tearDown(self): self.temp.cleanup()

    def test_agent_reports_thinking_messages_and_searches_in_order(self):
        notes = []
        result, _ = self.agent.run({'id': uid(), 'prompt': '比較', 'source': '', 'source_snapshot': None,
                                    'context_snapshot': ''}, lambda: None, lambda _: None,
                                   note=lambda kind, text: notes.append((kind, text)))
        self.assertEqual(result['content'], '三家價格表')
        self.assertEqual(notes, [('thinking', '**先確認範圍**\n使用者要比較三家方案。'),
                                 ('message', '我先查官方價格頁。'),
                                 ('tool', '搜尋：Hostinger KVM 2 price'),
                                 ('thinking', '整理成表格')])

    def test_office_stores_notes_without_changing_status(self):
        office = app.Office(self.store, FakeModel(), self.agent)
        task = office.command({'id': uid(), 'prompt': '比較三家 VPS'})['task']
        office.execute(self.store.claim())
        saved = self.store.get(task['id'])
        self.assertEqual(saved['status'], 'completed')
        kinds = [e['status'] for e in saved['events']]
        self.assertEqual([k for k in kinds if k in app.Store.NOTE_KINDS], ['thinking', 'message', 'tool', 'thinking'])
        self.assertLess(kinds.index('thinking'), kinds.index('completed'))

    def test_note_limits(self):
        task = self.store.submit(uid(), '測試', '', 'm')
        self.store.note(task['id'], 'thinking', '長' * 5000)
        self.store.note(task['id'], 'unknown', 'ignored')
        self.store.note(task['id'], 'message', '   ')
        events = [e for e in self.store.get(task['id'])['events'] if e['status'] in app.Store.NOTE_KINDS]
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0]['message'].endswith('（已截斷）') and len(events[0]['message']) < 4010)
        for _ in range(app.Store.NOTE_LIMIT + 5):
            self.store.note(task['id'], 'tool', 'x')
        notes = [e for e in self.store.get(task['id'])['events'] if e['status'] in app.Store.NOTE_KINDS]
        self.assertEqual(len(notes), app.Store.NOTE_LIMIT)
        status_before = self.store.get(task['id'])['status']
        self.store.cancel(task['id'])
        count = len(self.store.get(task['id'])['events'])
        self.store.note(task['id'], 'thinking', 'after cancel')
        self.assertEqual(len(self.store.get(task['id'])['events']), count)
        self.assertNotEqual(status_before, 'cancelled')


class StallReport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.agent = app.CodexAgent(Path(self.temp.name) / 'runtime')
        self.agent.HEARTBEAT_SECONDS, self.agent.STALL_SECONDS = 0.2, 0.6
        self.agent.binary.parent.mkdir()
        (self.agent.binary.parent / 'codex-code-mode-host').write_text('fixture host presence')
    def tearDown(self): self.temp.cleanup()

    def run_with(self, body):
        self.agent.binary.write_text('#!/usr/bin/env python3\nimport json,sys,time,pathlib\n'
            "if sys.argv[1:]==['login','status']: sys.exit(0)\nargs=sys.argv\nsys.stdin.read()\n"
            "def tick(): print(json.dumps({'type':'item.started','item':{'type':'web_search'}}), flush=True)\n" + body +
            "\npathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps({'kind':'completed','content':'ok','next_step':''}))\n")
        self.agent.binary.chmod(0o700)
        progress = []
        self.agent.run({'id': uid(), 'prompt': 'x', 'source': '', 'source_snapshot': None, 'context_snapshot': ''},
                       lambda: None, progress.append)
        return [p for p in progress if p.startswith('Codex 處理中')]

    def test_silent_codex_is_reported_as_possibly_stuck(self):
        beats = self.run_with('tick()\ntime.sleep(1.5)')
        self.assertTrue(any('可能卡住' in b for b in beats), beats)

    def test_active_codex_is_not_reported_as_stuck(self):
        beats = self.run_with('for _ in range(15):\n    tick(); time.sleep(0.1)')
        self.assertTrue(beats)
        self.assertFalse(any('可能卡住' in b for b in beats), beats)


if __name__ == '__main__': unittest.main()
