"""``pre_tool_call`` guard for ``dispatch_job`` (S3, AC-8/AC-12).

This is a second, independent defense layer on top of the in-handler
binding check already performed by ``dispatch.dispatch_job`` (S2): even if
that handler-side validation regresses, this hook still vetoes an
unbound channel / invalid ``repo`` override / structurally invalid
``repo_bindings.yaml`` before the tool call is allowed to proceed
(fail-closed, per architecture_decisions and edge_cases: 未bound
channel・mention なし・allowlist 外ユーザからの依頼).

Follows the verified ``register_hook('pre_tool_call', fn)`` integration
point and block-dict return shape from
``hermes/plugins/path_guard/__init__.py`` (``_block_if_sensitive`` /
``register()``) — ``check()`` below returns a ``{"action": "block",
"message": ...}`` dict to veto, or ``None`` to let the call through
unchanged.

Only ``dispatch_job`` calls are inspected; every other ``tool_name`` is
passed through untouched (``None``).
"""

from __future__ import annotations

from typing import Any, Dict, Optional

from . import bindings as bindings_mod


def check(tool_name: str, args: Optional[Dict[str, Any]] = None, **_: Any) -> Optional[Dict[str, str]]:
    """``pre_tool_call`` hook: block an insufficiently-bound ``dispatch_job``
    call, otherwise return ``None`` (allow / pass through).
    """
    if tool_name != "dispatch_job":
        return None

    args = args or {}
    platform = args.get("platform")
    channel = args.get("channel")
    prompt = args.get("prompt")
    repo_override = args.get("repo")

    if not platform or not channel or not prompt:
        return {
            "action": "block",
            "message": (
                "claude_runner guard: dispatch_job requires platform, "
                "channel, and prompt (fail-closed)"
            ),
        }

    try:
        bindings = bindings_mod.load_bindings()
    except bindings_mod.BindingsError as exc:
        return {
            "action": "block",
            "message": (
                f"claude_runner guard: repo_bindings.yaml invalid, "
                f"dispatch refused (fail-closed): {exc}"
            ),
        }

    bound_repos = bindings_mod.resolve_repos(bindings, platform, channel)
    if not bound_repos:
        return {
            "action": "block",
            "message": (
                f"claude_runner guard: channel {channel!r} on platform "
                f"{platform!r} is not bound to any repo; dispatch refused "
                "(fail-closed)"
            ),
        }

    if repo_override is not None and repo_override not in bound_repos:
        return {
            "action": "block",
            "message": (
                f"claude_runner guard: repo {repo_override!r} is not bound "
                f"to channel {channel!r}; dispatch refused (fail-closed)"
            ),
        }

    return None
