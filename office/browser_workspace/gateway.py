"""Private Unix-socket HTTP/WebSocket gateway for a single remote display.

Office authenticates the user and supplies X-Neko-Device. Only that trusted
same-UID Unix peer may reach this service; this is not a public auth system.
RFB bytes are transported unchanged. The view upstream must enforce view-only.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import socket
import stat
import struct

from aiohttp import WSMsgType, web

from .controller import BrowserController, ControllerError
from .ports import BrowserWorkspaceError

CONTROLLER = web.AppKey("browser_controller", BrowserController)
VIEW_SOCKET = web.AppKey("browser_view_socket", Path)
CONTROL_SOCKET = web.AppKey("browser_control_socket", Path)
STATIC_ROOT = web.AppKey("browser_static_root", Path)
DEVICE = web.RequestKey("browser_device", str)
_STATIC = {"/browser/": "index.html", "/browser/viewer.js": "viewer.js",
           "/browser/viewer.css": "viewer.css", "/browser/novnc.js": "novnc.js",
           "/browser/notices.txt": "notices.txt"}
_HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer", "X-Frame-Options": "SAMEORIGIN",
            "Content-Security-Policy": "default-src 'self'; script-src 'self'; "
            "style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; "
            "object-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'self'"}


def validate_private_socket(path: str | Path, *, must_exist: bool = True) -> Path:
    path = Path(path).expanduser()
    if not path.is_absolute() or ".." in path.parts or len(os.fsencode(path)) >= 104:
        raise ControllerError("socket_path_invalid", 503)
    try:
        for parent in path.parents:
            if parent.is_symlink():
                raise ValueError
        info = path.parent.stat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise ValueError
        try:
            info = path.lstat()
        except FileNotFoundError:
            if must_exist:
                raise ValueError from None
            return path
        if (not must_exist or not stat.S_ISSOCK(info.st_mode)
                or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError
    except (OSError, ValueError):
        raise ControllerError("socket_path_invalid", 503) from None
    return path


def _device(request: web.Request) -> str:
    sock = request.transport.get_extra_info("socket") if request.transport else None
    if sock is None or sock.family != socket.AF_UNIX:
        raise ControllerError("private_gateway_only", 403)
    if hasattr(socket, "SO_PEERCRED"):
        uid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
        if uid != os.geteuid():
            raise ControllerError("private_gateway_only", 403)
    values = request.headers.getall("X-Neko-Device", [])
    if len(values) != 1:
        raise ControllerError("invalid_device", 403)
    BrowserController._device(values[0])
    return values[0]


@web.middleware
async def _guard(request: web.Request, handler):
    try:
        request[DEVICE] = _device(request)
        if request.can_read_body:
            if request.method == "GET":
                raise ControllerError("invalid_request", 400)
            await request.read()  # Application enforces the 4 KiB bound.
        response = await handler(request)
    except ControllerError as error:
        response = web.json_response({"error": error.code}, status=error.status)
    except web.HTTPException as error:
        code = {404: "not_found", 405: "method_not_allowed", 413: "request_too_large"}.get(
            error.status, "invalid_request")
        response = web.json_response({"error": code}, status=error.status)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError, TypeError):
        response = web.json_response({"error": "invalid_request"}, status=400)
    except BrowserWorkspaceError:
        response = web.json_response({"error": "browser_not_running"}, status=503)
    except Exception:
        response = web.json_response({"error": "gateway_failure"}, status=503)
    if not response.prepared:
        response.headers.update(_HEADERS)
    return response


async def _body(request: web.Request, keys: set[str]) -> dict:
    if request.query or request.content_type != "application/json":
        raise ControllerError("invalid_request", 400)
    value = await request.json()
    if not isinstance(value, dict) or set(value) != keys:
        raise ControllerError("invalid_request", 400)
    return value


async def _state(request: web.Request) -> web.Response:
    if request.query:
        raise ControllerError("invalid_request", 400)
    return web.json_response(await request.app[CONTROLLER].state(request[DEVICE]))


async def _takeover(request: web.Request) -> web.Response:
    await _body(request, set())
    return web.json_response(await request.app[CONTROLLER].takeover(request[DEVICE]))


async def _release(request: web.Request) -> web.Response:
    body = await _body(request, {"epoch"})
    if type(body["epoch"]) is not int:
        raise ControllerError("invalid_request", 400)
    return web.json_response(await request.app[CONTROLLER].release(request[DEVICE], body["epoch"]))


async def _static(request: web.Request) -> web.Response:
    if request.query:
        raise ControllerError("invalid_request", 400)
    path = request.app[STATIC_ROOT] / _STATIC[request.path]
    if not path.is_file() or path.is_symlink():
        raise web.HTTPNotFound()
    return web.FileResponse(path)


class _Bridge:
    def __init__(self, ws: web.WebSocketResponse):
        self.ws = ws
        self.reader = self.writer = None
        self.connecting = None
        self.pumps: list[asyncio.Task] = []
        self.closing = None

    async def connect(self, path: Path) -> None:
        validate_private_socket(path)
        if self.closing is not None:
            raise ControllerError("stale_epoch")
        self.connecting = asyncio.create_task(asyncio.open_unix_connection(path))
        try:
            self.reader, self.writer = await asyncio.wait_for(self.connecting, timeout=3)
        except (OSError, TimeoutError):
            raise ControllerError("display_unavailable", 503) from None
        if self.closing is not None:
            self.writer.close()
            await self.writer.wait_closed()
            raise ControllerError("stale_epoch")

    async def send_tcp(self, data: bytes) -> None:
        if self.closing is not None or self.writer is None:
            raise ControllerError("control_not_connected")
        self.writer.write(data)
        await self.writer.drain()

    async def run(self, forward) -> None:
        async def to_browser():
            while chunk := await self.reader.read(65536):
                await forward(chunk, self.ws.send_bytes)

        async def to_display():
            async for message in self.ws:
                if message.type == WSMsgType.BINARY:
                    await forward(message.data, self.send_tcp)
                elif message.type not in (WSMsgType.PING, WSMsgType.PONG):
                    break

        if self.closing is not None:
            return
        self.pumps = [asyncio.create_task(to_browser()), asyncio.create_task(to_display())]
        await asyncio.wait(self.pumps, return_when=asyncio.FIRST_COMPLETED)

    async def close(self) -> None:
        if self.closing is None:
            self.closing = asyncio.create_task(self._close())
            self.closing.add_done_callback(lambda task: None if task.cancelled() else task.exception())
        await asyncio.shield(self.closing)

    async def _close(self) -> None:
        tasks = list(self.pumps)
        if self.connecting is not None and not self.connecting.done():
            tasks.append(self.connecting)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if (self.writer is None and self.connecting is not None and self.connecting.done()
                and not self.connecting.cancelled() and self.connecting.exception() is None):
            self.reader, self.writer = self.connecting.result()
        if self.writer is not None:
            self.writer.close()
            try:
                await asyncio.wait_for(self.writer.wait_closed(), timeout=2)
            except (OSError, TimeoutError):
                pass
        if self.ws.prepared:
            await self.ws.close(code=1000)


async def _websocket(request: web.Request) -> web.WebSocketResponse:
    if (set(request.query) != {"mode", "epoch"}
            or any(len(request.query.getall(key)) != 1 for key in ("mode", "epoch"))
            or request.can_read_body):
        raise ControllerError("invalid_request", 400)
    mode, raw_epoch = request.query["mode"], request.query["epoch"]
    if mode not in ("view", "control") or not raw_epoch.isascii() or not raw_epoch.isdigit():
        raise ControllerError("invalid_request", 400)
    if len(raw_epoch) > 16 or int(raw_epoch) > 9007199254740991:
        raise ControllerError("invalid_request", 400)
    epoch = int(raw_epoch)
    controller = request.app[CONTROLLER]
    ws = web.WebSocketResponse(protocols=("binary",), timeout=2, heartbeat=20,
                               compress=False, max_msg_size=65536)
    ws.headers.update(_HEADERS)
    bridge = _Bridge(ws)
    if mode == "control":
        connection_id = await controller.attach_control(request[DEVICE], epoch, bridge.close)
        upstream = request.app[CONTROL_SOCKET]
        forward = lambda data, send: controller.forward_control(connection_id, data, send)
    else:
        connection_id = await controller.register_viewer(bridge.close, epoch=epoch)
        upstream = request.app[VIEW_SOCKET]
        forward = lambda data, send: controller.forward_view(connection_id, data, send)
    try:
        await bridge.connect(upstream)
        await ws.prepare(request)
        if bridge.closing is not None:
            await ws.close()
            return ws
        await bridge.run(forward)
    finally:
        try:
            await bridge.close()
        finally:
            if mode == "control":
                await controller.detach_control(connection_id)
            else:
                await controller.unregister_viewer(connection_id)
    return ws


def create_app(controller: BrowserController, view_socket: str | Path,
               control_socket: str | Path, *, static_root: str | Path | None = None) -> web.Application:
    view, control = validate_private_socket(view_socket), validate_private_socket(control_socket)
    if view == control or view.parent != control.parent:
        raise ControllerError("socket_path_invalid", 503)
    app = web.Application(client_max_size=4096, middlewares=[_guard])
    app[CONTROLLER], app[VIEW_SOCKET], app[CONTROL_SOCKET] = controller, view, control
    app[STATIC_ROOT] = Path(static_root) if static_root else Path(__file__).parent / "static"
    for path in _STATIC:
        app.router.add_get(path, _static)
    app.router.add_get("/api/browser/state", _state)
    app.router.add_post("/api/browser/takeover", _takeover)
    app.router.add_post("/api/browser/release", _release)
    app.router.add_get("/api/browser/ws", _websocket)
    async def cleanup(application):
        await application[CONTROLLER].close()
    app.on_cleanup.append(cleanup)
    return app


@dataclass
class UnixGateway:
    runner: web.AppRunner
    path: Path
    inode: int
    _closing: asyncio.Task | None = field(default=None, init=False, repr=False)

    async def close(self) -> None:
        if self._closing is None:
            self._closing = asyncio.create_task(self._shutdown())
            self._closing.add_done_callback(
                lambda task: None if task.cancelled() else task.exception())
        await asyncio.shield(self._closing)

    async def _shutdown(self) -> None:
        try:
            await self.runner.cleanup()
        finally:
            try:
                await self.runner.app[CONTROLLER].close()
            finally:
                try:
                    info = self.path.lstat()
                    if stat.S_ISSOCK(info.st_mode) and info.st_ino == self.inode:
                        self.path.unlink()
                except FileNotFoundError:
                    pass


async def serve_unix(app: web.Application, path: str | Path) -> UnixGateway:
    """Bind only a private socket; refuse to unlink another instance's socket."""
    path = validate_private_socket(path, must_exist=False)
    if path.parent != app[VIEW_SOCKET].parent:
        raise ControllerError("socket_path_invalid", 503)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    runner = web.AppRunner(app, access_log=None, shutdown_timeout=5)
    bound = False
    try:
        listener.bind(str(path))
        bound = True
        path.chmod(0o600)
        listener.setblocking(False)
        listener.listen(64)
        inode = path.stat().st_ino
        await runner.setup()
        await web.SockSite(runner, listener).start()
        return UnixGateway(runner, path, inode)
    except BaseException:
        listener.close()
        await runner.cleanup()
        if bound:
            path.unlink(missing_ok=True)
        raise
