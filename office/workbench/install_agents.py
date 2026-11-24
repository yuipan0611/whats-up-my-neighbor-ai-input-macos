#!/usr/bin/env python3
"""Install checksum-verified official tools, without reading or copying any sign-in."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install_agent_clis

def main():
    root = Path('/opt/neko-workbench')
    root.mkdir(mode=0o755, exist_ok=True)
    claude = install_agent_clis.install('claude', root)
    claude.chmod(0o755)
    (claude / 'claude').chmod(0o755)
    url = 'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json'
    manifest = json.load(urllib.request.urlopen(url, timeout=30))
    payload = urllib.request.urlopen(manifest['url'], timeout=180).read()
    if hashlib.sha512(payload).hexdigest() != manifest['sha512']:
        raise SystemExit('Antigravity SHA-512 mismatch')
    google = root / 'google'
    google.mkdir(mode=0o755, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
        member = archive.getmember('antigravity')
        if not member.isfile():
            raise SystemExit('Unexpected Google executable')
        (google / 'agy').write_bytes(archive.extractfile(member).read())
    (google / 'agy').chmod(0o755)
    (root / 'google-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name, binary in [('Claude', claude / 'claude'), ('Antigravity', google / 'agy')]:
        out = subprocess.run([str(binary), '--version'], capture_output=True, text=True, check=True, timeout=30)
        print(name, out.stdout.strip())

if __name__ == '__main__':
    main()
