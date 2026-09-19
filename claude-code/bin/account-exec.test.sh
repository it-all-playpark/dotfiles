#!/usr/bin/env bash
# claude-code/bin/account-exec.test.sh
# gh / gcloud の cwd 連動アカウント shim (account-exec) のテスト。
# 設計: docs/specs/2026-09-19-claude-account-env-design.md §9
#
# Usage: bash claude-code/bin/account-exec.test.sh
#
# $TMPDIR 配下に一時 HOME を作り、ghq/github.com/<org>/repo/.claude/worktrees/x を掘る。
# fake の gh / gcloud（受け取った env と argv を 1 行ずつ出すだけ）を一時 dir に置き、
# shim dir ($HOME_T/.claude/bin、実運用と同じ位置) から実物の bin/gh, bin/gcloud を
# symlink して呼ぶ。ACCOUNT_MAP は一時ファイル。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/account-exec"

if [[ ! -x $SHIM ]]; then
  echo "FAIL: shim not executable: $SHIM" >&2
  exit 1
fi
for t in gh gcloud; do
  if [[ ! -L "$SCRIPT_DIR/$t" || "$(readlink "$SCRIPT_DIR/$t")" != "account-exec" ]]; then
    echo "FAIL: $SCRIPT_DIR/$t must be a symlink to account-exec" >&2
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/account-exec-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  printf "  \033[32mPASS\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m %s\n" "$1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
}

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------
HOME_T="$TMPROOT/home"
FAKE_BIN="$TMPROOT/fake-bin"
SHIM_BIN="$HOME_T/.claude/bin"
MAP="$TMPROOT/account-map.json"
ORG_REPO="$HOME_T/ghq/github.com/acme/repo"
ORG_WT="$ORG_REPO/.claude/worktrees/x"
GHONLY_REPO="$HOME_T/ghq/github.com/ghonly/repo"
UNMAPPED_REPO="$HOME_T/ghq/github.com/nobody/repo"
OUTSIDE_DIR="$HOME_T/elsewhere"

mkdir -p "$FAKE_BIN" "$SHIM_BIN" "$ORG_WT" "$GHONLY_REPO" "$UNMAPPED_REPO" "$OUTSIDE_DIR" "$TMPROOT/empty-bin"

for t in gh gcloud; do
  cat >"$FAKE_BIN/$t" <<'EOF'
#!/usr/bin/env bash
printf 'GH_CONFIG_DIR=%s\n' "${GH_CONFIG_DIR-<unset>}"
printf 'CLOUDSDK_ACTIVE_CONFIG_NAME=%s\n' "${CLOUDSDK_ACTIVE_CONFIG_NAME-<unset>}"
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$FAKE_BIN/$t"
  # 実運用と同じ 2 段: ~/.claude/bin/gh → claude-code/bin/gh → account-exec
  ln -s "$SCRIPT_DIR/$t" "$SHIM_BIN/$t"
done

cat >"$MAP" <<'EOF'
{
  "orgs": {
    "acme": { "gh_config_dir": "~/.config/gh-acme", "gcloud_config": "acme-cfg" },
    "ghonly": { "gh_config_dir": "~/.config/gh-ghonly" }
  }
}
EOF

# account-exec のシェバン行 (#!/usr/bin/env bash) 解決と、shim 内部が呼ぶ実 jq の
# 解決用に、それぞれの実ディレクトリだけを PATH 末尾へ足す（shim dir 除外ロジックの
# 対象外の場所なので、gh/gcloud の実体解決には影響しない）。
BASH_DIR="$(dirname "$BASH")"
JQ_DIR="$(dirname "$(command -v jq)")"

# run_shim <cwd> <tool> [args...]
#   RUN_PATH / RUN_MAP / RUN_ENV (配列) で上書き可。結果は OUT / ERR / RC に入る。
RUN_PATH="$SHIM_BIN:$FAKE_BIN:$BASH_DIR:$JQ_DIR"
RUN_MAP="$MAP"
RUN_ENV=()
OUT=""
ERR=""
RC=0
run_shim() {
  local dir="$1" tool="$2"
  shift 2
  set +e
  OUT="$(cd "$dir" && env -u GH_CONFIG_DIR -u CLOUDSDK_ACTIVE_CONFIG_NAME \
    HOME="$HOME_T" PATH="$RUN_PATH" ACCOUNT_MAP="$RUN_MAP" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SHIM_BIN/$tool" "$@" 2>"$TMPROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
}

reset_run() {
  RUN_PATH="$SHIM_BIN:$FAKE_BIN:$BASH_DIR:$JQ_DIR"
  RUN_MAP="$MAP"
  RUN_ENV=()
}

contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  esac
  return 1
}

echo "=== account-exec tests ==="

# ---------------------------------------------------------------------------
# 1. mapped org の repo 直下で gh → GH_CONFIG_DIR が ~ 展開済みで届く
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=$HOME_T/.config/gh-acme"; then
  pass "01_mapped_org_gh_sets_config_dir"
else
  fail "01_mapped_org_gh_sets_config_dir" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. worktree パス …/<org>/repo/.claude/worktrees/x でも 1 と同じ
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_WT" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=$HOME_T/.config/gh-acme"; then
  pass "02_worktree_path_gh_sets_config_dir"
else
  fail "02_worktree_path_gh_sets_config_dir" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. mapped org で gcloud → CLOUDSDK_ACTIVE_CONFIG_NAME
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_REPO" gcloud config list
if [[ $RC -eq 0 ]] && contains "$OUT" "CLOUDSDK_ACTIVE_CONFIG_NAME=acme-cfg"; then
  pass "03_mapped_org_gcloud_sets_config_name"
else
  fail "03_mapped_org_gcloud_sets_config_name" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. gcloud_config を省略した org で gcloud → env 未設定のまま実体へ
# ---------------------------------------------------------------------------
reset_run
run_shim "$GHONLY_REPO" gcloud config list
if [[ $RC -eq 0 ]] && contains "$OUT" "CLOUDSDK_ACTIVE_CONFIG_NAME=<unset>" && [[ -z $ERR ]]; then
  pass "04_missing_key_leaves_env_unset"
else
  fail "04_missing_key_leaves_env_unset" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. 未登録 org / ghq 外 → env 未設定、stderr 空、argv そのまま
# ---------------------------------------------------------------------------
reset_run
run_shim "$UNMAPPED_REPO" gh repo view
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" && [[ -z $ERR ]] &&
  contains "$OUT" $'argc=2\narg=[repo]\narg=[view]'; then
  pass "05a_unmapped_org_passthrough"
else
  fail "05a_unmapped_org_passthrough" "rc=$RC out=$OUT err=$ERR"
fi

reset_run
run_shim "$OUTSIDE_DIR" gh repo view
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" && [[ -z $ERR ]] &&
  contains "$OUT" $'argc=2\narg=[repo]\narg=[view]'; then
  pass "05b_outside_ghq_passthrough"
else
  fail "05b_outside_ghq_passthrough" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 6. マップ不在 / JSON 不正 → env 未設定で実体へ、stderr に警告 1 行
# ---------------------------------------------------------------------------
reset_run
RUN_MAP="$TMPROOT/missing.json"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" &&
  [[ "$(printf '%s\n' "$ERR" | grep -c '^account-exec:')" -eq 1 ]]; then
  pass "06a_missing_map_warns_once_and_passes_through"
else
  fail "06a_missing_map_warns_once_and_passes_through" "rc=$RC out=$OUT err=$ERR"
fi

reset_run
echo '{ "orgs": { not json' >"$TMPROOT/bad.json"
RUN_MAP="$TMPROOT/bad.json"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" &&
  [[ "$(printf '%s\n' "$ERR" | grep -c '^account-exec:')" -eq 1 ]]; then
  pass "06b_invalid_json_warns_once_and_passes_through"
else
  fail "06b_invalid_json_warns_once_and_passes_through" "rc=$RC out=$OUT err=$ERR"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: account-exec"
