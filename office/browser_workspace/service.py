"""Run the dedicated VPS Chrome/display service; never requires a local Mac."""
from __future__ import annotations

import argparse
import asyncio
import os
from pathlib import Path
import signal
import socket
import stat
import sys

from . import BrowserWorkspaceError, PlaywrightChromeProvider
from .controller import BrowserController
from .desktop import DesktopSession
from .gateway import create_app, serve_unix, validate_private_socket


def remove_stale_gateway(path: Path) -> None:
    """Only after DesktopSession holds this runtime's exclusive process lock."""
    if not path.exists() and not path.is_symlink():
        return
    validate_private_socket(path)
    original = path.lstat()
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(.25)
    try:
        probe.connect(str(path))
    except ConnectionRefusedError:
        current = path.lstat()
        if current.st_ino == original.st_ino and stat.S_ISSOCK(current.st_mode):
            path.unlink()
            return
    finally:
        probe.close()
    raise BrowserWorkspaceError('gateway_already_running')


async def run(args) -> None:
    os.umask(0o077)
    desktop = DesktopSession(args.runtime_dir, display=args.display)
    provider = PlaywrightChromeProvider(args.profile_root, args.profile_id, headless=False)
    controller = BrowserController(provider)
    gateway = None
    watchers = []
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopped.set)
    try:
        await desktop.start()
        # This is a dedicated service process, not an Office request thread.
        os.environ.update(desktop.environment())
        gateway_path = args.runtime_dir / 'gateway.sock'
        remove_stale_gateway(gateway_path)
        await controller.start()
        app = create_app(controller, desktop.view_socket, desktop.control_socket)
        gateway = await serve_unix(app, gateway_path)
        print('Browser workspace ready; waiting for an authenticated Office viewer.', flush=True)
        watchers = [asyncio.create_task(stopped.wait()),
                    asyncio.create_task(desktop.wait_closed()),
                    asyncio.create_task(provider.wait_closed())]
        completed, _ = await asyncio.wait(watchers, return_when=asyncio.FIRST_COMPLETED)
        for task in completed:
            task.result()
    finally:
        for task in watchers:
            task.cancel()
        if watchers:
            await asyncio.gather(*watchers, return_exceptions=True)
        try:
            if gateway:
                await gateway.close()
            else:
                await controller.close()
        finally:
            await desktop.close()
            for sig in (signal.SIGTERM, signal.SIGINT):
                loop.remove_signal_handler(sig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile-root', type=Path, required=True)
    parser.add_argument('--profile-id', required=True)
    parser.add_argument('--runtime-dir', type=Path, required=True)
    parser.add_argument('--display', help='Optional unused X display, otherwise automatically allocated')
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except (KeyboardInterrupt, asyncio.CancelledError):
        return 130
    except BrowserWorkspaceError as error:
        print(f'Browser service stopped: {error.code}', file=sys.stderr)
        return 1
    except Exception:
        print('Browser service stopped: startup_or_runtime_failed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
