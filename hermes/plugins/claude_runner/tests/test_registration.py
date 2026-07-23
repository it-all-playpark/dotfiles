"""Tests for the claude_runner plugin scaffold (S1).

Covers the three contracts locked in by the S1 spike:

1. ``register(ctx)`` registers ``dispatch_job`` into ``tools.registry`` (the
   real registry, via a thin ctx double whose ``register_tool`` mirrors
   ``PluginContext.register_tool``'s signature/order at
   ``hermes_cli/plugins.py:317`` and forwards straight into it — so this
   proves dispatch_job actually lands in the registry the way the real
   PluginContext would).
2. ``manifest.py`` keeps host and container paths in four separate fields
   through a build/write/read round trip (edge_cases: host<->container path
   mixup).
3. ``bindings.py`` raises (fail-closed) on a structurally invalid
   repo_bindings.yaml instead of silently permitting dispatch.

Run via ``tests/hermes-claude-runner.test.sh`` (uses the hermes-agent venv
so ``tools.registry`` is importable without vendoring a second dependency
set into this repo).
"""

from __future__ import annotations

import json
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

tools_registry = pytest.importorskip(
    "tools.registry",
    reason="hermes-agent venv not available (tools.registry import failed)",
)

import claude_runner  # noqa: E402  (sys.path setup above must run first)
from claude_runner import bindings as bindings_mod  # noqa: E402
from claude_runner import manifest as manifest_mod  # noqa: E402


class _FakePluginContext:
    """Double mirroring ``PluginContext.register_tool``'s signature/order
    (hermes_cli/plugins.py:317), forwarding into the real ``tools.registry``
    so tests exercise the same registration path the real plugin loader
    would use."""

    def __init__(self, name: str):
        self.manifest = type("_Manifest", (), {"name": name})()
        self.registered: list[str] = []
        self.hooks: dict[str, list] = {}

    def register_tool(
        self,
        name,
        toolset,
        schema,
        handler,
        check_fn=None,
        requires_env=None,
        is_async=False,
        description="",
        emoji="",
    ):
        tools_registry.registry.register(
            name=name,
            toolset=toolset,
            schema=schema,
            handler=handler,
            check_fn=check_fn,
            requires_env=requires_env,
            is_async=is_async,
            description=description,
            emoji=emoji,
        )
        self.registered.append(name)

    def register_hook(self, hook_name, fn):
        """Double mirroring ``PluginContext.register_hook`` (S3 guard
        integration point, verified against ``hermes/plugins/path_guard``'s
        ``register_hook('pre_tool_call', fn)`` usage)."""
        self.hooks.setdefault(hook_name, []).append(fn)


# ---------------------------------------------------------------------------
# 1. register(ctx) -> tools.registry
# ---------------------------------------------------------------------------


def test_register_adds_dispatch_job_to_registry():
    ctx = _FakePluginContext("claude_runner")
    try:
        claude_runner.register(ctx)

        assert "dispatch_job" in ctx.registered
        entry = tools_registry.registry.get_entry("dispatch_job")
        assert entry is not None
        assert entry.toolset == "claude_runner"
        assert (
            tools_registry.registry.get_schema("dispatch_job")
            == claude_runner.DISPATCH_SCHEMA
        )
        assert tools_registry.registry.get_emoji("dispatch_job") == "🚀"
    finally:
        tools_registry.registry.deregister("dispatch_job")


def test_dispatch_job_stub_returns_error_json():
    result = json.loads(claude_runner._dispatch_job_stub({}))
    assert "error" in result


# ---------------------------------------------------------------------------
# 2. manifest round trip: host/container paths stay separate
# ---------------------------------------------------------------------------


def test_manifest_round_trip_keeps_host_and_container_paths_separate(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(manifest_mod, "JOBS_DIR", tmp_path / "jobs")
    monkeypatch.setattr(manifest_mod, "WORKSPACES_DIR", tmp_path / "workspaces")
    monkeypatch.setattr(manifest_mod, "CLAUDE_STATE_DIR", tmp_path / "claude-state")

    built = manifest_mod.build_manifest(
        job_id="job-abc123",
        platform="slack",
        channel="C0123456789",
        repo="it-all-playpark/dotfiles",
        origin_url="git@github.com:it-all-playpark/dotfiles.git",
    )
    manifest_mod.write_manifest(built)

    on_disk = json.loads((tmp_path / "jobs" / "job-abc123.json").read_text())
    read_back = manifest_mod.read_manifest("job-abc123")

    for manifest in (on_disk, read_back):
        assert manifest["workspace_host_dir"] == str(
            tmp_path / "workspaces" / "job-abc123"
        )
        assert manifest["workspace_container_dir"] == "/workspace/jobs/job-abc123"
        assert manifest["claude_config_host_dir"] == str(
            tmp_path / "claude-state" / "job-abc123"
        )
        assert (
            manifest["claude_config_container_dir"]
            == "/root/.claude-hermes/job-abc123"
        )
        # host and container paths must never collide (edge_cases: mixup)
        assert manifest["workspace_host_dir"] != manifest["workspace_container_dir"]
        assert (
            manifest["claude_config_host_dir"]
            != manifest["claude_config_container_dir"]
        )

    assert read_back["status"] == "pending"
    assert read_back["notified"] is False


def test_manifest_rejects_invalid_status():
    with pytest.raises(manifest_mod.ManifestError):
        manifest_mod.build_manifest(
            job_id="job-bad",
            platform="slack",
            channel="C1",
            repo="owner/name",
            origin_url="git@github.com:owner/name.git",
            status="not-a-real-status",
        )


def test_manifest_rejects_missing_field():
    with pytest.raises(manifest_mod.ManifestError):
        manifest_mod.validate_manifest({"job_id": "job-x"})


# ---------------------------------------------------------------------------
# 3. bindings: valid loads, invalid raises (fail-closed)
# ---------------------------------------------------------------------------


def test_bindings_valid_file_loads(tmp_path):
    valid = tmp_path / "repo_bindings.yaml"
    valid.write_text(
        "platforms:\n"
        "  slack:\n"
        "    channels:\n"
        "      C0123456789:\n"
        "        repos:\n"
        "          - it-all-playpark/dotfiles\n"
    )
    loaded = bindings_mod.load_bindings(valid)
    assert bindings_mod.resolve_repos(loaded, "slack", "C0123456789") == [
        "it-all-playpark/dotfiles"
    ]
    assert bindings_mod.resolve_repos(loaded, "slack", "C_UNBOUND") == []
    assert bindings_mod.resolve_repos(loaded, "discord", "C0123456789") == []


@pytest.mark.parametrize(
    "content",
    [
        "not_platforms: {}\n",
        "platforms:\n  slack: not-a-mapping\n",
        "platforms:\n  slack:\n    channels: {}\n",
        "platforms:\n  slack:\n    channels:\n      C1: {}\n",
        "platforms:\n  slack:\n    channels:\n      C1:\n        repos: []\n",
        "platforms:\n  slack:\n    channels:\n      C1:\n        repos:\n          - not-a-slug\n",
    ],
)
def test_bindings_invalid_schema_raises(tmp_path, content):
    invalid = tmp_path / "repo_bindings.yaml"
    invalid.write_text(content)
    with pytest.raises(bindings_mod.BindingsError):
        bindings_mod.load_bindings(invalid)


def test_repo_bindings_sample_file_is_valid():
    sample = REPO_ROOT / "hermes" / "repo_bindings.yaml"
    loaded = bindings_mod.load_bindings(sample)
    assert isinstance(loaded["platforms"], dict)
