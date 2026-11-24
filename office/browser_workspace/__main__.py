"""Run a dedicated browser locally on the VPS display, without an agent."""
from __future__ import annotations

import argparse
import asyncio
import signal
import sys

from . import BrowserWorkspaceError, PlaywrightChromeProvider


async def _run(args: argparse.Namespace) -> None:
    provider = PlaywrightChromeProvider(args.profile_root, args.profile_id,
                                        headless=args.headless)
    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    loop.add_signal_handler(signal.SIGTERM, task.cancel)
    try:
        await provider.start()
        if args.url:
            await provider.navigate(args.url)
        print("Browser workspace started. Close Chrome or press Ctrl-C to stop.", flush=True)
        await provider.wait_closed()
    finally:
        await provider.close()
        loop.remove_signal_handler(signal.SIGTERM)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-root", required=True, help="Dedicated absolute directory outside Git")
    parser.add_argument("--profile-id", required=True, help="Lowercase identifier; one profile per trust scope")
    parser.add_argument("--headless", action="store_true", help="Test mode without a visible display")
    parser.add_argument("--url", help="Optional trusted HTTP(S) page; no URL is logged")
    args = parser.parse_args()
    try:
        asyncio.run(_run(args))
    except (KeyboardInterrupt, asyncio.CancelledError):
        return 130
    except BrowserWorkspaceError as error:
        print(f"Browser workspace stopped: {error.code}", file=sys.stderr)
        return 1
    except Exception:
        print("Browser workspace stopped: unexpected_failure", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
