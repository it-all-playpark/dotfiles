"""Tests for ``hermes/watchdog.sh``'s notify-dedup + cleanup reconcile logic
(S5, AC-4/AC-5).

``watchdog.sh`` splits a completed job's lifecycle into two distinct passes
(see the module docstring in the script itself):

1. First pass a job is observed terminal (``status`` done/failed) with
   ``manifest.notified == false`` -> Slack notify fires *once*, then
   ``notified`` is flipped ``true`` atomically. No cleanup happens yet.
2. A later pass observes ``notified == true`` already on disk -> no notify
   (dedup), and *this* pass removes ``workspace_host_dir`` + the manifest
   file.

This split means a cleanup failure between passes can never cause a
duplicate Slack send on retry (edge_cases: 同一完了ジョブへの watchdog による
二重通知).

``watchdog.sh`` is exercised as a real subprocess with real ``jq`` — only
the network-facing ``curl`` (Slack) and ``claude`` (bg session polling) are
stubbed via a PATH-prepended fake-bin dir, so this test exercises the
script's actual bash logic rather than a reimplementation of it in Python.

The real ``flock`` mutual-exclusion gate (AC-5) is *not* exercised here —
``HERMES_WATCHDOG_SKIP_LOCK=1`` is set so these single-invocation tests don't
depend on a real ``flock`` binary being on PATH. AC-5 itself is verified by
launching two real concurrent ``watchdog.sh`` invocations from a shell (see
hermes/README.md watchdog section) — a process-level race that doesn't fit a
single-process pytest run anyway.
"""

from __future__ import annotations

import json
import os
import subprocess
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


def _write_job(*, status, notified, bg_job_id="bg-job-1", job_id="job-watchdog-1"):
    """Build + write a manifest, then materialize its workspace/claude-state
    host dirs on disk (cleanup removes real directories, so they must
    exist for the cleanup assertions to be meaningful)."""
    manifest = manifest_mod.build_manifest(
        job_id=job_id,
        platform="slack",
        channel="C0123456789",
        repo="it-all-playpark/dotfiles",
        origin_url="git@github.com:it-all-playpark/dotfiles.git",
        bg_job_id=bg_job_id,
        status=status,
        notified=notified,
    )
    manifest_mod.write_manifest(manifest)
    Path(manifest["workspace_host_dir"]).mkdir(parents=True, exist_ok=True)
    (Path(manifest["workspace_host_dir"]) / "marker.txt").write_text("clone\n")
    Path(manifest["claude_config_host_dir"]).mkdir(parents=True, exist_ok=True)
    return manifest


def _fake_bin_dir(tmp_path, *, curl_log, claude_agents_json=None):
    """Build a PATH-prependable dir with fake curl (Slack) + claude (bg
    session polling) so watchdog.sh never touches the real network/CLI."""
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()

    curl_script = bin_dir / "curl"
    curl_script.write_text(
        "#!/usr/bin/env bash\n"
        f'echo "===CALL===" >> "{curl_log}"\n'
        'echo \'{"ok":true}\'\n'
        "exit 0\n"
    )
    curl_script.chmod(0o755)

    claude_script = bin_dir / "claude"
    payload = claude_agents_json if claude_agents_json is not None else "[]"
    claude_script.write_text(
        "#!/usr/bin/env bash\n" f"cat <<'CLAUDE_JSON'\n{payload}\nCLAUDE_JSON\n"
    )
    claude_script.chmod(0o755)

    return bin_dir


def _run_watchdog(tmp_path, *, bin_dir, slack_bot_token="xoxb-fake-token"):
    env = dict(os.environ)
    env["HERMES_HOME"] = str(tmp_path / "hermes")
    env["HERMES_WATCHDOG_SKIP_LOCK"] = "1"
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    if slack_bot_token is not None:
        env["SLACK_BOT_TOKEN"] = slack_bot_token
    else:
        env.pop("SLACK_BOT_TOKEN", None)
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


# ---------------------------------------------------------------------------
# 1. notified=false, status=done -> notify exactly once, notified flips true,
#    no cleanup yet (edge_cases: 同一完了ジョブへの watchdog による二重通知)
# ---------------------------------------------------------------------------


def test_notified_false_triggers_single_notify_and_flips_true(tmp_path):
    manifest = _write_job(status="done", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(tmp_path, curl_log=curl_log)

    _run_watchdog(tmp_path, bin_dir=bin_dir)

    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert len(calls) == 1

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["notified"] is True
    assert updated["status"] == "done"
    # cleanup deferred to a later pass -- workspace/manifest still present
    assert Path(manifest["workspace_host_dir"]).is_dir()


# ---------------------------------------------------------------------------
# 2. notified=true already -> no re-notify (dedup) AND this pass cleans up
#    the workspace clone + manifest (edge_cases: 完了確定後 cleanup)
# ---------------------------------------------------------------------------


def test_notified_true_skips_notify_and_triggers_cleanup(tmp_path):
    manifest = _write_job(status="done", notified=True)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(tmp_path, curl_log=curl_log)

    _run_watchdog(tmp_path, bin_dir=bin_dir)

    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert calls == []  # no re-notify

    assert not Path(manifest["workspace_host_dir"]).exists()
    assert not manifest_mod.manifest_path(manifest["job_id"]).exists()


# ---------------------------------------------------------------------------
# 3. A failed job is notified/cleaned up the same way as a done job.
# ---------------------------------------------------------------------------


def test_failed_status_notified_once_like_done(tmp_path):
    manifest = _write_job(status="failed", notified=False)
    curl_log = tmp_path / "curl.log"
    bin_dir = _fake_bin_dir(tmp_path, curl_log=curl_log)

    _run_watchdog(tmp_path, bin_dir=bin_dir)

    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert len(calls) == 1

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["notified"] is True


# ---------------------------------------------------------------------------
# 4. A still-running job is left completely untouched: no notify, no
#    cleanup, manifest status unchanged.
# ---------------------------------------------------------------------------


def test_running_job_with_still_running_bg_session_is_untouched(tmp_path):
    manifest = _write_job(status="running", notified=False, bg_job_id="bg-job-1")
    curl_log = tmp_path / "curl.log"
    still_running_json = json.dumps([{"id": "bg-job-1", "status": "running"}])
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=still_running_json
    )

    _run_watchdog(tmp_path, bin_dir=bin_dir)

    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert calls == []

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "running"
    assert updated["notified"] is False
    assert Path(manifest["workspace_host_dir"]).is_dir()


# ---------------------------------------------------------------------------
# 5. A running job whose bg session has completed gets reconciled to `done`
#    on this pass, then notified on the *next* pass (two-phase, as above).
# ---------------------------------------------------------------------------


def test_running_job_with_completed_bg_session_reconciles_then_notifies(tmp_path):
    manifest = _write_job(status="running", notified=False, bg_job_id="bg-job-1")
    curl_log = tmp_path / "curl.log"
    completed_json = json.dumps([{"id": "bg-job-1", "status": "completed"}])
    bin_dir = _fake_bin_dir(
        tmp_path, curl_log=curl_log, claude_agents_json=completed_json
    )

    _run_watchdog(tmp_path, bin_dir=bin_dir)

    updated = manifest_mod.read_manifest(manifest["job_id"])
    assert updated["status"] == "done"
    assert updated["notified"] is True

    calls = curl_log.read_text().splitlines() if curl_log.exists() else []
    assert len(calls) == 1
