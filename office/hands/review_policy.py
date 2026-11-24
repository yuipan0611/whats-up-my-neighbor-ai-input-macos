"""Per-workspace Google review policy, with a root-owned proof for the exact installed CLI and gate."""
import hashlib
import json
from pathlib import Path
import shlex

GATE=Path(__file__).with_name('review_gate.py')
PROOF=Path('/opt/neko-workbench/google-review-verified.json')

def install(folder):
    folder=Path(folder)
    hooks=folder/'.agents'; hooks.mkdir(mode=0o700,exist_ok=True)
    audit=hooks/'tool-denials.jsonl'
    command=shlex.join(['/usr/bin/python3','-I',str(GATE),'--audit',str(audit)])
    config={'neko-text-review':{'PreToolUse':[{'matcher':'*','hooks':[{'type':'command','command':command,'timeout':5}]}]}}
    (hooks/'hooks.json').write_text(json.dumps(config,indent=2)+'\n')
    return audit

def fingerprints(binary):
    return {'cli_sha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            'gate_sha256':hashlib.sha256(GATE.read_bytes()).hexdigest()}

def verified(binary):
    try:
        info=PROOF.stat()
        if info.st_uid!=0 or info.st_mode&0o022: return False
        proof=json.loads(PROOF.read_text())
        return proof.get('verified') is True and all(proof.get(k)==v for k,v in fingerprints(binary).items())
    except (OSError,ValueError): return False
