"""Real TCP upgrade, UTF-8 delivery and reconnect, with no external service."""
import json
import socket
import threading
import time
import uvicorn
from websockets.sync.client import connect
from nekochat.relay.app import create_app
from test_relay import TOKENS, packet, policy

def test_real_websocket_roundtrip():
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(create_app(policy()), log_level='critical', ws='websockets-sansio', lifespan='off'))
    thread = threading.Thread(target=server.run, kwargs={'sockets': [listener]}, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 10
        while not server.started:
            assert time.monotonic() < deadline
            time.sleep(.01)
        url=f'ws://127.0.0.1:{port}/nekochat/v1/ws'
        def login(user):
            return connect(url, additional_headers={'Authorization':f'Bearer {user}:{TOKENS[user]}'}, open_timeout=5)
        with login('alice') as a, login('bob') as b:
            assert json.loads(a.recv(timeout=5))['kind']=='ready'
            b.recv(timeout=5)
            a.send(json.dumps(packet(), ensure_ascii=False))
            assert json.loads(b.recv(timeout=5))['text']=='下課見 🐈'
            assert json.loads(a.recv(timeout=5))['status']=='delivered'
        with login('alice') as a:
            assert json.loads(a.recv(timeout=5))['kind']=='ready'
    finally:
        server.should_exit=True
        thread.join(timeout=10)
        listener.close()
        assert not thread.is_alive()
