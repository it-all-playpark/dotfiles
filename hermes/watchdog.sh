#!/usr/bin/env bash
# hermes/watchdog.sh — host-side reconcile loop for claude_runner jobs (S5, AC-4/AC-5).
#
# Runs periodically (launchd `com.playpark.hermes-watchdog`, StartInterval) and:
#
#   1. Acquires an exclusive lock on ~/.hermes/watchdog.lock via `flock -xn`.
#      A concurrent run that fails to acquire the lock exits immediately
#      (AC-5: multi-run exclusion) instead of racing the same manifests.
#   2. Scans ~/.hermes/jobs/*.json and, for any manifest still `pending`/
#      `running`, reconciles its `bg_job_id` against `claude agents --json`
#      (per-job `CLAUDE_CONFIG_DIR`/`--cwd`, matching the AC-3 go/no-go
#      verification in claudedocs/hermes-phaseB-execution-model-decision.md)
#      to detect completion.
#   3. Once a manifest reaches a terminal status (`done`/`failed`) it is
#      notified over Slack *exactly once* — `manifest.notified` is flipped
#      to `true` atomically right after a successful notify so a later run
#      never re-sends (edge_cases: 同一完了ジョブへの watchdog による二重通知).
#   4. Only on a **later** pass, once `notified=true` is already on disk, is
#      the job's `workspace_host_dir` clone removed and its manifest deleted.
#      Splitting notify and cleanup into separate passes means a cleanup
#      failure (partial `rm`, killed mid-run) can never cause a duplicate
#      Slack notification on retry — the manifest survives with
#      `notified=true` until cleanup actually succeeds.
#
# Env overrides (test/alt-deployment hooks, mirrors manifest.py conventions):
#   HERMES_HOME              default ~/.hermes ; jobs/workspaces/claude-state
#                             all derive from this, same as manifest.py.
#   HERMES_WATCHDOG_LOCK      default $HERMES_HOME/watchdog.lock
#   HERMES_WATCHDOG_SKIP_LOCK if set to a non-empty value, skips flock
#                             acquisition entirely. **Test-only** escape
#                             hatch so unit tests can exercise the
#                             notify/cleanup reconcile logic without
#                             depending on a real flock binary or racing
#                             concurrent invocations; AC-5 (flock mutual
#                             exclusion) is verified separately by running
#                             two real concurrent `watchdog.sh` invocations
#                             from a shell (see hermes/README.md). Must
#                             never be set in the launchd agent.
#   SLACK_BOT_TOKEN           Slack bot token for chat.postMessage. If a
#                             manifest's platform is `slack` and this is
#                             unset, notify is skipped (logged) and the
#                             manifest is retried on the next pass rather
#                             than silently dropped.
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
JOBS_DIR="${HERMES_JOBS_DIR:-$HERMES_HOME/jobs}"
LOCK_FILE="${HERMES_WATCHDOG_LOCK:-$HERMES_HOME/watchdog.lock}"
ENV_FILE="$HERMES_HOME/.env"

# Load ~/.hermes/.env (SLACK_BOT_TOKEN etc.) the same way hermes-wrapper.sh
# does, when present. Tests run against an isolated HERMES_HOME with no
# .env file, so this is a no-op there and injected env vars pass through.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

log() {
  echo "watchdog: $*" >&2
}

acquire_lock_or_exit() {
  if [ -n "${HERMES_WATCHDOG_SKIP_LOCK:-}" ]; then
    log "HERMES_WATCHDOG_SKIP_LOCK set — skipping flock (test-only path)"
    return 0
  fi
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 200>"$LOCK_FILE"
  if ! flock -xn 200; then
    log "another watchdog run holds $LOCK_FILE — exiting immediately (AC-5)"
    exit 0
  fi
}

# Reconcile a still-pending/running job's bg_job_id against `claude agents`.
# Echoes one of: running | done | failed
# `claude agents --json --all --cwd <workspace_host_dir>` is invoked with the
# job's own CLAUDE_CONFIG_DIR (host path), exactly the pattern verified GO in
# claudedocs/hermes-phaseB-execution-model-decision.md (AC-3).
poll_bg_status() {
  local claude_config_host_dir="$1" workspace_host_dir="$2" bg_job_id="$3"
  local json
  if ! json=$(CLAUDE_CONFIG_DIR="$claude_config_host_dir" claude agents --json --all --cwd "$workspace_host_dir" 2>/dev/null); then
    log "claude agents --json failed for bg_job_id=$bg_job_id — treating as still running"
    echo "running"
    return
  fi
  local entry_status
  entry_status=$(printf '%s' "$json" | jq -r --arg id "$bg_job_id" '
    [.[] | select((.id // .sessionId // .taskId // .job_id) == $id)] | .[0].status // empty
  ' 2>/dev/null || true)

  if [ -z "$entry_status" ]; then
    # Session no longer listed at all (even with --all) -> it has exited.
    echo "done"
    return
  fi
  case "$entry_status" in
    running | in_progress | pending)
      echo "running"
      ;;
    error | failed)
      echo "failed"
      ;;
    *)
      echo "done"
      ;;
  esac
}

notify_slack() {
  local channel="$1" text="$2"
  if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    log "SLACK_BOT_TOKEN not set — skipping notify for channel $channel (will retry next pass)"
    return 1
  fi
  local payload
  payload=$(jq -n --arg channel "$channel" --arg text "$text" '{channel: $channel, text: $text}')
  if ! curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" >/dev/null; then
    log "Slack notify failed for channel $channel (will retry next pass)"
    return 1
  fi
  return 0
}

# Atomically flip manifest.<field> = <value> (same tmp-file + os.replace
# pattern as manifest.write_manifest, expressed in jq/mv for bash callers).
set_manifest_field() {
  local manifest_path="$1" field="$2" json_value="$3"
  local tmp
  tmp=$(mktemp "${manifest_path}.XXXXXX.tmp")
  jq --argjson v "$json_value" ". + {\"$field\": \$v}" "$manifest_path" >"$tmp"
  mv "$tmp" "$manifest_path"
}

cleanup_job() {
  local manifest_path="$1" workspace_host_dir="$2" job_id="$3"
  if [ -n "$workspace_host_dir" ] && [ "$workspace_host_dir" != "/" ]; then
    rm -rf -- "$workspace_host_dir"
  fi
  rm -f -- "$manifest_path"
  log "job $job_id cleaned up (workspace + manifest removed)"
}

reconcile_job() {
  local manifest_path="$1"
  local job_id platform channel repo bg_job_id status notified workspace_host_dir claude_config_host_dir

  job_id=$(jq -r '.job_id' "$manifest_path")
  platform=$(jq -r '.platform' "$manifest_path")
  channel=$(jq -r '.channel' "$manifest_path")
  repo=$(jq -r '.repo' "$manifest_path")
  bg_job_id=$(jq -r '.bg_job_id // empty' "$manifest_path")
  status=$(jq -r '.status' "$manifest_path")
  notified=$(jq -r '.notified' "$manifest_path")
  workspace_host_dir=$(jq -r '.workspace_host_dir' "$manifest_path")
  claude_config_host_dir=$(jq -r '.claude_config_host_dir' "$manifest_path")

  if [ "$status" = "pending" ] || [ "$status" = "running" ]; then
    if [ -z "$bg_job_id" ]; then
      log "job $job_id ($status) has no bg_job_id yet — skipping"
      return
    fi
    local polled
    polled=$(poll_bg_status "$claude_config_host_dir" "$workspace_host_dir" "$bg_job_id")
    if [ "$polled" = "running" ]; then
      log "job $job_id still running — skipping"
      return
    fi
    status="$polled"
    set_manifest_field "$manifest_path" "status" "\"$status\""
  fi

  # status is now terminal (done/failed).
  if [ "$notified" = "false" ]; then
    if notify_slack "$channel" "hermes job $job_id ($repo) finished: $status"; then
      set_manifest_field "$manifest_path" "notified" "true"
      log "job $job_id notified (status=$status)"
    fi
    # Cleanup is deliberately deferred to the pass *after* notified=true is
    # durably on disk (see module docstring) — do not fall through here.
    return
  fi

  cleanup_job "$manifest_path" "$workspace_host_dir" "$job_id"
}

main() {
  acquire_lock_or_exit
  mkdir -p "$JOBS_DIR"
  shopt -s nullglob
  local manifest_path
  for manifest_path in "$JOBS_DIR"/*.json; do
    reconcile_job "$manifest_path"
  done
}

main "$@"
