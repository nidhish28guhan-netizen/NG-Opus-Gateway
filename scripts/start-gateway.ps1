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
$TaskName = "ng-sonnet-gateway"

function Write-Info($msg) { Write-Host "[ng-sonnet-gateway] $msg" -ForegroundColor Cyan }
function Write-Bad($msg)  { Write-Host "[ng-sonnet-gateway] $msg" -ForegroundColor Red }

# Load upstream credentials. The values are committed in gateway/upstream.env
# so this works with zero setup. A local override in scripts\gateway.env, if
# present, still wins so a fork can test without changing the committed file.
$UpstreamEnv = Join-Path $Dir "gateway\upstream.env"
$EnvFile = Join-Path $Dir "scripts\gateway.env"
$LoadFile = if (Test-Path $EnvFile) { $EnvFile } elseif (Test-Path $UpstreamEnv) { $UpstreamEnv } else { $null }
if (-not $LoadFile) {
  Write-Bad "No upstream.env found. The repo is incomplete."
  exit 1
}
Get-Content $LoadFile | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
    $k, $v = $line.Split("=", 2)
    Set-Item -Path "Env:$k" -Value $v.Trim('"')
  }
}

if (-not $env:NG_UPSTREAM_TOKEN) {
  Write-Bad "NG_UPSTREAM_TOKEN is empty in the env file."
  exit 1
}

# Discover the model at runtime when the env does not pin one.
if (-not $env:NG_UPSTREAM_MODEL) {
  if (-not $env:NG_UPSTREAM_BASE) {
    Write-Bad "NG_UPSTREAM_BASE is not set. gateway/upstream.env looks broken."
    exit 1
  }
  try {
    $modelsResp = Invoke-RestMethod -Uri "$($env:NG_UPSTREAM_BASE)/models" `
      -Headers @{ Authorization = "Bearer $($env:NG_UPSTREAM_TOKEN)" } -TimeoutSec 30
    $env:NG_UPSTREAM_MODEL = $modelsResp.data[0].id
  } catch {
    Write-Bad "Could not discover the model from the provider."
    exit 1
  }
}

# litellm needs a provider prefix to know which wire protocol to use. Discovery
# returns a bare model id with an org/name separator slash, which is NOT a
# litellm provider prefix. Add "openai/" unless the value already starts with
# a prefix litellm recognizes.
$knownPrefixes = @('anthropic/','azure/','openai/','bedrock/','cohere/','gemini/','vertex_ai/','huggingface/','together_ai/','fireworks_ai/','ollama/','ollama_chat/','groq/','mistral/','anyscale/','deepseek/','perplexity/','openrouter/','voyage/','xai/','litellm_proxy/')
$prefixed = $false
foreach ($p in $knownPrefixes) { if ($env:NG_UPSTREAM_MODEL.StartsWith($p)) { $prefixed = $true; break } }
if (-not $prefixed) { $env:NG_UPSTREAM_MODEL = "openai/$($env:NG_UPSTREAM_MODEL)" }

if (-not $env:NG_GATEWAY_KEY) { $env:NG_GATEWAY_KEY = "NG-Claude-Anthropic" }
$env:CLAUDE_DESKTOP_LITELLM_KEY = $env:NG_GATEWAY_KEY

# Build a virtualenv with litellm if one is not already present.
if (-not (Test-Path (Join-Path $Venv "Scripts\litellm.exe"))) {
  Write-Info "Building the virtualenv (one-time, ~1 min)..."
  python -m venv $Venv
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet --upgrade pip
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet 'litellm[proxy]'
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
