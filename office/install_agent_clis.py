"""Pinned official Claude Code and Gemini CLI for the office's brain executors (ADR-003 P2/P4).

Run on the VPS as the office's own user; never requests sudo, never copies a login. Each package
is the npm registry tarball, checked against the SHA-512 pinned here before anything is unpacked.
Logging in is a separate step the owner does in person (ADR-003 3.4).

    python3 -I install_agent_clis.py claude|gemini|all [--runtime ~/neighbor-office/runtime]
"""
import argparse
import base64
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

PACKAGES = {
    # The version whose stream events, tool list and error codes the office was checked against.
    'claude': {'version': '2.1.183', 'url': 'https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.183.tgz',
               'integrity': 'sha512-Ik4jBKW40pYyheJ+p890DMIPGgeFXuuCwQV4fWGHAyCEuBYoFYmTWiNEJIFZqIhbbX0YxfOhxacQ/xZSp6kvEw=='},
    # Gemini CLI is one bundled script with no required dependencies, run by the system's Node (>= 20).
    'gemini': {'version': '0.47.0', 'url': 'https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-0.47.0.tgz',
               'integrity': 'sha512-cg0Y3X2bwJD7lyjD6lodyR6VeNXDmzqC7JqjZKf6cYVIImIwdPX5ARgOewOnkEufb3MwZe9SRl4G49IfdEvCuQ=='},
}


def integrity(data):
    return 'sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode()


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def safe_members(archive):
    members = archive.getmembers()
    for member in members:
        path = Path(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'package' or not (member.isfile() or member.isdir()):
            raise SystemExit('Unexpected package layout: ' + member.name)
    return members


def install(name, runtime, download=fetch):
    package = PACKAGES[name]
    data = download(package['url'])
    if integrity(data) != package['integrity']:
        raise SystemExit(f'{name} {package["version"]}: SHA-512 mismatch, nothing was installed')
    root = Path(runtime) / name
    staging = Path(runtime) / f'.{name}-{package["version"]}.partial'
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(mode=0o700, parents=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        archive.extractall(staging, members=safe_members(archive))
    unpacked = staging / 'package'
    if name == 'claude':
        if not (unpacked / 'claude').is_file():
            raise SystemExit('Unexpected package layout: no claude binary')
        (unpacked / 'claude').chmod(0o700)
    else:
        if not (unpacked / 'bundle/gemini.js').is_file():
            raise SystemExit('Unexpected package layout: no bundle/gemini.js')
        # What GeminiAgent runs: a launcher that hands the bundled script to the system's Node.
        (unpacked / 'gemini').write_text('#!/bin/sh\nexec node "$(dirname "$0")/bundle/gemini.js" "$@"\n')
        (unpacked / 'gemini').chmod(0o700)
    (unpacked / 'VERSION').write_text(package['version'] + '\n')
    # Swap in whole, so a running office never sees a half-unpacked CLI; logins live elsewhere and stay.
    old = Path(runtime) / f'.{name}.old'
    shutil.rmtree(old, ignore_errors=True)
    if root.exists():
        root.rename(old)
    unpacked.rename(root)
    root.chmod(0o700)
    shutil.rmtree(staging, ignore_errors=True)
    shutil.rmtree(old, ignore_errors=True)
    return root


def check_version(name, root):
    env = {k: os.environ[k] for k in ('HOME', 'PATH', 'LANG') if k in os.environ}
    env.update(DISABLE_AUTOUPDATER='1', CLAUDE_CONFIG_DIR=str(root.parent / 'claude-home'), GEMINI_CLI_HOME=str(root.parent / 'gemini-home'))
    out = subprocess.run([str(root / name), '--version'], env=env, capture_output=True, text=True, timeout=60, check=True)
    return out.stdout.strip()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('which', choices=('claude', 'gemini', 'all'))
    parser.add_argument('--runtime', type=Path, default=Path.home() / 'neighbor-office/runtime')
    args = parser.parse_args(argv)
    for name in (('claude', 'gemini') if args.which == 'all' else (args.which,)):
        root = install(name, args.runtime)
        print(f'{name}: official SHA-512 verified, {check_version(name, root)}', flush=True)


if __name__ == '__main__':
    sys.exit(main())
