#!/usr/bin/env python3
"""Official Antigravity PreToolUse gate: this review role uses supplied evidence only."""
import argparse
import json
from pathlib import Path
import sys

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--audit',type=Path)
    args=parser.parse_args()
    # Consume the hook envelope, but never record arguments, file contents, URLs or credentials.
    data=sys.stdin.buffer.read(4_000_001)
    try: request=json.loads(data)
    except ValueError: request={}
    if args.audit:
        with args.audit.open('a') as out:
            out.write(json.dumps({'denied':True,'tool':str(request.get('toolCall',{}).get('name','unknown'))[:100]})+'\n')
    print(json.dumps({'decision':'deny','reason':'這個角色只檢查已提供的證據，不執行檔案、指令、網路或其他工具。'},ensure_ascii=False))

if __name__=='__main__': main()
