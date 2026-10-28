#!/usr/bin/env python3
"""Small stdio MCP client of a per-task proxy. Holds no Office lease or Docker socket."""
import argparse
import json
import socket
import sys

TOOLS = {
    'list_files': ('列出這次固定版本的檔案。', {}),
    'read_file': ('讀取專案複本的 UTF-8 文字檔。', {'path':{'type':'string'}}),
    'write_file': ('在 Docker 複本裡寫入檔案；不會修改主機或 GitHub。', {'path':{'type':'string'},'text':{'type':'string'}}),
    'delete_file': ('刪除 Docker 複本內的檔案。', {'path':{'type':'string'}}),
    'run_checks': ('執行官網鎖定依賴、型別、內容、語音測試及建置。每件任務只能開始一次。', {}),
    'run_status': ('查看測試狀態與已保存的紀錄。', {}),
}

def call(path, request):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sock:
        sock.settimeout(120)
        sock.connect(path)
        sock.sendall(json.dumps(request,ensure_ascii=False).encode()+b'\n')
        data=b''
        while not data.endswith(b'\n'):
            part=sock.recv(65536)
            if not part: break
            data+=part
            if len(data)>2_000_000: raise ValueError('response too large')
    return json.loads(data)

def serve(path,stdin=sys.stdin,stdout=sys.stdout):
    for line in stdin:
        if len(line)>1_500_000: continue
        try: request=json.loads(line)
        except ValueError: continue
        mid,method=request.get('id'),request.get('method')
        if mid is None: continue
        if method=='initialize':
            result={'protocolVersion':request.get('params',{}).get('protocolVersion','2025-06-18'),
                    'capabilities':{'tools':{}},'serverInfo':{'name':'neko-project','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':name,'description':desc,'inputSchema':{'type':'object','properties':schema,
                             'required':list(schema),'additionalProperties':False}} for name,(desc,schema) in TOOLS.items()]}
        elif method=='tools/call':
            params=request.get('params',{})
            name,args=params.get('name'),params.get('arguments',{})
            try:
                if name not in TOOLS or not isinstance(args,dict) or set(args)!=set(TOOLS[name][1]):
                    raise ValueError('invalid tool')
                reply=call(path,{'tool':name,'args':args})
                result={'content':[{'type':'text','text':json.dumps(reply.get('body',{}),ensure_ascii=False)}],
                        'isError':reply.get('status')!=200}
            except (OSError,ValueError):
                result={'content':[{'type':'text','text':'專案工具沒有回報完整結果，請停止並核對；不要自行改在主機執行。'}],'isError':True}
        elif method=='ping': result={}
        else:
            stdout.write(json.dumps({'jsonrpc':'2.0','id':mid,'error':{'code':-32601,'message':'method not found'}})+'\n'); stdout.flush(); continue
        stdout.write(json.dumps({'jsonrpc':'2.0','id':mid,'result':result},ensure_ascii=False)+'\n'); stdout.flush()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket',required=True)
    serve(parser.parse_args().socket)
