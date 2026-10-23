"""The hands worker against a real office over the worker socket, with a fake Codex (H3).

The fake reads its mode from the prompt (MODE:ok, MODE:sleep, MODE:crash, MODE:env, MODE:flood)."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_office import app, FakeModel

spec = importlib.util.spec_from_file_location('hands_worker', Path(__file__).parents[1] / 'hands' / 'worker.py')
worker_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker_mod)

FAKE_CODEX = r'''#!{python}
import json, os, re, subprocess, sys, time
args = sys.argv[1:]
output = args[args.index('--output-last-message') + 1]
cwd = args[args.index('--cd') + 1]
prompt = sys.stdin.read()
mode = re.search(r'MODE:(\w+)', prompt).group(1)
def emit(kind, **item):
    print(json.dumps({{'type': 'item.completed', 'item': {{'type': kind, **item}}}}), flush=True)
def final(outcome, content, reason=''):
    with open(output, 'w') as f:
        json.dump({{'outcome': outcome, 'content': content, 'reason': reason}}, f)
if mode == 'ok':
    emit('reasoning', text='先想一下')
    emit('command_execution', command='ls -la')
    emit('mcp_tool_call', server='browser', tool='navigate_page', arguments={{'url': 'https://example.com'}})
    emit('agent_message', text='打開了範例網頁')
    final('completed', '# done')
elif mode == 'sleep':
    emit('agent_message', text='做到一半')
    child = subprocess.Popen(['sleep', '60'])
    with open(os.path.join(cwd, 'child.pid'), 'w') as f:
        f.write(str(child.pid))
    time.sleep(60)
elif mode == 'crash':
    emit('agent_message', text='快要失敗了')
    sys.exit(3)
elif mode == 'env':
    with open(os.path.join(cwd, 'seen.json'), 'w') as f:
        json.dump({{'env': dict(os.environ), 'args': args, 'prompt': prompt}}, f)
    final('completed', 'env dumped')
elif mode == 'flood':  # one burst, then exit: most steps are still waiting when the agent is done
    sys.stdout.write(''.join(json.dumps({{'type': 'item.completed', 'item': {{'type': 'agent_message', 'text': f'第 {{i}} 步'}}}}) + '\n' for i in range(45)))
    sys.stdout.flush()
    final('completed', 'flooded')
'''


def uid():
    return str(uuid.uuid4())


def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:  # a zombie still answers signal 0; it is dead for our purposes
        with open(f'/proc/{pid}/stat') as f:
            return f.read().split(') ')[1][0] != 'Z'
    except OSError:
        return True


class WorkerBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.store = app.Store(root / 'data')
        self.office = app.Office(self.store, FakeModel())
        self.worker_socket = root / 'w' / 'worker.sock'
        self.server = app.Server(0, self.office, worker_socket=self.worker_socket)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        fake = root / 'fake-codex'
        fake.write_text(FAKE_CODEX.format(python=sys.executable))
        fake.chmod(0o755)
        self.workspace = root / 'workspace'
        self.worker = worker_mod.Worker(worker_mod.Office(self.worker_socket), fake, root / 'codex-home', self.workspace,
                                        root / 'from-cat', browser=('/usr/bin/node', ['/opt/mcp/server.js', '--browser-url=http://127.0.0.1:9222']))
        self.worker.HEARTBEAT_SECONDS, self.worker.FLUSH_SECONDS, self.worker.POLL_SECONDS = 0.3, 0.1, 0.1

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def submit(self, mode, prompt='做一件事'):
        return self.office.command({'id': uid(), 'prompt': f'{prompt} MODE:{mode}', 'executor': 'hands'})['task']

    def run_one(self):
        status, body = self.worker.office.post('/api/worker/claim', {})
        self.assertEqual(status, 200)
        return body['task'], self.worker.handle(body['task'])

    def steps(self, task_id):
        return [(e['status'], e['message']) for e in self.store.get(task_id)['events'] if e['status'] in ('thinking', 'message', 'tool')]


class CompletionTests(WorkerBase):
    def test_completes_and_records_steps(self):
        task = self.submit('ok')
        _, outcome = self.run_one()
        self.assertEqual(outcome, 'completed')
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result']), ('completed', '# done'))
        self.assertEqual(self.steps(task['id']), [('thinking', '先想一下'), ('tool', '執行：ls -la'),
                                                  ('tool', '瀏覽器：navigate_page https://example.com'), ('message', '打開了範例網頁')])

    def test_crash_is_reported_as_failed_with_steps_kept(self):
        task = self.submit('crash')
        _, outcome = self.run_one()
        saved = self.store.get(task['id'])
        self.assertEqual((outcome, saved['status']), ('failed', 'failed'))
        self.assertIn('結束碼 3', saved['stage'])
        self.assertEqual(saved['result'], '快要失敗了')

    def test_many_steps_all_arrive(self):
        self.worker.BATCH, self.worker.FLUSH_SECONDS = 5, 100
        task = self.submit('flood')
        self.run_one()
        self.assertEqual([m for _, m in self.steps(task['id'])], [f'第 {i} 步' for i in range(45)])
        self.assertEqual(self.store.get(task['id'])['result'], 'flooded')

    def test_serve_loop_claims_runs_and_stops(self):
        task = self.submit('ok')
        loop = threading.Thread(target=self.worker.serve)
        loop.start()
        try:
            self.assertTrue(wait_for(lambda: self.store.get(task['id'])['status'] == 'completed'))
        finally:
            self.worker.stopping = True
            loop.join(timeout=5)
        self.assertFalse(loop.is_alive())


class StopTests(WorkerBase):
    def start(self, mode='sleep'):
        task = self.submit(mode)
        status, body = self.worker.office.post('/api/worker/claim', {})
        result = {}
        runner = threading.Thread(target=lambda: result.setdefault('outcome', self.worker.handle(body['task'])))
        runner.start()
        pid_file = self.workspace / task['id'] / 'attempt-1' / 'child.pid'
        self.assertTrue(wait_for(pid_file.exists))
        self.assertTrue(wait_for(lambda: pid_file.read_text().strip() != ''))
        return task, runner, result, int(pid_file.read_text())

    def test_cancel_kills_the_agent_and_its_children(self):
        task, runner, result, child = self.start()
        self.store.cancel(task['id'])
        runner.join(timeout=10)
        self.assertEqual(result['outcome'], 'stopped by the office')
        self.assertTrue(wait_for(lambda: not alive(child), 5))
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result']), ('cancelled', None))

    def test_take_back_switch_stops_the_agent(self):
        task, runner, result, child = self.start()
        self.store.set_hands_locked(True)
        runner.join(timeout=10)
        self.assertEqual(result['outcome'], 'stopped by the office')
        self.assertTrue(wait_for(lambda: not alive(child), 5))

    def test_superseded_attempt_stops_without_handing_in(self):
        task, runner, result, child = self.start()
        with self.store.connect() as c:
            c.execute('UPDATE tasks SET heartbeat=0 WHERE id=?', (task['id'],))
        self.store.expire_hands()
        second = self.store.claim_hands()
        self.assertEqual(second['attempts'], 2)
        runner.join(timeout=10)
        self.assertEqual(result['outcome'], 'stopped by the office')
        self.assertTrue(wait_for(lambda: not alive(child), 5))
        saved = self.store.get(task['id'])
        self.assertEqual((saved['status'], saved['result']), ('running', None))

    def test_time_limit_keeps_the_partial_work(self):
        self.worker.TASK_SECONDS = 1.5
        task, runner, result, child = self.start()
        runner.join(timeout=10)
        saved = self.store.get(task['id'])
        self.assertEqual((result['outcome'], saved['status'], saved['result']), ('incomplete', 'incomplete', '做到一半'))
        self.assertIn('30 分鐘', saved['stage'])
        self.assertTrue(wait_for(lambda: not alive(child), 5))


class BoundaryTests(WorkerBase):
    def test_lease_and_office_socket_never_reach_the_agent(self):
        task = self.submit('env')
        claimed, outcome = self.run_one()
        self.assertEqual(outcome, 'completed')
        seen = json.loads((self.workspace / task['id'] / 'attempt-1' / 'seen.json').read_text())
        dumped = json.dumps(seen, ensure_ascii=False)
        self.assertNotIn(claimed['lease'], dumped)
        self.assertNotIn(str(self.worker_socket), dumped)
        self.assertEqual(seen['env']['CODEX_HOME'], str(Path(self.temp.name) / 'codex-home'))
        self.assertEqual(set(self.worker.environment()) - {'HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'CODEX_HOME', 'TERM'}, set())
        self.assertIn('MODE:env', seen['prompt'])
        self.assertFalse(any(str(p).endswith('final.json') for p in (self.workspace / task['id']).rglob('*')))

    def test_codex_arguments(self):
        args = self.worker.arguments(Path('/w/t/attempt-1'), Path('/r/schema.json'), Path('/r/final.json'))
        joined = ' '.join(args)
        for expected in ('--sandbox workspace-write', 'sandbox_workspace_write.network_access=true', '--add-dir ' + str(self.worker.handoff_dir),
                         'mcp_servers.browser.command="/usr/bin/node"',
                         'mcp_servers.browser.args=["/opt/mcp/server.js", "--browser-url=http://127.0.0.1:9222"]',
                         'mcp_servers.browser.default_tools_approval_mode="approve"',
                         '--disable browser_use', '--disable computer_use', '--ignore-user-config'):
            self.assertIn(expected, joined)
        self.assertNotIn('dangerously', joined)
        self.assertNotIn('skip_host_skill_discovery', joined)
        self.assertEqual(args[-1], '-')


if __name__ == '__main__':
    unittest.main()
