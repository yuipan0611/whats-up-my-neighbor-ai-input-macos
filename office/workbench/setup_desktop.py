#!/usr/bin/env python3
"""Root installs launchers; the editor and official tools run as neko-hands."""
import json
from pathlib import Path
import subprocess

ROOT = Path('/home/neko-hands/workbench')

def main():
    ROOT.mkdir(mode=0o700, exist_ok=True)
    commands = {
        'Claude · 方案': ['/opt/neko-workbench/claude/claude'],
        'Codex · 實作': ['/opt/neko-hands/codex/codex-x86_64-unknown-linux-musl'],
        'Gemini · 檢查': ['/opt/neko-workbench/google/agy'],
    }
    folders = ['claude-plan', 'codex-work', 'gemini-review', 'results', 'tasks']
    for folder in folders:
        (ROOT / folder).mkdir(mode=0o700, exist_ok=True)
    tasks = []
    for (name, command), folder in zip(commands.items(), folders):
        tasks.append({'label': name, 'type': 'process', 'command': command[0],
                      'options': {'cwd': str(ROOT / folder), 'env': {'DISABLE_AUTOUPDATER': '1', 'AGY_CLI_DISABLE_AUTO_UPDATE': '1'}},
                      'presentation': {'reveal': 'always', 'panel': 'dedicated', 'group': 'agents', 'clear': False},
                      'problemMatcher': []})
    tasks.append({'label': '開啟三家 Agent', 'dependsOrder': 'parallel', 'dependsOn': list(commands), 'problemMatcher': []})
    workspace = {'folders': [{'name': folder, 'path': folder} for folder in folders],
                 'settings': {'telemetry.telemetryLevel': 'off', 'update.mode': 'manual',
                              'workbench.startupEditor': 'none', 'files.autoSave': 'off',
                              'terminal.integrated.defaultProfile.linux': 'bash'},
                 'tasks': {'version': '2.0.0', 'tasks': tasks}}
    (ROOT / '貓咪三家工作台.code-workspace').write_text(json.dumps(workspace, ensure_ascii=False, indent=2) + '\n')
    (ROOT / 'README.md').write_text('''# 貓咪三家工作台

平常在貓咪辦公室選「三家協作 · NekoNode 官網」交辦。
Claude 整理方案 → Codex 修改複本並透過 Docker 測試 → Gemini 檢查證據。
進度、測試紀錄與 patch 會交回對話窗；這個視窗用來查看或手動接手。

要手動開三家工具：終端機 → 執行工作 → 開啟三家 Agent。
Claude 與 Google 首次使用需要本人登入；請在工具的登入畫面完成，不要把授權碼貼進聊天。
手動終端與自動交辦是獨立工作階段，不會自動共享對話。
''')
    desktop = Path('/home/neko-hands/Desktop/貓咪三家工作台.desktop')
    launcher = Path('/opt/neko-workbench/open-editor')
    launcher.write_text('#!/bin/sh\nset -eu\nneko_uid=$(id -u)\nexec env XDG_RUNTIME_DIR=/run/user/"$neko_uid" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$neko_uid"/bus /usr/bin/code "$@"\n')
    launcher.chmod(0o755)
    desktop.write_text('[Desktop Entry]\nType=Application\nName=貓咪三家工作台\nComment=VS Code 與三家 Agent\nExec=/opt/neko-workbench/open-editor "' + str(ROOT / '貓咪三家工作台.code-workspace') + '"\nIcon=com.visualstudio.code\nTerminal=false\n')
    desktop.chmod(0o755)
    subprocess.run(['chown', '-R', 'neko-hands:neko-hands', str(ROOT), str(desktop)], check=True)
    subprocess.run(['runuser', '-u', 'neko-hands', '--', 'env', 'DISPLAY=:1',
                    'XAUTHORITY=/home/neko-hands/.Xauthority', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus',
                    'gio', 'set', str(desktop), 'metadata::trusted', 'true'], check=False)

if __name__ == '__main__':
    main()
