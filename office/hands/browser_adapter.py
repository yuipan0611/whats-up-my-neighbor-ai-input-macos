#!/usr/bin/env python3
"""The agent's only browser tools in broker mode: a small MCP server over stdio (G3).

Six fixed tools. Each call goes to the worker's proxy socket, which adds the task, lease and
control epoch and forwards it to the office broker. This process never sees the lease, and
there is no raw-browser fallback: if the proxy is down, the tool fails. Python standard library only."""
from __future__ import annotations
import argparse
import json
import socket
import sys
import uuid

TOOLS = [
    {'name': 'observe_page', 'broker': 'take_snapshot', 'description': '列出目前頁面上可以操作的連結、按鈕與輸入框，回傳 snapshot_id 與每個目標的 ref。',
     'schema': {}},
    {'name': 'read_page', 'broker': 'read_text', 'description': '讀出目前頁面的標題與可見文字。', 'schema': {}},
    {'name': 'screenshot', 'broker': 'take_screenshot', 'description': '把目前頁面截圖存起來，回傳檔名。', 'schema': {}},
    {'name': 'open_url', 'broker': 'navigate', 'description': '打開一個 http(s) 網址。', 'schema': {'url': {'type': 'string'}}},
    {'name': 'click', 'broker': 'click', 'description': '點擊 observe_page 回傳的某個目標。按鈕與會造成效果的操作會交給使用者親手做。',
     'schema': {'snapshot_id': {'type': 'string'}, 'target_ref': {'type': 'string'}}},
    {'name': 'type_text', 'broker': 'type_text', 'description': '在某個輸入框輸入文字。這一步會交給使用者親手做。',
     'schema': {'snapshot_id': {'type': 'string'}, 'target_ref': {'type': 'string'}, 'text': {'type': 'string'}}},
]
BY_NAME = {t['name']: t for t in TOOLS}


def proxy_call(path, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(60)
        s.connect(path)
        s.sendall(json.dumps(request, ensure_ascii=False).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def tool_result(text, error=False):
    return {'content': [{'type': 'text', 'text': text}], 'isError': error}


def call_tool(proxy, name, arguments):
    tool = BY_NAME.get(name)
    if tool is None or not isinstance(arguments, dict) or not set(arguments) <= set(tool['schema']):
        return tool_result('沒有這個工具，或參數不對。', True)
    request = {'tool': tool['broker'], 'action_id': str(uuid.uuid4()),
               'args': {k: arguments[k] for k in ('url', 'text') if k in arguments},
               **{k: arguments[k] for k in ('snapshot_id', 'target_ref') if k in arguments}}
    try:
        reply = proxy_call(proxy, request)
    except (OSError, ValueError):
        return tool_result('瀏覽器入口連不上，這一步沒有執行。', True)
    status, body = reply.get('status'), reply.get('body') or {}
    decision = body.get('decision')
    if decision == 'needs_human':
        return tool_result('這一步要由使用者親手做（' + str(body.get('reason_code')) + '），沒有執行。請停在這裡，在成果寫明使用者要按哪裡。')
    if status == 200 and body.get('outcome') == 'succeeded':
        return tool_result(json.dumps(body.get('result', {}), ensure_ascii=False))
    reason = body.get('reason_code') or body.get('error') or f'status {status}'
    hint = '；請先用 observe_page 重新觀察' if reason in ('stale_target', 'stale_snapshot', 'stale_epoch', 'unknown_target') else ''
    return tool_result(f'這一步沒有完成：{reason}{hint}。', True)


def serve(proxy, stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, mid = message.get('method'), message.get('id')
        if mid is None:
            continue  # notifications need no answer
        if method == 'initialize':
            result = {'protocolVersion': message.get('params', {}).get('protocolVersion', '2025-06-18'),
                      'capabilities': {'tools': {}}, 'serverInfo': {'name': 'neko-browser', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': t['name'], 'description': t['description'],
                                 'inputSchema': {'type': 'object', 'properties': t['schema'], 'required': list(t['schema']),
                                                 'additionalProperties': False}} for t in TOOLS]}
        elif method == 'tools/call':
            params = message.get('params') or {}
            result = call_tool(proxy, params.get('name'), params.get('arguments') or {})
        elif method == 'ping':
            result = {}
        else:
            stdout.write(json.dumps({'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'method not found'}}) + '\n')
            stdout.flush()
            continue
        stdout.write(json.dumps({'jsonrpc': '2.0', 'id': mid, 'result': result}, ensure_ascii=False) + '\n')
        stdout.flush()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--socket', required=True)
    serve(parser.parse_args().socket)
