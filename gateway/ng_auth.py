"""NG-Opus-Gateway custom auth.

Wired into gateway/litellm-config.yaml as ``general_settings.custom_auth``.
This is what makes litellm accept per-user keys without a database: litellm
hands us the request and the presented api key, and we return a
``UserAPIKeyAuth`` describing who it belongs to.

Rules:
  * Keys minted by the ledger (gateway/ng_users.py), format ``NG-...``.
  * The owner/admin key from NG_OWNER_KEY acts as master: full access, no
    budget. It is only read from the environment, never from the repo.
  * Anything else is 401.

A rejected/over-budget request never reaches the upstream.
"""

from __future__ import annotations

import os

from litellm.proxy._types import UserAPIKeyAuth


def _ledger():
    """Load ng_users.py from this file's directory.

    litellm loads custom_auth by file path (get_instance_fn), so the gateway
    directory is not on sys.path and a plain ``import ng_users`` can fail.
    Resolve the sibling explicitly.
    """
    import importlib.util

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "ng_users.py")
    spec = importlib.util.spec_from_file_location("ng_users", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load ng_users.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _role_admin() -> int:
    # LitellmUserRoles.PROXY_ADMIN.value
    try:
        from litellm.proxy._types import LitellmUserRoles
    except Exception:  # pragma: no cover
        return 2
    try:
        return LitellmUserRoles.PROXY_ADMIN.value
    except Exception:
        return 2


async def user_api_key_auth(request, api_key: str) -> UserAPIKeyAuth:
    """Validate an incoming api key against the local ledger."""
    ng_users = _ledger()

    if not isinstance(api_key, str) or not api_key:
        from fastapi import HTTPException

        raise HTTPException(status_code=401, detail="Missing API key")

    owner_key = ng_users.master_key()
    if owner_key and api_key == owner_key:
        return UserAPIKeyAuth(
            token=api_key,
            user_id="__owner__",
            user_role=_role_admin(),
            api_key=api_key,
        )

    user = ng_users.verify_key(api_key)
    if user is None:
        from fastapi import HTTPException

        raise HTTPException(
            status_code=401,
            detail="Invalid API key. Ask the gateway owner for an NG key.",
        )

    return UserAPIKeyAuth(
        token=api_key,
        user_id=user,
        api_key=api_key,
    )
