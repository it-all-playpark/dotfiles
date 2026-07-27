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
# malformed replay runbook（pending/malformed/ に落ちた handoff の回収手順）:
#   1. mv ~/.claude/journal/pending/malformed/<file>.json ~/.claude/journal/pending/
#   2. echo '{}' | bash ~/.claude/hooks/stop-devflow-telemetry.sh  # または次の Stop event
#   3. ~/.claude/logs/stop-devflow-telemetry.log に journal-failed が無いことを確認
#   注: outcome=failure かつ error_category/error_msg を欠く payload は journal.sh 契約
#   （outcome != success で両キー必須）で journal-failed → pending/ に残り続ける。
#   再投入前に payload へ error_category（enum: lint|test|build|runtime|config|env|merge|
#   type-check|needs_clarification|empty_diff）と error_msg を手で追記すること。
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
if [[ ${CLAUDE_DEVFLOW_TELEMETRY_HOOK:-1} == "0" ]]; then
  exit 0
fi

PENDING_DIR="${CLAUDE_JOURNAL_DIR:-${HOME}/.claude/journal}/pending"

if [[ ! -d $PENDING_DIR ]]; then
  exit 0
fi

FALLBACK_JOURNAL="${HOME}/ghq/github.com/it-all-playpark/skills/skill-retrospective/scripts/journal.sh"
LOG_FILE="${HOME}/.claude/logs/stop-devflow-telemetry.log"

# Process each *.json in pending dir
for f in "${PENDING_DIR}"/*.json; do
  # No files matched (glob literal returned)
  [[ -e $f ]] || continue

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
  eval_staleness=""
  repo=""
  pr_number=""
  ci_wait_seconds=""
  ci_poll_attempts=""
  trust_run_id=""
  trust_receipts_json=""
  trust_surfaceproof_json=""
  error_category=""
  error_msg=""

  if ! parsed=$(jq -e '{
    skill: .skill,
    outcome: .outcome,
    issue: .issue,
    journal_sh: .journal_sh,
    repo: .repo,
    pr_number: .pr_number,
    error_category: .error_category,
    error_msg: .error_msg,
    merge_tier: .telemetry.merge_tier,
    gate_policy: .telemetry.gate_policy,
    danger_hits: (.telemetry.danger_hits // []),
    shape: .telemetry.shape,
    shape_refloored: .telemetry.shape_refloored,
    plan_iter: .telemetry.plan_iter,
    eval_iter: .telemetry.eval_iter,
    eval_verdict: .telemetry.eval_verdict,
    iterate_status: .telemetry.iterate_status,
    eval_staleness: .telemetry.eval_staleness,
    ci_wait_seconds: .telemetry.ci_wait_seconds,
    ci_poll_attempts: .telemetry.ci_poll_attempts,
    trust_run_id: .telemetry.trust_run_id,
    trust_receipts: .telemetry.trust_receipts,
    trust_surfaceproof: .telemetry.trust_surfaceproof_shadow
  }' "$claimed" 2>/dev/null); then
    # JSON parse error
    mkdir -p "${PENDING_DIR}/malformed"
    mv "$claimed" "${PENDING_DIR}/malformed/$(basename "$f")"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s malformed-json %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >>"$LOG_FILE"
    continue
  fi

  skill=$(echo "$parsed" | jq -r '.skill // empty')
  outcome=$(echo "$parsed" | jq -r '.outcome // empty')
  merge_tier=$(echo "$parsed" | jq -r '.merge_tier // empty')

  # Required key check（producer 契約 _lib/journal-handoff.mjs と一致: skill/outcome のみ必須。
  # merge_tier は standard/complex shape 由来で micro shape や pr-iterate 単体起動には存在しない
  # ため required から除外し、下流で conditional 転送する）
  if [[ -z $skill || -z $outcome ]]; then
    mkdir -p "${PENDING_DIR}/malformed"
    mv "$claimed" "${PENDING_DIR}/malformed/$(basename "$f")"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s missing-required-key %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >>"$LOG_FILE"
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
  eval_staleness=$(echo "$parsed" | jq -r '.eval_staleness // empty')
  repo=$(echo "$parsed" | jq -r '.repo // empty')
  pr_number=$(echo "$parsed" | jq -r '.pr_number // empty')
  error_category=$(echo "$parsed" | jq -r '.error_category // empty')
  error_msg=$(echo "$parsed" | jq -r '.error_msg // empty')
  ci_wait_seconds=$(echo "$parsed" | jq -r '.ci_wait_seconds // empty')
  ci_poll_attempts=$(echo "$parsed" | jq -r '.ci_poll_attempts // empty')
  trust_run_id=$(echo "$parsed" | jq -r '.trust_run_id // empty')
  trust_receipts_json=$(echo "$parsed" | jq -c '.trust_receipts // empty')
  trust_surfaceproof_json=$(echo "$parsed" | jq -c '.trust_surfaceproof // empty')

  # --- Resolve journal.sh ---
  journal_sh=""
  if [[ -n $journal_sh_field && -x $journal_sh_field ]]; then
    journal_sh="$journal_sh_field"
  elif [[ -x $FALLBACK_JOURNAL ]]; then
    journal_sh="$FALLBACK_JOURNAL"
  else
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s no-journal-sh %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >>"$LOG_FILE"
    mv "$claimed" "$f"
    continue
  fi

  # --- Build command args ---
  cmd_args=(
    log "$skill" "$outcome"
    --issue "$issue"
  )

  # merge_tier は standard/complex shape 由来の optional field（producer 契約は skill/outcome
  # のみ必須）。micro shape run や pr-iterate 単体起動には存在しないため conditional 転送とし、
  # 既存呼び出しとの引数順序 byte 互換のため --issue 直後に挿入する。
  if [[ -n $merge_tier && $merge_tier != "null" ]]; then
    cmd_args+=(--merge-tier "$merge_tier")
  fi

  cmd_args+=(
    --gate-policy "$gate_policy"
    --danger-hits "$danger_hits_json"
    --shape "$shape"
    --shape-refloored "$shape_refloored"
    --plan-iter "$plan_iter"
    --eval-iter "$eval_iter"
  )

  # Optional fields: only append if non-empty and not null
  if [[ -n $eval_verdict && $eval_verdict != "null" ]]; then
    cmd_args+=(--eval-verdict "$eval_verdict")
  fi
  if [[ -n $iterate_status && $iterate_status != "null" ]]; then
    cmd_args+=(--iterate-status "$iterate_status")
  fi
  if [[ -n $eval_staleness && $eval_staleness != "null" ]]; then
    cmd_args+=(--eval-staleness "$eval_staleness")
  fi
  if [[ -n $repo && $repo != "null" ]]; then
    cmd_args+=(--repo "$repo")
  fi
  if [[ -n $pr_number && $pr_number != "null" ]]; then
    cmd_args+=(--pr-number "$pr_number")
  fi
  if [[ -n $ci_wait_seconds && $ci_wait_seconds != "null" ]]; then
    cmd_args+=(--ci-wait-seconds "$ci_wait_seconds")
  fi
  if [[ -n $ci_poll_attempts && $ci_poll_attempts != "null" ]]; then
    cmd_args+=(--ci-poll-attempts "$ci_poll_attempts")
  fi
  # journal.sh は outcome != success のとき --error-category / --error-msg を必須とする
  # （journal.sh L128-133）。これを欠くと失敗 run が journal-failed で pending に留まり続ける。
  if [[ -n $error_category && $error_category != "null" ]]; then
    cmd_args+=(--error-category "$error_category")
  fi
  if [[ -n $error_msg && $error_msg != "null" ]]; then
    cmd_args+=(--error-msg "$error_msg")
  fi

  # --- trust telemetry (epic #390 Phase 5 / issue #413) ---
  # journal.sh は --trust-receipts / --trust-surfaceproof を closed enum で検証し、契約違反時は
  # exit 1 する。無検査で転送すると entry 全体が pending へ差し戻され、merge_tier 等の基本
  # telemetry ごと恒久的に失われる。trust キーは optional な付加情報なので、契約を満たす値だけを
  # 転送し、満たさない値は drop してログに残す（fail-open — base entry の記録を最優先する）。
  # 例: SurfaceProof が advisory/blocking へ昇格した run は verdict:null を出すため drop される
  #     （journal.sh 側 enum の拡張は昇格 PR の責務であり本 hook の責務ではない）。
  if [[ -n $trust_run_id && $trust_run_id != "null" ]]; then
    cmd_args+=(--trust-run-id "$trust_run_id")
  fi
  if [[ -n $trust_receipts_json && $trust_receipts_json != "null" ]]; then
    if echo "$trust_receipts_json" | jq -e '
      type == "array" and length > 0 and all(.[];
        (.layer // "") as $l | (.mode // "") as $m | (.verdict // "") as $v |
        (["surfaceproof","evalseal","effectdelta"] | index($l)) != null and
        (["off","shadow","advisory","blocking"] | index($m)) != null and
        (["pass","fail","inconclusive"] | index($v)) != null)' >/dev/null 2>&1; then
      cmd_args+=(--trust-receipts "$trust_receipts_json")
    else
      mkdir -p "$(dirname "$LOG_FILE")"
      printf '%s %s trust-key-dropped: trust_receipts (journal.sh closed-enum 契約を満たさない)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >>"$LOG_FILE"
    fi
  fi
  if [[ -n $trust_surfaceproof_json && $trust_surfaceproof_json != "null" ]]; then
    if echo "$trust_surfaceproof_json" | jq -e '
      type == "object" and
      ((.mode // "") as $m | (.verdict // "") as $v |
       (["off","shadow","advisory","blocking"] | index($m)) != null and
       (["pass","fail","inconclusive"] | index($v)) != null)' >/dev/null 2>&1; then
      cmd_args+=(--trust-surfaceproof "$trust_surfaceproof_json")
    else
      mkdir -p "$(dirname "$LOG_FILE")"
      printf '%s %s trust-key-dropped: trust_surfaceproof_shadow (journal.sh closed-enum 契約を満たさない)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" >>"$LOG_FILE"
    fi
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
      "$(echo "$journal_stderr" | head -1 | tr '\n' ' ')" >>"$LOG_FILE"
  fi
done

exit 0
