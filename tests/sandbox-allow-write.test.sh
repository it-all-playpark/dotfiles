#!/usr/bin/env bash
# tests/sandbox-allow-write.test.sh
# Unit test for claude-code/settings.json's sandbox.filesystem.allowWrite array.
# Run from the repo root: bash tests/sandbox-allow-write.test.sh
# Requires: jq
#
# issue #214: pnpm の store operation lock（/tmp/pnpm-store-operation-locks-<uid>/）
# の配下に書けることを、Claude Code の sandbox と同じ一致規則で検証する。
# - glob（* ? [ を含む）エントリ: パス全体に一致する正規表現になる（`*`→`[^/]*`、
#   `**/`→`(.*/)?`、`**`→`.*`）。そのパス自体にしか効かず、配下には効かない
# - リテラルのエントリ: subpath 扱いで、そのパスと配下すべてに効く
# - 判定の前に末尾の `/**` を剥がす（Claude Code の allowWrite.map(pg)）。
#   `-*/**` は `-*` と同じになり、配下には効かない
# `/private/tmp/pnpm-store-operation-locks-*` だけではディレクトリ作成しか通らず、
# 既存の all-stores.lock を開き直す 2 回目以降の pnpm が EPERM で落ちていた。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"

PASS=0
FAIL=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== sandbox.filesystem.allowWrite unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# settings_is_valid_json
# ---------------------------------------------------------------------------
echo "- settings_is_valid_json"
if jq empty "${SETTINGS}" >/dev/null 2>&1; then
  pass "settings_is_valid_json"
else
  fail "settings_is_valid_json" "${SETTINGS} is not valid JSON"
fi

ALLOW_WRITE_JSON="$(jq -c '.sandbox.filesystem.allowWrite' "${SETTINGS}")"

# write_allowed <path>: allowWrite のいずれかのエントリが <path> への書き込みを許すか
write_allowed() {
  jq -e --arg p "$1" --arg home "${HOME}" '
    def glob_to_regex:
      "^" + (
        gsub("(?<c>[.^$+{}()|\\\\])"; "\\\(.c)")
        | gsub("\\*\\*/"; "\u0001")
        | gsub("\\*\\*"; "\u0002")
        | gsub("\\*"; "[^/]*")
        | gsub("\\?"; "[^/]")
        | gsub("\u0001"; "(.*/)?")
        | gsub("\u0002"; ".*")
      ) + "$";
    def expand_home: if startswith("~/") then $home + .[1:] else . end;
    def strip_globstar_suffix: sub("/\\*\\*$"; "") | if . == "" then "/" else . end;
    map(expand_home | strip_globstar_suffix)
    | any(
        . as $e
        | if $e | test("[*?\\[]") then
            $p | test($e | glob_to_regex)
          else
            ($p == $e) or ($p | startswith($e + "/"))
          end
      )
  ' <<<"${ALLOW_WRITE_JSON}" >/dev/null
}

LOCK_DIR="/private/tmp/pnpm-store-operation-locks-502"

# ---------------------------------------------------------------------------
# pnpm_lock_dir_writable
# ---------------------------------------------------------------------------
echo "- pnpm_lock_dir_writable"
if write_allowed "${LOCK_DIR}"; then
  pass "pnpm_lock_dir_writable"
else
  fail "pnpm_lock_dir_writable" "${LOCK_DIR} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_all_stores_lock_writable
# ---------------------------------------------------------------------------
echo "- pnpm_all_stores_lock_writable"
if write_allowed "${LOCK_DIR}/all-stores.lock"; then
  pass "pnpm_all_stores_lock_writable"
else
  fail "pnpm_all_stores_lock_writable" "${LOCK_DIR}/all-stores.lock is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_per_store_lock_writable
# ---------------------------------------------------------------------------
echo "- pnpm_per_store_lock_writable"
per_store_lock="${LOCK_DIR}/0fddfda5c3f3059f44d27e74068169714961516a980eb80cf6533e87e93601e7.lock"
if write_allowed "${per_store_lock}"; then
  pass "pnpm_per_store_lock_writable"
else
  fail "pnpm_per_store_lock_writable" "${per_store_lock} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_store_dir_writable
# ---------------------------------------------------------------------------
echo "- pnpm_store_dir_writable"
store_file="${HOME}/Library/pnpm/store/v10/index/00/abc-index.json"
if write_allowed "${store_file}"; then
  pass "pnpm_store_dir_writable"
else
  fail "pnpm_store_dir_writable" "${store_file} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# npm_cache_writable
# dev-flow の deps install（npm ci）は sandbox 内で走る（skills #868）。
# ~/.npm/_cacache に書けないと EPERM で落ちる。~/.npm の他（_npx 等）は開けない。
# ---------------------------------------------------------------------------
echo "- npm_cache_writable"
cache_file="${HOME}/.npm/_cacache/content-v2/sha512/00/ab/abc"
if write_allowed "${cache_file}" && ! write_allowed "${HOME}/.npm/_npx/abc/package.json"; then
  pass "npm_cache_writable"
else
  fail "npm_cache_writable" "${cache_file} must be writable and ~/.npm/_npx must not be"
fi

# ---------------------------------------------------------------------------
# uv_cache_dir_writable
# issue #317: sandbox 内の uv run は ~/.cache/uv を初期化できず exit 2 で落ちる。
# env の UV_CACHE_DIR を allowWrite 内の /private/tmp/claude/uv-cache に向ける。
# ~/.cache/uv は sandbox 外の uv と共有するキャッシュなので開けない。
# ---------------------------------------------------------------------------
echo "- uv_cache_dir_writable"
uv_cache_dir="$(jq -r '.env.UV_CACHE_DIR // ""' "${SETTINGS}")"
if [ "${uv_cache_dir}" = "/private/tmp/claude/uv-cache" ] &&
  jq -e 'index("/private/tmp/claude") != null' <<<"${ALLOW_WRITE_JSON}" >/dev/null &&
  write_allowed "${uv_cache_dir}/sdists-v10/.git" &&
  ! write_allowed "${HOME}/.cache/uv/sdists-v10/.git"; then
  pass "uv_cache_dir_writable"
else
  fail "uv_cache_dir_writable" "env.UV_CACHE_DIR=${uv_cache_dir:-<unset>} must be /private/tmp/claude/uv-cache under allowWrite's /private/tmp/claude, and ~/.cache/uv must not be writable"
fi

# ---------------------------------------------------------------------------
# gh_cache_writable
# issue #352: gh run view --log / --log-failed はログの zip を ~/.cache/gh/run-log-*.zip に
# キャッシュし、書けないと `creating cache entry: … operation not permitted` で落ちる。
# ~/.cache/gh から実行されるものは無いので開ける。~/.cache 全体には広げない。
# ---------------------------------------------------------------------------
echo "- gh_cache_writable"
gh_cache_file="${HOME}/.cache/gh/run-log-123456789-1760000000.zip"
if write_allowed "${gh_cache_file}" && ! write_allowed "${HOME}/.cache/other-tool/x"; then
  pass "gh_cache_writable"
else
  fail "gh_cache_writable" "${gh_cache_file} must be writable and the rest of ~/.cache must not be"
fi

# ---------------------------------------------------------------------------
# gcloud_account_config_dirs_writable
# account-exec はアカウントごとの CLOUDSDK_CONFIG（account-map の gcloud_config_dir、
# ~/.config/gcloud-<account>）で gcloud を起動する。gcloud は読み取り系のコマンドでも
# logs/<日付>/<時刻>.log と credentials.db に書き、書けないと exit 1 で落ちる。
# glob は配下に効かないので、配下は `**/*` で任意の深さに一致させる。
# ---------------------------------------------------------------------------
echo "- gcloud_account_config_dirs_writable"
gcloud_dir="${HOME}/.config/gcloud-acme"
expected_writable=(
  "${gcloud_dir}"
  "${gcloud_dir}/credentials.db"
  "${gcloud_dir}/logs/2026.10.27/11.39.08.130829.log"
)
not_writable=(
  "${HOME}/.config/gcloudx/credentials.db"
  "${HOME}/.config/other-tool/x"
)
missed=()
for p in "${expected_writable[@]}"; do
  write_allowed "${p}" || missed+=("${p}")
done
leaked=()
for p in "${not_writable[@]}"; do
  write_allowed "${p}" && leaked+=("${p}")
done
if [ "${#missed[@]}" -ne 0 ]; then
  fail "gcloud_account_config_dirs_writable" "Not covered by allowWrite: ${missed[*]}"
elif [ "${#leaked[@]}" -ne 0 ]; then
  fail "gcloud_account_config_dirs_writable" "Unexpectedly writable: ${leaked[*]}"
else
  pass "gcloud_account_config_dirs_writable"
fi

# ---------------------------------------------------------------------------
# tmp_root_not_writable
# ---------------------------------------------------------------------------
echo "- tmp_root_not_writable"
# /tmp 全体は開けない（hook の claude-skill-ctx-* や bridge のソケットと共有する領域）
not_expected=(
  "/private/tmp/claude-skill-ctx-probe"
  "/private/tmp/pnpm-store-operation-locks"
  "/private/tmp/other-dir/pnpm-store-operation-locks-502/all-stores.lock"
  "${LOCK_DIR}/sub/deeper.lock"
)
leaked=()
for p in "${not_expected[@]}"; do
  write_allowed "${p}" && leaked+=("${p}")
done
if [ "${#leaked[@]}" -eq 0 ]; then
  pass "tmp_root_not_writable"
else
  fail "tmp_root_not_writable" "Unexpectedly writable: ${leaked[*]}"
fi

# ---------------------------------------------------------------------------
# no_duplicate_entries
# ---------------------------------------------------------------------------
echo "- no_duplicate_entries"
total_len="$(jq 'length' <<<"${ALLOW_WRITE_JSON}")"
unique_len="$(jq 'unique | length' <<<"${ALLOW_WRITE_JSON}")"
if [ "${total_len}" -eq "${unique_len}" ]; then
  pass "no_duplicate_entries"
else
  fail "no_duplicate_entries" "length=${total_len} unique=${unique_len}"
fi

# ---------------------------------------------------------------------------
# no_globstar_suffix_entries
# ---------------------------------------------------------------------------
echo "- no_globstar_suffix_entries"
# 末尾 `/**` は Claude Code が剥がすので、書いても配下に効かない（効くと誤解させるだけ）
globstar_entries="$(jq -r '.[] | select(endswith("/**"))' <<<"${ALLOW_WRITE_JSON}")"
if [ -z "${globstar_entries}" ]; then
  pass "no_globstar_suffix_entries"
else
  fail "no_globstar_suffix_entries" "Entries ending in /** (stripped by Claude Code): ${globstar_entries//$'\n'/ }"
fi

# ---------------------------------------------------------------------------
# repo_config_deny_covers_main_checkouts_not_worktrees
# ---------------------------------------------------------------------------
echo "- repo_config_deny_covers_main_checkouts_not_worktrees"
# denyWrite の glob は allowWrite と違い配下にも効く（2026-10-16 実測: 作業中でない repo の
# 既存 .claude/skills へのファイル作成が EPERM）。
# issue #366: Claude Code の組み込み保護は起動元 repo しか塞がないので、~/ghq 深さ 3 の全 repo の
# .git/hooks・.git/config・.claude/settings{,.local}.json・.claude/hooks も塞ぐ（後で sandbox 外の
# git や Claude Code に実行されるもの）。<repo>/.claude/worktrees/<name>/ の追跡ファイルは塞がない。
# 塞ぐと wt-add / dev-flow / bg job が worktree を取り出せず、worktree の pre-push がそこの
# スクリプトを読むテストで落ちる。glob を `**` にすると worktree 側まで塞がれてこのケースが落ちる。
DENY_WRITE_JSON="$(jq -c '.sandbox.filesystem.denyWrite' "${SETTINGS}")"
write_denied() {
  jq -e --arg p "$1" --arg home "${HOME}" '
    def glob_to_regex:
      "^" + (
        gsub("(?<c>[.^$+{}()|\\\\])"; "\\\(.c)")
        | gsub("\\*\\*/"; "\u0001")
        | gsub("\\*\\*"; "\u0002")
        | gsub("\\*"; "[^/]*")
        | gsub("\\?"; "[^/]")
        | gsub("\u0001"; "(.*/)?")
        | gsub("\u0002"; ".*")
      ) + "(/.*)?$";
    def expand_home: if startswith("~/") then $home + .[1:] else . end;
    map(expand_home) | any(. as $e | $p | test($e | glob_to_regex))
  ' <<<"${DENY_WRITE_JSON}" >/dev/null
}
R="${HOME}/ghq/github.com/playpark-llc/corporate-site"
WT="${R}/.claude/worktrees/w"
expected_denied=(
  "${R}/.claude/skills/x/SKILL.md"
  "${R}/.git/hooks/pre-push"
  "${R}/.git/config"
  "${R}/.claude/settings.json"
  "${R}/.claude/settings.local.json"
  "${R}/.claude/hooks/x.sh"
  # issue #409: codex（sandbox の外）が読む project config。mcp_servers・notify を書けるので worktree 側も塞ぐ
  "${R}/.codex/config.toml"
  "${WT}/.codex/config.toml"
)
not_denied=(
  "${WT}/.claude/settings.json"
  "${WT}/.claude/settings.local.json"
  "${WT}/.claude/hooks/x.sh"
  "${WT}/.claude/skills/x/SKILL.md"
  # worktree の中で git init したテスト用 repo（.git/hooks・.git/config を `**` にすると塞がれる）
  "${WT}/.devflow-tmp/fixture/.git/config"
  "${WT}/.devflow-tmp/fixture/.git/hooks/pre-commit"
  "${R}/.git/worktrees/w/HEAD"
  "${R}/.git/refs/heads/x"
  "${R}/.claude/scheduled_tasks.json"
)
missed=()
for p in "${expected_denied[@]}"; do
  write_denied "${p}" || missed+=("${p}")
done
over_denied=()
for p in "${not_denied[@]}"; do
  write_denied "${p}" && over_denied+=("${p}")
done
if [ "${#missed[@]}" -ne 0 ]; then
  fail "repo_config_deny_covers_main_checkouts_not_worktrees" "Not denied: ${missed[*]}"
elif [ "${#over_denied[@]}" -ne 0 ]; then
  fail "repo_config_deny_covers_main_checkouts_not_worktrees" "Unexpectedly denied: ${over_denied[*]}"
else
  pass "repo_config_deny_covers_main_checkouts_not_worktrees"
fi

# ---------------------------------------------------------------------------
# permissions_deny_guards_repo_git_and_sns_sync
# ---------------------------------------------------------------------------
echo "- permissions_deny_guards_repo_git_and_sns_sync"
# issue #366: Edit(path) の deny は Edit / Write ツールと Bash のリダイレクトにも効く。Write(path) は
# Claude Code が参照しない（docs permissions「Read and Edit」）ので書かない。
# zernio sync --execute（orphan delete で投稿を消す）は --execute が末尾に来るか global option が
# 前に付くので、前方一致ではなく `*` を両側に置く。Bash ルールは `*` を `.*` にした全体一致で見る。
DENY_JSON="$(jq -c '.permissions.deny' "${SETTINGS}")"
bash_denied() {
  jq -e --arg c "$1" '
    map(
      select(startswith("Bash(") and endswith(")"))
      | .[5:-1]
      | "^" + (gsub("(?<c>[.^$+?{}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*")) + "$"
    )
    | any(. as $re | $c | test($re))
  ' <<<"${DENY_JSON}" >/dev/null
}
required_rules=(
  "Edit(~/ghq/*/*/*/.git/config)"
  "Edit(~/ghq/*/*/*/.git/hooks/**)"
  "Bash(zernio *--execute*)"
)
missing_rules=()
for r in "${required_rules[@]}"; do
  jq -e --arg r "${r}" 'index($r) != null' <<<"${DENY_JSON}" >/dev/null || missing_rules+=("${r}")
done
write_rules="$(jq -r '.[] | select(startswith("Write("))' <<<"${DENY_JSON}")"
sync_execute=(
  "zernio sync --execute"
  "zernio sync --dir ./post/blog --from 2026-04-01 --execute"
  "zernio -v sync --execute --verbose"
)
not_sync_execute=(
  "zernio post --json f.json"
  "zernio sync --dir x"
  "zernio delete-post --id X"
)
unmatched=()
for c in "${sync_execute[@]}"; do
  bash_denied "${c}" || unmatched+=("${c}")
done
over_matched=()
for c in "${not_sync_execute[@]}"; do
  bash_denied "${c}" && over_matched+=("${c}")
done
if [ "${#missing_rules[@]}" -ne 0 ]; then
  fail "permissions_deny_guards_repo_git_and_sns_sync" "Missing deny rules: ${missing_rules[*]}"
elif [ -n "${write_rules}" ]; then
  fail "permissions_deny_guards_repo_git_and_sns_sync" "Write( rules are ignored by Claude Code: ${write_rules//$'\n'/ }"
elif [ "${#unmatched[@]}" -ne 0 ]; then
  fail "permissions_deny_guards_repo_git_and_sns_sync" "Not denied: ${unmatched[*]}"
elif [ "${#over_matched[@]}" -ne 0 ]; then
  fail "permissions_deny_guards_repo_git_and_sns_sync" "Unexpectedly denied: ${over_matched[*]}"
else
  pass "permissions_deny_guards_repo_git_and_sns_sync"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
