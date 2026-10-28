#!/usr/bin/env python3
"""Submit one durable real collaboration through the dialogue API; inspect without replaying it."""
import argparse
import http.client
import json
from pathlib import Path
import socket
import uuid

ROOT=Path('/home/neighbor/neighbor-office')
OUTPUT=ROOT/'data/workbench-acceptance'
REQUEST=OUTPUT/'collaboration-request.json'
REPORT=OUTPUT/'collaboration-live.json'

class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        self.sock.settimeout(20); self.sock.connect(str(ROOT/'run/office.sock'))

def api(path,body=None,token=''):
    connection=Unix('127.0.0.1:18421',timeout=20)
    try:
        headers={'Host':'127.0.0.1:18421'}
        if body is not None: headers.update({'Content-Type':'application/json','X-Office-Token':token})
        connection.request('GET' if body is None else 'POST',path,
                           None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers)
        response=connection.getresponse(); value=json.loads(response.read())
        if response.status not in (200,202): raise RuntimeError(value.get('error','HTTP '+str(response.status)))
        return value
    finally: connection.close()

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--start',action='store_true'); args=parser.parse_args()
    OUTPUT.mkdir(mode=0o700,parents=True,exist_ok=True)
    if args.start:
        if not REQUEST.exists():
            request={'id':str(uuid.uuid4()),'executor':'collaborate',
                     'prompt':'【三家協作實機驗收】請 Claude 整理方案；Codex 只檢查 NekoNode 官網的固定版本，不修改檔案。執行工作台既定的型別、內容、語音測試及建置；Gemini 依測試證據獨立檢查。三家都請用繁體中文說明實際做了什麼及未驗證的限制，不要發布官網。'}
            REQUEST.write_text(json.dumps(request,ensure_ascii=False,indent=2)+'\n'); REQUEST.chmod(0o600)
        request=json.loads(REQUEST.read_text())
        token=api('/api/bootstrap')['token']
        first=api('/api/command',request,token)['task']
        second=api('/api/command',request,token)['task']
        assert first['id']==second['id']
    if not REQUEST.exists(): raise SystemExit('No real collaboration has been submitted')
    task=api('/api/tasks/'+json.loads(REQUEST.read_text())['id'])
    collaboration=task.get('collaboration') or {}
    summary={'task_id':task['id'],'status':task['status'],'stage':task['stage'],
             'phase':collaboration.get('phase'),'finished_providers':list(collaboration.get('steps',{})),
             'three_provider_acceptance':task['status']=='completed' and set(collaboration.get('steps',{}))=={'claude','codex','gemini'}}
    REPORT.write_text(json.dumps({'summary':summary,'task':task},ensure_ascii=False,indent=2)+'\n'); REPORT.chmod(0o600)
    print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__': main()
