#!/usr/bin/env python3
"""Live synthetic acceptance through the office API, never through fixture agents."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:18421')
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--provider', choices=['codex', 'gemma'], default='codex')
args = parser.parse_args()
token = ''
def api(path, body=None):
    req = urllib.request.Request(args.url+path, None if body is None else json.dumps(body).encode(),
        {} if body is None else {'Content-Type':'application/json', 'X-Office-Token':token})
    with urllib.request.urlopen(req, timeout=10) as r: return json.load(r)
def uid(): return str(uuid.uuid4())
def wait(id_):
    deadline=time.monotonic()+400
    while time.monotonic()<deadline:
        task=api('/api/tasks/'+id_)
        if task['status'] not in ('queued','planning','running','saving'): return task
        time.sleep(1)
    raise AssertionError('live task timed out')
token=api('/api/bootstrap')['token']
before=api('/api/health')
assert not before['paused'], 'Office is paused; do not alter user control state'
a={'id':uid(),'day':'2026-10-21','text':'【合成驗證】小林 10 月 25 日交初稿，預算 300 元；是否出門尚未決定。'}
b={'id':uid(),'day':'2026-10-21','text':'【合成驗證】UNSELECTED_SENTINEL_73，不可附到其他任務。'}
api('/api/journal',a);api('/api/journal',a);api('/api/journal',b)
request={'id':uid(),'prompt':'將選取的紀錄整理成兩點，保留日期、金額及不確定性。','executor':args.provider,'journal_ids':[a['id']]}
first=api('/api/command',request)['task'];again=api('/api/command',request)['task'];assert first['id']==again['id']
done=wait(first['id'])
assert a['text'] in done['context_snapshot'] and b['text'] not in done['context_snapshot']
assert done['executor']==args.provider
if args.provider=='codex' and not before['provider']['authenticated']:
    assert done['status']=='needs_provider' and done['result'] is None
else:
    assert done['status']=='completed', done['stage']
    assert '25' in done['result'] and '300' in done['result'], done['result']
handoff={'id':uid(),'note':'【合成驗證】已確認日期與金額。','next_step':'下次請明確保留尚未決定的外出計畫。'}
saved=api('/api/tasks/'+done['id']+'/handoff',handoff)
api('/api/tasks/'+done['id']+'/handoff',handoff)
assert handoff['next_step'] in saved['text']
child_request={'id':uid(),'prompt':'請依交接重寫為一句提醒，保留尚未決定的事。','executor':args.provider,'parent_id':done['id']}
child=api('/api/command',child_request)['task'];child_done=wait(child['id'])
assert handoff['next_step'] in child_done['context_snapshot']
assert b['text'] not in child_done['context_snapshot']
if args.provider=='codex' and not before['provider']['authenticated']: assert child_done['status']=='needs_provider'
else: assert child_done['status']=='completed', child_done['stage']
report={'provider':args.provider,'health_before':before,'health_after':api('/api/health'),
        'journal_ids':[a['id'],b['id']],'task':done,'child':child_done,'handoff':saved,
        'result_sha256':hashlib.sha256((done['result'] or '').encode()).hexdigest()}
args.report.parent.mkdir(parents=True,exist_ok=True)
args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'provider':args.provider,'task':done['id'],'status':done['status'],'child':child_done['id'],
                  'child_status':child_done['status'],'report':str(args.report)},ensure_ascii=False))
