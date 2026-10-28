"""Collaboration contracts against a real SQLite/git checkout and a simulated Docker provider."""
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch
from test_office import app,FakeModel,local_request
import runner
from workbench_control import Workbench

class WorkbenchTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        remote=self.root/'remotes'/'owner'/'repo'; remote.mkdir(parents=True)
        def git(*args): subprocess.run(['git','-C',str(remote),*args],capture_output=True,check=True)
        git('init','-q','-b','main'); git('config','user.name','test'); git('config','user.email','test@example.invalid')
        (remote/'README.md').write_text('old\n'); (remote/'.env').write_text('CANARY=fictional-only\n')
        git('add','-A'); git('-c','commit.gpgsign=false','commit','-q','-m','base')
        self.store=app.Store(self.root/'data'); self.fake=runner.FakeRunner()
        self.config={'repo':'owner/repo','base':'main','storage':str(self.root),'key':'unused','known_hosts':'unused','image':'fake'}
        self.checkouts=runner.Checkouts(self.root/'checkouts',remote=str(self.root/'remotes')+'/{repo}')
        self.wb=Workbench(self.store,self.config,self.fake,self.checkouts)
        self.office=app.Office(self.store,FakeModel(),workbench=self.wb)
        self.task=self.office.command({'id':str(uuid.uuid4()),'prompt':'測試專案','executor':'collaborate'})['task']
        self.claim=self.store.claim_hands(); self.identity={'task_id':self.task['id'],'lease':self.claim['lease']}

    def call(self,action,**body): return self.wb.call(action,{**self.identity,**body})
    def phase(self,name,**output):
        self.call('phase',phase=name,mode='start')
        return self.call('phase',phase=name,mode='complete',output={'content':name+' result',**output})
    def start(self):
        self.call('prepare'); self.phase('claude'); return self.call('open_run')
    def execute(self):
        self.call('tool',tool='run_checks',args={})
        for thread in self.wb.threads.values(): thread.join(10)
        return self.call('evidence')

    def test_ordered_three_phases_complete_only_with_test_evidence_and_approval(self):
        self.start(); self.call('phase',phase='codex',mode='start'); evidence=self.execute()
        self.assertEqual(evidence['state'],'published',evidence)
        self.assertIn('-old',evidence['patch'])
        self.call('phase',phase='codex',mode='complete',output={'content':'implemented'})
        self.phase('gemini',approved=True)
        self.assertEqual(self.call('finish')['status'],'completed')
        self.assertEqual((self.checkouts.worktree(self.task['id'])/'README.md').read_text(),'new\n')
        self.assertEqual(len([c for c in self.fake.calls if c[0]=='execute']),1)

    def test_checks_without_file_changes_are_successful_without_fake_commit(self):
        self.fake.result['patch']=b''
        self.start(); before=self.checkouts.git('-C',str(self.checkouts.worktree(self.task['id'])),'rev-parse','HEAD')
        evidence=self.execute()
        after=self.checkouts.git('-C',str(self.checkouts.worktree(self.task['id'])),'rev-parse','HEAD')
        self.assertEqual((evidence['state'],before),( 'published',after))
        self.assertEqual(evidence['detail'],'no_changes')

    def test_duplicate_request_cannot_change_the_workflow(self):
        with self.assertRaises(app.OfficeError):
            self.office.command({'id':self.task['id'],'prompt':'測試專案','executor':'hands'})
        replay=self.office.command({'id':self.task['id'],'prompt':'測試專案','executor':'collaborate'})
        self.assertEqual(replay['task']['id'],self.task['id'])

    def test_unclassified_execution_failure_is_not_retried(self):
        self.start()
        with patch.object(self.wb.runs,'execute',side_effect=ValueError('synthetic unknown result')):
            self.assertEqual(self.execute()['state'],'unknown')
        with self.assertRaises(runner.RunRefused): self.call('tool',tool='run_checks',args={})
        self.assertTrue(all(box['state']=='gone' for box in self.fake.boxes.values()))

    def test_phase_start_answer_lost_is_never_replayed(self):
        self.call('prepare'); self.call('phase',phase='claude',mode='start')
        new=Workbench(self.store,self.config,self.fake,self.checkouts)
        with self.assertRaises(runner.RunRefused) as error:
            new.call('phase',{**self.identity,'phase':'claude','mode':'start'})
        self.assertEqual(error.exception.reason,'phase_unknown')

    def test_completed_phase_is_returned_without_repeating_provider(self):
        self.call('prepare'); original=self.phase('claude')
        replay=self.call('phase',phase='claude',mode='start')
        self.assertEqual(original,replay)

    def test_lease_expiry_and_cancel_do_not_requeue_collaboration(self):
        self.start()
        self.store.expire_hands(time.time()+self.store.HANDS_LEASE+5)
        self.assertEqual(self.store.get(self.task['id'])['status'],'interrupted')
        self.wb.sweep()
        self.assertTrue(all(box['state']=='gone' for box in self.fake.boxes.values()))
        self.assertIsNone(self.store.claim_hands())

    def test_no_approval_or_failed_test_cannot_claim_completed(self):
        self.start(); self.phase('codex'); self.fake.result['exit_code']=3
        self.assertEqual(self.execute()['state'],'failed')
        self.phase('gemini',approved=True)
        self.assertEqual(self.call('finish')['status'],'incomplete')

    def test_secrets_and_invalid_paths_do_not_reach_the_container(self):
        self.start()
        self.assertNotIn('.env',next(iter(self.fake.boxes.values()))['files'])
        for path in ('../x','/etc/passwd','.env','.git/config','.github/workflows/x.yml'):
            with self.assertRaises(runner.RunRefused): self.call('tool',tool='read_file',args={'path':path})

    def test_worker_socket_only_and_stale_lease_are_rejected(self):
        sock=self.root/'run'/'o.sock'; worker=self.root/'worker'/'w.sock'
        server=app.Server(0,self.office,local_socket=sock,worker_socket=worker)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        request=json.dumps({**self.identity,'lease':'wrong'}).encode()
        status,_,_=local_request(worker,'/api/worker/workbench/prepare',request,{'Content-Type':'application/json'})
        self.assertEqual(status,409)
        status,_,_=local_request(sock,'/api/worker/workbench/prepare',request,{'Content-Type':'application/json'})
        self.assertIn(status,(403,404))

    def test_unsafe_network_is_rejected_before_checkout_or_container(self):
        self.fake.self_check=lambda:['host_address']
        with self.assertRaises(runner.RunRefused) as error: self.call('prepare')
        self.assertEqual(error.exception.reason,'sandbox_unsafe')
        self.assertEqual(self.fake.boxes,{})
        self.assertFalse(self.checkouts.worktree(self.task['id']).exists())

    def test_worker_runs_all_three_stages_and_delivers_verified_artifact(self):
        import sys
        sys.path.insert(0,str(Path(__file__).parents[1]/'hands'))
        from team_worker import Team
        def post(path,body):
            return 200,self.wb.call(path.rsplit('/',1)[-1],body)
        worker=SimpleNamespace(office=SimpleNamespace(post=post),workspace_root=self.root/'worker'/'workspace',
                               codex_home=self.root/'login',codex='codex',stopping=False)
        team=Team(worker); team.root.mkdir(parents=True)
        team.claude=self.root/'claude'; team.claude.touch()
        team.google=self.root/'agy'; team.google.touch()
        seen=[]
        def stage(name,*args):
            seen.append(name)
            if name=='codex': self.execute()
            return {'content':name+' synthetic output',**({'approved':True} if name=='gemini' else {})}
        team.run=stage
        real_subprocess_run=subprocess.run
        def preflight(args,**kwargs):
            if args[0] in (str(team.claude),str(team.google)): return SimpleNamespace(returncode=0)
            return real_subprocess_run(args,**kwargs)
        with patch('team_worker.subprocess.run',side_effect=preflight), patch('team_worker.review_policy.verified',return_value=True), \
             patch.dict('os.environ',{'XDG_RUNTIME_DIR':'/nonexistent/runtime-for-test'}):
            result=team.handle(self.claim)
        self.assertEqual(result,'collaboration finished')
        self.assertEqual(seen,['claude','codex','gemini'])
        self.assertEqual(self.store.get(self.task['id'])['status'],'completed')
        self.assertIn(b'-old',(team.root/'results'/(self.task['id']+'.patch')).read_bytes())
        self.assertEqual(len([call for call in self.fake.calls if call[0]=='execute']),1)
        sock=self.root/'run'/'artifacts.sock'
        server=app.Server(0,self.office,local_socket=sock)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        status,data,_=local_request(sock,'/api/tasks/'+self.task['id']+'/patch')
        self.assertEqual(status,200); self.assertIn(b'-old',data)
        status,data,_=local_request(sock,'/api/tasks/'+self.task['id']+'/test-log')
        self.assertEqual(status,200); self.assertEqual(data,b'ok\n')

if __name__=='__main__': unittest.main()
