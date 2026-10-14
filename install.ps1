# NG-Opus-Gateway — interactive installer (Windows)
#
#   irm https://raw.githubusercontent.com/nidhish28guhan-netizen/NG-Opus-Gateway/main/install.ps1 | iex
#
# Starts the gateway, then asks which client to wire up, installing any client
# that is missing, and prints the base URL and API key at the end.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Brand  = "NG free gateway"
$Repo   = "nidhish28guhan-netizen/NG-Opus-Gateway"
$Dir    = if ($env:NG_GATEWAY_DIR) { $env:NG_GATEWAY_DIR } else { "$env:USERPROFILE\.ng-opus-gateway" }
$Port   = if ($env:NG_GATEWAY_PORT) { $env:NG_GATEWAY_PORT } else { "4002" }
$Log     = Join-Path $Dir "gateway.log"
$Venv    = Join-Path $Dir ".venv"
$TaskName = "ng-opus-gateway"

function Write-Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "[-] $m" -ForegroundColor Red }
function Write-Banner($t) {
  Write-Host ""
  Write-Host "------------------------------------------------" -ForegroundColor Magenta
  Write-Host "  $t - Limited time only" -ForegroundColor White
  Write-Host "------------------------------------------------" -ForegroundColor Magenta
  Write-Host ""
}

# ------------------------ 1. get the code -------------------------
if (-not (Test-Path (Join-Path $Dir ".git"))) {
  Write-Info "Cloning NG-Opus-Gateway into $Dir..."
  git clone -q "https://github.com/$Repo.git" $Dir
  Write-Good "Downloaded."
} else {
  Write-Info "Updating the existing copy..."
  git -C $Dir pull -q --ff-only 2>$null
}
Push-Location $Dir

# -------------- 2. load committed credentials ---------------------
# Everything needed to reach the upstream is committed in
# gateway/upstream.env, so this installer asks for nothing.
$EnvFile = Join-Path $Dir "gateway\upstream.env"
if (-not (Test-Path $EnvFile)) {
  Write-Bad "gateway/upstream.env is missing. The repo is incomplete."
  exit 1
}
$EnvOverride = Join-Path $Dir "scripts\gateway.env"
# A local override still wins so a fork can test privately.
$LoadFile = if (Test-Path $EnvOverride) { $EnvOverride } else { $EnvFile }
Get-Content $LoadFile | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
    $k, $v = $line.Split("=", 2)
    Set-Item -Path "Env:$k" -Value $v.Trim('"')
  }
}

if (-not $env:NG_UPSTREAM_TOKEN) {
  Write-Bad "NG_UPSTREAM_TOKEN is empty in gateway/upstream.env."
  exit 1
}

# Discover the model from the provider instead of hardcoding it.
if (-not $env:NG_UPSTREAM_MODEL) {
  Write-Info "Discovering the model from the provider..."
  try {
    $modelsResp = Invoke-RestMethod -Uri "$($env:NG_UPSTREAM_BASE)/models" `
      -Headers @{ Authorization = "Bearer $($env:NG_UPSTREAM_TOKEN)" } -TimeoutSec 30
    $env:NG_UPSTREAM_MODEL = $modelsResp.data[0].id
    Write-Good "Model discovered."
  } catch {
    Write-Bad "Could not discover the model from the provider. Check the key in gateway/upstream.env."
    exit 1
  }
}

$Key = if ($env:NG_GATEWAY_KEY) { $env:NG_GATEWAY_KEY } else { "NG-Claude-Anthropic" }
$env:NG_GATEWAY_KEY = $Key
$env:CLAUDE_DESKTOP_LITELLM_KEY = $Key

# ----------------------- 3. the gateway ---------------------------
if (-not (Test-Path (Join-Path $Venv "Scripts\litellm.exe"))) {
  Write-Info "Building an isolated Python environment (one-time, ~1 min)..."
  python -m venv $Venv
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet --upgrade pip
  & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet litellm
  Write-Good "Installed."
}

Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Litellm = Join-Path $Venv "Scripts\litellm.exe"
$Config  = Join-Path $Dir "gateway\litellm-config.yaml"
# Task Scheduler starts in a fresh session that does not inherit our env vars,
# so write a wrapper that reloads upstream.env before launching.
$wrapper = Join-Path $Dir "scripts\run-gateway.cmd"
@"
@echo off
for /f "usebackq tokens=1,* delims==" %%a in (`"$EnvFile`") do @set "%%a=%%b"
"$Litellm" --config "$Config" --port $Port
"@ | Set-Content $wrapper -Encoding ASCII

$action  = New-ScheduledTaskAction -Execute $wrapper
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Info "Starting the gateway on port $Port..."
$up = $false
for ($i = 1; $i -le 40; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/liveliness" -TimeoutSec 3 -UseBasicParsing
    if ($r.StatusCode -eq 200) { $up = $true; break }
  } catch {}
  Start-Sleep -Seconds 2
}
if (-not $up) { Write-Bad "The gateway did not come up in time. Check $Log"; exit 1 }
Write-Good "Gateway is live."

$BaseUrl = "http://127.0.0.1:$Port"
$LanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -like "192.168.*" -or $_.IPAddress -like "10.*" } |
  Select-Object -First 1).IPAddress
$LanUrl = if ($LanIp) { "http://${LanIp}:$Port" } else { "http://<this-machine's-LAN-ip>:$Port" }

# ------------------------- 4. clients -----------------------------
function Install-ClaudeCli {
  if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Good "Claude Code CLI already installed."; return $true }
  Write-Info "Installing the Claude Code CLI..."
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Bad "Node/npm is required for the Claude Code CLI but was not found."
    Write-Info "Install Node from https://nodejs.org and re-run this script."
    return $false
  }
  npm install -g @anthropic-ai/claude-code 2>$null
  if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Good "Claude Code CLI installed."; return $true }
  Write-Bad "Claude Code CLI install failed."; return $false
}

function Install-Codex {
  if (Get-Command codex -ErrorAction SilentlyContinue) { Write-Good "Codex CLI already installed."; return $true }
  Write-Info "Installing the Codex CLI..."
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Write-Bad "Node/npm is required for the Codex CLI but was not found."; return $false }
  npm install -g @openai/codex 2>$null
  if (Get-Command codex -ErrorAction SilentlyContinue) { Write-Good "Codex CLI installed."; return $true }
  Write-Bad "Codex CLI install failed."; return $false
}

function Install-Antigravity {
  $dest = "$env:LOCALAPPDATA\Programs\Antigravity"
  if (Test-Path "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe") { Write-Good "Antigravity already installed."; return $true }
  Write-Info "Antigravity is a GUI app and needs a manual install on Windows."
  Write-Info "Get it from https://antigravity.google — this script writes the"
  Write-Info "config it should read."
  return $true
}

function Install-Dsh {
  $exe = "$env:LOCALAPPDATA\Programs\DeepSeek Harness\DeepSeek Harness.exe"
  if (Test-Path $exe) { Write-Good "DeepSeek Harness already installed."; return $true }
  Write-Bad "DeepSeek Harness is a desktop app and needs a manual install."
  Write-Info "Get it from the official site, then re-run this script to wire the model."
  return $true
}

# ------------------- 5. wire the model in -------------------------
function Wire-ClaudeCli {
  if (-not (Install-ClaudeCli)) { return }
  $dir = "$env:USERPROFILE\.claude"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $f = Join-Path $dir "settings.json"
  $cfg = @{ env = @{ ANTHROPIC_BASE_URL = $BaseUrl; ANTHROPIC_AUTH_TOKEN = $Key } }
  if (Test-Path $f) {
    try { $existing = Get-Content $f -Raw | ConvertFrom-Json } catch { $existing = $null }
    if ($existing) {
      if (-not $existing.env) { $existing | Add-Member -NotePropertyName env -NotePropertyValue @{} }
      $existing.env.ANTHROPIC_BASE_URL = $BaseUrl
      $existing.env.ANTHROPIC_AUTH_TOKEN = $Key
      $cfg = $existing
    }
  }
  $cfg | ConvertTo-Json -Depth 10 | Set-Content $f
  Write-Good "Wired the model into Claude Code ($f)."
}

function Wire-Codex {
  if (-not (Install-Codex)) { return }
  $dir = "$env:USERPROFILE\.codex"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  @"
# Wired by NG-Opus-Gateway
model = "claude-opus-5-5"
model_provider = "ng-gateway"

[model_providers.ng-gateway]
name = "NG Gateway"
base_url = "$BaseUrl/v1"
wire_api = "chat"
env_key = "NG_GATEWAY_KEY"
"@ | Set-Content (Join-Path $dir "config.toml")
  $envPath = "$env:USERPROFILE\.powershellrc.ps1"
  " `$env:NG_GATEWAY_KEY = `"$Key`"" | Out-File -Append -FilePath $envPath -ErrorAction SilentlyContinue
  [Environment]::SetEnvironmentVariable("NG_GATEWAY_KEY", $Key, "User")
  Write-Good "Wired the model into Codex ($(Join-Path $dir 'config.toml'))."
}

function Wire-Antigravity {
  Install-Antigravity | Out-Null
  $dir = "$env:USERPROFILE\.antigravity"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $cfg = @{ provider = "ng-gateway"; model = "claude-opus-5-5"; baseUrl = "$BaseUrl/v1"; apiKey = $Key }
  $cfg | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir "settings.json")
  Write-Good "Wrote Antigravity settings ($(Join-Path $dir 'settings.json'))."
  Write-Info "If Antigravity does not pick these up, add a custom OpenAI-compatible"
  Write-Info "provider inside the app with the base URL and key printed below."
}

function Wire-Dsh {
  if (-not (Install-Dsh)) { return }
  $prof = "$env:USERPROFILE\.dsh\profiles\desktop"
  New-Item -ItemType Directory -Force -Path $prof | Out-Null
  @"
llm-pi-ai:
  config:
    providers:
      ng-gateway:
        displayName: ng-gateway
        api: openai-completions
        baseURL: $BaseUrl/v1
        headers:
          Authorization: Bearer $Key
        streamIdleTimeoutMs: 600000
        timeoutMs: 1800000
        retryPolicy:
          mode: normal
          maxRetries: 2
          retryableCodes: [SERVER, RATE_LIMIT, TIMEOUT, TRANSPORT]
          backoff:
            initialDelayMs: 3000
            maxDelayMs: 45000
        models:
          - id: claude-opus-5-5
            name: Claude Opus 5.5 (ng-gateway)
            contextWindow: 262144
            maxTokens: 128000
            input:
              - text
              - image
"@ | Set-Content (Join-Path $prof "cordis.patch.yml")
  Write-Good "Wired the model into DeepSeek Harness ($(Join-Path $prof 'cordis.patch.yml'))."
  Write-Info "Restart DeepSeek Harness for the route to load."
}

# ---------------------------- menu --------------------------------
Write-Banner $Brand
Write-Info "Which client should I open and wire up?"
Write-Host ""
Write-Host "   1) Claude Code"
Write-Host "   2) Codex"
Write-Host "   3) Antigravity"
Write-Host "   4) DeepSeek Harness (DSH)"
Write-Host "   5) All of the above"
Write-Host ""
$choice = Read-Host "? Enter 1-5 (default 1)"
if (-not $choice) { $choice = "1" }

switch ($choice) {
  "1" { Wire-ClaudeCli }
  "2" { Wire-Codex }
  "3" { Wire-Antigravity }
  "4" { Wire-Dsh }
  "5" { Wire-ClaudeCli; Wire-Codex; Wire-Antigravity; Wire-Dsh }
  default { Write-Bad "Invalid choice: $choice. The gateway is running but nothing was wired." }
}

# --------------------- 6. show credentials ------------------------
Write-Banner $Brand
Write-Host "  Base URL    $BaseUrl" -ForegroundColor White
Write-Host "  LAN URL     $LanUrl  (other devices on your Wi-Fi)" -ForegroundColor White
Write-Host "  API key     $Key" -ForegroundColor White
Write-Host "  Model       claude-opus-5-5" -ForegroundColor White
Write-Host ""
Write-Info "Give these to any OpenAI-compatible client to use the gateway."
Write-Host ""
Write-Good "Done. The gateway auto-starts at logon."
Write-Host ""
