"""Tests for claude_runner フェーズD: 多repoファンアウト・同時実行上限・
schema fail-closed (S6, AC-6/AC-7/AC-8).

1. A channel bound to multiple repos fans out to one independent
   job_id/manifest/clone per repo (AC-6) — each job is fully independent so
   the S5 watchdog can later notify/cleanup each one on its own.
2. Once ``~/.hermes/jobs/`` already holds
   ``claude_runner.max_concurrent_jobs`` pending/running manifests, a new
   dispatch_job call is refused with a "congested" ``tool_error`` and
   performs *zero* side effects for the capped repo: no new manifest is
   written, no clone, no container launch (AC-7). The count itself is taken
   under an exclusive ``flock`` (see ``dispatch._reserve_job_slot``) so two
   concurrent dispatch_job calls can never both slip past the cap — that
   process-level race is not exercised by a single-process pytest run here,
   the same way AC-5's watchdog flock race is verified manually rather than
   in-process (see ``test_watchdog_notify.py`` module docstring / README).
3. A structurally invalid ``repo_bindings.yaml`` is fail-closed: the bind is
   refused (no clone, no container, no manifest) and the refusal is
   returned as a ``tool_error`` the caller relays back to the requesting
   channel as the "notification" (AC-8).

``dispatch._git_clone`` / ``dispatch._docker_run_claude_bg`` are
monkeypatched so no real git/docker call happens.
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

pytest.importorskip("tools.registry", reason="hermes-agent venv not available")

from claude_runner import dispatch  # noqa: E402
from claude_runner import manifest as manifest_mod  # noqa: E402

BOUND_BINDINGS_YAML = """\
platforms:
  slack:
    channels:
      C0123456789:
        repos:
          - it-all-playpark/dotfiles
"""

MULTI_REPO_BINDINGS_YAML = """\
platforms:
  slack:
    channels:
      C_MULTI:
        repos:
          - it-all-playpark/dotfiles
          - it-all-playpark/skills
"""


@pytest.fixture(autouse=True)
def _isolated_manifest_dirs(tmp_path, monkeypatch):
    monkeypatch.setattr(manifest_mod, "JOBS_DIR", tmp_path / "jobs")
    monkeypatch.setattr(manifest_mod, "WORKSPACES_DIR", tmp_path / "workspaces")
    monkeypatch.setattr(manifest_mod, "CLAUDE_STATE_DIR", tmp_path / "claude-state")
    yield


def _write_bindings(tmp_path, content):
    path = tmp_path / "repo_bindings.yaml"
    path.write_text(content)
    return path


def _write_config(tmp_path, *, max_concurrent_jobs):
    path = tmp_path / "config.yaml"
    path.write_text(f"claude_runner:\n  max_concurrent_jobs: {max_concurrent_jobs}\n")
    return path


def _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-job-42"):
    def _fake_clone(origin_url, host_dir):
        calls.setdefault("clone", []).append(
            {"origin_url": origin_url, "host_dir": str(host_dir)}
        )

    def _fake_bg(**kwargs):
        calls.setdefault("bg", []).append(kwargs)
        return {"container_id": f"container-{bg_job_id}", "bg_job_id": bg_job_id}

    monkeypatch.setattr(dispatch, "_git_clone", _fake_clone)
    monkeypatch.setattr(dispatch, "_docker_run_claude_bg", _fake_bg)


def _seed_active_job(*, status="running", job_id="job-preexisting"):
    """Write a manifest directly (bypassing dispatch_job) so it occupies a
    concurrency slot before the test's dispatch_job call runs."""
    manifest = manifest_mod.build_manifest(
        job_id=job_id,
        platform="slack",
        channel="C0123456789",
        repo="it-all-playpark/dotfiles",
        origin_url="git@github.com:it-all-playpark/dotfiles.git",
        bg_job_id="bg-preexisting",
        status=status,
    )
    manifest_mod.write_manifest(manifest)
    return manifest


# ---------------------------------------------------------------------------
# 1. Multi-repo bind fans out to one independent job per repo (AC-6)
# ---------------------------------------------------------------------------


def test_multi_repo_bind_fans_out_to_independent_jobs(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, MULTI_REPO_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=5))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-fanout")

    result = json.loads(
        dispatch.dispatch_job(
            {"platform": "slack", "channel": "C_MULTI", "prompt": "fan out please"}
        )
    )

    assert result["errors"] == []
    assert result["congested"] == []
    assert len(result["jobs"]) == 2

    job_ids = {job["job_id"] for job in result["jobs"]}
    assert len(job_ids) == 2  # independent job_id per repo

    assert len(calls["clone"]) == 2  # independent clone per repo
    assert len(calls["bg"]) == 2  # independent container launch per repo

    manifests = [manifest_mod.read_manifest(job_id) for job_id in job_ids]
    repos = {m["repo"] for m in manifests}
    assert repos == {"it-all-playpark/dotfiles", "it-all-playpark/skills"}
    for m in manifests:
        assert m["status"] == "running"
        # independent host/container paths, keyed off each job's own job_id
        assert m["workspace_host_dir"].endswith(m["job_id"])
        assert m["workspace_container_dir"].endswith(m["job_id"])


# ---------------------------------------------------------------------------
# 2. max_concurrent_jobs reached -> congested, zero side effects (AC-7)
# ---------------------------------------------------------------------------


def test_running_at_cap_returns_congested_with_no_new_dispatch(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=1))

    # One job already occupies the (cap=1) slot.
    _seed_active_job(status="running")

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "should be congested",
            }
        )
    )

    assert "error" in result
    assert "混雑中" in result["error"]
    assert result["jobs"] == []
    assert result["congested"] == [{"repo": "it-all-playpark/dotfiles"}]

    # zero side effects for the capped repo
    assert "clone" not in calls
    assert "bg" not in calls
    manifests_on_disk = list(manifest_mod.jobs_dir().glob("*.json"))
    assert len(manifests_on_disk) == 1  # only the pre-seeded job, no new one


def test_pending_job_also_counts_toward_the_cap(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=1))

    _seed_active_job(status="pending")

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "should also be congested",
            }
        )
    )

    assert "error" in result
    assert result["congested"] == [{"repo": "it-all-playpark/dotfiles"}]
    assert "clone" not in calls


def test_below_cap_dispatches_normally(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=2))

    # One pre-existing job, but cap is 2 -> one slot still free.
    _seed_active_job(status="running")

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-under-cap")

    result = json.loads(
        dispatch.dispatch_job(
            {"platform": "slack", "channel": "C0123456789", "prompt": "still room"}
        )
    )

    assert result["congested"] == []
    assert len(result["jobs"]) == 1
    assert len(calls["clone"]) == 1
    assert len(calls["bg"]) == 1


def test_done_job_does_not_count_toward_the_cap(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=1))

    # A terminal job frees up the slot even though its manifest is still on
    # disk (watchdog cleanup hasn't run yet).
    _seed_active_job(status="done")

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-after-done")

    result = json.loads(
        dispatch.dispatch_job(
            {"platform": "slack", "channel": "C0123456789", "prompt": "slot is free"}
        )
    )

    assert result["congested"] == []
    assert len(result["jobs"]) == 1
    assert len(calls["clone"]) == 1


# ---------------------------------------------------------------------------
# 3. Malformed repo_bindings.yaml -> fail-closed refusal + notification (AC-8)
# ---------------------------------------------------------------------------


def test_malformed_bindings_file_rejects_the_bind_with_no_side_effects(
    tmp_path, monkeypatch
):
    bad_bindings = tmp_path / "repo_bindings.yaml"
    bad_bindings.write_text("not_platforms: {}\n")
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bad_bindings))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=5))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "should be refused",
            }
        )
    )

    assert "error" in result
    assert "fail-closed" in result["error"]
    assert "clone" not in calls
    assert "bg" not in calls
    assert not manifest_mod.jobs_dir().exists() or not any(
        manifest_mod.jobs_dir().iterdir()
    )


def test_invalid_repo_slug_in_bindings_rejects_the_bind(tmp_path, monkeypatch):
    bad_bindings = tmp_path / "repo_bindings.yaml"
    bad_bindings.write_text(
        "platforms:\n"
        "  slack:\n"
        "    channels:\n"
        "      C0123456789:\n"
        "        repos:\n"
        "          - not-a-valid-slug\n"
    )
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bad_bindings))
    monkeypatch.setattr(dispatch, "CONFIG_PATH", _write_config(tmp_path, max_concurrent_jobs=5))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "should be refused too",
            }
        )
    )

    assert "error" in result
    assert "fail-closed" in result["error"]
    assert "clone" not in calls
    assert "bg" not in calls
