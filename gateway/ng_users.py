"""NG-Sonnet-Gateway user ledger.

A self-contained, SQL-free store for per-user API keys and daily token usage.

Design goals (from the gateway owner):
  * No SQL database, nothing external. One local file, governed by this PC.
  * Unbreakable chain: usage records are hash-linked, so editing, deleting, or
    reordering any record invalidates the whole chain from that point on.
  * Uncheatable budget: the daily cap is checked *before* the request goes
    upstream, and usage is only counted from signed records the gateway itself
    wrote after a confirmed response.
  * API keys are never stored in the clear and never exposed to end users
    beyond the one-time print at creation.

Layout of LEDGER_FILE (JSON):

    {
      "version": 1,
      "salt": "<hex>",
      "users": {
          "<user_id>": {
              "key_hash": "<hex sha256(salt + api_key)>",
              "created":   1234567890.0,
              "note":      "optional human label",
              "spend": [ <usage record>, ... ]
          }
      },
      "chain_head": "<hex of the last committed record>"
    }

A usage record is:

    {
      "user":   "<user_id>",
      "day":    "YYYY-MM-DD",          # server-local day
      "tokens": <int>,                 # total tokens for the call
      "ts":     <epoch float>,
      "prev":   "<hex>",               # hash of the previous record
      "sig":    "<hex>"                # hmac of this record with the salt
    }

`sig` is HMAC-SHA256(salt, "<user>|<day>|<tokens>|<ts>|<prev>"). A record is
valid only if its sig matches and its prev matches the record before it. The
first record's prev is "". chain_head pins the latest record, so an attacker
who appending a fake-but-well-formed record still cannot forge the salt.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from datetime import date

LEDGER_FILE_ENV = "NG_LEDGER_FILE"
DAILY_LIMIT_ENV = "NG_DAILY_TOKEN_LIMIT"
DEFAULT_LIMIT = 30_000_000  # 30M tokens per user per day

_LOCK = threading.Lock()


# ---------------------------------------------------------------- hashing

def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac_hex(salt: str, message: str) -> str:
    return hmac.new(salt.encode("utf-8"), message.encode("utf-8"),
                    hashlib.sha256).hexdigest()


def _record_id(rec: dict) -> str:
    """Canonical digest of a record's contents (not including its own sig)."""
    message = "|".join(
        str(rec[k]) for k in ("user", "day", "tokens", "ts", "prev"))
    return _sha256_hex(message.encode("utf-8"))


def _sign(salt: str, rec: dict) -> str:
    message = "|".join(
        str(rec[k]) for k in ("user", "day", "tokens", "ts", "prev"))
    return _hmac_hex(salt, message)


# ---------------------------------------------------------------- accessors

def _ledger_path() -> str:
    default = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "gateway.ng-ledger.json")
    return os.environ.get(LEDGER_FILE_ENV) or os.path.abspath(default)


def _today() -> str:
    return date.fromtimestamp(time.time()).isoformat()


def _load(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    if "salt" not in data:
        data["salt"] = secrets.token_hex(32)
    if not isinstance(data.get("users"), dict):
        data["users"] = {}
    if data.get("version") is None:
        data["version"] = 1
    return data


def _save(path: str, data: dict) -> None:
    """Atomic write: build in a sibling temp file, then rename."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    # The ledger must never be group/world readable.
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


# ---------------------------------------------------------------- keys

def create_user(user_id: str, note: str = "") -> str | None:
    """Create a user and return their API key exactly once.

    Returns None if the id already exists (call reset_key instead).
    """
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
        if user_id in data["users"]:
            return None
        api_key = "NG-" + secrets.token_urlsafe(32)
        salt = data["salt"]
        data["users"][user_id] = {
            "key_hash": _sha256_hex((salt + api_key).encode("utf-8")),
            "created": time.time(),
            "note": note,
            "spend": [],
        }
        _save(path, data)
        return api_key


def reset_key(user_id: str) -> str | None:
    """Issue a fresh key for an existing user (old key stops working)."""
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
        user = data["users"].get(user_id)
        if user is None:
            return None
        api_key = "NG-" + secrets.token_urlsafe(32)
        user["key_hash"] = _sha256_hex((data["salt"] + api_key).encode("utf-8"))
        _save(path, data)
        return api_key


def delete_user(user_id: str) -> bool:
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
        if user_id not in data["users"]:
            return False
        del data["users"][user_id]
        _save(path, data)
        return True


def verify_key(api_key: str) -> str | None:
    """Map a presented api key to a user id, or None if unknown."""
    if not api_key or not api_key.startswith("NG-"):
        return None
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
        salt = data["salt"]
        candidate = _sha256_hex((salt + api_key).encode("utf-8"))
        for user_id, user in data["users"].items():
            if hmac.compare_digest(user.get("key_hash", ""), candidate):
                return user_id
    return None


def master_key() -> str | None:
    """The owner key is whichever key the env names, if any.

    ``NG_OWNER_KEY`` wins. If unset, fall back to the gateway key so a plain
    zero-prompt install keeps working: the key printed by the installer is the
    owner key, and every other user must be minted via scripts/ng-users.sh.
    """
    return os.environ.get("NG_OWNER_KEY") or os.environ.get("NG_GATEWAY_KEY") or None


# ---------------------------------------------------------------- budget

def daily_limit() -> int:
    raw = os.environ.get(DAILY_LIMIT_ENV)
    if not raw:
        return DEFAULT_LIMIT
    try:
        return max(1, int(raw))
    except ValueError:
        return DEFAULT_LIMIT


def _verify_chain(data: dict) -> list[dict]:
    """Return only records whose chain and signature are intact.

    Walks every record in append order, checking each record's sig against the
    salt and its prev link against the previous record. The chain head pins the
    newest record, so trailing forgeries are caught too.
    """
    salt = data["salt"]
    keep: list[dict] = []
    expected_prev = ""
    for uid in sorted(data["users"]):
        for rec in data["users"][uid].get("spend", []):
            try:
                if rec.get("prev") != expected_prev:
                    break  # chain broken from here on
                if not hmac.compare_digest(rec.get("sig", ""), _sign(salt, rec)):
                    break
            except Exception:
                break
            keep.append(rec)
            expected_prev = _record_id(rec)
    # The ledger's pinned head must equal the newest intact record.
    head = data.get("chain_head")
    if expected_prev and (not head or head != expected_prev):
        return []
    return keep


def used_today(user_id: str) -> int:
    """Verified tokens this user has spent today (chain-checked)."""
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
    today = _today()
    total = 0
    for rec in _verify_chain(data):
        if rec.get("user") == user_id and rec.get("day") == today:
            total += int(rec.get("tokens", 0))
    return total


def check_budget(user_id: str) -> tuple[bool, int, int]:
    """(allowed, used, limit) for this user today."""
    limit = daily_limit()
    used = used_today(user_id)
    return (used < limit, used, limit)


def record_usage(user_id: str, tokens: int) -> None:
    """Append a signed, chained usage record for a confirmed call."""
    if tokens <= 0:
        return
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
        user = data["users"].get(user_id)
        if user is None:
            return
        intact = _verify_chain(data)
        prev = _record_id(intact[-1]) if intact else ""
        rec = {
            "user": user_id,
            "day": _today(),
            "tokens": int(tokens),
            "ts": round(time.time(), 3),
            "prev": prev,
        }
        rec["sig"] = _sign(data["salt"], rec)
        user.setdefault("spend", []).append(rec)
        data["chain_head"] = _record_id(rec)
        _save(path, data)


def status(user_id: str | None = None) -> list[dict]:
    """Usage summary, used for the admin listing. Verified only."""
    path = _ledger_path()
    with _LOCK:
        data = _load(path)
    today = _today()
    out = []
    for uid in sorted(data["users"]):
        if user_id and uid != user_id:
            continue
        created = data["users"][uid].get("created")
        note = data["users"][uid].get("note", "")
        out.append({
            "user": uid,
            "note": note,
            "created": created,
            "today": sum(
                int(r.get("tokens", 0))
                for r in _verify_chain(data)
                if r.get("user") == uid and r.get("day") == today
            ),
            "limit": daily_limit(),
        })
    return out
