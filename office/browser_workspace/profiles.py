"""Private, dedicated profiles and a local-process exclusive ownership lock.

This is not a distributed lease or an isolation boundary against the same UID.
The deployment owner must keep this tree out of agent/code-runner mounts.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat

from .ports import BrowserWorkspaceError

_MARKER = b"nekonode-browser-workspace-v1\n"
_PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,47}\Z")


def _is_git_worktree(path: Path) -> bool:
    marker = path / ".git"
    if marker.is_dir():
        return (marker / "HEAD").is_file()
    if marker.is_file():
        with marker.open("rb") as stream:
            prefix = stream.read(128)
        return prefix.startswith(b"gitdir:") and bool(prefix[7:].strip())
    return False


def _check_private(fd: int, *, directory: bool) -> None:
    info = os.fstat(fd)
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or (not directory and info.st_nlink != 1)):
        raise BrowserWorkspaceError("profile_permissions_invalid")


def _open_root(root: Path) -> int:
    # Walk with directory descriptors: neither the root nor an ancestor may
    # silently redirect through a symlink. Missing directories are private.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(root.anchor, flags)
    try:
        for part in root.parts[1:]:
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        _check_private(fd, directory=True)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _claim_root(fd: int) -> None:
    """Do not adopt an existing daily-browser profile or unrelated directory."""
    name = ".nekonode-browser-root"
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        marker_fd = os.open(name, flags, dir_fd=fd)
    except FileNotFoundError:
        if os.listdir(fd):
            raise BrowserWorkspaceError("profile_root_not_dedicated") from None
        try:
            marker_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
        except FileExistsError:
            marker_fd = os.open(name, flags, dir_fd=fd)
        else:
            try:
                os.write(marker_fd, _MARKER)
                os.fsync(marker_fd)
            finally:
                os.close(marker_fd)
            marker_fd = os.open(name, flags, dir_fd=fd)
    try:
        _check_private(marker_fd, directory=False)
        if os.read(marker_fd, len(_MARKER) + 1) != _MARKER:
            raise BrowserWorkspaceError("profile_root_not_dedicated")
    finally:
        os.close(marker_fd)


class ProfileLease:
    def __init__(self, root: str | Path, profile_id: str):
        root = Path(root).expanduser()
        if (not isinstance(profile_id, str) or not _PROFILE_ID.fullmatch(profile_id)
                or not root.is_absolute() or ".." in root.parts or root == Path("/")):
            raise BrowserWorkspaceError("profile_path_invalid")
        if any(_is_git_worktree(part) for part in (root, *root.parents)):
            raise BrowserWorkspaceError("profile_root_in_repository")
        self.path = root / profile_id
        self._root = root
        self._profile_id = profile_id
        self._lock_fd: int | None = None
        self._root_fd: int | None = None

    def acquire(self) -> Path:
        if self._lock_fd is not None:
            raise BrowserWorkspaceError("profile_already_acquired")
        if os.name != "posix":
            raise BrowserWorkspaceError("platform_unsupported")
        import fcntl

        try:
            self._root_fd = _open_root(self._root)
            _claim_root(self._root_fd)
            self._lock_fd = os.open(
                f".{self._profile_id}.lock",
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600, dir_fd=self._root_fd)
            _check_private(self._lock_fd, directory=False)
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BrowserWorkspaceError("profile_in_use") from None
            try:
                os.mkdir(self._profile_id, 0o700, dir_fd=self._root_fd)
            except FileExistsError:
                pass
            profile_fd = os.open(self._profile_id, os.O_RDONLY | os.O_DIRECTORY
                                 | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self._root_fd)
            try:
                _check_private(profile_fd, directory=True)
            finally:
                os.close(profile_fd)
            return self.path
        except BaseException as error:
            self.release()
            if isinstance(error, (BrowserWorkspaceError, KeyboardInterrupt, SystemExit)):
                raise
            raise BrowserWorkspaceError("profile_path_invalid") from None

    def release(self) -> None:
        # Keep the lock file: unlinking it can give two processes different
        # inodes to lock. Closing the descriptor releases flock, including crash.
        for name in ("_lock_fd", "_root_fd"):
            fd = getattr(self, name)
            if fd is not None:
                os.close(fd)
                setattr(self, name, None)
