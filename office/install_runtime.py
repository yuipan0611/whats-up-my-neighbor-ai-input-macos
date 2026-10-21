"""User-only Ollama installer. Run on the VPS, never requests sudo."""
import concurrent.futures
import hashlib
from pathlib import Path
import subprocess

VERSION = '0.40.7'
SIZE = 1505607169
SHA256 = '7f082e625b4c334df84ed1558fe282d6d8091fe3545790aef30b3a9c50d44d41'
URL = f'https://github.com/ollama/ollama/releases/download/v{VERSION}/ollama-linux-amd64.tar.zst'
root = Path.home() / 'neighbor-office/runtime/downloads'
root.mkdir(parents=True, exist_ok=True, mode=0o700)
archive = root / f'ollama-linux-amd64-v{VERSION}.tar.zst'
parts = 8

def download(i):
    start, end = SIZE * i // parts, SIZE * (i + 1) // parts - 1
    path = root / f'ollama-v{VERSION}.part{i}'
    if not path.exists() or path.stat().st_size != end - start + 1:
        subprocess.run(['curl', '-fLsS', '--retry', '3', '--max-time', '1800', '--range', f'{start}-{end}', URL, '-o', str(path)], check=True)
    if path.stat().st_size != end - start + 1:
        raise RuntimeError('Download server did not honor requested range')
    print(f'Part {i + 1}/{parts} downloaded', flush=True)
    return path

with concurrent.futures.ThreadPoolExecutor(max_workers=parts) as pool:
    paths = list(pool.map(download, range(parts)))
hash_ = hashlib.sha256()
with archive.open('wb') as out:
    for path in paths:
        with path.open('rb') as src:
            while data := src.read(1024 * 1024):
                hash_.update(data)
                out.write(data)
if hash_.hexdigest() != SHA256:
    raise RuntimeError('Ollama release SHA256 mismatch; not extracting')
print('Official release SHA256 verified', flush=True)
prefix = Path.home() / '.local/opt/neighbor-ollama'
prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
# Only CPU libraries; no CUDA/ROCm package or drivers are installed.
listing = subprocess.check_output(['tar', '--zstd', '-tf', str(archive)], text=True).splitlines()
members = [n for n in listing if n.rstrip('/') == 'bin/ollama' or (n.startswith('lib/ollama/') and '/' not in n[len('lib/ollama/'):] and ('ggml' in n or 'llama' in n))]
print('CPU runtime files:', members, flush=True)
subprocess.run(['tar', '--zstd', '-xf', str(archive), '-C', str(prefix), *members], check=True)
subprocess.run([str(prefix / 'bin/ollama'), '--version'], check=True)
for path in paths:
    path.unlink()
print('Runtime ready (archive retained for reproducibility)', flush=True)
