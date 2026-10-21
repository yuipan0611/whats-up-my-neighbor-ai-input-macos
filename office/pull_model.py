"""Download a named local model via loopback Ollama and report phase changes."""
import json
import sys
import urllib.request
name = sys.argv[1] if len(sys.argv) > 1 else 'gemma3:1b'
if name not in ('gemma3:1b', 'gemma3:4b'):
    raise SystemExit('Unsupported test model')
req = urllib.request.Request('http://127.0.0.1:11434/api/pull', json.dumps({'model': name}).encode(), {'Content-Type': 'application/json'})
status = ''
with urllib.request.urlopen(req, timeout=1200) as r:
    for line in r:
        obj = json.loads(line)
        if 'error' in obj:
            raise SystemExit(obj['error'])
        if obj.get('status') != status:
            status = obj.get('status')
            print(status, flush=True)
with urllib.request.urlopen('http://127.0.0.1:11434/api/tags') as r:
    print(json.dumps(json.load(r), ensure_ascii=False), flush=True)
