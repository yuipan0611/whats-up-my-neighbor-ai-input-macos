"""G3: the restricted browser adapter and the worker's broker mode, end to end with a fake Codex.

The fake Codex acts as the MCP client: it starts the real adapter, lists tools and calls them.
The office and broker are real; the browser is the fake from test_browser_actions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

from test_office import app, FakeModel
from test_browser_actions import FakeBrowser, ba

HANDS = Path(__file__).parents[1] / 'hands'
spec = importlib.util.spec_from_file_location('hands_worker_g3', HANDS / 'worker.py')
worker_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker_mod)
spec = importlib.util.spec_from_file_location('hands_adapter_g3', HANDS / 'browser_adapter.py')
adapter_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter_mod)

FAKE_CODEX = r'''#!{python}
import json, os, subprocess, sys
args = sys.argv[1:]
output, cwd = args[args.index('--output-last-message') + 1], args[args.index('--cd') + 1]
config = {{}}
for i, a in enumerate(args):
    if a == '-c' and args[i + 1].startswith('mcp_servers.browser.'):
        key, _, value = args[i + 1][len('mcp_servers.browser.'):].partition('=')
        config[key] = value
sys.stdin.read()
server = subprocess.Popen([json.loads(config['command'])] + json.loads(config['args']), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(i, method, params=None):
    server.stdin.write(json.dumps({{'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params or {{}}}}) + '\n'); server.stdin.flush()
    return json.loads(server.stdout.readline())
rpc(1, 'initialize', {{'protocolVersion': '2025-06-18'}})
tools = [t['name'] for t in rpc(2, 'tools/list')['result']['tools']]
calls = {{}}
calls['open'] = rpc(3, 'tools/call', {{'name': 'open_url', 'arguments': {{'url': 'https://example.test/docs'}}}})['result']
snap = json.loads(rpc(4, 'tools/call', {{'name': 'observe_page', 'arguments': {{}}}})['result']['content'][0]['text'])
calls['button'] = rpc(5, 'tools/call', {{'name': 'click', 'arguments': {{'snapshot_id': snap['snapshot_id'], 'target_ref': 'e2'}}}})['result']
calls['raw'] = rpc(6, 'tools/call', {{'name': 'evaluate_script', 'arguments': {{'function': '() => 1'}}}})['result']
calls['js_url'] = rpc(7, 'tools/call', {{'name': 'open_url', 'arguments': {{'url': 'javascript:alert(1)'}}}})['result']
server.stdin.close(); server.wait(10)
with open(os.path.join(cwd, 'seen.json'), 'w') as f:
    json.dump({{'tools': tools, 'calls': calls, 'config': config, 'env': dict(os.environ)}}, f, ensure_ascii=False)
with open(output, 'w') as f:
    json.dump({{'outcome': 'incomplete', 'content': '刪除帳號那一步要你親手按。', 'reason': '需要使用者'}}, f)
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.store = app.Store(root / 'data')
        self.browser = FakeBrowser()
        self.office = app.Office(self.store, FakeModel(), broker=ba.Broker(self.store, self.browser))
        self.worker_socket = root / 'w' / 'worker.sock'
        self.server = app.Server(0, self.office, worker_socket=self.worker_socket)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        fake = root / 'fake-codex'
        fake.write_text(FAKE_CODEX.format(python=sys.executable)); fake.chmod(0o755)
        self.workspace = root / 'ws'
        self.worker = worker_mod.Worker(worker_mod.Office(self.worker_socket), fake, root / 'codex-home', self.workspace,
                                        browser=('/usr/bin/false', ['raw-browser-must-not-be-used']), adapter=HANDS / 'browser_adapter.py')
        self.worker.HEARTBEAT_SECONDS, self.worker.FLUSH_SECONDS = 0.3, 0.1

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def run_task(self):
        task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：看一個測試頁', 'executor': 'hands'})['task']
        status, body = self.worker.office.post('/api/worker/claim', {})
        self.assertEqual(body['task']['browser_mode'], 'broker')
        return task, body['task'], self.worker.handle(body['task'])

    def test_agent_gets_only_the_fixed_tools_through_the_broker(self):
        task, claimed, outcome = self.run_task()
        seen = json.loads((self.workspace / task['id'] / 'attempt-1' / 'seen.json').read_text())
        self.assertEqual(seen['tools'], ['observe_page', 'read_page', 'screenshot', 'open_url', 'click', 'type_text'])
        self.assertFalse(seen['calls']['open']['isError'])
        self.assertIn('使用者親手做', seen['calls']['button']['content'][0]['text'])
        self.assertTrue(seen['calls']['raw']['isError'])
        self.assertIn('scheme_not_allowed', seen['calls']['js_url']['content'][0]['text'])
        self.assertEqual([c[0] for c in self.browser.calls], ['navigate', 'take_snapshot'])  # the button never reached the browser
        dumped = json.dumps(seen, ensure_ascii=False)
        self.assertNotIn(claimed['lease'], dumped)
        self.assertNotIn('raw-browser-must-not-be-used', dumped)
        self.assertIn('browser_adapter.py', seen['config']['args'])
        with self.store.connect() as c:
            decisions = [r[0] for r in c.execute("SELECT decision FROM browser_audit_events WHERE task_id=? AND event_type='decision' ORDER BY seq", (task['id'],))]
        self.assertEqual(decisions, ['allow', 'allow', 'needs_human', 'deny'])
        saved = self.store.get(task['id'])
        self.assertEqual((outcome, saved['status']), ('incomplete', 'incomplete'))

    def test_broker_mode_without_adapter_fails_and_never_starts_the_agent(self):
        self.worker.adapter = None
        task, claimed, outcome = self.run_task()
        self.assertEqual(outcome, 'failed: broker mode without adapter')
        saved = self.store.get(task['id'])
        self.assertEqual(saved['status'], 'failed')
        self.assertIn('受限工具沒有設定', saved['stage'])
        self.assertFalse((self.workspace / task['id'] / 'attempt-1' / 'seen.json').exists())
        self.assertEqual(self.browser.calls, [])

    def test_broker_arguments_never_name_the_raw_tool(self):
        args = ' '.join(self.worker.arguments(Path('/w'), Path('/s'), Path('/o'), '/tmp/x/b.sock'))
        self.assertIn('browser_adapter.py', args)
        self.assertNotIn('raw-browser-must-not-be-used', args)
        legacy = ' '.join(self.worker.arguments(Path('/w'), Path('/s'), Path('/o')))
        self.assertIn('raw-browser-must-not-be-used', legacy)

    def test_proxy_owns_the_identity_and_the_epoch(self):
        task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務', 'executor': 'hands'})['task']
        claimed = self.worker.office.post('/api/worker/claim', {})[1]['task']
        path = Path(self.temp.name) / 'p' / 'b.sock'
        path.parent.mkdir(mode=0o700)
        proxy = worker_mod.BrokerProxy(str(path), self.worker.office, task['id'], claimed['lease'])
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        try:
            call = lambda **extra: adapter_mod.proxy_call(str(path), {'tool': 'read_text', 'action_id': str(uuid.uuid4()), 'args': {}, **extra})
            reply = call()
            self.assertEqual(reply['status'], 200)
            self.assertNotIn(claimed['lease'], json.dumps(reply))  # same UID (D13): the agent can reach this socket directly
            for extra in ({'control_epoch': 999}, {'task_id': 'someone-else'}, {'lease': 'guess'}):
                self.assertEqual(call(**extra)['status'], 400, extra)
        finally:
            proxy.shutdown(); proxy.server_close()
        self.assertEqual([c[0] for c in self.browser.calls], ['read_text'])

    def test_adapter_without_proxy_fails_closed(self):
        proc = subprocess.run([sys.executable, '-I', str(HANDS / 'browser_adapter.py'), '--socket', '/nonexistent/b.sock'], text=True,
                              input='\n'.join(json.dumps(m) for m in (
                                  {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'read_page', 'arguments': {}}},
                                  {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'click', 'arguments': {'extra': 1}}})) + '\n',
                              capture_output=True, timeout=30)
        replies = [json.loads(l) for l in proc.stdout.splitlines()]
        self.assertTrue(all(r['result']['isError'] for r in replies))
        self.assertIn('連不上', replies[0]['result']['content'][0]['text'])
        self.assertIn('參數不對', replies[1]['result']['content'][0]['text'])  # rejected before any proxy call


if __name__ == '__main__':
    unittest.main()
