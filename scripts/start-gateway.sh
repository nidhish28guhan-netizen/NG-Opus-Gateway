#!/usr/bin/env bash
# start-gateway.sh — run the LiteLLM gateway on macOS.
#
#   ./start-gateway.sh          start in the foreground
#   ./start-gateway.sh install  install a launchd agent (auto-start on login)
#   ./start-gateway.sh status   is it running?
#   ./start-gateway.sh logs     tail the log
#   ./start-gateway.sh stop     stop it
#   ./start-gateway.sh restart  restart it
#
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="${ENV_FILE:-$DIR/scripts/gateway.env}"
LOG="${LOG:-$DIR/gateway.log}"
VENV="${VENV:-$DIR/.venv}"
PORT="${GATEWAY_PORT:-4002}"
LABEL="ai.ng-sonnet-gateway.gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

log()  { printf '\033[36m[ng-sonnet-gateway]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ng-sonnet-gateway]\033[0m %s\n' "$*" >&2; }

# Load upstream credentials. The values are committed in gateway/upstream.env
# so this works with zero setup. A local override in scripts/gateway.env, if
# present, still wins so a fork can test without changing the committed file.
ENV_FILE="${ENV_FILE:-$DIR/scripts/gateway.env}"
UPSTREAM_ENV="$DIR/gateway/upstream.env"
if [[ -f "$ENV_FILE" ]]; then
  set +u; source "$ENV_FILE"; set -u
elif [[ -f "$UPSTREAM_ENV" ]]; then
  set +u; source "$UPSTREAM_ENV"; set -u
else
  err "No upstream.env found. The repo is incomplete."
  exit 1
fi

if [[ -z "${NG_UPSTREAM_TOKEN:-}" ]]; then
  err "NG_UPSTREAM_TOKEN is empty in the env file."
  exit 1
fi

# Discover the model at runtime when the env does not pin one, so the repo
# never hardcodes a specific upstream model.
if [[ -z "${NG_UPSTREAM_MODEL:-}" ]]; then
  NG_UPSTREAM_MODEL="$(
    curl -s -m 30 "${NG_UPSTREAM_BASE:?set by gateway/upstream.env}/models" \
      -H "Authorization: Bearer ${NG_UPSTREAM_TOKEN}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || true
  )"
  if [[ -z "$NG_UPSTREAM_MODEL" ]]; then
    err "Could not discover the model from the provider."
    exit 1
  fi
fi

# litellm needs a provider prefix to know which protocol to speak. The
# discovery above returns a bare model id with an org/name separator slash,
# which is NOT a litellm provider prefix. Prefix it unless the env already
# carries one litellm recognizes.
case "$NG_UPSTREAM_MODEL" in
  anthropic/*|azure/*|openai/*|bedrock/*|cohere/*|gemini/*|vertex_ai/*|huggingface/*|together_ai/*|fireworks_ai/*|ollama/*|ollama_chat/*|groq/*|mistral/*|anyscale/*|deepseek/*|perplexity/*|openrouter/*|voyage/*|xai/*|litellm_proxy/*) ;;
  *) NG_UPSTREAM_MODEL="openai/$NG_UPSTREAM_MODEL" ;;
esac

: "${NG_GATEWAY_KEY:=NG-Claude-Anthropic}"

export NG_UPSTREAM_TOKEN NG_UPSTREAM_MODEL NG_UPSTREAM_BASE
export NG_GATEWAY_KEY CLAUDE_DESKTOP_LITELLM_KEY

# Build a virtualenv with litellm if one is not already present.
if [[ ! -x "$VENV/bin/litellm" ]]; then
  log "Building the virtualenv (one-time, ~1 min)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet 'litellm[proxy]'
fi

LITELLM_BIN="$VENV/bin/litellm"
CONFIG="$DIR/gateway/litellm-config.yaml"

start_foreground() {
  exec "$LITELLM_BIN" --config "$CONFIG" --port "$PORT" 2>&1 | tee -a "$LOG"
}

stop() {
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    log "Stopped the launchd agent."
  else
    err "No launchd agent installed. Nothing to stop."
  fi
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LITELLM_BIN</string>
    <string>--config</string><string>$CONFIG</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NG_UPSTREAM_TOKEN</key><string>$NG_UPSTREAM_TOKEN</string>
    <key>NG_UPSTREAM_MODEL</key><string>$NG_UPSTREAM_MODEL</string>
    <key>NG_UPSTREAM_BASE</key><string>$NG_UPSTREAM_BASE</string>
    <key>NG_GATEWAY_KEY</key><string>$NG_GATEWAY_KEY</string>
    <key>CLAUDE_DESKTOP_LITELLM_KEY</key><string>$NG_GATEWAY_KEY</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
XML
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  log "Installed and started. It will auto-start on login."
  log "Log: $LOG"
}

status() {
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    log "launchd agent: running (port $PORT)"
  elif lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    log "Something is listening on port $PORT (not the launchd agent)."
  else
    log "Not running."
  fi
}

case "${1:-start}" in
  start)     start_foreground ;;
  install)   install_agent ;;
  stop)      stop ;;
  restart)   stop; sleep 2; install_agent ;;
  status)    status ;;
  logs)      tail -f "$LOG" ;;
  *)         echo "usage: $0 [start|install|stop|restart|status|logs]"; exit 1 ;;
esac
