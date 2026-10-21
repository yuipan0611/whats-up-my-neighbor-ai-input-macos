"""End-to-end acceptance using synthetic Chinese notes and a real local model."""
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid

BASE='http://127.0.0.1:8421'
ROOT=Path.home()/'neighbor-office/data'
report={'started_at':time.time(),'checks':[],'tasks':{}}
token=''
def get(path):
    with urllib.request.urlopen(BASE+path,timeout=10) as r:return json.load(r)
def auth():
    global token
    token=get('/api/bootstrap')['token']
def post(path,body):
    req=urllib.request.Request(BASE+path,json.dumps(body,ensure_ascii=False).encode(),{'Content-Type':'application/json','X-Office-Token':token})
    with urllib.request.urlopen(req,timeout=10) as r:return json.load(r)
def submit(prompt,source=''):
    body={'id':str(uuid.uuid4()),'prompt':prompt,'source':source,'executor':'gemma'}
    post('/api/command',body)
    return body

def wait(id_, states, timeout=240):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        t=get('/api/tasks/'+id_)
        if t['status'] in states:return t
        if t['status'] in ['failed','needs_input','needs_external','incomplete','completed','interrupted','cancelled']:
            raise AssertionError(f'Unexpected status {t["status"]}: {t["stage"]}')
        time.sleep(0.5)
    raise AssertionError('Task deadline exceeded')
def mark(name):
    report['checks'].append(name);print('PASS '+name,flush=True)
def restart():
    subprocess.run(['systemctl','--user','restart','neighbor-office'],check=True)
    for _ in range(40):
        try:
            auth();return
        except (OSError,ValueError):time.sleep(0.25)
    raise AssertionError('Service did not recover')

auth()
source='驗收筆記-20261021.md'
text='2026年10月21日會議筆記：小林負責整理需求，10月25日交初稿。小陳負責測試，預算上限是1200元。目前還沒決定是否購買新主機，先測試現有VPS。'
try:post('/api/files',{'name':source,'text':text})
except urllib.error.HTTPError as e:
    if e.code!=409:raise
    e.close()
assert (ROOT/'inbox'/source).read_text()==text
mark('upload independently read back')

body=submit('幫我整理成三個重點，保留日期、人名、金額與尚未決定的事。',source)
post('/api/command',body)
assert sum(t['id']==body['id'] for t in get('/api/tasks')['tasks'])==1
mark('duplicate submission is idempotent')
print('DETACH_TEST_READY '+body['id'],flush=True)
start=time.monotonic()
task=wait(body['id'],['completed'])
assert (ROOT/task['artifact']).read_text()==task['result']
assert all(v in task['result'] for v in ('小林','小陳','1200'))
report['tasks']['summary']=task
report['summary_seconds']=round(time.monotonic()-start,2)
mark('real model summary completed and artifact independently read back')

body=submit('幫我整理這份筆記。')
task=wait(body['id'],['needs_input']);report['tasks']['clarification']=task
assert task['result'] is None
mark('missing content asks for input without fabricated result')
body=submit('幫我上網查今天的台灣新聞，整理來源連結。')
task=wait(body['id'],['needs_external']);report['tasks']['external']=task
assert task['artifact'].endswith('brief.md') and '交接單' in task['result']
mark('external request remains pending with saved brief')

body=submit('請幫我寫一段五百字的工作鼓勵。')
wait(body['id'],['planning','running'])
post('/api/tasks/'+body['id']+'/cancel',{})
time.sleep(2)
task=get('/api/tasks/'+body['id']);assert task['status']=='cancelled' and task['artifact'] is None
report['tasks']['cancelled']=task
mark('cancel active real-model task prevents completed artifact')

post('/api/command',{'prompt':'先停一下'})
body=submit('把選取的筆記整理成兩個重點，保留預算與交稿日期。',source)
assert get('/api/tasks/'+body['id'])['status']=='queued'
restart()
assert get('/api/tasks')['paused'] is True and get('/api/tasks/'+body['id'])['status']=='queued'
assert get('/api/tasks/'+report['tasks']['summary']['id'])['result']==report['tasks']['summary']['result']
mark('service restart preserves paused queue and previous result')
post('/api/command',{'prompt':'繼續工作'})
task=wait(body['id'],['completed']);report['tasks']['resumed']=task
mark('resume executes saved queue and saves new artifact')

body=submit('幫我寫一段五百字的工作鼓勵。')
wait(body['id'],['planning','running'])
restart()
task=get('/api/tasks/'+body['id']);assert task['status']=='interrupted'
report['tasks']['interrupted']=task
mark('restart marks active work interrupted and does not repeat it')

state=post('/api/command',{'prompt':'做到哪了？'})
assert state['control']=='status'
mark('natural language status reads persisted state')
report['health']=get('/api/health')
report['finished_at']=time.time()
path=Path.home()/'neighbor-office/live-verification.json'
path.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('LIVE_VERIFICATION_SAVED '+str(path),flush=True)
