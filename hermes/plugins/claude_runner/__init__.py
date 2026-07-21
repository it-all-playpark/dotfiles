"""claude_runner plugin — registers the dispatch_job tool.

This registers ``dispatch_job`` via ``ctx.register_tool()`` per the
integration contract confirmed against the installed hermes 0.13.0
(``hermes_cli/plugins.py:317`` — ``PluginContext.register_tool(name,
toolset, schema, handler, check_fn, requires_env, is_async, description,
emoji)``). The real dispatch flow (repo_bindings lookup, origin clone,
``claude --bg`` launch, manifest reconcile) lives in ``dispatch.py`` (S2);
``register()`` below wires ``dispatch.dispatch_job`` in as the handler. The
tool name/toolset/schema/argument order fixed in S1 must not change.
``_dispatch_job_stub`` is kept (unused by ``register()``) only because it is
still exercised directly by ``tests/test_registration.py``.

Inbound message dedupe is intentionally *not* handled here — per
architecture_decisions it belongs to the gateway platform adapter layer
(``gateway/platforms/wecom_callback.py`` ``_seen_messages`` pattern), not to
plugin hooks (no inbound-message hook exists in the invoke_hook surface).

``register()`` also wires ``guard.check`` in as a ``pre_tool_call`` hook
(S3): this is a second, independent defense layer that vetoes an
insufficiently-bound ``dispatch_job`` call even if the in-handler binding
check inside ``dispatch.dispatch_job`` regresses. Follows the verified
``register_hook('pre_tool_call', fn)`` pattern already used by
``hermes/plugins/path_guard``.
"""

from __future__ import annotations

from typing import Any, Dict

from tools.registry import tool_error

from . import guard
from .dispatch import dispatch_job

DISPATCH_SCHEMA: Dict[str, Any] = {
    "name": "dispatch_job",
    "description": (
        "Dispatch a ChatOps job: resolve the requesting channel's bound "
        "repo(s) via repo_bindings.yaml, clone from origin, launch "
        "`claude --bg` against the clone in a per-job container, and "
        "reconcile the resulting bg job id into the job manifest."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "platform": {
                "type": "string",
                "description": "Source ChatOps platform (e.g. slack, discord, google_chat).",
            },
            "channel": {
                "type": "string",
                "description": "Platform channel id the request came from; used for repo_bindings.yaml lookup.",
            },
            "prompt": {
                "type": "string",
                "description": "The user's request to hand to `claude --bg`.",
            },
            "repo": {
                "type": "string",
                "description": (
                    "Optional owner/name override. When omitted, dispatch "
                    "fans out to every repo bound to (platform, channel)."
                ),
            },
        },
        "required": ["platform", "channel", "prompt"],
    },
}


def _dispatch_job_stub(args: dict, **kwargs) -> str:
    """S1-era placeholder handler. No longer registered (see ``register()``
    below, which wires in ``dispatch.dispatch_job`` instead) — retained so
    the S1 regression test in ``tests/test_registration.py`` keeps passing.
    """
    return tool_error(
        "dispatch_job is not implemented yet (claude_runner scaffold; see S2)"
    )


def register(ctx) -> None:
    """Register the dispatch_job tool and its pre_tool_call guard. Called
    once by the plugin loader."""
    ctx.register_tool(
        name="dispatch_job",
        toolset="claude_runner",
        schema=DISPATCH_SCHEMA,
        handler=dispatch_job,
        description=DISPATCH_SCHEMA["description"],
        emoji="🚀",
    )
    ctx.register_hook("pre_tool_call", guard.check)
