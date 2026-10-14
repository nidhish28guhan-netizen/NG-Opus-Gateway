#!/usr/bin/env bash
# ng-users — manage per-user keys and daily token budgets.
#
#   ./scripts/ng-users.sh add    <user-id> [note]   mint a new key (printed ONCE)
#   ./scripts/ng-users.sh list                       who used what today
#   ./scripts/ng-users.sh reset  <user-id>           issue a replacement key
#   ./scripts/ng-users.sh delete <user-id>           revoke a user entirely
#
# Keys are shown exactly once at creation. The ledger only ever stores the
# salted hash, so a lost key cannot be recovered - reset it instead.
#
# Daily limit is set by NG_DAILY_TOKEN_LIMIT (default 30,000,000 tokens/user/day).
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
  for candidate in "$DIR/.venv/bin/python" "$HOME/.ng-opus-gateway/.venv/bin/python" python3; do
    if [[ -x "$candidate" ]]; then PY="$candidate"; break; fi
  done
fi
if [[ -z "${PY:-}" ]]; then
  echo "[-] no python found" >&2
  exit 1
fi

# Must match ng_users._ledger_path()'s default: the gateway reads the ledger
# from the REPO ROOT (gateway/../gateway.ng-ledger.json). Keep them in sync or
# the admin tool and the gateway see two different files.
export NG_LEDGER_FILE="${NG_LEDGER_FILE:-$DIR/gateway.ng-ledger.json}"
export NG_REPO_DIR="$DIR"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//; s#^./scripts#./scripts#' ; }

case "${1:-help}" in
  add)
    [[ -n "${2:-}" ]] || { echo "[-] usage: ng-users.sh add <user-id> [note]" >&2; exit 1; }
    OUT="$("$PY" - "$2" "${3:-}" <<'PY'
import importlib.util, os, sys
path = os.path.join(os.environ["NG_REPO_DIR"], "gateway", "ng_users.py")
spec = importlib.util.spec_from_file_location("ng_users", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
uid, note = sys.argv[1], sys.argv[2]
k = m.create_user(uid, note)
if k is None:
    print("EXISTS"); sys.exit(0)
print(k)
PY
)"
    if [[ "$OUT" == "EXISTS" ]]; then
      echo "[-] user '$2' already exists. Use: $0 reset $2"
      exit 1
    fi
    echo "[+] created '$2'"
    echo "[+] API key (shown ONCE, copy it now):"
    echo
    echo "    $OUT"
    echo
    echo "[+] Daily limit: ${NG_DAILY_TOKEN_LIMIT:-30000000} tokens. Resets at midnight."
    ;;
  list)
    "$PY" - <<'PY' || true
import importlib.util, os
path = os.path.join(os.environ["NG_REPO_DIR"], "gateway", "ng_users.py")
spec = importlib.util.spec_from_file_location("ng_users", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = m.status()
if not rows:
    print("  (no users yet — run: ./scripts/ng-users.sh add <user-id>)")
else:
    for r in rows:
        print(f"  {r['user']:<16} today {r['today']:>10,} / {r['limit']:,}")
PY
    ;;
  reset)
    [[ -n "${2:-}" ]] || { echo "[-] usage: ng-users.sh reset <user-id>" >&2; exit 1; }
    OUT="$("$PY" - "$2" <<'PY'
import importlib.util, os, sys
path = os.path.join(os.environ["NG_REPO_DIR"], "gateway", "ng_users.py")
spec = importlib.util.spec_from_file_location("ng_users", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
k = m.reset_key(sys.argv[1])
print("NONE" if k is None else k)
PY
)"
    if [[ "$OUT" == "NONE" ]]; then
      echo "[-] user '$2' does not exist"
      exit 1
    fi
    echo "[+] new key for '$2' (old key revoked):"
    echo
    echo "    $OUT"
    ;;
  delete)
    [[ -n "${2:-}" ]] || { echo "[-] usage: ng-users.sh delete <user-id>" >&2; exit 1; }
    if "$PY" - "$2" <<'PY'
import importlib.util, os, sys
path = os.path.join(os.environ["NG_REPO_DIR"], "gateway", "ng_users.py")
spec = importlib.util.spec_from_file_location("ng_users", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.delete_user(sys.argv[1]) else 1)
PY
    then
      echo "[+] deleted '$2'"
    else
      echo "[-] user '$2' does not exist"
      exit 1
    fi
    ;;
  *)
    usage
    ;;
esac
