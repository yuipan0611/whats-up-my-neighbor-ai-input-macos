"""Who controls the cat's Chrome: take, stop confirmation, return and re-observation (ADR-002 section 6, G4).

One persistent state per browser session, changed by compare-and-swap under the store lock:

    agent_running → taking_control → human_control ⇄ human_disconnected → resuming → agent_running
    any of them → held (stop not confirmed, restart, resume failed)

Every take and return raises the control epoch, so snapshots, targets and queued calls from
before are stale. Person input opens only after the worker has confirmed that the agent and its
tools stopped and the broker has no action in flight; the agent runs again only after the broker
itself took a new snapshot. Nothing here times out into giving control back to the agent.
Python standard library only."""
from __future__ import annotations
import hashlib
import json
import threading
import time
import uuid

import browser_audit as audit

STOP_SECONDS = 5          # ADR-002 6.1: engineering budget for the stop confirmation; not a measured latency
DISCONNECT_SECONDS = 15   # no controller ping for this long: the person's control connection is gone
COLUMNS = {'controller_seen': 'REAL', 'state_since': 'REAL', 'hold_reason': "TEXT NOT NULL DEFAULT ''"}


def ensure_schema(c):
    audit.ensure_schema(c)
    have = {r[1] for r in c.execute('PRAGMA table_info(browser_sessions)')}
    for name, kind in COLUMNS.items():
        if name not in have:
            c.execute(f'ALTER TABLE browser_sessions ADD COLUMN {name} {kind}')
    c.execute('CREATE TABLE IF NOT EXISTS browser_control_ops (operation_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, '
              'status INTEGER NOT NULL, response TEXT NOT NULL, created TEXT NOT NULL)')


class Control:
    def __init__(self, store, broker, clock=time.time):
        self.store, self.broker, self.clock = store, broker, clock
        self.ops = threading.Lock()  # one person operation at a time; each one is short
        with store.connect() as c:
            ensure_schema(c)

    # -- helpers ---------------------------------------------------------------------------

    def session(self, c):
        return c.execute('SELECT * FROM browser_sessions WHERE id=?', (audit.SESSION,)).fetchone()

    def live_task(self, c, session):
        """The broker-mode hands task the session belongs to, if it is still running."""
        if not session['task_id']:
            return None
        return c.execute("SELECT id,attempts,initiator_kind FROM tasks WHERE id=? AND status IN ('planning','running','saving') "
                         "AND browser_mode='broker'", (session['task_id'],)).fetchone()

    def move(self, c, state, bump=False, reason='', **fields):
        sets = {'state': state, 'state_since': self.clock(), 'hold_reason': reason, 'updated': audit.now(), **fields}
        c.execute(f"UPDATE browser_sessions SET {','.join(k + '=?' for k in sets)}"
                  + (',control_epoch=control_epoch+1' if bump else '') + ' WHERE id=?', [*sets.values(), audit.SESSION])
        return self.session(c)

    @staticmethod
    def record(c, event_type, provenance, session, reason):
        """Best effort: a broken audit table must never keep a stop from happening."""
        try:
            audit.append(c, event_type, provenance, task_id=session['task_id'], attempt=session['attempt'],
                         browser_session_id=audit.SESSION, control_epoch=session['control_epoch'], reason_code=reason)
        except Exception:
            pass

    def sweep(self, c):
        """Time-driven moves: an unconfirmed stop becomes held, a silent controller becomes disconnected."""
        s = self.session(c)
        t = self.clock()
        if s['state'] == 'taking_control' and t - (s['state_since'] or 0) > STOP_SECONDS:
            s = self.move(c, 'held', reason='stop_unconfirmed')
            self.record(c, 'control_held', 'broker_observed', s, 'stop_unconfirmed')
        elif s['state'] == 'human_control' and t - (s['controller_seen'] or 0) > DISCONNECT_SECONDS:
            s = self.move(c, 'human_disconnected', reason='controller_disconnected', controller_seen=s['controller_seen'])
            self.record(c, 'control_disconnected', 'human_control_event', s, 'controller_disconnected')
        return s

    def gate_clear(self, timeout):
        """Wait for an action already dispatched to finish; True when nothing is in flight."""
        if not self.broker.gate.acquire(timeout=timeout):
            return False
        self.broker.gate.release()
        with self.store.connect() as c:
            return c.execute("SELECT 1 FROM browser_actions WHERE session_id=? AND decision='allow' AND outcome IS NULL",
                             (audit.SESSION,)).fetchone() is None

    # -- person side -----------------------------------------------------------------------

    def operate(self, device_id, request):
        """POST /api/viewer/control: {operation_id, action: take|return|ping, expected_epoch}."""
        if not isinstance(request, dict) or set(request) != {'operation_id', 'action', 'expected_epoch'}:
            return 400, {'error': '需要 operation_id、action 與 expected_epoch。'}
        try:
            if str(uuid.UUID(request['operation_id'])) != request['operation_id']:
                raise ValueError
        except (ValueError, TypeError, AttributeError):
            return 400, {'error': 'operation_id 需為 UUID。'}
        if request['action'] not in ('take', 'return', 'ping'):
            return 400, {'error': 'action 只能是 take、return 或 ping。'}
        if not isinstance(request['expected_epoch'], int) or isinstance(request['expected_epoch'], bool):
            return 400, {'error': 'expected_epoch 需為整數。'}
        fingerprint = hashlib.sha256(json.dumps([device_id, request['action'], request['expected_epoch']]).encode()).hexdigest()
        with self.ops:
            with self.store.connect() as c:
                done = c.execute('SELECT * FROM browser_control_ops WHERE operation_id=?', (request['operation_id'],)).fetchone()
            if done:
                if done['fingerprint'] != fingerprint:
                    return 409, {'error': '這個 operation_id 已經用在別的操作上。', 'reason_code': 'operation_conflict'}
                return done['status'], {**json.loads(done['response']), 'replayed': True}
            status, body = {'take': self.take, 'return': self.ret, 'ping': self.ping}[request['action']](device_id, request['expected_epoch'])
            if request['action'] != 'ping':
                with self.store.connect() as c:
                    c.execute('INSERT INTO browser_control_ops VALUES (?,?,?,?,?)', (request['operation_id'], fingerprint, status,
                              json.dumps(body, ensure_ascii=False), audit.now()))
            return status, body

    def take(self, device_id, expected):
        with self.store.lock:
            with self.store.connect() as c:
                s = self.sweep(c)
                if expected != s['control_epoch']:
                    return 409, self.stale(s)
                if s['state'] == 'human_control' and s['controller_device_id'] == device_id:
                    return 202, self.view(s, device_id)
                if c.execute("SELECT 1 FROM tasks WHERE executor='hands' AND browser_mode!='broker' AND status IN ('planning','running','saving')").fetchone():
                    # A legacy worker does not speak this protocol, so its agent could keep going under the person's hands.
                    return 409, {'error': '正在跑的這件是舊模式，不能接手；要的話先停止這件。', 'reason_code': 'legacy_task_running'}
                # Close the gate first: from here no new agent action passes the broker's checks.
                agent_may_run = s['state'] in ('agent_running', 'resuming', 'taking_control', 'held')
                s = self.move(c, 'taking_control', bump=True, controller_device_id=device_id, controller_seen=self.clock())
                self.record(c, 'control_requested', 'human_control_event', s, 'take')
                needs_ack = agent_may_run and self.live_task(c, s) is not None
        if not self.gate_clear(STOP_SECONDS):
            with self.store.lock:
                with self.store.connect() as c:
                    s = self.session(c)
                    if s['state'] == 'taking_control':
                        s = self.move(c, 'held', reason='in_flight_unresolved', controller_device_id=device_id)
                        self.record(c, 'control_held', 'broker_observed', s, 'in_flight_unresolved')
            return 202, self.view(s, device_id)
        if not needs_ack:  # no agent attached to this browser: nothing to stop
            with self.store.lock:
                with self.store.connect() as c:
                    s = self.session(c)
                    if s['state'] == 'taking_control' and s['controller_device_id'] == device_id:
                        s = self.move(c, 'human_control', controller_device_id=device_id, controller_seen=self.clock())
                        self.record(c, 'control_taken', 'broker_observed', s, 'nothing_to_stop')
        return 202, self.view(s, device_id)

    def ret(self, device_id, expected):
        with self.store.lock:
            with self.store.connect() as c:
                s = self.sweep(c)
                if expected != s['control_epoch']:
                    return 409, self.stale(s)
                if s['state'] not in ('human_control', 'human_disconnected', 'held'):
                    return 409, {'error': '現在不是由人接手，沒有可以交還的。', 'reason_code': 'not_held', 'control_state': s['state']}
                reconcile = bool(s['blocked'])
                live = self.live_task(c, s)
                # The person looked and handed it back: a pending reconcile is theirs to have cleared.
                s = self.move(c, 'resuming' if live else 'agent_running', bump=True, controller_device_id=None, blocked='')
                self.record(c, 'control_return_requested', 'human_control_event', s,
                            'reconcile_acknowledged' if reconcile else 'return')
                if not live:
                    self.record(c, 'control_released', 'broker_observed', s, 'no_agent_attached')
        return 202, self.view(s, device_id)

    def ping(self, device_id, expected):
        """The controller's connection is alive; a disconnected controller has to take again."""
        with self.store.lock:
            with self.store.connect() as c:
                s = self.sweep(c)
                if s['state'] != 'human_control' or s['controller_device_id'] != device_id or expected != s['control_epoch']:
                    return 409, {**self.stale(s), 'reason_code': 'not_controller'}
                c.execute('UPDATE browser_sessions SET controller_seen=? WHERE id=?', (self.clock(), audit.SESSION))
                return 200, self.view(self.session(c), device_id)

    def input_allowed(self, device_id, epoch):
        """For each batch of viewer input: only the current controller, in the current epoch, while connected."""
        with self.store.lock:
            with self.store.connect() as c:
                s = self.sweep(c)
        return s['state'] == 'human_control' and s['controller_device_id'] == device_id and s['control_epoch'] == epoch

    def state(self, device_id):
        with self.store.lock:
            with self.store.connect() as c:
                return self.view(self.sweep(c), device_id)

    def view(self, s, device_id):
        """What a paired device may see: no lease, no CDP address, no page content."""
        controller = s['controller_device_id']
        return {'control_state': s['state'], 'control_epoch': s['control_epoch'], 'hold_reason': s['hold_reason'],
                'controller': None if not controller else ('this_device' if controller == device_id else 'other_device'),
                'can_input': s['state'] == 'human_control' and controller == device_id,
                'reconcile_pending': bool(s['blocked']), 'task_id': s['task_id'],
                'waiting_seconds': int(self.clock() - s['state_since']) if s['state_since'] and s['state'] != 'agent_running' else 0}

    @staticmethod
    def stale(s):
        return {'error': '狀態已經變了，請重新整理再操作。', 'reason_code': 'stale_epoch', 'control_epoch': s['control_epoch'],
                'control_state': s['state']}

    # -- worker side -----------------------------------------------------------------------

    def claimable(self):
        """While a person holds the Chrome, no hands task is handed out: not the next one either."""
        with self.store.lock:
            with self.store.connect() as c:
                return self.sweep(c)['state'] in ('agent_running', 'resuming')

    def attach(self, task):
        with self.store.lock:
            with self.store.connect() as c:
                c.execute('UPDATE browser_sessions SET task_id=?,attempt=?,updated=? WHERE id=?',
                          (task['id'], task['attempts'], audit.now(), audit.SESSION))

    def worker_view(self, task_id):
        """Added to the heartbeat of a broker-mode task: whether its agent must stay stopped."""
        with self.store.lock:
            with self.store.connect() as c:
                s = self.sweep(c)
                if s['task_id'] != task_id and s['state'] in ('agent_running', 'resuming'):
                    # Only one hands task runs at a time, so an active one that beats here is this session's task
                    # (a claim that skipped attach, or a new attempt after a worker restart).
                    task = c.execute('SELECT attempts FROM tasks WHERE id=?', (task_id,)).fetchone()
                    c.execute('UPDATE browser_sessions SET task_id=?,attempt=?,updated=? WHERE id=?',
                              (task_id, task['attempts'], audit.now(), audit.SESSION))
                    s = self.session(c)
        mine = s['task_id'] == task_id
        return {'hold': not mine or s['state'] != 'agent_running', 'control_epoch': s['control_epoch'],
                'control_state': s['state'] if mine else 'held'}

    def ack(self, request):
        """POST /api/worker/browser/control-ack: checked against the broker's own records, not taken on the worker's word."""
        if not isinstance(request, dict) or not {'task_id', 'lease', 'control_epoch', 'checkpoint'} <= set(request) <= \
                {'task_id', 'lease', 'control_epoch', 'checkpoint', 'snapshot_id'}:
            return 400, {'error': '需要 task_id、lease、control_epoch 與 checkpoint。'}
        if request['checkpoint'] not in ('stopped', 'observed', 'failed'):
            return 400, {'error': 'checkpoint 只能是 stopped、observed 或 failed。'}
        if not all(isinstance(request[k], str) and request[k] for k in ('task_id', 'lease')):
            return 400, {'error': 'task_id 與 lease 需為字串。'}
        if request['checkpoint'] == 'stopped' and not self.gate_clear(STOP_SECONDS):
            return 409, {'error': '還有動作在進行，先不要開放操作。', 'reason_code': 'in_flight'}
        with self.store.lock:
            with self.store.connect() as c:
                task = self.broker.task(c, request['task_id'], request['lease'])
                if isinstance(task, tuple):
                    return task
                s = self.sweep(c)
                if s['task_id'] != task['id'] or request['control_epoch'] != s['control_epoch']:
                    return 409, self.stale(s)
                checkpoint = request['checkpoint']
                if checkpoint == 'stopped':
                    if s['state'] != 'taking_control':
                        return 409, {'error': '現在不是等停手的時候。', 'reason_code': 'wrong_state', 'control_state': s['state']}
                    if c.execute("SELECT 1 FROM browser_actions WHERE session_id=? AND decision='allow' AND outcome IS NULL",
                                 (audit.SESSION,)).fetchone():
                        return 409, {'error': '還有動作在進行，先不要開放操作。', 'reason_code': 'in_flight'}
                    s = self.move(c, 'human_control', controller_device_id=s['controller_device_id'], controller_seen=self.clock())
                    self.record(c, 'control_taken', 'broker_observed', s, 'stop_confirmed')
                elif s['state'] != 'resuming':
                    return 409, {'error': '現在不是交還的時候。', 'reason_code': 'wrong_state', 'control_state': s['state']}
                elif checkpoint == 'failed':
                    s = self.move(c, 'held', reason='resume_failed')
                    self.record(c, 'control_held', 'broker_observed', s, 'resume_failed')
                else:
                    snap = c.execute('SELECT targets FROM browser_snapshots WHERE snapshot_id=? AND session_id=? AND task_id=? AND control_epoch=?',
                                     (request.get('snapshot_id'), audit.SESSION, task['id'], s['control_epoch'])).fetchone()
                    if not snap:
                        return 409, {'error': '要附上交還之後由 broker 取得的新快照。', 'reason_code': 'observation_missing'}
                    if any(t.get('role') == 'secret' for t in json.loads(snap['targets']).values()):
                        # Still a sign-in or code screen: the person finishes it; nothing typed goes back to the agent.
                        s = self.move(c, 'held', reason='sensitive_page')
                        self.record(c, 'control_held', 'broker_observed', s, 'sensitive_page')
                        return 409, {'error': '頁面還在登入或驗證碼畫面，請你完成後再交還。', 'reason_code': 'sensitive_page',
                                     'control_state': s['state'], 'control_epoch': s['control_epoch']}
                    s = self.move(c, 'agent_running')
                    self.record(c, 'control_released', 'broker_observed', s, 'observed')
        return 200, {'control_state': s['state'], 'control_epoch': s['control_epoch']}

    # -- revoke and restart -----------------------------------------------------------------

    def revoked(self, device_id):
        """A revoked controller loses input at once; another paired device can take or return."""
        with self.store.lock:
            with self.store.connect() as c:
                s = self.session(c)
                if s['controller_device_id'] == device_id and s['state'] in ('taking_control', 'human_control', 'human_disconnected'):
                    s = self.move(c, 'held', reason='controller_revoked', controller_device_id=None)
                    self.record(c, 'control_held', 'human_control_event', s, 'controller_revoked')

    # -- restart ---------------------------------------------------------------------------

    def recover(self):
        """At startup nothing proves an in-between state safe: takes and resumes become held, a person's
        control stays theirs but disconnected. Never back to the agent without an explicit return."""
        with self.store.lock:
            with self.store.connect() as c:
                s = self.session(c)
                if s['state'] in ('taking_control', 'resuming'):
                    s = self.move(c, 'held', reason='restart')
                    self.record(c, 'control_held', 'broker_observed', s, 'restart')
                elif s['state'] == 'human_control':
                    s = self.move(c, 'human_disconnected', reason='restart', controller_seen=s['controller_seen'])
                    self.record(c, 'control_disconnected', 'broker_observed', s, 'restart')
                return s['state']
