"""Real desktop bootstrap + paired chat, without any generated config files."""
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import httpx
import pytest
from pydantic import ValidationError
from websockets.sync.client import connect
from nekochat.relay.desktop import DesktopBootstrap, private_ipv4

TOKENS = {'alice': 'test-desktop-alice-credential', 'bob': 'test-desktop-bob-credential'}
ROOM = '1' * 32

def bootstrap():
    return {'version': 1, 'room_id': ROOM, 'bind_hosts': ['127.0.0.1'], 'policy': {
        'mode': 'lan', 'users': {user: {'token_sha256': hashlib.sha256(token.encode()).hexdigest(),
        'friends': [other for other in TOKENS if other != user]} for user, token in TOKENS.items()}}}

@pytest.mark.parametrize('host', ['0.0.0.0', '8.8.8.8', 'example.com', '::1', '169.254.1.1', '192.168.1.2.evil', '127.1'])
def test_room_rejects_public_or_ambiguous_bindings(host):
    assert not private_ipv4(host)
    value = bootstrap(); value['bind_hosts'] = [host]
    with pytest.raises(ValidationError): DesktopBootstrap.model_validate(value)

def test_room_requires_mutual_distinct_credentials():
    value=bootstrap();value['policy']['users']['alice']['friends']=[]
    with pytest.raises(ValidationError): DesktopBootstrap.model_validate(value)
    value=bootstrap();value['policy']['users']['bob']['token_sha256']=value['policy']['users']['alice']['token_sha256']
    with pytest.raises(ValidationError): DesktopBootstrap.model_validate(value)
    value=bootstrap();value['policy']['mode']='vps'
    with pytest.raises(ValidationError): DesktopBootstrap.model_validate(value)

class RoomProcess:
    def __init__(self):
        executable=os.environ.get('NEKOCHAT_FROZEN_RELAY')
        command=[executable] if executable else [sys.executable,'-m','nekochat.relay.desktop']
        self.process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
            cwd=Path(__file__).resolve().parents[3])
        self.process.stdin.write(json.dumps(bootstrap())+'\n');self.process.stdin.flush()
        output=queue.Queue()
        threading.Thread(target=lambda:output.put(self.process.stdout.readline()),daemon=True).start()
        try:
            line=output.get(timeout=25)
            self.start=json.loads(line)
            self.port=self.start['port']
            deadline=time.monotonic()+10
            while True:
                try:
                    health=httpx.get(f'http://127.0.0.1:{self.port}/healthz',timeout=1).json()
                    assert health['room_id']==ROOM
                    break
                except httpx.TransportError:
                    assert time.monotonic()<deadline
                    time.sleep(.05)
        except Exception:
            self.close();raise
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=5)
        self.process.stdout.close();self.process.stderr.close()

def test_desktop_room_roundtrip_and_parent_eof_exit():
    room=RoomProcess()
    try:
        assert room.start=={'version':1,'port':room.port,'room_id':ROOM}
        url=f'ws://127.0.0.1:{room.port}/nekochat/v1/ws'
        with connect(url,additional_headers={'Authorization':f"Bearer alice:{TOKENS['alice']}"}) as a, \
             connect(url,additional_headers={'Authorization':f"Bearer bob:{TOKENS['bob']}"}) as b:
            assert json.loads(a.recv(timeout=5))['user']=='alice';b.recv(timeout=5)
            a.send(json.dumps({'protocol':'nekochat','version':1,'kind':'chat.send','id':'room_test','to':'bob','text':'不用改設定檔 🐈'}))
            assert json.loads(b.recv(timeout=5))['text']=='不用改設定檔 🐈'
            assert json.loads(a.recv(timeout=5))['status']=='delivered'
        room.process.stdin.close()
        assert room.process.wait(timeout=8)==0
        with pytest.raises(httpx.TransportError):httpx.get(f'http://127.0.0.1:{room.port}/healthz',timeout=1)
    finally:room.close()

def test_desktop_bootstrap_never_echoes_input():
    secret='private-test-value-must-not-be-logged'
    result=subprocess.run([sys.executable,'-m','nekochat.relay.desktop'],input=json.dumps({'unexpected':secret})+'\n',
        text=True,capture_output=True,timeout=10)
    assert result.returncode==1 and secret not in result.stdout+result.stderr
