import json
import os
from pathlib import Path
import signal
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid
from test_office import app, FakeModel


def uid():
    return str(uuid.uuid4())


class Agent:
    model = 'synthetic-agent'
    def __init__(self): self.calls = []
    def run(self, task, check, progress, note=None):
        check(); self.calls.append(task); progress('合成測試事件')
        return {'kind': 'completed', 'content': '外部測試成果', 'next_step': '人工核對'}, {'provider': 'fixture'}
    def health(self): return {'name': 'fixture', 'authenticated': True, 'installed': True}


class PersistenceV2(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'data'
        self.store = app.Store(self.root)
    def tearDown(self): self.temp.cleanup()
    def test_additive_migration_preserves_old_task_and_artifact(self):
        task = self.store.submit(uid(), '舊的任務', '', 'old-gemma')
        path = self.store.save(task['id'], '既有結果')
        self.store.change(task['id'], 'completed', 'old', result='既有結果', artifact=path)
        with self.store.connect() as c:
            for field in ('executor', 'parent_id', 'journal_ids', 'context_snapshot'):
                c.execute('ALTER TABLE tasks DROP COLUMN ' + field)
        recovered = app.Store(self.root)
        self.assertEqual(recovered.get(task['id'])['executor'], 'gemma')
        self.assertEqual(recovered.get(task['id'])['result'], '既有結果')
        self.assertEqual((self.root/path).read_text(), '既有結果')
        self.assertEqual(app.Store(self.root).get(task['id'])['model'], 'old-gemma')
    def test_journal_idempotent_raw_export_without_model(self):
        body = {'id': uid(), 'day': '2026-10-21', 'text': '不確定週五是否出門。'}
        self.store.add_journal(body); self.store.add_journal(body)
        fresh = app.Store(self.root)
        self.assertEqual(len(fresh.journal()), 1)
        self.assertEqual(fresh.journal()[0]['text'], body['text'])
        self.assertIn(body['text'], (self.root/'journal/2026-10-21.md').read_text())
        with self.assertRaises(app.OfficeError): self.store.add_journal({**body, 'text': '不同內容'})
        with self.assertRaises(app.OfficeError): self.store.add_journal({**body, 'id': uid(), 'day': '2026-02-30'})
    def test_handoff_contains_new_note_and_child_freezes_only_selected_context(self):
        agent = Agent(); office = app.Office(self.store, FakeModel(), agent)
        original = office.command({'id': uid(), 'prompt': '第一件工作'})['task']
        office.execute(self.store.claim())
        body = {'id': uid(), 'note': '已人工核對日期', 'next_step': '比較第二方案'}
        self.store.add_handoff(original['id'], body); self.store.add_handoff(original['id'], body)
        export = self.root/'tasks'/original['id']/'handoff.md'
        self.assertIn(body['next_step'], export.read_text())
        self.assertEqual(export.read_text().count('已人工核對日期'), 1)
        a = {'id': uid(), 'day': '2026-10-21', 'text': '可分享的紀錄'}
        b = {'id': uid(), 'day': '2026-10-21', 'text': 'PRIVATE_UNSELECTED_SENTINEL'}
        self.store.add_journal(a); self.store.add_journal(b)
        request = {'id': uid(), 'prompt': '接著比較', 'parent_id': original['id'], 'journal_ids': [a['id']]}
        child = office.command(request)['task']
        self.store.add_handoff(original['id'], {'id': uid(), 'note': '稍後更動', 'next_step': ''})
        self.assertNotIn('稍後更動', child['context_snapshot'])
        office.execute(self.store.claim())
        self.assertIn(body['next_step'], agent.calls[-1]['context_snapshot'])
        self.assertIn(a['text'], agent.calls[-1]['context_snapshot'])
        self.assertNotIn(b['text'], json.dumps(agent.calls[-1], ensure_ascii=False))
        self.assertEqual(office.command(request)['task']['id'], child['id'])
        self.assertIn(a['text'], self.store.handoff_text(child['id']))
        self.assertNotIn(b['text'], self.store.handoff_text(child['id']))
        with self.assertRaises(app.OfficeError): office.command({**request, 'journal_ids': []})
        self.assertEqual(self.store.get(original['id'])['result'], '外部測試成果\n\n## 建議下一步\n\n人工核對')
    def test_default_external_never_calls_gemma_and_cancel_blocks_save(self):
        model = FakeModel(); model.generate = lambda *a: self.fail('Gemma must be optional')
        office = app.Office(self.store, model, Agent())
        first = office.command({'id': uid(), 'prompt': '寫一句問候'})['task']
        office.execute(self.store.claim())
        self.assertEqual(self.store.get(first['id'])['status'], 'completed')
        second = office.command({'id': uid(), 'prompt': '第二件'})['task']
        claim = self.store.claim()
        office.agent.run = lambda task, check, progress, note=None: (self.store.cancel(task['id']), check())
        with self.assertRaises(app.Cancelled): office.execute(claim)
        self.assertFalse((self.root/'tasks'/second['id']).exists())
    def test_missing_login_keeps_task_without_fabricated_result(self):
        agent = app.CodexAgent(Path(self.temp.name)/'runtime')
        office = app.Office(self.store, FakeModel(), agent)
        task = office.command({'id': uid(), 'prompt': '待登入工作'})['task']
        office.start()
        try:
            deadline = time.monotonic()+3
            while self.store.get(task['id'])['status'] != 'needs_provider' and time.monotonic() < deadline: time.sleep(.02)
            saved = self.store.get(task['id'])
            self.assertEqual(saved['status'], 'needs_provider')
            self.assertIsNone(saved['result'])
        finally: office.stopping.set(); office.thread.join(2)
    def test_journal_selected_gemma_path_uses_frozen_context(self):
        body = {'id': uid(), 'day': '2026-10-21', 'text': '星期五可能參訪，尚未確定。'}
        self.store.add_journal(body)
        model = FakeModel(action='summarize')
        office = app.Office(self.store, model, Agent())
        task = office.command({'id': uid(), 'prompt': '摘要紀錄', 'executor': 'gemma', 'journal_ids': [body['id']]})['task']
        office.execute(self.store.claim())
        self.assertEqual(self.store.get(task['id'])['status'], 'completed')
        self.assertIn(body['text'], model.prompts[-1])
        model.action = 'external'
        task = office.command({'id': uid(), 'prompt': '上網研究今天新聞', 'executor': 'gemma'})['task']
        office.execute(self.store.claim())
        self.assertIn('改交 Codex', self.store.get(task['id'])['result'])
        self.assertNotIn('尚未接通', self.store.get(task['id'])['result'])


class CodexProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name)
        self.agent = app.CodexAgent(self.runtime)
        self.agent.binary.parent.mkdir()
        self.task = {'id': uid(), 'prompt': '測試工作', 'source': '', 'source_snapshot': None, 'context_snapshot': '選取的交接'}
    def tearDown(self): self.temp.cleanup()
    def executable(self, script):
        self.agent.binary.write_text('#!/usr/bin/env python3\n'+script)
        self.agent.binary.chmod(0o700)
        (self.agent.binary.parent/'codex-code-mode-host').write_text('fixture host presence')
    def test_bounded_adapter_stdin_flags_and_clean_environment(self):
        self.executable('''import json,sys,os,pathlib
if sys.argv[1:]==['login','status']: sys.exit(0)
args=sys.argv
assert '--ephemeral' in args and args[args.index('--sandbox')+1]=='read-only'
assert args[args.index('-a')+1]=='never'
assert 'OPENAI_API_KEY' not in os.environ
assert 'shell_tool' in args and 'unified_exec' in args
assert '選取的交接' in sys.stdin.read()
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps({'kind':'completed','content':'完整結果','next_step':''}))
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':4}}))
''')
        old = os.environ.get('OPENAI_API_KEY'); os.environ['OPENAI_API_KEY'] = 'fixture-not-a-key'
        try: result, metrics = self.agent.run(self.task, lambda: None, lambda _: None)
        finally:
            if old is None: os.environ.pop('OPENAI_API_KEY')
            else: os.environ['OPENAI_API_KEY'] = old
        self.assertEqual(result['content'], '完整結果')
        self.assertEqual(metrics['usage']['input_tokens'], 4)
        self.assertEqual(list((self.runtime/'agent-runs').iterdir()), [])
    def test_cancel_terminates_owned_process_group(self):
        marker = self.runtime/'child.pid'
        self.executable(f'''import sys,time,subprocess,pathlib
if sys.argv[1:]==['login','status']: sys.exit(0)
sys.stdin.read()
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
pathlib.Path({str(marker)!r}).write_text(str(child.pid))
time.sleep(30)
''')
        def check():
            if marker.exists(): raise app.Cancelled()
        started=time.monotonic()
        with self.assertRaises(app.Cancelled): self.agent.run(self.task, check, lambda _: None)
        self.assertLess(time.monotonic()-started, 4)
        pid=int(marker.read_text())
        for _ in range(20):
            try: os.kill(pid,0)
            except ProcessLookupError: break
            time.sleep(.05)
        else:
            # Linux may retain the dead child as a zombie until PID 1 reaps it.
            stat=Path(f'/proc/{pid}/stat')
            self.assertTrue(stat.exists() and stat.read_text().split()[2]=='Z')
    def test_invalid_external_response_never_completed(self):
        self.executable('''import sys,pathlib
if sys.argv[1:]==['login','status']: sys.exit(0)
sys.stdin.read()
pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text('{"kind":"completed"}')
''')
        with self.assertRaises(app.ProviderError): self.agent.run(self.task, lambda: None, lambda _: None)


if __name__ == '__main__': unittest.main()
