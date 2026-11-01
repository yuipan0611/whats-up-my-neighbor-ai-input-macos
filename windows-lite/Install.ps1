# Per-user installation of an extracted CI trial ZIP. No administrator rights.
$ErrorActionPreference = 'Stop'
if (Get-Process -Name 'NekoChat.Windows' -ErrorAction SilentlyContinue) {
    throw '請先從貓咪右鍵選單離開 NekoChat，再重新執行安裝。'
}
$source = $PSScriptRoot
if (!(Test-Path (Join-Path $source 'NekoChat.Windows.exe'))) { throw '請先完整解壓縮試用 ZIP。' }
$destination = Join-Path $env:LOCALAPPDATA 'Programs/NekoChat.WindowsLite'
if ([IO.Path]::GetFullPath($source).TrimEnd('\') -eq [IO.Path]::GetFullPath($destination).TrimEnd('\')) {
    throw '已在安裝資料夾內。請直接啟動 NekoChat.Windows.exe。'
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'NekoChat Windows Lite.lnk'))
$shortcut.TargetPath = Join-Path $destination 'NekoChat.Windows.exe'
$shortcut.WorkingDirectory = $destination
$shortcut.Save()
Write-Output '安裝完成，請從開始功能表開啟 NekoChat Windows Lite。'
