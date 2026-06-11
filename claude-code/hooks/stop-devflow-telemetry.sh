#!/usr/bin/env bash
# Stop hook: dev-flow telemetry handoff flush
#
# Claude Code の Stop event で呼び出される hook。dev-flow が pending dir に書き出した
# handoff JSON を読み取り、journal.sh log コマンドへ転送して telemetry を記録する。
#
# pending dir: ${CLAUDE_JOURNAL_DIR:-$HOME/.claude/journal}/pending/
# 各 *.json を atomic claim（mv + PID suffix）してから処理し、成功なら削除、
# 失敗なら元のファイル名に戻す（次回 Stop で再試行）。
#
# 無効化:
#   - 環境変数 CLAUDE_DEVFLOW_TELEMETRY_HOOK=0（escape hatch）
#   - pending dir が存在しない
#
# stdout: なし
# stderr: なし（ログは $HOME/.claude/logs/stop-devflow-telemetry.log へ）
# 終了コード: 常に 0（Stop を絶対にブロックしない）
#
# Ref: https://code.claude.com/docs/en/hooks

set -euo pipefail

# stdin は JSON payload 前提。SIGPIPE 回避のため drain する。
cat >/dev/null 2>&1 || true

# Escape hatch
if [[ "${CLAUDE_DEVFLOW_TELEMETRY_HOOK:-1}" == "0" ]]; then
  exit 0
fi

PENDING_DIR="${CLAUDE_JOURNAL_DIR:-${HOME}/.claude/journal}/pending"

if [[ ! -d "$PENDING_DIR" ]]; then
  exit 0
fi

FALLBACK_JOURNAL="${HOME}/ghq/github.com/it-all-playpark/skills/skill-retrospective/scripts/journal.sh"
LOG_FILE="${HOME}/.claude/logs/stop-devflow-telemetry.log"

# Process each *.json in pending dir
for f in "${PENDING_DIR}"/*.json; do
  # No files matched (glob literal returned)
  [[ -e "$f" ]] || continue

  claimed="${f}.claimed.$$"

  # Atomic claim: mv 失敗 = 他プロセスが処理中 → skip
  if ! mv "$f" "$claimed" 2>/dev/null; then
    continue
  fi

  # --- Parse JSON ---
  skill=""
  outcome=""
  issue=""
  journal_sh_field=""
  merge_tier=""
  gate_policy=""
  danger_hits_json=""
  shape=""
  shape_refloored=""
  plan_iter=""
  eval_iter=""
  eval_verdict=""
  iterate_status=""

  if ! parsed=$(jq -e '{
    skill: .skill,
    outcome: .outcome,
    issue: .issue,
    journal_sh: .journal_sh,
    merge_tier: .telemetry.merge_tier,
    gate_policy: .telemetry.gate_policy,
    danger_hits: (.telemetry.danger_hits // []),
    shape: .telemetry.shape,
    shape_refloored: .telemetry.shape_refloored,
    plan_iter: .telemetry.plan_iter,
    eval_iter: .telemetry.eval_iter,
    eval_verdict: .telemetry.eval_verdict,
    iterate_status: .telemetry.iterate_status
  }' "$claimed" 2>/dev/null); then
    # JSON parse error
    mkdir -p "${PENDING_DIR}/malformed"
    mv "$claimed" "${PENDING_DIR}/malformed/$(basename "$f")"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s malformed-json %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >> "$LOG_FILE"
    continue
  fi

  skill=$(echo "$parsed" | jq -r '.skill // empty')
  outcome=$(echo "$parsed" | jq -r '.outcome // empty')
  merge_tier=$(echo "$parsed" | jq -r '.merge_tier // empty')

  # Required key check
  if [[ -z "$skill" || -z "$outcome" || -z "$merge_tier" ]]; then
    mkdir -p "${PENDING_DIR}/malformed"
    mv "$claimed" "${PENDING_DIR}/malformed/$(basename "$f")"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s missing-required-key %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >> "$LOG_FILE"
    continue
  fi

  issue=$(echo "$parsed" | jq -r '.issue // empty')
  journal_sh_field=$(echo "$parsed" | jq -r '.journal_sh // empty')
  gate_policy=$(echo "$parsed" | jq -r '.gate_policy // empty')
  danger_hits_json=$(echo "$parsed" | jq -c '.danger_hits // []')
  shape=$(echo "$parsed" | jq -r '.shape // empty')
  shape_refloored=$(echo "$parsed" | jq -r 'if .shape_refloored == null then "" else (.shape_refloored | tostring) end')
  plan_iter=$(echo "$parsed" | jq -r '.plan_iter // empty')
  eval_iter=$(echo "$parsed" | jq -r '.eval_iter // empty')
  eval_verdict=$(echo "$parsed" | jq -r '.eval_verdict // empty')
  iterate_status=$(echo "$parsed" | jq -r '.iterate_status // empty')

  # --- Resolve journal.sh ---
  journal_sh=""
  if [[ -n "$journal_sh_field" && -x "$journal_sh_field" ]]; then
    journal_sh="$journal_sh_field"
  elif [[ -x "$FALLBACK_JOURNAL" ]]; then
    journal_sh="$FALLBACK_JOURNAL"
  else
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s no-journal-sh %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >> "$LOG_FILE"
    mv "$claimed" "$f"
    continue
  fi

  # --- Build command args ---
  cmd_args=(
    log "$skill" "$outcome"
    --issue "$issue"
    --merge-tier "$merge_tier"
    --gate-policy "$gate_policy"
    --danger-hits "$danger_hits_json"
    --shape "$shape"
    --shape-refloored "$shape_refloored"
    --plan-iter "$plan_iter"
    --eval-iter "$eval_iter"
  )

  # Optional fields: only append if non-empty and not null
  if [[ -n "$eval_verdict" && "$eval_verdict" != "null" ]]; then
    cmd_args+=(--eval-verdict "$eval_verdict")
  fi
  if [[ -n "$iterate_status" && "$iterate_status" != "null" ]]; then
    cmd_args+=(--iterate-status "$iterate_status")
  fi

  # --- Execute journal.sh ---
  journal_stderr=""
  if journal_stderr=$(bash "$journal_sh" "${cmd_args[@]}" 2>&1 >/dev/null); then
    # Success: remove claimed file
    rm -f "$claimed"
  else
    # Failure: restore original filename, write log
    mv "$claimed" "$f"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s %s journal-failed: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(basename "$f")" \
      "$(echo "$journal_stderr" | head -1 | tr '\n' ' ')" >> "$LOG_FILE"
  fi
done

exit 0
