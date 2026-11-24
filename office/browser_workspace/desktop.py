"""A private Xvfb display and two replaceable TigerVNC RFB endpoints.

This service and its gateway are trusted, same-UID peers. Do not share their
UID, Xauthority, runtime mounts or profile mounts with untrusted agent code.
Only the display and RFB processes belong here; Chrome remains a separate port.
"""
from __future__ import annotations

import asyncio
import fcntl
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import sys

from .ports import BrowserWorkspaceError

_START_TIMEOUT = 10.0
_STOP_TIMEOUT = 3.0
_KILL_TIMEOUT = 3.0
_DISPLAY = re.compile(r":[0-9]{1,5}\Z")


def _require_unprivileged() -> None:
    if sys.platform != "linux":
        raise BrowserWorkspaceError("desktop_platform_unsupported")
    if os.geteuid() == 0:
        raise BrowserWorkspaceError("desktop_root_forbidden")


def _private(info: os.stat_result, kind, mode: int) -> bool:
    return (kind(info.st_mode) and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == mode)


def _open_runtime(path: Path) -> int:
    """Reject symlinks throughout the path, not only at the final component."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            info = os.fstat(fd)
            # A sticky /tmp is fine. Other writable ancestors allow another
            # UID to replace a private child directory after validation.
            if (info.st_uid not in (0, os.geteuid()) or
                    (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
                raise BrowserWorkspaceError("desktop_runtime_invalid")
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        if not _private(os.fstat(fd), stat.S_ISDIR, 0o700):
            raise BrowserWorkspaceError("desktop_runtime_invalid")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _clipboard_flags(help_text: str) -> list[str]:
    """Probe capabilities, with one source-verified legacy exception.

    TigerVNC v1.13.1 x0vncserver removes clipboard parameters because it has
    no clipboard implementation. Later builds must expose both off switches.
    https://github.com/TigerVNC/tigervnc/blob/v1.13.1/unix/x0vncserver/x0vncserver.cxx
    """
    version = re.search(r"TigerVNC(?: Server)?(?: version)?\s+(\d+\.\d+\.\d+)\b",
                        help_text, re.IGNORECASE)
    words = set(re.findall(r"\b[a-z][a-z0-9]*\b", help_text.lower()))
    required = {"display", "rfbport", "rfbunixpath", "rfbunixmode", "securitytypes",
                "acceptkeyevents", "acceptpointerevents", "acceptsetdesktopsize",
                "alwaysshared", "nevershared", "disconnectclients", "useshm", "framerate"}
    if not version or not required <= words:
        raise BrowserWorkspaceError("desktop_vnc_unsupported")
    clipboard = {"acceptcuttext", "sendcuttext"} & words
    if len(clipboard) == 2:
        return ["-AcceptCutText=0", "-SendCutText=0"]
    if not clipboard and version.group(1) == "1.13.1":
        return []
    raise BrowserWorkspaceError("desktop_vnc_unsupported")


class DesktopSession:
    """One-shot desktop session, used from one asyncio event loop.

    ``display=None`` lets Xvfb allocate a fresh display. An explicit ``:99``
    is supported, but an existing X lock/socket is never adopted or removed.
    ``environment()`` returns only DISPLAY/XAUTHORITY, after ``start()``.
    A child exit tears down its peers; ``wait_closed()`` then reports a fixed
    error code. The caller should stop Chrome when that happens, and call
    ``close()`` when Chrome or the enclosing runtime stops.
    """

    def __init__(self, runtime_dir: Path, display: str | None = None):
        self.runtime_dir = Path(runtime_dir).expanduser()
        if (not self.runtime_dir.is_absolute() or ".." in self.runtime_dir.parts
                or self.runtime_dir == Path("/")
                or (display is not None and not _DISPLAY.fullmatch(display))
                or len(os.fsencode(self.runtime_dir / "control.sock")) >= 108):
            raise BrowserWorkspaceError("desktop_runtime_invalid")
        self.view_socket = self.runtime_dir / "view.sock"
        self.control_socket = self.runtime_dir / "control.sock"
        self.xauthority = self.runtime_dir / "Xauthority"
        self._requested_display = display
        self._display: str | None = None
        self._state = "new"
        self._operation = asyncio.Lock()
        self._closed = asyncio.Event()
        self._failure: BrowserWorkspaceError | None = None
        self._runtime_fd: int | None = None
        self._lock_fd: int | None = None
        self._children: list[asyncio.subprocess.Process] = []
        self._daemons: list[asyncio.subprocess.Process] = []
        self._owned_paths: set[Path] = set()
        self._pending_spawn = None
        self._cleanup_task = None
        self._monitor = None

    def environment(self) -> dict[str, str]:
        if self._state != "running" or self._display is None:
            raise BrowserWorkspaceError("desktop_not_running")
        return {"DISPLAY": self._display, "XAUTHORITY": str(self.xauthority)}

    def _acquire(self) -> None:
        self._runtime_fd = _open_runtime(self.runtime_dir)
        self._lock_fd = os.open(".desktop.lock", os.O_RDWR | os.O_CREAT
                                | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                                dir_fd=self._runtime_fd)
        info = os.fstat(self._lock_fd)
        if not _private(info, stat.S_ISREG, 0o600) or info.st_nlink != 1:
            raise BrowserWorkspaceError("desktop_runtime_invalid")
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BrowserWorkspaceError("desktop_runtime_in_use") from None
        # A previous crashed service may have live children. Do not unlink its
        # sockets or authority and accidentally start a second desktop owner.
        if any(os.path.lexists(p) for p in
               (self.xauthority, self.view_socket, self.control_socket)):
            raise BrowserWorkspaceError("desktop_runtime_not_clean")

    async def _spawn(self, *args: str, **kwargs) -> asyncio.subprocess.Process:
        options = {"stdin": asyncio.subprocess.DEVNULL,
                   "stdout": asyncio.subprocess.DEVNULL,
                   "stderr": asyncio.subprocess.DEVNULL}
        options.update(kwargs)
        # Cancellation can arrive after fork but before create_subprocess_exec
        # returns. Retain that task so shutdown can still acquire and reap it.
        self._pending_spawn = asyncio.create_task(
            asyncio.create_subprocess_exec(*args, **options))
        self._pending_spawn.add_done_callback(
            lambda task: None if task.cancelled() else task.exception())
        child = await asyncio.wait_for(asyncio.shield(self._pending_spawn), _START_TIMEOUT)
        self._children.append(child)
        self._pending_spawn = None
        return child

    async def _prepare_authority(self, xauth: str) -> None:
        fd = os.open(self.xauthority, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                     | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        os.close(fd)
        self._owned_paths.add(self.xauthority)
        # FamilyWild (65535) matches Xvfb's as-yet unallocated display. The
        # private cookie database must be nonempty BEFORE Xvfb is started.
        # Numeric xauth records: family, address, display, auth-name, auth-data.
        cookie = secrets.token_hex(16)
        record = ("ffff 0000 0000 0012 4d49542d4d414749432d434f4f4b49452d31 "
                  f"0010 {cookie}\n").encode("ascii")
        child = await self._spawn(xauth, "-f", str(self.xauthority), "nmerge", "-",
                                  stdin=asyncio.subprocess.PIPE)
        await asyncio.wait_for(child.communicate(record), _START_TIMEOUT)
        info = self.xauthority.lstat()
        if (child.returncode != 0 or not _private(info, stat.S_ISREG, 0o600)
                or info.st_nlink != 1 or info.st_size == 0):
            raise BrowserWorkspaceError("desktop_xauthority_failed")

    def _vnc_arguments(self, socket: Path, *, control: bool,
                       clipboard: list[str]) -> list[str]:
        return [f"-display={self._display}", "-rfbport=-1",
                f"-rfbunixpath={socket}", "-rfbunixmode=0600",
                "-SecurityTypes=None", "-UseSHM=0", "-FrameRate=30",
                "-AcceptSetDesktopSize=0", *clipboard,
                f"-AcceptKeyEvents={int(control)}",
                f"-AcceptPointerEvents={int(control)}",
                f"-AlwaysShared={int(not control)}", f"-NeverShared={int(control)}",
                "-DisconnectClients=0"]

    async def _wait_socket(self, path: Path) -> None:
        async with asyncio.timeout(_START_TIMEOUT):
            while True:
                if any(child.returncode is not None for child in self._daemons):
                    raise BrowserWorkspaceError("desktop_process_exited")
                try:
                    info = path.lstat()
                except FileNotFoundError:
                    await asyncio.sleep(0.025)
                    continue
                if not _private(info, stat.S_ISSOCK, 0o600):
                    raise BrowserWorkspaceError("desktop_socket_invalid")
                return

    async def start(self) -> None:
        async with self._operation:
            if self._state != "new":
                raise BrowserWorkspaceError("desktop_already_started")
            self._state = "starting"
            try:
                _require_unprivileged()
                self._acquire()
                xvfb, xauth = shutil.which("Xvfb"), shutil.which("xauth")
                vnc = shutil.which("X0tigervnc") or shutil.which("x0vncserver")
                if not all((xvfb, xauth, vnc)):
                    raise BrowserWorkspaceError("desktop_dependency_missing")
                probe = await self._spawn(vnc, "-help", stdout=asyncio.subprocess.PIPE,
                                          stderr=asyncio.subprocess.STDOUT)
                output, _ = await asyncio.wait_for(probe.communicate(), _START_TIMEOUT)
                if probe.returncode not in (0, 1) or len(output) > 65536:
                    raise BrowserWorkspaceError("desktop_vnc_unsupported")
                clipboard = _clipboard_flags(output.decode("utf-8", errors="replace"))
                await self._prepare_authority(xauth)
                display_args = []
                if self._requested_display is not None:
                    number = self._requested_display[1:]
                    if any(os.path.lexists(p) for p in
                           (f"/tmp/.X{number}-lock", f"/tmp/.X11-unix/X{number}")):
                        raise BrowserWorkspaceError("desktop_display_busy")
                    display_args = [self._requested_display]
                display = await self._spawn(
                    xvfb, *display_args, "-displayfd", "1", "-screen", "0",
                    "1280x800x24", "-nolisten", "tcp", "-noreset", "-auth",
                    str(self.xauthority), stdout=asyncio.subprocess.PIPE, limit=256)
                self._daemons.append(display)
                line = await asyncio.wait_for(display.stdout.readline(), _START_TIMEOUT)
                if not re.fullmatch(rb"[0-9]{1,5}\n", line):
                    raise BrowserWorkspaceError("desktop_display_failed")
                self._display = ":" + line.decode("ascii").strip()
                if self._requested_display not in (None, self._display):
                    raise BrowserWorkspaceError("desktop_display_failed")
                env = {**os.environ, "DISPLAY": self._display,
                       "XAUTHORITY": str(self.xauthority)}
                for path, control in ((self.view_socket, False), (self.control_socket, True)):
                    self._owned_paths.add(path)
                    child = await self._spawn(
                        vnc, *self._vnc_arguments(path, control=control, clipboard=clipboard),
                        env=env)
                    self._daemons.append(child)
                    await self._wait_socket(path)
                self._state = "running"
                self._monitor = asyncio.create_task(self._watch_children())
                self._monitor.add_done_callback(
                    lambda task: None if task.cancelled() else task.exception())
            except BaseException as error:
                await self._cleanup()
                if isinstance(error, (BrowserWorkspaceError, asyncio.CancelledError,
                                      KeyboardInterrupt, SystemExit)):
                    raise
                raise BrowserWorkspaceError("desktop_start_failed") from None

    async def _watch_children(self) -> None:
        waits = [asyncio.create_task(child.wait()) for child in self._daemons]
        try:
            await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
            if self._state == "running":
                self._failure = BrowserWorkspaceError("desktop_process_exited")
                await self._cleanup()
        finally:
            for task in waits:
                task.cancel()
            await asyncio.gather(*waits, return_exceptions=True)

    async def wait_closed(self) -> None:
        await self._closed.wait()
        if self._failure is not None:
            raise self._failure

    async def close(self) -> None:
        async with self._operation:
            await self._cleanup()

    async def _cleanup(self) -> None:
        if self._cleanup_task is None:
            self._state = "closing"
            self._cleanup_task = asyncio.create_task(self._shutdown())
            self._cleanup_task.add_done_callback(
                lambda task: None if task.cancelled() else task.exception())
        await asyncio.shield(self._cleanup_task)

    async def _shutdown(self) -> None:
        try:
            if self._pending_spawn is not None:
                try:
                    child = await asyncio.wait_for(
                        asyncio.shield(self._pending_spawn), _START_TIMEOUT)
                    self._children.append(child)
                except (OSError, ValueError):
                    pass  # Failed before creating a child.
                self._pending_spawn = None
            for child in reversed(self._children):
                if child.returncode is None:
                    try:
                        child.terminate()
                    except ProcessLookupError:
                        pass
            try:
                await asyncio.wait_for(asyncio.gather(
                    *(child.wait() for child in self._children)), _STOP_TIMEOUT)
            except TimeoutError:
                for child in self._children:
                    if child.returncode is None:
                        try:
                            child.kill()
                        except ProcessLookupError:
                            pass
                await asyncio.wait_for(asyncio.gather(
                    *(child.wait() for child in self._children)), _KILL_TIMEOUT)
            for path in self._owned_paths:
                path.unlink(missing_ok=True)
            for name in ("_lock_fd", "_runtime_fd"):
                fd = getattr(self, name)
                if fd is not None:
                    os.close(fd)
                    setattr(self, name, None)
            self._display = None
            self._state = "closed"
        except Exception:
            # An uncertain shutdown retains the ownership lock and private
            # paths. A second close observes this same failed cleanup task.
            self._state = "failed"
            self._failure = BrowserWorkspaceError("desktop_shutdown_failed")
            raise self._failure from None
        finally:
            self._closed.set()
