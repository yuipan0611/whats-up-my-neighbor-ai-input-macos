"""Provider stream parsing and credential boundaries; no real account or model is used."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from test_office import app
sys.path.insert(0,str(Path(__file__).parents[1]/'hands'))
from team_worker import Team,ProviderUnavailable

class TeamWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name)
        client=SimpleNamespace(post=lambda path,body:(200,{'continue':True}))
        worker=SimpleNamespace(office=client,workspace_root=self.folder/'work',codex_home=self.folder/'codex-home',codex='codex',stopping=False)
        self.team=Team(worker)
        self.identity={'task_id':'synthetic-task','lease':'fictional-private-lease'}

    def run_stream(self,name,event,returncode=0):
        code='import json,sys; sys.stdin.read(); print('+repr(json.dumps(event))+'); sys.exit('+str(returncode)+')'
        return self.team.run(name,[sys.executable,'-c',code],'synthetic prompt',self.folder,self.identity,self.folder/'unused')

    def test_google_result_response_is_parsed_as_structured_output(self):
        expected={'content':'檢查完成','approved':True}
        event={'event':'result','result':{'status':'SUCCESS','response':json.dumps(expected)}}
        self.assertEqual(self.run_stream('gemini',event),expected)

    def test_claude_structured_output_is_parsed(self):
        self.assertEqual(self.run_stream('claude',{'type':'result','structured_output':{'content':'方案'}}),{'content':'方案'})

    def test_cli_exit_zero_with_google_error_is_not_success(self):
        with self.assertRaises(ProviderUnavailable):
            self.run_stream('gemini',{'event':'result','result':{'status':'ERROR','response':''}})

    def test_unstructured_or_missing_approval_is_not_success(self):
        for event in ({'type':'result','result':'plain text'}, {'event':'result','result':{'response':'{"content":"looks okay"}'}}):
            with self.assertRaises(ProviderUnavailable): self.run_stream('gemini',event)

    def test_environment_does_not_inherit_api_billing_credentials(self):
        with patch.dict(os.environ,{'ANTHROPIC_API_KEY':'fictional-api','GEMINI_API_KEY':'fictional-api','OPENAI_API_KEY':'fictional-api'}):
            env=self.team.environment()
            self.assertFalse(any(k.endswith('API_KEY') for k in env))
            self.assertNotIn('fictional-api',json.dumps(env))

    def test_provider_commands_do_not_receive_the_lease_and_codex_has_only_project_tools(self):
        seen=[]
        self.team.post=lambda *args,**kwargs:{'state':'started'} if kwargs.get('mode')=='start' else {'state':'completed'}
        def fake_run(name,args,prompt,*rest): seen.append((name,args,prompt)); return {'content':'okay','approved':True} if name=='gemini' else {'content':'okay'}
        self.team.run=fake_run
        for name in ('claude','codex','gemini'):
            self.team.phase(name,self.identity,'synthetic',self.folder,{},self.folder/'proxy.sock')
        self.assertNotIn(self.identity['lease'],json.dumps(seen))
        codex=next(args for name,args,prompt in seen if name=='codex')
        self.assertIn('read-only',codex); self.assertIn('shell_tool',codex); self.assertIn('unified_exec',codex)
        self.assertIn('mcp_servers.project.command="/usr/bin/python3"',codex)
        google=next(args for name,args,prompt in seen if name=='gemini')
        self.assertIn('--input-format',google); self.assertIn('gemini-3.1-pro-high',google)
        self.assertNotIn('--dangerously-skip-permissions',google)

if __name__=='__main__': unittest.main()
