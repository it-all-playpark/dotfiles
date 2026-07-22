"""Tests for ``hermes/watchdog.sh``'s per-job container死活検知 (issue #122).

``watchdog.sh``'s ``reconcile_job`` previously judged a job's liveness purely
from ``poll_bg_status`` (a ``claude agents --json`` listing). If the bg
session's own manifest still said ``running`` but its per-job Docker
container had actually been killed/OOM-killed/removed by a daemon restart,
the job would be polled forever with no path to ``failed`` (issue #122 /
AC-2 NO-GO).

This adds a second, independent signal: ``poll_container_state`` runs
``docker inspect -f '{{.State.Running}}' <container_id>`` and classifies the
result as ``alive`` / ``dead`` / ``unknown``. Only ``dead`` observed for
``HERMES_WATCHDOG_CONTAINER_DEAD_CONFIRM_COUNT`` (default 2) *consecutive*
reconcile passes forces the job to ``failed`` (falling through into the
existing notify/cleanup pipeline, same as the reaper paths already covered
by ``test_watchdog_notify.py``). ``alive`` resets the streak; ``unknown``
(docker unreachable) leaves the streak untouched so a daemon restart never
manufactures a false failure nor silently drops already-observed dead
passes.

Like ``test_watchdog_notify.py``, ``watchdog.sh`` is exercised as a real
subprocess with real ``jq`` -- only ``curl`` (Slack), ``claude`` (bg session
polling) and now ``docker`` (container liveness) are stubbed via a
PATH-prepended fake-bin dir.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
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

from claude_runner import manifest as manifest_mod  # noqa: E402

WATCHDOG_SH = REPO_ROOT / "hermes" / "watchdog.sh"


@pytest.fixture(autouse=True)
def _isolated_manifest_dirs(tmp_path, monkeypatch):
    monkeypatch.setattr(manifest_mod, "JOBS_DIR", tmp_path / "hermes" / "jobs")
    monkeypatch.setattr(
        manifest_mod, "WORKSPACES_DIR", tmp_path / "hermes" / "workspaces"
    )
    monkeypatch.setattr(
        manifest_mod, "CLAUDE_STATE_DIR", tmp_path / "hermes" / "claude-state"
    )
    yield


def _write_job(
    *,
    status,
    notified,
    bg_job_id="bg-job-1",
    job_id="job-watchdog-container-1",
    platform="slack",
    channel="C0123456789",
    created_at=None,
    container_id="container-abc-1",
    container_dead_streak=None,
):
    """Build + write a manifest (optionally with ``container_id``), then
    materialize its workspace/claude-state host dirs on disk. ``created_at``
    defaults to 10 minutes ago so the REAP_TIMEOUT_SECONDS (default 5400s)
    reaper never fires and the ABSENT_GRACE window is trivially satisfied
    for the still-listed-running bg session assertions below."""
    manifest = manifest_mod.build_manifest(
        job_id=job_id,
        platform=platform,
        channel=channel,
        repo="it-all-playpark/dotfiles",
        origin_url="git@github.com:it-all-playpark/dotfiles.git",
        container_id=container_id,
        bg_job_id=bg_job_id,
        status=status,
        notified=notified,
        created_at=created_at if created_at is not None else time.time() - 600,
    )
    if container_dead_streak is not None:
        manifest["container_dead_streak"] = container_dead_streak
    manifest_mod.write_manifest(manifest)
    Path(manifest["workspace_host_dir"]).mkdir(parents=True, exist_ok=True)
    (Path(manifest["workspace_host_dir"]) / "marker.txt").write_text("clone\n")
    Path(manifest["claude_config_host_dir"]).mkdir(parents=True, exist_ok=True)
    return manifest


def _fake_bin_dir(
    tmp_path,
    *,
    curl_log,
    claude_agents_json=None,
    curl_response='{"ok":true}',
    curl_http_status="200",
    curl_exit_code=0,
):
    """Build a PATH-prependable dir with fake curl (Slack), claude (bg
    session polling) and docker (container liveness). The fake docker's
    behavior is selected at *runtime* via the ``FAKE_DOCKER_MODE`` env var
    (alive/exited/no_such/daemon_down) so a single script serves every test
    case below."""
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()

    curl_script = bin_dir / "curl"
    curl_script.write_text(
        "#!/usr/bin/env bash\n"
        f'printf \'%s\\n\' "$*" | tr \'\\n\' \' \' >> "{curl_log}"\n'
        f'printf \'\\n\' >> "{curl_log}"\n'
        "has_w=0\n"
        'for a in "$@"; do\n'
        '  if [ "$a" = "-w" ]; then has_w=1; fi\n'
        "done\n"
        f"printf '%s' {shlex.quote(curl_response)}\n"
        'if [ "$has_w" = "1" ]; then\n'
        f"  printf '\\n%s' {shlex.quote(curl_http_status)}\n"
        "fi\n"
        f"exit {curl_exit_code}\n"
    )
    curl_script.chmod(0o755)

    claude_script = bin_dir / "claude"
    payload = claude_agents_json if claude_agents_json is not None else "[]"
    claude_script.write_text(
        "#!/usr/bin/env bash\n" f"cat <<'CLAUDE_JSON'\n{payload}\nCLAUDE_JSON\n"
    )
    claude_script.chmod(0o755)

    docker_script = bin_dir / "docker"
    docker_script.write_text(
        "#!/usr/bin/env bash\n"
        'mode="${FAKE_DOCKER_MODE:-alive}"\n'
        'case "$mode" in\n'
        "  alive)\n"
        '    echo "true"\n'
        "    exit 0\n"
        "    ;;\n"
        "  exited)\n"
        '    echo "false"\n'
        "    exit 0\n"
        "    ;;\n"
        "  no_such)\n"
        '    echo "Error: No such object: xxx" >&2\n'
        "    exit 1\n"
        "    ;;\n"
        "  daemon_down)\n"
        '    echo "Cannot connect to the Docker daemon" >&2\n'
        "    exit 1\n"
        "    ;;\n"
        "  *)\n"
        '    echo "true"\n'
        "    exit 0\n"
        "    ;;\n"
        "esac\n"
    )
    docker_script.chmod(0o755)

    return bin_dir


def _run_watchdog(
    tmp_path, *, bin_dir, slack_bot_token="xoxb-fake-token", extra_env=None
):
    env = dict(os.environ)
    env["HERMES_HOME"] = str(tmp_path / "hermes")
    env["HERMES_WATCHDOG_SKIP_LOCK"] = "1"
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    if slack_bot_token is not None:
        env["SLACK_BOT_TOKEN"] = slack_bot_token
    else:
        env.pop("SLACK_BOT_TOKEN", None)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", str(WATCHDOG_SH)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"watchdog.sh exited {result.returncode}\nstdout={result.stdout}\n"
        f"stderr={result.stderr}"
    )
    return result


_STILL_RUNNING_JSON = json.dumps([{"id": "bg-job-1", "status": "running"}])
_COMPLETED_JSON = json.dumps([{"id": "bg-job-1", "status": "completed"}])


# ---------------------------------------------------------------------------
# 1. bg session still listed running + container alive -> stays running,
#    container_dead_streak 0.
# ---------------------------------------------------------------------------


def test_container_alive_keeps_running_with_zero_streak(tmp_path):
    manifest = _write_job(status="running", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "alive"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert updated.get("container_dead_streak", 0) == 0


# ---------------------------------------------------------------------------
# 2. bg session still listed running + container gone (--rm'd, "no such
#    object") -> first pass increments the streak but stays running; the
#    *second* consecutive pass reconciles to failed and notifies exactly
#    once (issue #122).
# ---------------------------------------------------------------------------


def test_container_no_such_object_confirms_dead_after_two_passes_then_failed(
    tmp_path,
):
    manifest = _write_job(status="running", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )
    env = {"FAKE_DOCKER_MODE": "no_such"}

    _run_watchdog(tmp_path, bin_dir=bin_dir, extra_env=env)
    after_pass1 = manifest_mod.read_manifest(manifest["job_id"])
    assert after_pass1["status"] == "running"
    assert after_pass1["container_dead_streak"] == 1
    calls_after_pass1 = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert calls_after_pass1 == []

    _run_watchdog(tmp_path, bin_dir=bin_dir, extra_env=env)
    after_pass2 = manifest_mod.read_manifest(manifest["job_id"])
    assert after_pass2["status"] == "failed"
    assert after_pass2["notified"] is True
    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# 3. `docker inspect` succeeds (exit 0) but reports Running=false (container
#    exited, not yet removed) -> counts as a dead observation too.
# ---------------------------------------------------------------------------


def test_container_exited_running_false_counts_as_dead_observation(tmp_path):
    manifest = _write_job(status="running", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "exited"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert updated["container_dead_streak"] == 1


# ---------------------------------------------------------------------------
# 4. docker daemon unreachable ("Cannot connect to the Docker daemon") with
#    a pre-existing dead streak of 1 -> streak must NOT change (unknown is
#    not a reset, and it is not an increment either) and status stays
#    running.
# ---------------------------------------------------------------------------


def test_docker_daemon_unreachable_leaves_existing_streak_unchanged(tmp_path):
    manifest = _write_job(
        status="running", notified=False, container_dead_streak=1
    )
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "daemon_down"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert updated["container_dead_streak"] == 1
    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert calls == []


# ---------------------------------------------------------------------------
# 5. A pre-existing dead streak of 1 is reset to 0 once the container is
#    observed alive again.
# ---------------------------------------------------------------------------


def test_container_alive_resets_existing_streak_to_zero(tmp_path):
    manifest = _write_job(
        status="running", notified=False, container_dead_streak=1
    )
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "alive"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert updated["container_dead_streak"] == 0


# ---------------------------------------------------------------------------
# 6. Backward compatibility: a manifest with no container_id (pre-#122
#    dispatch) must skip container liveness checking entirely, even when the
#    fake docker would report the container gone -- no container_dead_streak
#    field should ever be created for it.
# ---------------------------------------------------------------------------


def test_manifest_without_container_id_skips_container_check(tmp_path):
    manifest = _write_job(status="running", notified=False, container_id=None)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_STILL_RUNNING_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "no_such"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert "container_dead_streak" not in updated


# ---------------------------------------------------------------------------
# 7. The bg session listing itself reports completion (poll_bg_status ->
#    done) even though the container is gone -- the normal completion path
#    takes priority and the job is reconciled to `done`, never `failed`.
# ---------------------------------------------------------------------------


def test_bg_session_completed_takes_priority_over_dead_container(tmp_path):
    manifest = _write_job(status="running", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=_COMPLETED_JSON
    )

    _run_watchdog(
        tmp_path, bin_dir=bin_dir, extra_env={"FAKE_DOCKER_MODE": "no_such"}
    )

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "done"
    assert updated["notified"] is True
