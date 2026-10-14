#!/usr/bin/env bash
# NG-Sonnet-Gateway - interactive installer (macOS)
#
#   curl -fsSL https://raw.githubusercontent.com/nidhish28guhan-netizen/NG-Sonnet-Gateway/main/install.sh | bash
#
# Zero prompts: upstream credentials live in gateway/upstream.env (committed).
# The model name is auto-discovered from the provider. This script starts the
# gateway, asks which client to wire up, installs any missing client, wires the
# model in, and prints the base URL and API key.
set -euo pipefail

# ---------------------------- constants ----------------------------
BRAND="NG free gateway"
REPO="nidhish28guhan-netizen/NG-Sonnet-Gateway"
INSTALL_DIR="${NG_GATEWAY_DIR:-$HOME/.ng-sonnet-gateway}"
LOG="$INSTALL_DIR/gateway.log"
VENV="$INSTALL_DIR/.venv"
LABEL="ai.ng-sonnet-gateway.gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# ---------------------------- helpers ------------------------------
say()  { printf '[*] %s\n' "$*"; }
good() { printf '[+] %s\n' "$*"; }
bad()  { printf '[-] %s\n' "$*" >&2; }
ask()  { printf '[?] %s ' "$*"; }

banner() {
  echo
  echo "------------------------------------------------"
  echo "  ${BRAND} - Limited time only"
  echo "------------------------------------------------"
  echo
}

# ------------------------ 1. get the code --------------------------
# Migrate a legacy "opus" install in place: the repo was renamed, so move the
# old directory (keeping the venv, the token ledger, and the logs) if this is
# the same machine upgrading.
LEGACY_DIR="$HOME/.ng-opus-gateway"
if [[ "$INSTALL_DIR" == "$HOME/.ng-sonnet-gateway" && -d "$LEGACY_DIR/.git" && ! -d "$INSTALL_DIR/.git" ]]; then
  say "Migrating the existing install from $LEGACY_DIR..."
  mv "$LEGACY_DIR" "$INSTALL_DIR"
  good "Migrated (venv, user ledger, and logs kept)."
fi

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  say "Cloning NG-Sonnet-Gateway into $INSTALL_DIR..."
  git clone -q "https://github.com/${REPO}.git" "$INSTALL_DIR"
  good "Downloaded."
else
  say "Updating the existing copy..."
  git -C "$INSTALL_DIR" pull -q --ff-only 2>/dev/null || true
fi
cd "$INSTALL_DIR"

# ----------------- 2. load committed credentials -------------------
# Everything needed to reach the upstream is committed in upstream.env, so
# this installer asks for nothing. See gateway/upstream.env.
if [[ ! -f "gateway/upstream.env" ]]; then
  bad "gateway/upstream.env is missing. The repo is incomplete."
  exit 1
fi
set +u; # shellcheck source=/dev/null
source gateway/upstream.env
set -u

GATEWAY_KEY="${NG_GATEWAY_KEY:-NG-Claude-Anthropic}"
PORT="${NG_GATEWAY_PORT:-4002}"
export NG_UPSTREAM_TOKEN NG_UPSTREAM_BASE GATEWAY_KEY PORT
export NG_GATEWAY_KEY="$GATEWAY_KEY"
export CLAUDE_DESKTOP_LITELLM_KEY="$GATEWAY_KEY"

# Discover the model name from the provider instead of hardcoding it, so the
# repo never names a specific upstream model and survives a swap upstream.
if [[ -z "${NG_UPSTREAM_MODEL:-}" ]]; then
  say "Discovering the model from the provider..."
  NG_UPSTREAM_MODEL="$(
    curl -s -m 30 "${NG_UPSTREAM_BASE}/models" \
      -H "Authorization: Bearer ${NG_UPSTREAM_TOKEN}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || true
  )"
  if [[ -z "$NG_UPSTREAM_MODEL" ]]; then
    bad "Could not discover the model from the provider."
    bad "Check the upstream key in gateway/upstream.env and your network."
    exit 1
  fi
  export NG_UPSTREAM_MODEL
  good "Model discovered."
fi

# litellm needs a provider prefix to know which wire protocol to use. The
# discovery returns a bare model id with an org/name separator slash, which is
# NOT a litellm provider prefix. Add "openai/" unless the value already starts
# with a prefix litellm recognizes. The upstream id itself is never written
# into the repo - it is discovered at runtime from the provider.
case "$NG_UPSTREAM_MODEL" in
  anthropic/*|azure/*|openai/*|bedrock/*|cohere/*|gemini/*|vertex_ai/*|huggingface/*|together_ai/*|fireworks_ai/*|ollama/*|ollama_chat/*|groq/*|mistral/*|anyscale/*|deepseek/*|perplexity/*|openrouter/*|voyage/*|xai/*|litellm_proxy/*) ;;
  *) NG_UPSTREAM_MODEL="openai/$NG_UPSTREAM_MODEL"; export NG_UPSTREAM_MODEL ;;
esac

# ----------------------- 3. the gateway ----------------------------
# Build the venv if missing, or repair it if the proxy extras are absent
# (early installs used plain "litellm", which lacks the websockets module the
# proxy server needs - the gateway then crashes on startup).
if [[ ! -x "$VENV/bin/litellm" ]] || ! "$VENV/bin/python" -c "import websockets" >/dev/null 2>&1; then
  if [[ -d "$VENV" ]]; then rm -rf "$VENV"; fi
  say "Building an isolated Python environment (one-time, about 1 min)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet 'litellm[proxy]'
  good "Installed."
fi

# Stop any old instance on this port, then install the launchd agent.
# Order matters: kill the listener FIRST so litellm lets go of the port, then
# boot the old agent out and let launchd finish before re-registering. Doing
# these in the wrong order (or booting out after needing the port) leaves the
# agent unregistered and the gateway dead - which is the bug this fixes.
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | xargs kill 2>/dev/null || true
if launchctl list "$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  sleep 3
fi
# Retire the pre-rename agent, which otherwise keeps holding the port.
LEGACY_LABEL="ai.ng-opus-gateway.gateway"
if launchctl list "$LEGACY_LABEL" >/dev/null 2>&1; then
  say "Retiring the old gateway agent..."
  launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist" 2>/dev/null || true
  good "Retired."
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTDOC
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV}/bin/litellm</string>
    <string>--config</string><string>${INSTALL_DIR}/gateway/litellm-config.yaml</string>
    <string>--port</string><string>${PORT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NG_UPSTREAM_TOKEN</key><string>${NG_UPSTREAM_TOKEN}</string>
    <key>NG_UPSTREAM_MODEL</key><string>${NG_UPSTREAM_MODEL}</string>
    <key>NG_UPSTREAM_BASE</key><string>${NG_UPSTREAM_BASE}</string>
    <key>NG_GATEWAY_KEY</key><string>${GATEWAY_KEY}</string>
    <key>CLAUDE_DESKTOP_LITELLM_KEY</key><string>${GATEWAY_KEY}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
PLISTDOC

# Register the agent. bootstrap can race with the bootout above, so retry the
# (re)start until it is actually registered and running, not just fire-and-forget.
DOMAIN="gui/$(id -u)"
for _attempt in 1 2 3 4 5; do
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || \
      launchctl load -w "$PLIST" 2>/dev/null || true
  fi
  launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && break
  sleep 3
done

say "Starting the gateway on port $PORT..."
BASE_URL="http://127.0.0.1:${PORT}"
UP=0
for _i in $(seq 1 40); do
  if curl -s -m 3 -o /dev/null "${BASE_URL}/health/liveliness" 2>/dev/null; then
    UP=1
    break
  fi
  sleep 2
done
if [[ "$UP" -ne 1 ]]; then
  bad "The gateway did not come up in time. Check $LOG"
  exit 1
fi
good "Gateway is live."

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
LAN_URL="http://${LAN_IP:-THIS_MACHINE_LAN_IP}:${PORT}"

# ------------------------- 4. pick a client ------------------------
has() { command -v "$1" >/dev/null 2>&1; }

install_claude_cli() {
  if has claude; then good "Claude Code CLI already installed."; return 0; fi
  say "Installing the Claude Code CLI..."
  if ! has npm; then
    bad "Node/npm is required for the Claude Code CLI but was not found."
    say "Install Node from https://nodejs.org and re-run this script."
    return 1
  fi
  npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || npm install -g @anthropic-ai/claude-code
  if has claude; then good "Claude Code CLI installed."; return 0; fi
  bad "Claude Code CLI install failed."
  return 1
}

install_codex() {
  if has codex; then good "Codex CLI already installed."; return 0; fi
  say "Installing the Codex CLI..."
  if ! has npm; then
    bad "Node/npm is required for the Codex CLI but was not found."
    return 1
  fi
  npm install -g @openai/codex >/dev/null 2>&1 || npm install -g @openai/codex
  if has codex; then good "Codex CLI installed."; return 0; fi
  bad "Codex CLI install failed."
  return 1
}

install_antigravity() {
  if [[ -d "/Applications/Antigravity.app" ]]; then good "Antigravity already installed."; return 0; fi
  say "Downloading Antigravity..."
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL "https://storage.googleapis.com/antigravity/releases/latest/Antigravity-darwin-arm64.zip" -o "${tmp}/antigravity.zip"; then
    ( cd "$tmp" && unzip -q antigravity.zip && mv -f Antigravity.app /Applications/ 2>/dev/null ) || true
    if [[ -d "/Applications/Antigravity.app" ]]; then
      good "Antigravity installed."
      return 0
    fi
  fi
  bad "Could not install Antigravity automatically."
  say "Download it from https://antigravity.google and it will pick up the config this script writes."
  return 0
}

install_dsh() {
  if [[ -d "/Applications/DeepSeek Harness.app" ]]; then good "DeepSeek Harness already installed."; return 0; fi
  bad "DeepSeek Harness is a desktop app and needs a manual install."
  say "Get it from the official site, then re-run this script to wire the model."
  return 0
}

# --------------------- 5. wire the model in ------------------------
wire_claude_cli() {
  install_claude_cli || return 0
  mkdir -p "$HOME/.claude"
  local f="$HOME/.claude/settings.json"
  "$VENV/bin/python" "$INSTALL_DIR/scripts/patch_claude_settings.py" "$f" "$BASE_URL" "$GATEWAY_KEY"
  good "Wired the model into Claude Code ($HOME/.claude/settings.json)."
}

wire_codex() {
  install_codex || return 0
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<TOMLDOC
# Wired by NG-Sonnet-Gateway
model = "claude-sonnet-5-5"
model_provider = "ng-gateway"

[model_providers.ng-gateway]
name = "NG Gateway"
base_url = "${BASE_URL}/v1"
wire_api = "chat"
env_key = "NG_GATEWAY_KEY"
TOMLDOC
  # codex reads the key from the environment named by env_key
  if ! grep -q 'NG_GATEWAY_KEY' "$HOME/.zshrc" 2>/dev/null; then
    printf 'export NG_GATEWAY_KEY="%s"\n' "$GATEWAY_KEY" >> "$HOME/.zshrc"
  fi
  good "Wired the model into Codex ($HOME/.codex/config.toml)."
}

wire_antigravity() {
  install_antigravity || return 0
  mkdir -p "$HOME/.antigravity"
  cat > "$HOME/.antigravity/settings.json" <<JSONDOC
{
  "provider": "ng-gateway",
  "model": "claude-sonnet-5-5",
  "baseUrl": "${BASE_URL}/v1",
  "apiKey": "${GATEWAY_KEY}"
}
JSONDOC
  good "Wrote Antigravity settings ($HOME/.antigravity/settings.json)."
  say "If Antigravity does not pick these up, add a custom OpenAI-compatible"
  say "provider inside the app with the base URL and key printed below."
}

wire_dsh() {
  install_dsh || return 0
  local prof="$HOME/.dsh/profiles/desktop"
  mkdir -p "$prof"
  cat > "$prof/cordis.patch.yml" <<YAMLDOC
llm-pi-ai:
  config:
    providers:
      ng-gateway:
        displayName: ng-gateway
        api: openai-completions
        baseURL: ${BASE_URL}/v1
        headers:
          Authorization: Bearer ${GATEWAY_KEY}
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
          - id: claude-sonnet-5-5
            name: Claude Sonnet 5.5 (ng-gateway)
            contextWindow: 1000000
            maxTokens: 128000
            input:
              - text
              - image
YAMLDOC
  good "Wired the model into DeepSeek Harness ($prof/cordis.patch.yml)."
  say "Restart DeepSeek Harness for the route to load - it only reads the"
  say "profile at startup."
}

# ---------------------------- the menu -----------------------------
banner
say "Which client should I open and wire up?"
echo
echo "   1) Claude Code"
echo "   2) Codex"
echo "   3) Antigravity"
echo "   4) DeepSeek Harness (DSH)"
echo "   5) All of the above"
echo
ask "Enter 1-5 (default 1):"
read -r CHOICE < /dev/tty
CHOICE="${CHOICE:-1}"

case "$CHOICE" in
  1) wire_claude_cli ;;
  2) wire_codex ;;
  3) wire_antigravity ;;
  4) wire_dsh ;;
  5) wire_claude_cli; wire_codex; wire_antigravity; wire_dsh ;;
  *) bad "Invalid choice: $CHOICE"; bad "Wiring nothing, but the gateway is running."; exit 0 ;;
esac

# ---------------------- 6. show credentials ------------------------
banner
echo "  Base URL    $BASE_URL/v1"
if [[ -n "$LAN_IP" ]]; then
  echo "  LAN URL     $LAN_URL/v1  (other devices on your Wi-Fi)"
fi
echo "  API key     $GATEWAY_KEY"
echo "  Model       claude-sonnet-5-5"
echo
say "Give these to any OpenAI-compatible client to use the gateway."
echo
good "Done. The gateway auto-starts on login."
echo
