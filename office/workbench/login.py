#!/usr/bin/env python3
"""Launch official sign-in in a user-owned TTY. Never read codes or copy credentials."""
import os
from pathlib import Path
import sys

name=sys.argv[1]
if name not in ('claude','google'): raise SystemExit('choose claude or google')
env={k:os.environ[k] for k in ('SSH_CONNECTION','SSH_CLIENT','SSH_TTY','TERM') if k in os.environ}
env.update(HOME='/home/neko-hands',PATH='/usr/bin:/bin',LANG='C.UTF-8',
           XDG_RUNTIME_DIR='/run/user/1001',DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1001/bus',
           DISABLE_AUTOUPDATER='1',AGY_CLI_DISABLE_AUTO_UPDATE='1')
command='/opt/neko-workbench/claude/claude auth login --claudeai' if name=='claude' else '/opt/neko-workbench/google/agy'
print('\n'+('Claude 訂閱登入' if name=='claude' else 'Google Antigravity 個人帳號登入')+'\n請在 Mac 瀏覽器完成登入。授權碼只貼回這個視窗，不要貼到聊天。\n',flush=True)
args=['runuser','-u','neko-hands','--','env','-i',*[k+'='+v for k,v in env.items()],
      'script','-q','-c',command,'/dev/null']
os.execv('/usr/sbin/runuser',args)
