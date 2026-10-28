"""Opt-in Linux Docker checks. Synthetic repositories only; cleanup is fenced to each test's run IDs."""
import json
import os
import subprocess
import threading
import time
import unittest
from test_runner import RunnerBase
import runner
from runner_docker import DockerRunner

@unittest.skipUnless(os.environ.get('NEKO_DOCKER_TEST')=='1','requires real isolated Linux Docker')
class RealDockerTests(RunnerBase):
    def setUp(self):
        super().setUp()
        self.provider=DockerRunner('neko-runner:workbench-v1')
        self.service=runner.RunService(self.store,self.provider)

    def tearDown(self):
        with self.store.connect() as c: rows=list(c.execute('SELECT * FROM runner_runs'))
        for row in rows:
            found=row['sandbox_id'] or self.provider.find(row['run_id'])
            if found: self.provider.destroy(found)
        super().tearDown()

    def inside(self,run,*args): return self.provider.call('exec',run['sandbox_id'],*args)

    def test_full_run_publishes_once(self):
        run=self.service.execute(self.start()['run_id'],self.lease,['sh','-c','echo new > README.md; echo built'])
        self.assertEqual(run['exit_code'],0)
        repo,target=self.repo(); self.service.verify(run['run_id'])
        self.service.publish(run['run_id'],self.lease,target); self.service.publish(run['run_id'],self.lease,target)
        self.assertEqual(self.commits(repo),2)
        self.assertEqual((repo/'README.md').read_text(),'new\n')

    def test_no_mounts_secrets_socket_or_privilege_and_resource_limits(self):
        os.environ['NEKO_CANARY_SECRET']='fictional-canary-321'; self.addCleanup(os.environ.pop,'NEKO_CANARY_SECRET',None)
        run=self.start(); info=json.loads(self.provider.call('inspect',run['sandbox_id']).stdout)[0]; host=info['HostConfig']
        self.assertEqual(info['Mounts'],[]); self.assertFalse(host['Privileged'])
        self.assertEqual(host['CapDrop'],['ALL']); self.assertIn('no-new-privileges',host['SecurityOpt'])
        self.assertEqual((host['Memory'],host['NanoCpus'],host['PidsLimit']),(2147483648,2000000000,512))
        self.assertEqual(self.inside(run,'id','-u').stdout.strip(),b'10001')
        self.assertNotIn(b'fictional-canary',self.inside(run,'env').stdout)
        self.inside(run,'sh','-c','test ! -e /var/run/docker.sock && test ! -e /home/neighbor/neighbor-office/data/office.sqlite3 && test ! -e /work/.env')

    def test_timeout_stops_and_cleans(self):
        run=self.start(limits={'seconds':1}); start=time.monotonic()
        run=self.service.execute(run['run_id'],self.lease,['sleep','60'])
        self.assertLess(time.monotonic()-start,15)
        self.assertEqual((run['state'],run['detail'],run['cleanup']),('failed','time_limit','done'))

    def test_failure_keeps_log(self):
        run=self.service.execute(self.start()['run_id'],self.lease,['sh','-c','echo broken >&2; exit 3'])
        self.assertEqual((run['state'],run['exit_code']),('failed',3))
        self.assertEqual((self.service.runs_dir(run)/'staging'/'log.txt').read_text(),'broken\n')

    def test_literal_command_is_not_evaluated_as_shell(self):
        run=self.start(); self.provider.execute(run['sandbox_id'],['echo','x; touch /tmp/pwned'],10)
        self.inside(run,'sh','-c','test ! -e /tmp/pwned')

    def test_outbound_package_registry_is_available(self):
        self.inside(self.start(),'python3','-c','import urllib.request; urllib.request.urlopen("https://registry.npmjs.org/next",timeout=20).close()')

    def test_cancel_stops_live_execution(self):
        run=self.start(); thread=threading.Thread(target=self.service.execute,args=(run['run_id'],self.lease,['sleep','60']))
        thread.start()
        for _ in range(100):
            if self.service.run(run['run_id'])['state']=='running': break
            time.sleep(.05)
        self.store.cancel(self.task['id']); self.service.sweep(); thread.join(10)
        self.assertFalse(thread.is_alive()); self.assertEqual(self.service.run(run['run_id'])['state'],'cancelled')
        self.assertEqual(self.provider.status(run['sandbox_id']),'gone')

    def test_lost_create_answer_is_recovered_without_duplicate(self):
        create=self.provider.create
        def lost(*args): create(*args); raise runner.RunnerUnknown('lost answer')
        self.provider.create=lost; run=self.start(); self.provider.create=create
        self.assertEqual(run['state'],'create_unknown')
        runner.RunService(self.store,self.provider).recover()
        self.assertEqual(self.service.run(run['run_id'])['state'],'interrupted')
        self.assertIsNone(self.provider.find(run['run_id']))

    def test_host_gateway_and_metadata_are_blocked(self):
        self.assertEqual(self.provider.self_check(),[])

if __name__=='__main__': unittest.main()
