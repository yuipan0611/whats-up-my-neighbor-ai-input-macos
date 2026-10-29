"""Bundled desktop room Relay: in-memory policy via stdin, lifetime owned by App."""
import ipaddress
import json
import socket
import sys
import threading
import uvicorn
from pydantic import BaseModel, ConfigDict, Field, model_validator
from nekochat.relay.app import Policy, create_app, unique_object


def private_ipv4(value: str) -> bool:
    try:
        ip = ipaddress.IPv4Address(value)
        return any(ip in network for network in (
            ipaddress.IPv4Network('10.0.0.0/8'), ipaddress.IPv4Network('172.16.0.0/12'),
            ipaddress.IPv4Network('192.168.0.0/16'), ipaddress.IPv4Network('127.0.0.0/8')))
    except ipaddress.AddressValueError:
        return False


class DesktopBootstrap(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    version: int = Field(ge=1, le=1)
    room_id: str = Field(pattern=r'^[a-f0-9]{32}$')
    bind_hosts: list[str] = Field(min_length=1, max_length=8)
    policy: Policy

    @model_validator(mode='after')
    def validate_room(self):
        if self.policy.mode != 'lan' or len(self.policy.users) != 2:
            raise ValueError('Desktop rooms require exactly two LAN peers')
        if len(set(self.bind_hosts)) != len(self.bind_hosts) or not all(private_ipv4(x) for x in self.bind_hosts):
            raise ValueError('Only unique private IPv4 bindings are allowed')
        digests = set()
        for user, account in self.policy.users.items():
            if set(account.friends) != set(self.policy.users) - {user}:
                raise ValueError('Both peers must authorize each other')
            digests.add(account.token_sha256)
        if len(digests) != 2:
            raise ValueError('Each peer needs its own credential')
        return self


def run():
    sockets = []
    try:
        # No secrets in arguments, environment, config files, stdout or logs.
        line = sys.stdin.buffer.readline(16385)
        if len(line) > 16384:
            raise ValueError('Bootstrap too large')
        settings = DesktopBootstrap.model_validate(json.loads(line, object_pairs_hook=unique_object))
        hosts = list(dict.fromkeys(['127.0.0.1'] + settings.bind_hosts))
        port = 0
        for host in hosts:
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sockets.append(listener)
            listener.bind((host, port))
            port = listener.getsockname()[1]
            listener.listen(128)
        app = create_app(settings.policy, room_id=settings.room_id)
        server = uvicorn.Server(uvicorn.Config(app, log_level='critical', access_log=False,
            ws='websockets-sansio', ws_max_size=16384, lifespan='off', proxy_headers=False))

        def watch_parent():
            # Parent death/exit closes its stdin pipe, including on Windows.
            # A normal parent keeps this pipe open until leaving the room.
            sys.stdin.buffer.read()
            server.should_exit = True

        threading.Thread(target=watch_parent, daemon=True).start()
        print(json.dumps({'version': 1, 'port': port, 'room_id': settings.room_id}), flush=True)
        server.run(sockets=sockets)
        return 0
    except Exception:
        # Do not print validation bodies or bootstrap data.
        print('NekoChat room Relay could not start.', file=sys.stderr)
        return 1
    finally:
        for listener in sockets:
            listener.close()


if __name__ == '__main__':
    raise SystemExit(run())
