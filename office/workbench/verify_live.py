#!/usr/bin/env python3
"""Real private-source/Docker acceptance, with explicitly simulated provider phase output.

Run as neighbor. Does not use production Office data or call a model. Three-provider acceptance is separate.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import office
from workbench_control import Workbench

def main():
    config=json.loads(Path('/home/neighbor/neighbor-office/workbench.json').read_text())
    output=Path(config['storage'])/'acceptance'
    output.mkdir(mode=0o700,exist_ok=True)
    data=output/('run-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()))
    store=office.Store(data/'data')
    wb=Workbench(store,config)
    app=office.Office(store,None,workbench=wb)
    task=app.command({'id':str(uuid.uuid4()),'prompt':'Infrastructure acceptance only: run the official website checks; agent phases are simulated.','executor':'collaborate'})['task']
    claimed=store.claim_hands()
    identity={'task_id':task['id'],'lease':claimed['lease']}
    def call(action,**body): return wb.call(action,{**identity,**body})
    started=time.monotonic()
    try:
        prepared=call('prepare')
        print('Private source ready',prepared['source_rev'],len(prepared['files']),flush=True)
        call('phase',phase='claude',mode='start')
        call('phase',phase='claude',mode='complete',output={'content':'SIMULATED phase for infrastructure acceptance; no Claude request.'})
        call('open_run')
        run=wb.get_run(store.get(task['id']))
        info=json.loads(wb.provider.call('inspect',run['sandbox_id']).stdout)[0]
        assert info['Mounts']==[] and info['HostConfig']['Privileged'] is False
        assert info['Config']['User']=='10001:10001'
        assert info['HostConfig']['Memory']==2*1024**3
        assert info['HostConfig']['NanoCpus']==2_000_000_000
        assert info['HostConfig']['PidsLimit']==512
        assert wb.provider.call('exec',run['sandbox_id'],'id','-u').stdout.strip()==b'10001'
        call('tool',tool='run_checks',args={})
        while time.monotonic()-started<700:
            status=call('tool',tool='run_status',args={})
            print('Docker check',status['state'],round(time.monotonic()-started),flush=True)
            if status['state'] in ('published','failed','unknown','lost','rejected','cancelled','interrupted'): break
            time.sleep(15)
        evidence=call('evidence')
        result={'kind':'real private source + rootless Docker; provider phases simulated',
                'source_rev':prepared['source_rev'],'state':evidence['state'],'exit_code':evidence['exit_code'],
                'seconds':evidence['seconds'],'network_reachable':wb.reachable,'mounts':info['Mounts'],
                'memory':info['HostConfig']['Memory'],'nano_cpus':info['HostConfig']['NanoCpus'],
                'pids':info['HostConfig']['PidsLimit'],'log':evidence['log'],
                'three_provider_acceptance':'NOT RUN: requires owner authentication'}
        (output/'latest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='log'},ensure_ascii=False),flush=True)
        if evidence['state']!='published':
            print(evidence['log'][-7000:],flush=True)
            raise SystemExit(1)
    finally:
        try:
            run=wb.get_run(store.get(task['id'])); wb.runs.cleanup(run['run_id'])
        except Exception: pass

if __name__=='__main__': main()
