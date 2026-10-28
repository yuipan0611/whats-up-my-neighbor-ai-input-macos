#!/usr/bin/env python3
"""Root-only, idle Office cutover with an additive database migration and automatic code rollback."""
import argparse
from datetime import datetime, timezone
import http.client
import json
import os
import re
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import time

ROOT=Path('/home/neighbor/neighbor-office')
UNIT=Path('/home/neighbor/.config/systemd/user/neighbor-office.service')
HELPERS_ROOT=Path('/opt/neko-hands')
HELPERS=('worker.py','browser_adapter.py','team_worker.py','project_tools.py','review_gate.py','review_policy.py','verify_google_policy.py')

def run(*args):
    return subprocess.run(args,check=True,capture_output=True,text=True)

def service(action,worker=False):
    if worker: return run('systemctl',action,'neko-hands-worker.service')
    return run('runuser','-u','neighbor','--','env','XDG_RUNTIME_DIR=/run/user/1000',
               'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus','systemctl','--user',action,'neighbor-office.service')

def flags(values):
    with sqlite3.connect(ROOT/'data/office.sqlite3') as c:
        c.executemany('UPDATE settings SET value=? WHERE key=?',[(v,k) for k,v in values.items()])

def health():
    class Unix(http.client.HTTPConnection):
        def connect(self):
            self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            self.sock.settimeout(10); self.sock.connect(str(ROOT/'run/office.sock'))
    connection=Unix('127.0.0.1:18421',timeout=10)
    try:
        connection.request('GET','/api/health',headers={'Host':'127.0.0.1:18421'})
        response=connection.getresponse()
        if response.status!=200: raise RuntimeError('Office health HTTP '+str(response.status))
        return json.loads(response.read())
    finally: connection.close()

def wait_health(version):
    for _ in range(20):
        try:
            result=health()
            if result['version']==version and result['worker_running']: return result
        except (OSError,ValueError,http.client.HTTPException): pass
        time.sleep(1)
    raise RuntimeError('Office did not become healthy')

def atomic_copy(source,target):
    temporary=target.with_name(target.name+'.workbench-new')
    shutil.copy2(source,temporary); temporary.chmod(0o644)
    temporary.replace(target)

def point(target):
    temporary=ROOT/'current.workbench-new'
    if temporary.is_symlink(): temporary.unlink()
    temporary.symlink_to(target); temporary.replace(ROOT/'current')

def restore(backup):
    info=json.loads((backup/'deployment.json').read_text())
    # An old worker must never interpret a queued collaboration as an ordinary hands job.
    with sqlite3.connect(ROOT/'data/office.sqlite3') as c:
        columns={r[1] for r in c.execute('PRAGMA table_info(tasks)')}
        if 'workflow' in columns:
            c.execute("UPDATE tasks SET status='interrupted',stage='新版協作已回復舊版，請核對已有結果後接續。' "
                      "WHERE workflow='collaborate' AND status IN ('queued','planning','running','saving')")
    service('stop',True); service('stop')
    atomic_copy(backup/'neighbor-office.service',UNIT)
    run('chown','neighbor:neighbor',str(UNIT))
    for name in HELPERS:
        old=backup/'helpers'/name
        if old.exists(): atomic_copy(old,HELPERS_ROOT/name)
    point(info['old_target'])
    run('runuser','-u','neighbor','--','env','XDG_RUNTIME_DIR=/run/user/1000','systemctl','--user','daemon-reload')
    flags(info['flags']); service('start'); service('start',True)
    result=wait_health(info['old_version'])
    print(json.dumps({'rolled_back':True,'version':result['version'],'backup':str(backup)}))

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--release',type=Path)
    parser.add_argument('--rollback',type=Path)
    args=parser.parse_args()
    if os.geteuid()!=0: raise SystemExit('Root is required')
    if args.rollback: return restore(args.rollback)
    release=args.release.resolve()
    if release.parent!=ROOT/'releases' or not (release/'office.py').is_file():
        raise SystemExit('Expected a staged Office release')
    version=re.search(r"^VERSION = '([A-Za-z0-9.+-]+)'$",(release/'office.py').read_text(),re.M)
    if not version: raise SystemExit('Release version is missing')
    version=version.group(1)
    old=health()
    if old['version']==version: raise SystemExit('Version already deployed; inspect rather than replay')
    backup=ROOT/'backups'/('workbench-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    backup.mkdir(mode=0o700,parents=True)
    with sqlite3.connect(ROOT/'data/office.sqlite3',timeout=10) as c:
        c.execute('BEGIN IMMEDIATE')
        busy=c.execute("SELECT count(*) FROM tasks WHERE status IN ('queued','planning','running','saving')").fetchone()[0]
        if busy: raise SystemExit('Office has pending work; deployment deferred without changing it')
        previous=dict(c.execute("SELECT key,value FROM settings WHERE key IN ('paused','hands_locked')"))
        c.execute("UPDATE settings SET value='1' WHERE key IN ('paused','hands_locked')")
    info={'old_target':os.readlink(ROOT/'current'),'old_version':old['version'],'flags':previous,'release':str(release)}
    (backup/'deployment.json').write_text(json.dumps(info,indent=2)+'\n')
    shutil.copy2(UNIT,backup/'neighbor-office.service')
    (backup/'helpers').mkdir(mode=0o700)
    for name in HELPERS:
        p=HELPERS_ROOT/name
        if p.exists(): shutil.copy2(p,backup/'helpers'/name)
    with sqlite3.connect(ROOT/'data/office.sqlite3') as source, sqlite3.connect(backup/'office.sqlite3') as target:
        source.backup(target)
    (backup/'office.sqlite3').chmod(0o600)
    try:
        # Recheck after the claim lock reaches the old worker; never stop an active job.
        time.sleep(1)
        with sqlite3.connect(ROOT/'data/office.sqlite3') as c:
            busy=c.execute("SELECT count(*) FROM tasks WHERE status IN ('planning','running','saving')").fetchone()[0]
        if busy:
            flags(previous)
            raise SystemExit('A job began before the claim lock; deployment deferred')
        service('stop',True); service('stop')
        for name in HELPERS: atomic_copy(release/'hands'/name,HELPERS_ROOT/name)
        unit=(backup/'neighbor-office.service').read_text()
        if '--workbench-config ' not in unit:
            unit=unit.replace('--worker-socket /srv/neko-office/worker.sock','--worker-socket /srv/neko-office/worker.sock --workbench-config %h/neighbor-office/workbench.json')
        if 'Environment=DOCKER_HOST=' not in unit:
            unit=unit.replace('[Service]\n','[Service]\nEnvironment=DOCKER_HOST=unix:///run/user/1000/docker.sock\n')
        UNIT.write_text(unit); UNIT.chmod(0o600); run('chown','neighbor:neighbor',str(UNIT))
        point(str(release))
        run('runuser','-u','neighbor','--','env','XDG_RUNTIME_DIR=/run/user/1000','systemctl','--user','daemon-reload')
        service('start'); result=wait_health(version)
        if not result['workbench']['enabled']: raise RuntimeError('Workbench is not enabled')
        service('start',True); service('is-active',True)
        flags(previous)
        (backup/'success.json').write_text(json.dumps({'version':result['version'],'workbench':True})+'\n')
        print(json.dumps({'deployed':True,'version':result['version'],'backup':str(backup),'release':str(release)}))
    except Exception:
        restore(backup)
        raise

if __name__=='__main__': main()
