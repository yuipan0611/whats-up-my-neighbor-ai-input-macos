"""Single-process, live-only authenticated Relay. No Agent imports or commands."""
import asyncio
import hashlib
import hmac
import json
import os
import time
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from pathlib import Path
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from .protocol import ClientEvent, Send, UserID, event

class Account(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    token_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    friends: list[UserID]

class Policy(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    mode: str = Field(pattern=r"^(lan|vps)$")
    users: dict[UserID, Account] = Field(min_length=1, max_length=100)

    @classmethod
    def load(cls, path: str):
        policy = cls.model_validate_json(Path(path).read_text())
        for user, account in policy.users.items():
            if any(friend not in policy.users or friend == user for friend in account.friends):
                raise ValueError("Unknown or self friend in relay policy")
        digests = [a.token_sha256 for a in policy.users.values()]
        if len(set(digests)) != len(digests):
            raise ValueError("Each user needs a unique token")
        return policy

@dataclass
class Peer:
    socket: WebSocket
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send(self, message):
        async with self.lock:
            await asyncio.wait_for(self.socket.send_json(message), timeout=5)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def create_app(policy: Policy, room_id: str | None = None) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    peers: dict[str, Peer] = {}

    @app.get("/healthz")
    async def health():
        return {"protocol": "nekochat", "version": 1, **({"room_id": room_id} if room_id else {})}

    @app.websocket("/nekochat/v1/ws")
    async def websocket(ws: WebSocket):
        # Native clients only. Credentials never appear in query strings.
        if ws.query_params or ws.headers.get("origin") or (policy.mode == "vps" and ws.url.scheme != "wss"):
            await ws.close(code=4403)
            return
        auth = ws.headers.get("authorization", "")
        user, separator, token = auth.removeprefix("Bearer ").partition(":")
        account = policy.users.get(user)
        if not auth.startswith("Bearer ") or not separator or not account or not hmac.compare_digest(
            hashlib.sha256(token.encode()).hexdigest(), account.token_sha256
        ):
            await ws.close(code=4401)
            return
        if user in peers:
            await ws.close(code=4409)
            return
        # Reserve synchronously before the handshake yields; concurrent upgrades
        # for the same identity must not both pass the duplicate-session check.
        peer = Peer(ws)
        peers[user] = peer
        seen: OrderedDict[str, None] = OrderedDict()
        rate = deque()
        try:
            await ws.accept()
            await peer.send(event("ready", "ready", user=user))
            while True:
                packet = await asyncio.wait_for(ws.receive(), timeout=90)
                if packet["type"] == "websocket.disconnect":
                    break
                raw = packet.get("text")
                if raw is None or len(raw.encode("utf-8")) > 16384:
                    await ws.close(code=1009)
                    break
                now = time.monotonic()
                while rate and rate[0] <= now - 10:
                    rate.popleft()
                if len(rate) >= 30:
                    await peer.send(event("error", "invalid", code="rate_limited"))
                    await ws.close(code=4429)
                    break
                rate.append(now)
                try:
                    # Explicitly reject bool/float versions (JSON Schema integer semantics vary).
                    obj = json.loads(raw, object_pairs_hook=unique_object)
                    if type(obj.get("version")) is not int:
                        raise ValueError("version")
                    message = ClientEvent.validate_python(obj)
                    if isinstance(message, Send):
                        message.text.encode("utf-8")
                        if not message.text.strip():
                            raise ValueError("empty")
                except (ValidationError, ValueError, TypeError, AttributeError):
                    await peer.send(event("error", "invalid", code="invalid_event"))
                    continue
                if not isinstance(message, Send):
                    await peer.send(event("pong", message.id))
                    continue
                friend = policy.users.get(message.to)
                if message.to not in account.friends or not friend or user not in friend.friends:
                    await peer.send(event("error", message.id, code="forbidden"))
                    continue
                if message.id in seen:
                    await peer.send(event("chat.ack", message.id, status="duplicate"))
                    continue
                target = peers.get(message.to)
                if target is None:
                    await peer.send(event("error", message.id, code="offline"))
                    continue
                try:
                    await target.send(event("chat.message", message.id, sender=user, text=message.text))
                except (TimeoutError, RuntimeError, WebSocketDisconnect, OSError):
                    await peer.send(event("error", message.id, code="offline"))
                    continue
                seen[message.id] = None
                if len(seen) > 256:
                    seen.popitem(last=False)
                await peer.send(event("chat.ack", message.id, status="delivered"))
        except (WebSocketDisconnect, TimeoutError, RuntimeError, OSError):
            pass
        finally:
            if peers.get(user) is peer:
                del peers[user]
            try:
                await ws.close()
            except (RuntimeError, OSError):
                pass
    return app


def from_env():
    path = os.environ.get("NEKOCHAT_CONFIG")
    if not path:
        raise RuntimeError("Set NEKOCHAT_CONFIG to an external relay policy file")
    return create_app(Policy.load(path))
