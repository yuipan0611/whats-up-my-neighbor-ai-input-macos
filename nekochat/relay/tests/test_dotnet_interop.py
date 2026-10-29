"""Opt-in execution of the actual C# transport against a live FastAPI Relay."""
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import pytest
import uvicorn
from nekochat.relay.app import create_app
from test_relay import policy

@pytest.mark.skipif(not os.environ.get('NEKOCHAT_DOTNET'), reason='Set NEKOCHAT_DOTNET to the dotnet executable')
def test_csharp_transport_to_fastapi():
    listener=socket.socket();listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
    server=uvicorn.Server(uvicorn.Config(create_app(policy()),log_level='critical',ws='websockets-sansio',lifespan='off'))
    thread=threading.Thread(target=server.run,kwargs={'sockets':[listener]},daemon=True);thread.start()
    try:
        deadline=time.monotonic()+10
        while not server.started:
            assert time.monotonic()<deadline
            time.sleep(.01)
        root=Path(__file__).resolve().parents[3]
        result=subprocess.run([os.environ['NEKOCHAT_DOTNET'],'run','--project','windows-lite/NekoChat.Tests','-c','Release','--no-build','--','--live',str(port)],cwd=root,text=True,capture_output=True,timeout=60)
        assert result.returncode==0,result.stdout+result.stderr
        assert 'behavior checks passed' in result.stdout
    finally:
        server.should_exit=True;thread.join(timeout=10);listener.close();assert not thread.is_alive()
