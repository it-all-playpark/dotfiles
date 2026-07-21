"""Smoke test for ``_docker_run_claude_bg`` (PR #117 review).

``docker run -d``'s own stdout is the Docker **container id**, never the
``claude --bg`` job id the S5 watchdog (``hermes/watchdog.sh``'s
``poll_bg_status``) needs to reconcile against ``claude agents --json``.
The real job id only ever appears in the containerized process's own
stdout, read back via ``docker logs <container_id>``.

Unlike ``test_dispatch.py``/``test_fanout_limit.py`` (which monkeypatch
``_docker_run_claude_bg`` itself and never exercise its body), this test
drives ``_docker_run_claude_bg`` for real with ``subprocess.run`` mocked at
the process boundary, so the container-id/bg-job-id split inside the
function is actually asserted rather than assumed.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

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

CONTAINER_ID = "a1b2c3d4e5f6" * 5  # docker's full 64-hex-char container id shape
BG_JOB_ID = "bg-job-real-42"  # what `claude --bg` itself prints, and what
# `claude agents --json`'s `.id`/`.sessionId` would report for this session.


def _fake_subprocess_run(cmd, **kwargs):
    """Route by argv[0:2]: `docker run ...` -> container id on stdout;
    `docker logs <id>` -> the claude --bg job id on stdout (mirrors what the
    containerized process actually printed, per docker's log capture)."""
    result = MagicMock()
    result.returncode = 0
    if cmd[:2] == ["docker", "run"]:
        result.stdout = f"{CONTAINER_ID}\n"
        result.stderr = ""
    elif cmd[:2] == ["docker", "logs"]:
        assert cmd[2] == CONTAINER_ID, "docker logs must target the container id, not bg_job_id"
        result.stdout = f"{BG_JOB_ID}\n"
        result.stderr = ""
    else:
        raise AssertionError(f"unexpected subprocess.run call: {cmd!r}")
    return result


def test_bg_job_id_is_read_from_container_logs_not_run_stdout(monkeypatch):
    monkeypatch.setattr(dispatch.subprocess, "run", _fake_subprocess_run)

    launch_result = dispatch._docker_run_claude_bg(
        job_id="job-smoke-1",
        workspace_host_dir="/host/workspaces/job-smoke-1",
        workspace_container_dir="/workspace/jobs/job-smoke-1",
        claude_config_host_dir="/host/claude-state/job-smoke-1",
        claude_config_container_dir="/root/.claude-hermes/job-smoke-1",
        prompt="do the thing",
        docker_image="hermes-claude:latest",
        forward_env=(),
    )

    assert launch_result == {"container_id": CONTAINER_ID, "bg_job_id": BG_JOB_ID}
    # The critical invariant this review comment exists for: bg_job_id must
    # never be the container id `docker run -d` printed.
    assert launch_result["bg_job_id"] != launch_result["container_id"]


def test_bg_job_id_matches_claude_agents_listing_container_id_does_not():
    """Simulate the S5 watchdog's reconcile match (poll_bg_status compares
    manifest.bg_job_id against `claude agents --json`'s `.id`) and assert
    only bg_job_id — never container_id — is a hit."""
    fake_claude_agents_listing = [
        {"id": BG_JOB_ID, "status": "running"},
        {"id": "some-other-session", "status": "done"},
    ]
    listed_ids = {entry["id"] for entry in fake_claude_agents_listing}

    assert BG_JOB_ID in listed_ids
    assert CONTAINER_ID not in listed_ids


def test_docker_run_stdout_empty_raises_dispatch_error(monkeypatch):
    def _empty_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        return result

    monkeypatch.setattr(dispatch.subprocess, "run", _empty_run)

    with pytest.raises(dispatch.DispatchError, match="no container id"):
        dispatch._docker_run_claude_bg(
            job_id="job-smoke-2",
            workspace_host_dir="/host/workspaces/job-smoke-2",
            workspace_container_dir="/workspace/jobs/job-smoke-2",
            claude_config_host_dir="/host/claude-state/job-smoke-2",
            claude_config_container_dir="/root/.claude-hermes/job-smoke-2",
            prompt="do the thing",
            docker_image="hermes-claude:latest",
            forward_env=(),
        )


def test_missing_bg_job_id_in_logs_raises_after_poll_timeout(monkeypatch):
    def _empty_logs_run(cmd, **kwargs):
        assert cmd[:2] == ["docker", "logs"]
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        return result

    monkeypatch.setattr(dispatch.subprocess, "run", _empty_logs_run)

    # Explicit short timeout/interval (rather than monkeypatching the
    # module-level defaults, which are bound into the function signature at
    # def-time and would not be picked up dynamically).
    with pytest.raises(dispatch.DispatchError, match="no bg job id"):
        dispatch._read_bg_job_id_from_container_logs(
            CONTAINER_ID, timeout=0.05, interval=0.01
        )
