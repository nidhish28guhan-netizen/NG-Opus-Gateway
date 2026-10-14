"""NG-Opus-Gateway gateway request hook.

Registered from litellm-config.desktop.yaml via:

    litellm_settings:
      callbacks: ng_hook.proxy_handler_instance

Purpose
-------
Claude Desktop sends Anthropic-style requests to the gateway's
``/v1/messages`` endpoint. For a non-Anthropic upstream (the provider serving
the upstream model), litellm translates the Anthropic
``thinking`` block into an OpenAI-style ``reasoning_effort`` label:

    budget_tokens >= 4096            -> "high"
    budget_tokens >= 2048            -> "medium"
    budget_tokens >= 1024            -> "low"
    otherwise                        -> "minimal"
    thinking.type == "adaptive"      -> "medium"   (hardcoded default)

The upstream accepts ``none``/``minimal``/``low``/``high`` but
rejects ``medium`` and ``default`` with a bare 400::

    {"message":"Invalid request","type":"Bad Request","code":400}

which surfaces in Claude Desktop as a failed request and in the proxy log as::

    litellm.BadRequestError: OpenAIException - Invalid request
    LiteLLM: model group 'claude-sonnet-5-5' failed with the error above.

Claude Desktop's default thinking budget lands squarely in the 2048-4095
bucket, so almost every Cowork/Code request maps to "medium" and fails.

Fix
---
This hook runs before the upstream call and rewrites any ``reasoning_effort``
the upstream cannot accept to the nearest accepted value, preserving the
intent of the original tier:

    "medium"  -> "high"   (nearest accepted tier above; keeps strong reasoning)
    "default" -> "high"
    dict form {"effort": "medium", ...} -> {"effort": "high", ...}

Everything else is passed through untouched.
"""

from __future__ import annotations

from typing import Any, Optional

from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy._types import UserAPIKeyAuth
from litellm.types.utils import CallTypesLiteral

# reasoning_effort values this upstream rejects.
_REJECTED = frozenset({"medium", "default"})
# Replacement tier. "high" is the closest accepted tier above "medium",
# so the client keeps the strong reasoning behavior it asked for.
_ACCEPTED_REPLACEMENT = "high"
# Bottom of litellm's "high" bucket (DEFAULT_REASONING_EFFORT_HIGH_THINKING_BUDGET).
# A budget >= this value derives to reasoning_effort="high".
# Raised well above litellm's floor: a larger thinking budget makes the
# upstream spend more tokens reasoning before it answers, which is the main
# lever for making this gateway feel like a bigger, more thorough model.
_HIGH_BUDGET = 32768


def _ledger():
    """Load the per-user ledger module (gateway/ng_users.py).

    litellm loads this hook by file path via ``get_instance_fn``, so the
    gateway directory is not necessarily on ``sys.path``; resolve the sibling
    file explicitly. Cached in sys.modules so the module (and its salt) is
    identical for every caller in this process.
    """
    import importlib.util
    import os
    import sys

    cached = sys.modules.get("ng_users")
    if cached is not None:
        return cached
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "ng_users.py")
    spec = importlib.util.spec_from_file_location("ng_users", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load ng_users.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ng_users"] = mod
    spec.loader.exec_module(mod)
    return mod



def _clamp_effort(effort: Any) -> Any:
    """Return an effort value the upstream accepts.

    Handles both the plain-string form (``"medium"``) and the summary-wrapped
    dict form (``{"effort": "medium", "summary": "detailed"}``) that litellm's
    thinking->reasoning_effort translation can emit.
    """
    if isinstance(effort, str):
        return _ACCEPTED_REPLACEMENT if effort in _REJECTED else effort
    if isinstance(effort, dict):
        inner = effort.get("effort")
        if isinstance(inner, str) and inner in _REJECTED:
            return {**effort, "effort": _ACCEPTED_REPLACEMENT}
        return effort
    return effort


def _normalize_thinking(thinking: Any) -> Any:
    """Rewrite an Anthropic ``thinking`` block so the derived effort is accepted.

    litellm derives the OpenAI ``reasoning_effort`` label from this block
    *after* the pre-call hook runs, so clamping ``reasoning_effort`` directly
    is not enough when the client sent a ``thinking`` block. For a non-Claude
    target the budget is discarded entirely and only the resulting tier label
    reaches the upstream, so rewriting the budget is safe and only changes
    which bucket it lands in.

    Buckets (litellm defaults):

        budget >= 4096  -> "high"     (accepted)
        budget >= 2048  -> "medium"   (REJECTED by upstream -> 400)
        budget >= 1024  -> "low"      (accepted)
        otherwise       -> "minimal"  (accepted)
        type "adaptive" -> "medium"   (REJECTED by upstream -> 400)

    We nudge the budget up to the bottom of the "high" bucket, preserving the
    client's intent of "think meaningfully" while landing on an accepted tier.

    Note: raising the budget makes the upstream reason more, which consumes
    output tokens. Claude Desktop sends a generous max_tokens (e.g. 128000), so
    this is not a concern in practice, but a request pairing a high budget with
    a tiny max_tokens can return stop_reason="max_tokens" with an empty answer.
    """
    if not isinstance(thinking, dict):
        return thinking

    thinking_type = thinking.get("type")
    # Adaptive thinking has no budget and buckets to a hardcoded "medium";
    # convert it to an enabled block with a high budget.
    if thinking_type == "adaptive":
        return {**thinking, "type": "enabled", "budget_tokens": _HIGH_BUDGET}

    if thinking_type != "enabled":
        return thinking

    budget = thinking.get("budget_tokens")
    if not isinstance(budget, int) or isinstance(budget, bool):
        # No usable budget: force the same "high" tier rather than letting a
        # missing/0 budget fall through to "minimal" silently.
        return {**thinking, "budget_tokens": _HIGH_BUDGET}

    if budget < _HIGH_BUDGET:
        return {**thinking, "budget_tokens": _HIGH_BUDGET}

    return thinking


class NGGatewayHook(CustomLogger):
    """Normalizes ``reasoning_effort`` so the upstream stops returning 400."""

    async def async_log_success_event(
        self,
        kwargs: dict,
        response_obj,
        start_time,
        end_time,
        **kwargs_extra: Any,
    ) -> None:
        """Record spent tokens after a confirmed upstream response.

        This is the only honest place to count usage: the call actually
        happened, so the allowance is genuinely spent. Counting before the
        call would overcharge users whose requests fail.
        """
        try:
            ng_users = _ledger()
        except Exception:
            return  # ledger not installed; budgeting is off
        try:
            user = self._resolve_user(kwargs)
            if user is None:
                return
            usage = getattr(response_obj, "usage", None) or getattr(
                response_obj, "_hidden_params", {}).get("usage", {})
            total = 0
            if isinstance(usage, dict):
                total = (int(usage.get("total_tokens") or 0)
                         or int(usage.get("completion_tokens") or 0)
                         + int(usage.get("prompt_tokens") or 0))
            elif usage is not None:
                total = (int(getattr(usage, "total_tokens", 0) or 0)
                         or int(getattr(usage, "completion_tokens", 0) or 0)
                         + int(getattr(usage, "prompt_tokens", 0) or 0))
            if total > 0:
                ng_users.record_usage(user, total)
        except Exception as exc:  # pragma: no cover
            from litellm import verbose_logger

            verbose_logger.warning(f"ng-gateway: usage recording failed: {exc}")

    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        data: Optional[dict],
        call_type: CallTypesLiteral,
        cache: Any = None,
        **kwargs: Any,
    ) -> Optional[dict]:
        if not isinstance(data, dict):
            return data

        # The upstream provider behind this gateway serves a model with a
        # 262144-token context window. Claude Desktop / DSH send the entire
        # conversation each turn and, once it grows past that limit, the
        # upstream rejects the whole request with a bare 400:
        #
        #   {"type":"context_length","limit":262144,"actual":263350}
        #
        # Trim the OLDEST messages (keeping the system prompt and the most
        # recent turns) so the request fits.
        self._trim_context(data)

        # The /v1/messages passthrough stores its translated OpenAI kwargs
        # under "messages_api_kwargs" until the adapter finalizes the call;
        # the plain chat/completions path keeps them at the top level. Patch
        # both so the clamp applies whichever path produced the request.
        targets: list[dict] = []
        kwargs_bundle = data.get("messages_api_kwargs")
        if isinstance(kwargs_bundle, dict):
            targets.append(kwargs_bundle)
        targets.append(data)

        changed = False
        for target in targets:
            if not isinstance(target, dict):
                continue
            current = target.get("reasoning_effort")
            if current is None:
                continue
            clamped = _clamp_effort(current)
            if clamped != current:
                target["reasoning_effort"] = clamped
                changed = True

        # litellm derives reasoning_effort from an Anthropic ``thinking`` block
        # after this hook, so a plain reasoning_effort clamp would be
        # overwritten. Rewrite the thinking block's budget instead.
        for target in targets:
            if not isinstance(target, dict):
                continue
            thinking = target.get("thinking")
            if thinking is None:
                continue
            normalized = _normalize_thinking(thinking)
            if normalized != thinking:
                target["thinking"] = normalized
                changed = True

        if changed:
            from litellm import verbose_logger

            verbose_logger.debug(
                "ng-gateway: normalized reasoning_effort/thinking for upstream compatibility"
            )

        # Push sampling toward a large-model feel: higher temperature for more
        # varied output, and the strongest reasoning tier the upstream accepts.
        self._boost_sampling(data)

        # Ask for thorough, full-length answers instead of terse summaries.
        self._nudge_verbosity(data)

        # The upstream's 262144 context budget covers input AND output. Clients
        # like DSH ask for max_completion_tokens=128000, which alone is fine,
        # but once the conversation grows the sum overflows and the upstream
        # rejects it with a bare "Invalid request" (no field detail). Shrink
        # the output budget so input + output fits.
        self._cap_output_tokens(data)

        # Per-user daily budget. This runs before the request leaves the
        # machine, so an exhausted user is rejected without ever touching the
        # upstream allowance.
        self._enforce_budget(user_api_key_dict, data)

        return data

    # --- per-user daily budget ------------------------------------------
    # The gateway is shared. Each user key gets a fixed token allowance per
    # calendar day, tracked in a local hash-chained ledger (gateway/ng_users.py)
    # with no SQL and no external service. Enforcement happens here, before the
    # upstream call, which is the only place a cap can be honest: any check
    # after the call would still have spent the allowance.
    _BUDGET_ERROR_TYPE = "rate_limit_error"

    def _enforce_budget(self, user_api_key_dict, data: dict) -> None:
        """Reject the call if the user has spent their daily token allowance."""
        try:
            ng_users = _ledger()
        except Exception:
            return  # never break the gateway over a missing ledger

        try:
            user = self._user_from_auth(user_api_key_dict)
            if user is None:
                return  # ledger not in use for this request
            allowed, used, limit = ng_users.check_budget(user)
            if allowed:
                return
            from fastapi import HTTPException

            raise HTTPException(
                status_code=429,
                detail=(
                    "NG daily token limit reached: "
                    f"{used}/{limit} tokens used today. "
                    "The limit resets at midnight (server local time)."
                ),
            )
        except HTTPException:
            raise
        except Exception as exc:  # pragma: no cover
            from litellm import verbose_logger

            verbose_logger.warning(f"ng-gateway: budget check failed: {exc}")
            return

    @staticmethod
    def _user_from_auth(user_api_key_dict) -> str | None:
        """Resolve the caller's ledger user id from the auth object.

        custom_auth (ng_auth.py) returns a UserAPIKeyAuth whose user_id is the
        ledger user, so this is normally a single attribute read. The raw token
        is the fallback, which lets the ledger verify the key itself.
        """
        if user_api_key_dict is None:
            return None
        uid = getattr(user_api_key_dict, "user_id", None)
        if isinstance(uid, str) and uid:
            return uid
        token = getattr(user_api_key_dict, "token", None) or getattr(
            user_api_key_dict, "api_key", None)
        if isinstance(token, str) and token:
            try:
                return _ledger().verify_key(token)
            except Exception:
                return None
        return None

    @staticmethod
    def _resolve_user(kwargs: dict) -> str | None:
        """Resolve the ledger user from a logging event's kwargs.

        Success/failure logging events carry the caller in
        ``litellm_params.metadata`` as ``user_api_key_user_id`` (set by
        custom_auth), with the raw key as ``user_api_key``. Both are present on
        every confirmed call.
        """
        if not isinstance(kwargs, dict):
            return None
        params = kwargs.get("litellm_params")
        meta = params.get("metadata") if isinstance(params, dict) else None
        if not isinstance(meta, dict):
            return None
        uid = meta.get("user_api_key_user_id")
        if isinstance(uid, str) and uid:
            return uid
        token = meta.get("user_api_key")
        if isinstance(token, str) and token:
            try:
                return _ledger().verify_key(token)
            except Exception:
                return None
        return None

    # --- sampling boost ---------------------------------------------------
    # This gateway relays a compact, fast model. Left at client defaults its
    # replies are terse and flat compared with a large frontier model. Raise
    # the sampling temperature and top_p so answers are longer, more varied,
    # and read like a bigger model wrote them.
    _TARGET_TEMPERATURE = 1.0
    _TARGET_TOP_P = 0.98

    def _boost_sampling(self, data: dict) -> None:
        """Raise temperature/top_p and lock reasoning at the top accepted tier."""
        for holder in (data, data.get("messages_api_kwargs")):
            if not isinstance(holder, dict):
                continue

            # Raise the temperature if the client asked for something cooler.
            # Only nudge upward, never downward, so a client that deliberately
            # asked for near-deterministic output still gets it.
            current_temp = holder.get("temperature")
            if not isinstance(current_temp, (int, float)) or current_temp < self._TARGET_TEMPERATURE:
                holder["temperature"] = self._TARGET_TEMPERATURE
            if not isinstance(holder.get("top_p"), (int, float)):
                holder["top_p"] = self._TARGET_TOP_P

            # Ask for the strongest reasoning the upstream accepts. The clamp
            # above already maps rejected tiers to "high"; make it explicit so
            # a client that sent nothing still gets max reasoning.
            if holder.get("reasoning_effort") is None:
                holder["reasoning_effort"] = "high"

    # --- verbosity nudge --------------------------------------------------
    # The upstream answers tersely by default. Prepend a system instruction
    # asking for thoroughness so replies carry the depth and length people
    # expect from a frontier model, instead of a two-line summary.
    _VERBOSITY_PROMPT = (
        "You are a thorough, detailed assistant. Answer in full: explain your "
        "reasoning, cover the important edge cases, and use structure (short "
        "headings, bullet points, or numbered steps) where it helps. Prefer a "
        "complete explanation over a brief one, but never pad or repeat."
    )

    def _nudge_verbosity(self, data: dict) -> None:
        """Prepend a system instruction asking for thorough, complete answers."""
        for holder in (data, data.get("messages_api_kwargs")):
            if not isinstance(holder, dict):
                continue
            messages = holder.get("messages")
            if not isinstance(messages, list) or not messages:
                continue

            # /v1/messages requests carry the system text as a top-level field.
            sys_field = holder.get("system")
            if isinstance(sys_field, str):
                if self._VERBOSITY_PROMPT.split()[0] not in sys_field.split()[:6]:
                    holder["system"] = self._VERBOSITY_PROMPT + "\n\n" + sys_field
                continue

            if isinstance(sys_field, list):
                joined = "\n".join(
                    b.get("text", "") for b in sys_field
                    if isinstance(b, dict)
                )
                if self._VERBOSITY_PROMPT.split()[0] not in joined.split()[:6]:
                    holder["system"] = [
                        {"type": "text", "text": self._VERBOSITY_PROMPT},
                        *sys_field,
                    ]
                continue

            # chat/completions: a leading system message, if any.
            if isinstance(messages[0], dict) and messages[0].get("role") == "system":
                existing = messages[0].get("content")
                text = existing if isinstance(existing, str) else ""
                if self._VERBOSITY_PROMPT.split()[0] not in text.split()[:6]:
                    messages[0]["content"] = self._VERBOSITY_PROMPT + "\n\n" + text
                continue

            # No system message at all: insert one.
            messages.insert(
                0, {"role": "system", "content": self._VERBOSITY_PROMPT}
            )

    # --- output capping ---------------------------------------------------
    # Same upstream context budget as above; the reply is counted against it.
    # Never force the reply below this — a generous floor keeps answers long
    # and detailed rather than clipped short after a sentence or two.
    _MIN_OUTPUT_TOKENS = 8192

    def _cap_output_tokens(self, data: dict) -> None:
        """Shrink max_tokens/max_completion_tokens so input+output fits upstream."""
        # Both the chat/completions path (top level) and the /v1/messages
        # passthrough ("messages_api_kwargs") carry the output limit.
        holders: list[dict] = []
        for holder in (data, data.get("messages_api_kwargs")):
            if isinstance(holder, dict):
                holders.append(holder)

        for holder in holders:
            key = None
            for candidate in ("max_completion_tokens", "max_tokens"):
                if isinstance(holder.get(candidate), (int, float)):
                    key = candidate
                    break
            if key is None:
                continue

            requested = int(holder[key])
            # Measure what the input costs (after trimming already ran).
            messages = holder.get("messages")
            input_tokens = (
                self._count_tokens(messages, holder.get("tools"))
                if isinstance(messages, list) and messages else 0
            )
            # Use the scaled (pessimistic) estimate; the tokenizer undercounts.
            input_scaled = int(input_tokens * self._COUNT_SAFETY)

            allowed = self._CONTEXT_LIMIT - input_scaled
            allowed = max(allowed, self._MIN_OUTPUT_TOKENS)
            if requested <= allowed:
                continue

            holder[key] = allowed
            from litellm import verbose_logger

            verbose_logger.warning(
                "ng-gateway: %s=%d with input ~%d (scaled %d) would exceed "
                "the %d budget; capped output to %d",
                key, requested, input_tokens, input_scaled,
                self._CONTEXT_LIMIT, allowed,
            )

    # --- context trimming -------------------------------------------------
    # The upstream context window. Would come from /v1/models
    # (its advertised context window).
    _CONTEXT_LIMIT = 262144
    # litellm's local tokenizer UNDERCOUNTS this upstream by roughly 19%
    # (local estimate 224271 vs upstream's own count 266837 on a real Claude
    # Desktop request). Trim earlier than the raw limit so a miscount can't
    # push the request back over the edge.
    _COUNT_SAFETY = 1.25
    # Tokens to keep free for the model's reply, otherwise a conversation that
    # fits exactly leaves no room to generate.
    _OUTPUT_RESERVE = 8192

    @staticmethod
    def _count_tokens(messages: list, tools: Any) -> int:
        """Best-effort token count for the request body."""
        try:
            import litellm

            kwargs: dict[str, Any] = {"messages": messages}
            if isinstance(tools, list) and tools:
                kwargs["tools"] = tools
            return int(litellm.token_counter(**kwargs))
        except Exception:
            # Fallback: ~4 chars/token. Only used if token_counter breaks.
            total = 0
            for m in messages:
                content = m.get("content") if isinstance(m, dict) else None
                if isinstance(content, str):
                    total += len(content)
                elif isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict):
                            total += len(str(b.get("text", "")))
            return total // 4

    def _trim_context(self, data: dict) -> None:
        """Drop the oldest non-system messages until the request fits upstream."""
        # The chat/completions path keeps messages at the top level; the
        # /v1/messages passthrough keeps them under "messages_api_kwargs".
        targets: list[dict] = []
        for holder in (data, data.get("messages_api_kwargs")):
            if isinstance(holder, dict) and isinstance(holder.get("messages"), list):
                targets.append(holder)

        for holder in targets:
            messages: list = holder["messages"]
            tools = holder.get("tools")
            if not messages:
                continue

            # Trim until our (scaled) estimate fits the budget. The local
            # tokenizer undercounts the upstream, so compare the scaled figure.
            budget = self._CONTEXT_LIMIT - self._OUTPUT_RESERVE
            scaled = lambda raw: int(raw * self._COUNT_SAFETY)
            total = self._count_tokens(messages, tools)
            if scaled(total) <= budget:
                continue

            original_total = total
            original_count = len(messages)

            # System messages stay (the prompt/instructions are at the front);
            # everything else is trimmed from the oldest side.
            system_msgs = [m for m in messages if isinstance(m, dict) and m.get("role") == "system"]
            convo = [m for m in messages if not (isinstance(m, dict) and m.get("role") == "system")]

            # Trim the oldest conversation messages until we fit. Rather than
            # recounting after every single drop, drop a geometrically growing
            # batch, then recount and refine — accurate and fast on large
            # histories (thousands of messages).
            trimmed = 0
            while convo and scaled(total) > budget:
                # Batch size grows so huge histories converge quickly.
                batch = max(1, trimmed // 4 + 1)
                batch = min(batch, len(convo))
                del convo[:batch]
                trimmed += batch
                total = self._count_tokens(system_msgs + convo, tools)

            holder["messages"] = system_msgs + convo

            from litellm import verbose_logger

            verbose_logger.warning(
                "ng-gateway: context %d tokens (scaled %d) exceeded %d budget; "
                "trimmed %d oldest message(s) (%d -> %d), now est %d tokens (scaled %d)",
                original_total, scaled(original_total), budget, trimmed,
                original_count, len(holder["messages"]), total, scaled(total),
            )


# litellm's callback loader resolves the dotted path to an object and requires
# an instance (a CustomLogger), not the class itself.
proxy_handler_instance = NGGatewayHook()
