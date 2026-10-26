"""Browser control state and the append-only audit trail (ADR-002 sections 5 and 6).

The office writes these rows itself; a worker's own account of what happened is stored
with provenance worker_reported and never counts as proof that an action ran.
Nothing secret goes in: no typed text, keys, cookies, headers, leases, query strings,
fragments or raw tool payloads. Python standard library only."""
from __future__ import annotations
from datetime import datetime, timezone
from urllib.parse import urlsplit

SESSION = 'cat-chrome'  # one shared Chrome for now; every task and takeover goes through it
SCHEMA = '''
CREATE TABLE IF NOT EXISTS browser_sessions (id TEXT PRIMARY KEY, state TEXT NOT NULL, control_epoch INTEGER NOT NULL,
    controller_device_id TEXT, task_id TEXT, attempt INTEGER, blocked TEXT NOT NULL DEFAULT '', updated TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS browser_snapshots (snapshot_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, control_epoch INTEGER NOT NULL,
    task_id TEXT NOT NULL, tab_id TEXT NOT NULL, generation TEXT NOT NULL, targets TEXT NOT NULL, created TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS browser_actions (action_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, attempt INTEGER NOT NULL,
    fingerprint TEXT NOT NULL, session_id TEXT NOT NULL, control_epoch INTEGER NOT NULL, tool TEXT NOT NULL,
    target_summary TEXT NOT NULL, policy_version TEXT NOT NULL, rule_id TEXT NOT NULL, decision TEXT NOT NULL,
    reason_code TEXT NOT NULL, outcome TEXT, response TEXT, created TEXT NOT NULL, finished TEXT);
CREATE TABLE IF NOT EXISTS browser_audit_events (seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
    event_type TEXT NOT NULL, task_id TEXT, attempt INTEGER, initiator_kind TEXT, browser_session_id TEXT,
    control_epoch INTEGER, action_id TEXT, tool TEXT, target_summary TEXT, policy_version TEXT, rule_id TEXT,
    decision TEXT, outcome TEXT, reason_code TEXT, provenance TEXT NOT NULL);
'''
FIELDS = ('task_id', 'attempt', 'initiator_kind', 'browser_session_id', 'control_epoch', 'action_id', 'tool',
          'target_summary', 'policy_version', 'rule_id', 'decision', 'outcome', 'reason_code')
PROVENANCE = ('broker_observed', 'worker_reported', 'human_control_event')


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def ensure_schema(c):
    c.executescript(SCHEMA)
    c.execute("INSERT OR IGNORE INTO browser_sessions(id,state,control_epoch,updated) VALUES (?,?,1,?)", (SESSION, 'agent_running', now()))


def origin(url):
    """Only scheme and host: paths and queries can carry tokens, names or search terms."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return 'invalid-url'
    if parts.scheme in ('http', 'https') and parts.hostname:
        return f'{parts.scheme}://{parts.hostname}' + (f':{parts.port}' if parts.port else '')
    return (parts.scheme or 'no-scheme') + ':'


def append(c, event_type, provenance, **fields):
    """The only way rows enter the audit; there is no update or delete path in the application."""
    if provenance not in PROVENANCE or not set(fields) <= set(FIELDS):
        raise ValueError('audit field or provenance not allowed')
    clean = {k: (v[:200] if isinstance(v, str) else v) for k, v in fields.items()}
    columns = ['at', 'event_type', 'provenance', *clean]
    c.execute(f"INSERT INTO browser_audit_events({','.join(columns)}) VALUES ({','.join('?' * len(columns))})",
              [now(), event_type, provenance, *clean.values()])


def task_events(c, task_id, after=0, limit=100):
    rows = c.execute('SELECT seq,at,event_type,action_id,tool,target_summary,policy_version,rule_id,decision,outcome,'
                     'reason_code,provenance,control_epoch FROM browser_audit_events WHERE task_id=? AND seq>? ORDER BY seq LIMIT ?',
                     (task_id, after, limit + 1)).fetchall()
    events = [dict(r) for r in rows[:limit]]
    return {'events': events, 'more': len(rows) > limit, 'next_after': events[-1]['seq'] if events else after}
