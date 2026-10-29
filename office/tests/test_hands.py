"""Hands tasks and the worker API (agent-hands PRD 5.2, 7, 9).

The worker and the agent it runs share one Linux account, so the worker socket must
not answer anything beyond the hands task itself."""
import base64
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_office import app, FakeModel, LOCAL_HOST, local_request

OFFICE_PY = Path(__file__).parents[1] / 'office.py'


def uid():
    return str(uuid.uuid4())


class HandsBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.store = app.Store(root / 'data')
        self.office = app.Office(self.store, FakeModel())
        self.local_path = root / 'run' / 'office.sock'
        self.worker_path = root / 'worker' / 'worker.sock'
        self.server = app.Server(0, self.office, local_socket=self.local_path, worker_socket=self.worker_path)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def hands_task(self, prompt='去網站下載報表', **extra):
        return self.office.command({'id': uid(), 'prompt': prompt, 'executor': 'hands', **extra})['task']

    def worker(self, path, body=None, method='POST'):
        data = None if method == 'GET' else json.dumps(body or {}).encode()
        status, raw, _ = local_request(self.worker_path, path, data, {'Content-Type': 'application/json'}, method)
        return status, json.loads(raw) if raw else None

    def claim(self):
        status, body = self.worker('/api/worker/claim')
        self.assertEqual(status, 200, body)
        return body['task']

    def as_worker(self, path, claimed, **fields):
        """Call a worker route as the attempt that `claimed` came from."""
        return self.worker(path, {'task_id': claimed['id'], 'lease': claimed['lease'], **fields})


class ClaimTests(HandsBase):
    def test_internal_worker_never_takes_hands_tasks(self):
        task = self.hands_task()
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.store.get(task['id'])['status'], 'queued')
        self.assertEqual(self.store.get(task['id'])['model'], 'hands')

    def test_one_task_at_a_time_in_order(self):
        first, second = self.hands_task('第一件'), self.hands_task('第二件')
        claimed = self.claim()
        self.assertEqual((claimed['id'], claimed['attempts']), (first['id'], 1))
        self.assertIsNone(self.claim())
        self.as_worker('/api/worker/complete', claimed, outcome='completed', text='# 好了')
        self.assertEqual(self.claim()['id'], second['id'])

    def test_claim_carries_only_the_task_itself(self):
        journal = {'id': uid(), 'day': '2026-10-23', 'text': '只給這件工作的生活紀錄'}
        self.store.add_journal(journal)
        self.store.add_journal({'id': uid(), 'day': '2026-10-23', 'text': '沒有選取的私人紀錄'})
        self.office.command({'id': uid(), 'prompt': '別的工作', 'executor': 'gemma'})
        self.hands_task(journal_ids=[journal['id']])
        task = self.claim()
        self.assertEqual(set(task), set(app.Store.HANDS_FIELDS))
        self.assertIn('只給這件工作的生活紀錄', task['context_snapshot'])
        dumped = json.dumps(task, ensure_ascii=False)
        self.assertNotIn('沒有選取的私人紀錄', dumped)
        self.assertNotIn('別的工作', dumped)

    def test_media_stays_with_codex_for_now(self):
        self.store.upload_attachment('photo.png', base64.b64encode(b'\x89PNG\r\n\x1a\n' + b'0' * 16).decode())
        with self.assertRaisesRegex(app.OfficeError, 'Codex'):
            self.hands_task(source='photo.png')


class BoundaryTests(HandsBase):
    def test_worker_socket_answers_nothing_but_worker_routes(self):
        self.hands_task()
        for path in ('/', '/app.js', '/api/tasks', '/api/journal', '/api/bootstrap', '/api/sync?after=0', '/api/devices', '/api/health', '/api/ws'):
            self.assertEqual(self.worker(path, method='GET')[0], 404, path)
        for path in ('/api/command', '/api/journal', '/api/files', '/api/attachments', f'/api/devices/{uid()}/revoke', '/api/pair'):
            self.assertEqual(self.worker(path, {'id': uid(), 'prompt': 'x', 'text': 'x', 'name': 'x.md'})[0], 404, path)
        self.assertEqual(len(self.store.list()), 1)
        self.assertEqual(self.store.journal(), [])

    def test_owner_entries_cannot_call_worker_routes(self):
        self.hands_task()
        headers = {'Host': LOCAL_HOST, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token}
        status, _, _ = local_request(self.local_path, '/api/worker/claim', b'{}', headers)
        self.assertEqual(status, 404)
        self.assertEqual(self.store.list()[0]['status'], 'queued')

    def test_worker_socket_is_group_shared_but_closed_to_others(self):
        sock, parent = self.worker_path.lstat(), self.worker_path.parent.lstat()
        self.assertEqual(stat.S_IMODE(sock.st_mode), 0o660)
        self.assertEqual(stat.S_IMODE(parent.st_mode) & 0o007, 0)
        shared = Path(self.temp.name) / 'open'
        shared.mkdir(); shared.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'mode 750'):
            app.Server(0, self.office, worker_socket=shared / 'worker.sock')

    def test_worker_posts_must_be_json(self):
        status, _, _ = local_request(self.worker_path, '/api/worker/claim', b'{}', {'Content-Type': 'text/plain'})
        self.assertEqual(status, 415)


class LifecycleTests(HandsBase):
    def test_heartbeat_steps_and_completion(self):
        task = self.hands_task()
        claimed = self.claim()
        self.assertEqual(self.as_worker('/api/worker/heartbeat', claimed)[1], {'continue': True, 'status': 'running'})
        events = [{'kind': 'tool', 'message': '打開報表頁面'}, {'kind': 'message', 'message': '找到上個月的報表'}]
        self.assertEqual(self.as_worker('/api/worker/events', claimed, events=events)[1], {'recorded': 2})
        status, body = self.as_worker('/api/worker/complete', claimed, outcome='completed', text='# 報表\n\n已下載。')
        self.assertEqual((status, body['status']), (200, 'completed'))
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result'], saved['artifact']), ('completed', '# 報表\n\n已下載。', f"tasks/{task['id']}/result.md"))
        self.assertEqual([e['message'] for e in saved['events'] if e['status'] in ('tool', 'message')], ['打開報表頁面', '找到上個月的報表'])
        self.assertEqual(self.as_worker('/api/worker/heartbeat', claimed)[1], {'continue': False, 'status': 'completed'})
        self.assertEqual(self.as_worker('/api/worker/complete', claimed, outcome='completed', text='again')[0], 409)

    def test_partial_and_failed_outcomes(self):
        partial = self.hands_task('做一半')
        self.as_worker('/api/worker/complete', self.claim(), outcome='incomplete', text='先做到這裡')
        self.assertEqual((self.store.get(partial['id'])['status'], self.store.get(partial['id'])['artifact']), ('incomplete', f"tasks/{partial['id']}/partial.md"))
        failed = self.hands_task('做不到')
        self.as_worker('/api/worker/complete', self.claim(), outcome='failed', text='', reason='網站要你登入')
        saved = self.store.get(failed['id'])
        self.assertEqual((saved['status'], saved['stage'], saved['artifact']), ('failed', '網站要你登入', None))

    def test_bad_requests_change_nothing(self):
        task = self.hands_task()
        claimed = self.claim()
        bad = [('/api/worker/events', {'events': [{'kind': 'shell', 'message': 'rm -rf'}]}),
               ('/api/worker/events', {'events': []}),
               ('/api/worker/complete', {'outcome': 'done', 'text': 'x'}),
               ('/api/worker/complete', {'outcome': 'completed', 'text': '  '}),
               ('/api/worker/complete', {'outcome': 'completed', 'text': 'x' * 150001})]
        for path, fields in bad:
            self.assertIn(self.as_worker(path, claimed, **fields)[0], (400, 413), fields)
        gemma = self.office.command({'id': uid(), 'prompt': '一般工作', 'executor': 'gemma'})['task']
        valid = {'lease': claimed['lease'], 'events': [{'kind': 'tool', 'message': 'x'}], 'outcome': 'completed', 'text': 'x'}
        for path in ('/api/worker/heartbeat', '/api/worker/events', '/api/worker/complete'):
            self.assertEqual(self.worker(path, {'task_id': gemma['id'], **valid})[0], 404)
            self.assertEqual(self.worker(path, {'task_id': 42, **valid})[0], 404)
        self.assertEqual(self.store.get(task['id'])['status'], 'running')
        self.assertEqual(self.store.get(gemma['id'])['status'], 'queued')

    def test_cancel_stops_the_worker_and_keeps_no_result(self):
        task = self.hands_task()
        claimed = self.claim()
        self.store.cancel(task['id'])
        self.assertEqual(self.as_worker('/api/worker/heartbeat', claimed)[1], {'continue': False, 'status': 'cancelled'})
        self.assertEqual(self.as_worker('/api/worker/events', claimed, events=[{'kind': 'tool', 'message': 'x'}])[0], 409)
        self.assertEqual(self.as_worker('/api/worker/complete', claimed, outcome='completed', text='late')[0], 409)
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result']), ('cancelled', None))
        self.assertFalse((self.store.root / 'tasks' / task['id'] / 'result.md').exists())


class StopTests(HandsBase):
    def test_pause_command_stops_and_holds_hands_work(self):
        running, waiting = self.hands_task('一'), self.hands_task('二')
        claimed = self.claim()
        self.office.command({'prompt': '先停一下'})
        self.assertFalse(self.as_worker('/api/worker/heartbeat', claimed)[1]['continue'])
        status, body = self.worker('/api/worker/claim')
        self.assertEqual((body['task'], body['paused']), (None, True))
        self.office.command({'prompt': '繼續工作'})
        self.assertEqual(self.claim()['id'], waiting['id'])

    def test_take_back_switch(self):
        running, waiting = self.hands_task('一'), self.hands_task('二')
        claimed = self.claim()
        self.store.set_hands_locked(True)
        self.assertEqual(self.store.get(running['id'])['status'], 'cancelled')
        self.assertFalse(self.as_worker('/api/worker/heartbeat', claimed)[1]['continue'])
        status, body = self.worker('/api/worker/claim')
        self.assertEqual((body['task'], body['locked']), (None, True))
        self.assertEqual(self.store.get(waiting['id'])['status'], 'queued')
        self.assertIn(('_office', 'hands_locked'), [(e['task_id'], e['status']) for e in self.store.sync(0)['events']])
        self.store.set_hands_locked(False)
        self.assertEqual(self.claim()['id'], waiting['id'])

    def test_take_back_switch_cli(self):
        run = lambda *a: subprocess.run([sys.executable, '-I', str(OFFICE_PY), 'hands-lock', *a, '--data', str(self.store.root)],
                                        check=True, capture_output=True, text=True).stdout
        self.assertIn('已收回', run('on'))
        self.assertTrue(self.store.hands_locked())
        self.assertIn('已收回', run('status'))
        self.assertIn('開啟中', run('off'))
        self.assertFalse(self.store.hands_locked())


class LeaseTests(HandsBase):
    def test_silent_worker_is_retried_then_reported(self):
        task = self.hands_task()
        for attempt in (1, 2, 3):
            claimed = self.claim()
            self.assertEqual((claimed['id'], claimed['attempts']), (task['id'], attempt))
            self.assertEqual(self.store.expire_hands(time.time() + 10), 0)
            self.assertEqual(self.store.expire_hands(time.time() + app.Store.HANDS_LEASE + 1), 1)
            self.assertEqual(self.store.get(task['id'])['status'], 'queued' if attempt < 3 else 'interrupted')
        self.assertIsNone(self.claim())
        self.assertIn('3 次', self.store.get(task['id'])['stage'])

    def test_any_worker_call_renews_the_lease(self):
        task = self.hands_task()
        claimed = self.claim()
        with self.store.connect() as c:
            c.execute('UPDATE tasks SET heartbeat=? WHERE id=?', (time.time() - app.Store.HANDS_LEASE - 5, task['id']))
        self.as_worker('/api/worker/events', claimed, events=[{'kind': 'tool', 'message': '還在做'}])
        self.assertEqual(self.store.expire_hands(), 0)
        self.assertEqual(self.store.get(task['id'])['status'], 'running')

    def test_office_restart_keeps_the_worker_task(self):
        hands = self.hands_task()
        claimed = self.claim()
        gemma = self.office.command({'id': uid(), 'prompt': '一般工作', 'executor': 'gemma'})['task']
        self.store.claim()
        with self.store.connect() as c:
            c.execute('UPDATE tasks SET heartbeat=0 WHERE id=?', (hands['id'],))
        restarted = app.Store(self.store.root)
        app.Office(restarted, FakeModel())
        self.assertEqual(restarted.get(hands['id'])['status'], 'running')
        self.assertEqual(restarted.get(gemma['id'])['status'], 'interrupted')
        self.assertEqual(restarted.expire_hands(), 0)
        self.assertEqual(restarted.hands_heartbeat(hands['id'], claimed['lease']), {'continue': True, 'status': 'running'})


class FencingTests(HandsBase):
    """A call left over from an earlier attempt must not touch the attempt that replaced it."""

    def requeue(self, task):
        self.assertEqual(self.store.expire_hands(time.time() + app.Store.HANDS_LEASE + 1), 1)
        self.assertEqual(self.store.get(task['id'])['status'], 'queued')

    def test_each_attempt_gets_its_own_lease(self):
        task = self.hands_task()
        first = self.claim()
        self.requeue(task)
        self.assertEqual(self.as_worker('/api/worker/complete', first, outcome='completed', text='# 太晚了')[0], 409)
        second = self.claim()
        self.assertEqual((first['id'], second['id'], second['attempts']), (task['id'], task['id'], 2))
        self.assertGreaterEqual(len(first['lease']), 24)
        self.assertNotEqual(first['lease'], second['lease'])
        self.assertNotIn('lease', self.store.get(task['id']))
        self.assertNotIn('lease', self.store.list()[0])

    def test_stale_attempt_cannot_renew_report_or_finish(self):
        task = self.hands_task()
        stale = self.claim()
        self.requeue(task)
        current = self.claim()
        with self.store.connect() as c:
            c.execute('UPDATE tasks SET heartbeat=0 WHERE id=?', (task['id'],))
        self.assertEqual(self.as_worker('/api/worker/heartbeat', stale)[1], {'continue': False, 'status': 'running', 'superseded': True})
        status, body = self.as_worker('/api/worker/events', stale, events=[{'kind': 'tool', 'message': '舊的一輪還在動'}])
        self.assertEqual((status, body.get('superseded')), (409, True))
        status, body = self.as_worker('/api/worker/complete', stale, outcome='completed', text='# 舊成果')
        self.assertEqual((status, body.get('superseded')), (409, True))
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result'], saved['heartbeat']), ('running', None, 0))
        self.assertNotIn('舊的一輪還在動', [e['message'] for e in saved['events']])
        self.assertFalse((self.store.root / 'tasks' / task['id'] / 'result.md').exists())
        self.assertEqual(self.as_worker('/api/worker/heartbeat', current)[1], {'continue': True, 'status': 'running'})
        self.assertEqual(self.as_worker('/api/worker/complete', current, outcome='completed', text='# 新成果')[0], 200)
        self.assertEqual(self.store.get(task['id'])['result'], '# 新成果')

    def test_a_missing_or_guessed_lease_does_nothing(self):
        task = self.hands_task()
        claimed = self.claim()
        valid = {'task_id': task['id'], 'events': [{'kind': 'tool', 'message': 'x'}], 'outcome': 'completed', 'text': 'x'}
        for path in ('/api/worker/heartbeat', '/api/worker/events', '/api/worker/complete'):
            for lease in ({}, {'lease': ''}, {'lease': 42}, {'lease': ['x']}):
                self.assertEqual(self.worker(path, {**valid, **lease})[0], 400, (path, lease))
        guessed = {**claimed, 'lease': 'x' * len(claimed['lease'])}
        self.assertEqual(self.as_worker('/api/worker/heartbeat', guessed)[1]['continue'], False)
        self.assertEqual(self.as_worker('/api/worker/complete', guessed, outcome='completed', text='x')[0], 409)
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result']), ('running', None))


if __name__ == '__main__':
    unittest.main()
