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
LABEL="ai.ng-opus-gateway.gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

log()  { printf '\033[36m[ng-opus-gateway]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ng-opus-gateway]\033[0m %s\n' "$*" >&2; }

# Load secrets. The example file is shipped; copy it to gateway.env first.
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$DIR/scripts/gateway.env.example" "$ENV_FILE"
  err "Created $ENV_FILE from the example."
  err "Edit it and put your Token Juice key in NG_UPSTREAM_TOKEN, then re-run."
  exit 1
fi
# shellcheck disable=SC1090
set +u; source "$ENV_FILE"; set -u

if [[ -z "${NG_UPSTREAM_TOKEN:-}" || "$NG_UPSTREAM_TOKEN" == *"PASTE_YOUR_TOKEN_HERE"* ]]; then
  err "NG_UPSTREAM_TOKEN is not set. Edit $ENV_FILE and add your upstream key."
  exit 1
fi
if [[ -z "${NG_UPSTREAM_MODEL:-}" || "$NG_UPSTREAM_MODEL" == *"PASTE_UPSTREAM_MODEL_NAME"* ]]; then
  err "NG_UPSTREAM_MODEL is not set. Edit $ENV_FILE and add the upstream model name."
  exit 1
fi

export NG_UPSTREAM_TOKEN NG_UPSTREAM_MODEL NG_UPSTREAM_BASE
export NG_GATEWAY_KEY CLAUDE_DESKTOP_LITELLM_KEY

# Build a virtualenv with litellm if one is not already present.
if [[ ! -x "$VENV/bin/litellm" ]]; then
  log "Building the virtualenv (one-time, ~1 min)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet litellm
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
