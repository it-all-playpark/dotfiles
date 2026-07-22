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
#      notified over its own `manifest.platform` (Slack/Discord — see
#      `notify_dispatch` below) *exactly once* — `manifest.notified` is
#      flipped to `true` atomically right after a successful notify so a
#      later run never re-sends (edge_cases: 同一完了ジョブへの watchdog に
#      よる二重通知).
#   4. Only on a **later** pass, once `notified=true` is already on disk, is
#      the job's `workspace_host_dir` clone removed and its manifest deleted.
#      Splitting notify and cleanup into separate passes means a cleanup
#      failure (partial `rm`, killed mid-run) can never cause a duplicate
#      notification on retry — the manifest survives with `notified=true`
#      until cleanup actually succeeds.
#   5. Reaper: a `pending`/`running` manifest older than
#      `HERMES_WATCHDOG_REAP_TIMEOUT_SECONDS` (default 90 minutes) is
#      reclaimed instead of being skipped/leaked forever — see that env var
#      below for the two distinct stuck-forever cases it closes.
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
#                             than silently dropped. A Slack API-level
#                             failure (HTTP 200 + body `.ok == false`, e.g.
#                             channel_not_found) is treated the same way —
#                             `notify_slack` inspects the response body, not
#                             just the curl exit code.
#   DISCORD_BOT_TOKEN         Discord bot token used to notify manifests
#                             whose platform is `discord`, via the Discord
#                             REST API (`POST /channels/<id>/messages`,
#                             `Authorization: Bot <token>`) — the same
#                             credential the native gateway adapter
#                             (`gateway/platforms/discord.py`) authenticates
#                             with. If unset, notify is skipped (logged) and
#                             retried next pass.
#   HERMES_WATCHDOG_ABSENT_GRACE_SECONDS
#                             Minimum age (manifest.created_at) a
#                             pending/running job must reach before an empty
#                             `claude agents --json --all` listing is even
#                             considered as a signal of completion — guards
#                             against the registration lag right after
#                             dispatch. Default 60.
#   HERMES_WATCHDOG_ABSENT_CONFIRM_COUNT
#                             Number of *consecutive* reconcile passes a
#                             job's bg_job_id must be missing from the
#                             listing (after the grace period) before it is
#                             declared `done`. A single transient empty
#                             listing is not enough — guards a still-running
#                             job (and its bind-mounted workspace_host_dir,
#                             which cleanup_job later `rm -rf`s) against a
#                             false-positive done verdict. Default 3.
#   HERMES_WATCHDOG_REAP_TIMEOUT_SECONDS
#                             Age (manifest.created_at) after which a stuck
#                             job is reaped rather than skipped/leaked
#                             forever (PR #117 review: a `pending` job whose
#                             dispatch never got as far as writing
#                             `bg_job_id` was skipped by reconcile_job on
#                             every single pass with no way out, silently
#                             occupying a concurrency slot forever; a
#                             terminal job on a platform with no outbound
#                             notify adapter — e.g. `google_chat`, see
#                             notify dispatch below — stayed
#                             `notified=false` forever and so never reached
#                             `cleanup_job`, leaking its `workspace_host_dir`
#                             clone permanently). Once a `pending`/`running`
#                             job's age passes this threshold:
#                               - no `bg_job_id` yet → reaped: `status` is
#                                 forced to `failed` (dispatch never
#                                 registered) so it flows into the normal
#                                 notify+cleanup path instead of skipping
#                                 forever.
#                               - `bg_job_id` set (still actively polled via
#                                 `poll_bg_status`) → NOT force-terminated
#                                 (an actually-running job is left running);
#                                 a timeout warning is logged each pass
#                                 instead so a stuck-for-hours job is visible
#                                 in `watchdog.{out,err}.log`.
#                             Separately, a terminal job whose platform has
#                             no outbound notify adapter (`has_notify_adapter`
#                             false) that has stayed `notified=false` past
#                             this same threshold is reaped straight to
#                             `cleanup_job` *without* ever having notified —
#                             the only way to reclaim its slot/workspace,
#                             since notify for that platform can never
#                             succeed. Default 5400 (90 minutes).
#   HERMES_WATCHDOG_CONTAINER_DEAD_CONFIRM_COUNT
#                             Per-job container 死活検知 (issue #122 / AC-2):
#                             `poll_bg_status` alone only reflects what the
#                             bg session's own listing reports — if the
#                             per-job Docker container is killed/OOM-killed
#                             or vanishes on a daemon restart while that
#                             listing still says `running`, reconcile_job
#                             would otherwise poll the job forever with no
#                             path to `failed`. When a manifest's
#                             `container_id` is non-empty and `poll_bg_status`
#                             returns `running`, `poll_container_state` runs
#                             `docker inspect -f '{{.State.Running}}'` against
#                             it and classifies the result:
#                               - alive   -> `container_dead_streak` is reset
#                                 to 0 (guards against a transient dead
#                                 observation right before a legitimate
#                                 `--rm` completion race).
#                               - unknown (docker missing from PATH, or a
#                                 daemon-connect error not matching "no such
#                                 object") -> `container_dead_streak` is left
#                                 completely unchanged — a daemon restart
#                                 must never manufacture a false failure NOR
#                                 silently erase dead passes already observed.
#                               - dead (inspect reports Running=false, or
#                                 fails with a "no such object" error, i.e.
#                                 the container was --rm'd) -> increments
#                                 `container_dead_streak`; once it reaches
#                                 this threshold for CONSECUTIVE passes,
#                                 `status` is forced to `failed` and falls
#                                 through into the normal notify/cleanup
#                                 pipeline below (same shape as the existing
#                                 reap paths). This script never restarts the
#                                 container nor re-dispatches the job on its
#                                 own — that is a deliberate operational
#                                 constraint (see
#                                 claudedocs/hermes-phaseB-execution-model-decision.md),
#                                 an operator must re-run the ChatOps command
#                                 manually after being notified. A manifest
#                                 with no `container_id` (pre-#122 dispatch)
#                                 skips this check entirely for backward
#                                 compatibility. Default 2.
#
# notify dispatch (manifest.platform):
#   `notify_slack` and `notify_discord` are the only real network sends;
#   any other/unknown platform has no outbound adapter wired into this
#   script (e.g. Google Chat currently only has an *inbound* webhook route
#   — see hermes/README.md フェーズE — no send credential exists here) and
#   is logged + left `notified=false` for retry rather than being routed
#   through notify_slack, which would silently "succeed" against the wrong
#   channel namespace.
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

ABSENT_GRACE_SECONDS="${HERMES_WATCHDOG_ABSENT_GRACE_SECONDS:-60}"
ABSENT_CONFIRM_COUNT="${HERMES_WATCHDOG_ABSENT_CONFIRM_COUNT:-3}"
REAP_TIMEOUT_SECONDS="${HERMES_WATCHDOG_REAP_TIMEOUT_SECONDS:-5400}"
CONTAINER_DEAD_CONFIRM_COUNT="${HERMES_WATCHDOG_CONTAINER_DEAD_CONFIRM_COUNT:-2}"

# manifest.created_at is a float (Python time.time()); compute integer age
# with awk rather than bash arithmetic (no float support) or `awk systime()`
# (gawk-only, absent from macOS's default BSD awk). Echoes 0 on any failure
# so callers can safely compare it as an integer.
job_age_seconds() {
  local created_at="$1" now
  now=$(date +%s)
  awk -v now="$now" -v created="$created_at" 'BEGIN { printf "%d", now - created }' 2>/dev/null || echo 0
}

# Reconcile a still-pending/running job's bg_job_id against `claude agents`.
# Echoes one of: running | done | failed
# `claude agents --json --all --cwd <workspace_host_dir>` is invoked with the
# job's own CLAUDE_CONFIG_DIR (host path), exactly the pattern verified GO in
# claudedocs/hermes-phaseB-execution-model-decision.md (AC-3).
#
# When bg_job_id is missing from the listing entirely, that is NOT taken as
# an immediate `done` verdict: a job just dispatched can hit a registration
# lag before `claude agents` lists it, and a transient/empty listing can
# occur for other reasons too. A false-positive `done` here flows straight
# into notify + (next pass) `cleanup_job`'s `rm -rf` of a still-running job's
# bind-mounted workspace_host_dir, so we require both (a) the manifest is
# older than ABSENT_GRACE_SECONDS and (b) the absence has now been observed
# on ABSENT_CONFIRM_COUNT *consecutive* passes (persisted on the manifest as
# `bg_absent_streak`) before declaring `done`. Any pass where the job IS
# listed resets the streak to 0.
poll_bg_status() {
  local manifest_path="$1" claude_config_host_dir="$2" workspace_host_dir="$3" bg_job_id="$4" created_at="$5"
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
    # Session not (yet, or no longer) listed. Require grace + N consecutive
    # absences before treating it as exited — see function docstring.
    local age
    age=$(job_age_seconds "$created_at")
    if [ -z "$age" ] || [ "$age" -lt "$ABSENT_GRACE_SECONDS" ]; then
      log "bg_job_id=$bg_job_id not listed but manifest age (${age}s) < ${ABSENT_GRACE_SECONDS}s grace — treating as still running"
      echo "running"
      return
    fi
    local streak
    streak=$(jq -r '.bg_absent_streak // 0' "$manifest_path" 2>/dev/null || echo 0)
    streak=$((streak + 1))
    if [ "$streak" -lt "$ABSENT_CONFIRM_COUNT" ]; then
      set_manifest_field "$manifest_path" "bg_absent_streak" "$streak"
      log "bg_job_id=$bg_job_id not listed ($streak/$ABSENT_CONFIRM_COUNT consecutive absences) — treating as still running"
      echo "running"
      return
    fi
    log "bg_job_id=$bg_job_id not listed for $ABSENT_CONFIRM_COUNT consecutive passes past grace — treating as done"
    echo "done"
    return
  fi

  # Listed again -> reset any prior absence streak.
  if [ "$(jq -r '.bg_absent_streak // 0' "$manifest_path" 2>/dev/null || echo 0)" != "0" ]; then
    set_manifest_field "$manifest_path" "bg_absent_streak" "0"
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

# Per-job container liveness check (issue #122 / AC-2). Echoes one of:
# alive | dead | unknown
#
# `docker` missing from PATH -> unknown (can't tell either way, never
# manufacture a false failure just because this host has no docker CLI).
# `docker inspect -f '{{.State.Running}}' <container_id>` exit 0:
#   - stdout == "true"  -> alive
#   - stdout != "true"  -> dead (exited but not yet --rm'd)
# `docker inspect` non-zero exit:
#   - stderr matches "no such object" (case-insensitive) -> dead (the
#     container was --rm'd, the expected shape for a normal completion too,
#     which is why the CONTAINER_DEAD_CONFIRM_COUNT streak — not a single
#     observation — is what actually forces `failed`, see reconcile_job).
#   - anything else (daemon unreachable, permission error, etc.) -> unknown.
poll_container_state() {
  local container_id="$1"
  if ! command -v docker >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  local out
  if out=$(docker inspect -f '{{.State.Running}}' "$container_id" 2>&1); then
    if [ "$out" = "true" ]; then
      echo "alive"
    else
      echo "dead"
    fi
    return
  fi
  if printf '%s' "$out" | grep -qi 'no such object'; then
    echo "dead"
  else
    echo "unknown"
  fi
}

# Slack's chat.postMessage returns HTTP 200 + body `{"ok":false,"error":...}`
# for API-level failures (e.g. channel_not_found when a non-Slack channel id
# is handed to it) — `curl -fsS` only checks the HTTP status, so a body-only
# failure must be inspected explicitly or it is silently treated as success.
notify_slack() {
  local channel="$1" text="$2"
  if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    log "SLACK_BOT_TOKEN not set — skipping notify for channel $channel (will retry next pass)"
    return 1
  fi
  local payload response
  payload=$(jq -n --arg channel "$channel" --arg text "$text" '{channel: $channel, text: $text}')
  if ! response=$(curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload"); then
    log "Slack notify failed for channel $channel (request error, will retry next pass)"
    return 1
  fi
  if [ "$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
    local slack_error
    slack_error=$(printf '%s' "$response" | jq -r '.error // "unknown"' 2>/dev/null)
    log "Slack notify rejected for channel $channel (ok:false, error=$slack_error; will retry next pass)"
    return 1
  fi
  return 0
}

# Discord notify via the bot REST API, using the same DISCORD_BOT_TOKEN the
# native gateway adapter authenticates with (gateway/platforms/discord.py).
notify_discord() {
  local channel="$1" text="$2"
  if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    log "DISCORD_BOT_TOKEN not set — skipping notify for channel $channel (will retry next pass)"
    return 1
  fi
  local payload response http_status body
  payload=$(jq -n --arg content "$text" '{content: $content}')
  if ! response=$(curl -sS -w '\n%{http_code}' -X POST \
    "https://discord.com/api/v10/channels/${channel}/messages" \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload"); then
    log "Discord notify failed for channel $channel (request error, will retry next pass)"
    return 1
  fi
  http_status=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')
  case "$http_status" in
    2??) return 0 ;;
    *)
      log "Discord notify failed for channel $channel (HTTP $http_status: $body; will retry next pass)"
      return 1
      ;;
  esac
}

# Whether `notify_dispatch` has a real outbound send wired for this
# platform. Used both by `notify_dispatch` itself and by `reconcile_job`'s
# reap fallback: a platform with no adapter (e.g. `google_chat`) can never
# succeed a notify, so `notified` can never flip `true` on its own — without
# an explicit reap that stuck job would leak its workspace/manifest forever
# (PR #117 review, see HERMES_WATCHDOG_REAP_TIMEOUT_SECONDS in module
# docstring).
has_notify_adapter() {
  case "$1" in
    slack | discord) return 0 ;;
    *) return 1 ;;
  esac
}

# Route a manifest's completion notify by platform. Only `slack` and
# `discord` have a real outbound send wired here — any other/unknown
# platform (e.g. `google_chat`, which currently only has an *inbound*
# webhook route with no send credential — see hermes/README.md フェーズE) is
# logged and left for retry rather than silently routed through
# notify_slack against the wrong channel namespace (see module docstring).
notify_dispatch() {
  local platform="$1" channel="$2" text="$3"
  if ! has_notify_adapter "$platform"; then
    log "no outbound notify adapter wired for platform=$platform (channel=$channel) — skipping (will retry next pass)"
    return 1
  fi
  case "$platform" in
    slack)
      notify_slack "$channel" "$text"
      ;;
    discord)
      notify_discord "$channel" "$text"
      ;;
  esac
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
  local job_id platform channel repo bg_job_id status notified workspace_host_dir claude_config_host_dir created_at

  job_id=$(jq -r '.job_id' "$manifest_path")
  platform=$(jq -r '.platform' "$manifest_path")
  channel=$(jq -r '.channel' "$manifest_path")
  repo=$(jq -r '.repo' "$manifest_path")
  bg_job_id=$(jq -r '.bg_job_id // empty' "$manifest_path")
  status=$(jq -r '.status' "$manifest_path")
  notified=$(jq -r '.notified' "$manifest_path")
  workspace_host_dir=$(jq -r '.workspace_host_dir' "$manifest_path")
  claude_config_host_dir=$(jq -r '.claude_config_host_dir' "$manifest_path")
  created_at=$(jq -r '.created_at // 0' "$manifest_path")

  if [ "$status" = "pending" ] || [ "$status" = "running" ]; then
    local age
    age=$(job_age_seconds "$created_at")

    if [ -z "$bg_job_id" ]; then
      if [ "$age" -ge "$REAP_TIMEOUT_SECONDS" ]; then
        # Dispatch never got as far as writing bg_job_id (e.g. the
        # dispatching process was interrupted right after `reserve`) — this
        # job can never progress on its own and would otherwise be skipped
        # on every single pass forever, permanently occupying a
        # max_concurrent_jobs slot (PR #117 review). Reap it: force to
        # `failed` and fall through into the normal notify+cleanup path
        # below instead of returning early.
        log "job $job_id ($status) never received a bg_job_id and exceeded ${REAP_TIMEOUT_SECONDS}s (age=${age}s) — reaping as failed (dispatch timeout)"
        status="failed"
        set_manifest_field "$manifest_path" "status" "\"failed\""
      else
        log "job $job_id ($status) has no bg_job_id yet — skipping"
        return
      fi
    else
      if [ "$age" -ge "$REAP_TIMEOUT_SECONDS" ]; then
        # An actually-dispatched job is left running — poll_bg_status is
        # still the source of truth for its real state — but a job stuck
        # for hours should be visible rather than silently polled forever.
        log "job $job_id ($status) has been running for ${age}s, past the ${REAP_TIMEOUT_SECONDS}s timeout threshold (bg_job_id=$bg_job_id) — timeout warning"
      fi
      local polled
      polled=$(poll_bg_status "$manifest_path" "$claude_config_host_dir" "$workspace_host_dir" "$bg_job_id" "$created_at")
      if [ "$polled" = "running" ]; then
        # bg session listing still says running — cross-check the per-job
        # container's own liveness (issue #122 / AC-2): a killed/OOM'd/
        # daemon-restart-vanished container can otherwise be polled forever
        # since poll_bg_status alone never observes it.
        local container_id
        container_id=$(jq -r '.container_id // empty' "$manifest_path")
        if [ -z "$container_id" ]; then
          # Pre-#122 manifest with no container_id recorded — skip the
          # check entirely, preserving prior behavior.
          log "job $job_id still running — skipping"
          return
        fi
        local cstate
        cstate=$(poll_container_state "$container_id")
        case "$cstate" in
          alive)
            if [ "$(jq -r '.container_dead_streak // 0' "$manifest_path" 2>/dev/null || echo 0)" != "0" ]; then
              set_manifest_field "$manifest_path" "container_dead_streak" "0"
            fi
            log "job $job_id still running — skipping"
            return
            ;;
          unknown)
            log "job $job_id container state unknown (docker unavailable) — leaving container_dead_streak unchanged"
            return
            ;;
          dead)
            local streak
            streak=$(jq -r '.container_dead_streak // 0' "$manifest_path" 2>/dev/null || echo 0)
            streak=$((streak + 1))
            set_manifest_field "$manifest_path" "container_dead_streak" "$streak"
            if [ "$streak" -lt "$CONTAINER_DEAD_CONFIRM_COUNT" ]; then
              log "job $job_id per-job container $container_id observed dead ($streak/$CONTAINER_DEAD_CONFIRM_COUNT consecutive passes) — not yet reconciling"
              return
            fi
            log "job $job_id per-job container $container_id dead for $streak consecutive passes while bg session still listed running — reconciling status to failed (issue #122)"
            status="failed"
            set_manifest_field "$manifest_path" "status" '"failed"'
            ;;
        esac
      else
        status="$polled"
        set_manifest_field "$manifest_path" "status" "\"$status\""
      fi
    fi
  fi

  # status is now terminal (done/failed).
  if [ "$notified" = "false" ]; then
    if notify_dispatch "$platform" "$channel" "hermes job $job_id ($repo) finished: $status"; then
      set_manifest_field "$manifest_path" "notified" "true"
      log "job $job_id notified (status=$status, platform=$platform)"
    elif ! has_notify_adapter "$platform"; then
      # This platform can never succeed a notify (no outbound adapter, e.g.
      # google_chat) — `notified` would stay `false` forever, so cleanup_job
      # below would never run and workspace_host_dir/manifest would leak
      # permanently (PR #117 review). Once stuck this long, reclaim anyway:
      # accept the loss of the notify guarantee for this one job rather than
      # leak its slot/workspace forever.
      local age
      age=$(job_age_seconds "$created_at")
      if [ "$age" -ge "$REAP_TIMEOUT_SECONDS" ]; then
        log "job $job_id (platform=$platform) has no outbound notify adapter and stayed unnotified for ${age}s past the ${REAP_TIMEOUT_SECONDS}s threshold — reaping (cleanup without notify) to avoid a permanent leak"
        cleanup_job "$manifest_path" "$workspace_host_dir" "$job_id"
      fi
    fi
    # Cleanup is deliberately deferred to the pass *after* notified=true is
    # durably on disk (see module docstring) — do not fall through here,
    # except via the reap path above.
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
