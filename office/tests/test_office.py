import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location('office_app', Path(__file__).parents[1] / 'office.py')
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class FakeModel:
    model = 'test-model'
    def __init__(self, action='write', result='測試成果', question='', source='', hook=None, truncated=False):
        self.action, self.result, self.question, self.source = action, result, question, source
        self.hook, self.truncated = hook, truncated
        self.prompts = []
    def generate(self, system, prompt, check, progress, schema=None, limit=512):
        check()
        self.prompts.append(prompt)
        if self.hook:
            self.hook(check)
        check()
        if schema:
            return json.dumps({'action': self.action, 'question': self.question, **({'source': self.source} if self.source else {})}), {'done_reason':'stop'}
        return self.result, {'done_reason':'length' if self.truncated else 'stop', 'eval_count':3}
    def health(self):
        return {'ready':True, 'name':self.model}


class OfficeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'data'
        self.store = app.Store(self.root)
    def tearDown(self):
        self.temp.cleanup()
    def submit(self, model=None, prompt='寫一句問候', source=''):
        model = model or FakeModel()
        office = app.Office(self.store, model)
        task = office.command({'id':str(uuid.uuid4()), 'prompt':prompt, 'source':source})['task']
        return office, task
    def run_task(self, office):
        task = self.store.claim()
        office.execute(task)
        return self.store.get(task['id'])
    def test_result_is_written_and_independently_readable(self):
        office, task = self.submit()
        done = self.run_task(office)
        self.assertEqual(done['status'], 'completed')
        self.assertEqual((self.root / done['artifact']).read_text(), '測試成果')
        self.assertEqual([e['status'] for e in done['events']], ['queued','planning','running','running','saving','completed'])
        recovered = app.Store(self.root)
        self.assertEqual(recovered.get(task['id'])['result'], '測試成果')
    def test_same_request_does_not_repeat(self):
        office, task = self.submit()
        office.command({'id':task['id'], 'prompt':'寫一句問候', 'source':''})
        self.assertEqual(len(self.store.list()), 1)
        with self.assertRaises(app.OfficeError):
            office.command({'id':task['id'], 'prompt':'其他內容'})
    def test_cancel_during_model_prevents_artifact(self):
        office, task = self.submit()
        office.model.hook=lambda check: (self.store.cancel(task['id']), check())
        with self.assertRaises(app.Cancelled):
            self.run_task(office)
        self.assertEqual(self.store.get(task['id'])['status'], 'cancelled')
        self.assertFalse((self.root / 'tasks' / task['id']).exists())
    def test_cancelled_task_cannot_be_completed(self):
        office, task = self.submit()
        self.store.cancel(task['id'])
        with self.assertRaises(app.Cancelled):
            self.store.change(task['id'],'completed','錯誤')
        self.assertEqual(self.store.get(task['id'])['status'],'cancelled')
    def test_restart_keeps_queue_and_marks_active_interrupted(self):
        office, first = self.submit()
        second = office.command({'id':str(uuid.uuid4()), 'prompt':'寫一句晚安'})['task']
        self.store.claim()
        app.Office(app.Store(self.root), FakeModel())
        self.assertEqual(self.store.get(first['id'])['status'], 'interrupted')
        self.assertEqual(self.store.get(second['id'])['status'], 'queued')
    def test_pause_survives_restart_and_resume_keeps_queued(self):
        office, task = self.submit()
        office.command({'prompt':'先停一下'})
        fresh = app.Office(app.Store(self.root), FakeModel())
        self.assertTrue(fresh.store.paused())
        self.assertIsNone(fresh.store.claim())
        fresh.command({'prompt':'繼續工作'})
        self.assertEqual(fresh.store.claim()['id'], task['id'])
    def test_controls_do_not_need_model(self):
        office, _ = self.submit()
        office.model.generate = lambda *_: self.fail('controls must not call model')
        self.assertEqual(office.command({'prompt':'做到哪了？'})['control'], 'status')
        self.assertEqual(office.command({'prompt':'先停一下'})['control'], 'paused')
    def test_source_snapshot_survives_source_change(self):
        self.store.upload('筆記.md', '阿明週五交稿。')
        model = FakeModel(action='summarize')
        office, task = self.submit(model, '整理筆記', '筆記.md')
        (self.root / 'inbox/筆記.md').write_text('來源已改寫')
        self.run_task(office)
        self.assertIn('阿明週五交稿', model.prompts[-1])
        self.assertNotIn('來源已改寫', model.prompts[-1])
        (self.root / 'inbox/筆記.md').unlink()
        again=office.command({'id':task['id'],'prompt':'整理筆記','source':'筆記.md'})['task']
        self.assertEqual(again['status'],'completed')
    def test_upload_rejects_overwrite_traversal_and_symlink(self):
        for name in ('../secret.txt','/etc/passwd','a\\b.txt','.hidden.txt','a.html'):
            with self.assertRaises(app.OfficeError):
                self.store.upload(name,'x')
        self.store.upload('ok.txt','first')
        with self.assertRaises(app.OfficeError):
            self.store.upload('ok.txt','second')
        (self.root/'inbox/link.txt').symlink_to(self.root/'inbox/ok.txt')
        with self.assertRaises(app.OfficeError):
            self.store.read_source('link.txt')
    def test_model_cannot_add_unapproved_file_access_fields(self):
        office, task=self.submit(FakeModel(action='summarize',source='../../etc/passwd'))
        with self.assertRaises(app.OfficeError):
            self.run_task(office)
        self.assertIsNone(self.store.get(task['id'])['artifact'])
    def test_live_research_is_pending_even_if_model_suggests_write(self):
        office,task=self.submit(FakeModel(action='write'),'研究今年各家VPS價格並寫報告')
        done=self.run_task(office)
        self.assertEqual(done['status'],'needs_external')
        self.assertIn('尚未接通',done['result'])
    def test_missing_summary_input_is_rejected_even_if_model_suggests_write(self):
        office,task=self.submit(FakeModel(action='write'),'幫我整理這份筆記')
        done=self.run_task(office)
        self.assertEqual(done['status'],'needs_input')
        self.assertIsNone(done['artifact'])
    def test_url_summary_waits_for_external_fetch(self):
        office,task=self.submit(FakeModel(action='write'),'幫我摘要這個網址：https://example.org/article')
        self.assertEqual(self.run_task(office)['status'],'needs_external')
    def test_research_motivation_is_local_prose(self):
        office,task=self.submit(FakeModel(action='write'),'幫我寫一段研究動機')
        self.assertEqual(self.run_task(office)['status'],'completed')
    def test_external_work_remains_pending_with_brief(self):
        office, task=self.submit(FakeModel(action='external'),'研究今天新聞')
        done=self.run_task(office)
        self.assertEqual(done['status'],'needs_external')
        self.assertTrue((self.root/done['artifact']).is_file())
        self.assertIn('尚未接通',done['result'])
    def test_clarification_is_not_fabricated_result(self):
        office, task=self.submit(FakeModel(action='clarify',question='請提供筆記。'),'整理這份筆記')
        done=self.run_task(office)
        self.assertEqual(done['status'],'needs_input')
        self.assertEqual(done['stage'],'請提供筆記。')
        self.assertIsNone(done['result'])
    def test_truncated_output_is_partial(self):
        office, task=self.submit(FakeModel(truncated=True))
        done=self.run_task(office)
        self.assertEqual(done['status'],'incomplete')
        self.assertTrue(done['artifact'].endswith('partial.md'))
    def test_summary_without_source_or_pasted_text_does_not_generate(self):
        model=FakeModel(action='summarize')
        office,task=self.submit(model,'幫我整理這份筆記')
        done=self.run_task(office)
        self.assertEqual(done['status'],'needs_input')
        self.assertEqual(len(model.prompts),1)
        self.assertIsNone(done['result'])
    def test_second_service_cannot_recover_first_services_tasks(self):
        office,task=self.submit()
        self.store.set_paused(True)
        command=[sys.executable,'-I',str(Path(__file__).parents[1]/'office.py'),'--data',str(self.root),'--port','0']
        first=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertIn('listening',first.stdout.readline())
            self.store.change(task['id'],'running','simulated live task')
            second=subprocess.run(command,capture_output=True,text=True,timeout=5)
            self.assertNotEqual(second.returncode,0)
            self.assertIn('already running',second.stderr)
            self.assertEqual(self.store.get(task['id'])['status'],'running')
        finally:
            first.terminate();first.communicate(timeout=6)
    def test_input_budget_rejected_before_network(self):
        model=app.Ollama()
        with self.assertRaises(app.OfficeError) as e:
            model.generate('x'*7001,'',lambda:None,lambda n:None)
        self.assertEqual(e.exception.code,413)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.store=app.Store(Path(self.temp.name)/'data')
        self.office=app.Office(self.store,FakeModel())
        self.server=app.Server(0,self.office)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.url='http://127.0.0.1:'+str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join()
        self.temp.cleanup()
    def request(self,path,body=None,headers=None):
        req=urllib.request.Request(self.url+path,None if body is None else json.dumps(body).encode(),headers or {})
        try:
            with urllib.request.urlopen(req,timeout=2) as r:
                return r.status,r.read(),dict(r.headers)
        except urllib.error.HTTPError as e:
            with e:
                return e.code,e.read(),dict(e.headers)
    def test_cross_origin_and_rebinding_rejected(self):
        self.assertEqual(self.request('/api/tasks',headers={'Host':'evil.example'})[0],421)
        self.assertEqual(self.request('/api/tasks',headers={'Origin':'https://evil.example'})[0],403)
        self.assertEqual(self.request('/api/tasks',headers={'Sec-Fetch-Site':'cross-site'})[0],403)
    def test_write_requires_token_and_json(self):
        body={'id':str(uuid.uuid4()),'prompt':'hello'}
        self.assertEqual(self.request('/api/command',body,{'Content-Type':'application/json'})[0],403)
        headers={'Content-Type':'application/json','X-Office-Token':self.server.token}
        self.assertEqual(self.request('/api/command',body,headers)[0],202)
        self.assertEqual(self.request('/api/command',body,headers)[0],202)
        self.assertEqual(len(self.store.list()),1)
    def test_real_http_result_and_download(self):
        body={'id':str(uuid.uuid4()),'prompt':'hello'}
        headers={'Content-Type':'application/json','X-Office-Token':self.server.token}
        self.request('/api/command',body,headers)
        self.office.execute(self.store.claim())
        code,data,_=self.request('/api/tasks/'+body['id'])
        self.assertEqual(json.loads(data)['status'],'completed')
        code,data,headers=self.request('/api/tasks/'+body['id']+'/download')
        self.assertEqual(code,200);self.assertEqual(data.decode(),'測試成果')
        self.assertIn('attachment',headers['Content-Disposition'])
    def test_static_is_script_safe_and_no_cache(self):
        code,html,headers=self.request('/')
        self.assertEqual(code,200)
        self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        js=(Path(__file__).parents[1]/'static/app.js').read_text()
        self.assertNotIn('innerHTML',js)
        self.assertNotIn('eval(',js)


if __name__=='__main__':
    unittest.main(verbosity=2)
