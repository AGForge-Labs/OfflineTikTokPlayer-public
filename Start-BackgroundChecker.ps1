$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$taskPython = Join-Path $PSScriptRoot '.venv\Scripts\pythonw.exe'
if (-not (Test-Path -LiteralPath $taskPython)) {
    Write-Host 'Run Setup-Helper.ps1 first.'
    exit 1
}
Start-Process -FilePath $taskPython -ArgumentList '-m', 'offline_tiktok.gui', '--background' -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
