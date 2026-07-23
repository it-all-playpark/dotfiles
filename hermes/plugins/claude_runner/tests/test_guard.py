"""Tests for the claude_runner ``pre_tool_call`` guard (S3, AC-8/AC-12).

This is the second, independent defense layer for ``dispatch_job``: even if
the in-handler binding check (S2, ``dispatch.dispatch_job``) regresses, the
``pre_tool_call`` hook registered here must still veto an unbound/invalid
dispatch before it reaches the handler. Follows the verified
``register_hook('pre_tool_call', fn)`` / block-dict pattern from
``hermes/plugins/path_guard/__init__.py`` (``_block_if_sensitive`` +
``register()``).

Three cases:

1. ``dispatch_job`` with an unbound (platform, channel) -> block.
2. ``dispatch_job`` with a bound (platform, channel) -> ``None`` (allow).
3. Any other ``tool_name`` -> ``None`` (pass through untouched).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[4]
HERMES_AGENT_ROOT = Path(
    os.environ.get("HERMES_AGENT_ROOT", "~/.hermes/hermes-agent")
).expanduser()

for _path in (str(HERMES_AGENT_ROOT), str(REPO_ROOT / "hermes" / "plugins")):
    if _path not in sys.path:
        sys.path.insert(0, _path)

pytest.importorskip("tools.registry", reason="hermes-agent venv not available")

from claude_runner import guard  # noqa: E402

BOUND_BINDINGS_YAML = """\
platforms:
  slack:
    channels:
      C0123456789:
        repos:
          - it-all-playpark/dotfiles
"""

INVALID_BINDINGS_YAML = """\
platforms:
  slack:
    channels:
      C1: {}
"""


def _write_bindings(tmp_path, content):
    path = tmp_path / "repo_bindings.yaml"
    path.write_text(content)
    return path


# ---------------------------------------------------------------------------
# 1. dispatch_job, unbound channel -> block
# ---------------------------------------------------------------------------


def test_dispatch_job_with_unbound_channel_is_blocked(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check(
        "dispatch_job",
        {"platform": "slack", "channel": "C_NOT_BOUND", "prompt": "do it"},
    )

    assert result is not None
    assert result["action"] == "block"
    assert "message" in result and isinstance(result["message"], str)


def test_dispatch_job_with_repo_override_not_bound_is_blocked(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check(
        "dispatch_job",
        {
            "platform": "slack",
            "channel": "C0123456789",
            "prompt": "do it",
            "repo": "some-other/repo",
        },
    )

    assert result is not None
    assert result["action"] == "block"


def test_dispatch_job_with_invalid_bindings_schema_is_blocked(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, INVALID_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check(
        "dispatch_job",
        {"platform": "slack", "channel": "C1", "prompt": "do it"},
    )

    assert result is not None
    assert result["action"] == "block"


def test_dispatch_job_with_missing_required_args_is_blocked(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check("dispatch_job", {"platform": "slack"})

    assert result is not None
    assert result["action"] == "block"


# ---------------------------------------------------------------------------
# 2. dispatch_job, bound channel -> allow (None)
# ---------------------------------------------------------------------------


def test_dispatch_job_with_bound_channel_is_allowed(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check(
        "dispatch_job",
        {
            "platform": "slack",
            "channel": "C0123456789",
            "prompt": "do it",
        },
    )

    assert result is None


# ---------------------------------------------------------------------------
# 3. other tool_name -> pass through untouched
# ---------------------------------------------------------------------------


def test_other_tool_name_is_passed_through(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    result = guard.check("some_other_tool", {"channel": "C_NOT_BOUND"})

    assert result is None
