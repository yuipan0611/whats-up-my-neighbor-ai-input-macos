"""Pinned official Codex CLI and tool host; no sudo or credential migration."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
VERSION = '0.163.0'
ASSETS = [
    ('codex-x86_64-unknown-linux-musl', 'beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4', None),
    ('codex-code-mode-host-x86_64-unknown-linux-musl', '314263128ba6592e7e807c265deeaf928a692b72dcbfeb5e0b20c9423b703529', 'codex-code-mode-host'),
    ('bwrap-x86_64-unknown-linux-musl', 'bcc196b1d25dc2c2b912dcedf780b562deb0552f3c50648761ced145c3466a23', 'bwrap'),
]
root = Path.home()/'neighbor-office/runtime/codex'
root.mkdir(parents=True, exist_ok=True, mode=0o700)
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while data := f.read(1024*1024): h.update(data)
    return h.hexdigest()
for name, expected, alias in ASSETS:
    archive = root/(name+'-'+VERSION+'.tar.gz')
    legacy = root/('codex-'+VERSION+'.tar.gz')
    if name.startswith('codex-x86') and legacy.exists() and digest(legacy)==expected:
        archive = legacy
    if not archive.exists() or digest(archive)!=expected:
        url = f'https://github.com/openai/codex/releases/download/rust-v{VERSION}/{name}.tar.gz'
        subprocess.run(['curl','-fLsS','--retry','3',url,'-o',str(archive)],check=True)
    if digest(archive)!=expected: raise SystemExit('Official release checksum mismatch: '+name)
    with tarfile.open(archive) as tar:
        members=tar.getmembers()
        if len(members)!=1 or not members[0].isfile() or Path(members[0].name).name!=members[0].name:
            raise SystemExit('Unexpected official archive layout')
        member=members[0]
        source=root/member.name
        with tar.extractfile(member) as src, source.open('wb') as dst: shutil.copyfileobj(src,dst)
        source.chmod(0o700)
        if alias and source.name!=alias:
            target=root/alias
            if target.is_symlink(): target.unlink()
            shutil.copyfile(source,target);target.chmod(0o700)
    print(name+': official SHA256 verified',flush=True)
subprocess.run([str(root/'codex-x86_64-unknown-linux-musl'),'--version'],check=True)
