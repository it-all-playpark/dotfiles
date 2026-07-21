"""``repo_bindings.yaml`` loader + schema validator (fail-closed).

Schema::

    platforms:
      <platform>:               # e.g. slack, discord, google_chat
        channels:
          <channel_id>:
            repos:
              - owner/name

Any structural violation raises :class:`BindingsError` — this module
deliberately does not fall back to a permissive default. ``dispatch_job``
must treat an invalid ``repo_bindings.yaml`` as "no bindings available" and
refuse to dispatch rather than silently allowing an unbound channel through
(plan AC-8, edge_cases: repo_bindings.yaml schema 不正).
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")

DEFAULT_BINDINGS_PATH = Path(__file__).resolve().parents[2] / "repo_bindings.yaml"


class BindingsError(ValueError):
    """Raised when repo_bindings.yaml fails schema validation (fail-closed)."""


def fail_closed_message(exc: "BindingsError") -> str:
    """Uniform fail-closed refusal message for a ``BindingsError``.

    Both of ``dispatch_job``'s independent enforcement points — the
    in-handler check in ``dispatch.py`` (S2) and the ``pre_tool_call`` guard
    in ``guard.py`` (S3) — catch ``BindingsError`` and must refuse the
    dispatch with the *same* reason (AC-8: fail-closed on a structurally
    invalid ``repo_bindings.yaml``). Centralizing the message here keeps
    both call sites from drifting apart."""
    return f"repo_bindings.yaml invalid, dispatch refused (fail-closed): {exc}"


def bindings_path() -> Path:
    """Return the path to load repo_bindings.yaml from, honoring the
    ``HERMES_REPO_BINDINGS_PATH`` override used by tests/alt deployments."""
    override = os.environ.get("HERMES_REPO_BINDINGS_PATH")
    return Path(override).expanduser() if override else DEFAULT_BINDINGS_PATH


def load_bindings(path: Optional[Path] = None) -> Dict[str, Any]:
    """Load and validate repo_bindings.yaml.

    Raises :class:`BindingsError` on any schema violation — callers must not
    swallow this exception (fail-closed per architecture_decisions).
    """
    target = path or bindings_path()
    with open(target, "r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    validate_bindings(raw)
    return raw


def validate_bindings(raw: Any) -> None:
    """Raise BindingsError if ``raw`` doesn't satisfy the bindings schema."""
    if not isinstance(raw, dict):
        raise BindingsError("repo_bindings.yaml root must be a mapping")

    platforms = raw.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        raise BindingsError(
            "repo_bindings.yaml must define a non-empty 'platforms' mapping"
        )

    for platform_name, platform_cfg in platforms.items():
        if not isinstance(platform_cfg, dict):
            raise BindingsError(f"platforms.{platform_name} must be a mapping")

        channels = platform_cfg.get("channels")
        if not isinstance(channels, dict) or not channels:
            raise BindingsError(
                f"platforms.{platform_name}.channels must be a non-empty mapping"
            )

        for channel_id, channel_cfg in channels.items():
            if not isinstance(channel_cfg, dict):
                raise BindingsError(
                    f"platforms.{platform_name}.channels.{channel_id} must be a mapping"
                )

            repos = channel_cfg.get("repos")
            if not isinstance(repos, list) or not repos:
                raise BindingsError(
                    f"platforms.{platform_name}.channels.{channel_id}.repos "
                    "must be a non-empty list"
                )

            for repo in repos:
                if not isinstance(repo, str) or not REPO_SLUG_RE.match(repo):
                    raise BindingsError(
                        f"platforms.{platform_name}.channels.{channel_id} "
                        f"has invalid repo slug: {repo!r}"
                    )


def resolve_repos(bindings: Dict[str, Any], platform: str, channel: str) -> List[str]:
    """Return the repo list bound to ``(platform, channel)``, or ``[]`` if
    that platform/channel isn't bound."""
    platforms = bindings.get("platforms") or {}
    channels = (platforms.get(platform) or {}).get("channels") or {}
    channel_cfg = channels.get(channel) or {}
    return list(channel_cfg.get("repos") or [])
