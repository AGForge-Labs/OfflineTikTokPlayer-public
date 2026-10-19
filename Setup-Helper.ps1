$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
python -m venv .venv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$taskPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (Test-Path -LiteralPath 'requirements.lock.txt') {
    & $taskPython -m pip install -r requirements.lock.txt
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& $taskPython -m pip install -e '.[test]'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'Helper dependencies installed. Microsoft Edge, FFmpeg and FFprobe must also be available.'
