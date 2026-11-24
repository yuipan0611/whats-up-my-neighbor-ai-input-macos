"""Desktop lifecycle tests with real synthetic processes; no X/VNC required.

These exercise process ownership and Unix permissions, not RFB semantics.
Real Xvfb/TigerVNC/Chrome behavior is covered by the separate integration job.
"""
import asyncio
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

OFFICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OFFICE))
from browser_workspace import BrowserWorkspaceError
from browser_workspace import desktop


FLAGS = ("display rfbport rfbunixpath rfbunixmode SecurityTypes AcceptKeyEvents "
         "AcceptPointerEvents AcceptSetDesktopSize AlwaysShared NeverShared "
         "DisconnectClients UseSHM FrameRate")

# Stand-ins run as distinct processes and create actual Unix sockets. Nothing
# renders a screen, parses RFB, or impersonates the Chrome integration test.
SYNTHETIC = r'''
import os
from pathlib import Path
import signal
import socket
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "xauth":
    path = Path(args[args.index("-f") + 1])
    data = sys.stdin.buffer.read()
    path.write_bytes(bytes.fromhex(b"".join(data.split()).decode("ascii")))
    sys.exit(0)
if "-help" in args:
    print(Path(__file__).with_name("help.txt").read_text())
    sys.exit(1)
if Path(__file__).with_name("ignore-terminate").exists():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if name == "Xvfb":
    assert "-ac" not in args
    assert args[args.index("-nolisten") + 1] == "tcp"
    assert Path(args[args.index("-auth") + 1]).stat().st_size > 0
    print("31872", flush=True)
else:
    path = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-rfbunixpath="))
    if Path(__file__).with_name("fail-view").exists() and path.endswith("/view.sock"):
        print("synthetic-diagnostic-must-not-escape", file=sys.stderr)
        sys.exit(19)
    channel = socket.socket(socket.AF_UNIX)
    channel.bind(path)
    os.chmod(path, 0o600)
    channel.listen()
while True:
    signal.pause()
'''


class CapabilityTests(unittest.TestCase):
    def test_legacy_exception_requires_exact_version_and_all_other_flags(self):
        legacy = "TigerVNC Server version 1.13.1, built test\n" + FLAGS
        self.assertEqual(desktop._clipboard_flags(legacy), [])
        for invalid in (legacy.replace("1.13.1", "1.13.0"),
                        legacy.replace("AcceptKeyEvents", ""),
                        legacy + " AcceptCutText", "other-server\n" + FLAGS):
            with self.subTest(help=invalid):
                with self.assertRaises(BrowserWorkspaceError) as raised:
                    desktop._clipboard_flags(invalid)
                self.assertEqual(raised.exception.code, "desktop_vnc_unsupported")

    def test_modern_clipboard_requires_both_server_off_switches(self):
        help_text = ("TigerVNC Server version 1.16.2\n" + FLAGS
                     + " AcceptCutText SendCutText")
        self.assertEqual(desktop._clipboard_flags(help_text),
                         ["-AcceptCutText=0", "-SendCutText=0"])

    def test_root_is_refused(self):
        with patch.object(desktop.sys, "platform", "linux"), \
                patch.object(desktop.os, "geteuid", return_value=0):
            with self.assertRaises(BrowserWorkspaceError) as raised:
                desktop._require_unprivileged()
        self.assertEqual(raised.exception.code, "desktop_root_forbidden")


@unittest.skipUnless(sys.platform == "linux", "Linux desktop runtime")
class DesktopTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.runtime = self.base / "runtime"
        self.bin = self.base / "bin"
        self.bin.mkdir(mode=0o700)
        for name in ("xauth", "Xvfb", "X0tigervnc"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + SYNTHETIC)
            path.chmod(0o700)
        self.help = self.bin / "help.txt"
        self.help.write_text("TigerVNC Server version 1.13.1, built test\n" + FLAGS)
        self.children = []
        self.commands = []
        self.real_spawn = asyncio.create_subprocess_exec

        async def record_spawn(*args, **kwargs):
            self.commands.append((args, kwargs))
            child = await self.real_spawn(*args, **kwargs)
            self.children.append(child)
            return child

        # CI may itself be root. Only the synthetic process tests bypass this
        # guard; production rejects root, independently tested above.
        self.patchers = [patch.object(desktop, "_require_unprivileged"),
                         patch.object(desktop.shutil, "which",
                                      side_effect=lambda name: str(self.bin / name)
                                      if (self.bin / name).exists() else None),
                         patch.object(desktop.asyncio, "create_subprocess_exec",
                                      side_effect=record_spawn)]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    async def asyncTearDown(self):
        # A failed assertion should never leave synthetic desktop children.
        for child in self.children:
            if child.returncode is None:
                child.kill()
        await asyncio.gather(*(child.wait() for child in self.children))

    def session(self, **kwargs):
        session = desktop.DesktopSession(self.runtime, **kwargs)
        self.addAsyncCleanup(session.close)
        return session

    async def test_private_endpoints_flags_and_clean_shutdown(self):
        self.help.write_text("TigerVNC Server version 1.16.2\n" + FLAGS
                             + " AcceptCutText SendCutText")
        session = self.session()
        await session.start()
        self.assertEqual(session.environment(), {
            "DISPLAY": ":31872", "XAUTHORITY": str(session.xauthority)})
        for path, mode, kind in ((self.runtime, 0o700, stat.S_ISDIR),
                                 (session.xauthority, 0o600, stat.S_ISREG),
                                 (session.view_socket, 0o600, stat.S_ISSOCK),
                                 (session.control_socket, 0o600, stat.S_ISSOCK)):
            info = path.lstat()
            self.assertTrue(kind(info.st_mode))
            self.assertEqual(stat.S_IMODE(info.st_mode), mode)
        vnc = [args for args, _ in self.commands if "-rfbport=-1" in args]
        self.assertEqual(len(vnc), 2)
        for args in vnc:
            for flag in ("-UseSHM=0", "-FrameRate=30", "-AcceptSetDesktopSize=0",
                         "-AcceptCutText=0", "-SendCutText=0", "-rfbunixmode=0600"):
                self.assertIn(flag, args)
            self.assertIn("-display=:31872", args)
        for flag in ("-AcceptKeyEvents=0", "-AcceptPointerEvents=0", "-AlwaysShared=1"):
            self.assertIn(flag, vnc[0])
        for flag in ("-NeverShared=1", "-AlwaysShared=0", "-DisconnectClients=0"):
            self.assertIn(flag, vnc[1])
        auth = session.xauthority.read_bytes()
        cookie = auth[-16:].hex()
        self.assertNotIn(cookie, repr(self.commands))
        # The runner's gateway and unrelated files do not belong to desktop.
        unrelated = self.runtime / "keep-me"
        unrelated.write_text("keep")
        await session.close()
        await session.wait_closed()
        self.assertTrue(all(child.returncode is not None for child in self.children))
        self.assertFalse(session.xauthority.exists())
        self.assertFalse(session.view_socket.exists())
        self.assertFalse(session.control_socket.exists())
        self.assertEqual(unrelated.read_text(), "keep")

    async def test_legacy_omits_unsupported_clipboard_flags_and_locks_runtime(self):
        session = self.session()
        await session.start()
        for args, _ in self.commands:
            self.assertFalse(any("CutText" in arg for arg in args))
        other = self.session()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await other.start()
        self.assertEqual(raised.exception.code, "desktop_runtime_in_use")
        self.assertTrue(session.view_socket.exists())
        await session.close()
        replacement = self.session()
        await replacement.start()

    async def test_any_daemon_exit_stops_all_peers(self):
        session = self.session()
        await session.start()
        session._daemons[1].kill()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await asyncio.wait_for(session.wait_closed(), 3)
        self.assertEqual(raised.exception.code, "desktop_process_exited")
        self.assertTrue(all(child.returncode is not None for child in self.children))
        self.assertFalse(session.xauthority.exists())

    async def test_partial_launch_failure_reaps_display_and_sanitizes_error(self):
        (self.bin / "fail-view").touch()
        session = self.session()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await session.start()
        self.assertEqual(str(raised.exception), "desktop_process_exited")
        self.assertTrue(all(child.returncode is not None for child in self.children))
        self.assertIsNone(session._lock_fd)
        self.assertFalse(session.xauthority.exists())

    async def test_early_spawn_cancellation_keeps_ownership_until_child_reaped(self):
        created = asyncio.Event()
        return_gate = asyncio.Event()
        original = desktop.asyncio.create_subprocess_exec

        async def delayed_spawn(*args, **kwargs):
            child = await original(*args, **kwargs)
            if Path(args[0]).name == "Xvfb":
                created.set()
                await return_gate.wait()
            return child

        session = self.session()
        with patch.object(desktop.asyncio, "create_subprocess_exec", side_effect=delayed_spawn):
            starting = asyncio.create_task(session.start())
            await asyncio.wait_for(created.wait(), 3)
            starting.cancel()
            await asyncio.sleep(0)
            self.assertIsNotNone(session._lock_fd)
            self.assertIsNone(self.children[-1].returncode)
            return_gate.set()
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(starting, 3)
        self.assertTrue(all(child.returncode is not None for child in self.children))
        self.assertIsNone(session._lock_fd)

    async def test_cancelled_close_finishes_kill_escalation_and_releases_lock(self):
        (self.bin / "ignore-terminate").touch()
        session = self.session()
        await session.start()
        with patch.object(desktop, "_STOP_TIMEOUT", 0.15):
            closing = asyncio.create_task(session.close())
            await asyncio.sleep(0.025)
            closing.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await closing
            self.assertIsNotNone(session._lock_fd)
            await asyncio.wait_for(session.close(), 3)
        self.assertTrue(all(child.returncode is not None for child in self.children))
        self.assertIsNone(session._lock_fd)

    async def test_unknown_capabilities_fail_before_starting_a_desktop(self):
        self.help.write_text("TigerVNC Server version 1.14.0\n" + FLAGS)
        session = self.session()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await session.start()
        self.assertEqual(raised.exception.code, "desktop_vnc_unsupported")
        self.assertEqual(len(self.children), 1)
        self.assertTrue(all(child.returncode is not None for child in self.children))

    async def test_existing_display_is_not_adopted(self):
        session = self.session(display=":99")
        real_lexists = os.path.lexists
        with patch.object(desktop.os.path, "lexists",
                          side_effect=lambda path: str(path) == "/tmp/.X99-lock"
                          or real_lexists(path)):
            with self.assertRaises(BrowserWorkspaceError) as raised:
                await session.start()
        self.assertEqual(raised.exception.code, "desktop_display_busy")
        self.assertFalse(any(Path(args[0]).name == "Xvfb" for args, _ in self.commands))

    async def test_permissive_and_symlink_runtime_are_rejected(self):
        self.runtime.mkdir(mode=0o755)
        session = self.session()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await session.start()
        self.assertEqual(raised.exception.code, "desktop_runtime_invalid")
        self.runtime.rmdir()
        target = self.base / "target"
        target.mkdir(mode=0o700)
        self.runtime.symlink_to(target, target_is_directory=True)
        session = self.session()
        with self.assertRaises(BrowserWorkspaceError):
            await session.start()
        self.assertEqual(list(target.iterdir()), [])

    async def test_stale_authority_is_preserved_and_refused(self):
        self.runtime.mkdir(mode=0o700)
        authority = self.runtime / "Xauthority"
        authority.write_bytes(b"not ours")
        authority.chmod(0o600)
        session = self.session()
        with self.assertRaises(BrowserWorkspaceError) as raised:
            await session.start()
        self.assertEqual(raised.exception.code, "desktop_runtime_not_clean")
        self.assertEqual(authority.read_bytes(), b"not ours")


if __name__ == "__main__":
    unittest.main()
