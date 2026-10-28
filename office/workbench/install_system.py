#!/usr/bin/env python3
"""Run as root on the existing VPS. Keep packages and bounded Docker storage separate from Office data."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path('/home/neighbor/neighbor-office/workbench-install')
VOLUME = Path('/home/neighbor/neighbor-office/sandbox-storage')
DISK = Path('/var/lib/neko-workbench/docker.ext4')

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root on the VPS')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest = json.load(urllib.request.urlopen('https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest', timeout=30))
    package = ROOT / ('code-' + manifest['productVersion'] + '.deb')
    if not package.exists():
        urllib.request.urlretrieve(manifest['url'], package)
    if hashlib.sha256(package.read_bytes()).hexdigest() != manifest['sha256hash']:
        raise SystemExit('VS Code SHA-256 mismatch')
    (ROOT / 'vscode-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    os.environ.update(DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
    run('apt-get', 'update', '-qq')
    run('apt-get', 'install', '-y', 'uidmap', 'slirp4netns', 'fuse-overlayfs', str(package))
    # This is a new, dedicated, preallocated filesystem: no existing filesystem is formatted.
    if not DISK.exists():
        DISK.parent.mkdir(mode=0o700, exist_ok=True)
        run('fallocate', '-l', '16G', str(DISK))
        run('mkfs.ext4', '-q', '-E', 'nodiscard', '-m', '0', '-L', 'neko-workbench', str(DISK))
    VOLUME.mkdir(parents=True, exist_ok=True)
    if not os.path.ismount(VOLUME):
        if any(VOLUME.iterdir()):
            raise SystemExit('Storage mountpoint is not empty; refusing to hide files')
        run('mount', '-o', 'loop,nosuid,nodev', str(DISK), str(VOLUME))
    run('chown', 'neighbor:neighbor', str(VOLUME))
    VOLUME.chmod(0o700)
    fstab = Path('/etc/fstab')
    entry = f'{DISK} {VOLUME} ext4 loop,nosuid,nodev,nofail 0 0 # neko-workbench\n'
    if '# neko-workbench' not in fstab.read_text():
        with fstab.open('a') as out:
            out.write('\n' + entry)
    config = Path('/home/neighbor/.config/docker/daemon.json')
    config.parent.mkdir(parents=True, exist_ok=True)
    settings = json.loads(config.read_text()) if config.exists() else {}
    if settings.get('data-root') not in (None, str(VOLUME / 'docker')):
        raise SystemExit('An unrelated rootless Docker data root exists')
    settings.update({'data-root': str(VOLUME / 'docker'), 'log-driver': 'local',
                     'log-opts': {'max-size': '5m', 'max-file': '2'}})
    config.write_text(json.dumps(settings, indent=2) + '\n')
    run('chown', '-R', 'neighbor:neighbor', str(config.parent))
    env = ['env', 'XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']
    run('runuser', '-u', 'neighbor', '--', *env, 'dockerd-rootless-setuptool.sh', 'install', '--force')
    drop = Path('/home/neighbor/.config/systemd/user/docker.service.d')
    drop.mkdir(parents=True, exist_ok=True)
    firewall=Path('/opt/neko-workbench/rootless-firewall.sh')
    if not firewall.is_file():
        raise SystemExit('Install the rootless firewall before enabling Docker')
    (drop / 'workbench.conf').write_text('[Unit]\nRequiresMountsFor=' + str(VOLUME) + '\n\n[Service]\nEnvironment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns\nMemoryMax=3G\nCPUQuota=200%\nExecStartPost=' + str(firewall) + '\n')
    run('chown', '-R', 'neighbor:neighbor', str(drop))
    run('runuser', '-u', 'neighbor', '--', *env, 'systemctl', '--user', 'daemon-reload')
    run('runuser', '-u', 'neighbor', '--', *env, 'systemctl', '--user', 'restart', 'docker')
    run('runuser', '-u', 'neighbor', '--', *env, 'systemctl', '--user', 'enable', 'docker')
    run('runuser', '-u', 'neighbor', '--', *env, 'docker', '--context', 'rootless', 'info', '--format', '{{json .SecurityOptions}} {{.CgroupDriver}}')
    print('System installation complete; existing rootful Docker and Office service preserved.')

if __name__ == '__main__':
    main()
