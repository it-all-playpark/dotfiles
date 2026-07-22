"""claude_runner job manifest schema and atomic persistence.

Manifest files live at ``~/.hermes/jobs/<job_id>.json`` and track the
lifecycle + host<->container path pairs of a single dispatched ChatOps job,
so dispatch (S2), the executor (S4), and the watchdog (S5) can coordinate
without re-deriving paths independently.

Host paths (``*_host_dir``) are real filesystem locations under
``~/.hermes/`` that the *host* watchdog/CLI operate on. Container paths
(``*_container_dir``) are what must be passed as ``--cwd`` /
``CLAUDE_CONFIG_DIR`` *inside* the dispatch container (bind-mounted from the
matching host path). The two must never be swapped — passing a host path as
a container ``--cwd`` breaks dispatch because the path doesn't exist inside
the container (see plan edge_cases: host-vs-container path mixup).
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

VALID_STATUSES = ("pending", "running", "done", "failed")

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
JOBS_DIR = HERMES_HOME / "jobs"
WORKSPACES_DIR = HERMES_HOME / "workspaces"
CLAUDE_STATE_DIR = HERMES_HOME / "claude-state"

WORKSPACE_CONTAINER_ROOT = "/workspace/jobs"
CLAUDE_CONFIG_CONTAINER_ROOT = "/root/.claude-hermes"

REQUIRED_FIELDS = (
    "job_id",
    "platform",
    "channel",
    "repo",
    "origin_url",
    "workspace_host_dir",
    "workspace_container_dir",
    "claude_config_host_dir",
    "claude_config_container_dir",
    "container_id",
    "bg_job_id",
    "status",
    "notified",
    "created_at",
)


class ManifestError(ValueError):
    """Raised when a manifest dict fails schema validation."""


def jobs_dir() -> Path:
    """Return the directory manifests are stored in (module-level, patchable
    in tests via ``monkeypatch.setattr(manifest, "JOBS_DIR", ...)``)."""
    return JOBS_DIR


def manifest_path(job_id: str) -> Path:
    return JOBS_DIR / f"{job_id}.json"


def build_manifest(
    *,
    job_id: str,
    platform: str,
    channel: str,
    repo: str,
    origin_url: str,
    container_id: Optional[str] = None,
    bg_job_id: Optional[str] = None,
    status: str = "pending",
    notified: bool = False,
    created_at: Optional[float] = None,
) -> Dict[str, Any]:
    """Build a manifest dict, deriving all four host/container paths from
    ``job_id`` per the fixed layout documented on this module.

    ``container_id`` (the Docker container id from ``docker run -d``'s own
    stdout) and ``bg_job_id`` (the claude agent job id printed by the
    containerized ``claude --bg`` process, read from ``docker logs``) are
    two distinct identifiers — the S5 watchdog reconciles ``bg_job_id``
    against ``claude agents --json``, never ``container_id`` (PR #117
    review: conflating the two made ``poll_bg_status`` never find a match).
    """
    manifest = {
        "job_id": job_id,
        "platform": platform,
        "channel": channel,
        "repo": repo,
        "origin_url": origin_url,
        "workspace_host_dir": str(WORKSPACES_DIR / job_id),
        "workspace_container_dir": f"{WORKSPACE_CONTAINER_ROOT}/{job_id}",
        "claude_config_host_dir": str(CLAUDE_STATE_DIR / job_id),
        "claude_config_container_dir": f"{CLAUDE_CONFIG_CONTAINER_ROOT}/{job_id}",
        "container_id": container_id,
        "bg_job_id": bg_job_id,
        "status": status,
        "notified": notified,
        "created_at": created_at if created_at is not None else time.time(),
    }
    validate_manifest(manifest)
    return manifest


def validate_manifest(manifest: Dict[str, Any]) -> None:
    """Raise ManifestError if ``manifest`` doesn't satisfy the schema."""
    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        raise ManifestError(f"manifest missing required fields: {missing}")
    if manifest["status"] not in VALID_STATUSES:
        raise ManifestError(
            f"manifest status {manifest['status']!r} not in {VALID_STATUSES}"
        )
    if not isinstance(manifest["notified"], bool):
        raise ManifestError("manifest.notified must be a bool")


def write_manifest(manifest: Dict[str, Any]) -> Path:
    """Atomically write ``manifest`` to ``~/.hermes/jobs/<job_id>.json``.

    Writes to a tmp file in the same directory then ``os.replace``s it into
    place so a concurrent reader (watchdog) never observes a partial file.
    """
    validate_manifest(manifest)
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    target = manifest_path(manifest["job_id"])
    fd, tmp_name = tempfile.mkstemp(
        dir=str(JOBS_DIR), prefix=f".{manifest['job_id']}.", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_name, target)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    return target


def read_manifest(job_id: str) -> Dict[str, Any]:
    """Read + validate the manifest for ``job_id``."""
    path = manifest_path(job_id)
    with open(path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    validate_manifest(manifest)
    return manifest
