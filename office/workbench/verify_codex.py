#!/usr/bin/env python3
"""Real Codex/MCP/Docker probe in an isolated Office database. Claude is explicitly simulated; no Gemini call."""
import argparse
import json
import os
import pwd
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE=Path(__file__).resolve()

def server(probe,sock):
    sys.path.insert(0,'/home/neighbor/neighbor-office/current')
    import office
    from workbench_control import Workbench
    config=json.loads(Path('/home/neighbor/neighbor-office/workbench.json').read_text())
    root=Path(config['storage'])/'acceptance'/('codex-'+probe)
    store=office.Store(root/'data'); wb=Workbench(store,config)
    app=office.Office(store,None,workbench=wb)
    task=app.command({'id':probe,'executor':'collaborate','prompt':'【獨立 Codex 實機驗證】只執行官網既定檢查，不修改檔案；Claude 階段明確為測試模擬，不呼叫 Gemini。'})['task']
    api=office.Server(0,app,worker_socket=sock,local_socket=Path('/run/user/1000')/('neko-probe-'+probe[:8])/'o.sock')
    stopped=threading.Event()
    signal.signal(signal.SIGTERM,lambda *_:stopped.set())
    threading.Thread(target=api.serve_forever,daemon=True).start()
    try: stopped.wait()
    finally:
        store.cancel(task['id']); wb.sweep(); api.shutdown(); api.server_close()

def worker(probe,sock):
    sys.path.insert(0,'/opt/neko-hands')
    from worker import Office
    from team_worker import Team,Proxy,CONTENT_SCHEMA
    from types import SimpleNamespace
    client=Office(sock)
    status,body=client.post('/api/worker/claim',{})
    assert status==200 and body.get('task'),body
    task=body['task']; identity={'task_id':task['id'],'lease':task['lease']}
    root=Path('/home/neko-hands/workbench/probes')/probe
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    team=Team(SimpleNamespace(office=client,workspace_root=root/'workspace',codex_home=Path('/home/neko-hands/.codex'),
                              codex='/opt/neko-hands/codex/codex-x86_64-unknown-linux-musl',stopping=False))
    folder=team.root/'codex-work'; folder.mkdir(mode=0o700,parents=True)
    prepared=team.post('prepare',identity)
    team.post('phase',identity,phase='claude',mode='start')
    team.post('phase',identity,phase='claude',mode='complete',output={'content':'SIMULATED infrastructure precondition only. No Claude model call. Run the configured checks without edits.'})
    team.post('open_run',identity)
    with tempfile.TemporaryDirectory(prefix='neko-probe-',dir='/run/user/1001') as temp:
        path=Path(temp)/'p.sock'; proxy=Proxy(path,client,identity)
        threading.Thread(target=proxy.serve_forever,daemon=True).start()
        try:
            output=team.phase('codex',identity,'你是獨立實機測試中的 Codex。用 project MCP 呼叫 run_checks 一次，再用 run_status 等到 published。不要修改檔案，不要呼叫主機 shell 或其他工具。根據實際結果用繁體中文回報退出碼與測試項目；沒有證據不得宣稱通過。來源 commit：'+prepared['source_rev'],folder,CONTENT_SCHEMA,path)
        finally: proxy.shutdown(); proxy.server_close()
    evidence=team.post('evidence',identity)
    result={'kind':'REAL Codex + project MCP + private source + Docker; Claude simulated, Gemini NOT RUN',
            'source_rev':prepared['source_rev'],'codex_actual':True,'output':output,'evidence':evidence}
    (root/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'codex_actual':True,'state':evidence['state'],'exit_code':evidence['exit_code'],'seconds':evidence['seconds'],'result':str(root/'result.json')},ensure_ascii=False),flush=True)
    assert evidence['state']=='published' and evidence['exit_code']==0

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--role',choices=['server','worker']); parser.add_argument('--probe'); parser.add_argument('--socket',type=Path); args=parser.parse_args()
    if args.role=='server': return server(args.probe,args.socket)
    if args.role=='worker': return worker(args.probe,args.socket)
    if os.geteuid()!=0: raise SystemExit('Use root to start the two separate account processes')
    probe=str(uuid.uuid4()); sock=Path('/srv/neko-office')/('probe-'+probe[:8]+'.sock')
    def account(name):
        info=pwd.getpwnam(name)
        env={'HOME':info.pw_dir,'PATH':'/usr/bin:/bin','LANG':'C.UTF-8','XDG_RUNTIME_DIR':'/run/user/'+str(info.pw_uid),
             'DBUS_SESSION_BUS_ADDRESS':'unix:path=/run/user/'+str(info.pw_uid)+'/bus'}
        if name=='neighbor': env['DOCKER_HOST']='unix:///run/user/1000/docker.sock'
        return {'user':info.pw_uid,'group':info.pw_gid,'extra_groups':os.getgrouplist(name,info.pw_gid),'env':env,'cwd':'/opt/neko-workbench'}
    control=subprocess.Popen(['/usr/bin/python3','-I',str(HERE),'--role','server','--probe',probe,'--socket',str(sock)],
                             start_new_session=True,**account('neighbor'))
    try:
        for _ in range(40):
            if sock.exists(): break
            if control.poll() is not None: raise SystemExit('Probe control did not start')
            time.sleep(.25)
        subprocess.run(['/usr/bin/python3','-I',str(HERE),'--role','worker','--probe',probe,'--socket',str(sock)],
                       check=True,timeout=1000,**account('neko-hands'))
    finally:
        try: os.killpg(control.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: control.wait(timeout=10)
        except subprocess.TimeoutExpired: os.killpg(control.pid,signal.SIGKILL); control.wait()

if __name__=='__main__': main()
