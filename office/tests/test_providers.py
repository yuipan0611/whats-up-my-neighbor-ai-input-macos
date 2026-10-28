"""Claude as a brain executor (ADR-003 P1), against a scripted stand-in for the Claude Code CLI."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid
from test_office import app, FakeModel, local_request


def uid():
    return str(uuid.uuid4())


# Reads its script from the config dir the office gives it, records how it was started, then replays the script.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
home = pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
script = json.loads((home / 'script.json').read_text())
if sys.argv[1:3] == ['auth', 'status']:
    print(json.dumps({'loggedIn': script['logged_in'], 'authMethod': 'claude.ai'}))
    sys.exit(0 if script['logged_in'] else 1)
(home / 'run.json').write_text(json.dumps({'argv': sys.argv[1:], 'env': dict(os.environ), 'stdin': sys.stdin.read(),
                                           'cwd': os.getcwd()}, ensure_ascii=False))
for step in script['steps']:
    if isinstance(step, dict) and 'sleep' in step:
        time.sleep(step['sleep'])
    else:
        print(step if isinstance(step, str) else json.dumps(step, ensure_ascii=False), flush=True)
sys.exit(script['exit'])
'''
ANSWER = {'kind': 'completed', 'content': '三家方案比較表', 'next_step': '人工核對價格'}


def init(tools=('StructuredOutput', 'WebFetch', 'WebSearch'), mcp=()):
    return {'type': 'system', 'subtype': 'init', 'tools': list(tools), 'mcp_servers': list(mcp)}


def assistant(*blocks, error=None):
    event = {'type': 'assistant', 'message': {'role': 'assistant', 'content': list(blocks)}}
    if error:
        event['error'] = error
    return event


def result(structured=ANSWER, is_error=False, subtype='success'):
    return {'type': 'result', 'subtype': subtype, 'is_error': is_error, 'num_turns': 3,
            'usage': {'input_tokens': 120, 'output_tokens': 40}, 'structured_output': structured}


HAPPY = [init(),
         assistant({'type': 'thinking', 'thinking': '先確認要比較哪三家。'}),
         assistant({'type': 'text', 'text': '我先查官方價格頁。'}),
         assistant({'type': 'tool_use', 'name': 'WebSearch', 'input': {'query': 'Hostinger KVM 2 price'}}),
         assistant({'type': 'tool_use', 'name': 'WebFetch', 'input': {'url': 'https://example.com/pricing', 'prompt': '價格'}}),
         assistant({'type': 'tool_use', 'name': 'StructuredOutput', 'input': ANSWER}),
         result()]


class ClaudeAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = app.Store(Path(self.temp.name) / 'data')
        self.agent = app.ClaudeAgent(Path(self.temp.name) / 'runtime')
        self.agent.binary.parent.mkdir()
        self.agent.binary.write_text(FAKE_CLAUDE)
        self.agent.binary.chmod(0o700)

    def script(self, steps, logged_in=True, exit=0):
        (self.agent.home / 'script.json').write_text(json.dumps({'steps': steps, 'logged_in': logged_in, 'exit': exit},
                                                                ensure_ascii=False))
        self.agent._health = None

    def run_task(self, check=lambda: None, progress=None, notes=None):
        task = {'id': uid(), 'prompt': '比較三家 VPS 價格', 'source': '', 'source_snapshot': None, 'context_snapshot': '選取的交接'}
        return self.agent.run(task, check, progress or (lambda text: None),
                              note=(lambda kind, text: notes.append((kind, text))) if notes is not None else None)

    def recorded(self):
        return json.loads((self.agent.home / 'run.json').read_text())

    def test_completed_answer_notes_and_metrics(self):
        self.script(HAPPY)
        notes = []
        answer, metrics = self.run_task(notes=notes)
        self.assertEqual(answer, ANSWER)
        self.assertEqual(notes, [('thinking', '先確認要比較哪三家。'), ('message', '我先查官方價格頁。'),
                                 ('tool', '搜尋：Hostinger KVM 2 price'), ('tool', '讀取：https://example.com/pricing')])
        self.assertEqual(metrics['provider'], 'claude')
        self.assertEqual(metrics['usage'], {'input_tokens': 120, 'output_tokens': 40})
        self.assertEqual(metrics['event_types'], {'thinking': 1, 'text': 1, 'WebSearch': 1, 'WebFetch': 1, 'StructuredOutput': 1})

    def test_runs_with_only_web_tools_in_its_own_config_dir(self):
        os.environ['ANTHROPIC_API_KEY'] = 'must-not-reach-the-cli'
        self.addCleanup(os.environ.pop, 'ANTHROPIC_API_KEY')
        self.script(HAPPY)
        self.run_task()
        run = self.recorded()
        argv, env = run['argv'], run['env']
        def value(flag):
            return argv[argv.index(flag) + 1]
        self.assertIn('-p', argv)
        self.assertEqual(value('--tools'), 'WebSearch,WebFetch')
        self.assertEqual(value('--allowedTools'), 'WebSearch,WebFetch')
        self.assertEqual(value('--permission-mode'), 'dontAsk')
        self.assertEqual(value('--setting-sources'), '')
        self.assertEqual(value('--output-format'), 'stream-json')
        for flag in ('--strict-mcp-config', '--no-session-persistence', '--disable-slash-commands'):
            self.assertIn(flag, argv)
        self.assertNotIn('--mcp-config', argv)
        self.assertEqual(json.loads(value('--json-schema')), app.CliAgent.schema)
        self.assertEqual(value('--system-prompt'), app.CliAgent.BRIEF)
        self.assertEqual(env['CLAUDE_CONFIG_DIR'], str(self.agent.home))
        self.assertEqual(env['DISABLE_AUTOUPDATER'], '1')
        self.assertNotIn('ANTHROPIC_API_KEY', env)
        self.assertEqual(Path(run['cwd']).resolve(), self.agent.workspace.resolve())
        # The task travels on stdin as data, apart from the instructions.
        self.assertEqual(json.loads(run['stdin'])['交辦'], '比較三家 VPS 價格')
        self.assertEqual(json.loads(run['stdin'])['明確選取的交接與生活紀錄'], '選取的交接')
        self.assertEqual(list(self.agent.workspace.iterdir()), [])

    def test_needs_input_is_returned_as_is(self):
        ask = {'kind': 'needs_input', 'content': '要比較哪一個方案？', 'next_step': ''}
        self.script([init(), result(ask)])
        self.assertEqual(self.run_task()[0], ask)

    def test_not_installed_or_logged_out_never_starts_a_run(self):
        self.script(HAPPY, logged_in=False)
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertEqual(str(e.exception), app.ClaudeAgent.LOGIN)
        self.assertFalse((self.agent.home / 'run.json').exists())
        self.agent.binary.unlink()
        self.agent._health = None
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertIn('還沒裝進辦公室', str(e.exception))
        self.assertEqual(self.agent.health(), {'name': 'Claude', 'installed': False, 'authenticated': False})

    def test_expired_login_and_used_up_quota_ask_the_owner(self):
        # A logged-out run still reports subtype "success"; only is_error and the error code tell.
        for code, expected in (('authentication_failed', app.ClaudeAgent.LOGIN), ('rate_limit', app.ClaudeAgent.QUOTA),
                               ('billing_error', app.ClaudeAgent.QUOTA)):
            with self.subTest(code=code):
                self.script([init(), assistant({'type': 'text', 'text': 'Not logged in · Please run /login'}, error=code),
                             result(None, is_error=True)])
                notes = []
                with self.assertRaises(app.ProviderError) as e:
                    self.run_task(notes=notes)
                self.assertEqual(str(e.exception), expected)
                self.assertEqual(notes, [])  # the CLI's English notice is not recorded as the model's words

    def test_runs_that_do_not_finish_cleanly_are_not_completed(self):
        cases = {'error result': [init(), result(None, is_error=True)],
                 'error result with an answer': [init(), result(is_error=True)],
                 'error subtype with an answer': [init(), result(subtype='error_max_turns')],
                 'no result': [init()],
                 'no init': [result()],
                 'exit code': [init(), result()],
                 'broken answer': [init(), result({'kind': 'completed', 'content': 'x'})],
                 'empty answer': [init(), result({'kind': 'completed', 'content': '  ', 'next_step': ''})]}
        for name, steps in cases.items():
            with self.subTest(name):
                self.script(steps, exit=1 if name == 'exit code' else 0)
                with self.assertRaises(app.ProviderError):
                    self.run_task()

    def test_wider_tools_stop_the_run_before_any_work(self):
        for steps in ([init(tools=('Bash', 'WebSearch')), {'sleep': 5}, result()],
                      [init(mcp=({'name': 'browser', 'status': 'connected'},)), {'sleep': 5}, result()]):
            with self.subTest(steps[0]):
                self.script(steps)
                started = time.monotonic()
                with self.assertRaises(app.ProviderError) as e:
                    self.run_task()
                self.assertIn('超出辦公室的設定', str(e.exception))
                self.assertLess(time.monotonic() - started, 3)

    def test_stray_lines_are_ignored(self):
        self.script(['not json', '42', '["list"]', init(), result()])
        self.assertEqual(self.run_task()[0], ANSWER)

    def test_silence_is_reported_as_possibly_stuck(self):
        self.agent.HEARTBEAT_SECONDS, self.agent.STALL_SECONDS = 0.2, 0.6
        self.script([init(), {'sleep': 1.5}, result()])
        beats = []
        self.run_task(progress=beats.append)
        beats = [b for b in beats if b.startswith('Claude 處理中')]
        self.assertTrue(any('可能卡住' in b for b in beats), beats)

    def test_cancel_time_and_size_limits_stop_the_cli(self):
        started = time.monotonic()
        def check():
            if time.monotonic() - started > 0.5:
                raise app.Cancelled()
        self.script([init(), {'sleep': 10}, result()])
        with self.assertRaises(app.Cancelled):
            self.run_task(check=check)
        self.assertLess(time.monotonic() - started, 4)
        self.agent.TIME_LIMIT = 0.5
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertIn('超過 15 分鐘', str(e.exception))
        self.agent.TIME_LIMIT, self.agent.OUTPUT_LIMIT = 900, 2000
        self.script([init()] + [assistant({'type': 'text', 'text': '長' * 400})] * 5 + [result()])
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertIn('容量上限', str(e.exception))


class ClaudeInOfficeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = app.Store(Path(self.temp.name) / 'data')
        self.agent = app.ClaudeAgent(Path(self.temp.name) / 'runtime')
        self.agent.binary.parent.mkdir()
        self.agent.binary.write_text(FAKE_CLAUDE)
        self.agent.binary.chmod(0o700)
        (self.agent.home / 'script.json').write_text(json.dumps({'steps': HAPPY, 'logged_in': True, 'exit': 0}))
        self.office = app.Office(self.store, FakeModel(), providers={'claude': self.agent})

    def test_claude_task_is_completed_and_recorded(self):
        task = self.office.command({'id': uid(), 'prompt': '比較三家 VPS', 'executor': 'claude'})['task']
        self.assertEqual(task['model'], app.ClaudeAgent.model)
        self.office.execute(self.store.claim())
        saved = self.store.get(task['id'])
        self.assertEqual(saved['status'], 'completed')
        self.assertIn('三家方案比較表', saved['result'])
        self.assertIn('人工核對價格', saved['result'])
        self.assertEqual(json.loads(saved['metrics'])['provider'], 'claude')
        self.assertTrue(any(e['message'] == '已選取 Claude，正在準備外部工作。' for e in saved['events']))
        with self.store.connect() as c:
            keys = {r[0] for r in c.execute("SELECT key FROM settings WHERE key LIKE '%_last_success'")}
        self.assertEqual(keys, {'claude_last_success'})

    def test_claude_without_a_configured_agent_waits_for_it(self):
        office = app.Office(self.store, FakeModel())
        office.command({'id': uid(), 'prompt': '比較', 'executor': 'claude'})
        with self.assertRaises(app.ProviderError):
            office.execute(self.store.claim())

    def test_pictures_and_pdfs_stay_with_codex(self):
        with self.assertRaises(app.OfficeError) as e:
            self.store.submit(uid(), '讀這張圖', 'photo.png', 'm', 'claude')
        self.assertIn('只能交給 Codex', str(e.exception))
        with self.assertRaises(app.OfficeError):
            self.store.submit(uid(), '比較', '', 'm', 'llama')

    def test_health_lists_every_provider_and_keeps_codex_where_it_was(self):
        socket_path = Path(self.temp.name) / 'run/office.sock'
        server = app.Server(0, self.office, local_socket=socket_path)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        health = json.loads(local_request(socket_path, '/api/health')[1])
        self.assertEqual(health['provider'], {'name': 'Codex', 'installed': False, 'authenticated': False, 'last_success': None})
        self.assertEqual(health['providers']['codex'], health['provider'])
        self.assertEqual(health['providers']['claude'], {'name': 'Claude', 'installed': True, 'authenticated': True,
                                                         'last_success': None})
        self.assertEqual(health['providers']['gemini'], {'name': 'Gemini', 'installed': False, 'authenticated': False,
                                                         'last_success': None})
        self.assertFalse(health['external_connected'])


FAKE_GEMINI = r"""#!/usr/bin/env python3
import json, os, pathlib, sys, time
home = pathlib.Path(os.environ['GEMINI_CLI_HOME'])
script = json.loads((home / 'script.json').read_text())
(home / 'run.json').write_text(json.dumps({'argv': sys.argv[1:], 'env': dict(os.environ), 'stdin': sys.stdin.read(), 'cwd': os.getcwd(),
                                           'settings': json.loads((home / '.gemini/settings.json').read_text())}, ensure_ascii=False))
for step in script['steps']:
    if isinstance(step, dict) and 'sleep' in step:
        time.sleep(step['sleep'])
    else:
        print(step if isinstance(step, str) else json.dumps(step, ensure_ascii=False), flush=True)
sys.exit(script['exit'])
"""
G_INIT = {'type': 'init', 'session_id': 's', 'model': 'gemini-3-pro'}
G_DONE = {'type': 'result', 'status': 'success', 'stats': {'total_tokens': 900, 'tool_calls': 2}}


def said(text, pieces=3):
    size = max(1, len(text) // pieces)
    return [{'type': 'message', 'role': 'assistant', 'content': text[i:i + size], 'delta': True} for i in range(0, len(text), size)]


def tool(name, **parameters):
    return {'type': 'tool_use', 'tool_name': name, 'tool_id': uid(), 'parameters': parameters}


G_HAPPY = ([G_INIT, {'type': 'message', 'role': 'user', 'content': '（交辦）'},
            tool('google_web_search', query='Hostinger KVM 2 price'),
            {'type': 'tool_result', 'tool_id': 't', 'status': 'success', 'output': '...'},
            tool('web_fetch', prompt='讀 https://example.com/pricing 的價格')] +
           said(json.dumps(ANSWER, ensure_ascii=False)) + [G_DONE])


class GeminiAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.agent = app.GeminiAgent(Path(self.temp.name) / 'runtime')
        self.agent.binary.parent.mkdir()
        self.agent.binary.write_text(FAKE_GEMINI)
        self.agent.binary.chmod(0o700)
        (self.agent.home / '.gemini').mkdir()
        self.creds = self.agent.home / '.gemini/oauth_creds.json'
        self.creds.write_text('{}')

    def script(self, steps, exit=0):
        (self.agent.home / 'script.json').write_text(json.dumps({'steps': steps, 'exit': exit}, ensure_ascii=False))

    def run_task(self, check=lambda: None, progress=None, notes=None):
        task = {'id': uid(), 'prompt': '比較三家 VPS 價格', 'source': '', 'source_snapshot': None, 'context_snapshot': ''}
        return self.agent.run(task, check, progress or (lambda text: None),
                              note=(lambda kind, text: notes.append((kind, text))) if notes is not None else None)

    def recorded(self):
        return json.loads((self.agent.home / 'run.json').read_text())

    def test_completed_answer_from_streamed_text(self):
        self.script(G_HAPPY)
        notes = []
        answer, metrics = self.run_task(notes=notes)
        self.assertEqual(answer, ANSWER)
        self.assertEqual(notes, [('tool', '搜尋：Hostinger KVM 2 price'), ('tool', '讀取：讀 https://example.com/pricing 的價格')])
        self.assertEqual(metrics['provider'], 'gemini')
        self.assertEqual(metrics['stats'], {'total_tokens': 900, 'tool_calls': 2})
        self.assertEqual(metrics['event_types'], {'google_web_search': 1, 'web_fetch': 1})

    def test_runs_read_only_with_two_tools_on_the_google_login(self):
        os.environ['GEMINI_API_KEY'] = 'must-not-reach-the-cli'
        self.addCleanup(os.environ.pop, 'GEMINI_API_KEY')
        (self.agent.home / '.gemini/settings.json').write_text(json.dumps({'mcpServers': {'x': {'command': 'evil'}},
                                                                            'tools': {'core': ['run_shell_command']}}))
        self.script(G_HAPPY)
        self.run_task()
        run = self.recorded()
        argv, env = run['argv'], run['env']
        self.assertEqual(argv[argv.index('--approval-mode') + 1], 'plan')
        self.assertEqual(argv[argv.index('-o') + 1], 'stream-json')
        self.assertEqual(argv[argv.index('-p') + 1], '')
        self.assertEqual(run['settings'], {'security': {'auth': {'selectedType': 'oauth-personal'}},
                                           'tools': {'core': ['google_web_search', 'web_fetch']}, 'mcpServers': {},
                                           'privacy': {'usageStatisticsEnabled': False}})
        self.assertEqual(env['GEMINI_CLI_HOME'], str(self.agent.home))
        self.assertEqual(env['NO_BROWSER'], 'true')
        self.assertNotIn('GEMINI_API_KEY', env)
        self.assertEqual(Path(run['cwd']).resolve(), self.agent.workspace.resolve())
        self.assertTrue(run['stdin'].startswith(app.CliAgent.BRIEF + app.GeminiAgent.ANSWER))
        self.assertEqual(json.loads(run['stdin'].split('\n\n', 1)[1])['交辦'], '比較三家 VPS 價格')
        self.assertEqual(list(self.agent.workspace.iterdir()), [])

    def test_fenced_or_wrapped_json_is_accepted(self):
        for text in ('```json\n' + json.dumps(ANSWER, ensure_ascii=False) + '\n```',
                     '以下是結果：' + json.dumps(ANSWER, ensure_ascii=False)):
            with self.subTest(text[:12]):
                self.script([G_INIT] + said(text) + [G_DONE])
                self.assertEqual(self.run_task()[0], ANSWER)

    def test_not_installed_or_logged_out_never_starts_a_run(self):
        self.creds.unlink()
        self.script(G_HAPPY)
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertEqual(str(e.exception), app.GeminiAgent.LOGIN)
        self.assertFalse((self.agent.home / 'run.json').exists())
        self.agent.binary.unlink()
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertIn('還沒裝進辦公室', str(e.exception))

    def test_expired_login_and_used_up_quota_ask_the_owner(self):
        self.script([], exit=41)
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertEqual(str(e.exception), app.GeminiAgent.LOGIN)
        for steps in ([G_INIT, {'type': 'error', 'severity': 'error', 'message': 'RESOURCE_EXHAUSTED: quota exceeded'},
                       {'type': 'result', 'status': 'error', 'error': {'type': 'Error', 'message': 'failed'}}],
                      [G_INIT, {'type': 'result', 'status': 'error', 'error': {'type': 'Error', 'message': 'HTTP 429 Too Many Requests'}}]):
            with self.subTest(steps[1]):
                self.script(steps)
                with self.assertRaises(app.ProviderError) as e:
                    self.run_task()
                self.assertEqual(str(e.exception), app.GeminiAgent.QUOTA)

    def test_any_other_tool_stops_the_run(self):
        self.script([G_INIT, tool('run_shell_command', command='ls ~'), {'sleep': 5}, G_DONE])
        started = time.monotonic()
        with self.assertRaises(app.ProviderError) as e:
            self.run_task()
        self.assertIn('超出辦公室的設定', str(e.exception))
        self.assertLess(time.monotonic() - started, 3)

    def test_runs_that_do_not_finish_cleanly_are_not_completed(self):
        answer = said(json.dumps(ANSWER, ensure_ascii=False))
        cases = {'error result': [G_INIT] + answer + [{'type': 'result', 'status': 'error', 'error': {'type': 'Error', 'message': 'x'}}],
                 'no result': [G_INIT] + answer,
                 'no init': answer + [G_DONE],
                 'exit code': [G_INIT] + answer + [G_DONE],
                 'not json': [G_INIT] + said('三家方案比較表') + [G_DONE],
                 'broken answer': [G_INIT] + said('{"kind": "completed", "content": "x"}') + [G_DONE]}
        for name, steps in cases.items():
            with self.subTest(name):
                self.script(steps, exit=1 if name == 'exit code' else 0)
                with self.assertRaises(app.ProviderError):
                    self.run_task()

    def test_gemini_task_through_the_office(self):
        store = app.Store(Path(self.temp.name) / 'data')
        office = app.Office(store, FakeModel(), providers={'gemini': self.agent})
        self.script(G_HAPPY)
        task = office.command({'id': uid(), 'prompt': '比較三家 VPS', 'executor': 'gemini'})['task']
        self.assertEqual(task['model'], app.GeminiAgent.model)
        office.execute(store.claim())
        saved = store.get(task['id'])
        self.assertEqual(saved['status'], 'completed')
        self.assertIn('三家方案比較表', saved['result'])
        self.assertTrue(any(e['message'] == '已選取 Gemini，正在準備外部工作。' for e in saved['events']))
        with store.connect() as c:
            self.assertIsNotNone(c.execute("SELECT value FROM settings WHERE key='gemini_last_success'").fetchone())


if __name__ == '__main__':
    unittest.main()
