"""Browser action broker (ADR-002 section 4): the agent proposes, the office decides and dispatches.

Only calls that come through here are governed. The capability baseline (G0) shows the
agent's shell can still reach Chrome's DevTools port, its profile and the X display, so
nothing here may be described as covering every path. Python standard library only."""
from __future__ import annotations
import hashlib
import hmac
import json
import re
import secrets
import threading
import uuid
from urllib.parse import urlsplit

import browser_audit as audit

POLICY_VERSION = 'browser-policy-1'
ACTIVE = ('planning', 'running', 'saving')
REQUEST_KEYS = {'task_id', 'lease', 'action_id', 'control_epoch', 'tool', 'args', 'snapshot_id', 'target_ref'}
# Fixed tool table: argument schema, whether a page target is required, and its kind.
TOOLS = {
    'take_snapshot': {'kind': 'observe', 'args': {}, 'target': False},
    'read_text': {'kind': 'read', 'args': {}, 'target': False},
    'take_screenshot': {'kind': 'read', 'args': {}, 'target': False},
    'navigate': {'kind': 'navigate', 'args': {'url': 2000}, 'target': False},
    'click': {'kind': 'click', 'args': {}, 'target': True},
    'type_text': {'kind': 'input', 'args': {'text': 2000}, 'target': True},
    'press_key': {'kind': 'input', 'args': {'key': 40}, 'target': False},
    'submit_form': {'kind': 'input', 'args': {}, 'target': True},
    'upload_file': {'kind': 'transfer', 'args': {'path': 400}, 'target': True},
    'download': {'kind': 'transfer', 'args': {}, 'target': True},
}
# Raw capabilities the broker never offers: arbitrary script, traffic, memory, screen recording.
RAW_DENIED = {'evaluate_script', 'get_network_request', 'list_network_requests', 'take_heapsnapshot',
              'screencast_start', 'screencast_stop', 'performance_start_trace', 'performance_stop_trace',
              'emulate', 'handle_dialog', 'drag', 'fill_form', 'lighthouse_audit'}
ACTION_PATH = re.compile(r'(^|[/_.-])(log-?out|sign-?out|delete|remove|unsubscribe|confirm|approve|pay|payment|checkout|'
                         r'transfer|send|purchase|order|cancel|merge|publish|submit)([/_.-]|$)', re.I)
STATUS = {'allow': 200, 'needs_human': 200, 'deny': 403}


class BrowserFailed(Exception):
    """The browser reported a definite failure: nothing happened on the page."""


class BrowserUnknown(Exception):
    """Timeout or lost connection: whether the page acted is not known."""


def classify(tool, args, target):
    """Fixed rules, most restrictive first. Returns (decision, rule_id, reason_code)."""
    if tool in RAW_DENIED:
        return 'deny', 'R7-raw-tool', 'raw_tool_not_offered'
    spec = TOOLS.get(tool)
    if spec is None:
        return 'deny', 'R0-unknown-tool', 'unknown_tool'
    kind = spec['kind']
    if kind in ('observe', 'read'):
        return 'allow', 'R1-read', 'read_only'
    if kind == 'navigate':
        return url_rule(args['url'], 'R2-navigate')
    if kind == 'click':
        if target and target.get('role') == 'link' and target.get('href'):
            return url_rule(target['href'], 'R4-link')
        return 'needs_human', 'R5-click', 'click_effect_unknown'
    return 'needs_human', 'R6-effect', 'external_effect'


def url_rule(url, rule_id):
    parts = urlsplit(url)
    if parts.scheme not in ('http', 'https') or not parts.hostname:
        return 'deny', 'R2-scheme', 'scheme_not_allowed'
    if parts.username or parts.password:
        return 'deny', 'R2-credentials', 'credentials_in_url'
    if ACTION_PATH.search(parts.path):
        return 'needs_human', 'R3-action-url', 'action_like_url'
    return 'allow', rule_id, 'navigation'


class Broker:
    def __init__(self, store, browser, mode_check=True):
        self.store, self.browser = store, browser
        self.key = secrets.token_bytes(32)  # fingerprints never hash typed text with a key that is stored
        self.gate = threading.Lock()         # one action or control change at a time for the shared Chrome
        self.mode_check = mode_check
        with store.connect() as c:
            audit.ensure_schema(c)

    # -- entry -------------------------------------------------------------------------------

    def act(self, request):
        problem = self.validate(request)
        if problem:
            return 400, {'error': problem}
        task_id, action_id, tool = request['task_id'], request['action_id'], request['tool']
        args = request.get('args') or {}
        try:
            with self.store.lock:
                with self.store.connect() as c:
                    task = self.task(c, task_id, request['lease'])
                    if isinstance(task, tuple):
                        return task
                    existing = c.execute('SELECT * FROM browser_actions WHERE action_id=?', (action_id,)).fetchone()
                    if existing:
                        return self.replay(existing, request)
                    session = c.execute('SELECT * FROM browser_sessions WHERE id=?', (audit.SESSION,)).fetchone()
                    if session['blocked']:
                        return 503, {'error': '有一個動作的結果還沒核對，先停下來。', 'reason_code': 'reconcile_pending'}
                    if request['control_epoch'] != session['control_epoch']:
                        return 409, {'error': '控制世代已經變了，請重新觀察。', 'reason_code': 'stale_epoch',
                                     'control_epoch': session['control_epoch']}
                    if session['state'] != 'agent_running':
                        return 409, {'error': '現在由人接手或暫停中。', 'reason_code': 'held', 'control_state': session['state']}
                    target = None
                    if TOOLS.get(tool, {}).get('target'):
                        target = self.resolve(c, request, session)
                        if isinstance(target, tuple):
                            return target
                    decision, rule_id, reason = classify(tool, args, target)
                    summary = self.summary(tool, args, target)
                    c.execute('INSERT INTO browser_actions(action_id,task_id,attempt,fingerprint,session_id,control_epoch,tool,'
                              'target_summary,policy_version,rule_id,decision,reason_code,created) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                              (action_id, task_id, task['attempts'], self.fingerprint(request), audit.SESSION, session['control_epoch'],
                               tool, summary, POLICY_VERSION, rule_id, decision, reason, audit.now()))
                    audit.append(c, 'decision', 'broker_observed', task_id=task_id, attempt=task['attempts'],
                                 initiator_kind=task['initiator_kind'], browser_session_id=audit.SESSION,
                                 control_epoch=session['control_epoch'], action_id=action_id, tool=tool,
                                 target_summary=summary, policy_version=POLICY_VERSION, rule_id=rule_id,
                                 decision=decision, reason_code=reason)
        except Exception:
            # The decision could not be written first, so nothing is dispatched.
            return 503, {'error': '紀錄寫不進去，這個動作沒有執行。', 'reason_code': 'audit_unavailable'}
        if decision != 'allow':
            return self.finish(action_id, task, 'not_dispatched', reason, decision, {})
        return self.dispatch(action_id, task, tool, args, target, request['control_epoch'])

    # -- checks ------------------------------------------------------------------------------

    @staticmethod
    def validate(request):
        if not isinstance(request, dict) or not set(request) <= REQUEST_KEYS:
            return '有不認得的欄位。'
        for key in ('task_id', 'lease', 'action_id', 'tool'):
            if not isinstance(request.get(key), str) or not request[key]:
                return f'{key} 需為字串。'
        try:
            if str(uuid.UUID(request['action_id'])) != request['action_id']:
                raise ValueError
        except ValueError:
            return 'action_id 需為 UUID。'
        if not isinstance(request.get('control_epoch'), int) or isinstance(request['control_epoch'], bool):
            return 'control_epoch 需為整數。'
        args = request.get('args', {})
        if not isinstance(args, dict):
            return 'args 需為物件。'
        spec = TOOLS.get(request['tool'])
        if spec:
            if set(args) != set(spec['args']):
                return '這個工具的參數不對。'
            for name, limit in spec['args'].items():
                if not isinstance(args[name], str) or not 0 < len(args[name]) <= limit:
                    return f'{name} 需為 1 至 {limit} 字。'
            if spec['target'] and not (isinstance(request.get('snapshot_id'), str) and isinstance(request.get('target_ref'), str)):
                return '這個工具需要 snapshot_id 和 target_ref。'
        return None

    def task(self, c, task_id, lease):
        row = c.execute('SELECT id,status,executor,lease,attempts,initiator_kind,browser_mode FROM tasks WHERE id=?', (task_id,)).fetchone()
        if row is None or row['executor'] != 'hands':
            return 404, {'error': '找不到這件工作。'}
        if row['status'] not in ACTIVE or not hmac.compare_digest(row['lease'].encode(), lease.encode()):
            return 409, {'error': '這件工作已經停止或交給新的一輪。', 'reason_code': 'stale_lease'}
        if self.mode_check and row['browser_mode'] != 'broker':
            return 409, {'error': '這件工作不是 broker 模式。', 'reason_code': 'mode_mismatch'}
        settings = dict(c.execute("SELECT key,value FROM settings WHERE key IN ('paused','hands_locked')").fetchall())
        if '1' in settings.values():
            return 409, {'error': '辦公室暫停中或已收回權限。', 'reason_code': 'stopped'}
        return row

    def resolve(self, c, request, session):
        snap = c.execute('SELECT * FROM browser_snapshots WHERE snapshot_id=?', (request['snapshot_id'],)).fetchone()
        if snap is None or snap['task_id'] != request['task_id'] or snap['control_epoch'] != session['control_epoch']:
            return 409, {'error': '這個畫面快照已經過時，請重新觀察。', 'reason_code': 'stale_snapshot'}
        target = json.loads(snap['targets']).get(request['target_ref'])
        if target is None:
            return 409, {'error': '快照裡沒有這個目標。', 'reason_code': 'unknown_target'}
        return {**target, 'tab_id': snap['tab_id'], 'generation': snap['generation'], 'ref': request['target_ref']}

    @staticmethod
    def summary(tool, args, target):
        if tool == 'navigate':
            return audit.origin(args['url'])
        if target:
            return f"{target.get('role', 'element')}" + (f" → {audit.origin(target['href'])}" if target.get('href') else '')
        return tool

    def fingerprint(self, request):
        canonical = json.dumps({k: request.get(k) for k in ('task_id', 'tool', 'args', 'snapshot_id', 'target_ref')},
                               sort_keys=True, ensure_ascii=False)
        return hmac.new(self.key, canonical.encode(), hashlib.sha256).hexdigest()

    def replay(self, row, request):
        """Same action_id: the stored answer, never a second dispatch."""
        if row['task_id'] != request['task_id'] or not hmac.compare_digest(row['fingerprint'], self.fingerprint(request)):
            return 409, {'error': '這個 action_id 已經用在別的動作上。', 'reason_code': 'action_id_conflict'}
        stored = json.loads(row['response']) if row['response'] else {
            'action_id': row['action_id'], 'decision': row['decision'], 'outcome': row['outcome'] or 'unknown',
            'reason_code': 'outcome_pending'}
        return STATUS.get(row['decision'], 200), {**stored, 'replayed': True}

    # -- dispatch and outcome ----------------------------------------------------------------

    def dispatch(self, action_id, task, tool, args, target, epoch):
        with self.gate:
            with self.store.connect() as c:  # control may have changed while we waited for the gate
                session = c.execute('SELECT state,control_epoch FROM browser_sessions WHERE id=?', (audit.SESSION,)).fetchone()
                stopped = c.execute("SELECT 1 FROM settings WHERE key IN ('paused','hands_locked') AND value='1'").fetchone()
            if session['state'] != 'agent_running' or session['control_epoch'] != epoch or stopped:
                return self.finish(action_id, task, 'not_dispatched', 'held_before_dispatch', 'allow', {}, 409)
            # The page is checked here, outside any database transaction and right before acting on it.
            if target and self.browser.generation(target['tab_id']) != target['generation']:
                return self.finish(action_id, task, 'not_dispatched', 'stale_target', 'allow', {}, 409)
            try:
                result = self.browser.execute(tool, args, target)
                outcome, reason = 'succeeded', 'done'
            except BrowserFailed:
                result, outcome, reason = {}, 'failed', 'browser_failed'
            except Exception:  # timeout, lost connection or anything else: the page may have acted
                result, outcome, reason = {}, 'unknown', 'result_unknown'
            if tool == 'take_snapshot' and outcome == 'succeeded':
                result = self.save_snapshot(task['id'], epoch, result)
            return self.finish(action_id, task, outcome, reason, 'allow', result)

    def save_snapshot(self, task_id, epoch, snap):
        snapshot_id = str(uuid.uuid4())
        targets = {ref: {k: v for k, v in t.items() if k in ('role', 'href')} for ref, t in snap['targets'].items()}
        for t in targets.values():
            if t.get('href'):
                parts = urlsplit(t['href'])
                t['href'] = f'{parts.scheme}://{parts.netloc}{parts.path}'  # queries and fragments are not kept
        with self.store.connect() as c:
            c.execute('INSERT INTO browser_snapshots VALUES (?,?,?,?,?,?,?,?)', (snapshot_id, audit.SESSION, epoch, task_id,
                      snap['tab_id'], snap['generation'], json.dumps(targets), audit.now()))
        return {'snapshot_id': snapshot_id, 'tab_id': snap['tab_id'],
                'targets': {ref: {'role': t.get('role'), 'name': str(t.get('name', ''))[:120]} for ref, t in snap['targets'].items()}}

    def finish(self, action_id, task, outcome, reason, decision, result, status=None):
        body = {'action_id': action_id, 'decision': decision, 'outcome': outcome, 'reason_code': reason}
        if outcome == 'succeeded':
            body['result'] = result
        try:
            with self.store.connect() as c:
                c.execute('UPDATE browser_actions SET outcome=?,response=?,finished=? WHERE action_id=?',
                          (outcome, json.dumps(body, ensure_ascii=False), audit.now(), action_id))
                audit.append(c, 'outcome', 'broker_observed', task_id=task['id'], attempt=task['attempts'],
                             browser_session_id=audit.SESSION, action_id=action_id, decision=decision,
                             outcome=outcome, reason_code=reason)
        except Exception:
            self.block('outcome_unwritten')
            return 503, {'action_id': action_id, 'decision': decision, 'outcome': 'unknown',
                         'reason_code': 'outcome_unwritten', 'error': '結果寫不進去，先停下來核對。'}
        return status or STATUS.get(decision, 200), body

    def block(self, why):
        """Stop new actions on this session until a person reconciles; best effort if the database is down."""
        try:
            with self.store.connect() as c:
                c.execute('UPDATE browser_sessions SET blocked=?,updated=? WHERE id=?', (why, audit.now(), audit.SESSION))
        except Exception:
            pass  # the database is down too; act() cannot write a decision, so nothing is dispatched anyway

    def recover(self):
        """At startup: an allowed action with no outcome may have acted, so it becomes unknown and is never resent."""
        with self.store.connect() as c:
            rows = c.execute("SELECT action_id,task_id,attempt FROM browser_actions WHERE decision='allow' AND outcome IS NULL").fetchall()
            for row in rows:
                c.execute("UPDATE browser_actions SET outcome='unknown',finished=? WHERE action_id=?", (audit.now(), row['action_id']))
                audit.append(c, 'reconciled', 'broker_observed', task_id=row['task_id'], attempt=row['attempt'],
                             browser_session_id=audit.SESSION, action_id=row['action_id'], decision='allow',
                             outcome='unknown', reason_code='restart_without_outcome')
            if rows:
                c.execute('UPDATE browser_sessions SET blocked=?,updated=? WHERE id=?', ('reconcile_pending', audit.now(), audit.SESSION))
        return len(rows)
