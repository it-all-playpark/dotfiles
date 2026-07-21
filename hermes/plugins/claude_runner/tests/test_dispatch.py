"""Tests for the claude_runner dispatch_job real implementation (S2, AC-1).

Covers the handler's processing order without touching real git/docker:

1. Unbound (platform, channel) -> fail-closed ``tool_error`` (no clone, no
   docker call, no manifest written).
2. Bound (platform, channel) -> manifest built with the four host/container
   path fields correctly split, ``git clone`` invoked with the *host*
   workspace dir, and the ``claude --bg`` container launch invoked with the
   *container* paths (never the host paths) — edge_cases: host-vs-container
   path mixup.
3. ``repo_bindings.yaml`` schema violations are fail-closed too (dispatch
   refused, not silently permitted).

``dispatch._git_clone`` and ``dispatch._docker_run_claude_bg`` are
monkeypatched so no real subprocess/git/docker call happens.
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

from claude_runner import bindings as bindings_mod  # noqa: E402
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


# ---------------------------------------------------------------------------
# 1. Unbound channel -> fail-closed
# ---------------------------------------------------------------------------


def test_unbound_channel_is_refused_without_side_effects(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C_NOT_BOUND",
                "prompt": "do the thing",
            }
        )
    )

    assert "error" in result
    assert "clone" not in calls
    assert "bg" not in calls
    assert not manifest_mod.jobs_dir().exists() or not any(
        manifest_mod.jobs_dir().iterdir()
    )


def test_repo_override_not_bound_to_channel_is_refused(tmp_path, monkeypatch):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "do the thing",
                "repo": "some-other/repo",
            }
        )
    )

    assert "error" in result
    assert "clone" not in calls
    assert "bg" not in calls


# ---------------------------------------------------------------------------
# 2. Bound channel -> manifest + clone(host) + claude --bg(container)
# ---------------------------------------------------------------------------


def test_bound_channel_dispatches_with_correct_host_and_container_paths(
    tmp_path, monkeypatch
):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-job-42")

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "ship the fix",
            }
        )
    )

    assert result.get("errors") == []
    assert len(result["jobs"]) == 1
    job = result["jobs"][0]
    assert job["repo"] == "it-all-playpark/dotfiles"
    assert job["bg_job_id"] == "bg-job-42"
    assert job["status"] == "running"

    job_id = job["job_id"]
    manifest = manifest_mod.read_manifest(job_id)
    assert manifest["status"] == "running"
    assert manifest["bg_job_id"] == "bg-job-42"
    # container_id (docker run -d's own stdout) and bg_job_id (the claude
    # agent job id read from docker logs) are distinct fields — the S5
    # watchdog reconciles bg_job_id only (PR #117 review).
    assert manifest["container_id"] == "container-bg-job-42"
    assert manifest["container_id"] != manifest["bg_job_id"]
    assert manifest["notified"] is False

    # host/container paths are correctly derived and never collide
    assert manifest["workspace_host_dir"] == str(
        manifest_mod.WORKSPACES_DIR / job_id
    )
    assert manifest["workspace_container_dir"] == f"/workspace/jobs/{job_id}"
    assert manifest["claude_config_host_dir"] == str(
        manifest_mod.CLAUDE_STATE_DIR / job_id
    )
    assert manifest["claude_config_container_dir"] == f"/root/.claude-hermes/{job_id}"

    # clone was invoked with the HOST workspace dir, not the container path
    assert len(calls["clone"]) == 1
    clone_call = calls["clone"][0]
    assert clone_call["host_dir"] == manifest["workspace_host_dir"]
    assert clone_call["origin_url"] == "git@github.com:it-all-playpark/dotfiles.git"

    # claude --bg was launched with CONTAINER paths, never host paths
    assert len(calls["bg"]) == 1
    bg_call = calls["bg"][0]
    assert bg_call["workspace_container_dir"] == manifest["workspace_container_dir"]
    assert (
        bg_call["claude_config_container_dir"]
        == manifest["claude_config_container_dir"]
    )
    assert bg_call["workspace_host_dir"] == manifest["workspace_host_dir"]
    assert bg_call["claude_config_host_dir"] == manifest["claude_config_host_dir"]
    assert bg_call["prompt"] == "ship the fix"
    assert bg_call["job_id"] == job_id
    # never the host dirs mistakenly used as container args
    assert bg_call["workspace_container_dir"] != bg_call["workspace_host_dir"]
    assert (
        bg_call["claude_config_container_dir"] != bg_call["claude_config_host_dir"]
    )


def test_bound_channel_with_multiple_repos_fans_out_one_job_per_repo(
    tmp_path, monkeypatch
):
    bindings_path = _write_bindings(tmp_path, MULTI_REPO_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls, bg_job_id="bg-job-multi")

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C_MULTI",
                "prompt": "fan out please",
            }
        )
    )

    assert len(result["jobs"]) == 2
    dispatched_repos = {job["repo"] for job in result["jobs"]}
    assert dispatched_repos == {
        "it-all-playpark/dotfiles",
        "it-all-playpark/skills",
    }
    assert len(calls["clone"]) == 2
    assert len(calls["bg"]) == 2
    job_ids = {job["job_id"] for job in result["jobs"]}
    assert len(job_ids) == 2  # each repo gets its own job_id


def test_docker_launch_failure_marks_manifest_failed_and_reports_error(
    tmp_path, monkeypatch
):
    bindings_path = _write_bindings(tmp_path, BOUND_BINDINGS_YAML)
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bindings_path))

    def _fake_clone(origin_url, host_dir):
        pass

    def _fake_bg_raises(**kwargs):
        raise RuntimeError("docker run failed")

    monkeypatch.setattr(dispatch, "_git_clone", _fake_clone)
    monkeypatch.setattr(dispatch, "_docker_run_claude_bg", _fake_bg_raises)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "this will fail",
            }
        )
    )

    assert result["jobs"] == []
    assert len(result["errors"]) == 1
    job_id = None
    for path in manifest_mod.jobs_dir().glob("*.json"):
        job_id = path.stem
    assert job_id is not None
    manifest = manifest_mod.read_manifest(job_id)
    assert manifest["status"] == "failed"


# ---------------------------------------------------------------------------
# 3. Malformed repo_bindings.yaml -> fail-closed
# ---------------------------------------------------------------------------


def test_malformed_bindings_file_is_fail_closed(tmp_path, monkeypatch):
    bad_bindings = tmp_path / "repo_bindings.yaml"
    bad_bindings.write_text("not_platforms: {}\n")
    monkeypatch.setenv("HERMES_REPO_BINDINGS_PATH", str(bad_bindings))

    calls: dict = {}
    _fake_clone_and_bg(monkeypatch, calls)

    result = json.loads(
        dispatch.dispatch_job(
            {
                "platform": "slack",
                "channel": "C0123456789",
                "prompt": "should not run",
            }
        )
    )

    assert "error" in result
    assert "clone" not in calls
    assert "bg" not in calls


def test_missing_required_args_returns_tool_error():
    result = json.loads(dispatch.dispatch_job({"platform": "slack"}))
    assert "error" in result
