"""``dispatch_job`` real implementation (S2, AC-1).

Replaces the S1 ``_dispatch_job_stub`` registered in ``__init__.py``. The
public contract (tool name / schema / argument names) is frozen by S1 and
is **not** changed here — this module only supplies the handler body.

Processing order, per plan S2:

1. Resolve ``(platform, channel)`` -> bound repo(s) via ``bindings.py``.
   An unbound channel, an invalid ``repo`` override, or a structurally
   invalid ``repo_bindings.yaml`` are all refused (fail-closed) — no clone,
   no container launch, no manifest is written for a refused request.
2. For each bound repo (fan-out when ``repo`` is omitted and multiple repos
   are bound, per ``DISPATCH_SCHEMA``'s documented contract): generate a
   ``job_id``, build + write a ``pending`` manifest deriving the four
   host/container path fields from ``job_id`` (see ``manifest.py``).
3. ``git clone <origin_url> <workspace_host_dir>`` — origin-based clone
   (worktree method intentionally not used, per architecture_decisions).
4. Launch ``claude --bg --cwd <workspace_container_dir>`` inside a per-job
   container with ``CLAUDE_CONFIG_DIR=<claude_config_container_dir>``.
   **Container-facing args always use the container paths** — passing a
   host path here breaks dispatch because the path doesn't exist inside the
   container (edge_cases: host-vs-container path mixup). ``_docker_run_
   claude_bg`` asserts this explicitly.
5. Reconcile the returned bg job id into ``manifest.bg_job_id`` and flip
   ``status`` to ``running`` (or ``failed`` if steps 3/4 raised).

``_git_clone`` and ``_docker_run_claude_bg`` are the two "real world" seams
— tests monkeypatch both instead of shelling out to real git/docker.

Fan-out (S6, AC-6) reuses step 2-5 unchanged: each bound repo gets its own
``job_id``/manifest/clone/container, so a per-repo failure never affects the
other repos' jobs and each is independently reconciled/notified/cleaned up
by the S5 watchdog.

Global concurrency cap (S6, AC-7): before a repo's job_id/manifest is
created, ``_reserve_job_slot`` takes an exclusive ``flock`` on
``~/.hermes/jobs/.dispatch_concurrency.lock`` and, while holding it, counts
the ``pending``/``running`` manifests already in ``~/.hermes/jobs/``. If
that count has reached ``claude_runner.max_concurrent_jobs`` (config.yaml),
no manifest is written and no clone/container is launched for that repo —
it is reported back as "congested" instead. Counting and manifest creation
happen inside the same locked critical section specifically so two
concurrent ``dispatch_job`` calls can never both observe a free slot and
both proceed past the cap (edge_cases: 同時実行上限到達時の race).
"""

from __future__ import annotations

import json
import os
import subprocess
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

from tools.registry import tool_error, tool_result

from . import bindings as bindings_mod
from . import manifest as manifest_mod

try:
    import fcntl
except ImportError:  # pragma: no cover - posix-only (darwin/linux) in practice
    fcntl = None  # type: ignore[assignment]

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config.yaml"

DEFAULT_DOCKER_IMAGE = "hermes-tools:latest"
DEFAULT_FORWARD_ENV = (
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
)

# claude_runner.max_concurrent_jobs fallback when config.yaml doesn't set it
# (or sets it to something non-positive) — see _load_claude_runner_config.
DEFAULT_MAX_CONCURRENT_JOBS = 3

# Manifest statuses that occupy a concurrency slot.
ACTIVE_JOB_STATUSES = ("pending", "running")

CONGESTED_MESSAGE = (
    "hermes is busy (max_concurrent_jobs reached); dispatch refused, "
    "please retry later (混雑中)"
)


class DispatchError(RuntimeError):
    """Raised when clone/container-launch fails for a single job."""


def _new_job_id() -> str:
    return f"job-{uuid.uuid4().hex[:12]}"


def _origin_url(repo: str) -> str:
    """``owner/name`` -> ``git@github.com:owner/name.git``."""
    return f"git@github.com:{repo}.git"


def _load_terminal_config() -> Dict[str, Any]:
    """Read ``docker_image`` / ``docker_forward_env`` from hermes/config.yaml.

    Falls back to the documented defaults if config.yaml is missing/invalid
    rather than failing dispatch outright — the docker image name is not a
    security-sensitive fail-closed concern the way repo_bindings is.
    """
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}
    except OSError:
        return {"docker_image": DEFAULT_DOCKER_IMAGE, "forward_env": DEFAULT_FORWARD_ENV}

    terminal_cfg = raw.get("terminal") or {}
    return {
        "docker_image": terminal_cfg.get("docker_image") or DEFAULT_DOCKER_IMAGE,
        "forward_env": tuple(terminal_cfg.get("docker_forward_env") or DEFAULT_FORWARD_ENV),
    }


def _load_claude_runner_config() -> Dict[str, Any]:
    """Read ``claude_runner.max_concurrent_jobs`` from hermes/config.yaml.

    Falls back to ``DEFAULT_MAX_CONCURRENT_JOBS`` if config.yaml is missing,
    invalid, or the value isn't a positive int — a misconfigured cap should
    degrade to *some* sane limit rather than disabling the cap outright
    (fail-closed in spirit, matching ``_load_terminal_config``'s fallback
    style for non-security config)."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}
    except OSError:
        return {"max_concurrent_jobs": DEFAULT_MAX_CONCURRENT_JOBS}

    runner_cfg = raw.get("claude_runner") or {}
    max_jobs = runner_cfg.get("max_concurrent_jobs")
    if not isinstance(max_jobs, int) or isinstance(max_jobs, bool) or max_jobs < 1:
        max_jobs = DEFAULT_MAX_CONCURRENT_JOBS
    return {"max_concurrent_jobs": max_jobs}


def _concurrency_lock_path() -> Path:
    return manifest_mod.jobs_dir() / ".dispatch_concurrency.lock"


def _count_active_jobs() -> int:
    """Count manifests under ``~/.hermes/jobs/`` whose status is
    pending/running (i.e. currently occupying a concurrency slot).

    Must only be called while holding the concurrency flock — see
    ``_reserve_job_slot`` — otherwise this is a check-then-act race."""
    jobs_dir = manifest_mod.jobs_dir()
    if not jobs_dir.exists():
        return 0
    count = 0
    for path in jobs_dir.glob("*.json"):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        if data.get("status") in ACTIVE_JOB_STATUSES:
            count += 1
    return count


def _reserve_job_slot(
    *, platform: str, channel: str, repo: str, max_concurrent_jobs: int
) -> Optional[Dict[str, Any]]:
    """Atomically (under an exclusive ``flock``) check the active job count
    against ``max_concurrent_jobs`` and, if a slot is free, build + write a
    ``pending`` manifest that reserves it.

    Returns the reserved manifest, or ``None`` if the cap is already
    reached ("congested" — the caller must not clone/launch a container for
    that repo, AC-7). Holding the lock across "count" *and* "write
    manifest" is what prevents two concurrent ``dispatch_job`` calls from
    both observing a free slot and both proceeding past the cap."""
    lock_path = _concurrency_lock_path()
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+") as lock_fh:
        if fcntl is not None:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        try:
            if _count_active_jobs() >= max_concurrent_jobs:
                return None
            job_id = _new_job_id()
            manifest = manifest_mod.build_manifest(
                job_id=job_id,
                platform=platform,
                channel=channel,
                repo=repo,
                origin_url=_origin_url(repo),
                status="pending",
            )
            manifest_mod.write_manifest(manifest)
            return manifest
        finally:
            if fcntl is not None:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)


def _git_clone(origin_url: str, host_dir: Path) -> None:
    """Clone ``origin_url`` into ``host_dir`` (origin-based clone, not a
    worktree — see architecture_decisions). Split out so tests can
    monkeypatch this instead of shelling out to a real git remote."""
    host_dir.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", origin_url, str(host_dir)],
        check=True,
        capture_output=True,
        text=True,
    )


def _docker_run_claude_bg(
    *,
    job_id: str,
    workspace_host_dir: str,
    workspace_container_dir: str,
    claude_config_host_dir: str,
    claude_config_container_dir: str,
    prompt: str,
    docker_image: str,
    forward_env: tuple,
) -> str:
    """Launch ``claude --bg`` inside a per-job container and return the bg
    job id printed on stdout.

    ``--cwd`` and ``CLAUDE_CONFIG_DIR`` MUST be container paths — the
    asserts below make a host/container mixup (edge_cases) loud instead of
    a silent "cwd does not exist" failure inside the container.
    """
    assert workspace_container_dir.startswith(
        f"{manifest_mod.WORKSPACE_CONTAINER_ROOT}/"
    ), f"refusing container launch: not a container workspace path: {workspace_container_dir!r}"
    assert claude_config_container_dir.startswith(
        f"{manifest_mod.CLAUDE_CONFIG_CONTAINER_ROOT}/"
    ), f"refusing container launch: not a container CLAUDE_CONFIG_DIR: {claude_config_container_dir!r}"
    assert workspace_container_dir != workspace_host_dir
    assert claude_config_container_dir != claude_config_host_dir

    cmd: List[str] = [
        "docker",
        "run",
        "-d",
        "--rm",
        "--name",
        f"hermes-claude-{job_id}",
        "-v",
        f"{workspace_host_dir}:{workspace_container_dir}",
        "-v",
        f"{claude_config_host_dir}:{claude_config_container_dir}",
        "-e",
        f"CLAUDE_CONFIG_DIR={claude_config_container_dir}",
    ]
    for key in forward_env:
        value = os.environ.get(key)
        if value:
            cmd += ["-e", f"{key}={value}"]
    cmd += [
        docker_image,
        "claude",
        "--bg",
        "--cwd",
        workspace_container_dir,
        prompt,
    ]

    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    bg_job_id = result.stdout.strip()
    if not bg_job_id:
        raise DispatchError("claude --bg produced no bg job id on stdout")
    return bg_job_id


def _dispatch_one(
    *, manifest: Dict[str, Any], prompt: str, terminal_cfg: Dict[str, Any]
) -> Dict[str, Any]:
    """Clone + launch the container for an already-reserved ``manifest``
    (see ``_reserve_job_slot`` — job_id/manifest creation happens there,
    under the concurrency lock, before this function is called)."""
    job_id = manifest["job_id"]
    repo = manifest["repo"]

    try:
        _git_clone(manifest["origin_url"], Path(manifest["workspace_host_dir"]))
        bg_job_id = _docker_run_claude_bg(
            job_id=job_id,
            workspace_host_dir=manifest["workspace_host_dir"],
            workspace_container_dir=manifest["workspace_container_dir"],
            claude_config_host_dir=manifest["claude_config_host_dir"],
            claude_config_container_dir=manifest["claude_config_container_dir"],
            prompt=prompt,
            docker_image=terminal_cfg["docker_image"],
            forward_env=terminal_cfg["forward_env"],
        )
    except Exception as exc:  # noqa: BLE001 — reconcile failure into manifest, then re-raise-as-DispatchError
        manifest["status"] = "failed"
        manifest_mod.write_manifest(manifest)
        raise DispatchError(f"dispatch failed for {repo} (job {job_id}): {exc}") from exc

    manifest["bg_job_id"] = bg_job_id
    manifest["status"] = "running"
    manifest_mod.write_manifest(manifest)

    return {
        "job_id": job_id,
        "repo": repo,
        "bg_job_id": bg_job_id,
        "status": "running",
    }


def dispatch_job(args: dict, **kwargs) -> str:
    """``dispatch_job`` tool handler — see module docstring for the flow.

    Fail-closed at every gate: missing args, unbound channel, an invalid
    ``repo`` override, or a malformed ``repo_bindings.yaml`` all return a
    ``tool_error`` with zero side effects (no clone, no container launch,
    no manifest written).
    """
    args = args or {}
    platform: Optional[str] = args.get("platform")
    channel: Optional[str] = args.get("channel")
    prompt: Optional[str] = args.get("prompt")
    repo_override: Optional[str] = args.get("repo")

    if not platform or not channel or not prompt:
        return tool_error("dispatch_job requires platform, channel, and prompt")

    try:
        bindings = bindings_mod.load_bindings()
    except bindings_mod.BindingsError as exc:
        return tool_error(bindings_mod.fail_closed_message(exc))

    bound_repos = bindings_mod.resolve_repos(bindings, platform, channel)
    if not bound_repos:
        return tool_error(
            f"channel {channel!r} on platform {platform!r} is not bound to any "
            "repo; dispatch refused (fail-closed)"
        )

    if repo_override is not None:
        if repo_override not in bound_repos:
            return tool_error(
                f"repo {repo_override!r} is not bound to channel {channel!r}; "
                "dispatch refused (fail-closed)"
            )
        target_repos = [repo_override]
    else:
        target_repos = bound_repos

    terminal_cfg = _load_terminal_config()
    max_concurrent_jobs = _load_claude_runner_config()["max_concurrent_jobs"]

    dispatched: List[Dict[str, Any]] = []
    errors: List[Dict[str, str]] = []
    congested: List[Dict[str, str]] = []
    for repo in target_repos:
        # Fan-out (AC-6): each bound repo gets its own reserved job_id /
        # manifest here, independent of the others, so one repo's cap-hit
        # or clone/launch failure never blocks or corrupts another repo's
        # job (each is later reconciled/notified/cleaned up independently
        # by the S5 watchdog).
        manifest = _reserve_job_slot(
            platform=platform,
            channel=channel,
            repo=repo,
            max_concurrent_jobs=max_concurrent_jobs,
        )
        if manifest is None:
            congested.append({"repo": repo})
            continue
        try:
            dispatched.append(
                _dispatch_one(manifest=manifest, prompt=prompt, terminal_cfg=terminal_cfg)
            )
        except DispatchError as exc:
            errors.append({"repo": repo, "error": str(exc)})

    if not dispatched and not errors and congested:
        return tool_error(CONGESTED_MESSAGE, jobs=[], congested=congested)

    if not dispatched and errors:
        return tool_error(
            "dispatch_job failed for all bound repos",
            jobs=[],
            errors=errors,
            congested=congested,
        )

    return tool_result(jobs=dispatched, errors=errors, congested=congested)
