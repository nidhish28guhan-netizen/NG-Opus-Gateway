# start-gateway.ps1 — run the LiteLLM gateway on Windows.
#
#   .\scripts\start-gateway.ps1            start in the foreground
#   .\scripts\start-gateway.ps1 -Install   install a scheduled task (auto-start on login)
#   .\scripts\start-gateway.ps1 -Status    is it running?
#   .\scripts\start-gateway.ps1 -Logs      tail the log
#   .\scripts\start-gateway.ps1 -Stop      stop it
#
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Logs
)

$ErrorActionPreference = "Stop"
$Dir = Resolve-Path "$PSScriptRoot\.."
$EnvFile = Join-Path $Dir "scripts\gateway.env"
$Log = Join-Path $Dir "gateway.log"
$Venv = Join-Path $Dir ".venv"
$Port = if ($env:GATEWAY_PORT) { $env:GATEWAY_PORT } else { "4002" }
$TaskName = "ng-opus-gateway"

function Write-Info($msg) { Write-Host "[ng-opus-gateway] $msg" -ForegroundColor Cyan }
function Write-Bad($msg)  { Write-Host "[ng-opus-gateway] $msg" -ForegroundColor Red }

# Load secrets from gateway.env (simple KEY=VALUE lines).
if (-not (Test-Path $EnvFile)) {
  Copy-Item (Join-Path $Dir "scripts\gateway.env.example") $EnvFile
  Write-Bad "Created $EnvFile from the example."
  Write-Bad "Edit it and put your Token Juice key in NG_UPSTREAM_TOKEN, then re-run."
  exit 1
}
Get-Content $EnvFile | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
    $k, $v = $line.Split("=", 2)
    Set-Item -Path "Env:$k" -Value $v
  }
}

if (-not $env:NG_UPSTREAM_TOKEN -or $env:NG_UPSTREAM_TOKEN -like "*PASTE_YOUR_TOKEN_HERE*") {
  Write-Bad "NG_UPSTREAM_TOKEN is not set. Edit $EnvFile and add your upstream key."
  exit 1
}
if (-not $env:NG_UPSTREAM_MODEL -or $env:NG_UPSTREAM_MODEL -like "*PASTE_UPSTREAM_MODEL_NAME*") {
  Write-Bad "NG_UPSTREAM_MODEL is not set. Edit $EnvFile and add the upstream model name."
  exit 1
}
$env:CLAUDE_DESKTOP_LITELLM_KEY = $env:NG_GATEWAY_KEY

# Build a virtualenv with litellm if one is not already present.
if (-not (Test-Path (Join-Path $Venv "Scripts\litellm.exe"))) {
  Write-Info "Building the virtualenv (one-time, ~1 min)..."
  python -m venv $Venv
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet --upgrade pip
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet litellm
}

$Litellm = Join-Path $Venv "Scripts\litellm.exe"
$Config = Join-Path $Dir "gateway\litellm-config.yaml"

if ($Install) {
  # Task Scheduler starts in a fresh session that does not inherit our env
  # vars, so write a wrapper that reloads gateway.env before launching.
  $wrapper = Join-Path $Dir "scripts\run-gateway.cmd"
  @"
@echo off
for /f "usebackq tokens=1,* delims==" %%a in (`"%EnvFile%`") do @set "%%a=%%b"
"$Litellm" --config "$Config" --port $Port
"@ | Set-Content $wrapper -Encoding ASCII

  $action = New-ScheduledTaskAction -Execute $wrapper
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Write-Info "Installed and started. It will auto-start at login."
  Write-Info "Log: $Log"
  return
}

if ($Stop) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Info "Stopped and removed the scheduled task."
  } else {
    Write-Bad "No scheduled task installed. Nothing to stop."
  }
  return
}

if ($Status) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task -and $task.State -eq "Running") {
    Write-Info "Scheduled task: running (port $Port)"
  } elseif (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Write-Info "Something is listening on port $Port."
  } else {
    Write-Info "Not running."
  }
  return
}

if ($Logs) {
  Get-Content $Log -Wait -Tail 50
  return
}

# Default: run in the foreground.
& $Litellm --config $Config --port $Port 2>&1 | Tee-Object -FilePath $Log -Append
