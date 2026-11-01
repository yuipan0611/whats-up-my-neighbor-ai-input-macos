import hashlib
import json
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from jsonschema import Draft202012Validator
from nekochat.relay.app import Policy, create_app
from nekochat.relay.protocol import ClientEvent, ServerEvent

TOKENS = {u: f"test-only-{u}-not-a-real-credential" for u in ("alice", "bob", "eve")}

def policy(mode="lan", mutual=True):
    return Policy(mode=mode, users={u: {"token_sha256": hashlib.sha256(t.encode()).hexdigest(),
        "friends": (["bob"] if u == "alice" else ["alice"] if u == "bob" and mutual else [])}
        for u, t in TOKENS.items()})

def connect(client, user="alice", **kwargs):
    return client.websocket_connect("/nekochat/v1/ws", headers={"Authorization": f"Bearer {user}:{TOKENS[user]}"}, **kwargs)

def packet(**extra):
    return dict(protocol="nekochat", version=1, id="m1", kind="chat.send", to="bob", text="下課見 🐈", **extra)

def test_delivery_authoritative_sender_and_duplicate():
    with TestClient(create_app(policy())) as c, connect(c) as a, connect(c, "bob") as b:
        assert a.receive_json()["user"] == "alice"
        b.receive_json()
        a.send_json(packet())
        incoming = b.receive_json()
        assert incoming["sender"] == "alice" and incoming["text"] == "下課見 🐈"
        assert a.receive_json()["status"] == "delivered"
        a.send_json(packet())
        assert a.receive_json()["status"] == "duplicate"
        b.send_json(dict(protocol="nekochat", version=1, id="p", kind="ping"))
        assert b.receive_json()["kind"] == "pong"  # No duplicate message queued.

@pytest.mark.parametrize("changes", [
    {"version": 2}, {"version": True}, {"version": 1.0}, {"kind": "executeRequest"},
    {"kind": "agent.run"}, {"action": "paste"}, {"sender": "eve"}, {"text": " "},
    {"text": "x" * 2001}, {"text": "\ud800"}, {"to": "../bob"}, {"to": "bob\n"}, {"id": "m1\n"}, {"protocol": "office"}, {"id": ""},
])
def test_invalid_and_remote_events(changes):
    with TestClient(create_app(policy())) as c, connect(c) as a:
        a.receive_json()
        p = packet(); p.update(changes); a.send_text(json.dumps(p, ensure_ascii=True))
        assert a.receive_json()["code"] == "invalid_event"

def test_malformed_binary_and_oversize():
    for payload in ["{", "[]", "null", "1", '{"protocol":"office","protocol":"nekochat","version":1,"id":"p","kind":"ping"}']:
        with TestClient(create_app(policy())) as c, connect(c) as a:
            a.receive_json(); a.send_text(payload)
            assert a.receive_json()["code"] == "invalid_event"
    for payload in [b"binary", "x" * 16385]:
        with TestClient(create_app(policy())) as c, connect(c) as a:
            a.receive_json()
            a.send_bytes(payload) if isinstance(payload, bytes) else a.send_text(payload)
            with pytest.raises(WebSocketDisconnect) as e: a.receive_json()
            assert e.value.code == 1009

def test_offline_and_mutual_authorization():
    with TestClient(create_app(policy())) as c, connect(c) as a:
        a.receive_json(); a.send_json(packet()); assert a.receive_json()["code"] == "offline"
        p=packet();p['to']='eve';a.send_json(p);assert a.receive_json()["code"] == "forbidden"
    with TestClient(create_app(policy(mutual=False))) as c, connect(c) as a:
        a.receive_json(); a.send_json(packet()); assert a.receive_json()["code"] == "forbidden"

@pytest.mark.parametrize("headers,path,mode", [
    ({}, "/nekochat/v1/ws", "lan"),
    ({"Authorization": "Bearer alice:wrong"}, "/nekochat/v1/ws", "lan"),
    ({"Authorization": f"Bearer alice:{TOKENS['alice']}", "Origin": "https://evil.invalid"}, "/nekochat/v1/ws", "lan"),
    ({"Authorization": f"Bearer alice:{TOKENS['alice']}"}, "/nekochat/v1/ws?token=no", "lan"),
    ({"Authorization": f"Bearer alice:{TOKENS['alice']}"}, "/nekochat/v1/ws", "vps"),
])
def test_auth_transport_and_origin(headers,path,mode):
    with TestClient(create_app(policy(mode))) as c:
        with pytest.raises(WebSocketDisconnect):
            with c.websocket_connect(path, headers=headers): pass

def test_vps_wss_and_duplicate_session():
    with TestClient(create_app(policy("vps"))) as c:
        with c.websocket_connect("wss://testserver/nekochat/v1/ws", headers={"Authorization": f"Bearer alice:{TOKENS['alice']}"}) as a:
            assert a.receive_json()["kind"] == "ready"
    with TestClient(create_app(policy())) as c, connect(c) as a:
        a.receive_json()
        with pytest.raises(WebSocketDisconnect) as e:
            with connect(c): pass
        assert e.value.code == 4409
    # A disconnected identity can connect again.
    with TestClient(create_app(policy())) as c, connect(c) as a:
        assert a.receive_json()["kind"] == "ready"

def test_rate_limit():
    with TestClient(create_app(policy())) as c, connect(c) as a:
        a.receive_json()
        for i in range(30):
            a.send_text("{"); assert a.receive_json()["code"] == "invalid_event"
        a.send_text("{"); assert a.receive_json()["code"] == "rate_limited"
        with pytest.raises(WebSocketDisconnect) as e: a.receive_json()
        assert e.value.code == 4429

def test_schema_is_generated_and_matches_events():
    root = Path(__file__).resolve().parents[2] / "protocol"
    for name, adapter in [("client", ClientEvent), ("server", ServerEvent)]:
        actual = json.loads((root / f"{name}-v1.schema.json").read_text())
        expected = adapter.json_schema(); expected['$schema'] = "https://json-schema.org/draft/2020-12/schema"
        assert actual == expected
        Draft202012Validator.check_schema(actual)
    validator = Draft202012Validator(json.loads((root / 'client-v1.schema.json').read_text()))
    validator.validate(packet())
    for field, value in [('to', 'bob\n'), ('id', 'm1\n'), ('text', ' \n')]:
        invalid = packet(); invalid[field] = value
        assert not validator.is_valid(invalid)

def test_policy_invalid_references_and_reused_tokens(tmp_path):
    p=policy().model_dump();p['users']['alice']['friends']=['missing']
    path=tmp_path/'config.json';path.write_text(json.dumps(p))
    with pytest.raises(ValueError): Policy.load(str(path))
    p=policy().model_dump();p['users']['bob']['token_sha256']=p['users']['alice']['token_sha256']
    path.write_text(json.dumps(p))
    with pytest.raises(ValueError): Policy.load(str(path))


def test_concurrent_identity_is_reserved_before_accept():
    import asyncio
    from types import SimpleNamespace

    async def scenario():
        app = create_app(policy())
        endpoint = next(r.endpoint for r in app.routes if r.path == '/nekochat/v1/ws')
        entered, release = asyncio.Event(), asyncio.Event()

        class Socket:
            query_params = {}
            headers = {'authorization': f"Bearer alice:{TOKENS['alice']}"}
            url = SimpleNamespace(scheme='ws')
            def __init__(self, delayed=False):
                self.delayed = delayed
                self.accepted = False
                self.close_code = None
            async def accept(self):
                self.accepted = True
                if self.delayed:
                    entered.set()
                    await release.wait()
            async def send_json(self, value):
                pass
            async def receive(self):
                return {'type': 'websocket.disconnect'}
            async def close(self, code=1000):
                self.close_code = code

        first, second = Socket(True), Socket()
        task = asyncio.create_task(endpoint(first))
        await asyncio.wait_for(entered.wait(), 2)
        try:
            await asyncio.wait_for(endpoint(second), 2)
            assert not second.accepted and second.close_code == 4409
        finally:
            release.set()
            await asyncio.wait_for(task, 2)
    asyncio.run(scenario())
