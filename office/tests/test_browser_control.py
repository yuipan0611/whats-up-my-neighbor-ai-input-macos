"""G4: take, stop confirmation, return and re-observation of the cat's Chrome (ADR-002 section 6).

Simulation: the office, broker, control and worker are real; the browser and Codex are fakes.
Fictional data only. Real Chrome cases are in test_browser_chrome."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_office import app, FakeModel
from test_browser_actions import FakeBrowser, ba, local_request, LOCAL_HOST
from test_browser_adapter import HANDS, worker_mod

sys.path.insert(0, str(Path(__file__).parents[1]))
import browser_audit  # noqa: E402
import browser_control as bc  # noqa: E402

# Turn 1 opens a page, observes, starts a tool child and then works for a long time (until stopped).
# Turn 2 (after a return) tries its old target first, then observes again, and finishes.
FAKE_CODEX = r'''#!{python}
import json, os, re, subprocess, sys, time
args = sys.argv[1:]
output, cwd = args[args.index('--output-last-message') + 1], args[args.index('--cd') + 1]
config = dict(args[i + 1][len('mcp_servers.browser.'):].split('=', 1) for i, a in enumerate(args)
              if a == '-c' and args[i + 1].startswith('mcp_servers.browser.'))
prompt = sys.stdin.read()
url = re.search(r'URL=(http[^\s"]+)', prompt).group(1)
server = subprocess.Popen([json.loads(config['command'])] + json.loads(config['args']), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def call(i, name, arguments):
    server.stdin.write(json.dumps({{'jsonrpc': '2.0', 'id': i, 'method': 'tools/call', 'params': {{'name': name, 'arguments': arguments}}}}) + '\n')
    server.stdin.flush()
    return json.loads(server.stdout.readline())['result']
first = os.path.join(cwd, 'turn1.json')
if not os.path.exists(first):
    call(1, 'open_url', {{'url': url}})
    snap = json.loads(call(2, 'observe_page', {{}})['content'][0]['text'])
    link = next(r for r, t in snap['targets'].items() if t['role'] == 'link')
    child = subprocess.Popen(['sleep', '600'])
    with open(first + '.tmp', 'w') as f:
        json.dump({{'snapshot_id': snap['snapshot_id'], 'ref': link, 'pids': [os.getpid(), server.pid, child.pid]}}, f)
    os.rename(first + '.tmp', first)
    time.sleep(600)
old = json.load(open(first))
stale = call(3, 'click', {{'snapshot_id': old['snapshot_id'], 'target_ref': old['ref']}})
fresh = json.loads(call(4, 'observe_page', {{}})['content'][0]['text'])
with open(os.path.join(cwd, 'turn2.json'), 'w') as f:
    json.dump({{'note': prompt[prompt.find('使用者剛剛接手過'):], 'stale': stale, 'fresh': fresh}}, f, ensure_ascii=False)
with open(output, 'w') as f:
    json.dump({{'outcome': 'completed', 'content': '看完了。', 'reason': ''}}, f)
'''


def wait_for(check, seconds=10, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)
    raise AssertionError('timed out waiting')


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:  # a zombie still answers kill(0); it no longer runs
        return os.waitpid(pid, os.WNOHANG) == (0, 0)
    except ChildProcessError:
        import subprocess
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith('Z')


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class ControlBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = app.Store(self.root / 'data')
        self.browser = FakeBrowser()
        self.broker = ba.Broker(self.store, self.browser)
        self.office = app.Office(self.store, FakeModel(), broker=self.broker)
        self.clock = Clock()
        self.control = self.office.control
        self.control.clock = self.clock

    def tearDown(self):
        self.temp.cleanup()

    def session(self):
        with self.store.connect() as c:
            return dict(c.execute("SELECT * FROM browser_sessions WHERE id='cat-chrome'").fetchone())

    def op(self, action, device='dev-a', epoch=None, operation_id=None):
        epoch = self.session()['control_epoch'] if epoch is None else epoch
        return self.control.operate(device, {'operation_id': operation_id or str(uuid.uuid4()), 'action': action, 'expected_epoch': epoch})

    def new_task(self):
        task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：URL=https://example.test/docs', 'executor': 'hands'})['task']
        claimed = self.store.claim_hands()
        self.control.attach(claimed)
        return task, claimed

    def act(self, claimed, tool, args=None, **extra):
        return self.broker.act({'task_id': claimed['id'], 'lease': claimed['lease'], 'action_id': str(uuid.uuid4()),
                                'control_epoch': self.session()['control_epoch'], 'tool': tool, 'args': args or {}, **extra})

    def ack(self, claimed, checkpoint, **extra):
        return self.control.ack({'task_id': claimed['id'], 'lease': claimed['lease'], 'control_epoch': self.session()['control_epoch'],
                                 'checkpoint': checkpoint, **extra})

    def events(self):
        with self.store.connect() as c:
            return [(r[0], r[1]) for r in c.execute("SELECT event_type,reason_code FROM browser_audit_events WHERE event_type LIKE 'control_%' ORDER BY seq")]


class StateMachineTests(ControlBase):
    def test_take_without_an_agent_opens_input_and_stales_old_epoch(self):
        epoch = self.session()['control_epoch']
        status, body = self.op('take')
        self.assertEqual((status, body['control_state'], body['control_epoch'], body['can_input']), (202, 'human_control', epoch + 1, True))
        self.assertTrue(self.control.input_allowed('dev-a', epoch + 1))
        self.assertFalse(self.control.input_allowed('dev-a', epoch))
        self.assertFalse(self.control.input_allowed('dev-b', epoch + 1))

    def test_operation_id_is_idempotent_and_conflicts_are_409(self):
        op = str(uuid.uuid4())
        epoch = self.session()['control_epoch']
        first = self.op('take', epoch=epoch, operation_id=op)
        again = self.op('take', epoch=epoch, operation_id=op)
        self.assertEqual(self.session()['control_epoch'], epoch + 1)  # no second epoch
        self.assertTrue(again[1]['replayed'])
        self.assertEqual(first[0], again[0])
        self.assertEqual(self.op('return', epoch=epoch, operation_id=op)[0], 409)
        self.assertEqual(self.op('take', device='dev-b', epoch=epoch)[1]['reason_code'], 'stale_epoch')  # expected_epoch is old

    def test_take_with_an_agent_waits_for_the_stop_confirmation(self):
        task, claimed = self.new_task()
        self.assertEqual(self.act(claimed, 'read_text')[1]['outcome'], 'succeeded')
        status, body = self.op('take')
        self.assertEqual((body['control_state'], body['can_input']), ('taking_control', False))
        self.assertFalse(self.control.input_allowed('dev-a', body['control_epoch']))
        self.assertEqual(self.act(claimed, 'read_text')[1]['reason_code'], 'held')
        self.assertTrue(self.control.worker_view(task['id'])['hold'])
        wrong = self.control.ack({'task_id': claimed['id'], 'lease': claimed['lease'], 'control_epoch': body['control_epoch'] - 1, 'checkpoint': 'stopped'})
        self.assertEqual(wrong[1]['reason_code'], 'stale_epoch')
        self.assertEqual(self.control.ack({'task_id': claimed['id'], 'lease': 'guess', 'control_epoch': body['control_epoch'], 'checkpoint': 'stopped'})[0], 409)
        self.assertEqual(self.ack(claimed, 'stopped')[0], 200)
        self.assertTrue(self.control.input_allowed('dev-a', body['control_epoch']))
        self.assertEqual([e[0] for e in self.events()], ['control_requested', 'control_taken'])

    def test_unconfirmed_stop_becomes_held_and_never_opens_input(self):
        task, claimed = self.new_task()
        epoch = self.op('take')[1]['control_epoch']
        self.clock.t += bc.STOP_SECONDS + 1
        self.assertEqual(self.control.state('dev-a')['control_state'], 'held')
        self.assertFalse(self.control.input_allowed('dev-a', epoch))
        self.assertEqual(self.ack(claimed, 'stopped')[1]['reason_code'], 'wrong_state')  # a late ack does not open input
        self.assertEqual(self.op('take')[1]['control_state'], 'taking_control')  # take again, wait for a fresh stop
        self.assertEqual(self.ack(claimed, 'stopped')[0], 200)

    def test_second_device_takes_over_and_the_first_loses_input(self):
        self.op('take', 'dev-a')
        epoch_a = self.session()['control_epoch']
        status, body = self.op('take', 'dev-b')
        self.assertEqual((body['controller'], body['control_epoch']), ('this_device', epoch_a + 1))
        self.assertEqual(self.control.state('dev-a')['controller'], 'other_device')
        self.assertFalse(self.control.input_allowed('dev-a', epoch_a))
        self.assertFalse(self.control.input_allowed('dev-a', epoch_a + 1))
        self.assertTrue(self.control.input_allowed('dev-b', epoch_a + 1))
        self.assertEqual(self.op('ping', 'dev-a', epoch=epoch_a)[1]['reason_code'], 'not_controller')

    def test_disconnect_holds_forever_until_someone_acts(self):
        task, claimed = self.new_task()
        self.op('take'); self.ack(claimed, 'stopped')
        epoch = self.session()['control_epoch']
        self.clock.t += bc.DISCONNECT_SECONDS - 1
        self.assertEqual(self.op('ping', epoch=epoch)[0], 200)
        self.clock.t += bc.DISCONNECT_SECONDS + 1
        self.assertEqual(self.control.state('dev-a')['control_state'], 'human_disconnected')
        self.assertFalse(self.control.input_allowed('dev-a', epoch))
        self.clock.t += 24 * 3600
        view = self.control.worker_view(task['id'])
        self.assertEqual((view['hold'], view['control_state']), (True, 'human_disconnected'))  # no timeout hands it back
        self.assertGreaterEqual(self.control.state('dev-a')['waiting_seconds'], 24 * 3600)  # counted from the disconnect
        self.assertEqual(self.op('ping', epoch=epoch)[0], 409)  # reconnecting means taking again
        body = self.op('take')[1]
        self.assertEqual((body['control_state'], body['control_epoch']), ('human_control', epoch + 1))

    def test_return_needs_a_new_broker_observation_before_the_agent_acts(self):
        task, claimed = self.new_task()
        old = self.act(claimed, 'take_snapshot')[1]['result']
        self.op('take'); self.ack(claimed, 'stopped')
        status, body = self.op('return', 'dev-b')  # another paired device may hand back
        self.assertEqual((status, body['control_state']), (202, 'resuming'))
        self.assertEqual(self.act(claimed, 'read_text')[1]['reason_code'], 'held')
        self.assertEqual(self.ack(claimed, 'observed', snapshot_id=old['snapshot_id'])[1]['reason_code'], 'observation_missing')
        self.assertEqual(self.ack(claimed, 'observed')[1]['reason_code'], 'observation_missing')
        fresh = self.act(claimed, 'take_snapshot')[1]['result']
        self.assertEqual(self.ack(claimed, 'observed', snapshot_id=fresh['snapshot_id'])[0], 200)
        self.assertEqual(self.session()['state'], 'agent_running')
        self.assertEqual(self.act(claimed, 'click', snapshot_id=old['snapshot_id'], target_ref='e1')[1]['reason_code'], 'stale_snapshot')
        self.assertEqual(self.act(claimed, 'click', snapshot_id=fresh['snapshot_id'], target_ref='e1')[1]['outcome'], 'succeeded')
        self.assertEqual([e[0] for e in self.events()],
                         ['control_requested', 'control_taken', 'control_return_requested', 'control_released'])

    def test_return_onto_a_sign_in_screen_stays_held(self):
        task, claimed = self.new_task()
        self.op('take'); self.ack(claimed, 'stopped'); self.op('return')
        real = self.browser.execute
        def login_page(tool, args, target):
            out = real(tool, args, target)
            if tool == 'take_snapshot':
                out['targets']['e9'] = {'role': 'secret', 'name': '密碼'}
            return out
        self.browser.execute = login_page
        fresh = self.act(claimed, 'take_snapshot')[1]['result']
        status, body = self.ack(claimed, 'observed', snapshot_id=fresh['snapshot_id'])
        self.assertEqual((status, body['reason_code'], self.session()['state']), (409, 'sensitive_page', 'held'))

    def test_requeued_task_after_return_observes_with_its_new_lease(self):
        task, claimed = self.new_task()
        self.op('take'); self.ack(claimed, 'stopped'); self.op('return')
        self.assertEqual(self.session()['state'], 'resuming')
        self.assertEqual(self.store.expire_hands(time.time() + 3600), 1)  # the worker died while resuming
        self.assertTrue(self.control.claimable())
        again = self.store.claim_hands()
        self.assertTrue(self.control.worker_view(task['id'])['hold'])
        self.assertEqual(self.act(again, 'read_text')[1]['reason_code'], 'held')
        fresh = self.act(again, 'take_snapshot')[1]['result']
        self.assertEqual(self.ack(claimed, 'observed', snapshot_id=fresh['snapshot_id'])[0], 409)  # the old lease
        self.assertEqual(self.ack(again, 'observed', snapshot_id=fresh['snapshot_id'])[0], 200)

    def test_restart_keeps_every_in_between_state_held(self):
        for state, after in (('taking_control', 'held'), ('resuming', 'held'), ('human_control', 'human_disconnected'),
                             ('human_disconnected', 'human_disconnected'), ('held', 'held'), ('agent_running', 'agent_running')):
            with self.store.connect() as c:
                c.execute("UPDATE browser_sessions SET state=? WHERE id='cat-chrome'", (state,))
            office = app.Office(self.store, FakeModel(), broker=ba.Broker(self.store, self.browser))  # the office restarts
            self.assertEqual(self.session()['state'], after, state)
            self.assertEqual(office.control.claimable(), after == 'agent_running', state)

    def test_revoked_controller_loses_input_at_once(self):
        self.op('take')
        epoch = self.session()['control_epoch']
        self.control.revoked('dev-a')
        self.assertEqual(self.session()['state'], 'held')
        self.assertFalse(self.control.input_allowed('dev-a', epoch))
        self.assertEqual(self.op('return', 'dev-b')[1]['control_state'], 'agent_running')

    def test_cancelled_task_is_not_revived_by_return(self):
        task, claimed = self.new_task()
        self.op('take'); self.ack(claimed, 'stopped')
        self.store.cancel(task['id'])
        body = self.op('return')[1]
        self.assertEqual(body['control_state'], 'agent_running')  # nothing to resume
        self.assertEqual(self.store.get(task['id'])['status'], 'cancelled')
        self.assertEqual(self.events()[-1], ('control_released', 'no_agent_attached'))

    def test_take_still_stops_when_the_audit_table_is_broken(self):
        task, claimed = self.new_task()
        original = browser_audit.append
        browser_audit.append = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('audit down'))
        try:
            self.assertEqual(self.op('take')[1]['control_state'], 'taking_control')
            self.assertIn(self.act(claimed, 'read_text')[0], (409, 503))
            self.assertEqual(self.browser.calls, [])  # and the broker dispatches nothing
        finally:
            browser_audit.append = original
        self.assertTrue(self.control.worker_view(task['id'])['hold'])

    def test_legacy_task_cannot_be_taken_over(self):
        self.office.command({'id': str(uuid.uuid4()), 'prompt': '舊模式', 'executor': 'hands'})
        with self.store.connect() as c:
            c.execute("UPDATE tasks SET browser_mode='legacy'")
        self.store.claim_hands()
        status, body = self.op('take')
        self.assertEqual((status, body['reason_code']), (409, 'legacy_task_running'))

    def test_in_flight_action_finishes_before_input_opens(self):
        task, claimed = self.new_task()
        self.browser.gate = threading.Event()
        result = {}
        runner = threading.Thread(target=lambda: result.setdefault('r', self.act(claimed, 'navigate', {'url': 'https://example.test/slow'})))
        runner.start()
        wait_for(lambda: self.broker.gate.locked())
        time.sleep(0.2)  # past the in-gate recheck, inside the browser call
        taker = threading.Thread(target=lambda: result.setdefault('take', self.op('take')))
        taker.start()
        time.sleep(0.3)
        self.assertEqual(self.session()['state'], 'taking_control')  # the gate closed before the action ended
        self.browser.gate.set()
        runner.join(); taker.join()
        self.assertEqual(result['r'][1]['outcome'], 'succeeded')  # it had passed every check; it is not undone
        self.assertEqual(self.ack(claimed, 'stopped')[0], 200)
        with self.store.connect() as c:
            order = [r[0] for r in c.execute("SELECT event_type FROM browser_audit_events WHERE event_type IN ('outcome','control_taken') ORDER BY seq")]
        self.assertEqual(order[-2:], ['outcome', 'control_taken'])

    def test_in_flight_action_that_never_ends_holds(self):
        task, claimed = self.new_task()
        self.browser.gate = threading.Event()
        runner = threading.Thread(target=lambda: self.act(claimed, 'navigate', {'url': 'https://example.test/hang'}))
        runner.start()
        wait_for(lambda: self.broker.gate.locked())
        saved, bc.STOP_SECONDS = bc.STOP_SECONDS, 0.3
        try:
            body = self.op('take')[1]
        finally:
            bc.STOP_SECONDS = saved
            self.browser.gate.set(); runner.join()
        self.assertEqual((body['control_state'], self.session()['hold_reason']), ('held', 'in_flight_unresolved'))


class ReconcileTests(ControlBase):
    """Handing control back and reconciling an unknown outcome are two separate steps (施工單 2026-10-28 第三節)."""

    def unknown_action(self, task, tool='navigate'):
        """An allowed action whose result never arrived (a crash mid-dispatch), found at the next start."""
        action_id = str(uuid.uuid4())
        with self.store.connect() as c:
            c.execute("INSERT INTO browser_actions(action_id,task_id,attempt,fingerprint,session_id,control_epoch,tool,target_summary,"
                      "policy_version,rule_id,decision,reason_code,created) VALUES (?,?,1,'f','cat-chrome',1,?,'https://x.test',"
                      "'browser-policy-1','R2-navigate','allow','navigation','t')", (action_id, task['id'], tool))
        self.broker.recover()
        return action_id

    def reconcile(self, action_id, resolution='happened', evidence='checked_on_site', device='dev-a', epoch=None, operation_id=None):
        epoch = self.session()['control_epoch'] if epoch is None else epoch
        return self.control.reconcile(device, {'operation_id': operation_id or str(uuid.uuid4()), 'action_id': action_id,
                                               'resolution': resolution, 'evidence': evidence, 'expected_epoch': epoch})

    def take_over(self, claimed):
        self.op('take')
        self.assertEqual(self.ack(claimed, 'stopped')[0], 200)

    def test_return_does_not_settle_an_unknown_outcome(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.assertEqual(self.act(claimed, 'read_text')[1]['reason_code'], 'reconcile_pending')
        self.take_over(claimed)
        state = self.control.state('dev-a')
        self.assertTrue(state['reconcile_pending'])
        self.assertEqual([i['action_id'] for i in state['reconcile_items']], [action])
        self.assertNotIn('lease', json.dumps(state))
        body = self.op('return')[1]
        # The agent is not resumed: control left the person, the unknown is still there.
        self.assertEqual((body['control_state'], body['hold_reason'], body['reconcile_pending']), ('held', 'reconcile_pending', True))
        self.assertTrue(self.control.worker_view(task['id'])['hold'])
        self.assertEqual(self.act(claimed, 'take_snapshot')[1]['reason_code'], 'reconcile_pending')
        self.assertIn(('control_return_requested', 'return_with_reconcile_pending'), self.events())
        self.assertEqual(self.session()['blocked'], 'reconcile_pending')

    def test_reconcile_then_return_resumes_from_a_new_observation(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.take_over(claimed)
        status, body = self.reconcile(action, 'not_happened', 'checked_on_site')
        self.assertEqual((status, body['reason_code'], body['reconcile_pending'], body['control_state']),
                         (200, 'reconciled', False, 'human_control'))  # reconciling never moves control
        self.assertEqual(self.op('return')[1]['control_state'], 'resuming')
        fresh = self.act(claimed, 'take_snapshot')[1]['result']
        self.assertEqual(self.ack(claimed, 'observed', snapshot_id=fresh['snapshot_id'])[0], 200)
        self.assertEqual(self.act(claimed, 'read_text')[1]['outcome'], 'succeeded')
        with self.store.connect() as c:
            row = c.execute('SELECT outcome,reconciled FROM browser_actions WHERE action_id=?', (action,)).fetchone()
            event = c.execute("SELECT provenance,outcome,reason_code FROM browser_audit_events WHERE event_type='reconciled' "
                              "AND action_id=? ORDER BY seq DESC LIMIT 1", (action,)).fetchone()
        self.assertEqual(tuple(row), ('unknown', 'not_happened'))  # the broker's record of the dispatch is not rewritten
        self.assertEqual(tuple(event), ('human_control_event', 'not_happened', 'checked_on_site'))
        self.assertEqual([c[0] for c in self.browser.calls].count('navigate'), 0)  # nothing was resent

    def test_block_lifts_only_after_the_last_unknown(self):
        task, claimed = self.new_task()
        first, second = self.unknown_action(task), self.unknown_action(task, 'click')
        self.take_over(claimed)
        body = self.reconcile(first)[1]
        self.assertEqual((body['remaining'], body['reconcile_pending'], self.session()['blocked']), (1, True, 'reconcile_pending'))
        body = self.reconcile(second, 'accepted_unknown', 'accept_risk')[1]
        self.assertEqual((body['remaining'], body['reconcile_pending'], self.session()['blocked']), (0, False, ''))

    def test_return_from_held_after_reconcile_resumes(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.take_over(claimed)
        self.assertEqual(self.op('return')[1]['control_state'], 'held')
        self.assertEqual(self.reconcile(action, 'happened', 'external_record')[0], 200)
        self.assertEqual(self.op('return')[1]['control_state'], 'resuming')

    def test_restart_and_new_lease_keep_the_block(self):
        task, claimed = self.new_task()
        self.unknown_action(task)
        self.take_over(claimed)
        self.op('return')
        with self.store.connect() as c:  # even if something cleared the flag, the unknown row itself still blocks
            c.execute("UPDATE browser_sessions SET blocked='',state='agent_running' WHERE id='cat-chrome'")
        self.assertEqual(self.act(claimed, 'read_text')[1]['reason_code'], 'reconcile_pending')
        office = app.Office(self.store, FakeModel(), broker=ba.Broker(self.store, self.browser))  # the office restarts
        self.assertEqual(self.session()['blocked'], 'reconcile_pending')
        self.assertTrue(office.control.state('dev-a')['reconcile_pending'])
        with self.store.connect() as c:  # a new attempt with a new lease does not get around it
            c.execute("UPDATE browser_sessions SET state='agent_running' WHERE id='cat-chrome'")
            c.execute("UPDATE tasks SET lease='0123456789abcdef0123456789abcdef', attempts=attempts+1 WHERE id=?", (task['id'],))
        renewed = {**claimed, 'lease': '0123456789abcdef0123456789abcdef'}
        self.assertEqual(self.act(renewed, 'read_text')[1]['reason_code'], 'reconcile_pending')

    def test_same_operation_replays_and_repeats_change_nothing(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.take_over(claimed)
        op = str(uuid.uuid4())
        first = self.reconcile(action, operation_id=op)
        again = self.reconcile(action, operation_id=op)
        self.assertEqual((again[0], again[1]['replayed'], again[1]['reason_code']), (200, True, 'reconciled'))
        self.assertEqual(self.reconcile(action, 'not_happened', operation_id=op)[1]['reason_code'], 'operation_conflict')
        self.assertEqual(self.reconcile(action)[1]['reason_code'], 'already_reconciled')       # new op, same answer: no change
        self.assertEqual(self.reconcile(action, 'not_happened')[0], 409)                        # new op, other answer
        with self.store.connect() as c:
            n = c.execute("SELECT COUNT(*) FROM browser_audit_events WHERE event_type='reconciled' AND provenance='human_control_event'").fetchone()[0]
            reconcile_id = c.execute('SELECT reconcile_id FROM browser_actions WHERE action_id=?', (action,)).fetchone()[0]
        self.assertEqual((first[0], n, reconcile_id), (200, 1, op))

    def test_old_or_other_controller_cannot_reconcile(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        old_epoch = self.session()['control_epoch']
        self.take_over(claimed)
        self.assertEqual(self.reconcile(action, epoch=old_epoch)[1]['reason_code'], 'stale_epoch')
        self.assertEqual(self.reconcile(action, device='dev-b')[1]['reason_code'], 'not_controller')
        self.control.revoked('dev-a')  # a revoked device no longer authenticates at all (HTTP layer, test_mobile)
        self.assertTrue(self.control.state('dev-b')['reconcile_pending'])
        self.assertEqual(self.reconcile(action, device='dev-b')[0], 200)  # no controller now: another paired device may

    def test_evidence_must_fit_and_agent_word_is_not_evidence(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.take_over(claimed)
        for resolution, evidence in (('happened', 'accept_risk'), ('accepted_unknown', 'checked_on_site'),
                                     ('happened', 'agent_reported'), ('happened', 'page_text'), ('succeeded', 'checked_on_site')):
            self.assertEqual(self.reconcile(action, resolution, evidence)[0], 400, (resolution, evidence))
        self.assertEqual(self.reconcile(action, 'accepted_unknown', 'accept_risk')[1]['reason_code'], 'reconciled')
        self.assertEqual(self.control.reconcile('dev-a', {'operation_id': str(uuid.uuid4()), 'action_id': action})[0], 400)

    def test_only_unknown_outcomes_and_finished_actions_are_reconciled(self):
        task, claimed = self.new_task()
        done = self.act(claimed, 'read_text')[1]['action_id']
        self.op('take')
        self.ack(claimed, 'stopped')
        self.assertEqual(self.reconcile(done)[1]['reason_code'], 'not_unknown')
        self.assertEqual(self.reconcile(str(uuid.uuid4()))[1]['reason_code'], 'unknown_action')

    def test_action_in_flight_cannot_be_reconciled(self):
        task, claimed = self.new_task()
        self.browser.gate = threading.Event()
        result = {}
        worker = threading.Thread(target=lambda: result.update(r=self.act(claimed, 'navigate', {'url': 'https://example.test/a'})))
        worker.start()
        action = wait_for(lambda: self.session_action())
        try:
            self.assertEqual(self.reconcile(action)[1]['reason_code'], 'in_flight')
        finally:
            self.browser.gate.set()
        worker.join(5)

    def session_action(self):
        with self.store.connect() as c:
            row = c.execute("SELECT action_id FROM browser_actions WHERE decision='allow' AND outcome IS NULL").fetchone()
        return row and row[0]

    def test_unwritten_outcome_is_settled_then_reconciled(self):
        task, claimed = self.new_task()
        action = str(uuid.uuid4())
        with self.store.connect() as c:  # dispatched, then the outcome could not be written: no outcome, session blocked
            c.execute("INSERT INTO browser_actions(action_id,task_id,attempt,fingerprint,session_id,control_epoch,tool,target_summary,"
                      "policy_version,rule_id,decision,reason_code,created) VALUES (?,?,1,'f','cat-chrome',1,'click','button',"
                      "'browser-policy-1','R5-click','allow','click_effect_unknown','t')", (action, task['id']))
            c.execute("UPDATE browser_sessions SET blocked='outcome_unwritten' WHERE id='cat-chrome'")
        self.take_over_without_ack()
        self.assertEqual(self.reconcile(action, 'happened', 'checked_on_site')[1]['reconcile_pending'], False)
        self.assertEqual(self.session()['blocked'], '')

    def take_over_without_ack(self):
        """No live agent to stop (the unwritten row would otherwise read as in flight to the stop check)."""
        with self.store.connect() as c:
            c.execute("UPDATE browser_sessions SET state='human_control',controller_device_id='dev-a',controller_seen=?,"
                      "control_epoch=control_epoch+1 WHERE id='cat-chrome'", (self.clock(),))

    def test_cancelled_task_stays_cancelled_after_reconcile_and_return(self):
        task, claimed = self.new_task()
        action = self.unknown_action(task)
        self.take_over(claimed)
        self.store.cancel(task['id'])
        self.assertEqual(self.reconcile(action)[0], 200)
        self.assertEqual(self.op('return')[1]['control_state'], 'agent_running')  # nothing left to resume
        self.assertEqual(self.store.get(task['id'])['status'], 'cancelled')
        self.assertIsNone(self.store.claim_hands())
        self.assertEqual(self.act(claimed, 'read_text')[1]['reason_code'], 'stale_lease')


class HttpAndWorkerTests(ControlBase):
    def setUp(self):
        super().setUp()
        self.control.clock = time.time
        self.local = self.root / 'run' / 'office.sock'
        self.worker_socket = self.root / 'w' / 'worker.sock'
        self.server = app.Server(0, self.office, local_socket=self.local, worker_socket=self.worker_socket)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        fake = self.root / 'fake-codex'
        fake.write_text(FAKE_CODEX.format(python=sys.executable)); fake.chmod(0o755)
        self.worker = worker_mod.Worker(worker_mod.Office(self.worker_socket), fake, self.root / 'codex-home', self.root / 'ws',
                                        browser=('/usr/bin/false', []), adapter=HANDS / 'browser_adapter.py')
        self.worker.HEARTBEAT_SECONDS, self.worker.FLUSH_SECONDS, self.worker.CONTROL_SECONDS = 0.5, 0.1, 0.2

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        super().tearDown()

    def owner(self, method, path, body=None):
        headers = {'Host': LOCAL_HOST, 'Content-Type': 'application/json', 'X-Office-Token': self.server.token}
        status, raw, _ = local_request(self.local, path, json.dumps(body).encode() if body is not None else None, headers)
        return status, json.loads(raw)

    def worker_post(self, path, body):
        status, raw, _ = local_request(self.worker_socket, path, json.dumps(body).encode(), {'Content-Type': 'application/json'})
        return status, json.loads(raw)

    def test_routes_belong_to_owner_and_worker_only(self):
        epoch = self.owner('GET', '/api/viewer/state')[1]['control_epoch']
        status, body = self.owner('POST', '/api/viewer/control', {'operation_id': str(uuid.uuid4()), 'action': 'take', 'expected_epoch': epoch})
        self.assertEqual((status, body['control_state'], body['controller']), (202, 'human_control', 'this_device'))
        self.assertNotIn('lease', json.dumps(body))
        self.assertEqual(self.worker_post('/api/viewer/control', {'operation_id': str(uuid.uuid4()), 'action': 'return', 'expected_epoch': epoch + 1})[0], 404)
        self.assertEqual(local_request(self.worker_socket, '/api/viewer/state', headers={'Host': LOCAL_HOST})[0], 404)
        self.assertEqual(self.owner('POST', '/api/worker/browser/control-ack', {'task_id': 'x'})[0], 404)
        claim = self.worker_post('/api/worker/claim', {})[1]
        self.assertEqual((claim['task'], claim.get('held')), (None, True))  # a person holds the Chrome: no task starts

    def test_reconcile_route_is_owner_only(self):
        body = {'operation_id': str(uuid.uuid4()), 'action_id': str(uuid.uuid4()), 'resolution': 'happened',
                'evidence': 'checked_on_site', 'expected_epoch': self.owner('GET', '/api/viewer/state')[1]['control_epoch']}
        self.assertEqual(self.worker_post('/api/viewer/reconcile', body)[0], 404)
        self.assertEqual(self.owner('POST', '/api/viewer/reconcile', body)[1]['reason_code'], 'unknown_action')

    def run_worker(self, prompt_url='https://example.test/docs'):
        task = self.office.command({'id': str(uuid.uuid4()), 'prompt': f'合成任務：URL={prompt_url}', 'executor': 'hands'})['task']
        claimed = self.worker.office.post('/api/worker/claim', {})[1]['task']
        result = {}
        thread = threading.Thread(target=lambda: result.setdefault('outcome', self.worker.handle(claimed)))
        thread.start()
        turn1 = self.root / 'ws' / task['id'] / 'attempt-1' / 'turn1.json'
        wait_for(turn1.exists, 20)
        return task, claimed, result, thread, json.loads(turn1.read_text())

    def owner_op(self, action):
        epoch = self.owner('GET', '/api/viewer/state')[1]['control_epoch']
        return self.owner('POST', '/api/viewer/control', {'operation_id': str(uuid.uuid4()), 'action': action, 'expected_epoch': epoch})

    def test_take_stops_the_whole_tree_holds_with_lease_and_return_resumes_from_a_new_observation(self):
        self.worker.TASK_SECONDS = 6
        task, claimed, result, thread, turn1 = self.run_worker()
        self.assertTrue(all(alive(p) for p in turn1['pids'][1:]))
        started = time.monotonic()
        self.assertEqual(self.owner_op('take')[1]['control_state'], 'taking_control')
        wait_for(lambda: self.owner('GET', '/api/viewer/state')[1]['control_state'] == 'human_control', 10)
        stop_seconds = time.monotonic() - started
        self.assertLess(stop_seconds, bc.STOP_SECONDS)
        self.assertFalse(any(alive(p) for p in turn1['pids']), 'agent, adapter or tool child still running')
        calls_at_take = len(self.browser.calls)
        with self.store.connect() as c:
            beat1 = c.execute('SELECT heartbeat FROM tasks WHERE id=?', (task['id'],)).fetchone()[0]
        time.sleep(7)  # longer than the whole task budget: held time does not count
        with self.store.connect() as c:
            beat2 = c.execute('SELECT heartbeat FROM tasks WHERE id=?', (task['id'],)).fetchone()[0]
        self.assertGreater(beat2, beat1 + 5)  # the lease is kept while held
        self.assertEqual(self.store.expire_hands(), 0)
        self.assertEqual(len(self.browser.calls), calls_at_take)  # nothing reached the browser while held
        self.assertEqual(self.owner_op('return')[0], 202)
        thread.join(30)
        self.assertEqual(result.get('outcome'), 'completed')
        turn2 = json.loads((self.root / 'ws' / task['id'] / 'attempt-1' / 'turn2.json').read_text())
        self.assertIn('交還給你', turn2['note'])
        self.assertTrue(turn2['stale']['isError'])
        self.assertIn('stale', turn2['stale']['content'][0]['text'])
        self.assertEqual(self.browser.calls[calls_at_take][0], 'take_snapshot')  # the first browser call after return: the broker observing
        self.assertNotIn(claimed['lease'], json.dumps(turn2, ensure_ascii=False))
        self.assertEqual([e[0] for e in self.events()],
                         ['control_requested', 'control_taken', 'control_return_requested', 'control_released'])
        print(f'\nG4 stop confirmation (simulation): {stop_seconds:.2f}s', file=sys.stderr)

    def test_no_stop_confirmation_while_part_of_the_tree_survives(self):
        task, claimed, result, thread, turn1 = self.run_worker()
        self.worker.group_gone = lambda pgid, wait: False  # as if a tool process outlived the stop
        self.owner_op('take')
        wait_for(lambda: self.owner('GET', '/api/viewer/state')[1]['control_state'] == 'held', bc.STOP_SECONDS + 5)
        view = self.owner('GET', '/api/viewer/state')[1]
        self.assertEqual((view['hold_reason'], view['can_input']), ('stop_unconfirmed', False))
        self.owner('POST', f"/api/tasks/{task['id']}/cancel", {})
        thread.join(10)

    def test_cancel_while_held_ends_the_task_and_return_does_not_revive_it(self):
        task, claimed, result, thread, turn1 = self.run_worker()
        self.owner_op('take')
        wait_for(lambda: self.owner('GET', '/api/viewer/state')[1]['control_state'] == 'human_control', 10)
        self.owner('POST', f"/api/tasks/{task['id']}/cancel", {})
        thread.join(10)
        self.assertEqual(result.get('outcome'), 'stopped by the office')
        self.assertEqual(self.owner_op('return')[1]['control_state'], 'agent_running')
        self.assertEqual(self.store.get(task['id'])['status'], 'cancelled')
        self.assertFalse((self.root / 'ws' / task['id'] / 'attempt-1' / 'turn2.json').exists())

    def test_worker_restart_while_held_waits_for_return_and_old_targets_stay_stale(self):
        task, claimed, result, thread, turn1 = self.run_worker()
        self.owner_op('take')
        wait_for(lambda: self.owner('GET', '/api/viewer/state')[1]['control_state'] == 'human_control', 10)
        self.worker.office = worker_mod.Office(self.root / 'nowhere.sock')  # the office is gone for this worker
        time.sleep(1)
        self.assertTrue(thread.is_alive())  # an unreachable office does not release the hold
        self.worker.stopping = True  # the worker process exits; its lease lapses and the task is queued again
        thread.join(10)
        self.assertEqual(self.store.expire_hands(time.time() + 3600), 1)
        fresh = worker_mod.Office(self.worker_socket)  # a new worker process
        self.assertIsNone(fresh.post('/api/worker/claim', {})[1]['task'])  # still held: not claimed
        self.assertEqual(self.owner_op('return')[1]['control_state'], 'agent_running')  # no live task to resume
        claimed2 = fresh.post('/api/worker/claim', {})[1]['task']
        self.assertEqual((claimed2['id'], claimed2['attempts']), (task['id'], 2))
        status, body = self.broker.act({'task_id': task['id'], 'lease': claimed2['lease'], 'action_id': str(uuid.uuid4()),
                                        'control_epoch': self.session()['control_epoch'], 'tool': 'click',
                                        'snapshot_id': turn1['snapshot_id'], 'target_ref': turn1['ref'], 'args': {}})
        self.assertEqual((status, body['reason_code']), (409, 'stale_snapshot'))
        self.assertEqual(self.browser.calls[-1][0], 'take_snapshot')  # the old click never reached the browser


if __name__ == '__main__':
    unittest.main()
