"""G1／G2: browser action broker and audit against a fake browser (ADR-002 sections 4, 5, 8).

Everything here is simulated: no real Chrome, no real accounts, fictional values only.
It proves what the broker path does; it says nothing about paths that bypass the broker (G0)."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_office import app, FakeModel, LOCAL_HOST, local_request

sys.path.insert(0, str(Path(__file__).parents[1]))
import browser_actions as ba  # noqa: E402

SECRET = 'fictional-passcode-4821'  # must never reach the database


class FakeBrowser:
    def __init__(self):
        self.calls, self.gen, self.fail, self.gate = [], {'tab-1': 'g1'}, None, None

    def generation(self, tab):
        return self.gen[tab]

    def execute(self, tool, args, target):
        if self.gate:
            self.gate.wait(5)
        self.calls.append((tool, args, target))
        if self.fail:
            raise self.fail
        if tool == 'take_snapshot':
            return {'tab_id': 'tab-1', 'generation': self.gen['tab-1'], 'targets': {
                'e1': {'role': 'link', 'name': 'Docs', 'href': 'https://example.test/docs?session=abc#top'},
                'e2': {'role': 'button', 'name': 'Delete account'},
                'e3': {'role': 'textbox', 'name': 'Search'},
                'e4': {'role': 'link', 'name': 'Sign out', 'href': 'https://example.test/logout'}}}
        if tool in ('navigate', 'click'):
            self.gen['tab-1'] = f'g{len(self.calls) + 1}'
        return {'text': 'hello'} if tool == 'read_text' else {'ok': True}


class BrokerBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = app.Store(self.root / 'data')
        self.browser = FakeBrowser()
        self.broker = ba.Broker(self.store, self.browser)
        self.office = app.Office(self.store, FakeModel(), broker=self.broker)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：讀一個測試頁', 'executor': 'hands'})['task']
        self.claimed = self.store.claim_hands()

    def tearDown(self):
        self.temp.cleanup()

    def epoch(self):
        with self.store.connect() as c:
            return c.execute("SELECT control_epoch FROM browser_sessions WHERE id='cat-chrome'").fetchone()[0]

    def act(self, tool, args=None, action_id=None, **extra):
        request = {'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': action_id or str(uuid.uuid4()),
                   'control_epoch': self.epoch(), 'tool': tool, 'args': args or {}, **extra}
        return self.broker.act(request)

    def snapshot(self):
        status, body = self.act('take_snapshot')
        self.assertEqual(status, 200, body)
        return body['result']['snapshot_id']

    def audit(self, action_id=None):
        with self.store.connect() as c:
            rows = c.execute('SELECT * FROM browser_audit_events WHERE task_id=? ORDER BY seq', (self.task['id'],)).fetchall()
        return [dict(r) for r in rows if action_id is None or r['action_id'] == action_id]

    def db_bytes(self):
        with self.store.connect() as c:
            c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        return b''.join(p.read_bytes() for p in (self.root / 'data').glob('office.sqlite3*'))


class DecisionTests(BrokerBase):
    def test_read_is_allowed_dispatched_and_audited_in_two_rows(self):
        action = str(uuid.uuid4())
        status, body = self.act('read_text', action_id=action)
        self.assertEqual((status, body['decision'], body['outcome'], body['result']), (200, 'allow', 'succeeded', {'text': 'hello'}))
        rows = self.audit(action)
        self.assertEqual([(r['event_type'], r['decision'], r['outcome'], r['provenance']) for r in rows],
                         [('decision', 'allow', None, 'broker_observed'), ('outcome', 'allow', 'succeeded', 'broker_observed')])
        self.assertEqual(rows[0]['policy_version'], ba.POLICY_VERSION)

    def test_unknown_and_raw_tools_are_denied_and_never_reach_the_browser(self):
        for tool in ('evaluate_script', 'take_heapsnapshot', 'get_network_request', 'teleport'):
            status, body = self.act(tool)
            self.assertEqual((status, body['decision'], body['outcome']), (403, 'deny', 'not_dispatched'), tool)
        self.assertEqual(self.browser.calls, [])

    def test_navigation_rules(self):
        cases = {'javascript:alert(1)': (403, 'deny'), 'file:///etc/passwd': (403, 'deny'),
                 'https://user:pw@example.test/': (403, 'deny'), 'https://example.test/account/delete': (200, 'needs_human'),
                 'https://example.test/checkout': (200, 'needs_human'), 'https://example.test/docs': (200, 'allow')}
        for url, (status, decision) in cases.items():
            got, body = self.act('navigate', {'url': url})
            self.assertEqual((got, body['decision']), (status, decision), url)
        self.assertEqual([c[0] for c in self.browser.calls], ['navigate'])

    def test_click_link_allowed_button_and_logout_need_a_person(self):
        snap = self.snapshot()
        self.assertEqual(self.act('click', snapshot_id=snap, target_ref='e1')[1]['decision'], 'allow')
        snap = self.snapshot()
        for ref in ('e2', 'e4'):
            status, body = self.act('click', snapshot_id=snap, target_ref=ref)
            self.assertEqual((status, body['decision'], body['outcome']), (200, 'needs_human', 'not_dispatched'), ref)
        self.assertEqual([c[0] for c in self.browser.calls], ['take_snapshot', 'click', 'take_snapshot'])

    def test_typing_needs_a_person_and_the_text_is_never_stored(self):
        snap = self.snapshot()
        status, body = self.act('type_text', {'text': SECRET}, snapshot_id=snap, target_ref='e3')
        self.assertEqual((status, body['decision']), (200, 'needs_human'))
        self.assertNotIn(SECRET.encode(), self.db_bytes())

    def test_queries_fragments_and_lease_are_not_stored(self):
        self.act('navigate', {'url': 'https://example.test/docs?token=zz-fictional-token#frag'})
        self.snapshot()
        data = self.db_bytes()
        for leaked in (b'zz-fictional-token', b'#frag', b'session=abc'):
            self.assertNotIn(leaked, data)
        self.assertEqual(self.audit()[0]['target_summary'], 'https://example.test')
        with self.store.connect() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM browser_actions WHERE fingerprint=?", (self.claimed['lease'],)).fetchone()[0], 0)
        for row in self.audit():
            self.assertNotIn(self.claimed['lease'], json.dumps(row))


class StateTests(BrokerBase):
    def test_same_action_id_replays_without_a_second_dispatch(self):
        action = str(uuid.uuid4())
        first = self.act('read_text', action_id=action)
        again = self.act('read_text', action_id=action)
        self.assertEqual(again[0], 200)
        self.assertTrue(again[1]['replayed'])
        self.assertEqual(again[1]['outcome'], first[1]['outcome'])
        self.assertEqual(len(self.browser.calls), 1)

    def test_same_action_id_with_other_content_is_409(self):
        action = str(uuid.uuid4())
        self.act('navigate', {'url': 'https://example.test/a'}, action_id=action)
        status, body = self.act('navigate', {'url': 'https://example.test/b'}, action_id=action)
        self.assertEqual((status, body['reason_code']), (409, 'action_id_conflict'))
        self.assertEqual(len(self.browser.calls), 1)

    def test_stale_lease_epoch_hold_stop_and_mode_do_not_dispatch(self):
        request = lambda **o: {'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': str(uuid.uuid4()),
                               'control_epoch': self.epoch(), 'tool': 'read_text', 'args': {}, **o}
        self.assertEqual(self.broker.act(request(lease='old-lease'))[1]['reason_code'], 'stale_lease')
        self.assertEqual(self.broker.act(request(control_epoch=self.epoch() - 1))[1]['reason_code'], 'stale_epoch')
        with self.store.connect() as c:
            c.execute("UPDATE browser_sessions SET state='human_control' WHERE id='cat-chrome'")
        self.assertEqual(self.broker.act(request())[1]['reason_code'], 'held')
        with self.store.connect() as c:
            c.execute("UPDATE browser_sessions SET state='agent_running' WHERE id='cat-chrome'")
        self.store.set_paused(True)
        self.assertEqual(self.broker.act(request())[1]['reason_code'], 'stopped')
        self.store.set_hands_locked(True)  # also cancels the running hands task
        self.assertEqual(self.broker.act(request())[1]['reason_code'], 'stale_lease')
        self.assertEqual(self.browser.calls, [])
        legacy = self.store.submit(str(uuid.uuid4()), '舊模式', '', 'hands', 'hands')
        self.store.set_paused(False); self.store.set_hands_locked(False)
        claimed = self.store.claim_hands()
        status, body = self.broker.act(request(task_id=legacy['id'], lease=claimed['lease']))
        self.assertEqual((status, body['reason_code']), (409, 'mode_mismatch'))

    def test_bad_requests_are_400(self):
        base = {'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': str(uuid.uuid4()),
                'control_epoch': self.epoch(), 'tool': 'read_text', 'args': {}}
        for broken in ({**base, 'extra': 1}, {**base, 'action_id': 'not-a-uuid'}, {**base, 'control_epoch': '1'},
                       {**base, 'tool': 'navigate', 'args': {'url': 'x' * 2001}}, {**base, 'tool': 'click'},
                       {**base, 'tool': 'navigate', 'args': {'url': 'https://a.test', 'risk': 'read-only'}}):
            self.assertEqual(self.broker.act(broken)[0], 400, broken)
        self.assertEqual(self.browser.calls, [])

    def test_old_target_after_navigation_is_refused(self):
        snap = self.snapshot()
        self.act('navigate', {'url': 'https://example.test/next'})
        status, body = self.act('click', snapshot_id=snap, target_ref='e1')
        self.assertEqual((status, body['reason_code'], body['outcome']), (409, 'stale_target', 'not_dispatched'))
        self.assertEqual([c[0] for c in self.browser.calls], ['take_snapshot', 'navigate'])

    def test_snapshot_from_an_older_epoch_is_refused(self):
        snap = self.snapshot()
        with self.store.connect() as c:
            c.execute("UPDATE browser_sessions SET control_epoch=control_epoch+1 WHERE id='cat-chrome'")
        self.assertEqual(self.act('click', snapshot_id=snap, target_ref='e1')[1]['reason_code'], 'stale_snapshot')


class FailureTests(BrokerBase):
    def test_decision_not_written_means_no_dispatch(self):
        original = self.store.connect
        def broken():
            raise RuntimeError('disk full')
        self.store.connect = broken
        try:
            status, body = self.act_without_epoch('read_text')
        finally:
            self.store.connect = original
        self.assertEqual((status, body['reason_code']), (503, 'audit_unavailable'))
        self.assertEqual(self.browser.calls, [])

    def act_without_epoch(self, tool):
        return self.broker.act({'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': str(uuid.uuid4()),
                                'control_epoch': 1, 'tool': tool, 'args': {}})

    def test_unknown_result_is_not_sent_again(self):
        self.browser.fail = TimeoutError('no answer')
        action = str(uuid.uuid4())
        status, body = self.act('read_text', action_id=action)
        self.assertEqual((body['decision'], body['outcome']), ('allow', 'unknown'))
        self.browser.fail = None
        self.assertEqual(self.act('read_text', action_id=action)[1]['outcome'], 'unknown')
        self.assertEqual(len(self.browser.calls), 1)

    def test_definite_failure_is_failed_not_success(self):
        self.browser.fail = ba.BrowserFailed('closed tab')
        self.assertEqual(self.act('read_text')[1]['outcome'], 'failed')

    def test_outcome_not_written_blocks_the_session(self):
        original = self.broker.finish
        calls = {'n': 0}
        def flaky_connect(real=self.store.connect):
            calls['n'] += 1
            if calls['n'] == 1:
                raise RuntimeError('database locked')
            return real()
        def finish(*a, **k):
            self.store.connect, saved = flaky_connect, self.store.connect
            try:
                return original(*a, **k)
            finally:
                self.store.connect = saved
        self.broker.finish = finish
        status, body = self.act('read_text')
        self.broker.finish = original
        self.assertEqual((status, body['outcome'], body['reason_code']), (503, 'unknown', 'outcome_unwritten'))
        status, body = self.act('read_text')
        self.assertEqual((status, body['reason_code']), (503, 'reconcile_pending'))
        self.assertEqual(len(self.browser.calls), 1)

    def test_restart_turns_missing_outcomes_into_unknown_and_blocks(self):
        with self.store.connect() as c:
            c.execute("INSERT INTO browser_actions(action_id,task_id,attempt,fingerprint,session_id,control_epoch,tool,target_summary,"
                      "policy_version,rule_id,decision,reason_code,created) VALUES (?,?,1,'f','cat-chrome',1,'navigate','https://x.test',"
                      "'p','R2','allow','navigation','t')", (str(uuid.uuid4()), self.task['id']))
        self.assertEqual(ba.Broker(self.store, self.browser).recover(), 1)
        self.assertEqual(self.audit()[-1]['reason_code'], 'restart_without_outcome')
        self.assertEqual(self.act('read_text')[1]['reason_code'], 'reconcile_pending')


class RaceTests(BrokerBase):
    def test_take_waits_for_an_action_in_flight(self):
        self.browser.gate = threading.Event()
        result = {}
        worker = threading.Thread(target=lambda: result.setdefault('r', self.act('read_text')))
        worker.start()
        time.sleep(0.2)
        took = {}
        def take():
            with self.broker.gate:  # what G4's take does first
                took['at'] = len(self.browser.calls)
        taker = threading.Thread(target=take)
        taker.start()
        time.sleep(0.2)
        self.assertNotIn('at', took)
        self.browser.gate.set()
        worker.join(5); taker.join(5)
        self.assertEqual((result['r'][1]['outcome'], took['at']), ('succeeded', 1))

    def test_action_that_passed_checks_is_not_sent_after_a_takeover(self):
        result = {}
        self.broker.gate.acquire()
        try:
            worker = threading.Thread(target=lambda: result.setdefault('r', self.act('read_text')))
            worker.start()
            time.sleep(0.3)
            with self.store.connect() as c:
                c.execute("UPDATE browser_sessions SET state='taking_control',control_epoch=control_epoch+1 WHERE id='cat-chrome'")
        finally:
            self.broker.gate.release()
        worker.join(5)
        self.assertEqual((result['r'][0], result['r'][1]['reason_code'], result['r'][1]['outcome']), (409, 'held_before_dispatch', 'not_dispatched'))
        self.assertEqual(self.browser.calls, [])


class HttpTests(BrokerBase):
    def setUp(self):
        super().setUp()
        self.local = self.root / 'run' / 'office.sock'
        self.worker_sock = self.root / 'w' / 'worker.sock'
        self.server = app.Server(0, self.office, local_socket=self.local, worker_socket=self.worker_sock)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        super().tearDown()

    def post_worker(self, path, body):
        status, raw, _ = local_request(self.worker_sock, path, json.dumps(body).encode(), {'Content-Type': 'application/json'})
        return status, json.loads(raw)

    def test_worker_route_and_owner_history(self):
        body = {'task_id': self.task['id'], 'lease': self.claimed['lease'], 'action_id': str(uuid.uuid4()),
                'control_epoch': self.epoch(), 'tool': 'read_text', 'args': {}}
        self.assertEqual(self.post_worker('/api/worker/browser/action', body)[1]['outcome'], 'succeeded')
        self.assertEqual(self.post_worker('/api/worker/browser/action', {**body, 'action_id': str(uuid.uuid4()), 'tool': 'evaluate_script'})[0], 403)
        status, raw, _ = local_request(self.local, f"/api/tasks/{self.task['id']}/actions?after=0&limit=2", headers={'Host': LOCAL_HOST})
        page = json.loads(raw)
        self.assertEqual((status, len(page['events']), page['more']), (200, 2, True))
        status, raw, _ = local_request(self.local, f"/api/tasks/{self.task['id']}/actions?after={page['next_after']}", headers={'Host': LOCAL_HOST})
        self.assertEqual([e['decision'] for e in json.loads(raw)['events']], ['deny', 'deny'])
        status, _, _ = local_request(self.worker_sock, f"/api/tasks/{self.task['id']}/actions", headers={'Host': LOCAL_HOST})
        self.assertEqual(status, 404)
        status, _, _ = local_request(self.local, '/api/worker/browser/action', json.dumps(body).encode(),
                                     {'Host': LOCAL_HOST, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token})
        self.assertEqual(status, 404)

    def test_broker_route_is_off_without_broker_mode(self):
        self.office.broker = None
        status, _ = self.post_worker('/api/worker/browser/action', {'task_id': 'x'})
        self.assertEqual(status, 404)


class MigrationTests(unittest.TestCase):
    def test_old_database_gains_columns_and_keeps_rows(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / 'data'; data.mkdir(mode=0o700)
            c = sqlite3.connect(data / 'office.sqlite3')
            c.executescript('''CREATE TABLE tasks (id TEXT PRIMARY KEY, prompt TEXT NOT NULL, source TEXT NOT NULL, status TEXT NOT NULL,
                stage TEXT NOT NULL, title TEXT NOT NULL, created TEXT NOT NULL, updated TEXT NOT NULL, plan TEXT, result TEXT,
                artifact TEXT, metrics TEXT, model TEXT NOT NULL, source_snapshot TEXT);
                INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111','舊任務','','completed','完成','舊任務','t','t',NULL,'舊成果',NULL,NULL,'gemma',NULL);''')
            c.commit(); c.close()
            store = app.Store(data)
            task = store.get('11111111-1111-1111-1111-111111111111')
            self.assertEqual((task['result'], task['browser_mode'], task['initiator_kind']), ('舊成果', 'legacy', 'person'))
            app.Store(data)  # a second run of the migration changes nothing
            with store.connect() as c:
                self.assertEqual(c.execute("SELECT state,control_epoch FROM browser_sessions").fetchall()[0][:], ('agent_running', 1))


if __name__ == '__main__':
    unittest.main()
