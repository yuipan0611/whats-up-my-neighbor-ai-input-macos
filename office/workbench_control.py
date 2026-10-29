"""Office side of the three-provider workbench. Owns source access and Docker; agents never do."""
from __future__ import annotations
import json
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import threading
import time

import runner
import runner_docker

PHASES = ('claude', 'codex', 'gemini')
CHECK_COMMAND = ['sh', '-c', 'npm ci --no-audit --no-fund && npx --no-install tsc --noEmit && npm run check:content && npm run test:content && node scripts/run-with-ts.mjs --test scripts/browser-speech.test.mjs && npm run build']
SCHEMA = '''CREATE TABLE IF NOT EXISTS workbench_tasks (
task_id TEXT NOT NULL, attempt INTEGER NOT NULL, phase TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'new',
source_rev TEXT NOT NULL DEFAULT '', outputs TEXT NOT NULL DEFAULT '{}', updated TEXT NOT NULL,
PRIMARY KEY(task_id,attempt));'''

FILE_OP = r'''
import json, pathlib, sys
op, args = sys.argv[1], json.loads(sys.argv[2])
root = pathlib.Path('/work')
path = root / args.get('path', '')
if not path.resolve().is_relative_to(root) or any(p.startswith('.') and p in ('.git','.ssh','.codex','.claude','.gemini') for p in path.parts):
    raise SystemExit('refused')
if op == 'read_file':
    if path.stat().st_size > 65536: raise SystemExit('file too large')
    print(json.dumps({'text':path.read_text()}))
elif op == 'write_file':
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(args['text'])
    print(json.dumps({'written':True}))
elif op == 'delete_file':
    if path.is_file(): path.unlink()
    print(json.dumps({'deleted':True}))
'''

class PrivateCheckouts(runner.Checkouts):
    def __init__(self, root, key, known_hosts):
        super().__init__(root, remote='git@github.com:{repo}.git')
        # These paths come only from the owner-installed configuration, never the worker or model.
        import shlex
        self.ssh = 'ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=' + shlex.quote(str(known_hosts)) + ' -i ' + shlex.quote(str(key))

    def git(self, *args, timeout=300):
        env = {'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'GIT_CONFIG_NOSYSTEM': '1',
               'GIT_TERMINAL_PROMPT': '0', 'GIT_SSH_COMMAND': self.ssh}
        out = subprocess.run(['git', '-c', 'credential.helper=', '-c', 'core.hooksPath=/dev/null', *args],
                             capture_output=True, timeout=timeout, env=env)
        if out.returncode:
            raise runner.RunRefused('repo_access', '尚未取得官網的唯讀授權，或 GitHub 暫時連不上；工作已保留。')
        return out.stdout.decode().strip()

class Workbench:
    def __init__(self, store, config, provider=None, checkouts=None):
        self.store, self.config = store, config
        self.provider = provider or runner_docker.DockerRunner(config['image'], network='neko-runner')
        self.runs = runner.RunService(store, self.provider)
        self.checkouts = checkouts or PrivateCheckouts(Path(config['storage']) / 'checkouts', config['key'], config['known_hosts'])
        self.lock = threading.RLock()
        self.executing = set()
        self.threads = {}
        self.probe_at, self.reachable = 0, ['not_checked']
        with store.connect() as c:
            c.executescript(SCHEMA)
            c.execute("UPDATE workbench_tasks SET state='unknown',updated=? WHERE state='running'", (runner.now(),))
        self.runs.recover(lambda run: self.checkouts.target(run['task_id']))

    def guard(self, body):
        if not isinstance(body, dict) or not isinstance(body.get('task_id'), str) or not isinstance(body.get('lease'), str):
            raise runner.RunRefused('bad_request', '需要有效的任務與 lease。')
        with self.store.connect() as c:
            self.store._active_hands(c, body['task_id'], body['lease'])
            task = dict(c.execute('SELECT * FROM tasks WHERE id=?', (body['task_id'],)).fetchone())
            if task.get('workflow') != 'collaborate':
                raise runner.RunRefused('not_workbench', '這件工作不是三家協作。')
            c.execute('INSERT OR IGNORE INTO workbench_tasks(task_id,attempt,updated) VALUES(?,?,?)',
                      (task['id'], task['attempts'], runner.now()))
        self.runs.guard({'task_id': task['id'], 'attempt': task['attempts']}, body['lease'])
        return task

    def record(self, task):
        with self.store.connect() as c:
            return dict(c.execute('SELECT * FROM workbench_tasks WHERE task_id=? AND attempt=?', (task['id'],task['attempts'])).fetchone())

    def update(self, task, **fields):
        fields['updated'] = runner.now()
        with self.store.connect() as c:
            c.execute('UPDATE workbench_tasks SET ' + ','.join(k+'=?' for k in fields) + ' WHERE task_id=? AND attempt=?',
                      [*fields.values(), task['id'],task['attempts']])

    def safe_network(self):
        if self.reachable or time.monotonic()-self.probe_at > 600:
            self.reachable = self.provider.self_check() if hasattr(self.provider,'self_check') else []
            self.probe_at = time.monotonic()
        if self.reachable:
            raise runner.RunRefused('sandbox_unsafe', '執行環境尚未通過主機隔離檢查，沒有開始。')

    def inputs(self, worktree):
        paths = subprocess.run(['git','-C',str(worktree),'ls-files','-z'], capture_output=True, check=True).stdout.decode().split('\0')
        paths = [p for p in paths if p and not runner.excluded(p) and '.vscode' not in Path(p).parts]
        runner.select_inputs(worktree, paths)
        return paths

    def call(self, action, body):
        task = self.guard(body)
        if action == 'prepare':
            self.safe_network()
            worktree, _, rev = self.checkouts.prepare(task['id'], self.config['repo'], self.config.get('base','main'))
            paths = self.inputs(worktree)
            old = self.record(task)
            if old['source_rev'] and old['source_rev'] != rev:
                raise runner.RunRefused('source_changed', '來源版本已改變，請先核對已有結果。')
            self.update(task, source_rev=rev)
            context = {}
            for p in ('README.md','AGENTS.md','package.json','tsconfig.json'):
                if p in paths:
                    context[p] = (worktree/p).read_text()[:24000]
            return {'repo':self.config['repo'],'source_rev':rev,'files':paths,'context':context,'check_command':CHECK_COMMAND}
        if action == 'phase':
            return self.phase(task,body)
        if action == 'progress':
            row=self.record(task)
            return {'phase':row['phase'],'state':row['state'],'source_rev':row['source_rev'],
                    'outputs':json.loads(row['outputs'])}
        if action == 'open_run':
            self.safe_network()
            if 'claude' not in json.loads(self.record(task)['outputs']):
                raise runner.RunRefused('phase_order','先完成 Claude 的方案。')
            worktree = self.checkouts.worktree(task['id'])
            rev = self.record(task)['source_rev']
            run = self.runs.start(task['id'], body['lease'], worktree, self.inputs(worktree), rev,
                                  limits={'usd_per_second':0})
            return self.view(run)
        if action == 'tool':
            return self.tool(task,body)
        if action == 'evidence':
            run = self.get_run(task)
            view = self.view(run)
            folder = self.runs.runs_dir(run)/'staging'
            view['truncated']={}
            for key, file, limit in [('log','log.txt',64000),('patch','result.patch',64000)]:
                p = folder/file
                view[key] = p.read_bytes()[:limit].decode('utf-8','replace') if p.is_file() else ''
                view['truncated'][key]=p.is_file() and p.stat().st_size>limit
            view['outputs'] = json.loads(self.record(task)['outputs'])
            return view
        if action == 'artifact':
            run = self.get_run(task)
            path = self.runs.runs_dir(run)/'staging'/'result.patch'
            data = path.read_bytes() if path.is_file() else b''
            return {'patch_base64':base64.b64encode(data).decode(),'sha256':hashlib.sha256(data).hexdigest()}
        if action == 'finish':
            row = self.record(task)
            outputs = json.loads(row['outputs'])
            run = self.get_run(task)
            complete = set(outputs) == set(PHASES) and outputs['gemini'].get('approved') is True and run['state']=='published'
            content = '\n\n'.join('## '+name+'\n\n'+outputs[name].get('content','') for name in PHASES if name in outputs)
            content += '\n\n來源版本：`'+row['source_rev']+'`\n\n測試狀態：'+run['state']+'（退出碼 '+str(run['exit_code'])+'）'
            log = self.runs.runs_dir(run)/'staging'/'log.txt'
            content += '\n\n## 執行證據\n\n指令：\n```sh\n'+CHECK_COMMAND[-1]+'\n```\n\n耗時：'+str(run['seconds'])+' 秒\n\n```text\n'+(log.read_bytes()[-6000:].decode('utf-8','replace') if log.is_file() else '沒有已保存的測試紀錄。')+'\n```'
            self.update(task,state='completed' if complete else 'needs_input')
            return self.store.hands_complete(task['id'],body['lease'],'completed' if complete else 'incomplete',content,
                                             '' if complete else '三家檢查尚未全部通過；請查看已有成果。')
        raise runner.RunRefused('unknown_action','沒有這個協作操作。')

    def phase(self, task, body):
        phase, mode = body.get('phase'),body.get('mode')
        if phase not in PHASES or mode not in ('start','complete'):
            raise runner.RunRefused('bad_phase','階段不正確。')
        with self.lock:
            row = self.record(task)
            outputs = json.loads(row['outputs'])
            if phase in outputs:
                return {'state':'completed','output':outputs[phase]}
            if list(outputs) != list(PHASES[:PHASES.index(phase)]):
                raise runner.RunRefused('phase_order','協作階段順序不正確。')
            if mode == 'start':
                if row['state'] in ('running','unknown'):
                    raise runner.RunRefused('phase_unknown','上一段執行結果尚未核對，不會自動重做。')
                self.update(task,phase=phase,state='running')
                self.store.note(task['id'],'tool',{'claude':'Claude 正在整理方案。','codex':'Codex 正在處理專案複本。','gemini':'Gemini 正在檢查成果。'}[phase])
                return {'state':'started'}
            output = body.get('output')
            if row['phase'] != phase or row['state'] != 'running' or not isinstance(output,dict) or not isinstance(output.get('content'),str) or not output['content'].strip() or len(json.dumps(output).encode())>40000:
                raise runner.RunRefused('bad_output','沒有有效的完整階段成果。')
            if phase == 'gemini' and not isinstance(output.get('approved'),bool):
                raise runner.RunRefused('bad_output','Gemini 需要明確的檢查結論。')
            outputs[phase] = output
            self.update(task,outputs=json.dumps(outputs,ensure_ascii=False),state='ready')
            return {'state':'completed','output':output}

    def get_run(self, task):
        with self.store.connect() as c:
            row = c.execute('SELECT * FROM runner_runs WHERE task_id=? AND attempt=?',(task['id'],task['attempts'])).fetchone()
        if row is None:
            raise runner.RunRefused('no_run','這次尚未建立執行環境。')
        return dict(row)

    @staticmethod
    def view(run):
        return {k:run.get(k) for k in ('run_id','state','detail','exit_code','seconds')}

    def tool(self, task, body):
        name, args = body.get('tool'), body.get('args',{})
        if not isinstance(args,dict) or name not in ('list_files','read_file','write_file','delete_file','run_checks','run_status'):
            raise runner.RunRefused('bad_tool','沒有這個專案工具。')
        with self.lock:
            run = self.get_run(task)
            self.runs.guard(run,body['lease'])
            if name == 'run_status':
                view = self.view(run)
                log = self.runs.runs_dir(run)/'staging'/'log.txt'
                view['log'] = log.read_bytes()[:16000].decode('utf-8','replace') if log.is_file() else ''
                return view
            if run['state'] != 'ready' or run['run_id'] in self.executing:
                raise runner.RunRefused('run_started','測試已開始或已結束，不能再改寫這次輸入。')
            if name == 'run_checks':
                if args:
                    raise runner.RunRefused('bad_tool','官網檢查不接受額外參數。')
                self.executing.add(run['run_id'])
                thread = threading.Thread(target=self.drive,args=(task,run,body['lease']),daemon=True)
                self.threads[run['run_id']] = thread
                thread.start()
                return {'run_id':run['run_id'],'state':'executing'}
            if name == 'list_files':
                return {'files':json.loads(run['manifest'])}
            path = args.get('path')
            if not runner.safe_relative(path) or runner.excluded(path) or path.startswith('.github/workflows/') or '.vscode' in Path(path).parts:
                raise runner.RunRefused('bad_path','這個路徑不提供給 Agent。')
            if set(args) != ({'path','text'} if name=='write_file' else {'path'}):
                raise runner.RunRefused('bad_tool','檔案工具參數不正確。')
            if name == 'write_file' and (not isinstance(args['text'],str) or len(args['text'].encode())>1_000_000):
                raise runner.RunRefused('too_large','單次修改超過容量。')
            out = self.provider.call('exec',run['sandbox_id'],'python3','-c',FILE_OP,name,json.dumps(args))
            return json.loads(out.stdout)

    def drive(self, task, run, lease):
        try:
            got = self.runs.execute(run['run_id'],lease,CHECK_COMMAND)
            if got['state']=='collected' and got['exit_code']==0:
                got = self.runs.verify(run['run_id'],allow_empty=True)
            if got['state']=='verified':
                self.runs.publish(run['run_id'],lease,self.checkouts.target(task['id']))
        except (runner.RunRefused,runner.RunnerError):
            pass
        except Exception:
            # An unclassified failure may happen after execution began. Never offer the same run again.
            with self.lock:
                if self.runs.run(run['run_id'])['state'] not in runner.TERMINAL:
                    self.runs.set(run['run_id'],'unknown',detail='internal_unknown')
            self.runs.cleanup(run['run_id'])
        finally:
            with self.lock:
                self.executing.discard(run['run_id'])

    def sweep(self):
        self.runs.sweep()
