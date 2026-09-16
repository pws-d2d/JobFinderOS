# Entry point for the Windows Task Scheduler job created by
# JobFinderOS_install_task_scheduler.ps1. Runs one scheduler_tick.py pass and
# appends its own stdout/stderr to logs/task-scheduler.log, since Task
# Scheduler (unlike launchd's StandardOutPath/StandardErrorPath) has no
# built-in output redirection for a scheduled action.
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$VenvPython = Join-Path $Root ".venv\Scripts\python.exe"
$Python = if (Test-Path $VenvPython) { $VenvPython } else { "python" }

$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "task-scheduler.log"

$env:PATH = "$(Join-Path $Root '.venv\Scripts');$env:PATH"
$env:PYTHONIOENCODING = "utf-8"
# PYTHONIOENCODING controls what bytes Python writes; it does not control how
# PowerShell decodes bytes it captures from a native command's stdout - that's
# [Console]::OutputEncoding, which under legacy powershell.exe defaults to the
# system codepage (e.g. cp1252), not UTF-8. Without this line, a real em dash
# in a skill's output comes back as "ΓÇö" - UTF-8's 3 bytes for "-" individually
# mis-decoded as cp1252 - verified empirically in a real tick's log output.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
"[$stamp] tick starting ($Python)" | Add-Content -Path $LogFile -Encoding utf8

# Explicit Out-String + Add-Content -Encoding utf8, not "*>> $LogFile":
# verified empirically that under the legacy powershell.exe Task Scheduler
# invokes (not pwsh - kept deliberately, since pwsh isn't guaranteed present
# on a fresh Windows install), *>> file redirection defaults to UTF-16LE,
# which renders the child's UTF-8 JSON output as garbled space-separated
# characters when anything else later reads the log as UTF-8.
$output = & $Python (Join-Path $Root "scripts\scheduler_tick.py") 2>&1 | Out-String
$exitCode = $LASTEXITCODE
Add-Content -Path $LogFile -Value $output -Encoding utf8

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
"[$stamp] tick finished (exit $exitCode)" | Add-Content -Path $LogFile -Encoding utf8

exit $exitCode
