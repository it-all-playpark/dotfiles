#!/usr/bin/env bash
# Stop hook: feature branch で未 commit 差分が残っている場合に継続を強制する
#
# Claude Code の Stop event で呼び出される hook。feature branch で staged /
# unstaged の差分が残ったまま session を終えようとした場合、exit 2 を返して
# Claude に継続を促すガードを提供する。
#
# 無効化条件（いずれかに該当すると exit 0）:
#   - 環境変数 CLAUDE_STOP_GUARD=0（escape hatch）
#   - カレントディレクトリが git worktree 外
#   - branch が main / master / dev / develop / development
#   - detached HEAD（branch 判定不能）
#   - 差分が一切ない
#   - bg セッションに実行中の local_workflow task がある（例: dev-flow を
#     Workflow tool で bg 起動し、EnterWorktree でこの worktree に入って
#     待機しているケース。差分は自分ではなく実行中の Workflow が書いている
#     途中のものなので「忘れ物」ではない）。判定は
#     ~/.claude/jobs/<session_id先頭8桁>/state.json の inFlight.kinds を見る。
#     このファイルは harness 内部の状態ファイルで形式が変わり得るため、
#     読み取り失敗・キー不在時は安全側（従来通りブロック）にフォールバックする。
#
# stdin: Claude Code Hooks の JSON payload（session_id を bg-workflow 判定に使う）
# stdout: なし
# stderr: ブロック時のガイドメッセージ
# 終了コード:
#   0 - 継続可（ガード不要）
#   2 - ブロック（未 commit 差分あり、Claude に継続を促す）
#
# Ref: https://code.claude.com/docs/en/hooks

set -euo pipefail

# stdin は JSON payload。session_id を bg-workflow 判定に使うため読み取る。
# 読み取り失敗（pipe closed 等）は無視して空 JSON 扱いで先へ進む。
PAYLOAD=$(cat 2>/dev/null || echo '{}')

# Escape hatch: 環境変数での bypass
if [[ ${CLAUDE_STOP_GUARD:-1} == "0" ]]; then
  exit 0
fi

# git worktree 外では何もしない
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# branch 判定。detached HEAD の場合は "HEAD" が返る。
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "${BRANCH}" in
"" | HEAD)
  # 判定不能（detached HEAD 等）→ 副作用を避けてスルー
  exit 0
  ;;
main | master | dev | develop | development)
  # 保護ブランチ。通常対話を妨げないため無効。
  exit 0
  ;;
esac

# staged / unstaged 双方をチェック
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  exit 0
fi

# bg セッションに実行中の local_workflow task があれば、この差分はその task が
# 書いている途中のものである可能性が高く「忘れ物」ではないためスルーする。
# jq 不在・state.json 不在・schema 不一致など何かあれば安全側（ブロック継続）。
SESSION_ID=$(printf '%s' "${PAYLOAD}" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -n ${SESSION_ID} ]]; then
  JOB_STATE="${HOME}/.claude/jobs/${SESSION_ID%%-*}/state.json"
  if [[ -f ${JOB_STATE} ]]; then
    HAS_WORKFLOW=$(jq -r '.inFlight.kinds // [] | index("local_workflow") // empty' "${JOB_STATE}" 2>/dev/null || echo "")
    if [[ -n ${HAS_WORKFLOW} ]]; then
      exit 0
    fi
  fi
fi

# ここまで来たら feature branch で差分あり → ブロック
cat >&2 <<MSG
[stop-unfinished-guard] 未コミットの差分が残っています (branch: ${BRANCH})。
以下のいずれかを実施してから再度 Stop してください:
  1. 意図した差分なら commit する: git add -A && git commit -m "..."
  2. 作業継続中なら実装を進める
  3. 破棄するなら: git stash / git restore
一時的に無効化するには環境変数 CLAUDE_STOP_GUARD=0 を設定してください。
MSG
exit 2
